# UsefulScripts

個人用小工具集：一個工具一個資料夾，各自獨立、可單獨取用。

| 工具 | 說明 |
|---|---|
| `zoom-record/` | headless Zoom 錄影：Mac 下一條指令，在遠端 Linux worker 上自動入會＋錄影＋散會自動停，mp4 取回本機 |
| `gh-runner/` | GitHub Actions Self-Hosted Runner 容器工具：專為 Private repo 提供隔離、憑證安全、一鍵啟動的 runner 環境（已停用，改由 MyLinuxPool ghrunner 取代） |

## 慣例

- 每個工具一個資料夾，裡面一定要有 `README.md`（用法＋需求＋注意事項）。
- 跑在別台機器上的東西，預設該機器是「全新狀態」也能跑（自己裝依賴）。
