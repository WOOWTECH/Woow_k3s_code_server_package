# Woow k3s code-server

[![Helm](https://img.shields.io/badge/Helm-chart-0F1689)](https://helm.sh)
[![code-server](https://img.shields.io/badge/code--server-4.135.0-blueviolet)](https://github.com/coder/code-server)
[![pi-coding-agent](https://img.shields.io/badge/pi--coding--agent-0.83.0-blue)](https://www.npmjs.com/package/@earendil-works/pi-coding-agent)
[![ACP](https://img.shields.io/badge/ACP%20client-formulahendry.acp--client%400.2.0-green)](https://open-vsx.org/extension/formulahendry/acp-client)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

[English](README.md) · **繁體中文**

用 Helm 把 [`code-server`](https://github.com/coder/code-server)（瀏覽器版 VS Code）部署到 k3s，透過 Cloudflare Tunnel 對外，內建 [pi coding agent](https://github.com/earendil-works/pi)、[pi-acp](https://www.npmjs.com/package/pi-acp)、以及預先接好線的 [ACP Client](https://open-vsx.org/extension/formulahendry/acp-client) 聊天側欄。

這個 chart 部署的是跟 `Woow_podman_code_server_package` **完全相同的 image**——同一顆 image，代表 pi 那層不可能在兩個部署之間漂移。這是 WOOWTECH 三個對齊的 code-server 部署之一（podman、一個 [Home Assistant add-on](https://github.com/WOOWTECH/Woow_ha_code_server_add_on)、以及這份 chart）；完整跨平台契約見 [`PARITY_CONTRACT.md`](PARITY_CONTRACT.md)。

這裡的 pi 狀態**只屬於這個部署**。

---

## 提供什麼

| | |
|---|---|
| **對外方式** | Cloudflare Tunnel → ClusterIP Service，不用 Ingress——路徑根目錄、真憑證 |
| **IDE** | code-server 4.135.0 |
| **Agent** | pi 0.83.0，右側 ACP chat panel 直接可用；每個 terminal 的 PATH 上都有 `pi` |
| **Workspace** | 專屬的 `workspace` PVC（20Gi，Longhorn） |
| **持久化** | pi 狀態有自己的 PVC（5Gi）；IDE 設定放在同一顆 volume 的 subPath |
| **備份** | 選用的 CronJob，tar 到第三顆 PVC，保留最新 7 份 |

## 為什麼這裡的聊天 webview 不用額外處理就能動

Cloudflare Tunnel 讓 code-server 坐落在路徑根目錄、背後是真正被作業系統信任的邊緣憑證——讓 VS Code webview 的 ServiceWorker 能註冊需要的兩個條件（安全 context、沒有路徑前綴這種意外情況）在這裡天生就滿足，這正是 podman package 自己的 `README.md#security` 裡說純 HTTP 區網**不**滿足的那兩個條件。完整推理見 `PARITY_CONTRACT.md` 的 webview 驗證結論，剩下唯一要手動做的瀏覽器檢查見 `docs/DEPLOYMENT.md`。

## 安裝

完整前置條件與 namespace 初始化：[`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md)。精簡版：

```bash
kubectl --context woow-k3s create namespace code-server
kubectl -n code-server create secret generic code-server-auth --from-literal=PASSWORD='...'
kubectl -n code-server create secret generic code-server-cf-creds --from-file=credentials.json=./credentials.json

./scripts/deploy.sh
```

### 首次使用

```bash
kubectl --context woow-k3s -n code-server exec -it deploy/code-server -c code-server -- sh -lc 'pi login'
```

## 目錄結構

```
charts/code-server/
  Chart.yaml / values.yaml       chart 預設值，每個選項都有說明
  templates/
    deployment.yaml                initContainer pi-seed + code-server 本體
    service.yaml                   ClusterIP，直接指到 code-server:8080——沒有 nginx sidecar
    cloudflared.yaml + configmap-cloudflared.yaml   專屬的 tunnel Deployment + git 版控的路由設定
    pvc-data.yaml / pvc-backup.yaml
    secret-auth.yaml                選用——通常用 auth.existingSecret 代替
    configmap-settings.yaml         settings.json 需要的 6 個必要 key
    networkpolicy.yaml              選用
    cronjob-backup.yaml             選用
    tests/smoke.yaml                helm test——在叢集內 curl /healthz
values-woow.yaml                  woow-k3s 這個實例自己的設定值
deploy/rendered/code-server-woow.yaml   CI 算出來的 manifest（tunnel ID 是佔位值，不要直接 apply）
scripts/{deploy.sh,uninstall.sh}
tests/
  lib/parity.sh                    跟 podman/HA 兩個 repo 共用的轉接器（PARITY_TARGET=k3s）
  smoke-container.sh / smoke-acp.sh / smoke-pi-integration.sh
docs/{ARCHITECTURE.md,DEPLOYMENT.md}
.github/workflows/chart.yml        helm lint + template + 憑證檢查 + 自動把算出來的 manifest commit 回去
```

## 驗收部署

```bash
export PARITY_TARGET=k3s KUBECTL_CONTEXT=woow-k3s K3S_NAMESPACE=code-server
bash tests/smoke-container.sh
bash tests/smoke-acp.sh
bash tests/smoke-pi-integration.sh
helm test code-server -n code-server
```

## 安全

- `PASSWORD` 從外部建立的 Secret 來——絕對不是 chart 的預設值，也不是 podman quadlet 那組區網用的字面密碼。這裡是對外公開的 Cloudflare 網域。
- pi 唯一的憑證是 PVC 上 `/data/pi-agent/auth.json` 裡的 OAuth pair——任何在這個 namespace 有 `kubectl exec` 權限的人都讀得到。真正的管控是 `pods/exec` 的 RBAC。
- 每個 container 都設了 `automountServiceAccountToken: false`、`allowPrivilegeEscalation: false`、`capabilities: drop: [ALL]`。
- `NetworkPolicy` 預設關閉（選用，跟這個叢集的預設慣例一致）——開啟後 ingress 只允許 tunnel + kubelet，egress 允許 DNS + 開放網際網路（扣掉叢集自己的 CIDR）。

完整內容見 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md#security-posture)。

## 相關

- [`Woow_podman_code_server_package`](https://github.com/WOOWTECH/Woow_podman_code_server_package) — 建置這個 chart 部署的那顆 image
- [`Woow_ha_code_server_add_on`](https://github.com/WOOWTECH/Woow_ha_code_server_add_on) — 同一套 pi/ACP 接線，包成 Home Assistant add-on
- [`Woow_k3s_pi_agent_package`](https://github.com/WOOWTECH/Woow_k3s_pi_agent_package) — 這份 chart 的結構所依循的房規範本
- [ACP Client (formulahendry)](https://open-vsx.org/extension/formulahendry/acp-client) — 渲染聊天面板的 VS Code extension

## 授權

MIT
