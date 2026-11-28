# ======================================================================
# SysPilot PortableTools.psm1 - Apps & Store-Clients.
# Verwaltet portale Programme (GitHub-Releases -> PortableApps),
# klassische Installer, winget/Store-Apps und Web-Clients.
# Klassische Installer werden mit Fortschritt geladen, SHA-geprueft
# (wo Pin vorhanden) und silent oder interaktiv installiert.
# ======================================================================

# App-Definitionen: Name, Repo, Asset-Pattern (regex auf asset.name),
# Zielordner in PortableApps, EXE-Name darin, Typ (zip|web)
$script:PortableAppDefs = @(
    @{
        Id = 'unigetui'; Name = 'UniGetUI';
        Desc = 'GUI fuer WinGet, Scoop, Chocolatey u.a. - portabel, Settings bleiben im Programmordner';
        Repo = 'Devolutions/UniGetUI';
        AssetPattern = 'UniGetUI\.x64\.zip$';
        Dir = 'UniGetUI'; Exe = 'UniGetUI.exe'; Type = 'zip';
        Web = 'https://github.com/Devolutions/UniGetUI/releases/latest'
    },
    @{
        Id = 'komistore'; Name = 'Komi Store (ehem. GitHub Store)';
        Desc = 'App-Store fuer GitHub/Codeberg-Releases - portables ZIP, ein Klick installieren';
        Repo = 'komi-store/komi-store';
        AssetPattern = 'windows-portable\.zip$';
        Dir = 'KomiStore'; Exe = 'Komi-Store.exe'; Type = 'zip';
        Web = 'https://github.com/komi-store/komi-store/releases/latest'
    },
    @{
        Id = 'uptodown'; Name = 'Uptodown Desktop';
        Desc = 'Offizieller Uptodown-Client: 25.000+ Apps, Auto-Updates, Silent-Install - offizielle Installer-URL, SHA256-geprueft';
        Repo = $null; AssetPattern = $null; Dir = $null; Exe = $null;
        Type = 'installer';
        InstallerUrl = 'https://download.uptodown.app/windows-client';
        Sha256 = '5cd1e3d9c438ce5a28fa4e2e8ecbbc0fffa066676cd58c8429041b818d3ac1a7';
        InstallArgs = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-';
        DisplayName = 'Uptodown Desktop';
        Web = 'https://uptodown-desktop.en.uptodown.com/windows'
    },
    @{
        Id = 'winutil'; Name = 'Chris Titus WinUtil';
        Desc = 'Umfangreiches Windows-Tuning/Repair-Skript (TUI) - portabel als .ps1, laeuft im eigenen Fenster';
        Repo = 'ChrisTitusTech/winutil';
        AssetPattern = 'winutil\.ps1$';
        Dir = 'WinUtil'; Exe = 'winutil.ps1'; Type = 'script';
        Web = 'https://github.com/ChrisTitusTech/winutil'
    },
    @{
        Id = 'wintoys'; Name = 'WinToys';
        Desc = 'Microsoft-Experimentier-Launcher: PowerToys-Module, Windows-Features, Utilities - Installation ueber winget/Microsoft Store';
        Repo = $null; AssetPattern = $null; Dir = $null; Exe = $null; Type = 'winget';
        WingetId = '9NZKPSTSNW4P';
        StoreUrl = 'ms-windows-store://pdp/?ProductId=9NZKPSTSNW4P';
        Source = 'msstore';
        Web = 'https://apps.microsoft.com/detail/9NZKPSTSNW4P'
    },
    @{
        Id = 'itopeasy'; Name = 'iTop Easy Desktop';
        Desc = 'Desktop-Organisator: Icons in Kategorien/Ordner sortieren, Auto-Arrangement, Wallpaper-Manager';
        Repo = $null; AssetPattern = $null; Dir = $null; Exe = $null; Type = 'winget';
        WingetId = 'iTop.iTopEasyDesktop';
        Source = 'winget';
        StoreUrl = 'https://www.itop-abc.com/Products/FreeDesktopOrganizer.htm';
        Web = 'https://www.itop-abc.com/Products/FreeDesktopOrganizer.htm'
    },
    @{
        Id = 'ferdium'; Name = 'Ferdium';
        Desc = 'Desktop-App fuer Messenger (WhatsApp, Telegram, Signal, Discord u.v.m.) - ein Fenster fuer alle';
        Repo = $null; AssetPattern = $null; Dir = $null; Exe = $null; Type = 'winget';
        WingetId = 'Ferdium.Ferdium';
        Source = 'winget';
        StoreUrl = 'https://ferdium.org/';
        Web = 'https://ferdium.org/'
    },
    @{
        Id = 'uwt'; Name = 'Ultimate Windows Tweaker 5';
        Desc = 'Ueber 200 Windows-11-Tweaks (Taskbar, Explorer, Privatsphaere, Performance) - portabel, ohne Installation';
        Repo = $null; AssetPattern = $null; Dir = 'UltimateWindowsTweaker'; Exe = 'Ultimate Windows Tweaker.exe';
        Type = 'zip'; DownloadMode = 'majorgeeks';
        DetailsUrl = 'https://www.majorgeeks.com/files/details/ultimate_windows_tweaker_5.html';
        VersionPattern = 'Windows Tweaker for Windows 11\s+([\d.]+)'; AssetName = 'UWT5.zip';
        Web = 'https://www.thewindowsclub.com/ultimate-windows-tweaker-5-for-windows-11'
    },
    @{
        Id = 'hostsman'; Name = 'HostsMan';
        Desc = 'Hosts-Datei-Manager: eingebauter Editor, Online-Update, Block-Log, verschluesselte Backups - portabel (MajorGeeks/Abelhadigital)';
        Repo = $null; AssetPattern = $null; Dir = 'HostsMan'; Exe = 'hm.exe';
        Type = 'zip'; DownloadMode = 'majorgeeks';
        DetailsUrl = 'https://www.majorgeeks.com/files/details/hostsman.html';
        VersionPattern = 'HostsMan\s+([\d.]+)'; AssetName = 'HostsMan.zip';
        Web = 'https://www.abelhadigital.com/'
    },
    @{
        Id = 'pcm'; Name = 'Microsoft PC Manager';
        Desc = 'Microsofts kostenloser PC-Manager (Cleanup, Storage, Health-Check, Pop-up-Schutz) - Store-App, in DE regionsbeschraenkt: Installation ueber Uptodown-Seite';
        Repo = $null; AssetPattern = $null; Dir = $null; Exe = $null;
        Type = 'storeapp'; MatchName = 'PC Manager';
        StoreUrl = 'ms-windows-store://pdp/?ProductId=9PM860492SZD';
        Web = 'https://microsoft-pc-manager.en.uptodown.com/windows/download'
    },
    @{
        Id = 'mumu'; Name = 'MuMu Player';
        Desc = 'NetEase Android-Emulator fuer Windows (Spiele + Apps, Multi-Instance, Keymapping) - offizieller Download, Installer mit eigener UI';
        Repo = $null; AssetPattern = $null; Dir = $null; Exe = $null;
        Type = 'installer';
        InstallerUrl = 'https://api.mumuplayer.com/api/dl/win?channel=gw-win-download';
        InstallArgs = '';
        DisplayName = 'MuMu Player';
        Web = 'https://www.mumuplayer.com/de/download/'
    },
    @{
        Id = 'flipboard'; Name = 'Flipboard';
        Desc = 'News-Magazin-App - HINWEIS: offizieller Desktop-Client wurde eingestellt, nur Web-Version';
        Repo = $null; AssetPattern = $null; Dir = $null; Exe = $null; Type = 'web';
        Web = 'https://flipboard.com/'
    }
)

