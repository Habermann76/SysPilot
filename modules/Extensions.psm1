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
    $pos = 0
    while ($true) {
        $ext = @(Get-SysPilotExtensions)
        if ($ext.Count -eq 0) {
            Write-SysPilotHeader "Browser-Erweiterungen verwalten"
            Write-Host "  Keine Erweiterungen gefunden." -ForegroundColor Green
            return
        }
        $list = @($ext | Sort-Object Kategorie, Browser, Name)

        $items = @()
        $items += @{ Label = '>> Report: Duplikate und Ueberlappungen anzeigen'; Color = 'Cyan'; Tag = 'report' }
        for ($i = 0; $i -lt $list.Count; $i++) {
            $e = $list[$i]
            $state = if ($e.Aktiv) { 'AN ' } else { 'aus' }
            $color = if ($e.Kategorie -match 'KI|Coupon|Cache') { 'Yellow' } else { 'White' }
            $items += @{ Label = ("{0} {1,-38} {2,-8} {3}" -f $state, $e.Name, $e.Browser, $e.Kategorie); Color = $color; Tag = $i }
        }
        $items += @{ Label = '<< Zurueck'; Color = 'Green'; Tag = 'back' }

        $choice = Show-SysPilotArrowMenu -Items $items -StartIndex $pos `
            -Title "Browser-Erweiterungen verwalten  ($($list.Count) gefunden)" `
            -Footer 'Pfeiltasten = auswaehlen | Enter = Erweiterungs-Seite im Browser oeffnen | Esc = zurueck'
        if ($null -eq $choice -or $choice -eq 'back') { return }
        if ($choice -eq 'report') {
            Clear-Host
            Show-SysPilotExtensionReport
            Write-Host ""
            Write-Host "  Beliebige Taste = zurueck zur Liste" -ForegroundColor DarkGray
            $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
            $pos = 0
            continue
        }
        $e = $list[[int]$choice]
        $pos = [int]$choice + 1
        Clear-Host
        Write-Host ""
        Write-Host "  Oeffne $($e.Settings) in $($e.Browser) ..." -ForegroundColor Cyan
        Write-Host "  (Dort kannst du die Erweiterung '$($e.Name)' deaktivieren/entfernen)" -ForegroundColor DarkGray
        try { Start-Process $e.Settings } catch { Write-Host "  Konnte nicht geoeffnet werden: $($_.Exception.Message)" -ForegroundColor Red }
        Start-Sleep -Milliseconds 1200
    }
}

Export-ModuleMember -Function Get-SysPilotBrowserProfiles, Get-SysPilotExtensions,
    Show-SysPilotExtensionReport, Show-SysPilotExtensionManager
