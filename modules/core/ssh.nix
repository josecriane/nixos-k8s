{
  config,
  lib,
  pkgs,
  ...
}:

{
  # SSH Server
  services.openssh = {
    enable = true;
    ports = [ 22 ];

    settings = {
      # Key-only authentication
      PasswordAuthentication = false;
      PermitRootLogin = "no";
      KbdInteractiveAuthentication = false;

      # Additional security
      X11Forwarding = false;
      PermitEmptyPasswords = false;
      MaxAuthTries = 3;

      # Keep connection alive
      ClientAliveInterval = 60;
      ClientAliveCountMax = 3;

      # Restrict to modern algorithms
      KexAlgorithms = [
        "mlkem768x25519-sha256"
        "curve25519-sha256"
        "curve25519-sha256@libssh.org"
        "diffie-hellman-group16-sha512"
      ];
      Ciphers = [
        "chacha20-poly1305@openssh.com"
        "aes256-gcm@openssh.com"
        "aes128-gcm@openssh.com"
      ];
      Macs = [
        "hmac-sha2-256-etm@openssh.com"
        "hmac-sha2-512-etm@openssh.com"
        "umac-128-etm@openssh.com"
      ];
    };
  };

  # Open SSH port in firewall
  networking.firewall.allowedTCPPorts = [ 22 ];
}
