# שחזור קבצים – תוכנה לשחזור קבצים שנמחקו ב-Windows
# הפעלה: לחיצה כפולה על "Start.bat" (או: powershell -ExecutionPolicy Bypass -STA -File FileRecovery.ps1)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

function Show-Error($text) {
    [void][System.Windows.Forms.MessageBox]::Show($text, 'שחזור קבצים', 'OK', 'Error',
        'Button1', [System.Windows.Forms.MessageBoxOptions]::RtlReading -bor [System.Windows.Forms.MessageBoxOptions]::RightAlign)
}

function Ask($text, $icon = 'Question') {
    $r = [System.Windows.Forms.MessageBox]::Show($text, 'שחזור קבצים', 'YesNo', $icon,
        'Button2', [System.Windows.Forms.MessageBoxOptions]::RtlReading -bor [System.Windows.Forms.MessageBoxOptions]::RightAlign)
    return $r -eq 'Yes'
}

function Show-Info($text) {
    [void][System.Windows.Forms.MessageBox]::Show($text, 'שחזור קבצים', 'OK', 'Information',
        'Button1', [System.Windows.Forms.MessageBoxOptions]::RtlReading -bor [System.Windows.Forms.MessageBoxOptions]::RightAlign)
}

# ---------- הרשאות מנהל (נדרשות לסריקה עמוקה) ----------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and $env:FILERECOVERY_NO_ELEVATE -ne '1') {
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"")
        exit
    } catch {
        # המשתמש סירב – ממשיכים בלי סריקה עמוקה
    }
}

# הסתרת חלון ה-PowerShell השחור
try {
    Add-Type -Name ConsoleWin -Namespace Native -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
'@
    [void][Native.ConsoleWin]::ShowWindow([Native.ConsoleWin]::GetConsoleWindow(), 0)
} catch { }

# ---------- מנוע הסריקה (C#) ----------
$engineSource = @'
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
'@
try {
    Add-Type -TypeDefinition $engineSource -Language CSharp
} catch {
    Show-Error ("טעינת מנוע השחזור נכשלה:`n" + $_.Exception.Message)
    exit 1
}

# ---------- סל המיחזור ----------
# כל קובץ שנמחק לסל נשמר כ-$R..., ולצידו קובץ $I... שמכיל את הנתיב המקורי, הגודל ותאריך המחיקה
function Read-RecycleInfo([string]$iPath) {
    $b = [IO.File]::ReadAllBytes($iPath)
    if ($b.Length -lt 24) { return $null }
    $ver = [BitConverter]::ToInt64($b, 0)
    $size = [BitConverter]::ToInt64($b, 8)
    $date = [DateTime]::FromFileTime([BitConverter]::ToInt64($b, 16))
    if ($ver -ge 2 -and $b.Length -ge 28) {
        $chars = [BitConverter]::ToInt32($b, 24)
        $orig = [Text.Encoding]::Unicode.GetString($b, 28, [Math]::Min($chars * 2, $b.Length - 28))
    } else {
        $orig = [Text.Encoding]::Unicode.GetString($b, 24, [Math]::Min(520, $b.Length - 24))
    }
    $orig = $orig.Split([char]0)[0]
    [pscustomobject]@{ Original = $orig; Size = $size; Deleted = $date }
}

