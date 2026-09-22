#!/usr/bin/env bash
# do_record.sh — Mac controller: provision a (possibly fresh) mlp worker,
# join a Zoom meeting headlessly (Chrome web client under Xvfb), record
# screen+audio with ffmpeg until the meeting ends, fetch the mp4 back.
#
# usage:
#   ~/testSH/do_record.sh <host> <zoomid> <zoompw> <outputmp4>
#   e.g. ~/testSH/do_record.sh worker-2300 72733198447 CNXi70 /tmp/meet.mp4
#
# <host> must be ssh-able (mlp ssh-config --write first).
# env overrides:
#   REC_NAME           display name in meeting (default: rec-<host>)
#   TEST_SECS          >0: record N sec after admit then leave (default 0 = till meeting ends)
#   ADMIT_TIMEOUT_SEC  how long to wait in waiting room (default 1200)
#   MAX_REC_SEC        safety cap on recording length (default 21600 = 6h)
#   SSH_CFG            ssh config file (default ~/.mylinuxpool/ssh_config)
set -uo pipefail

usage() {
    echo "usage: $0 <host> <zoomid> <zoompw> <outputmp4>" >&2
    echo "env: REC_NAME TEST_SECS ADMIT_TIMEOUT_SEC MAX_REC_SEC SSH_CFG" >&2
}

[[ $# -eq 4 ]] || { usage; exit 2; }
HOST="$1"; ZID="$2"; ZPW="$3"; OUT="$4"

SSH_CFG="${SSH_CFG:-$HOME/.mylinuxpool/ssh_config}"
SAFEHOST="$(printf '%s' "$HOST" | tr -c '[:alnum:]' '-' | cut -c1-20)"
REC_NAME="${REC_NAME:-rec-$SAFEHOST}"
TEST_SECS="${TEST_SECS:-0}"
ADMIT_TIMEOUT_SEC="${ADMIT_TIMEOUT_SEC:-1200}"
MAX_REC_SEC="${MAX_REC_SEC:-21600}"
RES_W="${RES_W:-1920}"
RES_H="${RES_H:-1080}"

[[ -f "$SSH_CFG" ]] || { echo "do_record: ssh config not found: $SSH_CFG (run: mlp ssh-config --write)" >&2; exit 2; }
command -v ssh >/dev/null || { echo "do_record: ssh not found" >&2; exit 2; }
command -v scp >/dev/null || { echo "do_record: scp not found" >&2; exit 2; }

B64() { printf '%s' "$1" | base64 | tr -d '\n'; }
ZID_B64="$(B64 "$ZID")"
ZPW_B64="$(B64 "$ZPW")"
ZNAME_B64="$(B64 "$REC_NAME")"

echo "do_record: checking ssh to $HOST ..." >&2
ssh -F "$SSH_CFG" -o BatchMode=yes -o ConnectTimeout=15 "$HOST" "mkdir -p /tmp/mlprec && echo ok" 2>&1 | tail -n 2
# shellcheck disable=SC2181
# (connectivity check above is informational; the upload below will fail loudly if ssh is broken)

echo "do_record: uploading recorder payload to $HOST ..." >&2
ssh -F "$SSH_CFG" -o BatchMode=yes -o ConnectTimeout=15 "$HOST" 'cat > /tmp/mlprec/run.sh' <<'REMOTE_EOF'
#!/usr/bin/env bash
# run.sh (remote payload) — env in: ZID_B64 ZPW_B64 ZNAME_B64 TEST_SECS ADMIT_TIMEOUT_SEC MAX_REC_SEC
set -u
export DISPLAY=":99"
RDIR="/tmp/mlprec"
OUTMP4="$RDIR/out.mp4"
mkdir -p "$RDIR"

ZID="$(printf '%s' "${ZID_B64:?}" | base64 -d)"
ZPW="$(printf '%s' "${ZPW_B64:?}" | base64 -d)"
ZNAME="$(printf '%s' "${ZNAME_B64:?}" | base64 -d)"
TEST_SECS="${TEST_SECS:-0}"
ADMIT_TIMEOUT_SEC="${ADMIT_TIMEOUT_SEC:-1200}"
MAX_REC_SEC="${MAX_REC_SEC:-21600}"
RES_W="${RES_W:-1920}"
RES_H="${RES_H:-1080}"
CROP_Y=140
CROP_H=$((RES_H - CROP_Y))
export RES_W RES_H

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }
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
dismiss_nag() {
    # "Please enable access to your microphone and camera" toast:
    # Escape first, then its X (best effort, harmless if absent).
    DISPLAY=:99 xdotool key Escape 2>/dev/null
    sleep 1
    DISPLAY=:99 xdotool mousemove 1320 427 click 1 2>/dev/null
    sleep 1
}
page_state() {
    # screenshot + OCR the meeting tab -> WAITING | PREJOIN | INMEETING | ENDED | UNKNOWN
    local png="$RDIR/state.png" txt tl now mt
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
    if printf '%s' "$txt" | grep -q -E "has ended|meeting ended|ended by host"; then echo ENDED; return; fi
    if printf '%s' "$txt" | grep -q -E "link is invalid|invalid meeting|not found|does not exist|no longer available|meeting is over"; then echo INVALID; return; fi
    if printf '%s' "$txt" | grep -q -E "enter meeting info|meeting passcode"; then echo PREJOIN; return; fi
    tl="$(wintitle)"
    case "$tl" in *"Zoom Meeting - Google Chrome"*) echo INMEETING ;; *) echo UNKNOWN ;; esac
}

