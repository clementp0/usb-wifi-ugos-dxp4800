#!/usr/bin/env bash
# USB Wi-Fi for Ugreen NAS (UGOS) — interactive installer / toolbox.
# Run it and pick from the menu, or go straight in:  sudo bash install.sh install
#
#   git clone https://github.com/clementp0/usb-wifi-ugos-dxp4800
#   cd usb-wifi-ugos-dxp4800
#   sudo bash install.sh
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "Please run with sudo:  sudo bash install.sh" >&2; exit 1; }

HERE=$(cd "$(dirname "$0")" && pwd)
LIB=/usr/local/lib/wifi-ui
ENVF=/etc/wifi-ui.env
TOKENF=/etc/wifi-ui.token
WPACONF=/etc/wpa_supplicant/wifi-nas.conf
PORT=8088

# --- colours (disabled if not a terminal or NO_COLOR is set) ---
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    B=$'\e[1m'; DIM=$'\e[2m'; R=$'\e[0m'; CY=$'\e[36m'; GR=$'\e[32m'; YE=$'\e[33m'; RD=$'\e[31m'; INV=$'\e[7m'
else
    B=; DIM=; R=; CY=; GR=; YE=; RD=; INV=
fi
cls()  { printf '\e[H\e[2J\e[3J'; }           # clear screen, home cursor
curs() { printf '\e[?25%s' "$1"; }            # h = show, l = hide
ok()  { printf '  %s✔%s %s\n' "$GR" "$R" "$1"; }
no()  { printf '  %s✘%s %s\n' "$RD" "$R" "$1"; }
dot() { printf '  %s•%s %s\n' "$DIM" "$R" "$1"; }
cleanup() { curs h; }
trap cleanup EXIT INT TERM

# --- bilingual helper:  say "English" "Français" ---
UILANG=${UILANG:-}
say() { if [ "$UILANG" = fr ]; then printf '%s\n' "$2"; else printf '%s\n' "$1"; fi; }
sp()  { if [ "$UILANG" = fr ]; then printf '%s'   "$2"; else printf '%s'   "$1"; fi; }

banner() {
    printf '%s\n' "$CY$B"
    printf '    ┌────────────────────────────────────────────┐\n'
    printf '    │      ▁▂▃  USB Wi-Fi  ·  Ugreen NAS  ▃▂▁      │\n'
    printf '    └────────────────────────────────────────────┘\n'
    printf '%s\n' "$R"
}

# Full-screen single-choice selector. Arrow keys / numbers / Enter.
# Usage: select_menu "Title" "opt1" "opt2" ...  -> chosen index in $REPLY (-1 = quit)
select_menu() {
    local title=$1; shift
    local opts=("$@") n=$# cur=0 key k2 i
    curs l
    while :; do
        cls
        banner
        printf '  %s%s%s\n\n' "$B" "$title" "$R"
        i=0
        for o in "${opts[@]}"; do
            if [ "$i" = "$cur" ]; then
                printf '   %s %s %s  %s\n' "$CY$INV$B" "$((i + 1))" "$o $R"
            else
                printf '     %s%s%s  %s\n' "$DIM" "$((i + 1))" "$R" "$o"
            fi
            i=$((i + 1))
        done
        printf '\n  %s%s%s' "$DIM" "$(sp '↑/↓ move · Enter select · number jumps · q quit' '↑/↓ naviguer · Entrée choisir · chiffre direct · q quitter')" "$R"
        IFS= read -rsn1 key || true
        case "$key" in
            $'\e')
                read -rsn2 -t 0.1 k2 || true
                case "$k2" in '[A') cur=$(((cur - 1 + n) % n));; '[B') cur=$(((cur + 1) % n));; esac;;
            '') cur=$cur; break;;                       # Enter
            q|Q) cur=-1; break;;
            [1-9]) if [ "$key" -le "$n" ]; then cur=$((key - 1)); break; fi;;
        esac
    done
    curs h
    REPLY=$cur
}

