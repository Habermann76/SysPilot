# SysPilot - Dein intelligenter PC-Autopilot
# Kuehlt, beschleunigt und aufraeumen - besser als Camomile, kostenlos, offen.
#Requires -Version 5.1
param(
    [switch]$Autopilot
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path

# Module laden
Get-ChildItem (Join-Path $script:Root 'modules') -Filter '*.psm1' | ForEach-Object {
    Import-Module $_.FullName -Force -Global
}

# Direkt in den Autopilot (fuer geplante Aufgabe)
if ($Autopilot) {
    Start-SysPilotAutopilot
    return
}

# Admin nur als Menue-Option (16), keine Start-Frage.
# Optional wieder aktivierbar: config.json -> Start.AskForAdmin = true
$startCfg = (Get-SysPilotConfig).Start
if (-not (Test-SysPilotAdmin) -and $startCfg -and $startCfg.AskForAdmin) {
    Restart-SysPilotElevated
}

function Show-SysPilotReport {
    Write-SysPilotHeader "System-Analyse"
    $cfg = Get-SysPilotConfig

    # Basis
    $os = Get-CimInstance Win32_OperatingSystem
    $cpu = Get-CimInstance Win32_Processor
    $totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    $freeGB = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
    Write-Host ("  CPU:      {0} ({1} Kerne/{2} Threads)" -f $cpu.Name.Trim(), $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors)
    Write-Host ("  RAM:      {0} GB gesamt, {1} GB frei ({2}% belegt)" -f $totalGB, $freeGB, [math]::Round(100 * ($totalGB - $freeGB) / $totalGB))
    Write-Host ("  CPU-Last: {0}%" -f $cpu.LoadPercentage)
    $disk = Get-PSDrive C
    Write-Host ("  Platte C: {0} GB frei von {1} GB" -f [math]::Round($disk.Free / 1GB, 1), [math]::Round(($disk.Used + $disk.Free) / 1GB, 1))

    # Aktiver Energieplan
    $mode = Get-SysPilotActiveMode
    $plans = Get-SysPilotPlanList
    $active = ($plans | Where-Object { $_.Active }).Name
    $modeTxt = switch ($mode) { 'Cool' { 'SysPilot KUEHL' } 'Performance' { 'SysPilot LEISTUNG' } default { "fremd ($active)" } }
    Write-Host ("  Energie:  {0}" -f $modeTxt)

    # Top RAM-Verbraucher (nach Programm-Familie gruppiert)
    Write-Host ""
    Write-Host "  Top RAM-Verbraucher (gruppiert):" -ForegroundColor Cyan
    $groups = Get-Process | Group-Object ProcessName | ForEach-Object {
        [PSCustomObject]@{
            Name  = $_.Name
            Anzahl = $_.Count
            RAM_MB = [math]::Round(($_.Group | Measure-Object WorkingSet64 -Sum).Sum / 1MB)
        }
    } | Sort-Object RAM_MB -Descending | Select-Object -First 12
    $groups | Format-Table -AutoSize | Out-String | ForEach-Object { $_.Trim() } | Write-Host

    # Warnungen
    Write-Host "  Warnungen:" -ForegroundColor Cyan
    $warnings = 0

    # Bandbreiten-Sharing
    $sharing = Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match 'honeygain|earnapp|bright'
    }
    if ($sharing) {
        $warnings++
        Write-Host "  [!] BANDBREITEN-SHARING laeuft: $($sharing.Name -join ', ')" -ForegroundColor Red
        Write-Host "      Diese Apps verkaufen deine Internet-IP als Proxy. Deinstallation empfohlen (Menue 6)." -ForegroundColor Red
    }

    # Optimizer-Duplikate
    $installed = Get-SysPilotInstalled
    $optimizers = $installed | Where-Object { $_.Hinweis -match 'Optimizer-Duplikate' }
    if ($optimizers.Count -gt 1) {
        $warnings++
        Write-Host "  [!] $($optimizers.Count) PC-Optimizer gleichzeitig installiert (bremsen sich gegenseitig):" -ForegroundColor Yellow
        $optimizers | ForEach-Object { Write-Host "      - $($_.DisplayName)" -ForegroundColor Yellow }
    }

    # Autostart-Last
    $startup = Get-SysPilotStartupItems
    $activeStartup = ($startup | Where-Object { $_.Aktiv }).Count
    if ($activeStartup -gt 15) {
        $warnings++
        Write-Host "  [!] $activeStartup aktive Autostart-Eintraege (viel!). Manager: Menue 5." -ForegroundColor Yellow
    } else {
        Write-Host "  [OK] $activeStartup aktive Autostart-Eintraege." -ForegroundColor Green
    }

    # Dienste
    $svcPlan = Get-SysPilotServicePlan
    $pending = ($svcPlan | Where-Object { $_.Aenderung }).Count
    if ($pending -gt 0) {
        Write-Host "  [i] $pending Dienste koennten optimiert werden (Menue 7)." -ForegroundColor Cyan
    } else {
        Write-Host "  [OK] Dienste sind optimiert." -ForegroundColor Green
    }

    if ($warnings -eq 0) { Write-Host "  [OK] Keine kritischen Warnungen." -ForegroundColor Green }
}

