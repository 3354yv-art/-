# צריבת קושחה ל-QLYX Q8 – עוזר צעד-אחר-צעד לבדיקת קובץ PAC, זיהוי מצב צריבה, גיבוי וצריבה
# הפעלה: לחיצה כפולה על "Start.bat" (או: powershell -ExecutionPolicy Bypass -STA -File QlyxFlash.ps1)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$appTitle = 'צריבת קושחה – QLYX Q8'
$rtl = [System.Windows.Forms.MessageBoxOptions]::RtlReading -bor [System.Windows.Forms.MessageBoxOptions]::RightAlign

function Show-Error($text) {
    [void][System.Windows.Forms.MessageBox]::Show($text, $appTitle, 'OK', 'Error', 'Button1', $rtl)
}

function Ask($text, $icon = 'Question') {
    $r = [System.Windows.Forms.MessageBox]::Show($text, $appTitle, 'YesNo', $icon, 'Button2', $rtl)
    return $r -eq 'Yes'
}

function Show-Info($text) {
    [void][System.Windows.Forms.MessageBox]::Show($text, $appTitle, 'OK', 'Information', 'Button1', $rtl)
}

# הסתרת חלון ה-PowerShell השחור
try {
    Add-Type -Name ConsoleWin -Namespace Native -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
'@
    [void][Native.ConsoleWin]::ShowWindow([Native.ConsoleWin]::GetConsoleWindow(), 0)
} catch { }

# ---------- מנוע קובצי PAC (C#) ----------
$engineSource = @'
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
'@
try {
    Add-Type -TypeDefinition $engineSource -Language CSharp
} catch {
    Show-Error ("טעינת המנוע נכשלה:`n" + $_.Exception.Message)
    exit 1
}

# ---------- הגדרות (נתיבי הכלים נשמרים בין הפעלות) ----------
$settingsDir = Join-Path $env:APPDATA 'QlyxFlash'
$settingsPath = Join-Path $settingsDir 'settings.json'
$settings = @{ SpdDump = ''; ResearchDownload = ''; LastPac = '' }
try {
    if (Test-Path $settingsPath) {
        $j = Get-Content $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($k in @($settings.Keys)) { if ($j.$k) { $settings[$k] = [string]$j.$k } }
    }
} catch { }

function Save-Settings {
    try {
        [void](New-Item -ItemType Directory -Force -Path $settingsDir)
        $settings | ConvertTo-Json | Set-Content -Path $settingsPath -Encoding UTF8
    } catch { }
}

# ---------- מצב ----------
$script:pac = $null        # הקובץ שנטען
$script:pacOk = $false     # עבר את כל הבדיקות
$script:pacWarn = ''       # אזהרות שלא חוסמות

# ---------- עזרי ממשק ----------
$font = New-Object Drawing.Font('Segoe UI', 10)
$bold = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold)
$big = New-Object Drawing.Font('Segoe UI', 12, [Drawing.FontStyle]::Bold)

function New-Label([string]$text, [switch]$Bold, [string]$Color) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $text
    $l.AutoSize = $true
    $l.MaximumSize = New-Object Drawing.Size(820, 0)
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
    $t.AutoScroll = $true
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

function Select-File([string]$title, [string]$filter, [string]$current) {
    $dlg = New-Object Windows.Forms.OpenFileDialog
    $dlg.Title = $title
    $dlg.Filter = $filter
    if ($current -and (Test-Path $current)) { $dlg.InitialDirectory = Split-Path $current }
    if ($dlg.ShowDialog() -eq 'OK') { return $dlg.FileName }
    return $null
}

function Format-Size([long]$n) {
    if ($n -ge 1MB) { return ('{0:N1} MB' -f ($n / 1MB)) }
    if ($n -ge 1KB) { return ('{0:N1} KB' -f ($n / 1KB)) }
    return "$n B"
}

# ---------- החלון הראשי ----------
$form = New-Object Windows.Forms.Form
$form.Text = $appTitle
$form.Font = $font
$form.RightToLeft = 'Yes'
$form.RightToLeftLayout = $true
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object Drawing.Size(900, 680)
$form.MinimumSize = New-Object Drawing.Size(740, 560)

