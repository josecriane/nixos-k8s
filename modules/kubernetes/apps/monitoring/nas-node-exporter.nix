# Scrape node_exporter running on each enabled NAS host (port 9100).
# Cluster nodes already expose node-exporter via kube-prometheus-stack's
# DaemonSet; this module adds NAS hosts (which live outside the cluster).
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
  port = 9100;

  enabledNas = lib.filter (n: n.enabled or false) (
    lib.mapAttrsToList (name: cfg: cfg // { inherit name; }) (serverConfig.nas or { })
  );

  enabled = enabledNas != [ ];

  endpointAddresses = lib.concatMapStringsSep "\n" (n: ''
    - ip: ${n.ip}
      hostname: ${n.hostname or n.name}'') enabledNas;

  manifestText = ''
    apiVersion: v1
    kind: Service
    metadata:
      name: nas-node-exporter
      namespace: ${ns}
      labels:
        app.kubernetes.io/name: nas-node-exporter
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
      name: nas-node-exporter
      namespace: ${ns}
      labels:
        app.kubernetes.io/name: nas-node-exporter
    subsets:
      - addresses:
    ${lib.concatMapStringsSep "\n" (l: "      ${l}") (lib.splitString "\n" endpointAddresses)}
        ports:
          - name: metrics
            port: ${toString port}
            protocol: TCP
    ---
    apiVersion: monitoring.coreos.com/v1
    kind: ServiceMonitor
    metadata:
      name: nas-node-exporter
      namespace: ${ns}
      labels:
        release: kube-prometheus-stack
    spec:
      namespaceSelector:
        matchNames:
          - ${ns}
      selector:
        matchLabels:
          app.kubernetes.io/name: nas-node-exporter
      endpoints:
        - port: metrics
          interval: 30s
          scrapeTimeout: 20s
          relabelings:
            - sourceLabels: [__meta_kubernetes_endpoint_hostname]
              targetLabel: instance
            - targetLabel: job
              replacement: nas-node-exporter
  '';

  manifest = pkgs.writeText "nas-node-exporter-scrape.yaml" manifestText;

  configHash = builtins.hashString "sha256" manifestText;
in
lib.optionalAttrs enabled {
  systemd.services.nas-node-exporter-scrape-setup = {
    description = "Register NAS node_exporter targets with Prometheus";
    after = [ "kube-prometheus-stack-setup.service" ];
    requires = [ "kube-prometheus-stack-setup.service" ];
    wantedBy = [ "k3s-core.target" ];
    before = [ "k3s-core.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "nas-node-exporter-scrape-setup" ''
        ${k8s.libShSource}
        setup_preamble_hash "/var/lib/nas-node-exporter-scrape-setup-done" \
          "NAS node_exporter scrape" "${configHash}"

        wait_for_k3s
        ensure_namespace "${ns}"

        $KUBECTL apply -f ${manifest}

        print_success "NAS node_exporter scrape" \
          "Endpoints: ${
            lib.concatMapStringsSep ", " (n: "${n.name} (${n.ip}:${toString port})") enabledNas
          }"

        create_marker "/var/lib/nas-node-exporter-scrape-setup-done" "${configHash}"
      '';
    };
  };
}
