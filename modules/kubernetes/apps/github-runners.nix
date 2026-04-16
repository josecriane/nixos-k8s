# GitHub Actions Runner Controller (ARC) + self-hosted runner scale set
#
# config.nix:
#   services.github-runners = true;
#   github-runners = {
#     configUrl = "https://github.com/your-org";
#     maxRunners = 5;
#   };
#
# secrets/github-pat.age:
#   A GitHub Personal Access Token with repo + admin:org scopes.
#   echo "ghp_xxxx" | agenix -e secrets/github-pat.age
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

  mirrorEnabled = (serverConfig.services or { }).docker-mirror or false;
  mirrorHost = "mirror.${serverConfig.subdomain}.${serverConfig.domain}";
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
              hostnames = [
                mirrorHost
                registryHost
              ];
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
      # Create GitHub PAT secret from agenix (trim newline from token)
      echo "Creating GitHub PAT secret..."
      TOKEN=$(tr -d '\n' < "${config.age.secrets.github-pat.path}")
      $KUBECTL create secret generic github-secret \
        --namespace arc-runners \
        --from-literal=github_token="$TOKEN" \
        --dry-run=client -o yaml | $KUBECTL apply -f -

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
                          "registry-mirrors": ["https://${mirrorHost}"]''}
          }
      DAEMONEOF

      # Create mirror registry secret (docker auth config)
      if ! $KUBECTL get secret mirror-registry-secret -n arc-runners &>/dev/null; then
        echo "Creating mirror registry secret..."
        $KUBECTL create secret docker-registry mirror-registry-secret \
          --namespace arc-runners \
          --docker-server="${mirrorHost}" \
          --docker-username="unused" \
          --docker-password="unused" \
          --dry-run=client -o yaml | $KUBECTL apply -f -
      fi
    '';
  };
in
{
  age.secrets.github-pat = {
    file = "${secretsPath}/github-pat.age";
  };

  systemd.services = controller.systemd.services // runnerSet.systemd.services;
}
