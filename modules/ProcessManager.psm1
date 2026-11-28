# =====================================================================
# ProcessManager.psm1 - Task-Manager fuer SysPilot
# Prozesse auflisten, beenden, starten, analysieren.
# Process Explorer (Sysinternals) portabel nachladbar.
# =====================================================================

function Get-SysPilotProcesses {
    <# Prozessliste mit Kern-Daten. Sortiert nach RAM (Default) oder CPU.
       Gibt Objekte mit Id, Name, CPU(s), RamMB, Pfad zurueck. #>
    param(
        [int]$Top = 60,
        [string]$Filter = '',
        [ValidateSet('ram','cpu','name')][string]$Sort = 'ram'
    )
    $procs = Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Id -gt 4 -and $_.ProcessName -notin @('Idle','System')
    }
    if ($Filter) {
        $procs = $procs | Where-Object {
            $_.ProcessName -like "*$Filter*" -or "$($_.Id)" -eq $Filter -or
            ($_.MainWindowTitle -and $_.MainWindowTitle -like "*$Filter*")
        }
    }
    $list = foreach ($p in $procs) {
        [pscustomobject]@{
            Id       = $p.Id
            Name     = $p.ProcessName
            CPU      = if ($null -ne $p.CPU) { [math]::Round($p.CPU,1) } else { 0 }
            RamMB    = [math]::Round($p.WorkingSet64/1MB)
            Path     = $p.Path
            Title    = $p.MainWindowTitle
            Session  = $p.SessionId
            Priority = [string]$p.PriorityClass
        }
    }
    $list = switch ($Sort) {
        'cpu'  { $list | Sort-Object CPU -Descending }
        'name' { $list | Sort-Object Name }
        default { $list | Sort-Object RamMB -Descending }
    }
    return @($list | Select-Object -First $Top)
}

function Show-SysPilotProcessTable {
    <# Tabellarische Prozessuebersicht (Top N). #>
    param([int]$Top = 40, [string]$Filter = '')
    $list = @(Get-SysPilotProcesses -Top $Top -Filter $Filter)
    if ($list.Count -eq 0) { Write-Host '  Keine Prozesse gefunden.' -ForegroundColor DarkGray; return }
    Write-Host ("`n  {0,-7} {1,-28} {2,10} {3,10}  {4}" -f 'PID','Name','CPU(s)','RAM(MB)','Fenstertitel') -ForegroundColor Cyan
    Write-Host ('  ' + ('-'*90)) -ForegroundColor DarkGray
    foreach ($p in $list) {
        $ttl = if ($p.Title) { $p.Title.Substring(0,[Math]::Min(30,$p.Title.Length)) } else { '' }
        Write-Host ("  {0,-7} {1,-28} {2,10} {3,10}  {4}" -f $p.Id,$p.Name,$p.CPU,$p.RamMB,$ttl)
    }
    Write-Host ("`n  {0} Prozesse (Top $Top)" -f $list.Count) -ForegroundColor DarkGray
}

