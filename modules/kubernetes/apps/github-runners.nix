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
  k8s = import ../lib.nix { inherit pkgs serverConfig; };
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
    values = {
      inherit githubConfigUrl maxRunners;
      githubConfigSecret = "github-secret";
      runnerScaleSetName = runnerName;
      minRunners = 0;
      controllerServiceAccount = {
        name = "arc-gha-rs-controller";
        namespace = "arc-systems";
      };
      template = {
        spec = {
          containers = [
            {
              name = "runner";
              image = "ghcr.io/actions/actions-runner:latest";
              command = [ "/home/runner/run.sh" ];
              env = [
                {
                  name = "DOCKER_HOST";
                  value = "unix:///var/run/docker.sock";
                }
                {
                  name = "DOCKER_API_VERSION";
                  value = "1.43";
                }
                {
                  name = "RUNNER_WAIT_FOR_DOCKER_IN_SECONDS";
                  value = "120";
                }
              ];
              resources = {
                requests = {
                  cpu = "500m";
                  memory = "1Gi";
                };
                limits = {
                  cpu = "2";
                  memory = "6Gi";
                };
              };
              volumeMounts = [
                {
                  name = "work";
                  mountPath = "/home/runner/_work";
                }
                {
                  name = "dind-sock";
                  mountPath = "/var/run";
                }
                {
                  name = "docker-conf-rw";
                  mountPath = "/home/runner/.docker";
                }
              ];
            }
            {
              name = "dind";
              image = "docker:24-dind";
              args = [
                "dockerd"
                "--host=unix:///var/run/docker.sock"
                "--group=$(DOCKER_GROUP_GID)"
              ];
              env = [
                {
                  name = "DOCKER_GROUP_GID";
                  value = "123";
                }
              ];
              securityContext = {
                privileged = true;
              };
              resources = {
                requests = {
                  cpu = "250m";
                  memory = "512Mi";
                };
                limits = {
                  cpu = "1";
                  memory = "2Gi";
                };
              };
              volumeMounts = [
                {
                  name = "work";
                  mountPath = "/home/runner/_work";
                }
                {
                  name = "dind-sock";
                  mountPath = "/var/run";
                }
                {
                  name = "dind-externals";
                  mountPath = "/home/runner/externals";
                }
                {
                  name = "daemon-json";
                  mountPath = "/etc/docker/daemon.json";
                  readOnly = true;
                  subPath = "daemon.json";
                }
                {
                  name = "dind-docker-conf";
                  mountPath = "/root/.docker";
                }
              ];
            }
          ];
          initContainers = [
            {
              name = "init-dind-externals";
              image = "ghcr.io/actions/actions-runner:latest";
              command = [
                "cp"
                "-r"
                "/home/runner/externals/."
                "/home/runner/tmpDir/"
              ];
              volumeMounts = [
                {
                  name = "dind-externals";
                  mountPath = "/home/runner/tmpDir";
                }
              ];
            }
            {
              name = "copy-docker-config";
              image = "busybox:1.34.1";
              command = [
                "sh"
                "-c"
                ''
                  set -x
                  mkdir -p /home/runner/.docker
                  cp /docker-conf-ro/config.json /home/runner/.docker/config.json
                  chmod 644 /home/runner/.docker/config.json
                  mkdir -p /dind-docker-conf
                  cp /docker-conf-ro/config.json /dind-docker-conf/config.json
                  chmod 644 /dind-docker-conf/config.json
                ''
              ];
              volumeMounts = [
                {
                  name = "docker-conf-rw";
                  mountPath = "/home/runner/.docker";
                }
                {
                  name = "dind-docker-conf";
                  mountPath = "/dind-docker-conf";
                }
                {
                  name = "mirror-registry";
                  mountPath = "/docker-conf-ro/config.json";
                  subPath = ".dockerconfigjson";
                }
              ];
            }
          ];
          hostAliases = lib.optionals mirrorEnabled [
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
          ];
          volumes = [
            {
              name = "work";
              emptyDir = { };
            }
            {
              name = "dind-sock";
              emptyDir = { };
            }
            {
              name = "dind-externals";
              emptyDir = { };
            }
            {
              name = "docker-conf-rw";
              emptyDir = { };
            }
            {
              name = "dind-docker-conf";
              emptyDir = { };
            }
            {
              name = "mirror-registry";
              secret = {
                secretName = "mirror-registry-secret";
              };
            }
            {
              name = "daemon-json";
              configMap = {
                name = "docker-daemon-config";
              };
            }
          ];
        };
      };
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

      # NetworkPolicy: restrict egress to DNS, mirror, traefik and internet only.
      # Blocks access to kube-apiserver, kubelet, other namespaces, LAN (RFC1918).
      # This reduces the blast radius of a compromised runner (DinD is privileged).
      echo "Applying arc-runners NetworkPolicy..."
      cat <<'NETPOLEOF' | $KUBECTL apply -f -
      apiVersion: networking.k8s.io/v1
      kind: NetworkPolicy
      metadata:
        name: arc-runners-egress
        namespace: arc-runners
      spec:
        podSelector: {}
        policyTypes: [Egress]
        egress:
          # DNS via CoreDNS (no port filter: NixOS' CoreDNS listens on 10053,
          # and Calico evaluates the policy post-DNAT so the service port 53
          # would not match).
          - to:
              - namespaceSelector:
                  matchLabels:
                    kubernetes.io/metadata.name: kube-system
          # Docker mirror (internal only, HTTP)
          - to:
              - namespaceSelector:
                  matchLabels:
                    kubernetes.io/metadata.name: container-mirror
            ports:
              - protocol: TCP
                port: 5000
          # Docker registry via Traefik (for docker login/push)
          - to:
              - namespaceSelector:
                  matchLabels:
                    kubernetes.io/metadata.name: traefik-system
            ports:
              - protocol: TCP
                port: 443
              - protocol: TCP
                port: 80
          # Internet, but block all RFC1918/private ranges (no LAN, no k8s internal IPs)
          - to:
              - ipBlock:
                  cidr: 0.0.0.0/0
                  except:
                    - 10.0.0.0/8
                    - 172.16.0.0/12
                    - 192.168.0.0/16
                    - 169.254.0.0/16
      NETPOLEOF
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
