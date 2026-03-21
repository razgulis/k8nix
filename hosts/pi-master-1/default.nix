{ config, lib, pkgs, ... }:
{
  imports = [
    ../../modules/blocky
    ../../modules/k3s/argocd.nix
    ../../modules/k3s/external-secrets.nix
    ../../modules/k3s/ingress.nix
    ../../modules/k3s/openebs-zfs.nix
    ../../modules/k3s/vault.nix
  ];

  k8nix.argocd = {
    enable = true;
    bootstrapApp = {
      repoURL = "https://github.com/razgulis/k8nix-apps";
      targetRevision = "master";
      path = "argocd";
    };
    allowedSourceRepos = [
      "https://github.com/razgulis/k8nix-apps*"
      "https://gitlab.gitlab.svc.cluster.local/*/*"
    ];
  };

  k8nix.ingress = {
    enable = true;
    loadBalancerIP = "192.168.1.254";
  };

  networking.nameservers = [ "127.0.0.1" ];

  networking.firewall.allowedTCPPorts = lib.mkAfter [ 53 ];
  networking.firewall.allowedUDPPorts = lib.mkAfter [ 53 ];

  # If you want the master to be schedulable (not recommended), set this true.
  # For a normal master-only control-plane, leave as-is and use taints (k3s defaults).
}
