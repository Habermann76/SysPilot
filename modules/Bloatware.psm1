# SysPilot - Bloatware: Programme finden und deinstallieren (Desktop + UWP)
#Requires -Version 5.1

function Get-SysPilotInstalled {
    $cfg = Get-SysPilotConfig
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $apps = Get-ItemProperty $paths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and -not $_.SystemComponent -and -not $_.ParentKeyName } |
        Select-Object -Property DisplayName, DisplayVersion, Publisher, InstallDate,
            @{n = 'SizeMB'; e = { if ($_.EstimatedSize) { [math]::Round($_.EstimatedSize / 1024) } else { 0 } }},
            UninstallString, QuietUninstallString, PSChildName -Unique

    foreach ($a in $apps) {
        $flag = ""
        foreach ($cat in $cfg.KnownBloat.PSObject.Properties) {
            foreach ($b in $cat.Value) {
                if ($a.DisplayName -like "*$b*") { $flag = $cat.Name; break }
            }
            if ($flag) { break }
        }
        $a | Add-Member -NotePropertyName Hinweis -NotePropertyValue $flag -Force
    }
    return ($apps | Sort-Object @{e = { [bool]$_.Hinweis }; Descending = $true }, @{e = 'SizeMB'; Descending = $true })
}

function Uninstall-SysPilotProgram {
    param([Parameter(Mandatory)]$App)
    $u = $App.UninstallString
    if (-not $u) { Write-Host "  [!] Kein Deinstallations-Eintrag gefunden." -ForegroundColor Red; return }

    Write-Host "  Deinstalliere: $($App.DisplayName) ..." -ForegroundColor Cyan
    Write-SysPilotLog "Deinstallation gestartet: $($App.DisplayName)"

    if ($u -match 'msiexec') {
        $guid = $App.PSChildName
        $proc = Start-Process "msiexec.exe" -ArgumentList "/x $guid" -PassThru
        # Fortschritt waehrend Deinstallation
        $i = 0
        while (-not $proc.HasExited) {
            $i++
            Write-SysPilotProgress -Activity "Deinstalliere $($App.DisplayName)" -Current ($i % 100) -Total 100 -Status 'laeuft...'
            Start-Sleep -Milliseconds 500
        }
        Complete-SysPilotProgress
    } else {
        # Uninstall-String kann Argumente enthalten -> aufteilen
        if ($u -match '^"([^"]+)"\s*(.*)$') {
            $exe = $matches[1]; $args = $matches[2]
        } elseif ($u -match '^(\S+)\s*(.*)$') {
            $exe = $matches[1]; $args = $matches[2]
        }
        $proc = Start-Process $exe -ArgumentList $args -PassThru
        $i = 0
        while (-not $proc.HasExited) {
            $i++
            Write-SysPilotProgress -Activity "Deinstalliere $($App.DisplayName)" -Current ($i % 100) -Total 100 -Status 'laeuft...'
            Start-Sleep -Milliseconds 500
        }
        Complete-SysPilotProgress
    }
    Write-Host "  [OK] Deinstallations-Programm beendet: $($App.DisplayName)" -ForegroundColor Green
    Write-SysPilotLog "Deinstallation beendet: $($App.DisplayName)"

    # Reste entfernen
    Remove-SysPilotLeftovers -App $App
}

function Remove-SysPilotLeftovers {
    param([Parameter(Mandatory)]$App)
    $name = $App.DisplayName
    $short = ($name -split ' ')[0] -replace '[^\w]',''
    if ($short.Length -lt 3) { return }

    $leftoverPaths = @(
        "$env:APPDATA\$short",
        "$env:APPDATA\$($App.Publisher)",
        "$env:LOCALAPPDATA\$short",
        "$env:LOCALAPPDATA\$($App.Publisher)",
        "$env:PROGRAMDATA\$short",
        "$env:PROGRAMDATA\$($App.Publisher)",
        "C:\Program Files\$short",
        "C:\Program Files (x86)\$short",
        "C:\Program Files\$($App.Publisher)",
        "C:\Program Files (x86)\$($App.Publisher)"
    ) | Select-Object -Unique

    $removed = 0
    foreach ($p in $leftoverPaths) {
        if ($p -and (Test-Path $p -ErrorAction SilentlyContinue)) {
            try {
                Remove-Item $p -Recurse -Force -ErrorAction Stop
                Write-Host "    Rest entfernt: $p" -ForegroundColor DarkGreen
                $removed++
            } catch { }
        }
    }
    if ($removed -gt 0) {
        Write-Host "  [OK] $removed Rest-Ordner entfernt." -ForegroundColor Green
        Write-SysPilotLog "Reste entfernt fuer '$name': $removed Ordner"
    }
}

