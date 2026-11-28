# SysPilot - HealthMonitor: Smart Health Monitor (neu entworfen)
# Ueberwacht CPU, GPU, SSD, Luefter, Temperatur via LibreHardwareMonitor + Fallbacks
# Bei Abweichungen: KI-freundliche Ursachenanalyse, Warnsymbol, Reparatur-Howtos, Ersatzteil-Empfehlungen
#Requires -Version 5.1

$script:SysPilotRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$script:HealthStateFile = Join-Path $script:SysPilotRoot 'logs\health-state.json'
$script:LhmExe = $null
try { $script:LhmExe = Join-Path (Get-SysPilotPortableAppsDir) 'LibreHardwareMonitor\LibreHardwareMonitor.exe' } catch { }
if (-not $script:LhmExe) { $script:LhmExe = Join-Path $script:SysPilotRoot 'tools\LibreHardwareMonitor\LibreHardwareMonitor.exe' }

# ---------- Schwellenwerte ----------
$script:HealthThresholds = @{
    CpuWarnC  = 75
    CpuCritC  = 85
    GpuWarnC  = 75
    GpuCritC  = 85
    SsdWarnC  = 55
    SsdCritC  = 65
    FanMinRpm = 600
    FanMaxRpm = 6000
}

# ---------- Zustand laden/speichern ----------
function Get-SysPilotHealthState {
    if (-not (Test-Path $script:HealthStateFile)) {
        return @{ Modus = 'NORMAL'; LetztePruefung = $null; Warnungen = @(); Historie = @() }
    }
    try {
        $raw = Get-Content $script:HealthStateFile -Raw -ErrorAction Stop
        return $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return @{ Modus = 'NORMAL'; LetztePruefung = $null; Warnungen = @(); Historie = @() }
    }
}

function Save-SysPilotHealthState {
    param($State)
    $dir = Split-Path $script:HealthStateFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = $State | ConvertTo-Json -Depth 5
    Set-Content -Path $script:HealthStateFile -Value $json -Encoding UTF8 -ErrorAction SilentlyContinue
}

# ---------- Sensoren via LibreHardwareMonitor ----------
function Get-SysPilotLhmSensors {
    <# Liest Sensoren aus LibreHardwareMonitor WMI-Namespace #>
    $sensors = @()
    try {
        $hw = Get-CimInstance -Namespace 'root\LibreHardwareMonitor' -ClassName 'Hardware' -ErrorAction Stop
        foreach ($h in $hw) {
            $typ = $h.HardwareType
            $sens = Get-CimInstance -Namespace 'root\LibreHardwareMonitor' -ClassName 'Sensor' -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -eq $h.Name -or $_.SensorType -in @('Temperature','Load','Clock','Power','Throughput','SmallData') }
            foreach ($s in $sens) {
                $sensors += [PSCustomObject]@{
                    Hardware = $h.HardwareType
                    Name = $h.Name
                    SensorType = $s.SensorType
                    SensorName = $s.Name
                    Value = if ($s.Value -is [double]) { [math]::Round($s.Value, 1) } else { $s.Value }
                    Unit = $s.Unit
                }
            }
        }
    } catch { }
    return $sensors
}

# ---------- Temperatur ueber bestehende Temperature.psm1 ----------
function Get-SysPilotCpuTemperatureSimple {
    if (Get-Command Get-SysPilotCpuTemperature -ErrorAction SilentlyContinue) {
        return Get-SysPilotCpuTemperature
    }
    return [PSCustomObject]@{ Celsius = $null; Quelle = 'unbekannt'; Geschaetzt = $true }
}

# ---------- SSD Health via SMART (PowerShell Fallback) ----------
function Get-SysPilotSsdHealth {
    <# Versucht SSD-Gesundheit ueber PowerShell / WMI zu ermitteln #>
    $disks = Get-PhysicalDisk -ErrorAction SilentlyContinue
    $results = @()
    foreach ($d in $disks) {
        $results += [PSCustomObject]@{
            Name = $d.FriendlyName
            Typ = $d.MediaType
            Gesundheit = $d.HealthStatus
            SizeGB = [math]::Round($d.Size / 1GB, 1)
            Seriennummer = $d.SerialNumber
        }
    }
    return $results
}

