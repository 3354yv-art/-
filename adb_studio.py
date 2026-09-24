#!/usr/bin/env python3
"""ADB סטודיו — ממשק גרפי פשוט ונקי בעברית לניהול מכשירי אנדרואיד דרך ADB.

הפעלה:  python adb_studio.py
אין צורך בספריות חיצוניות — רק Python 3.9 ומעלה (או קובץ ההתקנה המוכן ל-Windows).
"""

import json
import mimetypes
import os
import platform
import re
import secrets
import shlex
import shutil
import socket
import stat
import subprocess
import string
import sys
import tarfile
import tempfile
import threading
import time
import urllib.request
import webbrowser
import zipfile
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, quote, urlparse

APP_NAME = "ADB סטודיו"
FROZEN = getattr(sys, "frozen", False)  # רץ כקובץ exe מותקן
APP_DIR = (Path(sys.executable) if FROZEN else Path(__file__)).resolve().parent
RES_DIR = Path(getattr(sys, "_MEIPASS", APP_DIR)).resolve()
WEB_DIR = (RES_DIR / "web").resolve()
DATA_DIR = Path.home() / ".adb-studio"
TOOLS_DIR = APP_DIR / "platform-tools"          # מגיע עם ההתקנה
USER_TOOLS_DIR = DATA_DIR / "platform-tools"    # התקנה אוטומטית מתוך התוכנה
SCRCPY_DIR = APP_DIR / "scrcpy"                 # שיקוף מסך — מגיע עם ההתקנה
USER_SCRCPY_DIR = DATA_DIR / "scrcpy"
IS_WINDOWS = os.name == "nt"
IS_MAC = sys.platform == "darwin"
NO_WINDOW = 0x08000000 if IS_WINDOWS else 0  # CREATE_NO_WINDOW
TOKEN = secrets.token_urlsafe(24)
last_seen = 0.0  # מתי הממשק פנה לשרת לאחרונה
IDLE_EXIT = 180  # שניות בלי ממשק פתוח עד יציאה (דפדפנים מאטים טיימרים של חלון ממוזער)

PACKAGE_RE = re.compile(r"^[A-Za-z0-9_.]+$")
ADDRESS_RE = re.compile(r"^[A-Za-z0-9.\-\[\]:]+$")
MIME = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".svg": "image/svg+xml",
    ".png": "image/png",
    ".ico": "image/x-icon",
    ".woff2": "font/woff2",
}


class AdbError(Exception):
    """שגיאה עם הודעה ידידותית שמוצגת למשתמש."""


# ───────────────────────────── ADB ─────────────────────────────

_adb_path = None


def find_adb():
    exe = "adb.exe" if IS_WINDOWS else "adb"
    candidates = []
    if os.environ.get("ADB_PATH"):
        candidates.append(Path(os.environ["ADB_PATH"]))
    candidates += [TOOLS_DIR / exe, USER_TOOLS_DIR / exe]
    on_path = shutil.which("adb")
    if on_path:
        candidates.append(Path(on_path))
    for var in ("ANDROID_HOME", "ANDROID_SDK_ROOT"):
        if os.environ.get(var):
            candidates.append(Path(os.environ[var]) / "platform-tools" / exe)
    home = Path.home()
    if IS_WINDOWS:
        local = os.environ.get("LOCALAPPDATA")
        if local:
            candidates.append(Path(local) / "Android" / "Sdk" / "platform-tools" / exe)
    elif IS_MAC:
        candidates.append(home / "Library" / "Android" / "sdk" / "platform-tools" / exe)
    else:
        candidates.append(home / "Android" / "Sdk" / "platform-tools" / exe)
    for path in candidates:
        if path.is_file():
            return str(path)
    return None


def adb_path():
    global _adb_path
    if not _adb_path or not Path(_adb_path).is_file():
        _adb_path = find_adb()
    return _adb_path


_scrcpy_path = None


def scrcpy_path():
    """scrcpy — הכלי שמאחורי שיקוף המסך (Genymobile, Apache-2.0)."""
    global _scrcpy_path
    if _scrcpy_path and Path(_scrcpy_path).is_file():
        return _scrcpy_path
    exe = "scrcpy.exe" if IS_WINDOWS else "scrcpy"
    candidates = [Path(os.environ["SCRCPY_PATH"])] if os.environ.get("SCRCPY_PATH") else []
    candidates += [SCRCPY_DIR / exe, USER_SCRCPY_DIR / exe]
    on_path = shutil.which("scrcpy")
    if on_path:
        candidates.append(Path(on_path))
    _scrcpy_path = next((str(p) for p in candidates if p.is_file()), None)
    return _scrcpy_path


FRIENDLY_ERRORS = [
    ("no devices/emulators found", "לא נמצא מכשיר מחובר"),
    ("unauthorized", "המכשיר לא מאושר — אשרו את ניפוי ה-USB במסך הטלפון"),
    ("device offline", "המכשיר במצב לא מקוון — נסו לנתק ולחבר מחדש"),
    ("not found", "המכשיר לא נמצא — ייתכן שהוא נותק"),
    ("Permission denied", "אין הרשאה לבצע את הפעולה הזו"),
    ("No such file or directory", "הקובץ או התיקייה לא קיימים"),
    ("Read-only file system", "מערכת הקבצים לקריאה בלבד"),
    ("INSTALL_FAILED_VERSION_DOWNGRADE", "כבר מותקנת גרסה חדשה יותר של האפליקציה"),
    ("INSTALL_FAILED_INSUFFICIENT_STORAGE", "אין מספיק מקום פנוי במכשיר"),
    ("INSTALL_FAILED_UPDATE_INCOMPATIBLE", "חתימת האפליקציה שונה מהגרסה המותקנת — הסירו אותה קודם"),
    ("INSTALL_PARSE_FAILED", "קובץ ה-APK פגום או לא תקין"),
    ("INSTALL_FAILED_USER_RESTRICTED", "ההתקנה נחסמה — אשרו התקנה דרך USB בהגדרות המכשיר"),
]


