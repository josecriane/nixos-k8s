{
  config,
  lib,
  pkgs,
  serverConfig ? { },
  clusterNodes ? [ ],
  ...
}:

let
  cfg = config.smart;

  monitoringEnabled = serverConfig.services.monitoring or false;

  k8sCfg = serverConfig.kubernetes or { };
  podCidr = k8sCfg.podCidr or "10.42.0.0/16";
  serviceCidr = k8sCfg.serviceCidr or "10.43.0.0/16";
  clusterSources = lib.concatStringsSep "," (
    (map (n: n.ip) clusterNodes)
    ++ [
      podCidr
      serviceCidr
    ]
  );
  hasCluster = clusterNodes != [ ];
in
{
  options.smart = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable SMART monitoring (smartd + periodic health/temperature/space checks).";
    };

    tempThreshold = lib.mkOption {
      type = lib.types.int;
      default = 55;
      description = "Temperature in Celsius above which a warning is logged.";
    };

    usageThreshold = lib.mkOption {
      type = lib.types.int;
      default = 85;
      description = "Filesystem usage percent above which a warning is logged.";
    };

    monitoredPaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "/" ];
      description = "Filesystem paths checked by the disk-space timer.";
    };

    exporter = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = monitoringEnabled;
        defaultText = lib.literalExpression "serverConfig.services.monitoring or false";
        description = ''
          Expose SMART attributes to Prometheus via smartctl_exporter.
          Defaults to true when cluster monitoring is enabled so the upstream
          smartctl ServiceMonitor has something to scrape.
        '';
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 9633;
        description = "Port for smartctl_exporter.";
      };
      openFirewall = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Open the exporter port in the firewall (LAN only).";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = with pkgs; [
      smartmontools
      nvme-cli
    ];

    services.smartd = {
      enable = true;
      autodetect = true;
      notifications = {
        mail.enable = false;
        wall.enable = true;
      };
      defaults.monitored = "-a -o on -s (S/../.././02|L/../../6/03)";
    };

    services.prometheus.exporters.smartctl = lib.mkIf cfg.exporter.enable {
      enable = true;
      port = cfg.exporter.port;
      openFirewall = cfg.exporter.openFirewall;
    };

    # The upstream smartctl_exporter module runs --smartctl scan which picks
    # up iSCSI virtual disks (e.g. Longhorn replicas) and emits 0C readings
    # that pollute Prometheus. Wrap ExecStart so only non-iSCSI block devices
    # are passed as --smartctl.device.
    systemd.services."prometheus-smartctl-exporter".serviceConfig.ExecStart =
      let
        exporterCfg = config.services.prometheus.exporters.smartctl;
        start = pkgs.writeShellScript "smartctl-exporter-start" ''
          set -eu
          args=(
            "--web.listen-address=${exporterCfg.listenAddress}:${toString exporterCfg.port}"
            "--smartctl.interval=${exporterCfg.maxInterval}"
          )
          while IFS= read -r dev; do
            [ -n "$dev" ] || continue
            args+=("--smartctl.device=$dev")
          done < <(${pkgs.util-linux}/bin/lsblk -dno NAME,TYPE,TRAN | \
            ${pkgs.gawk}/bin/awk '$2=="disk" && $3!="iscsi" {print "/dev/"$1}')
          exec ${pkgs.prometheus-smartctl-exporter}/bin/smartctl_exporter "''${args[@]}"
        '';
      in
      lib.mkIf cfg.exporter.enable (lib.mkForce start.outPath);

    # NVMe controller char devices ship as 0600 root:root, which the
    # smartctl-exporter user (supplementary group "disk") cannot open. Relax to
    # disk group so the exporter can query SMART on NVMe drives.
    services.udev.extraRules = lib.mkIf cfg.exporter.enable ''
      KERNEL=="nvme[0-9]*", SUBSYSTEM=="nvme", MODE="0660", GROUP="disk"
    '';

    # On K8s clusters, expose the exporter port only to other cluster nodes and
    # the pod/service CIDRs (matches the pattern used for kubelet/node-exporter).
    # Standalone hosts can still use exporter.openFirewall = true for LAN-wide.
    networking.firewall.extraCommands = lib.mkIf (cfg.exporter.enable && hasCluster) ''
      iptables -A nixos-fw -s ${clusterSources} -p tcp --dport ${toString cfg.exporter.port} -j nixos-fw-accept
    '';

    systemd.services.disk-health-check = {
      description = "SMART health check across all block devices";
      serviceConfig.Type = "oneshot";
      script = ''
        set -u
        export PATH=${
          lib.makeBinPath [
            pkgs.smartmontools
            pkgs.coreutils
            pkgs.gnugrep
            pkgs.gawk
            pkgs.util-linux
          ]
        }:$PATH

        exit_code=0
        for dev in $(lsblk -dno NAME,TYPE,TRAN | awk '$2=="disk" && $3!="iscsi" {print "/dev/"$1}'); do
          if ! out=$(smartctl -H "$dev" 2>&1); then
            echo "ERROR: smartctl failed on $dev"
            exit_code=1
            continue
          fi
          status=$(echo "$out" | grep -iE "overall-health|SMART Health Status|result" | head -1)
          echo "$dev: $status"
          if echo "$status" | grep -qiE "FAIL|BAD"; then
            echo "CRITICAL: $dev reports failing SMART status"
            exit_code=1
          fi
        done
        exit "$exit_code"
      '';
    };

    systemd.timers.disk-health-check = {
      description = "Daily SMART health check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
        RandomizedDelaySec = "15min";
      };
    };

    systemd.services.disk-temperature-check = {
      description = "Disk temperature check";
      serviceConfig.Type = "oneshot";
      script = ''
        set -u
        export PATH=${
          lib.makeBinPath [
            pkgs.smartmontools
            pkgs.coreutils
            pkgs.gnugrep
            pkgs.gawk
            pkgs.util-linux
          ]
        }:$PATH

        threshold=${toString cfg.tempThreshold}
        exit_code=0

        for dev in $(lsblk -dno NAME,TYPE,TRAN | awk '$2=="disk" && $3!="iscsi" {print "/dev/"$1}'); do
          temp=$(smartctl -A "$dev" 2>/dev/null | \
            awk '/Temperature_Celsius|Current Drive Temperature|Temperature:/ { for (i=1;i<=NF;i++) if ($i+0>0 && $i+0<150) { print $i+0; exit } }')
          [ -z "$temp" ] && continue
          if [ "$temp" -ge "$threshold" ]; then
            echo "WARNING: $dev temperature is $temp C (threshold: $threshold C)"
            exit_code=1
          else
            echo "OK: $dev temperature $temp C"
          fi
        done
        exit "$exit_code"
      '';
    };

    systemd.timers.disk-temperature-check = {
      description = "Hourly disk temperature check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "hourly";
        Persistent = true;
        RandomizedDelaySec = "5min";
      };
    };

    systemd.services.disk-space-check = {
      description = "Disk space usage check";
      serviceConfig.Type = "oneshot";
      script = ''
        set -u
        export PATH=${
          lib.makeBinPath [
            pkgs.coreutils
            pkgs.gnugrep
            pkgs.gawk
            pkgs.util-linux
          ]
        }:$PATH

        threshold=${toString cfg.usageThreshold}
        exit_code=0

        for path in ${lib.concatStringsSep " " (map (p: "'${p}'") cfg.monitoredPaths)}; do
          [ -d "$path" ] || continue
          mountpoint -q "$path" 2>/dev/null || true
          usage=$(df --output=pcent "$path" | tail -1 | tr -d ' %')
          [ -z "$usage" ] && continue
          if [ "$usage" -ge "$threshold" ]; then
            echo "WARNING: $path is at $usage% (threshold: $threshold%)"
            exit_code=1
          else
            echo "OK: $path at $usage%"
          fi
        done
        exit "$exit_code"
      '';
    };

    systemd.timers.disk-space-check = {
      description = "Daily disk space check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
        RandomizedDelaySec = "30min";
      };
    };
  };
}
