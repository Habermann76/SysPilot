# SysPilot - StorageCleanup: Speicher- & Temp-Analyse (0.9.4.6)
# Erklaert pagefile.sys, hiberfil.sys, Temp-Ordner, Update-Cache, Dumps usw.
# Sicheres Bereinigen nur fuer freigegebene Ziele; riskante Aktionen nur mit Bestaetigung.
#Requires -Version 5.1

function Get-SysPilotItemSizeMB {
    <# Misst Groesse eines Ordners (schnell via robocopy /L) oder einer Datei in MB. #>
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path $Path)) { return 0 }
    $item = Get-Item $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return 0 }
    if (-not $item.PSIsContainer) {
        return [math]::Round($item.Length / 1MB, 2)
    }
    # Ordner: robocopy-Listing ist deutlich schneller als Get-ChildItem -Recurse
    $out = robocopy $Path 'C:\SysPilot-SizeProbe-Null' /L /S /NJH /NFL /NDL /BYTES /XJ /R:0 /W:0 2>$null | Out-String
    if ($out -match '(?m)^\s*Bytes\s*:\s*(\d+)') {
        return [math]::Round([int64]$Matches[1] / 1MB, 2)
    }
    $size = (Get-ChildItem $Path -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    if (-not $size) { return 0 }
    return [math]::Round($size / 1MB, 2)
}

function Get-StorageAnalysis {
    <# Detailierte Speicher- und Temp-Analyse mit deutschen Erklaerungen. #>
    [CmdletBinding()]
    param()

    Write-SysPilotHeader "Speicher- & Temp-Analyse"

    # RAM-Groesse ermitteln
    $ram = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory/1GB)
    Write-Host "RAM-Groesse: $ram GB`n" -ForegroundColor White

    # pagefile.sys analysieren
    Write-Host "pagefile.sys (Auslagerungsdatei)" -ForegroundColor Yellow
    $pfItem = Get-Item "C:\pagefile.sys" -Force -ErrorAction SilentlyContinue
    $pfu = Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pfItem -or $pfu) {
        if ($pfItem) {
            Write-Host ("   Groesse: {0} GB" -f [math]::Round($pfItem.Length/1GB,2)) -ForegroundColor Gray
        } elseif ($pfu) {
            Write-Host ("   Groesse: ca. {0} GB (laut Windows Pagefile-Usage)" -f [math]::Round($pfu.AllocatedBaseSize/1024,2)) -ForegroundColor Gray
        }
        Write-Host "   Typ: Windows-Auslagerungsdatei (RAM-Auslagerung)" -ForegroundColor Gray
        Write-Host "   Enthaelt KEINEN 'alten Muell' - die Groesse kommt von der Windows-Automatik (meist 1-3x RAM)" -ForegroundColor DarkGray
        Write-Host "   NICHT loeschen. Verkleinern geht nur manuell (sysdm.cpl), bei grossen KI-Modellen nicht unter 8 GB!" -ForegroundColor Red
    } else {
        Write-Host "   Keine Pagefile konfiguriert" -ForegroundColor DarkGray
    }
    if ($pfu) {
        Write-Host ("   Aktuell belegt: {0} MB, Spitze: {1} MB" -f $pfu.CurrentUsage, $pfu.PeakUsage) -ForegroundColor DarkGray
    }

    # hiberfil.sys analysieren
    Write-Host "`nhiberfil.sys (Ruhezustand)" -ForegroundColor Yellow
    if (Test-Path "C:\hiberfil.sys") {
        $hf = Get-Item "C:\hiberfil.sys" -Force
        Write-Host ("   Groesse: {0} GB" -f [math]::Round($hf.Length/1GB,2)) -ForegroundColor Gray
        Write-Host "   Typ: Ruhezustandsdatei (ca. 40-75% des RAMs)" -ForegroundColor Gray
        Write-Host "   Abschaltbar via 'powercfg /h off' - endet auch den Schnellstart (Start dauert minimal laenger)" -ForegroundColor DarkGray
    } else {
        Write-Host "   Nicht vorhanden (Ruhezustand evtl. bereits aus)" -ForegroundColor Green
    }

    # swapfile.sys
    Write-Host "`nswapfile.sys" -ForegroundColor Yellow
    if (Test-Path "C:\swapfile.sys") {
        $sf = Get-Item "C:\swapfile.sys" -Force
        Write-Host ("   Groesse: {0} GB - dynamischer Arbeitsspeicher, Windows-intern" -f [math]::Round($sf.Length/1GB,2)) -ForegroundColor Gray
    } else {
        Write-Host "   Nicht vorhanden" -ForegroundColor DarkGray
    }

    # Ordner/Dateien mit Groesse messen
    $rows = @(
        @{ Name = 'Benutzer-Temp';            Path = $env:TEMP;                                            Safe = $true  }
        @{ Name = 'Windows-Temp';             Path = 'C:\Windows\Temp';                                    Safe = $true  }
        @{ Name = 'Windows-Update-Cache';     Path = 'C:\Windows\SoftwareDistribution\Download';          Safe = $true  }
        @{ Name = 'Windows-Logs';             Path = 'C:\Windows\Logs';                                    Safe = $true  }
        @{ Name = 'Windows-Installer';        Path = 'C:\Windows\Installer';                               Safe = $false }
        @{ Name = 'WinSxS (Komponentenspeicher)'; Path = 'C:\Windows\WinSxS';                             Safe = $false }
        @{ Name = 'Windows-Fehlerberichte (WER)'; Path = 'C:\ProgramData\Microsoft\Windows\WER';          Safe = $true  }
        @{ Name = 'Minidumps';                Path = 'C:\Windows\Minidump';                                 Safe = $true  }
        @{ Name = 'CrashDumps (Benutzer-WER)'; Path = "$env:LOCALAPPDATA\Microsoft\Windows\WER\ReportArchive"; Safe = $true }
    )
    foreach ($r in $rows) {
        $mb = Get-SysPilotItemSizeMB -Path $r.Path
        $safeMark = if ($r.Safe) { '[SICHER]' } else { '[VORSICHT]' }
        Write-Host ("{0,-32} {1,10} MB  {2}" -f $r.Name, $mb, $safeMark) -ForegroundColor $(if ($r.Safe) { 'White' } else { 'Yellow' })
    }
    if (Test-Path 'C:\Windows\MEMORY.DMP') {
        $mdb = Get-SysPilotItemSizeMB -Path 'C:\Windows\MEMORY.DMP'
        Write-Host ("{0,-32} {1,10} MB  [SICHER]" -f 'MEMORY.DMP (Absturzabbild)', $mdb) -ForegroundColor White
    }

    Write-Host "`nLegende: [SICHER] = kann gefahrlos geloescht werden | [VORSICHT] = niemals von Hand, nur Windows/DISM" -ForegroundColor DarkGray
    Write-Host "WinSxS & Windows-Installer nur ueber DISM: Dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase" -ForegroundColor DarkGray
    Write-Host "Tipp fuer Platzfresser ausserhalb Windows: Wizard 'Grosse Dateien finden' in der Toolbox." -ForegroundColor DarkGray
}

