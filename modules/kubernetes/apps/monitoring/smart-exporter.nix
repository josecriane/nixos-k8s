# Scrape smartctl_exporter running on each cluster node (port 9633).
# The exporter must be enabled per-node via `smart.exporter.enable = true`.
# Downstream layers can register additional scrape targets (e.g. NAS hosts
# outside the cluster) with a separate Service/Endpoints/ServiceMonitor.
{
  k8s,
  config,
  lib,
  pkgs,
  serverConfig,
  ...
}:

let
  ns = "monitoring";
  port = 9633;

  manifestText = ''
    apiVersion: monitoring.coreos.com/v1alpha1
    kind: ScrapeConfig
    metadata:
      name: smartctl-exporter
      namespace: ${ns}
      labels:
        release: kube-prometheus-stack
    spec:
      jobName: smartctl-exporter
      scrapeInterval: 60s
      scrapeTimeout: 30s
      kubernetesSDConfigs:
        - role: Node
      relabelings:
        - sourceLabels: [__meta_kubernetes_node_address_InternalIP]
          targetLabel: __address__
          replacement: "$1:${toString port}"
        - sourceLabels: [__meta_kubernetes_node_name]
          targetLabel: instance
      metricRelabelings:
        # Drop Longhorn iSCSI virtual disks (model_name="IET VIRTUAL-DISK",
        # scsi_vendor="IET"). smartctl_exporter autodiscovers every block
        # device, including iSCSI targets Longhorn attaches for its volumes.
        - sourceLabels: [model_name]
          regex: "IET VIRTUAL-DISK"
          action: drop
        - sourceLabels: [scsi_vendor]
          regex: "IET"
          action: drop
  '';

  manifest = pkgs.writeText "smartctl-exporter-scrape.yaml" manifestText;

  configHash = builtins.hashString "sha256" manifestText;
in
{
  systemd.services.smartctl-exporter-scrape-setup = {
    description = "Register cluster smartctl_exporter targets with Prometheus";
    after = [ "kube-prometheus-stack-setup.service" ];
    requires = [ "kube-prometheus-stack-setup.service" ];
    wantedBy = [ "k3s-core.target" ];
    before = [ "k3s-core.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "smartctl-exporter-scrape-setup" ''
        ${k8s.libShSource}
        setup_preamble_hash "/var/lib/smartctl-exporter-scrape-setup-done" \
          "smartctl_exporter scrape" "${configHash}"

        wait_for_k3s
        ensure_namespace "${ns}"

        $KUBECTL -n ${ns} delete servicemonitor,service,endpoints smartctl-exporter --ignore-not-found
        $KUBECTL apply -f ${manifest}

        print_success "smartctl_exporter scrape" \
          "Discovers every cluster node on port ${toString port}"

        create_marker "/var/lib/smartctl-exporter-scrape-setup-done" "${configHash}"
      '';
    };
  };
}
