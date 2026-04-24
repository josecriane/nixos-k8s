#!/usr/bin/env bash
set -euo pipefail

# Pull the Kubernetes CA and apitoken from a freshly-installed bootstrap
# node, encrypt them with agenix, and drop the .age files into secrets/.
# Worker nodes then consume those via `age.secrets` in kubeadm.nix, which
# keeps the multi-node setup fully declarative (no more manual scp of
# /var/lib/kubernetes/secrets/ from master to worker).
#
# Usage: ./scripts/sync-bootstrap-secrets.sh <bootstrap-node-name>
#
# Pre-reqs:
#   - Bootstrap node already installed and running.
#   - secrets/secrets.nix has publicKeys rules for kubernetes-ca.age and
#     kubernetes-apitoken.age (add them to `allKeys` so every worker can
#     decrypt, including ones you add later).

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "$SCRIPT_DIR")}"
CONFIG_FILE="$PROJECT_DIR/config.nix"
SECRETS_DIR="$PROJECT_DIR/secrets"

NODE="${1:-}"
if [[ -z "$NODE" ]]; then
  echo "Usage: $0 <bootstrap-node-name>"
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

IS_BOOTSTRAP=$(nix eval --impure --json --expr "(import $CONFIG_FILE).nodes.$NODE.bootstrap or false" 2>/dev/null || echo false)
if [[ "$IS_BOOTSTRAP" != "true" ]]; then
  echo -e "${RED}Node '$NODE' is not the bootstrap (bootstrap = false).${NC}"
  exit 1
fi

ADMIN_USER=$($NIX_EVAL --expr "(import $CONFIG_FILE).adminUser" 2>/dev/null)
AGENIX_IDENTITY=$($NIX_EVAL --expr "(import $CONFIG_FILE).agenixIdentity or \"\"" 2>/dev/null | sed "s|~|$HOME|" | head -1)
AGENIX_IDENTITY="${AGENIX_IDENTITY:-$HOME/.ssh/agenix}"

if [[ ! -f "$AGENIX_IDENTITY" ]]; then
  echo -e "${RED}Cannot find agenix identity at $AGENIX_IDENTITY${NC}"
  exit 1
fi

echo -e "${BLUE}=== Syncing bootstrap secrets from ${NODE} (${NODE_IP}) ===${NC}"

# Copy to /tmp with the admin user so we can scp without sudo on the wire.
# Each ssh -t opens its own pty so sudo can prompt for the password.
echo -e "${YELLOW}Copying ca.pem + apitoken.secret to remote /tmp...${NC}"
ssh -t "$ADMIN_USER@$NODE_IP" "sudo install -m 644 -o '$ADMIN_USER' /var/lib/kubernetes/secrets/ca.pem /tmp/bootstrap-ca.pem"
ssh -t "$ADMIN_USER@$NODE_IP" "sudo install -m 600 -o '$ADMIN_USER' /var/lib/kubernetes/secrets/apitoken.secret /tmp/bootstrap-apitoken.secret"

TMPDIR=$(mktemp -d)
cleanup() {
  rm -rf "$TMPDIR"
  ssh -o ConnectTimeout=5 "$ADMIN_USER@$NODE_IP" \
    "rm -f /tmp/bootstrap-ca.pem /tmp/bootstrap-apitoken.secret" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo -e "${YELLOW}Downloading to local tmpfs...${NC}"
scp -q "$ADMIN_USER@$NODE_IP:/tmp/bootstrap-ca.pem" "$TMPDIR/ca.pem"
scp -q "$ADMIN_USER@$NODE_IP:/tmp/bootstrap-apitoken.secret" "$TMPDIR/apitoken.secret"

if [[ ! -s "$TMPDIR/ca.pem" || ! -s "$TMPDIR/apitoken.secret" ]]; then
  echo -e "${RED}Downloaded files are empty. Is the bootstrap node fully up?${NC}"
  exit 1
fi

echo -e "${YELLOW}Encrypting with agenix...${NC}"
cd "$SECRETS_DIR"
if ! grep -q '"kubernetes-ca.age"' secrets.nix 2>/dev/null; then
  echo -e "${RED}secrets.nix is missing a publicKeys rule for kubernetes-ca.age.${NC}"
  echo "Add these two lines to secrets/secrets.nix:"
  echo '  "kubernetes-ca.age".publicKeys = allKeys;'
  echo '  "kubernetes-apitoken.age".publicKeys = allKeys;'
  exit 1
fi

EDITOR="cp $TMPDIR/ca.pem" agenix -e kubernetes-ca.age -i "$AGENIX_IDENTITY"
EDITOR="cp $TMPDIR/apitoken.secret" agenix -e kubernetes-apitoken.age -i "$AGENIX_IDENTITY"

echo ""
echo -e "${GREEN}=== Done ===${NC}"
echo "Secrets written to:"
echo -e "  ${GREEN}$SECRETS_DIR/kubernetes-ca.age${NC}"
echo -e "  ${GREEN}$SECRETS_DIR/kubernetes-apitoken.age${NC}"
echo ""
echo "Commit and push, then workers can be installed without manual scp:"
echo -e "  ${GREEN}git add secrets/kubernetes-ca.age secrets/kubernetes-apitoken.age${NC}"
echo -e "  ${GREEN}git commit -m 'chore: sync bootstrap CA and apitoken for workers'${NC}"
