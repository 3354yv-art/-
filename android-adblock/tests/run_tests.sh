#!/bin/bash
# בדיקות הליבה הטהורה ב-JVM: יחידה + (אם יש root ו-/dev/net/tun) קצה-לקצה מול מחסנית TCP/IP אמיתית.
set -e
SRC="$(cd "$(dirname "$0")/.." && pwd)/app/src/main/java/com/adblock/app"
T="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
javac -Xlint:all -d "$OUT" "$SRC"/{DnsCore,DnsEngine,PacketHandler,Forwarder,ListParser,DomainSet}.java "$T"/UnitTests.java "$T"/Bridge.java 2>&1 | grep -v "Picked up" || true
java -cp "$OUT" com.adblock.app.UnitTests 2>&1 | grep -v "Picked up"
if [ -w /dev/net/tun ] && [ "$(id -u)" = 0 ]; then
  python3 "$T/e2e_tun.py" "$OUT" 2>&1 | grep -v "Picked up"
else
  echo "SKIP e2e (צריך root ו-/dev/net/tun)"
fi
