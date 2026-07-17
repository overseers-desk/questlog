#!/bin/bash
# Measure wall-clock time from questlog launch to the first visible row in
# the streamtree, on a private Xvfb display (never the real :0; see the
# project CLAUDE.md on GUI verification).
#
# Method: a screenshot poller names each frame by the absolute wall clock,
# the launch moment is logged to t0, and a withdrawn wish pings the app's
# event loop every 100ms. First-row time is read off the frames, not from
# any in-app timer. At the end this script prints the frame-change timeline
# (offset from t0, PNG size) and the slow ping round-trips; confirm the
# first-row frame by eye.
#
# Usage: ./measure.sh [outdir]     # outdir defaults to a fresh /tmp dir
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
QL="$HERE/../../questlog"
DIR="${1:-$(mktemp -d /tmp/ql-startup-XXXX)}"
DISP=":99"
OBSERVE_SECS=40

mkdir -p "$DIR"
rm -f "$DIR"/f_*.png "$DIR"/t0 "$DIR"/*.log

Xvfb "$DISP" -screen 0 1500x1150x24 >"$DIR/xvfb.log" 2>&1 &
XVFB=$!
sleep 2

(
  while :; do
    t=$(date +%s.%N)
    DISPLAY=$DISP import -window root "$DIR/f_$t.png" 2>/dev/null
  done
) &
POLLER=$!

PING_LOG="$DIR/ping.log" DISPLAY=$DISP wish9.0 "$HERE/pinger.tcl" >"$DIR/pinger.err" 2>&1 &
PINGER=$!
sleep 1

date +%s.%N > "$DIR/t0"
DISPLAY=$DISP "$QL" >"$DIR/ql.log" 2>&1 &
APP=$!

sleep "$OBSERVE_SECS"

kill $POLLER $PINGER 2>/dev/null
wait $POLLER 2>/dev/null
kill $APP 2>/dev/null
kill $XVFB 2>/dev/null

T0=$(cat "$DIR/t0")
echo "run dir: $DIR   frames: $(ls "$DIR"/f_*.png | wc -l)"
echo "---- frame-change timeline (s after launch, png bytes) ----"
prev=""
for f in $(ls "$DIR"/f_*.png | sort); do
  ts=${f##*/f_}; ts=${ts%.png}
  sz=$(stat -c%s "$f")
  if [ "$sz" != "$prev" ]; then
    printf "%8.2f %9d %s\n" "$(echo "$ts - $T0" | bc)" "$sz" "$f"
    prev=$sz
  fi
done | head -25
echo "---- ping round-trips over 150ms (s after launch, rtt ms) ----"
T0MS=$(echo "$T0 * 1000" | bc | cut -d. -f1)
awk -v t0="$T0MS" '$3 > 150 {printf "%8.2f %6dms ok=%d\n", ($1-t0)/1000, $3, $4}' "$DIR/ping.log"
