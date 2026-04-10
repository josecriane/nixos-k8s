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

  # Adjust these for your hardware:
  boot.initrd.availableKernelModules = [
    "nvme"
    "xhci_pci"
    "thunderbolt"
    "usbhid"
    "usb_storage"
    "sd_mod"
    "sdhci_pci"
  ];
  # For AMD: boot.kernelModules = [ "kvm-amd" ];
  # For Intel: boot.kernelModules = [ "kvm-intel" ];
  boot.kernelModules = [ "kvm-amd" ];

  # AMD microcode updates (change to hardware.cpu.intel.updateMicrocode for Intel)
  hardware.cpu.amd.updateMicrocode = true;

  # Firmware
  hardware.enableRedistributableFirmware = lib.mkDefault true;

  # Disk device for disko (adjust for your hardware)
  disko.devices.disk.main.device = "/dev/nvme0n1";
}
