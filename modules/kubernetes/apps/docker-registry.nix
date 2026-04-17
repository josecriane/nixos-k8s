# Docker Registry + UI
#
# Authentication model:
#   - Anonymous GET/HEAD (pulls)
#   - BasicAuth required for push/delete (POST/PUT/PATCH/DELETE)
#   - UI requires auth
# htpasswd credentials live in agenix secret tls-htpasswd.age.
#
# config.nix:
#   services.docker-registry = true;
#
# secrets/registry-htpasswd.age:
#   Raw htpasswd file content. Generate with:
#     htpasswd -Bc htpasswd ci-user
#     agenix -e secrets/registry-htpasswd.age < htpasswd
#
# URLs:
#   Registry: https://registry.<subdomain>.<domain>
#   UI:       https://registry-ui.<subdomain>.<domain>
#
# Push example:
#   docker login registry.<subdomain>.<domain>
#   docker push registry.<subdomain>.<domain>/myimage:latest
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

  registry = k8s.createHelmRelease {
    name = "docker-registry";
    namespace = "container-registry";
    repo = {
      name = "docker-registry";
      url = "https://twuni.github.io/docker-registry.helm";
    };
    chart = "docker-registry/docker-registry";
    version = "2.2.3";
    tier = "core";
    values = {
      persistence = {
        enabled = true;
        size = "50Gi";
      };
    };
    extraScript = ''
      # TLS handled by the default TLSStore in traefik-system (see tls-secret.nix).

      # htpasswd secret for Traefik BasicAuth (key must be 'users')
      echo "Creating registry htpasswd secret..."
      HTPASSWD_CONTENT=$(cat "${config.age.secrets.registry-htpasswd.path}")
      $KUBECTL create secret generic registry-htpasswd \
        --namespace container-registry \
        --from-literal=users="$HTPASSWD_CONTENT" \
        --dry-run=client -o yaml | $KUBECTL apply -f -

      # BasicAuth middleware
      echo "Creating registry-auth middleware..."
      cat <<'MWYAML' | $KUBECTL apply -f -
      apiVersion: traefik.io/v1alpha1
      kind: Middleware
      metadata:
        name: registry-auth
        namespace: container-registry
      spec:
        basicAuth:
          secret: registry-htpasswd
      MWYAML

      # IngressRoute with two routes: anonymous pulls (GET/HEAD) + authed writes
      echo "Creating registry IngressRoute..."
      REGISTRY_HOST=$(hostname registry)
      cat <<ROUTEYAML | $KUBECTL apply -f -
      apiVersion: traefik.io/v1alpha1
      kind: IngressRoute
      metadata:
        name: docker-registry
        namespace: container-registry
      spec:
        entryPoints:
          - websecure
        routes:
          - match: Host(\`$REGISTRY_HOST\`) && (Method(\`GET\`) || Method(\`HEAD\`))
            kind: Rule
            priority: 100
            middlewares:
              - name: hsts-headers
                namespace: traefik-system
            services:
              - name: docker-registry
                port: 5000
          - match: Host(\`$REGISTRY_HOST\`)
            kind: Rule
            priority: 50
            middlewares:
              - name: hsts-headers
                namespace: traefik-system
              - name: registry-auth
                namespace: container-registry
            services:
              - name: docker-registry
                port: 5000
        tls:
          store:
            name: default
            namespace: traefik-system
      ROUTEYAML
    '';
  };

  ui = k8s.createHelmRelease {
    name = "docker-registry-ui";
    namespace = "container-registry";
    repo = {
      name = "docker-registry-ui";
      url = "https://helm.joxit.dev";
    };
    chart = "docker-registry-ui/docker-registry-ui";
    version = "1.1.3";
    tier = "core";
    values = {
      ui = {
        dockerRegistryUrl = "http://docker-registry:5000";
      };
    };
    ingress = {
      host = "registry-ui";
      service = "docker-registry-ui-docker-registry-ui-user-interface";
      port = 80;
    };
    middlewares = [
      {
        name = "registry-auth";
        namespace = "container-registry";
      }
    ];
  };
in
{
  age.secrets.registry-htpasswd = {
    file = "${secretsPath}/registry-htpasswd.age";
  };

  systemd.services = registry.systemd.services // ui.systemd.services;
}
