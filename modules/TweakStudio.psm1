# ======================================================================
# SysPilot TweakStudio.psm1 - "Tweak-Studio": eigener Katalog von
# Registry-/Dienst-Tweaks mit Statusanzeige, Einzel-Umschaltung,
# .reg-Backup vor jeder Aenderung, Favoriten und Rueckgaengigmachung.
# Eigenstaendige Implementierung (kein UWT-Nachbau, eigene Namen/Werte).
# ======================================================================

$script:TweakFavPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'SysPilot\tweak-favorites.txt'

$script:TweakDefs = @(
    # ---------------- Kontextmenue (Datei-Explorer, Ordner-Hintergrund) ----------------
    @{ Key='pshere'; Cat='Kontextmenue'; Name='PowerShell: hier oeffnen';
       Desc='Kontextmenue auf Ordner-Hintergrund: "PowerShell hier" startet pwsh/ powershell im Ordner';
       Admin=$false; Risk='low'; Restart='explorer';
       On=@(
           @{Path='HKCU:\Software\Classes\Directory\Background\shell\SysPilotPS'; Kind='NewKey'},
           @{Path='HKCU:\Software\Classes\Directory\Background\shell\SysPilotPS'; Kind='SetDefault'; On='PowerShell hier'; Off=''},
           @{Path='HKCU:\Software\Classes\Directory\Background\shell\SysPilotPS'; Kind='SetValue'; Name='Icon'; On='powershell.exe,0'; Type='String'},
           @{Path='HKCU:\Software\Classes\Directory\Background\shell\SysPilotPS\command'; Kind='NewKey'},
           @{Path='HKCU:\Software\Classes\Directory\Background\shell\SysPilotPS\command'; Kind='SetDefault'; On='powershell.exe -NoExit -Command "Set-Location -LiteralPath ''%V''"'; Off=''}
       );
       Off=@(
           @{Path='HKCU:\Software\Classes\Directory\Background\shell\SysPilotPS'; Kind='DeleteKey'}
       )
    },
    @{ Key='psadmin'; Cat='Kontextmenue'; Name='PowerShell: als Admin oeffnen';
       Desc='Kontextmenue: "PowerShell (Admin)" oeffnet eine elevierte Shell im Ordner';
       Admin=$false; Risk='low'; Restart='explorer';
       On=@(
           @{Path='HKCU:\Software\Classes\Directory\Background\shell\SysPilotPSAdmin'; Kind='NewKey'},
           @{Path='HKCU:\Software\Classes\Directory\Background\shell\SysPilotPSAdmin'; Kind='SetDefault'; On='PowerShell als Admin'; Off=''},
           @{Path='HKCU:\Software\Classes\Directory\Background\shell\SysPilotPSAdmin'; Kind='SetValue'; Name='Icon'; On='powershell.exe,0'; Type='String'},
           @{Path='HKCU:\Software\Classes\Directory\Background\shell\SysPilotPSAdmin\command'; Kind='NewKey'},
           @{Path='HKCU:\Software\Classes\Directory\Background\shell\SysPilotPSAdmin\command'; Kind='SetDefault'; On='powershell.exe -Command "Start-Process powershell -Verb RunAs -ArgumentList ''-NoExit'',''-Command'',''Set-Location -LiteralPath ''''%V''''''"'; Off=''}
       );
       Off=@(
           @{Path='HKCU:\Software\Classes\Directory\Background\shell\SysPilotPSAdmin'; Kind='DeleteKey'}
       )
    },
    @{ Key='termhere'; Cat='Kontextmenue'; Name='Terminal: hier oeffnen';
       Desc='Kontextmenue: Windows-Terminal (wt.exe) im Ordner; ohne Terminal = cmd';
       Admin=$false; Risk='low'; Restart='explorer';
       On=@(
           @{Path='HKCU:\Software\Classes\Directory\Background\shell\SysPilotTerm'; Kind='NewKey'},
           @{Path='HKCU:\Software\Classes\Directory\Background\shell\SysPilotTerm'; Kind='SetDefault'; On='Terminal hier'; Off=''},
           @{Path='HKCU:\Software\Classes\Directory\Background\shell\SysPilotTerm\command'; Kind='NewKey'},
           @{Path='HKCU:\Software\Classes\Directory\Background\shell\SysPilotTerm\command'; Kind='SetDefault'; On='wt.exe -d "%V"'; Off=''}
       );
       Off=@(
           @{Path='HKCU:\Software\Classes\Directory\Background\shell\SysPilotTerm'; Kind='DeleteKey'}
       )
    },
    @{ Key='editfile'; Cat='Kontextmenue'; Name='Editor: mit Datei oeffnen';
       Desc='Kontextmenue auf Dateien: oeffnet die Datei in Notepad++ falls vorhanden, sonst Notepad';
       Admin=$false; Risk='low'; Restart='explorer';
       On=@(
           @{Path='HKCU:\Software\Classes\*\shell\SysPilotEdit'; Kind='NewKey'},
           @{Path='HKCU:\Software\Classes\*\shell\SysPilotEdit'; Kind='SetDefault'; On='Editieren (SysPilot)'; Off=''},
           @{Path='HKCU:\Software\Classes\*\shell\SysPilotEdit\command'; Kind='NewKey'},
           @{Path='HKCU:\Software\Classes\*\shell\SysPilotEdit\command'; Kind='SetDefault'; On='notepad.exe "%1"'; Off=''}
       );
       Off=@(
           @{Path='HKCU:\Software\Classes\*\shell\SysPilotEdit'; Kind='DeleteKey'}
       )
    },
    @{ Key='copypath'; Cat='Kontextmenue'; Name='Kopieren: Pfad in Zwischenablage';
       Desc='Kontextmenue auf Ordnern/Dateien: kopiert den vollen Pfad (%V bzw. %1)';
       Admin=$false; Risk='low'; Restart='explorer';
       On=@(
           @{Path='HKCU:\Software\Classes\Directory\shell\SysPilotCopyPath'; Kind='NewKey'},
           @{Path='HKCU:\Software\Classes\Directory\shell\SysPilotCopyPath'; Kind='SetDefault'; On='Pfad kopieren'; Off=''},
           @{Path='HKCU:\Software\Classes\Directory\shell\SysPilotCopyPath\command'; Kind='NewKey'},
           @{Path='HKCU:\Software\Classes\Directory\shell\SysPilotCopyPath\command'; Kind='SetDefault'; On='cmd.exe /c echo %V|clip'; Off=''},
           @{Path='HKCU:\Software\Classes\*\shell\SysPilotCopyPathFile'; Kind='NewKey'},
           @{Path='HKCU:\Software\Classes\*\shell\SysPilotCopyPathFile'; Kind='SetDefault'; On='Pfad kopieren'; Off=''},
           @{Path='HKCU:\Software\Classes\*\shell\SysPilotCopyPathFile\command'; Kind='NewKey'},
           @{Path='HKCU:\Software\Classes\*\shell\SysPilotCopyPathFile\command'; Kind='SetDefault'; On='cmd.exe /c echo %1|clip'; Off=''}
       );
       Off=@(
           @{Path='HKCU:\Software\Classes\Directory\shell\SysPilotCopyPath'; Kind='DeleteKey'},
           @{Path='HKCU:\Software\Classes\*\shell\SysPilotCopyPathFile'; Kind='DeleteKey'}
       )
    },
    @{ Key='openhere'; Cat='Kontextmenue'; Name='Explorer: Ordner hier oeffnen';
       Desc='Verstecktes Windows-Feature aktivieren: "Ordner hier oeffnen" als Admin (UAC-bestaetigt)';
       Admin=$false; Risk='medium'; Restart='explorer';
       On=@(
           @{Path='HKCU:\Software\Classes\Directory\Background\shell\runas'; Kind='NewKey'},
           @{Path='HKCU:\Software\Classes\Directory\Background\shell\runas'; Kind='SetDefault'; On='Open console here'; Off=''},
           @{Path='HKCU:\Software\Classes\Directory\Background\shell\runas\command'; Kind='NewKey'},
           @{Path='HKCU:\Software\Classes\Directory\Background\shell\runas\command'; Kind='SetDefault'; On='cmd.exe /k pushd "%V"'; Off=''}
       );
       Off=@(
           @{Path='HKCU:\Software\Classes\Directory\Background\shell\runas'; Kind='DeleteKey'}
       )
    },

    # ---------------- Explorer & Taskleiste ----------------
    @{ Key='taskview'; Cat='Explorer & Taskleiste'; Name='Task-Ansicht-Button';
       Desc='ShowTaskViewButton 0/1 - Taskleiste anzeigen/ausblenden';
       Admin=$false; Risk='low'; Restart='explorer';
       On=@(@{Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Kind='SetValue'; Name='ShowTaskViewButton'; On=1; Off=0; Type='Dword'});
       Off=@(@{Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Kind='SetValue'; Name='ShowTaskViewButton'; On=1; Off=0; Type='Dword'})
    },
    @{ Key='menudelay'; Cat='Explorer & Taskleiste'; Name='Menue-Verzoegerung = 0';
       Desc='MenuShowDelay=0 - Kontextmenues oeffnen sofort';
       Admin=$false; Risk='low'; Restart='none';
       On=@(@{Path='HKCU:\Control Panel\Desktop'; Kind='SetValue'; Name='MenuShowDelay'; On='0'; Off='400'; Type='String'});
       Off=@(@{Path='HKCU:\Control Panel\Desktop'; Kind='SetValue'; Name='MenuShowDelay'; On='0'; Off='400'; Type='String'})
    },
    @{ Key='extensions'; Cat='Explorer & Taskleiste'; Name='Dateiendungen immer anzeigen';
       Desc='HideFileExt=0 - .txt/.exe/etc. sichtbar (empfohlen)';
       Admin=$false; Risk='low'; Restart='explorer';
       On=@(@{Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Kind='SetValue'; Name='HideFileExt'; On=0; Off=1; Type='Dword'});
       Off=@(@{Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Kind='SetValue'; Name='HideFileExt'; On=0; Off=1; Type='Dword'})
    },
    @{ Key='taskal'; Cat='Explorer & Taskleiste'; Name='Taskleiste linksbuendig';
       Desc='TaskbarAl=0 - Symbole links statt mittig (Win11-Style-Wechsel)';
       Admin=$false; Risk='low'; Restart='explorer';
       On=@(@{Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Kind='SetValue'; Name='TaskbarAl'; On=0; Off=1; Type='Dword'});
       Off=@(@{Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Kind='SetValue'; Name='TaskbarAl'; On=0; Off=1; Type='Dword'})
    },
    @{ Key='smallicons'; Cat='Explorer & Taskleiste'; Name='Kleine Taskleistensymbole';
       Desc='TaskbarSi=1 - mehr Platz auf der Taskleiste';
       Admin=$false; Risk='low'; Restart='explorer';
       On=@(@{Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Kind='SetValue'; Name='TaskbarSi'; On=1; Off=0; Type='Dword'});
       Off=@(@{Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Kind='SetValue'; Name='TaskbarSi'; On=1; Off=0; Type='Dword'})
    },
    @{ Key='searchbox'; Cat='Explorer & Taskleiste'; Name='Taskleisten-Suchfeld -> Symbol';
       Desc='SearchboxTaskbarMode=1 - nur Lupe statt breitem Suchfeld';
       Admin=$false; Risk='low'; Restart='explorer';
       On=@(@{Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search'; Kind='SetValue'; Name='SearchboxTaskbarMode'; On=1; Off=2; Type='Dword'});
       Off=@(@{Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search'; Kind='SetValue'; Name='SearchboxTaskbarMode'; On=1; Off=2; Type='Dword'})
    },
    @{ Key='clocksec'; Cat='Explorer & Taskleiste'; Name='Sekunden in der Uhrzeit';
       Desc='ShowSecondsInSystemClock=1 - HH:MM:SS in der Taskleiste';
       Admin=$false; Risk='low'; Restart='explorer';
       On=@(@{Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Kind='SetValue'; Name='ShowSecondsInSystemClock'; On=1; Off=0; Type='Dword'});
       Off=@(@{Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Kind='SetValue'; Name='ShowSecondsInSystemClock'; On=1; Off=0; Type='Dword'})
    },
    @{ Key='recentdocs'; Cat='Explorer & Taskleiste'; Name='Zuletzt verwendete Dokumente aus';
       Desc='Start_TrackDocs=0 + NoRecentDocsHistory=1 - sauberer Start/JumpLists';
       Admin=$false; Risk='low'; Restart='explorer';
       On=@(
           @{Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Kind='SetValue'; Name='Start_TrackDocs'; On=0; Off=1; Type='Dword'},
           @{Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Kind='SetValue'; Name='NoRecentDocsHistory'; On=1; Off=0; Type='Dword'}
       );
       Off=@(
           @{Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Kind='SetValue'; Name='Start_TrackDocs'; On=0; Off=1; Type='Dword'},
           @{Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Kind='SetValue'; Name='NoRecentDocsHistory'; On=1; Off=0; Type='Dword'}
       )
    },
    @{ Key='thumbnails'; Cat='Explorer & Taskleiste'; Name='Miniaturansichten aus';
       Desc='IconsOnly=1 - Ordner zeigen Icons statt Bildvorschauen (schneller, privater)';
       Admin=$false; Risk='low'; Restart='explorer';
       On=@(@{Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Kind='SetValue'; Name='IconsOnly'; On=1; Off=0; Type='Dword'});
       Off=@(@{Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Kind='SetValue'; Name='IconsOnly'; On=1; Off=0; Type='Dword'})
    },
    @{ Key='navpane'; Cat='Explorer & Taskleiste'; Name='Navigationsbereich: eigenstaendig';
       Desc='NavPaneExpandToCurrentFolder=1 - Unterordner des aktuellen Pfads aufklappen';
       Admin=$false; Risk='low'; Restart='explorer';
       On=@(@{Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Kind='SetValue'; Name='NavPaneExpandToCurrentFolder'; On=1; Off=0; Type='Dword'});
       Off=@(@{Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Kind='SetValue'; Name='NavPaneExpandToCurrentFolder'; On=1; Off=0; Type='Dword'})
    },

    # ---------------- Leistung & System ----------------
    @{ Key='netthrottle'; Cat='Leistung & System'; Name='Netzwerk-Drosselung aus';
       Desc='NetworkThrottlingIndex=0xFFFFFFFF - volle Bandbreite';
       Admin=$true; Risk='low'; Restart='none';
       On=@(@{Path='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'; Kind='SetValue'; Name='NetworkThrottlingIndex'; On='0xFFFFFFFF'; Off='10'; Type='Dword'});
       Off=@(@{Path='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'; Kind='SetValue'; Name='NetworkThrottlingIndex'; On='0xFFFFFFFF'; Off='10'; Type='Dword'})
    },
    @{ Key='sysresp'; Cat='Leistung & System'; Name='System-Reaktivitaet fuer Spiele';
       Desc='SystemResponsiveness=0 - CPU Prioritaet fuer Games';
       Admin=$true; Risk='low'; Restart='none';
       On=@(@{Path='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'; Kind='SetValue'; Name='SystemResponsiveness'; On=0; Off=20; Type='Dword'});
       Off=@(@{Path='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'; Kind='SetValue'; Name='SystemResponsiveness'; On=0; Off=20; Type='Dword'})
    },
    @{ Key='gamedvr'; Cat='Leistung & System'; Name='Game DVR deaktivieren';
       Desc='AppCaptureEnabled=0 + GameDVR_Enabled=0 - kein Hintergrund-Recording';
       Admin=$false; Risk='low'; Restart='none';
       On=@(
           @{Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR'; Kind='SetValue'; Name='AppCaptureEnabled'; On=0; Off=1; Type='Dword'},
           @{Path='HKCU:\System\GameConfigStore'; Kind='SetValue'; Name='GameDVR_Enabled'; On=0; Off=1; Type='Dword'}
       );
       Off=@(
           @{Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR'; Kind='SetValue'; Name='AppCaptureEnabled'; On=0; Off=1; Type='Dword'},
           @{Path='HKCU:\System\GameConfigStore'; Kind='SetValue'; Name='GameDVR_Enabled'; On=0; Off=1; Type='Dword'}
       )
    },
    @{ Key='powerthrottle'; Cat='Leistung & System'; Name='Power Throttling aus';
       Desc='PowerThrottlingOff=1 - Hintergrundprozesse nicht ausdrosseln';
       Admin=$true; Risk='medium'; Restart='none';
       On=@(@{Path='HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling'; Kind='SetValue'; Name='PowerThrottlingOff'; On=1; Off=0; Type='Dword'});
       Off=@(@{Path='HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling'; Kind='SetValue'; Name='PowerThrottlingOff'; On=1; Off=0; Type='Dword'})
    },
    @{ Key='shutdownfast'; Cat='Leistung & System'; Name='Schnelleres Herunterfahren';
       Desc='AutoEndTasks + WaitToKillAppTimeout=2000 + HungAppTimeout=1000';
       Admin=$false; Risk='medium'; Restart='none';
       On=@(
           @{Path='HKCU:\Control Panel\Desktop'; Kind='SetValue'; Name='AutoEndTasks'; On='1'; Off='0'; Type='String'},
           @{Path='HKCU:\Control Panel\Desktop'; Kind='SetValue'; Name='WaitToKillAppTimeout'; On='2000'; Off='5000'; Type='String'},
           @{Path='HKCU:\Control Panel\Desktop'; Kind='SetValue'; Name='HungAppTimeout'; On='1000'; Off='5000'; Type='String'}
       );
       Off=@(
           @{Path='HKCU:\Control Panel\Desktop'; Kind='SetValue'; Name='AutoEndTasks'; On='1'; Off='0'; Type='String'},
           @{Path='HKCU:\Control Panel\Desktop'; Kind='SetValue'; Name='WaitToKillAppTimeout'; On='2000'; Off='5000'; Type='String'},
           @{Path='HKCU:\Control Panel\Desktop'; Kind='SetValue'; Name='HungAppTimeout'; On='1000'; Off='5000'; Type='String'}
       )
    },
    @{ Key='bsodinfo'; Cat='Leistung & System'; Name='BSOD-Details anzeigen';
       Desc='DisplayParameters=1 - tech. Info beim Bluescreen';
       Admin=$true; Risk='low'; Restart='none';
       On=@(@{Path='HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'; Kind='SetValue'; Name='DisplayParameters'; On=1; Off=0; Type='Dword'});
       Off=@(@{Path='HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'; Kind='SetValue'; Name='DisplayParameters'; On=1; Off=0; Type='Dword'})
    },
    @{ Key='visualfx'; Cat='Leistung & System'; Name='Visuelle Effekte: Leistung';
       Desc='VisualFXSetting=2 - beste Leistung (weniger Animationen)';
       Admin=$false; Risk='low'; Restart='explorer';
       On=@(@{Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'; Kind='SetValue'; Name='VisualFXSetting'; On=2; Off=0; Type='Dword'});
       Off=@(@{Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'; Kind='SetValue'; Name='VisualFXSetting'; On=2; Off=0; Type='Dword'})
    },
    @{ Key='numlock'; Cat='Leistung & System'; Name='NumLock beim Start AN';
       Desc='InitialKeyboardIndicators=2 - Ziffernblock direkt nutzbar';
       Admin=$true; Risk='low'; Restart='none';
       On=@(@{Path='HKU\.DEFAULT\Control Panel\Keyboard'; Kind='SetValue'; Name='InitialKeyboardIndicators'; On='2'; Off='0'; Type='String'});
       Off=@(@{Path='HKU\.DEFAULT\Control Panel\Keyboard'; Kind='SetValue'; Name='InitialKeyboardIndicators'; On='2'; Off='0'; Type='String'})
    },

    # ---------------- Datenschutz (Basis; vollstaendig: PrivacyFix) ----------------
    @{ Key='adid'; Cat='Datenschutz'; Name='Werbe-ID deaktivieren';
       Desc='AdvertisingID Enabled=0';
       Admin=$false; Risk='low'; Restart='none';
       On=@(@{Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; Kind='SetValue'; Name='Enabled'; On=0; Off=1; Type='Dword'});
       Off=@(@{Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; Kind='SetValue'; Name='Enabled'; On=0; Off=1; Type='Dword'})
    },
    @{ Key='tailored'; Cat='Datenschutz'; Name='Massgeschneiderte Inhalte aus';
       Desc='TailoredExperiencesEnabled=0';
       Admin=$false; Risk='low'; Restart='none';
       On=@(@{Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy'; Kind='SetValue'; Name='TailoredExperiencesEnabled'; On=0; Off=1; Type='Dword'});
       Off=@(@{Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy'; Kind='SetValue'; Name='TailoredExperiencesEnabled'; On=0; Off=1; Type='Dword'})
    },
    @{ Key='telemetry'; Cat='Datenschutz'; Name='Telemetrie = Minimal (Policy)';
       Desc='HKLM AllowTelemetry=0 - volle Telemetrie aus';
       Admin=$true; Risk='low'; Restart='none';
       On=@(@{Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Kind='SetValue'; Name='AllowTelemetry'; On=0; Off=1; Type='Dword'});
       Off=@(@{Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Kind='SetValue'; Name='AllowTelemetry'; On=0; Off=1; Type='Dword'})
    },
    @{ Key='cdm'; Cat='Datenschutz'; Name='Content Delivery Master aus';
       Desc='ContentDeliveryAllowed=0 - sperrt die meisten Consumer-Features';
       Admin=$false; Risk='medium'; Restart='none';
       On=@(@{Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Kind='SetValue'; Name='ContentDeliveryAllowed'; On=0; Off=1; Type='Dword'});
       Off=@(@{Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Kind='SetValue'; Name='ContentDeliveryAllowed'; On=0; Off=1; Type='Dword'})
    },
    @{ Key='location'; Cat='Datenschutz'; Name='Standort-Zugriff sperren';
       Desc='Location Capability = Deny (HKLM-Policy)';
       Admin=$true; Risk='medium'; Restart='none';
       On=@(@{Path='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location'; Kind='SetValue'; Name='Value'; On='Deny'; Off='Allow'; Type='String'});
       Off=@(@{Path='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location'; Kind='SetValue'; Name='Value'; On='Deny'; Off='Allow'; Type='String'})
    },
    @{ Key='copilot'; Cat='Datenschutz'; Name='Copilot in Taskleiste aus';
       Desc='TurnOffWindowsCopilot=1 (HKLM-Policy)';
       Admin=$true; Risk='low'; Restart='explorer';
       On=@(@{Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot'; Kind='SetValue'; Name='TurnOffWindowsCopilot'; On=1; Off=0; Type='Dword'});
       Off=@(@{Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot'; Kind='SetValue'; Name='TurnOffWindowsCopilot'; On=1; Off=0; Type='Dword'})
    },

    # ---------------- Dienste ----------------
    @{ Key='diagtrack'; Cat='Dienste'; Name='DiagTrack (Telemetrie) deaktivieren';
       Desc='Diagnosedatendienst: automatic -> disabled + stoppen';
       Admin=$true; Risk='medium'; Restart='none'; Kind='Service'; Service='DiagTrack'; ServiceOn='Disabled'; ServiceOff='Automatic';
       On=@(); Off=@()
    },
    @{ Key='w32time'; Cat='Dienste'; Name='Windows-Zeitdienst manuell';
       Desc='W32Time: automatic -> manual (spart Ressourcen, Sync nur bei Bedarf)';
       Admin=$true; Risk='low'; Restart='none'; Kind='Service'; Service='W32Time'; ServiceOn='Manual'; ServiceOff='Automatic';
       On=@(); Off=@()
    },
    @{ Key='spooler'; Cat='Dienste'; Name='Druckerdienst deaktivieren';
       Desc='Spooler: automatic -> disabled (nur ohne Drucker!)';
       Admin=$true; Risk='high'; Restart='none'; Kind='Service'; Service='Spooler'; ServiceOn='Disabled'; ServiceOff='Automatic';
       On=@(); Off=@()
    },
    @{ Key='sysmain'; Cat='Dienste'; Name='SysMain (Superfetch) manuell';
       Desc='SysMain: automatic -> manual (RAM-schonend auf SSD-Systemen ok)';
       Admin=$true; Risk='low'; Restart='none'; Kind='Service'; Service='SysMain'; ServiceOn='Manual'; ServiceOff='Automatic';
       On=@(); Off=@()
    },
    @{ Key='wsearch'; Cat='Dienste'; Name='Windows-Suche deaktivieren';
       Desc='WSearch: automatic -> disabled (Start-Suche langsamer, Index weg)';
       Admin=$true; Risk='medium'; Restart='none'; Kind='Service'; Service='WSearch'; ServiceOn='Disabled'; ServiceOff='Automatic';
       On=@(); Off=@()
    }
)

function Get-SysPilotTweakFavorites {
    if (Test-Path $script:TweakFavPath) { return @(Get-Content $script:TweakFavPath -Encoding UTF8 | Where-Object { $_ -match '\S' }) }
    return @()
}
function Add-SysPilotTweakFavorite {
    param([Parameter(Mandatory)][string]$Key)
    $f = @(Get-SysPilotTweakFavorites)
    if ($f -contains $Key) { return }
    $dir = Split-Path $script:TweakFavPath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Add-Content -Path $script:TweakFavPath -Value $Key -Encoding UTF8
}
function Remove-SysPilotTweakFavorite {
    param([Parameter(Mandatory)][string]$Key)
    $f = @(Get-SysPilotTweakFavorites) | Where-Object { $_ -ne $Key }
    if (-not (Test-Path $script:TweakFavPath)) { return }
    Set-Content -Path $script:TweakFavPath -Value $f -Encoding UTF8
}

function Backup-SysPilotTweakKeys {
    <# Exportiert alle betroffenen Registry-Keys vor einer Aenderung. #>
    param([Parameter(Mandatory)]$Tweak, [Parameter(Mandatory)][string]$Direction)
    $keys = @{}
    $ops = if ($Direction -eq 'on') { @($Tweak.On) } else { @($Tweak.Off) }
    foreach ($op in $ops) {
        if ($op.Kind -in @('SetValue','SetDefault','DeleteValue','DeleteKey')) {
            $k = $op.Path
            if ($k -match '^(HKLM|HKCU|HKU|HKCR):\\(.+)$') {
                $hive = $Matches[1]; $rest = $Matches[2]
                $parts = $rest -split '\\'
                # naechsten existierenden Vorfahren finden (laengster Prefix)
                $cur = "$hive`:\"
                $found = $null
                foreach ($p in $parts) {
                    $cur = Join-Path $cur $p
                    if (Test-Path -LiteralPath $cur) { $found = $cur }
                }
                if ($found) { $keys[$found] = $true }
            }
        }
    }
    if ($keys.Count -eq 0) { return $null }
    $bkDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ("SysPilot\reg-backups\" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $bkDir -Force | Out-Null
    $files = @()
    foreach ($k in $keys.Keys) {
        $safe = ($k -replace '[:\\]','_')
        $f = Join-Path $bkDir "$safe.reg"
        & reg.exe export "$k" "$f" /y 2>$null | Out-Null
        if (Test-Path $f) { $files += $f }
    }
    return @{ Dir=$bkDir; Files=$files; Keys=$keys.Keys }
}

function Get-SysPilotTweakStatus {
    <# Status aller Tweaks: AN / aus / custom + aktueller Wert. #>
    $favs = @(Get-SysPilotTweakFavorites)
    $out = @()
    foreach ($t in $script:TweakDefs) {
        $state = 'custom'; $cur = '-'
        if ($t.Kind -eq 'Service') {
            $svc = Get-Service -Name $t.Service -ErrorAction SilentlyContinue
            if ($svc) {
                $st = $svc.StartType.ToString()
                $state = if ($st -eq $t.ServiceOn) { 'AN' } elseif ($st -eq $t.ServiceOff) { 'aus' } else { 'custom' }
                $cur = $st
            } else { $cur = 'nicht gefunden' }
        } else {
            $onOps = @($t.On | Where-Object { $_.Kind -eq 'SetValue' -or $_.Kind -eq 'SetDefault' })
            $probe = if ($onOps.Count -gt 0) { $onOps[0] } else { $null }
            if ($probe) {
                try {
                    if ($probe.Kind -eq 'SetDefault') {
                        $item = Get-Item -LiteralPath $probe.Path -ErrorAction Stop
                        $cur = $item.GetValue('', $null)
                    } else {
                        $prop = Get-ItemProperty -LiteralPath $probe.Path -Name $probe.Name -ErrorAction Stop
                        $cur = $prop.($probe.Name)
                    }
                    $onVal = $probe.On; $offVal = $probe.Off
                    if ($null -ne $cur) {
                        if ("$cur" -eq "$onVal" -or "$cur" -eq ("0x{0:X8}" -f [int64]$onVal)) { $state = 'AN' }
                        elseif ("$cur" -eq "$offVal" -or "$cur" -eq ("0x{0:X8}" -f [int64]$offVal)) { $state = 'aus' }
                    }
                } catch { $cur = 'nicht gesetzt' }
            } else {
                # DeleteKey-Tweaks: "AN" = Ziel-Key existiert NICHT
                $del = @($t.On | Where-Object { $_.Kind -eq 'DeleteKey' })
                if ($del.Count -gt 0) {
                    $gone = $true
                    foreach ($d in $del) { if (Test-Path -LiteralPath $d.Path) { $gone = $false } }
                    # pruefe zusaetzlich ob Setup-Keys existieren
                    $mk = @($t.On | Where-Object { $_.Kind -in @('NewKey','SetDefault','SetValue') }) | Select-Object -First 1
                    if ($mk -and (Test-Path -LiteralPath $mk.Path)) { $state = 'AN' } else { $state = 'aus'; $cur = 'Key fehlt' }
                    if ($gone -and -not $mk) { $state = 'aus' }
                }
            }
        }
        $out += [pscustomobject]@{ Tweak=$t; State=$state; Current="$cur"; Fav=($favs -contains $t.Key) }
    }
    return $out
}

function Invoke-SysPilotTweakOps {
    <# Fuehrt eine Ops-Liste aus (On oder Off). #>
    param([Parameter(Mandatory)]$Ops)
    foreach ($op in $Ops) {
        $p = $op.Path
        switch ($op.Kind) {
            'NewKey' {
                if (-not (Test-Path -LiteralPath $p)) { New-Item -LiteralPath $p -Force | Out-Null }
            }
            'SetDefault' {
                if (-not (Test-Path -LiteralPath $p)) { New-Item -LiteralPath $p -Force | Out-Null }
                Set-Item -LiteralPath $p -Value ([string]$op.On) -Force -ErrorAction Stop
            }
            'SetValue' {
                if (-not (Test-Path -LiteralPath $p)) { New-Item -LiteralPath $p -Force | Out-Null }
                $type = if ($op.Type -match 'Dword') { 'DWord' } else { 'String' }
                $v = $op.On
                if ($type -eq 'DWord') { $v = [int64]$v }
                Set-ItemProperty -LiteralPath $p -Name $op.Name -Value $v -Type $type -Force -ErrorAction Stop
            }
            'DeleteValue' {
                if (Test-Path -LiteralPath $p) {
                    $pn = $op.Name
                    $prop = Get-ItemProperty -LiteralPath $p -Name $pn -ErrorAction SilentlyContinue
                    if ($null -ne $prop -and $null -ne $prop.$pn) { Remove-ItemProperty -LiteralPath $p -Name $pn -Force -ErrorAction SilentlyContinue }
                }
            }
            'DeleteKey' {
                if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }
    }
}

function Set-SysPilotTweakItem {
    <# Schaltet einen Tweak um (AN <-> aus), mit .reg-Backup davor. #>
    param([Parameter(Mandatory)]$Tweak, [switch]$NoConfirm)
    $st = Get-SysPilotTweakStatus | Where-Object { $_.Tweak.Key -eq $Tweak.Key } | Select-Object -First 1
    $toOn = ($st.State -ne 'AN')

    if ($Tweak.Admin -and -not (Test-SysPilotAdmin)) {
        $r = Confirm-SysPilot "'$($Tweak.Name)' braucht Administrator-Rechte.`nSysPilot jetzt als Administrator neu starten?"
        if ($r) { Restart-SysPilotElevated }
        return
    }
    if (-not $NoConfirm -and -not (Confirm-SysPilot "'$($Tweak.Name)' $(if ($toOn) {'einschalten'} else {'ausschalten'})?`n$($Tweak.Desc)`nRisiko: $($Tweak.Risk)")) { return }

    # Backup vor Aenderung (Registry-Keys; Services sind ueber Set-Service reversibel)
    $bk = $null
    if ($Tweak.Kind -ne 'Service') { $bk = Backup-SysPilotTweakKeys -Tweak $Tweak -Direction $(if ($toOn) {'on'} else {'off'}) }

    try {
        if ($Tweak.Kind -eq 'Service') {
            $target = if ($toOn) { $Tweak.ServiceOn } else { $Tweak.ServiceOff }
            Set-Service -Name $Tweak.Service -StartupType $target -ErrorAction Stop
            if ($target -eq 'Disabled') { Stop-Service -Name $Tweak.Service -Force -ErrorAction SilentlyContinue }
        } else {
            $ops = if ($toOn) { $Tweak.On } else { $Tweak.Off }
            Invoke-SysPilotTweakOps -Ops $ops
        }
        Write-Host "  [OK] $($Tweak.Name) -> $(if ($toOn) {'AN'} else {'aus'})" -ForegroundColor Green
        if ($bk -and $bk.Files.Count -gt 0) { Write-Host "       Backup: $($bk.Dir)" -ForegroundColor DarkGray }
        Write-SysPilotLog "TweakStudio $($Tweak.Key) = $(if ($toOn) {'AN'} else {'aus'})"
        if ($Tweak.Restart -eq 'explorer' -and $toOn) {
            Write-Host '  Hinweis: Explorer-Neustart noetig (Task-Manager > Windows-Explorer > neu starten)' -ForegroundColor DarkYellow
        }
    } catch {
        Write-Host "  [!] Fehler: $($_.Exception.Message)" -ForegroundColor Red
        if ($bk -and $bk.Files.Count -gt 0) {
            foreach ($bf in $bk.Files) { & reg.exe import $bf 2>$null | Out-Null }
            Write-Host '       Backup wurde automatisch wiederhergestellt.' -ForegroundColor Yellow
        }
    }
}

function Show-SysPilotTweakStudio {
    <# Pfeiltasten-Menue: Kategorien, Favoriten, Status, umschalten. #>
    while ($true) {
        $items = @()
        $favs = @(Get-SysPilotTweakFavorites)
        if ($favs.Count -gt 0) {
            $items += @{ Label = '>>> FAVORITEN'; Color = 'Yellow'; Tag = 'fav' }
        }
        $cats = @($script:TweakDefs | ForEach-Object { $_.Cat } | Sort-Object -Unique)
        foreach ($c in $cats) { $items += @{ Label = ">>> $c"; Color = 'Cyan'; Tag = "cat:$c" } }
        $items += @{ Label = '>>> RECHTSKLICK-TIPPS (Kontextmenue-Beispiele)'; Color = 'DarkCyan'; Tag = 'tips' }
        $items += @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = $null }
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'SysPilot Tweak-Studio' -Footer 'Pfeiltasten, Enter = auswaehlen, Esc = zurueck'
        if ($null -eq $sel) { return }

        if ($sel -eq 'fav') {
            $status = @(Get-SysPilotTweakStatus | Where-Object { $_.Fav })
            $fItems = @()
            foreach ($s in $status) {
                $mark = switch ($s.State) { 'AN' {'[AN ]'} 'aus' {'[aus]'} default {'[???]'} }
                $fItems += @{ Label = ("{0} {1,-44} {2}" -f $mark, $s.Tweak.Name, $s.Tweak.Desc); Color = $(if ($s.State -eq 'AN') {'Green'} else {'White'}); Tag = $s }
            }
            foreach ($s in $status) {
                $fItems += @{ Label = "  [x] Favorit entfernen: $($s.Tweak.Name)"; Color = 'DarkYellow'; Tag = "unfav:$($s.Tweak.Key)" }
            }
            $fItems += @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = $null }
            $pick = Show-SysPilotArrowMenu -Items $fItems -Title 'Favoriten' -Footer 'Enter = umschalten, "unfav" = entfernen, Esc = zurueck'
            if ($null -eq $pick) { continue }
            if ($pick -like 'unfav:*') { Remove-SysPilotTweakFavorite -Key $pick.Substring(6); continue }
            $menu = @(
                @{ Label = 'Umschalten (AN/aus)'; Color = 'Cyan'; Tag = 'toggle' },
                @{ Label = 'Favorit entfernen'; Color = 'DarkYellow'; Tag = 'unfav2' },
                @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = $null }
            )
            $a = Show-SysPilotArrowMenu -Items $menu -Title $pick.Tweak.Name -Footer 'Enter = auswaehlen'
            if ($null -eq $a) { continue }
            if ($a.Tag -eq 'toggle') { Set-SysPilotTweakItem -Tweak $pick.Tweak }
            elseif ($a.Tag -eq 'unfav2') { Remove-SysPilotTweakFavorite -Key $pick.Tweak.Key }
            continue
        }

        if ($sel -eq 'tips') {
            $tips = @(
                @{ Label = 'Tipp 1: Kontextmenue-Tweaks landen unter HKCU\Software\Classes -'; Color = 'DarkGray'; Tag = $null },
                @{ Label = '        gelten NUR fuer diesen Benutzer, kein Admin noetig.'; Color = 'DarkGray'; Tag = $null },
                @{ Label = 'Tipp 2: Nach dem Einschalten Explorer neu starten'; Color = 'DarkGray'; Tag = $null },
                @{ Label = '        (Task-Manager > Windows-Explorer > neu starten).'; Color = 'DarkGray'; Tag = $null },
                @{ Label = 'Tipp 3: Jede Aenderung wird vorher als .reg-Backup'; Color = 'DarkGray'; Tag = $null },
                @{ Label = '        in %LOCALAPPDATA%\SysPilot\reg-backups gesichert.'; Color = 'DarkGray'; Tag = $null },
                @{ Label = 'Tipp 4: Ausfuehrliche .reg-Dateien -> RegGallery-Modul.'; Color = 'DarkGray'; Tag = $null },
                @{ Label = '        (Menue > REGISTRY-GALERIE)'; Color = 'DarkGray'; Tag = $null },
                @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = 'back' }
            )
            [void](Show-SysPilotArrowMenu -Items $tips -Title 'Kontextmenue-Tipps' -Footer 'Enter/Esc = zurueck')
            continue
        }

        if ($sel -like 'cat:*') {
            $cat = $sel.Substring(4)
            $status = @(Get-SysPilotTweakStatus | Where-Object { $_.Tweak.Cat -eq $cat })
            $tItems = @()
            foreach ($s in $status) {
                $mark = switch ($s.State) { 'AN' {'[AN ]'} 'aus' {'[aus]'} default {'[???]'} }
                $color = switch ($s.State) { 'AN' {'Green'} 'aus' {'White'} default {'Yellow'} }
                $adm = if ($s.Tweak.Admin) { ' [Admin]' } else { '' }
                $risk = if ($s.Tweak.Risk -eq 'high') { ' [RISKANT]' } elseif ($s.Tweak.Risk -eq 'medium') { ' [mittel]' } else { '' }
                $fav = if ($s.Fav) { ' *' } else { '' }
                $tItems += @{ Label = ("{0} {1,-40} {2}{3}{4}{5}" -f $mark, $s.Tweak.Name, $s.Tweak.Desc, $adm, $risk, $fav); Color = $color; Tag = $s }
            }
            $tItems += @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = $null }
            $pick = Show-SysPilotArrowMenu -Items $tItems -Title "$cat - Tweaks" -Footer 'Enter = Aktion, Esc = zurueck  (* = Favorit)'
            if ($null -eq $pick) { continue }
            $act = Show-SysPilotArrowMenu -Items @(
                @{ Label = 'Umschalten (AN/aus)'; Color = 'Cyan'; Tag = 'toggle' },
                @{ Label = $(if ($pick.Fav) { 'Favorit entfernen' } else { 'Als Favorit markieren' }); Color = 'Yellow'; Tag = 'fav' },
                @{ Label = 'Status/Details'; Color = 'DarkGray'; Tag = 'info' },
                @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = $null }
            ) -Title $pick.Tweak.Name -Footer 'Enter = auswaehlen'
            if ($null -eq $act) { continue }
            switch ($act.Tag) {
                'toggle' { Set-SysPilotTweakItem -Tweak $pick.Tweak }
                'fav'    { if ($pick.Fav) { Remove-SysPilotTweakFavorite -Key $pick.Tweak.Key } else { Add-SysPilotTweakFavorite -Key $pick.Tweak.Key } }
                'info'   { Write-Host "`n  $($pick.Tweak.Name)`n  $($pick.Tweak.Desc)`n  Risiko: $($pick.Tweak.Risk) | Admin: $($pick.Tweak.Admin) | Aktuell: $($pick.Current)`n  Backup-Ordner: %LOCALAPPDATA%\SysPilot\reg-backups" -ForegroundColor Cyan; Read-SysPilotChoice 'Enter = weiter' | Out-Null }
            }
        }
    }
}

Export-ModuleMember -Function Get-SysPilotTweakStatus, Set-SysPilotTweakItem,
    Show-SysPilotTweakStudio, Add-SysPilotTweakFavorite, Remove-SysPilotTweakFavorite,
    Get-SysPilotTweakFavorites, Backup-SysPilotTweakKeys
