{
  config,
  lib,
  ...
}:

let
  isBootstrap = config.cluster.isBootstrap;
  engine = config.cluster.kubernetes.engine;
  engineService = if engine == "k3s" then "k3s.service" else "kube-apiserver.service";
in
{
  # All nodes get the infrastructure target
  systemd.targets.k8s-infrastructure = {
    description = "Kubernetes infrastructure services";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network-online.target"
      engineService
    ];
    wants = [
      "network-online.target"
      engineService
    ];
  };

  # Higher-level targets only on the bootstrap server
  systemd.targets.k8s-storage = lib.mkIf isBootstrap {
    description = "Kubernetes storage services";
    wantedBy = [ "multi-user.target" ];
    after = [ "k8s-infrastructure.target" ];
    requires = [ "k8s-infrastructure.target" ];
  };

  systemd.targets.k8s-core = lib.mkIf isBootstrap {
    description = "Kubernetes core services";
    wantedBy = [ "multi-user.target" ];
    after = [ "k8s-storage.target" ];
    requires = [ "k8s-storage.target" ];
  };

  systemd.targets.k8s-apps = lib.mkIf isBootstrap {
    description = "Kubernetes application services";
    wantedBy = [ "multi-user.target" ];
    after = [ "k8s-core.target" ];
    requires = [ "k8s-core.target" ];
  };

  systemd.targets.k8s-extras = lib.mkIf isBootstrap {
    description = "Kubernetes extra services (optional)";
    wantedBy = [ "multi-user.target" ];
    after = [ "k8s-apps.target" ];
    wants = [ "k8s-apps.target" ];
  };
}
