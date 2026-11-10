# code-server image

[50-project acceptance lab](qa/project-lab/) contains opt-in Node.js examples,
HTTP regression checks and reproducible standalone ZIP downloads. Run its
Node.js 22/Python 3 acceptance with `bash harness/check.sh` from the lab
directory. Browser checks are optional; enable the `browser` input when manually
running the Gitea acceptance workflow. The lab is source-only and does not require an image release or
changes to chart/platform version pins. Its dedicated Gitea workflow runs the
synthetic acceptance suite without deployment credentials or live services.

三代理候選版加入 Codex CLI 0.167.0／Codex ACP 2.6.0。Pi、Claude、Codex 共用該實例的 `/data/pi-agent/skills` 與 `/data/pi-agent/shared/mcp.json`；修改 MCP 後執行 `woow-agent-sync` 並重新連線。登入仍分開，既有租戶資料與帳號不會被其他實例覆蓋。正式 image digest 仍須通過既有 release gate。


供 PaaS 平台 cloud service 使用的 **code-server（瀏覽器版 VS Code）**，內建 Pi、Claude Code 與 Codex。

- Registry：`jcr-prod.woowtech.io/woow-paas-docker-local/code-server:{tag}`（tag = UTC `YYYYMMDD.HHMM`，走候選 tag → 核可 → promote）
- 平台側 **pin image digest**；chart 為 `woow-paas-charts` 的 `charts/code-server`（code-server 自己的密碼登入，沒有代理）。
- 上游：`WOOWTECH/Woow_podman_code_server_package`，其 GitHub Actions 發佈 `ghcr.io/woowtech/woow-code-server-amd64`。三邊（podman、HA add-on、k3s／PaaS）的共同基準寫在上游 `PARITY_CONTRACT.md`（1.3：code-server 4.139.1、pi 0.99.1＋pi-acp 0.0.34、Claude Code 2.1.285＋claude-agent-acp 0.84.0、ACP Client 0.2.0＋Claude Code 擴充）。本 image **以 digest 消費上游**，不重建。

## 這顆 image 改了什麼（相對上游）

