# ממיר ומשחזר – שחזור, המרה והעברת קבצים ב-Windows
# הפעלה: לחיצה כפולה על "ממיר ומשחזר.cmd" – קובץ אחד שמכיל את כל התוכנה

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
# כשהתוכנה מופעלת מהקובץ היחיד (.cmd), קובץ ה-cmd מעביר את הנתיב שלו במשתנה CR_SELF
$SelfPath = if ($env:CR_SELF) { $env:CR_SELF } else { $PSCommandPath }
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and $env:CONVERTER_NO_ELEVATE -ne '1') {
    try {
        if ($SelfPath -like '*.cmd') {
            Start-Process -FilePath $SelfPath -Verb RunAs -WindowStyle Hidden
        } else {
            Start-Process powershell.exe -Verb RunAs -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', "`"$SelfPath`"")
        }
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

$AppDir = Split-Path -Parent $SelfPath
$WorkDir = Join-Path $env:LOCALAPPDATA 'ConverterRecovery'
[void][IO.Directory]::CreateDirectory($WorkDir)

# ---------- המנוע (C#) – מקומפל פעם אחת ונשמר במטמון ----------
$engineSource = @'
#__ENGINE__#
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
#__OFFICE__#
'@

function Format-Size([long]$b) { [Recovery.Scanner]::FormatSize($b) }
function Get-Brush([string]$hex) { (New-Object Windows.Media.BrushConverter).ConvertFromString($hex) }

# ---------- החלון ----------
$xaml = @'
#__XAML__#
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
