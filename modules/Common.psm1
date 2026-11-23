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
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetConsoleScreenBufferInfo(IntPtr hConsoleOutput, out CONSOLE_SCREEN_BUFFER_INFO lpConsoleScreenBufferInfo);

    [StructLayout(LayoutKind.Sequential)] public struct COORD { public short X; public short Y; }
    [StructLayout(LayoutKind.Sequential)] public struct SMALL_RECT { public short Left; public short Top; public short Right; public short Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct CONSOLE_SCREEN_BUFFER_INFO {
        public COORD dwSize; public COORD dwCursorPosition; public short wAttributes;
        public SMALL_RECT srWindow; public COORD dwMaximumWindowSize;
    }
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

$script:_logSessionHeaderWritten = $false

function Write-SysPilotLog {
    <# Zentrales Log. Schreibt nach <root>\logs\syspilot-<datum>.log;
       falls das nicht beschreibbar ist (z.B. Program Files ohne Admin),
       Fallback auf %LOCALAPPDATA%\SysPilot\logs. Erste Zeile jeder
       Session = Header mit Version/PID/User/Admin. #>
    param([string]$Message, [string]$Level = "INFO")
    try {
        $candidates = @(
            (Join-Path $script:SysPilotRoot "logs"),
            (Join-Path $env:LOCALAPPDATA "SysPilot\logs")
        ) | Select-Object -Unique
        $line = "{0} [{1}] {2}" -f (Get-Date -Format "HH:mm:ss.fff"), $Level, $Message
        foreach ($d in $candidates) {
            try {
                if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d -ErrorAction Stop | Out-Null }
                $file = Join-Path $d ("syspilot-" + (Get-Date -Format "yyyy-MM-dd") + ".log")
                if (-not $script:_logSessionHeaderWritten) {
                    $script:_logSessionHeaderWritten = $true
                    $ver = ''
                    try { $ver = (Get-Content (Join-Path $script:SysPilotRoot 'version.txt') -Raw -ErrorAction Stop).Trim() } catch { }
                    $hdr = "=== SysPilot $ver | PID $PID | User $env:USERNAME | Admin $(Test-SysPilotAdmin) | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
                    Add-Content -Path $file -Value $hdr -Encoding UTF8 -ErrorAction Stop
                }
                Add-Content -Path $file -Value $line -Encoding UTF8 -ErrorAction Stop
                return
            } catch { }
        }
    } catch { }
}

function Write-SysPilotDebug {
    <# DETAIL-Log fuer Fehlersuche (Extension-Entfernung, Policy-Ops,
       Menue-Entscheidungen). Landet im selben Log mit Level DEBUG. #>
    param([Parameter(Mandatory)][string]$Message)
    Write-SysPilotLog -Message $Message -Level 'DEBUG'
}

