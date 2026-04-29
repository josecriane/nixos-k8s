# NFS mount declarations - imported on ALL nodes
# Ensures every node can access NAS storage for pods scheduled on it
{
  config,
  lib,
  pkgs,
  serverConfig,
  ...
}:

let
  useNFS = serverConfig.storage.useNFS or false;

  enabledNas = lib.filterAttrs (name: cfg: cfg.enabled or false) (serverConfig.nas or { });
  primaryNas = lib.findFirst (
    cfg: (cfg.role or "all") == "media" || (cfg.role or "all") == "all"
  ) null (lib.attrValues enabledNas);

  nfsServer = if primaryNas != null then primaryNas.ip else "";
  nfsExports = if primaryNas != null then (primaryNas.nfsExports or { }) else { };
  nfsPath = nfsExports.nfsPath or "/";

  secondaryNasList = lib.filter (
    cfg: (cfg.enabled or false) && (cfg.mediaPaths or [ ]) != [ ] && cfg != primaryNas
  ) (lib.attrValues (serverConfig.nas or { }));

  nasMountPoint = "/mnt/nas1";
in
{
  # Enable NFS client support
  boot.supportedFilesystems = lib.mkIf useNFS [
    "nfs"
    "nfs4"
  ];
  services.rpcbind.enable = lib.mkIf useNFS true;

  # Mount NAS (nofail so boot continues if NAS is down)
  fileSystems = lib.mkIf useNFS (
    {
      ${nasMountPoint} = {
        device = "${nfsServer}:${nfsPath}";
        fsType = "nfs4";
        options = [
          "rw"
          "noatime"
          "nodiratime"
          "soft"
          "timeo=50"
          "retrans=3"
          "_netdev"
          "nofail"
          "x-systemd.automount"
          "x-systemd.mount-timeout=30"
          "x-systemd.idle-timeout=0"
        ];
      };
    }
    // lib.foldl' (
      acc: nasCfg:
      let
        nasMount = "/mnt/${nasCfg.hostname}";
        nasNfsPath = (nasCfg.nfsExports or { }).nfsPath or "/";
      in
      acc
      // {
        ${nasMount} = {
          device = "${nasCfg.ip}:${nasNfsPath}";
          fsType = "nfs4";
          options = [
            "rw"
            "noatime"
            "nodiratime"
            "soft"
            "timeo=50"
            "retrans=3"
            "_netdev"
            "nofail"
            "x-systemd.automount"
            "x-systemd.mount-timeout=30"
            "x-systemd.idle-timeout=0"
          ];
        };
      }
      // lib.foldl' (
        a: path:
        a
        // {
          "${nasMountPoint}/${path}" = {
            device = "${nasMount}/${path}";
            fsType = "none";
            options = [
              "bind"
              "_netdev"
              "nofail"
            ];
            depends = [
              nasMountPoint
              nasMount
            ];
          };
        }
      ) { } nasCfg.mediaPaths
    ) { } secondaryNasList
  );

  # Auto-heal NFS mounts. Two failure modes are covered:
  #   1. Stale handles: a NAS reboot leaves cached file handles invalid on the
  #      client, surfacing as "Stale file handle" on stat/mkdir. We stat each
  #      active NFS mount with a short timeout and restart its unit on failure.
  #   2. Failed mount units: if the NAS is unreachable while systemd tries to
  #      mount (e.g. the NAS rebooted and the autofs trigger fired before the
  #      server was answering), the mount unit ends up in 'failed' state and
  #      systemd doesn't retry on its own. Bind mounts that depend on it stay
  #      down too. We reset-failed + start each failed mount under /mnt so the
  #      next NAS-up window picks them back up automatically.
  # Only enabled when NFS storage is in use.
  systemd.services.nfs-heal = lib.mkIf useNFS {
    description = "Detect and heal stale or failed NFS mounts";
    serviceConfig = {
      Type = "oneshot";
    };
    path = [
      pkgs.util-linux
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gawk
      pkgs.systemd
    ];
    script = ''
      set -u

      # 1. Stale NFS handles on currently-mounted NFS paths.
      findmnt -l -t nfs,nfs4 -n -o TARGET | while read -r target; do
        case "$target" in /mnt/*) ;; *) continue ;; esac
        if ! timeout 3 stat "$target" >/dev/null 2>&1; then
          unit=$(systemd-escape --path --suffix=mount "$target")
          echo "Stale NFS mount: $target, restarting $unit"
          systemctl restart "$unit" || echo "  failed to restart $unit"
        fi
      done

      # 2. Failed mount units under /mnt (NFS or bind mounts that depend on
      # NFS). Capture the list before we reset-failed, since reset clears the
      # state we filter on. systemd resolves RequiresMountsFor when each is
      # started, so order within the list doesn't matter.
      failed_mounts=$(systemctl --failed --type=mount --no-legend --plain \
        --no-pager 2>/dev/null | awk '{print $1}' | grep '^mnt-' || true)
      if [ -n "$failed_mounts" ]; then
        echo "$failed_mounts" | while read -r unit; do
          [ -z "$unit" ] && continue
          echo "Failed mount unit: $unit, resetting and starting"
          systemctl reset-failed "$unit" 2>/dev/null || true
          systemctl start --no-block "$unit" || \
            echo "  failed to start $unit"
        done
      fi
    '';
  };

  systemd.timers.nfs-heal = lib.mkIf useNFS {
    description = "Periodic NFS stale-handle healing";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5m";
      OnUnitActiveSec = "5m";
      AccuracySec = "30s";
    };
  };
}
