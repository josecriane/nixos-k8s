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
  targetName = "k3s-${tier}";
  prevTarget =
    {
      infrastructure = null;
      storage = "infrastructure";
      core = "storage";
      apps = "core";
      extras = "apps";
    }
    .${tier} or null;

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
    after = [ "k3s.service" ] ++ pkgs.lib.optional (prevTarget != null) "${prevTarget}.target";
    requires = [ "k3s.service" ];
    wantedBy = [ "${targetName}.target" ];
    before = [ "${targetName}.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = script;
    };
  };
}
