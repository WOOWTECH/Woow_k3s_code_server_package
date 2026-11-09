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

Published PaaS image: `jcr-prod.woowtech.io/woow-paas-docker-local/code-server:20261109.1822@sha256:9ce86033b4fef2cc99395114a4db31538b7c32822b34b8d57c2b370e96e27dc3`.
Upstream mirror approval #619 and image publication approval #621 completed.
Provider login and real model checks in the PaaS QA instance remain pending.

<!-- BEGIN GENERATED: scripts/sync-from-gitea.sh -->
| Mirror path | Source repository | Source path | Commit |
|---|---|---|---|
| `chart/` | `woow-paas/woow-paas-charts` | `charts/code-server/` | `5457874185edcf0ce8ee963f42df78672af1c218` |
| `validation/shared/omnigent-host/` | `woow-paas/woow-paas-charts` | `shared/omnigent-host/` | `5457874185edcf0ce8ee963f42df78672af1c218` |
| `image/` | `woow-paas/paas-odoo-ci` | `code-server/` | `d8d239f08b5b400eddbb6f7509f0d88918d65041` |

Base image (podman package, consumed by digest): `ghcr.io/woowtech/woow-code-server-amd64:main-5d91687@sha256:aeb8bca7b8f7fc679b95e9d9891b1ec131ddc3be87758a2d7045f80fafee03e1`

Chart `0.1.11` / appVersion `4.139.1` — synced 2026-11-09 21:14 UTC.
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
- pi and Claude Code are built in (terminal and the ACP sidebar); optional
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
