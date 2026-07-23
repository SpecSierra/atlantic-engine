#!/bin/bash
# vbench.sh <quality> <window_s>  — measure presented-frame cadence of the playing <video>
# Requires: page already in fullscreen, video playing.
Q="${1:-hd1080}"
W="${2:-15}"
A=~/atldbg

timeout 120 $A eval "var p=document.getElementById('movie_player');p.setPlaybackQualityRange&&p.setPlaybackQualityRange('$Q','$Q');p.setPlaybackQuality&&p.setPlaybackQuality('$Q');'q'" >/dev/null 2>&1
sleep 6
timeout 120 $A eval "var v=document.querySelector('video');window.__rv=[];window.__t0=performance.now();var f=function(now,md){window.__rv.push([md.presentationTime,md.presentedFrames,md.mediaTime]);v.requestVideoFrameCallback(f)};v.requestVideoFrameCallback(f);window.__raf=[];var g=function(t){window.__raf.push(t);requestAnimationFrame(g)};requestAnimationFrame(g);'armed '+v.videoWidth+'x'+v.videoHeight" 2>&1 | grep '"value"'
sleep "$W"
timeout 120 $A eval "var a=window.__rv,r=window.__raf,v=document.querySelector('video');
var d=[];for(var i=1;i<a.length;i++)d.push(a[i][0]-a[i-1][0]);d.sort(function(x,y){return x-y});
var rd=[];for(var i=1;i<r.length;i++)rd.push(r[i]-r[i-1]);rd.sort(function(x,y){return x-y});
var n=d.length,span=a.length>1?(a[a.length-1][0]-a[0][0])/1000:0;
var pf=a.length>1?a[a.length-1][1]-a[0][1]:0, ms=a.length>1?a[a.length-1][2]-a[0][2]:0;
JSON.stringify({res:v.videoWidth+'x'+v.videoHeight,span_s:Math.round(span*10)/10,
 presented_fps:span?Math.round(pf/span*10)/10:0, media_fps:ms?Math.round(pf/ms*10)/10:0,
 media_advance:Math.round(ms*10)/10, cb_fps:span?Math.round(n/span*10)/10:0,
 cb_p50:Math.round(d[(n*0.5)|0]), cb_p95:Math.round(d[(n*0.95)|0]), cb_max:Math.round(d[n-1]),
 raf_p50:Math.round(rd[(rd.length*0.5)|0]), raf_p95:Math.round(rd[(rd.length*0.95)|0]),
 dropped:v.webkitDroppedFrameCount})" 2>&1 | grep '"value"'
