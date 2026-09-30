package com.adblock.app;

import java.io.*;
import java.net.*;
import java.util.*;
import java.util.concurrent.*;

/** בדיקה: מעבד חבילות שמגיעות מ-stdin (len16 + packet) וכותב תשובות ל-stdout. משתמש בקוד האמיתי. */
public class Bridge {
    public static void main(String[] a) throws Exception {
        final DataOutputStream out = new DataOutputStream(new BufferedOutputStream(System.out));
        DataInputStream in = new DataInputStream(new BufferedInputStream(System.in));
        Forwarder fw = new Forwarder(new Forwarder.Env() {
            public List<String> servers() { return Arrays.asList("1.1.1.1", "9.9.9.9"); }
            public void prepare(DatagramSocket s) {}
            public void prepare(Socket s) {}
        });
        DnsEngine engine = new DnsEngine(fw, (n, b) -> System.err.println((b ? "BLOCK " : "PASS  ") + n), 20000, 500);
        engine.setLists(new HashSet<>(Arrays.asList("doubleclick.net", "tracker.example")), new HashSet<String>());
        engine.setDohBlock(new HashSet<>(Arrays.asList(DnsEngine.DOH_HOSTS)));
        PacketHandler ph = new PacketHandler(engine, pkt -> {
            synchronized (out) {
                try { out.writeShort(pkt.length); out.write(pkt); out.flush(); } catch (IOException e) { }
            }
        }, Executors.newFixedThreadPool(8));
        while (true) {
            int n;
            try { n = in.readUnsignedShort(); } catch (EOFException e) { return; }
            byte[] p = new byte[n];
            in.readFully(p);
            ph.handle(p, n);
        }
    }
}
