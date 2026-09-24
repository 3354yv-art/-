# ממיר ומשחזר – שחזור, המרה והעברת קבצים ב-Windows
# הפעלה: לחיצה כפולה על "Start.bat" (או: powershell -ExecutionPolicy Bypass -STA -File ConverterRecovery.ps1)

$ErrorActionPreference = 'Stop'
$AppName = 'ממיר ומשחזר'
$AppVersion = '3.0'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms

$RtlOptions = [System.Windows.MessageBoxOptions]::RtlReading -bor [System.Windows.MessageBoxOptions]::RightAlign
$script:win = $null
function Show-Msg([string]$text, [string]$icon, [string]$buttons = 'OK') {
    if ($script:win) { return [System.Windows.MessageBox]::Show($script:win, $text, $AppName, $buttons, $icon, 'None', $RtlOptions) }
    return [System.Windows.MessageBox]::Show($text, $AppName, $buttons, $icon, 'None', $RtlOptions)
}
function Show-Error([string]$text) { [void](Show-Msg $text 'Error') }
function Show-Info([string]$text) { [void](Show-Msg $text 'Information') }
function Ask([string]$text, [string]$icon = 'Question') { (Show-Msg $text $icon 'YesNo') -eq 'Yes' }

# ---------- הרשאות מנהל (נדרשות לסריקת עומק, גרסאות קודמות, גיבוי ותיקון כוננים) ----------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and $env:CONVERTER_NO_ELEVATE -ne '1') {
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"")
        exit
    } catch {
        # המשתמש סירב – ממשיכים בלי הכלים שדורשים הרשאות מנהל
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

$AppDir = Split-Path -Parent $PSCommandPath
$WorkDir = Join-Path $env:LOCALAPPDATA 'ConverterRecovery'
[void][IO.Directory]::CreateDirectory($WorkDir)

# ---------- המנוע (C#) – מקומפל פעם אחת ונשמר במטמון ----------
$engineSource = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;
using System.Diagnostics;
using System.Globalization;
using System.Text.RegularExpressions;
using System.Windows.Media;
using System.Windows.Media.Imaging;

// מנוע שחזור קבצים: סורק כונן ברמת הבתים ומזהה קבצים לפי החתימה והמבנה שלהם.
// נכתב ב-C# 5 כדי ש-PowerShell 5.1 (שמגיע עם כל Windows) יוכל לקמפל אותו.

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

// כלים שרצים ברקע: העתקה (רגילה ומכונן פגום), גיבוי כונן לקובץ, חיפוש קבצים, המרת תמונות, יצירת PDF והרצת תוכנות חיצוניות.
// נכתב ב-C# 5 כדי ש-PowerShell 5.1 (שמגיע עם כל Windows) יוכל לקמפל אותו.

namespace Recovery
{
    // בסיס לכל פעולה ארוכה: רצה בחוט נפרד, והממשק שואל אותה מדי פעם מה המצב
    public abstract class Job
    {
        public volatile bool Cancel;
        public volatile bool Running;
        public volatile string Error;
        public volatile string Status = "";
        public long Position;
        public long Total;             // 0 = התקדמות לא ידועה
        public DateTime StartedAt;
        public int Warnings;

        private readonly List<string> lines = new List<string>();
        private Thread thread;

        protected virtual bool NeedsSta { get { return false; } }

        public int Permille
        {
            get
            {
                long t = Interlocked.Read(ref Total);
                if (t <= 0) return -1;
                long p = Interlocked.Read(ref Position);
                return (int)Math.Max(0, Math.Min(1000, 1000.0 * p / t));
            }
        }

        public void Start()
        {
            Running = true;
            StartedAt = DateTime.Now;
            thread = new Thread(Wrap);
            thread.IsBackground = true;
            if (NeedsSta) thread.SetApartmentState(ApartmentState.STA);
            thread.Start();
        }

        public void RunSync()
        {
            Running = true;
            StartedAt = DateTime.Now;
            Wrap();
        }

        public virtual void Stop() { Cancel = true; }

        private void Wrap()
        {
            try { Run(); }
            catch (Exception ex) { Error = ex.Message; Log("שגיאה: " + ex.Message); }
            finally { Running = false; }
        }

        protected abstract void Run();

        public void Log(string s) { lock (lines) lines.Add(s); }

        public string[] TakeLines()
        {
            lock (lines)
            {
                string[] a = lines.ToArray();
                lines.Clear();
                return a;
            }
        }

        public static string Size(long b) { return Scanner.FormatSize(b); }

        // אם קיים קובץ בשם הזה – מוסיף (2), (3)...
        public static string FreeName(string path)
        {
            if (!File.Exists(path) && !Directory.Exists(path)) return path;
            string dir = Path.GetDirectoryName(path);
            string b = Path.GetFileNameWithoutExtension(path);
            string ext = Path.GetExtension(path);
            for (int k = 2; ; k++)
            {
                string p = Path.Combine(dir, b + " (" + k + ")" + ext);
                if (!File.Exists(p) && !Directory.Exists(p)) return p;
            }
        }

        // מעבר על כל הקבצים בתיקייה, בלי להיתקע על תיקיות חסומות ובלי קיצורי דרך שיוצרים לולאות
        public static IEnumerable<string> SafeFiles(string root, Job owner)
        {
            Stack<string> dirs = new Stack<string>();
            dirs.Push(root);
            while (dirs.Count > 0)
            {
                if (owner != null && owner.Cancel) yield break;
                string d = dirs.Pop();
                string[] files = null, subs = null;
                try { files = Directory.GetFiles(d); } catch { }
                try { subs = Directory.GetDirectories(d); } catch { }
                if (files != null) foreach (string f in files) yield return f;
                if (subs == null) continue;
                for (int i = subs.Length - 1; i >= 0; i--)
                {
                    try
                    {
                        if ((File.GetAttributes(subs[i]) & FileAttributes.ReparsePoint) != 0) continue;
                    }
                    catch { continue; }
                    dirs.Push(subs[i]);
                }
            }
        }
    }

    public static class NativeLinks
    {
        [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
        private static extern bool CreateSymbolicLink(string link, string target, int flags);

        // קיצור לתיקייה (למשל לצילום של הכונן), כדי שסייר הקבצים יוכל לפתוח אותו
        public static bool MakeDirLink(string link, string target) { return CreateSymbolicLink(link, target, 1); }
    }

    // ---------- העתקת קבצים ותיקיות ----------
    // מצב רגיל: להעברה בין מחשבים (מדלג על קבצים זהים, ממשיך מאיפה שנעצר).
    // מצב הצלה: לכונן פגום – מנסה שוב, ואם קטע לא נקרא הוא ממולא באפסים והקובץ מסומן.
    public class CopyJob : Job
    {
        private class Pair { public string Src, Dst; public long Len; }
        private readonly List<string[]> roots = new List<string[]>();

        public bool Salvage;
        public int Retries = 2;
        public bool SkipIdentical = true;
        public bool Overwrite;         // false = שם חדש כשיש קובץ שונה באותו שם
        public string ReportPath;
        public string[] ExcludeNames = new string[] { "desktop.ini", "thumbs.db", "~$*" };

        public int Copied, Skipped, Failed, Damaged;
        public long BytesCopied;
        private readonly List<string> problems = new List<string>();

        // src יכול להיות קובץ או תיקייה; dst היא התיקייה שאליה יועתק התוכן
        public void Add(string src, string dst) { roots.Add(new string[] { src, dst }); }

        // שם שמסתיים ב-* הוא תחילית של שם קובץ; שם רגיל יכול להיות גם שם של תיקייה בדרך
        private bool Excluded(string path)
        {
            string name = Path.GetFileName(path);
            foreach (string p in ExcludeNames)
            {
                if (p.EndsWith("*"))
                {
                    if (name.StartsWith(p.TrimEnd('*'), StringComparison.OrdinalIgnoreCase)) return true;
                }
                else if (string.Equals(name, p, StringComparison.OrdinalIgnoreCase) ||
                         path.IndexOf("\\" + p + "\\", StringComparison.OrdinalIgnoreCase) >= 0) return true;
            }
            return false;
        }

        protected override void Run()
        {
            Status = "סופר קבצים...";
            List<Pair> list = new List<Pair>();
            long total = 0;
            foreach (string[] r in roots)
            {
                if (File.Exists(r[0]))
                {
                    Pair p = new Pair();
                    p.Src = r[0];
                    p.Dst = Path.Combine(r[1], Path.GetFileName(r[0]));
                    try { p.Len = new FileInfo(r[0]).Length; } catch { }
                    list.Add(p); total += p.Len;
                    continue;
                }
                if (!Directory.Exists(r[0])) { Log("לא נמצא: " + r[0]); continue; }
                string baseDir = r[0].TrimEnd('\\') + "\\";
                foreach (string f in SafeFiles(r[0], this))
                {
                    if (Excluded(f)) continue;
                    Pair p = new Pair();
                    p.Src = f;
                    p.Dst = Path.Combine(r[1], f.Substring(baseDir.Length));
                    try { p.Len = new FileInfo(f).Length; } catch { }
                    list.Add(p); total += p.Len;
                    if (list.Count % 500 == 0) Status = "סופר קבצים... " + list.Count;
                }
            }
            if (Cancel) return;
            Total = Math.Max(1, total);
            Log("נמצאו " + list.Count + " קבצים, " + Size(total));

            byte[] buf = new byte[1024 * 1024];
            int index = 0;
            foreach (Pair p in list)
            {
                if (Cancel) break;
                index++;
                Status = index + " מתוך " + list.Count + " · " + Path.GetFileName(p.Src);
                try { CopyOne(p, buf); }
                catch (Exception ex)
                {
                    Failed++;
                    problems.Add("לא הועתק: " + p.Src + " – " + ex.Message);
                    Log("✗ " + p.Src + " – " + ex.Message);
                }
            }
            Position = Total;
            string sum = "הועתקו " + Copied + " קבצים (" + Size(BytesCopied) + ")";
            if (Skipped > 0) sum += ", דולגו " + Skipped + " שכבר קיימים";
            if (Damaged > 0) sum += ", " + Damaged + " שוחזרו חלקית";
            if (Failed > 0) sum += ", " + Failed + " נכשלו";
            Status = sum;
            Log(sum);
            if (ReportPath != null && (problems.Count > 0 || Salvage))
            {
                try
                {
                    List<string> rep = new List<string>();
                    rep.Add(sum);
                    rep.Add("");
                    rep.AddRange(problems);
                    Directory.CreateDirectory(Path.GetDirectoryName(ReportPath));
                    File.WriteAllLines(ReportPath, rep.ToArray(), Encoding.UTF8);
                    Log("דוח נשמר: " + ReportPath);
                }
                catch { }
            }
        }

        private void CopyOne(Pair p, byte[] buf)
        {
            long before = Interlocked.Read(ref Position);
            FileInfo si = new FileInfo(p.Src);
            string dst = p.Dst;
            if (File.Exists(dst))
            {
                FileInfo di = new FileInfo(dst);
                if (SkipIdentical && di.Length == si.Length && Math.Abs((di.LastWriteTimeUtc - si.LastWriteTimeUtc).TotalSeconds) < 3)
                {
                    Skipped++;
                    Interlocked.Add(ref Position, p.Len);
                    return;
                }
                if (!Overwrite) dst = FreeName(dst);
            }
            Directory.CreateDirectory(Path.GetDirectoryName(dst));
            string tmp = dst + ".partial";
            int badBlocks = 0;
            using (FileStream src = new FileStream(p.Src, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 4096))
            using (FileStream o = new FileStream(tmp, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16))
            {
                long len = src.Length, pos = 0;
                while (pos < len)
                {
                    if (Cancel) break;
                    int want = (int)Math.Min(buf.Length, len - pos);
                    int n = ReadAt(src, pos, buf, want);
                    if (n < 0)
                    {
                        if (!Salvage) throw new IOException("שגיאת קריאה – ייתכן שהכונן פגום. נסה את \"העתקה מכונן פגום\".");
                        // קריאה בקטעים קטנים, כדי להציל כמה שיותר
                        const int small = 4096;
                        for (int off = 0; off < want; off += small)
                        {
                            int w = Math.Min(small, want - off);
                            byte[] sb = new byte[w];
                            int m = -1;
                            for (int t = 0; t <= Retries && m < 0; t++) m = ReadAt(src, pos + off, sb, w);
                            if (m < 0) { Array.Clear(sb, 0, w); badBlocks++; }
                            Buffer.BlockCopy(sb, 0, buf, off, w);
                        }
                        n = want;
                    }
                    if (n == 0) break;
                    o.Write(buf, 0, n);
                    pos += n;
                    BytesCopied += n;
                    Interlocked.Add(ref Position, n);
                }
            }
            if (Cancel)
            {
                try { File.Delete(tmp); } catch { }
                Interlocked.Exchange(ref Position, before);
                return;
            }
            if (File.Exists(dst)) File.Delete(dst);
            File.Move(tmp, dst);
            try
            {
                File.SetCreationTimeUtc(dst, si.CreationTimeUtc);
                File.SetLastWriteTimeUtc(dst, si.LastWriteTimeUtc);
            }
            catch { }
            Copied++;
            if (badBlocks > 0)
            {
                Damaged++;
                string msg = "שוחזר חלקית (" + badBlocks + " קטעים של 4KB לא נקראו ומולאו באפסים): " + p.Src;
                problems.Add(msg);
                Log("⚠ " + msg);
            }
        }

        // מחזיר -1 אם הייתה שגיאת קריאה
        private static int ReadAt(FileStream s, long pos, byte[] b, int count)
        {
            try
            {
                s.Seek(pos, SeekOrigin.Begin);
                int total = 0;
                while (total < count)
                {
                    int n = s.Read(b, total, count - total);
                    if (n <= 0) break;
                    total += n;
                }
                return total;
            }
            catch (IOException) { return -1; }
        }
    }

    // ---------- גיבוי כונן שלם לקובץ תמונה (כמו ddrescue) ----------
    public class DiskImageJob : Job
    {
        private readonly char letter;
        private readonly string outPath;
        public long BadSectors;

        public DiskImageJob(char driveLetter, string imagePath) { letter = driveLetter; outPath = imagePath; }

        protected override void Run()
        {
            using (VolumeSource src = new VolumeSource(letter))
            {
                Total = src.Length;
                Log("גודל הכונן: " + Size(src.Length) + ". כותב אל " + outPath);
                Directory.CreateDirectory(Path.GetDirectoryName(outPath));
                int chunk = 4 * 1024 * 1024;
                chunk -= chunk % src.Alignment;
                byte[] buf = new byte[chunk];
                using (FileStream o = new FileStream(outPath, FileMode.Create, FileAccess.Write, FileShare.Read, 1 << 20))
                {
                    long pos = 0;
                    while (pos < src.Length && !Cancel)
                    {
                        int want = (int)Math.Min(chunk, src.Length - pos);
                        long errBefore = src.ReadErrors;
                        int n = src.ReadAligned(pos, buf, want);
                        if (n <= 0) break;
                        if (src.ReadErrors > errBefore)
                        {
                            BadSectors = src.ReadErrors;
                            Log("⚠ סקטורים פגומים באזור " + Size(pos) + " (סה\"כ " + BadSectors + ")");
                        }
                        o.Write(buf, 0, n);
                        pos += n;
                        Position = pos;
                        double sec = (DateTime.Now - StartedAt).TotalSeconds;
                        string speed = sec > 1 ? " · " + Size((long)(pos / sec)) + "/שנייה" : "";
                        Status = Size(pos) + " מתוך " + Size(src.Length) + speed + (BadSectors > 0 ? " · סקטורים פגומים: " + BadSectors : "");
                    }
                }
                if (Cancel) { Status = "הגיבוי נעצר – הקובץ חלקי."; Log(Status); return; }
                Status = "הגיבוי הסתיים: " + Size(src.Length) + (BadSectors > 0 ? ", " + BadSectors + " סקטורים לא נקראו (מולאו באפסים)" : ", בלי שגיאות קריאה");
                Log(Status);
                try
                {
                    File.WriteAllText(outPath + ".txt",
                        "גיבוי של הכונן " + letter + ":\r\nתאריך: " + DateTime.Now.ToString("dd/MM/yyyy HH:mm") +
                        "\r\nגודל: " + Size(src.Length) + "\r\nסקטורים שלא נקראו: " + BadSectors +
                        "\r\n\r\nאפשר לסרוק את הקובץ הזה ב\"סריקת עומק\" (מקור: קובץ תמונת כונן) כדי לחלץ ממנו קבצים.\r\n", Encoding.UTF8);
                }
                catch { }
            }
        }
    }

    // ---------- חיפוש קבצים שנעלמו ----------
    public class FoundFile
    {
        public string Name { get; set; }
        public string Folder { get; set; }
        public string FullPath { get; set; }
        public long Length { get; set; }
        public DateTime Modified { get; set; }
        public string SizeText { get { return Job.Size(Length); } }
        public string DateText { get { return Modified.ToString("dd/MM/yyyy HH:mm"); } }
    }

    public class FileSearchJob : Job
    {
        public List<string> Roots = new List<string>();
        public string Query = "";          // חלק מהשם, או תבנית עם * ו-?; כמה אפשרויות מופרדות ב-;
        public string[] Extensions;        // null = הכל
        public DateTime After = DateTime.MinValue;
        public int MaxResults = 5000;
        public int Scanned;

        private readonly List<FoundFile> fresh = new List<FoundFile>();
        private int found;

        public FoundFile[] TakeResults()
        {
            lock (fresh)
            {
                FoundFile[] a = fresh.ToArray();
                fresh.Clear();
                return a;
            }
        }

        private static readonly string[] SkipDirs = new string[] { "$Recycle.Bin", "System Volume Information", "WinSxS", "$WinREAgent", "Windows\\Installer" };

        protected override void Run()
        {
            List<Regex> pats = new List<Regex>();
            foreach (string q in (Query ?? "").Split(';'))
            {
                string t = q.Trim();
                if (t.Length == 0) continue;
                string rx = t.IndexOfAny(new char[] { '*', '?' }) >= 0
                    ? "^" + Regex.Escape(t).Replace("\\*", ".*").Replace("\\?", ".") + "$"
                    : Regex.Escape(t);
                pats.Add(new Regex(rx, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant));
            }
            Dictionary<string, bool> exts = null;
            if (Extensions != null && Extensions.Length > 0)
            {
                exts = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
                foreach (string e in Extensions) exts[e.StartsWith(".") ? e : "." + e] = true;
            }
            foreach (string root in Roots)
            {
                if (Cancel) break;
                Log("מחפש ב-" + root);
                Stack<string> dirs = new Stack<string>();
                dirs.Push(root);
                while (dirs.Count > 0 && !Cancel)
                {
                    string d = dirs.Pop();
                    Status = "נבדקו " + Scanned + " קבצים · נמצאו " + found + " · " + d;
                    DirectoryInfo di = new DirectoryInfo(d);
                    FileSystemInfo[] items;
                    try { items = di.GetFileSystemInfos(); } catch { continue; }
                    foreach (FileSystemInfo fi in items)
                    {
                        if ((fi.Attributes & FileAttributes.Directory) != 0)
                        {
                            if ((fi.Attributes & FileAttributes.ReparsePoint) != 0) continue;
                            bool skip = false;
                            foreach (string s in SkipDirs) if (fi.FullName.EndsWith("\\" + s, StringComparison.OrdinalIgnoreCase)) skip = true;
                            if (!skip) dirs.Push(fi.FullName);
                            continue;
                        }
                        Scanned++;
                        if (exts != null && !exts.ContainsKey(fi.Extension)) continue;
                        DateTime m;
                        try { m = fi.LastWriteTime; } catch { continue; }
                        if (m < After) continue;
                        if (pats.Count > 0)
                        {
                            bool ok = false;
                            foreach (Regex r in pats) if (r.IsMatch(fi.Name)) { ok = true; break; }
                            if (!ok) continue;
                        }
                        FoundFile f = new FoundFile();
                        f.Name = fi.Name;
                        f.Folder = Path.GetDirectoryName(fi.FullName);
                        f.FullPath = fi.FullName;
                        f.Modified = m;
                        try { f.Length = ((FileInfo)fi).Length; } catch { }
                        lock (fresh) fresh.Add(f);
                        found++;
                        if (found >= MaxResults)
                        {
                            Log("הגעת למקסימום " + MaxResults + " תוצאות – צמצם את החיפוש.");
                            Status = "נמצאו " + found + " קבצים (הוצגו הראשונים)";
                            return;
                        }
                    }
                }
            }
            Status = (Cancel ? "החיפוש נעצר. " : "החיפוש הסתיים. ") + "נבדקו " + Scanned + " קבצים, נמצאו " + found + ".";
            Log(Status);
        }
    }

    // ---------- המרת תמונות (כולל HEIC מאייפון) ויצירת PDF מתמונות ----------
    // משתמש ב-WIC של Windows, ולכן קורא כל פורמט שמותקן לו רכיב (HEIC דורש את "HEIF Image Extensions" מה-Store)
    public class ImageConvertJob : Job
    {
        public List<string> Files = new List<string>();
        public string Format = "jpg";      // jpg png bmp gif tiff ico pdf
        public string OutputFolder;        // null = ליד הקובץ המקורי
        public int Quality = 90;
        public int MaxSide;                // 0 = בלי שינוי גודל
        public bool SinglePdf = true;
        public string PdfName = "תמונות";
        public int Done, Failed;
        public List<string> Outputs = new List<string>();

        protected override bool NeedsSta { get { return true; } }

        protected override void Run()
        {
            Total = Files.Count;
            PdfWriter pdf = null;
            string pdfPath = null;
            if (Format == "pdf" && SinglePdf && Files.Count > 0)
            {
                string dir = OutputFolder ?? Path.GetDirectoryName(Files[0]);
                Directory.CreateDirectory(dir);
                pdfPath = FreeName(Path.Combine(dir, PdfName + ".pdf"));
                pdf = new PdfWriter();
            }
            for (int i = 0; i < Files.Count && !Cancel; i++)
            {
                string f = Files[i];
                Status = (i + 1) + " מתוך " + Files.Count + " · " + Path.GetFileName(f);
                try
                {
                    BitmapSource img = Load(f);
                    if (MaxSide > 0) img = Shrink(img, MaxSide);
                    if (Format == "pdf")
                    {
                        byte[] jpg = Encode(Flatten(img), "jpg");
                        if (pdf != null) pdf.AddJpeg(jpg, img.PixelWidth, img.PixelHeight);
                        else
                        {
                            PdfWriter one = new PdfWriter();
                            one.AddJpeg(jpg, img.PixelWidth, img.PixelHeight);
                            string o = Target(f, "pdf");
                            one.Save(o);
                            Outputs.Add(o);
                        }
                    }
                    else
                    {
                        string o = Target(f, Format);
                        File.WriteAllBytes(o, Encode(img, Format));
                        Outputs.Add(o);
                        Log("✓ " + Path.GetFileName(o));
                    }
                    Done++;
                }
                catch (Exception ex)
                {
                    Failed++;
                    string m = ex.Message;
                    if (f.EndsWith(".heic", StringComparison.OrdinalIgnoreCase) || f.EndsWith(".heif", StringComparison.OrdinalIgnoreCase))
                        m += " (לקבצי HEIC צריך להתקין מה-Microsoft Store את \"HEIF Image Extensions\")";
                    else if (f.EndsWith(".webp", StringComparison.OrdinalIgnoreCase))
                        m += " (לקבצי WEBP צריך להתקין מה-Microsoft Store את \"Webp Image Extensions\")";
                    Log("✗ " + Path.GetFileName(f) + " – " + m);
                }
                Position = i + 1;
            }
            if (pdf != null && pdf.Pages > 0 && !Cancel)
            {
                pdf.Save(pdfPath);
                Outputs.Add(pdfPath);
                Log("✓ נוצר " + pdfPath + " (" + pdf.Pages + " עמודים)");
            }
            Status = "הומרו " + Done + " קבצים" + (Failed > 0 ? ", " + Failed + " נכשלו" : "");
            Log(Status);
        }

        private string Target(string src, string ext)
        {
            string dir = OutputFolder ?? Path.GetDirectoryName(src);
            Directory.CreateDirectory(dir);
            return FreeName(Path.Combine(dir, Path.GetFileNameWithoutExtension(src) + "." + ext));
        }

        public static BitmapSource Load(string path)
        {
            BitmapDecoder dec;
            using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            {
                dec = BitmapDecoder.Create(fs, BitmapCreateOptions.PreservePixelFormat | BitmapCreateOptions.IgnoreColorProfile, BitmapCacheOption.OnLoad);
            }
            BitmapFrame fr = dec.Frames[0];
            BitmapSource img = fr;
            int rot = 0;
            try
            {
                BitmapMetadata md = fr.Metadata as BitmapMetadata;
                if (md != null)
                {
                    object o = md.GetQuery("System.Photo.Orientation");
                    if (o != null)
                    {
                        int v = Convert.ToInt32(o, CultureInfo.InvariantCulture);
                        if (v == 3) rot = 180; else if (v == 6) rot = 90; else if (v == 8) rot = 270;
                    }
                }
            }
            catch { }
            if (rot != 0) img = new TransformedBitmap(img, new RotateTransform(rot));
            img.Freeze();
            return img;
        }

        private static BitmapSource Shrink(BitmapSource img, int max)
        {
            int side = Math.Max(img.PixelWidth, img.PixelHeight);
            if (side <= max) return img;
            double s = (double)max / side;
            BitmapSource r = new TransformedBitmap(img, new ScaleTransform(s, s));
            r.Freeze();
            return r;
        }

        // מניח את התמונה על רקע לבן (לפורמטים בלי שקיפות)
        private static BitmapSource Flatten(BitmapSource img)
        {
            FormatConvertedBitmap c = new FormatConvertedBitmap(img, PixelFormats.Bgra32, null, 0);
            int w = c.PixelWidth, h = c.PixelHeight;
            byte[] px = new byte[w * h * 4];
            c.CopyPixels(px, w * 4, 0);
            int stride = (w * 3 + 3) & ~3;
            byte[] o = new byte[stride * h];
            for (int y = 0; y < h; y++)
            {
                int si = y * w * 4, di = y * stride;
                for (int x = 0; x < w; x++, si += 4, di += 3)
                {
                    int a = px[si + 3];
                    o[di] = (byte)((px[si] * a + 255 * (255 - a)) / 255);
                    o[di + 1] = (byte)((px[si + 1] * a + 255 * (255 - a)) / 255);
                    o[di + 2] = (byte)((px[si + 2] * a + 255 * (255 - a)) / 255);
                }
            }
            BitmapSource r = BitmapSource.Create(w, h, 96, 96, PixelFormats.Bgr24, null, o, stride);
            r.Freeze();
            return r;
        }

        private byte[] Encode(BitmapSource img, string fmt)
        {
            if (fmt == "ico")
            {
                BitmapSource small = Shrink(img, 256);
                byte[] png = Encode(small, "png");
                MemoryStream ms0 = new MemoryStream();
                BinaryWriter bw = new BinaryWriter(ms0);
                bw.Write((short)0); bw.Write((short)1); bw.Write((short)1);
                bw.Write((byte)(small.PixelWidth >= 256 ? 0 : small.PixelWidth));
                bw.Write((byte)(small.PixelHeight >= 256 ? 0 : small.PixelHeight));
                bw.Write((byte)0); bw.Write((byte)0);
                bw.Write((short)1); bw.Write((short)32);
                bw.Write(png.Length); bw.Write(22);
                bw.Write(png);
                bw.Flush();
                return ms0.ToArray();
            }
            BitmapEncoder enc;
            switch (fmt)
            {
                case "png": enc = new PngBitmapEncoder(); break;
                case "bmp": enc = new BmpBitmapEncoder(); img = Flatten(img); break;
                case "gif": enc = new GifBitmapEncoder(); img = Flatten(img); break;
                case "tiff": enc = new TiffBitmapEncoder(); break;
                default:
                    JpegBitmapEncoder j = new JpegBitmapEncoder();
                    j.QualityLevel = Math.Max(10, Math.Min(100, Quality));
                    enc = j;
                    img = Flatten(img);
                    break;
            }
            enc.Frames.Add(BitmapFrame.Create(img));
            MemoryStream ms = new MemoryStream();
            enc.Save(ms);
            return ms.ToArray();
        }
    }

    // כותב PDF פשוט: כל תמונה בעמוד A4 משלה, ממורכזת עם שוליים
    public class PdfWriter
    {
        private readonly List<byte[]> jpgs = new List<byte[]>();
        private readonly List<int[]> dims = new List<int[]>();
        public int Pages { get { return jpgs.Count; } }

        public void AddJpeg(byte[] jpeg, int w, int h)
        {
            jpgs.Add(jpeg);
            dims.Add(new int[] { w, h });
        }

        public void Save(string path)
        {
            using (FileStream fs = new FileStream(path, FileMode.Create))
            {
                List<long> offs = new List<long>();
                Action<string> W = delegate (string s) { byte[] b = Encoding.ASCII.GetBytes(s); fs.Write(b, 0, b.Length); };
                W("%PDF-1.4\n");
                fs.Write(new byte[] { 0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A }, 0, 6);
                int n = jpgs.Count;
                // אובייקטים: 1 קטלוג, 2 עמודים, ואז לכל עמוד: עמוד, תוכן, תמונה
                StringBuilder kids = new StringBuilder();
                for (int i = 0; i < n; i++) kids.Append(3 + i * 3).Append(" 0 R ");
                offs.Add(fs.Position); W("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");
                offs.Add(fs.Position); W("2 0 obj\n<< /Type /Pages /Kids [" + kids + "] /Count " + n + " >>\nendobj\n");
                for (int i = 0; i < n; i++)
                {
                    int w = dims[i][0], h = dims[i][1];
                    bool land = w > h;
                    double pw = land ? 842 : 595, ph = land ? 595 : 842, m = 28;
                    double s = Math.Min((pw - 2 * m) / w, (ph - 2 * m) / h);
                    double dw = w * s, dh = h * s, x = (pw - dw) / 2, y = (ph - dh) / 2;
                    int po = 3 + i * 3;
                    string content = string.Format(CultureInfo.InvariantCulture, "q {0:0.##} 0 0 {1:0.##} {2:0.##} {3:0.##} cm /Im0 Do Q", dw, dh, x, y);
                    offs.Add(fs.Position);
                    W(string.Format(CultureInfo.InvariantCulture,
                        "{0} 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {1} {2}] /Resources << /XObject << /Im0 {3} 0 R >> >> /Contents {4} 0 R >>\nendobj\n",
                        po, pw, ph, po + 2, po + 1));
                    offs.Add(fs.Position);
                    W((po + 1) + " 0 obj\n<< /Length " + content.Length + " >>\nstream\n" + content + "\nendstream\nendobj\n");
                    offs.Add(fs.Position);
                    W((po + 2) + " 0 obj\n<< /Type /XObject /Subtype /Image /Width " + w + " /Height " + h +
                      " /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length " + jpgs[i].Length + " >>\nstream\n");
                    fs.Write(jpgs[i], 0, jpgs[i].Length);
                    W("\nendstream\nendobj\n");
                }
                long xref = fs.Position;
                StringBuilder sb = new StringBuilder();
                sb.Append("xref\n0 ").Append(offs.Count + 1).Append("\n0000000000 65535 f \n");
                foreach (long o in offs) sb.Append(o.ToString("0000000000")).Append(" 00000 n \n");
                sb.Append("trailer\n<< /Size ").Append(offs.Count + 1).Append(" /Root 1 0 R >>\nstartxref\n").Append(xref).Append("\n%%EOF\n");
                W(sb.ToString());
            }
        }
    }

    // ---------- הרצת תוכנות חיצוניות (ffmpeg, chkdsk, winget, netsh, Office) ----------
    public class ProcessStep
    {
        public string File;
        public string Args;
        public string Label;
        public string Input;           // טקסט שנשלח לקלט (למשל Y לאישור)
        public bool Utf8;              // false = קידוד הקונסולה של Windows
        public string WorkDir;
    }

    public class ProcessJob : Job
    {
        public List<ProcessStep> Steps = new List<ProcessStep>();
        public int FailedSteps;
        public int LastExitCode;
        public bool QuietProgress = true;   // לא לרשום ביומן שורות התקדמות חוזרות
        private Process current;
        private double duration;            // משך הקובץ הנוכחי (ffmpeg)

        private static readonly Regex RxDur = new Regex(@"Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)");
        private static readonly Regex RxTime = new Regex(@"time=\s*(\d+):(\d+):(\d+(?:\.\d+)?)");
        private static readonly Regex RxPct = new Regex(@"(\d{1,3}(?:\.\d+)?)\s*(?:%|percent|אחוז)", RegexOptions.IgnoreCase);
        private static readonly Regex RxStep = new Regex(@"^PROGRESS (\d+)/(\d+)");

        public void Add(string file, string args, string label)
        {
            ProcessStep s = new ProcessStep();
            s.File = file; s.Args = args; s.Label = label;
            Steps.Add(s);
        }

        public override void Stop()
        {
            Cancel = true;
            Process p = current;
            if (p == null) return;
            try
            {
                Process k = Process.Start(new ProcessStartInfo("taskkill", "/T /F /PID " + p.Id) { CreateNoWindow = true, UseShellExecute = false });
                if (k != null) k.WaitForExit(5000);
            }
            catch { }
            try { if (!p.HasExited) p.Kill(); } catch { }
        }

        protected override void Run()
        {
            Total = Steps.Count * 1000L;
            Encoding oem;
            try { oem = Encoding.GetEncoding(CultureInfo.CurrentCulture.TextInfo.OEMCodePage); } catch { oem = Encoding.Default; }
            for (int i = 0; i < Steps.Count && !Cancel; i++)
            {
                ProcessStep st = Steps[i];
                Position = i * 1000L;
                duration = 0;
                Status = st.Label ?? Path.GetFileName(st.File);
                Log("▶ " + Status);
                ProcessStartInfo psi = new ProcessStartInfo(st.File, st.Args ?? "");
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.RedirectStandardOutput = true;
                psi.RedirectStandardError = true;
                psi.RedirectStandardInput = true;
                psi.StandardOutputEncoding = st.Utf8 ? Encoding.UTF8 : oem;
                psi.StandardErrorEncoding = st.Utf8 ? Encoding.UTF8 : oem;
                if (st.WorkDir != null) psi.WorkingDirectory = st.WorkDir;
                Process p;
                try { p = Process.Start(psi); }
                catch (Exception ex)
                {
                    FailedSteps++;
                    Log("✗ לא ניתן להפעיל את " + st.File + ": " + ex.Message);
                    continue;
                }
                current = p;
                int stepIndex = i;
                DataReceivedEventHandler h = delegate (object sender, DataReceivedEventArgs e) { OnLine(e.Data, stepIndex); };
                p.OutputDataReceived += h;
                p.ErrorDataReceived += h;
                p.BeginOutputReadLine();
                p.BeginErrorReadLine();
                try
                {
                    if (st.Input != null) p.StandardInput.Write(st.Input);
                    p.StandardInput.Close();
                }
                catch { }
                p.WaitForExit();
                current = null;
                LastExitCode = p.ExitCode;
                if (Cancel) break;
                if (p.ExitCode != 0)
                {
                    FailedSteps++;
                    Log("✗ הסתיים עם קוד " + p.ExitCode + ": " + (st.Label ?? st.File));
                }
                else Log("✓ " + (st.Label ?? "הסתיים"));
            }
            Position = Total;
            Status = Cancel ? "נעצר." : (FailedSteps > 0 ? "הסתיים, " + FailedSteps + " מתוך " + Steps.Count + " פעולות נכשלו." : "הסתיים בהצלחה.");
        }

        private static double Secs(Match m)
        {
            return int.Parse(m.Groups[1].Value) * 3600 + int.Parse(m.Groups[2].Value) * 60 +
                   double.Parse(m.Groups[3].Value, CultureInfo.InvariantCulture);
        }

        private void OnLine(string line, int step)
        {
            if (line == null) return;
            line = line.TrimEnd();
            if (line.Trim().Length == 0) return;
            double sub = -1;
            bool quiet = false;
            Match m = RxStep.Match(line);
            if (m.Success)
            {
                double a = double.Parse(m.Groups[1].Value), b = double.Parse(m.Groups[2].Value);
                if (b > 0) sub = a / b;
                string rest = line.Substring(m.Length).Trim();
                if (rest.Length > 0) Status = rest;
                quiet = true;
            }
            else
            {
                m = RxDur.Match(line);
                if (m.Success && duration == 0) duration = Secs(m);
                m = RxTime.Match(line);
                if (m.Success)
                {
                    if (duration > 0) sub = Secs(m) / duration;
                    quiet = true;
                }
                else
                {
                    m = RxPct.Match(line);
                    if (m.Success && line.Length < 120)
                    {
                        double v = double.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture);
                        if (v <= 100)
                        {
                            sub = v / 100.0;
                            Status = line.Trim();
                            quiet = QuietProgress;
                        }
                    }
                }
            }
            if (sub >= 0) Position = step * 1000L + (long)(Math.Min(1, sub) * 1000);
            if (!quiet) Log(line);
        }
    }
}
'@
try {
    $refs = @(
        [System.Windows.Media.Imaging.BitmapSource].Assembly.Location,
        [System.Windows.Threading.Dispatcher].Assembly.Location,
        [System.Xaml.XamlSchemaContext].Assembly.Location)
    $sha = [Security.Cryptography.SHA1]::Create()
    $hash = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($engineSource))[0..7] | ForEach-Object { $_.ToString('x2') })
    $dll = Join-Path $WorkDir "engine-$hash.dll"
    $loaded = $false
    if (Test-Path -LiteralPath $dll) {
        try { Add-Type -Path $dll; $loaded = $true } catch { }
    }
    if (-not $loaded) {
        try {
            Add-Type -TypeDefinition $engineSource -Language CSharp -ReferencedAssemblies $refs -OutputAssembly $dll -OutputType Library
            Add-Type -Path $dll
        } catch {
            Add-Type -TypeDefinition $engineSource -Language CSharp -ReferencedAssemblies $refs
        }
    }
} catch {
    Show-Error ("טעינת המנוע נכשלה:`n" + $_.Exception.Message)
    exit 1
}