function Get-RecycleItems {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($d in [IO.DriveInfo]::GetDrives()) {
        if (-not $d.IsReady) { continue }
        $bin = Join-Path $d.RootDirectory.FullName ('$Recycle.Bin\' + $sid)
        if (-not [IO.Directory]::Exists($bin)) { continue }
        foreach ($i in [IO.Directory]::GetFiles($bin, '$I*')) {
            $r = Join-Path $bin ('$R' + [IO.Path]::GetFileName($i).Substring(2))
            $isDir = [IO.Directory]::Exists($r)
            if (-not $isDir -and -not [IO.File]::Exists($r)) { continue }
            try { $info = Read-RecycleInfo $i } catch { continue }
            if (-not $info -or -not $info.Original) { continue }
            $items.Add([pscustomobject]@{
                Name     = [IO.Path]::GetFileName($info.Original)
                Original = $info.Original
                Deleted  = $info.Deleted
                Size     = $info.Size
                IsFolder = $isDir
                IFile    = $i
                RFile    = $r
            })
        }
    }
    return @($items | Sort-Object Deleted -Descending)
}

function Get-FreeName([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $path }
    $dir = [IO.Path]::GetDirectoryName($path)
    $base = [IO.Path]::GetFileNameWithoutExtension($path)
    $ext = [IO.Path]::GetExtension($path)
    for ($k = 1; ; $k++) {
        $p = Join-Path $dir ("$base (משוחזר $k)$ext")
        if (-not (Test-Path -LiteralPath $p)) { return $p }
    }
}

function Restore-RecycleItem($it) {
    $target = Get-FreeName $it.Original
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
    if ($it.IsFolder) { [IO.Directory]::Move($it.RFile, $target) } else { [IO.File]::Move($it.RFile, $target) }
    try { [IO.File]::Delete($it.IFile) } catch { }
    return $target
}

function Copy-RecycleItem($it, [string]$folder) {
    $target = Get-FreeName (Join-Path $folder $it.Name)
    if ($it.IsFolder) { Copy-Item -LiteralPath $it.RFile -Destination $target -Recurse }
    else { [IO.File]::Copy($it.RFile, $target) }
    return $target
}

function Format-Size([long]$b) { [Recovery.Scanner]::FormatSize($b) }

function Get-DriveChoices {
    foreach ($d in [IO.DriveInfo]::GetDrives()) {
        if (-not $d.IsReady) { continue }
        if ($d.DriveType -ne 'Fixed' -and $d.DriveType -ne 'Removable') { continue }
        $label = if ($d.VolumeLabel) { $d.VolumeLabel } else { 'כונן' }
        [pscustomobject]@{
            Letter = $d.Name.Substring(0, 1)
            Format = $d.DriveFormat
            Text   = "{0}  {1}  ({2}, {3})" -f $d.Name.Substring(0, 2), $label, $d.DriveFormat, (Format-Size $d.TotalSize)
        }
    }
}

# ---------- עזרי ממשק ----------
$font = New-Object Drawing.Font('Segoe UI', 10)
$bold = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold)

function New-Label([string]$text, [switch]$Bold, [string]$Color) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $text
    $l.AutoSize = $true
    $l.MaximumSize = New-Object Drawing.Size(860, 0)
    $l.Margin = New-Object Windows.Forms.Padding(6, 6, 6, 2)
    if ($Bold) { $l.Font = $bold }
    if ($Color) { $l.ForeColor = [Drawing.Color]::FromName($Color) }
    $l
}

function New-Button([string]$text, [scriptblock]$onClick) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $text
    $b.AutoSize = $true
    $b.Padding = New-Object Windows.Forms.Padding(8, 3, 8, 3)
    $b.Add_Click($onClick)
    $b
}

function New-Flow {
    $f = New-Object Windows.Forms.FlowLayoutPanel
    $f.AutoSize = $true
    $f.WrapContents = $true
    $f.Dock = 'Fill'
    $f.Margin = New-Object Windows.Forms.Padding(2)
    foreach ($c in $args) { $f.Controls.Add($c) }
    $f
}

function New-Page([string]$title) {
    $page = New-Object Windows.Forms.TabPage
    $page.Text = $title
    $page.Padding = New-Object Windows.Forms.Padding(8)
    $t = New-Object Windows.Forms.TableLayoutPanel
    $t.Dock = 'Fill'
    $t.ColumnCount = 1
    [void]$t.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
    $page.Controls.Add($t)
    $page | Add-Member -NotePropertyName Table -NotePropertyValue $t
    $page
}

