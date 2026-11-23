# SysPilot - Common: Admin-Check, Logging, Config, Backup/Restore
#Requires -Version 5.1

$script:SysPilotRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$script:Config = $null

function Test-SysPilotAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class SysPilotGameCheck {
    [DllImport("shell32.dll")]
    public static extern int SHQueryUserNotificationState(out int pquns);
}
"@ -ErrorAction SilentlyContinue

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class SysPilotConsoleInput {
    [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
    [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool ReadConsoleInput(IntPtr hConsoleInput, [Out] INPUT_RECORD[] lpBuffer, uint nLength, out uint lpNumberOfEventsRead);

    [StructLayout(LayoutKind.Sequential)] public struct COORD { public short X; public short Y; }
    [StructLayout(LayoutKind.Sequential)] public struct KEY_EVENT_RECORD {
        public int bKeyDown; public short wRepeatCount; public short wVirtualKeyCode;
        public short wVirtualScanCode; public char UnicodeChar; public int dwControlKeyState;
    }
    [StructLayout(LayoutKind.Sequential)] public struct MOUSE_EVENT_RECORD {
        public COORD dwMousePosition; public uint dwButtonState; public uint dwControlKeyState; public uint dwEventFlags;
    }
    [StructLayout(LayoutKind.Explicit, Size=20)] public struct INPUT_RECORD {
        [FieldOffset(0)] public ushort EventType;
        [FieldOffset(4)] public KEY_EVENT_RECORD KeyEvent;
        [FieldOffset(4)] public MOUSE_EVENT_RECORD MouseEvent;
    }
}
"@ -ErrorAction SilentlyContinue

function Test-SysPilotGamingActive {
    <# Gibt $true zurueck, wenn ein Spiel laeuft oder eine Vollbild-/Direct3D-Anwendung aktiv ist.
       Schuetzt Spiele vor stoerenden Fenstern, Popups und Fokus-Verlust. #>
    try {
        $state = 0
        if ([SysPilotGameCheck]::SHQueryUserNotificationState([ref]$state) -eq 0) {
            # 2 = QUNS_BUSY (Vollbild / D3D Exklusiv)
            # 3 = QUNS_RUNNING_D3D_FULL_SCREEN (Direct3D Vollbild, typisch fuer Spiele)
            # 4 = QUNS_PRESENTATION_MODE
            # 7 = QUNS_APP (Vollbild Store-App)
            if ($state -in 2, 3, 4, 7) { return $true }
        }
    } catch { }

    try {
        $cfg = Get-SysPilotConfig
        if ($cfg -and $cfg.GameProcesses -and $cfg.GameProcesses.Count -gt 0) {
            $running = Get-Process -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ProcessName
            foreach ($g in $cfg.GameProcesses) {
                $base = $g -replace '\.exe$',''
                if ($running -contains $base) { return $true }
            }
        }
    } catch { }

    return $false
}

function Assert-SysPilotAdmin {
    if (-not (Test-SysPilotAdmin)) {
        Write-Host ""
        Write-Host "  [!] Diese Aktion braucht Administrator-Rechte." -ForegroundColor Yellow
        Write-Host "      Bitte SysPilot ueber den Menuepunkt 'Als Administrator neu starten' oeffnen." -ForegroundColor Yellow
        Write-Host ""
        return $false
    }
    return $true
}

function Restart-SysPilotElevated {
    <# Startet das aktuelle Skript (GUI oder Konsole) mit Admin-Rechten neu.
       -NoExit: das aufrufende Skript beendet sich selbst (kein hartes exit,
       damit die GUI sauber aufraeumen kann). #>
    param([switch]$NoExit)
    if (Test-SysPilotAdmin) { return }
    $exe = "powershell.exe"
    if ($PSVersionTable.PSEdition -eq 'Core') { $exe = "pwsh.exe" }
    # Aufrufendes Skript ermitteln ($PSCommandPath zeigt innerhalb eines Moduls auf die .psm1, nicht auf das Skript)
    $caller = Get-PSCallStack | Where-Object { $_.ScriptName -and $_.ScriptName -like '*.ps1' } | Select-Object -First 1
    $current = if ($caller) { $caller.ScriptName } else { $null }
    if (-not $current) { $current = Join-Path $script:SysPilotRoot "SysPilot.ps1" }
    $argList = if ((Split-Path $current -Leaf) -ieq 'SysPilot-GUI.ps1') { "-STA -NoProfile -ExecutionPolicy Bypass" } else { "-NoProfile -ExecutionPolicy Bypass" }
    # Nur die GUI laeuft ohne Konsolenfenster (sie versteckt es selbst). Das Text-Menue (SysPilot.ps1)
    # braucht sein Fenster - versteckt waere es unsichtbar und die App wirkt "nicht gestartet".
    if ((Split-Path $current -Leaf) -ieq 'SysPilot-GUI.ps1') { $argList += " -WindowStyle Hidden" }
    $argList += " -File `"$current`""
    Start-Process $exe -Verb RunAs -ArgumentList $argList
    if (-not $NoExit) { exit }
}

function ConvertTo-SysPilotArgString {
    <# Baut aus einer Argumentliste eine korrekt gequotete Kommandozeile.
       Start-Process -ArgumentList @(...) setzt Pfade mit Leerzeichen NICHT in Anfuehrungszeichen
       (z.B. "C:\Program Files\SysPilot\SysPilot.ps1") - dann startet das Werkzeug nicht. #>
    param([string[]]$ArgList)
    $parts = foreach ($a in $ArgList) {
        if ($null -eq $a -or $a -eq '') { '""' }
        elseif ($a -match '[\s"]') { '"' + ($a -replace '"', '\"') + '"' }
        else { $a }
    }
    return ($parts -join ' ')
}

function Start-SysPilotGuiTool {
    <# Einheitlicher, sicherer Starter für Toolbox-Aktionen aus der GUI. #>
    param(
        [Parameter(Mandatory)][string]$ToolKey,
        [bool]$NeedsAdmin = $false,
        [string]$WorkingDirectory = $script:SysPilotRoot
    )
    $scriptPath = Join-Path $script:SysPilotRoot 'SysPilot.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "SysPilot-Hauptskript nicht gefunden: $scriptPath"
    }
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$scriptPath,'-Tool',$ToolKey)
    $argString = ConvertTo-SysPilotArgString $args
    $params = @{ FilePath = $(if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }); ArgumentList = $argString; WorkingDirectory = $WorkingDirectory; WindowStyle = 'Normal' }
    if ($NeedsAdmin -and -not (Test-SysPilotAdmin)) { $params.Verb = 'RunAs' }
    try {
        $process = Start-Process @params -PassThru -ErrorAction Stop
        Write-SysPilotLog "GUI-Tool gestartet: $ToolKey (Admin=$NeedsAdmin, PID=$($process.Id))"
        return $process
    } catch {
        Write-SysPilotLog "GUI-Tool konnte nicht starten: $ToolKey - $($_.Exception.Message)" 'ERROR'
        throw
    }
}

function Search-SysPilotGuiTopic {
    param([Parameter(Mandatory)][string]$Query)
    $encoded = [Uri]::EscapeDataString("SysPilot $Query")
    Start-Process "https://www.bing.com/search?q=$encoded"
}

function Write-SysPilotLog {
    param([string]$Message, [string]$Level = "INFO")
    $logDir = Join-Path $script:SysPilotRoot "logs"
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
    $file = Join-Path $logDir ("syspilot-" + (Get-Date -Format "yyyy-MM-dd") + ".log")
    $line = "{0} [{1}] {2}" -f (Get-Date -Format "HH:mm:ss"), $Level, $Message
    Add-Content -Path $file -Value $line -Encoding UTF8
}

function Get-SysPilotConfig {
    if ($null -eq $script:Config) {
        $path = Join-Path $script:SysPilotRoot "config.json"
        $script:Config = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    return $script:Config
}

function Reset-SysPilotConfig { $script:Config = $null }

function Test-NameMatch {
    # Wildcard-Match (* am Ende oder Anfang erlaubt), case-insensitive
    param([string]$Name, [string[]]$Patterns)
    foreach ($pat in $Patterns) {
        if ($Name -like $pat) { return $true }
        if ($Name -like "$pat*") { return $true }
    }
    return $false
}

function Get-SysPilotProcessByName {
    param([string]$Name)
    $base = $Name -replace '\.exe$',''
    Get-Process -Name $base -ErrorAction SilentlyContinue
}

function New-SysPilotBackup {
    param([string]$Label = "manual")
    $dir = Join-Path $script:SysPilotRoot "backup"
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $target = Join-Path $dir "$stamp-$Label"
    New-Item -ItemType Directory -Force -Path $target | Out-Null

    # Dienste
    Get-CimInstance Win32_Service | Select-Object Name, StartMode, State |
        Export-Csv -Path (Join-Path $target "services.csv") -NoTypeInformation -Encoding UTF8

    # Autostart (Registry Run-Schluessel)
    $runKeys = @(
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32"
    )
    $regOut = Join-Path $target "registry"
    New-Item -ItemType Directory -Force -Path $regOut | Out-Null
    $i = 0
    foreach ($k in $runKeys) {
        $i++
        $regPath = $k -replace '^HKCU:\\','HKEY_CURRENT_USER\' -replace '^HKLM:\\','HKEY_LOCAL_MACHINE\'
        & reg.exe export $regPath (Join-Path $regOut "run-$i.reg") /y 2>$null | Out-Null
    }

    # Energieplaene exportieren
    $plans = & powercfg /list
    foreach ($line in $plans) {
        if ($line -match '([0-9a-fA-F-]{36})') {
            $guid = $matches[1]
            & powercfg /export (Join-Path $target "plan-$guid.pow") $guid 2>$null | Out-Null
        }
    }

    Write-SysPilotLog "Backup erstellt: $target"
    return $target
}

function Get-SysPilotBackupDir {
    $dir = Join-Path $script:SysPilotRoot "backup"
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    return $dir
}

function Get-SysPilotPortableAppsDir {
    <# Loest das PortableApps-Verzeichnis des Benutzers auf.
       Bevorzugt den echten Desktop-Ort (OneDrive-Desktop, falls umgeleitet),
       sonst OneDrive/Desktop als Fallback. Legt den Ordner an. #>
    $candidates = @(
        (Join-Path ([Environment]::GetFolderPath('Desktop')) 'PortableApps'),
        "$env:USERPROFILE\OneDrive\Desktop\PortableApps",
        "$env:USERPROFILE\Desktop\PortableApps"
    ) | Select-Object -Unique
    foreach ($d in $candidates) {
        if (Test-Path (Split-Path $d -Parent)) {
            if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
            return $d
        }
    }
    # Letzte Instanz: ersten Kandidaten trotzdem anlegen
    $d = $candidates[0]
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    return $d
}

function Get-SysPilotLocalSearchDirs {
    <# Ordner, in denen nach lokalen Installern/Downloads gesucht wird:
       Downloads + PortableApps (nur existierende). #>
    $dirs = @("$env:USERPROFILE\Downloads", (Get-SysPilotPortableAppsDir))
    return @($dirs | Select-Object -Unique | Where-Object { Test-Path $_ })
}

function Get-SysPilotBackups {
    $dir = Join-Path $script:SysPilotRoot "backup"
    if (-not (Test-Path $dir)) { return @() }
    Get-ChildItem $dir -Directory | Sort-Object Name -Descending
}

function Restore-SysPilotServices {
    param([string]$BackupPath)
    $csv = Join-Path $BackupPath "services.csv"
    if (-not (Test-Path $csv)) { Write-Host "  Kein Dienste-Backup gefunden." -ForegroundColor Red; return }
    $rows = Import-Csv $csv -Encoding UTF8
    $count = 0
    foreach ($r in $rows) {
        $svc = Get-Service -Name $r.Name -ErrorAction SilentlyContinue
        if ($svc -and $svc.StartType -ne $r.StartMode) {
            try {
                Set-Service -Name $r.Name -StartupType $r.StartMode -ErrorAction Stop
                $count++
            } catch { }
        }
    }
    Write-Host "  $count Dienste wiederhergestellt." -ForegroundColor Green
    Write-SysPilotLog "Dienste aus Backup wiederhergestellt: $BackupPath ($count)"
}

function Write-SysPilotHeader {
    param([string]$Title)
    Write-Host ""
    Write-Host ("=" * 66) -ForegroundColor DarkCyan
    Write-Host ("  " + $Title) -ForegroundColor Cyan
    Write-Host ("=" * 66) -ForegroundColor DarkCyan
}

function Read-SysPilotChoice {
    param([string]$Prompt = "Auswahl")
    Write-Host ""
    # Pause-Aufrufe ('Weiter', 'Weiter mit Enter', ~160 Stellen) bekommen einen
    # mausfaehigen "drueck irgendwas"-Modus: Klick oder Taste = weiter.
    # Rueckgabe ist '' - identisch zum bloßen Enter bei Read-Host.
    $hadApi = $script:ConsoleInputReady
    if ($Prompt -match '^weiter' -and (Initialize-SysPilotConsoleInput)) {
        Write-Host -NoNewline "  $Prompt : " -ForegroundColor Yellow
        Write-Host "(Enter oder Klick)" -ForegroundColor DarkGray
        Clear-SysPilotConsoleInputBuffer
        try {
            while ($true) {
                $ev = Read-SysPilotMenuEvent
                if ($ev.Kind -eq 'Key') { return '' }
                if ($ev.Action -eq 'Click') { return '' }
            }
        } finally {
            if (-not $hadApi) { Restore-SysPilotConsoleInput }
        }
    }
    Write-Host -NoNewline "  $Prompt : " -ForegroundColor Yellow
    return (Read-Host).Trim()
}

function Read-SysPilotYesNo {
    <# Kompakter Ja/Nein-Dialog MIT MausUnterstuetzung: Klick auf [Ja]/[Nein],
       Mausrad = umschalten, j/y = Ja, n = Nein, Pfeile+Enter, Esc = Nein.
       Zeichnet INLINE (kein Clear-Host) - der vorherige Kontext bleibt sichtbar.
       Gibt $true (Ja) oder $false (Nein/Abbruch) zurueck. #>
    param([Parameter(Mandatory)][string]$Question)
    $hadApi = $script:ConsoleInputReady
    if (-not (Initialize-SysPilotConsoleInput)) {
        $a = Read-SysPilotChoice "$Question (j/n)"
        return ($a -match '^(j|ja|y|yes)$')
    }
    Clear-SysPilotConsoleInputBuffer
    $sel = 1   # default: Nein (sicher)
    $optRow = -1; $restRow = -1; $firstDraw = $true
    $drawOpts = {
        Write-Host -NoNewline '   '
        if ($sel -eq 0) { Write-Host -NoNewline '[ Ja ]' -ForegroundColor Black -BackgroundColor Yellow }
        else { Write-Host -NoNewline '[ Ja ]' -ForegroundColor DarkGray }
        Write-Host -NoNewline '   '
        if ($sel -eq 1) { Write-Host -NoNewline '[ Nein ]' -ForegroundColor Black -BackgroundColor Yellow }
        else { Write-Host -NoNewline '[ Nein ]' -ForegroundColor DarkGray }
        Write-Host ""
    }
    try {
    $needDraw = $true
    while ($true) {
        if ($needDraw) {
            if ($firstDraw) {
                Write-Host ""
                Write-Host "  $Question" -ForegroundColor Yellow
                Write-Host ""
                $optRow = $Host.UI.RawUI.CursorPosition.Y
                & $drawOpts
                $restRow = $Host.UI.RawUI.CursorPosition.Y
                Write-Host "  (Klick, j/n, Pfeile+Enter, Esc = Nein)" -ForegroundColor DarkGray
                $firstDraw = $false
            } else {
                # nur die Optionszeile aktualisieren (kein Clear-Host)
                $Host.UI.RawUI.CursorPosition = New-Object System.Management.Automation.Host.Coordinates(0, $optRow)
                & $drawOpts
                $Host.UI.RawUI.CursorPosition = New-Object System.Management.Automation.Host.Coordinates(0, $restRow)
            }
        }
        $needDraw = $true
        $ev = Read-SysPilotMenuEvent
        if ($ev.Kind -eq 'Key') {
            switch ([int]$ev.Vk) {
                74 { return $true }    # j
                89 { return $true }    # y
                78 { return $false }   # n
                27 { return $false }   # Esc
                13 { return ($sel -eq 0) }
                37 { $sel = 0 }        # links = Ja
                39 { $sel = 1 }        # rechts = Nein
                38 { $sel = 0 }        # oben = Ja
                40 { $sel = 1 }        # unten = Nein
            }
        } else {
            $zoneJa = ($ev.Row -eq $optRow -and $ev.Col -ge 3 -and $ev.Col -le 10)
            $zoneNein = ($ev.Row -eq $optRow -and $ev.Col -ge 11 -and $ev.Col -le 18)
            switch ($ev.Action) {
                'Move' {
                    $h = if ($zoneJa) { 0 } elseif ($zoneNein) { 1 } else { $sel }
                    if ($h -ne $sel) { $sel = $h } else { $needDraw = $false }
                }
                'Click' {
                    if ($zoneJa) { return $true }
                    if ($zoneNein) { return $false }
                    $needDraw = $false
                }
                'WheelUp'   { $sel = 0 }
                'WheelDown' { $sel = 1 }
            }
        }
    }
    } finally {
        if (-not $hadApi) { Restore-SysPilotConsoleInput }
    }
}

function Confirm-SysPilot {
    param([string]$Question)
    return (Read-SysPilotYesNo $Question)
}

function Set-SysPilotConfigValue {
    <# Setzt einen Config-Wert (z.B. -Section Start -Key AlwaysAdmin -Value $true) und speichert config.json. #>
    param([string]$Section, [Parameter(Mandatory)][string]$Key, $Value)
    $path = Join-Path $script:SysPilotRoot 'config.json'
    $json = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($Section) {
        if (-not $json.$Section) { $json | Add-Member -NotePropertyName $Section -NotePropertyValue ([PSCustomObject]@{}) -Force }
        if ($json.$Section.PSObject.Properties[$Key]) { $json.$Section.$Key = $Value }
        else { $json.$Section | Add-Member -NotePropertyName $Key -NotePropertyValue $Value -Force }
    } else {
        if ($json.PSObject.Properties[$Key]) { $json.$Key = $Value }
        else { $json | Add-Member -NotePropertyName $Key -NotePropertyValue $Value -Force }
    }
    $json | ConvertTo-Json -Depth 10 | Set-Content $path -Encoding UTF8
    Reset-SysPilotConfig
}

function Get-SysPilotShortcutPaths {
    <# Alle SysPilot-Verknuepfungen (Desktop, Startmenue) - User + All Users. #>
    $dirs = @(
        [Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('CommonDesktopDirectory'),
        [Environment]::GetFolderPath('StartMenu'),
        [Environment]::GetFolderPath('CommonStartMenu')
    ) | Select-Object -Unique
    $found = @()
    foreach ($d in $dirs) {
        if (-not (Test-Path $d)) { continue }
        $found += Get-ChildItem $d -Recurse -Filter '*.lnk' -ErrorAction SilentlyContinue |
            Where-Object { $_.BaseName -like 'SysPilot*' } | Select-Object -ExpandProperty FullName
    }
    return $found
}

function Set-SysPilotShortcutRunAs {
    <# Setzt/entfernt "Als Administrator ausfuehren" auf allen SysPilot-Verknuepfungen.
       Trick: Byte 21 im .lnk (LinkFlags) mit 0x20 verodern = RunAsAdministrator. #>
    param([bool]$RunAs)
    $links = Get-SysPilotShortcutPaths
    $changed = 0
    foreach ($l in $links) {
        try {
            $bytes = [System.IO.File]::ReadAllBytes($l)
            if ($bytes.Length -lt 0x16) { continue }
            if ($RunAs) { $bytes[0x15] = $bytes[0x15] -bor 0x20 }
            else { $bytes[0x15] = $bytes[0x15] -band (-bnot 0x20) }
            [System.IO.File]::WriteAllBytes($l, $bytes)
            $changed++
        } catch { }
    }
    Write-SysPilotLog "Verknuepfungen 'Als Administrator ausfuehren' = $RunAs ($changed Links)"
    return $changed
}

function Write-SysPilotProgress {
    <# Fortschrittsanzeige in Prozent (einheitlich) #>
    param(
        [Parameter(Mandatory)][string]$Activity,
        [Parameter(Mandatory)][int]$Current,
        [Parameter(Mandatory)][int]$Total,
        [string]$Status = ''
    )
    $pct = if ($Total -gt 0) { [math]::Round(100 * $Current / $Total) } else { 0 }
    Write-Progress -Activity $Activity -Status "$Status ($Current/$Total)" -PercentComplete $pct
}

function Complete-SysPilotProgress {
    param([string]$Activity = 'Fertig')
    Write-Progress -Activity $Activity -Completed
}

function Clear-SysPilotPendingKeys {
    <# Verwirft Tastendruecke, die waehrend langsamer Vorarbeit im
       Konsolen-Tastenpuffer liegen geblieben sind. Sonst wird z.B. ein
       versehentliches Enter sofort als Menueauswahl verarbeitet. #>
    try {
        while ([Console]::KeyAvailable) {
            [void]$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        }
    } catch { }
}

$script:ConsoleInputReady = $false
$script:ConsoleInputHandle = [IntPtr]::Zero
$script:ConsoleInputOrigMode = 0

function Initialize-SysPilotConsoleInput {
    <# Aktiviert Maus-Events in der Konsole (ENABLE_MOUSE_INPUT) und
       deaktiviert QuickEdit (ENABLE_QUICK_EDIT_MODE = 0x40): Solange
       QuickEdit an ist, behandelt conhost die Maus selbst (Textauswahl)
       und liefert KEINE Mouse-Records an die App - ohne das Ausschalten
       bleiben Klicks/Rad wirkungslos. Der Original-Modus wird gespeichert
       und in Restore-SysPilotConsoleInput wiederhergestellt. #>
    if ($script:ConsoleInputReady) { return ($script:ConsoleInputHandle -ne [IntPtr]::Zero) }
    try {
        if (-not ('SysPilotConsoleInput' -as [type])) { return $false }
        $h = [SysPilotConsoleInput]::GetStdHandle(-10)
        if ($h.ToInt64() -eq -1 -or $h -eq [IntPtr]::Zero) { return $false }
        $mode = 0
        if (-not [SysPilotConsoleInput]::GetConsoleMode($h, [ref]$mode)) { return $false }
        $script:ConsoleInputOrigMode = $mode
        $newMode = ($mode -bor 0x0010) -band (-bnot 0x0040)
        [void][SysPilotConsoleInput]::SetConsoleMode($h, $newMode)
        $script:ConsoleInputHandle = $h
        $script:ConsoleInputReady = $true
        return $true
    } catch { return $false }
}

function Restore-SysPilotConsoleInput {
    <# Stellt den urspruenglichen Konsolen-Input-Modus wieder her. #>
    if ($script:ConsoleInputReady -and $script:ConsoleInputHandle -ne [IntPtr]::Zero) {
        try { [void][SysPilotConsoleInput]::SetConsoleMode($script:ConsoleInputHandle, $script:ConsoleInputOrigMode) } catch { }
        $script:ConsoleInputHandle = [IntPtr]::Zero
        $script:ConsoleInputReady = $false
    }
}

function Clear-SysPilotConsoleInputBuffer {
    <# Verwirft alle pending Tastatur-/Maus-Records (blockierungsfrei). #>
    if ($null -ne $script:_menuEventQueue) { $script:_menuEventQueue.Clear() }
    if (-not (Initialize-SysPilotConsoleInput)) { return }
    $buf = [Array]::CreateInstance([type]'SysPilotConsoleInput+INPUT_RECORD', 128)
    while ([SysPilotConsoleInput]::WaitForSingleObject($script:ConsoleInputHandle, 0) -eq 0) {
        $n = 0
        [void][SysPilotConsoleInput]::ReadConsoleInput($script:ConsoleInputHandle, $buf, 128, [ref]$n)
        if ($n -lt 128) { break }
    }
}

$script:_menuEventQueue = $null

function ConvertTo-SysPilotMenuEventRecord {
    <# Wandelt einen INPUT_RECORD in ein Event-Hashtable um oder $null
       (Key-Up, Focus, rechte Maustaste usw. werden uebersprungen). #>
    param($Rec)
    if ($Rec.EventType -eq 1) {
        if ($Rec.KeyEvent.bKeyDown -eq 0) { return $null }
        return @{ Kind = 'Key'; Vk = [int]$Rec.KeyEvent.wVirtualKeyCode }
    }
    if ($Rec.EventType -eq 2) {
        $me = $Rec.MouseEvent
        $flags = [uint32]$me.dwEventFlags
        $btn = [uint32]$me.dwButtonState
        $row = [int]$me.dwMousePosition.Y
        $col = [int]$me.dwMousePosition.X
        if (($flags -band 0x0004) -ne 0) {   # MOUSE_WHEELED (0x04, nicht 0x02=DoubleClick)
            $hi = [int](($btn -shr 16) -band 0xFFFF)
            if ($hi -ge 0x8000) { $hi -= 0x10000 }
            return @{ Kind = 'Mouse'; Action = $(if ($hi -gt 0) { 'WheelUp' } else { 'WheelDown' }); Row = $row; Col = $col }
        }
        if (($flags -band 0x0001) -ne 0) {
            return @{ Kind = 'Mouse'; Action = 'Move'; Row = $row; Col = $col }
        }
        if (($btn -band 0x0001) -ne 0) {
            return @{ Kind = 'Mouse'; Action = 'Click'; Row = $row; Col = $col }
        }
    }
    return $null
}

function Read-SysPilotMenuEvent {
    <# Liest blockierend das naechste Tastatur- oder Maus-Event.
       ReadConsoleInput liefert bis zu 32 Records pro Aufruf - ALLE werden
       in einer Queue zwischengespeichert, sonst gingen Events verloren
       (z.B. Pfeiltaste hinter einer Mausbewegung im selben Paket).
       Rueckgabe: @{Kind='Key'; Vk=<int>} oder
                  @{Kind='Mouse'; Action='Move'|'Click'|'WheelUp'|'WheelDown'; Row=<int>; Col=<int>}
       Ohne Console-API: Fallback auf ReadKey (Tastatur-only). #>
    if (-not (Initialize-SysPilotConsoleInput)) {
        $k = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        return @{ Kind = 'Key'; Vk = [int]$k.VirtualKeyCode }
    }
    if ($null -eq $script:_menuEventQueue) { $script:_menuEventQueue = New-Object System.Collections.Queue }
    $buf = [Array]::CreateInstance([type]'SysPilotConsoleInput+INPUT_RECORD', 32)
    while ($true) {
        if ($script:_menuEventQueue.Count -gt 0) { return $script:_menuEventQueue.Dequeue() }
        [void][SysPilotConsoleInput]::WaitForSingleObject($script:ConsoleInputHandle, [uint32]::MaxValue)
        $n = 0
        [void][SysPilotConsoleInput]::ReadConsoleInput($script:ConsoleInputHandle, $buf, 32, [ref]$n)
        for ($i = 0; $i -lt $n; $i++) {
            $ev = ConvertTo-SysPilotMenuEventRecord $buf[$i]
            if ($null -eq $ev) { continue }
            # Move-Events sind transient: bei voller Queue verwerfen, nie blockieren
            if ($ev.Action -eq 'Move' -and $script:_menuEventQueue.Count -ge 100) { continue }
            $script:_menuEventQueue.Enqueue($ev)
        }
    }
}

function Show-SysPilotArrowMenu {
    <# Pfeiltasten-Menue: hoch/runter, Bild auf/ab, Pos1/Ende, Enter = waehlen, Esc = zurueck.
       Maus: Linksklick auf Eintrag = auswaehlen, Mausrad = blättern, Hover = Markierung.
       Items: Array von @{ Label; Color; Tag } - gibt Tag des gewaehlten Eintrags zurueck oder $null bei Esc.
       Lange Listen scrollen automatisch (an Fensterhoehe angepasst). -StartIndex merkt die Position. #>
    param(
        [Parameter(Mandatory)][array]$Items,
        [string]$Title = '',
        [string]$Footer = 'Pfeiltasten hoch/runter, Enter = waehlen, Esc = zurueck',
        [int]$StartIndex = 0
    )
    if ($Items.Count -eq 0) { return $null }
    Clear-SysPilotPendingKeys
    $useApi = Initialize-SysPilotConsoleInput
    if ($useApi) { Clear-SysPilotConsoleInputBuffer }
    $sel = [math]::Max(0, [math]::Min($StartIndex, $Items.Count - 1))
    $top = 0
    $itemStartRow = $(if ($Title) { 3 } else { 0 })
    try {
    $needDraw = $true
    while ($true) {
        $winH = 30
        try { $winH = [Console]::WindowHeight } catch { }
        $reserve = 4 + $(if ($Title) { 3 } else { 0 })
        $page = [math]::Max(5, $winH - $reserve)
        if ($Items.Count -lt $page) { $page = $Items.Count }
        if ($sel -lt $top) { $top = $sel }
        if ($sel -ge $top + $page) { $top = $sel - $page + 1 }
        $top = [math]::Max(0, [math]::Min($top, $Items.Count - $page))

        if ($needDraw) {
            Clear-Host
            if ($Title) {
                Write-Host ""
                Write-Host "  $Title" -ForegroundColor Cyan
                Write-Host ""
            }
            $itemStartRow = $Host.UI.RawUI.CursorPosition.Y
            for ($i = $top; $i -lt ($top + $page); $i++) {
                $it = $Items[$i]
                $prefix = if ($i -eq $sel) { ' > ' } else { '   ' }
                $color = if ($i -eq $sel) { 'Black' } else { if ($it.Color) { $it.Color } else { 'White' } }
                $line = "$prefix$($it.Label)"
                if ($i -eq $sel) { Write-Host $line -ForegroundColor $color -BackgroundColor Cyan }
                else { Write-Host $line -ForegroundColor $color }
            }
            Write-Host ""
            $more = if ($Items.Count -gt $page) { "  [{0}/{1}]" -f ($sel + 1), $Items.Count } else { '' }
            Write-Host ("  $Footer" + $more) -ForegroundColor DarkGray
        }
        $needDraw = $true
        $ev = Read-SysPilotMenuEvent
        if ($ev.Kind -eq 'Key') {
            switch ([int]$ev.Vk) {
                38 { $sel = ($sel - 1 + $Items.Count) % $Items.Count }
                40 { $sel = ($sel + 1) % $Items.Count }
                33 { $sel = [math]::Max(0, $sel - $page) }
                34 { $sel = [math]::Min($Items.Count - 1, $sel + $page) }
                36 { $sel = 0 }
                35 { $sel = $Items.Count - 1 }
                27 { return $null }
                13 { return $Items[$sel].Tag }
            }
        } else {
            $idx = [int]$ev.Row - $itemStartRow + $top
            switch ($ev.Action) {
                'Move' {
                    if ($idx -ge $top -and $idx -lt ($top + $page) -and $idx -ne $sel) { $sel = $idx }
                    else { $needDraw = $false }
                }
                'Click' {
                    if ($idx -ge $top -and $idx -lt ($top + $page)) { return $Items[$idx].Tag }
                    else { $needDraw = $false }
                }
                'WheelUp'   { $sel = ($sel - 1 + $Items.Count) % $Items.Count }
                'WheelDown' { $sel = ($sel + 1) % $Items.Count }
            }
        }
    }
    } finally {
        if ($useApi) { Restore-SysPilotConsoleInput }
    }
}

function Show-SysPilotMultiSelectMenu {
    <# Mehrfachauswahl per Pfeiltasten: hoch/runter, Leertaste = Haken,
       Enter = Auswahl bestaetigen, Esc = abbrechen.
       Maus: Linksklick auf Eintrag = Haken umschalten, Mausrad = blaettern.
       Items: Array von @{ Label; Color; Tag; Checked } - gibt Array der
       Tags der abgehakten Eintraege zurueck oder $null bei Esc. #>
    param(
        [Parameter(Mandatory)][array]$Items,
        [string]$Title = '',
        [string]$Footer = 'Pfeiltasten, Leertaste = auswaehlen, Enter = uebernehmen, Esc = abbrechen'
    )
    if ($Items.Count -eq 0) { return @() }
    Clear-SysPilotPendingKeys
    $useApi = Initialize-SysPilotConsoleInput
    if ($useApi) { Clear-SysPilotConsoleInputBuffer }
    $sel = 0
    $itemStartRow = $(if ($Title) { 3 } else { 0 })
    try {
    $needDraw = $true
    while ($true) {
        if ($needDraw) {
            Clear-Host
            if ($Title) {
                Write-Host ""
                Write-Host "  $Title" -ForegroundColor Cyan
                Write-Host ""
            }
            $itemStartRow = $Host.UI.RawUI.CursorPosition.Y
            for ($i = 0; $i -lt $Items.Count; $i++) {
                $it = $Items[$i]
                $mark = if ($it.Checked) { '[x]' } else { '[ ]' }
                $prefix = if ($i -eq $sel) { ' > ' } else { '   ' }
                $line = "$prefix$mark $($it.Label)"
                if ($i -eq $sel) { Write-Host $line -ForegroundColor Black -BackgroundColor Cyan }
                else { Write-Host $line -ForegroundColor $(if ($it.Checked) { 'Green' } else { if ($it.Color) { $it.Color } else { 'White' } }) }
            }
            Write-Host ""
            $cnt = @($Items | Where-Object { $_.Checked }).Count
            Write-Host ("  $Footer  |  ausgewaehlt: $cnt") -ForegroundColor DarkGray
        }
        $needDraw = $true
        $ev = Read-SysPilotMenuEvent
        if ($ev.Kind -eq 'Key') {
            switch ([int]$ev.Vk) {
                38 { $sel = ($sel - 1 + $Items.Count) % $Items.Count }
                40 { $sel = ($sel + 1) % $Items.Count }
                36 { $sel = 0 }
                35 { $sel = $Items.Count - 1 }
                27 { return $null }
                13 {
                    $out = @()
                    foreach ($it in $Items) { if ($it.Checked) { $out += $it.Tag } }
                    if ($out.Count -eq 0) { continue }
                    return $out
                }
                32 { $Items[$sel].Checked = -not $Items[$sel].Checked }
            }
        } else {
            $idx = [int]$ev.Row - $itemStartRow
            switch ($ev.Action) {
                'Move' {
                    if ($idx -ge 0 -and $idx -lt $Items.Count -and $idx -ne $sel) { $sel = $idx }
                    else { $needDraw = $false }
                }
                'Click' {
                    if ($idx -ge 0 -and $idx -lt $Items.Count) { $Items[$idx].Checked = -not $Items[$idx].Checked }
                    else { $needDraw = $false }
                }
                'WheelUp'   { $sel = ($sel - 1 + $Items.Count) % $Items.Count }
                'WheelDown' { $sel = ($sel + 1) % $Items.Count }
            }
        }
    }
    } finally {
        if ($useApi) { Restore-SysPilotConsoleInput }
    }
}

function Test-SysPilotLaunchablePath {
    <# $true wenn der Pfad eine startbare Datei ist (.exe/.bat/.cmd/.com/
       .ps1/.lnk/.url/.msc/.reg). Verhindert, dass z.B. ein .ico- oder
       .png-DisplayIcon aus der Uninstall-Registry als "Programm" gestartet
       wird (Windows "Oeffnen mit"-Dialog). #>
    param([Parameter(Mandatory)][string]$Path)
    return ($Path -match '\.(exe|bat|cmd|com|ps1|lnk|url|msc|reg)$')
}

function Save-SysPilotUrlToFile {
    <# Lädt eine URL mit sichtbarem Fortschritt (Prozent + MB).
       Gibt $true bei Erfolg zurück. #>
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile,
        [int]$TimeoutSec = 600,
        [string]$Label = 'Download'
    )
    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add('User-Agent', 'SysPilot/0.9')
    $total = 0L; $received = 0L
    $script:dlTotal = 0L; $script:dlReceived = 0L
    $wc.add_DownloadProgressChanged({
        param($s, $e)
        $script:dlTotal = $e.TotalBytesToReceive
        $script:dlReceived = $e.BytesReceived
    })
    try {
        $wc.DownloadFileAsync($Uri, $OutFile)
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($wc.IsBusy) {
            Start-Sleep -Milliseconds 250
            $t = $script:dlTotal; $r = $script:dlReceived
            if ($t -gt 0) {
                $pct = [math]::Min(100, [math]::Round($r * 100 / $t))
                $mbR = [math]::Round($r / 1MB, 1); $mbT = [math]::Round($t / 1MB, 1)
                $spd = if ($sw.Elapsed.TotalSeconds -gt 1) { [math]::Round($r / 1MB / $sw.Elapsed.TotalSeconds, 1) } else { 0 }
                Write-Host ("`r  $Label : $pct%  ($mbR/$mbT MB, $spd MB/s)   ") -NoNewline
            } else {
                $mbR = [math]::Round($r / 1MB, 1)
                Write-Host ("`r  $Label : $mbR MB geladen...   ") -NoNewline
            }
            if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) { throw "Download-Timeout nach ${TimeoutSec}s" }
        }
        Write-Host ''
        return $true
    } catch {
        Write-Host ''
        Write-Host "  [!] Download fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    } finally {
        $wc.Dispose()
    }
}

Export-ModuleMember -Function ConvertTo-SysPilotArgString, Test-SysPilotAdmin, Assert-SysPilotAdmin, Restart-SysPilotElevated,
    Write-SysPilotLog, Get-SysPilotConfig, Reset-SysPilotConfig, Set-SysPilotConfigValue, Test-NameMatch,
    Get-SysPilotProcessByName, New-SysPilotBackup, Get-SysPilotBackupDir, Get-SysPilotBackups, Restore-SysPilotServices,
    Write-SysPilotHeader, Read-SysPilotChoice, Confirm-SysPilot, Show-SysPilotArrowMenu, Show-SysPilotMultiSelectMenu,
    Clear-SysPilotPendingKeys,
    Initialize-SysPilotConsoleInput, Restore-SysPilotConsoleInput, Read-SysPilotMenuEvent, Clear-SysPilotConsoleInputBuffer, Read-SysPilotYesNo,
    Save-SysPilotUrlToFile, Test-SysPilotLaunchablePath,
    Write-SysPilotProgress, Complete-SysPilotProgress, Get-SysPilotShortcutPaths, Set-SysPilotShortcutRunAs,
    Test-SysPilotGamingActive, Get-SysPilotPortableAppsDir, Get-SysPilotLocalSearchDirs
