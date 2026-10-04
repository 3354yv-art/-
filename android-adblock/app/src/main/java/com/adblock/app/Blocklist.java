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

/** ניהול רשימות: רשימת פרסומות (נשמרת כקובץ hash בינארי), ורשימה לבנה. */
final class Blocklist {
    /** רק רשימות פרסומות. כל רשומה = כתובת ראשית + מראות (mirrors) אם הראשית נכשלה. */
    static final String[][] SOURCES = {
            {"https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"},
            {"https://adaway.org/hosts.txt"},
            {"https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&showintro=0&mimetype=plaintext"},
            {"https://easylist.to/easylist/easylist.txt",
             "https://raw.githubusercontent.com/easylist/easylist/master/easylist.txt"},
    };

    /** דומיינים שלעולם לא נחסמים - בדיקות חיבור/Captive portal, וכתובות העדכון של הרשימות. */
    static final String[] NEVER_BLOCK = {
            "connectivitycheck.gstatic.com", "connectivitycheck.android.com", "clients3.google.com",
            "clients1.google.com", "clients4.google.com", "time.android.com", "captive.apple.com",
            "www.msftconnecttest.com", "dns.msftncsi.com", "detectportal.firefox.com",
            "raw.githubusercontent.com", "github.com", "adaway.org", "adguardteam.github.io",
            "easylist.to", "pgl.yoyo.org",
    };

    private static final long STALE_MS = 24L * 3600 * 1000;

    private static volatile DomainSet blocked = DomainSet.EMPTY;
    private static volatile Set<String> allowed = new HashSet<>(Arrays.asList(NEVER_BLOCK));
    private static final Object lock = new Object();

    private Blocklist() {}

    static Set<String> blocked() { return blocked; }
    static Set<String> allowed() { return allowed; }
    static int size() { return blocked.size(); }

    private static File adsFile(Context c) { return new File(c.getFilesDir(), "ads.bin"); }
    private static File userAllowFile(Context c) { return new File(c.getFilesDir(), "allowlist.txt"); }

    static boolean isStale(Context c) {
        File f = adsFile(c);
        return !f.exists() || System.currentTimeMillis() - f.lastModified() > STALE_MS;
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

    /** טעינה מלאה: מובנית + רשימת הפרסומות שהורדה. טעינה בינארית - אלפיות שנייה. */
    static void loadFull(Context c) {
        // ניקוי קבצים מגרסאות קודמות (רשימות מעקב/טלמטריה שכבר לא בשימוש)
        for (String old : new String[]{"blocklist.txt", "std.bin", "aggr.bin"}) new File(c.getFilesDir(), old).delete();
        DomainSet s = new DomainSet(builtin(c));
        long[] ads = DomainSet.read(adsFile(c));
        if (ads != null) s = s.with(new DomainSet(ads));
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

    /** מוריד את רשימות הפרסומות. מחזיר את מספר הדומיינים הכולל, או -1 אם שום דבר לא ירד. */
    static int update(Context c) {
        long[] ads = download(SOURCES);
        if (ads.length < 1000) return -1;
        synchronized (lock) {
            try { DomainSet.write(adsFile(c), ads); } catch (IOException e) { return -1; }
        }
        loadFull(c);
        return blocked.size();
    }
}