$tabs = New-Object Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$tabs.RightToLeftLayout = $true
$form.Controls.Add($tabs)

# ===== לשונית 1: קובץ הקושחה =====
$p1 = New-Page '1. קובץ הקושחה'
Add-Row $p1 (New-Label 'בחר את קובץ הקושחה (סיומת .pac) שקיבלת מהיבואן או ממעבדה. התוכנה תבדוק שהקובץ שלם, לא פגום ומתאים לדגם, לפני שתצרוב אותו.')
$lblPacPath = New-Label 'לא נבחר קובץ.'
$lblPacPath.RightToLeft = 'No'
$btnPac = New-Button 'בחר קובץ PAC...' {
    $f = Select-File 'בחר קובץ קושחה' 'קושחת Unisoc (*.pac)|*.pac|כל הקבצים (*.*)|*.*' $settings.LastPac
    if ($f) { Open-Pac $f }
}
Add-Row $p1 (New-Flow $btnPac $lblPacPath)

$lblPacInfo = New-Label '' -Bold
Add-Row $p1 $lblPacInfo
$lblPacStatus = New-Label ''
$lblPacStatus.Font = $big
Add-Row $p1 $lblPacStatus

$progCrc = New-Object Windows.Forms.ProgressBar
$progCrc.Dock = 'Fill'
$progCrc.RightToLeftLayout = $true
$progCrc.Visible = $false
Add-Row $p1 $progCrc

$lvFiles = New-Object Windows.Forms.ListView
$lvFiles.View = 'Details'
$lvFiles.FullRowSelect = $true
$lvFiles.GridLines = $true
$lvFiles.RightToLeftLayout = $true
[void]$lvFiles.Columns.Add('מזהה', 130)
[void]$lvFiles.Columns.Add('שם קובץ', 240)
[void]$lvFiles.Columns.Add('סוג', 80)
[void]$lvFiles.Columns.Add('גודל', 100)
[void]$lvFiles.Columns.Add('כתובת', 120)
Add-Row $p1 $lvFiles -Fill

function Set-Status([string]$text, [string]$color) {
    $lblPacStatus.Text = $text
    $lblPacStatus.ForeColor = [Drawing.Color]::FromName($color)
}

