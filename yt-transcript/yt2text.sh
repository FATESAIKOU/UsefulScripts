#!/usr/bin/env bash
# yt2text.sh — YouTube URL -> transcript (txt with [mm:ss] / srt)
#
#   yt2text.sh <yturl> [options]
#
# Manual subtitles are used when they exist; otherwise the audio is downloaded
# and transcribed with Whisper (mlx-whisper on Apple Silicon, faster-whisper on
# CUDA, faster-whisper CPU otherwise). Chinese output is converted to Taiwan
# Traditional with OpenCC unless --no-trad.
#
# Everything (venv, models, temp audio) lives under $YT2TEXT_HOME (default
# /tmp/yt2text) and is reused next time; delete it (or pass --clean) to reset.
set -euo pipefail

usage() {
    cat <<'EOF'
usage: yt2text.sh <yturl> [options]

  -o, --out FILE        output file (default: ./<video-id>.<format>)
  -m, --model NAME      large-v3-turbo (default) | large-v3 | medium | small
  -l, --lang CODE       spoken language, e.g. zh / ja / en (default: auto-detect)
  -f, --format FMT      txt (default, "[mm:ss] text" per line) | srt
  -p, --prompt TEXT     initial prompt for Whisper (put names / jargon here)
      --no-trad         don't convert Chinese to Taiwan Traditional
      --force-asr       ignore existing subtitles, always run Whisper
      --keep-audio      keep the downloaded audio next to the output
      --remote HOST     run everything on [user@]HOST over ssh (key login only,
                        BatchMode) and copy the result back; SSH_OPTS is passed
                        to ssh/scp, e.g. SSH_OPTS="-F ~/.mylinuxpool/ssh_config"
      --clean           delete $YT2TEXT_HOME (venv + models) when done
  -h, --help

env: YT2TEXT_HOME (default /tmp/yt2text), SSH_OPTS
EOF
}

log() { printf '[yt2text %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

URL=""; OUT=""; MODEL="large-v3-turbo"; LANG_OPT=""; FMT="txt"; PROMPT=""
TRAD=1; FORCE_ASR=0; KEEP_AUDIO=0; REMOTE=""; CLEAN=0
FWD=()   # options forwarded verbatim to the remote run
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--out)     OUT="${2:?}"; shift 2 ;;
        -m|--model)   MODEL="${2:?}"; FWD+=("$1" "$2"); shift 2 ;;
        -l|--lang)    LANG_OPT="${2:?}"; FWD+=("$1" "$2"); shift 2 ;;
        -f|--format)  FMT="${2:?}"; FWD+=("$1" "$2"); shift 2 ;;
        -p|--prompt)  PROMPT="${2:?}"; FWD+=("$1" "$2"); shift 2 ;;
        --no-trad)    TRAD=0; FWD+=("$1"); shift ;;
        --force-asr)  FORCE_ASR=1; FWD+=("$1"); shift ;;
        --keep-audio) KEEP_AUDIO=1; FWD+=("$1"); shift ;;
        --remote)     REMOTE="${2:?}"; shift 2 ;;
        --clean)      CLEAN=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        -*)           usage >&2; die "unknown option: $1" ;;
        *)            [[ -z "$URL" ]] || die "only one URL please"; URL="$1"; shift ;;
    esac
done
[[ -n "$URL" ]] || { usage >&2; exit 2; }
case "$MODEL" in large-v3-turbo|large-v3|medium|small) ;; *) die "unknown model: $MODEL" ;; esac
case "$FMT" in txt|srt) ;; *) die "unknown format: $FMT" ;; esac

WORK="${YT2TEXT_HOME:-/tmp/yt2text}"

