{
  config,
  lib,
  pkgs,
  serverConfig,
  secretsPath,
  ...
}:

{
  age.secrets.admin-password-hash = {
    file = "${secretsPath}/admin-password-hash.age";
  };

  # Agenix decrypts secrets in an activation script that by default runs AFTER
  # the users activation. hashedPasswordFile would then read a non-existent file
  # and the account gets locked with '!' in /etc/shadow. Force users to wait.
  system.activationScripts.users.deps = [ "agenixInstall" ];

  # Make user management fully declarative so hashedPasswordFile is re-applied
  # on every activation (with mutableUsers=true it only applies at first create).
  users.mutableUsers = false;

  users.users.${serverConfig.adminUser} = {
    isNormalUser = true;
    description = "Server Administrator";
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = serverConfig.adminSSHKeys;
    shell = pkgs.bash;
    hashedPasswordFile = config.age.secrets.admin-password-hash.path;
  };

  security.sudo = {
    # Always require password for interactive sudo.
    # Specific commands used by the Makefile/scripts are NOPASSWD below.
    wheelNeedsPassword = true;
    extraRules = [
      {
        groups = [ "wheel" ];
        commands = [
          # Limit systemctl NOPASSWD to *-setup.service units used by `make reinstall`.
          # Do NOT include sshd, fail2ban, networking, etc.
          {
            command = "/run/current-system/sw/bin/systemctl status *-setup.service";
            options = [ "NOPASSWD" ];
          }
          {
            command = "/run/current-system/sw/bin/systemctl restart *-setup.service";
            options = [ "NOPASSWD" ];
          }
          {
            command = "/run/current-system/sw/bin/systemctl start *-setup.service";
            options = [ "NOPASSWD" ];
          }
          {
            command = "/run/current-system/sw/bin/systemctl stop *-setup.service";
            options = [ "NOPASSWD" ];
          }
          {
            command = "/run/current-system/sw/bin/journalctl";
            options = [ "NOPASSWD" ];
          }
          # make reinstall: clear service markers
          {
            command = "/run/current-system/sw/bin/rm -f /var/lib/*-setup-done";
            options = [ "NOPASSWD" ];
          }
          {
            command = "${pkgs.kubectl}/bin/kubectl";
            options = [ "NOPASSWD" ];
          }
          # Note: nixos-rebuild --sudo wraps commands in `sh -c ...` which is not in this
          # NOPASSWD list on purpose (allowing `sh` would be equivalent to passwordless root).
          # `make deploy` will ask for the admin password once per deploy (via NIX_SSHOPTS=-tt).
        ];
      }
    ];
  };

  # Disable root login
  users.users.root.hashedPassword = "!";
}
