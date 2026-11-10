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

Published PaaS image: `jcr-prod.woowtech.io/woow-paas-docker-local/code-server:20261110.1622@sha256:0271957892a382d88c141c4a0d3a2b3b53da6cd0b56ba7239fe229608d6dcb5b`.

Gitea source PRs [#659](https://git-prod.woowtech.io/woow-paas/paas-odoo-ci/pulls/659),
[#662](https://git-prod.woowtech.io/woow-paas/paas-odoo-ci/pulls/662) and
[#663](https://git-prod.woowtech.io/woow-paas/paas-odoo-ci/pulls/663) are merged.
The image contains both connector extensions at 0.1.6: Refresh MCP releases its
busy state when the operation completes, independently of notification dismissal,
and Paseo reports recognized RPC failures with guidance for opening the original
conversation before refreshing. The bounded PaaS adapter preserves both the
existing reminder behavior and the shared native-resume source guards.

Gitea Actions build [41326](https://git-prod.woowtech.io/woow-paas/paas-odoo-ci/actions/runs/41326)
passed the actual built-image gates. Normal approval #665 and promotion
[41331](https://git-prod.woowtech.io/woow-paas/paas-odoo-ci/actions/runs/41331)
completed. The canonical manifest equals the tested candidate; extracted image
bytes match 45 packaged source files, 18 installed runtime files, three PaaS
adapter files and both reviewed VSIX packages. The shared source and VSIX bytes
match the published Podman 4.139.1-8 and HA 0.1.14 images.

Chart 0.1.12 remains unchanged. It adds a code-server-only `securityContext`
override, preserving the init container, cookie proxy and pod policies. Gitea
PR #332 is merged; publication run 40266 verified the chart in both Gitea Helm
and OCI registries. The chart OCI digest is
`sha256:d9fbaba022ef3ccd5426955fa47ae29d99065c93edae4dad2dd61739b542cf95`.
The identical `code-server-0.1.12.tgz` package has SHA-256
`fad8bd37e4103f94e9149111d5cc3d8b005ffe5cabb9f7f650d167424a722990`.

Deployment pin updates and installed-session acceptance are coordinated separately
from this source mirror. See [sandbox deployment requirements](image/security/codex/README.md)
for the host AppArmor/seccomp profiles needed where nested user namespaces are
restricted; image publication does not prove an unmodified HA Supervisor profile
works or that external MCP OAuth/service authorization is configured.

<!-- BEGIN GENERATED: scripts/sync-from-gitea.sh -->
| Mirror path | Source repository | Source path | Commit |
|---|---|---|---|
| `chart/` | `woow-paas/woow-paas-charts` | `charts/code-server/` | `4ce7e68abe5de07f50002841c53a101cf8f32f6c` |
| `validation/shared/omnigent-host/` | `woow-paas/woow-paas-charts` | `shared/omnigent-host/` | `4ce7e68abe5de07f50002841c53a101cf8f32f6c` |
| `image/` | `woow-paas/paas-odoo-ci` | `code-server/` | `5828588a6589a680a20e2992e306d10136b59dd6` |

Base image (podman package, consumed by digest): `ghcr.io/woowtech/woow-code-server-amd64:4.139.1-8@sha256:fe8b6a0f1b90863cb784cc8a4d69ba33783ee7b87d6322bf975a59511905370d`

Chart `0.1.12` / appVersion `4.139.1` — synced 2026-11-10 16:40 UTC.
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
