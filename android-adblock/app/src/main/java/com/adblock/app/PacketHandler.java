package com.adblock.app;

import java.io.ByteArrayOutputStream;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Random;
import java.util.concurrent.Executor;

/**
 * מעבד חבילות IP שמגיעות מה-tun: DNS מעל UDP, DNS מעל TCP (מימוש TCP מינימלי),
 * ICMP echo, ו-RST מיידי לכל TCP אחר (כדי שעקיפות DoH/DoT ייכשלו מהר ואפליקציות
 * יחזרו ל-DNS של המערכת). טהור - ניתן לבדיקה ב-JVM.
 */
final class PacketHandler {
    interface Sink { void write(byte[] packet); }

    private static final int FIN = 1, SYN = 2, RST = 4, PSH = 8, ACK = 16;
    private static final int MSS = 1360;

    private final DnsEngine engine;
    private final Sink sink;
    private final Executor executor;
    private final Random rnd = new Random();

    private static final class Conn {
        long isn;           // ה-ISN שלנו
        long expected;      // ה-seq הבא שמצפים לו מהלקוח
        long ourSeq;        // ה-seq הבא שלנו
        final ByteArrayOutputStream buf = new ByteArrayOutputStream();
        boolean closed;
    }

    private final Map<String, Conn> conns = new LinkedHashMap<String, Conn>(16, 0.75f, true) {
        @Override protected boolean removeEldestEntry(Map.Entry<String, Conn> e) { return size() > 256; }
    };

    PacketHandler(DnsEngine engine, Sink sink, Executor executor) {
        this.engine = engine;
        this.sink = sink;
        this.executor = executor;
    }

    // ------------------------------------------------------------ entry

    void handle(byte[] p, int n) {
        if (n < 20 || (p[0] >> 4) != 4) return;
        int ihl = (p[0] & 0x0F) * 4;
        int total = ((p[2] & 0xFF) << 8) | (p[3] & 0xFF);
        if (ihl < 20 || total < ihl || total > n) total = n;
        int fragOff = ((p[6] & 0x1F) << 8) | (p[7] & 0xFF);
        if (fragOff != 0) return; // רק פרגמנט ראשון
        switch (p[9]) {
            case 17: handleUdp(p, ihl, total); break;
            case 6:  handleTcp(p, ihl, total); break;
            case 1:  handleIcmp(p, ihl, total); break;
            default: break;
        }
    }

    // ------------------------------------------------------------ UDP

    private void handleUdp(final byte[] p, final int ihl, int total) {
        if (total < ihl + 8) return;
        int dport = u16(p, ihl + 2);
        if (dport != 53) return;                       // UDP אחר (QUIC/DoH3/DoT...) - נשמט
        int len = Math.min(u16(p, ihl + 4), total - ihl);
        final int off = ihl + 8, dlen = len - 8;
        if (dlen < 12) return;
        final byte[] q = new byte[dlen];
        System.arraycopy(p, off, q, 0, dlen);
        executor.execute(() -> {
            try {
                byte[] ans = engine.handle(q);
                sink.write(DnsCore.buildUdpReply(p, ihl, ans));
            } catch (Throwable ignored) { }
        });
    }

    // ------------------------------------------------------------ ICMP

    private void handleIcmp(byte[] p, int ihl, int total) {
        if (total < ihl + 8 || p[ihl] != 8) return;    // רק echo request
        byte[] r = new byte[total];
        System.arraycopy(p, 0, r, 0, total);
        System.arraycopy(p, 16, r, 12, 4);
        System.arraycopy(p, 12, r, 16, 4);
        r[8] = 64;
        r[10] = 0; r[11] = 0;
        int c = DnsCore.checksum(r, 0, ihl);
        r[10] = (byte) (c >> 8); r[11] = (byte) c;
        r[ihl] = 0;                                    // echo reply
        r[ihl + 2] = 0; r[ihl + 3] = 0;
        c = DnsCore.checksum(r, ihl, total - ihl);
        r[ihl + 2] = (byte) (c >> 8); r[ihl + 3] = (byte) c;
        sink.write(r);
    }

