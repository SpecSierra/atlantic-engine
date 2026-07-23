#!/bin/bash
SSH="sshpass -p root ssh -4 -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null defaultuser@localhost"
A=~/atldbg
for i in 1 2 3; do
  st=$(timeout 120 $A eval 'var v=document.querySelector("video");v.paused?"paused":"playing:"+v.videoWidth' 2>&1 | grep -o 'paused\|playing:[0-9]*')
  echo "attempt$i: $st"
  case "$st" in playing:1920) exit 0;; esac
  timeout 120 $A eval 'var v=document.querySelector("video");var p=document.getElementById("movie_player");document.addEventListener("touchend",function h(e){document.removeEventListener("touchend",h,true);if(v.paused)v.play();p.setPlaybackQualityRange&&p.setPlaybackQualityRange("hd1080","hd1080")},true);"armed"' >/dev/null 2>&1
  $SSH 'echo root | devel-su -p python3 /home/defaultuser/tap.py 1019 700' >/dev/null 2>&1
  sleep 8
done
timeout 120 $A eval 'var v=document.querySelector("video");JSON.stringify({paused:v.paused,res:v.videoWidth+"x"+v.videoHeight,fs:!!document.webkitFullscreenElement})' 2>&1 | grep '"value"'
