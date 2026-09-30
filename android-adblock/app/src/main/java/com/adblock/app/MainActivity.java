package com.adblock.app;

import android.app.Activity;
import android.content.Intent;
import android.graphics.Color;
import android.net.VpnService;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

public class MainActivity extends Activity {
    private static final int REQ_VPN = 1;

    private TextView status, stats, recent;
    private Button toggle, update;
    private final Handler ui = new Handler(Looper.getMainLooper());
    private final Runnable tick = new Runnable() {
        @Override public void run() { refresh(); ui.postDelayed(this, 1000); }
    };

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setGravity(Gravity.CENTER_HORIZONTAL);
        int pad = (int) (24 * getResources().getDisplayMetrics().density);
        root.setPadding(pad, pad * 2, pad, pad);

        TextView title = text("חוסם פרסומות", 28, Color.BLACK);
        status = text("", 20, Color.DKGRAY);
        toggle = new Button(this);
        update = new Button(this);
        update.setText("עדכן רשימת חסימה");
        stats = text("", 16, Color.DKGRAY);
        recent = text("", 13, Color.GRAY);
        TextView note = text("חוסם פרסומות ומעקב בכל האפליקציות באמצעות DNS מקומי. "
                + "שום תעבורה אינה יוצאת לשרת שלנו. אם \"DNS פרטי\" מופעל בהגדרות "
                + "המכשיר - כבה אותו או הגדר אותו ל\"אוטומטי\".", 12, Color.GRAY);

        root.addView(title);
        root.addView(status);
        root.addView(toggle);
        root.addView(update);
        root.addView(stats);
        root.addView(recent);
        root.addView(note);
        setContentView(root);

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
                runOnUiThread(() -> {
                    update.setEnabled(true);
                    update.setText(n < 0 ? "העדכון נכשל - נסה שוב" : "עודכן: " + n + " דומיינים");
                });
            }).start();
        });
        new Thread(() -> Blocklist.load(getApplicationContext())).start();
    }

    private TextView text(String s, int sp, int color) {
        TextView t = new TextView(this);
        t.setText(s);
        t.setTextSize(sp);
        t.setTextColor(color);
        t.setGravity(Gravity.CENTER);
        t.setPadding(0, 16, 0, 16);
        return t;
    }

    private void startVpn() {
        startService(new Intent(this, AdBlockVpnService.class));
    }

    @Override
    protected void onActivityResult(int req, int res, Intent data) {
        if (req == REQ_VPN && res == RESULT_OK) startVpn();
    }

    private void refresh() {
        boolean on = AdBlockVpnService.running;
        status.setText(on ? "פעיל ✔" : "כבוי");
        status.setTextColor(on ? Color.rgb(0, 140, 60) : Color.DKGRAY);
        toggle.setText(on ? "כבה" : "הפעל");
        int t = AdBlockVpnService.total.get(), bl = AdBlockVpnService.blockedCount.get();
        stats.setText("נחסמו " + bl + " מתוך " + t + " בקשות\nברשימה: " + Blocklist.size() + " דומיינים");
        StringBuilder sb = new StringBuilder();
        synchronized (AdBlockVpnService.recent) {
            for (String d : AdBlockVpnService.recent) sb.append(d).append('\n');
        }
        recent.setText(sb.toString());
    }

    @Override protected void onResume() { super.onResume(); ui.post(tick); }
    @Override protected void onPause() { super.onPause(); ui.removeCallbacks(tick); }
}
