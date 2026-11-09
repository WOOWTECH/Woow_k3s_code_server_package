#!/usr/bin/env bash
# code-server render contract: code-server itself is the single exposed port (no
# auth-proxy — its own password login); PASSWORD comes from the chart Secret
# (platform pin / existingSecret / lookup-once); a password change never changes
# the pod template (helm_secret reset path); optional keys are optional env from
# the Secret and restart the pod via a checksum; pi + Claude Code wiring
# (contract 1.1); --trusted-origins takes the HOST of the public URL; internet-
# only egress by default; non-root; RWO+Recreate; release-prefixed names.
# 0.1.2: the IDE keeps the WHOLE plan (the Omnigent host runs inside it, no
# sidecar, no split); HOME state on the pi volume + size-limited ~/.cache;
# claude.ai connectors off; core.quotepath=false; build parallelism = CPU limit.
set -euo pipefail
CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; HELM="${HELM_BINARY:-helm}"
command -v yq >/dev/null 2>&1 || { echo "SKIP (render-contract): yq (mikefarah) required"; exit 0; }
fail() { echo "FAIL (render-contract): $1"; exit 1; }
OUT="$($HELM template svc-aaaa1111 "$CHART_DIR" -n SENTINEL)"
DEP="$(printf '%s' "$OUT" | yq 'select(.kind=="Deployment")')"
C="$(printf '%s' "$DEP" | yq '.spec.template.spec.containers[] | select(.name=="code-server")')"
env_of() { printf '%s' "$C" | yq ".env[] | select(.name==\"$1\") | $2"; }
mnt_ro() { printf '%s' "$1" | yq ".volumeMounts[] | select(.mountPath==\"$2\") | .name + \":\" + (.readOnly // false | tostring)"; }

# entrance: exactly one ClusterIP Service :8080, un-suffixed fullname
[ "$(printf '%s' "$OUT" | yq -N 'select(.kind=="Service") | .metadata.name' | wc -l)" = "1" ] || fail "expected exactly one Service"
[ "$(printf '%s' "$OUT" | yq -N 'select(.kind=="Service") | .metadata.name')" = "svc-aaaa1111-code-server" ] || fail "entrance Service must be the un-suffixed fullname"
[ "$(printf '%s' "$OUT" | yq -N 'select(.kind=="Service") | .spec.type')" = "ClusterIP" ] || fail "Service is not ClusterIP"
[ "$(printf '%s' "$OUT" | yq -N 'select(.kind=="Service") | .spec.ports[0].targetPort')" = "8080" ] || fail "Service targetPort != 8080"
# #1458: code-server + the cookie proxy (nginx, the entrance) — no auth-proxy, no omnigent-host sidecar
[ "$(printf '%s' "$DEP" | yq '[.spec.template.spec.containers[].name] | join(",")')" = "code-server,cookie-proxy" ] || fail "containers must be exactly code-server + cookie-proxy"
[ "$($HELM template t "$CHART_DIR" --set cookieProxy.enabled=false | yq 'select(.kind=="Deployment") | .spec.template.spec.containers | length')" = "1" ] || fail "cookieProxy.enabled=false must leave code-server alone (0.1.3 shape)"
[ "$(printf '%s' "$DEP" | yq '[.spec.template.spec.initContainers[].name] | join(",")')" = "pi-seed" ] || fail "pi-seed must be the only init container"
[ "$(printf '%s' "$C" | yq '.command')" = "null" ] || fail "code-server must keep the image ENTRYPOINT (dumb-init -> omnigent-host-entry -> entrypoint.sh): no command override"
printf '%s' "$OUT" | grep -qiE 'cloudflared|CronJob' && fail "cloudflared / backup CronJob must not be rendered"
# #1458 cookie proxy: nginx owns the entrance port; code-server is on a pod-private unix socket
CP="$(printf '%s' "$DEP" | yq '.spec.template.spec.containers[] | select(.name=="cookie-proxy")')"
[ "$(printf '%s' "$CP" | yq '.ports[0].containerPort')" = "8080" ] || fail "cookie proxy must own the entrance port 8080"
[ "$(printf '%s' "$C" | yq '.ports // [] | length')" = "0" ] || fail "code-server must not expose a TCP port behind the cookie proxy"
printf '%s' "$C" | yq '.args | join(" ")' | grep -q -- '--socket /run/code-server/code-server.sock' || fail "code-server must listen on the unix socket"
[ "$(printf '%s' "$DEP" | yq '.spec.template.spec.volumes[] | select(.name=="code-server-socket") | .emptyDir.medium')" = "Memory" ] || fail "the socket lives in a pod-private Memory emptyDir"
NGX="$(printf '%s' "$OUT" | yq -N 'select(.kind=="ConfigMap" and .metadata.name=="svc-aaaa1111-code-server-settings") | .data["cookie-proxy.conf"]')"
printf '%s' "$NGX" | grep -q 'proxy_cookie_flags ~^code-server-session httponly secure;' || fail "cookie proxy must add HttpOnly + Secure to the session cookie"
printf '%s' "$NGX" | grep -q 'proxy_pass http://unix:/run/code-server/code-server.sock:;' || fail "cookie proxy must forward to the unix socket"
printf '%s' "$NGX" | grep -q 'proxy_set_header Upgrade $http_upgrade;' || fail "cookie proxy must pass websockets"
printf '%s' "$NGX" | grep -q 'access_log off;' || fail "cookie proxy must not log URLs"

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

