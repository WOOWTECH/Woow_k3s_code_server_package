# code-server

三代理候選版加入 Codex CLI 0.167.0／Codex ACP 2.6.0。Pi、Claude、Codex 共用該實例的 `/data/pi-agent/skills` 與 `/data/pi-agent/shared/mcp.json`；修改 MCP 後執行 `woow-agent-sync` 並重新連線。登入仍分開，既有租戶資料與帳號不會被其他實例覆蓋。正式 image digest 仍須通過既有 release gate。


瀏覽器版 VS Code（code-server）cloud service chart，內建 Pi、Claude Code 與 Codex。per-instance、ClusterIP、
兩顆 RWO PVC（`/workspace`、`/data/pi-agent`），由 paas-operator 部署成 `svc-{ref[:8]}` 到 `paas-ws-*`。
認證是 code-server 自己的密碼登入（平台的 `config.sensitive.admin_password`），沒有 auth-proxy；0.1.4 起入口是 pod 內
一個只改 cookie 屬性的 nginx（`cookieProxy`，見下方「Session cookie」）。
密碼登入無法從容器裡關掉：code-server 只讀 chart 管理的唯讀設定檔（`CODE_SERVER_CONFIG=/etc/code-server/config.yaml`，
內容只有 `auth: password`，來自 settings ConfigMap），並固定帶 `--auth password`。`~/.config/code-server/config.yaml`
雖然在 PVC 上、租戶或 session 寫得進去，但 code-server 不會讀它，所以寫 `auth: none` 或 `hashed-password` 都無效，
平台的「重設密碼」也一定生效（round-3 審查的 MAJOR，sandbox 實測過寫入後刪 pod 仍要 chart 的密碼）。
image：paas-odoo-ci `code-server/`。

| 容器 | 角色 | Port |
| --- | --- | --- |
| `pi-seed`（init） | 初始化 pi／Claude Code 狀態目錄、把必要設定合併進 IDE 的 `settings.json`、把 HOME 的骨架種到 PVC（不覆蓋租戶檔案） | — |
| `code-server` | IDE 本體；0.1.2 起 Omnigent host 也在這個容器裡（背景）。0.1.4 起聽 pod 內的 unix socket（`/run/code-server/code-server.sock`） | — |
| `cookie-proxy` | 0.1.4（#1458，`cookieProxy.enabled`，預設開）：nginx，對外唯一入口，轉給 code-server 的 socket，並在 session cookie 加上 HttpOnly＋Secure | 8080 |

`cookieProxy.enabled=false` 時回到 0.1.3 的形狀（只有 `code-server` 一個容器，聽 0.0.0.0:8080）。

## Session cookie（0.1.4，#1458）

code-server 的登入 cookie（`code-server-session`，值是密碼的雜湊）上游沒有 HttpOnly／Secure，也沒有選項可開。
`cookieProxy` 讓 pod 內的 nginx 佔入口 8080，`proxy_cookie_flags` 幫這個 cookie 加上 **HttpOnly＋Secure**（頁面上的
JavaScript 讀不到、只走 https）；code-server 改用 `--socket` 聽 pod 私有的 Memory emptyDir，叢集裡沒有別的路可以繞過。
WebSocket（終端機、編輯器）、上傳下載都不緩衝直接串流；不寫 access log。沙盒實測：登入、工作台、終端機、登出都正常，
`document.cookie` 讀不到 session。

**仍未解決（上游設計）**：cookie 在密碼改變前一直有效——登出只刪掉那個瀏覽器的 cookie，伺服器端沒有 session 可撤銷，
也沒有閒置／絕對逾時。要立即讓所有登入失效：在平台「重設密碼」。根本修法（前置有伺服器端 session 的 auth proxy）見
woow_paas_platform #1458 的 PR 說明。

## 容器內看得到的密碼與金鑰（0.1.9，INFRA-DOC-007-2）

