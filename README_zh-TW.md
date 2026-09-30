# Woow code-server（WOOW PaaS 雲端服務）

[English](README.md) · **繁體中文**

瀏覽器版 VS Code（[code-server](https://github.com/coder/code-server)），內建 **pi coding agent** 與 **Claude Code**，是 WOOW PaaS 平台上每個租戶一套的雲端服務。

> **這個 repo 是唯讀鏡像。** 正本在內部 Gitea（`woow-paas/woow-paas-charts` 的 `charts/code-server/`，以及 `woow-paas/paas-odoo-ci` 的 `code-server/`）。對應的來源 commit 見 [MIRROR.md](MIRROR.md)。請不要在這裡修改 `chart/` 或 `image/`。

## 你會得到什麼

| | |
|---|---|
| **IDE** | code-server 4.139.1（Code 1.139.1），預設繁體中文介面 |
| **AI 助手** | pi 0.99.1 與 Claude Code 2.1.285：終端機（`pi`、`claude`）、ACP 聊天側欄（agent `pi` 與 `claude`），另附 Claude Code 官方擴充 |
| **登入** | code-server 自己的密碼登入，沒有帳號。密碼在開通時顯示一次；之後可在服務頁「Admin Credentials」重設，或改成自己的密碼，服務約一分鐘後重啟生效 |
| **模型** | 每個助手在終端機登入一次（`pi login`、`claude`），或在服務頁填選填的 Anthropic／OpenRouter API Key。只填 OpenRouter 時，Claude Code 也會改走 OpenRouter |
| **Git** | 服務頁可選填 Git Token，git 連 github.com 時自動帶入，不會寫到磁碟 |
| **儲存** | 工作區 20 GB（`/workspace`）＋ 5 GB 放 pi／Claude Code 登入、sessions、IDE 設定與你自己裝的擴充，重啟都會保留 |
| **omnigent** | 內建 `omnigent` 指令，可把這台 IDE 接成 Omnigent 的機器（見下方） |
| **規格／價格** | 2 vCPU／4 GB RAM／25 GB 磁碟，每月 4,500 點（7 天免費試用） |

## 架構

```
租戶瀏覽器 ──▶ Cloudflare tunnel（paas-cs-<ws>-<id>.woowtech.io）
                        │
                        ▼
              Service <release>-code-server :8080
                        │
   ┌────────────────────┴───────────────────────────────────┐
   │ Deployment <release>-code-server（1 份，Recreate）     │
   │  init  pi-seed：seed /data/pi-agent、合併 settings     │
   │  main  code-server --locale zh-tw                      │
   │        --trusted-origins <公開網址的 host>             │
   │        PASSWORD ← Secret <release>-code-server-secret  │
   └───────────┬───────────────────────────┬────────────────┘
               ▼                           ▼
   PVC <release>-code-server-workspace   PVC <release>-code-server-pi-data
   /workspace（20 Gi）                   /data/pi-agent＋IDE User/＋extensions/（5 Gi）
```

- 非 root（uid 1000），拿掉所有 capabilities，不掛 service account token。
- NetworkPolicy 預設全擋：只允許連 DNS、公網與同一個 namespace，連不到內網和叢集 API。
- 換密碼時 chart 不會改 pod template，所以平台的重設就是 `helm upgrade`＋重啟。

### Image

[`image/`](image/) 是疊在 WOOWTECH podman image（[`Woow_podman_code_server_package`](https://github.com/WOOWTECH/Woow_podman_code_server_package)，以 digest 引用）上的一薄層：把釘版擴充（ACP Client、Claude Code）搬進 code-server 的內建擴充目錄，並加上繁體中文語言包與 `omnigent` 指令。建置、驗證與發佈都在 `woow-paas/paas-odoo-ci`，要經過正式環境核可，不會從這個 repo 建置。

## 與 podman、Home Assistant 版的對齊

這是 WOOWTECH code-server 三件組（podman package、Home Assistant add-on、這個雲端服務）裡的 **k3s 這一邊**。三邊共用同一份釘版基準：code-server、pi、pi-acp、Claude Code、ACP 接線與 pi 狀態目錄結構，定義在 [PARITY_CONTRACT.md](PARITY_CONTRACT.md)（三個 repo 內容相同）。繁中介面、平台管理的密碼、選填金鑰、保留自裝擴充與 omnigent 指令是 PaaS 版才有的（contract §6）。

## 連到 Omnigent

**同一個工作區**裡的 Omnigent 服務可以用叢集內部位址連（不繞公網）：`http://<omnigent release>-omnigent.<namespace>.svc.cluster.local:8000`。在 code-server 的終端機執行：

```bash
omnigent login http://<release>-omnigent.<namespace>.svc.cluster.local:8000
omnigent host
```

omnigent 的登入與機器身分存在 `/data/pi-agent/omnigent`（持久磁碟），重啟後仍是同一台機器。想讓 omnigent 的 Pi 直接沿用這台 IDE 裡 pi 的登入（不用另外給 API Key），在 `/data/pi-agent/omnigent/config.yaml` 加上「Pi original auth」：

```yaml
providers:
  pi-original:
    kind: subscription
    cli: pi
    default: pi
```

注意：
- 一台機器登記在某個 omnigent 帳號後，換帳號重連會被拒絕（409）。
- `omnigent host` 不會自動啟動，服務重啟後要再執行一次。

## 同步

```bash
scripts/sync-from-gitea.sh                         # 兩個 Gitea repo 都用 main
scripts/sync-from-gitea.sh <charts-ref> <ci-ref>
```

這裡的 CI 只做 chart lint、render 與鏡像結構檢查，不建置、不發佈任何東西。

## 歷史

先前的單機版 k3s package（自帶 cloudflared，`code-server` namespace，網址 `code-server-woow-k3s.woowtech.io`）保存在 [`legacy/k3s-single-instance`](../../tree/legacy/k3s-single-instance) 分支與 `legacy-v0.1.0` tag。

## 授權

[MIT](LICENSE)
