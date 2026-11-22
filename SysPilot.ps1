# SysPilot - Dein intelligenter PC-Autopilot
# Kuehlt, beschleunigt und aufraeumen - besser als Camomile, kostenlos, offen.
#Requires -Version 5.1
param(
    [switch]$Autopilot,
    [switch]$CheckupAuto,
    [switch]$Guardian,
    [switch]$Loop,
    [string]$Tool,
    [switch]$FromGui
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

# =======================================================================
# HAUPTMENUE (Pfeiltasten-Auswahl via Show-SysPilotArrowMenu)
# =======================================================================
function Close-SysPilotToTray {
    <# "Beenden" = SysPilot laeuft im Hintergrund weiter: GUI im Tray starten (falls nicht schon offen). #>
    $cfg = (Get-SysPilotConfig).Start
    if ($cfg -and $cfg.PSObject.Properties['GuiOnExit'] -and -not $cfg.GuiOnExit) { return }

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
        $unitTxt = if ($unit -eq 'C') { 'Celsius (C)' } else { 'Fahrenheit (F)' }

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
                    Set-SysPilotShortcutRunAs -RunAs $false | Out-Null
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

function Invoke-SysPilotPlanSwitch {
    <# Wechselt den Energieplan (Cool/Performance). Fehlender Plan -> Angebot zum Einrichten,
       fehlende Admin-Rechte -> Angebot zum Neustart. #>
    param([ValidateSet('Cool','Performance')][string]$Mode)
    $name = if ($Mode -eq 'Cool') { 'SysPilot Kuehl & Leise' } else { 'SysPilot Leistung' }
    if (-not (Get-SysPilotPlanGuid -Name $name)) {
        Write-Host "  Plan '$name' existiert noch nicht." -ForegroundColor Yellow
        if (Confirm-SysPilot 'Energieplaene jetzt einrichten? (braucht Admin)') {
            Install-SysPilotPlans
        } else { return }
    }
    if (-not (Test-SysPilotAdmin)) {
        Write-Host "  Plan-Wechsel braucht Administrator-Rechte." -ForegroundColor Yellow
        if (Confirm-SysPilot 'SysPilot jetzt als Administrator neu starten?') {
            Restart-SysPilotElevated
        }
        return
    }
    Set-SysPilotPlan -Mode $Mode | Out-Null
    $now = Get-SysPilotActiveMode
    if ($now -eq $Mode) {
        Write-Host "  [OK] Energieplan aktiv: $name" -ForegroundColor Green
    } else {
        Write-Host "  [!] Wechsel hat nicht geklappt (aktuell: $now)." -ForegroundColor Yellow
    }
}

function Show-SysPilotMenu {
    $isAdmin = Test-SysPilotAdmin
    $adminTag = if ($isAdmin) { "ADMIN" } else { "eingeschraenkt" }

    $items = @(
        @{ Label = 'System-Analyse (Was bremst meinen PC?)';      Color = 'White';    Tag = 'report' }
        @{ Label = 'AUTOPILOT starten (Live-Umschaltung + Prioritaeten)'; Color = 'Green'; Tag = 'autopilot' }
        @{ Label = 'Energieplan: Kuehl & Leise (Temperatur-Schutz)'; Color = 'White'; Tag = 'cool' }
        @{ Label = 'Energieplan: Leistung';                        Color = 'White';    Tag = 'perf' }
        @{ Label = 'Autopilot bei Anmeldung automatisch starten/entfernen'; Color = 'White'; Tag = 'autopilottask' }
        @{ Label = 'RAM freigeben (Working Sets + Standby-Cache)'; Color = 'Green';   Tag = 'freemem' }
        @{ Label = 'Autostart-Manager';                            Color = 'White';    Tag = 'startup' }
        @{ Label = 'HOSTS-Editor (Eintraege, Sperre, DNS-Flush)';   Color = 'White';    Tag = 'hosts' }
        @{ Label = 'Programme deinstallieren (Bloatware-Finder)';  Color = 'White';    Tag = 'bloat' }
        @{ Label = 'OPTIMIZER AUSMISTEN (auswaehlen, welche bleiben)'; Color = 'Magenta'; Tag = 'optimizers' }
        @{ Label = 'AUTO-OPTIMIERUNG (Dienste + Features + Tweaks, mit Backup)'; Color = 'Green'; Tag = 'autooptimize' }
        @{ Label = 'Dienste optimieren';                           Color = 'White';    Tag = 'services' }
        @{ Label = 'Windows-Funktionen & Gaming-Tweaks';           Color = 'White';    Tag = 'features' }
        @{ Label = 'Datentraeger bereinigen';                      Color = 'White';    Tag = 'cleanup' }
        @{ Label = 'Prozess-Prioritaeten einmalig anwenden';       Color = 'White';    Tag = 'priorities' }
        @{ Label = 'Einstellungen (Sprache, Einheiten, Konfiguration)'; Color = 'White'; Tag = 'settings' }
        @{ Label = 'Backup erstellen / Dienste wiederherstellen'; Color = 'White';    Tag = 'backupmenu' }
        @{ Label = 'Als Administrator neu starten';                Color = 'White';    Tag = 'admin' }
        @{ Label = 'RESSOURCEN-FRESSER & Massnahmen';              Color = 'Yellow';   Tag = 'hogs' }
        @{ Label = 'Statistiken (Verlauf)';                        Color = 'White';    Tag = 'stats' }
        @{ Label = 'SKRIPTE (Gaming/Arbeit/Kuehl/Nacht - anpassbar)'; Color = 'Green'; Tag = 'scripts' }
        @{ Label = 'GRAFISCHE OBERFLAECHE (Live-Dashboard)';       Color = 'Cyan';     Tag = 'gui' }
        @{ Label = 'BROWSER-ERWEITERUNGEN (Duplikate finden)';      Color = 'Yellow';   Tag = 'extensions' }
        @{ Label = 'NETZWERK / INTERNET reparieren';               Color = 'Cyan';     Tag = 'netrepair' }
        @{ Label = 'SYSTEM-REPARATUR (Dateizuordnungen, Dienste, UAC, WMI)'; Color = 'Yellow'; Tag = 'sysrepair' }
        @{ Label = 'SYSTEM-TUNING (Netzwerk-, System-, Explorer-Tweaks)'; Color = 'Magenta'; Tag = 'systune' }
        @{ Label = 'WINDOWS-11-UI (Taskbar, Kontextmenue, Admin-Eintraege)'; Color = 'Cyan'; Tag = 'win11ui' }
        @{ Label = 'NETZWERKADAPTER identifizieren (was ist vgate0?)'; Color = 'Cyan'; Tag = 'adapters' }
        @{ Label = 'AUTOMATIC CHECKUP (Komplett-Scan, Erklaerungen, Reparatur)'; Color = 'Green'; Tag = 'checkup' }
        @{ Label = 'TOOLBOX (alle Werkzeuge nach Kategorien)';     Color = 'Cyan';     Tag = 'toolbox' }
        @{ Label = 'SMART HEALTH MONITOR';                         Color = 'Cyan';     Tag = 'health' }
        @{ Label = 'ADVANCED DNS MANAGER';                         Color = 'Cyan';     Tag = 'dns' }
        @{ Label = 'KI-Suche';                                     Color = 'White';    Tag = 'aisearch' }
        @{ Label = 'SPEICHER-ANALYSE (pagefile, hiberfil, Temp, WinSxS)'; Color = 'Cyan'; Tag = 'storage' }
        @{ Label = 'PC-ANALYSE (CPU, RAM, GPU, Mainboard, Laufwerke)'; Color = 'Cyan'; Tag = 'hardware' }
        @{ Label = 'TREIBER-WERKSTATT (Problemgeraete, Inventar, Rollback)'; Color = 'Yellow'; Tag = 'drivers' }
        @{ Label = 'WIZTREE (Festplatten-/Ordneranalyse)';            Color = 'White';    Tag = 'wiztree' }
        @{ Label = 'Beenden (SysPilot laeuft im Tray weiter)';     Color = 'DarkGray'; Tag = 'tray' }
    )

    while ($true) {
        $sel = Show-SysPilotArrowMenu -Items $items -Title "SysPilot $(Get-SysPilotVersion) - PC-Autopilot [$adminTag]" -Footer 'Pfeiltasten hoch/runter, Enter = ausfuehren, Esc = beenden'
        if ($null -eq $sel) { Close-SysPilotToTray; return }
        if ($sel -eq 'tray') { Close-SysPilotToTray; return }
        Invoke-SysPilotTool -Name $sel
    }
}

# =======================================================================
# NEU: Advanced DNS Manager (Show-SysPilotDnsWindow)
# =======================================================================
function Show-SysPilotDnsWindow {
    <# Oeffnet den Advanced DNS Manager: Adapter waehlen, Provider testen, DNS setzen, Cache pruefen #>
    while ($true) {
        Write-Host ""
        Write-Host "  ========================================================" -ForegroundColor Cyan
        Write-Host "           ADVANCED DNS MANAGER" -ForegroundColor Cyan
        Write-Host "           DNS-Adapter - Provider - Cache - Lookup" -ForegroundColor Cyan
        Write-Host "  ========================================================" -ForegroundColor Cyan
        Write-Host ""

        $adapters = @(Get-SysPilotDnsAdapters)
        $items = @()
        foreach ($a in $adapters) {
            $items += @{ Label = "$($a.Name)  [$($a.Status)]  DNS: $($a.DnsServers)"; Color = 'White'; Tag = $a }
        }
        $items += @{ Label = 'DNS-Provider testen (Latenzvergleich)'; Color = 'Yellow'; Tag = 'TEST' }
        $items += @{ Label = 'DNS-Cache anzeigen'; Color = 'Yellow'; Tag = 'CACHE' }
        $items += @{ Label = 'DNS-Cache leeren (flush)'; Color = 'Yellow'; Tag = 'FLUSH' }
        $items += @{ Label = 'DNS-Lookup (Domain -> IP)'; Color = 'Cyan'; Tag = 'LOOKUP' }
        $items += @{ Label = 'Reverse-DNS (IP -> Domain)'; Color = 'Cyan'; Tag = 'REVERSE' }
        $items += @{ Label = 'DNS-Historie anzeigen'; Color = 'DarkGray'; Tag = 'HISTORY' }
        $items += @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = $null }

        $sel = Show-SysPilotArrowMenu -Items $items -Title 'Advanced DNS Manager' -Footer 'Pfeiltasten, Enter = ausfuehren, Esc = zurueck'
        if ($null -eq $sel) { return }

        if ($sel -eq 'TEST') {
            Write-Host ""
            Write-Host "  Teste alle DNS-Provider (google.com) ..." -ForegroundColor DarkGray
            $results = Test-SysPilotAllDnsProviders -TestDomain 'google.com'
            Write-Host ""
            foreach ($r in $results) {
                $farbe = if ($r.Erfolg) { 'Green' } else { 'Red' }
                $latenz = if ($r.LatenzMs) { "$($r.LatenzMs) ms" } else { '---' }
                Write-Host "    $($r.Provider): $(if ($r.Erfolg) { 'OK' } else { 'FEHL' })  Latenz: $latenz" -ForegroundColor $farbe
            }
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            continue
        }

        if ($sel -eq 'CACHE') {
            Write-Host ""
            Show-SysPilotDnsCache
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            continue
        }

        if ($sel -eq 'FLUSH') {
            Write-Host ""
            if (Confirm-SysPilot 'DNS-Cache wirklich leeren?') {
                if (Clear-SysPilotDnsCache) {
                    Write-Host '  [OK] DNS-Cache geleert.' -ForegroundColor Green
                }
            }
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            continue
        }

        if ($sel -eq 'LOOKUP') {
            Write-Host ""
            $domain = Read-SysPilotChoice 'Domain (z.B. google.com)'
            if ($domain) {
                $r = Invoke-SysPilotDnsLookup -Domain $domain
                Write-Host ""
                Write-Host "  Ergebnis fuer $domain (Server: $($r.Server))" -ForegroundColor Cyan
                $r.Output | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
                Write-Host "  Latenz: $($r.LatenzMs) ms" -ForegroundColor DarkGray
            }
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            continue
        }

        if ($sel -eq 'REVERSE') {
            Write-Host ""
            $ip = Read-SysPilotChoice 'IP-Adresse (z.B. 8.8.8.8)'
            if ($ip) {
                $r = Invoke-SysPilotReverseDns -IpAddress $ip
                Write-Host ""
                Write-Host "  Reverse-DNS fuer $ip (Server: $($r.Server))" -ForegroundColor Cyan
                $r.Output | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
            }
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            continue
        }

        if ($sel -eq 'HISTORY') {
            Write-Host ""
            $history = @(Get-SysPilotDnsHistory)
            if ($history.Count -eq 0) {
                Write-Host '  Keine Historie vorhanden.' -ForegroundColor DarkGray
            } else {
                $history | Select-Object -First 20 | ForEach-Object {
                    Write-Host "    $($_.Zeit)  $($_.Domain)  $($_.RecordType)  $($_.Result)  $($_.Provider)  $($_.LatencyMs)ms" -ForegroundColor DarkGray
                }
            }
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            continue
        }

        # Adapter ausgewaehlt: DNS setzen
        $adapter = $sel
        Write-Host ""
        Write-Host "  Adapter: $($adapter.Name)  (aktuell: $($adapter.DnsServers))" -ForegroundColor Cyan
        Write-Host ""
        $provItems = @()
        foreach ($key in $script:DnsProviders.Keys) {
            $p = $script:DnsProviders[$key]
            $provItems += @{ Label = "$($p.Name)  -  $($p.Beschreibung)"; Color = 'White'; Tag = $key }
        }
        $provItems += @{ Label = 'Eigene DNS-Server eintragen'; Color = 'Yellow'; Tag = 'CUSTOM' }
        $provItems += @{ Label = 'Auf DHCP/Automatisch zuruecksetzen'; Color = 'Yellow'; Tag = 'DHCP' }
        $provItems += @{ Label = 'Abbrechen'; Color = 'DarkGray'; Tag = $null }

        $provSel = Show-SysPilotArrowMenu -Items $provItems -Title 'DNS-Anbieter waehlen' -Footer 'Enter = uebernehmen, Esc = abbrechen'
        if ($null -eq $provSel) { continue }

        if ($provSel -eq 'CUSTOM') {
            Write-Host ""
            $custom = Read-SysPilotChoice 'DNS-Server (kommagetrennt, z.B. 8.8.8.8, 1.1.1.1)'
            if ($custom) {
                $servers = ($custom -split ',') | ForEach-Object { $_.Trim() }
                if (Set-SysPilotDnsServers -InterfaceIndex $adapter.ifIndex -ServerAddresses $servers) {
                    Write-Host '  [OK] DNS-Server gesetzt.' -ForegroundColor Green
                }
            }
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            continue
        }

        if ($provSel -eq 'DHCP') {
            Write-Host ""
            if (Confirm-SysPilot 'DNS auf Automatisch (DHCP) zuruecksetzen?') {
                if (Reset-SysPilotDnsToDhcp -InterfaceIndex $adapter.ifIndex) {
                    Write-Host '  [OK] DNS auf DHCP zurueckgesetzt.' -ForegroundColor Green
                }
            }
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            continue
        }

        # Bekannter Provider
        $provider = $script:DnsProviders[$provSel]
        $ips = @($provider.Ips)
        if ($ips.Count -gt 0) {
            if (Confirm-SysPilot "$($provider.Name) ($($ips -join ', ')) auf Adapter '$($adapter.Name)' setzen?") {
                if (Set-SysPilotDnsServers -InterfaceIndex $adapter.ifIndex -ServerAddresses $ips) {
                    Write-Host "  [OK] $($provider.Name) gesetzt." -ForegroundColor Green
                }
            }
        } else {
            Write-Host '  Dieser Provider hat keine konfigurierten IPs.' -ForegroundColor Yellow
        }
        Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
    }
}

# =======================================================================
# NEU: Smart Health Monitor (Show-SysPilotHealthDashboard)
# =======================================================================
function Show-SysPilotHealthDashboard {
    <# Oeffnet das Smart Health Monitor Dashboard: Hardware-Ueberwachung, Warnungen, KI-Ursachen, Reparatur-Howtos #>
    while ($true) {
        Write-Host ""
        Write-Host "  ========================================================" -ForegroundColor Cyan
        Write-Host "           SMART HEALTH MONITOR" -ForegroundColor Cyan
        Write-Host "           CPU - GPU - SSD - Luefter - Temperatur - KI" -ForegroundColor Cyan
        Write-Host "  ========================================================" -ForegroundColor Cyan
        Write-Host ""

        $health = Invoke-SysPilotHealthCheck
        $symbol = Get-SysPilotHealthSymbol -Modus $health.Modus

        Write-Host "  Status: $($symbol.Symbol)  $($symbol.Text)  ($($health.Modus))" -ForegroundColor $symbol.Farbe
        Write-Host "  Letzte Pruefung: $($health.Zeit)" -ForegroundColor DarkGray
        Write-Host ""

        if ($health.CpuTemp) { Write-Host "  CPU-Temperatur: $($health.CpuTemp) C" -ForegroundColor $(if ($health.CpuTemp -ge 85) { 'Red' } elseif ($health.CpuTemp -ge 75) { 'Yellow' } else { 'Green' }) }
        if ($health.GpuTemp) { Write-Host "  GPU-Temperatur: $($health.GpuTemp) C" -ForegroundColor $(if ($health.GpuTemp -ge 85) { 'Red' } elseif ($health.GpuTemp -ge 75) { 'Yellow' } else { 'Green' }) }

        Write-Host ""
        if ($health.Warnungen.Count -gt 0) {
            Write-Host "  WARNINGS / WARNUNGEN:" -ForegroundColor Yellow
            foreach ($w in $health.Warnungen) {
                $farbe = if ($w.Schweregrad -eq 'KRITISCH') { 'Red' } else { 'Yellow' }
                Write-Host "    [$($w.Schweregrad)] $($w.Text)" -ForegroundColor $farbe
            }
        } else {
            Write-Host "  OK: Alle Werte im Normalbereich." -ForegroundColor Green
        }

        Write-Host ""
        $items = @()
        $items += @{ Label = 'KI-Ursachenanalyse + Reparatur-Howtos'; Color = 'Cyan'; Tag = 'URSACHEN' }
        $items += @{ Label = 'Online Reparatur-Howtos (KI-Recherche)'; Color = 'Cyan'; Tag = 'ONLINEHOWTOS' }
        $items += @{ Label = 'Nahegelegene Reparaturlaeden (KI + Standort)'; Color = 'Cyan'; Tag = 'REPARATUR' }
        $items += @{ Label = 'Ersatzteil-Empfehlungen'; Color = 'Cyan'; Tag = 'ERSETZTEILE' }
        $items += @{ Label = 'SSD Health (SMART) anzeigen'; Color = 'Yellow'; Tag = 'SSD' }
        $items += @{ Label = 'Luefter-Details anzeigen'; Color = 'Yellow'; Tag = 'FANS' }
        $items += @{ Label = 'Alle Sensoren (LibreHardwareMonitor)'; Color = 'DarkGray'; Tag = 'SENSOREN' }
        $items += @{ Label = 'LibreHardwareMonitor installieren'; Color = 'Yellow'; Tag = 'LHM' }
        $items += @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = $null }

        $sel = Show-SysPilotArrowMenu -Items $items -Title 'Smart Health Monitor' -Footer 'Enter = ausfuehren, Esc = zurueck'
        if ($null -eq $sel) { return }

        if ($sel -eq 'URSACHEN') {
            Write-Host ""
            if ($health.Warnungen.Count -eq 0) {
                Write-Host '  Keine Warnungen - keine Ursachenanalyse noetig.' -ForegroundColor Green
            } else {
                foreach ($w in $health.Warnungen) {
                    Write-Host ""
                    Write-Host "  === $($w.Komponente): $($w.Text) ===" -ForegroundColor Cyan
                    $urs = Get-SysPilotHealthUrsachen -Komponente $w.Komponente -Wert $w.Wert -Einheit $w.Einheit
                    if ($urs.Ursachen.Count -gt 0) {
                        Write-Host '  Moegliche Ursachen:' -ForegroundColor DarkGray
                        $urs.Ursachen | ForEach-Object { Write-Host "    - $_" -ForegroundColor DarkGray }
                    }
                    if ($urs.HowTos.Count -gt 0) {
                        Write-Host '  Reparatur-Howtos:' -ForegroundColor DarkGray
                        foreach ($h in $urs.HowTos) {
                            Write-Host "    Reparatur: $($h.Titel) ($($h.Schwierigkeit), ~$($h.ZeitMin) Min)" -ForegroundColor DarkGray
                            Write-Host "       $($h.Beschreibung)" -ForegroundColor DarkGray
                        }
                    }
                    $teile = Get-SysPilotErsatzteile -Komponente $w.Komponente
                    if ($teile.Count -gt 0) {
                        Write-Host '  Ersatzteile:' -ForegroundColor DarkGray
                        $teile | ForEach-Object { Write-Host "    $($_.Produkt) - $($_.Zweck) (~$($_.PriceEur))" -ForegroundColor DarkGray }
                    }
                }
            }
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            continue
        }

        if ($sel -eq 'ONLINEHOWTOS') {
            Write-Host ""
            $suchbegriff = Read-SysPilotChoice 'Suchbegriff (z.B. "CPU zu heiss", "SSD langsam", "Luefter laut")'
            if ($suchbegriff) {
                Write-Host "  Suche online nach Reparatur-Howtos ..." -ForegroundColor DarkGray
                $howtos = Get-SysPilotRepairHowtosOnline -Suchbegriff $suchbegriff
                Write-Host ""
                foreach ($h in $howtos) {
                    Write-Host "  Reparatur: $($h.Titel)" -ForegroundColor Cyan
                    Write-Host "     $($h.Beschreibung)" -ForegroundColor DarkGray
                    Write-Host "     $($h.Url)" -ForegroundColor DarkGray
                    Write-Host ""
                }
            }
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            continue
        }

        if ($sel -eq 'REPARATUR') {
            Write-Host ""
            $shops = Get-SysPilotNearbyRepairShops
            Write-Host "  Nahegelegene Reparaturlaeden:" -ForegroundColor Cyan
            Write-Host ""
            foreach ($s in $shops) {
                Write-Host "  Shop: $($s.Name)" -ForegroundColor Yellow
                Write-Host "     $($s.Beschreibung)" -ForegroundColor DarkGray
                Write-Host "     $($s.Url)" -ForegroundColor DarkGray
                Write-Host ""
            }
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            continue
        }


        if ($sel -eq 'ERSETZTEILE') {
            Write-Host ""
            $kompItems = @()
            $kompItems += @{ Label = 'CPU'; Tag = 'CPU' }
            $kompItems += @{ Label = 'GPU'; Tag = 'GPU' }
            $kompItems += @{ Label = 'SSD'; Tag = 'SSD' }
            $kompItems += @{ Label = 'Luefter'; Tag = 'Luefter' }
            $kompItems += @{ Label = 'Zurueck'; Tag = $null }
            $k = Show-SysPilotArrowMenu -Items $kompItems -Title 'Ersatzteil-Empfehlungen'
            if ($k) {
                $teile = Get-SysPilotErsatzteile -Komponente $k
                Write-Host ""
                $teile | ForEach-Object {
                    Write-Host "    $($_.Produkt)" -ForegroundColor DarkGray
                    Write-Host "       Zweck: $($_.Zweck)  |  Preis: $($_.PriceEur)" -ForegroundColor DarkGray
                }
            }
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            continue
        }

        if ($sel -eq 'SSD') {
            Write-Host ""
            $ssds = @(Get-SysPilotSsdHealth)
            if ($ssds.Count -eq 0) {
                Write-Host '  Keine SSD-Informationen verfuegbar.' -ForegroundColor DarkGray
            } else {
                $ssds | ForEach-Object {
                    Write-Host "    $($_.Name)  ($($_.Typ))  Gesundheit: $($_.Gesundheit)  $($_.SizeGB) GB" -ForegroundColor $(if ($_.Gesundheit -ne 'Gesund') { 'Red' } else { 'Green' })
                }
            }
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            continue
        }

        if ($sel -eq 'FANS') {
            Write-Host ""
            $fans = @(Get-SysPilotFanSpeeds)
            if ($fans.Count -eq 0) {
                Write-Host '  Keine Luefter-Informationen verfuegbar (LibreHardwareMonitor noetig).' -ForegroundColor DarkGray
            } else {
                $fans | ForEach-Object {
                    Write-Host "    $($_.SensorName): $([math]::Round($_.Value)) RPM" -ForegroundColor DarkGray
                }
            }
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            continue
        }

        if ($sel -eq 'SENSOREN') {
            Write-Host ""
            $sens = @(Get-SysPilotLhmSensors)
            if ($sens.Count -eq 0) {
                Write-Host '  Keine Sensor-Daten verfuegbar. Installiere LibreHardwareMonitor.' -ForegroundColor DarkGray
            } else {
                $sens | Select-Object -First 40 | ForEach-Object {
                    Write-Host "    $($_.Hardware) / $($_.SensorName): $($_.Value) $($_.Unit)" -ForegroundColor DarkGray
                }
            }
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            continue
        }

        if ($sel -eq 'LHM') {
            Write-Host ""
            $lhmPath = Join-Path $script:Root 'tools\LibreHardwareMonitor\LibreHardwareMonitor.exe'
            if (Test-Path $lhmPath) {
                Write-Host '  LibreHardwareMonitor ist bereits installiert.' -ForegroundColor Green
                if (Confirm-SysPilot 'Jetzt starten?') {
                    & $lhmPath
                }
            } else {
                Write-Host '  LibreHardwareMonitor nicht gefunden. Installation...' -ForegroundColor Yellow
                if (Get-Command Install-SysPilotLHM -ErrorAction SilentlyContinue) {
                    Install-SysPilotLHM
                } else {
                    Write-Host '  Install-SysPilotLHM nicht verfuegbar (Temperature-Modul geladen?).' -ForegroundColor Yellow
                }
            }
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            continue
        }
    }
}

