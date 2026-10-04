package com.adblock.app;

import android.content.Context;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.Arrays;
import java.util.HashSet;
import java.util.Set;
import java.util.TreeSet;

/** ניהול רשימות: חסימה רגילה + אגרסיבית (נשמרות כקבצי hash בינאריים), ורשימה לבנה. */
final class Blocklist {
    private static final String GZ = "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/hosts/";
    private static final String GZ_MIRROR = "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/hosts/";

    private static String[] hagezi(String name) { return new String[]{GZ + name, GZ_MIRROR + name}; }

    /** כל רשומה = כתובת ראשית + מראות (mirrors) אם הראשית נכשלה. */
    static final String[][] STANDARD = {
            {"https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"},
            {"https://adaway.org/hosts.txt"},
            {"https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt",
             "https://raw.githubusercontent.com/AdguardTeam/AdGuardSDNSFilter/master/Filters/filter.txt"},
            hagezi("pro.txt"),
    };

    /** מצב אגרסיבי: ultimate, טלמטריה של יצרני מכשירים, איומים/פישינג, CNAME מוסתר, פופאפים. */
    static final String[][] AGGRESSIVE = {
            hagezi("ultimate.txt"),
            hagezi("tif.medium.txt"),
            hagezi("popupads.txt"),
            hagezi("native.xiaomi.txt"),
            hagezi("native.samsung.txt"),
            hagezi("native.huawei.txt"),
            hagezi("native.oppo-realme.txt"),
            hagezi("native.vivo.txt"),
            {"https://raw.githubusercontent.com/nextdns/cname-cloaking-blocklist/master/domains"},
    };

    /** דומיינים שלעולם לא נחסמים - בדיקות חיבור/Captive portal, וכתובות העדכון של הרשימות. */
    static final String[] NEVER_BLOCK = {
            "connectivitycheck.gstatic.com", "connectivitycheck.android.com", "clients3.google.com",
            "clients1.google.com", "clients4.google.com", "time.android.com", "captive.apple.com",
            "www.msftconnecttest.com", "dns.msftncsi.com", "detectportal.firefox.com",
            "raw.githubusercontent.com", "github.com", "adaway.org", "adguardteam.github.io",
            "cdn.jsdelivr.net",
    };

    private static final long STALE_MS = 24L * 3600 * 1000;

    private static volatile DomainSet blocked = DomainSet.EMPTY;
    private static volatile Set<String> allowed = new HashSet<>(Arrays.asList(NEVER_BLOCK));
    private static final Object lock = new Object();

    private Blocklist() {}

    static Set<String> blocked() { return blocked; }
    static Set<String> allowed() { return allowed; }
    static int size() { return blocked.size(); }

    private static File stdFile(Context c) { return new File(c.getFilesDir(), "std.bin"); }
    private static File aggrFile(Context c) { return new File(c.getFilesDir(), "aggr.bin"); }
    private static File userAllowFile(Context c) { return new File(c.getFilesDir(), "allowlist.txt"); }

    static boolean aggressive(Context c) {
        return c.getSharedPreferences(AdBlockVpnService.PREFS, Context.MODE_PRIVATE).getBoolean("aggressive", true);
    }

    static void setAggressive(Context c, boolean on) {
        c.getSharedPreferences(AdBlockVpnService.PREFS, Context.MODE_PRIVATE).edit().putBoolean("aggressive", on).apply();
    }

    static boolean isStale(Context c) {
        File f = stdFile(c);
        if (!f.exists() || System.currentTimeMillis() - f.lastModified() > STALE_MS) return true;
        return aggressive(c) && !aggrFile(c).exists();
    }

    private static long[] builtin(Context c) {
        DomainSet.Builder b = new DomainSet.Builder();
        try (InputStream in = c.getAssets().open("builtin.txt")) { ListParser.parse(in, b); } catch (IOException ignored) { }
        return b.build();
    }

    /** טעינה מהירה של הרשימה המובנית בלבד (כדי שה-VPN יעבוד מיד). */
    static void loadBuiltin(Context c) {
        blocked = new DomainSet(builtin(c));
        loadAllowed(c);
    }

    /** טעינה מלאה: מובנית + רגילה + (אם אגרסיבי) האגרסיבית. טעינה בינארית - אלפיות שנייה. */
    static void loadFull(Context c) {
        new File(c.getFilesDir(), "blocklist.txt").delete(); // פורמט ישן
        DomainSet s = new DomainSet(builtin(c));
        long[] std = DomainSet.read(stdFile(c));
        if (std != null) s = s.with(new DomainSet(std));
        if (aggressive(c)) {
            long[] ag = DomainSet.read(aggrFile(c));
            if (ag != null) s = s.with(new DomainSet(ag));
        }
        blocked = s;
        loadAllowed(c);
    }

    private static void loadAllowed(Context c) {
        Set<String> al = new HashSet<>(Arrays.asList(NEVER_BLOCK));
        File f = userAllowFile(c);
        if (f.exists()) {
            try (InputStream in = new FileInputStream(f)) { ListParser.parse(in, al); } catch (IOException ignored) { }
        }
        allowed = al;
    }

    /** הרשימה הלבנה של המשתמש בלבד (לתצוגה/עריכה). */
    static Set<String> userAllowed(Context c) {
        Set<String> s = new TreeSet<>();
        File f = userAllowFile(c);
        if (f.exists()) {
            try (InputStream in = new FileInputStream(f)) { ListParser.parse(in, s); } catch (IOException ignored) { }
        }
        return s;
    }

    static void setUserAllowed(Context c, Set<String> s) {
        synchronized (lock) {
            try (FileOutputStream out = new FileOutputStream(userAllowFile(c))) {
                StringBuilder sb = new StringBuilder();
                for (String d : s) sb.append(d).append('\n');
                out.write(sb.toString().getBytes("UTF-8"));
            } catch (IOException ignored) { }
            loadAllowed(c);
        }
    }

    /** מוריד קבוצת מקורות; לכל מקור מנסה את הכתובת הראשית ואז מראות. מחזיר את ה-hashes הממוינים. */
    private static long[] download(String[][] group) {
        DomainSet.Builder all = new DomainSet.Builder();
        for (String[] urls : group) {
            for (String src : urls) {
                DomainSet.Builder part = new DomainSet.Builder();
                try {
                    HttpURLConnection con = (HttpURLConnection) new URL(src).openConnection();
                    con.setConnectTimeout(15000);
                    con.setReadTimeout(60000);
                    con.setRequestProperty("User-Agent", "AdBlock-Android");
                    if (con.getResponseCode() != 200) continue;
                    try (InputStream in = con.getInputStream()) { ListParser.parse(in, part); }
                } catch (Exception e) {
                    continue;
                }
                if (part.size() < 50) continue;
                for (long h : part.build()) all.addHash(h);
                break; // המקור הצליח - לא צריך מראה
            }
        }
        return all.build();
    }

    /** מוריד הכל. מחזיר את מספר הדומיינים הכולל, או -1 אם שום דבר לא ירד. */
    static int update(Context c) {
        long[] std = download(STANDARD);
        long[] ag = download(AGGRESSIVE);
        boolean ok = false;
        synchronized (lock) {
            try {
                if (std.length >= 1000) { DomainSet.write(stdFile(c), std); ok = true; }
                if (ag.length >= 100) { DomainSet.write(aggrFile(c), ag); ok = true; }
            } catch (IOException e) {
                return -1;
            }
        }
        if (!ok) return -1;
        loadFull(c);
        return blocked.size();
    }
}
