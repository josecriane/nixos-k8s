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
}