def friendly(message):
    message = (message or "").strip()
    for needle, text in FRIENDLY_ERRORS:
        if needle in message:
            return text
    return message or "הפעולה נכשלה"


def run_adb(*args, serial=None, timeout=30, binary=False):
    """מריץ פקודת adb ומחזיר (קוד יציאה, פלט, שגיאה)."""
    path = adb_path()
    if not path:
        raise AdbError("ADB לא מותקן במחשב")
    cmd = [path]
    if serial:
        if serial.startswith("-"):
            raise AdbError("מזהה מכשיר לא תקין")
        cmd += ["-s", serial]
    cmd += [str(a) for a in args]
    try:
        proc = subprocess.run(
            cmd,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            timeout=timeout,
            creationflags=NO_WINDOW,
        )
    except subprocess.TimeoutExpired:
        raise AdbError("הפעולה ארכה יותר מדי זמן")
    except OSError as exc:
        raise AdbError(f"לא ניתן להפעיל את ADB: {exc}")
    err = proc.stderr.decode("utf-8", "replace").replace("\r\n", "\n")
    if binary:
        return proc.returncode, proc.stdout, err
    out = proc.stdout.decode("utf-8", "replace").replace("\r\n", "\n")
    return proc.returncode, out, err


def adb_ok(*args, serial=None, timeout=30):
    """מריץ פקודה וזורק שגיאה ידידותית אם נכשלה."""
    code, out, err = run_adb(*args, serial=serial, timeout=timeout)
    if code != 0:
        raise AdbError(friendly(err or out))
    return out


def shell(serial, script, timeout=30):
    return adb_ok("shell", script, serial=serial, timeout=timeout)


# ─────────────────────────── מכשירים ───────────────────────────


def list_devices():
    out = adb_ok("devices", "-l", timeout=10)
    devices = []
    for line in out.splitlines()[1:]:
        parts = line.split()
        if len(parts) < 2 or line.startswith("*"):
            continue
        props = dict(p.split(":", 1) for p in parts[2:] if ":" in p)
        serial = parts[0]
        devices.append({
            "serial": serial,
            "state": parts[1],
            "model": props.get("model", "").replace("_", " "),
            "wireless": ":" in serial or "._adb-tls-connect." in serial,
        })
    return devices


SEP = "@@SEP@@"


def device_info(serial):
    script = f"; echo {SEP}; ".join([
        "getprop ro.product.manufacturer; getprop ro.product.model; "
        "getprop ro.build.version.release; getprop ro.build.version.sdk; "
        "getprop ro.product.device; getprop ro.build.display.id; "
        "getprop ro.build.version.security_patch; getprop ro.product.cpu.abi; "
        "getprop ro.soc.model; getprop ro.board.platform; getprop ro.product.brand",
        "dumpsys battery",
        "df -k /data",
        "wm size",
        "ip -f inet addr show wlan0",
        "grep -E 'MemTotal|MemAvailable' /proc/meminfo",
        "cat /proc/uptime",
    ])
    parts = shell(serial, script).split(SEP)
    parts += [""] * (7 - len(parts))
    # getprop מדפיס שורה ריקה לערך חסר — לא מסננים שורות כדי לא לשבש את הסדר
    props = [line.strip() for line in parts[0].strip("\n").split("\n")] + [""] * 11
    info = {
        "manufacturer": props[0].capitalize(),
        "model": props[1],
        "android": props[2],
        "sdk": props[3],
        "codename": props[4],
        "build": props[5],
        "patch": props[6],
        "abi": props[7],
        "chipset": props[8] or props[9],
        "brand": props[10].capitalize(),
    }

    battery = {}
    for line in parts[1].splitlines():
        if ":" in line:
            key, val = line.split(":", 1)
            battery[key.strip()] = val.strip()
    if battery.get("level"):
        powered = any(battery.get(k) == "true" for k in
                      ("AC powered", "USB powered", "Wireless powered"))
        temp = battery.get("temperature", "")
        info["battery"] = {
            "level": int(battery["level"]),
            "charging": battery.get("status") == "2" or (powered and battery.get("status") != "5"),
            "full": battery.get("status") == "5",
            "temperature": round(int(temp) / 10, 1) if temp.isdigit() else None,
        }

    df_lines = [l for l in parts[2].strip().splitlines() if l.strip()]
    if len(df_lines) >= 2:
        nums = [int(n) for n in df_lines[-1].split() if n.isdigit()]
        if len(nums) >= 3:
            info["storage"] = {"total": nums[0] * 1024, "used": nums[1] * 1024,
                               "free": nums[2] * 1024}

    sizes = re.findall(r"(\w+) size: (\d+x\d+)", parts[3])
    if sizes:
        info["screen"] = dict(sizes).get("Override", sizes[0][1])

    ip = re.search(r"inet (\d+\.\d+\.\d+\.\d+)", parts[4])
    info["ip"] = ip.group(1) if ip else None

    mem = dict(re.findall(r"(\w+):\s+(\d+)", parts[5]))
    if "MemTotal" in mem:
        info["ram"] = {"total": int(mem["MemTotal"]) * 1024,
                       "free": int(mem.get("MemAvailable", 0)) * 1024}

    try:
        info["uptime"] = int(float(parts[6].split()[0]))
    except (ValueError, IndexError):
        info["uptime"] = None
    return info


def wifi_ip(serial):
    out = shell(serial, "ip -f inet addr show wlan0")
    match = re.search(r"inet (\d+\.\d+\.\d+\.\d+)", out)
    return match.group(1) if match else None


def normalize_address(address, default_port=5555):
    address = (address or "").strip()
    if not address or not ADDRESS_RE.match(address):
        raise AdbError("כתובת לא תקינה. דוגמה: 192.168.1.20:5555")
    if address.count(":") == 0:
        address = f"{address}:{default_port}"
    return address


