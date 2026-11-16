#!/usr/bin/env bash
# USB Wi-Fi for Ugreen NAS (UGOS) — read-only diagnostic toolbox.
# UGOS Pro connects USB Wi-Fi dongles itself (Settings → Network → Wi-Fi); this
# script only tells you whether a dongle is recognised and which chipsets your
# kernel can drive. It installs nothing and changes nothing.
#
#   bash check.sh                      # interactive menu (EN / FR)
#   bash check.sh check | drivers | compatible
set -euo pipefail

# modinfo / iw live in /usr/sbin, which is not in a normal user's PATH on Debian.
PATH="$PATH:/usr/sbin:/sbin"

# --- colours (disabled if not a terminal or NO_COLOR is set) ---
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    B=$'\e[1m'; DIM=$'\e[2m'; R=$'\e[0m'; CY=$'\e[36m'; GR=$'\e[32m'; YE=$'\e[33m'; RD=$'\e[31m'; INV=$'\e[7m'
else
    B=; DIM=; R=; CY=; GR=; YE=; RD=; INV=
fi
cls()  { printf '\e[H\e[2J\e[3J'; }           # clear screen, home cursor
curs() { [ -t 1 ] && printf '\e[?25%s' "$1"; return 0; }   # h = show, l = hide
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

wl_iface() { for n in /sys/class/net/wl*; do [ -e "$n" ] && { basename "$n"; return; }; done; }

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

# ----------------------------------------------------------------------------
# 1) Is a Wi-Fi adapter plugged in, and is UGOS using it?
# ----------------------------------------------------------------------------
do_check() {
    banner
    say "  Wi-Fi adapter check" "  Vérification de la carte Wi-Fi"; echo
    local i; i=$(wl_iface || true)
    if [ -z "${i:-}" ]; then
        no "$(sp 'No Wi-Fi interface (wl*) found.' 'Aucune interface Wi-Fi (wl*) détectée.')"
        dot "$(sp 'Plug a USB dongle in, wait a few seconds, and retry.' 'Branche un dongle USB, attends quelques secondes, puis réessaie.')"
        dot "$(sp 'Use option 2 to see whether its driver loaded.' "Utilise l'option 2 pour voir si son pilote s'est chargé.")"
        return 0
    fi
    ok "$(sp 'Interface detected: ' 'Interface détectée : ')$B$i$R"
    local link ssid sig ipv svc
    link=$(iw dev "$i" link 2>/dev/null || true)
    svc=$(systemctl is-active "wpa_supplicant@$i.service" 2>/dev/null || true)
    ssid=$(printf '%s' "$link" | sed -n 's/.*SSID: \(.*\)/\1/p' | head -1)
    sig=$(printf '%s' "$link" | sed -n 's/.*signal: \(-\?[0-9]*\).*/\1/p' | head -1)
    ipv=$(ip -4 -o addr show "$i" 2>/dev/null | awk '{print $4}' | head -1)
    if [ -n "$ssid" ]; then
        ok "$(sp 'Connected to: ' 'Connecté à : ')$B$ssid$R${sig:+  ($sig dBm)}"
    else
        no "$(sp 'Not connected to any network.' 'Connecté à aucun réseau.')"
    fi
    if [ -n "$ipv" ]; then
        ok "$(sp 'IP address: ' 'Adresse IP : ')$B$ipv$R"
    else
        dot "$(sp 'No IP address (not associated / no DHCP).' "Pas d'adresse IP (non associé / pas de DHCP).")"
    fi
    dot "$(sp 'UGOS Wi-Fi service ' 'Service Wi-Fi UGOS ')(wpa_supplicant@$i): ${svc:-inactive}"
    if [ -z "$ssid" ]; then
        echo
        dot "$(sp 'To connect: UGOS → Settings → Network → Wi-Fi.' 'Pour te connecter : UGOS → Réglages → Réseau → Wi-Fi.')"
    fi
    return 0
}

# ----------------------------------------------------------------------------
# 2) Drivers / firmware for the plugged USB devices.
# ----------------------------------------------------------------------------
do_drivers() {
    banner
    say "  USB adapters — driver & firmware" "  Cartes USB — pilote & firmware"; echo
    dot "$(sp 'Kernel: ' 'Noyau : ')$(uname -r)"; echo
    local any=0 d name vid pid prod drv net i m fw
    for d in /sys/bus/usb/devices/[0-9]*-*; do
        [ -e "$d" ] || continue
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
        drv=$(printf '%s' "$drv" | xargs -n1 2>/dev/null | sort -u | xargs 2>/dev/null || true)
        any=1
        printf '  %s%s%s  %s\n' "$B" "${vid:-?}:${pid:-?}" "$R" "${prod:-$(sp 'unknown device' 'appareil inconnu')}"
        if [ -n "$net" ] && [ "${net#wl}" != "$net" ]; then
            ok "$(sp 'Wi-Fi ready, interface ' 'Wi-Fi prêt, interface ')$net ${drv:+($(sp 'driver' 'pilote'): $drv)}"
            for m in $drv; do
                fw=$(fw_state "$m")
                case "$fw" in
                    ok)      ok "$(sp 'Firmware present' 'Firmware présent') ($m)";;
                    missing) no "$(sp 'Firmware missing' 'Firmware manquant') ($m)";;
                esac
            done
        elif [ -n "$drv" ]; then
            dot "$(sp 'Driver loaded: ' 'Pilote chargé : ')$drv $(sp '(not a Wi-Fi interface)' "(pas d'interface Wi-Fi)")"
        else
            no "$(sp 'No driver bound — likely unsupported by this kernel.' 'Aucun pilote — probablement non supporté par ce noyau.')"
        fi
    done
    [ "$any" = 1 ] || no "$(sp 'No USB devices found.' 'Aucun périphérique USB trouvé.')"
    return 0
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

do_compatible() {
    banner
    say "  Compatible cards for this kernel" "  Cartes compatibles avec ce noyau"; echo
    dot "$(sp 'Kernel: ' 'Noyau : ')$(uname -r)"; echo
    say "  Ready to use (driver + firmware present):" "  Prêtes à l'emploi (pilote + firmware présents) :"; echo
    local entry mod chip ex fw later=""
    for entry in "${CARDS[@]}"; do
        IFS='|' read -r mod chip ex <<<"$entry"
        if ! has_mod "$mod"; then
            later="$later$(no "$chip  $DIM[$mod: $(sp 'driver not in this kernel' 'pilote absent de ce noyau')]$R")"$'\n'
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
    return 0
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
            "$(sp 'Exit' 'Quitter')"
        case "$REPLY" in
            0) run_action do_check;;
            1) run_action do_drivers;;
            2) run_action do_compatible;;
            *) break;;
        esac
    done
    cls
}

# --- entry point: a subcommand runs that action; otherwise show the menu ---
case "${1:-}" in
    check)      UILANG=${UILANG:-en}; do_check;      exit 0;;
    drivers)    UILANG=${UILANG:-en}; do_drivers;    exit 0;;
    compatible) UILANG=${UILANG:-en}; do_compatible; exit 0;;
    "") ;;
    *) echo "Usage: bash check.sh [check | drivers | compatible]" >&2; exit 1;;
esac

if [ -t 0 ]; then
    pick_lang
    menu
else
    UILANG=${UILANG:-en}
    do_check; echo; do_drivers; echo; do_compatible
fi
