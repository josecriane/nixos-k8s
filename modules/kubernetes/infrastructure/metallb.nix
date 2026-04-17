{
  config,
  lib,
  pkgs,
  serverConfig,
  ...
}:

let
  k8s = import ../lib.nix { inherit pkgs serverConfig; };
  markerFile = "/var/lib/metallb-setup-done";
in
{
  systemd.services.metallb-setup = {
    description = "Setup MetalLB load balancer";
    after = [
      "k3s.service"
      "k3s-cni-bridge-fixer.service"
    ];
    wants = [
      "k3s.service"
      "k3s-cni-bridge-fixer.service"
    ];
    # TIER 1: Infrastructure
    wantedBy = [ "k3s-infrastructure.target" ];
    before = [ "k3s-infrastructure.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      ExecStart = pkgs.writeShellScript "metallb-setup" ''
        ${k8s.libShSource}

        setup_preamble "${markerFile}" "MetalLB"
        wait_for_k3s

        # Verify CoreDNS works (real test that pod networking works)
        echo "Waiting for CoreDNS to be Ready..."
        $KUBECTL wait --namespace kube-system \
          --for=condition=ready pod \
          --selector=k8s-app=kube-dns \
          --timeout=300s || true

        echo "Installing MetalLB with Helm..."

        helm_repo_add metallb https://metallb.github.io/metallb

        # Create memberlist secret for speaker pods (required since MetalLB v0.14+)
        # MetalLB speaker needs NET_RAW for ARP/NDP; baseline PSS blocks it.
        ensure_namespace metallb-system privileged
        $KUBECTL create secret generic -n metallb-system metallb-memberlist \
          --from-literal=secretkey="$(generate_password 64)" \
          --dry-run=client -o yaml | $KUBECTL apply -f -

        helm_install metallb metallb/metallb metallb-system 5m

        echo "Waiting for MetalLB pods to be ready..."
        wait_for_pod metallb-system "app.kubernetes.io/name=metallb"

        echo "Applying MetalLB configuration..."

        cat <<EOF | $KUBECTL apply -f -
        apiVersion: metallb.io/v1beta1
        kind: IPAddressPool
        metadata:
          name: default-pool
          namespace: metallb-system
        spec:
          addresses:
          - ${serverConfig.metallbPoolStart}-${serverConfig.metallbPoolEnd}
        EOF

        cat <<EOF | $KUBECTL apply -f -
        apiVersion: metallb.io/v1beta1
        kind: L2Advertisement
        metadata:
          name: default-l2
          namespace: metallb-system
        spec:
          ipAddressPools:
          - default-pool
        EOF

        print_success "MetalLB" \
          "IP pool: ${serverConfig.metallbPoolStart}-${serverConfig.metallbPoolEnd}"

        create_marker "${markerFile}"
      '';
    };
  };
}