| # | 改動 | 為什麼 |
|---|---|---|
| 1 | 釘版擴充（ACP Client、Claude Code）從使用者擴充目錄搬到 `/usr/lib/code-server/lib/vscode/extensions`（內建） | chart 把租戶 PVC 掛在使用者擴充目錄，租戶自己裝的擴充才能跨重啟保留；不搬的話釘版擴充會被 PVC 蓋掉 |
| 2 | 繁體中文語言包 `ms-ceintl.vscode-language-pack-zh-hant` 1.131.0（內建），並在 build 時寫好 `languagepacks.json`（VS Code 只在安裝／移除擴充時寫這個檔，內建的語言包不登記就不會生效） | chart 預設 `--locale zh-tw`。Open VSX 最新只到 1.131，Code 1.139 之後新增的字串會顯示英文 |
| 3 | omnigent CLI 0.16.0：uv 管理的 Python 3.12.16 venv（`/opt/omnigent/tools/omnigent`，`omnigent`／`omni` 連到 `/usr/local/bin`）。omnigent 與全部 94 個相依套件以 `omnigent-requirements.lock`（`uv pip compile --generate-hashes`）釘死，`uv pip install --require-hashes --no-deps` 安裝、build 時編好 bytecode（`UV_COMPILE_BYTECODE=1`）；verify 比對 venv 內套件＝lock。登入憑證與 host 身分放 `/data/pi-agent/omnigent`（`OMNIGENT_CONFIG_HOME`／`OMNIGENT_DATA_DIR`） | 讓這台 IDE 可以 `omnigent login <Omnigent 網址>` 後成為 Omnigent 的機器（host）。host **跑在 code-server 容器裡**（沒有 sidecar）：image 只提供 CLI 與入口 stub（第 8 項），supervisor／launcher 由 chart 0.1.2 起以共用套件（woow-paas-charts `shared/omnigent-host`）的 ConfigMap 掛入，租戶登入後執行 host、重啟後自動回來。hash 鎖定讓每次 build 裝到同一批套件，被竄改或沒釘到的套件會讓 build 失敗 |
| 4 | 刪掉 Claude Agent SDK 自帶的 `claude` 執行檔 | SDK 找不到自帶的就用 PATH 上的 `claude`（映像裡釘版的 2.1.285），省約 200MB |
| 5 | 刪掉內建的 GitHub Copilot Chat 擴充（170MB），並把 ACP Client 的預設 agent 清單清空 | 側欄只列這個 image 真的有的 Pi、Claude 與 Codex（chart 寫入）；ACP Client 的清單＝`acp.agents` 的 package.json 預設值與使用者設定深度合併，無法從 settings.json 刪掉內建那 11 個（例如未安裝的 Copilot、Gemini）。chart 另設 `chat.disableAIFeatures`，核心聊天面板不再邀請安裝 Copilot |
| 6 | tmux 釘在 Debian 13 的 `3.5a-3`（`TMUX_VERSION`），verify 比對套件版本完全相符；確認 kit 需要的 `flock`、`setsid`、`dumb-init` 都在（每個指令各查一次） | Omnigent 在 host 上用 runner 自己的 tmux 終端機跑原生 Claude／pi（claude-native、pi-native），沒有 tmux（或低於 3.3）就拒絕啟動。釘版讓重建可重現：Debian 換掉這個版本時 build 會失敗，要明確改版號 |
| 7 | `/etc/bash.bashrc` 最後讀 `/etc/woow/bashrc.d/*.sh`；image 內建 `omnigent-host.sh`：chart 掛了套件時 source `/etc/omnigent-host/omnigent-host-profile.sh` | 新開的終端機（互動式、非 login 的 bash，不讀 `/etc/profile.d`）在租戶需要動手時印出確切指令（尚未登入的 `omnigent login …`、登入失效、換帳號後的 `omnigent host reset-id --yes`、image 太舊）；`kubectl exec` 進來的 shell 也會把套件的 `bin`（`omnigent` 防呆、`omnigent-host-status`）放到 PATH 最前面。沒掛套件的環境不會印任何東西 |
| 8 | ENTRYPOINT 改成 `dumb-init -- python3 /opt/woow-connectors/omnigent/kit-entry.py /usr/local/bin/omnigent-host-entry /usr/local/bin/woow-code-server-entry --bind-addr 0.0.0.0:8080 .`；`kit-entry.py` 準備私有 connector kit overlay 後交給既有入口；`omnigent-host-entry` 是共用套件的 `image/omnigent-host-entry`（逐 byte，build 時比對 sha256） | chart 掛了套件（`omnigentHost.enabled`）時，stub 交給套件的 launcher：supervisor 在背景（自己的 session）等租戶登入、維持 `omnigent host`，code-server 照原樣啟動；SIGTERM 時先停 host 再停 code-server。沒掛套件時直接 exec 上游 entrypoint，行為與以前相同。dumb-init 是 PID 1，回收 session 留下的程序。chart 的 args（`--locale`、`--trusted-origins`）照舊接在後面 |
| 9 | 開發工具（QA CS-09）：`python3-pytest` 8.3.5-2（Debian，系統 python 可 `python3 -m pytest`）、ruff 0.16.10（`devtools-requirements.lock` hash 鎖定，裝在 `/opt/devtools`，連到 `/usr/local/bin/ruff`）、`fonts-noto-cjk`＋`fontconfig`（版本都釘死） | 系統 python 被 PEP 668 鎖住，裝不了 pytest／ruff；沒有字型時圖表、截圖、PDF 的中文會變方塊 |
| 10 | HOME 跨重啟保存（QA CS-01／CSV-M1／CSV-M3）：`~/.gitconfig`、`~/.bash_history` 是連到 `/data/pi-agent/home/` 的連結（pi-seed 本來就把 `~/.pi` 放在那裡）；`NPM_CONFIG_PREFIX=/home/coder/.local`、`NPM_CONFIG_CACHE=/home/coder/.cache/npm`，`~/.local/bin` 接在 PATH **最後面**；刪掉 base image 在 build 時產生的 `~/.config/code-server/config.yaml` | 平台改任何設定都會重啟 pod，HOME 在容器層就會整個消失。`~/.ssh`、`~/.config`、`~/.local` 由 chart（0.1.2）從 pi-data PVC 掛進來、`~/.cache` 是有大小上限的 emptyDir；`npm i -g`、`uv tool install` 的工具因此留在 PVC 上。原本的 `/opt/npm-global` 不在 PATH 上、又寫在節點系統碟。`~/.local/bin` 跨重啟、跨換版保存，所以排在系統目錄之後：裡面同名的 `claude`、`pi`、`omnigent`、`dumb-init`、`fixuid`（上游 entrypoint 用 PATH 找）永遠蓋不過 image 釘版的那一份，新指令照樣找得到（verify 用假執行檔實測）。IDE 終端機是 login shell（/etc/profile 重設 PATH，再由 profile.d 與 `~/.profile` 重建），所以 image 也把 `~/.profile` 的 `~/bin`、`~/.local/bin` 與 `/etc/profile.d/npm-global.sh` 的兩個 npm-global bin 改成**接在後面**，kit 的防呆（`/etc/omnigent-host/bin`）因此在 IDE 終端機裡也排在所有租戶寫得到的目錄之前；verify 以 `bash -lic` 實測。base image 的 config.yaml 帶一組 build 時產生、每個容器都一樣的密碼；chart 讓 code-server 只讀唯讀的 `CODE_SERVER_CONFIG`（`auth: password`），verify 也以這個方式、搭配寫壞的 `~/.config/code-server/config.yaml`（`auth: none`＋`hashed-password`）測登入 |

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
# 瀏覽器開 http://localhost:8080，用 pw 登入：介面是繁中、側欄 ACP 有 Pi、Claude 與 Codex 三個 agent
```

## Pi 經由 LiteLLM／OpenAI 相容閘道調用 GPT-6 工具

若 `models.json` 把 GPT-6 系列設為 `openai-completions`，帶推理的工具呼叫可能遺失參數。2026-11-10 實測同一閘道、GPT-6 Sol 與 GPT-6.1 Sol：Chat Completions 平行呼叫兩個工具時參數為空；Responses 保留完整參數。改用 Responses 後，Pi 0.99.1 對兩個模型各執行一次 HA 模板與 Context7 真實 MCP 呼叫，共 4 次成功、0 次重試。

[OpenAI 官方相容性說明](https://developers.openai.com/api/docs/guides/latest-model)要求 GPT-6.1 Sol 工具呼叫使用 Responses；GPT-6 Sol 在 Chat Completions 的工具呼叫僅支援 `reasoning_effort: none`。這裡保留推理能力，使用 Responses。

先確認自己的閘道確實支援 `/v1/responses`，再於 code-server 終端執行（替換供應商名稱）：

```sh
node /opt/woow-agent-tools/configure-pi-responses.mjs --provider my-gateway
node /opt/woow-agent-tools/configure-pi-responses.mjs --provider my-gateway --apply
```

第一行僅預覽。第二行只為該供應商的 GPT-6 模型加上 `api: "openai-responses"`，保留其餘模型、金鑰、網址與推理設定，並建立權限 0600 的原始設定備份。未知 API、壞 JSON、符號連結或偵測到同時修改時會中止。此工具不在啟動時自動執行，也不建立或複製供應商登入。

完成後開啟新的 Pi 工作階段，再驗證實際工具參數與結果。模型出現在選單、工具列出成功，均不足以代表對話驗收通過。本次真實重測發生在 PaaS QA；工具在三種映像的原始碼與回歸測試一致，未因此宣稱 HA／Podman 正式環境已換版。

### Codex container sandbox compatibility

Native Codex and the ACP adapter use the same scoped bubblewrap compatibility launcher. See [sandbox setup and isolation verification](security/codex/README.md) for optional host profiles and the live probe. Existing sandbox and login settings are retained.
