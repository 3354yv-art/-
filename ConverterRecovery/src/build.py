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
out = out.replace('\r\n', '\n').replace('\n', '\r\n')
root = os.path.join(here, '..')
open(os.path.join(root, 'ConverterRecovery.ps1'), 'w', encoding='utf-8-sig', newline='').write(out)
bat = '@echo off\r\ncd /d "%~dp0"\r\nstart "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0ConverterRecovery.ps1"\r\n'
open(os.path.join(root, 'Start.bat'), 'w', encoding='ascii', newline='').write(bat)
print('built')
