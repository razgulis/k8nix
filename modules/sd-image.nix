{ config, lib, pkgs, ... }:

{
  # Enables: config.system.build.sdImage
  imports = [
    "${pkgs.path}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
  ];

  # Quality-of-life for headless boot
  services.openssh.enable = true;

  # Optional: don’t compress; faster builds
  sdImage.compressImage = false;

  # Optional: a touch more room before first boot expand (still expands on first boot)
  sdImage.imageBaseName = "nixos-${config.networking.hostName}";
}

