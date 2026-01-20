{ config, lib, pkgs, hostName, ... }:

{
  networking.hostName = hostName;

  # Basic system defaults for small ARM nodes
  time.timeZone = "America/Denver";
  i18n.defaultLocale = "en_US.UTF-8";

  services.openssh.enable = true;
  services.openssh.settings = {
    PasswordAuthentication = false;
    KbdInteractiveAuthentication = false;
    PermitRootLogin = "no";
  };

  users.users.admin = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOW8xWUfi/PtattP6DK+kQ74ynKikXPWx+OPkPN73ROG sergei.razgulin@gmail.com"
    ];
  };

  security.sudo.wheelNeedsPassword = false;

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    auto-optimise-store = true;
  };

  # Helpful on Pis
  hardware.enableRedistributableFirmware = true;
  services.timesyncd.enable = true;

  # Reduce SD wear a bit
  zramSwap.enable = true;

  # Often used for Kubernetes on Raspberry Pi (may be redundant on newer kernels, harmless)
  boot.kernelParams = [
    "cgroup_enable=cpuset"
    "cgroup_enable=memory"
    "cgroup_memory=1"
  ];

  # A few tools
  environment.systemPackages = with pkgs; [
    vim
    git
    htop
    curl
    jq
    iproute2
    ethtool
  ];

  system.stateVersion = "24.11";
}

