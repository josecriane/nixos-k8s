# Calico CNI via Tigera operator
# Only installed on bootstrap server (operator manages DaemonSets on all nodes)
{
  config,
  lib,
  pkgs,
  serverConfig,
  ...
}:

let
  k8s = import ../lib.nix { inherit pkgs serverConfig; };
  markerFile = "/var/lib/calico-setup-done";
  podCidr = (serverConfig.kubernetes or { }).podCidr or "10.42.0.0/16";
in
{
  systemd.services.calico-setup = {
    description = "Setup Calico CNI via Tigera operator";
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
      ExecStart = pkgs.writeShellScript "calico-setup" ''
        ${k8s.libShSource}

        setup_preamble "${markerFile}" "Calico CNI"
        wait_for_k3s

        echo "Installing Tigera operator..."

        helm_repo_add projectcalico https://docs.tigera.io/calico/charts

        helm_install tigera-operator projectcalico/tigera-operator tigera-operator 10m

        echo "Waiting for Tigera operator to be ready..."
        wait_for_deployment tigera-operator tigera-operator 300

        # Create Calico Installation resource
        echo "Creating Calico Installation..."
        cat <<EOF | $KUBECTL apply -f -
        apiVersion: operator.tigera.io/v1
        kind: Installation
        metadata:
          name: default
        spec:
          calicoNetwork:
            ipPools:
            - cidr: ${podCidr}
              encapsulation: VXLANCrossSubnet
              natOutgoing: Enabled
              nodeSelector: all()
        EOF

        # Calico needs privileged (hostNetwork, NET_ADMIN, hostPath).
        for ns in tigera-operator calico-system calico-apiserver; do
          $KUBECTL create namespace "$ns" --dry-run=client -o yaml | $KUBECTL apply -f -
          $KUBECTL label --overwrite namespace "$ns" \
            pod-security.kubernetes.io/enforce=privileged \
            pod-security.kubernetes.io/warn=privileged \
            pod-security.kubernetes.io/audit=privileged
        done

        # Wait for calico-system pods
        echo "Waiting for Calico pods..."
        for i in $(seq 1 60); do
          READY=$($KUBECTL get pods -n calico-system --no-headers 2>/dev/null | grep -c "Running" || echo "0")
          if [ "$READY" -ge 2 ]; then
            echo "Calico pods running ($READY)"
            break
          fi
          echo "Waiting for Calico pods... ($i/60, running: $READY)"
          sleep 5
        done

        print_success "Calico CNI" \
          "Operator: tigera-operator" \
          "CIDR: ${podCidr}" \
          "Encapsulation: VXLANCrossSubnet"

        create_marker "${markerFile}"
      '';
    };
  };
}
