# Woow code-server（WOOW PaaS 雲端服務）

[English](README.md)

瀏覽器版 VS Code，內建 Pi、Claude Code、Codex，每個租戶使用獨立實例。
本鏡像對齊已合併的三代理來源，PaaS 映像已通過發布核可。商城與既有租戶升級分別追蹤；
PaaS 的模型登入與真實對話測試仍待完成。

本 repo 是**唯讀來源鏡像**。正本在 Gitea 的 `woow-paas/woow-paas-charts`（`charts/code-server`）
與 `woow-paas/paas-odoo-ci`（`code-server`）。[MIRROR.md](MIRROR.md) 記錄來源提交與基底映像 digest。

| 功能 | 候選版行為 |
|---|---|
| IDE | code-server 4.139.1、繁中介面、固定版本 ACP 與 Claude Code 擴充 |
| 三代理 | Pi 0.99.1、Claude Code 2.1.285、Codex CLI 0.167.0／ACP 2.6.0；可從終端機或 ACP 側欄使用 |
| 共用 skills | `/data/pi-agent/skills`，三代理指向同一目錄 |
| 共用 MCP | `/data/pi-agent/shared/mcp.json`；修改後執行 `woow-agent-sync` 並重新連線 |
| 模型登入 | 分別執行 `pi login`、`claude auth login`、`codex login --device-auth` |
| IDE 登入 | 平台管理密碼；cookie proxy 補上 HttpOnly、Secure |
| 持久資料 | 工作區、代理資料分開使用 PVC，HOME、設定與自行安裝的擴充跨重啟保留 |
| 整合 | Omnigent host、選填模型與 Git 金鑰、同工作區 LiteLLM 網址 |

共用連線定義不代表共用模型訂閱、OAuth 登入、工具操作批准或對話上下文。
ACP 切換會斷開上一代理並清空面板顯示。不支援的 MCP 限制或同名技能衝突會阻止遷移並說明原因。
映像不包含登入憑證或私有 MCP 網址。

目前一般 T1 模板為 2 vCPU／8 GiB RAM／20 GiB 儲存（工作區 16 GiB、代理資料 4 GiB），實際方案以服務頁為準。

瀏覽器經平台 tunnel 進入 ClusterIP，再由 pod 內 nginx 轉到 code-server 的私人 Unix socket。
IDE 使用 uid 1000、不掛載 service-account token，並有 NetworkPolicy。密碼、容器內金鑰可見範圍、
HOME、Omnigent、LiteLLM 與升級細節見 [chart/README.md](chart/README.md)。

[image/README.md](image/README.md) 說明 PaaS 如何衍生自固定 digest 的 Podman 映像；
[PARITY_CONTRACT.md](PARITY_CONTRACT.md) 記錄三環境共同候選基準。
chart 與映像必須一起升級：上一版映像沒有 `codex-code`。

要連接 Omnigent，在 IDE 終端機執行 `omnigent login <server URL>`。
啟用 chart 的 host 整合後，supervisor 會在登入後自動啟動 host，pod 重啟後也會恢復；
以 `omnigent-host-status` 檢查，不要另開第二個 host。

## 同步來源

```bash
scripts/sync-from-gitea.sh                         # 兩個正本的 main
scripts/sync-from-gitea.sh <charts-ref> <ci-ref>    # 指定審查或候選提交
```

本 repo 的 CI 檢查鏡像與 chart，映像仍由 Gitea 發布。
舊單機版保留於 [`legacy/k3s-single-instance`](../../tree/legacy/k3s-single-instance) 與 `legacy-v0.1.0`。

[MIT 授權](LICENSE)
