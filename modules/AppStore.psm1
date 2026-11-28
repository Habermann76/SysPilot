# =====================================================================
# AppStore.psm1 - SysPilot "Megastore"
# =====================================================================
# Baut einen lokalen App-Index (Inhaltsverzeichnis) aus:
#   - kuratiertem Update-Katalog (SoftwareUpdateCenter, ~147 Apps, reich)
#   - Ninite-Katalog (~160 Apps)
#   - Chocolatey-Vollindex (alle Pakete)
#   - Scoop-Bucket-Apps (alle Buckets)
#   - GitHub-Repositories (API, stars-sortiert)
#   - GitLab-Projekte (API, stars-sortiert)
# Derselbe App kann aus mehreren Managern kommen -> EIN Karte mit
# mehreren Install-Quellen. Index liegt als JSON in
# %LOCALAPPDATA%\SysPilot\appindex.json und wird woechentlich per
# geplanter Aufgabe aktualisiert (Install-SysPilotAppIndexTask).
# =====================================================================

$script:AppStoreCats = @(
    @{ Id='Browser';        Name='Browser';            Keys='chrome edge firefox brave opera vivaldi zen waterfox thorium librewolf mullvad torbrowser seamonkey browser' },
    @{ Id='Multimedia';     Name='Multimedia';         Keys='vlc mpv mpc mediaplayer kodi foobar aimp audacity handbrake gimp inkscape obs sharex greenshot flameshot screenshot video audio music player editor image photo media codec mp3 flac ogg midi synth tracker mixer podcast audiobook subtitle lyric record screen cast stream radio convert encode decode dvd bluray' },
    @{ Id='Netzwerk & VPN'; Name='Netzwerk & VPN';     Keys='tailscale zerotier vpn wireguard openvpn cloudflare warp nordvpn proton mullvad windscribe syncthing rclone localsend putty kitty termius filezilla wireshark network torrent qbittorrent transmission utorrent btsync adb adb-tools ngrok cloudflared frp chisel proxy socks5 socks' },
    @{ Id='Sicherheit';     Name='Sicherheit';         Keys='antivirus avast avg malwarebytes kaspersky avira bitdefender norton eset sophos defender keepass bitwarden veracrypt password manager firewall encrypt backup veeam password passwordmanager credential secret token hashcat john hydra nmap masscan wireshark' },
    @{ Id='System & Tools'; Name='System & Tools';     Keys='7-zip 7zip winrar notepad++ ditto windirstat wiztree treesize bulkrename advancedip scanner hwinfo cpu-z gpuz process explorer sysinternals speedfan hwmonitor crystal diskmark crystalmark memtest prime95 cpu benchmark cleaner debloat optimize tweak btop htop glances fastfetch neofetch starship oh-my-posh zoxide fzf ripgrep fd bat jq yq tmux screen totalcommander doublecmd xyplorer files ranger nnn vifm mc midnight explorer filemanager taskbar dock rainmeter wallpaper theme icon cursor hotkey shortcut clipboard ditto autohotkey autokey powertoys' },
    @{ Id='Entwicklung';    Name='Entwicklung';        Keys='git node npm python pip dotnet java jdk visualstudio vscode vscodium cursor windsurf zed jetbrains rider resharper postman insomnia githubdesktop docker kubernetes helm terraform ansible vagrant postgresql mysql mariadb sqlite redis mongodb developer code ide sdk framework runtime compiler nginx apache php ruby perl lua clang gcc llvm cmake make ninja meson bazel gradle maven sbt cargo rustup go golang swift kotlin flutter react vue angular svelte electron tauri jest playwright selenium eslint prettier typescript graphql grpc thrift api cli sdk compiler interpreter debug lint build ci cd devops sre sysadmin script automation macro batch shell bash zsh powershell pwsh cygwin msys mingw msys2 cygwin strawberry perl activeperl activetcl tcl tk wish expect' },
    @{ Id='KI-Apps';        Name='KI-Apps';            Keys='chatgpt claude gemini copilot ollama lmstudio openwebui anythingllm jan perplexity deepseek groq openrouter mistral ai assistant llm model' },
    @{ Id='Gaming';         Name='Gaming';             Keys='steam epicgames gog battle.net xbox geforce riot ubisoft ea origin faceit discord medal games game launcher emu emulator retroarch pcsx2 dolphin yuzu ryujinx' },
    @{ Id='Buerowerkzeuge'; Name='Buerowerkzeuge';    Keys='libreoffice onlyoffice openoffice office word excel powerpoint pdf calibre sumatra reader pandoc typora marktypora obsidian notion joplin notes document write ebook epub mobi kindle latex tex overleaf scribus drawio diagram gantt kanban whiteboard miro excalidraw plantuml mermaid graphviz svg png jpg gif webp heic' },
    @{ Id='Kommunikation';  Name='Kommunikation';      Keys='discord telegram signal whatsapp threema element matrix zoom teams slack mattermost rocket riot element webex gotomeeting meetup jitsi' },
    @{ Id='Sprachen & Uebungen'; Name='Sprachen & Uebungen'; Keys='anki duolingo quizlet language translate dictionary tutor school learn' },
    @{ Id='Design & Media'; Name='Design & Media';     Keys='figma sketch canva photoshop gimp blender krita inkscape illustrator darktable rawtherapee davinci resolve premiere aftereffects font icon' },
    @{ Id='Sonstige';       Name='Sonstige';           Keys='' }
)

function Get-SysPilotAppIndexPath {
    $dir = Join-Path $env:LOCALAPPDATA 'SysPilot'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return (Join-Path $dir 'appindex.json')
}

function Get-SysPilotAppIndex {
    <# Liest den lokalen App-Index. Gibt @{Entries;Built;Count;Sources} zurueck. #>
    $p = Get-SysPilotAppIndexPath
    if (-not (Test-Path $p)) { return @{ Entries=@(); Built=''; Count=0; Sources=@{} } }
    try {
        $j = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        $entries = @()
        foreach ($e in @($j.Entries)) {
            # JSON macht aus Hashtable einen PSCustomObject - fuer
            # .ContainsKey()/Index-Zugriff zurueck nach Hashtable
            if ($e.Managers -and $e.Managers -isnot [hashtable]) {
                $mh = @{}
                foreach ($prop in $e.Managers.PSObject.Properties) { $mh[$prop.Name] = [string]$prop.Value }
                $e.Managers = $mh
            }
            $entries += $e
        }
        return @{ Entries=$entries; Built=[string]$j.Built; Count=[int]$j.Count; Sources=$j.Sources }
    } catch { return @{ Entries=@(); Built=''; Count=0; Sources=@{} } }
}

function Save-SysPilotAppIndex {
    param([object[]]$Entries, [hashtable]$Sources = @{})
    $idx = Get-SysPilotAppIndex
    $doc = [ordered]@{
        Built   = (Get-Date).ToString('s')
        Count   = @($Entries).Count
        Sources = $Sources
        Entries = @($Entries)
    }
    $doc | ConvertTo-Json -Depth 6 -Compress:$false | Set-Content (Get-SysPilotAppIndexPath) -Encoding UTF8
    return $doc
}

function Get-SysPilotIndexCat {
    <# Kategorie eines Eintrags per Keyword-Heuristik (de+en).
       Zweistufig: erst Wort-Grenzen im Rohtext, dann normalisierter
       Substring (deckt 'notepadplusplus' -> 'notepad', 'gitkraken' ->
       'git' etc. ab - choco/scoop-Namen haben keine Worttrenner). #>
    param([Parameter(Mandatory)][string]$Name, [string]$Desc = '')
    $hay = ("$Name $Desc").ToLower()
    $hayNorm = ([regex]::Replace($hay, '[^a-z0-9]', ''))
    foreach ($c in $script:AppStoreCats) {
        if ($c.Id -eq 'Sonstige') { continue }
        foreach ($k in ($c.Keys -split ' ')) {
            $kl = $k.ToLower()
            if ($kl.Length -ge 3 -and $hay -match "\b$([regex]::Escape($kl))\b") { return $c.Id }
        }
    }
    foreach ($c in $script:AppStoreCats) {
        if ($c.Id -eq 'Sonstige') { continue }
        foreach ($k in ($c.Keys -split ' ')) {
            $kn = ([regex]::Replace($k.ToLower(), '[^a-z0-9]', ''))
            if ($kn.Length -ge 4 -and $hayNorm.Contains($kn)) { return $c.Id }
        }
    }
    return 'Sonstige'
}

function Get-SysPilotIndexIcon {
    <# Icon-URL fuer die Karte: GitHub-Avatar, sonst Domain-Favicon. #>
    param([string]$Page = '', [string]$Github = '')
    if ($Github) {
        $owner = ($Github -split '/')[0]
        if ($owner) { return "https://github.com/$owner.png?size=64" }
    }
    if ($Page) {
        try { $host_ = ([Uri]$Page).Host; if ($host_) { return "https://www.google.com/s2/favicons?domain=$host_&sz=64" } } catch {}
    }
    return ''
}

function Get-SysPilotIndexNorm {
    param([string]$s)
    return ([regex]::Replace("$s".ToLower(),'[^a-z0-9]',''))
}

# ---------------------------------------------------------------------
# HARVESTER: liefern rohe Zeilen @{Name;Desc;Page;Cat;Managers}
# ---------------------------------------------------------------------

function Get-SysPilotIndexFromCatalog {
    <# Kuratierter Katalog (reichste Quelle). #>
    $rows = @()
    try {
        if (-not (Get-Command Get-SysPilotUpdateCatalog -ErrorAction SilentlyContinue)) { Import-SysPilotModule -Name 'SoftwareUpdateCenter' -ErrorAction SilentlyContinue }
        foreach ($a in @(Get-SysPilotUpdateCatalog)) {
            $m = @{}
            if ($a.WingetId) { $m['winget'] = [string]$a.WingetId }
            if ($a.Gh)        { $m['github']  = [string]$a.Gh }
            if ($a.NpmPkg)    { $m['npm']     = [string]$a.NpmPkg }
            if ($a.PipPkg)    { $m['pip']     = [string]$a.PipPkg }
            if ($a.Page)      { $m['web']     = [string]$a.Page }
            if ($a.Mg)        { $m['majorgeeks'] = [string]$a.Mg }
            $desc = [string]$(if ($a.Desc) { $a.Desc } else { $a.Note })
            $rows += [pscustomobject]@{
                Name=[string]$a.Name; Desc=$desc; Cat=[string]$a.Cat
                Page=[string]$(if($a.Page){$a.Page}elseif($a.Gh){"https://github.com/$($a.Gh)"}else{''})
                Github=[string]$(if($a.Gh){$a.Gh}else{''})
                Managers=$m; Source='katalog'; Priority=100
            }
        }
    } catch {}
    return $rows
}

function Get-SysPilotIndexFromNinite {
    <# Ninite-App-Liste (~160). #>
    $rows = @()
    try {
        if (-not (Get-Command Get-SysPilotNiniteApps -ErrorAction SilentlyContinue)) { Import-SysPilotModule -Name 'PortableTools' -ErrorAction SilentlyContinue }
        foreach ($a in @(Get-SysPilotNiniteApps)) {
            $rows += [pscustomobject]@{
                Name=[string]$a.Name; Desc="Ninite still-Installation$(if($a.Version){" (v$($a.Version))"})"
                Cat=''; Page='https://ninite.com/'
                Managers=@{ ninite=[string]$a.Slug }
                Source='ninite'; Priority=80
            }
        }
    } catch {}
    return $rows
}

function Get-SysPilotIndexFromChoco {
    <# Chocolatey-Vollindex (alle Pakete, id|version). #>
    $rows = @()
    $exe = $null
    try { if (Get-Command Find-SysPilotChocoExeLocal -ErrorAction SilentlyContinue) { $exe = Find-SysPilotChocoExeLocal } } catch {}
    if (-not $exe) { $exe = (Get-Command choco.exe -ErrorAction SilentlyContinue).Source }
    if (-not $exe) { return $rows }
    try {
        $out = & $exe search '' --limit-output 2>&1 | Out-String
        foreach ($line in ($out -split "`r?`n")) {
            $f = $line -split '\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
            if ($f.Count -lt 1) { continue }
            $id = $f[0]
            if ($id -notmatch '^[a-zA-Z0-9][\w.\-]*$' -or $id -match '^(chocolatey|package|software)') { continue }
            # Varianten (.install/.portable/.tool/.lib) kuerzen -> basis-Name
            $base = $id -replace '\.(install|portable|tool|lib|dotnetfx)$',''
            $rows += [pscustomobject]@{
                Name=$base; Desc=''; Cat=''
                Page="https://community.chocolatey.org/packages/$base"
                Managers=@{ chocolatey=$id }
                Source='choco'; Priority=30
            }
        }
    } catch {}
    return $rows
}

