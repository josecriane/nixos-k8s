#!/usr/bin/env bash
set -euo pipefail

# Install a NixOS node using nixos-anywhere.
# Usage: ./scripts/install.sh <node-name> <node-ip>

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$SCRIPT_DIR")}"
CONFIG_FILE="$PROJECT_DIR/config.nix"

NODE="${1:-}"
NODE_IP="${2:-}"

if [[ -z "$NODE" || -z "$NODE_IP" ]]; then
  echo "Usage: $0 <node-name> <node-ip>"
  exit 1
fi

HOST_DIR="$PROJECT_DIR/hosts/${NODE}"
HW_CONFIG="${HOST_DIR}/hardware-configuration.nix"

echo -e "${BLUE}=== NixOS K8s - Installing node: ${NODE} ===${NC}"
echo ""

# Verify connectivity
echo -e "${YELLOW}Verifying connectivity with ${NODE_IP}...${NC}"
if ! ping -c 1 -W 2 "$NODE_IP" &>/dev/null; then
  echo -e "${RED}Cannot reach ${NODE_IP}${NC}"
  echo "Verify the server is powered on and connected to the network."
  exit 1
fi
echo -e "${GREEN}Server reachable${NC}"

# Clean known_hosts to avoid conflicts with reinstallations
ssh-keygen -R "$NODE_IP" &>/dev/null || true

# Detect SSH user
echo -e "${YELLOW}Detecting SSH user...${NC}"
ADMIN_USER=$(grep 'adminUser =' "$CONFIG_FILE" | sed 's/.*"\(.*\)".*/\1/')

if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes "$ADMIN_USER@$NODE_IP" "echo ok" &>/dev/null; then
  SSH_USER="$ADMIN_USER"
  echo -e "${GREEN}Connecting as $SSH_USER (existing NixOS)${NC}"
elif command -v sshpass &>/dev/null && sshpass -p nixos ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o PubkeyAuthentication=no "nixos@$NODE_IP" "echo ok" &>/dev/null; then
  SSH_USER="nixos"
  echo -e "${GREEN}Connecting as nixos (installation ISO)${NC}"
elif ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes "nixos@$NODE_IP" "echo ok" &>/dev/null; then
  SSH_USER="nixos"
  echo -e "${GREEN}Connecting as nixos (existing SSH key)${NC}"
else
  echo -e "${YELLOW}Could not detect SSH user automatically${NC}"
  echo ""
  echo "Which user to connect to $NODE_IP?"
  echo "  1) nixos (installation ISO)"
  echo "  2) $ADMIN_USER (existing NixOS)"
  read -rp "Select [1/2]: " choice
  case "$choice" in
    1) SSH_USER="nixos" ;;
    2) SSH_USER="$ADMIN_USER" ;;
    *) echo "Invalid option"; exit 1 ;;
  esac
  echo -e "${GREEN}Using user: $SSH_USER${NC}"
fi

# Copy SSH key if needed
if ! ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes "$SSH_USER@$NODE_IP" "echo ok" &>/dev/null; then
  echo -e "${YELLOW}Copying SSH key to the server...${NC}"
  if [[ "$SSH_USER" == "nixos" ]]; then
    if command -v sshpass &>/dev/null; then
      echo -e "${YELLOW}Using sshpass to copy SSH key (password: nixos)...${NC}"
      sshpass -p nixos ssh-copy-id -o StrictHostKeyChecking=no -o PubkeyAuthentication=no "$SSH_USER@$NODE_IP"
    else
      echo -e "${YELLOW}sshpass not available. Enter the password for user nixos:${NC}"
      ssh-copy-id -o StrictHostKeyChecking=no -o PubkeyAuthentication=no "$SSH_USER@$NODE_IP" </dev/tty
    fi
  else
    echo -e "${YELLOW}Enter the password for user $SSH_USER:${NC}"
    ssh-copy-id -o StrictHostKeyChecking=no -o PubkeyAuthentication=no "$SSH_USER@$NODE_IP" </dev/tty
  fi
  if ! ssh -o BatchMode=yes "$SSH_USER@$NODE_IP" "echo ok" &>/dev/null; then
    echo -e "${RED}Could not copy SSH key. nixos-anywhere requires it.${NC}"
    exit 1
  fi
fi
echo -e "${GREEN}SSH key configured${NC}"

