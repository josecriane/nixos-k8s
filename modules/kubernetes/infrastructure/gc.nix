{
  config,
  lib,
  pkgs,
  serverConfig,
  nodeConfig,
  ...
}:

let
  isBootstrap = nodeConfig.bootstrap or false;

  cfg = config.cluster.gc;
  enabled = cfg.enable or false;
  onCalendar = cfg.onCalendar or "*-*-* 05:00:00";
  replicaSetAgeHours = cfg.replicaSetAgeHours or 24;
  podAgeHours = cfg.podAgeHours or 24;
  jobAgeHours = cfg.jobAgeHours or 168;
  dryRun = cfg.dryRun or false;
  excludeNamespaces = cfg.excludeNamespaces or [ ];

  kubectl = "${pkgs.kubectl}/bin/kubectl";
  jq = "${pkgs.jq}/bin/jq";

  excludeCase = lib.concatStringsSep "|" excludeNamespaces;

  gcScript = pkgs.writeShellScript "k8s-gc" ''
    set -euo pipefail
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    DRY_RUN="${if dryRun then "true" else "false"}"
    NOW=$(date -u +%s)

    if [ "$DRY_RUN" = "true" ]; then
      echo "=== Kubernetes GC (dry run, nothing will be deleted) ==="
    else
      echo "=== Kubernetes GC ==="
    fi

    excluded() {
      ${
        if excludeNamespaces == [ ] then
          "return 1"
        else
          ''
            case "$1" in
              ${excludeCase}) return 0 ;;
              *) return 1 ;;
            esac
          ''
      }
    }

    age_hours() {
      local ts=$1 epoch
      epoch=$(date -u -d "$ts" +%s 2>/dev/null || echo "$NOW")
      echo $(( (NOW - epoch) / 3600 ))
    }

    delete() {
      local kind=$1 ns=$2 name=$3
      if [ "$DRY_RUN" = "true" ]; then
        echo "  would delete $kind $ns/$name"
      else
        ${kubectl} delete "$kind" "$name" -n "$ns" --ignore-not-found >/dev/null 2>&1 \
          && echo "  deleted $kind $ns/$name" \
          || echo "  FAILED to delete $kind $ns/$name"
      fi
    }

    echo ""
    echo "--- Superseded ReplicaSets (older than ${toString replicaSetAgeHours}h) ---"

    DEPLOY_REVS=$(${kubectl} get deploy -A -o json | ${jq} -r '
      .items[] | "\(.metadata.namespace)/\(.metadata.name)=\(.metadata.annotations["deployment.kubernetes.io/revision"] // "")"')

    RS_KEPT=0
    RS_DELETED=0

    while IFS='|' read -r NS NAME REV OWNER CREATED; do
      [ -n "''${NS:-}" ] || continue
      excluded "$NS" && continue

      if [ -n "$OWNER" ]; then
        CUR=$(printf '%s\n' "$DEPLOY_REVS" | ${pkgs.gnugrep}/bin/grep -m1 "^$NS/$OWNER=" | ${pkgs.gnused}/bin/sed 's/.*=//' || true)
        if [ -n "$CUR" ] && [ "$REV" = "$CUR" ]; then
          RS_KEPT=$((RS_KEPT + 1))
          continue
        fi
      fi

      AGE=$(age_hours "$CREATED")
      if [ "$AGE" -lt ${toString replicaSetAgeHours} ]; then
        RS_KEPT=$((RS_KEPT + 1))
        continue
      fi

      delete replicaset "$NS" "$NAME"
      RS_DELETED=$((RS_DELETED + 1))
    done <<< "$(${kubectl} get rs -A -o json | ${jq} -r '
      .items[]
      | select((.spec.replicas // 0) == 0)
      | select((.status.replicas // 0) == 0)
      | "\(.metadata.namespace)|\(.metadata.name)|\(.metadata.annotations["deployment.kubernetes.io/revision"] // "")|\((.metadata.ownerReferences // [] | map(select(.kind == "Deployment")) | .[0].name) // "")|\(.metadata.creationTimestamp)"')"

    echo "  ReplicaSets: $RS_DELETED removed, $RS_KEPT kept"

    echo ""
    echo "--- Terminated pods (older than ${toString podAgeHours}h) ---"

    POD_DELETED=0
    while IFS='|' read -r NS NAME PHASE CREATED; do
      [ -n "''${NS:-}" ] || continue
      excluded "$NS" && continue

      AGE=$(age_hours "$CREATED")
      [ "$AGE" -ge ${toString podAgeHours} ] || continue

      delete pod "$NS" "$NAME"
      POD_DELETED=$((POD_DELETED + 1))
    done <<< "$(${kubectl} get pods -A -o json | ${jq} -r '
      .items[]
      | select(.status.phase == "Failed" or .status.phase == "Succeeded")
      | "\(.metadata.namespace)|\(.metadata.name)|\(.status.phase)|\(.metadata.creationTimestamp)"')"

    echo "  Pods: $POD_DELETED removed"

    echo ""
    echo "--- Finished jobs (older than ${toString jobAgeHours}h) ---"

    JOB_DELETED=0
    while IFS='|' read -r NS NAME CREATED; do
      [ -n "''${NS:-}" ] || continue
      excluded "$NS" && continue

      AGE=$(age_hours "$CREATED")
      [ "$AGE" -ge ${toString jobAgeHours} ] || continue

      delete job "$NS" "$NAME"
      JOB_DELETED=$((JOB_DELETED + 1))
    done <<< "$(${kubectl} get jobs -A -o json | ${jq} -r '
      .items[]
      | select((.status.succeeded // 0) > 0 or (.status.failed // 0) > 0)
      | select(.metadata.ownerReferences == null or ([.metadata.ownerReferences[].kind] | index("CronJob") | not))
      | "\(.metadata.namespace)|\(.metadata.name)|\(.metadata.creationTimestamp)"')"

    echo "  Jobs: $JOB_DELETED removed"

    echo ""
    echo "GC finished"
  '';
in
{
  systemd.services.k8s-gc = {
    description = "Garbage-collect superseded Kubernetes objects";
    after = [ "k3s.service" ];
    wants = [ "k3s.service" ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = gcScript;
    };
  };

  systemd.timers.k8s-gc = {
    description = "Periodic Kubernetes garbage collection";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = onCalendar;
      Persistent = true;
      RandomizedDelaySec = "30m";
    };
  };
}