平台交給這個容器的祕密都是**環境變數**：登入密碼 `PASSWORD`（chart Secret 的 `admin_password`），以及服務頁選填的
`ANTHROPIC_API_KEY`、`OPENROUTER_API_KEY`（只填 OpenRouter 時也以 `ANTHROPIC_AUTH_TOKEN` 給 Claude Code）、`GIT_TOKEN`。

- **金鑰是刻意給工具用的**：終端機 `env`、擴充、pi、Claude Code、Omnigent session 都讀得到（這正是它們能用金鑰的原因）。
- **密碼也讀得到**：code-server 啟動時把 `PASSWORD` 從自己的 `process.env` 刪掉（上游 `src/node/cli.ts`），所以終端機的
  `env` 看不到，Omnigent session 也另外 unset；但 Linux 的 `/proc/<pid>/environ` 保留的是程序**啟動時**的環境，而容器裡
  所有程序都是同一個使用者（uid 1000），所以 `tr '\0' '\n' < /proc/1/environ` 一樣看得到密碼和全部金鑰。
- **風險**：裝到惡意擴充、或 AI 助手被提示注入（讀到惡意 README、網頁）時，可能把金鑰或密碼送出去；密碼外洩等於別人可以登入這個 IDE。

**建議租戶這樣做**（範本說明也寫了同樣的提醒）：

1. 模型金鑰改用 **LiteLLM 虛擬金鑰**（同工作區 LiteLLM 後台 Virtual Keys：設預算上限、只開需要的模型、可隨時撤銷，用法見下方
   「同工作區 LiteLLM」），或 OpenRouter 設額度上限的金鑰；不要貼 Anthropic／OpenRouter 主帳號金鑰。
2. Git Token 用最小權限（GitHub fine-grained token：限定 repo、設到期日）。
3. 只安裝信任的擴充。
4. 懷疑外洩：服務頁「管理員帳密」重設密碼（所有瀏覽器的登入同時失效），並到發行單位撤換金鑰。

