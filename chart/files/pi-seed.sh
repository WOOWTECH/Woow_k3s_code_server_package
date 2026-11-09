#!/bin/sh
# code-server pi-seed init container (rendered into the <release>-code-server-settings
# ConfigMap as pi-seed.sh and run as `sh /seed/pi-seed.sh`). Kept as a file so the
# chart tests EXECUTE it against fake image/volume directories
# (tests/test-pi-seed.sh) instead of grepping strings.
#
# 1. pi + Claude Code state store: the image's idempotent pi-seed (cp -an of the
#    image skeleton; also creates claude/ on volumes from older images).
# 2. IDE user settings: the chart's required keys win, the tenant's other keys stay.
# 3. (SEED_HOME=1, persistence.home) HOME on the pi volume (the volume's home/ is
#    mounted as /home/coder since 0.1.4, #1452): seed the image's ~/.config and
#    ~/.local skeleton and its top-level dotfiles (~/.bashrc, ~/.profile, …) with
#    cp -n (a tenant file is never overwritten, nothing is ever deleted), ~/.ssh
#    0700, HOME 0700, and the language-pack registry merge.
#    Best effort: a seeding problem must not keep the IDE from starting.
# A failure of 1 fails the init container (set -eu): the IDE would start without
# its agents otherwise.
set -eu
PI_DATA=${PI_DATA:-/data/pi-agent}
IDE_DIR=${IDE_DIR:-/ide}
EXT_DIR=${EXT_DIR:-/extensions}
SEED_DIR=${SEED_DIR:-/seed}
IMAGE_HOME=${IMAGE_HOME:-/home/coder}
PI_SEED_BIN=${PI_SEED_BIN:-/usr/local/bin/pi-seed}
SEED_HOME=${SEED_HOME:-0}

"$PI_SEED_BIN"
chmod 700 "$PI_DATA/claude" 2>/dev/null || true
mkdir -p "$IDE_DIR" "$EXT_DIR"
[ -f "$IDE_DIR/settings.json" ] || cp "$SEED_DIR/settings.json" "$IDE_DIR/settings.json"
tmp=$(mktemp)
# VS Code accepts comments in settings.json, jq does not: a tenant file jq cannot
# parse is left exactly as it is (the IDE must still start).
if jq -S -s '.[0] * .[1]' "$IDE_DIR/settings.json" "$SEED_DIR/settings.json" > "$tmp"; then
  mv "$tmp" "$IDE_DIR/settings.json"
else
  echo "pi-seed: $IDE_DIR/settings.json is not plain JSON (comments?); required settings not merged (continuing)"
fi

# pi default model (#1378). The image's pi-seed writes $PI_DATA/settings.json only
# when the file is absent; a store where pi already wrote settings.json (theme, …)
# but never chose a model would keep pi's own pick (anthropic first → 401 with an
# OpenRouter-only key). Fill BOTH keys only when NEITHER is set — never override a
# choice; keep the file's mode (pi keeps it 0600). Best effort.
PS=$PI_DATA/settings.json
if [ -n "${PI_DEFAULT_MODEL:-}" ] && [ -f "$PS" ]; then
  if jq -e 'type == "object" and (has("defaultProvider") | not) and (has("defaultModel") | not)' "$PS" >/dev/null 2>&1; then
    { jq --arg p "${PI_DEFAULT_PROVIDER:-openai-codex}" --arg m "$PI_DEFAULT_MODEL" \
        '. + {defaultProvider: $p, defaultModel: $m}' "$PS" > "$tmp" && cat "$tmp" > "$PS"; } \
      || echo "pi-seed: could not add the default pi model to settings.json (continuing)"
  fi
fi

if [ "$SEED_HOME" = 1 ]; then
  H=$PI_DATA/home
  mkdir -p "$H/.config" "$H/.local/bin" "$H/.local/share/code-server"
  # ~/.ssh holds the tenant's private keys: created 0700, and kept 0700.
  [ -d "$H/.ssh" ] || mkdir -m 700 "$H/.ssh"
  chmod 700 "$H/.ssh" || echo "pi-seed: could not set ~/.ssh to 0700 (continuing)"
  # code-server reads its config from the chart's read-only CODE_SERVER_CONFIG, never
  # from ~/.config/code-server (a tenant-writable config.yaml must not be able to turn
  # the password login off): the image's stale config.yaml is not seeded.
  (cd "$IMAGE_HOME/.config" && find . -mindepth 1 -maxdepth 1 ! -name code-server -exec cp -an {} "$H/.config/" \;) \
    || echo "pi-seed: could not seed ~/.config (continuing)"
  cp -an "$IMAGE_HOME/.local/." "$H/.local/" || echo "pi-seed: could not seed ~/.local (continuing)"
  # #1452: the rest of the image's HOME root (~/.bashrc, ~/.profile, ~/.bash_logout,
  # whatever a newer image adds), no-clobber. Not: the directories handled here
  # (.config .local .ssh), ~/.cache (an emptyDir), and the image's links INTO this
  # directory (~/.gitconfig, ~/.bash_history, ~/.pi -> /data/pi-agent/home/...):
  # copied here they would be links to themselves.
  for f in "$IMAGE_HOME"/.[!.]* "$IMAGE_HOME"/..?* "$IMAGE_HOME"/*; do
    { [ -e "$f" ] || [ -L "$f" ]; } || continue
    n=${f##*/}
    case $n in .config|.local|.ssh|.cache) continue ;; esac
    if [ -L "$f" ]; then
      case $(readlink "$f") in "$H"|"$H"/*) continue ;; esac
    fi
    cp -an "$f" "$H/" || echo "pi-seed: could not seed ~/$n (continuing)"
  done
  # The image's HOME is 0700; so is the volume's (it is the tenant's HOME now).
  chmod 700 "$H" || echo "pi-seed: could not set HOME to 0700 (continuing)"
  # code-server's language-pack registry: the image's entries (the built-in zh-hant
  # pack, absolute paths of THIS image) win over the volume's (an older image's
  # paths); a pack the tenant installed keeps its own entry.
  LP=$IMAGE_HOME/.local/share/code-server/languagepacks.json
  VLP=$H/.local/share/code-server/languagepacks.json
  if [ -f "$LP" ]; then
    if jq -e 'type == "object"' "$VLP" >/dev/null 2>&1; then
      { jq -s '.[0] * .[1]' "$VLP" "$LP" > "$tmp" && mv "$tmp" "$VLP"; } || echo "pi-seed: could not merge languagepacks.json (continuing)"
    else
      cp "$LP" "$VLP" || echo "pi-seed: could not seed languagepacks.json (continuing)"
    fi
  fi
fi
rm -f "$tmp"
