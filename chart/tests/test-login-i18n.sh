#!/usr/bin/env bash
# code-server login page in Traditional Chinese, without leaking how the password is
# carried (INFRA-DOC-007-3), and the disclosure that every process in the IDE
# container can read the password and the optional keys (INFRA-DOC-007-2).
#
# Upstream code-server 4.139.1 ships login strings for en / zh-cn / ja / th / ur only;
# with --locale zh-tw i18next falls back to en, so the page was English and said
# "Password was set from $PASSWORD." (src/node/i18n/locales/en.json,
# LOGIN_USING_ENV_PASSWORD) — naming the env var an extension or AI assistant can read.
# Since 4.10x code-server takes --i18n <json>: those strings override EVERY bundled
# language (src/node/i18n/index.ts loadCustomStrings → addResourceBundle per locale,
# shallow merge), so the en fallback that zh-tw resolves to shows them too.
set -euo pipefail
CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; HELM="${HELM_BINARY:-helm}"
command -v yq >/dev/null 2>&1 || { echo "SKIP (login-i18n): yq (mikefarah) required"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP (login-i18n): jq required"; exit 0; }
fail() { echo "FAIL (login-i18n): $1"; exit 1; }

# Every key of code-server 4.139.1 src/node/i18n/locales/en.json (the login page and
# its error messages). A key missing from the file would fall back to English.
KEYS="INCORRECT_PASSWORD LOGIN_BELOW LOGIN_PASSWORD LOGIN_RATE_LIMIT LOGIN_TITLE LOGIN_USING_ENV_PASSWORD LOGIN_USING_HASHED_PASSWORD MISS_PASSWORD PASSWORD_PLACEHOLDER SUBMIT WELCOME"

render() { $HELM template svc-aaaa1111 "$CHART_DIR" -n SENTINEL "$@"; }
args_of() { printf '%s' "$1" | yq 'select(.kind=="Deployment") | .spec.template.spec.containers[] | select(.name=="code-server") | .args | join(" ")'; }
cm_key() { printf '%s' "$1" | yq -N "select(.kind==\"ConfigMap\" and .metadata.name==\"svc-aaaa1111-code-server-settings\") | .data[\"$2\"] // \"\""; }

OUT="$(render)"

# 1. code-server gets --i18n pointing at the chart's read-only mount
AA="$(args_of "$OUT")"
case " $AA " in *" --i18n /etc/code-server/i18n.json "*) ;; *) fail "args must carry --i18n /etc/code-server/i18n.json: '$AA'" ;; esac
VOL="$(printf '%s' "$OUT" | yq -o=json -I=0 'select(.kind=="Deployment") | .spec.template.spec.volumes[] | select(.name=="code-server-config") | .configMap.items')"
[ "$VOL" = '[{"key":"code-server-config.yaml","path":"config.yaml"},{"key":"code-server-i18n.json","path":"i18n.json"}]' ] \
  || fail "code-server-config volume must project config.yaml + i18n.json from the settings ConfigMap: $VOL"

# 2. the strings: valid JSON, exactly the upstream keys, all non-empty, Traditional Chinese
J="$(cm_key "$OUT" code-server-i18n.json)"
printf '%s' "$J" | jq -e 'type=="object"' >/dev/null 2>&1 || fail "code-server-i18n.json is not a JSON object"
GOT="$(printf '%s' "$J" | jq -r 'keys | join(" ")')"
[ "$GOT" = "$KEYS" ] || fail "i18n keys must be exactly the upstream login keys: got '$GOT'"
printf '%s' "$J" | jq -e 'all(.[]; type=="string" and length>0)' >/dev/null || fail "every login string must be a non-empty string"
# how the password is carried is never shown (env var names, config file paths)
V="$(printf '%s' "$J" | jq -r '.[]')"
printf '%s' "$V" | grep -qE '\$[A-Za-z_]|PASSWORD|config\.yaml|config file|設定檔|環境變數' \
  && fail "login strings must not name the env var / config file that carries the password"
