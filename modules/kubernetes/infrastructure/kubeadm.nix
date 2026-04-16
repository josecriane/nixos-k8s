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
      extraOpts = "--enable-admission-plugins=NodeRestriction";
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
    };

    proxy = {
      enable = true;
    };

    addons.dns = {
      enable = true;
      clusterDomain = "cluster.local";
      corefile = ''
        .:10053 {
          errors
          health :10054
          kubernetes cluster.local in-addr.arpa ip6.arpa {
            pods insecure
            fallthrough in-addr.arpa ip6.arpa
          }
          prometheus :10055
          forward . ${builtins.concatStringsSep " " serverConfig.nameservers}
          cache 30
          loop
          reload
          loadbalance
        }
      '';
    };

    clusterCidr = podCidr;
  };

  # Firewall
  networking.firewall.allowedTCPPorts = [
    10250
  ] # kubelet
  ++ lib.optionals isServer [
    6443 # API server
    10259 # scheduler
    10257 # controller-manager
  ]
  ++ lib.optionals (isServer && isHA) [
    2379 # etcd client
    2380 # etcd peer
  ];

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

  # Setup kubeconfig for admin user (servers only)
  systemd.services.kubeconfig-setup = lib.mkIf isServer {
    description = "Setup kubeconfig for admin user";
    after = [ "kube-apiserver.service" ];
    wants = [ "kube-apiserver.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "setup-kubeconfig" ''
        # Wait for API server to generate kubeconfig
        for i in $(seq 1 60); do
          if [ -f "${kubeconfigPath}" ]; then
            break
          fi
          sleep 2
        done

        if [ -f "${kubeconfigPath}" ]; then
          mkdir -p /home/${serverConfig.adminUser}/.kube
          cp "${kubeconfigPath}" /home/${serverConfig.adminUser}/.kube/config
          chown ${serverConfig.adminUser}:users /home/${serverConfig.adminUser}/.kube/config
          chmod 600 /home/${serverConfig.adminUser}/.kube/config
        else
          echo "WARNING: kubeconfig not found at ${kubeconfigPath}"
        fi
      '';
    };
  };
}
