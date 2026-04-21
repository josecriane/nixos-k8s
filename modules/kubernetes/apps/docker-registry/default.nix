# Docker Registry + UI
#
# Authentication model:
#   - Anonymous GET/HEAD (pulls)
#   - BasicAuth required for push/delete (POST/PUT/PATCH/DELETE)
#   - UI requires auth
# htpasswd credentials live in agenix secret tls-htpasswd.age.
#
# config.nix:
#   services.docker-registry = true;
#
# secrets/registry-htpasswd.age:
#   Raw htpasswd file content. Generate with:
#     htpasswd -Bc htpasswd ci-user
#     agenix -e secrets/registry-htpasswd.age < htpasswd
#
# URLs:
#   Registry: https://registry.<subdomain>.<domain>
#   UI:       https://registry-ui.<subdomain>.<domain>
#
# Push example:
#   docker login registry.<subdomain>.<domain>
#   docker push registry.<subdomain>.<domain>/myimage:latest
{
  config,
  lib,
  pkgs,
  serverConfig,
  secretsPath,
  ...
}:

let
  k8s = import ../../lib.nix { inherit pkgs serverConfig; };

  # htpasswd secret for Traefik BasicAuth (key must be 'users').
  # Must exist before manifests.yaml applies the Middleware that references it,
  # otherwise push requests 503 during the first bootstrap window.
  preHelm = pkgs.writeShellScript "docker-registry-pre-helm" ''
    ${k8s.libShSource}
    set -euo pipefail
    wait_for_k3s
    ensure_namespace container-registry

    echo "Creating registry htpasswd secret..."
    HTPASSWD_CONTENT=$(cat "${config.age.secrets.registry-htpasswd.path}")
    $KUBECTL create secret generic registry-htpasswd \
      --namespace container-registry \
      --from-literal=users="$HTPASSWD_CONTENT" \
      --dry-run=client -o yaml | $KUBECTL apply -f -
  '';

  registry = k8s.createHelmRelease {
    name = "docker-registry";
    namespace = "container-registry";
    repo = {
      name = "docker-registry";
      url = "https://twuni.github.io/docker-registry.helm";
    };
    chart = "docker-registry/docker-registry";
    version = "2.2.3";
    tier = "core";
    valuesFile = ./values-registry.yaml;
    manifests = [ ./manifests.yaml ];
    # TLS handled by the default TLSStore in traefik-system (see tls-secret.nix).
  };

  ui = k8s.createHelmRelease {
    name = "docker-registry-ui";
    namespace = "container-registry";
    repo = {
      name = "docker-registry-ui";
      url = "https://helm.joxit.dev";
    };
    chart = "docker-registry-ui/docker-registry-ui";
    version = "1.1.3";
    tier = "core";
    valuesFile = ./values-ui.yaml;
    ingress = {
      host = "registry-ui";
      service = "docker-registry-ui-docker-registry-ui-user-interface";
      port = 80;
    };
    middlewares = [
      {
        name = "registry-auth";
        namespace = "container-registry";
      }
    ];
  };
in
lib.recursiveUpdate {
  age.secrets.registry-htpasswd = {
    file = "${secretsPath}/registry-htpasswd.age";
  };

  systemd.services = registry.systemd.services // ui.systemd.services;
} {
  systemd.services.docker-registry-setup.serviceConfig.ExecStartPre = "${preHelm}";
}
