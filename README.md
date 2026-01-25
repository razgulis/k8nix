# k8nix

NixOS flake for a multi-node Raspberry Pi 4 k3s cluster.

## What this repo includes
- Flake outputs for one master and four workers, all aarch64.
- Shared base config (SSH, users, kernel params, tools).
- Network defaults (static LAN IPs, /etc/hosts, firewall).
- SD card image build for headless boot.
- k3s server/agent modules and a sample agenix secrets file.

## Requirements
- Nix with flakes enabled.
- Raspberry Pi 4 devices (aarch64).
- SD card writer (and `dd` or a similar tool).
- Optional: agenix for managing the k3s token.

## Layout
- `flake.nix`: entry point; `nixosConfigurations` for each node.
- `modules/base.nix`: common OS defaults and tools.
- `modules/networking.nix`: static IPs, hosts file, firewall rules.
- `modules/sd-image.nix`: SD image builder.
- `modules/k3s/server.nix`: k3s server config.
- `modules/k3s/agent.nix`: k3s agent config.
- `hosts/*/default.nix`: per-node overrides.
- `secrets/secrets.nix`: agenix recipients and example secret mapping.

## Quick start
1) Update host IPs and gateway in `modules/networking.nix`.
2) Update SSH keys and secrets in `secrets/secrets.nix`.
3) Build an SD card image for a node:

```bash
nix build .#nixosConfigurations.pi-master-1.config.system.build.sdImage
```

The image appears in `./result/sd-image/`.

4) Flash the image (example):

```bash
lsblk
sudo umount /dev/sdX1 /dev/sdX2 2>/dev/null || true
sudo dd if=./result/sd-image/nixos-pi-master-1.img of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

5) Boot the Pi, then repeat for each worker.

Note: flash to the whole device (e.g. `/dev/sda`), not a partition (e.g. `/dev/sda1`).

## SSH access
- Default user is `admin` (key-based auth; password login is disabled). Update the SSH key and Home Manager defaults in `modules/base.nix`.

## Name resolution
- Nodes advertise `*.local` via mDNS (e.g. `pi-master-1.local`) and can be reached by name on clients that support mDNS.

## DNS (Blocky)
- `pi-master-1` runs `blocky` and listens on port `53` (TCP/UDP).
- The `systemd-resolved` DNS stub listener is disabled on the master so Blocky can bind to `:53`.

## Cluster bootstrap notes
- The k3s token is read from `/etc/k3s/token`.
- A placeholder token is created by tmpfiles rules in the k3s modules.
- For real usage, replace the placeholder with agenix (or another secret manager).

## Development shell
This flake exposes a dev shell with agenix:

```bash
nix develop
```

## Customize
- Add per-node tweaks in `hosts/<node>/default.nix`.
- Update k3s flags in `modules/k3s/server.nix` or `modules/k3s/agent.nix`.
- If you want DHCP instead of static IPs, flip the commented settings in
  `modules/networking.nix`.
