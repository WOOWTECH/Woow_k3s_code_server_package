#!/usr/bin/env bash
# Container-specific policies must never propagate into the seed or cookie proxy.
set -Eeuo pipefail
CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELM="${HELM:-helm}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL (container-security-context): $*" >&2; exit 1; }
context() {
  yq -o=json -I=0 "select(.kind == \"Deployment\") | .spec.template.spec.$2[] | select(.name == \"$3\") | .securityContext" "$1"
}
for proxy in true false; do
  "$HELM" template test "$CHART_DIR" --set cookieProxy.enabled="$proxy" > "$WORK/base.yaml"
  "$HELM" template test "$CHART_DIR" --set cookieProxy.enabled="$proxy" \
    --set codeServer.securityContext.appArmorProfile.type=Localhost \
    --set codeServer.securityContext.appArmorProfile.localhostProfile=code-server-test \
    --set codeServer.securityContext.seccompProfile.type=Localhost \
    --set codeServer.securityContext.seccompProfile.localhostProfile=code-server-test/codex.json \
    > "$WORK/override.yaml"
  [ "$(context "$WORK/base.yaml" initContainers pi-seed)" = "$(context "$WORK/override.yaml" initContainers pi-seed)" ] || fail 'override changed pi-seed'
  [ "$(context "$WORK/base.yaml" containers cookie-proxy)" = "$(context "$WORK/override.yaml" containers cookie-proxy)" ] || fail 'override changed cookie proxy'
  actual="$(context "$WORK/override.yaml" containers code-server)"
  [ "$(printf '%s' "$actual" | yq '.allowPrivilegeEscalation')" = false ] || fail 'default NoNewPrivs lost'
  [ "$(printf '%s' "$actual" | yq '.capabilities.drop[0]')" = ALL ] || fail 'default capability drop lost'
  [ "$(printf '%s' "$actual" | yq '.appArmorProfile.localhostProfile')" = code-server-test ] || fail 'AppArmor override absent'
  [ "$(printf '%s' "$actual" | yq '.seccompProfile.localhostProfile')" = code-server-test/codex.json ] || fail 'seccomp override absent'
  [ "$(yq 'select(.kind == "Deployment") | .spec.template.spec.securityContext.seccompProfile.type' "$WORK/override.yaml")" = RuntimeDefault ] || fail 'pod policy changed'
  "$HELM" template test "$CHART_DIR" --set cookieProxy.enabled="$proxy" --set-json codeServer.securityContext=null > "$WORK/null.yaml"
  [ "$(context "$WORK/base.yaml" containers code-server)" = "$(context "$WORK/null.yaml" containers code-server)" ] || fail 'null override changed defaults'
done
echo 'PASS (container-security-context): scoped profiles, inherited hardening, unchanged init/proxy/pod contexts, default/null compatibility'
