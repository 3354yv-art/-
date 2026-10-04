package com.adblock.app;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.ConnectivityManager;
import android.net.LinkProperties;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.VpnService;
import android.os.Build;
import android.os.ParcelFileDescriptor;

import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.net.DatagramSocket;
import java.net.InetAddress;
import java.net.Socket;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * VPN מקומי. מנתב אליו רק: כתובת ה-DNS הווירטואלית שלנו, וכתובות של שרתי DNS ציבוריים ידועים
 * (כדי לתפוס אפליקציות שמקודדות 8.8.8.8 ועוקפות את ה-DNS של המערכת). שאר התעבורה לא נוגעת בנו.
 */
public class AdBlockVpnService extends VpnService implements Forwarder.Env {
    static final String ACTION_STOP = "com.adblock.app.STOP";
    static final String PREFS = "adblock";
    static final String KEY_ENABLED = "enabled";

    private static final String FAKE_DNS = "10.111.222.2";
    private static final String CLIENT_ADDR = "10.111.222.1";
    private static final String[] HIJACK = {
            "8.8.8.8", "8.8.4.4", "1.1.1.1", "1.0.0.1", "9.9.9.9", "149.112.112.112",
            "208.67.222.222", "208.67.220.220", "94.140.14.14", "94.140.15.15",
    };
    private static final String[] FALLBACK_UPSTREAM = {"1.1.1.1", "9.9.9.9", "8.8.8.8"};
    private static final String CHANNEL = "adblock";

    static volatile boolean running = false;
    static volatile AdBlockVpnService instance;
    static final AtomicInteger total = new AtomicInteger();
    static final AtomicInteger blockedCount = new AtomicInteger();
    static final ArrayDeque<String> recent = new ArrayDeque<>();

    private ParcelFileDescriptor tun;
    private Thread loop;
    private ExecutorService pool;
    private DnsEngine engine;
    private SharedPreferences prefs;

    private volatile Network cachedNet;
    private volatile List<String> cachedServers = new ArrayList<>();
    private volatile long cachedAt = 0;

