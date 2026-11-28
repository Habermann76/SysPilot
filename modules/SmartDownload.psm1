# SmartDownload.psm1 - KI-Pseudo-Paketmanager: orchestrierte
# Download-Link-Suche ueber Paketmanager, Web-Kataloge,
# Suchmaschinen (DDG/Bing) und Herbert-KI.
#
# Architektur: Find-SysPilotDownload startet bis zu 4 Kind-Runspaces
# parallel (PM, Kataloge, Websuche), sammelt die Funde und laesst
# Herbert in Phase 2 die Kandidaten bewerten. Ergebnisse werden
# heuristisch vor-bewertet (offizielle Domain, Download-Pfad,
# Katalog-Bonus, Junk-Filter), damit die KI-Liste kurz bleibt.

$script:SmartDlJunkDomains = @(
    'youtube.com','youtu.be','facebook.com','instagram.com','tiktok.com',
    'pinterest.com','reddit.com','quora.com','linkedin.com','twitter.com',
    'x.com','amazon.','ebay.','aliexpress.','wikipedia.org','wikihow.com',
    'medium.com','blogspot.','wordpress.com','tumblr.com','9gag.com',
    'twitch.tv','discord.','telegram.','whatsapp.com','spotify.com',
    'google.com/search','bing.com/search','duckduckgo.com'
)
$script:SmartDlCatalogDomains = @(
    'majorgeeks.com','uptodown.com','filehorse.com','softpedia.com',
    'ninite.com','fossbytes.com','softonic.com','filehorse.com',
    'majorgeeks.com','techspot.com','filehorse.com','softpedia.com',
    'portableapps.com',' alternativeto.net','ghacks.net','makeuseof.com'
)

function Find-SysPilotWebResults {
    <# Durchsucht Suchmaschinen headless und gibt strukturierte
       Treffer zurueck: @{Title;Url;Engine;Snippet;Score}.
       Engine 'ddg' (html.duckduckgo.com, uddg=-Redirects) und
       'bing' (bing.com/search, u=-Param ist base64). #>
    param(
        [Parameter(Mandatory)][string]$Query,
        [int]$MaxPerEngine = 8
    )
    $results = @()
    $qEsc = [Uri]::EscapeDataString($Query)
    $ua = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36' }
    $seen = @{}

    # --- DuckDuckGo HTML ---
    try {
        $u = "https://html.duckduckgo.com/html/?q=$qEsc"
        $r = Invoke-WebRequest $u -UseBasicParsing -TimeoutSec 15 -Headers $ua -ErrorAction Stop
        $n = 0
        foreach ($m in [regex]::Matches($r.Content, 'class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>')) {
            $href = $m.Groups[1].Value
            $real = $href
            if ($href -match 'uddg=([^&"]+)') { $real = [uri]::UnescapeDataString($Matches[1]) }
            if ($real -notmatch '^https?://') { continue }
            $real = $real.TrimEnd('/')
            if ($seen.ContainsKey($real)) { continue }
            $title = ($m.Groups[2].Value -replace '<[^>]+>','').Trim()
            if (-not $title) { continue }
            $seen[$real] = $true
            $results += [pscustomobject]@{ Title=$title; Url=$real; Engine='ddg'; Snippet=''; Score=0 }
            $n++; if ($n -ge $MaxPerEngine) { break }
        }
    } catch { }

    # --- Bing (u= Parameter: 'a1' + base64url) ---
    try {
        $u = "https://www.bing.com/search?q=$qEsc&setlang=de"
        $r = Invoke-WebRequest $u -UseBasicParsing -TimeoutSec 15 -Headers $ua -ErrorAction Stop
        $n = 0
        foreach ($m in [regex]::Matches($r.Content, '<h2[^>]*>\s*<a[^>]+href="([^"]+)"[^>]*>(.*?)</a>')) {
            $href = ($m.Groups[1].Value -replace '&amp;','&')
            $real = ''
            if ($href -match '[?&]u=a1([^&"]+)') {
                $b64 = $Matches[1] -replace '-','+' -replace '_','/'
                $pad = 4 - ($b64.Length % 4); if ($pad -lt 4) { $b64 += '=' * $pad }
                try { $real = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) } catch { $real = '' }
            }
            if (-not $real -and $href -match '^https?://') { $real = $href }
            if (-not $real -or $real -notmatch '^https?://') { continue }
            $real = $real.TrimEnd('/')
            if ($seen.ContainsKey($real)) { continue }
            $title = ($m.Groups[2].Value -replace '<[^>]+>','').Trim()
            if (-not $title) { continue }
            $seen[$real] = $true
            $results += [pscustomobject]@{ Title=$title; Url=$real; Engine='bing'; Snippet=''; Score=0 }
            $n++; if ($n -ge $MaxPerEngine) { break }
        }
    } catch { }

    return @($results)
}

function Get-SysPilotSmartDlScore {
    <# Heuristische Vorbewertung eines Web-Treffers.
       Positiv: offizielle Domain (Name-Token), Download-Pfad,
       Katalog-Domain. Negativ: Junk-Domains, News/Blog-Only. #>
    param(
        [Parameter(Mandatory)][pscustomobject]$Hit,
        [string]$AppName = ''
    )
    $score = 0
    $u = [string]$Hit.Url
    $host_ = ''
    try { $host_ = ([uri]$u).Host.ToLower() } catch { return -10 }
    $path = ''
    try { $path = ([uri]$u).AbsolutePath.ToLower() } catch {}

    foreach ($j in $script:SmartDlJunkDomains) { if ($host_.Contains($j) -or $u.Contains($j)) { $score -= 4 } }
    foreach ($c in $script:SmartDlCatalogDomains) { if ($host_.Contains($c)) { $score += 3 } }
    if ($path -match 'download|/dl/|get-|install|setup|releases?/|/files/') { $score += 2 }
    if ($u -match '\.(exe|msi|zip|7z)(\?|$)') { $score += 3 }
    if ($host_ -match '^(www\.|de\.|en\.|apps\.)?microsoft\.com$' -or $host_ -match 'apps\.microsoft\.com') { $score += 1 }
    # Name-Token im Host = wahrscheinlich offizielle Domain
    if ($AppName) {
        $tokens = $AppName -split '[\s\-_\.\(\)]+' | Where-Object { $_.Length -ge 3 } |
            ForEach-Object { $_.ToLower() } | Where-Object { $_ -notin @('the','for','and','pro','plus','free','windows','64','32','new','latest') }
        foreach ($t in $tokens) { if ($host_.Contains($t)) { $score += 3; break } }
    }
    return $score
}

function Find-SysPilotCodeRepoHits {
    <# GitHub + GitLab Repo-Suche fuer einen Begriff (API, stars-sortiert).
       Gibt @{Source;Title;Url;Note;Best} zurueck - gleiche Form wie
       Katalog-Treffer, damit sie in dieselben Listen passen. #>
    param([Parameter(Mandatory)][string]$Query, [int]$MaxPerSource = 6)
    $results = @()
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
    $q = $Query.Trim()
    if (-not $q) { return @() }
    $enc = [Uri]::EscapeDataString($q)
    # --- GitHub ---
    try {
        $hdr = @{ 'User-Agent'='SysPilot'; 'Accept'='application/vnd.github+json' }
        $r = Invoke-RestMethod "https://api.github.com/search/repositories?q=$enc&sort=stars&order=desc&per_page=$MaxPerSource" -Headers $hdr -TimeoutSec 15 -ErrorAction Stop
        foreach ($it in @($r.items)) {
            $desc = [string]$it.description
            if ($desc.Length -gt 90) { $desc = $desc.Substring(0,90)+'...' }
            $results += [pscustomobject]@{ Source='GitHub'; Title=$it.full_name; Url=$it.html_url
                Note="$(if($it.language){"[$($it.language)] "})$($it.stargazers_count) Stars$(if($desc){" - $desc"})"; Best=($it.stargazers_count -ge 1000) }
        }
    } catch {}
    # --- GitLab ---
    try {
        $r = Invoke-RestMethod "https://gitlab.com/api/v4/projects?search=$enc&order_by=star_count&sort=desc&per_page=$MaxPerSource" -TimeoutSec 15 -ErrorAction Stop
        foreach ($it in @($r)) {
            $desc = [string]$it.description
            if ($desc.Length -gt 90) { $desc = $desc.Substring(0,90)+'...' }
            $results += [pscustomobject]@{ Source='GitLab'; Title=$it.path_with_namespace; Url=$it.web_url
                Note="$($it.star_count) Stars$(if($desc){" - $desc"})"; Best=($it.star_count -ge 500) }
        }
    } catch {}
    return @($results)
}

function Find-SysPilotDownload {
    <# Orchestriert die komplette Download-Suche in bis zu 4
       parallelen Kind-Runspaces. Gibt zurueck:
       @{Ok;Query;Pm;Catalog;Web;AiText;AiUrls;Stats}
       Optionaler Scriptblock -OnProgress erhaelt Statuszeilen. #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Id = '',
        [string]$ErrorText = '',
        [int]$MaxWebResults = 15,
        [string]$Category = '',
        [ValidateSet('install','file')][string]$Goal = 'install',
        [scriptblock]$OnProgress = $null
    )
    $say = { param($m) if ($OnProgress) { $null = & $OnProgress ([string]$m) } }
    $modDir = $PSScriptRoot
    $query = "$Name $Id".Trim()

    $pmCode = @'
$pm = @()
try {
    Import-Module (Join-Path $modDir 'Common.psm1') -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $modDir 'PackageManagers.psm1') -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $modDir 'SoftwareUpdateCenter.psm1') -Force -ErrorAction SilentlyContinue
    $q = $fuQueue
    $say = { param($m) if ($q) { $q.Enqueue([string]$m) } }
    & $say "Paketmanager: choco/scoop nach '$query' ..."
    foreach ($c in @(Find-SysPilotChocoRemoteCandidates -Query $query | Select-Object -First 3)) {
        $pm += [pscustomobject]@{ Kind='choco'; Text="Kandidat '$c' (choco search)"; Url='' }
    }
    foreach ($c in @(Find-SysPilotScoopRemoteCandidates -Query $query | Select-Object -First 3)) {
        $pm += [pscustomobject]@{ Kind='scoop'; Text="Kandidat '$c' (scoop search)"; Url='' }
    }
} catch { if ($q) { $q.Enqueue("PM-Suche Fehler: $($_.Exception.Message)") } }
$pm
'@

    $catCode = @'
$cat = @()
try {
    Import-Module (Join-Path $modDir 'Common.psm1') -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $modDir 'SoftwareUpdateCenter.psm1') -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $modDir 'PackageManagers.psm1') -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $modDir 'AppStore.psm1') -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $modDir 'SmartDownload.psm1') -Force -ErrorAction SilentlyContinue
    $q = $fuQueue
    $say = { param($m) if ($q) { $q.Enqueue([string]$m) } }
    & $say 'Kataloge: Ninte/MajorGeeks/Uptodown/FOSSHub + Katalog-Suche (Uptodown, FileHorse) ...'
    $cat += @(Get-SysPilotWebSourceVersions -Query $query | Select-Object -First 6)
    $cat += @(Find-SysPilotCatalogSearch -Query $query | Select-Object -First 8)
    # Lokaler Megastore-Index (appindex.json, 4000+ Apps aus choco/
    # scoop/GitHub/Webportalen): Token-Match auf Name+Desc -> Page-Link
    # + Manager-Quellen. Deckt Apps ab, die sonst nur als Roheintrag
    # im Store existieren und per Web-Scraping nicht gefunden werden.
    try {
        if (Get-Command Get-SysPilotAppIndex -ErrorAction SilentlyContinue) {
            $idx = Get-SysPilotAppIndex
            $qLow = $query.ToLower()
            $tok = @([regex]::Matches($qLow,'[a-z0-9]{3,}') | ForEach-Object { $_.Value } | Select-Object -First 5)
            $idxHits = foreach ($e in @($idx.Entries)) {
                $nLow = ([string]$e.Name).ToLower(); $dLow = ([string]$e.Desc).ToLower()
                $score = 0
                foreach ($t in $tok) { if ($nLow.Contains($t)) { $score += 2 } elseif ($dLow.Contains($t)) { $score += 1 } }
                if ($score -ge 2 -and [string]$e.Page) {
                    $mgrs = @($e.ManagerList) -join '+'
                    [pscustomobject]@{ Source='Index'; Title=[string]$e.Name; Url=[string]$e.Page; Version=''; Note="Megastore ($mgrs)$(if($e.Cat){", $($e.Cat)"})"; Best=($score -ge 5) }
                }
            }
            foreach ($h in (@($idxHits) | Sort-Object Best -Descending | Select-Object -First 8)) { $cat += $h }
        }
    } catch {}
    # Kategorie-Filter: kuratierter Update-Katalog liefert Treffer aus
    # der gewaehlten Kategorie (z.B. 'Browser', 'Multimedia'), deren
    # Name zum Suchbegriff passt - mit winget-ID/Page als Quelle.
    if ($catFilter -and $catFilter -ne 'Alle') {
        $qLow = $query.ToLower()
        $tok = @([regex]::Matches($qLow,'[a-z0-9]{3,}') | ForEach-Object { $_.Value } | Select-Object -First 4)
        $cur = @(Get-SysPilotUpdateCatalog | Where-Object { $_.Cat -eq $catFilter })
        $curHits = foreach ($a in $cur) {
            $nLow = ([string]$a.Name).ToLower()
            $hit = 0; foreach ($t in $tok) { if ($nLow.Contains($t)) { $hit++ } }
            if ($hit -gt 0) {
                $u = [string]$(if ($a.Page) { $a.Page } elseif ($a.WingetId) { '' } else { '' })
                $note = "Katalog '$catFilter'"
                if ($a.WingetId) { $note += ", winget: $($a.WingetId)" }
                if ($a.Gh) { $note += ", GitHub: $($a.Gh)" }
                [pscustomobject]@{ Source='Katalog'; Title=[string]$a.Name; Url=$u; Version=''; Note=$note; Best=($hit -ge 2) }
            }
        }
        foreach ($h in ($curHits | Sort-Object Best -Descending | Select-Object -First 5)) { $cat += $h }
    }
    $seenU = @{}; $catOut = @()
    foreach ($w in $cat) {
        $wu = [string]$w.Url
        if ($wu -and $seenU.ContainsKey($wu)) { continue }
        if ($wu) { $seenU[$wu] = $true }
        $catOut += $w
    }
    $catOut | Select-Object -First 12
} catch { if ($q) { $q.Enqueue("Katalog-Suche Fehler: $($_.Exception.Message)") }; @() }
'@

    $codeCode = @'
