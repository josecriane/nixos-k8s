{
  config,
  lib,
  pkgs,
  serverConfig,
  secretsPath,
  ...
}:

let
  adminPasswordFile = "${secretsPath}/admin-password-hash.age";
  hasAdminPassword = builtins.pathExists adminPasswordFile;
  cfg = config.k8s.users;

  # Base NOPASSWD rules every cluster needs: *-setup.service lifecycle,
  # journalctl, marker cleanup, and kubectl (with SETENV when requested).
  systemctlRoot = "/run/current-system/sw/bin/systemctl";
  setupCommands = [
    { command = "${systemctlRoot} status *-setup.service"; options = [ "NOPASSWD" ]; }
    { command = "${systemctlRoot} restart *-setup.service"; options = [ "NOPASSWD" ]; }
    { command = "${systemctlRoot} start *-setup.service"; options = [ "NOPASSWD" ]; }
    { command = "${systemctlRoot} stop *-setup.service"; options = [ "NOPASSWD" ]; }
  ];

  kubectlCommand = {
    command = "/run/current-system/sw/bin/kubectl";
    options = [ "NOPASSWD" ] ++ lib.optional cfg.kubectlSetenv "SETENV";
  };

  journalctlCommand = {
    command = "/run/current-system/sw/bin/journalctl";
    options = [ "NOPASSWD" ];
  };

  markerCommand = {
    command = "/run/current-system/sw/bin/rm -f /var/lib/*-setup-done";
    options = [ "NOPASSWD" ];
  };

  baseSudoCommands = setupCommands ++ [ journalctlCommand markerCommand kubectlCommand ];
in
{
  options.k8s.users = {
    kubectlSetenv = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Grant SETENV on the kubectl sudo rule so KUBECONFIG env is preserved.";
    };

    extraSudoCommands = lib.mkOption {
      type = lib.types.listOf (lib.types.attrsOf lib.types.unspecified);
      default = [ ];
      description = "Extra command entries appended to the wheel sudo rule.";
    };
  };

  config = {
    age.secrets.admin-password-hash = lib.mkIf hasAdminPassword {
      file = adminPasswordFile;
    };

    # Agenix decrypts secrets in an activation script that by default runs AFTER
    # the users activation. hashedPasswordFile would then read a non-existent
    # file and the account gets locked with '!' in /etc/shadow. Force users to wait.
    system.activationScripts.users.deps = lib.mkIf hasAdminPassword [ "agenixInstall" ];

    # Make user management fully declarative so hashedPasswordFile is re-applied
    # on every activation (mutableUsers=true only applies at first create).
    users.mutableUsers = !hasAdminPassword;

    users.users.${serverConfig.adminUser} = {
      isNormalUser = true;
      description = "Server Administrator";
      extraGroups = [ "wheel" ];
      openssh.authorizedKeys.keys = serverConfig.adminSSHKeys;
      shell = pkgs.bash;
    }
    // lib.optionalAttrs hasAdminPassword {
      hashedPasswordFile = config.age.secrets.admin-password-hash.path;
    };

    security.sudo = {
      wheelNeedsPassword = hasAdminPassword;
      extraRules = lib.optionals hasAdminPassword [
        {
          groups = [ "wheel" ];
          commands = baseSudoCommands ++ cfg.extraSudoCommands;
        }
      ];
    };

    # Disable root login
    users.users.root.hashedPassword = "!";
  };
}
