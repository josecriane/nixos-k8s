# Upload TLS wildcard certificate to the cluster as a K8s secret.
# Requires tls-cert.age and tls-key.age in secrets/.
# Only active when certificates.provider = "manual".
{
  config,
  lib,
  pkgs,
  serverConfig,
  secretsPath,
  ...
}:

let
  k8s = import ../lib.nix { inherit pkgs serverConfig; };
  markerFile = "/var/lib/tls-secret-setup-done";
  certSecret = "wildcard-${serverConfig.subdomain}-${serverConfig.domain}-tls";
  isManual = (serverConfig.certificates.provider or "manual") == "manual";
in
lib.mkIf isManual {
  age.secrets.tls-cert = {
    file = "${secretsPath}/tls-cert.age";
  };
  age.secrets.tls-key = {
    file = "${secretsPath}/tls-key.age";
  };

  systemd.services.tls-secret-setup = {
    description = "Upload TLS certificate to Kubernetes";
    after = [ "traefik-setup.service" ];
    wants = [ "traefik-setup.service" ];
    wantedBy = [ "k3s-infrastructure.target" ];
    before = [ "k3s-infrastructure.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      ExecStart = pkgs.writeShellScript "tls-secret-setup" ''
        ${k8s.libShSource}

        setup_preamble "${markerFile}" "TLS certificate"
        wait_for_k3s

        echo "Uploading TLS certificate to cluster..."

        $KUBECTL create secret tls "${certSecret}" \
          --cert="${config.age.secrets.tls-cert.path}" \
          --key="${config.age.secrets.tls-key.path}" \
          --namespace=traefik-system \
          --dry-run=client -o yaml | $KUBECTL apply -f -

        echo "Certificate uploaded to traefik-system/${certSecret}"

        print_success "TLS certificate" \
          "Secret: ${certSecret}" \
          "Namespace: traefik-system"

        create_marker "${markerFile}"
      '';
    };
  };
}
