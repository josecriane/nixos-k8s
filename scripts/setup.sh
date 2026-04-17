#!/usr/bin/env bash
# Interactive setup wizard for NixOS K8s
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$SCRIPT_DIR")}"

echo "========================================="
echo "  NixOS K8s - Setup Wizard"
echo "========================================="
echo ""

CONFIG_FILE="$PROJECT_DIR/config.nix"

if [ -f "$CONFIG_FILE" ]; then
  echo "config.nix already exists."
  read -p "Overwrite? (y/N): " OVERWRITE
  if [ "$OVERWRITE" != "y" ] && [ "$OVERWRITE" != "Y" ]; then
    echo "Setup cancelled."
    exit 0
  fi
fi

# ============================================
# Network
# ============================================
echo "--- Network ---"
echo ""

read -p "Gateway [192.168.1.1]: " GATEWAY
GATEWAY="${GATEWAY:-192.168.1.1}"

read -p "DNS servers (comma-separated) [1.1.1.1,8.8.8.8]: " DNS_INPUT
DNS_INPUT="${DNS_INPUT:-1.1.1.1,8.8.8.8}"

DNS_LIST=""
IFS=',' read -ra DNS_ARRAY <<< "$DNS_INPUT"
for dns in "${DNS_ARRAY[@]}"; do
  dns=$(echo "$dns" | xargs)
  DNS_LIST="$DNS_LIST    \"$dns\"\n"
done

read -p "Use WiFi instead of Ethernet? (y/N): " USE_WIFI_INPUT
if [ "$USE_WIFI_INPUT" = "y" ] || [ "$USE_WIFI_INPUT" = "Y" ]; then
  USE_WIFI="true"
  read -p "WiFi SSID: " WIFI_SSID
  if [ -z "$WIFI_SSID" ]; then
    echo "ERROR: WiFi SSID is required when using WiFi"
    exit 1
  fi
else
  USE_WIFI="false"
  WIFI_SSID=""
fi

# ============================================
# Domain
# ============================================
echo ""
echo "--- Domain ---"
echo ""

read -p "Domain [example.com]: " DOMAIN
DOMAIN="${DOMAIN:-example.com}"

read -p "Subdomain (services at *.<subdomain>.<domain>) [k8s]: " SUBDOMAIN
SUBDOMAIN="${SUBDOMAIN:-k8s}"

# ============================================
# Kubernetes engine
# ============================================
echo ""
echo "--- Kubernetes engine ---"
echo ""
echo "  1) k3s     - Lightweight, batteries included (recommended for most cases)"
echo "  2) kubeadm - Standard Kubernetes via NixOS module (closer to upstream)"
echo ""
read -p "Engine [k3s]: " ENGINE_INPUT
ENGINE_INPUT="${ENGINE_INPUT:-k3s}"
case "$ENGINE_INPUT" in
  1|k3s) K8S_ENGINE="k3s" ;;
  2|kubeadm) K8S_ENGINE="kubeadm" ;;
  *)
    echo "ERROR: Invalid choice. Use 'k3s' or 'kubeadm'."
    exit 1
    ;;
esac

echo ""
echo "  1) flannel - Simple VXLAN overlay (default)"
echo "  2) calico  - Advanced: network policies, BGP, used by many production clusters"
echo ""
read -p "CNI plugin [flannel]: " CNI_INPUT
CNI_INPUT="${CNI_INPUT:-flannel}"
case "$CNI_INPUT" in
  1|flannel) K8S_CNI="flannel" ;;
  2|calico) K8S_CNI="calico" ;;
  *)
    echo "ERROR: Invalid choice. Use 'flannel' or 'calico'."
    exit 1
    ;;
esac

# ============================================
# Admin
# ============================================
echo ""
echo "--- Admin user ---"
echo ""

read -p "Admin username [admin]: " ADMIN_USER
ADMIN_USER="${ADMIN_USER:-admin}"

read -p "Timezone [UTC]: " TIMEZONE
TIMEZONE="${TIMEZONE:-UTC}"

