# SysPilot - Memory: RAM freigeben (ehrlich, mit Messung statt Cleaner-Magie)
#Requires -Version 5.1

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class SysPilotMem {
    [DllImport("psapi.dll", SetLastError=true)]
    public static extern bool EmptyWorkingSet(IntPtr hProcess);
    [DllImport("ntdll.dll")]
    public static extern int NtSetSystemInformation(int SystemInformationClass, IntPtr SystemInformation, int SystemInformationLength);
}
"@ -ErrorAction SilentlyContinue

function Get-SysPilotMemoryInfo {
    $os = Get-CimInstance Win32_OperatingSystem
    $perf = Get-CimInstance Win32_PerfRawData_PerfOS_Memory -ErrorAction SilentlyContinue
    $standbyBytes = 0
    if ($perf) {
        $standbyBytes = [double]$perf.StandbyCacheCoreBytes + [double]$perf.StandbyCacheNormalPriorityBytes + [double]$perf.StandbyCacheReserveBytes
    }
    [PSCustomObject]@{
        TotalGB   = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
        FreeGB    = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
        UsedPct   = [math]::Round(100 * ($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize)
        StandbyMB = [math]::Round($standbyBytes / 1MB)
    }
}

function Clear-SysPilotWorkingSets {
    <# Verkleinert die Arbeitsseiten aller Prozesse (auslagerbarer RAM wird frei) #>
    $cfg = Get-SysPilotConfig
    $freed = 0; $ok = 0; $fail = 0
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
        if (Test-NameMatch -Name $p.ProcessName -Patterns $cfg.NeverTouch) { continue }
        if ($p.Id -eq $PID) { continue }
        try {
            $before = $p.WorkingSet64
            if ([SysPilotMem]::EmptyWorkingSet($p.Handle)) {
                $p.Refresh()
                $after = $p.WorkingSet64
                if ($before -gt $after) { $freed += ($before - $after) }
                $ok++
            } else { $fail++ }
        } catch { $fail++ }
    }
    [PSCustomObject]@{ FreedMB = [math]::Round($freed / 1MB); Trimmed = $ok; Skipped = $fail }
}

function Clear-SysPilotStandbyList {
    <# Leert den Standby-Cache (wie EmptyStandbyList.exe). Braucht Admin. #>
    if (-not (Test-SysPilotAdmin)) { return $null }
    $ptr = [Runtime.InteropServices.Marshal]::AllocHGlobal(4)
    try {
        [Runtime.InteropServices.Marshal]::WriteInt32($ptr, 4)   # MemoryPurgeStandbyList
        $status = [SysPilotMem]::NtSetSystemInformation(80, $ptr, 4)  # SystemMemoryListInformation
        return ($status -eq 0)
    } finally {
        [Runtime.InteropServices.Marshal]::FreeHGlobal($ptr)
    }
}

function Invoke-SysPilotFreeRam {
    Write-SysPilotHeader "RAM freigeben"
    $before = Get-SysPilotMemoryInfo
    Write-Host ("  Vorher:  {0} GB frei von {1} GB ({2}% belegt) | Standby-Cache: {3} MB" -f $before.FreeGB, $before.TotalGB, $before.UsedPct, $before.StandbyMB)
    Write-Host ""

    Write-Host "  Schritt 1: Arbeitsseiten aller Prozesse verkleinern ..." -ForegroundColor Cyan
    $ws = Clear-SysPilotWorkingSets
    Write-Host ("  [OK] {0} Prozesse verkleinert ({1} MB), {2} ohne Zugriff" -f $ws.Trimmed, $ws.FreedMB, $ws.Skipped) -ForegroundColor Green

    if (Test-SysPilotAdmin) {
        Write-Host "  Schritt 2: Standby-Cache leeren ..." -ForegroundColor Cyan
        if (Clear-SysPilotStandbyList) {
            Write-Host "  [OK] Standby-Cache geleert." -ForegroundColor Green
        } else {
            Write-Host "  [!] Standby-Cache konnte nicht geleert werden." -ForegroundColor Yellow
        }
    } else {
        Write-Host "  Schritt 2: Standby-Cache -> uebersprungen (braucht Admin, Menue 15)" -ForegroundColor DarkYellow
    }

    Start-Sleep -Milliseconds 500
    $after = Get-SysPilotMemoryInfo
    $deltaMB = [math]::Round(($after.FreeGB - $before.FreeGB) * 1024)
    Write-Host ""
    Write-Host ("  Nachher: {0} GB frei ({1}% belegt) | Standby-Cache: {2} MB" -f $after.FreeGB, $after.UsedPct, $after.StandbyMB)
    if ($deltaMB -gt 0) {
        Write-Host "  => $deltaMB MB mehr frei" -ForegroundColor Green
    } else {
        Write-Host "  => Kein nennenswerter Gewinn (Windows hatte schon aufgeraeumt)" -ForegroundColor DarkGray
    }
    Write-SysPilotLog ("RAM freigegeben: WorkingSets {0} MB, Standby geleert: {1}, frei vorher/nachher: {2}/{3} GB" -f $ws.FreedMB, (Test-SysPilotAdmin), $before.FreeGB, $after.FreeGB)

    Write-Host ""
    Write-Host "  Ehrlicher Hinweis: Windows fuellt freien RAM als Cache wieder auf - normal und gut so." -ForegroundColor DarkGray
    Write-Host "  DAUERHAFT mehr RAM gibt es nur durch: Programme schliessen, Autostart reduzieren (Menue 5)," -ForegroundColor DarkGray
    Write-Host "  Bloatware deinstallieren (Menue 6/7). Deine groessten Verbraucher gerade:" -ForegroundColor DarkGray
    Get-Process | Group-Object ProcessName | ForEach-Object {
        [PSCustomObject]@{ Programm = $_.Name; Instanzen = $_.Count; RAM_MB = [math]::Round(($_.Group | Measure-Object WorkingSet64 -Sum).Sum / 1MB) }
    } | Sort-Object RAM_MB -Descending | Select-Object -First 6 | Format-Table -AutoSize
}

Export-ModuleMember -Function Get-SysPilotMemoryInfo, Clear-SysPilotWorkingSets, Clear-SysPilotStandbyList, Invoke-SysPilotFreeRam
