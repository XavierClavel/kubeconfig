#!/usr/bin/env bash
#
# Materialises the KUBE_CONFIG repository secret as a kubeconfig file and
# exports KUBECONFIG for the remaining steps of the job.
#
# The secret may hold either the raw kubeconfig YAML or a base64 encoding of
# it -- `cat ~/.kube/config | base64 -w0` is the usual way people produce it,
# so both are accepted.
#
set -euo pipefail

: "${KUBE_CONFIG:?the KUBE_CONFIG secret is not set for this environment}"

target="${RUNNER_TEMP:-/tmp}/kubeconfig"
umask 077

if printf '%s' "$KUBE_CONFIG" | head -c 512 | grep -q 'apiVersion'; then
  printf '%s' "$KUBE_CONFIG" > "$target"
else
  printf '%s' "$KUBE_CONFIG" | base64 -d > "$target"
fi
chmod 600 "$target"

# Anything the decoded file contains is secret-derived: GitHub only masks the
# secret in its original encoding, so never cat this file.
if ! grep -q '^apiVersion:' "$target"; then
  echo "::error::KUBE_CONFIG is neither valid kubeconfig YAML nor base64 of it" >&2
  exit 1
fi

echo "KUBECONFIG=$target" >> "$GITHUB_ENV"
# GITHUB_ENV only affects *later* steps, so export it for the check below too.
export KUBECONFIG="$target"

if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "::error::cannot reach the cluster API server with the supplied kubeconfig." >&2
  echo "Check that the k3s API port is reachable from GitHub-hosted runners." >&2
  kubectl cluster-info 2>&1 | sed 's/^/  /' >&2 || true
  exit 1
fi
