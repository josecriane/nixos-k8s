{
  # Each category's default.nix handles its own conditional loading based on
  # nodeConfig.bootstrap, serverConfig.kubernetes.engine/cni, and
  # serverConfig.services toggles.
  imports = [
    ./systemd-targets.nix
    ./apps
    ./infrastructure
  ];
}
