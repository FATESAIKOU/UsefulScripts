# gh-runner

GitHub Actions Self-Hosted Runner 容器化工具，專為一人公司的 Private 儲存庫（`MyPMO`、`MyBrain`、`MyAiEntry`、`MyLinuxPool`）提供輕量、安全且隔離的背景執行環境。

---

## 1. 設計原則與核心用途

- **只登錄 Private Repo，絕不碰 Public Repo**：在每次啟動 runner 容器前，腳本會硬性透過 GitHub CLI 驗證目標儲存庫的 visibility 必須為 `true:private`。若為 public 或查詢失敗，立即中斷退出，堅決不讓 self-hosted runner 暴露於 public repo 的 Pull Request 執行風險中。（注意：`MyLinuxPool` 必須在 GitHub 上切換為 Private 後方可登錄）。
- **嚴格憑證隔離，長期 PAT 永不進容器，單次 Token 瞬間清空**：宿主機使用 Personal Access Token (PAT) 透過 `curl --config -` 向 GitHub API 換取單次 registration token，PAT 永不傳入容器，更不上 `docker run -e` 命令列參數；單次 registration token 掛載入容器後，在 `./config.sh` 註冊瞬間立即清空為 0 bytes，workflow job 絕無機會讀取到有效憑證。
- **宿主機與容器邊界保護**：
  - 嚴禁掛載 `/var/run/docker.sock`（防止 container breakout）。
  - 嚴禁 `--privileged`，預設啟用 `--cap-drop ALL` 與 `--security-opt no-new-privileges:true`。
  - 容器內以非 root 使用者 `runner` 執行工作，建置時透過 `--build-arg RUNNER_UID=$(id -u)` 自動對齊主機使用者 UID，並妥善處理 Ubuntu 24.04 既有 UID 衝突，確保掛載權限一致且安全。
  - 硬性保護特定路徑，阻擋任何包含 `LLMGateway` 關鍵字的路徑，防止誤觸機密。

---

## 2. GitHub PAT 申請與本機配置

Runner 需要一個具備儲存庫管理權限的 Fine-grained Personal Access Token (PAT) 以換取 runner 註冊 token。

### 申請方式
1. 前往 GitHub **Settings -> Developer settings -> Personal access tokens -> Fine-grained tokens**。
2. 建立新 Token：
   - **Token name**：`POOL_PROVIDER__GH_PRIVATE_RUNNER__ADMIN`
   - **Repository access**：**Only select repositories**，勾選：
     - `MyPMO`
     - `MyBrain`
     - `MyAiEntry`
     - `MyLinuxPool`
   - **Repository permissions**：
     - **Administration**：`Read and write`（僅用於註冊 self-hosted runner，其餘權限皆不給）
3. 儲存 Token 於宿主機指定路徑（預設：`~/.config/gh-runner/token`）：
   ```bash
   mkdir -p ~/.config/gh-runner
   echo "ghp_your_fine_grained_token_here" > ~/.config/gh-runner/token
   chmod 600 ~/.config/gh-runner/token
   ```
   > [!IMPORTANT]
   > `gh-runner.sh` 在執行時會強制檢查密碼檔權限。若群組或其他使用者具有任何存取權限（非 `0600` / `0400` 等），腳本將直接拒絕執行並提示 `chmod 600`，杜絕權限過寬導致的憑證洩漏。

---

## 3. 指令用法

所有指令皆在 runner provider 主機（如 `fh-l`、`fh-proxy`、`fh-proxy-asus`）上執行。

### 啟動 Runner 容器 (`up`)
```bash
# 預設為 MyPMO, MyBrain, MyAiEntry, MyLinuxPool 四個 repo 各自啟動一個容器 (count=1)
# （MyLinuxPool 需已切換為 Private 儲存庫）
./gh-runner.sh up

# 同主機同 repo 啟動多個 Runner 容器（例如啟動 3 個 MyLinuxPool 容器）
./gh-runner.sh up --count 3 MyLinuxPool
./gh-runner.sh up -n 2 MyPMO MyLinuxPool

# 設定資源上限（例如限制每個容器最多使用 2 CPUs 與 4GB 記憶體）
./gh-runner.sh up --count 2 --cpus 2 --memory 4g MyLinuxPool

# 啟動時強制重新建置 Docker 映像檔
./gh-runner.sh up --build

# 指定特定 repo 啟動（單一或多個，支援 positional 或 --repo 參數）
./gh-runner.sh up MyPMO
./gh-runner.sh up --repo MyLinuxPool
./gh-runner.sh up MyPMO MyBrain
```

