# SmartDrivers.psm1 - KI-Pseudo-Paketmanager fuer TREIBER:
# orchestrierte Treiber-Suche ueber Windows Update, MS Update
# Catalog, Treiber-Kataloge (TechPowerUp, Guru3D, Station-Drivers,
# MajorGeeks), Suchmaschinen (DDG/Bing) und Herbert-KI.
#
# Architektur spiegelt SmartDownload: Find-SysPilotDriver startet
# parallele Kind-Runspaces (wu/cat/web), sammelt Funde und laesst
# Herbert in Phase 2 den besten Treiber-Link waehlen. Die
# Treiber-Werkstatt (Drivers.psm1) bindet das per Knopfdruck ein.

$script:SmartDrvJunkDomains = @(
    'youtube.com','youtu.be','facebook.com','instagram.com','tiktok.com',
    'pinterest.com','reddit.com','quora.com','linkedin.com','twitter.com',
    'x.com','amazon.','ebay.','aliexpress.','wikipedia.org','wikihow.com',
    'medium.com','blogspot.','wordpress.com','tumblr.com','9gag.com',
    'twitch.tv','discord.','telegram.','whatsapp.com','spotify.com',
    'google.com/search','bing.com/search','duckduckgo.com'
)
$script:SmartDrvCatalogDomains = @(
    'station-drivers.com','guru3d.com','techpowerup.com','majorgeeks.com',
    'driverscloud.com','softpedia.com','filehorse.com','techspot.com',
    'catalog.update.microsoft.com','update.microsoft.com','catalog.update'
)

# Hersteller -> offizielle Treiber-Downloadseite
$script:SmartDrvOfficialPages = [ordered]@{
    'nvidia'      = 'https://www.nvidia.com/Download/index.aspx'
    'amd'         = 'https://www.amd.com/en/support'
    'ati'         = 'https://www.amd.com/en/support'
    'intel'       = 'https://www.intel.com/content/www/us/en/download-center/home.html'
    'realtek'     = 'https://www.realtek.com/Download/List?cate_id=584'
    'killer'      = 'https://www.intel.com/content/www/us/en/download-center/home.html'
    'qualcomm'    = 'https://www.qualcomm.com/support/downloads'
    'mediatek'    = 'https://www.mediatek.com/downloads'
    'broadcom'    = 'https://www.broadcom.com/support/download-search'
    'marvell'     = 'https://www.marvell.com/support/downloads.html'
    'dell'        = 'https://www.dell.com/support/home/en-us'
    'hp'          = 'https://support.hp.com/us-en/drivers'
    'hewlett'     = 'https://support.hp.com/us-en/drivers'
    'lenovo'      = 'https://support.lenovo.com/us/en/downloads'
    'asus'        = 'https://www.asus.com/support/Download-Center/'
    'msi'         = 'https://www.msi.com/Support/Download'
    'gigabyte'    = 'https://www.gigabyte.com/Support/Driver'
    'asrock'      = 'https://www.asrock.com/support/index.asp'
    'samsung'     = 'https://www.samsung.com/support/downloads/'
    'sandisk'     = 'https://www.westerndigital.com/support'
    'western'     = 'https://www.westerndigital.com/support'
    'logitech'    = 'https://www.logitech.com/en-us/software'
    'razer'       = 'https://www.razer.com/downloads'
    'corsair'     = 'https://www.corsair.com/us/en/explorer/designer-series/software'
    'steelseries' = 'https://steelseries.com/downloads'
    'hyperx'      = 'https://www.hyperx.com/us/support'
    'synaptics'   = 'https://www.synaptics.com/support/drivers'
    'elan'        = 'https://www.elantech.com.tw/support/download'
    'creative'    = 'https://support.creative.com/'
    'bose'        = 'https://global.bose.com/en_us/support'
    'canon'       = 'https://www.usa.canon.com/support'
    'epson'       = 'https://epson.com/Support/Scanners-Waste-Ink-Tank-Printers/s/SPT_B11H'
    'brother'     = 'https://support.brother.com/'
    'lexmark'     = 'https://www.lexmark.com/en_us/support.html'
    'kyocera'     = 'https://www.kyoceradocumentsolutions.eu/en/support.html'
    'ricoh'       = 'https://www.ricoh-usa.com/support/'
    'xerox'       = 'https://www.xerox.com/support/'
    'fujitsu'     = 'https://www.fujitsu.com/global/support/'
    'toshiba'     = 'https://www.toshiba-tec.com/support/'
    'panasonic'   = 'https://na.panasonic.com/support/'
    'lg'          = 'https://www.lg.com/us/support'
    'sony'        = 'https://www.sony.com/electronics/support'
    'philips'     = 'https://www.usa.philips.com/support'
    'benq'        = 'https://www.benq.com/en-us/support/download.html'
    'viewsonic'   = 'https://www.viewsonic.com/global/support/downloads/'
    'aoc'         = 'https://www.aoc.com/us/support/downloads'
    'predator'    = 'https://www.acer.com/us-en/support'
    'acer'        = 'https://www.acer.com/us-en/support'
}

function Get-SysPilotSmartDrvScore {
    <# Heuristische Vorbewertung eines Treiber-Treffers.
       Positiv: offizielle Hersteller-Domain, Katalog-Domain,
       WHQL-Hinweis, Download-Pfad, Hardware-ID im Text.
       Negativ: Junk-Domains, Social/Video. #>
    param(
        [Parameter(Mandatory)][pscustomobject]$Hit,
        [string]$DevName = '',
        [string]$Manufacturer = '',
        [string]$HwId = ''
    )
    $score = 0
    $u = [string]$Hit.Url
    $host_ = ''
    try { $host_ = ([uri]$u).Host.ToLower() } catch { return -10 }
    $path = ''
    try { $path = ([uri]$u).AbsolutePath.ToLower() } catch {}
    $title = ([string]$Hit.Title).ToLower()
    $all = "$u $title".ToLower()

    foreach ($j in $script:SmartDrvJunkDomains) { if ($host_.Contains($j) -or $all.Contains($j)) { $score -= 4 } }
    foreach ($c in $script:SmartDrvCatalogDomains) { if ($host_.Contains($c)) { $score += 3 } }
    if ($path -match 'driver|/dl/|download|firmware|/files/') { $score += 2 }
    if ($u -match '\.(exe|msi|zip|7z|inf)(\?|$)') { $score += 3 }
    if ($all -match 'whql|certified|official|treiber|driver') { $score += 1 }
    if ($all -match 'beta|alpha|modded|dch|unlocked') { $score -= 1 }
    # Offizielle Hersteller-Domain (Hersteller-Name oder bekannte Keys)
    $man = $Manufacturer.ToLower()
    foreach ($k in $script:SmartDrvOfficialPages.Keys) {
        if (($man -and $man.Contains($k)) -or ($DevName.ToLower().Contains($k))) {
            $official = ([uri]$script:SmartDrvOfficialPages[$k]).Host.ToLower()
            if ($host_ -eq $official -or $host_.EndsWith('.' + $official)) { $score += 4 }
            break
        }
    }
    # Device-Name-Token im Host = wahrscheinlich offizielle Seite
    if ($DevName) {
        $tokens = $DevName -split '[\s\-_\.\(\)]+' | Where-Object { $_.Length -ge 4 } |
            ForEach-Object { $_.ToLower() } | Where-Object { $_ -notin @('the','for','and','pro','plus','free','windows','64','32','new','latest','driver','treiber','download') }
        foreach ($t in $tokens) { if ($host_.Contains($t)) { $score += 3; break } }
    }
    # Hardware-ID-Treffer = sehr starkes Signal (exakter Geraetetreiber)
    if ($HwId -and $all.Contains($HwId.ToLower())) { $score += 5 }
    return $score
}

function Find-SysPilotSmartDrvOfficial {
    <# Findet die offizielle Treiber-Downloadseite eines Geraets
       anhand des Herstellers. Gibt URL + Hersteller-Name zurueck. #>
    param([string]$Manufacturer = '', [string]$DevName = '')
    $hay = "$Manufacturer $DevName".ToLower()
    foreach ($k in $script:SmartDrvOfficialPages.Keys) {
        if ($hay.Contains($k)) {
            return @{ Manufacturer = $k; Url = $script:SmartDrvOfficialPages[$k] }
        }
    }
    return $null
}

function Find-SysPilotDriver {
    <# Orchestriert die komplette Treiber-Suche in parallelen
       Kind-Runspaces. Gibt zurueck:
       @{Ok;Query;Name;Manufacturer;HwId;Wu;Catalog;Web;Portals;Official;AiText;AiUrls;Stats}
       Optionaler Scriptblock -OnProgress erhaelt Statuszeilen. #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Manufacturer = '',
        [string]$HwId = '',
        [string]$CurrentVersion = '',
        [int]$MaxWebResults = 15,
        [scriptblock]$OnProgress = $null,
        [switch]$SkipAi
    )
    $say = { param($m) if ($OnProgress) { $null = & $OnProgress ([string]$m) } }
    $modDir = $PSScriptRoot
    $query = "$Manufacturer $Name".Trim()
    if (-not $query) { $query = $Name }

    $wuCode = @'
$wu = @()
try {
    Import-Module (Join-Path $modDir 'Common.psm1') -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $modDir 'Drivers.psm1') -Force
    $q = $fuQueue
    $say = { param($m) if ($q) { $q.Enqueue([string]$m) } }
    & $say 'Windows Update: Treiber-Updates suchen ...'
    $all = @(Get-SysPilotWUDriverUpdates)
    # Device-Name-Match bevorzugen, sonst alle (max 8)
    $nameL = $itemName.ToLower()
    $matched = @($all | Where-Object { ([string]$_.Title).ToLower().Contains($nameL) -or ([string]$_.DeviceCategory).ToLower().Contains($nameL) })
    $pick = if ($matched.Count -gt 0) { $matched } else { $all | Select-Object -First 8 }
    foreach ($u in @($pick | Select-Object -First 8)) {
        $wu += [pscustomobject]@{ Source='WU'; Title=$u.Title; Version=''; Url=''; Note="$($u.DriverModel) | $($u.DeviceCategory)" }
    }
} catch { if ($q) { $q.Enqueue("WU-Suche Fehler: $($_.Exception.Message)") } }
$wu
'@

    $catCode = @'
$cat = @()
try {
    Import-Module (Join-Path $modDir 'Common.psm1') -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $modDir 'Drivers.psm1') -Force
    Import-Module (Join-Path $modDir 'SmartDownload.psm1') -Force -ErrorAction SilentlyContinue
    $q = $fuQueue
    $say = { param($m) if ($q) { $q.Enqueue([string]$m) } }
    & $say 'MS Update Catalog + Treiber-Kataloge (TechPowerUp, Guru3D, MajorGeeks, Station-Drivers) ...'
    # MS Update Catalog per Hardware-ID
    if ($hwIdVar) {
        foreach ($r in @(Find-SysPilotCatalogDrivers -Query $hwIdVar | Select-Object -First 6)) {
            $cat += [pscustomobject]@{ Source='mscatalog'; Title=$r.Title; Version=$r.Version; Url=$r.Url; Note="Katalog $($r.Date) $($r.Size)" }
        }
    }
    # TechPowerUp GPU-Treiberseiten (version + WHQL scrapebar)
    $tpuMap = @{
        'nvidia' = 'https://www.techpowerup.com/download/nvidia-geforce-graphics-drivers/'
        'amd'    = 'https://www.techpowerup.com/download/amd-radeon-graphics-drivers/'
        'ati'    = 'https://www.techpowerup.com/download/amd-radeon-graphics-drivers/'
        'intel'  = 'https://www.techpowerup.com/download/intel-integrated-graphics-drivers/'
    }
    $manL = $manufacturerVar.ToLower()
    foreach ($k in $tpuMap.Keys) {
        if ($manL -match $k) {
            try {
                $page = Invoke-WebRequest $tpuMap[$k] -UseBasicParsing -TimeoutSec 20 -Headers @{ 'User-Agent'='Mozilla/5.0' }
                $m = [regex]::Match($page.Content, 'Drivers\s+([\d.]+)\s+(WHQL|Hotfix|Beta|Game Ready|Studio)?')
                if ($m.Success) {
                    $ver = $m.Groups[1].Value; $qual = $m.Groups[2].Value
                    $cat += [pscustomobject]@{ Source='techpowerup'; Title="GPU-Treiber $ver $qual"; Version=$ver; Url=$tpuMap[$k]; Note='TechPowerUp - WHQL-Status' }
                } else {
                    $cat += [pscustomobject]@{ Source='techpowerup'; Title='GPU-Treiber (TechPowerUp)'; Version=''; Url=$tpuMap[$k]; Note='aktuelle Version auf Seite' }
                }
            } catch {}
            break
        }
    }
    # Guru3D: neueste Download-Links (Treiber-Kategorie)
    try {
        $g = Invoke-WebRequest 'https://www.guru3d.com/files/' -UseBasicParsing -TimeoutSec 20 -Headers @{ 'User-Agent'='Mozilla/5.0' }
        $seenG = @{}
        foreach ($m in [regex]::Matches($g.Content, 'href="(https://www\.guru3d\.com/download/[^"]+-download/)"[^>]*>(.*?)</a>')) {
            $u = $m.Groups[1].Value; $t = ($m.Groups[2].Value -replace '<[^>]+>','').Trim()
            if (-not $t -or $seenG.ContainsKey($u)) { continue }
            $seenG[$u] = $true
            if ($t -match '(?i)driver|treiber|nvidia|amd|intel|realtek|wifi|bluetooth|chipset|audio|lan') {
                $cat += [pscustomobject]@{ Source='guru3d'; Title=$t; Version=''; Url=$u; Note='Guru3D Download' }
            }
            if ($seenG.Count -ge 5) { break }
        }
    } catch {}
    # MajorGeeks Treiber-Sektion
    try {
        $mg = Invoke-WebRequest 'https://www.majorgeeks.com/pg/drivers.html' -UseBasicParsing -TimeoutSec 20 -Headers @{ 'User-Agent'='Mozilla/5.0' }
        $seenM = @{}
        foreach ($m in [regex]::Matches($mg.Content, 'href="([^"]*majorgeeks\.com/files/details/[^"]+)"[^>]*>(.*?)</a>')) {
            $u = 'https://www.majorgeeks.com' + $m.Groups[1].Value; $t = ($m.Groups[2].Value -replace '<[^>]+>','').Trim()
            if (-not $t -or $seenM.ContainsKey($u)) { continue }
            $seenM[$u] = $true
            if ($t -match '(?i)driver|nvidia|amd|intel|realtek|wifi|bluetooth|chipset|audio|network|lan') {
                $cat += [pscustomobject]@{ Source='majorgeeks'; Title=$t; Version=''; Url=$u; Note='MajorGeeks' }
            }
            if ($seenM.Count -ge 5) { break }
        }
    } catch {}
    # Station-Drivers Forum: neueste Treiber-Topics
    try {
        $sd = Invoke-WebRequest 'https://www.station-drivers.com/index.php/en-us/forum.html' -UseBasicParsing -TimeoutSec 20 -Headers @{ 'User-Agent'='Mozilla/5.0' }
        $seenS = @{}
        foreach ($m in [regex]::Matches($sd.Content, 'href="(/index\.php/en-us/forum/[^"]+/\d+-[^"]+)"[^>]*>(.*?)</a>')) {
            $u = 'https://www.station-drivers.com' + $m.Groups[1].Value; $t = ($m.Groups[2].Value -replace '<[^>]+>','').Trim()
            if (-not $t -or $seenS.ContainsKey($u)) { continue }
            $seenS[$u] = $true
            if ($t -match '(?i)driver|nvidia|amd|intel|realtek|wifi|bluetooth|chipset|audio|lan|firmware') {
                $cat += [pscustomobject]@{ Source='station-drivers'; Title=$t; Version=''; Url=$u; Note='Station-Drivers Forum' }
            }
            if ($seenS.Count -ge 5) { break }
        }
    } catch {}
    # Dedupe nach Url
    $seenU = @{}; $catOut = @()
    foreach ($w in $cat) {
        $wu = [string]$w.Url
        if ($wu -and $seenU.ContainsKey($wu)) { continue }
        if ($wu) { $seenU[$wu] = $true }
        $catOut += $w
    }
    $catOut | Select-Object -First 14
} catch { if ($q) { $q.Enqueue("Katalog-Suche Fehler: $($_.Exception.Message)") }; @() }
'@

    $webCode = @'
