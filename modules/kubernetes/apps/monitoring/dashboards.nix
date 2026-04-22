# Declarative Grafana dashboards shipped with nixos-k8s.
# The Grafana sidecar (from kube-prometheus-stack) watches every namespace for
# ConfigMaps labelled grafana_dashboard=1 and loads them as read-only dashboards.
#
# Dashboards live in ./dashboards/ as JSON and target generic cluster metrics
# (kube-state-metrics, node-exporter, smartctl_exporter, etc.). Downstream
# repos can add their own dashboards with a different source label so each
# layer only prunes what it owns.
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

  nasEnabled = lib.any (cfg: cfg.enabled or false) (lib.attrValues (serverConfig.nas or { }));

  dashboards = {
    home = ./dashboards/home.json;
    cluster-overview = ./dashboards/cluster-overview.json;
    pods = ./dashboards/pods.json;
    storage = ./dashboards/storage.json;
  }
  // lib.optionalAttrs nasEnabled {
    nas-overview = ./dashboards/nas-overview.json;
  };

  configHash = builtins.hashString "sha256" (
    builtins.toJSON (lib.mapAttrs (_: path: builtins.readFile path) dashboards)
  );

  sourceLabel = "grafana_dashboard_source=nixos-k8s";

  keepNames = lib.concatStringsSep " " (
    map (n: "grafana-dashboard-${n}") (builtins.attrNames dashboards)
  );

  applyLines = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (name: path: ''
      $KUBECTL create configmap grafana-dashboard-${name} \
        --namespace "${ns}" \
        --from-file=${name}.json=${path} \
        --dry-run=client -o yaml \
        | $KUBECTL apply --server-side --force-conflicts -f -
      $KUBECTL label --overwrite configmap grafana-dashboard-${name} \
        -n "${ns}" grafana_dashboard=1 ${sourceLabel}
    '') dashboards
  );
in
{
  systemd.services.grafana-upstream-dashboards-setup = {
    description = "Apply nixos-k8s Grafana dashboard ConfigMaps";
    after = [ "kube-prometheus-stack-setup.service" ];
    requires = [ "kube-prometheus-stack-setup.service" ];
    wantedBy = [ "k3s-core.target" ];
    before = [ "k3s-core.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "grafana-upstream-dashboards-setup" ''
        ${k8s.libShSource}
        setup_preamble_hash "/var/lib/grafana-upstream-dashboards-setup-done" \
          "nixos-k8s Grafana dashboards" "${configHash}"

        wait_for_k3s
        ensure_namespace "${ns}"

        ${applyLines}

        keep="${keepNames}"
        for cm in $($KUBECTL get cm -n "${ns}" -l ${sourceLabel} -o name 2>/dev/null); do
          name="$(basename "$cm")"
          if ! echo " $keep " | grep -q " $name "; then
            echo "Pruning $name..."
            $KUBECTL delete cm -n "${ns}" "$name" --ignore-not-found
          fi
        done

        print_success "nixos-k8s Grafana dashboards" \
          "Loaded: ${builtins.concatStringsSep ", " (builtins.attrNames dashboards)}"

        create_marker "/var/lib/grafana-upstream-dashboards-setup-done" "${configHash}"
      '';
    };
  };
}
