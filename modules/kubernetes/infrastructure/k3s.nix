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
  isServer = nodeConfig.role == "server";
  isAgent = nodeConfig.role == "agent";
  isBootstrap = nodeConfig.bootstrap or false;
  isHA = builtins.length (builtins.filter (n: n.role == "server") clusterNodes) > 1;
  k8sCfg = serverConfig.kubernetes or { };
  cni = k8sCfg.cni or "flannel";
  podCidr = k8sCfg.podCidr or "10.42.0.0/16";
  serviceCidr = k8sCfg.serviceCidr or "10.43.0.0/16";
  useCalico = cni == "calico";
in
{
  # K3s token (shared across all nodes via agenix)
  age.secrets.k3s-token = {
    file = "${secretsPath}/k3s-token.age";
    path = "/var/lib/rancher/k3s/server/token";
    owner = "root";
    mode = "0600";
  };

  # K3s - Lightweight Kubernetes
  services.k3s = {
    enable = true;
    role = if isServer then "server" else "agent";
    tokenFile = config.age.secrets.k3s-token.path;

    serverAddr = lib.mkIf (!isBootstrap) "https://${nodeConfig.bootstrapIP}:6443";

    extraFlags = toString (
      # Server-specific flags
      lib.optionals isServer [
        "--secrets-encryption"
        "--disable=traefik"
        "--disable=servicelb"
        "--write-kubeconfig-mode=600"
        "--cluster-cidr=${podCidr}"
        "--service-cidr=${serviceCidr}"
        "--node-ip=${nodeConfig.ip}"
        "--advertise-address=${nodeConfig.ip}"
      ]
      # Disable built-in flannel when using calico
      ++ lib.optionals (isServer && useCalico) [
        "--flannel-backend=none"
        "--disable-network-policy"
      ]
      # Bootstrap server: initialize cluster (enables embedded etcd for HA)
      ++ lib.optionals (isBootstrap && isHA) [
        "--cluster-init"
      ]
      # Agent-specific flags
      ++ lib.optionals isAgent [
        "--node-ip=${nodeConfig.ip}"
      ]
      # Common kubelet flags
      ++ [
        "--kubelet-arg=system-reserved=cpu=500m,memory=512Mi"
        "--kubelet-arg=kube-reserved=cpu=500m,memory=512Mi"
        "--kubelet-arg=eviction-hard=memory.available<256Mi,nodefs.available<10%"
      ]
    );
  };

  # Ensure K3s waits for network to be ready
  systemd.services.k3s = {
    after = [
      "network-online.target"
      "k3s-network-check.service"
    ];
    wants = [ "network-online.target" ];
    requires = [ "k3s-network-check.service" ];
  };

  # Firewall
  networking.firewall.allowedTCPPorts =
    # All nodes
    [ 10250 ] # kubelet
    ++ lib.optionals isServer [
      6443 # K3s API server
    ]
    ++ lib.optionals (isServer && isHA) [
      2379 # etcd client
      2380 # etcd peer
    ];

  networking.firewall.allowedUDPPorts = [
    8472 # Flannel VXLAN
  ];

  # Allow traffic on CNI interfaces
  networking.firewall.trustedInterfaces = [
    "cni0"
    "flannel.1"
  ]
  ++ lib.optionals useCalico [
    "cali+"
    "tunl0"
  ];

  # Kernel modules required for CNI bridge
  boot.kernelModules = [
    "bridge"
    "br_netfilter"
    "veth"
  ];

  # Sysctl settings for Kubernetes networking
  boot.kernel.sysctl = {
    "net.bridge.bridge-nf-call-iptables" = 1;
    "net.bridge.bridge-nf-call-ip6tables" = 1;
    "net.ipv4.ip_forward" = 1;
  };

  # Useful tools
  environment.systemPackages = with pkgs; [
    kubectl
    kubernetes-helm
    k9s
  ];

  # Verify network is ready before K3s
  systemd.services.k3s-network-check = {
    description = "Verify network is ready before K3s starts";
    before = [ "k3s.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "k3s-network-check" ''
        set -e

        echo "Verifying network connectivity before starting K3s..."

        # Wait for IP address to be configured
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

        # Verify gateway is reachable
        echo "Verifying connectivity to gateway ${serverConfig.gateway}..."
        for i in $(seq 1 10); do
          if ${pkgs.iputils}/bin/ping -c 1 -W 2 ${serverConfig.gateway} &>/dev/null; then
            echo "Gateway ${serverConfig.gateway} reachable"
            break
          fi
          echo "Waiting for gateway... ($i/10)"
          sleep 2
        done

        # DNS check (optional, non-blocking)
        echo "Verifying DNS..."
        if ${pkgs.iputils}/bin/ping -c 1 -W 2 ${builtins.head serverConfig.nameservers} &>/dev/null; then
          echo "DNS working"
        else
          echo "WARN: DNS not responding, but continuing (may be normal)"
        fi

        ${lib.optionalString (!isBootstrap) ''
          # Non-bootstrap nodes: verify bootstrap server is reachable
          echo "Verifying connectivity to bootstrap server ${nodeConfig.bootstrapIP}..."
          for i in $(seq 1 15); do
            if ${pkgs.iputils}/bin/ping -c 1 -W 2 ${nodeConfig.bootstrapIP} &>/dev/null; then
              echo "Bootstrap server ${nodeConfig.bootstrapIP} reachable"
              break
            fi
            echo "Waiting for bootstrap server... ($i/15)"
            sleep 2
          done
        ''}

        echo "Network verified, K3s can start"
      '';
    };
  };

  # Service to copy kubeconfig after K3s starts (servers only)
  systemd.services.kubeconfig-setup = lib.mkIf isServer {
    description = "Setup kubeconfig for admin user";
    after = [ "k3s.service" ];
    wants = [ "k3s.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "setup-kubeconfig" ''
        for i in $(seq 1 30); do
          if [ -f /etc/rancher/k3s/k3s.yaml ]; then
            break
          fi
          sleep 1
        done

        if [ -f /etc/rancher/k3s/k3s.yaml ]; then
          mkdir -p /home/${serverConfig.adminUser}/.kube
          cp /etc/rancher/k3s/k3s.yaml /home/${serverConfig.adminUser}/.kube/config
          chown ${serverConfig.adminUser}:users /home/${serverConfig.adminUser}/.kube/config
          chmod 600 /home/${serverConfig.adminUser}/.kube/config
        fi
      '';
    };
  };

  # WORKAROUND: Fix for K3s CNI bridge issue
  systemd.services.k3s-cni-bridge-fixer = {
    description = "K3s CNI Bridge Fixer - Attach veth interfaces to cni0";
    after = [ "k3s.service" ];
    wants = [ "k3s.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      Restart = "always";
      RestartSec = "5s";
      ProtectSystem = "full";
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      CapabilityBoundingSet = "CAP_NET_ADMIN";
      AmbientCapabilities = "CAP_NET_ADMIN";

      ExecStart = pkgs.writeShellScript "k3s-cni-bridge-fixer" ''
        set -euo pipefail

        log() {
          echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
        }

        attach_veths_to_bridge() {
          if ! ${pkgs.iproute2}/bin/ip link show cni0 &>/dev/null; then
            return 0
          fi

          ${pkgs.iproute2}/bin/ip link set cni0 up 2>/dev/null || true

          for veth in $(${pkgs.iproute2}/bin/ip link show type veth | ${pkgs.gnugrep}/bin/grep -oP '^\d+: \K[^:@]+' || true); do
            if ! ${pkgs.iproute2}/bin/ip link show "$veth" | ${pkgs.gnugrep}/bin/grep -q "master cni0"; then
              if ${pkgs.iproute2}/bin/ip link set "$veth" master cni0 2>/dev/null; then
                log "Attached $veth to cni0 bridge"
              fi
            fi
          done
        }

        log "Starting K3s CNI bridge fixer..."
        log "Monitoring veth interfaces and attaching to cni0 bridge"

        while true; do
          attach_veths_to_bridge
          sleep 30
        done
      '';
    };
  };

}
