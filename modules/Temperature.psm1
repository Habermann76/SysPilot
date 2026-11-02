# SysPilot - Temperature: CPU-Temperatur aus mehreren Quellen (mit Fallback)
#Requires -Version 5.1

function Get-SysPilotCpuTemperature {
    <#
    Versucht CPU-Temperatur zu lesen. Quellen in Reihenfolge:
      1. LibreHardwareMonitor / HWiNFO WMI (falls installiert)
      2. OpenHardwareMonitor WMI
      3. ACPI Thermal Zone (meist nicht verfuegbar auf Laptops)
      4. Schaetzung aus CPU-Last (Fallback, als 'geschaetzt' markiert)
    Rueckgabe: [PSCustomObject]@{ Celsius; Quelle; Geschaetzt }
    #>

    # 1. LibreHardwareMonitor / HWiNFO (falls der Nutzer es installiert hat)
    try {
        $lhm = Get-CimInstance -Namespace 'root\LibreHardwareMonitor' -ClassName 'Hardware' -ErrorAction Stop |
               Where-Object { $_.HardwareType -eq 'Cpu' }
        if ($lhm) {
            $sensor = Get-CimInstance -Namespace 'root\LibreHardwareMonitor' -ClassName 'Sensor' -ErrorAction Stop |
                      Where-Object { $_.SensorType -eq 'Temperature' -and $_.Name -match 'Package|Core|CPU' } |
                      Sort-Object Value -Descending | Select-Object -First 1
            if ($sensor) {
                return [PSCustomObject]@{ Celsius = [math]::Round($sensor.Value); Quelle = 'LibreHardwareMonitor'; Geschaetzt = $false }
            }
        }
    } catch { }

    # 2. OpenHardwareMonitor
    try {
        $ohm = Get-CimInstance -Namespace 'root\OpenHardwareMonitor' -ClassName 'Sensor' -ErrorAction Stop |
               Where-Object { $_.SensorType -eq 'Temperature' -and $_.Name -match 'CPU|Package|Core' } |
               Sort-Object Value -Descending | Select-Object -First 1
        if ($ohm) {
            return [PSCustomObject]@{ Celsius = [math]::Round($ohm.Value); Quelle = 'OpenHardwareMonitor'; Geschaetzt = $false }
        }
    } catch { }

    # 3. ACPI Thermal Zone (selten auf Laptops verfuegbar)
    try {
        $t = Get-CimInstance -Namespace 'root\wmi' -ClassName 'MSAcpi_ThermalZoneTemperature' -ErrorAction Stop |
             Select-Object -First 1
        if ($t) {
            $c = [math]::Round(($t.CurrentTemperature / 10) - 273.15)
            if ($c -gt 0 -and $c -lt 130) {
                return [PSCustomObject]@{ Celsius = $c; Quelle = 'ACPI'; Geschaetzt = $false }
            }
        }
    } catch { }

    # 4. Fallback: Schaetzung aus CPU-Last (grobe Naeherung, klar markiert)
    $cpu = Get-CimInstance Win32_Processor
    $load = $cpu.LoadPercentage
    $speedPct = if ($cpu.MaxClockSpeed -gt 0) { $cpu.CurrentClockSpeed / $cpu.MaxClockSpeed } else { 1 }
    # Basis ~40C idle, +0.35C pro % Last, +8C wenn Boost aktiv (Takt > Basis)
    $est = 40 + ($load * 0.35) + ($(if ($speedPct -gt 1.0) { 8 } else { 0 }))
    return [PSCustomObject]@{ Celsius = [math]::Round($est); Quelle = 'geschaetzt (Last)'; Geschaetzt = $true }
}

function Get-SysPilotTempStatus {
    param([int]$Celsius)
    $cfg = (Get-SysPilotConfig).Autopilot
    if ($Celsius -ge [int]$cfg.TempCriticalC) { return @{ Text = 'KRITISCH'; Color = '#FFB71C1C' } }
    if ($Celsius -ge [int]$cfg.TempHotC)  { return @{ Text = 'HEISS';  Color = '#FFEF5350' } }
    if ($Celsius -ge [int]$cfg.TempWarmC) { return @{ Text = 'WARM';   Color = '#FFFFB74D' } }
    return @{ Text = 'OK'; Color = '#FF81C784' }
}

