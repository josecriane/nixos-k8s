# GitHub Actions Runner Controller (ARC) + self-hosted runner scale set
#
# config.nix:
#   services.github-runners = true;
#   github-runners = {
#     configUrl = "https://github.com/your-org";
#     maxRunners = 5;
#     runnerName = "self-hosted-linux";
#     # GitHub App auth (recommended - minimal scopes, short-lived tokens)
#     githubApp = {
#       appId = 1234567;
#       installationId = 87654321;
#     };
#   };
#
# Authentication:
#   - With githubApp block: needs secrets/github-app-key.age (private key .pem)
#   - Without githubApp block: falls back to PAT via secrets/github-pat.age
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
  ghConfig = serverConfig.github-runners or { };
  githubConfigUrl = ghConfig.configUrl or "";
  maxRunners = ghConfig.maxRunners or 5;
  runnerName = ghConfig.runnerName or "self-hosted-linux";

  # GitHub App auth is preferred. Fall back to PAT only if githubApp not configured.
  githubApp = ghConfig.githubApp or null;
  useGithubApp = githubApp != null;

  mirrorEnabled = (serverConfig.services or { }).docker-mirror or false;
  # Internal cluster DNS for the mirror (no external ingress)
  mirrorInternalHost = "docker-mirror-docker-registry.container-mirror.svc.cluster.local:5000";
  registryHost = "registry.${serverConfig.subdomain}.${serverConfig.domain}";
  traefikIP = serverConfig.traefikIP;

  hostAliasesJson = builtins.toJSON (
    lib.optionals mirrorEnabled [
      {
        ip = "127.0.0.1";
        hostnames = [
          "index.docker.io"
          "registry-1.docker.io"
          "docker.io"
        ];
      }
      {
        ip = traefikIP;
        hostnames = [ registryHost ];
      }
    ]
  );

  controller = k8s.createHelmRelease {
    name = "arc";
    namespace = "arc-systems";
    chart = "oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller";
    version = "0.13.1";
    tier = "apps";
  };

  runnerSet = k8s.createHelmRelease {
    name = "arc-runner-set";
    namespace = "arc-runners";
    chart = "oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set";
    version = "0.13.1";
    tier = "extras";
    # Runners need privileged DinD (docker:24-dind sidecar).
    pssLevel = "privileged";
    valuesFile = ./values-runner-set.yaml;
    manifests = [ ./manifests.yaml ];
    substitutions = {
      GITHUB_CONFIG_URL = githubConfigUrl;
      MAX_RUNNERS = maxRunners;
      RUNNER_NAME = runnerName;
      HOST_ALIASES = hostAliasesJson;
    };
    extraScript = ''
      # Create GitHub auth secret (App or PAT)
      echo "Creating GitHub auth secret..."
      ${
        if useGithubApp then
          ''
            $KUBECTL create secret generic github-secret \
              --namespace arc-runners \
              --from-literal=github_app_id="${toString githubApp.appId}" \
              --from-literal=github_app_installation_id="${toString githubApp.installationId}" \
              --from-file=github_app_private_key="${config.age.secrets.github-app-key.path}" \
              --dry-run=client -o yaml | $KUBECTL apply -f -
          ''
        else
          ''
            TOKEN=$(tr -d '\n' < "${config.age.secrets.github-pat.path}")
            $KUBECTL create secret generic github-secret \
              --namespace arc-runners \
              --from-literal=github_token="$TOKEN" \
              --dry-run=client -o yaml | $KUBECTL apply -f -
          ''
      }

      # Create daemon.json ConfigMap for DinD (registry mirror + MTU)
      echo "Creating Docker daemon config..."
      cat <<DAEMONEOF | $KUBECTL apply -f -
      apiVersion: v1
      kind: ConfigMap
      metadata:
        name: docker-daemon-config
        namespace: arc-runners
      data:
        daemon.json: |
          {
            "mtu": 1450,
            "default-network-opts": {
              "bridge": {
                "com.docker.network.driver.mtu": "1450"
              }
            }${lib.optionalString mirrorEnabled ''
              ,
                          "registry-mirrors": ["http://${mirrorInternalHost}"],
                          "insecure-registries": ["${mirrorInternalHost}"]''}
          }
      DAEMONEOF

      # Create mirror registry secret (docker auth config for registry login on the node)
      if ! $KUBECTL get secret mirror-registry-secret -n arc-runners &>/dev/null; then
        echo "Creating registry secret..."
        $KUBECTL create secret docker-registry mirror-registry-secret \
          --namespace arc-runners \
          --docker-server="${registryHost}" \
          --docker-username="unused" \
          --docker-password="unused" \
          --dry-run=client -o yaml | $KUBECTL apply -f -
      fi

    '';
  };
in
{
  age.secrets = lib.mkMerge [
    (lib.mkIf useGithubApp {
      github-app-key = {
        file = "${secretsPath}/github-app-key.age";
      };
    })
    (lib.mkIf (!useGithubApp) {
      github-pat = {
        file = "${secretsPath}/github-pat.age";
      };
    })
  ];

  systemd.services = controller.systemd.services // runnerSet.systemd.services;
}
