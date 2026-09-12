# Architecture

## Shape

```
Internet ── Cloudflare Tunnel (code-server-cloudflared, 2 replicas)
                    │
                    ▼
            Service code-server:8080 (ClusterIP)
                    │
                    ▼
            Deployment code-server (replicas: 1, strategy: Recreate)
              initContainer: pi-seed
              container:     code-server (pi + pi-acp + ACP Client baked into the image)
                    │
        ┌───────────┴────────────┐
        ▼                        ▼
  PVC code-server-pi-data   PVC code-server-workspace
  (longhorn, 5Gi)           (longhorn, 20Gi)
```

No nginx sidecar (unlike the sibling `Woow_k3s_pi_agent_package` chart) — code-server needs the browser's real `Host`/`Origin` to reach it unmodified for its own origin check, the opposite of pi-web's requirement that Host be rewritten to `localhost`. cloudflared forwards the real Host by default, so nothing sits between the tunnel and the Service.

## Why this chart's own dedicated tunnel, not the shared NPM+tunnel pattern

`Woow_k3s_pi_agent_package/deploy/npm/` extracted cloudflared into its own release plus a shared NPM instance, specifically to stop five sibling releases *in one namespace* from stepping on each other's tunnel routing table on every upgrade. This chart is a single release in its own `code-server` namespace — that coupling problem doesn't exist here, so a dedicated `code-server-cloudflared` Deployment (same pattern the pi-agent chart used *before* that extraction) is simpler and correct. Revisit only if a second code-server release is ever asked to share this namespace.

## Image

This chart does not build an image. It consumes the exact image `Woow_podman_code_server_package` builds and publishes to `ghcr.io/woowtech/woow-code-server-amd64` — one image, so the pi layer (Node 22, pi 0.83.0, pi-acp 0.0.33, ACP Client 0.2.0, `pi-code`, `pi.sh`, `pi-seed`, the settings seed) physically cannot drift between the podman and k3s deployments. See `PARITY_CONTRACT.md`.

## `pi-seed` initContainer

