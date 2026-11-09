#!/usr/bin/env bash
# code-server pi-seed init container: EXECUTES the rendered script (the pi-seed.sh key
# of the settings ConfigMap = files/pi-seed.sh) with sh/dash/bash (and busybox sh
# when OG_TEST_BUSYBOX points to one) against fake image/volume directories:
#   * required IDE settings win, the tenant's other keys stay; a settings.json jq
#     cannot parse (VS Code allows comments) is left alone and the init still succeeds;
#   * persistence.home: the image skeleton is seeded with no-clobber, never
#     ~/.config/code-server (code-server reads only the chart's read-only config);
#     ~/.ssh ends 0700 (fresh and pre-existing);
#   * languagepacks.json: the image's entries win over the volume's, a pack the
#     tenant installed keeps its entry;
#   * a failing image pi-seed fails the init container (set -eu);
#   * SEED_HOME=0 (persistence.home.enabled=false) touches no HOME state.
set -u
CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; HELM="${HELM_BINARY:-helm}"
command -v yq >/dev/null 2>&1 || { echo "SKIP (pi-seed): yq (mikefarah) required"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP (pi-seed): jq required"; exit 0; }
rc=0
ok() { printf '  ok   %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; rc=1; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
OUT=$($HELM template svc-5eed0001 "$CHART_DIR")
printf '%s' "$OUT" | yq -N 'select(.kind=="ConfigMap" and .metadata.name=="svc-5eed0001-code-server-settings") | .data["pi-seed.sh"]' >"$T/pi-seed.sh"
printf '%s' "$OUT" | yq -N 'select(.kind=="ConfigMap" and .metadata.name=="svc-5eed0001-code-server-settings") | .data["settings.json"]' >"$T/settings.json"
[ -s "$T/pi-seed.sh" ] || { echo "FAIL (pi-seed): no pi-seed.sh in the settings ConfigMap"; exit 1; }
DEP=$(printf '%s' "$OUT" | yq 'select(.kind=="Deployment")')
eq "init runs the ConfigMap script" "$(printf '%s' "$DEP" | yq -o=json -I=0 '.spec.template.spec.initContainers[] | select(.name=="pi-seed") | .command')" '["/bin/sh","/seed/pi-seed.sh"]'
eq "init mounts the settings ConfigMap at /seed" "$(printf '%s' "$DEP" | yq '.spec.template.spec.initContainers[] | select(.name=="pi-seed") | .volumeMounts[] | select(.mountPath=="/seed") | .name')" settings
eq "SEED_HOME=1 by default" "$(printf '%s' "$DEP" | yq '.spec.template.spec.initContainers[0].env[] | select(.name=="SEED_HOME") | .value')" 1
eq "SEED_HOME=0 with persistence.home.enabled=false" "$($HELM template t "$CHART_DIR" --set persistence.home.enabled=false | yq 'select(.kind=="Deployment") | .spec.template.spec.initContainers[0].env[] | select(.name=="SEED_HOME") | .value')" 0

shells="sh bash"
[ -n "${OG_TEST_BUSYBOX:-}" ] && [ -x "${OG_TEST_BUSYBOX}" ] && shells="$shells busybox"

# fake image: HOME skeleton + the image's pi-seed
mk_image() {
  I=$1
  mkdir -p "$I/.config/code-server" "$I/.config/tool" "$I/.local/bin" "$I/.local/share/code-server"
  printf 'bind-addr: 127.0.0.1:8080\nauth: password\npassword: baked-into-image\n' >"$I/.config/code-server/config.yaml"
  echo image-tool-conf >"$I/.config/tool/conf"
  echo image-helper >"$I/.local/bin/helper"
  printf '{"zh-tw":{"hash":"image-hash","translations":{"vscode":"/usr/lib/code-server/new/zh-hant"}}}\n' >"$I/.local/share/code-server/languagepacks.json"
  printf '#!/bin/sh\nmkdir -p "$PI_DATA/claude" && echo ran >>"$PI_DATA/pi-seed-ran"\n' >"$I/pi-seed"
  chmod +x "$I/pi-seed"
  # #1452 HOME root: dotfiles, a cache dir, and the image's links INTO the volume's home/
  echo image-bashrc >"$I/.bashrc"; echo image-profile >"$I/.profile"
  mkdir -p "$I/.cache/x"; echo junk >"$I/.cache/x/f"
  ln -s "$2/home/.gitconfig" "$I/.gitconfig"; ln -s "$2/home/.pi" "$I/.pi"
  ln -s /elsewhere/claude "$I/.claude"
}
seed() { # <shell> <case dir> [VAR=value ...]; prints the exit code
  sh_=$1; d=$2; shift 2
  if [ "$sh_" = busybox ]; then set -- "$OG_TEST_BUSYBOX" sh "$@"; else set -- "$sh_" "$@"; fi
  env PI_DATA="$d/vol" IDE_DIR="$d/vol/ide-user" EXT_DIR="$d/vol/extensions" SEED_DIR="$T" \
      IMAGE_HOME="$d/img" PI_SEED_BIN="$d/img/pi-seed" SEED_HOME=1 TMPDIR="$d" \
      "${@:2:$#}" "$1" "$T/pi-seed.sh" >"$d/log" 2>&1
  echo $?
}
# run_seed passes extra VAR=value words through env before the shell: rebuild the call.
seed() { # <shell> <case dir> [VAR=value ...]
  sh_=$1; d=$2; shift 2
  if [ "$sh_" = busybox ]; then cmd=("$OG_TEST_BUSYBOX" sh); else cmd=("$sh_"); fi
  env PI_DATA="$d/vol" IDE_DIR="$d/vol/ide-user" EXT_DIR="$d/vol/extensions" SEED_DIR="$T" \
      IMAGE_HOME="$d/img" PI_SEED_BIN="$d/img/pi-seed" SEED_HOME=1 TMPDIR="$d" "$@" \
      "${cmd[@]}" "$T/pi-seed.sh" >"$d/log" 2>&1
  echo $?
}
mode() { stat -c %a "$1" 2>/dev/null; }

for s in $shells; do
  command -v "${s%% *}" >/dev/null 2>&1 || [ "$s" = busybox ] || { echo "  skip shell $s (not installed)"; continue; }
  echo "── shell: $s"

  # A: fresh volume
  d="$T/$s-fresh"; mkdir -p "$d/vol"; mk_image "$d/img" "$d/vol"
  eq "[$s] fresh: rc 0" "$(seed "$s" "$d")" 0
  eq "[$s] fresh: image pi-seed ran" "$(cat "$d/vol/pi-seed-ran" 2>/dev/null)" ran
  eq "[$s] fresh: settings.json = required settings" "$(jq -S . "$d/vol/ide-user/settings.json" 2>/dev/null)" "$(jq -S . "$T/settings.json")"
  eq "[$s] fresh: ~/.ssh created 0700" "$(mode "$d/vol/home/.ssh")" 700
  eq "[$s] fresh: image ~/.config skeleton seeded" "$(cat "$d/vol/home/.config/tool/conf" 2>/dev/null)" image-tool-conf
  eq "[$s] fresh: image ~/.local skeleton seeded" "$(cat "$d/vol/home/.local/bin/helper" 2>/dev/null)" image-helper
  eq "[$s] fresh: ~/.config/code-server NOT seeded (stale image config.yaml)" "$([ -e "$d/vol/home/.config/code-server" ] && echo present || echo absent)" absent
  eq "[$s] fresh: languagepacks.json = the image's" "$(jq -r '.["zh-tw"].hash' "$d/vol/home/.local/share/code-server/languagepacks.json" 2>/dev/null)" image-hash
  eq "[$s] fresh: extensions dir created" "$([ -d "$d/vol/extensions" ] && echo yes)" yes
  eq "[$s] fresh: ~/.bashrc seeded (#1452)" "$(cat "$d/vol/home/.bashrc" 2>/dev/null)" image-bashrc
  eq "[$s] fresh: ~/.profile seeded (#1452)" "$(cat "$d/vol/home/.profile" 2>/dev/null)" image-profile
  eq "[$s] fresh: ~/.cache NOT seeded (emptyDir)" "$([ -e "$d/vol/home/.cache" ] && echo present || echo absent)" absent
  eq "[$s] fresh: no self-link ~/.gitconfig" "$([ -L "$d/vol/home/.gitconfig" ] && echo link || echo none)" none
  eq "[$s] fresh: no self-link ~/.pi" "$([ -L "$d/vol/home/.pi" ] && echo link || echo none)" none
  eq "[$s] fresh: other links kept as links" "$(readlink "$d/vol/home/.claude" 2>/dev/null)" /elsewhere/claude
  eq "[$s] fresh: HOME 0700" "$(mode "$d/vol/home")" 700

  # B: existing volume with tenant state
  d="$T/$s-existing"; mk_image "$d/img" "$d/vol"
  mkdir -p "$d/vol/ide-user" "$d/vol/home/.config/tool" "$d/vol/home/.local/bin" "$d/vol/home/.local/share/code-server" "$d/vol/home/.ssh"
  printf '{"editor.fontSize": 20, "chat.disableAIFeatures": false, "acp.agents": {"mine": {"command": "x"}}}\n' >"$d/vol/ide-user/settings.json"
  echo tenant-tool-conf >"$d/vol/home/.config/tool/conf"
  echo tenant-helper >"$d/vol/home/.local/bin/helper"
  echo tenant-key >"$d/vol/home/.ssh/id_ed25519"; chmod 600 "$d/vol/home/.ssh/id_ed25519"; chmod 755 "$d/vol/home/.ssh"
  printf '{"zh-tw":{"hash":"old-volume-hash","translations":{"vscode":"/usr/lib/code-server/old/zh-hant"}},"fr":{"hash":"tenant-fr"}}\n' >"$d/vol/home/.local/share/code-server/languagepacks.json"
  echo tenant-bashrc >"$d/vol/home/.bashrc"; echo tenant-gitconfig >"$d/vol/home/.gitconfig"; echo tenant-file >"$d/vol/home/notes.txt"
  eq "[$s] existing: rc 0" "$(seed "$s" "$d")" 0
  S="$d/vol/ide-user/settings.json"
  eq "[$s] existing: tenant setting kept" "$(jq -r '.["editor.fontSize"]' "$S")" 20
  eq "[$s] existing: required setting wins" "$(jq -r '.["chat.disableAIFeatures"]' "$S")" true
  eq "[$s] existing: required agents merged, tenant agent kept" "$(jq -r '.["acp.agents"] | keys | join(",")' "$S")" claude,codex,mine,pi
  eq "[$s] existing: tenant ~/.config file not overwritten" "$(cat "$d/vol/home/.config/tool/conf")" tenant-tool-conf
  eq "[$s] existing: tenant ~/.local file not overwritten" "$(cat "$d/vol/home/.local/bin/helper")" tenant-helper
  eq "[$s] existing: ssh key kept" "$(cat "$d/vol/home/.ssh/id_ed25519")" tenant-key
  eq "[$s] existing: ~/.ssh back to 0700" "$(mode "$d/vol/home/.ssh")" 700
  L="$d/vol/home/.local/share/code-server/languagepacks.json"
  eq "[$s] existing: image zh-tw entry wins over the volume's" "$(jq -r '.["zh-tw"].hash + " " + .["zh-tw"].translations.vscode' "$L")" "image-hash /usr/lib/code-server/new/zh-hant"
  eq "[$s] existing: tenant-installed pack kept" "$(jq -r '.fr.hash' "$L")" tenant-fr
  eq "[$s] existing: tenant ~/.bashrc not overwritten (#1452)" "$(cat "$d/vol/home/.bashrc")" tenant-bashrc
  eq "[$s] existing: ~/.gitconfig file kept (not replaced by the image link)" "$(cat "$d/vol/home/.gitconfig")" tenant-gitconfig
  eq "[$s] existing: missing ~/.profile seeded" "$(cat "$d/vol/home/.profile" 2>/dev/null)" image-profile
  eq "[$s] existing: tenant file in ~ kept" "$(cat "$d/vol/home/notes.txt")" tenant-file

  # C: settings.json with comments (JSONC): left alone, init still succeeds
  d="$T/$s-jsonc"; mk_image "$d/img" "$d/vol"; mkdir -p "$d/vol/ide-user"
  printf '{\n  // my font\n  "editor.fontSize": 18\n}\n' >"$d/vol/ide-user/settings.json"
  cp "$d/vol/ide-user/settings.json" "$d/jsonc.orig"
  eq "[$s] jsonc: rc 0" "$(seed "$s" "$d")" 0
  eq "[$s] jsonc: tenant file unchanged" "$(cmp -s "$d/vol/ide-user/settings.json" "$d/jsonc.orig" && echo same)" same

  # D: the image's pi-seed fails -> the init container fails (set -eu)
  d="$T/$s-fail"; mk_image "$d/img" "$d/vol"; mkdir -p "$d/vol"
  printf '#!/bin/sh\nexit 3\n' >"$d/img/pi-seed"
  r=$(seed "$s" "$d"); [ "$r" != 0 ] && ok "[$s] failing image pi-seed fails the init (rc $r)" || bad "[$s] failing image pi-seed must fail the init (set -eu), got rc 0"
  eq "[$s] failing image pi-seed: nothing merged after it" "$([ -e "$d/vol/ide-user/settings.json" ] && echo merged || echo stopped)" stopped

  # E: SEED_HOME=0 touches no HOME state
  d="$T/$s-nohome"; mk_image "$d/img" "$d/vol"; mkdir -p "$d/vol"
  eq "[$s] SEED_HOME=0: rc 0" "$(seed "$s" "$d" SEED_HOME=0)" 0
  eq "[$s] SEED_HOME=0: no home/ on the volume" "$([ -e "$d/vol/home" ] && echo present || echo absent)" absent

  # F (#1378): pi default model filled into an EXISTING settings.json that has none
  d="$T/$s-pimodel"; mk_image "$d/img" "$d/vol"; mkdir -p "$d/vol"
  printf '{"theme":"dark"}\n' >"$d/vol/settings.json"; chmod 600 "$d/vol/settings.json"
  eq "[$s] pi model: rc 0" "$(seed "$s" "$d" PI_DEFAULT_PROVIDER=openrouter PI_DEFAULT_MODEL=moonshotai/kimi-k2.6)" 0
  eq "[$s] pi model: provider+model filled, other keys kept" "$(jq -c -S . "$d/vol/settings.json")" '{"defaultModel":"moonshotai/kimi-k2.6","defaultProvider":"openrouter","theme":"dark"}'
  eq "[$s] pi model: file stays 0600" "$(mode "$d/vol/settings.json")" 600
  # an explicit choice is never overridden (either key present)
  d="$T/$s-pichosen"; mk_image "$d/img" "$d/vol"; mkdir -p "$d/vol"
  printf '{"defaultProvider":"anthropic","defaultModel":"claude-x"}\n' >"$d/vol/settings.json"; cp "$d/vol/settings.json" "$d/orig"
  eq "[$s] pi chosen: rc 0" "$(seed "$s" "$d" PI_DEFAULT_PROVIDER=openrouter PI_DEFAULT_MODEL=moonshotai/kimi-k2.6)" 0
  eq "[$s] pi chosen: tenant choice untouched" "$(cmp -s "$d/vol/settings.json" "$d/orig" && echo same)" same
  d="$T/$s-pihalf"; mk_image "$d/img" "$d/vol"; mkdir -p "$d/vol"
  printf '{"defaultProvider":"openai-codex"}\n' >"$d/vol/settings.json"; cp "$d/vol/settings.json" "$d/orig"
  seed "$s" "$d" PI_DEFAULT_PROVIDER=openrouter PI_DEFAULT_MODEL=m >/dev/null
  eq "[$s] pi half-set: untouched" "$(cmp -s "$d/vol/settings.json" "$d/orig" && echo same)" same
  # no model given → nothing added; unparsable file → left alone, init still succeeds
  d="$T/$s-pinomodel"; mk_image "$d/img" "$d/vol"; mkdir -p "$d/vol"
  printf '{"theme":"dark"}\n' >"$d/vol/settings.json"; cp "$d/vol/settings.json" "$d/orig"
  seed "$s" "$d" PI_DEFAULT_PROVIDER=openai-codex PI_DEFAULT_MODEL= >/dev/null
  eq "[$s] pi no model: untouched" "$(cmp -s "$d/vol/settings.json" "$d/orig" && echo same)" same
  d="$T/$s-pibad"; mk_image "$d/img" "$d/vol"; mkdir -p "$d/vol"
  printf 'not json\n' >"$d/vol/settings.json"; cp "$d/vol/settings.json" "$d/orig"
  eq "[$s] pi unparsable: rc 0" "$(seed "$s" "$d" PI_DEFAULT_PROVIDER=openrouter PI_DEFAULT_MODEL=m)" 0
  eq "[$s] pi unparsable: untouched" "$(cmp -s "$d/vol/settings.json" "$d/orig" && echo same)" same
done

# #1378 render: the pi-seed init gets openrouter + the default model iff an
# OpenRouter key is set and no explicit pi.defaultModel.
pienv() { $HELM template t "$CHART_DIR" "$@" | yq 'select(.kind=="Deployment") | .spec.template.spec.initContainers[] | select(.name=="pi-seed") | .env[] | select(.name=="PI_DEFAULT_PROVIDER" or .name=="PI_DEFAULT_MODEL") | .value' | tr '\n' ' '; }
eq "render: no key → values defaults (no model seeded)" "$(pienv)" "openai-codex  "
eq "render: OpenRouter key → openrouter + default model" "$(pienv --set auth.openrouterApiKey=sk-or)" "openrouter moonshotai/kimi-k2.6 "
eq "render: explicit pi.defaultModel wins" "$(pienv --set auth.openrouterApiKey=sk-or --set pi.defaultModel=gpt-x)" "openai-codex gpt-x "
eq "render: openrouterDefaultModel='' disables the switch" "$(pienv --set auth.openrouterApiKey=sk-or --set pi.openrouterDefaultModel=)" "openai-codex  "

if [ "$rc" = 0 ]; then
  echo "PASS (pi-seed): settings merge (required wins, tenant kept, JSONC left alone), no-clobber HOME seed (incl. the HOME root dotfiles #1452, no self-links, no ~/.cache) without ~/.config/code-server, ~/.ssh 0700, image language packs win, set -eu, SEED_HOME=0, pi default model (#1378: fill-only, render switch)"
else
  echo "FAIL (pi-seed)"
fi
exit $rc
