# Woow code-server (WOOW PaaS cloud service)

[繁體中文](README_zh-TW.md)

Browser VS Code with Pi, Claude Code and Codex, deployed as a private service per tenant.
This branch mirrors the three-agent candidate. It does not mean the PaaS marketplace
or existing tenants have been upgraded; publishing the image still requires the Gitea release gate.

This is a **read-only source mirror**. Edit `charts/code-server` in
`woow-paas/woow-paas-charts` and `code-server` in `woow-paas/paas-odoo-ci` on Gitea.
[MIRROR.md](MIRROR.md) records the exact commits and base digest.

| Capability | Candidate behavior |
|---|---|
| IDE | code-server 4.139.1, Traditional Chinese UI, pinned ACP and Claude Code extensions |
| Agents | Pi 0.99.1, Claude Code 2.1.285, Codex CLI 0.167.0 / ACP 2.6.0; terminal and ACP sidebar |
| Shared skills | `/data/pi-agent/skills`; all three agents resolve the same directory |
| Shared MCP | `/data/pi-agent/shared/mcp.json`; run `woow-agent-sync`, then reconnect sessions |
| Model login | Separate per agent: `pi login`, `claude auth login`, `codex login --device-auth` |
| IDE login | Platform-managed password; the cookie proxy adds HttpOnly and Secure |
| Persistence | Separate workspace and agent-data PVCs; HOME, settings and user extensions survive restarts |
| Integrations | Omnigent host, optional model/Git keys and workspace LiteLLM URL; see chart documentation |

Shared MCP definitions do not share provider or OAuth logins, tool approvals, or conversation context.
Switching agents disconnects the previous ACP session and clears the visible chat.
Unsupported MCP restrictions and conflicting skills stop migration with a diagnostic.
No credentials or private endpoints are bundled in the image.

The normal T1 template currently uses 2 vCPU / 8 GiB RAM and 20 GiB storage
(workspace 16 GiB plus agent data 4 GiB). The platform service page is authoritative for the selected plan.

The browser reaches the ClusterIP service through the platform tunnel. Inside the pod,
nginx forwards to code-server's private Unix socket. The IDE runs as uid 1000 with
no service-account token; NetworkPolicy limits network access. See
[chart/README.md](chart/README.md) for password behavior, secret visibility, persistent HOME,
Omnigent, LiteLLM, and upgrade details.

[image/README.md](image/README.md) explains the thin PaaS derivative of the pinned
Podman image. [PARITY_CONTRACT.md](PARITY_CONTRACT.md) records the shared candidate baseline.
The chart and image must be upgraded together: the previous image lacks `codex-code`.

To join Omnigent, run `omnigent login <server URL>` in the IDE terminal. When the
chart's Omnigent host integration is enabled, its supervisor starts the host after login
and restarts it after a pod restart. Check `omnigent-host-status`; do not start a second host.

## Sync

```bash
scripts/sync-from-gitea.sh                         # authoritative main branches
scripts/sync-from-gitea.sh <charts-ref> <ci-ref>    # explicit reviewed/candidate commits
```

CI here checks the mirror and chart. Image publication remains in Gitea.

The old single-instance package is preserved on
[`legacy/k3s-single-instance`](../../tree/legacy/k3s-single-instance) and `legacy-v0.1.0`.

[MIT License](LICENSE)