# ---------------------------------------------------------------- remote mode
if [[ -n "$REMOTE" ]]; then
    # shellcheck disable=SC2206
    SSH=(ssh ${SSH_OPTS:-} -o BatchMode=yes -o ConnectTimeout=15)
    # shellcheck disable=SC2206
    SCP=(scp ${SSH_OPTS:-} -o BatchMode=yes -o ConnectTimeout=15)
    HOST="$REMOTE"
    RWORK="/tmp/yt2text"
    RJOB="$RWORK/job-$$-$RANDOM"
    log "remote: $HOST (work dir $RWORK)"
    "${SSH[@]}" "$HOST" "mkdir -p $RJOB && cat > $RWORK/yt2text.sh && chmod +x $RWORK/yt2text.sh" < "$0" \
        || die "cannot reach $HOST with key login (BatchMode)"
    RARGS="$(printf '%q ' "$URL" ${FWD[@]+"${FWD[@]}"} -o "$RJOB/result.$FMT")"
    "${SSH[@]}" "$HOST" "YT2TEXT_HOME=$RWORK bash $RWORK/yt2text.sh $RARGS" \
        || { "${SSH[@]}" "$HOST" "rm -rf $RJOB" || true; die "remote run failed"; }
    if [[ -z "$OUT" ]]; then
        VID="$("${SSH[@]}" "$HOST" "cat $RJOB/video_id 2>/dev/null" || true)"
        OUT="./${VID:-transcript}.$FMT"
    fi
    "${SCP[@]}" "$HOST:$RJOB/result.$FMT" "$OUT" || die "copy back failed"
    if [[ "$KEEP_AUDIO" -eq 1 ]]; then
        "${SCP[@]}" "$HOST:$RJOB/result.audio.*" "$(dirname "$OUT")/" 2>/dev/null || log "no audio to copy back"
    fi
    if [[ "$CLEAN" -eq 1 ]]; then "${SSH[@]}" "$HOST" "rm -rf $RWORK"; else "${SSH[@]}" "$HOST" "rm -rf $RJOB"; fi
    log "done: $OUT"
    exit 0
fi

# ---------------------------------------------------------------- environment
OS="$(uname -s)"; ARCH="$(uname -m)"
ENGINE="faster-whisper-cpu"
if [[ "$OS" == "Darwin" && "$ARCH" == "arm64" ]]; then
    ENGINE="mlx"
elif command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    ENGINE="faster-whisper-cuda"
fi
VENV="$WORK/venv-$OS-$ARCH-$ENGINE"
PKGS=("yt-dlp[default]" imageio-ffmpeg opencc numpy)
case "$ENGINE" in
    mlx)                 PKGS+=(mlx-whisper) ;;
    faster-whisper-cuda) PKGS+=(faster-whisper nvidia-cublas-cu12 "nvidia-cudnn-cu12==9.*") ;;
    *)                   PKGS+=(faster-whisper) ;;
esac
mkdir -p "$WORK"

# uv builds the venv (and fetches its own Python if needed), so the host needs
# neither python3-venv nor sudo; a private uv is downloaded when none is found
export UV_CACHE_DIR="$WORK/uv-cache" UV_PYTHON_INSTALL_DIR="$WORK/python"
UV="$(command -v uv || true)"
if [[ -z "$UV" ]]; then
    UV="$WORK/bin/uv"
    if [[ ! -x "$UV" ]]; then
        case "$OS-$ARCH" in
            Linux-x86_64)   TRIPLE=x86_64-unknown-linux-gnu ;;
            Linux-aarch64)  TRIPLE=aarch64-unknown-linux-gnu ;;
            Darwin-arm64)   TRIPLE=aarch64-apple-darwin ;;
            Darwin-x86_64)  TRIPLE=x86_64-apple-darwin ;;
            *) die "no uv build for $OS-$ARCH" ;;
        esac
        log "downloading uv ($TRIPLE) ..."
        mkdir -p "$WORK/bin"
        curl -fsSL "https://github.com/astral-sh/uv/releases/latest/download/uv-$TRIPLE.tar.gz" \
            | tar -xz -C "$WORK/bin" --strip-components 1 "uv-$TRIPLE/uv" || die "uv download failed"
    fi
fi

STAMP="$VENV/.yt2text-ok"
if [[ ! -f "$STAMP" ]]; then
    log "setting up $VENV ($ENGINE; first run only, a few minutes) ..."
    rm -rf "$VENV"
    "$UV" venv -q --python 3.12 "$VENV"
    "$UV" pip install -q --python "$VENV/bin/python" "${PKGS[@]}"
    touch "$STAMP"
else
    # yt-dlp must stay current or YouTube breaks it; cheap when already latest
    "$UV" pip install -q --python "$VENV/bin/python" --upgrade "yt-dlp[default]" >/dev/null 2>&1 \
        || log "warning: yt-dlp upgrade failed, using installed version"
fi

if [[ "$ENGINE" == "faster-whisper-cuda" ]]; then
    # ctranslate2 needs cuBLAS / cuDNN from the pip wheels
    NV_LIBS="$("$VENV/bin/python" -c 'import nvidia.cublas.lib as a, nvidia.cudnn.lib as b; print(list(a.__path__)[0] + ":" + list(b.__path__)[0])')"
    export LD_LIBRARY_PATH="$NV_LIBS${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

