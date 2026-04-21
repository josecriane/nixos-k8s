{
  lib,
  pkgs,
  serverConfig,
  ...
}:

let
  k8s = import ../../lib.nix { inherit pkgs serverConfig; };
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

  release = k8s.createHelmRelease {
    name = "traefik";
    namespace = "traefik-system";
    tier = "infrastructure";
    repo = {
      name = "traefik";
      url = "https://traefik.github.io/charts";
    };
    chart = "traefik/traefik";
    timeout = "5m";
    valuesFile = ./values.yaml;
    manifests = [ ./middlewares.yaml ];
    substitutions = {
      TRAEFIK_IP = serverConfig.traefikIP;
      ADDITIONAL_ARGS = builtins.toJSON additionalArgs;
    };
    extraScript = ''
      echo "Waiting for Traefik pod to be ready..."
      wait_for_pod traefik-system "app.kubernetes.io/name=traefik"

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
      echo "LoadBalancer IP: $FINAL_IP"
      echo "Dashboard: kubectl port-forward -n traefik-system svc/traefik 9000:9000"
    '';
  };
in
lib.recursiveUpdate release {
  systemd.services.traefik-setup = {
    after = (release.systemd.services.traefik-setup.after or [ ]) ++ [
      "k3s.service"
      "metallb-setup.service"
    ];
    wants = [
      "k3s.service"
      "metallb-setup.service"
    ];
  };
}