$codeHits = @()
try {
    Import-Module (Join-Path $modDir 'SmartDownload.psm1') -Force
    $q = $fuQueue
    $say = { param($m) if ($q) { $q.Enqueue([string]$m) } }
    & $say 'Code-Repos: GitHub + GitLab (API, stars-sortiert) ...'
    $codeHits = @(Find-SysPilotCodeRepoHits -Query $query -MaxPerSource 6)
} catch { if ($q) { $q.Enqueue("Code-Suche Fehler: $($_.Exception.Message)") }; @() }
$codeHits
'@

    $webCode = @'
$web = @()
try {
    Import-Module (Join-Path $modDir 'Common.psm1') -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $modDir 'SmartDownload.psm1') -Force
    $q = $fuQueue
    $say = { param($m) if ($q) { $q.Enqueue([string]$m) } }
    & $say "Websuche: DDG + Bing nach '$query' (offiziell, Kataloge, neueste Version) ..."
    $queries = @(
        "$query official download",
        "$query latest version windows download",
        "`"$query`" site:majorgeeks.com OR site:uptodown.com OR site:filehorse.com OR site:softpedia.com",
        "$query download -youtube -facebook"
    )
    $all = @()
    foreach ($qs in $queries) {
        $all += @(Find-SysPilotWebResults -Query $qs -MaxPerEngine 6)
    }
    # Dedupe + Score + Top-N
    $seenU = @{}; $scored = @()
    foreach ($h in $all) {
        $hu = ([string]$h.Url).TrimEnd('/')
        if ($seenU.ContainsKey($hu)) { continue }
        $seenU[$hu] = $true
        $h.Score = Get-SysPilotSmartDlScore -Hit $h -AppName $itemName
        $scored += $h
    }
    $top = $scored | Sort-Object Score -Descending | Select-Object -First $maxWeb
    $out = @()
    foreach ($h in $top) {
        $out += [pscustomobject]@{ Title=$h.Title; Url=$h.Url; Engine=$h.Engine; Note="Score $($h.Score)"; Best=($h.Score -ge 5) }
    }
    $out
} catch { if ($q) { $q.Enqueue("Websuche Fehler: $($_.Exception.Message)") }; @() }
'@

    $aiCode = @'
$aiUrls = @(); $aiText = ''
$aiDec = @{ Method=''; Manager=''; Package=''; Reason='' }
try {
    Import-Module (Join-Path $modDir 'Common.psm1') -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $modDir 'AiAssist.psm1') -Force -ErrorAction Stop
    if (-not (Get-Command Invoke-SysPilotAiChat -ErrorAction SilentlyContinue)) {
        throw "AiAssist-Import erfolgreich, aber Invoke-SysPilotAiChat fehlt"
    }
    $q = $fuQueue
    $say = { param($m) if ($q) { $q.Enqueue([string]$m) } }
    & $say 'Herbert-KI bewertet alle Funde und waehlt den besten Link (kann 30-90s dauern) ...'
    $prompt = @"
Du bist Herbert, der Update-Manager-Assistent von SysPilot. Suche das passende Download-Update.
App: $itemName | ID: $itemId
Kategorie: $(if($catFilter -and $catFilter -ne 'Alle'){$catFilter}else{'(keine)'})
Fehler: $itemError
Ziel: $(if($goal -eq 'file'){'Datei herunterladen (portables Tool/Installer)' }else{'Programm installieren'})

Paketmanager-Kandidaten:
$pmTxt

Katalog-Funde:
$catTxt

Web-Suchtreffer (vorbewertet, Score = heuristische Einschaetzung):
$webTxt

Aufgabe: Waehle den besten Download-Link (offizielle Quelle bevorzugen,
Kataloge als Alternative). Antworte KURZ auf Deutsch:
1. Eine Zeile 'URL: <bester link>'
2. Optional weitere 'URL:'-Zeilen fuer Alternativen
3. 2-3 Saetze Zusammenfassung/A walkthrough.

Zusaetzlich entscheide die INSTALLATIONS-METHODE (Herbert-decide):
- Ziel ist ein Programm zu installieren (Goal=install): bevorzuge einen
  sauberen Paketmanager-Weg, wenn ein Kandidat oben eine echte
  Paket-ID nennt. Antworte dann ZUERST mit diesen Zeilen:
  METHODE: pm
  MANAGER: <winget|choco|scoop|npm|pip|dotnet|psgallery>
  PAKET: <exakte Paket-ID oder Name>
  BEGRUENDUNG: <ein Satz>
  Danach normal die URL:-Liste (als Fallback).
- Ziel ist nur eine Datei (Goal=file, z.B. portables Tool/Installer):
  Antworte METHODE: smartdl (PM nur wenn das Paket selbst die Datei ist).
- Fuer magnet:/torrent-Quellen: METHODE: torrent.
"@
    $ai = Invoke-SysPilotAiChat -Prompt $prompt -TimeoutSec 90
    if ($ai.Ok) {
        $aiText = [string]$ai.Text
        foreach ($m in [regex]::Matches($aiText, 'https?://[^\s)"''<>\]]+')) {
            $u = $m.Value.TrimEnd('.',',',';')
            if ($u -notmatch 'perplexity|duckduckgo|gemini|copilot|youtube|facebook') { $aiUrls += $u }
        }
        # Herbert-Entscheidung: METHODE pm|smartdl|torrent + MANAGER/PAKET
        foreach ($ln in ($aiText -split "`r?`n")) {
            $t = $ln.Trim()
            if ($t -match '^(?i)METHODE\s*:\s*(\w+)') { $aiDec.Method = $Matches[1].ToLower() }
            elseif ($t -match '^(?i)MANAGER\s*:\s*(\S+)') { $aiDec.Manager = $Matches[1].ToLower() }
            elseif ($t -match '^(?i)PAKET\s*:\s*(.+)$') { $aiDec.Package = $Matches[1].Trim() }
            elseif ($t -match '^(?i)BEGRUENDUNG\s*:\s*(.+)$') { $aiDec.Reason = $Matches[1].Trim() }
        }
    } else { & $say "Herbert nicht erreichbar: $($ai.Error)" }
} catch { if ($q) { $q.Enqueue("KI-Suche Fehler: $($_.Exception.Message)") } }
@{ AiUrl=$aiUrls; AiText=$aiText; AiDec=$aiDec }
'@

    & $say "SmartDownload: Suche nach '$Name' ($Id) - 3 Quellen parallel ..."
    $modDirVar = $modDir; $queryVar = $query; $nameVar = $Name; $idVar = $Id; $errVar = $ErrorText; $maxWebVar = $MaxWebResults; $catVar = $Category; $goalVar = $Goal

    $sdQ = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
    $drainSd = {
        $line = $null
        while ($sdQ.TryDequeue([ref]$line)) { $null = & $OnProgress ([string]$line) }
    }
    $spawn = {
        param([string]$name, [string]$code, [hashtable]$extra)
        $crs = [runspacefactory]::CreateRunspace()
        $crs.ApartmentState='STA'; $crs.ThreadOptions='ReuseThread'; $crs.Open()
        $vars = @{ modDir=$modDirVar; fuQueue=$sdQ; query=$queryVar; itemName=$nameVar; itemId=$idVar; itemError=$errVar; maxWeb=$maxWebVar; catFilter=$catVar; goal=$goalVar }
        if ($extra) { foreach ($kv in $extra.GetEnumerator()) { $vars[$kv.Key]=$kv.Value } }
        foreach ($kv in $vars.GetEnumerator()) { $crs.SessionStateProxy.SetVariable($kv.Key,$kv.Value) }
        $cps = [powershell]::Create(); $cps.Runspace=$crs
        [void]$cps.AddScript($code)
        @{ Name=$name; Rs=$crs; Ps=$cps; H=$cps.BeginInvoke() }
    }
    $waitAll = {
        param($children)
        foreach ($c in $children) {
            while (-not $c.H.IsCompleted) { & $drainSd; Start-Sleep -Milliseconds 250 }
            try { $c.Out = @($c.Ps.EndInvoke($c.H)) }
            catch { $c.Out=@(); $null = & $OnProgress "[$($c.Name)] Fehler: $($_.Exception.Message)" }
            try { $c.Ps.Dispose() } catch {}
            try { $c.Rs.Close(); $c.Rs.Dispose() } catch {}
        }
        & $drainSd
    }

    $children = @(
        & $spawn 'pm'  $pmCode  $null
        & $spawn 'cat' $catCode $null
        & $spawn 'code' $codeCode $null
        & $spawn 'web' $webCode $null
    )
    & $say 'Phase 1: Paketmanager + Kataloge + Code-Repos + Websuche parallel ...'
    & $waitAll $children

    $pm=@(); $cat=@(); $web=@()
    foreach ($c in $children) {
        if ($c.Name -eq 'pm')  { $pm  = @($c.Out | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['Kind'] }) }
        if ($c.Name -eq 'cat') { $cat = @($c.Out | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['Url'] }) }
        if ($c.Name -eq 'code'){ $cat += @($c.Out | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['Url'] }) }
        if ($c.Name -eq 'web') { $web = @($c.Out | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['Engine'] }) }
    }
    & $say "Phase 1 fertig: PM=$($pm.Count) Kataloge=$($cat.Count) Web=$($web.Count) - Herbert wird gefragt ..."

    # Phase 2: Herbert bewertet
    $pmTxt=''; foreach($p in $pm){ $pmTxt += "- [$($p.Kind)] $($p.Text)`n" }; if(-not $pmTxt){$pmTxt="- (keine)`n"}
    $catTxt=''; foreach($w in $cat | Select-Object -First 12){ $disp=$(if($w.Version){$w.Version}elseif($w.Title){$w.Title}else{$w.Source}); $catTxt += "- [$($w.Source)] $disp -> $($w.Url) ($($w.Note))`n" }; if(-not $catTxt){$catTxt="- (keine)`n"}
    $webTxt=''; foreach($h in $web | Select-Object -First $MaxWebResults){ $webTxt += "- [$($h.Engine) Score=$($h.Score)] $($h.Title) -> $($h.Url)`n" }; if(-not $webTxt){$webTxt="- (keine)`n"}

    $aiChild = & $spawn 'ki' $aiCode @{ pmTxt=$pmTxt; catTxt=$catTxt; webTxt=$webTxt }
    & $waitAll @($aiChild)
    $aiRes = @($aiChild.Out | Where-Object { $_ -is [hashtable] }) | Select-Object -First 1
    $aiUrls=@(); $aiText=''; $decision=@{Method='';Manager='';Package='';Reason=''}
    if ($aiRes) {
        $aiUrls=@($aiRes['AiUrl']); $aiText=[string]$aiRes['AiText']
        if ($aiRes.ContainsKey('AiDec') -and $aiRes['AiDec']) { $decision = $aiRes['AiDec'] }
    }
    if ($decision.Method -eq 'pm' -and $Goal -eq 'file') { $decision.Method = 'smartdl' }  # Datei-Kontext: kein PM

    & $say 'Suche abgeschlossen.'
    return @{
        Ok=$true; Query=$query; Name=$Name; Id=$Id
        Pm=$pm; Catalog=$cat; Web=$web
        AiText=$aiText; AiUrls=$aiUrls; Decision=$decision
        Stats=@{ Pm=$pm.Count; Catalog=$cat.Count; Web=$web.Count }
    }
}

function Show-SysPilotDownloadFinder {
    <# WPF-Fenster fuer die SmartDownload-Suche: Eingabefelder
       (Name/ID/Fehler), Live-Protokoll, Fortschrittsbalken,
       Ergebnis-Liste mit Direktlinks + kostenlose Web-KI. #>
    param(
        [string]$AppName = '',
        [string]$AppId = '',
        [string]$ErrorText = '',
        [string]$Title = 'Download-Suche',
        $Owner = $null
    )
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
        Write-Warning 'Show-SysPilotDownloadFinder braucht STA - im Konsolen-Modus nicht verfuegbar.'
        return $false
    }
    try {
        [void][reflection.assembly]::LoadWithPartialName('PresentationFramework')
        [void][reflection.assembly]::LoadWithPartialName('PresentationCore')
        [void][reflection.assembly]::LoadWithPartialName('WindowsBase')
    } catch { }

    $script:_sdQueue = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
    $results = @()

    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$Title" Width="980" Height="640" WindowStartupLocation="CenterOwner"
        Background="#FF1E1E2E" Foreground="#FFEAEAF2" FontFamily="Segoe UI">
  <Window.Resources>
    <Style TargetType="ListViewItem">
      <Setter Property="Padding" Value="8,5"/>
      <Setter Property="Foreground" Value="#FFEAEAF2"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#FF34344E"/></Trigger>
        <Trigger Property="IsSelected" Value="True">
          <Setter Property="Background" Value="#CCE4EAF2"/>
          <Setter Property="Foreground" Value="#FF1E1E2E"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="#FFEAEAF2"/><Setter Property="Background" Value="Transparent"/>
      <Setter Property="Padding" Value="8,4"/>
      <Style.Triggers>
        <Trigger Property="IsHighlighted" Value="True"><Setter Property="Background" Value="#FF34344E"/><Setter Property="Foreground" Value="#FFEAEAF2"/></Trigger>
        <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#CCE4EAF2"/><Setter Property="Foreground" Value="#FF1E1E2E"/></Trigger>
      </Style.Triggers>
    </Style>
  </Window.Resources>
  <Grid Margin="14">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="170"/><RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <StackPanel Orientation="Horizontal" Grid.Row="0" Margin="0,0,0,8">
      <TextBlock Text="Name:" VerticalAlignment="Center" Margin="0,0,6,0"/>
      <TextBox x:Name="TxtName" Width="240" VerticalAlignment="Center"/>
      <TextBlock Text="ID:" VerticalAlignment="Center" Margin="14,0,6,0"/>
      <TextBox x:Name="TxtId" Width="220" VerticalAlignment="Center"/>
      <TextBlock Text="Kategorie:" VerticalAlignment="Center" Margin="14,0,6,0"/>
      <ComboBox x:Name="KatBox" Width="150" VerticalAlignment="Center"/>
      <Button x:Name="BtnSearch" Content="Suchen" Width="90" Margin="16,0,0,0"/>
      <Button x:Name="BtnAssist" Content="Install-Hilfe" Width="110" Margin="8,0,0,0" ToolTip="Herbert schlaegt Installationswege vor: PM-IDs, Konsolenbefehle, Download-Links"/>
      <Button x:Name="BtnClose" Content="Schliessen" Width="90" Margin="8,0,0,0"/>
    </StackPanel>
    <TextBox x:Name="TxtError" Grid.Row="1" Height="44" Margin="0,0,0,8" IsReadOnly="True"
             TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Background="#FF14141E"
             Foreground="#FFB0B0C0" FontFamily="Consolas" FontSize="11"/>
    <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,0,0,6">
      <TextBlock x:Name="TxtStatus" Text="Bereit." Foreground="#FFB0B0C0" VerticalAlignment="Center"/>
      <ProgressBar x:Name="ProgBar" Width="220" Height="8" Margin="16,0,0,0"
                   VerticalAlignment="Center" Visibility="Collapsed" IsIndeterminate="True"/>
    </StackPanel>
    <ListView x:Name="ResultList" Grid.Row="3" Margin="0,0,0,8" Background="#FF14141E"
              Foreground="#FFEAEAF2" BorderBrush="#FF3A3A55">
      <ListView.View><GridView>
        <GridViewColumn Header="Quelle" Width="90"  DisplayMemberBinding="{Binding Tag}"/>
        <GridViewColumn Header="Treffer"  Width="640" DisplayMemberBinding="{Binding Label}"/>
        <GridViewColumn Header="URL"      Width="200" DisplayMemberBinding="{Binding Url}"/>
      </GridView></ListView.View>
    </ListView>
    <RichTextBox x:Name="HerbBox" Grid.Row="4" Height="120" IsReadOnly="True" Visibility="Collapsed"
                 Background="#FF101018" Foreground="#FFEAEAF2" BorderThickness="0"
                 FontFamily="Segoe UI" FontSize="12" Padding="8,6" Margin="0,0,0,8"
                 VerticalScrollBarVisibility="Auto" ToolTip="Herbert-Antwort - URLs sind klickbar"/>
    <TextBox x:Name="LogBox" Grid.Row="5" IsReadOnly="True" TextWrapping="Wrap"
             VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
             Background="#FF0E140E" Foreground="#FF9CCC65" FontFamily="Consolas" FontSize="11"
             BorderBrush="#FF2E4A2E" AcceptsReturn="True"/>
    <StackPanel Grid.Row="6" Orientation="Horizontal" Margin="0,8,0,0">
      <Button x:Name="BtnOpen" Content="Link oeffnen" Width="110" IsEnabled="False"/>
      <Button x:Name="BtnCopy" Content="Alles kopieren" Width="120" Margin="8,0,0,0"/>
      <TextBlock x:Name="TxtHint" Text="Tipp: Rechtsklick in Log = kopieren. Enter im Namensfeld = Suchen." Foreground="#FF7A7A90" VerticalAlignment="Center" Margin="16,0,0,0"/>
    </StackPanel>
  </Grid>
</Window>
"@
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
    $win = [Windows.Markup.XamlReader]::Load($reader)
    if ($Owner) { try { $win.Owner = $Owner } catch {} }
    $fc = @{}
    foreach ($n in 'TxtName','TxtId','TxtError','BtnSearch','BtnAssist','BtnClose','TxtStatus','ProgBar','ResultList','HerbBox','LogBox','BtnOpen','BtnCopy','TxtHint','KatBox') {
        $fc[$n] = $win.FindName($n)
    }

    $fc.TxtName.Text = $AppName; $fc.TxtId.Text = $AppId
    $fc.TxtError.Text = $(if ($ErrorText) { "Fehler: $ErrorText" } else { 'Kein Fehlerkontext - freie Suche.' })
    if ($AppName -and -not $AppId) { $fc.TxtName.Focus(); $fc.TxtName.SelectAll() }
    # Kategorie-Box: 'Alle' + Katalog-Kategorien (SoftwareUpdateCenter)
    try {
        if (-not (Get-Command Get-SysPilotUpdateCatalogCategories -ErrorAction SilentlyContinue)) {
            Import-SysPilotModule -Name 'SoftwareUpdateCenter' -ErrorAction SilentlyContinue
        }
        if (Get-Command Get-SysPilotUpdateCatalogCategories -ErrorAction SilentlyContinue) {
            [void]$fc.KatBox.Items.Add('Alle')
            foreach ($c in @(Get-SysPilotUpdateCatalogCategories)) { [void]$fc.KatBox.Items.Add($c) }
        }
    } catch { }
    if ($fc.KatBox.Items.Count -eq 0) { [void]$fc.KatBox.Items.Add('Alle') }
    $fc.KatBox.SelectedIndex = 0

    $setStatus = { param($t,$c) $fc.TxtStatus.Text=[string]$t; $fc.TxtStatus.Foreground=[System.Windows.Media.BrushConverter]::new().ConvertFromString($c) }
    $drainLog = {
        $line = $null; $added = $false
        while ($script:_sdQueue.TryDequeue([ref]$line)) {
            Write-SysPilotPanelLog ([string]$line)
            $fc.LogBox.AppendText([string]$line + "`n"); $added = $true
        }
        if ($added) { $fc.LogBox.ScrollToEnd() }
    }
    $logTimer = New-Object System.Windows.Threading.DispatcherTimer
    $logTimer.Interval = [TimeSpan]::FromMilliseconds(200)
    $logTimer.Add_Tick({ & $drainLog })

    $busy = $false; $rs=$null; $ps=$null; $async=$null
    $pendQ = New-Object 'System.Collections.Generic.Queue[object]'
    $stopJob = {
        if ($async) { try { $ps.Stop(); $ps.Dispose() } catch {}; try { $rs.Close(); $rs.Dispose() } catch {} }
        $async=$null; $rs=$null; $ps=$null
    }
    $poll = New-Object System.Windows.Threading.DispatcherTimer
    $poll.Interval = [TimeSpan]::FromMilliseconds(700)
    $poll.Add_Tick({
        & $drainLog
        if (-not $async) { $poll.Stop(); & $setStatus 'Fertig.' '#FF81C784'; $fc.ProgBar.Visibility='Collapsed'; $fc.BtnSearch.IsEnabled=$true; return }
        if ($async.IsCompleted) {
            $poll.Stop(); & $drainLog
            $res = $null
            try { $res = $ps.EndInvoke($async) } catch { & $setStatus "Job-Fehler: $($_.Exception.Message)" '#FFEF5350' }
            & $stopJob
            if ($res -and $res.Ok) {
                # Ergebnisse zusammenstellen
                $items = @()
                foreach ($p in @($res.Pm))      { $items += [pscustomobject]@{ Tag='[pm]';     Label="PM $($p.Kind): $($p.Text)"; Url=$p.Url } }
                foreach ($w in @($res.Catalog)) { $disp = $(if($w.Version){$w.Version}elseif($w.Title){$w.Title}else{$w.Source}); $items += [pscustomobject]@{ Tag="[kat:$($w.Source)]"; Label="$disp - $($w.Note)"; Url=$w.Url } }
                foreach ($h in @($res.Web))     { $items += [pscustomobject]@{ Tag="[web:$($h.Engine)]"; Label="$($h.Title) ($($h.Note))"; Url=$h.Url } }
                foreach ($u in @($res.AiUrls))  { $items += [pscustomobject]@{ Tag='[ki]'; Label='Herbert-Fundstelle'; Url=$u } }
                $qe = [Uri]::EscapeDataString("$($fc.TxtName.Text) $($fc.TxtId.Text) download")
                $items += [pscustomobject]@{ Tag='[ki-frei]'; Label='Perplexity (Websuche)'; Url="https://www.perplexity.ai/?q=$qe" }
                $items += [pscustomobject]@{ Tag='[ki-frei]'; Label='Duck.ai (kostenlos)';     Url="https://duckduckgo.com/?q=$qe&ia=chat" }
                $items += [pscustomobject]@{ Tag='[ki-frei]'; Label='Gemini';                  Url="https://gemini.google.com/app?q=$qe" }
                $items += [pscustomobject]@{ Tag='[ki-frei]'; Label='Copilot';                 Url="https://copilot.microsoft.com/?q=$qe" }
                $results = $items
                $fc.ResultList.Items.Clear()
                foreach ($i in $items) { [void]$fc.ResultList.Items.Add($i) }
                $fc.ResultList.Visibility='Visible'
                if ($items.Count -gt 0) { $fc.ResultList.SelectedIndex=0; $fc.BtnOpen.IsEnabled=$true }
                if ($res.AiText) {
                    Set-SysPilotRichText -RichBox $fc.HerbBox -Text ([string]$res.AiText)
                    $fc.HerbBox.Visibility='Visible'
                }
                Set-SysPilotWindowAutoSize -Win $win -MinWidth 900 -MinHeight 560
                $st = $res.Stats
                & $setStatus "Fertig: $($st.Pm) PM, $($st.Catalog) Kataloge, $($st.Web) Web, $($items.Count) Ergebnisse." '#FF81C784'
            } else {
                & $setStatus 'Suche fehlgeschlagen.' '#FFEF5350'
            }
            $fc.ProgBar.Visibility='Collapsed'; $fc.BtnSearch.IsEnabled=$true; $busy=$false
            if ($pendQ.Count -gt 0) { $n=$pendQ.Dequeue(); & $beginSearch $n.n $n.i $n.e $n.c }
        }
    })

    $beginSearch = {
        param($name,$id,$err,$catSel)
        $busy=$true; $fc.BtnSearch.IsEnabled=$false
        $fc.HerbBox.Document.Blocks.Clear(); $fc.HerbBox.Visibility='Collapsed'
        $fc.LogBox.Clear(); $fc.ResultList.Items.Clear()
        $fc.ResultList.Visibility='Collapsed'; $fc.BtnOpen.IsEnabled=$false
        $results=@()
        & $setStatus "Suche laeuft: $name ..." '#FFB0B0C0'
        $fc.ProgBar.Visibility='Visible'; $fc.ProgBar.IsIndeterminate=$true
        while ($script:_sdQueue.TryDequeue([ref]([string]$null))) {}
        $rs=[runspacefactory]::CreateRunspace(); $rs.ApartmentState='STA'; $rs.ThreadOptions='ReuseThread'; $rs.Open()
        # Modul-Pfad robust aufloesen (laeuft auch aus Program Files)
        $modRoot = $null
        try { $modRoot = (Get-Module SmartDownload).Path } catch {}
        if (-not $modRoot) { $modRoot = Join-Path $env:ProgramFiles 'SysPilot\modules\SmartDownload.psm1' }
        $sdModDir = Split-Path $modRoot -Parent
        $sdQueue = $script:_sdQueue
        $ps=[powershell]::Create(); $ps.Runspace=$rs
        [void]$ps.AddScript({
            param($sdModDir,$sdName,$sdId,$sdErr,$sdCat,$sdQueue)
            Import-Module (Join-Path $sdModDir 'Common.psm1') -Force -ErrorAction SilentlyContinue
            Import-Module (Join-Path $sdModDir 'SmartDownload.psm1') -Force
            Import-Module (Join-Path $sdModDir 'SoftwareUpdateCenter.psm1') -Force -ErrorAction SilentlyContinue
            Import-Module (Join-Path $sdModDir 'PackageManagers.psm1') -Force -ErrorAction SilentlyContinue
            Import-Module (Join-Path $sdModDir 'AiAssist.psm1') -Force -ErrorAction SilentlyContinue
            Find-SysPilotDownload -Name $sdName -Id $sdId -ErrorText $sdErr -Category $sdCat `
                -OnProgress { param($m) $sdQueue.Enqueue($m) }
        }).AddArgument($sdModDir).AddArgument($name).AddArgument($id).AddArgument($err).AddArgument($catSel).AddArgument($sdQueue) | Out-Null
        $async=$ps.BeginInvoke()
        $poll.Start()
    }

    $startSearch = {
        $name=[string]$fc.TxtName.Text; $id=[string]$fc.TxtId.Text; $err=[string]$fc.TxtError.Text
        $catSel=[string]$fc.KatBox.SelectedItem; if(-not $catSel){$catSel='Alle'}
        if ($busy) {
            $pendQ.Enqueue(@{n=$name;i=$id;e=$err;c=$catSel})
            & $setStatus "Warteschlange: $($pendQ.Count) Suche(n) - '$name' wartet." '#FFFFB74D'
            return
        }
        & $beginSearch $name $id $err $catSel
    }

    $fc.BtnSearch.Add_Click({ & $startSearch })
    $fc.BtnAssist.Add_Click({
        $errCtx = $fc.TxtError.Text -replace '^Fehler:\s*',''
        if(-not $errCtx -or $errCtx -eq 'Kein Fehlerkontext - freie Suche.'){ $errCtx='' }
        try {
            Show-SysPilotInstallAssistWindow -AppName $fc.TxtName.Text.Trim() -AppId $fc.TxtId.Text.Trim() -ErrorText $errCtx -Owner $win -Title "Install-Hilfe: $($fc.TxtName.Text.Trim())"
        } catch { & $setStatus "Install-Hilfe: $($_.Exception.Message)" '#FFFF5252' }
    })
    $fc.BtnClose.Add_Click({ & $stopJob; $win.Close() })
    $fc.TxtName.Add_KeyUp({ param($s,$e) if ($e.Key -eq 'Enter') { & $startSearch } })
    $fc.BtnOpen.Add_Click({
        $i=$fc.ResultList.SelectedIndex; if($i -lt 0 -or $i -ge $results.Count){return}
        $u=[string]$results[$i].Url; if($u){Start-Process $u}else{& $setStatus 'Kein Direktlink - siehe Log.' '#FFFFB74D'}
    })
    $fc.ResultList.Add_MouseDoubleClick({
        $i=$fc.ResultList.SelectedIndex; if($i -lt 0 -or $i -ge $results.Count){return}
        $u=[string]$results[$i].Url; if($u){Start-Process $u}
    })
    $fc.ResultList.Add_SelectionChanged({ $fc.BtnOpen.IsEnabled = ($fc.ResultList.SelectedIndex -ge 0) })
    $fc.BtnCopy.Add_Click({
        $txt = $fc.LogBox.Text
        try { [Windows.Clipboard]::SetText($txt) } catch {}
        & $setStatus 'Protokoll kopiert.' '#FF81C784'
    })
    $fc.LogBox.Add_PreviewMouseRightButtonDown({
        $fc.LogBox.SelectAll()
    })
    $win.Add_Closed({ & $drainLog; & $stopJob; $logTimer.Stop(); $poll.Stop() })
    Set-SysPilotWindowAutoSize -Win $win -MinWidth 900 -MinHeight 560
    $logTimer.Start()
    Add-SysPilotAssistantToWindow -Win $win -Context 'Show-SysPilotDownloadFinder'
    [void]$win.ShowDialog()
    return $true
}

function Save-SysPilotSmartDownload {
    <# Drop-in-Wrapper um Save-SysPilotUrlToFile mit
       SmartDownload-Fallback: zuerst der bekannte/direct Link,
       bei Fehler oder fehlender URL wird Find-SysPilotDownload
       gestartet (PM + Kataloge + Suchmaschinen + Herbert) und
       der Nutzer waehlt aus den Herbert-/Top-Treffern den Link.
       Rueckgabe: @{Ok; Path; Url; AiText; Via} #>
    param(
        [string]$Url = '',
        [Parameter(Mandatory)][string]$OutFile,
        [Parameter(Mandatory)][string]$Name,
        [string]$Id = '',
        [string]$ErrorText = '',
        [int]$TimeoutSec = 600,
        [string]$Label = '',
        [switch]$AllowAbort
    )
    $lbl = $(if ($Label) { $Label } else { $Name })
    $fail = { param($why)
        Write-Host ("  [!] Download fehlgeschlagen ({0}). Starte SmartDownload-Suche ..." -f $why) -ForegroundColor Yellow
    }
    if ($Url) {
        Write-Host "  Lade $lbl von $Url ..." -ForegroundColor Cyan
        if (Invoke-SysPilotFileDownload -Url $Url -OutFile $OutFile -Label $lbl -TimeoutSec $TimeoutSec -Title $lbl) {
            return @{ Ok=$true; Path=$OutFile; Url=$Url; AiText=''; Via='direct' }
        }
        & $fail 'direkter Link'
    }
    else { & $fail 'kein direkter Link bekannt' }

    $say = { param($m) Write-Host "  $m" -ForegroundColor DarkGray }
    $res = Find-SysPilotDownload -Name $Name -Id $Id -ErrorText $ErrorText -Goal 'file' -OnProgress $say
    if (-not $res -or -not $res.Ok) { return @{ Ok=$false; Path=$null; Url=''; AiText=''; Via='smart' } }
    if ($res.Decision -and $res.Decision.Method) {
        Write-Host "  Herbert-Entscheidung: $($res.Decision.Method)$(if($res.Decision.Reason){" ($($res.Decision.Reason))"})" -ForegroundColor DarkCyan
    }

    # Kandidaten: Herbert-Funde zuerst, dann Web-Top (Score), Kataloge
    $cands = @()
    $seenU = @{}
    foreach ($u in @($res.AiUrls)) {
        $uu = ([string]$u).TrimEnd('/', '.')
        if ($uu -match '^https?://' -and -not $seenU.ContainsKey($uu)) { $seenU[$uu]=$true; $cands += [pscustomobject]@{ Url=$uu; Title='Herbert-Empfehlung'; Note='KI'; Score=99 } }
    }
    foreach ($h in @($res.Web | Sort-Object Score -Descending)) {
        $hu = ([string]$h.Url).TrimEnd('/')
        if ($hu -match '^https?://' -and -not $seenU.ContainsKey($hu)) {
            $seenU[$hu]=$true
            $cands += [pscustomobject]@{ Url=$hu; Title=([string]$h.Title); Note=([string]$h.Note); Score=[int]$h.Score }
        }
    }
    foreach ($w in @($res.Catalog | Select-Object -First 4)) {
        $wu = ([string]$w.Url).TrimEnd('/')
        if ($wu -match '^https?://' -and -not $seenU.ContainsKey($wu)) {
            $seenU[$wu]=$true
            $cands += [pscustomobject]@{ Url=$wu; Title=([string]$(if($w.Title){$w.Title}else{$w.Source})); Note=[string]$w.Source; Score=10 }
        }
    }
    $cands = @($cands | Select-Object -First 10)
    if ($cands.Count -eq 0) {
        Write-Host '  [!] Keine Download-Kandidaten gefunden.' -ForegroundColor Red
        return @{ Ok=$false; Path=$null; Url=''; AiText=[string]$res.AiText; Via='smart' }
    }
    if ($res.AiText) { Write-Host "  Herbert: $($res.AiText -split "`n" | Select-Object -First 1)" -ForegroundColor DarkCyan }

    $acts = @()
    foreach ($c in $cands) {
        $tag = 'u:' + $c.Url
        $lbl2 = $(if ($c.Title) { $c.Title } else { $c.Url })
        if ($lbl2.Length -gt 70) { $lbl2 = $lbl2.Substring(0,70) + '...' }
        $acts += @{ Label = "[$($c.Note)] $lbl2"; Color='White'; Tag = $tag }
    }
    $acts += @{ Label = 'Link im Browser oeffnen (manuell)'; Color='DarkGray'; Tag='open' }
    $acts += @{ Label = 'Abbrechen'; Color='DarkGray'; Tag='back' }
    $pick = Show-SysPilotArrowMenu -Items $acts -Title "SmartDownload: Download-Link fuer $lbl waehlen" -Footer 'Enter = Auswahl, Esc = Abbrechen'
    if ($null -eq $pick -or $pick -eq 'back') { return @{ Ok=$false; Path=$null; Url=''; AiText=[string]$res.AiText; Via='smart' } }
    if ($pick -eq 'open') {
        Start-Process $cands[0].Url
        return @{ Ok=$false; Path=$null; Url=$cands[0].Url; AiText=[string]$res.AiText; Via='browser' }
    }
    $pickUrl = ([string]$pick) -replace '^u:',''
    Write-Host "  Lade erneut von $pickUrl ..." -ForegroundColor Cyan
    if (Invoke-SysPilotFileDownload -Url $pickUrl -OutFile $OutFile -Label $lbl -TimeoutSec $TimeoutSec -Title $lbl) {
        return @{ Ok=$true; Path=$OutFile; Url=$pickUrl; AiText=[string]$res.AiText; Via='smart' }
    }
    Write-Host '  [!] Auch dieser Link fehlgeschlagen.' -ForegroundColor Red
    return @{ Ok=$false; Path=$null; Url=$pickUrl; AiText=[string]$res.AiText; Via='smart' }
}

function Install-SysPilotSmartPackage {
    <# Universeller Install-Einstieg (Herbert-decide):
       Find-SysPilotDownload (Goal=install) holt PM-Kandidaten,
       Kataloge, Web + Herberts Methoden-Entscheidung.
       - Decision.Method='pm'  -> Install-SysPilotPmPackage direkt
       - sonst 'smartdl'       -> bester Download-Kandidat wird
         heruntergeladen (Segment/aria2-Engine) und Pfad geliefert.
       Fuer 'torrent' -> Invoke-SysPilotTorrentDownload.
       Rueckgabe: @{Ok;Via;Path;Url;Detail;Decision;AiText} #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Id = '',
        [string]$ErrorText = '',
        [string]$OutDir = '',
        [int]$TimeoutSec = 900,
        [scriptblock]$OnProgress = $null
    )
    $say = { param($m) if ($OnProgress) { $null = & $OnProgress ([string]$m) } else { Write-Host "  $m" -ForegroundColor DarkGray } }
    if (-not $OutDir) { $OutDir = Join-Path $env:USERPROFILE 'Downloads\SysPilot' }
    if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

    $res = Find-SysPilotDownload -Name $Name -Id $Id -ErrorText $ErrorText -Goal 'install' -OnProgress $say
    if (-not $res -or -not $res.Ok) { return @{ Ok=$false; Via='none'; Path=$null; Url=''; Detail='Suche fehlgeschlagen'; Decision=$null; AiText='' } }
    $dec = $res.Decision
    & $say ("Herbert-Entscheidung: " + $(if($dec.Method){"$($dec.Method)$(if($dec.Manager){" via $($dec.Manager)"})$(if($dec.Package){" ($($dec.Package))"})"}else{'smartdl'}) + $(if($dec.Reason){" - $($dec.Reason)"}))

    # 1) Herbert entscheidet PM -> direkter Paketmanager-Install
    if ($dec.Method -eq 'pm' -and $dec.Manager -and $dec.Package) {
        Import-Module (Join-Path $PSScriptRoot 'PackageManagers.psm1') -Force -ErrorAction SilentlyContinue
        if (Get-Command Install-SysPilotPmPackage -ErrorAction SilentlyContinue) {
            & $say "Installiere via $($dec.Manager): $($dec.Package) ..."
            $mgrMap = @{ 'chocolatey'='choco'; 'powershell gallery'='psgallery'; 'psgallery'='psgallery'; 'dotnet tool'='dotnet' }
            $realMgr = $(if($mgrMap.ContainsKey([string]$dec.Manager)){$mgrMap[[string]$dec.Manager]}else{[string]$dec.Manager})
            if ($realMgr -in @('winget','choco','scoop','npm','pip','dotnet','psgallery')) {
                $r = Install-SysPilotPmPackage -Manager $realMgr -Id ([string]$dec.Package)
                if ($r.Ok) { return @{ Ok=$true; Via='pm'; Path=$null; Url="pm:$realMgr`:$($dec.Package)"; Detail="$realMgr : $($dec.Package) (Herbert)"; Decision=$dec; AiText=[string]$res.AiText } }
                & $say "[FAIL] PM $realMgr $($dec.Package): $($r.Error) - Fallback SmartDownload"
            }
        }
    }

    # 2) Torrent-Entscheidung
    if ($dec.Method -eq 'torrent') {
        $magnet = @($res.AiUrls + @($res.Web | ForEach-Object { $_.Url }) + @($res.Catalog | ForEach-Object { $_.Url })) |
                  Where-Object { $_ -match '^(magnet:|.*\.torrent)' } | Select-Object -First 1
        if ($magnet) {
            $r = Invoke-SysPilotTorrentDownload -Source $magnet -OutDir $OutDir -Label $Name -TimeoutSec 0 -ProgressQueue $null
            if ($r.Ok) { return @{ Ok=$true; Via='torrent'; Path=$OutDir; Url=$magnet; Detail="Torrent via aria2 -> $OutDir"; Decision=$dec; AiText=[string]$res.AiText } }
            & $say "[FAIL] Torrent: $($r.Error)"
        }
    }

    # 3) SmartDownload: Kandidaten priorisieren (Herbert-URLs > Web-Score > Katalog)
    $cands = @(); $seenU=@{}
    foreach ($u in @($res.AiUrls)) { $uu=([string]$u).TrimEnd('/','.'); if($uu -match '^https?://' -and -not $seenU[$uu]){$seenU[$uu]=$true;$cands+=[pscustomobject]@{Url=$uu;Title='Herbert-Empfehlung';Score=99}} }
    foreach ($h in @($res.Web | Sort-Object Score -Descending)) { $hu=([string]$h.Url).TrimEnd('/'); if($hu -match '^https?://' -and -not $seenU[$hu]){$seenU[$hu]=$true;$cands+=[pscustomobject]@{Url=$hu;Title=[string]$h.Title;Score=[int]$h.Score}} }
    foreach ($w in @($res.Catalog | Select-Object -First 4)) { $wu=([string]$w.Url).TrimEnd('/'); if($wu -match '^https?://' -and -not $seenU[$wu]){$seenU[$wu]=$true;$cands+=[pscustomobject]@{Url=$wu;Title=[string]$(if($w.Title){$w.Title}else{$w.Source});Score=10}} }
    $cands = @($cands | Select-Object -First 6)
    if ($cands.Count -eq 0) { return @{ Ok=$false; Via='none'; Path=$null; Url=''; Detail='Keine Download-Kandidaten'; Decision=$dec; AiText=[string]$res.AiText } }

    # Video-Page? -> yt-dlp
    foreach ($c in $cands) {
        $kind = Test-SysPilotSpecialDownloadUrl -Url $c.Url
        if ($kind -eq 'video') {
            & $say "Video-Quelle erkannt - yt-dlp-Download ..."
            $vr = Invoke-SysPilotVideoDownload -Url $c.Url -OutDir $OutDir -Label $Name
            if ($vr.Ok) { return @{ Ok=$true; Via='video'; Path=$vr.Path; Url=$c.Url; Detail="Video via yt-dlp"; Decision=$dec; AiText=[string]$res.AiText } }
        }
    }

    # Kandidaten nacheinander versuchen (Herbert-Top zuerst)
    $tried = @()
    foreach ($c in $cands) {
        $safe = ($c.Title -replace '[\\/:*?"<>|]','_')
        if ($safe.Length -gt 60) { $safe = $safe.Substring(0,60) }
        $out = Join-Path $OutDir ($safe + $(if($c.Url -match '\.msi(\?|$)'){' .msi'}elseif($c.Url -match '\.zip(\?|$)'){' .zip'}else{'.exe'}))
        & $say "SmartDownload: $($c.Title) ($($c.Url)) ..."
        $ok = Invoke-SysPilotFileDownload -Url $c.Url -OutFile $out -Label $Name -TimeoutSec $TimeoutSec -Title $Name
        if ($ok -and (Test-Path $out) -and ((Get-Item $out).Length -gt 0)) {
            return @{ Ok=$true; Via='smartdl'; Path=$out; Url=$c.Url; Detail="Download: $out"; Decision=$dec; AiText=[string]$res.AiText }
        }
        $tried += $c.Url
    }
    return @{ Ok=$false; Via='smartdl'; Path=$null; Url=''; Detail="Alle $($cands.Count) Kandidaten fehlgeschlagen"; Decision=$dec; AiText=[string]$res.AiText; Tried=$tried }
}

