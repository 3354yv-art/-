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

/** ניהול רשימות: חסימה (מורדת + מובנית), ורשימה לבנה (מובנית + של המשתמש). */
final class Blocklist {
    static final String[] SOURCES = {
            "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts",
            "https://adaway.org/hosts.txt",
            "https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt",
            "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/hosts/pro.txt",
    };

    /** דומיינים שלעולם לא נחסמים - בדיקות חיבור/Captive portal, וכתובות העדכון של הרשימות. */
    static final String[] NEVER_BLOCK = {
            "connectivitycheck.gstatic.com", "connectivitycheck.android.com", "clients3.google.com",
            "clients1.google.com", "clients4.google.com", "time.android.com", "captive.apple.com",
            "www.msftconnecttest.com", "dns.msftncsi.com", "detectportal.firefox.com",
            "raw.githubusercontent.com", "github.com", "adaway.org", "adguardteam.github.io",
    };

    private static final long STALE_MS = 7L * 24 * 3600 * 1000;

    private static volatile Set<String> blocked = new HashSet<>();
    private static volatile Set<String> allowed = new HashSet<>(Arrays.asList(NEVER_BLOCK));
    private static final Object lock = new Object();

    private Blocklist() {}

    static Set<String> blocked() { return blocked; }
    static Set<String> allowed() { return allowed; }
    static int size() { return blocked.size(); }

    private static File file(Context c) { return new File(c.getFilesDir(), "blocklist.txt"); }
    private static File userAllowFile(Context c) { return new File(c.getFilesDir(), "allowlist.txt"); }

    static boolean isStale(Context c) {
        File f = file(c);
        return !f.exists() || System.currentTimeMillis() - f.lastModified() > STALE_MS;
    }

    /** טעינה מהירה של הרשימה המובנית בלבד (כדי שה-VPN יעבוד מיד). */
    static void loadBuiltin(Context c) {
        Set<String> set = new HashSet<>();
        try (InputStream in = c.getAssets().open("builtin.txt")) { ListParser.parse(in, set); } catch (IOException ignored) { }
        blocked = set;
        loadAllowed(c);
    }

    /** טעינה מלאה: הרשימה שהורדה (אם קיימת) + המובנית + הרשימה הלבנה. */
    static void loadFull(Context c) {
        Set<String> set = new HashSet<>();
        try (InputStream in = c.getAssets().open("builtin.txt")) { ListParser.parse(in, set); } catch (IOException ignored) { }
        File f = file(c);
        if (f.exists()) {
            try (InputStream in = new FileInputStream(f)) { ListParser.parse(in, set); } catch (IOException ignored) { }
        }
        blocked = set;
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

    /** מוריד את כל המקורות ומאחד. מחזיר מספר דומיינים, או -1 אם כולם נכשלו. */
    static int update(Context c) {
        Set<String> all = new HashSet<>();
        for (String src : SOURCES) {
            try {
                HttpURLConnection con = (HttpURLConnection) new URL(src).openConnection();
                con.setConnectTimeout(15000);
                con.setReadTimeout(40000);
                con.setRequestProperty("User-Agent", "AdBlock-Android");
                Set<String> part = new HashSet<>();
                try (InputStream in = con.getInputStream()) { ListParser.parse(in, part); }
                if (part.size() > 500) all.addAll(part);
            } catch (Exception ignored) { }
        }
        if (all.size() < 1000) return -1;
        synchronized (lock) {
            try {
                File tmp = new File(c.getFilesDir(), "blocklist.tmp");
                try (FileOutputStream out = new FileOutputStream(tmp)) {
                    StringBuilder sb = new StringBuilder(all.size() * 20);
                    for (String d : all) sb.append(d).append('\n');
                    out.write(sb.toString().getBytes("UTF-8"));
                }
                if (!tmp.renameTo(file(c))) {
                    file(c).delete();
                    if (!tmp.renameTo(file(c))) return -1;
                }
            } catch (IOException e) {
                return -1;
            }
        }
        loadFull(c);
        return blocked.size();
    }
}
