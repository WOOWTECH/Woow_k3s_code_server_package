#!/usr/bin/env bash
# code-server x shared omnigent-host kit (IN-CONTAINER mode, shared/omnigent-host/README.md):
#   * the vendored kit is byte-identical to shared/omnigent-host (sha256);
#   * the kit contract on the code-server container (env, read-only mounts, runtime
#     ConfigMap; launch through the image ENTRYPOINT stub, so no command override);
#   * omnigentHost.serverUrl never changes the pod template (no restart on injection);
#   * enabled=false leaves no trace except the telemetry env;
#   * this chart's per-service parameters (kit README table) and its guards.
set -u
CHART_DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(cd "$CHART_DIR/../.." && pwd)/shared/omnigent-host/chart/kit-test-lib.sh"
command -v yq >/dev/null 2>&1 || { echo "SKIP (omnigent-host-kit): yq (mikefarah) required"; exit 0; }
rc=0
ok() { printf '  ok   %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; rc=1; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

echo "── kit: vendored copy, in-container contract, runtime serverUrl, disabled"
kit_assert_vendored "$CHART_DIR" || rc=1
out=$(mktemp); off=$(mktemp)
helm template svc-c0de0101 "$CHART_DIR" >"$out"
kit_assert_in_container "$out" code-server image || rc=1
kit_assert_runtime_server_url "$CHART_DIR" || rc=1
helm template svc-c0de0101 "$CHART_DIR" --set omnigentHost.enabled=false >"$off"
kit_assert_disabled "$off" code-server || rc=1

echo "── code-server parameters (kit README: Per-service parameters)"
dep=$(mktemp)
yq 'select(.kind == "Deployment")' "$out" >"$dep"
C='.spec.template.spec.containers[] | select(.name == "code-server")'
e() { yq "$C | .env[] | select(.name == \"$1\") | .value" "$dep"; }
eq "OG_CONFIG_HOME = /data/pi-agent/omnigent (prod is logged in there)" "$(e OG_CONFIG_HOME)" /data/pi-agent/omnigent
eq "OG_DATA_DIR = OG_CONFIG_HOME" "$(e OG_DATA_DIR)" /data/pi-agent/omnigent
eq "OG_STATUS_FILE on the pi volume" "$(e OG_STATUS_FILE)" /data/pi-agent/omnigent/omnigent-host/status.json
eq "OG_WORKSPACE = /workspace" "$(e OG_WORKSPACE)" /workspace
eq "OG_HOST_NAME = code-server · <release>" "$(e OG_HOST_NAME)" "code-server · svc-c0de0101"
eq "OG_BIN = the image's pinned /usr/local/bin/omnigent (~/.local/bin is persistent)" "$(e OG_BIN)" /usr/local/bin/omnigent
eq "OG_PROVIDERS" "$(e OG_PROVIDERS)" claude-subscription,pi-original
eq "OG_UNSET_ENV: the IDE password never reaches the host" "$(e OG_UNSET_ENV)" PASSWORD,HASHED_PASSWORD,SUDO_PASSWORD
eq "no OG_HOME (HOME stays /home/coder)" "$(yq "[$C | .env[] | select(.name == \"OG_HOME\")] | length" "$dep")" 0
pt=",$(e OG_PASSTHROUGH),"
for v in PI_CODING_AGENT_DIR PI_AGENT_DATA_DIR PI_TELEMETRY PI_SKIP_VERSION_CHECK DISABLE_AUTOUPDATER OPENROUTER_API_KEY \
  ENABLE_CLAUDEAI_MCP_SERVERS GIT_CONFIG_GLOBAL NPM_CONFIG_PREFIX NPM_CONFIG_CACHE MAKEFLAGS UV_CONCURRENT_BUILDS; do
  case $pt in *",$v,"*) ok "sessions inherit $v (OG_PASSTHROUGH)" ;; *) bad "OG_PASSTHROUGH lacks $v ($pt)" ;; esac
