package com.adblock.app;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.graphics.Color;
import android.net.Uri;
import android.net.VpnService;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;
import android.provider.Settings;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.TreeSet;

public class MainActivity extends Activity {
    private static final int REQ_VPN = 1;
    private static final String ADB_CMD = "adb shell pm grant com.adblock.app android.permission.WRITE_SECURE_SETTINGS";

    private TextView status, stats;
    private Button toggle, update;
    private LinearLayout cards, recentBox;
    private String lastSig = "";
    private final Handler ui = new Handler(Looper.getMainLooper());
    private final Runnable tick = new Runnable() {
        @Override public void run() { refresh(); ui.postDelayed(this, 1000); }
    };

    private int dp(int v) { return (int) (v * getResources().getDisplayMetrics().density); }

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        ScrollView scroll = new ScrollView(this);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setGravity(Gravity.CENTER_HORIZONTAL);
        root.setPadding(dp(20), dp(40), dp(20), dp(24));
        scroll.addView(root);

        root.addView(text("חוסם פרסומות", 28, Color.BLACK));
        status = text("", 20, Color.DKGRAY);
        root.addView(status);
        toggle = new Button(this);
        root.addView(toggle);
        stats = text("", 15, Color.DKGRAY);
        root.addView(stats);

        cards = new LinearLayout(this);
        cards.setOrientation(LinearLayout.VERTICAL);
        root.addView(cards);

        CheckBox aggr = new CheckBox(this);
        aggr.setText("מצב אגרסיבי: חוסם עוד - טלמטריה של יצרני מכשירים, איומים ופישינג, "
                + "מעקב מוסתר, ודומיינים בשם ads./telemetry. (עלול לשבור אתר; אז לחץ עליו ברשימה למטה)");
        aggr.setChecked(Blocklist.aggressive(this));
        aggr.setOnCheckedChangeListener((v, checked) -> {
            Blocklist.setAggressive(this, checked);
            new Thread(() -> {
                Blocklist.loadFull(getApplicationContext());
                AdBlockVpnService s = AdBlockVpnService.instance;
                if (s != null) s.applyLists();
                if (checked && Blocklist.isStale(getApplicationContext())) {
                    Blocklist.update(getApplicationContext());
                    if (s != null) s.applyLists();
                }
            }).start();
        });
        root.addView(aggr);

        update = new Button(this);
        update.setText("עדכן רשימות חסימה");
        root.addView(update);
        Button allow = new Button(this);
        allow.setText("ניהול רשימה לבנה");
        root.addView(allow);

        root.addView(text("נחסמו לאחרונה (לחץ כדי לאפשר דומיין)", 14, Color.GRAY));
        recentBox = new LinearLayout(this);
        recentBox.setOrientation(LinearLayout.VERTICAL);
        root.addView(recentBox);
        setContentView(scroll);