$web = @()
try {
    Import-Module (Join-Path $modDir 'Common.psm1') -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $modDir 'SmartDownload.psm1') -Force
    Import-Module (Join-Path $modDir 'SmartDrivers.psm1') -Force -ErrorAction SilentlyContinue
    $q = $fuQueue
    $say = { param($m) if ($q) { $q.Enqueue([string]$m) } }
    & $say "Websuche: DDG + Bing nach Treiber '$query' ..."
    $queries = @(
        "$query driver download windows 11",
        "$itemName $manufacturerVar driver latest version",
        "`"$itemName`" driver site:station-drivers.com OR site:guru3d.com OR site:techpowerup.com OR site:majorgeeks.com",
        "$manufacturerVar $itemName driver whql official"
    )
    $all = @()
    foreach ($qs in $queries) { $all += @(Find-SysPilotWebResults -Query $qs -MaxPerEngine 5) }
    $seenU = @{}; $scored = @()
    foreach ($h in $all) {
        $hu = ([string]$h.Url).TrimEnd('/')
        if ($seenU.ContainsKey($hu)) { continue }
        $seenU[$hu] = $true
        $h.Score = Get-SysPilotSmartDrvScore -Hit $h -DevName $itemName -Manufacturer $manufacturerVar -HwId $hwIdVar
        $scored += $h
    }
    $top = $scored | Sort-Object Score -Descending | Select-Object -First $maxWeb
    $out = @()
    foreach ($h in $top) {
        $out += [pscustomobject]@{ Title=$h.Title; Url=$h.Url; Engine=$h.Engine; Note="Score $($h.Score)"; Best=($h.Score -ge 6) }
    }
    $out
} catch { if ($q) { $q.Enqueue("Websuche Fehler: $($_.Exception.Message)") }; @() }
'@

    $katCode = @'
$ports = @()
try {
    Import-Module (Join-Path $modDir 'SmartDrivers.psm1') -Force -ErrorAction SilentlyContinue
    $q = $fuQueue
    $say = { param($m) if ($q) { $q.Enqueue([string]$m) } }
    & $say 'Treiber-Webkatalog: passende Portal-Quellen werden ermittelt ...'
    $hay = "$itemName $manufacturerVar $hwIdVar".ToLower()
    $catMap = @(
        @{ Cat='GPU (Grafikkarte)';      Kw='nvidia|amd|radeon|geforce|graphics|\bgpu\b|\bvga\b|intel hd|intel iris|intel uhd' }
        @{ Cat='Netzwerk';               Kw='wifi|wlan|wireless|ethernet|\blan\b|network|killer|qualcomm|broadcom|mediatek|bluetooth|wwan' }
        @{ Cat='Audio';                  Kw='audio|sound|creative|bose|headset|speaker|microphone' }
        @{ Cat='Drucker/Scanner';        Kw='printer|drucker|scanner|hp |hewlett|canon|epson|brother|lexmark|kyocera|ricoh|xerox' }
        @{ Cat='Notebook/PC-Hersteller'; Kw='dell|lenovo|asus|msi|gigabyte|asrock|acer|predator|laptop|notebook|thinkpad|vivobook|zenbook|ideapad' }
        @{ Cat='Peripherie';             Kw='logitech|razer|steelseries|corsair|hyperx|synaptics|elan|mouse|keyboard|tastatur|maus|webcam|gamepad|joystick' }
        @{ Cat='Speicher/SSD';           Kw='samsung|sandisk|western digital|\bwd\b|nvme|\bssd\b|speicher|storage|micron|kingston|crucial' }
        @{ Cat='Chipset/USB';            Kw='chipset|\busb\b|sata|\bpch\b|x570|b550|b450|z790|b760|h610' }
        @{ Cat='BIOS/Firmware';          Kw='bios|firmware|uefi' }
    )
    $scored = @()
    foreach ($e in @(Get-SysPilotDriverWebCatalog)) {
        $score = 0
        # Name-Token-Match (z.B. 'Realtek', 'Logitech', 'NVIDIA')
        foreach ($t in @($e.Name -split '[\s\(\)/]+' | Where-Object { $_.Length -ge 3 })) {
            if ($hay.Contains($t.ToLower())) { $score += 3 }
        }
        # Kategorie-Stichwort-Match
        foreach ($cm in $catMap) {
            if ($e.Cat -eq $cm.Cat -and $hay -match $cm.Kw) { $score += 4; break }
        }
        # Generische Treiber-Portale immer einbeziehen (kleiner Basis-Score)
        if ($e.Cat -eq 'Treiber allgemein') { $score += 1 }
        if ($score -gt 0) {
            $scored += [pscustomobject]@{ Name=$e.Name; Url=$e.Url; Cat=$e.Cat; Auto=$e.Auto; Score=$score }
        }
    }
    $ports = @($scored | Sort-Object Score -Descending | Select-Object -First 8)
    & $say ("Webkatalog: $($ports.Count) passende Portale: " + (($ports | ForEach-Object { $_.Name }) -join ', '))
} catch { if ($q) { $q.Enqueue("Webkatalog-Fehler: $($_.Exception.Message)") } }
@{ Portal=$ports }
'@

    $aiCode = @'
$aiUrls = @(); $aiText = ''
try {
    Import-Module (Join-Path $modDir 'Common.psm1') -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $modDir 'AiAssist.psm1') -Force -ErrorAction Stop
    if (-not (Get-Command Invoke-SysPilotAiChat -ErrorAction SilentlyContinue)) {
        throw "AiAssist-Import erfolgreich, aber Invoke-SysPilotAiChat fehlt"
    }
    $q = $fuQueue
    $say = { param($m) if ($q) { $q.Enqueue([string]$m) } }
    & $say 'Herbert-KI bewertet alle Treiber-Funde und waehlt den besten (kann 30-90s dauern) ...'
    $prompt = @"
Du bist Herbert, der Treiber-Assistent von SysPilot. Suche den passenden Treiber.
Geraet: $itemName | Hersteller: $manufacturerVar | Hardware-ID: $hwIdVar
Installierte Version: $curVerVar

Windows-Update-Treiber:
$wuTxt

Katalog-Funde (MS Update Catalog, TechPowerUp, Guru3D, MajorGeeks, Station-Drivers):
$catTxt

Treiber-Webkatalog-Portale (kuratierte Hersteller-/Treiber-Seiten):
$portTxt

Web-Suchtreffer (Score = heuristische Einschaetzung):
$webTxt

Aufgabe: Waehle den besten Treiber-Download. Bevorzuge WHQL/official,
MS Update Catalog oder Herstellerseite. Antworte KURZ auf Deutsch:
1. Eine Zeile 'URL: <bester link>'
2. Optional weitere 'URL:'-Zeilen fuer Alternativen
3. 2-3 Saetze: warum dieser Treiber, WHQL-Hinweis, Installations-Tipp.
"@
    $ai = Invoke-SysPilotAiChat -Prompt $prompt -TimeoutSec 90
    if ($ai.Ok) {
        $aiText = [string]$ai.Text
        foreach ($m in [regex]::Matches($aiText, 'https?://[^\s)"''<>\]]+')) {
            $u = $m.Value.TrimEnd('.',',',';')
            if ($u -notmatch 'perplexity|duckduckgo|gemini|copilot|youtube|facebook') { $aiUrls += $u }
        }
    } else { & $say "Herbert nicht erreichbar: $($ai.Error)" }
} catch { if ($q) { $q.Enqueue("KI-Suche Fehler: $($_.Exception.Message)") } }
@{ AiUrl=$aiUrls; AiText=$aiText }
'@

    & $say "SmartDrivers: Suche Treiber fuer '$Name' ($Manufacturer) - 3 Quellen parallel ..."
    $modDirVar = $modDir; $queryVar = $query; $nameVar = $Name
    $manVar = $Manufacturer; $hwVar = $HwId; $curVar = $CurrentVersion; $maxWebVar = $MaxWebResults

    $sdQ = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
    $drainSd = {
        $line = $null
        while ($sdQ.TryDequeue([ref]$line)) { $null = & $OnProgress ([string]$line) }
    }
    $spawn = {
        param([string]$name, [string]$code, [hashtable]$extra)
        $crs = [runspacefactory]::CreateRunspace()
        $crs.ApartmentState='STA'; $crs.ThreadOptions='ReuseThread'; $crs.Open()
        $vars = @{ modDir=$modDirVar; fuQueue=$sdQ; query=$queryVar; itemName=$nameVar
                   manufacturerVar=$manVar; hwIdVar=$hwVar; curVerVar=$curVar; maxWeb=$maxWebVar }
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
        & $spawn 'wu'  $wuCode  $null
        & $spawn 'cat' $catCode $null
        & $spawn 'web' $webCode $null
        & $spawn 'kat' $katCode $null
    )
    & $say 'Phase 1: Windows Update + Kataloge + Webkatalog + Websuche parallel ...'
    & $waitAll $children

    $wu=@(); $cat=@(); $web=@(); $ports=@()
    foreach ($c in $children) {
        if ($c.Name -eq 'wu')  { $wu  = @($c.Out | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['Source'] -and $_.Source -eq 'WU' }) }
        if ($c.Name -eq 'cat') { $cat = @($c.Out | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['Url'] }) }
        if ($c.Name -eq 'web') { $web = @($c.Out | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['Engine'] }) }
        if ($c.Name -eq 'kat') { $kres = @($c.Out | Where-Object { $_ -is [hashtable] }) | Select-Object -First 1; if($kres){ $ports = @($kres['Portal']) } }
    }
    & $say ("Phase 1 fertig: WU=$($wu.Count) Kataloge=$($cat.Count) Web=$($web.Count) Portale=$($ports.Count)" + $(if($SkipAi){' - Herbert uebersprungen'}else{' - Herbert wird gefragt ...'}))

    # Offizielle Herstellerseite
    $official = Find-SysPilotSmartDrvOfficial -Manufacturer $Manufacturer -DevName $Name

    # Phase 2: Herbert bewertet
    $wuTxt=''; foreach($w in $wu){ $wuTxt += "- $($w.Title) | $($w.Note)`n" }; if(-not $wuTxt){$wuTxt="- (keine)`n"}
    $catTxt=''; foreach($w in $cat | Select-Object -First 14){ $disp=$(if($w.Version){$w.Version}elseif($w.Title){$w.Title}else{$w.Source}); $catTxt += "- [$($w.Source)] $disp -> $($w.Url) ($($w.Note))`n" }; if(-not $catTxt){$catTxt="- (keine)`n"}
    $webTxt=''; foreach($h in $web | Select-Object -First $MaxWebResults){ $webTxt += "- [$($h.Engine) Score=$($h.Score)] $($h.Title) -> $($h.Url)`n" }; if(-not $webTxt){$webTxt="- (keine)`n"}
    $portTxt=''; foreach($p in $ports){ $portTxt += "- [$($p.Cat)] $($p.Name) -> $($p.Url)`n" }; if(-not $portTxt){$portTxt="- (keine)`n"}
    $offTxt = if ($official) { "$($official.Url) ($($official.Manufacturer))" } else { '(nicht gefunden)' }

    $aiChild = $null
    if (-not $SkipAi) {
        $aiChild = & $spawn 'ki' $aiCode @{ wuTxt=$wuTxt; catTxt=$catTxt; webTxt=$webTxt; portTxt=$portTxt; offTxt=$offTxt }
        & $waitAll @($aiChild)
    }
    $aiRes = @(); if ($aiChild) { $aiRes = @($aiChild.Out | Where-Object { $_ -is [hashtable] }) | Select-Object -First 1 }
    $aiUrls=@(); $aiText=''
    if ($aiRes) { $aiUrls=@($aiRes['AiUrl']); $aiText=[string]$aiRes['AiText'] }

    & $say 'Suche abgeschlossen.'
    return @{
        Ok=$true; Query=$query; Name=$Name; Manufacturer=$Manufacturer; HwId=$HwId
        Wu=$wu; Catalog=$cat; Web=$web; Portals=$ports; Official=$official
        AiText=$aiText; AiUrls=$aiUrls
        Stats=@{ Wu=$wu.Count; Catalog=$cat.Count; Web=$web.Count; Portals=$ports.Count }
    }
}

function Show-SysPilotDriverFinder {
    <# WPF-Fenster fuer die SmartDrivers-Suche: Geraet-Felder
       (Name/Hersteller/HW-ID/Version), Live-Protokoll,
       Fortschrittsbalken, Ergebnis-Liste + Herbert-Box. #>
    param(
        [string]$DevName = '',
        [string]$Manufacturer = '',
        [string]$HwId = '',
        [string]$CurrentVersion = '',
        [string]$Title = 'SmartDrivers - Treiber-Suche',
        $Owner = $null
    )
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
        Write-Warning 'Show-SysPilotDriverFinder braucht STA - im Konsolen-Modus nicht verfuegbar.'
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
        Title="$Title" Width="1020" Height="660" WindowStartupLocation="CenterOwner"
        Background="#FF1E1E2E" Foreground="#FFEAEAF2" FontFamily="Segoe UI">
  <Window.Resources>
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
      <RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="170"/>
      <RowDefinition Height="170"/><RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <StackPanel Orientation="Horizontal" Grid.Row="0" Margin="0,0,0,8">
      <TextBlock Text="Geraet:" VerticalAlignment="Center" Margin="0,0,6,0"/>
      <TextBox x:Name="TxtName" Width="230" VerticalAlignment="Center"/>
      <TextBlock Text="Hersteller:" VerticalAlignment="Center" Margin="14,0,6,0"/>
      <TextBox x:Name="TxtMan" Width="130" VerticalAlignment="Center"/>
      <TextBlock Text="HW-ID:" VerticalAlignment="Center" Margin="14,0,6,0"/>
      <TextBox x:Name="TxtHw" Width="200" VerticalAlignment="Center"/>
      <TextBlock Text="Version:" VerticalAlignment="Center" Margin="14,0,6,0"/>
      <TextBox x:Name="TxtVer" Width="90" VerticalAlignment="Center"/>
    </StackPanel>
    <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,0,0,8">
      <ComboBox x:Name="CmbDevices" Width="560" IsEditable="False" ToolTip="Erkannte Geraete (Problemgeraete + Inventar)"/>
      <Button x:Name="BtnPick" Content="Geraet waehlen" Width="100" Margin="8,0,0,0"/>
      <Button x:Name="BtnSearch" Content="Suchen" Width="90" Margin="16,0,0,0"/>
      <Button x:Name="BtnClose" Content="Schliessen" Width="90" Margin="8,0,0,0"/>
    </StackPanel>
    <TextBox x:Name="TxtError" Grid.Row="2" Height="40" Margin="0,0,0,8" IsReadOnly="True"
             TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Background="#FF14141E"
             Foreground="#FFB0B0C0" FontFamily="Consolas" FontSize="11"/>
    <StackPanel Grid.Row="3" Orientation="Horizontal" Margin="0,0,0,6">
      <TextBlock x:Name="TxtStatus" Text="Bereit." Foreground="#FFB0B0C0" VerticalAlignment="Center"/>
      <ProgressBar x:Name="ProgBar" Width="220" Height="8" Margin="16,0,0,0"
                   VerticalAlignment="Center" Visibility="Collapsed" IsIndeterminate="True"/>
    </StackPanel>
    <ListView x:Name="ResultList" Grid.Row="4" Margin="0,0,0,8" Background="#FF14141E"
              Foreground="#FFEAEAF2" BorderBrush="#FF3A3A55">
      <ListView.View><GridView>
        <GridViewColumn Header="Quelle" Width="100" DisplayMemberBinding="{Binding Tag}"/>
        <GridViewColumn Header="Treffer"  Width="600" DisplayMemberBinding="{Binding Label}"/>
        <GridViewColumn Header="URL"      Width="220" DisplayMemberBinding="{Binding Url}"/>
      </GridView></ListView.View>
    </ListView>
    <RichTextBox x:Name="HerbBox" Grid.Row="5" Height="120" IsReadOnly="True" Visibility="Collapsed"
                 Background="#FF101018" Foreground="#FFEAEAF2" BorderThickness="0"
                 FontFamily="Segoe UI" FontSize="12" Padding="8,6" Margin="0,0,0,8"
                 VerticalScrollBarVisibility="Auto" ToolTip="Herbert-Antwort - URLs sind klickbar"/>
    <TextBox x:Name="LogBox" Grid.Row="6" IsReadOnly="True" TextWrapping="Wrap"
             VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
             Background="#FF0E140E" Foreground="#FF9CCC65" FontFamily="Consolas" FontSize="11"
             BorderBrush="#FF2E4A2E" AcceptsReturn="True"/>
    <StackPanel Grid.Row="7" Orientation="Horizontal" Margin="0,8,0,0">
      <Button x:Name="BtnOpen" Content="Link oeffnen" Width="110" IsEnabled="False"/>
      <Button x:Name="BtnCopy" Content="Alles kopieren" Width="120" Margin="8,0,0,0"/>
      <Button x:Name="BtnWU" Content="WU-Install" Width="100" Margin="8,0,0,0" ToolTip="Windows-Update-Treiber-Installationsmenue oeffnen"/>
      <TextBlock x:Name="TxtHint" Text="Tipp: Rechtsklick in Log = kopieren. Enter = Suchen." Foreground="#FF7A7A90" VerticalAlignment="Center" Margin="16,0,0,0"/>
    </StackPanel>
  </Grid>
</Window>
"@
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
    $win = [Windows.Markup.XamlReader]::Load($reader)
    if (Test-SysPilotWindowAlreadyOpen -Key 'syspilot-driver-finder' -Win $win) { return }
    if ($Owner) { try { $win.Owner = $Owner } catch {} }
    $fc = @{}
    foreach ($n in 'TxtName','TxtMan','TxtHw','TxtVer','TxtError','CmbDevices','BtnPick','BtnSearch','BtnClose','TxtStatus','ProgBar','ResultList','HerbBox','LogBox','BtnOpen','BtnCopy','BtnWU','TxtHint') {
        $fc[$n] = $win.FindName($n)
    }

    # Geraete-Liste befuellen (Problemgeraete + Inventar)
    $deviceList = @()
    try {
        Import-Module (Join-Path $PSScriptRoot 'Drivers.psm1') -Force -ErrorAction SilentlyContinue
        $deviceList += @(Get-SysPilotDeviceHardwareIds)
        if ($deviceList.Count -eq 0) {
            $inv = @(Get-SysPilotDriverInventory | Select-Object -First 30)
            foreach ($d in $inv) {
                $deviceList += [pscustomobject]@{ Name=$d.DeviceName; Manufacturer=''; DeviceID=$d.DeviceID; PNPDeviceID=''; HardwareIds=@() }
            }
        }
    } catch {}
    foreach ($d in $deviceList) {
        $hid = if ($d.HardwareIds -and $d.HardwareIds.Count -gt 0) { $d.HardwareIds[0] } else { [string]$d.DeviceID }
        $fc.CmbDevices.Items.Add([pscustomobject]@{ Label="$($d.Name) [$hid]"; Name=$d.Name; Man=$d.Manufacturer; Hw=$hid; Ver='' })
    }

    $fc.TxtName.Text = $DevName; $fc.TxtMan.Text = $Manufacturer; $fc.TxtHw.Text = $HwId; $fc.TxtVer.Text = $CurrentVersion
    if ($DevName -and -not $HwId) { $fc.TxtName.Focus(); $fc.TxtName.SelectAll() }

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
                $items = @()
                foreach ($w in @($res.Wu))      { $items += [pscustomobject]@{ Tag='[wu]';       Label="WU: $($w.Title)"; Url='' } }
                foreach ($w in @($res.Catalog)) { $disp = $(if($w.Version){$w.Version}elseif($w.Title){$w.Title}else{$w.Source}); $items += [pscustomobject]@{ Tag="[cat:$($w.Source)]"; Label="$disp - $($w.Note)"; Url=$w.Url } }
                foreach ($h in @($res.Web))     { $items += [pscustomobject]@{ Tag="[web:$($h.Engine)]"; Label="$($h.Title) ($($h.Note))"; Url=$h.Url } }
                if ($res.Official)              { $items += [pscustomobject]@{ Tag='[official]'; Label="Offizielle Seite: $($res.Official.Manufacturer)"; Url=$res.Official.Url } }
                foreach ($p in @($res.Portals))  { $items += [pscustomobject]@{ Tag="[katalog:$($p.Cat)]"; Label="Portal: $($p.Name) ($($p.Cat))"; Url=$p.Url } }
                foreach ($u in @($res.AiUrls))  { $items += [pscustomobject]@{ Tag='[ki]'; Label='Herbert-Fundstelle'; Url=$u } }
                $qe = [Uri]::EscapeDataString("$($fc.TxtName.Text) $($fc.TxtMan.Text) driver download")
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
                Set-SysPilotWindowAutoSize -Win $win -MinWidth 980 -MinHeight 620
                $st = $res.Stats
                & $setStatus "Fertig: $($st.Wu) WU, $($st.Catalog) Kataloge, $($st.Web) Web, $($items.Count) Ergebnisse." '#FF81C784'
            } else {
                & $setStatus 'Suche fehlgeschlagen.' '#FFEF5350'
            }
            $fc.ProgBar.Visibility='Collapsed'; $fc.BtnSearch.IsEnabled=$true; $busy=$false
            if ($pendQ.Count -gt 0) { $n=$pendQ.Dequeue(); & $beginSearch $n.n $n.m $n.h $n.v }
        }
    })

    $beginSearch = {
        param($name,$man,$hw,$ver)
        $busy=$true; $fc.BtnSearch.IsEnabled=$false
        $fc.HerbBox.Document.Blocks.Clear(); $fc.HerbBox.Visibility='Collapsed'
        $fc.LogBox.Clear(); $fc.ResultList.Items.Clear()
        $fc.ResultList.Visibility='Collapsed'; $fc.BtnOpen.IsEnabled=$false
        $results=@()
        & $setStatus "Suche laeuft: $name ..." '#FFB0B0C0'
        $fc.ProgBar.Visibility='Visible'; $fc.ProgBar.IsIndeterminate=$true;$fc.ProgBar.Value=0
        while ($script:_sdQueue.TryDequeue([ref]([string]$null))) {}
        $rs=[runspacefactory]::CreateRunspace(); $rs.ApartmentState='STA'; $rs.ThreadOptions='ReuseThread'; $rs.Open()
        $modRoot = $null
        try { $modRoot = (Get-Module SmartDrivers).Path } catch {}
        if (-not $modRoot) { $modRoot = Join-Path $env:ProgramFiles 'SysPilot\modules\SmartDrivers.psm1' }
        $sdModDir = Split-Path $modRoot -Parent
        $sdQueue = $script:_sdQueue
        $ps=[powershell]::Create(); $ps.Runspace=$rs
        [void]$ps.AddScript({
            param($sdModDir,$sdName,$sdMan,$sdHw,$sdVer,$sdQueue)
            Import-Module (Join-Path $sdModDir 'Common.psm1') -Force -ErrorAction SilentlyContinue
            Import-Module (Join-Path $sdModDir 'SmartDrivers.psm1') -Force
            Import-Module (Join-Path $sdModDir 'SmartDownload.psm1') -Force -ErrorAction SilentlyContinue
            Import-Module (Join-Path $sdModDir 'Drivers.psm1') -Force -ErrorAction SilentlyContinue
            Import-Module (Join-Path $sdModDir 'AiAssist.psm1') -Force -ErrorAction SilentlyContinue
            Find-SysPilotDriver -Name $sdName -Manufacturer $sdMan -HwId $sdHw -CurrentVersion $sdVer `
                -OnProgress { param($m) $sdQueue.Enqueue($m) }
        }).AddArgument($sdModDir).AddArgument($name).AddArgument($man).AddArgument($hw).AddArgument($ver).AddArgument($sdQueue) | Out-Null
        $async=$ps.BeginInvoke()
        $poll.Start()
    }

    $startSearch = {
        $name=[string]$fc.TxtName.Text; $man=[string]$fc.TxtMan.Text
        $hw=[string]$fc.TxtHw.Text; $ver=[string]$fc.TxtVer.Text
        if (-not $name) { & $setStatus 'Geraetename fehlt.' '#FFEF5350'; return }
        if ($busy) {
            $pendQ.Enqueue(@{n=$name;m=$man;h=$hw;v=$ver})
            & $setStatus "Warteschlange: $($pendQ.Count) Treiber-Suche(n) - '$name' wartet." '#FFFFB74D'
            return
        }
        & $beginSearch $name $man $hw $ver
    }

    $fc.BtnSearch.Add_Click({ & $startSearch })
    $fc.BtnClose.Add_Click({ & $stopJob; $win.Close() })
    $fc.TxtName.Add_KeyUp({ param($s,$e) if ($e.Key -eq 'Enter') { & $startSearch } })
    $fc.BtnPick.Add_Click({
        $sel = $fc.CmbDevices.SelectedItem
        if (-not $sel) { & $setStatus 'Kein Geraet ausgewaehlt.' '#FFFFB74D'; return }
        $fc.TxtName.Text = $sel.Name
        if ($sel.Man) { $fc.TxtMan.Text = $sel.Man }
        if ($sel.Hw)  { $fc.TxtHw.Text = $sel.Hw }
    })
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
    $fc.BtnWU.Add_Click({
        try {
            Import-Module (Join-Path $PSScriptRoot 'Drivers.psm1') -Force -ErrorAction SilentlyContinue
            Show-SysPilotDriverSourcesMenu
        } catch { & $setStatus "WU-Menue nicht verfuegbar: $($_.Exception.Message)" '#FFEF5350' }
    })
    $fc.LogBox.Add_PreviewMouseRightButtonDown({ $fc.LogBox.SelectAll() })
    $win.Add_Closed({ & $drainLog; & $stopJob; $logTimer.Stop(); $poll.Stop() })
    Set-SysPilotWindowAutoSize -Win $win -MinWidth 980 -MinHeight 620
    $logTimer.Start()
    Add-SysPilotAssistantToWindow -Win $win -Context 'Show-SysPilotDriverFinder'
    [void]$win.ShowDialog()
    return $true
}