# Download-Portale (kein lokales Programm - oeffnen eine Katalogseite).
# Werden im Apps-Menue als eigener Block am Ende gelistet.
$script:PortablePortalDefs = @(
    @{ Id='ninite';        Name='Ninite';                  Desc='Still-Installationsmanager (~160 Apps): App-Auswahl hier automatisiert - laedt + startet den stillen Installer'; Url='https://ninite.com/'; Auto=$true },
    @{ Id='portableapps';  Name='PortableApps.com';        Desc='Groesstes Portal portabler Windows-Apps (400+)'; Url='https://www.portableapps.com/'; Auto=$false },
    @{ Id='filehippo';     Name='FileHippo';               Desc='EN: versionsarchivierte Downloads, kein Bundleware - Bot-Schutz, manuell'; Url='https://filehippo.com/'; Auto=$false },
    @{ Id='majorgeeks';    Name='MajorGeeks';              Desc='EN: kuratiert, Version+Mirror automatisiert auswertbar'; Url='https://www.majorgeeks.com/'; Auto=$true },
    @{ Id='uptodown';      Name='Uptodown';                Desc='EN/DE: 25.000+ Apps, Version automatisch lesbar'; Url='https://uptodown.com/'; Auto=$true },
    @{ Id='fosshub';       Name='FOSSHub';                 Desc='EN: nur Open-Source-Software, Version lesbar'; Url='https://www.fosshub.com/'; Auto=$true },
    @{ Id='softpedia';     Name='Softpedia';               Desc='EN: riesige Datenbank, langsame Seite'; Url='https://www.softpedia.com/'; Auto=$false },
    @{ Id='heise';         Name='Heise Download';          Desc='DE: redaktionell geprueft'; Url='https://www.heise.de/download/'; Auto=$false },
    @{ Id='chip';          Name='CHIP Download';           Desc='DE: grosse Auswahl, viel Werbung'; Url='https://www.chip.de/download/'; Auto=$false },
    @{ Id='computerbild';  Name='Computer Bild Downloads'; Desc='DE: gepruefte Installer'; Url='https://www.computerbild.de/downloads/'; Auto=$false },
    @{ Id='computerbase';  Name='ComputerBase Downloads';  Desc='DE: technisch fundiert, sparsam kuratiert'; Url='https://www.computerbase.de/downloads/'; Auto=$false },
    @{ Id='winfuture';     Name='WinFuture';               Desc='DE: Windows-Tweaks, Tools, ISOs'; Url='https://winfuture.de/'; Auto=$false },
    @{ Id='deskmodder';    Name='Deskmodder';              Desc='DE: Tools, Windows-Tricks, Docks'; Url='https://www.deskmodder.de/'; Auto=$false },
    @{ Id='softonic';      Name='Softonic';                Desc='DE: grosse Auswahl - nur mit Adblock empfohlen'; Url='https://de.softonic.com/'; Auto=$false },
    @{ Id='giga';          Name='GIGAZONE';                Desc='DE: Cloud-Speicher/Datei-Host (keine Programm-Downloads)'; Url='https://giga.de/'; Auto=$false },
    @{ Id='alternativeto'; Name='AlternativeTo';           Desc='EN: Suchmaschine fuer Software-Alternativen'; Url='https://alternativeto.net/'; Auto=$false },
    @{ Id='ghacks';        Name='Ghacks';                  Desc='EN: Blog mit direkten Tool-Download-Links'; Url='https://www.ghacks.net/'; Auto=$false },
    @{ Id='troypoint';     Name='TroyPoint';               Desc='EN: Fire-TV/Android-TV-Apps + APK-Downloads mit Install-Anleitungen (Kodi, IPTV, VPN, Launcher)'; Url='https://troypoint.com/'; Auto=$false }
)

