# Deployment

## Prerequisites

1. **The image must be published first.** `values-woow.yaml` currently pins `image.tag: "0.1.0"` as a placeholder — it must match a real tag/digest published by `Woow_podman_code_server_package`'s CI (`ghcr.io/woowtech/woow-code-server-amd64`). Prefer `image.digest` once known.
2. **A Cloudflare Tunnel must exist**, created in the Cloudflare Zero Trust dashboard (outside the cluster, outside git, outside anything `kubectl` can verify): note its tunnel UUID and download `credentials.json`. Point the DNS record for `code-server-woow-k3s.woowtech.io` at it.
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

helm test code-server -n code-server   # in-cluster curl to /healthz
```

Then the manual browser gate — open `https://code-server-woow-k3s.woowtech.io`, sign in, open a Markdown preview, and confirm the ServiceWorker registers (DevTools → Application → Service Workers). Per `PARITY_CONTRACT.md`'s webview gate verdict, k3s is expected to pass this by construction (path-root + trusted Cloudflare cert), but it has not been directly observed end-to-end against a real deployed instance — see the repo's own testing notes.

Also worth checking once, per the contract: leave the tab idle 150 seconds and confirm the workbench reconnects on its own (Cloudflare closes proxied WebSockets after 100s idle on plans below Enterprise — a real, separate failure mode from the webview/secure-context one, and easy to misdiagnose as the same bug).

## Upgrading

```bash
helm upgrade code-server charts/code-server -n code-server -f values-woow.yaml
kubectl -n code-server rollout status deploy/code-server
```

Bump `PI_CODING_AGENT_VERSION` / `PI_ACP_VERSION` / `ACP_CLIENT_VERSION` only in lockstep with the podman package and the HA add-on — see `PARITY_CONTRACT.md` §2.1. This chart does not build an image, so a version bump here means waiting for the podman package's new image to publish, then bumping `image.tag`/`image.digest`.

## Rollback

```bash
./scripts/uninstall.sh          # keeps all 3 PVCs (Longhorn Retain + helm.sh/resource-policy: keep)
./scripts/uninstall.sh --purge  # also deletes them, after a y/N prompt
```

## Known gaps at first deployment

- The image has not yet been published to GHCR (a live step owned by the podman track).
- No Cloudflare Tunnel has been created yet for `code-server-woow-k3s.woowtech.io`.
- `deploy/rendered/code-server-woow.yaml` in this repo is rendered with a **placeholder** `cloudflare.tunnelId` (CI cannot know the real one) — do not `kubectl apply` it directly; always go through `helm upgrade --install` with the real values.
