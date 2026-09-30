package com.adblock.app;

import java.io.ByteArrayInputStream;
import java.util.*;
import java.util.concurrent.atomic.AtomicInteger;

/** בדיקות יחידה לליבה הטהורה (ללא אנדרואיד). */
public class UnitTests {
    static int fails = 0;
    static void check(String name, boolean ok) { System.out.println((ok ? "PASS " : "FAIL ") + name); if (!ok) fails++; }

    static byte[] query(String name, int type) {
        List<Byte> b = new ArrayList<>();
        byte[] h = {0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0};
        for (byte x : h) b.add(x);
        for (String l : name.split("\\.")) { b.add((byte) l.length()); for (char c : l.toCharArray()) b.add((byte) c); }
        b.add((byte) 0); b.add((byte) 0); b.add((byte) type); b.add((byte) 0); b.add((byte) 1);
        byte[] r = new byte[b.size()]; for (int i = 0; i < r.length; i++) r[i] = b.get(i); return r;
    }

    /** תשובה עם CNAME: www.site.com -> tracker.adnet.net, ואז A 1.2.3.4 */
    static byte[] cnameResponse(byte[] q, String target) {
        Set<Byte> dummy = null;
        java.io.ByteArrayOutputStream o = new java.io.ByteArrayOutputStream();
        byte[] qq = q.clone();
        qq[2] = (byte) 0x81; qq[3] = (byte) 0x80; qq[7] = 2;      // QR, ancount=2
        o.write(qq, 0, qq.length);
        // CNAME RR: name ptr 0xC00C
        o.write(0xC0); o.write(0x0C); o.write(0); o.write(5); o.write(0); o.write(1); o.write(0); o.write(0); o.write(0); o.write(60);
        java.io.ByteArrayOutputStream rd = new java.io.ByteArrayOutputStream();
        for (String l : target.split("\\.")) { rd.write(l.length()); for (char c : l.toCharArray()) rd.write(c); }
        rd.write(0);
        o.write(0); o.write(rd.size()); o.write(rd.toByteArray(), 0, rd.size());
        // A RR owned by target (as a pointer to the rdata of the CNAME = offset of rdata)
        int rdataOff = qq.length + 12;
        o.write(0xC0); o.write(rdataOff); o.write(0); o.write(1); o.write(0); o.write(1); o.write(0); o.write(0); o.write(0); o.write(60);
        o.write(0); o.write(4); o.write(1); o.write(2); o.write(3); o.write(4);
        return o.toByteArray();
    }