def connect(address):
    address = normalize_address(address)
    _, out, err = run_adb("connect", address, timeout=15)
    text = (out + err).strip()
    if "connected to" in text:
        return address
    raise AdbError(f"החיבור נכשל: {text or 'אין תגובה מהמכשיר'}")


def switch_to_wifi(serial):
    ip = wifi_ip(serial)
    if not ip:
        raise AdbError("המכשיר לא מחובר לרשת Wi‑Fi")
    adb_ok("tcpip", "5555", serial=serial, timeout=15)
    last = None
    for _ in range(5):
        time.sleep(1.5)
        try:
            return connect(f"{ip}:5555")
        except AdbError as exc:
            last = exc
    raise last


MDNS_RE = re.compile(r"^(\S+)\s+(_adb[\w-]*\._tcp)\.?\s+([\d.]+):(\d+)")


def mdns_services():
    """מכשירים שמפרסמים את עצמם ברשת (ניפוי באגים אלחוטי, אנדרואיד 11+)."""
    try:
        _, out, _ = run_adb("mdns", "services", timeout=8)
    except AdbError:
        return []
    services = []
    for line in out.splitlines():
        match = MDNS_RE.match(line.strip())
        if match:
            name, kind, ip, port = match.groups()
            services.append({"name": name, "kind": kind, "ip": ip, "address": f"{ip}:{port}"})
    return services


def discover():
    connected = {d["serial"] for d in list_devices()}
    found = []
    for svc in mdns_services():
        if svc["kind"] != "_adb-tls-connect._tcp":
            continue
        if svc["address"] in connected or any(c.startswith(svc["name"] + ".") for c in connected):
            continue
        # שם השירות הוא בדרך כלל adb-<מספר סידורי>-<אקראי>
        label = re.sub(r"^adb-|-\w{6}$", "", svc["name"])
        found.append({"label": label, "address": svc["address"]})
    return found


QR_SESSIONS = {}


def qr_start():
    """צימוד בסריקת QR — אותו פרוטוקול של Android Studio."""
    name = "ADB-Studio-" + secrets.token_hex(3)
    alphabet = string.ascii_letters + string.digits
    password = "".join(secrets.choice(alphabet) for _ in range(10))
    QR_SESSIONS[name] = {"password": password, "state": "waiting", "ip": None}
    return {"session": name, "qr": f"WIFI:T:ADB;S:{name};P:{password};;"}


def qr_poll(name):
    session = QR_SESSIONS.get(name)
    if not session:
        raise AdbError("פג תוקף הצימוד — נסו שוב")
    services = mdns_services()
    if session["state"] == "waiting":
        pairing = next((s for s in services if s["name"] == name
                        and s["kind"].startswith("_adb-tls-pairing")), None)
        if not pairing:
            return {"state": "waiting"}
        _, out, err = run_adb("pair", pairing["address"], session["password"], timeout=30)
        if "Successfully paired" not in out + err:
            session["state"] = "failed"
            raise AdbError(f"הצימוד נכשל: {(out + err).strip()}")
        session.update(state="paired", ip=pairing["ip"], since=time.monotonic())
    if session["state"] == "paired":
        target = next((s for s in services if s["ip"] == session["ip"]
                       and s["kind"] == "_adb-tls-connect._tcp"), None)
        if target:
            # adb מתחבר לבד למכשיר מצומד; אם לא — מתחברים ידנית
            for dev in list_devices():
                if dev["serial"].startswith(target["name"] + ".") or dev["serial"] == target["address"]:
                    session["state"] = "connected"
                    return {"state": "connected", "serial": dev["serial"]}
            try:
                serial = connect(target["address"])
                session["state"] = "connected"
                return {"state": "connected", "serial": serial}
            except AdbError:
                pass
        if time.monotonic() - session["since"] > 25:
            return {"state": "paired"}
        return {"state": "pairing"}
    return {"state": session["state"]}


# ────────────────────────── אפליקציות ──────────────────────────


def check_package(package):
    if not package or not PACKAGE_RE.match(package):
        raise AdbError("שם חבילה לא תקין")
    return package


def list_apps(serial):
    """כל האפליקציות, כולל מושבתות ואפליקציות מערכת שהוסרו (וניתנות לשחזור)."""
    script = f"; echo {SEP}; ".join([
        "pm list packages -3", "pm list packages", "pm list packages -d", "pm list packages -u"])
    parts = shell(serial, script, timeout=40).split(SEP) + [""] * 4

    def names(text):
        return {l.split(":", 1)[1].strip() for l in text.splitlines() if l.startswith("package:")}

    user, installed, disabled, everything = (names(t) for t in parts[:4])
    everything |= installed
    apps = [{
        "package": p,
        "system": p not in user,
        "disabled": p in disabled,
        "removed": p not in installed,
    } for p in everything]
    apps.sort(key=lambda a: a["package"])
    return apps


INSTALLERS = {
    "com.android.vending": "Google Play",
    "com.sec.android.app.samsungapps": "Galaxy Store",
    "com.huawei.appmarket": "AppGallery",
    "com.xiaomi.market": "GetApps",
    "com.xiaomi.mipicks": "GetApps",
    "com.amazon.venezia": "Amazon Appstore",
    "org.fdroid.fdroid": "F-Droid",
    "com.google.android.packageinstaller": "התקנה ידנית",
    "com.android.packageinstaller": "התקנה ידנית",
    "com.android.shell": "ADB",
}


