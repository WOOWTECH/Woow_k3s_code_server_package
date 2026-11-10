# Mirror provenance

This repository is a **read-only mirror** of the code-server cloud service that
runs on the WOOW PaaS platform. The source of truth is the internal Gitea
(`git-prod.woowtech.io`). Changes land there first, go through those repos'
review and prod approval gates, and are then synced here with
[`scripts/sync-from-gitea.sh`](scripts/sync-from-gitea.sh).

**Do not edit `chart/` or `image/` here** — the next sync overwrites them. Open
the change against the Gitea repositories instead.

`validation/shared/omnigent-host/` is also mirrored from the same chart source
commit. `bash scripts/test-chart.sh` stages the original upstream directory
layout so every chart test, including canonical-kit comparison, runs without
editing the mirrored chart or accessing Gitea during CI.

## Current sync

Published PaaS image: `jcr-prod.woowtech.io/woow-paas-docker-local/code-server:20261110.0151@sha256:ad6544f9f3e917a7f8c7ee86bcf31793faf65969ab078d1c8c421012e4344d85`.

Gitea source PR #630 is merged. Build 40167 and publication approval #633
completed; the canonical manifest was verified equal to the tested candidate.
Chart 0.1.11 and its canonical host kit are unchanged from the previous sync.
The published chart OCI digest remains `sha256:7c6a1fe2bd444c92e3e53b3aa4457399d139de4d88641cccfe10a90a94758148`.

The new image passed native Codex with `workspace-write` and approvals set to
`never`: shared skill, shell arithmetic and a real MCP result. Workspace
read/write succeeded while outside writes and network sockets were denied.
Pi switched GPT-6 Sol to GPT-6.1 Sol in one conversation, retained context and
completed three MCP calls without errors. Claude completed two MCP calls.
Auth and shared settings survived the QA image update byte-for-byte.

These sandbox checks use explicit host AppArmor/seccomp profiles where the
runtime restricts nested user namespaces. They do not prove an unmodified HA
Supervisor profile works, or replace the earlier Paseo/Omnigent UI acceptance
record. See [sandbox deployment requirements](image/security/codex/README.md).
Google MCP OAuth and service-specific authorization/module issues remain
outside this image's completed checks. Deployment pin updates are coordinated
separately from this source mirror.

<!-- BEGIN GENERATED: scripts/sync-from-gitea.sh -->
| Mirror path | Source repository | Source path | Commit |
|---|---|---|---|
| `chart/` | `woow-paas/woow-paas-charts` | `charts/code-server/` | `adf529e06628777f191fd877ad4d09e5e85facd8` |
| `validation/shared/omnigent-host/` | `woow-paas/woow-paas-charts` | `shared/omnigent-host/` | `adf529e06628777f191fd877ad4d09e5e85facd8` |
| `image/` | `woow-paas/paas-odoo-ci` | `code-server/` | `4e8fefaf220e068beebab1420addca6acadeb463` |

Base image (podman package, consumed by digest): `ghcr.io/woowtech/woow-code-server-amd64:4.139.1-5@sha256:96d6a20abf3e108d2efa9aca46461f33d834bd416e3711a9705f63ca2ba7a903`

Chart `0.1.11` / appVersion `4.139.1` — synced 2026-11-10 02:02 UTC.
<!-- END GENERATED -->

## Where each piece comes from

| Piece | Source | Published as |
|---|---|---|
| `chart/` | `woow-paas/woow-paas-charts` `charts/code-server/` | `oci://jcr-prod.woowtech.io/woow-paas-docker-local/code-server` (private) |
| `image/` | `woow-paas/paas-odoo-ci` `code-server/` (`build-code-server-image.yml`: build → verify → candidate tag → prod approval → promote) | `jcr-prod.woowtech.io/woow-paas-docker-local/code-server:<YYYYMMDD.HHMM>` (private) |
| base image | [`WOOWTECH/Woow_podman_code_server_package`](https://github.com/WOOWTECH/Woow_podman_code_server_package) → `ghcr.io/woowtech/woow-code-server-amd64`, copied byte-for-byte into jcr-prod by `paas-odoo-ci` `mirror-image.yml` | `jcr-prod.woowtech.io/woow-paas-docker-local/woow-code-server-amd64` (private) |

The PaaS image adds only what the cloud service needs on top of the podman
image: the pinned extensions moved into code-server's built-in extensions dir
(so the chart can keep runtime-installed extensions on the tenant volume), the
Traditional Chinese language pack, and the `omnigent` CLI. See
[`image/README.md`](image/README.md).

## How the PaaS platform uses it

- The platform (`odoo-addons/woow_paas_platform`, template `code-server`) pins the
  chart version and the image by `tag@sha256`, and injects the tenant's public
  URL as `codeServer.publicUrl` (its host becomes `--trusted-origins`).
- Each tenant instance gets its own namespace-scoped release, two PVCs
  (workspace 20 Gi, pi-data 5 Gi) and a Cloudflare-tunnel subdomain.
- **Login is code-server's own password login** — no username, no auth-proxy.
  The password lives in the chart Secret and is managed by the platform: shown
  once at launch, then reset or set by the tenant from the service page.
- Pi, Claude Code and Codex are built in (terminal and the ACP sidebar); optional
  Anthropic / OpenRouter keys and a Git token come from the service page.

## Resyncing

```bash
scripts/sync-from-gitea.sh                         # both repos at main
scripts/sync-from-gitea.sh <charts-ref> <ci-ref>
```

Needs read access to both Gitea repositories.

## History

The previous single-instance k3s package (chart `code-server` 0.1.0 with its own
cloudflared, code-server 4.135.0 + pi 0.83.0 — the `code-server` namespace behind
`code-server-woow-k3s.woowtech.io`) is preserved on the
[`legacy/k3s-single-instance`](../../tree/legacy/k3s-single-instance) branch and
the `legacy-v0.1.0` tag. On 2026-10-01 this repository became the mirror of the
PaaS cloud service (code-server 4.139.1, PARITY_CONTRACT 1.2).
