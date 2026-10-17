# gh-runner

GitHub Actions Self-Hosted Runner 容器化工具，專為一人公司的 Private 儲存庫（`MyPMO`、`MyBrain`、`MyAiEntry`）提供輕量、安全且隔離的背景執行環境。

---

## 1. 設計原則與核心用途

- **只登錄 Private Repo，絕不碰 Public Repo**：在每次啟動 runner 容器前，腳本會硬性透過 GitHub CLI 驗證目標儲存庫的 visibility 必須為 `true:private`。若為 public 或查詢失敗，立即中斷退出，堅決不讓 self-hosted runner 暴露於 public repo 的 Pull Request 執行風險中。
- **嚴格憑證隔離，長期 PAT 永不進容器，單次 Token 瞬間清空**：宿主機使用 Personal Access Token (PAT) 透過 `curl --config -` 向 GitHub API 換取單次 registration token，PAT 永不傳入容器，更不上 `docker run -e` 命令列參數；單次 registration token 掛載入容器後，在 `./config.sh` 註冊瞬間立即清空為 0 bytes，workflow job 絕無機會讀取到有效憑證。
- **宿主機與容器邊界保護**：
  - 嚴禁掛載 `/var/run/docker.sock`（防止 container breakout）。
  - 嚴禁 `--privileged`，預設啟用 `--cap-drop ALL` 與 `--security-opt no-new-privileges:true`。
  - 容器內以非 root 使用者 `runner`（UID 1001）執行工作。
  - 硬性保護特定路徑，阻擋任何包含 `LLMGateway` 關鍵字的路徑，防止誤觸機密。

---

## 2. GitHub PAT 申請與本機配置

Runner 需要一個具備儲存庫管理權限的 Fine-grained Personal Access Token (PAT) 以換取 runner 註冊 token。

### 申請方式
1. 前往 GitHub **Settings -> Developer settings -> Personal access tokens -> Fine-grained tokens**。
2. 建立新 Token：
   - **Token name**：`POOL_PROVIDER__GH_PRIVATE_RUNNER__ADMIN`
   - **Repository access**：**Only select repositories**，只勾選：
     - `MyPMO`
     - `MyBrain`
     - `MyAiEntry`
   - **Repository permissions**：
     - **Administration**：`Read and write`（僅用於註冊 self-hosted runner，其餘權限皆不給）
3. 儲存 Token 於宿主機指定路徑（預設：`~/.config/gh-runner/token`）：
   ```bash
   mkdir -p ~/.config/gh-runner
   echo "ghp_your_fine_grained_token_here" > ~/.config/gh-runner/token
   chmod 600 ~/.config/gh-runner/token
   ```

---

## 3. 指令用法

所有指令皆在 runner provider 主機（如 `fh-l`、`fh-proxy`、`fh-proxy-asus`）上執行。

### 啟動 Runner 容器 (`up`)
```bash
# 預設為 MyPMO, MyBrain, MyAiEntry 三個 repo 各自啟動一個容器
./gh-runner.sh up

# 啟動時強制重新建置 Docker 映像檔
./gh-runner.sh up --build

# 指定特定 repo 啟動（單一或多個）
./gh-runner.sh up MyPMO
./gh-runner.sh up MyPMO MyBrain
```

### 停止並移除 Runner 容器 (`down`)
```bash
# 停止並移除所有預設 repo 的 runner 容器
./gh-runner.sh down

# 停止並移除指定 repo 的 runner 容器
./gh-runner.sh down MyPMO
```

### 查看容器狀態 (`status`)
```bash
./gh-runner.sh status
```

### 建置 Docker 映像檔 (`build`)
```bash
./gh-runner.sh build
```

### 環境變數客製化
- `GH_RUNNER_TOKEN_FILE`：指定 PAT 檔案路徑（預設 `~/.config/gh-runner/token`）。
- `GH_RUNNER_REPOS`：自訂預設 repo 清單（空白分隔，預設 `"MyPMO MyBrain MyAiEntry"`）。
- `GH_RUNNER_OWNER`：預設組織或擁有者（預設 `"FATESAIKOU"`）。
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

### 內建執行環境與 Tool Cache
容器映像檔預裝以下工具以完全相容各 repo 的 workflow：
- **Python 3.12**：內建 `python3`, `pip`, `venv`，並已安裝 `PyYAML>=6`（滿足 `MyPMO`、`MyBrain`）。
- **Node.js 24**：內建 `node`, `npm`, `npx`（滿足 `MyAiEntry`）。
- **GitHub CLI (`gh`)**：官方最新版本（滿足 `MyPMO` issue/PR 操作）。
- **Actions Tool Cache**：已預先建立 `/opt/hostedtoolcache` 目錄架構及 `.complete` 標記。當 workflow 使用 `actions/setup-python@v6` (`python-version: '3.12'`) 或 `actions/setup-node@v4` (`node-version: 24`) 時，會直接命中本機快取，省去每次下載時間。
- **基礎系統工具**：`git`, `jq`, `curl`, `ca-certificates`, `tar`, `gzip`, `unzip`。

---

## 5. 安全與隔離邊界說明

1. **Private 專屬**：公共儲存庫執行 self-hosted runner 會引發來自外部 fork PR 的惡意程式碼執行風險。因此本工具採取白名單原則，強制執行 API 檢查，非 private 絕不啟動。
2. **無 Docker Socket 掛載**：Runner 內部無法直接操作宿主機 Docker daemon，避免利用容器逃逸取得宿主機 root 權限。
3. **無 Root 權限**：Runner 以非特權帳號 `runner`（UID 1001）執行，且啟用 `--cap-drop ALL` 和 `--security-opt no-new-privileges:true`。
4. **長期 PAT 永不進容器，單次 Token 瞬間清空**：
   - 宿主機 `gh-runner.sh` 使用 PAT 透過 `curl --config -`（由 stdin 傳遞 Authorization header）向 GitHub API 換取單次 registration token，長期 PAT 絕不上 `docker run` 命令列、不進環境變數、不掛載入容器。
   - 單次 registration token 存入宿主機權限 `0600` 暫存檔，掛載至容器 `/run/secrets/gh_runner_reg_token`。
   - 容器內 `entrypoint.sh` 在執行 `./config.sh` 註冊瞬間立即將該 token 檔案清空為 0 bytes（`: > "$REG_TOKEN_FILE"`），任何 workflow job step 執行時均無法讀到任何有效憑證。
   - runner 登錄完成後以 `exec env -u REG_TOKEN -u REG_TOKEN_FILE -u PAT -u TOKEN_FILE ./run.sh` 啟動主程序，確保環境變數完全乾淨無任何 token 殘留。
5. **目錄防護**：嚴格禁止掛載宿主機 `$HOME` 或含有敏感金鑰的路徑（如 `LLMGateway`）。
6. **不可變執行環境（Immutable Runner）**：
   - 由於啟用 `--cap-drop ALL` 且以非 root 使用者 `runner` 運行，容器內部處於不可變狀態，workflow step 無法（也嚴禁）透過 `sudo apt-get` 動態安裝系統層級套件。
   - 若未來 workflow 需要新增 OS 系統套件或共用程式庫（.so），應修改 `Dockerfile` 並以 `./gh-runner.sh up --build` 重新打包發布映像檔。
