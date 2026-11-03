# SysPilot Setup-Automatisierung
# Wird vom Installer (Inno Setup) aufgerufen, kann aber auch manuell laufen:
#   powershell -ExecutionPolicy Bypass -File setup-automation.ps1 -Autopilot -SmartBoost -RunAsAdmin
# Rueckgaengig (z.B. bei Deinstallation):  -Undo
#Requires -Version 5.1
param(
    [switch]$Autopilot,     # Autopilot bei der Anmeldung automatisch starten (geplante Aufgabe)
    [switch]$SmartBoost,    # RAM automatisch freigeben, wenn er knapp wird
    [switch]$RunAsAdmin,    # SysPilot immer als Administrator starten (Config + Verknuepfungen)
    [switch]$Undo           # alles wieder entfernen
)

$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $script:Root) { $script:Root = $PSScriptRoot }
Get-ChildItem (Join-Path $script:Root 'modules') -Filter '*.psm1' | ForEach-Object {
    Import-Module $_.FullName -Force -Global -WarningAction SilentlyContinue
}

if ($Undo) {
    Remove-SysPilotAutopilotTask
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
