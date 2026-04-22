# Standard Kubernetes via NixOS services.kubernetes module
# Uses kubeadm-like declarative setup with automatic PKI
{
  config,
  lib,
  pkgs,
  serverConfig,
  nodeConfig,
  clusterNodes,
  secretsPath,
  ...
}:

let
  k8sCfg = serverConfig.kubernetes or { };
  podCidr = k8sCfg.podCidr or "10.42.0.0/16";
  serviceCidr = k8sCfg.serviceCidr or "10.43.0.0/16";
  cni = k8sCfg.cni or "flannel";

  isServer = nodeConfig.role == "server";
  isAgent = nodeConfig.role == "agent";
  isBootstrap = nodeConfig.bootstrap or false;
  isHA = builtins.length (builtins.filter (n: n.role == "server") clusterNodes) > 1;

  kubeconfigPath = "/etc/kubernetes/cluster-admin.kubeconfig";
in
{
  # Kubernetes cluster via NixOS module
  services.kubernetes = {
    roles =
      if isServer then
        [
          "master"
          "node"
        ]
      else
        [ "node" ];

    masterAddress = nodeConfig.bootstrapIP;
    apiserverAddress = "https://${nodeConfig.bootstrapIP}:6443";

    # PKI: auto-generate on master, distribute CA to workers
    easyCerts = true;

    apiserver = lib.mkIf isServer {
      enable = true;
      advertiseAddress = nodeConfig.ip;
      securePort = 6443;
      serviceClusterIpRange = serviceCidr;
      allowPrivileged = true;
      # NodeRestriction plus front-proxy request header auth. The NixOS
      # services.kubernetes module generates the proxy-client cert but
      # never configures the matching --requestheader-* flags, so any
      # aggregated APIService (Calico via Tigera operator, metrics-server,
      # prometheus-adapter, etc.) rejects proxied requests as user
      # "front-proxy-client" instead of the real ServiceAccount.
      extraOpts = builtins.concatStringsSep " " [
        "--enable-admission-plugins=NodeRestriction"
        "--requestheader-client-ca-file=/var/lib/kubernetes/secrets/ca.pem"
        "--requestheader-allowed-names=front-proxy-client"
        "--requestheader-username-headers=X-Remote-User"
        "--requestheader-group-headers=X-Remote-Group"
        "--requestheader-extra-headers-prefix=X-Remote-Extra-"
      ];
    };

    controllerManager = lib.mkIf isServer {
      enable = true;
      extraOpts = "--cluster-cidr=${podCidr}";
    };

    scheduler.enable = lib.mkIf isServer true;

    kubelet = {
      enable = true;
      extraOpts = builtins.concatStringsSep " " [
        "--node-ip=${nodeConfig.ip}"
        "--system-reserved=cpu=500m,memory=512Mi"
        "--kube-reserved=cpu=500m,memory=512Mi"
        "--eviction-hard=memory.available<256Mi,nodefs.available<10%"
      ];
      kubeconfig = {
        server = "https://${nodeConfig.bootstrapIP}:6443";
      };
      # When the CNI is Calico, also expose its plugin binaries to kubelet.
      # NixOS module recreates /opt/cni/bin on each kubelet restart using
      # these packages; without this the Calico DaemonSet-installed binary
      # gets wiped. nixpkgs' calico-cni-plugin only ships `calico`; Calico
      # also needs `calico-ipam` pointing at the same binary (as the
      # DaemonSet's install step does upstream).
      cni.packages = lib.mkIf (cni == "calico") [
        (pkgs.runCommand "calico-cni-bundle" { } ''
          mkdir -p $out/bin
          ln -s ${pkgs.calico-cni-plugin}/bin/calico $out/bin/calico
          ln -s ${pkgs.calico-cni-plugin}/bin/calico $out/bin/calico-ipam
        '')
      ];
    };

    proxy = {
      enable = true;
    };

    # Disable bundled flannel; CNI comes from cni-flannel.nix or cni-calico.nix.
    # (Default is true and would create a stale /etc/cni/net.d/11-flannel.conf.)
    flannel.enable = false;

    addons.dns = {
      enable = true;
      clusterDomain = "cluster.local";
      corefile = ''
        .:10053 {
          errors
          health :10054
          kubernetes cluster.local in-addr.arpa ip6.arpa {
            pods verified
            fallthrough in-addr.arpa ip6.arpa
          }
          prometheus :10055
          forward . ${builtins.concatStringsSep " " serverConfig.nameservers} {
            policy sequential
          }
          cache 30
          loop
          reload
          loadbalance
        }
      '';
    };

    clusterCidr = podCidr;
  };

  # Container workloads spawned by containerd (DinD sidecars, databases in CI)
  # inherit containerd's rlimits. NixOS defaults are too low (soft nofile=1024),
  # which causes EMFILE inside heavy workloads like MongoDB. Mirror Docker
  # upstream defaults.
  systemd.services.containerd.serviceConfig = {
    LimitNOFILE = "infinity";
    LimitNOFILESoft = "infinity";
    LimitNPROC = "infinity";
  };

  # Firewall
  # API server (6443), scheduler (10259), controller-manager (10257) and
  # kubelet (10250) are NOT in allowedTCPPorts to avoid exposing them globally.
  # They're restricted via extraCommands to cluster nodes + pod/service CIDRs.
  # etcd (2379/2380) only matters for HA and is also restricted below.
  networking.firewall.allowedTCPPorts = [ ];

  networking.firewall.extraCommands =
    let
      sources = lib.concatStringsSep "," (
        (map (n: n.ip) clusterNodes)
        ++ [
          podCidr
          serviceCidr
        ]
      );
    in
    ''
      # Kubelet
      iptables -A nixos-fw -s ${sources} -p tcp --dport 10250 -j nixos-fw-accept
    ''
    + lib.optionalString isServer ''
      # API server, scheduler, controller-manager
      iptables -A nixos-fw -s ${sources} -p tcp -m multiport --dports 6443,10259,10257 -j nixos-fw-accept
    ''
    + lib.optionalString (isServer && isHA) ''
      # etcd peer + client (HA only)
      iptables -A nixos-fw -s ${sources} -p tcp -m multiport --dports 2379,2380 -j nixos-fw-accept
    '';

  networking.firewall.allowedUDPPorts = [
    8472 # VXLAN (Flannel)
  ];

  # Trust CNI interfaces
  networking.firewall.trustedInterfaces = [
    "cni0"
    "flannel.1"
    "cali+"
    "tunl0"
  ];

  # Kernel modules
  boot.kernelModules = [
    "bridge"
    "br_netfilter"
    "veth"
    "overlay"
  ];

  # Sysctl for Kubernetes networking
  boot.kernel.sysctl = {
    "net.bridge.bridge-nf-call-iptables" = lib.mkDefault 1;
    "net.bridge.bridge-nf-call-ip6tables" = lib.mkDefault 1;
    "net.ipv4.ip_forward" = lib.mkDefault 1;
  };

  # Tools
  environment.systemPackages = with pkgs; [
    kubectl
    kubernetes-helm
    k9s
  ];

  # Network check before kubernetes starts
  systemd.services.k8s-network-check = {
    description = "Verify network is ready before Kubernetes starts";
    before = [
      "kube-apiserver.service"
      "kubelet.service"
    ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "k8s-network-check" ''
        set -e

        echo "Verifying network connectivity..."

        IP_READY=false
        for i in $(seq 1 30); do
          if ${pkgs.iproute2}/bin/ip addr show | grep -q "${nodeConfig.ip}"; then
            echo "IP ${nodeConfig.ip} configured"
            IP_READY=true
            break
          fi
          echo "Waiting for IP... ($i/30)"
          sleep 1
        done

        if [ "$IP_READY" = "false" ]; then
          echo "ERROR: IP ${nodeConfig.ip} not configured after 30 seconds"
          exit 1
        fi

        echo "Verifying gateway ${serverConfig.gateway}..."
        for i in $(seq 1 10); do
          if ${pkgs.iputils}/bin/ping -c 1 -W 2 ${serverConfig.gateway} &>/dev/null; then
            echo "Gateway reachable"
            break
          fi
          echo "Waiting for gateway... ($i/10)"
          sleep 2
        done

        ${lib.optionalString (!isBootstrap) ''
          echo "Verifying bootstrap server ${nodeConfig.bootstrapIP}..."
          for i in $(seq 1 15); do
            if ${pkgs.iputils}/bin/ping -c 1 -W 2 ${nodeConfig.bootstrapIP} &>/dev/null; then
              echo "Bootstrap server reachable"
              break
            fi
            echo "Waiting for bootstrap server... ($i/15)"
            sleep 2
          done
        ''}

        echo "Network verified"
      '';
    };
  };

  # Set KUBECONFIG globally and let sudo preserve it so `sudo kubectl` works.
  # The kubeconfig file is root-readable only; do NOT copy it to user home.
  environment.variables.KUBECONFIG = lib.mkIf isServer kubeconfigPath;
  security.sudo.extraConfig = lib.mkIf isServer ''
    Defaults env_keep += "KUBECONFIG"
  '';
}
