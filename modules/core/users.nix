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
in
{
  age.secrets.admin-password-hash = lib.mkIf hasAdminPassword {
    file = adminPasswordFile;
  };

  users.users.${serverConfig.adminUser} = {
    isNormalUser = true;
    description = "Server Administrator";
    extraGroups = [
      "wheel"
    ];
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
        commands = [
          {
            command = "/run/current-system/sw/bin/nixos-rebuild";
            options = [ "NOPASSWD" ];
          }
          {
            command = "/run/current-system/sw/bin/systemctl status *";
            options = [ "NOPASSWD" ];
          }
          {
            command = "/run/current-system/sw/bin/systemctl restart *";
            options = [ "NOPASSWD" ];
          }
          {
            command = "/run/current-system/sw/bin/systemctl start *";
            options = [ "NOPASSWD" ];
          }
          {
            command = "/run/current-system/sw/bin/systemctl stop *";
            options = [ "NOPASSWD" ];
          }
          {
            command = "/run/current-system/sw/bin/journalctl";
            options = [ "NOPASSWD" ];
          }
          {
            command = "${pkgs.kubectl}/bin/kubectl";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];
  };

  # Disable root login
  users.users.root.hashedPassword = "!";
}
