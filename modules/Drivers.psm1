# SysPilot - Treiber-Werkstatt
#Requires -Version 5.1
# Problemgeraete finden, Treiber-Inventar, veraltete Treiber markieren,
# Problemgeraete neu starten, Rollback-Anleitung.
# EHRLICH: Driver-Downloads aus Herstellernetzwerken sind ohne stabile API
# nicht zuverlaessig moeglich - dafuer gibt es die Rollback-Anleitung
# (Geraetemanager -> Treiber -> "Vorheriger Treiber") und den Hinweis auf
# Windows Update. Alle aendernden Aktionen nur mit Bestaetigung + Admin.

$script:DriverErrorMeanings = @{
    1  = 'Geraet nicht korrekt konfiguriert'
    3  = 'Treiber defekt oder fehlt'
    10 = 'Geraet kann nicht starten'
    12 = 'Nicht genuegend freie Ressourcen'
    22 = 'Geraet deaktiviert'
    24 = 'Geraet wird nicht erkannt (Plug & Play-Problem)'
    28 = 'Treiber nicht installiert'
    31 = 'Nicht genuegend freie Ressourcen (Konflikt)'
    37 = 'Windows kann das Geraet nicht starten'
    39 = 'Treiber fehlt oder ist beschaedigt'
    42 = 'Nicht genuegend freie Ressourcen (Konfiguration)'
    43 = 'Geraet ist deaktiviert'
    45 = 'Noch nicht bereit (OOBE/Updates)'
    47 = 'Geraet meldet Fehler gegenüber Windows'
    52 = 'Signaturpruefung fehlgeschlagen (unsigned Driver)'
}

function Get-SysPilotDriverProblemDevices {
    <# Problemgeraete: Win32_PnPEntity mit ConfigManagerErrorCode <> 0. #>
    $devices = @()
    try {
        $devices = @(Get-CimInstance Win32_PnPEntity -ErrorAction Stop |
            Where-Object { $_.ConfigManagerErrorCode -and $_.ConfigManagerErrorCode -ne 0 })
    } catch { }
    $result = @()
    foreach ($dev in $devices) {
        $code = [int]$dev.ConfigManagerErrorCode
        $meaning = if ($script:DriverErrorMeanings.ContainsKey($code)) { $script:DriverErrorMeanings[$code] } else { "Fehlercode $code" }
        $result += [PSCustomObject]@{
            Name       = $dev.Name
            DeviceID   = $dev.DeviceID
            PNPDeviceID= $dev.PNPDeviceID
            Class      = $dev.PNPClass
            ErrorCode  = $code
            Meaning    = $meaning
        }
    }
    $result | Sort-Object ErrorCode
}

function Get-SysPilotDriverInventory {
    <# Treiber-Inventar aus Win32_PnPSignedDriver (lokalisiert unabhaengig). #>
    $drivers = @()
    try {
        $drivers = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop |
            Where-Object { $_.DeviceName -and $_.DriverVersion } |
            Sort-Object DriverDate -Descending |
            Select-Object -First 50 |
            ForEach-Object {
                [PSCustomObject]@{
                    DeviceName    = $_.DeviceName
                    Manufacturer  = $_.Manufacturer
                    DriverVersion = $_.DriverVersion
                    DriverDate    = if ($_.DriverDate) { ([Management.ManagementDateTimeConverter]::ToDateTime($_.DriverDate)).ToString('yyyy-MM-dd') } else { 'n/a' }
                    InfName       = $_.InfName
                }
            })
    } catch { }
    $drivers
}

function Test-SysPilotDriverOutdated {
    <# Markiert Treiber mit DriverDate aelter als 3 Jahre. #>
    $cutoff = (Get-Date).AddYears(-3)
    $outdated = @()
    try {
        $outdated = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop |
            Where-Object { $_.DriverDate } |
            ForEach-Object {
                $dt = [Management.ManagementDateTimeConverter]::ToDateTime($_.DriverDate)
                if ($dt -lt $cutoff) {
                    [PSCustomObject]@{
                        DeviceName    = $_.DeviceName
                        DriverVersion = $_.DriverVersion
                        DriverDate    = $dt.ToString('yyyy-MM-dd')
                        AgeDays       = [math]::Round(((Get-Date) - $dt).TotalDays)
                        Manufacturer  = $_.Manufacturer
                    }
                }
            } |
            Sort-Object AgeDays -Descending |
            Select-Object -First 30)
    } catch { }
    $outdated
}

function Invoke-SysPilotDriverRestartDevice {
    <# Startet ein Problemgeraet neu (pnputil /restart-device), nur mit Bestaetigung + Admin. #>
    param([Parameter(Mandatory)]$Device)
    if (-not (Assert-SysPilotAdmin)) { return }
    if (-not (Confirm-SysPilot "Geraet '$($Device.Name)' neu starten?")) { return }
    $id = $Device.PNPDeviceID
    if (-not $id) { $id = $Device.DeviceID }
    & pnputil /restart-device "$id" 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  [OK] $($Device.Name) neu gestartet." -ForegroundColor Green
        Write-SysPilotLog "Treiber-Werkstatt: Geraet neu gestartet ($id)"
    } else {
        Write-Host "  [!] Neustart fehlgeschlagen (Exit $LASTEXITCODE)." -ForegroundColor Yellow
    }
}

