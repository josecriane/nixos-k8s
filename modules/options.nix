{ config, lib, ... }:
let
  inherit (lib) mkOption types;

  freeform =
    options:
    types.submodule {
      inherit options;
      freeformType = types.attrs;
    };

  bool =
    default: description:
    mkOption {
      inherit default description;
      type = types.bool;
    };

  str =
    default: description:
    mkOption {
      inherit default description;
      type = types.str;
    };

  nullOrStr =
    description:
    mkOption {
      inherit description;
      type = types.nullOr types.str;
      default = null;
    };

  middlewares =
    description:
    mkOption {
      inherit description;
      type = types.listOf types.attrs;
      default = [ ];
    };

  node = types.submodule (
    { name, ... }:
    {
      freeformType = types.attrs;
      options = {
        name = mkOption {
          type = types.str;
          default = name;
          readOnly = true;
          description = "Node name, taken from its key in `nodes`.";
        };
        ip = mkOption {
          type = types.str;
          description = "Static IPv4 address of the node.";
        };
        role = mkOption {
          type = types.enum [
            "server"
            "agent"
          ];
          description = "Control-plane server or worker agent.";
        };
        bootstrap = bool false "Whether this node initialises the cluster and runs the cluster-wide setup units. Exactly one node sets it.";
        powerManaged = bool false "Whether the node may be suspended and woken by power management.";
        mac = nullOrStr "MAC address used for Wake-on-LAN.";
        encryption = mkOption {
          default = { };
          description = "LUKS root encryption for the node.";
          type = freeform {
            enable = bool false "Whether to encrypt the root partition.";
            unlock = mkOption {
              type = types.enum [
                "ssh"
                "tpm"
              ];
              default = "ssh";
              description = "Unlock with a passphrase over initrd SSH, or with the TPM.";
            };
            sshPort = mkOption {
              type = types.port;
              default = 2222;
              description = "initrd SSH port when `unlock = \"ssh\"`.";
            };
          };
        };
        kubelet = mkOption {
          default = { };
          description = "kubelet resource reservations (kubeadm only).";
          type = freeform {
            systemReserved = str "cpu=500m,memory=512Mi" "kubelet `--system-reserved`.";
            kubeReserved = str "cpu=500m,memory=512Mi" "kubelet `--kube-reserved`.";
          };
        };
      };
    }
  );

  nas = types.submodule (
    { name, ... }:
    {
      freeformType = types.attrs;
      options = {
        name = mkOption {
          type = types.str;
          default = name;
          readOnly = true;
          description = "NAS name, taken from its key in `nas`.";
        };
        enabled = bool false "Whether the cluster uses this NAS.";
        ip = nullOrStr "IPv4 address of the NAS.";
        hostname = str name "Hostname of the NAS. Also names its mount point `/mnt/<hostname>`.";
        role = str "all" "`media` or `all` marks the primary NAS for media. Any other value excludes it.";
        nfsExports = mkOption {
          default = { };
          description = "NFS exports of the NAS.";
          type = freeform {
            nfsPath = str "/" "Exported NFS path.";
          };
        };
        mediaPaths = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Paths on a secondary NAS mounted into the media tree.";
        };
      };
    }
  );

  clusterModule =
    { config, ... }:
    {
      freeformType = types.attrs;
      options = {
        nodeName = mkOption {
          type = types.str;
          internal = true;
          description = "Name of the node this system is built for. Set by `mkCluster`.";
        };
        node = mkOption {
          type = types.attrs;
          readOnly = true;
          default = config.nodes.${config.nodeName};
          defaultText = lib.literalExpression "config.cluster.nodes.\${config.cluster.nodeName}";
          description = "Configuration of the node this system is built for.";
        };
        bootstrapNode = mkOption {
          type = types.attrs;
          readOnly = true;
          default = builtins.head (builtins.filter (n: n.bootstrap) (lib.attrValues config.nodes));
          defaultText = lib.literalMD "the node with `bootstrap = true`";
          description = "Configuration of the bootstrap node.";
        };
        isBootstrap = mkOption {
          type = types.bool;
          readOnly = true;
          default = config.node.bootstrap;
          defaultText = lib.literalExpression "config.cluster.node.bootstrap";
          description = "Whether this system is the bootstrap node.";
        };
        secretsPath = mkOption {
          type = types.path;
          description = "Directory with the agenix `.age` files. Set by `mkCluster`.";
        };

        domain = mkOption {
          type = types.str;
          description = "Base domain.";
        };
        subdomain = mkOption {
          type = types.str;
          description = "Subdomain under `domain`. Services live at `<name>.<subdomain>.<domain>`.";
        };
        gateway = mkOption {
          type = types.str;
          description = "LAN default gateway.";
        };
        nameservers = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Upstream DNS servers.";
        };
        timezone = str "UTC" "System timezone and `TZ` of the workloads.";

        useWifi = bool false "Whether nodes connect over WiFi instead of Ethernet.";
        wifiSSID = str "" "WiFi network name when `useWifi = true`.";

        adminUser = mkOption {
          type = types.str;
          description = "Name of the admin user on every node.";
        };
        adminSSHKeys = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "SSH public keys of the admin user, also used for initrd SSH.";
        };
        agenixIdentity = nullOrStr "Private key that the scripts use to decrypt the secrets.";
        puid = mkOption {
          type = types.int;
          default = 1000;
          description = "UID of the workloads that run as a user.";
        };
        pgid = mkOption {
          type = types.int;
          default = 1000;
          description = "GID of the workloads that run as a user.";
        };

        acmeEmail = nullOrStr "ACME account email when `certificates.provider = \"acme\"`.";
        metallbPoolStart = nullOrStr "First address of the MetalLB L2 pool.";
        metallbPoolEnd = nullOrStr "Last address of the MetalLB L2 pool.";
        traefikIP = nullOrStr "LoadBalancer IP of Traefik.";

        kubernetes = mkOption {
          default = { };
          description = "Kubernetes distribution and network.";
          type = freeform {
            engine = mkOption {
              type = types.enum [
                "k3s"
                "kubeadm"
              ];
              default = "k3s";
              description = "Kubernetes distribution.";
            };
            cni = mkOption {
              type = types.enum [
                "flannel"
                "calico"
              ];
              default = "flannel";
              description = "Pod network.";
            };
            loadBalancer = mkOption {
              type = types.enum [
                "metallb"
                "servicelb"
              ];
              default = "metallb";
              description = "LoadBalancer implementation. `servicelb` requires k3s.";
            };
            podCidr = str "10.42.0.0/16" "Pod network CIDR.";
            serviceCidr = str "10.43.0.0/16" "Service network CIDR.";
          };
        };

        certificates = mkOption {
          default = { };
          description = "TLS certificate source.";
          type = freeform {
            provider = mkOption {
              type = types.enum [
                "acme"
                "manual"
              ];
              default = "manual";
              description = "`acme` issues a wildcard with cert-manager and Cloudflare DNS-01. `manual` reads `tls-cert.age` and `tls-key.age`.";
            };
            restoreFromBackup = bool true "Restore the ACME certificate from a backup to avoid rate limits.";
          };
        };

        storage = mkOption {
          default = { };
          description = "Persistent storage.";
          type = freeform {
            useNFS = bool false "Whether to back hostPath volumes with the primary NAS over NFS.";
            longhorn = mkOption {
              default = { };
              description = "Longhorn replicated block storage.";
              type = freeform {
                enable = bool false "Whether to deploy Longhorn.";
                replicaCount = mkOption {
                  type = types.int;
                  default = 2;
                  description = "Replicas per volume.";
                };
                defaultStorageClass = bool false "Whether Longhorn is the default StorageClass.";
                ingress = mkOption {
                  default = null;
                  description = "Ingress for the Longhorn UI.";
                  type = types.nullOr (freeform {
                    host = mkOption {
                      type = types.str;
                      description = "Host label under `<subdomain>.<domain>`.";
                    };
                    middlewares = middlewares "Traefik middlewares of the Longhorn UI.";
                  });
                };
              };
            };
          };
        };

        services = mkOption {
          default = { };
          description = "Optional services. An unknown key is an error.";
          type = types.submodule {
            options = {
              docker-registry = bool false "Private Docker registry.";
              docker-mirror = bool false "Pull-through Docker Hub mirror.";
              github-runners = bool false "GitHub Actions runner scale set.";
              monitoring = bool false "kube-prometheus-stack, Loki and the exporters.";
              traefikDashboard = bool false "Traefik dashboard IngressRoute.";
            };
          };
        };

        monitoring = mkOption {
          default = { };
          description = "Monitoring stack, used when `services.monitoring = true`.";
          type = freeform {
            storageClass = nullOrStr "StorageClass of every monitoring PVC. `null` uses the cluster default.";
            loki = mkOption {
              default = { };
              description = "Loki.";
              type = freeform {
                enable = bool true "Whether to deploy Loki and Promtail.";
              };
            };
            grafana = mkOption {
              default = { };
              description = "Grafana.";
              type = freeform {
                middlewares = middlewares "Traefik middlewares of Grafana.";
              };
            };
            prometheus = mkOption {
              default = { };
              description = "Prometheus.";
              type = freeform {
                middlewares = middlewares "Traefik middlewares of Prometheus. No ingress when empty.";
              };
            };
            alertmanager = mkOption {
              default = { };
              description = "Alertmanager.";
              type = freeform {
                middlewares = middlewares "Traefik middlewares of Alertmanager. No ingress when empty.";
                webhook = mkOption {
                  default = { };
                  description = "Webhook receiver.";
                  type = freeform {
                    enable = bool false "Whether to send alerts to a webhook.";
                    url = str "" "Webhook URL.";
                    existingSecret = nullOrStr "Secret with the bearer token.";
                    tokenKey = str "api_token" "Key of the token in `existingSecret`.";
                    repeatInterval = str "12h" "Alertmanager `repeat_interval`.";
                    groupBy = mkOption {
                      type = types.listOf types.str;
                      default = [
                        "namespace"
                        "alertname"
                      ];
                      description = "Alertmanager `group_by`.";
                    };
                  };
                };
              };
            };
            disabledRules = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "kube-prometheus-stack default rules to disable.";
            };
            grafanaCloud = mkOption {
              default = { };
              description = "Grafana Cloud remote write.";
              type = freeform {
                enable = bool false "Whether to remote-write metrics to Grafana Cloud.";
              };
            };
          };
        };

        github-runners = mkOption {
          default = { };
          description = "GitHub Actions runners, used when `services.github-runners = true`.";
          type = freeform {
            configUrl = str "" "GitHub organisation or repository URL.";
            maxRunners = mkOption {
              type = types.int;
              default = 5;
              description = "Maximum number of runners.";
            };
            runnerName = str "self-hosted-linux" "Runner scale set name.";
            nodeSlots = mkOption {
              type = types.attrsOf types.int;
              default = { };
              description = "Runner slots per node name.";
            };
            aptMirror = str "" "APT mirror URL for the runners.";
            githubApp = mkOption {
              type = types.nullOr types.attrs;
              default = null;
              description = "GitHub App `{ appId; installationId; }`. `null` uses a PAT.";
            };
          };
        };

        dockerMirror = mkOption {
          default = { };
          description = "Docker Hub mirror, used when `services.docker-mirror = true`.";
          type = freeform {
            clusterIP = nullOrStr "Fixed ClusterIP of the mirror Service.";
            storageSize = nullOrStr "PVC size of the mirror.";
          };
        };

        traefik = mkOption {
          default = { };
          description = "Traefik.";
          type = freeform {
            dashboard = mkOption {
              default = { };
              description = "Traefik dashboard, used when `services.traefikDashboard = true`.";
              type = freeform {
                enable = bool false "Unused. `services.traefikDashboard` enables the dashboard.";
                host = nullOrStr "Dashboard host. `null` uses `traefik.<subdomain>.<domain>`.";
                middlewares = middlewares "Traefik middlewares of the dashboard.";
                extraAfter = mkOption {
                  type = types.listOf types.str;
                  default = [ ];
                  description = "Extra units that the dashboard setup waits for.";
                };
              };
            };
          };
        };

        gc = mkOption {
          default = { };
          description = "Garbage collection of finished pods, jobs and old ReplicaSets.";
          type = freeform {
            enable = bool false "Whether to run the garbage collector.";
            onCalendar = str "*-*-* 05:00:00" "systemd `OnCalendar` of the run.";
            replicaSetAgeHours = mkOption {
              type = types.int;
              default = 24;
              description = "Minimum age of an empty ReplicaSet.";
            };
            podAgeHours = mkOption {
              type = types.int;
              default = 24;
              description = "Minimum age of a finished pod.";
            };
            jobAgeHours = mkOption {
              type = types.int;
              default = 168;
              description = "Minimum age of a finished job.";
            };
            dryRun = bool false "Whether to only print what would be deleted.";
            excludeNamespaces = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Namespaces to skip.";
            };
          };
        };

        firmwareUpdates = mkOption {
          default = { };
          description = "Firmware updates.";
          type = freeform {
            enable = bool true "Whether to enable fwupd.";
          };
        };

        nodes = mkOption {
          type = types.attrsOf node;
          description = "Cluster nodes. Each key maps to `<hostsPath>/<key>`.";
        };

        nas = mkOption {
          default = { };
          type = types.attrsOf nas;
          description = "NAS servers.";
        };
      };
    };
in
{
  options.cluster = mkOption {
    description = "Cluster-wide configuration, as passed to `mkCluster`.";
    type = types.submodule clusterModule;
  };

  config.assertions = [
    {
      assertion = builtins.deepSeq config.cluster true;
      message = "unreachable: cluster config failed to evaluate";
    }
    {
      assertion =
        config.cluster.kubernetes.loadBalancer != "servicelb" || config.cluster.kubernetes.engine == "k3s";
      message = "kubernetes.loadBalancer = \"servicelb\" requires kubernetes.engine = \"k3s\"";
    }
  ];
}
