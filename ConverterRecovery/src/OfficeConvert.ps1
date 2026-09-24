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
