#!/usr/bin/env bash
# Unit test for decide_stop (the recording stop policy) in do_record.sh.
# Extracts the function from the remote payload and checks the table below.
# usage: bash test_decide_stop.sh   (no network, no worker)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
eval "$(awk '/^decide_stop\(\) \{/,/^}/' "$HERE/do_record.sh")"
declare -F decide_stop >/dev/null || { echo "decide_stop not found in do_record.sh"; exit 1; }
ALONE_SEC=300; GONE_HITS=3; fail=0
t() { local want="$1"; shift; local got; got="$(decide_stop "$@")"
      if [[ "$got" == "$want"* ]]; then echo "ok   $want <- $*"; else echo "FAIL want=$want got=$got <- $*"; fail=1; fi; }
#   elapsed max ff wmiss quiet gone alone seen
t CONTINUE            100 3600 1 0 0 0 0   0
t CONTINUE            100 3600 1 0 0 0 900 0   # alone from the start (early join): keep waiting
t ENDED:only          100 3600 1 0 0 0 300 1
t CONTINUE            100 3600 1 0 0 0 295 1
t ENDED:meeting\ page 100 3600 1 0 0 3 0   1
t CONTINUE            100 3600 1 0 0 2 0   1
t ENDED:browser       100 3600 1 3 0 0 0   1
t ENDED:max           3600 3600 1 0 0 0 0  0
t ABNORMAL:ffmpeg     100 3600 0 0 0 0 0   0
t ABNORMAL:ffmpeg     3600 3600 0 3 24 3 900 1   # ffmpeg death wins: never report a broken file as ENDED
t ABNORMAL:no\ audio  100 3600 1 0 24 0 0  0
t ENDED:only          100 3600 1 0 24 0 300 1    # silent because everyone left -> normal end, not abnormal
exit $fail
