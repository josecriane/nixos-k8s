{
  k8s,
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkOption types;

  str =
    default: description:
    mkOption {
      inherit default description;
      type = types.str;
    };

  lines =
    description:
    mkOption {
      inherit description;
      type = types.lines;
      default = "";
    };

  ingressModule = {
    options = {
      name = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "IngressRoute name. Defaults to the release name.";
      };
      host = mkOption {
        type = types.str;
        description = "Host prefix: `<host>.<subdomain>.<domain>`.";
      };
      service = mkOption {
        type = types.str;
        description = "Backend Service.";
      };
      port = mkOption {
        type = types.port;
        description = "Backend Service port.";
      };
    };
  };

  releaseModule =
    { name, ... }:
    {
      options = {
        name = mkOption {
          type = types.str;
          default = name;
          readOnly = true;
          description = "Helm release name, also the `<name>-setup` unit and the marker file.";
        };
        namespace = mkOption {
          type = types.str;
          description = "Namespace of the release.";
        };
        repo = mkOption {
          type = types.nullOr (
            types.submodule {
              options = {
                name = mkOption {
                  type = types.str;
                  description = "Local repository name.";
                };
                url = mkOption {
                  type = types.str;
                  description = "Repository URL.";
                };
              };
            }
          );
          default = null;
          description = "Helm repository to add. Not needed for `oci://` charts.";
        };
        chart = mkOption {
          type = types.str;
          description = "Chart reference.";
        };
        version = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Chart version. `null` installs the latest.";
        };
        tier = mkOption {
          type = types.enum [
            "infrastructure"
            "storage"
            "core"
            "apps"
            "extras"
          ];
          default = "core";
          description = "Boot tier: the unit runs before `k3s-<tier>.target` and after the previous tier.";
        };
        timeout = str "10m" "Helm `--timeout`.";
        values = mkOption {
          type = types.attrs;
          default = { };
          description = "Values as Nix attrs. They override `valuesFile`.";
        };
        valuesFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = "Values YAML, token-substituted with `substitutions`.";
        };
        substitutions = mkOption {
          type = types.attrs;
          default = { };
          description = "Tokens `__KEY__` replaced in `valuesFile` and `manifests`, on top of TIMEZONE, PUID, PGID, DOMAIN and SUBDOMAIN.";
        };
        manifests = mkOption {
          type = types.listOf types.path;
          default = [ ];
          description = "YAML manifests applied after the install, token-substituted like `valuesFile`.";
        };
        sets = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Helm `--set` arguments.";
        };
        runtimeSets = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Shell-expanded `key=value` strings passed as `--set`. `runtime` defines the variables. Their values join the marker hash.";
        };
        waitFor = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Deployment to wait for after the install.";
        };
        ingresses = mkOption {
          type = types.listOf (types.submodule ingressModule);
          default = [ ];
          description = "Traefik IngressRoutes with TLS, created after the install.";
        };
        middlewares = mkOption {
          type = types.listOf types.attrs;
          default = [ ];
          description = "Traefik middlewares `{ name, namespace }` attached to every ingress.";
        };
        pssLevel = str "baseline" "Pod Security Standard level of the namespace.";
        after = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Units that the setup unit wants and runs after.";
        };
        bootstrapOnly = mkOption {
          type = types.bool;
          default = true;
          description = "Whether only the bootstrap node runs the setup unit.";
        };
        prepare = lines "Script for `ExecStartPre`. It runs on every start, in its own process, before the marker check.";
        runtime = lines "Shell run before the marker check, in the same shell as helm. It can set the variables of `runtimeSets` and append to `EXTRA_SETS`.";
        preInstall = lines "Shell run after the marker check, before `helm upgrade --install`.";
        postInstall = lines "Shell run after the install, `waitFor`, `manifests` and `ingresses`.";
      };
    };

  mkSetupService =
    {
      name,
      namespace,
      repo,
      chart,
      version,
      tier,
      timeout,
      values,
      valuesFile,
      substitutions,
      manifests,
      sets,
      runtimeSets,
      waitFor,
      ingresses,
      middlewares,
      pssLevel,
      after,
      prepare,
      runtime,
      preInstall,
      postInstall,
      ...
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
        if valuesFile != null then k8s.renderValues name valuesFile substitutions else null;

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
          ingress' = ingresses;
          extra = builtins.hashString "sha256" postInstall;
        }
        // pkgs.lib.optionalAttrs (runtimeSets != [ ]) {
          inherit runtimeSets;
        }
        // pkgs.lib.optionalAttrs (runtime != "") {
          runtime = builtins.hashString "sha256" runtime;
        }
        // pkgs.lib.optionalAttrs (preInstall != "") {
          pre = builtins.hashString "sha256" preInstall;
        }
      );
      configHash = builtins.hashString "sha256" configHashInput;

      runtimeSetsScript =
        if runtimeSets == [ ] && runtime == "" then
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

      mwArgs = builtins.concatStringsSep " " (map (mw: "\"${mw.name}:${mw.namespace}\"") middlewares);

      ingressScript = pkgs.lib.optionalString (ingresses != [ ]) (
        ''
          wait_for_certificate
        ''
        + pkgs.lib.concatMapStrings (ingress: ''

          create_ingress_route \
            "${if ingress.name != null then ingress.name else name}" "${namespace}" \
            "$(hostname ${ingress.host})" \
            "${ingress.service}" ${toString ingress.port} ${mwArgs}
        '') ingresses
      );

      waitScript =
        if waitFor != null then ''wait_for_deployment "${namespace}" "${waitFor}" 300'' else "";

      manifestsScript = k8s.applyManifestsScript { inherit name manifests substitutions; };

    in
    {
      description = "Setup ${name} via Helm";
      after = (if prevTargetName != null then [ "${prevTargetName}.target" ] else [ ]) ++ after;
      wants = after;
      requires = if prevTargetName != null then [ "${prevTargetName}.target" ] else [ ];
      wantedBy = [ "${targetName}.target" ];
      before = [ "${targetName}.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ExecStartPre = pkgs.lib.mkIf (prepare != "") "${pkgs.writeShellScript "${name}-pre-helm" prepare}";
        ExecStart = pkgs.writeShellScript serviceName ''
          ${k8s.libShSource}

          wait_for_k3s

          # Always ensure namespace exists with the correct PSS level, even
          # when the helm install is skipped by the marker hash check. Pods
          # requiring "privileged" (hostPath, hostNetwork, hostPID) need the
          # label set before helm --wait, or it will time out.
          ensure_namespace "${namespace}" "${pssLevel}"

          EXTRA_SETS=()

          ${runtime}

          ${runtimeSetsScript}

          setup_preamble_hash "${markerFile}" "${name}" "$CONFIG_HASH"

          ${repoScript}

          ${valuesFlag}

          ${preInstall}

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

          ${postInstall}

          print_success "${name}" \
            "Chart: ${chart}${if version != null then " (${version})" else ""}" \
            "Namespace: ${namespace}"${
              if ingresses != [ ] then
                ''
                  \
                  "URL: https://$(hostname ${(builtins.head ingresses).host})"''
              else
                ""
            }

          create_marker "${markerFile}" "$CONFIG_HASH"
        '';
      };
    };

  enabled = lib.filterAttrs (
    _: release: !release.bootstrapOnly || config.cluster.isBootstrap
  ) config.k8s.helmReleases;
in
{
  options.k8s.helmReleases = mkOption {
    type = types.attrsOf (types.submodule releaseModule);
    default = { };
    description = "Helm releases. Each one generates a `<name>-setup` oneshot unit that installs the chart once per configuration hash.";
  };

  config.systemd.services = lib.mapAttrs' (
    name: release: lib.nameValuePair "${name}-setup" (mkSetupService release)
  ) enabled;
}