def app_info(serial, package):
    package = check_package(package)
    out = shell(serial, f"dumpsys package {shlex.quote(package)}", timeout=30)
    start = out.find(f"Package [{package}]")
    section = out[start:] if start >= 0 else out

    def field(name):
        match = re.search(rf"\b{name}=([^\s,]+)", section)
        return match.group(1) if match else None

    info = {
        "package": package,
        "version": field("versionName"),
        "versionCode": field("versionCode"),
        "targetSdk": field("targetSdk"),
        "installed": re.search(r"firstInstallTime=([\d-]+ [\d:]+)", section),
        "updated": re.search(r"lastUpdateTime=([\d-]+ [\d:]+)", section),
    }
    info["installed"] = info["installed"].group(1) if info["installed"] else None
    info["updated"] = info["updated"].group(1) if info["updated"] else None
    installer = field("installerPackageName")
    if installer in (None, "null"):
        info["installer"] = "מותקנת מראש" if "/system/" in section or "/product/" in section else "לא ידוע"
    else:
        info["installer"] = INSTALLERS.get(installer, installer)
    info["permissions"] = len(re.findall(r"^\s+[\w.]+\.permission\.[\w.]+: granted=true",
                                         section, re.M))
    code_path = field("codePath")
    if code_path:
        du = run_adb("shell", f"du -sk {shlex.quote(code_path)}", serial=serial, timeout=15)[1]
        size = du.split()[0] if du.split() else ""
        info["size"] = int(size) * 1024 if size.isdigit() else None
    return info


def app_action(serial, package, action, system=False):
    package = check_package(package)
    q = shlex.quote(package)
    if action == "launch":
        out = shell(serial, f"monkey -p {q} -c android.intent.category.LAUNCHER 1")
        if "No activities found" in out:
            raise AdbError("לאפליקציה הזו אין מסך פתיחה")
        return "האפליקציה נפתחה"
    if action == "stop":
        shell(serial, f"am force-stop {q}")
        return "האפליקציה נעצרה"
    if action == "clear":
        out = shell(serial, f"pm clear {q}")
        if "Success" not in out:
            raise AdbError("לא ניתן לנקות את הנתונים של האפליקציה הזו")
        return "נתוני האפליקציה נוקו"
    if action == "disable":
        out = shell(serial, f"pm disable-user --user 0 {q}")
        if "disabled" not in out:
            raise AdbError(friendly(out) if out.strip() else "לא ניתן להשבית את האפליקציה")
        return "האפליקציה הושבתה"
    if action == "enable":
        out = shell(serial, f"pm enable {q}")
        if "enabled" not in out:
            raise AdbError(friendly(out) if out.strip() else "לא ניתן להפעיל את האפליקציה")
        return "האפליקציה הופעלה מחדש"
    if action == "restore":
        out = shell(serial, f"cmd package install-existing {q} || pm install-existing {q}")
        if "installed" not in out.lower():
            raise AdbError(friendly(out) if out.strip() else "השחזור נכשל")
        return "האפליקציה שוחזרה"
    if action == "uninstall":
        if system:
            out = shell(serial, f"pm uninstall -k --user 0 {q}")
        else:
            _, out, err = run_adb("uninstall", package, serial=serial, timeout=60)
            out += err
        if "Success" not in out:
            raise AdbError(friendly(out) if out.strip() else "ההסרה נכשלה")
        return "האפליקציה הוסרה"
    raise AdbError("פעולה לא מוכרת")


def install_package(serial, local):
    """מתקין APK רגיל, או חבילה מפוצלת (‎.apks / .xapk) עם install-multiple."""
    suffix = local.suffix.lower()
    if suffix == ".apk":
        _, out, err = run_adb("install", "-r", str(local), serial=serial, timeout=900)
    elif suffix in (".apks", ".xapk", ".apkm", ".zip"):
        parts_dir = local.parent / "parts"
        parts_dir.mkdir()
        parts = []
        try:
            with zipfile.ZipFile(local) as zf:
                for i, member in enumerate(n for n in zf.namelist() if n.lower().endswith(".apk")):
                    target = parts_dir / f"{i:03d}.apk"
                    target.write_bytes(zf.read(member))
                    parts.append(str(target))
        except zipfile.BadZipFile:
            raise AdbError("הקובץ פגום או מוצפן (APKM מוצפן אינו נתמך)")
        if not parts:
            raise AdbError("לא נמצאו קבצי APK בתוך החבילה")
        _, out, err = run_adb("install-multiple", "-r", *parts, serial=serial, timeout=900)
    else:
        raise AdbError("ניתן להתקין קבצי APK, APKS או XAPK")
    if "Success" not in out + err:
        raise AdbError(friendly(out + err))


def apk_path(serial, package):
    out = shell(serial, f"pm path {shlex.quote(check_package(package))}")
    paths = [l.split(":", 1)[1].strip() for l in out.splitlines() if l.startswith("package:")]
    if not paths:
        raise AdbError("קובץ ה-APK לא נמצא")
    base = [p for p in paths if p.endswith("/base.apk")]
    return (base or paths)[0]


# ─────────────────────────── קבצים ───────────────────────────


def clean_remote(path):
    path = (path or "").strip() or "/sdcard"
    if not path.startswith("/"):
        raise AdbError("נתיב לא תקין")
    return path


def list_files(serial, path):
    path = clean_remote(path)
    script = (f"cd {shlex.quote(path)} || exit 7; "
              "stat -L -c '%f|%s|%Y|%n' -- * .* 2>/dev/null; exit 0")
    code, out, err = run_adb("shell", script, serial=serial, timeout=30)
    if code != 0 or err.strip():
        raise AdbError(friendly(err) if err.strip() else "לא ניתן לפתוח את התיקייה")
    entries = []
    for line in out.splitlines():
        parts = line.split("|", 3)
        if len(parts) != 4 or parts[3] in (".", "..", "*", ".*"):
            continue
        try:
            mode = int(parts[0], 16)
            entries.append({
                "name": parts[3],
                "dir": stat.S_ISDIR(mode),
                "size": int(parts[1]),
                "mtime": int(parts[2]),
            })
        except ValueError:
            continue
    entries.sort(key=lambda e: (not e["dir"], e["name"].lower()))
    return {"path": path, "entries": entries}


