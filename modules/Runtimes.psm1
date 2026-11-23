# ======================================================================
# SysPilot Runtimes.psm1 - Laufzeit-Umgebungen pruefen, installieren,
# aktualisieren. Quellen: lokale Installer (Downloads) + offizielle
# Microsoft-URLs. Alles mit Bestaetigung und Admin-Check.
# ======================================================================

# --- Quellen (nur offizielle Microsoft-Links, keine geratenen URLs) ---
$script:VcRedistUrls = @{
    x64 = 'https://aka.ms/vs/17/release/vc_redist.x64.exe'
    x86 = 'https://aka.ms/vs/17/release/vc_redist.x86.exe'
}
$script:DotnetDesktopVersions = @(
    @{ Ver = '11.0.0';  Label = '11.0.0 (STS, Support bis 11/2028)'; Url = 'https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/11.0.0/windowsdesktop-runtime-11.0.0-win-x64.exe' },
    @{ Ver = '10.0.15'; Label = '10.0.15 (LTS, Support bis 11/2028)'; Url = 'https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/10.0.15/windowsdesktop-runtime-10.0.15-win-x64.exe' },
    @{ Ver = '9.0.23';  Label = '9.0.23 (STS, Support bis 11/2026)';  Url = 'https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/9.0.23/windowsdesktop-runtime-9.0.23-win-x64.exe' },
    @{ Ver = '8.0.34';  Label = '8.0.34 (LTS, Support bis 11/2026)';  Url = 'https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/8.0.34/windowsdesktop-runtime-8.0.34-win-x64.exe' }
)
$script:NetFx481Url = 'https://go.microsoft.com/fwlink/?linkid=2133304'
$script:ComputerbaseUrls = @{
    'All in One Runtimes'         = 'https://www.computerbase.de/downloads/systemtools/all-in-one-runtimes/'
    'Visual C++ Redistributables' = 'https://www.computerbase.de/downloads/systemtools/visual-c-redistributable-runtimes/'
    'Microsoft .NET'              = 'https://www.computerbase.de/downloads/systemtools/microsoft-.net/'
    'Microsoft .NET Framework'    = 'https://www.computerbase.de/downloads/systemtools/microsoft-.net-framework/'
}

function Get-SysPilotInstalledRuntimes {
    <# Installierte Laufzeiten: VC++-Redistributables, .NET Framework,
       .NET (Core/Desktop) Runtimes. #>
    $result = [ordered]@{ VcRedist = @(); NetFramework = $null; DotnetRuntimes = @() }

    # Visual C++ Redistributables
    $uninst = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
              'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $result.VcRedist = @(Get-ItemProperty $uninst -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match 'Visual C\+\+.*Redistributable' } |
        Sort-Object DisplayName -Unique |
        ForEach-Object { [pscustomobject]@{ Name = $_.DisplayName; Version = $_.DisplayVersion } })

    # .NET Framework (Release-Key -> Versionsname)
    $rel = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name Release -ErrorAction SilentlyContinue).Release
    if ($rel) {
        $v = switch -Regex ([string]$rel) {
            '^(5[0-9]{5})' { if ([int]$Matches[1] -ge 533320) { '4.8.1' } elseif ([int]$Matches[1] -ge 528040) { '4.8' } elseif ([int]$Matches[1] -ge 461808) { '4.7.2' } elseif ([int]$Matches[1] -ge 460798) { '4.7.1' } elseif ([int]$Matches[1] -ge 394802) { '4.7' } elseif ([int]$Matches[1] -ge 379893) { '4.5.2' } else { "Release $rel" } }
            default { "Release $rel" }
        }
        $result.NetFramework = [pscustomobject]@{ Version = $v; Release = $rel }
    }

    # .NET (Core/Desktop) Runtimes via Registry + dotnet --list-runtimes
    $dotnetKeys = @(
        'HKLM:\SOFTWARE\dotnet\Setup\InstalledVersions\x64\sharedfx\Microsoft.WindowsDesktop.App',
        'HKLM:\SOFTWARE\dotnet\Setup\InstalledVersions\x64\sharedfx\Microsoft.NETCore.App',
        'HKLM:\SOFTWARE\dotnet\Setup\InstalledVersions\x64\sharedfx\Microsoft.AspNetCore.App'
    )
    foreach ($k in $dotnetKeys) {
        if (Test-Path $k) {
            $app = ($k -split '\\')[-1]
            foreach ($sub in (Get-ChildItem $k -ErrorAction SilentlyContinue)) {
                $result.DotnetRuntimes += [pscustomobject]@{ App = $app; Version = $sub.PSChildName }
            }
        }
    }
    if (Get-Command dotnet -ErrorAction SilentlyContinue) {
        $lines = & dotnet --list-runtimes 2>$null
        foreach ($l in $lines) {
            if ($l -match '^(.+?)\s+(\d+\.\d+\.\d+.*)$') {
                $result.DotnetRuntimes += [pscustomobject]@{ App = $Matches[1]; Version = $Matches[2] }
            }
        }
    }
    $result.DotnetRuntimes = @($result.DotnetRuntimes | Sort-Object App, { [version]($_.Version -replace '[^0-9\.].*$','') } -Unique)
    return $result
}