function Add-Row($page, $control, [switch]$Fill) {
    $t = $page.Table
    $row = $t.RowCount
    $t.RowCount = $row + 1
    if ($Fill) { [void]$t.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 100))) }
    else { [void]$t.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize))) }
    if ($Fill -or $control -is [Windows.Forms.FlowLayoutPanel]) { $control.Dock = 'Fill' }
    $t.Controls.Add($control, 0, $row)
}

function Select-Folder([string]$description) {
    $dlg = New-Object Windows.Forms.FolderBrowserDialog
    $dlg.Description = $description
    $dlg.ShowNewFolderButton = $true
    if ($dlg.ShowDialog() -eq 'OK') { return $dlg.SelectedPath }
    return $null
}

function Get-DefaultOutput([string]$exceptLetter) {
    foreach ($d in [IO.DriveInfo]::GetDrives()) {
        if ($d.IsReady -and ($d.DriveType -eq 'Fixed' -or $d.DriveType -eq 'Removable') -and
            $d.Name.Substring(0, 1) -ne $exceptLetter) {
            return (Join-Path $d.Name 'קבצים משוחזרים')
        }
    }
    return (Join-Path ([Environment]::GetFolderPath('Desktop')) 'קבצים משוחזרים')
}

# ---------- החלון הראשי ----------
$form = New-Object Windows.Forms.Form
$form.Text = 'שחזור קבצים'
$form.Font = $font
$form.RightToLeft = 'Yes'
$form.RightToLeftLayout = $true
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object Drawing.Size(940, 680)
$form.MinimumSize = New-Object Drawing.Size(760, 560)

$tabs = New-Object Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$tabs.RightToLeftLayout = $true
$form.Controls.Add($tabs)

# ===== לשונית 1: סל המיחזור =====
$pBin = New-Page 'סל המיחזור'
Add-Row $pBin (New-Label 'שלב ראשון: בדוק כאן. קבצים שנמחקו רגיל (בלי Shift) נמצאים בסל המיחזור וחוזרים במלואם, עם השם המקורי.')

$lvBin = New-Object Windows.Forms.ListView
$lvBin.View = 'Details'
$lvBin.CheckBoxes = $true
$lvBin.FullRowSelect = $true
$lvBin.RightToLeftLayout = $true
[void]$lvBin.Columns.Add('שם', 220)
[void]$lvBin.Columns.Add('מיקום מקורי', 360)
[void]$lvBin.Columns.Add('נמחק בתאריך', 140)
[void]$lvBin.Columns.Add('גודל', 90)

$txtBinFilter = New-Object Windows.Forms.TextBox
$txtBinFilter.Width = 260

function Load-Bin {
    $lvBin.BeginUpdate()
    $lvBin.Items.Clear()
    $filter = $txtBinFilter.Text.Trim()
    try { $script:binItems = Get-RecycleItems } catch { $script:binItems = @() }
    foreach ($it in $script:binItems) {
        if ($filter -and $it.Original -notlike "*$filter*") { continue }
        $name = if ($it.IsFolder) { '📁 ' + $it.Name } else { $it.Name }
        $size = if ($it.IsFolder) { 'תיקייה' } else { Format-Size $it.Size }
        $li = New-Object Windows.Forms.ListViewItem($name)
        [void]$li.SubItems.Add([IO.Path]::GetDirectoryName($it.Original))
        [void]$li.SubItems.Add($it.Deleted.ToString('dd/MM/yyyy HH:mm'))
        [void]$li.SubItems.Add($size)
        $li.Tag = $it
        [void]$lvBin.Items.Add($li)
    }
    $lvBin.EndUpdate()
    $lblBinCount.Text = "{0} פריטים בסל המיחזור" -f $lvBin.Items.Count
}

function Get-CheckedBin { @($lvBin.CheckedItems | ForEach-Object { $_.Tag }) }