function Show-SysPilotAppSearchWindow {
    <# WPF-Programm-Suche: sucht in ALLEN installierten Paketmanagern
       (winget, choco, scoop, npm, pip, dotnet, PSGallery) UND parallel
       ueber SmartDownload (Web-Kataloge, Suchmaschinen, Herbert-KI).
       PM-Treffer sind direkt installierbar, Web-Treffer klickbar. #>
    param(
        [string]$InitialQuery = '',
        [string]$Category = '',
        [string]$Title = 'SysPilot - Programm-Suche',
        $Owner = $null
    )
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
        Write-Warning 'Show-SysPilotAppSearchWindow braucht STA.'
        return $false
    }
    try {
        [void][reflection.assembly]::LoadWithPartialName('PresentationFramework')
        [void][reflection.assembly]::LoadWithPartialName('PresentationCore')
        [void][reflection.assembly]::LoadWithPartialName('WindowsBase')
    } catch { }

    $script:_asQueue = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
    $script:_asObjQ  = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $script:_asProcPath=''; $script:_asProcOffset=0L
    $script:_asProgGoal=0; $script:_asCurLabel=$null; $script:_asJobT0=$null
    $script:_asBusy = $false
    $script:_asResults = @()
    $script:_asPending = New-Object 'System.Collections.Generic.Queue[object]'

    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$Title" Width="1040" Height="700" WindowStartupLocation="CenterScreen"
        ResizeMode="CanResizeWithGrip" Background="#FF1E1E2E" Foreground="#FFEAEAF2" FontFamily="Segoe UI">
  <Window.Resources>
    <Style TargetType="Button"><Setter Property="Background" Value="#FF2D2D44"/><Setter Property="Foreground" Value="#FFEAEAF2"/><Setter Property="BorderBrush" Value="#FF4A4A6A"/><Setter Property="Padding" Value="10,4"/><Setter Property="Margin" Value="3"/><Setter Property="Cursor" Value="Hand"/></Style>
    <Style TargetType="ListViewItem"><Setter Property="Padding" Value="6,3"/><Setter Property="Foreground" Value="#FFEAEAF2"/><Setter Property="FontSize" Value="11"/><Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#FF34344E"/></Trigger><Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#CCE4EAF2"/><Setter Property="Foreground" Value="#FF1E1E2E"/></Trigger></Style.Triggers></Style>
    <Style TargetType="GridViewColumnHeader"><Setter Property="Background" Value="#FF2D2D44"/><Setter Property="Foreground" Value="#FF4FC3F7"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Padding" Value="7,4"/><Setter Property="BorderBrush" Value="#FF4A4A6A"/><Setter Property="BorderThickness" Value="0,0,1,1"/></Style>
    <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#FFEAEAF2"/></Style>
    <Style TargetType="TextBox"><Setter Property="Background" Value="#FF252538"/><Setter Property="Foreground" Value="#FFEAEAF2"/><Setter Property="BorderBrush" Value="#FF4A4A6A"/><Setter Property="Padding" Value="6,4"/></Style>
    <ControlTemplate x:Key="ComboDarkToggle" TargetType="ToggleButton">
      <Border x:Name="Bg" Background="#FF252538" BorderBrush="#FF4A4A6A" BorderThickness="1" CornerRadius="2"/>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="BorderBrush" Value="#FF4FC3F7"/></Trigger>
        <Trigger Property="IsChecked" Value="True"><Setter Property="BorderBrush" Value="#FF4FC3F7"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate>
    <Style TargetType="ComboBox">
      <Setter Property="Background" Value="#FF252538"/><Setter Property="Foreground" Value="#FFEAEAF2"/>
      <Setter Property="BorderBrush" Value="#FF4A4A6A"/><Setter Property="Padding" Value="5,3"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton x:Name="ToggleButton" Focusable="False" ClickMode="Press"
                Template="{StaticResource ComboDarkToggle}"
                IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"/>
              <ContentPresenter x:Name="ContentSite" IsHitTestVisible="False"
                Content="{TemplateBinding SelectionBoxItem}"
                ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                ContentTemplateSelector="{TemplateBinding ItemTemplateSelector}"
                Margin="8,0,24,0" VerticalAlignment="Center" HorizontalAlignment="Left"/>
              <Path Data="M 0 0 L 4 4 L 8 0 Z" Fill="#FF9E9E9E" Width="8" Height="4"
                    HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,10,0"/>
              <Popup x:Name="Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}"
                     AllowsTransparency="True" Focusable="False" PopupAnimation="Slide">
                <Border Background="#FF1E1E2E" BorderBrush="#FF4A4A6A" BorderThickness="1"
                        MinWidth="{TemplateBinding ActualWidth}" MaxHeight="320">
                  <ScrollViewer><ItemsPresenter/></ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.55"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="#FFEAEAF2"/><Setter Property="Background" Value="Transparent"/>
      <Setter Property="Padding" Value="8,4"/>
      <Style.Triggers>
        <Trigger Property="IsHighlighted" Value="True"><Setter Property="Background" Value="#FF34344E"/><Setter Property="Foreground" Value="#FFEAEAF2"/></Trigger>
        <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#CCE4EAF2"/><Setter Property="Foreground" Value="#FF1E1E2E"/></Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="TabItem">
      <Setter Property="Foreground" Value="#FF9E9E9E"/><Setter Property="Padding" Value="14,7"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="Bd" Background="#FF252538" BorderBrush="#FF4A4A6A" BorderThickness="0,0,0,2" Padding="{TemplateBinding Padding}">
              <ContentPresenter ContentSource="Header" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter Property="Background" Value="#FF2D2D44" TargetName="Bd"/>
                <Setter Property="BorderBrush" Value="#FF4FC3F7" TargetName="Bd"/>
                <Setter Property="Foreground" Value="#FF4FC3F7"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True"><Setter Property="Foreground" Value="#FFEAEAF2"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <DockPanel Margin="12">
    <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,8">
      <TextBlock Text="Programm / App:" VerticalAlignment="Center" Margin="0,0,6,0"/>
      <TextBox x:Name="TxtQuery" Width="280" VerticalAlignment="Center"/>
      <TextBlock Text="Kategorie:" VerticalAlignment="Center" Margin="14,0,6,0"/>
      <ComboBox x:Name="KatBox" Width="150" VerticalAlignment="Center"/>
      <Button x:Name="BtnSearch" Content="Suchen" Width="90" Margin="16,0,0,0"/>
      <Button x:Name="BtnInstall" Content="Auswahl installieren" Width="140" Margin="10,0,0,0" ToolTip="Ausgewaehlten PM-Treffer ueber seinen Paketmanager installieren"/>
      <Button x:Name="BtnClose" Content="Schliessen" Width="90" HorizontalAlignment="Right"/>
    </StackPanel>
    <Border DockPanel.Dock="Bottom" Background="#FF16161F" BorderBrush="#FF4A4A6A" BorderThickness="0,1,0,0" Padding="8,6">
      <StackPanel>
        <ProgressBar x:Name="ProgBar" Height="4" IsIndeterminate="False" Minimum="0" Maximum="100" Value="0" Visibility="Collapsed" Margin="0,0,0,6" Foreground="#FF4FC3F7" Background="#FF2A2A3A"/>
        <Grid Margin="0,0,0,4">
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <ListBox x:Name="ResultList" Grid.Column="0" Height="56" Visibility="Collapsed" Background="#FF101018" BorderThickness="0" DisplayMemberPath="Label" ToolTip="Web/Katalog-Treffer - Doppelklick oeffnet den Link"/>
          <Button x:Name="BtnOpenLink" Grid.Column="1" Content="Link&#10;oeffnen" Visibility="Collapsed" Margin="5,0,0,0" VerticalAlignment="Stretch"/>
        </Grid>
        <RichTextBox x:Name="HerbBox" Height="100" IsReadOnly="True" Visibility="Collapsed"
                     Background="#FF101018" Foreground="#FFEAEAF2" BorderBrush="#FF2E4A2E"
                     FontFamily="Segoe UI" FontSize="12" Padding="8,6" Margin="0,6,0,0"
                     VerticalScrollBarVisibility="Auto" ToolTip="Herbert-Antwort - URLs sind klickbar"/>
        <TextBox x:Name="LogBox" Height="90" IsReadOnly="True" TextWrapping="NoWrap" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="11" Background="#FF0C0C14" Foreground="#FF9FE89F" BorderThickness="0" ToolTip="Live-Protokoll"/>
        <TextBlock x:Name="TxtStatus" FontSize="11" Foreground="#FF9E9E9E" Margin="0,5,0,0" TextWrapping="Wrap"/>
      </StackPanel>
    </Border>
    <TabControl Background="Transparent" BorderThickness="0">
      <TabItem Header="Paketmanager-Treffer">
        <ListView x:Name="PmList" SelectionMode="Extended" Background="#FF252538" BorderThickness="0">
          <ListView.View><GridView>
            <GridViewColumn Header="Manager" Width="110" DisplayMemberBinding="{Binding Manager}"/>
            <GridViewColumn Header="Paket / App" Width="280" DisplayMemberBinding="{Binding Name}"/>
            <GridViewColumn Header="ID" Width="200" DisplayMemberBinding="{Binding Id}"/>
            <GridViewColumn Header="Detail" Width="330" DisplayMemberBinding="{Binding Detail}"/>
          </GridView></ListView.View>
        </ListView>
      </TabItem>
      <TabItem Header="Web / Katalog / Herbert">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
          <ListView x:Name="WebList" SelectionMode="Single" Background="#FF252538" BorderThickness="0">
            <ListView.View><GridView>
              <GridViewColumn Header="Quelle" Width="110" DisplayMemberBinding="{Binding Tag}"/>
              <GridViewColumn Header="Treffer" Width="560" DisplayMemberBinding="{Binding Label}"/>
              <GridViewColumn Header="URL" Width="220" DisplayMemberBinding="{Binding Url}"/>
            </GridView></ListView.View>
          </ListView>
          <TextBlock Grid.Row="1" x:Name="WebHint" FontSize="11" Foreground="#FF9E9E9E" Margin="0,6,0,0" Text="Doppelklick auf einen Treffer oeffnet den Link. Herbert-Empfehlung unten."/>
        </Grid>
      </TabItem>
    </TabControl>
  </DockPanel>