def rename_file(serial, path, new_name):
    path = clean_remote(path)
    new_name = (new_name or "").strip()
    if not new_name or "/" in new_name or new_name in (".", ".."):
        raise AdbError("שם לא תקין")
    target = path.rstrip("/").rsplit("/", 1)[0] + "/" + new_name
    out = shell(serial, f"[ -e {shlex.quote(target)} ] && echo EXISTS || "
                        f"mv -- {shlex.quote(path)} {shlex.quote(target)}")
    if "EXISTS" in out:
        raise AdbError("כבר קיים קובץ בשם הזה")


# ───────────────────────── הורדת רכיבים ─────────────────────────


def download(url, target):
    request = urllib.request.Request(url, headers={"User-Agent": "ADB-Studio"})
    try:
        with urllib.request.urlopen(request, timeout=60) as resp, open(target, "wb") as fh:
            shutil.copyfileobj(resp, fh)
    except OSError as exc:
        raise AdbError(f"ההורדה נכשלה — בדקו את חיבור האינטרנט ({exc})")


def safe_extract(archive, dest):
    """חילוץ zip / tar.gz בלי לאפשר כתיבה מחוץ לתיקיית היעד."""
    dest = dest.resolve()
    if archive.suffix == ".zip":
        with zipfile.ZipFile(archive) as zf:
            if any(not (dest / n).resolve().is_relative_to(dest) for n in zf.namelist()):
                raise AdbError("קובץ ההורדה לא תקין")
            zf.extractall(dest)
    else:
        with tarfile.open(archive) as tf:
            for m in tf.getmembers():
                if not (dest / m.name).resolve().is_relative_to(dest) or m.issym() or m.islnk():
                    raise AdbError("קובץ ההורדה לא תקין")
            tf.extractall(dest)


def install_scrcpy():
    request = urllib.request.Request(
        "https://api.github.com/repos/Genymobile/scrcpy/releases/latest",
        headers={"User-Agent": "ADB-Studio", "Accept": "application/vnd.github+json"})
    try:
        with urllib.request.urlopen(request, timeout=30) as resp:
            release = json.load(resp)
    except OSError as exc:
        raise AdbError(f"לא ניתן לבדוק גרסה עדכנית ({exc})")
    machine = platform.machine().lower()
    if IS_WINDOWS:
        key = "win64" if sys.maxsize > 2 ** 32 else "win32"
    elif IS_MAC:
        key = "macos-aarch64" if machine in ("arm64", "aarch64") else "macos-x86_64"
    elif machine in ("x86_64", "amd64"):
        key = "linux-x86_64"
    else:
        raise AdbError("אין גרסה מוכנה של רכיב השיקוף למחשב הזה — התקינו scrcpy ידנית")
    asset = next((a for a in release.get("assets", [])
                  if a["name"].startswith(f"scrcpy-{key}-")
                  and a["name"].endswith((".zip", ".tar.gz"))), None)
    if not asset:
        raise AdbError("לא נמצאה הורדה מתאימה")
    tmp = Path(tempfile.mkdtemp(prefix="adb-studio-"))
    try:
        archive = tmp / ("scrcpy.zip" if asset["name"].endswith(".zip") else "scrcpy.tar.gz")
        download(asset["browser_download_url"], archive)
        out = tmp / "out"
        out.mkdir()
        safe_extract(archive, out)
        folders = [p for p in out.iterdir() if p.is_dir()]
        source = folders[0] if len(folders) == 1 else out
        shutil.rmtree(USER_SCRCPY_DIR, ignore_errors=True)
        USER_SCRCPY_DIR.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(source), str(USER_SCRCPY_DIR))
        if not IS_WINDOWS:
            for name in ("scrcpy", "adb"):
                exe = USER_SCRCPY_DIR / name
                if exe.exists():
                    exe.chmod(exe.stat().st_mode | 0o755)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    global _scrcpy_path
    _scrcpy_path = None
    if not scrcpy_path():
        raise AdbError("ההתקנה הסתיימה אבל רכיב השיקוף לא נמצא")


def install_platform_tools():
    osname = "windows" if IS_WINDOWS else "darwin" if IS_MAC else "linux"
    url = f"https://dl.google.com/android/repository/platform-tools-latest-{osname}.zip"
    tmp = Path(tempfile.mkdtemp(prefix="adb-studio-"))
    try:
        archive = tmp / "platform-tools.zip"
        download(url, archive)
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        safe_extract(archive, DATA_DIR)
        if not IS_WINDOWS:
            for name in ("adb", "fastboot"):
                exe = USER_TOOLS_DIR / name
                if exe.exists():
                    exe.chmod(exe.stat().st_mode | 0o755)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    global _adb_path
    _adb_path = None
    if not adb_path():
        raise AdbError("ההתקנה הסתיימה אבל ADB לא נמצא")


# ─────────────────────────── שיקוף מסך ───────────────────────────

MIRRORS = {}  # serial -> {"proc", "log", "record"}

QUALITY = {
    "high": ["--video-bit-rate=16M"],
    "balanced": ["--max-size=1920", "--video-bit-rate=8M"],
    "saver": ["--max-size=1024", "--video-bit-rate=2M", "--max-fps=30"],
}


def media_dir():
    base = Path.home() / "Videos"
    folder = (base if base.is_dir() else Path.home()) / "ADB Studio"
    folder.mkdir(parents=True, exist_ok=True)
    return folder


def mirror_running(serial):
    entry = MIRRORS.get(serial)
    return bool(entry) and entry["proc"].poll() is None


