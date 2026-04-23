# Shared helpers for Kubernetes modules
# Usage: let k8s = import ./lib.nix { inherit pkgs serverConfig; }; in ...
{ pkgs, serverConfig }:

let
  kubectl = "${pkgs.kubectl}/bin/kubectl";
  helm = "${pkgs.kubernetes-helm}/bin/helm";
  jq = "${pkgs.jq}/bin/jq";
  yq = "${pkgs.yq-go}/bin/yq";
  openssl = "${pkgs.openssl}/bin/openssl";

  domain = serverConfig.domain;
  subdomain = serverConfig.subdomain;
  certSecret = "wildcard-${subdomain}-${domain}-tls";

  k8sCfg = serverConfig.kubernetes or { };
  engine = k8sCfg.engine or "k3s";
  kubeconfigPath =
    if engine == "k3s" then "/etc/rancher/k3s/k3s.yaml" else "/etc/kubernetes/cluster-admin.kubeconfig";
in
rec {
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
    export K8S_CNI="${k8sCfg.cni or "flannel"}"
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
  #   { config, lib, pkgs, serverConfig, ... }:
  #   let k8s = import ../lib.nix { inherit pkgs serverConfig; }; in
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
  # from serverConfig. Caller-provided `extra` attrset adds/overrides tokens
  # (e.g. { IMAGE_TAG = "v1.2.3"; }) and is referenced as __IMAGE_TAG__ in the
  # YAML. Values that are not strings are passed through `toString`.
  renderValues =
    name: yamlFile: extra:
    let
      common = {
        TIMEZONE = serverConfig.timezone or "UTC";
        PUID = toString (serverConfig.puid or 1000);
        PGID = toString (serverConfig.pgid or 1000);
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
      # from serverConfig; this attrset adds/overrides more.
      substitutions ? { },
      # Extra YAML manifests to apply after helm install. Each file is
      # token-substituted (same tokens as valuesFile) and applied with
      # `kubectl apply -f`. Runs after PSS labeling and waitFor, before
      # ingressScript/extraScript.
      manifests ? [ ],
      sets ? [ ],
      ingress ? null,
      middlewares ? [ ],
      waitFor ? null,
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
      configHashInput = builtins.toJSON {
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
      };
      configHash = builtins.hashString "sha256" configHashInput;

      versionFlag = if version != null then "--version ${version}" else "";

      repoScript = if repo != null then ''helm_repo_add "${repo.name}" "${repo.url}"'' else "";

      setsFlags = builtins.concatStringsSep " " (map (s: "--set ${s}") sets);

      # Build the values file flag: convert JSON to YAML at runtime
      valuesFlag =
        if values != { } then
          ''
            VALUES_FILE=$(mktemp /tmp/${name}-values-XXXXXX.yaml)
            $YQ -P '.' ${valuesFileNix} > "$VALUES_FILE"
          ''
        else if renderedValuesFile != null then
          ''VALUES_FILE="${renderedValuesFile}"''
        else
          "";

      valuesFlagArg = if values != { } || renderedValuesFile != null then "-f \"$VALUES_FILE\"" else "";

      cleanupValues = if values != { } then ''rm -f "$VALUES_FILE"'' else "";

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

            setup_preamble_hash "${markerFile}" "${name}" "${configHash}"

            ${repoScript}

            ${valuesFlag}

            echo "Installing ${name} (${chart})..."
            $HELM upgrade --install "${name}" "${chart}" \
              --namespace "${namespace}" \
              --create-namespace \
              ${versionFlag} \
              ${valuesFlagArg} \
              ${setsFlags} \
              --wait \
              --timeout ${timeout} || {
                echo "Helm install failed, retrying with --force..."
                $HELM upgrade --install "${name}" "${chart}" \
                  --namespace "${namespace}" \
                  --create-namespace \
                  ${versionFlag} \
                  ${valuesFlagArg} \
                  ${setsFlags} \
                  --wait \
                  --force \
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

            create_marker "${markerFile}" "${configHash}"
          '';
        };
      };
    };

  # ============================================
  # LINUX SERVER DEPLOYMENT (raw YAML, for non-Helm containers)
  # ============================================

  createLinuxServerDeployment =
    {
      name,
      namespace,
      image,
      port,
      configPVC,
      apiKeySecret ? null,
      extraVolumes ? [ ],
      extraVolumeMounts ? [ ],
      extraEnv ? [ ],
      resources ? {
        requests = {
          cpu = "50m";
          memory = "128Mi";
        };
        limits = {
          memory = "512Mi";
        };
      },
    }:
    let
      puid = toString (serverConfig.puid or 1000);
      pgid = toString (serverConfig.pgid or 1000);

      volumeMountsStr = builtins.concatStringsSep "\n        " (
        [
          "- name: config\n          mountPath: /config"
        ]
        ++ extraVolumeMounts
      );

      volumesStr = builtins.concatStringsSep "\n      " (
        [
          "- name: config\n        persistentVolumeClaim:\n          claimName: ${configPVC}"
        ]
        ++ extraVolumes
        ++ (
          if apiKeySecret != null then
            [
              "- name: api-key-secret\n        secret:\n          secretName: ${apiKeySecret}"
            ]
          else
            [ ]
        )
      );

      envStr = builtins.concatStringsSep "\n        " (
        [
          "- name: PUID\n          value: \"${puid}\""
          "- name: PGID\n          value: \"${pgid}\""
          "- name: TZ\n          value: \"${serverConfig.timezone}\""
        ]
        ++ extraEnv
      );

      rawInitContainer = ''
        initContainers:
        - name: init-api-key
          image: busybox:1.37.0
          command: ['sh', '-c']
          args:
          - |
            API_KEY=$(cat /secrets/api-key)
            if [ ! -f /config/config.xml ]; then
              echo "Pre-seeding config.xml with stable API key..."
              cat > /config/config.xml <<XMLEOF
            <Config>
              <ApiKey>''${API_KEY}</ApiKey>
              <AnalyticsEnabled>False</AnalyticsEnabled>
            </Config>
            XMLEOF
              chown ${puid}:${pgid} /config/config.xml
              echo "config.xml created with stable API key"
            else
              CURRENT_KEY=$(sed -n 's/.*<ApiKey>\(.*\)<\/ApiKey>.*/\1/p' /config/config.xml)
              if [ "$CURRENT_KEY" != "$API_KEY" ]; then
                echo "Updating API key in existing config.xml..."
                sed -i "s|<ApiKey>.*</ApiKey>|<ApiKey>''${API_KEY}</ApiKey>|" /config/config.xml
                echo "API key updated"
              else
                echo "config.xml API key matches secret, no change needed"
              fi
            fi
          volumeMounts:
          - name: config
            mountPath: /config
          - name: api-key-secret
            mountPath: /secrets
            readOnly: true'';

      initContainerYaml =
        if apiKeySecret != null then
          builtins.concatStringsSep "\n" (
            map (line: "      " + line) (
              pkgs.lib.splitString "\n" (pkgs.lib.removePrefix "\n" rawInitContainer)
            )
          )
        else
          "";
    in
    ''
          cat <<'EOF' | ${kubectl} apply -f -
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: ${name}
        namespace: ${namespace}
      spec:
        replicas: 1
        selector:
          matchLabels:
            app: ${name}
        template:
          metadata:
            labels:
              app: ${name}
          spec:
      ${initContainerYaml}
            containers:
            - name: ${name}
              image: ${image}
              ports:
              - containerPort: ${toString port}
              env:
              ${envStr}
              resources:
                requests:
                  cpu: ${resources.requests.cpu}
                  memory: ${resources.requests.memory}
                limits:
                  memory: ${resources.limits.memory}
              volumeMounts:
              ${volumeMountsStr}
            volumes:
            ${volumesStr}
      ---
      apiVersion: v1
      kind: Service
      metadata:
        name: ${name}
        namespace: ${namespace}
      spec:
        selector:
          app: ${name}
        ports:
        - port: ${toString port}
          targetPort: ${toString port}
      EOF
    '';
}
