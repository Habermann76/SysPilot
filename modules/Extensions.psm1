# SysPilot - Extensions: Browser-Erweiterungen finden, kategorisieren,
# Sicherheits-Scan (blocklist, Permissions, Manifest V2, CRXcavator),
# WPF-Verwaltung mit Herbert-Assistent und Statuskonsole.
#Requires -Version 5.1

# =====================================================================
# Bekannte Schaedlings-/Hijacker-Extensions (IDs + Namensmuster)
# Quellen: Palo Alto Unit42 (RedDirection), LayerX, DomainTools,
# Cyberhaven-Vorfaelle, historisch bekannte Rogue-Add-ons.
# =====================================================================
$script:SysPilotExtBlocklistIds = @(
    # The Great Suspender (+ Klone), Nano Adblocker/Defender
    'jfkecceghciadamopilhkbcenmfjakk','bhalcjonkjbgncikbplpbdlfkgdgcmah',
    'djflhoibgkdhkhhhdibiihelfpmahkoa','ngpampappnmepgilojfohadhhmbhlaek',
    # LayerX-Kampagne 2025 (Fake-Utility-Extensions)
    'ccolcciihnpcbjcgcjfmabegkpbehnip','aeibljandkelbcaaemkdnbaacppjdmom',
    'fcfmhlijjmckglejcgdclfneafoehafm','abbngaojehjekanfdipifimgmppiojpl',
    'dohmiglipinohflhapdagfgbldhmoojl','acmiibcdcmaghndcahglamnhnlmcmlng',
    'mipophmjfhpecleajkijfifmffcjdiac','cknmibbkfbephciofemdjndbgebggnkc',
    'gmigkpkjegnpmjpmnmgnkhmoinpgdnfc','ahgccenjociolkbpgbfibmfclcfnlaei',
    'kjhjnbdjonamibpaalanflmidplhiehe','pobknfocgoijjmokmhimkfhemcnigdji',
    'iclckldkfemlnecocpphinnplnmijkol','jmpcodajbcpgkebjipbmjdoboehfiddd',
    'ihdnbohcfnegemgomjcpckmpnkdgopon','oeefjlikahigmlnplgijgeeecbpemhip',
    'aofddmgnidinflambjlfkpboeamdldbd','acchdggcflgidjdcnhnnkfengdcmldae',
    'albakpncdngcejcjdahomfbkakbmafgb'
)
$script:SysPilotExtBlocklistNames = @(
    'the great suspender','nano adblocker','nano defender','uc browser',
    'hola vpn','hola free vpn','touch vpn','supervpn','apus browser',
    'qihoo 360','avast secure browser','deserve','capital one shopping',
    'the great suspender','video downloader professional','pdf converter pro'
)

function Get-SysPilotExtBlocklistIds { return @($script:SysPilotExtBlocklistIds | Where-Object { $_ -notmatch '\.\.\.' }) }
function Get-SysPilotExtBlocklistNames { return @($script:SysPilotExtBlocklistNames) }

# ---------- Benutzer-Blocklist (persistent, pro Nutzer) ----------
# Datei: %LOCALAPPDATA%\SysPilot\ext-user-blocklist.txt
# Zeilen: Extension-ID (32 Zeichen a-p) oder Namensfragment.
# Getrefferte Extensions werden als KRITISCH geflaggt.
function Get-SysPilotExtUserBlocklistPath {
    $dir = Join-Path $env:LOCALAPPDATA 'SysPilot'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    return (Join-Path $dir 'ext-user-blocklist.txt')
}
function Get-SysPilotExtUserBlocklist {
    $p = Get-SysPilotExtUserBlocklistPath
    if (-not (Test-Path $p)) { return @() }
    try {
        return @((Get-Content $p -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^#' }))
    } catch { return @() }
}
function Add-SysPilotExtUserBlocklist {
    param([Parameter(Mandatory)][string]$Term)
    $t = "$Term".Trim(); if (-not $t) { return $false }
    $p = Get-SysPilotExtUserBlocklistPath
    $cur = @(Get-SysPilotExtUserBlocklist)
    if ($cur -contains $t) { return $true }
    try { Add-Content -Path $p -Value $t -Encoding UTF8; return $true } catch { return $false }
}

# ---------- Browser-Richtlinien-Sperre (ExtensionInstallBlocklist) ----------
# Schreibt die Extension-ID in die Installations-Blockliste der
# Browser-Richtlinien (HKCU). Verhindert, dass die Extension ueber
# Account-Sync oder den Store erneut installiert/geladen wird.
# Registry-Pfad je Browser (HKCU = kein Admin noetig):
#   Chrome/Chromium: Software\Policies\Google\Chrome
#   Edge:            Software\Policies\Microsoft\Edge
#   Brave:           Software\Policies\BraveSoftware\Brave
#   Firefox:         eigene policies.json - hier nicht unterstuetzt
function Get-SysPilotExtensionPolicyPath {
    param([Parameter(Mandatory)][string]$Browser)
    switch ($Browser) {
        'Chrome'           { return 'Google\Chrome' }
        'Edge'             { return 'Microsoft\Edge' }
        'Brave'            { return 'BraveSoftware\Brave' }
        'Perplexity Comet' { return 'Perplexity\Comet' }
        'BrowserOS'        { return 'BrowserOS\BrowserOS' }
        default            { return 'Chromium' }
    }
}
function Add-SysPilotExtensionInstallBlock {
    <# Setzt eine Installations-Sperre fuer die Extension-ID im
       Browser-Richtlinien-Blocklist-Key. Idempotent. #>
    param([Parameter(Mandatory)][string]$Browser, [Parameter(Mandatory)][string]$ExtId)
    $id = "$ExtId".Trim().ToLower()
    if ($id -notmatch '^[a-p]{32}$') { return @{ Ok=$false; Message='Keine Store-ID - Policy-Block nur fuer Store-Extensions' } }
    $paths = @((Get-SysPilotExtensionPolicyPath $Browser))
    if ($Browser -notin @('Chrome','Edge','Brave') -and $Browser -ne 'Firefox' -and $Browser -ne 'Tor') {
        $paths += 'Chromium'   # Fallback fuer Chromium-Forks
    }
    $done = @()
    foreach ($rel in ($paths | Sort-Object -Unique)) {
        $keyPath = "HKCU:\SOFTWARE\Policies\$rel\ExtensionInstallBlocklist"
        try {
            if (-not (Test-Path $keyPath)) { New-Item -Path $keyPath -Force | Out-Null }
            $regItem = Get-Item -Path $keyPath -ErrorAction SilentlyContinue
            $existing = @()
            if ($regItem) { $existing = @($regItem.GetValueNames() | ForEach-Object { "$($regItem.GetValue($_))".ToLower() }) }
            if ($existing -notcontains $id) {
                $idx = 1
                while ($idx -le 99) {
                    $v = $null
                    try { $v = $regItem.GetValue("$idx") } catch { $v = $null }
                    if ($null -eq $v) { break }
                    $idx++
                }
                if ($idx -gt 99) { $idx = (Get-Random -Minimum 100 -Maximum 999) }
                New-ItemProperty -Path $keyPath -Name "$idx" -Value $id -PropertyType String -Force | Out-Null
            }
            $done += $rel
        } catch { }
    }
    if ($done.Count -eq 0) { return @{ Ok=$false; Message='Policy-Key konnte nicht geschrieben werden' } }
    return @{ Ok=$true; Message="Install-Sperre gesetzt: $($done -join ', ')" }
}

function Get-SysPilotBrowserProfiles {
    <# Findet installierte Browser und ihre Profil-Ordner.
       Chromium-Forks (auch KI-Browser) einzeln; AiBrowser markiert,
       damit Massen-Aktionen separat bestaetigt werden koennen. #>
    $profiles = @()
    $browsers = @(
        @{ Name = 'Chrome';        Path = "$env:LOCALAPPDATA\Google\Chrome\User Data";              ExtSub = 'Extensions'; Settings = 'chrome://extensions/' },
        @{ Name = 'Edge';          Path = "$env:LOCALAPPDATA\Microsoft\Edge\User Data";             ExtSub = 'Extensions'; Settings = 'edge://extensions/' },
        @{ Name = 'Brave';         Path = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data"; ExtSub = 'Extensions'; Settings = 'brave://extensions/' },
        @{ Name = 'Opera';         Path = "$env:APPDATA\Opera Software\Opera Stable";                ExtSub = 'Extensions'; Settings = 'opera://extensions/' },
        @{ Name = 'Arc';           Path = "$env:LOCALAPPDATA\Arc\User Data";                         ExtSub = 'Extensions'; Settings = 'chrome://extensions/' },
        @{ Name = 'Vivaldi';       Path = "$env:LOCALAPPDATA\Vivaldi\User Data";                     ExtSub = 'Extensions'; Settings = 'vivaldi://extensions/' },
        # KI-Browser (Chromium-Forks): EINZELN verwaltbar - bei Massen-
        # Aktionen wird extra gefragt, ob sie einbezogen werden sollen.
        @{ Name = 'Perplexity Comet'; Path = "$env:LOCALAPPDATA\Perplexity\Comet\User Data"; ExtSub = 'Extensions'; Settings = 'chrome://extensions/'; AiBrowser = $true },
        @{ Name = 'BrowserOS';       Path = "$env:LOCALAPPDATA\BrowserClaw\User Data";       ExtSub = 'Extensions'; Settings = 'chrome://extensions/'; AiBrowser = $true },
        @{ Name = 'Dia';             Path = "$env:LOCALAPPDATA\Dia\User Data";               ExtSub = 'Extensions'; Settings = 'chrome://extensions/'; AiBrowser = $true },
        @{ Name = 'Atlas';           Path = "$env:LOCALAPPDATA\Atlas\User Data";             ExtSub = 'Extensions'; Settings = 'chrome://extensions/'; AiBrowser = $true },
        @{ Name = 'Firefox'; Path = "$env:APPDATA\Mozilla\Firefox\Profiles";            ExtSub = '';           Settings = 'about:addons' }
    )
    foreach ($b in $browsers) {
        if (-not (Test-Path $b.Path)) { continue }
        if ($b.Name -eq 'Firefox') {
            Get-ChildItem $b.Path -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $profiles += [PSCustomObject]@{ Browser = 'Firefox'; Profil = $_.Name; Pfad = $_.FullName; Settings = $b.Settings; AiBrowser = $false }
            }
        } else {
            $dirs = @(Get-ChildItem $b.Path -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })
            foreach ($d in $dirs) {
                $profiles += [PSCustomObject]@{ Browser = $b.Name; Profil = $d.Name; Pfad = $d.FullName; Settings = $b.Settings; AiBrowser = [bool]$b.AiBrowser }
            }
        }
    }
    # Tor Browser (Firefox-basiert, portabel)
    $deskTop = [Environment]::GetFolderPath('Desktop')
    $pubDesk = [Environment]::GetFolderPath('CommonDesktopDirectory')
    $torRoots = @(
        (Join-Path $deskTop 'Tor Browser'), (Join-Path $pubDesk 'Tor Browser'),
        "$env:LOCALAPPDATA\Tor Browser",
        'C:\Program Files\Tor Browser', 'C:\Program Files (x86)\Tor Browser'
    )
    foreach ($r in $torRoots) {
        foreach ($sub in @('Browser\TorBrowser\Data\Browser', 'TorBrowser\Data\Browser', 'Data\Browser')) {
            $profRoot = Join-Path $r $sub
            if (Test-Path $profRoot) {
                Get-ChildItem $profRoot -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like 'profile*' } | ForEach-Object {
                        $profiles += [PSCustomObject]@{ Browser = 'Tor'; Profil = $_.Name; Pfad = $_.FullName; Settings = 'about:addons'; AiBrowser = $false }
                    }
            }
        }
    }
    return $profiles
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

function Get-SysPilotExtManifestInfo {
    <# Liest manifest.json einer Chromium-Extension (Permissions,
       Host-Permissions, Content-Scripts, Manifest-Version).
       Rueckgabe: PSCustomObject oder $null. #>
    param([Parameter(Mandatory)][string]$ProfilePath,
          [Parameter(Mandatory)][string]$ExtId,
          [string]$Version = '')
    $base = Join-Path $ProfilePath ("Extensions\" + $ExtId)
    if (-not (Test-Path $base)) {
        # Chromium-IDs sind lowercase; manche Browser nutzen andere Schreibung
        $hit = Get-ChildItem (Join-Path $ProfilePath 'Extensions') -Directory -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -ieq $ExtId } | Select-Object -First 1
        if ($hit) { $base = $hit.FullName }
    }
    if (-not (Test-Path $base)) { return $null }
    $verDir = $null
    if ($Version) {
        $cand = Join-Path $base $Version
        if (Test-Path $cand) { $verDir = $cand }
    }
    if (-not $verDir) {
        $verDir = Get-ChildItem $base -Directory -ErrorAction SilentlyContinue |
                  Sort-Object Name -Descending | Select-Object -First 1
        if ($verDir) { $verDir = $verDir.FullName } else { return $null }
    }
    $mf = Join-Path $verDir 'manifest.json'
    if (-not (Test-Path $mf)) { return $null }
    try {
        $m = Get-Content $mf -Raw -Encoding UTF8 | ConvertFrom-Json
        $perm = @(); $hostp = @(); $csMatch = @()
        if ($m.permissions)        { $perm   = @($m.permissions) }
        if ($m.host_permissions)   { $hostp  = @($m.host_permissions) }
        if ($m.optional_permissions){ $perm  += @($m.optional_permissions) }
        if ($m.content_scripts)    { foreach ($cs in $m.content_scripts) { $csMatch += @($cs.matches) } }
        return [PSCustomObject]@{
            ManifestVersion = [int]$m.manifest_version
            Permissions     = $perm
            HostPermissions = $hostp
            ContentMatches  = $csMatch
            HasUpdateUrl    = [bool]$m.update_url
            Path            = $verDir
        }
    } catch { return $null }
}

