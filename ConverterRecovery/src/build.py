# בונה את ConverterRecovery.ps1 הסופי: מטמיע בתוכו את המנוע (C#), החלון (XAML) וסקריפט המרת המסמכים.
# שומר UTF-8 עם BOM ו-CRLF (נדרש ל-PowerShell 5.1)
import os, re
here = os.path.dirname(os.path.abspath(__file__))
def read(name): return open(os.path.join(here, name), encoding='utf-8-sig').read()

# מאחדים את קבצי ה-C#: כל שורות ה-using למעלה, ואחריהן גוף הקבצים
usings, bodies = [], []
for name in ('Engine.cs', 'Tools.cs'):
    body = []
    for line in read(name).splitlines():
        if re.match(r'^using [\w.]+;$', line):
            if line not in usings: usings.append(line)
        else:
            body.append(line)
    bodies.append('\n'.join(body).strip('\n'))
engine = '\n'.join(usings) + '\n\n' + '\n\n'.join(bodies)

parts = {'#__ENGINE__#': engine, '#__XAML__#': read('MainWindow.xaml').strip('\n'), '#__OFFICE__#': read('OfficeConvert.ps1').strip('\n')}
out = read('ConverterRecovery.template.ps1')
for key, text in parts.items():
    assert "\n'@" not in '\n' + text, key   # אסור שורה שמתחילה ב-'@ בתוך here-string
    assert key in out, key
    out = out.replace(key, text)
# קובץ אחד: כותרת קטנה של cmd שמפעילה PowerShell על אותו קובץ עצמו.
# עבור PowerShell הכותרת היא הערה (<# ... #>); עבור cmd היא פקודות רגילות. בלי BOM, כדי ש-cmd יקרא את השורה הראשונה.
header = """<# : batch
@echo off
set "CR_SELF=%~f0"
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -Command "iex ([IO.File]::ReadAllText($env:CR_SELF, [Text.Encoding]::UTF8))"
exit /b
#>
"""
assert all(ord(c) < 128 for c in header.split('\n', 1)[1])
out = header + out
out = out.replace('\r\n', '\n').replace('\n', '\r\n')
dist = os.path.join(here, '..', '..', 'ממיר ומשחזר.cmd')
open(dist, 'w', encoding='utf-8', newline='').write(out)
print('built', os.path.abspath(dist))