# ---------- Luefter-Geschwindigkeit ----------
function Get-SysPilotFanSpeeds {
    $sensors = Get-SysPilotLhmSensors
    $fans = $sensors | Where-Object { $_.SensorType -eq 'Fan' }
    return $fans
}

# ---------- Gesamte Gesundheitspruefung ----------
function Invoke-SysPilotHealthCheck {
    <# Fuehrt eine vollstaendige Gesundheitspruefung durch und gibt Zustand zurueck.
       Modus: NORMAL | WARNUNG | KRITISCH
       Bei WARNUNG/KRITISCH: intensivere Pruefung, Ursachenanalyse #>
    param([switch]$Quick)
    $state = Get-SysPilotHealthState
    # Rate-Limiting: Bei NORMAL-Modus nicht zu oft pruefen
    if (-not (Test-SysPilotHealthRateLimit -Modus $state.Modus)) {
        # Letzten Zustand zurueckgeben ohne teure Pruefung
        return [PSCustomObject]@{
            Modus = $state.Modus
            Werte = @{}
            Warnungen = $state.Warnungen
            CpuTemp = $null
            GpuTemp = $null
            Sensoren = @()
            Fans = @()
            SsdHealth = @()
            Zeit = $state.LetzterPruefung
            RateLimited = $true
        }
    }
    $lhmSensors = Get-SysPilotLhmSensors
    $cpuTemp = Get-SysPilotCpuTemperatureSimple
    $ssdHealth = Get-SysPilotSsdHealth
    $fans = @(Get-SysPilotFanSpeeds)

    $werte = @{}
    $warnungen = @()
    $modus = 'NORMAL'

    # CPU Temperatur
    if ($cpuTemp.Celsius) {
        $werte.CpuTemp = $cpuTemp.Celsius
        if ($cpuTemp.Celsius -ge $script:HealthThresholds.CpuCritC) {
            $warnungen += @{ Komponente = 'CPU'; Wert = $cpuTemp.Celsius; Einheit = ' Grad C'; Schweregrad = 'KRITISCH'; Text = 'CPU-Temperatur kritisch - moegliche Thermaldrosselung' }
            $modus = 'KRITISCH'
        } elseif ($cpuTemp.Celsius -ge $script:HealthThresholds.CpuWarnC) {
            $warnungen += @{ Komponente = 'CPU'; Wert = $cpuTemp.Celsius; Einheit = ' Grad C'; Schweregrad = 'WARNUNG'; Text = 'CPU-Temperatur erhoeht - Kuehlung pruefen' }
            if ($modus -eq 'NORMAL') { $modus = 'WARNUNG' }
        }
    }

    # GPU Temperatur (aus LHM)
    $gpuTemp = $lhmSensors | Where-Object { $_.Hardware -eq 'Gpu' -and $_.SensorType -eq 'Temperature' } | Select-Object -First 1
    if ($gpuTemp) {
        $werte.GpuTemp = $gpuTemp.Value
        if ($gpuTemp.Value -ge $script:HealthThresholds.GpuCritC) {
            $warnungen += @{ Komponente = 'GPU'; Wert = $gpuTemp.Value; Einheit = ' Grad C'; Schweregrad = 'KRITISCH'; Text = 'GPU-Temperatur kritisch' }
            $modus = 'KRITISCH'
        } elseif ($gpuTemp.Value -ge $script:HealthThresholds.GpuWarnC) {
            $warnungen += @{ Komponente = 'GPU'; Wert = $gpuTemp.Value; Einheit = ' Grad C'; Schweregrad = 'WARNUNG'; Text = 'GPU-Temperatur erhoeht' }
            if ($modus -eq 'NORMAL') { $modus = 'WARNUNG' }
        }
    }

    # SSD Health
    foreach ($ssd in $ssdHealth) {
        if ($ssd.Gesundheit -ne 'Gesund') {
            $warnungen += @{ Komponente = 'SSD'; Wert = $ssd.Gesundheit; Einheit = ''; Schweregrad = 'KRITISCH'; Text = "SSD '$($ssd.Name)' meldet Gesundheit: $($ssd.Gesundheit) - Datensicherung empfohlen!" }
            $modus = 'KRITISCH'
        }
    }

    # Luefter
    foreach ($fan in $fans) {
        if ($fan.Value -and $fan.Value -lt $script:HealthThresholds.FanMinRpm) {
            $warnungen += @{ Komponente = 'Luefter'; Wert = $fan.Value; Einheit = 'RPM'; Schweregrad = 'WARNUNG'; Text = "Luefter '$($fan.SensorName)' laeuft langsam ($([math]::Round($fan.Value)) RPM) - evtl. verschmutzt oder defekt" }
            if ($modus -eq 'NORMAL') { $modus = 'WARNUNG' }
        }
        # Unrund-Erkennung bei WARNUNG/KRITISCH (Rate-Limiting: nur wenn noetig, nicht im Quick-Modus)
        if (-not $Quick -and $modus -ne 'NORMAL' -and $fan.Value -and $fan.Value -gt 0) {
            $unrund = Test-SysPilotFanUnrund -SensorName $fan.SensorName -Messungen 3 -IntervallMs 500
            if ($unrund.Unrund) {
                $warnungen += @{ Komponente = 'Luefter'; Wert = $unrund.Standardabweichung; Einheit = 'RPM-Varianz'; Schweregrad = 'WARNUNG'; Text = "Luefter '$($fan.SensorName)' laeuft unrund (Varianz: $([math]::Round($unrund.Standardabweichung)) RPM) - evtl. dreckig oder Lager verschlissen" }
                if ($modus -eq 'NORMAL') { $modus = 'WARNUNG' }
            }
        }
    }

    $state.Modus = $modus
    $state.LetzterPruefung = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $state.Warnungen = $warnungen
    $state.Historie = @($werte) + $state.Historie
    if ($state.Historie.Count -gt 50) { $state.Historie = $state.Historie[0..49] }
    Save-SysPilotHealthState -State $state

    return [PSCustomObject]@{
        Modus = $modus
        Werte = $werte
        Warnungen = $warnungen
        CpuTemp = $werte.CpuTemp
        GpuTemp = $werte.GpuTemp
        Sensoren = $lhmSensors
        Fans = $fans
        SsdHealth = $ssdHealth
        Zeit = $state.LetzterPruefung
    }
}

