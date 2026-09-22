#!/usr/bin/env bash
#
# Applies the manifests of every application listed in apps/registry.conf that
# is not already running in the cluster.
#
# The configuration is never copied into this repo: each entry names a kustomize
# target inside the project's own repository, and kubectl fetches it directly.
# An app whose marker resource already exists is skipped untouched -- its own
# CI owns the running version from then on, and re-applying from here would
# revert the image tag it deployed.
#
#   ./apps/sync.sh                 # bootstrap what is missing
#   ./apps/sync.sh --dry-run       # say what would be applied, change nothing
#   ./apps/sync.sh --force cooknco # re-apply named apps even if running
#   ./apps/sync.sh cooknco padel-manager
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY="${REGISTRY:-${SCRIPT_DIR}/registry.conf}"

DRY_RUN=false
FORCE=false
SELECTED=()

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    --force)   FORCE=true ;;
    -h|--help)
      # The header comment is the help text; print it up to the first line of
      # actual code so the two cannot drift apart.
      sed -e '1d' -e '/^[^#]/q' "${BASH_SOURCE[0]}" \
        | sed -e '/^[^#]/d' -e 's/^#//' -e 's/^ //'
      exit 0
      ;;
    -*) echo "error: unknown flag $1" >&2; exit 2 ;;
    *)  SELECTED+=("$1") ;;
  esac
  shift
done

# Colour only on a terminal: CI pipes this into a log and a step summary, where
# raw escapes are just noise.
if [ -t 1 ]; then
  C_BLUE=$'\033[1;34m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'
  C_OFF=$'\033[0m'
else
  C_BLUE=''; C_GREEN=''; C_YELLOW=''; C_OFF=''
fi

log()  { printf '\n%s==>%s %s\n' "$C_BLUE" "$C_OFF" "$*"; }
skip() { printf '    %s%s%s %s\n' "$C_GREEN" 'running' "$C_OFF" "$*"; }
warn() { printf '    %s%s%s %s\n' "$C_YELLOW" 'warning' "$C_OFF" "$*"; }

command -v kubectl >/dev/null || { echo 'error: kubectl not found in PATH' >&2; exit 1; }
[ -r "$REGISTRY" ] || { echo "error: cannot read $REGISTRY" >&2; exit 1; }

# --force is a per-app override, not a cluster-wide one: `--force` alone would
# re-apply every project and roll all their images back at once.
if [ "$FORCE" = true ] && [ ${#SELECTED[@]} -eq 0 ]; then
  echo 'error: --force requires at least one app name' >&2
  exit 2
fi

log "Target cluster: $(kubectl config current-context)"
kubectl cluster-info >/dev/null

# Every "${arr[@]}" below is guarded by an element-count test first: expanding an
# empty array is an unbound-variable error under `set -u` in bash 3.2, which is
# what macOS still ships.
wanted() {
  [ ${#SELECTED[@]} -eq 0 ] && return 0
  local candidate
  for candidate in "${SELECTED[@]}"; do
    [ "$candidate" = "$1" ] && return 0
  done
  return 1
}

declare -a matched=() applied=() failed=()

# The registry is read on fd 3, not stdin: kubectl inherits stdin and would
# otherwise be free to consume the rest of the file mid-loop.
while read -r name namespace marker url _rest <&3; do
  # Skip blank lines and comments.
  [ -z "${name:-}" ] && continue
  case "$name" in \#*) continue ;; esac

  if [ -z "${namespace:-}" ] || [ -z "${marker:-}" ] || [ -z "${url:-}" ]; then
    echo "error: malformed registry entry: $name" >&2
    exit 1
  fi

  wanted "$name" || continue
  matched+=("$name")

  log "$name"

  if [ "$FORCE" = true ]; then
    printf '    forcing re-apply (marker %s in %s not checked)\n' "$marker" "$namespace"
  elif kubectl get "$marker" -n "$namespace" >/dev/null 2>&1; then
    skip "$marker exists in namespace $namespace"
    continue
  else
    printf '    %s absent from namespace %s, applying\n' "$marker" "$namespace"
  fi

  printf '    source: %s\n' "$url"

  if [ "$DRY_RUN" = true ]; then
    # Renders through the same code path as the real apply, so a broken URL or
    # an unparseable overlay fails here rather than at deploy time. Server-side
    # dry-run would need the namespace to exist already, which for a first
    # bootstrap it does not.
    if kubectl kustomize "$url" >/dev/null; then
      printf '    would apply (rendered clean)\n'
      applied+=("$name")
    else
      warn "could not render $url"
      failed+=("$name")
    fi
    continue
  fi

  # No --prune and no --force-conflicts: this only ever creates what is missing.
  # A field managed by the project's own CI must lose to that CI, not to us.
  if kubectl apply -k "$url" --server-side --field-manager=kubeconfig-apps-sync; then
    applied+=("$name")
  else
    warn "apply failed for $name"
    failed+=("$name")
  fi
done 3< "$REGISTRY"

# An unmatched name on the command line is a typo, not an empty result.
if [ ${#SELECTED[@]} -gt 0 ]; then
  for candidate in "${SELECTED[@]}"; do
    found=false
    if [ ${#matched[@]} -gt 0 ]; then
      for name in "${matched[@]}"; do
        [ "$candidate" = "$name" ] && found=true && break
      done
    fi
    if [ "$found" = false ]; then
      echo "error: no registry entry named '$candidate'" >&2
      exit 1
    fi
  done
fi

log 'Summary'
if [ "$DRY_RUN" = true ]; then
  printf '    would apply: %s\n' "${applied[*]:-none}"
else
  printf '    applied: %s\n' "${applied[*]:-none}"
fi
if [ ${#failed[@]} -gt 0 ]; then
  printf '    failed:  %s\n' "${failed[*]}"
  exit 1
fi
