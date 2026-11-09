# Automatic cleanup of disabled K8s services
# Removes the markers of setup units that no longer exist, so re-enabling a
# service re-runs its setup, and runs extraCleanup for disabled services.
# PVCs are preserved to protect user data
{
  k8s,
  config,
  lib,
  pkgs,
  ...
}:

let
  svc = config.cluster.services;
  enabled = name: svc.${name} or false;

  cfg = config.k8s.cleanup;

  disabledServices = lib.filterAttrs (name: _: !(enabled name)) cfg.serviceMap;

  setupUnits = lib.filter (lib.hasSuffix "-setup") (lib.attrNames config.systemd.services);

  extraCleanups = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (name: svcCfg: ''
      echo ""
      echo "=== Extra cleanup for disabled service: ${name} ==="
      ${svcCfg.extraCleanup}
    '') disabledServices
  );
in
{
  options.k8s.cleanup.serviceMap = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options.extraCleanup = lib.mkOption {
          type = lib.types.lines;
          default = "";
          description = "Bash commands that remove cross-namespace resources when the service is disabled.";
        };
      }
    );
    default = { };
    description = ''
      Map of service toggle name -> cleanup spec. When a toggle in
      `config.cluster.services.<name>` is false, its extraCleanup runs.
      K8s resources are left untouched here (scaledown handles them to
      preserve PVCs).
    '';
  };

  config.systemd.services.k8s-cleanup = lib.mkIf config.cluster.isBootstrap {
    description = "Cleanup disabled K8s services";
    after = [ "k3s-infrastructure.target" ];
    requires = [ "k3s-infrastructure.target" ];
    wantedBy = [ "k3s-storage.target" ];
    before = [ "k3s-storage.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "k8s-cleanup" (
        ''
          ${k8s.libShSource}
          set -e

          declare -A SETUP_UNITS=(${lib.concatMapStringsSep " " (u: "[${u}]=1") setupUnits})

          for marker in /var/lib/*-setup-done; do
            [ -e "$marker" ] || continue
            unit=$(basename "$marker" -done)
            if [ -z "''${SETUP_UNITS[$unit]:-}" ]; then
              echo "Removing marker of a unit that no longer exists: $marker"
              rm -f "$marker"
            fi
          done
        ''
        + lib.optionalString (extraCleanups != "") ''

          wait_for_k3s
          ${extraCleanups}
        ''
      );
    };
  };
}
