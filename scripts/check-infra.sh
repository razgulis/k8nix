#!/usr/bin/env bash
set -euo pipefail

KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-10s}"

REQUIRED_NAMESPACES_CSV="${REQUIRED_NAMESPACES_CSV:-argocd,ingress-nginx,metallb-system,openebs,external-secrets,vault,ai-data}"
REQUIRED_STORAGE_CLASSES_CSV="${REQUIRED_STORAGE_CLASSES_CSV:-zfs-reliable,zfs-ai-postgres,zfs-bulk,zfs-ai-minio}"
EXPECTED_NODES_CSV="${EXPECTED_NODES_CSV:-}"

CHECK_ARGO_APPS=1
CHECK_GLOBAL_PODS=1
CHECK_NODE_VERSIONS="${CHECK_NODE_VERSIONS:-1}"

SSH_BIN="${SSH_BIN:-ssh}"
NIX_BIN="${NIX_BIN:-nix}"
GIT_BIN="${GIT_BIN:-git}"
SSH_USER="${SSH_USER:-admin}"
DEFAULT_REPO_DIR="/home/${SSH_USER}/repositories/k8nix-infra"
REPO_DIR="${REPO_DIR:-$DEFAULT_REPO_DIR}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-6}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_REPO_DIR="${LOCAL_REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

FAILURES=()
WARNINGS=()
DISCOVERED_NODES=()

# Color output is enabled only for interactive terminals, and can be disabled
# explicitly with NO_COLOR=1.
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'
  C_INFO=$'\033[1;34m'
  C_PASS=$'\033[1;32m'
  C_WARN=$'\033[1;33m'
  C_FAIL=$'\033[1;31m'
else
  C_RESET=""
  C_INFO=""
  C_PASS=""
  C_WARN=""
  C_FAIL=""
fi

usage() {
  cat <<'EOF'
Usage:
  scripts/check-infra.sh [options]

Options:
  --kubectl-bin <path>              kubectl binary to use (default: kubectl)
  --request-timeout <duration>      kubectl request timeout (default: 10s)
  --required-namespaces <csv>       namespaces that must exist
  --required-storage-classes <csv>  storage classes that must exist
  --expected-nodes <csv>            node names that must be Ready
  --no-argo-app-check               skip Argo CD Application health/sync checks
  --no-global-pod-check             skip global pod readiness/status sweep
  --no-node-version-check           skip node code/drift checks via SSH + nix eval
  --ssh-user <name>                 SSH user for node version checks (default: admin)
  --repo-dir <path>                 repo path on nodes (default: /home/<ssh-user>/repositories/k8nix-infra)
  --local-repo-dir <path>           local repo path to compare against (default: repo root)
  -h, --help                        show this help

Environment equivalents:
  KUBECTL_BIN, REQUEST_TIMEOUT, REQUIRED_NAMESPACES_CSV,
  REQUIRED_STORAGE_CLASSES_CSV, EXPECTED_NODES_CSV,
  CHECK_NODE_VERSIONS, SSH_USER, REPO_DIR, LOCAL_REPO_DIR,
  SSH_BIN, NIX_BIN, GIT_BIN, SSH_CONNECT_TIMEOUT

Examples:
  scripts/check-infra.sh
  scripts/check-infra.sh --expected-nodes pi-master-1,pi-worker-1,pi-worker-2,pi-worker-3,pi-worker-4,r630-storage
  scripts/check-infra.sh --local-repo-dir "$PWD" --ssh-user admin
EOF
}

log_info() {
  echo "${C_INFO}[INFO]${C_RESET} $*"
}

log_pass() {
  echo "${C_PASS}[PASS]${C_RESET} $*"
}

log_warn() {
  echo "${C_WARN}[WARN]${C_RESET} $*"
  WARNINGS+=("$*")
}

log_fail() {
  echo "${C_FAIL}[FAIL]${C_RESET} $*"
  FAILURES+=("$*")
}

kubectl_cmd() {
  "$KUBECTL_BIN" --request-timeout "$REQUEST_TIMEOUT" "$@"
}

csv_to_lines() {
  local csv="$1"
  if [[ -z "$csv" ]]; then
    return 0
  fi
  tr ',' '\n' <<< "$csv" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d'
}

check_nodes() {
  local nodes_raw
  if ! nodes_raw="$(kubectl_cmd get nodes --no-headers 2>/dev/null)"; then
    log_fail "Cannot list cluster nodes"
    return
  fi

  if [[ -z "$nodes_raw" ]]; then
    log_fail "No nodes returned by the API"
    return
  fi

  DISCOVERED_NODES=()
  while read -r node _; do
    [[ -n "${node:-}" ]] && DISCOVERED_NODES+=("$node")
  done <<< "$nodes_raw"

  local not_ready
  not_ready="$(awk '$2 !~ /^Ready/ {print $1}' <<< "$nodes_raw" | xargs || true)"
  if [[ -n "$not_ready" ]]; then
    log_fail "Some nodes are not Ready: $not_ready"
  else
    local count
    count="$(wc -l <<< "$nodes_raw" | tr -d ' ')"
    log_pass "All nodes are Ready ($count nodes)"
  fi

  if [[ -n "$EXPECTED_NODES_CSV" ]]; then
    while IFS= read -r expected; do
      if ! awk -v n="$expected" '$1 == n && $2 ~ /^Ready/' <<< "$nodes_raw" >/dev/null; then
        log_fail "Expected node '$expected' is missing or not Ready"
      fi
    done < <(csv_to_lines "$EXPECTED_NODES_CSV")
  fi
}

check_namespaces() {
  while IFS= read -r ns; do
    if kubectl_cmd get namespace "$ns" >/dev/null 2>&1; then
      log_pass "Namespace exists: $ns"
    else
      log_fail "Missing namespace: $ns"
    fi
  done < <(csv_to_lines "$REQUIRED_NAMESPACES_CSV")
}

check_storage_classes() {
  while IFS= read -r sc; do
    if kubectl_cmd get storageclass "$sc" >/dev/null 2>&1; then
      log_pass "StorageClass exists: $sc"
    else
      log_fail "Missing StorageClass: $sc"
    fi
  done < <(csv_to_lines "$REQUIRED_STORAGE_CLASSES_CSV")
}

check_deployments_in_namespace() {
  local ns="$1"
  local rows
  rows="$(kubectl_cmd -n "$ns" get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.readyReplicas}{"\t"}{.spec.replicas}{"\n"}{end}' 2>/dev/null || true)"
  [[ -z "$rows" ]] && return

  while IFS=$'\t' read -r name ready desired; do
    [[ -z "$name" ]] && continue
    ready="${ready:-0}"
    desired="${desired:-0}"
    if [[ "$desired" == "0" ]]; then
      log_warn "Deployment has 0 replicas: $ns/$name"
    elif [[ "$ready" == "$desired" ]]; then
      log_pass "Deployment ready: $ns/$name ($ready/$desired)"
    else
      log_fail "Deployment not ready: $ns/$name ($ready/$desired)"
    fi
  done <<< "$rows"
}

check_statefulsets_in_namespace() {
  local ns="$1"
  local rows
  rows="$(kubectl_cmd -n "$ns" get statefulset -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.readyReplicas}{"\t"}{.spec.replicas}{"\n"}{end}' 2>/dev/null || true)"
  [[ -z "$rows" ]] && return

  while IFS=$'\t' read -r name ready desired; do
    [[ -z "$name" ]] && continue
    ready="${ready:-0}"
    desired="${desired:-0}"
    if [[ "$desired" == "0" ]]; then
      log_warn "StatefulSet has 0 replicas: $ns/$name"
    elif [[ "$ready" == "$desired" ]]; then
      log_pass "StatefulSet ready: $ns/$name ($ready/$desired)"
    else
      log_fail "StatefulSet not ready: $ns/$name ($ready/$desired)"
    fi
  done <<< "$rows"
}

check_daemonsets_in_namespace() {
  local ns="$1"
  local rows
  rows="$(kubectl_cmd -n "$ns" get daemonset -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.numberReady}{"\t"}{.status.desiredNumberScheduled}{"\n"}{end}' 2>/dev/null || true)"
  [[ -z "$rows" ]] && return

  while IFS=$'\t' read -r name ready desired; do
    [[ -z "$name" ]] && continue
    ready="${ready:-0}"
    desired="${desired:-0}"
    if [[ "$desired" == "0" ]]; then
      log_warn "DaemonSet has 0 desired pods: $ns/$name"
    elif [[ "$ready" == "$desired" ]]; then
      log_pass "DaemonSet ready: $ns/$name ($ready/$desired)"
    else
      log_fail "DaemonSet not ready: $ns/$name ($ready/$desired)"
    fi
  done <<< "$rows"
}

check_required_namespace_workloads() {
  while IFS= read -r ns; do
    check_deployments_in_namespace "$ns"
    check_statefulsets_in_namespace "$ns"
    check_daemonsets_in_namespace "$ns"
  done < <(csv_to_lines "$REQUIRED_NAMESPACES_CSV")
}

check_argo_applications() {
  if [[ "$CHECK_ARGO_APPS" != "1" ]]; then
    log_info "Skipping Argo CD Application checks"
    return
  fi

  if ! kubectl_cmd -n argocd get applications.argoproj.io >/dev/null 2>&1; then
    log_warn "Argo CD Application CRD not available; skipping app checks"
    return
  fi

  local rows
  rows="$(kubectl_cmd -n argocd get applications.argoproj.io -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.sync.status}{"\t"}{.status.health.status}{"\n"}{end}' 2>/dev/null || true)"
  if [[ -z "$rows" ]]; then
    log_warn "No Argo CD applications found in argocd namespace"
    return
  fi

  while IFS=$'\t' read -r name sync health; do
    [[ -z "$name" ]] && continue
    sync="${sync:-Unknown}"
    health="${health:-Unknown}"
    if [[ "$sync" == "Synced" && "$health" == "Healthy" ]]; then
      log_pass "Argo app healthy/synced: $name"
    else
      log_fail "Argo app not healthy/synced: $name (sync=$sync health=$health)"
    fi
  done <<< "$rows"
}

check_external_secrets_health() {
  if ! kubectl_cmd get crd externalsecrets.external-secrets.io >/dev/null 2>&1; then
    log_warn "ExternalSecret CRD not present; skipping External Secrets checks"
    return
  fi

  local stores
  stores="$(kubectl_cmd get secretstore -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}' 2>/dev/null || true)"
  if [[ -n "$stores" ]]; then
    while IFS=$'\t' read -r ns name ready; do
      [[ -z "$name" ]] && continue
      if [[ "$ready" == "True" ]]; then
        log_pass "SecretStore ready: $ns/$name"
      else
        log_fail "SecretStore not ready: $ns/$name (Ready=${ready:-Unknown})"
      fi
    done <<< "$stores"
  else
    log_warn "No SecretStore resources found"
  fi

  local exts
  exts="$(kubectl_cmd get externalsecret -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}' 2>/dev/null || true)"
  if [[ -n "$exts" ]]; then
    while IFS=$'\t' read -r ns name ready; do
      [[ -z "$name" ]] && continue
      if [[ "$ready" == "True" ]]; then
        log_pass "ExternalSecret ready: $ns/$name"
      else
        log_fail "ExternalSecret not ready: $ns/$name (Ready=${ready:-Unknown})"
      fi
    done <<< "$exts"
  else
    log_warn "No ExternalSecret resources found"
  fi
}

check_vault_unsealed() {
  if ! kubectl_cmd get namespace vault >/dev/null 2>&1; then
    log_warn "Vault namespace missing; skipping Vault seal checks"
    return
  fi

  local pods
  pods="$(kubectl_cmd -n vault get pod -l app.kubernetes.io/name=vault,component=server -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
  if [[ -z "$pods" ]]; then
    log_fail "No Vault server pods found in vault namespace"
    return
  fi

  while IFS= read -r pod; do
    [[ -z "$pod" ]] && continue
    local status
    status="$(kubectl_cmd -n vault exec "$pod" -- vault status 2>/dev/null || true)"
    if [[ -z "$status" ]]; then
      log_fail "Cannot execute 'vault status' in pod vault/$pod"
      continue
    fi

    if grep -qE '^Sealed[[:space:]]+false$' <<< "$status"; then
      log_pass "Vault unsealed: vault/$pod"
    else
      local sealed
      sealed="$(awk '$1 == "Sealed" {print $2}' <<< "$status" | tail -n 1)"
      log_fail "Vault sealed or unknown state: vault/$pod (Sealed=${sealed:-Unknown})"
    fi
  done <<< "$pods"
}

check_global_pod_health() {
  if [[ "$CHECK_GLOBAL_PODS" != "1" ]]; then
    log_info "Skipping global pod status sweep"
    return
  fi

  local rows
  rows="$(kubectl_cmd get pods -A --no-headers 2>/dev/null || true)"
  [[ -z "$rows" ]] && { log_fail "No pods returned by API"; return; }

  local bad=0
  while read -r ns name ready status restarts age _; do
    [[ -z "${ns:-}" ]] && continue
    local ready_now ready_total
    ready_now="${ready%/*}"
    ready_total="${ready#*/}"
    if [[ "$status" != "Running" && "$status" != "Completed" ]]; then
      log_fail "Pod unhealthy status: $ns/$name (status=$status ready=$ready restarts=$restarts age=$age)"
      bad=1
      continue
    fi
    if [[ "$status" == "Running" && "$ready_now" != "$ready_total" ]]; then
      log_fail "Pod not fully ready: $ns/$name (ready=$ready restarts=$restarts age=$age)"
      bad=1
    fi
  done <<< "$rows"

  if [[ "$bad" == "0" ]]; then
    log_pass "All pods are Running/Completed and fully ready"
  fi
}

short_sha() {
  local sha="$1"
  if [[ -z "$sha" ]]; then
    return 0
  fi
  echo "${sha:0:12}"
}

join_unique_words() {
  if [[ "$#" -eq 0 ]]; then
    return 0
  fi
  printf '%s\n' "$@" | awk 'NF && !seen[$0]++' | xargs
}

collect_nodes_for_version_checks() {
  local -a nodes=()
  if [[ -n "$EXPECTED_NODES_CSV" ]]; then
    while IFS= read -r node; do
      [[ -n "$node" ]] && nodes+=("$node")
    done < <(csv_to_lines "$EXPECTED_NODES_CSV")
  else
    nodes=("${DISCOVERED_NODES[@]}")
  fi

  if [[ "${#nodes[@]}" -eq 0 ]]; then
    return 0
  fi
  printf '%s\n' "${nodes[@]}"
}

check_node_versions() {
  if [[ "$CHECK_NODE_VERSIONS" != "1" ]]; then
    log_info "Skipping node code/drift checks"
    return
  fi

  local -a nodes=()
  while IFS= read -r node; do
    [[ -n "$node" ]] && nodes+=("$node")
  done < <(collect_nodes_for_version_checks)

  if [[ "${#nodes[@]}" -eq 0 ]]; then
    log_warn "No nodes available for node version checks"
    return
  fi

  if ! command -v "$SSH_BIN" >/dev/null 2>&1; then
    log_warn "ssh binary not found: $SSH_BIN (skipping node code/drift checks)"
    return
  fi

  if ! command -v "$NIX_BIN" >/dev/null 2>&1; then
    log_warn "nix binary not found: $NIX_BIN (skipping node code/drift checks)"
    return
  fi

  if [[ ! -f "$LOCAL_REPO_DIR/flake.nix" ]]; then
    log_warn "Local flake not found at $LOCAL_REPO_DIR (skipping node code/drift checks)"
    return
  fi

  local local_head=""
  if command -v "$GIT_BIN" >/dev/null 2>&1; then
    local_head="$("$GIT_BIN" -C "$LOCAL_REPO_DIR" rev-parse --verify HEAD 2>/dev/null || true)"
  else
    log_warn "git binary not found: $GIT_BIN (commit comparison skipped)"
  fi

  if [[ -n "$local_head" ]]; then
    log_info "Local repo HEAD: $(short_sha "$local_head")"
  else
    log_warn "Could not determine local git HEAD at $LOCAL_REPO_DIR"
  fi

  local flake_ref="$LOCAL_REPO_DIR"
  local -a pending_nodes=()
  local -a repo_mismatch_nodes=()
  local -a unknown_nodes=()

  for node in "${nodes[@]}"; do
    local desired_outpath
    if ! desired_outpath="$("$NIX_BIN" eval --raw "${flake_ref}#nixosConfigurations.${node}.config.system.build.toplevel.outPath" 2>/dev/null)"; then
      log_warn "Cannot evaluate local target system for node '$node'"
      unknown_nodes+=("$node")
      continue
    fi

    local remote_line
    if ! remote_line="$(
      "$SSH_BIN" \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" \
        "${SSH_USER}@${node}" \
        "bash -s -- '$REPO_DIR'" <<'EOF'
set -uo pipefail
repo_dir="$1"

running_path="$(readlink -f /run/current-system 2>/dev/null || true)"
repo_head=""
repo_dirty=""

if [[ -d "$repo_dir/.git" ]]; then
  cd "$repo_dir" || exit 0
  repo_head="$(git rev-parse --verify HEAD 2>/dev/null || true)"
  if [[ -n "$(git status --porcelain 2>/dev/null || true)" ]]; then
    repo_dirty="1"
  else
    repo_dirty="0"
  fi
fi

printf '%s\t%s\t%s\n' "$running_path" "$repo_head" "$repo_dirty"
EOF
    )"; then
      log_warn "Cannot query node '$node' over SSH as ${SSH_USER}"
      unknown_nodes+=("$node")
      continue
    fi

    local running_path repo_head repo_dirty
    IFS=$'\t' read -r running_path repo_head repo_dirty <<< "$remote_line"

    if [[ -z "$running_path" ]]; then
      log_warn "Node '$node' did not return a running system path"
      unknown_nodes+=("$node")
      continue
    fi

    local node_has_pending=0
    if [[ "$running_path" == "$desired_outpath" ]]; then
      log_pass "Node running latest local config: $node"
    else
      log_warn "Node would change on rebuild: $node"
      pending_nodes+=("$node")
      node_has_pending=1
    fi

    if [[ -n "$local_head" && -n "$repo_head" && "$repo_head" != "$local_head" ]]; then
      repo_mismatch_nodes+=("$node")
      if [[ "$node_has_pending" == "1" ]]; then
        log_warn "Node repo commit differs from local HEAD: $node (node=$(short_sha "$repo_head"), local=$(short_sha "$local_head"))"
      else
        log_info "Node repo commit differs from local HEAD but no config drift: $node (node=$(short_sha "$repo_head"), local=$(short_sha "$local_head"))"
      fi
    elif [[ -z "$repo_head" ]]; then
      log_warn "Node repo not found or unreadable at $node:$REPO_DIR"
      unknown_nodes+=("$node")
    fi

    if [[ "$repo_dirty" == "1" ]]; then
      log_warn "Node repo has local changes: $node:$REPO_DIR"
    fi
  done

  if [[ "${#pending_nodes[@]}" -gt 0 ]]; then
    log_warn "Nodes with pending infra changes: $(join_unique_words "${pending_nodes[@]}")"
  else
    log_pass "No pending infra changes on nodes against local code"
  fi

  if [[ "${#repo_mismatch_nodes[@]}" -gt 0 ]]; then
    log_info "Nodes on a different repo commit: $(join_unique_words "${repo_mismatch_nodes[@]}")"
  fi

  if [[ "${#unknown_nodes[@]}" -gt 0 ]]; then
    log_warn "Node version checks incomplete for: $(join_unique_words "${unknown_nodes[@]}")"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubectl-bin)
      KUBECTL_BIN="${2:-}"
      [[ -n "$KUBECTL_BIN" ]] || { echo "error: --kubectl-bin requires a value" >&2; exit 2; }
      shift 2
      ;;
    --request-timeout)
      REQUEST_TIMEOUT="${2:-}"
      [[ -n "$REQUEST_TIMEOUT" ]] || { echo "error: --request-timeout requires a value" >&2; exit 2; }
      shift 2
      ;;
    --required-namespaces)
      REQUIRED_NAMESPACES_CSV="${2:-}"
      [[ -n "$REQUIRED_NAMESPACES_CSV" ]] || { echo "error: --required-namespaces requires a value" >&2; exit 2; }
      shift 2
      ;;
    --required-storage-classes)
      REQUIRED_STORAGE_CLASSES_CSV="${2:-}"
      [[ -n "$REQUIRED_STORAGE_CLASSES_CSV" ]] || { echo "error: --required-storage-classes requires a value" >&2; exit 2; }
      shift 2
      ;;
    --expected-nodes)
      EXPECTED_NODES_CSV="${2:-}"
      [[ -n "$EXPECTED_NODES_CSV" ]] || { echo "error: --expected-nodes requires a value" >&2; exit 2; }
      shift 2
      ;;
    --no-argo-app-check)
      CHECK_ARGO_APPS=0
      shift
      ;;
    --no-global-pod-check)
      CHECK_GLOBAL_PODS=0
      shift
      ;;
    --no-node-version-check)
      CHECK_NODE_VERSIONS=0
      shift
      ;;
    --ssh-user)
      old_default_repo_dir="/home/${SSH_USER}/repositories/k8nix-infra"
      SSH_USER="${2:-}"
      [[ -n "$SSH_USER" ]] || { echo "error: --ssh-user requires a value" >&2; exit 2; }
      if [[ "$REPO_DIR" == "$old_default_repo_dir" ]]; then
        REPO_DIR="/home/${SSH_USER}/repositories/k8nix-infra"
      fi
      shift 2
      ;;
    --repo-dir)
      REPO_DIR="${2:-}"
      [[ -n "$REPO_DIR" ]] || { echo "error: --repo-dir requires a value" >&2; exit 2; }
      shift 2
      ;;
    --local-repo-dir)
      LOCAL_REPO_DIR="${2:-}"
      [[ -n "$LOCAL_REPO_DIR" ]] || { echo "error: --local-repo-dir requires a value" >&2; exit 2; }
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! command -v "$KUBECTL_BIN" >/dev/null 2>&1; then
  echo "error: kubectl binary not found: $KUBECTL_BIN" >&2
  exit 127
