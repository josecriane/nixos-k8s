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

  # ============================================
  # HELM RELEASE (generates a complete systemd service for a Helm chart)
  # ============================================

  # Creates a systemd service that deploys a Helm chart.
  #
  # Usage in a module:
  #   { k8s, config, lib, pkgs, ... }:

  #   k8s.createHelmRelease {
  #     name = "argocd";
  #     namespace = "argo-cd";
  #     repo = { name = "argo-cd"; url = "https://argoproj.github.io/argo-helm"; };
  #     chart = "argo-cd/argo-cd";
  #     version = "7.7.10";
  #     tier = "core";
  #     values = { server.service.type = "ClusterIP"; };
  #     ingress = { host = "argocd"; service = "argocd-server"; port = 443; };
  #   }
  #
  # Returns an attrset with: { systemd.services.<name>-setup = ...; }
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
  # createHelmRelease: auto TIMEZONE/PUID/PGID/DOMAIN/SUBDOMAIN plus caller
  # substitutions). Use this in raw systemd services that don't go through
  # createHelmRelease but still want static YAML kept in its own file.
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

  createHelmRelease =
    {
      name,
      namespace,
      repo ? null,
      chart,
      version ? null,
      tier ? "core",
      timeout ? "10m",
      values ? { },
      valuesFile ? null,
      # Token substitutions applied to valuesFile and manifests. Common tokens
      # (TIMEZONE, PUID, PGID, DOMAIN, SUBDOMAIN) are always auto-populated
      # from cluster; this attrset adds/overrides more.
      substitutions ? { },
      # Extra YAML manifests to apply after helm install. Each file is
      # token-substituted (same tokens as valuesFile) and applied with
      # `kubectl apply -f`. Runs after PSS labeling and waitFor, before
      # ingressScript/extraScript.
      manifests ? [ ],
      sets ? [ ],
      # Values only knowable at deploy time, as shell-expandable "key=value" strings
      # appended as --set. runtimeScript runs before the marker check, so it can define
      # what they expand to and append conditional ones to EXTRA_SETS, and their expanded
      # values join the marker hash.
      runtimeSets ? [ ],
      runtimeScript ? "",
      ingress ? null,
      middlewares ? [ ],
      waitFor ? null,
      preScript ? "",
      extraScript ? "",
      # Pod Security Standard level applied to the namespace via labels.
      # Use "privileged" for workloads that need hostPath, capabilities, hostNetwork, etc.
      pssLevel ? "baseline",
    }:
    let
      markerFile = "/var/lib/${name}-setup-done";
      serviceName = "${name}-setup";
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
      prevTargetName = if prevTier != null then "k3s-${prevTier}" else null;

      valuesJson = builtins.toJSON values;
      valuesFileNix = pkgs.writeText "${name}-values.json" valuesJson;

      # Render valuesFile (if provided) with common tokens + caller substitutions.
      renderedValuesFile =
        if valuesFile != null then renderValues name valuesFile substitutions else null;

      # Config hash: changes when chart, version, values, sets, or ingress change
      configHashInput = builtins.toJSON (
        {
          inherit
            chart
            version
            values
            sets
            substitutions
            pssLevel
            ;
          valuesFile' = if valuesFile != null then builtins.readFile valuesFile else null;
          manifests' = map (m: builtins.readFile m) manifests;
          ingress' = if ingress != null then ingress else null;
          extra = builtins.hashString "sha256" extraScript;
        }
        // pkgs.lib.optionalAttrs (runtimeSets != [ ]) {
          inherit runtimeSets;
        }
        // pkgs.lib.optionalAttrs (runtimeScript != "") {
          runtime = builtins.hashString "sha256" runtimeScript;
        }
        // pkgs.lib.optionalAttrs (preScript != "") {
          pre = builtins.hashString "sha256" preScript;
        }
      );
      configHash = builtins.hashString "sha256" configHashInput;

      runtimeSetsScript =
        if runtimeSets == [ ] && runtimeScript == "" then
          ''
            RUNTIME_SET_FLAGS=()
            CONFIG_HASH="${configHash}"
          ''
        else
          ''
            RUNTIME_SETS=(${pkgs.lib.concatMapStringsSep " " (s: ''"${s}"'') runtimeSets})
            RUNTIME_SETS+=("''${EXTRA_SETS[@]}")
            RUNTIME_SET_FLAGS=()
            for kv in "''${RUNTIME_SETS[@]}"; do
              RUNTIME_SET_FLAGS+=(--set "$kv")
            done
            RUNTIME_DIGEST=$(printf '%s\0' "''${RUNTIME_SETS[@]}" | $OPENSSL dgst -sha256 -r | cut -d' ' -f1)
            CONFIG_HASH=$(printf '%s%s' "${configHash}" "$RUNTIME_DIGEST" | $OPENSSL dgst -sha256 -r | cut -d' ' -f1)
          '';

      versionFlag = if version != null then "--version ${version}" else "";

      repoScript = if repo != null then ''helm_repo_add "${repo.name}" "${repo.url}"'' else "";

      setsFlags = builtins.concatStringsSep " " (map (s: "--set ${s}") sets);

      # Values precedence (low → high):
      #   1. valuesFile (static YAML, optionally token-substituted)
      #   2. values (Nix attrs, converted to JSON → YAML at runtime)
      # When both are passed, helm merges them via two `-f` flags (last wins).
      valuesFlag =
        (pkgs.lib.optionalString (renderedValuesFile != null) ''
          VALUES_BASE_FILE="${renderedValuesFile}"
        '')
        + (pkgs.lib.optionalString (values != { }) ''
          VALUES_OVERRIDE_FILE=$(mktemp /tmp/${name}-values-XXXXXX.yaml)
          $YQ -P '.' ${valuesFileNix} > "$VALUES_OVERRIDE_FILE"
        '');

      valuesFlagArg = pkgs.lib.concatStringsSep " " (
        pkgs.lib.optional (renderedValuesFile != null) ''-f "$VALUES_BASE_FILE"''
        ++ pkgs.lib.optional (values != { }) ''-f "$VALUES_OVERRIDE_FILE"''
      );

      cleanupValues = pkgs.lib.optionalString (values != { }) ''rm -f "$VALUES_OVERRIDE_FILE"'';

      ingressScript =
        if ingress != null then
          let
            mwArgs = builtins.concatStringsSep " " (map (mw: "\"${mw.name}:${mw.namespace}\"") middlewares);
          in
          ''
            wait_for_certificate

            create_ingress_route \
              "${name}" "${namespace}" \
              "$(hostname ${ingress.host})" \
              "${ingress.service}" ${toString ingress.port} ${mwArgs}
          ''
        else
          "";

      waitScript =
        if waitFor != null then ''wait_for_deployment "${namespace}" "${waitFor}" 300'' else "";

      manifestsScript = applyManifestsScript { inherit name manifests substitutions; };

    in
    {
      systemd.services.${serviceName} = {
        description = "Setup ${name} via Helm";
        after = if prevTargetName != null then [ "${prevTargetName}.target" ] else [ ];
        requires = if prevTargetName != null then [ "${prevTargetName}.target" ] else [ ];
        wantedBy = [ "${targetName}.target" ];
        before = [ "${targetName}.target" ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ProtectHome = true;
          PrivateTmp = true;
          NoNewPrivileges = true;
          ExecStart = pkgs.writeShellScript serviceName ''
            ${libShSource}

            wait_for_k3s

            # Always ensure namespace exists with the correct PSS level, even
            # when the helm install is skipped by the marker hash check. Pods
            # requiring "privileged" (hostPath, hostNetwork, hostPID) need the
            # label set before helm --wait, or it will time out.
            ensure_namespace "${namespace}" "${pssLevel}"

            EXTRA_SETS=()

            ${runtimeScript}

            ${runtimeSetsScript}

            setup_preamble_hash "${markerFile}" "${name}" "$CONFIG_HASH"

            ${repoScript}

            ${valuesFlag}

            ${preScript}

            echo "Installing ${name} (${chart})..."
            $HELM upgrade --install "${name}" "${chart}" \
              --namespace "${namespace}" \
              --create-namespace \
              ${versionFlag} \
              ${valuesFlagArg} \
              ${setsFlags} \
              "''${RUNTIME_SET_FLAGS[@]}" \
              --wait \
              --timeout ${timeout} || {
                echo "Helm install failed, retrying with server-side apply and --force-conflicts..."
                $HELM upgrade --install "${name}" "${chart}" \
                  --namespace "${namespace}" \
                  --create-namespace \
                  ${versionFlag} \
                  ${valuesFlagArg} \
                  ${setsFlags} \
                  "''${RUNTIME_SET_FLAGS[@]}" \
                  --wait \
                  --server-side=true \
                  --force-conflicts \
                  --timeout ${timeout}
              }

            ${cleanupValues}

            ${waitScript}

            ${manifestsScript}

            ${ingressScript}

            ${extraScript}

            print_success "${name}" \
              "Chart: ${chart}${if version != null then " (${version})" else ""}" \
              "Namespace: ${namespace}"${
                if ingress != null then
                  ''
                    \
                    "URL: https://$(hostname ${ingress.host})"''
                else
                  ""
              }

            create_marker "${markerFile}" "$CONFIG_HASH"
          '';
        };
      };
    };

}