done
case $pt in *",PASSWORD,"* | *",HASHED_PASSWORD,"*) bad "OG_PASSTHROUGH must not pass the IDE password" ;; *) ok "OG_PASSTHROUGH has no IDE password" ;; esac
eq "OG_HOST_ENABLED=1" "$(e OG_HOST_ENABLED)" 1
# 0.1.4 (#1458): + the cookie-proxy nginx (the entrance); still no omnigent-host sidecar
eq "containers = code-server + cookie-proxy (no omnigent-host sidecar)" "$(yq -o json -I0 '[.spec.template.spec.containers[].name]' "$dep")" '["code-server","cookie-proxy"]'
eq "no command override (image ENTRYPOINT runs omnigent-host-entry)" "$(yq "$C | .command" "$dep")" null
eq "status printer also at /usr/local/bin" "$(yq "$C | .volumeMounts[] | select(.mountPath == \"/usr/local/bin/omnigent-host-status\") | .subPath" "$dep")" omnigent-host-status
g=$(yq '.spec.template.spec.terminationGracePeriodSeconds' "$dep")
if [ "$g" -ge 30 ] 2>/dev/null; then ok "terminationGracePeriodSeconds $g >= 20 s (host stop) + code-server"; else bad "terminationGracePeriodSeconds $g too short for host stop + code-server"; fi
eq "fsGroupChangePolicy OnRootMismatch (0600 tokens survive remounts)" "$(yq '.spec.template.spec.securityContext.fsGroupChangePolicy' "$dep")" OnRootMismatch
eq "pod annotation checksum/omnigent-host present" "$(yq '.spec.template.metadata.annotations["checksum/omnigent-host"] | length' "$dep")" 64

echo "── values guards and overrides"
hn=$(helm template t "$CHART_DIR" --set-string 'omnigentHost.hostName=IDE 小明' | yq 'select(.kind == "Deployment")' | yq "$C | .env[] | select(.name == \"OG_HOST_NAME\") | .value")
eq "hostName override" "$hn" "IDE 小明"
ws=$(helm template t "$CHART_DIR" --set omnigentHost.workspace=/workspace/proj | yq 'select(.kind == "Deployment")' | yq "$C | .env[] | select(.name == \"OG_WORKSPACE\") | .value")
eq "workspace override" "$ws" /workspace/proj
for bad_set in omnigentHost.watchSeconds=10 omnigentHost.workspace=relative omnigentHost.serverUrl=ftp://x omnigentHost.serverUrl=http://u:p@x; do
  if helm template t "$CHART_DIR" --set "$bad_set" >/dev/null 2>&1; then bad "render must fail for $bad_set"; else ok "render fails for $bad_set"; fi
done
# a --reuse-values upgrade from 0.1.1 has no omnigentHost block: defaults (enabled)
rv=$(mktemp)
yq 'del(.omnigentHost)' "$CHART_DIR/values.yaml" >"$rv"
eq "values without omnigentHost (reuse-values from 0.1.1) render enabled" \
  "$(helm template t "$CHART_DIR" -f "$rv" | yq 'select(.kind == "Deployment")' | yq "$C | .env[] | select(.name == \"OG_HOST_ENABLED\") | .value")" 1
# disabled: telemetry env stays, the image stub then just execs code-server
de=$(yq 'select(.kind == "Deployment")' "$off")
for v in OMNIGENT_ANALYTICS=0 DO_NOT_TRACK=1 DISABLE_TELEMETRY=1; do
  eq "disabled keeps telemetry off: ${v%%=*}" "$(printf '%s' "$de" | yq "$C | .env[] | select(.name == \"${v%%=*}\") | .value")" "${v#*=}"
done
eq "disabled: no checksum/omnigent-host annotation" "$(printf '%s' "$de" | yq '.spec.template.metadata.annotations | has("checksum/omnigent-host")')" false
eq "disabled: same resources (full plan)" "$(printf '%s' "$de" | yq "$C | .resources.limits.cpu + \"/\" + .resources.limits.memory")" "2/4Gi"
rm -f "$out" "$off" "$dep" "$rv"
[ $rc -eq 0 ] && echo "PASS (omnigent-host-kit): code-server carries the in-container kit" || echo "FAIL (omnigent-host-kit)"
exit $rc
