#!/usr/bin/env bash
# do_record.sh — controller: provision a (possibly fresh) Ubuntu 24.04 box
# over plain SSH, join a Zoom meeting headlessly (Chrome web client under
# Xvfb), record screen+audio with ffmpeg until the meeting ends, fetch mp4.
#
# Deliberately NOT tied to any cluster architecture (no mlp): the only
# requirement on the far end is key-auth SSH + passwordless sudo.
# Run it from anywhere (Mac, Gateway, fh-l) against anywhere.
#
# usage:
#   do_record.sh <target> <zoomid> <zoompw> <outputmp4>
#   <target> : [user@]host[:port]  (plain ssh names work too via ~/.ssh/config)
#   e.g. do_record.sh worker-2302 72733198447 CNXi70 /tmp/meet.mp4
#   e.g. SSH_OPTS="-F ~/.mylinuxpool/ssh_config" do_record.sh worker-2302 ...
#   e.g. do_record.sh worker@127.0.0.1:2302 ...          (from the Gateway)
#   e.g. SSH_OPTS="-i ~/.ssh/key" do_record.sh ubuntu@1.2.3.4 ...  (any cloud VM)
#
# env overrides:
#   SSH_OPTS           extra flags for ssh/scp, e.g. "-F cfg -i key -J jump"
#                      (no spaces inside values; key-auth required)
#   REC_NAME           display name in meeting (default: rec-<target>)
#   TEST_SECS          >0: cap recording at N sec (same stop loop as real runs; default 0)
#   ALONE_SEC          stop after the bot has been the ONLY participant this long,
#                      once someone else was seen (default 300)
#   GONE_HITS          consecutive 5s probes without the meeting UI before stop (default 3)
#   ADMIT_TIMEOUT_SEC  how long to wait in waiting room (default 1200)
#   MAX_REC_SEC        safety cap on recording length (default 21600 = 6h)
#   RES_W / RES_H      virtual display size (default 1920 / 1080)
set -uo pipefail

usage() {
    echo "usage: $0 <target> <zoomid> <zoompw> <outputmp4>" >&2
    echo "  <target>: [user@]host[:port]; env: SSH_OPTS REC_NAME TEST_SECS ADMIT_TIMEOUT_SEC MAX_REC_SEC ALONE_SEC GONE_HITS RES_W RES_H" >&2
}

