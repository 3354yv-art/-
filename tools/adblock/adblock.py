#!/usr/bin/env python3
"""
AdBlock - חוסם פרסומות ומעקבים ברמת המערכת (שרת DNS מקומי).

כל אפליקציה במחשב (דפדפן, משחקים, Spotify, תוכנות...) שואלת את ה-DNS לפני שהיא
מתחברת לשרת. השרת הזה עונה "0.0.0.0" לדומיינים של פרסומות/מעקב, ומעביר את
כל השאר לשרת DNS אמיתי. ללא תלויות - Python 3.8+ בלבד.

שימוש:
    python adblock.py update        הורדת/עדכון רשימות החסימה
    python adblock.py run           הפעלת השרת (פורט 53, דורש הרשאות מנהל)
    python adblock.py set-dns       הפניית כל המחשב לשרת (Windows / macOS)
    python adblock.py restore-dns   החזרת ה-DNS המקורי
    python adblock.py check דומיין  בדיקה אם דומיין חסום
"""
import argparse
import json
import os
import platform
import socket
import socketserver
import struct
import subprocess
import sys
import threading
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
BLOCKLIST_FILE = os.path.join(HERE, "blocklist.txt")   # נוצר ע"י update
CUSTOM_BLOCK = os.path.join(HERE, "custom-block.txt")  # דומיינים שתרצה לחסום בעצמך
ALLOWLIST = os.path.join(HERE, "allowlist.txt")        # דומיינים שלעולם לא נחסום
STATE_FILE = os.path.join(HERE, ".dns-backup.json")

SOURCES = [
    "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts",
    "https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt",
    "https://easylist.to/easylist/easylist.txt",  # נשלף רק החלק של דומיינים (||domain^)
]

# רשימה מובנית קטנה למקרה שאין אינטרנט בהפעלה הראשונה
BUILTIN = """
doubleclick.net googleadservices.com googlesyndication.com adservice.google.com
pagead2.googlesyndication.com ads.youtube.com admob.com app-measurement.com
adnxs.com adsrvr.org taboola.com outbrain.com criteo.com criteo.net
scorecardresearch.com quantserve.com moatads.com amazon-adsystem.com
ads.twitter.com analytics.twitter.com ads.facebook.com an.facebook.com
unityads.unity3d.com ads.mopub.com applovin.com ironsrc.com vungle.com
chartboost.com adcolony.com inmobi.com startapp.com flurry.com
hotjar.com mixpanel.com segment.io branch.io adjust.com appsflyer.com
""".split()

UPSTREAMS = [("1.1.1.1", 53), ("9.9.9.9", 53)]

# ------------------------------------------------------------------ blocklist

def _clean(line):
    return line.split("#", 1)[0].strip().lower()

def parse_list(text):
    """מפרש hosts / domain-list / פורמט Adblock (||domain^) ומחזיר קבוצת דומיינים."""
    out = set()
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line[0] in "![":
            continue
        if line.startswith("||"):                      # Adblock: ||example.com^
            d = line[2:].split("^", 1)[0].split("$", 1)[0]
            if d and "/" not in d and "*" not in d and "." in d:
                out.add(d.lower())
            continue
        line = _clean(line)
        if not line:
            continue
        parts = line.split()
        d = parts[1] if len(parts) >= 2 and parts[0] in ("0.0.0.0", "127.0.0.1", "::1") else parts[0]
        if "." in d and "/" not in d and ":" not in d and d not in ("localhost", "0.0.0.0"):
            out.add(d)
    return out

def read_lines(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return ""

def load_blocklist():
    blocked = set(BUILTIN)
    blocked |= parse_list(read_lines(BLOCKLIST_FILE))
    blocked |= parse_list(read_lines(CUSTOM_BLOCK))
    allowed = parse_list(read_lines(ALLOWLIST))
    return blocked, allowed

def is_blocked(name, blocked, allowed):
    """חוסם את הדומיין ואת כל תת-הדומיינים שלו; allowlist מנצח."""
    labels = name.lower().rstrip(".").split(".")
    verdict = False
    for i in range(len(labels) - 1):          # לא בודקים TLD בודד
        suffix = ".".join(labels[i:])
        if suffix in allowed:
            return False
        if suffix in blocked:
            verdict = True
    return verdict

def update():
    all_domains = set()
    for url in SOURCES:
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "adblock-py"})
            with urllib.request.urlopen(req, timeout=30) as r:
                found = parse_list(r.read().decode("utf-8", "ignore"))
            print(f"  {len(found):>8}  {url}")
            all_domains |= found
        except Exception as e:
            print(f"  נכשל   {url}  ({e})")
    if not all_domains:
        print("לא הורדה אף רשימה - נשארים עם הרשימה הקיימת/המובנית.")
        return 1
    with open(BLOCKLIST_FILE, "w", encoding="utf-8") as f:
        f.write("\n".join(sorted(all_domains)) + "\n")
    print(f"נשמרו {len(all_domains)} דומיינים ב-{BLOCKLIST_FILE}")
    return 0