function Find-SysPilotRuntimeInstaller {
    <# Sucht lokale Installer in Downloads (+ Unterordner wie ABDM\Programs).
       Gibt @{ Type; Path; Label } zurueck oder $null. #>
    param([Parameter(Mandatory)][string]$Type)
    $dirs = @(Get-SysPilotLocalSearchDirs) + @("$env:USERPROFILE\Downloads\ABDM")
    $patterns = @{
        'vcx64'    = 'VC_redist.x64.exe'
        'vcx86'    = 'VC_redist.x86.exe'
        'dotnet'   = 'windowsdesktop-runtime-*-win-x64.exe'
        'netfx'    = 'NDP48*.exe'
        'aio'      = 'aio-runtimes*.exe'
    }
    $pat = $patterns[$Type]
    if (-not $pat) { return $null }
    foreach ($d in $dirs) {
        if (-not (Test-Path $d)) { continue }
        $hit = Get-ChildItem $d -Recurse -Filter '*.exe' -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -like $pat } |
               Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($hit) {
            return @{ Type = $Type; Path = $hit.FullName; Label = $hit.Name; SizeMB = [math]::Round($hit.Length/1MB,1) }
        }
    }
    return $null
}

function Save-SysPilotRuntimeInstaller {
    <# Laedt einen Installer von einer offiziellen URL nach Downloads. #>
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$FileName)
    $dest = Join-Path (Get-SysPilotPortableAppsDir) $FileName
    Write-Host "  Lade $FileName von $Url ..." -ForegroundColor Cyan
    if (-not (Save-SysPilotUrlToFile -Uri $Url -OutFile $dest -TimeoutSec 600 -Label $FileName)) { return $null }
    if (-not (Test-Path $dest) -or (Get-Item $dest).Length -lt 100KB) {
        Write-Host '  [!] Download unvollstaendig.' -ForegroundColor Red
        Remove-Item $dest -Force -ErrorAction SilentlyContinue
        return $null
    }
    Write-Host ("  [OK] Gespeichert: {0} ({1} MB)" -f $dest, [math]::Round((Get-Item $dest).Length/1MB,1)) -ForegroundColor Green
    return $dest
}

function Install-SysPilotRuntimeWinget {
    <# Installiert eine Runtime ueber winget - sauberster Pfad:
       kuenftige Versionen im Channel, 'bereits installiert' wird erkannt,
       Silent-Mode mit eigenem Fortschritt.
       Rueckgabe: $true = ok, $false = winget-Fehler, $null = winget fehlt. #>
    param(
        [Parameter(Mandatory)][string]$WingetId,
        [Parameter(Mandatory)][string]$Label
    )
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) { return $null }
    Write-Host "  Installiere $Label ueber winget ($WingetId) ..." -ForegroundColor Cyan
    $wargs = @('install','--id',$WingetId,'-e','--silent',
               '--accept-package-agreements','--accept-source-agreements',
               '--disable-interactivity')
    $p = Start-Process winget.exe -ArgumentList $wargs -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -eq 0) {
        Write-Host "  [OK] $Label installiert bzw. aktuell." -ForegroundColor Green
        Write-SysPilotLog "Runtime via winget installiert: $WingetId"
        return $true
    }
    # winget meldet 'kein passender Installer' auch dann, wenn das Paket
    # bereits in neuester Version installiert ist - kurz gegenpruefen.
    $lst = & winget.exe list --id $WingetId -e --accept-source-agreements 2>$null
    if ($LASTEXITCODE -eq 0 -and ($lst | Out-String) -match [regex]::Escape($WingetId)) {
        Write-Host "  [OK] $Label ist bereits installiert." -ForegroundColor Green
        return $true
    }
    Write-Host "  [!] winget fehlgeschlagen (Code $($p.ExitCode))" -ForegroundColor Yellow
    return $false
}

