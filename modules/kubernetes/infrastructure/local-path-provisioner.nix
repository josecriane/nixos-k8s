# Local Path Provisioner for kubeadm clusters
# K3s bundles this, kubeadm does not.
# Provides a default StorageClass using hostPath volumes.
{
  config,
  lib,
  pkgs,
  serverConfig,
  ...
}:

let
  k8s = import ../lib.nix { inherit pkgs serverConfig; };
  markerFile = "/var/lib/local-path-provisioner-setup-done";
in
{
  systemd.services.local-path-provisioner-setup = {
    description = "Setup Local Path Provisioner";
    after = [
      "kube-apiserver.service"
      "kubelet.service"
    ];
    wants = [
      "kube-apiserver.service"
      "kubelet.service"
    ];
    # TIER 1: Infrastructure (needed before storage tier)
    wantedBy = [ "k3s-infrastructure.target" ];
    before = [ "k3s-infrastructure.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      ExecStart = pkgs.writeShellScript "local-path-provisioner-setup" ''
        ${k8s.libShSource}

        setup_preamble "${markerFile}" "Local Path Provisioner"
        wait_for_k3s

        echo "Installing Local Path Provisioner..."

        $KUBECTL apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml

        echo "Waiting for Local Path Provisioner to be ready..."
        wait_for_pod local-path-storage "app=local-path-provisioner"

        echo "Setting local-path as default StorageClass..."
        $KUBECTL patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

        print_success "Local Path Provisioner" \
          "StorageClass: local-path (default)" \
          "Storage path: /opt/local-path-provisioner"

        create_marker "${markerFile}"
      '';
    };
  };
}