$OfficeScript = @'
param([string]$JobFile)
# המרת מסמכים דרך Word / Excel / PowerPoint (או LibreOffice). רץ בתהליך נפרד כדי שהחלון הראשי לא ייתקע.
# כל שורה שמתחילה ב-PROGRESS מעדכנת את פס ההתקדמות בתוכנה.
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$job = Get-Content -LiteralPath $JobFile -Raw -Encoding UTF8 | ConvertFrom-Json
$files = @($job.Files)
$fmt = [string]$job.Format
$n = $files.Count

function Get-Target([string]$src, [string]$ext) {
    $dir = if ($job.OutputFolder) { [string]$job.OutputFolder } else { [IO.Path]::GetDirectoryName($src) }
    [void][IO.Directory]::CreateDirectory($dir)
    $base = [IO.Path]::GetFileNameWithoutExtension($src)
    $p = Join-Path $dir "$base.$ext"
    for ($k = 2; (Test-Path -LiteralPath $p); $k++) { $p = Join-Path $dir "$base ($k).$ext" }
    return $p
}

$wordExt = 'doc', 'docx', 'docm', 'dot', 'dotx', 'rtf', 'odt', 'txt', 'htm', 'html', 'mht', 'wps', 'pdf', 'xml'
$excelExt = 'xls', 'xlsx', 'xlsm', 'xlsb', 'csv', 'ods'
$pptExt = 'ppt', 'pptx', 'pptm', 'pps', 'ppsx', 'odp'
$wordCodes = @{ pdf = 17; docx = 16; doc = 0; rtf = 6; txt = 7; odt = 23; html = 10 }
$excelCodes = @{ pdf = -1; xlsx = 51; xls = 56; csv = 62; ods = 60; html = 44 }
$pptCodes = @{ pdf = 32; pptx = 24; ppt = 1; odp = 35 }

$word = $null; $excel = $null; $ppt = $null
$failed = 0
$soffice = [string]$job.LibreOffice

for ($i = 0; $i -lt $n; $i++) {
    $f = [string]$files[$i]
    $name = [IO.Path]::GetFileName($f)
    Write-Output "PROGRESS $i/$n $name"
    $ext = [IO.Path]::GetExtension($f).TrimStart('.').ToLower()
    try {
        if ($job.UseOffice -and $wordExt -contains $ext) {
            if (-not $wordCodes.ContainsKey($fmt)) { throw "Word לא יכול לשמור בפורמט $fmt. מתאים: PDF, DOCX, DOC, RTF, TXT, ODT, HTML" }
            if (-not $word) { $word = New-Object -ComObject Word.Application; $word.Visible = $false; $word.DisplayAlerts = 0 }
            $t = Get-Target $f $fmt
            $doc = $word.Documents.Open($f, $false, $true, $false)
            try {
                if ($fmt -eq 'pdf') { $doc.ExportAsFixedFormat($t, 17) } else { $doc.SaveAs2($t, $wordCodes[$fmt]) }
            } finally { $doc.Close(0) }
        } elseif ($job.UseOffice -and $excelExt -contains $ext) {
            if (-not $excelCodes.ContainsKey($fmt)) { throw "Excel לא יכול לשמור בפורמט $fmt. מתאים: PDF, XLSX, XLS, CSV, ODS, HTML" }
            if (-not $excel) { $excel = New-Object -ComObject Excel.Application; $excel.Visible = $false; $excel.DisplayAlerts = $false }
            $t = Get-Target $f $fmt
            $wb = $excel.Workbooks.Open($f, 0, $true)
            try {
                if ($fmt -eq 'pdf') { $wb.ExportAsFixedFormat(0, $t) } else { $wb.SaveAs($t, $excelCodes[$fmt]) }
            } finally { $wb.Close($false) }
        } elseif ($job.UseOffice -and $pptExt -contains $ext) {
            if (-not $pptCodes.ContainsKey($fmt)) { throw "PowerPoint לא יכול לשמור בפורמט $fmt. מתאים: PDF, PPTX, PPT, ODP" }
            if (-not $ppt) { $ppt = New-Object -ComObject PowerPoint.Application }
            $t = Get-Target $f $fmt
            $pres = $ppt.Presentations.Open($f, -1, 0, 0)
            try { $pres.SaveAs($t, $pptCodes[$fmt]) } finally { $pres.Close() }
        } elseif ($soffice) {
            # LibreOffice שומר בשם המקורי – ממירים לתיקייה זמנית ואז מעבירים לשם פנוי
            $t = Get-Target $f $fmt
            $tmp = Join-Path ([IO.Path]::GetTempPath()) ('cr-lo-' + [guid]::NewGuid().ToString('N'))
            [void][IO.Directory]::CreateDirectory($tmp)
            $filter = if ($fmt -eq 'txt') { 'txt:Text (encoded):UTF8' } else { $fmt }
            $p = Start-Process -FilePath $soffice -ArgumentList @('--headless', '--convert-to', $filter, '--outdir', "`"$tmp`"", "`"$f`"") -Wait -PassThru -WindowStyle Hidden
            $out = Get-ChildItem -LiteralPath $tmp -File | Select-Object -First 1
            if (-not $out) { throw "LibreOffice לא הצליח להמיר את הקובץ ל-$fmt (קוד $($p.ExitCode))" }
            Move-Item -LiteralPath $out.FullName -Destination $t
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            throw "אין תוכנה שיודעת לפתוח קבצי .$ext (צריך Microsoft Office או LibreOffice)"
        }
        Write-Output "✓ $([IO.Path]::GetFileName($t))"
    } catch {
        $failed++
        Write-Output "✗ $name – $($_.Exception.Message)"
    }
}
Write-Output "PROGRESS $n/$n"

foreach ($app in @($word, $excel, $ppt)) {
    if (-not $app) { continue }
    try { $app.Quit() } catch { }
    try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($app) } catch { }
}
[GC]::Collect()
if ($failed -gt 0) { exit 1 }
exit 0
'@

function Format-Size([long]$b) { [Recovery.Scanner]::FormatSize($b) }
function Get-Brush([string]$hex) { (New-Object Windows.Media.BrushConverter).ConvertFromString($hex) }