fi

log_info "Checking infrastructure health..."
log_info "kubectl: $KUBECTL_BIN (timeout: $REQUEST_TIMEOUT)"
if [[ "$CHECK_NODE_VERSIONS" == "1" ]]; then
  log_info "node version check: enabled (ssh user: $SSH_USER, remote repo: $REPO_DIR, local repo: $LOCAL_REPO_DIR)"
else
  log_info "node version check: disabled"
fi

if ! kubectl_cmd version >/dev/null 2>&1; then
  echo "${C_FAIL}[FAIL]${C_RESET} Unable to contact Kubernetes API with kubectl" >&2
  exit 1
fi
log_pass "Kubernetes API is reachable"

check_nodes
check_namespaces
check_storage_classes
check_required_namespace_workloads
check_argo_applications
check_external_secrets_health
check_vault_unsealed
check_global_pod_health
check_node_versions

echo
if [[ "${#WARNINGS[@]}" -gt 0 ]]; then
  echo "${C_WARN}Warnings:${C_RESET} ${#WARNINGS[@]}"
fi

if [[ "${#FAILURES[@]}" -gt 0 ]]; then
  echo "${C_FAIL}Failures:${C_RESET} ${#FAILURES[@]}"
  exit 1
fi

echo "${C_PASS}All infrastructure checks passed.${C_RESET}"