function Invoke-SysPilotDriverRollbackGuide {
    <# Rollback ist in Windows nur manuell moeglich (aelterer Treiber muss im
       Treiberstore vorhanden sein). Gibt eine klare Schritt-fuer-Schritt-Anleitung
       und oeffnet optional den Geraetemanager. #>
    Write-Host 'Rollback in Windows (manuell, sicher):' -ForegroundColor Cyan
    Write-Host '  1. Win+X -> Geraetemanager (devmgmt.msc)' -ForegroundColor Gray
    Write-Host '  2. Problemgeraet doppelklicken -> Reiter "Treiber"' -ForegroundColor Gray
    Write-Host '  3. Button "Vorheriger Treiber" (Rollback) - geht nur, wenn ein' -ForegroundColor Gray
    Write-Host '     aelterer Treiber noch im Treiberstore liegt' -ForegroundColor Gray
    Write-Host '  4. Alternativ: Treiber deinstallieren und Windows neu starten -' -ForegroundColor Gray
    Write-Host '     Windows sucht dann einen passenden Treiber (Windows Update)' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  Hinweis: Aktuelle Treiber ueber Windows Update prüfen:' -ForegroundColor Yellow
    Write-Host '  Einstellungen -> Windows Update -> Optionale Updates -> Treiber' -ForegroundColor DarkGray
    if (Confirm-SysPilot 'Geraetemanager jetzt oeffnen?') {
        Start-Process 'devmgmt.msc'
    }
}

function Get-SysPilotDriverMissingComponents {
    <# Prueft deterministisch System-Komponenten (DirectX, VC++ Runtimes).
       Keine Downloads - nur Statusanzeige. #>
    $result = @()

    # DirectX: HKLM:\SOFTWARE\Microsoft\DirectX
    # Ab DirectX 11 gibt es keinen zentralen Versionsschluessel - daher
    # ehrliche Statusmeldung statt erfundener Werte.
    $dxKey = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\DirectX' -Name Version -ErrorAction SilentlyContinue
    if ($dxKey -and $dxKey.Version) {
        $result += [PSCustomObject]@{ Name = 'DirectX'; Status = "Version $($dxKey.Version) registriert"; Details = 'Registry-Check' }
    } else {
        $result += [PSCustomObject]@{ Name = 'DirectX'; Status = 'Kein zentraler Versionsschluessel'; Details = 'Ab DirectX 11 normal - Pruefung ueber dxdiag.exe moeglich' }
    }

    # Visual C++ Runtimes: Uninstall-Eintraege mit "Visual C++"
    $vcPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $vcCount = 0
    foreach ($p in $vcPaths) {
        try {
            $vcCount += @(Get-ItemProperty -Path $p -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -match 'Visual C\+\+' }).Count
        } catch { }
    }
    if ($vcCount -gt 0) {
        $result += [PSCustomObject]@{ Name = 'Visual C++ Runtimes'; Status = "$vcCount Pakete installiert"; Details = 'Uninstall-Registry' }
    } else {
        $result += [PSCustomObject]@{ Name = 'Visual C++ Runtimes'; Status = 'Keine Eintraege gefunden'; Details = 'Pruefung ueber Uninstall-Registry' }
    }

    $result
}

# =======================================================================
# TREIBER-QUELLEN (nach SDI-Analyse):
#  - Windows Update COM-API (legitim, signierte Treiber, installierbar)
#  - Microsoft Update Catalog (Katalog-Suche per Hardware-ID, .cab-Download
#    ueber Browser - wie SDIs "Search Microsoft Update Catalog for HardwareID")
#  SDI DriverPacks (SamLab-Torrents) werden bewusst NICHT nachgebaut:
#  proprietaeres Repack-Format, Torrent-Quellen, kein klares Lizenzmodell.
# =======================================================================

function Get-SysPilotWUDriverUpdates {
    <# Listet per Windows-Update-API verfügbare Treiber-Updates.
       Legitime Quelle: Microsoft Update (signierte Treiber). #>
    $updates = @()
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $result = $searcher.Search("IsInstalled=0 and Type='Driver'")
        foreach ($u in $result.Updates) {
            $updates += [PSCustomObject]@{
                Title          = $u.Title
                DriverModel    = $u.DriverModel
                DeviceCategory = $u.DeviceCategory
            }
        }
    } catch {
        Write-Host "  [!] Windows-Update-Suche fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    $updates
}

