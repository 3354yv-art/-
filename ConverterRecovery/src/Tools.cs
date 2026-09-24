// כלים שרצים ברקע: העתקה (רגילה ומכונן פגום), גיבוי כונן לקובץ, חיפוש קבצים, המרת תמונות, יצירת PDF והרצת תוכנות חיצוניות.
// נכתב ב-C# 5 כדי ש-PowerShell 5.1 (שמגיע עם כל Windows) יוכל לקמפל אותו.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Media;
using System.Windows.Media.Imaging;

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
