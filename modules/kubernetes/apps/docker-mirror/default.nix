# Docker Registry Mirror (pull-through cache for Docker Hub)
#
# config.nix:
#   services.docker-mirror = true;
#
# Internal-only service, no external ingress. Accessed by pods in the cluster
# via: http://docker-mirror-docker-registry.container-mirror.svc.cluster.local:5000
#
# This URL is used automatically by the DinD sidecar in GitHub runners
# (see modules/kubernetes/apps/github-runners).
#
# secrets/docker-mirror-proxy.age:
#   Two lines: username on line 1, password/token on line 2. Used to
#   authenticate against Docker Hub (registry-1.docker.io) to avoid
#   anonymous rate limits. Generate a token at
#   https://hub.docker.com/settings/security and encrypt with:
#     printf 'myuser\nmytoken\n' | agenix -e secrets/docker-mirror-proxy.age
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
    extraScript = injectProxyCreds;
  };
in
{
  age.secrets.docker-mirror-proxy = {
    file = "${secretsPath}/docker-mirror-proxy.age";
  };

  systemd.services = release.systemd.services;
}
