{
  config,
  lib,
  pkgs,
  ...
}:

{
  # Firewall
  networking.firewall = {
    enable = true;
    allowPing = true;

    allowedTCPPorts = [
      80 # HTTP  - Traefik
      443 # HTTPS - Traefik
    ];
  };

  # Fail2ban for brute force protection
  services.fail2ban = {
    enable = true;
    maxretry = 5;
    bantime = "1h";
    bantime-increment = {
      enable = true;
      maxtime = "48h";
      factor = "4";
    };

    jails = {
      sshd = {
        settings = {
          enabled = true;
          port = "ssh";
          maxretry = 3;
        };
      };
    };
  };

  # Security limits
  security.protectKernelImage = true;

  # Kernel hardening
  boot.kernel.sysctl = {
    "kernel.dmesg_restrict" = 1;
    "kernel.kptr_restrict" = 2;
    "kernel.unprivileged_bpf_disabled" = 1;
    "net.core.bpf_jit_harden" = 2;
    "kernel.yama.ptrace_scope" = 1;
    "net.ipv4.conf.all.rp_filter" = 1;
    "net.ipv4.conf.all.log_martians" = 1;
    "net.ipv4.tcp_syncookies" = 1;
  };
}
