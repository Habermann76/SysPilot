# SysPilot - Insights: Ressourcen-Fresser erkennen, Statistiken, Massnahmen
#Requires -Version 5.1

function Get-SysPilotHogs {
    <# Findet RAM- und CPU-Fresser, gruppiert nach Programm-Familie, mit Massnahme #>
    $cfg = (Get-SysPilotConfig).Hogs
    $ramWarn = [int]$cfg.RamWarnMB
    $cpuWarn = [int]$cfg.CpuWarnSeconds

    $groups = Get-Process -ErrorAction SilentlyContinue | Group-Object ProcessName
    $rows = @()
    foreach ($g in $groups) {
        $ramMB = [math]::Round((($g.Group | Measure-Object WorkingSet64 -Sum).Sum) / 1MB)
        $cpuS = [math]::Round((($g.Group | Measure-Object CPU -Sum).Sum))
        $name = $g.Name

        $known = $null
        foreach ($h in $cfg.KnownHogs) {
            if ($name -like "*$($h.Name)*" -or $h.Name -like "*$name*") { $known = $h; break }
        }

        $isHog = ($ramMB -ge $ramWarn) -or ($cpuS -ge $cpuWarn) -or ($null -ne $known)
        if (-not $isHog) { continue }

        $rows += [PSCustomObject]@{
            Programm  = $name
            Instanzen = $g.Count
            RAM_MB    = $ramMB
            CPU_s     = $cpuS
            Warum     = if ($known) { $known.Why } else { '' }
            Massnahme = if ($known) { $known.Fix } else { 'Pruefen ob dauerhaft noetig' }
            HowTo     = if ($known -and $known.HowTo) { $known.HowTo } else { '' }
            Link      = if ($known -and $known.Link) { $known.Link } else { '' }
            Action    = if ($known -and $known.Action) { $known.Action } else { '' }
        }
    }
    return ($rows | Sort-Object RAM_MB -Descending)
}

function Show-SysPilotHogs {
    while ($true) {
        $hogs = @(Get-SysPilotHogs)
        if ($hogs.Count -eq 0) {
            Write-SysPilotHeader "Ressourcen-Fresser & Massnahmen"
            Write-Host "  Keine Auffaelligkeiten - System laeuft schlank." -ForegroundColor Green
            Read-SysPilotChoice "Weiter mit Enter" | Out-Null
            return
        }
        $items = @()
        foreach ($h in $hogs) {
            $color = if ($h.Massnahme -match 'DEINSTALLIEREN') { 'Red' } elseif ($h.RAM_MB -ge 800) { 'Yellow' } else { 'White' }
            $label = "{0,-24} {1,5} MB RAM  {2,5}s CPU  ({3}x)" -f $h.Programm, $h.RAM_MB, $h.CPU_s, $h.Instanzen
            $items += @{ Label = $label; Color = $color; Tag = $h }
        }
        $items += @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = $null }

        $sel = Show-SysPilotArrowMenu -Items $items -Title 'Ressourcen-Fresser & Massnahmen' -Footer 'Pfeiltasten, Enter = Details + Howto, Esc = zurueck'
        if ($null -eq $sel) { return }

        $hog = $sel
        Write-SysPilotHeader $hog.Programm
        Write-Host ("  RAM: {0} MB  |  CPU: {1}s  |  Instanzen: {2}" -f $hog.RAM_MB, $hog.CPU_s, $hog.Instanzen) -ForegroundColor Cyan
        Write-Host ""
        if ($hog.Warum)     { Write-Host "  Warum:     $($hog.Warum)" -ForegroundColor Yellow }
        if ($hog.Massnahme) { Write-Host "  Massnahme: $($hog.Massnahme)" -ForegroundColor Magenta }

        # Einfache Aktion? -> direkt ausfuehren (Ja/Nein)
        if ($hog.Action) {
            Write-Host ""
            $actionText = switch ($hog.Action) {
                'DisableStartup' { "Autostart deaktivieren" }
                'Uninstall'      { "Programm deinstallieren" }
                'DisableService' { "Dienst auf Manuell stellen" }
                'WslShutdown'    { "WSL/Docker herunterfahren (gibt RAM frei)" }
                default { $hog.Action }
            }
            if (Confirm-SysPilot "Soll SysPilot das jetzt fuer dich tun? ($actionText)") {
                Invoke-SysPilotHogAction -Hog $hog
            }
        }

        # Howto + 3 Links (offiziell + Google + KI-Suche)
        if ($hog.HowTo) {
            Write-Host ""
            Write-Host "  Wie geht das? (Howto):" -ForegroundColor Green
            $hog.HowTo -split '\. ' | ForEach-Object { Write-Host "    - $_" -ForegroundColor White }
        }
        Write-Host ""
        Write-Host "  Anleitungen:" -ForegroundColor Cyan
        $linkItems = @()
        if ($hog.Link) {
            $linkItems += @{ Label = "Offizielle Anleitung (Hersteller/Microsoft)"; Color = 'White'; Tag = $hog.Link }
        }
        $linkItems += @{ Label = "Google-Suche: '$($hog.Programm) Howto'"; Color = 'White'; Tag = "https://www.google.com/search?q=$($hog.Programm)+howto+deutsch" }
        $linkItems += @{ Label = "KI-Suche (Gemini): '$($hog.Programm) optimieren'"; Color = 'White'; Tag = "https://gemini.google.com/app?q=$($hog.Programm)+optimieren+howto+deutsch" }
        $linkItems += @{ Label = "Funktion erbeten / Fehler melden (GitHub)"; Color = 'Yellow'; Tag = "https://github.com/Habermann76/SysPilot/issues/new" }
        $linkItems += @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = $null }

        $linkSel = Show-SysPilotArrowMenu -Items $linkItems -Title "Anleitung fuer $($hog.Programm)" -Footer 'Pfeiltasten, Enter = oeffnen, Esc = zurueck'
        if ($linkSel) { Start-Process $linkSel }
    }
}

