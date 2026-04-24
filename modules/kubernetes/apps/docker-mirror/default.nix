# Docker Registry Mirror (pull-through cache for Docker Hub)
#
# config.nix:
#   services.docker-mirror = true;
#
# Exposed externally at mirror.<subdomain>.<domain> behind BasicAuth
# (reusing the registry htpasswd in registry-htpasswd.age) so CI pipelines
# can `docker login` and pull/push-through cached images. Cluster pods keep
# using the internal service URL:
#   http://docker-mirror-docker-registry.container-mirror.svc.cluster.local:5000
#
# secrets/docker-mirror-proxy.age:
#   Two lines: username on line 1, password/token on line 2. Used to
#   authenticate against Docker Hub (registry-1.docker.io) to avoid
#   anonymous rate limits. Generate a token at
#   https://hub.docker.com/settings/security and encrypt with:
#     printf 'myuser\nmytoken\n' | agenix -e secrets/docker-mirror-proxy.age
#
# secrets/registry-htpasswd.age:
#   Shared with the private docker-registry. Same users can log in to both.
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

  # The twuni chart always generates its own Secret named
  # "<release>-<chart>-secret" (here: docker-mirror-docker-registry-secret)
  # and references it by fixed name in the Deployment. It doesn't support
  # `proxy.secretRef` or `existingSecret` for proxy creds, so we let helm
  # create the Secret (initially with empty credentials, falling back to
  # anonymous pull-through) and overwrite it post-install with the real
  # values from agenix, then rollout-restart so pods pick them up.
  chartSecret = "docker-mirror-docker-registry-secret";

  # Middleware + htpasswd Secret must exist BEFORE the IngressRoute that
  # references them, otherwise Traefik reports the route as invalid.
  preHelm = pkgs.writeShellScript "docker-mirror-pre-helm" ''
    ${k8s.libShSource}
    set -euo pipefail
    wait_for_k3s
    ensure_namespace container-mirror

    echo "Creating htpasswd secret and BasicAuth middleware in container-mirror..."
    HTPASSWD_CONTENT=$(cat "${config.age.secrets.registry-htpasswd.path}")
    $KUBECTL create secret generic registry-htpasswd \
      --namespace container-mirror \
      --from-literal=users="$HTPASSWD_CONTENT" \
      --dry-run=client -o yaml | $KUBECTL apply -f -

    cat <<'MW' | $KUBECTL apply -f -
    apiVersion: traefik.io/v1alpha1
    kind: Middleware
    metadata:
      name: registry-auth
      namespace: container-mirror
    spec:
      basicAuth:
        secret: registry-htpasswd
    MW
  '';

  injectProxyCreds = ''
    echo "Injecting Docker Hub proxy credentials into ${chartSecret}..."
    USERNAME=$(sed -n '1p' "${config.age.secrets.docker-mirror-proxy.path}")
    PASSWORD=$(sed -n '2p' "${config.age.secrets.docker-mirror-proxy.path}")

    # Preserve haSharedSecret if the chart already generated one; otherwise
    # create a new random value so we don't leave that field empty.
    HA_SECRET=$($KUBECTL -n container-mirror get secret ${chartSecret} \
      -o jsonpath='{.data.haSharedSecret}' 2>/dev/null | base64 -d || true)
    if [ -z "$HA_SECRET" ]; then
      HA_SECRET=$($OPENSSL rand -hex 16)
    fi

    $KUBECTL create secret generic ${chartSecret} \
      --namespace container-mirror \
      --from-literal=proxyUsername="$USERNAME" \
      --from-literal=proxyPassword="$PASSWORD" \
      --from-literal=haSharedSecret="$HA_SECRET" \
      --dry-run=client -o yaml | $KUBECTL apply -f -

    # Restart only if the running pods' env-hash doesn't already match.
    # Simpler: unconditional rollout restart; the no-op case still returns fast.
    $KUBECTL -n container-mirror rollout restart deploy docker-mirror-docker-registry
    $KUBECTL -n container-mirror rollout status deploy docker-mirror-docker-registry --timeout=180s
  '';

  release = k8s.createHelmRelease {
    name = "docker-mirror";
    namespace = "container-mirror";
    repo = {
      name = "docker-registry";
      url = "https://twuni.github.io/docker-registry.helm";
    };
    chart = "docker-registry/docker-registry";
    version = "2.2.3";
    tier = "core";
    valuesFile = ./values.yaml;
    ingress = {
      host = "mirror";
      service = "docker-mirror-docker-registry";
      port = 5000;
    };
    middlewares = [
      {
        name = "registry-auth";
        namespace = "container-mirror";
      }
    ];
    extraScript = injectProxyCreds;
  };
in
lib.recursiveUpdate
  {
    age.secrets.docker-mirror-proxy = {
      file = "${secretsPath}/docker-mirror-proxy.age";
    };
    age.secrets.registry-htpasswd = {
      file = "${secretsPath}/registry-htpasswd.age";
    };

    systemd.services = release.systemd.services;
  }
  {
    systemd.services.docker-mirror-setup.serviceConfig.ExecStartPre = "${preHelm}";
  }