# SSH key
echo ""
read -p "Path to SSH public key [~/.ssh/id_ed25519.pub]: " SSH_KEY_PATH
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_ed25519.pub}"

if [ -f "$SSH_KEY_PATH" ]; then
  mkdir -p "$PROJECT_DIR/keys"
  cp "$SSH_KEY_PATH" "$PROJECT_DIR/keys/admin.pub"
  echo "SSH key copied to keys/admin.pub"
  SSH_KEY_LINE='    (builtins.readFile ./keys/admin.pub)'
else
  echo "WARNING: SSH key not found at $SSH_KEY_PATH"
  echo "You will need to add your SSH key to config.nix manually"
  SSH_KEY_LINE='    # (builtins.readFile ./keys/admin.pub)'
fi

# ============================================
# TLS certificates
# ============================================
echo ""
echo "--- TLS certificates ---"
echo ""
echo "  1) manual - Provide your own certificate (encrypt via secrets/tls-cert.age and tls-key.age)"
echo "  2) acme   - Automatic via cert-manager + Cloudflare DNS-01"
echo ""
read -p "Certificate provider [manual]: " CERT_PROVIDER_INPUT
CERT_PROVIDER_INPUT="${CERT_PROVIDER_INPUT:-manual}"

case "$CERT_PROVIDER_INPUT" in
  1|manual)
    CERT_PROVIDER="manual"
    ACME_EMAIL=""
    ;;
  2|acme)
    CERT_PROVIDER="acme"
    read -p "ACME email for Let's Encrypt: " ACME_EMAIL
    if [ -z "$ACME_EMAIL" ]; then
      echo "ERROR: ACME email is required for certificate issuance"
      exit 1
    fi
    ;;
  *)
    echo "ERROR: Invalid choice. Use 'manual' or 'acme'."
    exit 1
    ;;
esac

# ============================================
# Load balancer
# ============================================
echo ""
echo "--- Load balancer (MetalLB) ---"
echo ""

PREFIX=$(echo "$GATEWAY" | sed 's/\.[0-9]*$//')

read -p "MetalLB pool start IP [${PREFIX}.200]: " METALLB_START
METALLB_START="${METALLB_START:-${PREFIX}.200}"

read -p "MetalLB pool end IP [${PREFIX}.254]: " METALLB_END
METALLB_END="${METALLB_END:-${PREFIX}.254}"

read -p "Traefik IP (from MetalLB pool) [$METALLB_START]: " TRAEFIK_IP
TRAEFIK_IP="${TRAEFIK_IP:-$METALLB_START}"

# ============================================
# Storage
# ============================================
echo ""
echo "--- Storage ---"
echo ""

read -p "Use NFS storage from a NAS? (y/N): " USE_NFS_INPUT
if [ "$USE_NFS_INPUT" = "y" ] || [ "$USE_NFS_INPUT" = "Y" ]; then
  USE_NFS="true"
  read -p "NAS IP: " NAS_IP
  read -p "NAS hostname [nas1]: " NAS_HOSTNAME
  NAS_HOSTNAME="${NAS_HOSTNAME:-nas1}"
  read -p "NFS export path [/]: " NAS_NFS_PATH
  NAS_NFS_PATH="${NAS_NFS_PATH:-/}"
else
  USE_NFS="false"
fi

# ============================================
# Bootstrap server (first node)
# ============================================
echo ""
echo "--- Bootstrap server (first node) ---"
echo ""

read -p "Node name [server1]: " NODE_NAME
NODE_NAME="${NODE_NAME:-server1}"

read -p "Server IP [${PREFIX}.100]: " SERVER_IP
SERVER_IP="${SERVER_IP:-${PREFIX}.100}"

# ============================================
# Disk encryption
# ============================================
echo ""
echo "--- Disk encryption ---"
echo ""

