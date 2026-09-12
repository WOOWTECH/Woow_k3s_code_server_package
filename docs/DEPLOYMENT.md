# Deployment

## Prerequisites

1. **The image must be published.** `values/woow-k3s/code-server.yaml` pins `image.digest` — the digest published by `Woow_podman_code_server_package`'s CI to `ghcr.io/woowtech/woow-code-server-amd64` (done: run 34414564430, 2026-09-09). A digest, not the floating `:main` tag. The package is public, so `imagePullSecrets.enabled: false`.
2. **A Cloudflare Tunnel must exist** (done for this instance: created 2026-09-09 via the Cloudflare API, with the DNS CNAME for `code-server-woow-k3s.woowtech.io` created in the same pass). A locally-managed tunnel: note its UUID for `cloudflare.tunnelId` and keep its `credentials.json` only in Secret `code-server-cf-creds` — it is outside the cluster, outside git, and outside anything `kubectl` can verify.
3. **`kubectl config current-context` must be `woow-k3s`.** `scripts/deploy.sh` refuses to run otherwise.

## Namespace bootstrap (one-time)

```bash
kubectl --context woow-k3s create namespace code-server

kubectl -n code-server create secret generic code-server-auth \
    --from-literal=PASSWORD='<a strong password — never the podman quadlet's LAN default>'

kubectl -n code-server create secret generic code-server-cf-creds \
    --from-file=credentials.json=/path/to/the/tunnel/credentials.json

# Only if ghcr.io/woowtech/woow-code-server-amd64 is a PRIVATE package —
# check at https://github.com/orgs/WOOWTECH/packages first:
kubectl -n code-server create secret docker-registry ghcr-woowtech \
    --docker-server=ghcr.io \
    --docker-username=WOOWTECH \
    --docker-password='<a PAT with read:packages>'
```

The namespace inherits no ResourceQuota and no LimitRange (those exist only in `paas-ws-*` namespaces) — this chart's own `resources.limits` (4 CPU / 8Gi) are the only constraint on a cluster that also hosts 16 production Odoo tenants, which is why they are conservative rather than `omnigent`'s 16 CPU / 24Gi.

## Install

```bash
./scripts/deploy.sh
```

This verifies the context, namespace, both Secrets, and the StorageClass exist, then runs `helm upgrade --install`, waits for rollout, and runs the three `tests/smoke-*.sh` scripts with `PARITY_TARGET=k3s`.

## First run

```bash
kubectl --context woow-k3s -n code-server exec -it deploy/code-server -c code-server -- sh -lc 'pi login'
```

pi has no credentials until this runs once — see `PARITY_CONTRACT.md` §7 for why this cannot be a Secret mount (the credential is an OAuth pair pi rewrites on every refresh).

## E2E verification checklist

```bash
export PARITY_TARGET=k3s KUBECTL_CONTEXT=woow-k3s K3S_NAMESPACE=code-server

bash tests/smoke-container.sh          # /healthz + password gate
bash tests/smoke-acp.sh                # ACP extension + settings.json's 6 required keys
bash tests/smoke-pi-integration.sh     # pi/pi-acp/pi-code + internal store + shared-file hashes

helm --kube-context woow-k3s test code-server -n code-server --logs   # in-cluster curl: /healthz + /login
```

Then the manual browser gate — open `https://code-server-woow-k3s.woowtech.io`, sign in, open a Markdown preview, and confirm the ServiceWorker registers (DevTools → Application → Service Workers). Per `PARITY_CONTRACT.md`'s webview gate verdict, k3s is expected to pass this by construction (path-root + trusted Cloudflare cert), but it has not been directly observed end-to-end against a real deployed instance — see the repo's own testing notes.

Also worth checking once, per the contract: leave the tab idle 150 seconds and confirm the workbench reconnects on its own (Cloudflare closes proxied WebSockets after 100s idle on plans below Enterprise — a real, separate failure mode from the webview/secure-context one, and easy to misdiagnose as the same bug).

## Upgrading

```bash
helm --kube-context woow-k3s upgrade code-server charts/code-server \
    -n code-server -f values/woow-k3s/code-server.yaml
kubectl --context woow-k3s -n code-server rollout status deploy/code-server

# Before and after: does the repo still describe what is running?
scripts/check-drift.sh
```

Bump `PI_CODING_AGENT_VERSION` / `PI_ACP_VERSION` / `ACP_CLIENT_VERSION` only in lockstep with the podman package and the HA add-on — see `PARITY_CONTRACT.md` §2.1. This chart does not build an image, so a version bump here means waiting for the podman package's new image to publish, then bumping `image.tag`/`image.digest`.

## Rollback

```bash
./scripts/uninstall.sh          # keeps all 3 PVCs (Longhorn Retain + helm.sh/resource-policy: keep)
./scripts/uninstall.sh --purge  # also deletes them, after a y/N prompt
```

## Known gaps

- `deploy/rendered/code-server-woow.yaml` is rendered with a **placeholder** `cloudflare.tunnelId` (it has no business carrying the real one) — do not `kubectl apply` it directly; always go through `helm upgrade --install` with the real values. `scripts/render.sh` regenerates it and CI fails if it is stale.
- Applying that file would also strip the `kubectl.kubernetes.io/restartedAt` annotation a manual `kubectl rollout restart` left on the live pod template, and restart the pod. A `helm upgrade` does not: its three-way merge only patches what the chart itself renders.
- The public hostname has **no Cloudflare Access policy**: one shared password, no SSO, no MFA, no per-person identity for a door that opens on a shell and pi's OAuth credential.
- `networkPolicy.enabled` is `false` on the live instance. The policy exists in the chart and is opt-in because switching it on changes what a *running* pod can reach — rehearse it in a test namespace (confirm pi still reaches its provider, git remotes, open-vsx.org, registry.npmjs.org and cdn.agentclientprotocol.com) before rolling it out.
- The backup CronJob writes to a third Longhorn PVC in the same cluster, pinned by `requiredDuringScheduling` podAffinity to the app pod's node: no off-cluster copy, and no backup at all while the app pod is down. Nothing monitors whether it ran.