### 停止並移除 Runner 容器 (`down`)
```bash
# 停止並移除所有預設 repo 的 runner 容器（包含所有編號實例與舊版無編號容器）
./gh-runner.sh down

# 停止並移除指定 repo 的 runner 容器
./gh-runner.sh down MyPMO
./gh-runner.sh down --repo MyLinuxPool
```

### 查看容器狀態 (`status`)
```bash
# 列出目前所有 gh-runner-* 容器狀態（包含所有編號實例與舊版無編號容器）
./gh-runner.sh status

# 查看指定儲存庫的 runner 容器狀態
./gh-runner.sh status --repo MyLinuxPool
```

### 建置 Docker 映像檔 (`build`)
```bash
./gh-runner.sh build
```

### 命名規範（Naming Convention）
- **容器名稱**：`gh-runner-<repo>-<i>`（例如 `gh-runner-MyLinuxPool-1`、`gh-runner-MyLinuxPool-2`）。
- **Runner 名稱**：`mlp-<host>-<repo>-<i>`（例如 `mlp-fh-l-MyLinuxPool-1`）。
- **工作目錄 Volume**：`gh-runner-work-<repo>-<i>`（例如 `gh-runner-work-MyLinuxPool-1`，每個容器擁有專屬獨立 Named Volume，徹底杜絕多個 runner 並行構建時的工作目錄衝突）。

### 平滑升級與舊 Runner 清理說明
- **本機容器自動清理**：執行 `./gh-runner.sh up` 或 `./gh-runner.sh down` 時，腳本會自動檢測並以 `docker rm -f` 移除舊版不帶編號的容器（`gh-runner-<repo>`）以及縮編時多餘的編號容器（例如從 3 台縮減為 2 台時自動清理第 3 台），無需人工手動介入。
- **GitHub 後台 Offline Runner**：舊版本註冊的 runner 名稱（`mlp-<host>-<repo>`）在容器停止後，GitHub 後台會顯示為 `Offline`。此為 GitHub Actions self-hosted runner 的正常生命週期行為，**不需要手動反註冊**，GitHub 官方後台會在 14 天後自動清理清除；若追求管理面板整潔，亦可隨時至 GitHub 儲存庫的 **Settings > Actions > Runners** 手動點選刪除。

### 環境變數客製化
- `GH_RUNNER_TOKEN_FILE`：指定 PAT 檔案路徑（預設 `~/.config/gh-runner/token`）。
- `GH_RUNNER_REPOS`：自訂預設 repo 清單（空白分隔，預設 `"MyPMO MyBrain MyAiEntry MyLinuxPool"`）。
- `GH_RUNNER_OWNER`：預設組織或擁有者（預設 `"FATESAIKOU"`）。
- `GH_RUNNER_COUNT`：每個 repo 啟動的 runner 容器數量（預設 `1`）。
- `GH_RUNNER_CPUS`：每個容器可使用的 CPU 上限（例如 `2`、`1.5`，預設無限制）。
- `GH_RUNNER_MEMORY`：每個容器可使用的記憶體上限（例如 `4g`、`512m`，預設無限制）。
- `GH_RUNNER_LABELS`：Runner 標籤（預設 `"fh-runner"`）。
- `GH_RUNNER_IMAGE`：映像檔名稱（預設 `"mlp-gh-runner:latest"`）。
- `GH_RUNNER_HOST`：主機名稱識別碼（預設為 `hostname -s`）。

---

## 4. Private Repo Workflow 設定與內建環境

在 Private 儲存庫的 GitHub Actions workflow 檔中，將 `runs-on` 指定為：

```yaml
jobs:
  build-and-test:
    runs-on: [self-hosted, fh-runner]
    steps:
      - uses: actions/checkout@v4
      - name: Run script
        run: |
          python3 --version
          node --version
          gh --version
```

### 預裝依賴對照表（Workflow Audit）

因容器以非特權帳號 `runner` 執行且 `--cap-drop ALL`，所有儲存庫 workflow 所需套件皆已預裝於映像檔中：

| 儲存庫 | Workflows / Actions 涵蓋清單 | 預裝依賴工具與作用 |
|---|---|---|
| **`MyPMO`** | `validate.yml`, `sync.yml` | `python3` (3.12), `python3-pip`, `python3-yaml`, `gh`, `git`, `bash`, `jq`, `curl` |
| **`MyBrain`** | `okf-check.yml` | `python3` (3.12), `python3-pip`, `PyYAML>=6`, `actions/setup-python@v6` toolcache |
| **`MyAiEntry`** | `ci.yml` | Node.js 24 (`node`, `npm`, `npx`), `actions/setup-node@v4` toolcache |
| **`MyLinuxPool`** | `ci.yml`, `create-worker.yml`, `delete-worker.yml`, `refresh-authorized-keys.yml`, `repair-gateway.yml`, `rotate-gateway.yml`, `.github/actions/pool-ssh`, `.github/actions/push-state`, `linode/action-linode-cli@v1` | `openssh-client` (`ssh`, `scp`, `ssh-agent`, `ssh-add`, `ssh-keygen`), `python3-pytest` (單元測試), `gettext-base` (`envsubst` 設定檔渲染), `fzf` (`mlp` CLI 必要依賴), `openssl` (金鑰與加密操作), `rsync` (客戶端同步測試), `linode-cli` (Linode 管理 CLI), `pyyaml`, `jsonschema`, `gh`, `git`, `jq`, `curl`, `bash` |