function Get-SysPilotIndexFromScoop {
    <# Scoop-Bucket-Apps (ANSI-Output wird gestrippt). #>
    $rows = @()
    $exe = $null
    try { if (Get-Command Get-SysPilotScoopExeLocal -ErrorAction SilentlyContinue) { $exe = Get-SysPilotScoopExeLocal } } catch {}
    if (-not $exe) { $exe = (Get-Command scoop.exe -ErrorAction SilentlyContinue).Source }
    if (-not $exe) { return $rows }
    try {
        $out = & $exe search '' 2>&1 | Out-String
        $out = $out -replace "`e\[[0-9;]*m",''
        foreach ($line in ($out -split "`r?`n")) {
            $t = ($line.Trim() -split '\s+') | Where-Object { $_ -ne '' }
            if ($t.Count -lt 3) { continue }
            $nm = $t[0]
            if ($nm -match '^(Name|Results|----|Software|Bucket)') { continue }
            if ($nm -notmatch '^[a-zA-Z0-9][\w.\-]*$') { continue }
            $bucket = $t[2]
            $rows += [pscustomobject]@{
                Name=$nm; Desc="Scoop ($bucket)"; Cat=''
                Page="https://scoop.sh/#/$bucket/$nm"
                Managers=@{ scoop="$bucket/$nm" }
                Source='scoop'; Priority=30
            }
        }
    } catch {}
    return $rows
}

function Get-SysPilotIndexFromCodeRepos {
    <# GitHub + GitLab: stars-sortierte Repo-Suche (Windows-nah). #>
    <# Gibt @{Github=@();Gitlab=@()} mit @{Name;Desc;Page;Github|Gitlab;Stars}. #>
    $gh = @(); $gl = @()
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
    $hdr = @{ 'User-Agent' = 'SysPilot-AppStore'; 'Accept' = 'application/vnd.github+json' }
    $ghQueries = @(
        'windows+app+stars:%3E800',
        'windows+software+stars:%3E400',
        'powershell+stars:%3E400',
        'tweaks+windows+stars:%3E100',
        'topic:windows+stars:%3E300'
    )
    $seen = @{}
    foreach ($qq in $ghQueries) {
        try {
            $r = Invoke-RestMethod "https://api.github.com/search/repositories?q=$qq&sort=stars&order=desc&per_page=40" -Headers $hdr -TimeoutSec 15 -ErrorAction Stop
            foreach ($it in @($r.items)) {
                $k = $it.full_name.ToLower(); if ($seen.ContainsKey($k)) { continue }; $seen[$k]=1
                $gh += [pscustomobject]@{ Name=$it.name; Full=$it.full_name; Desc=[string]$it.description
                    Page=$it.html_url; Github=$it.full_name; Stars=[int]$it.stargazers_count; Lang=[string]$it.language }
            }
        } catch {}
        Start-Sleep -Milliseconds 800   # API-Rate-Limit schonen
    }
    foreach ($qq in @('windows','powershell','windows+tweaks')) {
        try {
            $enc = [Uri]::EscapeDataString($qq)
            $r = Invoke-RestMethod "https://gitlab.com/api/v4/projects?search=$enc&order_by=star_count&sort=desc&per_page=30" -TimeoutSec 15 -ErrorAction Stop
            foreach ($it in @($r)) {
                $ghk = "gh:$($it.path_with_namespace)".ToLower()
                if ($seen.ContainsKey($ghk)) { continue }; $seen[$ghk]=1
                $gl += [pscustomobject]@{ Name=$it.name; Full=$it.path_with_namespace; Desc=[string]$it.description
                    Page=$it.web_url; Gitlab=$it.path_with_namespace; Stars=[int]$it.star_count }
            }
        } catch {}
        Start-Sleep -Milliseconds 500
    }
    return @{ Github=@($gh); Gitlab=@($gl) }
}

# ---------------------------------------------------------------------
# INDEX BAUEN
# ---------------------------------------------------------------------

function Get-SysPilotAppIndexEntries {
    <# Merge aller Quellen zu Index-Eintraegen (Dedupe nach Name,
       Manager-Quellen werden zusammengefuehrt). #>
    param([object[]]$Rows)
    $merged = [ordered]@{}
    foreach ($r in $Rows) {
        $key = Get-SysPilotIndexNorm $r.Name
        if (-not $key) { continue }
        if (-not $merged.Contains($key)) {
            $cat = $(if ($r.Cat) { [string]$r.Cat } else { Get-SysPilotIndexCat -Name $r.Name -Desc ([string]$r.Desc) })
            $merged[$key] = [pscustomobject]@{
                Name=[string]$r.Name; Desc=[string]$r.Desc; Cat=$cat
                Page=[string]$r.Page; Github=[string]$r.Github
                Icon=Get-SysPilotIndexIcon -Page ([string]$r.Page) -Github ([string]$r.Github)
                Managers=@{}; Sources=@(); Score=0; _prio=[int]$r.Priority
            }
        }
        $e = $merged[$key]
        # Quellen anh?ngen
        foreach ($mk in $r.Managers.Keys) {
            if (-not $e.Managers.ContainsKey($mk)) { $e.Managers[$mk] = [string]$r.Managers[$mk] }
        }
        if ($r.Source -and $e.Sources -notcontains $r.Source) { $e.Sources += $r.Source }
        # Reichere Felder aus der hoeher priorisierten Quelle uebernehmen
        if ([int]$r.Priority -gt $e._prio) {
            $e._prio = [int]$r.Priority
            if ($r.Desc) { $e.Desc = [string]$r.Desc }
            if ($r.Cat)  { $e.Cat  = [string]$r.Cat }
            if ($r.Page -and -not $e.Page) { $e.Page = [string]$r.Page }
            if ($r.Github -and -not $e.Github) { $e.Github = [string]$r.Github }
            $e.Icon = Get-SysPilotIndexIcon -Page $e.Page -Github $e.Github
        }
        # Score: Anzahl Quellen + Prioritaet
        $e.Score = $e.Sources.Count * 10 + $e._prio
    }
    $out = foreach ($e in $merged.Values) {
        $e.PSObject.Properties.Remove('_prio')
        # Sortierhilfe: Manager-Liste als Array fuer JSON
        $e | Add-Member -NotePropertyName ManagerList -NotePropertyValue @($e.Managers.Keys) -Force
        $e
    }
    return @($out | Sort-Object Cat, Name)
}

# ---------------------------------------------------------------------
# KI-KATEGORISIERUNG (Herbert)
# ---------------------------------------------------------------------
# Verbleibende 'Sonstige'-Eintraege (meist choco/scoop-Namen ohne
# Beschreibung) werden batchweise durch den KI-Provider klassifiziert.
# Ergebnisse landen in appindex-aicat.json (Cache) - beim naechsten
# Rebuild werden nur NEUE Namen klassifiziert, der Index bleibt schnell.

$script:AppStoreAiCatTokens = [ordered]@{
    browser='Browser'; multimedia='Multimedia'; netzwerk='Netzwerk & VPN'
    sicherheit='Sicherheit'; system='System & Tools'; entwicklung='Entwicklung'
    ki='KI-Apps'; gaming='Gaming'; buero='Buerowerkzeuge'
    kommunikation='Kommunikation'; sprachen='Sprachen & Uebungen'; design='Design & Media'
}

function Get-SysPilotIndexAiCatCachePath {
    return (Join-Path (Split-Path (Get-SysPilotAppIndexPath) -Parent) 'appindex-aicat.json')
}

function Read-SysPilotIndexAiCatCache {
    $p = Get-SysPilotIndexAiCatCachePath
    if (-not (Test-Path $p)) { return @{} }
    try {
        $j = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        $h = @{}
        foreach ($prop in $j.PSObject.Properties) { $h[$prop.Name] = [string]$prop.Value }
        return $h
    } catch { return @{} }
}

function Save-SysPilotIndexAiCatCache {
    param([hashtable]$Cache)
    try {
        $Cache | ConvertTo-Json -Compress | Set-Content (Get-SysPilotIndexAiCatCachePath) -Encoding UTF8
    } catch {}
}

function Add-SysPilotAiIndexCategories {
    <# Weist 'Sonstige'-Eintraegen per KI eine Kategorie zu.
       Gibt Anzahl geaenderter Eintraege zurueck (0 = kein Provider /
       nichts zu tun). Param -MaxBatches begrenzt die Laufzeit -
       Rest wird beim naechsten Rebuild nachgeholt (Cache). #>
    param([object[]]$Entries, [int]$MaxBatches = 40, [int]$BatchSize = 80, [scriptblock]$OnProgress = $null)
    $say = { param($m) if ($OnProgress) { $null = & $OnProgress ([string]$m) } }
    $miss = @($Entries | Where-Object { $_.Cat -eq 'Sonstige' })
    if ($miss.Count -eq 0) { return 0 }
    # Provider verfuegbar? (Import + Enabled-Check)
    try {
        if (-not (Get-Command Invoke-SysPilotAiChat -ErrorAction SilentlyContinue)) { Import-SysPilotModule -Name 'AiAssist' -ErrorAction SilentlyContinue }
        if (-not (Get-Command Get-SysPilotAiProviders -ErrorAction SilentlyContinue)) { return 0 }
        $hasProvider = @((Get-SysPilotAiProviders) | Where-Object { $_.Enabled }).Count -gt 0
        if (-not $hasProvider) { return 0 }
    } catch { return 0 }
    $cache = Read-SysPilotIndexAiCatCache
    # Cache-Treffer sofort anwenden
    $todo = @()
    foreach ($e in $miss) {
        $k = Get-SysPilotIndexNorm "$($e.Name) $($e.Desc)"
        if ($cache.ContainsKey($k)) { $e.Cat = $cache[$k] }
        else { $todo += $e }
    }
    $changed = @($miss | Where-Object { $_.Cat -ne 'Sonstige' }).Count
    if ($todo.Count -eq 0) { return $changed }
    # Provider-Strategie: lokales Ollama mit dem GROESSTEN verfuegbaren
    # Modell ist ideal (kostenlos, privat, schnell) - Resolve-SysPilotAiModel
    # waehlt sonst die kleinste/free-Variante, die bei 12 Kategorien
    # schon mal danebengreift. Fallback: generische Provider-Kette.
    $aiProvider = ''; $aiModel = ''
    try {
        $prov = @(Get-SysPilotAiProviders | Where-Object { $_.Enabled -and $_.BaseUrl -match '11434' })[0]
        if ($prov) {
            $ml = Get-SysPilotAiProviderModels -Provider $prov -TimeoutSec 10
            if ($ml.Ok -and @($ml.Models).Count -gt 0) {
                $best = $null; $bestScore = -1.0
                foreach ($mm in $ml.Models) {
                    $id = [string]$mm.Id
                    $score = [double]$mm.Context
                    if ($id -match '(\d+(?:\.\d+)?)\s*b') { $score += [double]$Matches[1] * 1000000 }
                    if ($score -gt $bestScore) { $bestScore = $score; $best = $id }
                }
                if ($best) { $aiProvider = [string]$prov.Name; $aiModel = $best }
            }
        }
    } catch {}
    # Token-Liste fuer den Prompt
    $catList = (@($script:AppStoreAiCatTokens.GetEnumerator() | ForEach-Object { "$($_.Key)|$($_.Value)" }) -join ', ')
    $sys = 'Du bist ein Klassifizierer fuer einen Windows-App-Store. Antworte AUSSCHLIESSLICH mit Zeilen "nummer|token" - kein App-Name, keine Erklaerung, kein Markdown, keine nummerierten Wiederholungen.'
    $batches = [math]::Ceiling($todo.Count / $BatchSize)
    $done = 0
    for ($b = 0; $b -lt $batches -and $b -lt $MaxBatches; $b++) {
        $slice = @($todo | Select-Object -Skip ($b * $BatchSize) -First $BatchSize)
        & $say "KI-Kategorie Batch $($b+1)/$([math]::Min($batches,$MaxBatches)) ($($slice.Count) Apps) ..."
        $lines = for ($i = 0; $i -lt $slice.Count; $i++) {
            $d = ([string]$slice[$i].Desc); if ($d.Length -gt 60) { $d = $d.Substring(0,60) }
            "$($i+1). $($slice[$i].Name)$(if($d){" - $d"})"
        }
        $prompt = @"
Ordne jede App der passendsten Kategorie zu. Moegliche token|Kategorie: $catList
Antworte AUSSCHLIESSLICH mit Zeilen "nummer|token" (z.B. "3|browser"), genau eine pro Eintrag, in Reihenfolge, ohne weitere Texte.

$($lines -join "`n")
"@
        try {
            if ($aiProvider) {
                $r = Invoke-SysPilotAiChat -Prompt $prompt -System $sys -ProviderName $aiProvider -Model $aiModel -TimeoutSec 90
            } else {
                $r = Invoke-SysPilotAiChat -Prompt $prompt -System $sys -TimeoutSec 60
            }
            if (-not $r.Ok -or -not $r.Text) {
                # Lokaler Versuch fehlgeschlagen -> generische Kette einmalig
                if ($aiProvider) { $r = Invoke-SysPilotAiChat -Prompt $prompt -System $sys -TimeoutSec 60 }
                else { break }
            }
            if (-not $r.Ok -or -not $r.Text) { break }
            foreach ($ln in ([string]$r.Text -split "`r?`n")) {
                if ($ln -match '^\s*(\d+)\s*[\.\):\-|]?\s*([A-Za-zÄÖÜäöüß]+)') {
                    $n = [int]$Matches[1]; $tok = $Matches[2].ToLower()
                    $tok = $tok -replace '[^a-zäöüß]',''
                    # Token-Aliase + direktes Cat-Match zulaessig
                    $catId = $null
                    if ($script:AppStoreAiCatTokens.Contains($tok)) { $catId = $script:AppStoreAiCatTokens[$tok] }
                    else {
                        foreach ($kv in $script:AppStoreAiCatTokens.GetEnumerator()) {
                            $cn = ([regex]::Replace($kv.Value.ToLower(),'[^a-zäöüß]',''))
                            if ($tok -eq $cn -or $tok -eq ([regex]::Replace($kv.Key,'[^a-z]',''))) { $catId = $kv.Value; break }
                        }
                    }
                    if ($catId -and $n -ge 1 -and $n -le $slice.Count) {
                        $slice[$n-1].Cat = $catId
                        $cache[(Get-SysPilotIndexNorm "$($slice[$n-1].Name) $($slice[$n-1].Desc)")] = $catId
                        $changed++
                    }
                }
            }
            $done += $slice.Count
        } catch { break }
    }
    if ($done -gt 0) { Save-SysPilotIndexAiCatCache -Cache $cache }
    return $changed
}

