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
          cfg = nixpkgs.lib.recursiveUpdate (import ./modules/cluster-defaults.nix) clusterConfig;

          nodes = cfg.nodes;
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
                serverConfig = cfg;
                k8s = import ./modules/kubernetes/lib.nix {
                  inherit pkgs;
                  serverConfig = cfg;
                };
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

      apps.${system} =
        let
          mkScriptApp = name: path: {
            type = "app";
            program = toString (
              pkgs.writeShellScript "nixos-k8s-${name}" ''
                export PROJECT_DIR="''${PROJECT_DIR:-$PWD}"
                exec ${path} "$@"
              ''
            );
          };
        in
        {
          install = mkScriptApp "install" "${self}/scripts/install.sh";
          unlock = mkScriptApp "unlock" "${self}/scripts/unlock.sh";
          enroll-tpm = mkScriptApp "enroll-tpm" "${self}/scripts/enroll-tpm.sh";
          setup = mkScriptApp "setup" "${self}/scripts/setup.sh";
          add-node = mkScriptApp "add-node" "${self}/scripts/add-node.sh";
          sync-bootstrap-secrets = mkScriptApp "sync-bootstrap-secrets" "${self}/scripts/sync-bootstrap-secrets.sh";
        };

      checks.${system} =
        let
          base = import "${self}/config.example.nix";
          mkVariant =
            suffix: overrides:
            nixpkgs.lib.mapAttrs'
              (name: node: nixpkgs.lib.nameValuePair "${name}${suffix}" node.config.system.build.toplevel)
              (mkCluster {
                clusterConfig = base // overrides;
                hostsPath = "${self}/hosts";
                secretsPath = "${self}/secrets";
              });
        in
        mkVariant "" { }
        // mkVariant "-kubeadm-calico" {
          kubernetes = base.kubernetes // {
            engine = "kubeadm";
            cni = "calico";
          };
        }
        // mkVariant "-services" {
          services = base.services // {
            monitoring = true;
            traefikDashboard = true;
            docker-registry = true;
            docker-mirror = true;
          };
          storage = base.storage // {
            useNFS = true;
          };
          nas.nas1 = {
            enabled = true;
            ip = "192.168.1.50";
          };
        };

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
