#!/bin/bash
# rssslope.sh <quality> <seconds> — set YT quality, then sample WebProcess RSS
Q="$1"; S="${2:-60}"
A=~/atldbg
SSH="sshpass -p root ssh -4 -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null defaultuser@localhost"
timeout 120 $A eval "var p=document.getElementById('movie_player');p.setPlaybackQualityRange('$Q','$Q');p.setPlaybackQuality&&p.setPlaybackQuality('$Q');'q=$Q'" >/dev/null 2>&1
sleep 8
timeout 120 $A eval "var v=document.querySelector('video');'res='+v.videoWidth+'x'+v.videoHeight+' paused='+v.paused" 2>&1 | grep '"value"'
$SSH "P=\$(pgrep -f 'WPEWebProces[s]'|tail -1); for i in \$(seq 1 $((S/10))); do echo \"t=\$((i*10))s rss=\$(( \$(grep VmRSS /proc/\$P/status|tr -dc 0-9)/1024 ))MB\"; sleep 10; done" 2>/dev/null | tail -20
