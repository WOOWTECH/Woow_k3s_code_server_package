# code-server — PaaS cloud-service image (browser VS Code + pi + Claude Code).
#
# Thin derivative of the WOOWTECH podman image (WOOWTECH/Woow_podman_code_server_package,
# PARITY_CONTRACT 1.1: code-server 4.139.1, pi 0.99.1 + pi-acp 0.0.34, Claude Code
# 2.1.285 + claude-agent-acp 0.84.0, ACP Client 0.2.0 + the Claude Code extension).
# Upstream is consumed AS-IS by digest; this layer only adds what the PaaS needs:
#   1. the pinned extensions move to code-server's BUILT-IN extensions dir, because the
#      chart mounts the tenant volume over the user extensions dir (so extensions the
#      tenant installs at runtime survive restarts) and would otherwise hide them
#   2. the Traditional Chinese language pack, also built in (chart passes --locale zh-tw)
#   3. the omnigent CLI (uv tool, Python 3.12) so the IDE can join an Omnigent service in
#      the same workspace as a host (`omnigent login <url>` + `omnigent host`); not started
#      automatically. Its Claude Agent SDK uses the image's `claude` instead of shipping a
#      second 200 MB copy.
# Chart: woow-paas-charts charts/code-server (code-server's own password login, no proxy).
# Registry: jcr-prod.woowtech.io/woow-paas-docker-local/code-server:{tag}.
#
# The workflow overrides BASE with the JCR mirror of the same digest (the cluster's
# ghcr connections are throttled); bump = change the tag AND the digest together.
ARG BASE=ghcr.io/woowtech/woow-code-server-amd64:main-9f38fb0@sha256:fa0ddc38eb3b86c77fdda8e8ec1e85f18499a85975667483d56bf9dd8b4adef6
FROM ${BASE}

ARG ACP_CLIENT_VERSION=0.2.0
ARG CLAUDE_CODE_EXTENSION_VERSION=2.1.285
ARG LANGUAGE_PACK_VERSION=1.131.0
ARG UV_VERSION=0.12.20
ARG UV_SHA256=6590717592ace991ff83a63fef799e3ad9d33ecc8f96c5d6bdd732496e79337f
ARG OMNIGENT_VERSION=0.16.0

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
      src=$(find "$USERDIR" -mindepth 1 -maxdepth 1 -type d -name "${id}*" | head -n1); \
      test -n "$src" || { echo "missing pinned extension ${id} in ${USERDIR}"; exit 1; }; \
      mv "$src" "$BUILTIN/$(basename "$src")"; \
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

# 3. omnigent CLI in /opt/omnigent (image layer; the Python it needs is uv-managed
# 3.12 because the base is Debian 12 / Python 3.11). The Claude Agent SDK falls back
# to `claude` on PATH when its bundled CLI is absent — that is /usr/bin/claude, the
# same pinned Claude Code the terminal and the sidebar use. Its login tokens, host
# identity and config live on the pi volume (OMNIGENT_CONFIG_HOME / _DATA_DIR), so a
# joined host keeps its identity across restarts; $HOME itself is not persisted.
# The cluster's github.com downloads get reset mid-stream (run 11909): uv is fetched with
# retries and checked against its release sha256; uv's own Python download retries too.
# The UV_* paths are build-only: a tenant's own `uv tool install` goes to ~/.local.
ENV OMNIGENT_CONFIG_HOME=/data/pi-agent/omnigent \
    OMNIGENT_DATA_DIR=/data/pi-agent/omnigent
RUN set -eu; \
    export UV_PYTHON_INSTALL_DIR=/opt/omnigent/python UV_TOOL_DIR=/opt/omnigent/tools \
           UV_TOOL_BIN_DIR=/usr/local/bin UV_NO_CACHE=1 \
           OMNIGENT_CONFIG_HOME=/tmp/og OMNIGENT_DATA_DIR=/tmp/og \
           UV_HTTP_RETRIES=8 UV_HTTP_TIMEOUT=120; \
    curl -fsSL --retry 8 --retry-all-errors --retry-delay 5 -o /tmp/uv.tar.gz \
      "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-x86_64-unknown-linux-gnu.tar.gz"; \
    echo "${UV_SHA256}  /tmp/uv.tar.gz" | sha256sum -c -; \
    tar xzf /tmp/uv.tar.gz -C /tmp; \
    install -m 0755 /tmp/uv-x86_64-unknown-linux-gnu/uv /tmp/uv-x86_64-unknown-linux-gnu/uvx /usr/local/bin/; \
    rm -rf /tmp/uv-* /tmp/uv.tar.gz; \
    uv --version | grep -q "^uv ${UV_VERSION}"; \
    uv tool install --python 3.12 --python-preference only-managed "omnigent==${OMNIGENT_VERSION}"; \
    SDK=$(find /opt/omnigent/tools/omnigent -type d -path '*site-packages/claude_agent_sdk' | head -n1); \
    test -n "$SDK"; \
    rm -f "$SDK/_bundled/claude"; \
    omnigent --version 2>&1 | grep -q "${OMNIGENT_VERSION}" || { omnigent --version; exit 1; }; \
    /opt/omnigent/tools/omnigent/bin/python -c "import claude_agent_sdk, omnigent"; \
    rm -rf /tmp/og; \
    chmod -R a+rX /opt/omnigent

USER coder