def start_mirror(serial, opts, title):
    exe = scrcpy_path()
    if not exe:
        raise AdbError("רכיב שיקוף המסך לא מותקן")
    if mirror_running(serial):
        return None
    args = [exe, "--serial", serial, f"--window-title={title}", "--shortcut-mod=lctrl"]
    args += QUALITY.get(opts.get("quality"), QUALITY["balanced"])
    if opts.get("screenOff"):
        args.append("--turn-screen-off")
    if opts.get("stayAwake"):
        args.append("--stay-awake")
    if not opts.get("audio", True):
        args.append("--no-audio")
    if opts.get("readOnly"):
        args.append("--no-control")
    record = None
    if opts.get("record"):
        record = media_dir() / f"הקלטת מסך {time.strftime('%Y-%m-%d %H-%M-%S')}.mkv"
        args.append(f"--record={record}")
    env = dict(os.environ)
    if adb_path():
        env["ADB"] = adb_path()  # אותה גרסת adb — בלי התנגשויות שרת
    log = tempfile.TemporaryFile()
    proc = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                            env=env, cwd=str(Path(exe).parent), creationflags=NO_WINDOW)
    # scrcpy נכשל מהר אם משהו לא בסדר — מחכים רגע כדי להחזיר שגיאה ברורה
    for _ in range(25):
        if proc.poll() is not None:
            log.seek(0)
            text = log.read().decode("utf-8", "replace")
            errors = [l.split(":", 1)[-1].strip() for l in text.splitlines() if "ERROR" in l]
            raise AdbError("השיקוף נכשל: " + (errors[-1] if errors else text.strip()[-300:] or "שגיאה לא ידועה"))
        time.sleep(0.1)
    MIRRORS[serial] = {"proc": proc, "log": log, "record": str(record) if record else None}
    return record


def stop_mirror(serial):
    entry = MIRRORS.pop(serial, None)
    if entry and entry["proc"].poll() is None:
        entry["proc"].terminate()
        try:
            entry["proc"].wait(5)  # נותנים ל-scrcpy לסגור את קובץ ההקלטה כראוי
        except subprocess.TimeoutExpired:
            entry["proc"].kill()
    return entry["record"] if entry else None


KEYS = {
    "home": 3, "back": 4, "recents": 187, "power": 26, "volup": 24, "voldown": 25,
    "mute": 164, "wake": 224, "play": 85, "next": 87, "prev": 88,
}


