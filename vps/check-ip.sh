#!/bin/bash
echo '=== IP Quality Check ==='
PROXY="socks5h://6458952-bcc9e8fa:c51094ec-US-32987325-2m@gate-sea.kookeey.info:1000"
RESULT=$(curl -x $PROXY -s --max-time 10 'http://ip-api.com/json?fields=status,country,regionName,city,isp,org,as,proxy,hosting,mobile,query')
echo "$RESULT" | python3 -m json.tool
IP=$(echo "$RESULT" | python3 -c "import sys,json;print(json.load(sys.stdin)['query'])" 2>/dev/null)
echo ''
echo "=== Scamalytics (手动浏览器打开) ==="
echo "https://scamalytics.com/ip/$IP"
echo ''
PROXY_FLAG=$(echo "$RESULT" | python3 -c "import sys,json;d=json.load(sys.stdin);print('PASS' if not d['proxy'] and not d['hosting'] else 'FAIL')" 2>/dev/null)
echo "ISP Check: $PROXY_FLAG"
