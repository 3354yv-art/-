// מנוע שחזור קבצים: סורק כונן ברמת הבתים ומזהה קבצים לפי החתימה והמבנה שלהם.
// נכתב ב-C# 5 כדי ש-PowerShell 5.1 (שמגיע עם כל Windows) יוכל לקמפל אותו.
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace Recovery
{
    public abstract class BlockSource : IDisposable
    {
        public abstract long Length { get; }
        public abstract int Alignment { get; }
        // offset חייב להיות כפולה של Alignment; מחזיר כמה בתים נקראו
        public abstract int ReadAligned(long offset, byte[] buffer, int count);
        public virtual void Dispose() { }
    }

    // קריאה מקובץ תמונת-דיסק (לבדיקות)
    public class FileBlockSource : BlockSource
    {
        private FileStream fs;
        public FileBlockSource(string path)
        {
            fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        }
        public override long Length { get { return fs.Length; } }
        public override int Alignment { get { return 512; } }
        public override int ReadAligned(long offset, byte[] buffer, int count)
        {
            fs.Seek(offset, SeekOrigin.Begin);
            int total = 0;
            while (total < count)
            {
                int n = fs.Read(buffer, total, count - total);
                if (n <= 0) break;
                total += n;
            }
            return total;
        }
        public override void Dispose() { fs.Dispose(); }
    }

    // קריאה ישירה מכונן Windows (דורש הרשאות מנהל)
    public class VolumeSource : BlockSource
    {
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool DeviceIoControl(SafeFileHandle h, uint code, byte[] inBuf, int inSize, byte[] outBuf, int outSize, out int returned, IntPtr overlapped);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool ReadFile(SafeFileHandle h, byte[] buffer, int count, out int read, IntPtr overlapped);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetFilePointerEx(SafeFileHandle h, long distance, out long newPos, uint method);
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool GetDiskFreeSpace(string root, out uint sectorsPerCluster, out uint bytesPerSector, out uint freeClusters, out uint totalClusters);

        private const uint IOCTL_DISK_GET_LENGTH_INFO = 0x0007405C;
        private const uint FSCTL_GET_VOLUME_BITMAP = 0x0009006F;
        private const int ERROR_MORE_DATA = 234;

        private SafeFileHandle handle;
        private long length;
        private int sector;
        public int ClusterSize;
        public long ReadErrors;

        public VolumeSource(char letter)
        {
            string root = letter + ":\\";
            uint spc, bps, fc, tc;
            if (!GetDiskFreeSpace(root, out spc, out bps, out fc, out tc))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            sector = (int)bps;
            ClusterSize = (int)(spc * bps);

            handle = CreateFile("\\\\.\\" + letter + ":", 0x80000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
            if (handle.IsInvalid)
                throw new Win32Exception(Marshal.GetLastWin32Error());

            byte[] outBuf = new byte[8];
            int ret;
            if (DeviceIoControl(handle, IOCTL_DISK_GET_LENGTH_INFO, null, 0, outBuf, 8, out ret, IntPtr.Zero))
                length = BitConverter.ToInt64(outBuf, 0);
            else
                length = (long)tc * spc * bps;
            length -= length % sector;
        }

        public override long Length { get { return length; } }
        public override int Alignment { get { return sector; } }

        public override int ReadAligned(long offset, byte[] buffer, int count)
        {
            if (offset >= length) return 0;
            if (offset + count > length) count = (int)(length - offset);
            long np;
            int read;
            if (SetFilePointerEx(handle, offset, out np, 0) && ReadFile(handle, buffer, count, out read, IntPtr.Zero) && read == count)
                return count;
            // סקטורים פגומים: קוראים סקטור-סקטור ומאפסים את מה שלא נקרא
            byte[] one = new byte[sector];
            for (int i = 0; i < count; i += sector)
            {
                if (SetFilePointerEx(handle, offset + i, out np, 0) && ReadFile(handle, one, sector, out read, IntPtr.Zero) && read == sector)
                    Buffer.BlockCopy(one, 0, buffer, i, sector);
                else
                {
                    Array.Clear(buffer, i, sector);
                    ReadErrors++;
                }
            }
            return count;
        }

        // מפת האשכולות התפוסים של NTFS: ביט 1 = תפוס. מאפשר לסרוק רק שטח פנוי.
        public byte[] GetVolumeBitmap(out long clusters)
        {
            clusters = 0;
            byte[] input = new byte[8];
            byte[] head = new byte[64];
            int ret;
            if (!DeviceIoControl(handle, FSCTL_GET_VOLUME_BITMAP, input, 8, head, head.Length, out ret, IntPtr.Zero)
                && Marshal.GetLastWin32Error() != ERROR_MORE_DATA)
                return null;
            long size = BitConverter.ToInt64(head, 8);
            byte[] full = new byte[16 + (size + 7) / 8];
            if (!DeviceIoControl(handle, FSCTL_GET_VOLUME_BITMAP, input, 8, full, full.Length, out ret, IntPtr.Zero))
                return null;
            clusters = size;
            byte[] bits = new byte[(size + 7) / 8];
            Buffer.BlockCopy(full, 16, bits, 0, bits.Length);
            return bits;
        }

        public override void Dispose() { handle.Dispose(); }
    }

    // גישה אקראית לבתים עם מטמון, מעל מקור שדורש קריאות מיושרות
    public class Reader
    {
        private BlockSource src;
        private byte[] cache;
        private long cacheStart = -1;
        private int cacheLen;
        public long Length;

        public Reader(BlockSource source)
        {
            src = source;
            Length = source.Length;
            cache = new byte[1 << 20];
        }

        private void Load(long pos)
        {
            long start = pos - pos % cache.Length;
            cacheStart = start;
            cacheLen = src.ReadAligned(start, cache, (int)Math.Min(cache.Length, Length - start));
        }

        public int ByteAt(long pos)
        {
            if (pos < 0 || pos >= Length) return -1;
            if (pos < cacheStart || pos >= cacheStart + cacheLen)
            {
                Load(pos);
                if (pos >= cacheStart + cacheLen) return -1;
            }
            return cache[pos - cacheStart];
        }

        public int Read(long pos, byte[] dst, int off, int count)
        {
            int done = 0;
            while (done < count)
            {
                long p = pos + done;
                if (p >= Length) break;
                if (p < cacheStart || p >= cacheStart + cacheLen)
                {
                    Load(p);
                    if (p >= cacheStart + cacheLen) break;
                }
                int avail = (int)(cacheStart + cacheLen - p);
                int n = Math.Min(avail, count - done);
                Buffer.BlockCopy(cache, (int)(p - cacheStart), dst, off + done, n);
                done += n;
            }
            return done;
        }

        public long BE16(long p) { int a = ByteAt(p), b = ByteAt(p + 1); if ((a | b) < 0) return -1; return (a << 8) | b; }
        public long LE16(long p) { int a = ByteAt(p), b = ByteAt(p + 1); if ((a | b) < 0) return -1; return (b << 8) | a; }
        public long BE32(long p) { long a = BE16(p), b = BE16(p + 2); if (a < 0 || b < 0) return -1; return (a << 16) | b; }
        public long LE32(long p) { long a = LE16(p), b = LE16(p + 2); if (a < 0 || b < 0) return -1; return (b << 16) | a; }
        public long BE64(long p) { long a = BE32(p), b = BE32(p + 4); if (a < 0 || b < 0 || a > 0x7FFFFFFF) return -1; return (a << 32) | b; }

        public string Ascii(long p, int n)
        {
            byte[] b = new byte[n];
            if (Read(p, b, 0, n) != n) return null;
            return Encoding.ASCII.GetString(b);
        }

        // מחפש רצף בתים בטווח [from, limit); מחזיר מיקום או -1
        public long Find(byte[] pattern, long from, long limit)
        {
            byte[] buf = new byte[1 << 20];
            long pos = from;
            if (limit > Length) limit = Length;
            while (pos < limit)
            {
                int want = (int)Math.Min(buf.Length, limit - pos + pattern.Length - 1);
                int n = Read(pos, buf, 0, want);
                if (n < pattern.Length) return -1;
                int last = n - pattern.Length;
                for (int i = 0; i <= last; i++)
                {
                    if (buf[i] != pattern[0]) continue;
                    int k = 1;
                    while (k < pattern.Length && buf[i + k] == pattern[k]) k++;
                    if (k == pattern.Length && pos + i < limit) return pos + i;
                }
                pos += last + 1;
            }
            return -1;
        }
    }

    public class Scanner
    {
        // הגדרות
        public bool Jpg = true, Png = true, Gif = true, Heic = true, Pdf = true, Office = true, Video = true;
        public long MinSize = 4096;
        public int Step = 512;
        public byte[] Bitmap;       // null = סריקת כל הכונן
        public long BitmapClusters;
        public int ClusterSize = 4096;

        // מצב (נקרא מה-UI)
        public long Position;
        public long Total;
        public int Found;
        public long BytesRecovered;
        public volatile bool Cancel;
        public volatile bool Running;
        public volatile string Error;
        public DateTime StartedAt;

        private BlockSource src;
        private Reader rd;
        private string outDir;
        private Thread thread;
        private readonly Dictionary<string, int> counts = new Dictionary<string, int>();
        private readonly List<string> newLines = new List<string>();

        private const long MB = 1024L * 1024;

        public Scanner(BlockSource source, string outputFolder)
        {
            src = source;
            rd = new Reader(source);
            outDir = outputFolder;
            Total = source.Length;
        }

        public void Start()
        {
            Running = true;
            StartedAt = DateTime.Now;
            thread = new Thread(Run);
            thread.IsBackground = true;
            thread.Start();
        }

        public void RunSync()
        {
            Running = true;
            StartedAt = DateTime.Now;
            Run();
        }

        // שורות חדשות ליומן מאז הקריאה הקודמת
        public string[] TakeLines()
        {
            lock (newLines)
            {
                string[] a = newLines.ToArray();
                newLines.Clear();
                return a;
            }
        }

        public string Summary()
        {
            lock (counts)
            {
                StringBuilder sb = new StringBuilder();
                foreach (KeyValuePair<string, int> kv in counts)
                {
                    if (sb.Length > 0) sb.Append("   ");
                    sb.Append(kv.Key.ToUpper()).Append(": ").Append(kv.Value);
                }
                return sb.ToString();
            }
        }

        private bool IsAllocated(long pos)
        {
            if (Bitmap == null) return false;
            long c = pos / ClusterSize;
            if (c >= BitmapClusters) return false;
            return (Bitmap[c >> 3] & (1 << (int)(c & 7))) != 0;
        }

        private long NextFree(long pos)
        {
            if (Bitmap == null) return pos;
            long c = pos / ClusterSize;
            if (c >= BitmapClusters || !IsAllocated(pos)) return pos;
            while (c < BitmapClusters)
            {
                if ((c & 7) == 0 && Bitmap[c >> 3] == 0xFF) { c += 8; continue; }
                if ((Bitmap[c >> 3] & (1 << (int)(c & 7))) == 0) break;
                c++;
            }
            return c * ClusterSize;
        }

        private int FreeRun(long pos, int max)
        {
            if (Bitmap == null) return max;
            int len = 0;
            while (len < max && !IsAllocated(pos + len)) len += ClusterSize;
            return Math.Min(len, max);
        }

        private void Run()
        {
            try
            {
                Directory.CreateDirectory(outDir);
                byte[] chunk = new byte[4 * (int)MB];
                long pos = 0;
                while (pos < Total && !Cancel)
                {
                    pos = NextFree(pos);
                    Position = pos;
                    if (pos >= Total) break;
                    int want = FreeRun(pos, chunk.Length);
                    int n = src.ReadAligned(pos, chunk, (int)Math.Min(want, Total - pos));
                    if (n <= 0) break;

                    long jumpTo = -1;
                    for (int i = 0; i + 16 <= n && !Cancel; i += Step)
                    {
                        string kind = Detect(chunk, i);
                        if (kind == null) continue;
                        long start = pos + i;
                        string ext;
                        long len = Measure(kind, start, out ext);
                        if (len < MinSize || ext == null) continue;
                        Save(start, len, ext);
                        long end = start + len;
                        jumpTo = end + (Step - end % Step) % Step;
                        break;
                    }
                    pos = jumpTo > pos ? jumpTo : pos + n;
                }
                Position = Math.Min(pos, Total);
            }
            catch (Exception ex)
            {
                Error = ex.Message;
            }
            finally
            {
                Running = false;
            }
        }

        private static bool Match(byte[] b, int i, string s)
        {
            for (int k = 0; k < s.Length; k++) if (b[i + k] != (byte)s[k]) return false;
            return true;
        }

        private string Detect(byte[] b, int i)
        {
            if (Jpg && b[i] == 0xFF && b[i + 1] == 0xD8 && b[i + 2] == 0xFF)
            {
                int m = b[i + 3];
                if ((m >= 0xE0 && m <= 0xEF) || m == 0xDB || m == 0xFE || m == 0xC0 || m == 0xC4) return "jpg";
            }
            if (Png && b[i] == 0x89 && Match(b, i + 1, "PNG\r\n\x1A\n")) return "png";
            if (Gif && (Match(b, i, "GIF87a") || Match(b, i, "GIF89a"))) return "gif";
            if (Pdf && Match(b, i, "%PDF-")) return "pdf";
            if (Office && b[i] == 0x50 && b[i + 1] == 0x4B && b[i + 2] == 3 && b[i + 3] == 4) return "zip";
            if ((Video || Heic) && Match(b, i + 4, "ftyp"))
            {
                int size = (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];
                if (size >= 8 && size <= 512) return "iso";
            }
            return null;
        }

        private long Measure(string kind, long s, out string ext)
        {
            ext = kind;
            switch (kind)
            {
                case "jpg": return MeasureJpeg(s);
                case "png": return MeasurePng(s);
                case "gif": return MeasureGif(s);
                case "pdf": return MeasurePdf(s);
                case "zip": return MeasureZip(s, out ext);
                case "iso": return MeasureIsoMedia(s, out ext);
            }
            return -1;
        }

        private long MeasureJpeg(long s)
        {
            long max = Math.Min(s + 100 * MB, rd.Length);
            long p = s + 2;
            bool sawScan = false;
            while (p < max)
            {
                if (rd.ByteAt(p) != 0xFF) return -1;
                int m = rd.ByteAt(p + 1);
                if (m < 0) return -1;
                if (m == 0xFF) { p++; continue; }
                if (m == 0xD9) return sawScan ? p + 2 - s : -1;
                if (m == 0xD8 || m == 0x00) return -1;
                if (m == 0x01 || (m >= 0xD0 && m <= 0xD7)) { p += 2; continue; }
                long len = rd.BE16(p + 2);
                if (len < 2) return -1;
                p += 2 + len;
                if (m != 0xDA) continue;
                sawScan = true;
                // נתוני תמונה דחוסים: רצים עד מרקר שאינו 00 / RST
                while (p < max)
                {
                    int x = rd.ByteAt(p);
                    if (x < 0) return -1;
                    if (x != 0xFF) { p++; continue; }
                    int y = rd.ByteAt(p + 1);
                    if (y < 0) return -1;
                    if (y == 0x00 || (y >= 0xD0 && y <= 0xD7)) { p += 2; continue; }
                    if (y == 0xFF) { p++; continue; }
                    break;
                }
            }
            return -1;
        }

        private static bool IsChunkName(string t)
        {
            if (t == null) return false;
            foreach (char c in t) if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'))) return false;
            return true;
        }

        private long MeasurePng(long s)
        {
            long max = Math.Min(s + 200 * MB, rd.Length);
            long p = s + 8;
            if (rd.Ascii(p + 4, 4) != "IHDR") return -1;
            while (p < max)
            {
                long len = rd.BE32(p);
                string type = rd.Ascii(p + 4, 4);
                if (len < 0 || len > 0x7FFFFFFF || !IsChunkName(type)) return -1;
                p += 12 + len;
                if (type == "IEND") return p <= rd.Length ? p - s : -1;
            }
            return -1;
        }

        private long SkipGifSubBlocks(long p, long max)
        {
            while (p < max)
            {
                int size = rd.ByteAt(p);
                if (size < 0) return -1;
                p++;
                if (size == 0) return p;
                p += size;
            }
            return -1;
        }

        private long MeasureGif(long s)
        {
            long max = Math.Min(s + 100 * MB, rd.Length);
            int flags = rd.ByteAt(s + 10);
            if (flags < 0) return -1;
            long p = s + 13;
            if ((flags & 0x80) != 0) p += 3 << ((flags & 7) + 1);
            while (p < max)
            {
                int b = rd.ByteAt(p);
                if (b == 0x3B) return p + 1 - s;
                if (b == 0x21)
                {
                    p = SkipGifSubBlocks(p + 2, max);
                }
                else if (b == 0x2C)
                {
                    int f = rd.ByteAt(p + 9);
                    if (f < 0) return -1;
                    p += 10;
                    if ((f & 0x80) != 0) p += 3 << ((f & 7) + 1);
                    p = SkipGifSubBlocks(p + 1, max);
                }
                else return -1;
                if (p < 0) return -1;
            }
            return -1;
        }

        private long MeasurePdf(long s)
        {
            long max = Math.Min(s + 500 * MB, rd.Length);
            byte[] eof = Encoding.ASCII.GetBytes("%%EOF");
            byte[] buf = new byte[Step];
            long lastEnd = -1;
            long searchFrom = s;
            // PDF יכול להכיל כמה %%EOF (עדכונים מצטברים) – לוקחים את האחרון לפני שמתחיל קובץ אחר / אזור ריק
            while (true)
            {
                long limit = lastEnd < 0 ? max : Math.Min(max, lastEnd + 32 * MB);
                long e = rd.Find(eof, searchFrom, limit);
                long checkTo = e < 0 ? limit : e;
                if (lastEnd >= 0)
                {
                    long b = lastEnd + (Step - lastEnd % Step) % Step;
                    for (; b + Step <= checkTo; b += Step)
                    {
                        if (rd.Read(b, buf, 0, Step) < 16) return lastEnd - s;
                        if (Detect(buf, 0) != null || IsZeros(buf)) return lastEnd - s;
                    }
                }
                if (e < 0) return lastEnd < 0 ? -1 : lastEnd - s;
                lastEnd = e + 5;
                int c = rd.ByteAt(lastEnd);
                if (c == '\r') { lastEnd++; c = rd.ByteAt(lastEnd); }
                if (c == '\n') lastEnd++;
                searchFrom = e + 5;
            }
        }

        private static bool IsZeros(byte[] b)
        {
            for (int i = 0; i < b.Length; i++) if (b[i] != 0) return false;
            return true;
        }

        private long MeasureZip(long s, out string ext)
        {
            ext = null;
            long max = Math.Min(s + 1024 * MB, rd.Length);
            long p = s;
            long cdGuess = -1;
            // מעבר על הכותרות המקומיות – מהיר ומדויק כשאין data descriptor
            while (p < max)
            {
                long sig = rd.LE32(p);
                if (sig == 0x04034B50)
                {
                    long flags = rd.LE16(p + 6);
                    long csize = rd.LE32(p + 18);
                    long nlen = rd.LE16(p + 26), xlen = rd.LE16(p + 28);
                    if (flags < 0 || csize < 0 || nlen < 0 || xlen < 0) return -1;
                    if ((flags & 8) != 0 || csize == 0xFFFFFFFF) break;
                    p += 30 + nlen + xlen + csize;
                    continue;
                }
                if (sig == 0x02014B50) cdGuess = p;
                break;
            }
            byte[] eocd = { 0x50, 0x4B, 0x05, 0x06 };
            long from = cdGuess > 0 ? cdGuess : s + 30;
            while (true)
            {
                long e = rd.Find(eocd, from, max);
                if (e < 0) return -1;
                long cdSize = rd.LE32(e + 12), cdOff = rd.LE32(e + 16), comment = rd.LE16(e + 20);
                if (cdSize >= 0 && cdOff >= 0 && comment >= 0 && cdOff + cdSize == e - s)
                {
                    ext = ZipKind(s + cdOff, cdSize);
                    long end = e + 22 + comment;
                    return end <= rd.Length ? end - s : -1;
                }
                from = e + 1;
            }
        }

        private string ZipKind(long cd, long cdSize)
        {
            int n = (int)Math.Min(cdSize, 2 * MB);
            byte[] b = new byte[n];
            rd.Read(cd, b, 0, n);
            string names = Encoding.ASCII.GetString(b);
            if (names.Contains("word/document")) return "docx";
            if (names.Contains("xl/workbook")) return "xlsx";
            if (names.Contains("ppt/presentation")) return "pptx";
            if (names.Contains("AndroidManifest.xml")) return "apk";
            if (names.Contains("META-INF/MANIFEST.MF")) return "jar";
            return "zip";
        }

        private static readonly string[] Boxes = {
            "moov", "mdat", "free", "skip", "wide", "uuid", "pnot", "meta", "pdin",
            "moof", "mfra", "sidx", "styp", "emsg", "prft", "junk", "PICT", "idat", "iinf", "iloc"
        };

        private long MeasureIsoMedia(long s, out string ext)
        {
            ext = null;
            string brand = rd.Ascii(s + 8, 4);
            if (brand == null) return -1;
            bool heic = brand == "heic" || brand == "heix" || brand == "mif1" || brand == "msf1" || brand == "hevc" || brand == "avif";
            if (heic && !Heic) return -1;
            if (!heic && !Video) return -1;

            long p = s + rd.BE32(s);
            bool moov = false, mdat = false, meta = false;
            while (p < rd.Length)
            {
                long size = rd.BE32(p);
                string type = rd.Ascii(p + 4, 4);
                if (size < 0 || type == null || Array.IndexOf(Boxes, type) < 0) break;
                long hdr = 8;
                if (size == 1) { size = rd.BE64(p + 8); hdr = 16; }
                if (size < hdr) break;
                if (type == "moov") moov = true;
                if (type == "mdat") mdat = true;
                if (type == "meta") meta = true;
                p += size;
            }
            if (p > rd.Length || !mdat) return -1;
            if (heic)
            {
                if (!meta) return -1;
                ext = brand == "avif" ? "avif" : "heic";
            }
            else
            {
                if (!moov) return -1;
                if (brand == "qt  ") ext = "mov";
                else if (brand.StartsWith("3gp")) ext = "3gp";
                else if (brand == "M4A ") ext = "m4a";
                else ext = "mp4";
            }
            return p - s;
        }

        private void Save(long start, long len, string ext)
        {
            string dir = Path.Combine(outDir, ext.ToUpper());
            Directory.CreateDirectory(dir);
            int num;
            lock (counts)
            {
                int c;
                counts.TryGetValue(ext, out c);
                counts[ext] = c + 1;
                num = c + 1;
            }
            string name = string.Format("{0}_{1:D5}.{2}", ext, num, ext);
            string path = Path.Combine(dir, name);
            byte[] buf = new byte[1 << 20];
            using (FileStream f = new FileStream(path, FileMode.Create, FileAccess.Write))
            {
                long done = 0;
                while (done < len)
                {
                    int n = rd.Read(start + done, buf, 0, (int)Math.Min(buf.Length, len - done));
                    if (n <= 0) break;
                    f.Write(buf, 0, n);
                    done += n;
                }
            }
            Found++;
            BytesRecovered += len;
            lock (newLines) newLines.Add(ext.ToUpper() + "\\" + name + "  (" + FormatSize(len) + ")");
        }

        public static string FormatSize(long b)
        {
            if (b >= 1024L * MB) return (b / (1024.0 * MB)).ToString("0.0") + " GB";
            if (b >= MB) return (b / (double)MB).ToString("0.0") + " MB";
            return (b / 1024.0).ToString("0") + " KB";
        }
    }
}
