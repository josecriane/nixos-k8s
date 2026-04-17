# Docker Registry Mirror (pull-through cache for Docker Hub)
#
# config.nix:
#   services.docker-mirror = true;
#
# Internal-only service, no external ingress. Accessed by pods in the cluster
# via: http://docker-mirror-docker-registry.container-mirror.svc.cluster.local:5000
#
# This URL is used automatically by the DinD sidecar in GitHub runners
# (see modules/kubernetes/apps/github-runners.nix).
{
  config,
  lib,
  pkgs,
  serverConfig,
  ...
}:

let
  k8s = import ../lib.nix { inherit pkgs serverConfig; };
in
k8s.createHelmRelease {
  name = "docker-mirror";
  namespace = "container-mirror";
  repo = {
    name = "docker-registry";
    url = "https://twuni.github.io/docker-registry.helm";
  };
  chart = "docker-registry/docker-registry";
  version = "2.2.3";
  tier = "core";
  values = {
    proxy = {
      enabled = true;
      remoteurl = "https://registry-1.docker.io";
    };
    persistence = {
      enabled = true;
      size = "100Gi";
    };
  };
}
