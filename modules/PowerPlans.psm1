# SysPilot - PowerPlans: Energieplaene + Autopilot (Kuehl/Leistung)
#Requires -Version 5.1

# Locale-unabhaengige GUIDs (funktionieren auch auf deutschem Windows)
$script:SUB_PROCESSOR    = '54533251-82be-4824-96c1-47b60b740d00'
$script:PROCTHROTTLEMIN  = '893dee8e-2bef-41e0-89c6-b55d0929964c'
$script:PROCTHROTTLEMAX  = 'bc5038f7-23e0-4960-96da-33abaf5935ec'
$script:PERFBOOSTMODE    = 'be337238-0d82-4146-a960-4f3749d470c7'
$script:SYSCOOLPOL       = '94d3a615-a899-4ac5-ae2b-e4d8f634367f'
$script:SCHEME_BALANCED  = '381b4222-f694-41f0-9685-ff5bb260df2e'
$script:SCHEME_HIGHPERF  = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'

$script:COOL_NAME  = 'SysPilot Kuehl & Leise'
$script:PERF_NAME  = 'SysPilot Leistung'

function Get-SysPilotPlanList {
    $out = & powercfg /list
    $plans = @()
    foreach ($line in $out) {
        if ($line -match '([0-9a-fA-F]{8}-[0-9a-fA-F-]{27,36})\s+\((.+?)\)\s*(\*)?$') {
            $plans += [PSCustomObject]@{
                Guid   = $matches[1]
                Name   = $matches[2]
                Active = ($matches[3] -eq '*')
            }
        }
    }
    return $plans
}

function Get-SysPilotPlanGuid {
    param([string]$Name)
    $p = Get-SysPilotPlanList | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if ($p) { return $p.Guid }
    return $null
}

function Set-PowerSetting {
    param([string]$Scheme, [string]$Setting, [int]$AC, [int]$DC)
    & powercfg /setacvalueindex $Scheme $script:SUB_PROCESSOR $Setting $AC 2>$null | Out-Null
    & powercfg /setdcvalueindex $Scheme $script:SUB_PROCESSOR $Setting $DC 2>$null | Out-Null
}

function Install-SysPilotPlans {
    <#
    Erstellt zwei Plaene:
      Kuehl & Leise : Boost AUS (Ryzen bleibt auf Basistakt), Max 95%/85%, passive Kuehlung
      Leistung      : Boost AGGRESSIV, Max 100%, aktive Kuehlung
    #>
    if (-not (Assert-SysPilotAdmin)) { return }

    $coolGuid = Get-SysPilotPlanGuid -Name $script:COOL_NAME
    if (-not $coolGuid) {
        $out = & powercfg /duplicatescheme $script:SCHEME_BALANCED
        if ($out -match '([0-9a-fA-F-]{36})') { $coolGuid = $matches[1] }
        & powercfg /changename $coolGuid $script:COOL_NAME "Senkt Temperatur und Luefterlaerm: CPU-Boost aus, sanfte Taktung" | Out-Null
    }
    # Kuehl-Plan: Boost deaktiviert (0), Max 95% AC / 85% DC, Min 5%, passive Kuehlung (0)
    Set-PowerSetting -Scheme $coolGuid -Setting $script:PERFBOOSTMODE   -AC 0  -DC 0
    Set-PowerSetting -Scheme $coolGuid -Setting $script:PROCTHROTTLEMAX -AC 95 -DC 85
    Set-PowerSetting -Scheme $coolGuid -Setting $script:PROCTHROTTLEMIN -AC 5  -DC 5
    Set-PowerSetting -Scheme $coolGuid -Setting $script:SYSCOOLPOL      -AC 0  -DC 0

    $perfGuid = Get-SysPilotPlanGuid -Name $script:PERF_NAME
    if (-not $perfGuid) {
        $out = & powercfg /duplicatescheme $script:SCHEME_HIGHPERF
        if ($out -match '([0-9a-fA-F-]{36})') { $perfGuid = $matches[1] }
        & powercfg /changename $perfGuid $script:PERF_NAME "Volle Leistung fuer Gaming, Kompilieren und Entwicklung" | Out-Null
    }
    # Leistungs-Plan: Boost aggressiv (2), Max 100%, Min 10%, aktive Kuehlung (1)
    Set-PowerSetting -Scheme $perfGuid -Setting $script:PERFBOOSTMODE   -AC 2   -DC 1
    Set-PowerSetting -Scheme $perfGuid -Setting $script:PROCTHROTTLEMAX -AC 100 -DC 100
    Set-PowerSetting -Scheme $perfGuid -Setting $script:PROCTHROTTLEMIN -AC 10  -DC 5
    Set-PowerSetting -Scheme $perfGuid -Setting $script:SYSCOOLPOL      -AC 1   -DC 1

    Write-Host ""
    Write-Host "  [OK] Energieplaene eingerichtet:" -ForegroundColor Green
    Write-Host "       - $script:COOL_NAME  ($coolGuid)" -ForegroundColor Green
    Write-Host "       - $script:PERF_NAME  ($perfGuid)" -ForegroundColor Green
    Write-SysPilotLog "Energieplaene installiert: Kuehl=$coolGuid Leistung=$perfGuid"
}

