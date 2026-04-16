{
  config,
  lib,
  nodeConfig,
  ...
}:

let
  encryption = nodeConfig.encryption or { };
  enableEncryption = encryption.enable or false;
in
{
  disko.devices = {
    disk = {
      main = {
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            # EFI partition (always unencrypted)
            ESP = {
              size = "512M";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "umask=0077" ];
              };
            };

            # Root partition
            root = {
              size = "100%";
              content =
                if enableEncryption then
                  {
                    type = "luks";
                    name = "cryptroot";
                    settings = {
                      allowDiscards = true;
                      bypassWorkqueues = true;
                    };
                    content = {
                      type = "filesystem";
                      format = "ext4";
                      mountpoint = "/";
                    };
                  }
                else
                  {
                    type = "filesystem";
                    format = "ext4";
                    mountpoint = "/";
                  };
            };
          };
        };
      };
    };
  };
}