[[ $# -eq 4 ]] || { usage; exit 2; }
TARGET="$1"; ZID="$2"; ZPW="$3"; OUT="$4"

# split [user@]host[:port] (IPv6 not supported — use ssh-config names for those)
if [[ "$TARGET" == *@* ]]; then SSH_USER="${TARGET%%@*}"; REST="${TARGET#*@}"
else SSH_USER=""; REST="$TARGET"; fi
if [[ "$REST" == *:* ]]; then SSH_HOST="${REST%%:*}"; SSH_PORT="${REST##*:}"
else SSH_HOST="$REST"; SSH_PORT=""; fi
[[ -n "$SSH_HOST" ]] || { usage; exit 2; }
DEST="${SSH_USER:+$SSH_USER@}$SSH_HOST"

SSH=(ssh)
SCP=(scp)
if [[ -n "$SSH_PORT" ]]; then SSH+=(-p "$SSH_PORT"); SCP+=(-P "$SSH_PORT"); fi
if [[ -n "${SSH_OPTS:-}" ]]; then
    # shellcheck disable=SC2206
    EXTRA=($SSH_OPTS)
    SSH+=("${EXTRA[@]}"); SCP+=("${EXTRA[@]}")
fi
SSH_OPTS_DISPLAY="${SSH[*]}"

SAFEHOST="$(printf '%s' "$TARGET" | tr -c '[:alnum:]' '-' | cut -c1-20)"
REC_NAME="${REC_NAME:-rec-$SAFEHOST}"
TEST_SECS="${TEST_SECS:-0}"
ADMIT_TIMEOUT_SEC="${ADMIT_TIMEOUT_SEC:-1200}"
MAX_REC_SEC="${MAX_REC_SEC:-21600}"
RES_W="${RES_W:-1920}"
RES_H="${RES_H:-1080}"
ALONE_SEC="${ALONE_SEC:-300}"
GONE_HITS="${GONE_HITS:-3}"
[[ "$ALONE_SEC" =~ ^[0-9]+$ && "$GONE_HITS" =~ ^[1-9][0-9]*$ ]] || { echo "do_record: ALONE_SEC/GONE_HITS must be integers" >&2; exit 2; }

command -v ssh >/dev/null || { echo "do_record: ssh not found" >&2; exit 2; }
command -v scp >/dev/null || { echo "do_record: scp not found" >&2; exit 2; }

B64() { printf '%s' "$1" | base64 | tr -d '\n'; }
ZID_B64="$(B64 "$ZID")"
ZPW_B64="$(B64 "$ZPW")"
ZNAME_B64="$(B64 "$REC_NAME")"

echo "do_record: checking ssh to $DEST via [${SSH_OPTS_DISPLAY}] ..." >&2
"${SSH[@]}" -o BatchMode=yes -o ConnectTimeout=15 "$DEST" "mkdir -p /tmp/mlprec && echo ok" 2>&1 | tail -n 2
# (connectivity check above is informational; the upload below will fail loudly if ssh is broken)

echo "do_record: uploading recorder payload to $DEST ..." >&2
"${SSH[@]}" -o BatchMode=yes -o ConnectTimeout=15 "$DEST" 'cat > /tmp/mlprec/run.sh' <<'REMOTE_EOF'
#!/usr/bin/env bash
# run.sh (remote payload) — env in: ZID_B64 ZPW_B64 ZNAME_B64 TEST_SECS ADMIT_TIMEOUT_SEC MAX_REC_SEC
set -u
export DISPLAY=":99"
RDIR="/tmp/mlprec"
OUTMP4="$RDIR/out.mp4"
mkdir -p "$RDIR"
rm -f "$OUTMP4"

ZID="$(printf '%s' "${ZID_B64:?}" | base64 -d)"
ZPW="$(printf '%s' "${ZPW_B64:?}" | base64 -d)"
ZNAME="$(printf '%s' "${ZNAME_B64:?}" | base64 -d)"
TEST_SECS="${TEST_SECS:-0}"
ADMIT_TIMEOUT_SEC="${ADMIT_TIMEOUT_SEC:-1200}"
MAX_REC_SEC="${MAX_REC_SEC:-21600}"
RES_W="${RES_W:-1920}"
RES_H="${RES_H:-1080}"
ALONE_SEC="${ALONE_SEC:-300}"
GONE_HITS="${GONE_HITS:-3}"
CROP_Y=140
CROP_H=$((RES_H - CROP_Y))
export RES_W RES_H

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
# in-meeting toolbar evidence; one definition for INMEETING and the ENDED guard
TOOLBAR_RE="participants|leave meeting"
die() { log "FATAL: $*"; exit 1; }
# Kill OUR processes whose full command line matches an ERE. Never kill by bare
# name: mlp images (MyLinuxPool#431) shim pkill/killall to always fail, which
# silently left every old Chrome alive (and holding the CDP port) — #17.
kill_pat() {
    local pids
    pids="$(pgrep -u "$(id -u)" -f -- "$1" | tr '\n' ' ')"
    [[ -n "${pids// /}" ]] && kill -"${2:-TERM}" $pids 2>/dev/null
    return 0
}
CHROME_PAT="--user-data-dir=$RDIR/chrome-prof"
stop_chrome() {
    local i
    kill_pat "$CHROME_PAT"
    for i in $(seq 1 15); do pgrep -u "$(id -u)" -f -- "$CHROME_PAT" >/dev/null || return 0; sleep 1; done
    log "chrome ignored SIGTERM, SIGKILLing ..."
    kill_pat "$CHROME_PAT" KILL; sleep 2
}
shot() {
    local f="$RDIR/step_$1.png" out rc
    rm -f "$f"
    out="$(DISPLAY=:99 scrot "$f" 2>&1)"; rc=$?
    if [[ "$rc" -ne 0 || ! -s "$f" ]]; then
        log "shot FAILED($rc): $f: $out"
    else
        log "shot: $f ($(stat -c %s "$f") bytes)"
    fi
}
streams() { pactl list short sink-inputs 2>/dev/null | wc -l; }
wintitle() { xdotool getwindowname "$CHROME_WIN" 2>/dev/null; }
click_word() {
    # tsv-guided click: find WORD in screenshot, click at (left+DX, top+DY).
    # DX/DY = -1/-1 means word-box center. Prints "x y" or nothing.
    python3 - "$1" "$2" "$3" "$4" <<'PYEOF' 2>/dev/null
import sys, subprocess
png, w, dx, dy = sys.argv[1], sys.argv[2].lower(), int(sys.argv[3]), int(sys.argv[4])
try:
    out = subprocess.run(['tesseract', png, 'stdout', 'tsv'],
                         capture_output=True, text=True, timeout=25).stdout
except Exception:
    sys.exit(1)
for line in out.splitlines()[1:]:
    p = line.split('\t')
    if len(p) < 12 or p[0] != '5':
        continue
    if p[11].strip().lower().strip('.,!?"\'\u2019\u2018\u201c\u201d') == w:
        x, y, ww, hh = int(p[6]), int(p[7]), int(p[8]), int(p[9])
        if dx == -1 and dy == -1:
            print(f"{x + ww // 2} {y + hh // 2}")
        else:
            print(f"{x + dx} {y + dy}")
        break
PYEOF
}
ocr_crop() {
    # OCR a screen region (x y w h of $RDIR/nag.png) -> lowercase text.
    # Small crops OCR completely; full shots often truncate. No-ops on failure.
    local c="$RDIR/crop.png"
    ffmpeg -hide_banner -y -loglevel error -i "$RDIR/nag.png" -vf crop=$3:$4:$1:$2 "$c" 2>/dev/null || return 1
    tesseract "$c" stdout 2>/dev/null | tr '[:upper:]' '[:lower:]'
}
dismiss_nag() {
    # Kill toast overlays. Banner/toast X positions drift between sessions,
    # so: OCR-gate on cropped regions, then sweep-click the X zone.
    # All clicks are harmless single clicks on empty/meeting area if absent.
    local png="$RDIR/nag.png" xy t x
    rm -f "$png"
    DISPLAY=:99 scrot "$png" 2>/dev/null || return 0
    # 1. mid-screen "Please enable access..." banner -> sweep its right end
    # (2026-11-21: banner moved up to y~295 under Chrome 158; sweep both rows)
    t="$(ocr_crop 0 180 1920 420)"
    if printf '%s' "$t" | grep -q "please enable access"; then
        log "sweeping nag X ..."
        for y in 295 415; do
            for x in 1250 1270 1290 1310 1330; do
                DISPLAY=:99 xdotool mousemove $x $y click 1 2>/dev/null
                sleep 1
            done
        done
    fi
    # 2. AI "Got it" toast -> TSV word-center (proven 2x)
    for gw in Got Gotit; do
        xy="$(click_word "$png" "$gw" -1 -1)"
        if [[ -n "$xy" ]]; then
            log "dismissing AI toast at $xy"
            DISPLAY=:99 xdotool mousemove $xy click 1 2>/dev/null
            sleep 2
            break
        fi
    done
    # 2b. TSV often misses "Got it"; gate on a cropped OCR of the toast (only
    # the button text: "my notes"/"zoom ai" also appear in the AI panel) and
    # click the button at both known rows (toolbar shown: 318, hidden: 270)
    t="$(ocr_crop 1420 140 500 240)"
    if printf '%s' "$t" | grep -q -E "got it"; then
        log "clicking AI toast Got it ..."
        for y in 270 318; do
            DISPLAY=:99 xdotool mousemove 1731 $y click 1 2>/dev/null
            sleep 1
        done
    fi
    # 3. accel toast ("...graphics/hardware acceleration") -> sweep right end
    t="$(ocr_crop 900 150 1020 300)"
    if printf '%s' "$t" | grep -q "acceleration"; then
        log "sweeping accel X ..."
        for y in 226 355; do
            for x in 1280 1300 1320 1340; do
                DISPLAY=:99 xdotool mousemove $x $y click 1 2>/dev/null
                sleep 1
            done
        done
    fi
    DISPLAY=:99 xdotool mousemove 10 930 2>/dev/null
}
page_state() {
    # screenshot + OCR the meeting tab -> WAITING | PREJOIN | INMEETING | ENDED | UNKNOWN
    local png="$RDIR/state.png" txt tl now mt
    # jiggle the mouse first: the meeting toolbar auto-hides when idle, and
    # without it OCR sees no in-meeting evidence (false UNKNOWN 2026-09-22).
    DISPLAY=:99 xdotool mousemove 960 1060 2>/dev/null
    sleep 1
    tl="$(wintitle)"
    case "$tl" in *"Error - Zoom"*) echo INVALID; return ;; esac
    now=$(date +%s)
    rm -f "$png"
    DISPLAY=:99 scrot "$png" 2>/dev/null || { echo UNKNOWN; return; }
    mt=$(stat -c %Y "$png" 2>/dev/null || echo 0)
    [[ $((now - mt)) -gt 15 ]] && { echo UNKNOWN; return; }
    txt="$(tesseract "$png" stdout 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    printf '%s' "$txt" > "$RDIR/state.txt"
    if printf '%s' "$txt" | grep -q -E "let them know|waiting room|host will let you in"; then echo WAITING; return; fi
    if printf '%s' "$txt" | grep -q -E "has ended|has been ended|meeting ended|ended by host|host has ended|been removed|removed from the meeting|you left the meeting" \
        && ! printf '%s' "$txt" | grep -q -i -E "$TOOLBAR_RE"; then echo ENDED; return; fi
    # (ENDED needs the toolbar to be GONE too: chat or a shared screen saying
    # "has ended" must not stop a live recording.)
    if printf '%s' "$txt" | grep -q -E "link is invalid|invalid meeting|not found|does not exist|no longer available|meeting is over"; then echo INVALID; return; fi
    if printf '%s' "$txt" | grep -q -E "enter meeting info|meeting passcode|your name"; then echo PREJOIN; return; fi
    # INMEETING needs POSITIVE evidence (toolbar words). Empty/truncated OCR
    # must yield UNKNOWN, never INMEETING (false admit 2026-09-22).
    if printf '%s' "$txt" | grep -q -i -E "$TOOLBAR_RE"; then echo INMEETING; return; fi
    echo UNKNOWN
}

pulse_ok() {
    # healthy = pactl answers AND a monitor source exists (sets MON)
    MON=""
    timeout 5 pactl info >/dev/null 2>&1 || return 1
    MON="$(timeout 5 pactl list short sources 2>/dev/null | awk '/monitor/ {print $2; exit}')"
    [[ -n "$MON" ]]
}
ensure_pulse() {
    # pulseaudio can hang or die mid-session (2026-11-22: monitor open failed
    # with EAGAIN, then every restart hit "Daemon startup failed" on stale
    # runtime state). One round = restart THEN verify.
    local i
    pulse_ok && return 0
    for i in 1 2 3; do
        log "pulseaudio unhealthy — restart $i/3 ..."
        pulseaudio --kill 2>/dev/null; sleep 1
        kill_pat '^pulseaudio( |$)' KILL; sleep 1
        # Assumes a dedicated recorder box: /tmp/pulse-* of OTHER users would go too.
        rm -rf /tmp/pulse-* "${XDG_RUNTIME_DIR:-/nonexistent}/pulse" "$HOME/.config/pulse/"*-runtime 2>/dev/null
        pulseaudio -D --exit-idle-time=-1 --disallow-exit 2>&1 | head -n 2 >&2
        sleep 2
        pulse_ok && { log "pulseaudio recovered (monitor $MON)"; return 0; }
    done
    return 1
}
start_ffmpeg() {
    DISPLAY=:99 ffmpeg -hide_banner -y -loglevel warning \
        -video_size ${RES_W}x${CROP_H} -framerate 15 -f x11grab -i :99+0,${CROP_Y} \
        -f pulse -ac 2 -i "$MON" \
        -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p \
        -c:a aac -b:a 128k -movflags +faststart "$OUTMP4" >"$RDIR/ffmpeg.log" 2>&1 &
    FFPID=$!
    sleep 2
    kill -0 "$FFPID" 2>/dev/null
}

leave_meeting() {
    log "leaving meeting politely ..."
    if [[ "$(cdp_eval "$JS_LEAVE")" == clicked ]]; then
        sleep 2
        [[ "$(cdp_eval "$JS_LEAVE_CONFIRM")" == confirmed ]] && { sleep 3; return; }
    fi
    # fallback: coordinates (only when the DOM route failed)
    DISPLAY=:99 xdotool windowfocus "$CHROME_WIN" 2>/dev/null
    DISPLAY=:99 xdotool mousemove 960 1060 2>/dev/null; sleep 2
    DISPLAY=:99 xdotool mousemove 1875 1060 click 1 2>/dev/null; sleep 4
    DISPLAY=:99 xdotool mousemove 1735 633 click 1 2>/dev/null; sleep 4
}
stop_ffmpeg() {
    kill -INT "$FFPID" 2>/dev/null
    for i in $(seq 1 20); do kill -0 "$FFPID" 2>/dev/null || break; sleep 1; done
    kill -TERM "$FFPID" 2>/dev/null
}
on_exit() {
    # any exit after chrome launch (die included) must not leave the bot in
    # the meeting or ffmpeg running
    if [[ -n "${FFPID:-}" ]] && kill -0 "$FFPID" 2>/dev/null; then stop_ffmpeg; fi
    stop_chrome
}

# ---- CDP (Chrome DevTools Protocol, 127.0.0.1:9222 on this box only) ----
# Reading the page beats OCR/coordinates: participant count, in-meeting
# toolbar and toasts come straight from the DOM (#17). OCR stays as fallback.
cat > "$RDIR/cdp.py" <<'CDP_EOF'
import json, sys, urllib.request
try:
    import websocket
except ImportError:
    sys.exit(3)
try:
    tabs = json.load(urllib.request.urlopen("http://127.0.0.1:9222/json", timeout=5))
except Exception:
    sys.exit(3)
pages = [t for t in tabs if t.get("type") == "page" and "zoom.us" in t.get("url", "")]
if not pages:
    sys.exit(2)
try:
    ws = websocket.create_connection(pages[0]["webSocketDebuggerUrl"], timeout=10)
    ws.send(json.dumps({"id": 1, "method": "Runtime.evaluate",
                        "params": {"expression": sys.argv[1], "returnByValue": True}}))
    while True:
        msg = json.loads(ws.recv())
        if msg.get("id") == 1:
            break
    ws.close()
except Exception:
    sys.exit(3)
res = msg.get("result", {})
if "exceptionDetails" in res:
    sys.exit(3)
v = res.get("result", {}).get("value")
print(v if isinstance(v, str) else json.dumps(v))
CDP_EOF
cdp_eval() { timeout 20 python3 "$RDIR/cdp.py" "$1" 2>/dev/null; }
# -> "IN N": IN=1 when the footer Leave button exists (present even while the
# toolbar is visually hidden); N = participant count (incl. us) or -1.
# exit !=0 = CDP unavailable (no tab -> 2, protocol -> 3).
JS_PROBE='(() => { const b = [...document.querySelectorAll("button")];
  const leave = b.some(x => (x.getAttribute("aria-label") || "").trim() === "Leave");
  const pa = b.map(x => x.getAttribute("aria-label") || "").find(a => /participants list pane/i.test(a));
  const m = pa && pa.match(/\[(\d+)\]/);
  return (leave ? 1 : 0) + " " + (m ? m[1] : -1); })()'