def open_folder(path):
    if IS_WINDOWS:
        os.startfile(path)  # noqa: S606
    else:
        subprocess.Popen(["open" if IS_MAC else "xdg-open", str(path)],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


# ─────────────────────────── שרת ───────────────────────────


class Handler(BaseHTTPRequestHandler):
    server_version = "ADBStudio/1.0"

    def log_message(self, fmt, *args):  # שקט בקונסול
        pass

    # ---- עזרים ----
    def send_json(self, data, status=HTTPStatus.OK):
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def send_error_json(self, message, status=HTTPStatus.BAD_REQUEST):
        self.send_json({"error": message}, status)

    def send_bytes(self, data, content_type, filename=None):
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        if filename:
            self.send_header("Content-Disposition",
                             f"attachment; filename*=UTF-8''{quote(filename)}")
        self.end_headers()
        self.wfile.write(data)

    def send_file(self, path, filename, inline=False):
        size = path.stat().st_size
        self.send_response(HTTPStatus.OK)
        kind = (mimetypes.guess_type(filename)[0] if inline else None) or "application/octet-stream"
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(size))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Disposition",
                         f"{'inline' if inline else 'attachment'}; filename*=UTF-8''{quote(filename)}")
        self.end_headers()
        with open(path, "rb") as fh:
            shutil.copyfileobj(fh, self.wfile)

    def host_ok(self):
        port = self.server.server_address[1]
        return self.headers.get("Host") in (f"127.0.0.1:{port}", f"localhost:{port}")

    def token_ok(self, query):
        given = self.headers.get("X-Token") or query.get("token", [""])[0]
        return secrets.compare_digest(given, TOKEN)

    def read_json(self):
        length = int(self.headers.get("Content-Length") or 0)
        if not length:
            return {}
        try:
            return json.loads(self.rfile.read(length).decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            raise AdbError("בקשה לא תקינה")

    def receive_upload(self, query):
        name = os.path.basename(query.get("name", ["file"])[0].replace("\\", "/")).strip()
        if not name or name in (".", ".."):
            raise AdbError("שם קובץ לא תקין")
        length = int(self.headers.get("Content-Length") or 0)
        tmpdir = Path(tempfile.mkdtemp(prefix="adb-studio-"))
        target = tmpdir / name
        remaining = length
        with open(target, "wb") as fh:
            while remaining > 0:
                chunk = self.rfile.read(min(1 << 20, remaining))
                if not chunk:
                    break
                fh.write(chunk)
                remaining -= len(chunk)
        return tmpdir, target

    # ---- ניתוב ----
    def handle_any(self, method):
        url = urlparse(self.path)
        query = parse_qs(url.query)
        if not self.host_ok():
            return self.send_error_json("גישה נדחתה", HTTPStatus.FORBIDDEN)
        if not url.path.startswith("/api/"):
            return self.serve_static(url.path) if method == "GET" else \
                self.send_error_json("לא נמצא", HTTPStatus.NOT_FOUND)
        if not self.token_ok(query):
            return self.send_error_json("גישה נדחתה", HTTPStatus.FORBIDDEN)
        global last_seen
        last_seen = time.monotonic()
        route = url.path[len("/api/"):]
        handler = ROUTES.get((method, route))
        if not handler:
            return self.send_error_json("לא נמצא", HTTPStatus.NOT_FOUND)
        try:
            if method == "POST":
                result = handler(self, self.read_json())
            else:
                result = handler(self, {k: v[0] for k, v in query.items()})
            if result is not None:
                self.send_json(result)
        except AdbError as exc:
            self.send_error_json(str(exc))
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as exc:  # noqa: BLE001 — מציגים למשתמש ולא קורסים
            self.send_error_json(f"שגיאה לא צפויה: {exc}", HTTPStatus.INTERNAL_SERVER_ERROR)

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")

    def do_PUT(self):
        self.handle_any("PUT")

    def serve_static(self, path):
        if path in ("", "/"):
            path = "/index.html"
        target = (WEB_DIR / path.lstrip("/")).resolve()
        if not target.is_relative_to(WEB_DIR) or not target.is_file():
            return self.send_error_json("לא נמצא", HTTPStatus.NOT_FOUND)
        self.send_bytes(target.read_bytes(), MIME.get(target.suffix, "application/octet-stream"))


def route(method, path):
    def wrap(fn):
        ROUTES[(method, path)] = fn
        return fn
    return wrap


ROUTES = {}


def need_serial(data):
    serial = (data.get("serial") or "").strip()
    if not serial:
        raise AdbError("לא נבחר מכשיר")
    return serial


@route("POST", "status")
def api_status(req, data):
    path = adb_path()
    version = None
    if path:
        _, out, _ = run_adb("version", timeout=10)
        match = re.search(r"^Version ([\d.]+)", out, re.M) or re.search(r"version ([\d.]+)", out)
        version = match.group(1) if match else None
    return {"adb": bool(path), "path": path, "version": version,
            "scrcpy": bool(scrcpy_path()), "os": platform.system()}


@route("POST", "setup")
def api_setup(req, data):
    install_platform_tools()
    return api_status(req, data)


@route("POST", "devices")
def api_devices(req, data):
    return {"devices": list_devices()}


@route("POST", "device/info")
def api_info(req, data):
    return device_info(need_serial(data))


@route("POST", "device/reboot")
def api_reboot(req, data):
    mode = data.get("mode") or ""
    if mode not in ("", "recovery", "bootloader"):
        raise AdbError("מצב הפעלה לא מוכר")
    args = ["reboot"] + ([mode] if mode else [])
    run_adb(*args, serial=need_serial(data), timeout=20)
    return {"message": "המכשיר מופעל מחדש"}


@route("POST", "device/wifi")
def api_wifi(req, data):
    address = switch_to_wifi(need_serial(data))
    return {"message": f"מחובר אלחוטית ל-{address} — אפשר לנתק את הכבל", "serial": address}


@route("POST", "connect")
def api_connect(req, data):
    address = connect(data.get("address"))
    return {"message": f"מחובר ל-{address}", "serial": address}


@route("POST", "pair")
def api_pair(req, data):
    address = (data.get("address") or "").strip()
    if not ADDRESS_RE.match(address) or not re.search(r":\d+$", address):
        raise AdbError("יש להזין כתובת כולל פורט, כפי שמופיע במסך הצימוד")
    code = re.sub(r"\D", "", str(data.get("code") or ""))
    if len(code) != 6:
        raise AdbError("קוד הצימוד צריך להכיל 6 ספרות")
    _, out, err = run_adb("pair", address, code, timeout=30)
    text = (out + err).strip()
    if "Successfully paired" not in text:
        raise AdbError(f"הצימוד נכשל: {text or 'אין תגובה'}")
    return {"message": "הצימוד הצליח! עכשיו התחברו עם הכתובת שמופיעה במסך ניפוי באגים אלחוטי"}


@route("POST", "disconnect")
def api_disconnect(req, data):
    run_adb("disconnect", need_serial(data), timeout=10)
    return {"message": "המכשיר נותק"}


@route("POST", "discover")
def api_discover(req, data):
    return {"devices": discover()}


@route("POST", "qr/start")
def api_qr_start(req, data):
    return qr_start()


@route("POST", "qr/poll")
def api_qr_poll(req, data):
    return qr_poll(data.get("session"))


@route("POST", "device/key")
def api_key(req, data):
    code = KEYS.get(data.get("key"))
    if code is None:
        raise AdbError("מקש לא מוכר")
    shell(need_serial(data), f"input keyevent {code}")
    return {"ok": True}


@route("POST", "mirror/setup")
def api_mirror_setup(req, data):
    install_scrcpy()
    return {"message": "רכיב שיקוף המסך הותקן"}


@route("POST", "mirror/start")
def api_mirror_start(req, data):
    serial = need_serial(data)
    record = start_mirror(serial, data.get("options") or {}, data.get("title") or APP_NAME)
    return {"message": "השיקוף נפתח בחלון נפרד" + (" ומוקלט" if record else ""),
            "record": str(record) if record else None}


@route("POST", "mirror/stop")
def api_mirror_stop(req, data):
    record = stop_mirror(need_serial(data))
    return {"message": "השיקוף נסגר" + (" — ההקלטה נשמרה" if record else ""), "record": record}


@route("POST", "mirror/status")
def api_mirror_status(req, data):
    serial = need_serial(data)
    running = mirror_running(serial)
    if not running and serial in MIRRORS:  # המשתמש סגר את החלון בעצמו
        MIRRORS.pop(serial)
    return {"running": running, "installed": bool(scrcpy_path())}


@route("POST", "open-media")
def api_open_media(req, data):
    open_folder(media_dir())
    return {"message": "התיקייה נפתחה"}


@route("POST", "apps")
def api_apps(req, data):
    return {"apps": list_apps(need_serial(data))}


@route("POST", "apps/info")
def api_app_info(req, data):
    return app_info(need_serial(data), data.get("package"))


@route("POST", "apps/action")
def api_app_action(req, data):
    message = app_action(need_serial(data), data.get("package"), data.get("action"),
                         bool(data.get("system")))
    return {"message": message}


@route("GET", "apps/apk")
def api_app_apk(req, data):
    serial = need_serial(data)
    package = check_package(data.get("package"))
    remote = apk_path(serial, package)
    tmpdir = Path(tempfile.mkdtemp(prefix="adb-studio-"))
    try:
        local = tmpdir / f"{package}.apk"
        adb_ok("pull", remote, str(local), serial=serial, timeout=600)
        req.send_file(local, local.name)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


@route("PUT", "apps/install")
def api_install(req, data):
    serial = need_serial(data)
    tmpdir, apk = req.receive_upload({"name": [data.get("name", "app.apk")]})
    try:
        install_package(serial, apk)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)
    return {"message": f"{apk.name} הותקן בהצלחה"}