function Invoke-SysPilotSmartDriverSearch {
    <# Einstiegspunkt fuer Menues: oeffnet das WPF-Fenster (STA)
       oder faellt auf eine Konsolen-Suche zurueck (MTA/headless).
       Gibt $true zurueck wenn die Suche_STARTED wurde. #>
    param(
        [string]$DevName = '',
        [string]$Manufacturer = '',
        [string]$HwId = '',
        [string]$CurrentVersion = ''
    )
    if ([Threading.Thread]::CurrentThread.ApartmentState -eq 'STA') {
        return (Show-SysPilotDriverFinder -DevName $DevName -Manufacturer $Manufacturer -HwId $HwId -CurrentVersion $CurrentVersion)
    }
    # --- Konsolen-Fallback ---
    if (-not $DevName) {
        $devs = @()
        try {
            Import-Module (Join-Path $PSScriptRoot 'Drivers.psm1') -Force -ErrorAction SilentlyContinue
            $devs = @(Get-SysPilotDeviceHardwareIds)
        } catch {}
        if ($devs.Count -eq 0) {
            $inv = @(Get-SysPilotDriverInventory | Select-Object -First 30)
            foreach ($d in $inv) {
                $devs += [pscustomobject]@{ Name=$d.DeviceName; Manufacturer=''; DeviceID=$d.DeviceID; PNPDeviceID=''; HardwareIds=@() }
            }
        }
        $items = @()
        foreach ($d in $devs) {
            $hid = if ($d.HardwareIds -and $d.HardwareIds.Count -gt 0) { $d.HardwareIds[0] } else { [string]$d.DeviceID }
            $items += @{ Label = "$($d.Name) [$hid]"; Color = 'White'; Tag = $d }
        }
        $items += @{ Label = 'Geraet manuell eingeben'; Color = 'DarkGray'; Tag = 'MANUAL' }
        $items += @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = $null }
        $pick = Show-SysPilotArrowMenu -Items $items -Title 'SmartDrivers - Geraet waehlen' -Footer 'Enter = suchen, Esc = zurueck'
        if ($null -eq $pick) { return $false }
        if ($pick -eq 'MANUAL') {
            $DevName = Read-SysPilotInput 'Geraetename (z.B. RTL8852CE)'
            if (-not $DevName) { return $false }
            $Manufacturer = Read-SysPilotInput 'Hersteller (optional, z.B. Realtek)' ; if (-not $Manufacturer) { $Manufacturer='' }
            $HwId = Read-SysPilotInput 'Hardware-ID (optional, z.B. PCI\VEN_10EC&DEV_8852)'; if (-not $HwId) { $HwId='' }
        } else {
            $DevName = [string]$pick.Name
            $Manufacturer = [string]$pick.Manufacturer
            $HwId = if ($pick.HardwareIds -and $pick.HardwareIds.Count -gt 0) { [string]$pick.HardwareIds[0] } else { [string]$pick.DeviceID }
        }
    }
    Write-Host "`n  SmartDrivers: Suche Treiber fuer '$DevName' ..." -ForegroundColor Cyan
    $r = Find-SysPilotDriver -Name $DevName -Manufacturer $Manufacturer -HwId $HwId -CurrentVersion $CurrentVersion `
        -OnProgress { param($m) Write-Host "    >> $m" -ForegroundColor DarkGray }
    if (-not $r -or -not $r.Ok) { Write-Host '  [!] Suche fehlgeschlagen.' -ForegroundColor Red; return $true }
    Write-Host ''
    Write-Host '  === ERGEBNISSE ===' -ForegroundColor Cyan
    if ($r.Official) { Write-Host ("  [official] {0} -> {1}" -f $r.Official.Manufacturer, $r.Official.Url) -ForegroundColor Green }
    foreach ($p in @($r.Portals) | Select-Object -First 8) {
        Write-Host ("  [katalog:$($p.Cat)] {0} -> {1}" -f $p.Name, $p.Url) -ForegroundColor DarkCyan
    }
    foreach ($w in @($r.Wu))      { Write-Host ("  [wu] {0} | {1}" -f $w.Title, $w.Note) -ForegroundColor White }
    foreach ($w in @($r.Catalog) | Select-Object -First 10) {
        $disp = $(if ($w.Version) { $w.Version } elseif ($w.Title) { $w.Title } else { $w.Source })
        Write-Host ("  [cat:$($w.Source)] {0} -> {1}" -f $disp, $w.Url) -ForegroundColor White
    }
    foreach ($h in @($r.Web) | Select-Object -First 8) {
        Write-Host ("  [web:$($h.Engine)] {0} -> {1}" -f $h.Title, $h.Url) -ForegroundColor DarkGray
    }
    if ($r.AiText) {
        Write-Host ''
        Write-Host '  --- Herbert ---' -ForegroundColor Cyan
        Write-Host $r.AiText -ForegroundColor White
    }
    # Top-Link oeffnen?
    $topUrl = $null
    if ($r.AiUrls -and @($r.AiUrls).Count -gt 0) { $topUrl = @($r.AiUrls)[0] }
    elseif ($r.Official) { $topUrl = $r.Official.Url }
    if ($topUrl -and (Confirm-SysPilot 'Besten Link im Browser oeffnen?')) { Start-Process $topUrl }
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
    return $true
}

# =====================================================================
# SMARTDRIVER STUDIO: Hardware-Analyse, Multi-Select, Backup,
# selbsttaetige Installation (WU / MS-Catalog .cab / Web-Installer)
# =====================================================================

function Get-SysPilotDriverWebCatalog {
    <# Eigener Treiber-Webkatalog: kuratierte Portale nach Kategorie.
       Auto = scrapbarer Download-Bereich, Manuell = Portal-Start. #>
    return @(
        @{ Cat='GPU (Grafikkarte)';  Name='TechPowerUp';        Url='https://www.techpowerup.com/download/nvidia-geforce-graphics-drivers/'; Auto=$true }
        @{ Cat='GPU (Grafikkarte)';  Name='Guru3D';             Url='https://www.guru3d.com/download/'; Auto=$true }
        @{ Cat='GPU (Grafikkarte)';  Name='Station-Drivers';    Url='https://www.station-drivers.com/index.php/en-us/forum.html'; Auto=$true }
        @{ Cat='Treiber allgemein';  Name='MajorGeeks';         Url='https://www.majorgeeks.com/pg/drivers.html'; Auto=$true }
        @{ Cat='Treiber allgemein';  Name='DriversCloud';       Url='https://www.driverscloud.com/en/drivers'; Auto=$false }
        @{ Cat='Treiber allgemein';  Name='FileHorse';          Url='https://www.filehorse.com/download/'; Auto=$false }
        @{ Cat='Treiber allgemein';  Name='TechSpot';           Url='https://www.techspot.com/downloads/drivers/'; Auto=$false }
        @{ Cat='Hersteller';         Name='NVIDIA';             Url='https://www.nvidia.com/Download/index.aspx'; Auto=$false }
        @{ Cat='Hersteller';         Name='AMD';                Url='https://www.amd.com/en/support'; Auto=$false }
        @{ Cat='Hersteller';         Name='Intel Download Center'; Url='https://www.intel.com/content/www/us/en/download-center/home.html'; Auto=$false }
        @{ Cat='Hersteller';         Name='Realtek';            Url='https://www.realtek.com/Download/List?cate_id=584'; Auto=$false }
        @{ Cat='Hersteller';         Name='Microsoft Update Catalog'; Url='https://www.catalog.update.microsoft.com/Home.aspx'; Auto=$true }
        @{ Cat='Drucker/Scanner';    Name='HP Support';         Url='https://support.hp.com/us-en/drivers'; Auto=$false }
        @{ Cat='Drucker/Scanner';    Name='Brother';            Url='https://support.brother.com/'; Auto=$false }
        @{ Cat='Drucker/Scanner';    Name='Canon';              Url='https://www.usa.canon.com/support'; Auto=$false }
        @{ Cat='Drucker/Scanner';    Name='Epson';              Url='https://epson.com/Support/Scanners-Waste-Ink-Tank-Printers/s/SPT_B11H'; Auto=$false }
        @{ Cat='Notebook/PC-Hersteller'; Name='Dell';            Url='https://www.dell.com/support/home/en-us'; Auto=$false }
        @{ Cat='Notebook/PC-Hersteller'; Name='Lenovo';          Url='https://support.lenovo.com/us/en/downloads'; Auto=$false }
        @{ Cat='Notebook/PC-Hersteller'; Name='ASUS';            Url='https://www.asus.com/support/Download-Center/'; Auto=$false }
        @{ Cat='Notebook/PC-Hersteller'; Name='MSI';             Url='https://www.msi.com/Support/Download'; Auto=$false }
        @{ Cat='Notebook/PC-Hersteller'; Name='Gigabyte';        Url='https://www.gigabyte.com/Support/Driver'; Auto=$false }
        @{ Cat='Peripherie';         Name='Logitech';           Url='https://www.logitech.com/en-us/software'; Auto=$false }
        @{ Cat='Peripherie';         Name='Razer';              Url='https://www.razer.com/downloads'; Auto=$false }
        @{ Cat='Peripherie';         Name='SteelSeries';        Url='https://steelseries.com/downloads'; Auto=$false }
        @{ Cat='Peripherie';         Name='Synaptics (Touchpad)'; Url='https://www.synaptics.com/support/drivers'; Auto=$false }
        @{ Cat='Peripherie';         Name='Elan (Touchpad)';    Url='https://www.elantech.com.tw/support/download'; Auto=$false }
        @{ Cat='Audio';              Name='Creative';           Url='https://support.creative.com/'; Auto=$false }
        @{ Cat='Audio';              Name='Bose';               Url='https://global.bose.com/en_us/support'; Auto=$false }
        @{ Cat='Speicher/SSD';       Name='Samsung';            Url='https://www.samsung.com/support/downloads/'; Auto=$false }
        @{ Cat='Speicher/SSD';       Name='SanDisk/WD';         Url='https://www.westerndigital.com/support'; Auto=$false }
        @{ Cat='Netzwerk';           Name='Killer (Intel)';     Url='https://www.intel.com/content/www/us/en/download-center/home.html'; Auto=$false }
        @{ Cat='Netzwerk';           Name='Qualcomm';           Url='https://www.qualcomm.com/support/downloads'; Auto=$false }
        @{ Cat='Netzwerk';           Name='Broadcom';           Url='https://www.broadcom.com/support/download-search'; Auto=$false }
        @{ Cat='Chipset/USB';        Name='ASUS Chipset';       Url='https://www.asus.com/support/Download-Center/'; Auto=$false }
        @{ Cat='Chipset/USB';        Name='Gigabyte Chipset';   Url='https://www.gigabyte.com/Support/Driver'; Auto=$false }
        @{ Cat='BIOS/Firmware';      Name='Hersteller-Seiten';  Url='https://www.station-drivers.com/index.php/en-us/forum.html'; Auto=$false }
    )
}

function Get-SysPilotDriverDevices {
    <# Einheitliche Geraete-Liste: Problemgeraete + Inventar +
       veraltete Treiber. Status: problem | outdated | ok.
       OnProgress: Scriptblock, bekommt "PROGRESS|<0-100>". #>
    param([scriptblock]$OnProgress = $null)
    $say = { param($m) if($OnProgress){ $null = & $OnProgress ([string]$m) } }
    if (-not (Get-Command Get-SysPilotDriverInventory -ErrorAction SilentlyContinue)) {
        Import-Module (Join-Path $PSScriptRoot 'Drivers.psm1') -Force -Global -ErrorAction SilentlyContinue
        Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force -Global -ErrorAction SilentlyContinue
    }
    $log = { param($m) if($say){ $null = & $say $m } }
    $prog = { param($p) if($say){ $null = & $say ("PROGRESS|" + [math]::Round([math]::Min(100,[math]::Max(0,$p)))) } }
    # === Schneller Pfad: Get-PnpDevice (PnP-API, keine WMI) ===
    & $log 'Phase 1/3: Geraeteliste wird gelesen (PnP-API, schnell) ...'
    $pnpDevs = @()
    try { $pnpDevs = @(Get-PnpDevice -ErrorAction Stop) } catch {}
    & $prog 30
    & $log "PnP-Geraete: $($pnpDevs.Count) - Problemgeraete + Hardware-IDs werden ermittelt ..."
    $problem = @()
    $seenPnp = @{}
    foreach ($pd in $pnpDevs) {
        $seenPnp[$pd.InstanceId] = $true
        $st = ''
        try { $st = [string]$pd.Status } catch {}
        if ($st -ne 'Error' -and $st -ne 'Degraded') { continue }
        $code = 0; $meaning = ''
        try {
            $pc = Get-PnpDeviceProperty -InstanceId $pd.InstanceId -KeyName 'DEVPKEY_Device_ProblemCode' -ErrorAction SilentlyContinue
            if ($pc -and $pc.Data) { $code = [int]$pc.Data }
        } catch {}
        $meaning = switch ($code) {
            1 {'Device is not configured correctly'} 10 {'Cannot start'} 22 {'Disabled'}
            28 {'Drivers not installed'} 31 {'Driver load failure'} 43 {'Reported failure'}
            45 {'Currently not connected'} 52 {'Unsigned driver'} default {"Code $code"} }
        $hw = ''
        try {
            $prop = Get-PnpDeviceProperty -InstanceId $pd.InstanceId -KeyName 'DEVPKEY_Device_HardwareIds' -ErrorAction SilentlyContinue
            if ($prop) { $hw = @($prop.Data) | Where-Object { $_ -match '^(PCI|USB|HID|ACPI|SWD|BTH)' } | Select-Object -First 1 }
        } catch {}
        $problem += [pscustomobject]@{ Name=[string]$pd.FriendlyName; Man=[string]$pd.Manufacturer
            HwId=[string]$hw; PnpId=[string]$pd.InstanceId; Class=[string]$pd.Class
            Status='problem'; Detail=$meaning; Ver=''; Date='' }
    }
    & $prog 55
    # === Treiber-Details per WMI-Job MIT TIMEOUT (haengt nicht ewig) ===
    & $log 'Phase 2/3: Treiber-Versionen + Alters-Check (Timeout 25s) ...'
    $drvCode = {
        Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop |
            Where-Object { $_.DeviceName -and $_.DriverVersion } |
            ForEach-Object {
                $dt = $null
                try { if ($_.DriverDate) { $dt = [Management.ManagementDateTimeConverter]::ToDateTime($_.DriverDate) } } catch {}
                [pscustomobject]@{ DeviceName=$_.DeviceName; Manufacturer=$_.Manufacturer
                    DriverVersion=$_.DriverVersion; DriverDate=$dt; InfName=$_.InfName }
            }
    }
    $allDrv = @(); $wmiOk = $false
    try {
        $job = Start-Job -ScriptBlock $drvCode
        if (Wait-Job $job -Timeout 25) {
            $allDrv = @($job | Receive-Job)
            $wmiOk = ($allDrv.Count -gt 0)
        } else { Stop-Job $job -ErrorAction SilentlyContinue }
        Remove-Job $job -Force -ErrorAction SilentlyContinue
    } catch {}
    if (-not $wmiOk) { & $log 'Hinweis: WMI-Treiberabfrage Timeout/leer - Liste ohne Versionsdetails.' }
    & $prog 75
    $cutoff = (Get-Date).AddYears(-3)
    $outdatedNames = @{}
    $inv = @($allDrv | Sort-Object { if ($_.DriverDate) { $_.DriverDate } else { [datetime]::MinValue } } -Descending | Select-Object -First 120)
    foreach ($d in $allDrv) {
        if ($d.DriverDate -and $d.DriverDate -lt $cutoff) { $outdatedNames[[string]$d.DeviceName] = $true }
    }
    # Hardware-Filter: Software/Virtual/Geraete ohne Klasse raus
    $hwDevs = @($pnpDevs | Where-Object {
        $_.Class -and $_.Class -notin @('SoftwareDevice','Firmware') -and
        $_.FriendlyName -and $_.FriendlyName -notmatch '(?i)^(Microsoft |ACPI |NDIS |USB4 |PCI Express|System Firmware|Motherboard resources|Programmable interrupt|DMA |I/O |Memory |Reserved|ACPI\()' -and
        $_.InstanceId -match '^(PCI|USB|HID|ACPI|SWD|BTH|STOR|SCSI|BLUETOOTH|DISPLAY|HDAUDIO|MEDIA|NET|SDIO|UEFI)'
    } | Select-Object -First 200)
    & $prog 85
    & $log "Geraete: $($hwDevs.Count) Hardware + $($problem.Count) Problem - wird zusammengefuehrt ..."
    $total = $problem.Count + $hwDevs.Count
    $done = 0
    $out = @()
    foreach ($p in $problem) {
        $out += $p
        $done++
        & $prog (85 + [math]::Floor(($done / [math]::Max(1,$total)) * 14))
    }
    $drvByName = @{}
    foreach ($d in $inv) { $drvByName[[string]$d.DeviceName] = $d }
    $i = 0
    foreach ($pd in $hwDevs) {
        $i++
        if (($i % 10) -eq 0) { & $prog (85 + [math]::Floor((($done + $i) / [math]::Max(1,$total)) * 14)) }
        $name = [string]$pd.FriendlyName
        $drv = $drvByName[$name]
        $ver = ''; $date = ''; $man = [string]$pd.Manufacturer; $st = 'ok'
        if ($drv) {
            $ver = "v$($drv.DriverVersion)"; $man = [string]$drv.Manufacturer
            $date = $(if($drv.DriverDate){$drv.DriverDate.ToString('yyyy-MM-dd')}else{''})
            if ($outdatedNames.ContainsKey($name)) { $st = 'outdated' }
        } elseif (-not $wmiOk) { $st = 'ok' }
        $out += [pscustomobject]@{ Name=$name; Man=$man; HwId=''; PnpId=[string]$pd.InstanceId; Class=[string]$pd.Class
            Status=$st; Detail=$ver; Ver=[string]$(if($drv){$drv.DriverVersion}else{''}); Date=$date }
    }
    & $prog 100
    return @($out)
}

function Invoke-SysPilotElevated {
    <# Fuehrt ein Skript elevated aus (UAC) und liefert die
       Ausgabe zurueck (ueber Temp-Datei). #>
    param([Parameter(Mandatory)][string]$Script, [int]$TimeoutSec = 300)
    $tmp = Join-Path $env:TEMP ("syspilot-elev-" + [guid]::NewGuid().ToString('N') + ".ps1")
    $outF = $tmp + '.out'
    Set-Content -Path $tmp -Value $Script -Encoding UTF8
    try {
        $p = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList @(
            '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden',
            '-Command',"& { try { `$o = & '$tmp' 2>&1 | Out-String; Set-Content '$outF' `$o -Encoding UTF8 } catch { Set-Content '$outF' `$_.Exception.Message -Encoding UTF8 } }")
        if (Test-Path $outF) { return (Get-Content $outF -Raw -Encoding UTF8) }
        return "exit=$($p.ExitCode) (keine Ausgabe)"
    } catch { return "Elevation fehlgeschlagen: $($_.Exception.Message)" }
    finally { Remove-Item $tmp,$outF -Force -ErrorAction SilentlyContinue }
}

