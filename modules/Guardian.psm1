# SysPilot - Guardian: wacht ueber SysPilot und startet es neu, falls es nicht laeuft
#Requires -Version 5.1

# Wurzelordner (jedes Modul hat einen eigenen $script:-Bereich, die Variable aus Common.psm1 ist hier nicht sichtbar)
$script:SysPilotRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)

function Get-SysPilotGuardianConfig {
    <# Liest die Guardian-Einstellungen aus config.json -> Guardian. #>
    $cfg = Get-SysPilotConfig
    $g = $cfg.Guardian
    if (-not $g) {
        $g = [PSCustomObject]@{ Enabled = $false; StartMode = 'OpenGui' }  # OpenGui | TrayOnly
    }
    return $g
}

function Save-SysPilotGuardianConfig {
    param([bool]$Enabled, [string]$StartMode)
    $path = Join-Path $script:SysPilotRoot 'config.json'
    $json = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $g = [PSCustomObject]@{ Enabled = $Enabled; StartMode = $StartMode }
    if ($json.PSObject.Properties['Guardian']) { $json.Guardian = $g }
    else { $json | Add-Member -NotePropertyName Guardian -NotePropertyValue $g -Force }
    $json | ConvertTo-Json -Depth 10 | Set-Content $path -Encoding UTF8
    Reset-SysPilotConfig
}

function Test-SysPilotGuiRunning {
    <# Prueft, ob die SysPilot-GUI laeuft (eigener Prozess, nicht dieser). #>
    $procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'SysPilot-GUI\.ps1' -and $_.ProcessId -ne $PID }
    return [bool]$procs
}

function Install-SysPilotGuardian {
    <# Registriert die geplante Aufgabe "SysPilot Guardian": prueft alle 2 Min, ob die GUI laeuft. #>
    if (-not (Assert-SysPilotAdmin)) { return $false }
    $exe = 'powershell.exe'
    if ($PSVersionTable.PSEdition -eq 'Core') { $exe = 'pwsh.exe' }
    $scriptPath = Join-Path $script:SysPilotRoot 'SysPilot.ps1'
    $action = New-ScheduledTaskAction -Execute $exe -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" -Guardian"
    # Bei Anmeldung starten + alle 2 Minuten wiederholen (dauerhaft)
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $trigger.Repetition = New-ScheduledTaskRepetition -Interval (New-TimeSpan -Minutes 2) -Duration ([TimeSpan]::MaxValue)
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::FromMinutes(1))
    Register-ScheduledTask -TaskName 'SysPilot Guardian' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-SysPilotLog 'Guardian installiert (prueft alle 2 Min, ob SysPilot laeuft)'
    return $true
}

function Remove-SysPilotGuardian {
    if (-not (Assert-SysPilotAdmin)) { return }
    Unregister-ScheduledTask -TaskName 'SysPilot Guardian' -Confirm:$false -ErrorAction SilentlyContinue
    Write-SysPilotLog 'Guardian entfernt'
}

function Invoke-SysPilotGuardian {
    <# Wird von der geplanten Aufgabe aufgerufen: startet die GUI, falls sie nicht laeuft. #>
    $g = Get-SysPilotGuardianConfig
    if (-not $g.Enabled) { return }
    if (Test-SysPilotGuiRunning) { return }

    $gui = Join-Path $script:SysPilotRoot 'SysPilot-GUI.ps1'
    $guiArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$gui)
    if ($g.StartMode -eq 'TrayOnly') { $guiArgs += '-StartHidden' }
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList (ConvertTo-SysPilotArgString $guiArgs)
    Write-SysPilotLog "Guardian: SysPilot neu gestartet (Modus: $($g.StartMode))"
}

function Show-SysPilotGuardianMenu {
    <# Guardian einstellen: an/aus + Start-Modus (GUI offen / nur Tray). #>
    while ($true) {
        $g = Get-SysPilotGuardianConfig
        $task = Get-ScheduledTask -TaskName 'SysPilot Guardian' -ErrorAction SilentlyContinue
        $statusTxt = if ($task -and $g.Enabled) { 'AN (wacht ueber SysPilot)' } else { 'AUS' }
        $modeTxt = if ($g.StartMode -eq 'TrayOnly') { 'Nur im Tray (versteckt)' } else { 'GUI offen (Standard)' }

        $items = @(
            @{ Label = "Status: $statusTxt  (Enter = an/aus)"; Color = $(if ($task -and $g.Enabled) { 'Green' } else { 'Yellow' }); Tag = 'toggle' },
            @{ Label = "Start-Modus: $modeTxt"; Color = 'White'; Tag = 'mode' },
            @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = $null }
        )
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'SysPilot Guardian' -Footer 'Pfeiltasten, Enter = aendern, Esc = zurueck'
        if ($null -eq $sel) { return }

        switch ($sel) {
            'toggle' {
                if ($task -and $g.Enabled) {
                    Save-SysPilotGuardianConfig -Enabled $false -StartMode $g.StartMode
                    Remove-SysPilotGuardian
                    Write-Host '  [OK] Guardian deaktiviert.' -ForegroundColor Yellow
                } else {
                    Save-SysPilotGuardianConfig -Enabled $true -StartMode $g.StartMode
                    if (Install-SysPilotGuardian) { Write-Host '  [OK] Guardian aktiviert - startet SysPilot neu, falls es nicht laeuft.' -ForegroundColor Green }
                }
                Read-SysPilotChoice 'Weiter' | Out-Null
            }
            'mode' {
                $mItems = @(
                    @{ Label = 'GUI offen (Standard) - Fenster wird gezeigt'; Color = 'White'; Tag = 'OpenGui' },
                    @{ Label = 'Nur im Tray (versteckt) - startet im Hintergrund'; Color = 'White'; Tag = 'TrayOnly' }
                )
                $m = Show-SysPilotArrowMenu -Items $mItems -Title 'Wie soll SysPilot starten?'
                if ($m) {
                    Save-SysPilotGuardianConfig -Enabled $g.Enabled -StartMode $m
                    Write-Host ('  [OK] Start-Modus: ' + $(if ($m -eq 'TrayOnly') { 'Nur im Tray' } else { 'GUI offen' })) -ForegroundColor Green
                    Read-SysPilotChoice 'Weiter' | Out-Null
                }
            }
        }
    }
}

Export-ModuleMember -Function Get-SysPilotGuardianConfig, Save-SysPilotGuardianConfig, Test-SysPilotGuiRunning,
    Install-SysPilotGuardian, Remove-SysPilotGuardian, Invoke-SysPilotGuardian, Show-SysPilotGuardianMenu
