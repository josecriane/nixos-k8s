{
  lib,
  serverConfig,
  nodeConfig,
  ...
}:

let
  isBootstrap = nodeConfig.bootstrap or false;

  k8sCfg = serverConfig.kubernetes or { };
  engine = k8sCfg.engine or "k3s";
  cni = k8sCfg.cni or "flannel";

  certProvider = serverConfig.certificates.provider or "acme";

  longhornEnabled = serverConfig.storage.longhorn.enable or false;
in
{
  imports = [
    ./nfs-mounts.nix
  ]
  # Engine
  ++ lib.optionals (engine == "k3s") [
    ./k3s.nix
  ]
  ++ lib.optionals (engine == "kubeadm") [
    ./kubeadm.nix
  ]
  # CNI (kubeadm always needs one; k3s only for calico)
  ++ lib.optionals (isBootstrap && engine == "kubeadm" && cni == "flannel") [
    ./cni-flannel.nix
  ]
  ++ lib.optionals (isBootstrap && (cni == "calico") && (engine == "kubeadm" || engine == "k3s")) [
    ./calico
  ]
  # Local path provisioner (kubeadm only, K3s bundles it)
  ++ lib.optionals (isBootstrap && engine == "kubeadm") [
    ./local-path-provisioner.nix
  ]
  # Core infrastructure (bootstrap only)
  ++ lib.optionals isBootstrap [
    ./metallb
    ./traefik
    ./traefik-dashboard
    ./tls-secret
    ./nfs-storage.nix
    ./cleanup.nix
  ]
  # cert-manager (acme only)
  ++ lib.optionals (isBootstrap && certProvider == "acme") [
    ./cert-manager
  ]
  # Longhorn distributed block storage (host prereqs on every node,
  # Helm release on bootstrap only — guarded inside the module)
  ++ lib.optionals longhornEnabled [
    ./longhorn
  ];
}