function Backup-SysPilotDeviceDriver {
    <# Sichert den aktuellen Treiber eines Geraets: findet die
       OEM-INF im Treiberstore und exportiert sie via pnputil
       (elevated). #>
    param([Parameter(Mandatory)]$Device)
    $inf = ''
    try {
        $q = Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop |
            Where-Object { $_.DeviceName -eq $Device.Name -and $_.InfName } |
            Sort-Object DriverDate -Descending | Select-Object -First 1
        if ($q) { $inf = [string]$q.InfName }
    } catch {}
    if (-not $inf) { return @{ Ok=$false; Error='Keine INF fuer Geraet gefunden' } }
    $safe = ($Device.Name -replace '[^\w\- ]','_')
    $dir = Join-Path $env:LOCALAPPDATA "SysPilot\DriverBackup\$safe"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $script = "pnputil /export-driver `"$inf`" `"$dir`" 2>&1 | Out-String"
    $res = Invoke-SysPilotElevated -Script $script -TimeoutSec 120
    $ok = ($res -match '(?i)completed successfully|erfolgreich')
    return @{ Ok=$ok; Dir=$dir; Inf=$inf; Output=$res }
}

function Restore-SysPilotDriverBackup {
    <# Spielt einen Treiber-Backup-Ordner (INF-Dateien) wieder
       ein: pnputil /add-driver. #>
    param([Parameter(Mandatory)][string]$BackupDir)
    if (-not (Test-Path $BackupDir)) { return @{ Ok=$false; Error="Ordner nicht gefunden: $BackupDir" } }
    $infs = @(Get-ChildItem $BackupDir -Recurse -Filter *.inf -ErrorAction SilentlyContinue)
    if ($infs.Count -eq 0) { return @{ Ok=$false; Error='Keine INF-Dateien im Backup' } }
    $script = "pnputil /add-driver `"$BackupDir\*.inf`" /subdirs /install 2>&1 | Out-String"
    $res = Invoke-SysPilotElevated -Script $script -TimeoutSec 300
    $ok = ($res -match '(?i)completed successfully|erfolgreich|added and installed')
    return @{ Ok=$ok; Output=$res; Count=$infs.Count }
}

function Get-SysPilotCatalogCabUrl {
    <# Microsoft Update Catalog: GUID -> direkter .cab-Download-Link
       (DownloadDialog-Mechanismus). #>
    param([Parameter(Mandatory)][string]$Guid)
    try {
        $body = "updateIDs=[{`"size`":0,`"updateID`":`"$Guid`"}]"
        $r = Invoke-WebRequest 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx' -Method Post `
            -Body $body -ContentType 'application/json' -UseBasicParsing -TimeoutSec 30 `
            -Headers @{ 'User-Agent'='Mozilla/5.0'; 'Referer'="https://www.catalog.update.microsoft.com/UpdateDetail.aspx?updateid=$Guid" }
        $m = [regex]::Match($r.Content, 'https?://[^"''<>\s]+\.cab')
        if ($m.Success) { return $m.Value }
        $m2 = [regex]::Match($r.Content, 'https?://[^"''<>\s]*download\.windowsupdate\.com[^"''<>\s]+')
        if ($m2.Success) { return $m2.Value }
    } catch {}
    return $null
}

function Install-SysPilotWUDriverQuiet {
    <# WU-Treiber-Installation ohne Konsolen-Bestaetigung
       (User hat in der WPF-UI schon bestaetigt). #>
    param([Parameter(Mandatory)][string]$Title, [scriptblock]$OnProgress = { param($m) })
    $say = { param($m) if($OnProgress){ $null = & $OnProgress ([string]$m) } }
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        $safeTitle = $Title -replace "'","''"
        $script = @"
`$session = New-Object -ComObject Microsoft.Update.Session
`$searcher = `$session.CreateUpdateSearcher()
`$result = `$searcher.Search("IsInstalled=0 and Type='Driver'")
`$match = `$null
foreach (`$u in `$result.Updates) { if (`$u.Title -eq '$safeTitle') { `$match = `$u; break } }
if (-not `$match) { 'NOTFOUND'; exit 1 }
if (-not `$match.EulaAccepted) { `$match.AcceptEula() | Out-Null }
`$dl = `$session.CreateUpdateDownloader()
`$dl.Updates = `$result.Updates | Where-Object { `$_.Title -eq '$safeTitle' }
`$dlRes = `$dl.Download()
if (`$dlRes.ResultCode -ne 2) { "DLFAIL`$(`$dlRes.ResultCode)"; exit 2 }
`$inst = `$session.CreateUpdateInstaller()
`$inst.Updates = `$result.Updates | Where-Object { `$_.Title -eq '$safeTitle' }
`$instRes = `$inst.Install()
if (`$instRes.ResultCode -eq 2) { 'OK' } else { "INSTFAIL`$(`$instRes.ResultCode)" }
"@
        $out = Invoke-SysPilotElevated -Script $script -TimeoutSec 600
        if ($out -match '(?m)^OK') { return @{ Ok=$true; Detail='WU installiert (elevated)' } }
        return @{ Ok=$false; Error=(($out -split "`n" | Select-Object -Last 3) -join ' ') }
    }
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $result = $searcher.Search("IsInstalled=0 and Type='Driver'")
        $match = $null
        foreach ($u in $result.Updates) { if ($u.Title -eq $Title) { $match = $u; break } }
        if (-not $match) { return @{ Ok=$false; Error='Update nicht gefunden' } }
        if (-not $match.EulaAccepted) { $match.AcceptEula() | Out-Null }
        & $say 'WU: Download ...'
        $dl = $session.CreateUpdateDownloader()
        $dl.Updates = $result.Updates | Where-Object { $_.Title -eq $Title }
        $dlRes = $dl.Download()
        if ($dlRes.ResultCode -ne 2) { return @{ Ok=$false; Error="Download fehlgeschlagen ($($dlRes.ResultCode))" } }
        & $say 'WU: Installation ...'
        $inst = $session.CreateUpdateInstaller()
        $inst.Updates = $result.Updates | Where-Object { $_.Title -eq $Title }
        $instRes = $inst.Install()
        if ($instRes.ResultCode -eq 2) { return @{ Ok=$true; Detail='WU installiert' } }
        return @{ Ok=$false; Error="Install fehlgeschlagen ($($instRes.ResultCode))" }
    } catch { return @{ Ok=$false; Error=$_.Exception.Message } }
}

