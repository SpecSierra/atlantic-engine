#!/bin/bash
# Video decode bake-off harness for Atlantic Browser on-device.
# Usage: vidtest.sh "<RANK_STRING>" "<label>"
RANK="$1"; LABEL="$2"
VID="${3:-https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/1080/Big_Buck_Bunny_1080_10s_30MB.mp4}"
SSH="sshpass -p root ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 defaultuser@localhost"

echo "############ TEST: $LABEL   (rank='$RANK') ############"
$SSH "
export XDG_RUNTIME_DIR=/run/user/100000
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/100000/dbus/user_bus_socket
pkill -f 'atlantic-browser.bi[n]'; pkill -f 'WPEWebProces[s]'; pkill -x bwrap 2>/dev/null; sleep 3
export ATLANTIC_GST_PLUGIN_FEATURE_RANK='$RANK'
export GST_DEBUG='GST_ELEMENT_FACTORY:4'
export GST_DEBUG_NO_COLOR=1
export WEBKIT_INSPECTOR_HTTP_SERVER=0.0.0.0:9224
setsid /usr/bin/atlantic-browser >/tmp/vt.log 2>&1 </dev/null &
sleep 9
dbus-send --session --print-reply --dest=org.atlantic.browser.ui --type=method_call \
  /ui org.atlantic.browser.ui.openUrl array:string:'$VID' >/dev/null 2>&1
"
# poll until buffered (readyState>=3), up to ~30s
for i in $(seq 1 15); do
  sleep 2
  RS=$(python3 /root/wkinspect.py 'var v=document.querySelector("video"); v?v.readyState:-1' 2>/dev/null | grep -oE '"value":[^,]*' | grep -oE '[0-9-]+$')
  [ "$RS" = "4" ] || [ "$RS" = "3" ] && break
done
echo "readyState before play=$RS"
python3 /root/wkinspect.py 'var v=document.querySelector("video"); if(v){v.loop=true;v.muted=false;v.play();} "kick"' --gesture 2>&1 >/dev/null
sleep 6
echo "--- playback advancing? ---"
python3 /root/wkinspect.py 'var v=document.querySelector("video"); v?("t="+v.currentTime.toFixed(2)+" paused="+v.paused+" err="+(v.error?v.error.code:0)+" w="+v.videoWidth):"none"' 2>&1 | grep -E '"value"'
$SSH "
echo '--- video decoder element created ---'
grep -aE 'creating element' /tmp/vt.log | grep -aiE '\"(avdec_h264|v4l2[a-z0-9]*dec|v4l2sl[a-z0-9]*dec|droidvdec|vp9dec|vp8dec|vah264dec)\"' | grep -aviE 'iVBOR|base64' | sort -u | tail -8
echo '--- media errors / crashes ---'
grep -aiE 'not-negotiated|no suitable|error.*decod|received signal SIG|segfault|web-process.*crash' /tmp/vt.log | grep -aviE 'iVBOR' | tail -5
echo '--- WebProcess CPU%% (raw top lines, 3 samples) ---'
for n in 1 2 3; do top -bn1 2>/dev/null | grep -aE 'WPEWebProcess [0-9]+ [0-9]+\$' | head -2; sleep 1; done
"
echo "############ END $LABEL ############"; echo