</Window>
"@
    $win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$xaml)))
    if (Test-SysPilotWindowAlreadyOpen -Key 'syspilot-smartdl-install' -Win $win) { return }
    if ($Owner) { $win.Owner = $Owner } else { $win.WindowStartupLocation = 'CenterScreen' }
    $fc = @{}
    foreach ($n in 'TxtQuery','KatBox','BtnSearch','BtnInstall','BtnClose','TxtStatus','ProgBar','LogBox','ResultList','BtnOpenLink','HerbBox','PmList','WebList','WebHint') {
        $fc[$n] = $win.FindName($n)
    }

    $setStatus = { param($t,$col) $fc.TxtStatus.Text=$t; $fc.TxtStatus.Foreground=[Windows.Media.BrushConverter]::new().ConvertFrom($col) }
    $modDir = $PSScriptRoot

    $sayLog = {
        param([string]$line)
        if (-not $line) { return }
        # Fortschritts-Marker: ::PROG|idx/total|Art|name (name leer = fertig)
        if ($line -match '::PROG\|(\d+)/(\d+)\|([^|]*)\|(.*)$') {
            $pIdx=[int]$Matches[1]; $pTot=[int]$Matches[2]; $pKind=$Matches[3]; $pNm=$Matches[4].Trim()
            if ($pNm.Length -gt 60) { $pNm = $pNm.Substring(0,60) + '...' }
            $fc.ProgBar.IsIndeterminate=$false; $fc.ProgBar.Visibility='Visible'
            $fc.ProgBar.Minimum=0; $fc.ProgBar.Maximum=$pTot
            $isStart = ($pNm -ne '')
            $floor = $(if($isStart){[Math]::Max(0,$pIdx-1)}else{$pIdx})
            $fc.ProgBar.Value = $floor
            $script:_asProgGoal = $pIdx
            $script:_asCurLabel = $(if($pNm){"$pKind $pIdx/$pTot`: $pNm"}else{"$pKind $pIdx/$pTot"})
            if ($pNm) { $fc.TxtStatus.Text=$script:_asCurLabel; $fc.TxtStatus.Foreground=[Windows.Media.BrushConverter]::new().ConvertFrom('#FFB0B0C0') }
            return
        }
        Write-SysPilotPanelLog $line
        $fc.LogBox.AppendText($line + "`n")
        try { $fc.LogBox.ScrollToEnd() } catch {}
        if ($fc.LogBox.Text.Length -gt 120000) { $fc.LogBox.Text = $fc.LogBox.Text.Substring($fc.LogBox.Text.Length - 60000) }
    }
    $tailProc = {
        try {
            $logs = Get-ChildItem (Join-Path $env:TEMP 'syspilot-proc-*.log') -File -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -gt (Get-Date).AddSeconds(-30) } |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if (-not $logs) { return }
            if ($logs.FullName -ne $script:_asProcPath) { $script:_asProcPath=$logs.FullName; $script:_asProcOffset=0L }
            $len=$logs.Length; if($len -le $script:_asProcOffset){return}
            $fs=[IO.File]::Open($logs.FullName,'Open','Read','ReadWrite')
            try { $fs.Seek($script:_asProcOffset,'Begin')|Out-Null; $sr=New-Object IO.StreamReader($fs); $chunk=$sr.ReadToEnd() } finally { $fs.Close() }
            $script:_asProcOffset=$len
            foreach($l in ($chunk -split "`r?`n")){ & $sayLog $l }
        } catch {}
    }
    $drainAll = {
        $line=$null
        while ($script:_asQueue.TryDequeue([ref]$line)) { if($line){ & $sayLog ">> $line" }; $line=$null }
        $obj=$null
        while ($script:_asObjQ.TryDequeue([ref]$obj)) { if($obj){ & $applyObj $obj }; $obj=$null }
        & $tailProc
        # Sanftes Auffuellen + Live-%-Anzeige
        try {
            if ($script:_asBusy -and -not $fc.ProgBar.IsIndeterminate -and $fc.ProgBar.Visibility -eq 'Visible') {
                $goal = [double]$(if($null -ne $script:_asProgGoal){$script:_asProgGoal}else{0})
                $cur  = [double]$fc.ProgBar.Value
                $cap  = $goal - 0.15
                if ($cap -gt $cur) { $fc.ProgBar.Value = [Math]::Min($cap, $cur + ($cap - $cur) * 0.04 + 0.02) }
                if ($script:_asCurLabel) {
                    $pct = [int][Math]::Round($fc.ProgBar.Value / [Math]::Max(1.0,[double]$fc.ProgBar.Maximum) * 100)
                    $el  = ''
                    if ($script:_asJobT0) { try { $el = ' - ' + ((Get-Date) - $script:_asJobT0).ToString('mm\:ss') } catch {} }
                    $fc.TxtStatus.Text = "$($script:_asCurLabel)  [$pct%]$el"
                }
            }
        } catch {}
    }
    $applyObj = {
        param($o)
        if (-not $o -or -not $o.Type) { return }
        if ($o.Type -eq 'pm') {
            $disp = [pscustomobject]@{ Manager=[string]$o.Manager; Name=[string]$o.Name; Id=[string]$o.Id; Detail=[string]$o.Detail; Orig=$o }
            [void]$fc.PmList.Items.Add($disp)
        }
        elseif ($o.Type -eq 'search') {
            $script:_asResults=@()
            foreach($it in @($o.Items)){ $script:_asResults += $it }
            $fc.WebList.Items.Clear()
            foreach($it in $script:_asResults){ [void]$fc.WebList.Items.Add($it) }
            if ($o.AiText) { Set-SysPilotRichText -RichBox $fc.HerbBox -Text ([string]$o.AiText); $fc.HerbBox.Visibility='Visible' } else { $fc.HerbBox.Visibility='Collapsed' }
            & $setStatus "SmartDownload fertig: $($o.Stats.Pm) PM, $($o.Stats.Catalog) Katalog, $($o.Stats.Web) Web." '#FF81C784'
        }
        elseif ($o.Type -eq 'pmcount') {
            & $setStatus "Paketmanager: $($o.Count) Treffer - SmartDownload laeuft weiter ..." '#FFB0B0C0'
        }
        elseif ($o.Type -eq 'done') {
            $script:_asBusy=$false; $fc.ProgBar.Visibility='Collapsed'; $fc.ProgBar.IsIndeterminate=$false
            & $setStatus 'Suche abgeschlossen.' '#FF81C784'
        }
    }

    # Such-Job: PM-Suche (alle Manager) + SmartDownload (Kataloge/Web/KI)
    $script:_asRs=$null; $script:_asPs=$null; $script:_asAsync=$null
    $searchCode = @'