$lblBinCount = New-Label ''
Add-Row $pBin (New-Flow (New-Label 'חיפוש:') $txtBinFilter (New-Button 'חפש / רענן' { Load-Bin }) $lblBinCount)
Add-Row $pBin $lvBin -Fill

$btnRestore = New-Button '↩ שחזר למקום המקורי' {
    $sel = Get-CheckedBin
    if ($sel.Count -eq 0) { Show-Info 'סמן בתיבות הסימון את הקבצים שברצונך לשחזר.'; return }
    $ok = 0; $errs = @()
    foreach ($it in $sel) {
        try { [void](Restore-RecycleItem $it); $ok++ } catch { $errs += "$($it.Name): $($_.Exception.Message)" }
    }
    Load-Bin
    $msg = "שוחזרו $ok פריטים למקומם המקורי."
    if ($errs) { $msg += "`n`nלא הצליח:`n" + ($errs -join "`n") }
    Show-Info $msg
}
$btnCopy = New-Button '📂 העתק לתיקייה אחרת...' {
    $sel = Get-CheckedBin
    if ($sel.Count -eq 0) { Show-Info 'סמן בתיבות הסימון את הקבצים שברצונך להעתיק.'; return }
    $folder = Select-Folder 'לאן להעתיק את הקבצים?'
    if (-not $folder) { return }
    $ok = 0; $errs = @()
    foreach ($it in $sel) {
        try { [void](Copy-RecycleItem $it $folder); $ok++ } catch { $errs += "$($it.Name): $($_.Exception.Message)" }
    }
    $msg = "הועתקו $ok פריטים אל:`n$folder"
    if ($errs) { $msg += "`n`nלא הצליח:`n" + ($errs -join "`n") }
    Show-Info $msg
    Start-Process explorer.exe $folder
}
$btnAll = New-Button 'סמן הכל' { foreach ($i in $lvBin.Items) { $i.Checked = $true } }
$btnNone = New-Button 'נקה סימון' { foreach ($i in $lvBin.Items) { $i.Checked = $false } }
Add-Row $pBin (New-Flow $btnRestore $btnCopy $btnAll $btnNone)
[void]$tabs.TabPages.Add($pBin)

# ===== לשונית 2: סריקה עמוקה =====
$pScan = New-Page 'סריקה עמוקה'
Add-Row $pScan (New-Label 'מחפש קבצים שנמחקו לגמרי (גם אחרי ריקון הסל או Shift+Delete) ישירות על הכונן. הקבצים חוזרים בלי השם המקורי, ממוינים לתיקיות לפי סוג.')
Add-Row $pScan (New-Label '⚠ חשוב: שמור את הקבצים המשוחזרים על כונן אחר (למשל דיסק-און-קי) – כתיבה לאותו כונן עלולה לדרוס בדיוק את מה שמנסים להציל.' -Bold -Color 'DarkRed')

$cmbDrive = New-Object Windows.Forms.ComboBox
$cmbDrive.DropDownStyle = 'DropDownList'
$cmbDrive.Width = 340
$script:driveChoices = @(Get-DriveChoices)
foreach ($d in $script:driveChoices) { [void]$cmbDrive.Items.Add($d.Text) }
if ($cmbDrive.Items.Count -gt 0) { $cmbDrive.SelectedIndex = 0 }
Add-Row $pScan (New-Flow (New-Label 'הכונן שממנו נמחקו הקבצים:') $cmbDrive)

$txtOut = New-Object Windows.Forms.TextBox
$txtOut.Width = 420
if ($script:driveChoices.Count -gt 0) { $txtOut.Text = Get-DefaultOutput $script:driveChoices[0].Letter }
$cmbDrive.Add_SelectedIndexChanged({
    $txtOut.Text = Get-DefaultOutput $script:driveChoices[$cmbDrive.SelectedIndex].Letter
})
Add-Row $pScan (New-Flow (New-Label 'שמור את הקבצים המשוחזרים ב:') $txtOut (New-Button 'בחר...' {
    $f = Select-Folder 'בחר תיקייה לשמירת הקבצים המשוחזרים (עדיף בכונן אחר)'
    if ($f) { $txtOut.Text = $f }
}))