run_action() {
    cls; "$1"
    printf '\n  %s' "$DIM"; sp 'Press Enter to return to the menu… ' 'Entrée pour revenir au menu… '; printf '%s' "$R"
    read -r _ || true
}

lan_ip()  { ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -v '^169\.254' | head -1 || true; }
wl_iface() { for n in /sys/class/net/wl*; do [ -e "$n" ] && { basename "$n"; return; }; done; }

# ----------------------------------------------------------------------------
# 1) Is a Wi-Fi adapter plugged in and working?
# ----------------------------------------------------------------------------
do_check() {
    banner
    say "  Wi-Fi adapter check" "  Vérification de la carte Wi-Fi"; echo
    local i; i=$(wl_iface || true)
    if [ -z "${i:-}" ]; then
        no "$(sp 'No Wi-Fi interface (wl*) found.' 'Aucune interface Wi-Fi (wl*) détectée.')"
        dot "$(sp 'Plug a USB dongle in, wait a few seconds, and retry.' 'Branche un dongle USB, attends quelques secondes, puis réessaie.')"
        dot "$(sp 'Use option 2 to see if its driver exists.' "Utilise l'option 2 pour voir si son pilote existe.")"
        return
    fi
    ok "$(sp 'Interface detected: ' 'Interface détectée : ')$B$i$R"
    local link ssid sig ipv svc
    link=$(iw dev "$i" link 2>/dev/null || true)
    svc=$(systemctl is-active "wifi-auto@$i.service" 2>/dev/null || true)
    ssid=$(printf '%s' "$link" | sed -n 's/.*SSID: \(.*\)/\1/p' | head -1)
    sig=$(printf '%s' "$link" | sed -n 's/.*signal: \(-\?[0-9]*\).*/\1/p' | head -1)
    ipv=$(ip -4 -o addr show "$i" 2>/dev/null | awk '{print $4}' | head -1)
    if [ -n "$ssid" ]; then
        ok "$(sp 'Connected to: ' 'Connecté à : ')$B$ssid$R${sig:+  ($sig dBm)}"
    else
        no "$(sp 'Not connected to any network yet.' 'Pas encore connecté à un réseau.')"
    fi
    [ -n "$ipv" ] && ok "$(sp 'IP address: ' 'Adresse IP : ')$B$ipv$R" \
                  || dot "$(sp 'No IP address (not associated / no DHCP).' "Pas d'adresse IP (non associé / pas de DHCP).")"
    dot "$(sp 'Auto-connect service: ' 'Service de connexion auto : ')${svc:-inactive}"
}

# ----------------------------------------------------------------------------
# 2) Drivers / firmware for the plugged USB devices.
# ----------------------------------------------------------------------------
do_drivers() {
    banner
    say "  USB adapters — driver & firmware" "  Cartes USB — pilote & firmware"; echo
    dot "$(sp 'Kernel: ' 'Noyau : ')$(uname -r)"; echo
    local any=0 d name vid pid prod drv net i
    for d in /sys/bus/usb/devices/[0-9]*-*; do
        name=$(basename "$d")
        case "$name" in *:*) continue;; esac
        [ "$(cat "$d/bDeviceClass" 2>/dev/null || true)" = 09 ] && continue   # hubs
        vid=$(cat "$d/idVendor" 2>/dev/null || true); pid=$(cat "$d/idProduct" 2>/dev/null || true)
        prod=$(cat "$d/product" 2>/dev/null || true)
        drv=""; net=""
        for i in "$d/$name:"*; do
            [ -e "$i/driver" ] && drv="$drv $(basename "$(readlink "$i/driver")")"
            [ -d "$i/net" ] && net=$(ls "$i/net" 2>/dev/null | head -1)
        done
        drv=$(printf '%s' "$drv" | xargs 2>/dev/null || true)
        any=1
        printf '  %s%s%s  %s\n' "$B" "${vid:-?}:${pid:-?}" "$R" "${prod:-$(sp 'unknown device' 'appareil inconnu')}"
        if [ -n "$net" ] && [ "${net#wl}" != "$net" ]; then
            ok "$(sp 'Wi-Fi ready, interface ' 'Wi-Fi prêt, interface ')$net ${drv:+(driver: $drv)}"
        elif [ -n "$drv" ]; then
            dot "$(sp 'Driver loaded: ' 'Pilote chargé : ')$drv $(sp '(not a Wi-Fi interface yet)' "(pas encore d'interface Wi-Fi)")"
        else
            no "$(sp 'No driver bound — likely unsupported by this kernel.' 'Aucun pilote — probablement non supporté par ce noyau.')"
        fi
    done
    [ "$any" = 1 ] || no "$(sp 'No USB devices found.' 'Aucun périphérique USB trouvé.')"
    echo
    dot "$(sp 'Full verdict (firmware too) is in the web UI adapter card.' "Le verdict complet (firmware inclus) est dans la carte « Adaptateur » de l'interface.")"
}

