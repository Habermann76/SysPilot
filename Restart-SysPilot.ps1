# SysPilot-Neustart: beendet alle laufenden SysPilot-Prozesse und startet die GUI neu.
# Aufruf ueber die Verknuepfung "SysPilot Neustart" (Desktop/Startmenue).
# Hinweis: elevated SysPilot-Instanzen sind ohne Adminrechte nicht per
# CommandLine erkennbar - deshalb Mutex-Test + Elevation als Fallback.

$ErrorActionPreference = 'SilentlyContinue'
$self = $PID

function Get-SysPilotProcesses {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
        Where-Object {
            $_.ProcessId -ne $self -and
            $_.CommandLine -match 'SysPilot(-GUI)?\.ps1' -and
            $_.CommandLine -notmatch 'Restart-SysPilot|stop-syspilot'
        }
}

function Stop-SysPilotProcesses {
    foreach ($p in @(Get-SysPilotProcesses)) {
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop } catch { }
    }
}

# True, wenn der Single-Instance-Mutex der GUI frei ist (kein unsichtbarer Rest)
function Test-SysPilotGuiMutexFree {
    $m = $null
    try {
        $m = New-Object System.Threading.Mutex($false, 'Local\SysPilotGUI-SingleInstance')
        if ($m.WaitOne(0)) { $m.ReleaseMutex() | Out-Null; return $true }
        return $false
    } catch { return $true }   # Mutex nicht pruefbar -> nicht blockieren
    finally { if ($m) { $m.Dispose() } }
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    # Ohne Admin nur die sichtbaren Prozesse killbar - Rest pruefen
    Stop-SysPilotProcesses
    Start-Sleep -Milliseconds 700
    $blocked = (@(Get-SysPilotProcesses).Count -gt 0) -or (-not (Test-SysPilotGuiMutexFree))
    if ($blocked) {
        # Elevated Reste (z.B. SysPilot-GUI im Tray) blockieren den Neustart -> UAC
        Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',"`"$PSCommandPath`""
        exit
    }
} else {
    Stop-SysPilotProcesses
}

# Aufraeumen + warten, bis der GUI-Mutex frei ist (alte Instanz braucht einen Moment)
Start-Sleep -Milliseconds 500
for ($i = 0; $i -lt 20 -and -not (Test-SysPilotGuiMutexFree); $i++) { Start-Sleep -Milliseconds 300 }

# GUI neu starten (gleicher Aufruf wie die Desktop-Verknuepfung)
$gui = Join-Path $PSScriptRoot 'SysPilot-GUI.ps1'
if (Test-Path $gui) {
    Start-Process powershell.exe -ArgumentList '-STA','-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',"`"$gui`""
}