function Find-SysPilotStoreApp {
    <# Sucht eine Store-/winget-App (z.B. WinToys, iTop Easy Desktop).
       1) Get-StartApps (MSIX + Startmenue-Kacheln)
       2) Uninstall-Registry -> InstallLocation/DisplayIcon als EXE-Pfad #>
    param([Parameter(Mandatory)][hashtable]$App)
    # Get-StartApps ist langsam (~1-4s) - kurz cachen, sonst scanned jedes
    # Menue-Redraw alle Apps neu. Cache wird nach Installationen verworfen.
    if (-not $script:_startAppsCache -or ((Get-Date) - $script:_startAppsCacheTime).TotalSeconds -gt 20) {
        $script:_startAppsCache = @(Get-StartApps -ErrorAction SilentlyContinue)
        $script:_startAppsCacheTime = Get-Date
    }
    $match = if ($App.MatchName) { $App.MatchName } else { $App.Name }
    $hit = $script:_startAppsCache | Where-Object { $_.Name -like "*$match*" } | Select-Object -First 1
    if ($hit) {
        # Klassischer Shortcut (kein MSIX): AppID ist ein .lnk-Pfad
        if ($hit.AppID -match '\.(lnk|url)$' -and (Test-Path $hit.AppID)) {
            try {
                $sh = New-Object -ComObject WScript.Shell
                $target = $sh.CreateShortcut($hit.AppID).TargetPath
                if ($target -and (Test-Path $target)) { return @{ Path = $target } }
            } catch { }
        }
        return @{ AppId = $hit.AppID; Name = $hit.Name }
    }
    # Fallback: Uninstall-Registry (winget-Apps ohne Startmenue-Eintrag)
    $uninst = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
              'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
              'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $disp = switch ($App.Id) {
        'wintoys'  { 'WinToys' }
        'itopeasy' { 'iTop Easy Desktop' }
        'ferdium'  { 'Ferdium' }
        'flipboard'{ 'Flipboard' }
        'pcm'      { 'PC Manager' }
        'mumu'     { 'MuMu' }
        default    { $App.Name }
    }
    $reg = Get-ItemProperty $uninst -ErrorAction SilentlyContinue |
           Where-Object { $_.DisplayName -like "*$disp*" } | Select-Object -First 1
    if ($reg) {
        foreach ($cand in @(($reg.DisplayIcon -split ',')[0], $reg.InstallLocation)) {
            if ($cand) { $cand = $cand.Trim('"').Trim() }
            if ($cand -and (Test-Path $cand)) {
                if (((Get-Item $cand) -is [IO.FileInfo]) -and (Test-SysPilotLaunchablePath $cand)) { return @{ Path = $cand } }
                $exeHit = Get-ChildItem $cand -Filter '*.exe' -ErrorAction SilentlyContinue |
                          Where-Object { $_.Name -notmatch 'unins|uninstall|update|createdump|crashpad' } | Select-Object -First 1
                if ($exeHit) { return @{ Path = $exeHit.FullName } }
            }
        }
        return @{ Installed = $true }
    }
    return $null
}

function Install-SysPilotWingetApp {
    <# Installiert eine App ueber winget (msstore-Quelle). #>
    param([Parameter(Mandatory)][hashtable]$App)
    if (Find-SysPilotStoreApp -App $App) {
        Write-Host "  Bereits installiert." -ForegroundColor Green
        return $true
    }
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) {
        Write-Host '  [!] winget nicht gefunden - Store-Seite wird geoeffnet.' -ForegroundColor Yellow
        Start-Process $App.StoreUrl
        return $false
    }
    $src = if ($App.Source) { $App.Source } else { 'msstore' }
    Write-Host "  Installiere $($App.Name) ueber winget/$src ($($App.WingetId)) ..." -ForegroundColor Cyan
    $wargs = @('install','--id',$App.WingetId,'--source',$src,'-e',
               '--accept-package-agreements','--accept-source-agreements')
    if ($src -eq 'msstore') { $wargs += '--silent' }
    $p = Start-Process winget.exe -ArgumentList $wargs -Wait -PassThru -NoNewWindow
    $script:_startAppsCache = $null
    if ($p.ExitCode -eq 0 -or (Find-SysPilotStoreApp -App $App)) {
        Write-Host "  [OK] $($App.Name) installiert." -ForegroundColor Green
        Write-SysPilotLog "$($App.Name) via winget installiert"
        $script:_startAppsCache = $null
        return $true
    }
    Write-Host "  [!] winget-Installation fehlgeschlagen (Code $($p.ExitCode)) - Store-Seite wird geoeffnet." -ForegroundColor Yellow
    Start-Process $App.StoreUrl
    return $false
}

function Start-SysPilotStoreApp {
    <# Startet eine Store-App ueber shell:AppsFolder. #>
    param([Parameter(Mandatory)][hashtable]$App)
    $found = Find-SysPilotStoreApp -App $App
    if (-not $found) {
        if ($App.Type -eq 'storeapp') {
            Write-Host "  Nicht installiert - oeffne Installationsseite ..." -ForegroundColor Yellow
            Start-Process $App.Web
            return
        }
        Write-Host "  Nicht installiert - Installiere zuerst ..." -ForegroundColor Yellow
        Install-SysPilotWingetApp -App $App | Out-Null
        $found = Find-SysPilotStoreApp -App $App
        if (-not $found) { return }
    }
    Write-Host "  Starte $($App.Name) ..." -ForegroundColor Cyan
    if ($found.Path) {
        Start-Process $found.Path
    } else {
        Start-Process "shell:AppsFolder\$($found.AppId)"
    }
}

