#!/usr/bin/env python3
"""
בדיקת קצה-לקצה מול מחסנית הרשת האמיתית של הליבה: יוצר התקן tun, מעביר אליו את
החבילות לקוד ה-Java האמיתי (PacketHandler/DnsEngine/Forwarder), ושולח שאילתות
UDP / TCP / ICMP רגילות. דורש root ו-/dev/net/tun. שימוש: e2e_tun.py <classes-dir>
"""
import fcntl, os, socket, struct, subprocess, sys, threading, time

CLASSES = sys.argv[1]
IF, FAKE = b"adb0", "10.111.222.2"

tun = os.open("/dev/net/tun", os.O_RDWR)
fcntl.ioctl(tun, 0x400454CA, struct.pack("16sH", IF, 0x1001))   # TUNSETIFF, IFF_TUN|IFF_NO_PI
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
def ifreq(code, payload):
    fcntl.ioctl(s, code, struct.pack("16s", IF) + payload)
sa = lambda ip: struct.pack("H2s4s8x", socket.AF_INET, b"\0\0", socket.inet_aton(ip))
ifreq(0x8916, sa("10.111.222.1"))        # SIOCSIFADDR
ifreq(0x891C, sa("255.255.255.0"))       # SIOCSIFNETMASK
ifreq(0x8914, struct.pack("H", 0x41) + b"\0" * 14)  # SIOCSIFFLAGS UP|RUNNING

java = subprocess.Popen(["java", "-cp", CLASSES, "com.adblock.app.Bridge"],
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=open("/tmp/bridge.err", "w"))
def tun_to_java():
    while True:
        try: pkt = os.read(tun, 65535)
        except OSError: return
        java.stdin.write(struct.pack("!H", len(pkt)) + pkt); java.stdin.flush()
def java_to_tun():
    while True:
        h = java.stdout.read(2)
        if len(h) < 2: return
        n = struct.unpack("!H", h)[0]
        os.write(tun, java.stdout.read(n))
for f in (tun_to_java, java_to_tun): threading.Thread(target=f, daemon=True).start()
time.sleep(1.5)

def query(name, qtype=1, edns=True):
    qn = b"".join(bytes([len(l)]) + l.encode() for l in name.split(".")) + b"\0"
    q = b"\xab\xcd\x01\x00\x00\x01\x00\x00\x00\x00\x00" + (b"\x01" if edns else b"\x00") + qn + struct.pack("!HH", qtype, 1)
    if edns: q += b"\x00\x00\x29\x04\xd0\x00\x00\x00\x00\x00\x00"
    return q
def rcode_an(r): return r[3] & 15, struct.unpack("!H", r[6:8])[0]
def udp(name, qtype=1, dst=FAKE, edns=True):
    c = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); c.settimeout(6)
    c.sendto(query(name, qtype, edns), (dst, 53)); return c.recv(8192)
def tcp_conn(dst=FAKE, port=53):
    c = socket.socket(); c.settimeout(6); c.connect((dst, port)); return c
def tcp_query(c, name, qtype=1):
    q = query(name, qtype); c.sendall(struct.pack("!H", len(q)) + q)
    n = struct.unpack("!H", c.recv(2))[0]; r = b""
    while len(r) < n: r += c.recv(n - len(r))
    return r

fails = []
def check(label, cond, extra=""):
    print(("PASS " if cond else "FAIL ") + label, extra); 
    if not cond: fails.append(label)

r = udp("ads.doubleclick.net");                       check("UDP blocked -> 0.0.0.0", rcode_an(r) == (0, 1) and r[-4:] == b"\0\0\0\0")
r = udp("x.tracker.example", 28);                     check("UDP blocked AAAA -> ::", rcode_an(r) == (0, 1) and r[-16:] == bytes(16))
r = udp("example.com");                               check("UDP forwarded example.com", rcode_an(r)[0] == 0 and rcode_an(r)[1] >= 1, rcode_an(r))
r = udp("example.com");                               check("UDP cached repeat", rcode_an(r)[1] >= 1)
r = udp("example.com", dst="10.111.222.77");          check("UDP to 'hijacked' IP answered", rcode_an(r)[1] >= 1)
r = udp("use-application-dns.net");                   check("Firefox DoH canary -> NXDOMAIN", rcode_an(r)[0] == 3)
r = udp("dns.google");                                check("DoH hostname dns.google blocked", rcode_an(r) == (0, 1) and r[-4:] == b"\0\0\0\0")
def upstream_tcp_ok():
    try: socket.create_connection(("1.1.1.1", 53), timeout=3).close(); return True
    except OSError: return False
