{
  description = "NixOS multi-node Raspberry Pi k3s cluster";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-hardware.url = "github:NixOS/nixos-hardware";

    agenix.url = "github:ryantm/agenix";
  };

  outputs = { self, nixpkgs, nixos-hardware, agenix }:
    let
      # Target platform for the Raspberry Pi images.
      targetSystem = "aarch64-linux";

      # Shell tooling should be available on common dev hosts too.
      devSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs devSystems (system: f system);

      mkHost = { hostName, roleModule }:
        nixpkgs.lib.nixosSystem {
          system = targetSystem;
          specialArgs = { inherit hostName; };

          modules = [
            nixos-hardware.nixosModules.raspberry-pi-4
            agenix.nixosModules.default

            ./modules/base.nix
            ./modules/networking.nix
            ./modules/sd-image.nix

            roleModule
            (./hosts + "/${hostName}/default.nix")
          ];
        };
    in
    {
      nixosConfigurations = {
        pi-master-1     = mkHost { hostName = "pi-master-1";     roleModule = ./modules/k3s/server.nix; };
        pi-worker-1     = mkHost { hostName = "pi-worker-1";     roleModule = ./modules/k3s/agent.nix; };
        pi-worker-2     = mkHost { hostName = "pi-worker-2";     roleModule = ./modules/k3s/agent.nix; };
        pi-worker-3     = mkHost { hostName = "pi-worker-3";     roleModule = ./modules/k3s/agent.nix; };
        pi-worker-4-hdd = mkHost { hostName = "pi-worker-4-hdd"; roleModule = ./modules/k3s/agent.nix; };
      };

      devShells = forAllSystems (system: {
        default = nixpkgs.legacyPackages.${system}.mkShell {
          packages = [ agenix.packages.${system}.default ];
        };
      });
    };
}
