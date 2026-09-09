#!/usr/bin/env bash
# Install/upgrade the code-server chart on woow-k3s.
#
#   ./scripts/deploy.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${NAMESPACE:-code-server}"
CONTEXT="${KUBECTL_CONTEXT:-woow-k3s}"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mXX\033[0m %s\n' "$*" >&2; exit 1; }

CURRENT_CONTEXT="$(kubectl config current-context)"
[ "${CURRENT_CONTEXT}" = "${CONTEXT}" ] || die "kubectl context is '${CURRENT_CONTEXT}', expected '${CONTEXT}'. Run: kubectl config use-context ${CONTEXT}"

say "Checking namespace ${NAMESPACE}"
kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 \
    || die "namespace ${NAMESPACE} does not exist. See docs/DEPLOYMENT.md for the one-time bootstrap steps."

say "Checking required Secrets"
kubectl -n "${NAMESPACE}" get secret code-server-auth >/dev/null 2>&1 \
    || die "Secret code-server-auth not found. Create it: kubectl -n ${NAMESPACE} create secret generic code-server-auth --from-literal=PASSWORD='...'"
kubectl -n "${NAMESPACE}" get secret code-server-cf-creds >/dev/null 2>&1 \
    || die "Secret code-server-cf-creds not found. Create it from the Cloudflare tunnel's credentials.json — see docs/DEPLOYMENT.md."

say "Checking StorageClass"
STORAGECLASS="$(python3 -c "import yaml,sys; print(yaml.safe_load(open('${REPO_DIR}/values-woow.yaml'))['persistence']['storageClassName'])" 2>/dev/null || echo "")"
[ -n "${STORAGECLASS}" ] || die "persistence.storageClassName is empty in values-woow.yaml"
kubectl get storageclass "${STORAGECLASS}" >/dev/null 2>&1 \
    || die "StorageClass ${STORAGECLASS} not found on this cluster"

say "helm upgrade --install"
helm upgrade --install code-server "${REPO_DIR}/charts/code-server" \
    --namespace "${NAMESPACE}" \
    -f "${REPO_DIR}/values-woow.yaml" \
    --wait --timeout 5m

say "Waiting for rollout"
kubectl -n "${NAMESPACE}" rollout status deploy/code-server --timeout=300s

say "Running tests/smoke-*.sh (PARITY_TARGET=k3s)"
export PARITY_TARGET=k3s KUBECTL_CONTEXT="${CONTEXT}" K3S_NAMESPACE="${NAMESPACE}"
bash "${REPO_DIR}/tests/smoke-container.sh"
bash "${REPO_DIR}/tests/smoke-acp.sh"
bash "${REPO_DIR}/tests/smoke-pi-integration.sh"

say "Done."
say "  First run: kubectl --context ${CONTEXT} -n ${NAMESPACE} exec -it deploy/code-server -c code-server -- sh -lc 'pi login'"
