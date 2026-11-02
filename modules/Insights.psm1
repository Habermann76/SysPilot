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
        }
    }
    return ($rows | Sort-Object RAM_MB -Descending)
}

function Show-SysPilotHogs {
    Write-SysPilotHeader "Ressourcen-Fresser & Massnahmen"
    $hogs = Get-SysPilotHogs
    if ($hogs.Count -eq 0) {
        Write-Host "  Keine Auffaelligkeiten - System laeuft schlank." -ForegroundColor Green
        return
    }
    $i = 0
    foreach ($h in $hogs) {
        $i++
        $color = if ($h.Massnahme -match 'DEINSTALLIEREN') { 'Red' } elseif ($h.RAM_MB -ge 800) { 'Yellow' } else { 'White' }
        Write-Host ("  [{0,2}] {1,-24} {2,5} MB RAM  {3,5}s CPU  ({4}x)" -f $i, $h.Programm, $h.RAM_MB, $h.CPU_s, $h.Instanzen) -ForegroundColor $color
        if ($h.Warum)     { Write-Host ("       Warum:    $($h.Warum)") -ForegroundColor DarkGray }
        if ($h.Massnahme) { Write-Host ("       Massnahme: $($h.Massnahme)") -ForegroundColor DarkCyan }
    }
    Write-Host ""
    Write-Host "  Tipp: Viele davon laufen nur manchmal - Autostart aus (Menue 5) haelt sie fern," -ForegroundColor DarkGray
    Write-Host "  bis du sie wirklich brauchst. Statistik ueber Zeit: Menue 18." -ForegroundColor DarkGray
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

Export-ModuleMember -Function Get-SysPilotHogs, Show-SysPilotHogs, Write-SysPilotStatSample, Show-SysPilotStats