### 內建執行環境與 Tool Cache
容器映像檔預裝以下工具以完全相容各 repo 的 workflow：
- **系統基礎工具**：`git`, `jq`, `curl`, `ca-certificates`, `tar`, `gzip`, `unzip`, `gnupg`。
- **SSH 與維運套件**：`openssh-client` (`ssh`, `scp`, `ssh-agent`, `ssh-add`, `ssh-keygen`), `rsync`, `openssl`, `gettext-base` (`envsubst`), `fzf`。
- **Python 3.12 環境**：內建 `python3`, `pip`, `venv`, `python3-yaml`, `python3-pytest`，並以 pip 預裝 `pyyaml`, `jsonschema`, `linode-cli`。
- **Pip 非特權執行環境**：設定 `PIP_BREAK_SYSTEM_PACKAGES=1`、`PIP_USER=1` 及 `PATH="/home/runner/.local/bin:${PATH}"`，當 `linode/action-linode-cli@v1` 或其他 workflow step 於 runtime 執行 `pip install` 時，自動安裝至使用者目錄且可直接在 PATH 執行。
- **Node.js 24**：內建 `node`, `npm`, `npx`（滿足 `MyAiEntry`）。
- **GitHub CLI (`gh`)**：官方最新版本（滿足 issue/PR 操作）。
- **Actions Tool Cache**：已預先建立 `/opt/hostedtoolcache` 目錄架構及 `.complete` 標記。當 workflow 使用 `actions/setup-python@v6` (`python-version: '3.12'`) 或 `actions/setup-node@v4` (`node-version: 24`) 時，直接命中本機快取。
- **GitHub Actions Runner**：採用官方最新穩定版本 `2.338.0`。

---

## 5. 安全與隔離邊界說明

1. **Private 專屬**：公共儲存庫執行 self-hosted runner 會引發來自外部 fork PR 的惡意程式碼執行風險。因此本工具採取白名單原則，強制執行 API 檢查，非 private 絕不啟動。
2. **無 Docker Socket 掛載**：Runner 內部無法直接操作宿主機 Docker daemon，避免利用容器逃逸取得宿主機 root 權限。
3. **無 Root 權限與主機 UID 自動對齊**：Runner 以非特權帳號 `runner` 執行，透過 `--build-arg RUNNER_UID=$(id -u)` 動態對齊宿主機使用者 UID（自動相容主機 UID 1000/1002 並清除 Ubuntu 24.04 預設 uid 1000 衝突），並啟用 `--cap-drop ALL` 和 `--security-opt no-new-privileges:true`。
4. **長期 PAT 永不進容器，單次 Token 瞬間清空**：
   - 宿主機 `gh-runner.sh` 使用 PAT 透過 `curl --config -`（由 stdin 傳遞 Authorization header）向 GitHub API 換取單次 registration token，長期 PAT 絕不上 `docker run` 命令列、不進環境變數、不掛載入容器。
   - 單次 registration token 存入宿主機權限 `0600` 暫存檔，掛載至容器 `/run/secrets/gh_runner_reg_token`。
   - 容器內 `entrypoint.sh` 在執行 `./config.sh` 註冊瞬間立即將該 token 檔案清空為 0 bytes（`: > "$REG_TOKEN_FILE"`），任何 workflow job step 執行時均無法讀到任何有效憑證。
   - runner 登錄完成後以 `exec env -u REG_TOKEN -u REG_TOKEN_FILE -u PAT -u TOKEN_FILE ./run.sh` 啟動主程序，確保環境變數完全乾淨無任何 token 殘留。
5. **目錄防護**：嚴格禁止掛載宿主機 `$HOME` 或含有敏感金鑰的路徑（如 `LLMGateway`）。
6. **不可變執行環境（Immutable Runner）**：
   - 由於啟用 `--cap-drop ALL` 且以非 root 使用者 `runner` 運行，容器內部處於不可變狀態，workflow step 無法（也嚴禁）透過 `sudo apt-get` 動態安裝系統層級套件。
   - 若未來 workflow 需要新增 OS 系統套件或共用程式庫（.so），應修改 `Dockerfile` 並以 `./gh-runner.sh up --build` 重新打包發布映像檔。
