package com.adblock.app;

import android.content.ContentResolver;
import android.content.Context;
import android.content.SharedPreferences;
import android.provider.Settings;

/**
 * "DNS פרטי" (DoT) של אנדרואיד עוקף DNS של VPN כשהוא במצב hostname.
 * קורא את המצב, ואם ניתנה הרשאת WRITE_SECURE_SETTINGS (פעם אחת דרך adb) - מתקן אוטומטית.
 */
final class PrivateDns {
    private PrivateDns() {}

    static final String MODE = "private_dns_mode";
    static final String SPEC = "private_dns_specifier";

    static String mode(Context c) {
        try {
            String m = Settings.Global.getString(c.getContentResolver(), MODE);
            return m == null ? "off" : m;
        } catch (Exception e) {
            return "off";
        }
    }

    static String specifier(Context c) {
        try { return Settings.Global.getString(c.getContentResolver(), SPEC); } catch (Exception e) { return null; }
    }

    static boolean isStrict(Context c) { return "hostname".equals(mode(c)); }

    /** מעביר ל-opportunistic (ה-VPN שלנו לא תומך DoT, אז נופלים ל-DNS רגיל דרכנו). מחזיר true אם הצליח. */
    static boolean fix(Context c, SharedPreferences prefs) {
        try {
            ContentResolver cr = c.getContentResolver();
            String cur = mode(c);
            if (!"hostname".equals(cur)) return true;
            prefs.edit().putString("pd_orig_mode", cur).putString("pd_orig_spec", specifier(c)).apply();
            return Settings.Global.putString(cr, MODE, "opportunistic");
        } catch (Exception e) {
            return false; // אין הרשאה
        }
    }

    /** מחזיר את ההגדרה המקורית אם שינינו אותה. */
    static void restore(Context c, SharedPreferences prefs) {
        String orig = prefs.getString("pd_orig_mode", null);
        if (orig == null) return;
        try {
            Settings.Global.putString(c.getContentResolver(), MODE, orig);
        } catch (Exception ignored) { }
        prefs.edit().remove("pd_orig_mode").remove("pd_orig_spec").apply();
    }
}
