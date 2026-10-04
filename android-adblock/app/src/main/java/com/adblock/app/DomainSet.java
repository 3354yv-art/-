package com.adblock.app;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.util.AbstractSet;
import java.util.Arrays;
import java.util.Iterator;

/**
 * קבוצת דומיינים קומפקטית: שומרת רק hash של 64 ביט לכל דומיין (8 בתים במקום ~130),
 * כך שמיליוני דומיינים תופסים כמה MB, נטענים מקובץ בינארי באלפיות שנייה, והחיפוש מהיר.
 * הסיכוי להתנגשות שגויה זניח (~1e-13 לשאילתה). ניתן לחבר כמה חלקים (parts).
 */
final class DomainSet extends AbstractSet<String> {
    private static final int MAGIC = 0x41444231; // "ADB1"
    static final DomainSet EMPTY = new DomainSet(new long[0][]);

    private final long[][] parts;
    private final int size;

    DomainSet(long[]... parts) {
        this.parts = parts;
        int n = 0;
        for (long[] p : parts) n += p.length;
        this.size = n;
    }

    static long hash(String s) {
        long h = 0xcbf29ce484222325L;
        for (int i = 0; i < s.length(); i++) { h ^= s.charAt(i); h *= 0x100000001b3L; }
        h ^= h >>> 30; h *= 0xbf58476d1ce4e5b9L;
        h ^= h >>> 27; h *= 0x94d049bb133111ebL;
        h ^= h >>> 31;
        return h;
    }

    @Override public boolean contains(Object o) {
        if (!(o instanceof String)) return false;
        long h = hash((String) o);
        for (long[] p : parts) if (Arrays.binarySearch(p, h) >= 0) return true;
        return false;
    }

    @Override public int size() { return size; }
    @Override public boolean isEmpty() { return size == 0; }
    @Override public Iterator<String> iterator() { throw new UnsupportedOperationException("hash-only set"); }

    DomainSet with(DomainSet other) {
        long[][] all = new long[parts.length + other.parts.length][];
        System.arraycopy(parts, 0, all, 0, parts.length);
        System.arraycopy(other.parts, 0, all, parts.length, other.parts.length);
        return new DomainSet(all);
    }

    // ------------------------------------------------------------------ builder

    /** אוסף hash-ים תוך כדי פענוח; בסוף ממיין ומסיר כפילויות. */
    static final class Builder extends AbstractSet<String> {
        private long[] a = new long[1 << 16];
        private int n;

        @Override public boolean add(String s) {
            if (n == a.length) a = Arrays.copyOf(a, a.length * 2);
            a[n++] = hash(s);
            return true;
        }
        @Override public int size() { return n; }
        @Override public Iterator<String> iterator() { throw new UnsupportedOperationException(); }

        void addHash(long h) {
            if (n == a.length) a = Arrays.copyOf(a, a.length * 2);
            a[n++] = h;
        }

        long[] build() {
            long[] r = Arrays.copyOf(a, n);
            Arrays.sort(r);
            int m = 0;
            for (int i = 0; i < r.length; i++) if (i == 0 || r[i] != r[i - 1]) r[m++] = r[i];
            return Arrays.copyOf(r, m);
        }
    }

    // ------------------------------------------------------------------ file format

    static void write(File f, long[] hashes) throws IOException {
        File tmp = new File(f.getPath() + ".tmp");
        try (FileOutputStream out = new FileOutputStream(tmp)) {
            ByteBuffer bb = ByteBuffer.allocate(8 + hashes.length * 8);
            bb.putInt(MAGIC).putInt(hashes.length);
            for (long h : hashes) bb.putLong(h);
            out.write(bb.array());
        }
        if (!tmp.renameTo(f)) {
            f.delete();
            if (!tmp.renameTo(f)) throw new IOException("rename failed");
        }
    }

    /** קורא קובץ שנכתב ב-write(). מחזיר null אם חסר/פגום. */
    static long[] read(File f) {
        if (!f.exists() || f.length() < 8) return null;
        try (FileInputStream in = new FileInputStream(f); FileChannel ch = in.getChannel()) {
            ByteBuffer bb = ByteBuffer.allocate((int) f.length());
            while (bb.hasRemaining() && ch.read(bb) >= 0) { }
            bb.flip();
            if (bb.getInt() != MAGIC) return null;
            int n = bb.getInt();
            if (n < 0 || bb.remaining() != n * 8L) return null;
            long[] r = new long[n];
            bb.asLongBuffer().get(r);
            return r;
        } catch (IOException | RuntimeException e) {
            return null;
        }
    }
}