Import-Module (Join-Path $modDir 'Common.psm1') -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $modDir 'PackageManagers.psm1') -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $modDir 'SmartDownload.psm1') -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $modDir 'SoftwareUpdateCenter.psm1') -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $modDir 'AiAssist.psm1') -Force -ErrorAction SilentlyContinue
$q=$sdQueue; $oq=$sdObjQ
$say={param($m) if($q){$q.Enqueue([string]$m)}}
& $say "=== Programm-Suche: '$sdQuery' ==="
# 1) ALLE Paketmanager
$pmRes = @()
try { $pmRes = @(Get-SysPilotPmSearchResults -Query $sdQuery -OnProgress $say) } catch { & $say "PM-Suche Fehler: $($_.Exception.Message)" }
$seen=@{}
$n=0
foreach($r in $pmRes){
    $k = "$($r.Manager)|$($r.Id)".ToLower()
    if($seen.ContainsKey($k)){continue}; $seen[$k]=1
    $n++
    if($n -gt 60){break}
    $oq.Enqueue([pscustomobject]@{Type='pm';Manager=[string]$r.Manager;Id=[string]$r.Id;Name=[string]$r.Name;Detail=[string]$r.Detail})
}
& $say "Paketmanager: $n Treffer."
$oq.Enqueue([pscustomobject]@{Type='pmcount';Count=$n})
# 2) SmartDownload: Kataloge + Web + Herbert
try {
    $dl = Find-SysPilotDownload -Name $sdQuery -Category $sdCat -OnProgress $say
    $items=@()
    foreach($u in @($dl.AiUrls)){ $items += [pscustomobject]@{Tag='[ki]';Label='Herbert-Fundstelle';Url=$u} }
    foreach($h in @($dl.Web | Sort-Object Score -Descending | Select-Object -First 10)){ $items += [pscustomobject]@{Tag="[$($h.Engine)]";Label="$($h.Title) (Score $($h.Score))";Url=$h.Url} }
    foreach($w in @($dl.Catalog | Select-Object -First 8)){ $disp=$(if($w.Title){$w.Title}else{$w.Source}); $items += [pscustomobject]@{Tag="[$($w.Source)]";Label=$disp;Url=$w.Url} }
    foreach($p in @($dl.Pm | Select-Object -First 8)){ $items += [pscustomobject]@{Tag="pm:$($p.Kind)";Label=$p.Text;Url=''} }
    $oq.Enqueue([pscustomobject]@{Type='search';Items=$items;AiText=$dl.AiText;Stats=$dl.Stats})
} catch { & $say "SmartDownload Fehler: $($_.Exception.Message)" }
$oq.Enqueue([pscustomobject]@{Type='done'})
'@
    $script:_asSearchCode = $searchCode

    $beginSearch = {
        param($q,$catSel)
        $script:_asBusy=$true
        $script:_asQueue = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
        $script:_asObjQ  = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $fc.PmList.Items.Clear(); $fc.WebList.Items.Clear(); $fc.ResultList.Items.Clear()
        $fc.HerbBox.Visibility='Collapsed'; $fc.ResultList.Visibility='Collapsed'; $fc.BtnOpenLink.Visibility='Collapsed'
        $script:_asResults=@()
        & $sayLog "=== Programm-Suche: '$q' ==="
        $script:_asRs=[runspacefactory]::CreateRunspace(); $script:_asRs.ApartmentState='STA'; $script:_asRs.ThreadOptions='ReuseThread'; $script:_asRs.Open()
        $script:_asRs.SessionStateProxy.SetVariable('modDir',$modDir)
        $script:_asRs.SessionStateProxy.SetVariable('sdQueue',$script:_asQueue)
        $script:_asRs.SessionStateProxy.SetVariable('sdObjQ',$script:_asObjQ)
        $script:_asRs.SessionStateProxy.SetVariable('sdQuery',$q)
        $script:_asRs.SessionStateProxy.SetVariable('sdCat',$catSel)
        $script:_asPs=[powershell]::Create(); $script:_asPs.Runspace=$script:_asRs
        [void]$script:_asPs.AddScript($script:_asSearchCode)
        $script:_asAsync=$script:_asPs.BeginInvoke()
        $fc.ProgBar.Visibility='Visible'; $fc.ProgBar.IsIndeterminate=$true
        & $setStatus "Suche laeuft: $q (alle Paketmanager + SmartDownload) ..." '#FFB0B0C0'
    }

    $startSearch = {
        $q = ([string]$fc.TxtQuery.Text).Trim()
        if (-not $q) { & $setStatus 'Bitte einen Suchbegriff eingeben.' '#FFFFB74D'; return }
        $catSel = [string]$fc.KatBox.SelectedItem; if(-not $catSel){$catSel='Alle'}
        if ($script:_asBusy) {
            $script:_asPending.Enqueue(@{Kind='search';Q=$q;Cat=$catSel})
            & $setStatus "Warteschlange: $($script:_asPending.Count) Aktion(en) - 'Suche: $q' wartet." '#FFFFB74D'
            return
        }
        & $beginSearch $q $catSel
    }

    # Install-Job fuer einen PM-Treffer
    $instCode = @'