meeting_probe() {
    local out rc
    out="$(cdp_eval "$JS_PROBE")"; rc=$?
    # no zoom tab at all = the page is gone (counts as "not in meeting")
    [[ "$rc" -eq 2 ]] && { echo "0 -1"; return 0; }
    [[ "$rc" -eq 0 && "$out" =~ ^[01]\ -?[0-9]+$ ]] || return 1
    echo "$out"
}
# hide nag/AI/accel toasts by TEXT and press any visible "Got it" (position-proof;
# replaces the --load-extension toast killer, which Chrome 137+ ignores)
JS_TOASTS='(() => { const P = ["please enable access", "a new home for zoom ai",
    "better meeting experience", "graphics/hardware acceleration"]; let k = 0;
  const all = [...document.querySelectorAll("body *")];
  for (const p of P) {
    // smallest element holding the whole phrase (toast text is split by
    // <button>microphone</button> etc., so leaf-only matching misses it) ...
    const hits = all.filter(e => e.offsetWidth > 0 && (e.textContent || "").toLowerCase().includes(p));
    if (!hits.length) continue;
    let n = hits.reduce((a, b) => (b.textContent.length < a.textContent.length ? b : a));
    // ... widened to the outermost toast-sized box (stop below full-width containers)
    while (n.parentElement && n.parentElement !== document.body && n.parentElement.offsetWidth < 1500) n = n.parentElement;
    if (n.offsetWidth < 1500) { n.style.setProperty("display", "none", "important"); k++; }
  }
  for (const x of document.querySelectorAll("button"))
    if ((x.innerText || "").trim() === "Got it" && x.offsetParent) { x.click(); k++; }
  return String(k); })()'
