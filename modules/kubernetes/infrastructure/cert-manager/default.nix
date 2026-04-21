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

  certBackupDir = "/var/lib/cert-backup";
  nasBackupDir = "/mnt/nas1/backups";
  certName = "wildcard-${serverConfig.subdomain}-${serverConfig.domain}";
  secretName = "${certName}-tls";

  restoreFromBackup = serverConfig.certificates.restoreFromBackup or true;

  nasConfig = serverConfig.nas.nas1 or null;
  nasEnabled = nasConfig != null && (nasConfig.enabled or false);

  # NAS backups are only filesystem operations (age decrypt/copy). Do this
  # before k3s/helm so it doesn't gate cluster progress, and so the local
  # backup is available when the restore/ACME logic runs post-helm.
  preHelm = pkgs.writeShellScript "cert-manager-pre-helm" ''
    ${k8s.libShSource}
    set -euo pipefail

    CERT_BACKUP_DIR="${certBackupDir}"
    SECRET_NAME="${secretName}"
    RESTORE_FROM_BACKUP="${if restoreFromBackup then "true" else "false"}"
    NAS_ENABLED="${if nasEnabled then "true" else "false"}"
    NAS_BACKUP_DIR="${nasBackupDir}"

    mkdir -p "$CERT_BACKUP_DIR"

    AGE="${pkgs.age}/bin/age"
    AGE_KEY="/etc/ssh/ssh_host_ed25519_key"

    if [ "$RESTORE_FROM_BACKUP" = "true" ] && [ "$NAS_ENABLED" = "true" ]; then
      echo "Looking for certificate backup on NAS..."
      NAS_BACKUP_ENCRYPTED="$NAS_BACKUP_DIR/$SECRET_NAME.yaml.age"
      NAS_BACKUP_PLAIN="$NAS_BACKUP_DIR/$SECRET_NAME.yaml"
      set +e
      if [ -f "$NAS_BACKUP_ENCRYPTED" ]; then
        echo "Encrypted backup found on NAS, decrypting to local..."
        if $AGE -d -i "$AGE_KEY" -o "$CERT_BACKUP_DIR/$SECRET_NAME.yaml" "$NAS_BACKUP_ENCRYPTED"; then
          chmod 600 "$CERT_BACKUP_DIR/$SECRET_NAME.yaml"
          echo "Backup decrypted from NAS"
        else
          echo "WARN: NAS backup decrypt failed, continuing without"
          rm -f "$CERT_BACKUP_DIR/$SECRET_NAME.yaml"
        fi
      elif [ -f "$NAS_BACKUP_PLAIN" ]; then
        echo "Unencrypted backup found on NAS, copying to local..."
        if cp "$NAS_BACKUP_PLAIN" "$CERT_BACKUP_DIR/$SECRET_NAME.yaml"; then
          chmod 600 "$CERT_BACKUP_DIR/$SECRET_NAME.yaml"
          echo "Backup copied from NAS (consider re-encrypting)"
        else
          echo "WARN: NAS backup copy failed, continuing without"
          rm -f "$CERT_BACKUP_DIR/$SECRET_NAME.yaml"
        fi
      else
        echo "No backup on NAS"
      fi
      set -e
    fi
  '';

  release = k8s.createHelmRelease {
    name = "cert-manager";
    namespace = "cert-manager";
    tier = "infrastructure";
    repo = {
      name = "jetstack";
      url = "https://charts.jetstack.io";
    };
    chart = "jetstack/cert-manager";
    timeout = "5m";
    valuesFile = ./values.yaml;
    extraScript = ''
      wait_for_traefik

      echo "Waiting for cert-manager pods to be ready..."
      wait_for_pod cert-manager "app.kubernetes.io/instance=cert-manager"

      echo "Waiting for cert-manager CRDs to be registered..."
      $KUBECTL wait --for=condition=Established \
        --timeout=60s \
        crd/certificates.cert-manager.io \
        crd/certificaterequests.cert-manager.io \
        crd/issuers.cert-manager.io \
        crd/clusterissuers.cert-manager.io

      echo "Reading Cloudflare API token from agenix..."
      if [ ! -f "${config.age.secrets.cloudflare-api-token.path}" ]; then
        echo "ERROR: Cloudflare secret not found at ${config.age.secrets.cloudflare-api-token.path}"
        exit 1
      fi

      echo "Creating Cloudflare secret in cert-manager namespace..."
      $KUBECTL create secret generic cloudflare-api-token-secret \
        --namespace cert-manager \
        --from-file=api-token="${config.age.secrets.cloudflare-api-token.path}" \
        --dry-run=client -o yaml | $KUBECTL apply -f -

      echo "Creating ClusterIssuer for Let's Encrypt with Cloudflare DNS-01..."
      cat <<EOF | $KUBECTL apply -f -
      apiVersion: cert-manager.io/v1
      kind: ClusterIssuer
      metadata:
        name: letsencrypt-prod
      spec:
        acme:
          server: https://acme-v02.api.letsencrypt.org/directory
          email: ${serverConfig.acmeEmail}
          privateKeySecretRef:
            name: letsencrypt-prod-key
          solvers:
          - dns01:
              cloudflare:
                apiTokenSecretRef:
                  name: cloudflare-api-token-secret
                  key: api-token
      EOF

      echo "Waiting for ClusterIssuer to be ready..."
      sleep 5

      if ! $KUBECTL get clusterissuer letsencrypt-prod &>/dev/null; then
        echo "ERROR: Could not create ClusterIssuer"
        exit 1
      fi

      # ============================================
      # CERTIFICATE BACKUP/RESTORE
      # ============================================
      CERT_BACKUP_DIR="${certBackupDir}"
      SECRET_NAME="${secretName}"
      RESTORE_FROM_BACKUP="${if restoreFromBackup then "true" else "false"}"
      NAS_ENABLED="${if nasEnabled then "true" else "false"}"
      NAS_BACKUP_DIR="${nasBackupDir}"
      BACKUP_FILE="$CERT_BACKUP_DIR/$SECRET_NAME.yaml"
      CERT_RESTORED=false

      AGE="${pkgs.age}/bin/age"
      AGE_KEY="/etc/ssh/ssh_host_ed25519_key"

      save_backup() {
        echo "Saving certificate backup..."
        $KUBECTL get secret -n traefik-system $SECRET_NAME -o yaml > "$BACKUP_FILE"
        chmod 600 "$BACKUP_FILE"
        echo "Local backup saved at $BACKUP_FILE"

        if [ "$NAS_ENABLED" = "true" ]; then
          set +e
          mkdir -p "$NAS_BACKUP_DIR" 2>/dev/null
          if $AGE -R "$AGE_KEY".pub -o "$NAS_BACKUP_DIR/$SECRET_NAME.yaml.age" "$BACKUP_FILE" 2>&1; then
            chmod 600 "$NAS_BACKUP_DIR/$SECRET_NAME.yaml.age"
            echo "Encrypted backup saved to NAS: $NAS_BACKUP_DIR/$SECRET_NAME.yaml.age"
          else
            echo "WARN: NAS backup save failed, continuing (local backup still saved)"
          fi
          set -e
        fi
      }

      restore_backup() {
        if [ ! -f "$BACKUP_FILE" ]; then
          return 1
        fi
        echo "Restoring certificate from backup: $BACKUP_FILE"
        if $KUBECTL apply -f "$BACKUP_FILE"; then
          echo "Certificate restored successfully"
          return 0
        fi
        return 1
      }

      if [ -f "$BACKUP_FILE" ] && [ "$RESTORE_FROM_BACKUP" = "true" ]; then
        if restore_backup; then
          CERT_RESTORED=true
        fi
      fi

      echo "Creating Certificate resource..."
      cat <<EOF | $KUBECTL apply -f -
      apiVersion: cert-manager.io/v1
      kind: Certificate
      metadata:
        name: ${certName}
        namespace: traefik-system
      spec:
        secretName: $SECRET_NAME
        issuerRef:
          name: letsencrypt-prod
          kind: ClusterIssuer
        dnsNames:
        - "*.${serverConfig.subdomain}.${serverConfig.domain}"
        - "${serverConfig.subdomain}.${serverConfig.domain}"
      EOF

      if [ "$CERT_RESTORED" = "false" ]; then
        echo "No backup, waiting for Let's Encrypt to issue certificate..."

        for i in $(seq 1 60); do
          CERT_STATUS=$($KUBECTL get certificate -n traefik-system ${certName} -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")

          if [ "$CERT_STATUS" = "True" ]; then
            echo "Certificate issued successfully"
            save_backup
            CERT_RESTORED=true
            break
          fi

          ORDER_STATE=$($KUBECTL get orders -n traefik-system -o jsonpath='{.items[0].status.state}' 2>/dev/null || true)
          if [ "$ORDER_STATE" = "errored" ]; then
            ORDER_REASON=$($KUBECTL get orders -n traefik-system -o jsonpath='{.items[0].status.reason}' 2>/dev/null || true)
            echo "ACME order error: $ORDER_REASON"

            if echo "$ORDER_REASON" | grep -q "rateLimited"; then
              echo "Rate limit detected, trying to restore from backup..."

              if [ ! -f "$BACKUP_FILE" ] && [ "$NAS_ENABLED" = "true" ]; then
                NAS_BACKUP_ENCRYPTED="$NAS_BACKUP_DIR/$SECRET_NAME.yaml.age"
                NAS_BACKUP_PLAIN="$NAS_BACKUP_DIR/$SECRET_NAME.yaml"
                if [ -f "$NAS_BACKUP_ENCRYPTED" ]; then
                  $AGE -d -i "$AGE_KEY" -o "$BACKUP_FILE" "$NAS_BACKUP_ENCRYPTED"
                  chmod 600 "$BACKUP_FILE"
                elif [ -f "$NAS_BACKUP_PLAIN" ]; then
                  cp "$NAS_BACKUP_PLAIN" "$BACKUP_FILE"
                  chmod 600 "$BACKUP_FILE"
                fi
              fi

              if restore_backup; then
                CERT_RESTORED=true
              else
                echo "WARN: No backup available, services will use self-signed cert until rate limit expires"
              fi
              break
            fi
          fi

          echo "Waiting for certificate issuance... ($i/60) Status: $CERT_STATUS"
          sleep 5
        done
      fi

      FINAL_STATUS="Unknown"
      if [ "$CERT_RESTORED" = "true" ]; then
        if $KUBECTL get secret -n traefik-system $SECRET_NAME &>/dev/null; then
          FINAL_STATUS="True"
        fi
      else
        FINAL_STATUS=$($KUBECTL get certificate -n traefik-system ${certName} -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
      fi

      if [ "$FINAL_STATUS" = "True" ] && [ ! -f "$BACKUP_FILE" ]; then
        save_backup
      fi

      # Default TLSStore so IngressRoutes without explicit tls.secretName use
      # the wildcard cert via tls.store. Avoids copying the secret into every
      # namespace. Mirrors the pattern in tls-secret.nix (manual provider).
      echo "Creating default TLSStore..."
      cat <<TLSSTOREEOF | $KUBECTL apply -f -
      apiVersion: traefik.io/v1alpha1
      kind: TLSStore
      metadata:
        name: default
        namespace: traefik-system
      spec:
        defaultCertificate:
          secretName: $SECRET_NAME
      TLSSTOREEOF

      echo "ClusterIssuer: letsencrypt-prod"
      echo "Wildcard certificate: *.${serverConfig.subdomain}.${serverConfig.domain}"
      echo "Status: $FINAL_STATUS ($([ "$CERT_RESTORED" = "true" ] && echo "from backup" || echo "ACME"))"
    '';
  };
in
lib.recursiveUpdate release {
  age.secrets.cloudflare-api-token = {
    file = "${secretsPath}/cloudflare-api-token.age";
  };

  systemd.services.cert-manager-setup = {
    after = (release.systemd.services.cert-manager-setup.after or [ ]) ++ [
      "k3s.service"
      "traefik-setup.service"
    ];
    wants = [
      "k3s.service"
      "traefik-setup.service"
    ];
    serviceConfig.ExecStartPre = "${preHelm}";
  };
}
