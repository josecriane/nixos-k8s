# Scrape smartctl_exporter running on each enabled NAS host (port 9633).
# Cluster nodes are scraped by smart-exporter.nix; this module registers a
# separate Service/Endpoints/ServiceMonitor for NAS hosts (outside the cluster).
# No-op if no entry in serverConfig.nas has enabled=true.
{
  config,
  lib,
  pkgs,
  serverConfig,
  ...
}:

let
  k8s = import ../../lib.nix { inherit pkgs serverConfig; };
  ns = "monitoring";
  port = 9633;

  enabledNas = lib.filter (n: n.enabled or false) (
    lib.mapAttrsToList (name: cfg: cfg // { inherit name; }) (serverConfig.nas or { })
  );

  enabled = enabledNas != [ ];

  nasAddresses = lib.concatMapStringsSep "\n" (n: ''
    - ip: ${n.ip}
      hostname: ${n.hostname or n.name}'') enabledNas;

  manifestText = ''
    apiVersion: v1
    kind: Service
    metadata:
      name: nas-smartctl-exporter
      namespace: ${ns}
      labels:
        app.kubernetes.io/name: nas-smartctl-exporter
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
      name: nas-smartctl-exporter
      namespace: ${ns}
      labels:
        app.kubernetes.io/name: nas-smartctl-exporter
    subsets:
      - addresses:
    ${lib.concatMapStringsSep "\n" (l: "      ${l}") (lib.splitString "\n" nasAddresses)}
        ports:
          - name: metrics
            port: ${toString port}
            protocol: TCP
    ---
    apiVersion: monitoring.coreos.com/v1
    kind: ServiceMonitor
    metadata:
      name: nas-smartctl-exporter
      namespace: ${ns}
      labels:
        release: kube-prometheus-stack
    spec:
      namespaceSelector:
        matchNames:
          - ${ns}
      selector:
        matchLabels:
          app.kubernetes.io/name: nas-smartctl-exporter
      endpoints:
        - port: metrics
          interval: 60s
          scrapeTimeout: 30s
          relabelings:
            - sourceLabels: [__meta_kubernetes_endpoint_hostname]
              targetLabel: instance
  '';

  manifest = pkgs.writeText "nas-smartctl-exporter-scrape.yaml" manifestText;

  configHash = builtins.hashString "sha256" manifestText;
in
lib.optionalAttrs enabled {
  systemd.services.nas-smartctl-exporter-scrape-setup = {
    description = "Register NAS smartctl_exporter targets with Prometheus";
    after = [ "kube-prometheus-stack-setup.service" ];
    requires = [ "kube-prometheus-stack-setup.service" ];
    wantedBy = [ "k3s-core.target" ];
    before = [ "k3s-core.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "nas-smartctl-exporter-scrape-setup" ''
        ${k8s.libShSource}
        setup_preamble_hash "/var/lib/nas-smartctl-exporter-scrape-setup-done" \
          "NAS smartctl_exporter scrape" "${configHash}"

        wait_for_k3s
        ensure_namespace "${ns}"

        $KUBECTL apply -f ${manifest}

        print_success "NAS smartctl_exporter scrape" \
          "Endpoints: ${
            lib.concatMapStringsSep ", " (n: "${n.name} (${n.ip}:${toString port})") enabledNas
          }"

        create_marker "/var/lib/nas-smartctl-exporter-scrape-setup-done" "${configHash}"
      '';
    };
  };
}
