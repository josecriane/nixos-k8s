{
  lib,
  pkgs,
  serverConfig,
  clusterNodes,
  ...
}:

let
  k8s = import ../../lib.nix { inherit pkgs serverConfig; };
  bootstrapNode =
    let
      b = lib.findFirst (n: n.bootstrap or false) null clusterNodes;
    in
    if b != null then b.name else throw "metallb: no bootstrap node found in clusterNodes";

  # MetalLB v0.14+ requires a memberlist secret for speaker pods. It must
  # exist before helm install, and we must NOT regenerate it on re-runs or
  # active speakers break - check existence first.
  preHelm = pkgs.writeShellScript "metallb-pre-helm" ''
    ${k8s.libShSource}
    set -euo pipefail
    wait_for_k3s

    echo "Waiting for CoreDNS to be Ready..."
    $KUBECTL wait --namespace kube-system \
      --for=condition=ready pod \
      --selector=k8s-app=kube-dns \
      --timeout=300s || true

    # MetalLB speaker needs NET_RAW for ARP/NDP; baseline PSS blocks it.
    ensure_namespace metallb-system privileged

    if ! $KUBECTL get secret -n metallb-system metallb-memberlist >/dev/null 2>&1; then
      echo "Creating metallb-memberlist secret..."
      $KUBECTL create secret generic -n metallb-system metallb-memberlist \
        --from-literal=secretkey="$(generate_password 64)"
    fi
  '';

  release = k8s.createHelmRelease {
    name = "metallb";
    namespace = "metallb-system";
    tier = "infrastructure";
    pssLevel = "privileged";
    repo = {
      name = "metallb";
      url = "https://metallb.github.io/metallb";
    };
    chart = "metallb/metallb";
    timeout = "5m";
    manifests = [ ./config.yaml ];
    substitutions = {
      POOL_START = serverConfig.metallbPoolStart;
      POOL_END = serverConfig.metallbPoolEnd;
      BOOTSTRAP_NODE = bootstrapNode;
    };
    extraScript = ''
      echo "Waiting for MetalLB pods to be ready..."
      wait_for_pod metallb-system "app.kubernetes.io/name=metallb"
      echo "IP pool: ${serverConfig.metallbPoolStart}-${serverConfig.metallbPoolEnd}"
    '';
  };
in
lib.recursiveUpdate release {
  systemd.services.metallb-setup = {
    after = (release.systemd.services.metallb-setup.after or [ ]) ++ [
      "k3s.service"
      "k3s-cni-bridge-fixer.service"
    ];
    wants = [
      "k3s.service"
      "k3s-cni-bridge-fixer.service"
    ];
    serviceConfig.ExecStartPre = "${preHelm}";
  };
}
