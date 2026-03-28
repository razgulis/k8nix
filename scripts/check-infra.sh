#!/usr/bin/env bash
set -euo pipefail

KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-10s}"

REQUIRED_NAMESPACES_CSV="${REQUIRED_NAMESPACES_CSV:-argocd,ingress-nginx,metallb-system,openebs,external-secrets,vault,ai-data}"
REQUIRED_STORAGE_CLASSES_CSV="${REQUIRED_STORAGE_CLASSES_CSV:-zfs-reliable,zfs-ai-postgres,zfs-bulk,zfs-ai-minio}"
EXPECTED_NODES_CSV="${EXPECTED_NODES_CSV:-}"

CHECK_ARGO_APPS=1
CHECK_GLOBAL_PODS=1

FAILURES=()
WARNINGS=()

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
  -h, --help                        show this help

Environment equivalents:
  KUBECTL_BIN, REQUEST_TIMEOUT, REQUIRED_NAMESPACES_CSV,
  REQUIRED_STORAGE_CLASSES_CSV, EXPECTED_NODES_CSV

Examples:
  scripts/check-infra.sh
  scripts/check-infra.sh --expected-nodes pi-master-1,pi-worker-1,pi-worker-2,pi-worker-3,pi-worker-4,r630-storage
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

echo
if [[ "${#WARNINGS[@]}" -gt 0 ]]; then
  echo "${C_WARN}Warnings:${C_RESET} ${#WARNINGS[@]}"
fi

if [[ "${#FAILURES[@]}" -gt 0 ]]; then
  echo "${C_FAIL}Failures:${C_RESET} ${#FAILURES[@]}"
  exit 1
fi

echo "${C_PASS}All infrastructure checks passed.${C_RESET}"