JS_LEAVE='(() => { const l = [...document.querySelectorAll("button")].find(x => (x.getAttribute("aria-label") || "").trim() === "Leave");
  if (!l) return "none"; l.click(); return "clicked"; })()'
JS_LEAVE_CONFIRM='(() => { const c = [...document.querySelectorAll("button")].find(x => /^leave meeting$/i.test((x.innerText || "").trim()));
  if (!c) return "none"; c.click(); return "confirmed"; })()'

decide_stop() {
    # Pure stop policy (#17; no I/O, unit-testable). Args:
    #   elapsed max ff_alive win_miss quiet_ticks gone_hits alone_sec seen_others
    # -> CONTINUE | ENDED:<why> | ABNORMAL:<why>
    # ENDED = normal end (exit 0). ABNORMAL = early stop (FATAL, exit 1, caller rejoins).
    local elapsed=$1 max=$2 ff=$3 wmiss=$4 quiet=$5 gone=$6 alone=$7 seen=$8
    [[ "$ff" -eq 1 ]]            || { echo "ABNORMAL:ffmpeg exited unexpectedly"; return; }
    [[ "$elapsed" -lt "$max" ]]  || { echo "ENDED:max rec cap reached"; return; }
    [[ "$wmiss" -lt 3 ]]         || { echo "ENDED:browser window gone"; return; }
    [[ "$gone" -lt "$GONE_HITS" ]] || { echo "ENDED:meeting page gone (ended by host / removed / left)"; return; }
    if [[ "$seen" -eq 1 && "$alone" -ge "$ALONE_SEC" ]]; then echo "ENDED:only the bot left for ${ALONE_SEC}s"; return; fi
    [[ "$quiet" -lt 24 ]]        || { echo "ABNORMAL:no audio 120s (disconnected?)"; return; }
    echo CONTINUE
}