# the password login cannot be switched off from inside the container (HOME, incl.
# ~/.config, is on the tenant volume): code-server reads ONLY the chart's read-only
# config file (auth: password, nothing else) and gets --auth password as an arg.
[ "$(env_of CODE_SERVER_CONFIG .value)" = "/etc/code-server/config.yaml" ] || fail "CODE_SERVER_CONFIG must be the chart's /etc/code-server/config.yaml"
[ "$(mnt_ro "$C" /etc/code-server)" = "code-server-config:true" ] || fail "/etc/code-server must be a read-only mount of the code-server-config volume"
[ "$(printf '%s' "$DEP" | yq -o=json -I=0 '.spec.template.spec.volumes[] | select(.name=="code-server-config") | .configMap')" = '{"name":"svc-aaaa1111-code-server-settings","defaultMode":444,"items":[{"key":"code-server-config.yaml","path":"config.yaml"},{"key":"code-server-i18n.json","path":"i18n.json"}]}' ] || fail "code-server-config must be the settings ConfigMap's code-server-config.yaml as config.yaml (+ the 0.1.9 login strings as i18n.json, tests/test-login-i18n.sh), mode 0444"
CSC="$(printf '%s' "$OUT" | yq -N 'select(.kind=="ConfigMap" and .metadata.name=="svc-aaaa1111-code-server-settings") | .data["code-server-config.yaml"]')"
[ "$(printf '%s' "$CSC" | yq -o=json -I=0 '.')" = '{"auth":"password"}' ] || fail "the code-server config must be exactly {auth: password} (no password/hashed-password/auth override): got $CSC"
printf '%s' "$C" | yq '.volumeMounts[] | select(.mountPath == "/etc" or .mountPath == "/etc/code-server/config.yaml" or (.mountPath | test("^/etc/code-server/."))) | .mountPath' | grep -q . && fail "nothing may be mounted over or inside /etc/code-server"
printf '%s' "$C" | yq '.env[].name' | grep -qxE 'HASHED_PASSWORD|VSCODE_OPTIONS|XDG_CONFIG_HOME' && fail "no env may override code-server's password or config location"
for flag in "" "--set omnigentHost.enabled=false" "--set codeServer.locale=" "--set codeServer.publicUrl=https://x.example"; do
  # shellcheck disable=SC2086
  AA="$($HELM template t "$CHART_DIR" $flag | yq 'select(.kind=="Deployment") | .spec.template.spec.containers[0].args | join(" ")')"
  case " $AA " in *" --auth password "*) ;; *) fail "args must carry --auth password (${flag:-default}): '$AA'" ;; esac
  case " $AA " in *" --config "*|*"--auth none"*|*"hashed-password"*) fail "args must not override the config/auth: '$AA'" ;; esac