function Update-SysPilotIndexSonstige {
    <# Klassifiziert die 'Sonstige'-Eintraege des bestehenden Index per
       KI (Add-SysPilotAiIndexCategories) und speichert den Index neu.
       Gibt Statistik zurueck; laeuft headless (Index-Task-konform). #>
    param([int]$MaxBatches = 60, [scriptblock]$OnProgress = $null)
    $idx = Get-SysPilotAppIndex
    if (@($idx.Entries).Count -eq 0) { return @{ Ok=$false; Error='Kein Index vorhanden'; Changed=0; Before=0; Rest=0 } }
    $before = @($idx.Entries | Where-Object { $_.Cat -eq 'Sonstige' }).Count
    $say = { param($m) if ($OnProgress) { $null = & $OnProgress ([string]$m) } }
    & $say "Sonstige: $before Eintraege - KI-Kategorisierung startet ..."
    $changed = Add-SysPilotAiIndexCategories -Entries $idx.Entries -MaxBatches $MaxBatches -OnProgress $OnProgress
    $rest = @($idx.Entries | Where-Object { $_.Cat -eq 'Sonstige' }).Count
    Save-SysPilotAppIndex -Entries $idx.Entries -Sources $idx.Sources
    return @{ Ok=$true; Changed=$changed; Before=$before; Rest=$rest }
}

function Test-SysPilotIndexAiReady {
    <# Schneller Check ob ein lokaler KI-Server fuer die Index-
       Kategorisierung bereitsteht (Ollama-API erreichbar + Modell). #>
    try {
        $r = Invoke-RestMethod 'http://localhost:11434/api/tags' -TimeoutSec 4 -ErrorAction Stop
        if (@($r.models).Count -gt 0) { return $true }
    } catch {}
    # Fallback: irgendein aktivierter Provider koennte reichen -
    # der Sort-JOB probiert die Kette ohnehin selbst durch.
    try {
        if (Get-Command Get-SysPilotAiProviders -ErrorAction SilentlyContinue) {
            return (@(Get-SysPilotAiProviders | Where-Object { $_.Enabled }).Count -gt 0)
        }
    } catch {}
    return $false
}

function Show-SysPilotIndexAiSetup {
    <# Interaktives Setup fuer die KI-Kategorisierung: Ollama per
       winget installieren (sichtbare Bestaetigung - Systemaenderung),
       'ollama serve' starten, passendes Modell per RAM-Groesse pullen.
       Gibt $true zurueck, wenn danach ein lokaler Provider bereit ist. #>
    param([object]$Owner)
    $mb = { param($t,$m,$i) [System.Windows.MessageBox]::Show($m,$t,$i) }
    # Schritt 1: Ollama installiert?
    $ollamaExe = $null
    $oc = Get-Command ollama -ErrorAction SilentlyContinue
    if ($oc) { $ollamaExe = $oc.Source }
    if (-not $ollamaExe -and (Test-Path "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe")) { $ollamaExe = "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe" }
    if (-not $ollamaExe) {
        $r = & $mb 'KI-Server fehlt' "Kein lokaler KI-Server (Ollama) gefunden.`n`nDie Index-Kategorisierung funktioniert am besten mit Ollama - kostenlos, laeuft lokal, unlimitiert.`n`nOllama jetzt per winget installieren?" 'YesNo'
        if ($r -ne 'Yes') { return $false }
        $w = $null
        $wc = Get-Command winget -ErrorAction SilentlyContinue
        if ($wc) { $w = $wc.Source }
        if (-not $w) { & $mb 'Fehler' 'winget nicht gefunden - Ollama manuell von ollama.com installieren.' 'OK' | Out-Null; return $false }
        $pr = Invoke-SysPilotMonitoredProcess -FilePath $w -ArgList @('install','--id','Ollama.Ollama','--exact','--accept-package-agreements','--accept-source-agreements','--disable-interactivity') -Label 'Ollama-Installation' -TimeoutSec 900 -Quiet
        if (-not $pr.Ok) { & $mb 'Fehler' "Ollama-Installation fehlgeschlagen:`n$($pr.Error)" 'OK' | Out-Null; return $false }
        $ollamaExe = "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe"
        if (-not (Test-Path $ollamaExe)) { $oc2 = Get-Command ollama -ErrorAction SilentlyContinue; if ($oc2) { $ollamaExe = $oc2.Source } }
        if (-not $ollamaExe) { & $mb 'Fehler' 'ollama.exe nach Installation nicht gefunden.' 'OK' | Out-Null; return $false }
    }
    # Schritt 2: Server laeuft?
    $apiUp = $false
    try { Invoke-RestMethod 'http://localhost:11434/api/tags' -TimeoutSec 4 -ErrorAction Stop | Out-Null; $apiUp = $true } catch {}
    if (-not $apiUp) {
        try { Start-Process -FilePath $ollamaExe -ArgumentList 'serve' -WindowStyle Hidden -ErrorAction Stop | Out-Null } catch {}
        Start-Sleep -Seconds 3
        try { Invoke-RestMethod 'http://localhost:11434/api/tags' -TimeoutSec 6 -ErrorAction Stop | Out-Null; $apiUp = $true } catch {}
    }
    if (-not $apiUp) { & $mb 'Server startet nicht' 'Ollama-Server liess sich nicht starten (Port 11434).' 'OK' | Out-Null; return $false }
    # Schritt 3: Modell vorhanden?
    $models = @()
    try { $models = @((Invoke-RestMethod 'http://localhost:11434/api/tags' -TimeoutSec 5).models | ForEach-Object { [string]$_.name }) } catch {}
    if ($models.Count -eq 0) {
        $ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
        $model = if ($ramGB -ge 16) { 'qwen3:8b' } elseif ($ramGB -ge 8) { 'qwen3:4b' } else { 'qwen3:1.7b' }
        $r = & $mb 'Modell laden' "Ollama laeuft, aber kein Modell ist installiert.`n`nEmpfohlenes Modell fuer die Kategorisierung: $model (~2-5 GB Download)`n`nJetzt laden? (kann je nach Verbindung 5-30 Minuten dauern)" 'YesNo'
        if ($r -ne 'Yes') { return $false }
        $pr = Invoke-SysPilotMonitoredProcess -FilePath $ollamaExe -ArgList @('pull', $model) -Label "Ollama pull $model" -TimeoutSec 3600 -Quiet
        if (-not $pr.Ok) { & $mb 'Fehler' "Modell-Download fehlgeschlagen:`n$($pr.Error)" 'OK' | Out-Null; return $false }
    }
    return $true
}

function New-SysPilotAppIndex {
    <# Baut den kompletten App-Index neu. L?uft typischerweise im
       Hintergrund (Minuten: choco/scoop Vollscan + GitHub/GitLab). #>
    param([scriptblock]$OnProgress = $null, [switch]$SkipAi, [int]$MaxAiBatches = 40)
    $say = { param($m) if ($OnProgress) { $null = & $OnProgress ([string]$m) } }
    $modDir = $PSScriptRoot

    & $say 'Index: kuratierter Katalog ...'
    $rows = @(Get-SysPilotIndexFromCatalog)
    & $say "  -> $($rows.Count) Katalog-Eintraege"

    & $say 'Index: Ninite-Katalog ...'
    $rows += @(Get-SysPilotIndexFromNinite)
    & $say "  -> $($rows.Count) gesamt"

    & $say 'Index: GitHub + GitLab (stars-sortiert, kann 1-2 Minuten dauern) ...'
    $code = Get-SysPilotIndexFromCodeRepos
    foreach ($g in @($code.Github)) {
        $rows += [pscustomobject]@{
            Name=$g.Name; Desc="$(if($g.Desc){$g.Desc}else{"GitHub: $($g.Full)"}) $(if($g.Lang){"[$($g.Lang)]"})"
            Cat=''; Page=$g.Page; Github=$g.Full
            Managers=@{ github=$g.Full }
            Source='github'; Priority=60
        }
    }
    foreach ($g in @($code.Gitlab)) {
        $rows += [pscustomobject]@{
            Name=$g.Name; Desc="$(if($g.Desc){$g.Desc}else{"GitLab: $($g.Full)"})"
            Cat=''; Page=$g.Page; Github=''
            Managers=@{ gitlab=$g.Full }
            Source='gitlab'; Priority=60
        }
    }
    & $say "  -> $($rows.Count) gesamt (davon $(@($code.Github).Count) GitHub, $(@($code.Gitlab).Count) GitLab)"

    & $say 'Index: Chocolatey-Vollscan (kann 1-2 Minuten dauern) ...'
    $chocoRows = @(Get-SysPilotIndexFromChoco)
    & $say "  -> $($chocoRows.Count) choco-Pakete"
    $rows += $chocoRows

    & $say 'Index: Scoop-Buckets ...'
    $scoopRows = @(Get-SysPilotIndexFromScoop)
    & $say "  -> $($scoopRows.Count) scoop-Apps"
    $rows += $scoopRows

    & $say 'Index: Webkatalog-Portale (PortableApps-Verzeichnis) ...'
    $webRows = @(Get-SysPilotIndexFromWebPortals)
    & $say "  -> $($webRows.Count) Web-Eintraege"
    $rows += $webRows

    & $say "Index: Merge + Dedupe ($($rows.Count) Rohdaten) ..."
    $entries = @(Get-SysPilotAppIndexEntries -Rows $rows)
    $sonstigeVorher = @($entries | Where-Object { $_.Cat -eq 'Sonstige' }).Count
    if (-not $SkipAi -and $sonstigeVorher -gt 0) {
        & $say "Index: KI-Kategorisierung von $sonstigeVorher 'Sonstige'-Eintraegen (Herbert, batchweise, Cache) ..."
        $aiN = Add-SysPilotAiIndexCategories -Entries $entries -MaxBatches $MaxAiBatches
        if ($aiN -gt 0) { & $say "  -> KI sortierte $aiN Eintraege ein" }
    }
    $sonstigeNachher = @($entries | Where-Object { $_.Cat -eq 'Sonstige' }).Count
    $sources = @{
        katalog=$rows.Count; github=@($code.Github).Count; gitlab=@($code.Gitlab).Count
        choco=$chocoRows.Count; scoop=$scoopRows.Count; ninite=@($rows | Where-Object {$_.Source -eq 'ninite'}).Count
        webportal=$webRows.Count
    }
    $doc = Save-SysPilotAppIndex -Entries $entries -Sources $sources
    & $say "Index fertig: $($entries.Count) Apps in $(@($entries | ForEach-Object {$_.Cat} | Sort-Object -Unique).Count) Kategorien, Sonstige: $sonstigeNachher -> $($doc.Built)"
    return $doc
}

function Update-SysPilotAppIndex {
    <# Headless-Variante fuer die geplante Aufgabe (kein UI). #>
    param([int]$TimeoutMin = 20)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $doc = New-SysPilotAppIndex -OnProgress { param($m) Write-SysPilotLog "AppIndex: $m" }
    Write-SysPilotLog "AppIndex: $($doc.Count) Apps indexiert in $([int]$sw.Elapsed.TotalMinutes) Min"
    return $doc
}

# ---------------------------------------------------------------------
# GEPLANTER TASK (woechentlich, ueber Nacht)
# ---------------------------------------------------------------------

function Get-SysPilotAppIndexTask {
    return Get-ScheduledTask -TaskName 'SysPilot AppIndex' -ErrorAction SilentlyContinue
}