function Set-SysPilotHibernation {
    <# Schaltet den Ruhezustand um: hiberfil.sys vorhanden -> aus (powercfg /h off),
       nicht vorhanden -> an (powercfg /h on). Beides nur mit Bestaetigung. #>
    if (-not (Assert-SysPilotAdmin)) { return }
    $isOn = Test-Path 'C:\hiberfil.sys'
    if ($isOn) {
        Write-Host "Ruhezustand ist AN (hiberfil.sys vorhanden)." -ForegroundColor Yellow
        Write-Host "Ausschalten beendet auch den 'Schnellstart' - der naechste Start dauert minimal laenger." -ForegroundColor DarkGray
        if (Confirm-SysPilot 'Ruhezustand jetzt ausschalten?') {
            powercfg /h off
            Write-Host '  [OK] Ruhezustand ausgeschaltet, hiberfil.sys entfernt, Schnellstart beendet.' -ForegroundColor Green
            Write-SysPilotLog 'StorageCleanup: Ruhezustand ausgeschaltet'
        }
    } else {
        Write-Host "Ruhezustand ist AUS (keine hiberfil.sys)." -ForegroundColor Yellow
        Write-Host "Einschalten stellt 'Ruhezustand' und den 'Schnellstart' wieder her." -ForegroundColor DarkGray
        if (Confirm-SysPilot 'Ruhezustand jetzt einschalten?') {
            powercfg /h on
            Write-Host '  [OK] Ruhezustand eingeschaltet (hiberfil.sys wird wieder angelegt).' -ForegroundColor Green
            Write-SysPilotLog 'StorageCleanup: Ruhezustand eingeschaltet'
        }
    }
}

