{
  config,
  pkgs,
  ns,
}:

{
  name,
  tier ? "core",
  extraCleanup ? "",
}:

let
  engineService =
    if config.cluster.kubernetes.engine == "k3s" then "k3s.service" else "kube-apiserver.service";
  targetName = "k3s-${tier}";
  prevTier =
    {
      infrastructure = null;
      storage = "infrastructure";
      core = "storage";
      apps = "core";
      extras = "apps";
    }
    .${tier} or null;
  prevTarget = if prevTier != null then "k3s-${prevTier}.target" else null;

  script = pkgs.writeShellScript "${name}-uninstall" ''
    set -e
    export KUBECONFIG=${
      if config.cluster.kubernetes.engine == "k3s" then
        "/etc/rancher/k3s/k3s.yaml"
      else
        "/etc/kubernetes/cluster-admin.kubeconfig"
    }
    KUBECTL=${pkgs.kubectl}/bin/kubectl
    HELM=${pkgs.kubernetes-helm}/bin/helm

    if $HELM list -n ${ns} --short 2>/dev/null | grep -qx ${name}; then
      echo "${name} helm release present, uninstalling (disabled in monitoring config)..."
      $HELM uninstall ${name} -n ${ns} --wait --timeout=120s || true
    else
      echo "${name} not installed, nothing to do"
    fi

    rm -f /var/lib/${name}-setup-done

    ${extraCleanup}

    echo "${name} reconciliation complete"
  '';
in
{
  systemd.services."${name}-setup" = {
    description = "Reconcile ${name} (disabled in monitoring config)";
    after = [ engineService ] ++ pkgs.lib.optional (prevTarget != null) prevTarget;
    wants = [ engineService ];
    requires = pkgs.lib.optional (prevTarget != null) prevTarget;
    wantedBy = [ "${targetName}.target" ];
    before = [ "${targetName}.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = script;
    };
  };
}