done

# optional keys: optional env from the Secret; a change restarts the pod via checksum
for k in ANTHROPIC_API_KEY:anthropic_api_key OPENROUTER_API_KEY:openrouter_api_key GIT_TOKEN:git_token; do
  n=${k%%:*}; key=${k#*:}
  [ "$(env_of "$n" .valueFrom.secretKeyRef.key)" = "$key" ] || fail "$n must come from Secret key $key"
  [ "$(env_of "$n" .valueFrom.secretKeyRef.optional)" = "true" ] || fail "$n must be optional (an auth.existingSecret may omit it)"
done
# #1556: the optional keys are ALWAYS in the Secret, "" when unset — a key dropped from
# stringData is never deleted from the live Secret's data (helm three-way patch), so a
# cleared key would keep working. Set → value; unset / cleared → "".
for key in anthropic_api_key openrouter_api_key git_token; do
  [ "$(printf '%s' "$OUT" | yq -N "select(.kind==\"Secret\") | .stringData | has(\"$key\")")" = "true" ] || fail "#1556: Secret must always carry $key (\"\" when unset)"
  [ "$(printf '%s' "$OUT" | yq -N "select(.kind==\"Secret\") | .stringData.$key")" = "" ] || fail "#1556: unset $key must render as \"\""
done
SETK="$($HELM template t "$CHART_DIR" --set-string auth.anthropicApiKey=sk-set-1 --set-string auth.openrouterApiKey=or-set-2 --set-string auth.gitToken=gt-set-3 | yq -N 'select(.kind=="Secret")' | yq '.stringData | [.anthropic_api_key, .openrouter_api_key, .git_token] | join(",")')"
[ "$SETK" = "sk-set-1,or-set-2,gt-set-3" ] || fail "#1556: set keys must render their values (got $SETK)"
CLR="$($HELM template t "$CHART_DIR" --set-string auth.anthropicApiKey= --set-string auth.openrouterApiKey= --set-string auth.gitToken= | yq -N 'select(.kind=="Secret")' | yq -o=json -I=0 '.stringData | {"a": .anthropic_api_key, "o": .openrouter_api_key, "g": .git_token}')"
[ "$CLR" = '{"a":"","o":"","g":""}' ] || fail "#1556: cleared keys must render as \"\" (got $CLR)"
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
SET="$(printf '%s' "$OUT" | yq -N 'select(.kind=="ConfigMap" and .metadata.name=="svc-aaaa1111-code-server-settings") | .data["settings.json"]')"
[ "$(printf '%s' "$SET" | yq -p json '.["acp.agents"] | keys | sort | join(",")')" = "claude,codex,pi" ] || fail "settings must configure exactly the pi, claude and codex agents"
[ "$(printf '%s' "$SET" | yq -p json '.["acp.agents"].claude.command')" = "claude-agent-acp" ] || fail "claude agent must run claude-agent-acp"
[ "$(printf '%s' "$SET" | yq -p json '.["chat.disableAIFeatures"]')" = "true" ] || fail "settings must disable VS Code's built-in chat (the image drops Copilot)"
[ "$(printf '%s' "$SET" | yq -p json '.["security.workspace.trust.enabled"]')" = "false" ] || fail "workspace trust must be off (ACP sidebar)"
SEED="$(printf '%s' "$OUT" | yq -N 'select(.kind=="ConfigMap" and .metadata.name=="svc-aaaa1111-code-server-settings") | .data["pi-seed.sh"]')"
[ "$(printf '%s\n' "$SEED")" = "$(cat "$CHART_DIR/files/pi-seed.sh")" ] || fail "the settings ConfigMap must carry files/pi-seed.sh verbatim (tests/test-pi-seed.sh executes it)"
printf '%s' "$C" | yq '.volumeMounts[] | select(.mountPath=="/home/coder/.local/share/code-server/extensions") | .subPath' | grep -qx extensions || fail "runtime extensions must persist on the pi volume"

# HOME state on the pi volume (CS-01/CSV-M1/CSV-M3): ~/.ssh, ~/.config, ~/.local
# from pi-data subPaths home/*; the IDE's User/ and extensions/ stay mounted inside
# ~/.local; ~/.cache a size-limited emptyDir; files via GIT_CONFIG_GLOBAL / HISTFILE.
mnt() { printf '%s' "$1" | yq ".volumeMounts[] | select(.mountPath==\"$2\") | .name + \":\" + (.subPath // \"\")"; }
# #1452: the WHOLE HOME is pi-data subPath home (the directory 0.1.2/0.1.3 kept
# ~/.ssh, ~/.config and ~/.local in, so an upgrade keeps them); no per-dir mounts left.
[ "$(mnt "$C" /home/coder)" = "pi-data:home" ] || fail "HOME must be mounted from pi-data subPath home (#1452)"
for m in .ssh .config .local; do
  [ -z "$(mnt "$C" "/home/coder/$m")" ] || fail "HOME/$m must not be a separate mount any more (inside the HOME mount)"
done
[ "$(mnt "$C" /home/coder/.local/share/code-server/User)" = "pi-data:ide-user" ] || fail "IDE User/ must stay on pi-data ide-user"
[ "$(mnt "$C" /home/coder/.cache)" = "home-cache:" ] || fail "HOME/.cache must be the home-cache volume"
[ "$(printf '%s' "$DEP" | yq '.spec.template.spec.volumes[] | select(.name=="home-cache") | .emptyDir.sizeLimit')" = "2Gi" ] || fail "HOME/.cache must be an emptyDir with sizeLimit 2Gi"
[ "$(env_of GIT_CONFIG_GLOBAL .value)" = "/data/pi-agent/home/.gitconfig" ] || fail "GIT_CONFIG_GLOBAL must point into the pi volume"
[ "$(env_of HISTFILE .value)" = "/data/pi-agent/home/.bash_history" ] || fail "HISTFILE must point into the pi volume"
[ "$(env_of NPM_CONFIG_PREFIX .value)" = "/home/coder/.local" ] || fail "npm global prefix must be ~/.local (on the pi volume)"
[ "$(env_of NPM_CONFIG_CACHE .value)" = "/home/coder/.cache/npm" ] || fail "npm cache must be in the size-limited ~/.cache"
# (pi-seed behaviour — no-clobber seed, ~/.ssh 0700, language packs — is EXECUTED by tests/test-pi-seed.sh)
printf '%s' "$SEED" | grep -qE 'cp -a[^n]|cp -r|cp -f|rm -r' && fail "pi-seed must never overwrite or delete tenant HOME files"
[ "$(printf '%s\n' "$SEED" | grep -E '(^|[;&|[:space:]])rm ' | sed 's/^ *//')" = 'rm -f "$tmp"' ] || fail "pi-seed may only remove its own temp file"
OFF="$($HELM template t "$CHART_DIR" --set persistence.home.enabled=false | yq 'select(.kind=="Deployment")')"
printf '%s' "$OFF" | yq '.spec.template.spec.containers[0].volumeMounts[].subPath' | grep -q '^home/' && fail "persistence.home.enabled=false must not mount HOME from the volume"
printf '%s' "$OFF" | yq '.spec.template.spec.containers[0].env[].name' | grep -qxE 'GIT_CONFIG_GLOBAL|HISTFILE' && fail "persistence.home.enabled=false must not set GIT_CONFIG_GLOBAL/HISTFILE"
[ "$(printf '%s' "$OFF" | yq '.spec.template.spec.volumes[] | select(.name=="home-cache") | .emptyDir.sizeLimit')" = "2Gi" ] || fail "HOME/.cache stays size-limited without HOME persistence"

# claude.ai remote MCP connectors off by default (CS-07); git shows non-ASCII names (CSV-M2)
[ "$(env_of ENABLE_CLAUDEAI_MCP_SERVERS .value)" = "false" ] || fail "ENABLE_CLAUDEAI_MCP_SERVERS must default to false"
$HELM template t "$CHART_DIR" --set claude.claudeAiMcpServers=true | yq 'select(.kind=="Deployment") | .spec.template.spec.containers[0].env[].name' | grep -qx ENABLE_CLAUDEAI_MCP_SERVERS && fail "claude.claudeAiMcpServers=true must drop the override"
GC="$(printf '%s' "$OUT" | yq -N 'select(.kind=="ConfigMap" and .metadata.name=="svc-aaaa1111-code-server-settings") | .data.gitconfig')"
printf '%s' "$GC" | git config -f /dev/stdin --get core.quotepath | grep -qx false || fail "/etc/gitconfig must set core.quotepath=false"
printf '%s' "$GC" | git config -f /dev/stdin --get filter.lfs.process | grep -qx 'git-lfs filter-process' || fail "/etc/gitconfig must keep the image's git-lfs filter"

# build parallelism = CPU limit (nproc reports the node; CS-10)
jobs_for() { $HELM template t "$CHART_DIR" "$@" | yq 'select(.kind=="Deployment")' | yq '.spec.template.spec.containers[0].env[] | select(.name=="MAKEFLAGS" or .name=="UV_CONCURRENT_BUILDS" or .name=="CMAKE_BUILD_PARALLEL_LEVEL" or .name=="PYTEST_XDIST_AUTO_NUM_WORKERS") | .value' | tr '\n' ' '; }
[ "$(jobs_for)" = "-j2 2 2 2 " ] || fail "default build jobs must follow the 2-CPU limit: got '$(jobs_for)'"
[ "$(jobs_for --set codeServer.resources.limits.cpu=1500m)" = "-j2 2 2 2 " ] || fail "1500m must round up to 2 jobs"
[ "$(jobs_for --set codeServer.resources.limits.cpu=3)" = "-j3 3 3 3 " ] || fail "a 3-CPU limit must give 3 jobs"
[ "$(jobs_for --set codeServer.buildJobs=5)" = "-j5 5 5 5 " ] || fail "codeServer.buildJobs must override"
$HELM template t "$CHART_DIR" --set codeServer.buildJobs=0 >/dev/null 2>&1 && fail "buildJobs 0 must fail the render"

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
# #1434: every container caps its share of the node's system disk; every emptyDir capped
for c in $(printf '%s' "$DEP" | yq '.spec.template.spec | (.initContainers + .containers)[] | .name'); do
  printf '%s' "$DEP" | yq ".spec.template.spec | (.initContainers + .containers)[] | select(.name==\"$c\") | .resources.limits[\"ephemeral-storage\"]" | grep -qv null || fail "container $c lacks an ephemeral-storage limit (#1434)"
  printf '%s' "$DEP" | yq ".spec.template.spec | (.initContainers + .containers)[] | select(.name==\"$c\") | .resources.requests[\"ephemeral-storage\"]" | grep -qv null || fail "container $c lacks an ephemeral-storage request (#1434)"
done
[ "$(printf '%s' "$DEP" | yq '[.spec.template.spec.volumes[] | select(has("emptyDir")) | select(.emptyDir.sizeLimit == null)] | length')" = "0" ] || fail "an emptyDir without sizeLimit (#1434)"
[ "$(printf '%s' "$C" | yq '.resources.limits["ephemeral-storage"]')" = "8Gi" ] || fail "code-server ephemeral-storage limit must cover the 2Gi ~/.cache + scratch (8Gi)"
[ "$($HELM template t "$CHART_DIR" --set codeServer.resources.limits.cpu=2 --set codeServer.resources.limits.memory=4Gi | yq 'select(.kind=="Deployment") | .spec.template.spec.containers[] | select(.name=="code-server") | .resources.limits["ephemeral-storage"]')" = "8Gi" ] || fail "ephemeral-storage lost when the platform sets cpu/memory"
# the IDE keeps the whole plan (T1 2 vCPU / 4Gi), with the Omnigent host on or off
for flag in "" "--set omnigentHost.enabled=false"; do
  # shellcheck disable=SC2086
  R="$($HELM template t "$CHART_DIR" $flag | yq 'select(.kind=="Deployment")' | yq '.spec.template.spec.containers[] | select(.name=="code-server") | .resources | [.requests.cpu, .requests.memory, .limits.cpu, .limits.memory] | join("/")')"
  [ "$R" = "500m/1Gi/2/4Gi" ] || fail "code-server resources must be the full plan 500m/1Gi/2/4Gi (${flag:-default}): got $R"
done
$HELM template t "$CHART_DIR" | grep -qiE 'resourcePlan|planBudget' && fail "no plan split helpers/values may render"
grep -qE 'resourcePlan|ideResources|sidecarDefaultResources' "$CHART_DIR/values.yaml" "$CHART_DIR/templates/"*.tpl && fail "round-2 plan-split values/helpers must be gone"
printf '%s' "$DEP" | yq '.spec.template.spec.initContainers[0].resources.limits.cpu' | grep -q . || fail "pi-seed lacks limits (ResourceQuota)"
NS="$(printf '%s' "$OUT" | { grep -E '^  namespace:' || true; } | awk '{print $2}' | sort -u | tr '\n' ' ')"; [ -z "$NS" ] || [ "$NS" = "SENTINEL " ] || fail "hard-coded namespace: $NS"
A="$($HELM template svc-aaaa1111 "$CHART_DIR" -n X | yq -N '.kind + "/" + .metadata.name' | sort)"
B="$($HELM template svc-bbbb2222 "$CHART_DIR" -n X | yq -N '.kind + "/" + .metadata.name' | sort)"
[ -z "$(comm -12 <(printf '%s\n' "$A") <(printf '%s\n' "$B"))" ] || fail "two releases collide on object names"
# 0.1.8 (#1637): the startupProbe has a real timeout (default 1 s restarted slow-but-fine starts)
[ "$(printf '%s' "$C" | yq '.startupProbe.timeoutSeconds')" = "5" ] || fail "startupProbe.timeoutSeconds must be 5"
[ "$($HELM template t "$CHART_DIR" --set cookieProxy.enabled=false | yq 'select(.kind=="Deployment") | .spec.template.spec.containers[0].startupProbe.timeoutSeconds')" = "5" ] || fail "startupProbe.timeoutSeconds must be 5 without the cookie proxy too"
echo "PASS (render-contract): code-server behind the cookie proxy (HttpOnly+Secure, unix socket; #1458) with its own password and the image ENTRYPOINT, whole HOME on the pi volume (#1452), ephemeral-storage everywhere (#1434), PASSWORD←Secret (pin/existing/lookup), password login not overridable (read-only CODE_SERVER_CONFIG auth: password + --auth password), reset keeps the pod template, optional keys + restart checksum + OpenRouter route, pi+claude wiring, full-plan resources, HOME on the pi volume + size-limited cache, claude.ai connectors off, quotepath/lfs gitconfig, build jobs = CPU limit, trusted-origin host, internet-only egress, non-root, RWO+Recreate, limits, collision-free names."

[ "$(env_of CODEX_HOME .value)" = "/data/pi-agent/codex" ] || fail "Codex state must persist on the pi-data volume"
[ "$(printf '%s' "$SET" | yq -p json '.["acp.agents"].codex.command')" = "codex-code" ] || fail "Codex ACP wrapper missing"
