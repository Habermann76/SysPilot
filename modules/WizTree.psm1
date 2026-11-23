# SysPilot - WizTree Integration
#Requires -Version 5.1
# Erkennt eine vorhandene WizTree-Installation (Pfade + Uninstall-Registry),
# loest die offizielle Download-URL dynamisch von diskanalyzer.com auf und
# installiert silent (/VERYSILENT /NORESTART /SUPPRESSMSGBOXES).

$script:WizTreeInstallPaths = @(
    'C:\Program Files\WizTree\WizTree64.exe',
    'C:\Program Files (x86)\WizTree\WizTree64.exe',
    'C:\Program Files (x86)\WizTree\WizTree32.exe',
    "$env:LOCALAPPDATA\WizTree\WizTree64.exe"
)

function Get-SysPilotWizTreeExe {
    <# Liefert den Pfad zur WizTree-Exe oder $null.
       Prueft Uninstall-Registry (InstallLocation/DisplayIcon) und übliche Pfade. #>
    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    try {
        $apps = Get-ItemProperty -Path $regPaths -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match 'WizTree' -or $_.PSChildName -match 'WizTree' }
        foreach ($app in $apps) {
            foreach ($prop in @('InstallLocation', 'DisplayIcon')) {
                $val = $app.$prop
                if (-not $val) { continue }
                $val = ($val -split ',')[0].Trim('"')
                if ($val -and (Test-Path $val -PathType Leaf) -and (Test-SysPilotLaunchablePath $val)) { return $val }
                if ($val -and (Test-Path $val -PathType Container)) {
                    $exe = Get-ChildItem -Path $val -Filter 'WizTree*.exe' -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -match '64' } | Select-Object -First 1
                    if (-not $exe) {
                        $exe = Get-ChildItem -Path $val -Filter 'WizTree*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
                    }
                    if ($exe) { return $exe.FullName }
                }
            }
        }
    } catch { }
    foreach ($p in $script:WizTreeInstallPaths) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Get-SysPilotWizTreeDownloadUrl {
    <# Loest die aktuelle Installer-URL von der offiziellen Seite auf.
       Pattern: files/wiztree_X_YY_setup.exe (hoechste Version gewinnt).
       Fallback: bekannte Version 4.34. #>
    $fallback = 'https://diskanalyzer.com/files/wiztree_4_34_setup.exe'
    try {
        $html = (Invoke-WebRequest -Uri 'https://diskanalyzer.com/download' -UseBasicParsing -TimeoutSec 20).Content
        $matches = [regex]::Matches($html, 'files/wiztree_(\d+)_(\d+)_setup\.exe') |
            ForEach-Object { [pscustomobject]@{ Major = [int]$_.Groups[1].Value; Minor = [int]$_.Groups[2].Value; File = $_.Value } } |
            Sort-Object Major, Minor -Descending | Select-Object -First 1
        if ($matches) { return "https://diskanalyzer.com/$($matches.File)" }
    } catch { }
    return $fallback
}

function Install-SysPilotWizTree {
    <# Installiert WizTree silent. Prueft Erfolg ueber die Exe im Zielpfad. #>
    $existing = Get-SysPilotWizTreeExe
    if ($existing) {
        Write-Host "WizTree ist bereits installiert: $existing" -ForegroundColor Green
        return $true
    }
    if (-not (Confirm-SysPilot 'WizTree von der offiziellen Seite (diskanalyzer.com) herunterladen und installieren?')) {
        return $false
    }
    $url = Get-SysPilotWizTreeDownloadUrl
    Write-Host "  Download: $url" -ForegroundColor DarkGray

    $tempDir = Join-Path $env:TEMP ('syspilot-wiztree-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
    $installerPath = Join-Path $tempDir 'wiztree-setup.exe'

    if (-not (Save-SysPilotUrlToFile -Uri $url -OutFile $installerPath -TimeoutSec 120 -Label 'WizTree')) {
        Write-Host '  [FEHLER] Download fehlgeschlagen.' -ForegroundColor Red
        Write-Host '  Bitte WizTree manuell von https://diskanalyzer.com/download installieren.' -ForegroundColor Yellow
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        return $false
    }

    $sizeMB = [math]::Round((Get-Item $installerPath).Length / 1MB, 1)
    if ($sizeMB -lt 1) {
        Write-Host '  [FEHLER] Download zu klein/ungueltig.' -ForegroundColor Red
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        return $false
    }

    Write-Host "  Starte stille Installation ($sizeMB MB) ..." -ForegroundColor DarkGray
    $proc = Start-Process -FilePath $installerPath -ArgumentList '/VERYSILENT /NORESTART /SUPPRESSMSGBOXES /SP-' -Wait -PassThru

    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue

    $exe = Get-SysPilotWizTreeExe
    if ($exe -and $proc.ExitCode -le 1) {
        Write-Host "  [OK] WizTree installiert: $exe" -ForegroundColor Green
        Write-SysPilotLog "WizTree installiert ($url)"
        return $true
    }
    Write-Host "  [FEHLER] Installation fehlgeschlagen (ExitCode: $($proc.ExitCode))." -ForegroundColor Red
    Write-SysPilotLog "WizTree-Installation fehlgeschlagen (ExitCode: $($proc.ExitCode))"
    return $false
}

function Start-SysPilotWizTree {
    <# Startet WizTree (installiert vorher falls noetig). #>
    $exe = Get-SysPilotWizTreeExe
    if (-not $exe) {
        Write-Host 'WizTree ist nicht installiert.' -ForegroundColor Yellow
        if (-not (Install-SysPilotWizTree)) { return }
        $exe = Get-SysPilotWizTreeExe
        if (-not $exe) { return }
    }
    Write-Host "Starte WizTree: $exe" -ForegroundColor Cyan
    Start-Process -FilePath $exe
    Write-SysPilotLog "WizTree gestartet ($exe)"
}

function Show-SysPilotWizTreeMenu {
    <# Pfeiltasten-Menue: WizTree starten / installieren / Info / zurueck. #>
    while ($true) {
        $exe = Get-SysPilotWizTreeExe
        $items = @(
            @{ Label = "WizTree starten$(if ($exe) { '  [' + $exe + ']' } else { '  (nicht installiert)' })"; Color = 'Green'; Tag = 'start' }
            @{ Label = 'WizTree installieren/aktualisieren'; Color = 'White'; Tag = 'install' }
            @{ Label = 'WizTree-Website oeffnen'; Color = 'White'; Tag = 'web' }
            @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = $null }
        )
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'WizTree-Integration' -Footer 'Pfeiltasten, Enter = ausfuehren, Esc = zurueck'
        if ($null -eq $sel) { return }

        switch ($sel) {
            'start'   { Start-SysPilotWizTree; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
            'install' { [void](Install-SysPilotWizTree); Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
            'web'     { Start-Process 'https://diskanalyzer.com'; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
        }
    }
}

Export-ModuleMember -Function Get-SysPilotWizTreeExe, Get-SysPilotWizTreeDownloadUrl, Install-SysPilotWizTree, Start-SysPilotWizTree, Show-SysPilotWizTreeMenu
