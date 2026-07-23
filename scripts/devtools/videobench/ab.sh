#!/bin/bash
# ab.sh — interleaved A/B: default 700MB memory-pressure threshold vs 2400MB
# Each arm: fresh launch, YT 1080p fullscreen, 30s settle, 2x20s frame-trace capture + RSS series.
D=/root/handover/video-harness
SSH="sshpass -p root ssh -4 -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null defaultuser@localhost"

run_arm() {
  tag="$1"; shift
  echo "############ $tag ############"
  timeout 300 $D/fsrun.sh "$@" >/dev/null 2>&1
  $D/ensure_play.sh | tail -1
  # force 1080p once more, then settle
  timeout 120 ~/atldbg eval "var p=document.getElementById('movie_player');p.setPlaybackQualityRange('hd1080','hd1080');'q'" >/dev/null 2>&1
  sleep 30
  timeout 120 ~/atldbg eval "var v=document.querySelector('video');'res='+v.videoWidth+'x'+v.videoHeight+' paused='+v.paused" 2>&1 | grep -o 'res=[^"]*'
  for i in 1 2; do
    $D/cap.sh "$D/ab.$tag.$i.log" 20
    $SSH 'P=$(pgrep -f "WPEWebProces[s]"|tail -1); echo "   rss=$(( $(grep VmRSS /proc/$P/status|tr -dc 0-9)/1024 ))MB"' 2>/dev/null | tail -1
  done
}

for round in 1 2; do
  run_arm "A$round" --env ATLANTIC_FRAME_TRACE=1
  run_arm "B$round" --env ATLANTIC_FRAME_TRACE=1 --env WEBKIT_MEMORY_BASE_THRESHOLD_MB=2400
done