function Install-SysPilotRuntimePackage {
    <# Installiert einen Runtime-Installer. Erkennt Typ an Dateiname/Type.
       Silent wo moeglich, sonst interaktiv. Bietet bei fehlenden
       Admin-Rechten den Neustart als Administrator an. #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Type = 'auto'
    )
    if (-not (Test-SysPilotAdmin)) {
        if (Confirm-SysPilot "'$Path' installieren braucht Administrator-Rechte.`nSysPilot jetzt als Administrator neu starten?") {
            Restart-SysPilotElevated
        }
        return $false
    }
    if (-not (Test-Path $Path)) { Write-Host "  [!] Datei nicht gefunden: $Path" -ForegroundColor Red; return $false }

    $name = [IO.Path]::GetFileName($Path).ToLower()
    $t = $Type
    if ($t -eq 'auto') {
        $t = switch -Wildcard ($name) {
            'VC_redist.x64*'        { 'vcx64' }
            'VC_redist.x86*'        { 'vcx86' }
            'windowsdesktop-runtime*'{ 'dotnet' }
            'NDP48*'                { 'netfx' }
            'aio-runtimes*'         { 'aio' }
            default                 { 'generic' }
        }
    }

    $procArgs = switch ($t) {
        'vcx64'    { '/install /quiet /norestart' }
        'vcx86'    { '/install /quiet /norestart' }
        'dotnet'   { '/install /quiet /norestart' }
        'netfx'    { '/q /norestart' }
        'aio'      { '' }   # AIO hat eigene Auswahl-UI - bewusst interaktiv
        default    { '/S' }
    }
    $silent = ($t -ne 'aio')
    $label  = switch ($t) { 'aio' { 'All in One Runtimes (interaktive Auswahl)' } 'generic' { 'Installer' } default { "Runtime ($t)" } }

    if (-not (Confirm-SysPilot "'$label' installieren?`n`n$Path")) { return $false }
    Write-Host "  Starte Installer ..." -ForegroundColor Cyan
    try {
        $p = Start-Process -FilePath $Path -ArgumentList $procArgs -Wait -PassThru
        # 0 = ok, 3010 = ok (Neustart noetig), 1638 = neuere Version bereits installiert
        if ($p.ExitCode -in 0, 3010, 1638) {
            Write-Host '  [OK] Installation abgeschlossen (ggf. Neustart noetig).' -ForegroundColor Green
            Write-SysPilotLog "Runtime installiert: $name"
            return $true
        }
        Write-Host "  [!] Installer beendet mit Code $($p.ExitCode)" -ForegroundColor Yellow
        return $false
    } catch {
        Write-Host "  [!] Start fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Show-SysPilotRuntimeStatus {
    <# Zeigt alle erkannten Laufzeiten uebersichtlich. #>
    $r = Get-SysPilotInstalledRuntimes
    Write-Host ''
    Write-Host '  === Visual C++ Redistributables ===' -ForegroundColor Cyan
    if ($r.VcRedist.Count -eq 0) { Write-Host '  (keine gefunden)' -ForegroundColor DarkGray }
    foreach ($v in $r.VcRedist) { Write-Host ("  {0}  [{1}]" -f $v.Name, $v.Version) -ForegroundColor White }

    Write-Host ''
    Write-Host '  === .NET Framework ===' -ForegroundColor Cyan
    if ($r.NetFramework) { Write-Host ("  Version {0} (Release {1})" -f $r.NetFramework.Version, $r.NetFramework.Release) -ForegroundColor White }
    else { Write-Host '  (nicht gefunden)' -ForegroundColor DarkGray }

    Write-Host ''
    Write-Host '  === .NET Runtimes (Core/Desktop) ===' -ForegroundColor Cyan
    if ($r.DotnetRuntimes.Count -eq 0) { Write-Host '  (keine gefunden - ggf. dotnet --list-runtimes pruefen)' -ForegroundColor DarkGray }
    foreach ($d in $r.DotnetRuntimes) { Write-Host ("  {0}  {1}" -f $d.App, $d.Version) -ForegroundColor White }

    Write-Host ''
    Write-Host '  === Lokale Installer (Downloads) ===' -ForegroundColor Cyan
    foreach ($t in 'vcx64','vcx86','dotnet','netfx','aio') {
        $f = Find-SysPilotRuntimeInstaller -Type $t
        if ($f) { Write-Host ("  [{0}] {1} ({2} MB)" -f $t, $f.Label, $f.SizeMB) -ForegroundColor Green }
    }
    Write-Host ''
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
}

