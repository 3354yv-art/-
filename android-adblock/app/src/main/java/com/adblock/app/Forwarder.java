package com.adblock.app;

import java.io.DataInputStream;
import java.io.IOException;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.util.List;

/**
 * מעביר שאילתות לשרתי DNS אמיתיים: UDP, ועם fallback ל-TCP כשהתשובה נחתכה (TC).
 * מנסה שרתים לפי סדר (הראשון הוא ה-DNS של הרשת עצמה), וזוכר את האחרון שעבד.
 */
final class Forwarder implements DnsEngine.Upstream {
    /** הסביבה: איזה שרתים, ואיך להגן על socket מלולאה בתוך ה-VPN. */
    interface Env {
        List<String> servers();
        void prepare(DatagramSocket s) throws IOException;
        void prepare(Socket s) throws IOException;
    }

    private final Env env;
    private volatile int lastGood = 0;

    Forwarder(Env env) { this.env = env; }

    @Override
    public byte[] query(byte[] q) {
        List<String> servers = env.servers();
        int n = servers.size();
        for (int k = 0; k < n; k++) {
            int idx = (lastGood + k) % n;
            String host = servers.get(idx);
            byte[] r = viaUdp(host, q);
            if (r != null && r.length >= 12 && (r[2] & 0x02) != 0) {
                byte[] full = viaTcp(host, q);
                if (full != null) r = full;
            }
            if (r != null && r.length >= 12) {
                lastGood = idx;
                return r;
            }
        }
        return null;
    }

    private byte[] viaUdp(String host, byte[] q) {
        try (DatagramSocket s = new DatagramSocket()) {
            env.prepare(s);
            s.setSoTimeout(1500);
            s.send(new DatagramPacket(q, q.length, InetAddress.getByName(host), 53));
            byte[] buf = new byte[4096];
            DatagramPacket resp = new DatagramPacket(buf, buf.length);
            // מתעלם מתשובות עם txid שגוי (למשל תשובה מאוחרת לשאילתה קודמת)
            long deadline = System.currentTimeMillis() + 1500;
            while (true) {
                s.receive(resp);
                if (resp.getLength() >= 12 && buf[0] == q[0] && buf[1] == q[1]) {
                    byte[] r = new byte[resp.getLength()];
                    System.arraycopy(buf, 0, r, 0, r.length);
                    return r;
                }
                long left = deadline - System.currentTimeMillis();
                if (left <= 0) return null;
                s.setSoTimeout((int) left);
            }
        } catch (IOException | RuntimeException e) {
            return null;
        }
    }

    private byte[] viaTcp(String host, byte[] q) {
        try (Socket s = new Socket()) {
            env.prepare(s);
            s.connect(new InetSocketAddress(InetAddress.getByName(host), 53), 2000);
            s.setSoTimeout(3000);
            byte[] framed = new byte[q.length + 2];
            framed[0] = (byte) (q.length >> 8); framed[1] = (byte) q.length;
            System.arraycopy(q, 0, framed, 2, q.length);
            s.getOutputStream().write(framed);
            s.getOutputStream().flush();
            DataInputStream in = new DataInputStream(s.getInputStream());
            int len = in.readUnsignedShort();
            if (len < 12) return null;
            byte[] r = new byte[len];
            in.readFully(r);
            return r;
        } catch (IOException | RuntimeException e) {
            return null;
        }
    }
}