# ----------------------------------------------------------------------------
# 3) Which known Wi-Fi cards this kernel can already drive (driver + firmware ready).
# ----------------------------------------------------------------------------
# Curated map:  module | chipset | example USB dongles
CARDS=(
    "mt7921u|MediaTek MT7921AU (Wi-Fi 6)|BrosTrend AX9L, Comfast CF-953AX (AXE3000)"
    "mt76x2u|MediaTek MT7612U (AC1200)|Alfa AWUS036ACM, Netgear A6210"
    "mt76x0u|MediaTek MT7610U (AC600)|Panda PAU0B, Comfast CF-812AC"
    "mt7601u|MediaTek MT7601U (2.4GHz)|cheap 'MT7601' nano dongles"
    "rtw88_8822bu|Realtek RTL8822BU (AC1300)|Maxesla AC1200 (tested), TP-Link Archer T3U Plus"
    "rtw88_8821cu|Realtek RTL8811CU/8821CU (AC600)|BrosTrend AC650 (tested), Comfast CF-811AC"
    "rtl8xxxu|Realtek RTL8188/8192 CU/EU (2.4GHz)|TP-Link TL-WN823N, many nano dongles"
    "rtl8187|Realtek RTL8187 (54 Mbit/s)|Netgear WG111v3 (tested), Alfa AWUS036H"
    "rt2800usb|Ralink RT3070/RT5370 (2.4GHz)|Alfa AWUS036NH, older dongles"
    "ath9k_htc|Atheros AR9271 (2.4GHz)|Alfa AWUS036NHA, TP-Link TL-WN722N v1, Panda PAU05"
    "carl9170|Atheros AR9170 (2.4GHz)|Alfa AWUS036NHR (older)"
)

has_mod() { modinfo "$1" >/dev/null 2>&1; }
fw_state() {   # module -> none | ok | missing  (does every firmware file it needs exist?)
    local mod=$1 files f found=ok
    files=$(modinfo -F firmware "$mod" 2>/dev/null || true)
    [ -z "$files" ] && { echo none; return; }
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        [ -e "/lib/firmware/$f" ] || [ -e "/lib/firmware/$f.zst" ] || [ -e "/lib/firmware/$f.xz" ] || found=missing
    done <<EOF
$files
EOF
    echo "$found"
}