function Find-SysPilotPortableApp {
    <# Sucht die EXE eines Portable-App-Eintrags im PortableApps-Ordner
       und in der Uninstall-Registry ( fuer normale Installationen). #>
    param([Parameter(Mandatory)][hashtable]$App)
    if ($App.Type -eq 'web') { return $null }   # Web-Apps haben keine lokale Installation
    if ($App.Type -eq 'winget') {
        $s = Find-SysPilotStoreApp -App $App
        if ($s -and $s.Path) { return @{ Path = $s.Path; Portable = $false; Installed = $true; StoreApp = $true } }
        if ($s -and $s.AppId) { return @{ Path = "shell:AppsFolder\$($s.AppId)"; Portable = $false; Installed = $true; StoreApp = $true } }
        if ($s -and $s.Installed) { return @{ Path = $null; Portable = $false; Installed = $true; StoreApp = $true } }
        return $null
    }
    if ($App.Type -eq 'storeapp') {
        # Wie winget, aber ohne Installationsversuch (regionsbeschraenkt)
        $s = Find-SysPilotStoreApp -App $App
        if ($s -and $s.Path) { return @{ Path = $s.Path; Portable = $false; Installed = $true; StoreApp = $true } }
        if ($s -and $s.AppId) { return @{ Path = "shell:AppsFolder\$($s.AppId)"; Portable = $false; Installed = $true; StoreApp = $true } }
        if ($s -and $s.Installed) { return @{ Path = $null; Portable = $false; Installed = $true; StoreApp = $true } }
        return $null
    }
    $pa = $null
    try { $pa = Get-SysPilotPortableAppsDir } catch { }
    if ($pa -and $App.Dir -and $App.Exe) {
        $exe = Join-Path $pa (Join-Path $App.Dir $App.Exe)
        if (Test-Path $exe) { return @{ Path = $exe; Portable = $true } }
        # Alternative: EXE mit ahnlichem Namen im Ordner (nicht fuer Skripte)
        $dir = Join-Path $pa $App.Dir
        if ($App.Type -ne 'script' -and (Test-Path $dir)) {
            $hit = Get-ChildItem $dir -Filter '*.exe' -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -notmatch 'unins|uninstall' } | Select-Object -First 1
            # Zweiter Versuch rekursiv (z.B. UWT packt in Versions-Unterordner)
            if (-not $hit) {
                $hit = Get-ChildItem $dir -Filter '*.exe' -Recurse -ErrorAction SilentlyContinue |
                       Where-Object { $_.Name -notmatch 'unins|uninstall' } | Select-Object -First 1
            }
            if ($hit) { return @{ Path = $hit.FullName; Portable = $true } }
        }
    }
    # Installierte Version ueber Uninstall-Registry finden
    $uninst = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
              'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
              'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $disp = switch ($App.Id) {
        'unigetui' { 'UniGetUI' }
        'komistore'{ 'Komi Store' }
        'uptodown' { 'Uptodown Desktop' }
        'uwt'      { 'Ultimate Windows Tweaker' }
        'hostsman' { 'HostsMan' }
        'mumu'     { 'MuMu' }
        default    { $App.Name }
    }
    $hit = Get-ItemProperty $uninst -ErrorAction SilentlyContinue |
           Where-Object { $_.DisplayName -like "*$disp*" } | Select-Object -First 1
    if ($hit) {
        $ip = $null
        foreach ($cand in @(($hit.DisplayIcon -split ',')[0], $hit.InstallLocation)) {
            if ($cand) { $cand = $cand.Trim('"').Trim() }
            if ($cand -and (Test-Path $cand)) {
                if (((Get-Item $cand) -is [IO.FileInfo]) -and (Test-SysPilotLaunchablePath $cand)) { $ip = $cand }
                else {
                    $exeHit = Get-ChildItem $cand -Filter '*.exe' -ErrorAction SilentlyContinue |
                              Where-Object { $_.Name -notmatch 'unins|uninstall|update|createdump|crashpad' } | Select-Object -First 1
                    if ($exeHit) { $ip = $exeHit.FullName }
                }
                if ($ip) { break }
            }
        }
        if ($ip) { return @{ Path = $ip; Portable = $false } }
        return @{ Path = $null; Portable = $false; Installed = $true }
    }
    return $null
}

function Get-SysPilotGitHubAssetUrl {
    <# Loest die Download-URL eines Release-Assets per GitHub-API. #>
    param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string]$Pattern)
    try {
        $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -TimeoutSec 20 -ErrorAction Stop
        $asset = $rel.assets | Where-Object { $_.name -match $Pattern } | Select-Object -First 1
        if ($asset) {
            return @{ Version = $rel.tag_name; Url = $asset.browser_download_url; Name = $asset.name; SizeMB = [math]::Round($asset.size/1MB,1) }
        }
    } catch { }
    return $null
}

function Get-SysPilotMajorGeeksAsset {
    <# Liest eine MajorGeeks-Detailseite: Version + Mirror-URL.
       Gibt ein Asset-Hashtable (wie GitHub) oder $null zurueck.
       VersionPattern/AssetName sind app-spezifisch (Default = UWT). #>
    param(
        [Parameter(Mandatory)][string]$DetailsUrl,
        [string]$VersionPattern = 'Windows Tweaker for Windows 11\s+([\d.]+)',
        [string]$AssetName = 'UWT5.zip'
    )
    try {
        $html = (Invoke-WebRequest -Uri $DetailsUrl -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop).Content
        $version = $null
        if ($html -match $VersionPattern) { $version = $Matches[1] }
        $mirror = $null
        if ($html -match 'href=["'']([^"'']*getmirror[^"'']*\.html)["'']') {
            $m = $Matches[1]
            if ($m -notmatch '^https?://') { $m = 'https://www.majorgeeks.com/' + $m.TrimStart('/') }
            $mirror = $m
        }
        if (-not $mirror) { return $null }
        return @{ Version = $(if ($version) { $version } else { 'unbekannt' }); Name = $AssetName; SizeMB = $null; MirrorUrl = $mirror }
    } catch { return $null }
}

function Save-SysPilotMajorGeeksFile {
    <# Laedt eine Datei von MajorGeeks: Mirror-Seite liefert Cookie,
       Download-Endpunkt antwortet 302 auf Token-URL (files*.majorgeeks.com). #>
    param([Parameter(Mandatory)][string]$MirrorUrl,
          [Parameter(Mandatory)][string]$OutFile,
          [string]$Label = 'Download', [int]$TimeoutSec = 120)
    try {
        $s = New-Object Microsoft.PowerShell.Commands.WebRequestSession
        Invoke-WebRequest -Uri $MirrorUrl -WebSession $s -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop | Out-Null
        Invoke-WebRequest -Uri 'https://www.majorgeeks.com/index.php?ct=files&action=download' -WebSession $s -OutFile $OutFile -UseBasicParsing -TimeoutSec $TimeoutSec -MaximumRedirection 5 -ErrorAction Stop | Out-Null
        $len = if (Test-Path $OutFile) { (Get-Item $OutFile).Length } else { 0 }
        if ($len -gt 0) {
            Write-Host ("  {0}: {1:N1} MB heruntergeladen" -f $Label, ($len/1MB)) -ForegroundColor Green
            return $true
        }
    } catch {
        Write-Host "  [!] Mirror-Download fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Red
    }
    return $false
}