# ------------------------------------------------------------------ DNS wire

def parse_question(data):
    """מחזיר (שם, qtype, סוף-השאלה) מחבילת DNS, או None אם פגומה."""
    try:
        i, labels = 12, []
        while True:
            n = data[i]
            if n == 0:
                i += 1
                break
            if n & 0xC0:
                return None
            labels.append(data[i + 1:i + 1 + n].decode("ascii", "ignore"))
            i += 1 + n
        qtype = struct.unpack("!H", data[i:i + 2])[0]
        return ".".join(labels), qtype, i + 4
    except (IndexError, struct.error):
        return None

def blocked_reply(data, qend, qtype):
    """תשובה מזויפת: 0.0.0.0 ל-A, ::  ל-AAAA, ריקה (NOERROR) לשאר הסוגים."""
    txid = data[:2]
    question = data[12:qend]
    rd = data[2] & 0x01
    flags = struct.pack("!H", 0x8000 | (rd << 8) | 0x0080)  # QR, RD, RA
    answer, count = b"", 0
    if qtype == 1:
        answer, count = b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 60, 4) + bytes(4), 1
    elif qtype == 28:
        answer, count = b"\xc0\x0c" + struct.pack("!HHIH", 28, 1, 60, 16) + bytes(16), 1
    header = txid + flags + struct.pack("!HHHH", 1, count, 0, 0)
    return header + question + answer

def servfail(data):
    return data[:2] + struct.pack("!H", 0x8182) + data[4:6] + b"\0\0\0\0\0\0"

# ------------------------------------------------------------------ server

class Stats:
    def __init__(self):
        self.lock = threading.Lock()
        self.blocked = self.total = 0

    def add(self, was_blocked):
        with self.lock:
            self.total += 1
            self.blocked += was_blocked

STATS = Stats()
BLOCKED, ALLOWED = set(), set()
VERBOSE = False

def resolve(data):
    q = parse_question(data)
    if q is None:
        return servfail(data)
    name, qtype, qend = q
    if is_blocked(name, BLOCKED, ALLOWED):
        STATS.add(True)
        if VERBOSE:
            print(f"חסום  {name}", flush=True)
        return blocked_reply(data, qend, qtype)
    STATS.add(False)
    for host, port in UPSTREAMS:
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
                s.settimeout(3)
                s.sendto(data, (host, port))
                return s.recv(4096)
        except OSError:
            continue
    return servfail(data)

def resolve_tcp(data):
    """העברה ב-TCP (לתשובות גדולות); חסימה עדיין נבדקת קודם."""
    q = parse_question(data)
    if q and is_blocked(q[0], BLOCKED, ALLOWED):
        return resolve(data)
    STATS.add(False)
    for host, port in UPSTREAMS:
        try:
            with socket.create_connection((host, port), timeout=3) as s:
                s.sendall(struct.pack("!H", len(data)) + data)
                hdr = s.recv(2)
                n = struct.unpack("!H", hdr)[0]
                buf = b""
                while len(buf) < n:
                    chunk = s.recv(n - len(buf))
                    if not chunk:
                        break
                    buf += chunk
                return buf
        except OSError:
            continue
    return servfail(data)

class UDPHandler(socketserver.BaseRequestHandler):
    def handle(self):
        data, sock = self.request
        if len(data) >= 12:
            sock.sendto(resolve(data), self.client_address)

class TCPHandler(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            self.request.settimeout(5)
            hdr = self.request.recv(2)
            n = struct.unpack("!H", hdr)[0]
            data = b""
            while len(data) < n:
                chunk = self.request.recv(n - len(data))
                if not chunk:
                    return
                data += chunk
            reply = resolve_tcp(data)
            self.request.sendall(struct.pack("!H", len(reply)) + reply)
        except (OSError, struct.error):
            pass

class ThreadedUDP(socketserver.ThreadingMixIn, socketserver.UDPServer):
    daemon_threads = True
    allow_reuse_address = True

class ThreadedTCP(socketserver.ThreadingMixIn, socketserver.TCPServer):
    daemon_threads = True
    allow_reuse_address = True

def run(listen, port):
    global BLOCKED, ALLOWED
    if not os.path.exists(BLOCKLIST_FILE):
        print("אין רשימת חסימה - מוריד...")
        update()
    BLOCKED, ALLOWED = load_blocklist()
    print(f"נטענו {len(BLOCKED)} דומיינים חסומים, {len(ALLOWED)} ברשימה הלבנה")
    try:
        udp, tcp = ThreadedUDP((listen, port), UDPHandler), ThreadedTCP((listen, port), TCPHandler)
    except PermissionError:
        sys.exit("אין הרשאה לפורט %d - הפעל כמנהל (Windows) או עם sudo (Linux/macOS)." % port)
    except OSError as e:
        sys.exit(f"לא ניתן להאזין על {listen}:{port} - {e}\n(אולי שירות אחר כבר משתמש בפורט 53)")
    for s in (udp, tcp):
        threading.Thread(target=s.serve_forever, daemon=True).start()
    print(f"רץ על {listen}:{port}. Ctrl+C לעצירה.")
    try:
        while True:
            time.sleep(60)
            pct = 100 * STATS.blocked / max(STATS.total, 1)
            print(f"[סטטיסטיקה] {STATS.total} בקשות, {STATS.blocked} נחסמו ({pct:.0f}%)", flush=True)
    except KeyboardInterrupt:
        print("\nנעצר.")

# ------------------------------------------------------------------ system DNS

def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)