# ---- 1. provision (idempotent; safe on fresh default workers) ----
log "provisioning (name=$ZNAME test_secs=$TEST_SECS) ..."
sudo -n true 2>/dev/null || die "need passwordless sudo on this worker"
export DEBIAN_FRONTEND=noninteractive
sudo dpkg --configure -a 2>&1 | tail -n 2 >&2
sudo apt-get update 2>&1 | tail -n 1 >&2
for p in xvfb ffmpeg pulseaudio pulseaudio-utils xdotool scrot mesa-utils curl ca-certificates tesseract-ocr python3-websocket; do
    dpkg -s "$p" >/dev/null 2>&1 || sudo apt-get install -y "$p" 2>&1 | tail -n 1 >&2
done
if ! command -v google-chrome >/dev/null 2>&1; then
    log "installing google-chrome (141MB, one-time) ..."
    curl --retry 3 -sL -o "$RDIR/chrome.deb" https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb \
        || die "chrome download failed"
    sudo apt-get install -y "$RDIR/chrome.deb" 2>&1 | tail -n 2 >&2
    command -v google-chrome >/dev/null 2>&1 || die "chrome install failed"
fi
log "provision ok: $(google-chrome --version 2>/dev/null), $(ffmpeg -hide_banner -version 2>/dev/null | head -n1)"

# ---- 2. virtual display + dummy audio ----
CUR="$(DISPLAY=:99 xdotool getdisplaygeometry 2>/dev/null | awk '{print $1"x"$2}')"
[[ -z "$CUR" || "$CUR" == "x" ]] && CUR="none"
if [[ "$CUR" != "${RES_W}x${RES_H}" ]]; then
    log "display is '$CUR', want ${RES_W}x${RES_H} — (re)starting Xvfb ..."
    kill_pat '^Xvfb :99( |$)'; sleep 2
    rm -f /tmp/.X11-unix/X99
    setsid Xvfb :99 -screen 0 ${RES_W}x${RES_H}x24 -ac </dev/null >"$RDIR/xvfb.log" 2>&1 &
    for i in $(seq 1 10); do ls /tmp/.X11-unix/X99 >/dev/null 2>&1 && break; sleep 1; done
