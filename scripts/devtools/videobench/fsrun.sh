#!/bin/bash
# fsrun.sh [--env K=V ...] — relaunch browser on a YT video, force 1080p, enter fullscreen.
set -u
A=~/atldbg
ENVS=()
while [ "${1:-}" = "--env" ]; do ENVS+=(--env "$2"); shift 2; done
URL="${1:-https://m.youtube.com/watch?v=Jm0MLlE4x0U}"

timeout 200 $A launch "${ENVS[@]}" "$URL" 2>&1 | tail -3
sleep 12
# force H.264 1080p
timeout 120 $A eval "var p=document.getElementById('movie_player');p&&p.setPlaybackQualityRange&&p.setPlaybackQualityRange('hd1080','hd1080');var v=document.querySelector('video');v&&v.play();(v?v.videoWidth+'x'+v.videoHeight:'no-video')" 2>&1 | grep '"value"'
sleep 5
# arm gesture-driven fullscreen, then synthesize a real touch
timeout 120 $A eval "document.addEventListener('touchend',function h(e){document.removeEventListener('touchend',h,true);var p=document.getElementById('movie_player');try{(p.requestFullscreen||p.webkitRequestFullscreen).call(p)}catch(x){}},true);'armed'" 2>&1 | grep '"value"'
sshpass -p root ssh -4 -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null defaultuser@localhost \
  'echo root | devel-su -p python3 /home/defaultuser/tap.py 1019 700' >/dev/null 2>&1
sleep 4
timeout 120 $A eval "var v=document.querySelector('video');JSON.stringify({fs:!!document.webkitFullscreenElement,res:v.videoWidth+'x'+v.videoHeight,paused:v.paused,t:Math.round(v.currentTime)})" 2>&1 | grep '"value"'