**為什麼 chart 沒有直接擋**：code-server 和租戶的終端機是同一個 uid，code-server 啟動時讀得到的東西（env、設定檔、
Secret 掛載），容器裡其他程序也讀得到。評估過「啟動 stub 讀檔、exec 並清掉 `PASSWORD`」：exec 之後 code-server 自己的
`/proc/<pid>/environ` 仍是交給它的環境；改用設定檔傳密碼，檔案同樣讀得到（`hashed-password` 更糟，雜湊值就是 session
cookie 的值）。要真正隔離，密碼必須留在另一個容器（例如把密碼驗證移到 `cookie-proxy` 那層、code-server 改 `--auth none`
只聽 pod 內 socket），這會換掉 code-server 的登入頁與內建限流，屬產品決策，追蹤在
[charts#221](https://git-prod.woowtech.io/woow-paas/woow-paas-charts/issues/221)。

## 登入頁繁體中文（0.1.9，INFRA-DOC-007-3）

code-server 4.139.1 的登入頁只內建 en／zh-cn／ja／th／ur，`--locale zh-tw` 會退回英文，而且顯示
「Password was set from $PASSWORD.」（等於告訴擴充／AI 密碼放在哪個環境變數）。`codeServer.loginI18n`（預設 true）把
settings ConfigMap 的 `code-server-i18n.json` 以唯讀方式投影到 `/etc/code-server/i18n.json`，並帶 `--i18n` 給 code-server：
上游會把它蓋在**每一種**內建語言上（`src/node/i18n/index.ts` `loadCustomStrings`），所以不論 locale 退到哪裡都是繁中。
內容涵蓋上游 `en.json` 的全部 11 個 key（標題、說明、送出、錯誤訊息、限流），密碼提示改成指向 WOOW PaaS 服務頁
「管理員帳密」，不提環境變數或設定檔。設 false 回到上游字串。字串在 settings ConfigMap 裡，
改了會經 `checksum/settings` 重啟 pod（code-server 只在啟動時讀這個檔）；從 0.1.8 升到 0.1.9 也會因此重啟一次（約一分鐘，磁碟保留）。檔案不存在時 code-server 會拒絕啟動，所以參數與投影由同一個條件產生。

## Omnigent host（0.1.2，在 code-server 容器裡）

讓 Omnigent 可以在這台 IDE 上開 Claude Code／pi 的工作階段（session），用的是租戶自己在 IDE 裡登入的
`claude`／`pi`，檔案留在 `/workspace`。host 跟一般機器上的常駐程式一樣跑在 code-server 容器裡，自己往外
連到同工作區的 Omnigent 服務（容器對容器，跟連外部網路一樣）。

**啟動方式**：image 的 ENTRYPOINT 是 `dumb-init -- omnigent-host-entry /usr/bin/entrypoint.sh --bind-addr 0.0.0.0:8080 .`。
chart 掛了套件（`omnigentHost.enabled`，預設開）時，stub 交給套件的 launcher：

```
PID 1  dumb-init                          （回收殭屍程序）
 └─ sh omnigent-host-launch -- entrypoint.sh …   （約 1 MB，負責關機順序）
     ├─ supervisor.sh（背景、自己的 session）→ omnigent host → session（tmux／claude／pi）
     └─ entrypoint.sh → dumb-init → code-server（自己的 session，argv／env／cwd 不變）
```

- chart **不覆寫 command**，`--locale`、`--trusted-origins` 照舊當 args 接在 ENTRYPOINT 後面。
- SIGTERM：launcher 先停 supervisor（host 有 15 秒優雅停止，之後 SIGKILL），再把 SIGTERM 轉給
  code-server；`terminationGracePeriodSeconds` 60 秒足夠。
- 沒掛套件（`omnigentHost.enabled=false`）或 image 沒有 omnigent：stub 直接 exec 上游 entrypoint，跟 0.1.1 一樣。
- supervisor 絕不擋住或弄垮 code-server：缺東西（image 太舊、沒有 tmux…）就寫狀態檔後安靜結束。

supervisor、helper、launcher、狀態訊息、`omnigent` 防呆都是**共用套件** `shared/omnigent-host`，由
`scripts/sync-omnigent-host-kit.sh` 逐 byte 複製到 `files/omnigent-host/` 與 `templates/_omnigent-host.tpl`；
**不要直接改這裡的副本**，改 `shared/omnigent-host/` 後重跑 sync。行為、env 契約、狀態檔格式見
`shared/omnigent-host/README.md`。

**租戶要做的事（只做一次）**：在 IDE 終端機執行

```bash
omnigent login <Omnigent 網址>
# 例：omnigent login http://svc-5fd48417-omnigent.paas-ws-7948b087.svc.cluster.local:8000
```

輸入 Omnigent 的帳號密碼。**WOOW 預設用工作區 Omnigent 的 admin 帳號**（使用者的決定：三台 host 都由 admin
擁有）；其他租戶可以用日常帳號，套件不擋。幾秒內這台會以 **`code-server · <release>`** 出現在該帳號的
機器清單；之後每次重啟都會自動回來，不必再登入。需要租戶動手時（還沒登入、登入失效、換帳號後要
`omnigent host reset-id --yes`、image 太舊），每開一個終端機都會印出確切指令；隨時可以執行
`omnigent-host-status` 看完整狀態。登入指令裡的網址來自 `omnigentHost.serverUrl`（平台注入同工作區
Omnigent 的內部網址）。

- **不要自己再跑 `omnigent host`**：終端機裡的 `omnigent` 是套件的防呆，背景服務在跑時
  `omnigent host`／`omnigent host stop`／`omnigent start|stop` 會直接失敗並說明
  「already running, managed automatically — see omnigent-host-status」。`omnigent host status`、
  `omnigent host reset-id`、`omnigent login`、session 指令照常可用。
- **serverUrl 不會重啟 pod**：網址只寫進 `<release>-code-server-omnigent-host-runtime` ConfigMap（以目錄掛在
  `/etc/omnigent-host-runtime/`，不在任何 checksum 裡），supervisor 與 `omnigent-host-status` 每次都重讀。

**這個 chart 給套件的參數**

| 參數 | 值 |
|---|---|
| init（PID 1） | `dumb-init`（image ENTRYPOINT） |
| `HOME` | `/home/coder`（不設 `OG_HOME`；套件在 HOME 建 `~/.claude` → `CLAUDE_CONFIG_DIR`、`~/workspace` → `/workspace`） |
| `OG_CONFIG_HOME`＝`OG_DATA_DIR` | `/data/pi-agent/omnigent`（pi-data PVC；正式站已在這裡以 admin 登入；IDE 終端機的 `omnigent login` 也寫這裡） |
| workspace | `/workspace`（`omnigentHost.workspace` 可改） |
| providers | `claude-subscription,pi-original`（每顆 PVC 只補一次，不覆蓋租戶設定） |
| passthrough | `PI_CODING_AGENT_DIR,PI_AGENT_DATA_DIR,PI_TELEMETRY,PI_SKIP_VERSION_CHECK,DISABLE_AUTOUPDATER,OPENROUTER_API_KEY`，加上這個 chart 的 `ENABLE_CLAUDEAI_MCP_SERVERS,GIT_CONFIG_GLOBAL,NPM_CONFIG_PREFIX,NPM_CONFIG_CACHE,MAKEFLAGS,CMAKE_BUILD_PARALLEL_LEVEL,UV_CONCURRENT_BUILDS,PYTEST_XDIST_AUTO_NUM_WORKERS`（session 跟 IDE 終端機看到同一套設定） |
| unsetEnv | `PASSWORD,HASHED_PASSWORD,SUDO_PASSWORD`（code-server 的登入密碼不給 host） |
| 遙測 | `OMNIGENT_ANALYTICS=0`、`DO_NOT_TRACK=1`、`DISABLE_TELEMETRY=1`（關掉套件時也保留）＋ config.yaml `telemetry: false` |

**資源**：code-server 容器拿**整個方案**（T1：requests 500m／1Gi、limits 2 CPU／4Gi，與 0.1.1 相同），
host 與 session 共用這個 cgroup，不切分。保護 IDE 的方式（套件）：host 與 session 的 `oom_score_adj` 1000；
supervisor 的 memory guard 在容器工作集達 limit 的 90% 時先殺最大的 Omnigent session 程序，絕不碰
code-server、終端機或 host 本身。沒登入時 supervisor 只是睡覺的 shell（約 2 MB RSS）。

**網路**：host 只往外連 Omnigent（WebSocket），不開 port、不加 Service（0.1.4 的 cookie-proxy 不影響：它只處理進來的流量）。in-cluster 網址靠
`networkPolicy.sameNamespaceEgress`（預設 true）出得去，Omnigent 那端靠 operator baseline
`paas-baseline-allow-same-ns` 收得到；公開網址走一般的 internet egress。

**中斷連線與安全**：刪掉 `/data/pi-agent/omnigent/auth_tokens.json` 只是**本機登出**，server 端的 refresh
grant 仍有效（最長 `OMNIGENT_GRANT_MAX_LIFETIME_DAYS`）；要真正撤銷，請在 Omnigent 刪除或停用該帳號，
watchdog 會在 `watchSeconds`＋20 秒內停掉 host、狀態變「登入已失效」。Omnigent 暫時連不上（5xx、逾時、
重啟）不會被當成撤銷，host 會自己重連。session 以 IDE 使用者身分執行，讀得到 token 檔。不想要這個功能就把
`omnigentHost.enabled` 設成 false。

**需求**：image 要有 omnigent CLI、tmux ≥ 3.3、ENTRYPOINT 裡的 `omnigent-host-entry` 與
`/etc/woow/bashrc.d` hook（paas-odoo-ci `code-server/` 的 `20261002.1318` 或之後的 build）。chart 0.1.2 必須和新
image 一起上線：舊 image 沒有 stub，host 不會啟動（code-server 本身照常）；round-3 的候選 `20261002.0800`（#204，已逾時）
把持久化的 `~/.local/bin` 放在 PATH 最前面，上游 entrypoint 會執行那裡的 `fixuid`／`dumb-init`，**不可**和 0.1.2 搭配。

## HOME 跨重啟保存（0.1.2；0.1.4 起整個 HOME）

平台上改任何設定（API Key、Git Token、密碼）都會重啟 pod，以前 HOME 在容器層，重啟就全部消失
（QA CS-01／CSV-M1／CSV-M3）。0.1.2 起（`persistence.home.enabled`，預設 true）只保存下表幾個目錄；
**0.1.4 起（#1452）整個 `/home/coder` 就是 pi-data PVC 的 `home/` 目錄**——0.1.2／0.1.3 本來就把 `~/.ssh`、`~/.config`、
`~/.local`、`~/.pi`、`~/.gitconfig`、`~/.bash_history` 放在那裡，所以升級不會丟任何已保存的東西；另外 `~/.bashrc`、
`~/.profile` 的修改、`~` 下的檔案與目錄（`~/.nvm`、`~/.cargo`、`~/.npmrc`、conda…）也都跨重啟保存
（0.1.3 以前放在 `~` 根層的檔案本來就不保存，升級那次的重啟也一樣不會留下）。pi-seed 會把 image 的
`~/.bashrc`、`~/.profile` 等用 `cp -n` 種進去（已有的不覆蓋；image 之後改了這些檔案不會自動更新到既有服務），
不種 `~/.cache`（emptyDir）與 image 指回 `home/` 的連結（避免自我連結）；HOME 設成 0700。

| 位置 | 存在哪 |
|---|---|
| `~` 整個（0.1.4） | pi-data PVC 的 `home/`（subPath）；以下各項都在裡面 |
| `~/.ssh`、`~/.config`、`~/.local` | pi-data PVC 的 `home/.ssh`、`home/.config`、`home/.local`（0.1.2／0.1.3 是各自的 subPath）。`~/.local` 含 `npm i -g`（`NPM_CONFIG_PREFIX=~/.local`）、`uv tool install`、`~/.local/bin`（在 PATH 上，但排在系統目錄**之後**）；IDE 的 `User/`、`extensions/` 照舊掛在裡面 |
| `~/.gitconfig`、`~/.bash_history` | `/data/pi-agent/home/.gitconfig`、`.bash_history`（`GIT_CONFIG_GLOBAL`、`HISTFILE`；image 也把 `~/` 下的同名檔連過去） |
| `~/.pi` | `/data/pi-agent/home/.pi`（原本就是，pi-seed） |
| `~/.cache` | emptyDir，`persistence.cache.sizeLimit`（預設 2Gi）；npm 的 cache 也移到 `~/.cache/npm`。超過上限 kubelet 只驅逐這個 pod，不會再無上限寫進節點系統碟 |

**節點系統碟（0.1.4，#1434）**：每個容器都有 `ephemeral-storage` requests／limits（code-server 1Gi／8Gi，含 2Gi 的
`~/.cache`、`/tmp` 與容器層），超過只驅逐這個 pod。

pi-seed init（`files/pi-seed.sh`，放在 settings ConfigMap）用 `cp -an` 把 image 的 `~/.config`、`~/.local`
骨架種進 PVC，**絕不覆蓋**租戶已有的檔案（`~/.config/code-server` 不種，code-server 不讀它）；`~/.ssh` 保持 0700；
code-server 的語言包登記（`languagepacks.json`）以 image 的內容為準合併，租戶自己裝的語言包保留。
`settings.json` 有註解（JSONC，jq 讀不了）時保持原樣、照常啟動。
注意：這些都算在 pi-data 的 5Gi 裡（pi／Claude 狀態也在這顆）。

**`~/.local/bin` 不會蓋過 image 的釘版工具**：image 的 PATH 是系統目錄在前、`~/.local/bin` 在最後（2026-10-02
之後的 build），所以 `npm i -g`、`uv tool install` 裝的新指令照樣找得到，但同名的 `claude`、`pi`、`omnigent`、
`code-server`、`dumb-init` 等永遠是 image 那一份；要用自己裝的版本就打完整路徑（`~/.local/bin/claude`）。
IDE 終端機是 login shell（`/etc/profile` 重設 PATH），image 也把 `~/.profile`、`/etc/profile.d/npm-global.sh` 改成
接在後面，所以 IDE 終端機的順序是 `remote-cli → /etc/omnigent-host/bin（防呆）→ 系統目錄 → npm-global → ~/.local/bin`
（sandbox 用真的瀏覽器實測）。
kit 本身只執行 `OG_BIN=/usr/local/bin/omnigent`。`persistence.home.enabled=false` 時 `~/.ssh`、`~/.config`、
`~/.local` 回到容器層（重啟就消失），但 `~/.gitconfig`、`~/.bash_history` 仍經 image 的連結存在 pi volume。

## 其他（0.1.2）

- **Claude Code 不載入 claude.ai 帳號的遠端連接器**（Gmail、Drive…；QA CS-07）：`ENABLE_CLAUDEAI_MCP_SERVERS=false`，
  `claude.claudeAiMcpServers: true` 可以打開。
- `/etc/gitconfig` 加 `core.quotepath = false`（中文檔名不再顯示成八進位；QA CSV-M2），並保留 image 原本的
  git-lfs filter（chart 的掛載會蓋掉 image 的 `/etc/gitconfig`）。
- `MAKEFLAGS=-jN`、`CMAKE_BUILD_PARALLEL_LEVEL`、`UV_CONCURRENT_BUILDS`、`PYTEST_XDIST_AUTO_NUM_WORKERS` = CPU limit
  無條件進位（`nproc` 在容器裡回報的是整台節點的核心數；QA CS-10）；`codeServer.buildJobs` 可指定。

## 同工作區 LiteLLM（0.1.5）

同一個工作區有執行中的 LiteLLM 服務時，平台把它的叢集內網址注入 `llmGateway.baseUrl`
（`http://<release>-litellm.<ns>.svc.cluster.local:4000/v1`）；**只帶網址、不帶金鑰**，租戶自己填的非空值優先。

- IDE 容器（終端機、Omnigent session 也繼承）拿到 env **`LITELLM_BASE_URL`**＝OpenAI 相容 base URL。不設定 `OPENAI_BASE_URL`／`ANTHROPIC_BASE_URL`，
  原本的 provider 設定不受影響。
- **金鑰租戶自己貼**：在 LiteLLM 後台（Virtual Keys）建虛擬金鑰（建議設預算、限定模型），貼到要用的工具自己的
  設定。平台不跨服務傳金鑰。實測：帶虛擬金鑰 `curl "$LITELLM_BASE_URL/models"` 回 200，不帶或錯誤金鑰回 401。
- **Claude Code**（已實測：LiteLLM chart 0.1.1／LiteLLM 1.103.3 的 Anthropic 相容 `/v1/messages`，含串流；
  Claude Code 2.1.284 在 OpenDesign daemon 容器內走叢集內網址、2.1.289 經 port-forward，`claude -p` 都跑完一輪）：在終端機
  ```sh
  ANTHROPIC_BASE_URL="${LITELLM_BASE_URL%/v1}" ANTHROPIC_AUTH_TOKEN=<虛擬金鑰> ANTHROPIC_API_KEY= \
  ANTHROPIC_MODEL=<LiteLLM 模型名> ANTHROPIC_DEFAULT_HAIKU_MODEL=<LiteLLM 模型名> claude
  ```
  `ANTHROPIC_BASE_URL` 要去掉 `/v1`（Claude Code 自己會接 `/v1/messages`）；模型名是 LiteLLM 裡的 model
  name，虛擬金鑰要允許該模型；`ANTHROPIC_API_KEY=` 清空，免得送出原本的 Anthropic 金鑰。
- **pi**（2026-11-05 正式站實測：pi 0.99.1 經 LiteLLM 回覆、用工具寫檔都通）：本 IDE 的 pi 設定目錄是
  **`$PI_CODING_AGENT_DIR`（`/data/pi-agent`，在 PVC 上）**，不是 pi 文件預設的 `~/.pi/agent`——檔案放錯地方，
  pi 會回 `Unknown provider "litellm"`。在終端機：
  ```sh
  # 已有 models.json 時，把 litellm 加進原本的 "providers"，不要整份覆蓋
  cat > "$PI_CODING_AGENT_DIR/models.json" <<EOF
  {"providers": {"litellm": {"baseUrl": "$LITELLM_BASE_URL", "api": "openai-completions",
    "apiKey": "\$LITELLM_API_KEY", "models": [{"id": "<LiteLLM 模型名>"}]}}}
  EOF
  LITELLM_API_KEY=<虛擬金鑰> pi --provider litellm --model <LiteLLM 模型名>
  ```
  `apiKey` 寫成 `$LITELLM_API_KEY`（pi 支援 `$NAME`／`${NAME}` 環境變數展開），金鑰就不會寫進檔案；`baseUrl`
  在建檔當下展開成叢集內網址。`pi --list-models litellm` 看得到模型就代表設定讀到了。
- 網路：靠既有的 `networkPolicy.sameNamespaceEgress`（預設 true）；它和 `allowAllEgress` 都關掉就連不到。
- 生效時機：網址放在不入 checksum 的 runtime ConfigMap `<fullname>-llm-gateway`（`envFrom`，optional），
  設定／變更／清空網址 pod template 都不變、不重啟 pod（平台密碼重設的 `helm upgrade --atomic --timeout 15s`
  不受影響）；env 在容器啟動時讀，執行中的容器要等下次重啟（重設密碼、重新部署）才看到新值。
- 不是 http(s) 的值會被略過（沒有 env），不會讓 render 失敗。
- 測試：`tests/test-llm-gateway.sh`（只改網址時所有 workload byte-identical、envFrom、壞值、NetworkPolicy）。

## 測試

- `tests/test-render-contract.sh`：既有契約（密碼、選填金鑰、網路、命名），加上密碼登入不可覆寫（唯讀
  `CODE_SERVER_CONFIG` 只有 `auth: password`、`--auth password`）、只有一個容器、不覆寫 command、
  資源＝整個方案、HOME 掛載與 cache 上限、claude.ai 連接器、gitconfig、build 平行數。
- `tests/test-pi-seed.sh`：**實際執行** render 出來的 pi-seed 腳本（sh、bash，設 `OG_TEST_BUSYBOX` 時加 busybox），
  對假的 image／volume 目錄檢查：設定合併、JSONC 保持原樣、不覆蓋、`~/.ssh` 0700、語言包以 image 為準、`set -eu`。
- `tests/test-login-i18n.sh`：`--i18n` 參數與唯讀投影、11 個登入字串（繁中、不提環境變數／設定檔、沒有 placeholder、
  沒有簡體字、密碼提示指向「管理員帳密」）、`loginI18n=false` 還原、NOTES／README 的祕密揭露。
- `tests/test-omnigent-host-kit.sh`：套件副本與 `shared/omnigent-host` 的 sha256 一致、in-container 契約
  （image 啟動模式）、serverUrl 不改 pod template、關閉時不留痕跡、這個 chart 的參數與 values 驗證。
- `tests/test-container-security-context.sh`：確認個別容器覆寫保留預設防護，且不影響 init、proxy 或 pod 的安全設定。
- 套件本身的行為測試：`shared/omnigent-host/tests/`。

## 0.1.12：code-server 個別容器安全設定

`codeServer.securityContext` 只覆寫 code-server 容器，會與共用的
`securityContext` 深度合併。預設空物件保留既有行為；未指定的
`allowPrivilegeEscalation: false`、`capabilities.drop: [ALL]` 繼續生效。
pi-seed、cookie proxy 與 pod 的安全設定不受此覆寫影響。

使用已驗證的 Localhost AppArmor／seccomp 設定時，把兩個 profile 放在
`codeServer.securityContext`，並以 `nodeSelector` 限定已安裝、載入相符
profile 的節點。chart 不會安裝主機 policy，也不會自動改用寬鬆設定；
映像中的 sandbox 相容修正仍需搭配該部署允許的核心與安全政策。
