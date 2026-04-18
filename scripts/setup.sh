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
EXISTING_CONFIG=""

if [ -f "$CONFIG_FILE" ]; then
  echo "config.nix already exists. Existing values will be pre-filled as defaults."
  read -p "Overwrite? (y/N): " OVERWRITE
  if [ "$OVERWRITE" != "y" ] && [ "$OVERWRITE" != "Y" ]; then
    echo "Setup cancelled."
    exit 0
  fi
  EXISTING_CONFIG="$CONFIG_FILE"
  echo ""
fi

# ============================================
# Helpers to read defaults from existing config
# ============================================
cfg_get() {
  # cfg_get <nix-path-starting-with-dot> <fallback>
  # toString lets us read ints (e.g. appId) and strings uniformly.
  local expr="$1" fallback="${2:-}"
  if [ -n "$EXISTING_CONFIG" ]; then
    local r
    r=$(nix eval --raw --impure --expr "toString ((import $EXISTING_CONFIG)$expr or \"\")" 2>/dev/null || true)
    if [ -n "$r" ]; then printf '%s' "$r"; return; fi
  fi
  printf '%s' "$fallback"
}

cfg_get_bool() {
  local expr="$1" fallback="${2:-false}"
  if [ -n "$EXISTING_CONFIG" ]; then
    local r
    r=$(nix eval --impure --expr "(import $EXISTING_CONFIG)$expr or $fallback" 2>/dev/null || echo "$fallback")
    printf '%s' "$r"
    return
  fi
  printf '%s' "$fallback"
}

cfg_get_list_csv() {
  local expr="$1" fallback="${2:-}"
  if [ -n "$EXISTING_CONFIG" ] && command -v jq >/dev/null 2>&1; then
    local r
    r=$(nix eval --json --impure --expr "(import $EXISTING_CONFIG)$expr or []" 2>/dev/null \
        | jq -r 'if type == "array" then join(",") else "" end' 2>/dev/null || true)
    if [ -n "$r" ]; then printf '%s' "$r"; return; fi
  fi
  printf '%s' "$fallback"
}

# Prompt "y/N" using the given existing bool as the default answer.
# Prints "true" or "false" to stdout.
ask_yn() {
  local prompt="$1" default_bool="$2"
  local default_letter="N"
  [ "$default_bool" = "true" ] && default_letter="Y"
  local suffix
  if [ "$default_letter" = "Y" ]; then suffix="[Y/n]"; else suffix="[y/N]"; fi
  local ans
  read -p "${prompt} ${suffix}: " ans
  ans="${ans:-$default_letter}"
  if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then echo "true"; else echo "false"; fi
}

# ============================================
# Network
# ============================================
echo "--- Network ---"
echo ""

DEFAULT_GATEWAY=$(cfg_get '.gateway' "192.168.1.1")
read -p "Gateway [$DEFAULT_GATEWAY]: " GATEWAY
GATEWAY="${GATEWAY:-$DEFAULT_GATEWAY}"

DEFAULT_DNS=$(cfg_get_list_csv '.nameservers' "1.1.1.1,8.8.8.8")
read -p "DNS servers (comma-separated) [$DEFAULT_DNS]: " DNS_INPUT
DNS_INPUT="${DNS_INPUT:-$DEFAULT_DNS}"

DNS_LIST=""
IFS=',' read -ra DNS_ARRAY <<< "$DNS_INPUT"
for dns in "${DNS_ARRAY[@]}"; do
  dns=$(echo "$dns" | xargs)
  DNS_LIST="$DNS_LIST    \"$dns\"\n"
done

USE_WIFI=$(ask_yn "Use WiFi instead of Ethernet?" "$(cfg_get_bool '.useWifi' false)")
if [ "$USE_WIFI" = "true" ]; then
  DEFAULT_SSID=$(cfg_get '.wifiSSID' "")
  read -p "WiFi SSID [$DEFAULT_SSID]: " WIFI_SSID
  WIFI_SSID="${WIFI_SSID:-$DEFAULT_SSID}"
  if [ -z "$WIFI_SSID" ]; then
    echo "ERROR: WiFi SSID is required when using WiFi"
    exit 1
  fi