function Invoke-SysPilotTool {
    param([Parameter(Mandatory)][string]$Name)

    switch ($Name) {
        'checkup'      { Show-SysPilotCheckup; return }
        'toolbox'      { Show-SysPilotToolbox; return }
        'plans'        { Install-SysPilotPlans; Read-SysPilotChoice 'Weiter' | Out-Null; return }
        'autopilot'    { Start-SysPilotAutopilot; return }
        'cool'         { Invoke-SysPilotPlanSwitch -Mode Cool; Read-SysPilotChoice 'Weiter' | Out-Null; return }
        'perf'         { Invoke-SysPilotPlanSwitch -Mode Performance; Read-SysPilotChoice 'Weiter' | Out-Null; return }
        'autopilottask' {
            $t = Get-ScheduledTask -TaskName 'SysPilot Autopilot' -ErrorAction SilentlyContinue
            if ($t) { Remove-SysPilotAutopilotTask } else { Install-SysPilotAutopilotTask }
            Read-SysPilotChoice 'Weiter' | Out-Null; return
        }
        'settings'     { Show-SysPilotSettingsMenu; return }
        'admin'        { Restart-SysPilotElevated; return }
        'gui'          {
            $gui = Join-Path $script:Root 'SysPilot-GUI.ps1'
            if (Test-SysPilotAdmin) {
                Start-Process powershell.exe -Verb RunAs -ArgumentList (ConvertTo-SysPilotArgString @('-STA','-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$gui))
            } else {
                Start-Process powershell.exe -ArgumentList (ConvertTo-SysPilotArgString @('-STA','-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$gui))
            }
            return
        }
        'backupmenu'   {
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
            Read-SysPilotChoice 'Weiter' | Out-Null; return
        }
        'aisearch'     {
            $q = Read-SysPilotChoice 'KI-Suche (Begriff)' 'SysPilot'
            if ($q) { Start-Process 'https://duckduckgo.com/?q=' + [Uri]::EscapeDataString($q) }
            Read-SysPilotChoice 'Weiter' | Out-Null; return
        }
        'startup'      { Show-SysPilotStartupManager; return }
        'hosts'        { Show-SysPilotHostsEditor; return }
        'services'     { Show-SysPilotServiceTuner; Read-SysPilotChoice 'Weiter' | Out-Null; return }
        'freemem'      { Invoke-SysPilotFreeRam; Read-SysPilotChoice 'Weiter' | Out-Null; return }
        'priorities'   { Set-SysPilotPriorities; Read-SysPilotChoice 'Weiter' | Out-Null; return }
        'features'     { Show-SysPilotFeaturesMenu; return }
        'scripts'      { Show-SysPilotScriptsMenu; return }
        'security'     { Show-SysPilotSecurityCheck; Read-SysPilotChoice 'Weiter' | Out-Null; return }
        'drivers'      { Show-SysPilotDriverMenu; return }
        'hardware'     { Show-SysPilotHardwareMenu; return }
        'wiztree'      { Show-SysPilotWizTreeMenu; return }
        'netrepair'    { Show-SysPilotNetworkRepair; return }
        'sysrepair'    { Show-SysPilotSystemRepair; return }
        'systune'      { Show-SysPilotSystemTuning; return }
        'win11ui'      { Show-SysPilotWin11UiMenu; return }
        'win11taskbar' { Reset-SysPilotWin11Taskbar; Read-SysPilotChoice 'Weiter' | Out-Null; return }
        'win11ctx'     { Set-SysPilotContextMenuMode -Mode Toggle; Read-SysPilotChoice 'Weiter' | Out-Null; return }
        'win11ctxadmin'{ Show-SysPilotAdminContextMenuManager; return }
        'adapters'     { Show-SysPilotNetworkAdapters; return }
        'winupdate'    { Update-SysPilotWindows; Read-SysPilotChoice 'Weiter' | Out-Null; return }
        'backup'       { $b = New-SysPilotBackup -Label 'tool'; Write-Host "  Backup: $b" -ForegroundColor Green; Read-SysPilotChoice 'Weiter' | Out-Null; return }
        'cleanup'      { Show-SysPilotCleanupMenu; Read-SysPilotChoice 'Weiter' | Out-Null; return }
        'bloat'        { Show-SysPilotBloatManager; return }
        'optimizers'   { Show-SysPilotOptimizerManager; Read-SysPilotChoice 'Weiter' | Out-Null; return }
        'uwp'          { Show-SysPilotUwpManager; return }
        'shortcuts'    { Show-SysPilotShortcutFixer; Read-SysPilotChoice 'Weiter' | Out-Null; return }
        'largefiles'   { Show-SysPilotLargeFiles; Read-SysPilotChoice 'Weiter' | Out-Null; return }
        'emptyfolders' { Show-SysPilotEmptyFolders; Read-SysPilotChoice 'Weiter' | Out-Null; return }
        'extensions'   { Show-SysPilotExtensionManager; return }
        'report'       { Show-SysPilotReport; Read-SysPilotChoice 'Weiter' | Out-Null; return }
        'hogs'         { Show-SysPilotHogs; Read-SysPilotChoice 'Weiter' | Out-Null; return }
        'stats'        { Show-SysPilotStats; Read-SysPilotChoice 'Weiter' | Out-Null; return }
        'sysinfo'      { Show-SysPilotSystemInfo; Read-SysPilotChoice 'Weiter' | Out-Null; return }
        'autooptimize' { Invoke-SysPilotAutoOptimize; Read-SysPilotChoice 'Weiter' | Out-Null; return }
        'dns'          { Show-SysPilotDnsWindow; Read-SysPilotChoice 'Weiter' | Out-Null; return }
        'health'       { Show-SysPilotHealthDashboard; Read-SysPilotChoice 'Weiter' | Out-Null; return }
        'storage'      { Show-SysPilotStorageMenu; return }
        default        { Write-Host "  [!] Unbekanntes Werkzeug: $Name" -ForegroundColor Yellow; Read-SysPilotChoice 'Weiter' | Out-Null; return }
    }
}

if ($Tool) {
    Invoke-SysPilotTool -Name $Tool
    return
}

Show-SysPilotMenu