function Invoke-SysPilotThermalShutdown {
    <# Hitze-Notaus: PC vorsichtshalber herunterfahren/ruhezustand, bevor die CPU Schaden nimmt.
       Standard: Ruhezustand (Hibernate) - sicher, nichts geht verloren, schnell wieder da. #>
    param([int]$Celsius)
    $cfg = (Get-SysPilotConfig).Autopilot
    $action = $cfg.TempCriticalAction

    Write-SysPilotLog "HITZE-NOTAUS ausgeloest bei ${Celsius}C -> $action" -Level 'WARN'

    # Warnung anzeigen (30 Sekunden Countdown, abbrechen moeglich)
    $msg = "ACHTUNG: CPU ist ${Celsius}°C - KRITISCH!`n`nSysPilot schuetzt deinen PC und versetzt ihn in den Ruhezustand.`nAlles bleibt gespeichert.`n`nKlicke 'Abbrechen' innerhalb von 30 Sekunden, um das zu verhindern."
    $shell = New-Object -ComObject WScript.Shell
    $result = $shell.Popup($msg, 30, "SysPilot Hitzeschutz", 48 + 1)  # 48=Warnung, 1=OK/Abbrechen

    if ($result -eq 2) {  # Abbrechen
        Write-SysPilotLog "Hitzeschutz vom Nutzer abgebrochen bei ${Celsius}C" -Level 'WARN'
        return $false
    }

    Write-SysPilotLog "Hitzeschutz aktiv: $action bei ${Celsius}C" -Level 'WARN'
    if ($action -eq 'Shutdown') {
        & shutdown.exe /s /t 60 /c "SysPilot Hitzeschutz: CPU ${Celsius}C - PC wird heruntergefahren" | Out-Null
    } else {
        # Ruhezustand (sicherer Standard)
        & shutdown.exe /h | Out-Null
    }
    return $true
}

function Install-SysPilotLHM {
    <# Installiert LibreHardwareMonitor vollautomatisch (portable) und startet es.
       Danach liest SysPilot die echte CPU-Temperatur. #>
    Write-Host ""
    Write-Host "  LibreHardwareMonitor wird eingerichtet ..." -ForegroundColor Cyan
    Write-Host "  (kostenlos, Open Source, portable - keine Installation, keine Telemetrie)" -ForegroundColor DarkGray

    $dest = 'C:\Users\haber\SysPilot\tools\LibreHardwareMonitor'
    $exe = Join-Path $dest 'LibreHardwareMonitor.exe'
    if (Test-Path $exe) {
        Write-Host "  Bereits vorhanden: $exe" -ForegroundColor Green
    } else {
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
        $zip = Join-Path $env:TEMP 'lhm.zip'
        # Neuestes Release von GitHub
        $rel = Invoke-RestMethod 'https://api.github.com/repos/LibreHardwareMonitor/LibreHardwareMonitor/releases/latest' -ErrorAction Stop
        $asset = $rel.assets | Where-Object { $_.name -match '\.zip$' } | Select-Object -First 1
        if (-not $asset) { Write-Host "  [!] Download-Link nicht gefunden." -ForegroundColor Red; return }
        Write-Host "  Lade $($asset.name) herunter ..." -ForegroundColor DarkGray
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing
        Expand-Archive -Path $zip -DestinationPath $dest -Force
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        Write-Host "  [OK] Entpackt nach $dest" -ForegroundColor Green
    }

    # Starten (braucht Admin fuer Sensor-Zugriff)
    $running = Get-Process LibreHardwareMonitor -ErrorAction SilentlyContinue
    if (-not $running) {
        if (Test-SysPilotAdmin) {
            Start-Process $exe
        } else {
            Start-Process $exe -Verb RunAs
        }
        Start-Sleep -Seconds 4
    }
    Write-Host "  [OK] LibreHardwareMonitor laeuft - SysPilot liest jetzt die echte CPU-Temperatur." -ForegroundColor Green
    Write-SysPilotLog "LibreHardwareMonitor eingerichtet und gestartet"
}

Export-ModuleMember -Function Get-SysPilotCpuTemperature, Get-SysPilotTempStatus, Invoke-SysPilotThermalShutdown, Install-SysPilotLHM
