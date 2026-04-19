# Automatic cleanup of disabled K8s services
# Always imported - generates cleanup commands only for disabled services
# PVCs are preserved to protect user data
{
  config,
  lib,
  pkgs,
  serverConfig,
  ...
}:

let
  k8s = import ../lib.nix { inherit pkgs serverConfig; };
  svc = serverConfig.services or { };
  enabled = name: svc.${name} or false;

  cfg = config.k8s.cleanup;

  disabledServices = lib.filterAttrs (name: _: !(enabled name)) cfg.serviceMap;
  hasDisabled = (builtins.length (builtins.attrNames disabledServices)) > 0;

  # Disabled services: remove markers so re-enabling re-runs setup.
  # DO NOT delete K8s resources here - service-scaledown scales deployments
  # to 0 replicas instead, preserving manifests and PVCs.
  # extraCleanup handles cross-namespace resources (e.g. traefik middleware)
  # that aren't covered by scale-down.
  cleanupCommands = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      name: svcCfg:
      let
        markerCleanups = lib.concatMapStringsSep "\n" (m: ''rm -f "/var/lib/${m}"'') svcCfg.markers;
        extra = svcCfg.extraCleanup or "";
      in
      ''
        echo ""
        echo "=== Cleaning markers for disabled service: ${name} ==="
        ${extra}
        ${markerCleanups}
      ''
    ) disabledServices
  );
in
{
  options.k8s.cleanup.serviceMap = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          namespaces = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "K8s namespaces owned by this service (informational; scaledown handles resources).";
          };
          markers = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Marker file basenames under /var/lib to remove when the service is disabled.";
          };
          extraCleanup = lib.mkOption {
            type = lib.types.lines;
            default = "";
            description = "Extra bash commands to run for cross-namespace cleanup when disabled.";
          };
        };
      }
    );
    default = { };
    description = ''
      Map of service toggle name -> cleanup spec. When a toggle in
      `serverConfig.services.<name>` is false, the service's markers are
      removed and extraCleanup runs. K8s resources are left untouched here
      (scaledown handles them to preserve PVCs).
    '';
  };

  config = lib.mkIf hasDisabled {
    systemd.services.k8s-cleanup = {
      description = "Cleanup disabled K8s services";
      after = [ "k3s-infrastructure.target" ];
      requires = [ "k3s-infrastructure.target" ];
      wantedBy = [ "k3s-storage.target" ];
      before = [ "k3s-storage.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "k8s-cleanup" ''
          ${k8s.libShSource}
          set -e

          echo "Starting cleanup of disabled services..."
          wait_for_k3s

          ${cleanupCommands}

          echo ""
          echo "Cleanup of disabled services completed"
        '';
      };
    };
  };
}