function Install-SysPilotDriverAuto {
    <# Selbsttaetige Treiber-Installation: Download + je nach
       Dateityp cab/zip/7z -> entpacken + pnputil, msi/exe ->
       Silent-Versuche dann GUI. Erst stiller Store-Backup. #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$DevName = '',
        [scriptblock]$OnProgress = { param($m) }
    )
    $say = { param($m) if($OnProgress){ $null = & $OnProgress ([string]$m) } }
    if (-not (Get-Command Invoke-SysPilotFileDownload -ErrorAction SilentlyContinue)) {
        Import-Module (Join-Path $PSScriptRoot 'SmartDownload.psm1') -Force -ErrorAction SilentlyContinue
    }
    if (-not (Get-Command Invoke-SysPilotFileDownload -ErrorAction SilentlyContinue)) {
        return @{ Ok=$false; Error='Download-Helper nicht verfuegbar' }
    }
    $tmp = Join-Path $env:TEMP ("syspilot-drv-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $ext = ''
    try { $ext = ([uri]$Url).AbsolutePath.Split('.')[-1].ToLower() } catch {}
    if ($ext -notin @('exe','msi','zip','7z','cab')) { $ext = 'bin' }
    $file = Join-Path $tmp "driver.$ext"
    & $say "Download: $Url"
    $ok = Invoke-SysPilotFileDownload -Url $Url -OutFile $file -Label 'Treiber' -TimeoutSec 600
    if (-not $ok -or -not (Test-Path $file)) { return @{ Ok=$false; Error='Download fehlgeschlagen' } }
    & $say ("Geladen: {0} MB ({1})" -f [int]((Get-Item $file).Length/1MB), $ext)

    # stiller Treiberstore-Backup (elevated, Fehler ignoriert)
    try {
        $bk = Join-Path $env:LOCALAPPDATA ("SysPilot\DriverBackup\store-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        $script = "New-Item -ItemType Directory -Path '$bk' -Force | Out-Null; pnputil /export-driver * '$bk' 2>&1 | Out-String"
        $null = Invoke-SysPilotElevated -Script $script -TimeoutSec 600
        & $say "Treiber-Backup: $bk"
    } catch {}

    $pnputil = {
        param($infDir)
        $s = "pnputil /add-driver `"$infDir\*.inf`" /subdirs /install 2>&1 | Out-String"
        $r = Invoke-SysPilotElevated -Script $s -TimeoutSec 600
        return @{ Ok=($r -match '(?i)completed successfully|erfolgreich|added and installed|installiert'); Output=$r }
    }
    $installExe = {
        param($exePath)
        $flags = @('/S','/silent','/verysilent','/quiet','-s','--silent','/qn')
        foreach ($f in $flags) {
            & $say "Starte Installer silent: $exePath $f"
            try {
                $pr = Start-Process -FilePath $exePath -ArgumentList $f -PassThru -ErrorAction Stop
                Start-Sleep -Seconds 5
                if (-not $pr.HasExited) { & $say 'Installer laeuft (GUI/Progress) - bitte Fenster beachten.'; return @{ Ok=$true; Detail="Installer gestartet: $exePath $f" } }
                if ($pr.ExitCode -eq 0 -or $pr.ExitCode -eq 1641 -or $pr.ExitCode -eq 3010) { return @{ Ok=$true; Detail="Installer fertig (Exit $($pr.ExitCode)): $exePath $f" } }
            } catch { & $say "Flag $f fehlgeschlagen: $($_.Exception.Message)" }
        }
        # Letzter Ausweg: normal starten (User bedient GUI)
        & $say "Starte Installer interaktiv: $exePath"
        try { Start-Process $exePath; return @{ Ok=$true; Detail="Installer geoeffnet: $exePath (bitte im Fenster bestaetigen)" } }
        catch { return @{ Ok=$false; Error="Installer-Start fehlgeschlagen: $($_.Exception.Message)" } }
    }
    $installMsi = {
        param($msiPath)
        $s = "msiexec /i `"$msiPath`" /qn /norestart 2>&1 | Out-String; exit `$LASTEXITCODE"
        $r = Invoke-SysPilotElevated -Script $s -TimeoutSec 600
        if ($r -match '(?i)completed|erfolgreich|0\s*$') { return @{ Ok=$true; Detail="MSI installiert: $msiPath" } }
        return @{ Ok=$false; Error="msiexec: $(($r -split "`n" | Select-Object -Last 3) -join ' ')" }
    }

    switch ($ext) {
        'cab' {
            $extDir = Join-Path $tmp 'cab'; New-Item -ItemType Directory -Path $extDir -Force | Out-Null
            & $say 'Entpacke .cab ...'
            $null = & expand.exe $file -F:* $extDir 2>&1
            $res = & $pnputil $extDir
            if ($res.Ok) { return @{ Ok=$true; Detail="Treiber installiert (cab)"; BackupNote='store-Backup erstellt' } }
            return @{ Ok=$false; Error="pnputil: $(($res.Output -split "`n" | Select-Object -Last 3) -join ' ')" }
        }
        'zip' {
            $extDir = Join-Path $tmp 'zip'; New-Item -ItemType Directory -Path $extDir -Force | Out-Null
            & $say 'Entpacke .zip ...'
            try { Expand-Archive -Path $file -DestinationPath $extDir -Force -ErrorAction Stop } catch { & tar -xf $file -C $extDir 2>$null }
            $res = & $pnputil $extDir
            if ($res.Ok) { return @{ Ok=$true; Detail="Treiber installiert (zip)"; BackupNote='store-Backup erstellt' } }
            $exeIn = @(Get-ChildItem $extDir -Recurse -Include *.exe,*.msi -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($exeIn) { if ($exeIn.Extension -eq '.msi') { return & $installMsi $exeIn.FullName } else { return & $installExe $exeIn.FullName } }
            return @{ Ok=$false; Error='Kein installierbares INF/Programm im Archiv' }
        }
        '7z' {
            $extDir = Join-Path $tmp '7z'; New-Item -ItemType Directory -Path $extDir -Force | Out-Null
            $sz = Get-Command 7z -ErrorAction SilentlyContinue; if (-not $sz) { $sz = Get-Command 7za -ErrorAction SilentlyContinue }
            if ($sz) { & $sz.Source x $file "-o$extDir" -y | Out-Null } else { & tar -xf $file -C $extDir 2>$null }
            $res = & $pnputil $extDir
            if ($res.Ok) { return @{ Ok=$true; Detail="Treiber installiert (7z)"; BackupNote='store-Backup erstellt' } }
            $exeIn = @(Get-ChildItem $extDir -Recurse -Include *.exe,*.msi -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($exeIn) { if ($exeIn.Extension -eq '.msi') { return & $installMsi $exeIn.FullName } else { return & $installExe $exeIn.FullName } }
            return @{ Ok=$false; Error='Kein installierbares INF/Programm im Archiv' }
        }
        'msi' { return & $installMsi $file }
        default { return & $installExe $file }
    }
}

function Show-SysPilotDriverStudioWindow {
    <# SmartDriver STUDIO: vollautomatische Hardware-Analyse,
       Auto-Treibersuche, Statusfarben, Auto-Backup + Restore. #>
    param([string]$Title='SmartDriver Studio - Treiber-Werkstatt', $Owner=$null)
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
        Write-Warning 'Show-SysPilotDriverStudioWindow braucht STA.'
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
        Title="$Title" Width="1240" Height="760" WindowStartupLocation="CenterOwner"
        Background="#FF1E1E2E" Foreground="#FFEAEAF2" FontFamily="Segoe UI">
  <Window.Resources>
    <Style TargetType="Button"><Setter Property="Background" Value="#FF2D2D44"/><Setter Property="Foreground" Value="#FFEAEAF2"/><Setter Property="BorderBrush" Value="#FF4A4A6A"/><Setter Property="Padding" Value="10,4"/><Setter Property="Margin" Value="3"/><Setter Property="Cursor" Value="Hand"/></Style>
    <Style TargetType="ListBoxItem"><Setter Property="Padding" Value="5,2"/><Setter Property="Foreground" Value="#FFEAEAF2"/><Setter Property="FontSize" Value="12"/><Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#FF34344E"/></Trigger><Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#CCE4EAF2"/><Setter Property="Foreground" Value="#FF1E1E2E"/></Trigger></Style.Triggers></Style>
    <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#FFEAEAF2"/></Style>
    <Style TargetType="CheckBox"><Setter Property="Foreground" Value="#FFEAEAF2"/><Setter Property="VerticalAlignment" Value="Center"/></Style>
    <Style TargetType="TextBox"><Setter Property="Background" Value="#FF252538"/><Setter Property="Foreground" Value="#FFEAEAF2"/><Setter Property="BorderBrush" Value="#FF4A4A6A"/><Setter Property="Padding" Value="6,4"/></Style>
    <Style TargetType="ProgressBar"><Setter Property="Height" Value="4"/><Setter Property="Minimum" Value="0"/><Setter Property="Maximum" Value="100"/><Setter Property="Value" Value="0"/><Setter Property="Visibility" Value="Collapsed"/><Setter Property="Margin" Value="0,0,0,6"/><Setter Property="Foreground" Value="#FF4FC3F7"/><Setter Property="Background" Value="#FF2A2A3A"/></Style>
  </Window.Resources>
  <DockPanel Margin="12">
    <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,8">
      <Button x:Name="BtnAnalyse" Content="Neu scannen" ToolTip="Hardware-Analyse neu starten"/>
      <Button x:Name="BtnSearch" Content="Suchen" ToolTip="Ausgewaehlte Geraete: WU + MS-Katalog + Web + Herbert" IsEnabled="False"/>
      <Button x:Name="BtnInstall" Content="Installieren" ToolTip="Markierte Kandidaten installieren (Multi-Select)" IsEnabled="False"/>
      <Button x:Name="BtnHerbert" Content="Herbert Auto" ToolTip="Herbert waehlt besten Kandidaten und installiert selbsttaetig" IsEnabled="False"/>
      <Button x:Name="BtnAssistent" Content="Assistent" ToolTip="Pilot Herbert als schwebenden Assistenten rechts oeffnen"/>
      <Separator Margin="8,4" Background="#FF4A4A6A"/>
      <Button x:Name="BtnBackup" Content="Sichern" ToolTip="Treiber der ausgewaehlten Geraete manuell sichern"/>
      <Button x:Name="BtnRestore" Content="Restore" ToolTip="Treiber-Backup wiederherstellen"/>
      <Separator Margin="8,4" Background="#FF4A4A6A"/>
      <Button x:Name="BtnCatalog" Content="Webkatalog" ToolTip="Treiber-Quellen-Katalog oeffnen"/>
      <Button x:Name="BtnSingle" Content="Einzel-Suche" ToolTip="Klassische SmartDrivers-Einzelrecherche"/>
      <Button x:Name="BtnClose" Content="Schliessen" HorizontalAlignment="Right"/>
    </StackPanel>
    <Border DockPanel.Dock="Bottom" Background="#FF16161F" BorderBrush="#FF4A4A6A" BorderThickness="0,1,0,0" Padding="8,6">
      <StackPanel>
        <ProgressBar x:Name="ProgBar"/>
        <TextBox x:Name="LogBox" Height="90" IsReadOnly="True" TextWrapping="NoWrap" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="11" Background="#FF0C0C14" Foreground="#FF9FE89F" BorderThickness="0"/>
        <TextBlock x:Name="TxtStatus" FontSize="11" Foreground="#FF9E9E9E" Margin="0,5,0,0" TextWrapping="Wrap"/>
      </StackPanel>
    </Border>
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="340"/><ColumnDefinition Width="10"/><ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <Border Background="#FF252538" CornerRadius="6" Padding="8">
        <DockPanel>
          <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,4">
            <TextBlock Text="Geraete" FontWeight="Bold" Foreground="#FF4FC3F7" VerticalAlignment="Center"/>
            <TextBlock x:Name="TxtDevCount" Text="" Foreground="#FF9E9E9E" FontSize="10" VerticalAlignment="Center" Margin="8,0,0,0"/>
          </StackPanel>
          <ListBox x:Name="DevList" Background="Transparent" BorderThickness="0"/>
        </DockPanel>
      </Border>
      <GridSplitter Grid.Column="1" Width="8" HorizontalAlignment="Stretch" Background="#FF2A2A3A"/>
      <Grid Grid.Column="2">
        <Grid.RowDefinitions>
          <RowDefinition Height="*"/><RowDefinition Height="8"/><RowDefinition Height="150"/>
        </Grid.RowDefinitions>
        <Border Grid.Row="0" Background="#FF14141E" CornerRadius="4" Padding="4">
          <DockPanel>
            <TextBlock DockPanel.Dock="Top" Text="Treiber-Kandidaten" FontWeight="Bold" Foreground="#FF4FC3F7" Margin="4,2,0,4"/>
            <ListBox x:Name="CandList" Background="Transparent" BorderThickness="0"/>
          </DockPanel>
        </Border>
        <GridSplitter Grid.Row="1" Height="8" HorizontalAlignment="Stretch" Background="#FF2A2A3A"/>
        <Border Grid.Row="2" Background="#FF101018" CornerRadius="4" Padding="8">
          <DockPanel>
            <TextBlock DockPanel.Dock="Top" Text="Herbert" FontWeight="Bold" Foreground="#FF9CCC65" Margin="0,0,0,4"/>
            <RichTextBox x:Name="HerbBox" IsReadOnly="True" Background="Transparent" BorderThickness="0" Foreground="#FFEAEAF2" FontFamily="Segoe UI" FontSize="12" VerticalScrollBarVisibility="Auto"/>
          </DockPanel>
        </Border>
      </Grid>
    </Grid>
  </DockPanel>
</Window>
"@
    $win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$xaml)))
    if (Test-SysPilotWindowAlreadyOpen -Key 'syspilot-driver-studio' -Win $win) { return }
    if ($Owner) { try { $win.Owner=$Owner } catch {} } else { $win.WindowStartupLocation='CenterScreen' }
    $fc = @{}
    foreach ($n in 'BtnAnalyse','BtnSearch','BtnInstall','BtnHerbert','BtnAssistent','BtnBackup','BtnRestore','BtnCatalog','BtnSingle','BtnClose','ProgBar','LogBox','TxtStatus','DevList','CandList','HerbBox','TxtDevCount') {
        $fc[$n] = $win.FindName($n)
    }
    $modDir = $PSScriptRoot
    $st = @{
        Devices=@(); Candidates=@(); CandView=@()
        Queue=(New-Object System.Collections.Concurrent.ConcurrentQueue[string])
        Rs=$null; Ps=$null; Async=$null; JobKind=''
        JobStart=$null; JobDone=$true; Busy=$false
        Next=$null; Codes=@{}; StartJob=$null
    }

    $setStatus = { param($t,$c) $fc.TxtStatus.Text=[string]$t; $fc.TxtStatus.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString($c) }
    $logFile = Join-Path $env:LOCALAPPDATA 'SysPilot\logs\drvstudio.log'
    try { $null = New-Item -ItemType Directory -Path (Split-Path $logFile) -Force } catch {}
    $sayLog = { param($l) if($l){
        $line = [string]$l
        $fc.LogBox.AppendText($line+"`n"); try{$fc.LogBox.ScrollToEnd()}catch{}
        try { Add-Content -Path $logFile -Value ("{0} {1}" -f (Get-Date -Format 'HH:mm:ss'), $line) -Encoding UTF8 } catch {}
    } }
    $drainQ = { $l=$null; while($st.Queue.TryDequeue([ref]$l)){
        if($l -is [string] -and $l -match '^PROGRESS\|(\d+)$'){
            try{ $fc.ProgBar.IsIndeterminate=$false; $fc.ProgBar.Value=[double]$Matches[1]; $fc.ProgBar.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString('#FF4FC3F7') }catch{}
        } else { & $sayLog $l }
        $l=$null } }

    # ---------- Item-Templates (Geraete + Kandidaten) ----------
    $mkTemplate = {
        param($statusProp)
        $dt = New-Object Windows.DataTemplate
        $sp = New-Object Windows.FrameworkElementFactory([Windows.Controls.StackPanel],'sp')
        $sp.SetValue([Windows.Controls.StackPanel]::OrientationProperty,[Windows.Controls.Orientation]::Horizontal)
        $cb = New-Object Windows.FrameworkElementFactory([Windows.Controls.CheckBox],'cb')
        $cb.SetBinding([Windows.Controls.Primitives.ToggleButton]::IsCheckedProperty, (New-Object Windows.Data.Binding('Checked') ))
        $cb.SetValue([Windows.Controls.CheckBox]::VerticalAlignmentProperty,[Windows.VerticalAlignment]::Center)
        $null = $sp.AppendChild($cb)
        $tb = New-Object Windows.FrameworkElementFactory([Windows.Controls.TextBlock],'tb')
        $tb.SetBinding([Windows.Controls.TextBlock]::TextProperty,(New-Object Windows.Data.Binding('Label')))
        $tb.SetValue([Windows.Controls.TextBlock]::VerticalAlignmentProperty,[Windows.VerticalAlignment]::Center)
        $tb.SetValue([Windows.Controls.TextBlock]::TextTrimmingProperty,[Windows.TextTrimming]::CharacterEllipsis)
        $stTb = New-Object Windows.Style
        $stTb.TargetType=[Windows.Controls.TextBlock]
        # problem=rot, update/veraltet=orange, current/ok=gruen, info=grau
        foreach($pair in @(@('problem','#FFFF8A80'),@('update','#FFFFB74D'),@('outdated','#FFFFB74D'),@('current','#FF81C784'),@('ok','#FF81C784'),@('info','#FF9E9E9E'))){
            $tr = New-Object Windows.DataTrigger
            $tr.Binding = New-Object Windows.Data.Binding($statusProp)
            $tr.Value = $pair[0]
            $tr.Setters.Add((New-Object Windows.Setter([Windows.Controls.TextBlock]::ForegroundProperty,[Windows.Media.BrushConverter]::new().ConvertFromString($pair[1]))))
            $stTb.Triggers.Add($tr)
        }
        $tb.SetValue([Windows.Controls.TextBlock]::StyleProperty,$stTb)
        $null = $sp.AppendChild($tb)
        $dt.VisualTree = $sp
        return $dt
    }
    try { $fc.DevList.ItemTemplate = & $mkTemplate 'Status'; $fc.DevList.DisplayMemberPath=$null } catch {}
    try { $fc.CandList.ItemTemplate = & $mkTemplate 'Status'; $fc.CandList.DisplayMemberPath=$null } catch {}

    $st.Rs=$null;$st.Ps=$null;$st.Async=$null
    $st.JobStart=$null;$st.JobDone=$true
    $st.Busy=$false
    $stopJob = { if($st.Async){try{$st.Ps.Stop();$st.Ps.Dispose()}catch{};try{$st.Rs.Close();$st.Rs.Dispose()}catch{}};$st.Ps=$null;$st.Rs=$null;$st.Async=$null }

    # Geraete fuellen; Checked-Zustand nach Schluessel (Name|HwId) erhalten
    $fillDevices = {
        param([bool]$AutoCheck=$false)
        $old=@{}
        try{ foreach($it in @($fc.DevList.Items)){ if($it.Dev){ $old["$($it.Dev.Name)|$($it.Dev.HwId)"]=$it.Checked } } }catch{}
        $fc.DevList.Items.Clear()
        $prob=0;$outd=0;$upd=0;$cur=0
        foreach($d in $st.Devices){
            $key="$($d.Name)|$($d.HwId)"
            $chk = $false
            if($old.ContainsKey($key)){ $chk=$old[$key] }
            elseif($AutoCheck -and ($d.Status -eq 'problem' -or $d.Status -eq 'outdated')){ $chk=$true }
            if($d.Status -eq 'problem'){$prob++}elseif($d.Status -eq 'outdated' -or $d.Status -eq 'update'){$outd++}elseif($d.Status -eq 'current' -or $d.Status -eq 'ok'){$cur++}
            $lbl = "$($d.Name)  [$($d.Status)]$(if($d.Detail){" - $($d.Detail)"})"
            [void]$fc.DevList.Items.Add([pscustomobject]@{ Label=$lbl; Status=$d.Status; Checked=$chk; Dev=$d })
        }
        $fc.TxtDevCount.Text = "$($st.Devices.Count) Geraete ($prob Problem, $outd Update, $cur aktuell)"
    }
    $fillCandidates = {
        $fc.CandList.Items.Clear()
        $st.CandView=@()
        foreach($c in $st.Candidates){
            # installierbar -> orange 'update', sonst grau 'info'
            $installable = ($c.Kind -in 'wu','cab','catalog') -or ($c.Url -match '\.(exe|msi|zip|7z|cab)(\?|$)')
            $status = $(if($installable){'update'}else{'info'})
            # DevObj fuer automatisches Backup/Restore beim Installieren anhaengen
            $devObj = $null
            foreach($d in $st.Devices){ if($d.Name -eq $c.Dev){ $devObj=$d; break } }
            $v = [pscustomobject]@{ Label=$c.Label; Status=$status; Checked=$installable; Dev=$c.Dev; Tag=$c.Tag; Url=$c.Url; Kind=$c.Kind; Raw=$c.Raw; Cand=$c; DevObj=$devObj }
            $st.CandView += $v
            [void]$fc.CandList.Items.Add($v)
        }
        $fc.BtnInstall.IsEnabled=($st.CandView.Count -gt 0)
        $fc.BtnHerbert.IsEnabled=($st.CandView.Count -gt 0)
    }

    $poll = New-Object System.Windows.Threading.DispatcherTimer
    $poll.Interval=[timespan]::FromMilliseconds(400)
    $poll.Add_Tick({
        & $drainQ
        # Warteschlange: naechste User-Aktion starten (Auto-Kette $st.Next
        # hat Prioritaet und wird im Completion-Block gestartet)
        if(-not $st.Busy -and -not $st.Async -and $st.Pending -and $st.Pending.Count -gt 0){
            $pn=$st.Pending.Dequeue()
            & $sayLog ">>> Warteschlange: $($pn.Kind)"
            & $st.StartJob $pn.Code $pn.Kind $pn.Status $pn.Vars
        }
        if(-not $st.Async){return}
        if(-not $st.JobDone -and $st.JobStart){
            $el=[int]((Get-Date)-$st.JobStart).TotalSeconds
            if($el -gt 3 -and (($el % 10) -lt 1)){ & $sayLog ">>> Job laeuft noch (${el}s)" }
            if($el -gt 240){ & $sayLog '>>> Job-Timeout 240s - wird abgebrochen'; & $stopJob; $st.Busy=$false; & $setStatus 'Job-Timeout' '#FFFF5252'; return }
        }
        if($st.Async.IsCompleted -and -not $st.JobDone){
            try {
            $st.JobDone=$true
            & $sayLog ">>> Job abgeschlossen - verarbeite Ergebnis"
            & $drainQ
            $out=@()
            try{$out=@($st.Ps.EndInvoke($st.Async))}catch{& $sayLog "Job-Fehler: $($_.Exception.Message)"}
            try { foreach($e in @($st.Ps.Streams.Error)){ if($e){ & $sayLog "  [FEHLER] $($e.Exception.Message)" } } } catch {}
            & $stopJob
            & $sayLog ">>> out=$(@($out).Count) items"
            $st.Busy=$false;$fc.ProgBar.Visibility='Collapsed'
            $o=$out | Where-Object {$_ -is [hashtable]} | Select-Object -First 1
            $kind = $(if($st.JobKind){$st.JobKind}else{'?'})
            if($o -and $o['Ok']){
                if($kind -eq 'analyse'){
                    $st.Devices = @($o['Devices'])
                    & $fillDevices $true
                    & $setStatus "Analyse: $($st.Devices.Count) Geraete gefunden." '#FF81C784'
                    # Auto-Backup nur fuer Problem/Geraete mit altem Treiber
                    $bakDevs = @($st.Devices | Where-Object { $_.Status -eq 'problem' -or $_.Status -eq 'outdated' } | Select-Object -First 8)
                    $selDevs = @($fc.DevList.Items | Where-Object { $_.Checked } | ForEach-Object { $_.Dev } | Select-Object -First 8)
                    if($selDevs.Count -eq 0){
                        # Keine Auffaelligkeiten: Stichprobe automatisch durchsuchen
                        $selDevs = @($st.Devices | Where-Object { $_.Status -eq 'ok' } | Select-Object -First 8)
                        if($selDevs.Count -gt 0){
                            & $sayLog ">>> Keine Problemgeraete - automatische Stichprobe: $($selDevs.Count) Geraete"
                            foreach($it in @($fc.DevList.Items)){ if($selDevs -contains $it.Dev){ $it.Checked=$true } }
                        }
                    }
                    if($bakDevs.Count -gt 0 -and $st.Codes['backup'] -and $st.Codes['search'] -and $st.StartJob){
                        & $sayLog ">>> Auto-Backup fuer $($bakDevs.Count) Geraet(e) ..."
                        $st.Next = @{ Code=$st.Codes['backup']; Kind='backup'; Vars=@{ devs=$bakDevs }; Status="Auto-Backup laeuft ($($bakDevs.Count) Geraete) ..." }
                    } elseif($selDevs.Count -gt 0 -and $st.Codes['search'] -and $st.StartJob){
                        & $sayLog ">>> Starte automatische Treiber-Suche fuer $($selDevs.Count) Geraet(e) ..."
                        $st.Next = @{ Code=$st.Codes['search']; Kind='search'; Vars=@{ selDevs=$selDevs }; Status="Automatische Treiber-Suche laeuft ..." }
                    } else {
                        & $setStatus "Analyse: $($st.Devices.Count) Geraete - nichts zu tun." '#FF81C784'
                    }
                } elseif($kind -eq 'backup'){
                    $res = @($o['Results'])
                    $okc = @($res | Where-Object { $_.Ok }).Count
                    & $sayLog "Backup fertig: $okc/$($res.Count) Geraete gesichert."
                    # danach automatisch suchen (abgehaekte Geraete, max 8)
                    $sel = @($fc.DevList.Items | Where-Object { $_.Checked } | ForEach-Object { $_.Dev } | Select-Object -First 8)
                    if($sel.Count -gt 0 -and $st.Codes['search'] -and $st.StartJob){
                        & $sayLog ">>> Starte automatische Treiber-Suche fuer $($sel.Count) Geraet(e) ..."
                        $st.Next = @{ Code=$st.Codes['search']; Kind='search'; Vars=@{ selDevs=$sel }; Status="Automatische Treiber-Suche laeuft ..." }
                    }
                } elseif($kind -eq 'search'){
                    $st.Candidates = @($o['Candidates'])
                    & $fillCandidates
                    # Geraete-Status nach Fund aktualisieren: update > current
                    $byDev=@{}
                    foreach($v in $st.CandView){ if(-not $byDev.ContainsKey($v.Dev)){$byDev[$v.Dev]=@()}; $byDev[$v.Dev]+=$v }
                    foreach($d in $st.Devices){
                        if($byDev.ContainsKey($d.Name)){
                            $hasUpd = @($byDev[$d.Name] | Where-Object { $_.Status -eq 'update' }).Count -gt 0
                            if($hasUpd){ $d.Status='update'; $d.Detail='Treiber-Update gefunden' }
                            else { if($d.Status -ne 'problem'){ $d.Status='current'; $d.Detail='Kein Update gefunden' } }
                        }
                    }
                    & $fillDevices $false
                    if($o['AiText'] -and $o['AiText'].ToString()){
                        $tb = New-Object Windows.Documents.Paragraph
                        $tb.Inlines.Add([Windows.Documents.Run]::new([string]$o['AiText']))
                        $fc.HerbBox.Document.Blocks.Clear() | Out-Null
                        [void]$fc.HerbBox.Document.Blocks.Add($tb)
                    }
                    & $setStatus "Suche fertig: $($st.Candidates.Count) Kandidaten." '#FF81C784'
                    # Herbert prueft automatisch die Trefferqualitaet
                    if($st.CandView.Count -gt 0 -and $st.Codes['review'] -and $st.StartJob){
                        & $sayLog ">>> Herbert prueft die Treffer auf Richtigkeit ..."
                        $st.Next = @{ Code=$st.Codes['review']; Kind='review'; Vars=@{ cands=$st.CandView }; Status='Herbert prueft Treffer ...' }
                    }
                } elseif($kind -eq 'review'){
                    # Herbert-Ergebnis: Drop-Liste + Empfehlung anwenden
                    $drop = @()
                    if($o['Drop']){ $drop = @($o['Drop'] | ForEach-Object { [int]$_ }) }
                    $best = $(if($o['Best']){[int]$o['Best']}else{0})
                    $note = [string]$(if($o['Note']){$o['Note']}else{''})
                    $kept=@(); $di=0
                    foreach($v in $st.CandView){
                        $di++
                        if($drop -contains $di){ continue }
                        if($di -eq $best){ $v.Label = "[EMPFOHLEN] $($v.Label)"; $v.Checked=$true; $v.Status='update' }
                        $kept += $v
                    }
                    $removed = $st.CandView.Count - $kept.Count
                    $st.CandView = $kept
                    $fc.CandList.Items.Clear()
                    foreach($v in $st.CandView){ [void]$fc.CandList.Items.Add($v) }
                    $fc.BtnInstall.IsEnabled=($st.CandView.Count -gt 0)
                    $fc.BtnHerbert.IsEnabled=($st.CandView.Count -gt 0)
                    if($note){
                        $tb = New-Object Windows.Documents.Paragraph
                        $tb.Inlines.Add([Windows.Documents.Run]::new($note))
                        $fc.HerbBox.Document.Blocks.Clear() | Out-Null
                        [void]$fc.HerbBox.Document.Blocks.Add($tb)
                    }
                    & $sayLog (">>> Herbert-FILTER: $removed Treffer entfernt, Empfehlung markiert.")
                    & $setStatus "Herbert fertig: $removed Fehlertreffer entfernt, $($st.CandView.Count) Kandidaten bleiben - bitte Installieren bestaetigen." '#FF81C784'
                } elseif($kind -eq 'install' -or $kind -eq 'herbert'){
                    if($o['Results']){
                        foreach($rr in @($o['Results'])){
                            & $sayLog $("  [{0}] {1} - {2}" -f $(if($rr.Ok){'OK'}else{'FAIL'}), $rr.Item, $rr.Detail)
                        }
                        $fail = @($o['Results'] | Where-Object { -not $_.Ok }).Count
                        & $setStatus "Installation: $(@($o['Results']).Count - $fail)/$(@($o['Results']).Count) erfolgreich." $(if($fail){'#FFFFB74D'}else{'#FF81C784'})
                    } elseif($o['Result']){
                        $rs = $o['Result']
                        & $sayLog "Herbert installiert: $($o['Pick']) -> $(if($rs.Ok){'OK'}else{'FAIL'}) $(if($rs.Ok){$rs.Detail}else{$rs.Error})"
                        & $setStatus "Herbert: $(if($rs.Ok){'[OK]'}else{'[FAIL]'}) $($o['Pick'])" $(if($rs.Ok){'#FF81C784'}else{'#FFFF5252'})
                    } else {
                        & $setStatus "$(if($o['Ok']){'[OK]'}else{'[FAIL]'}) $($o['Pick'])" '#FF81C784'
                    }
                } else {
                    $d = [string]$(if($o['Detail']){$o['Detail']}else{$o['Error']})
                    & $setStatus "$(if($o['Ok']){'[OK]'}else{'[FAIL]'}) $d" $(if($o['Ok']){'#FF81C784'}else{'#FFFF5252'})
                }
            } else {
                & $setStatus "Fehler: $(if($o){$o['Error']}else{'unbekannt'})" '#FFFF5252'
            }
            & $sayLog ">>> Verarbeitung fertig"
            # naechster Job in der Auto-Kette
            if($st.Next -and $st.StartJob){
                $n=$st.Next; $st.Next=$null
                & $sayLog ">>> Starte naechsten Schritt: $($n.Kind)"
                & $st.StartJob $n.Code $n.Kind $n.Status $n.Vars
            }
            } catch {
                & $sayLog ">>> VERARBEITUNGS-FEHLER: $($_.Exception.Message)"
                & $sayLog ([string]$_.ScriptStackTrace)
                $st.Busy=$false
            }
        }
    }.GetNewClosure())

    $startJob = {
        param($code,$kind,$statusMsg,$vars)
        if($st.Busy){
            # User-Aktion queue'en statt verwerfen (Params wurden beim
            # Aufrufer aufgeloest). Auto-Kette ($st.Next) bleibt Prioritaet.
            if(-not $st.Pending){$st.Pending=New-Object 'System.Collections.Generic.Queue[object]'}
            $st.Pending.Enqueue(@{Code=$code;Kind=$kind;Status=$statusMsg;Vars=$vars})
            & $sayLog ">>> In Warteschlange ($($st.Pending.Count)): $kind"
            & $setStatus "Warteschlange: $($st.Pending.Count) Aktion(en) - '$kind' wartet." '#FFFFB74D'
            return
        }
        & $sayLog ">>> startJob [$kind] modDir=$modDir"
        try {
        $st.Busy=$true;$st.JobKind=$kind
        $st.Queue = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
        $st.Rs=[runspacefactory]::CreateRunspace();$st.Rs.ApartmentState='STA';$st.Rs.ThreadOptions='ReuseThread';$st.Rs.Open()
        & $sayLog '>>> Runspace offen'
        $st.Rs.SessionStateProxy.SetVariable('modDir',$modDir)
        $st.Rs.SessionStateProxy.SetVariable('sdQueue',$st.Queue)
        $st.Rs.SessionStateProxy.SetVariable('logFile',$logFile)
        if($vars){ foreach($k in @($vars.Keys)){ $st.Rs.SessionStateProxy.SetVariable($k,$vars[$k]) } }
        $st.Ps=[powershell]::Create();$st.Ps.Runspace=$st.Rs
        [void]$st.Ps.AddScript($code)
        $st.Async=$st.Ps.BeginInvoke()
        $st.JobStart=Get-Date;$st.JobDone=$false
        try{$poll.Start()}catch{}
        $fc.ProgBar.Visibility='Visible';$fc.ProgBar.IsIndeterminate=$true;$fc.ProgBar.Value=0
        & $sayLog ">>> Job gestartet"
        & $setStatus $statusMsg '#FFB0B0C0'
        } catch {
            & $sayLog ">>> startJob FEHLER: $($_.Exception.Message)"
            & $sayLog ([string]$_.ScriptStackTrace)
            $st.Busy=$false
        }
    }

    $analyseCode = @'
$lf = $logFile
if(-not $lf){ $lf = 'C:\Users\haber\AppData\Local\SysPilot\logs\drvstudio-job.log' }
function _mark($m){ try { Add-Content -Path $lf -Value ("{0} JOB: {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -Encoding UTF8 } catch {} }
_mark 'Job-Skript startet'
Import-Module (Join-Path $modDir 'Common.psm1') -Force -ErrorAction SilentlyContinue
_mark 'Common importiert'
Import-Module (Join-Path $modDir 'Drivers.psm1') -Force -ErrorAction SilentlyContinue
_mark 'Drivers importiert'
Import-Module (Join-Path $modDir 'SmartDrivers.psm1') -Force -ErrorAction SilentlyContinue
_mark 'SmartDrivers importiert'
$q=$sdQueue; $say={param($m) if($q){$q.Enqueue([string]$m)}}
& $say 'Hardware-Analyse: Problemgeraete + Inventar + HW-IDs ...'
$isAdminJob = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if(-not $isAdminJob){& $say 'HINWEIS: keine Adminrechte - Inventar/Problemgeraete koennen leer sein. SysPilot als Administrator starten.'}
try {
  _mark 'Starte Get-SysPilotDriverDevices ...'
  $devs = @(Get-SysPilotDriverDevices -OnProgress $say)
  _mark "Get-SysPilotDriverDevices fertig: $($devs.Count)"
  & $say "Gefunden: $($devs.Count) Geraete"
  if($devs.Count -gt 0){ @{ Ok=$true; Devices=$devs } }
  else { @{ Ok=$false; Error='Keine Geraete zurueckgegeben' } }
} catch {
  _mark "Analyse-Fehler: $($_.Exception.Message)"
  & $say "Analyse-Fehler: $($_.Exception.Message)"
  & $say ([string]$_.ScriptStackTrace)
  @{ Ok=$false; Error=$_.Exception.Message }
}
_mark 'Job-Skript endet'
'@

    $backupCode = @'
Import-Module (Join-Path $modDir 'Common.psm1') -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $modDir 'SmartDrivers.psm1') -Force -ErrorAction SilentlyContinue
$q=$sdQueue; $say={param($m) if($q){$q.Enqueue([string]$m)}}
$results=@()
foreach($d in $devs){
  & $say "Sichere Treiber: $($d.Name) ..."
  $b = Backup-SysPilotDeviceDriver -Device $d
  if($b.Ok){& $say "  [OK] $($b.Dir)"; $results += [pscustomobject]@{Item=$d.Name;Ok=$true;Detail=$b.Dir}}
  else {& $say "  [FAIL] $($b.Error)"; $results += [pscustomobject]@{Item=$d.Name;Ok=$false;Detail=$b.Error}}
}
@{ Ok=$true; Results=$results }
'@

    $searchCode = @'
Import-Module (Join-Path $modDir 'Common.psm1') -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $modDir 'Drivers.psm1') -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $modDir 'SmartDrivers.psm1') -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $modDir 'SmartDownload.psm1') -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $modDir 'AiAssist.psm1') -Force -ErrorAction SilentlyContinue
$q=$sdQueue; $say={param($m) if($q){$q.Enqueue([string]$m)}}
$all=@(); $aiText=''
$di=0; $dtot=@($selDevs).Count
foreach($d in $selDevs){
  $di++
  & $say ("PROGRESS|" + [math]::Round(100*$di/[math]::Max(1,$dtot)))
  & $say "=== Suche: $($d.Name) ==="
  $r = Find-SysPilotDriver -Name $d.Name -Manufacturer $d.Man -HwId $d.HwId -SkipAi -OnProgress $say
  if($r -and $r.Ok){
    if($r.AiText){$aiText += "`n--- $($d.Name) ---`n" + [string]$r.AiText}
    foreach($w in @($r.Wu)){ $all += [pscustomobject]@{Dev=$d.Name;Tag='[wu]';Label="WU: $($w.Title)";Url='';Kind='wu';Raw=$w.Title} }
    foreach($w in @($r.Catalog)){ $disp=$(if($w.Version){$w.Version}elseif($w.Title){$w.Title}else{$w.Source}); $all += [pscustomobject]@{Dev=$d.Name;Tag="[cat:$($w.Source)]";Label="$disp - $($w.Note)";Url=$w.Url;Kind=$(if($w.Guid){'catalog'}else{'link'});Raw=$w} }
    foreach($h in @($r.Web)){ $all += [pscustomobject]@{Dev=$d.Name;Tag="[web:$($h.Engine)]";Label="$($h.Title) ($($h.Note))";Url=$h.Url;Kind='link';Raw=$h} }
    if($r.Official){ $all += [pscustomobject]@{Dev=$d.Name;Tag='[official]';Label="Offizielle Seite: $($r.Official.Manufacturer)";Url=$r.Official.Url;Kind='portal';Raw=$r.Official} }
    foreach($p in @($r.Portals)){ $all += [pscustomobject]@{Dev=$d.Name;Tag="[katalog:$($p.Cat)]";Label="Portal: $($p.Name) ($($p.Cat))";Url=$p.Url;Kind='portal';Raw=$p} }
    foreach($u in @($r.AiUrls)){ $all += [pscustomobject]@{Dev=$d.Name;Tag='[ki]';Label='Herbert-Fundstelle';Url=$u;Kind='link';Raw=$u} }
    if($d.HwId){
      foreach($c in @(Find-SysPilotCatalogDrivers -Query $d.HwId | Select-Object -First 4)){
        $cab = Get-SysPilotCatalogCabUrl -Guid $c.Guid
        if($cab){ $all += [pscustomobject]@{Dev=$d.Name;Tag='[cab]';Label="MS-Catalog: $($c.Title) $($c.Version)";Url=$cab;Kind='cab';Raw=$c} }
      }
    }
  }
}
& $say "Kandidaten gesamt: $($all.Count)"
@{ Ok=$true; Candidates=$all; AiText=$aiText }
'@

    $installCode = @'