function Install-SysPilotWUDriverUpdate {
    <# Laedt und installiert ein Windows-Update-Treiber-Update.
       Nur nach Bestaetigung; bricht bei EULA ablehnend ab. #>
    param([Parameter(Mandatory)]$Update)
    if (-not (Assert-SysPilotAdmin)) { return }
    if (-not (Confirm-SysPilot "Treiber-Update installieren?`n  $($Update.Title)")) { return }
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $result = $searcher.Search("IsInstalled=0 and Type='Driver'")
        $match = $null
        foreach ($u in $result.Updates) { if ($u.Title -eq $Update.Title) { $match = $u; break } }
        if (-not $match) { Write-Host '  [!] Update nicht mehr gefunden.' -ForegroundColor Yellow; return }
        if (-not $match.EulaAccepted) { $match.AcceptEula() | Out-Null }
        Write-Host '  Lade Update herunter ...' -ForegroundColor Cyan
        $dl = $session.CreateUpdateDownloader()
        $dl.Updates = $result.Updates | Where-Object { $_.Title -eq $Update.Title }
        $dlRes = $dl.Download()
        if ($dlRes.ResultCode -ne 2) { Write-Host "  [!] Download fehlgeschlagen (Code $($dlRes.ResultCode))." -ForegroundColor Red; return }
        $inst = $session.CreateUpdateInstaller()
        $inst.Updates = $result.Updates | Where-Object { $_.Title -eq $Update.Title }
        $instRes = $inst.Install()
        if ($instRes.ResultCode -eq 2) {
            Write-Host '  [OK] Treiber-Update installiert.' -ForegroundColor Green
            Write-SysPilotLog "WU-Treiber installiert: $($Update.Title)"
        } else {
            Write-Host "  [!] Installation fehlgeschlagen (Code $($instRes.ResultCode))." -ForegroundColor Red
            Write-SysPilotLog "WU-Treiber-Installation fehlgeschlagen: $($Update.Title) (Code $($instRes.ResultCode))"
        }
    } catch {
        Write-Host "  [!] Fehler: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Get-SysPilotDeviceHardwareIds {
    <# HardwareIDs fuer Problemgeraete (DEVPKEY_Device_HardwareIds). #>
    $devices = @(Get-SysPilotDriverProblemDevices)
    $result = @()
    foreach ($dev in $devices) {
        $ids = @()
        try {
            $pnp = Get-PnpDevice -ErrorAction Stop | Where-Object { $_.InstanceId -eq $dev.PNPDeviceID } | Select-Object -First 1
            if ($pnp) {
                $prop = Get-PnpDeviceProperty -InstanceId $pnp.InstanceId -KeyName 'DEVPKEY_Device_HardwareIds' -ErrorAction Stop
                $ids = @($prop.Data) | Where-Object { $_ -match '^(PCI|USB|HID|ACPI|SWD|BTH)' } | Select-Object -First 3
            }
        } catch { }
        $result += [PSCustomObject]@{
            Name        = $dev.Name
            DeviceID    = $dev.DeviceID
            PNPDeviceID = $dev.PNPDeviceID
            HardwareIds = $ids
        }
    }
    $result
}

