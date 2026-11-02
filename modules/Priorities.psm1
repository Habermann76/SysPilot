# SysPilot - Priorities: Prozess-Prioritaeten (wichtige Apps bevorzugen, Ballast bremsen)
#Requires -Version 5.1

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class SysPilotFg {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
}
"@ -ErrorAction SilentlyContinue

function Get-SysPilotForegroundPid {
    try {
        $hwnd = [SysPilotFg]::GetForegroundWindow()
        if ($hwnd -eq [IntPtr]::Zero) { return 0 }
        $pidOut = 0
        [void][SysPilotFg]::GetWindowThreadProcessId($hwnd, [ref]$pidOut)
        return [int]$pidOut
    } catch { return 0 }
}

function Set-ProcessPrioritySafe {
    param([System.Diagnostics.Process]$Process, [string]$Priority)
    try {
        if ($Process.PriorityClass.ToString() -ne $Priority) {
            $Process.PriorityClass = $Priority
            return $true
        }
    } catch { }
    return $false
}

function Set-SysPilotPriorities {
    param([switch]$Quiet)
    $cfg = Get-SysPilotConfig
    $changed = @()

    $all = Get-Process -ErrorAction SilentlyContinue
    $fgPid = 0
    if ($cfg.BoostForegroundApp) { $fgPid = Get-SysPilotForegroundPid }

    foreach ($p in $all) {
        $name = $p.ProcessName
        if (Test-NameMatch -Name $name -Patterns $cfg.NeverTouch) { continue }

        $target = $null
        if (Test-NameMatch -Name $name -Patterns $cfg.GameProcesses) {
            $target = $cfg.GamePriority
        }
        elseif (Test-NameMatch -Name $name -Patterns $cfg.JunkProcesses) {
            $target = $cfg.JunkPriority
        }
        elseif (Test-NameMatch -Name $name -Patterns $cfg.ImportantProcesses) {
            $target = $cfg.ImportantPriority
        }
        elseif ($p.Id -eq $fgPid -and $p.Id -ne $PID) {
            # Vordergrund-App bekommt einen kleinen Schub (cleverer als starre Regeln)
            $target = $cfg.ImportantPriority
        }

        if ($target) {
            if (Set-ProcessPrioritySafe -Process $p -Priority $target) {
                $changed += "$name($($p.Id))->$target"
            }
        }
    }

    if ($changed.Count -gt 0) {
        Write-SysPilotLog ("Prioritaeten: " + ($changed -join ', '))
        if (-not $Quiet) {
            Write-Host "  [OK] $($changed.Count) Prozess-Prioritaeten angepasst:" -ForegroundColor Green
            $changed | ForEach-Object { Write-Host "       $_" -ForegroundColor DarkGreen }
        }
    }
    elseif (-not $Quiet) {
        Write-Host "  Alle Prioritaeten sind bereits korrekt gesetzt." -ForegroundColor DarkGray
    }
}

function Show-SysPilotPriorities {
    $cfg = Get-SysPilotConfig
    Write-SysPilotHeader "Prozess-Prioritaeten (live)"

    $all = Get-Process -ErrorAction SilentlyContinue
    $rows = @()
    foreach ($p in $all) {
        $name = $p.ProcessName
        if (Test-NameMatch -Name $name -Patterns $cfg.NeverTouch) { continue }
        $role = ""
        if (Test-NameMatch -Name $name -Patterns $cfg.GameProcesses) { $role = "SPIEL" }
        elseif (Test-NameMatch -Name $name -Patterns $cfg.ImportantProcesses) { $role = "wichtig" }
        elseif (Test-NameMatch -Name $name -Patterns $cfg.JunkProcesses) { $role = "Ballast" }
        if ($role) {
            $rows += [PSCustomObject]@{
                Rolle     = $role
                Prozess   = $name
                PID       = $p.Id
                Prioritaet = $p.PriorityClass.ToString()
                RAM_MB    = [math]::Round($p.WorkingSet64 / 1MB)
            }
        }
    }
    $rows | Sort-Object Rolle, RAM_MB -Descending | Format-Table -AutoSize
    Write-Host "  Legende: SPIEL=$($cfg.GamePriority) | wichtig=$($cfg.ImportantPriority) | Ballast=$($cfg.JunkPriority)" -ForegroundColor DarkGray
}

Export-ModuleMember -Function Set-SysPilotPriorities, Show-SysPilotPriorities, Get-SysPilotForegroundPid