Import-Module (Join-Path $modDir 'Common.psm1') -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $modDir 'SmartDrivers.psm1') -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $modDir 'Drivers.psm1') -Force -ErrorAction SilentlyContinue
$q=$sdQueue; $say={param($m) if($q){$q.Enqueue([string]$m)}}
$results=@()
foreach($c in $targets){
  & $say "=== Installiere: $($c.Label) ($($c.Dev)) ==="
  # AUTO-BACKUP des Geraets vor Installation (Restore bei Fehlschlag)
  $bkDir=$null
  if($c.DevObj){
    & $say "  Auto-Backup: $($c.Dev) ..."
    try { $b = Backup-SysPilotDeviceDriver -Device $c.DevObj; if($b.Ok){$bkDir=$b.Dir; & $say "  [OK] Backup: $bkDir"} else {& $say "  [WARN] Backup fehlgeschlagen: $($b.Error)"} } catch { & $say "  [WARN] Backup-Fehler: $($_.Exception.Message)" }
  }
  $r=$null
  if($c.Kind -eq 'wu'){
    $r = Install-SysPilotWUDriverQuiet -Title $c.Raw -OnProgress $say
  } elseif($c.Kind -eq 'catalog' -and $c.Raw.Url){
    $cab = Get-SysPilotCatalogCabUrl -Guid $c.Raw.Guid
    if($cab){ $r = Install-SysPilotDriverAuto -Url $cab -DevName $c.Dev -OnProgress $say }
    else { $r = @{Ok=$false;Error='Kein cab-Link'} }
  } elseif($c.Url -match '\.(exe|msi|zip|7z|cab)(\?|$)'){
    $r = Install-SysPilotDriverAuto -Url $c.Url -DevName $c.Dev -OnProgress $say
  } else {
    & $say "[SKIP] $($c.Label) - kein direkter Download, Link bleibt manuell: $($c.Url)"
    $r = @{Ok=$false;Error='Manuell noetig (kein Direktlink)'}
  }
  # Bei Fehlschlag automatisch Backup zurueckspielen
  if($r -and -not $r.Ok -and $bkDir){
    & $say "  Install fehlgeschlagen - Auto-Restore aus $bkDir ..."
    try { $rr = Restore-SysPilotDriverBackup -BackupDir $bkDir; if($rr.Ok){& $say "  [OK] Auto-Restore: $($rr.Count) INF eingespielt"} else {& $say "  [WARN] Auto-Restore: $($rr.Error)"} } catch { & $say "  [WARN] Auto-Restore-Fehler: $($_.Exception.Message)" }
  }
  $results += [pscustomobject]@{Item=$c.Label;Ok=$r.Ok;Detail=$(if($r.Ok){$r.Detail}else{$r.Error})}
}
@{ Ok=$true; Results=$results }
'@

    $herbertCode = @'
