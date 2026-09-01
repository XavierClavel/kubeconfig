#!/usr/bin/env bash
#
# Installs the operators the manifests in infrastructure/ depend on.
#
# Idempotent: every step is `helm upgrade --install`, so running it against an
# existing cluster reconciles it to the pinned versions rather than failing.
# Run it once on a fresh cluster before the first `kubectl apply -k .`; after
# that it only needs to run when bootstrap/ changes.
#
#   ./bootstrap/install.sh
#   KUBECONFIG=/path/to/new-vps.yaml ./bootstrap/install.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "${SCRIPT_DIR}/versions.env"

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }

for bin in helm kubectl; do
  command -v "$bin" >/dev/null || { echo "error: $bin not found in PATH" >&2; exit 1; }
done

log "Target cluster: $(kubectl config current-context)"
kubectl cluster-info >/dev/null

log "Adding Helm repositories"
helm repo add jetstack https://charts.jetstack.io --force-update
helm repo add strimzi https://strimzi.io/charts/ --force-update
helm repo update jetstack strimzi

log "cert-manager ${CERT_MANAGER_VERSION}"
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version "${CERT_MANAGER_VERSION}" \
  --values "${SCRIPT_DIR}/values/cert-manager.yaml" \
  --wait \
  --timeout 10m

log "Strimzi Kafka operator ${STRIMZI_VERSION}"
helm upgrade --install strimzi strimzi/strimzi-kafka-operator \
  --namespace kafka \
  --create-namespace \
  --version "${STRIMZI_VERSION}" \
  --values "${SCRIPT_DIR}/values/strimzi.yaml" \
  --wait \
  --timeout 10m

log "Waiting for CRDs to be established"
# Without this the first `kubectl apply -k .` on a brand new cluster can race
# the API server's discovery cache and fail on "no matches for kind".
kubectl wait --for=condition=Established --timeout=120s \
  crd/clusterissuers.cert-manager.io \
  crd/certificates.cert-manager.io \
  crd/kafkas.kafka.strimzi.io \
  crd/kafkanodepools.kafka.strimzi.io

log "Bootstrap complete. Next: kubectl apply -k ."