# ---------- החלון ----------
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ממיר ומשחזר" Width="1280" Height="830" MinWidth="1040" MinHeight="660"
        WindowStartupLocation="CenterScreen" FlowDirection="RightToLeft"
        FontFamily="Segoe UI" FontSize="14" Background="#F4F6FB" Foreground="#1E293B"
        UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <SolidColorBrush x:Key="Muted" Color="#64748B"/>
    <SolidColorBrush x:Key="Blue" Color="#2563EB"/>
    <SolidColorBrush x:Key="Purple" Color="#7C3AED"/>
    <SolidColorBrush x:Key="Green" Color="#059669"/>

    <Style x:Key="H1" TargetType="TextBlock">
      <Setter Property="FontSize" Value="30"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Foreground" Value="#0F172A"/>
    </Style>
    <Style x:Key="Sub" TargetType="TextBlock">
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin" Value="0,6,0,24"/>
    </Style>
    <Style x:Key="H2" TargetType="TextBlock">
      <Setter Property="FontSize" Value="18"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#0F172A"/>
      <Setter Property="Margin" Value="0,0,0,12"/>
    </Style>
    <Style x:Key="Note" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin" Value="0,4,0,4"/>
    </Style>
    <Style x:Key="Label" TargetType="TextBlock">
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Margin" Value="0,0,10,0"/>
      <Setter Property="MinWidth" Value="120"/>
    </Style>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="White"/>
      <Setter Property="CornerRadius" Value="16"/>
      <Setter Property="Padding" Value="24"/>
      <Setter Property="Margin" Value="0,0,0,16"/>
      <Setter Property="BorderBrush" Value="#E9EDF4"/>
      <Setter Property="BorderThickness" Value="1"/>
    </Style>
    <Style x:Key="Warn" TargetType="Border">
      <Setter Property="Background" Value="#FEF2F2"/>
      <Setter Property="BorderBrush" Value="#FECACA"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="16,12"/>
      <Setter Property="Margin" Value="0,0,0,16"/>
    </Style>
    <Style x:Key="Info" TargetType="Border" BasedOn="{StaticResource Warn}">
      <Setter Property="Background" Value="#EFF6FF"/>
      <Setter Property="BorderBrush" Value="#BFDBFE"/>
    </Style>
    <Style x:Key="Row" TargetType="DockPanel">
      <Setter Property="Margin" Value="0,6,0,6"/>
      <Setter Property="LastChildFill" Value="False"/>
    </Style>

    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Background" Value="#2563EB"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="22,9"/>
      <Setter Property="Margin" Value="0,0,10,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="HorizontalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
              <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.88"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.72"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Btn2" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#E2E8F0"/>
      <Setter Property="Foreground" Value="#1E293B"/>
      <Setter Property="FontWeight" Value="Normal"/>
      <Setter Property="Padding" Value="18,8"/>
    </Style>
    <Style x:Key="BtnPurple" TargetType="Button" BasedOn="{StaticResource Btn}"><Setter Property="Background" Value="#7C3AED"/></Style>
    <Style x:Key="BtnGreen" TargetType="Button" BasedOn="{StaticResource Btn}"><Setter Property="Background" Value="#059669"/></Style>
    <Style x:Key="BtnDanger" TargetType="Button" BasedOn="{StaticResource Btn2}">
      <Setter Property="Background" Value="#FEE2E2"/>
      <Setter Property="Foreground" Value="#B91C1C"/>
    </Style>
    <Style x:Key="Tile" TargetType="Button">
      <Setter Property="Background" Value="White"/>
      <Setter Property="Foreground" Value="#1E293B"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="MinHeight" Value="54"/>
      <Setter Property="Margin" Value="8"/>
      <Setter Property="Padding" Value="14,8"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="HorizontalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="12" Padding="{TemplateBinding Padding}"
                    BorderBrush="#E6EAF1" BorderThickness="1">
              <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="BorderBrush" Value="#93C5FD"/>
                <Setter TargetName="b" Property="Background" Value="#F7FAFF"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Background" Value="#EEF4FF"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="BigTile" TargetType="Button" BasedOn="{StaticResource Tile}">
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Padding" Value="20,16"/>
    </Style>

    <Style x:Key="Nav" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#E2E8F0"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="Margin" Value="10,1"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="GroupName" Value="nav"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="b" CornerRadius="8" Padding="18,9" Background="Transparent">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#2B3A52"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="b" Property="Background" Value="#2563EB"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="NavMain" TargetType="RadioButton" BasedOn="{StaticResource Nav}">
      <Setter Property="FontSize" Value="16"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Margin" Value="10,3"/>
    </Style>
    <Style x:Key="NavHead" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#7C8BA3"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="28,20,28,6"/>
    </Style>
    <Style x:Key="Pill" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#334155"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="Margin" Value="0,0,10,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="b" CornerRadius="20" Padding="22,9" Background="White" BorderBrush="#DCE3EC" BorderThickness="1">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="#93C5FD"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="b" Property="Background" Value="#1E293B"/>
                <Setter TargetName="b" Property="BorderBrush" Value="#1E293B"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="TextBox">
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="BorderBrush" Value="#CBD5E1"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Margin" Value="0,5,22,5"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="RadioButton">
      <Setter Property="Margin" Value="0,5,22,5"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="MinWidth" Value="220"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="ListView">
      <Setter Property="BorderBrush" Value="#E2E8F0"/>
      <Setter Property="Background" Value="White"/>
    </Style>
    <Style TargetType="ListBox">
      <Setter Property="BorderBrush" Value="#E2E8F0"/>
      <Setter Property="Background" Value="White"/>
    </Style>
    <Style x:Key="Bar" TargetType="ProgressBar">
      <Setter Property="Height" Value="8"/>
      <Setter Property="Minimum" Value="0"/>
      <Setter Property="Maximum" Value="1000"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Grid>
              <Border x:Name="PART_Track" CornerRadius="4" Background="#E5E9F0"/>
              <Border x:Name="PART_Indicator" CornerRadius="4" Background="#2563EB" HorizontalAlignment="Left" MinWidth="8"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsIndeterminate" Value="True">
                <Trigger.EnterActions>
                  <BeginStoryboard x:Name="pulse">
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="PART_Indicator" Storyboard.TargetProperty="Opacity"
                                       From="0.2" To="0.8" Duration="0:0:0.9" AutoReverse="True" RepeatBehavior="Forever"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions><StopStoryboard BeginStoryboardName="pulse"/></Trigger.ExitActions>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="300"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <!-- ===== תפריט צד ===== -->
    <Border Grid.Column="0" Background="#1E293B">
      <DockPanel>
        <StackPanel DockPanel.Dock="Top" Margin="28,34,28,16">
          <TextBlock Text="ממיר ומשחזר" FontSize="28" FontWeight="Bold" Foreground="White"/>
          <TextBlock Text="שחזור, המרה והעברת קבצים" Foreground="#94A3B8" FontSize="13.5" Margin="0,6,0,0"/>
        </StackPanel>
        <TextBlock x:Name="VersionText" DockPanel.Dock="Bottom" Text="גרסה 3.0" Foreground="#64748B" FontSize="11.5" Margin="28,8,28,16"/>
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel>
            <RadioButton x:Name="N_Home" Style="{StaticResource NavMain}" Content="דף הבית" IsChecked="True"/>
            <RadioButton x:Name="N_Recover" Style="{StaticResource NavMain}" Content="שחזור קבצים"/>
            <RadioButton x:Name="N_Convert" Style="{StaticResource NavMain}" Content="המרת קבצים"/>
            <RadioButton x:Name="N_Transfer" Style="{StaticResource NavMain}" Content="העברה ממחשב למחשב"/>
            <TextBlock Style="{StaticResource NavHead}" Text="עוד דרכי שחזור"/>
            <RadioButton x:Name="N_Bin" Style="{StaticResource Nav}" Content="סל המיחזור"/>
            <RadioButton x:Name="N_Versions" Style="{StaticResource Nav}" Content="גרסאות קודמות"/>
            <RadioButton x:Name="N_Unsaved" Style="{StaticResource Nav}" Content="מסמכים שלא נשמרו"/>
            <RadioButton x:Name="N_Search" Style="{StaticResource Nav}" Content="קבצים שנעלמו"/>
            <RadioButton x:Name="N_Deep" Style="{StaticResource Nav}" Content="סריקת עומק"/>
            <TextBlock Style="{StaticResource NavHead}" Text="כונן פגום"/>
            <RadioButton x:Name="N_Salvage" Style="{StaticResource Nav}" Content="העתקה מכונן פגום"/>
            <RadioButton x:Name="N_Image" Style="{StaticResource Nav}" Content="גיבוי כונן לקובץ"/>
            <RadioButton x:Name="N_Fix" Style="{StaticResource Nav}" Content="תיקון שגיאות בכונן"/>
          </StackPanel>
        </ScrollViewer>
      </DockPanel>
    </Border>

    <!-- ===== אזור התוכן ===== -->
    <Grid Grid.Column="1">
      <Grid.RowDefinitions>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <Grid Grid.Row="0">

        <!-- ===== דף הבית ===== -->
        <ScrollViewer x:Name="P_Home" VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="30,34,30,20">
            <TextBlock Style="{StaticResource H1}" Text="שלום! מה נעשה היום?" Margin="8,0"/>
            <TextBlock Style="{StaticResource Sub}" Text="בוחרים פעולה - והתוכנה תדריך אתכם צעד אחר צעד." Margin="8,8,8,20"/>
            <UniformGrid Columns="3">
              <Border Style="{StaticResource Card}" Margin="8">
                <StackPanel>
                  <Border Width="56" Height="56" CornerRadius="12" Background="{StaticResource Blue}" HorizontalAlignment="Left">
                    <TextBlock Text="&#xE777;" FontFamily="Segoe MDL2 Assets" FontSize="26" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  </Border>
                  <TextBlock Text="שחזור קבצים" FontSize="22" FontWeight="Bold" Foreground="#0F172A" Margin="0,22,0,8"/>
                  <TextBlock Style="{StaticResource Note}" Text="קבצים שנמחקו - עם השמות והתיקיות המקוריים" Height="42"/>
                  <Button x:Name="HomeRecover" Style="{StaticResource Btn}" Content="כניסה" HorizontalAlignment="Right" Margin="0,14,0,0" Padding="38,10"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Card}" Margin="8">
                <StackPanel>
                  <Border Width="56" Height="56" CornerRadius="12" Background="{StaticResource Purple}" HorizontalAlignment="Left">
                    <TextBlock Text="&#xE8AB;" FontFamily="Segoe MDL2 Assets" FontSize="26" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  </Border>
                  <TextBlock Text="המרת קבצים" FontSize="22" FontWeight="Bold" Foreground="#0F172A" Margin="0,22,0,8"/>
                  <TextBlock Style="{StaticResource Note}" Text="תמונות, שמע, וידאו, מסמכים ו-PDF" Height="42"/>
                  <Button x:Name="HomeConvert" Style="{StaticResource BtnPurple}" Content="כניסה" HorizontalAlignment="Right" Margin="0,14,0,0" Padding="38,10"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Card}" Margin="8">
                <StackPanel>
                  <Border Width="56" Height="56" CornerRadius="12" Background="{StaticResource Green}" HorizontalAlignment="Left">
                    <TextBlock Text="&#xE7F4;" FontFamily="Segoe MDL2 Assets" FontSize="26" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  </Border>
                  <TextBlock Text="העברה ממחשב למחשב" FontSize="22" FontWeight="Bold" Foreground="#0F172A" Margin="0,22,0,8"/>
                  <TextBlock Style="{StaticResource Note}" Text="כל הקבצים למחשב החדש - ברשת או בדיסק חיצוני" Height="42"/>
                  <Button x:Name="HomeTransfer" Style="{StaticResource BtnGreen}" Content="כניסה" HorizontalAlignment="Right" Margin="0,14,0,0" Padding="38,10"/>
                </StackPanel>
              </Border>
            </UniformGrid>
            <TextBlock Style="{StaticResource H2}" Text="עוד כלים" Margin="8,26,8,6"/>
            <UniformGrid Columns="4">
              <Button x:Name="T_Bin" Style="{StaticResource Tile}" Content="סל המיחזור"/>
              <Button x:Name="T_Versions" Style="{StaticResource Tile}" Content="גרסאות קודמות"/>
              <Button x:Name="T_Unsaved" Style="{StaticResource Tile}" Content="מסמכים שלא נשמרו"/>
              <Button x:Name="T_Search" Style="{StaticResource Tile}" Content="קבצים שנעלמו"/>
              <Button x:Name="T_Deep" Style="{StaticResource Tile}" Content="סריקת עומק"/>
              <Button x:Name="T_Salvage" Style="{StaticResource Tile}" Content="העתקה מכונן פגום"/>
              <Button x:Name="T_Image" Style="{StaticResource Tile}" Content="גיבוי כונן לקובץ"/>
              <Button x:Name="T_Fix" Style="{StaticResource Tile}" Content="תיקון שגיאות בכונן"/>
            </UniformGrid>
          </StackPanel>
        </ScrollViewer>

        <!-- ===== שחזור קבצים ===== -->
        <ScrollViewer x:Name="P_Recover" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
          <StackPanel Margin="38,34,38,20">
            <TextBlock Style="{StaticResource H1}" Text="שחזור קבצים"/>
            <TextBlock Style="{StaticResource Sub}" Text="מה קרה לקובץ? בחרו את המצב המתאים, והתוכנה תעביר אתכם לדרך השחזור הנכונה."/>
            <UniformGrid Columns="3" Margin="-8,0,-8,8">
              <Button x:Name="R_Bin" Style="{StaticResource BigTile}">
                <StackPanel>
                  <TextBlock Text="מחקתי רגיל" FontWeight="Bold" FontSize="16"/>
                  <TextBlock Style="{StaticResource Note}" Text="הקובץ כנראה בסל המיחזור - חוזר במלואו, עם השם."/>
                </StackPanel>
              </Button>
              <Button x:Name="R_Named" Style="{StaticResource BigTile}">
                <StackPanel>
                  <TextBlock Text="מחקתי לגמרי / רוקנתי את הסל" FontWeight="Bold" FontSize="16"/>
                  <TextBlock Style="{StaticResource Note}" Text="שחזור מהכונן, עם השמות והתיקיות המקוריים."/>
                </StackPanel>
              </Button>
              <Button x:Name="R_Versions" Style="{StaticResource BigTile}">
                <StackPanel>
                  <TextBlock Text="שמרתי מעל הקובץ" FontWeight="Bold" FontSize="16"/>
                  <TextBlock Style="{StaticResource Note}" Text="החזרת גרסה קודמת של קובץ או תיקייה."/>
                </StackPanel>
              </Button>
              <Button x:Name="R_Unsaved" Style="{StaticResource BigTile}">
                <StackPanel>
                  <TextBlock Text="סגרתי בלי לשמור" FontWeight="Bold" FontSize="16"/>
                  <TextBlock Style="{StaticResource Note}" Text="Word, Excel, PowerPoint ופנקס הרשימות."/>
                </StackPanel>
              </Button>
              <Button x:Name="R_Search" Style="{StaticResource BigTile}">
                <StackPanel>
                  <TextBlock Text="לא מוצא איפה שמרתי" FontWeight="Bold" FontSize="16"/>
                  <TextBlock Style="{StaticResource Note}" Text="חיפוש בכל המחשב, כולל תיקיות מוסתרות."/>
                </StackPanel>
              </Button>
              <Button x:Name="R_Deep" Style="{StaticResource BigTile}">
                <StackPanel>
                  <TextBlock Text="פרמטתי / הכונן לא נפתח" FontWeight="Bold" FontSize="16"/>
                  <TextBlock Style="{StaticResource Note}" Text="סריקת עומק לפי סוג הקובץ - גם אחרי פרמוט."/>
                </StackPanel>
              </Button>
            </UniformGrid>

            <Border x:Name="NamedCard" Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Style="{StaticResource H2}" Text="שחזור קבצים שנמחקו - עם השמות והתיקיות המקוריים"/>
                <TextBlock Style="{StaticResource Note}" Text="משתמש בכלי החינמי של מיקרוסופט (Windows File Recovery) ומפעיל אותו בשבילכם. מתאים לכונני NTFS (כמו כונן C)."/>
                <TextBlock x:Name="WinfrStatus" Margin="0,10,0,6" TextWrapping="Wrap" FontWeight="SemiBold"/>
                <StackPanel x:Name="WinfrInstallPanel" Orientation="Horizontal" Margin="0,4,0,4">
                  <Button x:Name="WinfrInstall" Style="{StaticResource Btn}" Content="התקנת הכלי (חינם)"/>
                  <Button x:Name="WinfrRecheck" Style="{StaticResource Btn2}" Content="בדוק שוב"/>
                </StackPanel>
                <StackPanel x:Name="WinfrForm">
                  <DockPanel Style="{StaticResource Row}">
                    <TextBlock Style="{StaticResource Label}" Text="הכונן שממנו נמחקו:"/>
                    <ComboBox x:Name="WinfrDrive" Width="340"/>
                  </DockPanel>
                  <DockPanel Style="{StaticResource Row}">
                    <TextBlock Style="{StaticResource Label}" Text="לשמור ב (כונן אחר):"/>
                    <TextBox x:Name="WinfrDest" Width="420"/>
                    <Button x:Name="WinfrBrowse" Style="{StaticResource Btn2}" Content="בחירה..." Margin="10,0,0,0"/>
                  </DockPanel>
                  <DockPanel Style="{StaticResource Row}">
                    <TextBlock Style="{StaticResource Label}" Text="סוג סריקה:"/>
                    <RadioButton x:Name="WinfrRegular" Content="מהירה - נמחקו לאחרונה" IsChecked="True"/>
                    <RadioButton x:Name="WinfrExtensive" Content="יסודית - נמחקו מזמן / אחרי פרמוט"/>
                  </DockPanel>
                  <DockPanel Style="{StaticResource Row}">
                    <TextBlock Style="{StaticResource Label}" Text="מה לחפש (לא חובה):"/>
                    <TextBox x:Name="WinfrFilter" Width="420" FlowDirection="LeftToRight"/>
                  </DockPanel>
                  <TextBlock Style="{StaticResource Note}" Text="לדוגמה: *.docx  או  *.jpg  או  \Users\שם\Documents\  או שם קובץ. כמה אפשרויות מפרידים ב- ;  ריק = הכל."/>
                  <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                    <Button x:Name="WinfrStart" Style="{StaticResource Btn}" Content="התחל שחזור"/>
                    <Button x:Name="WinfrOpen" Style="{StaticResource Btn2}" Content="פתח את התיקייה"/>
                  </StackPanel>
                </StackPanel>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Style="{StaticResource H2}" Text="לפני שמתחילים - חשוב לדעת"/>
                <TextBlock Style="{StaticResource Note}" Text="1. הפסיקו להשתמש בכונן שממנו נמחקו הקבצים. כל קובץ חדש שנשמר עליו (הורדות, התקנות ואפילו גלישה) עלול לדרוס את מה שנמחק."/>
                <TextBlock Style="{StaticResource Note}" Text="2. שמרו את הקבצים המשוחזרים תמיד על כונן אחר - דיסק-און-קי או דיסק חיצוני."/>
                <TextBlock Style="{StaticResource Note}" Text="3. היה מסונכרן לענן? בדקו גם את סל המיחזור של OneDrive / Google Drive / Dropbox באתר - הם שומרים קבצים שנמחקו כ-30 יום."/>
                <TextBlock Style="{StaticResource Note}" Text="4. בכונני SSD, Windows מנקה את השטח הפנוי זמן קצר אחרי המחיקה (TRIM) - פעלו מהר."/>
                <TextBlock Style="{StaticResource Note}" Text="5. כונן שמשמיע רעשים, איטי מאוד או נתקע? אל תסרקו אותו שוב ושוב - קודם 'העתקה מכונן פגום' או 'גיבוי כונן לקובץ'."/>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- ===== המרת קבצים ===== -->
        <ScrollViewer x:Name="P_Convert" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
          <StackPanel Margin="38,34,38,20">
            <TextBlock Style="{StaticResource H1}" Text="המרת קבצים"/>
            <TextBlock Style="{StaticResource Sub}" Text="בוחרים סוג, מוסיפים קבצים (אפשר גם לגרור לכאן), בוחרים פורמט - ולוחצים המרה."/>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,18">
              <RadioButton x:Name="CvImages" Style="{StaticResource Pill}" GroupName="cv" Content="תמונות" IsChecked="True"/>
              <RadioButton x:Name="CvMedia" Style="{StaticResource Pill}" GroupName="cv" Content="שמע ווידאו"/>
              <RadioButton x:Name="CvDocs" Style="{StaticResource Pill}" GroupName="cv" Content="מסמכים ו-PDF"/>
            </StackPanel>

            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Style="{StaticResource H2}" Text="1. בחירת קבצים"/>
                <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
                  <Button x:Name="CvAddFiles" Style="{StaticResource Btn2}" Content="הוספת קבצים..."/>
                  <Button x:Name="CvAddFolder" Style="{StaticResource Btn2}" Content="הוספת תיקייה..."/>
                  <Button x:Name="CvRemove" Style="{StaticResource Btn2}" Content="הסרת המסומנים"/>
                  <Button x:Name="CvClear" Style="{StaticResource Btn2}" Content="ניקוי הרשימה"/>
                  <TextBlock x:Name="CvCount" VerticalAlignment="Center" Foreground="{StaticResource Muted}" Margin="10,0"/>
                </StackPanel>
                <ListBox x:Name="CvList" Height="190" SelectionMode="Extended" AllowDrop="True"/>
                <TextBlock x:Name="CvHint" Style="{StaticResource Note}" Margin="0,8,0,0"/>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Style="{StaticResource H2}" Text="2. לאיזה פורמט להמיר?"/>
                <DockPanel Style="{StaticResource Row}">
                  <TextBlock Style="{StaticResource Label}" Text="פורמט יעד:"/>
                  <ComboBox x:Name="CvFormat" Width="300"/>
                </DockPanel>
                <StackPanel x:Name="CvImgOptions">
                  <DockPanel Style="{StaticResource Row}">
                    <TextBlock Style="{StaticResource Label}" Text="איכות:"/>
                    <ComboBox x:Name="CvQuality" Width="300"/>
                  </DockPanel>
                  <DockPanel Style="{StaticResource Row}">
                    <TextBlock Style="{StaticResource Label}" Text="גודל תמונה:"/>
                    <ComboBox x:Name="CvResize" Width="300"/>
                  </DockPanel>
                  <CheckBox x:Name="CvSinglePdf" Content="כל התמונות בקובץ PDF אחד (כל תמונה בעמוד)" IsChecked="True"/>
                </StackPanel>
                <StackPanel x:Name="CvMediaOptions" Visibility="Collapsed">
                  <DockPanel Style="{StaticResource Row}">
                    <TextBlock Style="{StaticResource Label}" Text="איכות:"/>
                    <ComboBox x:Name="CvMediaQuality" Width="300"/>
                  </DockPanel>
                </StackPanel>
                <Border x:Name="CvToolBox" Style="{StaticResource Info}" Margin="0,12,0,0">
                  <DockPanel LastChildFill="True">
                    <Button x:Name="CvToolInstall" DockPanel.Dock="Right" Style="{StaticResource Btn}" Content="התקנה" Margin="10,0,0,0" Visibility="Collapsed"/>
                    <TextBlock x:Name="CvToolText" TextWrapping="Wrap" VerticalAlignment="Center"/>
                  </DockPanel>
                </Border>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Style="{StaticResource H2}" Text="3. לאן לשמור?"/>
                <RadioButton x:Name="CvSameFolder" GroupName="cvout" Content="באותה תיקייה של הקובץ המקורי" IsChecked="True"/>
                <DockPanel Style="{StaticResource Row}">
                  <RadioButton x:Name="CvOtherFolder" GroupName="cvout" Content="בתיקייה:" VerticalAlignment="Center"/>
                  <TextBox x:Name="CvOut" Width="420"/>
                  <Button x:Name="CvBrowse" Style="{StaticResource Btn2}" Content="בחירה..." Margin="10,0,0,0"/>
                </DockPanel>
                <StackPanel Orientation="Horizontal" Margin="0,16,0,0">
                  <Button x:Name="CvStart" Style="{StaticResource BtnPurple}" Content="המרה" Padding="44,10"/>
                  <Button x:Name="CvOpen" Style="{StaticResource Btn2}" Content="פתח את התיקייה" IsEnabled="False"/>
                </StackPanel>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- ===== העברה ממחשב למחשב ===== -->
        <ScrollViewer x:Name="P_Transfer" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
          <StackPanel Margin="38,34,38,20">
            <TextBlock Style="{StaticResource H1}" Text="העברה ממחשב למחשב"/>
            <TextBlock Style="{StaticResource Sub}" Text="מעבירים את הקבצים, הסימניות, רשתות ה-Wi-Fi ורשימת התוכנות למחשב החדש - דרך דיסק חיצוני או תיקייה משותפת ברשת."/>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,18">
              <RadioButton x:Name="TrOld" Style="{StaticResource Pill}" GroupName="tr" Content="שלב 1: במחשב הישן - אריזה" IsChecked="True"/>
              <RadioButton x:Name="TrNew" Style="{StaticResource Pill}" GroupName="tr" Content="שלב 2: במחשב החדש - פריסה"/>
            </StackPanel>

            <StackPanel x:Name="TrOldPanel">
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Style="{StaticResource H2}" Text="מה להעביר?"/>
                  <WrapPanel>
                    <CheckBox x:Name="TrDesktop" Content="שולחן העבודה" IsChecked="True" Width="200"/>
                    <CheckBox x:Name="TrDocuments" Content="מסמכים" IsChecked="True" Width="200"/>
                    <CheckBox x:Name="TrPictures" Content="תמונות" IsChecked="True" Width="200"/>
                    <CheckBox x:Name="TrVideos" Content="סרטונים" IsChecked="True" Width="200"/>
                    <CheckBox x:Name="TrMusic" Content="מוזיקה" IsChecked="True" Width="200"/>
                    <CheckBox x:Name="TrDownloads" Content="הורדות" IsChecked="True" Width="200"/>
                    <CheckBox x:Name="TrFavorites" Content="מועדפים" IsChecked="True" Width="200"/>
                  </WrapPanel>
                  <TextBlock Style="{StaticResource H2}" Text="הגדרות" Margin="0,14,0,6" FontSize="15"/>
                  <WrapPanel>
                    <CheckBox x:Name="TrBookmarks" Content="סימניות של Chrome ו-Edge" IsChecked="True" Width="300"/>
                    <CheckBox x:Name="TrWifi" Content="רשתות Wi-Fi והסיסמאות שלהן" IsChecked="True" Width="300"/>
                    <CheckBox x:Name="TrApps" Content="רשימת התוכנות (להתקנה מחדש)" IsChecked="True" Width="300"/>
                  </WrapPanel>
                  <TextBlock Style="{StaticResource H2}" Text="תיקיות נוספות" Margin="0,14,0,6" FontSize="15"/>
                  <ListBox x:Name="TrExtra" Height="80" SelectionMode="Extended"/>
                  <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
                    <Button x:Name="TrExtraAdd" Style="{StaticResource Btn2}" Content="הוספת תיקייה..."/>
                    <Button x:Name="TrExtraRemove" Style="{StaticResource Btn2}" Content="הסרה"/>
                  </StackPanel>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Style="{StaticResource H2}" Text="לאן לשמור?"/>
                  <DockPanel Style="{StaticResource Row}">
                    <TextBlock Style="{StaticResource Label}" Text="תיקיית יעד:"/>
                    <TextBox x:Name="TrDest" Width="420"/>
                    <Button x:Name="TrDestBrowse" Style="{StaticResource Btn2}" Content="בחירה..." Margin="10,0,0,0"/>
                  </DockPanel>
                  <TextBlock Style="{StaticResource Note}" Text="דיסק חיצוני, דיסק-און-קי, או תיקייה משותפת ברשת (למשל \\שם-המחשב-החדש\תיקייה). אם העצירה באמצע - הפעלה חוזרת ממשיכה מאיפה שנעצר."/>
                  <StackPanel Orientation="Horizontal" Margin="0,14,0,0">
                    <Button x:Name="TrPack" Style="{StaticResource BtnGreen}" Content="התחל אריזה" Padding="36,10"/>
                    <Button x:Name="TrPackOpen" Style="{StaticResource Btn2}" Content="פתח את התיקייה" IsEnabled="False"/>
                  </StackPanel>
                </StackPanel>
              </Border>
            </StackPanel>

            <StackPanel x:Name="TrNewPanel" Visibility="Collapsed">
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Style="{StaticResource H2}" Text="איפה נמצאים הקבצים מהמחשב הישן?"/>
                  <DockPanel Style="{StaticResource Row}">
                    <TextBlock Style="{StaticResource Label}" Text="תיקיית ההעברה:"/>
                    <TextBox x:Name="TrSrc" Width="420"/>
                    <Button x:Name="TrSrcBrowse" Style="{StaticResource Btn2}" Content="בחירה..." Margin="10,0,0,0"/>
                  </DockPanel>
                  <TextBlock Style="{StaticResource Note}" Text="בוחרים את התיקייה שנוצרה בשלב 1 (שמה מתחיל ב'העברת קבצים')."/>
                  <TextBlock x:Name="TrSrcInfo" Margin="0,10,0,4" FontWeight="SemiBold" TextWrapping="Wrap"/>
                  <WrapPanel x:Name="TrItems" Margin="0,4,0,0"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Style="{StaticResource H2}" Text="אפשרויות"/>
                  <CheckBox x:Name="TrWifiImport" Content="ייבוא רשתות ה-Wi-Fi" IsChecked="True"/>
                  <CheckBox x:Name="TrAppsImport" Content="התקנה מחדש של התוכנות (דרך winget של Windows - לוקח זמן)" IsChecked="False"/>
                  <TextBlock Style="{StaticResource Note}" Text="קבצים שכבר קיימים ויש להם אותו תוכן - מדלגים. קבצים שונים באותו שם - נשמרים בשם חדש, בלי לדרוס כלום."/>
                  <StackPanel Orientation="Horizontal" Margin="0,14,0,0">
                    <Button x:Name="TrRestore" Style="{StaticResource BtnGreen}" Content="התחל פריסה" Padding="36,10"/>
                  </StackPanel>
                </StackPanel>
              </Border>
            </StackPanel>

            <Border Style="{StaticResource Info}">
              <StackPanel>
                <TextBlock FontWeight="SemiBold" Text="העברה ברשת, בלי דיסק חיצוני:"/>
                <TextBlock TextWrapping="Wrap" Margin="0,4,0,0" Text="במחשב החדש: לוחצים ימני על תיקייה ריקה ← מאפיינים ← שיתוף ← שיתוף... ומוסיפים את המשתמש. במחשב הישן: בשדה 'תיקיית יעד' כותבים \\שם-המחשב-החדש\שם-התיקייה. שני המחשבים צריכים להיות מחוברים לאותה רשת."/>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- ===== סל המיחזור ===== -->
        <ScrollViewer x:Name="P_Bin" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
          <StackPanel Margin="38,34,38,20">
            <TextBlock Style="{StaticResource H1}" Text="סל המיחזור"/>
            <TextBlock Style="{StaticResource Sub}" Text="קבצים שנמחקו רגיל (בלי Shift) נמצאים כאן, וחוזרים במלואם עם השם והמיקום המקוריים."/>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <DockPanel Style="{StaticResource Row}" Margin="0,0,0,12">
                  <TextBlock Style="{StaticResource Label}" Text="חיפוש:" MinWidth="0"/>
                  <TextBox x:Name="BinFilter" Width="300"/>
                  <Button x:Name="BinRefresh" Style="{StaticResource Btn2}" Content="חיפוש / רענון" Margin="10,0,0,0"/>
                  <TextBlock x:Name="BinCount" VerticalAlignment="Center" Foreground="{StaticResource Muted}" Margin="14,0"/>
                </DockPanel>
                <ListView x:Name="BinList" Height="380" SelectionMode="Extended">
                  <ListView.View>
                    <GridView>
                      <GridViewColumn Header="שם" Width="240" DisplayMemberBinding="{Binding Name}"/>
                      <GridViewColumn Header="מיקום מקורי" Width="360" DisplayMemberBinding="{Binding Folder}"/>
                      <GridViewColumn Header="נמחק בתאריך" Width="150" DisplayMemberBinding="{Binding DateText}"/>
                      <GridViewColumn Header="גודל" Width="100" DisplayMemberBinding="{Binding SizeText}"/>
                    </GridView>
                  </ListView.View>
                </ListView>
                <TextBlock Style="{StaticResource Note}" Text="לבחירת כמה פריטים: Ctrl + לחיצה, או Shift + לחיצה לטווח." Margin="0,8,0,0"/>
                <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                  <Button x:Name="BinRestore" Style="{StaticResource Btn}" Content="שחזר למקום המקורי"/>
                  <Button x:Name="BinCopy" Style="{StaticResource Btn2}" Content="העתק לתיקייה אחרת..."/>
                  <Button x:Name="BinAll" Style="{StaticResource Btn2}" Content="בחר הכל"/>
                </StackPanel>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- ===== גרסאות קודמות ===== -->
        <ScrollViewer x:Name="P_Versions" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
          <StackPanel Margin="38,34,38,20">
            <TextBlock Style="{StaticResource H1}" Text="גרסאות קודמות"/>
            <TextBlock Style="{StaticResource Sub}" Text="Windows שומר מדי פעם 'צילום' של הכונן (נקודות שחזור). מכאן פותחים צילום ישן ולוקחים ממנו את הגרסה הקודמת של הקובץ."/>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <DockPanel Style="{StaticResource Row}">
                  <TextBlock Style="{StaticResource Label}" Text="התיקייה של הקובץ:"/>
                  <TextBox x:Name="VerFolder" Width="420"/>
                  <Button x:Name="VerBrowse" Style="{StaticResource Btn2}" Content="בחירה..." Margin="10,0,0,0"/>
                  <Button x:Name="VerFind" Style="{StaticResource Btn}" Content="חפש גרסאות" Margin="10,0,0,0"/>
                </DockPanel>
                <ListView x:Name="VerList" Height="260" Margin="0,12,0,0" SelectionMode="Single">
                  <ListView.View>
                    <GridView>
                      <GridViewColumn Header="תאריך הצילום" Width="200" DisplayMemberBinding="{Binding DateText}"/>
                      <GridViewColumn Header="כונן" Width="80" DisplayMemberBinding="{Binding Drive}"/>
                      <GridViewColumn Header="לפני" Width="160" DisplayMemberBinding="{Binding Age}"/>
                    </GridView>
                  </ListView.View>
                </ListView>
                <TextBlock x:Name="VerInfo" Style="{StaticResource Note}" Margin="0,8,0,0"/>
                <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                  <Button x:Name="VerOpen" Style="{StaticResource Btn}" Content="פתח את הגרסה בסייר הקבצים"/>
                  <Button x:Name="VerCopy" Style="{StaticResource Btn2}" Content="העתק את התיקייה מהגרסה הזו..."/>
                </StackPanel>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Style="{StaticResource H2}" Text="עוד אפשרויות"/>
                <TextBlock Style="{StaticResource Note}" Text="אין צילומים? כנראה ש'הגנת מערכת' כבויה. כדאי להפעיל אותה עכשיו - כדי שבפעם הבאה תהיה גרסה קודמת לחזור אליה."/>
                <WrapPanel Margin="0,10,0,0">
                  <Button x:Name="VerHistory" Style="{StaticResource Btn2}" Content="היסטוריית קבצים" Margin="0,0,10,8"/>
                  <Button x:Name="VerProtection" Style="{StaticResource Btn2}" Content="הגדרות הגנת מערכת" Margin="0,0,10,8"/>
                  <Button x:Name="VerCreate" Style="{StaticResource Btn2}" Content="צור נקודת שחזור עכשיו" Margin="0,0,10,8"/>
                </WrapPanel>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- ===== מסמכים שלא נשמרו ===== -->
        <ScrollViewer x:Name="P_Unsaved" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
          <StackPanel Margin="38,34,38,20">
            <TextBlock Style="{StaticResource H1}" Text="מסמכים שלא נשמרו"/>
            <TextBlock Style="{StaticResource Sub}" Text="Word, Excel, PowerPoint, פנקס הרשימות ו-Notepad++ שומרים עותקים זמניים בזמן העבודה. כאן מוצאים אותם - גם אחרי קריסה או סגירה בלי שמירה."/>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <DockPanel Style="{StaticResource Row}" Margin="0,0,0,12">
                  <Button x:Name="UnsRefresh" Style="{StaticResource Btn2}" Content="חיפוש מחדש"/>
                  <TextBlock x:Name="UnsCount" VerticalAlignment="Center" Foreground="{StaticResource Muted}" Margin="6,0"/>
                </DockPanel>
                <ListView x:Name="UnsList" Height="340" SelectionMode="Extended">
                  <ListView.View>
                    <GridView>
                      <GridViewColumn Header="תוכנה" Width="140" DisplayMemberBinding="{Binding App}"/>
                      <GridViewColumn Header="שם" Width="260" DisplayMemberBinding="{Binding Name}"/>
                      <GridViewColumn Header="נשמר לאחרונה" Width="150" DisplayMemberBinding="{Binding DateText}"/>
                      <GridViewColumn Header="גודל" Width="90" DisplayMemberBinding="{Binding SizeText}"/>
                      <GridViewColumn Header="מיקום" Width="300" DisplayMemberBinding="{Binding Folder}"/>
                    </GridView>
                  </ListView.View>
                </ListView>
                <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                  <Button x:Name="UnsOpen" Style="{StaticResource Btn}" Content="פתיחה"/>
                  <Button x:Name="UnsSave" Style="{StaticResource Btn2}" Content="שמירת עותק אל..."/>
                  <Button x:Name="UnsFolder" Style="{StaticResource Btn2}" Content="הצג בתיקייה"/>
                </StackPanel>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Info}">
              <TextBlock TextWrapping="Wrap" Text="עוד דרך ב-Word/Excel/PowerPoint: קובץ ← מידע ← ניהול מסמך ← 'שחזר מסמכים שלא נשמרו'. כשפותחים קובץ משוחזר - שמרו אותו מיד בשם חדש (קובץ ← שמירה בשם)."/>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- ===== קבצים שנעלמו ===== -->
        <ScrollViewer x:Name="P_Search" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
          <StackPanel Margin="38,34,38,20">
            <TextBlock Style="{StaticResource H1}" Text="קבצים שנעלמו"/>
            <TextBlock Style="{StaticResource Sub}" Text="לא זוכרים איפה שמרתם? הקובץ 'נעלם' אחרי גרירה בטעות? מחפשים בכל המחשב - כולל תיקיות מוסתרות, OneDrive וכוננים חיצוניים."/>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <DockPanel Style="{StaticResource Row}">
                  <TextBlock Style="{StaticResource Label}" Text="שם הקובץ (או חלק ממנו):"/>
                  <TextBox x:Name="SrName" Width="360"/>
                </DockPanel>
                <DockPanel Style="{StaticResource Row}">
                  <TextBlock Style="{StaticResource Label}" Text="סוג:"/>
                  <ComboBox x:Name="SrType" Width="220"/>
                  <TextBlock Style="{StaticResource Label}" Text="שונה לאחרונה:" MinWidth="0" Margin="24,0,10,0"/>
                  <ComboBox x:Name="SrTime" Width="180" MinWidth="0"/>
                </DockPanel>
                <DockPanel Style="{StaticResource Row}">
                  <TextBlock Style="{StaticResource Label}" Text="איפה לחפש:"/>
                  <ComboBox x:Name="SrWhere" Width="360"/>
                </DockPanel>
                <StackPanel Orientation="Horizontal" Margin="0,12,0,12">
                  <Button x:Name="SrStart" Style="{StaticResource Btn}" Content="חפש"/>
                  <TextBlock x:Name="SrCount" VerticalAlignment="Center" Foreground="{StaticResource Muted}" Margin="6,0"/>
                </StackPanel>
                <ListView x:Name="SrList" Height="330" SelectionMode="Extended">
                  <ListView.View>
                    <GridView>
                      <GridViewColumn Header="שם" Width="250" DisplayMemberBinding="{Binding Name}"/>
                      <GridViewColumn Header="תיקייה" Width="380" DisplayMemberBinding="{Binding Folder}"/>
                      <GridViewColumn Header="שונה בתאריך" Width="150" DisplayMemberBinding="{Binding DateText}"/>
                      <GridViewColumn Header="גודל" Width="90" DisplayMemberBinding="{Binding SizeText}"/>
                    </GridView>
                  </ListView.View>
                </ListView>
                <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                  <Button x:Name="SrOpen" Style="{StaticResource Btn}" Content="פתיחה"/>
                  <Button x:Name="SrShow" Style="{StaticResource Btn2}" Content="הצג בתיקייה"/>
                  <Button x:Name="SrCopy" Style="{StaticResource Btn2}" Content="העתק אל..."/>
                </StackPanel>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- ===== סריקת עומק ===== -->
        <ScrollViewer x:Name="P_Deep" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
          <StackPanel Margin="38,34,38,20">
            <TextBlock Style="{StaticResource H1}" Text="סריקת עומק"/>
            <TextBlock Style="{StaticResource Sub}" Text="מוצאת תמונות, מסמכים וסרטונים שנמחקו לגמרי - גם אחרי ריקון הסל, Shift+Delete או פרמוט. הקבצים חוזרים ממוינים לתיקיות לפי סוג, בלי השמות המקוריים."/>
            <Border Style="{StaticResource Warn}">
              <TextBlock TextWrapping="Wrap" Foreground="#991B1B" FontWeight="SemiBold" Text="חשוב: שמרו את הקבצים המשוחזרים על כונן אחר (למשל דיסק-און-קי). כתיבה לאותו כונן עלולה לדרוס בדיוק את מה שמנסים להציל."/>
            </Border>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Style="{StaticResource H2}" Text="מה לסרוק?"/>
                <DockPanel Style="{StaticResource Row}">
                  <RadioButton x:Name="DpFromDrive" GroupName="dpsrc" Content="כונן:" IsChecked="True" MinWidth="130"/>
                  <ComboBox x:Name="DpDrive" Width="360"/>
                </DockPanel>
                <DockPanel Style="{StaticResource Row}">
                  <RadioButton x:Name="DpFromImage" GroupName="dpsrc" Content="קובץ תמונת כונן:" MinWidth="130"/>
                  <TextBox x:Name="DpImage" Width="360"/>
                  <Button x:Name="DpImageBrowse" Style="{StaticResource Btn2}" Content="בחירה..." Margin="10,0,0,0"/>
                </DockPanel>
                <DockPanel Style="{StaticResource Row}" Margin="0,14,0,6">
                  <TextBlock Style="{StaticResource Label}" Text="לשמור את הקבצים ב:" MinWidth="130"/>
                  <TextBox x:Name="DpOut" Width="360"/>
                  <Button x:Name="DpOutBrowse" Style="{StaticResource Btn2}" Content="בחירה..." Margin="10,0,0,0"/>
                </DockPanel>
                <TextBlock Style="{StaticResource H2}" Text="אילו קבצים לחפש?" Margin="0,16,0,6" FontSize="15"/>
                <WrapPanel>
                  <CheckBox x:Name="DpJpg" Content="JPG" IsChecked="True"/>
                  <CheckBox x:Name="DpPng" Content="PNG" IsChecked="True"/>
                  <CheckBox x:Name="DpGif" Content="GIF" IsChecked="True"/>
                  <CheckBox x:Name="DpHeic" Content="HEIC (אייפון)" IsChecked="True"/>
                  <CheckBox x:Name="DpPdf" Content="PDF" IsChecked="True"/>
                  <CheckBox x:Name="DpOffice" Content="Word / Excel / PowerPoint / ZIP" IsChecked="True"/>
                  <CheckBox x:Name="DpVideo" Content="סרטונים MP4 / MOV" IsChecked="True"/>
                </WrapPanel>
                <CheckBox x:Name="DpFree" Content="לסרוק רק שטח פנוי (מהיר יותר, בלי כפילויות של קבצים קיימים - מומלץ)" IsChecked="True" Margin="0,12,0,4"/>
                <DockPanel Style="{StaticResource Row}">
                  <TextBlock Style="{StaticResource Label}" Text="לדלג על קבצים קטנים מ-" MinWidth="0"/>
                  <TextBox x:Name="DpMin" Width="70" Text="10" FlowDirection="LeftToRight"/>
                  <TextBlock Text="KB (מסנן תמונות ממוזערות)" VerticalAlignment="Center" Margin="10,0"/>
                </DockPanel>
                <StackPanel Orientation="Horizontal" Margin="0,16,0,0">
                  <Button x:Name="DpStart" Style="{StaticResource Btn}" Content="התחל סריקה" Padding="36,10"/>
                  <Button x:Name="DpOpen" Style="{StaticResource Btn2}" Content="פתח את תיקיית הקבצים"/>
                </StackPanel>
                <TextBlock x:Name="DpSummary" Margin="0,12,0,0" FontWeight="SemiBold" TextWrapping="Wrap"/>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- ===== העתקה מכונן פגום ===== -->
        <ScrollViewer x:Name="P_Salvage" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
          <StackPanel Margin="38,34,38,20">
            <TextBlock Style="{StaticResource H1}" Text="העתקה מכונן פגום"/>
            <TextBlock Style="{StaticResource Sub}" Text="מעתיקה קבצים מכונן שמתחיל להיכשל: מנסה שוב, מדלגת על אזורים פגומים וממשיכה הלאה - במקום להיתקע כמו העתקה רגילה."/>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <DockPanel Style="{StaticResource Row}">
                  <TextBlock Style="{StaticResource Label}" Text="מה להעתיק (תיקייה):" MinWidth="150"/>
                  <TextBox x:Name="SvSrc" Width="400"/>
                  <Button x:Name="SvSrcBrowse" Style="{StaticResource Btn2}" Content="בחירה..." Margin="10,0,0,0"/>
                </DockPanel>
                <DockPanel Style="{StaticResource Row}">
                  <TextBlock Style="{StaticResource Label}" Text="לאן (כונן תקין):" MinWidth="150"/>
                  <TextBox x:Name="SvDst" Width="400"/>
                  <Button x:Name="SvDstBrowse" Style="{StaticResource Btn2}" Content="בחירה..." Margin="10,0,0,0"/>
                </DockPanel>
                <DockPanel Style="{StaticResource Row}">
                  <TextBlock Style="{StaticResource Label}" Text="ניסיונות חוזרים:" MinWidth="150"/>
                  <ComboBox x:Name="SvRetries" Width="200" MinWidth="0"/>
                </DockPanel>
                <CheckBox x:Name="SvSkip" Content="לדלג על קבצים שכבר הועתקו (להמשך אחרי עצירה)" IsChecked="True"/>
                <StackPanel Orientation="Horizontal" Margin="0,16,0,0">
                  <Button x:Name="SvStart" Style="{StaticResource Btn}" Content="התחל העתקה" Padding="36,10"/>
                  <Button x:Name="SvOpen" Style="{StaticResource Btn2}" Content="פתח את התיקייה"/>
                </StackPanel>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Info}">
              <StackPanel>
                <TextBlock FontWeight="SemiBold" Text="טיפים לכונן גוסס:"/>
                <TextBlock TextWrapping="Wrap" Margin="0,4,0,0" Text="• התחילו מהתיקייה הכי חשובה (למשל התמונות), ורק אחר כך את השאר - כל דקה של עבודה שוחקת את הכונן."/>
                <TextBlock TextWrapping="Wrap" Text="• קבצים שרק חלק מהם נקרא יסומנו בדוח שנשמר בתיקיית היעד."/>
                <TextBlock TextWrapping="Wrap" Text="• כונן שמשמיע נקישות - כבו אותו ופנו למעבדת שחזור. ניסיונות נוספים עלולים להרוס אותו סופית."/>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- ===== גיבוי כונן לקובץ ===== -->
        <ScrollViewer x:Name="P_Image" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
          <StackPanel Margin="38,34,38,20">
            <TextBlock Style="{StaticResource H1}" Text="גיבוי כונן לקובץ"/>
            <TextBlock Style="{StaticResource Sub}" Text="יוצר עותק מלא של כונן - סקטור אחרי סקטור - בתוך קובץ אחד (‎.img). אחר כך אפשר לחפש בעותק בסריקת עומק, בלי להעמיס על הכונן המקורי."/>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <DockPanel Style="{StaticResource Row}">
                  <TextBlock Style="{StaticResource Label}" Text="הכונן לגיבוי:" MinWidth="150"/>
                  <ComboBox x:Name="ImDrive" Width="400"/>
                </DockPanel>
                <DockPanel Style="{StaticResource Row}">
                  <TextBlock Style="{StaticResource Label}" Text="לשמור בקובץ:" MinWidth="150"/>
                  <TextBox x:Name="ImOut" Width="400"/>
                  <Button x:Name="ImBrowse" Style="{StaticResource Btn2}" Content="בחירה..." Margin="10,0,0,0"/>
                </DockPanel>
                <TextBlock x:Name="ImInfo" Style="{StaticResource Note}" Margin="0,8,0,0"/>
                <StackPanel Orientation="Horizontal" Margin="0,16,0,0">
                  <Button x:Name="ImStart" Style="{StaticResource Btn}" Content="התחל גיבוי" Padding="36,10"/>
                  <Button x:Name="ImScan" Style="{StaticResource Btn2}" Content="סרוק את הקובץ בסריקת עומק"/>
                </StackPanel>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Info}">
              <TextBlock TextWrapping="Wrap" Text="הקובץ יהיה בגודל של כל הכונן (לא רק השטח התפוס), לכן צריך כונן יעד גדול מספיק. אזורים שלא ניתן לקרוא ממולאים באפסים, והמיקומים שלהם נרשמים בפירוט."/>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- ===== תיקון שגיאות בכונן ===== -->
        <ScrollViewer x:Name="P_Fix" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
          <StackPanel Margin="38,34,38,20">
            <TextBlock Style="{StaticResource H1}" Text="תיקון שגיאות בכונן"/>
            <TextBlock Style="{StaticResource Sub}" Text="בודק את בריאות הדיסקים ואת מערכת הקבצים, ומתקן שגיאות בעזרת הכלי המובנה של Windows (chkdsk)."/>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <DockPanel Style="{StaticResource Row}" Margin="0,0,0,10">
                  <TextBlock Style="{StaticResource H2}" Text="מצב הדיסקים" Margin="0"/>
                  <Button x:Name="FxHealthRefresh" Style="{StaticResource Btn2}" Content="רענון" DockPanel.Dock="Right" Margin="0"/>
                </DockPanel>
                <ListView x:Name="FxDisks" Height="130">
                  <ListView.View>
                    <GridView>
                      <GridViewColumn Header="דיסק" Width="300" DisplayMemberBinding="{Binding Name}"/>
                      <GridViewColumn Header="סוג" Width="90" DisplayMemberBinding="{Binding Kind}"/>
                      <GridViewColumn Header="גודל" Width="100" DisplayMemberBinding="{Binding SizeText}"/>
                      <GridViewColumn Header="מצב" Width="260" DisplayMemberBinding="{Binding Health}"/>
                    </GridView>
                  </ListView.View>
                </ListView>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Style="{StaticResource H2}" Text="בדיקה ותיקון"/>
                <DockPanel Style="{StaticResource Row}">
                  <TextBlock Style="{StaticResource Label}" Text="כונן:"/>
                  <ComboBox x:Name="FxDrive" Width="360"/>
                </DockPanel>
                <RadioButton x:Name="FxScan" GroupName="fx" Content="בדיקה בלבד - בטוח, בלי לשנות כלום" IsChecked="True"/>
                <RadioButton x:Name="FxRepair" GroupName="fx" Content="תיקון שגיאות במערכת הקבצים"/>
                <RadioButton x:Name="FxDeep" GroupName="fx" Content="תיקון + איתור סקטורים פגומים (איטי מאוד, יכול לקחת שעות)"/>
                <Border Style="{StaticResource Warn}" Margin="0,12,0,0">
                  <TextBlock TextWrapping="Wrap" Foreground="#991B1B" Text="אם יש על הכונן קבצים חשובים שעוד לא גובו - קודם העתיקו אותם ('העתקה מכונן פגום'). תיקון של כונן פגום פיזית עלול להעלים קבצים."/>
                </Border>
                <StackPanel Orientation="Horizontal" Margin="0,4,0,0">
                  <Button x:Name="FxStart" Style="{StaticResource Btn}" Content="התחל" Padding="40,10"/>
                </StackPanel>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>
      </Grid>

      <!-- ===== פירוט ===== -->
      <Border x:Name="DetailsPanel" Grid.Row="1" Style="{StaticResource Card}" Margin="22,0,22,10" Padding="10" Visibility="Collapsed">
        <TextBox x:Name="LogBox" Height="170" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"
                 BorderThickness="0" FontSize="12.5" Background="White"/>
      </Border>

      <!-- ===== שורת מצב ===== -->
      <Border Grid.Row="2" Style="{StaticResource Card}" Margin="22,0,22,18" Padding="22,14">
        <StackPanel>
          <DockPanel LastChildFill="True">
            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
              <Button x:Name="DetailsBtn" Style="{StaticResource Btn2}" Content="הצגת פירוט"/>
              <Button x:Name="StopBtn" Style="{StaticResource BtnDanger}" Content="עצירה" IsEnabled="False" Margin="0"/>
            </StackPanel>
            <StackPanel VerticalAlignment="Center">
              <TextBlock x:Name="StatusText" Text="מוכן" FontWeight="Bold" TextTrimming="CharacterEllipsis"/>
              <TextBlock x:Name="StatusSub" Foreground="{StaticResource Muted}" FontSize="12.5" TextTrimming="CharacterEllipsis" Visibility="Collapsed"/>
            </StackPanel>
          </DockPanel>
          <ProgressBar x:Name="Progress" Style="{StaticResource Bar}" Margin="0,12,0,0" Value="0"/>
        </StackPanel>
      </Border>
    </Grid>
  </Grid>