function Install-SysPilotAppIndexTask {
    <# Woechentlich Sonntag 04:00: SysPilot.ps1 -IndexUpdate (silent,
       hoechste Rechte). #>
    $exe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $scriptPath = Join-Path $script:SysPilotRoot 'SysPilot.ps1'
    $action = New-ScheduledTaskAction -Execute $exe -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" -IndexUpdate"
    $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At '04:00'
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 2)
    Register-ScheduledTask -TaskName 'SysPilot AppIndex' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-SysPilotLog 'AppIndex: geplante Aufgabe "SysPilot AppIndex" registriert (woechentlich So 04:00)'
}

function Remove-SysPilotAppIndexTask {
    Unregister-ScheduledTask -TaskName 'SysPilot AppIndex' -Confirm:$false -ErrorAction SilentlyContinue
    Write-SysPilotLog 'AppIndex: geplante Aufgabe entfernt'
}

# ---------------------------------------------------------------------
# WEBKATALOG-HARVESTER: scrapet oeffentliche App-Verzeichnisse
# ---------------------------------------------------------------------

function Get-SysPilotIndexFromWebPortals {
    <# Scraped Webkataloge zu Index-Zeilen. Derzeit:
       - PortableApps.com Kategorie-Seiten (8 Kategorien, ~1000
         portable Windows-Apps: Name, Lizenz, Kurzbeschreibung,
         Kategorie, Homepage-Link)
       Weitere Portale (Uptodown, FOSSHub, MajorGeeks) sind per
       Bot-Schutz/JS nicht zuverlaessig scrapbar - sie werden ueber
       SmartDownload/Find-SysPilotDownload on-demand abgefragt. #>
    $rows = @()
    $catMap = @{
        'accessibility'='System & Tools'; 'development'='Entwicklung'
        'education'='Sprachen & Uebungen';  'games'='Gaming'
        'internet'='Netzwerk & VPN';       'office'='Buerowerkzeuge'
        'security'='Sicherheit';           'utilities'='System & Tools'
    }
    foreach ($ck in @($catMap.Keys | Sort-Object)) {
        try {
            $r = Invoke-WebRequest "https://portableapps.com/apps/$ck" -UseBasicParsing -TimeoutSec 30 `
                -Headers @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) SysPilot Megastore' } `
                -ErrorAction Stop
            foreach ($m in [regex]::Matches($r.Content,
                '<li><img[^>]*>\s*<a href="(/apps/[^"]+)">([^<]+)</a>([^<]*)</li>')) {
                $href = [string]$m.Groups[1].Value
                $name = ([string]$m.Groups[2].Value).Trim() -replace '\s+Portable$',''
                $rest = [string]$m.Groups[3].Value
                if (-not $name -or $href -notmatch '^/apps/') { continue }
                $desc = ''
                if ($rest -match '-\s*(.+)$') { $desc = $Matches[1].Trim() }
                $desc = [System.Net.WebUtility]::HtmlDecode($desc)
                if ($desc.Length -gt 160) { $desc = $desc.Substring(0,160) + '...' }
                $d = "$desc [Windows, portabel]"
                $rows += [pscustomobject]@{
                    Name=$name; Desc=$d; Cat=[string]$catMap[$ck]
                    Page="https://portableapps.com$href"; Github=''
                    Managers=@{ web='portableapps' }
                    Source='webportal'; Priority=55
                }
            }
        } catch {}
    }
    return $rows
}

# ---------------------------------------------------------------------
# FORKS + ALTERNATIVEN (KI-Suche)
# ---------------------------------------------------------------------

function Find-SysPilotAppForks {
    <# Forks eines Index-Eintrags. Hat der Eintrag ein verknuepftes
       GitHub-Repo -> offizielle Forks-API (newest first).
       Sonst -> GitHub-Suchlink als Fallback. #>
    param([Parameter(Mandatory)]$Entry)
    $out = @()
    $gh = [string]$Entry.Github
    if ($gh -match '^([\w.-]+)/([\w.-]+)$') {
        try {
            $r = Invoke-RestMethod "https://api.github.com/repos/$gh/forks?sort=newest&per_page=15" `
                -Headers @{ 'User-Agent' = 'SysPilot Megastore'; 'Accept' = 'application/vnd.github+json' } `
                -TimeoutSec 15 -ErrorAction Stop
            foreach ($f in @($r)) {
                $out += [pscustomobject]@{
                    Name=[string]$f.full_name; Url=[string]$f.html_url
                    Desc="Fork - $([string]$f.description)"; Kind='fork'
                }
            }
        } catch {}
    }
    if ($out.Count -eq 0) {
        $q = [uri]::EscapeDataString([string]$Entry.Name)
        $out += [pscustomobject]@{
            Name='GitHub-Suche (keine Repo-Verknuepfung)'
            Url="https://github.com/search?q=$q&type=repositories"
            Desc='Repo-Suche auf GitHub'; Kind='fork'
        }
    }
    return $out
}

function Find-SysPilotAppAlternatives {
    <# Alternativen-Liste fuer einen Eintrag: 1) AlternativeTo-Suche
       (immer), 2) Herbert-KI-Suche nach konkreten Vorschlaegen. #>
    param([Parameter(Mandatory)]$Entry)
    $out = @()
    $q = [uri]::EscapeDataString([string]$Entry.Name)
    $out += [pscustomobject]@{
        Name='AlternativeTo-Suchergebnisse'; Url="https://alternativeto.net/browse/search/?q=$q"
        Desc='Kuratierte Alternatives-Datenbank'; Kind='alt'
    }
    try {
        if (-not (Get-Command Invoke-SysPilotAiChat -ErrorAction SilentlyContinue)) {
            Import-SysPilotModule -Name 'AiAssist' -ErrorAction SilentlyContinue
        }
        if (Get-Command Invoke-SysPilotAiChat -ErrorAction SilentlyContinue) {
            $desc = [string]$(if ($Entry.Desc) { $Entry.Desc } else { 'Software' })
            $prompt = "Nenne bis zu 8 kostenlose oder Open-Source-Alternativen zu '$($Entry.Name)' ($desc). Antworte NUR als Liste, eine Zeile pro Alternative im Format 'Name | https://url'. Keine Erklaerungen, keine Nummern."
            $r = Invoke-SysPilotAiChat -Prompt $prompt -System 'Du bist ein Software-Katalog-Assistent. Antworte nur mit der geforderten Liste.' -TimeoutSec 60
            if ($r -and $r.Ok -and $r.Text) {
                foreach ($l in ([string]$r.Text -split "`r?`n")) {
                    if ($l -match '^\s*[-*\d.]*\s*([^|:]+?)\s*[|:]\s*(https?://[^\s)]+)') {
                        $nm = ($Matches[1].Trim() -replace '\*','').Trim()
                        if ($nm) {
                            $out += [pscustomobject]@{
                                Name=$nm; Url=$Matches[2].Trim()
                                Desc='KI-Vorschlag'; Kind='alt'
                            }
                        }
                    }
                }
            }
        }
    } catch {}
    return $out
}

function Show-SysPilotAppRelations {
    <# Kleines Ergebnisfenster: sucht Forks oder Alternativen im
       Hintergrund (Runspace) und listet klickbare Treffer. #>
    param([Parameter(Mandatory)]$Entry, [string]$Kind = 'forks',
          [string]$Title = '', [object]$Owner = $null)
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
        Write-Warning 'Show-SysPilotAppRelations braucht STA.'
        return $false
    }
    try {
        [void][reflection.assembly]::LoadWithPartialName('PresentationFramework')
        [void][reflection.assembly]::LoadWithPartialName('PresentationCore')
        [void][reflection.assembly]::LoadWithPartialName('WindowsBase')
    } catch {}
    $kindLabel = if ($Kind -eq 'forks') { 'Forks' } else { 'Alternativen' }
    if (-not $Title) { $Title = "$kindLabel : $($Entry.Name)" }
    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$Title" Width="640" Height="520" WindowStartupLocation="CenterOwner"
        ResizeMode="CanResizeWithGrip" Background="#FF1E1E2E" Foreground="#FFEAEAF2" FontFamily="Segoe UI">
  <Window.Resources>
    <Style TargetType="Button"><Setter Property="Background" Value="#FF2D2D44"/><Setter Property="Foreground" Value="#FFEAEAF2"/><Setter Property="BorderBrush" Value="#FF4A4A6A"/><Setter Property="Padding" Value="10,4"/><Setter Property="Margin" Value="3"/><Setter Property="Cursor" Value="Hand"/></Style>
    <Style TargetType="ListBoxItem"><Setter Property="Padding" Value="6,3"/><Setter Property="Foreground" Value="#FFEAEAF2"/><Setter Property="FontSize" Value="12"/><Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#FF34344E"/></Trigger><Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#CCE4EAF2"/><Setter Property="Foreground" Value="#FF1E1E2E"/></Trigger></Style.Triggers></Style>
    <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#FFEAEAF2"/></Style>
  </Window.Resources>
  <DockPanel Margin="12">
    <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,8">
      <Button x:Name="BtnAgain" Content="Neu suchen" ToolTip="Suche erneut starten"/>
      <Button x:Name="BtnOpen" Content="Auswahl oeffnen" ToolTip="Ausgewaehlten Link im Browser oeffnen"/>
      <Button x:Name="BtnClose" Content="Schliessen" HorizontalAlignment="Right"/>
    </StackPanel>
    <StackPanel DockPanel.Dock="Bottom" Margin="0,8,0,0">
      <ProgressBar x:Name="ProgBar" Height="4" IsIndeterminate="True" Visibility="Collapsed" Foreground="#FF4FC3F7" Background="#FF2A2A3A"/>
      <TextBlock x:Name="TxtStatus" FontSize="11" Foreground="#FF9E9E9E" TextWrapping="Wrap"/>
    </StackPanel>
    <ListBox x:Name="ResultList" Background="#FF252538" BorderThickness="0"/>
  </DockPanel>
</Window>
"@
    $win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$xaml)))
    if (Test-SysPilotWindowAlreadyOpen -Key 'syspilot-app-relation' -Win $win) { return }
    if ($Owner) { $win.Owner = $Owner }
    $fc = @{}
    foreach ($n in 'BtnAgain','BtnOpen','BtnClose','ProgBar','TxtStatus','ResultList') { $fc[$n] = $win.FindName($n) }
    $setStatus = { param($t,$col) $fc.TxtStatus.Text=$t; $fc.TxtStatus.Foreground=[Windows.Media.BrushConverter]::new().ConvertFrom($col) }
    $modDir = $PSScriptRoot
    $entryJson = $Entry | ConvertTo-Json -Depth 6 -Compress

    $jobCode = @'
Import-Module (Join-Path $modDir 'Common.psm1') -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $modDir 'AppStore.psm1') -Force -ErrorAction SilentlyContinue
$q=$sdQueue
$e = $entryJson | ConvertFrom-Json
try {
  if($kind -eq 'forks'){ $links = @(Find-SysPilotAppForks -Entry $e) }
  else { $links = @(Find-SysPilotAppAlternatives -Entry $e) }
} catch { $links = @() }
$q.Enqueue('LINKS|' + ($links | ConvertTo-Json -Compress -Depth 5))
$q.Enqueue('DONE')
'@

    $rs=$null;$psx=$null;$async=$null;$q=$null
    $startSearch = {
        if($rs){return}
        $q = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
        $rs=[runspacefactory]::CreateRunspace();$rs.ApartmentState='STA';$rs.ThreadOptions='ReuseThread';$rs.Open()
        $rs.SessionStateProxy.SetVariable('modDir',$modDir)
        $rs.SessionStateProxy.SetVariable('sdQueue',$q)
        $rs.SessionStateProxy.SetVariable('entryJson',$entryJson)
        $rs.SessionStateProxy.SetVariable('kind',$Kind)
        $psx=[powershell]::Create();$psx.Runspace=$rs
        [void]$psx.AddScript($jobCode)
        $async=$psx.BeginInvoke()
        $fc.ResultList.Items.Clear()
        $fc.ProgBar.Visibility='Visible'
        & $setStatus "Suche $kindLabel fuer $($Entry.Name) ..." '#FFB0B0C0'
    }

    $poll = New-Object System.Windows.Threading.DispatcherTimer
    $poll.Interval=[timespan]::FromMilliseconds(400)
    $poll.Add_Tick({
        if(-not $q){return}
        $line=$null;$links=@();$done=$false
        while($q.TryDequeue([ref]$line)){
            if($line -match '^LINKS\|(.*)$'){ try{$links=@($Matches[1]|ConvertFrom-Json)}catch{} }
            if($line -eq 'DONE'){$done=$true}
        }
        if(-not $done){return}
        $poll.Stop()
        try{$null=@($psx.EndInvoke($async))}catch{}
        try{$psx.Dispose();$rs.Close();$rs.Dispose()}catch{}
        $rs=$null;$psx=$null;$async=$null
        $fc.ProgBar.Visibility='Collapsed'
        foreach($l in $links){
            $item = New-Object Windows.Controls.ListBoxItem
            $item.Tag = [string]$l.Url
            $item.ToolTip = [string]$l.Url
            $sp = New-Object Windows.Controls.StackPanel
            $n = New-Object Windows.Controls.TextBlock; $n.Text=[string]$l.Name; $n.FontWeight='SemiBold'; $n.FontSize='12'
            $d = New-Object Windows.Controls.TextBlock; $d.Text=[string]$l.Desc; $d.FontSize='10'
            $d.Foreground=[Windows.Media.BrushConverter]::new().ConvertFrom('#FF9E9E9E'); $d.TextTrimming='CharacterEllipsis'
            [void]$sp.Children.Add($n); [void]$sp.Children.Add($d)
            $item.Content=$sp
            $item.Add_MouseDoubleClick({ param($s,$ev) if($s.Tag){Start-Process ([string]$s.Tag)} })
            [void]$fc.ResultList.Items.Add($item)
        }
        if($links.Count -eq 0){ & $setStatus 'Keine Treffer gefunden.' '#FFFFB74D' }
        else { & $setStatus "$($links.Count) Treffer - Doppelklick oder 'Auswahl oeffnen'." '#FF81C784' }
    }.GetNewClosure())

    $openSel = { param($s,$ev)
        $it=$fc.ResultList.SelectedItem; if(-not $it -or -not $it.Tag){& $setStatus 'Bitte einen Treffer auswaehlen.' '#FFFFB74D';return}
        Start-Process ([string]$it.Tag)
    }
    $fc.BtnOpen.Add_Click($openSel)
    $fc.BtnAgain.Add_Click({ & $startSearch })
    $fc.BtnClose.Add_Click({$win.Close()})
    $win.Add_Closing({ if($poll){$poll.Stop()}; if($async){try{$psx.Stop();$psx.Dispose();$rs.Close();$rs.Dispose()}catch{}} })
    $poll.Start()
    & $startSearch
    if (Get-Command Set-SysPilotWindowAutoSize -ErrorAction SilentlyContinue) {
        Set-SysPilotWindowAutoSize -Win $win -MinWidth 560 -MinHeight 420
    }
    Add-SysPilotAssistantToWindow -Win $win -Context 'Show-SysPilotAppRelations'
    [void]$win.ShowDialog()
    return $true
}