fi
ls /tmp/.X11-unix/X99 >/dev/null 2>&1 || die "Xvfb did not start"
log "display: $(DISPLAY=:99 xdotool getdisplaygeometry 2>/dev/null)"
ensure_pulse || die "no pulseaudio monitor source (restart did not help)"
log "display :99 + audio monitor $MON ready"

# ---- 3. launch chrome (bot profile), straight at the join page ----
stop_chrome
pgrep -u "$(id -u)" -f -- "$CHROME_PAT" >/dev/null && die "could not stop a previous chrome (it would hold the CDP port)"
rm -rf "$RDIR/chrome-prof"; mkdir -p "$RDIR/chrome-prof"
setsid bash -c 'DISPLAY=:99 google-chrome --no-sandbox --disable-dev-shm-usage --no-first-run --no-default-browser-check --use-angle=swiftshader --enable-unsafe-swiftshader --autoplay-policy=no-user-gesture-required --remote-debugging-port=9222 --remote-allow-origins=* --window-size=${RES_W},${RES_H} --window-position=0,0 --user-data-dir="$0/chrome-prof" "https://app.zoom.us/wc/$1/join"' "$RDIR" "$ZID" </dev/null >"$RDIR/chrome.log" 2>&1 &
trap on_exit EXIT
CHROME_WIN=""
for i in $(seq 1 30); do
    CHROME_WIN="$(DISPLAY=:99 xdotool search --onlyvisible --class google-chrome 2>/dev/null | head -n1)"
    [[ -n "$CHROME_WIN" ]] && break
    sleep 1
done
[[ -n "$CHROME_WIN" ]] || { shot nochrome; die "chrome window never appeared"; }
log "chrome window $CHROME_WIN"

# ---- 4. join form is the startup page; confirm it loaded, fill passcode + name ----
DISPLAY=:99 xdotool windowfocus "$CHROME_WIN"
sleep 8
DISPLAY=:99 xdotool key Escape  # dismiss notification-permission popup if any
sleep 2
# cookie banner (OCR-gated; covers the form on fresh profiles) then
# device-permission modals ("Continue without microphone and camera" — OCR-gated).
# No fake devices on purpose: bot stays camera-off (black tile) + muted.
DISPLAY=:99 xdotool mousemove 1100 595 click 1 2>/dev/null
sleep 2
for i in 1 2; do
    rm -f "$RDIR/ck.png"
    DISPLAY=:99 scrot "$RDIR/ck.png" 2>/dev/null || break
    tesseract "$RDIR/ck.png" stdout 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep -q "accept cookies" || break
    log "accepting cookies ($i)"
    DISPLAY=:99 xdotool mousemove 1100 595 click 1
    sleep 3
done
# device modals, gated on their TITLE (link text OCRs unreliably under the dim overlay)
for i in 1 2 3; do
    rm -f "$RDIR/m.png"
    DISPLAY=:99 scrot "$RDIR/m.png" 2>/dev/null || break
    tesseract "$RDIR/m.png" stdout 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep -q "do you want people" || break
    log "dismissing device modal ($i)"
    DISPLAY=:99 xdotool mousemove 975 765 click 1
    sleep 3
done
shot joinpage
OKFORM=0
for i in $(seq 1 6); do
    ST="$(page_state)"
    [[ "$ST" == "PREJOIN" ]] && { OKFORM=1; break; }
    [[ "$ST" == "INVALID" ]] && { shot badlink; die "join page reports invalid/nonexistent meeting — check the meeting ID (see step_badlink.png)"; }
    sleep 5
done
[[ "$OKFORM" == "1" ]] || { die "join form never loaded (see step_joinpage.png)"; }
DISPLAY=:99 xdotool windowfocus "$CHROME_WIN"
DISPLAY=:99 xdotool mousemove 1355 485 click 1
sleep 1
DISPLAY=:99 xdotool type -- "$ZPW"
sleep 1
DISPLAY=:99 xdotool mousemove 1355 555 click 1
sleep 1
DISPLAY=:99 xdotool type -- "$ZNAME"
sleep 1
shot filled
# submit: keyboard Enter in the name field first (most reliable), then button clicks
DISPLAY=:99 xdotool mousemove 1355 555 click 1
sleep 1
DISPLAY=:99 xdotool key Return
for i in 1 2 3 4 5; do
    sleep 10
    [[ "$(page_state)" != "PREJOIN" ]] && break
    DISPLAY=:99 xdotool mousemove 1355 630 click 1
    sleep 2
done
[[ "$(page_state)" != "PREJOIN" ]] || { die "Join submit did not advance past the form (see step_filled.png)"; }
log "join submitted as $ZNAME, waiting for admit (timeout ${ADMIT_TIMEOUT_SEC}s) ..."

# ---- 5. wait for admit (OCR the page: waiting-room pages keep dummy audio
# streams open, so stream-counting alone false-triggers — verified 2026-09-21) ----
INHITS=0; WAITED=0
while [[ "$WAITED" -lt "$ADMIT_TIMEOUT_SEC" ]]; do
    ST="$(page_state)"
    log "state=$ST"
    if [[ "$ST" == "INMEETING" ]]; then
        INHITS=$((INHITS + 1))
        [[ "$INHITS" -ge 2 ]] && break
    else
        INHITS=0
    fi
    [[ "$ST" == "ENDED" ]] && { die "meeting ended before we were admitted"; }
    sleep 10
    WAITED=$((WAITED + 10))