function New-Check([string]$text, [bool]$on = $true) {
    $c = New-Object Windows.Forms.CheckBox
    $c.Text = $text
    $c.Checked = $on
    $c.AutoSize = $true
    $c
}
$chkJpg = New-Check 'JPG'
$chkPng = New-Check 'PNG'
$chkGif = New-Check 'GIF'
$chkHeic = New-Check 'HEIC (אייפון)'
$chkPdf = New-Check 'PDF'
$chkOffice = New-Check 'Word / Excel / PowerPoint / ZIP'
$chkVideo = New-Check 'סרטונים MP4 / MOV'
Add-Row $pScan (New-Flow (New-Label 'תמונות:') $chkJpg $chkPng $chkGif $chkHeic)
Add-Row $pScan (New-Flow (New-Label 'מסמכים וסרטונים:') $chkPdf $chkOffice $chkVideo)

$chkFree = New-Check 'סרוק רק שטח פנוי (מהיר יותר, בלי כפילויות של קבצים קיימים – מומלץ)'
$numMin = New-Object Windows.Forms.NumericUpDown
$numMin.Minimum = 0
$numMin.Maximum = 100000
$numMin.Value = 10
$numMin.Width = 80
Add-Row $pScan (New-Flow $chkFree)
Add-Row $pScan (New-Flow (New-Label 'דלג על קבצים קטנים מ-') $numMin (New-Label 'KB (מסנן תמונות ממוזערות)'))

$progress = New-Object Windows.Forms.ProgressBar
$progress.Maximum = 1000
$progress.Height = 22
$progress.Dock = 'Fill'
$progress.RightToLeftLayout = $true
Add-Row $pScan $progress
$lblScan = New-Label 'מוכן לסריקה.'
Add-Row $pScan $lblScan

$lstLog = New-Object Windows.Forms.ListBox
$lstLog.RightToLeft = 'No'
Add-Row $pScan $lstLog -Fill

$btnStart = New-Button '▶ התחל סריקה' { Start-DeepScan }
$btnStop = New-Button '■ עצור' { if ($script:scan) { $script:scan.Cancel = $true; $lblScan.Text = 'עוצר...' } }
$btnStop.Enabled = $false
$btnOpen = New-Button '📂 פתח את תיקיית הקבצים' {
    if (Test-Path -LiteralPath $txtOut.Text) { Start-Process explorer.exe $txtOut.Text }
}
Add-Row $pScan (New-Flow $btnStart $btnStop $btnOpen)
[void]$tabs.TabPages.Add($pScan)

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 500