function Install-SysPilotInstallerApp {
    <# Typ 'installer': oficialler Installer herunterladen (mit
       Fortschritt), SHA256 pruefen, silent installieren, EXE suchen. #>
    param([Parameter(Mandatory)][hashtable]$App)
    $existing = Find-SysPilotPortableApp -App $App
    if ($existing -and $existing.Path) {
        Write-Host "  Bereits installiert: $($existing.Path)" -ForegroundColor Green
        if (-not (Confirm-SysPilot "$($App.Name) ist bereits installiert. Trotzdem neu installieren (Update)?")) {
            return $existing.Path
        }
    } elseif (-not (Confirm-SysPilot "$($App.Name) herunterladen und installieren?")) {
        return $null
    }
    $exe = Join-Path $env:TEMP ("inst_" + $App.Id + ".exe")
    if (-not (Invoke-SysPilotFileDownload -Url $App.InstallerUrl -OutFile $exe -Label $App.Name -TimeoutSec 600 -Title $App.Name)) {
        Import-SysPilotModule SmartDownload
        if (Get-Command Save-SysPilotSmartDownload -ErrorAction SilentlyContinue) {
            $sd = Save-SysPilotSmartDownload -Url $App.InstallerUrl -OutFile $exe -Name $App.Name -Id $App.Id -TimeoutSec 600 -Label $App.Name
            if (-not ($sd -and $sd.Ok)) {
                Remove-Item $exe -Force -ErrorAction SilentlyContinue
                return $null
            }
            Write-Host "  [OK] Via SmartDownload: $($sd.Url)" -ForegroundColor DarkCyan
        } else {
            Remove-Item $exe -Force -ErrorAction SilentlyContinue
            return $null
        }
    }
    if ($App.Sha256) {
        $h = (Get-FileHash $exe -Algorithm SHA256).Hash.ToLower()
        if ($h -ne $App.Sha256.ToLower()) {
            Write-Host '  [!] SHA256-Pruefsumme stimmt nicht - Download verworfen, Abbruch.' -ForegroundColor Red
            Remove-Item $exe -Force -ErrorAction SilentlyContinue
            return $null
        }
        Write-Host '  [OK] SHA256 verifiziert (offizielle Pruefsumme)' -ForegroundColor Green
    }
    Write-Host "  Installiere $($App.Name) ..." -ForegroundColor Cyan
    # InstallArgs kann leer sein (interaktiver Installer, z.B. MuMu)
    $pargs = @{}
    if ($App.InstallArgs) { $pargs['ArgumentList'] = $App.InstallArgs }
    $p = Start-Process $exe @pargs -Wait -PassThru
    Remove-Item $exe -Force -ErrorAction SilentlyContinue
    if ($p.ExitCode -ne 0) {
        Write-Host "  [!] Installer meldet Code $($p.ExitCode) - evtl. trotzdem installiert, pruefe ..." -ForegroundColor Yellow
    }
    # Registry-Eintrag kann eine Weile brauchen
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Seconds 2
        $found = Find-SysPilotPortableApp -App $App
        if ($found -and $found.Path) {
            Write-Host "  [OK] Installiert: $($found.Path)" -ForegroundColor Green
            Write-SysPilotLog "$($App.Name) installiert ($($App.InstallerUrl))"
            return $found.Path
        }
    }
    Write-Host '  [!] Installer lief, aber Programm nicht gefunden - Startmenue/Programme pruefen.' -ForegroundColor Yellow
    return $null
}

