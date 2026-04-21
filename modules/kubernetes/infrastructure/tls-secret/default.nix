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
  k8s = import ../../lib.nix { inherit pkgs serverConfig; };
  markerFile = "/var/lib/tls-secret-setup-done";
  certSecret = "wildcard-${serverConfig.subdomain}-${serverConfig.domain}-tls";
  isManual = (serverConfig.certificates.provider or "manual") == "manual";

  # Hash of the encrypted cert+key. When agenix re-encrypts (cert rotation,
  # re-keying), the ciphertext changes so the hash changes and the service
  # re-runs. This propagates cert updates without a manual `make reinstall`.
  # .age files are binary so we use hashFile (which doesn't read content as string).
  certContentHash =
    if isManual then
      builtins.hashString "sha256" (
        (builtins.hashFile "sha256" "${secretsPath}/tls-cert.age")
        + (builtins.hashFile "sha256" "${secretsPath}/tls-key.age")
      )
    else
      "";
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

        setup_preamble_hash "${markerFile}" "TLS certificate" "${certContentHash}"
        wait_for_k3s

        echo "Uploading TLS certificate to cluster..."

        $KUBECTL create secret tls "${certSecret}" \
          --cert="${config.age.secrets.tls-cert.path}" \
          --key="${config.age.secrets.tls-key.path}" \
          --namespace=traefik-system \
          --dry-run=client -o yaml | $KUBECTL apply -f -

        echo "Certificate uploaded to traefik-system/${certSecret}"

        # Default TLSStore so IngressRoutes without explicit tls.secretName use
        # the wildcard cert. Avoids copying the secret into every namespace.
        ${k8s.applyManifestsScript {
          name = "tls-secret";
          manifests = [ ./manifests.yaml ];
          substitutions = {
            CERT_SECRET = certSecret;
          };
        }}

        print_success "TLS certificate" \
          "Secret: ${certSecret}" \
          "Namespace: traefik-system" \
          "Default TLSStore: traefik-system/default"

        create_marker "${markerFile}" "${certContentHash}"
      '';
    };
  };
}