    // ------------------------------------------------------------ TCP

    private void handleTcp(byte[] p, int ihl, int total) {
        if (total < ihl + 20) return;
        int sport = u16(p, ihl), dport = u16(p, ihl + 2);
        long seq = u32(p, ihl + 4), ack = u32(p, ihl + 8);
        int doff = ((p[ihl + 12] & 0xFF) >> 4) * 4;
        int flags = p[ihl + 13] & 0x3F;
        if (doff < 20 || total < ihl + doff) return;
        int payloadOff = ihl + doff, plen = total - payloadOff;
        if ((flags & RST) != 0) { dropConn(p, sport, dport); return; }

        if (dport != 53) { sendRst(p, ihl, seq, ack, flags, plen); return; }

        final String key = key(p, sport, dport);
        Conn c;
        synchronized (conns) { c = conns.get(key); }

        if ((flags & SYN) != 0 && (flags & ACK) == 0) {
            if (c == null) {
                c = new Conn();
                c.isn = rnd.nextInt() & 0xFFFFFFFFL;
                c.ourSeq = (c.isn + 1) & 0xFFFFFFFFL;
                c.expected = (seq + 1) & 0xFFFFFFFFL;
                synchronized (conns) { conns.put(key, c); }
            }
            sink.write(tcp(p, ihl, c.isn, c.expected, SYN | ACK, null, 0, 0, true));
            return;
        }

        if (c == null) {
            if (plen > 0 || (flags & FIN) != 0) sendRst(p, ihl, seq, ack, flags, plen);
            return;
        }

        boolean finNow = false;
        byte[] complete = null;
        synchronized (c) {
            if (seq == c.expected && plen > 0) {
                c.buf.write(p, payloadOff, plen);
                c.expected = (c.expected + plen) & 0xFFFFFFFFL;
            } else if (seq != c.expected && plen > 0) {
                // כפילות/מחוץ לסדר: נאשר את מה שקיבלנו ונתעלם
                sink.write(tcp(p, ihl, c.ourSeq, c.expected, ACK, null, 0, 0, false));
                return;
            }
            if ((flags & FIN) != 0 && seq + plen == c.expected) {
                c.expected = (c.expected + 1) & 0xFFFFFFFFL;
                finNow = true;
            }
            if (plen > 0 || finNow) {
                sink.write(tcp(p, ihl, c.ourSeq, c.expected, ACK, null, 0, 0, false));
            }
            byte[] b = c.buf.toByteArray();
            if (b.length >= 2) {
                int mlen = ((b[0] & 0xFF) << 8) | (b[1] & 0xFF);
                if (mlen > 0 && b.length >= 2 + mlen) {
                    complete = new byte[mlen];
                    System.arraycopy(b, 2, complete, 0, mlen);
                    c.buf.reset();
                    if (b.length > 2 + mlen) c.buf.write(b, 2 + mlen, b.length - 2 - mlen);
                }
            }
            if (finNow) {
                c.closed = true;
                sink.write(tcp(p, ihl, c.ourSeq, c.expected, FIN | ACK, null, 0, 0, false));
                c.ourSeq = (c.ourSeq + 1) & 0xFFFFFFFFL;
            }
        }
        if (finNow) { synchronized (conns) { conns.remove(key); } }

        if (complete != null) {
            final byte[] query = complete;
            final Conn conn = c;
            final byte[] pkt = p.clone();
            final int fihl = ihl;
            executor.execute(() -> {
                try {
                    byte[] ans = engine.handle(query);
                    byte[] framed = new byte[ans.length + 2];
                    framed[0] = (byte) (ans.length >> 8); framed[1] = (byte) ans.length;
                    System.arraycopy(ans, 0, framed, 2, ans.length);
                    synchronized (conn) {
                        if (conn.closed) return;
                        for (int o = 0; o < framed.length; o += MSS) {
                            int l = Math.min(MSS, framed.length - o);
                            sink.write(tcp(pkt, fihl, conn.ourSeq, conn.expected, ACK | PSH, framed, o, l, false));
                            conn.ourSeq = (conn.ourSeq + l) & 0xFFFFFFFFL;
                        }
                    }
                } catch (Throwable ignored) { }
            });
        }
    }

