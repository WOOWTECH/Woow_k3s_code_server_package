#!/usr/bin/env bash
# Sync this mirror from the Gitea source of truth.
#
# This repository is a read-only MIRROR of the WOOW PaaS code-server cloud
# service. The authoritative copy lives on the internal Gitea
# (git-prod.woowtech.io); edits made here are overwritten by the next sync.
#
#   chart/    <- woow-paas/woow-paas-charts  charts/code-server/
#   image/    <- woow-paas/paas-odoo-ci      code-server/   (Dockerfile + README)
#
# The image is a thin PaaS layer on the WOOWTECH podman image; it is built and
# published by paas-odoo-ci (candidate tag -> prod approval -> promote), never
# from here. The platform's pinned image reference is not in the chart defaults
# (the platform always overrides image.tag), so MIRROR.md records the base
# image digest from image/Dockerfile and the chart version.
#
# Usage:  scripts/sync-from-gitea.sh [woow-paas-charts-ref] [paas-odoo-ci-ref]   (default "main" "main")
#
# Needs git read access to both Gitea repos (e.g. a credential helper for
# https://git-prod.woowtech.io). Writes the resolved commits into MIRROR.md so
# every mirrored file can be traced back to the exact source revision.
set -Eeuo pipefail

GITEA="${GITEA_URL:-https://git-prod.woowtech.io}"
CHARTS_REF="${1:-main}"
CI_REF="${2:-main}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fetch() { # <dir> <repo> <ref>
    git init -q "$WORK/$1"
    git -C "$WORK/$1" fetch -q --depth 1 "$GITEA/$2.git" "$3"
    git -C "$WORK/$1" checkout -q FETCH_HEAD
    git -C "$WORK/$1" rev-parse HEAD
}
CHARTS_SHA="$(fetch charts woow-paas/woow-paas-charts "$CHARTS_REF")"
CI_SHA="$(fetch ci woow-paas/paas-odoo-ci "$CI_REF")"

copy() { # <src dir> <dest dir>
    [ -d "$1" ] || { echo "missing source directory: $1" >&2; exit 1; }
    rm -rf "$2"
    mkdir -p "$2"
    cp -a "$1/." "$2/"
}
copy "$WORK/charts/charts/code-server" "$ROOT/chart"
copy "$WORK/ci/code-server" "$ROOT/image"

CHART_VERSION="$(sed -n 's/^version: *//p' "$ROOT/chart/Chart.yaml")"
APP_VERSION="$(sed -n 's/^appVersion: *"\{0,1\}\([^"]*\)"\{0,1\}/\1/p' "$ROOT/chart/Chart.yaml")"

# Rewrite only the generated block of MIRROR.md; the prose around it is kept.
python3 - "$ROOT/MIRROR.md" "$ROOT/image/Dockerfile" "$CHARTS_SHA" "$CI_SHA" "$CHART_VERSION" "$APP_VERSION" <<'PY'
import sys, re, datetime
path, dockerfile, charts, ci, chart_ver, app_ver = sys.argv[1:7]
df = open(dockerfile, encoding="utf-8").read()
base = re.search(r'^ARG BASE=(\S+)$', df, re.M).group(1)
block = (
    "<!-- BEGIN GENERATED: scripts/sync-from-gitea.sh -->\n"
    "| Mirror path | Source repository | Source path | Commit |\n"
    "|---|---|---|---|\n"
    f"| `chart/` | `woow-paas/woow-paas-charts` | `charts/code-server/` | `{charts}` |\n"
    f"| `image/` | `woow-paas/paas-odoo-ci` | `code-server/` | `{ci}` |\n"
    "\n"
    f"Base image (podman package, consumed by digest): `{base}`\n"
    "\n"
    f"Chart `{chart_ver}` / appVersion `{app_ver}` — synced "
    f"{datetime.datetime.now(datetime.timezone.utc):%Y-%m-%d %H:%M} UTC.\n"
    "<!-- END GENERATED -->"
)
text = open(path, encoding="utf-8").read()
new, n = re.subn(r"<!-- BEGIN GENERATED.*?<!-- END GENERATED -->", block, text, flags=re.S)
if n != 1:
    sys.exit("MIRROR.md is missing its generated block markers")
open(path, "w", encoding="utf-8").write(new)
PY

echo "synced: woow-paas-charts@${CHARTS_SHA:0:8} paas-odoo-ci@${CI_SHA:0:8}  chart ${CHART_VERSION} / ${APP_VERSION}"