read -p "Enable LUKS disk encryption? (y/N): " ENCRYPT_INPUT
if [ "$ENCRYPT_INPUT" = "y" ] || [ "$ENCRYPT_INPUT" = "Y" ]; then
  ENCRYPT_ENABLE="true"
  echo ""
  echo "  Unlock method:"
  echo "    1) ssh - SSH into initrd to type passphrase (manual, most secure)"
  echo "    2) tpm - Automatic via TPM2 chip (unattended reboot, needs TPM hardware)"
  echo ""
  read -p "Unlock method [ssh]: " UNLOCK_METHOD_INPUT
  UNLOCK_METHOD_INPUT="${UNLOCK_METHOD_INPUT:-ssh}"
  case "$UNLOCK_METHOD_INPUT" in
    1|ssh) UNLOCK_METHOD="ssh" ;;
    2|tpm) UNLOCK_METHOD="tpm" ;;
    *)
      echo "ERROR: Invalid choice. Use 'ssh' or 'tpm'."
      exit 1
      ;;
  esac
  if [ "$UNLOCK_METHOD" = "ssh" ]; then
    read -p "Initrd SSH port [2222]: " SSH_INITRD_PORT
    SSH_INITRD_PORT="${SSH_INITRD_PORT:-2222}"
  fi
else
  ENCRYPT_ENABLE="false"
fi

# ============================================
# Services
# ============================================
echo ""
echo "--- Services (all optional, can be changed later in config.nix) ---"
echo ""

SVC_REGISTRY="false"
read -p "Enable Docker Registry? (y/N): " SVC_INPUT
[ "$SVC_INPUT" = "y" ] || [ "$SVC_INPUT" = "Y" ] && SVC_REGISTRY="true"

SVC_MIRROR="false"
read -p "Enable Docker Mirror (pull-through cache)? (y/N): " SVC_INPUT
[ "$SVC_INPUT" = "y" ] || [ "$SVC_INPUT" = "Y" ] && SVC_MIRROR="true"

SVC_RUNNERS="false"
GITHUB_CONFIG_URL=""
GITHUB_MAX_RUNNERS="5"
GITHUB_RUNNER_NAME="self-hosted-linux"
GITHUB_AUTH_METHOD="app"
GITHUB_APP_ID=""
GITHUB_INSTALLATION_ID=""
read -p "Enable GitHub Actions self-hosted runners? (y/N): " SVC_INPUT
if [ "$SVC_INPUT" = "y" ] || [ "$SVC_INPUT" = "Y" ]; then
  SVC_RUNNERS="true"
  read -p "  GitHub org/repo URL (e.g. https://github.com/your-org): " GITHUB_CONFIG_URL
  if [ -z "$GITHUB_CONFIG_URL" ]; then
    echo "  ERROR: GitHub config URL is required for runners"
    exit 1
  fi
  read -p "  Runner name [self-hosted-linux]: " GITHUB_RUNNER_NAME
  GITHUB_RUNNER_NAME="${GITHUB_RUNNER_NAME:-self-hosted-linux}"
  read -p "  Max runners [5]: " GITHUB_MAX_RUNNERS
  GITHUB_MAX_RUNNERS="${GITHUB_MAX_RUNNERS:-5}"
  echo ""
  echo "  Authentication:"
  echo "    1) GitHub App (recommended - minimal scopes, rotating tokens)"
  echo "    2) PAT         (simpler - fine-grained or classic personal token)"
  read -p "  Auth method [app]: " AUTH_INPUT
  AUTH_INPUT="${AUTH_INPUT:-app}"
  case "$AUTH_INPUT" in
    1|app)
      GITHUB_AUTH_METHOD="app"
      read -p "  App ID: " GITHUB_APP_ID
      read -p "  Installation ID: " GITHUB_INSTALLATION_ID
      if [ -z "$GITHUB_APP_ID" ] || [ -z "$GITHUB_INSTALLATION_ID" ]; then
        echo "  ERROR: Both App ID and Installation ID are required"
        exit 1
      fi
      echo "  NOTE: You will need to create secrets/github-app-key.age with the App private key (.pem)"
      ;;
    2|pat)
      GITHUB_AUTH_METHOD="pat"
      echo "  NOTE: You will need to create secrets/github-pat.age with your PAT"
      ;;
    *)
      echo "  ERROR: Invalid choice. Use 'app' or 'pat'."
      exit 1
      ;;
  esac