do_compatible() {
    banner
    say "  Compatible cards for this kernel" "  Cartes compatibles avec ce noyau"; echo
    dot "$(sp 'Kernel: ' 'Noyau : ')$(uname -r)"; echo
    say "  Ready to use (driver + firmware present):" "  Prêtes à l'emploi (pilote + firmware présents) :"; echo
    local entry mod chip ex fw later=""
    for entry in "${CARDS[@]}"; do
        IFS='|' read -r mod chip ex <<<"$entry"
        if ! has_mod "$mod"; then
            later="$later  $(no "$chip  $DIM[$mod: $(sp 'driver not in this kernel' 'pilote absent de ce noyau')]$R")"$'\n'
            continue
        fi
        fw=$(fw_state "$mod")
        if [ "$fw" = missing ]; then
            no "$chip  $YE$(sp 'driver OK but firmware missing' 'pilote OK mais firmware manquant')$R $DIM($mod)$R"
        else
            ok "$B$chip$R $DIM($mod)$R"
            printf '       %s%s%s\n' "$DIM" "$ex" "$R"
        fi
    done
    if [ -n "$later" ]; then
        echo; say "  Not available on this kernel:" "  Non disponibles sur ce noyau :"; echo
        printf '%s' "$later"
    fi
    echo
    dot "$(sp 'Based on modules shipped with your kernel — no guarantee, but a safe bet.' 'Basé sur les modules livrés avec ton noyau — sans garantie, mais un pari sûr.')"
}

# ----------------------------------------------------------------------------
# 4) Install everything.
# ----------------------------------------------------------------------------
do_install() {
    banner
    say "  Installing…" "  Installation…"; echo

    local PW
    if [ -f "$ENVF" ] && grep -q '^WIFI_UI_PASSWORD=.' "$ENVF"; then
        say "A UI password is already set (kept). Delete $ENVF to change it." \
            "Un mot de passe est déjà défini (conservé). Supprime $ENVF pour le changer."
        PW=$(grep '^WIFI_UI_PASSWORD=' "$ENVF" | cut -d= -f2-)
    else
        curs h
        while :; do
            read -rsp "$(sp 'Choose a password for the web UI: ' 'Choisis un mot de passe pour l'\''interface web : ')" p1; echo
            read -rsp "$(sp 'Repeat it: ' 'Répète-le : ')" p2; echo
            [ -n "$p1" ] && [ "$p1" = "$p2" ] && { PW=$p1; break; }
            say "  empty or mismatch, try again." "  vide ou différent, réessaie."
        done
    fi

    install -m 644 "$HERE/wifi-auto/wifi-auto@.service" /etc/systemd/system/wifi-auto@.service
    install -m 644 "$HERE/wifi-auto/99-wifi-auto.rules" /etc/udev/rules.d/99-wifi-auto.rules
    if [ ! -f "$WPACONF" ]; then
        install -D -m 600 "$HERE/wifi-auto/wifi-nas.conf.example" "$WPACONF"
        say "Created $WPACONF (add networks from the UI)." "Créé $WPACONF (ajoute tes réseaux depuis l'interface)."
    fi

    install -D -m 644 "$HERE/ui/wifi-ui.py" "$LIB/wifi-ui.py"
    install -D -m 644 "$HERE/ui/index.html" "$LIB/index.html"
    install -m 644 "$HERE/ui/wifi-ui.service" /etc/systemd/system/wifi-ui.service

    umask 077
    cat > "$ENVF" <<EOF
WIFI_UI_PASSWORD=$PW
WIFI_UI_HOST=0.0.0.0
WIFI_UI_SOCKET=
EOF
    chmod 600 "$ENVF"

    local TOKEN
    TOKEN=$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-24)
    printf '%s' "$TOKEN" > "$TOKENF"
    chmod 600 "$TOKENF"

    systemctl daemon-reload
    udevadm control --reload
    systemctl enable wifi-ui >/dev/null 2>&1 || true
    systemctl restart wifi-ui
    local IFACE; IFACE=$(wl_iface || true)
    [ -n "${IFACE:-}" ] && systemctl start "wifi-auto@$IFACE.service" 2>/dev/null || true

    sleep 1
    local CODE IP HOST
    CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/" || true)
    IP=$(lan_ip); HOST=$(hostname)

    echo
    printf '  %s────────────────────────────────────────────────%s\n' "$GR" "$R"
    [ "$CODE" = 200 ] && ok "$(sp 'USB Wi-Fi UI is running.' "L'interface USB Wi-Fi tourne.")" \
                      || no "$(sp "Installed, but health check = $CODE  (journalctl -u wifi-ui -n 20)" "Installé, mais health check = $CODE  (journalctl -u wifi-ui -n 20)")"
    echo
    say "  One-click first login (works once, then expires):" \
        "  Première connexion en 1 clic (valable une seule fois) :"
    [ -n "${IP:-}" ] && printf '      %shttp://%s:%s/?token=%s%s\n' "$B$CY" "$IP" "$PORT" "$TOKEN" "$R"
    echo
    say "  Or open it and sign in with your password:" \
        "  Ou ouvre-la et connecte-toi avec ton mot de passe :"
    [ -n "${IP:-}" ] && dot "http://$IP:$PORT"
    dot "http://$HOST.local:$PORT     $(sp '(name, survives IP changes)' '(nom, résiste aux changements d'\''IP)')"
    command -v qrencode >/dev/null 2>&1 && [ -n "${IP:-}" ] && { echo; qrencode -t ANSIUTF8 "http://$IP:$PORT/?token=$TOKEN"; }
    printf '  %s────────────────────────────────────────────────%s\n' "$GR" "$R"

    if command -v docker >/dev/null 2>&1; then
        echo; local a
        read -rp "$(sp 'Add a desktop icon via Docker now? [y/N] ' 'Ajouter une icône de bureau via Docker maintenant ? [o/N] ')" a || true
        case "$a" in y|Y|o|O) echo; do_docker_link;; esac
    fi
}

