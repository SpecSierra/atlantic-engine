#!/bin/bash
# arm.sh <tag> [--env K=V ...] — full fresh arm: relaunch, fullscreen, 1080p, 2x20s capture
set -u
TAG="$1"; shift
D=/root/handover/video-harness
SSH="sshpass -p root ssh -4 -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null defaultuser@localhost"
A=~/atldbg

timeout 250 $D/fsrun.sh "$@" >/dev/null 2>&1
# kick playback + 1080p with a real touch gesture
timeout 120 $A eval 'var v=document.querySelector("video");var p=document.getElementById("movie_player");document.addEventListener("touchend",function h(e){document.removeEventListener("touchend",h,true);v.play();p.setPlaybackQualityRange&&p.setPlaybackQualityRange("hd1080","hd1080")},true);"armed"' >/dev/null 2>&1
$SSH 'echo root | devel-su -p python3 /home/defaultuser/tap.py 1019 700' >/dev/null 2>&1
sleep 12
echo "--- $TAG state ---"
timeout 120 $A eval 'var v=document.querySelector("video");JSON.stringify({fs:!!document.webkitFullscreenElement,res:v.videoWidth+"x"+v.videoHeight,paused:v.paused,t:Math.round(v.currentTime)})' 2>&1 | grep '"value"'
sleep 15
for i in 1 2; do
  echo "--- $TAG run$i ---"
  $D/cap.sh "$D/$TAG.$i.log" 20
  $SSH 'for p in $(pgrep -f "WPEWebProces[s]"); do printf "rss %s MB  " $(( $(grep VmRSS /proc/$p/status|tr -dc 0-9)/1024 )); done; echo' 2>/dev/null | tail -1
done
