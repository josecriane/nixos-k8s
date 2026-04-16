# Docker Registry Mirror (pull-through cache for Docker Hub)
#
# config.nix:
#   services.docker-mirror = true;
#
# URL: https://mirror.<subdomain>.<domain>
#
# Configure Docker/containerd to use this mirror to avoid Docker Hub rate limits.
# In containerd config (/etc/containerd/config.toml):
#   [plugins."io.containerd.grpc.v1.cri".registry.mirrors."docker.io"]
#     endpoint = ["https://mirror.<subdomain>.<domain>"]
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
  ingress = {
    host = "mirror";
    service = "docker-registry";
    port = 5000;
  };
}