HAVE_TCP_UP = upstream_tcp_ok()
if HAVE_TCP_UP:
    r = udp("google.com", 16, edns=False);            check("UDP TXT without EDNS (TC->TCP upstream)", rcode_an(r)[0] == 0 and rcode_an(r)[1] >= 1, (len(r), rcode_an(r)))
else:
    print("SKIP UDP TC->TCP upstream fallback (this sandbox blocks TCP/53 egress)")

c = tcp_conn()
r = tcp_query(c, "ads.doubleclick.net");              check("TCP blocked", rcode_an(r) == (0, 1))
r = tcp_query(c, "example.com");                      check("TCP forwarded (2nd query same conn)", rcode_an(r)[1] >= 1)
r = tcp_query(c, "google.com", 16);                   check("TCP large TXT", rcode_an(r)[1] >= 1 or not HAVE_TCP_UP, len(r))
c.close(); time.sleep(0.3)
c = tcp_conn("10.111.222.50"); r = tcp_query(c, "ads.doubleclick.net"); check("TCP to other routed IP", rcode_an(r) == (0, 1)); c.close()

t0 = time.time()
try: tcp_conn(port=443); check("TCP 443 refused quickly", False)
except ConnectionRefusedError: check("TCP 443 refused quickly (RST)", time.time() - t0 < 2, f"{time.time()-t0:.2f}s")
except Exception as e: check("TCP 443 refused quickly", False, e)
try: tcp_conn(port=853); check("TCP 853 (DoT) refused", False)
except ConnectionRefusedError: check("TCP 853 (DoT) refused", True)

# ---- עומס: 300 שאילתות UDP + 60 חיבורי TCP במקביל
import concurrent.futures as cf
def one_udp(i):
    n = ["ads.doubleclick.net", "example.com", "x%d.tracker.example" % i, "example.org"][i % 4]
    r = udp(n); return (r[3] & 15) == 0
def one_tcp(i):
    c = tcp_conn(); ok = True
    for n in ("ads.doubleclick.net", "example.com"):
        ok &= (tcp_query(c, n)[3] & 15) == 0
    c.close(); return ok
with cf.ThreadPoolExecutor(40) as ex:
    res_u = list(ex.map(one_udp, range(300))); res_t = list(ex.map(one_tcp, range(60)))
check("stress: 300 parallel UDP queries", all(res_u), f"{sum(res_u)}/300")
check("stress: 60 parallel TCP connections x2 queries", all(res_t), f"{sum(res_t)}/60")

ic = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_ICMP); ic.settimeout(3)
body = struct.pack("!BBHHH", 8, 0, 0, 0x1234, 1) + b"ping-test"
def cs(b):
    if len(b) % 2: b += b"\0"
    t = sum(struct.unpack("!%dH" % (len(b)//2), b)); t = (t & 0xFFFF) + (t >> 16); t = (t & 0xFFFF) + (t >> 16); return ~t & 0xFFFF
body = body[:2] + struct.pack("!H", cs(body)) + body[4:]
ic.sendto(body, (FAKE, 0)); got = False
try:
    while True:
        d = ic.recv(512); ip = (d[0] & 15) * 4
        if d[ip] == 0 and d[12:16] == socket.inet_aton(FAKE): got = True; break
except socket.timeout: pass
check("ICMP echo reply", got)

java.stdin.close(); time.sleep(0.3)
print("\nRESULT:", "ALL PASSED" if not fails else f"{len(fails)} FAILED: {fails}")
sys.exit(1 if fails else 0)