function Start-DeepScan {
    if (-not $isAdmin) {
        Show-Error 'סריקה עמוקה דורשת הרשאות מנהל. סגור את התוכנה, הפעל אותה שוב ואשר את חלון ההרשאות.'
        return
    }
    if ($cmbDrive.SelectedIndex -lt 0) { return }
    $drive = $script:driveChoices[$cmbDrive.SelectedIndex]
    $out = $txtOut.Text.Trim()
    if (-not $out -or -not [IO.Path]::IsPathRooted($out)) { Show-Error 'בחר תיקייה לשמירת הקבצים.'; return }
    if ($out.Substring(0, 1) -eq $drive.Letter) {
        $q = "התיקייה נמצאת על אותו כונן שסורקים ($($drive.Letter):).`n" +
             "כתיבה לשם עלולה להרוס קבצים שעוד לא שוחזרו.`n`n" +
             "מומלץ מאוד לחבר דיסק-און-קי ולבחור אותו.`nלהמשיך בכל זאת?"
        if (-not (Ask $q 'Warning')) { return }
    }

    try {
        $script:src = [Recovery.VolumeSource]::new([char]$drive.Letter)
    } catch {
        Show-Error ("לא ניתן לפתוח את הכונן לקריאה:`n" + $_.Exception.Message)
        return
    }
    $s = [Recovery.Scanner]::new($script:src, $out)
    $s.Jpg = $chkJpg.Checked; $s.Png = $chkPng.Checked; $s.Gif = $chkGif.Checked; $s.Heic = $chkHeic.Checked
    $s.Pdf = $chkPdf.Checked; $s.Office = $chkOffice.Checked; $s.Video = $chkVideo.Checked
    $s.MinSize = [long]$numMin.Value * 1024
    $s.Step = $script:src.Alignment
    $note = ''
    if ($chkFree.Checked) {
        if ($drive.Format -eq 'NTFS') {
            $clusters = [long]0
            $bm = $script:src.GetVolumeBitmap([ref]$clusters)
            if ($bm) {
                $s.Bitmap = $bm
                $s.BitmapClusters = $clusters
                $s.ClusterSize = $script:src.ClusterSize
            } else { $note = ' (לא ניתן לקרוא את מפת השטח הפנוי – סורק את כל הכונן)' }
        } else { $note = " (הכונן בפורמט $($drive.Format) – סורק את כל הכונן)" }
    }
    $lstLog.Items.Clear()
    [void]$lstLog.Items.Add("סורק את $($drive.Letter): ...$note")
    $script:scan = $s
    $btnStart.Enabled = $false
    $btnStop.Enabled = $true
    $cmbDrive.Enabled = $false
    $s.Start()
    $timer.Start()
}

$timer.Add_Tick({
    $s = $script:scan
    if (-not $s) { $timer.Stop(); return }
    foreach ($line in $s.TakeLines()) { [void]$lstLog.Items.Add($line) }
    while ($lstLog.Items.Count -gt 2000) { $lstLog.Items.RemoveAt(1) }
    if ($lstLog.Items.Count -gt 0) { $lstLog.TopIndex = $lstLog.Items.Count - 1 }

    $pct = if ($s.Total -gt 0) { [Math]::Min(1000, [int](1000.0 * $s.Position / $s.Total)) } else { 0 }
    $progress.Value = $pct
    $elapsed = (Get-Date) - $s.StartedAt
    $eta = ''
    if ($pct -gt 5 -and $s.Running) {
        $left = [TimeSpan]::FromSeconds($elapsed.TotalSeconds * (1000 - $pct) / $pct)
        $eta = if ($left.TotalMinutes -ge 60) { ' · נותרו כ-{0:0.0} שעות' -f $left.TotalHours } else { ' · נותרו כ-{0:0} דקות' -f [Math]::Ceiling($left.TotalMinutes) }
    }
    $lblScan.Text = "{0:0.0}% · נמצאו {1} קבצים ({2}){3}`n{4}" -f ($pct / 10.0), $s.Found, (Format-Size $s.BytesRecovered), $eta, $s.Summary()

    if (-not $s.Running) {
        $timer.Stop()
        try { $script:src.Dispose() } catch { }
        $btnStart.Enabled = $true
        $btnStop.Enabled = $false
        $cmbDrive.Enabled = $true
        if ($s.Error) {
            Show-Error ("הסריקה נעצרה בגלל שגיאה:`n" + $s.Error)
        } elseif ($s.Cancel) {
            $lblScan.Text = "הסריקה נעצרה. נמצאו $($s.Found) קבצים.`n" + $s.Summary()
        } else {
            $progress.Value = 1000
            $lblScan.Text = "הסריקה הסתיימה! נמצאו $($s.Found) קבצים.`n" + $s.Summary()
            if ($s.Found -gt 0) {
                if (Ask "הסריקה הסתיימה ונמצאו $($s.Found) קבצים.`nלפתוח את התיקייה?") { Start-Process explorer.exe $txtOut.Text }
            } else {
                Show-Info 'הסריקה הסתיימה ולא נמצאו קבצים מהסוגים שנבחרו. נסה את הלשונית "שחזור עם שמות".'
            }
        }
        $script:scan = $null
    }
})

