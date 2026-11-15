## Web UI — manual setup & options

A small white web page to see the Wi-Fi status and manage saved networks, without SSH.
The easy way to install it is the menu at the repo root (`sudo bash install.sh` → **Install web UI**).
This page documents the manual steps and the configuration options.

- **Two files, no dependencies**: `wifi-ui.py` + `index.html`, Python standard library only (Debian 12 ships `python3`).
- **Shows**: connection (SSID, signal, band, speed, IP), nearby networks (auto-refreshed), the plugged USB adapter (model, USB ID, port, driver, firmware, verdict), and the drivers available on this NAS.
- **Does**: add / update / delete a saved network (saving reconnects Wi-Fi automatically), switch language FR / EN.
- **Works with any dongle**: picks the first `wl*` interface, same as the `wifi-auto@` service.
- **Protected**: serves on port `8088`, refuses non-LAN clients (`403`), asks for a password, and locks out an IP for 5 min after 5 wrong passwords. One-time setup token for the first login.

> **Note:** it runs as root because it edits `/etc/wpa_supplicant/wifi-nas.conf` and restarts the service. Over plain HTTP the password is not encrypted — keep it on your LAN and never expose port 8088 to the internet.

### Manual install

```bash
sudo install -D -m 644 -t /usr/local/lib/wifi-ui wifi-ui.py index.html
```

```bash
sudo tee /etc/wifi-ui.env >/dev/null <<'EOF'
WIFI_UI_PASSWORD=change-me
WIFI_UI_HOST=0.0.0.0
WIFI_UI_SOCKET=
EOF
sudo chmod 600 /etc/wifi-ui.env
```

```bash
sudo cp wifi-ui.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now wifi-ui
```

Open `http://<NAS-IP>:8088` and sign in with the password.

### One-time login link (optional)

Write a random token; the URL `http://<nas>:8088/?token=<token>` logs in once, then the server deletes the token:

```bash
head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | sudo tee /etc/wifi-ui.token >/dev/null
sudo chmod 600 /etc/wifi-ui.token && sudo systemctl restart wifi-ui
```

### Options (in `/etc/wifi-ui.env`)

| Variable | Default | Meaning |
| --- | --- | --- |
| `WIFI_UI_PASSWORD` | *(empty)* | set = sign-in page; empty = no sign-in, only allowed with `WIFI_UI_HOST=127.0.0.1` |
| `WIFI_UI_HOST` | `127.0.0.1` | bind address; the installer uses `0.0.0.0` to open it to the LAN |
| `WIFI_UI_PORT` | `8088` | listening port |
| `WIFI_UI_LAN_ONLY` | `1` | refuse non-LAN clients with `403` (set `0` to disable) |
| `WIFI_UI_SESSION_DAYS` | `180` | how long a device stays signed in |
| `WIFI_UI_SOCKET` | `/var/ugreen/wifi-ui.sock` | extra Unix socket; empty disables it |
| `WIFI_UI_TOKEN_FILE` | `/etc/wifi-ui.token` | one-time login token file |
| `WIFI_CONF` | `/etc/wpa_supplicant/wifi-nas.conf` | wpa_supplicant config it edits |

### Limits

- SSIDs and passwords containing `"` or `\` are refused (kept simple on purpose). WPA3-only and hidden networks still need a manual edit of the config file.
- Saving or deleting a network restarts Wi-Fi. If you are browsing through Wi-Fi, the page comes back after a few seconds.
- A UGOS update may remove these files, same as the rest of this setup.

### Uninstall

```bash
sudo systemctl disable --now wifi-ui && sudo rm -rf /etc/systemd/system/wifi-ui.service /usr/local/lib/wifi-ui /etc/wifi-ui.env /etc/wifi-ui.token
```