function Get-SysPilotLogFiles {
    <# Alle vorhandenen Log-Dateien (beide moeglichen Orte). #>
    $dirs = @(
        (Join-Path $script:SysPilotRoot "logs"),
        (Join-Path $env:LOCALAPPDATA "SysPilot\logs")
    ) | Select-Object -Unique
    $files = @()
    foreach ($d in $dirs) {
        if (Test-Path $d) { $files += Get-ChildItem $d -Filter 'syspilot-*.log' -File -ErrorAction SilentlyContinue }
    }
    return $files | Sort-Object LastWriteTime -Descending
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

# =====================================================================
# Auto-Fix-Hilfen: Warnungen (veraltete Buckets/Quellen/Tools) einmalig
# pro Zeitfenster selbsttaetig beheben. Stamp-Dateien in
# %LOCALAPPDATA%\SysPilot\autofix\.
# =====================================================================

function Get-SysPilotAutoFixStampPath {
    param([Parameter(Mandatory)][string]$Name)
    $dir = Join-Path $env:LOCALAPPDATA 'SysPilot\autofix'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    return (Join-Path $dir ($Name + '.stamp'))
}

function Test-SysPilotAutoFixDue {
    <# $true, wenn der Auto-Fix fuer $Name laenger als $Hours nicht lief. #>
    param([Parameter(Mandatory)][string]$Name, [int]$Hours = 24)
    $stamp = Get-SysPilotAutoFixStampPath -Name $Name
    if (-not (Test-Path $stamp)) { return $true }
    return ((Get-Date) - (Get-Item $stamp).LastWriteTime).TotalHours -ge $Hours
}

function Save-SysPilotAutoFixStamp {
    param([Parameter(Mandatory)][string]$Name)
    Set-Content -Path (Get-SysPilotAutoFixStampPath -Name $Name) -Value (Get-Date -Format 'o') -ErrorAction SilentlyContinue
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
        $vp = Get-SysPilotConsoleViewport
        $winH = $vp.Rows
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

function Get-SysPilotConsoleViewport {
    <# Liefert die SICHTBARE Konsolen-Groesse (Viewport) in Zeichen.
       srWindow aus GetConsoleScreenBufferInfo ist in conhost UND
       Windows Terminal zuverlaessig; [Console]::WindowHeight kann in
       manchen Hosts die Buffer-Hoehe liefern (dann scrollt die Anzeige
       und Maus-Koordinaten stimmen nicht mehr). Fallback: Console-API. #>
    try {
        $h = [SysPilotConsoleInput]::GetStdHandle(-11)
        if ($h -ne [IntPtr]::Zero -and $h.ToInt64() -ne -1) {
            $info = New-Object SysPilotConsoleInput+CONSOLE_SCREEN_BUFFER_INFO
            if ([SysPilotConsoleInput]::GetConsoleScreenBufferInfo($h, [ref]$info)) {
                $rows = $info.srWindow.Bottom - $info.srWindow.Top + 1
                $cols = $info.srWindow.Right - $info.srWindow.Left + 1
                if ($rows -gt 0 -and $cols -gt 0) { return @{ Rows = [int]$rows; Cols = [int]$cols } }
            }
        }
    } catch { }
    $rows = 30; $cols = 120
    try { $rows = [Console]::WindowHeight } catch { }
    try { $cols = [Console]::WindowWidth } catch { }
    return @{ Rows = $rows; Cols = $cols }
}

function Show-SysPilotMultiSelectMenu {
    <# Mehrfachauswahl per Pfeiltasten: hoch/runter, Leertaste = Haken,
       Enter = Auswahl bestaetigen, Esc = abbrechen.
       Maus: Linksklick auf Eintrag = Haken umschalten, Mausrad = blaettern.
       Items: Array von @{ Label; Color; Tag; Checked } - gibt Array der
       Tags der abgehakten Eintraege zurueck oder $null bei Esc.
       Optional -Actions @(@{Label;Tag;Color}): zusaetzliche klickbare
       Buttons unter der Liste. Wenn gesetzt, gibt die Funktion IMMER ein
       Objekt zurueck: @{ Selected = @(Tags); Action = $null|<ActionTag> }.
       Tastatur: Ziffern 1-9 loesen Actions aus, Enter = Selected. #>
    param(
        [Parameter(Mandatory)][array]$Items,
        [string]$Title = '',
        [string]$Footer = 'Pfeiltasten/Klick, Leertaste = Haken, A = alle, Enter = uebernehmen, Esc = abbrechen',
        [array]$Actions = @()
    )
    if ($Items.Count -eq 0) { return @() }
    Clear-SysPilotPendingKeys
    $useApi = Initialize-SysPilotConsoleInput
    if ($useApi) { Clear-SysPilotConsoleInputBuffer }
    $sel = 0
    # Fenster-Darstellung: bei langen Listen nur eine Sichtscheibe zeichnen,
    # sonst flackert die Anzeige bei jedem Hover (Clear-Host + hunderte Zeilen).
    # WICHTIG: Die sichtbare Groesse wird aus der FENSTERHOEHE berechnet -
    # sonst scrollt die Konsole beim Zeichnen und die gespeicherten Zeilen-
    # positionen (itemStartRow/actionStartRow) stimmen nicht mehr mit den
    # Mausklick-Koordinaten ueberein (Highlight versetzt, Klicks falsch).
    $viewTop = 0
    $windowed = $false
    $viewSize = 0
    $actionStartRow = -1
    $actionCols = @()
    $hasActions = $Actions.Count -gt 0
    try {
    $needDraw = $true
    while ($true) {
        if ($needDraw) {
            # Zeilenbudget: Titel(3) + Items + Leer(1) + Buttons(2) + Footer(1)
            # Viewport-Hoehe aus der Console-API (srWindow) - zuverlaessig
            # in conhost UND Windows Terminal, anders als WindowHeight.
            $vp = Get-SysPilotConsoleViewport
            $winH = $vp.Rows
            $overhead = 2 + $(if ($hasActions) { 3 } else { 0 }) + $(if ($Title) { 3 } else { 0 })
            $viewSize = [Math]::Max(3, $winH - $overhead - 1)
            $windowed = $Items.Count -gt $viewSize
            Clear-Host
            if ($Title) {
                Write-Host ""
                Write-Host "  $Title" -ForegroundColor Cyan
                Write-Host ""
            }
            if ($windowed) {
                if ($sel -lt $viewTop) { $viewTop = $sel }
                if ($sel -ge $viewTop + $viewSize) { $viewTop = $sel - $viewSize + 1 }
                $viewTop = [Math]::Max(0, [Math]::Min($viewTop, $Items.Count - $viewSize))
            } else { $viewTop = 0 }
            $itemStartRow = $Host.UI.RawUI.CursorPosition.Y
            $viewEnd = if ($windowed) { [Math]::Min($Items.Count, $viewTop + $viewSize) } else { $Items.Count }
            for ($i = $viewTop; $i -lt $viewEnd; $i++) {
                $it = $Items[$i]
                $mark = if ($it.Checked) { '[x]' } else { '[ ]' }
                $prefix = if ($i -eq $sel) { ' > ' } else { '   ' }
                $line = "$prefix$mark $($it.Label)"
                if ($i -eq $sel) { Write-Host $line -ForegroundColor Black -BackgroundColor Cyan }
                else { Write-Host $line -ForegroundColor $(if ($it.Checked) { 'Green' } else { if ($it.Color) { $it.Color } else { 'White' } }) }
            }
            Write-Host ""
            $cnt = @($Items | Where-Object { $_.Checked }).Count
            $pos = if ($windowed) { "  Eintrag $($sel + 1)/$($Items.Count)  |  " } else { '' }
            if ($Actions.Count -gt 0) {
                # Buttons in EINER Zeile mit Abstand; Spalten werden fuer
                # Klick-Trefferatz gespeichert (actionCols: Start/End/Tag)
                $actionStartRow = $Host.UI.RawUI.CursorPosition.Y
                $actionCols = @()
                $colPos = 2
                Write-Host '  ' -NoNewline
                foreach ($a in $Actions) {
                    $btn = "[ $($a.Label) ]"
                    $actionCols += @{ Start = $colPos; End = $colPos + $btn.Length; Tag = $a.Tag }
                    $acol = if ($a.Color) { $a.Color } else { 'Green' }
                    Write-Host $btn -ForegroundColor $acol -NoNewline
                    Write-Host '   ' -NoNewline
                    $colPos += $btn.Length + 3
                }
                Write-Host ''
                Write-Host ""
            }
            Write-Host ("$pos$Footer  |  ausgewaehlt: $cnt") -ForegroundColor DarkGray
        }
        $needDraw = $true
        $ev = Read-SysPilotMenuEvent
        if ($ev.Kind -eq 'Key') {
            switch ([int]$ev.Vk) {
                38 { $sel = ($sel - 1 + $Items.Count) % $Items.Count }
                40 { $sel = ($sel + 1) % $Items.Count }
                33 { $sel = [Math]::Max(0, $sel - $viewSize) }
                34 { $sel = [Math]::Min($Items.Count - 1, $sel + $viewSize) }
                36 { $sel = 0 }
                35 { $sel = $Items.Count - 1 }
                27 { return $null }
                13 {
                    $out = @()
                    foreach ($it in $Items) { if ($it.Checked) { $out += $it.Tag } }
                    if ($out.Count -eq 0) { continue }
                    if ($hasActions) { return [PSCustomObject]@{ Selected = $out; Action = $null } }
                    return $out
                }
                32 { $Items[$sel].Checked = -not $Items[$sel].Checked }
                65 { foreach ($it in $Items) { $it.Checked = $true } }
                { [int]$ev.Vk -ge 49 -and [int]$ev.Vk -le 57 -and $hasActions } {
                    $ai = [int]$ev.Vk - 49
                    if ($ai -lt $Actions.Count) {
                        $selTags = @(); foreach ($it in $Items) { if ($it.Checked) { $selTags += $it.Tag } }
                        return [PSCustomObject]@{ Selected = $selTags; Action = $Actions[$ai].Tag }
                    }
                }
            }
        } else {
            # Klick auf Aktions-Button? (eine Zeile, Spalten-Test per Col)
            if ($hasActions -and $actionStartRow -ge 0 -and [int]$ev.Row -eq $actionStartRow -and $ev.Action -eq 'Click') {
                foreach ($ac in $actionCols) {
                    if ([int]$ev.Col -ge $ac.Start -and [int]$ev.Col -lt $ac.End) {
                        $selTags = @(); foreach ($it in $Items) { if ($it.Checked) { $selTags += $it.Tag } }
                        return [PSCustomObject]@{ Selected = $selTags; Action = $ac.Tag }
                    }
                }
                $needDraw = $false
            }
            $idx = $viewTop + ([int]$ev.Row - $itemStartRow)
            $inView = ($idx -ge $viewTop -and $idx -lt $viewEnd)
            switch ($ev.Action) {
                'Move' {
                    if ($inView -and $idx -ne $sel) { $sel = $idx }
                    else { $needDraw = $false }
                }
                'Click' {
                    if ($inView) { $Items[$idx].Checked = -not $Items[$idx].Checked }
                    else { $needDraw = $false }
                }
                'WheelUp'   { $step = [Math]::Max(3, [int]($viewSize / 3)); $sel = [Math]::Max(0, $sel - $step) }
                'WheelDown' { $step = [Math]::Max(3, [int]($viewSize / 3)); $sel = [Math]::Min($Items.Count - 1, $sel + $step) }
            }
        }
    }
    } finally {
        if ($useApi) { Restore-SysPilotConsoleInput }
    }
}

function Find-SysPilotJsonSection {
    <# Findet "Key":<Wert> in JSON-Text per Regex + Klammer-Scanning
       (stringsicher). Gibt @{ Start; End; Text } zurueck, wobei Start/End
       den WERT (ohne "Key":) im Originaltext markieren, oder $null.
       -MustContain <key>: ueberspringt Kandidaten, deren Wert den
       Unter-Schluessel NICHT enthaelt - noetig bei mehrdeutigen Keys
       (z.B. "extensions" kommt in Chromium-Prefs mehrfach vor:
       account_values.extensions.ui, echtes extensions.settings,
       protection.macs.extensions - nur das echte hat "settings"). #>
    param([Parameter(Mandatory)][string]$Json, [Parameter(Mandatory)][string]$Key,
          [string]$MustContain = '')
    $rx = New-Object System.Text.RegularExpressions.Regex('"' + [regex]::Escape($Key) + '"\s*:')
    $searchFrom = 0
    $len = $Json.Length
    while ($searchFrom -lt $len) {
        $m = $rx.Match($Json, $searchFrom)
        if (-not $m.Success) { return $null }
        $i = $m.Index + $m.Length
        while ($i -lt $len -and [char]::IsWhiteSpace($Json[$i])) { $i++ }
        if ($i -ge $len) { return $null }
        $open = $Json[$i]
        if ($open -eq '{' -or $open -eq '[') {
            $close = if ($open -eq '{') { '}' } else { ']' }
            $depth = 0; $inStr = $false; $esc = $false; $endIdx = -1
            for ($j = $i; $j -lt $len; $j++) {
                $c = $Json[$j]
                if ($inStr) {
                    if ($esc) { $esc = $false }
                    elseif ($c -eq '\') { $esc = $true }
                    elseif ($c -eq '"') { $inStr = $false }
                    continue
                }
                if ($c -eq '"') { $inStr = $true }
                elseif ($c -eq $open) { $depth++ }
                elseif ($c -eq $close) {
                    $depth--
                    if ($depth -eq 0) { $endIdx = $j + 1; break }
                }
            }
            if ($endIdx -lt 0) { return $null }
            $txt = $Json.Substring($i, $endIdx - $i)
            if ($MustContain -and $txt -notmatch ('"' + [regex]::Escape($MustContain) + '"\s*:')) {
                $searchFrom = $m.Index + $m.Length
                continue
            }
            return @{ Start = $i; End = $endIdx; Text = $txt }
        }
        $j = $i; $inStr = $false; $esc = $false
        while ($j -lt $len) {
            $c = $Json[$j]
            if ($inStr) {
                if ($esc) { $esc = $false }
                elseif ($c -eq '\') { $esc = $true }
                elseif ($c -eq '"') { $inStr = $false }
                $j++; continue
            }
            if ($c -eq '"') { $inStr = $true; $j++; continue }
            if ($c -eq ',' -or $c -eq '}' -or $c -eq ']') { break }
            $j++
        }
        $txt = $Json.Substring($i, $j - $i).Trim()
        if ($MustContain -and $txt -notmatch ('"' + [regex]::Escape($MustContain) + '"\s*:')) {
            $searchFrom = $m.Index + $m.Length
            continue
        }
        return @{ Start = $i; End = $j; Text = $txt }
    }
    return $null
}

function Get-SysPilotJsonChildProperties {
    <# Listet die DIREKTEN Kind-Elemente eines JSON-Objekt-Texts
       ({"k":v,...}) per Scanner auf - stringsicher, unveraendert den Text.
       Gibt Array von @{ Key; KeyStart; ValueStart; ValueEnd; Value } zurueck
       (Value = Rohtext des Werts). Benoetigt fuer Dateien mit doppelten
       Schluesseln, die ConvertFrom-Json nicht parsen kann. #>
    param([Parameter(Mandatory)][string]$Json)
    $props = @()
    $len = $Json.Length
    $i = 0
    # oeffnende Klammer ueberspringen
    while ($i -lt $len -and [char]::IsWhiteSpace($Json[$i])) { $i++ }
    if ($i -ge $len -or $Json[$i] -ne '{') { return $props }
    $i++
    while ($i -lt $len) {
        while ($i -lt $len -and [char]::IsWhiteSpace($Json[$i])) { $i++ }
        if ($i -ge $len -or $Json[$i] -eq '}') { break }
        if ($Json[$i] -ne '"') { break }
        $keyStart = $i
        $i++
        $key = ''
        $esc = $false
        while ($i -lt $len) {
            $c = $Json[$i]
            if ($esc) {
                switch ($c) { 'n' { $key += "`n" } 't' { $key += "`t" } 'r' { $key += "`r" } default { $key += $c } }
                $esc = $false; $i++; continue
            }
            if ($c -eq '\') { $esc = $true; $i++; continue }
            if ($c -eq '"') { $i++; break }
            $key += $c; $i++
        }
        while ($i -lt $len -and [char]::IsWhiteSpace($Json[$i])) { $i++ }
        if ($i -ge $len -or $Json[$i] -ne ':') { break }
        $i++
        while ($i -lt $len -and [char]::IsWhiteSpace($Json[$i])) { $i++ }
        $vStart = $i
        if ($i -ge $len) { break }
        $c = $Json[$i]
        if ($c -eq '{' -or $c -eq '[') {
            $open = $c; $close = $(if ($open -eq '{') { '}' } else { ']' })
            $depth = 0; $inStr = $false; $esc = $false; $vEnd = -1
            for ($j = $i; $j -lt $len; $j++) {
                $ch = $Json[$j]
                if ($inStr) {
                    if ($esc) { $esc = $false }
                    elseif ($ch -eq '\') { $esc = $true }
                    elseif ($ch -eq '"') { $inStr = $false }
                    continue
                }
                if ($ch -eq '"') { $inStr = $true }
                elseif ($ch -eq $open) { $depth++ }
                elseif ($ch -eq $close) {
                    $depth--
                    if ($depth -eq 0) { $vEnd = $j + 1; break }
                }
            }
            if ($vEnd -lt 0) { break }
            $props += @{ Key = $key; KeyStart = $keyStart; ValueStart = $vStart; ValueEnd = $vEnd; Value = $Json.Substring($vStart, $vEnd - $vStart) }
            $i = $vEnd
        } else {
            $inStr = $false; $esc = $false; $vEnd = $i
            while ($vEnd -lt $len) {
                $ch = $Json[$vEnd]
                if ($inStr) {
                    if ($esc) { $esc = $false }
                    elseif ($ch -eq '\') { $esc = $true }
                    elseif ($ch -eq '"') { $inStr = $false }
                    $vEnd++; continue
                }
                if ($ch -eq '"') { $inStr = $true; $vEnd++; continue }
                if ($ch -eq ',' -or $ch -eq '}' -or $ch -eq ']') { break }
                $vEnd++
            }
            $props += @{ Key = $key; KeyStart = $keyStart; ValueStart = $vStart; ValueEnd = $vEnd; Value = $Json.Substring($vStart, $vEnd - $vStart).Trim() }
            $i = $vEnd
        }
        while ($i -lt $len -and [char]::IsWhiteSpace($Json[$i])) { $i++ }
        if ($i -lt $len -and $Json[$i] -eq ',') { $i++; continue }
        break
    }
    return $props
}

function ConvertFrom-SysPilotJsonScalar {
    <# Wandelt einen JSON-Skalar-Rohtext in einen PS-Wert um. #>
    param([Parameter(Mandatory)][string]$Text)
    $t = $Text.Trim()
    if ($t.Length -ge 2 -and $t[0] -eq '"' -and $t[$t.Length-1] -eq '"') {
        $inner = $t.Substring(1, $t.Length - 2)
        return ($inner -replace '\\"','"' -replace '\\\\','\')
    }
    if ($t -match '^-?\d+$') { return [int64]$t }
    if ($t -match '^-?\d+\.\d+$') { return [double]$t }
    if ($t -eq 'true') { return $true }
    if ($t -eq 'false') { return $false }
    return $t
}

function Get-SysPilotJsonSectionText {
    <# Text des Werts eines JSON-Objekt-Schluessels (siehe Find-...#Section). #>
    param([Parameter(Mandatory)][string]$Json, [Parameter(Mandatory)][string]$Key, [string]$MustContain = '')
    $s = Find-SysPilotJsonSection -Json $Json -Key $Key -MustContain $MustContain
    if ($null -eq $s) { return $null }
    return $s.Text
}

function Get-SysPilotChromiumExtensionSettings {
    <# Liest extensions.settings aus einer Chromium-Prefs-Datei
       (Secure Preferences/Preferences). Schneller Pfad: komplettes
       ConvertFrom-Json. Fallback: Scanner-basierte Extraktion, weil
       z.B. Edge-Dateien doppelte Schluessel enthalten
       (macroEnabled.12/macroenabled.12) und ConvertFrom-Json dann
       komplett scheitert - der Fallback baut pro Extension ein
       minimales Objekt (manifest.name/version/type + state).
       Gibt $null zurueck, wenn nichts da. #>
    param([Parameter(Mandatory)][string]$PrefPath)
    $raw = Read-SysPilotFileRaw -Path $PrefPath
    if (-not $raw) { return $null }
    try {
        $j = $raw | ConvertFrom-Json
        if ($j.extensions -and $j.extensions.settings) { return $j.extensions.settings }
        return $null
    } catch { }
    $ext = Get-SysPilotJsonSectionText -Json $raw -Key 'extensions' -MustContain 'settings'
    if (-not $ext) { return $null }
    $set = Get-SysPilotJsonSectionText -Json $ext -Key 'settings'
    if (-not $set) { return $null }
    # Scanner-Fallback: Kind-Elemente von settings durchgehen
    $result = [PSCustomObject]@{}
    $count = 0
    foreach ($pr in (Get-SysPilotJsonChildProperties -Json $set)) {
        $manifest = $null; $state = $null
        foreach ($ch in (Get-SysPilotJsonChildProperties -Json $pr.Value)) {
            if ($ch.Key -eq 'manifest') {
                $mObj = [PSCustomObject]@{ name = $null; version = $null; type = $null }
                foreach ($mc in (Get-SysPilotJsonChildProperties -Json $ch.Value)) {
                    if ($mc.Key -eq 'name')    { $mObj.name = ConvertFrom-SysPilotJsonScalar -Text $mc.Value }
                    elseif ($mc.Key -eq 'version') { $mObj.version = ConvertFrom-SysPilotJsonScalar -Text $mc.Value }
                    elseif ($mc.Key -eq 'type')   { $mObj.type = ConvertFrom-SysPilotJsonScalar -Text $mc.Value }
                }
                $manifest = $mObj
            } elseif ($ch.Key -eq 'state') {
                $state = ConvertFrom-SysPilotJsonScalar -Text $ch.Value
            }
        }
        $entry = [PSCustomObject]@{ manifest = $manifest; state = $state }
        $result | Add-Member -NotePropertyName $pr.Key -NotePropertyValue $entry -Force
        $count++
    }
    if ($count -eq 0) { return $null }
    return $result
}

function Remove-SysPilotJsonPropertyText {
    <# Entfernt "Key":<Wert> inkl. Komma aus JSON-Objekt-Text, ohne den
       Rest des Dokuments anzufassen (roh-Text, stringsicher).
       Gibt den neuen Text zurueck oder $null, wenn Key nicht vorhanden. #>
    param([Parameter(Mandatory)][string]$Json, [Parameter(Mandatory)][string]$Key)
    $m = [regex]::Match($Json, '"' + [regex]::Escape($Key) + '"\s*:')
    if (-not $m.Success) { return $null }
    $keyStart = $m.Index
    $i = $m.Index + $m.Length
    while ($i -lt $Json.Length -and [char]::IsWhiteSpace($Json[$i])) { $i++ }
    if ($i -ge $Json.Length) { return $null }
    $open = $Json[$i]
    $end = $i
    if ($open -eq '{' -or $open -eq '[') {
        $close = if ($open -eq '{') { '}' } else { ']' }
        $depth = 0; $inStr = $false; $esc = $false; $found = $false
        for ($j = $i; $j -lt $Json.Length; $j++) {
            $c = $Json[$j]
            if ($inStr) {
                if ($esc) { $esc = $false }
                elseif ($c -eq '\') { $esc = $true }
                elseif ($c -eq '"') { $inStr = $false }
                continue
            }
            if ($c -eq '"') { $inStr = $true }
            elseif ($c -eq $open) { $depth++ }
            elseif ($c -eq $close) {
                $depth--
                if ($depth -eq 0) { $end = $j + 1; $found = $true; break }
            }
        }
        if (-not $found) { return $null }
    } else {
        $inStr = $false; $esc = $false
        while ($end -lt $Json.Length) {
            $c = $Json[$end]
            if ($inStr) {
                if ($esc) { $esc = $false }
                elseif ($c -eq '\') { $esc = $true }
                elseif ($c -eq '"') { $inStr = $false }
                $end++; continue
            }
            if ($c -eq '"') { $inStr = $true; $end++; continue }
            if ($c -eq ',' -or $c -eq '}' -or $c -eq ']') { break }
            $end++
        }
    }
    # Komma mit entfernen: direkt vor dem Key (",\"id\":{...}") oder dahinter.
    # Vorwaerts-Scan auf das letzte nicht-leere Zeichen vor dem Key -
    # robust gegen Kommas in Strings frueherer Werte.
    $k = $keyStart - 1
    while ($k -ge 0 -and [char]::IsWhiteSpace($Json[$k])) { $k-- }
    if ($k -ge 0 -and $Json[$k] -eq ',') {
        return $Json.Substring(0, $k) + $Json.Substring($end)
    }
    $after = $Json.Substring($end)
    if ($after -match '^\s*,') {
        $skip = $after.IndexOf(',') + 1
        return $Json.Substring(0, $keyStart) + $after.Substring($skip)
    }
    return $Json.Substring(0, $keyStart) + $Json.Substring($end)
}

function Read-SysPilotFileRaw {
    <# Liest eine Textdatei mit FileShare.ReadWrite - funktioniert auch
       wenn ein Browser die Datei gerade schreibt/liest. #>
    param([Parameter(Mandatory)][string]$Path)
    $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
        try { return $sr.ReadToEnd() } finally { $sr.Close() }
    } finally { $fs.Close() }
}

function Write-SysPilotFileRaw {
    <# Schreibt Text OHNE BOM (UTF8-Encoding($false)) mit
       FileShare.ReadWrite und Retry - Chromium-Prefs (Secure
       Preferences/extensions.json) dürfen keinen BOM haben, sonst
       werte der Browser die Datei evtl. als korrupt und stellt
       Einträge wieder her. #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Content)
    $enc = New-Object System.Text.UTF8Encoding($false)
    $lastErr = $null
    for ($try = 0; $try -lt 4; $try++) {
        try {
            $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Create,
                [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
            try {
                $sw = New-Object System.IO.StreamWriter($fs, $enc)
                try { $sw.Write($Content) } finally { $sw.Close() }
            } finally { $fs.Close() }
            return $true
        } catch {
            $lastErr = $_.Exception.Message
            Start-Sleep -Milliseconds 300
        }
    }
    throw "Schreiben fehlgeschlagen: $lastErr"
}

function Remove-SysPilotPrefExtensionEntry {
    <# Entfernt eine Extension-ID aus extensions.settings UND
       extensions.alerts einer Chromium-Prefs-Datei per Rohtext-Edit
       (funktioniert auch bei doppelt verKeys wie in Edge-Dateien,
       wo ConvertFrom/To-Json scheitert). Gibt $true bei Aenderung. #>
    param([Parameter(Mandatory)][string]$FilePath, [Parameter(Mandatory)][string]$ExtId)
    $raw = Read-SysPilotFileRaw -Path $FilePath
    if (-not $raw) { return $false }
    $new = $raw
    foreach ($sub in @('settings', 'alerts')) {
        # "extensions" kommt in Chromium-Prefs mehrfach vor
        # (account_values.extensions.ui, protection.macs.extensions) -
        # nur die Sektion mit dem jeweiligen Unter-Key ist die echte.
        $extSec = Find-SysPilotJsonSection -Json $new -Key 'extensions' -MustContain $sub
        if ($null -eq $extSec) { Write-SysPilotDebug "  PrefEdit $($FilePath | Split-Path -Leaf): extensions-Sektion fuer '$sub' nicht gefunden"; continue }
        $subSec = Find-SysPilotJsonSection -Json $extSec.Text -Key $sub
        if ($null -eq $subSec) { Write-SysPilotDebug "  PrefEdit $($FilePath | Split-Path -Leaf): '$sub'-Sektion nicht gefunden"; continue }
        $subNew = Remove-SysPilotJsonPropertyText -Json $subSec.Text -Key $ExtId
        if ($null -eq $subNew) { Write-SysPilotDebug "  PrefEdit $($FilePath | Split-Path -Leaf): ID $ExtId nicht in $sub"; continue }
        Write-SysPilotDebug "  PrefEdit $($FilePath | Split-Path -Leaf): ID $ExtId aus $sub entfernt"
        $innerNew = $extSec.Text.Substring(0, $subSec.Start) + $subNew + $extSec.Text.Substring($subSec.End)
        $new = $new.Substring(0, $extSec.Start) + $innerNew + $new.Substring($extSec.End)
    }
    if ($new -ne $raw) {
        Write-SysPilotFileRaw -Path $FilePath -Content $new | Out-Null
        return $true
    }
    return $false
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
    Write-SysPilotLog, Write-SysPilotDebug, Get-SysPilotLogFiles, Get-SysPilotConfig, Reset-SysPilotConfig, Set-SysPilotConfigValue, Test-NameMatch,
    Get-SysPilotProcessByName, New-SysPilotBackup, Get-SysPilotBackupDir, Get-SysPilotBackups, Restore-SysPilotServices,
    Write-SysPilotHeader, Read-SysPilotChoice, Confirm-SysPilot, Show-SysPilotArrowMenu, Show-SysPilotMultiSelectMenu,
    Clear-SysPilotPendingKeys,
    Initialize-SysPilotConsoleInput, Restore-SysPilotConsoleInput, Read-SysPilotMenuEvent, Clear-SysPilotConsoleInputBuffer, Read-SysPilotYesNo,
    Save-SysPilotUrlToFile, Test-SysPilotLaunchablePath,
    Find-SysPilotJsonSection, Get-SysPilotJsonSectionText, Get-SysPilotChromiumExtensionSettings,
    Get-SysPilotJsonChildProperties, ConvertFrom-SysPilotJsonScalar, Get-SysPilotConsoleViewport,
    Read-SysPilotFileRaw, Write-SysPilotFileRaw,
    Remove-SysPilotJsonPropertyText, Remove-SysPilotPrefExtensionEntry,
    Write-SysPilotProgress, Complete-SysPilotProgress, Get-SysPilotShortcutPaths, Set-SysPilotShortcutRunAs,
    Test-SysPilotGamingActive, Get-SysPilotPortableAppsDir, Get-SysPilotLocalSearchDirs,
    Get-SysPilotAutoFixStampPath, Test-SysPilotAutoFixDue, Save-SysPilotAutoFixStamp