fi

# ============================================
# Additional nodes
# ============================================
echo ""
echo "--- Additional nodes (optional) ---"
echo ""

EXTRA_NODES=""
while true; do
  read -p "Add another node? (y/N): " ADD_NODE
  if [ "$ADD_NODE" != "y" ] && [ "$ADD_NODE" != "Y" ]; then
    break
  fi

  read -p "  Node name: " EXTRA_NAME
  if [ -z "$EXTRA_NAME" ]; then
    echo "  Skipped (empty name)"
    continue
  fi

  read -p "  IP address: " EXTRA_IP
  if [ -z "$EXTRA_IP" ]; then
    echo "  Skipped (empty IP)"
    continue
  fi

  echo "  Role:"
  echo "    1) server - Control plane node"
  echo "    2) agent  - Worker node"
  read -p "  Role [agent]: " EXTRA_ROLE_INPUT
  case "$EXTRA_ROLE_INPUT" in
    1|server) EXTRA_ROLE="server" ;;
    *) EXTRA_ROLE="agent" ;;
  esac

  read -p "  Enable disk encryption? (y/N): " EXTRA_ENCRYPT
  EXTRA_ENCRYPT_NIX=""
  if [ "$EXTRA_ENCRYPT" = "y" ] || [ "$EXTRA_ENCRYPT" = "Y" ]; then
    read -p "  Unlock method (ssh/tpm) [ssh]: " EXTRA_UNLOCK
    EXTRA_UNLOCK="${EXTRA_UNLOCK:-ssh}"
    if [ "$EXTRA_UNLOCK" = "tpm" ]; then
      EXTRA_ENCRYPT_NIX="
      encryption = { enable = true; unlock = \"tpm\"; };"
    else
      read -p "  Initrd SSH port [2222]: " EXTRA_SSH_PORT
      EXTRA_SSH_PORT="${EXTRA_SSH_PORT:-2222}"
      EXTRA_ENCRYPT_NIX="
      encryption = { enable = true; unlock = \"ssh\"; sshPort = ${EXTRA_SSH_PORT}; };"
    fi
  fi

  EXTRA_NODES="$EXTRA_NODES
    $EXTRA_NAME = {
      ip = \"$EXTRA_IP\";
      role = \"$EXTRA_ROLE\";
      bootstrap = false;$EXTRA_ENCRYPT_NIX
    };"

  # Create host directory
  EXTRA_HOST_DIR="$PROJECT_DIR/hosts/$EXTRA_NAME"
  if [ ! -d "$EXTRA_HOST_DIR" ]; then
    echo "  Creating hosts/$EXTRA_NAME/ (copied from template)"
    if [ -d "$PROJECT_DIR/hosts/server1" ]; then
      cp -r "$PROJECT_DIR/hosts/server1" "$EXTRA_HOST_DIR"
    else
      mkdir -p "$EXTRA_HOST_DIR"
    fi
  fi

  echo "  Added $EXTRA_NAME ($EXTRA_IP) as $EXTRA_ROLE"
  echo ""
done

# ============================================
# Build NAS config
# ============================================
NAS_CONFIG="nas = {};"
if [ "$USE_NFS" = "true" ]; then
  NAS_CONFIG="nas = {
    ${NAS_HOSTNAME} = {
      enabled = true;
      ip = \"${NAS_IP}\";
      hostname = \"${NAS_HOSTNAME}\";
      role = \"all\";
      nfsExports = {
        nfsPath = \"${NAS_NFS_PATH}\";
      };
    };
  };"
fi

# ============================================
# Build encryption config for bootstrap node
# ============================================
BOOTSTRAP_ENCRYPT=""
if [ "$ENCRYPT_ENABLE" = "true" ]; then
  if [ "$UNLOCK_METHOD" = "tpm" ]; then
    BOOTSTRAP_ENCRYPT="
      encryption = { enable = true; unlock = \"tpm\"; };"
  else
    BOOTSTRAP_ENCRYPT="
      encryption = { enable = true; unlock = \"ssh\"; sshPort = ${SSH_INITRD_PORT}; };"
  fi
fi

# ============================================
# Build ACME email line
# ============================================
ACME_LINE=""
if [ -n "$ACME_EMAIL" ]; then
  ACME_LINE="acmeEmail = \"$ACME_EMAIL\";"
else
  ACME_LINE="# acmeEmail = \"you@example.com\"; # only needed with provider = \"acme\""
fi

# ============================================
# Create host directory for bootstrap node
# ============================================
HOST_DIR="$PROJECT_DIR/hosts/$NODE_NAME"
if [ ! -d "$HOST_DIR" ]; then
  echo ""
  echo "Creating hosts/$NODE_NAME/ directory..."
  if [ -d "$PROJECT_DIR/hosts/server1" ] && [ "$NODE_NAME" != "server1" ]; then
    cp -r "$PROJECT_DIR/hosts/server1" "$HOST_DIR"
  elif [ ! -d "$HOST_DIR" ]; then
    mkdir -p "$HOST_DIR"
    echo "WARNING: You'll need to create hardware-configuration.nix manually in hosts/$NODE_NAME/"
  fi
fi

# ============================================
# Write config.nix
# ============================================
cat > "$CONFIG_FILE" << NIXEOF
{
  gateway = "$GATEWAY";
  nameservers = [
$(echo -e "$DNS_LIST")  ];
  useWifi = $USE_WIFI;
  wifiSSID = "$WIFI_SSID";
  domain = "$DOMAIN";
  subdomain = "$SUBDOMAIN";
  adminUser = "$ADMIN_USER";
  adminSSHKeys = [
$SSH_KEY_LINE
  ];
  puid = 1000;
  pgid = 1000;
  $ACME_LINE
  metallbPoolStart = "$METALLB_START";
  metallbPoolEnd = "$METALLB_END";
  traefikIP = "$TRAEFIK_IP";
  timezone = "$TIMEZONE";

  kubernetes = {
    engine = "$K8S_ENGINE";
    cni = "$K8S_CNI";
  };

  services = {
    docker-registry = $SVC_REGISTRY;
    docker-mirror = $SVC_MIRROR;
    github-runners = $SVC_RUNNERS;
  };
$(if [ "$SVC_RUNNERS" = "true" ]; then
if [ "$GITHUB_AUTH_METHOD" = "app" ]; then
cat << GHEOF
  github-runners = {
    configUrl = "$GITHUB_CONFIG_URL";
    maxRunners = $GITHUB_MAX_RUNNERS;
    runnerName = "$GITHUB_RUNNER_NAME";
    githubApp = {
      appId = $GITHUB_APP_ID;
      installationId = $GITHUB_INSTALLATION_ID;
    };
  };
GHEOF
else
cat << GHEOF
  github-runners = {
    configUrl = "$GITHUB_CONFIG_URL";
    maxRunners = $GITHUB_MAX_RUNNERS;
    runnerName = "$GITHUB_RUNNER_NAME";
  };
GHEOF
fi
fi)
  $NAS_CONFIG
  storage = { useNFS = $USE_NFS; };
  certificates = { provider = "$CERT_PROVIDER"; restoreFromBackup = false; };

  nodes = {
    $NODE_NAME = {
      ip = "$SERVER_IP";
      role = "server";
      bootstrap = true;$BOOTSTRAP_ENCRYPT
    };$EXTRA_NODES
  };
}
NIXEOF

# ============================================
# Summary
# ============================================
echo ""
echo "========================================="
echo "  Setup complete!"
echo "========================================="
echo ""
echo "Configuration written to config.nix"
echo ""
echo "  Engine:      $K8S_ENGINE + $K8S_CNI"
echo "  Domain:      *.$SUBDOMAIN.$DOMAIN"
echo "  Gateway:     $GATEWAY"
echo "  Traefik IP:  $TRAEFIK_IP"
echo "  MetalLB:     $METALLB_START - $METALLB_END"
echo "  Certificates: $CERT_PROVIDER"
if [ "$USE_NFS" = "true" ]; then
  echo "  NAS:         $NAS_IP ($NAS_HOSTNAME)"
fi
echo ""
ENABLED_SVCS=""
[ "$SVC_REGISTRY" = "true" ] && ENABLED_SVCS="$ENABLED_SVCS Registry"
[ "$SVC_MIRROR" = "true" ] && ENABLED_SVCS="$ENABLED_SVCS Mirror"
[ "$SVC_RUNNERS" = "true" ] && ENABLED_SVCS="$ENABLED_SVCS Runners"
if [ -n "$ENABLED_SVCS" ]; then
  echo "  Services:   $ENABLED_SVCS"
else
  echo "  Services:    (none)"
fi
echo ""
echo "  Nodes:"
echo "    $NODE_NAME ($SERVER_IP) - server (bootstrap)"
if [ -n "$EXTRA_NODES" ]; then
  echo "$EXTRA_NODES" | grep -oP '\w+ = \{' | sed 's/ = {//' | while read name; do
    IP=$(echo "$EXTRA_NODES" | grep -A1 "$name" | grep 'ip =' | sed 's/.*"\(.*\)".*/\1/')
    ROLE=$(echo "$EXTRA_NODES" | grep -A2 "$name" | grep 'role =' | sed 's/.*"\(.*\)".*/\1/')
    echo "    $name ($IP) - $ROLE"
  done
fi
echo ""
echo "Next steps:"
echo "  1. Add your agenix secrets:"
echo "     cd secrets"
echo "     openssl rand -hex 32 | agenix -e k3s-token.age"
echo "     # Admin user password hash (required):"
echo "     nix-shell -p mkpasswd --run 'mkpasswd -m sha-512' | tr -d '\\n' > /tmp/pass-hash"
echo "     agenix -e admin-password-hash.age < /tmp/pass-hash && rm /tmp/pass-hash"
if [ "$CERT_PROVIDER" = "manual" ]; then
  echo "     agenix -e tls-cert.age < /path/to/wildcard.crt"
  echo "     agenix -e tls-key.age  < /path/to/wildcard.key"
fi
if [ "$CERT_PROVIDER" = "acme" ]; then
  echo "     agenix -e cloudflare-api-token.age"
fi
if [ "$SVC_REGISTRY" = "true" ]; then
  echo "     # Generate htpasswd and encrypt (push credentials for the registry):"
  echo "     nix-shell -p apacheHttpd --run 'htpasswd -Bc /tmp/htpasswd ci'"
  echo "     agenix -e registry-htpasswd.age < /tmp/htpasswd && rm /tmp/htpasswd"
fi
if [ "$SVC_RUNNERS" = "true" ]; then
  if [ "$GITHUB_AUTH_METHOD" = "app" ]; then
    echo "     agenix -e github-app-key.age < /path/to/app-private-key.pem"
  else
    echo "     echo \"ghp_xxxx\" | agenix -e github-pat.age"
  fi
fi
echo "  2. Edit hosts/$NODE_NAME/hardware-configuration.nix for your hardware"
echo "  3. Run 'make install NODE=$NODE_NAME'"
if [ "$ENCRYPT_ENABLE" = "true" ] && [ "$UNLOCK_METHOD" = "tpm" ]; then
  echo ""
  echo "  After first boot, enroll TPM key:"
  echo "    make ssh NODE=$NODE_NAME"
  echo "    sudo systemd-cryptenroll /dev/disk/by-partlabel/disk-main-root --tpm2-device=auto --tpm2-pcrs=0+7"
fi
echo ""
