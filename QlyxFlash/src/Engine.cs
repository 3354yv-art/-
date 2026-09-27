// מנוע QlyxFlash: קורא קובצי קושחה בפורמט PAC של Unisoc/Spreadtrum, בודק את התקינות שלהם ומחלץ מהם קבצים.
// נכתב ב-C# 5 כדי ש-PowerShell 5.1 (שמגיע עם כל Windows) יוכל לקמפל אותו.
// מבנה הקובץ לפי unpac של spreadtrum_flash: https://github.com/ilyakurdyukov/spreadtrum_flash
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace Qlyx
{
    public class PacEntry
    {
        public string Id;
        public string Name;
        public long Size;
        public long Offset;
        public uint Type;      // 0 - פעולה, 1 - קובץ, 2 - XML, 0x101 - FDL
        public uint[] Addr;

        public bool HasData { get { return Name.Length > 0 && Offset > 0 && Size > 0; } }
        public uint FirstAddr { get { return Addr.Length > 0 ? Addr[0] : 0; } }
        public bool IsFdl { get { return Id.StartsWith("FDL", StringComparison.OrdinalIgnoreCase); } }
    }

    public class PacFile
    {
        public const int HeadSize = 2124;
        public const int EntrySize = 2580;
        const uint Magic = 0xFFFAFFFA; // ~0x50005

        public string Path;
        public long FileLength;
        public string PacVersion, FwName, FwVersion, FwAlias;
        public uint PacSize;
        public ushort HeadCrc, DataCrc, HeadCrcActual;
        public List<PacEntry> Entries = new List<PacEntry>();

        public bool HeadCrcOk { get { return HeadCrc == HeadCrcActual; } }

        public static ushort Crc16(ushort crc, byte[] buf, int len)
        {
            uint c = crc;
            for (int i = 0; i < len; i++)
            {
                c ^= buf[i];
                for (int b = 0; b < 8; b++)
                    c = (c >> 1) ^ ((c & 1) != 0 ? 0xA001u : 0u);
            }
            return (ushort)c;
        }

        static string Utf16(byte[] b, int off, int chars)
        {
            var sb = new StringBuilder();
            for (int i = 0; i < chars; i++)
            {
                char ch = (char)(b[off + i * 2] | (b[off + i * 2 + 1] << 8));
                if (ch == 0) break;
                sb.Append(ch);
            }
            return sb.ToString();
        }

        public static PacFile Open(string path)
        {
            var p = new PacFile();
            p.Path = path;
            using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                p.FileLength = fs.Length;
                var h = new byte[HeadSize];
                if (fs.Read(h, 0, HeadSize) != HeadSize)
                    throw new InvalidDataException("הקובץ קצר מדי – זה לא קובץ PAC.");
                if (BitConverter.ToUInt32(h, HeadSize - 8) != Magic)
                    throw new InvalidDataException("זה לא קובץ PAC של Unisoc/Spreadtrum (חתימה שגויה).");

                p.PacVersion = Utf16(h, 0, 24);
                p.PacSize = BitConverter.ToUInt32(h, 48);
                p.FwName = Utf16(h, 52, 256);
                p.FwVersion = Utf16(h, 564, 256);
                uint count = BitConverter.ToUInt32(h, 1076);
                uint dirOffset = BitConverter.ToUInt32(h, 1080);
                p.FwAlias = Utf16(h, 1104, 100);
                p.HeadCrc = BitConverter.ToUInt16(h, HeadSize - 4);
                p.DataCrc = BitConverter.ToUInt16(h, HeadSize - 2);
                p.HeadCrcActual = Crc16(0, h, HeadSize - 4);

                if (dirOffset != HeadSize)
                    throw new InvalidDataException("מבנה הקובץ לא מוכר (מיקום רשימת הקבצים שגוי).");
                if (count >= 1024)
                    throw new InvalidDataException("מבנה הקובץ לא מוכר (יותר מדי קבצים).");

                var e = new byte[EntrySize];
                for (int i = 0; i < count; i++)
                {
                    if (fs.Read(e, 0, EntrySize) != EntrySize)
                        throw new InvalidDataException("הקובץ נקטע באמצע רשימת הקבצים.");
                    if (BitConverter.ToUInt32(e, 0) != EntrySize)
                        throw new InvalidDataException("מבנה הקובץ לא מוכר (גודל רשומה שגוי).");
                    var en = new PacEntry();
                    en.Id = Utf16(e, 4, 256);
                    en.Name = Utf16(e, 516, 256);
                    uint sizeHigh = BitConverter.ToUInt32(e, 1532);
                    uint offHigh = BitConverter.ToUInt32(e, 1536);
                    en.Size = ((long)sizeHigh << 32) | BitConverter.ToUInt32(e, 1540);
                    en.Type = BitConverter.ToUInt32(e, 1544);
                    en.Offset = ((long)offHigh << 32) | BitConverter.ToUInt32(e, 1552);
                    uint addrNum = BitConverter.ToUInt32(e, 1560);
                    var addrs = new List<uint>();
                    for (int j = 0; j < 5 && j < addrNum; j++)
                        addrs.Add(BitConverter.ToUInt32(e, 1564 + j * 4));
                    en.Addr = addrs.ToArray();
                    p.Entries.Add(en);
                }
            }
            return p;
        }

        // בעיות מבניות שמונעות צריבה בטוחה. רשימה ריקה = תקין.
        public List<string> StructureProblems()
        {
            var list = new List<string>();
            if (!HeadCrcOk)
                list.Add(string.Format("בדיקת הכותרת נכשלה (CRC 0x{0:X4}, צפוי 0x{1:X4}).", HeadCrc, HeadCrcActual));
            if (PacSize != FileLength)
                list.Add(string.Format("גודל הקובץ ({0:N0} בתים) לא תואם לגודל שרשום בו ({1:N0} בתים) – ייתכן שההורדה לא הושלמה.", FileLength, PacSize));
            foreach (var en in Entries)
                if (en.HasData && en.Offset + en.Size > FileLength)
                    list.Add("הקובץ " + en.Name + " חורג מסוף הקובץ – הקובץ פגום או חתוך.");
            return list;
        }

        // מחשב את ה-CRC של כל הנתונים. progress מקבל אחוז 0–100.
        public bool CheckDataCrc(Action<int> progress, out ushort actual)
        {
            ushort crc = 0;
            var buf = new byte[1 << 20];
            using (var fs = new FileStream(Path, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                fs.Position = HeadSize;
                long left = (long)PacSize - HeadSize;
                long total = left;
                int lastPct = -1;
                while (left > 0)
                {
                    int n = fs.Read(buf, 0, (int)Math.Min(buf.Length, left));
                    if (n <= 0) break;
                    crc = Crc16(crc, buf, n);
                    left -= n;
                    int pct = total > 0 ? (int)((total - left) * 100 / total) : 100;
                    if (pct != lastPct && progress != null) { progress(pct); lastPct = pct; }
                }
                if (left > 0) { actual = crc; return false; }
            }
            actual = crc;
            return crc == DataCrc;
        }

        public string Extract(PacEntry en, string dir)
        {
            string name = System.IO.Path.GetFileName(en.Name);
            if (name.Length == 0 || name != en.Name || name.IndexOfAny(System.IO.Path.GetInvalidFileNameChars()) >= 0)
                throw new InvalidDataException("שם קובץ לא בטוח בתוך ה-PAC: " + en.Name);
            string outPath = System.IO.Path.Combine(dir, name);
            var buf = new byte[1 << 20];
            using (var fs = new FileStream(Path, FileMode.Open, FileAccess.Read, FileShare.Read))
            using (var fo = new FileStream(outPath, FileMode.Create, FileAccess.Write))
            {
                fs.Position = en.Offset;
                long left = en.Size;
                while (left > 0)
                {
                    int n = fs.Read(buf, 0, (int)Math.Min(buf.Length, left));
                    if (n <= 0) throw new EndOfStreamException("הקובץ נקטע בזמן החילוץ.");
                    fo.Write(buf, 0, n);
                    left -= n;
                }
            }
            return outPath;
        }

        public static string TypeName(uint t)
        {
            switch (t)
            {
                case 0: return "פעולה";
                case 1: return "קובץ";
                case 2: return "XML";
                case 0x101: return "FDL";
                default: return "0x" + t.ToString("X");
            }
        }
    }
}
