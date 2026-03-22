# k8nix

NixOS flake for a mixed-architecture k3s cluster (Raspberry Pi + x86_64 storage worker).

## What this repo includes
- Flake outputs for one master + four Pi workers (aarch64) + one x86_64 storage worker.
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
- `modules/k3s/argocd.nix`: Argo CD install + bootstrap app-of-apps.
- `modules/k3s/openebs-zfs.nix`: OpenEBS install + ZFS StorageClasses.
- `hosts/r630-storage/disko.nix`: declarative disk/pool layout for the R630.
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

## Continued Development (updating without reflashing)
- ssh into the instance, then make sure this repository is cloned:
  `mkdir repositories; cd repositories; git clone https://github.com/razgulis/k8nix.git`
- if the repo is already checked out:
  `git pull`
- rebuild the flake you are currently on:
  `sudo nixos-rebuild switch --flake .#pi-worker-X`

## Roll out to multiple nodes
Use `scripts/rebuild-nodes.sh` from your dev machine to update several nodes in one run.

Examples:

```bash
# Rebuild all default nodes (master, workers, storage)
scripts/rebuild-nodes.sh

# Rebuild only specific nodes
scripts/rebuild-nodes.sh pi-worker-3 pi-worker-4

# Pull a specific branch before rebuilding
scripts/rebuild-nodes.sh --branch master

# If a node has local repo drift, discard changes and continue
scripts/rebuild-nodes.sh --discard-local-changes pi-worker-3 pi-worker-4
```

The script:
- SSHes into each node as `admin` (override with `SSH_USER`).
- Checks that the remote repo is clean.
- Can explicitly discard remote local changes with `--discard-local-changes`.
- Runs `git pull --ff-only` (unless `--no-pull`).
- Runs `sudo nixos-rebuild switch --flake .#<node-name>`.

## Infrastructure health check
Use `scripts/check-infra.sh` to validate cluster health after restarts or maintenance.

It checks:
- API reachability and node readiness.
- Required namespaces and storage classes.
- Deployment/StatefulSet/DaemonSet readiness in key namespaces.
- Argo CD app sync/health.
- External Secrets readiness.
- Vault unsealed state.
- Global pod readiness/status sweep.

Examples:

```bash
# Default checks
scripts/check-infra.sh

# Verify specific expected nodes are all Ready
scripts/check-infra.sh --expected-nodes pi-master-1,pi-worker-1,pi-worker-2,pi-worker-3,pi-worker-4,r630-storage

# Skip Argo checks (if Argo is intentionally down for maintenance)
scripts/check-infra.sh --no-argo-app-check
```

The script exits non-zero on failures so it can be used in automation.

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

## Argo CD bootstrap (pi-master-1)
- `pi-master-1` imports `modules/k3s/argocd.nix`, which:
  - installs Argo CD in-cluster via k3s `HelmChart`
  - recursively scans the `argocd/` path in `k8nix-apps` for Application manifests
  - creates an AppProject that allows both:
    - `https://github.com/razgulis/k8nix-apps*`
    - `https://gitlab.gitlab.svc.cluster.local/*/*` (future in-cluster GitLab repos)
  - bootstraps the root app (`k8nix-apps`) from:
    - repo: `https://github.com/razgulis/k8nix-apps`
    - revision: `master`
    - path: `argocd`
- The root app can define child applications, including ones pointing to the in-cluster GitLab repo, which avoids circular dependencies in this infra repo.
- To access Argo CD UI without exposing it publicly:

```bash
sudo k3s kubectl -n argocd port-forward svc/argocd-server 8080:80
```

- Verify bootstrap objects:

```bash
sudo k3s kubectl -n argocd get appprojects,applications
```

## Worker kubeconfig (read-only)
Workers can optionally have a read-only kubeconfig at `/home/admin/.kube/config` (encrypted via agenix as `secrets/kubeconfig-ro.age`).

High level:
1) Ensure the master has the read-only RBAC manifest applied (after rebuilding `pi-master-1`).
2) Generate a token and write a kubeconfig pointing at `https://pi-master-1:6443`.
3) Encrypt that kubeconfig into `secrets/kubeconfig-ro.age` and rebuild the workers.

After the master rebuild, the RBAC is applied automatically from `/var/lib/rancher/k3s/server/manifests/readonly-kubeconfig-rbac.yaml`.

Example (run on `pi-master-1`):

```bash
TOKEN="$(sudo k3s kubectl -n kube-system create token readonly-kubeconfig --duration=8760h)"
CA_B64="$(sudo base64 -w0 /var/lib/rancher/k3s/server/tls/server-ca.crt)"

cat > /tmp/kubeconfig-ro.yaml <<EOF
apiVersion: v1
kind: Config
clusters:
- name: default
  cluster:
    certificate-authority-data: ${CA_B64}
    server: https://pi-master-1:6443
users:
- name: readonly
  user:
    token: ${TOKEN}
contexts:
- name: default
  context:
    cluster: default
    user: readonly
current-context: default
EOF
```

Then (on your dev machine in this repo):