function Edit-SysPilotConfig {
    while ($true) {
        $cfg = Get-SysPilotConfig
        $items = @(
            @{ Label = "Wichtige Programme anzeigen/ergaenzen  ($($cfg.ImportantProcesses.Count) Eintraege)"; Color = 'White'; Tag = 'ImportantProcesses' },
            @{ Label = "Spiele anzeigen/ergaenzen              ($($cfg.GameProcesses.Count) Eintraege)"; Color = 'White'; Tag = 'GameProcesses' },
            @{ Label = "Ballast-Prozesse anzeigen/ergaenzen    ($($cfg.JunkProcesses.Count) Eintraege)"; Color = 'White'; Tag = 'JunkProcesses' },
            @{ Label = "config.json im Editor oeffnen"; Color = 'White'; Tag = 'edit' },
            @{ Label = "Zurueck"; Color = 'DarkGray'; Tag = $null }
        )
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'Konfiguration'
        if ($null -eq $sel) { return }
        $path = Join-Path $script:Root 'config.json'
        if ($sel -eq 'edit') {
            Start-Process notepad.exe $path
            Write-Host "  Nach dem Speichern Menue erneut oeffnen (Config wird neu geladen)." -ForegroundColor DarkGray
            Reset-SysPilotConfig
            Read-SysPilotChoice "Weiter" | Out-Null
            continue
        }
        $field = $sel
        Write-Host "  Aktuell: $($cfg.$field -join ', ')" -ForegroundColor DarkGray
        $new = Read-SysPilotChoice "Neuer Prozessname (ohne .exe, leer = abbrechen)"
        if ($new) {
            $json = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
            $json.$field = @($json.$field) + $new
            $json | ConvertTo-Json -Depth 10 | Set-Content $path -Encoding UTF8
            Reset-SysPilotConfig
            Write-Host "  [OK] '$new' hinzugefuegt." -ForegroundColor Green
            Read-SysPilotChoice "Weiter" | Out-Null
        }
    }
}

function Show-SysPilotSettingsMenu {
    while ($true) {
        $lang = Get-SysPilotLang
        $unit = Get-SysPilotTempUnit
        $langTxt = if ($lang -eq 'de') { 'Deutsch' } else { 'English' }
        $unitTxt = if ($unit -eq 'C') { 'Celsius (°C)' } else { 'Fahrenheit (°F)' }

        $items = @(
            @{ Label = "Sprache / Language: $langTxt"; Color = 'White'; Tag = 'lang' },
            @{ Label = "Temperatureinheit: $unitTxt"; Color = 'White'; Tag = 'unit' },
            @{ Label = "Konfiguration (Programme, Spiele, Ballast)"; Color = 'White'; Tag = 'config' },
            @{ Label = "Zurueck"; Color = 'DarkGray'; Tag = $null }
        )
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'Einstellungen'
        if ($null -eq $sel) { return }
        switch ($sel) {
            'lang' {
                $new = if ($lang -eq 'de') { 'en' } else { 'de' }
                Set-SysPilotLanguage -Lang $new
                $newTxt = if ($new -eq 'de') { 'Deutsch' } else { 'English' }
                Write-Host "  [OK] Sprache: $newTxt" -ForegroundColor Green
                Read-SysPilotChoice "Weiter" | Out-Null
            }
            'unit' {
                $new = if ($unit -eq 'C') { 'F' } else { 'C' }
                Set-SysPilotTempUnit -Unit $new
                $newTxt = if ($new -eq 'C') { 'Celsius' } else { 'Fahrenheit' }
                Write-Host "  [OK] Temperatureinheit: $newTxt" -ForegroundColor Green
                Read-SysPilotChoice "Weiter" | Out-Null
            }
            'config' { Edit-SysPilotConfig }
        }
    }
}

