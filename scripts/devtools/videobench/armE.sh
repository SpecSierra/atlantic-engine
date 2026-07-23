#!/bin/bash
D=/root/handover/video-harness
SSH="sshpass -p root ssh -4 -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null defaultuser@localhost"
tag="$1"; shift
echo "######## $tag ########"
timeout 300 $D/fsrun.sh "$@" >/dev/null 2>&1
$D/ensure_play.sh | tail -1
timeout 120 ~/atldbg eval "var p=document.getElementById('movie_player');p.setPlaybackQualityRange('hd1080','hd1080');'q'" >/dev/null 2>&1
sleep 30
timeout 120 ~/atldbg eval "var v=document.querySelector('video');'res='+v.videoWidth+'x'+v.videoHeight+' paused='+v.paused" 2>&1 | grep -o 'res=[^"]*'
for i in 1 2; do
  $D/cap.sh "$D/$tag.$i.log" 20
  $SSH 'P=$(pgrep -f "WPEWebProces[s]"|tail -1); echo "   rss=$(( $(grep VmRSS /proc/$P/status|tr -dc 0-9)/1024 ))MB"' 2>/dev/null | tail -1
done
