# Kubernetes Dashboard
#
# config.nix:
#   services.kubernetes-dashboard = true;
#
# URL: https://kubernetes-dashboard.<subdomain>.<domain>
# Login: uses a long-lived admin token created automatically during setup.
#   To retrieve it: kubectl get secret dashboard-admin-token -n kubernetes-dashboard -o jsonpath="{.data.token}" | base64 -d
{
  config,
  lib,
  pkgs,
  serverConfig,
  ...
}:

let
  k8s = import ../lib.nix { inherit pkgs serverConfig; };
in
k8s.createHelmRelease {
  name = "kubernetes-dashboard";
  namespace = "kubernetes-dashboard";
  repo = {
    name = "kubernetes-dashboard";
    url = "https://kubernetes.github.io/dashboard/";
  };
  chart = "kubernetes-dashboard/kubernetes-dashboard";
  version = "7.10.0";
  tier = "core";
  ingress = {
    host = "kubernetes-dashboard";
    service = "kubernetes-dashboard-kong-proxy";
    port = 443;
  };
  waitFor = "kubernetes-dashboard-kong-proxy";
  extraScript = ''
    # Create admin ServiceAccount + ClusterRoleBinding + long-lived token
    cat <<'SAEOF' | $KUBECTL apply -f -
    apiVersion: v1
    kind: ServiceAccount
    metadata:
      name: dashboard-admin
      namespace: kubernetes-dashboard
    ---
    apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRoleBinding
    metadata:
      name: dashboard-admin
    roleRef:
      apiGroup: rbac.authorization.k8s.io
      kind: ClusterRole
      name: cluster-admin
    subjects:
    - kind: ServiceAccount
      name: dashboard-admin
      namespace: kubernetes-dashboard
    ---
    apiVersion: v1
    kind: Secret
    metadata:
      name: dashboard-admin-token
      namespace: kubernetes-dashboard
      annotations:
        kubernetes.io/service-account.name: dashboard-admin
    type: kubernetes.io/service-account-token
    SAEOF
    echo "Dashboard admin token created (secret: dashboard-admin-token)"
  '';
}
