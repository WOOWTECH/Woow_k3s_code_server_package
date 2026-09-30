#!/usr/bin/env bash
# code-server render contract: code-server itself is the single exposed port (no
# auth-proxy — its own password login); PASSWORD comes from the chart Secret
# (platform pin / existingSecret / lookup-once); a password change never changes
# the pod template (helm_secret reset path); optional keys are optional env from
# the Secret and restart the pod via a checksum; pi + Claude Code wiring
# (contract 1.1); --trusted-origins takes the HOST of the public URL; internet-
# only egress by default; non-root; RWO+Recreate; release-prefixed names.
set -euo pipefail
CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; HELM="${HELM_BINARY:-helm}"
command -v yq >/dev/null 2>&1 || { echo "SKIP (render-contract): yq (mikefarah) required"; exit 0; }
fail() { echo "FAIL (render-contract): $1"; exit 1; }
OUT="$($HELM template svc-aaaa1111 "$CHART_DIR" -n SENTINEL)"
DEP="$(printf '%s' "$OUT" | yq 'select(.kind=="Deployment")')"
C="$(printf '%s' "$DEP" | yq '.spec.template.spec.containers[] | select(.name=="code-server")')"
env_of() { printf '%s' "$C" | yq ".env[] | select(.name==\"$1\") | $2"; }

# entrance: exactly one ClusterIP Service :8080, un-suffixed fullname; one container
[ "$(printf '%s' "$OUT" | yq -N 'select(.kind=="Service") | .metadata.name' | wc -l)" = "1" ] || fail "expected exactly one Service"
[ "$(printf '%s' "$OUT" | yq -N 'select(.kind=="Service") | .metadata.name')" = "svc-aaaa1111-code-server" ] || fail "entrance Service must be the un-suffixed fullname"
[ "$(printf '%s' "$OUT" | yq -N 'select(.kind=="Service") | .spec.type')" = "ClusterIP" ] || fail "Service is not ClusterIP"
[ "$(printf '%s' "$OUT" | yq -N 'select(.kind=="Service") | .spec.ports[0].targetPort')" = "8080" ] || fail "Service targetPort != 8080"
[ "$(printf '%s' "$DEP" | yq '.spec.template.spec.containers | length')" = "1" ] || fail "one container only (no auth-proxy sidecar)"
printf '%s' "$OUT" | grep -qiE 'cloudflared|nginx|CronJob' && fail "cloudflared / nginx / backup CronJob must not be rendered"

