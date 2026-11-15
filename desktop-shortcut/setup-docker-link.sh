#!/usr/bin/env bash
# Creates a tiny redirect container so the UGOS Docker app can pin a desktop icon
# that opens the local Wi-Fi UI. The icon only works on the LAN (it redirects to a
# local address that is not reachable through UGREENlink).
#
# Volume-independent: the nginx config is generated inside the container, so it does
# not matter which volume Docker lives on — nothing is written to the host.
#
#   sudo bash setup-docker-link.sh [target-host] [listen-port]
#   e.g.  sudo bash setup-docker-link.sh DXP4800PLUS.local 8089
#         sudo bash setup-docker-link.sh 192.168.1.126 8089
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "Run with sudo" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "docker not found (install Container Manager first)" >&2; exit 1; }

HOSTN=${1:-$(hostname).local}
PORT=${2:-8089}
TARGET="http://$HOSTN:8088"

docker rm -f usbwifi-link >/dev/null 2>&1 || true
docker run -d --name usbwifi-link --restart unless-stopped -p "$PORT":80 \
    nginx:alpine sh -c "printf 'server { listen 80; location / { return 302 %s; } }' '$TARGET' > /etc/nginx/conf.d/default.conf && exec nginx -g 'daemon off;'"

echo
echo "Container 'usbwifi-link' is up on port $PORT, redirecting to $TARGET"
echo "Now open UGOS > Docker, select 'usbwifi-link', and use its"
echo "'Add to desktop' / shortcut option to put the icon on the home screen."