    // ------------------------------------------------------------------ lifecycle

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        prefs = getSharedPreferences(PREFS, MODE_PRIVATE);
        if (intent != null && ACTION_STOP.equals(intent.getAction())) {
            prefs.edit().putBoolean(KEY_ENABLED, false).apply();
            stopVpn();
            stopSelf();
            return START_NOT_STICKY;
        }
        if (!running) {
            // הפעלה ע"י המשתמש, או אתחול מחדש של המערכת (intent == null)
            if (intent != null || prefs.getBoolean(KEY_ENABLED, false)) startVpn();
        }
        return START_STICKY;
    }

    private void startVpn() {
        showForeground();
        prefs.edit().putBoolean(KEY_ENABLED, true).apply();

        // DNS פרטי במצב hostname עוקף אותנו. אם יש הרשאה - מתקנים; אחרת לא מנתבים DoH/DoT (כדי לא לשבור אינטרנט)
        if (PrivateDns.isStrict(this)) PrivateDns.fix(this, prefs);
        boolean strict = PrivateDns.isStrict(this);

        Blocklist.loadBuiltin(this);
        engine = new DnsEngine(new Forwarder(this), (name, blocked) -> {
            total.incrementAndGet();
            if (blocked) {
                blockedCount.incrementAndGet();
                synchronized (recent) {
                    recent.remove(name);
                    recent.addFirst(name);
                    while (recent.size() > 12) recent.removeLast();
                }
            }
        }, 20000, 1000);
        applyLists();

        try {
            Builder b = new Builder()
                    .setSession("AdBlock")
                    .addAddress(CLIENT_ADDR, 24)
                    .addDnsServer(FAKE_DNS)
                    .addRoute(FAKE_DNS, 32)
                    .setMtu(1500)
                    .setBlocking(true);
            if (!strict) for (String ip : HIJACK) b.addRoute(ip, 32);
            if (Build.VERSION.SDK_INT >= 29) b.setMetered(false);
            tun = b.establish();
        } catch (Exception e) {
            tun = null;
        }
        if (tun == null) { running = false; stopSelf(); return; }

        instance = this;
        running = true;
        pool = Executors.newFixedThreadPool(12);
        final FileInputStream in = new FileInputStream(tun.getFileDescriptor());
        final FileOutputStream out = new FileOutputStream(tun.getFileDescriptor());
        final PacketHandler handler = new PacketHandler(engine, pkt -> {
            try { synchronized (out) { out.write(pkt); } } catch (IOException ignored) { }
        }, pool);
        loop = new Thread(() -> readLoop(in, handler), "adblock-tun");
        loop.start();

        // רשימות ברקע: טעינה מלאה (בינארית, מהירה) מיד; ובדיקת עדכון כל כמה שעות כל עוד פעיל
        new Thread(() -> {
            Context app = getApplicationContext();
            Blocklist.loadFull(app);
            applyLists();
            while (running) {
                if (Blocklist.isStale(app) && Blocklist.update(app) > 0) applyLists();
                try { Thread.sleep(6L * 3600 * 1000); } catch (InterruptedException e) { return; }
            }
        }, "adblock-lists").start();
    }

    /** מעדכן את המנוע ברשימות הנוכחיות (נקרא גם מה-UI אחרי שינוי רשימה לבנה). */
    void applyLists() {
        DnsEngine e = engine;
        if (e == null) return;
        e.setLists(Blocklist.blocked(), Blocklist.allowed());
        e.setAggressive(Blocklist.aggressive(this));
        Set<String> doh = new HashSet<>(Arrays.asList(DnsEngine.DOH_HOSTS));
        String spec = PrivateDns.specifier(this);
        if (spec != null) doh.remove(spec.toLowerCase());       // לא שוברים DNS פרטי שהמשתמש הגדיר
        e.setDohBlock(doh);
    }

    private void readLoop(FileInputStream in, PacketHandler handler) {
        byte[] buf = new byte[32767];
        try {
            int n;
            while ((n = in.read(buf)) >= 0) {
                if (n == 0) continue;
                try {
                    handler.handle(buf.clone(), n);
                } catch (Throwable ignored) {
                    // חבילה פגומה לעולם לא מפילה את הלולאה
                }
            }
        } catch (IOException ignored) {
            // ה-tun נסגר - עצירה רגילה
        }
    }

    private void stopVpn() {
        running = false;
        instance = null;
        if (pool != null) pool.shutdownNow();
        try { if (tun != null) tun.close(); } catch (IOException ignored) { }
        tun = null;
        if (prefs != null) PrivateDns.restore(this, prefs);
        try { stopForeground(true); } catch (Throwable ignored) { }
    }

    @Override
    public void onDestroy() {
        stopVpn();
        super.onDestroy();
    }

    @Override
    public void onRevoke() {
        // משתמש הפעיל VPN אחר / ביטל את ההרשאה - לא נילחם בזה
        if (prefs == null) prefs = getSharedPreferences(PREFS, MODE_PRIVATE);
        prefs.edit().putBoolean(KEY_ENABLED, false).apply();
        stopVpn();
        super.onRevoke();
    }

    // ------------------------------------------------------------------ notification

    private void showForeground() {
        try {
            NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
            Notification.Builder nb;
            if (Build.VERSION.SDK_INT >= 26) {
                nm.createNotificationChannel(new NotificationChannel(CHANNEL, "AdBlock", NotificationManager.IMPORTANCE_MIN));
                nb = new Notification.Builder(this, CHANNEL);
            } else {
                nb = new Notification.Builder(this);
            }
            int piFlags = Build.VERSION.SDK_INT >= 23 ? PendingIntent.FLAG_IMMUTABLE : 0;
            PendingIntent pi = PendingIntent.getActivity(this, 0, new Intent(this, MainActivity.class), piFlags);
            nb.setContentTitle("חוסם הפרסומות פעיל")
              .setSmallIcon(android.R.drawable.ic_lock_lock)
              .setContentIntent(pi)
              .setOngoing(true);
            startForeground(1, nb.build());
        } catch (Throwable ignored) {
            // ללא foreground: ה-VPN עדיין עובד
        }
    }

    // ------------------------------------------------------------------ Forwarder.Env

    /** הרשת הפיזית (לא ה-VPN) - עדיפות לרשת שעברה אימות. */
    private Network underlying() {
        ConnectivityManager cm = (ConnectivityManager) getSystemService(Context.CONNECTIVITY_SERVICE);
        Network fallback = null;
        try {
            for (Network n : cm.getAllNetworks()) {
                NetworkCapabilities nc = cm.getNetworkCapabilities(n);
                if (nc == null || nc.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) continue;
                if (!nc.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) continue;
                if (nc.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) return n;
                if (fallback == null) fallback = n;
            }
        } catch (Throwable ignored) { }
        return fallback;
    }

    @Override
    public List<String> servers() {
        long now = System.currentTimeMillis();
        if (now - cachedAt < 3000 && !cachedServers.isEmpty()) return cachedServers;
        List<String> list = new ArrayList<>();
        Network n = underlying();
        cachedNet = n;
        if (n != null) {
            try {
                ConnectivityManager cm = (ConnectivityManager) getSystemService(Context.CONNECTIVITY_SERVICE);
                LinkProperties lp = cm.getLinkProperties(n);
                if (lp != null) {
                    for (InetAddress a : lp.getDnsServers()) {
                        String h = a.getHostAddress();
                        if (h != null && !h.equals(FAKE_DNS) && !list.contains(h)) list.add(h);
                    }
                }
            } catch (Throwable ignored) { }
        }
        for (String f : FALLBACK_UPSTREAM) if (!list.contains(f)) list.add(f);
        cachedServers = list;
        cachedAt = now;
        return list;
    }

    @Override
    public void prepare(DatagramSocket s) throws IOException {
        protect(s);
        Network n = cachedNet;
        if (n != null) { try { n.bindSocket(s); } catch (IOException ignored) { } }
    }

    @Override
    public void prepare(Socket s) throws IOException {
        protect(s);
        Network n = cachedNet;
        if (n != null) { try { n.bindSocket(s); } catch (IOException ignored) { } }
    }
}