function Install-SysPilotPortableApp {
    <# Laedt + extrahiert eine portable App nach PortableApps.
       Gibt den EXE-Pfad zurueck oder $null. #>
    param([Parameter(Mandatory)][hashtable]$App)
    if ($App.Type -eq 'winget') { Install-SysPilotWingetApp -App $App | Out-Null; return $null }
    if ($App.Type -eq 'web') {
        Write-Host "  $($App.Name) wird ueber die offizielle Seite installiert (kein Direktlink)." -ForegroundColor Yellow
        Start-Process $App.Web
        return $null
    }
    if ($App.Type -eq 'installer') { return (Install-SysPilotInstallerApp -App $App) }
    if ($App.Type -eq 'storeapp') {
        Write-Host "  $($App.Name) ist eine Store-App und in dieser Region nicht im" -ForegroundColor Yellow
        Write-Host '  Microsoft Store/winget verfuegbar - oeffne die Uptodown-Downloadseite' -ForegroundColor Yellow
        Write-Host '  (funktioniert nachweislich, siehe App-Beschreibung).' -ForegroundColor Yellow
        Start-Process $App.Web
        return $null
    }
    $existing = Find-SysPilotPortableApp -App $App
    if ($existing -and $existing.Portable) {
        Write-Host "  Bereits vorhanden: $($existing.Path)" -ForegroundColor Green
        return $existing.Path
    }
    if ($App.DownloadMode -eq 'majorgeeks') {
        $asset = Get-SysPilotMajorGeeksAsset -DetailsUrl $App.DetailsUrl `
            -VersionPattern $App.VersionPattern -AssetName $App.AssetName
        if (-not $asset) {
            Write-Host "  [!] MajorGeeks-Info nicht lesbar ($($App.DetailsUrl))." -ForegroundColor Red
            return $null
        }
    } else {
        $asset = Get-SysPilotGitHubAssetUrl -Repo $App.Repo -Pattern $App.AssetPattern
        if (-not $asset) {
            Write-Host "  [!] Release-Asset nicht gefunden ($($App.Repo))." -ForegroundColor Red
            return $null
        }
    }
    $sizeTxt = if ($asset.SizeMB) { " ($($asset.SizeMB) MB)" } else { '' }
    Write-Host "  Version: $($asset.Version) - $($asset.Name)$sizeTxt" -ForegroundColor Cyan
    if ($asset.Url) { Write-Host "  Download: $($asset.Url)" -ForegroundColor DarkGray }
    if (-not (Confirm-SysPilot "$($App.Name) herunterladen und nach PortableApps installieren?")) { return $null }

    $pa = Get-SysPilotPortableAppsDir
    $destDir = Join-Path $pa $App.Dir

    # Typ 'script': einzelnes .ps1 laden statt ZIP entpacken
    if ($App.Type -eq 'script') {
        New-Item -ItemType Directory -Force -Path $destDir | Out-Null
        $dest = Join-Path $destDir $App.Exe
        if (-not (Invoke-SysPilotFileDownload -Url $asset.Url -OutFile $dest -Label $App.Name -TimeoutSec 120 -Title $App.Name)) {
            Import-SysPilotModule SmartDownload
            if (Get-Command Save-SysPilotSmartDownload -ErrorAction SilentlyContinue) {
                $sd = Save-SysPilotSmartDownload -Url $asset.Url -OutFile $dest -Name $App.Name -Id $App.Id -TimeoutSec 300 -Label $App.Name
                if (-not ($sd -and $sd.Ok)) { return $null }
            } else { return $null }
        }
        if (-not (Test-Path $dest) -or (Get-Item $dest).Length -lt 10KB) {
            Write-Host '  [!] Download unvollstaendig.' -ForegroundColor Red
            Remove-Item $dest -Force -ErrorAction SilentlyContinue
            return $null
        }
        Write-Host "  [OK] Installiert: $dest" -ForegroundColor Green
        Write-SysPilotLog "$($App.Name) $($asset.Version) nach $dest"
        return $dest
    }

    $zip = Join-Path $env:TEMP ("pa_" + $App.Id + "_" + [guid]::NewGuid().ToString('N').Substring(0,6) + '.zip')
    if ($App.DownloadMode -eq 'majorgeeks') {
        $dlOk = Save-SysPilotMajorGeeksFile -MirrorUrl $asset.MirrorUrl -OutFile $zip -Label $App.Name
    } else {
        $dlOk = Invoke-SysPilotFileDownload -Url $asset.Url -OutFile $zip -Label $App.Name -TimeoutSec 600 -Title $App.Name
        if (-not $dlOk) {
            Import-SysPilotModule SmartDownload
            if (Get-Command Save-SysPilotSmartDownload -ErrorAction SilentlyContinue) {
                $sd = Save-SysPilotSmartDownload -Url $asset.Url -OutFile $zip -Name $App.Name -Id $App.Id -TimeoutSec 600 -Label $App.Name
                $dlOk = ($sd -and $sd.Ok)
            }
        }
    }
    if (-not $dlOk) { Remove-Item $zip -Force -ErrorAction SilentlyContinue; return $null }
    try {
        if ((Get-Item $zip).Length -lt 20KB) { throw 'Download zu klein/ unvollstaendig' }
        # Ziel: Unterordner im PortableApps-Ordner (alte Version umbenennen)
        if (Test-Path $destDir) {
            $old = "$destDir.old-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
            Rename-Item $destDir $old
            Write-Host "  Alte Version gesichert: $old" -ForegroundColor DarkGray
        }
        Expand-Archive -Path $zip -DestinationPath $destDir -Force
    } catch {
        Write-Host "  [!] Fehler: $($_.Exception.Message)" -ForegroundColor Red
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        return $null
    } finally {
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
    }
    $exe = Find-SysPilotPortableApp -App $App
    if ($exe -and $exe.Path) {
        Write-Host "  [OK] Installiert: $($exe.Path)" -ForegroundColor Green
        Write-SysPilotLog "$($App.Name) $($asset.Version) nach $destDir"
        return $exe.Path
    }
    Write-Host "  [!] Entpackt, aber EXE nicht gefunden - pruefe $destDir" -ForegroundColor Yellow
    return $null
}

function Start-SysPilotPortableApp {
    <# Installiert (falls noetig) und startet eine portable App. #>
    param([Parameter(Mandatory)][hashtable]$App)
    if ($App.Type -eq 'web') {
        # Web-Apps: erst nach installierter Browser-PWA/Shortcut suchen
        # (z.B. Flipboard als Brave-PWA -> eigener App-Fenster), sonst die
        # offizielle Seite oeffnen. NIEMALS eine lokale Datei starten -
        # veraltete .ico-Eintraege in der Uninstall-Registry loesten sonst
        # den Windows-"Oeffnen mit"-Dialog aus.
        $s = Find-SysPilotStoreApp -App $App
        if ($s -and $s.Path) {
            Write-Host "  Starte $($App.Name) ..." -ForegroundColor Cyan
            Start-Process $s.Path
            return
        }
        if ($s -and $s.AppId) {
            Write-Host "  Starte $($App.Name) (Browser-App) ..." -ForegroundColor Cyan
            try {
                Start-Process "shell:AppsFolder\$($s.AppId)"
                return
            } catch { }
        }
        Write-Host "  Oeffne $($App.Name) im Browser ..." -ForegroundColor Cyan
        Start-Process $App.Web
        return
    }
    if ($App.Type -eq 'winget' -or $App.Type -eq 'storeapp') { Start-SysPilotStoreApp -App $App; return }
    $found = Find-SysPilotPortableApp -App $App
    $exe = $null
    if ($found -and $found.Path) { $exe = $found.Path }
    if (-not $exe -and $App.Type -ne 'web') {
        $exe = Install-SysPilotPortableApp -App $App
    } elseif (-not $exe -and $App.Type -eq 'web') {
        Install-SysPilotPortableApp -App $App
        return
    }
    if ($exe) {
        Write-Host "  Starte $($App.Name) ..." -ForegroundColor Cyan
        if ($exe -like '*.ps1') {
            # Skript-App (z.B. WinUtil): eigenes Konsolenfenster, -NoExit fuer Fehleranzeige
            Start-Process powershell.exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File',"`"$exe`""
        } else {
            Start-Process $exe
        }
    }
}

