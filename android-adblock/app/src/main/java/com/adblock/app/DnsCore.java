package com.adblock.app;

import java.util.Set;

/** לוגיקת DNS ו-IP טהורה (ללא תלות באנדרואיד) - ניתנת לבדיקה ב-JVM רגיל. */
final class DnsCore {
    private DnsCore() {}

    /** תוצאת פענוח שאלת DNS. */
    static final class Question {
        final String name;
        final int type;
        final int end; // אינדקס (יחסית לתחילת ה-DNS) שבו נגמרת שאלה
        Question(String name, int type, int end) { this.name = name; this.type = type; this.end = end; }
    }

    /** מפענח את השאלה הראשונה בחבילת DNS ב-[off, off+len). מחזיר null אם פגומה. */
    static Question parseQuestion(byte[] b, int off, int len) {
        try {
            if (len < 17) return null;
            int i = off + 12;
            StringBuilder sb = new StringBuilder();
            while (true) {
                int n = b[i] & 0xFF;
                if (n == 0) { i++; break; }
                if ((n & 0xC0) != 0 || i + n >= off + len) return null;
                if (sb.length() > 0) sb.append('.');
                for (int k = 1; k <= n; k++) sb.append((char) (b[i + k] & 0xFF));
                i += n + 1;
            }
            if (i + 4 > off + len) return null;
            int type = ((b[i] & 0xFF) << 8) | (b[i + 1] & 0xFF);
            return new Question(sb.toString().toLowerCase(), type, i + 4 - off);
        } catch (ArrayIndexOutOfBoundsException e) {
            return null;
        }
    }

    /** חוסם את הדומיין וכל תת-דומיין שלו; הרשימה הלבנה גוברת. */
    static boolean isBlocked(String name, Set<String> blocked, Set<String> allowed) {
        String n = name.toLowerCase();
        if (n.endsWith(".")) n = n.substring(0, n.length() - 1);
        boolean verdict = false;
        int i = 0;
        while (true) {
            String suffix = n.substring(i);
            if (suffix.indexOf('.') < 0) break; // לא בודקים TLD בודד
            if (allowed.contains(suffix)) return false;
            if (blocked.contains(suffix)) verdict = true;
            int dot = n.indexOf('.', i);
            if (dot < 0) break;
            i = dot + 1;
        }
        return verdict;
    }

    /** מילים שבתחילת שם הדומיין כמעט תמיד מסמנות פרסום/מעקב (מצב אגרסיבי בלבד). */
    private static final Set<String> AD_LABELS = new java.util.HashSet<>(java.util.Arrays.asList(
            "ads", "ad", "adserver", "adservice", "adservices", "adsrv", "adtrack", "adtracking", "adx",
            "tracking", "tracker", "trackers", "telemetry", "beacon", "beacons", "pixel", "pixels",
            "banners", "banner", "popads", "popunder", "analytics-api", "metrics-api"));

    /** היוריסטיקה: ads.example.com, telemetry.app.io וכו'. דורש לפחות 3 תוויות (לא נוגעים בדומיין ראשי). */
    static boolean heuristicAd(String name) {
        String n = name.toLowerCase();
        if (n.endsWith(".")) n = n.substring(0, n.length() - 1);
        String[] l = n.split("\\.");
        if (l.length < 3) return false;
        if (AD_LABELS.contains(l[0])) return true;
        return l.length >= 4 && AD_LABELS.contains(l[1]);
    }

    /** האם השם (או הורה שלו) ברשימה הלבנה. */
    static boolean isAllowed(String name, Set<String> allowed) {
        String n = name.toLowerCase();
        if (n.endsWith(".")) n = n.substring(0, n.length() - 1);
        int i = 0;
        while (true) {
            String suffix = n.substring(i);
            if (suffix.indexOf('.') < 0) return false;
            if (allowed.contains(suffix)) return true;
            int dot = n.indexOf('.', i);
            if (dot < 0) return false;
            i = dot + 1;
        }
    }

    /** תשובת DNS מזויפת: 0.0.0.0 ל-A, :: ל-AAAA, ריקה לשאר. */
    static byte[] blockedReply(byte[] q, int off, Question qs) {
        boolean a = qs.type == 1, aaaa = qs.type == 28;
        int ansLen = a ? 16 : aaaa ? 28 : 0;
        byte[] r = new byte[qs.end + ansLen];
        r[0] = q[off]; r[1] = q[off + 1];                 // txid
        r[2] = (byte) (0x80 | (q[off + 2] & 0x01));       // QR + RD
        r[3] = (byte) 0x80;                               // RA, NOERROR
        r[5] = 1;                                         // qdcount
        r[7] = (byte) (ansLen > 0 ? 1 : 0);               // ancount
        System.arraycopy(q, off + 12, r, 12, qs.end - 12);
        if (ansLen > 0) {
            int p = qs.end;
            r[p++] = (byte) 0xC0; r[p++] = 0x0C;          // pointer לשם
            r[p++] = 0; r[p++] = (byte) qs.type;          // TYPE
            r[p++] = 0; r[p++] = 1;                       // CLASS IN
            r[p++] = 0; r[p++] = 0; r[p++] = 0; r[p++] = 60; // TTL
            r[p++] = 0; r[p++] = (byte) (a ? 4 : 16);     // RDLENGTH
            // RDATA נשאר אפסים
        }
        return r;
    }