function Set-SysPilotPlan {
    param([ValidateSet('Cool','Performance')][string]$Mode)
    $name = if ($Mode -eq 'Cool') { $script:COOL_NAME } else { $script:PERF_NAME }
    $guid = Get-SysPilotPlanGuid -Name $name
    if (-not $guid) {
        Write-Host "  [!] Plan '$name' existiert nicht. Bitte zuerst Menuepunkt 2 ausfuehren." -ForegroundColor Yellow
        return $false
    }
    & powercfg /setactive $guid 2>$null | Out-Null
    Write-SysPilotLog "Energieplan gewechselt: $Mode ($name)"
    return $true
}

function Get-SysPilotActiveMode {
    $plans = Get-SysPilotPlanList | Where-Object { $_.Active }
    if (-not $plans) { return 'Unknown' }
    if ($plans.Name -eq $script:COOL_NAME) { return 'Cool' }
    if ($plans.Name -eq $script:PERF_NAME) { return 'Performance' }
    return 'Other'
}

function Get-SysPilotActivePlanName {
    <# Name des aktiven Plans (fuer die Anzeige, z.B. 'Ausbalanciert'). #>
    $p = Get-SysPilotPlanList | Where-Object { $_.Active } | Select-Object -First 1
    if ($p) { return $p.Name }
    return $null
}

function Get-SysPilotCpuLoad {
    (Get-CimInstance Win32_Processor).LoadPercentage
}

function Test-SysPilotOnBattery {
    $b = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
    if (-not $b) { return $false }   # kein Akku = Desktop = Netzbetrieb
    return ($b.BatteryStatus -eq 1)  # 1 = entlaedt (Akku)
}

