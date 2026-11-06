# SysPilot - Dein intelligenter PC-Autopilot
# Kuehlt, beschleunigt und aufraeumen - besser als Camomile, kostenlos, offen.
#Requires -Version 5.1
param(
    [switch]$Autopilot,
    [switch]$CheckupAuto,
    [switch]$Guardian,
    [switch]$Loop,
    [string]$Tool
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

# Guardian (fuer geplante Aufgabe "SysPilot Guardian"): startet die GUI, falls sie nicht laeuft
if ($Guardian) {
    if ($Loop) { Invoke-SysPilotGuardianLoop } else { Invoke-SysPilotGuardian }
    return
}

# Geplanter Checkup (fuer geplante Aufgabe "SysPilot Checkup"): scannt und behebt laut Zeitplan
if ($CheckupAuto) {
    $sched = Get-SysPilotCheckupSchedule
    $results = Invoke-SysPilotCheckupScan -Quiet
    $found = @($results | Where-Object { $_.Found }).Count
    Write-SysPilotLog "Checkup (geplant): $found Bereiche mit Befunden"
    if ($sched.AutoFix -and $found -gt 0) {
        $fixable = @($results | Where-Object { $_.Found -and $_.AutoFix })
        if ($fixable.Count -gt 0) {
            $fixed = Invoke-SysPilotCheckupFix -Results $fixable
            Write-SysPilotLog "Checkup (geplant): $fixed Bereiche automatisch behoben"
        }
    }
    return
}

# Direktaufruf eines Werkzeugs (z.B. aus der GUI-Toolbox heraus)
if ($Tool) {
    switch ($Tool) {
        'checkup'      { Show-SysPilotCheckup }
        'toolbox'      { Show-SysPilotToolbox }
        'plans'        { Install-SysPilotPlans; Read-SysPilotChoice 'Weiter' | Out-Null }
        'autopilot'    { Start-SysPilotAutopilot }
        'startup'      { Show-SysPilotStartupManager }
        'services'     { Show-SysPilotServiceTuner; Read-SysPilotChoice 'Weiter' | Out-Null }
        'freemem'      { Invoke-SysPilotFreeRam; Read-SysPilotChoice 'Weiter' | Out-Null }
        'priorities'   { Set-SysPilotPriorities; Read-SysPilotChoice 'Weiter' | Out-Null }
        'features'     { Show-SysPilotFeaturesMenu }
        'scripts'      { Show-SysPilotScriptsMenu }
        'security'     { Show-SysPilotSecurityCheck; Read-SysPilotChoice 'Weiter' | Out-Null }
        'netrepair'    { Show-SysPilotNetworkRepair }
        'adapters'     { Show-SysPilotNetworkAdapters }
        'winupdate'    { Update-SysPilotWindows; Read-SysPilotChoice 'Weiter' | Out-Null }
        'backup'       { $b = New-SysPilotBackup -Label 'tool'; Write-Host "  Backup: $b" -ForegroundColor Green; Read-SysPilotChoice 'Weiter' | Out-Null }
        'cleanup'      { Show-SysPilotCleanupMenu; Read-SysPilotChoice 'Weiter' | Out-Null }
        'bloat'        { Show-SysPilotBloatManager }
        'optimizers'   { Show-SysPilotOptimizerManager; Read-SysPilotChoice 'Weiter' | Out-Null }
        'uwp'          { Show-SysPilotUwpManager }
        'shortcuts'    { Show-SysPilotShortcutFixer; Read-SysPilotChoice 'Weiter' | Out-Null }
        'largefiles'   { Show-SysPilotLargeFiles; Read-SysPilotChoice 'Weiter' | Out-Null }
        'emptyfolders' { Show-SysPilotEmptyFolders; Read-SysPilotChoice 'Weiter' | Out-Null }
        'extensions'   { Show-SysPilotExtensionManager }
        'report'       { Show-SysPilotReport; Read-SysPilotChoice 'Weiter' | Out-Null }
        'hogs'         { Show-SysPilotHogs; Read-SysPilotChoice 'Weiter' | Out-Null }
        'stats'        { Show-SysPilotStats; Read-SysPilotChoice 'Weiter' | Out-Null }
        'sysinfo'      { Show-SysPilotSystemInfo; Read-SysPilotChoice 'Weiter' | Out-Null }
        'autooptimize' { Invoke-SysPilotAutoOptimize; Read-SysPilotChoice 'Weiter' | Out-Null }
        'checkupschedule' { Show-SysPilotCheckupScheduleMenu }
        'guardian'     { Show-SysPilotGuardianMenu }
        'autopilottask' {
            $t = Get-ScheduledTask -TaskName 'SysPilot Autopilot' -ErrorAction SilentlyContinue
            if ($t) { Remove-SysPilotAutopilotTask } else { Install-SysPilotAutopilotTask }
            Read-SysPilotChoice 'Weiter' | Out-Null
        }
        'smartboost'   {
            $cur = [bool](Get-SysPilotConfig).Autopilot.AutoFreeRam
            Set-SysPilotConfigValue -Section 'Autopilot' -Key 'AutoFreeRam' -Value (-not $cur)
            $new = -not $cur
            Write-Host ""
            Write-Host ("  Smart Boost (RAM automatisch freigeben im Autopilot): " + $(if ($new) { 'AN' } else { 'AUS' })) -ForegroundColor $(if ($new) { 'Green' } else { 'Yellow' })
            if ($new) {
                Write-Host '  Der Autopilot gibt RAM automatisch frei, wenn er knapp wird.' -ForegroundColor DarkGray
                $t = Get-ScheduledTask -TaskName 'SysPilot Autopilot' -ErrorAction SilentlyContinue
                if (-not $t) {
                    Write-Host '  Tipp: Autopilot bei Anmeldung starten (Toolbox: "Autopilot bei Anmeldung").' -ForegroundColor DarkGray
                }
            }
            Read-SysPilotChoice 'Weiter' | Out-Null
        }
        default        { Write-Host "  Unbekanntes Werkzeug: $Tool" -ForegroundColor Red }
    }
    return
}

# Admin nur als Menue-Option (16), keine Start-Frage.
# Optional: config.json -> Start.AskForAdmin = true (fragt) oder Start.AlwaysAdmin = true (automatisch)
$startCfg = (Get-SysPilotConfig).Start
if (-not (Test-SysPilotAdmin) -and $startCfg -and ($startCfg.AskForAdmin -or $startCfg.AlwaysAdmin)) {
    Restart-SysPilotElevated
}

function Close-SysPilotToTray {
    <# "Beenden" = SysPilot laeuft im Hintergrund weiter: GUI im Tray starten (falls nicht schon offen). #>
    $cfg = (Get-SysPilotConfig).Start
    if ($cfg -and $cfg.PSObject.Properties['GuiOnExit'] -and -not $cfg.GuiOnExit) { return }

    # Laeuft die GUI schon? (Mutex ist prozess-lokal pruefbar - stattdessen Fenster suchen)
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    $guiRunning = Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'SysPilot-GUI\.ps1' -and $_.ProcessId -ne $PID }
    if ($guiRunning) {
        Write-Host '  SysPilot laeuft bereits im Hintergrund (Tray-Symbol).' -ForegroundColor DarkGray
        return
    }
    $gui = Join-Path $script:Root 'SysPilot-GUI.ps1'
    Write-Host ''
    Write-Host '  SysPilot laeuft im Hintergrund weiter (Tray-Symbol neben der Uhr).' -ForegroundColor DarkCyan
    Write-Host '  Doppelklick aufs Symbol = Dashboard. Rechtsklick = Beenden.' -ForegroundColor DarkGray
    Write-Host '  (Abschalten: Einstellungen -> "Beim Beenden im Hintergrund weiterlaufen")' -ForegroundColor DarkGray
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList (ConvertTo-SysPilotArgString @('-NoProfile','-ExecutionPolicy','Bypass','-File',$gui,'-StartHidden'))
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

        $startCfg = (Get-SysPilotConfig).Start
        $alwaysAdmin = [bool]$startCfg.AlwaysAdmin
        $guiOnExit = if ($null -ne $startCfg.GuiOnExit) { [bool]$startCfg.GuiOnExit } else { $true }
        $aaTxt = if ($alwaysAdmin) { 'AN' } else { 'AUS' }
        $geTxt = if ($guiOnExit) { 'AN' } else { 'AUS' }
        $trayStart = [bool]($startCfg.PSObject.Properties['StartInTray'] -and $startCfg.StartInTray)
        $tsTxt = if ($trayStart) { 'AN' } else { 'AUS' }

        $items = @(
            @{ Label = "Sprache / Language: $langTxt"; Color = 'White'; Tag = 'lang' },
            @{ Label = "Temperatureinheit: $unitTxt"; Color = 'White'; Tag = 'unit' },
            @{ Label = "Immer als Administrator starten: $aaTxt"; Color = 'White'; Tag = 'alwaysadmin' },
            @{ Label = "Beim Beenden im Hintergrund weiterlaufen (Tray): $geTxt"; Color = 'White'; Tag = 'guionexit' },
            @{ Label = "GUI beim Start nur im Tray (ohne Fenster): $tsTxt"; Color = 'White'; Tag = 'traystart' },
            @{ Label = "Konfiguration (Programme, Spiele, Ballast)"; Color = 'White'; Tag = 'config' },
            @{ Label = "Zurueck"; Color = 'DarkGray'; Tag = $null }
        )
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'Einstellungen'
        if ($null -eq $sel) { return }
        switch ($sel) {
            'alwaysadmin' {
                $new = -not $alwaysAdmin
                Set-SysPilotConfigValue -Section 'Start' -Key 'AlwaysAdmin' -Value $new
                if ($new) {
                    $n = Set-SysPilotShortcutRunAs -RunAs $true
                    Write-Host "  [OK] Immer als Administrator: AN (ab naechstem Start)." -ForegroundColor Green
                    if ($n -gt 0) { Write-Host "  [OK] $n Verknuepfung(en) auf 'Als Administrator ausfuehren' gesetzt." -ForegroundColor Green }
                    else { Write-Host "  [i] Keine Verknuepfungen gefunden - gilt trotzdem beim Start von SysPilot." -ForegroundColor DarkGray }
                } else {
                    $n = Set-SysPilotShortcutRunAs -RunAs $false
                    Write-Host "  [OK] Immer als Administrator: AUS." -ForegroundColor Green
                }
                Read-SysPilotChoice "Weiter" | Out-Null
            }
            'traystart' {
                $new = -not $trayStart
                Set-SysPilotConfigValue -Section 'Start' -Key 'StartInTray' -Value $new
                if ($new) {
                    Write-Host '  [OK] GUI-Start: nur im Tray (Symbol neben der Uhr, ggf. unter ^ "Ausgeblendete Symbole").' -ForegroundColor Green
                    Write-Host '  Fenster oeffnen: Doppelklick aufs Symbol, oder die Verknuepfung nochmal starten.' -ForegroundColor DarkGray
                } else {
                    Write-Host '  [OK] GUI-Start: Fenster oeffnet sich (Symbol bleibt im Tray).' -ForegroundColor Green
                }
                Read-SysPilotChoice "Weiter" | Out-Null
            }
            'guionexit' {
                $new = -not $guiOnExit
                Set-SysPilotConfigValue -Section 'Start' -Key 'GuiOnExit' -Value $new
                Write-Host ("  [OK] Beim Beenden im Hintergrund weiterlaufen: " + $(if ($new) { 'AN' } else { 'AUS' })) -ForegroundColor Green
                Read-SysPilotChoice "Weiter" | Out-Null
            }
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
        @{ Key = '24'; Label = 'AUTOMATIC CHECKUP (Komplett-Scan, Erklaerungen, Reparatur)'; Color = 'Green' },
        @{ Key = '25'; Label = 'TOOLBOX (alle Werkzeuge nach Kategorien)'; Color = 'Cyan' },
        @{ Key = '26'; Label = 'SMART HEALTH MONITOR (CPU/RAM/Disk/Temp)'; Color = 'Cyan' },
        @{ Key = '27'; Label = 'DNS-MANAGER (Adapter, Anbieter, Backup)'; Color = 'Cyan' },
        @{ Key = '28'; Label = 'KI-SUCHE (HowTo & Tipps im Browser)'; Color = 'Yellow' },
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
            27 { Close-SysPilotToTray; return }                      # Esc
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
                            Start-Process powershell.exe -Verb RunAs -ArgumentList (ConvertTo-SysPilotArgString @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$gui))
                        } else {
                            Start-Process powershell.exe -ArgumentList (ConvertTo-SysPilotArgString @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$gui))
                        }
                    }
                    '21' { Show-SysPilotExtensionManager }
                    '22' { Show-SysPilotNetworkRepair }
                    '23' { Show-SysPilotNetworkAdapters }
                    '24' { Show-SysPilotCheckup }
                    '25' { Show-SysPilotToolbox }
                    '26' { Show-SysPilotHealthDashboard }
                    '27' { Show-SysPilotDnsManager }
                    '28' { Invoke-SysPilotAISearch -Query (Read-SysPilotChoice 'Suchbegriff') }
                    '0'  { Close-SysPilotToTray; return }
                }
            }
        }
    }
}

Show-SysPilotMenu
