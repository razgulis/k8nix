{ config, lib, pkgs, ... }:

let
  masterName = "pi-master-1";
in
{
  services.k3s = {
    enable = true;
    role = "server";
    clusterInit = true;

    # For real usage, put this in a secret manager (sops-nix/agenix).
    # For initial bootstrap only, you can create this file manually.
    tokenFile = "/etc/k3s/token";

    # Optional opinionated defaults
    extraFlags = lib.concatStringsSep " " [
      "--write-kubeconfig-mode=0644"
      "--disable=traefik"
      "--disable=servicelb"
      "--flannel-backend=vxlan"
      # If you later add MetalLB, you usually want servicelb disabled.
    ];
  };

  # Create a placeholder token file if it doesn't exist yet (bootstrap convenience).
  # Replace this with sops-nix or agenix ASAP.
  systemd.tmpfiles.rules = [
    "f /etc/k3s/token 0600 root root - CHANGEME_SUPER_SECRET_TOKEN"
  ];

  # Helpful to manage from the master
  environment.systemPackages = with pkgs; [
    kubectl
  ];
}

