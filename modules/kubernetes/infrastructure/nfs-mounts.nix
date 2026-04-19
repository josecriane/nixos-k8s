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

  # Auto-heal stale NFS handles: NAS reboots leave cached file handles invalid
  # on the client side, surfacing as "Stale file handle" on stat/mkdir. A periodic
  # check stats each NFS mount with a short timeout and restarts its mount unit
  # on failure. Only enabled when NFS storage is in use.
  systemd.services.nfs-heal = lib.mkIf useNFS {
    description = "Detect and heal stale NFS mounts";
    serviceConfig = {
      Type = "oneshot";
    };
    path = [
      pkgs.util-linux
      pkgs.coreutils
      pkgs.systemd
    ];
    script = ''
      set -u
      findmnt -l -t nfs,nfs4 -n -o TARGET | while read -r target; do
        case "$target" in /mnt/*) ;; *) continue ;; esac
        if ! timeout 3 stat "$target" >/dev/null 2>&1; then
          unit=$(systemd-escape --path --suffix=mount "$target")
          echo "Stale NFS mount: $target, restarting $unit"
          systemctl restart "$unit" || echo "  failed to restart $unit"
        fi
      done
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