        toggle.setOnClickListener(v -> {
            if (AdBlockVpnService.running) {
                startService(new Intent(this, AdBlockVpnService.class).setAction(AdBlockVpnService.ACTION_STOP));
            } else {
                Intent prep = VpnService.prepare(this);
                if (prep != null) startActivityForResult(prep, REQ_VPN);
                else startVpn();
            }
        });
        update.setOnClickListener(v -> {
            update.setEnabled(false);
            update.setText("מוריד...");
            new Thread(() -> {
                int n = Blocklist.update(getApplicationContext());
                AdBlockVpnService s = AdBlockVpnService.instance;
                if (s != null) s.applyLists();
                runOnUiThread(() -> {
                    update.setEnabled(true);
                    update.setText(n < 0 ? "העדכון נכשל - נסה שוב" : "עודכן: " + n + " דומיינים");
                });
            }).start();
        });
        allow.setOnClickListener(v -> manageAllowlist());
        new Thread(() -> Blocklist.loadFull(getApplicationContext())).start();
    }

    private TextView text(String s, int sp, int color) {
        TextView t = new TextView(this);
        t.setText(s);
        t.setTextSize(sp);
        t.setTextColor(color);
        t.setGravity(Gravity.CENTER);
        t.setPadding(0, dp(8), 0, dp(8));
        return t;
    }

    private void startVpn() {
        startService(new Intent(this, AdBlockVpnService.class));
    }

    @Override
    protected void onActivityResult(int req, int res, Intent data) {
        if (req == REQ_VPN && res == RESULT_OK) startVpn();
    }

    // ------------------------------------------------------------ allowlist

    private void allowDomain(final String domain) {
        new AlertDialog.Builder(this)
                .setMessage("לאפשר את " + domain + " ?\n(ייפסק לחסום אותו ואת תת-הדומיינים שלו)")
                .setPositiveButton("אפשר", (d, w) -> {
                    Set<String> s = new TreeSet<>(Blocklist.userAllowed(this));
                    s.add(domain);
                    Blocklist.setUserAllowed(this, s);
                    AdBlockVpnService svc = AdBlockVpnService.instance;
                    if (svc != null) svc.applyLists();
                    lastSig = "";
                })
                .setNegativeButton("ביטול", null)
                .show();
    }

    private void manageAllowlist() {
        final List<String> items = new ArrayList<>(Blocklist.userAllowed(this));
        if (items.isEmpty()) {
            new AlertDialog.Builder(this).setMessage("הרשימה הלבנה ריקה.\nכדי לאפשר דומיין, לחץ עליו ברשימת \"נחסמו לאחרונה\".")
                    .setPositiveButton("סגור", null).show();
            return;
        }
        new AlertDialog.Builder(this)
                .setTitle("לחץ על דומיין כדי להחזיר את החסימה")
                .setItems(items.toArray(new CharSequence[0]), (d, which) -> {
                    Set<String> s = new TreeSet<>(Blocklist.userAllowed(this));
                    s.remove(items.get(which));
                    Blocklist.setUserAllowed(this, s);
                    AdBlockVpnService svc = AdBlockVpnService.instance;
                    if (svc != null) svc.applyLists();
                })
                .setNegativeButton("סגור", null)
                .show();
    }

    // ------------------------------------------------------------ status

    private void addCard(String message, String buttonLabel, View.OnClickListener action) {
        TextView t = text(message, 13, Color.rgb(120, 60, 0));
        t.setBackgroundColor(Color.rgb(255, 243, 224));
        t.setPadding(dp(12), dp(10), dp(12), dp(10));
        t.setTextIsSelectable(true);
        cards.addView(t);
        if (buttonLabel != null) {
            Button bt = new Button(this);
            bt.setText(buttonLabel);
            bt.setOnClickListener(action);
            cards.addView(bt);
        }
    }

    private void refresh() {
        boolean on = AdBlockVpnService.running;
        status.setText(on ? "פעיל ✔" : "כבוי");
        status.setTextColor(on ? Color.rgb(0, 140, 60) : Color.DKGRAY);
        toggle.setText(on ? "כבה" : "הפעל");
        int t = AdBlockVpnService.total.get(), bl = AdBlockVpnService.blockedCount.get();
        stats.setText("נחסמו " + bl + " מתוך " + t + " בקשות\nברשימה: " + Blocklist.size() + " דומיינים");

        List<String> recent;
        synchronized (AdBlockVpnService.recent) { recent = new ArrayList<>(AdBlockVpnService.recent); }
        boolean strict = PrivateDns.isStrict(this);
        PowerManager pm = (PowerManager) getSystemService(POWER_SERVICE);
        boolean batteryOk = pm != null && pm.isIgnoringBatteryOptimizations(getPackageName());

        String sig = on + "|" + strict + "|" + batteryOk + "|" + recent;
        if (sig.equals(lastSig)) return;   // לא בונים מחדש בלי שינוי (כדי שלחיצות לא יתפספסו)
        lastSig = sig;

        cards.removeAllViews();
        if (strict) {
            addCard("⚠ \"DNS פרטי\" מוגדר אצלך לשם מארח ספציפי, ולכן אנדרואיד עוקף את החוסם.\n"
                            + "תיקון: הגדרות ← רשת ואינטרנט ← DNS פרטי ← \"אוטומטי\" או \"כבוי\".\n"
                            + "תיקון אוטומטי (פעם אחת, מהמחשב):\n" + ADB_CMD,
                    "פתח הגדרות רשת", v -> startActivity(new Intent(Settings.ACTION_WIRELESS_SETTINGS)));
        }
        if (!batteryOk) {
            addCard("כדי שהמערכת לא תעצור את החוסם ברקע (בעיקר ב-Xiaomi/Samsung/Huawei), אשר חריגה מחיסכון בסוללה.",
                    "אשר חריגה מסוללה", v -> {
                        try {
                            startActivity(new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                    Uri.parse("package:" + getPackageName())));
                        } catch (Exception e) {
                            startActivity(new Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS));
                        }
                    });
        }
        addCard("הגנה מלאה: ב-VPN הפעל \"VPN תמיד פעיל\" (Always-on) ואת \"חסום חיבורים ללא VPN\". "
                        + "כך החוסם עולה עם המכשיר ואין חלון זמן בלי הגנה.",
                "הגדרות VPN", v -> startActivity(new Intent(Settings.ACTION_VPN_SETTINGS)));

        recentBox.removeAllViews();
        for (final String d : recent) {
            TextView row = text(d, 13, Color.DKGRAY);
            row.setOnClickListener(v -> allowDomain(d));
            recentBox.addView(row);
        }
    }

    @Override protected void onResume() { super.onResume(); lastSig = ""; ui.post(tick); }
    @Override protected void onPause() { super.onPause(); ui.removeCallbacks(tick); }
}
