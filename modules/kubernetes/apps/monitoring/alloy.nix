{
  config,
  k8s,
  lib,
  pkgs,
  serverConfig,
  ...
}:

let
  ns = "monitoring";

  monCfg = serverConfig.monitoring or { };
  cfg = monCfg.alloy or { };

  lokiEnable = (monCfg.loki or { }).enable or true;
  lokiUrl =
    cfg.lokiUrl or (if lokiEnable then "http://loki." + ns + ":3100/loki/api/v1/push" else "");
  enable = (cfg.enable or lokiEnable) && lokiUrl != "";
  existingSecret = cfg.existingSecret or null;
  clusterName = cfg.clusterName or "homelab";
  dropRegex = cfg.dropRegex or "";
  chartVersion = cfg.chartVersion or "1.12.1";
  memRequest = cfg.memoryRequest or "128Mi";
  memLimit = cfg.memoryLimit or "512Mi";
  cpuRequest = cfg.cpuRequest or "50m";

  configMapName = "alloy-logs-config";
  uninstallService = import ./uninstall.nix { inherit config pkgs ns; };

  dropStage = lib.optionalString (dropRegex != "") ''

    	stage.match {
    		selector            = "{cluster!=\"\"} |~ \"${dropRegex}\""
    		action              = "drop"
    		drop_counter_reason = "dropped_by_config"
    	}'';

  alloyConfig = pkgs.writeText "alloy-logs.alloy" (
    builtins.replaceStrings [ "__DROP_STAGE__" ] [ dropStage ] (builtins.readFile ./alloy-logs.alloy)
  );

  preScript = ''
    $KUBECTL -n ${ns} create configmap ${configMapName} \
      --from-file=config.alloy=${alloyConfig} \
      --dry-run=client -o yaml | $KUBECTL apply -f -
  '';

  values = {
    controller.type = "daemonset";

    alloy = {
      configMap = {
        create = false;
        name = configMapName;
        key = "config.alloy";
      };

      mounts.varlog = true;

      securityContext.runAsUser = 0;

      extraEnv = [
        {
          name = "NODE_NAME";
          valueFrom.fieldRef.fieldPath = "spec.nodeName";
        }
        {
          name = "CLUSTER_NAME";
          value = clusterName;
        }
        {
          name = "LOKI_URL";
          value = lokiUrl;
        }
      ];

      envFrom = lib.optionals (existingSecret != null) [ { secretRef.name = existingSecret; } ];

      resources = {
        requests = {
          memory = memRequest;
          cpu = cpuRequest;
        };
        limits.memory = memLimit;
      };
    };
  };
in
if enable then
  k8s.createHelmRelease {
    name = "alloy-logs";
    namespace = ns;
    tier = "core";
    repo = {
      name = "grafana";
      url = "https://grafana.github.io/helm-charts";
    };
    chart = "grafana/alloy";
    version = chartVersion;
    inherit values preScript;
    pssLevel = "privileged";
  }
else
  uninstallService {
    name = "alloy-logs";
    extraCleanup = ''
      $KUBECTL -n ${ns} delete configmap ${configMapName} --ignore-not-found
    '';
  }