function Show-SysPilotMenu {
    $isAdmin = Test-SysPilotAdmin
    $adminTag = if ($isAdmin) { "ADMIN" } else { "eingeschraenkt" }

    $items = @(
        @{ Key = '1';  Label = 'System-Analyse (Was bremst meinen PC?)'; Color = 'White' },
        @{ Key = '2';  Label = 'Energieplaene einrichten (Kuehl & Leise / Leistung)'; Color = 'White' },
        @{ Key = '3';  Label = 'AUTOPILOT starten (Live-Umschaltung + Prioritaeten)'; Color = 'Green' },
        @{ Key = '4';  Label = 'Autopilot bei Anmeldung automatisch starten/entfernen'; Color = 'White' },
        @{ Key = '5';  Label = 'Autostart-Manager'; Color = 'White' },
        @{ Key = '6';  Label = 'Programme deinstallieren (Bloatware-Finder)'; Color = 'White' },
        @{ Key = '7';  Label = 'OPTIMIZER AUSMISTEN (auswaehlen, welche 1-2 bleiben)'; Color = 'Magenta' },
        @{ Key = '8';  Label = 'AUTO-OPTIMIERUNG (Dienste + Features + Tweaks, mit Backup)'; Color = 'Green' },
        @{ Key = '9';  Label = 'Dienste optimieren'; Color = 'White' },
        @{ Key = '10'; Label = 'Windows-Funktionen & Gaming-Tweaks'; Color = 'White' },
        @{ Key = '11'; Label = 'Datentraeger bereinigen'; Color = 'White' },
        @{ Key = '12'; Label = 'RAM FREIGEBEN (Working Sets + Standby-Cache)'; Color = 'Green' },
        @{ Key = '13'; Label = 'Prozess-Prioritaeten einmalig anwenden'; Color = 'White' },
        @{ Key = '14'; Label = 'Einstellungen (Sprache, Einheiten, Konfiguration)'; Color = 'White' },
        @{ Key = '15'; Label = 'Backup erstellen / Dienste wiederherstellen'; Color = 'White' },
        @{ Key = '16'; Label = 'Als Administrator neu starten'; Color = 'White' },
        @{ Key = '17'; Label = 'RESSOURCEN-FRESSER & Massnahmen'; Color = 'Yellow' },
        @{ Key = '18'; Label = 'Statistiken (Verlauf)'; Color = 'White' },
        @{ Key = '19'; Label = 'SKRIPTE (Gaming/Arbeit/Kuehl/Nacht - anpassbar)'; Color = 'Green' },
        @{ Key = '20'; Label = 'GRAFISCHE OBERFLAECHE (Live-Dashboard)'; Color = 'Cyan' },
        @{ Key = '21'; Label = 'BROWSER-ERWEITERUNGEN (Duplikate finden)'; Color = 'Yellow' },
        @{ Key = '22'; Label = 'NETZWERK / INTERNET reparieren'; Color = 'Cyan' },
        @{ Key = '23'; Label = 'NETZWERKADAPTER identifizieren (was ist vgate0?)'; Color = 'Cyan' },
        @{ Key = '0';  Label = 'Beenden'; Color = 'DarkGray' }
    )

    $sel = 0
    while ($true) {
        Clear-Host
        Write-Host ""
        Write-Host "   ____            ____  _ _       _   " -ForegroundColor Cyan
        Write-Host "  / ___| _   _ ___|  _ \(_) | ___ | |_ " -ForegroundColor Cyan
        Write-Host "  \___ \| | | / __| |_) | | |/ _ \| __|" -ForegroundColor Cyan
        Write-Host "   ___) | |_| \__ \  __/| | | (_) | |_ " -ForegroundColor Cyan
        Write-Host "  |____/ \__, |___/_|   |_|_|\___/ \__|" -ForegroundColor Cyan
        Write-Host "         |___/                          " -ForegroundColor Cyan
        Write-Host "  Intelligenter PC-Autopilot  [$adminTag]" -ForegroundColor DarkCyan
        Write-Host ""
        Write-Host "  Pfeiltasten hoch/runter, Enter = ausfuehren, Esc = beenden" -ForegroundColor DarkGray
        Write-Host ""

        for ($i = 0; $i -lt $items.Count; $i++) {
            $it = $items[$i]
            $prefix = if ($i -eq $sel) { ' > ' } else { '   ' }
            $color = if ($i -eq $sel) { 'Black' } else { $it.Color }
            $bg = if ($i -eq $sel) { 'Cyan' } else { $null }
            $line = "{0}[{1,-2}] {2}" -f $prefix, $it.Key, $it.Label
            if ($bg) { Write-Host $line -ForegroundColor $color -BackgroundColor $bg }
            else { Write-Host $line -ForegroundColor $color }
        }

        $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        switch ($key.VirtualKeyCode) {
            38 { $sel = ($sel - 1 + $items.Count) % $items.Count }   # hoch
            40 { $sel = ($sel + 1) % $items.Count }                  # runter
            27 { return }                                            # Esc
            13 {                                                     # Enter
                $c = $items[$sel].Key
                switch ($c) {
                    '1'  { Show-SysPilotReport; Read-SysPilotChoice "Weiter mit Enter" | Out-Null }
                    '2'  { Install-SysPilotPlans; Read-SysPilotChoice "Weiter mit Enter" | Out-Null }
                    '3'  { Start-SysPilotAutopilot }
                    '4'  {
                        $t = Get-ScheduledTask -TaskName 'SysPilot Autopilot' -ErrorAction SilentlyContinue
                        if ($t) { Remove-SysPilotAutopilotTask } else { Install-SysPilotAutopilotTask }
                        Read-SysPilotChoice "Weiter mit Enter" | Out-Null
                    }
                    '5'  { Show-SysPilotStartupManager }
                    '6'  { Show-SysPilotBloatManager }
                    '7'  { Show-SysPilotOptimizerManager; Read-SysPilotChoice "Weiter mit Enter" | Out-Null }
                    '8'  { Invoke-SysPilotAutoOptimize; Read-SysPilotChoice "Weiter mit Enter" | Out-Null }
                    '9'  { Show-SysPilotServiceTuner; Read-SysPilotChoice "Weiter mit Enter" | Out-Null }
                    '10' { Show-SysPilotFeaturesMenu }
                    '11' { Show-SysPilotCleanupMenu; Read-SysPilotChoice "Weiter mit Enter" | Out-Null }
                    '12' { Invoke-SysPilotFreeRam; Read-SysPilotChoice "Weiter mit Enter" | Out-Null }
                    '13' { Set-SysPilotPriorities; Read-SysPilotChoice "Weiter mit Enter" | Out-Null }
                    '14' { Show-SysPilotSettingsMenu }
                    '15' {
                        if (Assert-SysPilotAdmin) {
                            $b = New-SysPilotBackup -Label "menu"
                            Write-Host "  Backup erstellt: $b" -ForegroundColor Green
                            $backups = Get-SysPilotBackups
                            if ($backups.Count -gt 1) {
                                Write-Host "  Vorhandene Backups:" -ForegroundColor DarkGray
                                $backups | ForEach-Object { Write-Host "    $($_.Name)" -ForegroundColor DarkGray }
                                if (Confirm-SysPilot "Dienste aus einem Backup wiederherstellen?") {
                                    $bn = Read-SysPilotChoice "Backup-Name"
                                    $bp = Join-Path $script:Root "backup\$bn"
                                    if (Test-Path $bp) { Restore-SysPilotServices -BackupPath $bp }
                                }
                            }
                        }
                        Read-SysPilotChoice "Weiter mit Enter" | Out-Null
                    }
                    '16' { Restart-SysPilotElevated }
                    '17' { Show-SysPilotHogs; Read-SysPilotChoice "Weiter mit Enter" | Out-Null }
                    '18' { Show-SysPilotStats; Read-SysPilotChoice "Weiter mit Enter" | Out-Null }
                    '19' { Show-SysPilotScriptsMenu }
                    '20' {
                        $gui = Join-Path $script:Root 'SysPilot-GUI.ps1'
                        if (Test-SysPilotAdmin) {
                            Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$gui
                        } else {
                            Start-Process powershell.exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$gui
                        }
                    }
                    '21' { Show-SysPilotExtensionManager }
                    '22' { Show-SysPilotNetworkRepair }
                    '23' { Show-SysPilotNetworkAdapters }
                    '0'  { return }
                }
            }
        }
    }
}

Show-SysPilotMenu
