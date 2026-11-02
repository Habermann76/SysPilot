# SysPilot - Extensions: Browser-Erweiterungen finden, kategorisieren, Duplikate aufdecken
#Requires -Version 5.1

function Get-SysPilotBrowserProfiles {
    <# Findet installierte Browser und ihre Profil-Ordner #>
    $profiles = @()
    $browsers = @(
        @{ Name = 'Chrome';  Path = "$env:LOCALAPPDATA\Google\Chrome\User Data";        ExtSub = 'Extensions'; Settings = 'chrome://extensions/' },
        @{ Name = 'Edge';    Path = "$env:LOCALAPPDATA\Microsoft\Edge\User Data";       ExtSub = 'Extensions'; Settings = 'edge://extensions/' },
        @{ Name = 'Brave';   Path = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data"; ExtSub = 'Extensions'; Settings = 'brave://extensions/' },
        @{ Name = 'Opera';   Path = "$env:APPDATA\Opera Software\Opera Stable";         ExtSub = 'Extensions'; Settings = 'opera://extensions/' },
        @{ Name = 'Firefox'; Path = "$env:APPDATA\Mozilla\Firefox\Profiles";            ExtSub = '';           Settings = 'about:addons' }
    )
    foreach ($b in $browsers) {
        if (-not (Test-Path $b.Path)) { continue }
        if ($b.Name -eq 'Firefox') {
            Get-ChildItem $b.Path -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $profiles += [PSCustomObject]@{ Browser = 'Firefox'; Profil = $_.Name; Pfad = $_.FullName; Settings = $b.Settings }
            }
        } else {
            # Chromium: Default + Profile *
            $dirs = @(Get-ChildItem $b.Path -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })
            foreach ($d in $dirs) {
                $profiles += [PSCustomObject]@{ Browser = $b.Name; Profil = $d.Name; Pfad = $d.FullName; Settings = $b.Settings }
            }
        }
    }
    return $profiles
}

function Get-SysPilotExtensions {
    <# Liest alle Erweiterungen aller Browser-Profile #>
    $cfg = Get-SysPilotConfig
    $cats = $cfg.ExtensionCategories
    $profiles = Get-SysPilotBrowserProfiles
    $all = @()

    foreach ($p in $profiles) {
        if ($p.Browser -eq 'Firefox') {
            # Firefox: extensions.json
            $json = Join-Path $p.Pfad 'extensions.json'
            if (Test-Path $json) {
                try {
                    $data = Get-Content $json -Raw -Encoding UTF8 | ConvertFrom-Json
                    foreach ($a in $data.addons) {
                        if ($a.type -ne 'extension') { continue }
                        $name = $a.defaultLocale.name
                        if (-not $name) { $name = $a.id }
                        $all += [PSCustomObject]@{
                            Browser = 'Firefox'; Profil = $p.Profil; Name = $name
                            Id = $a.id; Aktiv = (-not $a.userDisabled); Version = $a.version
                            Kategorie = Get-ExtensionCategory -Name $name -Cats $cats
                            Settings = $p.Settings
                        }
                    }
                } catch { }
            }
        } else {
            # Chromium: nur vom Nutzer installierte Erweiterungen (aus 'extensions'-Einstellungen)
            $extDir = Join-Path $p.Pfad 'Extensions'
            if (-not (Test-Path $extDir)) { continue }

            # Installierte Erweiterungen aus 'Secure Preferences' lesen (dort stehen sie wirklich)
            $prefFile = Join-Path $p.Pfad 'Secure Preferences'
            if (-not (Test-Path $prefFile)) { $prefFile = Join-Path $p.Pfad 'Preferences' }
            if (-not (Test-Path $prefFile)) { continue }
            try {
                $pref = Get-Content $prefFile -Raw -Encoding UTF8 | ConvertFrom-Json
                $settings = $pref.extensions.settings
                if (-not $settings) { continue }
                foreach ($prop in $settings.PSObject.Properties) {
                    $entry = $prop.Value
                    # Nur echte Erweiterungen (keine Themes/Apps), nur vom Nutzer installierte
                    if ($entry.manifest -eq $null) { continue }
                    if ($entry.manifest.type -eq 'theme') { continue }
                    $name = $entry.manifest.name
                    if (-not $name) { $name = $prop.Name }
                    $aktiv = ($entry.state -ne 0) -and ($entry.disable_reasons -eq $null -or $entry.disable_reasons.Count -eq 0)
                    $all += [PSCustomObject]@{
                        Browser = $p.Browser; Profil = $p.Profil; Name = $name
                        Id = $prop.Name; Aktiv = $aktiv; Version = $entry.manifest.version
                        Kategorie = Get-ExtensionCategory -Name $name -Cats $cats
                        Settings = $p.Settings
                    }
                }
            } catch { }
        }
    }
    return $all
}

function Get-ExtensionCategory {
    param([string]$Name, $Cats)
    $n = $Name.ToLower()
    foreach ($cat in $Cats.PSObject.Properties) {
        foreach ($kw in $cat.Value) {
            if ($n -like "*$($kw.ToLower())*") { return $cat.Name }
        }
    }
    return 'Sonstige'
}