Import-Module (Join-Path $modDir 'Common.psm1') -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $modDir 'PackageManagers.psm1') -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $modDir 'SoftwareUpdateCenter.psm1') -Force -ErrorAction SilentlyContinue
$q=$sdQueue; $oq=$sdObjQ
$say={param($m) if($q){$q.Enqueue([string]$m)}}
$q.Enqueue('::PROG|1/1|Install|' + $instName)
& $say "Installiere $instMgr : $instId ..."
$r = Install-SysPilotPmPackage -Manager $instMgr -Id $instId
$finalOk = [bool]$r.Ok; $finalErr = [string]$r.Error
if(-not $finalOk){
  & $say "Fehlgeschlagen: $finalErr - Herbert Auto-Fix laeuft ..."
  try {
    Import-Module (Join-Path $modDir 'SmartDownload.psm1') -Force -ErrorAction SilentlyContinue
    if(Get-Command Invoke-SysPilotAutoInstallFix -ErrorAction SilentlyContinue){
      $fix = Invoke-SysPilotAutoInstallFix -AppName $instName -AppId $instId -FailedManager $instMgr -ErrorText $finalErr -OnProgress $say
      if($fix.Ok){$finalOk=$true;$finalErr="Auto-Fix: $($fix.Detail)"}
      else{$finalErr="Auto-Fix: $($fix.Detail)"}
    }
  } catch { & $say "Auto-Fix Fehler: $($_.Exception.Message)" }
}
$q.Enqueue('::PROG|1/1|Install|')
$oq.Enqueue([pscustomobject]@{Type='inst';Manager=$instMgr;Id=$instId;Ok=$finalOk;Err=$finalErr})
'@
    $beginInstall = {
        param($mgr,$id,$name)
        $script:_asBusy=$true
        $script:_asJobT0=Get-Date; $script:_asCurLabel=$null; $script:_asProgGoal=0
        $script:_asQueue = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
        $script:_asObjQ  = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $script:_asRs=[runspacefactory]::CreateRunspace(); $script:_asRs.ApartmentState='STA'; $script:_asRs.ThreadOptions='ReuseThread'; $script:_asRs.Open()
        $script:_asRs.SessionStateProxy.SetVariable('modDir',$modDir)
        $script:_asRs.SessionStateProxy.SetVariable('sdQueue',$script:_asQueue)
        $script:_asRs.SessionStateProxy.SetVariable('sdObjQ',$script:_asObjQ)
        $script:_asRs.SessionStateProxy.SetVariable('instMgr',$mgr)
        $script:_asRs.SessionStateProxy.SetVariable('instId',$id)
        $script:_asRs.SessionStateProxy.SetVariable('instName',$name)
        $script:_asPs=[powershell]::Create(); $script:_asPs.Runspace=$script:_asRs
        [void]$script:_asPs.AddScript($instCode)
        $script:_asAsync=$script:_asPs.BeginInvoke()
        $fc.ProgBar.Visibility='Visible'; $fc.ProgBar.IsIndeterminate=$true
        & $setStatus "Installiere $mgr : $id ..." '#FFB0B0C0'
    }
    $startInstall = {
        $w = $fc.PmList.SelectedItem
        if (-not $w) { & $setStatus 'Bitte zuerst einen PM-Treffer auswaehlen.' '#FFFFB74D'; return }
        $mgr=[string]$w.Manager; $id=[string]$w.Id
        if ($id -match 'install ') { & $setStatus 'pip-Hinweis - bitte manuell: pip install <name>' '#FFFFB74D'; return }
        $r=[System.Windows.MessageBox]::Show("$($w.Name)`nManager: $mgr`nID: $id`n`nInstallieren?",'Programm-Suche','YesNo','Question')
        if($r -ne 'Yes'){return}
        if ($script:_asBusy) {
            $script:_asPending.Enqueue(@{Kind='inst';Mgr=$mgr;Id=$id;Name=[string]$w.Name})
            & $setStatus "Warteschlange: $($script:_asPending.Count) Aktion(en) - 'Install: $($w.Name)' wartet." '#FFFFB74D'
            return
        }
        & $beginInstall $mgr $id ([string]$w.Name)
    }
    # 'inst'-Ergebnis in applyObj ergaenzen
    $applyObj2 = {
        param($o)
        if ($o -and $o.Type -eq 'inst') {
            $col = $(if($o.Ok){'#FF81C784'}else{'#FFFF5252'})
            & $setStatus "$(if($o.Ok){'[OK]'}else{'[FAIL]'}) $($o.Manager): $($o.Id) $(if(-not $o.Ok){$o.Err})" $col
            $script:_asBusy=$false; $script:_asCurLabel=$null
            $fc.ProgBar.IsIndeterminate=$false;$fc.ProgBar.Minimum=0;$fc.ProgBar.Maximum=100;$fc.ProgBar.Value=100
        } else { & $applyObj $o }
    }
    # drainAll nutzt $applyObj - umbiegen auf applyObj2 via Wrapper
    $drainAll = {
        $line=$null
        while ($script:_asQueue.TryDequeue([ref]$line)) { if($line){ & $sayLog ">> $line" }; $line=$null }
        $obj=$null
        while ($script:_asObjQ.TryDequeue([ref]$obj)) { if($obj){ & $applyObj2 $obj }; $obj=$null }
        & $tailProc
        # Warteschlange: naechste Aktion starten sobald frei
        try {
            if (-not $script:_asBusy -and $script:_asPending.Count -gt 0) {
                $pn = $script:_asPending.Dequeue()
                & $sayLog ">>> Warteschlange: $($pn.Kind)"
                if ($pn.Kind -eq 'inst') { & $beginInstall $pn.Mgr $pn.Id $pn.Name }
                else { & $beginSearch $pn.Q $pn.Cat }
            }
        } catch {}
    }

    # Kategorien fuellen
    [void]$fc.KatBox.Items.Add('Alle')
    try {
        if (-not (Get-Command Get-SysPilotUpdateCatalogCategories -ErrorAction SilentlyContinue)) { Import-SysPilotModule -Name 'SoftwareUpdateCenter' -ErrorAction SilentlyContinue }
        if (Get-Command Get-SysPilotUpdateCatalogCategories -ErrorAction SilentlyContinue) {
            foreach ($c in @(Get-SysPilotUpdateCatalogCategories)) { [void]$fc.KatBox.Items.Add($c) }
        }
    } catch {}
    if ($InitialQuery) { $fc.TxtQuery.Text=$InitialQuery }
    if ($Category -and $Category -ne 'Alle') {
        foreach($i in $fc.KatBox.Items){ if([string]$i -eq $Category){$fc.KatBox.SelectedItem=$i;break} }
    }
    if ($fc.KatBox.SelectedIndex -lt 0) { $fc.KatBox.SelectedIndex=0 }
    $fc.TxtQuery.Focus()

    $fc.BtnSearch.Add_Click({ & $startSearch })
    $fc.BtnInstall.Add_Click({ & $startInstall })
    $fc.BtnClose.Add_Click({ $win.Close() })
    $fc.TxtQuery.Add_KeyUp({ param($s,$e) if($e.Key -eq 'Enter'){ & $startSearch } })
    $fc.WebList.Add_MouseDoubleClick({
        $it=$fc.WebList.SelectedItem
        if($it -and $it.Url){ Start-Process ([string]$it.Url) }
    })
    $fc.ResultList.Add_MouseDoubleClick({
        $it=$fc.ResultList.SelectedItem
        if($it -and $it.Url){ Start-Process ([string]$it.Url) }
    })
    $fc.BtnOpenLink.Add_Click({
        $it=$fc.WebList.SelectedItem
        if($it -and $it.Url){ Start-Process ([string]$it.Url) }
    })

    $poll = New-Object System.Windows.Threading.DispatcherTimer
    $poll.Interval=[timespan]::FromMilliseconds(200)
    $poll.Add_Tick({
        & $drainAll
        if ($script:_asAsync -and $script:_asAsync.IsCompleted -and $script:_asBusy) {
            try { $null=@($script:_asPs.EndInvoke($script:_asAsync)) } catch { & $sayLog "Job-Fehler: $($_.Exception.Message)" }
            try{$script:_asPs.Dispose()}catch{}
            try{$script:_asRs.Close();$script:_asRs.Dispose()}catch{}
            $script:_asPs=$null;$script:_asRs=$null;$script:_asAsync=$null
            # 'done' kommt evtl. nicht (install-job) -> busy ruecksetzen falls noetig
            if ($fc.ProgBar.IsIndeterminate) { $script:_asBusy=$false; $fc.ProgBar.Visibility='Collapsed' }
        }
    }.GetNewClosure())
    $win.Add_Closing({
        $poll.Stop()
        if ($script:_asAsync) { try{$script:_asPs.Stop();$script:_asPs.Dispose();$script:_asRs.Close();$script:_asRs.Dispose()}catch{} }
    })
    $poll.Start()
    Set-SysPilotWindowAutoSize -Win $win -MinWidth 1000 -MinHeight 640
    if ($InitialQuery) { & $startSearch }
    Add-SysPilotAssistantToWindow -Win $win -Context 'Show-SysPilotAppSearchWindow'
    [void]$win.ShowDialog()
    return $true
}

