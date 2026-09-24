; ADB סטודיו — סקריפט התקנה (Inno Setup 6)
; נבנה אוטומטית ב-GitHub Actions: ‎.github/workflows/build.yml

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

[Setup]
AppId={{6B2F3C8E-4A1D-4E7B-9C35-ADB5D10F0001}
AppName=ADB סטודיו
AppVersion={#AppVersion}
AppVerName=ADB סטודיו {#AppVersion}
AppPublisher=ADB Studio
DefaultDirName={autopf}\ADB Studio
DefaultGroupName=ADB סטודיו
DisableProgramGroupPage=yes
DisableDirPage=yes
DisableReadyPage=yes
; התקנה למשתמש הנוכחי — בלי בקשת הרשאות מנהל
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\dist
OutputBaseFilename=ADB-Studio-Setup
SetupIconFile=icon.ico
UninstallDisplayIcon={app}\ADBStudio.exe
UninstallDisplayName=ADB סטודיו
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes

[Languages]
Name: "hebrew"; MessagesFile: "compiler:Languages\Hebrew.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "..\dist\ADBStudio\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\ADB סטודיו"; Filename: "{app}\ADBStudio.exe"
Name: "{autodesktop}\ADB סטודיו"; Filename: "{app}\ADBStudio.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\ADBStudio.exe"; Description: "{cm:LaunchProgram,ADB סטודיו}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{app}\platform-tools\adb.exe"; Parameters: "kill-server"; Flags: runhidden skipifdoesntexist; RunOnceId: "KillAdb"

[Code]
// שרת ה-ADB נועל את הקבצים שלו — עוצרים אותו לפני עדכון
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Code: Integer;
  Adb: String;
begin
  Adb := ExpandConstant('{app}\platform-tools\adb.exe');
  if FileExists(Adb) then
    Exec(Adb, 'kill-server', '', SW_HIDE, ewWaitUntilTerminated, Code);
  Result := '';
end;