function Show-SysPilotPagefileGuide {
    <# Anleitung zur Pagefile-Verkleinerung (manuell, mit Warnung). #>
    Write-Host "Pagefile-Optimierung (manuell):" -ForegroundColor Cyan
    Write-Host "  1. Win+R -> 'sysdm.cpl' -> Enter" -ForegroundColor Gray
    Write-Host "  2. Reiter 'Erweitert' -> 'Leistung' -> 'Einstellungen'" -ForegroundColor Gray
    Write-Host "  3. Reiter 'Erweitert' -> 'Virtueller Arbeitsspeicher' -> 'Aendern'" -ForegroundColor Gray
    Write-Host "  4. Haken 'Automatisch verwalten' entfernen, Laufwerk C: whalen" -ForegroundColor Gray
    Write-Host "  5. 'Benutzerdefinierte Groesse': 16+GB RAM -> 8192/8192 MB, 8-16GB -> 4096/4096 MB" -ForegroundColor Gray
    Write-Host "  6. 'Festlegen' -> OK -> NEUSTART" -ForegroundColor Gray
    Write-Host "`n  ACHTUNG: Bei grossen KI-Modellen (LM Studio) NICHT unter 8 GB - sonst koennen Programme abstuerzen!" -ForegroundColor Red
}

function Invoke-SysPilotDismCleanup {
    <# DISM Component Cleanup - entfernt alte Windows-Komponenten. Dauert laenger. #>
    if (-not (Assert-SysPilotAdmin)) { return }
    Write-Host "DISM Component Cleanup startet - das kann 10-30 Minuten dauern..." -ForegroundColor Yellow
    Write-Host "(entfernt ueberfluessige Windows-Komponenten aus WinSxS)" -ForegroundColor DarkGray
    if (-not (Confirm-SysPilot 'Jetzt starten?')) { return }
    & Dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase
    Write-Host '  [OK] DISM Cleanup abgeschlossen.' -ForegroundColor Green
    Write-SysPilotLog 'StorageCleanup: DISM Component Cleanup ausgefuehrt'
}

function Show-SysPilotStorageMenu {
    <# Hauptmenue der Speicher-Analyse: erst Analyse, dann optionale Aktionen. #>
    $items = @(
        @{ Label = 'Analyse anzeigen (Groessen + Erklaerungen)';              Color = 'White';    Tag = 'analyse' }
        @{ Label = 'Ruhezustand umschalten (an/aus, hiberfil.sys)';          Color = 'White';    Tag = 'hibernate' }
        @{ Label = 'Pagefile-Verkleinerung (Anleitung)';                     Color = 'White';    Tag = 'pagefile' }
        @{ Label = 'DISM Component Cleanup (WinSxS, dauert laenger)';         Color = 'Yellow';   Tag = 'dism' }
        @{ Label = 'Sicheres Temp/Cache-Bereinigen (wie Cleanup-Menue)';     Color = 'White';    Tag = 'cleanup' }
        @{ Label = 'Zurueck';                                                Color = 'DarkGray'; Tag = $null }
    )
    while ($true) {
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'Speicher-Analyse' -Footer 'Pfeiltasten hoch/runter, Enter = auswaehlen, Esc = zurueck'
        if ($null -eq $sel) { return }
        switch ($sel) {
            'analyse'    { Get-StorageAnalysis; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
            'hibernate'  { Set-SysPilotHibernation; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
            'pagefile'   { Show-SysPilotPagefileGuide; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
            'dism'       { Invoke-SysPilotDismCleanup; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
            'cleanup'    { if (Confirm-SysPilot 'Datentraeger-Bereinigung starten?') { Show-SysPilotCleanupMenu }; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
        }
    }
}

Export-ModuleMember -Function Get-StorageAnalysis, Show-SysPilotStorageMenu,
    Set-SysPilotHibernation, Show-SysPilotPagefileGuide, Invoke-SysPilotDismCleanup,
    Get-SysPilotItemSizeMB
