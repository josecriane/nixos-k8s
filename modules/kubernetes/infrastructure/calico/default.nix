# Calico CNI via Tigera operator
# Only installed on bootstrap server (operator manages DaemonSets on all nodes)
{
  lib,
  pkgs,
  serverConfig,
  ...
}:

let
  k8s = import ../../lib.nix { inherit pkgs serverConfig; };
  podCidr = (serverConfig.kubernetes or { }).podCidr or "10.42.0.0/16";

  # Migration: the previous module was named "calico", this one is
  # "tigera-operator". Remove the stale marker so the service lifecycle
  # tracks the new name consistently, and stop the old unit if still loaded.
  preHelm = pkgs.writeShellScript "tigera-operator-pre-helm" ''
    set -euo pipefail
    rm -f /var/lib/calico-setup-done
    systemctl stop calico-setup.service 2>/dev/null || true
  '';

  release = k8s.createHelmRelease {
    name = "tigera-operator";
    namespace = "tigera-operator";
    tier = "infrastructure";
    pssLevel = "privileged";
    repo = {
      name = "projectcalico";
      url = "https://docs.tigera.io/calico/charts";
    };
    chart = "projectcalico/tigera-operator";
    timeout = "10m";
    waitFor = "tigera-operator";
    manifests = [ ./installation.yaml ];
    substitutions = {
      POD_CIDR = podCidr;
    };
    extraScript = ''
      # Calico needs privileged (hostNetwork, NET_ADMIN, hostPath).
      # tigera-operator ns was labeled via pssLevel; label the operator-managed ones too.
      for ns in calico-system calico-apiserver; do
        $KUBECTL create namespace "$ns" --dry-run=client -o yaml | $KUBECTL apply -f -
        $KUBECTL label --overwrite namespace "$ns" \
          pod-security.kubernetes.io/enforce=privileged \
          pod-security.kubernetes.io/warn=privileged \
          pod-security.kubernetes.io/audit=privileged
      done

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

      # Pin Felix to the nftables backend so its rules share the same table
      # kube-proxy writes to. Kernel 6.18 (NixOS 26.05+) no longer ships the
      # legacy ip_tables module; Felix's default "Auto" backend can still
      # pick Legacy and end up with an independent empty table, which makes
      # pod-to-Service DNAT silently drop (DNS and everything behind a
      # ClusterIP stops working on agent nodes).
      echo "Pinning Felix iptablesBackend=NFT..."
      $KUBECTL patch felixconfiguration default --type=merge \
        -p '{"spec":{"iptablesBackend":"NFT"}}' || \
        $KUBECTL apply -f - <<FELIX
      apiVersion: projectcalico.org/v3
      kind: FelixConfiguration
      metadata:
        name: default
      spec:
        iptablesBackend: NFT
      FELIX
    '';
  };
in
lib.recursiveUpdate release {
  systemd.services.tigera-operator-setup = {
    after = (release.systemd.services.tigera-operator-setup.after or [ ]) ++ [
      "kube-apiserver.service"
      "k3s.service"
    ];
    wants = [
      "kube-apiserver.service"
      "k3s.service"
    ];
    # tigera-operator is the CNI installer itself. On first boot the node
    # is NotReady until Calico is rolled out, so wait_for_k3s must skip the
    # Ready check. Subsequent runs are no-ops thanks to the marker hash.
    environment.SKIP_NODE_READY = "1";
    serviceConfig.ExecStartPre = "${preHelm}";
  };

  # When certmgr rotates the ServiceAccount signing key
  # (/var/lib/kubernetes/secrets/service-account.pem), every existing SA
  # token gets invalidated by signature even if its `exp` is still in the
  # future. Calico's cni-config-monitor only refreshes its CNI kubeconfig
  # on a time schedule (~7h between writes), so there's a multi-hour
  # window after the rotation in which /etc/cni/net.d/calico-kubeconfig on
  # each node carries an unauthorized token. During that window
  # `kubectl delete pod` hangs with
  # `Failed to destroy network for sandbox: ... Unauthorized` until the
  # next scheduled refresh, which leaves runner pods stuck in Terminating
  # and ARC unable to scale.
  #
  # Watch the signing cert and roll the calico-node DaemonSet the moment
  # certmgr rewrites it. install-cni in the new pods regenerates the host
  # kubeconfig with a fresh token signed by the current key.
  systemd.paths.calico-cni-token-refresh = {
    description = "Watch SA signing key and refresh Calico CNI tokens";
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathChanged = "/var/lib/kubernetes/secrets/service-account.pem";
      Unit = "calico-cni-token-refresh.service";
    };
  };

  systemd.services.calico-cni-token-refresh = {
    description = "Roll calico-node so CNI kubeconfigs pick up a fresh token";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "calico-cni-token-refresh" ''
        set -eu
        KUBECTL="${pkgs.kubectl}/bin/kubectl --kubeconfig=/etc/kubernetes/cluster-admin.kubeconfig"
        # certmgr restarts kube-apiserver around the rotation, so wait for
        # the API to come back before issuing the rollout.
        for i in $(seq 1 60); do
          $KUBECTL get ns calico-system &>/dev/null && break
          sleep 2
        done
        $KUBECTL -n calico-system rollout restart daemonset/calico-node
      '';
    };
  };
}
