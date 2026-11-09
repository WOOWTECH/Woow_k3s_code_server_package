# code-server — PaaS cloud-service image (browser VS Code + Pi + Claude Code + Codex).
#
# Thin derivative of the WOOWTECH podman image (WOOWTECH/Woow_podman_code_server_package,
# PARITY_CONTRACT 1.3: code-server 4.139.1, pi 0.99.1 + pi-acp 0.0.34, Claude Code
# 2.1.285 + claude-agent-acp 0.84.0, ACP Client 0.2.0 + the Claude Code extension).
# Upstream is consumed AS-IS by digest; this layer only adds what the PaaS needs:
#   1. the pinned extensions move to code-server's BUILT-IN extensions dir, because the
#      chart mounts the tenant volume over the user extensions dir (so extensions the
#      tenant installs at runtime survive restarts) and would otherwise hide them
#   2. the Traditional Chinese language pack, also built in (chart passes --locale zh-tw)
#   3. the omnigent CLI (uv-managed Python 3.12 venv, every package pinned with hashes in
#      omnigent-requirements.lock, bytecode compiled at build) so the IDE can join an
#      Omnigent service as a host. The host runs INSIDE the code-server container (no
#      sidecar): step 8 puts the shared kit's omnigent-host-entry stub in the ENTRYPOINT;
#      when the chart mounts the kit (woow-paas-charts shared/omnigent-host) the stub
#      starts the kit's launcher, which runs the supervisor in the background and then
#      code-server. Its Claude Agent SDK uses the image's `claude` instead of shipping a
#      second 200 MB copy.
#   4. tmux (pinned 3.5a-3, >= 3.3): Omnigent runs its native Claude / pi harnesses inside
#      tmux terminals on the host, and refuses to launch them without it
#   5. an interactive-shell hook: /etc/bash.bashrc sources /etc/woow/bashrc.d/*.sh; the
#      image's omnigent-host.sh there sources the kit's omnigent-host-profile.sh when the
#      chart mounted it (kit `bin` on PATH for `kubectl exec` shells, and
#      `omnigent-host-status --motd`, which prints only when the tenant must act)
#   6. developer tools (QA CS-09): pytest (Debian python3-pytest, pinned), ruff (pinned with
#      hashes in devtools-requirements.lock), fonts-noto-cjk + fontconfig (CJK text in
#      rendered documents, charts and screenshots)
#   7. HOME state that survives pod restarts (QA CS-01 / CSV-M1 / CSV-M3): ~/.gitconfig and
#      ~/.bash_history are links into the pi volume (/data/pi-agent/home, where pi-seed
#      already keeps ~/.pi); the chart mounts ~/.ssh, ~/.config and ~/.local from the same
#      volume and ~/.cache as a size-limited emptyDir. `npm i -g` installs into ~/.local
#      (NPM_CONFIG_PREFIX; ~/.local/bin on PATH, also for `uv tool install`), and npm's
#      cache moves to ~/.cache/npm. ~/.local/bin comes LAST on PATH: it survives restarts
#      and image upgrades, so a `claude`, `pi`, `omnigent`, `dumb-init`, `fixuid`, … put
#      there must never shadow the image's pinned one (the upstream entrypoint looks
#      fixuid / dumb-init up on PATH before it starts code-server). The base image's
#      ~/.config/code-server/config.yaml (a password generated at its build, the same in
#      every container) is removed: the chart points CODE_SERVER_CONFIG at its own
#      read-only config (auth: password), and code-server ignores ~/.config there.
#      The IDE terminal is a LOGIN shell (/etc/profile resets PATH, then profile.d and
#      ~/.profile rebuild it), so the same order is applied there: ~/.profile and
#      /etc/profile.d/npm-global.sh APPEND ~/bin, ~/.local/bin and the two npm-global
#      bins (all tenant-writable, two of them persistent) instead of prepending them;
#      the kit's guard (/etc/omnigent-host/bin, put first by the bashrc.d hook) then
#      stays ahead of everything the tenant can write.
#   8. ENTRYPOINT dumb-init -> omnigent-host-entry -> woow-code-server-entry -> /usr/bin/entrypoint.sh: without the kit mounted the stub just execs the upstream entrypoint.
# Chart: woow-paas-charts charts/code-server (code-server's own password login, no proxy).
# Registry: jcr-prod.woowtech.io/woow-paas-docker-local/code-server:{tag}.
#
# The workflow overrides BASE with the JCR mirror of the same digest (the cluster's
# ghcr connections are throttled); bump = change the tag AND the digest together.
ARG BASE=ghcr.io/woowtech/woow-code-server-amd64:main-5d91687@sha256:aeb8bca7b8f7fc679b95e9d9891b1ec131ddc3be87758a2d7045f80fafee03e1
FROM docker.io/library/node:22.23.2-bookworm-slim AS connector-vsix
WORKDIR /build/extensions
RUN apt-get update && apt-get install -y --no-install-recommends python3 && rm -rf /var/lib/apt/lists/*
COPY extensions/ ./
RUN npm ci --ignore-scripts --no-audit --no-fund && npm run package

FROM ${BASE}

ARG ACP_CLIENT_VERSION=0.2.0
ARG CLAUDE_CODE_EXTENSION_VERSION=2.1.285
ARG LANGUAGE_PACK_VERSION=1.131.0
ARG UV_VERSION=0.12.20
ARG UV_SHA256=6590717592ace991ff83a63fef799e3ad9d33ecc8f96c5d6bdd732496e79337f
# omnigent and its dependencies come from omnigent-requirements.lock (hashes); this ARG
# only cross-checks the lock. PYTHON_VERSION: uv verifies the managed CPython download.
ARG OMNIGENT_VERSION=0.16.0
ARG PYTHON_VERSION=3.12.14
ARG TMUX_VERSION=3.5a-3

USER root

# 1 + 2. built-in extensions. code-server scans lib/vscode/extensions as system
# extensions: always loaded, independent of the user extensions dir, not removable
# from the UI (the pins stay pinned). The language pack targets ^1.131 (Open VSX's
# newest); on Code 1.139 strings added since then fall back to English.
RUN set -eu; \
    BUILTIN=/usr/lib/code-server/lib/vscode/extensions; \
    USERDIR=/home/coder/.local/share/code-server/extensions; \
    test -d "$BUILTIN"; \
    for id in "formulahendry.acp-client-${ACP_CLIENT_VERSION}" "anthropic.claude-code-${CLAUDE_CODE_EXTENSION_VERSION}"; do \
      src=$(find "$BUILTIN" -mindepth 1 -maxdepth 1 -type d -name "${id}*" | head -n1); \
      if [ -z "$src" ]; then \
        src=$(find "$USERDIR" -mindepth 1 -maxdepth 1 -type d -name "${id}*" | head -n1); \
        test -n "$src" || { echo "missing pinned extension ${id}"; exit 1; }; \
        mv "$src" "$BUILTIN/$(basename "$src")"; \
      fi; \
    done; \
    rm -rf "$USERDIR"; \
    tmp=$(mktemp -d); \
    SERVICE_URL=https://open-vsx.org/vscode/gallery ITEM_URL=https://open-vsx.org/vscode/item \
      code-server --extensions-dir "$tmp" --user-data-dir "$tmp/ud" \
      --install-extension "ms-ceintl.vscode-language-pack-zh-hant@${LANGUAGE_PACK_VERSION}"; \
    lp=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d -name "ms-ceintl.vscode-language-pack-zh-hant-${LANGUAGE_PACK_VERSION}*" | head -n1); \
    test -n "$lp"; \
    mv "$lp" "$BUILTIN/"; \
    rm -rf "$tmp"; \
    chown -R root:root "$BUILTIN"; \
    chmod -R a+rX "$BUILTIN"; \
    CC=$(find "$BUILTIN" -mindepth 1 -maxdepth 1 -type d -name "anthropic.claude-code-${CLAUDE_CODE_EXTENSION_VERSION}*"); \
    find "$CC/resources" -type f -name claude -exec chmod 0755 {} +; \
    for d in "formulahendry.acp-client-${ACP_CLIENT_VERSION}" "anthropic.claude-code-${CLAUDE_CODE_EXTENSION_VERSION}" "ms-ceintl.vscode-language-pack-zh-hant-${LANGUAGE_PACK_VERSION}"; do \
      m=$(find "$BUILTIN" -mindepth 2 -maxdepth 2 -path "*/${d}*/package.json" | head -n1); \
      test -n "$m" || { echo "built-in ${d} has no package.json"; exit 1; }; \
      v=$(jq -r .version "$m"); test "$v" = "${d##*-}" || { echo "${d}: package.json says ${v}"; exit 1; }; \
    done; \
    mkdir -p "$USERDIR"; chown coder:coder "$USERDIR"

# 2b. register the built-in language pack. VS Code writes <user-data-dir>/languagepacks.json
# only from its install/uninstall hooks (NativeLanguagePackService.update), never at
# startup, so a pack that is built in rather than installed is invisible to --locale
# (verified: run 11905 served no NLS bundle). Write the file exactly as
# LanguagePacksCache.createLanguagePacksFromExtension would: languageId → label,
# extension identifier (lower-case publisher.name) + version, translations id → absolute
# path, hash = md5(id + version). A later install by the tenant re-runs update() over
# getInstalled() (system + user), which reproduces this entry. The user-data-dir itself
# (/home/coder/.local/share/code-server) is image-layer; only User/ and extensions/ are
# on the volume.
RUN set -eu; \
    LP=$(find /usr/lib/code-server/lib/vscode/extensions -mindepth 1 -maxdepth 1 -type d -name "ms-ceintl.vscode-language-pack-zh-hant-${LANGUAGE_PACK_VERSION}*" | head -n1); \
    test -n "$LP"; \
    UD=/home/coder/.local/share/code-server; \
    node -e ' \
      const fs = require("fs"), path = require("path"), crypto = require("crypto"); \
      const dir = process.argv[1], out = process.argv[2]; \
      const m = JSON.parse(fs.readFileSync(path.join(dir, "package.json"), "utf8")); \
      const id = (m.publisher + "." + m.name).toLowerCase(); \
      const packs = {}; \
      for (const l of (m.contributes && m.contributes.localizations) || []) { \
        const p = packs[l.languageId] || (packs[l.languageId] = { hash: "", extensions: [], translations: {}, label: l.localizedLanguageName || l.languageName }); \
        p.extensions.push({ extensionIdentifier: { id }, version: m.version }); \
        for (const t of l.translations) p.translations[t.id] = path.join(dir, t.path); \
      } \
      for (const k of Object.keys(packs)) { \
        const h = crypto.createHash("md5"); \
        for (const e of packs[k].extensions) h.update(e.extensionIdentifier.id).update(e.version); \
        packs[k].hash = h.digest("hex"); \
      } \
      if (!packs["zh-tw"] || !fs.existsSync(packs["zh-tw"].translations.vscode)) { console.error("no zh-tw vscode translations"); process.exit(1); } \
      fs.writeFileSync(out, JSON.stringify(packs)); \
    ' "$LP" "$UD/languagepacks.json"; \
    chown coder:coder "$UD/languagepacks.json"; \
    jq -e '."zh-tw".translations.vscode' "$UD/languagepacks.json"

# 2c. the sidebar lists only the agents this image ships (pi, claude, codex), and no Copilot.
# ACP Client's agent list is Object.keys(acp.agents), and VS Code deep-merges an object
# setting's package.json default with the user value, so its eleven built-in entries
# (GitHub Copilot, Gemini CLI, …, which are not installed here) can't be removed from
# settings.json — empty the default instead; the chart seeds pi + claude + codex and a tenant's
# own "Add Agent" entries still land in settings.json. The built-in GitHub Copilot Chat
# extension (170 MB) goes too; the chart also sets chat.disableAIFeatures so the core
# chat view doesn't offer to install it.
RUN set -eu; \
    B=/usr/lib/code-server/lib/vscode/extensions; \
    test -f "$B/copilot/package.json"; \
    jq -e '.name == "copilot-chat"' "$B/copilot/package.json" >/dev/null; \
    rm -rf "$B/copilot"; \
    M=$(find "$B" -mindepth 2 -maxdepth 2 -path "*/formulahendry.acp-client-${ACP_CLIENT_VERSION}*/package.json" | head -n1); \
    test -n "$M"; \
    jq -e '[.contributes.configuration | if type == "array" then .[] else . end | .properties["acp.agents"].default | select(. != null) | keys | length] | add > 0' "$M" >/dev/null; \
    tmp=$(mktemp); \
    jq '.contributes.configuration |= (if type == "array" then map(if .properties["acp.agents"] then .properties["acp.agents"].default = {} else . end) else .properties["acp.agents"].default = {} end)' "$M" > "$tmp"; \
    cat "$tmp" > "$M"; rm -f "$tmp"; \
    jq -e '[.contributes.configuration | if type == "array" then .[] else . end | .properties["acp.agents"].default | select(. != null)] == [{}]' "$M" >/dev/null

# 3. omnigent CLI in /opt/omnigent (image layer; the Python it needs is uv-managed 3.12
# because the base's own Python is older). Supply chain: uv itself is checked against its
# release sha256; CPython is uv's managed build (uv verifies its checksum); omnigent and
# every transitive dependency are installed from omnigent-requirements.lock with
# --require-hashes --no-deps (any unpinned or altered package fails the build), and the
# bytecode is compiled here so nothing is written under /opt at runtime. The Claude Agent
# SDK falls back to `claude` on PATH when its bundled CLI is absent — that is
# /usr/bin/claude, the same pinned Claude Code the terminal and the sidebar use. Login
# tokens, host identity and config live on the pi volume (OMNIGENT_CONFIG_HOME /
# _DATA_DIR). The cluster's github.com downloads get reset mid-stream (run 11909): curl
# and uv retry. The UV_* settings are build-only; a tenant's own uv goes to ~/.local.
ENV OMNIGENT_CONFIG_HOME=/data/pi-agent/omnigent \
    OMNIGENT_DATA_DIR=/data/pi-agent/omnigent
COPY omnigent-requirements.lock /tmp/omnigent-requirements.lock
RUN set -eu; \
    export UV_PYTHON_INSTALL_DIR=/opt/omnigent/python UV_PYTHON_PREFERENCE=only-managed \
           UV_NO_CACHE=1 UV_COMPILE_BYTECODE=1 UV_HTTP_RETRIES=8 UV_HTTP_TIMEOUT=120 \
           OMNIGENT_CONFIG_HOME=/tmp/og OMNIGENT_DATA_DIR=/tmp/og; \
    curl -fsSL --retry 8 --retry-all-errors --retry-delay 5 -o /tmp/uv.tar.gz \
      "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-x86_64-unknown-linux-gnu.tar.gz"; \
    echo "${UV_SHA256}  /tmp/uv.tar.gz" | sha256sum -c -; \
    tar xzf /tmp/uv.tar.gz -C /tmp; \
    install -m 0755 /tmp/uv-x86_64-unknown-linux-gnu/uv /tmp/uv-x86_64-unknown-linux-gnu/uvx /usr/local/bin/; \
    rm -rf /tmp/uv-* /tmp/uv.tar.gz; \
    uv --version | grep -q "^uv ${UV_VERSION}"; \
    grep -q "^omnigent==${OMNIGENT_VERSION} " /tmp/omnigent-requirements.lock \
      || { echo "omnigent-requirements.lock does not pin omnigent==${OMNIGENT_VERSION}"; exit 1; }; \
    VENV=/opt/omnigent/tools/omnigent; \
    uv venv --python "${PYTHON_VERSION}" "$VENV"; \
    uv pip install --python "$VENV/bin/python" --require-hashes --no-deps --compile-bytecode \
      -r /tmp/omnigent-requirements.lock; \
    uv pip check --python "$VENV/bin/python"; \
    "$VENV/bin/python" -c "import sys; assert sys.version.split()[0] == '${PYTHON_VERSION}', sys.version"; \
    for s in $("$VENV/bin/python" -c 'import importlib.metadata as m; print(" ".join(e.name for e in m.distribution("omnigent").entry_points if e.group == "console_scripts"))'); do \
      ln -sf "$VENV/bin/$s" "/usr/local/bin/$s"; \
    done; \
    test -x /usr/local/bin/omnigent; \
    SDK=$(find "$VENV" -type d -path '*site-packages/claude_agent_sdk' | head -n1); \
    test -n "$SDK"; \
    rm -f "$SDK/_bundled/claude"; \
    omnigent --version 2>&1 | grep -q "${OMNIGENT_VERSION}" || { omnigent --version; exit 1; }; \
    "$VENV/bin/python" -c "import claude_agent_sdk, omnigent, yaml"; \
    rm -rf /tmp/og /tmp/omnigent-requirements.lock; \
    chmod -R a+rX /opt/omnigent

# 3b. Claude Code's <system-reminder> blocks (CLAUDE.md, auto-memory index, task notifications) share the
# person's role=user transcript record; omnigent 0.16.0 mirrors every block, so the web chat shows a ~19 KB
# "<system-reminder> ..." bubble and the session title is generated from it. Same version-gated exact-anchor
# patch as pi-agent/ (byte-identical copy; fails the build if the omnigent pin moves or anchors drift); unit
# tests run on the patched package; pyc is rewritten because /opt is read-only at runtime.
COPY omnigent-reminder-patch/ /opt/patches/omnigent-reminder-patch/
COPY tests/omnigent-reminder-patch.test.py /opt/patches/tests/omnigent-reminder-patch.test.py
RUN set -eu; \
    VENV=/opt/omnigent/tools/omnigent; \
    SP="$VENV/lib/python3.12/site-packages"; \
    "$VENV/bin/python" /opt/patches/omnigent-reminder-patch/omnigent-reminder-patch.py --site-packages "$SP" --strict; \
    "$VENV/bin/python" /opt/patches/tests/omnigent-reminder-patch.test.py; \
    grep -q 'omnigent-reminder-patch v2' "$SP/omnigent/harnesses/claude_native/bridge.py"; \
    chmod -R a+rX /opt/omnigent

# 4. tmux for Omnigent's native harnesses (claude-native / pi-native launch the agent in a
# runner-owned tmux terminal; omnigent requires tmux >= 3.3 for allow-passthrough). The
# base is Debian 13 (trixie); tmux is pinned to its exact package version so a rebuild
# installs the same tmux (a point release that replaces it fails the build instead of
# silently changing it; bump TMUX_VERSION then). Its libraries (libevent-core,
# libjemalloc2) follow trixie / trixie-security. apt retries: downloads get reset.
RUN set -eu; \
    apt-get -o Acquire::Retries=8 update; \
    DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=8 install -y --no-install-recommends "tmux=${TMUX_VERSION}"; \
    rm -rf /var/lib/apt/lists/*; \
    test "$(dpkg-query -W --showformat='${Version}' tmux)" = "${TMUX_VERSION}"; \
    tmux -V | grep -Eq '^tmux (3\.([3-9]|[1-9][0-9])|[4-9]\.)' || { tmux -V; echo "tmux too old"; exit 1; }; \
    for c in flock setsid; do command -v "$c" >/dev/null || { echo "missing $c"; exit 1; }; done

# 5. interactive-shell hook. Debian's /etc/bash.bashrc returns early for non-interactive
# shells, so this only runs in terminals; it is read by every interactive bash, login or
# not (the IDE terminal is not a login shell, so /etc/profile.d would be missed).
# omnigent-host.sh sources the kit's omnigent-host-profile.sh (mounted by the chart at
# /etc/omnigent-host, shared omnigent-host kit): it puts the kit's bin (the `omnigent`
# guard, omnigent-host-status) first on PATH for shells that do not descend from the
# launcher (kubectl exec) and prints `omnigent-host-status --motd` whenever the tenant has
# to act (not logged in, login expired, reset-id needed, image too old). Without the kit
# mounted it does nothing.
RUN set -eu; \
    mkdir -p /etc/woow/bashrc.d; \
    printf '%s\n' '' \
      '# WOOW PaaS: interactive-shell snippets (image: omnigent-host.sh; charts may add more).' \
      'for _woow_rc in /etc/woow/bashrc.d/*.sh; do [ -r "$_woow_rc" ] && . "$_woow_rc"; done; unset _woow_rc' \
      >> /etc/bash.bashrc; \
    printf '%s\n' \
      '# WOOW PaaS: Omnigent host hook for interactive shells (shared omnigent-host kit,' \
      '# mounted by the chart; PATH + status MOTD; silent without the kit).' \
      '[ -r /etc/omnigent-host/omnigent-host-profile.sh ] && . /etc/omnigent-host/omnigent-host-profile.sh' \
      ':' \
      > /etc/woow/bashrc.d/omnigent-host.sh; \
    chmod 0644 /etc/woow/bashrc.d/omnigent-host.sh; \
    bash -n /etc/bash.bashrc; \
    bash -n /etc/woow/bashrc.d/omnigent-host.sh

# 6. developer tools (QA CS-09). pytest from Debian so `python3 -m pytest` / `pytest` work with
# the system python (PEP 668 blocks pip there); ruff from devtools-requirements.lock (hashes)
# into its own venv on the uv-managed Python 3.12 of step 3; CJK fonts + fontconfig. Debian
# packages are pinned to exact versions like tmux (a point release fails the build).
ARG PYTEST_DEB_VERSION=8.3.5-2
ARG FONTS_NOTO_CJK_VERSION=1:20240730+repack1-1
ARG FONTCONFIG_VERSION=2.15.0-2.3
ARG RUFF_VERSION=0.16.10
COPY devtools-requirements.lock /tmp/devtools-requirements.lock
RUN set -eu; \
    apt-get -o Acquire::Retries=8 update; \
    DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=8 install -y --no-install-recommends \
      "python3-pytest=${PYTEST_DEB_VERSION}" "fonts-noto-cjk=${FONTS_NOTO_CJK_VERSION}" "fontconfig=${FONTCONFIG_VERSION}"; \
    rm -rf /var/lib/apt/lists/*; \
    test "$(dpkg-query -W --showformat='${Version}' python3-pytest)" = "${PYTEST_DEB_VERSION}"; \
    test "$(dpkg-query -W --showformat='${Version}' fonts-noto-cjk)" = "${FONTS_NOTO_CJK_VERSION}"; \
    test "$(dpkg-query -W --showformat='${Version}' fontconfig)" = "${FONTCONFIG_VERSION}"; \
    python3 -m pytest --version; \
    fc-list :lang=zh-tw family | grep -q 'Noto Sans CJK' || { echo "no Noto Sans CJK for zh-tw"; exit 1; }; \
    grep -q "^ruff==${RUFF_VERSION} " /tmp/devtools-requirements.lock \
      || { echo "devtools-requirements.lock does not pin ruff==${RUFF_VERSION}"; exit 1; }; \
    export UV_PYTHON_INSTALL_DIR=/opt/omnigent/python UV_PYTHON_PREFERENCE=only-managed UV_NO_CACHE=1 \
           UV_PYTHON_DOWNLOADS=never UV_HTTP_RETRIES=8 UV_HTTP_TIMEOUT=120; \
    uv venv --python "${PYTHON_VERSION}" /opt/devtools; \
    uv pip install --python /opt/devtools/bin/python --require-hashes --no-deps -r /tmp/devtools-requirements.lock; \
    ln -sf /opt/devtools/bin/ruff /usr/local/bin/ruff; \
    ruff --version | grep -qx "ruff ${RUFF_VERSION}" || { ruff --version; exit 1; }; \
    rm -f /tmp/devtools-requirements.lock; \
    chmod -R a+rX /opt/devtools

# 7. HOME state on the pi volume. The chart mounts /data/pi-agent (pi-data PVC) and, from the
# same volume, ~/.ssh, ~/.config, ~/.local (+ the IDE's User/ and extensions/ inside it) and
# ~/.cache (emptyDir). The two single files are links into /data/pi-agent/home (pi-seed
# already keeps ~/.pi there): git writes ~/.gitconfig through the link (lockfile next to the
# target) and bash appends history through it; the chart also sets GIT_CONFIG_GLOBAL and
# HISTFILE to the same files. Without a volume (docker run) the links dangle and git / bash
# behave as if the files did not exist.
# ~/.local/bin is APPENDED to PATH (after the system dirs): see 7. in the header.
ENV NPM_CONFIG_PREFIX=/home/coder/.local \
    NPM_CONFIG_CACHE=/home/coder/.cache/npm \
    PATH=${PATH}:/home/coder/.local/bin
RUN set -eu; \
    rm -rf /home/coder/.config/code-server; \
    P=/home/coder/.profile; N=/etc/profile.d/npm-global.sh; \
    grep -qxF '    PATH="$HOME/bin:$PATH"' "$P"; grep -qxF '    PATH="$HOME/.local/bin:$PATH"' "$P"; \
    grep -qxF '        *) PATH="${_npm_bin}:${PATH}" ;;' "$N"; \
    sed -i -e 's|^    PATH="$HOME/bin:$PATH"$|    PATH="$PATH:$HOME/bin"|' \
           -e 's|^    PATH="$HOME/.local/bin:$PATH"$|    PATH="$PATH:$HOME/.local/bin"|' "$P"; \
    sed -i -e 's|^        \*) PATH="${_npm_bin}:${PATH}" ;;$|        *) PATH="${PATH}:${_npm_bin}" ;;|' "$N"; \
    grep -qxF '    PATH="$PATH:$HOME/bin"' "$P"; grep -qxF '    PATH="$PATH:$HOME/.local/bin"' "$P"; \
    grep -qxF '        *) PATH="${PATH}:${_npm_bin}" ;;' "$N"; \
    ! grep -qE 'PATH="[$][{]?(HOME|_npm_bin)' "$P" "$N"; \
    chown coder:coder "$P"; chmod 0644 "$P" "$N"; \
    for f in .gitconfig .bash_history; do \
      test ! -e "/home/coder/$f"; \
      ln -s "/data/pi-agent/home/$f" "/home/coder/$f"; \
      chown -h coder:coder "/home/coder/$f"; \
    done; \
    mkdir -p /home/coder/.local/bin /home/coder/.ssh /home/coder/.cache; \
    chmod 700 /home/coder/.ssh; \
    chown coder:coder /home/coder/.local /home/coder/.local/bin /home/coder/.ssh /home/coder/.cache

# 8. entrypoint: the shared kit's image stub between dumb-init and the upstream entrypoint
# (woow-paas-charts shared/omnigent-host/image/omnigent-host-entry, byte-identical; verify
# compares the sha256). With the kit mounted (chart omnigentHost.enabled) it runs
# /etc/omnigent-host/omnigent-host-launch, which starts the omnigent-host supervisor in the
# background (own session) and then the upstream entrypoint (fixuid, /entrypoint.d,
# `dumb-init code-server`) in its own session; SIGTERM stops the host first, then
# code-server. Without the kit it execs the upstream entrypoint unchanged. dumb-init stays
# PID 1 and reaps whatever Omnigent sessions leave behind. The chart's args (--locale,
# --trusted-origins) are appended as before.
ARG OMNIGENT_HOST_ENTRY_SHA256=ad88912f898c24fadb8704f731adb0eb5bca98969af9f5d4a15fcfd51ad6007b
COPY omnigent-host-entry /usr/local/bin/omnigent-host-entry
RUN set -eu; \
    echo "${OMNIGENT_HOST_ENTRY_SHA256}  /usr/local/bin/omnigent-host-entry" | sha256sum -c -; \
    chmod 0755 /usr/local/bin/omnigent-host-entry; \
    sh -n /usr/local/bin/omnigent-host-entry; \
    test -x /usr/bin/dumb-init; test -x /usr/bin/entrypoint.sh; test -x /usr/local/bin/woow-code-server-entry; test -x /usr/local/bin/codex-code
USER root
COPY connectors/ /opt/woow-connectors/
COPY --from=connector-vsix /build/extensions/dist/ /opt/woow-connector-vsix/
COPY rootfs/usr/local/bin/ /usr/local/bin/
RUN chmod +x /usr/local/bin/woow-connectors /usr/local/bin/woow-connectors-service /usr/local/bin/woow-code-server-entry \
 && bash /opt/woow-connectors/paseo/install-runtime.sh /opt/woow-connectors/paseo \
 && /opt/omnigent/tools/omnigent/bin/python /opt/woow-connectors/omnigent/patch-runtime.py \
 && chmod -R a+rX /opt/woow-connectors /opt/omnigent
ENV WOOW_OMNIGENT_SHARED_TOOLS=1
USER coder
ENTRYPOINT ["/usr/bin/dumb-init", "--", "python3", "/opt/woow-connectors/omnigent/kit-entry.py", "/usr/local/bin/omnigent-host-entry", "/usr/local/bin/woow-code-server-entry", "--bind-addr", "0.0.0.0:8080", "."]
