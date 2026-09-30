package com.adblock.app;

import android.content.Intent;
import android.net.VpnService;
import android.os.ParcelFileDescriptor;

import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetAddress;
import java.util.ArrayDeque;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * VPN מקומי שמנתב רק את בקשות ה-DNS של כל האפליקציות אל הקוד הזה (שום תעבורה אחרת
 * לא עוברת דרכו). דומיינים של פרסומות מקבלים 0.0.0.0, השאר מועבר ל-DNS אמיתי.
 */
public class AdBlockVpnService extends VpnService {
    static final String ACTION_STOP = "com.adblock.app.STOP";

    private static final String FAKE_DNS = "10.111.222.2";
    private static final String CLIENT_ADDR = "10.111.222.1";
    private static final String[] UPSTREAM = {"1.1.1.1", "9.9.9.9"};

    static volatile boolean running = false;
    static final AtomicInteger total = new AtomicInteger();
    static final AtomicInteger blockedCount = new AtomicInteger();
    static final ArrayDeque<String> recent = new ArrayDeque<>();

    private ParcelFileDescriptor tun;
    private Thread loop;
    private ExecutorService pool;

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && ACTION_STOP.equals(intent.getAction())) {
            stopVpn();
            stopSelf();
            return START_NOT_STICKY;
        }
        if (!running) startVpn();
        return START_STICKY;
    }

    private void startVpn() {
        Blocklist.load(this);
        try {
            tun = new Builder()
                    .setSession("AdBlock")
                    .addAddress(CLIENT_ADDR, 32)
                    .addDnsServer(FAKE_DNS)
                    .addRoute(FAKE_DNS, 32)   // רק ה-DNS מנותב אלינו
                    .setBlocking(true)
                    .establish();
        } catch (Exception e) {
            tun = null;
        }
        if (tun == null) { stopSelf(); return; }

        running = true;
        pool = Executors.newFixedThreadPool(8);
        final FileInputStream in = new FileInputStream(tun.getFileDescriptor());
        final FileOutputStream out = new FileOutputStream(tun.getFileDescriptor());
        loop = new Thread(() -> readLoop(in, out), "adblock-tun");
        loop.start();
    }

    private void readLoop(FileInputStream in, final FileOutputStream out) {
        byte[] buf = new byte[32767];
        try {
            int n;
            while ((n = in.read(buf)) >= 0) {
                if (n == 0) continue;
                handlePacket(buf.clone(), n, out);
            }
        } catch (IOException ignored) {
            // ה-tun נסגר - עצירה רגילה
        }
    }

    private void handlePacket(final byte[] p, int n, final FileOutputStream out) {
        if (n < 28 || (p[0] >> 4) != 4) return;           // רק IPv4
        final int ihl = (p[0] & 0x0F) * 4;
        if (p[9] != 17 || n < ihl + 8) return;            // רק UDP
        int dport = ((p[ihl + 2] & 0xFF) << 8) | (p[ihl + 3] & 0xFF);
        if (dport != 53) return;
        final int dnsOff = ihl + 8;
        final int dnsLen = n - dnsOff;

        final DnsCore.Question q = DnsCore.parseQuestion(p, dnsOff, dnsLen);
        if (q == null) return;
        total.incrementAndGet();

        if (DnsCore.isBlocked(q.name, Blocklist.blocked(), Blocklist.allowed())) {
            blockedCount.incrementAndGet();
            synchronized (recent) {
                recent.addFirst(q.name);
                while (recent.size() > 8) recent.removeLast();
            }
            write(out, DnsCore.buildUdpReply(p, ihl, DnsCore.blockedReply(p, dnsOff, q)));
            return;
        }

        final byte[] query = new byte[dnsLen];
        System.arraycopy(p, dnsOff, query, 0, dnsLen);
        pool.execute(() -> {
            byte[] answer = forward(query);
            if (answer == null) answer = DnsCore.servfail(query, 0);
            write(out, DnsCore.buildUdpReply(p, ihl, answer));
        });
    }

    /** שולח את השאילתה לשרת DNS אמיתי דרך socket שמוגן מפני לולאה בתוך ה-VPN. */
    private byte[] forward(byte[] query) {
        for (String host : UPSTREAM) {
            try (DatagramSocket s = new DatagramSocket()) {
                protect(s);
                s.setSoTimeout(3000);
                s.send(new DatagramPacket(query, query.length, InetAddress.getByName(host), 53));
                byte[] rb = new byte[4096];
                DatagramPacket resp = new DatagramPacket(rb, rb.length);
                s.receive(resp);
                byte[] r = new byte[resp.getLength()];
                System.arraycopy(rb, 0, r, 0, r.length);
                return r;
            } catch (IOException ignored) { }
        }
        return null;
    }

    private void write(FileOutputStream out, byte[] packet) {
        try {
            synchronized (out) { out.write(packet); }
        } catch (IOException ignored) { }
    }

    private void stopVpn() {
        running = false;
        if (pool != null) pool.shutdownNow();
        try { if (tun != null) tun.close(); } catch (IOException ignored) { }
        tun = null;
    }

    @Override
    public void onDestroy() {
        stopVpn();
        super.onDestroy();
    }

    @Override
    public void onRevoke() {
        stopVpn();
        super.onRevoke();
    }
}
