; SysPilot Installer (Inno Setup)
; Version 0.9.4 beta - x64

#define MyAppName "SysPilot"
#define MyAppVersion "0.9.4"
#define MyAppPublisher "Habermann76"
#define MyAppURL "https://github.com/Habermann76/SysPilot"
#define MyAppExeName "SysPilot-GUI.ps1"

[Setup]
AppId={{A1B2C3D4-E5F6-7890-ABCD-EF1234567890}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion} beta
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}/issues
AppUpdatesURL={#MyAppURL}/releases
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
AllowNoIcons=yes
LicenseFile=LICENSE
OutputDir=installer-output
OutputBaseFilename=SysPilot-Setup-0.9.4.1-beta-x64
SetupIconFile=
Compression=lzma
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0

[Languages]
Name: "german"; MessagesFile: "compiler:Languages\German.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"
Name: "autopilot"; Description: "Autopilot bei Windows-Anmeldung starten (empfohlen)"; GroupDescription: "Automatiken (Haeckchen nach Wunsch entfernen):"
Name: "smartboost"; Description: "Smart Boost: RAM automatisch freigeben, wenn er knapp wird (empfohlen)"; GroupDescription: "Automatiken (Haeckchen nach Wunsch entfernen):"
Name: "guardian"; Description: "Guardian: SysPilot startet mit Windows im Infobereich (Ausgeblendete Symbole) und wird neu gestartet, falls es nicht laeuft (empfohlen)"; GroupDescription: "Automatiken (Haeckchen nach Wunsch entfernen):"
Name: "runasadmin"; Description: "SysPilot immer als Administrator ausfuehren (empfohlen - sonst funktionieren Plaene/Dienste nicht)"; GroupDescription: "Automatiken (Haeckchen nach Wunsch entfernen):"

[Files]
Source: "SysPilot.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "SysPilot-GUI.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "setup-automation.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "config.json"; DestDir: "{app}"; Flags: ignoreversion
Source: "version.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "stop-syspilot.ps1"; Flags: dontcopy
Source: "README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "INSTALL.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "DEBUG.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "ROADMAP.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "modules\*.psm1"; DestDir: "{app}\modules"; Flags: ignoreversion recursesubdirs
Source: "scripts\*.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion recursesubdirs

[Dirs]
Name: "{app}\backup"
Name: "{app}\logs"
Name: "{app}\tools"

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\SysPilot-GUI.ps1"""; Comment: "SysPilot GUI starten"
Name: "{group}\{#MyAppName} (Text-Menue)"; Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\SysPilot.ps1"""; Comment: "SysPilot Text-Menue starten"
Name: "{group}\{#MyAppName} Dokumentation"; Filename: "{app}\README.md"
Name: "{autodesktop}\{#MyAppName}"; Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\SysPilot-GUI.ps1"""; Tasks: desktopicon

[Run]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\setup-automation.ps1"" -RestoreUserSettings"; Flags: runhidden waituntilterminated
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\setup-automation.ps1"" -Autopilot"; Tasks: autopilot; Flags: runhidden waituntilterminated
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\setup-automation.ps1"" -SmartBoost"; Tasks: smartboost; Flags: runhidden waituntilterminated
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\setup-automation.ps1"" -Guardian"; Tasks: guardian; Flags: runhidden waituntilterminated
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\setup-automation.ps1"" -RunAsAdmin"; Tasks: runasadmin; Flags: runhidden waituntilterminated
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\SysPilot-GUI.ps1"""; Description: "SysPilot jetzt starten"; Flags: nowait postinstall skipifsilent
; Stilles Update (z. B. aus SysPilot heraus): SysPilot danach unsichtbar im Tray wieder starten
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\SysPilot-GUI.ps1"" -StartHidden"; Flags: nowait runhidden; Check: WizardSilent

[UninstallRun]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\setup-automation.ps1"" -Undo"; Flags: runhidden waituntilterminated; RunOnceId: "syspilot-cleanup"

[UninstallDelete]
Type: filesandordirs; Name: "{app}\logs"
Type: filesandordirs; Name: "{app}\tools"

[Code]
// Vor der Installation: laufendes SysPilot beenden (Update) und eigene Einstellungen sichern
procedure CurrentStepChanged(CurStep: TSetupStep);
var
  rc: Integer;
begin
  if CurStep = ssInstall then
  begin
    ExtractTemporaryFile('stop-syspilot.ps1');
    Exec('powershell.exe', '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + ExpandConstant('{tmp}\stop-syspilot.ps1') + '"', '', SW_HIDE, ewWaitUntilTerminated, rc);
    if FileExists(ExpandConstant('{app}\config.json')) then
      FileCopy(ExpandConstant('{app}\config.json'), ExpandConstant('{app}\config.user-backup.json'), False);
  end;
end;