</Window>
'@
try {
    $script:win = [Windows.Markup.XamlReader]::Parse($xaml)
} catch {
    Show-Error ("טעינת החלון נכשלה:`n" + $_.Exception.Message)
    exit 1
}
$win = $script:win
$ui = @{}
foreach ($m in [regex]::Matches($xaml, 'x:Name="(\w+)"')) {
    $n = $m.Groups[1].Value
    $el = $win.FindName($n)
    if ($el) { $ui[$n] = $el }
}
$ui.VersionText.Text = "גרסה $AppVersion"
if (-not $isAdmin) { $win.Title = "$AppName  (ללא הרשאות מנהל – חלק מהכלים לא יעבדו)" }

# שגיאה לא צפויה באחד הכפתורים לא תסגור את התוכנה
$win.Dispatcher.Add_UnhandledException({
    param($s, $e)
    $e.Handled = $true
    Show-Error ("אירעה שגיאה:`n" + $e.Exception.Message)
})

# ---------- עזרים ----------
function Select-Folder([string]$description, [string]$start) {
    $dlg = New-Object Windows.Forms.FolderBrowserDialog
    $dlg.Description = $description
    $dlg.ShowNewFolderButton = $true
    if ($start -and (Test-Path -LiteralPath $start)) { $dlg.SelectedPath = $start }
    if ($dlg.ShowDialog() -eq 'OK') { return $dlg.SelectedPath }
    return $null
}

