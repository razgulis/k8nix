{ config, lib, pkgs, ... }:

let
  # Update these IPs to match your LAN plan (DHCP reservations recommended).
  nodes = {
    "pi-master-1"     = "192.168.1.200";
    "pi-worker-1"     = "192.168.1.201";
    "pi-worker-2"     = "192.168.1.202";
    "pi-worker-3"     = "192.168.1.203";
    "pi-worker-4-hdd" = "192.168.1.204";
  };

  # Prefer the master name; it will be in /etc/hosts via extraHosts.
  masterName = "pi-master-1";
  masterIP   = nodes.${masterName};
in
{
  # Prefer networkd on servers
  networking.useNetworkd = true;
  systemd.network.enable = true;

  # Assuming wired ethernet is `end0` (common on Pi 4 NixOS).
  systemd.network.networks."10-lan" = {
    # DHCP assigned IPs
    #matchConfig.Name = "end0";
    #networkConfig.DHCP = "yes";
    
    # If you want fully static IPs per node instead:
    address = [ "${nodes.${config.networking.hostName}}/24" ];
    gateway = [ "192.168.1.1" ];
    #dns = [ "192.168.1.200" ];
    dns = [ "192.168.1.1" ];
  };

  # Simple name resolution without depending on LAN DNS
  networking.extraHosts =
    lib.concatStringsSep "\n" (lib.mapAttrsToList (name: ip: "${ip} ${name}") nodes);

  networking.firewall = {
    enable = true;

    # Kubernetes / k3s common ports
    allowedTCPPorts = [
      22      # ssh
      6443    # kube-apiserver on server
      10250   # kubelet
      2379    # etcd (if using embedded etcd / server)
      2380
    ];

    allowedUDPPorts = [
      8472    # flannel VXLAN
    ];

    # NodePort range (optional, but convenient on bare metal)
    allowedTCPPortRanges = [
      { from = 30000; to = 32767; }
    ];
  };
}

