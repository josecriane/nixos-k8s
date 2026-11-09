{
  config,
  lib,
  ...
}:

let
  cluster = config.cluster;
  net = cluster.network;
  node = cluster.node;
  wifi = cluster.useWifi;
in
{
  networking = {
    hostName = node.name;
    extraHosts = builtins.concatStringsSep "\n" (
      map (n: "${n.ip} ${n.name}") (lib.attrValues cluster.nodes)
    );
    useDHCP = false;
    useNetworkd = true;
    nameservers = lib.optional net.localDnsCache "127.0.0.1" ++ cluster.nameservers;

    getaddrinfo.precedence = {
      "::ffff:0:0/96" = 100;
      "::1/128" = 50;
      "::/0" = 40;
    };

    wireless = lib.mkIf wifi {
      enable = true;
      networks."${cluster.wifiSSID}" = {
        pskRaw = "ext:wifi_psk";
      };
    };
  };

  services.dnsmasq = lib.mkIf net.localDnsCache {
    enable = true;
    settings = {
      cache-size = 1000;
      server = cluster.nameservers ++ net.dnsFallbacks;
      listen-address = "127.0.0.1";
      bind-interfaces = true;
      no-resolv = true;
    }
    // lib.optionalAttrs net.dnsRebindProtection {
      stop-dns-rebind = true;
      rebind-localhost-ok = true;
    };
  };

  systemd.network = {
    enable = true;
    wait-online.enable = false;
    networks."10-lan" = {
      matchConfig.Name = if wifi then "wlan0" else net.interfaceMatch;
      address = [
        "${node.ip}/${toString node.prefixLength}"
      ]
      ++ lib.optional (node.ipv6 != null) "${node.ipv6}/${toString node.ipv6PrefixLength}";
      routes = [
        { Gateway = cluster.gateway; }
      ]
      ++ lib.optional (node.ipv6Gateway != null) {
        Gateway = node.ipv6Gateway;
        GatewayOnLink = true;
      };
      dns = cluster.nameservers;
      linkConfig.RequiredForOnline = "routable";
    }
    // lib.optionalAttrs (!wifi && node.ipv6 == null) {
      networkConfig = {
        LinkLocalAddressing = "ipv4";
        IPv6AcceptRA = false;
      };
    };
  };

  age.secrets.wifi-password = lib.mkIf wifi {
    file = "${cluster.secretsPath}/wifi-password.age";
    path = "/run/secrets/wifi_psk";
  };
}