Unlike podman (where a named volume is seeded from the image's own `/opt/pi-agent-skel` content on first mount, with zero runtime hook) and the HA add-on (an s6 oneshot), k3s runs `pi-seed` as an `initContainer` on every pod start:

1. `/usr/local/bin/pi-seed` — idempotent, copies from `/opt/pi-agent-skel` into `/data/pi-agent` if not already present.
2. Seeds `/home/coder/.local/share/code-server/User/settings.json` (mounted via a PVC `subPath`, which starts genuinely empty — a `subPath` mount gets no image content, unlike podman's named volume) from the chart's `configmap-settings.yaml`, with an idempotent `jq` merge so a user's own edits to other keys survive an upgrade that adds a new required key.

Both steps are safe to re-run on every pod restart.

## `--trusted-origins`

The image's own `ENTRYPOINT` (inherited from `codercom/code-server`, unchanged) is:
```
/usr/bin/entrypoint.sh --bind-addr 0.0.0.0:8080 .
```
Kubernetes `args:` on the container is appended AFTER that entrypoint (since this chart sets no `command:`), so `--trusted-origins <hostname>` lands correctly as a trailing flag — verified directly against the base image: `entrypoint.sh --bind-addr 0.0.0.0:8080 . --trusted-origins <host>` starts cleanly, and `--trusted-origins` is confirmed (by reading code-server's own bundled `cli.js`) to be a real `type: "string[]"` option, not a boolean.

This flag is defensive, not required: cloudflared already forwards the real `Host`/`Origin` by default. It exists because a proxy that fails to do so makes code-server 403 the WebSocket upgrade — a dead sidebar/terminal that looks exactly like the ServiceWorker/secure-context bug (see `PARITY_CONTRACT.md`'s webview gate verdict) but is a different, unrelated failure mode. Only rendered when `cloudflare.hostname` is set.

## Storage

`persistence.storageClassName` has **no default** and the chart refuses to render without it. woow-k3s carries two StorageClasses both marked `(default)` — `local-path` and `longhorn` — so an omitted value is non-deterministic and would most likely bind node-local, unreplicated `local-path`; a rescheduled pod would silently come up with an empty store. This chart's own `values/woow-k3s/code-server.yaml` sets `longhorn` explicitly.

All three PVCs (`pi-data`, `workspace`, and `backup` when enabled) carry `helm.sh/resource-policy: keep` while `keepOnUninstall` is `true`, so `helm uninstall` never deletes them. The chart renders no Namespace at all, so a release can never take its own namespace down with it.

## Backup

No Longhorn backup target and no cluster-wide recurring jobs exist on woow-k3s — the `cronjob-backup.yaml` template (opt-in, `persistence.backup.enabled`) is the only data protection available, matching the house pattern (`pi-agent-woow/opendesign-backup`). It tars both PVCs to a third PVC, tolerates busybox `tar`'s exit code 1 (a file changing size mid-read, normal under a live directory) but fails on anything else, verifies with `tar tzf` before counting an archive as real, and prunes to the newest 7. `models-store.json` is excluded (a refetchable cache, per `PARITY_CONTRACT.md`).

Because both the app's PVCs and the backup PVC are RWO, the backup Pod carries a mandatory `podAffinity` pinning it to the same node the app pod is already on.

**Nothing monitors whether this CronJob actually ran** — a house-wide gap, not specific to this chart (`omnigent`'s own `host-gc` CronJob failed 3 of its last 4 runs unnoticed on this same cluster).

## Security posture

- `automountServiceAccountToken: false` on both the app pod and the cloudflared pod — neither makes Kubernetes API calls, matching the pi-agent chart's own reasoning for its pi-web pod ("a mounted ServiceAccount token would be pure attack surface on a pod whose whole job is running arbitrary model-authored code").
- `allowPrivilegeEscalation: false` + `capabilities: drop: [ALL]` per-container. Neither reference chart in this house (`Woow_k3s_pi_agent_package`, `Woow_k3s_opendesign`) currently sets this, so it is not claimed as an established convention — it is added here as a cheap, functionality-neutral hardening default.
- `runAsUser/Group/fsGroup: 1000` — matches the image's `coder` user (uid 1000) and the podman quadlet's `UserNS=keep-id:uid=1000,gid=1000` requirement; without it, pi's own file locking (`settings.json.lock`) fails with `EACCES`.
- `NetworkPolicy` (opt-in, default off — matching the house default on `pi-agent-woow` and `omnigent`): restricts ingress to the tunnel pods + node CIDRs (kubelet probes), and egress to DNS + the open internet minus this cluster's own CIDRs (pod/service/LAN ranges, metadata address) — the same shape the pi-agent chart's own policy uses, verified reachable in that deployment.
- `PASSWORD` comes from a Secret created out of band, never a chart default — the k3s exposure is a public Cloudflare hostname, not an office LAN.
- pi's only credential is an OAuth pair in `/data/pi-agent/auth.json` on the PVC. Anyone with `kubectl exec` in this namespace can read it — the real access control is RBAC on `pods/exec`, not anything this chart can enforce.

## Where to look when something breaks

| Symptom | Look here |
|---|---|
| Pod stuck `Init:0/1` | `kubectl logs -c pi-seed` — check for a PVC mount failure or a jq error |
| `ImagePullBackOff` | The `ghcr.io/woowtech` package may be private with no `imagePullSecrets` configured — see `docs/DEPLOYMENT.md` |
| Hostname 404s, everything in-cluster looks healthy | The Cloudflare Tunnel route/DNS record was never created in the dashboard — this is entirely outside the cluster and outside anything `kubectl` can see |
| Sidebar/terminal completely dead despite a valid cert | Host/Origin mismatch on the WebSocket upgrade — confirm `cloudflare.hostname` matches the real DNS name and `--trusted-origins` is rendered (see the deployment's `args:`) |
| Chat panel blank | Leave the tab idle 150s first and check whether it reconnects on its own — Cloudflare closes proxied WebSockets after 100s idle on plans below Enterprise, which looks identical to the ServiceWorker bug but is not |