function Get-SysPilotExtRisk {
    <# Lokale Risiko-Bewertung einer Extension (ohne Netz).
       Gibt @{ Score; Flags; Level } zurueck. #>
    param($Ext)
    $score = 0; $flags = @()
    $id = "$($Ext.Id)".ToLower(); $nm = "$($Ext.Name)".ToLower()

    # 1) Bekannte Schaedlinge (ID oder Name)
    $blkIds = Get-SysPilotExtBlocklistIds; $blkNm = Get-SysPilotExtBlocklistNames
    if ($blkIds -contains $id) { $score += 100; $flags += 'KRITISCH: bekannte Schaedlings-Extension (Blocklist)' }
    foreach ($bn in $blkNm) { if ($nm -like "*$bn*") { $score += 100; $flags += "KRITISCH: bekannter Rogue-Name ('$bn')"; break } }

    # 1b) Benutzer-Blocklist (persistent)
    foreach ($ub in (Get-SysPilotExtUserBlocklist)) {
        if ($ub -match '^[a-p]{32}$' -and $ub -eq $id) { $score += 80; $flags += 'Auf Benutzer-Blocklist'; break }
        if ($ub -notmatch '^[a-p]{32}$' -and $ub.Length -ge 3 -and $nm -like "*$($ub.ToLower())*") { $score += 80; $flags += "Auf Benutzer-Blocklist ('$ub')"; break }
    }

    # 2) Manifest-Daten
    $mf = $Ext.ManifestInfo
    if ($mf) {
        if ($mf.ManifestVersion -eq 2) { $score += 15; $flags += 'Manifest V2 (veraltet, Chrome schaltet MV2 ab)' }
        foreach ($p in @($mf.Permissions)) {
            switch -Regex ($p) {
                'cookies'          { $score += 20; $flags += 'Liest Cookies (Session-Diebstahl-Risiko)' }
                'browsingData|history|bookmarks' { $score += 10; $flags += "Breiter Zugriff: $p" }
                'webRequest'       { $score += 15; $flags += 'Kann Requests abfangen/aendern (webRequest)' }
                'management|debugger|proxy' { $score += 20; $flags += "Sehr maechtige Permission: $p" }
                'nativeMessaging'  { $score += 10; $flags += 'nativeMessaging (Kommunikation mit lokalem Programm)' }
                'clipboardRead|clipboardWrite' { $score += 8; $flags += 'Clipboard-Zugriff' }
                'tabs'             { $score += 4 }
                'unlimitedStorage|privacy|geolocation|downloads' { $score += 5 }
            }
        }
        $allUrls = @('<all_urls>','*://*/*')
        if (@($mf.HostPermissions) | Where-Object { $allUrls -contains $_ }) {
            $score += 20; $flags += 'Greift auf ALLE Websites zu (host_permissions <all_urls>)'
        }
        if (@($mf.ContentMatches) | Where-Object { $allUrls -contains $_ -or $_ -eq '*://*/*' }) {
            $score += 10; $flags += 'Content-Script auf allen Seiten'
        }
        if (-not $mf.HasUpdateUrl -and $Ext.Browser -notin @('Firefox','Tor')) {
            $score += 3; $flags += 'Kein Update-Kanal (update_url fehlt)'
        }
    }

    # 3) Kategorie-Heuristik (bekannte Ressourcenfresser/Ehrungs-Tracker)
    if ("$($Ext.Kategorie)" -match 'Coupon|Cashback|Cache') { $score += 10; $flags += 'Kategorie: bekannter Ressourcenfresser/Tracker-Typ' }
    if ("$($Ext.Kategorie)" -match 'KI') { $score += 3; $flags += 'KI-Extension (datenschutzrelevant)' }

    $level = 'ok'
    if (-not $Ext.Aktiv) { $level = 'off' }
    elseif ($score -ge 50) { $level = 'kritisch' }
    elseif ($score -ge 25) { $level = 'riskant' }
    elseif ($score -ge 10) { $level = 'beachten' }
    return @{ Score = $score; Flags = $flags; Level = $level }
}

