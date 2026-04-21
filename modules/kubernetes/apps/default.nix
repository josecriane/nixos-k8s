{
  lib,
  serverConfig,
  nodeConfig,
  ...
}:

let
  isBootstrap = nodeConfig.bootstrap or false;
  svc = serverConfig.services or { };
  enabled = name: svc.${name} or false;
  onBootstrap = name: isBootstrap && (enabled name);
in
{
  imports =
    lib.optionals (onBootstrap "docker-registry") [
      ./docker-registry
    ]
    ++ lib.optionals (onBootstrap "docker-mirror") [
      ./docker-mirror
    ]
    ++ lib.optionals (onBootstrap "github-runners") [
      ./github-runners
    ];
}
