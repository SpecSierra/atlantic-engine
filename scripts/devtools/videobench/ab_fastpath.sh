#!/bin/bash
# ab_fastpath.sh — interleaved 5x5 A/B of WEBKIT_COMPOSITE_SKIP_LOCKED_LAYERS
# A = stock (flag off), B = fast path (flag on). Fresh launch per arm, YT 1080p
# fullscreen, 25 s settle, one 20 s ATLANTIC_FRAME_TRACE window.
D=/root/handover/video-harness
SSH="sshpass -p root ssh -4 -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null defaultuser@localhost"

assert_link() {
  # A dropped reverse tunnel silently turns every later arm into garbage; abort instead.
  timeout 25 $SSH 'echo LINK_OK' 2>/dev/null | grep -q LINK_OK || {
    echo "!!! tunnel down before $1 — aborting run"; exit 1; }
}

run_arm() {
  tag="$1"; shift
  assert_link "$tag"
  echo "######## $tag ########"
  timeout 300 $D/fsrun.sh "$@" >/dev/null 2>&1
  $D/ensure_play.sh | tail -1
  timeout 120 ~/atldbg eval "var p=document.getElementById('movie_player');p.setPlaybackQualityRange('hd1080','hd1080');'q'" >/dev/null 2>&1
  sleep 25
  timeout 120 ~/atldbg eval "var v=document.querySelector('video');'res='+v.videoWidth+'x'+v.videoHeight+' paused='+v.paused" 2>&1 | grep -o 'res=[^"]*'
  $D/cap.sh "$D/fp.$tag.log" 20
  $SSH 'P=$(pgrep -f "WPEWebProces[s]"|tail -1); echo "   rss=$(( $(grep VmRSS /proc/$P/status|tr -dc 0-9)/1024 ))MB"' 2>/dev/null | tail -1
}

for r in 1 2 3 4 5; do
  run_arm "A$r" --env ATLANTIC_FRAME_TRACE=1
  run_arm "B$r" --env ATLANTIC_FRAME_TRACE=1 --env WEBKIT_COMPOSITE_SKIP_LOCKED_LAYERS=1
done
