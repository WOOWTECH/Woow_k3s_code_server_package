# Woow code-server (WOOW PaaS cloud service)

**繁體中文說明：[README_zh-TW.md](README_zh-TW.md)**

Browser VS Code ([code-server](https://github.com/coder/code-server)) with the
**pi coding agent** and **Claude Code** built in, as a per-tenant cloud service
on the WOOW PaaS platform.

> **This repository is a read-only mirror.** The source of truth is the
> internal Gitea (`woow-paas/woow-paas-charts` `charts/code-server/` and
> `woow-paas/paas-odoo-ci` `code-server/`). See [MIRROR.md](MIRROR.md) for the
> exact source commits. Do not open changes against `chart/` or `image/` here.

## What you get

| | |
|---|---|
| **IDE** | code-server 4.139.1 (Code 1.139.1), Traditional Chinese UI by default |
| **AI assistants** | pi 0.99.1 and Claude Code 2.1.285 — in the terminal (`pi`, `claude`), in the ACP chat sidebar (agents `pi` and `claude`), plus the official Claude Code extension |
| **Login** | code-server's own password login — no username. The password is shown once at launch; reset it or set your own from the service page ("Admin Credentials"). The service restarts in about a minute |
| **Model access** | Sign in once per assistant in the terminal (`pi login`, `claude`), or fill the optional Anthropic / OpenRouter API key on the service page. With only an OpenRouter key, Claude Code is routed through OpenRouter as well |
| **Git** | Optional Git token on the service page; git offers it to github.com automatically. It is never written to disk |
| **Storage** | Workspace 20 GB (`/workspace`) + 5 GB for pi / Claude Code logins, sessions, IDE settings and the extensions you install yourself — all kept across restarts |
| **omnigent** | The `omnigent` CLI is included, so this IDE can join an Omnigent service as a machine (below) |
| **Size / price** | 2 vCPU / 4 GB RAM / 25 GB disk, 4,500 pts/month (7-day trial) |

## Architecture

```
tenant browser ──▶ Cloudflare tunnel (paas-cs-<ws>-<id>.woowtech.io)
                        │
                        ▼
              Service <release>-code-server :8080
                        │
   ┌────────────────────┴───────────────────────────────────┐
   │ Deployment <release>-code-server (1 replica, Recreate) │
   │  init  pi-seed: seed /data/pi-agent, merge settings    │
   │  main  code-server --locale zh-tw                      │
   │        --trusted-origins <public host>                 │
   │        PASSWORD ← Secret <release>-code-server-secret  │
   └───────────┬───────────────────────────┬────────────────┘
               ▼                           ▼
   PVC <release>-code-server-workspace   PVC <release>-code-server-pi-data
   /workspace (20 Gi)                    /data/pi-agent + IDE User/ + extensions/ (5 Gi)
```

- Non-root (uid 1000), all capabilities dropped, no service-account token.
- Default-deny NetworkPolicy: egress to DNS, the public internet and the same
  namespace only — no private networks, no cluster API.
- The chart never changes the pod template when the password changes, so the
  platform's reset is `helm upgrade` + a restart.

### Image

[`image/`](image/) is a thin layer on the WOOWTECH podman image
([`Woow_podman_code_server_package`](https://github.com/WOOWTECH/Woow_podman_code_server_package),
consumed by digest). It moves the pinned extensions (ACP Client, Claude Code)
into code-server's built-in extensions dir, adds the Traditional Chinese
language pack and the `omnigent` CLI. It is built, verified and published by
`woow-paas/paas-odoo-ci` behind a prod approval gate — never from this
repository.

## Parity with the podman and Home Assistant packages

This is the **k3s leg** of the WOOWTECH code-server trio (podman package, Home
Assistant add-on, this cloud service). The three share one pinned baseline —
code-server, pi, pi-acp, Claude Code, the ACP wiring and the pi state layout —
defined in [PARITY_CONTRACT.md](PARITY_CONTRACT.md) (identical in all three
repositories). The Traditional Chinese UI, the platform-managed password, the
optional keys, persistent runtime extensions and the omnigent CLI are
PaaS-only additions (contract §6).

## Connecting to Omnigent

An Omnigent service **in the same workspace** is reachable at its in-cluster
address (no public hop): `http://<omnigent release>-omnigent.<namespace>.svc.cluster.local:8000`.
In the code-server terminal:

```bash
omnigent login http://<release>-omnigent.<namespace>.svc.cluster.local:8000
omnigent host
```

The omnigent login and machine identity are stored under
`/data/pi-agent/omnigent` (the persistent disk), so the machine keeps its
identity across restarts. To let omnigent's Pi reuse the pi login from this
IDE (no separate API key), add "Pi original auth" to
`/data/pi-agent/omnigent/config.yaml`:

```yaml
providers:
  pi-original:
    kind: subscription
    cli: pi
    default: pi
```

Notes:
- Once a machine is registered to one omnigent account, reconnecting it as a
  different account is refused (409).
- `omnigent host` is not started automatically; run it again after the service
  restarts.

## Syncing

```bash
scripts/sync-from-gitea.sh                         # both Gitea repos at main
scripts/sync-from-gitea.sh <charts-ref> <ci-ref>
```

CI here lints and renders the chart and checks the mirror layout; it does not
build or publish anything.

## History

The previous single-instance k3s package (its own cloudflared, the `code-server`
namespace behind `code-server-woow-k3s.woowtech.io`) is preserved on the
[`legacy/k3s-single-instance`](../../tree/legacy/k3s-single-instance) branch and
the `legacy-v0.1.0` tag.

## License

[MIT](LICENSE)
