{ config, lib, pkgs, modulesPath, ... }:

{
  # Enables: config.system.build.sdImage
  imports = [
    (modulesPath + "/installer/sd-card/sd-image-aarch64.nix")
  ];

  # `sd-image-aarch64.nix` enables `hardware.enableAllHardware`, which pulls in a
  # broad set of initrd modules. The Raspberry Pi kernel package doesn't ship
  # every possible module (e.g. `dw-hdmi`), so allow missing modules to avoid
  # failing the image build.
  boot.initrd.allowMissingModules = true;

  # Quality-of-life for headless boot
  services.openssh.enable = true;

  # Optional: don’t compress; faster builds
  sdImage.compressImage = false;

  # Optional: a touch more room before first boot expand (still expands on first boot)
  image.baseName = "nixos-${config.networking.hostName}";
}
