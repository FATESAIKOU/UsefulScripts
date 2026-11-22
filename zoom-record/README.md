# zoom-record

一條指令，在遠端 Ubuntu 機器（全新安裝也行）上自動開 Chrome（Xvfb 虛擬螢幕）
加入 Zoom 會議並錄影；主持人散會（或被移除）時自動停止，mp4 取回本機。
走純 SSH，不綁任何叢集架構；在哪跑、對哪跑都行（Mac、Gateway、fh-l…）。

## 用法

```bash
do_record.sh <target> <zoomid> <zoompw> <outputmp4>
# <target> : [user@]host[:port]（~/.ssh/config 的名字也行）
# e.g.
do_record.sh worker-2302 75725811260 1PZ3sF /tmp/meet.mp4
SSH_OPTS="-F ~/.mylinuxpool/ssh_config" do_record.sh worker-2302 ...   # mlp
do_record.sh worker@127.0.0.1:2302 ...                                 # 從 Gateway 直連
SSH_OPTS="-i ~/.ssh/key" do_record.sh ubuntu@1.2.3.4 ...               # 任意雲主機
```

- 遠端需求：Ubuntu 24.04＋key 登入＋passwordless sudo（mlp default image 符合）。
- bot 以匿名顯示名稱入會（預設 `rec-<host>`，`REC_NAME` 可改），
  不開相機（黑畫面）不開麥，低調旁錄。等候室需主持人放行。
  「Please enable access…」提示條會自動關掉（入會後＋每分鐘巡檢）。
- 錄影只含會議頁面（裁掉瀏覽器框），1920x940 H264 + AAC。

## 環境變數

| 變數 | 預設 | 說明 |
|---|---|---|
| `REC_NAME` | `rec-<host>` | 會議中顯示名稱 |
| `TEST_SECS` | `0` | `>0` 時最多錄 N 秒（走跟正式錄影**同一個**停止迴圈，只是上限較短）；`0`＝錄到散會 |
| `ALONE_SEC` | `300` | 曾經有別人在場之後，只剩 bot 自己持續這麼久就停 |
| `GONE_HITS` | `3` | 連續幾次（每 5 秒一次）讀不到會議畫面就停 |
| `ADMIT_TIMEOUT_SEC` | `1200` | 等候室等待上限 |
| `MAX_REC_SEC` | `21600` | 錄影安全上限（6h） |
| `RES_W` / `RES_H` | `1920` / `1080` | 虛擬螢幕解析度（錄影裁掉上方 140px 瀏覽器框） |
| `SSH_OPTS` | 空 | 透傳給 ssh/scp 的參數，如 `"-F cfg -i key -J jump"`（值內勿含空白；需 key 登入） |
| `SSH_CFG` | `~/.mylinuxpool/ssh_config` | ssh 設定檔 |

## 需求

- Mac：`ssh`、`scp`（系統內建）。
- Worker：Ubuntu 24.04＋passwordless sudo（mlp default image 符合）；
  套件（xvfb、ffmpeg、pulseaudio、xdotool、tesseract、python3-websocket、google-chrome）
  由 script 自己裝，不用預裝。
- 入會狀態用截圖＋OCR 判斷（等候室／入會中／已結束／無效連結）。
- 散會判定（錄影中）直接讀網頁（Chrome DevTools 協定，port 9222 只開在 worker 本機），
  每 5 秒讀一次 footer 的 Leave 按鈕和參加人數，交給 `decide_stop`（純函式）決定：
  - **正常結束（exit 0）**：只剩 bot 自己持續 `ALONE_SEC`（要先看過別人在場，
    所以提早入會等人不會被停）、會議畫面連續 `GONE_HITS` 次不見（主持人散會／被移出／離開）、
    瀏覽器視窗消失 15 秒、達到 `MAX_REC_SEC`（或 `TEST_SECS`）。
  - **提早停止（FATAL、exit 1）**：ffmpeg 中途結束、音訊 120 秒歸零。
  - CDP 連續 3 次讀不到時，退回 OCR 判斷（散會文字＋工具列消失，10 秒後再確認）。
- 提早停止（ffmpeg 中途結束、音訊 120 秒歸零）算**失敗**：remote 印 `FATAL`、
  `do_record.sh` exit 1，讓外層可以重新入會；mp4 若還讀得到（ffprobe 有 duration）
  照樣取回 `<outputmp4>`。mp4 讀不到（ffmpeg 被殺、沒有 moov atom）一律算失敗。
- 入會後任何結束（含 `die`）都會停 ffmpeg、關 Chrome，bot 不會留在會議裡。
- 不用 `pkill`／`killall`（mlp image 會把它們換成一律失敗的 shim，見 MyLinuxPool#431）：
  一律用 `pgrep -f` 精確比對（例如 Chrome 只認 `--user-data-dir=/tmp/mlprec/chrome-prof`）再 `kill`。
  舊版因此留下過殘留的 Chrome，佔住 CDP port，也在會議裡留下殘留的連線。
- 停止策略的單元測試：`bash zoom-record/test_decide_stop.sh`（不需要網路或 worker）。
- pulseaudio 無回應或沒有 monitor source 時會自動清掉殘留後重啟（最多 3 輪「重啟→驗證」；
  會清 `/tmp/pulse-*`，前提是專用的錄影機），ffmpeg 啟動失敗會修好 pulse 再重試一次。
- 會議中的提示 toast（權限要求、AI 介紹、硬加速）每分鐘經 CDP 按文字內容隱藏、
  按掉「Got it」；離開會議也是經 DOM 按 Leave。CDP 不通時才退回座標點擊。
  （原本的 `--load-extension` 擴充功能在 Chrome 137+ 已失效，已移除。）

## 同步規則

- 本資料夾的 `do_record.sh` 是正本；`~/testSH/do_record.sh` 是執行用副本。
- 改完這裡要 `cp zoom-record/do_record.sh ~/testSH/do_record.sh`，
  兩邊用 `diff -q` 確認一致再 commit。
