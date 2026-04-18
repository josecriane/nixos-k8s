# Disk encryption unlock configuration
# Supports two unlock methods:
#   - "ssh": SSH server in initrd, connect remotely to type the passphrase
#   - "tpm": Automatic unlock via TPM2 (no manual intervention, but tied to hardware)
{
  config,
  lib,
  pkgs,
  nodeConfig,
  serverConfig,
  ...
}:

let
  encryption = nodeConfig.encryption or { };
  enableEncryption = encryption.enable or false;
  unlockMethod = encryption.unlock or "ssh"; # "ssh" or "tpm"
  initrdSSHPort = encryption.sshPort or 2222;
in
lib.mkIf enableEncryption {

  boot.initrd.systemd.enable = true;

  # Initrd SSH is always enabled when encryption is on.
  # - unlock=ssh: primary unlock channel.
  # - unlock=tpm: fallback before TPM is enrolled (first boot after install)
  #   and when TPM unlock fails (firmware update, PCR drift, disk moved).
  boot.initrd.network = {
    enable = true;

    ssh = {
      enable = true;
      port = initrdSSHPort;
      authorizedKeys = serverConfig.adminSSHKeys;
      # Host keys for initrd SSH (generated on first boot, stored persistently)
      hostKeys = [
        "/etc/ssh/ssh_host_ed25519_key"
      ];
    };
  };

  # systemd-networkd in initrd for static IP
  boot.initrd.systemd.network = {
    enable = true;
    networks."10-lan" = {
      matchConfig.Name = "en*";
      address = [ "${nodeConfig.ip}/24" ];
      routes = [ { Gateway = serverConfig.gateway; } ];
    };
  };

  # TPM2 auto-unlock: after first install, enroll the TPM key with:
  #   make enroll-tpm NODE=<name>
  # This binds the key to the current firmware + secure boot state.
  # The passphrase remains as fallback if TPM unlock fails.
  environment.systemPackages = lib.mkIf (unlockMethod == "tpm") [
    pkgs.tpm2-tss
  ];
}