# ---------- KI-freundliche Ursachenanalyse ----------
function Get-SysPilotHealthUrsachen {
    param([string]$Komponente, [string]$Wert, [string]$Einheit)
    $ursachen = @()
    $howtos = @()

    switch ($Komponente) {
        'CPU' {
            $temp = [double]$Wert
            if ($temp -ge 85) {
                $ursachen += 'Thermalpaste moeglicherweise ausgetrocknet (aelter als 2-3 Jahre)'
                $ursachen += 'CPU-Kuehler/Luefter verschmutzt oder defekt'
                $ursachen += 'Gehaeusebelueftung unzureichend (Staub, blocked airflow)'
                $ursachen += 'CPU laeuft im Dauer-Boost (zu hohe Spannung/Takt)'
                $howtos += @{ Titel = 'Thermalpaste erneuern'; Beschreibung = 'CPU-Kuehler abbauen, alte Paste entfernen, neue Waermeleitpaste auftragen, Kuehler wieder montieren.'; Schwierigkeit = 'Mittel'; ZeitMin = 30 }
                $howtos += @{ Titel = 'CPU-Kuehler reinigen'; Beschreibung = 'Staub vom Kuehler und Luefterblaettern entfernen (Druckluft, weiche Buerste).'; Schwierigkeit = 'Einfach'; ZeitMin = 15 }
            } elseif ($temp -ge 75) {
                $ursachen += 'CPU-Temperatur im oberen Normalbereich - Gehaeuselueftung pruefen'
                $ursachen += 'Luefterkurve im BIOS koennte aggressiver eingestellt werden'
                $howtos += @{ Titel = 'Gehaeuse staubfrei machen'; Beschreibung = 'Alle Luefter und Filter im Gehaeuse reinigen, Luftstrom pruefen.'; Schwierigkeit = 'Einfach'; ZeitMin = 20 }
            }
        }
        'GPU' {
            $temp = [double]$Wert
            if ($temp -ge 85) {
                $ursachen += 'GPU-Luefter verschmutzt oder defekt'
                $ursachen += 'Grafikkarte im Gehaeuse zu wenig Luftzufuhr'
                $ursachen += 'Thermalpaste auf der GPU moeglicherweise alt'
                $howtos += @{ Titel = 'GPU-Luefter reinigen'; Beschreibung = 'Grafikkarte ausbauen, Luefter und Kuehlrippen von Staub befreien.'; Schwierigkeit = 'Mittel'; ZeitMin = 25 }
            }
        }
        'SSD' {
            $ursachen += 'SSD naehert sich dem Lebensende (SMART-Werte kritisch)'
            $ursachen += 'Ueberhitzung der SSD (keine Kuehlung, schlechte Belueftung)'
            $ursachen += 'Viele Schreibzugriffe in kurzer Zeit'
            $howtos += @{ Titel = 'Daten sofort sichern'; Beschreibung = 'Wichtige Daten auf externe Festplatte oder Cloud kopieren, bevor die SSD ausfaellt.'; Schwierigkeit = 'Einfach'; ZeitMin = 60 }
            $howtos += @{ Titel = 'SSD-Ersatz pruefen'; Beschreibung = 'Kompatible SSD ermitteln (NVMe M.2 oder SATA), kaufen und Daten klonen.'; Schwierigkeit = 'Mittel'; ZeitMin = 45 }
        }
        'Luefter' {
            $rpm = [double]$Wert
            if ($rpm -gt 0 -and $rpm -lt 600) {
                $ursachen += 'Luefter durch Staub oder Fusseln blockiert'
                $ursachen += 'Luefterlager verschlissen (laut, unrund)'
                $ursachen += 'Luefterkabel lose oder Stecker oxidiert'
                $ursachen += 'BIOS-Luefterkurve zu niedrig eingestellt'
                $howtos += @{ Titel = 'Luefter reinigen'; Beschreibung = 'Luefter ausbauen, Blaetter und Lager mit Druckluft reinigen, ggf. ein Tropfen Maschinenoel ins Lager.'; Schwierigkeit = 'Einfach'; ZeitMin = 15 }
                $howtos += @{ Titel = 'Luefter ersetzen'; Beschreibung = 'Passenden Ersatzluefter (Groesse, Anschluss 3-/4-Pin) kaufen und einbauen.'; Schwierigkeit = 'Einfach'; ZeitMin = 10 }
            }
        }
    }

    return [PSCustomObject]@{
        Ursachen = $ursachen
        HowTos = $howtos
    }
}