# an expired HF token in the environment makes public model downloads 401
unset HF_TOKEN HUGGING_FACE_HUB_TOKEN
export HF_HUB_DISABLE_IMPLICIT_TOKEN=1
export HF_HOME="$WORK/hf"
export HF_HUB_DISABLE_PROGRESS_BARS=1

JOB="$(mktemp -d "$WORK/job.XXXXXX")"
cleanup() { rm -rf "$JOB"; if [[ "$CLEAN" -eq 1 ]]; then rm -rf "$WORK"; fi; }
trap cleanup EXIT

cat > "$JOB/yt2text.py" <<'PYEOF'
import json, os, re, shutil, subprocess, sys

a = json.loads(sys.argv[1])
job, engine = a["job"], a["engine"]

def log(msg):
    print(f"[yt2text] {msg}", file=sys.stderr, flush=True)

def ytdlp_base():
    cmd = [os.path.join(os.path.dirname(sys.executable), "yt-dlp"), "--no-playlist", "--no-warnings"]
    if not shutil.which("deno") and shutil.which("node"):
        cmd += ["--js-runtimes", "node"]
    return cmd

def ffmpeg_bin():
    f = shutil.which("ffmpeg")
    if f:
        return f
    import imageio_ffmpeg
    return imageio_ffmpeg.get_ffmpeg_exe()

# ---- metadata
log("reading video info ...")
info = json.loads(subprocess.run(ytdlp_base() + ["-J", a["url"]], check=True,
                                 capture_output=True, text=True).stdout)
vid, title = info.get("id", "video"), info.get("title", "")
open(os.path.join(job, "video_id"), "w").write(vid)
log(f"{title} [{vid}] {int(info.get('duration') or 0)//60} min")

def pick_sub_lang():
    subs = {k: v for k, v in (info.get("subtitles") or {}).items() if k != "live_chat"}
    if not subs or a["force_asr"]:
        return None
    want = a["lang"] or info.get("language") or ""
    if want:
        for k in subs:
            if k == want or k.split("-")[0] == want.split("-")[0]:
                return k
        return None
    return next(iter(subs)) if len(subs) == 1 else None

def parse_vtt(path):
    segs, cur = [], None
    ts = re.compile(r"(\d+:)?(\d+):(\d+)[.,](\d+)\s+-->\s+(\d+:)?(\d+):(\d+)[.,](\d+)")
    def sec(h, m, s, ms):
        return int((h or "0:")[:-1]) * 3600 + int(m) * 60 + int(s) + int(ms) / 1000
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n")
        m = ts.search(line)
        if m:
            cur = [sec(*m.group(1, 2, 3, 4)), sec(*m.group(5, 6, 7, 8)), []]
            segs.append(cur)
        elif cur is not None and line.strip():
            cur[2].append(re.sub(r"<[^>]+>", "", line).strip())
        elif not line.strip():
            cur = None
    out = []
    for s, e, t in segs:
        text = " ".join(x for x in t if x)
        if text and not (out and out[-1][2] == text):
            out.append((s, e, text))
    return out

segments, lang, source = None, a["lang"], "whisper"
sub_lang = pick_sub_lang()
if sub_lang:
    log(f"using manual subtitles ({sub_lang}), no ASR needed")
    subprocess.run(ytdlp_base() + ["--skip-download", "--write-subs", "--sub-langs", sub_lang,
                                   "--sub-format", "vtt", "--convert-subs", "vtt",
                                   "--ffmpeg-location", ffmpeg_bin(),
                                   "-o", os.path.join(job, "sub.%(ext)s"), a["url"]],
                   check=True, stdout=subprocess.DEVNULL)
    vtts = [f for f in os.listdir(job) if f.endswith(".vtt")]
    if vtts:
        segments, lang, source = parse_vtt(os.path.join(job, vtts[0])), sub_lang, "subtitles"
    else:
        log("subtitle download produced nothing, falling back to ASR")

