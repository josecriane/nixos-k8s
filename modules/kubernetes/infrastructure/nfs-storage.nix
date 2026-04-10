# NFS Storage PV/PVC creation - imported only on bootstrap server
# Creates K8s PersistentVolumes and PersistentVolumeClaims
{
  config,
  lib,
  pkgs,
  serverConfig,
  nodeConfig,
  ...
}:

let
  k8s = import ../lib.nix { inherit pkgs serverConfig; };
  ns = "default";
  markerFile = "/var/lib/nfs-storage-setup-done";

  useNFS = serverConfig.storage.useNFS or false;

  enabledNas = lib.filterAttrs (name: cfg: cfg.enabled or false) (serverConfig.nas or { });
  primaryNas = lib.findFirst (
    cfg: (cfg.role or "all") == "media" || (cfg.role or "all") == "all"
  ) null (lib.attrValues enabledNas);

  nfsServer = if primaryNas != null then primaryNas.ip else "";
  nfsExports = if primaryNas != null then (primaryNas.nfsExports or { }) else { };
  nfsPath = nfsExports.nfsPath or "/";

  nasMountPoint = "/mnt/nas1";
  localDataPath = "/var/lib/k8s-data";
  hostDataPath = if useNFS then nasMountPoint else localDataPath;

  secondaryMountUnits =
    let
      secondaryNasList = lib.filter (
        cfg: (cfg.enabled or false) && (cfg.mediaPaths or [ ]) != [ ] && cfg != primaryNas
      ) (lib.attrValues (serverConfig.nas or { }));
      pathToMountUnit =
        path: (builtins.replaceStrings [ "/" ] [ "-" ] (lib.removePrefix "/" path)) + ".mount";
    in
    lib.concatMap (
      nasCfg:
      [ (pathToMountUnit "/mnt/${nasCfg.hostname}") ]
      ++ map (path: pathToMountUnit "${nasMountPoint}/${path}") nasCfg.mediaPaths
    ) secondaryNasList;
in
{
  systemd.services.nfs-storage-setup = {
    description = "Setup storage for K8s services";
    after = [
      "k3s-infrastructure.target"
    ]
    ++ lib.optionals useNFS ([ "mnt-nas1.mount" ] ++ secondaryMountUnits);
    requires = [ "k3s-infrastructure.target" ];
    wants = lib.optionals useNFS ([ "mnt-nas1.mount" ] ++ secondaryMountUnits);
    # TIER 2: Storage
    wantedBy = [ "k3s-storage.target" ];
    before = [ "k3s-storage.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      ExecStart = pkgs.writeShellScript "nfs-storage-setup" ''
        ${k8s.libShSource}

        setup_preamble "${markerFile}" "NFS Storage"
        wait_for_k3s

        USE_NFS="${if useNFS then "true" else "false"}"
        HOST_DATA_PATH="${hostDataPath}"
        NFS_SERVER="${nfsServer}"
        NFS_PATH="${nfsPath}"

        echo "Storage mode: $([ "$USE_NFS" = "true" ] && echo "NFS ($NFS_SERVER -> ${nasMountPoint})" || echo "Local ($HOST_DATA_PATH)")"

        ${
          if useNFS then
            ''
              MOUNTPOINT="${pkgs.util-linux}/bin/mountpoint"
              if ! $MOUNTPOINT -q "${nasMountPoint}"; then
                echo "WARN: ${nasMountPoint} not mounted, attempting to mount..."
                mount "${nasMountPoint}" 2>/dev/null || true
                sleep 3
              fi

              if ! $MOUNTPOINT -q "${nasMountPoint}"; then
                echo "ERROR: Could not mount ${nasMountPoint}, using local storage..."
                HOST_DATA_PATH="${localDataPath}"
                USE_NFS="false"
              fi
            ''
          else
            ""
        }

        # Create base directory structure
        echo "Creating directory structure..."
        mkdir -p "$HOST_DATA_PATH/data"
        chmod 775 "$HOST_DATA_PATH/data" 2>/dev/null || true
        echo "Directory structure created at $HOST_DATA_PATH"

        # Create PV + PVC if not already Bound
        EXISTING_STATUS=$($KUBECTL get pvc shared-data -n ${ns} -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [ "$EXISTING_STATUS" = "Bound" ]; then
          echo "PV/PVC shared-data already exists and is Bound, skipping creation"
        else
          if [ "$USE_NFS" = "true" ]; then
            # Multi-node: use NFS PV type (accessible from any node)
            cat <<PVEOF | $KUBECTL apply -f -
        apiVersion: v1
        kind: PersistentVolume
        metadata:
          name: shared-data-pv
          labels:
            type: nfs
        spec:
          capacity:
            storage: 1Ti
          accessModes:
            - ReadWriteMany
          persistentVolumeReclaimPolicy: Retain
          storageClassName: nfs-storage
          nfs:
            server: $NFS_SERVER
            path: $NFS_PATH
        ---
        apiVersion: v1
        kind: PersistentVolumeClaim
        metadata:
          name: shared-data
          namespace: ${ns}
        spec:
          accessModes:
            - ReadWriteMany
          storageClassName: nfs-storage
          resources:
            requests:
              storage: 1Ti
          volumeName: shared-data-pv
        PVEOF
            echo "PV/PVC shared-data created (NFS: $NFS_SERVER:$NFS_PATH)"
          else
            # Single-node: use hostPath with node affinity
            cat <<PVEOF | $KUBECTL apply -f -
        apiVersion: v1
        kind: PersistentVolume
        metadata:
          name: shared-data-pv
          labels:
            type: local
        spec:
          capacity:
            storage: 500Gi
          accessModes:
            - ReadWriteMany
          persistentVolumeReclaimPolicy: Retain
          storageClassName: local-storage
          hostPath:
            path: $HOST_DATA_PATH
            type: DirectoryOrCreate
          nodeAffinity:
            required:
              nodeSelectorTerms:
              - matchExpressions:
                - key: kubernetes.io/hostname
                  operator: In
                  values:
                  - ${nodeConfig.name}
        ---
        apiVersion: v1
        kind: PersistentVolumeClaim
        metadata:
          name: shared-data
          namespace: ${ns}
        spec:
          accessModes:
            - ReadWriteMany
          storageClassName: local-storage
          resources:
            requests:
              storage: 500Gi
          volumeName: shared-data-pv
        PVEOF
            echo "PV/PVC shared-data created (hostPath: $HOST_DATA_PATH, node: ${nodeConfig.name})"
          fi

          echo "Waiting for PVC shared-data to be Bound..."
          for i in $(seq 1 30); do
            STATUS=$($KUBECTL get pvc shared-data -n ${ns} -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
            if [ "$STATUS" = "Bound" ]; then
              echo "PVC shared-data: Bound"
              break
            fi
            echo "  Status: $STATUS ($i/30)"
            sleep 5
          done
        fi

        print_success "NFS Storage" \
          "PVC: shared-data (${ns})" \
          "Data path: $HOST_DATA_PATH"

        create_marker "${markerFile}"
      '';
    };
  };
}
