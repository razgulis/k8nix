{ config, lib, pkgs, ... }:
{
  # Optional: since this node has a HDD, you might prefer it for persistent workloads.
  # You can add node labels via k3s extraFlags if you like, e.g.:
  
  services.k3s.extraFlags = (config.services.k3s.extraFlags or "") + " --node-label storage=hdd";
}

