# UGOS · USB Wi-Fi for Ugreen NAS

Check whether a USB Wi-Fi dongle works on a Ugreen NAS (UGOS Pro), and which chipsets your kernel can already drive — before you buy one.

**[Connecting](#connecting-to-wi-fi)** · **[Run the check](#run-the-check)** · **[Compatibility](#compatibility-kernel-61815-ugos-pro--debian-12)**

> Status: Tested on a DXP4800 Plus, UGOS Pro / Debian 12, kernel 6.18.15.

## Connecting to Wi-Fi

UGOS Pro handles USB Wi-Fi dongles natively: plug the dongle in, then go to **Settings → Network → Wi-Fi**. The connection comes back on its own after a reboot.

This repo installs nothing and runs no service: it only tells you whether a dongle is recognised (driver + firmware) and which ones are worth buying.

## Run the check

On the NAS, over SSH (no `git` needed, uses `curl`):

```bash
curl -fsSL https://github.com/clementp0/usb-wifi-ugos-dxp4800/archive/refs/heads/main.tar.gz | tar xz && bash usb-wifi-ugos-dxp4800-main/check.sh
```

This opens an interactive menu (English / French):

```
  1  Check the Wi-Fi adapter (detect + status)
  2  Show drivers / firmware (plugged devices)
  3  List compatible cards for this NAS
  4  Exit
```

- **1** — is a `wl*` interface present, is it connected (SSID, signal, IP), and is the UGOS Wi-Fi service running.
- **2** — every plugged USB device with its driver and whether the firmware it needs is present.
- **3** — the known USB Wi-Fi chipsets, split into "ready on this kernel" and "not available".

Navigate with ↑/↓ and Enter, or press the number directly. Each action also runs non-interactively: `bash check.sh check | drivers | compatible`. Read-only, no `sudo` needed; delete the folder when you're done.

## Compatibility (kernel 6.18.15, UGOS Pro / Debian 12)

Run menu option **3** ("List compatible cards for this NAS") to see which of these your kernel can drive right now, and option **2** to see which driver a plugged dongle actually uses.

### Tested on a DXP4800 Plus

| Dongle | Chipset | Driver | Result |
| --- | --- | --- | --- |
| Maxesla AC1200 (USB 3.0) | Realtek RTL8822BU | `rtw88_8822bu` | Pretty good; transfers hold up well even at long range. |
| BrosTrend AC650 (AC1L) | Realtek RTL8811CU | `rtw88_8821cu` | Not the fastest, but fine for streaming films. |
| Netgear WG111v3 | Realtek RTL8187 | `rtl8187` | Works, very slow. OK for light read/write only. Monitor mode works |

Got another dongle working (or not)? Open an issue with the output of menu option **2**.

### Kernel-ready, not yet tested here

These chipsets have an in-kernel driver (and firmware) on UGOS Pro 6.18.15, so they *should* work without building anything:

| Chipset | Driver | Example dongles | Notes |
| --- | --- | --- | --- |
| MediaTek MT7921AU (Wi-Fi 6, AXE3000) | `mt7921u` | BrosTrend AX9L, Comfast CF-953AX | best candidate for speed |
| MediaTek MT7612U (AC1200) | `mt76x2u` | Alfa AWUS036ACM, Netgear A6210 | very solid Linux driver |
| Realtek RTL8822BU (AC1300) | `rtw88_8822bu` | TP-Link Archer T3U Plus, D-Link DWA-181 | same driver as the Maxesla AC1200 |
| MediaTek MT7610U (AC600) | `mt76x0u` | Panda PAU0B, Comfast CF-812AC | reported working but slow (Reddit) |
| Realtek RTL8811CU/8821CU (AC600) | `rtw88_8821cu` | Comfast CF-811AC | same driver as the BrosTrend AC650 |
| MediaTek MT7601U (2.4 GHz) | `mt7601u` | cheap "MT7601" nano dongles | |
| Realtek RTL8188/8192 CU/EU (2.4 GHz) | `rtl8xxxu` | TP-Link TL-WN823N, many nano dongles | |
| Ralink RT3070/RT5370 (2.4 GHz) | `rt2800usb` | Alfa AWUS036NH | |
| Atheros AR9271 (2.4 GHz) | `ath9k_htc` | Alfa AWUS036NHA, TP-Link TL-WN722N v1, Panda PAU05 | |
| Atheros AR9170 (2.4 GHz) | `carl9170` | Alfa AWUS036NHR (older) | |

⚠️ Dongles often change chipset between hardware revisions (v1/v2/v3…) — check the exact chipset of the revision you buy.

Check your own kernel before buying:

```bash
ls /lib/modules/$(uname -r)/kernel/drivers/net/wireless/{mediatek/mt76,realtek,ath}/
```

---

*Unofficial, community-made. Undocumented UGOS internals may change with updates. Proceed at your own risk.*