function Stop-SysPilotProcessTree {
    <# Beendet einen Prozess inkl. Kindprozessen (optional). #>
    param([Parameter(Mandatory)][int]$Id, [switch]$Force)
    $p = Get-Process -Id $Id -ErrorAction SilentlyContinue
    if (-not $p) { Write-Host "  Prozess $Id existiert nicht mehr." -ForegroundColor DarkGray; return $false }
    $kids = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$Id" -ErrorAction SilentlyContinue)
    foreach ($k in $kids) { Stop-Process -Id $k.ProcessId -Force -ErrorAction SilentlyContinue }
    try {
        Stop-Process -Id $Id -Force:$Force -ErrorAction Stop
        Write-Host "  [OK] '$($p.ProcessName)' (PID $Id) beendet$($(if($kids.Count){", $($kids.Count) Kindprozesse"}))" -ForegroundColor Green
        Write-SysPilotLog "Prozess beendet: $($p.ProcessName) (PID $Id)"
        return $true
    } catch {
        Write-Host "  [!] Beenden fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Start-SysPilotProcessPick {
    <# Startet ein Programm: per Dateidialog oder per Name/Pfad. #>
    Write-Host "`n  Programm starten:" -ForegroundColor Cyan
    Write-Host "  1) Programm per Dateidialog waehlen (.exe)" -ForegroundColor White
    Write-Host "  2) Programmname/-pfad eingeben (z.B. notepad, C:\pfad\app.exe)" -ForegroundColor White
    Write-Host "  0) Abbrechen" -ForegroundColor DarkGray
    $c = Read-SysPilotChoice 'Auswahl'
    if ($c -eq '0' -or -not $c) { return }
    $path = $null
    if ($c -eq '1') {
        Add-Type -AssemblyName System.Windows.Forms
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = 'Programme (*.exe;*.lnk;*.bat;*.cmd)|*.exe;*.lnk;*.bat;*.cmd|Alle Dateien (*.*)|*.*'
        $dlg.Title = 'Programm waehlen'
        if ($dlg.ShowDialog() -ne 'OK') { return }
        $path = $dlg.FileName
    } else {
        $path = (Read-SysPilotInput 'Programmname oder Pfad' -BrowseFile).Trim('"')
        if (-not $path) { return }
        if ($path -notmatch '[\\/]' -and $path -notmatch '\.(exe|lnk|bat|cmd)$') {
            # Name -> im PATH suchen
            $cmd = Get-Command $path -ErrorAction SilentlyContinue
            if ($cmd) { $path = $cmd.Source } else {
                $path = "$env:WINDIR\System32\$path.exe"
                if (-not (Test-Path $path)) { Write-Host "  [!] '$path' nicht gefunden." -ForegroundColor Red; return }
            }
        }
        if (-not (Test-Path $path)) {
            Write-Host "  [!] Pfad nicht gefunden: $path" -ForegroundColor Red
            return
        }
    }
    try {
        Start-Process $path
        Write-Host "  [OK] Gestartet: $path" -ForegroundColor Green
        Write-SysPilotLog "Prozess gestartet: $path"
    } catch {
        Write-Host "  [!] Start fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Red
    }
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
}

function Test-SysPilotExeIntegrity {
    <# Prueft grob, ob eine EXE vollstaendig ist: MZ-Header + Mindestgroesse.
       Faengt grob abgebrochene Downloads ab. Fuer exakte Pruefung
       zusaetzlich -ExpectedSize (Remote-Content-Length) nutzen. #>
    param([Parameter(Mandatory)][string]$Path, [long]$MinSize = 1MB, [long]$ExpectedSize = 0)
    try {
        $fi = Get-Item $Path -ErrorAction Stop
        if ($fi.Length -lt $MinSize) { return $false }
        if ($ExpectedSize -gt 0 -and $fi.Length -ne $ExpectedSize) { return $false }
        $fs = [IO.File]::OpenRead($Path)
        try {
            $b = New-Object byte[] 2
            [void]$fs.Read($b, 0, 2)
            return ($b[0] -eq 0x4D -and $b[1] -eq 0x5A)   # 'MZ'
        } finally { $fs.Close() }
    } catch { return $false }
}

function Get-SysPilotProcessExplorer {
    <# Process Explorer portabel bereitstellen (live.sysinternals.com,
       offizieller Microsoft-Download). Gibt EXE-Pfad zurueck.
       Beschaedigte/unvollstaendige Downloads werden per Remote-Groessen-
       abgleich erkannt, geloescht und einmal neu geholt. #>
    $dir = Join-Path (Get-SysPilotPortableAppsDir) 'ProcessExplorer'
    $exe = Join-Path $dir 'procexp64.exe'
    $url = 'https://live.sysinternals.com/procexp64.exe'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    # Erwartete Groesse per HEAD (Content-Length) - live.sysinternals liefert sie
    $expected = 0L
    try {
        $req = [Net.HttpWebRequest]::Create($url)
        $req.Method = 'HEAD'; $req.Timeout = 10000; $req.UserAgent = 'SysPilot/0.9'
        $resp = $req.GetResponse()
        try { $cl = $resp.Headers['Content-Length']; if ($cl) { $expected = [long]$cl } } finally { $resp.Close() }
    } catch {}
    $valid = { param($p) Test-SysPilotExeIntegrity -Path $p -MinSize 2MB -ExpectedSize $expected }
    for ($try = 0; $try -lt 2; $try++) {
        if ((Test-Path $exe) -and (& $valid $exe)) { return $exe }
        if (Test-Path $exe) {
            Write-Host '  Vorhandene procexp64.exe ist unvollstaendig/korrupt - wird neu geladen.' -ForegroundColor Yellow
            Remove-Item $exe -Force -ErrorAction SilentlyContinue
        }
        Write-Host '  Process Explorer wird heruntergeladen (procexp64.exe, ~2,5 MB) ...' -ForegroundColor Cyan
        $ok = Invoke-SysPilotFileDownload -Url $url -OutFile $exe -Label 'Process Explorer' -TimeoutSec 120 -Title 'Process Explorer'
        if ($ok -and (Test-Path $exe) -and (& $valid $exe)) { return $exe }
        Write-Host '  [!] Download unvollstaendig - ein Versuch bleibt.' -ForegroundColor DarkYellow
    }
    Write-Host '  [!] Download fehlgeschlagen.' -ForegroundColor Red
    return $null
}

