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

Always pass the context explicitly (`--kube-context` for helm, `--context` for
kubectl). Full prerequisites and namespace bootstrap:
[`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md).

The chart renders **no Namespace**: Helm keeps its release record in the release
namespace, and a chart-owned Namespace would let `helm uninstall` delete it —
taking the kept PVCs with it. Create it yourself (or use `--create-namespace`).

### A. How woow-k3s runs it — Secrets created out of band

`secrets.create` is `false` by default, so the chart only references Secrets
that already exist and no upgrade can overwrite the real password or the real
tunnel credential.

```bash
kubectl --context woow-k3s create namespace code-server
cp examples/secrets.example.yaml ~/secure/code-server-secrets.yaml   # fill every REPLACE_ME
kubectl --context woow-k3s -n code-server apply -f ~/secure/code-server-secrets.yaml

# From a local clone
git clone https://github.com/WOOWTECH/Woow_k3s_code_server_package.git
cd Woow_k3s_code_server_package
helm --kube-context woow-k3s upgrade --install code-server charts/code-server \
  -n code-server -f values/woow-k3s/code-server.yaml --wait --timeout 5m

# Or let the wrapper run the pre-flight checks first (context, namespace, both
# Secrets, StorageClass) and the parity smoke tests afterwards
./scripts/deploy.sh
```

Straight from the repo tarball, no clone. The chart is in a subdirectory, so
extract rather than passing the URL to helm:

```bash
curl -sSL https://github.com/WOOWTECH/Woow_k3s_code_server_package/archive/refs/heads/main.tar.gz | tar xz
helm --kube-context woow-k3s upgrade --install code-server \
  Woow_k3s_code_server_package-main/charts/code-server -n code-server \
  -f Woow_k3s_code_server_package-main/values/woow-k3s/code-server.yaml
```

### B. Let the chart create the Secrets — test installs

```bash
helm --kube-context woow-k3s install code-server charts/code-server \
  -n ht-code-server --create-namespace \
  --set persistence.storageClassName=longhorn-delete \
  --set secrets.create=true \
  --set secrets.authPassword="$(openssl rand -hex 24)" \
  --set keepOnUninstall=false
kubectl --context woow-k3s -n ht-code-server port-forward svc/code-server 8080:8080
```

`cloudflare.enabled` defaults to **false** on purpose: a test install must never
start a second connector against a real tunnel — Cloudflare would split traffic
between it and production. Reach a test release by port-forward.

### First run

```bash
kubectl --context woow-k3s -n code-server exec -it deploy/code-server -c code-server -- sh -lc 'pi login'
```

## Key values

| Value | Default | Description |
|---|---|---|
| `keepOnUninstall` | `true` | `helm.sh/resource-policy: keep` on every PVC and any chart-created Secret |
| `image.digest` / `image.tag` | `""` / `""` | Prefer the digest. With both empty the tag falls back to `appVersion` with `+` replaced by `_` (an OCI tag may not contain `+`) |
| `persistence.storageClassName` | **none — required** | No default on purpose: woow-k3s marks *two* StorageClasses `(default)` |
| `persistence.piData.size` / `workspace.size` | `5Gi` / `20Gi` | RWO, `keep` |
| `secrets.create` | `false` | Render `code-server-auth` (and the tunnel credentials) from `secrets.*` instead of using existing Secrets |
| `auth.existingSecret` | `code-server-auth` | Secret holding the `PASSWORD` key |
| `cloudflare.enabled` | `false` | Dedicated tunnel Deployment; needs `tunnelId`, `hostname` and a credentials source |
| `cloudflare.replicas` | `2` | Connectors, spread by anti-affinity |
| `persistence.backup.enabled` / `backup.schedule` / `backup.keep` | `false` / `17 3 * * *` / `7` | Daily tar of pi-data + workspace to a third PVC |
| `networkPolicy.enabled` | `false` | Opt-in, and a **runtime change** for a running pod — see Security |
| `codeServer.resources` | 500m/1Gi → 4/8Gi | This cluster also hosts 16 production Odoo tenants |
| `imagePullSecrets.enabled` | `false` | The GHCR package is public; flip on only if it is made private |

Full list: [`charts/code-server/values.yaml`](charts/code-server/values.yaml).
The live instance's own values: [`values/woow-k3s/code-server.yaml`](values/woow-k3s/code-server.yaml)
(no secrets — those live only in the cluster).

## Layout

```
charts/code-server/
  Chart.yaml / values.yaml       chart defaults, every knob documented
  templates/
    deployment.yaml                initContainer pi-seed + the code-server container
    service.yaml                   ClusterIP, direct to code-server:8080 — no nginx sidecar
    cloudflared.yaml + configmap-cloudflared.yaml   dedicated tunnel Deployment + git-tracked routing
    pvc-data.yaml / pvc-backup.yaml
    secrets.yaml                    only with secrets.create=true; otherwise existing Secrets
    configmap-settings.yaml         the 6 required settings.json keys
    networkpolicy.yaml              opt-in
    cronjob-backup.yaml             opt-in
    tests/smoke.yaml                helm test — curls /healthz and /login in-cluster
values/woow-k3s/code-server.yaml  the woow-k3s instance's own values (no secrets)
examples/secrets.example.yaml     every Secret key, with placeholders
deploy/rendered/code-server-woow.yaml   rendered reference (placeholder tunnel ID — never apply directly)
scripts/{deploy.sh,uninstall.sh,render.sh,check-drift.sh}
tests/
  lib/parity.sh                    shared adapter with the podman/HA repos (PARITY_TARGET=k3s)
  smoke-container.sh / smoke-acp.sh / smoke-pi-integration.sh
docs/{ARCHITECTURE.md,DEPLOYMENT.md}
.github/workflows/chart.yml        lint, template every values combination, kubeconform -strict,
                                   required()-guard and secret-leak checks, render freshness
```

## Verifying a deployment

```bash
helm --kube-context woow-k3s test code-server -n code-server --logs   # read-only: /healthz + /login

export PARITY_TARGET=k3s KUBECTL_CONTEXT=woow-k3s K3S_NAMESPACE=code-server
bash tests/smoke-container.sh
bash tests/smoke-acp.sh
bash tests/smoke-pi-integration.sh

# Repo vs Helm release: rendered manifest and values (exit 0 = identical)
scripts/check-drift.sh
```

## Uninstall — the data is kept

```bash
helm --kube-context woow-k3s uninstall code-server -n code-server
```

That removes the Deployments, the Service, the ConfigMaps and the CronJob. With
`keepOnUninstall=true` the three PVCs stay (pi login, sessions, workspace,
backups), the namespace was never a chart object, and `code-server-auth` /
`code-server-cf-creds` were created out of band and are untouched. Re-installing
re-attaches the same volumes.

`scripts/uninstall.sh` does the same and prints the exact command to delete the
data on purpose (`--purge` asks first). Longhorn's reclaim policy is `Retain`,
so even then the PVs stay `Released` until someone deletes them.

## Taking over or upgrading the live release

The `code-server` release in namespace `code-server` on woow-k3s is already
Helm-managed by this chart, and `values/woow-k3s/code-server.yaml` is the source
of truth for it:

```bash
scripts/check-drift.sh    # helm get manifest == helm template, helm get values == the file
```

Upgrading a live release to this chart version replaces no object and rolls no
pod: the rendered objects are field-for-field what is running (only a YAML
comment moved into `_helpers.tpl`, and the `helm test` hook pod — which is not
part of the release manifest — changed).

Two things to know before that upgrade:

- Keep `networkPolicy.enabled=false`, as the instance values do. Enabling it
  adds a policy the running pod has never been subject to; that is a runtime
  change and belongs in its own deliberate rollout.
- The live pod template carries a `kubectl.kubernetes.io/restartedAt`
  annotation from a manual `kubectl rollout restart`. Helm's three-way merge
  leaves it alone (it is in neither the old nor the new render), so the upgrade
  does not roll the pod. A `kubectl apply` of `deploy/rendered/...` would remove
  it and restart the pod — one more reason that file is a reference only.

## Security

- `PASSWORD` comes from a Secret created out of band — never a chart default, and never the podman quadlet's LAN literal. This is a public Cloudflare hostname.
- That single shared password is the **only** access control on the public hostname: no Cloudflare Access policy, no SSO, no MFA, no per-person identity. Anyone who has it gets a shell, the agent, and pi's OAuth credential.
- pi's only credential is an OAuth pair in `/data/pi-agent/auth.json` on the PVC — anyone with `kubectl exec` in this namespace can read it. RBAC on `pods/exec` is the real control. The daily backup tars it too.
- `automountServiceAccountToken: false`, `allowPrivilegeEscalation: false`, `capabilities: drop: [ALL]` on every container.
- VS Code Workspace Trust is deliberately **disabled** in the seeded settings (the ACP panel needs it off), so any cloned repository's tasks and extension behaviour are trusted without a prompt. See `PARITY_CONTRACT.md` §2.5.
- `NetworkPolicy` is opt-in and **off** on the live instance: this pod runs model-authored code and can currently reach the rest of the cluster and the LAN. Turning it on restricts ingress to the tunnel, the `helm test` pod and the node CIDRs, and egress to DNS plus the internet minus this cluster's own CIDRs — verify pi still reaches everything it needs in a test namespace first. One measured wrinkle: this cluster's policy controller programs a *new* pod's IP into the allow sets about 5-10 seconds after that pod starts, so anything that connects in its own first second (an un-retried test, a freshly rescheduled connector) sees a refused connection and then works. The `helm test` pod retries for that reason.

Full detail: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md#security-posture).

## Related

- [`Woow_podman_code_server_package`](https://github.com/WOOWTECH/Woow_podman_code_server_package) — builds the image this chart deploys
- [`Woow_ha_code_server_add_on`](https://github.com/WOOWTECH/Woow_ha_code_server_add_on) — the same pi/ACP wiring as a Home Assistant add-on
- [`Woow_k3s_pi_agent_package`](https://github.com/WOOWTECH/Woow_k3s_pi_agent_package) — house-style Helm chart this one's structure follows
- [ACP Client (formulahendry)](https://open-vsx.org/extension/formulahendry/acp-client) — the VS Code extension that renders the chat panel

## License

MIT