function Invoke-SysPilotInstallAssist {
    <# Herbert-basierter Installations-Assistent: schlaegt fuer eine App
       die besten Install-Wege vor - Paketmanager-IDs, Konsolenbefehle
       (mit Silent-Flags) oder Download-Links. Liest den Antworttext
       strukturiert aus (PM|/CMD|/LINK|-Zeilen). #>
    param(
        [Parameter(Mandatory)][string]$AppName,
        [string]$AppId = '',
        [string]$ErrorText = '',
        [string]$PageUrl = '',
        [int]$TimeoutSec = 120,
        [scriptblock]$OnProgress = { param($m) }
    )
    $say = $OnProgress
    & $say "Herbert wird gefragt: Installationsweg fuer '$AppName' (kann 30-90s dauern) ..."
    Import-Module (Join-Path $PSScriptRoot 'AiAssist.psm1') -Force -ErrorAction SilentlyContinue
    if (-not (Get-Command Invoke-SysPilotAiChat -ErrorAction SilentlyContinue)) {
        return @{ Ok=$false; Error='Ki-Modul nicht verfuegbar'; AiText=''; Pm=@(); Cmd=@(); Links=@() }
    }
    $mgrList = 'winget, chocolatey (choco), scoop, npm, pip, dotnet, PowerShell Gallery'
    $prompt = @"
Du bist Herbert, der Installations-Assistent von SysPilot (Windows-Tool).
Finde den besten Installationsweg fuer diese App.

App: $AppName
ID/Hinweis: $(if($AppId){$AppId}else{'-'})
Fehler/Problem: $(if($ErrorText){$ErrorText}else{'-'})
Bekannte Seite: $(if($PageUrl){$PageUrl}else{'-'})
Verfuegbare Paketmanager: $mgrList

Antworte KURZ und PRUEFBAR auf Deutsch. Fuer JEDE Empfehlung eine Zeile im Format:
PM|<manager>|<paket-id oder befehl>|<ein halber Satz Notiz>
CMD|<vollstaendiger Konsolenbefehl>|<notiz>
LINK|<direkter download-link>|<notiz>

Regeln:
- PM nur mit echten, gaengigen Paket-IDs (z.B. winget search-Namen wie 'VideoLAN.VLC').
- CMD nur sichere Standardbefehle (winget install, choco install, scoop install, npm i -g, pip install, dotnet tool install -g) - Silent-Flags wenn sinnvoll.
- LINK nur offizielle/direct-download URLs, keine Suchmaschinen.
- Wenn die App nur als Quelltext existiert: sage das ehrlich, rate keinen Fake-Download.
- Maximal 6 Zeilen PM/CMD/LINK insgesamt, danach 2-3 Saetze Erklaerung.
"@
    $ai = Invoke-SysPilotAiChat -Prompt $prompt -TimeoutSec $TimeoutSec
    if (-not $ai.Ok) {
        & $say "Herbert nicht erreichbar: $($ai.Error)"
        return @{ Ok=$false; Error=[string]$ai.Error; AiText=''; Pm=@(); Cmd=@(); Links=@() }
    }
    $txt = [string]$ai.Text
    $pm=@(); $cmds=@(); $links=@()
    foreach ($line in ($txt -split "`r?`n")) {
        $l = $line.Trim()
        if ($l -match '^(?i)PM\s*\|\s*([^|]+)\|\s*([^|]+)\|\s*(.*)$') {
            $pm += [pscustomobject]@{ Manager=$Matches[1].Trim().ToLower(); Id=$Matches[2].Trim(); Note=$Matches[3].Trim() }
        } elseif ($l -match '^(?i)CMD\s*\|\s*([^|]+)\|\s*(.*)$') {
            $cmds += [pscustomobject]@{ Command=$Matches[1].Trim(); Note=$Matches[2].Trim() }
        } elseif ($l -match '^(?i)LINK\s*\|\s*(https?://\S+)\s*\|?\s*(.*)$') {
            $u = $Matches[1].TrimEnd('.',',',';')
            if ($u -notmatch 'perplexity|duckduckgo\.com/\?q|gemini|copilot|youtube\.com/(watch|results)|facebook') {
                $links += [pscustomobject]@{ Url=$u; Note=$Matches[2].Trim() }
            }
        }
    }
    & $say "Herbert fertig: $($pm.Count) PM-Vorschlaege, $($cmds.Count) Befehle, $($links.Count) Links"
    return @{ Ok=$true; AiText=$txt; Pm=$pm; Cmd=$cmds; Links=$links }
}

function Test-SysPilotSafeInstallCmd {
    <# Prueft, ob ein Konsolenbefehl aus der White-List kommt und keine
       gefaehrlichen Metazeichen enthaelt. #>
    param([Parameter(Mandatory)][string]$Command)
    $c = $Command.Trim()
    if (-not $c) { return $false }
    if ($c -match '[;&|`<>]|\$\(|\$\{') { return $false }
    if ($c -match '(?i)\b(rm|del|erase|format|shutdown|restart|reg\s+(add|delete|import)|net\s+(user|localgroup)|cipher\s+/w|bcdedit|diskpart|takeown|icacls\s+/reset)\b') { return $false }
    $first = ($c -split '\s+')[0].ToLower()
    $first = $first -replace '\.exe$',''
    return ($first -in @('winget','choco','scoop','npm','pip','python','py','dotnet','msiexec','7z','tar','git'))
}

function Invoke-SysPilotAutoInstallFix {
    <# Selbsttaetiger Install-Fix: bei einem fehlgeschlagenen
       Paketmanager-Install wird Herbert automatisch befragt und
       der beste Vorschlag DIREKT angewendet - zuerst PM-IDs
       (auch Alternativen zum Manager), dann sichere Konsolen-
       befehle. Nicht loesbare Faelle liefern die Links fuer den
       Nutzer. #>
    param(
        [Parameter(Mandatory)][string]$AppName,
        [string]$AppId = '',
        [string]$FailedManager = '',
        [string]$ErrorText = '',
        [string]$PageUrl = '',
        [scriptblock]$OnProgress = { param($m) }
    )
    $say = $OnProgress
    Import-Module (Join-Path $PSScriptRoot 'PackageManagers.psm1') -Force -ErrorAction SilentlyContinue
    $res = Invoke-SysPilotInstallAssist -AppName $AppName -AppId $AppId -ErrorText $ErrorText -PageUrl $PageUrl -OnProgress $say
    if (-not $res.Ok) { return @{ Action='none'; Ok=$false; Detail="Herbert nicht erreichbar: $($res.Error)"; Links=@() } }

    # 1) PM-Vorschlaege: ersten versuchen, der nicht der fehlgeschlagene ist
    foreach ($p in @($res.Pm)) {
        $mgr = [string]$p.Manager
        $id  = [string]$p.Id
        if (-not $mgr -or -not $id) { continue }
        if ($mgr -eq $FailedManager -and $id -eq $AppId) { continue }   # exakt der Fehlschlag
        $mgrMap = @{ 'chocolatey'='choco'; 'powershell gallery'='psgallery'; 'psgallery'='psgallery' }
        $realMgr = $(if($mgrMap.ContainsKey($mgr)){$mgrMap[$mgr]}else{$mgr})
        if ($realMgr -notin @('winget','choco','scoop','npm','pip','dotnet','psgallery')) { continue }
        & $say "Auto-Fix: versuche $realMgr : $id (Herbert-Vorschlag) ..."
        try {
            $r = Install-SysPilotPmPackage -Manager $realMgr -Id $id
            if ($r.Ok) {
                & $say "[OK] Auto-Fix erfolgreich: $realMgr $id"
                return @{ Action='pm'; Ok=$true; Detail="$realMgr : $id"; Links=@($res.Links) }
            }
            & $say "[FAIL] Auto-Fix $realMgr $id : $($r.Error)"
        } catch { & $say "[FAIL] Auto-Fix $realMgr : $($_.Exception.Message)" }
    }

    # 2) Sicherer Konsolenbefehl (White-List)
    foreach ($c in @($res.Cmd)) {
        $cmd = [string]$c.Command
        if (-not (Test-SysPilotSafeInstallCmd $cmd)) { continue }
        & $say "Auto-Fix: fuehre Befehl aus: $cmd"
        try {
            $out = & cmd.exe /c $cmd 2>&1 | Out-String
            $tail = ($out -split "`r?`n" | Select-Object -Last 5) -join ' | '
            & $say "Befehl-Ausgabe: $tail"
            if ($LASTEXITCODE -eq 0 -or $out -match '(?i)success|installed|already') {
                return @{ Action='cmd'; Ok=$true; Detail=$cmd; Links=@($res.Links) }
            }
        } catch { & $say "[FAIL] Befehl: $($_.Exception.Message)" }
    }

    # 3) SmartDownload-Fallback: Herbert entscheidet PM vs Download,
    #    Kandidaten werden automatisch durchprobiert (Segment/aria2).
    & $say 'Auto-Fix: SmartDownload-Suche mit Herbert-Entscheidung ...'
    $dlDir = Join-Path $env:TEMP 'SysPilot\autodl'
    try {
        $sp = Install-SysPilotSmartPackage -Name $AppName -Id $AppId -ErrorText $ErrorText -OutDir $dlDir -TimeoutSec 900 -OnProgress $say
        if ($sp.Ok) {
            if ($sp.Via -eq 'pm') { return @{ Action='pm'; Ok=$true; Detail=$sp.Detail; Links=@($res.Links); AiText=[string]$res.AiText } }
            if ($sp.Via -eq 'smartdl' -or $sp.Via -eq 'torrent' -or $sp.Via -eq 'video') {
                return @{ Action='downloaded'; Ok=$false; Detail="Installer liegt unter: $($sp.Path)"; Path=$sp.Path; Url=$sp.Url; Links=@($res.Links); AiText=[string]$res.AiText }
            }
        }
        foreach ($l in @($sp.Links) | Where-Object { $_ }) { if ($l -notin @($res.Links)) { $res.Links += $l } }
        if (-not $sp.Ok -and $sp.AiText) { $res.AiText = [string]$sp.AiText }
    } catch { & $say "[FAIL] SmartDownload: $($_.Exception.Message)" }

    # 4) Nichts Automatisches - Links fuer den Nutzer
    & $say 'Auto-Fix: kein sicherer automatischer Weg - Herbert-Vorschlaege bleiben manuell.'
    return @{ Action='manual'; Ok=$false; Detail='Keine automatische Installation moeglich'; Links=@($res.Links); AiText=[string]$res.AiText }
}