done
[[ "$INHITS" -ge 2 ]] || { shot noadmit; die "not admitted within ${ADMIT_TIMEOUT_SEC}s (still in waiting room?)"; }
log "admitted (audio streams flowing)"
sleep 3
shot admitted
# dismiss in-meeting toasts: DOM first, coordinates only if CDP is down
[[ "$(cdp_eval "$JS_TOASTS")" =~ ^[0-9]+$ ]] || dismiss_nag

# ---- 6. record ----
rm -f "$OUTMP4"
log "recording to $OUTMP4 ..."
# crop to page area only (y=140): no browser tabs/omnibox/infobar in the mp4.
if ! start_ffmpeg; then
    tail -n 5 "$RDIR/ffmpeg.log" >&2
    log "ffmpeg died at startup — repairing pulseaudio and retrying once ..."
    ensure_pulse || die "pulseaudio unrecoverable"
    start_ffmpeg || { tail -n 5 "$RDIR/ffmpeg.log" >&2; die "ffmpeg died at startup (after pulse repair)"; }
fi
log "ffmpeg pid $FFPID recording"

# TEST_SECS is only a shorter cap: tests exercise the SAME stop loop as real runs.
CAP="$MAX_REC_SEC"
[[ "$TEST_SECS" -gt 0 ]] && { CAP="$TEST_SECS"; log "test mode: cap ${TEST_SECS}s"; }
sleep 5
[[ "$(cdp_eval "$JS_TOASTS")" =~ ^[0-9]+$ ]] || dismiss_nag
START=$(date +%s)
MISS=0; QUIET=0; GONE=0; ALONE=0; SEEN=0; CDPFAIL=0; TICK=0; ABNORMAL=""; LASTN=""
while true; do
    sleep 5
    ELAPSED=$(( $(date +%s) - START )); TICK=$((TICK + 5))
    FF=1; kill -0 "$FFPID" 2>/dev/null || FF=0
    if [[ -n "$(wintitle)" ]]; then MISS=0; else MISS=$((MISS + 1)); log "chrome window lost ($MISS/3)"; fi
    if [[ "$(streams)" -ge 1 ]]; then QUIET=0; else QUIET=$((QUIET + 1)); fi
    if P="$(meeting_probe)"; then
        CDPFAIL=0; read -r PIN PN <<<"$P"
        if [[ "$PIN" -eq 1 ]]; then
            GONE=0
            [[ "$PN" -ge 2 ]] && SEEN=1
            if [[ "$PN" -eq 1 ]]; then ALONE=$((ALONE + 5)); else ALONE=0; fi
        else
            GONE=$((GONE + 1)); log "meeting UI absent ($GONE/$GONE_HITS)"
        fi
        [[ "$PN" != "$LASTN" ]] && { log "participants=$PN (in=$PIN)"; LASTN="$PN"; }
    else
        CDPFAIL=$((CDPFAIL + 1)); ALONE=0
        [[ "$CDPFAIL" -eq 3 ]] && log "CDP unavailable — falling back to OCR checks"
    fi
    R="$(decide_stop "$ELAPSED" "$CAP" "$FF" "$MISS" "$QUIET" "$GONE" "$ALONE" "$SEEN")"
    case "$R" in
        CONTINUE) ;;
        ENDED:*) log "stop: ${R#ENDED:}"; break ;;
        ABNORMAL:*) ABNORMAL="${R#ABNORMAL:}"; [[ "$FF" -eq 0 ]] && tail -n 5 "$RDIR/ffmpeg.log" >&2; log "stop (abnormal): $ABNORMAL"; break ;;
    esac
    if [[ "$TICK" -ge 60 ]]; then
        TICK=0
        if [[ "$CDPFAIL" -lt 3 ]]; then
            cdp_eval "$JS_TOASTS" >/dev/null
        else
            # OCR fallback (only while CDP is down)
            ST="$(page_state)"; log "ocr state=$ST"
            if [[ "$ST" == "ENDED" ]]; then
                sleep 10; ST="$(page_state)"; log "ocr state (confirm)=$ST"
                [[ "$ST" == "ENDED" ]] && { log "stop: meeting ended (ocr)"; break; }
            fi
            dismiss_nag
        fi
    fi
done
stop_ffmpeg
[[ -n "$(wintitle)" ]] && leave_meeting
shot end