function Show-SysPilotRuntimesMenu {
    <# Pfeiltasten-Menue fuer Laufzeit-Installationen. #>
    while ($true) {
        # Aktuelle Versionen kurz ermitteln fuer die Anzeige
        $r = Get-SysPilotInstalledRuntimes
        $netfxTxt = if ($r.NetFramework) { $r.NetFramework.Version } else { 'fehlt' }
        $items = @(
            @{ Label = 'Status: installierte Runtimes anzeigen';                    Color = 'White';  Tag = 'status' }
            @{ Label = 'Visual C++ Redistributable (x64 + x86) aktualisieren';      Color = 'Cyan';   Tag = 'vc' }
            @{ Label = '.NET Desktop Runtime installieren/wahlen';                  Color = 'Cyan';   Tag = 'dotnet' }
            @{ Label = ".NET Framework (aktuell: $netfxTxt) aktualisieren";        Color = 'Cyan';   Tag = 'netfx' }
            @{ Label = 'All in One Runtimes (Computerbase, interaktiv)';            Color = 'Yellow'; Tag = 'aio' }
            @{ Label = 'Computerbase-Download-Seiten im Browser oeffnen';          Color = 'DarkGray'; Tag = 'cb' }
            @{ Label = 'Zurueck';                                                  Color = 'DarkGray'; Tag = $null }
        )
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'SysPilot Laufzeiten (Runtimes)' -Footer 'Pfeiltasten, Enter = auswaehlen, Esc = zurueck'
        if ($null -eq $sel) { return }

        switch ($sel) {
            'status' { Show-SysPilotRuntimeStatus }

            'vc' {
                $wingetIds = @{ x64 = 'Microsoft.VCRedist.2015+.x64'; x86 = 'Microsoft.VCRedist.2015+.x86' }
                foreach ($arch in 'x64','x86') {
                    $type = "vc$arch"
                    $local = Find-SysPilotRuntimeInstaller -Type $type
                    if ($local) {
                        Write-Host "`n  Lokaler Installer gefunden: $($local.Label)" -ForegroundColor Green
                        Install-SysPilotRuntimePackage -Path $local.Path -Type $type
                        continue
                    }
                    # 1) winget (bevorzugt: neueste Version, saubere Codes)
                    $wg = Install-SysPilotRuntimeWinget -WingetId $wingetIds[$arch] -Label "VC++ Redistributable $arch"
                    if ($wg) { continue }
                    # 2) Fallback: offizieller Direktdownload
                    $url = $script:VcRedistUrls[$arch]
                    $fn  = "vc_redist.$arch.exe"
                    if (Confirm-SysPilot "VC++ Redistributable $arch von Microsoft herunterladen und installieren?`n$url") {
                        $p = Save-SysPilotRuntimeInstaller -Url $url -FileName $fn
                        if ($p) { Install-SysPilotRuntimePackage -Path $p -Type $type }
                    }
                }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }

            'dotnet' {
                # Version waehlen
                $wingetMap = @{
                    '11.0.0' = 'Microsoft.DotNet.DesktopRuntime.11'
                    '10.0.15' = 'Microsoft.DotNet.DesktopRuntime.10'
                    '9.0.23'  = 'Microsoft.DotNet.DesktopRuntime.9'
                    '8.0.34'  = 'Microsoft.DotNet.DesktopRuntime.8'
                }
                $dItems = @()
                foreach ($v in $script:DotnetDesktopVersions) { $dItems += @{ Label = $v.Label; Color = 'White'; Tag = $v } }
                $dItems += @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = $null }
                $pick = Show-SysPilotArrowMenu -Items $dItems -Title '.NET Desktop Runtime - Version waehlen' -Footer 'Enter =installieren, Esc = zurueck'
                if ($null -ne $pick) {
                    $ver = $pick.Ver
                    $local = Find-SysPilotRuntimeInstaller -Type 'dotnet'
                    $localMatch = ($local -and ([IO.Path]::GetFileName($local.Path) -match [regex]::Escape($ver)))
                    if ($localMatch) {
                        Write-Host "`n  Lokaler Installer: $($local.Label)" -ForegroundColor Green
                        Install-SysPilotRuntimePackage -Path $local.Path -Type 'dotnet'
                    } else {
                        # 1) winget
                        $wg = Install-SysPilotRuntimeWinget -WingetId $wingetMap[$ver] -Label ".NET Desktop Runtime $ver"
                        if (-not $wg) {
                            # 2) Fallback: offizieller Direktdownload
                            if ($local -and -not $localMatch) {
                                Write-Host "`n  [!] Lokaler Installer ist andere Version ($($local.Label)) - Download stattdessen." -ForegroundColor Yellow
                            }
                            if (Confirm-SysPilot ".NET Desktop Runtime $ver herunterladen und installieren?`n$($pick.Url)") {
                                $p = Save-SysPilotRuntimeInstaller -Url $pick.Url -FileName "windowsdesktop-runtime-$ver-win-x64.exe"
                                if ($p) { Install-SysPilotRuntimePackage -Path $p -Type 'dotnet' }
                            }
                        }
                    }
                }
            }

            'netfx' {
                $local = Find-SysPilotRuntimeInstaller -Type 'netfx'
                if ($local) {
                    Write-Host "`n  Lokaler Installer: $($local.Label) ($($local.SizeMB) MB)" -ForegroundColor Green
                    Install-SysPilotRuntimePackage -Path $local.Path -Type 'netfx'
                } else {
                    # 1) winget: Microsoft.DotNet.Framework.Runtime = 4.8.1
                    $wg = Install-SysPilotRuntimeWinget -WingetId 'Microsoft.DotNet.Framework.Runtime' -Label '.NET Framework 4.8.1'
                    if (-not $wg) {
                        # 2) Fallback: offizieller Web-Installer
                        if (Confirm-SysPilot ".NET Framework 4.8.1 (Web-Installer) herunterladen und installieren?`n$script:NetFx481Url") {
                            $p = Save-SysPilotRuntimeInstaller -Url $script:NetFx481Url -FileName 'ndp481-web.exe'
                            if ($p) { Install-SysPilotRuntimePackage -Path $p -Type 'netfx' }
                        }
                    }
                }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }

            'aio' {
                $local = Find-SysPilotRuntimeInstaller -Type 'aio'
                if ($local) {
                    Write-Host "`n  Lokaler Installer: $($local.Label) ($($local.SizeMB) MB)" -ForegroundColor Green
                    Write-Host '  AIO oeffnet eine eigene Auswahl (welche Runtimes) - Countdown stopbar.' -ForegroundColor DarkGray
                    Install-SysPilotRuntimePackage -Path $local.Path -Type 'aio'
                } else {
                    Write-Host '  Kein lokaler AIO-Installer gefunden. Computerbase-Seite wird geoeffnet.' -ForegroundColor Yellow
                    Start-Process $script:ComputerbaseUrls['All in One Runtimes']
                }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }

            'cb' {
                foreach ($k in $script:ComputerbaseUrls.Keys) {
                    Write-Host "  $k -> $($script:ComputerbaseUrls[$k])" -ForegroundColor DarkGray
                }
                Write-Host ''
                if (Confirm-SysPilot 'Computerbase-Download-Seiten im Browser oeffnen?') {
                    foreach ($u in $script:ComputerbaseUrls.Values) { Start-Process $u }
                }
            }
        }
    }
}

Export-ModuleMember -Function Get-SysPilotInstalledRuntimes, Find-SysPilotRuntimeInstaller,
    Save-SysPilotRuntimeInstaller, Install-SysPilotRuntimeWinget, Install-SysPilotRuntimePackage,
    Show-SysPilotRuntimeStatus, Show-SysPilotRuntimesMenu