    private void dropConn(byte[] p, int sport, int dport) {
        synchronized (conns) { conns.remove(key(p, sport, dport)); }
    }

    private static String key(byte[] p, int sport, int dport) {
        return u32(p, 12) + ":" + sport + ">" + u32(p, 16) + ":" + dport;
    }

    /** RST לפי RFC 793 לחבילה שאין לה חיבור. */
    private void sendRst(byte[] p, int ihl, long seq, long ack, int flags, int plen) {
        if ((flags & ACK) != 0) {
            sink.write(tcp(p, ihl, ack, 0, RST, null, 0, 0, false));
        } else {
            long a = (seq + plen + ((flags & SYN) != 0 ? 1 : 0) + ((flags & FIN) != 0 ? 1 : 0)) & 0xFFFFFFFFL;
            sink.write(tcp(p, ihl, 0, a, RST | ACK, null, 0, 0, false));
        }
    }

    /** בונה חבילת TCP כתשובה לחבילה req (src/dst מוחלפים). */
    private static byte[] tcp(byte[] req, int ihl, long seq, long ack, int flags,
                              byte[] data, int dOff, int dLen, boolean mss) {
        int hdr = mss ? 24 : 20;
        int tcpLen = hdr + dLen;
        byte[] r = new byte[20 + tcpLen];
        r[0] = 0x45;
        r[2] = (byte) (r.length >> 8); r[3] = (byte) r.length;
        r[6] = 0x40; r[8] = 64; r[9] = 6;
        System.arraycopy(req, 16, r, 12, 4);
        System.arraycopy(req, 12, r, 16, 4);
        int c = DnsCore.checksum(r, 0, 20);
        r[10] = (byte) (c >> 8); r[11] = (byte) c;
        int t = 20;
        System.arraycopy(req, ihl + 2, r, t, 2);         // src port = dst המקורי
        System.arraycopy(req, ihl, r, t + 2, 2);         // dst port = src המקורי
        put32(r, t + 4, seq);
        put32(r, t + 8, ack);
        r[t + 12] = (byte) ((hdr / 4) << 4);
        r[t + 13] = (byte) flags;
        r[t + 14] = (byte) 0xFF; r[t + 15] = (byte) 0xFF; // window 65535
        if (mss) { r[t + 20] = 2; r[t + 21] = 4; r[t + 22] = (byte) (MSS >> 8); r[t + 23] = (byte) MSS; }
        if (dLen > 0) System.arraycopy(data, dOff, r, t + hdr, dLen);
        // checksum עם pseudo-header
        long sum = 0;
        for (int i = 12; i < 20; i += 2) sum += ((r[i] & 0xFF) << 8) | (r[i + 1] & 0xFF);
        sum += 6 + tcpLen;
        for (int i = 0; i + 1 < tcpLen; i += 2) sum += ((r[t + i] & 0xFF) << 8) | (r[t + i + 1] & 0xFF);
        if ((tcpLen & 1) == 1) sum += (r[t + tcpLen - 1] & 0xFF) << 8;
        while ((sum >> 16) != 0) sum = (sum & 0xFFFF) + (sum >> 16);
        int cs = (int) (~sum & 0xFFFF);
        r[t + 16] = (byte) (cs >> 8); r[t + 17] = (byte) cs;
        return r;
    }

    private static int u16(byte[] b, int o) { return ((b[o] & 0xFF) << 8) | (b[o + 1] & 0xFF); }
    private static long u32(byte[] b, int o) {
        return ((b[o] & 0xFFL) << 24) | ((b[o + 1] & 0xFFL) << 16) | ((b[o + 2] & 0xFFL) << 8) | (b[o + 3] & 0xFFL);
    }
    private static void put32(byte[] b, int o, long v) {
        b[o] = (byte) (v >> 24); b[o + 1] = (byte) (v >> 16); b[o + 2] = (byte) (v >> 8); b[o + 3] = (byte) v;
    }
}
