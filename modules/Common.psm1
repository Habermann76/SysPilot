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
    $current = $PSCommandPath
    if (-not $current) { $current = Join-Path $script:SysPilotRoot "SysPilot.ps1" }
    Start-Process $exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$current`""
    if (-not $NoExit) { exit }
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

Export-ModuleMember -Function Test-SysPilotAdmin, Assert-SysPilotAdmin, Restart-SysPilotElevated,
    Write-SysPilotLog, Get-SysPilotConfig, Reset-SysPilotConfig, Test-NameMatch,
    Get-SysPilotProcessByName, New-SysPilotBackup, Get-SysPilotBackups, Restore-SysPilotServices,
    Write-SysPilotHeader, Read-SysPilotChoice, Confirm-SysPilot, Show-SysPilotArrowMenu,
    Write-SysPilotProgress, Complete-SysPilotProgress
