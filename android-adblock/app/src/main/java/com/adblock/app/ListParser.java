package com.adblock.app;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.util.Set;

/** מפענח רשימות חסימה: hosts, רשימת דומיינים, ותחביר Adblock (||domain^). */
final class ListParser {
    private ListParser() {}

    static void parse(InputStream in, Set<String> out) throws IOException {
        BufferedReader r = new BufferedReader(new InputStreamReader(in, "UTF-8"));
        String line;
        while ((line = r.readLine()) != null) parseLine(line, out);
    }

    static void parseLine(String raw, Set<String> out) {
        String line = raw.trim();
        if (line.isEmpty()) return;
        char c = line.charAt(0);
        if (c == '!' || c == '[' || c == '#') return;
        if (line.startsWith("@@")) return;                      // כללי חריגה - לא חוסמים
        if (line.startsWith("||")) {                            // ||example.com^
            String d = line.substring(2);
            int caret = d.indexOf('^');
            if (caret < 0) return;
            String rest = d.substring(caret + 1);
            if (!rest.isEmpty() && !harmless(rest)) return;      // כללים עם מגבלות סוג-משאב ($script, $image...) לא ברמת דומיין
            d = d.substring(0, caret).toLowerCase();
            if (valid(d)) out.add(d);
            return;
        }
        int hash = line.indexOf('#');
        if (hash >= 0) line = line.substring(0, hash).trim();
        if (line.isEmpty()) return;
        String[] p = line.split("\\s+");
        String d = (p.length >= 2 && (p[0].equals("0.0.0.0") || p[0].equals("127.0.0.1")
                || p[0].equals("::1") || p[0].equals("::"))) ? p[1] : p[0];
        if (d.startsWith("*.")) d = d.substring(2);
        d = d.toLowerCase();
        if (valid(d)) out.add(d);
    }

    /** $third-party / $important / $all - חוסמים את כל הדומיין, אז בטוח להשתמש בכלל כמו שהוא. */
    private static boolean harmless(String mod) {
        if (!mod.startsWith("$")) return false;
        for (String m : mod.substring(1).split(",")) {
            if (!(m.equals("third-party") || m.equals("3p") || m.equals("important") || m.equals("all"))) return false;
        }
        return true;
    }

    private static boolean valid(String d) {
        if (d.indexOf('.') <= 0 || d.length() > 253) return false;
        if (d.equals("0.0.0.0") || d.equals("localhost") || d.endsWith(".localhost")) return false;
        for (int i = 0; i < d.length(); i++) {
            char ch = d.charAt(i);
            boolean ok = (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '.' || ch == '-' || ch == '_';
            if (!ok) return false;
        }
        // כתובת IP גולמית אינה דומיין
        boolean allDigits = true;
        for (int i = 0; i < d.length(); i++) {
            char ch = d.charAt(i);
            if (ch != '.' && (ch < '0' || ch > '9')) { allDigits = false; break; }
        }
        return !allDigits;
    }
}
