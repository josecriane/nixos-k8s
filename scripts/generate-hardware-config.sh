#!/usr/bin/env bash
set -euo pipefail

# Generate hardware-configuration.nix for a node by probing the target machine.
# Usage: ./scripts/generate-hardware-config.sh <node-name> <node-ip> [user]

NODE="${1:-}"
NODE_IP="${2:-}"
SSH_USER="${3:-nixos}"

if [[ -z "$NODE" || -z "$NODE_IP" ]]; then
  echo "Usage: $0 <node-name> <node-ip> [user]"
  exit 1
fi

HOST_DIR="hosts/${NODE}"
HW_CONFIG="${HOST_DIR}/hardware-configuration.nix"

mkdir -p "$HOST_DIR"

# Skip if hardware-configuration.nix already exists
if [[ -f "$HW_CONFIG" ]]; then
  echo "Hardware config already exists: ${HW_CONFIG} (skipping detection)"
  exit 0
fi

echo "Detecting hardware on ${NODE} (${NODE_IP})..."

# Get the raw hardware config from the live system
RAW_CONFIG=$(ssh -o StrictHostKeyChecking=accept-new "${SSH_USER}@${NODE_IP}" \
  "sudo nixos-generate-config --show-hardware-config 2>/dev/null")

if [[ -z "$RAW_CONFIG" ]]; then
  echo "ERROR: Failed to get hardware config from ${SSH_USER}@${NODE_IP}"
  exit 1
fi

# Extract initrd kernel modules
INITRD_MODULES=$(echo "$RAW_CONFIG" | \
  sed -n '/boot\.initrd\.availableKernelModules/,/\];/p' | \
  grep -oP '"[^"]+"' | tr '\n' ' ')

# Extract kernel modules
KERNEL_MODULES=$(echo "$RAW_CONFIG" | \
  sed -n '/boot\.kernelModules/,/\];/p' | \
  grep -oP '"[^"]+"' | tr '\n' ' ')

# Detect CPU vendor from kernel modules or raw config
if echo "$KERNEL_MODULES" | grep -q '"kvm-amd"'; then
  CPU_VENDOR="amd"
elif echo "$KERNEL_MODULES" | grep -q '"kvm-intel"'; then
  CPU_VENDOR="intel"
else
  # Fallback: check the remote system directly
  CPU_INFO=$(ssh "${SSH_USER}@${NODE_IP}" "grep -m1 vendor_id /proc/cpuinfo" 2>/dev/null || true)
  if echo "$CPU_INFO" | grep -qi "AuthenticAMD"; then
    CPU_VENDOR="amd"
  else
    CPU_VENDOR="intel"
  fi
fi

# Detect primary disk device (prefer nvme > sda > vda)
DISK_DEVICE=$(ssh "${SSH_USER}@${NODE_IP}" '
  if [ -e /dev/nvme0n1 ]; then
    echo "/dev/nvme0n1"
  elif [ -e /dev/sda ]; then
    echo "/dev/sda"
  elif [ -e /dev/vda ]; then
    echo "/dev/vda"
  else
    lsblk -dpno NAME | grep -v loop | head -1
  fi
')

if [[ -z "$DISK_DEVICE" ]]; then
  echo "ERROR: Could not detect a disk device on the target"
  exit 1
fi

# Detect network driver (needed for initrd SSH unlock)
NET_DRIVER=$(ssh "${SSH_USER}@${NODE_IP}" '
  for iface in /sys/class/net/e*; do
    [ -e "$iface/device/driver" ] && basename $(readlink "$iface/device/driver") && break
  done
' 2>/dev/null || true)

# Add network driver to initrd modules if not already present
if [[ -n "$NET_DRIVER" ]] && ! echo "$INITRD_MODULES" | grep -q "\"$NET_DRIVER\""; then
  INITRD_MODULES="$INITRD_MODULES \"$NET_DRIVER\""
fi

# Format the initrd modules list for nix
format_nix_list() {
  local modules="$1"
  echo "$modules" | tr ' ' '\n' | grep -v '^$' | sed 's/^/    /' | paste -sd $'\n' -
}

INITRD_LIST=$(format_nix_list "$INITRD_MODULES")
KERNEL_LIST=$(format_nix_list "$KERNEL_MODULES")

# Set CPU-specific values
if [[ "$CPU_VENDOR" == "amd" ]]; then
  KVM_MODULE='"kvm-amd"'
  MICROCODE_LINE="hardware.cpu.amd.updateMicrocode = true;"
else
  KVM_MODULE='"kvm-intel"'
  MICROCODE_LINE="hardware.cpu.intel.updateMicrocode = true;"
fi

# Make sure kvm module is in the kernel modules list
if ! echo "$KERNEL_LIST" | grep -q "kvm-"; then
  KERNEL_LIST=$(printf '%s\n    %s' "$KERNEL_LIST" "$KVM_MODULE")
fi

# Show what was detected
echo ""
echo "=== Detected hardware ==="
echo "  CPU vendor:     ${CPU_VENDOR}"
echo "  Disk device:    ${DISK_DEVICE}"
echo "  Initrd modules: ${INITRD_MODULES}"
echo "  Kernel modules: ${KERNEL_MODULES}"
echo ""

# Generate the file
cat > "$HW_CONFIG" <<NIXEOF
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  # Bootloader
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.memtest86.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.initrd.availableKernelModules = [
${INITRD_LIST}
  ];
  boot.kernelModules = [
${KERNEL_LIST}
  ];

  ${MICROCODE_LINE}

  # Firmware
  hardware.enableRedistributableFirmware = lib.mkDefault true;

  # Disk device for disko
  disko.devices.disk.main.device = "${DISK_DEVICE}";
}
NIXEOF

echo "Generated ${HW_CONFIG}"
echo ""
cat "$HW_CONFIG"
echo ""
