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
  networking.useDHCP = false;

  # Wired ethernet is commonly `end0` on NixOS Pi images, but may be `eth0`
  # depending on predictable interface naming.
  systemd.network.networks."10-lan" = {
    matchConfig.Name = "end0 eth0";
    # Static per-node IPs (default for this repo). To use DHCP instead, comment
    # out `address`/`gateway`/`dns` and set `networkConfig.DHCP = "yes";`.
    networkConfig.DHCP = "no";
    # Advertise `${networking.hostName}.local` via mDNS (systemd-resolved).
    networkConfig.MulticastDNS = "yes";
    address = [ "${nodes.${config.networking.hostName}}/24" ];
    gateway = [ "192.168.1.1" ];
    # Prefer the cluster DNS (Blocky) when available, but fall back to the gateway.
    dns = [ masterIP "192.168.1.1" ];
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
      5353    # mDNS (hostname.local discovery)
    ];

    # NodePort range (optional, but convenient on bare metal)
    allowedTCPPortRanges = [
      { from = 30000; to = 32767; }
    ];
  };
}
