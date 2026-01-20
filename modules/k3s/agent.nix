{ config, lib, pkgs, ... }:

{
  services.k3s = {
    enable = true;
    role = "agent";

    serverAddr = "https://pi-master-1:6443";

    # Must match the master's token
    tokenFile = "/etc/k3s/token";

    extraFlags = lib.concatStringsSep " " [
      "--flannel-backend=vxlan"
    ];
  };

  systemd.tmpfiles.rules = [
    "f /etc/k3s/token 0600 root root - CHANGEME_SUPER_SECRET_TOKEN"
  ];
}