# ---------- Ersatzteil-Empfehlungen ----------
function Get-SysPilotErsatzteile {
    param([string]$Komponente)
    $teile = @()

    switch ($Komponente) {
        'CPU' {
            $teile += @{ Produkt = 'Waermeleitpaste (z.B. Arctic MX-4, Noctua NT-H2)'; Zweck = 'Fuer CPU-Kuehler'; PriceEur = '5-15 EUR' }
            $teile += @{ Produkt = 'CPU-Kuehler (Air oder AIO)'; Zweck = 'Wenn aktueller Kuehler unzureichend'; PriceEur = '30-150 EUR' }
            $teile += @{ Produkt = 'Gehaeuseluefter (120/140mm)'; Zweck = 'Bessere Gehaeusebelueftung'; PriceEur = '10-25 EUR' }
        }
        'GPU' {
            $teile += @{ Produkt = 'Grafikkarten-Luefter'; Zweck = 'Ersatz fuer defekte GPU-Luefter'; PriceEur = '15-40 EUR' }
            $teile += @{ Produkt = 'GPU-Halterung'; Zweck = 'Vermeidet Durchhaengen und Belastung'; PriceEur = '15-30 EUR' }
        }
        'SSD' {
            $teile += @{ Produkt = 'NVMe M.2 SSD (1-2 TB)'; Zweck = 'Ersatz fuer ausfallgefaehrdete SSD'; PriceEur = '60-150 EUR' }
            $teile += @{ Produkt = 'SATA SSD (1-4 TB)'; Zweck = 'Ersatz fuer aeltere SATA-SSDs'; PriceEur = '50-120 EUR' }
            $teile += @{ Produkt = 'SSD-Kuehlkoerper / Heatsink'; Zweck = 'Vermeidung von SSD-Ueberhitzung'; PriceEur = '10-25 EUR' }
        }
        'Luefter' {
            $teile += @{ Produkt = 'Gehaeuseluefter 120mm / 140mm (PWM)'; Zweck = 'Ersatz fuer defekte oder laute Luefter'; PriceEur = '12-30 EUR' }
            $teile += @{ Produkt = 'CPU-Luefter'; Zweck = 'Ersatz fuer defekten CPU-Kuehler-Luefter'; PriceEur = '15-35 EUR' }
        }
    }
    return $teile
}