function Open-Pac([string]$path) {
    $script:pac = $null
    $script:pacOk = $false
    $script:pacWarn = ''
    $lvFiles.Items.Clear()
    $lblPacInfo.Text = ''
    $lblPacPath.Text = $path
    $settings.LastPac = $path
    Save-Settings
    Update-FlashTab

    try {
        $p = [Qlyx.PacFile]::Open($path)
    } catch {
        $ex = $_.Exception
        if ($ex.InnerException) { $ex = $ex.InnerException }
        Set-Status ('❌ הקובץ לא תקין: ' + $ex.Message) 'Firebrick'
        return
    }

    $lblPacInfo.Text = "שם הקושחה: $($p.FwName)`nגרסה: $($p.FwVersion)`nכינוי: $($p.FwAlias)     פורמט: $($p.PacVersion)     גודל: $(Format-Size $p.FileLength)"
    foreach ($en in $p.Entries) {
        $it = New-Object Windows.Forms.ListViewItem($en.Id)
        [void]$it.SubItems.Add($en.Name)
        [void]$it.SubItems.Add([Qlyx.PacFile]::TypeName($en.Type))
        [void]$it.SubItems.Add($(if ($en.Size -gt 0) { Format-Size $en.Size } else { '' }))
        [void]$it.SubItems.Add($(if ($en.FirstAddr -ne 0) { '0x{0:X}' -f $en.FirstAddr } else { '' }))
        [void]$lvFiles.Items.Add($it)
    }

    $problems = $p.StructureProblems()
    if ($problems.Count -gt 0) {
        Set-Status ("❌ אסור לצרוב את הקובץ הזה:`n" + ($problems -join "`n")) 'Firebrick'
        return
    }

    # בדיקת CRC של כל התוכן – מזהה קובץ שנפגם בהורדה
    Set-Status 'בודק את שלמות הקובץ...' 'DimGray'
    $progCrc.Value = 0
    $progCrc.Visible = $true
    $form.Cursor = 'WaitCursor'
    try {
        $actual = [uint16]0
        $cb = [Action[int]] { param($pct) $progCrc.Value = $pct; [Windows.Forms.Application]::DoEvents() }
        $crcOk = $p.CheckDataCrc($cb, [ref]$actual)
    } finally {
        $progCrc.Visible = $false
        $form.Cursor = 'Default'
    }
    if (-not $crcOk) {
        Set-Status ("❌ הקובץ פגום (בדיקת CRC נכשלה: 0x{0:X4}, צפוי 0x{1:X4}).`nהורד אותו שוב ממקור אמין." -f $actual, $p.DataCrc) 'Firebrick'
        return
    }

    $fdls = @($p.Entries | Where-Object { $_.IsFdl -and $_.HasData })
    $warn = @()
    $ident = "$($p.FwName) $($p.FwVersion) $($p.FwAlias) $([IO.Path]::GetFileName($path))"
    if ($ident -notmatch 'Q8') {
        $warn += "⚠ לא מצאתי 'Q8' בשם הקושחה. ודא שהיא בדיוק לדגם QLYX Q8 – קושחה של דגם אחר עלולה להשבית את הטלפון."
    }
    if ($fdls.Count -eq 0) {
        $warn += '⚠ אין בקובץ קבצי FDL (טוען הצריבה). ייתכן שזו לא קושחה מלאה.'
    }

    $script:pac = $p
    $script:pacOk = $true
    $script:pacWarn = $warn -join "`n"
    if ($warn.Count -gt 0) {
        Set-Status ("✔ הקובץ שלם, אבל שים לב:`n" + $script:pacWarn) 'DarkOrange'
    } else {
        Set-Status '✔ הקובץ שלם ותקין. אפשר לעבור ללשונית הבאה.' 'ForestGreen'
    }
    Update-FlashTab
}

