#!/usr/bin/env bash
# Re-render deploy/rendered/code-server-woow.yaml from the chart + the live
# instance values, with a PLACEHOLDER tunnel ID.
#
# The file is a review aid: it is what the live release looks like in one page,
# and CI fails if it is stale. It is NOT applyable — the tunnel ID is a
# placeholder, and the live release is managed by Helm, not kubectl apply.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${REPO_DIR}/deploy/rendered/code-server-woow.yaml"
PLACEHOLDER_TUNNEL="00000000-0000-0000-0000-000000000000"

mkdir -p "$(dirname "${OUT}")"
helm template code-server "${REPO_DIR}/charts/code-server" \
    --namespace code-server \
    -f "${REPO_DIR}/values/woow-k3s/code-server.yaml" \
    --set cloudflare.tunnelId="${PLACEHOLDER_TUNNEL}" \
    > "${OUT}"
echo "wrote ${OUT}"