# ---------- Warnsymbol-Farbe ----------
function Get-SysPilotHealthSymbol {
    param([string]$Modus)
    switch ($modus) {
        'KRITISCH' { return @{ Symbol = '!'; Farbe = '#FF1744'; Text = 'KRITISCH' } }
        'WARNUNG'  { return @{ Symbol = '!'; Farbe = '#FF9800'; Text = 'WARNUNG' } }
        default    { return @{ Symbol = 'v'; Farbe = '#4CAF50'; Text = 'OK' } }
    }
}
# ---------- Luefter "unrund"-Erkennung (RPM-Varianz ueber Zeit) ----------
function Test-SysPilotFanUnrund {
    param([string]$SensorName, [int]$Messungen = 5, [int]$IntervallMs = 1000)
    $werte = @()
    for ($i = 0; $i -lt $Messungen; $i++) {
        $fans = Get-SysPilotFanSpeeds
        $fan = $fans | Where-Object { $_.SensorName -eq $SensorName } | Select-Object -First 1
        if ($fan -and $fan.Value) { $werte += [double]$fan.Value }
        if ($i -lt $Messungen - 1) { Start-Sleep -Milliseconds $IntervallMs }
    }
    if ($werte.Count -lt 2) { return @{ SensorName = $SensorName; RpmWerte = $werte; Mittelwert = 0; Standardabweichung = 0; Unrund = $false } }
    $mittel = ($werte | Measure-Object -Average).Average
    $varianz = ($werte | ForEach-Object { [math]::Pow($_ - $mittel, 2) } | Measure-Object -Average).Average
    $stdAbw = [math]::Sqrt($varianz)
    $unrund = ($stdAbw -gt ($mittel * 0.15)) -or ($stdAbw -gt 100)
    return @{ SensorName = $SensorName; RpmWerte = $werte; Mittelwert = [math]::Round($mittel); Standardabweichung = [math]::Round($stdAbw, 1); Unrund = $unrund }
}

