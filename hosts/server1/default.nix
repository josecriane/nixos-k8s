{
  config,
  lib,
  ...
}:

{
  imports = [
    ./hardware-configuration.nix
    ./disk-config.nix
  ];

  # Hostname
  networking.hostName = config.cluster.node.name;

  # Static /etc/hosts for all cluster nodes
  networking.extraHosts = builtins.concatStringsSep "\n" (
    map (n: "${n.ip} ${n.name}") (lib.attrValues config.cluster.nodes)
  );

  # Local DNS cache
  services.dnsmasq = {
    enable = true;
    settings = {
      cache-size = 1000;
      server = config.cluster.nameservers ++ [
        "1.1.1.1"
        "8.8.8.8"
      ];
      listen-address = "127.0.0.1";
      bind-interfaces = true;
      no-resolv = true;
      stop-dns-rebind = true;
      rebind-localhost-ok = true;
    };
  };

  # Network
  networking = {
    useDHCP = false;
    useNetworkd = true;
    nameservers = [ "127.0.0.1" ] ++ config.cluster.nameservers;

    # Prefer IPv4 over IPv6 for outgoing connections
    getaddrinfo.precedence = {
      "::ffff:0:0/96" = 100;
      "::1/128" = 50;
      "::/0" = 40;
    };

    # WiFi or Ethernet depending on configuration
    wireless = lib.mkIf (config.cluster.useWifi) {
      enable = true;
      networks."${config.cluster.wifiSSID}" = {
        pskRaw = "ext:wifi_psk";
      };
    };
  };

  # Static IP
  systemd.network = {
    enable = true;
    wait-online.enable = false;
    networks."10-lan" =
      if (config.cluster.useWifi) then
        {
          matchConfig.Name = "wlan0";
          address = [ "${config.cluster.node.ip}/24" ];
          routes = [ { Gateway = config.cluster.gateway; } ];
          dns = config.cluster.nameservers;
          linkConfig.RequiredForOnline = "routable";
        }
      else
        {
          matchConfig.Name = "en*";
          address = [ "${config.cluster.node.ip}/24" ];
          routes = [ { Gateway = config.cluster.gateway; } ];
          dns = config.cluster.nameservers;
          linkConfig.RequiredForOnline = "routable";
          networkConfig = {
            LinkLocalAddressing = "ipv4";
            IPv6AcceptRA = false;
          };
        };
  };

  # Secret for WiFi password (if using WiFi)
  age.secrets.wifi-password = lib.mkIf (config.cluster.useWifi) {
    file = "${config.cluster.secretsPath}/wifi-password.age";
    path = "/run/secrets/wifi_psk";
  };

  # System state version
  system.stateVersion = "26.05";
}
