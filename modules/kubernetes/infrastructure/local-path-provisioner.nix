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

  # Pinned version + SHA256 verified at build time by Nix
  lppVersion = "v0.0.30";
  lppManifest = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/rancher/local-path-provisioner/${lppVersion}/deploy/local-path-storage.yaml";
    sha256 = "fe682186b00400fe7e2b72bae16f63e47a56a6dcc677938c6642139ef670045e";
  };
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

        echo "Installing Local Path Provisioner (${lppVersion})..."

        $KUBECTL apply -f ${lppManifest}

        # Uses hostPath volumes; baseline PSS blocks them.
        ensure_namespace local-path-storage privileged

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