function Get-SysPilotExtensions {
    <# Liest alle Erweiterungen aller Browser-Profile inkl. Manifest-
       Informationen und lokaler Risiko-Bewertung. #>
    $cfg = Get-SysPilotConfig
    $cats = $cfg.ExtensionCategories
    $profiles = Get-SysPilotBrowserProfiles
    $profMap = @{}
    foreach ($p in $profiles) { $profMap[$p.Pfad] = $p }
    $all = @()

    foreach ($p in $profiles) {
        if ($p.Browser -in @('Firefox', 'Tor')) {
            $json = Join-Path $p.Pfad 'extensions.json'
            if (Test-Path $json) {
                try {
                    $data = Get-Content $json -Raw -Encoding UTF8 | ConvertFrom-Json
                    foreach ($a in $data.addons) {
                        if ($a.type -ne 'extension') { continue }
                        $name = $a.defaultLocale.name
                        if (-not $name) { $name = $a.id }
                        $e = [PSCustomObject]@{
                            Browser = $p.Browser; Profil = $p.Profil; Name = $name
                            Id = $a.id; Aktiv = (-not $a.userDisabled); Version = $a.version
                            Kategorie = Get-ExtensionCategory -Name $name -Cats $cats
                            Settings = $p.Settings; AiBrowser = [bool]$p.AiBrowser
                            ManifestInfo = $null; ExtPath = $p.Pfad
                        }
                        $e | Add-Member -NotePropertyName Risk -NotePropertyValue (Get-SysPilotExtRisk $e) -Force
                        $all += $e
                    }
                } catch { }
            }
        } else {
            $extDir = Join-Path $p.Pfad 'Extensions'
            if (-not (Test-Path $extDir)) { continue }
            $prefFile = Join-Path $p.Pfad 'Secure Preferences'
            if (-not (Test-Path $prefFile)) { $prefFile = Join-Path $p.Pfad 'Preferences' }
            if (-not (Test-Path $prefFile)) { continue }
            try {
                $settings = Get-SysPilotChromiumExtensionSettings -PrefPath $prefFile
                if (-not $settings) { continue }
                foreach ($prop in $settings.PSObject.Properties) {
                    $entry = $prop.Value
                    if ($entry.manifest -eq $null) { continue }
                    if ($entry.manifest.type -eq 'theme') { continue }
                    # Eingebaute Komponenten/extensions des Browsers selbst
                    # (location 5=COMPONENT, 9/12-15=Policy/Device-Komponenten)
                    # sind keine Nutzer-Extensions -> rausfiltern.
                    if ($entry.location -ne $null -and [int]$entry.location -in @(5,9,12,13,14,15)) { continue }
                    # Bei normalen Browsern: vom Browser mitgelieferte
                    # Add-ons ausblenden. KI-Browser: deren eingebaute
                    # Agent-Extensions sind das Produkt -> sichtbar lassen.
                    if (-not $p.AiBrowser -and $entry.was_installed_by_default -eq $true -and $entry.from_webstore -eq $false) { continue }
                    $name = $entry.manifest.name
                    if (-not $name) { $name = $prop.Name }
                    $aktiv = ($entry.state -ne 0) -and ($entry.disable_reasons -eq $null -or $entry.disable_reasons.Count -eq 0)
                    $e = [PSCustomObject]@{
                        Browser = $p.Browser; Profil = $p.Profil; Name = $name
                        Id = $prop.Name; Aktiv = $aktiv; Version = $entry.manifest.version
                        Kategorie = Get-ExtensionCategory -Name $name -Cats $cats
                        Settings = $p.Settings; AiBrowser = [bool]$p.AiBrowser
                        ManifestInfo = $null; ExtPath = $p.Pfad
                    }
                    $e.ManifestInfo = Get-SysPilotExtManifestInfo -ProfilePath $p.Pfad -ExtId $prop.Name -Version "$($entry.manifest.version)"
                    $e | Add-Member -NotePropertyName Risk -NotePropertyValue (Get-SysPilotExtRisk $e) -Force
                    $all += $e
                }
            } catch { }
        }
    }
    return $all
}

function Get-SysPilotExtensionStoreUrl {
    <# Beste Store-/Info-URL fuer eine Extension. #>
    param($Ext)
    $id = "$($Ext.Id)"
    if ("$($Ext.Browser)" -eq 'Edge') {
        return "https://microsoftedge.microsoft.com/addons/detail/$id"
    }
    if ("$($Ext.Browser)" -in @('Firefox','Tor')) {
        return "https://addons.mozilla.org/firefox/search/?q=" + [uri]::EscapeDataString("$($Ext.Name)")
    }
    return "https://chromewebstore.google.com/detail/$id"
}

