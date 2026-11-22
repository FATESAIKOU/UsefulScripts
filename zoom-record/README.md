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
| `TEST_SECS` | `0` | `>0` 時只錄 N 秒後離開（測試用）；`0`＝錄到散會 |
| `ADMIT_TIMEOUT_SEC` | `1200` | 等候室等待上限 |
| `MAX_REC_SEC` | `21600` | 錄影安全上限（6h） |
| `RES_W` / `RES_H` | `1920` / `1080` | 虛擬螢幕解析度（錄影裁掉上方 140px 瀏覽器框） |
| `SSH_OPTS` | 空 | 透傳給 ssh/scp 的參數，如 `"-F cfg -i key -J jump"`（值內勿含空白；需 key 登入） |
| `SSH_CFG` | `~/.mylinuxpool/ssh_config` | ssh 設定檔 |

## 需求

- Mac：`ssh`、`scp`（系統內建）。
- Worker：Ubuntu 24.04＋passwordless sudo（mlp default image 符合）；
  套件（xvfb、ffmpeg、pulseaudio、xdotool、tesseract、google-chrome）
  由 script 自己裝，不用預裝。
- 入會狀態用截圖＋OCR 判斷（等候室／入會中／已結束／無效連結）。
- 散會判定（錄影中）：Chrome 視窗消失 15 秒、OCR 連兩次（間隔 10 秒）看到散會文字
  **且**工具列已消失、音訊串流 120 秒歸零、ffmpeg 意外結束、或達 `MAX_REC_SEC`。
  不看視窗標題（個人會議室的標題是 `<名字>'s Personal Meeting Room`，見 #15）。
- 提早停止（ffmpeg 中途結束、音訊 120 秒歸零）算**失敗**：remote 印 `FATAL`、
  `do_record.sh` exit 1，讓外層可以重新入會；mp4 若還讀得到（ffprobe 有 duration）
  照樣取回 `<outputmp4>`。mp4 讀不到（ffmpeg 被殺、沒有 moov atom）一律算失敗。
- 入會後任何結束（含 `die`）都會停 ffmpeg、關 Chrome，bot 不會留在會議裡。
- pulseaudio 無回應或沒有 monitor source 時會自動清掉殘留後重啟（最多 3 輪「重啟→驗證」；
  會清 `/tmp/pulse-*`，前提是專用的錄影機），ffmpeg 啟動失敗會修好 pulse 再重試一次。
- ⚠️ `TEST_SECS` 模式**不走**散會判定迴圈；改到散會判定時，請用
  `MAX_REC_SEC=360` 的正式模式實測。
- 會議中的提示 toast（權限要求、AI 介紹、硬加速）由 Chrome 擴充功能
  按文字內容常駐隱藏（`toastext/`，worker 上動態產生、不進版控），
  座標點擊只當備援——toast 重繪、換位置都不怕。

## 同步規則

- 本資料夾的 `do_record.sh` 是正本；`~/testSH/do_record.sh` 是執行用副本。
- 改完這裡要 `cp zoom-record/do_record.sh ~/testSH/do_record.sh`，
  兩邊用 `diff -q` 確認一致再 commit。
