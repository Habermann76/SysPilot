# ======================================================================
# SysPilot RootCertificates.psm1 - Windows-Stammzertifikate aktualisieren.
# Laedt das portable UpdateRootCertificates-Tool (asheroto, GitHub,
# GPL-3.0) bei Bedarf nach PortableApps herunter und startet es.
# Das Tool wird NICHT mit SysPilot ausgeliefert - Download zur Laufzeit.
# ======================================================================

function Get-SysPilotRootCertExe {
    <# Sucht die UpdateRootCertificates.exe: PortableApps, Downloads,
       dann lokale Installer-Suche. #>
    $pa = $null
    try { $pa = Get-SysPilotPortableAppsDir } catch { }
    $candidates = @(
        "$pa\UpdateRootCertificates\UpdateRootCertificates.exe",
        "$env:USERPROFILE\Downloads\UpdateRootCertificates.exe"
    ) | Where-Object { $_ }
    foreach ($p in $candidates) { if (Test-Path $p) { return $p } }
    #portableapps rekursiv (z.B. UpdateRootCertificates_<ver>\...)
    if ($pa -and (Test-Path $pa)) {
        $hit = Get-ChildItem $pa -Recurse -Filter 'UpdateRootCertificates.exe' -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

function Get-SysPilotRootCertLatestRelease {
    <# Ermittelt die neueste Version + Download-URL ueber die GitHub-API.
       Fallback: bekannte Version 5.1.1. #>
    $fallback = @{ Version = '5.1.1'; Url = 'https://github.com/asheroto/UpdateRootCertificates/releases/download/5.1.1/UpdateRootCertificates.exe' }
    try {
        $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/asheroto/UpdateRootCertificates/releases/latest' -TimeoutSec 20 -ErrorAction Stop
        $asset = $rel.assets | Where-Object { $_.name -eq 'UpdateRootCertificates.exe' } | Select-Object -First 1
        if ($asset) {
            return @{ Version = $rel.tag_name; Url = $asset.browser_download_url }
        }
    } catch { }
    return $fallback
}

function Install-SysPilotRootCertTool {
    <# Laedt das portable Tool nach PortableApps\UpdateRootCertificates
       und gibt den EXE-Pfad zurueck (oder $null bei Fehler). #>
    $existing = Get-SysPilotRootCertExe
    if ($existing) { return $existing }

    $rel = Get-SysPilotRootCertLatestRelease
    Write-Host "  Neueste Version: $($rel.Version)" -ForegroundColor Cyan
    Write-Host "  Download: $($rel.Url)" -ForegroundColor DarkGray
    if (-not (Confirm-SysPilot 'UpdateRootCertificates herunterladen und in PortableApps ablegen?')) { return $null }

    $pa = Get-SysPilotPortableAppsDir
    $destDir = Join-Path $pa 'UpdateRootCertificates'
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    $dest = Join-Path $destDir 'UpdateRootCertificates.exe'

    if (-not (Save-SysPilotUrlToFile -Uri $rel.Url -OutFile $dest -TimeoutSec 120 -Label 'UpdateRootCertificates')) { return $null }
    if (-not (Test-Path $dest) -or (Get-Item $dest).Length -lt 500KB) {
        Write-Host '  [!] Download unvollstaendig.' -ForegroundColor Red
        Remove-Item $dest -Force -ErrorAction SilentlyContinue
        return $null
    }
    Write-Host "  [OK] Gespeichert: $dest" -ForegroundColor Green
    Write-SysPilotLog "UpdateRootCertificates $($rel.Version) nach $dest geladen"
    return $dest
}

function Start-SysPilotRootCertUpdate {
    <# Stellt sicher, dass das Tool vorhanden ist und startet es
       (mit Admin-Rechten, da es den Zertifikatsspeicher aendert). #>
    $exe = Get-SysPilotRootCertExe
    if (-not $exe) {
        $exe = Install-SysPilotRootCertTool
        if (-not $exe) { return }
    }
    if (-not (Confirm-SysPilot "Stammzertifikate aktualisieren?`n`n$exe`n`nDas Tool aktualisiert die vertrauenswuerdigen Root-ZAs und entfernt disallowed Zertifikate.")) { return }
    try {
        Start-Process -FilePath $exe -Verb RunAs
        Write-SysPilotLog 'UpdateRootCertificates gestartet'
    } catch {
        Write-Host "  [!] Start fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Show-SysPilotRootCertStatus {
    <# Kurzer Status: Tool vorhanden? Version des Windows-Root-Stores. #>
    $exe = Get-SysPilotRootCertExe
    Write-Host ''
    if ($exe) {
        $fi = Get-Item $exe
        Write-Host "  Tool: $exe" -ForegroundColor Green
        Write-Host ("  Datei: {0} MB, Stand {1}" -f [math]::Round($fi.Length/1MB,1), $fi.LastWriteTime.ToString('dd.MM.yyyy')) -ForegroundColor DarkGray
        $rel = (Get-Item $exe).VersionInfo.ProductVersion
        if ($rel) { Write-Host "  Version: $rel" -ForegroundColor DarkGray }
    } else {
        Write-Host '  Tool nicht vorhanden - wird bei Bedarf geladen.' -ForegroundColor Yellow
    }
    try {
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root','LocalMachine')
        $store.Open('ReadOnly')
        Write-Host ("  Root-Zertifikate im Speicher: " + $store.Certificates.Count) -ForegroundColor White
        $store.Close()
    } catch {
        Write-Host '  Root-Store konnte nicht gelesen werden (Admin noetig).' -ForegroundColor DarkGray
    }
    Write-Host ''
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
}

function Show-SysPilotRootCertMenu {
    <# Pfeiltasten-Menue fuer Stammzertifikat-Updates. #>
    while ($true) {
        $exe = Get-SysPilotRootCertExe
        $status = if ($exe) { 'vorhanden' } else { 'nicht geladen' }
        $items = @(
            @{ Label = "Status anzeigen (Tool: $status)";              Color = 'White';  Tag = 'status' }
            @{ Label = 'Stammzertifikate aktualisieren (Tool starten)'; Color = 'Green'; Tag = 'run' }
            @{ Label = 'Tool (neu) herunterladen';                      Color = 'Cyan';   Tag = 'dl' }
            @{ Label = 'Projektseite im Browser oeffnen';               Color = 'DarkGray'; Tag = 'web' }
            @{ Label = 'Zurueck';                                        Color = 'DarkGray'; Tag = $null }
        )
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'SysPilot - Stammzertifikate' -Footer 'Pfeiltasten, Enter = auswaehlen, Esc = zurueck'
        if ($null -eq $sel) { return }
        switch ($sel) {
            'status' { Show-SysPilotRootCertStatus }
            'run'    { Start-SysPilotRootCertUpdate }
            'dl'     {
                $p = Install-SysPilotRootCertTool
                if ($p) { Write-Host "  Bereit: $p" -ForegroundColor Green }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'web'    { Start-Process 'https://github.com/asheroto/UpdateRootCertificates' }
        }
    }
}

Export-ModuleMember -Function Get-SysPilotRootCertExe, Get-SysPilotRootCertLatestRelease,
    Install-SysPilotRootCertTool, Start-SysPilotRootCertUpdate,
    Show-SysPilotRootCertStatus, Show-SysPilotRootCertMenu
