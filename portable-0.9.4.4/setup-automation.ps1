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
    [switch]$RestoreUserSettings,  # (Update) eigene Einstellungen aus config.user-backup.json uebernehmen
    [switch]$Undo           # alles wieder entfernen
)

$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $script:Root) { $script:Root = $PSScriptRoot }
Get-ChildItem (Join-Path $script:Root 'modules') -Filter '*.psm1' | ForEach-Object {
    Import-Module $_.FullName -Force -Global -WarningAction SilentlyContinue
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
