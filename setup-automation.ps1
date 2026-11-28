# SysPilot Setup-Automatisierung
# Wird vom Installer (Inno Setup) aufgerufen, kann aber auch manuell laufen:
#   powershell -ExecutionPolicy Bypass -File setup-automation.ps1 -Autopilot -SmartBoost -RunAsAdmin
# Rueckgaengig (z.B. bei Deinstallation):  -Undo
#Requires -Version 5.1
param(
    [switch]$Autopilot,     # Autopilot bei der Anmeldung automatisch starten (geplante Aufgabe)
    [switch]$SmartBoost,    # RAM automatisch freigeben, wenn er knapp wird
    [switch]$RunAsAdmin,    # SysPilot immer als Administrator starten (Config + Verknuepfungen)
    [switch]$Guardian,      # Guardian: ueberwacht SysPilot (Tray) und startet es neu, falls es nicht laeuft
    [switch]$HerbertFullscreen, # Pilot Herbert immer im Vollbildmodus starten
    [switch]$RestoreUserSettings,  # (Update) eigene Einstellungen aus config.user-backup.json uebernehmen
    [switch]$Undo           # alles wieder entfernen
)

$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $script:Root) { $script:Root = $PSScriptRoot }
Get-ChildItem (Join-Path $script:Root 'modules') -Filter '*.psm1' | ForEach-Object {
    try {
        Import-Module $_.FullName -Force -Global -WarningAction SilentlyContinue
        $m = Get-Module $_.BaseName
        if (-not $m -or $m.Path -ne $_.FullName) { throw "Modul nicht geladen" }
    } catch {
        # Headless-Kontext: keine UI, aber Log-Eintrag ist Pflicht
        $msg = "MODUL-IMPORT FEHLER (Setup): $($_.BaseName) - $($_.Exception.Message)"
        try { Write-SysPilotLog $msg } catch {
            try {
                $ld = Join-Path $env:LOCALAPPDATA 'SysPilot\logs'
                if (-not (Test-Path $ld)) { New-Item -ItemType Directory -Path $ld -Force | Out-Null }
                Add-Content (Join-Path $ld ("syspilot-" + (Get-Date -Format 'yyyy-MM-dd') + ".log")) "$(Get-Date -Format 'HH:mm:ss.fff') [ERROR] $msg"
            } catch { }
        }
    }
}

if ($Undo) {
    Remove-SysPilotAutopilotTask
    Remove-SysPilotGuardian
    Set-SysPilotShortcutRunAs -RunAs $false | Out-Null
    Write-SysPilotLog 'Setup-Automatisierung rueckgaengig gemacht (Deinstallation)'
    return
}

if ($SmartBoost) {
    Set-SysPilotConfigValue -Section 'Autopilot' -Key 'AutoFreeRam' -Value $true
    Write-SysPilotLog 'Setup: Smart Boost aktiviert (AutoFreeRam)'
}
if ($Autopilot) {
    Install-SysPilotAutopilotTask
}
if ($RunAsAdmin) {
    Set-SysPilotConfigValue -Section 'Start' -Key 'AlwaysAdmin' -Value $true
    Set-SysPilotShortcutRunAs -RunAs $true | Out-Null
    Write-SysPilotLog 'Setup: Immer als Administrator aktiviert'
}
if ($HerbertFullscreen) {
    Set-SysPilotConfigValue -Section 'Herbert' -Key 'Fullscreen' -Value $true
    Write-SysPilotLog 'Setup: Herbert-Vollbildmodus aktiviert'
}

if ($RestoreUserSettings) {
    # Beim Update liefert der Installer eine frische config.json mit. Eigene Einstellungen (Start, Guardian, Autopilot, ...) bleiben erhalten.
    $backup = Join-Path $script:Root 'config.user-backup.json'
    $cfgPath = Join-Path $script:Root 'config.json'
    if (Test-Path $backup) {
        try {
            $old = Get-Content $backup -Raw -Encoding UTF8 | ConvertFrom-Json
            $new = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($sec in 'Start','UI','Guardian','Update','Autopilot') {
                $oldSec = $old.PSObject.Properties[$sec]
                if (-not $oldSec -or -not $oldSec.Value) { continue }
                if (-not $new.PSObject.Properties[$sec]) {
                    $new | Add-Member -NotePropertyName $sec -NotePropertyValue $oldSec.Value -Force
                    continue
                }
                foreach ($prop in $oldSec.Value.PSObject.Properties) {
                    if ($new.$sec.PSObject.Properties[$prop.Name]) { $new.$sec.($prop.Name) = $prop.Value }
                    else { $new.$sec | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value -Force }
                }
            }
            $new | ConvertTo-Json -Depth 10 | Set-Content $cfgPath -Encoding UTF8
            Reset-SysPilotConfig
            Remove-Item $backup -Force -ErrorAction SilentlyContinue
            Write-SysPilotLog 'Update: eigene Einstellungen uebernommen'
        } catch { Write-SysPilotLog "Update: Einstellungen konnten nicht uebernommen werden: $($_.Exception.Message)" }
    }
    # Dauer-Wache und Autopilot nach dem Update (vom Installer beendet) wieder starten
    $g = (Get-SysPilotConfig).PSObject.Properties['Guardian']
    if ($g -and $g.Value -and $g.Value.Enabled) { Install-SysPilotGuardian | Out-Null }
    Start-ScheduledTask -TaskName 'SysPilot Autopilot' -ErrorAction SilentlyContinue
}

if ($Guardian) {
    $mode = 'TrayOnly'
    $gp = (Get-SysPilotConfig).PSObject.Properties['Guardian']
    if ($gp -and $gp.Value -and $gp.Value.StartMode) { $mode = [string]$gp.Value.StartMode }
    Save-SysPilotGuardianConfig -Enabled $true -StartMode $mode
    Install-SysPilotGuardian | Out-Null
    Write-SysPilotLog "Setup: Guardian aktiviert (Modus: $mode)"
}

# Download-Engine (aria2/yt-dlp/ffmpeg), llama.cpp-Backend und Paketmanager
# sicherstellen - idempotent, Fehler werden nur geloggt.
try {
    Write-SysPilotLog 'Setup: Ensure-SysPilotPrereqs startet (Download-Tools, llama.cpp, Paketmanager)'
    $pr = Ensure-SysPilotPrereqs -Quiet
    Write-SysPilotLog ("Setup: Prereqs fertig - installiert: {0} | uebersprungen: {1} | fehlgeschlagen: {2}" -f
        (@($pr.Installed) -join ', '), (@($pr.Skipped) -join ', '), (@($pr.Failed) -join ', '))
} catch {
    Write-SysPilotLog "Setup: Ensure-SysPilotPrereqs Fehler: $($_.Exception.Message)"
}
