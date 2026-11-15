#!/usr/bin/env python3
"""Tiny web UI for the wifi-auto setup (wpa_supplicant + systemd). Python stdlib only."""
import fnmatch, glob, hashlib, hmac, ipaddress, json, os, re, socketserver, subprocess, threading, time
from functools import cache
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

CONF = os.environ.get("WIFI_CONF", "/etc/wpa_supplicant/wifi-nas.conf")
PORT = int(os.environ.get("WIFI_UI_PORT", "8088"))
HOST = os.environ.get("WIFI_UI_HOST", "127.0.0.1")
PASSWORD = os.environ.get("WIFI_UI_PASSWORD", "")
SOCK = os.environ.get("WIFI_UI_SOCKET", "/var/ugreen/wifi-ui.sock")
if not PASSWORD and HOST != "127.0.0.1":
    raise SystemExit("WIFI_UI_PASSWORD is required unless WIFI_UI_HOST=127.0.0.1")
# Session cookie value: derived from the password, so changing the password logs everyone out.
SESSION = hmac.new(PASSWORD.encode(), b"wifi-ui-session", hashlib.sha256).hexdigest() if PASSWORD else None
COOKIE = "usbwifi_session"
FAILS = {}  # client ip -> (failed count, locked-until epoch): brute-force lockout
FAILS_LOCK = threading.Lock()
MAX_TRIES, LOCKOUT = 5, 300
LAN_ONLY = os.environ.get("WIFI_UI_LAN_ONLY", "1") != "0"
SESSION_DAYS = int(os.environ.get("WIFI_UI_SESSION_DAYS", "180"))  # stay signed in per device
# One-time "magic link" token: lets the install URL log in once, then it's destroyed.
TOKEN_FILE = os.environ.get("WIFI_UI_TOKEN_FILE", "/etc/wifi-ui.token")
def _load_token():
    try:
        with open(TOKEN_FILE) as f:
            return f.read().strip() or None
    except OSError:
        return None
SETUP_TOKEN = _load_token() if PASSWORD else None
TOKEN_LOCK = threading.Lock()


def is_lan(ip):
    try:
        a = ipaddress.ip_address(ip)
        return a.is_private or a.is_loopback or a.is_link_local
    except ValueError:
        return False
BLOCK = re.compile(r"network=\{.*?\}\n?", re.S)
MODULES = f"/lib/modules/{os.uname().release}"
USB_SPEED = {"1.5": "USB 1.0", "12": "USB 1.1", "480": "USB 2.0", "5000": "USB 3 · 5 Gb/s",
             "10000": "USB 3 · 10 Gb/s", "20000": "USB 3 · 20 Gb/s"}


def run(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=15).stdout