if segments is None:
    log("downloading audio ...")
    subprocess.run(ytdlp_base() + ["-f", "ba/b", "-o", os.path.join(job, "audio.%(ext)s"), a["url"]],
                   check=True, stdout=subprocess.DEVNULL)
    audio = next(os.path.join(job, f) for f in os.listdir(job) if f.startswith("audio."))
    # decode with ffmpeg ourselves: faster-whisper's PyAV path breaks on some versions
    pcm = os.path.join(job, "audio.f32")
    subprocess.run([ffmpeg_bin(), "-nostdin", "-loglevel", "error", "-y", "-i", audio,
                    "-ac", "1", "-ar", "16000", "-f", "f32le", pcm], check=True)
    import numpy as np
    samples = np.fromfile(pcm, dtype=np.float32)
    log(f"transcribing {len(samples)/16000/60:.1f} min with {a['model']} on {engine} ...")
    kw = {"language": a["lang"] or None, "initial_prompt": a["prompt"] or None}
    if engine == "mlx":
        import mlx_whisper
        repo = {"large-v3-turbo": "mlx-community/whisper-large-v3-turbo",
                "large-v3": "mlx-community/whisper-large-v3-mlx",
                "medium": "mlx-community/whisper-medium-mlx",
                "small": "mlx-community/whisper-small-mlx"}[a["model"]]
        r = mlx_whisper.transcribe(samples, path_or_hf_repo=repo, **kw)
        segments = [(s["start"], s["end"], s["text"].strip()) for s in r["segments"]]
        lang = r.get("language") or lang
    else:
        from faster_whisper import WhisperModel
        cuda = engine == "faster-whisper-cuda"
        model = WhisperModel(a["model"], device="cuda" if cuda else "cpu",
                             compute_type="float16" if cuda else "int8")
        it, fi = model.transcribe(samples, vad_filter=True, **kw)
        segments = []
        for s in it:
            segments.append((s.start, s.end, s.text.strip()))
            if len(segments) % 50 == 0:
                log(f"  ... {s.end/60:.1f} min")
        lang = fi.language or lang
    if a["keep_audio"]:
        ext = os.path.splitext(audio)[1]
        shutil.copy(audio, os.path.splitext(a["out"])[0] + ".audio" + ext)

segments = [s for s in segments if s[2]]
if a["trad"] and (lang or "").lower().startswith("zh"):
    import opencc
    cc = opencc.OpenCC("s2tw")
    segments = [(s, e, cc.convert(t)) for s, e, t in segments]
    log("converted to Taiwan Traditional (OpenCC s2tw)")

def stamp(t):
    t = int(t)
    return f"{t//3600}:{t%3600//60:02d}:{t%60:02d}" if t >= 3600 else f"{t//60:02d}:{t%60:02d}"

def srt_time(t):
    ms = int(round(t * 1000))
    return f"{ms//3600000:02d}:{ms%3600000//60000:02d}:{ms%60000//1000:02d},{ms%1000:03d}"

with open(a["out"], "w", encoding="utf-8") as f:
    if a["format"] == "srt":
        for i, (s, e, t) in enumerate(segments, 1):
            f.write(f"{i}\n{srt_time(s)} --> {srt_time(e)}\n{t}\n\n")
    else:
        for s, _, t in segments:
            f.write(f"[{stamp(s)}] {t}\n")
log(f"{len(segments)} segments from {source} (lang={lang or '?'}) -> {a['out']}")
PYEOF

# output path: default ./<video-id>.<fmt>, resolved after we know the id
TMP_OUT="$JOB/result.$FMT"
ARGS_JSON="$("$VENV/bin/python" -c 'import json,sys; print(json.dumps(dict(zip(sys.argv[1::2], sys.argv[2::2]))))' \
    url "$URL" job "$JOB" engine "$ENGINE" model "$MODEL" lang "$LANG_OPT" format "$FMT" \
    prompt "$PROMPT" out "$TMP_OUT")"
ARGS_JSON="$("$VENV/bin/python" -c 'import json,sys; d=json.loads(sys.argv[1]); d.update(trad=sys.argv[2]=="1", force_asr=sys.argv[3]=="1", keep_audio=sys.argv[4]=="1"); print(json.dumps(d))' \
    "$ARGS_JSON" "$TRAD" "$FORCE_ASR" "$KEEP_AUDIO")"

"$VENV/bin/python" -I "$JOB/yt2text.py" "$ARGS_JSON"

[[ -n "$OUT" ]] || OUT="./$(cat "$JOB/video_id").$FMT"
mkdir -p "$(dirname "$OUT")"
cp "$TMP_OUT" "$OUT"
for f in "$JOB"/result.audio.*; do
    if [[ -e "$f" ]]; then cp "$f" "${OUT%.*}.audio.${f##*.}"; fi
done
# the remote caller fetches result.* + video_id from its own job dir
if [[ "$(dirname "$OUT")" != "$JOB" && "$OUT" == */result.$FMT ]]; then
    cp "$JOB/video_id" "$(dirname "$OUT")/video_id"
fi
log "done: $OUT"