# Step 1: Generate hardware-configuration.nix
echo ""
cd "$PROJECT_DIR"

echo -e "${BLUE}=== Step 1: Detecting hardware ===${NC}"
"$SCRIPT_DIR/generate-hardware-config.sh" "$NODE" "$NODE_IP" "$SSH_USER"

# Step 2: Confirm and install
echo ""
echo -e "${RED}WARNING: This will ERASE ALL contents on the target disk!${NC}"
echo ""
read -rp "$(echo -e "${YELLOW}Continue with the installation? [y/N]:${NC} ")" confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  echo "Installation cancelled."
  exit 0
fi

# Run nixos-anywhere
echo ""
echo -e "${BLUE}=== Step 2: Installing NixOS with nixos-anywhere ===${NC}"
echo ""

# Generate SSH host keys for this node (needed for agenix + initrd SSH)
SERVER_KEY_DIR="$PROJECT_DIR/secrets/server-keys/${NODE}"
SECRETS_NIX="$PROJECT_DIR/secrets/secrets.nix"
AGENIX_IDENTITY=$(grep 'agenixIdentity' "$CONFIG_FILE" | sed 's/.*"\(.*\)".*/\1/' | sed "s|~|$HOME|" | head -1)
AGENIX_IDENTITY="${AGENIX_IDENTITY:-$HOME/.ssh/agenix}"

if [[ ! -f "$SERVER_KEY_DIR/ssh_host_ed25519_key" ]]; then
  echo -e "${YELLOW}Generating SSH host keys for ${NODE}...${NC}"
  mkdir -p "$SERVER_KEY_DIR"
  ssh-keygen -t ed25519 -f "$SERVER_KEY_DIR/ssh_host_ed25519_key" -N "" -C "root@${NODE}"
  echo -e "${GREEN}Host key generated${NC}"

  # Add host key to secrets.nix and re-encrypt
  NODE_PUB_KEY=$(cat "$SERVER_KEY_DIR/ssh_host_ed25519_key.pub" | awk '{print $1 " " $2}')

  if ! grep -q "^  ${NODE} " "$SECRETS_NIX" 2>/dev/null; then
    echo -e "${YELLOW}Adding ${NODE} host key to secrets/secrets.nix...${NC}"

    # Add the node variable and include it in allHosts
    sed -i "s|# Nomasystems agenix|${NODE} = \"${NODE_PUB_KEY}\";\n\n  # Nomasystems agenix|" "$SECRETS_NIX"

    # Update allHosts to include the new node
    if grep -q 'allHosts = \[\];' "$SECRETS_NIX"; then
      sed -i "s|allHosts = \[\];|allHosts = [ ${NODE} ];|" "$SECRETS_NIX"
    elif grep -q 'allHosts = \[' "$SECRETS_NIX"; then
      sed -i "s|allHosts = \[|allHosts = [ ${NODE} |" "$SECRETS_NIX"
    fi

    # Add node to github-pat publicKeys (bootstrap server needs it)
    sed -i "s|\"github-pat.age\".publicKeys = \[ admin \];|\"github-pat.age\".publicKeys = [ admin ${NODE} ];|" "$SECRETS_NIX"

    echo -e "${GREEN}secrets.nix updated${NC}"
  fi

  # Re-encrypt all secrets so the new node can decrypt them
  if [[ -f "$AGENIX_IDENTITY" ]]; then
    echo -e "${YELLOW}Re-encrypting secrets for ${NODE}...${NC}"
    cd "$PROJECT_DIR/secrets"
    agenix -r -i "$AGENIX_IDENTITY"
    cd "$PROJECT_DIR"
    echo -e "${GREEN}Secrets re-encrypted${NC}"
  else
    echo -e "${RED}WARNING: Cannot find $AGENIX_IDENTITY to re-encrypt secrets${NC}"
    echo "Run manually: cd secrets && agenix -r -i <your-identity-key>"
  fi
  echo ""
fi

# Prepare extra-files with SSH host keys
EXTRA_FILES=$(mktemp -d)
mkdir -p "$EXTRA_FILES/etc/ssh"
cp "$SERVER_KEY_DIR/ssh_host_ed25519_key" "$EXTRA_FILES/etc/ssh/"
cp "$SERVER_KEY_DIR/ssh_host_ed25519_key.pub" "$EXTRA_FILES/etc/ssh/"
chmod 600 "$EXTRA_FILES/etc/ssh/ssh_host_ed25519_key"

