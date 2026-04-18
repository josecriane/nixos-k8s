#!/usr/bin/env bash
set -euo pipefail

# Enroll TPM2 for LUKS auto-unlock on a node.
# Must be run once after a successful first boot.
# Usage: ./scripts/enroll-tpm.sh <node-name>

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$SCRIPT_DIR")}"
CONFIG_FILE="$PROJECT_DIR/config.nix"

# PCRs to bind the TPM unlock against.
# 0 = firmware, 7 = Secure Boot state. Override via env if needed.
TPM_PCRS="${TPM_PCRS:-0+7}"
LUKS_DEVICE="${LUKS_DEVICE:-/dev/disk/by-partlabel/disk-main-root}"

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

METHOD=$($NIX_EVAL --expr "(import $CONFIG_FILE).nodes.$NODE.encryption.unlock or \"\"" 2>/dev/null || true)
if [[ "$METHOD" != "tpm" ]]; then
  echo -e "${RED}Node '$NODE' is not configured for TPM unlock.${NC}"
  echo "  encryption.unlock = '${METHOD:-unset}'"
  exit 1
fi

ADMIN_USER=$($NIX_EVAL --expr "(import $CONFIG_FILE).adminUser" 2>/dev/null)

echo -e "${BLUE}=== Enrolling TPM2 on ${NODE} (${NODE_IP}) ===${NC}"
echo -e "${YELLOW}Device: ${LUKS_DEVICE}${NC}"
echo -e "${YELLOW}PCRs:   ${TPM_PCRS}${NC}"
echo ""

# Sanity-check connectivity and that the node actually has a TPM2 chip
if ! ssh -o ConnectTimeout=5 "$ADMIN_USER@$NODE_IP" "test -c /dev/tpm0 && test -c /dev/tpmrm0" 2>/dev/null; then
  echo -e "${RED}Node does not expose /dev/tpm0 or /dev/tpmrm0${NC}"
  echo "  Enable TPM2 (or Intel PTT) in the BIOS before running this command."
  exit 1
fi

# Check if TPM is already enrolled in this LUKS header
if ssh "$ADMIN_USER@$NODE_IP" "sudo cryptsetup luksDump $LUKS_DEVICE" 2>/dev/null \
     | grep -qE "systemd-tpm2|tpm2-hash-pcrs"; then
  echo -e "${YELLOW}A TPM2 keyslot is already enrolled on this device.${NC}"
  read -rp "Re-enroll (removes existing TPM keyslot first)? (y/N): " REDO
  if [[ "$REDO" != "y" && "$REDO" != "Y" ]]; then
    exit 0
  fi
  echo -e "${YELLOW}Wiping existing TPM2 keyslot...${NC}"
  ssh -t "$ADMIN_USER@$NODE_IP" \
    "sudo systemd-cryptenroll --wipe-slot=tpm2 $LUKS_DEVICE"
fi

# Passphrase: used once to authorize enrollment. Not stored.
read -rsp "Existing LUKS passphrase: " PASSPHRASE
echo ""

if [[ -z "$PASSPHRASE" ]]; then
  echo -e "${RED}Empty passphrase, aborting${NC}"
  exit 1
fi

echo -e "${YELLOW}Enrolling...${NC}"

# Pipe the passphrase via stdin. The remote reads it into a tmp file (600),
# runs systemd-cryptenroll, and removes the tmp file afterwards.
REMOTE_CMD=$(cat <<REMOTE
set -euo pipefail
KF=\$(mktemp)
chmod 600 "\$KF"
cat > "\$KF"
sudo systemd-cryptenroll "$LUKS_DEVICE" \\
  --tpm2-device=auto \\
  --tpm2-pcrs="$TPM_PCRS" \\
  --unlock-key-file="\$KF"
shred -u "\$KF" 2>/dev/null || rm -f "\$KF"
REMOTE
)

printf '%s' "$PASSPHRASE" | ssh "$ADMIN_USER@$NODE_IP" "$REMOTE_CMD"

# Clear passphrase from shell state
unset PASSPHRASE

echo ""
echo -e "${GREEN}TPM2 enrolled on ${NODE}${NC}"
echo "  Next reboots will unlock automatically via TPM."
echo "  SSH-in-initrd remains available as fallback if TPM unlock fails."