```bash
nix develop
cd secrets
RULES=./secrets.nix EDITOR=vim agenix -e kubeconfig-ro.age -i ~/.ssh/nix-pi-cluster
```

Paste the contents of `/tmp/kubeconfig-ro.yaml`, save, then rebuild worker nodes/images.

Notes:
- The `laptop` key in `secrets/secrets.nix` must match the public key of the private key you use with `-i`.
- Replace `~/.ssh/nix-pi-cluster` with the private key you actually use on your dev machine.
- If you get `Forbidden: nodes is forbidden`, the RBAC manifest wasn’t applied on the master; rebuild `pi-master-1`.

Troubleshooting (run on `pi-master-1`):
```bash
sudo k3s kubectl auth can-i list nodes \
  --as system:serviceaccount:kube-system:readonly-kubeconfig
```

## Add a worker node (example: `pi-worker-2`)
1) Update IPs (if needed) in `modules/networking.nix` and ensure the node name exists in `nodes`.
2) Build and flash the worker image:

```bash
nix build .#nixosConfigurations.pi-worker-2.config.system.build.sdImage
sudo dd if=./result/sd-image/nixos-pi-worker-2.img of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

3) Boot the Pi and SSH in:

```bash
ssh admin@pi-worker-2
```

4) On the new worker, print its host key:

```bash
sudo cat /etc/ssh/ssh_host_ed25519_key.pub
```

5) On your dev machine, add that key to `secrets/secrets.nix` under `hosts = { ... }` and include it in `k3sNodes`.
6) Re-key `kubeconfig-ro.age` so the new worker can decrypt it:

```bash
cd secrets
RULES=./secrets.nix agenix -r -i ~/.ssh/nix-pi-cluster
```

7) Commit and push the updated secrets:

```bash
git add secrets/secrets.nix secrets/kubeconfig-ro.age
git commit -m "Add pi-worker-2 host key"
git push
```

8) On the worker, pull and rebuild:

```bash
cd ~/repositories/k8nix
git pull
sudo nixos-rebuild switch --flake .#pi-worker-2
```

9) Verify the node joins from the master:

```bash
sudo k3s kubectl get nodes -o wide
```

Notes:
- The worker joins using `/etc/k3s/token`; ensure it matches the master.
- If the worker doesn’t join, check logs on the worker: `sudo journalctl -u k3s -b --no-pager | tail -200`.

## `r630-storage` (x86_64 storage + heavy workloads)
- Host config is under `hosts/r630-storage/`.
- Disk geometry is declarative in `hosts/r630-storage/disko.nix`.
- It runs as a k3s agent with ZFS enabled and imports pools `r630-main` and `r630-bulk`.
- It advertises labels for storage-oriented scheduling:
  - `k8nix.io/role=storage`
  - `k8nix.io/storage=true`
  - `k8nix.io/ai-data=true`
  - `workload=heavy`
- `pi-master-1` applies OpenEBS and the following StorageClasses:
  - `zfs-reliable` -> `poolname: r630-main`
  - `zfs-ai-postgres` -> `poolname: r630-main` (PostgreSQL/TimescaleDB/pgvector)
  - `zfs-bulk` -> `poolname: r630-bulk`
  - `zfs-ai-minio` -> `poolname: r630-bulk` (MinIO object storage)
- Build/evaluate this host with:

```bash
nix build .#nixosConfigurations.r630-storage.config.system.build.toplevel
```

### AI data stack repo split
- Keep infra primitives (node labels, storage classes, cluster bootstrap) in this repo (`k8nix-infra`).
- Define app workloads (PostgreSQL/TimescaleDB/pgvector and MinIO manifests/Helm values) in your Argo app repo (`k8nix-apps` or in-cluster GitLab app repo).
- MCP service is intentionally deferred for now.

### Vault + External Secrets (no plaintext app passwords in Git)
- `modules/k3s/vault.nix` installs HashiCorp Vault via k3s `HelmChart`.
- `modules/k3s/external-secrets.nix` installs External Secrets Operator via k3s `HelmChart`.
- `hosts/pi-master-1/default.nix` imports both modules.
- `k8nix-apps/apps/ai-data/external-secrets.yaml` defines:
  - ServiceAccount + SecretStore (`vault-ai-data`)
  - ExternalSecrets that materialize `minio-ai-auth` and `postgres-ai-auth`
- `k8nix-apps/apps/ai-data/minio.yaml` and `postgres.yaml` no longer store password values.

One-time bootstrap after rebuilding `pi-master-1` and waiting for `vault-0`:

```bash
# 1) Initialize and unseal vault (save output securely; do not commit it).
kubectl -n vault exec -it vault-0 -- vault operator init
kubectl -n vault exec -it vault-0 -- vault operator unseal <unseal-key-1>
kubectl -n vault exec -it vault-0 -- vault operator unseal <unseal-key-2>
kubectl -n vault exec -it vault-0 -- vault operator unseal <unseal-key-3>

# 2) Log in with the initial root token.
kubectl -n vault exec -it vault-0 -- sh -lc 'vault login <root-token>'

