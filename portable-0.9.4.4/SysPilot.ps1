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
        'dns'         { Show-SysPilotDnsWindow; Read-SysPilotChoice 'Weiter' | Out-Null }
        'health'      { Show-SysPilotHealthDashboard; Read-SysPilotChoice 'Weiter' | Out-Null }
    }
}

# =======================================================================
# HAUPTMENUE
# =======================================================================
function Show-SysPilotMenu {
    while ($true) {
        Clear-Host
        Write-Host ""
        Write-Host "  SysPilot 0.9.4.4 — Dein intelligenter PC-Autopilot" -ForegroundColor Cyan
        Write-Host "  ==================================================" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "   1  Autopilot starten" -ForegroundColor White
        Write-Host "   2  Kühl-Modus (Temperatur-Schutz)" -ForegroundColor White
        Write-Host "   3  Performance-Modus" -ForegroundColor White
        Write-Host "   4  RAM freigeben" -ForegroundColor White
        Write-Host "   5  Autostart-Manager" -ForegroundColor White
        Write-Host "   6  Bloatware-Manager" -ForegroundColor White
        Write-Host "   7  Optimizer-Manager" -ForegroundColor White
        Write-Host "   8  Auto-Optimierung" -ForegroundColor White
        Write-Host "   9  Dienste-Tuner" -ForegroundColor White
        Write-Host "  10  Windows-Features" -ForegroundColor White
        Write-Host "  11  Cleanup-Menü" -ForegroundColor White
        Write-Host "  12  RAM freigeben (Sofort)" -ForegroundColor White
        Write-Host "  13  Prozess-Prioritäten" -ForegroundColor White
        Write-Host "  14  Einstellungen" -ForegroundColor White
        Write-Host "  15  Backup / Wiederherstellung" -ForegroundColor White
        Write-Host "  16  Als Administrator neu starten" -ForegroundColor White
        Write-Host "  17  Ressourcen-Fresser" -ForegroundColor White
        Write-Host "  18  Statistiken" -ForegroundColor White
        Write-Host "  19  Skripte" -ForegroundColor White
        Write-Host "  20  GUI öffnen" -ForegroundColor White
        Write-Host "  21  Erweiterungen" -ForegroundColor White
        Write-Host "  22  Netzwerk-Reparatur" -ForegroundColor White
        Write-Host "  23  Netzwerkadapter" -ForegroundColor White
        Write-Host "  24  Checkup" -ForegroundColor White
        Write-Host "  25  Toolbox" -ForegroundColor White
        Write-Host "  26  Smart Health Monitor" -ForegroundColor Cyan
        Write-Host "  27  Advanced DNS Manager" -ForegroundColor Cyan
        Write-Host "  28  KI-Suche" -ForegroundColor White
        Write-Host "   0  In Tray minimieren / Beenden" -ForegroundColor DarkGray
        Write-Host ""

        $wahl = Read-SysPilotChoice 'Auswahl'
        switch ($wahl) {
            '1'  { Start-SysPilotAutopilot; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
            '2'  { Start-SysPilotCoolMode; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
            '3'  { Start-SysPilotPerfMode; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
            '4'  { Invoke-SysPilotFreeRam; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
            '5'  { Show-SysPilotStartupManager; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
            '6'  { Show-SysPilotBloatManager; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
            '7'  { Show-SysPilotOptimizerManager; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
            '8'  { Invoke-SysPilotAutoOptimize; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
            '9'  { Show-SysPilotServiceTuner; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
            '10' { Show-SysPilotFeaturesMenu; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
            '11' { Show-SysPilotCleanupMenu; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
            '12' { Invoke-SysPilotFreeRam; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
            '13' { Set-SysPilotPriorities; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
            '14' { Show-SysPilotSettingsMenu; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
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
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            '16' { Restart-SysPilotElevated }
            '17' { Show-SysPilotHogs; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
            '18' { Show-SysPilotStats; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
            '19' { Show-SysPilotScriptsMenu; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
            '20' {
                $gui = Join-Path $script:Root 'SysPilot-GUI.ps1'
                if (Test-SysPilotAdmin) {
                    Start-Process powershell.exe -Verb RunAs -ArgumentList (ConvertTo-SysPilotArgString @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$gui))
                } else {
                    Start-Process powershell.exe -ArgumentList (ConvertTo-SysPilotArgString @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$gui))
                }
            }
            '21' { Show-SysPilotExtensionManager; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
            '22' { Show-SysPilotNetworkRepair; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
            '23' { Show-SysPilotNetworkAdapters; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
            '24' { Show-SysPilotCheckup; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
            '25' { Show-SysPilotToolbox; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
            '26' { Show-SysPilotHealthDashboard; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
            '27' { Show-SysPilotDnsWindow; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
            '28' { $q = Read-SysPilotChoice 'KI-Suche (Begriff)' 'SysPilot DNS Manager'; Start-Process 'https://duckduckgo.com/?q=' + [Uri]::EscapeDataString($q); Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
            '0'  { Close-SysPilotToTray; return }
        }
    }
}

# =======================================================================
# NEU: Advanced DNS Manager (Show-SysPilotDnsWindow)
# =======================================================================
function Show-SysPilotDnsWindow {
    <# Öffnet den Advanced DNS Manager: Adapter wählen, Provider testen, DNS setzen, Cache prüfen #>
    while ($true) {
        Write-Host ""
        Write-Host "  ╔════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host "  ║         ADVANCED DNS MANAGER                            ║" -ForegroundColor Cyan
        Write-Host "  ║         DNS-Adapter · Provider · Cache · Lookup         ║" -ForegroundColor Cyan
        Write-Host "  ╚════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
        Write-Host ""

        $adapters = @(Get-SysPilotDnsAdapters)
        $items = @()
        foreach ($a in $adapters) {
            $items += @{ Label = "$($a.Name)  [$($a.Status)]  DNS: $($a.DnsServers)"; Color = 'White'; Tag = $a }
        }
        $items += @{ Label = 'DNS-Provider testen (Latenzvergleich)'; Color = 'Yellow'; Tag = 'TEST' }
        $items += @{ Label = 'DNS-Cache anzeigen'; Color = 'Yellow'; Tag = 'CACHE' }
        $items += @{ Label = 'DNS-Cache leeren (flush)'; Color = 'Yellow'; Tag = 'FLUSH' }
        $items += @{ Label = 'DNS-Lookup (Domain → IP)'; Color = 'Cyan'; Tag = 'LOOKUP' }
        $items += @{ Label = 'Reverse-DNS (IP → Domain)'; Color = 'Cyan'; Tag = 'REVERSE' }
        $items += @{ Label = 'DNS-Historie anzeigen'; Color = 'DarkGray'; Tag = 'HISTORY' }
        $items += @{ Label = 'Zurück'; Color = 'DarkGray'; Tag = $null }

        $sel = Show-SysPilotArrowMenu -Items $items -Title 'Advanced DNS Manager' -Footer 'Pfeiltasten, Enter = ausführen, Esc = zurück'
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
                Write-Host "  Ergebnis für $domain (Server: $($r.Server))" -ForegroundColor Cyan
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
                Write-Host "  Reverse-DNS für $ip (Server: $($r.Server))" -ForegroundColor Cyan
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

        # Adapter ausgewählt: DNS setzen
        $adapter = $sel
        Write-Host ""
        Write-Host "  Adapter: $($adapter.Name)  (aktuell: $($adapter.DnsServers))" -ForegroundColor Cyan
        Write-Host ""
        $provItems = @()
        foreach ($key in $script:DnsProviders.Keys) {
            $p = $script:DnsProviders[$key]
            $provItems += @{ Label = "$($p.Name)  —  $($p.Beschreibung)"; Color = 'White'; Tag = $key }
        }
        $provItems += @{ Label = 'Eigene DNS-Server eintragen'; Color = 'Yellow'; Tag = 'CUSTOM' }
        $provItems += @{ Label = 'Auf DHCP/Automatisch zurücksetzen'; Color = 'Yellow'; Tag = 'DHCP' }
        $provItems += @{ Label = 'Abbrechen'; Color = 'DarkGray'; Tag = $null }

        $provSel = Show-SysPilotArrowMenu -Items $provItems -Title 'DNS-Anbieter wählen' -Footer 'Enter = übernehmen, Esc = abbrechen'
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
            if (Confirm-SysPilot 'DNS auf Automatisch (DHCP) zurücksetzen?') {
                if (Reset-SysPilotDnsToDhcp -InterfaceIndex $adapter.ifIndex) {
                    Write-Host '  [OK] DNS auf DHCP zurückgesetzt.' -ForegroundColor Green
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
    <# Öffnet das Smart Health Monitor Dashboard: Hardware-Überwachung, Warnungen, KI-Ursachen, Reparatur-Howtos #>
    while ($true) {
        Write-Host ""
        Write-Host "  ╔════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host "  ║         SMART HEALTH MONITOR                            ║" -ForegroundColor Cyan
        Write-Host "  ║         CPU · GPU · SSD · Lüfter · Temperatur · KI      ║" -ForegroundColor Cyan
        Write-Host "  ╚════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
        Write-Host ""

        $health = Invoke-SysPilotHealthCheck
        $symbol = Get-SysPilotHealthSymbol -Modus $health.Modus

        Write-Host "  Status: $($symbol.Symbol)  $($symbol.Text)  ($($health.Modus))" -ForegroundColor $symbol.Farbe
        Write-Host "  Letzte Prüfung: $($health.Zeit)" -ForegroundColor DarkGray
        Write-Host ""

        if ($health.CpuTemp) { Write-Host "  CPU-Temperatur: $($health.CpuTemp)°C" -ForegroundColor $(if ($health.CpuTemp -ge 85) { 'Red' } elseif ($health.CpuTemp -ge 75) { 'Yellow' } else { 'Green' }) }
        if ($health.GpuTemp) { Write-Host "  GPU-Temperatur: $($health.GpuTemp)°C" -ForegroundColor $(if ($health.GpuTemp -ge 85) { 'Red' } elseif ($health.GpuTemp -ge 75) { 'Yellow' } else { 'Green' }) }

        Write-Host ""
        if ($health.Warnungen.Count -gt 0) {
            Write-Host "  ⚠ WARNINGS / WARNUNGEN:" -ForegroundColor Yellow
            foreach ($w in $health.Warnungen) {
                $farbe = if ($w.Schweregrad -eq 'KRITISCH') { 'Red' } else { 'Yellow' }
                Write-Host "    [$($w.Schweregrad)] $($w.Text)" -ForegroundColor $farbe
            }
        } else {
            Write-Host "  ✓ Alle Werte im Normalbereich." -ForegroundColor Green
        }

        Write-Host ""
        $items = @()
        $items += @{ Label = 'KI-Ursachenanalyse + Reparatur-Howtos'; Color = 'Cyan'; Tag = 'URSACHEN' }
        $items += @{ Label = 'Online Reparatur-Howtos (KI-Recherche)'; Color = 'Cyan'; Tag = 'ONLINEHOWTOS' }
        $items += @{ Label = 'Nahegelegene Reparaturlaeden (KI + Standort)'; Color = 'Cyan'; Tag = 'REPARATUR' }
        $items += @{ Label = 'Ersatzteil-Empfehlungen'; Color = 'Cyan'; Tag = 'ERSETZTEILE' }
        $items += @{ Label = 'SSD Health (SMART) anzeigen'; Color = 'Yellow'; Tag = 'SSD' }
        $items += @{ Label = 'Lüfter-Details anzeigen'; Color = 'Yellow'; Tag = 'FANS' }
        $items += @{ Label = 'Alle Sensoren (LibreHardwareMonitor)'; Color = 'DarkGray'; Tag = 'SENSOREN' }
        $items += @{ Label = 'LibreHardwareMonitor installieren'; Color = 'Yellow'; Tag = 'LHM' }
        $items += @{ Label = 'Zurück'; Color = 'DarkGray'; Tag = $null }

        $sel = Show-SysPilotArrowMenu -Items $items -Title 'Smart Health Monitor' -Footer 'Enter = ausführen, Esc = zurück'
        if ($null -eq $sel) { return }

        if ($sel -eq 'URSACHEN') {
            Write-Host ""
            if ($health.Warnungen.Count -eq 0) {
                Write-Host '  Keine Warnungen - keine Ursachenanalyse nötig.' -ForegroundColor Green
            } else {
                foreach ($w in $health.Warnungen) {
                    Write-Host ""
                    Write-Host "  === $($w.Komponente): $($w.Text) ===" -ForegroundColor Cyan
                    $urs = Get-SysPilotHealthUrsachen -Komponente $w.Komponente -Wert $w.Wert -Einheit $w.Einheit
                    if ($urs.Ursachen.Count -gt 0) {
                        Write-Host '  Mögliche Ursachen:' -ForegroundColor DarkGray
                        $urs.Ursachen | ForEach-Object { Write-Host "    • $_" -ForegroundColor DarkGray }
                    }
                    if ($urs.HowTos.Count -gt 0) {
                        Write-Host '  Reparatur-Howtos:' -ForegroundColor DarkGray
                        foreach ($h in $urs.HowTos) {
                            Write-Host "    🔧 $($h.Titel) ($($h.Schwierigkeit), ~$($h.ZeitMin) Min)" -ForegroundColor DarkGray
                            Write-Host "       $($h.Beschreibung)" -ForegroundColor DarkGray
                        }
                    }
                    $teile = Get-SysPilotErsatzteile -Komponente $w.Komponente
                    if ($teile.Count -gt 0) {
                        Write-Host '  Ersatzteile:' -ForegroundColor DarkGray
                        $teile | ForEach-Object { Write-Host "    🛒 $($_.Produkt) — $($_.Zweck) (~$($_.GeschätztePreis))" -ForegroundColor DarkGray }
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
                    Write-Host "  🔧 $($h.Titel)" -ForegroundColor Cyan
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
                Write-Host "  🏪 $($s.Name)" -ForegroundColor Yellow
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
            $kompItems += @{ Label = 'Lüfter'; Tag = 'Lüfter' }
            $kompItems += @{ Label = 'Zurück'; Tag = $null }
            $k = Show-SysPilotArrowMenu -Items $kompItems -Title 'Ersatzteil-Empfehlungen'
            if ($k) {
                $teile = Get-SysPilotErsatzteile -Komponente $k
                Write-Host ""
                $teile | ForEach-Object {
                    Write-Host "    🛒 $($_.Produkt)" -ForegroundColor DarkGray
                    Write-Host "       Zweck: $($_.Zweck)  |  Preis: $($_.GeschätztePreis)" -ForegroundColor DarkGray
                }
            }
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            continue
        }

        if ($sel -eq 'SSD') {
            Write-Host ""
            $ssds = @(Get-SysPilotSsdHealth)
            if ($ssds.Count -eq 0) {
                Write-Host '  Keine SSD-Informationen verfügbar.' -ForegroundColor DarkGray
            } else {
                $ssds | ForEach-Object {
                    Write-Host "    $($_.Name)  ($($_.Typ))  Gesundheit: $($_.Gesundheit)  $($_.GrößeGB) GB" -ForegroundColor $(if ($_.Gesundheit -ne 'Gesund') { 'Red' } else { 'Green' })
                }
            }
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            continue
        }

        if ($sel -eq 'FANS') {
            Write-Host ""
            $fans = @(Get-SysPilotFanSpeeds)
            if ($fans.Count -eq 0) {
                Write-Host '  Keine Lüfter-Informationen verfügbar (LibreHardwareMonitor nötig).' -ForegroundColor DarkGray
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
                Write-Host '  Keine Sensor-Daten verfügbar. Installiere LibreHardwareMonitor.' -ForegroundColor DarkGray
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
                    Write-Host '  Install-SysPilotLHM nicht verfügbar (Temperature-Modul geladen?).' -ForegroundColor Yellow
                }
            }
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            continue
        }
    }
}

Show-SysPilotMenu