function Select-Files([string]$filter, [switch]$Single) {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Multiselect = -not $Single
    $dlg.Filter = $filter
    if ($dlg.ShowDialog($win)) { return @($dlg.FileNames) }
    return @()
}

function Open-Path([string]$path) {
    if ($path -and (Test-Path -LiteralPath $path)) { Start-Process explorer.exe "`"$path`"" }
}

function Show-InFolder([string]$file) {
    Start-Process explorer.exe "/select,`"$file`""
}

function Get-DriveChoices {
    foreach ($d in [IO.DriveInfo]::GetDrives()) {
        try { if (-not $d.IsReady) { continue } } catch { continue }
        if ($d.DriveType -ne 'Fixed' -and $d.DriveType -ne 'Removable') { continue }
        $label = if ($d.VolumeLabel) { $d.VolumeLabel } else { 'כונן' }
        [pscustomobject]@{
            Letter = $d.Name.Substring(0, 1)
            Root   = $d.Name
            Format = $d.DriveFormat
            Size   = $d.TotalSize
            Free   = $d.AvailableFreeSpace
            Text   = "{0}  {1}  ({2}, {3}, פנוי {4})" -f $d.Name.Substring(0, 2), $label, $d.DriveFormat, (Format-Size $d.TotalSize), (Format-Size $d.AvailableFreeSpace)
        }
    }
}

function Fill-Drives($combo) {
    $combo.Items.Clear()
    foreach ($d in $script:drives) { [void]$combo.Items.Add($d.Text) }
    if ($combo.Items.Count -gt 0) { $combo.SelectedIndex = 0 }
}

function Get-SelectedDrive($combo) {
    if ($combo.SelectedIndex -lt 0) { return $null }
    return $script:drives[$combo.SelectedIndex]
}

# תיקייה מומלצת לשמירה – על כונן אחר מזה שממנו משחזרים
function Get-DefaultOutput([string]$exceptLetter, [string]$name = 'קבצים משוחזרים') {
    foreach ($d in $script:drives) {
        if ($d.Letter -ne $exceptLetter) { return (Join-Path $d.Root $name) }
    }
    return (Join-Path ([Environment]::GetFolderPath('Desktop')) $name)
}

function Get-DownloadsFolder {
    try {
        $p = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction Stop).'{374DE290-123F-4565-9164-39C4925E467B}'
        if ($p) { return [Environment]::ExpandEnvironmentVariables($p) }
    } catch { }
    return (Join-Path $env:USERPROFILE 'Downloads')
}

function Test-SameDrive([string]$a, [string]$b) {
    if (-not $a -or -not $b -or $a.StartsWith('\\') -or $b.StartsWith('\\')) { return $false }
    return $a.Substring(0, 1).ToUpper() -eq $b.Substring(0, 1).ToUpper()
}

$script:drives = @(Get-DriveChoices)

# ---------- ניווט ----------
$pages = 'Home', 'Recover', 'Convert', 'Transfer', 'Bin', 'Versions', 'Unsaved', 'Search', 'Deep', 'Salvage', 'Image', 'Fix'
$script:onShow = @{}
function Show-Page([string]$name) {
    # סימון הפריט בתפריט מפעיל שוב את Show-Page דרך האירוע Checked
    if (-not $ui["N_$name"].IsChecked) { $ui["N_$name"].IsChecked = $true; return }
    foreach ($p in $pages) {
        $ui["P_$p"].Visibility = if ($p -eq $name) { 'Visible' } else { 'Collapsed' }
    }
    $ui["P_$name"].ScrollToTop()
    if ($script:onShow.ContainsKey($name)) { & $script:onShow[$name] }
}
foreach ($p in $pages) {
    $ui["N_$p"].Tag = $p
    $ui["N_$p"].Add_Checked({ param($s, $e) Show-Page $s.Tag })
}
$ui.HomeRecover.Add_Click({ Show-Page 'Recover' })
$ui.HomeConvert.Add_Click({ Show-Page 'Convert' })
$ui.HomeTransfer.Add_Click({ Show-Page 'Transfer' })
foreach ($p in 'Bin', 'Versions', 'Unsaved', 'Search', 'Deep', 'Salvage', 'Image', 'Fix') {
    $ui["T_$p"].Tag = $p
    $ui["T_$p"].Add_Click({ param($s, $e) Show-Page $s.Tag })
}
foreach ($p in 'Bin', 'Versions', 'Unsaved', 'Search', 'Deep') {
    $ui["R_$p"].Tag = $p
    $ui["R_$p"].Add_Click({ param($s, $e) Show-Page $s.Tag })
}
$ui.R_Named.Add_Click({ $ui.NamedCard.BringIntoView() })

# ---------- פעולות ברקע + שורת המצב ----------
$script:task = $null
$script:logLines = New-Object System.Collections.Generic.List[string]

function Add-Log([string]$line) {
    $script:logLines.Add($line)
    if ($script:logLines.Count -gt 3000) { $script:logLines.RemoveRange(0, 500) }
    $script:logDirty = $true
}

function Test-Busy {
    if ($script:task) {
        Show-Info "כרגע רצה פעולה אחרת: $($script:task.Title).`nחכו שתסתיים, או לחצו 'עצירה'."
        return $true
    }
    return $false
}

function Test-Admin([string]$what) {
    if ($isAdmin) { return $true }
    Show-Error "$what דורש הרשאות מנהל.`nסגרו את התוכנה, הפעילו אותה שוב ואשרו את חלון ההרשאות."
    return $false
}

# Job: אובייקט Recovery.Job (או Scanner). Done מקבל את המשימה בסיום. Tick רץ בכל עדכון.
function Start-Work([string]$title, $job, [scriptblock]$done, [scriptblock]$tick, $data) {
    $script:task = @{ Title = $title; Job = $job; Done = $done; Tick = $tick; Data = $data; Started = Get-Date }
    Add-Log ''
    Add-Log "=== $title · $((Get-Date).ToString('HH:mm')) ==="
    $ui.StopBtn.IsEnabled = $true
    $ui.StatusText.Text = $title
    $ui.StatusSub.Text = 'מתחיל...'
    $ui.StatusSub.Visibility = 'Visible'
    $ui.Progress.IsIndeterminate = $true
    $job.Start()
    $script:timer.Start()
}

function Stop-Work {
    $t = $script:task
    if (-not $t) { return }
    if ($t.Job -is [Recovery.Job]) { $t.Job.Stop() } else { $t.Job.Cancel = $true }
    $ui.StatusSub.Text = 'עוצר...'
}

function Format-Eta($t, [int]$pm) {
    if ($pm -lt 15) { return '' }
    $el = ((Get-Date) - $t.Started).TotalSeconds
    if ($el -lt 10) { return '' }
    $left = [TimeSpan]::FromSeconds($el * (1000 - $pm) / $pm)
    if ($left.TotalMinutes -ge 60) { return ' · נותרו כ-{0:0.0} שעות' -f $left.TotalHours }
    if ($left.TotalMinutes -ge 1) { return ' · נותרו כ-{0:0} דקות' -f [Math]::Ceiling($left.TotalMinutes) }
    return ' · פחות מדקה'
}

$script:timer = New-Object System.Windows.Threading.DispatcherTimer
$script:timer.Interval = [TimeSpan]::FromMilliseconds(400)
$script:timer.Add_Tick({
    try {
        $t = $script:task
        if (-not $t) { $script:timer.Stop(); return }
        $j = $t.Job
        foreach ($l in $j.TakeLines()) { Add-Log $l }
        if ($j -is [Recovery.Job]) {
            $pm = $j.Permille
            $sub = $j.Status
        } else {
            $pm = if ($j.Total -gt 0) { [Math]::Min(1000, [int](1000.0 * $j.Position / $j.Total)) } else { -1 }
            $sub = "נמצאו {0} קבצים ({1})   {2}" -f $j.Found, (Format-Size $j.BytesRecovered), $j.Summary()
        }
        if ($pm -ge 0) {
            $ui.Progress.IsIndeterminate = $false
            $ui.Progress.Value = $pm
            $ui.StatusText.Text = "{0} · {1:0.0}%{2}" -f $t.Title, ($pm / 10.0), (Format-Eta $t $pm)
        } else {
            $ui.Progress.IsIndeterminate = $true
        }
        if ($sub) { $ui.StatusSub.Text = $sub }
        if ($t.Tick) { & $t.Tick $t }
        if (-not $j.Running) {
            foreach ($l in $j.TakeLines()) { Add-Log $l }
            $script:task = $null
            $script:timer.Stop()
            $ui.StopBtn.IsEnabled = $false
            $ui.Progress.IsIndeterminate = $false
            $cancelled = [bool]$j.Cancel
            if ($j.Error) {
                $ui.StatusText.Text = "$($t.Title) – נעצר בגלל שגיאה"
                $ui.StatusSub.Text = $j.Error
            } elseif ($cancelled) {
                $ui.StatusText.Text = "$($t.Title) – נעצר"
            } else {
                $ui.Progress.Value = 1000
                $ui.StatusText.Text = "$($t.Title) – הסתיים"
            }
            Update-LogBox
            $t.Cancelled = $cancelled
            if ($t.Done) { & $t.Done $t }
        }
        Update-LogBox
    } catch {
        Add-Log ('שגיאה בממשק: ' + $_.Exception.Message)
    }
})

function Update-LogBox {
    if (-not $script:logDirty -or $ui.DetailsPanel.Visibility -ne 'Visible') { return }
    $script:logDirty = $false
    $ui.LogBox.Text = [string]::Join("`r`n", $script:logLines)
    $ui.LogBox.ScrollToEnd()
}

$ui.StopBtn.Add_Click({ Stop-Work })
$ui.DetailsBtn.Add_Click({
    if ($ui.DetailsPanel.Visibility -eq 'Visible') {
        $ui.DetailsPanel.Visibility = 'Collapsed'
        $ui.DetailsBtn.Content = 'הצגת פירוט'
    } else {
        $ui.DetailsPanel.Visibility = 'Visible'
        $ui.DetailsBtn.Content = 'הסתרת פירוט'
        $script:logDirty = $true
        Update-LogBox
    }
})

function New-ProcessJob { New-Object Recovery.ProcessJob }
function Add-Step($pj, [string]$file, [string]$argList, [string]$label, [switch]$Utf8, [string]$StdIn) {
    $s = New-Object Recovery.ProcessStep
    $s.File = $file; $s.Args = $argList; $s.Label = $label; $s.Utf8 = [bool]$Utf8
    if ($StdIn) { $s.Input = $StdIn }
    $pj.Steps.Add($s)
}

# =====================================================================
# סל המיחזור
# =====================================================================
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
        try { if (-not $d.IsReady) { continue } } catch { continue }
        $bin = Join-Path $d.RootDirectory.FullName ('$Recycle.Bin\' + $sid)
        if (-not [IO.Directory]::Exists($bin)) { continue }
        foreach ($i in [IO.Directory]::GetFiles($bin, '$I*')) {
            $r = Join-Path $bin ('$R' + [IO.Path]::GetFileName($i).Substring(2))
            $isDir = [IO.Directory]::Exists($r)
            if (-not $isDir -and -not [IO.File]::Exists($r)) { continue }
            try { $info = Read-RecycleInfo $i } catch { continue }
            if (-not $info -or -not $info.Original) { continue }
            $nm = [IO.Path]::GetFileName($info.Original)
            $items.Add([pscustomobject]@{
                Name     = if ($isDir) { "📁 $nm" } else { $nm }
                FileName = $nm
                Original = $info.Original
                Folder   = [IO.Path]::GetDirectoryName($info.Original)
                Deleted  = $info.Deleted
                DateText = $info.Deleted.ToString('dd/MM/yyyy HH:mm')
                SizeText = if ($isDir) { 'תיקייה' } else { Format-Size $info.Size }
                IsFolder = $isDir
                IFile    = $i
                RFile    = $r
            })
        }
    }
    return @($items | Sort-Object Deleted -Descending)
}

function Get-FreeName([string]$path) { [Recovery.Job]::FreeName($path) }

function Load-Bin {
    $filter = $ui.BinFilter.Text.Trim()
    try { $all = Get-RecycleItems } catch { $all = @() }
    $shown = @($all | Where-Object { -not $filter -or $_.Original -like "*$filter*" })
    $ui.BinList.ItemsSource = $shown
    $ui.BinCount.Text = if ($filter) { "$($shown.Count) מתוך $($all.Count) פריטים" } else { "$($all.Count) פריטים בסל המיחזור" }
}
$script:onShow['Bin'] = { Load-Bin }
$ui.BinRefresh.Add_Click({ Load-Bin })
$ui.BinFilter.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { Load-Bin } })
$ui.BinAll.Add_Click({ $ui.BinList.SelectAll(); $ui.BinList.Focus() })

$ui.BinRestore.Add_Click({
    $sel = @($ui.BinList.SelectedItems)
    if ($sel.Count -eq 0) { Show-Info 'בחרו ברשימה את הקבצים שברצונכם לשחזר.'; return }
    $ok = 0; $errs = @()
    foreach ($it in $sel) {
        try {
            $target = Get-FreeName $it.Original
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
            if ($it.IsFolder) { [IO.Directory]::Move($it.RFile, $target) } else { [IO.File]::Move($it.RFile, $target) }
            try { [IO.File]::Delete($it.IFile) } catch { }
            Add-Log "שוחזר: $target"
            $ok++
        } catch { $errs += "$($it.FileName): $($_.Exception.Message)" }
    }
    Load-Bin
    $msg = "שוחזרו $ok פריטים למקומם המקורי."
    if ($errs) { $msg += "`n`nלא הצליח:`n" + ($errs -join "`n") }
    Show-Info $msg
})

$ui.BinCopy.Add_Click({
    $sel = @($ui.BinList.SelectedItems)
    if ($sel.Count -eq 0) { Show-Info 'בחרו ברשימה את הקבצים שברצונכם להעתיק.'; return }
    $folder = Select-Folder 'לאן להעתיק את הקבצים?'
    if (-not $folder) { return }
    $ok = 0; $errs = @()
    foreach ($it in $sel) {
        try {
            $target = Get-FreeName (Join-Path $folder $it.FileName)
            if ($it.IsFolder) { Copy-Item -LiteralPath $it.RFile -Destination $target -Recurse } else { [IO.File]::Copy($it.RFile, $target) }
            $ok++
        } catch { $errs += "$($it.FileName): $($_.Exception.Message)" }
    }
    $msg = "הועתקו $ok פריטים אל:`n$folder"
    if ($errs) { $msg += "`n`nלא הצליח:`n" + ($errs -join "`n") }
    Show-Info $msg
    Open-Path $folder
})