function Find-SysPilotCatalogDrivers {
    <# Sucht den Microsoft Update Catalog nach einer Hardware-ID.
       Gibt Titel, Datum, Version, Groesse und Detail-URL zurueck.
       Download selbst laeuft ueber den Browser (Katalog-Mechanismus). #>
    param([Parameter(Mandatory)][string]$Query)
    $results = @()
    $url = 'https://www.catalog.update.microsoft.com/Search.aspx?q=' + [Uri]::EscapeDataString($Query)
    try {
        $html = (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30).Content
        # Zeilen: <tr id="GUID_R#"> ... goToDetails("GUID") ... Titel ... Datum ... Version ... Groesse
        $rowPattern = '(?s)<tr id="([0-9a-fA-F-]{36})_R\d+".*?goToDetails\("\1"\).*?>([^<]+)</a>.*?C2_R\d+">\s*(.*?)\s*</td>.*?C4_R\d+">\s*(.*?)\s*</td>.*?C5_R\d+">\s*(.*?)\s*</td>.*?C6_R\d+">.*?<span[^>]*>([^<]+)</span>'
        foreach ($m in [regex]::Matches($html, $rowPattern)) {
            $guid = $m.Groups[1].Value
            $results += [PSCustomObject]@{
                Guid    = $guid
                Title   = $m.Groups[2].Value.Trim()
                Product = ($m.Groups[3].Value -replace '\s+', ' ').Trim()
                Date    = $m.Groups[4].Value.Trim()
                Version = $m.Groups[5].Value.Trim()
                Size    = $m.Groups[6].Value.Trim()
                Url     = "https://www.catalog.update.microsoft.com/UpdateDetail.aspx?updateid=$guid"
            }
        }
        if ($results.Count -eq 0) {
            # Fallback: nur GUIDs + Titel (robustere, einfachere Regex)
            $simple = '(?s)goToDetails\("([0-9a-fA-F-]{36})"\).*?class="contentTextItemSpacerNoBreakLink">\s*([^<]+)'
            foreach ($m in [regex]::Matches($html, $simple)) {
                $results += [PSCustomObject]@{
                    Guid = $m.Groups[1].Value; Title = $m.Groups[2].Value.Trim()
                    Product = ''; Date = ''; Version = ''; Size = ''
                    Url = "https://www.catalog.update.microsoft.com/UpdateDetail.aspx?updateid=$($m.Groups[1].Value)"
                }
            }
        }
    } catch {
        Write-Host "  [!] Katalog-Suche fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    # Katalog listet gleiche Treiber in mehreren Sprach-/Paketvarianten:
    # Dedupe nach Titel+Version (erste Variante je Kombination).
    $seen = @{}
    $results | Where-Object {
        $key = "$($_.Title)|$($_.Version)"
        -not $seen.ContainsKey($key) -and ($seen[$key] = $true)
    } | Select-Object -First 25
}

function Show-SysPilotDriverSourcesMenu {
    <# Untermenue: Treiber-Quellen (WU-Updates, MS-Katalog, SDI-Info). #>
    while ($true) {
        $items = @(
            @{ Label = 'Windows-Update-Treiber suchen';        Color = 'Green';    Tag = 'wu' }
            @{ Label = 'Treiber-Update installieren (WU)';    Color = 'White';    Tag = 'wuinstall' }
            @{ Label = 'MS Update Catalog per Hardware-ID';    Color = 'White';    Tag = 'catalog' }
            @{ Label = 'DriversCloud Herstellerseite (Browser)'; Color = 'White'; Tag = 'dcweb' }
            @{ Label = 'Ueber SDI DriverPacks (Info)';         Color = 'DarkGray'; Tag = 'sdiinfo' }
            @{ Label = 'SDI: neueste Version laden + installieren'; Color = 'Green'; Tag = 'sdidownload' }
            @{ Label = 'Zurueck';                              Color = 'DarkGray'; Tag = $null }
        )
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'Treiber-Quellen' -Footer 'Pfeiltasten, Enter = ausfuehren, Esc = zurueck'
        if ($null -eq $sel) { return }

        switch ($sel) {
            'wu' {
                Write-Host '  Suche Windows Update nach Treiber-Updates ...' -ForegroundColor Cyan
                $ups = @(Get-SysPilotWUDriverUpdates)
                if ($ups.Count -eq 0) { Write-Host '  [OK] Keine Treiber-Updates ueber Windows Update verfuegbar.' -ForegroundColor Green }
                foreach ($u in $ups) {
                    Write-Host ("  {0} | {1} | {2}" -f $u.Title, $u.DriverModel, $u.DeviceCategory) -ForegroundColor White
                }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'wuinstall' {
                Write-Host '  Lade Windows-Update-Treiberliste ...' -ForegroundColor Cyan
                $ups = @(Get-SysPilotWUDriverUpdates)
                if ($ups.Count -eq 0) { Write-Host '  Keine installierbaren Treiber-Updates gefunden.' -ForegroundColor Green; Read-SysPilotChoice 'Weiter' | Out-Null; continue }
                $uItems = @()
                foreach ($u in $ups) { $uItems += @{ Label = $u.Title; Color = 'White'; Tag = $u } }
                $uItems += @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = $null }
                $pick = Show-SysPilotArrowMenu -Items $uItems -Title 'Treiber-Update waehlen' -Footer 'Enter = installieren, Esc = zurueck'
                if ($null -ne $pick) { Install-SysPilotWUDriverUpdate -Update $pick }
            }
            'catalog' {
                $hw = @(Get-SysPilotDeviceHardwareIds)
                if ($hw.Count -eq 0) {
                    Write-Host '  Keine Problemgeraete mit Hardware-ID gefunden.' -ForegroundColor Yellow
                    $manual = Read-SysPilotChoice 'Hardware-ID manuell eingeben (z.B. PCI\VEN_1002&DEV_164C), leer = abbrechen'
                    if (-not $manual) { Read-SysPilotChoice 'Weiter' | Out-Null; continue }
                    $results = @(Find-SysPilotCatalogDrivers -Query $manual)
                } else {
                    $hItems = @()
                    foreach ($d in $hw) {
                        $hid = if ($d.HardwareIds.Count -gt 0) { $d.HardwareIds[0] } else { $d.DeviceID }
                        $hItems += @{ Label = "$($d.Name) [$hid]"; Color = 'White'; Tag = $hid }
                    }
                    $hItems += @{ Label = 'Hardware-ID manuell eingeben'; Color = 'DarkGray'; Tag = 'MANUAL' }
                    $hItems += @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = $null }
                    $pick = Show-SysPilotArrowMenu -Items $hItems -Title 'Geraet fuer Katalog-Suche waehlen' -Footer 'Enter = suchen, Esc = zurueck'
                    if ($null -eq $pick) { continue }
                    $query = if ($pick -eq 'MANUAL') { Read-SysPilotChoice 'Hardware-ID eingeben' } else { $pick }
                    if (-not $query) { continue }
                    Write-Host "  Katalog-Suche nach: $query" -ForegroundColor Cyan
                    $results = @(Find-SysPilotCatalogDrivers -Query $query)
                }
                if ($results.Count -eq 0) { Write-Host '  Keine Katalog-Treffer gefunden.' -ForegroundColor DarkGray }
                foreach ($r in $results) {
                    $info = if ($r.Date) { "$($r.Date) | v$($r.Version) | $($r.Size)" } else { 'Details in Katalog' }
                    Write-Host ("  {0}`n    {1}" -f $r.Title, $info) -ForegroundColor White
                    Write-Host "    $($r.Url)" -ForegroundColor DarkGray
                }
                if ($results.Count -gt 0 -and (Confirm-SysPilot 'Ersten Treffer im Browser oeffnen?')) {
                    Start-Process $results[0].Url
                }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'dcweb' {
                # Problemgeraete mit Hersteller-Info
                $devs = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
                    Where-Object { $_.ConfigManagerErrorCode -ne 0 -and $_.Manufacturer } |
                    Select-Object Name, Manufacturer, DeviceID -First 20)
                if ($devs.Count -eq 0) {
                    Write-Host '  Keine Problemgeraete mit Herstellerangabe gefunden.' -ForegroundColor Yellow
                    $man = Read-SysPilotChoice 'Hersteller manuell eingeben (z.B. Realtek), leer = abbrechen'
                    if (-not $man) { Read-SysPilotChoice 'Weiter' | Out-Null; continue }
                    $url = Find-SysPilotDriversCloudManufacturer -Manufacturer $man
                    if ($url) { Write-Host "  $url" -ForegroundColor DarkGray; if (Confirm-SysPilot 'Seite im Browser oeffnen?') { Start-Process $url } }
                    else { Write-Host '  Hersteller auf DriversCloud nicht gefunden - Index wird geoeffnet.' -ForegroundColor Yellow; if (Confirm-SysPilot 'Treiber-Index oeffnen?') { Start-Process 'https://www.driverscloud.com/en/drivers' } }
                    Read-SysPilotChoice 'Weiter' | Out-Null
                    continue
                }
                $dItems = @()
                foreach ($d in $devs) { $dItems += @{ Label = "$($d.Name) [$($d.Manufacturer)]"; Color = 'White'; Tag = $d } }
                $dItems += @{ Label = 'Hersteller manuell eingeben'; Color = 'DarkGray'; Tag = 'MANUAL' }
                $dItems += @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = $null }
                $pick = Show-SysPilotArrowMenu -Items $dItems -Title 'Geraet fuer DriversCloud-Suche' -Footer 'Enter = Seite oeffnen, Esc = zurueck'
                if ($null -eq $pick) { continue }
                $manu = if ($pick -eq 'MANUAL') { Read-SysPilotChoice 'Hersteller eingeben' } else { $pick.Manufacturer }
                if (-not $manu) { continue }
                $url = Find-SysPilotDriversCloudManufacturer -Manufacturer $manu
                if ($url) {
                    Write-Host "  DriversCloud: $url" -ForegroundColor Green
                    if (Confirm-SysPilot 'Hersteller-Treiberseite im Browser oeffnen?') { Start-Process $url }
                } else {
                    Write-Host "  '$manu' nicht in DriversCloud-Index gefunden." -ForegroundColor Yellow
                    if (Confirm-SysPilot 'DriversCloud-Treiberindex oeffnen?') { Start-Process 'https://www.driverscloud.com/en/drivers' }
                }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'sdidownload' { Install-SysPilotSdiLatest }
            'sdiinfo' {
                Write-Host '  SDI (Snappy Driver Installer, SamLab) analysiert:' -ForegroundColor Cyan
                Write-Host '  - DriverPacks: SamLab-eigene Treiber-Repacks als .7z-Archive' -ForegroundColor Gray
                Write-Host '  - Download: integrierter BitTorrent-Client + HTTP-Update-Session' -ForegroundColor Gray
                Write-Host '  - Quellen: Torrents (sdi.com.ru), RSS-Feed, USB-Wizard, Index-DB' -ForegroundColor Gray
                Write-Host '  - MS-Katalog-Suche per Hardware-ID (von uns uebernommen)' -ForegroundColor Gray
                Write-Host ''
                Write-Host '  Warum NICHT nachgebaut:' -ForegroundColor Yellow
                Write-Host '  DriverPacks sind proprietaere Repack-Archive; der Download laeuft ueber' -ForegroundColor Gray
                Write-Host '  inoffizielle Torrent-Quellen ohne klares Lizenzmodell. Stattdessen nutzt' -ForegroundColor Gray
                Write-Host '  SysPilot die legitimen Quellen: Windows Update API + MS Update Catalog.' -ForegroundColor Gray
                Write-Host ''
                Write-Host '  SDI selbst starten (falls installiert):' -ForegroundColor Cyan
                $sdi = Get-SysPilotSdiExe
                if ($sdi) {
                    Write-Host "    Gefunden: $sdi" -ForegroundColor Green
                    if (Confirm-SysPilot 'SDI jetzt starten?') { Start-Process $sdi }
                } else {
                    Write-Host '    Keine SDI-Installation gefunden (Registry/Pfade).' -ForegroundColor DarkGray
                }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
        }
    }
}

function Get-SysPilotSdiExe {
    <# Erkennt eine SDI-Installation (Snappy Driver Installer, SamLab). #>
    try {
        $apps = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match 'Snappy Driver|SDI' }
        foreach ($app in $apps) {
            foreach ($prop in @('InstallLocation', 'DisplayIcon')) {
                $val = $app.$prop
                if (-not $val) { continue }
                $val = ($val -split ',')[0].Trim('"')
                if ($val -and (Test-Path $val -PathType Leaf) -and (Test-SysPilotLaunchablePath $val)) { return $val }
                if ($val -and (Test-Path $val -PathType Container)) {
                    $exe = Get-ChildItem -Path $val -Filter 'SDI*.exe' -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -match '64|drv' } | Select-Object -First 1
                    if ($exe) { return $exe.FullName }
                }
            }
        }
    } catch { }
    $paDir = $null
    try { $paDir = Get-SysPilotPortableAppsDir } catch { }
    $dirs = @()
    if ($paDir) { $dirs += Get-ChildItem $paDir -Directory -Filter 'SDI*' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName } }
    $dirs += 'C:\Program Files\SDI', 'C:\Program Files (x86)\SDI',
             (Join-Path $env:LOCALAPPDATA 'Programs\SDI')
    foreach ($d in $dirs) {
        if (-not (Test-Path $d)) { continue }
        # Bevorzugt 64-bit/treiberdir-namen; neuere Releases: SDI_x64_Rxxxx.exe
        $exe = Get-ChildItem -Path $d -Recurse -Filter 'SDI*.exe' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch 'unins|uninstall|update' } |
            Sort-Object { if ($_.Name -match 'x64|64') { 0 } elseif ($_.Name -match 'drv') { 1 } else { 2 } } |
            Select-Object -First 1
        if ($exe) { return $exe.FullName }
    }
    return $null
}

