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

context 一律明確指定（helm 用 `--kube-context`，kubectl 用 `--context`）。完整前置條件與
namespace 初始化：[`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md)。

這個 chart **不渲染 Namespace**：Helm 的 release 記錄就放在 release namespace 裡，
如果 Namespace 變成 chart 的資源，`helm uninstall` 就有能力把它刪掉——連同那些
刻意保留的 PVC 一起。namespace 請自己建（或用 `--create-namespace`）。

### A. woow-k3s 的做法——Secret 在 chart 外面建立

`secrets.create` 預設 `false`，chart 只引用已經存在的 Secret，所以任何 upgrade
都不可能覆蓋掉真正的密碼或真正的 tunnel 憑證。

```bash
kubectl --context woow-k3s create namespace code-server
cp examples/secrets.example.yaml ~/secure/code-server-secrets.yaml   # 把每個 REPLACE_ME 填掉
kubectl --context woow-k3s -n code-server apply -f ~/secure/code-server-secrets.yaml

# 從 clone 安裝
git clone https://github.com/WOOWTECH/Woow_k3s_code_server_package.git
cd Woow_k3s_code_server_package
helm --kube-context woow-k3s upgrade --install code-server charts/code-server \
  -n code-server -f values/woow-k3s/code-server.yaml --wait --timeout 5m

# 或交給包裝腳本，它會先做 pre-flight（context、namespace、兩個 Secret、StorageClass），
# 裝完再跑 parity smoke 測試
./scripts/deploy.sh
```

直接用 repo 的 tarball、不 clone。chart 在子目錄裡，所以要先解壓，不能把 URL 直接餵給 helm：

```bash
curl -sSL https://github.com/WOOWTECH/Woow_k3s_code_server_package/archive/refs/heads/main.tar.gz | tar xz
helm --kube-context woow-k3s upgrade --install code-server \
  Woow_k3s_code_server_package-main/charts/code-server -n code-server \
  -f Woow_k3s_code_server_package-main/values/woow-k3s/code-server.yaml
```

### B. 讓 chart 自己產生 Secret——測試用

```bash
helm --kube-context woow-k3s install code-server charts/code-server \
  -n ht-code-server --create-namespace \
  --set persistence.storageClassName=longhorn-delete \
  --set secrets.create=true \
  --set secrets.authPassword="$(openssl rand -hex 24)" \
  --set keepOnUninstall=false
kubectl --context woow-k3s -n ht-code-server port-forward svc/code-server 8080:8080
```

`cloudflare.enabled` 預設是 **false**，這是刻意的：測試安裝絕對不能對著真的 tunnel
再起一組 connector——Cloudflare 會把流量分給它和正式環境。測試的 release 請用
port-forward 連。

### 首次使用

```bash
kubectl --context woow-k3s -n code-server exec -it deploy/code-server -c code-server -- sh -lc 'pi login'
```

## 主要設定值

| 設定值 | 預設 | 說明 |
|---|---|---|
| `keepOnUninstall` | `true` | 在每顆 PVC 和 chart 產生的 Secret 上加 `helm.sh/resource-policy: keep` |
| `image.digest` / `image.tag` | `""` / `""` | 優先用 digest。兩個都空時，tag 退回 `appVersion` 並把 `+` 換成 `_`（OCI tag 不允許 `+`） |
| `persistence.storageClassName` | **無預設——必填** | 刻意不給預設：woow-k3s 上有*兩個* StorageClass 都標著 `(default)` |
| `persistence.piData.size` / `workspace.size` | `5Gi` / `20Gi` | RWO，帶 `keep` |
| `secrets.create` | `false` | 改成 true 才會用 `secrets.*` 產生 `code-server-auth`（以及 tunnel 憑證），否則一律引用既有 Secret |
| `auth.existingSecret` | `code-server-auth` | 存放 `PASSWORD` key 的 Secret |
| `cloudflare.enabled` | `false` | 專屬 tunnel Deployment；需要 `tunnelId`、`hostname` 與憑證來源 |
| `cloudflare.replicas` | `2` | connector 數量，用 anti-affinity 分散 |
| `persistence.backup.enabled` / `backup.schedule` / `backup.keep` | `false` / `17 3 * * *` / `7` | 每天把 pi-data + workspace tar 到第三顆 PVC |
| `networkPolicy.enabled` | `false` | 選用，而且對已經在跑的 pod 是**執行期行為改變**——見「安全」 |
| `codeServer.resources` | 500m/1Gi → 4/8Gi | 這個叢集同時跑 16 個正式 Odoo 租戶 |
| `imagePullSecrets.enabled` | `false` | GHCR package 是公開的；只有改成私有時才需要打開 |

完整清單見 [`charts/code-server/values.yaml`](charts/code-server/values.yaml)。
線上實例自己的值：[`values/woow-k3s/code-server.yaml`](values/woow-k3s/code-server.yaml)
（不含任何 secret——那些只存在叢集的 Secret 裡）。

## 目錄結構

```
charts/code-server/
  Chart.yaml / values.yaml       chart 預設值，每個選項都有說明
  templates/
    deployment.yaml                initContainer pi-seed + code-server 本體
    service.yaml                   ClusterIP，直接指到 code-server:8080——沒有 nginx sidecar
    cloudflared.yaml + configmap-cloudflared.yaml   專屬的 tunnel Deployment + git 版控的路由設定
    pvc-data.yaml / pvc-backup.yaml
    secrets.yaml                    只在 secrets.create=true 時渲染；否則用既有 Secret
    configmap-settings.yaml         settings.json 需要的 6 個必要 key
    networkpolicy.yaml              選用
    cronjob-backup.yaml             選用
    tests/smoke.yaml                helm test——在叢集內 curl /healthz 與 /login
values/woow-k3s/code-server.yaml  woow-k3s 這個實例自己的設定值（不含 secret）
examples/secrets.example.yaml     每個 Secret key 的佔位範例
deploy/rendered/code-server-woow.yaml   算出來的參考 manifest（tunnel ID 是佔位值，不要直接 apply）
scripts/{deploy.sh,uninstall.sh,render.sh,check-drift.sh}
tests/
  lib/parity.sh                    跟 podman/HA 兩個 repo 共用的轉接器（PARITY_TARGET=k3s）
  smoke-container.sh / smoke-acp.sh / smoke-pi-integration.sh
docs/{ARCHITECTURE.md,DEPLOYMENT.md}
.github/workflows/chart.yml        lint、渲染所有 values 組合、kubeconform -strict、
                                   required() 守門與 secret 洩漏檢查、render 是否過期
```

## 驗收部署

```bash
helm --kube-context woow-k3s test code-server -n code-server --logs   # 唯讀：/healthz + /login

export PARITY_TARGET=k3s KUBECTL_CONTEXT=woow-k3s K3S_NAMESPACE=code-server
bash tests/smoke-container.sh
bash tests/smoke-acp.sh
bash tests/smoke-pi-integration.sh

# repo 與 Helm release 的比對：manifest 與 values（exit 0 = 完全一致）
scripts/check-drift.sh
```

## 卸載——資料會留下

```bash
helm --kube-context woow-k3s uninstall code-server -n code-server
```

這會移除兩個 Deployment、Service、ConfigMap 與 CronJob。因為 `keepOnUninstall=true`，
三顆 PVC 都會留下（pi 登入、sessions、workspace、備份），namespace 本來就不是 chart 的
資源，`code-server-auth` / `code-server-cf-creds` 是在 chart 外面建立的、完全不會被動到。
重新安裝就會接回同樣的 volume。

`scripts/uninstall.sh` 做一樣的事，並把「真的要刪資料」的指令印出來（加 `--purge` 會先問一次）。
Longhorn 的 reclaim policy 是 `Retain`，就算刪了 PVC，PV 也會停在 `Released`，要有人再手動刪。

## 接管或升級線上的 release

woow-k3s 上 namespace `code-server` 裡的 `code-server` release 已經由這份 chart 用 Helm 管著，
而 `values/woow-k3s/code-server.yaml` 就是它的 source of truth：

```bash
scripts/check-drift.sh    # helm get manifest == helm template、helm get values == 這個檔案
```

把線上 release 升級到這個 chart 版本不會替換任何物件、也不會重啟 pod：渲染出來的物件
跟現在跑的逐欄位相同（只差一段被搬進 `_helpers.tpl` 的 YAML 註解，以及 `helm test` 的
hook pod——那不屬於 release manifest）。

升級前有兩件事要知道：

- `networkPolicy.enabled` 要維持 `false`，跟實例設定檔一樣。打開它會加上一條這顆 pod
  從來沒有受過的政策，那是執行期行為改變，應該安排成獨立的一次上線。
- 線上的 pod template 帶著一個來自手動 `kubectl rollout restart` 的
  `kubectl.kubernetes.io/restartedAt` annotation。Helm 的 three-way merge 不會動它
  （舊 render 和新 render 都沒有這個欄位），所以 upgrade 不會重啟 pod；但如果拿
  `deploy/rendered/...` 去 `kubectl apply`，它會被移除並造成重啟——這也是那個檔案
  只能當參考的另一個理由。

## 安全

- `PASSWORD` 從外部建立的 Secret 來——絕對不是 chart 的預設值，也不是 podman quadlet 那組區網用的字面密碼。這裡是對外公開的 Cloudflare 網域。
- 那一組共用密碼是公開網域上**唯一**的存取控制：沒有 Cloudflare Access policy、沒有 SSO、沒有 MFA、沒有個人身分。拿到密碼的人就拿到 shell、agent，以及 pi 的 OAuth 憑證。
- pi 唯一的憑證是 PVC 上 `/data/pi-agent/auth.json` 裡的 OAuth pair——任何在這個 namespace 有 `kubectl exec` 權限的人都讀得到。真正的管控是 `pods/exec` 的 RBAC。每日備份也會把它 tar 進去。
- 每個 container 都設了 `automountServiceAccountToken: false`、`allowPrivilegeEscalation: false`、`capabilities: drop: [ALL]`。
- VS Code 的 Workspace Trust 在種下的 settings 裡是**刻意關閉**的（ACP 側欄需要它關掉），所以任何 clone 下來的 repo 的 tasks 與 extension 行為都不會再問一次就直接信任。見 `PARITY_CONTRACT.md` §2.5。
- `NetworkPolicy` 是選用的，而且線上實例是**關閉**的：這顆 pod 執行模型寫出來的程式，目前可以連到叢集其他地方和區網。打開後 ingress 只允許 tunnel、`helm test` pod 與節點 CIDR，egress 允許 DNS 加上網際網路（扣掉叢集自己的 CIDR）——請先在測試 namespace 確認 pi 需要的東西都還連得到。

完整內容見 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md#security-posture)。

## 相關

- [`Woow_podman_code_server_package`](https://github.com/WOOWTECH/Woow_podman_code_server_package) — 建置這個 chart 部署的那顆 image
- [`Woow_ha_code_server_add_on`](https://github.com/WOOWTECH/Woow_ha_code_server_add_on) — 同一套 pi/ACP 接線，包成 Home Assistant add-on
- [`Woow_k3s_pi_agent_package`](https://github.com/WOOWTECH/Woow_k3s_pi_agent_package) — 這份 chart 的結構所依循的房規範本
- [ACP Client (formulahendry)](https://open-vsx.org/extension/formulahendry/acp-client) — 渲染聊天面板的 VS Code extension

## 授權

MIT
