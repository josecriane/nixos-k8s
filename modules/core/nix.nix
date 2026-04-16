{
  config,
  lib,
  pkgs,
  ...
}:

{
  # Enable flakes and new CLI
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    auto-optimise-store = true;

    # Trusted users
    trusted-users = [
      "root"
      "@wheel"
    ];
    allowed-users = [
      "root"
      "@wheel"
    ];
  };

  # Automatic garbage collection
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;
}
