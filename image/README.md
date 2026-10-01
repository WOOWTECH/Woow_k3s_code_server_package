# code-server image

供 PaaS 平台 cloud service 使用的 **code-server（瀏覽器版 VS Code）**，內建 pi 與 Claude Code。

- Registry：`jcr-prod.woowtech.io/woow-paas-docker-local/code-server:{tag}`（tag = UTC `YYYYMMDD.HHMM`，走候選 tag → 核可 → promote）
- 平台側 **pin image digest**；chart 為 `woow-paas-charts` 的 `charts/code-server`（code-server 自己的密碼登入，沒有代理）。
- 上游：`WOOWTECH/Woow_podman_code_server_package`，其 GitHub Actions 發佈 `ghcr.io/woowtech/woow-code-server-amd64`。三邊（podman、HA add-on、k3s／PaaS）的共同基準寫在上游 `PARITY_CONTRACT.md`（1.1：code-server 4.139.1、pi 0.99.1＋pi-acp 0.0.34、Claude Code 2.1.285＋claude-agent-acp 0.84.0、ACP Client 0.2.0＋Claude Code 擴充）。本 image **以 digest 消費上游**，不重建。

## 這顆 image 改了什麼（相對上游）

| # | 改動 | 為什麼 |
|---|---|---|
| 1 | 釘版擴充（ACP Client、Claude Code）從使用者擴充目錄搬到 `/usr/lib/code-server/lib/vscode/extensions`（內建） | chart 把租戶 PVC 掛在使用者擴充目錄，租戶自己裝的擴充才能跨重啟保留；不搬的話釘版擴充會被 PVC 蓋掉 |
| 2 | 繁體中文語言包 `ms-ceintl.vscode-language-pack-zh-hant` 1.131.0（內建），並在 build 時寫好 `languagepacks.json`（VS Code 只在安裝／移除擴充時寫這個檔，內建的語言包不登記就不會生效） | chart 預設 `--locale zh-tw`。Open VSX 最新只到 1.131，Code 1.139 之後新增的字串會顯示英文 |
| 3 | omnigent CLI 0.16.0（`uv tool`，uv 管理的 Python 3.12，裝在 `/opt/omnigent`），登入憑證與 host 身分放 `/data/pi-agent/omnigent`（`OMNIGENT_CONFIG_HOME`／`OMNIGENT_DATA_DIR`） | 讓這台 IDE 可以 `omnigent login <同工作區 Omnigent 內部網址>` 後 `omnigent host`，把 Omnigent 的工作跑在這台的 workspace；不自動啟動 |
| 4 | 刪掉 Claude Agent SDK 自帶的 `claude` 執行檔 | SDK 找不到自帶的就用 PATH 上的 `claude`（映像裡釘版的 2.1.285），省約 200MB |
| 5 | 刪掉內建的 GitHub Copilot Chat 擴充（170MB），並把 ACP Client 的預設 agent 清單清空 | 側欄只列這個 image 真的有的 pi 與 claude（chart 寫入）；ACP Client 的清單＝`acp.agents` 的 package.json 預設值與使用者設定深度合併，無法從 settings.json 刪掉內建那 11 個（Copilot、Gemini、Codex…，這裡都沒裝）。chart 另設 `chat.disableAIFeatures`，核心聊天面板不再邀請安裝 Copilot |

上游已經是 uid 1000（coder）、自帶 `/healthz`，不用再改。

## 升上游版本

1. 上游 podman repo 發版後，用 `mirror-image.yml` 把新的 `woow-code-server-amd64` 鏡像進 JCR（`/approve`）。
2. 改 `Dockerfile` 的 `ARG BASE=…@sha256:…`（index digest）；workflow 會沿用這個 digest、改從 JCR 鏡像拉。
3. 版本基準若變了，一併改 workflow「Verify built image」裡的版本斷言與內建擴充的版本號。

## 本地驗證

```bash
docker build -f code-server/Dockerfile -t code-server:dev code-server
docker run --rm code-server:dev id -u                                   # 1000
docker run --rm -d --name cs -e PASSWORD=pw -p 8080:8080 code-server:dev --locale zh-tw
# 瀏覽器開 http://localhost:8080，用 pw 登入：介面是繁中、側欄 ACP 有 pi 與 claude 兩個 agent
```
