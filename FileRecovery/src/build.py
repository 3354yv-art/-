# בונה את FileRecovery.ps1 הסופי: מטמיע את Engine.cs בתוך הסקריפט, שומר UTF-8 עם BOM ו-CRLF (נדרש ל-PowerShell 5.1)
import os
here = os.path.dirname(os.path.abspath(__file__))
tpl = open(os.path.join(here, 'FileRecovery.template.ps1'), encoding='utf-8').read()
eng = open(os.path.join(here, 'Engine.cs'), encoding='utf-8').read().strip('\n')
assert "\n'@" not in '\n' + eng
out = tpl.replace('#__ENGINE__#', eng).replace('\r\n', '\n').replace('\n', '\r\n')
open(os.path.join(here, '..', 'FileRecovery.ps1'), 'w', encoding='utf-8-sig', newline='').write(out)
bat = '@echo off\r\ncd /d "%~dp0"\r\nstart "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0FileRecovery.ps1"\r\n'
open(os.path.join(here, '..', 'Start.bat'), 'w', encoding='ascii', newline='').write(bat)
print('built')