# ---------------------------------------------------------------------
# MEGASTORE FENSTER (WPF)
# ---------------------------------------------------------------------

function Show-SysPilotAppStoreWindow {
    <# WPF-Megastore: Kategorie-Leiste + Suchfeld + Kachel-Grid mit
       Icons, Beschreibungen und Install-/Link-Buttons. Index kommt
       aus appindex.json (New-SysPilotAppIndex). #>
    param([string]$Title = 'SysPilot - App Store (Megastore)', $Owner = $null)
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
        Write-Warning 'Show-SysPilotAppStoreWindow braucht STA.'
        return $false
    }
    try {
        [void][reflection.assembly]::LoadWithPartialName('PresentationFramework')
        [void][reflection.assembly]::LoadWithPartialName('PresentationCore')
        [void][reflection.assembly]::LoadWithPartialName('WindowsBase')
        [void][reflection.assembly]::LoadWithPartialName('Windows')
    } catch {}

    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$Title" Width="1180" Height="760" WindowStartupLocation="CenterScreen"
        ResizeMode="CanResizeWithGrip" Background="#FF1E1E2E" Foreground="#FFEAEAF2" FontFamily="Segoe UI">
  <Window.Resources>
    <Style TargetType="Button"><Setter Property="Background" Value="#FF2D2D44"/><Setter Property="Foreground" Value="#FFEAEAF2"/><Setter Property="BorderBrush" Value="#FF4A4A6A"/><Setter Property="Padding" Value="10,4"/><Setter Property="Margin" Value="3"/><Setter Property="Cursor" Value="Hand"/></Style>
    <Style TargetType="ListBoxItem"><Setter Property="Padding" Value="6,3"/><Setter Property="Foreground" Value="#FFEAEAF2"/><Setter Property="FontSize" Value="12"/><Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#FF34344E"/></Trigger><Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#CCE4EAF2"/><Setter Property="Foreground" Value="#FF1E1E2E"/></Trigger></Style.Triggers></Style>
    <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#FFEAEAF2"/></Style>
    <Style TargetType="TextBox"><Setter Property="Background" Value="#FF252538"/><Setter Property="Foreground" Value="#FFEAEAF2"/><Setter Property="BorderBrush" Value="#FF4A4A6A"/><Setter Property="Padding" Value="6,4"/></Style>
    <Style TargetType="ComboBox"><Setter Property="Background" Value="#FF1E1E2E"/><Setter Property="Foreground" Value="#FFEAEAF2"/><Setter Property="BorderBrush" Value="#FF4A4A6A"/><Setter Property="Padding" Value="4,3"/></Style>
    <Style TargetType="ComboBoxItem"><Setter Property="Background" Value="#FF1E1E2E"/><Setter Property="Foreground" Value="#FFEAEAF2"/><Setter Property="Padding" Value="6,3"/><Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#FF34344E"/></Trigger><Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#CCE4EAF2"/><Setter Property="Foreground" Value="#FF1E1E2E"/></Trigger></Style.Triggers></Style>
  </Window.Resources>
  <DockPanel Margin="12">
    <StackPanel DockPanel.Dock="Top" Margin="0,0,0,8">
      <StackPanel Orientation="Horizontal" Margin="0,0,0,4">
        <TextBox x:Name="TxtSearch" Width="300" ToolTip="Suche in Name, Beschreibung, Kategorie"/>
        <ComboBox x:Name="SortBox" Width="140" Margin="6,0,0,0" VerticalAlignment="Center" ToolTip="Sortierung der Karten">
          <ComboBoxItem Content="Kategorie" IsSelected="True"/>
          <ComboBoxItem Content="Name"/>
          <ComboBoxItem Content="OS (Win/Linux/Mac)"/>
          <ComboBoxItem Content="Beliebtheit"/>
        </ComboBox>
        <Button x:Name="BtnRebuild" Content="Index neu bauen" ToolTip="Alle Quellen erneut abfragen (dauert Minuten)"/>
        <Button x:Name="BtnAiSort" Content="Herbert sortiert" ToolTip="KI-Kategorisierung: sortiert 'Sonstige'-Eintraege per Herbert (lokaler KI-Server, sonst Setup-Angebot)"/>
        <Button x:Name="BtnAutoTask" Content="Auto-Update" ToolTip="Woechentliche Aktualisierung (So 04:00) an/aus"/>
        <Button x:Name="BtnSelAll" Content="Alle" ToolTip="Alle sichtbaren Karten per Haekchen vormerken"/>
        <Button x:Name="BtnSelNone" Content="Keine" ToolTip="Alle Haekchen entfernen"/>
        <Button x:Name="BtnSelInstall" Content="Auswahl installieren" ToolTip="Abgehakte Apps per Paketmanager nacheinander installieren (Mehrfachauswahl per Haekchen)"/>
        <TextBlock x:Name="TxtSelCount" Text="Auswahl: 0" VerticalAlignment="Center" Foreground="#FF4FC3F7" FontWeight="Bold" Margin="10,0,0,0"/>
        <Button x:Name="BtnClose" Content="Schliessen" HorizontalAlignment="Right"/>
      </StackPanel>
      <StackPanel Orientation="Horizontal" Margin="0,0,0,0">
        <TextBlock Text="System:" VerticalAlignment="Center" Foreground="#FF9E9E9E" FontSize="11" Margin="0,0,6,0"/>
        <CheckBox x:Name="ChkWin" Content="Windows" IsChecked="True" VerticalAlignment="Center" Margin="0,0,10,0" Foreground="#FFEAEAF2"/>
        <CheckBox x:Name="ChkLinux" Content="Linux" IsChecked="True" VerticalAlignment="Center" Margin="0,0,10,0" Foreground="#FFEAEAF2"/>
        <CheckBox x:Name="ChkMac" Content="Mac" IsChecked="True" VerticalAlignment="Center" Margin="0,0,10,0" Foreground="#FFEAEAF2"/>
        <TextBlock x:Name="TxtPlatHint" Text="(alle = kein Filter)" VerticalAlignment="Center" Foreground="#FF6E6E85" FontSize="10"/>
      </StackPanel>
    </StackPanel>
    <Border DockPanel.Dock="Bottom" Background="#FF16161F" BorderBrush="#FF4A4A6A" BorderThickness="0,1,0,0" Padding="8,6">
      <StackPanel>
        <ProgressBar x:Name="ProgBar" Height="4" IsIndeterminate="False" Minimum="0" Maximum="100" Value="0" Visibility="Collapsed" Margin="0,0,0,6" Foreground="#FF4FC3F7" Background="#FF2A2A3A"/>
        <TextBox x:Name="LogBox" Height="80" IsReadOnly="True" TextWrapping="NoWrap" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="11" Background="#FF0C0C14" Foreground="#FF9FE89F" BorderThickness="0" ToolTip="Live-Protokoll"/>
        <TextBlock x:Name="TxtStatus" FontSize="11" Foreground="#FF9E9E9E" Margin="0,5,0,0" TextWrapping="Wrap"/>
      </StackPanel>
    </Border>
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="190"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <Border Background="#FF252538" CornerRadius="6" Margin="0,0,10,0">
        <DockPanel>
          <TextBlock DockPanel.Dock="Top" Text="Kategorien" FontWeight="Bold" Foreground="#FF4FC3F7" Margin="10,10,10,6" FontSize="13"/>
          <ListBox x:Name="CatList" Background="Transparent" BorderThickness="0" Margin="6" DisplayMemberPath="Label"/>
        </DockPanel>
      </Border>
      <Border Grid.Column="1" Background="#FF1A1A26" CornerRadius="6" Padding="10">
        <ScrollViewer x:Name="StoreScroll" VerticalScrollBarVisibility="Auto">
          <WrapPanel x:Name="CardPanel"/>
        </ScrollViewer>
      </Border>
    </Grid>
  </DockPanel>