else
  WIFI_SSID=""
fi

# ============================================
# Domain
# ============================================
echo ""
echo "--- Domain ---"
echo ""

DEFAULT_DOMAIN=$(cfg_get '.domain' "example.com")
read -p "Domain [$DEFAULT_DOMAIN]: " DOMAIN
DOMAIN="${DOMAIN:-$DEFAULT_DOMAIN}"

DEFAULT_SUBDOMAIN=$(cfg_get '.subdomain' "k8s")
read -p "Subdomain (services at *.<subdomain>.<domain>) [$DEFAULT_SUBDOMAIN]: " SUBDOMAIN
SUBDOMAIN="${SUBDOMAIN:-$DEFAULT_SUBDOMAIN}"

# ============================================
# Kubernetes engine
# ============================================
echo ""
echo "--- Kubernetes engine ---"
echo ""
echo "  1) k3s     - Lightweight, batteries included (recommended for most cases)"
echo "  2) kubeadm - Standard Kubernetes via NixOS module (closer to upstream)"
echo ""
DEFAULT_ENGINE=$(cfg_get '.kubernetes.engine' "k3s")
read -p "Engine [$DEFAULT_ENGINE]: " ENGINE_INPUT
ENGINE_INPUT="${ENGINE_INPUT:-$DEFAULT_ENGINE}"
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
DEFAULT_CNI=$(cfg_get '.kubernetes.cni' "flannel")
read -p "CNI plugin [$DEFAULT_CNI]: " CNI_INPUT
CNI_INPUT="${CNI_INPUT:-$DEFAULT_CNI}"
case "$CNI_INPUT" in
  1|flannel) K8S_CNI="flannel" ;;
  2|calico) K8S_CNI="calico" ;;
  *)
    echo "ERROR: Invalid choice. Use 'flannel' or 'calico'."
    exit 1
    ;;
esac

DEFAULT_POD_CIDR=$(cfg_get '.kubernetes.podCidr' "10.42.0.0/16")
read -p "Pod CIDR [$DEFAULT_POD_CIDR]: " POD_CIDR
POD_CIDR="${POD_CIDR:-$DEFAULT_POD_CIDR}"

DEFAULT_SERVICE_CIDR=$(cfg_get '.kubernetes.serviceCidr' "10.43.0.0/16")
read -p "Service CIDR [$DEFAULT_SERVICE_CIDR]: " SERVICE_CIDR
SERVICE_CIDR="${SERVICE_CIDR:-$DEFAULT_SERVICE_CIDR}"

# ============================================
# Admin
# ============================================
echo ""
echo "--- Admin user ---"
echo ""

DEFAULT_ADMIN_USER=$(cfg_get '.adminUser' "admin")
read -p "Admin username [$DEFAULT_ADMIN_USER]: " ADMIN_USER
ADMIN_USER="${ADMIN_USER:-$DEFAULT_ADMIN_USER}"

DEFAULT_TZ=$(cfg_get '.timezone' "UTC")
read -p "Timezone [$DEFAULT_TZ]: " TIMEZONE
TIMEZONE="${TIMEZONE:-$DEFAULT_TZ}"

# Agenix identity: private key used by `agenix` to decrypt secrets and by
# `make deploy/unlock/enroll-tpm` as SSH identity. Leave empty to omit.
DEFAULT_AGENIX_ID=$(cfg_get '.agenixIdentity' "")
if [ -n "$DEFAULT_AGENIX_ID" ]; then
  read -p "Agenix identity (private key path) [$DEFAULT_AGENIX_ID]: " AGENIX_IDENTITY
  AGENIX_IDENTITY="${AGENIX_IDENTITY:-$DEFAULT_AGENIX_ID}"
else
  read -p "Agenix identity (private key path, empty to skip): " AGENIX_IDENTITY
fi