# 3) Enable KV v2 and Kubernetes auth.
kubectl -n vault exec -it vault-0 -- sh -lc 'vault secrets enable -path=kv kv-v2 || true'
kubectl -n vault exec -it vault-0 -- sh -lc 'vault auth enable kubernetes || true'
kubectl -n vault exec -it vault-0 -- sh -lc '\''vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443" \
  token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt'\''

# 4) Create policy and role for ai-data External Secrets SA.
kubectl -n vault exec -it vault-0 -- sh -lc "cat >/tmp/ai-data-policy.hcl <<'EOF'
path \"kv/data/ai-data/*\" {
  capabilities = [\"read\"]
}
EOF
vault policy write ai-data-read /tmp/ai-data-policy.hcl"

kubectl -n vault exec -it vault-0 -- sh -lc 'vault write auth/kubernetes/role/ai-data-external-secrets \
  bound_service_account_names=external-secrets-vault \
  bound_service_account_namespaces=ai-data \
  policies=ai-data-read \
  ttl=24h'

# 5) Write initial application credentials in Vault.
MINIO_PASS="$(openssl rand -hex 32)"
PG_PASS="$(openssl rand -hex 32)"

kubectl -n vault exec -it vault-0 -- sh -lc "vault kv put kv/ai-data/minio \
  MINIO_ROOT_USER=minioadmin \
  MINIO_ROOT_PASSWORD=${MINIO_PASS}"

kubectl -n vault exec -it vault-0 -- sh -lc "vault kv put kv/ai-data/postgres \
  POSTGRES_DB=signaldb \
  POSTGRES_USER=ai_app \
  POSTGRES_PASSWORD=${PG_PASS}"
```

Password rotation (no Git changes required):

```bash
# Rotate in Vault.
NEW_MINIO_PASS="$(openssl rand -hex 32)"
NEW_PG_PASS="$(openssl rand -hex 32)"
kubectl -n vault exec -it vault-0 -- sh -lc "vault kv patch kv/ai-data/minio MINIO_ROOT_PASSWORD=${NEW_MINIO_PASS}"
kubectl -n vault exec -it vault-0 -- sh -lc "vault kv patch kv/ai-data/postgres POSTGRES_PASSWORD=${NEW_PG_PASS}"

# Force workload restarts so env vars pick up the new values.
kubectl -n ai-data rollout restart sts/minio-ai
kubectl -n ai-data rollout restart sts/postgres-ai
```

### Ensure ZFS PV datasets exist (day-2 on existing installs)
On already-installed machines, `nixos-rebuild switch` will not create missing
ZFS datasets from `disko.nix`. Run the following once on `r630-storage`:

```bash
if ! sudo zfs list -H -o name r630-main/k3s/pv >/dev/null 2>&1; then
  sudo zfs create -p \
    -o mountpoint=/var/lib/zfs-pv/reliable \
    -o canmount=on \
    -o recordsize=16K \
    r630-main/k3s/pv
fi

if ! sudo zfs list -H -o name r630-bulk/k3s/pv >/dev/null 2>&1; then
  sudo zfs create -p \
    -o mountpoint=/var/lib/zfs-pv/bulk \
    -o canmount=on \
    -o recordsize=1M \
    r630-bulk/k3s/pv
fi

if [ "$(sudo zfs get -H -o value mounted r630-main/k3s/pv)" != "yes" ]; then
  sudo zfs mount r630-main/k3s/pv
fi

if [ "$(sudo zfs get -H -o value mounted r630-bulk/k3s/pv)" != "yes" ]; then
  sudo zfs mount r630-bulk/k3s/pv
fi

sudo systemctl reset-failed var-lib-zfs\\x2dpv-reliable.mount var-lib-zfs\\x2dpv-bulk.mount
sudo systemctl start var-lib-zfs\\x2dpv-reliable.mount var-lib-zfs\\x2dpv-bulk.mount
sudo mkdir -p /var/lib/zfs-pv/reliable/gitlab
```

Verify:

```bash
sudo zfs list r630-main/k3s/pv r630-bulk/k3s/pv
findmnt /var/lib/zfs-pv/reliable /var/lib/zfs-pv/bulk
```

The host config also includes an idempotent service
(`k8nix-zfs-pv-datasets.service`) that ensures these datasets/mounts on rebuild.
After pulling this repo update on `r630-storage`, run:

```bash
sudo nixos-rebuild switch --flake .#r630-storage
sudo systemctl start k8nix-zfs-pv-datasets.service
```

### Bare-metal rebuild (`r630-storage`)
Use this when you want to wipe/recreate the machine from scratch with this repo as source of truth.

1) Boot into NixOS installer media on the R630.
2) Clone this repo in the live environment.
3) Set the `osDisk` by-id path in `hosts/r630-storage/disko.nix` to the dedicated OS drive.
4) Partition/create pools from the declarative layout:

```bash
sudo nix run github:nix-community/disko -- --mode disko --flake .#r630-storage
```

5) Install NixOS:

```bash
sudo nixos-install --flake .#r630-storage
```

Warning: this is destructive and will wipe data on the configured disks/pools.

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