def read(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return None


def iface():
    return next((n for n in sorted(os.listdir("/sys/class/net")) if n.startswith("wl")), None)


def field(body, key):
    m = re.search(rf'^\s*{key}="?([^"\n]*)"?', body, re.M)
    return m.group(1) if m else None


def read_conf():
    with open(CONF) as f:
        return f.read()


def write_conf(text):
    tmp = CONF + ".tmp"
    with open(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
        f.write(re.sub(r"\n{3,}", "\n\n", text))
    os.replace(tmp, CONF)


def networks():
    return [{"ssid": field(b, "ssid"), "priority": int(field(b, "priority") or 0)}
            for b in BLOCK.findall(read_conf())]


def remove(text, ssid):
    return BLOCK.sub(lambda m: "" if field(m.group(0), "ssid") == ssid else m.group(0), text)


def status():
    i = iface()
    if not i:
        return {"iface": None}
    link = run("iw", "dev", i, "link")
    get = lambda pat: (m := re.search(pat, link)) and m.group(1)
    ip = re.search(r"inet (\S+)", run("ip", "-4", "addr", "show", i))
    return {"iface": i,
            "service": run("systemctl", "is-active", f"wifi-auto@{i}.service").strip(),
            "ssid": get(r"SSID: (.*)"),
            "signal": int(s) if (s := get(r"signal: (-?\d+)")) else None,
            "freq": int(float(f)) if (f := get(r"freq: ([\d.]+)")) else None,
            "rate": get(r"tx bitrate: ([\d.]+ MBit/s)"),
            "ip": ip.group(1) if ip else None}


def scan():
    i, best, sig = iface(), {}, None
    if i:
        run("wpa_cli", "-i", i, "scan")  # ask wpa_supplicant to refresh (background scan, keeps the link)
    for line in run("iw", "dev", i, "scan", "dump").splitlines() if i else []:
        line = line.strip()
        if line.startswith("signal:"):
            sig = round(float(line.split()[1]))
        elif line.startswith("SSID: ") and line[6:]:
            best[line[6:]] = max(sig or -100, best.get(line[6:], -100))
    return sorted(({"ssid": s, "signal": v} for s, v in best.items()), key=lambda n: -n["signal"])


@cache
def wifi_aliases():
    """(usb modalias pattern, module) for every Wi-Fi driver shipped with this kernel."""
    with open(f"{MODULES}/modules.dep") as f:
        wifi = {os.path.basename(l.split(":")[0]).split(".ko")[0].replace("-", "_")
                for l in f if "/net/wireless/" in l.split(":")[0]}
    with open(f"{MODULES}/modules.alias") as f:
        rows = (l.split() for l in f)
        return [(r[1], r[2]) for r in rows if len(r) == 3 and r[1].startswith("usb:") and r[2].replace("-", "_") in wifi]


def firmware(mod):
    files = run("modinfo", "-F", "firmware", mod).split()
    found = [f for f in files if any(os.path.exists(f"/lib/firmware/{f}{x}") for x in ("", ".zst", ".xz"))]
    return {"needed": len(files), "found": len(found)}


def hardware():
    """USB Wi-Fi adapters, and USB devices without any driver (possibly unsupported dongles)."""
    out = []
    for d in sorted(glob.glob("/sys/bus/usb/devices/[0-9]*-*")):
        name = os.path.basename(d)
        if ":" in name or read(f"{d}/bDeviceClass") == "09":  # interfaces and hubs
            continue
        intfs = glob.glob(f"{d}/{name}:*")
        drivers = sorted({os.path.basename(os.readlink(f"{i}/driver")) for i in intfs if os.path.islink(f"{i}/driver")})
        nets = [n for i in intfs if os.path.isdir(f"{i}/net") for n in os.listdir(f"{i}/net")]
        wl = next((n for n in nets if n.startswith("wl")), None)
        aliases = [read(f"{i}/modalias") or "" for i in intfs]
        module = next((m for a in aliases for p, m in wifi_aliases() if fnmatch.fnmatchcase(a, p)), None)
        if not (wl or module or not drivers):
            continue
        bus, port = name.split("-", 1)
        out.append({
            "name": " ".join(filter(None, (read(f"{d}/manufacturer"), read(f"{d}/product")))) or None,
            "id": f"{read(f'{d}/idVendor')}:{read(f'{d}/idProduct')}",
            "port": f"Bus {bus} · port {port}",
            "usb": USB_SPEED.get(read(f"{d}/speed"), "USB"),
            "iface": wl,
            "module": module,
            "loaded": bool(module and os.path.isdir(f"/sys/module/{module.replace('-', '_')}")),
            "firmware": firmware(module) if module else None,
            "verdict": "ok" if wl else "driver" if module else "unsupported",
        })
    return {"kernel": os.uname().release, "devices": out}


# Curated USB Wi-Fi chipsets -> (kernel module, label, example dongles).
CARDS = [
    ("mt7921u", "MediaTek MT7921AU · Wi-Fi 6 (AXE3000)", "BrosTrend AX9L, Comfast CF-953AX"),
    ("mt76x2u", "MediaTek MT7612U · AC1200", "Alfa AWUS036ACM, Netgear A6210"),
    ("mt76x0u", "MediaTek MT7610U · AC600", "Panda PAU0B, Comfast CF-812AC"),
    ("mt7601u", "MediaTek MT7601U · 2.4 GHz", "cheap 'MT7601' nano dongles"),
    ("rtw88_8822bu", "Realtek RTL8822BU · AC1300", "Maxesla AC1200 (tested), TP-Link Archer T3U Plus"),
    ("rtw88_8821cu", "Realtek RTL8811CU/8821CU · AC600", "BrosTrend AC650 (tested), Comfast CF-811AC"),
    ("rtl8xxxu", "Realtek RTL8188/8192 CU/EU · 2.4 GHz", "TP-Link TL-WN823N, many nano dongles"),
    ("rtl8187", "Realtek RTL8187 · 54 Mbit/s", "Netgear WG111v3 (tested), Alfa AWUS036H"),
    ("rt2800usb", "Ralink RT3070/RT5370 · 2.4 GHz", "Alfa AWUS036NH, older dongles"),
    ("ath9k_htc", "Atheros AR9271 · 2.4 GHz", "Alfa AWUS036NHA, TP-Link TL-WN722N v1"),
    ("carl9170", "Atheros AR9170 · 2.4 GHz", "Alfa AWUS036NHR (older)"),
]


def available():
    """Known USB Wi-Fi chipsets this kernel can drive (driver present + firmware check)."""
    out = []
    for mod, chip, ex in CARDS:
        if not run("modinfo", "-n", mod).strip():
            out.append({"module": mod, "chip": chip, "examples": ex, "state": "absent"})
            continue
        fw = firmware(mod)
        state = "ok" if (fw["needed"] == 0 or fw["found"] >= fw["needed"]) else "missing"
        out.append({"module": mod, "chip": chip, "examples": ex, "state": state, "firmware": fw})
    return {"kernel": os.uname().release, "cards": out}


def restart():
    if i := iface():
        run("systemctl", "--no-block", "restart", f"wifi-auto@{i}.service")


def ok(s, lo, hi):
    return isinstance(s, str) and lo <= len(s.encode()) <= hi and not set(s) & set('"\\\n\r')


def add(d):
    ssid, psk, prio = d.get("ssid"), d.get("psk"), d.get("priority", 0)
    if not (ok(ssid, 1, 32) and ok(psk, 8, 63) and isinstance(prio, int) and 0 <= prio <= 999):
        raise ValueError("SSID 1-32 chars, password 8-63 chars, no quotes/backslashes")
    text = remove(read_conf(), ssid).rstrip("\n")
    write_conf(f'{text}\n\nnetwork={{\n    ssid="{ssid}"\n    psk="{psk}"\n    priority={prio}\n}}\n')
    restart()


def delete(d):
    write_conf(remove(read_conf(), d.get("ssid")))
    restart()


GETS = {"/api/status": lambda: {"status": status(), "networks": networks(), "scan": scan()},
        "/api/hardware": hardware,
        "/api/available": available}
ACTIONS = {"add": add, "delete": delete, "restart": lambda d: restart()}


class Handler(BaseHTTPRequestHandler):
    def send(self, code, body, ctype="application/json", cookie=None):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        if cookie is not None:
            self.send_header("Set-Cookie", f"{COOKIE}={cookie}; Path=/; HttpOnly; SameSite=Strict; Max-Age={SESSION_DAYS * 86400 if cookie else 0}")
        self.end_headers()
        self.wfile.write(data)

    def authed(self):
        cookies = dict(c.strip().split("=", 1) for c in self.headers.get("Cookie", "").split(";") if "=" in c)
        if SESSION is None or hmac.compare_digest(cookies.get(COOKIE, ""), SESSION):
            return True
        self.send(401, "login required", "text/plain")

    def consume_token(self, tok):
        """Validate the one-time setup token; if good, burn it so it can never be reused."""
        global SETUP_TOKEN
        with TOKEN_LOCK:
            if not (SETUP_TOKEN and tok and hmac.compare_digest(tok, SETUP_TOKEN)):
                return False
            SETUP_TOKEN = None
        try:
            os.remove(TOKEN_FILE)
        except OSError:
            pass
        return True

    def peer_ip(self):
        peer = self.client_address[0] if isinstance(self.client_address, tuple) else "unix"
        xri = self.headers.get("X-Real-IP")
        try:  # trust X-Real-IP only from a local reverse proxy, never a direct client
            if xri and ipaddress.ip_address(peer).is_loopback:
                return xri
        except ValueError:
            pass
        return peer

    def lan_ok(self):
        if not LAN_ONLY or is_lan(self.peer_ip()):
            return True
        self.send(403, "local network only", "text/plain")

    def login(self, d):
        ip = self.peer_ip()
        now = time.time()
        with FAILS_LOCK:
            count, until = FAILS.get(ip, (0, 0.0))
        if until > now:
            return self.send(429, "too many attempts", "text/plain")
        if SESSION and hmac.compare_digest(str(d.get("password", "")), PASSWORD):
            with FAILS_LOCK:
                FAILS.pop(ip, None)
            return self.send(200, "{}", cookie=SESSION)
        time.sleep(1)  # slow down guessing
        with FAILS_LOCK:
            count += 1
            FAILS[ip] = (count, now + LOCKOUT if count >= MAX_TRIES else 0.0)
        self.send(401, "wrong password", "text/plain")

    def do_GET(self):
        if not self.lan_ok():
            return
        path = self.path.split("?")[0]
        if path == "/":
            tok = parse_qs(urlparse(self.path).query).get("token", [""])[0]
            if tok and self.consume_token(tok):  # one-time link -> log in, then redirect to a clean URL
                self.send_response(302)
                self.send_header("Location", "/")
                self.send_header("Content-Length", "0")
                self.send_header("Set-Cookie", f"{COOKIE}={SESSION}; Path=/; HttpOnly; SameSite=Strict; Max-Age={SESSION_DAYS * 86400}")
                self.end_headers()
                return
            return self.send(200, PAGE, "text/html; charset=utf-8")
        if not self.authed():
            return
        if path in GETS:
            self.send(200, json.dumps(GETS[path]()))
        else:
            self.send(404, "not found", "text/plain")

    def do_POST(self):
        if not self.lan_ok():
            return
        name = self.path.removeprefix("/api/")
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or "{}")
        if name == "login":
            return self.login(body)
        if name == "logout":
            return self.send(200, "{}", cookie="")
        if not self.authed():
            return
        action = ACTIONS.get(name)
        if not action:
            return self.send(404, "not found", "text/plain")
        try:
            action(body)
            self.send(200, "{}")
        except (ValueError, OSError) as e:
            self.send(400, str(e), "text/plain")


PAGE = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "index.html"), encoding="utf-8").read()

class UnixServer(socketserver.ThreadingUnixStreamServer):
    """Same API on a Unix socket: UGOS marks the app as started when /var/ugreen/<service>.sock appears."""
    def get_request(self):
        conn, _ = super().get_request()
        return conn, ("unix", 0)


if __name__ == "__main__":
    if SOCK and os.path.isdir(os.path.dirname(SOCK)):
        if os.path.exists(SOCK):
            os.remove(SOCK)
        threading.Thread(target=UnixServer(SOCK, Handler).serve_forever, daemon=True).start()
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
