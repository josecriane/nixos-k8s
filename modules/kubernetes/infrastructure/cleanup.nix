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

  # Map service toggles to namespaces and marker files
  # Add entries here when you add new services
  serviceMap = {
    # example = {
    #   namespaces = [ "example" ];
    #   markers = [ "example-setup-done" ];
    # };
  };

  disabledServices = lib.filterAttrs (name: _: !(enabled name)) serviceMap;
  hasDisabled = (builtins.length (builtins.attrNames disabledServices)) > 0;

  cleanupCommands = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      name: cfg:
      let
        nsCleanups = lib.concatMapStringsSep "\n" (ns: ''cleanup_namespace "${ns}"'') cfg.namespaces;
        markerCleanups = lib.concatMapStringsSep "\n" (m: ''rm -f "/var/lib/${m}"'') cfg.markers;
        extra = cfg.extraCleanup or "";
      in
      ''
        echo ""
        echo "=== Cleaning disabled service: ${name} ==="
        ${nsCleanups}
        ${extra}
        ${markerCleanups}
      ''
    ) disabledServices
  );

in
{
  systemd.services.k8s-cleanup = lib.mkIf hasDisabled {
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
}
