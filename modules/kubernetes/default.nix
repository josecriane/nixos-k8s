{
  config,
  lib,
  pkgs,
  serverConfig,
  nodeConfig,
  ...
}:

let
  isServer = nodeConfig.role == "server";
  isBootstrap = nodeConfig.bootstrap or false;

  k8sCfg = serverConfig.kubernetes or { };
  engine = k8sCfg.engine or "k3s";
  cni = k8sCfg.cni or "flannel";

  certProvider = serverConfig.certificates.provider or "acme";

  svc = serverConfig.services or { };
  enabled = name: svc.${name} or false;
in
{
  imports = [
    ./systemd-targets.nix
    ./infrastructure/nfs-mounts.nix
  ]
  # Engine
  ++ lib.optionals (engine == "k3s") [
    ./infrastructure/k3s.nix
  ]
  ++ lib.optionals (engine == "kubeadm") [
    ./infrastructure/kubeadm.nix
  ]
  # CNI (kubeadm always needs one; k3s only for calico)
  ++ lib.optionals (isBootstrap && engine == "kubeadm" && cni == "flannel") [
    ./infrastructure/cni-flannel.nix
  ]
  ++ lib.optionals (isBootstrap && (cni == "calico") && (engine == "kubeadm" || engine == "k3s")) [
    ./infrastructure/cni-calico.nix
  ]
  # Local path provisioner (kubeadm only, K3s bundles it)
  ++ lib.optionals (isBootstrap && engine == "kubeadm") [
    ./infrastructure/local-path-provisioner.nix
  ]
  # Infrastructure (bootstrap only)
  ++ lib.optionals isBootstrap [
    ./infrastructure/metallb.nix
    ./infrastructure/traefik.nix
    ./infrastructure/tls-secret.nix
    ./infrastructure/nfs-storage.nix
    ./infrastructure/cleanup.nix
  ]
  # cert-manager (acme only)
  ++ lib.optionals (isBootstrap && certProvider == "acme") [
    ./infrastructure/cert-manager.nix
  ]
  # --- Application services (bootstrap only, toggled via config.nix) ---
  ++ lib.optionals (isBootstrap && (enabled "docker-registry")) [
    ./apps/docker-registry.nix
  ]
  ++ lib.optionals (isBootstrap && (enabled "docker-mirror")) [
    ./apps/docker-mirror.nix
  ]
  ++ lib.optionals (isBootstrap && (enabled "github-runners")) [
    ./apps/github-runners.nix
  ];
}
