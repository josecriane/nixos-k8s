# Flannel CNI for kubeadm engine
# K3s bundles Flannel so this is only needed with kubeadm
{
  config,
  lib,
  pkgs,
  serverConfig,
  ...
}:

let
  k8s = import ../lib.nix { inherit pkgs serverConfig; };
  markerFile = "/var/lib/flannel-setup-done";
  podCidr = (serverConfig.kubernetes or { }).podCidr or "10.42.0.0/16";

  # Pinned version + SHA256 verified at build time by Nix
  flannelVersion = "v0.28.4";
  flannelManifest = pkgs.fetchurl {
    url = "https://github.com/flannel-io/flannel/releases/download/${flannelVersion}/kube-flannel.yml";
    sha256 = "d078019743c5e0194ce965125fc80ef00af0c1661ec9e12396311f1cfec860a2";
  };
in
{
  systemd.services.flannel-setup = {
    description = "Setup Flannel CNI";
    after = [
      "kube-apiserver.service"
      "k3s.service"
    ];
    wants = [
      "kube-apiserver.service"
      "k3s.service"
    ];
    wantedBy = [ "k3s-infrastructure.target" ];
    before = [ "k3s-infrastructure.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      ExecStart = pkgs.writeShellScript "flannel-setup" ''
        ${k8s.libShSource}

        setup_preamble "${markerFile}" "Flannel CNI"
        wait_for_k3s

        echo "Installing Flannel CNI (${flannelVersion})..."

        $KUBECTL apply -f ${flannelManifest}

        echo "Waiting for Flannel pods..."
        for i in $(seq 1 60); do
          READY=$($KUBECTL get pods -n kube-flannel --no-headers 2>/dev/null | grep -c "Running" || echo "0")
          DESIRED=$($KUBECTL get daemonset -n kube-flannel kube-flannel-ds -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
          if [ "$READY" -ge "$DESIRED" ] && [ "$DESIRED" -gt 0 ]; then
            echo "Flannel pods running ($READY/$DESIRED)"
            break
          fi
          echo "Waiting for Flannel pods... ($i/60, running: $READY/$DESIRED)"
          sleep 5
        done

        print_success "Flannel CNI" \
          "CIDR: ${podCidr}" \
          "Backend: VXLAN"

        create_marker "${markerFile}"
      '';
    };
  };
}
