#!/usr/bin/env bash
set -euo pipefail

SSH_USER="${SSH_USER:-admin}"
REPO_DIR="${REPO_DIR:-/home/${SSH_USER}/repositories/k8nix-infra}"
DEFAULT_NODES=(
  pi-master-1
  pi-worker-1
  pi-worker-2
  pi-worker-3
  pi-worker-4
  r630-storage
)

NO_PULL=0
DRY_RUN=0
BRANCH=""
DISCARD_LOCAL_CHANGES=0
NODES=()

usage() {
  cat <<'EOF'
Usage:
  scripts/rebuild-nodes.sh [options] [node...]

Options:
  --no-pull          Skip git pull on remote nodes
  --branch <name>    Pull this branch explicitly
  --discard-local-changes
                     Reset and clean remote repo before pull/rebuild
  -n, --dry-run      Print actions without executing
  -h, --help         Show this help

Environment:
  SSH_USER           SSH username (default: admin)
  REPO_DIR           Repo path on each node (default: /home/<SSH_USER>/repositories/k8nix-infra)

Examples:
  scripts/rebuild-nodes.sh
  scripts/rebuild-nodes.sh pi-worker-3 pi-worker-4
  SSH_USER=admin REPO_DIR='/home/admin/repositories/k8nix-infra' scripts/rebuild-nodes.sh --branch master
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-pull)
      NO_PULL=1
      shift
      ;;
    --branch)
      BRANCH="${2:-}"
      if [[ -z "$BRANCH" ]]; then
        echo "error: --branch requires a value" >&2
        exit 2
      fi
      shift 2
      ;;
    --discard-local-changes)
      DISCARD_LOCAL_CHANGES=1
      shift
      ;;
    -n|--dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do
        NODES+=("$1")
        shift
      done
      ;;
    -*)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      NODES+=("$1")
      shift
      ;;
  esac
done

if [[ ${#NODES[@]} -eq 0 ]]; then
  NODES=("${DEFAULT_NODES[@]}")
fi

REMOTE_SCRIPT='
set -euo pipefail
NODE_NAME="$1"
REPO_DIR="$2"
NO_PULL="$3"
BRANCH="$4"
DISCARD_LOCAL_CHANGES="$5"

cd "$REPO_DIR"

if [[ -n "$(git status --porcelain)" ]]; then
  if [[ "$DISCARD_LOCAL_CHANGES" == "1" ]]; then
    git reset --hard HEAD
    git clean -fd
  else
    echo "error: dirty git tree on ${NODE_NAME} at ${REPO_DIR}" >&2
    git status --short
    exit 20
  fi
fi

if [[ "$NO_PULL" != "1" ]]; then
  if [[ -n "$BRANCH" ]]; then
    git fetch origin "$BRANCH" --prune
    git checkout "$BRANCH"
    git pull --ff-only origin "$BRANCH"
  else
    git pull --ff-only
  fi
fi

sudo nixos-rebuild switch --flake ".#${NODE_NAME}"
'

for node in "${NODES[@]}"; do
  echo "==> ${node}"
  if [[ "$DRY_RUN" == "1" ]]; then
    preview_cmd="cd ${REPO_DIR}"
    if [[ "$DISCARD_LOCAL_CHANGES" == "1" ]]; then
      preview_cmd+=" && git reset --hard HEAD && git clean -fd"
    fi
    if [[ "$NO_PULL" != "1" ]]; then
      if [[ -n "$BRANCH" ]]; then
        preview_cmd+=" && git fetch origin ${BRANCH} --prune && git checkout ${BRANCH} && git pull --ff-only origin ${BRANCH}"
      else
        preview_cmd+=" && git pull --ff-only"
      fi
    fi
    preview_cmd+=" && sudo nixos-rebuild switch --flake .#${node}"
    echo "ssh ${SSH_USER}@${node} \"${preview_cmd}\""
    continue
  fi

  ssh -o BatchMode=yes -o StrictHostKeyChecking=no "${SSH_USER}@${node}" \
    "bash -s -- '$node' '$REPO_DIR' '$NO_PULL' '$BRANCH' '$DISCARD_LOCAL_CHANGES'" <<< "$REMOTE_SCRIPT"
done

echo "done"