function Get-SysPilotUwpBloat {
    $cfg = Get-SysPilotConfig
    $pkgs = Get-AppxPackage -ErrorAction SilentlyContinue
    $found = @()
    foreach ($p in $pkgs) {
        $name = $p.Name
        $isBloat = $false
        foreach ($b in $cfg.UwpBloat) { if ($name -like "*$b*") { $isBloat = $true; break } }
        if (-not $isBloat) { continue }
        $isKeep = $false
        foreach ($k in $cfg.UwpKeep) { if ($name -like "*$k*") { $isKeep = $true; break } }
        if ($isKeep) { continue }
        $found += [PSCustomObject]@{
            Name    = $name
            Version = $p.Version
            Paket   = $p.PackageFullName
        }
    }
    return ($found | Sort-Object Name -Unique)
}

function Remove-SysPilotUwpPackage {
    param([Parameter(Mandatory)][string]$Name)
    $pkgs = Get-AppxPackage -Name $Name -ErrorAction SilentlyContinue
    foreach ($p in $pkgs) {
        try {
            Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop
            Write-Host "  [OK] Entfernt: $($p.Name)" -ForegroundColor Green
            Write-SysPilotLog "UWP entfernt: $($p.Name)"
        } catch {
            Write-Host "  [!] Konnte nicht entfernt werden: $($p.Name) ($($_.Exception.Message))" -ForegroundColor Yellow
        }
    }
}

function Show-SysPilotBloatManager {
    while ($true) {
        $apps = @(Get-SysPilotInstalled)
        $items = @()
        foreach ($a in $apps) {
            $hint = if ($a.Hinweis) { "  <<< $($a.Hinweis)" } else { "" }
            $color = if ($a.Hinweis) { "Magenta" } else { "White" }
            $items += @{ Label = ("{0,-45} {1,6} MB  {2}{3}" -f $a.DisplayName, $a.SizeMB, $a.Publisher, $hint); Color = $color; Tag = $a }
        }
        $items += @{ Label = '--- UWP / Store-Apps (Facebook, TikTok, Candy Crush ...) ---'; Color = 'Yellow'; Tag = 'UWP' }
        $items += @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = $null }

        $sel = Show-SysPilotArrowMenu -Items $items -Title 'Programme deinstallieren (Desktop)' -Footer 'Pfeiltasten, Enter = deinstallieren, Esc = zurueck'
        if ($null -eq $sel) { return }
        if ($sel -eq 'UWP') { Show-SysPilotUwpManager; continue }

        $app = $sel
        if ($app.Hinweis) { Write-Host "  Hinweis: $($app.Hinweis)" -ForegroundColor Magenta }
        if (Confirm-SysPilot "Wirklich '$($app.DisplayName)' deinstallieren (Reste werden entfernt)?") {
            Uninstall-SysPilotProgram -App $app
            Read-SysPilotChoice "Weiter mit Enter" | Out-Null
        }
    }
}

function Show-SysPilotUwpManager {
    while ($true) {
        $pkgs = @(Get-SysPilotUwpBloat)
        if ($pkgs.Count -eq 0) {
            Write-SysPilotHeader "UWP / Store-Apps entfernen"
            Write-Host "  Keine bekannte Bloatware-Apps gefunden - sauber!" -ForegroundColor Green
            Read-SysPilotChoice "Weiter mit Enter" | Out-Null
            return
        }
        $items = @()
        foreach ($p in $pkgs) {
            $items += @{ Label = $p.Name; Color = 'White'; Tag = $p }
        }
        $items += @{ Label = '--- ALLE entfernen ---'; Color = 'Red'; Tag = 'ALL' }
        $items += @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = $null }

        $sel = Show-SysPilotArrowMenu -Items $items -Title "UWP / Store-Apps entfernen ($($pkgs.Count) gefunden)" -Footer 'Pfeiltasten, Enter = entfernen, Esc = zurueck'
        if ($null -eq $sel) { return }
        if ($sel -eq 'ALL') {
            if (Confirm-SysPilot "Wirklich ALLE $($pkgs.Count) Apps entfernen?") {
                foreach ($p in $pkgs) { Remove-SysPilotUwpPackage -Name $p.Name }
                Read-SysPilotChoice "Weiter mit Enter" | Out-Null
            }
            continue
        }
        $pkg = $sel
        if (Confirm-SysPilot "Wirklich '$($pkg.Name)' entfernen?") {
            Remove-SysPilotUwpPackage -Name $pkg.Name
            Read-SysPilotChoice "Weiter mit Enter" | Out-Null
        }
    }
}