    /** תשובת SERVFAIL לשאילתה. */
    static byte[] servfail(byte[] q, int off) {
        byte[] r = new byte[12];
        if (q.length >= off + 2) { r[0] = q[off]; r[1] = q[off + 1]; }
        r[2] = (byte) 0x81; r[3] = (byte) 0x82;
        return r;
    }


    /** תשובת NXDOMAIN (משמשת ל-canary של Firefox DoH ולדומיינים שצריך "להעלים"). */
    static byte[] nxdomainReply(byte[] q, int off, Question qs) {
        byte[] r = blockedReply(q, off, new Question(qs.name, 0, qs.end));
        r[3] = (byte) 0x83; // RA + RCODE=3
        return r;
    }

    /** מפענח שם DNS (כולל pointers) החל מ-pos בתוך הודעה שלמה. מחזיר null אם פגום. */
    static String readName(byte[] m, int len, int pos) {
        StringBuilder sb = new StringBuilder();
        int jumps = 0;
        try {
            while (true) {
                int n = m[pos] & 0xFF;
                if (n == 0) break;
                if ((n & 0xC0) == 0xC0) {
                    pos = ((n & 0x3F) << 8) | (m[pos + 1] & 0xFF);
                    if (pos >= len || ++jumps > 10) return null;
                    continue;
                }
                if ((n & 0xC0) != 0 || pos + n >= len) return null;
                if (sb.length() > 0) sb.append('.');
                for (int k = 1; k <= n; k++) sb.append((char) (m[pos + k] & 0xFF));
                pos += n + 1;
            }
        } catch (ArrayIndexOutOfBoundsException e) {
            return null;
        }
        return sb.toString().toLowerCase();
    }

    /** מדלג על שם בתוך הודעה (label-ים או pointer). מחזיר אינדקס אחריו או -1. */
    private static int skipName(byte[] m, int len, int pos) {
        while (pos < len) {
            int n = m[pos] & 0xFF;
            if (n == 0) return pos + 1;
            if ((n & 0xC0) == 0xC0) return pos + 2;
            pos += n + 1;
        }
        return -1;
    }

    /**
     * "CNAME cloaking": מעקב שמוסתר מאחורי תת-דומיין של האתר עצמו (CNAME לדומיין של חברת פרסום).
     * בודק אם אחד מיעדי ה-CNAME בתשובה חסום. qEnd = סוף סעיף השאלה.
     */
    static boolean cnameBlocked(byte[] m, int len, int qEnd, Set<String> blocked, Set<String> allowed) {
        if (len < 12) return false;
        int an = ((m[6] & 0xFF) << 8) | (m[7] & 0xFF);
        int pos = qEnd;
        for (int i = 0; i < an && i < 32; i++) {
            pos = skipName(m, len, pos);
            if (pos < 0 || pos + 10 > len) return false;
            int type = ((m[pos] & 0xFF) << 8) | (m[pos + 1] & 0xFF);
            int rdlen = ((m[pos + 8] & 0xFF) << 8) | (m[pos + 9] & 0xFF);
            pos += 10;
            if (pos + rdlen > len) return false;
            if (type == 5) {
                String target = readName(m, len, pos);
                if (target != null && isBlocked(target, blocked, allowed)) return true;
            }
            pos += rdlen;
        }
        return false;
    }

    // ---------------------------------------------------------------- IPv4/UDP

    static int checksum(byte[] b, int off, int len) {
        long sum = 0;
        for (int i = 0; i < len - 1; i += 2) sum += ((b[off + i] & 0xFF) << 8) | (b[off + i + 1] & 0xFF);
        if ((len & 1) == 1) sum += (b[off + len - 1] & 0xFF) << 8;
        while ((sum >> 16) != 0) sum = (sum & 0xFFFF) + (sum >> 16);
        return (int) (~sum & 0xFFFF);
    }

    /**
     * בונה חבילת IPv4+UDP שהיא תשובה לחבילה המקורית req (שכבר נבדקה כ-UDP/IPv4),
     * כך ש-src/dst מוחלפים, עם payload של תשובת ה-DNS.
     */
    static byte[] buildUdpReply(byte[] req, int ihl, byte[] payload) {
        int total = 20 + 8 + payload.length;
        byte[] r = new byte[total];
        r[0] = 0x45;
        r[2] = (byte) (total >> 8); r[3] = (byte) total;
        r[6] = 0x40;                                      // DF
        r[8] = 64;                                        // TTL
        r[9] = 17;                                        // UDP
        System.arraycopy(req, 16, r, 12, 4);              // src = dst המקורי
        System.arraycopy(req, 12, r, 16, 4);              // dst = src המקורי
        int c = checksum(r, 0, 20);
        r[10] = (byte) (c >> 8); r[11] = (byte) c;
        System.arraycopy(req, ihl + 2, r, 20, 2);         // src port = dst port המקורי
        System.arraycopy(req, ihl, r, 22, 2);             // dst port = src port המקורי
        int ulen = 8 + payload.length;
        r[24] = (byte) (ulen >> 8); r[25] = (byte) ulen;  // UDP checksum נשאר 0 (חוקי ב-IPv4)
        System.arraycopy(payload, 0, r, 28, payload.length);
        return r;
    }
}
