{
  config,
  lib,
  pkgs,
  ...
}:

let
  isAcme = config.cluster.certificates.provider == "acme";
  useMetalLB = config.cluster.kubernetes.loadBalancer == "metallb";

  additionalArgs = [
    "--providers.kubernetescrd.allowCrossNamespace=true"
    # HTTP (web, :80) permanent redirect to HTTPS (websecure, :443)
    "--entrypoints.web.http.redirections.entryPoint.to=websecure"
    "--entrypoints.web.http.redirections.entryPoint.scheme=https"
    "--entrypoints.web.http.redirections.entryPoint.permanent=true"
  ]
  ++ lib.optionals isAcme [
    "--certificatesresolvers.default.acme.email=${config.cluster.acmeEmail}"
    "--certificatesresolvers.default.acme.storage=/data/acme.json"
    "--certificatesresolvers.default.acme.tlschallenge=true"
  ];

  # MetalLB assigns a fixed IP from the pool, so we can wait for that exact
  # address. With servicelb the address is whatever node IP klipper reports,
  # so there is nothing to compare against.
  waitForPoolIP = ''
    echo "Waiting for Traefik to get LoadBalancer IP..."
    for i in $(seq 1 30); do
      TRAEFIK_IP=$($KUBECTL get svc -n traefik-system traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
      if [ "$TRAEFIK_IP" = "${config.cluster.traefikIP}" ]; then
        echo "Traefik got IP: $TRAEFIK_IP"
        break
      fi
      echo "Waiting for LoadBalancer IP... ($i/30) (current: $TRAEFIK_IP)"
      sleep 2
    done
  '';

  lbUnits = [ "k3s.service" ] ++ lib.optional useMetalLB "metallb-setup.service";

  release = {
    namespace = "traefik-system";
    tier = "infrastructure";
    repo = {
      name = "traefik";
      url = "https://traefik.github.io/charts";
    };
    chart = "traefik/traefik";
    timeout = "5m";
    valuesFile = if useMetalLB then ./values.yaml else ./values-servicelb.yaml;
    manifests = [ ./middlewares.yaml ];
    substitutions = {
      ADDITIONAL_ARGS = builtins.toJSON additionalArgs;
    }
    // lib.optionalAttrs useMetalLB {
      TRAEFIK_IP = config.cluster.traefikIP;
    };
    after = lbUnits;
    postInstall = ''
      echo "Waiting for Traefik pod to be ready..."
      wait_for_pod traefik-system "app.kubernetes.io/name=traefik"

    ''
    + lib.optionalString useMetalLB waitForPoolIP
    + ''

      FINAL_IP=$($KUBECTL get svc -n traefik-system traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
      echo "LoadBalancer IP: $FINAL_IP"
      echo "Dashboard: kubectl port-forward -n traefik-system svc/traefik 9000:9000"
    '';
  };
in
lib.mkIf config.cluster.isBootstrap {
  k8s.helmReleases.traefik = release;
}