function Show-SysPilotOptimizerManager {
    <# Findet installierte PC-Optimizer, Nutzer waehlt welche BEHALTEN werden, Rest wird deinstalliert #>
    Write-SysPilotHeader "Optimizer ausmisten (auswaehlbar behalten)"
    $apps = @(Get-SysPilotInstalled | Where-Object { $_.Hinweis -match 'Optimizer-Duplikate' })

    if ($apps.Count -eq 0) {
        Write-Host "  Keine PC-Optimizer gefunden - sauber!" -ForegroundColor Green
        return
    }

    Write-Host "  Gefundene PC-Optimizer ($($apps.Count)):" -ForegroundColor Cyan
    Write-Host ""
    $i = 0; $list = @()
    foreach ($a in $apps) {
        $i++; $list += $a
        Write-Host ("  [{0,2}] {1,-42} {2,6} MB  {3}" -f $i, $a.DisplayName, $a.SizeMB, $a.Publisher) -ForegroundColor White
    }
    Write-Host ""
    Write-Host "  SysPilot ersetzt diese Tools komplett (Kuehlung, Autopilot, Prioritaeten, Cleanup)." -ForegroundColor DarkGray
    Write-Host "  Mehrere Optimizer gleichzeitig bremsen sich gegenseitig - max. 1-2 behalten." -ForegroundColor DarkGray
    Write-Host ""
    $keep = Read-SysPilotChoice "Welche BEHALTEN? Nummern mit Komma (z.B. 2,5) | A = ALLE entfernen | 0 = zurueck"
    if ($keep -eq '0' -or $keep -eq '') { return }

    $keepIdx = @()
    if ($keep -notmatch '^(a|A)$') {
        foreach ($part in ($keep -split ',')) {
            $n = 0
            if ([int]::TryParse($part.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $list.Count) {
                $keepIdx += ($n - 1)
            }
        }
    }

    $remove = @()
    for ($k = 0; $k -lt $list.Count; $k++) {
        if ($keepIdx -notcontains $k) { $remove += $list[$k] }
    }

    Write-Host ""
    if ($keepIdx.Count -gt 0) {
        Write-Host "  BEHALTEN:" -ForegroundColor Green
        foreach ($k in $keepIdx) { Write-Host "    + $($list[$k].DisplayName)" -ForegroundColor Green }
    }
    Write-Host "  ENTFERNEN ($($remove.Count)):" -ForegroundColor Red
    foreach ($r in $remove) { Write-Host "    - $($r.DisplayName)" -ForegroundColor Red }
    Write-Host ""

    if ($remove.Count -eq 0) { Write-Host "  Nichts zu entfernen." -ForegroundColor Green; return }
    if (-not (Confirm-SysPilot "$($remove.Count) Optimizer wirklich deinstallieren?")) { return }

    foreach ($r in $remove) {
        Uninstall-SysPilotProgram -App $r
    }
    Write-Host ""
    Write-Host "  Fertig. Tipp: Menue 5 (Autostart) und 7 (Dienste) pruefen - dort melden sich Reste." -ForegroundColor Cyan
    Write-SysPilotLog "Optimizer ausgemistet: $($remove.Count) entfernt, $($keepIdx.Count) behalten"
}

Export-ModuleMember -Function Get-SysPilotInstalled, Uninstall-SysPilotProgram, Remove-SysPilotLeftovers,
    Get-SysPilotUwpBloat, Remove-SysPilotUwpPackage, Show-SysPilotBloatManager, Show-SysPilotUwpManager,
    Show-SysPilotOptimizerManager
