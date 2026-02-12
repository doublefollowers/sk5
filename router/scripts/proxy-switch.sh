#!/bin/sh
# proxy-switch: switch between mux (video) and vision (registration)
# Usage: proxy-switch mux | proxy-switch vision

VPS="139.180.136.97"
MODE="$1"

if [ "$MODE" = "vision" ]; then
    echo "[*] Switching to VISION mode (registration: Vision + 5 SNI)"
    # VPS: stop sing-box, start xray
    ssh root@$VPS "systemctl stop sing-box; systemctl start xray" 2>/dev/null
    # Router: use vision config
    cp /etc/sing-box/config-vision.json /etc/sing-box/config.json
    # Restart sing-box
    kill $(ps | grep "sing-box run" | grep -v grep | head -1 | tr -s " " | cut -d" " -f2) 2>/dev/null
    sleep 2
    rm -f /tmp/sing-box-cache.db
    ulimit -n 65535
    nohup sing-box run -c /etc/sing-box/config.json > /var/log/sing-box.log 2>&1 &
    sleep 2
    echo "[OK] VISION mode active"
    echo "     VPS: Xray (Vision + 5 SNI rotation)"
    echo "     Router: VLESS + Reality + Vision"

elif [ "$MODE" = "mux" ]; then
    echo "[*] Switching to MUX mode (video: h2mux multiplex)"
    # VPS: stop xray, start sing-box
    ssh root@$VPS "systemctl stop xray; systemctl start sing-box" 2>/dev/null
    # Router: use mux config
    cp /etc/sing-box/config-mux.json /etc/sing-box/config.json
    # Restart sing-box
    kill $(ps | grep "sing-box run" | grep -v grep | head -1 | tr -s " " | cut -d" " -f2) 2>/dev/null
    sleep 2
    rm -f /tmp/sing-box-cache.db
    ulimit -n 65535
    nohup sing-box run -c /etc/sing-box/config.json > /var/log/sing-box.log 2>&1 &
    sleep 2
    echo "[OK] MUX mode active"
    echo "     VPS: sing-box (multiplex support)"
    echo "     Router: VLESS + Reality + h2mux"

else
    echo "Usage: proxy-switch <mux|vision>"
    echo "  mux    - Video mode (h2mux multiplex, fast)"
    echo "  vision - Registration mode (Vision + 5 SNI, secure)"
fi