function Invoke-SysPilotHogAction {
    <# Fuehrt eine einfache Massnahme direkt aus #>
    param([Parameter(Mandatory)]$Hog)
    $name = $Hog.Programm
    switch ($Hog.Action) {
        'DisableStartup' {
            Set-SysPilotStartupItem -Name $name -Enable $false
        }
        'Uninstall' {
            $app = Get-SysPilotInstalled | Where-Object { $_.DisplayName -like "*$name*" } | Select-Object -First 1
            if ($app) { Uninstall-SysPilotProgram -App $app }
            else { Write-Host "  [!] '$name' nicht in der Programmliste gefunden." -ForegroundColor Yellow }
        }
        'DisableService' {
            $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
            if ($svc) {
                if (Assert-SysPilotAdmin) {
                    Set-Service -Name $name -StartupType Manual -ErrorAction SilentlyContinue
                    Write-Host "  [OK] Dienst '$name' auf Manuell gestellt." -ForegroundColor Green
                    Write-SysPilotLog "Dienst '$name' auf Manuell (via Fresser-Aktion)"
                }
            } else { Write-Host "  [!] Dienst '$name' nicht gefunden." -ForegroundColor Yellow }
        }
        'WslShutdown' {
            & wsl.exe --shutdown 2>$null
            Write-Host "  [OK] WSL/Docker heruntergefahren - RAM freigegeben." -ForegroundColor Green
            Write-SysPilotLog "WSL heruntergefahren (via Fresser-Aktion)"
        }
    }
}

function Write-SysPilotStatSample {
    <# Ein Statistik-Datensatz (fuer Autopilot oder manuell) #>
    $dir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'logs'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $file = Join-Path $dir 'stats.csv'

    $os = Get-CimInstance Win32_OperatingSystem
    $cpu = Get-CimInstance Win32_Processor
    $procs = Get-Process -ErrorAction SilentlyContinue
    $top = $procs | Sort-Object WorkingSet64 -Descending | Select-Object -First 1

    $row = [PSCustomObject]@{
        Zeit      = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        CPU_Pct   = $cpu.LoadPercentage
        RAM_Pct   = [math]::Round(100 * ($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize)
        RAM_FreiMB = [math]::Round($os.FreePhysicalMemory / 1KB)
        Prozesse  = $procs.Count
        TopProzess = $top.ProcessName
        TopRAM_MB = [math]::Round($top.WorkingSet64 / 1MB)
        Plan      = (Get-SysPilotActiveMode)
    }
    $exists = Test-Path $file
    $row | Export-Csv -Path $file -NoTypeInformation -Append -Encoding UTF8 -Delimiter ';'
}

function Show-SysPilotStats {
    Write-SysPilotHeader "Statistiken"
    $file = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'logs\stats.csv'

    # Aktuellen Schnappschuss speichern
    Write-SysPilotStatSample

    if (-not (Test-Path $file)) {
        Write-Host "  Noch keine Verlaufs-Daten. Der Autopilot sammelt sie automatisch." -ForegroundColor DarkGray
        return
    }
    $data = Import-Csv $file -Delimiter ';' -Encoding UTF8
    if ($data.Count -lt 2) {
        Write-Host "  Erster Datensatz gespeichert. Mehr Verlauf sammelt der Autopilot (Menue 3/4)." -ForegroundColor DarkGray
    }

    $cpuVals = $data | ForEach-Object { [double]$_.CPU_Pct }
    $ramVals = $data | ForEach-Object { [double]$_.RAM_Pct }
    Write-Host ("  Datensaetze: {0}  (erster: {1}, letzter: {2})" -f $data.Count, $data[0].Zeit, $data[-1].Zeit) -ForegroundColor Cyan
    Write-Host ""
    Write-Host ("  CPU-Last:    Schnitt {0,4:N0}%   Max {1,4:N0}%" -f ($cpuVals | Measure-Object -Average).Average, ($cpuVals | Measure-Object -Maximum).Maximum)
    Write-Host ("  RAM-Belegt:  Schnitt {0,4:N0}%   Max {1,4:N0}%" -f ($ramVals | Measure-Object -Average).Average, ($ramVals | Measure-Object -Maximum).Maximum)
    Write-Host ""

    # Haeufigste Top-Prozesse
    Write-Host "  Haeufigster RAM-Verbraucher im Verlauf:" -ForegroundColor Cyan
    $data | Group-Object TopProzess | Sort-Object Count -Descending | Select-Object -First 5 |
        ForEach-Object { Write-Host ("    {0,-24} {1,4}x Spitze" -f $_.Name, $_.Count) -ForegroundColor White }
    Write-Host ""

    # Letzte 10 Eintraege
    Write-Host "  Letzte Eintraege:" -ForegroundColor Cyan
    $data | Select-Object -Last 10 | Format-Table Zeit, CPU_Pct, RAM_Pct, RAM_FreiMB, Prozesse, TopProzess, Plan -AutoSize
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

Export-ModuleMember -Function Get-SysPilotHogs, Show-SysPilotHogs, Write-SysPilotStatSample, Show-SysPilotStats, Invoke-SysPilotHogAction, Show-SysPilotReport