function Start-SysPilotAutopilot {
    <#
    Der Autopilot - cleverer als Camomile:
      - Erkennt Spiele/wichtige Prozesse -> sofort Leistung
      - Lastbasierte Umschaltung mit Hysterese (kein Flattern)
      - Akku-Modus bevorzugt Kuehl
      - Wendet Prozess-Prioritaeten bei jedem Zyklus an
      - Tasten: C=Kuehl P=Leistung A=Auto Q=Quit
    #>
    $cfg = (Get-SysPilotConfig).Autopilot
    $coolGuid = Get-SysPilotPlanGuid -Name $script:COOL_NAME
    $perfGuid = Get-SysPilotPlanGuid -Name $script:PERF_NAME
    if (-not $coolGuid -or -not $perfGuid) {
        Write-Host "  [!] SysPilot-Plaene fehlen. Bitte zuerst Menuepunkt 2 ausfuehren." -ForegroundColor Yellow
        return
    }

    $mode = 'Auto'
    $current = Get-SysPilotActiveMode
    if ($current -ne 'Cool' -and $current -ne 'Performance') {
        Set-SysPilotPlan -Mode Cool | Out-Null
        $current = 'Cool'
    }
    $highCount = 0; $lowCount = 0; $cycle = 0
    $hasPriorities = [bool](Get-Command Set-SysPilotPriorities -ErrorAction SilentlyContinue)
    $hasMemory = [bool](Get-Command Get-SysPilotMemoryInfo -ErrorAction SilentlyContinue)
    $hasStats = [bool](Get-Command Write-SysPilotStatSample -ErrorAction SilentlyContinue)

    Write-Host ""
    Write-Host "  AUTOPILOT laeuft.  Tasten: [C] Kuehl  [P] Leistung  [A] Auto  [Q] Ende" -ForegroundColor Cyan
    Write-Host "  Schwelle hoch: $($cfg.HighLoadThreshold)% x$($cfg.HighSamplesNeeded) | runter: $($cfg.LowLoadThreshold)% x$($cfg.LowSamplesNeeded)" -ForegroundColor DarkGray
    Write-Host ""

    while ($true) {
        # Tasteneingabe
        while ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true).Key
            switch ($key) {
                'C' { $mode = 'ManualCool';  Set-SysPilotPlan -Mode Cool | Out-Null;  $current = 'Cool';        Write-Host "  -> Manuell: KUEHL" -ForegroundColor Blue }
                'P' { $mode = 'ManualPerf';  Set-SysPilotPlan -Mode Performance | Out-Null; $current = 'Performance'; Write-Host "  -> Manuell: LEISTUNG" -ForegroundColor Magenta }
                'A' { $mode = 'Auto'; $highCount = 0; $lowCount = 0; Write-Host "  -> AUTO-Modus" -ForegroundColor Cyan }
                'Q' { Write-Host "  Autopilot beendet." -ForegroundColor Yellow; return }
            }
        }

        $load = Get-SysPilotCpuLoad
        $onBattery = Test-SysPilotOnBattery
        $reason = ""

        # Temperatur lesen (falls Modul geladen)
        $temp = $null
        if (Get-Command Get-SysPilotCpuTemperature -ErrorAction SilentlyContinue) {
            $temp = Get-SysPilotCpuTemperature
        }

        # App-Kategorie erkennen (Gaming > Entwicklung > Browser)
        $app = Get-SysPilotActiveAppCategory

        if ($mode -eq 'Auto') {
            # 0. KRITISCHE HITZE -> Notaus (Ruhezustand), hat absoluten Vorrang
            if ($temp -and -not $temp.Geschaetzt -and $temp.Celsius -ge [int]$cfg.TempCriticalC) {
                Write-Host "  !! KRITISCHE HITZE: $($temp.Celsius)C - Hitzeschutz wird ausgeloest !!" -ForegroundColor Red
                Invoke-SysPilotThermalShutdown -Celsius $temp.Celsius
            }
            # 1. HITZE -> abkuehlen + Ballast drosseln
            elseif ($temp -and -not $temp.Geschaetzt -and $temp.Celsius -ge [int]$cfg.TempHotC) {
                if ($current -ne 'Cool') {
                    Set-SysPilotPlan -Mode Cool | Out-Null; $current = 'Cool'
                    $reason = "HITZE: $($temp.Celsius)C >= $($cfg.TempHotC)C -> abkuehlen!"
                }
                # Bei Hitze: Ballast auf IDLE drosseln (unwichtige Prozesse)
                if ($cfg.ThrottleJunkOnHot) {
                    foreach ($j in (Get-SysPilotConfig).JunkProcesses) {
                        $base = $j -replace '\.exe$',''
                        Get-Process -Name $base -ErrorAction SilentlyContinue | ForEach-Object {
                            try { if ($_.PriorityClass -ne 'Idle') { $_.PriorityClass = 'Idle' } } catch { }
                        }
                    }
                }
                $highCount = 0; $lowCount = 0
            }
            # 2. App-basierte Plan-Wahl
            elseif ($app) {
                $want = $app.Plan
                if ($current -ne $want) {
                    Set-SysPilotPlan -Mode $want | Out-Null; $current = $want
                    $reason = "$($app.Kategorie) erkannt ($($app.Prozess)) -> $want"
                }
                $highCount = 0; $lowCount = 0
            }
            # 3. Last-basiert (Fallback)
            elseif ($load -ge $cfg.HighLoadThreshold) {
                $highCount++; $lowCount = 0
                if ($highCount -ge $cfg.HighSamplesNeeded -and $current -ne 'Performance') {
                    Set-SysPilotPlan -Mode Performance | Out-Null; $current = 'Performance'
                    $reason = "Last $load% >= $($cfg.HighLoadThreshold)% (anhaltend)"
                    $highCount = 0
                }
            }
            elseif ($load -le $cfg.LowLoadThreshold) {
                $lowCount++; $highCount = 0
                $needed = $cfg.LowSamplesNeeded
                if ($onBattery -and $cfg.PreferCoolOnBattery) { $needed = [Math]::Max(2, [int]($needed / 2)) }
                if ($lowCount -ge $needed -and $current -ne 'Cool') {
                    Set-SysPilotPlan -Mode Cool | Out-Null; $current = 'Cool'
                    $reason = "Last $load% <= $($cfg.LowLoadThreshold)% (ruhig)"
                    if ($onBattery) { $reason += " + Akku" }
                    $lowCount = 0
                }
            }
            else { $highCount = 0; $lowCount = 0 }
        }

        # Prioritaeten anwenden (still, nur bei Aenderungen loggen)
        if ($hasPriorities) { Set-SysPilotPriorities -Quiet }

        # Statistik sammeln (jeder 12. Zyklus ~ 1 Minute)
        $cycle++
        if ($hasStats -and ($cycle % 12) -eq 0) { Write-SysPilotStatSample }

        # Auto-RAM: bei Speicherdruck periodisch freigeben
        if ($hasMemory -and $cfg.AutoFreeRam -and ($cycle % [Math]::Max(1, [int]$cfg.AutoFreeRamEveryCycles)) -eq 0) {
            $mem = Get-SysPilotMemoryInfo
            if ($mem.UsedPct -ge [int]$cfg.AutoFreeRamThresholdPct) {
                $ws = Clear-SysPilotWorkingSets
                $standby = $false
                if (Test-SysPilotAdmin) { $standby = [bool](Clear-SysPilotStandbyList) }
                $stbTxt = if ($standby) { ' + Standby-Cache' } else { '' }
                Write-Host ("  {0}  AUTO-RAM: {1}% belegt -> {2} MB aus {3} Prozessen frei{4}" -f (Get-Date -Format "HH:mm:ss"), $mem.UsedPct, $ws.FreedMB, $ws.Trimmed, $stbTxt) -ForegroundColor DarkCyan
                Write-SysPilotLog "Auto-RAM: $($mem.UsedPct)% belegt, $($ws.FreedMB) MB frei, Standby: $standby"
            }
        }

        $bat = if ($onBattery) { "Akku " } else { "Netz " }
        $tempTxt = if ($temp) { " {0}C{1}" -f $temp.Celsius, $(if ($temp.Geschaetzt) { '~' } else { '' }) } else { '' }
        $appTxt = if ($app) { " $($app.Kategorie):$($app.Prozess)" } else { '' }
        $line = "  {0}  Last {1,3}%{2}  {3} Plan:{4,-11} Modus:{5}{6}" -f (Get-Date -Format "HH:mm:ss"), $load, $tempTxt, $bat, $current, $mode, $appTxt
        if ($reason) {
            Write-Host $line -ForegroundColor Green
            Write-Host ("         => " + $reason) -ForegroundColor DarkGreen
            if ($cfg.LogSwitches) { Write-SysPilotLog "Autopilot: $reason (Last $load%)" }
        } else {
            Write-Host $line -ForegroundColor DarkGray
        }

        Start-Sleep -Seconds $cfg.IntervalSeconds
    }
}

