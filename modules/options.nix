{
  config,
  lib,
  serverConfig,
  ...
}:
let
  inherit (lib) mkOption types;

  defaults = import ./cluster-defaults.nix;

  freeform =
    options:
    types.submodule {
      inherit options;
      freeformType = types.attrs;
    };

  node = types.submodule {
    freeformType = types.attrs;
    options = {
      ip = mkOption { type = types.str; };
      role = mkOption {
        type = types.enum [
          "server"
          "agent"
        ];
      };
      bootstrap = mkOption {
        type = types.bool;
        default = false;
      };
    };
  };
in
{
  options.cluster = mkOption {
    description = "Cluster-wide configuration, as passed to `mkCluster`.";
    type = freeform {
      domain = mkOption { type = types.str; };
      subdomain = mkOption { type = types.str; };
      gateway = mkOption { type = types.str; };
      nameservers = mkOption {
        type = types.listOf types.str;
        default = [ ];
      };
      timezone = mkOption {
        type = types.str;
        default = defaults.timezone;
      };

      useWifi = mkOption {
        type = types.bool;
        default = defaults.useWifi;
      };
      wifiSSID = mkOption {
        type = types.str;
        default = "";
      };

      adminUser = mkOption { type = types.str; };
      adminSSHKeys = mkOption {
        type = types.listOf types.str;
        default = [ ];
      };
      puid = mkOption {
        type = types.int;
        default = defaults.puid;
      };
      pgid = mkOption {
        type = types.int;
        default = defaults.pgid;
      };

      kubernetes = mkOption {
        default = { };
        type = freeform {
          engine = mkOption {
            type = types.enum [
              "k3s"
              "kubeadm"
            ];
            default = defaults.kubernetes.engine;
          };
          cni = mkOption {
            type = types.enum [
              "flannel"
              "calico"
            ];
            default = defaults.kubernetes.cni;
          };
          loadBalancer = mkOption {
            type = types.enum [
              "metallb"
              "servicelb"
            ];
            default = defaults.kubernetes.loadBalancer;
          };
          podCidr = mkOption {
            type = types.str;
            default = defaults.kubernetes.podCidr;
          };
          serviceCidr = mkOption {
            type = types.str;
            default = defaults.kubernetes.serviceCidr;
          };
        };
      };

      certificates = mkOption {
        default = { };
        type = freeform {
          provider = mkOption {
            type = types.enum [
              "acme"
              "manual"
            ];
            default = defaults.certificates.provider;
          };
          restoreFromBackup = mkOption {
            type = types.bool;
            default = defaults.certificates.restoreFromBackup;
          };
        };
      };

      storage = mkOption {
        default = { };
        type = freeform {
          useNFS = mkOption {
            type = types.bool;
            default = defaults.storage.useNFS;
          };
          longhorn = mkOption {
            default = { };
            type = freeform {
              enable = mkOption {
                type = types.bool;
                default = defaults.storage.longhorn.enable;
              };
            };
          };
        };
      };

      services = mkOption {
        default = { };
        type = freeform {
          monitoring = mkOption {
            type = types.bool;
            default = defaults.services.monitoring;
          };
          traefikDashboard = mkOption {
            type = types.bool;
            default = defaults.services.traefikDashboard;
          };
        };
      };

      gc = mkOption {
        default = { };
        type = freeform {
          enable = mkOption {
            type = types.bool;
            default = defaults.gc.enable;
          };
        };
      };

      traefik = mkOption {
        default = { };
        type = freeform {
          dashboard = mkOption {
            default = { };
            type = freeform {
              enable = mkOption {
                type = types.bool;
                default = false;
              };
            };
          };
        };
      };

      nodes = mkOption { type = types.attrsOf node; };

      nas = mkOption {
        default = { };
        type = types.attrsOf (freeform {
          enabled = mkOption {
            type = types.bool;
            default = false;
          };
        });
      };
    };
  };

  config = {
    cluster = serverConfig;

    assertions = [
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
  };
}