Import-Module (Join-Path $modDir 'Common.psm1') -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $modDir 'SmartDrivers.psm1') -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $modDir 'Drivers.psm1') -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $modDir 'SmartDownload.psm1') -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $modDir 'AiAssist.psm1') -Force -ErrorAction SilentlyContinue
$q=$sdQueue; $say={param($m) if($q){$q.Enqueue([string]$m)}}
$pick = $null
foreach($c in $cands){ if($c.Status -eq 'update' -and $c.Kind -eq 'cab'){$pick=$c;break} }
if(-not $pick){ foreach($c in $cands){ if($c.Kind -eq 'wu'){$pick=$c;break} } }
if(-not $pick){ foreach($c in $cands){ if($c.Url -match '\.(exe|msi|zip|7z|cab)(\?|$)'){$pick=$c;break} } }
if(-not $pick){ foreach($c in $cands){ if($c.Kind -eq 'portal'){$pick=$c;break} } }
if(-not $pick){ @{Ok=$false;Error='Kein installierbarer Kandidat'} }
& $say "Herbert waehlt: $($pick.Label)"
# Auto-Backup vor Herbert-Installation
$bkDir=$null
if($pick.DevObj){
  & $say "Auto-Backup: $($pick.Dev) ..."
  try { $b = Backup-SysPilotDeviceDriver -Device $pick.DevObj; if($b.Ok){$bkDir=$b.Dir; & $say "[OK] Backup: $bkDir"} else {& $say "[WARN] Backup: $($b.Error)"} } catch { & $say "[WARN] Backup-Fehler: $($_.Exception.Message)" }
}
$r=$null
if($pick.Kind -eq 'wu'){ $r = Install-SysPilotWUDriverQuiet -Title $pick.Raw -OnProgress $say }
elseif($pick.Kind -eq 'catalog'){
  $cab = Get-SysPilotCatalogCabUrl -Guid $pick.Raw.Guid
  if($cab){ $r = Install-SysPilotDriverAuto -Url $cab -DevName $pick.Dev -OnProgress $say } else { $r=@{Ok=$false;Error='Kein cab-Link'} }
}
elseif($pick.Url -match '\.(exe|msi|zip|7z|cab)(\?|$)'){ $r = Install-SysPilotDriverAuto -Url $pick.Url -DevName $pick.Dev -OnProgress $say }
else { $r = @{Ok=$true;Detail="Herbert-Link (manuell): $($pick.Url)"} }
if($r -and -not $r.Ok -and $bkDir){
  & $say "Install fehlgeschlagen - Auto-Restore aus $bkDir ..."
  try { $rr = Restore-SysPilotDriverBackup -BackupDir $bkDir; if($rr.Ok){& $say "[OK] Auto-Restore: $($rr.Count) INF"} else {& $say "[WARN] Auto-Restore: $($rr.Error)"} } catch { & $say "[WARN] Auto-Restore-Fehler: $($_.Exception.Message)" }
}
@{ Ok=$true; Pick=$pick.Label; Result=$r }
'@

    $reviewCode = @'