# SSH key: prefer existing keys/admin.pub; fall back to ~/.ssh/id_ed25519.pub
echo ""
if [ -f "$PROJECT_DIR/keys/admin.pub" ]; then
  DEFAULT_SSH_KEY_PATH="$PROJECT_DIR/keys/admin.pub"
else
  DEFAULT_SSH_KEY_PATH="$HOME/.ssh/id_ed25519.pub"
fi
read -p "Path to SSH public key [$DEFAULT_SSH_KEY_PATH]: " SSH_KEY_PATH
SSH_KEY_PATH="${SSH_KEY_PATH:-$DEFAULT_SSH_KEY_PATH}"

if [ -f "$SSH_KEY_PATH" ]; then
  mkdir -p "$PROJECT_DIR/keys"
  if [ "$SSH_KEY_PATH" != "$PROJECT_DIR/keys/admin.pub" ]; then
    cp "$SSH_KEY_PATH" "$PROJECT_DIR/keys/admin.pub"
    echo "SSH key copied to keys/admin.pub"
  else
    echo "Reusing existing keys/admin.pub"
  fi
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
DEFAULT_CERT_PROVIDER=$(cfg_get '.certificates.provider' "manual")
read -p "Certificate provider [$DEFAULT_CERT_PROVIDER]: " CERT_PROVIDER_INPUT
CERT_PROVIDER_INPUT="${CERT_PROVIDER_INPUT:-$DEFAULT_CERT_PROVIDER}"

case "$CERT_PROVIDER_INPUT" in
  1|manual)
    CERT_PROVIDER="manual"
    ACME_EMAIL=""
    ;;
  2|acme)
    CERT_PROVIDER="acme"
    DEFAULT_ACME_EMAIL=$(cfg_get '.acmeEmail' "")
    read -p "ACME email for Let's Encrypt [$DEFAULT_ACME_EMAIL]: " ACME_EMAIL
    ACME_EMAIL="${ACME_EMAIL:-$DEFAULT_ACME_EMAIL}"
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

DEFAULT_METALLB_START=$(cfg_get '.metallbPoolStart' "${PREFIX}.200")
read -p "MetalLB pool start IP [$DEFAULT_METALLB_START]: " METALLB_START
METALLB_START="${METALLB_START:-$DEFAULT_METALLB_START}"

DEFAULT_METALLB_END=$(cfg_get '.metallbPoolEnd' "${PREFIX}.254")
read -p "MetalLB pool end IP [$DEFAULT_METALLB_END]: " METALLB_END
METALLB_END="${METALLB_END:-$DEFAULT_METALLB_END}"

DEFAULT_TRAEFIK=$(cfg_get '.traefikIP' "$METALLB_START")
read -p "Traefik IP (from MetalLB pool) [$DEFAULT_TRAEFIK]: " TRAEFIK_IP
TRAEFIK_IP="${TRAEFIK_IP:-$DEFAULT_TRAEFIK}"

# ============================================
# Storage
# ============================================
echo ""
echo "--- Storage ---"
echo ""

USE_NFS=$(ask_yn "Use NFS storage from a NAS?" "$(cfg_get_bool '.storage.useNFS' false)")
if [ "$USE_NFS" = "true" ]; then
  # First (any) NAS entry gets pre-filled; otherwise hardcoded defaults.
  EXISTING_NAS_NAME=""
  if [ -n "$EXISTING_CONFIG" ] && command -v jq >/dev/null 2>&1; then
    EXISTING_NAS_NAME=$(nix eval --json --impure --expr \
      "builtins.attrNames ((import $EXISTING_CONFIG).nas or {})" 2>/dev/null \
      | jq -r '.[0] // ""' 2>/dev/null || true)
  fi
  DEFAULT_NAS_IP=$(cfg_get ".nas.${EXISTING_NAS_NAME}.ip" "")
  DEFAULT_NAS_HOSTNAME="${EXISTING_NAS_NAME:-nas1}"
  DEFAULT_NAS_PATH=$(cfg_get ".nas.${EXISTING_NAS_NAME}.nfsExports.nfsPath" "/")

  read -p "NAS IP [$DEFAULT_NAS_IP]: " NAS_IP
  NAS_IP="${NAS_IP:-$DEFAULT_NAS_IP}"
  read -p "NAS hostname [$DEFAULT_NAS_HOSTNAME]: " NAS_HOSTNAME
  NAS_HOSTNAME="${NAS_HOSTNAME:-$DEFAULT_NAS_HOSTNAME}"
  read -p "NFS export path [$DEFAULT_NAS_PATH]: " NAS_NFS_PATH
  NAS_NFS_PATH="${NAS_NFS_PATH:-$DEFAULT_NAS_PATH}"
