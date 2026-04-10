# Docker Registry + UI
#
# config.nix:
#   services.docker-registry = true;
#
# URLs:
#   Registry: https://registry.<subdomain>.<domain>
#   UI:       https://registry-ui.<subdomain>.<domain>
#
# Push example: docker push registry.<subdomain>.<domain>/myimage:latest
{ config, lib, pkgs, serverConfig, ... }:

let
  k8s = import ../lib.nix { inherit pkgs serverConfig; };
in
lib.mkMerge [
  # Container registry
  (k8s.createHelmRelease {
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
    ingress = {
      host = "registry";
      service = "docker-registry";
      port = 5000;
    };
  })

  # Registry UI
  (k8s.createHelmRelease {
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
  })
]
