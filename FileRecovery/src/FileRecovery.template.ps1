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
#__ENGINE__#
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
