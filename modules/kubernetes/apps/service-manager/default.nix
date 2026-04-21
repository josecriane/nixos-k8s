# Service Manager - browser-based control plane for K8s workloads.
# Lists every deployment/statefulset/daemonset across namespaces and exposes
# start/stop, restart, node preference, and cordon operations. The Go binary
# auto-discovers workloads; downstream only provides display/grouping hints
# via k8s.apps.serviceManager.
{
  config,
  lib,
  pkgs,
  serverConfig,
  nodeConfig,
  ...
}:

let
  k8s = import ../../lib.nix { inherit pkgs serverConfig; };
  ns = "service-manager";
  markerFile = "/var/lib/service-manager-setup-done";
  isBootstrap = nodeConfig.bootstrap or false;

  cfg = config.k8s.apps.serviceManager;

  configJson = builtins.toJSON {
    inherit (cfg) groupNames noStop hide;
  };

  bin = pkgs.buildGoModule {
    pname = "service-manager";
    version = "1.0.0";
    src = ./.;
    vendorHash = null;
  };

  image = pkgs.dockerTools.buildImage {
    name = "service-manager";
    tag = "latest";
    copyToRoot = [ bin ];
    config = {
      Cmd = [ "${bin}/bin/service-manager" ];
      ExposedPorts = {
        "8080/tcp" = { };
      };
    };
  };
in
{
  options.k8s.apps.serviceManager = {
    hostname = lib.mkOption {
      type = lib.types.str;
      default = "services";
      description = "Subdomain prefix passed to k8s.hostname for the IngressRoute.";
    };
    groupNames = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Map of namespace -> display group name shown in the UI.";
    };
    noStop = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "List of ns/name (or ns/*) entries that cannot be scaled to 0.";
    };
    hide = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Namespaces to hide entirely from the UI.";
    };
  };

  config.systemd.services = {
    service-manager-image-import = {
      description = "Import Service Manager container image into containerd";
      after = [ "k3s.service" ];
      requires = [ "k3s.service" ];
      wantedBy = [ "multi-user.target" ];
      restartTriggers = [ image ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "service-manager-image-import" ''
          set -e
          for i in $(seq 1 60); do
            [ -S /run/k3s/containerd/containerd.sock ] && break
            sleep 2
          done
          echo "Importing Service Manager image..."
          ${pkgs.k3s}/bin/k3s ctr images import ${image}
        '';
      };
    };
  }
  // lib.optionalAttrs isBootstrap {
    service-manager-setup = {
      description = "Setup Service Manager";
      after = [
        "k3s-storage.target"
        "service-manager-image-import.service"
      ];
      requires = [
        "k3s-storage.target"
        "service-manager-image-import.service"
      ];
      wantedBy = [ "k3s-core.target" ];
      before = [ "k3s-core.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "service-manager-setup" ''
                  ${k8s.libShSource}
                  IMAGE_HASH="${image}"
                  setup_preamble_hash "${markerFile}" "Service Manager" "$IMAGE_HASH"

                  wait_for_k3s
                  wait_for_traefik
                  wait_for_certificate
                  ensure_namespace "${ns}"

                  # ConfigMap carries dynamic services.json, keep inline.
                  $KUBECTL create configmap service-manager-config -n ${ns} \
                    --from-literal=services.json='${configJson}' \
                    --dry-run=client -o yaml | $KUBECTL apply -f -

                  ${k8s.applyManifestsScript {
                    name = "service-manager";
                    manifests = [ ./manifests.yaml ];
                    substitutions = { NAMESPACE = ns; };
                  }}

                  wait_for_deployment "${ns}" "service-manager" 120

                  echo "Rolling out service-manager to pick up new image..."
                  $KUBECTL rollout restart deployment/service-manager -n ${ns}
                  $KUBECTL rollout status deployment/service-manager -n ${ns} --timeout=120s

                  create_ingress_route "service-manager" "${ns}" "$(hostname ${cfg.hostname})" "service-manager" "8080"

                  print_success "Service Manager" \
                    "URL: https://$(hostname ${cfg.hostname})"

                  create_marker "${markerFile}" "$IMAGE_HASH"
        '';
      };
    };
  };
}