Import-Module (Join-Path $modDir 'Common.psm1') -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $modDir 'SmartDrivers.psm1') -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $modDir 'AiAssist.psm1') -Force -ErrorAction SilentlyContinue
$q=$sdQueue; $say={param($m) if($q){$q.Enqueue([string]$m)}}
& $say "Herbert prueft $(@($cands).Count) Treiber-Treffer auf Richtigkeit ..."
$lines=@(); $i=0
foreach($c in $cands){ $i++; $lines += "$i. [$($c.Tag)] $($c.Label) ($($c.Kind)) -> $($c.Url)" }
$devNames = (@($cands | ForEach-Object { $_.Dev } | Sort-Object -Unique) -join ', ')
$prompt = @"
Du bist Herbert, der Treiber-Pruefer von SysPilot.
Geraete: $devNames

Diese Treiber-Kandidaten wurden automatisch gefunden:
$($lines -join "`n")

Aufgabe: Pruefe jeden Treffer. Entferne alle, die clearly falsch sind
(falscher Hersteller, falsches Geraet, tote/irrelevante Links, Dubletten).
Antworte AUSSCHLIESSLICH in diesem Format, eine Zeile pro Eintrag:
DROP|<nummer>   <- Treffer ist falsch/irrelevant
BEST|<nummer>   <- der beste installierbare Treffer (nur einer)
NOTE|<text>     <- 1-3 Saetze deutsche Erklaerung (warum dieser, WHQL-Hinweis)
Wenn nichts falsch ist, keine DROP-Zeilen. Wenn unklar, lieber KEEPEN.
"@
$ai = Invoke-SysPilotAiChat -Prompt $prompt -TimeoutSec 90
$drop=@(); $best=0; $note=''
if($ai.Ok){
  $note = [string]$ai.Text
  foreach($ln in ($ai.Text -split "`n")){
    $ln = $ln.Trim()
    if($ln -match '^(?i)DROP\|\s*(\d+)'){ $drop += [int]$Matches[1] }
    elseif($ln -match '^(?i)BEST\|\s*(\d+)'){ $best = [int]$Matches[1] }
  }
  # NOTE-Zeilen aus dem Freitext extrahieren
  $noteLines = @($ai.Text -split "`n" | Where-Object { $_ -notmatch '^(?i)(DROP|BEST)\|' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  $note = ($noteLines -join ' ')
  if(-not $note){ $note = [string]$ai.Text }
} else { $note = "Herbert nicht erreichbar: $($ai.Error)" }
@{ Ok=$true; Drop=$drop; Best=$best; Note=$note }
'@

    # ---------- Click-Handler ----------
    $selDevices = { @($fc.DevList.SelectedItems | ForEach-Object { $_.Dev }) }
    $selChecked = { @($fc.DevList.Items | Where-Object { $_.Checked } | ForEach-Object { $_.Dev }) }
    $selCands = { @($fc.CandList.SelectedItems) }

    $fc.BtnAnalyse.Add_Click({ & $sayLog '>>> KLICK: Neu scannen'; & $startJob $st.Codes['analyse'] 'analyse' 'Hardware-Analyse laeuft ...' })

    $fc.BtnSearch.Add_Click({
        & $sayLog '>>> KLICK: Suchen'
        $sel = & $selChecked
        if($sel.Count -eq 0){ $sel = & $selDevices }
        if($sel.Count -eq 0){& $setStatus 'Bitte Geraete auswaehlen oder abhaken.' '#FFFFB74D';return}
        if($sel.Count -gt 8){& $setStatus 'Maximal 8 Geraete gleichzeitig (sonst zu lange).' '#FFFFB74D';return}
        & $startJob $st.Codes['search'] 'search' "Suche laeuft fuer $($sel.Count) Geraet(e) ..." @{ selDevs=$sel }
    })

    $fc.BtnInstall.Add_Click({
        & $sayLog '>>> KLICK: Installieren'
        $sel = & $selCands
        if($sel.Count -eq 0){& $setStatus 'Bitte Kandidaten markieren (Strg+Klick).' '#FFFFB74D';return}
        $r=[System.Windows.MessageBox]::Show("$($sel.Count) Treiber-Kandidat(en) installieren?`n`nAuto-Backup + Auto-Restore bei Fehlschlag ist aktiv.`n`n$(($sel | ForEach-Object {$_.Label}) -join "`n")",'SmartDriver Studio','YesNo','Question')
        if($r -ne 'Yes'){return}
        & $startJob $st.Codes['install'] 'install' "Installiere $($sel.Count) Kandidat(en) ..." @{ targets=$sel }
    })

    $fc.BtnHerbert.Add_Click({
        & $sayLog '>>> KLICK: Herbert Auto'
        $sel = & $selCands
        if($sel.Count -eq 0){& $setStatus 'Bitte Kandidaten markieren.' '#FFFFB74D';return}
        $r=[System.Windows.MessageBox]::Show("Herbert waehlt automatisch den besten Kandidaten und installiert ihn.`n`nAuto-Backup + Auto-Restore ist aktiv.`n`nFortfahren?,",'Herbert Auto-Install','YesNo','Question')
        if($r -ne 'Yes'){return}
        & $startJob $st.Codes['herbert'] 'herbert' 'Herbert waehlt und installiert ...' @{ cands=$sel }
    })

    $fc.BtnAssistent.Add_Click({
        & $sayLog '>>> KLICK: Assistent'
        try {
            Import-Module (Join-Path $modDir 'AiAssist.psm1') -Force -ErrorAction SilentlyContinue
            $devN = @($fc.DevList.Items | Where-Object { $_.Checked } | Select-Object -First 3 | ForEach-Object { $_.Dev.Name }) -join ', '
            $ctx = "SmartDriver Studio" + $(if($devN){" - Geraete: $devN"}else{''})
            $sg = @('Treiber-Status zusammenfassen','Welchen Kandidaten soll ich installieren?','System-Status pruefen','Was kann ich hier tun?')
            Show-SysPilotHerbertAssistant -Owner $win -Context $ctx -Suggestions $sg
        } catch { & $setStatus "Assistent: $($_.Exception.Message)" '#FFFF5252' }
    })

    $fc.BtnBackup.Add_Click({
        & $sayLog '>>> KLICK: Sichern'
        $sel = & $selChecked
        if($sel.Count -eq 0){ $sel = & $selDevices }
        if($sel.Count -eq 0){& $setStatus 'Bitte Geraete auswaehlen oder abhaken.' '#FFFFB74D';return}
        & $startJob $st.Codes['backup'] 'backup' "Sichere Treiber ($($sel.Count) Geraete) ..." @{ devs=$sel }
    })

    $fc.BtnRestore.Add_Click({
        $root = Join-Path $env:LOCALAPPDATA 'SysPilot\DriverBackup'
        if(-not (Test-Path $root)){& $setStatus 'Kein Backup-Ordner vorhanden.' '#FFFFB74D';return}
        $dirs = @(Get-ChildItem $root -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 8)
        $items = @(); foreach($d in $dirs){ $items += @{Label="$($d.Name) ($($d.LastWriteTime.ToString('dd.MM HH:mm')))";Color='White';Tag=$d.FullName} }
        $items += @{Label='Abbrechen';Color='DarkGray';Tag=$null}
        $pick = Show-SysPilotArrowMenu -Items $items -Title 'Treiber-Backup waehlen' -Footer 'Enter = einspielen, Esc = abbruch'
        if(-not $pick){return}
        & $sayLog "Spiel Backup ein: $pick ..."
        $r = Restore-SysPilotDriverBackup -BackupDir $pick
        & $sayLog $(if($r.Ok){"[OK] $($r.Count) INF-Dateien eingespielt."}else{"[FAIL] $($r.Error)"})
        & $setStatus $(if($r.Ok){'Backup eingespielt - Geraete ggf. neu starten noetig.'}else{$r.Error}) $(if($r.Ok){'#FF81C784'}else{'#FFFF5252'})
    })

    $fc.BtnCatalog.Add_Click({
        $w2 = New-Object Windows.Window
        $w2.Title='SmartDriver - Treiber-Webkatalog';$w2.Width=520;$w2.Height=560
        $w2.WindowStartupLocation='CenterOwner';if($win.Owner){$w2.Owner=$win}
        $w2.Background=[Windows.Media.BrushConverter]::new().ConvertFrom('#FF1E1E2E')
        $sp2=New-Object Windows.Controls.StackPanel;$sp2.Margin='12'
        $h2=New-Object Windows.Controls.TextBlock;$h2.Text='Treiber-Quellen-Katalog';$h2.FontSize=16;$h2.FontWeight='Bold';$h2.Foreground=[Windows.Media.BrushConverter]::new().ConvertFrom('#FF4FC3F7');$h2.Margin='0,0,0,8'
        [void]$sp2.Children.Add($h2)
        $cats=@{};foreach($e in (Get-SysPilotDriverWebCatalog)){$cats[$e.Cat]=@()}
        foreach($e in (Get-SysPilotDriverWebCatalog)){$cats[$e.Cat]+=$e}
        foreach($ck in ($cats.Keys|Sort-Object)){
            $ct=New-Object Windows.Controls.TextBlock;$ct.Text=$ck;$ct.FontWeight='Bold';$ct.Foreground=[Windows.Media.BrushConverter]::new().ConvertFrom('#FF9CCC65');$ct.Margin='0,8,0,2'
            [void]$sp2.Children.Add($ct)
            foreach($e in $cats[$ck]){
                $row=New-Object Windows.Controls.StackPanel;$row.Orientation='Horizontal'
                $nb=New-Object Windows.Controls.Button;$nb.Content=$e.Name;$nb.Padding='8,2';$nb.Margin='0,0,8,0';$nb.Tag=$e.Url
                $nb.Add_Click({param($s,$ev) Start-Process ([string]$s.Tag)})
                [void]$row.Children.Add($nb)
                $tag=New-Object Windows.Controls.TextBlock;$tag.Text=$(if($e.Auto){'[auto]'}else{'[manuell]'})
                $tag.Foreground=[Windows.Media.BrushConverter]::new().ConvertFrom('#FF6E6E85');$tag.FontSize='10';$tag.VerticalAlignment='Center'
                [void]$row.Children.Add($tag)
                [void]$sp2.Children.Add($row)
            }
        }
        $w2.Content=$sp2;[void]$w2.ShowDialog()
    })
    $fc.BtnSingle.Add_Click({
        try {
            Import-Module (Join-Path $modDir 'SmartDrivers.psm1') -Force -ErrorAction SilentlyContinue
            Invoke-SysPilotSmartDriverSearch
        } catch { & $setStatus "Einzel-Suche: $($_.Exception.Message)" '#FFFF5252' }
    })

    # Auswahl-Aenderungen aktivieren Buttons
    $fc.DevList.Add_SelectionChanged({
        $n = @($fc.DevList.SelectedItems).Count
        $fc.BtnSearch.IsEnabled = ($n -gt 0 -or @($fc.DevList.Items | Where-Object { $_.Checked }).Count -gt 0)
    })
    $fc.CandList.Add_SelectionChanged({
        $n = @($fc.CandList.SelectedItems).Count
        $fc.BtnInstall.IsEnabled = ($n -gt 0)
        $fc.BtnHerbert.IsEnabled = ($n -gt 0)
    })
    # Haken-Aenderungen (CheckBox) ebenfalls beruecksichtigen
    $fc.DevList.Add_MouseLeftButtonUp({
        Start-Sleep -Milliseconds 120
        $fc.BtnSearch.IsEnabled = (@($fc.DevList.Items | Where-Object { $_.Checked }).Count -gt 0)
    })

    $fc.BtnClose.Add_Click({& $stopJob;$win.Close()})
    $win.Add_Closing({& $drainQ;$poll.Stop();& $stopJob})

    # Codes + StartJob fuer die Auto-Kette bereitstellen
    $st.Codes = @{ analyse=$analyseCode; backup=$backupCode; search=$searchCode; install=$installCode; herbert=$herbertCode; review=$reviewCode }
    $st.StartJob = $startJob

    # Vollautomatisch: Analyse startet beim Oeffnen
    $win.Add_Loaded({
        & $sayLog '>>> Fenster geoeffnet - starte automatische Hardware-Analyse'
        & $startJob $st.Codes['analyse'] 'analyse' 'Hardware-Analyse laeuft ...'
    })

    Set-SysPilotWindowAutoSize -Win $win -MinWidth 1000 -MinHeight 640
    $poll.Start()
    [void]$win.ShowDialog()
    return $true
}

Export-ModuleMember -Function Find-SysPilotDriver, Show-SysPilotDriverFinder,
    Find-SysPilotSmartDrvOfficial, Get-SysPilotSmartDrvScore, Invoke-SysPilotSmartDriverSearch,
    Get-SysPilotDriverWebCatalog, Get-SysPilotDriverDevices, Invoke-SysPilotElevated,
    Backup-SysPilotDeviceDriver, Restore-SysPilotDriverBackup,
    Get-SysPilotCatalogCabUrl, Install-SysPilotWUDriverQuiet,
    Install-SysPilotDriverAuto, Show-SysPilotDriverStudioWindow