# ----------------------------------------------------------------------------
# 4) Uninstall.
# ----------------------------------------------------------------------------
do_uninstall() {
    banner
    say "  Uninstall" "  Désinstallation"; echo
    local all=n a
    curs h
    read -rp "$(sp 'Also remove the base Wi-Fi auto-connect service? [y/N] ' 'Retirer aussi le service de connexion Wi-Fi automatique ? [o/N] ')" a || true
    case "$a" in y|Y|o|O) all=y;; esac

    systemctl disable --now wifi-ui 2>/dev/null || true
    rm -f /etc/systemd/system/wifi-ui.service "$ENVF" "$TOKENF"
    rm -rf "$LIB"
    ok "$(sp 'Web UI removed.' 'Interface web retirée.')"

    if [ "$all" = y ]; then
        local IFACE; IFACE=$(wl_iface || true)
        [ -n "${IFACE:-}" ] && systemctl stop "wifi-auto@$IFACE.service" 2>/dev/null || true
        rm -f /etc/systemd/system/wifi-auto@.service /etc/udev/rules.d/99-wifi-auto.rules
        udevadm control --reload 2>/dev/null || true
        ok "$(sp 'Wi-Fi auto-connect service removed.' 'Service de connexion automatique retiré.')"
        dot "$(sp "Kept $WPACONF (your saved networks)." "Conservé $WPACONF (tes réseaux enregistrés).")"
    fi
    systemctl daemon-reload
}