# ---- 1. provision (idempotent; safe on fresh default workers) ----
log "provisioning (name=$ZNAME test_secs=$TEST_SECS) ..."
sudo -n true 2>/dev/null || die "need passwordless sudo on this worker"
export DEBIAN_FRONTEND=noninteractive
sudo dpkg --configure -a 2>&1 | tail -n 2 >&2
sudo apt-get update 2>&1 | tail -n 1 >&2
for p in xvfb ffmpeg pulseaudio pulseaudio-utils xdotool scrot mesa-utils curl ca-certificates tesseract-ocr; do
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
pgrep -x Xvfb >/dev/null 2>&1 || {
    rm -f /tmp/.X11-unix/X99
    setsid Xvfb :99 -screen 0 ${RES_W}x${RES_H}x24 -ac </dev/null >"$RDIR/xvfb.log" 2>&1 &
}
for i in $(seq 1 10); do ls /tmp/.X11-unix/X99 >/dev/null 2>&1 && break; sleep 1; done
ls /tmp/.X11-unix/X99 >/dev/null 2>&1 || die "Xvfb did not start"
pactl info >/dev/null 2>&1 || pulseaudio -D --exit-idle-time=-1 --disallow-exit 2>&1 | head -n 2 >&2
sleep 1
MON="$(pactl list short sources 2>/dev/null | awk '/monitor/ {print $2; exit}')"
[[ -n "$MON" ]] || die "no pulseaudio monitor source (pactl list sources empty)"
log "display :99 + audio monitor $MON ready"

# ---- 3. launch chrome (bot profile), straight at the join page ----
pkill -x chrome 2>/dev/null
for i in $(seq 1 20); do
    DISPLAY=:99 xdotool search --onlyvisible --class google-chrome 2>/dev/null | head -n1 | grep -q . || break
    sleep 1
done
if DISPLAY=:99 xdotool search --onlyvisible --class google-chrome 2>/dev/null | head -n1 | grep -q .; then
    log "chrome ignored SIGTERM, SIGKILLing ..."
    pkill -9 -x chrome 2>/dev/null; sleep 3
fi
rm -rf "$RDIR/chrome-prof"; mkdir -p "$RDIR/chrome-prof"
setsid bash -c 'DISPLAY=:99 google-chrome --no-sandbox --disable-dev-shm-usage --no-first-run --no-default-browser-check --use-angle=swiftshader --enable-unsafe-swiftshader --autoplay-policy=no-user-gesture-required --window-size=${RES_W},${RES_H} --window-position=0,0 --user-data-dir="$0/chrome-prof" "https://app.zoom.us/wc/$1/join"' "$RDIR" "$ZID" </dev/null >"$RDIR/chrome.log" 2>&1 &
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
for i in 1 2; do
    rm -f "$RDIR/ck.png"
    DISPLAY=:99 scrot "$RDIR/ck.png" 2>/dev/null || break
    tesseract "$RDIR/ck.png" stdout 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep -q "accept cookies" || break
    log "accepting cookies ($i)"
    DISPLAY=:99 xdotool mousemove 1010 450 click 1
    sleep 3
