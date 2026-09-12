#!/usr/bin/env bash
# Compare this repo with what is actually running. Exit 0 = in sync, 1 = drift.
#
#   1. repo vs release : helm template (this repo) <-> helm get manifest
#   2. repo vs release : the committed instance values <-> helm get values
#
# Read-only: it never installs, upgrades or applies anything.
#
#   CONTEXT=woow-k3s RELEASE=code-server NAMESPACE=code-server scripts/check-drift.sh
set -euo pipefail

CONTEXT="${KUBECTL_CONTEXT:-woow-k3s}"
RELEASE="${RELEASE:-code-server}"
NAMESPACE="${NAMESPACE:-code-server}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALUES="${VALUES:-${REPO_DIR}/values/woow-k3s/code-server.yaml}"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
rc=0

helm template "${RELEASE}" "${REPO_DIR}/charts/code-server" -n "${NAMESPACE}" \
    --skip-tests -f "${VALUES}" > "${tmp}/repo.yaml"
helm --kube-context "${CONTEXT}" get manifest "${RELEASE}" -n "${NAMESPACE}" > "${tmp}/release.yaml"

# -B: `helm get manifest` ends with a blank line `helm template` does not.
# -I '^ *#': YAML comments are not fields; the chart may reword one.
if diff -u -B -I '^ *#' "${tmp}/release.yaml" "${tmp}/repo.yaml" > "${tmp}/repo.diff"; then
    echo "1. repo == release ${RELEASE}"
else
    echo "1. DRIFT: this repo renders differently from release ${RELEASE}:"
    cat "${tmp}/repo.diff"
    rc=1
fi

helm --kube-context "${CONTEXT}" get values "${RELEASE}" -n "${NAMESPACE}" -o yaml > "${tmp}/release-values.yaml"
if python3 - "${tmp}/release-values.yaml" "${VALUES}" <<'PY'
import sys, yaml
def flat(d, p=""):
    out = {}
    for k, v in (d or {}).items():
        kp = f"{p}.{k}" if p else k
        out.update(flat(v, kp)) if isinstance(v, dict) else out.update({kp: v})
    return out
live, repo = flat(yaml.safe_load(open(sys.argv[1]))), flat(yaml.safe_load(open(sys.argv[2])))
bad = [f"  {k}: release={live.get(k)!r} repo={repo.get(k)!r}"
       for k in sorted(set(live) | set(repo))
       # auth.create was removed from the chart in the Helm-migration pass; the
       # release still carries the (false, therefore inert) key until the next
       # upgrade re-records its values.
       if k not in ("auth.create",) and live.get(k) != repo.get(k)]
print("\n".join(bad), file=sys.stderr) or sys.exit(1) if bad else None
PY
then
    echo "2. repo values == release values"
else
    echo "2. DRIFT: the committed instance values differ from the release's"
    rc=1
fi

exit "${rc}"