function Test-SysPilotExtHostAlive {
    <# Schneller Erreichbarkeits-Check (TCP 443, 3s) fuer Info-Links.
       Verhindert "Website nicht erreichbar"-Tabs bei toten Quellen. #>
    param([Parameter(Mandatory)][string]$Url)
    try {
        $u = [uri]$Url
        $port = if ($u.IsDefaultPort) { 443 } else { $u.Port }
        $c = New-Object Net.Sockets.TcpClient
        $iar = $c.BeginConnect($u.Host, $port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(3000)
        if ($ok) { try { $c.EndConnect($iar) } catch { $ok = $false } }
        $c.Close()
        return [bool]$ok
    } catch { return $false }
}

function Get-SysPilotExtensionInfoCatalog {
    <# Webkatalog: vertrauenswuerdige Info-/Security-Quellen fuer
       Browser-Extensions (fuer den Info-Button und die Katalog-Ansicht). #>
    return @(
        @{ Name='CRXcavator';            Url='https://crxcavator.io/';                       Cat='Risiko';   Desc='Automatischer Risiko-Score fuer Chrome/Edge/Firefox-Extensions (Duo Security)' },
        @{ Name='Chrome Web Store';      Url='https://chromewebstore.google.com/';            Cat='Store';    Desc='Offizielle Extension-Beschreibung, Berechtigungen, Nutzerzahl, Bewertungen' },
        @{ Name='Edge Add-ons';          Url='https://microsoftedge.microsoft.com/addons/';  Cat='Store';    Desc='Edge-Store mit Angaben zu Publisher und Rechten' },
        @{ Name='Firefox Add-ons (AMO)'; Url='https://addons.mozilla.org/firefox/extensions/';Cat='Store';    Desc='Mozilla-Add-on-Directory mit Review-Status' },
        @{ Name='Chrome-Stats';          Url='https://chrome-stats.com/';                    Cat='Analyse';  Desc='Installationszahlen, Versionshistorie, Update-Aktivitaet' },
        @{ Name='MyWOT';                 Url='https://www.mywot.com/';                        Cat='Reputation'; Desc='Community-Reputationsdaten fuer Domains/Software' },
        @{ Name='Malwarebytes Blog';     Url='https://www.malwarebytes.com/blog/';           Cat='Security'; Desc='Regelmaessige Berichte zu bösartigen Browser-Extensions' },
        @{ Name='The Hacker News';       Url='https://thehackernews.com/';                   Cat='Security'; Desc='News zu Chrome-Extension-Angriffen und Campaigns' },
        @{ Name='Palo Alto Unit 42';     Url='https://unit42.paloaltonetworks.com/';         Cat='Security'; Desc='Threat-Research (z.B. RedDirection-Extension-Kampagne)' },
        @{ Name='Kaspersky Securelist';  Url='https://securelist.com/';                      Cat='Security'; Desc='Analysen von Extension-Malware und Adware' },
        @{ Name='Google Chrome Release Notes'; Url='https://developer.chrome.com/docs/extensions/develop/migrate'; Cat='Doku'; Desc='Manifest-V2-Abkuendigung und Extensions-Richtlinien' }
    )
}

function Find-SysPilotExtensionCrxRisk {
    <# Optionale Online-Risikoabfrage bei CRXcavator (kostenlos, ~1 Req/s).
       Nur Chromium-Store-IDs (32 Zeichen a-p). Gibt pro Extension
       @{ CrxScore; CrxUsers; CrxRemoved; CrxUrl; CrxError } zurueck. #>
    param([array]$Exts, [int]$Limit = 20)
    $out = @{}
    $n = 0
    foreach ($e in $Exts) {
        if ($n -ge $Limit) { break }
        $id = "$($e.Id)"
        if ($id -notmatch '^[a-p]{32}$') { continue }   # nur Chrome-Store-IDs
        $n++
        $rec = @{ CrxScore=$null; CrxUsers=$null; CrxRemoved=$false; CrxUrl="https://crxcavator.io/report/$id"; CrxError=$null }
        try {
            $rep = Invoke-RestMethod -Uri "https://api.crxcavator.io/v1/report/$id" -TimeoutSec 10 -ErrorAction Stop
            $best = $null
            foreach ($r in @($rep)) {
                if (-not $best -or "$($r.version)" -eq "$($e.Version)") { $best = $r; if ("$($r.version)" -eq "$($e.Version)") { break } }
            }
            if ($best) {
                if ($best.risk -and $best.risk.total -ne $null) { $rec.CrxScore = [int]$best.risk.total }
                if ($best.webstore) {
                    if ($best.webstore.users -ne $null) { $rec.CrxUsers = $best.webstore.users }
                    if ($best.webstore.name) { }
                }
                $rec.CrxUrl = "https://crxcavator.io/report/$id/$($best.version)"
            } else { $rec.CrxRemoved = $true }
        } catch { $rec.CrxError = $_.Exception.Message }
        $out[$id] = $rec
        Start-Sleep -Milliseconds 400
    }
    return $out
}

function Remove-SysPilotChromiumExtension {
    <# Entfernt eine Chromium-Extension ROBUST:
       - Bearbeitet Secure Preferences UND Preferences (falls vorhanden)
       - ROHE JSON-Text-Entfernung via Remove-SysPilotJsonPropertyText:
         kein ConvertTo-Json-Rewrite -> immun gegen doppelte Schluessel
         (Edge-Dateien!) und erhaelt Dateiformatierung
       - Entfernt settings-Eintrag UND protection.macs-Reste
       - Loescht Extensions-Ordner
       - Verifiziert das Ergebnis durch erneutes Lesen der Settings
       Gibt @{ Ok; Message; PrefRemoved; FolderRemoved; Verified } zurück. #>
    param(
        [Parameter(Mandatory)][string]$ProfilePath,
        [Parameter(Mandatory)][string]$ExtId,
        [string]$PrefFile = ''
    )
    $prefFiles = @()
    if ($PrefFile) { $prefFiles = @($PrefFile) }
    else {
        foreach ($n in @('Secure Preferences','Preferences')) {
            $p = Join-Path $ProfilePath $n
            if (Test-Path $p) { $prefFiles += $p }
        }
    }
    $idToken = '"' + $ExtId + '"'
    $prefRemoved = $false; $prefFilesTouched = @()

    foreach ($pf in $prefFiles) {
        $raw = $null
        try { $raw = [IO.File]::ReadAllText($pf) } catch { continue }
        if (-not $raw -or $raw -notlike "*$idToken*") { continue }
        # Backup
        try { Copy-Item $pf "$pf.syspilot-bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')" -Force -ErrorAction Stop }
        catch { return @{ Ok=$false; Message="Backup fehlgeschlagen: $($_.Exception.Message)"; PrefRemoved=$false; FolderRemoved=$false; Verified=$false } }
        # Roh-Entfernung: alle "<id>":-Eintraege (settings + protection.macs)
        $new = $raw; $cnt = 0
        while ($cnt -lt 12) {
            $r = Remove-SysPilotJsonPropertyText -Json $new -Key $ExtId
            if ($null -eq $r -or $r -eq $new) { break }
            $new = $r; $cnt++
        }
        if ($cnt -gt 0) {
            try {
                [IO.File]::WriteAllText($pf, $new, (New-Object Text.UTF8Encoding($false)))
                $prefRemoved = $true; $prefFilesTouched += (Split-Path $pf -Leaf)
            } catch {
                return @{ Ok=$false; Message="Schreiben fehlgeschlagen ($pf): $($_.Exception.Message)"; PrefRemoved=$false; FolderRemoved=$false; Verified=$false }
            }
        }
    }

    # Programm-/Datenuordner loeschen (Paritaet mit CleanSweep:
    # Extensions\<id> + Local/Sync Extension Settings)
    $folderRemoved = $false
    foreach ($rel in @("Extensions\$ExtId", "Local Extension Settings\$ExtId", "Sync Extension Settings\$ExtId")) {
        $d = Join-Path $ProfilePath $rel
        if (Test-Path $d) {
            try { Remove-Item $d -Recurse -Force -ErrorAction Stop; $folderRemoved = $true }
            catch { }
        }
    }

    # Verifikation: Settings erneut lesen
    $verified = $false
    if ($prefRemoved) {
        $stillThere = $false
        foreach ($pf in $prefFiles) {
            try {
                $set = Get-SysPilotChromiumExtensionSettings -PrefPath $pf
                if ($set -and ($set.PSObject.Properties.Name -contains $ExtId)) { $stillThere = $true; break }
            } catch { }
        }
        $verified = -not $stillThere
    }

    if (-not $prefRemoved -and -not $folderRemoved) {
        return @{ Ok=$false; Message='Extension nicht gefunden (weder in Preferences noch als Ordner)'; PrefRemoved=$false; FolderRemoved=$false; Verified=$false }
    }
    $msg = 'Entfernt'
    if ($prefRemoved) { $msg += " (Prefs: $($prefFilesTouched -join '+'))" }
    if ($folderRemoved) { $msg += ' + Programmdateien' }
    else { $msg += ' - Programmdateien nicht loeschbar (Browser laeuft?)' }
    if ($prefRemoved) { $msg += $(if ($verified) { ' [verifiziert]' } else { ' [ACHTUNG: Eintrag evtl. noch vorhanden - Browser neu starten]' }) }
    return @{ Ok=$true; Message=$msg; PrefRemoved=$prefRemoved; FolderRemoved=$folderRemoved; Verified=$verified }
}

function Show-SysPilotExtensionReport {
    <# Konsolen-Report (bleibt fuer Menue/Fallback). Schreibt zusaetzlich
       in die WPF-Aktivitaetskonsole, falls ein Fenster offen ist. #>
    $lines = New-Object System.Collections.Generic.List[string]
    $say = { param($t,$c='Gray') $lines.Add($t); Write-SysPilotPanelLog $t }
    & $say "=== Browser-Erweiterungen: Analyse ==="
    $ext = @(Get-SysPilotExtensions)
    if ($ext.Count -eq 0) { & $say 'Keine Erweiterungen gefunden.' 'Green'; return }

    $krit = @($ext | Where-Object { $_.Risk.Level -eq 'kritisch' })
    $risk = @($ext | Where-Object { $_.Risk.Level -eq 'riskant' })
    $beacht = @($ext | Where-Object { $_.Risk.Level -eq 'beachten' })
    & $say ("Gefunden: {0} in {1} Browser(n) | Kritisch: {2} | Riskant: {3} | Beachten: {4}" -f $ext.Count, (($ext | Select-Object Browser -Unique).Count), $krit.Count, $risk.Count, $beacht.Count) 'Cyan'

    foreach ($e in ($ext | Sort-Object { $_.Risk.Score } -Descending | Select-Object -First 15)) {
        $lvl = switch ($e.Risk.Level) { 'kritisch' {'[KRITISCH]'} 'riskant' {'[riskant]'} 'beachten' {'[achtung]'} default {''} }
        & $say ("  {0} {1} ({2}/{3}) Score={4} v{5}" -f $lvl, $e.Name, $e.Browser, $e.Profil, $e.Risk.Score, $e.Version)
        foreach ($f in @($e.Risk.Flags | Select-Object -First 3)) { & $say "      - $f" }
    }

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
    <# WPF-Fenster: Extension-Liste mit Mehrfachauswahl (Haekchen),
       Browser-Filter als Checkboxen, Sortierung, Sicherheits-Flags
       (informativ - Herbert beurteilt), CRX-Check, Webkatalog,
       Bereinigung mit "alle Browser?"-Frage.
       Aufbau wie DrvStudio: Statuskonsole unten (Add-SysPilotAssistant-
       ToWindow), Herbert-Assistent per Button.
       Daten laden im Hintergrund-Runspace, UI bleibt reaktiv. #>
    if (-not [Environment]::UserInteractive) { Show-SysPilotExtensionReport; return }
    if (-not ('System.Windows.Markup.XamlReader' -as [type])) {
        try { Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop } catch {
            Show-SysPilotExtensionReport; return
        }
    }
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { Show-SysPilotExtensionReport; return }

    $pal = Get-SysPilotWpfPalette
    $bc = { param($h) [Windows.Media.BrushConverter]::new().ConvertFromString($h) }
    $script:_extVms = @()
    $script:_extFiltered = @()
    $script:_extHerbertNotes = @{}
    $modDir = Split-Path -Parent $PSCommandPath
    if (-not $modDir -or -not (Test-Path (Join-Path $modDir 'Common.psm1'))) {
        $modDir = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
    }
    if (-not $modDir) { $modDir = $script:SysPilotRoot }

    # ---------- Browser-Checkboxen (installierte Profile, schnell) ----------
    $profiles = @(Get-SysPilotBrowserProfiles)
    $browserNames = @($profiles | ForEach-Object { $_.Browser } | Sort-Object -Unique)
    $aiNames = @($profiles | Where-Object { $_.AiBrowser } | ForEach-Object { $_.Browser } | Sort-Object -Unique)

    # ---------- XAML ----------
    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="SysPilot - Browser-Erweiterungen" Width="1020" Height="660"
        MinWidth="800" MinHeight="500" WindowStartupLocation="CenterScreen"
        Background="$($pal.Bg)" Foreground="$($pal.Fg)"
        FontFamily="Segoe UI" FontSize="12">
  <Window.Resources>
    <Style TargetType="ListBoxItem">
      <Setter Property="Padding" Value="6,4"/>
      <Setter Property="Foreground" Value="#FFEAEAF2"/>
      <Setter Property="FontSize" Value="12"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#FF34344E"/></Trigger>
        <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#CCE4EAF2"/><Setter Property="Foreground" Value="#FF1E1E2E"/></Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="#FFE0E0E0"/><Setter Property="Background" Value="Transparent"/>
      <Setter Property="Padding" Value="8,4"/>
      <Style.Triggers>
        <Trigger Property="IsHighlighted" Value="True"><Setter Property="Background" Value="#FF34344E"/><Setter Property="Foreground" Value="#FFEAEAF2"/></Trigger>
        <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#CCE4EAF2"/><Setter Property="Foreground" Value="#FF1E1E2E"/></Trigger>
      </Style.Triggers>
    </Style>
  </Window.Resources>
  <DockPanel Margin="10">
    <Border DockPanel.Dock="Top" Padding="0,0,0,8">
      <StackPanel>
        <DockPanel>
          <TextBlock Text="Browser-Erweiterungen" FontSize="18" FontWeight="Bold"
                     Foreground="$($pal.Accent)" VerticalAlignment="Center"/>
          <TextBlock x:Name="SummaryText" FontSize="11" Foreground="$($pal.Muted)"
                     HorizontalAlignment="Right" VerticalAlignment="Center"/>
        </DockPanel>
        <TextBlock Text="Browser (Haken = einbezogen):" FontSize="11" Foreground="$($pal.Muted)" Margin="0,6,0,2"/>
        <WrapPanel x:Name="BrowserPanel"/>
        <DockPanel Margin="0,6,0,0">
          <TextBox x:Name="SearchBox" Width="200" Padding="6,3"
                   ToolTip="Name, ID oder Browser filtern"/>
          <ComboBox x:Name="SortBox" Width="150" Margin="8,0,0,0"
                    ToolTip="Sortierung">
            <ComboBoxItem Content="Sortierung: Risiko" IsSelected="True" Tag="risk"/>
            <ComboBoxItem Content="Sortierung: Browser" Tag="browser"/>
            <ComboBoxItem Content="Sortierung: Name" Tag="name"/>
            <ComboBoxItem Content="Sortierung: Kategorie" Tag="cat"/>
            <ComboBoxItem Content="Sortierung: Version" Tag="ver"/>
          </ComboBox>
          <CheckBox x:Name="OnlyRisky" Content="Nur auffaellig" Margin="12,0,0,0"
                    VerticalAlignment="Center" ToolTip="Nur Extensions mit Risiko-Flags anzeigen"/>
          <Button x:Name="BtnSelAll" Content="Alle markieren" Padding="8,2" Margin="14,0,0,0" ToolTip="Alle sichtbaren Eintraege markieren"/>
          <Button x:Name="BtnSelNone" Content="Markierung aufheben" Padding="8,2" Margin="6,0,0,0" ToolTip="Alle Markierungen aufheben"/>
        </DockPanel>
        <WrapPanel Margin="0,6,0,0">
          <Button x:Name="BtnHerbert" Content="Herbert beurteilen" Padding="10,3" Margin="0,0,6,0"
                  ToolTip="Herbert prueft die riskantesten Extensions und gibt eine Einschaetzung"/>
          <Button x:Name="BtnCrx" Content="CRX-Check" Padding="10,3" Margin="0,0,6,0"
                  ToolTip="Online-Risiko-Score via CRXcavator (max. 20, ~1/s)"/>
          <Button x:Name="BtnInfo" Content="Info" Padding="10,3" Margin="0,0,6,0"
                  ToolTip="Store-Seite + CRXcavator-Report der markierten Extension"/>
          <Button x:Name="BtnOpen" Content="Einstellungen" Padding="10,3" Margin="0,0,6,0"
                  ToolTip="Oeffnet die Browser-Erweiterungsseite"/>
          <Button x:Name="BtnCatalog" Content="Webkatalog" Padding="10,3" Margin="0,0,6,0"
                  ToolTip="Vertrauenswuerdige Security-Quellen fuer Extensions"/>
          <Button x:Name="BtnExtMgr" Content="Ext-Manager" Padding="10,3" Margin="0,0,6,0"
                  ToolTip="Installiert die SysPilot Extension-Manager-Extension (chrome.management: Suchen, Enable/Disable, Entfernen, HTML-Export/Import)"/>
          <Button x:Name="BtnRemove" Content="Entfernen" Padding="10,3" Margin="0,0,6,0"
                  Foreground="$($pal.Danger)"
                  ToolTip="Entfernt markierte Chromium-Extensions (Backup + Bestaetigung)"/>
          <Button x:Name="BtnReport" Content="Report" Padding="10,3"/>
          <Button x:Name="BtnClose" Content="Schliessen" Padding="10,3" HorizontalAlignment="Right"/>
        </WrapPanel>
      </StackPanel>
    </Border>
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="300"/>
      </Grid.ColumnDefinitions>
      <ListBox x:Name="ExtList" Grid.Column="0" Background="Transparent" BorderThickness="0"
               SelectionMode="Multiple">
        <ListBox.ItemTemplate>
          <DataTemplate>
            <Grid Margin="0,2">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="24"/>
                <ColumnDefinition Width="60"/>
                <ColumnDefinition Width="245"/>
                <ColumnDefinition Width="105"/>
                <ColumnDefinition Width="55"/>
                <ColumnDefinition Width="195"/>
              </Grid.ColumnDefinitions>
              <CheckBox Grid.Column="0" IsChecked="{Binding Selected, Mode=TwoWay}"
                        VerticalAlignment="Center"/>
              <TextBlock Grid.Column="1" Text="{Binding RiskLabel}" FontWeight="Bold"
                         Foreground="{Binding RiskBrush}"/>
              <TextBlock Grid.Column="2" Text="{Binding Name}" TextTrimming="CharacterEllipsis"/>
              <TextBlock Grid.Column="3" Text="{Binding BrowserLabel}" FontSize="11"
                         TextTrimming="CharacterEllipsis"/>
              <TextBlock Grid.Column="4" Text="{Binding Version}" FontSize="11"/>
              <TextBlock Grid.Column="5" Text="{Binding FlagText}" FontSize="10"
                         TextTrimming="CharacterEllipsis"/>
            </Grid>
          </DataTemplate>
        </ListBox.ItemTemplate>
      </ListBox>
      <Border Grid.Column="1" Margin="10,0,0,0" Padding="10"
              Background="$($pal.Panel)" BorderBrush="$($pal.Border)" BorderThickness="1" CornerRadius="4">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel>
            <TextBlock x:Name="DetailName" FontSize="15" FontWeight="Bold"
                       Foreground="$($pal.Accent)" TextWrapping="Wrap"/>
            <TextBlock x:Name="DetailMeta" FontSize="11" Foreground="$($pal.Muted)" Margin="0,4,0,8" TextWrapping="Wrap"/>
            <TextBlock Text="Risiko-Flags (informativ):" FontWeight="Bold" Foreground="$($pal.Warn)"/>
            <TextBlock x:Name="DetailFlags" FontSize="11" Foreground="$($pal.Fg)"
                       TextWrapping="Wrap" Margin="0,2,0,8"/>
            <TextBlock Text="Permissions:" FontWeight="Bold" Foreground="$($pal.Warn)"/>
            <TextBlock x:Name="DetailPerms" FontSize="11" Foreground="$($pal.Fg)"
                       TextWrapping="Wrap" Margin="0,2,0,8"/>
            <TextBlock x:Name="DetailHerbert" FontSize="11" Foreground="$($pal.Accent2)" TextWrapping="Wrap" Margin="0,0,0,8"/>
            <TextBlock x:Name="DetailCrx" FontSize="11" Foreground="$($pal.Accent2)" TextWrapping="Wrap" Margin="0,0,0,8"/>
            <TextBlock x:Name="DetailHint" FontSize="11" Foreground="$($pal.Muted)" TextWrapping="Wrap"/>
          </StackPanel>
        </ScrollViewer>
      </Border>
    </Grid>
  </DockPanel>
</Window>
"@
    $win = [Windows.Markup.XamlReader]::Parse($xaml)
    if (-not $win) { throw 'XAML parse fehlgeschlagen' }
    Set-SysPilotWpfDarkTheme -Win $win
    Set-SysPilotMenuWindowPosition -Win $win -Width 1040 -Height 700

    $extList = $win.FindName('ExtList')
    $search = $win.FindName('SearchBox')
    $sortBox = $win.FindName('SortBox')
    $onlyRisky = $win.FindName('OnlyRisky')
    $bPanel = $win.FindName('BrowserPanel')
    $sumTxt = $win.FindName('SummaryText')
    $dName = $win.FindName('DetailName'); $dMeta = $win.FindName('DetailMeta')
    $dFlags = $win.FindName('DetailFlags'); $dPerms = $win.FindName('DetailPerms')
    $dHerb = $win.FindName('DetailHerbert'); $dCrx = $win.FindName('DetailCrx')
    $dHint = $win.FindName('DetailHint')

    # Browser-Checkboxen
    $browserChecks = @{}
    foreach ($b in $browserNames) {
        $cb = New-Object Windows.Controls.CheckBox
        $cb.Content = $(if ($aiNames -contains $b) { "$b [KI]" } else { $b })
        $cb.IsChecked = $true; $cb.Margin = '0,0,12,2'; $cb.FontSize = '11'
        $cb.ToolTip = "Browser $b ein-/ausschalten"
        $bn = $b
        $cb.Add_Click({ & $applyFilter })
        [void]$bPanel.Children.Add($cb)
        $browserChecks[$bn] = $cb
    }

    # ---------- Helfer ----------
    $say = { param($t) try { Write-Host $t } catch {}; try { Write-SysPilotPanelLog $t } catch {} }

    # Generischer Async-Runner: Jobs landen in $asyncJobs (ArrayList in
    # Funktions-Scope, bleibt waehrend ShowDialog lebendig). EIN
    # DispatcherTimer im Funktions-Scope pollt alle Jobs - gleiches
    # Muster wie im SmartDriver-Studio ($poll + Shared-State).
    # WICHTIG: keine GetNewClosure noetig, da die Funktion waehrend
    # ShowDialog blockiert und ihre Lokalen sichtbar bleiben.
    $asyncJobs = New-Object System.Collections.ArrayList
    $runAsync = {
        param($scriptText, $arg, [scriptblock]$onDone)
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'MTA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
        $ps = [powershell]::Create(); $ps.Runspace = $rs
        [void]$ps.AddScript($scriptText)
        [void]$ps.AddArgument($arg)
        $h = $ps.BeginInvoke()
        [void]$asyncJobs.Add(@{ ps=$ps; rs=$rs; h=$h; done=$false; onDone=$onDone })
    }
    $poll = New-Object Windows.Threading.DispatcherTimer
    $poll.Interval = [timespan]::FromMilliseconds(400)
    $poll.Add_Tick({
        foreach ($job in @($asyncJobs)) {
            if ($job.h.IsCompleted -and -not $job.done) {
                $job.done = $true
                $out = @()
                try { $out = @($job.ps.EndInvoke($job.h)) } catch { $out = @() }
                try { $job.ps.Dispose(); $job.rs.Dispose() } catch {}
                try { [void]$asyncJobs.Remove($job) } catch {}
                try { & $job.onDone $out } catch {
                    try { Write-SysPilotPanelLog "Async-Fehler: $($_.Exception.Message)" } catch {}
                }
            }
        }
    })
    $poll.Start()
    $win.Add_Closed({ try { $poll.Stop() } catch {} })

    # ---------- Datenmodell ----------
    $buildVm = {
        param($e)
        $lvl = $e.Risk.Level
        $rLabel = switch ($lvl) { 'kritisch' {'KRITISCH'} 'riskant' {'riskant'} 'beachten' {'Achtung'} 'off' {'aus'} default {'ok'} }
        $rBrush = & $bc $(switch ($lvl) { 'kritisch' {'#FFE53935'} 'riskant' {'#FFFB8C00'} 'beachten' {'#FFF57F17'} 'off' {'#FF90A4AE'} default {'#FF43A047'} })
        $permTxt = ''
        if ($e.ManifestInfo -and $e.ManifestInfo.Permissions) { $permTxt = (@($e.ManifestInfo.Permissions) -join ', ') }
        $note = $script:_extHerbertNotes["$($e.Id)"]
        [pscustomobject]@{
            Ext = $e; Name = $e.Name; Version = "$($e.Version)"; Browser = $e.Browser
            BrowserLabel = "$($e.Browser)$(if($e.AiBrowser){' [KI]'}else{''})$(if($e.Profil -and $e.Profil -ne 'Default' -and $e.Profil -ne $e.Browser){" / $($e.Profil)"}else{''})"
            RiskLabel = $rLabel; RiskBrush = $rBrush
            RiskOrder = $(switch ($lvl) { 'kritisch'{0} 'riskant'{1} 'beachten'{2} 'off'{4} default{3} })
            RiskLevel = $lvl; RiskScore = $e.Risk.Score
            FlagText = (@(@($e.Risk.Flags) | Select-Object -First 1) + $(if($note){@("H: $($note.Substring(0,[math]::Min(40,$note.Length)))")}else{@()})) -join '; '
            PermText = $permTxt; Selected = $false
        }
    }

    $applyFilter = {
        $q = "$($search.Text)".Trim().ToLower()
        $activeBrowsers = @($browserChecks.Keys | Where-Object { $browserChecks[$_].IsChecked })
        $riskOnly = [bool]$onlyRisky.IsChecked
        $sortMode = "$($sortBox.SelectedItem.Tag)"
        $sorted = switch ($sortMode) {
            'browser' { $script:_extVms | Sort-Object Browser, Name }
            'name'    { $script:_extVms | Sort-Object Name }
            'cat'     { $script:_extVms | Sort-Object { $_.Ext.Kategorie }, Name }
            'ver'     { $script:_extVms | Sort-Object { "$($_.Ext.Version)" } }
            default   { $script:_extVms | Sort-Object RiskOrder, Browser, Name }
        }
        $list = @($sorted | Where-Object {
            $activeBrowsers -contains $_.Browser -and
            (-not $q -or "$($_.Name) $($_.Ext.Id) $($_.Browser)".ToLower().Contains($q)) -and
            (-not $riskOnly -or $_.RiskLevel -in @('kritisch','riskant','beachten'))
        })
        $extList.ItemsSource = $list
        $script:_extFiltered = $list
        $krit = @($list | Where-Object {$_.RiskLevel -eq 'kritisch'}).Count
        $risk = @($list | Where-Object {$_.RiskLevel -eq 'riskant'}).Count
        $sumTxt.Text = "$($list.Count) angezeigt | $krit kritisch | $risk riskant"
    }
    $search.Add_TextChanged({ & $applyFilter })
    $sortBox.Add_SelectionChanged({ & $applyFilter })
    $onlyRisky.Add_Click({ & $applyFilter })

    # Detail-Panel (erste markierte Extension)
    $extList.Add_SelectionChanged({
        $vm = $extList.SelectedItem
        if (-not $vm) { return }
        $e = $vm.Ext
        $dName.Text = "$($e.Name)  ($($e.Version))"
        $aiTag = if ($e.AiBrowser) { ' [KI-Browser]' } else { '' }
        $dMeta.Text = "$($e.Browser)$aiTag | Profil: $($e.Profil) | Kategorie: $($e.Kategorie) | Status: $(if($e.Aktiv){'aktiv'}else{'deaktiviert'}) | ID: $($e.Id)"
        $dFlags.Text = if (@($e.Risk.Flags).Count) { ($e.Risk.Flags -join "`n") } else { 'Keine Auffaelligkeiten.' }
        $dPerms.Text = if ($vm.PermText) { $vm.PermText } else { '(keine Manifest-Permissions gelesen)' }
        $hn = $script:_extHerbertNotes["$($e.Id)"]
        $dHerb.Text = if ($hn) { "Herbert: $hn" } else { '' }
        $dCrx.Text = ''
        if ($null -ne $e.CrxScore) { $dCrx.Text = "CRXcavator Score: $($e.CrxScore) | Store-Nutzer: $($e.CrxUsers) | $($e.CrxUrl)" }
        $dHint.Text = ''
    })

    # ---------- Aktionen ----------
    $btnInfo = $win.FindName('BtnInfo'); $btnOpen = $win.FindName('BtnOpen')
    $btnCat = $win.FindName('BtnCatalog'); $btnRem = $win.FindName('BtnRemove')
    $btnExtMgr = $win.FindName('BtnExtMgr')
    $btnRep = $win.FindName('BtnReport'); $btnHerb = $win.FindName('BtnHerbert')
    $btnCrx = $win.FindName('BtnCrx'); $btnClose = $win.FindName('BtnClose')
    $btnAll = $win.FindName('BtnSelAll'); $btnNone = $win.FindName('BtnSelNone')

    $btnAll.Add_Click({ foreach ($v in $script:_extFiltered) { $v.Selected = $true }; $extList.Items.Refresh() })
    $btnNone.Add_Click({ foreach ($v in $script:_extVms) { $v.Selected = $false }; $extList.Items.Refresh() })
    $btnClose.Add_Click({ $win.Close() })
    $btnRep.Add_Click({ Show-SysPilotExtensionReport })
    $btnCat.Add_Click({
        $cat = Get-SysPilotExtensionInfoCatalog
        $lines = ($cat | ForEach-Object { "[$($_.Cat)] $($_.Name)`n    $($_.Url)`n    $($_.Desc)" }) -join "`n`n"
        [System.Windows.MessageBox]::Show($lines, 'Extension-Sicherheits-Webkatalog', 'OK', 'Information') | Out-Null
    })
    $btnExtMgr.Add_Click({
        $r = Install-SysPilotExtManagerExtension
        if ($r.Ok) {
            & $say $r.Message
            [System.Windows.MessageBox]::Show($r.Message + "`n`nPfad (kopiert): " + $r.Dir, 'SysPilot Extension Manager', 'OK', 'Information') | Out-Null
        } else {
            [System.Windows.MessageBox]::Show($r.Message, 'SysPilot Extension Manager', 'OK', 'Warning') | Out-Null
        }
    })
    $btnOpen.Add_Click({
        $vm = $extList.SelectedItem; if (-not $vm) { return }
        try { Start-Process $vm.Ext.Settings } catch { [System.Windows.MessageBox]::Show("Konnte nicht geoefnet werden: $($_.Exception.Message)",'SysPilot','OK','Warning') | Out-Null }
        & $say "Einstellungen geoeffnet: $($vm.Ext.Browser)"
    })
    $btnInfo.Add_Click({
        $vms = @($script:_extVms | Where-Object { $_.Selected })
        if ($vms.Count -eq 0 -and $extList.SelectedItem) { $vms = @($extList.SelectedItem) }
        if ($vms.Count -eq 0) { [System.Windows.MessageBox]::Show('Keine Extension markiert.','SysPilot','OK','Information') | Out-Null; return }
        # CRXcavator einmalig auf Erreichbarkeit pruefen (Tcp 443, 3s)
        if ($null -eq $script:_extCrxAlive) { $script:_extCrxAlive = Test-SysPilotExtHostAlive 'https://crxcavator.io' }
        foreach ($vm in ($vms | Select-Object -First 5)) {
            $e = $vm.Ext
            $opened = @()
            $isStoreId = "$($e.Id)" -match '^[a-p]{32}$'
            # Store-Detail nur bei echten Store-IDs; sonst Name-Suche
            if ($isStoreId -or "$($e.Browser)" -in @('Firefox','Tor')) {
                try { Start-Process (Get-SysPilotExtensionStoreUrl $e); $opened += 'Store' } catch {}
                Start-Sleep -Milliseconds 300
            } else {
                $q = [uri]::EscapeDataString("$($e.Name) browser extension")
                try { Start-Process "https://www.google.com/search?q=$q"; $opened += 'Suche' } catch {}
            }
            if ($isStoreId -and $script:_extCrxAlive) {
                try { Start-Process "https://crxcavator.io/report/$($e.Id)"; $opened += 'CRXcavator' } catch {}
                Start-Sleep -Milliseconds 300
            }
            & $say "Info geoeffnet: $($e.Name) ($(($opened) -join ' + '))"
        }
        if (-not $script:_extCrxAlive) { & $say 'Hinweis: crxcavator.io nicht erreichbar - CRX-Links uebersprungen' }
    })

    # Herbert beurteilen (async, Runspace)
    $btnHerb.Add_Click({
        $targets = @($script:_extVms | Where-Object { $_.RiskLevel -in @('kritisch','riskant','beachten') -and $_.Ext.Aktiv } | Sort-Object RiskScore -Descending | Select-Object -First 15)
        if ($targets.Count -eq 0) { & $say 'Keine riskanten Extensions zum Beurteilen.'; return }
        $btnHerb.IsEnabled = $false
        & $say "Herbert beurteilt $($targets.Count) Extensions (dauert 30-90s) ..."
        $payload = @($targets | ForEach-Object {
            [pscustomobject]@{ id="$($_.Ext.Id)"; name="$($_.Ext.Name)"; browser="$($_.Ext.Browser)"; score=$_.RiskScore; flags=@($_.Ext.Risk.Flags) }
        })
        $jobScript = {
            param($st)
            Import-Module (Join-Path $st.md 'Common.psm1') -Force -ErrorAction SilentlyContinue
            Import-Module (Join-Path $st.md 'AiAssist.psm1') -Force -ErrorAction SilentlyContinue
            $lines = ($st.payload | ForEach-Object { "- id=$($_.id) | $($_.name) ($($_.browser)) | Score=$($_.score) | Flags: $(($_.flags) -join '; ')" }) -join "`n"
            $prompt = @"
Du bist Pilot Herbert, Assistent von SysPilot. Ein Nutzer hat $($st.payload.Count) Browser-Extensions, die ein heuristischer Scan als riskant markiert hat. Der Nutzer VERTRAUT diesen Extensions grundsaetzlich - deine Aufgabe ist NICHT Alarm zu schlagen, sondern DIRIGIEREN, PRUEFEN, BEURTEILEN:
- Welche sind wirklich bedenklich (echte Berechtigungs-Gefahr, bekannter Schaedling, toter Server)?
- Welche sind unkritisch trotz Flags (z.B. Debugger/Permissions sind bei manchen Tools normal)?
- Empfehlung: behalten / deaktivieren / entfernen - kurz und ehrlich.
Antworte FUER JEDE Extension exakt eine Zeile: EXT|<id>|<BEURTEILUNG max 15 Woerter>
Danach maximal 3 Saetze Gesamteinschaetzung auf Deutsch.

Extensions:
$lines
"@
            $r = Invoke-SysPilotAiChat -Prompt $prompt -TimeoutSec 120
            if ($r.Ok) { $r.Text } else { "KI-Fehler: $($r.Error)" }
        }
        & $runAsync $jobScript @{ md=$modDir; payload=$payload } {
            param($out)
            $txt = ($out | Out-String)
            & $say "Herbert-Urteil:`n$txt"
            # EXT|<id>|<note> Zeilen parsen
            foreach ($line in ($txt -split "`n")) {
                if ($line -match '^\s*EXT\|([^|]+)\|(.+)$') {
                    $script:_extHerbertNotes[$Matches[1].Trim()] = $Matches[2].Trim()
                }
            }
            # VMs neu aufbauen (Notizen sichtbar machen)
            foreach ($v in $script:_extVms) { $v.FlagText = ((@($v.Ext.Risk.Flags) | Select-Object -First 1) + $(if($script:_extHerbertNotes["$($v.Ext.Id)"]){@("H: $($script:_extHerbertNotes["$($v.Ext.Id)"].Substring(0,[math]::Min(40,$script:_extHerbertNotes["$($v.Ext.Id)"].Length)))")}else{@()})) -join '; ' }
            $extList.Items.Refresh()
            & $applyFilter
            $btnHerb.IsEnabled = $true
        }
    })

    # CRX-Check (online, gedrosselt)
    $btnCrx.Add_Click({
        if ($null -eq $script:_extCrxAlive) { $script:_extCrxAlive = Test-SysPilotExtHostAlive 'https://crxcavator.io' }
        if (-not $script:_extCrxAlive) { & $say 'CRXcavator ist nicht erreichbar - CRX-Check uebersprungen.'; return }
        $targets = @($script:_extVms | Where-Object { $_.Ext.Id -match '^[a-p]{32}$' -and $null -eq $_.Ext.CrxScore } | Select-Object -First 20)
        if ($targets.Count -eq 0) { & $say 'Keine neuen CRX-Check-Ziele.'; return }
        $btnCrx.IsEnabled = $false
        & $say "CRXcavator-Check fuer $($targets.Count) Extensions ..."
        $res = Find-SysPilotExtensionCrxRisk -Exts ($targets | ForEach-Object { $_.Ext }) -Limit 20
        foreach ($t in $targets) {
            $r = $res["$($t.Ext.Id)"]
            if ($r) {
                $t.Ext | Add-Member -NotePropertyName CrxScore -NotePropertyValue $r.CrxScore -Force
                $t.Ext | Add-Member -NotePropertyName CrxUsers -NotePropertyValue $r.CrxUsers -Force
                $t.Ext | Add-Member -NotePropertyName CrxUrl -NotePropertyValue $r.CrxUrl -Force
                if ($r.CrxError) { & $say "  $($t.Name): CRX-Fehler $($r.CrxError)" }
                elseif ($r.CrxRemoved) { & $say "  $($t.Name): NICHT im Store gefunden (entfernt?)" }
                else { & $say "  $($t.Name): CRX-Score $($r.CrxScore), $($r.CrxUsers) Nutzer" }
            }
        }
        $extList.Items.Refresh()
        $btnCrx.IsEnabled = $true
    })

    # Entfernen (Chromium; mit Backup, Bestaetigung, KI-Browser-Frage,
    # Frage ob in ALLEN Browsern entfernt werden soll)
    # Normalisierte Namen (Store-uebergreifend: Edge/Chrome/Firefox
    # nutzen UNTERSCHIEDLICHE Extension-IDs fuer dieselbe Extension!)
    $normName = {
        param($n)
        $t = ($n -replace '[^a-zA-Z0-9]', '').ToLower()
        $t -replace '(inc|llc|ltd|gmbh|corp|corporation|pty|ag|kg|ohg|se|bv|sarl|sas)$', ''
    }
    # Browser -> Prozessnamen (Tor Browser laeuft als firefox.exe)
    $browserProcs = @{
        'Chrome'           = @('chrome')
        'Edge'             = @('msedge')
        'Brave'            = @('brave')
        'Perplexity Comet' = @('Comet','Perplexity')
        'BrowserOS'        = @('BrowserOS','BrowserClaw','browseros')
        'Firefox'          = @('firefox')
        'Tor'              = @('firefox')
        'Opera'            = @('opera')
        'Arc'              = @('Arc')
        'Vivaldi'          = @('vivaldi')
        'Dia'              = @('Dia')
        'Atlas'            = @('Atlas')
    }

    $btnRem.Add_Click({
        $sel = @($script:_extVms | Where-Object { $_.Selected } | ForEach-Object { $_.Ext })
        if ($sel.Count -eq 0) { [System.Windows.MessageBox]::Show('Keine Extension markiert.','SysPilot','OK','Information') | Out-Null; return }

        # KI-Browser separat fragen
        $aiSel = @($sel | Where-Object { $_.AiBrowser })
        $normSel = @($sel | Where-Object { -not $_.AiBrowser })
        if ($aiSel.Count -gt 0) {
            $aiList = ($aiSel | ForEach-Object { "  - $($_.Name) ($($_.Browser))" }) -join [char]10
            $inc = [System.Windows.MessageBox]::Show("$($aiSel.Count) der Markierten sind KI-Browser-Extensions:`n$aiList`n`nAuch diese entfernen?", 'KI-Browser', 'YesNoCancel', 'Question')
            if ($inc -eq 'Cancel') { return }
            if ($inc -eq 'No') { $sel = $normSel }
        }
        if ($sel.Count -eq 0) { return }

        # Laufende Browser pruefen - sonst ueberschreiben sie die
        # Preferences-Aenderung beim Beenden (klassischer Grund,
        # warum "Entfernen" scheinbar nicht funktioniert!)
        $running = @()
        foreach ($b in (@($sel | ForEach-Object { $_.Browser } | Sort-Object -Unique))) {
            $names = $browserProcs[$b]
            if (-not $names) { continue }
            $hit = $false
            foreach ($pn in $names) { if (Get-Process -Name $pn -ErrorAction SilentlyContinue) { $hit = $true; break } }
            if ($hit) { $running += $b }
        }
        if ($running.Count -gt 0) {
            # Automatisch schliessen (User-Wunsch: keine manuelle Remember)
            & $say "Schliesse laufende Browser automatisch: $($running -join ', ') ..."
            foreach ($b in $running) {
                foreach ($pn in $browserProcs[$b]) {
                    Get-Process -Name $pn -ErrorAction SilentlyContinue | ForEach-Object { try { $_.CloseMainWindow() | Out-Null } catch {} }
                }
            }
            $deadline = (Get-Date).AddSeconds(8)
            while ((Get-Date) -lt $deadline) {
                $still = $false
                foreach ($b in $running) { foreach ($pn in $browserProcs[$b]) { if (Get-Process -Name $pn -ErrorAction SilentlyContinue) { $still = $true } } }
                if (-not $still) { break }
                Start-Sleep -Milliseconds 500
            }
            $stillRunning = @()
            foreach ($b in $running) { foreach ($pn in $browserProcs[$b]) { if (Get-Process -Name $pn -ErrorAction SilentlyContinue) { $stillRunning += $b; break } } }
            if ($stillRunning.Count -gt 0) {
                $stillList = @($stillRunning | Sort-Object -Unique) -join ', '
                $q = [System.Windows.MessageBox]::Show("$stillList liess sich nicht automatisch schliessen.`n`nEin laufender Browser ueberschreibt die Preferences-Aenderung beim Beenden - die Extension kommt dann ZURUECK.`n`n'Ja'     = Browser-Prozess jetzt beenden (offene Tabs gehen verloren)`n'Nein'   = trotzdem entfernen (Extension kann zurueckkommen)`n'Abbrechen' = nichts tun", 'Browser laeuft noch', 'YesNoCancel', 'Warning')
                if ($q -eq 'Cancel') { return }
                if ($q -eq 'Yes') {
                    & $say "Beende $stillList hart (Stop-Process) ..."
                    foreach ($b in @($stillRunning | Sort-Object -Unique)) {
                        foreach ($pn in $browserProcs[$b]) {
                            Get-Process -Name $pn -ErrorAction SilentlyContinue | ForEach-Object { try { Stop-Process -Id $_.Id -Force -ErrorAction Stop } catch {} }
                        }
                    }
                    $deadline2 = (Get-Date).AddSeconds(5)
                    while ((Get-Date) -lt $deadline2) {
                        $left = $false
                        foreach ($b in @($stillRunning | Sort-Object -Unique)) { foreach ($pn in $browserProcs[$b]) { if (Get-Process -Name $pn -ErrorAction SilentlyContinue) { $left = $true } } }
                        if (-not $left) { break }
                        Start-Sleep -Milliseconds 400
                    }
                    & $say "Browser beendet: $stillList"
                } else {
                    & $say "ACHTUNG: $stillList laeuft noch - Entfernung kann ueberschrieben werden!"
                }
            } else {
                & $say "Browser geschlossen: $($running -join ', ')"
            }
        }

        # "In allen Browsern?"-Frage: Duplikate erkennen per ID
        # ODER normalisiertem Namen (Store-IDs unterscheiden sich
        # zwischen Chrome/Edge/Firefox!)
        $selIds = @($sel | ForEach-Object { "$($_.Id)".ToLower() } | Sort-Object -Unique)
        $selNames = @($sel | ForEach-Object { & $normName $_.Name } | Sort-Object -Unique)
        $others = @($script:_extVms | Where-Object {
            -not $_.Selected -and (
                $selIds -contains "$($_.Ext.Id)".ToLower() -or
                ($selNames -contains (& $normName $_.Ext.Name) -and (& $normName $_.Ext.Name).Length -ge 5)
            )
        })
        if ($others.Count -gt 0) {
            $otherBrowsers = @($others | ForEach-Object { $_.Browser } | Sort-Object -Unique) -join ', '
            $oList = ($others | Select-Object -First 12 | ForEach-Object { "  - $($_.Name) ($($_.Browser))" }) -join [char]10
            $q = [System.Windows.MessageBox]::Show("Gleiche Extension wurde auch in NICHT markierten Browsern gefunden ($otherBrowsers):`n$oList$(if($others.Count -gt 12){"`n  ... und $($others.Count-12) weitere"})`n`nSoll die Extension in ALLEN Browsern entfernt werden?`n`nJa = in allen Browsern entfernen`nNein = nur in den markierten Browsern", 'Alle Browser?', 'YesNoCancel', 'Question')
            if ($q -eq 'Cancel') { return }
            if ($q -eq 'Yes') {
                $extra = @($others | ForEach-Object { $_.Ext })
                $sel = @($sel) + @($extra)
            }
        }

        $names = ($sel | ForEach-Object { "  - $($_.Name) ($($_.Browser)/$($_.Profil))" }) -join "`n"
        $ans = [System.Windows.MessageBox]::Show("Folgende $($sel.Count) Extensions wirklich entfernen?`n`n$names`n`nChromium: Secure Preferences + Preferences + Programmordner werden bereinigt (Backup wird angelegt, Ergebnis wird verifiziert). Firefox: bitte manuell in about:addons entfernen.", 'Extensions entfernen', 'YesNo', 'Warning')
        if ($ans -ne 'Yes') { return }

        $okCount = 0; $failCount = 0; $removedList = @()
        foreach ($e in $sel) {
            if ($e.Browser -in @('Firefox','Tor')) {
                & $say "  $($e.Name): Firefox - bitte manuell in about:addons entfernen"
                try { Start-Process $e.Settings } catch {}
                continue
            }
            & $say "  Entferne $($e.Name) ($($e.Browser)/$($e.Profil)) ..."
            $r = Remove-SysPilotChromiumExtension -ProfilePath $e.ExtPath -ExtId $e.Id
            if ($r.Ok) { $okCount++; $removedList += $e; & $say "    OK: $($r.Message)" } else { $failCount++; & $say "    FEHLER: $($r.Message)" }
        }
        & $say "Bereinigung fertig ($okCount ok, $failCount Fehler) - Browser neu starten empfohlen."

        # Erfolgreich entfernte Store-Extensions: Install-Sperre in den
        # Browser-Richtlinien + Benutzer-Blocklist, damit Sync/Store sie
        # nicht erneut installiert ("im Account"-Schutz)
        $removedOk = @($removedList | Where-Object { "$($_.Id)" -match '^[a-p]{32}$' })
        if ($okCount -gt 0 -and $removedOk.Count -gt 0) {
            $q = [System.Windows.MessageBox]::Show("$($removedOk.Count) Store-Extensions wurden entfernt.`n`nInstallations-Sperre in den Browser-Richtlinien setzen?`n`nDamit kann die Extension NICHT erneut installiert werden - auch nicht ueber Account-Sync oder den Store (Blocklist auf Browser-Ebene).`n`nOhne Sperre kann Sync die Extension beim naechsten Start wiederherstellen.", 'Install-Sperre', 'YesNo', 'Question', 'Yes')
            if ($q -eq 'Yes') {
                foreach ($e in $removedOk) {
                    $br = Add-SysPilotExtensionInstallBlock -Browser $e.Browser -ExtId $e.Id
                    if ($br.Ok) {
                        & $say "  Sperre: $($e.Name) ($($e.Browser)) -> $($br.Message)"
                        [void](Add-SysPilotExtUserBlocklist -Term $e.Id)
                    } else { & $say "  Sperre fehlgeschlagen $($e.Name): $($br.Message)" }
                }
            }
        }
        # Automatischer Re-Scan: Liste zeigt nur noch tatsaechlich vorhandene
        & $say 'Scanne Erweiterungen erneut ...'
        & $runAsync $loadScript @{ md=$modDir } $refreshList
    })
    # Herbert-Assistent + Statuskonsole
    try { Add-SysPilotAssistantToWindow -Win $win -Context 'Browser-Erweiterungen (Sicherheits-Scan)' -Suggestions @('Welche Extensions sind riskant?','Was sind ressourcenfresser?','Hilf mir beim Aufraeumen') | Out-Null } catch {}

    # Daten async laden (Timer tickt waehrend ShowDialog), dann modal zeigen
    & $say 'Lade Erweiterungen aller Browser-Profile ...'
    $loadScript = {
        param($st)
        Import-Module (Join-Path $st.md 'Common.psm1') -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $st.md 'Extensions.psm1') -Force -ErrorAction SilentlyContinue
        @(Get-SysPilotExtensions)
    }
    $refreshList = {
        param($out)
        $script:_extVms = @($out | ForEach-Object { & $buildVm $_ })
        & $say "Gefunden: $($script:_extVms.Count) Erweiterungen"
        & $applyFilter
        $sumTxt.Text = "Geladen: $($script:_extVms.Count) Erweiterungen"
    }
    & $runAsync $loadScript @{ md=$modDir } $refreshList
    [void]$win.ShowDialog()
}

function Get-SysPilotExtManagerDir {
    <# Pfad zum SysPilot Extension-Manager-Ordner (extension-manager/). #>
    $root = $script:SysPilotRoot
    if (-not $root) { $root = Split-Path -Parent $PSScriptRoot }
    foreach ($d in @((Join-Path $root 'extension-manager'), (Join-Path (Split-Path -Parent $PSScriptRoot) 'extension-manager'))) {
        if (Test-Path (Join-Path $d 'manifest.json')) { return $d }
    }
    return $null
}

function Install-SysPilotExtManagerExtension {
    <# Bietet die SysPilot Extension-Manager-Extension an: kopiert den
       Ordnerpfad in die Zwischenablage und oeffnet chrome://extensions.
       chrome.management ermoeglicht Enable/Disable/Remove + oeffnen der
       Browser-Detailseite direkt im Browser (kein chrome.exe-Workaround). #>
    $dir = Get-SysPilotExtManagerDir
    if (-not $dir) { return @{ Ok=$false; Message='extension-manager-Ordner nicht gefunden.' } }
    try { $dir | Set-Clipboard } catch {}
    $msg = "SysPilot Extension Manager ist im Repo unter:`n$dir`n`nPfad wurde in die Zwischenablage kopiert.`n`nInstallation:`n1) chrome://extensions oeffnen`n2) 'Entwicklermodus' aktivieren (oben rechts)`n3) 'Entpackte Erweiterung laden' -> Pfad einfuegen`n`nDanach: Suche, Enable/Disable, Entfernen, HTML-Export/Import (Sync zwischen Browsern) direkt im Browser."
    try { Start-Process 'chrome://extensions/' } catch {}
    return @{ Ok=$true; Message=$msg; Dir=$dir }
}

Export-ModuleMember -Function Get-SysPilotBrowserProfiles, Get-SysPilotExtensions,
    Get-SysPilotExtensionStoreUrl, Get-SysPilotExtensionInfoCatalog,
    Find-SysPilotExtensionCrxRisk, Remove-SysPilotChromiumExtension,
    Show-SysPilotExtensionReport, Show-SysPilotExtensionManager,
    Get-SysPilotExtRisk, Get-SysPilotExtManifestInfo,
    Get-SysPilotExtBlocklistIds, Get-SysPilotExtBlocklistNames,
    Get-SysPilotExtUserBlocklist, Add-SysPilotExtUserBlocklist,
    Get-SysPilotExtUserBlocklistPath, Get-SysPilotExtensionPolicyPath,
    Add-SysPilotExtensionInstallBlock, Test-SysPilotExtHostAlive,
    Get-SysPilotExtManagerDir, Install-SysPilotExtManagerExtension
