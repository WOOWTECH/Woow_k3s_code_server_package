# Woow k3s code-server

[![Helm](https://img.shields.io/badge/Helm-chart-0F1689)](https://helm.sh)
[![code-server](https://img.shields.io/badge/code--server-4.135.0-blueviolet)](https://github.com/coder/code-server)
[![pi-coding-agent](https://img.shields.io/badge/pi--coding--agent-0.83.0-blue)](https://www.npmjs.com/package/@earendil-works/pi-coding-agent)
[![ACP](https://img.shields.io/badge/ACP%20client-formulahendry.acp--client%400.2.0-green)](https://open-vsx.org/extension/formulahendry/acp-client)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

**English** · [繁體中文](README_zh-TW.md)

[`code-server`](https://github.com/coder/code-server) (the browser IDE) on k3s via Helm, exposed through a Cloudflare Tunnel, with the [pi coding agent](https://github.com/earendil-works/pi), [pi-acp](https://www.npmjs.com/package/pi-acp), and the [ACP Client](https://open-vsx.org/extension/formulahendry/acp-client) chat sidebar pre-wired.

This chart deploys the **same image** `Woow_podman_code_server_package` builds — one image, so the pi layer cannot drift between the two deployments. It is one of three aligned WOOWTECH code-server deployments (podman, a [Home Assistant add-on](https://github.com/WOOWTECH/Woow_ha_code_server_add_on), and this chart); see [`PARITY_CONTRACT.md`](PARITY_CONTRACT.md) for the cross-platform contract.

pi's state here is **private to this deployment**.

---

## What you get

| | |
|---|---|
| **Exposure** | Cloudflare Tunnel → ClusterIP Service, no Ingress object — path root, trusted cert |
| **IDE** | code-server 4.135.0 |
| **Agent** | pi 0.83.0 in the ACP right-side chat panel, and as `pi` on every terminal PATH |
| **Workspace** | A dedicated `workspace` PVC (20Gi, Longhorn) |
| **Persistence** | pi state on its own PVC (5Gi); IDE settings on a `subPath` of the same volume |
| **Backup** | Opt-in CronJob, tar to a third PVC, keeps the newest 7 |

## Why the chat webview works here without argument

Cloudflare Tunnel puts code-server at a path root behind a genuinely OS-trusted edge certificate — the two things that make VS Code's webview ServiceWorker register (a secure context, and no path-prefix scoping surprise) are both satisfied by construction, the same way the podman package's own `README.md#security` documents that plain-HTTP LAN access does **not** satisfy them. See `PARITY_CONTRACT.md`'s webview gate verdict for the full reasoning, and `docs/DEPLOYMENT.md` for the one remaining manual browser check.

## Install

Full prerequisites and namespace bootstrap: [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md). Short version:

```bash
kubectl --context woow-k3s create namespace code-server
kubectl -n code-server create secret generic code-server-auth --from-literal=PASSWORD='...'
kubectl -n code-server create secret generic code-server-cf-creds --from-file=credentials.json=./credentials.json

./scripts/deploy.sh
```

### First run

```bash
kubectl --context woow-k3s -n code-server exec -it deploy/code-server -c code-server -- sh -lc 'pi login'
```

## Layout

```
charts/code-server/
  Chart.yaml / values.yaml       chart defaults, every knob documented
  templates/
    deployment.yaml                initContainer pi-seed + the code-server container
    service.yaml                   ClusterIP, direct to code-server:8080 — no nginx sidecar
    cloudflared.yaml + configmap-cloudflared.yaml   dedicated tunnel Deployment + git-tracked routing
    pvc-data.yaml / pvc-backup.yaml
    secret-auth.yaml                optional — usually auth.existingSecret is used instead
    configmap-settings.yaml         the 6 required settings.json keys
    networkpolicy.yaml              opt-in
    cronjob-backup.yaml             opt-in
    tests/smoke.yaml                helm test — curls /healthz in-cluster
values-woow.yaml                  the woow-k3s instance's own values
deploy/rendered/code-server-woow.yaml   CI-rendered manifest (placeholder tunnel ID — never apply directly)
scripts/{deploy.sh,uninstall.sh}
tests/
  lib/parity.sh                    shared adapter with the podman/HA repos (PARITY_TARGET=k3s)
  smoke-container.sh / smoke-acp.sh / smoke-pi-integration.sh
docs/{ARCHITECTURE.md,DEPLOYMENT.md}
.github/workflows/chart.yml        helm lint + template + credential guard + auto-commit the render
```

## Verifying a deployment

```bash
export PARITY_TARGET=k3s KUBECTL_CONTEXT=woow-k3s K3S_NAMESPACE=code-server
bash tests/smoke-container.sh
bash tests/smoke-acp.sh
bash tests/smoke-pi-integration.sh
helm test code-server -n code-server
```

## Security

- `PASSWORD` comes from a Secret created out of band — never a chart default, and never the podman quadlet's LAN literal. This is a public Cloudflare hostname.
- pi's only credential is an OAuth pair in `/data/pi-agent/auth.json` on the PVC — anyone with `kubectl exec` in this namespace can read it. RBAC on `pods/exec` is the real control.
- `automountServiceAccountToken: false`, `allowPrivilegeEscalation: false`, `capabilities: drop: [ALL]` on every container.
- `NetworkPolicy` is opt-in (off by default, matching this cluster's house default) — restricts ingress to the tunnel + kubelet, egress to DNS + the open internet minus this cluster's own CIDRs.

Full detail: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md#security-posture).

## Related

- [`Woow_podman_code_server_package`](https://github.com/WOOWTECH/Woow_podman_code_server_package) — builds the image this chart deploys
- [`Woow_ha_code_server_add_on`](https://github.com/WOOWTECH/Woow_ha_code_server_add_on) — the same pi/ACP wiring as a Home Assistant add-on
- [`Woow_k3s_pi_agent_package`](https://github.com/WOOWTECH/Woow_k3s_pi_agent_package) — house-style Helm chart this one's structure follows
- [ACP Client (formulahendry)](https://open-vsx.org/extension/formulahendry/acp-client) — the VS Code extension that renders the chat panel

## License

MIT
