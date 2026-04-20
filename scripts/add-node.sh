#!/usr/bin/env bash
set -euo pipefail

# Add a new node to an existing cluster.
# Only edits config.nix and scaffolds hosts/<name>/. Does not run install.
# Usage: ./scripts/add-node.sh [NAME] [IP] [ROLE]
#   NAME, IP, ROLE are optional; prompts for any missing value.
#   ROLE defaults to "agent".

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$SCRIPT_DIR")}"
CONFIG_FILE="$PROJECT_DIR/config.nix"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo -e "${RED}config.nix not found at $CONFIG_FILE${NC}"
  echo "Run 'make setup' first to create the base configuration."
  exit 1
fi

NAME="${1:-}"
IP="${2:-}"
ROLE="${3:-}"

if [[ -z "$NAME" ]]; then
  read -rp "Node name: " NAME
fi
if [[ -z "$NAME" ]]; then
  echo -e "${RED}Node name is required${NC}"
  exit 1
fi

if grep -qE "^[[:space:]]+${NAME} = \{" "$CONFIG_FILE"; then
  echo -e "${RED}Node '${NAME}' already exists in config.nix${NC}"
  exit 1
fi

if [[ -z "$IP" ]]; then
  read -rp "IP address: " IP
fi
if [[ -z "$IP" ]]; then
  echo -e "${RED}IP is required${NC}"
  exit 1
fi

if [[ -z "$ROLE" ]]; then
  read -rp "Role (server/agent) [agent]: " ROLE
  ROLE="${ROLE:-agent}"
fi
case "$ROLE" in
  server|agent) ;;
  *) echo -e "${RED}Invalid role: $ROLE (expected server or agent)${NC}"; exit 1 ;;
esac

read -rp "Enable disk encryption? (y/N): " ENCRYPT
ENCRYPTION_NIX=""
if [[ "$ENCRYPT" =~ ^[Yy]$ ]]; then
  read -rp "Unlock method (ssh/tpm) [ssh]: " UNLOCK
  UNLOCK="${UNLOCK:-ssh}"
  read -rp "Initrd SSH port [2222]: " SSH_PORT
  SSH_PORT="${SSH_PORT:-2222}"
  ENCRYPTION_NIX=$'\n      encryption = { enable = true; unlock = "'"$UNLOCK"'"; sshPort = '"$SSH_PORT"'; };'
fi

NODE_BLOCK="    ${NAME} = {
      ip = \"${IP}\";
      role = \"${ROLE}\";
      bootstrap = false;${ENCRYPTION_NIX}
    };"

# Insert before the matching closing brace of the nodes attrset.
awk -v block="$NODE_BLOCK" '
  /^[[:space:]]*nodes = \{/ { in_nodes = 1; print; next }
  in_nodes && /^[[:space:]]+\};/ {
    sub(/[[:space:]]+\};.*/, "")
    indent = $0
    print block
    print indent "};"
    in_nodes = 0
    next
  }
  { print }
' "$CONFIG_FILE" > "$CONFIG_FILE.tmp"

if ! grep -q "^    ${NAME} = {" "$CONFIG_FILE.tmp"; then
  echo -e "${RED}Failed to insert node entry into config.nix${NC}"
  echo "Is 'nodes = { ... };' present and using standard indentation?"
  rm -f "$CONFIG_FILE.tmp"
  exit 1
fi

mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
echo -e "${GREEN}Added ${NAME} (${IP}, ${ROLE}) to config.nix${NC}"

HOST_DIR="$PROJECT_DIR/hosts/${NAME}"
if [[ ! -d "$HOST_DIR" ]]; then
  TEMPLATE=""
  for candidate in "$PROJECT_DIR/hosts/server1" "$PROJECT_DIR/hosts"/*; do
    if [[ -d "$candidate" && "$candidate" != "$HOST_DIR" ]]; then
      TEMPLATE="$candidate"
      break
    fi
  done

  if [[ -n "$TEMPLATE" ]]; then
    cp -r "$TEMPLATE" "$HOST_DIR"
    rm -f "$HOST_DIR/hardware-configuration.nix"
    echo -e "${GREEN}Scaffolded hosts/${NAME}/ from $(basename "$TEMPLATE")${NC}"
    echo -e "${YELLOW}Review hosts/${NAME}/ and adjust disk-config.nix for this node's hardware.${NC}"
  else
    mkdir -p "$HOST_DIR"
    echo -e "${YELLOW}Created empty hosts/${NAME}/. Populate default.nix and disk-config.nix manually.${NC}"
  fi
fi

echo ""
echo -e "${BLUE}Next steps:${NC}"
echo "  1. Adjust hosts/${NAME}/ if needed (disk layout, bootloader, hardware quirks)."
echo "  2. Boot the target machine from a NixOS live USB."
echo "  3. make install NODE=${NAME} IP=<live-usb-ip>"
