#!/usr/bin/env bash
# Removes the web UI (and, with --all, the base Wi-Fi auto-connect service too).
# Thin wrapper around the installer's uninstall action, so the logic lives in one place.
#
#   sudo bash uninstall.sh          # remove the web UI only
#   sudo bash uninstall.sh --all    # also remove the Wi-Fi auto-connect service
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "Please run with sudo:  sudo bash uninstall.sh" >&2; exit 1; }

HERE=$(cd "$(dirname "$0")" && pwd)
case "${1:-}" in
    --all|-a) printf 'y\n' | UILANG="${UILANG:-en}" bash "$HERE/install.sh" uninstall;;
    *)        printf 'n\n' | UILANG="${UILANG:-en}" bash "$HERE/install.sh" uninstall;;
esac