# =====================================================================
# שחזור עם שמות (Windows File Recovery של מיקרוסופט)
# =====================================================================
function Update-Winfr {
    $script:winfr = Get-Command winfr.exe -ErrorAction SilentlyContinue
    if ($script:winfr) {
        $ui.WinfrStatus.Text = '✔ הכלי מותקן ומוכן.'
        $ui.WinfrStatus.Foreground = Get-Brush '#047857'
        $ui.WinfrInstallPanel.Visibility = 'Collapsed'
        $ui.WinfrForm.IsEnabled = $true
    } else {
        $ui.WinfrStatus.Text = 'הכלי עדיין לא מותקן. לחצו "התקנת הכלי" (מ-Microsoft Store, חינם), ואחרי ההתקנה - "בדוק שוב".'
        $ui.WinfrStatus.Foreground = Get-Brush '#B45309'
        $ui.WinfrInstallPanel.Visibility = 'Visible'
        $ui.WinfrForm.IsEnabled = $false
    }
}
Fill-Drives $ui.WinfrDrive
$ui.WinfrDrive.Add_SelectionChanged({
    $d = Get-SelectedDrive $ui.WinfrDrive
    if ($d) { $ui.WinfrDest.Text = Get-DefaultOutput $d.Letter }
})
if ($script:drives.Count -gt 0) { $ui.WinfrDest.Text = Get-DefaultOutput $script:drives[0].Letter }
$script:onShow['Recover'] = { Update-Winfr }
$ui.WinfrRecheck.Add_Click({ Update-Winfr })
$ui.WinfrInstall.Add_Click({ Start-Process 'ms-windows-store://pdp/?productid=9N26S50LN705' })
$ui.WinfrBrowse.Add_Click({ $f = Select-Folder 'בחרו תיקייה בכונן אחר'; if ($f) { $ui.WinfrDest.Text = $f } })
$ui.WinfrOpen.Add_Click({ Open-Path $ui.WinfrDest.Text.Trim() })
$ui.WinfrStart.Add_Click({
    $d = Get-SelectedDrive $ui.WinfrDrive
    if (-not $d) { return }
    $dest = $ui.WinfrDest.Text.Trim()
    if (-not $dest -or -not [IO.Path]::IsPathRooted($dest)) { Show-Error 'בחרו תיקייה לשמירת הקבצים.'; return }
    if (Test-SameDrive $dest $d.Root) { Show-Error 'התיקייה חייבת להיות בכונן אחר מהכונן שממנו משחזרים.'; return }
    [void][IO.Directory]::CreateDirectory($dest)
    $mode = if ($ui.WinfrExtensive.IsChecked) { '/extensive' } else { '/regular' }
    $argList = "$($d.Letter): `"$($dest.TrimEnd('\'))`" $mode"
    foreach ($f in $ui.WinfrFilter.Text.Split(';')) {
        if ($f.Trim()) { $argList += " /n `"$($f.Trim())`"" }
    }
    Show-Info 'ייפתח חלון שחור של הכלי של מיקרוסופט. הקלידו Y ולחצו Enter כדי להתחיל. בסוף הוא ישאל אם לפתוח את התיקייה.'
    Start-Process -FilePath $script:winfr.Source -ArgumentList $argList
})

# =====================================================================
# המרת קבצים
# =====================================================================
$ImageExt = 'jpg', 'jpeg', 'jfif', 'png', 'bmp', 'gif', 'tif', 'tiff', 'ico', 'heic', 'heif', 'webp', 'avif', 'jxr', 'wdp', 'dng', 'cr2', 'nef', 'arw'
$MediaExt = 'mp4', 'mkv', 'avi', 'mov', 'wmv', 'webm', 'flv', 'm4v', '3gp', 'mpg', 'mpeg', 'ts', 'mts', 'm2ts', 'vob',
            'mp3', 'wav', 'm4a', 'aac', 'flac', 'ogg', 'oga', 'opus', 'wma', 'amr', 'aiff', 'gif'
$DocExt = 'doc', 'docx', 'docm', 'dot', 'dotx', 'rtf', 'odt', 'txt', 'htm', 'html', 'mht', 'wps', 'pdf', 'xml',
          'xls', 'xlsx', 'xlsm', 'xlsb', 'csv', 'ods', 'ppt', 'pptx', 'pptm', 'pps', 'ppsx', 'odp'

$ConvFormats = @{
    Images = @(
        @('jpg', 'JPG - תמונה רגילה, קובץ קטן'), @('png', 'PNG - איכות מלאה, תומך שקיפות'), @('pdf', 'PDF - מסמך מהתמונות'),
        @('bmp', 'BMP'), @('gif', 'GIF'), @('tiff', 'TIFF - להדפסה'), @('ico', 'ICO - סמל (אייקון)'))
    Media  = @(
        @('mp4', 'MP4 - וידאו (מתאים לכל מכשיר)'), @('mp3', 'MP3 - שמע בלבד'), @('m4a', 'M4A - שמע (AAC)'), @('wav', 'WAV - שמע ללא דחיסה'),
        @('flac', 'FLAC - שמע באיכות מלאה'), @('ogg', 'OGG - שמע'), @('mkv', 'MKV - וידאו'), @('mov', 'MOV - וידאו (אפל)'),
        @('avi', 'AVI - וידאו (מכשירים ישנים)'), @('webm', 'WEBM - וידאו לאתרים'), @('gif', 'GIF - הנפשה מתוך וידאו'))
    Docs   = @(
        @('pdf', 'PDF'), @('docx', 'DOCX - Word'), @('doc', 'DOC - Word ישן'), @('rtf', 'RTF'), @('txt', 'TXT - טקסט בלבד'),
        @('odt', 'ODT - OpenDocument'), @('html', 'HTML - דף אינטרנט'), @('xlsx', 'XLSX - Excel'), @('xls', 'XLS - Excel ישן'),
        @('csv', 'CSV - טבלה כטקסט'), @('ods', 'ODS - גיליון OpenDocument'), @('pptx', 'PPTX - PowerPoint'), @('ppt', 'PPT - PowerPoint ישן'),
        @('odp', 'ODP - מצגת OpenDocument'))
}
$script:cvMode = 'Images'

foreach ($q in @(@(95, 'גבוהה מאוד'), @(90, 'גבוהה (מומלץ)'), @(80, 'רגילה - קובץ קטן יותר'), @(65, 'נמוכה - קובץ קטן מאוד'))) {
    $it = New-Object Windows.Controls.ComboBoxItem; $it.Content = $q[1]; $it.Tag = $q[0]; [void]$ui.CvQuality.Items.Add($it)
}
$ui.CvQuality.SelectedIndex = 1
foreach ($q in @(@(0, 'בלי שינוי'), @(3840, 'עד 3840 פיקסלים (4K)'), @(1920, 'עד 1920 פיקסלים (Full HD)'), @(1280, 'עד 1280 פיקסלים (לשליחה במייל)'), @(800, 'עד 800 פיקסלים (קטן)'))) {
    $it = New-Object Windows.Controls.ComboBoxItem; $it.Content = $q[1]; $it.Tag = $q[0]; [void]$ui.CvResize.Items.Add($it)
}
$ui.CvResize.SelectedIndex = 0
foreach ($q in @(@('same', 'רגילה (מומלץ)'), @('high', 'גבוהה - קובץ גדול יותר'), @('small', 'קובץ קטן - לשליחה ולוואטסאפ'))) {
    $it = New-Object Windows.Controls.ComboBoxItem; $it.Content = $q[1]; $it.Tag = $q[0]; [void]$ui.CvMediaQuality.Items.Add($it)
}
$ui.CvMediaQuality.SelectedIndex = 0

function Find-FFmpeg {
    $c = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $cands = @(
        (Join-Path $AppDir 'ffmpeg.exe'), (Join-Path $AppDir 'ffmpeg\bin\ffmpeg.exe'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\ffmpeg.exe'))
    foreach ($p in $cands) { if (Test-Path -LiteralPath $p) { return $p } }
    $pk = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    if (Test-Path -LiteralPath $pk) {
        $f = Get-ChildItem -LiteralPath $pk -Filter 'ffmpeg.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($f) { return $f.FullName }
    }
    return $null
}

function Find-LibreOffice {
    foreach ($p in @("$env:ProgramFiles\LibreOffice\program\soffice.exe", "${env:ProgramFiles(x86)}\LibreOffice\program\soffice.exe")) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    return $null
}

function Test-Office { Test-Path 'Registry::HKEY_CLASSES_ROOT\Word.Application' }

function Update-ConvertTools {
    $ui.CvToolInstall.Visibility = 'Collapsed'
    switch ($script:cvMode) {
        'Images' {
            $ui.CvToolText.Text = 'אפשר להמיר גם תמונות HEIC מאייפון ו-WEBP. אם קובץ כזה לא נפתח - התקינו מ-Microsoft Store את "HEIF Image Extensions" / "Webp Image Extensions" (חינם).'
        }
        'Media' {
            $script:ffmpeg = Find-FFmpeg
            if ($script:ffmpeg) {
                $ui.CvToolText.Text = "✔ רכיב ההמרה FFmpeg מותקן ומוכן."
            } else {
                $ui.CvToolText.Text = 'להמרת שמע ווידאו צריך את הרכיב החינמי FFmpeg. לחצו "התקנה" (דרך winget של Windows, כמה דקות), או שימו ffmpeg.exe ליד התוכנה.'
                $ui.CvToolInstall.Visibility = 'Visible'
            }
        }
        'Docs' {
            $script:hasOffice = Test-Office
            $script:soffice = Find-LibreOffice
            if ($script:hasOffice) {
                $ui.CvToolText.Text = '✔ Microsoft Office מותקן - ההמרה תתבצע דרכו (Word, Excel, PowerPoint). אפשר גם PDF ל-Word.'
            } elseif ($script:soffice) {
                $ui.CvToolText.Text = '✔ LibreOffice מותקן - ההמרה תתבצע דרכו.'
            } else {
                $ui.CvToolText.Text = 'להמרת מסמכים צריך Microsoft Office או את LibreOffice החינמי. לחצו "התקנה" כדי להתקין את LibreOffice (דרך winget).'
                $ui.CvToolInstall.Visibility = 'Visible'
            }
        }
    }
}

function Set-ConvertMode([string]$mode) {
    $script:cvMode = $mode
    $ui.CvFormat.Items.Clear()
    foreach ($f in $ConvFormats[$mode]) {
        $it = New-Object Windows.Controls.ComboBoxItem; $it.Content = $f[1]; $it.Tag = $f[0]
        [void]$ui.CvFormat.Items.Add($it)
    }
    $ui.CvFormat.SelectedIndex = 0
    $ui.CvImgOptions.Visibility = if ($mode -eq 'Images') { 'Visible' } else { 'Collapsed' }
    $ui.CvMediaOptions.Visibility = if ($mode -eq 'Media') { 'Visible' } else { 'Collapsed' }
    $ui.CvHint.Text = switch ($mode) {
        'Images' { 'נתמכים: JPG, PNG, HEIC (אייפון), WEBP, BMP, GIF, TIFF, ICO ועוד.' }
        'Media' { 'נתמכים: MP4, MOV, AVI, MKV, WMV, WEBM, MP3, WAV, M4A, FLAC, OGG, WMA, AMR ועוד. אפשר לחלץ שמע מתוך וידאו.' }
        'Docs' { 'נתמכים: Word, Excel, PowerPoint, PDF, ODT/ODS/ODP, RTF, TXT, CSV. תמונות ל-PDF - בלשונית "תמונות".' }
    }
    $ui.CvList.Items.Clear()
    Update-CvCount
    Update-ConvertTools
}

function Update-CvCount { $ui.CvCount.Text = if ($ui.CvList.Items.Count) { "$($ui.CvList.Items.Count) קבצים" } else { '' } }

function Add-ConvertFiles($paths) {
    $exts = switch ($script:cvMode) { 'Images' { $ImageExt } 'Media' { $MediaExt } 'Docs' { $DocExt } }
    $skipped = 0
    foreach ($p in $paths) {
        $list = if (Test-Path -LiteralPath $p -PathType Container) {
            @(Get-ChildItem -LiteralPath $p -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
        } else { @($p) }
        foreach ($f in $list) {
            $e = [IO.Path]::GetExtension($f).TrimStart('.').ToLower()
            if ($exts -notcontains $e) { $skipped++; continue }
            if (-not $ui.CvList.Items.Contains($f)) { [void]$ui.CvList.Items.Add($f) }
        }
    }
    Update-CvCount
    if ($skipped -gt 0) { Add-Log "דולגו $skipped קבצים שאינם מהסוג שנבחר." }
}

$ui.CvImages.Add_Checked({ Set-ConvertMode 'Images' })
$ui.CvMedia.Add_Checked({ Set-ConvertMode 'Media' })
$ui.CvDocs.Add_Checked({ Set-ConvertMode 'Docs' })
$ui.CvAddFiles.Add_Click({
    $filter = switch ($script:cvMode) {
        'Images' { 'תמונות|' + (($ImageExt | ForEach-Object { "*.$_" }) -join ';') }
        'Media' { 'שמע ווידאו|' + (($MediaExt | ForEach-Object { "*.$_" }) -join ';') }
        'Docs' { 'מסמכים|' + (($DocExt | ForEach-Object { "*.$_" }) -join ';') }
    }
    Add-ConvertFiles (Select-Files ($filter + '|כל הקבצים|*.*'))
})
$ui.CvAddFolder.Add_Click({ $f = Select-Folder 'בחרו תיקייה - כל הקבצים המתאימים בה יתווספו'; if ($f) { Add-ConvertFiles @($f) } })
$ui.CvRemove.Add_Click({ foreach ($i in @($ui.CvList.SelectedItems)) { $ui.CvList.Items.Remove($i) }; Update-CvCount })
$ui.CvClear.Add_Click({ $ui.CvList.Items.Clear(); Update-CvCount })
$ui.CvList.Add_DragOver({ param($s, $e) $e.Effects = 'Copy'; $e.Handled = $true })
$ui.CvList.Add_Drop({ param($s, $e) if ($e.Data.GetDataPresent('FileDrop')) { Add-ConvertFiles @($e.Data.GetData('FileDrop')) } })
$ui.CvBrowse.Add_Click({ $f = Select-Folder 'לאן לשמור את הקבצים המומרים?'; if ($f) { $ui.CvOut.Text = $f; $ui.CvOtherFolder.IsChecked = $true } })
$ui.CvOut.Add_GotFocus({ $ui.CvOtherFolder.IsChecked = $true })
$ui.CvOut.Text = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'קבצים מומרים'
$ui.CvOpen.Add_Click({ Open-Path $script:cvLastFolder })
$script:onShow['Convert'] = { Update-ConvertTools }

$ui.CvToolInstall.Add_Click({
    if (Test-Busy) { return }
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        if ($script:cvMode -eq 'Media') { Start-Process 'https://www.gyan.dev/ffmpeg/builds/' } else { Start-Process 'https://he.libreoffice.org/download/download/' }
        Show-Info 'ההתקנה האוטומטית לא זמינה במחשב הזה (חסר winget). נפתח אתר ההורדה.'
        return
    }
    $pj = New-ProcessJob
    if ($script:cvMode -eq 'Media') {
        Add-Step $pj 'winget.exe' 'install --id Gyan.FFmpeg -e --accept-source-agreements --accept-package-agreements' 'מתקין את FFmpeg' -Utf8
    } else {
        Add-Step $pj 'winget.exe' 'install --id TheDocumentFoundation.LibreOffice -e --accept-source-agreements --accept-package-agreements' 'מתקין את LibreOffice' -Utf8
    }
    Start-Work 'התקנת רכיב' $pj {
        param($t)
        Update-ConvertTools
        if ($ui.CvToolInstall.Visibility -eq 'Collapsed') { Show-Info 'ההתקנה הסתיימה. אפשר להמיר.' }
        elseif (-not $t.Cancelled) { Show-Error 'ההתקנה לא הצליחה. פתחו "הצגת פירוט" כדי לראות מה קרה.' }
    }
})

function Get-FFmpegArgs([string]$src, [string]$dst, [string]$fmt, [string]$q) {
    $crf = @{ same = 23; high = 18; small = 28 }[$q]
    $scale = if ($q -eq 'small') { ' -vf "scale=''min(1280,iw)'':-2"' } else { '' }
    $ab = @{ same = '192k'; high = '320k'; small = '128k' }[$q]
    $a = switch ($fmt) {
        'mp4' { "-c:v libx264 -preset medium -crf $crf$scale -pix_fmt yuv420p -c:a aac -b:a $ab -movflags +faststart" }
        'mkv' { "-c:v libx264 -preset medium -crf $crf$scale -c:a aac -b:a $ab" }
        'mov' { "-c:v libx264 -preset medium -crf $crf$scale -pix_fmt yuv420p -c:a aac -b:a $ab" }
        'avi' { "-c:v mpeg4 -q:v $(@{ same = 4; high = 2; small = 7 }[$q])$scale -c:a libmp3lame -b:a $ab" }
        'webm' { "-c:v libvpx-vp9 -crf $($crf + 9) -b:v 0$scale -c:a libopus -b:a 128k" }
        'gif' { '-vf "fps=12,scale=''min(640,iw)'':-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse" -loop 0 -an' }
        'mp3' { "-vn -c:a libmp3lame -b:a $ab" }
        'm4a' { "-vn -c:a aac -b:a $ab" }
        'wav' { '-vn -c:a pcm_s16le' }
        'flac' { '-vn -c:a flac' }
        'ogg' { "-vn -c:a libvorbis -q:a $(@{ same = 5; high = 8; small = 3 }[$q])" }
    }
    return "-hide_banner -nostdin -y -i `"$src`" $a `"$dst`""
}

$ui.CvStart.Add_Click({
    if (Test-Busy) { return }
    $files = @($ui.CvList.Items | ForEach-Object { [string]$_ })
    if ($files.Count -eq 0) { Show-Info 'הוסיפו קודם קבצים להמרה (כפתור "הוספת קבצים", או גרירה לרשימה).'; return }
    $fmt = [string]$ui.CvFormat.SelectedItem.Tag
    $outDir = $null
    if ($ui.CvOtherFolder.IsChecked) {
        $outDir = $ui.CvOut.Text.Trim()
        if (-not $outDir -or -not [IO.Path]::IsPathRooted($outDir)) { Show-Error 'בחרו תיקייה לשמירה.'; return }
        [void][IO.Directory]::CreateDirectory($outDir)
    }
    $script:cvLastFolder = if ($outDir) { $outDir } else { [IO.Path]::GetDirectoryName($files[0]) }
    $ui.CvOpen.IsEnabled = $true
    $onDone = {
        param($t)
        if ($t.Cancelled) { return }
        $j = $t.Job
        $failed = if ($j -is [Recovery.ImageConvertJob]) { $j.Failed } else { $j.FailedSteps }
        if ($failed -gt 0) {
            Show-Error "ההמרה הסתיימה, אבל $failed קבצים לא הומרו.`nלחצו 'הצגת פירוט' כדי לראות למה."
        } elseif (Ask "ההמרה הסתיימה בהצלחה!`nלפתוח את התיקייה?") { Open-Path $script:cvLastFolder }
    }

    switch ($script:cvMode) {
        'Images' {
            $j = New-Object Recovery.ImageConvertJob
            foreach ($f in $files) { $j.Files.Add($f) }
            $j.Format = $fmt
            $j.OutputFolder = $outDir
            $j.Quality = [int]$ui.CvQuality.SelectedItem.Tag
            $j.MaxSide = [int]$ui.CvResize.SelectedItem.Tag
            $j.SinglePdf = [bool]$ui.CvSinglePdf.IsChecked
            $j.PdfName = [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($files[0]))
            if (-not $j.PdfName) { $j.PdfName = 'תמונות' }
            Start-Work "המרת $($files.Count) תמונות ל-$($fmt.ToUpper())" $j $onDone
        }
        'Media' {
            $script:ffmpeg = Find-FFmpeg
            if (-not $script:ffmpeg) { Show-Info 'צריך קודם להתקין את FFmpeg - לחצו על "התקנה" בחלק 2.'; return }
            $q = [string]$ui.CvMediaQuality.SelectedItem.Tag
            $pj = New-ProcessJob
            foreach ($f in $files) {
                $dir = if ($outDir) { $outDir } else { [IO.Path]::GetDirectoryName($f) }
                $dst = Get-FreeName (Join-Path $dir ([IO.Path]::GetFileNameWithoutExtension($f) + ".$fmt"))
                Add-Step $pj $script:ffmpeg (Get-FFmpegArgs $f $dst $fmt $q) ([IO.Path]::GetFileName($f) + ' ← ' + [IO.Path]::GetFileName($dst)) -Utf8
            }
            Start-Work "המרת $($files.Count) קבצים ל-$($fmt.ToUpper())" $pj $onDone
        }
        'Docs' {
            $hasOffice = Test-Office
            $lo = Find-LibreOffice
            if (-not $hasOffice -and -not $lo) { Show-Info 'צריך Microsoft Office או LibreOffice כדי להמיר מסמכים - לחצו "התקנה" בחלק 2.'; return }
            $scriptPath = Join-Path $WorkDir 'office-convert.ps1'
            [IO.File]::WriteAllText($scriptPath, $OfficeScript, (New-Object Text.UTF8Encoding($true)))
            $jobFile = Join-Path $WorkDir 'office-job.json'
            $spec = @{ Files = $files; Format = $fmt; OutputFolder = $outDir; UseOffice = $hasOffice; LibreOffice = $lo }
            [IO.File]::WriteAllText($jobFile, ($spec | ConvertTo-Json -Depth 3), (New-Object Text.UTF8Encoding($true)))
            $pj = New-ProcessJob
            Add-Step $pj 'powershell.exe' "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" `"$jobFile`"" 'ממיר מסמכים' -Utf8
            Start-Work "המרת $($files.Count) מסמכים ל-$($fmt.ToUpper())" $pj $onDone
        }
    }
})

# =====================================================================
# העברה ממחשב למחשב
# =====================================================================
$KnownFolders = [ordered]@{
    Desktop   = @{ Name = 'שולחן העבודה'; Box = 'TrDesktop'; Path = { [Environment]::GetFolderPath('Desktop') } }
    Documents = @{ Name = 'מסמכים'; Box = 'TrDocuments'; Path = { [Environment]::GetFolderPath('MyDocuments') } }
    Pictures  = @{ Name = 'תמונות'; Box = 'TrPictures'; Path = { [Environment]::GetFolderPath('MyPictures') } }
    Videos    = @{ Name = 'סרטונים'; Box = 'TrVideos'; Path = { [Environment]::GetFolderPath('MyVideos') } }
    Music     = @{ Name = 'מוזיקה'; Box = 'TrMusic'; Path = { [Environment]::GetFolderPath('MyMusic') } }
    Downloads = @{ Name = 'הורדות'; Box = 'TrDownloads'; Path = { Get-DownloadsFolder } }
    Favorites = @{ Name = 'מועדפים'; Box = 'TrFavorites'; Path = { [Environment]::GetFolderPath('Favorites') } }
}

$ui.TrOld.Add_Checked({ $ui.TrOldPanel.Visibility = 'Visible'; $ui.TrNewPanel.Visibility = 'Collapsed' })
$ui.TrNew.Add_Checked({ $ui.TrOldPanel.Visibility = 'Collapsed'; $ui.TrNewPanel.Visibility = 'Visible' })
$ui.TrExtraAdd.Add_Click({ $f = Select-Folder 'בחרו תיקייה נוספת להעברה'; if ($f -and -not $ui.TrExtra.Items.Contains($f)) { [void]$ui.TrExtra.Items.Add($f) } })
$ui.TrExtraRemove.Add_Click({ foreach ($i in @($ui.TrExtra.SelectedItems)) { $ui.TrExtra.Items.Remove($i) } })
$ui.TrDestBrowse.Add_Click({ $f = Select-Folder 'בחרו את הדיסק החיצוני, או תיקייה משותפת ברשת'; if ($f) { $ui.TrDest.Text = $f } })
foreach ($d in $script:drives) {
    if ($d.Letter -ne $env:SystemDrive.Substring(0, 1)) { $ui.TrDest.Text = $d.Root; break }
}
$ui.TrPackOpen.Add_Click({ Open-Path $script:trPackRoot })

function Get-BrowserBookmarkFiles {
    $list = @()
    $roots = @(
        @('Chrome', (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data')),
        @('Edge', (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data')),
        @('Brave', (Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data')))
    foreach ($r in $roots) {
        if (-not (Test-Path -LiteralPath $r[1])) { continue }
        foreach ($prof in Get-ChildItem -LiteralPath $r[1] -Directory -ErrorAction SilentlyContinue) {
            $bm = Join-Path $prof.FullName 'Bookmarks'
            if (Test-Path -LiteralPath $bm) {
                $suffix = if ($prof.Name -eq 'Default') { '' } else { " - $($prof.Name)" }
                $list += [pscustomobject]@{ Browser = $r[0]; Name = "$($r[0])$suffix"; File = $bm }
            }
        }
    }
    return $list
}

# ממיר את קובץ הסימניות של Chrome/Edge לקובץ HTML סטנדרטי, שכל דפדפן יודע לייבא
function Convert-BookmarksToHtml([string]$jsonPath, [string]$htmlPath) {
    $j = [IO.File]::ReadAllText($jsonPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine('<!DOCTYPE NETSCAPE-Bookmark-file-1>')
    [void]$sb.AppendLine('<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">')
    [void]$sb.AppendLine('<TITLE>Bookmarks</TITLE><H1>Bookmarks</H1><DL><p>')
    $walk = {
        param($node)
        $nm = [Net.WebUtility]::HtmlEncode([string]$node.name)
        if ($node.type -eq 'folder') {
            [void]$sb.AppendLine("<DT><H3>$nm</H3><DL><p>")
            foreach ($c in @($node.children)) { if ($c) { & $walk $c } }
            [void]$sb.AppendLine('</DL><p>')
        } elseif ($node.url) {
            [void]$sb.AppendLine("<DT><A HREF=`"$([Net.WebUtility]::HtmlEncode([string]$node.url))`">$nm</A>")
        }
    }
    foreach ($k in 'bookmark_bar', 'other', 'synced') {
        $n = $j.roots.$k
        if ($n) { & $walk $n }
    }
    [void]$sb.AppendLine('</DL><p>')
    [IO.File]::WriteAllText($htmlPath, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
}

function Get-InstalledPrograms {
    $keys = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    Get-ItemProperty $keys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and -not $_.SystemComponent -and -not $_.ParentKeyName } |
        Sort-Object DisplayName -Unique |
        ForEach-Object { "{0}   {1}   {2}" -f $_.DisplayName, $_.DisplayVersion, $_.Publisher }
}

$ui.TrPack.Add_Click({
    if (Test-Busy) { return }
    $dest = $ui.TrDest.Text.Trim()
    if (-not $dest -or -not ([IO.Path]::IsPathRooted($dest))) { Show-Error 'בחרו לאן לשמור (דיסק חיצוני או תיקייה ברשת).'; return }
    if (-not (Test-Path -LiteralPath $dest)) {
        try { [void][IO.Directory]::CreateDirectory($dest) } catch { Show-Error "לא ניתן לגשת אל $dest"; return }
    }
    $root = Join-Path $dest ("העברת קבצים - $env:COMPUTERNAME - " + (Get-Date).ToString('yyyy-MM-dd'))
    $settings = Join-Path $root '_הגדרות'
    [void][IO.Directory]::CreateDirectory($settings)
    $manifest = [ordered]@{ App = $AppName; Version = $AppVersion; Computer = $env:COMPUTERNAME; User = $env:USERNAME; Date = (Get-Date).ToString('s'); Parts = @() }

    $cj = New-Object Recovery.CopyJob
    $cj.SkipIdentical = $true
    $cj.Overwrite = $true
    $cj.ReportPath = Join-Path $settings 'דוח העתקה.txt'
    $srcList = @()
    foreach ($k in $KnownFolders.Keys) {
        $kf = $KnownFolders[$k]
        if (-not $ui[$kf.Box].IsChecked) { continue }
        $src = & $kf.Path
        if (-not $src -or -not (Test-Path -LiteralPath $src)) { continue }
        $srcList += $src
        $cj.Add($src, (Join-Path $root $kf.Name))
        $manifest.Parts += [ordered]@{ Key = $k; Name = $kf.Name; Folder = $kf.Name; Source = $src }
    }
    $n = 0
    foreach ($x in @($ui.TrExtra.Items)) {
        $n++
        $leaf = Split-Path -Leaf $x
        if (-not $leaf) { $leaf = "כונן $($x.Substring(0,1))" }
        $folder = "תיקיות נוספות\$n - $leaf"
        $cj.Add($x, (Join-Path $root $folder))
        $manifest.Parts += [ordered]@{ Key = 'Extra'; Name = $leaf; Folder = $folder; Source = [string]$x }
    }
    foreach ($s in $srcList) {
        if ($dest.StartsWith($s, [StringComparison]::OrdinalIgnoreCase)) {
            Show-Error "תיקיית היעד נמצאת בתוך '$s' שמועברת. בחרו יעד אחר (דיסק חיצוני)."
            return
        }
    }

    # הגדרות מהירות – עכשיו
    if ($ui.TrBookmarks.IsChecked) {
        $bmDir = Join-Path $root 'סימניות'
        foreach ($b in Get-BrowserBookmarkFiles) {
            try {
                [void][IO.Directory]::CreateDirectory($bmDir)
                Convert-BookmarksToHtml $b.File (Join-Path $bmDir "$($b.Name).html")
                Copy-Item -LiteralPath $b.File -Destination (Join-Path $settings "Bookmarks-$($b.Name).json") -Force
                Add-Log "✓ סימניות $($b.Name)"
            } catch { Add-Log "✗ סימניות $($b.Name): $($_.Exception.Message)" }
        }
        if (Test-Path -LiteralPath $bmDir) { $manifest.Parts += [ordered]@{ Key = 'Bookmarks'; Name = 'סימניות'; Folder = 'סימניות' } }
    }
    $pj = New-ProcessJob
    if ($ui.TrApps.IsChecked) {
        try {
            [IO.File]::WriteAllLines((Join-Path $root 'רשימת התוכנות שהיו במחשב הישן.txt'), [string[]]@(Get-InstalledPrograms), [Text.Encoding]::UTF8)
        } catch { }
        if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
            Add-Step $pj 'winget.exe' "export -o `"$(Join-Path $settings 'apps.json')`" --accept-source-agreements" 'שומר את רשימת התוכנות' -Utf8
            $manifest.Parts += [ordered]@{ Key = 'Apps'; Name = 'תוכנות'; Folder = '_הגדרות\apps.json' }
        }
    }
    if ($ui.TrWifi.IsChecked) {
        $wifiDir = Join-Path $settings 'wifi'
        [void][IO.Directory]::CreateDirectory($wifiDir)
        Add-Step $pj 'netsh.exe' "wlan export profile key=clear folder=`"$wifiDir`"" 'שומר את רשתות ה-Wi-Fi'
        $manifest.Parts += [ordered]@{ Key = 'Wifi'; Name = 'רשתות Wi-Fi'; Folder = '_הגדרות\wifi' }
    }
    [IO.File]::WriteAllText((Join-Path $root 'manifest.json'), ($manifest | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
    $script:trPackRoot = $root
    $ui.TrPackOpen.IsEnabled = $true

    $afterCopy = {
        param($t)
        if ($t.Cancelled) { Show-Info "האריזה נעצרה. לחיצה חוזרת על 'התחל אריזה' תמשיך מאיפה שנעצר."; return }
        $cj = $t.Job
        $pj = $t.Data
        $finish = {
            param($t2)
            $c = $t2.Data
            $msg = "האריזה הסתיימה!`n`n$($c.Status)`n`nעכשיו: חברו את הדיסק למחשב החדש, פתחו שם את התוכנה ← 'העברה ממחשב למחשב' ← 'שלב 2'."
            if ($c.Failed -gt 0) { $msg += "`n`nחלק מהקבצים לא הועתקו (למשל קבצים פתוחים). הרשימה ב'דוח העתקה' שבתיקייה _הגדרות." }
            Show-Info $msg
        }
        if ($pj.Steps.Count -gt 0) { Start-Work 'שמירת הגדרות' $pj $finish $null $cj }
        else { & $finish @{ Data = $cj } }
    }
    Start-Work 'אריזת הקבצים להעברה' $cj $afterCopy $null $pj
})

$ui.TrSrcBrowse.Add_Click({
    $f = Select-Folder "בחרו את התיקייה 'העברת קבצים - ...' שנוצרה במחשב הישן"
    if ($f) { $ui.TrSrc.Text = $f; Load-TransferPackage }
})
$ui.TrSrc.Add_LostFocus({ Load-TransferPackage })

function Load-TransferPackage {
    $ui.TrItems.Children.Clear()
    $script:trManifest = $null
    $src = $ui.TrSrc.Text.Trim()
    if (-not $src) { $ui.TrSrcInfo.Text = ''; return }
    $mf = Join-Path $src 'manifest.json'
    if (-not (Test-Path -LiteralPath $mf)) {
        $sub = Get-ChildItem -LiteralPath $src -Directory -Filter 'העברת קבצים*' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($sub) { $ui.TrSrc.Text = $sub.FullName; $src = $sub.FullName; $mf = Join-Path $src 'manifest.json' }
    }
    if (-not (Test-Path -LiteralPath $mf)) { $ui.TrSrcInfo.Text = 'לא נמצאו כאן קבצי העברה. בחרו את התיקייה שנוצרה במחשב הישן.'; return }
    $m = [IO.File]::ReadAllText($mf, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $script:trManifest = $m
    $when = $(try { ([DateTime]$m.Date).ToString('dd/MM/yyyy HH:mm') } catch { $m.Date })
    $ui.TrSrcInfo.Text = "✔ נמצאה העברה מהמחשב $($m.Computer) (משתמש $($m.User)), מתאריך $when. מה לפרוס?"
    foreach ($it in @($m.Parts)) {
        if ($it.Key -in 'Wifi', 'Apps') { continue }
        $cb = New-Object Windows.Controls.CheckBox
        $cb.Content = $it.Name
        $cb.IsChecked = $true
        $cb.Width = 220
        $cb.Tag = $it
        [void]$ui.TrItems.Children.Add($cb)
    }
}

$ui.TrRestore.Add_Click({
    if (Test-Busy) { return }
    Load-TransferPackage
    $m = $script:trManifest
    if (-not $m) { Show-Info 'בחרו קודם את תיקיית ההעברה.'; return }
    $root = $ui.TrSrc.Text.Trim()
    $cj = New-Object Recovery.CopyJob
    $cj.SkipIdentical = $true
    $cj.Overwrite = $false
    $cj.ReportPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'דוח העברת קבצים.txt'
    $bookmarks = $null
    foreach ($cb in $ui.TrItems.Children) {
        if (-not $cb.IsChecked) { continue }
        $it = $cb.Tag
        $from = Join-Path $root $it.Folder
        if ($KnownFolders.Contains([string]$it.Key)) { $to = & $KnownFolders[[string]$it.Key].Path }
        elseif ($it.Key -eq 'Bookmarks') { $to = Join-Path ([Environment]::GetFolderPath('Desktop')) 'סימניות מהמחשב הישן'; $bookmarks = $to }
        else { $to = Join-Path $env:USERPROFILE "מהמחשב הישן\$($it.Name)" }
        $cj.Add($from, $to)
    }
    $pj = New-ProcessJob
    $wifiDir = Join-Path $root '_הגדרות\wifi'
    if ($ui.TrWifiImport.IsChecked -and (Test-Path -LiteralPath $wifiDir)) {
        foreach ($x in Get-ChildItem -LiteralPath $wifiDir -Filter '*.xml' -ErrorAction SilentlyContinue) {
            Add-Step $pj 'netsh.exe' "wlan add profile filename=`"$($x.FullName)`" user=all" "מוסיף רשת Wi-Fi: $($x.BaseName -replace '^[^-]+-', '')"
        }
    }
    $apps = Join-Path $root '_הגדרות\apps.json'
    if ($ui.TrAppsImport.IsChecked) {
        if (-not (Test-Path -LiteralPath $apps)) { Add-Log 'לא נשמרה רשימת תוכנות בהעברה הזו.' }
        elseif (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) { Add-Log 'winget לא זמין במחשב הזה – אי אפשר להתקין תוכנות אוטומטית.' }
        else { Add-Step $pj 'winget.exe' "import -i `"$apps`" --accept-source-agreements --accept-package-agreements --ignore-unavailable" 'מתקין מחדש את התוכנות' -Utf8 }
    }
    $script:trBookmarks = $bookmarks
    $finish = {
        param($t)
        if ($t.Cancelled) { return }
        $msg = "הפריסה הסתיימה!"
        if ($script:trCopyStatus) { $msg += "`n`n$script:trCopyStatus" }
        if ($script:trBookmarks) {
            $msg += "`n`nהסימניות נמצאות בתיקייה 'סימניות מהמחשב הישן' בשולחן העבודה. לייבוא: בדפדפן ← סימניות ← ייבוא סימניות ← קובץ HTML."
        }
        Show-Info $msg
    }
    $afterCopy = {
        param($t)
        if ($t.Cancelled) { Show-Info "הפריסה נעצרה. לחיצה חוזרת תמשיך מאיפה שנעצר."; return }
        $script:trCopyStatus = $t.Job.Status
        $pj = $t.Data
        if ($pj.Steps.Count -gt 0) { Start-Work 'הגדרות מהמחשב הישן' $pj $script:trFinish }
        else { & $script:trFinish @{ Cancelled = $false } }
    }
    $script:trFinish = $finish
    Start-Work 'פריסת הקבצים במחשב החדש' $cj $afterCopy $null $pj
})

# =====================================================================
# גרסאות קודמות (צילומי כונן – Volume Shadow Copies)
# =====================================================================
$ui.VerFolder.Text = [Environment]::GetFolderPath('MyDocuments')
$ui.VerBrowse.Add_Click({ $f = Select-Folder 'בחרו את התיקייה שבה היה הקובץ' $ui.VerFolder.Text; if ($f) { $ui.VerFolder.Text = $f; Find-Versions } })
$ui.VerFind.Add_Click({ Find-Versions })
$script:verLinks = New-Object System.Collections.Generic.List[string]

function Find-Versions {
    if (-not (Test-Admin 'חיפוש גרסאות קודמות')) { return }
    $folder = $ui.VerFolder.Text.Trim()
    if (-not $folder -or $folder.Length -lt 2 -or $folder[1] -ne ':') { Show-Error 'בחרו תיקייה בכונן מקומי (למשל C:\...).'; return }
    $letter = $folder.Substring(0, 2).ToUpper()
    $win.Cursor = [Windows.Input.Cursors]::Wait
    try {
        $vol = Get-CimInstance Win32_Volume -ErrorAction Stop | Where-Object { $_.DriveLetter -eq $letter } | Select-Object -First 1
        $shadows = @(Get-CimInstance Win32_ShadowCopy -ErrorAction Stop | Where-Object { $vol -and $_.VolumeName -eq $vol.DeviceID })
    } catch {
        $shadows = @()
        Add-Log "שגיאה בקריאת הצילומים: $($_.Exception.Message)"
    } finally { $win.Cursor = $null }
    $now = Get-Date
    $items = foreach ($s in ($shadows | Sort-Object InstallDate -Descending)) {
        $d = [DateTime]$s.InstallDate
        $age = $now - $d
        [pscustomobject]@{
            Date     = $d
            DateText = $d.ToString('dd/MM/yyyy HH:mm')
            Drive    = $letter
            Age      = if ($age.TotalDays -ge 1) { '{0:0} ימים' -f [Math]::Floor($age.TotalDays) } else { '{0:0} שעות' -f [Math]::Floor($age.TotalHours) }
            Device   = $s.DeviceObject
            Relative = $folder.Substring(2).TrimStart('\')
        }
    }
    $ui.VerList.ItemsSource = @($items)
    if (@($items).Count -gt 0) {
        $ui.VerList.SelectedIndex = 0
        $ui.VerInfo.Text = "נמצאו $(@($items).Count) צילומים של הכונן $letter. בחרו תאריך מלפני שהקובץ נמחק או השתנה, ולחצו 'פתח'."
    } else {
        $ui.VerInfo.Text = "לא נמצאו צילומים של הכונן $letter. כנראה ש'הגנת מערכת' כבויה בכונן הזה - נסו 'היסטוריית קבצים', או סריקת עומק."
    }
}

function Mount-Version($v) {
    $base = Join-Path $env:TEMP 'ממיר ומשחזר - גרסאות'
    [void][IO.Directory]::CreateDirectory($base)
    $link = Join-Path $base ("{0} {1}" -f $v.Drive.TrimEnd(':'), $v.Date.ToString('yyyy-MM-dd HH-mm'))
    if (-not (Test-Path -LiteralPath $link)) {
        if (-not [Recovery.NativeLinks]::MakeDirLink($link, $v.Device + '\')) {
            throw "לא ניתן לפתוח את הצילום (שגיאה $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))."
        }
        $script:verLinks.Add($link)
    }
    $target = Join-Path $link $v.Relative
    if (-not (Test-Path -LiteralPath $target)) {
        Show-Info "התיקייה '$($v.Relative)' לא הייתה קיימת בתאריך הזה. נפתח את שורש הכונן מהצילום."
        return $link
    }
    return $target
}

$ui.VerOpen.Add_Click({
    $v = $ui.VerList.SelectedItem
    if (-not $v) { Show-Info 'בחרו קודם צילום מהרשימה.'; return }
    $p = Mount-Version $v
    Start-Process explorer.exe "`"$p`""
    Add-Log "נפתח צילום מ-$($v.DateText): $p"
})
$ui.VerCopy.Add_Click({
    if (Test-Busy) { return }
    $v = $ui.VerList.SelectedItem
    if (-not $v) { Show-Info 'בחרו קודם צילום מהרשימה.'; return }
    $p = Mount-Version $v
    $dest = Select-Folder "לאן להעתיק את התיקייה כפי שהייתה ב-$($v.DateText)?"
    if (-not $dest) { return }
    $name = Split-Path -Leaf $p
    $target = Get-FreeName (Join-Path $dest "$name ($($v.Date.ToString('yyyy-MM-dd')))")
    $cj = New-Object Recovery.CopyJob
    $cj.Add($p, $target)
    Start-Work 'העתקת גרסה קודמת' $cj { param($t) if (-not $t.Cancelled) { Show-Info "הועתק אל:`n$($t.Data)"; Open-Path $t.Data } } $null $target
})
$ui.VerHistory.Add_Click({
    try { Start-Process "$env:windir\System32\FileHistory.exe" } catch { Start-Process 'control.exe' '/name Microsoft.FileHistory' }
})
$ui.VerProtection.Add_Click({ Start-Process "$env:windir\System32\SystemPropertiesProtection.exe" })
$ui.VerCreate.Add_Click({
    if (Test-Busy) { return }
    if (-not (Test-Admin 'יצירת נקודת שחזור')) { return }
    $pj = New-ProcessJob
    Add-Step $pj 'powershell.exe' "-NoProfile -Command `"[Console]::OutputEncoding=[Text.Encoding]::UTF8; Enable-ComputerRestore -Drive '$env:SystemDrive\'; Checkpoint-Computer -Description 'ממיר ומשחזר' -RestorePointType MODIFY_SETTINGS`"" 'יוצר נקודת שחזור' -Utf8
    Start-Work 'יצירת נקודת שחזור' $pj {
        param($t)
        if ($t.Cancelled) { return }
        if ($t.Job.FailedSteps -eq 0) { Show-Info 'נקודת השחזור נוצרה.'; Find-Versions }
        else { Show-Error "לא הצלחנו ליצור נקודת שחזור. Windows מאפשר נקודה אחת בכל 24 שעות - ייתכן שכבר נוצרה אחת היום.`nפרטים ב'הצגת פירוט'." }
    }
})

# =====================================================================
# מסמכים שלא נשמרו
# =====================================================================
function Get-NotepadText([string]$bin) {
    # קבצי הלשוניות של פנקס הרשימות ב-Windows 11: הטקסט שמור כ-UTF-16. מחלצים את הרצף הקריא הארוך ביותר.
    $b = [IO.File]::ReadAllBytes($bin)
    $best = ''; $sb = New-Object Text.StringBuilder
    for ($off = 0; $off -lt 2; $off++) {
        [void]$sb.Clear()
        for ($i = $off; $i + 1 -lt $b.Length; $i += 2) {
            $c = [char]([int]$b[$i] -bor ([int]$b[$i + 1] -shl 8))
            $v = [int]$c
            # אותיות לטיניות, עברית, ערבית, יוונית, קירילית, סימנים ו-CJK; בלי תווי בקרה ובלי צירופים מקריים של בתים
            if ($v -eq 9 -or $v -eq 10 -or $v -eq 13 -or ($v -ge 0x20 -and $v -lt 0x250) -or ($v -ge 0x370 -and $v -lt 0x500) -or
                ($v -ge 0x590 -and $v -lt 0x700) -or ($v -ge 0x2000 -and $v -lt 0x2C00) -or ($v -ge 0x3000 -and $v -lt 0xD800)) {
                if ($c -eq "`r") { [void]$sb.Append("`r`n") } else { [void]$sb.Append($c) }
            } else {
                if ($sb.Length -gt $best.Length) { $best = $sb.ToString() }
                [void]$sb.Clear()
            }
        }
        if ($sb.Length -gt $best.Length) { $best = $sb.ToString() }
    }
    return $best.Trim()
}

function Find-Unsaved {
    $la = $env:LOCALAPPDATA; $ra = $env:APPDATA
    $spots = @(
        @('Office', "$la\Microsoft\Office\UnsavedFiles", '*'),
        @('Word', "$ra\Microsoft\Word", '*.asd;*.wbk;*.tmp;*.docx;*.doc'),
        @('Excel', "$ra\Microsoft\Excel", '*.xlsb;*.xar;*.xlsx;*.xls;*.tmp'),
        @('PowerPoint', "$ra\Microsoft\PowerPoint", '*.pptx;*.ppt;*.tmp'),
        @('Word', "$la\Microsoft\Office\16.0\Word", '*.asd'),
        @('Word', $env:TEMP, '*.asd;*.wbk;~WRL*.tmp;~WRD*.tmp'),
        @('Notepad++', "$ra\Notepad++\backup", '*'),
        @('פנקס רשימות', "$la\Packages\Microsoft.WindowsNotepad_8wekyb3d8bbwe\LocalState\TabState", '*.bin'),
        @('LibreOffice', "$ra\LibreOffice\4\user\backup", '*'))
    $res = New-Object System.Collections.Generic.List[object]
    foreach ($s in $spots) {
        if (-not (Test-Path -LiteralPath $s[1])) { continue }
        $depth = if ($s[1] -eq $env:TEMP) { 0 } else { 3 }
        foreach ($pat in $s[2].Split(';')) {
            foreach ($f in Get-ChildItem -LiteralPath $s[1] -Filter $pat -File -Recurse -Depth $depth -Force -ErrorAction SilentlyContinue) {
                if ($f.Length -lt 64) { continue }
                if ($res | Where-Object { $_.Path -eq $f.FullName }) { continue }
                $name = $f.Name
                if ($s[0] -eq 'פנקס רשימות') {
                    if ($f.Name -match '\.\d\.bin$') { continue }
                    $txt = $(try { Get-NotepadText $f.FullName } catch { '' })
                    if ($txt.Length -lt 2) { continue }
                    $first = ($txt -split "`n")[0].Trim()
                    $name = if ($first.Length -gt 40) { $first.Substring(0, 40) + '…' } else { $first }
                }
                $res.Add([pscustomobject]@{
                    App = $s[0]; Name = $name; Path = $f.FullName; Folder = $f.DirectoryName
                    Date = $f.LastWriteTime; DateText = $f.LastWriteTime.ToString('dd/MM/yyyy HH:mm'); SizeText = Format-Size $f.Length
                })
            }
        }
    }
    $ui.UnsList.ItemsSource = @($res | Sort-Object Date -Descending)
    $ui.UnsCount.Text = if ($res.Count) { "נמצאו $($res.Count) קבצים זמניים" } else { 'לא נמצאו קבצים זמניים. נסו גם "גרסאות קודמות" או "קבצים שנעלמו".' }
}

function Get-UnsavedAsFile($it, [string]$folder) {
    if ($it.App -eq 'פנקס רשימות') {
        $safe = ($it.Name -replace '[\\/:*?"<>|…]', '').Trim()
        if (-not $safe) { $safe = 'פנקס רשימות' }
        $t = Get-FreeName (Join-Path $folder "$safe.txt")
        [IO.File]::WriteAllText($t, (Get-NotepadText $it.Path), [Text.Encoding]::UTF8)
        return $t
    }
    $name = [IO.Path]::GetFileName($it.Path)
    $t = Get-FreeName (Join-Path $folder $name)
    [IO.File]::Copy($it.Path, $t)
    return $t
}

$script:onShow['Unsaved'] = { Find-Unsaved }
$ui.UnsRefresh.Add_Click({ Find-Unsaved })
$ui.UnsOpen.Add_Click({
    $it = $ui.UnsList.SelectedItem
    if (-not $it) { Show-Info 'בחרו קובץ מהרשימה.'; return }
    # פותחים עותק, כדי לא לפגוע בקובץ הזמני המקורי
    $tmp = Join-Path $WorkDir 'פתוחים'
    [void][IO.Directory]::CreateDirectory($tmp)
    $copy = Get-UnsavedAsFile $it $tmp
    $ext = [IO.Path]::GetExtension($copy).ToLower()
    try {
        if ($ext -in '.asd', '.wbk', '.tmp' -and $it.App -in 'Word', 'Office') { Start-Process winword.exe "`"$copy`"" }
        elseif ($ext -in '.xar', '.tmp' -and $it.App -eq 'Excel') { Start-Process excel.exe "`"$copy`"" }
        elseif ($ext -eq '.tmp' -and $it.App -eq 'PowerPoint') { Start-Process powerpnt.exe "`"$copy`"" }
        else { Start-Process "`"$copy`"" }
    } catch {
        Show-Error "לא נמצאה תוכנה שפותחת את הקובץ.`nהעותק נשמר כאן:`n$copy"
        Show-InFolder $copy
    }
})
$ui.UnsSave.Add_Click({
    $sel = @($ui.UnsList.SelectedItems)
    if ($sel.Count -eq 0) { Show-Info 'בחרו קבצים מהרשימה.'; return }
    $f = Select-Folder 'לאן לשמור עותק?' ([Environment]::GetFolderPath('MyDocuments'))
    if (-not $f) { return }
    foreach ($it in $sel) { try { [void](Get-UnsavedAsFile $it $f) } catch { Add-Log "✗ $($it.Name): $($_.Exception.Message)" } }
    Open-Path $f
})
$ui.UnsFolder.Add_Click({ $it = $ui.UnsList.SelectedItem; if ($it) { Show-InFolder $it.Path } })

# =====================================================================
# קבצים שנעלמו
# =====================================================================
$SearchTypes = @(
    @('הכל', $null),
    @('מסמכים (Word, Excel, PowerPoint, PDF, טקסט)', 'doc,docx,xls,xlsx,xlsm,ppt,pptx,pdf,txt,rtf,odt,ods,odp,csv'),
    @('תמונות', 'jpg,jpeg,png,heic,gif,bmp,tif,tiff,webp,raw,cr2,nef,arw,dng'),
    @('סרטונים', 'mp4,mov,avi,mkv,wmv,m4v,3gp,mts,webm'),
    @('שמע', 'mp3,wav,m4a,flac,ogg,wma,aac,amr'),
    @('PDF', 'pdf'),
    @('קבצים דחוסים', 'zip,rar,7z'))
foreach ($t in $SearchTypes) { $it = New-Object Windows.Controls.ComboBoxItem; $it.Content = $t[0]; $it.Tag = $t[1]; [void]$ui.SrType.Items.Add($it) }
$ui.SrType.SelectedIndex = 0
foreach ($t in @(@('בכל זמן', 0), @('היום', 1), @('בשבוע האחרון', 7), @('בחודש האחרון', 31), @('בשנה האחרונה', 366))) {
    $it = New-Object Windows.Controls.ComboBoxItem; $it.Content = $t[0]; $it.Tag = $t[1]; [void]$ui.SrTime.Items.Add($it)
}
$ui.SrTime.SelectedIndex = 0
function Fill-SearchWhere {
    $ui.SrWhere.Items.Clear()
    $it = New-Object Windows.Controls.ComboBoxItem; $it.Content = "התיקייה האישית שלי ($env:USERPROFILE)"; $it.Tag = @($env:USERPROFILE); [void]$ui.SrWhere.Items.Add($it)
    $it = New-Object Windows.Controls.ComboBoxItem; $it.Content = 'כל הכוננים'; $it.Tag = @($script:drives | ForEach-Object { $_.Root }); [void]$ui.SrWhere.Items.Add($it)
    foreach ($d in $script:drives) { $it = New-Object Windows.Controls.ComboBoxItem; $it.Content = $d.Text; $it.Tag = @($d.Root); [void]$ui.SrWhere.Items.Add($it) }
    $ui.SrWhere.SelectedIndex = 0
}
Fill-SearchWhere
$script:srResults = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$ui.SrList.ItemsSource = $script:srResults

function Start-FileSearch {
    if (Test-Busy) { return }
    $q = $ui.SrName.Text.Trim()
    $days = [int]$ui.SrTime.SelectedItem.Tag
    $types = $ui.SrType.SelectedItem.Tag
    if (-not $q -and $days -eq 0 -and -not $types) { Show-Info 'כתבו שם (או חלק מהשם), או בחרו סוג/זמן - כדי לצמצם את החיפוש.'; return }
    $j = New-Object Recovery.FileSearchJob
    foreach ($r in @($ui.SrWhere.SelectedItem.Tag)) { $j.Roots.Add([string]$r) }
    $j.Query = $q
    if ($types) { $j.Extensions = [string[]]($types -split ',') }
    if ($days -gt 0) { $j.After = (Get-Date).Date.AddDays(1 - $days) }
    $script:srResults.Clear()
    $ui.SrCount.Text = ''
    $tick = {
        param($t)
        foreach ($r in $t.Job.TakeResults()) { $script:srResults.Add($r) }
        $ui.SrCount.Text = "נמצאו $($script:srResults.Count) קבצים"
    }
    Start-Work 'חיפוש קבצים' $j { param($t) & $t.Tick $t; if ($script:srResults.Count -eq 0 -and -not $t.Cancelled) { $ui.SrCount.Text = 'לא נמצאו קבצים. נסו חלק קצר יותר מהשם, או "כל הכוננים".' } } $tick
}
$ui.SrStart.Add_Click({ Start-FileSearch })
$ui.SrName.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { Start-FileSearch } })
$ui.SrOpen.Add_Click({ $it = $ui.SrList.SelectedItem; if ($it) { Start-Process "`"$($it.FullPath)`"" } })
$ui.SrList.Add_MouseDoubleClick({ $it = $ui.SrList.SelectedItem; if ($it) { Show-InFolder $it.FullPath } })
$ui.SrShow.Add_Click({ $it = $ui.SrList.SelectedItem; if ($it) { Show-InFolder $it.FullPath } })
$ui.SrCopy.Add_Click({
    if (Test-Busy) { return }
    $sel = @($ui.SrList.SelectedItems)
    if ($sel.Count -eq 0) { Show-Info 'בחרו קבצים מהרשימה.'; return }
    $f = Select-Folder 'לאן להעתיק?'
    if (-not $f) { return }
    $cj = New-Object Recovery.CopyJob
    $cj.SkipIdentical = $false
    foreach ($it in $sel) { $cj.Add($it.FullPath, $f) }
    Start-Work 'העתקת קבצים' $cj { param($t) Open-Path $t.Data } $null $f
})

# =====================================================================
# סריקת עומק
# =====================================================================
Fill-Drives $ui.DpDrive
if ($script:drives.Count -gt 0) { $ui.DpOut.Text = Get-DefaultOutput $script:drives[0].Letter }
$ui.DpDrive.Add_SelectionChanged({
    $d = Get-SelectedDrive $ui.DpDrive
    if ($d) { $ui.DpOut.Text = Get-DefaultOutput $d.Letter; $ui.DpFromDrive.IsChecked = $true }
})
$ui.DpImageBrowse.Add_Click({
    $f = @(Select-Files 'תמונת כונן|*.img;*.dd;*.raw;*.bin;*.iso|כל הקבצים|*.*' -Single)
    if ($f.Count) { $ui.DpImage.Text = $f[0]; $ui.DpFromImage.IsChecked = $true }
})
$ui.DpOutBrowse.Add_Click({ $f = Select-Folder 'בחרו תיקייה לשמירת הקבצים המשוחזרים (עדיף בכונן אחר)'; if ($f) { $ui.DpOut.Text = $f } })
$ui.DpOpen.Add_Click({ Open-Path $ui.DpOut.Text.Trim() })

$ui.DpStart.Add_Click({
    if (Test-Busy) { return }
    $out = $ui.DpOut.Text.Trim()
    if (-not $out -or -not [IO.Path]::IsPathRooted($out)) { Show-Error 'בחרו תיקייה לשמירת הקבצים.'; return }
    $bitmapNote = ''
    if ($ui.DpFromImage.IsChecked) {
        $img = $ui.DpImage.Text.Trim()
        if (-not (Test-Path -LiteralPath $img)) { Show-Error 'בחרו קובץ תמונת כונן קיים.'; return }
        $src = New-Object Recovery.FileBlockSource($img)
        $label = [IO.Path]::GetFileName($img)
        $useBitmap = $false
    } else {
        if (-not (Test-Admin 'סריקת עומק של כונן')) { return }
        $drive = Get-SelectedDrive $ui.DpDrive
        if (-not $drive) { return }
        if (Test-SameDrive $out $drive.Root) {
            $q = "התיקייה נמצאת על אותו כונן שסורקים ($($drive.Letter):).`nכתיבה לשם עלולה להרוס קבצים שעוד לא שוחזרו.`n`nמומלץ מאוד לחבר דיסק-און-קי ולבחור אותו.`nלהמשיך בכל זאת?"
            if (-not (Ask $q 'Warning')) { return }
        }
        try { $src = New-Object Recovery.VolumeSource([char]$drive.Letter) }
        catch { Show-Error ("לא ניתן לפתוח את הכונן לקריאה:`n" + $_.Exception.Message); return }
        $label = "$($drive.Letter):"
        $useBitmap = $ui.DpFree.IsChecked
    }
    $s = New-Object Recovery.Scanner($src, $out)
    $s.Jpg = $ui.DpJpg.IsChecked; $s.Png = $ui.DpPng.IsChecked; $s.Gif = $ui.DpGif.IsChecked; $s.Heic = $ui.DpHeic.IsChecked
    $s.Pdf = $ui.DpPdf.IsChecked; $s.Office = $ui.DpOffice.IsChecked; $s.Video = $ui.DpVideo.IsChecked
    $kb = 10; [void][int]::TryParse($ui.DpMin.Text, [ref]$kb)
    $s.MinSize = [long]$kb * 1024
    $s.Step = $src.Alignment
    if ($useBitmap) {
        if ($drive.Format -eq 'NTFS') {
            $clusters = [long]0
            $bm = $src.GetVolumeBitmap([ref]$clusters)
            if ($bm) { $s.Bitmap = $bm; $s.BitmapClusters = $clusters; $s.ClusterSize = $src.ClusterSize }
            else { $bitmapNote = ' (לא ניתן לקרוא את מפת השטח הפנוי – סורק את כל הכונן)' }
        } else { $bitmapNote = " (הכונן בפורמט $($drive.Format) – סורק את כל הכונן)" }
    }
    Add-Log "סורק את $label$bitmapNote"
    $ui.DpSummary.Text = ''
    Start-Work "סריקת עומק של $label" $s {
        param($t)
        $s = $t.Job
        try { $t.Data.Dispose() } catch { }
        $ui.DpSummary.Text = "נמצאו $($s.Found) קבצים ($(Format-Size $s.BytesRecovered)).   $($s.Summary())"
        if ($s.Error) { Show-Error ("הסריקה נעצרה בגלל שגיאה:`n" + $s.Error); return }
        if ($t.Cancelled) { return }
        if ($s.Found -gt 0) {
            if (Ask "הסריקה הסתיימה ונמצאו $($s.Found) קבצים.`nלפתוח את התיקייה?") { Open-Path $ui.DpOut.Text.Trim() }
        } else {
            Show-Info 'הסריקה הסתיימה ולא נמצאו קבצים מהסוגים שנבחרו. נסו את "שחזור עם שמות" בעמוד שחזור קבצים.'
        }
    } $null $src
})

# =====================================================================
# העתקה מכונן פגום
# =====================================================================
foreach ($t in @(@(1, 'פעם אחת - מהיר'), @(3, '3 פעמים (מומלץ)'), @(8, '8 פעמים - עקשן'))) {
    $it = New-Object Windows.Controls.ComboBoxItem; $it.Content = $t[1]; $it.Tag = $t[0]; [void]$ui.SvRetries.Items.Add($it)
}
$ui.SvRetries.SelectedIndex = 1
$ui.SvSrcBrowse.Add_Click({ $f = Select-Folder 'מה להעתיק? (אפשר לבחור כונן שלם)'; if ($f) { $ui.SvSrc.Text = $f; if (-not $ui.SvDst.Text) { $ui.SvDst.Text = Get-DefaultOutput $f.Substring(0, 1) 'הועתק מכונן פגום' } } })
$ui.SvDstBrowse.Add_Click({ $f = Select-Folder 'לאן להעתיק? (כונן תקין)'; if ($f) { $ui.SvDst.Text = $f } })
$ui.SvOpen.Add_Click({ Open-Path $ui.SvDst.Text.Trim() })
$ui.SvStart.Add_Click({
    if (Test-Busy) { return }
    $src = $ui.SvSrc.Text.Trim(); $dst = $ui.SvDst.Text.Trim()
    if (-not $src -or -not (Test-Path -LiteralPath $src)) { Show-Error 'בחרו מה להעתיק.'; return }
    if (-not $dst -or -not [IO.Path]::IsPathRooted($dst)) { Show-Error 'בחרו לאן להעתיק.'; return }
    if (Test-SameDrive $src $dst) { Show-Error 'היעד חייב להיות בכונן אחר, תקין.'; return }
    $leaf = Split-Path -Leaf $src
    if (-not $leaf -or $leaf -eq $src) { $leaf = "כונן $($src.Substring(0, 1))" }
    $target = Join-Path $dst $leaf
    $cj = New-Object Recovery.CopyJob
    $cj.Salvage = $true
    $cj.Retries = [int]$ui.SvRetries.SelectedItem.Tag
    $cj.SkipIdentical = [bool]$ui.SvSkip.IsChecked
    $cj.Overwrite = $true
    $cj.ExcludeNames = [string[]]@('System Volume Information', '$RECYCLE.BIN')
    $cj.ReportPath = Join-Path $dst 'דוח העתקה מכונן פגום.txt'
    $cj.Add($src, $target)
    Start-Work 'העתקה מכונן פגום' $cj {
        param($t)
        if ($t.Cancelled) { return }
        $j = $t.Job
        $msg = "ההעתקה הסתיימה.`n$($j.Status)"
        if ($j.Damaged -gt 0 -or $j.Failed -gt 0) { $msg += "`n`nרשימת הקבצים הבעייתיים נשמרה ב:`n$($j.ReportPath)" }
        Show-Info $msg
        Open-Path $t.Data
    } $null $target
})

# =====================================================================
# גיבוי כונן לקובץ
# =====================================================================
Fill-Drives $ui.ImDrive
function Update-ImageDefaults {
    $d = Get-SelectedDrive $ui.ImDrive
    if (-not $d) { return }
    $dir = Get-DefaultOutput $d.Letter 'גיבויי כוננים'
    $ui.ImOut.Text = Join-Path $dir ("כונן {0} - {1}.img" -f $d.Letter, (Get-Date).ToString('yyyy-MM-dd'))
    $ui.ImInfo.Text = "גודל הקובץ שייווצר: $(Format-Size $d.Size)."
}
$ui.ImDrive.Add_SelectionChanged({ Update-ImageDefaults })
Update-ImageDefaults
$ui.ImBrowse.Add_Click({
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = 'תמונת כונן|*.img'
    $dlg.FileName = [IO.Path]::GetFileName($ui.ImOut.Text)
    if ($dlg.ShowDialog($win)) { $ui.ImOut.Text = $dlg.FileName }
})
$ui.ImScan.Add_Click({
    $p = $ui.ImOut.Text.Trim()
    if (Test-Path -LiteralPath $p) { $ui.DpImage.Text = $p; $ui.DpFromImage.IsChecked = $true }
    Show-Page 'Deep'
})
$ui.ImStart.Add_Click({
    if (Test-Busy) { return }
    if (-not (Test-Admin 'גיבוי כונן')) { return }
    $d = Get-SelectedDrive $ui.ImDrive
    $out = $ui.ImOut.Text.Trim()
    if (-not $d) { return }
    if (-not $out -or -not [IO.Path]::IsPathRooted($out)) { Show-Error 'בחרו איפה לשמור את הקובץ.'; return }
    if (Test-SameDrive $out $d.Root) { Show-Error 'הקובץ חייב להישמר על כונן אחר מהכונן שמגבים.'; return }
    try {
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($out))
        if (-not $out.StartsWith('\\')) {
            $free = (New-Object IO.DriveInfo($out.Substring(0, 1))).AvailableFreeSpace
            if ($free -lt $d.Size) { Show-Error "אין מספיק מקום ביעד: צריך $(Format-Size $d.Size), פנוי $(Format-Size $free)."; return }
            $fmt = (New-Object IO.DriveInfo($out.Substring(0, 1))).DriveFormat
            if ($fmt -like 'FAT*' -and $d.Size -gt 4GB) { Show-Error "כונן היעד בפורמט $fmt, שלא תומך בקבצים גדולים מ-4GB. בחרו כונן בפורמט NTFS או exFAT."; return }
        }
    } catch { }
    $j = New-Object Recovery.DiskImageJob([char]$d.Letter, $out)
    Start-Work "גיבוי הכונן $($d.Letter): לקובץ" $j {
        param($t)
        if ($t.Cancelled) { Show-Info "הגיבוי נעצר. הקובץ החלקי נשמר - אפשר לסרוק גם אותו בסריקת עומק:`n$($t.Data)"; return }
        if ($t.Job.Error) { Show-Error ("הגיבוי נכשל:`n" + $t.Job.Error); return }
        if (Ask "$($t.Job.Status)`n`nלסרוק עכשיו את הקובץ בסריקת עומק?") {
            $ui.DpImage.Text = $t.Data; $ui.DpFromImage.IsChecked = $true; Show-Page 'Deep'
        }
    } $null $out
})

# =====================================================================
# תיקון שגיאות בכונן
# =====================================================================
Fill-Drives $ui.FxDrive
function Load-DiskHealth {
    $rows = @()
    try {
        foreach ($p in Get-PhysicalDisk -ErrorAction Stop) {
            $h = switch ([string]$p.HealthStatus) { 'Healthy' { '✔ תקין' } 'Warning' { '⚠ אזהרה - כדאי לגבות בהקדם!' } 'Unhealthy' { '✗ לא תקין - גבו מיד!' } default { [string]$p.HealthStatus } }
            if ([string]$p.OperationalStatus -notin 'OK', '') { $h += " ($($p.OperationalStatus))" }
            $kind = switch ([string]$p.MediaType) { 'SSD' { 'SSD' } 'HDD' { 'דיסק קשיח' } default { [string]$p.BusType } }
            $rows += [pscustomobject]@{ Name = $p.FriendlyName; Kind = $kind; SizeText = Format-Size $p.Size; Health = $h }
        }
    } catch {
        try {
            foreach ($p in Get-CimInstance Win32_DiskDrive -ErrorAction Stop) {
                $h = if ($p.Status -eq 'OK') { '✔ תקין' } else { "⚠ $($p.Status)" }
                $rows += [pscustomobject]@{ Name = $p.Model; Kind = $p.InterfaceType; SizeText = Format-Size ([long]$p.Size); Health = $h }
            }
        } catch { }
    }
    $ui.FxDisks.ItemsSource = $rows
}
$script:onShow['Fix'] = { if (-not $ui.FxDisks.ItemsSource) { Load-DiskHealth } }
$ui.FxHealthRefresh.Add_Click({ Load-DiskHealth })
$ui.FxStart.Add_Click({
    if (Test-Busy) { return }
    if (-not (Test-Admin 'בדיקת כונן')) { return }
    $d = Get-SelectedDrive $ui.FxDrive
    if (-not $d) { return }
    $isSystem = $d.Letter -eq $env:SystemDrive.Substring(0, 1)
    $stdin = $null
    if ($ui.FxScan.IsChecked) {
        $argList = if ($d.Format -eq 'NTFS') { "$($d.Letter): /scan" } else { "$($d.Letter):" }
        $title = "בדיקת הכונן $($d.Letter):"
    } else {
        $sw = if ($ui.FxDeep.IsChecked) { '/r' } else { '/f' }
        if ($isSystem) {
            if (-not (Ask "הכונן $($d.Letter): הוא כונן המערכת, ולכן אפשר לתקן אותו רק בהפעלה מחדש של המחשב.`nלתזמן תיקון להפעלה הבאה?")) { return }
            $argList = "$($d.Letter): $sw"
        } else {
            if (-not (Ask "במהלך התיקון הכונן $($d.Letter): ינותק זמנית, וקבצים פתוחים ממנו ייסגרו.`nלהמשיך?" 'Warning')) { return }
            $argList = "$($d.Letter): $sw /x"
        }
        $stdin = "Y`r`nY`r`n"
        $title = "תיקון הכונן $($d.Letter):"
    }
    $pj = New-ProcessJob
    $pj.QuietProgress = $true
    Add-Step $pj "$env:windir\System32\chkdsk.exe" $argList $title -StdIn $stdin
    Start-Work $title $pj {
        param($t)
        if ($t.Cancelled) { return }
        $code = $t.Job.LastExitCode
        $msg = switch ($code) {
            0 { 'הבדיקה הסתיימה - לא נמצאו שגיאות.' }
            1 { 'נמצאו שגיאות והן תוקנו.' }
            2 { 'הבדיקה הסתיימה. ייתכן שנדרש ניקוי קטן - אפשר להריץ "תיקון".' }
            3 { 'נמצאו שגיאות שלא תוקנו. הריצו "תיקון שגיאות", ואם זה חוזר - גבו את הכונן.' }
            default { "הסתיים (קוד $code)." }
        }
        if ($isSystem -and -not $ui.FxScan.IsChecked) { $msg = 'התיקון תוזמן. הוא יתבצע בהפעלה מחדש הבאה של המחשב (לפני ש-Windows עולה).' }
        Show-Info "$msg`n`nהפלט המלא נמצא ב'הצגת פירוט'."
    }
})

# ---------- הפעלה ----------
Set-ConvertMode 'Images'
Update-Winfr
$win.Add_Closing({
    param($s, $e)
    if ($script:task) {
        if (-not (Ask "יש פעולה שעדיין רצה ($($script:task.Title)).`nלעצור אותה ולצאת?" 'Warning')) { $e.Cancel = $true; return }
        Stop-Work
    }
    # מוחק רק את הקיצורים לצילומים, לא את התוכן שלהם
    foreach ($l in $script:verLinks) { try { [IO.Directory]::Delete($l, $false) } catch { } }
})
$win.Add_ContentRendered({ $win.Activate() })
[void]$win.ShowDialog()
