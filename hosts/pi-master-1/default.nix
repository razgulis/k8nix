{ config, lib, pkgs, ... }:
{
  imports = [
    ../../modules/blocky.nix
  ];

  networking.nameservers = [ "127.0.0.1" ];

  networking.firewall.allowedTCPPorts =
    config.networking.firewall.allowedTCPPorts ++ [ 53 ];
  networking.firewall.allowedUDPPorts =
    config.networking.firewall.allowedUDPPorts ++ [ 53 ];

  # If you want the master to be schedulable (not recommended), set this true.
  # For a normal master-only control-plane, leave as-is and use taints (k3s defaults).
}
