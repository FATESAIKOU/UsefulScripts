# yt-transcript

一條指令把 YouTube 影片轉成逐字稿。影片有人工字幕就直接用；沒有字幕（或只有自動字幕）就下載音訊，用 Whisper 辨識。
中文預設轉成台灣繁體。

## 用法

```bash
yt-transcript/yt2text.sh <yturl> [options]

yt2text.sh https://youtu.be/xxxx                         # 本機跑，輸出 ./<video-id>.txt
yt2text.sh https://youtu.be/xxxx -o talk.srt -f srt      # 輸出 srt
yt2text.sh https://youtu.be/xxxx -l zh -p "DeepSeek、字節、騰訊、混元"   # 指定語言＋術語表
SSH_OPTS="-F ~/.mylinuxpool/ssh_config" \
  yt2text.sh https://youtu.be/xxxx --remote fh-l          # 丟到 fh-l（RTX 2070 SUPER）跑完再取回
```

| 選項 | 預設 | 說明 |
|---|---|---|
| `-o, --out FILE` | `./<video-id>.<format>` | 輸出檔 |
| `-m, --model` | `large-v3-turbo` | `large-v3-turbo`／`large-v3`／`medium`／`small` |
| `-l, --lang` | 自動偵測 | 說話的語言，例如 `zh`、`ja`、`en`；也用來挑字幕 |
| `-f, --format` | `txt` | `txt`（每句一行，前面加 `[mm:ss]`，超過一小時用 `[h:mm:ss]`）或 `srt` |
| `-p, --prompt` | 空 | 給 Whisper 的提示，把人名、專有名詞放進去，可以減少錯字 |
| `--no-trad` | 轉繁體 | 中文不做簡轉繁 |
| `--force-asr` | 關 | 有人工字幕也照樣跑 Whisper |
| `--keep-audio` | 關 | 把下載的音訊留在輸出檔旁邊（`<名稱>.audio.<ext>`） |
| `--remote HOST` | 本機 | `[user@]host`，必須是免密碼的 key 登入（用 BatchMode，不會停下來問密碼）；`SSH_OPTS` 會一起傳給 ssh／scp |
| `--clean` | 保留 | 跑完把 `$YT2TEXT_HOME` 整個刪掉 |

環境變數：`YT2TEXT_HOME`（預設 `/tmp/yt2text`）、`SSH_OPTS`。

## 怎麼運作

- 環境由 script 自己建，全部放在 `/tmp/yt2text/`：
  - `venv-<OS>-<arch>-<引擎>/`：yt-dlp、Whisper、OpenCC 等套件。
  - `hf/`：模型快取。
  - `job.*`：每次執行的暫存檔，跑完就刪。
- 第一次要裝套件、下載模型（large-v3-turbo 約 1.6GB），需要幾分鐘；之後直接沿用，只會順手把 yt-dlp 升到最新版。
- 不動系統環境。要重來就刪 `/tmp/yt2text`，或加 `--clean`。Mac 重開機時 `/tmp` 也會被清掉。
- 辨識引擎自動選：
  - Mac（Apple Silicon）：mlx-whisper，用 Apple GPU。
  - 有 NVIDIA GPU 的 Linux：faster-whisper（cuda、float16）；cuBLAS／cuDNN 從 pip 裝，不用另外裝 CUDA。
  - 其他：faster-whisper（CPU、int8），會很慢，建議改用 `--remote` 丟到有 GPU 的機器。
- 字幕：影片有人工字幕、而且語言對得上（`--lang`、影片標示的語言，或只有一種字幕）就直接用；自動字幕不採用（沒有標點、品質不穩）。
- 簡轉繁用 OpenCC `s2tw`：只換字形，不換詞彙。`s2twp` 會把「字節」轉成「位元組」，改到公司名，所以不用。
- `--remote`：把 script 本身傳到遠端的 `/tmp/yt2text/`，在遠端跑完（下載也在遠端做），再用 scp 取回結果。
  - 遠端需要 `python3`（含 venv）和 `node` 或 `deno`；沒有 ffmpeg 時會改用 pip 裝的 `imageio-ffmpeg`，不需要 sudo。

## 處理過的坑

AiMarketAna 第一次手動轉錄時踩到的坑，這支都先處理掉了：

- 環境裡有過期的 `HF_TOKEN`，下載模型會 401：執行時一律清掉 token，改匿名下載。
- faster-whisper 直接讀 webm 時 PyAV 版本不相容（`metadata_errors`）：先用 ffmpeg 轉成 16kHz 單聲道的 f32le，再把 numpy 陣列交給辨識。
- 沒有 deno 時 yt-dlp 會出警告：自動加 `--js-runtimes node`。
- small 模型的專有名詞錯字很多：預設改用 large-v3-turbo，並提供 `--prompt` 放術語表。

## 需求

- Mac：`python3`（3.10 以上）、`node`；網路。
- Linux：`python3` 加 `python3-venv`、`node`；有 NVIDIA 驅動就會走 GPU。
