# Expose the Traefik dashboard via an IngressRoute at traefik.<subdomain>.<domain>.
# Opt-in via serverConfig.traefik.dashboard.enable.
# Middlewares are applied in declaration order; typical use is HSTS + forward-auth.
{
  config,
  lib,
  pkgs,
  serverConfig,
  ...
}:

let
  k8s = import ../lib.nix { inherit pkgs serverConfig; };
  markerFile = "/var/lib/traefik-dashboard-setup-done";

  dashCfg = serverConfig.traefik.dashboard or { };
  dashEnable = serverConfig.services.traefikDashboard or false;
  host = dashCfg.host or (k8s.hostname "traefik");
  middlewares = dashCfg.middlewares or [ ];
  extraAfter = dashCfg.extraAfter or [ ];

  middlewaresYaml = lib.concatMapStringsSep "\n" (
    m: "            - name: ${m.name}\n              namespace: ${m.namespace}"
  ) middlewares;
  middlewaresBlock = lib.optionalString (middlewares != [ ]) ''
          middlewares:
    ${middlewaresYaml}'';
in
lib.mkIf dashEnable {
  systemd.services.traefik-dashboard-setup = {
    description = "Expose Traefik dashboard via IngressRoute";
    after = [ "traefik-setup.service" ] ++ extraAfter;
    wants = [ "traefik-setup.service" ] ++ extraAfter;
    wantedBy = [ "k3s-infrastructure.target" ];
    before = [ "k3s-infrastructure.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "traefik-dashboard-setup" ''
        ${k8s.libShSource}
        setup_preamble "${markerFile}" "Traefik dashboard"

        wait_for_k3s
        wait_for_traefik
        wait_for_certificate

        cat <<EOF | $KUBECTL apply -f -
        apiVersion: traefik.io/v1alpha1
        kind: IngressRoute
        metadata:
          name: traefik-dashboard
          namespace: traefik-system
        spec:
          entryPoints:
            - websecure
          routes:
            - match: Host(\`${host}\`)
              kind: Rule
        ${middlewaresBlock}
              services:
                - kind: TraefikService
                  name: api@internal
          tls:
            store:
              name: default
              namespace: traefik-system
        EOF

        print_success "Traefik dashboard" \
          "URL: https://${host}/dashboard/"

        create_marker "${markerFile}"
      '';
    };
  };
}