</Window>
"@
    $win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$xaml)))
    if (Test-SysPilotWindowAlreadyOpen -Key 'syspilot-appstore' -Win $win) { return }
    if ($Owner) { $win.Owner=$Owner } else { $win.WindowStartupLocation='CenterScreen' }
    $fc = @{}
    foreach ($n in 'TxtSearch','SortBox','BtnRebuild','BtnAiSort','BtnAutoTask','BtnSelAll','BtnSelNone','BtnSelInstall','TxtSelCount','BtnClose','ProgBar','LogBox','TxtStatus','CatList','CardPanel','StoreScroll','ChkWin','ChkLinux','ChkMac') {
        $fc[$n] = $win.FindName($n)
    }
    $setStatus = { param($t,$col) $fc.TxtStatus.Text=$t; $fc.TxtStatus.Foreground=[Windows.Media.BrushConverter]::new().ConvertFrom($col) }
    $modDir = $PSScriptRoot
    $fc._stQueue = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
    $fc._stProcPath=''; $fc._stProcOffset=0L
    $fc._stBusy=$false
    $fc._stPending = New-Object 'System.Collections.Generic.Queue[object]'
    $fc._stProgGoal=0; $fc._stCurLabel=$null; $fc._stJobT0=$null
    $fc._stEntries = @()
    $fc._stSel = @{}   # key -> Entry (Haekchen-Auswahl, bleibt ueber Filter hinweg)

    $sayLog = {
        param([string]$line)
        if(-not $line){return}
        # Fortschritts-Marker vom Job: ::PROG|idx/total|Art|name
        # (name leer = Schritt abgeschlossen)
        if ($line -match '::PROG\|(\d+)/(\d+)\|([^|]*)\|(.*)$') {
            $pIdx=[int]$Matches[1]; $pTot=[int]$Matches[2]; $pKind=$Matches[3]; $pNm=$Matches[4].Trim()
            if ($pNm.Length -gt 60) { $pNm = $pNm.Substring(0,60) + '...' }
            $fc.ProgBar.IsIndeterminate=$false; $fc.ProgBar.Visibility='Visible'
            $fc.ProgBar.Minimum=0; $fc.ProgBar.Maximum=$pTot
            $isStart = ($pNm -ne '')
            $floor = $(if($isStart){[Math]::Max(0,$pIdx-1)}else{$pIdx})
            $fc.ProgBar.Value = $floor
            $fc._stProgGoal = $pIdx
            $fc._stCurLabel = $(if($pNm){"$pKind $pIdx/$pTot`: $pNm"}else{"$pKind $pIdx/$pTot"})
            if ($pNm) { $fc.TxtStatus.Text=$fc._stCurLabel; $fc.TxtStatus.Foreground=[Windows.Media.BrushConverter]::new().ConvertFrom('#FFB0B0C0') }
            return
        }
        Write-SysPilotPanelLog $line
        $fc.LogBox.AppendText($line + "`n")
        try{$fc.LogBox.ScrollToEnd()}catch{}
        if($fc.LogBox.Text.Length -gt 80000){$fc.LogBox.Text=$fc.LogBox.Text.Substring($fc.LogBox.Text.Length-40000)}
    }
    $tailProc = {
        try {
            $logs = Get-ChildItem (Join-Path $env:TEMP 'syspilot-proc-*.log') -File -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -gt (Get-Date).AddSeconds(-30) } |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if(-not $logs){return}
            if($logs.FullName -ne $fc._stProcPath){$fc._stProcPath=$logs.FullName;$fc._stProcOffset=0L}
            $len=$logs.Length; if($len -le $fc._stProcOffset){return}
            $fs=[IO.File]::Open($logs.FullName,'Open','Read','ReadWrite')
            try{$fs.Seek($fc._stProcOffset,'Begin')|Out-Null;$sr=New-Object IO.StreamReader($fs);$chunk=$sr.ReadToEnd()}finally{$fs.Close()}
            $fc._stProcOffset=$len
            foreach($l in ($chunk -split "`r?`n")){ & $sayLog $l }
        } catch {}
    }
    $drainQ = {
        $line=$null
        while($fc._stQueue.TryDequeue([ref]$line)){ if($line){& $sayLog ">> $line"}; $line=$null }
        & $tailProc
    }

    # Index laden + Kategorien fuellen
    $loadIndex = {
        $idx = Get-SysPilotAppIndex
        $fc._stEntries = @($idx.Entries)
        $counts = @{}
        foreach($e in $fc._stEntries){ $counts[$e.Cat] = [int]$counts[$e.Cat] + 1 }
        $fc.CatList.Items.Clear()
        [void]$fc.CatList.Items.Add([pscustomobject]@{Label="Alle ($($fc._stEntries.Count))";Cat='';Tag='all'})
        foreach($c in @($script:AppStoreCats | Sort-Object Name)) {
            $n = [int]$counts[$c.Id]
            if($n -gt 0){ [void]$fc.CatList.Items.Add([pscustomobject]@{Label="$($c.Name) ($n)";Cat=$c.Id;Tag=$c.Id}) }
        }
        # Kategorien aus dem Index, die nicht in AppStoreCats stehen
        # (z.B. eigene Katalog-Kategorien wie 'Produktivitaet')
        $known = @{}; foreach($c in $script:AppStoreCats){ $known[$c.Id] = $true }
        foreach($k in @($counts.Keys | Where-Object { $_ -and -not $known.ContainsKey($_) } | Sort-Object)) {
            [void]$fc.CatList.Items.Add([pscustomobject]@{Label="$k ($($counts[$k]))";Cat=$k;Tag=$k})
        }
        if($idx.Built){ & $setStatus "Index: $($idx.Count) Apps, gebaut $($idx.Built)." '#FF9E9E9E' }
        else { & $setStatus 'Kein Index vorhanden - "Index neu bauen" starten.' '#FFFFB74D' }
        & $renderCards
    }

    # Karte bauen (Border + Icon + Name + Badges + Desc + Buttons)
    $mgrPrio = @('winget','chocolatey','scoop','npm','pip','dotnet','psgallery')

    # Plattform-Schaetzung: @($win,$lin,$mac); unbekannt = alle drei
    $platCache = @{}
    $getPlat = {
        param($e)
        $key = "$($e.Name)|$(@($e.Sources) -join ',')"
        if($platCache.ContainsKey($key)){return $platCache[$key]}
        $hay = "$($e.Name) $($e.Desc) $($e.Page) $($e.Github)".ToLower()
        $win=$false;$lin=$false;$mac=$false
        foreach($mk in @('winget','chocolatey','scoop')){ if($e.Managers.ContainsKey($mk)){$win=$true} }
        if($hay -match '\bwindows\b|\bwin32\b|\bwin64\b|\bmsi\b|\.exe\b|\.net\b|\bwinforms\b|\bwpf\b|\buwp\b'){ $win=$true }
        if($hay -match '\blinux\b|\bgnu\b|\bunix\b|\bgtk\b|\bqt\b|\bx11\b|\bxorg\b|\bwayland\b|\bubuntu\b|\bdebian\b|\bfedora\b|\barch linux\b|\bmanjaro\b|\balpine\b|\btermux\b|\bflatpak\b|\bsnap package\b|\bappimage\b|\bdeb\b|\brpm\b|\bdnf\b|\bpacman\b|\bapt-get\b|\byum\b|\bzypper\b'){ $lin=$true }
        if($hay -match '\bmacos\b|\bosx\b|\bdarwin\b|\bcocoa\b|\biphone\b'){ $mac=$true }
        if(-not $win -and -not $lin -and -not $mac){ $win=$true;$lin=$true;$mac=$true }
        $platCache[$key]=@($win,$lin,$mac)
        return $platCache[$key]
    }
    $platBadges = {
        param($p)
        $s=''
        if($p[0]){$s+=' Win'}
        if($p[1]){$s+=' Linux'}
        if($p[2]){$s+=' Mac'}
        return $s.Trim()
    }

    # Info-Popup: volle Beschreibung, Manager, Plattform, Aktionen
    $showInfo = {
        param($e)
        $p = & $getPlat $e
        $w = New-Object Windows.Window
        $w.Title = "Info: $($e.Name)"; $w.Width=560; $w.Height=480
        $w.WindowStartupLocation='CenterOwner'; if($win.Owner){$w.Owner=$win}
        $w.Background=[Windows.Media.BrushConverter]::new().ConvertFrom('#FF1E1E2E')
        $w.Foreground=[Windows.Media.BrushConverter]::new().ConvertFrom('#FFEAEAF2')
        $w.FontFamily='Segoe UI'
        $sp = New-Object Windows.Controls.StackPanel; $sp.Margin='16'
        $h = New-Object Windows.Controls.TextBlock
        $h.Text=[string]$e.Name; $h.FontSize=18; $h.FontWeight='Bold'; $h.TextWrapping='Wrap'
        $sp.Children.Add($h) | Out-Null
        $meta = New-Object Windows.Controls.TextBlock
        $srcs = @($e.ManagerList) -join ', '
        $meta.Text = "Kategorie: $($e.Cat)   |   Quellen: $srcs   |   System: $((& $platBadges $p))"
        $meta.FontSize=11; $meta.Foreground=[Windows.Media.BrushConverter]::new().ConvertFrom('#FF4FC3F7')
        $meta.Margin='0,4,0,8'; $meta.TextWrapping='Wrap'
        $sp.Children.Add($meta) | Out-Null
        $d = New-Object Windows.Controls.TextBlock
        $d.Text = [string]$(if($e.Desc){$e.Desc}else{'(keine Beschreibung im Index)'})
        $d.FontSize=12; $d.TextWrapping='Wrap'; $d.Margin='0,0,0,10'
        $sp.Foreground=[Windows.Media.BrushConverter]::new().ConvertFrom('#FFB0B0C0')
        $sv = New-Object Windows.Controls.ScrollViewer; $sv.VerticalScrollBarVisibility='Auto'; $sv.Content=$d
        $sp.Children.Add($sv) | Out-Null
        $btns = New-Object Windows.Controls.StackPanel; $btns.Orientation='Horizontal'; $btns.Margin='0,12,0,0'
        $bClose = New-Object Windows.Controls.Button; $bClose.Content='Schliessen'; $bClose.Padding='14,5'
        $bClose.Add_Click({$w.Close()}); [void]$btns.Children.Add($bClose)
        $url = [string]$(if($e.Page){$e.Page}else{''})
        if($url){
            $bOpen = New-Object Windows.Controls.Button; $bOpen.Content='Seite oeffnen'; $bOpen.Padding='14,5'; $bOpen.Margin='6,0,0,0'
            $bOpen.Tag=$url; $bOpen.Add_Click({param($s,$ev) Start-Process ([string]$s.Tag)})
            [void]$btns.Children.Add($bOpen)
        }
        $bDl = New-Object Windows.Controls.Button; $bDl.Content='SmartDownload'; $bDl.Padding='14,5'; $bDl.Margin='6,0,0,0'
        $bDl.ToolTip='Download-Link suchen (PM + Kataloge + GitHub/GitLab + Web + Herbert)'
        $bDl.Tag=$e; $bDl.Add_Click({
            param($s,$ev)
            try {
                if(-not (Get-Command Show-SysPilotDownloadFinder -ErrorAction SilentlyContinue)){ Import-SysPilotModule -Name 'SmartDownload' -ErrorAction SilentlyContinue }
                if(Get-Command Show-SysPilotDownloadFinder -ErrorAction SilentlyContinue){
                    Show-SysPilotDownloadFinder -AppName ([string]$s.Tag.Name) -Owner $w -Title "SmartDownload: $($s.Tag.Name)"
                }
            } catch {}
        })
        [void]$btns.Children.Add($bDl)
        $bAi = New-Object Windows.Controls.Button; $bAi.Content='KI-Hilfe'; $bAi.Padding='14,5'; $bAi.Margin='6,0,0,0'
        $bAi.ToolTip='Herbert Install-Assistent: Paketmanager-IDs, Konsolenbefehle oder Download-Links vorschlagen'
        $bAi.Tag=$e; $bAi.Add_Click({
            param($s,$ev)
            try {
                if(-not (Get-Command Show-SysPilotInstallAssistWindow -ErrorAction SilentlyContinue)){ Import-SysPilotModule -Name 'SmartDownload' -ErrorAction SilentlyContinue }
                if(Get-Command Show-SysPilotInstallAssistWindow -ErrorAction SilentlyContinue){
                    Show-SysPilotInstallAssistWindow -AppName ([string]$s.Tag.Name) -PageUrl ([string]$s.Tag.Page) -Owner $w -Title "Install-Hilfe: $($s.Tag.Name)"
                }
            } catch {}
        })
        [void]$btns.Children.Add($bAi)
        $bFork = New-Object Windows.Controls.Button; $bFork.Content='Forks'; $bFork.Padding='14,5'; $bFork.Margin='6,0,0,0'
        $bFork.ToolTip='Forks/Varianten suchen: GitHub-Forks-API wenn Repo verknuepft, sonst GitHub-Suche'
        $bFork.Tag=$e; $bFork.Add_Click({
            param($s,$ev)
            Show-SysPilotAppRelations -Entry $s.Tag -Kind forks -Owner $w -Title "Forks: $($s.Tag.Name)"
        })
        [void]$btns.Children.Add($bFork)
        $bAlt = New-Object Windows.Controls.Button; $bAlt.Content='Alternativen'; $bAlt.Padding='14,5'; $bAlt.Margin='6,0,0,0'
        $bAlt.ToolTip='KI-Suche (Herbert) + AlternativeTo nach Alternativen zu dieser App'
        $bAlt.Tag=$e; $bAlt.Add_Click({
            param($s,$ev)
            Show-SysPilotAppRelations -Entry $s.Tag -Kind alt -Owner $w -Title "Alternativen: $($s.Tag.Name)"
        })
        [void]$btns.Children.Add($bAlt)
        $sp.Children.Add($btns) | Out-Null
        $w.Content=$sp
        [void]$w.ShowDialog()
    }

    # SmartDownload-Button auf der Karte (wenn kein PM-Install)
    $dlClick = {
        param($s,$ev)
        $e = $s.Tag
        try {
            if(-not (Get-Command Show-SysPilotDownloadFinder -ErrorAction SilentlyContinue)){ Import-SysPilotModule -Name 'SmartDownload' -ErrorAction SilentlyContinue }
            if(Get-Command Show-SysPilotDownloadFinder -ErrorAction SilentlyContinue){
                Show-SysPilotDownloadFinder -AppName ([string]$e.Name) -Owner $win -Title "SmartDownload: $($e.Name)"
            } else { & $setStatus 'SmartDownload-Modul nicht verfuegbar.' '#FFFFB74D' }
        } catch { & $setStatus "DL: $($_.Exception.Message)" '#FFFF5252' }
    }

    # Haekchen-Auswahl: stabiler Schluessel pro Eintrag (Name+Kat+Page),
    # Wert = der Entry selbst (fuer Batch-Install)
    $selKey = { param($e) "$($e.Name)|$($e.Cat)|$([string]$e.Page)" }
    $updSelCount = {
        $fc.TxtSelCount.Text = "Auswahl: $(@($fc._stSel.Keys).Count)"
    }

    $renderCards = {
        $fc.CardPanel.Children.Clear()
        $cat = [string]$fc.CatList.SelectedItem.Cat
        if(-not $cat){$cat=''}
        $q = $fc.TxtSearch.Text.Trim().ToLower()
        $wantWin = ($fc.ChkWin.IsChecked -eq $true); $wantLin = ($fc.ChkLinux.IsChecked -eq $true); $wantMac = ($fc.ChkMac.IsChecked -eq $true)
        $osFilter = ($wantWin -or $wantLin -or $wantMac) -and -not ($wantWin -and $wantLin -and $wantMac)
        $shown = 0; $max = 240
        $sortMode = ''
        try { $sortMode = [string]$fc.SortBox.SelectedItem.Content } catch {}
        $src = @($fc._stEntries)
        if ($sortMode -eq 'Name') { $src = @($src | Sort-Object Name) }
        elseif ($sortMode -eq 'OS (Win/Linux/Mac)') {
            $src = @($src | Sort-Object { param($x) $p = & $getPlat $x; if($p[0]){0}elseif($p[1]){1}elseif($p[2]){2}else{3} }, Name)
        }
        elseif ($sortMode -eq 'Beliebtheit') { $src = @($src | Sort-Object @{e={-[int]$_.Score}}, Name) }
        else { $src = @($src | Sort-Object Cat, Name) }
        foreach($e in $src){
            if($shown -ge $max){break}
            if($cat -and $cat -ne '' -and $e.Cat -ne $cat){continue}
            if($osFilter){
                $p = & $getPlat $e
                if(-not (($wantWin -and $p[0]) -or ($wantLin -and $p[1]) -or ($wantMac -and $p[2]))){continue}
            }
            if($q){
                $hay = "$($e.Name) $($e.Desc) $($e.Cat) $($e.ManagerList -join ' ')".ToLower()
                if($hay -notmatch [regex]::Escape($q)){continue}
            }
            $shown++
            # Card-Rahmen
            $card = New-Object Windows.Controls.Border
            $card.Width=200; $card.Height=150; $card.Margin='0,0,10,10'
            $card.Background=[Windows.Media.BrushConverter]::new().ConvertFrom('#FF252538')
            $card.BorderBrush=[Windows.Media.BrushConverter]::new().ConvertFrom('#FF3A3A55')
            $card.BorderThickness='1'; $card.CornerRadius='6'; $card.Padding='8'
            $sp = New-Object Windows.Controls.StackPanel
            # Kopf: Haekchen (Batch-Auswahl) + Icon + Name
            $head = New-Object Windows.Controls.DockPanel
            $chk = New-Object Windows.Controls.CheckBox
            $chk.SetValue([Windows.Controls.DockPanel]::DockProperty,[Windows.Controls.Dock]::Right); $chk.VerticalAlignment='Top'; $chk.Margin='0,0,4,0'
            $chk.ToolTip='Fuer Batch-Installation vormerken'
            $selK = & $selKey $e
            $chk.IsChecked = $fc._stSel.ContainsKey($selK)
            $chk.Tag = $e
            $chk.Add_Checked({ param($s,$ev) $k=& $selKey $s.Tag; $fc._stSel[$k]=$s.Tag; & $updSelCount })
            $chk.Add_Unchecked({ param($s,$ev) $k=& $selKey $s.Tag; $fc._stSel.Remove($k)|Out-Null; & $updSelCount })
            [void]$head.Children.Add($chk)
            $img = New-Object Windows.Controls.Image
            $img.Width=26; $img.Height=26; $img.Margin='0,0,8,0'; $img.VerticalAlignment='Top'
            if($e.Icon){ try{$img.Source=[Windows.Media.Imaging.BitmapImage]::new([Uri]$e.Icon)}catch{} }
            [void]$head.Children.Add($img)
            $tb = New-Object Windows.Controls.TextBlock
            $tb.Text=[string]$e.Name; $tb.FontWeight='SemiBold'; $tb.FontSize='12'
            $tb.TextTrimming='CharacterEllipsis'; $tb.ToolTip=[string]$e.Name
            $tb.VerticalAlignment='Top'; $tb.TextWrapping='Wrap'; $tb.MaxHeight=34
            [void]$head.Children.Add($tb)
            # Badges: verfuegbare Manager + Plattform
            $badges=''
            foreach($mk in @($mgrPrio)){ if($e.Managers.ContainsKey($mk)){$badges += " $mk"} }
            foreach($mk in @('github','gitlab','ninite','majorgeeks','web')){ if($e.Managers.ContainsKey($mk)){$badges += " $mk"} }
            if($badges){
                $bb = New-Object Windows.Controls.TextBlock
                $bb.Text=$badges.Trim(); $bb.FontSize='9'; $bb.Foreground=[Windows.Media.BrushConverter]::new().ConvertFrom('#FF4FC3F7')
                $bb.Margin='0,2,0,0'; $bb.TextTrimming='CharacterEllipsis'
                $sp.Children.Add($bb) | Out-Null
            }
            $pb = New-Object Windows.Controls.TextBlock
            $pb.Text = "OS: $((& $platBadges (& $getPlat $e)))"; $pb.FontSize='9'
            $pb.Foreground=[Windows.Media.BrushConverter]::new().ConvertFrom('#FF9CCC65')
            $pb.Margin='0,1,0,0'; $pb.TextTrimming='CharacterEllipsis'
            $sp.Children.Add($pb) | Out-Null
            # Beschreibung (2 Zeilen)
            $desc=[string]$e.Desc
            if($desc.Length -gt 90){$desc=$desc.Substring(0,90)+'...'}
            $db = New-Object Windows.Controls.TextBlock
            $db.Text=$desc; $db.FontSize='10'; $db.Foreground=[Windows.Media.BrushConverter]::new().ConvertFrom('#FFB0B0C0')
            $db.TextWrapping='Wrap'; $db.MaxHeight=30; $db.Margin='0,3,0,0'
            $sp.Children.Add($db) | Out-Null
            # Buttons Zeile 1: Install (PM) oder SmartDownload
            $btns = New-Object Windows.Controls.StackPanel
            $btns.Orientation='Horizontal'; $btns.Margin='0,6,0,0'
            $instMgr=''
            foreach($mk in $mgrPrio){ if($e.Managers.ContainsKey($mk) -and $mk -ne 'web'){$instMgr=$mk;break} }
            if($instMgr){
                $b1 = New-Object Windows.Controls.Button
                $b1.Content="Install ($instMgr)"; $b1.FontSize='10'; $b1.Padding='8,2'; $b1.Margin='0'
                $b1.Tag = [pscustomobject]@{Entry=$e;Mgr=$instMgr;Id=[string]$e.Managers[$instMgr]}
                $b1.Add_Click($installClick)
                [void]$btns.Children.Add($b1)
            } else {
                $b1 = New-Object Windows.Controls.Button
                $b1.Content='DL suchen'; $b1.FontSize='10'; $b1.Padding='8,2'; $b1.Margin='0'
                $b1.ToolTip='SmartDownload: Download-Link in PMs, Katalogen, GitHub/GitLab, Web + Herbert suchen'
                $b1.Tag = $e
                $b1.Add_Click($dlClick)
                [void]$btns.Children.Add($b1)
            }
            # Buttons Zeile 2: Info + Oeffnen
            $btns2 = New-Object Windows.Controls.StackPanel
            $btns2.Orientation='Horizontal'; $btns2.Margin='0,3,0,0'
            $bInfo = New-Object Windows.Controls.Button
            $bInfo.Content='Info'; $bInfo.FontSize='10'; $bInfo.Padding='10,2'; $bInfo.Margin='0'
            $bInfo.ToolTip='Details: volle Beschreibung, Quellen, Plattform'
            $bInfo.Tag = $e
            $bInfo.Add_Click({ param($s,$ev) & $showInfo $s.Tag })
            [void]$btns2.Children.Add($bInfo)
            $url = [string]$(if($e.Page){$e.Page}else{''})
            if($url){
                $b2 = New-Object Windows.Controls.Button
                $b2.Content='Oeffnen'; $b2.FontSize='10'; $b2.Padding='10,2'; $b2.Margin='4,0,0,0'
                $b2.Tag = $url
                $b2.Add_Click({ param($s,$ev) Start-Process ([string]$s.Tag) })
                [void]$btns2.Children.Add($b2)
            }
            $sp.Children.Add($btns) | Out-Null
            $sp.Children.Add($btns2) | Out-Null
            $card.Child=$sp
            $card.Tag=$e
            # Kopf zuerst oben (DockPanel in StackPanel)
            $sp.Children.Insert(0,$head)
            [void]$fc.CardPanel.Children.Add($card)
        }
        if($shown -eq 0){
            $tb = New-Object Windows.Controls.TextBlock
            $tb.Text='Keine Treffer - Index neu bauen oder anderen Suchbegriff.'
            $tb.Foreground=[Windows.Media.BrushConverter]::new().ConvertFrom('#FF9E9E9E')
            $tb.Margin='10'; $tb.FontSize='13'
            [void]$fc.CardPanel.Children.Add($tb)
        }
        elseif($shown -ge $max){
            $tb = New-Object Windows.Controls.TextBlock
            $tb.Text="... und weitere Treffer (max. $max angezeigt - Suchbegriff praezisieren)"
            $tb.Foreground=[Windows.Media.BrushConverter]::new().ConvertFrom('#FF9E9E9E')
            $tb.Margin='10'; $tb.FontSize='11'
            [void]$fc.CardPanel.Children.Add($tb)
        }
    }

    # Install-Handler (runspace)
    $fc._stRs=$null;$fc._stPs=$null;$fc._stAsync=$null
    $installCode = @'
