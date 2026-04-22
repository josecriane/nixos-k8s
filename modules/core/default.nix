{
  config,
  lib,
  pkgs,
  serverConfig,
  ...
}:

{
  imports = [
    ./nix.nix
    ./users.nix
    ./ssh.nix
    ./security.nix
    ./encryption.nix
    ./smart.nix
  ];

  # Timezone and locale
  time.timeZone = serverConfig.timezone;
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = {
    LC_TIME = "en_US.UTF-8";
  };

  # Base system packages
  environment.systemPackages = with pkgs; [
    vim
    git
    curl
    wget
    htop
    btop
    tmux
    jq
    yq-go
    tree
    ncdu
    duf
    ripgrep
    fd
    smartmontools
  ];

  # Firmware updates
  services.fwupd.enable = true;

  # Disable graphical interface
  services.xserver.enable = false;

  # Swap - disabled when using kubeadm (kubelet doesn't support swap by default)
  swapDevices = lib.mkIf ((serverConfig.kubernetes.engine or "k3s") != "kubeadm") [
    {
      device = "/swapfile";
      size = 16384;
    }
  ];

  # Enable documentation
  documentation.enable = true;
  documentation.man.enable = true;
}