function Show-SysPilotInstallAssistWindow {
    <# WPF-Fenster des Install-Assistenten: Felder + Herbert-Antwort +
       strukturierte Vorschlaege (PM-Install / Befehl ausfuehren /
       Befehl kopieren / Link oeffnen). #>
    param(
        [string]$AppName = '',
        [string]$AppId = '',
        [string]$ErrorText = '',
        [string]$PageUrl = '',
        [string]$Title = 'Install-Assistent (Herbert)',
        $Owner = $null
    )
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
        Write-Warning 'Show-SysPilotInstallAssistWindow braucht STA.'
        return $false
    }
    try {
        [void][reflection.assembly]::LoadWithPartialName('PresentationFramework')
        [void][reflection.assembly]::LoadWithPartialName('PresentationCore')
        [void][reflection.assembly]::LoadWithPartialName('WindowsBase')
    } catch {}

    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$Title" Width="860" Height="620" WindowStartupLocation="CenterOwner"
        Background="#FF1E1E2E" Foreground="#FFEAEAF2" FontFamily="Segoe UI">
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
  </Window.Resources>
  <Grid Margin="14">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="150"/>
    </Grid.RowDefinitions>
    <StackPanel Orientation="Horizontal" Grid.Row="0" Margin="0,0,0,8">
      <TextBlock Text="App:" VerticalAlignment="Center" Margin="0,0,6,0"/>
      <TextBox x:Name="TxtName" Width="220" VerticalAlignment="Center"/>
      <TextBlock Text="ID:" VerticalAlignment="Center" Margin="12,0,6,0"/>
      <TextBox x:Name="TxtId" Width="200" VerticalAlignment="Center"/>
      <TextBlock Text="Seite:" VerticalAlignment="Center" Margin="12,0,6,0"/>
      <TextBox x:Name="TxtPage" Width="200" VerticalAlignment="Center"/>
      <Button x:Name="BtnAsk" Content="Herbert fragen" Width="120" Margin="16,0,0,0"/>
      <Button x:Name="BtnClose" Content="Schliessen" Width="90" Margin="8,0,0,0"/>
    </StackPanel>
    <TextBox x:Name="TxtCtx" Grid.Row="1" Height="40" Margin="0,0,0,8" IsReadOnly="True"
             TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Background="#FF14141E"
             Foreground="#FFB0B0C0" FontFamily="Consolas" FontSize="11"/>
    <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,0,0,6">
      <TextBlock x:Name="TxtStatus" Text="Bereit - Felder fuellen und 'Herbert fragen' klicken." Foreground="#FFB0B0C0" VerticalAlignment="Center"/>
      <ProgressBar x:Name="ProgBar" Width="200" Height="8" Margin="16,0,0,0" VerticalAlignment="Center" Visibility="Collapsed" IsIndeterminate="True"/>
    </StackPanel>
    <Grid Grid.Row="3" Margin="0,0,0,8">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/><ColumnDefinition Width="10"/><ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <Border Background="#FF101018" CornerRadius="4" Padding="8">
        <DockPanel>
          <TextBlock DockPanel.Dock="Top" Text="Herbert-Antwort" FontWeight="Bold" Foreground="#FF9CCC65" Margin="0,0,0,4"/>
          <RichTextBox x:Name="HerbBox" IsReadOnly="True" Background="Transparent" BorderThickness="0"
                       Foreground="#FFEAEAF2" FontFamily="Segoe UI" FontSize="12"
                       VerticalScrollBarVisibility="Auto"/>
        </DockPanel>
      </Border>
      <Border Grid.Column="2" Background="#FF14141E" CornerRadius="4" Padding="8">
        <DockPanel>
          <TextBlock DockPanel.Dock="Top" Text="Vorschlaege" FontWeight="Bold" Foreground="#FF4FC3F7" Margin="0,0,0,4"/>
          <ListBox x:Name="SugList" Background="Transparent" BorderThickness="0" DisplayMemberPath="Label"/>
        </DockPanel>
      </Border>
    </Grid>
    <StackPanel Grid.Row="4" Orientation="Horizontal" Margin="0,0,0,8">
      <Button x:Name="BtnAutoFix" Content="Auto-Fix" Width="90" Margin="8,0,0,0" ToolTip="Herbert analysiert den Fehler und wendet die beste Loesung direkt an (PM-Install oder sicherer Befehl)"/>
      <Button x:Name="BtnInstall" Content="PM installieren" Width="130" IsEnabled="False" ToolTip="Ausgewaehlten PM-Vorschlag installieren"/>
      <Button x:Name="BtnRun" Content="Befehl ausfuehren" Width="130" Margin="8,0,0,0" IsEnabled="False" ToolTip="Ausgewaehlten Konsolenbefehl ausfuehren (nur sichere PM-Befehle)"/>
      <Button x:Name="BtnCopy" Content="Befehl kopieren" Width="130" Margin="8,0,0,0" IsEnabled="False"/>
      <Button x:Name="BtnOpen" Content="Link oeffnen" Width="110" Margin="8,0,0,0" IsEnabled="False"/>
    </StackPanel>
    <TextBox x:Name="LogBox" Grid.Row="5" IsReadOnly="True" TextWrapping="Wrap"
             VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
             Background="#FF0E140E" Foreground="#FF9CCC65" FontFamily="Consolas" FontSize="11"
             BorderBrush="#FF2E4A2E" AcceptsReturn="True"/>
  </Grid>
</Window>
"@
    $win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$xaml)))
    if (Test-SysPilotWindowAlreadyOpen -Key 'syspilot-install-assist' -Win $win) { return }
    if ($Owner) { try { $win.Owner=$Owner } catch {} }
    $fc = @{}
    foreach ($n in 'TxtName','TxtId','TxtPage','TxtCtx','BtnAsk','BtnAutoFix','BtnClose','TxtStatus','ProgBar','HerbBox','SugList','BtnInstall','BtnRun','BtnCopy','BtnOpen','LogBox') {
        $fc[$n] = $win.FindName($n)
    }
    $fc.TxtName.Text=$AppName; $fc.TxtId.Text=$AppId; $fc.TxtPage.Text=$PageUrl
    if($ErrorText){ $fc.TxtCtx.Text="Kontext: $ErrorText" }
    elseif($PageUrl){ $fc.TxtCtx.Text="Kontext: Seite $PageUrl" }

    $script:_iaQueue = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
    $sayLog = { param($l) if($l){ Write-SysPilotPanelLog $l; $fc.LogBox.AppendText([string]$l+"`n"); try{$fc.LogBox.ScrollToEnd()}catch{} } }
    $setStatus = { param($t,$c) $fc.TxtStatus.Text=[string]$t; $fc.TxtStatus.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString($c) }
    $drainQ = { $l=$null; while($script:_iaQueue.TryDequeue([ref]$l)){ & $sayLog $l; $l=$null } }
    $modDir = $PSScriptRoot

    # Vorschlaege als Items (Tag = Rohobjekt)
    $fillSug = {
        param($res)
        $fc.SugList.Items.Clear()
        foreach($p in @($res.Pm)){    [void]$fc.SugList.Items.Add([pscustomobject]@{Kind='pm';   Label="PM $($p.Manager): $($p.Id) - $($p.Note)"; Raw=$p}) }
        foreach($c in @($res.Cmd)){   [void]$fc.SugList.Items.Add([pscustomobject]@{Kind='cmd';  Label="CMD: $($c.Command) - $($c.Note)"; Raw=$c}) }
        foreach($l in @($res.Links)){ [void]$fc.SugList.Items.Add([pscustomobject]@{Kind='link'; Label="LINK: $($l.Url) - $($l.Note)"; Raw=$l}) }
    }
    $updateButtons = {
        $it = $fc.SugList.SelectedItem
        $fc.BtnInstall.IsEnabled = ($it -and $it.Kind -eq 'pm')
        $fc.BtnRun.IsEnabled     = ($it -and $it.Kind -eq 'cmd')
        $fc.BtnCopy.IsEnabled    = ($it -and $it.Kind -eq 'cmd')
        $fc.BtnOpen.IsEnabled    = ($it -and ($it.Kind -eq 'link' -or ($it.Raw.Url)))
    }
    $fc.SugList.Add_SelectionChanged({ & $updateButtons })

    $busy=$false;$rs=$null;$ps=$null;$async=$null
    $pendQ=New-Object 'System.Collections.Generic.Queue[object]'
    $stopJob = { if($async){try{$ps.Stop();$ps.Dispose()}catch{};try{$rs.Close();$rs.Dispose()}catch{}};$async=$null;$rs=$null;$ps=$null }

    $jobCode = @'
$modDir = $modDirVar
$q = $iaQueue
$say = { param($m) if($q){$q.Enqueue([string]$m)} }
try {
    Import-Module (Join-Path $modDir 'Common.psm1') -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $modDir 'SmartDownload.psm1') -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $modDir 'AiAssist.psm1') -Force -ErrorAction SilentlyContinue
    $res = Invoke-SysPilotInstallAssist -AppName $appName -AppId $appId -ErrorText $errText -PageUrl $pageUrl -OnProgress $say
    @{ Ok=$true; Res=$res }
} catch { @{ Ok=$false; Error=$_.Exception.Message } }
'@
    # Gemeinsamer Job-Start fuer 'ask' (Herbert-Vorschlaege) und 'fix'
    # (Auto-Fix). Params werden beim Klick aufgeloest - queue-faehig.
    $runJob = {
        param($kind,$appName,$appId,$errText,$pageUrl)
        $busy=$true
        $script:_iaQueue = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
        $fc.ProgBar.Visibility='Visible'
        $rs=[runspacefactory]::CreateRunspace();$rs.ApartmentState='STA';$rs.ThreadOptions='ReuseThread';$rs.Open()
        $rs.SessionStateProxy.SetVariable('modDirVar',$modDir)
        $rs.SessionStateProxy.SetVariable('iaQueue',$script:_iaQueue)
        $rs.SessionStateProxy.SetVariable('appName',$appName)
        $rs.SessionStateProxy.SetVariable('appId',$appId)
        $rs.SessionStateProxy.SetVariable('errText',$errText)
        $rs.SessionStateProxy.SetVariable('pageUrl',$pageUrl)
        $ps=[powershell]::Create();$ps.Runspace=$rs
        [void]$ps.AddScript($(if($kind -eq 'fix'){$fixCode}else{$jobCode}))
        $script:_iaJobKind=$kind
        $async=$ps.BeginInvoke()
        & $setStatus $(if($kind -eq 'fix'){'Auto-Fix: Herbert analysiert und handelt ...'}else{'Herbert denkt nach ...'}) '#FFB0B0C0'
    }
    $startAsk = {
        if(-not $fc.TxtName.Text.Trim()){& $setStatus 'Bitte einen App-Namen eingeben.' '#FFFFB74D';return}
        $fc.HerbBox.Document.Blocks.Clear(); $fc.SugList.Items.Clear()
        $n=$fc.TxtName.Text.Trim();$i=$fc.TxtId.Text.Trim();$e=$fc.TxtCtx.Text.Trim();$p=$fc.TxtPage.Text.Trim()
        if($busy){ $pendQ.Enqueue(@{Kind='ask';Name=$n;Id=$i;Err=$e;Page=$p}); & $setStatus "Warteschlange: $($pendQ.Count) Aktion(en) - 'Herbert: $n' wartet." '#FFFFB74D'; return }
        & $runJob 'ask' $n $i $e $p
    }
    $fc.BtnAsk.Add_Click({ & $startAsk })
    # Auto-Fix: eigener Job - Herbert analysiert UND wendet an
    $fixCode = @'
$modDir = $modDirVar
$q = $iaQueue
$say = { param($m) if($q){$q.Enqueue([string]$m)} }
try {
    Import-Module (Join-Path $modDir 'Common.psm1') -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $modDir 'SmartDownload.psm1') -Force -ErrorAction SilentlyContinue
    $fix = Invoke-SysPilotAutoInstallFix -AppName $appName -AppId $appId -ErrorText $errText -PageUrl $pageUrl -OnProgress $say
    @{ Ok=$true; Fix=$fix }
} catch { @{ Ok=$false; Error=$_.Exception.Message } }
'@
    $fc.BtnAutoFix.Add_Click({
        if(-not $fc.TxtName.Text.Trim()){& $setStatus 'Bitte App-Namen eingeben.' '#FFFFB74D';return}
        $r=[System.Windows.MessageBox]::Show("Herbert analysiert den Fehler und wendet die beste Loesung DIREKT an (PM-Install oder sicherer Befehl).`n`nApp: $($fc.TxtName.Text)`n`nFortfahren?",'Auto-Fix','YesNo','Question')
        if($r -ne 'Yes'){return}
        $n=$fc.TxtName.Text.Trim();$i=$fc.TxtId.Text.Trim();$e=$fc.TxtCtx.Text.Trim();$p=$fc.TxtPage.Text.Trim()
        if($busy){ $pendQ.Enqueue(@{Kind='fix';Name=$n;Id=$i;Err=$e;Page=$p}); & $setStatus "Warteschlange: $($pendQ.Count) Aktion(en) - 'Auto-Fix: $n' wartet." '#FFFFB74D'; return }
        & $runJob 'fix' $n $i $e $p
    })
    $fc.BtnClose.Add_Click({$win.Close()})
    $fc.TxtName.Add_KeyDown({ param($s,$ev) if($ev.Key -eq 'Return'){& $startAsk} })

    $poll = New-Object System.Windows.Threading.DispatcherTimer
    $poll.Interval=[timespan]::FromMilliseconds(400)
    $poll.Add_Tick({
        & $drainQ
        if(-not $async){$poll.Stop();return}
        if($async.IsCompleted){
            $poll.Stop();& $drainQ
            $out=@()
            try{$out=@($ps.EndInvoke($async))}catch{& $setStatus "Job-Fehler: $($_.Exception.Message)" '#FFEF5350'}
            & $stopJob
            $busy=$false;$fc.ProgBar.Visibility='Collapsed'
            $o=$out | Where-Object {$_ -is [hashtable]} | Select-Object -First 1
            if($script:_iaJobKind -eq 'fix'){
                $script:_iaJobKind='ask'
                if($o -and $o['Ok'] -and $o['Fix']){
                    $fx=$o['Fix']
                    $col = $(if($fx.Ok){'#FF81C784'}else{'#FFFFB74D'})
                    & $setStatus "Auto-Fix: $(if($fx.Ok){'ERFOLGREICH'}else{'manuell noetig'}) - $($fx.Detail)" $col
                    if($fx.Links){ foreach($l in @($fx.Links)){ & $sayLog "Link: $($l.Url)" } }
                } else {
                    & $setStatus "Auto-Fix Fehler: $(if($o){$o['Error']}else{'unbekannt'})" '#FFFF5252'
                }
            } elseif($o -and $o['Ok'] -and $o['Res'].Ok){
                $res=$o['Res']
                $fc.HerbBox.Document.Blocks.Clear() | Out-Null
                $tb = New-Object Windows.Documents.Paragraph
                $tb.Inlines.Add([Windows.Documents.Run]::new([string]$res.AiText))
                [void]$fc.HerbBox.Document.Blocks.Add($tb)
                & $fillSug $res
                & $updateButtons
                & $setStatus "Fertig: $($fc.SugList.Items.Count) Vorschlaege." '#FF81C784'
            } elseif($o -and $o['Res'] -and -not $o['Res'].Ok){
                & $setStatus "Herbert: $($o['Res'].Error)" '#FFFFB74D'
            } else {
                & $setStatus "Fehler: $(if($o){$o['Error']}else{'unbekannt'})" '#FFFF5252'
            }
            # Warteschlange: naechste Aktion starten
            if($pendQ.Count -gt 0){ $pn=$pendQ.Dequeue(); & $sayLog ">>> Warteschlange: $($pn.Kind)"; & $runJob $pn.Kind $pn.Name $pn.Id $pn.Err $pn.Page }
        }
    }.GetNewClosure())
    $win.Add_Closing({ $poll.Stop(); & $stopJob })
    $poll.Start()
    Add-SysPilotAssistantToWindow -Win $win -Context 'Show-SysPilotInstallAssistWindow'
    [void]$win.ShowDialog()
    return $true
}

Export-ModuleMember -Function Find-SysPilotWebResults, Get-SysPilotSmartDlScore,
    Find-SysPilotCodeRepoHits, Find-SysPilotDownload, Show-SysPilotDownloadFinder,
    Show-SysPilotAppSearchWindow, Save-SysPilotSmartDownload,
    Install-SysPilotSmartPackage, Invoke-SysPilotInstallAssist, Show-SysPilotInstallAssistWindow,
    Invoke-SysPilotAutoInstallFix