done
for i in 1 2 3; do
    rm -f "$RDIR/m.png"
    DISPLAY=:99 scrot "$RDIR/m.png" 2>/dev/null || break
    tesseract "$RDIR/m.png" stdout 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep -q "continue without" || break
    log "dismissing device modal ($i)"
    DISPLAY=:99 xdotool mousemove 960 600 click 1
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
DISPLAY=:99 xdotool mousemove 1335 313 click 1
sleep 1
DISPLAY=:99 xdotool type -- "$ZPW"
sleep 1
DISPLAY=:99 xdotool mousemove 1335 392 click 1
sleep 1
DISPLAY=:99 xdotool type -- "$ZNAME"
sleep 1
shot filled
# submit: keyboard Enter in the name field first (most reliable), then button clicks
DISPLAY=:99 xdotool mousemove 1335 392 click 1
sleep 1
DISPLAY=:99 xdotool key Return
for i in 1 2 3 4 5; do
    sleep 10
    [[ "$(page_state)" != "PREJOIN" ]] && break
    DISPLAY=:99 xdotool mousemove 1335 478 click 1
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
# dismiss in-meeting toasts (best effort)
DISPLAY=:99 xdotool mousemove 1415 285 click 1 2>/dev/null
sleep 1
DISPLAY=:99 xdotool mousemove 1310 362 click 1 2>/dev/null
sleep 1
dismiss_nag

# ---- 6. record ----
rm -f "$OUTMP4"
log "recording to $OUTMP4 ..."
# crop to page area only (y=140): no browser tabs/omnibox/infobar in the mp4.
DISPLAY=:99 ffmpeg -hide_banner -y -loglevel warning \
    -video_size ${RES_W}x${CROP_H} -framerate 15 -f x11grab -i :99+0,${CROP_Y} \
    -f pulse -ac 2 -i "$MON" \
    -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p \
    -c:a aac -b:a 128k -movflags +faststart "$OUTMP4" >"$RDIR/ffmpeg.log" 2>&1 &
FFPID=$!
sleep 2
kill -0 "$FFPID" 2>/dev/null || { tail -n 5 "$RDIR/ffmpeg.log" >&2; die "ffmpeg died at startup"; }
log "ffmpeg pid $FFPID recording"

leave_meeting() {
    log "leaving meeting politely ..."
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

if [[ "$TEST_SECS" -gt 0 ]]; then
    log "test mode: recording ${TEST_SECS}s ..."
    sleep "$TEST_SECS"
    stop_ffmpeg
    leave_meeting
else
    START=$(date +%s)
    MISS=0; QUIET=0; OCR_TICK=0
    while true; do
        sleep 5
        NOW=$(date +%s)
        [[ $((NOW - START)) -ge "$MAX_REC_SEC" ]] && { log "max rec cap reached"; break; }
        TITLE="$(wintitle)"
        case "$TITLE" in
            *"Zoom Meeting - Google Chrome"*) MISS=0 ;;
            *) MISS=$((MISS + 1)); log "title lost ($MISS/3): $TITLE" ;;
        esac
        [[ "$MISS" -ge 3 ]] && { log "meeting window gone -> ended"; break; }
        N="$(streams)"
        if [[ "$N" -ge 1 ]]; then QUIET=0; else QUIET=$((QUIET + 1)); fi
        [[ "$QUIET" -ge 24 ]] && { log "no audio 120s (disconnected?) -> stop"; break; }
        OCR_TICK=$((OCR_TICK + 5))
        if [[ "$OCR_TICK" -ge 60 ]]; then
            OCR_TICK=0
            ST="$(page_state)"; log "ocr state=$ST"
            [[ "$ST" == "ENDED" ]] && { log "meeting ended (host)"; break; }
            if grep -q "please enable access" "$RDIR/state.txt" 2>/dev/null; then
                log "nag banner back, dismissing ..."
                dismiss_nag
            fi
        fi
    done
    stop_ffmpeg
    case "$(wintitle)" in
        *"Zoom Meeting - Google Chrome"*) leave_meeting ;;
    esac
fi
shot end