# Stage host files so the flake can see them (unstaged after install)
STAGED_FILES=()
for f in "$HOST_DIR"/*; do
  if [[ -f "$f" ]] && ! git ls-files --error-unmatch "$f" &>/dev/null 2>&1; then
    git add "$f"
    STAGED_FILES+=("$f")
  fi
done

INSTALL_EXIT=0
nix run github:nix-community/nixos-anywhere -- \
  --flake ".#${NODE}" \
  --target-host "$SSH_USER@$NODE_IP" \
  --build-on-remote \
  --extra-files "$EXTRA_FILES" \
  --option pure-eval false \
  || INSTALL_EXIT=$?

# Unstage files that were temporarily added
for f in "${STAGED_FILES[@]}"; do
  git reset HEAD "$f" &>/dev/null || true
done

if [[ "$INSTALL_EXIT" -ne 0 ]]; then
  echo -e "${RED}nixos-anywhere failed${NC}"
  exit "$INSTALL_EXIT"
fi

# Remove nixos-anywhere temporary keys from SSH agent
ssh-add -L 2>/dev/null | grep "nixos-anywhere" | while read -r key; do
  keyfile=$(mktemp)
  echo "$key" > "$keyfile"
  ssh-add -d "$keyfile" 2>/dev/null || true
  rm -f "$keyfile"
done

# After reboot, the node uses its static IP from config.nix
FINAL_IP=$(grep -A5 "\"${NODE}\"" "$CONFIG_FILE" | grep 'ip =' | sed 's/.*"\(.*\)".*/\1/' | head -1)
FINAL_IP="${FINAL_IP:-$NODE_IP}"

# Clean known_hosts for both IPs
ssh-keygen -R "$NODE_IP" 2>/dev/null || true
ssh-keygen -R "$FINAL_IP" 2>/dev/null || true

# Check if node has encryption with SSH unlock
HAS_SSH_UNLOCK=$(grep -A10 "\"${NODE}\"" "$CONFIG_FILE" | grep -c 'unlock.*=.*"ssh"' || true)
UNLOCK_PORT=$(grep -A10 "\"${NODE}\"" "$CONFIG_FILE" | grep 'sshPort' | sed 's/[^0-9]//g' | head -1)
UNLOCK_PORT="${UNLOCK_PORT:-2222}"

SSH_OPTS=(-o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o BatchMode=yes)

echo ""
echo -e "${YELLOW}Waiting for the server to reboot (${FINAL_IP})...${NC}"
sleep 10

if [[ "$HAS_SSH_UNLOCK" -gt 0 ]]; then
  echo -e "${YELLOW}Node has SSH disk unlock enabled (port ${UNLOCK_PORT})${NC}"
  echo -e "${YELLOW}Waiting for initrd SSH...${NC}"
  for i in $(seq 1 30); do
    if ssh "${SSH_OPTS[@]}" -p "$UNLOCK_PORT" "root@$FINAL_IP" "echo ok" &>/dev/null; then
      echo -e "${GREEN}Initrd SSH accessible${NC}"
      echo -e "${YELLOW}Connect to unlock the disk:${NC}"
      echo -e "  ${GREEN}ssh -p $UNLOCK_PORT root@$FINAL_IP${NC}"
      echo ""
      echo -e "${YELLOW}Waiting for disk to be unlocked...${NC}"
      break
    fi
    echo "Waiting for initrd SSH... ($i/30)"
    sleep 10
  done
fi

for i in $(seq 1 30); do
  if ssh "${SSH_OPTS[@]}" "$ADMIN_USER@$FINAL_IP" "echo ok" &>/dev/null; then
    echo -e "${GREEN}Server accessible${NC}"
    break
  fi
  echo "Waiting for SSH... ($i/30)"
  sleep 10
done

echo ""
echo -e "${GREEN}=== Installation of ${NODE} completed! ===${NC}"
echo ""
echo "Connect with:"
echo -e "  ${GREEN}ssh $ADMIN_USER@$FINAL_IP${NC}"
echo ""
echo "To deploy configuration updates:"
echo -e "  ${GREEN}make deploy NODE=$NODE${NC}"
echo ""