function Set-SysPilotProcessPriority {
    <# Setzt die Prioritaet eines Prozesses (PriorityClass).
       High/Realtime erfordern Adminrechte - Fehler wird sauber
       zurueckgegeben. Realtime nur mit Bedacht nutzen! #>
    param(
        [Parameter(Mandatory)][int]$Id,
        [Parameter(Mandatory)]
        [ValidateSet('Idle','BelowNormal','Normal','AboveNormal','High','Realtime')]
        [string]$Priority
    )
    $p = Get-Process -Id $Id -ErrorAction SilentlyContinue
    if (-not $p) { return @{ Ok=$false; Error="Prozess $Id nicht gefunden." } }
    try {
        $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::$Priority
        Write-SysPilotLog "Prioritaet: $($p.ProcessName) ($Id) -> $Priority"
        return @{ Ok=$true; Priority=$Priority }
    } catch {
        return @{ Ok=$false; Error=$_.Exception.Message }
    }
}

function Show-SysPilotProcessDetails {
    <# Tiefe Analyse eines Prozesses: Signatur, Parent, Kinder,
       Threads, Handles, Netzwerk-Verbindungen. #>
    param([Parameter(Mandatory)][int]$Id)
    $p = Get-Process -Id $Id -ErrorAction SilentlyContinue
    if (-not $p) { Write-Host "  Prozess $Id nicht gefunden." -ForegroundColor DarkGray; return }
    Write-Host "`n  === Prozess-Details: $($p.ProcessName) (PID $Id) ===" -ForegroundColor Cyan
    Write-Host "  Pfad:      $($p.Path)"
    Write-Host "  Start:     $(if($p.StartTime){$p.StartTime}else{'?'})"
    Write-Host "  CPU gesamt:$([math]::Round($p.CPU,1))s | Threads: $($p.Threads.Count) | Handles: $($p.HandleCount)"
    Write-Host "  RAM:       $([math]::Round($p.WorkingSet64/1MB)) MB (privat $([math]::Round($p.PrivateMemorySize64/1MB)) MB)"
    Write-Host "  Fenster:   '$($p.MainWindowTitle)' | Antwortet: $($p.Responding)"
    # Signatur
    if ($p.Path -and (Test-Path $p.Path)) {
        try {
            $sig = Get-AuthenticodeSignature $p.Path -ErrorAction Stop
            $signer = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { '-' }
            Write-Host "  Signatur:  $($sig.Status) | $signer" -ForegroundColor $(if($sig.Status -eq 'Valid'){'Green'}else{'Yellow'})
        } catch { Write-Host "  Signatur:  nicht pruefbar ($($_.Exception.Message))" -ForegroundColor DarkGray }
    }
    # Parent + Kinder
    try {
        $wmi = Get-CimInstance Win32_Process -Filter "ProcessId=$Id" -ErrorAction Stop
        if ($wmi) {
            $parent = Get-Process -Id $wmi.ParentProcessId -ErrorAction SilentlyContinue
            Write-Host "  Parent:    $(if($parent){"$($parent.ProcessName) (PID $($wmi.ParentProcessId))"}else{"PID $($wmi.ParentProcessId) (beendet?)"})"
            Write-Host "  Kommando:  $($wmi.CommandLine)"
            $kids = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$Id" -ErrorAction SilentlyContinue)
            if ($kids.Count) { Write-Host ("  Kinder:    " + (($kids | ForEach-Object { "$($_.Name)($($_.ProcessId))" }) -join ', ')) }
        }
    } catch {}
    # Netzwerk
    try {
        $conns = @(Get-NetTCPConnection -OwningProcess $Id -ErrorAction SilentlyContinue | Where-Object { $_.State -ne 'Listen' } | Select-Object -First 8)
        if ($conns.Count) {
            Write-Host "  Netzwerk:" -ForegroundColor Cyan
            foreach ($c in $conns) {
                $r = if ($c.RemoteAddress -and $c.RemoteAddress -ne '0.0.0.0' -and $c.RemoteAddress -ne '::') { "$($c.RemoteAddress):$($c.RemotePort)" } else { 'lauscht' }
                Write-Host ("    {0} {1}:{2} -> {3} [{4}]" -f $c.State, $c.LocalAddress, $c.LocalPort, $r, $c.OwningProcess)
            }
        }
    } catch {}
    # DLLs/Module (nur eigene Prozesse lesbar)
    try { Write-Host "  Module:    $($p.Modules.Count) geladen" } catch {}
}

function Invoke-SysPilotProcessExplorerForPid {
    <# Oeffnet Process Explorer (laedt bei Bedarf) - PID-Filter
       als Argument (procexp64 /e <pid> selektiert den Prozess). #>
    param([int]$Id = 0)
    $exe = Get-SysPilotProcessExplorer
    if (-not $exe) { return }
    $args = '/accepteula'
    if ($Id -gt 0) { $args += "/e $Id" }
    Start-Process $exe -ArgumentList $args
    Write-Host '  Process Explorer gestartet.' -ForegroundColor Green
}