function Get-SysPilotNiniteApps {
    <# Holt den Ninite-App-Katalog von ninite.com: Slug, Anzeigename,
       Version (steht im label-title-Attribut). #>
    try {
        $html = (Invoke-WebRequest 'https://ninite.com/' -UseBasicParsing -TimeoutSec 25 `
                 -Headers @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' } -ErrorAction Stop).Content
    } catch { return @() }
    $apps = @{}
    # Struktur: <label ... title="Name version"><input ... name="apps" value="slug">
    foreach ($m in [regex]::Matches($html, 'title="([^"]{3,120})"[^>]*>\s*<input[^>]*name="apps"\s+value="([a-z0-9\-]+)"')) {
        $title = $m.Groups[1].Value.Trim()
        $slug  = $m.Groups[2].Value
        # Titel "Fast Browser by Google 158.0.8127.89" -> Name + Version
        $ver = $null; $name = $title
        if ($title -match '^(.*?)[\s\-\u2013]*(\d+\.\d[\d.]*)\s*$') { $name = $Matches[1].Trim(); $ver = $Matches[2] }
        if (-not $apps.ContainsKey($slug)) {
            $apps[$slug] = [pscustomobject]@{ Slug = $slug; Name = $name; Title = $title; Version = $ver }
        }
    }
    return @($apps.Values)
}

function Install-SysPilotNiniteApps {
    <# Erstellt einen stillen Ninite-Installer fuer die ausgewaehlten Apps:
       POST auf ninite.com -> Antwort enthaelt /slug/ninite.exe -> Download
       -> Start (ninite installiert still im Hintergrund, ueberspringt
       aktuell installierte Apps). Gibt den EXE-Pfad zurueck. #>
    param([Parameter(Mandatory)][string[]]$Slugs)
    if (-not $Slugs -or $Slugs.Count -eq 0) { return $null }
    $base = 'https://ninite.com'
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $page = Invoke-WebRequest "$base/" -WebSession $session -UseBasicParsing -TimeoutSec 25 `
            -Headers @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' } -ErrorAction Stop
    $xsrf = $null
    if ($page.Content -match 'name="_xsrf"[^>]*value="([^"]+)"') { $xsrf = $Matches[1] }
    if (-not $xsrf) { Write-Host '  [!] xsrf-Token nicht gefunden - Seite evtl. geaendert.' -ForegroundColor Red; return $null }
    $body = "_xsrf=$([uri]::EscapeDataString($xsrf))"
    foreach ($s in $Slugs) { $body += "&apps=$([uri]::EscapeDataString($s))" }
    $resp = Invoke-WebRequest "$base/" -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded' `
            -WebSession $session -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
    if ($resp.Content -notmatch 'href="(/[a-z0-9\-]+/ninite\.exe)"') {
        Write-Host '  [!] Keine Installer-URL in Ninite-Antwort.' -ForegroundColor Red
        return $null
    }
    $exeUrl = "$base$($Matches[1])"
    $out = Join-Path $env:TEMP ("ninite_{0}.exe" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Write-Host "  Lade Ninite-Installer ($($Slugs.Count) Apps) ..." -ForegroundColor Cyan
    if (-not (Invoke-SysPilotFileDownload -Url $exeUrl -OutFile $out -Label 'Ninite-Installer' -TimeoutSec 300 -Title 'Ninite-Installer')) {
        Write-Host '  [!] Ninite-Download fehlgeschlagen/abgebrochen.' -ForegroundColor Red
        return $null
    }
    Write-Host "  Starte Installer - Installation laeuft still im Hintergrund (~1-5 Min)." -ForegroundColor Green
    Start-Process $out
    Write-SysPilotLog "Ninite-Installer erstellt: $($Slugs -join ',') -> $out"
    return $out
}

function Show-SysPilotNinitePicker {
    <# Ninite-Manager: App-Katalog laden, per Leertaste auswaehlen,
       stillen Installer erstellen + starten. #>
    Write-Host '  Lade Ninite-Katalog ...' -ForegroundColor Cyan
    $apps = @(Get-SysPilotNiniteApps)
    if ($apps.Count -eq 0) {
        Write-Host '  [!] Ninite-Katalog nicht ladbar - Seite oeffnen?' -ForegroundColor Yellow
        if (Confirm-SysPilot 'ninite.com im Browser oeffnen?') { Start-Process 'https://ninite.com/' }
        return
    }
    $items = foreach ($a in $apps) {
        $v = if ($a.Version) { "  [$($a.Version)]" } else { '' }
        @{ Label = "$($a.Name)$v"; Color = 'White'; Tag = $a.Slug; Checked = $false }
    }
    $chosen = Show-SysPilotMultiSelectMenu -Items $items -Title "Ninite - Apps auswaehlen ($($apps.Count) verfuegbar)" -Footer 'Leertaste = markieren, Enter = Installer erstellen+starten, Esc = abbruch'
    if ($null -eq $chosen -or $chosen.Count -eq 0) { return }
    Write-Host "  $($chosen.Count) Apps ausgewaehlt." -ForegroundColor Cyan
    if (-not (Confirm-SysPilot "Ninite-Installer fuer $($chosen.Count) Apps erstellen und starten?`nDer Installer laeuft still im Hintergrund und ueberspringt aktuelle Apps.")) { return }
    Install-SysPilotNiniteApps -Slugs $chosen | Out-Null
}

function Get-SysPilotDownloadPortals {
    <# Portalliste fuer andere Module (Update-Center Web-Kataloge). #>
    return $script:PortablePortalDefs
}

function Show-SysPilotPortableAppsMenu {
    <# Pfeiltasten-Menue fuer portable Apps / Store-Clients
       + Download-Portale (Web-Kataloge) als eigener Block am Ende. #>
    # Portale als web-App-Pseudo-Eintraege (gleiches Auswahl-Handling)
    $portalApps = foreach ($p in $script:PortablePortalDefs) {
        @{ Id = $p.Id; Name = $p.Name; Desc = $p.Desc; Type = 'web'; Web = $p.Url; Portal = $true; Auto = $p.Auto }
    }
    $allApps = @($script:PortableAppDefs) + @($portalApps)
    while ($true) {
        $items = @()
        foreach ($app in $allApps) {
            $found = Find-SysPilotPortableApp -App $app
            if ($app.Portal) {
                $mark = '[portal]'; $color = 'DarkGray'
                $typeTag = 'Portal'
                if ($app.Auto) { $mark = '[portal/auto]' }
            } elseif ($app.Type -eq 'web') {
                $mark = '[web]'; $color = 'DarkGray'; $typeTag = 'Web'
            } else {
                $mark = if ($found -and $found.Path) { '[installiert]' } elseif ($found -and $found.Installed) { '[installiert*]' } else { '[nicht vorhanden]' }
                $color = if ($found -and $found.Path) { 'Green' } else { 'White' }
                $typeTag = switch ($app.Type) {
                    'zip'        { 'portabel' }
                    'script'     { 'Skript' }
                    'installer'  { 'Installer' }
                    'winget'     { 'winget' }
                    'storeapp'   { 'Store' }
                    default      { $app.Type }
                }
            }
            $items += @{ Label = "$($app.Name) [$typeTag] $mark"; Color = $color; Tag = "app:$($app.Id)" }
        }
        $items += @{ Label = 'Vollpaket: mehrere Apps zum Installieren auswaehlen'; Color = 'Yellow'; Tag = 'bulk' }
        $items += @{ Label = 'Status-Details anzeigen'; Color = 'DarkGray'; Tag = 'details' }
        $items += @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = $null }
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'SysPilot - Apps & Store-Clients' -Footer 'Pfeiltasten, Enter = auswaehlen, Esc = zurueck'
        if ($null -eq $sel) { return }

        if ($sel -eq 'bulk') {
            # Mehrfachauswahl: alle installierbaren Apps (ohne 'web'/'storeapp'-Typ)
            Write-Host '  Apps werden gescannt, bitte warten...' -ForegroundColor DarkGray
            $pickItems = @()
            foreach ($a in $script:PortableAppDefs) {
                if ($a.Type -eq 'web' -or $a.Type -eq 'storeapp') { continue }
                $f = Find-SysPilotPortableApp -App $a
                $have = ($f -and ($f.Path -or $f.Installed))
                $pickItems += @{ Label = "$($a.Name)$(if ($have) { '  [installiert]' } else { '' })"; Color = $(if ($have) { 'DarkGray' } else { 'White' }); Tag = $a.Id; Checked = $false }
            }
            $chosen = Show-SysPilotMultiSelectMenu -Items $pickItems -Title 'Vollpaket-Installation - Apps per Leertaste auswaehlen'
            if ($null -eq $chosen) { continue }
            if ($chosen.Count -eq 0) { Write-Host '  Keine Apps ausgewaehlt.' -ForegroundColor DarkGray; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; continue }
            foreach ($cid in $chosen) {
                $ca = $script:PortableAppDefs | Where-Object { $_.Id -eq $cid } | Select-Object -First 1
                if ($ca) { Write-Host ''; Install-SysPilotPortableApp -App $ca | Out-Null }
            }
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            continue
        }

        if ($sel -eq 'details') {
            foreach ($app in $allApps) {
                $f = Find-SysPilotPortableApp -App $app
                Write-Host ''
                Write-Host "  === $($app.Name) ===" -ForegroundColor Cyan
                Write-Host "  $($app.Desc)" -ForegroundColor DarkGray
                if ($app.Portal) { Write-Host "  Portal: $($app.Web)" -ForegroundColor Cyan }
                if ($f -and $f.Path) { Write-Host "  Pfad: $($f.Path)" -ForegroundColor Green }
                elseif ($f -and $f.Installed) { Write-Host '  Installiert (kein Startpfad gefunden)' -ForegroundColor Yellow }
                else { Write-Host '  Nicht installiert' -ForegroundColor DarkGray }
            }
            Write-Host ''
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            continue
        }

        $appId = $sel.Substring(4)
        $app = $allApps | Where-Object { $_.Id -eq $appId } | Select-Object -First 1
        if (-not $app) { continue }
        # Untermenue: installieren / starten / seite oeffnen
        $installLabel = if ($app.Id -eq 'ninite') { 'Ninite-Manager (Apps auswaehlen, still installieren)' }
                        elseif ($app.Type -eq 'winget') { 'Installieren (winget/Microsoft Store)' }
                        elseif ($app.Type -eq 'installer') { 'Herunterladen + installieren' }
                        elseif ($app.Type -eq 'storeapp') { 'Installationsseite oeffnen (Store-beschraenkt)' }
                        elseif ($app.Type -eq 'web' -or $app.Portal) { 'Im Browser oeffnen' }
                        else { 'Herunterladen + installieren (portable)' }
        $sub = @(
            @{ Label = $installLabel;                            Color = 'Green';  Tag = 'install' }
            @{ Label = 'Starten';                               Color = 'Cyan';   Tag = 'run' }
            @{ Label = 'Offizielle Seite im Browser oeffnen';   Color = 'DarkGray'; Tag = 'web' }
            @{ Label = 'Zurueck';                                Color = 'DarkGray'; Tag = $null }
        )
        $pick = Show-SysPilotArrowMenu -Items $sub -Title "$($app.Name) - Aktion" -Footer 'Enter = auswaehlen, Esc = zurueck'
        if ($null -eq $pick) { continue }
        switch ($pick) {
            'install' {
                if ($app.Id -eq 'ninite') { Show-SysPilotNinitePicker }
                elseif ($app.Portal -or $app.Type -eq 'web') { Start-Process $app.Web }
                else { Install-SysPilotPortableApp -App $app | Out-Null }
            }
            'run'     {
                if ($app.Id -eq 'ninite') { Show-SysPilotNinitePicker }
                else { Start-SysPilotPortableApp -App $app }
            }
            'web'     { Start-Process $app.Web }
        }
        Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
    }
}

Export-ModuleMember -Function Find-SysPilotPortableApp, Get-SysPilotGitHubAssetUrl,
    Install-SysPilotPortableApp, Start-SysPilotPortableApp, Show-SysPilotPortableAppsMenu,
    Find-SysPilotStoreApp, Install-SysPilotWingetApp, Start-SysPilotStoreApp,
    Install-SysPilotInstallerApp, Get-SysPilotMajorGeeksAsset, Save-SysPilotMajorGeeksFile,
    Get-SysPilotNiniteApps, Install-SysPilotNiniteApps, Show-SysPilotNinitePicker,
    Get-SysPilotDownloadPortals
