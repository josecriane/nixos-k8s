{
  config,
  lib,
  pkgs,
  nodeConfig,
  serverConfig,
  ...
}:

let
  isBootstrap = nodeConfig.bootstrap or false;
  engine = (serverConfig.kubernetes or { }).engine or "k3s";
  engineService = if engine == "k3s" then "k3s.service" else "kube-apiserver.service";
in
{
  # All nodes get the infrastructure target
  systemd.targets.k3s-infrastructure = {
    description = "K3s infrastructure services";
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
  systemd.targets.k3s-storage = lib.mkIf isBootstrap {
    description = "K3s storage services";
    wantedBy = [ "multi-user.target" ];
    after = [ "k3s-infrastructure.target" ];
    requires = [ "k3s-infrastructure.target" ];
  };

  systemd.targets.k3s-core = lib.mkIf isBootstrap {
    description = "K3s core services";
    wantedBy = [ "multi-user.target" ];
    after = [ "k3s-storage.target" ];
    requires = [ "k3s-storage.target" ];
  };

  systemd.targets.k3s-apps = lib.mkIf isBootstrap {
    description = "K3s application services";
    wantedBy = [ "multi-user.target" ];
    after = [ "k3s-core.target" ];
    requires = [ "k3s-core.target" ];
  };

  systemd.targets.k3s-extras = lib.mkIf isBootstrap {
    description = "K3s extra services (optional)";
    wantedBy = [ "multi-user.target" ];
    after = [ "k3s-apps.target" ];
    wants = [ "k3s-apps.target" ];
  };
}