    public static void main(String[] a) throws Exception {
        // ---- ListParser
        Set<String> s = new HashSet<>();
        String txt = "# comment\n0.0.0.0 ads.example.com\n127.0.0.1 localhost\n0.0.0.0 0.0.0.0\n"
                + "plain.example.org\n||adnet.net^\n||img.adnet.net^$third-party\n@@||good.adnet.net^\n! c\n[Adblock]\n"
                + "*.wild.example.net\n1.2.3.4\n0.0.0.0 Upper.Case.COM # trailing\n||bad-rule.com/path^\n";
        ListParser.parse(new ByteArrayInputStream(txt.getBytes("UTF-8")), s);
        check("parser: hosts line", s.contains("ads.example.com"));
        check("parser: plain domain", s.contains("plain.example.org"));
        check("parser: adblock ||d^", s.contains("adnet.net"));
        check("parser: skips $modifier rules", !s.contains("img.adnet.net"));
        check("parser: skips @@ exceptions", !s.contains("good.adnet.net"));
        check("parser: wildcard prefix", s.contains("wild.example.net"));
        check("parser: lowercases + trailing comment", s.contains("upper.case.com"));
        check("parser: ignores localhost/0.0.0.0/IPs/paths", !s.contains("localhost") && !s.contains("0.0.0.0") && !s.contains("1.2.3.4") && s.size() == 5);

        // ---- isBlocked
        Set<String> bl = new HashSet<>(Arrays.asList("adnet.net", "x.com")), al = new HashSet<>(Arrays.asList("ok.adnet.net"));
        check("block: subdomain of blocked", DnsCore.isBlocked("a.b.adnet.net", bl, al));
        check("block: allowlist wins", !DnsCore.isBlocked("ok.adnet.net", bl, al) && !DnsCore.isBlocked("sub.ok.adnet.net", bl, al));
        check("block: unrelated", !DnsCore.isBlocked("adnet.net.evil.org", bl, al) && !DnsCore.isBlocked("notadnet.net", bl, al));
        check("block: trailing dot / case", DnsCore.isBlocked("ADNET.net.", bl, al));

        // ---- engine: CNAME cloaking, cache, failure
        final AtomicInteger upCalls = new AtomicInteger();
        final String[] cnameTo = {"tracker.adnet.net"};
        DnsEngine.Upstream up = q -> { upCalls.incrementAndGet(); return cnameResponse(q, cnameTo[0]); };
        final AtomicInteger blockedEvents = new AtomicInteger();
        DnsEngine e = new DnsEngine(up, (n, b) -> { if (b) blockedEvents.incrementAndGet(); }, 20000, 10);
        e.setLists(bl, new HashSet<String>());
        byte[] r = e.handle(query("www.site.com", 1));
        check("engine: CNAME cloaking blocked", (r[7] == 1) && r[r.length - 1] == 0 && r[r.length - 4] == 0 && blockedEvents.get() == 1);
        cnameTo[0] = "cdn.clean.org";
        e.setLists(bl, new HashSet<String>());
        r = e.handle(query("www.site2.com", 1));
        check("engine: clean CNAME passes", r.length > 12 && r[r.length - 4] == 1 && r[r.length - 1] == 4);
        int before = upCalls.get();
        byte[] q2 = query("www.site2.com", 1); q2[0] = 0x55; q2[1] = 0x66;
        r = e.handle(q2);
        check("engine: cache hit (no upstream) + txid rewritten", upCalls.get() == before && r[0] == 0x55 && r[1] == 0x66);
        DnsEngine failing = new DnsEngine(q -> null, null, 1000, 10);
        r = failing.handle(query("a.example.com", 1));
        check("engine: upstream down -> SERVFAIL", (r[3] & 15) == 2);
        check("engine: garbage input -> SERVFAIL, no crash", (failing.handle(new byte[]{1, 2, 3})[3] & 15) == 2);

        // ---- parseQuestion robustness (fuzz: never throws)
        Random rnd = new Random(1); boolean threw = false;
        for (int i = 0; i < 20000; i++) {
            byte[] junk = new byte[rnd.nextInt(80)]; rnd.nextBytes(junk);
            try { DnsCore.parseQuestion(junk, 0, junk.length); failing.handle(junk); DnsCore.cnameBlocked(junk, junk.length, 12, bl, al); }
            catch (Throwable t) { threw = true; System.out.println(t); break; }
        }
        check("fuzz: 20000 random packets never throw", !threw);

        // ---- PacketHandler fuzz
        PacketHandler ph = new PacketHandler(failing, p -> { }, Runnable::run);
        threw = false;
        for (int i = 0; i < 30000 && !threw; i++) {
            byte[] junk = new byte[rnd.nextInt(120)]; rnd.nextBytes(junk);
            if (junk.length > 0 && rnd.nextBoolean()) junk[0] = (byte) (0x40 | (5 + rnd.nextInt(3)));
            if (junk.length > 9 && rnd.nextBoolean()) junk[9] = (byte) new int[]{1, 6, 17}[rnd.nextInt(3)];
            try { ph.handle(junk, junk.length); } catch (Throwable t) { threw = true; t.printStackTrace(); }
        }
        check("fuzz: 30000 random IP packets never throw", !threw);

        System.out.println(fails == 0 ? "\nUNIT: ALL PASSED" : "\nUNIT: " + fails + " FAILED");
        System.exit(fails == 0 ? 0 : 1);
    }
}