function Get-SysPilotSdiLatestRelease {
    <# Ermittelt die neueste SDI-Lite-Version von der offiziellen
       Download-Seite (sdi-tool.org). Gibt URL + Versions-String zurueck.
       SDI Full ist nur per Torrent erhaeltlich und wird nicht angeboten. #>
    try {
        $html = (Invoke-WebRequest -Uri 'https://sdi-tool.org/download/' -UseBasicParsing -TimeoutSec 30).Content
        # Alle Direkt-Download-Links: SDI_R<nummer>.7z oder SDI_R<nummer>.zip
        $candidates = @()
        foreach ($m in [regex]::Matches($html, 'https?://[^\s"''<>]+SDI_R(\d+)\.(7z|zip)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
            $num = [int]$m.Groups[1].Value
            $candidates += [PSCustomObject]@{ Rev = $num; Url = $m.Value }
        }
        # Relativ-Links ../releases/SDI_Rxxxx.zip ebenfalls pruefen
        foreach ($m in [regex]::Matches($html, '(?:\.\./)?releases/SDI_R(\d+)\.zip', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
            $num = [int]$m.Groups[1].Value
            $candidates += [PSCustomObject]@{ Rev = $num; Url = "https://sdi-tool.org/releases/SDI_R$num.zip" }
        }
        if ($candidates.Count -eq 0) { return $null }
        $best = $candidates | Sort-Object Rev -Descending | Select-Object -First 1
        # Release-Nummer ist R<JJ><MM> (z.B. R2601); lesbare Version aus dem
        # Seitentext "x.y.z (R2601)" ableiten, sonst nur R-Nummer anzeigen.
        $ver = "R$($best.Rev)"
        $label = [regex]::Match($html, '(\d+\.\d+\.\d+)\s*\(R' + $best.Rev + '\)')
        if ($label.Success) { $ver = "$($label.Groups[1].Value) (R$($best.Rev))" }
        [PSCustomObject]@{ Rev = $best.Rev; Version = $ver; Url = $best.Url }
    } catch {
        Write-Host "  [!] Versionsabfrage fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
}

function Get-SysPilot7ZipExe {
    <# Sucht 7-Zip (fuer SDI-Archiv-Extraktion). #>
    $candidates = @(
        'C:\Program Files\7-Zip\7z.exe',
        'C:\Program Files (x86)\7-Zip\7z.exe'
    )
    foreach ($p in $candidates) { if (Test-Path $p) { return $p } }
    $cmd = Get-Command 7z.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Install-SysPilotSdiLatest {
    <# Lädt die neueste SDI-Version (offizielle Seite sdi-tool.org),
       entpackt sie nach %LOCALAPPDATA%\Programs\SDI und startet sie.
       Vollautomatisch nach einer einzigen Bestaetigung; kein Installer
       noetig (SDI ist portabel). SDI Full (Torrent) wird nicht angeboten. #>
    if (-not (Confirm-SysPilot 'Neueste SDI-Version von sdi-tool.org herunterladen und installieren?')) { return }

    $release = Get-SysPilotSdiLatestRelease
    if (-not $release) {
        Write-Host '  [!] Keine SDI-Version gefunden - bitte manuell von sdi-tool.org laden.' -ForegroundColor Yellow
        Read-SysPilotChoice 'Weiter' | Out-Null
        return
    }

    # Bereits aktuelle Version installiert? -> Download ueberspringen
    $existing = Get-SysPilotSdiExe
    if ($existing) {
        $exVer = (Get-Item $existing).VersionInfo.FileVersion
        $exProd = (Get-Item $existing).VersionInfo.ProductVersion
        $installedRev = $null
        foreach ($v in @($exVer, $exProd)) {
            if ($v -match 'R?(\d{4})') { $installedRev = [int]$Matches[1]; break }
        }
        if ($installedRev -eq $release.Rev) {
            Write-Host "  SDI $($release.Version) ist bereits installiert: $existing" -ForegroundColor Green
            if (Confirm-SysPilot 'SDI jetzt starten?') { Start-Process $existing }
            Read-SysPilotChoice 'Weiter' | Out-Null
            return
        }
        Write-Host "  Installiert: $existing (Rev $installedRev) -> Update auf $($release.Version)" -ForegroundColor Cyan
    }

    Write-Host "  Neueste Version: $($release.Version)" -ForegroundColor Cyan
    Write-Host "  Download: $($release.Url)" -ForegroundColor DarkGray

    $tmpDir = Join-Path $env:TEMP ("sdi_dl_" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    $archive = Join-Path $tmpDir ("SDI_R$($release.Rev)." + ($release.Url -replace '.*\.', ''))
    try {
        Write-Host '  Lade Archiv herunter ...' -ForegroundColor Cyan
        if (-not (Save-SysPilotUrlToFile -Uri $release.Url -OutFile $archive -TimeoutSec 300 -Label 'SDI-Archiv')) { throw 'Download fehlgeschlagen' }
        $sizeMB = [math]::Round((Get-Item $archive).Length / 1MB, 1)
        Write-Host "  Download fertig ($sizeMB MB)." -ForegroundColor Green

        # SDI ist portabel -> Installation in das PortableApps-Verzeichnis
        # des Benutzers (OneDrive-Desktop-bewusst, nutzerunabhaengig)
        $paRoot = Get-SysPilotPortableAppsDir
        $target = Join-Path $paRoot 'SDI'
        $backup = $null
        if (Test-Path $target) {
            $backup = "$target.old-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
            Rename-Item $target $backup
            Write-Host "  Vorhandene Installation gesichert nach: $backup" -ForegroundColor DarkGray
        }
        # Hinweis auf aeltere Installation im bisherigen Ziel
        $oldTarget = Join-Path $env:LOCALAPPDATA 'Programs\SDI'
        if ((Test-Path $oldTarget) -and -not $backup) {
            Write-Host "  Hinweis: aeltere SDI-Installation unter $oldTarget bleibt bestehen." -ForegroundColor DarkGray
        }
        New-Item -ItemType Directory -Path $target -Force | Out-Null

        $sevenZip = Get-SysPilot7ZipExe
        if ($sevenZip) {
            Write-Host '  Entpacke mit 7-Zip ...' -ForegroundColor Cyan
            & $sevenZip x $archive "-o$target" -y | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "7-Zip-Extraktion fehlgeschlagen (Code $LASTEXITCODE))" }
        } else {
            Write-Host '  7-Zip nicht gefunden - versuche tar ...' -ForegroundColor Yellow
            tar -xf $archive -C $target
            if ($LASTEXITCODE -ne 0) { throw 'Entpacken fehlgeschlagen (kein 7-Zip/tar)' }
        }

        # SDI-Dateien liegen ggf. in einem Unterordner - eine Ebene hochsuchen.
        # EXE-Namen variieren je nach Release: SDI64-drv.exe (alt),
        # SDI_x64_R2601.exe / SDI_R2601.exe (neu) - priorisiert 64-bit.
        $candidates = Get-ChildItem -Path $target -Recurse -Filter 'SDI*.exe' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch 'unins|uninstall|update' }
        $exe = $candidates |
            Where-Object { $_.Name -match 'x64|64|drv' } |
            Sort-Object { if ($_.Name -match 'x64|64') { 0 } else { 1 } } |
            Select-Object -First 1
        if (-not $exe) { $exe = $candidates | Select-Object -First 1 }
        if (-not $exe) { throw 'SDI-Ausfuehrung nach dem Entpacken nicht gefunden.' }

        Write-Host "  [OK] SDI $($release.Version) installiert: $($exe.FullName)" -ForegroundColor Green
        Write-SysPilotLog "SDI $($release.Version) installiert nach $target"
        if (Confirm-SysPilot 'SDI jetzt starten?') { Start-Process $exe.FullName }
    } catch {
        Write-Host "  [!] Fehler: $($_.Exception.Message)" -ForegroundColor Red
        Write-SysPilotLog "SDI-Installation fehlgeschlagen: $($_.Exception.Message)"
    } finally {
        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Read-SysPilotChoice 'Weiter' | Out-Null
}

function Find-SysPilotDriversCloudManufacturer {
    <# Findet die DriversCloud-Hersteller-Treiberseite zu einem
       Herstellernamen (z.B. "Realtek", "Advanced Micro Devices, Inc.").
       Liest den oeffentlichen Index https://www.driverscloud.com/en/drivers,
       matcht per Alias-Tabelle + Token-Ueberlappung. Gibt URL oder $null. #>
    param([Parameter(Mandatory)][string]$Manufacturer)

    # Alias-Tabelle: Windows-Herstellername -> DriversCloud-Slug-Anfang
    $aliases = @{
        'amd'                          = 'advanced micro devices'
        'advanced micro devices'       = 'amd'
        'nvidia'                       = 'nvidia'
        'intel'                        = 'intel'
        'realtek'                      = 'realtek'
        'microsoft'                    = 'microsoft'
        'hp'                           = 'hp'
        'hewlett'                      = 'hp'
        'hewlett-packard'              = 'hp'
        'hewlett packard'              = 'hp'
        'lenovo'                       = 'lenovo'
        'dell'                         = 'dell'
        'asus'                         = 'asus'
        'gigabyte'                     = 'gigabyte'
        'msi'                          = 'msi'
        'asrock'                       = 'asrock'
        'qualcomm'                     = 'qcom'
        'qualcomm technologies'        = 'qcom'
        'broadcom'                     = 'broadcom'
        'marvell'                      = 'marvell'
        'mediatek'                     = 'mediatek'
        'atheros'                      = 'atheros'
        'killer'                       = 'rivet'
        'steelseries'                  = 'steelseries'
        'logitech'                     = 'logitech'
        'microsoft corporation'        = 'microsoft'
    }

    function Normalize-ManufacturerName([string]$s) {
        ($s.ToLower() -replace '[^a-z0-9 ]', ' ' -replace '\s+', ' ').Trim()
    }

    $norm = Normalize-ManufacturerName $Manufacturer
    if (-not $norm) { return $null }

    try {
        $html = (Invoke-WebRequest -Uri 'https://www.driverscloud.com/en/drivers' -UseBasicParsing -TimeoutSec 30).Content
        # manufacturer/<id>/<slug>
        $links = @{}
        foreach ($m in [regex]::Matches($html, 'manufacturer/(\d+)/([a-z0-9][a-z0-9-]*)')) {
            $links[$m.Groups[2].Value] = "https://www.driverscloud.com/en/drivers/manufacturer/$($m.Groups[1].Value)/$($m.Groups[2].Value)"
        }
        if ($links.Count -eq 0) { return $null }

        # 1) Exakter Alias-Treffer (Slug exakt oder kuerzester passender Slug,
        #    damit z.B. "intel" nicht faelschlich "intellon" trifft)
        if ($aliases.ContainsKey($norm)) {
            $slug = $aliases[$norm]
            $exact = $links.Keys | Where-Object { $_ -eq $slug } | Select-Object -First 1
            if ($exact) { return $links[$exact] }
            $pref = $links.Keys | Where-Object { $_.StartsWith($slug) } | Sort-Object Length | Select-Object -First 1
            if ($pref) { return $links[$pref] }
        }
        # 2) Alias als Substring des Normal-Namens (z.B. "hewlewtt packard" -> hp)
        foreach ($aliasKey in $aliases.Keys) {
            if ($norm -like "*$aliasKey*" -or $aliasKey -like "*$norm*") {
                $slug = $aliases[$aliasKey]
                $exact = $links.Keys | Where-Object { $_ -eq $slug } | Select-Object -First 1
                if ($exact) { return $links[$exact] }
                $pref = $links.Keys | Where-Object { $_.StartsWith($slug) } | Sort-Object Length | Select-Object -First 1
                if ($pref) { return $links[$pref] }
            }
        }
        # 3) Token-Ueberlappung mit Slugs
        $tokens = $norm -split ' ' | Where-Object { $_.Length -ge 3 }
        $best = $null; $bestScore = 0
        foreach ($slug in $links.Keys) {
            $slugNorm = $slug -replace '-', ' '
            $score = 0
            foreach ($t in $tokens) { if ($slugNorm -like "*$t*") { $score++ } }
            if ($score -gt $bestScore) { $bestScore = $score; $best = $slug }
        }
        if ($best -and $bestScore -ge 1) { return $links[$best] }
        return $null
    } catch {
        Write-Host "  [!] DriversCloud-Index nicht erreichbar: $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
}

function Show-SysPilotDriverMenu {
    <# Pfeiltasten-Menue: Inventar, Problemgeraete, veraltete Treiber,
       fehlende Komponenten, Rollback-Anleitung, Treiber-Quellen, zurueck. #>
    $items = @(
        @{ Label = 'Treiber-Inventar (letzte 50)';        Color = 'White';    Tag = 'inventory' }
        @{ Label = 'Problemgeraete finden';              Color = 'Yellow';   Tag = 'problem' }
        @{ Label = 'Veraltete Treiber (>3 Jahre)';        Color = 'White';    Tag = 'outdated' }
        @{ Label = 'Fehlende Komponenten pruefen';        Color = 'White';    Tag = 'missing' }
        @{ Label = 'Problemgeraet neu starten';           Color = 'White';    Tag = 'restart' }
        @{ Label = 'Rollback-Anleitung (aelterer Treiber)'; Color = 'White';   Tag = 'rollback' }
        @{ Label = 'TREIBER-QUELLEN (WU, MS-Katalog, SDI-Info)'; Color = 'Green'; Tag = 'sources' }
        @{ Label = 'Zurueck';                             Color = 'DarkGray'; Tag = $null }
    )

    while ($true) {
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'Treiber-Werkstatt' -Footer 'Pfeiltasten, Enter = ausfuehren, Esc = zurueck'
        if ($null -eq $sel) { return }

        switch ($sel) {
            'inventory' {
                $inv = @(Get-SysPilotDriverInventory)
                if ($inv.Count -eq 0) {
                    Write-Host '  Kein Inventar gefunden.' -ForegroundColor DarkGray
                    if (-not (Test-SysPilotAdmin)) { Write-Host '  Hinweis: vollstaendiges Inventar braucht Administratorrechte (SysPilot als Admin starten).' -ForegroundColor Yellow }
                }
                foreach ($d in $inv) {
                    Write-Host ("  {0} | {1} | {2} | {3}" -f $d.DeviceName, $d.DriverVersion, $d.DriverDate, $d.Manufacturer) -ForegroundColor White
                }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'problem' {
                $probs = @(Get-SysPilotDriverProblemDevices)
                if ($probs.Count -eq 0) { Write-Host '  [OK] Keine Problemgeraete gefunden.' -ForegroundColor Green }
                foreach ($p in $probs) {
                    Write-Host ("  {0} | Fehler {1}: {2}" -f $p.Name, $p.ErrorCode, $p.Meaning) -ForegroundColor Yellow
                }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'outdated' {
                $old = @(Test-SysPilotDriverOutdated)
                if ($old.Count -eq 0) {
                    Write-Host '  [OK] Keine Treiber aelter als 3 Jahre gefunden (oder kein Admin fuer volle Liste).' -ForegroundColor Green
                }
                foreach ($o in $old) {
                    Write-Host ("  {0} | v{1} | {2} ({3} Tage alt)" -f $o.DeviceName, $o.DriverVersion, $o.DriverDate, $o.AgeDays) -ForegroundColor White
                }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'missing' {
                $miss = @(Get-SysPilotDriverMissingComponents)
                foreach ($m in $miss) {
                    Write-Host ("  {0}: {1} ({2})" -f $m.Name, $m.Status, $m.Details) -ForegroundColor White
                }
                Write-Host '  Hinweis: Fehlende Laufzeit-Pakete nur von microsoft.com oder Hersteller-Seiten installieren.' -ForegroundColor DarkGray
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'restart' {
                $probs = @(Get-SysPilotDriverProblemDevices)
                if ($probs.Count -eq 0) { Write-Host '  Keine Problemgeraete zum Neustart.' -ForegroundColor Green; Read-SysPilotChoice 'Weiter' | Out-Null; continue }
                $devItems = @()
                foreach ($p in $probs) { $devItems += @{ Label = "$($p.Name) (Fehler $($p.ErrorCode))"; Color = 'White'; Tag = $p } }
                $devItems += @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = $null }
                $pick = Show-SysPilotArrowMenu -Items $devItems -Title 'Geraet zum Neustart waehlen' -Footer 'Enter = Neustart, Esc = zurueck'
                if ($null -ne $pick) { Invoke-SysPilotDriverRestartDevice -Device $pick }
            }
            'rollback' { Invoke-SysPilotDriverRollbackGuide }
            'sources'  { Show-SysPilotDriverSourcesMenu }
        }
    }
}

Export-ModuleMember -Function Get-SysPilotDriverProblemDevices, Get-SysPilotDriverInventory, Test-SysPilotDriverOutdated, Invoke-SysPilotDriverRestartDevice, Invoke-SysPilotDriverRollbackGuide, Get-SysPilotDriverMissingComponents, Get-SysPilotWUDriverUpdates, Install-SysPilotWUDriverUpdate, Get-SysPilotDeviceHardwareIds, Find-SysPilotCatalogDrivers, Get-SysPilotSdiExe, Get-SysPilotSdiLatestRelease, Get-SysPilot7ZipExe, Install-SysPilotSdiLatest, Find-SysPilotDriversCloudManufacturer, Show-SysPilotDriverSourcesMenu, Show-SysPilotDriverMenu
