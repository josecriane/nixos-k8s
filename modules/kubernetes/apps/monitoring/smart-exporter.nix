# Scrape smartctl_exporter running on each cluster node (port 9633).
# The exporter must be enabled per-node via `smart.exporter.enable = true`.
# Downstream layers can register additional scrape targets (e.g. NAS hosts
# outside the cluster) with a separate Service/Endpoints/ServiceMonitor.
{
  config,
  lib,
  pkgs,
  serverConfig,
  clusterNodes,
  ...
}:

let
  k8s = import ../../lib.nix { inherit pkgs serverConfig; };
  ns = "monitoring";
  port = 9633;

  clusterAddresses = lib.concatMapStringsSep "\n" (n: ''
    - ip: ${n.ip}
      hostname: ${n.name}
      targetRef:
        kind: Node
        name: ${n.name}'') clusterNodes;

  manifestText = ''
    apiVersion: v1
    kind: Service
    metadata:
      name: smartctl-exporter
      namespace: ${ns}
      labels:
        app.kubernetes.io/name: smartctl-exporter
    spec:
      type: ClusterIP
      clusterIP: None
      ports:
        - name: metrics
          port: ${toString port}
          targetPort: ${toString port}
          protocol: TCP
    ---
    apiVersion: v1
    kind: Endpoints
    metadata:
      name: smartctl-exporter
      namespace: ${ns}
      labels:
        app.kubernetes.io/name: smartctl-exporter
    subsets:
      - addresses:
    ${lib.concatMapStringsSep "\n" (l: "      ${l}") (lib.splitString "\n" clusterAddresses)}
        ports:
          - name: metrics
            port: ${toString port}
            protocol: TCP
    ---
    apiVersion: monitoring.coreos.com/v1
    kind: ServiceMonitor
    metadata:
      name: smartctl-exporter
      namespace: ${ns}
      labels:
        release: kube-prometheus-stack
    spec:
      namespaceSelector:
        matchNames:
          - ${ns}
      selector:
        matchLabels:
          app.kubernetes.io/name: smartctl-exporter
      endpoints:
        - port: metrics
          interval: 60s
          scrapeTimeout: 30s
          relabelings:
            - sourceLabels: [__meta_kubernetes_endpoint_hostname]
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

        $KUBECTL apply -f ${manifest}

        print_success "smartctl_exporter scrape" \
          "Endpoints: ${
            lib.concatMapStringsSep ", " (n: "${n.name} (${n.ip}:${toString port})") clusterNodes
          }"

        create_marker "/var/lib/smartctl-exporter-scrape-setup-done" "${configHash}"
      '';
    };
  };
}