function Show-SysPilotProcessMenu {
    <# Task-Manager-Menue: Uebersicht, beenden, starten, Details,
       Process Explorer. #>
    while ($true) {
        Write-Host "`n  ========================================================" -ForegroundColor Cyan
        Write-Host "           SYSPilot TASK-MANAGER" -ForegroundColor Cyan
        Write-Host "  ========================================================" -ForegroundColor Cyan
        $items = @(
            @{ Label='Prozesse anzeigen (Top 40, RAM-sortiert)'; Color='White';    Tag='list' }
            @{ Label='Prozesse nach Name filtern';             Color='White';    Tag='filter' }
            @{ Label='Prozess beenden (PID/Name + Kindprozesse)'; Color='Yellow'; Tag='kill' }
            @{ Label='Programm starten (.exe/Name)';            Color='White';    Tag='start' }
            @{ Label='Prozess-Details/Analyse (Signatur, Parent, Netzwerk)'; Color='White'; Tag='details' }
            @{ Label='In Process Explorer oeffnen (Sysinternals, portabel)'; Color='Cyan'; Tag='pexpl' }
            @{ Label='Zurueck';                                  Color='DarkGray'; Tag=$null }
        )
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'Task-Manager' -Footer 'Pfeiltasten, Enter = auswaehlen, Esc = zurueck'
        if ($null -eq $sel) { return }
        switch ($sel) {
            'list' {
                Show-SysPilotProcessTable -Top 40
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'filter' {
                $f = Read-SysPilotInput 'Namensfilter (z.B. chrome, 4 stellig=PID)'
                if ($f) { Show-SysPilotProcessTable -Top 60 -Filter $f.Trim() }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'kill' {
                $q = Read-SysPilotInput 'PID oder Prozessname zum Beenden (leer = Liste)'
                if (-not $q) {
                    Show-SysPilotProcessTable -Top 30
                    $q = Read-SysPilotInput 'PID oder Name'
                }
                if (-not $q) { continue }
                $hits = @(Get-SysPilotProcesses -Top 500 -Filter $q.Trim())
                if ($hits.Count -eq 0) { Write-Host '  Kein passender Prozess.' -ForegroundColor DarkYellow; Read-SysPilotChoice 'Weiter' | Out-Null; continue }
                if ($hits.Count -gt 1) {
                    Write-Host "`n  Treffer:" -ForegroundColor Cyan
                    $i = 0
                    foreach ($h in ($hits | Select-Object -First 15)) { $i++; Write-Host ("  [{0}] {1} (PID {2}, {3} MB)" -f $i,$h.Name,$h.Id,$h.RamMB) }
                    $pick = Read-SysPilotChoice "Nummer waehlen (1-$($hits.Count) max 15)"
                    if (-not $pick -or [int]$pick -lt 1 -or [int]$pick -gt [Math]::Min(15,$hits.Count)) { continue }
                    $target = $hits[[int]$pick - 1]
                } else { $target = $hits[0] }
                Write-Host "`n  -> $($target.Name) (PID $($target.Id), $($target.RamMB) MB)" -ForegroundColor Yellow
                if (Confirm-SysPilot "Prozess '$($target.Name)' beenden? (inkl. Kindprozesse)") {
                    Stop-SysPilotProcessTree -Id $target.Id -Force
                }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'start' { Start-SysPilotProcessPick }
            'details' {
                $q = Read-SysPilotInput 'PID oder Prozessname'
                if ($q) {
                    $hits = @(Get-SysPilotProcesses -Top 500 -Filter $q.Trim())
                    if ($hits.Count -eq 0) { Write-Host '  Kein passender Prozess.' -ForegroundColor DarkYellow }
                    else { Show-SysPilotProcessDetails -Id $hits[0].Id; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
                }
            }
            'pexpl' {
                $q = Read-SysPilotInput 'PID (optional, leer = universal)'
                $pidNum = 0
                if ($q -and $q -match '^\d+$') { $pidNum = [int]$q }
                Invoke-SysPilotProcessExplorerForPid -Id $pidNum
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
        }
    }
}

Export-ModuleMember -Function `
    Get-SysPilotProcesses, Show-SysPilotProcessTable, `
    Stop-SysPilotProcessTree, Start-SysPilotProcessPick, `
    Set-SysPilotProcessPriority, `
    Get-SysPilotProcessExplorer, Show-SysPilotProcessDetails, `
    Invoke-SysPilotProcessExplorerForPid, Show-SysPilotProcessMenu
