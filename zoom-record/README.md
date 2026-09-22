# zoom-record

Mac 下一條指令，在遠端 Linux worker（mlp default image 即可，全新機器也行）
上自動開 Chrome（Xvfb 虛擬螢幕）加入 Zoom 會議並錄影；主持人散會（或被移除）
時自動停止，mp4 取回本機。

## 用法

```bash
~/testSH/do_record.sh <host> <zoomid> <zoompw> <outputmp4>
# e.g.
~/testSH/do_record.sh worker-2302 75725811260 1PZ3sF /tmp/meet.mp4
```

- `<host>`：`mlp ssh-config --write` 後能直接 `ssh` 的名字。
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
| `SSH_CFG` | `~/.mylinuxpool/ssh_config` | ssh 設定檔 |

## 需求

- Mac：`ssh`、`scp`（系統內建）。
- Worker：Ubuntu 24.04＋passwordless sudo（mlp default image 符合）；
  套件（xvfb、ffmpeg、pulseaudio、xdotool、tesseract、google-chrome）
  由 script 自己裝，不用預裝。
- 入會狀態用截圖＋OCR 判斷（等候室／入會中／已結束／無效連結）。

## 同步規則

- 本資料夾的 `do_record.sh` 是正本；`~/testSH/do_record.sh` 是執行用副本。
- 改完這裡要 `cp zoom-record/do_record.sh ~/testSH/do_record.sh`，
  兩邊用 `diff -q` 確認一致再 commit。
