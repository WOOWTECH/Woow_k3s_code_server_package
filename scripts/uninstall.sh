#!/usr/bin/env bash
# Uninstall the code-server release. PVCs are KEPT by default (the chart sets
# helm.sh/resource-policy: keep on them while keepOnUninstall=true, and the
# Longhorn StorageClass reclaim policy is Retain), the Secrets created out of
# band are untouched, and the namespace is not a chart object either — pass
# --purge to delete the PVCs too, after a confirmation prompt.
set -euo pipefail

NAMESPACE="${NAMESPACE:-code-server}"
CONTEXT="${KUBECTL_CONTEXT:-woow-k3s}"
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

CURRENT_CONTEXT="$(kubectl config current-context)"
[ "${CURRENT_CONTEXT}" = "${CONTEXT}" ] || { echo "kubectl context is '${CURRENT_CONTEXT}', expected '${CONTEXT}'" >&2; exit 1; }

say "helm uninstall"
helm uninstall code-server --namespace "${NAMESPACE}"

if [ "${PURGE}" -eq 1 ]; then
    printf 'Delete code-server-pi-data, code-server-workspace, code-server-backup PVCs? This removes the pi login, all sessions, and the workspace. [y/N] '
    read -r ans
    if [ "${ans}" = "y" ] || [ "${ans}" = "Y" ]; then
        kubectl -n "${NAMESPACE}" delete pvc code-server-pi-data code-server-workspace code-server-backup --ignore-not-found
        say "PVCs deleted."
    else
        say "Skipped — PVCs kept."
    fi
else
    say "Done. The namespace, both Secrets and the PVCs were NOT deleted:"
    say "  kubectl -n ${NAMESPACE} delete pvc code-server-pi-data code-server-workspace code-server-backup"
fi