fi

# ============================================
# Bootstrap server (first node)
# ============================================
echo ""
echo "--- Bootstrap server (first node) ---"
echo ""

EXISTING_BOOTSTRAP=""
if [ -n "$EXISTING_CONFIG" ]; then
  EXISTING_BOOTSTRAP=$(nix eval --raw --impure --expr \
    "let c = import $EXISTING_CONFIG; in builtins.head (builtins.filter (n: c.nodes.\${n}.bootstrap or false) (builtins.attrNames c.nodes))" \
    2>/dev/null || true)
fi

DEFAULT_NODE_NAME="${EXISTING_BOOTSTRAP:-server1}"
read -p "Node name [$DEFAULT_NODE_NAME]: " NODE_NAME
NODE_NAME="${NODE_NAME:-$DEFAULT_NODE_NAME}"

DEFAULT_SERVER_IP=$(cfg_get ".nodes.${EXISTING_BOOTSTRAP}.ip" "${PREFIX}.100")
read -p "Server IP [$DEFAULT_SERVER_IP]: " SERVER_IP
SERVER_IP="${SERVER_IP:-$DEFAULT_SERVER_IP}"

# ============================================
# Disk encryption
# ============================================
echo ""
echo "--- Disk encryption ---"
echo ""

DEFAULT_ENCRYPT=$(cfg_get_bool ".nodes.${EXISTING_BOOTSTRAP}.encryption.enable" false)
ENCRYPT_ENABLE=$(ask_yn "Enable LUKS disk encryption?" "$DEFAULT_ENCRYPT")
if [ "$ENCRYPT_ENABLE" = "true" ]; then
  echo ""
  echo "  Unlock method:"
  echo "    1) ssh - SSH into initrd to type passphrase (manual, most secure)"
  echo "    2) tpm - Automatic via TPM2 chip (unattended reboot, needs TPM hardware)"
  echo ""
  DEFAULT_UNLOCK=$(cfg_get ".nodes.${EXISTING_BOOTSTRAP}.encryption.unlock" "ssh")
  read -p "Unlock method [$DEFAULT_UNLOCK]: " UNLOCK_METHOD_INPUT
  UNLOCK_METHOD_INPUT="${UNLOCK_METHOD_INPUT:-$DEFAULT_UNLOCK}"
  case "$UNLOCK_METHOD_INPUT" in
    1|ssh) UNLOCK_METHOD="ssh" ;;
    2|tpm) UNLOCK_METHOD="tpm" ;;
    *)
      echo "ERROR: Invalid choice. Use 'ssh' or 'tpm'."
      exit 1
      ;;
  esac
  # sshPort is always meaningful (initrd SSH is always enabled as fallback).
  DEFAULT_SSH_PORT=$(cfg_get ".nodes.${EXISTING_BOOTSTRAP}.encryption.sshPort" "2222")
  read -p "Initrd SSH port [$DEFAULT_SSH_PORT]: " SSH_INITRD_PORT
  SSH_INITRD_PORT="${SSH_INITRD_PORT:-$DEFAULT_SSH_PORT}"
fi

# ============================================
# Services
# ============================================
echo ""
echo "--- Services (all optional, can be changed later in config.nix) ---"
echo ""

SVC_REGISTRY=$(ask_yn "Enable Docker Registry?" "$(cfg_get_bool '.services.docker-registry' false)")
SVC_MIRROR=$(ask_yn "Enable Docker Mirror (pull-through cache)?" "$(cfg_get_bool '.services.docker-mirror' false)")

