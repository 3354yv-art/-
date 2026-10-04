package com.adblock.app;

import java.util.Arrays;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;

/**
 * מוח ה-DNS: מחליט חסימה / תשובה מה-cache / העברה ל-upstream, כולל חסימת CNAME מוסתר.
 * טהור (ללא תלות באנדרואיד) כדי שאפשר לבדוק אותו ב-JVM.
 */
final class DnsEngine {
    /** העברה לשרת אמיתי. מחזיר null בכישלון. */
    interface Upstream { byte[] query(byte[] q); }

    /** מקבל עדכוני סטטיסטיקה. */
    interface Listener { void onQuery(String name, boolean blocked); }

    /**
     * דומיינים ש-Firefox/דפדפנים בודקים כדי לדעת אם לכבות DNS-over-HTTPS.
     * תשובת NXDOMAIN מכבה את ה-DoH שלהם והם חוזרים ל-DNS של המערכת (שלנו).
     */
    private static final Set<String> CANARY = new HashSet<>(Arrays.asList(
            "use-application-dns.net"));

    /** שרתי DoH/DoT ידועים: חסימתם מאלצת אפליקציות לחזור ל-DNS של המערכת. */
    static final String[] DOH_HOSTS = {
            "dns.google", "dns.google.com", "8888.google", "cloudflare-dns.com",
            "mozilla.cloudflare-dns.com", "chrome.cloudflare-dns.com", "one.one.one.one",
            "1dot1dot1dot1.cloudflare-dns.com", "dns.cloudflare.com", "security.cloudflare-dns.com",
            "family.cloudflare-dns.com", "dns.quad9.net", "dns9.quad9.net", "dns10.quad9.net",
            "dns11.quad9.net", "doh.opendns.com", "doh.familyshield.opendns.com", "dns.adguard.com",
            "dns.adguard-dns.com", "unfiltered.adguard-dns.com", "family.adguard-dns.com",
            "dns.nextdns.io", "doh.dns.sb", "dot.sb", "doh.cleanbrowsing.org", "doh.libredns.gr",
            "dns.twnic.tw", "doh.pub", "dns.alidns.com", "dns.switch.ch", "doh.mullvad.net",
            "dns.mullvad.net", "dns.controld.com", "freedns.controld.com", "doh.applied-privacy.net"
    };

    private final Upstream upstream;
    private final Listener listener;
    private volatile Set<String> blocked = new HashSet<>();
    private volatile Set<String> allowed = new HashSet<>();
    private volatile Set<String> dohBlocked = new HashSet<>();

    private final long ttlMs;
    private final int maxEntries;
    private final Map<String, Object[]> cache; // key -> {expiryMs, byte[]}

    DnsEngine(Upstream upstream, Listener listener, long ttlMs, final int maxEntries) {
        this.upstream = upstream;
        this.listener = listener;
        this.ttlMs = ttlMs;
        this.maxEntries = maxEntries;
        this.cache = new LinkedHashMap<String, Object[]>(64, 0.75f, true) {
            @Override protected boolean removeEldestEntry(Map.Entry<String, Object[]> e) {
                return size() > DnsEngine.this.maxEntries;
            }
        };
    }

    void setLists(Set<String> blocked, Set<String> allowed) {
        this.blocked = blocked;
        this.allowed = allowed;
        synchronized (cache) { cache.clear(); }
    }

    /** חוסם גם שמות DoH/DoT ידועים (except: מה שמשתמש הגדיר כ-Private DNS). */
    void setDohBlock(Set<String> hosts) { this.dohBlocked = hosts; }

    private boolean blockedName(String name) {
        Set<String> a = allowed;
        if (DnsCore.isBlocked(name, blocked, a)) return true;
        if (DnsCore.isBlocked(name, dohBlocked, a)) return true;
        return false;
    }

    /** מעבד שאילתת DNS ומחזיר תמיד תשובה תקינה (במקרה של כשל - SERVFAIL). */
    byte[] handle(byte[] query) {
        DnsCore.Question q = DnsCore.parseQuestion(query, 0, query.length);
        if (q == null) return DnsCore.servfail(query, 0);

        if (CANARY.contains(q.name)) {
            if (listener != null) listener.onQuery(q.name, true);
            return DnsCore.nxdomainReply(query, 0, q);
        }
        if (blockedName(q.name)) {
            if (listener != null) listener.onQuery(q.name, true);
            return DnsCore.blockedReply(query, 0, q);
        }

        String key = q.name + "/" + q.type;
        long now = System.currentTimeMillis();
        synchronized (cache) {
            Object[] hit = cache.get(key);
            if (hit != null) {
                if ((Long) hit[0] > now) {
                    byte[] r = ((byte[]) hit[1]).clone();
                    r[0] = query[0]; r[1] = query[1];
                    if (listener != null) listener.onQuery(q.name, false);
                    return r;
                }
                cache.remove(key);
            }
        }

        byte[] resp = upstream.query(query);
        if (resp == null || resp.length < 12) {
            if (listener != null) listener.onQuery(q.name, false);
            return DnsCore.servfail(query, 0);
        }
        if (DnsCore.cnameBlocked(resp, resp.length, q.end, blocked, allowed)) {
            if (listener != null) listener.onQuery(q.name, true);
            return DnsCore.blockedReply(query, 0, q);
        }
        if (listener != null) listener.onQuery(q.name, false);

        int rcode = resp[3] & 0x0F;
        boolean truncated = (resp[2] & 0x02) != 0;
        if (!truncated && (rcode == 0 || rcode == 3)) {
            synchronized (cache) { cache.put(key, new Object[]{now + ttlMs, resp.clone()}); }
        }
        return resp;
    }
}
