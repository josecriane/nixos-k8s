{
  config,
  lib,
  pkgs,
  serverConfig,
  ...
}:

let
  k8s = import ../lib.nix { inherit pkgs serverConfig; };
  markerFile = "/var/lib/traefik-setup-done";
  isAcme = (serverConfig.certificates.provider or "manual") == "acme";
  additionalArgs = [
    "--providers.kubernetescrd.allowCrossNamespace=true"
    # HTTP (web, :80) permanent redirect to HTTPS (websecure, :443)
    "--entrypoints.web.http.redirections.entryPoint.to=websecure"
    "--entrypoints.web.http.redirections.entryPoint.scheme=https"
    "--entrypoints.web.http.redirections.entryPoint.permanent=true"
  ]
  ++ lib.optionals isAcme [
    "--certificatesresolvers.default.acme.email=${serverConfig.acmeEmail}"
    "--certificatesresolvers.default.acme.storage=/data/acme.json"
    "--certificatesresolvers.default.acme.tlschallenge=true"
  ];
  additionalArgsFlags = lib.concatStringsSep " " (
    lib.imap0 (i: arg: "--set additionalArguments[${toString i}]=\"${arg}\"") additionalArgs
  );
in
{
  systemd.services.traefik-setup = {
    description = "Setup Traefik ingress controller";
    after = [
      "k3s.service"
      "metallb-setup.service"
    ];
    wants = [
      "k3s.service"
      "metallb-setup.service"
    ];
    # TIER 1: Infrastructure
    wantedBy = [ "k3s-infrastructure.target" ];
    before = [ "k3s-infrastructure.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      ExecStart = pkgs.writeShellScript "traefik-setup" ''
        ${k8s.libShSource}

        setup_preamble "${markerFile}" "Traefik"
        wait_for_k3s

        # Wait for MetalLB to be ready
        echo "Waiting for MetalLB to be ready..."
        for i in $(seq 1 36); do
          if $KUBECTL get namespace metallb-system &>/dev/null && \
             $KUBECTL get ipaddresspool -n metallb-system default-pool &>/dev/null; then
            echo "MetalLB is ready"
            break
          fi
          echo "Waiting for MetalLB... ($i/36)"
          sleep 5
        done

        if ! $KUBECTL get ipaddresspool -n metallb-system default-pool &>/dev/null; then
          echo "ERROR: MetalLB not available after 3 minutes"
          exit 1
        fi

        echo "Installing Traefik with Helm..."

        helm_repo_add traefik https://traefik.github.io/charts

        ensure_namespace traefik-system

        $HELM upgrade --install traefik traefik/traefik \
          --namespace traefik-system \
          --set service.type=LoadBalancer \
          --set service.spec.loadBalancerIP=${serverConfig.traefikIP} \
          --set ports.web.port=80 \
          --set ports.web.exposedPort=80 \
          --set ports.websecure.port=443 \
          --set ports.websecure.exposedPort=443 \
          --set ingressClass.enabled=true \
          --set ingressClass.isDefaultClass=true \
          --set ingressRoute.dashboard.enabled=false \
          --set logs.general.level=INFO \
          --set logs.access.enabled=true \
          --set providers.kubernetesCRD.enabled=true \
          --set providers.kubernetesIngress.enabled=true \
          ${additionalArgsFlags} \
          --set persistence.enabled=true \
          --set persistence.size=1Gi \
          --wait \
          --timeout 5m

        echo "Waiting for Traefik pod to be ready..."
        wait_for_pod traefik-system "app.kubernetes.io/name=traefik"

        # HSTS middleware: tells browsers to only use HTTPS for 1 year.
        # Attached to IngressRoutes via lib.sh create_ingress_route.
        echo "Creating HSTS middleware..."
        cat <<'HSTSEOF' | $KUBECTL apply -f -
        apiVersion: traefik.io/v1alpha1
        kind: Middleware
        metadata:
          name: hsts-headers
          namespace: traefik-system
        spec:
          headers:
            stsSeconds: 31536000
            stsIncludeSubdomains: true
            stsPreload: true
            forceSTSHeader: true
        HSTSEOF

        echo "Waiting for Traefik to get LoadBalancer IP..."
        for i in $(seq 1 30); do
          TRAEFIK_IP=$($KUBECTL get svc -n traefik-system traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
          if [ "$TRAEFIK_IP" = "${serverConfig.traefikIP}" ]; then
            echo "Traefik got IP: $TRAEFIK_IP"
            break
          fi
          echo "Waiting for LoadBalancer IP... ($i/30) (current: $TRAEFIK_IP)"
          sleep 2
        done

        FINAL_IP=$($KUBECTL get svc -n traefik-system traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")

        # Dashboard not exposed externally (no auth provider configured)
        # Access via: kubectl port-forward -n traefik-system svc/traefik 9000:9000

        print_success "Traefik" \
          "LoadBalancer IP: $FINAL_IP" \
          "Ports: 80 (HTTP), 443 (HTTPS)" \
          "Dashboard: kubectl port-forward -n traefik-system svc/traefik 9000:9000"

        create_marker "${markerFile}"
      '';
    };
  };
}
