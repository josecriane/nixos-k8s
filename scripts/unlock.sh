#!/usr/bin/env bash
set -euo pipefail

# Unlock a node's encrypted root disk via initrd SSH.
# Only works for nodes with encryption.unlock = "ssh".
# Usage: ./scripts/unlock.sh <node-name>

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$SCRIPT_DIR")}"
CONFIG_FILE="$PROJECT_DIR/config.nix"

NODE="${1:-}"

if [[ -z "$NODE" ]]; then
  echo "Usage: $0 <node-name>"
  exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo -e "${RED}config.nix not found at $CONFIG_FILE${NC}"
  exit 1
fi

NIX_EVAL="nix eval --raw --impure"

NODE_IP=$($NIX_EVAL --expr "(import $CONFIG_FILE).nodes.$NODE.ip" 2>/dev/null || true)
if [[ -z "$NODE_IP" ]]; then
  echo -e "${RED}Node '$NODE' not found in $CONFIG_FILE${NC}"
  exit 1
fi

ENCRYPT_ENABLED=$(nix eval --impure --expr \
  "(import $CONFIG_FILE).nodes.$NODE.encryption.enable or false" 2>/dev/null || echo false)
if [[ "$ENCRYPT_ENABLED" != "true" ]]; then
  echo -e "${RED}Node '$NODE' does not have encryption enabled${NC}"
  exit 1
fi

METHOD=$($NIX_EVAL --expr "(import $CONFIG_FILE).nodes.$NODE.encryption.unlock or \"ssh\"" 2>/dev/null || echo ssh)
if [[ "$METHOD" == "tpm" ]]; then
  echo -e "${YELLOW}Node uses TPM unlock. Using SSH fallback (needed for first boot or TPM failure).${NC}"
fi

PORT=$(nix eval --impure --expr \
  "toString ((import $CONFIG_FILE).nodes.$NODE.encryption.sshPort or 2222)" 2>/dev/null | tr -d '"')

IDENTITY=$($NIX_EVAL --expr "(import $CONFIG_FILE).agenixIdentity or \"\"" 2>/dev/null \
  | sed "s|~|$HOME|" || true)

SSH_OPTS=()
if [[ -n "$IDENTITY" ]]; then
  SSH_OPTS+=(-o "IdentityFile=$IDENTITY" -o "IdentitiesOnly=yes")
fi

echo -e "${BLUE}=== Unlocking ${NODE} at ${NODE_IP}:${PORT} ===${NC}"
echo -e "${YELLOW}Waiting for initrd SSH to accept connections...${NC}"

# Poll until the initrd SSH is reachable
for i in $(seq 1 60); do
  if nc -z -w 2 "$NODE_IP" "$PORT" 2>/dev/null; then
    echo -e "${GREEN}Initrd SSH is up${NC}"
    break
  fi
  if [[ $i -eq 60 ]]; then
    echo -e "${RED}Timed out waiting for ${NODE_IP}:${PORT}${NC}"
    exit 1
  fi
  sleep 2
done

echo -e "${YELLOW}Enter the LUKS passphrase when prompted.${NC}"
echo ""

exec ssh -t -p "$PORT" "${SSH_OPTS[@]}" "root@$NODE_IP" \
  'systemd-tty-ask-password-agent --query'