# ===== לשונית 3: שחזור עם שמות (Windows File Recovery של מיקרוסופט) =====
$pWinfr = New-Page 'שחזור עם שמות'
Add-Row $pWinfr (New-Label 'הכלי החינמי של מיקרוסופט "Windows File Recovery" משחזר קבצים שנמחקו בכונני NTFS עם השם והתיקייה המקוריים, וגם סוגי קבצים שהסריקה העמוקה לא מכירה. הלשונית הזו מפעילה אותו בשבילך.')

$winfr = Get-Command winfr.exe -ErrorAction SilentlyContinue
$lblWinfr = New-Label ''
Add-Row $pWinfr $lblWinfr
if (-not $winfr) {
    $lblWinfr.Text = 'הכלי עדיין לא מותקן במחשב. לחץ כדי להתקין אותו מ-Microsoft Store (חינם), ואז סגור ופתח את התוכנה מחדש.'
    Add-Row $pWinfr (New-Flow (New-Button 'התקן מ-Microsoft Store' { Start-Process 'ms-windows-store://pdp/?productid=9N26S50LN705' }))
} else {
    $lblWinfr.Text = '✔ הכלי מותקן.'
    $cmbWSrc = New-Object Windows.Forms.ComboBox
    $cmbWSrc.DropDownStyle = 'DropDownList'
    $cmbWSrc.Width = 340
    foreach ($d in $script:driveChoices) { [void]$cmbWSrc.Items.Add($d.Text) }
    if ($cmbWSrc.Items.Count -gt 0) { $cmbWSrc.SelectedIndex = 0 }
    Add-Row $pWinfr (New-Flow (New-Label 'הכונן שממנו נמחקו הקבצים:') $cmbWSrc)

    $txtWDest = New-Object Windows.Forms.TextBox
    $txtWDest.Width = 420
    if ($script:driveChoices.Count -gt 0) { $txtWDest.Text = Get-DefaultOutput $script:driveChoices[0].Letter }
    $cmbWSrc.Add_SelectedIndexChanged({ $txtWDest.Text = Get-DefaultOutput $script:driveChoices[$cmbWSrc.SelectedIndex].Letter })
    Add-Row $pWinfr (New-Flow (New-Label 'שמור ב (חייב להיות כונן אחר):') $txtWDest (New-Button 'בחר...' {
        $f = Select-Folder 'בחר תיקייה בכונן אחר'
        if ($f) { $txtWDest.Text = $f }
    }))

    $rbRegular = New-Object Windows.Forms.RadioButton
    $rbRegular.Text = 'מהיר – קבצים שנמחקו לאחרונה'
    $rbRegular.AutoSize = $true
    $rbRegular.Checked = $true
    $rbExt = New-Object Windows.Forms.RadioButton
    $rbExt.Text = 'יסודי – נמחקו מזמן / אחרי פרמוט'
    $rbExt.AutoSize = $true
    Add-Row $pWinfr (New-Flow (New-Label 'סוג סריקה:') $rbRegular $rbExt)

    $txtWFilter = New-Object Windows.Forms.TextBox
    $txtWFilter.Width = 300
    $txtWFilter.RightToLeft = 'No'
    Add-Row $pWinfr (New-Flow (New-Label 'מה לחפש (לא חובה):') $txtWFilter)
    Add-Row $pWinfr (New-Label 'דוגמאות: *.docx   או   *.jpg   או   \Users\שם\Documents\   או שם קובץ מלא. אפשר כמה, מופרדים ב-; . ריק = הכל.' -Color 'DimGray')

    Add-Row $pWinfr (New-Flow (New-Button '▶ התחל שחזור' {
        $d = $script:driveChoices[$cmbWSrc.SelectedIndex]
        $dest = $txtWDest.Text.Trim()
        if (-not $dest -or -not [IO.Path]::IsPathRooted($dest)) { Show-Error 'בחר תיקיית יעד.'; return }
        if ($dest.Substring(0, 1) -eq $d.Letter) { Show-Error 'התיקייה חייבת להיות בכונן אחר מהכונן שממנו משחזרים.'; return }
        [void][IO.Directory]::CreateDirectory($dest)
        $mode = if ($rbExt.Checked) { '/extensive' } else { '/regular' }
        $argList = "$($d.Letter): `"$($dest.TrimEnd('\'))`" $mode"
        foreach ($f in $txtWFilter.Text.Split(';')) {
            if ($f.Trim()) { $argList += " /n `"$($f.Trim())`"" }
        }
        Show-Info 'ייפתח חלון שחור של הכלי. הקלד Y ולחץ Enter כדי להתחיל. בסוף הוא ישאל אם לפתוח את הקבצים.'
        Start-Process -FilePath $winfr.Source -ArgumentList $argList
    }))
}
[void]$tabs.TabPages.Add($pWinfr)

# ===== לשונית 4: טיפים =====
$pTips = New-Page 'טיפים'
$tips = New-Object Windows.Forms.TextBox
$tips.Multiline = $true
$tips.ReadOnly = $true
$tips.ScrollBars = 'Vertical'
$tips.BackColor = [Drawing.SystemColors]::Window
$tips.Text = @'
מה לעשות קודם, לפי הסדר:

1. הפסק להשתמש בכונן שממנו נמחקו הקבצים. כל קובץ חדש שנשמר (הורדות, התקנות, אפילו גלישה) עלול לדרוס את הקבצים שנמחקו.

2. סל המיחזור – הלשונית הראשונה. רוב הקבצים שנמחקו בטעות נמצאים שם וחוזרים במלואם.

3. גרסאות קודמות – בסייר הקבצים, לחיצה ימנית על התיקייה שבה היה הקובץ ← מאפיינים ← "גרסאות קודמות". עובד רק אם "היסטוריית קבצים" או נקודות שחזור הופעלו.

4. ענן – אם הקובץ היה מסונכרן:
   • OneDrive: סל המיחזור באתר onedrive.live.com (שומר 30 יום).
   • Google Drive: "אשפה" באתר drive.google.com (שומר 30 יום).
   • Dropbox: "קבצים שנמחקו" באתר.

5. שחזור עם שמות – הלשונית השלישית (הכלי של מיקרוסופט). מחזיר שמות ותיקיות, מתאים לכונני NTFS.

6. סריקה עמוקה – הלשונית השנייה. מוצאת תמונות, מסמכים וסרטונים גם כשכל השאר נכשל, אבל בלי השמות המקוריים.

חשוב לדעת:
• שמור קבצים משוחזרים תמיד על כונן אחר (דיסק-און-קי / דיסק חיצוני).
• בכונני SSD, Windows מוחק פיזית את השטח הפנוי (TRIM) זמן קצר אחרי המחיקה, ולכן שם הסיכוי קטן יותר – כדאי לפעול מהר.
• קבצים גדולים שהיו מפוצלים על הדיסק עלולים לחזור פגומים – בדוק כל קובץ משוחזר.
• אם התוכנה לא מצאה – אפשר לנסות את התוכנה החינמית PhotoRec, שמכירה מאות סוגי קבצים.
'@
Add-Row $pTips $tips -Fill
[void]$tabs.TabPages.Add($pTips)

# ---------- הפעלה ----------
if (-not $isAdmin) {
    $form.Text += '  (ללא הרשאות מנהל – סריקה עמוקה לא זמינה)'
}
$form.Add_Shown({ Load-Bin; $form.Activate() })
$form.Add_FormClosing({ if ($script:scan) { $script:scan.Cancel = $true } })
[void]$form.ShowDialog()