Import-Module (Join-Path $modDir 'Common.psm1') -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $modDir 'PackageManagers.psm1') -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $modDir 'SoftwareUpdateCenter.psm1') -Force -ErrorAction SilentlyContinue
$q=$sdQueue
$say={param($m) if($q){$q.Enqueue([string]$m)}}
$q.Enqueue('::PROG|1/1|Install|' + $instName)
& $say "Installiere $instMgr : $instId ..."
$r = Install-SysPilotPmPackage -Manager $instMgr -Id $instId
if($r.Ok){& $say "[OK] $instName installiert ($instMgr)"}else{
  & $say "[FAIL] $instName : $($r.Error)"
  & $say 'Herbert Auto-Fix: analysiere Fehler und versucht Loesung ...'
  try {
    Import-Module (Join-Path $modDir 'SmartDownload.psm1') -Force -ErrorAction SilentlyContinue
    if(Get-Command Invoke-SysPilotAutoInstallFix -ErrorAction SilentlyContinue){
      $fix = Invoke-SysPilotAutoInstallFix -AppName $instName -AppId $instId -FailedManager $instMgr -ErrorText ([string]$r.Error) -OnProgress $say
      if($fix.Ok){& $say "[OK] Auto-Fix erfolgreich: $($fix.Detail)"}else{& $say "[MANUELL] $($fix.Detail)"}
    }
  } catch { & $say "Auto-Fix Fehler: $($_.Exception.Message)" }
}
$q.Enqueue('::PROG|1/1|Install|')
'@
    # ===== Job-Warteschlange =====
    # Aktionen waehrend eines laufenden Jobs werden eingereiht
    # (Label+Code+Vars werden beim Klick aufgeloest). Der Poll-Timer
    # startet bei freiem _stBusy den naechsten Eintrag.
    $stEnqueue = {
        param([string]$label, [string]$code, [hashtable]$vars, [string]$status)
        foreach($it in $fc._stPending){ if($it.Label -eq $label){ & $setStatus "Bereits in Warteschlange: $label" '#FFFFB74D'; return } }
        $item=[pscustomobject]@{Label=$label;Code=$code;Vars=$vars;Status=$status}
        if($fc._stBusy){
            $fc._stPending.Enqueue($item)
            & $sayLog ">> Warteschlange ($($fc._stPending.Count)): $label"
            & $setStatus "Warteschlange: $($fc._stPending.Count) Aktion(en) - '$label' wartet." '#FFFFB74D'
            return
        }
        & $stPumpItem $item
    }
    $stPumpItem = {
        param($item)
        & $sayLog "--- $($item.Label) ---"
        $fc._stBusy=$true
        $fc._stQueue = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
        $fc.LogBox.Clear()
        $fc._stRs=[runspacefactory]::CreateRunspace();$fc._stRs.ApartmentState='STA';$fc._stRs.ThreadOptions='ReuseThread';$fc._stRs.Open()
        $fc._stRs.SessionStateProxy.SetVariable('modDir',$modDir)
        $fc._stRs.SessionStateProxy.SetVariable('sdQueue',$fc._stQueue)
        foreach($kv in $item.Vars.GetEnumerator()){ $fc._stRs.SessionStateProxy.SetVariable($kv.Key,$kv.Value) }
        $fc._stPs=[powershell]::Create();$fc._stPs.Runspace=$fc._stRs
        [void]$fc._stPs.AddScript($item.Code)
        $fc._stAsync=$fc._stPs.BeginInvoke()
        $fc._stJobT0=Get-Date;$fc._stCurLabel=$null;$fc._stProgGoal=0
        $fc.ProgBar.Visibility='Visible';$fc.ProgBar.IsIndeterminate=$true
        if($item.Status){ & $setStatus ([string]$item.Status) '#FFB0B0C0' }
    }
    $installClick = {
        param($s,$ev)
        $d = $s.Tag
        $e=$d.Entry
        $r=[System.Windows.MessageBox]::Show("$($e.Name)`nManager: $($d.Mgr)`nID: $($d.Id)`n`nInstallieren?",'App Store','YesNo','Question')
        if($r -ne 'Yes'){return}
        & $stEnqueue "Install: $($e.Name) ($($d.Mgr))" $installCode @{ instMgr=$d.Mgr; instId=$d.Id; instName=[string]$e.Name } "Installiere $($d.Mgr) : $($d.Id) ..."
    }

    # Index-Rebuild-Job
    $rebuildCode = @'
