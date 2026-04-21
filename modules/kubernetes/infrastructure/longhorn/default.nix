{
  lib,
  pkgs,
  serverConfig,
  nodeConfig,
  ...
}:

let
  k8s = import ../../lib.nix { inherit pkgs serverConfig; };
  isBootstrap = nodeConfig.bootstrap or false;

  longhornCfg = serverConfig.storage.longhorn or { };
  replicaCount = longhornCfg.replicaCount or 2;
  defaultClass = longhornCfg.defaultStorageClass or false;
  ingressCfg = longhornCfg.ingress or null;

  release = k8s.createHelmRelease {
    name = "longhorn";
    namespace = "longhorn-system";
    tier = "storage";
    pssLevel = "privileged";
    repo = {
      name = "longhorn";
      url = "https://charts.longhorn.io";
    };
    chart = "longhorn/longhorn";
    timeout = "15m";
    valuesFile = ./values.yaml;
    substitutions = {
      DEFAULT_REPLICA_COUNT = toString replicaCount;
      DEFAULT_CLASS = if defaultClass then "true" else "false";
    };
    ingress =
      if ingressCfg != null then
        {
          host = ingressCfg.host;
          service = "longhorn-frontend";
          port = 80;
        }
      else
        null;
    middlewares = ingressCfg.middlewares or [ ];
    extraScript = ''
      echo "Waiting for Longhorn manager DaemonSet..."
      wait_for_pod longhorn-system "app=longhorn-manager"
      echo "Replica count: ${toString replicaCount}"
      echo "Default StorageClass: ${if defaultClass then "yes" else "no"}"
    ''
    + lib.optionalString defaultClass ''

      # When Longhorn is the default StorageClass, k3s's local-path must stop
      # being default (two default StorageClasses cause unpredictable PVC binding).
      if $KUBECTL get storageclass local-path >/dev/null 2>&1; then
        echo "Unsetting default annotation from local-path StorageClass..."
        $KUBECTL patch storageclass local-path \
          -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
      fi
      echo "Current StorageClasses:"
      $KUBECTL get storageclass
    '';
  };
in
lib.mkMerge [
  # Host-level prerequisites applied to every node so Longhorn can schedule
  # volume replicas anywhere. The manager runs as a DaemonSet and every
  # worker node needs open-iscsi + kernel modules to attach block devices.
  {
    services.openiscsi = {
      enable = true;
      name = "iqn.2025-01.homelab:${nodeConfig.name or "node"}";
    };

    boot.kernelModules = [
      "iscsi_tcp"
      "nfs"
      "nfsv4"
      "dm_crypt"
    ];

    environment.systemPackages = [
      pkgs.openiscsi
      pkgs.nfs-utils
    ];

    # Longhorn manager uses `nsenter` to run iscsiadm inside the host mount
    # namespace and resolves the binary through the container's PATH
    # (typically /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:...).
    # NixOS places binaries under /run/current-system/sw/bin which isn't in
    # that PATH, so we expose the needed host utilities at well-known paths.
    systemd.tmpfiles.rules = [
      "L+ /usr/local/sbin/iscsiadm - - - - ${pkgs.openiscsi}/bin/iscsiadm"
      "L+ /usr/local/bin/mount.nfs - - - - ${pkgs.nfs-utils}/bin/mount.nfs"
      "L+ /usr/local/bin/mount.nfs4 - - - - ${pkgs.nfs-utils}/bin/mount.nfs4"
    ];
  }
  # Helm release installed once from the bootstrap node.
  (lib.mkIf isBootstrap release)
]
