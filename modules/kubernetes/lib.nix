# Shared helpers for Kubernetes modules
# Provided to every module as the `k8s` argument (see mkCluster in flake.nix).
{ pkgs, cluster }:

let

  kubectl = "${pkgs.kubectl}/bin/kubectl";
  helm = "${pkgs.kubernetes-helm}/bin/helm";
  jq = "${pkgs.jq}/bin/jq";
  yq = "${pkgs.yq-go}/bin/yq";
  openssl = "${pkgs.openssl}/bin/openssl";

  domain = cluster.domain;
  subdomain = cluster.subdomain;
  certSecret = "wildcard-${subdomain}-${domain}-tls";

  k8sCfg = cluster.kubernetes;
  engine = k8sCfg.engine;
  kubeconfigPath =
    if engine == "k3s" then "/etc/rancher/k3s/k3s.yaml" else "/etc/kubernetes/cluster-admin.kubeconfig";
in
rec {
  primaryNas =
    let
      enabled = pkgs.lib.filterAttrs (_: cfg: cfg.enabled) cluster.nas;
      withNames = pkgs.lib.attrValues enabled;
    in
    pkgs.lib.findFirst (cfg: cfg.role == "media" || cfg.role == "all") null withNames;

  nasMountPointOf = cfg: "/mnt/${cfg.hostname}";

  primaryNasMountPoint = if primaryNas != null then nasMountPointOf primaryNas else "/mnt/nas";

  # ============================================
  # LIB.SH SOURCE (exports env vars + sources lib.sh)
  # ============================================

  libShSource = ''
    export KUBECTL="${pkgs.kubectl}/bin/kubectl"
    export JQ="${pkgs.jq}/bin/jq"
    export HELM="${pkgs.kubernetes-helm}/bin/helm"
    export YQ="${pkgs.yq-go}/bin/yq"
    export OPENSSL="${pkgs.openssl}/bin/openssl"
    export IP="${pkgs.iproute2}/bin/ip"
    export CURL="${pkgs.curl}/bin/curl"
    export DOMAIN="${domain}"
    export SUBDOMAIN="${subdomain}"
    export CERT_SECRET="${certSecret}"
    export KUBECONFIG="${kubeconfigPath}"
    export K8S_ENGINE="${engine}"
    export K8S_CNI="${k8sCfg.cni}"
    source ${./lib.sh}
  '';

  # ============================================
  # NIX-PURE FUNCTIONS
  # ============================================

  hostname = name: "${name}.${subdomain}.${domain}";

  forwardAuthMiddleware = [
    {
      name = "forward-auth";
      namespace = "traefik-system";
    }
  ];

  # Render a values YAML file with token substitution.
  # Auto-populates __TIMEZONE__, __PUID__, __PGID__, __DOMAIN__, __SUBDOMAIN__
  # from cluster. Caller-provided `extra` attrset adds/overrides tokens
  # (e.g. { IMAGE_TAG = "v1.2.3"; }) and is referenced as __IMAGE_TAG__ in the
  # YAML. Values that are not strings are passed through `toString`.
  renderValues =
    name: yamlFile: extra:
    let
      common = {
        TIMEZONE = cluster.timezone;
        PUID = toString (cluster.puid);
        PGID = toString (cluster.pgid);
        DOMAIN = domain;
        SUBDOMAIN = subdomain;
      };
      all = common // extra;
      keys = builtins.attrNames all;
      substituted = builtins.replaceStrings (map (k: "__${k}__") keys) (map (k: toString all.${k}) keys) (
        builtins.readFile yamlFile
      );
      raw = pkgs.writeText "${name}-values.raw.yaml" substituted;
    in
    # Token substitution can leave weird indentation (empty lines, mismatched
    # columns if the token was inserted mid-block). Reformat with yq so the
    # output is always canonical multi-doc YAML, regardless of how the caller
    # shaped the substitution string.
    pkgs.runCommand "${name}-values.yaml" { nativeBuildInputs = [ pkgs.yq-go ]; } ''
      yq -P ${raw} > $out
    '';

  # Alias: renderValues applies to any templated YAML, not only Helm values.
  renderManifest = renderValues;

  # Emit a bash snippet that applies one or more YAML manifests via
  # `kubectl apply -f`. Each manifest is token-substituted (same tokens as
  # k8s.helmReleases: auto TIMEZONE/PUID/PGID/DOMAIN/SUBDOMAIN plus caller
  # substitutions). Use this in raw systemd services that don't go through
  # k8s.helmReleases but still want static YAML kept in its own file.
  applyManifestsScript =
    {
      name,
      manifests,
      substitutions ? { },
    }:
    let
      rendered = pkgs.lib.imap0 (
        i: m: renderManifest "${name}-manifest-${toString i}" m substitutions
      ) manifests;
      args = builtins.concatStringsSep " " (map (m: "-f ${m}") rendered);
    in
    pkgs.lib.optionalString (manifests != [ ]) ''
      echo "Applying manifests for ${name}..."
      $KUBECTL apply ${args}
    '';

}
