{ config, lib, pkgs, hostName, ... }:

{
  networking.hostName = hostName;

  # Basic system defaults for small ARM nodes
  time.timeZone = "America/Denver";
  i18n.defaultLocale = "en_US.UTF-8";

  # Headless defaults: avoid pulling in desktop integration extras.
  services.xserver.enable = false;
  xdg = {
    icons.enable = false;
    mime.enable = false;
    sounds.enable = false;
  };

  services.openssh.enable = true;
  services.openssh.settings = {
    PasswordAuthentication = false;
    KbdInteractiveAuthentication = false;
    PermitRootLogin = "no";
  };

  users.users.admin = {
    isNormalUser = true;
    createHome = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOW8xWUfi/PtattP6DK+kQ74ynKikXPWx+OPkPN73ROG sergei.razgulin@gmail.com"
    ];
  };

  security.sudo.wheelNeedsPassword = false;

  # Headless images: Home Manager 25.05 expects `pkgs.libsForQt5.fcitx5-with-addons`,
  # but newer nixpkgs moved it. Provide a tiny stub package so evaluation works
  # without pulling a full GUI/input-method stack into the image.
  nixpkgs.overlays = [
    (final: prev: {
      libsForQt5 = prev.libsForQt5 // {
        fcitx5-with-addons =
          prev.runCommand "fcitx5-with-addons-stub" { } "mkdir -p $out";
      };
    })
  ];

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;

    users.admin = { ... }: {
      home.stateVersion = "23.05";

      # Headless images don't need per-user font discovery/caching.
      fonts.fontconfig.enable = false;

      programs.git = {
        enable = true;
        userName = "Sergei Razgulin";
        userEmail = "sergei.razgulin@gmail.com";
        extraConfig = {
          core.editor = "vim";
          merge.tool = "vimdiff";
          merge.conflictstyle = "diff3";
          alias = {
            co = "checkout";
            ci = "commit";
            st = "status";
            br = "branch";
          };
        };
      };

      programs.vim = {
        enable = true;
        extraConfig = ''
          set mouse=v
        '';
      };
    };
  };

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
    btop
    curl
    jq
    iproute2
    ethtool
    tldr
  ];

  # Shell Aliases
  programs.bash.shellAliases = {
    la = "ls -alh";
  };

  system.stateVersion = "24.11";
}
