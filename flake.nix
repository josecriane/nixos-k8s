{
  description = "NixOS K8s - Declarative K3s cluster on NixOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      disko,
      agenix,
      ...
    }@inputs:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };

      mkCluster =
        {
          clusterConfig,
          hostsPath,
          secretsPath,
          extraModules ? [ ],
          extraSpecialArgs ? { },
        }:
        let
          nodes = clusterConfig.nodes;
          bootstrapName = builtins.head (
            builtins.attrNames (nixpkgs.lib.filterAttrs (_: n: n.bootstrap or false) nodes)
          );
          bootstrapNode = nodes.${bootstrapName};

          mkHost =
            nodeName:
            let
              nodeCfg = nodes.${nodeName};
              nodeConfig = nodeCfg // {
                name = nodeName;
                bootstrapIP = bootstrapNode.ip;
              };
              clusterNodes = nixpkgs.lib.mapAttrsToList (name: cfg: cfg // { inherit name; }) nodes;
            in
            nixpkgs.lib.nixosSystem {
              inherit system;
              specialArgs = {
                inherit
                  inputs
                  secretsPath
                  nodeConfig
                  clusterNodes
                  ;
                serverConfig = clusterConfig;
              }
              // extraSpecialArgs;
              modules = [
                disko.nixosModules.disko
                agenix.nixosModules.default
                "${hostsPath}/${nodeName}"
                "${self}/modules/core"
                "${self}/modules/services"
                "${self}/modules/kubernetes"
              ]
              ++ extraModules;
            };
        in
        builtins.mapAttrs (name: _: mkHost name) nodes;

      # Standalone mode: use config.nix from this repo if it exists
      hasLocalConfig = builtins.pathExists "${self}/config.nix";
    in
    {
      lib.mkCluster = mkCluster;

      nixosConfigurations =
        if hasLocalConfig then
          mkCluster {
            clusterConfig = import "${self}/config.nix";
            hostsPath = "${self}/hosts";
            secretsPath = "${self}/secrets";
          }
        else
          { };

      formatter.${system} = pkgs.nixfmt-tree;

      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          nixos-anywhere
          kubectl
          kubernetes-helm
          k9s
          age
          jq
          yq-go
        ];
        shellHook = ''
          echo "NixOS K8s - Dev Shell"
          echo "Run 'make help' for available commands"
        '';
      };
    };
}