# ---------- KI-Recherche fuer Reparatur-Howtos (Web-Suche) ----------
function Get-SysPilotRepairHowtosOnline {
    param([string]$Suchbegriff, [int]$MaxErgebnisse = 5)
    $ergebnisse = @()
    try {
        $query = [Uri]::EscapeDataString("$Suchbegriff Reparatur Howto Anleitung")
        $url = "https://duckduckgo.com/?q=$query&format=json&no_html=1"
        $resp = Invoke-RestMethod -Uri $url -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        if ($resp.Results) {
            foreach ($r in ($resp.Results | Select-Object -First $MaxErgebnisse)) {
                $ergebnisse += @{ Titel = $r.Text; Url = $r.FirstURL; Beschreibung = $r.Result }
            }
        }
    } catch {
        $ergebnisse += @{ Titel = "Online-Suche: $Suchbegriff"; Url = "https://duckduckgo.com/?q=$([Uri]::EscapeDataString($Suchbegriff + ' Reparatur Howto'))"; Beschreibung = "Manuelle Suche im Browser" }
    }
    if ($ergebnisse.Count -eq 0) {
        $ergebnisse += @{ Titel = "Online-Suche: $Suchbegriff"; Url = "https://duckduckgo.com/?q=$([Uri]::EscapeDataString($Suchbegriff + ' Reparatur Howto'))"; Beschreibung = "Manuelle Suche im Browser" }
    }
    return $ergebnisse
}

# ---------- Nahegelegene Reparaturlaeden (Standort-basiert) ----------
function Get-SysPilotNearbyRepairShops {
    param([string]$Stadt = '', [string]$PLZ = '')
    $ort = if ($Stadt) { $Stadt } elseif ($PLZ) { $PLZ } else { '' }
    if (-not $ort) {
        try {
            $geo = Invoke-RestMethod -Uri 'https://ipapi.co/json/' -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
            $ort = $geo.city
            if (-not $ort) { $ort = $geo.region }
        } catch {
            $ort = Read-SysPilotInput 'Stadt oder PLZ fuer Reparaturladen-Suche'
        }
    }
    if (-not $ort) { return @() }
    $ergebnisse = @()
    try {
        $query = [Uri]::EscapeDataString("Computer Reparatur $ort")
        $url = "https://duckduckgo.com/?q=$query&format=json&no_html=1"
        $resp = Invoke-RestMethod -Uri $url -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        if ($resp.Results) {
            foreach ($r in ($resp.Results | Select-Object -First 8)) {
                $ergebnisse += @{ Name = $r.Text; Url = $r.FirstURL; Beschreibung = $r.Result; Ort = $ort }
            }
        }
    } catch { }
    if ($ergebnisse.Count -eq 0) {
        $ergebnisse += @{ Name = "Reparaturlaeden in $ort suchen"; Url = "https://duckduckgo.com/?q=$([Uri]::EscapeDataString('Computer Reparatur ' + $ort))"; Beschreibung = "Manuelle Suche im Browser"; Ort = $ort }
    }
    return $ergebnisse
}

# ---------- Rate-Limiting fuer intensive Pruefungen ----------
function Test-SysPilotHealthRateLimit {
    param([string]$Modus = 'NORMAL')
    $state = Get-SysPilotHealthState
    if (-not $state.LetzterPruefung) { return $true }
    try {
        $letzte = [DateTime]::ParseExact($state.LetzterPruefung, 'yyyy-MM-dd HH:mm:ss', $null)
        $minutenSeit = ((Get-Date) - $letzte).TotalMinutes
        $intervall = if ($Modus -in @('WARNUNG','KRITISCH')) { 2 } else { 5 }
        return $minutenSeit -ge $intervall
    } catch { return $true }
}

# ---------- Thermalpaste-Alter schaetzen ----------
function Get-SysPilotThermalPasteHinweis {
    param([int]$CpuTemp, [int]$SystemAlterJahre = 0)
    if ($SystemAlterJahre -ge 2 -and $CpuTemp -ge 75) { return $true }
    if ($CpuTemp -ge 85) { return $true }
    return $false
}