for k in LOGIN_PASSWORD LOGIN_USING_ENV_PASSWORD LOGIN_USING_HASHED_PASSWORD; do
  printf '%s' "$J" | jq -r --arg k "$k" '.[$k]' | grep -q '管理員帳密' || fail "$k must point at the PaaS service page 管理員帳密 (Admin Credentials)"
done
[ "$(printf '%s' "$J" | jq -r '.SUBMIT')" = "登入" ] || fail "SUBMIT must be 登入"
[ "$(printf '%s' "$J" | jq -r '.INCORRECT_PASSWORD')" = "密碼錯誤" ] || fail "INCORRECT_PASSWORD must be 密碼錯誤"
# no i18next placeholders: --app-name is not set, an unresolved {{app}} would show literally
printf '%s' "$V" | grep -q '{{' && fail "login strings must not use i18next placeholders"
# simplified-only characters that would betray a zh-CN copy
printf '%s' "$V" | grep -qE '[码录请输错误为设]' && fail "login strings must be Traditional Chinese (found a simplified character)"

# 3. off switch: codeServer.loginI18n=false → upstream strings, no flag, no item
OFF="$(render --set codeServer.loginI18n=false)"
case " $(args_of "$OFF") " in *" --i18n "*) fail "codeServer.loginI18n=false must drop --i18n" ;; esac
[ -z "$(cm_key "$OFF" code-server-i18n.json)" ] || fail "codeServer.loginI18n=false must not render code-server-i18n.json"
[ "$(printf '%s' "$OFF" | yq -o=json -I=0 'select(.kind=="Deployment") | .spec.template.spec.volumes[] | select(.name=="code-server-config") | .configMap.items')" = '[{"key":"code-server-config.yaml","path":"config.yaml"}]' ] \
  || fail "codeServer.loginI18n=false must project only config.yaml"

# 4. changing the strings never touches the password path; a password reset still
#    leaves the pod template alone (helm_secret 15 s reset budget)
T1="$(render --set-string config.sensitive.admin_password=first-password-1 | yq 'select(.kind=="Deployment") | .spec.template')"
T2="$(render --set-string config.sensitive.admin_password=second-password-2 | yq 'select(.kind=="Deployment") | .spec.template')"
[ "$T1" = "$T2" ] || fail "a password change must not change the pod template"

# 5. disclosure (INFRA-DOC-007-2): NOTES and README say that extensions / AI assistants /
#    any process in the container can read the password and the keys, and recommend a
#    budget-limited LiteLLM virtual key instead of a master key.
NOTES="$(cat "$CHART_DIR/templates/NOTES.txt")"
for needle in '/proc/1/environ' 'LiteLLM' 'virtual key'; do
  printf '%s' "$NOTES" | grep -qF "$needle" || fail "NOTES must disclose secret visibility (missing '$needle')"
done
grep -qF '## 容器內看得到的密碼與金鑰' "$CHART_DIR/README.md" || fail "README must have the section 容器內看得到的密碼與金鑰"
sed -n '/## 容器內看得到的密碼與金鑰/,/^## /p' "$CHART_DIR/README.md" > /tmp/.cs-readme.$$
for needle in '/proc/1/environ' 'ANTHROPIC_API_KEY' 'OPENROUTER_API_KEY' 'GIT_TOKEN' 'PASSWORD' 'LiteLLM' '虛擬金鑰'; do
  grep -qF "$needle" /tmp/.cs-readme.$$ || { rm -f /tmp/.cs-readme.$$; fail "README secret section must mention '$needle'"; }
done
rm -f /tmp/.cs-readme.$$

echo "PASS (login-i18n): --i18n /etc/code-server/i18n.json (read-only projection of the settings ConfigMap), all 11 upstream login keys in Traditional Chinese pointing at 管理員帳密 with no env-var / config-file names or placeholders, loginI18n=false restores upstream, password reset keeps the pod template, NOTES + README disclose that the container can read the password and keys (/proc/1/environ) and recommend LiteLLM virtual keys."