GITHUB_CONFIG_URL=""
GITHUB_MAX_RUNNERS="5"
GITHUB_RUNNER_NAME="self-hosted-linux"
GITHUB_AUTH_METHOD="app"
GITHUB_APP_ID=""
GITHUB_INSTALLATION_ID=""

SVC_RUNNERS=$(ask_yn "Enable GitHub Actions self-hosted runners?" "$(cfg_get_bool '.services.github-runners' false)")
if [ "$SVC_RUNNERS" = "true" ]; then
  DEFAULT_GH_URL=$(cfg_get '."github-runners".configUrl' "")
  read -p "  GitHub org/repo URL [$DEFAULT_GH_URL]: " GITHUB_CONFIG_URL
  GITHUB_CONFIG_URL="${GITHUB_CONFIG_URL:-$DEFAULT_GH_URL}"
  if [ -z "$GITHUB_CONFIG_URL" ]; then
    echo "  ERROR: GitHub config URL is required for runners"
    exit 1
  fi

  DEFAULT_RUNNER_NAME=$(cfg_get '."github-runners".runnerName' "self-hosted-linux")
  read -p "  Runner name [$DEFAULT_RUNNER_NAME]: " GITHUB_RUNNER_NAME
  GITHUB_RUNNER_NAME="${GITHUB_RUNNER_NAME:-$DEFAULT_RUNNER_NAME}"

  DEFAULT_MAX_RUNNERS=$(cfg_get '."github-runners".maxRunners' "5")
  read -p "  Max runners [$DEFAULT_MAX_RUNNERS]: " GITHUB_MAX_RUNNERS
  GITHUB_MAX_RUNNERS="${GITHUB_MAX_RUNNERS:-$DEFAULT_MAX_RUNNERS}"

  echo ""
  echo "  Authentication:"
  echo "    1) GitHub App (recommended - minimal scopes, rotating tokens)"
  echo "    2) PAT         (simpler - fine-grained or classic personal token)"
  # Detect prior auth method by checking which sub-attr exists
  DEFAULT_AUTH="app"
  if [ -n "$EXISTING_CONFIG" ]; then
    HAS_APP=$(nix eval --impure --expr "((import $EXISTING_CONFIG).\"github-runners\".githubApp or null) != null" 2>/dev/null || echo "false")
    if [ "$HAS_APP" != "true" ] && [ "$(cfg_get_bool '.services.github-runners' false)" = "true" ]; then
      DEFAULT_AUTH="pat"
    fi
  fi
  read -p "  Auth method [$DEFAULT_AUTH]: " AUTH_INPUT
  AUTH_INPUT="${AUTH_INPUT:-$DEFAULT_AUTH}"
  case "$AUTH_INPUT" in
    1|app)
      GITHUB_AUTH_METHOD="app"
      DEFAULT_APP_ID=$(cfg_get '."github-runners".githubApp.appId' "")
      DEFAULT_INSTALL_ID=$(cfg_get '."github-runners".githubApp.installationId' "")
      read -p "  App ID [$DEFAULT_APP_ID]: " GITHUB_APP_ID
      GITHUB_APP_ID="${GITHUB_APP_ID:-$DEFAULT_APP_ID}"
      read -p "  Installation ID [$DEFAULT_INSTALL_ID]: " GITHUB_INSTALLATION_ID
      GITHUB_INSTALLATION_ID="${GITHUB_INSTALLATION_ID:-$DEFAULT_INSTALL_ID}"
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

