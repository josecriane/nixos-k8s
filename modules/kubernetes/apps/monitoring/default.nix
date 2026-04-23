# Monitoring stack: kube-prometheus-stack + Loki + Promtail
#
# Grafana dashboards come from two places:
#   - Declarative: ConfigMaps labelled grafana_dashboard=1 (sidecar picks them up, read-only in UI)
#   - Ad-hoc: created via the UI, persisted in the Grafana PVC (freely editable/deletable)
#
# config.nix:
#   services.monitoring = true;
#
# Optional StorageClass for all monitoring PVCs (Grafana, Prometheus,
# Alertmanager, Loki). Omit to use the cluster default SC.
#   monitoring.storageClass = "longhorn";
#
# Optional middlewares for ingress auth (homelab typically sets forward-auth):
#   monitoring.prometheus.middlewares   = [ { name = "forward-auth"; namespace = "traefik-system"; } ];
#   monitoring.alertmanager.middlewares = [ { name = "forward-auth"; namespace = "traefik-system"; } ];
#   monitoring.grafana.middlewares      = [ ];  # Grafana self-auths (anonymous login page -> OIDC)
#
# If prometheus/alertmanager middlewares are empty, their ingresses are NOT
# created (safer default, since they have no built-in auth). Toggling the list
# back to empty after a deploy also removes any previously-created IngressRoute.
{
  config,
  lib,
  pkgs,
  serverConfig,
  ...
}@args:

let
  k8s = import ../../lib.nix { inherit pkgs serverConfig; };
  ns = "monitoring";

  dashboardsModule = import ./dashboards.nix args;
  smartExporterModule = import ./smart-exporter.nix args;
  nasSmartExporterModule = import ./nas-smart-exporter.nix args;
  nasNodeExporterModule = import ./nas-node-exporter.nix args;
  nodeExporterRelabelModule = import ./node-exporter-relabel.nix args;

  monCfg = serverConfig.monitoring or { };
  grafanaMw = monCfg.grafana.middlewares or [ ];
  promMw = monCfg.prometheus.middlewares or [ ];
  alertMw = monCfg.alertmanager.middlewares or [ ];

  # Optional StorageClass override for every monitoring PVC. Unset = use the
  # cluster default SC (k3s local-path, Longhorn if set as default, etc.).
  storageClass = monCfg.storageClass or null;

  kpsStorageSets = lib.optionals (storageClass != null) [
    "grafana.persistence.storageClassName=${storageClass}"
    "prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName=${storageClass}"
    "alertmanager.alertmanagerSpec.storage.volumeClaimTemplate.spec.storageClassName=${storageClass}"
  ];

  lokiStorageSets = lib.optionals (storageClass != null) [
    "singleBinary.persistence.storageClass=${storageClass}"
  ];

  mwArgs = mws: builtins.concatStringsSep " " (map (m: "\"${m.name}:${m.namespace}\"") mws);

  # (Re)create the IngressRoute when middleware list is non-empty; delete any
  # stale one when empty, so toggling middlewares off never leaves an
  # unauthenticated ingress pointing at Prometheus/AM.
  ingressToggle =
    name: svc: port: host: mws:
    if mws != [ ] then
      ''
        create_ingress_route \
          "${name}" "${ns}" \
          "$(hostname ${host})" \
          "${svc}" ${toString port} ${mwArgs mws}
      ''
    else
      ''
        $KUBECTL delete ingressroute.traefik.io "${name}" -n "${ns}" --ignore-not-found
      '';

  prePromIngress =
    ingressToggle "prometheus" "kube-prometheus-stack-prometheus" 9090 "prometheus"
      promMw;
  preAlertIngress =
    ingressToggle "alertmanager" "kube-prometheus-stack-alertmanager" 9093 "alertmanager"
      alertMw;

  preHelmKps = pkgs.writeShellScript "kube-prometheus-stack-pre-helm" ''
    ${k8s.libShSource}
    set -euo pipefail
    wait_for_k3s
    ensure_namespace "${ns}" "privileged"

    # The Grafana sub-chart reads admin-user/admin-password from existingSecret.
    # Create if missing or recreate if the secret uses different keys
    # (e.g. legacy ADMIN_USER/ADMIN_PASSWORD from a previous setup).
    if ! $KUBECTL get secret grafana-admin-credentials -n "${ns}" -o jsonpath='{.data.admin-user}' 2>/dev/null | grep -q .; then
      echo "Creating grafana-admin-credentials with a fresh password..."
      $KUBECTL delete secret grafana-admin-credentials -n "${ns}" --ignore-not-found
      PASSWORD=$(generate_password 24)
      $KUBECTL create secret generic grafana-admin-credentials \
        --namespace "${ns}" \
        --from-literal=admin-user=admin \
        --from-literal=admin-password="$PASSWORD"
      $KUBECTL label secret grafana-admin-credentials -n "${ns}" k8s/credential=true --overwrite
    fi

    # Grafana uses RWO PVC. A previous failed rollout can leave two pods competing
    # for the PVC (Multi-Attach error). Detect more than one Grafana pod and
    # delete the Deployment to let helm recreate it cleanly with Recreate strategy.
    GRAFANA_PODS=$($KUBECTL get pods -n "${ns}" -l app.kubernetes.io/name=grafana --no-headers 2>/dev/null | wc -l)
    if [ "$GRAFANA_PODS" -gt 1 ]; then
      echo "Multiple Grafana pods detected ($GRAFANA_PODS), deleting deployment to unstick rollout..."
      $KUBECTL delete deployment kube-prometheus-stack-grafana -n "${ns}" --ignore-not-found --wait=true
    fi

    # Grafana's envFromSecret references grafana-oidc-env. Ensure an (empty) stub
    # exists so the pod can start even before the downstream OIDC setup runs.
    # The real values (GF_AUTH_GENERIC_OAUTH_*) are written later by the homelab
    # grafana-oidc-setup service.
    if ! $KUBECTL get secret grafana-oidc-env -n "${ns}" &>/dev/null; then
      echo "Creating stub grafana-oidc-env secret..."
      $KUBECTL create secret generic grafana-oidc-env -n "${ns}"
    fi
  '';

  kps = k8s.createHelmRelease {
    name = "kube-prometheus-stack";
    namespace = ns;
    tier = "core";
    timeout = "15m";
    repo = {
      name = "prometheus-community";
      url = "https://prometheus-community.github.io/helm-charts";
    };
    chart = "prometheus-community/kube-prometheus-stack";
    valuesFile = ./values-kps.yaml;
    sets = kpsStorageSets;
    # node-exporter DaemonSet uses hostPath/hostNetwork/hostPID.
    pssLevel = "privileged";
    ingress = {
      host = "grafana";
      service = "kube-prometheus-stack-grafana";
      port = 80;
    };
    middlewares = grafanaMw;
    extraScript = ''
      ${prePromIngress}
      ${preAlertIngress}
    '';
  };

  loki = k8s.createHelmRelease {
    name = "loki";
    namespace = ns;
    tier = "core";
    timeout = "5m";
    repo = {
      name = "grafana";
      url = "https://grafana.github.io/helm-charts";
    };
    chart = "grafana/loki";
    valuesFile = ./values-loki.yaml;
    sets = lokiStorageSets;
    # Shared "monitoring" namespace hosts privileged workloads (node-exporter,
    # promtail). Keep the label consistent so intermediate deploys don't
    # temporarily demote it to baseline.
    pssLevel = "privileged";
  };

  promtail = k8s.createHelmRelease {
    name = "promtail";
    namespace = ns;
    tier = "core";
    timeout = "5m";
    repo = {
      name = "grafana";
      url = "https://grafana.github.io/helm-charts";
    };
    chart = "grafana/promtail";
    valuesFile = ./values-promtail.yaml;
    # Promtail DaemonSet needs hostPath + privileged to read /var/log.
    pssLevel = "privileged";
  };
in
lib.recursiveUpdate
  (builtins.foldl' lib.recursiveUpdate kps [
    loki
    dashboardsModule
    smartExporterModule
    nasSmartExporterModule
    nasNodeExporterModule
    nodeExporterRelabelModule
  ])
  (
    lib.recursiveUpdate promtail {
      systemd.services.kube-prometheus-stack-setup = {
        serviceConfig.ExecStartPre = "${preHelmKps}";
      };
      systemd.services.loki-setup = {
        after = (loki.systemd.services.loki-setup.after or [ ]) ++ [
          "kube-prometheus-stack-setup.service"
        ];
        wants = [ "kube-prometheus-stack-setup.service" ];
      };
      systemd.services.promtail-setup = {
        after = (promtail.systemd.services.promtail-setup.after or [ ]) ++ [
          "loki-setup.service"
        ];
        wants = [ "loki-setup.service" ];
      };
    }
  )
