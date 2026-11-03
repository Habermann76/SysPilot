# SysPilot - Common: Admin-Check, Logging, Config, Backup/Restore
#Requires -Version 5.1

$script:SysPilotRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$script:Config = $null

function Test-SysPilotAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
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
    $argList = "-NoProfile -ExecutionPolicy Bypass"
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
    Write-Host -NoNewline "  $Prompt : " -ForegroundColor Yellow
    return (Read-Host).Trim()
}

function Confirm-SysPilot {
    param([string]$Question)
    $a = Read-SysPilotChoice "$Question (j/n)"
    return ($a -match '^(j|ja|y|yes)$')
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

function Show-SysPilotArrowMenu {
    <# Pfeiltasten-Menue: hoch/runter, Enter = waehlen, Esc = zurueck.
       Items: Array von @{ Label; Color; Tag } - gibt Tag des gewaehlten Eintrags zurueck oder $null bei Esc. #>
    param(
        [Parameter(Mandatory)][array]$Items,
        [string]$Title = '',
        [string]$Footer = 'Pfeiltasten hoch/runter, Enter = waehlen, Esc = zurueck'
    )
    if ($Items.Count -eq 0) { return $null }
    $sel = 0
    while ($true) {
        Clear-Host
        if ($Title) {
            Write-Host ""
            Write-Host "  $Title" -ForegroundColor Cyan
            Write-Host ""
        }
        for ($i = 0; $i -lt $Items.Count; $i++) {
            $it = $Items[$i]
            $prefix = if ($i -eq $sel) { ' > ' } else { '   ' }
            $color = if ($i -eq $sel) { 'Black' } else { if ($it.Color) { $it.Color } else { 'White' } }
            $bg = if ($i -eq $sel) { 'Cyan' } else { $null }
            $line = "$prefix$($it.Label)"
            if ($bg) { Write-Host $line -ForegroundColor $color -BackgroundColor $bg }
            else { Write-Host $line -ForegroundColor $color }
        }
        Write-Host ""
        Write-Host "  $Footer" -ForegroundColor DarkGray
        $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        switch ($key.VirtualKeyCode) {
            38 { $sel = ($sel - 1 + $Items.Count) % $Items.Count }
            40 { $sel = ($sel + 1) % $Items.Count }
            27 { return $null }
            13 { return $Items[$sel].Tag }
        }
    }
}

Export-ModuleMember -Function ConvertTo-SysPilotArgString, Test-SysPilotAdmin, Assert-SysPilotAdmin, Restart-SysPilotElevated,
    Write-SysPilotLog, Get-SysPilotConfig, Reset-SysPilotConfig, Set-SysPilotConfigValue, Test-NameMatch,
    Get-SysPilotProcessByName, New-SysPilotBackup, Get-SysPilotBackups, Restore-SysPilotServices,
    Write-SysPilotHeader, Read-SysPilotChoice, Confirm-SysPilot, Show-SysPilotArrowMenu,
    Write-SysPilotProgress, Complete-SysPilotProgress, Get-SysPilotShortcutPaths, Set-SysPilotShortcutRunAs
