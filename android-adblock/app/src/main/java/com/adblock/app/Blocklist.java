package com.adblock.app;

import android.content.Context;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.Collections;
import java.util.HashSet;
import java.util.Set;

/** טעינה ועדכון של רשימת הדומיינים החסומים. */
final class Blocklist {
    private static final String URL_HOSTS =
            "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts";

    private static volatile Set<String> blocked = Collections.emptySet();
    private static volatile Set<String> allowed = Collections.emptySet();

    private Blocklist() {}

    static Set<String> blocked() { return blocked; }
    static Set<String> allowed() { return allowed; }
    static int size() { return blocked.size(); }

    private static File file(Context c) { return new File(c.getFilesDir(), "blocklist.txt"); }
    private static File allowFile(Context c) { return new File(c.getFilesDir(), "allowlist.txt"); }

    /** טוען מהקובץ שהורד, ואם אין - מהרשימה המובנית. */
    static void load(Context c) {
        Set<String> set = new HashSet<>();
        try {
            File f = file(c);
            try (InputStream in = f.exists() ? new java.io.FileInputStream(f) : c.getAssets().open("builtin.txt")) {
                parse(in, set);
            }
        } catch (IOException ignored) { }
        blocked = set;

        Set<String> al = new HashSet<>();
        try {
            File f = allowFile(c);
            if (f.exists()) try (InputStream in = new java.io.FileInputStream(f)) { parse(in, al); }
        } catch (IOException ignored) { }
        allowed = al;
    }

    /** מוריד את הרשימה המעודכנת. מחזיר מספר דומיינים, או -1 בכישלון. */
    static int update(Context c) {
        try {
            HttpURLConnection con = (HttpURLConnection) new URL(URL_HOSTS).openConnection();
            con.setConnectTimeout(15000);
            con.setReadTimeout(30000);
            Set<String> set = new HashSet<>();
            try (InputStream in = con.getInputStream()) { parse(in, set); }
            if (set.size() < 1000) return -1; // תשובה חשודה/ריקה
            File tmp = new File(c.getFilesDir(), "blocklist.tmp");
            try (FileOutputStream out = new FileOutputStream(tmp)) {
                StringBuilder sb = new StringBuilder();
                for (String d : set) sb.append(d).append('\n');
                out.write(sb.toString().getBytes("UTF-8"));
            }
            if (!tmp.renameTo(file(c))) return -1;
            load(c);
            return set.size();
        } catch (IOException e) {
            return -1;
        }
    }

    /** מפרש hosts ("0.0.0.0 domain") או רשימת דומיינים פשוטה. */
    static void parse(InputStream in, Set<String> out) throws IOException {
        BufferedReader r = new BufferedReader(new InputStreamReader(in, "UTF-8"));
        String line;
        while ((line = r.readLine()) != null) {
            int hash = line.indexOf('#');
            if (hash >= 0) line = line.substring(0, hash);
            line = line.trim().toLowerCase();
            if (line.isEmpty()) continue;
            String[] p = line.split("\\s+");
            String d = (p.length >= 2 && (p[0].equals("0.0.0.0") || p[0].equals("127.0.0.1"))) ? p[1] : p[0];
            if (d.indexOf('.') > 0 && d.indexOf('/') < 0 && d.indexOf(':') < 0
                    && !d.equals("0.0.0.0") && !d.equals("localhost")) out.add(d);
        }
    }
}