@route("POST", "files/list")
def api_files(req, data):
    return list_files(need_serial(data), data.get("path"))


@route("POST", "files/delete")
def api_delete(req, data):
    path = clean_remote(data.get("path"))
    if path.rstrip("/") in ("", "/sdcard", "/storage/emulated/0", "/storage", "/data", "/system"):
        raise AdbError("לא ניתן למחוק תיקייה זו")
    shell(need_serial(data), f"rm -rf -- {shlex.quote(path)}")
    return {"message": "נמחק"}


@route("POST", "files/rename")
def api_rename(req, data):
    rename_file(need_serial(data), data.get("path"), data.get("name"))
    return {"message": "השם שונה"}


@route("POST", "files/mkdir")
def api_mkdir(req, data):
    path = clean_remote(data.get("path"))
    shell(need_serial(data), f"mkdir -p -- {shlex.quote(path)}")
    return {"message": "התיקייה נוצרה"}


@route("PUT", "files/upload")
def api_upload(req, data):
    serial = need_serial(data)
    directory = clean_remote(data.get("dir")).rstrip("/") or ""
    tmpdir, local = req.receive_upload({"name": [data.get("name", "file")]})
    try:
        adb_ok("push", str(local), f"{directory}/{local.name}", serial=serial, timeout=1800)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)
    return {"message": f"{local.name} הועלה"}


@route("GET", "files/pull")
def api_pull(req, data):
    serial = need_serial(data)
    remote = clean_remote(data.get("path"))
    name = os.path.basename(remote.rstrip("/")) or "file"
    tmpdir = Path(tempfile.mkdtemp(prefix="adb-studio-"))
    try:
        local = tmpdir / name
        adb_ok("pull", remote, str(local), serial=serial, timeout=3600)
        if local.is_dir():  # תיקייה שלמה — נשלחת כ-zip
            local = Path(shutil.make_archive(str(tmpdir / name), "zip", local))
            name = local.name
        elif not local.is_file():
            raise AdbError("ההורדה נכשלה")
        req.send_file(local, name, inline=bool(data.get("inline")))
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


@route("GET", "screenshot")
def api_screenshot(req, data):
    code, png, err = run_adb("exec-out", "screencap", "-p",
                             serial=need_serial(data), timeout=30, binary=True)
    if code != 0 or not png.startswith(b"\x89PNG"):
        raise AdbError(friendly(err) if err.strip() else "צילום המסך נכשל")
    stamp = time.strftime("%Y-%m-%d_%H-%M-%S")
    req.send_bytes(png, "image/png", f"screenshot_{stamp}.png"
                   if data.get("download") else None)


@route("POST", "shell")
def api_shell(req, data):
    command = (data.get("command") or "").strip()
    if not command:
        raise AdbError("לא הוזנה פקודה")
    code, out, err = run_adb("shell", command, serial=need_serial(data), timeout=60)
    return {"output": (out + err).rstrip("\n"), "code": code}


# ─────────────────────────── הפעלה ───────────────────────────


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def browser_candidates():
    if IS_WINDOWS:
        roots = [os.environ.get(v) for v in ("PROGRAMFILES", "PROGRAMFILES(X86)", "LOCALAPPDATA")]
        subpaths = [r"Microsoft\Edge\Application\msedge.exe",
                    r"Google\Chrome\Application\chrome.exe",
                    r"BraveSoftware\Brave-Browser\Application\brave.exe"]
        return [str(Path(r) / s) for s in subpaths for r in roots if r]
    if IS_MAC:
        return ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
                "/Applications/Chromium.app/Contents/MacOS/Chromium",
                "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"]
    names = ["google-chrome", "google-chrome-stable", "chromium", "chromium-browser",
             "microsoft-edge", "brave-browser"]
    return [p for p in (shutil.which(n) for n in names) if p]


def open_app_window(url):
    """פותח חלון אפליקציה נקי (בלי שורת כתובת). מחזיר את התהליך או None."""
    profile = DATA_DIR / "window"
    profile.mkdir(parents=True, exist_ok=True)
    for exe in browser_candidates():
        if not Path(exe).is_file():
            continue
        try:
            return subprocess.Popen(
                [exe, f"--app={url}", f"--user-data-dir={profile}", "--window-size=1280,840",
                 "--no-first-run", "--no-default-browser-check", "--disable-sync"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
        except OSError:
            continue
    webbrowser.open(url)
    return None


def say(text):
    try:
        print(text, flush=True)
    except (UnicodeEncodeError, AttributeError, OSError):
        pass


def main():
    if hasattr(sys.stdout, "reconfigure"):
        try:
            sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        except (ValueError, OSError):
            pass
    no_window = "--no-window" in sys.argv
    port = free_port()
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.daemon_threads = True
    url = f"http://127.0.0.1:{port}/?token={TOKEN}"
    threading.Thread(target=server.serve_forever, daemon=True).start()
    say(f"{APP_NAME} פועל בכתובת: {url}")

    window = None if no_window else open_app_window(url)
    try:
        if window:
            opened = time.monotonic()
            say("סגרו את החלון כדי לצאת.")
            window.wait()
            # הדפדפן העביר את החלון לתהליך קיים — ממשיכים לרוץ עד Ctrl+C
            if time.monotonic() - opened > 5:
                return
        say("לחצו Ctrl+C כדי לצאת.")
        # נסגר לבד כשהחלון נסגר (אין יותר פניות מהממשק)
        while no_window or not last_seen or time.monotonic() - last_seen < IDLE_EXIT:
            time.sleep(5)
    except KeyboardInterrupt:
        pass
    finally:
        server.shutdown()


if __name__ == "__main__":
    main()
