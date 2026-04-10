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

  # ============================================
  # SSH UNLOCK (connect to initrd to type passphrase)
  # ============================================

  boot.initrd.network = lib.mkIf (unlockMethod == "ssh") {
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
  boot.initrd.systemd.network = lib.mkIf (unlockMethod == "ssh") {
    enable = true;
    networks."10-lan" = {
      matchConfig.Name = "en*";
      address = [ "${nodeConfig.ip}/24" ];
      routes = [ { Gateway = serverConfig.gateway; } ];
    };
  };

  # ============================================
  # TPM UNLOCK (automatic, no manual intervention)
  # ============================================

  # TPM2 auto-unlock: after first install, enroll the TPM key with:
  #   sudo systemd-cryptenroll /dev/disk/by-partlabel/disk-main-root --tpm2-device=auto --tpm2-pcrs=0+7
  # This binds the key to the current firmware + secure boot state.
  # The passphrase remains as fallback if TPM unlock fails.

  boot.initrd.systemd.enable = true;

  environment.systemPackages = lib.mkIf (unlockMethod == "tpm") [
    pkgs.tpm2-tss
  ];
}