function Get-SysPilotGameRunning {
    $cfg = Get-SysPilotConfig
    if ($cfg.GameProcesses) {
        foreach ($g in $cfg.GameProcesses) {
            $base = $g -replace '\.exe$',''
            if (Get-Process -Name $base -ErrorAction SilentlyContinue) { return $base }
        }
    }
    if (Get-Command Test-SysPilotGamingActive -ErrorAction SilentlyContinue) {
        if (Test-SysPilotGamingActive) { return 'FullscreenGame' }
    }
    return $null
}

function Get-SysPilotActiveAppCategory {
    <# Erkennt die wichtigste laufende App-Kategorie: Gaming > Entwicklung > Browser #>
    $cfg = Get-SysPilotConfig
    $procs = Get-Process -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ProcessName -Unique

    foreach ($cat in @('Gaming','Entwicklung','Browser')) {
        $rule = $cfg.Autopilot.AppPlans.$cat
        if (-not $rule) { continue }
        $list = $cfg.($rule.Match)
        foreach ($p in $procs) {
            foreach ($pat in $list) {
                $base = $pat -replace '\.exe$',''
                if ($p -eq $base -or $p -like "$base*") {
                    return @{ Kategorie = $cat; Prozess = $p; Plan = $rule.Plan; Priority = $rule.Priority }
                }
            }
        }
    }
    return $null
}

function Install-SysPilotAutopilotTask {
    if (-not (Assert-SysPilotAdmin)) { return }
    $exe = "powershell.exe"
    if ($PSVersionTable.PSEdition -eq 'Core') { $exe = "pwsh.exe" }
    $scriptPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) "SysPilot.ps1"
    $action = New-ScheduledTaskAction -Execute $exe -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" -Autopilot"
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName "SysPilot Autopilot" -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Host "  [OK] Autopilot startet jetzt automatisch bei der Anmeldung." -ForegroundColor Green
    Write-SysPilotLog "Autopilot-Task installiert"
}

function Remove-SysPilotAutopilotTask {
    if (-not (Assert-SysPilotAdmin)) { return }
    Unregister-ScheduledTask -TaskName "SysPilot Autopilot" -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "  [OK] Autopilot-Autostart entfernt." -ForegroundColor Green
    Write-SysPilotLog "Autopilot-Task entfernt"
}

Export-ModuleMember -Function Install-SysPilotPlans, Set-SysPilotPlan, Get-SysPilotActiveMode,
    Get-SysPilotActivePlanName, Get-SysPilotPlanList, Get-SysPilotPlanGuid, Start-SysPilotAutopilot, Get-SysPilotGameRunning, Get-SysPilotActiveAppCategory,
    Install-SysPilotAutopilotTask, Remove-SysPilotAutopilotTask, Get-SysPilotCpuLoad, Test-SysPilotOnBattery