function Show-SysPilotExtensionReport {
    Write-SysPilotHeader "Browser-Erweiterungen: Analyse"
    $ext = @(Get-SysPilotExtensions)
    if ($ext.Count -eq 0) { Write-Host "  Keine Erweiterungen gefunden." -ForegroundColor Green; return }

    Write-Host "  Gefunden: $($ext.Count) Erweiterungen in $(($ext | Select-Object Browser -Unique).Count) Browsern" -ForegroundColor Cyan
    Write-Host ""

    # Nach Kategorie gruppieren
    $byCat = $ext | Group-Object Kategorie | Sort-Object Count -Descending
    foreach ($c in $byCat) {
        $color = 'White'
        if ($c.Name -like 'KI*') { $color = 'Magenta' }
        elseif ($c.Name -like 'Coupon*') { $color = 'Yellow' }
        elseif ($c.Name -like 'Cache*') { $color = 'Yellow' }
        elseif ($c.Name -like 'AdBlock*') { $color = 'Green' }
        elseif ($c.Name -like 'VPN*') { $color = 'Cyan' }
        Write-Host ("  $($c.Name) ($($c.Count))") -ForegroundColor $color
        foreach ($e in ($c.Group | Sort-Object Browser, Name)) {
            $state = if ($e.Aktiv) { '' } else { '  [deaktiviert]' }
            Write-Host ("    - {0,-40} {1,-8} {2}{3}" -f $e.Name, $e.Browser, $e.Version, $state) -ForegroundColor DarkGray
        }
    }

    # Duplikat-Warnungen
    Write-Host ""
    Write-Host "  MOEGLICHE DUPLIKATE / UEBERLAPPUNGEN:" -ForegroundColor Yellow
    $warned = $false
    foreach ($cat in @('KI / Summarizer','Coupon / Cashback','Cache Cleaner / Speed','AdBlock / Privacy','VPN / Proxy','Passwort-Manager','Tab-Manager','Preisvergleich','Dark Mode')) {
        $group = $ext | Where-Object { $_.Kategorie -eq $cat -and $_.Aktiv }
        if ($group.Count -gt 1) {
            $warned = $true
            Write-Host ("  [!] " + $cat + ": $($group.Count) aktiv - beissen sich evtl. gegenseitig:") -ForegroundColor Red
            $group | ForEach-Object { Write-Host ("      - $($_.Name) ($($_.Browser))") -ForegroundColor Red }
        }
    }
    if (-not $warned) { Write-Host "  Keine kritischen Duplikate gefunden." -ForegroundColor Green }

    Write-Host ""
    Write-Host "  Ehrliche Empfehlung:" -ForegroundColor Cyan
    Write-Host "    - KI/Summarizer: 1 reicht (z.B. nur Copilot ODER ChatGPT, nicht 5)" -ForegroundColor DarkGray
    Write-Host "    - Coupon/Cashback: 1 reicht (Honey ODER Rakuten, nicht beide)" -ForegroundColor DarkGray
    Write-Host "    - Cache Cleaner: BRAUCHST DU NICHT - SysPilot macht das besser (Menue 11)" -ForegroundColor DarkGray
    Write-Host "    - AdBlock: 1 reicht (uBlock Origin ist genug)" -ForegroundColor DarkGray
    Write-Host "    - VPN: 1 reicht" -ForegroundColor DarkGray
}

function Show-SysPilotExtensionManager {
    while ($true) {
        Write-SysPilotHeader "Browser-Erweiterungen verwalten"
        $ext = @(Get-SysPilotExtensions)
        if ($ext.Count -eq 0) { Write-Host "  Keine Erweiterungen gefunden." -ForegroundColor Green; return }

        $i = 0; $list = @()
        foreach ($e in ($ext | Sort-Object Kategorie, Browser, Name)) {
            $i++; $list += $e
            $state = if ($e.Aktiv) { 'AN ' } else { 'aus' }
            $color = if ($e.Kategorie -match 'KI|Coupon|Cache') { 'Yellow' } else { 'White' }
            Write-Host ("  [{0,2}] {1} {2,-38} {3,-8} {4}" -f $i, $state, $e.Name, $e.Browser, $e.Kategorie) -ForegroundColor $color
        }
        Write-Host ""
        Write-Host "  Befehle: <Nr> = Extension-Seite im Browser oeffnen | R = Report | 0 = zurueck" -ForegroundColor Yellow
        $c = Read-SysPilotChoice "Auswahl"
        if ($c -eq '0' -or $c -eq '') { return }
        if ($c -match '^(r|R)$') { Show-SysPilotExtensionReport; Read-SysPilotChoice "Weiter" | Out-Null; continue }
        $n = 0
        if ([int]::TryParse($c, [ref]$n) -and $n -ge 1 -and $n -le $list.Count) {
            $e = $list[$n - 1]
            Write-Host "  Oeffne $($e.Settings) in $($e.Browser) ..." -ForegroundColor Cyan
            Write-Host "  (Dort kannst du die Erweiterung deaktivieren/entfernen)" -ForegroundColor DarkGray
            Start-Process $e.Settings
        }
    }
}

Export-ModuleMember -Function Get-SysPilotBrowserProfiles, Get-SysPilotExtensions,
    Show-SysPilotExtensionReport, Show-SysPilotExtensionManager