# ----------------------------------------------------------------------------
# Desktop icon via Docker (UGOS only lets you pin a shortcut from a container).
# Volume-independent: the nginx config is generated inside the container, so it
# does not matter which volume Docker lives on — no host path is written.
# ----------------------------------------------------------------------------
do_docker_link() {
    banner
    say "  Desktop icon via Docker" "  Icône de bureau via Docker"; echo
    if ! command -v docker >/dev/null 2>&1; then
        no "$(sp 'Docker not found — install Container Manager from the UGOS App Center first.' 'Docker introuvable — installe Container Manager depuis l'\''App Center UGOS d'\''abord.')"
        return
    fi
    local HOST IP target a port=8089
    HOST=$(hostname); IP=$(lan_ip)
    say "  Pick the address the icon should open:" "  Choisis l'adresse que l'icône doit ouvrir :"; echo
    printf '    %s1%s  http://%s.local:%s   %s%s%s\n' "$B" "$R" "$HOST" "$PORT" "$DIM" "$(sp '(name — needs mDNS/Bonjour on the client)' '(nom — nécessite mDNS/Bonjour sur le client)')" "$R"
    [ -n "$IP" ] && printf '    %s2%s  http://%s:%s      %s%s%s\n' "$B" "$R" "$IP" "$PORT" "$DIM" "$(sp '(IP — most robust; changes if DHCP changes)' '(IP — le plus robuste ; change si le DHCP change)')" "$R"
    printf '\n  > '; read -r a || true
    case "$a" in 2) target="http://$IP:$PORT";; *) target="http://$HOST.local:$PORT";; esac

    curs h
    docker rm -f usbwifi-link >/dev/null 2>&1 || true
    if docker run -d --name usbwifi-link --restart unless-stopped -p "$port":80 \
        nginx:alpine sh -c "printf 'server { listen 80; location / { return 302 %s; } }' '$target' > /etc/nginx/conf.d/default.conf && exec nginx -g 'daemon off;'" >/dev/null; then
        echo; ok "$(sp 'Container ' 'Conteneur ')${B}usbwifi-link${R} $(sp 'is up on port ' 'actif sur le port ')$port  →  $target"
        echo
        say "  Now open UGOS → Docker, select 'usbwifi-link'," "  Ouvre UGOS → Docker, sélectionne « usbwifi-link »,"
        say "  and use its 'Add to desktop' option to pin the icon." "  puis son option « Ajouter au bureau » pour épingler l'icône."
    else
        echo; no "$(sp 'Could not start the container (see: docker logs usbwifi-link).' 'Impossible de démarrer le conteneur (voir : docker logs usbwifi-link).')"
    fi
}

pick_lang() {
    [ -n "$UILANG" ] && return 0
    select_menu "Language  /  Langue" "English" "Français"
    case "$REPLY" in 1) UILANG=fr;; *) UILANG=en;; esac
}

menu() {
    while :; do
        select_menu "$(sp 'Main menu' 'Menu principal')" \
            "$(sp 'Check the Wi-Fi adapter (detect + status)' 'Vérifier la carte Wi-Fi (détection + état)')" \
            "$(sp 'Show drivers / firmware (plugged devices)' 'Voir les pilotes / firmware (ce qui est branché)')" \
            "$(sp 'List compatible cards for this NAS' 'Lister les cartes compatibles avec ce NAS')" \
            "$(sp 'Install web UI' 'Installer l'\''interface web')" \
            "$(sp 'Add a desktop icon (Docker)' 'Ajouter une icône de bureau (Docker)')" \
            "$(sp 'Uninstall web UI' 'Désinstaller l'\''interface web')" \
            "$(sp 'Exit' 'Quitter')"
        case "$REPLY" in
            0) run_action do_check;;
            1) run_action do_drivers;;
            2) run_action do_compatible;;
            3) run_action do_install;;
            4) run_action do_docker_link;;
            5) run_action do_uninstall;;
            *) break;;
        esac
    done
    cls
}

# --- entry point: a subcommand runs that action; otherwise show the menu ---
case "${1:-}" in
    install)   UILANG=${UILANG:-en}; do_install;   exit 0;;
    uninstall) UILANG=${UILANG:-en}; do_uninstall; exit 0;;
    check)      UILANG=${UILANG:-en}; do_check;      exit 0;;
    drivers)    UILANG=${UILANG:-en}; do_drivers;    exit 0;;
    compatible) UILANG=${UILANG:-en}; do_compatible;  exit 0;;
    docker)     UILANG=${UILANG:-en}; do_docker_link; exit 0;;
esac

if [ -t 0 ]; then
    pick_lang
    menu
else
    UILANG=${UILANG:-en}
    do_install   # non-interactive (piped) install
fi