# password: from the chart Secret, pin / existingSecret / self-generated
[ "$(env_of PASSWORD .valueFrom.secretKeyRef.key)" = "admin_password" ] || fail "PASSWORD must come from Secret key admin_password"
SEC="$(printf '%s' "$OUT" | yq -N 'select(.kind=="Secret") | .stringData.admin_password')"
[ ${#SEC} -ge 20 ] || fail "self-generated admin_password too short"
PIN="$($HELM template t "$CHART_DIR" --set-string config.sensitive.admin_password=pinned-by-platform | yq -N 'select(.kind=="Secret") | .stringData.admin_password')"
[ "$PIN" = "pinned-by-platform" ] || fail "platform-pinned admin_password not honoured"
$HELM template t "$CHART_DIR" --set auth.existingSecret=ext | yq -N 'select(.kind=="Secret") | .metadata.name' | grep -q . && fail "chart Secret rendered despite auth.existingSecret"
[ "$($HELM template t "$CHART_DIR" --set auth.existingSecret=ext | yq 'select(.kind=="Deployment") | .spec.template.spec.containers[0].env[] | select(.name=="PASSWORD") | .valueFrom.secretKeyRef.name')" = "ext" ] || fail "existingSecret not wired into PASSWORD"
# a password reset must not change the pod template (reset = helm upgrade --atomic + restart)
T1="$($HELM template t "$CHART_DIR" --set-string config.sensitive.admin_password=first-password-1 | yq 'select(.kind=="Deployment") | .spec.template')"
T2="$($HELM template t "$CHART_DIR" --set-string config.sensitive.admin_password=second-password-2 | yq 'select(.kind=="Deployment") | .spec.template')"
[ "$T1" = "$T2" ] || fail "changing admin_password changed the pod template"

# optional keys: optional env from the Secret; a change restarts the pod via checksum
for k in ANTHROPIC_API_KEY:anthropic_api_key OPENROUTER_API_KEY:openrouter_api_key GIT_TOKEN:git_token; do
  n=${k%%:*}; key=${k#*:}
  [ "$(env_of "$n" .valueFrom.secretKeyRef.key)" = "$key" ] || fail "$n must come from Secret key $key"
  [ "$(env_of "$n" .valueFrom.secretKeyRef.optional)" = "true" ] || fail "$n must be optional (unset when empty)"
done
printf '%s' "$OUT" | yq -N 'select(.kind=="Secret") | .stringData | keys | .[]' | grep -qE 'anthropic|openrouter|git_token' && fail "empty optional keys must not be written to the Secret"
A0="$(printf '%s' "$DEP" | yq '.spec.template.metadata.annotations["checksum/optional-auth"]')"
A1="$($HELM template t "$CHART_DIR" --set auth.anthropicApiKey=sk-x | yq 'select(.kind=="Deployment") | .spec.template.metadata.annotations["checksum/optional-auth"]')"
[ "$A0" != "$A1" ] || fail "changing an optional key must change checksum/optional-auth"
OR="$($HELM template t "$CHART_DIR" --set auth.openrouterApiKey=or-x | yq 'select(.kind=="Deployment") | .spec.template.spec.containers[0].env[] | select(.name=="ANTHROPIC_BASE_URL") | .value')"
[ "$OR" = "https://openrouter.ai/api" ] || fail "OpenRouter key alone must route Claude Code through OpenRouter"
$HELM template t "$CHART_DIR" --set auth.openrouterApiKey=or-x --set auth.anthropicApiKey=sk-x | yq 'select(.kind=="Deployment") | .spec.template.spec.containers[0].env[] | select(.name=="ANTHROPIC_BASE_URL") | .name' | grep -q . && fail "an Anthropic key must win over the OpenRouter route"

# pi + Claude Code (PARITY_CONTRACT 1.1)
[ "$(env_of CLAUDE_CONFIG_DIR .value)" = "/data/pi-agent/claude" ] || fail "CLAUDE_CONFIG_DIR must be /data/pi-agent/claude"
[ "$(env_of DISABLE_AUTOUPDATER .value)" = "1" ] || fail "DISABLE_AUTOUPDATER must be 1"
[ "$(env_of PI_CODING_AGENT_DIR .value)" = "/data/pi-agent" ] || fail "PI_CODING_AGENT_DIR must be /data/pi-agent"
SET="$(printf '%s' "$OUT" | yq -N 'select(.kind=="ConfigMap") | .data["settings.json"]')"
[ "$(printf '%s' "$SET" | yq -p json '.["acp.agents"] | keys | sort | join(",")')" = "claude,pi" ] || fail "settings must configure exactly the pi and claude agents"
[ "$(printf '%s' "$SET" | yq -p json '.["acp.agents"].claude.command')" = "claude-agent-acp" ] || fail "claude agent must run claude-agent-acp"
[ "$(printf '%s' "$SET" | yq -p json '.["security.workspace.trust.enabled"]')" = "false" ] || fail "workspace trust must be off (ACP sidebar)"
printf '%s' "$DEP" | yq '.spec.template.spec.initContainers[] | select(.name=="pi-seed") | .args[0]' | grep -q "jq -S -s '.\[0\] \* .\[1\]'" || fail "pi-seed must merge required settings into the existing settings.json"
printf '%s' "$C" | yq '.volumeMounts[] | select(.mountPath=="/home/coder/.local/share/code-server/extensions") | .subPath' | grep -qx extensions || fail "runtime extensions must persist on the pi volume"

# public URL → --trusted-origins <host>; locale
ARGS="$($HELM template t "$CHART_DIR" --set codeServer.publicUrl=https://paas-cs-x.woowtech.io | yq 'select(.kind=="Deployment") | .spec.template.spec.containers[0].args | join(" ")')"
printf '%s' "$ARGS" | grep -q -- '--trusted-origins paas-cs-x.woowtech.io' || fail "trusted origin must be the host of publicUrl ('$ARGS')"
printf '%s' "$ARGS" | grep -q -- '--locale zh-tw' || fail "default locale zh-tw not passed"
$HELM template t "$CHART_DIR" --set codeServer.publicUrl=not-a-url >/dev/null 2>&1 && fail "publicUrl without a host must fail the render"

# network: default-deny + DNS + public internet only (+ same namespace)
EG="$(printf '%s' "$OUT" | yq -N 'select(.kind=="NetworkPolicy" and .metadata.name=="svc-aaaa1111-code-server-allow") | .spec.egress')"
printf '%s' "$EG" | yq '.[] | select(.to[0].ipBlock.cidr=="0.0.0.0/0") | .to[0].ipBlock.except[]' | grep -qx '10.0.0.0/8' || fail "egress must exclude private networks"
printf '%s' "$EG" | yq '.[] | select(. == {})' | grep -q . && fail "allowAllEgress must default to false"

# hardening / storage / names
[ "$(printf '%s' "$DEP" | yq '.spec.template.spec.securityContext.runAsNonRoot')" = "true" ] || fail "runAsNonRoot missing"
[ "$(printf '%s' "$DEP" | yq '.spec.template.spec.automountServiceAccountToken')" = "false" ] || fail "SA token must not be mounted"
[ "$(printf '%s' "$DEP" | yq '.spec.strategy.type')" = "Recreate" ] || fail "strategy must be Recreate (RWO PVCs)"
[ "$(printf '%s' "$OUT" | yq -N 'select(.kind=="PersistentVolumeClaim") | .metadata.name' | sort | tr '\n' ' ')" = "svc-aaaa1111-code-server-pi-data svc-aaaa1111-code-server-workspace " ] || fail "expected the workspace and pi-data PVCs"
printf '%s' "$C" | yq '.resources.limits.cpu' | grep -q . || fail "code-server lacks limits (ResourceQuota)"
printf '%s' "$DEP" | yq '.spec.template.spec.initContainers[0].resources.limits.cpu' | grep -q . || fail "pi-seed lacks limits (ResourceQuota)"
NS="$(printf '%s' "$OUT" | { grep -E '^  namespace:' || true; } | awk '{print $2}' | sort -u | tr '\n' ' ')"; [ -z "$NS" ] || [ "$NS" = "SENTINEL " ] || fail "hard-coded namespace: $NS"
A="$($HELM template svc-aaaa1111 "$CHART_DIR" -n X | yq -N '.kind + "/" + .metadata.name' | sort)"
B="$($HELM template svc-bbbb2222 "$CHART_DIR" -n X | yq -N '.kind + "/" + .metadata.name' | sort)"
[ -z "$(comm -12 <(printf '%s\n' "$A") <(printf '%s\n' "$B"))" ] || fail "two releases collide on object names"
echo "PASS (render-contract): code-server is the only port (own password), PASSWORD←Secret (pin/existing/lookup), reset keeps the pod template, optional keys + restart checksum + OpenRouter route, pi+claude wiring, trusted-origin host, internet-only egress, non-root, RWO+Recreate, limits, collision-free names."