# ---- 7. verify + cleanup ----
stop_chrome
[[ -s "$OUTMP4" ]] || die "no output mp4 produced"
# non-empty is not enough: a killed ffmpeg leaves an mp4 without moov atom
DUR="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUTMP4" 2>/dev/null)"
[[ "$DUR" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "output mp4 unreadable (no duration; ffmpeg crashed?)"
ffprobe -hide_banner "$OUTMP4" 2>&1 | grep -E 'Duration|Stream' >&2
# an early stop is a FAILURE (exit 1) so callers rejoin; a readable partial
# mp4 is still kept and fetched by the controller
[[ -z "${ABNORMAL:-}" ]] || die "recording stopped early: $ABNORMAL (partial mp4 kept, ${DUR%.*}s)"
log "DONE $OUTMP4 ($(du -h "$OUTMP4" | cut -f1))"
REMOTE_EOF
echo "do_record: payload uploaded" >&2

echo "do_record: launching remote recorder on $DEST (name=$REC_NAME, detached) ..." >&2
# shellcheck disable=SC2029
"${SSH[@]}" -o BatchMode=yes -o ConnectTimeout=15 "$DEST" \
    "rm -f /tmp/mlprec/run.out; ZID_B64='$ZID_B64' ZPW_B64='$ZPW_B64' ZNAME_B64='$ZNAME_B64' TEST_SECS='$TEST_SECS' ADMIT_TIMEOUT_SEC='$ADMIT_TIMEOUT_SEC' MAX_REC_SEC='$MAX_REC_SEC' ALONE_SEC='$ALONE_SEC' GONE_HITS='$GONE_HITS' RES_W='$RES_W' RES_H='$RES_H' setsid bash /tmp/mlprec/run.sh </dev/null >>/tmp/mlprec/run.out 2>&1 & echo LAUNCHED" \
    || { echo "do_record: remote launch failed" >&2; exit 1; }

WAIT_BUDGET=$(( ADMIT_TIMEOUT_SEC + 300 ))
if [[ "$TEST_SECS" -gt 0 ]]; then WAIT_BUDGET=$(( WAIT_BUDGET + TEST_SECS + 300 )); else WAIT_BUDGET=$(( WAIT_BUDGET + MAX_REC_SEC + 600 )); fi
echo "do_record: polling remote progress (budget ${WAIT_BUDGET}s) ..." >&2
LAST=0; ELAPSED=0; RC=1
while [[ "$ELAPSED" -lt "$WAIT_BUDGET" ]]; do
    sleep 15; ELAPSED=$((ELAPSED + 15))
    FROM=$((LAST + 1))
    BATCH="$("${SSH[@]}" -o BatchMode=yes -o ConnectTimeout=15 "$DEST" \
        "TOTAL=\$(wc -l < /tmp/mlprec/run.out 2>/dev/null || echo 0); echo LINES:\$TOTAL; sed -n '${FROM},\$p' /tmp/mlprec/run.out 2>/dev/null; if grep -qE 'DONE /tmp|FATAL: ' /tmp/mlprec/run.out 2>/dev/null; then echo STATUS:FINISHED; elif pgrep -f '[r]un.sh' >/dev/null 2>&1; then echo STATUS:RUNNING; else echo STATUS:GONE; fi" \
        2>/dev/null)" || { echo "do_record: poll ssh failed, retrying ..." >&2; continue; }
    NL="$(printf '%s' "$BATCH" | sed -n 's/^LINES://p' | head -n1)"
    [[ "$NL" =~ ^[0-9]+$ ]] && LAST="$NL"
    printf '%s\n' "$BATCH" | sed -e '1d' -e '/^STATUS:/d' | sed '/^$/d'
    ST="$(printf '%s' "$BATCH" | sed -n 's/^STATUS://p' | head -n1)"
    if [[ "$ST" == "FINISHED" ]]; then
        if "${SSH[@]}" -o BatchMode=yes -o ConnectTimeout=15 "$DEST" "grep -q 'FATAL: ' /tmp/mlprec/run.out" 2>/dev/null; then
            echo "do_record: remote recorder reported FAILURE" >&2; RC=1
        else
            RC=0
        fi
        break
    elif [[ "$ST" == "GONE" ]]; then
        echo "do_record: remote recorder vanished without DONE (see /tmp/mlprec/run.out on $DEST)" >&2; RC=1; break
    fi
done
[[ "$ELAPSED" -lt "$WAIT_BUDGET" ]] || { echo "do_record: poll budget exhausted; remote may still run (check /tmp/mlprec/run.out on $DEST)" >&2; RC=1; }
if [[ "$RC" -ne 0 ]]; then
    # salvage a readable partial recording (run.sh deletes stale out.mp4 at start)
    if "${SSH[@]}" -o BatchMode=yes -o ConnectTimeout=15 "$DEST" \
        "ffprobe -v error -show_entries format=duration -of csv=p=0 /tmp/mlprec/out.mp4 2>/dev/null | grep -qE '^[0-9]'" 2>/dev/null; then
        mkdir -p "$(dirname "$OUT")"
        "${SCP[@]}" -o BatchMode=yes "$DEST:/tmp/mlprec/out.mp4" "$OUT" \
            && echo "do_record: FAILED, but fetched partial mp4 -> $OUT" >&2
    fi
    exit 1
fi

echo "do_record: fetching mp4 -> $OUT ..." >&2
mkdir -p "$(dirname "$OUT")"
"${SCP[@]}" -o BatchMode=yes "$DEST:/tmp/mlprec/out.mp4" "$OUT" || { echo "do_record: scp back failed" >&2; exit 1; }
ls -la "$OUT"
echo "do_record: done: $OUT" >&2
