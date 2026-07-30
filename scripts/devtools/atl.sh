#!/bin/bash
SSH='sshpass -p root ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null defaultuser@localhost'
ENV='export XDG_RUNTIME_DIR=/run/user/100000; export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/100000/dbus/user_bus_socket;'

case "$1" in
  restart)
    $SSH "$ENV pkill -f 'atlantic-browser.bi[n]'; pkill -f 'WPEWebProces[s]'; pkill -x bwrap; sleep 2; setsid /usr/bin/atlantic-browser >/tmp/atl.log 2>&1 </dev/null &"
    ;;
  open)
    $SSH "$ENV dbus-send --session --print-reply --dest=org.atlantic.browser.ui --type=method_call /ui org.atlantic.browser.ui.openUrl array:string:\"$2\""
    ;;
  shot)
    # Unique filename per shot: lipstick's saveScreenshot refuses to overwrite an
    # existing file AND writes it asynchronously (the D-Bus reply arrives before the
    # PNG is flushed), so a fixed name + immediate scp races and silently pulls the
    # previous frame. Fresh name + poll-until-stable avoids both traps.
    REMOTE="/home/defaultuser/ss_$(date +%s%N).png"
    $SSH "$ENV echo root | devel-su -p dbus-send --session --print-reply --dest=org.nemomobile.lipstick /org/nemomobile/lipstick/screenshot org.nemomobile.lipstick.saveScreenshot string:$REMOTE >/dev/null
          for i in \$(seq 1 30); do s1=\$(stat -c%s $REMOTE 2>/dev/null || echo 0); sleep 0.2; s2=\$(stat -c%s $REMOTE 2>/dev/null || echo 0); [ \"\$s1\" != 0 ] && [ \"\$s1\" = \"\$s2\" ] && break; done
          echo root | devel-su -p chmod 644 $REMOTE 2>/dev/null"
    sshpass -p root scp -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "defaultuser@localhost:$REMOTE" "${2:-/root/cur.png}"
    $SSH "rm -f $REMOTE"
    ;;
  push)
    sshpass -p root scp -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$2" defaultuser@localhost:/tmp/Background.qml
    $SSH "echo root | devel-su cp /tmp/Background.qml /usr/share/atlantic-browser/shared/Background.qml"
    ;;
  log) $SSH "$ENV tail -n 40 /tmp/atl.log" ;;
esac