# ---------- SSD Ausfallvorhersage + Backup-Erinnerung ----------
function Get-SysPilotSsdBackupReminder {
    param([array]$SsdHealth)
    $reminder = @{ Benoetigt = $false; Text = ''; Dringlichkeit = 'NORMAL' }
    foreach ($ssd in $SsdHealth) {
        if ($ssd.Gesundheit -ne 'Gesund') {
            $reminder.Benoetigt = $true
            $reminder.Text = "SSD '$($ssd.Name)' meldet Gesundheit: $($ssd.Gesundheit) - SOFORT Daten sichern!"
            $reminder.Dringlichkeit = 'KRITISCH'
        }
    }
    if (-not $reminder.Benoetigt -and $SsdHealth.Count -gt 0) {
        $reminder.Benoetigt = $true
        $reminder.Text = "Regelmaessige Datensicherung empfohlen (SSD: $($SsdHealth[0].Name))"
        $reminder.Dringlichkeit = 'NORMAL'
    }
    return $reminder
}



# ---------- Hintergrundmonitor fuer Health (sanft, nicht belastend) ----------
function Invoke-SysPilotHealthBackgroundMonitor {
    <# 
      Sanfter Hintergrund-Monitor fuer Health.
      Laeuft nicht dauerhaft aktiv, sondern als geplante Aufgabe oder regelmaessig.
      Nur bei abnormen Werten: Warnsignal im GUI, detaillierte Tests vorschlagen.
    #>
    param([string]$Modus = 'NORMAL', [int]$IntervallMinuten = 10)
    
    $state = Get-SysPilotHealthState
    
    # Rate-Limiting: Nur alle X Minuten rechecken
    if ($state.LetzterPruefung) {
        $letzte = [DateTime]::ParseExact($state.LetzterPruefung, 'yyyy-MM-dd HH:mm:ss', $null)
        $minutenSeit = ((Get-Date) - $letzte).TotalMinutes
        if ($minutenSeit -lt $IntervallMinuten) {
            return $state.Modus
        }
    }
    
    # Wenn im Normal-Modus, schnell pruefen (nur eine Kurzkontrolle)
    if ($Modus -eq 'NORMAL') {
        $quickCheck = Invoke-SysPilotHealthCheck -Quick
        if ($quickCheck.Modus -eq 'WARNUNG' -or $quickCheck.Modus -eq 'KRITISCH') {
            # Wurde sofort auf abnorm gewechselt
            $state.Modus = $quickCheck.Modus
            Save-SysPilotHealthState -State $state
            # GUI ueber Warnung informieren
            Write-SysPilotLog "HEALTH: WICHTIGERWEISE auf $($quickCheck.Modus) gewechselt - Pruefung empfohlen" -Level 'WARN'
            return $quickCheck.Modus
        }
        $state.Modus = 'NORMAL'
        $state.LetzterPruefung = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Save-SysPilotHealthState -State $state
        Write-SysPilotLog "HEALTH: Hintergrundpruefung abgeschlossen (NORMAL)" -Level 'DEBUG'
        return 'NORMAL'
    }
    
    # Im WARNUNG/KRITISCH-Modus: detailierter Check + Infos
    $detailed = Invoke-SysPilotHealthCheck
    if ($detailed.Modus -eq 'NORMAL') {
        $state.Modus = 'NORMAL'
        $state.LetzterPruefung = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Save-SysPilotHealthState -State $state
        Write-SysPilotLog "HEALTH: Hintergrundpruefung abgeschlossen (zurueck auf NORMAL)" -Level 'DEBUG'
        return 'NORMAL'
    }
    
    # Bei abnormen Werten: Warnsignal setzen
    $state.Modus = $detailed.Modus
    $state.LetzterPruefung = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Save-SysPilotHealthState -State $state
    
    # Details sammeln fuer GUI
    $warnungen = @()
    if ($detailed.CpuTemp -and $detailed.CpuTemp -ge 75) {
        $warnungen += @{ Komponente = 'CPU'; Wert = $detailed.CpuTemp; Einheit = ' Grad C'; Schweregrad = 'WARNUNG'; Text = "CPU-Temperatur: $($detailed.CpuTemp) Grad C (grenzwertig)" }
    }
    if ($detailed.SsdHealth.Count -gt 0 -and $detailed.SsdHealth[0].Gesundheit -ne 'Gesund') {
        $warnungen += @{ Komponente = 'SSD'; Wert = $detailed.SsdHealth[0].Gesundheit; Einheit = ''; Schweregrad = 'KRITISCH'; Text = "SSD-Status: $($detailed.SsdHealth[0].Gesundheit)" }
    }
    if ($detailed.Fans.Count -gt 0) {
        foreach ($fan in $detailed.Fans) {
            if ($fan.Value -lt 600 -or $fan.Value -gt 6000) {
                $warnungen += @{ Komponente = 'Luefter'; Wert = $fan.Value; Einheit = 'RPM'; Schweregrad = 'WARNUNG'; Text = "Luefter '$($fan.SensorName)' liefert ungewoehnlich ($([math]::Round($fan.Value)) RPM)" }
            }
        }
    }
    
    if ($warnungen.Count -gt 0) {
        Write-SysPilotLog "HEALTH: Warnungen im Hintergrund erkannt" -Level 'WARN'
        # Lade Hyperlink-Infos fuer Reparatur-HowTos (mit Fehlerbehandlung fuer Netzwerkausfaelle)
        $howtos = @()
        foreach ($w in $warnungen) {
            try {
                $prompt = "$($w.Komponente) $($w.Wert)$($w.Einheit)"
                $uebersicht = Get-SysPilotHealthUrsachen -Komponente $w.Komponente -Wert $w.Wert -Einheit $w.Einheit
                $links = Get-SysPilotRepairHowtosOnline -Suchbegriff $prompt -ErrorAction Stop
                $howtos += [PSCustomObject]@{
                    Komponente = $w.Komponente
                    Warnung = $w.Text
                    Ursachen = $uebersicht.Ursachen
                    HowTos = $uebersicht.HowTos
                    Links = $links
                }
            } catch {
                Write-SysPilotLog "HEALTH: Fehler beim Laden der Reparatur-HowTos: $($_.Exception.Message)" -Level 'WARN'
            }
        }
        # Speichere Warnungen fuer GUI
        $state.Warnungen = $state.Warnungen + $warnungen
        Save-SysPilotHealthState -State $state
        Write-SysPilotLog "HEALTH: Warnungen gespeichert in health-state.json" -Level 'INFO'

        # Teste auch nahegelegene Reparaturlaeden (mit Fehlerbehandlung fuer Netzwerkausfaelle)
        try {
            $shops = Get-SysPilotNearbyRepairShops -ErrorAction Stop
            $state.Reparaturlaeden = $shops
            Save-SysPilotHealthState -State $state
            Write-SysPilotLog "HEALTH: Reparaturlaeden gesucht: $($shops.Count) gefunden" -Level 'INFO'
        } catch {
            Write-SysPilotLog "HEALTH: Fehler bei Reparaturladen-Suche: $($_.Exception.Message)" -Level 'WARN'
        }
    }
    
    Write-SysPilotLog "HEALTH: Hintergrundmonitor abgeschlossen (Modus: $Modus)" -Level 'DEBUG'
    return $state.Modus
}


Export-ModuleMember -Function Invoke-SysPilotHealthCheck, Get-SysPilotHealthUrsachen, Get-SysPilotErsatzteile, `
    Get-SysPilotHealthSymbol, Get-SysPilotHealthState, Get-SysPilotLhmSensors, Get-SysPilotSsdHealth, `
    Get-SysPilotFanSpeeds, Get-SysPilotCpuTemperatureSimple, Test-SysPilotFanUnrund, `
    Get-SysPilotRepairHowtosOnline, Get-SysPilotNearbyRepairShops, Test-SysPilotHealthRateLimit, `
    Get-SysPilotThermalPasteHinweis, Get-SysPilotSsdBackupReminder, Invoke-SysPilotHealthBackgroundMonitor