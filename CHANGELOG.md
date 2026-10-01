# Changelog

## 1.1.0 — 2026-10-01

Resync to chart `0.1.1` (woow-paas-charts `8d6e2761`) and paas-odoo-ci
`af106ce2`:

- The ACP chat sidebar lists only the agents this image ships (`pi`, `claude`):
  the image empties ACP Client's built-in default agent list (GitHub Copilot,
  Gemini CLI, Codex CLI, …, none installed), which VS Code would otherwise merge
  into the tenant's settings.
- No Copilot: the image drops the built-in GitHub Copilot Chat extension, and the
  chart's required settings add `chat.disableAIFeatures`.

## 1.0.0 — 2026-10-01

This repository becomes a **read-only mirror of the WOOW PaaS code-server cloud
service** (`woow-paas/woow-paas-charts` `charts/code-server/`, chart `0.1.0`, and
`woow-paas/paas-odoo-ci` `code-server/`; code-server 4.139.1, pi 0.99.1, Claude
Code 2.1.285). See [MIRROR.md](MIRROR.md).

- `chart/`: per-tenant chart — code-server's own password login from a
  platform-managed Secret (no auth-proxy), optional Anthropic / OpenRouter keys
  and Git token, pi-seed initContainer, workspace + pi-data PVCs, runtime
  extensions kept on the tenant volume, release-prefixed names, non-root,
  default-deny NetworkPolicy.
- `image/`: thin PaaS layer on the podman image (by digest): pinned extensions
  in the built-in dir, zh-hant language pack, omnigent CLI. Built and published
  by paas-odoo-ci behind a prod approval gate, never from here.
- `PARITY_CONTRACT.md` 1.2: the k3s leg of the podman / HA / k3s trio is now the
  PaaS cloud service (same file in all three repositories).
- `scripts/sync-from-gitea.sh` resyncs `chart/`, `image/` and the generated
  block of MIRROR.md.
- Removed the single-instance package (own cloudflared, rendered manifests,
  apply/drift scripts, tests, values). It is preserved on
  `legacy/k3s-single-instance` and tag `legacy-v0.1.0`.
