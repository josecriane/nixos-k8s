{
  k8s,
  config,
  lib,
  ...
}:

let
  bootstrapNode = config.cluster.bootstrapNode.name;

  # MetalLB v0.14+ requires a memberlist secret for speaker pods. It must
  # exist before helm install, and we must NOT regenerate it on re-runs or
  # active speakers break - check existence first.
  prepare = ''
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

  release = {
    inherit prepare;
    after = [
      "k3s.service"
      "k3s-cni-bridge-fixer.service"
    ];
    namespace = "metallb-system";
    tier = "infrastructure";
    pssLevel = "privileged";
    repo = {
      name = "metallb";
      url = "https://metallb.github.io/metallb";
    };
    chart = "metallb/metallb";
    timeout = "5m";
    values.frrk8s.enabled = false;
    manifests = [ ./config.yaml ];
    substitutions = {
      POOL_START = config.cluster.metallbPoolStart;
      POOL_END = config.cluster.metallbPoolEnd;
      BOOTSTRAP_NODE = bootstrapNode;
    };
    postInstall = ''
      echo "Waiting for MetalLB pods to be ready..."
      wait_for_pod metallb-system "app.kubernetes.io/name=metallb"
      echo "IP pool: ${config.cluster.metallbPoolStart}-${config.cluster.metallbPoolEnd}"
    '';
  };
in
lib.mkIf (config.cluster.isBootstrap && config.cluster.kubernetes.loadBalancer == "metallb") {
  k8s.helmReleases.metallb = release;
}