def set_dns():
    system = platform.system()
    backup = {}
    if system == "Windows":
        ps = ("Get-NetAdapter | Where-Object Status -eq 'Up' | ForEach-Object { "
              "$d=(Get-DnsClientServerAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4).ServerAddresses; "
              "[pscustomobject]@{n=$_.Name;d=@($d)} } | ConvertTo-Json -Compress")
        out = sh(["powershell", "-NoProfile", "-Command", ps]).stdout.strip()
        adapters = json.loads(out) if out else []
        adapters = adapters if isinstance(adapters, list) else [adapters]
        for a in adapters:
            backup[a["n"]] = a["d"]
            sh(["powershell", "-NoProfile", "-Command",
                f"Set-DnsClientServerAddress -InterfaceAlias '{a['n']}' -ServerAddresses 127.0.0.1"])
    elif system == "Darwin":
        services = [l for l in sh(["networksetup", "-listallnetworkservices"]).stdout.splitlines()[1:]
                    if not l.startswith("*")]
        for svc in services:
            cur = sh(["networksetup", "-getdnsservers", svc]).stdout.split()
            backup[svc] = [] if "aren't" in " ".join(cur) else cur
            sh(["networksetup", "-setdnsservers", svc, "127.0.0.1"])
    else:
        sys.exit("ב-Linux: הגדר ידנית nameserver 127.0.0.1 ב-/etc/resolv.conf "
                 "(או ב-systemd-resolved / NetworkManager).")
    with open(STATE_FILE, "w") as f:
        json.dump({"system": system, "backup": backup}, f)
    print("כל המחשב משתמש עכשיו בחוסם. להחזרה: python adblock.py restore-dns")

def restore_dns():
    try:
        with open(STATE_FILE) as f:
            st = json.load(f)
    except OSError:
        sys.exit("אין גיבוי של ה-DNS (לא הורץ set-dns).")
    for name, servers in st["backup"].items():
        if st["system"] == "Windows":
            if servers:
                addrs = ",".join(f"'{s}'" for s in servers)
                cmd = f"Set-DnsClientServerAddress -InterfaceAlias '{name}' -ServerAddresses {addrs}"
            else:
                cmd = f"Set-DnsClientServerAddress -InterfaceAlias '{name}' -ResetServerAddresses"
            sh(["powershell", "-NoProfile", "-Command", cmd])
        else:
            sh(["networksetup", "-setdnsservers", name] + (servers or ["Empty"]))
    os.remove(STATE_FILE)
    print("ה-DNS המקורי הוחזר.")

# ------------------------------------------------------------------ main

def main():
    global VERBOSE
    p = argparse.ArgumentParser(description="חוסם פרסומות ברמת המערכת")
    p.add_argument("cmd", choices=["run", "update", "set-dns", "restore-dns", "check"], nargs="?", default="run")
    p.add_argument("domain", nargs="?")
    p.add_argument("--listen", default="127.0.0.1", help="כתובת האזנה (0.0.0.0 כדי לשרת גם מכשירים ברשת)")
    p.add_argument("--port", type=int, default=53)
    p.add_argument("-v", "--verbose", action="store_true", help="הדפס כל דומיין שנחסם")
    a = p.parse_args()
    VERBOSE = a.verbose
    if a.cmd == "update":
        sys.exit(update())
    elif a.cmd == "set-dns":
        set_dns()
    elif a.cmd == "restore-dns":
        restore_dns()
    elif a.cmd == "check":
        if not a.domain:
            sys.exit("שימוש: adblock.py check example.com")
        b, al = load_blocklist()
        print("חסום" if is_blocked(a.domain, b, al) else "מותר")
    else:
        run(a.listen, a.port)

if __name__ == "__main__":
    main()
