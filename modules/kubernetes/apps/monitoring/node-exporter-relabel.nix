# Patch the kube-prometheus-stack ServiceMonitor for node-exporter so that
# `instance` holds the Kubernetes node name instead of the pod IP:port. This
# aligns cluster node_exporter targets with the smartctl_exporter targets
# (which already relabel to the hostname) and with any downstream-registered
# exporters for hosts outside the cluster.
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

  patch = pkgs.writeText "node-exporter-relabel-patch.yaml" ''
    spec:
      endpoints:
        - port: http-metrics
          scheme: http
          relabelings:
            - action: replace
              regex: (.*)
              replacement: $1
              sourceLabels: [__meta_kubernetes_pod_node_name]
              targetLabel: instance
  '';

  configHash = builtins.hashString "sha256" (builtins.readFile patch);
in
{
  systemd.services.node-exporter-relabel-setup = {
    description = "Relabel node-exporter ServiceMonitor to use node name as instance";
    after = [ "kube-prometheus-stack-setup.service" ];
    requires = [ "kube-prometheus-stack-setup.service" ];
    wantedBy = [ "k3s-core.target" ];
    before = [ "k3s-core.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "node-exporter-relabel-setup" ''
        ${k8s.libShSource}
        setup_preamble_hash "/var/lib/node-exporter-relabel-setup-done" \
          "node-exporter relabel" "${configHash}"

        wait_for_k3s
        wait_for_resource servicemonitor "${ns}" kube-prometheus-stack-prometheus-node-exporter 300

        $KUBECTL patch servicemonitor kube-prometheus-stack-prometheus-node-exporter \
          -n "${ns}" --type merge --patch-file ${patch}

        print_success "node-exporter relabel" \
          "Instance label now uses node name"

        create_marker "/var/lib/node-exporter-relabel-setup-done" "${configHash}"
      '';
    };
  };
}