# ===== לשונית 2: חיבור הטלפון במצב צריבה =====
$p2 = New-Page '2. חיבור הטלפון'
Add-Row $p2 (New-Label 'כדי לצרוב, הטלפון צריך להתחבר למחשב ב"מצב צריבה" (Download mode). כך עושים את זה:' -Bold)
Add-Row $p2 (New-Label @'
1. כבה את הטלפון לגמרי. אם הסוללה נשלפת – הוצא אותה, חכה 10 שניות והחזר אותה.
2. לחץ והחזק את "מקש הצריבה" – ואז חבר את כבל ה-USB למחשב, עדיין בלחיצה.
3. המשך להחזיק כ-5 שניות וצפה בחלון הזה.

איזה מקש? היצרן לא מפרסם. בטלפוני מקשים עם שבב Unisoc זה בדרך כלל אחד מאלה:
   *   ,   0   ,   מקש OK האמצעי   ,   מקש החיוג (ירוק)   ,   9   ,   #
נסה אותם אחד אחד. כשהמקש הנכון – תראה כאן "מחובר במצב צריבה" באופן קבוע.
אם זה מופיע לשנייה ונעלם – המקש לא נכון (הטלפון עבר למצב טעינה). נתק, והתחל שוב עם מקש אחר.
'@)

$lblUsb = New-Label 'מחפש...'
$lblUsb.Font = $big
Add-Row $p2 $lblUsb
$lblUsbSeen = New-Label ''
Add-Row $p2 $lblUsbSeen
Add-Row $p2 (New-Label @'
אם כתוב "מחובר – אבל חסר דרייבר": התקן את הדרייבר של Spreadtrum/Unisoc (SPD Driver, מגיע בדרך כלל יחד עם ResearchDownload), ונסה שוב.
'@ -Color 'DimGray')

$script:lastSeen = $null
$usbTimer = New-Object Windows.Forms.Timer
$usbTimer.Interval = 500
$usbTimer.Add_Tick({
    try {
        $dev = @(Get-CimInstance -ClassName Win32_PnPEntity -Filter "PNPDeviceID LIKE '%VID_1782&PID_4D00%'" -ErrorAction Stop)
    } catch { $dev = @() }
    if ($dev.Count -gt 0) {
        $script:lastSeen = Get-Date
        if ($dev[0].ConfigManagerErrorCode -ne 0) {
            $lblUsb.Text = '● הטלפון מחובר במצב צריבה – אבל חסר דרייבר'
            $lblUsb.ForeColor = [Drawing.Color]::DarkOrange
        } else {
            $lblUsb.Text = '● הטלפון מחובר במצב צריבה'
            $lblUsb.ForeColor = [Drawing.Color]::ForestGreen
        }
        $lblUsbSeen.Text = "שם ההתקן ב-Windows: $($dev[0].Name)"
    } else {
        $lblUsb.Text = '○ לא מחובר במצב צריבה'
        $lblUsb.ForeColor = [Drawing.Color]::DimGray
        if ($script:lastSeen) {
            $sec = [int]((Get-Date) - $script:lastSeen).TotalSeconds
            $lblUsbSeen.Text = "הטלפון זוהה במצב צריבה לפני $sec שניות ואז התנתק."
        }
    }
})

# ===== לשונית 3: גיבוי =====
$p3 = New-Page '3. גיבוי (מומלץ מאוד)'
Add-Row $p3 (New-Label 'לפני שצורבים – מגבים את הקושחה שיש עכשיו בטלפון. אם משהו ישתבש, אפשר יהיה להחזיר אותה.' -Bold)
Add-Row $p3 (New-Label @'
הגיבוי נעשה עם הכלי החינמי spd_dump (פרויקט spreadtrum_flash). הורד את spd_dump.exe מ:
https://github.com/ilyakurdyukov/spreadtrum_flash/releases

חשוב: spd_dump עובד עם דרייבר WinUSB (מתקינים עם Zadig – ראה README), ולא עם הדרייבר של ResearchDownload.
אחרי הגיבוי, כדי לצרוב, מחזירים את הדרייבר המקורי במנהל ההתקנים ("החזר מנהל התקן לגרסה קודמת" / הסרה והתקנה מחדש).
התוכנה לוקחת את קובצי ה-FDL מתוך קובץ ה-PAC שבחרת בלשונית 1, ולכן צריך לבחור אותו קודם.
'@)

$lblSpd = New-Label $(if ($settings.SpdDump) { $settings.SpdDump } else { 'spd_dump.exe לא נבחר.' })
$lblSpd.RightToLeft = 'No'
$btnSpd = New-Button 'בחר את spd_dump.exe...' {
    $f = Select-File 'בחר את spd_dump.exe' 'spd_dump.exe|spd_dump*.exe|כל הקבצים (*.*)|*.*' $settings.SpdDump
    if ($f) { $settings.SpdDump = $f; $lblSpd.Text = $f; Save-Settings }
}
Add-Row $p3 (New-Flow $btnSpd $lblSpd)

$btnBackup = New-Button 'התחל גיבוי' { Start-Backup }
$btnBackup.Font = $bold
Add-Row $p3 (New-Flow $btnBackup)
$lblBackup = New-Label ''
Add-Row $p3 $lblBackup

function Start-Backup {
    if (-not $script:pac) { Show-Error 'קודם בחר קובץ PAC תקין בלשונית 1 – ממנו נלקחים קובצי ה-FDL.'; return }
    if (-not ($settings.SpdDump -and (Test-Path $settings.SpdDump))) { Show-Error 'קודם בחר את spd_dump.exe.'; return }
    $fdls = @($script:pac.Entries | Where-Object { $_.IsFdl -and $_.HasData } | Sort-Object { $_.Id })
    $fdl1 = $fdls | Where-Object { $_.Id -match '^FDL1?$' } | Select-Object -First 1
    $fdl2 = $fdls | Where-Object { $_.Id -match '^FDL2$' } | Select-Object -First 1
    if (-not $fdl1 -or -not $fdl2 -or $fdl1.FirstAddr -eq 0 -or $fdl2.FirstAddr -eq 0) {
        Show-Error "בקובץ ה-PAC אין FDL1 ו-FDL2 עם כתובות טעינה, ולכן אי אפשר לגבות איתו.`nבטלפוני 4G עם Unisoc (כמו T107/T117) צריך את שניהם."
        return
    }

    $dir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) ('QLYX-Q8-Backup ' + (Get-Date -Format 'yyyy-MM-dd HH-mm'))
    [void](New-Item -ItemType Directory -Force -Path $dir)
    $fdlDir = Join-Path $dir 'fdl'
    [void](New-Item -ItemType Directory -Force -Path $fdlDir)
    try {
        $f1 = $script:pac.Extract($fdl1, $fdlDir)
        $f2 = $script:pac.Extract($fdl2, $fdlDir)
    } catch {
        Show-Error ('חילוץ ה-FDL נכשל: ' + $_.Exception.Message); return
    }

    # הפקודה לפי ההוראות של spreadtrum_flash לטלפוני מקשים 4G (UMS9117/T107/T127)
    $cmd = @(
        '@echo off'
        'chcp 65001 >nul'
        'echo.'
        'echo  Hold the boot key and connect the phone to USB now...'
        'echo  (Waiting up to 5 minutes)'
        'echo.'
        ('"{0}" --wait 300 keep_charge 1 fdl "fdl\{1}" 0x{2:x} blk_size 0x1000 fdl "fdl\{3}" 0x{4:x} read_flash 0x80000001 0 auto boot0.bin read_flash 0x80000002 0 auto boot1.bin read_flash 0x80000003 0 auto kernel.bin read_flash 0x80000004 0 auto user.bin' -f `
            $settings.SpdDump, $fdl1.Name, $fdl1.FirstAddr, $fdl2.Name, $fdl2.FirstAddr)
        'echo.'
        'if errorlevel 1 (echo  *** BACKUP FAILED *** ) else (echo  Backup finished. Keep this folder safe!)'
        'pause'
    ) -join "`r`n"
    $bat = Join-Path $dir 'backup.cmd'
    [IO.File]::WriteAllText($bat, $cmd, (New-Object Text.UTF8Encoding($false)))
    $info = "קושחה: $($script:pac.FwName)`r`nגרסה: $($script:pac.FwVersion)`r`nקובץ: $($script:pac.Path)`r`nתאריך: $(Get-Date)`r`n"
    [IO.File]::WriteAllText((Join-Path $dir 'info.txt'), $info, (New-Object Text.UTF8Encoding($true)))

    Start-Process -FilePath $env:ComSpec -ArgumentList '/c', 'backup.cmd' -WorkingDirectory $dir
    $lblBackup.Text = "נפתח חלון גיבוי. עכשיו: החזק את מקש הצריבה וחבר את הטלפון.`nהגיבוי יישמר בתיקייה:`n$dir`nבסוף אמורים להיות שם 4 קבצים: boot0.bin, boot1.bin, kernel.bin, user.bin."
}

# ===== לשונית 4: צריבה =====
$p4 = New-Page '4. צריבה'
$lblFlashState = New-Label ''
$lblFlashState.Font = $big
Add-Row $p4 $lblFlashState
Add-Row $p4 (New-Label @'
הצריבה עצמה נעשית בכלי הרשמי של Unisoc – ResearchDownload (נקרא גם "SPD Research Tool" / "SPD Flash Tool").
זה הכלי שהמעבדות משתמשות בו, והוא הבטוח ביותר. בחר אותו פעם אחת, ואז לחץ "פתח".
'@)

$lblRd = New-Label $(if ($settings.ResearchDownload) { $settings.ResearchDownload } else { 'ResearchDownload.exe לא נבחר.' })
$lblRd.RightToLeft = 'No'
$btnRdPick = New-Button 'בחר את ResearchDownload.exe...' {
    $f = Select-File 'בחר את ResearchDownload.exe' 'ResearchDownload|ResearchDownload*.exe;UpgradeDownload*.exe|כל הקבצים (*.*)|*.*' $settings.ResearchDownload
    if ($f) { $settings.ResearchDownload = $f; $lblRd.Text = $f; Save-Settings }
}
Add-Row $p4 (New-Flow $btnRdPick $lblRd)

$btnRdOpen = New-Button 'פתח את ResearchDownload' { Open-ResearchDownload }
$btnRdOpen.Font = $bold
$btnCopyPath = New-Button 'העתק את נתיב קובץ ה-PAC' {
    if ($script:pac) { [Windows.Forms.Clipboard]::SetText($script:pac.Path); Show-Info 'הנתיב הועתק. הדבק אותו (Ctrl+V) בחלון בחירת הקובץ של ResearchDownload.' }
}
Add-Row $p4 (New-Flow $btnRdOpen $btnCopyPath)

Add-Row $p4 (New-Label 'שלבי הצריבה ב-ResearchDownload:' -Bold)
Add-Row $p4 (New-Label @'
1. לחץ על הכפתור הראשון משמאל (גלגל שיניים – "Load packet") ובחר את קובץ ה-PAC.
   (אפשר להדביק את הנתיב שהעתקת עם הכפתור למעלה.) חכה עד שהטעינה תסתיים.
2. לחץ על כפתור ההפעלה (משולש – "Start downloading"). הכלי יחכה לטלפון.
3. כבה את הטלפון (הוצא והחזר סוללה אם אפשר), החזק את מקש הצריבה וחבר את ה-USB.
4. חכה עד שכתוב "Passed" בירוק. אל תנתק את הכבל באמצע – ניתוק באמצע עלול להשבית את הטלפון!
5. לחץ "Stop" (ריבוע), נתק את הכבל והדלק את הטלפון. ההדלקה הראשונה יכולה לקחת יותר זמן.

אם כתוב "Failed" – אל תיבהל. כל עוד הטלפון נכנס למצב צריבה, אפשר תמיד לנסות שוב.
'@)

function Update-FlashTab {
    if ($script:pacOk) {
        if ($script:pacWarn) {
            $lblFlashState.Text = "הקובץ נבדק ושלם, עם אזהרות:`n$($script:pacWarn)"
            $lblFlashState.ForeColor = [Drawing.Color]::DarkOrange
        } else {
            $lblFlashState.Text = "✔ מוכן לצריבה: $($script:pac.FwVersion)"
            $lblFlashState.ForeColor = [Drawing.Color]::ForestGreen
        }
    } else {
        $lblFlashState.Text = 'קודם בחר ובדוק קובץ קושחה בלשונית 1.'
        $lblFlashState.ForeColor = [Drawing.Color]::Firebrick
    }
    $btnCopyPath.Enabled = [bool]$script:pac
}

function Open-ResearchDownload {
    if (-not $script:pacOk) {
        Show-Error 'לא נבחר קובץ קושחה תקין. בחר ובדוק אותו בלשונית 1 לפני הצריבה.'
        return
    }
    if ($script:pacWarn -and -not (Ask ("יש אזהרות לגבי הקובץ:`n`n$($script:pacWarn)`n`nלהמשיך בכל זאת?") 'Warning')) { return }
    if (-not ($settings.ResearchDownload -and (Test-Path $settings.ResearchDownload))) {
        Show-Error 'קודם בחר את ResearchDownload.exe.'
        return
    }
    if (-not (Ask "לפני שממשיכים:`n• גיבית את הקושחה הנוכחית (לשונית 3)?`n• הסוללה טעונה לפחות ל-50%?`n• הכבל תקין ומחובר ישירות למחשב (לא דרך מפצל)?`n`nלפתוח את ResearchDownload?")) { return }
    try {
        [Windows.Forms.Clipboard]::SetText($script:pac.Path)
    } catch { }
    Start-Process -FilePath $settings.ResearchDownload -WorkingDirectory (Split-Path $settings.ResearchDownload)
}

# ---------- הרכבה והפעלה ----------
foreach ($p in @($p1, $p2, $p3, $p4)) { [void]$tabs.TabPages.Add($p) }
Update-FlashTab
$form.Add_Shown({
    $usbTimer.Start()
    if ($settings.LastPac -and (Test-Path $settings.LastPac)) { Open-Pac $settings.LastPac }
})
$form.Add_FormClosed({ $usbTimer.Stop() })
[void]$form.ShowDialog()