# Pre-fill existing extra nodes first: user can keep, edit, or drop each.
if [ -n "$EXISTING_CONFIG" ] && command -v jq >/dev/null 2>&1; then
  EXTRA_EXISTING=$(nix eval --json --impure --expr \
    "let c = import $EXISTING_CONFIG; in builtins.filter (n: !(c.nodes.\${n}.bootstrap or false)) (builtins.attrNames c.nodes)" \
    2>/dev/null | jq -r '.[]' 2>/dev/null || true)

  for EX_NAME in $EXTRA_EXISTING; do
    echo "Existing node: $EX_NAME"
    KEEP=$(ask_yn "  Keep this node?" "true")
    if [ "$KEEP" != "true" ]; then
      echo "  Dropped $EX_NAME"
      echo ""
      continue
    fi

    EX_IP_DEFAULT=$(cfg_get ".nodes.${EX_NAME}.ip" "")
    read -p "  IP address [$EX_IP_DEFAULT]: " EX_IP
    EX_IP="${EX_IP:-$EX_IP_DEFAULT}"

    EX_ROLE_DEFAULT=$(cfg_get ".nodes.${EX_NAME}.role" "agent")
    read -p "  Role (server/agent) [$EX_ROLE_DEFAULT]: " EX_ROLE_INPUT
    EX_ROLE_INPUT="${EX_ROLE_INPUT:-$EX_ROLE_DEFAULT}"
    case "$EX_ROLE_INPUT" in
      1|server) EX_ROLE="server" ;;
      *) EX_ROLE="agent" ;;
    esac

    EX_ENCRYPT_DEFAULT=$(cfg_get_bool ".nodes.${EX_NAME}.encryption.enable" false)
    EX_ENCRYPT=$(ask_yn "  Enable disk encryption?" "$EX_ENCRYPT_DEFAULT")
    EX_ENCRYPT_NIX=""
    if [ "$EX_ENCRYPT" = "true" ]; then
      EX_UNLOCK_DEFAULT=$(cfg_get ".nodes.${EX_NAME}.encryption.unlock" "ssh")
      read -p "  Unlock method (ssh/tpm) [$EX_UNLOCK_DEFAULT]: " EX_UNLOCK
      EX_UNLOCK="${EX_UNLOCK:-$EX_UNLOCK_DEFAULT}"
      EX_PORT_DEFAULT=$(cfg_get ".nodes.${EX_NAME}.encryption.sshPort" "2222")
      read -p "  Initrd SSH port [$EX_PORT_DEFAULT]: " EX_PORT
      EX_PORT="${EX_PORT:-$EX_PORT_DEFAULT}"
      if [ "$EX_UNLOCK" = "tpm" ]; then
        EX_ENCRYPT_NIX="
      encryption = { enable = true; unlock = \"tpm\"; sshPort = ${EX_PORT}; };"
      else
        EX_ENCRYPT_NIX="
      encryption = { enable = true; unlock = \"ssh\"; sshPort = ${EX_PORT}; };"
      fi
    fi

    EXTRA_NODES="$EXTRA_NODES
    $EX_NAME = {
      ip = \"$EX_IP\";
      role = \"$EX_ROLE\";
      bootstrap = false;$EX_ENCRYPT_NIX
    };"

    echo "  Kept $EX_NAME ($EX_IP) as $EX_ROLE"
    echo ""
  done
fi

# Loop for brand-new nodes.
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
    read -p "  Initrd SSH port [2222]: " EXTRA_SSH_PORT
    EXTRA_SSH_PORT="${EXTRA_SSH_PORT:-2222}"
    if [ "$EXTRA_UNLOCK" = "tpm" ]; then
      EXTRA_ENCRYPT_NIX="
      encryption = { enable = true; unlock = \"tpm\"; sshPort = ${EXTRA_SSH_PORT}; };"
    else
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
      encryption = { enable = true; unlock = \"tpm\"; sshPort = ${SSH_INITRD_PORT}; };"
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
# Build agenix identity line
# ============================================
AGENIX_LINE=""
if [ -n "$AGENIX_IDENTITY" ]; then
  AGENIX_LINE="agenixIdentity = \"$AGENIX_IDENTITY\";"
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
  $AGENIX_LINE
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
    podCidr = "$POD_CIDR";
    serviceCidr = "$SERVICE_CIDR";
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
  echo "    make unlock NODE=$NODE_NAME       # first boot (TPM not yet enrolled)"
  echo "    make enroll-tpm NODE=$NODE_NAME   # once"
fi
echo ""