# ---- 7. verify + cleanup ----
pkill -x chrome 2>/dev/null
[[ -s "$OUTMP4" ]] || die "no output mp4 produced"
ffprobe -hide_banner "$OUTMP4" 2>&1 | grep -E 'Duration|Stream' >&2
log "DONE $OUTMP4 ($(du -h "$OUTMP4" | cut -f1))"
REMOTE_EOF
echo "do_record: payload uploaded" >&2

echo "do_record: launching remote recorder on $HOST (name=$REC_NAME, detached) ..." >&2
# shellcheck disable=SC2029
ssh -F "$SSH_CFG" -o BatchMode=yes -o ConnectTimeout=15 "$HOST" \
    "rm -f /tmp/mlprec/run.out; ZID_B64='$ZID_B64' ZPW_B64='$ZPW_B64' ZNAME_B64='$ZNAME_B64' TEST_SECS='$TEST_SECS' ADMIT_TIMEOUT_SEC='$ADMIT_TIMEOUT_SEC' MAX_REC_SEC='$MAX_REC_SEC' RES_W='$RES_W' RES_H='$RES_H' setsid bash /tmp/mlprec/run.sh </dev/null >>/tmp/mlprec/run.out 2>&1 & echo LAUNCHED" \
    || { echo "do_record: remote launch failed" >&2; exit 1; }

WAIT_BUDGET=$(( ADMIT_TIMEOUT_SEC + 300 ))
if [[ "$TEST_SECS" -gt 0 ]]; then WAIT_BUDGET=$(( WAIT_BUDGET + TEST_SECS + 300 )); else WAIT_BUDGET=$(( WAIT_BUDGET + MAX_REC_SEC + 600 )); fi
echo "do_record: polling remote progress (budget ${WAIT_BUDGET}s) ..." >&2
LAST=0; ELAPSED=0; RC=1
while [[ "$ELAPSED" -lt "$WAIT_BUDGET" ]]; do
    sleep 15; ELAPSED=$((ELAPSED + 15))
    FROM=$((LAST + 1))
    BATCH="$(ssh -F "$SSH_CFG" -o BatchMode=yes -o ConnectTimeout=15 "$HOST" \
        "TOTAL=\$(wc -l < /tmp/mlprec/run.out 2>/dev/null || echo 0); echo LINES:\$TOTAL; sed -n '${FROM},\$p' /tmp/mlprec/run.out 2>/dev/null; if grep -qE 'DONE /tmp|FATAL: ' /tmp/mlprec/run.out 2>/dev/null; then echo STATUS:FINISHED; elif pgrep -f '[r]un.sh' >/dev/null 2>&1; then echo STATUS:RUNNING; else echo STATUS:GONE; fi" \
        2>/dev/null)" || { echo "do_record: poll ssh failed, retrying ..." >&2; continue; }
    NL="$(printf '%s' "$BATCH" | sed -n 's/^LINES://p' | head -n1)"
    [[ "$NL" =~ ^[0-9]+$ ]] && LAST="$NL"
    printf '%s\n' "$BATCH" | sed -e '1d' -e '/^STATUS:/d' | sed '/^$/d'
    ST="$(printf '%s' "$BATCH" | sed -n 's/^STATUS://p' | head -n1)"
    if [[ "$ST" == "FINISHED" ]]; then
        if ssh -F "$SSH_CFG" -o BatchMode=yes -o ConnectTimeout=15 "$HOST" "grep -q 'FATAL: ' /tmp/mlprec/run.out" 2>/dev/null; then
            echo "do_record: remote recorder reported FAILURE" >&2; RC=1
        else
            RC=0
        fi
        break
    elif [[ "$ST" == "GONE" ]]; then
        echo "do_record: remote recorder vanished without DONE (see /tmp/mlprec/run.out on $HOST)" >&2; RC=1; break
    fi
done
[[ "$ELAPSED" -lt "$WAIT_BUDGET" ]] || { echo "do_record: poll budget exhausted; remote may still run (check /tmp/mlprec/run.out on $HOST)" >&2; RC=1; }
[[ "$RC" -eq 0 ]] || exit 1

echo "do_record: fetching mp4 -> $OUT ..." >&2
mkdir -p "$(dirname "$OUT")"
scp -F "$SSH_CFG" -o BatchMode=yes "$HOST:/tmp/mlprec/out.mp4" "$OUT" || { echo "do_record: scp back failed" >&2; exit 1; }
ls -la "$OUT"
echo "do_record: done: $OUT" >&2