Import-Module (Join-Path $modDir 'Common.psm1') -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $modDir 'AppStore.psm1') -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $modDir 'SoftwareUpdateCenter.psm1') -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $modDir 'PortableTools.psm1') -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $modDir 'PackageManagers.psm1') -Force -ErrorAction SilentlyContinue
$q=$sdQueue
$say={param($m) if($q){$q.Enqueue([string]$m)}}
$script:_rpi=0
$sayp={ param($m) if($m -match '^Index:'){ $script:_rpi++; if($q){$q.Enqueue("::PROG|$($script:_rpi)/8|Index|$($m -replace '^Index:\s*','')")} }; & $say $m }
$doc = New-SysPilotAppIndex -OnProgress $sayp
$q.Enqueue('::PROG|8/8|Index|')
$q.Enqueue("INDEX_DONE|$($doc.Count)|$($doc.Built)")
'@
    $startRebuild = {
        & $stEnqueue 'Index-Rebuild' $rebuildCode @{} 'Index wird neu gebaut (dauert einige Minuten) ...'
    }

    # KI-Sort-Job: 'Sonstige'-Eintraege per Herbert klassifizieren,
    # Index bleibt erhalten (nur Cat-Felder + Cache werden aktualisiert)
    $aiSortCode = @'
Import-Module (Join-Path $modDir 'Common.psm1') -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $modDir 'AppStore.psm1') -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $modDir 'AiAssist.psm1') -Force -ErrorAction SilentlyContinue
$q=$sdQueue
$say={param($m) if($q){$q.Enqueue([string]$m)}}
$r = Update-SysPilotIndexSonstige -MaxBatches 60 -OnProgress $say
$q.Enqueue("AI_SORT_DONE|$($r.Changed)|$($r.Before)|$($r.Rest)|$($r.Ok)")
'@
    $startAiSort = {
        & $stEnqueue 'KI-Sortierung' $aiSortCode @{} 'Herbert sortiert Sonstige-Eintraege ...'
    }

    # Batch-Install-Job: alle abgehakten Karten nacheinander per PM
    $batchCode = @'
Import-Module (Join-Path $modDir 'Common.psm1') -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $modDir 'PackageManagers.psm1') -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $modDir 'SoftwareUpdateCenter.psm1') -Force -ErrorAction SilentlyContinue
$q=$sdQueue
$say={param($m) if($q){$q.Enqueue([string]$m)}}
$tot=@($instList).Count;$i=0
foreach($it in $instList){
  $i++
  $q.Enqueue('::PROG|'+$i+'/'+$tot+'|Install|'+[string]$it.Name)
  & $say "Installiere $($it.Mgr) : $($it.Id) ($($it.Name)) ..."
  $r = Install-SysPilotPmPackage -Manager $it.Mgr -Id $it.Id
  if($r.Ok){& $say "[OK] $($it.Name) ($($it.Mgr))"}else{
    & $say "[FAIL] $($it.Name) : $($r.Error)"
    try {
      Import-Module (Join-Path $modDir 'SmartDownload.psm1') -Force -ErrorAction SilentlyContinue
      if(Get-Command Invoke-SysPilotAutoInstallFix -ErrorAction SilentlyContinue){
        $fix = Invoke-SysPilotAutoInstallFix -AppName $it.Name -AppId $it.Id -FailedManager $it.Mgr -ErrorText ([string]$r.Error) -OnProgress $say
        if($fix.Ok){& $say "[OK] Auto-Fix: $($fix.Detail)"}else{& $say "[MANUELL] $($fix.Detail)"}
      }
    } catch { & $say "Auto-Fix Fehler: $($_.Exception.Message)" }
  }
}
$q.Enqueue('::PROG|'+$tot+'/'+$tot+'|Install|')
'@

    $fc.BtnSelAll.Add_Click({
        foreach($c in @($fc.CardPanel.Children)){ if($c.Tag){ $fc._stSel[(& $selKey $c.Tag)] = $c.Tag } }
        & $updSelCount; & $renderCards
    })
    $fc.BtnSelNone.Add_Click({
        foreach($c in @($fc.CardPanel.Children)){ if($c.Tag){ $fc._stSel.Remove((& $selKey $c.Tag)) | Out-Null } }
        & $updSelCount; & $renderCards
    })
    $fc.BtnSelInstall.Add_Click({
        $entries = @($fc._stSel.Values)
        if($entries.Count -eq 0){& $setStatus 'Keine Karten abgehakt - bitte zuerst per Haekchen vormerken.' '#FFFFB74D';return}
        $instList=@(); $skip=@()
        foreach($e in $entries){
            $mgr=''
            foreach($mk in $mgrPrio){ if($e.Managers.ContainsKey($mk) -and $mk -ne 'web'){$mgr=$mk;break} }
            if($mgr){ $instList += [pscustomobject]@{Name=[string]$e.Name;Mgr=$mgr;Id=[string]$e.Managers[$mgr]} }
            else { $skip += [string]$e.Name }
        }
        if($skip.Count){& $sayLog "Ohne PM-Pfad uebersprungen: $($skip -join ', ')"}
        if(-not $instList.Count){& $setStatus 'Keine abgehakten Apps mit Paketmanager-Pfad.' '#FFFFB74D';return}
        $names=($instList | ForEach-Object { $_.Name }) -join ', '
        if($names.Length -gt 300){$names=$names.Substring(0,300)+' ...'}
        $r=[System.Windows.MessageBox]::Show("$($instList.Count) App(s) installieren?`n`n$names`n`n(silent, nacheinander - Log unten)",'App Store','YesNo','Question')
        if($r -ne 'Yes'){return}
        & $stEnqueue "Batch-Install: $($instList.Count) App(s)" $batchCode @{ instList=$instList } "Installiere $($instList.Count) App(s) ..."
    })

    $fc.CatList.Add_SelectionChanged({ & $renderCards }.GetNewClosure())
    $fc.TxtSearch.Add_TextChanged({ & $renderCards }.GetNewClosure())
    foreach($cb in 'ChkWin','ChkLinux','ChkMac'){ $fc[$cb].Add_Checked({ & $renderCards }.GetNewClosure()); $fc[$cb].Add_Unchecked({ & $renderCards }.GetNewClosure()) }
    $fc.BtnRebuild.Add_Click({ & $startRebuild })
    $fc.BtnAiSort.Add_Click({
        # Lokaler KI-Server bereit? Sonst Setup anbieten (Ollama + Modell)
        $ready = $false
        try { $ready = Test-SysPilotIndexAiReady } catch {}
        if(-not $ready){
            $r=[System.Windows.MessageBox]::Show("Kein lokaler KI-Server (Ollama) bereit.`n`nDie Kategorisierung funktioniert am besten mit Ollama - kostenlos, laeuft lokal, unlimitiert.`n`nJetzt einrichten (Installation + Modell-Download, kann 5-30 Minuten dauern - das Fenster reagiert dann nicht)?`n`n'Nein' = stattdessen die Cloud-Provider-Kette versuchen.",'KI-Server-Setup','YesNo','Question')
            if($r -eq 'Yes'){
                & $setStatus 'KI-Server-Setup laeuft (Installation + Modell) ...' '#FFB0B0C0'
                [void](Show-SysPilotIndexAiSetup -Owner $win)
            }
        }
        & $startAiSort
    })
    $fc.BtnAutoTask.Add_Click({
        $t = Get-SysPilotAppIndexTask
        if($t){
            $r=[System.Windows.MessageBox]::Show('Woechentliche Index-Aktualisierung (So 04:00) entfernen?','App Store','YesNo','Question')
            if($r -eq 'Yes'){Remove-SysPilotAppIndexTask;& $sayLog 'Index-Task entfernt.'}
        } else {
            $r=[System.Windows.MessageBox]::Show("Woechentliche Index-Aktualisierung einrichten?`n(So 04:00, silent,indexed alle Quellen neu)`n`nDer Index bleibt so automatisch aktuell - Morgens einfach den Store oeffnen.",'App Store','YesNo','Question')
            if($r -eq 'Yes'){Install-SysPilotAppIndexTask;& $sayLog 'Index-Task installiert (woechentlich So 04:00).'}
        }
    })
    $fc.BtnClose.Add_Click({$win.Close()})

    $poll = New-Object System.Windows.Threading.DispatcherTimer
    $poll.Interval=[timespan]::FromMilliseconds(300)
    $poll.Add_Tick({
        & $drainQ
        # Sanftes Auffuellen + Live-%-Anzeige
        try {
            if ($fc._stBusy -and -not $fc.ProgBar.IsIndeterminate -and $fc.ProgBar.Visibility -eq 'Visible') {
                $goal = [double]$(if($null -ne $fc._stProgGoal){$fc._stProgGoal}else{0})
                $cur  = [double]$fc.ProgBar.Value
                $cap  = $goal - 0.15
                if ($cap -gt $cur) { $fc.ProgBar.Value = [Math]::Min($cap, $cur + ($cap - $cur) * 0.04 + 0.02) }
                if ($fc._stCurLabel) {
                    $pct = [int][Math]::Round($fc.ProgBar.Value / [Math]::Max(1.0,[double]$fc.ProgBar.Maximum) * 100)
                    $el  = ''
                    if ($fc._stJobT0) { try { $el = ' - ' + ((Get-Date) - $fc._stJobT0).ToString('mm\:ss') } catch {} }
                    $fc.TxtStatus.Text = "$($fc._stCurLabel)  [$pct%]$el"
                }
            }
        } catch {}
        if($fc._stAsync -and $fc._stAsync.IsCompleted -and $fc._stBusy){
            try{$null=@($fc._stPs.EndInvoke($fc._stAsync))}catch{& $sayLog "Job-Fehler: $($_.Exception.Message)"}
            try{$fc._stPs.Dispose()}catch{}
            try{$fc._stRs.Close();$fc._stRs.Dispose()}catch{}
            $fc._stPs=$null;$fc._stRs=$null;$fc._stAsync=$null
            $fc._stBusy=$false;$fc._stCurLabel=$null
            $fc.ProgBar.IsIndeterminate=$false;$fc.ProgBar.Minimum=0;$fc.ProgBar.Maximum=100;$fc.ProgBar.Value=100
            # Index-Rebuild: Log auf INDEX_DONE pruefen -> neu laden
            $tail = ($fc.LogBox.Text -split "`n" | Select-Object -Last 30) -join "`n"
            if($tail -match 'INDEX_DONE\|(\d+)\|'){
                & $sayLog "Index gespeichert: $($Matches[1]) Apps"
                & $loadIndex
            } elseif($tail -match 'AI_SORT_DONE\|(\d+)\|(\d+)\|(\d+)\|(\w+)'){
                & $sayLog "Herbert sortierte $($Matches[1]) Eintraege ($($Matches[2]) waren Sonstige, $($Matches[3]) uebrig)"
                & $loadIndex
                & $setStatus "KI-Sortierung fertig: $($Matches[1]) einsortiert, $($Matches[3]) verbleiben in Sonstige." '#FF81C784'
            } else {
                & $setStatus 'Aufgabe abgeschlossen.' '#FF81C784'
            }
        }
        if(-not $fc._stBusy -and $fc._stPending.Count -gt 0){ & $stPumpItem $fc._stPending.Dequeue() }
    }.GetNewClosure())
    $win.Add_Closing({
        $poll.Stop()
        if($fc._stAsync){try{$fc._stPs.Stop();$fc._stPs.Dispose();$fc._stRs.Close();$fc._stRs.Dispose()}catch{}}
    })
    $poll.Start()
    & $loadIndex
    if (Get-Command Set-SysPilotWindowAutoSize -ErrorAction SilentlyContinue) {
        Set-SysPilotWindowAutoSize -Win $win -MinWidth 1000 -MinHeight 640
    }
    Add-SysPilotAssistantToWindow -Win $win -Context 'Show-SysPilotAppStoreWindow'
    [void]$win.ShowDialog()
    return $true
}

Export-ModuleMember -Function Get-SysPilotAppIndexPath, Get-SysPilotAppIndex,
    Save-SysPilotAppIndex, New-SysPilotAppIndex, Update-SysPilotAppIndex,
    Get-SysPilotAppIndexTask, Install-SysPilotAppIndexTask, Remove-SysPilotAppIndexTask,
    Show-SysPilotAppStoreWindow, Get-SysPilotIndexFromCodeRepos,
    Add-SysPilotAiIndexCategories, Update-SysPilotIndexSonstige, Test-SysPilotIndexAiReady,
    Show-SysPilotIndexAiSetup, Get-SysPilotIndexFromWebPortals, Find-SysPilotAppForks, Find-SysPilotAppAlternatives,
    Show-SysPilotAppRelations
