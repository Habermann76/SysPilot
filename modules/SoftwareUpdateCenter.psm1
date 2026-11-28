# SysPilot - Software Update Center (0.9.4.9)
# Einheitliches Update-/Download-Center: winget + Chocolatey + kuratierter
# Programm-Katalog (GitHub-Releases, offizielle Seiten, MajorGeeks).
# Nach Analyse von IObit Software Updater, UpdateHub (Nexova) und
# Patch My PC Home Updater: winget-first (wie UpdateHub), kuratierte
# App->Quelle-Tabelle (wie Patch My PC), keine IObit-Telemetrie.
#Requires -Version 5.1

$script:SysPilotRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$script:_ghHeaders = @{ 'User-Agent' = 'SysPilot-UpdateCenter'; 'Accept' = 'application/vnd.github+json' }
$script:_installedMap = $null

# =====================================================================
# QUELLEN: winget / Chocolatey
# =====================================================================

function Get-SysPilotWingetExe {
    $w = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($w) { return $w.Source }
    $c = "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe"
    if (Test-Path $c) { return $c }
    return $null
}

function Get-SysPilotChocoExe {
    $c = Get-Command choco.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in @("$env:ProgramData\chocolatey\bin\choco.exe",
                     "$env:LOCALAPPDATA\UniGetUI\Chocolatey\bin\choco.exe")) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function ConvertTo-SysPilotVerObj {
    param([string]$Text)
    $m = [regex]::Match([string]$Text, '\d+(\.\d+){1,3}')
    if (-not $m.Success) { return $null }
    $parts = @($m.Value.Split('.'))
    while ($parts.Count -lt 3) { $parts += '0' }
    try { return [version]($parts -join '.') } catch { return $null }
}

function Invoke-SysPilotWingetRaw {
    <# winget ausfuehren mit echtem Timeout, stdout+stderr, ExitCode.
       Bei Fehler enthaelt Error die letzten Output-Zeilen (lokalisiert). #>
    param([Parameter(Mandatory)][string[]]$ArgList, [int]$TimeoutSec = 300)
    $exe = Get-SysPilotWingetExe
    if (-not $exe) { return @{ Ok = $false; Text = ''; Error = 'winget nicht gefunden'; ExitCode = $null; Timeout = $false } }
    $argList = @($ArgList)
    if ($argList.Count -gt 0 -and $argList[0] -in @('install','upgrade','download','import','repair')) {
        $argList += @('--accept-source-agreements','--disable-interactivity')
    }
    # Monitored: Spinner + Laufzeit + letzte Output-Zeile, Haenger-
    # erkennung mit Abbruch (Q) - deckt Download/Install-Phasen ab.
    $verb = if ($argList.Count -gt 0) { $argList[0] } else { 'winget' }
    $r = Invoke-SysPilotMonitoredProcess -FilePath $exe -ArgList $argList `
         -Label "winget $verb" -TimeoutSec $TimeoutSec -StallWarnSec 150
    $out = [string]$r.Output
    $tail = (($out -split "`r?`n") | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 8) -join ' | '
    $err = if ($r.Ok) { '' } else { $(if ($r.Error) { $r.Error } else { $tail }) }
    if ($r.Timeout) { Write-SysPilotLog "winget Timeout nach ${TimeoutSec}s: $($argList -join ' ')" }
    if ($r.Aborted) { Write-SysPilotLog "winget abgebrochen: $($argList -join ' ')" }
    return @{ Ok = $r.Ok; Text = $out; Error = $err; ExitCode = $r.ExitCode; Timeout = $r.Timeout; Aborted = $r.Aborted }
}

function Get-SysPilotUpdateFailKind {
    <# Klassifiziert einen winget-Fehler: 'not-applicable' (exit 43/andere
       Quelle oder Architektur), 'admin' (Installer braucht Erhoehung,
       z.B. MSI 1603), 'timeout', sonst 'other'. #>
    param([string]$Error = '', $ExitCode)
    $e = "$Error".ToLower()
    if ("$ExitCode" -eq '43' -or $e -match 'kein anwendbares|no applicable|exit ?code:?\s*43') { return 'not-applicable' }
    if ($e -match 'kann nicht mit winget|cannot be upgraded|verwenden sie die vom herausgeber|use the upgrade method|publisher.*method|nicht mit winget') { return 'publisher' }
    if ($e -match '1603|1602|1618|administrator|adminrechte|elevat|hoeheren rechte|higher privileges|0x8a15002b') { return 'admin' }
    if ($e -match 'timeout') { return 'timeout' }
    return 'other'
}

function Invoke-SysPilotWingetUpdate {
    <# winget upgrade mit automatischem elevated-Retry bei Admin-Fehlern.
       Gibt Ok/Error/Kind/Elevated back. #>
    param(
        [Parameter(Mandatory)][string]$Id,
        [switch]$Silent,
        [int]$TimeoutSec = 900,
        [switch]$AllowElevated
    )
    $args = @('upgrade','--id',$Id,'--exact','--accept-package-agreements','--accept-source-agreements','--disable-interactivity')
    if ($Silent) { $args += '--silent' }
    $r = Invoke-SysPilotWingetRaw -ArgList $args -TimeoutSec $TimeoutSec
    if ($r.Ok) { return @{ Ok = $true; Error = ''; Kind = ''; Elevated = $false; Text = $r.Text } }
    $kind = Get-SysPilotUpdateFailKind -Error $r.Error -ExitCode $r.ExitCode
    # Einmal elevated wiederholen, wenn der Installer Admin braucht
    if ($kind -eq 'admin' -and $AllowElevated) {
        Write-SysPilotLog "winget ${Id}: Admin-Fehler ($($r.Error)) - elevated retry"
        # --force: Installer-Shutdown-Checks ueberschreiben (z.B. MSI 1603
        # durch laufende App) - ein letzter automatischer Versuch.
        $ea = @('upgrade','--id',$Id,'--exact','--accept-package-agreements','--accept-source-agreements','--force')
        if ($Silent) { $ea += '--silent' }
        $er = Invoke-SysPilotWingetElevated -ArgList $ea
        if ($er.Ok) { return @{ Ok = $true; Error = ''; Kind = ''; Elevated = $true; Text = '' } }
        return @{ Ok = $false; Error = "elevated: $($er.Error)"; Kind = 'admin'; Elevated = $true; Text = $r.Text }
    }
    return @{ Ok = $false; Error = $r.Error; Kind = $kind; Elevated = $false; Text = $r.Text }
}

# =====================================================================
# CROSS-MANAGER-FALLBACK
# winget kann viele Pakete nicht aktualisieren (andere Quelle/Architektur,
# 'publisher'-Methoden). Liegt das Paket auch in Chocolatey oder Scoop,
# kann der jeweilige Manager oft trotzdem updaten -> vollautomatisch
# durchprobieren, aber NUR wenn der Manager das Paket wirklich installiert
# hat (exakter Namensmatch, keine Ruffzanerei).
# =====================================================================

function Get-SysPilotScoopExeLocal {
    $c = Get-Command scoop -ErrorAction SilentlyContinue
    if ($c) {
        if ($c.Source -match '\.ps1$') {
            $cmd = [IO.Path]::ChangeExtension($c.Source, '.cmd')
            if (Test-Path $cmd) { return $cmd }
        }
        return $c.Source
    }
    foreach ($p in @("$env:USERPROFILE\scoop\shims\scoop.cmd",
                     "$env:USERPROFILE\scoop\shims\scoop.ps1")) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Get-SysPilotChocoInstalledNames {
    <# Alle lokal per Chocolatey installierten Paketnamen (lowercase).
       10-Minuten-Cache: 'choco list' ist langsam und wird pro
       AutoUpdate-Lauf nur einmal noetig. #>
    if ($script:_chocoNamesCache -and $script:_chocoNamesCache.At -gt (Get-Date).AddMinutes(-10)) {
        return $script:_chocoNamesCache.Set
    }
    $exe = Get-SysPilotChocoExe
    if (-not $exe) { return @{} }
    $out = & $exe list --local-only --limit-output 2>&1 | Out-String
    $set = @{}
    foreach ($line in ($out -split "`r?`n")) {
        $name = ($line -split '\|')[0].Trim().ToLower()
        if ($name) { $set[$name] = $true }
    }
    $script:_chocoNamesCache = @{ Set = $set; At = Get-Date }
    return $set
}

function Get-SysPilotScoopInstalledNames {
    <# Alle lokal per Scoop installierten App-Namen (lowercase).
       10-Minuten-Cache wie choco. #>
    if ($script:_scoopNamesCache -and $script:_scoopNamesCache.At -gt (Get-Date).AddMinutes(-10)) {
        return $script:_scoopNamesCache.Set
    }
    $exe = Get-SysPilotScoopExeLocal
    if (-not $exe) { return @{} }
    $out = & $exe list 2>&1 | Out-String
    $set = @{}
    foreach ($line in ($out -split "`r?`n")) {
        # Spalten: Name Version Source ... -> erstes Token
        $name = ($line.Trim() -split '\s+')[0].ToLower()
        if ($name -and $name -notin @('name','----','installed')) { $set[$name] = $true }
    }
    $script:_scoopNamesCache = @{ Set = $set; At = Get-Date }
    return $set
}

function Get-SysPilotAltManagerCandidates {
    <# Kandidaten-Namen fuer choco/scoop: volle Id, Id ohne Publisher,
       letzter Punkt-Abschnitt - jeweils original + lowercase. #>
    param([Parameter(Mandatory)][string]$Id)
    $cands = New-Object System.Collections.Generic.List[string]
    $parts = $Id -split '\.'
    $noPub = if ($parts.Count -gt 1) { ($parts[1..($parts.Count-1)] -join '.') } else { $Id }
    foreach ($c in @($Id, $noPub, ($parts[-1]), ($parts[-1].ToLower()))) {
        if ($c -and -not $cands.Contains($c)) { $cands.Add($c) }
    }
    # Nur sinnvolle Kandidaten (>=3 Zeichen, kein reiner Publisher-Rest)
    return @($cands | Where-Object { $_.Length -ge 3 } | Select-Object -Unique)
}

function Invoke-SysPilotChocoUpgradeAuto {
    <# choco upgrade mit Output-Parsing: choco exit 0 heisst NICHT
       Erfolg - 'Chocolatey upgraded 0/N packages' + 'war not found
       with the source(s)' ist ein Fehlschlag. 'nicht outdated' zaehlt
       als Erfolg (Ziel: aktuell). #>
    param([Parameter(Mandatory)][string]$Pkg, [switch]$Quiet)
    $exe = Get-SysPilotChocoExe
    if (-not $exe) { return @{ Ok=$false; Error='choco nicht gefunden' } }
    $args = @('upgrade',$Pkg,'-y','--no-progress','--limit-output')
    $out = ''
    if (Test-SysPilotAdmin) {
        $r = Invoke-SysPilotMonitoredProcess -FilePath $exe -ArgList $args -Label "choco upgrade $Pkg" -TimeoutSec 600
        $out = [string]$r.Output; $code = $r.ExitCode
    } else {
        Write-Host "     choco braucht Admin - UAC folgt, danach laeuft die Installation im eigenen Fenster ..." -ForegroundColor DarkGray
        $p = Start-Process $exe -ArgumentList $args -Verb RunAs -PassThru
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $spin = '|/-\'; $si = 0
        while (-not $p.HasExited) {
            Start-Sleep -Milliseconds 700
            $el = [int]$sw.Elapsed.TotalSeconds
            Write-Host ("`r     warte auf choco-Fenster... {0,4}s {1}   " -f $el, $spin[$si++ % 4]) -NoNewline
            if ($el -gt 900) { break }
        }
        Write-Host ''
        if (-not $p.HasExited) {
            try { & "$env:SystemRoot\System32\taskkill.exe" /PID $p.Id /T /F 2>&1 | Out-Null } catch {}
            return @{ Ok=$false; Error='choco: Timeout nach 900s (UAC/Installer)' }
        }
        $code = $p.ExitCode
    }
    $low = "$out".ToLower()
    $upToDate = ($low -match 'is not outdated|not newer|already.*latest|keine neuere|up to date')
    if ($upToDate) { return @{ Ok=$true; Error=''; Via='choco'; Note='bereits aktuell' } }
    $m = [regex]::Match("$out", 'Chocolatey upgraded (\d+)/(\d+)')
    if ($m.Success) {
        $done = [int]$m.Groups[1].Value; $total = [int]$m.Groups[2].Value
        if ($done -gt 0) { return @{ Ok=$true; Error=''; Via='choco'; Note=''; Out=$out } }
        if ($low -match 'was not found with the source|not found with the source|could not find') {
            return @{ Ok=$false; Error="choco: Paket nicht in konfigurierter Quelle ($Pkg)"; Via='choco' }
        }
        $warn = (($out -split "`r?`n") | Where-Object { $_ -match 'warn|error|nicht|not found' } | Select-Object -First 2) -join ' | '
        return @{ Ok=$false; Error="choco: 0/$total aktualisiert $(if($warn){"- $warn"})"; Via='choco' }
    }
    if ($code -eq 0 -and $low -notmatch 'was not found|upgraded 0/') {
        return @{ Ok=$true; Error=''; Via='choco'; Note=''; Out=$out }
    }
    $tail = (($out -split "`r?`n") | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 3) -join ' | '
    return @{ Ok=$false; Error="choco exit $code - $tail"; Via='choco' }
}

function Invoke-SysPilotScoopUpdateAuto {
    <# scoop update; 'up to date' zaehlt als Erfolg. #>
    param([Parameter(Mandatory)][string]$App, [switch]$Quiet)
    $exe = Get-SysPilotScoopExeLocal
    if (-not $exe) { return @{ Ok=$false; Error='scoop nicht gefunden' } }
    $seExe = $exe -replace '\.ps1$','.cmd'
    if (-not (Test-Path $seExe)) { $seExe = $exe }
    $sr = Invoke-SysPilotMonitoredProcess -FilePath $seExe -ArgList @('update',$App) -Label "scoop update $App" -TimeoutSec 600 -Quiet:$Quiet.IsPresent
    $out = [string]$sr.Output
    $code = $sr.ExitCode
    $low = $out.ToLower()
    $upToDate = ($low -match 'up to date|up-to-date|already.*latest|is up.to.date')
    $updated  = ($low -match 'updated|scoop updated')
    if ($code -eq 0 -and ($updated -or $upToDate)) {
        return @{ Ok=$true; Error=''; Via='scoop'; Note=$(if($upToDate){'bereits aktuell'}else{''}) }
    }
    $tail = (($out -split "`r?`n") | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 3) -join ' | '
    return @{ Ok=$false; Error="scoop exit $code - $tail"; Via='scoop' }
}

function Invoke-SysPilotAltManagerUpgrade {
    <# Versucht ein per winget fehlgeschlagenes Paket ueber die Manager,
       die es tatsaechlich installiert haben (choco -> scoop).
       Gibt $null zurueck, wenn kein Manager das Paket kennt. #>
    param([Parameter(Mandatory)]$Row, [switch]$Quiet)
    $id = [string]$Row.Id
    $cands = Get-SysPilotAltManagerCandidates -Id $id
    if (-not $cands) { return $null }
    $chocoSet = Get-SysPilotChocoInstalledNames
    $scoopSet = Get-SysPilotScoopInstalledNames
    $tried = @()
    # 1) Chocolatey
    foreach ($c in $cands) {
        if ($chocoSet.ContainsKey($c.ToLower())) {
            if (-not $Quiet) { Write-Host "     Fallback: Chocolatey '$c' ..." -ForegroundColor DarkGray }
            $r = Invoke-SysPilotChocoUpgradeAuto -Pkg $c -Quiet:$Quiet
            $tried += "choco:$c -> $(if($r.Ok){'OK'}else{$r.Error})"
            if ($r.Ok) { return @{ Ok=$true; Error=''; Via="choco:$c"; Note=$r.Note; Tried=($tried -join '; ') } }
            break   # Paket gefunden, Upgrade scheiterte -> nicht endlos weitere Manager mit falschen Namen fuettern
        }
    }
    # 2) Scoop
    foreach ($c in $cands) {
        if ($scoopSet.ContainsKey($c.ToLower())) {
            if (-not $Quiet) { Write-Host "     Fallback: Scoop '$c' ..." -ForegroundColor DarkGray }
            $r = Invoke-SysPilotScoopUpdateAuto -App $c -Quiet:$Quiet
            $tried += "scoop:$c -> $(if($r.Ok){'OK'}else{$r.Error})"
            if ($r.Ok) { return @{ Ok=$true; Error=''; Via="scoop:$c"; Note=$r.Note; Tried=($tried -join '; ') } }
            break
        }
    }
    if ($tried.Count -eq 0) { return $null }
    return @{ Ok=$false; Error=($tried -join '; '); Via='alt-managers'; Tried=($tried -join '; ') }
}

function Get-SysPilotSearchTerms {
    <# Suchbegriffe aus App-Namen/winget-Id: normalisiert, camelCase
       gesplittet, Versionen entfernt, Publisher-Praefix weg. #>
    param([Parameter(Mandatory)][string]$Query)
    $terms = New-Object System.Collections.Generic.List[string]
    $add = { param($t) $t=$t.Trim().ToLower(); if($t.Length -ge 3 -and -not $terms.Contains($t)){$terms.Add($t)} }
    # Aus winget-Id den App-Teil (nach letztem Punkt) + camelCase-Words
    $idPart = ($Query -split '\.')[-1]
    $words = [regex]::Matches($idPart,'[A-Z]?[a-z0-9]+|[A-Z]+(?![a-z])') | ForEach-Object { $_.Value }
    $spaced = ($words -join ' ').Trim()
    $noPub = if ($Query -match '\.') { $idPart } else { $Query }
    foreach ($t in @($noPub, $idPart, $spaced, (($words | Select-Object -First 2) -join ' '))) {
        # Versionen/Zahlen am Ende entfernen
        $t = [regex]::Replace("$t",'\s*\d+(\.\d+)*.*$','').Trim()
        $t = [regex]::Replace($t,'[^\w\s.-]',' ').Trim()
        if ($t) { & $add $t }
    }
    return @($terms | Select-Object -First 4)
}

function Find-SysPilotChocoRemoteCandidates {
    <# choco search -> Kandidaten (id|version), gerankt nach Aehnlichkeit. #>
    param([Parameter(Mandatory)][string]$Query)
    $exe = Get-SysPilotChocoExe
    if (-not $exe) { return @() }
    $found = @{}
    $terms = @(Get-SysPilotSearchTerms -Query $Query)
    $ti = 0
    foreach ($t in $terms) {
        $ti++
        Write-Host "     choco search '$t' ($ti/$($terms.Count)) - Remote-Katalog, kann dauern ..." -ForegroundColor DarkGray
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $out = & $exe search $t --limit-output 2>&1 | Out-String
        Write-Host ("       -> {0:N1}s" -f $sw.Elapsed.TotalSeconds) -ForegroundColor DarkGray
        foreach ($line in ($out -split "`r?`n")) {
            $f = $line -split '\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
            if ($f.Count -ge 1 -and $f[0] -match '^[a-zA-Z0-9][\w.\-]*$' -and $f[0] -notmatch '^(chocolatey|package)') {
                $found[$f[0].ToLower()] = $f[0]
            }
        }
    }
    # Ranken: exakte Uebereinstimmung > enthaelt > Token-Overlap
    $norm = { param($s) ([regex]::Replace($s.ToLower(),'[^a-z0-9]','')) }
    $q = & $norm $Query
    $scored = foreach ($id in $found.Values) {
        $n = & $norm $id
        $score = 0
        if ($n -eq $q) { $score = 100 }
        elseif ($n.Contains($q) -or $q.Contains($n)) { $score = 60 }
        else {
            $qt = ($Query.ToLower() -split '[^a-z0-9]+' | Where-Object { $_.Length -ge 3 })
            $hit = @($qt | Where-Object { $n.Contains($_) }).Count
            if ($hit -gt 0) { $score = 20 + $hit * 10 }
        }
        if ($score -gt 0) { [pscustomobject]@{ Id=$id; Score=$score } }
    }
    return @($scored | Sort-Object Score -Descending | Select-Object -First 6 | ForEach-Object { $_.Id })
}

function Find-SysPilotScoopRemoteCandidates {
    <# scoop search -> Kandidaten (App-Namen), grob geparst. #>
    param([Parameter(Mandatory)][string]$Query)
    $exe = Get-SysPilotScoopExeLocal
    if (-not $exe) { return @() }
    $found = @{}
    $terms = @(Get-SysPilotSearchTerms -Query $Query)
    $ti = 0
    foreach ($t in $terms) {
        $ti++
        Write-Host "     scoop search '$t' ($ti/$($terms.Count)) - Remote-Katalog, kann dauern ..." -ForegroundColor DarkGray
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $out = & $exe search $t 2>&1 | Out-String
        Write-Host ("       -> {0:N1}s" -f $sw.Elapsed.TotalSeconds) -ForegroundColor DarkGray
        foreach ($line in ($out -split "`r?`n")) {
            $line = $line.Trim()
            if ($line -match '^(WARN|Error|No matches)') { continue }
            # Formate: "name version", "bucket:name version", "* name ..."
            $m = [regex]::Match($line,'^\*?\s*([a-zA-Z0-9][\w\-]*)(?::([\w\-]+))?\s+[\d]')
            if ($m.Success) { $found[$m.Groups[1].Value.ToLower()] = $m.Groups[1].Value }
        }
    }
    return @($found.Values | Select-Object -First 6)
}

function Invoke-SysPilotChocoInstallPkg {
    <# choco install mit Pruefung (exit 0 + 'not found'-Warnings). #>
    param([Parameter(Mandatory)][string]$Pkg)
    $exe = Get-SysPilotChocoExe
    if (-not $exe) { return @{ Ok=$false; Error='choco nicht gefunden' } }
    $args = @('install',$Pkg,'-y','--no-progress','--limit-output')
    if (Test-SysPilotAdmin) {
        $r = Invoke-SysPilotMonitoredProcess -FilePath $exe -ArgList $args -Label "choco install $Pkg" -TimeoutSec 600
        $out = [string]$r.Output; $code = $r.ExitCode
    } else {
        Write-Host "     choco braucht Admin - UAC folgt, danach laeuft die Installation im eigenen Fenster ..." -ForegroundColor DarkGray
        $p = Start-Process $exe -ArgumentList $args -Verb RunAs -PassThru
        $sw = [Diagnostics.Stopwatch]::StartNew(); $spin = '|/-\'; $si = 0
        while (-not $p.HasExited) {
            Start-Sleep -Milliseconds 700
            $el = [int]$sw.Elapsed.TotalSeconds
            Write-Host ("`r     warte auf choco-Fenster... {0,4}s {1}   " -f $el, $spin[$si++ % 4]) -NoNewline
            if ($el -gt 900) { break }
        }
        Write-Host ''
        $code = $p.ExitCode; $out=''
    }
    $low = "$out".ToLower()
    if ($code -eq 0 -and $low -notmatch 'was not found|could not find|0/\d+ packages') {
        return @{ Ok=$true; Error='' }
    }
    $warn = (($out -split "`r?`n") | Where-Object { $_ -match 'warn|error|nicht|not found|failed' } | Select-Object -First 2) -join ' | '
    return @{ Ok=$false; Error="choco exit $code $(if($warn){"- $warn"})" }
}

function Show-SysPilotAltManagerInstallMenu {
    <# Sucht das Paket in Chocolatey UND Scoop (Remote-Repos) und
       bietet Installation an - fuer Faelle, in denen winget nicht
       kann (nicht anwendbar, publisher-Methode, Download-Fehler).
       -Adopt: Warnung dass vorhandene Installation ersetzt wird. #>
    param([Parameter(Mandatory)][string]$Query, [string]$Title = 'Anderer Paketmanager', [switch]$Adopt)
    Write-Host "`n  === Suche in Chocolatey + Scoop: $Query ===" -ForegroundColor Cyan
    Write-Host "  (Remote-Kataloge werden abgefragt - pro Begriff ein choco/scoop search, das kann 1-2 Minuten dauern)" -ForegroundColor DarkGray
    $chocoC = @(Find-SysPilotChocoRemoteCandidates -Query $Query)
    Write-Host "  Chocolatey: $($chocoC.Count) Kandidaten" -ForegroundColor DarkGray
    $scoopC = @(Find-SysPilotScoopRemoteCandidates -Query $Query)
    Write-Host "  Scoop: $($scoopC.Count) Kandidaten" -ForegroundColor DarkGray
    if ($chocoC.Count -eq 0 -and $scoopC.Count -eq 0) {
        Write-Host "  Keine Pakete in Chocolatey/Scoop gefunden." -ForegroundColor Yellow
        # Letzte Stufe der Update-Kette: Web-Kataloge mit automatisierten Versionen
        if (Get-Command Show-SysPilotWebSourceVersionsMenu -ErrorAction SilentlyContinue) {
            Write-Host "  -> versuche Web-Quellen (Versionen + Download-Links) ..." -ForegroundColor Cyan
            Show-SysPilotWebSourceVersionsMenu -Query $Query
        } else {
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
        }
        return $false
    }
    $items = @()
    foreach ($c in $chocoC) { $items += @{ Label="Chocolatey: $c"; Color='Green'; Tag="choco:$c" } }
    foreach ($c in $scoopC) { $items += @{ Label="Scoop: $c"; Color='Cyan';  Tag="scoop:$c" } }
    $items += @{ Label='Abbrechen'; Color='DarkGray'; Tag='back' }
    $sel = Show-SysPilotArrowMenu -Items $items -Title $Title -Footer 'Enter = installieren, Esc = abbruch'
    if (-not $sel -or $sel -eq 'back') { return $false }
    if ($sel -like 'choco:*') {
        $pkg = $sel.Substring(6)
        if ($Adopt) {
            Write-Host "`n  ACHTUNG: Die App ist bereits installiert (z.B. manuell/winget)." -ForegroundColor Yellow
            Write-Host "  choco install ersetzt sie - Einstellungen koennen verloren gehen," -ForegroundColor Yellow
            Write-Host "  dafuer wird die App danach von Chocolatey verwaltet (Updates klappen)." -ForegroundColor Yellow
        }
        if (-not (Confirm-SysPilot "Chocolatey-Paket '$pkg' installieren?")) { return $false }
        Write-Host "  -> choco install $pkg ..." -ForegroundColor Cyan
        $r = Invoke-SysPilotChocoInstallPkg -Pkg $pkg
        if ($r.Ok) { Write-Host "  [OK] $pkg installiert." -ForegroundColor Green; Write-SysPilotLog "choco install $pkg OK (alt-manager)"; return $true }
        Write-Host "  [!] $($r.Error)" -ForegroundColor Red
        return $false
    }
    if ($sel -like 'scoop:*') {
        $app = $sel.Substring(6)
        if ($Adopt) {
            Write-Host "`n  ACHTUNG: scoop installiert in eigenen Ordner - die vorhandene" -ForegroundColor Yellow
            Write-Host "  App bleibt bestehen (keine Uebernahme, evtl. doppelt vorhanden)." -ForegroundColor Yellow
        }
        if (-not (Confirm-SysPilot "Scoop-App '$app' installieren?")) { return $false }
        $se = Get-SysPilotScoopExeLocal
        if (-not $se) { Write-Host "  [!] scoop nicht gefunden." -ForegroundColor Red; return $false }
        Write-Host "  -> scoop install $app ..." -ForegroundColor Cyan
        $seExe = $se -replace '\.ps1$','.cmd'
        if (-not (Test-Path $seExe)) { $seExe = $se }
        $sr = Invoke-SysPilotMonitoredProcess -FilePath $seExe -ArgList @('install',$app) -Label "scoop install $app" -TimeoutSec 600
        $out = [string]$sr.Output
        $ok = ($sr.ExitCode -eq 0)
        if ($ok) { Write-Host "  [OK] $app installiert." -ForegroundColor Green; Write-SysPilotLog "scoop install $app OK (alt-manager)" }
        else { Write-Host "  [!] scoop exit $($sr.ExitCode)$(if($sr.Error){" - $($sr.Error)"})" -ForegroundColor Red
               $tail = (($out -split "`r?`n") | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 5) -join ' | '
               if ($tail) { Write-Host "  $tail" -ForegroundColor DarkGray } }
        return $ok
    }
    return $false
}

function Invoke-SysPilotWingetUpdateAuto {
    <# winget-Upgrade mit automatischer Fallback-Kette:
       1) normal (mit eigenem elevated-Retry bei Admin-Fehlern)
       2) bei not-applicable/publisher/other -> Chocolatey/Scoop,
          falls dort dasselbe Paket installiert ist
       3) Ergebnis konsolidiert (Via sagt, welcher Manager es schaffte). #>
    param(
        [Parameter(Mandatory)]$Row,
        [switch]$Silent,
        [int]$TimeoutSec = 900,
        [switch]$AllowElevated,
        [switch]$Quiet
    )
    $r = Invoke-SysPilotWingetUpdate -Id $Row.Id -Silent:$Silent -TimeoutSec $TimeoutSec -AllowElevated:$AllowElevated
    if ($r.Ok) { return $r }
    # Fallback nur sinnvoll, wenn winget prinzipiell nicht kann oder
    # der Installer scheitert - 'timeout'/'admin'-Endgueltig ausgenommen?
    # -> auch bei 'admin' nach failed elevated_retry versuchen: choco/scoop
    #    nutzen eigene Installer-Pfade.
    if ($r.Kind -in @('not-applicable','publisher','admin','other')) {
        $alt = Invoke-SysPilotAltManagerUpgrade -Row $Row -Quiet:$Quiet
        if ($alt) {
            if ($alt.Ok) {
                Write-SysPilotLog "UpdateFallback OK: $($Row.Name) via $($alt.Via) (winget: $($r.Kind))"
                return @{ Ok=$true; Error=''; Kind=''; Elevated=$false; Via=$alt.Via; Note=$alt.Note; Text=''; WingetErr=$r.Error }
            }
            Write-SysPilotLog "UpdateFallback FAIL: $($Row.Name) - $($alt.Error)"
            return @{ Ok=$false; Error="$($r.Error) | fallback: $($alt.Error)"; Kind=$r.Kind; Elevated=$r.Elevated; Via=$alt.Via; Text=$r.Text }
        }
    }
    return $r
}

function Update-SysPilotWingetSources {
    <# Aktualisiert die winget-Quellen (msstore/winget) selbsttaetig,
       wenn sie veraltet sind. Drossel: 1x pro 24h. #>
    if (-not (Test-SysPilotAutoFixDue -Name 'winget-source' -Hours 24)) { return }
    $exe = Get-SysPilotWingetExe
    if (-not $exe) { return }
    $r = Invoke-SysPilotWingetRaw -ArgList @('source','update') -TimeoutSec 120
    Save-SysPilotAutoFixStamp -Name 'winget-source'
    if ($r.Ok) { Write-SysPilotLog 'winget source update: OK' }
    else { Write-SysPilotLog "winget source update: $($r.Error)" }
}

function Get-SysPilotWingetUpgrades {
    <# Parse 'winget upgrade' / 'winget list --upgrade-available' (lokalisierte
       Spalten, daher Trennung an 2+ Spaces; ID enthaelt immer 'Publisher.App'). #>
    Update-SysPilotWingetSources
    # --include-unknown: sonst versteckt winget Pakete mit unbekannter
    # Versionsnummer hinter der Warnung "Mindestens N Pakete ..."
    $r = Invoke-SysPilotWingetRaw -ArgList @('upgrade','--include-unknown') -TimeoutSec 240
    # Sync-SysPilotFailedUpdates braucht zuverlaessig "keine Updates"
    # vs. "Abfrage fehlgeschlagen" unterscheiden zu koennen.
    $script:_wingetUpgOk = [bool]($r.Ok -or $r.Text)
    if (-not $r.Ok -and -not $r.Text) { return @() }
    $rows = @()
    foreach ($line in ($r.Text -split "`r?`n")) {
        if ($line -match '^\s*-{5,}' -or $line -match 'Aktualisierungen|updates available|Keine') { continue }
        # Token-weise: erste dotted ID mit >=3 Folgetokens (winget rueckt
        # lange Namen ohne 2-Spaces-Trennung an den ID heran!)
        $toks = @($line -split '\s+' | Where-Object { $_ -ne '' })
        $idIdx = -1
        for ($i = 0; $i -lt $toks.Count; $i++) {
            if ($toks[$i] -match '^[A-Za-z][A-Za-z0-9_.-]*\.[A-Za-z0-9][A-Za-z0-9_.-]*$' -and ($toks.Count - $i - 1) -ge 3) { $idIdx = $i; break }
        }
        if ($idIdx -lt 0) { continue }
        $name = ($toks[0..($idIdx-1)] -join ' ')
        $tail = $toks[($idIdx+1)..($toks.Count-1)]
        $src  = $tail[-1]
        $ver  = @($tail[0..($tail.Count-2)])
        # '< x.y' zusammenfuehren (winget zeigt "< 14.1.0" als zwei Tokens)
        $merged = @(); $vi = 0
        while ($vi -lt $ver.Count) {
            if ($ver[$vi] -eq '<' -and ($vi+1) -lt $ver.Count) { $merged += ('< ' + $ver[$vi+1]); $vi += 2 }
            else { $merged += $ver[$vi]; $vi++ }
        }
        if ($merged.Count -lt 2) { continue }
        $installed = $merged[-2]; $avail = $merged[-1]
        $rows += [pscustomobject]@{
            Name = $name.Trim(); Id = $toks[$idIdx]; Installed = $installed; Available = $avail; Source = $src
        }
    }
    return $rows
}

function Find-SysPilotWingetSearch {
    <# Remote-Suche ueber 'winget search' (alle konfigurierten Quellen).
       Token-Parsing wie Get-SysPilotWingetUpgrades: erste dotted ID
       (beginnt mit Buchstabe) = Paket-ID; liefert Name/Id/Version/Source. #>
    param([Parameter(Mandatory)][string]$Query, [int]$Limit = 20)
    $r = Invoke-SysPilotWingetRaw -ArgList @('search', $Query, '--accept-source-agreements') -TimeoutSec 120
    if (-not $r.Text) { return @() }
    $rows = @()
    foreach ($line in ($r.Text -split "`r?`n")) {
        $toks = @($line -split '\s+' | Where-Object { $_ -ne '' -and $_ -ne '|' })
        if ($toks.Count -lt 3) { continue }
        $idIdx = -1
        for ($i = 0; $i -lt $toks.Count; $i++) {
            if ($toks[$i] -match '^[A-Za-z][A-Za-z0-9_.-]*\.[A-Za-z0-9][A-Za-z0-9_.-]*$' -and ($toks.Count - $i - 1) -ge 1) { $idIdx = $i; break }
        }
        if ($idIdx -lt 1) { continue }
        $name = ($toks[0..($idIdx-1)] -join ' ').Trim()
        $tail = @($toks[($idIdx+1)..($toks.Count-1)])
        # Version = erstes Token das wie x.y aussieHt, Source = letztes Token
        $ver = ''; $src = ''
        foreach ($t in $tail) { if (-not $ver -and $t -match '^\d+(\.\d+)*$') { $ver = $t } }
        if ($tail.Count -gt 0) { $src = $tail[-1] }
        $rows += [pscustomobject]@{ Name = $name; Id = $toks[$idIdx]; Version = $ver; Source = $src }
        if ($rows.Count -ge $Limit) { break }
    }
    return $rows
}

function Update-SysPilotChocoSelf {
    <# Chocolatey-Selbst-Update, wenn 'choco outdated' meldet, dass
       Chocolatey selbst veraltet ist. Drossel: 1x pro 7 Tagen. #>
    if (-not (Test-SysPilotAutoFixDue -Name 'choco-self' -Hours 168)) { return }
    $exe = Get-SysPilotChocoExe
    if (-not $exe) { return }
    try {
        $chk = & $exe outdated chocolatey --no-color --limit-output 2>&1 | Out-String
        # Zeile wie 'chocolatey | 2.4.3 | 2.5.0 |'
        if ($chk -match '(?im)^\s*chocolatey\s*\|\s*[\d.]+\s*\|\s*([\d.]+)') {
            Save-SysPilotAutoFixStamp -Name 'choco-self'
            $cmd = "& '$exe' upgrade chocolatey -y --no-color"
            if (Test-SysPilotAdmin) {
                Write-Host "  -> Chocolatey selbst aktualisieren ($($Matches[1])) ..." -ForegroundColor DarkGray
                & $exe upgrade chocolatey -y --no-color --limit-output 2>&1 | Out-Null
                Write-SysPilotLog "choco self-update (Exit $LASTEXITCODE)"
            } else {
                Write-Host "  -> Chocolatey selbst ist veraltet ($($Matches[1])) - Admin noetig." -ForegroundColor Yellow
                $null = Show-SysPilotRunCommand -Command @($cmd) `
                    -Title 'Chocolatey-Update noetig' `
                    -Reason "Chocolatey selbst hat ein Update ($($Matches[1])). choco upgrade braucht Administratorrechte." `
                    -Owner $null
                Write-SysPilotLog "choco self-update angeboten (Admin-Card)"
            }
        }
    } catch { }
}

function Get-SysPilotChocoOutdated {
    $exe = Get-SysPilotChocoExe
    if (-not $exe) { $script:_chocoOutdatedOk = $false; return @() }
    Update-SysPilotChocoSelf
    try {
        $out = & $exe outdated --no-color --limit-output 2>&1 | Out-String
        $script:_chocoOutdatedOk = $true
    } catch { $script:_chocoOutdatedOk = $false; return @() }
    $rows = @()
    foreach ($line in ($out -split "`r?`n")) {
        # choco-Format: "Id | Version | Available Version | Pinned"
        if ($line -match 'Output is|Chocolatey v|package\(s\)|Warnings|Enjoy|https?://') { continue }
        $f = $line -split '\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
        if ($f.Count -lt 3) { continue }
        if ($f[0] -notmatch '[a-zA-Z]') { continue }
        if ($f[0] -match '^(Available|Version|Pinned|Id)$') { continue }
        # choco listet teils Pakete mit identischer Version (z.B.
        # chocolatey.server 0.3.0|0.3.0) -> Phantom-Update vermeiden
        $iv = ConvertTo-SysPilotVerObj -Text $f[1]
        $av = ConvertTo-SysPilotVerObj -Text $f[2]
        if ($iv -and $av -and $av -le $iv) { continue }
        if (-not $iv -and -not $av -and $f[1] -eq $f[2]) { continue }
        $rows += [pscustomobject]@{ Name = $f[0]; Id = $f[0]; Installed = $f[1]; Available = $f[2]; Source = 'chocolatey' }
    }
    return $rows
}

# =====================================================================
# KATALOG: kuratierte App -> Quelle(n)
# Felder: Cat, Name, WingetId?, Gh? (owner/repo), Page? (offizielle Seite),
#         Mg? (MajorGeeks-Detailslug), Note?
# =====================================================================

# MajorGeeks-Detailslugs (live verifiziert: Titel "Download <App> <Version>")
$script:MgSlugs = @{
    '7-Zip'='7-zip'; 'WinRAR'='winrar'; 'Bandizip'='bandizip'; 'NanaZip'='nanazip';
    'WinDirStat'='windirstat'; 'WizTree'='wiztree'; 'CrystalDiskInfo'='crystaldiskinfo';
    'HWiNFO'='hwinfo'; 'CPU-Z'='cpu-z'; 'GPU-Z'='gpu-z';
    'FanControl'='fancontrol'; 'Process Lasso'='process-lasso';
    'VirtualDesktop'='virtualdesktop'; 'Mem Reduct'='mem-reduct'; 'Special K'='special-k';
    'IrfanView'='irfanview'; 'FastStone Image Viewer'='faststone-image-viewer'; 'Calibre'='calibre';
    'VLC media player'='vlc-media-player'; 'MPC-HC'='mpc-hc'; 'foobar2000'='foobar2000';
    'AIMP'='aimp'; 'MusicBee'='musicbee'; 'Spotify'='spotify'; 'OBS Studio'='obs-studio';
    'HandBrake'='handbrake'; 'LosslessCut'='losslesscut'; 'Shutter Encoder'='shutter-encoder';
    'FFmpeg'='ffmpeg'; 'yt-dlp'='yt-dlp'; 'Audacity'='audacity'; 'LMMS'='lmms';
    'MuseScore'='musescore'; 'Opera'='opera'; 'Vivaldi'='vivaldi'; 'Zen Browser'='zen-browser';
    'Waterfox'='waterfox'; 'LibreWolf'='librewolf'; 'Microsoft PowerToys'='microsoft-powertoys';
    'Flow Launcher'='flow-launcher'; 'Everything'='everything'; 'Files'='files';
    'ExplorerPatcher'='explorerpatcher'; 'Windhawk'='windhawk'; 'TranslucentTB'='translucenttb';
    'MicaForEveryone'='mica-for-everyone'; 'EarTrumpet'='eartrumpet'; 'ShareX'='sharex';
    'Greenshot'='greenshot'; 'Flameshot'='flameshot'; 'CopyQ'='copyq'; 'Ditto'='ditto';
    'AutoHotkey'='autohotkey'; 'Joplin'='joplin'; 'Obsidian'='obsidian'; 'Zettlr'='zettlr';
    'draw.io'='drawio'; 'Krita'='krita'; 'Inkscape'='inkscape'; 'GIMP'='gimp'; 'Blender'='blender';
    'Zoom'='zoom'; 'Discord'='discord'; 'Telegram Desktop'='telegram'; 'Visual Studio Code'='visual-studio-code';
    'DBeaver'='dbeaver'; 'HeidiSQL'='heidisql'; 'Postman'='postman'; 'Insomnia'='insomnia';
    'Windows Terminal'='windows-terminal'; 'Wireshark'='wireshark'; 'WinSCP'='winscp';
    'FileZilla'='filezilla'; 'PuTTY'='putty'; 'FreeFileSync'='freefilesync'; 'KeePassXC'='keepassxc';
    'Ventoy'='ventoy'; 'Rufus'='rufus'; 'Bitwarden'='bitwarden'; 'Proton VPN'='protonvpn';
    'WireGuard'='wireguard'; 'LocalSend'='localsend'; 'OpenVPN'='openvpn'; 'Syncthing'='syncthing';
    'rclone'='rclone'; 'qBittorrent'='qbittorrent'; 'TeraCopy'='teracopy'; 'FastCopy'='fastcopy';
    'PeaZip'='peazip'
}

function Get-SysPilotUpdateCatalog {
    return @(
        # ---- Browser ----
        @{ Cat='Browser'; Name='Google Chrome';            WingetId='Google.Chrome';                 Page='https://www.google.com/chrome/' },
        @{ Cat='Browser'; Name='Microsoft Edge';           WingetId='Microsoft.Edge';                Page='https://www.microsoft.com/edge' },
        @{ Cat='Browser'; Name='Mozilla Firefox';          WingetId='Mozilla.Firefox';               Page='https://www.mozilla.org/firefox/' },
        @{ Cat='Browser'; Name='Brave Browser';            WingetId='Brave.Brave';                   Page='https://brave.com/download/' },
        @{ Cat='Browser'; Name='Opera';                    WingetId='Opera.Opera';                   Page='https://www.opera.com/download' },
        @{ Cat='Browser'; Name='Vivaldi';                  WingetId='Vivaldi.Vivaldi';               Page='https://vivaldi.com/download/' },
        @{ Cat='Browser'; Name='Zen Browser';              Gh='zen-browser/desktop';                 Page='https://zen-browser.app/' },
        @{ Cat='Browser'; Name='Waterfox';                 Gh='WaterfoxCo/Waterfox';                 Page='https://www.waterfox.net/' },
        @{ Cat='Browser'; Name='Thorium Browser';          Gh='Alex313031/Thorium';                  Page='https://thorium.rocks/' },
        @{ Cat='Browser'; Name='LibreWolf';                Page='https://librewolf.net/' },
        @{ Cat='Browser'; Name='Mullvad Browser';          Page='https://mullvad.net/browser/' },
        @{ Cat='Browser'; Name='Tor Browser';              WingetId='TorProject.TorBrowser';         Page='https://www.torproject.org/download/' },

        # ---- Netzwerk & VPN ----
        @{ Cat='Netzwerk & VPN'; Name='Tailscale';         WingetId='tailscale.tailscale';          Gh='tailscale/tailscale';              Page='https://tailscale.com/download' },
        @{ Cat='Netzwerk & VPN'; Name='ZeroTier';          Gh='zerotier/ZeroTierOne';               Page='https://www.zerotier.com/download/' },
        @{ Cat='Netzwerk & VPN'; Name='OpenVPN';           WingetId='OpenVPNTechnologies.OpenVPN';  Page='https://openvpn.net/download-open-vpn/' },
        @{ Cat='Netzwerk & VPN'; Name='WireGuard';         WingetId='WireGuard.WireGuard';          Page='https://www.wireguard.com/install/' },
        @{ Cat='Netzwerk & VPN'; Name='Cloudflare WARP';   WingetId='Cloudflare.Warp';              Page='https://one.one.one.one/' },
        @{ Cat='Netzwerk & VPN'; Name='NordVPN';           WingetId='NordSecurity.NordVPN';         Page='https://nordvpn.com/download/' },
        @{ Cat='Netzwerk & VPN'; Name='Proton VPN';        WingetId='Proton.ProtonVPN';             Page='https://protonvpn.com/download' },
        @{ Cat='Netzwerk & VPN'; Name='Windscribe';        WingetId='Windscribe.Windscribe';        Page='https://windscribe.com/install/' },
        @{ Cat='Netzwerk & VPN'; Name='Mullvad VPN';       Page='https://mullvad.net/en/download/' },
        @{ Cat='Netzwerk & VPN'; Name='Syncthing';         WingetId='Syncthing.Syncthing';          Gh='syncthing/syncthing';              Page='https://syncthing.net/downloads/' },
        @{ Cat='Netzwerk & VPN'; Name='rclone';            WingetId='Rclone.Rclone';                Gh='rclone/rclone';                    Page='https://rclone.org/downloads/' },
        @{ Cat='Netzwerk & VPN'; Name='LocalSend';         WingetId='LocalSend.LocalSend';          Gh='localsend/localsend';              Page='https://localsend.org/' },

        # ---- Multimedia ----
        @{ Cat='Multimedia'; Name='VLC media player';      WingetId='VideoLAN.VLC';                 Page='https://www.videolan.org/vlc/' },
        @{ Cat='Multimedia'; Name='MPC-HC';                WingetId='clsid2.mpc-hc';                Gh='clsid2/mpc-hc';                    Page='https://www.mpc-hc.org/' },
        @{ Cat='Multimedia'; Name='mpv.net';               Gh='mpvnet-player/mpv.net';              Page='https://mpv.net/' },
        @{ Cat='Multimedia'; Name='mpv';                   Gh='mpv-player/mpv';                     Page='https://mpv.io/' },
        @{ Cat='Multimedia'; Name='PotPlayer';             WingetId='Daum.PotPlayer';               Page='https://potplayer.daum.net/' },
        @{ Cat='Multimedia'; Name='foobar2000';            Page='https://www.foobar2000.org/download' },
        @{ Cat='Multimedia'; Name='AIMP';                  WingetId='AIMP.AIMP';                    Page='https://www.aimp.ru/' },
        @{ Cat='Multimedia'; Name='MusicBee';              Page='https://getmusicbee.com/' },
        @{ Cat='Multimedia'; Name='Spotify';               WingetId='Spotify.Spotify';              Page='https://www.spotify.com/download/' },
        @{ Cat='Multimedia'; Name='OBS Studio';            WingetId='OBSProject.OBSStudio';         Gh='obsproject/obs-studio';            Page='https://obsproject.com/' },
        @{ Cat='Multimedia'; Name='HandBrake';             WingetId='HandBrake.HandBrake';          Gh='HandBrake/HandBrake';              Page='https://handbrake.fr/' },
        @{ Cat='Multimedia'; Name='LosslessCut';           Gh='mifi/lossless-cut';                  Page='https://losslesscut.app/' },
        @{ Cat='Multimedia'; Name='Shutter Encoder';       Page='https://www.shutterencoder.com/' },
        @{ Cat='Multimedia'; Name='FFmpeg';                WingetId='Gyan.FFmpeg';                  Gh='BtbN/FFmpeg-Builds';               Page='https://ffmpeg.org/download.html' },
        @{ Cat='Multimedia'; Name='yt-dlp';                WingetId='yt-dlp.yt-dlp';                Gh='yt-dlp/yt-dlp';                    Page='https://github.com/yt-dlp/yt-dlp' },
        @{ Cat='Multimedia'; Name='aria2';                 WingetId='aria2.aria2';                  Gh='aria2/aria2';                      Page='https://aria2.github.io/' },
        @{ Cat='Multimedia'; Name='Audacity';              WingetId='Audacity.Audacity';            Gh='audacity/audacity';                Page='https://www.audacityteam.org/' },
        @{ Cat='Multimedia'; Name='LMMS';                  WingetId='LMMS.LMMS';                    Gh='LMMS/lmms';                        Page='https://lmms.io/' },
        @{ Cat='Multimedia'; Name='MuseScore';             Gh='musescore/MuseScore';                Page='https://musescore.org/' },
        @{ Cat='Multimedia'; Name='iTunes';                WingetId='Apple.iTunes';                 Page='https://www.apple.com/itunes/' },

        # ---- Media-Center (Kodi, Plex, Jellyfin & Co.) ----
        @{ Cat='Media-Center'; Name='Kodi';                  Desc='Open-Source Media-Center';        WingetId='XBMCFoundation.Kodi';           Gh='xbmc/xbmc';                         Page='https://kodi.tv/' },
        @{ Cat='Media-Center'; Name='KodiRoll Build';        Desc='Kodi-Build: Wizard + Addons (xstream, PlayForFun, Live-TV) - laeuft in Kodi unter Win/Android/TV'; Page='https://rolling-playforfun.de/app/'; Note='Install: Kodi > Einstellungen > File Manager > Source https://tinyurl.com/kodiroll > plugin.program.kodiroll.zip > Kodiroll Universal Build. APK-Variante (Android/Fire TV): kodiroll.apk auf derselben Seite' },
        @{ Cat='Media-Center'; Name='VYPN';                 Desc='Browser mit VPN + Media-Center (mhub-Quellen)'; Page='https://www.vypn.net/download'; Note='Direkt-Download Win64: https://www.vypn.net/update/download?app=net.vypn.app&platform=windows&arch=x86_64 - auch als Android-TV-App' },
        @{ Cat='Media-Center'; Name='Plex';                  Desc='Medien-Streaming Client';         WingetId='Plex.Plex';                     Gh='plex-inc';                          Page='https://www.plex.tv/' },
        @{ Cat='Media-Center'; Name='Plex Media Server';     Desc='Eigener Medienserver (Client+Server)'; WingetId='Plex.PlexMediaServer';        Page='https://www.plex.tv/download/' },
        @{ Cat='Media-Center'; Name='Plex HTPC';             Desc='Plex-Frontend fuer HTPCs';        WingetId='Plex.PlexHTPC';                 Page='https://www.plex.tv/' },
        @{ Cat='Media-Center'; Name='Plexamp';               Desc='Plex-Musik-Client';               WingetId='Plex.Plexamp';                  Page='https://www.plex.tv/plexamp/' },
        @{ Cat='Media-Center'; Name='Jellyfin Server';       Desc='Freier Medienserver (Open Source)'; WingetId='Jellyfin.Server';              Gh='jellyfin/jellyfin';                  Page='https://jellyfin.org/' },
        @{ Cat='Media-Center'; Name='Jellyfin Media Player'; Desc='Jellyfin-Client fuer Windows';    WingetId='Jellyfin.JellyfinMediaPlayer';  Gh='jellyfin/jellyfin-media-player';     Page='https://jellyfin.org/clients/' },
        @{ Cat='Media-Center'; Name='Emby';                  Desc='Medienserver + Client';           WingetId='9NBLGGH4T70L';                 WingetSource='msstore';                 Page='https://emby.media/' },
        @{ Cat='Media-Center'; Name='Stremio';               Desc='Streaming-Client mit Addons';     WingetId='Stremio.Stremio';               Gh='Stremio/stremio-shell';              Page='https://www.strem.io/' },
        @{ Cat='Media-Center'; Name='Moonfin';               Desc='Open-Source Jellyfin-Client';     WingetId='Moonfin.Moonfin';               Gh='Moonfin-Client/Moonfin-Core';       Page='https://github.com/Moonfin-Client/Moonfin-Core' },
        @{ Cat='Media-Center'; Name='Navidrome';             Desc='Musik-Streaming-Server';          WingetId='Navidrome.Navidrome';           Gh='navidrome/navidrome';                Page='https://www.navidrome.org/' },
        @{ Cat='Media-Center'; Name='Madsonic';              Desc='Subsonic-Fork: Musik/Medien-Server'; Gh='madsonic/madsonic';                Page='https://madsonic.com/' },
        @{ Cat='Media-Center'; Name='Universal Media Server'; Desc='DLNA/UPnP Medienserver';         WingetId='UniversalMediaServer.UniversalMediaServer'; Page='https://www.universalmediaserver.com/' },

        # ---- Produktivitaet ----
        @{ Cat='Produktivitaet'; Name='Microsoft PowerToys'; WingetId='Microsoft.PowerToys';       Gh='microsoft/PowerToys';              Page='https://learn.microsoft.com/windows/powertoys/' },
        @{ Cat='Produktivitaet'; Name='Flow Launcher';      WingetId='Flow-Launcher.Flow-Launcher';  Gh='Flow-Launcher/Flow.Launcher';      Page='https://www.flowlauncher.com/' },
        @{ Cat='Produktivitaet'; Name='Everything';         WingetId='voidtools.Everything';         Page='https://www.voidtools.com/' },
        @{ Cat='Produktivitaet'; Name='Files';              Gh='files-community/Files';              Page='https://files.community/' },
        @{ Cat='Produktivitaet'; Name='ExplorerPatcher';    Gh='valinet/ExplorerPatcher';            Page='https://github.com/valinet/ExplorerPatcher' },
        @{ Cat='Produktivitaet'; Name='Windhawk';           Gh='ramensoftware/windhawk';            Page='https://windhawk.net/' },
        @{ Cat='Produktivitaet'; Name='TranslucentTB';      Gh='TranslucentTB/TranslucentTB';        Page='https://github.com/TranslucentTB/TranslucentTB' },
        @{ Cat='Produktivitaet'; Name='MicaForEveryone';    Gh='MicaForEveryone/MicaForEveryone';    Page='https://github.com/MicaForEveryone/MicaForEveryone' },
        @{ Cat='Produktivitaet'; Name='EarTrumpet';         Gh='File-New-Project/EarTrumpet';        Page='https://eartrumpet.app/' },
        @{ Cat='Produktivitaet'; Name='ShareX';             WingetId='ShareX.ShareX';                Gh='ShareX/ShareX';                    Page='https://getsharex.com/' },
        @{ Cat='Produktivitaet'; Name='Greenshot';          WingetId='Greenshot.Greenshot';         Gh='greenshot/greenshot';              Page='https://getgreenshot.org/' },
        @{ Cat='Produktivitaet'; Name='Flameshot';          Gh='flameshot-org/flameshot';           Page='https://flameshot.org/' },
        @{ Cat='Produktivitaet'; Name='ScreenToGif';        Gh='NickeManarin/ScreenToGif';          Page='https://www.screentogif.com/' },
        @{ Cat='Produktivitaet'; Name='CopyQ';              Gh='hluk/CopyQ';                        Page='https://hluk.github.io/CopyQ/' },
        @{ Cat='Produktivitaet'; Name='Ditto';              WingetId='Ditto.Ditto';                 Page='https://ditto-cp.sourceforge.io/' },
        @{ Cat='Produktivitaet'; Name='AutoHotkey';         WingetId='AutoHotkey.AutoHotkey';       Gh='autohotkey/AutoHotkey';            Page='https://www.autohotkey.com/' },
        @{ Cat='Produktivitaet'; Name='espanso';           Gh='espanso/espanso';                   Page='https://espanso.org/' },
        @{ Cat='Produktivitaet'; Name='NotepadNext';        Gh='dail8859/NotepadNext';              Page='https://www.notepad-next.com/' },
        @{ Cat='Produktivitaet'; Name='Notepad++';          WingetId='Notepad++.Notepad++';         Page='https://notepad-plus-plus.org/' },
        @{ Cat='Produktivitaet'; Name='Obsidian';           WingetId='Obsidian.Obsidian';           Gh='obsidianmd/obsidian-releases';     Page='https://obsidian.md/' },
        @{ Cat='Produktivitaet'; Name='Joplin';             Gh='laurent22/joplin';                  Page='https://joplinapp.org/' },
        @{ Cat='Produktivitaet'; Name='Logseq';             Gh='logseq/logseq';                     Page='https://logseq.com/' },
        @{ Cat='Produktivitaet'; Name='Zettlr';             Gh='Zettlr/Zettlr';                     Page='https://www.zettlr.com/' },
        @{ Cat='Produktivitaet'; Name='MarkText';           Gh='marktext/marktext';                 Page='https://marktext.app/' },
        @{ Cat='Produktivitaet'; Name='draw.io';            WingetId='JGraph.Draw';                 Gh='jgraph/drawio-desktop';            Page='https://www.drawio.com/' },
        @{ Cat='Produktivitaet'; Name='Typora';             Page='https://typora.io/' },
        @{ Cat='Produktivitaet'; Name='Krita';              WingetId='KDE.Krita';                   Page='https://krita.org/' },
        @{ Cat='Produktivitaet'; Name='Inkscape';           WingetId='Inkscape.Inkscape';           Page='https://inkscape.org/' },
        @{ Cat='Produktivitaet'; Name='GIMP';               WingetId='GIMP.GIMP';                   Page='https://www.gimp.org/' },
        @{ Cat='Produktivitaet'; Name='Blender';           WingetId='BlenderFoundation.Blender';   Page='https://www.blender.org/' },
        @{ Cat='Produktivitaet'; Name='Figma';              WingetId='Figma.Figma';                 Page='https://www.figma.com/downloads/' },
        @{ Cat='Produktivitaet'; Name='Zoom';               WingetId='Zoom.Zoom';                   Page='https://zoom.us/download' },
        @{ Cat='Produktivitaet'; Name='Slack';              WingetId='SlackTechnologies.Slack';     Page='https://slack.com/downloads/windows' },
        @{ Cat='Produktivitaet'; Name='Discord';            WingetId='Discord.Discord';             Page='https://discord.com/download' },
        @{ Cat='Produktivitaet'; Name='Telegram Desktop';   WingetId='Telegram.TelegramDesktop';    Gh='telegramdesktop/tdesktop';                 Page='https://telegram.org/' },
        @{ Cat='Produktivitaet'; Name='Signal';             Gh='signalapp/Signal-Desktop';          Page='https://signal.org/download/' },
        @{ Cat='Produktivitaet'; Name='Element';            Gh='element-hq/element-desktop';        Page='https://element.io/' },
        @{ Cat='Produktivitaet'; Name='Mattermost';         Gh='mattermost/desktop';                Page='https://mattermost.com/download/' },

        # ---- Entwickler ----
        @{ Cat='Entwickler'; Name='Visual Studio Code';     WingetId='Microsoft.VisualStudioCode';  Gh='microsoft/vscode';                 Page='https://code.visualstudio.com/' },
        @{ Cat='Entwickler'; Name='VSCodium';               WingetId='VSCodium.VSCodium';           Gh='VSCodium/vscodium';               Page='https://vscodium.com/' },
        @{ Cat='Entwickler'; Name='GitHub Desktop';         WingetId='GitHub.GitHubDesktop';        Gh='desktop/desktop';                 Page='https://desktop.github.com/' },
        @{ Cat='Entwickler'; Name='Git';                    WingetId='Git.Git';                     Gh='git-for-windows/git';             Page='https://git-scm.com/' },
        @{ Cat='Entwickler'; Name='GitHub CLI';             WingetId='GitHub.cli';                  Gh='cli/cli';                         Page='https://cli.github.com/' },
        @{ Cat='Entwickler'; Name='Node.js LTS';            WingetId='OpenJS.NodeJS.LTS';           Gh='nodejs/node';                     Page='https://nodejs.org/' },
        @{ Cat='Entwickler'; Name='Python';                 WingetId='Python.Python.3.12';          Gh='python/cpython';                  Page='https://www.python.org/' },
        @{ Cat='Entwickler'; Name='uv';                     Gh='astral-sh/uv';                      Page='https://docs.astral.sh/uv/' },
        @{ Cat='Entwickler'; Name='Go';                     WingetId='GoLang.Go';                   Gh='golang/go';                       Page='https://go.dev/' },
        @{ Cat='Entwickler'; Name='Docker Desktop';         WingetId='Docker.DockerDesktop';        Gh='docker/for-win';                  Page='https://www.docker.com/products/docker-desktop/' },
        @{ Cat='Entwickler'; Name='Podman Desktop';         WingetId='RedHat.PodmanDesktop';        Gh='containers/podman-desktop';        Page='https://podman-desktop.io/' },
        @{ Cat='Entwickler'; Name='Postman';                WingetId='Postman.Postman';             Page='https://www.postman.com/downloads/' },
        @{ Cat='Entwickler'; Name='Insomnia';               WingetId='Kong.Insomnia';               Gh='Kong/insomnia';                   Page='https://insomnia.rest/' },
        @{ Cat='Entwickler'; Name='Bruno';                  Gh='usebruno/bruno';                    Page='https://www.usebruno.com/' },
        @{ Cat='Entwickler'; Name='DBeaver';                WingetId='DBeaver.DBeaverCommunity';    Gh='dbeaver/dbeaver';                 Page='https://dbeaver.io/' },
        @{ Cat='Entwickler'; Name='HeidiSQL';               WingetId='HeidiSQL.HeidiSQL';           Page='https://www.heidisql.com/' },
        @{ Cat='Entwickler'; Name='Beekeeper Studio';       Gh='beekeeper-studio/beekeeper-studio'; Page='https://www.beekeeperstudio.io/' },
        @{ Cat='Entwickler'; Name='Windows Terminal';       WingetId='Microsoft.WindowsTerminal';    Gh='microsoft/terminal';              Page='https://learn.microsoft.com/windows/terminal/' },
        @{ Cat='Entwickler'; Name='PowerShell';             WingetId='Microsoft.PowerShell';         Gh='PowerShell/PowerShell';            Page='https://github.com/PowerShell/PowerShell' },
        @{ Cat='Entwickler'; Name='Neovim';                 WingetId='Neovim.Neovim';               Gh='neovim/neovim';                   Page='https://neovim.io/' },
        @{ Cat='Entwickler'; Name='Wireshark';              WingetId='WiresharkFoundation.Wireshark'; Page='https://www.wireshark.org/' },
        @{ Cat='Entwickler'; Name='WinSCP';                 WingetId='WinSCP.WinSCP';               Page='https://winscp.net/' },
        @{ Cat='Entwickler'; Name='FileZilla';              WingetId='FileZilla.FileZilla.Client';  Page='https://filezilla-project.org/' },
        @{ Cat='Entwickler'; Name='PuTTY';                  WingetId='PuTTY.PuTTY';                 Page='https://www.putty.org/' },
        @{ Cat='Entwickler'; Name='NanaZip';                Gh='M2Team/NanaZip';                    Page='https://github.com/M2Team/NanaZip' },

        # ---- System & Tools ----
        @{ Cat='System & Tools'; Name='7-Zip';              WingetId='7zip.7zip';                   Gh='ip7z/7zip';                       Page='https://www.7-zip.org/' },
        @{ Cat='System & Tools'; Name='WinRAR';             WingetId='RARLab.WinRAR';               Page='https://www.rarlab.com/' },
        @{ Cat='System & Tools'; Name='Bandizip';           WingetId='Bandisoft.Bandizip';          Page='https://www.bandisoft.com/bandizip/' },
        @{ Cat='System & Tools'; Name='WinDirStat';         WingetId='WinDirStat.WinDirStat';       Gh='winDirStat/winDirStat';            Page='https://windirstat.net/' },
        @{ Cat='System & Tools'; Name='WizTree';            WingetId='AntibodySoftware.WizTree';    Page='https://diskanalyzer.com/' },
        @{ Cat='System & Tools'; Name='CrystalDiskInfo';    WingetId='CrystalDewWorld.CrystalDiskInfo'; Gh='hiyohiyo/CrystalDiskInfo';     Page='https://crystalmark.info/' },
        @{ Cat='System & Tools'; Name='CrystalDiskMark';    WingetId='CrystalDewWorld.CrystalDiskMark'; Gh='hiyohiyo/CrystalDiskMark';     Page='https://crystalmark.info/' },
        @{ Cat='System & Tools'; Name='HWiNFO';             WingetId='REALiX.HWiNFO';                Page='https://www.hwinfo.com/' },
        @{ Cat='System & Tools'; Name='CPU-Z';              WingetId='CPUID.CPU-Z';                 Page='https://www.cpuid.com/softwares/cpu-z.html' },
        @{ Cat='System & Tools'; Name='GPU-Z';              WingetId='TechPowerUp.GPU-Z';           Page='https://www.techpowerup.com/gpuz/' },
        @{ Cat='System & Tools'; Name='FanControl';         WingetId='Rem0o.FanControl';            Gh='Rem0o/FanControl.Releases';        Page='https://getfancontrol.com/' },
        @{ Cat='System & Tools'; Name='LibreHardwareMonitor'; WingetId='LibreHardwareMonitor.LibreHardwareMonitor'; Gh='LibreHardwareMonitor/LibreHardwareMonitor'; Page='https://github.com/LibreHardwareMonitor/LibreHardwareMonitor' },
        @{ Cat='System & Tools'; Name='OpenHardwareMonitor'; WingetId='OpenHardwareMonitor.OpenHardwareMonitor'; Gh='OpenHardwareMonitor/OpenHardwareMonitor'; Page='https://openhardwaremonitor.org/' },
        @{ Cat='System & Tools'; Name='Bulk Crap Uninstaller'; WingetId='Klocman.BulkCrapUninstaller'; Gh='Klocman/Bulk-Crap-Uninstaller';  Page='https://www.bcuninstaller.com/' },
        @{ Cat='System & Tools'; Name='SumatraPDF';         WingetId='SumatraPDF.SumatraPDF';       Gh='sumatrapdfreader/sumatrapdf';      Page='https://www.sumatrapdfreader.org/' },
        @{ Cat='System & Tools'; Name='KeePassXC';          WingetId='KeePassXC.KeePassXC';         Gh='keepassxreboot/keepassxc';         Page='https://keepassxc.org/' },
        @{ Cat='System & Tools'; Name='Ventoy';             WingetId='Ventoy.Ventoy';                Gh='ventoy/Ventoy';                    Page='https://www.ventoy.net/' },
        @{ Cat='System & Tools'; Name='Rufus';              WingetId='Rufus.Rufus';                 Gh='pbatard/rufus';                    Page='https://rufus.ie/' },
        @{ Cat='System & Tools'; Name='FreeFileSync';       WingetId='FreeFileSync.FreeFileSync';   Page='https://freefilesync.org/' },
        @{ Cat='System & Tools'; Name='VirtualDesktop';     WingetId='MScholtes.VirtualDesktop';    Gh='MScholtes/VirtualDesktop';          Page='https://github.com/MScholtes/VirtualDesktop' },
        @{ Cat='System & Tools'; Name='Process Lasso';      WingetId='Bitsum.ProcessLasso';         Page='https://bitsum.com/' },
        @{ Cat='System & Tools'; Name='TreeSize Free';      WingetId='JAMSoftware.TreeSizeFree';    Page='https://www.jamsoftware.com/treesize-free' },
        @{ Cat='System & Tools'; Name='Mem Reduct';         WingetId='henrypp.memreduct';           Gh='henrypp/memreduct';                Page='https://github.com/henrypp/memreduct' },
        @{ Cat='System & Tools'; Name='Special K';          Gh='Kaldaien/SpecialK';                 Page='https://kaldaien.net/ca_SPECIALK.html' },
        @{ Cat='System & Tools'; Name='IrfanView';          WingetId='IrfanView.IrfanView';         Page='https://www.irfanview.com/' },
        @{ Cat='System & Tools'; Name='FastStone Image Viewer'; WingetId='FastStone.FSIV';           Page='https://www.faststone.org/' },
        @{ Cat='System & Tools'; Name='Calibre';            WingetId='Calibre-Project.Calibre';     Page='https://calibre-ebook.com/' },
        @{ Cat='System & Tools'; Name='qBittorrent';        WingetId='qBittorrent.qBittorrent';     Gh='qBittorrent/qBittorrent';          Page='https://www.qbittorrent.org/' },
        @{ Cat='System & Tools'; Name='TeraCopy';           WingetId='CodeSector.TeraCopy';        Page='https://codesector.com/teracopy' },
        @{ Cat='System & Tools'; Name='FastCopy';           WingetId='FastCopy.FastCopy';          Page='https://fastcopy.jp/' },
        @{ Cat='System & Tools'; Name='PeaZip';             WingetId='PeaZip.Peazip';              Page='https://peazip.github.io/' },

        # ---- Sicherheit ----
        @{ Cat='Sicherheit'; Name='Malwarebytes';           WingetId='Malwarebytes.Malwarebytes';   Page='https://www.malwarebytes.com/' },
        @{ Cat='Sicherheit'; Name='Bitwarden';              WingetId='Bitwarden.Bitwarden';         Gh='bitwarden/clients';                Page='https://bitwarden.com/download/' },
        @{ Cat='Sicherheit'; Name='1Password';              WingetId='1Password.1Password';         Page='https://1password.com/downloads/' },
        @{ Cat='Sicherheit'; Name='AdGuard Home';           Gh='AdguardTeam/AdGuardHome';           Page='https://adguard.com/adguard-home/overview.html' },
        @{ Cat='Sicherheit'; Name='BleachBit';              WingetId='BleachBit.BleachBit';         Gh='bleachbit/bleachbit';              Page='https://www.bleachbit.org/' },
        @{ Cat='Sicherheit'; Name='Kaspersky';              Page='https://www.kaspersky.de/downloads/' },
        @{ Cat='Sicherheit'; Name='ESET';                   Page='https://www.eset.com/de/download/home/' },
        @{ Cat='Sicherheit'; Name='Bitdefender';            Page='https://www.bitdefender.de/consumer/free/' },
        @{ Cat='Sicherheit'; Name='SUPERAntiSpyware';       Page='https://www.superantispyware.com/' },
        @{ Cat='Sicherheit'; Name='HitmanPro';              Page='https://www.sophos.com/de-de/products/hitman/' },

        # ---- KI-Apps (lokale LLMs, AI-Clients, Agenten, MCP) ----
        @{ Cat='KI-Apps'; Name='Claude Desktop'; Desc='Anthropics Desktop-App fuer Claude (Chat, Projects)';            WingetId='Anthropic.Claude';          Page='https://claude.com/download' },
        @{ Cat='KI-Apps'; Name='Claude Code'; Desc='KI-Coding-Agent im Terminal (Anthropic)';               WingetId='Anthropic.ClaudeCode';      Page='https://claude.com/product/claude-code' },
        @{ Cat='KI-Apps'; Name='Claude Platform CLI'; Desc='CLI fuer Claude Platform/API-Verwaltung';       WingetId='Anthropic.Ant';             Page='https://docs.anthropic.com/' },
        @{ Cat='KI-Apps'; Name='Microsoft Copilot'; Desc='Microsofts KI-Assistent (Windows, Office, Browser)';         WingetId='Microsoft.Copilot';         Page='https://copilot.microsoft.com/' },
        @{ Cat='KI-Apps'; Name='Gemini Desktop'; Desc='Googles KI-Assistent als Windows-App';            WingetId='Google.GeminiDesktop';      Page='https://gemini.google.com/app' },
        @{ Cat='KI-Apps'; Name='Devin'; Desc='Autonomer KI-Softwareingenieur (Cognition)';                     WingetId='Codeium.Windsurf';          Page='https://devin.ai/' },
        @{ Cat='KI-Apps'; Name='Windsurf'; Desc='KI-Code-Editor (Ex-Codeium, Devin-Macher)';                  Page='https://windsurf.com/' },
        @{ Cat='KI-Apps'; Name='Perplexity'; Desc='Perplexitys KI-Suchmaschine als Windows-App (Store)';       WingetId='9P9XG917PWCJ'; WingetSource='msstore'; Page='https://www.perplexity.ai/'; Note='Nur als MSIX/Store-App erhaeltlich (auch Web-Installer nutzt Store-System) - Alternative: Comet Browser' },
        @{ Cat='KI-Apps'; Name='Comet Browser'; Desc='Perplexitys KI-Browser (eingebaute KI-Suche)';           WingetId='Perplexity.Comet'; Page='https://www.perplexity.ai/comet' },
        @{ Cat='KI-Apps'; Name='Ollama'; Desc='Lokale LLMs starten/verwalten (OpenAI-kompatible API)';                    WingetId='Ollama.Ollama';             Gh='ollama/ollama';                     Page='https://ollama.com/' },
        @{ Cat='KI-Apps'; Name='LM Studio'; Desc='GUI fuer lokale LLMs (Modelle, Chat, API-Server)';                 WingetId='ElementLabs.LMStudio';      Page='https://lmstudio.ai/' },
        @{ Cat='KI-Apps'; Name='llama.cpp'; Desc='C/C++-Inferenz-Engine fuer GGUF-Modelle';                 Gh='ggml-org/llama.cpp';              DetectPaths=@('C:\llama.cpp');          Page='https://github.com/ggml-org/llama.cpp' },
        @{ Cat='KI-Apps'; Name='GPT4All'; Desc='Desktop-Chat fuer lokale LLMs (Nomic AI)';                   Gh='nomic-ai/gpt4all';                Page='https://www.nomic.ai/gpt4all' },
        @{ Cat='KI-Apps'; Name='Jan'; Desc='Open-Source ChatGPT-Alternative, 100% offline';                       WingetId='Jan.Jan';                   Gh='janhq/jan';                         Page='https://jan.ai/' },
        @{ Cat='KI-Apps'; Name='KoboldCpp'; Desc='Ein-File GGUF-Runner mit KoboldAI-UI';                 Gh='LostRuins/koboldcpp';             Page='https://github.com/LostRuins/koboldcpp' },
        @{ Cat='KI-Apps'; Name='text-generation-webui'; Desc='Desktop-App fuer lokale LLMs mit Web-UI';     Gh='oobabooga/text-generation-webui'; Page='https://github.com/oobabooga/text-generation-webui' },
        @{ Cat='KI-Apps'; Name='LocalAI'; Desc='Open-Source AI-Engine: LLMs, Vision, Voice, Bilder';                   Gh='mudler/LocalAI';                  Page='https://localai.io/' },
        @{ Cat='KI-Apps'; Name='ExLlamaV2'; Desc='Schnelle GPU-Inferenz-Bibliothek fuer LLMs';                 Gh='turboderp-org/exllamav2';         Page='https://github.com/turboderp-org/exllamav2' },
        @{ Cat='KI-Apps'; Name='llama-swap'; Desc='Wechselt automatisch Modelle in lokalen AI-Servern';                Gh='mostlygeek/llama-swap';           Page='https://github.com/mostlygeek/llama-swap' },
        @{ Cat='KI-Apps'; Name='Cherry Studio'; Desc='AI-Workspace: Modelle, Agenten, Produktivitaet';             Gh='CherryHQ/cherry-studio';          Page='https://www.cherry-ai.com/' },
        @{ Cat='KI-Apps'; Name='Chatbox'; Desc='Leichtgewichtiger Desktop-KI-Client';                   Gh='chatboxai/chatbox';               Page='https://chatboxai.app/' },
        @{ Cat='KI-Apps'; Name='Msty'; Desc='Native Desktop-App fuer KI-Modelle (lokal+Cloud)';                      Page='https://msty.app/' },
        @{ Cat='KI-Apps'; Name='AnythingLLM'; Desc='Lokales RAG/Agent-Framework mit Desktop-App';               Gh='Mintplex-Labs/anything-llm';      Page='https://anythingllm.com/' },
        @{ Cat='KI-Apps'; Name='NextChat'; Desc='Zero-Config KI-Chat (Web/iOS/Android/Windows)';                  Gh='ChatGPTNextWeb/NextChat';         Page='https://nextchat.dev/' },
        @{ Cat='KI-Apps'; Name='LobeChat'; Desc='Moderne Chat-UI mit Agents, MCP, Skills';                  Gh='lobehub/lobe-chat';               Page='https://lobehub.com/' },
        @{ Cat='KI-Apps'; Name='Open WebUI'; Desc='User-freundliche KI-Oberflaeche (Ollama-kompatibel)';                Gh='open-webui/open-webui';           Page='https://openwebui.com/' },
        @{ Cat='KI-Apps'; Name='LibreChat'; Desc='ChatGPT-Klon mit Agents, MCP, Multi-User';                 Gh='danny-avila/LibreChat';           Page='https://www.librechat.ai/' },
        @{ Cat='KI-Apps'; Name='Witsy'; Desc='Schneller nativer Desktop-KI-Client';                     Page='https://witsy.app/' },
        @{ Cat='KI-Apps'; Name='Khoj'; Desc='Persoenlicher AI-Second-Brain (Suche, Agents)';                      Gh='khoj-ai/khoj';                    Page='https://khoj.dev/' },
        @{ Cat='KI-Apps'; Name='Perplexica'; Desc='Selbst-gehostete Perplexity-Alternative';                Gh='ItzCrazyKns/Perplexica';          Page='https://github.com/ItzCrazyKns/Perplexica' },
        @{ Cat='KI-Apps'; Name='Onyx'; Desc='Open-Source AI-Platform (Chat, Search, Agents)';                      Gh='onyx-dot-app/onyx';               Page='https://www.onyx.app/' },
        @{ Cat='KI-Apps'; Name='Kotaemon'; Desc='RAG-Tool zum Chatten mit eigenen Dokumenten';                  Gh='Cinnamon/kotaemon';               Page='https://cinnamon.github.io/kotaemon/' },
        @{ Cat='KI-Apps'; Name='SillyTavern'; Desc='Power-User-Frontend fuer LLMs (Rollenspiele)';               Gh='SillyTavern/SillyTavern';         Page='https://sillytavern.app/' },
        @{ Cat='KI-Apps'; Name='Dify'; Desc='Visuelle AI-Workflow/RAG-Plattform';                      Gh='langgenius/dify';                 Page='https://dify.ai/' },
        @{ Cat='KI-Apps'; Name='Flowise'; Desc='Visueller Builder fuer AI-Agents und Workflows';                   Gh='FlowiseAI/Flowise';               Page='https://flowiseai.com/' },
        @{ Cat='KI-Apps'; Name='Langflow'; Desc='Visueller Builder fuer AI-Agents (Drag&Drop)';                  WingetId='Langflow.Langflow';         Gh='langflow-ai/langflow';               Page='https://www.langflow.org/' },
        @{ Cat='KI-Apps'; Name='Aider'; Desc='KI-Pair-Programming im Terminal';                     Gh='Aider-AI/aider';                  Page='https://aider.chat/' },
        @{ Cat='KI-Apps'; Name='Open Interpreter'; Desc='Coding-Agent: fuehrt Code aus, bearbeitet Dateien';          Gh='OpenInterpreter/open-interpreter'; Page='https://docs.openinterpreter.com/' },
        @{ Cat='KI-Apps'; Name='Goose'; Desc='Open-Source AI-Agent (Block): Code ausfuehren/editieren';                     Gh='block/goose';                     Page='https://block.github.io/goose/' },
        @{ Cat='KI-Apps'; Name='opencode'; Desc='Open-Source Coding-Agent im Terminal (npm)';                  NpmPkg='opencode-ai';                 Gh='sst/opencode';                       DetectCmds=@('opencode'); Page='https://opencode.ai/' },
        @{ Cat='KI-Apps'; Name='Gemini CLI'; Desc='Gemini direkt im Terminal (Google, Open Source)';                NpmPkg='@google/gemini-cli';          Gh='google-gemini/gemini-cli';           Page='https://github.com/google-gemini/gemini-cli' },
        @{ Cat='KI-Apps'; Name='Codex CLI'; Desc='OpenAI-Coding-Agent im Terminal';                 WingetId='OpenAI.Codex';              Gh='openai/codex';                       Page='https://github.com/openai/codex' },
        @{ Cat='KI-Apps'; Name='Cline'; Desc='VS-Code-Extension: autonomer Coding-Agent';                     Page='https://cline.bot/';            DetectPaths=@("$env:APPDATA\Code\User\globalStorage\saoudrizwan.claude-dev") },
        @{ Cat='KI-Apps'; Name='Continue'; Desc='Open-Source Coding-Agent (VS Code/JetBrains)';                  Gh='continuedev/continue';            Page='https://www.continue.dev/' },
        @{ Cat='KI-Apps'; Name='Tabby'; Desc='Self-hosted AI-Coding-Assistant';                     WingetId='TabbyML.Tabby';             Gh='TabbyML/tabby';                      Page='https://tabbyml.com/' },
        @{ Cat='KI-Apps'; Name='Void Editor'; Desc='Open-Source Code-Editor mit KI (Cursor-Alternative)';               Gh='voideditor/void';                 Page='https://voideditor.com/' },
        @{ Cat='KI-Apps'; Name='Zed'; Desc='Schneller Code-Editor mit integrierter KI';                       WingetId='ZedIndustries.Zed';         Gh='zed-industries/zed';                 Page='https://zed.dev/' },
        @{ Cat='KI-Apps'; Name='Trae'; Desc='KI-IDE von ByteDance';                      Page='https://www.trae.ai/' },
        @{ Cat='KI-Apps'; Name='Melty'; Desc='Agentic Code-Editor';                     Gh='meltylabs/melty';                 Page='https://github.com/meltylabs/melty' },
        @{ Cat='KI-Apps'; Name='Pieces'; Desc='AI-Context-Manager fuer Entwickler (Memory)';                    Page='https://pieces.app/' },
        @{ Cat='KI-Apps'; Name='Supermaven'; Desc='KI-Code-Completion';                Page='https://supermaven.com/' },
        @{ Cat='KI-Apps'; Name='PocketAI Hub'; Desc='Privater Offline-KI-Client (Modelle auf dem Geraet)';              Page='https://pocketaihub.com/download'; Note='Privater Offline-KI-Client (Win/macOS/Linux/iOS/Android), Direkt-Download v1.0.39' },
        @{ Cat='KI-Apps'; Name='Layla (Desktop)'; Desc='Lokaler AI-Assistent (Tools, Memory, LLMs)';           Gh='PapaKoftes/Layla';                Page='https://github.com/PapaKoftes/Layla'; Note='Lokaler AI-Assistent per Install-Skript; Web-UI http://localhost:8000/ui; mobile App: layla-network.ai' },
        @{ Cat='KI-Apps'; Name='FreeLLMAPI'; Desc='Router: 87 Free-LLM-Provider hinter einem /v1-Endpunkt';                Gh='tashfeenahmed/freellmapi';        Page='https://freellmapi.co/';            Setup='freellmapi'; SetupLabel='FreeLLMAPI einrichten (Docker/Sync/keys.env)'; Note='Self-hosted Router: 87 Free-Provider hinter einem /v1-Endpunkt (Docker, localhost:3001)' },
        @{ Cat='KI-Apps'; Name='OmniRoute'; Desc='AI-Gateway: 375 Provider, Auto-Fallback, MCP/A2A';                 NpmPkg='omniroute';                   Gh='cheaper-inference/OmniRoute';         Page='https://omniroute.online/';         Setup='omniroute'; SetupLabel='OmniRoute einrichten (Token/Sync/Keys)'; Note='npm i -g omniroute -> http://localhost:20128 - AI-Gateway mit 375 Providern' },
        @{ Cat='KI-Apps'; Name='9router'; Desc='AI-Router: 40+ Provider, Auto-Fallback, RTK-Token-Sparer';             NpmPkg='9router';                      Gh='decolua/9router';                    Page='https://9router.com/';              Setup='9router'; SetupLabel='9router einrichten (Start/Passwort/Sync)'; Note='npm i -g 9router -> lokaler Router (Port 20128, paralleler Betrieb zu OmniRoute auf 20130 empfohlen)' },
        @{ Cat='KI-Apps'; Name='freelm'; Desc='Free-LLM-Aggregator als Python/Node-Lib + CLI';                    PipPkg='freelm';                      Gh='shihabshahrier/freelm';               NpmPkg='freelm'; Page='https://github.com/shihabshahrier/freelm'; Setup='freelm'; SetupLabel='freelm einrichten (Env-Vars/Serve)'; Note='pip install freelm oder npm i freelm - Free-LLM-Aggregator' },
        @{ Cat='KI-Apps'; Name='MCP Inspector'; Desc='Debugging-UI fuer MCP-Server (npx)';             NpmPkg='@modelcontextprotocol/inspector'; Gh='modelcontextprotocol/servers';      Page='https://modelcontextprotocol.io/';   Note='MCP-Server testen/debuggen (npx)' },
        @{ Cat='KI-Apps'; Name='MCPDeskClient'; Desc='Windows-nativer MCP-Desktop-Client (WinUI3)';             Gh='clatonhendricks/MCPDeskClient';   Page='https://github.com/clatonhendricks/MCPDeskClient'; Note='Windows-nativer MCP-Desktop-Client (WinUI3)' },
        @{ Cat='KI-Apps'; Name='MCP-Server (Win ODR)'; Desc='Windows-eigene MCP-Registry (On-Device Registry)';      DetectCmds=@('odr.exe');               Page='https://learn.microsoft.com/windows/ai/mcp/overview'; Note='Windows On-Device Registry: odr.exe mcp list zeigt registrierte MCP-Server' }
    ) | Where-Object { $_ -and $_.Name } | ForEach-Object {
        if (-not $_.Mg -and $script:MgSlugs.ContainsKey($_.Name)) { $_.Mg = $script:MgSlugs[$_.Name] }
        $_
    }
}

function Get-SysPilotUpdateCatalogCategories {
    $cats = @{}
    foreach ($a in Get-SysPilotUpdateCatalog) {
        if (-not $cats.ContainsKey($a.Cat)) { $cats[$a.Cat] = @() }
        $cats[$a.Cat] += $a
    }
    return $cats.Keys | Sort-Object
}

# =====================================================================
# INSTALLIERT-VERSION (Registry-Uninstall, gecacht)
# =====================================================================

function Get-SysPilotInstalledAppMap {
    if ($script:_installedMap) { return $script:_installedMap }
    $map = @{}
    $keys = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
              'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
              'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')
    foreach ($k in $keys) {
        Get-ItemProperty $k -ErrorAction SilentlyContinue | ForEach-Object {
            $dn = $_.DisplayName
            if (-not $dn) { return }
            $map[$dn.ToLower()] = [pscustomobject]@{ Name = $dn; Version = [string]$_.DisplayVersion }
        }
    }
    $script:_installedMap = $map
    return $map
}

function Find-SysPilotCatalogInstalled {
    param([Parameter(Mandatory)][hashtable]$App)
    $map = Get-SysPilotInstalledAppMap
    $target = $App.Name.ToLower()
    # 1) exakter Namens-Treffer
    if ($map.ContainsKey($target)) { return $map[$target] }
    # 2) Enthalten-Match (kuerzester DisplayName-Gewinner)
    $best = $null; $bestLen = [int]::MaxValue
    foreach ($k in $map.Keys) {
        if ($k.Contains($target) -or $target.Contains($k)) {
            if ($k.Length -lt $bestLen) { $bestLen = $k.Length; $best = $map[$k] }
        }
    }
    if ($best) { return $best }
    # 3) KI-Apps: Erkennung ueber Ordner/Commands (portabel, npm, manuell)
    if ($App.DetectPaths) {
        foreach ($p in @($App.DetectPaths)) {
            $exp = [Environment]::ExpandEnvironmentVariables([string]$p)
            if ($exp -and (Test-Path $exp)) {
                return [pscustomobject]@{ Name=$App.Name; Version='erkannt (Ordner)' }
            }
        }
    }
    if ($App.DetectCmds) {
        foreach ($c in @($App.DetectCmds)) {
            if (Get-Command ([string]$c) -ErrorAction SilentlyContinue) {
                return [pscustomobject]@{ Name=$App.Name; Version='erkannt (Kommando)' }
            }
        }
    }
    return $null
}

# =====================================================================
# GITHUB-QUELLEN: neueste Version + bestes Installer-Asset
# =====================================================================

function Get-SysPilotGithubLatest {
    <# GitHub releases/latest. Gibt @{Ok;Tag;Version;Assets} zurueck. #>
    param([Parameter(Mandatory)][string]$Repo, [int]$TimeoutSec = 20)
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $res = [pscustomobject]@{ Ok = $false; Tag = $null; Version = $null; Assets = @(); Error = '' }
    try {
        # Resilienter Aufruf (Retry+Backoff) bei instabilen Netzen (Hotspot)
        $resp = Invoke-SysPilotHttpRequest -Uri "https://api.github.com/repos/$Repo/releases/latest" -Method Get -Headers $script:_ghHeaders -TimeoutSec $TimeoutSec -Retries 3 -OnRetry { param($a,$w,$m) Write-Host "  [github] ${Repo}: Versuch $a fehlgeschlagen ($m) - Retry in ${w}s" -ForegroundColor DarkYellow }
        $r = $resp.Content | ConvertFrom-Json
        $res.Ok = $true
        $res.Tag = [string]$r.tag_name
        $res.Assets = @($r.assets)
        $res.Version = ([string]$r.tag_name) -replace '^v',''
    } catch { $res.Error = $_.Exception.Message }
    return $res
}

function Select-SysPilotGithubAsset {
    <# Waehlt das beste Windows-Installer-Asset: .msi > .exe > .zip > .7z,
       Debug/Symbole/Sigs werden uebersprungen, x64 bevorzugt. #>
    param([object[]]$Assets)
    if (-not $Assets -or $Assets.Count -eq 0) { return $null }
    $skip = '(?i)(debug|symbols|\.pdb$|\.blockmap$|\.sig$|\.asc$|\.sha\d*$|source|linux|macos|\.dmg$|\.appimage|\.snap|arm64|\.msixbundle$|\.appx$|\.nupkg$|\.snupkg$|\.tar\.|\.rpm$|\.deb$|\.flatpak|\.apk$)'
    $cand = @($Assets | Where-Object { $_.name -notmatch $skip })
    if ($cand.Count -eq 0) { $cand = @($Assets) }
    function _score($a) {
        $n = $a.name.ToLower(); $s = 0
        if ($n -match '\.msi$') { $s += 100 }
        elseif ($n -match '\.exe$') { $s += 80 }
        elseif ($n -match '\.(zip|7z)$') { $s += 60 }
        if ($n -match '(x64|amd64|x86_64|win64|64-bit|64bit)') { $s += 20 }
        elseif ($n -notmatch '(x86|win32|ia32|32-bit)') { $s += 10 }
        if ($n -match 'setup|install') { $s += 5 }
        return $s
    }
    return ($cand | Sort-Object { _score $_ } -Descending | Select-Object -First 1)
}

# =====================================================================
# DOWNLOAD
# =====================================================================

function Save-SysPilotDownload {
    <# Download mit Fortschritt (Prozent/MB/s/ETA) + Haengererkennung
       und Abbruch-Option - delegiert an Save-SysPilotUrlToFile (Common).
       Nach $env:USERPROFILE\Downloads. #>
    param([Parameter(Mandatory)][string]$Url,
          [Parameter(Mandatory)][string]$OutFile,
          [string]$Label = 'Download')
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    # Invoke-SysPilotFileDownload: WPF-Fortschrittsdialog (STA) oder
    # Konsolen-Fortschritt (MTA) - einheitlich ueberall.
    $ok = Invoke-SysPilotFileDownload -Url $Url -OutFile $OutFile -Label $Label -TimeoutSec 600 -Title $Label
    if ($ok -and (Test-Path $OutFile)) {
        $len = (Get-Item $OutFile).Length
        Write-Host ("  {0}: {1:N1} MB -> {2}" -f $Label, ($len/1MB), $OutFile) -ForegroundColor Green
        return @{ Ok = $true; Path = $OutFile; SizeMB = [math]::Round($len/1MB,1); Error = '' }
    }
    return @{ Ok = $false; Path = $null; SizeMB = 0; Error = 'Download fehlgeschlagen oder abgebrochen' }
}

# =====================================================================
# UI: Hauptmenue
# =====================================================================

function Show-SysPilotUpdateCenter {
    $winget = Get-SysPilotWingetExe
    $choco  = Get-SysPilotChocoExe
    $catN   = (Get-SysPilotUpdateCatalog).Count

    while ($true) {
        Write-Host ""
        Write-Host "  ========================================================" -ForegroundColor Cyan
        Write-Host "           SYSPilot SOFTWARECENTER" -ForegroundColor Cyan
        Write-Host "           winget + Chocolatey + Katalog + GitHub + MajorGeeks" -ForegroundColor Cyan
        Write-Host "  ========================================================" -ForegroundColor Cyan
        Write-Host ("  Quellen: winget={0}  choco={1}  Katalog-Apps={2}" -f
            $(if ($winget) { 'OK' } else { 'FEHLT' }),
            $(if ($choco)  { 'OK' } else { 'FEHLT' }),
            $catN) -ForegroundColor DarkGray
        Write-Host ""

        $items = @(
            @{ Label = 'Installierte Programme auf Updates pruefen (winget + Chocolatey)'; Color = 'Green'; Tag = 'scan' },
            @{ Label = 'Programm-Katalog (Kategorien: Browser, Multimedia, Dev, Tools, KI-Apps, Sicherheit ...)'; Color = 'Cyan'; Tag = 'catalog' },
            @{ Label = 'Fehlgeschlagene Updates (Kontrolle, Retry, manuell, KI-Suche)'; Color = 'Red'; Tag = 'failed' },
            @{ Label = 'Automatische Updates (taeglich silent, geplante Aufgabe)'; Color = 'Yellow'; Tag = 'auto' },
            @{ Label = 'Web-Kataloge / Download-Portale (Ninite auto, Versionen, 17 Portale)'; Color = 'Yellow'; Tag = 'webcat' },
            @{ Label = 'Paketmanager (winget/choco/scoop/npm/pip/dotnet/PSGallery + WSL)' ; Color = 'Cyan'; Tag = 'pkgs' },
            @{ Label = 'Quellen-Status (was ist verfuegbar?)'; Color = 'White'; Tag = 'status' },
            @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = $null }
        )
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'SysPilot Softwarecenter' -Footer 'Pfeiltasten, Enter = auswaehlen, Esc = zurueck'
        if ($null -eq $sel) { return }

        switch ($sel) {
            'scan'    { Show-SysPilotUpdateScan }
            'catalog' { Show-SysPilotCatalogBrowser }
            'auto'    { Show-SysPilotAutoUpdateMenu }
            'failed'  { Show-SysPilotFailedUpdatesWindow }
            'webcat'  { Show-SysPilotWebCatalogs }
            'pkgs'    { if (Get-Command Show-SysPilotPackageManagerMenu -ErrorAction SilentlyContinue) { Show-SysPilotPackageManagerMenu } }
            'status'  { Show-SysPilotUpdateSourcesStatus }
        }
    }
}

function Show-SysPilotUpdateSourcesStatus {
    Write-Host ""
    Write-Host "  UPDATE-QUELLEN" -ForegroundColor Cyan
    Write-Host "  --------------------------------------------------------" -ForegroundColor DarkGray
    $w = Get-SysPilotWingetExe
    Write-Host ("  winget:      {0}" -f $(if ($w) { "$w" } else { 'NICHT VERFUEGBAR' })) -ForegroundColor $(if ($w) {'Green'} else {'Red'})
    if ($w) {
        $v = (& $w --version 2>$null | Select-Object -First 1)
        Write-Host "              Version: $v" -ForegroundColor DarkGray
    }
    $c = Get-SysPilotChocoExe
    Write-Host ("  Chocolatey:  {0}" -f $(if ($c) { "$c" } else { 'nicht installiert' })) -ForegroundColor $(if ($c) {'Green'} else {'DarkGray'})
    Write-Host ("  Katalog:      {0} kuratierte Apps in {1} Kategorien" -f (Get-SysPilotUpdateCatalog).Count, (Get-SysPilotUpdateCatalogCategories).Count) -ForegroundColor Green
    Write-Host "  GitHub:       releases/latest + Direktdownload (API, keine Auth noetig)" -ForegroundColor Green
    Write-Host "  MajorGeeks:   Mirror-Resolver (wie Portable Apps, version+asset verifiziert)" -ForegroundColor Green
    Write-Host "  Web-Kataloge: Portale + Versions-Suche (Ninite auto, MajorGeeks/Uptodown/FOSSHub)" -ForegroundColor Yellow
    Write-Host ""
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
}

function Show-SysPilotWebCatalogs {
    <# Web-Kataloge / Download-Portale: Ninite ganz oben (automatisierbar),
       dann alle Download-Portale, danach Versions-Suche + manuelle Suche. #>
    $portals = @()
    if (Get-Command Get-SysPilotDownloadPortals -ErrorAction SilentlyContinue) {
        try { $portals = @(Get-SysPilotDownloadPortals) } catch { }
    }
    if ($portals.Count -eq 0) {
        $portals = @(
            @{ Id='ninite'; Name='Ninite'; Url='https://ninite.com/'; Auto=$true; Desc='Still-Installation' },
            @{ Id='filehippo'; Name='FileHippo'; Url='https://filehippo.com/'; Auto=$false; Desc='' },
            @{ Id='majorgeeks'; Name='MajorGeeks'; Url='https://www.majorgeeks.com/'; Auto=$true; Desc='' }
        )
    }
    # Ninite garantiert als erstes
    $portals = @($portals | Where-Object { $_.Id -eq 'ninite' }) + @($portals | Where-Object { $_.Id -ne 'ninite' })
    while ($true) {
        $items = foreach ($p in $portals) {
            $auto = if ($p.Auto) { ' [automatisierbar]' } else { '' }
            @{ Label = "$($p.Name)$auto"; Color = 'Cyan'; Tag = "portal:$($p.Id)" }
        }
        $items += @{ Label = 'RSS-Center (Interessengebiete, 1400+ Feeds, OPML-Export, Miniflux-Import)'; Color = 'Green'; Tag = 'rsscenter' }
        $items += @{ Label = 'Versionen in allen Quellen suchen (automatisiert wo moeglich)'; Color = 'Yellow'; Tag = 'versions' }
        $items += @{ Label = 'Manuelle Katalog-Suche (site:-Operatoren, Suchmaschinen)'; Color = 'White'; Tag = 'search' }
        $items += @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = $null }
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'Web-Kataloge / Download-Quellen' -Footer 'Enter = oeffnen/suchen, Esc = zurueck'
        if ($null -eq $sel) { return }
        if ($sel -eq 'versions') {
            $q = Read-SysPilotInput 'Suchbegriff fuer Versions-Check' '7-Zip'
            if ($q) { Show-SysPilotWebSourceVersionsMenu -Query $q }
            continue
        }
        if ($sel -eq 'search') { Show-SysPilotWebCatalogSearch; continue }
        if ($sel -eq 'rsscenter') {
            if (Get-Command Show-SysPilotRssCenter -ErrorAction SilentlyContinue) { Show-SysPilotRssCenter }
            else { Write-Host '  RSS-Center nicht verfuegbar (AiAssist-Modul fehlt).' -ForegroundColor Yellow }
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            continue
        }
        if ($sel -like 'portal:*') {
            $pid2 = $sel.Substring(7)
            $p = @($portals | Where-Object { $_.Id -eq $pid2 })[0]
            if (-not $p) { continue }
            if ($p.Id -eq 'ninite' -and (Get-Command Show-SysPilotNinitePicker -ErrorAction SilentlyContinue)) {
                Show-SysPilotNinitePicker
            } else {
                Write-Host "  Oeffne $($p.Name) ..." -ForegroundColor Cyan
                Start-Process $p.Url
            }
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
        }
    }
}

function Show-SysPilotWebCatalogSearch {
    <# Web-Katalog-Suche: Provider -> site:-Query -> Suchmaschine
       (Ecosia/Brave/Google). Die Query ist auf die Download-Seiten des
       Providers zugeschnitten (site:-Operator), damit die Ergebnisse
       direkt zur Installationsdatei fuehren. #>
    $q = Read-SysPilotInput 'Suchbegriff fuer Web-Kataloge' '7-Zip'
    if (-not $q) { return }

    # site:-Queries pro Provider (Suchmaschinen-Operatoren, deterministisch)
    $providers = @(
        @{ Key='majorgeeks'; Label="MajorGeeks: $q";            Site='site:majorgeeks.com/files/details'; Extra=' download' },
        @{ Key='filehippo';  Label="FileHippo: $q";             Site='site:filehippo.com';                Extra=' download' },
        @{ Key='uptodown';   Label="Uptodown Windows: $q";      Site='site:uptodown.com/windows';         Extra='' },
        @{ Key='chip';       Label="CHIP Download: $q";         Site='site:chip.de/download';             Extra='' },
        @{ Key='heise';      Label="Heise Download (direkt)";   Site=$null;                                Extra=$null },
        @{ Key='winget';     Label="winget-Suche LOKAL: '$q'";  Site=$null;                                Extra=$null },
        @{ Key='all';        Label="Alle Kataloge: $q";         Site='site:majorgeeks.com OR site:filehippo.com OR site:uptodown.com OR site:chip.de OR site:heise.de/download'; Extra=' download' },
        @{ Key='pm';         Label="Paketmanager-Suche: $q (ALLE PMs)"; Site=$null; Extra=$null }
    )
    $sel = Show-SysPilotArrowMenu -Items ($providers | ForEach-Object { @{ Label=$_.Label; Color='Cyan'; Tag=$_.Key } }) -Title 'Web-Katalog-Provider' -Footer 'Enter = auswaehlen, Esc = zurueck'
    if (-not $sel) { return }
    $prov = @($providers | Where-Object { $_.Key -eq $sel })[0]

    if ($sel -eq 'winget') {
        $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
        if ($wt) { Start-Process wt.exe -ArgumentList "winget","search","$q" }
        else     { Start-Process powershell.exe -ArgumentList "-NoExit","-Command","winget search `"$q`"" }
        return
    }
    if ($sel -eq 'heise') {
        Start-Process "https://www.heise.de/download/?suchbegriff=$([Uri]::EscapeDataString($q))"
        return
    }
    if ($sel -eq 'pm') {
        if (Get-Command Show-SysPilotPackageManagerSearch -ErrorAction SilentlyContinue) {
            # Query vorab setzen indem wir die Funktion mit Param aufrufen
            Show-SysPilotPackageManagerSearch -Query $q
        }
        return
    }
    # MajorGeeks: Direkt-URL per Slug erraten und verifizieren
    if ($sel -eq 'majorgeeks') {
        $slug = ($q.ToLower() -replace '[^a-z0-9]+','-').Trim('-')
        $direct = "https://www.majorgeeks.com/files/details/$slug.html"
        try {
            $r = Invoke-WebRequest -Uri $direct -UseBasicParsing -TimeoutSec 12 -Headers @{ 'User-Agent'='Mozilla/5.0' }
            if ($r.StatusCode -eq 200 -and $r.Content -match '<title>([^<]+)</title>' -and $Matches[1] -notmatch 'not found|404') {
                Write-Host "  MajorGeeks-Seite gefunden: $($Matches[1].Trim())" -ForegroundColor Green
                if ((Confirm-SysPilot "MajorGeeks-Seite direkt oeffnen?`n$direct")) { Start-Process $direct; return }
            }
        } catch { }
    }
    # Suchmaschinen-Auswahl
    $eq = [Uri]::EscapeDataString("$q $($prov.Extra) $($prov.Site)")
    $engines = @(
        @{ Label="Ecosia (Baeume pflanzen): $q";  Color='Green';  Tag="https://www.ecosia.org/search?q=$eq" },
        @{ Label="Brave-Suche: $q";               Color='Cyan';   Tag="https://search.brave.com/search?q=$eq" },
        @{ Label="Google-Suche: $q";              Color='Yellow'; Tag="https://www.google.com/search?q=$eq" }
    )
    $eng = Show-SysPilotArrowMenu -Items $engines -Title "Suchmaschine ($($prov.Label))" -Footer 'Enter = oeffnen, Esc = zurueck'
    if ($eng) { Start-Process $eng }
}

# =====================================================================
# WEB-QUELLEN-VERSIONEN: automatisierte Abfrage wo moeglich
# =====================================================================

function Test-SysPilotUrlReachable {
    <# Prueft ob eine URL erreichbar ist (HEAD, Fallback GET).
       Schneller Check ohne Download des Inhalts. #>
    param([Parameter(Mandatory)][string]$Url, [int]$TimeoutSec = 10)
    $ua = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) SysPilot/0.9' }
    try {
        Invoke-WebRequest $Url -Method Head -UseBasicParsing -TimeoutSec $TimeoutSec -MaximumRedirection 5 -Headers $ua -ErrorAction Stop | Out-Null
        return $true
    } catch {
        try {
            Invoke-WebRequest $Url -UseBasicParsing -TimeoutSec $TimeoutSec -MaximumRedirection 5 -Headers $ua -ErrorAction Stop | Out-Null
            return $true
        } catch { return $false }
    }
}

function Get-SysPilotAiPortalHint {
    <# Fragt die kostenlose Web-KI pollinations.ai (kein Login/Key noetig,
       GET-basiert) per Prompt nach aktueller Version + Download-URL.
       BEST-EFFORT: Das freie Modell hat keinen Web-Zugriff und kann
       veraltete Versionen nennen oder Rate-Limits (HTTP 402) werfen.
       Das Ergebnis ist IMMER als 'KI-Angabe' zu labeln, nie als
       verifiziert - $null bei Fehler oder unbrauchbarer Antwort.
       LinkOk: true wenn die gelieferte URL erreichbar ist. #>
    param([Parameter(Mandatory)][string]$Query)
    $q = $Query.Trim()
    if (-not $q) { return $null }
    $prompt = "What is the latest version of $q for Windows? " +
              "Reply ONLY in this format: VERSION: x.y.z | URL: https://official-download-or-product-page"
    $u = 'https://text.pollinations.ai/' + [Uri]::EscapeDataString($prompt)
    try {
        $r = Invoke-WebRequest $u -UseBasicParsing -TimeoutSec 50 `
            -Headers @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36' } `
            -ErrorAction Stop
        $c = $r.Content
    } catch { return $null }
    if (-not $c) { return $null }
    $ver = $null; $url = $null
    if ($c -match '(?i)version[^\d]{0,10}(\d+\.\d+(?:\.\d+)*)') { $ver = $Matches[1] }
    elseif ($c -match '\b(\d{1,2}\.\d+(?:\.\d+)*)\b') { $ver = $Matches[1] }
    if ($c -match '(?i)url[^\d]{0,5}(https?://[^\s"''<>\)\]]+)') { $url = $Matches[1].TrimEnd('.',';',',') }
    elseif ($c -match '(https?://[^\s"''<>\)\]]+)') { $url = $Matches[1].TrimEnd('.',';',',') }
    if (-not $ver -and -not $url) { return $null }
    $linkOk = $null
    if ($url) { $linkOk = Test-SysPilotUrlReachable -Url $url -TimeoutSec 10 }
    return [pscustomobject]@{ Version=$ver; Url=$url; Raw=$c; LinkOk=$linkOk }
}

function Get-SysPilotAiAlternatives {
    <# Fragt die kostenlose Web-KI pollinations.ai nach Forks und
       Alternativen zu einer App. Erwartet strukturierte Ausgabe
       (NAME | Beschreibung | Link); geparst zu Objekten.
       BEST-EFFORT: kein Web-Zugriff, Wissen kann veraltet/unvollstaendig
       sein - IMMER als 'KI-Vorschlag' labeln. Gibt Array zurueck. #>
    param([Parameter(Mandatory)][string]$Query, [int]$Max = 8)
    $q = $Query.Trim()
    if (-not $q) { return @() }
    $prompt = "List up to $Max free open-source apps, forks or alternatives to '$q' for Windows. " +
              "For EACH app output exactly ONE line in this format: " +
              "NAME | short description max 12 words | URL (prefer github.com, else official site, gitlab.com or fosshub.com). " +
              "No numbering, no markdown, no extra text."
    $u = 'https://text.pollinations.ai/' + [Uri]::EscapeDataString($prompt)
    try {
        $r = Invoke-WebRequest $u -UseBasicParsing -TimeoutSec 60 `
            -Headers @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36' } `
            -ErrorAction Stop
        $c = $r.Content
    } catch { return @() }
    if (-not $c) { return @() }
    $items = @()
    foreach ($line in ($c -split "`r?`n")) {
        $line = $line.Trim()
        if ($line.Length -lt 8) { continue }
        $parts = $line -split '\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        if ($parts.Count -lt 2) { continue }
        $name = $parts[0] -replace '^[\*\-\d\.\)\s]+', ''
        if ($name.Length -lt 2 -or $name.Length -gt 60) { continue }
        $desc = if ($parts.Count -ge 2) { $parts[1] } else { '' }
        if ($desc.Length -gt 140) { $desc = $desc.Substring(0,140) }
        $link = $null
        foreach ($p in $parts) {
            if ($p -match '(https?://[^\s"''<>\)\]]+)') { $link = $Matches[1].TrimEnd('.',';',','); break }
        }
        $kind = if ($link -match 'github\.com') { 'github' }
                elseif ($link -match 'gitlab\.com') { 'gitlab' }
                elseif ($link -match 'fosshub\.com') { 'fosshub' }
                elseif ($link) { 'web' } else { '' }
        $items += [pscustomobject]@{ Name=$name; Desc=$desc; Url=$link; Kind=$kind }
        if ($items.Count -ge $Max) { break }
    }
    return $items
}

function Show-SysPilotAiAlternativesMenu {
    <# Listet KI-gefundene Forks/Alternativen mit Mini-Beschreibung und
       Link. Enter = Link oeffnen; zusaetzlich Browser-KI-Suche. #>
    param([Parameter(Mandatory)][string]$Query, [string]$Title = 'KI-Alternativen')
    Write-Host "`n  Frage KI (pollinations.ai) nach Forks/Alternativen: $Query ..." -ForegroundColor Magenta
    $alts = @(Get-SysPilotAiAlternatives -Query $Query)
    if ($alts.Count -eq 0) {
        Write-Host '  Keine verwertbare KI-Antwort (Rate-Limit/Timeout/Format).' -ForegroundColor DarkYellow
        Write-Host '  Tipp: ausfuehrliche Suche mit Browser-KI (Perplexity etc.)' -ForegroundColor DarkGray
        $go = Show-SysPilotArrowMenu -Items @(
            @{ Label = 'Browser-KI-Suche starten (Perplexity/Duck.ai/Gemini/Copilot)'; Color='Cyan'; Tag='engines' },
            @{ Label = 'Zurueck'; Color='DarkGray'; Tag='back' }
        ) -Title 'KI-Alternativen' -Footer 'Enter = Aktion, Esc = zurueck'
        if ($go -eq 'engines') { Start-SysPilotAiSearch -Query "$Query forks alternatives open source download" }
        return
    }
    $items = foreach ($a in $alts) {
        $kindTxt = if ($a.Kind) { "[$($a.Kind)]" } else { '' }
        $descTxt = if ($a.Desc) { " - $($a.Desc.Substring(0,[Math]::Min(70,$a.Desc.Length)))" } else { '' }
        @{ Label = "$($a.Name) $kindTxt$descTxt"; Color = 'White'; Tag = $a }
    }
    $items += @{ Label = 'Browser-KI-Suche fuer ausfuehrlichere Ergebnisse'; Color = 'Cyan'; Tag = '__engines' }
    $items += @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = 'back' }
    $sel = Show-SysPilotArrowMenu -Items $items -Title "$Title (KI-Vorschlaege - bitte pruefen)" -Footer 'Enter = Link oeffnen, Esc = zurueck'
    if ($null -eq $sel -or $sel -eq 'back') { return }
    if ($sel -eq '__engines') { Start-SysPilotAiSearch -Query "$Query forks alternatives open source download"; return }
    if ($sel.Url) {
        Write-Host "  Oeffne $($sel.Kind): $($sel.Url)" -ForegroundColor Cyan
        Start-Process $sel.Url
    } else {
        Write-Host "  Kein Link in der KI-Antwort fuer $($sel.Name)" -ForegroundColor Yellow
    }
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
}

function Get-SysPilotWebSourceVersions {
    <# Fragt Versionen aus Web-Quellen ab. Automatisiert:
       - Ninite-Katalog (schlaegt Titel/Slug)
       - MajorGeeks (Slug-Raten + softwareVersion-Meta, Titel-Verifikation)
       - Uptodown  (Slug-Raten + version-Tag, Titel-Verifikation)
       - FOSSHub   (Name-Dash-Raten + JSON-LD Version, Titel-Verifikation)
       Sonst: manuelle Suchlinks (kein Versions-Parsing moeglich). #>
    param([Parameter(Mandatory)][string]$Query)
    $results = @()
    $q = $Query.Trim()
    if (-not $q) { return @() }
    # Saubere Such-/Slug-Basis: Versionen entfernen, Sonderzeichen -> Leerzeichen.
    # Kurze Tokens (z.B. '7' bei 7-Zip) werden BEHALTEN - sonst wird der Slug
    # zu generisch ('zip' statt '7-zip') und falsche App-Seiten verifiziert.
    $clean = ($q -replace '\d+(\.\d+)+', '') -replace '[^a-zA-Z0-9]+', ' '
    $words = @($clean -split '\s+' | Where-Object { $_.Length -ge 1 } | Select-Object -Unique)
    $phrase = ($words -join ' ').Trim().ToLower()
    if (-not $phrase) { $phrase = $q.ToLower() }
    $slug = ($phrase -replace '\s+', '-')
    $verifyWord = @($words | Where-Object { $_.Length -ge 3 } | Select-Object -First 1)
    if (-not $verifyWord) { $verifyWord = $words[0] }
    $rawSlug = ($q.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
    $slugs = @($slug, ($words -join '-'), $words[0], $rawSlug) |
        Where-Object { $_ -and $_.Length -ge 3 } | Select-Object -Unique
    $ua = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36' }

    # --- 1) Ninite-Katalog (automatischer Treffer moeglich) ---
    if (Get-Command Get-SysPilotNiniteApps -ErrorAction SilentlyContinue) {
        try {
            $na = @(Get-SysPilotNiniteApps)
            # Needles: Phrase + kompakt ("7 zip"->"7zip") + lange Suchbegriffe.">
            # Kurze Begriffe (3 Zeichen, z.B. 'zip') nur mit Wortgrenze -
            # sonst false positive (peazip statt 7zip).
            $longNeedles = @($phrase, ($phrase -replace '\s+', '')) +
                @(Get-SysPilotSearchTerms -Query $q | Where-Object { $_.Length -ge 4 } | ForEach-Object { $_.ToLower() })
            $shortNeedles = @(Get-SysPilotSearchTerms -Query $q | Where-Object { $_.Length -eq 3 } | ForEach-Object { $_.ToLower() })
            # Erstes Query-Wort als Kurz-needle (z.B. 'vlc' -> Slug 'vlc' im Ninite-Katalog)
            if ($words.Count -gt 0 -and $words[0].Length -ge 3) {
                $shortNeedles = @($shortNeedles + $words[0].ToLower() | Select-Object -Unique)
            }
            $hit = @($na | Where-Object {
                $hay  = ("$($_.Title) $($_.Slug)" -replace '[^a-zA-Z0-9]+', ' ').ToLower()
                $hayC = ($hay -replace '\s+', '')
                $ok = @($longNeedles | Where-Object {
                    $n = $_.ToLower()
                    ($n.Length -ge 3) -and ($hay.Contains($n) -or $hayC.Contains(($n -replace '\s+', '')))
                }).Count -gt 0
                if (-not $ok -and $shortNeedles.Count -gt 0) {
                    $ok = @($shortNeedles | Where-Object {
                        [regex]::IsMatch($hay, "\b$([regex]::Escape($_))\b")
                    }).Count -gt 0
                }
                $ok
            } | Select-Object -First 3)
            foreach ($h in $hit) {
                $results += [pscustomobject]@{ Source='Ninite'; Version=$h.Version; Url='https://ninite.com/'; Auto=$true; Note="still installierbar ($($h.Slug))"; Best=$false }
            }
        } catch { }
    }

    # --- 2) Slug-basierte Quellen (MajorGeeks / Uptodown / FOSSHub) ---
    $mgDone = $false; $udDone = $false; $fsDone = $false
    foreach ($s in $(if ($verifyWord) { $slugs } else { @() })) {
        if ($mgDone -and $udDone -and $fsDone) { break }
        # MajorGeeks: /files/details/<slug>.html, Version in softwareVersion-Meta
        if (-not $mgDone) {
            try {
                $u = "https://www.majorgeeks.com/files/details/$s.html"
                $r = Invoke-WebRequest $u -UseBasicParsing -TimeoutSec 12 -Headers $ua -ErrorAction Stop
                if ($r.Content -match '<title>([^<]+)' -and $Matches[1] -match [regex]::Escape($verifyWord)) {
                    $v = $null
                    if ($r.Content -match 'itemprop="softwareVersion"\s+content="([\d.]+)"') { $v = $Matches[1] }
                    $results += [pscustomobject]@{ Source='MajorGeeks'; Version=$v; Url=$u; Auto=$true; Note='Mirror-Download'; Best=$false }
                    $mgDone = $true
                }
            } catch { }
        }
        # Uptodown: <slug>.en.uptodown.com/windows, version">X (erste = neueste)
        if (-not $udDone) {
            try {
                $u = "https://$s.en.uptodown.com/windows"
                $r = Invoke-WebRequest $u -UseBasicParsing -TimeoutSec 12 -Headers $ua -ErrorAction Stop
                if ($r.Content -match '<title>([^<]+)' -and $Matches[1] -match [regex]::Escape($verifyWord)) {
                    $v = $null
                    if ($r.Content -match 'version">\s*([\d]+\.[\d.]+)') { $v = $Matches[1] }
                    $results += [pscustomobject]@{ Source='Uptodown'; Version=$v; Url=$u; Auto=$true; Note='direkter Download'; Best=$false }
                    $udDone = $true
                }
            } catch { }
        }
        # FOSSHub: /<Name-mit-Bindestrichen>.html, "Version": "X" im JSON-LD.
        # Verifikation ueber JSON-LD "name" - die Seite hat dutzende SVG-<title>.
        if (-not $fsDone -and $verifyWord) {
            foreach ($fsSlug in @("$($q -replace '\s+','-')", "$s")) {
                try {
                    $u = "https://www.fosshub.com/$fsSlug.html"
                    $r = Invoke-WebRequest $u -UseBasicParsing -TimeoutSec 12 -Headers $ua -ErrorAction Stop
                    if ($r.Content -match '"name"\s*:\s*"[^"]*' + [regex]::Escape($verifyWord)) {
                        $v = $null
                        if ($r.Content -match '"softwareVersion"\s*:\s*"([\d.]+)"') { $v = $Matches[1] }
                        elseif ($r.Content -match '"Version"\s*:\s*"([\d.]+)"') { $v = $Matches[1] }
                        $results += [pscustomobject]@{ Source='FOSSHub'; Version=$v; Url=$u; Auto=$true; Note='Open-Source-only'; Best=$false }
                        $fsDone = $true
                        break
                    }
                } catch { }
            }
        }
    }

    # --- 3) Manuelle Quellen (kein automatisches Versions-Parsing) ---
    $enc  = [Uri]::EscapeDataString($q)
    $encS = [Uri]::EscapeDataString(($phrase -replace ' ', '-'))
    $manual = @(
        @{ Source='FileHippo';    Url="https://filehippo.com/search?q=$enc&os=windows";                          Note='Bot-Schutz - im Browser' },
        @{ Source='Heise';        Url="https://www.heise.de/download/?suchbegriff=$enc";                        Note='' },
        @{ Source='CHIP';         Url='https://www.chip.de/download/';                                           Note='Suche auf Seite' },
        @{ Source='ComputerBild'; Url='https://www.computerbild.de/downloads/';                                  Note='Suche auf Seite' },
        @{ Source='ComputerBase'; Url='https://www.computerbase.de/downloads/';                                  Note='Suche auf Seite' },
        @{ Source='WinFuture';    Url='https://winfuture.de/';                                                   Note='Suche auf Seite' },
        @{ Source='Deskmodder';   Url="https://www.deskmodder.de/?s=$enc";                                       Note='' },
        @{ Source='Softonic';     Url="https://de.softonic.com/s/$encS";                                         Note='Adblock empfohlen' },
        @{ Source='Softpedia';    Url="https://www.softpedia.com/dyn-search.php?search_term=$enc";               Note='' },
        @{ Source='AlternativeTo';Url="https://alternativeto.net/browse/search/?q=$enc";                        Note='' },
        @{ Source='Ghacks';       Url="https://www.ghacks.net/?s=$enc";                                         Note='' },
        @{ Source='PortableApps'; Url='https://www.portableapps.com/';                                           Note='App-Suche auf Seite' },
        @{ Source='GIGAZONE';     Url='https://giga.de/';                                                        Note='Cloud, keine Programme' }
    )
    foreach ($m in $manual) {
        $results += [pscustomobject]@{ Source=$m.Source; Version=$null; Url=$m.Url; Auto=$false; Note=$m.Note; Best=$false }
    }
    return @($results)
}

function Show-SysPilotWebSourceVersionsMenu {
    <# Zeigt alle gefundenen Quellen mit Versionen sortiert (neueste oben)
       und hebt die beste Version hervor. Enter = Seite oeffnen.
       -IncludeAi: zusaetzlich Pollinations-KI abfragen (KI-Angabe,
       unverifiziert - das freie Modell hat keinen Web-Zugriff). #>
    param([Parameter(Mandatory)][string]$Query, [switch]$IncludeAi)
    Write-Host "`n  Frage Web-Quellen ab: $Query ..." -ForegroundColor Cyan
    $rows = @(Get-SysPilotWebSourceVersions -Query $Query)
    if ($IncludeAi) {
        Write-Host "  Frage KI (pollinations.ai) ..." -ForegroundColor Magenta
        $ai = Get-SysPilotAiPortalHint -Query $Query
        if ($ai) {
            $aiUrl = if ($ai.Url) { $ai.Url }
                     else { 'https://duckduckgo.com/?q=' + [Uri]::EscapeDataString("$Query latest version download") + '&ia=chat' }
            $linkNote = if ($null -ne $ai.LinkOk) { $(if ($ai.LinkOk) { ' - Link erreichbar' } else { ' - Link NICHT erreichbar' }) } else { '' }
            $rows += [pscustomobject]@{ Source='KI (Pollin.)'; Version=$ai.Version; Url=$aiUrl; Auto=$false; Note="KI-Angabe - bitte pruefen$linkNote"; Best=$false }
        } else {
            Write-Host '  KI lieferte keine verwertbare Antwort (Rate-Limit/Timeout).' -ForegroundColor DarkYellow
        }
    }
    if ($rows.Count -eq 0) {
        Write-Host '  Keine Quellen gefunden.' -ForegroundColor Yellow
        Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
        return
    }
    # Sortierung: Version desc (parsbar), dann Auto, dann manuell
    $withV = @($rows | Where-Object { $_.Version } | Sort-Object @{e={ ConvertTo-SysPilotVerObj $_.Version }}, @{e={$_.Source}} -Descending)
    $noV   = @($rows | Where-Object { -not $_.Version })
    $sorted = @($withV) + @($noV)
    # Beste Version markieren
    $best = $null
    foreach ($r in $sorted) {
        if ($r.Version) {
            $v = ConvertTo-SysPilotVerObj $r.Version
            if ($v -and (-not $best -or $v -gt (ConvertTo-SysPilotVerObj $best.Version))) { $best = $r }
        }
    }
    if ($best) { Write-Host "  Neueste Version gefunden: $($best.Version) ($($best.Source))" -ForegroundColor Green }
    $items = @(@{ Label = 'KI-Version + Download-Link abfragen (pollinations.ai)'; Color = 'Magenta'; Tag = '__ai' }) +
        @(foreach ($r in $sorted) {
        $isBest = ($best -and $r.Source -eq $best.Source -and $r.Version -eq $best.Version -and $r.Url -eq $best.Url)
        $verTxt = if ($r.Version) { $r.Version } else { 'manuell' }
        $note   = if ($r.Note) { " - $($r.Note)" } else { '' }
        $auto   = if ($r.Auto) { ' [auto]' } else { '' }
        $bestT  = if ($isBest) { '  <- NEUESTE' } else { '' }
        $label  = ("{0,-10} {1,-14} {2}{3}{4}" -f $verTxt, $r.Source, $note, $auto, $bestT)
        @{ Label = $label; Color = $(if ($isBest) { 'Green' } elseif ($r.Auto) { 'Cyan' } else { 'DarkGray' }); Tag = $r }
    })
    $items += @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = $null }
    $sel = Show-SysPilotArrowMenu -Items $items -Title "Web-Quellen: $Query" -Footer 'Enter = Seite oeffnen, Esc = zurueck'
    if ($sel -is [string] -and $sel -eq '__ai') {
        Show-SysPilotWebSourceVersionsMenu -Query $Query -IncludeAi
        return
    }
    if ($sel) {
        Write-Host "  Oeffne $($sel.Source): $($sel.Url)" -ForegroundColor Cyan
        Start-Process $sel.Url
    }
}

# =====================================================================
# UPDATE-SCAN: installierte Programme
# =====================================================================

function Show-SysPilotUpdateScan {
    $winget = Get-SysPilotWingetExe
    $choco  = Get-SysPilotChocoExe
    if (-not $winget -and -not $choco) {
        Write-Host "  [!] Weder winget noch Chocolatey verfuegbar - kein Scan moeglich." -ForegroundColor Red
        Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
        return
    }

    Write-Host ""
    Write-Host "  Scanne installierte Programme ..." -ForegroundColor Cyan
    Write-Host "  (winget kann beim ersten Mal eine Weile brauchen)" -ForegroundColor DarkGray
    $rows = @()
    if ($winget) {
        Write-Host "  - winget upgrade ..." -ForegroundColor DarkGray
        $rows += Get-SysPilotWingetUpgrades
    }
    if ($choco) {
        Write-Host "  - choco outdated ..." -ForegroundColor DarkGray
        $rows += Get-SysPilotChocoOutdated
    }
    # Weitere Paketmanager (scoop/npm/pip/dotnet/PSGallery)
    if (Get-Command Get-SysPilotPmOutdated -ErrorAction SilentlyContinue) {
        Write-Host "  - Paketmanager (scoop/npm/pip/dotnet/PSGallery) ..." -ForegroundColor DarkGray
        $rows += @(Get-SysPilotPmOutdated)
    }

    if ($rows.Count -eq 0) {
        Write-Host "  [OK] Keine Updates gefunden (oder Quellen leer)." -ForegroundColor Green
        Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
        return
    }

    # Duplikate: gleiche ID aus winget+choco bevorzugt winget
    $seen = @{}
    $uniq = @()
    foreach ($r in $rows) {
        $k = $r.Id.ToLower()
        if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $uniq += $r }
    }

    $items = foreach ($r in $uniq) {
        $avail = $r.Available
        @{ Label = ("{0}  |  {1} -> {2}  [{3}]" -f $r.Name, $r.Installed, $avail, $r.Source); Color = 'White'; Tag = $r }
    }

    $res = Show-SysPilotMultiSelectMenu -Items $items -Actions @(
        @{ Label = 'Ausgewaehlte aktualisieren'; Tag = 'update'; Color = 'Green' },
        @{ Label = 'Alle still aktualisieren'; Tag = 'autoall'; Color = 'Yellow' },
        @{ Label = 'Abbrechen';                Tag = 'back';  Color = 'DarkGray' }
    ) -Title 'Verfuegbare Updates' -Footer 'Leertaste = markieren, Enter = Aktion waehlen'

    if (-not $res -or $res.Action -eq 'back' -or $null -eq $res.Action) { return }
    if ($res.Action -eq 'autoall') {
        if (-not (Confirm-SysPilot "Alle $($uniq.Count) Updates JETZT still installieren?")) { return }
        Invoke-SysPilotAutoUpdate | Out-Null
        return
    }
    if ($res.Selected.Count -eq 0) { return }

    $admin = Test-SysPilotAdmin
    if (-not $admin) {
        Write-Host "  [!] Nicht-Admin: machine-scope Installer koennen fehlschlagen." -ForegroundColor Yellow
    }
    $mode = Show-SysPilotArrowMenu -Items @(
        @{ Label = 'Silent versuchen (--silent, UAC selbststaendig)'; Color = 'Green';  Tag = 'silent' },
        @{ Label = 'Interaktiv (winget zeigt Installer-UI)';        Color = 'Yellow'; Tag = 'normal' },
        @{ Label = 'Abbrechen';                                       Color = 'DarkGray'; Tag = 'back' }
    ) -Title 'Update-Modus' -Footer 'Enter = waehlen, Esc = abbruch'
    if (-not $mode -or $mode -eq 'back') { return }

    $okN = 0; $failN = 0
    foreach ($row in $res.Selected) {
        Write-Host ""
        Write-Host "  -> $($row.Name) ($($row.Id)): $($row.Installed) -> $($row.Available)" -ForegroundColor Cyan
        if ($row.Source -eq 'chocolatey' -and $choco) {
            $cr = Invoke-SysPilotChocoUpgradeAuto -Pkg $row.Id
            if ($cr.Ok) { $okN++; Remove-SysPilotFailedUpdate -Id $row.Id }
            else { $failN++; Add-SysPilotFailedUpdate -Row $row -Error $cr.Error; Write-Host ("     FEHLER: {0}" -f $cr.Error) -ForegroundColor Red }
            continue
        }
        if ([string]$row.Source -like 'pm:*') {
            Write-Host "     PM-Update via $($row.Source) ..." -ForegroundColor DarkGray
            $pr = Invoke-SysPilotPmUpgrade -Row $row
            if ($pr.Ok) { Write-Host ("     OK ({0:N0}s)" -f ($pr.Ms/1000)) -ForegroundColor Green; $okN++; Remove-SysPilotFailedUpdate -Id $row.Id }
            else { Write-Host ("     FEHLER: {0}" -f $pr.Error) -ForegroundColor Red; $failN++; Add-SysPilotFailedUpdate -Row $row -Error $pr.Error }
            continue
        }
        if ($winget) {
            $args = @('upgrade','--id',$row.Id,'--exact','--accept-package-agreements','--accept-source-agreements')
            if ($mode -eq 'silent') { $args += '--silent'; $args += '--disable-interactivity' }
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $kind = ''
            Write-Host "     laeuft... (kann bei grossen Downloads Minuten dauern)" -ForegroundColor DarkGray
            if ($mode -eq 'silent') {
                $r = Invoke-SysPilotWingetUpdateAuto -Row $row -Silent -TimeoutSec 900 -AllowElevated
                $okU = $r.Ok; $errTxt = $r.Error; $tailTxt = $r.Text; $kind = $r.Kind
                if ($r.Elevated) { $errTxt = "elevated: $errTxt" }
                if ($r.Ok -and $r.Via) { Write-Host "     Update via $($r.Via) (winget-Fallback)" -ForegroundColor Green }
            } else {
                # interaktiv: winget direkt ausfuehren -> eigener Fortschritt sichtbar
                $wexe = Get-SysPilotWingetExe
                & $wexe @args 2>&1 | Out-Host
                $okU = ($LASTEXITCODE -eq 0); $errTxt = ''; $tailTxt = ''
                # winget interaktiv fehlgeschlagen -> Cross-Manager-Fallback
                if (-not $okU) {
                    Write-Host "     winget fehlgeschlagen - versuche Chocolatey/Scoop-Fallback ..." -ForegroundColor DarkGray
                    $alt = Invoke-SysPilotAltManagerUpgrade -Row $row
                    if ($alt -and $alt.Ok) { $okU = $true; Write-Host "     Fallback OK via $($alt.Via)" -ForegroundColor Green }
                    elseif ($alt) { $errTxt = "fallback: $($alt.Error)" }
                }
            }
            $sw.Stop()
            if ($okU) {
                Write-Host ("     OK ({0:N0}s)" -f $sw.Elapsed.TotalSeconds) -ForegroundColor Green
                $okN++; Remove-SysPilotFailedUpdate -Id $row.Id
            } else {
                Write-Host ("     FEHLER ({0:N0}s): {1}" -f $sw.Elapsed.TotalSeconds, $errTxt) -ForegroundColor Red
                if ($tailTxt) { Write-Host ($tailTxt.Substring([Math]::Max(0,$tailTxt.Length-500))) -ForegroundColor DarkGray }
                $failN++; Add-SysPilotFailedUpdate -Row $row -Error $errTxt -Kind $kind
            }
            Write-SysPilotLog ("UpdateScan {0}: {1} in {2:N0}s" -f $(if($okU){'OK'}else{'FAIL'}), $row.Name, $sw.Elapsed.TotalSeconds)
        }
    }
    Write-Host ""
    Write-Host ("  Fertig: {0} ok, {1} Fehler." -f $okN, $failN) -ForegroundColor $(if ($failN -eq 0) {'Green'} else {'Yellow'})
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
}

# =====================================================================
# KATALOG-BROWSER
# =====================================================================

function Show-SysPilotCatalogBrowser {
    $cats = Get-SysPilotUpdateCatalogCategories
    $items = foreach ($c in $cats) {
        $n = @((Get-SysPilotUpdateCatalog) | Where-Object { $_.Cat -eq $c }).Count
        @{ Label = ("{0}  ({1} Apps)" -f $c, $n); Color = 'Cyan'; Tag = $c }
    }
    $items += @{ Label = 'Alle Apps (flate Liste)'; Color = 'White'; Tag = '*' }
    $items += @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = $null }

    $cat = Show-SysPilotArrowMenu -Items $items -Title 'Katalog-Kategorien' -Footer 'Enter = Kategorie oeffnen, Esc = zurueck'
    if ($null -eq $cat) { return }

    $apps = if ($cat -eq '*') { Get-SysPilotUpdateCatalog } else { @(Get-SysPilotUpdateCatalog | Where-Object { $_.Cat -eq $cat }) }
    $apps = $apps | Sort-Object Name

    $items = foreach ($a in $apps) {
        $inst = Find-SysPilotCatalogInstalled -App $a
        $src = @()
        if ($a.WingetId) { $src += $(if ($a.WingetSource) { "winget/$($a.WingetSource)" } else { 'winget' }) }
        if ($a.Gh)       { $src += 'github' }
        if ($a.Mg)       { $src += 'majorgeeks' }
        if ($a.Page)     { $src += 'web' }
        $instTxt = if ($inst) { "  [installiert: $($inst.Version)]" } else { '' }
        $descTxt = if ($a.Desc) { "  |  $($a.Desc.Substring(0,[Math]::Min(60,$a.Desc.Length)))" } else { '' }
        @{ Label = ("{0}  [{1}]{2}{3}" -f $a.Name, ($src -join '+'), $instTxt, $descTxt); Color = 'White'; Tag = $a }
    }
    $items += @{ Label = 'Zurueck zu Kategorien'; Color = 'DarkGray'; Tag = '__back' }

    $sel = Show-SysPilotArrowMenu -Items $items -Title "Katalog: $cat" -Footer 'Enter = Details/Aktionen, Esc = zurueck'
    if ($null -eq $sel -or $sel -eq '__back') { return }
    Show-SysPilotCatalogAppDetail -App $sel
}

function Show-SysPilotCatalogAppDetail {
    param([Parameter(Mandatory)][hashtable]$App)
    while ($true) {
        $inst = Find-SysPilotCatalogInstalled -App $App
        Write-Host ""
        Write-Host "  --------------------------------------------------------" -ForegroundColor DarkGray
        Write-Host "  $($App.Name)" -ForegroundColor Cyan
        if ($App.Desc) { Write-Host "  $($App.Desc)" -ForegroundColor DarkCyan }
        Write-Host "  Kategorie: $($App.Cat)" -ForegroundColor DarkGray
        if ($App.WingetId) { Write-Host "  winget-ID: $($App.WingetId)" -ForegroundColor DarkGray }
        if ($App.Gh)       { Write-Host "  GitHub:    $($App.Gh)" -ForegroundColor DarkGray }
        if ($App.NpmPkg)   { Write-Host "  npm:       $($App.NpmPkg)" -ForegroundColor DarkGray }
        if ($App.PipPkg)   { Write-Host "  pip:       $($App.PipPkg)" -ForegroundColor DarkGray }
        if ($App.WingetSource -eq 'msstore') {
            Write-Host "  winget-Quelle: msstore (MSIX)" -ForegroundColor Yellow
            Write-Host "  ! Store-Apps laufen NIEMALS als Administrator." -ForegroundColor Yellow
            Write-Host "  ! Falls eine offizielle Win32-Version oder ein Fork existiert," -ForegroundColor Yellow
            Write-Host "    diese bevorzugen (KI-Suche unter Softwarecenter > Web-Quellen)." -ForegroundColor Yellow
        }
        if ($App.Note)     { Write-Host "  Hinweis:   $($App.Note)" -ForegroundColor DarkYellow }
        if ($inst)         { Write-Host "  Installiert: $($inst.Version)" -ForegroundColor Green }
        else               { Write-Host "  Installiert: nein" -ForegroundColor DarkGray }
        Write-Host "  --------------------------------------------------------" -ForegroundColor DarkGray

        $acts = @()
        if ($App.WingetId) { $acts += @{ Label = 'winget: installieren / aktualisieren'; Color = 'Green';  Tag = 'winget' } }
        if ($App.Gh)       { $acts += @{ Label = 'GitHub: neueste Version + Download'; Color = 'Cyan';   Tag = 'github' } }
        if ($App.NpmPkg)   { $acts += @{ Label = "npm: $($App.NpmPkg) installieren"; Color = 'Green'; Tag = 'npm' } }
        if ($App.PipPkg)   { $acts += @{ Label = "pip: $($App.PipPkg) installieren"; Color = 'Green'; Tag = 'pip' } }
        # KI-Suche ist fuer JEDE App sinnvoll: Forks/Alternativen finden
        # (msstore: Win32-Alternative; sonst: KI-Download-Link + Alternativen)
        if ($App.WingetSource -eq 'msstore') { $acts += @{ Label = 'KI-Suche: offizielle Win32-Version/Fork suchen'; Color = 'Magenta'; Tag = 'aisearch' } }
        else { $acts += @{ Label = 'KI-Suche: Download-Link + Forks/Alternativen'; Color = 'Magenta'; Tag = 'aisearch' } }
        if ($App.Mg)       { $acts += @{ Label = 'MajorGeeks: Version + Mirror-Download'; Color = 'Yellow'; Tag = 'mg' } }
        if ($App.Setup)    { $acts += @{ Label = "Einrichten: $($App.SetupLabel)"; Color = 'Green'; Tag = 'setup' } }
        if ($App.Page)     { $acts += @{ Label = 'Offizielle Seite oeffnen'; Color = 'White'; Tag = 'page' } }
        $acts += @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = 'back' }

        $a = Show-SysPilotArrowMenu -Items $acts -Title $App.Name -Footer 'Enter = Aktion, Esc = zurueck'
        if ($null -eq $a -or $a -eq 'back') { return }

        switch ($a) {
            'winget' { Invoke-SysPilotCatalogWinget -App $App }
            'github' { Invoke-SysPilotCatalogGithub -App $App }
            'npm'    { Invoke-SysPilotCatalogNpm -App $App }
            'pip'    { Invoke-SysPilotCatalogPip -App $App }
            'aisearch' {
                if ($App.WingetSource -eq 'msstore') {
                    # Store-App: erst KI-Fork-Suche (pollinations), dann Browser-KI
                    Show-SysPilotAiAlternativesMenu -Query "$($App.Name)" -Title "Win32-Alternative zu $($App.Name)"
                } else {
                    # Normale App: Alternativen-Liste + Browser-KI mit Download-Link-Suche
                    Show-SysPilotAiAlternativesMenu -Query "$($App.Name)" -Title "Forks/Alternativen zu $($App.Name)"
                    Write-Host ''
                    Write-Host "  Ausfuehrliche Download-Link-Suche:" -ForegroundColor Cyan
                    Start-SysPilotAiSearch -Query "$($App.Name) official download site latest version windows"
                }
            }
            'mg'     { Invoke-SysPilotCatalogMajorGeeks -App $App }
            'setup'  {
                # Generischer Einrichtungs-Hook: Setup-Key waehlt den
                # passenden Router-Assistenten (je App ein eigener Flow)
                $done = $false
                if (Get-Command Show-SysPilotOmniRouteSetup -ErrorAction SilentlyContinue) {
                    switch ([string]$App.Setup) {
                        'omniroute'  { Show-SysPilotOmniRouteSetup;  $done = $true }
                        'freellmapi' { Show-SysPilotFreeLlmApiSetup; $done = $true }
                        'freelm'     { Show-SysPilotFreelmSetup;    $done = $true }
                        '9router'    { Show-SysPilotNineRouterSetup; $done = $true }
                        'routersync' { Show-SysPilotRouterSyncMenu;  $done = $true }
                    }
                }
                if (-not $done) {
                    Write-Host "  [!] Kein Einrichtungs-Assistent fuer $($App.Name) definiert." -ForegroundColor Yellow
                    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
                }
            }
            'page'   { Start-Process $App.Page }
        }
    }
}

function Invoke-SysPilotCatalogWinget {
    param([hashtable]$App)
    $winget = Get-SysPilotWingetExe
    if (-not $winget) { Write-Host "  [!] winget nicht verfuegbar" -ForegroundColor Red; Read-SysPilotChoice 'Weiter' | Out-Null; return }
    $inst = Find-SysPilotCatalogInstalled -App $App
    $isUpgrade = $inst -and ($inst.Version -notmatch 'unbekannt|^$')
    if ($App.WingetSource -eq 'msstore') {
        Write-Host "`n  ! MSIX/Store-Installation: die App laeuft nicht als Administrator." -ForegroundColor Yellow
        Write-Host "  ! Empfehlung: offizielle Win32-Version oder Fork bevorzugen, falls vorhanden." -ForegroundColor Yellow
        if (-not (Confirm-SysPilot "Trotzdem ueber den Microsoft Store installieren?")) { Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; return }
    }
    Write-Host ""
    Write-Host "  winget $(if ($isUpgrade) {'upgrade'} else {'install'}) $($App.WingetId) ..." -ForegroundColor Cyan
    $args = @($(if ($isUpgrade) {'upgrade'} else {'install'}), '--id', $App.WingetId, '--exact',
              '--accept-package-agreements','--accept-source-agreements','--disable-interactivity')
    if ($App.WingetSource) { $args += @('--source', $App.WingetSource) }
    $r = Invoke-SysPilotWingetRaw -ArgList $args -TimeoutSec 900
    if ($r.Ok) {
        Write-Host "  [OK] $($App.Name) $(if ($isUpgrade) {'aktualisiert'} else {'installiert'})" -ForegroundColor Green
    } else {
        Write-Host "  [!] Fehlgeschlagen: $($r.Error)" -ForegroundColor Red
        if ($r.Text) { Write-Host ($r.Text.Substring([Math]::Max(0,$r.Text.Length-600))) -ForegroundColor DarkGray }
        if (-not (Test-SysPilotAdmin)) { Write-Host "  Tipp: SysPilot als Administrator starten." -ForegroundColor Yellow }
        # winget kann nicht -> andere Paketmanager versuchen (choco/scoop)
        Write-Host "`n  winget-download nicht moeglich - suche Chocolatey/Scoop ..." -ForegroundColor Cyan
        [void](Show-SysPilotAltManagerInstallMenu -Query "$($App.Name) $($App.WingetId)" -Title "Alt-Manager: $($App.Name)")
    }
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
}

function Invoke-SysPilotCatalogNpm {
    <# npm install -g fuer Katalog-Apps mit NpmPkg (opencode, freelm,
       omniroute, gemini-cli, MCP-Inspector). #>
    param([hashtable]$App)
    $pkg = [string]$App.NpmPkg
    if (-not $pkg) { return }
    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
        Write-Host "  [!] npm nicht gefunden (Node.js noetig)" -ForegroundColor Red
        Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; return
    }
    Write-Host "`n  npm install -g $pkg ..." -ForegroundColor Cyan
    $npmExe = (Get-Command npm.cmd -ErrorAction SilentlyContinue).Source
    if (-not $npmExe) { $npmExe = (Get-Command npm -ErrorAction SilentlyContinue).Source }
    $nr = Invoke-SysPilotMonitoredProcess -FilePath $npmExe -ArgList @('install','-g',"$pkg@latest") -Label "npm install $pkg" -TimeoutSec 600
    $out = [string]$nr.Output
    if ($nr.ExitCode -eq 0) {
        Write-Host "  [OK] $pkg installiert" -ForegroundColor Green
        Write-SysPilotLog "npm install -g $pkg OK (catalog)"
        if ($pkg -match '(?i)omniroute|9router|freelm') {
            Write-Host "  Tipp: danach 'Einrichten: Router-Sync' in dieser Detailansicht -" -ForegroundColor Cyan
            Write-Host "        SysPilot-Provider werden automatisch in den Router uebernommen." -ForegroundColor Cyan
        }
    } else {
        Write-Host "  [!] npm fehlgeschlagen:" -ForegroundColor Red
        Write-Host ($out.Substring([Math]::Max(0,$out.Length-400))) -ForegroundColor DarkGray
    }
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
}

function Invoke-SysPilotCatalogPip {
    <# pip install fuer Katalog-Apps mit PipPkg (freelm). Bevorzugt
       'python -m pip' (pip.exe kann sich nicht selbst updaten). #>
    param([hashtable]$App)
    $pkg = [string]$App.PipPkg
    if (-not $pkg) { return }
    $py = $null
    if (Get-Command Get-SysPilotPythonExeForPip -ErrorAction SilentlyContinue) { $py = Get-SysPilotPythonExeForPip }
    if (-not $py) { $py = (Get-Command python.exe -ErrorAction SilentlyContinue).Source }
    if (-not $py) { Write-Host "  [!] Kein python.exe gefunden" -ForegroundColor Red; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; return }
    Write-Host "`n  $py -m pip install $pkg ..." -ForegroundColor Cyan
    $pr = Invoke-SysPilotMonitoredProcess -FilePath $py -ArgList @('-m','pip','install',$pkg) -Label "pip install $pkg" -TimeoutSec 600
    $out = [string]$pr.Output
    if ($pr.ExitCode -eq 0) {
        Write-Host "  [OK] $pkg installiert" -ForegroundColor Green
        Write-SysPilotLog "pip install $pkg OK (catalog)"
        if ($pkg -match '(?i)freelm') {
            Write-Host "  Tipp: danach 'Einrichten: Router-Sync' in dieser Detailansicht -" -ForegroundColor Cyan
            Write-Host "        SysPilot-Provider werden als FREELM_*-Env-Vars uebernommen." -ForegroundColor Cyan
        }
    } else {
        Write-Host "  [!] pip fehlgeschlagen:" -ForegroundColor Red
        Write-Host ($out.Substring([Math]::Max(0,$out.Length-400))) -ForegroundColor DarkGray
    }
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
}

function Invoke-SysPilotCatalogGithub {
    param([hashtable]$App)
    Write-Host ""
    Write-Host "  GitHub-Release abfragen: $($App.Gh) ..." -ForegroundColor Cyan
    $rel = Get-SysPilotGithubLatest -Repo $App.Gh
    if (-not $rel.Ok) {
        Write-Host "  [!] GitHub-API: $($rel.Error)" -ForegroundColor Red
        if ($App.Page) { if (Confirm-SysPilot "Stattdessen offizielle Seite oeffnen?") { Start-Process $App.Page } }
        Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; return
    }

    $inst = Find-SysPilotCatalogInstalled -App $App
    Write-Host "  Neueste Version: $($rel.Version)  (Tag: $($rel.Tag))" -ForegroundColor Green
    if ($inst -and $inst.Version) {
        $a = ConvertTo-SysPilotVerObj $inst.Version; $b = ConvertTo-SysPilotVerObj $rel.Version
        if ($a -and $b) {
            if ($b -gt $a) { Write-Host "  Installiert: $($inst.Version) -> UPDATE veruegbar" -ForegroundColor Yellow }
            else          { Write-Host "  Installiert: $($inst.Version) -> aktuell" -ForegroundColor Green }
        }
    }

    $asset = Select-SysPilotGithubAsset -Assets $rel.Assets
    if (-not $asset) {
        Write-Host "  Keine Windows-Assets im Release ($($rel.Assets.Count) Dateien)" -ForegroundColor Yellow
        Write-Host "  Release-Seite: https://github.com/$($App.Gh)/releases/latest" -ForegroundColor DarkGray
        Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; return
    }

    $sizeMB = [math]::Round($asset.size/1MB,1)
    $acts = @(
        @{ Label = "Herunterladen: $($asset.name) ($sizeMB MB)"; Color = 'Green'; Tag = 'dl' },
        @{ Label = 'Release-Seite im Browser oeffnen';           Color = 'White'; Tag = 'page' },
        @{ Label = 'Zurueck';                                     Color = 'DarkGray'; Tag = 'back' }
    )
    $a = Show-SysPilotArrowMenu -Items $acts -Title "$($App.Name) $($rel.Version)" -Footer 'Enter = Aktion, Esc = zurueck'
    if ($null -eq $a -or $a -eq 'back') { return }

    if ($a -eq 'page') { Start-Process "https://github.com/$($App.Gh)/releases/latest"; Read-SysPilotChoice 'Weiter' | Out-Null; return }

    $dlDir = Join-Path $env:USERPROFILE 'Downloads'
    $out = Join-Path $dlDir $asset.name
    if (Test-Path $out) { $out = Join-Path $dlDir ("{0}-{1}" -f [IO.Path]::GetFileNameWithoutExtension($asset.name), (Get-Date -Format 'yyyyMMdd-HHmmss')) + [IO.Path]::GetExtension($asset.name) }
    if (-not (Confirm-SysPilot "Download nach`n$out`n($sizeMB MB)?")) { return }

    $r = Save-SysPilotDownload -Url $asset.browser_download_url -OutFile $out -Label $App.Name
    if (-not $r.Ok) {
        Import-SysPilotModule SmartDownload
        if (Get-Command Save-SysPilotSmartDownload -ErrorAction SilentlyContinue) {
            $sd = Save-SysPilotSmartDownload -Url $asset.browser_download_url -OutFile $out -Name $App.Name -Id $(if($App.Id){$App.Id}else{$App.Name}) -ErrorText $r.Error -TimeoutSec 600 -Label $App.Name
            if (-not ($sd -and $sd.Ok)) { Write-Host "  [!] Download fehlgeschlagen: $($r.Error)" -ForegroundColor Red; Read-SysPilotChoice 'Weiter' | Out-Null; return }
        } else { Write-Host "  [!] Download fehlgeschlagen: $($r.Error)" -ForegroundColor Red; Read-SysPilotChoice 'Weiter' | Out-Null; return }
    }

    if ($asset.name -match '\.(exe|msi|bat|cmd)$') {
        if (Confirm-SysPilot "Installer jetzt ausfuehren?") {
            if ($asset.name -match '\.msi$') { Start-Process msiexec.exe -ArgumentList "/i `"$out`"" }
            else { Start-Process $out }
        } else {
            Write-Host "  Datei liegt unter: $out" -ForegroundColor DarkGray
        }
    }
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
}

function Invoke-SysPilotCatalogMajorGeeks {
    param([hashtable]$App)
    if (-not $App.Mg) { return }
    Write-Host ""
    Write-Host "  MajorGeeks-Details: $($App.Name) ..." -ForegroundColor Cyan
    if (-not (Get-Command Get-SysPilotMajorGeeksAsset -ErrorAction SilentlyContinue)) {
        Write-Host "  [!] MajorGeeks-Resolver nicht geladen (PortableTools)." -ForegroundColor Yellow
        Read-SysPilotChoice 'Weiter' | Out-Null; return
    }
    $asset = Get-SysPilotMajorGeeksAsset -DetailsUrl $App.Mg -VersionPattern '([\d]+\.[\d.]+)' -AssetName ''
    if (-not $asset) {
        Write-Host "  [!] MajorGeeks-Seite nicht auswertbar - Seite oeffnen?" -ForegroundColor Yellow
        if (Confirm-SysPilot "MajorGeeks-Seite im Browser oeffnen?") { Start-Process "https://www.majorgeeks.com/files/details/$($App.Mg).html" }
        Read-SysPilotChoice 'Weiter' | Out-Null; return
    }
    Write-Host "  Version: $($asset.Version)" -ForegroundColor Green
    Write-Host "  Mirror:  $($asset.MirrorUrl)" -ForegroundColor DarkGray
    if (-not (Confirm-SysPilot "Von MajorGeeks-Mirror herunterladen?")) { return }
    $zipName = ($App.Name -replace '[^\w]+','-') + '.zip'
    $out = Join-Path (Join-Path $env:USERPROFILE 'Downloads') $zipName
    $ok = Save-SysPilotMajorGeeksFile -MirrorUrl $asset.MirrorUrl -OutFile $out -Label $App.Name -TimeoutSec 300
    if ($ok) { Write-Host "  ZIP liegt unter: $out" -ForegroundColor Green }
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
}

# =====================================================================
# AUTO-UPDATE: stiller Batch-Lauf (interaktiv aufrufbar + Task-tauglich)
# =====================================================================

function Invoke-SysPilotAutoUpdate {
    <# Scannt winget+choco und installiert ALLE Updates silent.
       -Quiet: nur Log + Kurzmeldung (fuer geplante Aufgabe).
       Gibt @{Total;Ok;Fail;Errors} zurueck. #>
    param([switch]$Quiet)
    $res = [pscustomobject]@{ Total = 0; Ok = 0; Fail = 0; Errors = @() }
    $winget = Get-SysPilotWingetExe
    $choco  = Get-SysPilotChocoExe
    if (-not $winget -and -not $choco) {
        Write-SysPilotLog 'AutoUpdate: weder winget noch choco verfuegbar'
        return $res
    }
    if (-not $Quiet) { Write-Host "  Scanne nach Updates ..." -ForegroundColor Cyan }
    $rows = @()
    if ($winget) { $rows += Get-SysPilotWingetUpgrades }
    if ($choco)  { $rows += Get-SysPilotChocoOutdated }
    if (Get-Command Get-SysPilotPmOutdated -ErrorAction SilentlyContinue) {
        $rows += @(Get-SysPilotPmOutdated)
        if (Get-Command Get-SysPilotPmCoverage -ErrorAction SilentlyContinue) {
            Write-SysPilotLog ("AutoUpdate PM-Abdeckung: " + (Get-SysPilotPmCoverage))
        }
    }
    $seen = @{}; $uniq = @()
    foreach ($r in $rows) { $k = $r.Id.ToLower(); if (-not $seen.ContainsKey($k)) { $seen[$k]=$true; $uniq += $r } }
    $res.Total = $uniq.Count
    Write-SysPilotLog "AutoUpdate: $($uniq.Count) Updates gefunden"
    # Apps, die winget prinzipiell nicht aktualisieren kann (Kind=not-applicable,
    # mehrfach gescheitert) ueberspringen - spart taegliche Fehlversuche.
    # Per-App-Pref (Modus != Standard) hebelt den Skip auf.
    $upState = Read-SysPilotUpdateState
    $failedMap = @{}
    foreach ($f in @($upState.Failed)) { $failedMap[$f.Id.ToLower()] = $f }
    $explicitItems = @{}
    if ($upState.Items) { foreach ($p in $upState.Items.PSObject.Properties) { $explicitItems[$p.Name.ToLower()] = $true } }
    if ($uniq.Count -eq 0) {
        if (-not $Quiet) { Write-Host "  [OK] Alles aktuell." -ForegroundColor Green }
        return $res
    }
    foreach ($row in $uniq) {
        if (-not $Quiet) { Write-Host "  -> $($row.Name) ($($row.Id))" -ForegroundColor DarkGray }
        $pref = Get-SysPilotUpdatePrefs -Id $row.Id
        $fk = $failedMap[$row.Id.ToLower()]
        if ($fk -and $fk.Kind -in @('not-applicable','publisher') -and [int]$fk.Count -ge 2 -and -not $explicitItems[$row.Id.ToLower()]) {
            Write-SysPilotLog "AutoUpdate SKIP (winget nicht anwendbar, x$($fk.Count)): $($row.Name)"
            if (-not $Quiet) { Write-Host "     uebersprungen (winget kann nicht - siehe Fehlgeschlagene Updates)" -ForegroundColor DarkGray }
            continue
        }
        if ($pref.Mode -eq 'manual') {
            Write-SysPilotLog "AutoUpdate SKIP (manuell markiert): $($row.Name)"
            if (-not $Quiet) { Write-Host "     uebersprungen (manuell markiert)" -ForegroundColor DarkGray }
            continue
        }
        $useSilent = ($pref.Mode -ne 'interactive')
        $useAdmin  = [bool]$pref.Admin
        $sw = [Diagnostics.Stopwatch]::StartNew()
        if ($row.Source -eq 'chocolatey' -and $choco) {
            $cr = Invoke-SysPilotChocoUpgradeAuto -Pkg $row.Id -Quiet
            $sw.Stop()
            if ($cr.Ok) { $res.Ok++; Remove-SysPilotFailedUpdate -Id $row.Id; Write-SysPilotLog ("AutoUpdate choco OK{0}: {1} in {2:N0}s" -f $(if($cr.Note){" ($($cr.Note))"}else{''}), $row.Name, $sw.Elapsed.TotalSeconds) }
            else { $res.Fail++; $res.Errors += "$($row.Name): $($cr.Error)"; Add-SysPilotFailedUpdate -Row $row -Error $cr.Error; Write-SysPilotLog "AutoUpdate choco FAIL: $($row.Name) in $($sw.Elapsed.TotalSeconds.ToString('N0'))s - $($cr.Error)" }
            continue
        }
        if ([string]$row.Source -like 'pm:*') {
            $pr = Invoke-SysPilotPmUpgrade -Row $row -Silent
            $sw.Stop()
            if ($pr.Ok) { $res.Ok++; Remove-SysPilotFailedUpdate -Id $row.Id; Write-SysPilotLog "AutoUpdate PM OK: $($row.Name) in $([math]::Round($pr.Ms/1000))s" }
            else { $res.Fail++; $res.Errors += "$($row.Name): $($pr.Error)"; Add-SysPilotFailedUpdate -Row $row -Error $pr.Error; Write-SysPilotLog "AutoUpdate PM FAIL: $($row.Name) - $($pr.Error)" }
            continue
        }
        if ($winget) {
            if ($useAdmin) {
                $args = @('upgrade','--id',$row.Id,'--exact','--accept-package-agreements','--accept-source-agreements')
                $er = Invoke-SysPilotWingetElevated -ArgList $args
                $sw.Stop()
                if ($er.Ok) { $res.Ok++; Remove-SysPilotFailedUpdate -Id $row.Id; Write-SysPilotLog "AutoUpdate OK (admin): $($row.Name)" }
                else { $res.Fail++; $res.Errors += "$($row.Name): admin $($er.Error)"; Add-SysPilotFailedUpdate -Row $row -Error "admin: $($er.Error)" }
                continue
            }
            $r = Invoke-SysPilotWingetUpdateAuto -Row $row -Silent:$useSilent -TimeoutSec 900 -AllowElevated -Quiet
            $sw.Stop()
            if ($r.Ok) { $res.Ok++; Remove-SysPilotFailedUpdate -Id $row.Id; Write-SysPilotLog ("AutoUpdate OK{0}{1}: {2} in {3:N0}s" -f $(if($r.Elevated){' (admin)'}else{''}), $(if($r.Via){" via $($r.Via)"}else{''}), $row.Name, $sw.Elapsed.TotalSeconds) }
            else { $res.Fail++; $res.Errors += "$($row.Name): $($r.Error)"; Add-SysPilotFailedUpdate -Row $row -Error $r.Error -Kind $r.Kind; Write-SysPilotLog "AutoUpdate FAIL ($($r.Kind)): $($row.Name) in $($sw.Elapsed.TotalSeconds.ToString('N0'))s - $($r.Error)" }
        }
    }
    Write-SysPilotLog "AutoUpdate fertig: $($res.Ok) ok, $($res.Fail) Fehler"
    if (-not $Quiet) {
        Write-Host ("  Fertig: {0}/{1} still aktualisiert, {2} Fehler." -f $res.Ok, $res.Total, $res.Fail) -ForegroundColor $(if ($res.Fail -eq 0) {'Green'} else {'Yellow'})
        if ($res.Errors.Count -gt 0) { $res.Errors | Select-Object -First 5 | ForEach-Object { Write-Host "    ! $_" -ForegroundColor DarkGray } }
    }
    return $res
}

function Get-SysPilotUpdateTask {
    return Get-ScheduledTask -TaskName 'SysPilot Update' -ErrorAction SilentlyContinue
}

function Install-SysPilotUpdateTask {
    <# Taeglich um 12:00: SysPilot.ps1 -UpdateAuto (silent, hoechste Rechte). #>
    $exe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $scriptPath = Join-Path $script:SysPilotRoot 'SysPilot.ps1'
    $action = New-ScheduledTaskAction -Execute $exe -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" -UpdateAuto"
    $trigger = New-ScheduledTaskTrigger -Daily -At '12:00'
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    Register-ScheduledTask -TaskName 'SysPilot Update' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-SysPilotLog 'AutoUpdate: geplante Aufgabe "SysPilot Update" registriert (taeglich 12:00)'
}

function Remove-SysPilotUpdateTask {
    Unregister-ScheduledTask -TaskName 'SysPilot Update' -Confirm:$false -ErrorAction SilentlyContinue
    Write-SysPilotLog 'AutoUpdate: geplante Aufgabe entfernt'
}

# =====================================================================
# UPDATE-STATE: fehlgeschlagene Updates + dauerhaft prefs
# =====================================================================
# update-center.json:
# { "Failed": [ {Id,Name,Source,Error,LastTry,Count} ],
#   "Defaults": { "Mode": "silent|interactive|ask", "Admin": bool },
#   "Items": { "<id>": { "Mode": "...", "Admin": bool } } }

function Get-SysPilotUpdateStatePath {
    # State liegt in LOCALAPPDATA (Program Files ist ohne Admin read-only;
    # der geplante Task schreibt sonst still nichts).
    $dir = Join-Path $env:LOCALAPPDATA 'SysPilot'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return (Join-Path $dir 'update-center.json')
}

function Read-SysPilotUpdateState {
    $p = Get-SysPilotUpdateStatePath
    if (Test-Path $p) {
        try { return (Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { }
    }
    return [pscustomobject]@{ Failed = @(); Defaults = [pscustomobject]@{ Mode = 'silent'; Admin = $false }; Items = [pscustomobject]@{} }
}

function Write-SysPilotUpdateState {
    param($State)
    try { $State | ConvertTo-Json -Depth 8 | Set-Content (Get-SysPilotUpdateStatePath) -Encoding UTF8 }
    catch { Write-SysPilotLog "UpdateCenter: State schreiben fehlgeschlagen: $($_.Exception.Message)" }
}

function Add-SysPilotFailedUpdate {
    param([Parameter(Mandatory)]$Row, [string]$Error = '', [string]$Kind = '')
    $st = Read-SysPilotUpdateState
    $id = [string]$Row.Id
    $existing = @($st.Failed) | Where-Object { $_.Id -eq $id } | Select-Object -First 1
    if ($existing) {
        $existing.Count = [int]$existing.Count + 1
        $existing.LastTry = (Get-Date).ToString('s')
        $existing.Error = $Error
        if ($Kind) { $existing.Kind = $Kind }
    } else {
        $st.Failed = @($st.Failed) + [pscustomobject]@{
            Id = $id; Name = [string]$Row.Name; Source = [string]$Row.Source
            Error = $Error; LastTry = (Get-Date).ToString('s'); Count = 1; Kind = $Kind
        }
    }
    Write-SysPilotUpdateState $st
    Write-SysPilotLog "UpdateCenter FAIL registriert: $($Row.Name) ($id) - $Error"
}

function Remove-SysPilotFailedUpdate {
    param([Parameter(Mandatory)][string]$Id)
    $st = Read-SysPilotUpdateState
    $before = @($st.Failed).Count
    $st.Failed = @($st.Failed | Where-Object { $_.Id -ne $Id })
    if (@($st.Failed).Count -ne $before) { Write-SysPilotUpdateState $st }
}

function Sync-SysPilotFailedUpdates {
    <# Prueft alle 'Fehlgeschlagenen Updates' gegen den aktuellen
       Paketmanager-Stand: Eintraege, die nicht laenger als Update
       anstehen (z.B. App wurde manuell aktualisiert) oder deren
       Paket nicht mehr installiert ist, werden automatisch entfernt.
       Nicht Pruefbares (Manager fehlt/Abfrage fehlgeschlagen)
       bleibt erhalten - kein Faellschluss.
       Gibt @{Checked;Removed;Names} zurueck. #>
    $st = Read-SysPilotUpdateState
    $failed = @($st.Failed)
    if ($failed.Count -eq 0) { return @{ Checked = 0; Removed = 0; Names = @() } }

    # Ausstehende Updates je Manager einmalig ermitteln.
    # Key existiert nur, wenn die Abfrage erfolgreich lief -
    # sonst wuerde ein Fehler "keine Updates" vortaeuschen
    # und alle Eintraege faelschlich geloescht.
    $sets = @{}
    if (Get-SysPilotWingetExe) {
        try {
            $rows = @(Get-SysPilotWingetUpgrades)
            if ($script:_wingetUpgOk) {
                $s = @{}
                foreach ($r in $rows) {
                    $s[[string]$r.Id] = $true
                    $n = ([string]$r.Name).Trim().ToLower(); if ($n) { $s[$n] = $true }
                }
                $sets['winget'] = $s
            }
        } catch { }
    }
    if (Get-SysPilotChocoExe) {
        try {
            $rows = @(Get-SysPilotChocoOutdated)
            if ($script:_chocoOutdatedOk) {
                $s = @{}
                foreach ($r in $rows) {
                    $s[[string]$r.Id] = $true
                    $n = ([string]$r.Name).Trim().ToLower(); if ($n) { $s[$n] = $true }
                }
                $sets['chocolatey'] = $s
            }
        } catch { }
    }
    if (Get-SysPilotScoopExeLocal) {
        try {
            # Scoop-Status-Probe: nur bei erfolgreicher Abfrage auswerten
            $probe = Invoke-SysPilotScoopRaw -ScoopArgs @('status')
            if ($probe) {
                $s = @{}
                foreach ($r in @(Get-SysPilotScoopOutdated)) {
                    $s[[string]$r.Id] = $true
                    $n = ([string]$r.Name).Trim().ToLower(); if ($n) { $s[$n] = $true }
                }
                $sets['scoop'] = $s
            }
        } catch { }
    }

    $removeIds = @(); $names = @()
    foreach ($f in $failed) {
        $src = ([string]$f.Source).ToLower()
        $key = 'winget'
        if ($src -match 'choco') { $key = 'chocolatey' }
        elseif ($src -match 'scoop') { $key = 'scoop' }
        if (-not $sets.ContainsKey($key)) { continue }   # Manager nicht pruefbar -> behalten
        $pend = $sets[$key]
        $id = ([string]$f.Id).Trim()
        $nm = ([string]$f.Name).Trim().ToLower()
        if (($id -and $pend.ContainsKey($id)) -or ($nm -and $pend.ContainsKey($nm))) { continue }
        $removeIds += [string]$f.Id
        $names += [string]$f.Name
    }
    if ($names.Count -eq 0) { return @{ Checked = $failed.Count; Removed = 0; Names = @() } }
    $st.Failed = @($st.Failed | Where-Object { $removeIds -notcontains [string]$_.Id })
    Write-SysPilotUpdateState $st
    foreach ($n in $names) { Write-SysPilotLog "UpdateCenter: erledigt entfernt (Update steht nicht mehr aus): $n" }
    return @{ Checked = $failed.Count; Removed = $names.Count; Names = $names }
}

function Get-SysPilotUpdatePrefs {
    <# Gemergte Einstellungen: Defaults + Items[id]. #>
    param([Parameter(Mandatory)][string]$Id)
    $st = Read-SysPilotUpdateState
    $mode = 'silent'; $admin = $false
    if ($st.Defaults.Mode)   { $mode  = [string]$st.Defaults.Mode }
    if ($null -ne $st.Defaults.Admin) { $admin = [bool]$st.Defaults.Admin }
    $item = $st.Items.PSObject.Properties[$Id]
    if ($item) {
        if ($item.Value.Mode)  { $mode  = [string]$item.Value.Mode }
        if ($null -ne $item.Value.Admin) { $admin = [bool]$item.Value.Admin }
    }
    return @{ Mode = $mode; Admin = $admin }
}

function Set-SysPilotUpdatePrefs {
    param([string]$Id, [string]$Mode, [bool]$Admin, [switch]$Global, [switch]$Clear)
    if (-not $Global -and -not $Id) { throw 'Id fehlt (oder -Global setzen)' }
    $st = Read-SysPilotUpdateState
    if ($Global) {
        if ($Mode)  { $st.Defaults.Mode  = $Mode }
        $st.Defaults.Admin = $Admin
    } else {
        if ($Clear) {
            if ($st.Items.PSObject.Properties[$Id]) { $st.Items.PSObject.Properties.Remove($Id) }
        } else {
            if (-not $st.Items.PSObject.Properties[$Id]) {
                $st.Items | Add-Member -NotePropertyName $Id -NotePropertyValue ([pscustomobject]@{ Mode=''; Admin=$false }) -Force
            }
            if ($Mode) { $st.Items.$Id.Mode = $Mode }
            $st.Items.$Id.Admin = $Admin
        }
    }
    Write-SysPilotUpdateState $st
}

function Invoke-SysPilotWingetElevated {
    <# winget mit Admin-Rechten in einem eigenen Fenster (-Wait). #>
    param([Parameter(Mandatory)][string[]]$ArgList)
    $exe = Get-SysPilotWingetExe
    if (-not $exe) { return @{ Ok = $false; Error = 'winget nicht gefunden' } }
    $argStr = ($ArgList | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    try {
        $p = Start-Process -FilePath $exe -ArgumentList $argStr -Verb RunAs -PassThru -ErrorAction Stop
        $sw = [Diagnostics.Stopwatch]::StartNew(); $spin = '|/-\'; $si = 0
        while (-not $p.HasExited) {
            Start-Sleep -Milliseconds 700
            $el = [int]$sw.Elapsed.TotalSeconds
            Write-Host ("`r  winget elevated laeuft... {0,4}s {1}   " -f $el, $spin[$si++ % 4]) -NoNewline
            if ($el -gt 900) { break }
        }
        Write-Host ''
        # Timeout: Prozessbaum beenden, sonst laufen naechste Updates
        # parallel zum noch laufenden Installer (Datei-Lock-Kaese)
        if (-not $p.HasExited) {
            try { & "$env:SystemRoot\System32\taskkill.exe" /PID $p.Id /T /F 2>&1 | Out-Null } catch {}
            return @{ Ok = $false; ExitCode = $null; Error = 'elevated: Timeout nach 900s' }
        }
        return @{ Ok = ($p.ExitCode -eq 0); ExitCode = $p.ExitCode; Error = '' }
    } catch {
        # Fallback: elevated PowerShell
        try {
            $cmd = "& '$exe' $argStr"
            $p2 = Start-Process powershell.exe -ArgumentList "-NoProfile","-Command",$cmd -Verb RunAs -PassThru -ErrorAction Stop
            $sw = [Diagnostics.Stopwatch]::StartNew(); $spin = '|/-\'; $si = 0
            while (-not $p2.HasExited) {
                Start-Sleep -Milliseconds 700
                $el = [int]$sw.Elapsed.TotalSeconds
                Write-Host ("`r  winget elevated laeuft... {0,4}s {1}   " -f $el, $spin[$si++ % 4]) -NoNewline
                if ($el -gt 900) { break }
            }
            Write-Host ''
            if (-not $p2.HasExited) {
                try { & "$env:SystemRoot\System32\taskkill.exe" /PID $p2.Id /T /F 2>&1 | Out-Null } catch {}
                return @{ Ok = $false; ExitCode = $null; Error = 'elevated: Timeout nach 900s' }
            }
            return @{ Ok = ($p2.ExitCode -eq 0); ExitCode = $p2.ExitCode; Error = '' }
        } catch { return @{ Ok = $false; Error = $_.Exception.Message } }
    }
}

function Open-SysPilotManualUpdateTerminal {
    <# Schreibt die noetigen Befehle in ein .ps1 und oeffnet es in
       Windows Terminal (Fallback: powershell). #>
    param([Parameter(Mandatory)][array]$Rows)
    $lines = @('# SysPilot - manuelle Updates', "# erstellt $(Get-Date -Format 'yyyy-MM-dd HH:mm')", '')
    foreach ($row in $Rows) {
        if ($row.Source -eq 'chocolatey') {
            $lines += "Write-Host '== $($row.Name) (chocolatey) ==' -ForegroundColor Cyan"
            $lines += "choco upgrade $($row.Id)"
        } else {
            $lines += "Write-Host '== $($row.Name) (winget $($row.Id)) ==' -ForegroundColor Cyan"
            $lines += "winget upgrade --id $($row.Id) --exact --accept-package-agreements --accept-source-agreements"
        }
        $lines += ''
    }
    $lines += "Write-Host 'Fertig. Fenster schliessen.' -ForegroundColor Green; pause"
    $script = Join-Path $env:TEMP ("syspilot-updates-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.ps1')
    $lines | Set-Content $script -Encoding UTF8
    $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
    if ($wt) { Start-Process wt.exe -ArgumentList "powershell","-NoExit","-ExecutionPolicy","Bypass","-File","`"$script`"" }
    else     { Start-Process powershell.exe -ArgumentList "-NoExit","-ExecutionPolicy","Bypass","-File","`"$script`"" }
    Write-Host "  Terminal geoeffnet: $script" -ForegroundColor Green
    Write-Host "  (Bereits(Admin) noetig fuer machine-scope Installer)" -ForegroundColor DarkGray
}

function Start-SysPilotAiSearch {
    <# KI-Suche als Installations-/Versions-Hilfe: oeffnet eine freie
       Web-KI mit vorgefertigter Anfrage (Duck.ai, Gemini, Copilot,
       Perplexity - alle ohne Zwangs-Login nutzbar). Perplexity hat
       echten Web-Zugriff und liefert damit aktuellste Quellen. #>
    param([Parameter(Mandatory)][string]$Query)
    $q = [Uri]::EscapeDataString($Query)
    $engines = @(
        @{ Label = "Perplexity (Websuche, aktuellste Quellen): $Query"; Color = 'Green';  Tag = "https://www.perplexity.ai/?q=$q" },
        @{ Label = "Duck.ai (kostenlos, kein Login): $Query";            Color = 'Orange'; Tag = "https://duckduckgo.com/?q=$q&ia=chat" },
        @{ Label = "Gemini (Google): $Query";                             Color = 'Blue';   Tag = "https://gemini.google.com/app?q=$q" },
        @{ Label = "Copilot (Microsoft): $Query";                         Color = 'Cyan';   Tag = "https://copilot.microsoft.com/?q=$q" }
    )
    $sel = Show-SysPilotArrowMenu -Items $engines -Title 'KI-Suche' -Footer 'Enter = im Browser oeffnen, Esc = abbruch'
    if ($sel) { Start-Process $sel }
}

function Find-SysPilotCatalogSearch {
    <# Durchsucht echte Katalog-SUCHSEITEN (nicht nur geratene Slugs):
       Uptodown /windows/search?query= (Ergebnisse als <slug>.de.uptodown.com),
       FileHorse /search/?q= (/download-<slug>-windows-10/).
       Gibt @{Source;Title;Url;Note;Best} zurueck - Titel aus Linktext
       oder humanisiertem Slug. Defensive Parser: bei Markup-Aenderung
       einfach weniger Treffer, nie Fehler. #>
    param([Parameter(Mandatory)][string]$Query)
    $results = @()
    $qEsc  = [Uri]::EscapeDataString($Query)
    $ua = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36' }
    $seen = @{}

    function script:Format-SysPilotSlugTitle {
        param([string]$slug)
        $t = ''
        foreach ($seg in (($slug -replace '[^a-zA-Z0-9]+','-') -split '-' | Where-Object { $_ })) {
            $t += ' ' + $seg.Substring(0,1).ToUpper() + $seg.Substring(1)
        }
        return $t.Trim()
    }

    # --- Uptodown: /windows/search?query= -> <slug>.de.uptodown.com/windows ---
    try {
        $u = "https://de.uptodown.com/windows/search?query=$qEsc"
        $r = Invoke-WebRequest $u -UseBasicParsing -TimeoutSec 15 -Headers $ua -ErrorAction Stop
        $n = 0
        foreach ($m in [regex]::Matches($r.Content, 'https://([a-z0-9][a-z0-9\-]{1,60})\.(?:de|en|com)\.uptodown\.com/windows')) {
            $slug = $m.Groups[1].Value
            if ($slug -in @('www','en','de','apps','search','categories','developers','about','blog','enterprise','business')) { continue }
            $key = "ud:$slug"; if ($seen.ContainsKey($key)) { continue }; $seen[$key] = $true
            $results += [pscustomobject]@{ Source='Uptodown'; Title=(Format-SysPilotSlugTitle $slug); Url="https://$slug.de.uptodown.com/windows"; Note='Katalog-Suche'; Best=$false }
            $n++; if ($n -ge 6) { break }
        }
    } catch { }

    # --- FileHorse: /search/?q= -> /download-<slug>-windows-10/ ---
    try {
        $u = "https://www.filehorse.com/search/?q=$qEsc"
        $r = Invoke-WebRequest $u -UseBasicParsing -TimeoutSec 15 -Headers $ua -ErrorAction Stop
        $n = 0
        foreach ($m in [regex]::Matches($r.Content, 'href="(?:https://www\.filehorse\.com)?(/download-[a-z0-9][a-z0-9\-]{2,80}/?)"')) {
            $path = $m.Groups[1].Value.TrimEnd('/')
            $slug = $path -replace '^/download-','' -replace '-windows-?\d*.*$','' -replace '-(32|64|portable|latest|free|\d+)$',''
            if ($slug.Length -lt 3) { continue }
            $key = "fh:$slug"; if ($seen.ContainsKey($key)) { continue }; $seen[$key] = $true
            $results += [pscustomobject]@{ Source='FileHorse'; Title=(Format-SysPilotSlugTitle $slug); Url="https://www.filehorse.com$path/"; Note='Katalog-Suche'; Best=$false }
            $n++; if ($n -ge 6) { break }
        }
    } catch { }

    return @($results)
}

function Show-SysPilotFailedUpdatesWindow {
    param($Owner)
    <# WPF-Variante der Fehlgeschlagenen-Updates: Liste + Buttons statt
       Pfeilmenue. Laengere Aktionen (silent/admin-Retry) laufen in
       einem Hintergrund-Runspace; Ergebnis kommt per DispatcherTimer.
       Fallback: Show-SysPilotFailedUpdates (Konsolen-Menue). #>
    try {
        Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase -ErrorAction Stop
        if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'kein STA' }
    } catch {
        Show-SysPilotFailedUpdates
        return
    }
    $pxaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="SysPilot - Fehlgeschlagene Updates" Width="900" Height="680"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResizeWithGrip"
        Background="#FF1E1E2E" Foreground="#FFE0E0E0">
  <Window.Resources>
    <Style TargetType="Button"><Setter Property="Background" Value="#FF2D2D44"/><Setter Property="Foreground" Value="#FFE0E0E0"/><Setter Property="BorderBrush" Value="#FF4A4A6A"/><Setter Property="Padding" Value="10,4"/><Setter Property="Margin" Value="3"/><Setter Property="Cursor" Value="Hand"/></Style>
    <Style TargetType="ListViewItem"><Setter Property="Padding" Value="8,5"/><Setter Property="Foreground" Value="#FFEAEAF2"/><Setter Property="FontSize" Value="12"/><Setter Property="HorizontalContentAlignment" Value="Stretch"/><Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#FF34344E"/></Trigger><Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#CCE4EAF2"/><Setter Property="Foreground" Value="#FF1E1E2E"/></Trigger></Style.Triggers></Style>
    <Style TargetType="GridViewColumnHeader"><Setter Property="Background" Value="#FF2D2D44"/><Setter Property="Foreground" Value="#FF4FC3F7"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Padding" Value="8,5"/><Setter Property="BorderBrush" Value="#FF4A4A6A"/><Setter Property="BorderThickness" Value="0,0,1,1"/></Style>
    <Style TargetType="ListBoxItem"><Setter Property="Padding" Value="5,3"/><Setter Property="Foreground" Value="#FFD8E8D8"/><Setter Property="FontSize" Value="11"/><Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#FF2A3A2A"/></Trigger><Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#CCE4EAF2"/><Setter Property="Foreground" Value="#FF1B1B28"/></Trigger></Style.Triggers></Style>
    <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#FFE0E0E0"/></Style>
    <Style TargetType="TextBox"><Setter Property="Background" Value="#FF252538"/><Setter Property="Foreground" Value="#FFEAEAF2"/><Setter Property="BorderBrush" Value="#FF4A4A6A"/><Setter Property="Padding" Value="6,4"/></Style>
  </Window.Resources>
  <DockPanel Margin="12">
    <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,8">
      <TextBox x:Name="FilterBox" Width="220" ToolTip="Filter: Name, ID oder Fehlertext"/>
      <Button x:Name="BtnNaRemove" Content="Nicht-anwendbare entfernen" ToolTip="Loescht alle Eintraege, die winget prinzipiell nicht aktualisieren kann"/>
      <Button x:Name="BtnRefresh" Content="Aktualisieren"/>
      <Button x:Name="BtnClose" Content="Schliessen" HorizontalAlignment="Right"/>
    </StackPanel>
    <Border DockPanel.Dock="Bottom" Background="#FF16161F" BorderBrush="#FF4A4A6A" BorderThickness="0,1,0,0" Padding="8,6">
      <StackPanel>
        <ProgressBar x:Name="ProgBar" Height="4" IsIndeterminate="False" Minimum="0" Maximum="100" Value="0" Visibility="Collapsed" Margin="0,0,0,6" Foreground="#FF4FC3F7" Background="#FF2A2A3A"/>
        <Grid Margin="0,0,0,4">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <ListBox x:Name="ResultList" Grid.Column="0" Height="62" Visibility="Collapsed" Background="#FF101018" BorderThickness="0" ToolTip="Suchergebnisse - Doppelklick oder Button oeffnet den Link"/>
          <Button x:Name="BtnOpenLink" Grid.Column="1" Content="Link&#10;oeffnen" Visibility="Collapsed" Margin="5,0,0,0" VerticalAlignment="Stretch" ToolTip="Oeffnet die URL des markierten Suchergebnisses im Browser"/>
        </Grid>
        <RichTextBox x:Name="HerbBox" Height="120" IsReadOnly="True" Visibility="Collapsed"
                     Background="#FF101018" Foreground="#FFEAEAF2" BorderThickness="0"
                     FontFamily="Segoe UI" FontSize="12" Padding="8,6" Margin="0,6,0,0"
                     VerticalScrollBarVisibility="Auto" ToolTip="Herbert-Antwort - URLs sind klickbar"/>
        <TextBox x:Name="LogBox" Height="110" IsReadOnly="True" TextWrapping="NoWrap" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="11" Background="#FF0C0C14" Foreground="#FF9FE89F" BorderThickness="0" ToolTip="Live-Protokoll - Rechtsklick = kopieren"/>
        <TextBlock x:Name="StatusText" FontSize="11" Foreground="#FF9E9E9E" Margin="0,5,0,0" TextWrapping="Wrap"/>
      </StackPanel>
    </Border>
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="2*" MinWidth="380"/><ColumnDefinition Width="*" MinWidth="280"/>
      </Grid.ColumnDefinitions>
      <ListView x:Name="FailList" Background="#FF252538" BorderThickness="0">
        <ListView.View>
          <GridView>
            <GridViewColumn Header="Programm" Width="170" DisplayMemberBinding="{Binding Name}"/>
            <GridViewColumn Header="Quelle" Width="70" DisplayMemberBinding="{Binding Source}"/>
            <GridViewColumn Header="Fehler" Width="55" DisplayMemberBinding="{Binding CountText}"/>
            <GridViewColumn Header="Art" Width="120" DisplayMemberBinding="{Binding KindText}"/>
            <GridViewColumn Header="Letzter Versuch" Width="125" DisplayMemberBinding="{Binding LastTry}"/>
            <GridViewColumn Header="Fehlertext" Width="220" DisplayMemberBinding="{Binding ErrorShort}"/>
          </GridView>
        </ListView.View>
      </ListView>
      <Border Grid.Column="1" Background="#FF252538" CornerRadius="6" Padding="12" Margin="10,0,0,0">
        <DockPanel>
          <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,10,0,0">
            <Button x:Name="BtnSilent" Content="Silent erneut" ToolTip="Nochmal mit silent-Modus versuchen (winget/choco/scoop-Fallback)"/>
            <Button x:Name="BtnAdmin" Content="Admin" ToolTip="Erhoeht ausfuehren (UAC-Abfrage)"/>
            <Button x:Name="BtnManual" Content="Manuell" ToolTip="Oeffnet ein Terminal mit den noetigen Befehlen"/>
            <Button x:Name="BtnSearch" Content="Suchen" ToolTip="Alle Paketmanager + Web-Kataloge + Herbert-KI nach Download-Link/Update suchen"/>
            <Button x:Name="BtnAutoFix" Content="Auto-Fix" FontWeight="Bold" ToolTip="Herbert + SmartDownload: analysiert den Fehler per KI und wendet die beste Loesung direkt an (alternativer Paketmanager, sicherer Befehl oder Download-Link)"/>
            <Button x:Name="BtnRemove" Content="Entfernen" ToolTip="Eintrag als erledigt markieren"/>
          </StackPanel>
          <StackPanel>
            <TextBlock x:Name="DName" FontSize="15" FontWeight="Bold" Foreground="#FFEF5350" TextWrapping="Wrap"/>
            <TextBlock x:Name="DMeta" FontSize="11" Foreground="#FF9E9E9E" Margin="0,2,0,8" TextWrapping="Wrap"/>
            <TextBlock x:Name="DHint" FontSize="11" Foreground="#FFFFB74D" TextWrapping="Wrap" Margin="0,0,0,8"/>
            <TextBlock Text="Fehler:" FontSize="11" Foreground="#FF9E9E9E"/>
            <TextBox x:Name="DError" IsReadOnly="True" Height="110" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Margin="0,2,0,0" ToolTip="Rechtsklick = kopieren"/>
          </StackPanel>
        </DockPanel>
      </Border>
    </Grid>
  </DockPanel>
</Window>
"@
    $fwin = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$pxaml)))
    if (Test-SysPilotWindowAlreadyOpen -Key 'syspilot-failed-updates' -Win $fwin) { return }
    if ($Owner) { $fwin.Owner = $Owner } else { $fwin.WindowStartupLocation = 'CenterScreen' }
    $fc = @{}
    foreach ($n in 'FailList','FilterBox','DName','DMeta','DHint','DError','BtnSilent','BtnAdmin','BtnManual','BtnSearch','BtnAutoFix','BtnRemove','BtnNaRemove','BtnRefresh','BtnClose','StatusText','ProgBar','LogBox','ResultList','BtnOpenLink','HerbBox') {
        $fc[$n] = $fwin.FindName($n)
    }
    $script:fuResults = @()
    $script:fuQueue = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
    $script:fuProcPath = ''; $script:fuProcOffset = 0L
    $script:fuJobKind = ''
    $kindMap = @{ 'not-applicable'='winget: nicht anwendbar'; 'publisher'='winget: Publisher-Methode'; 'admin'='Admin noetig'; 'timeout'='Timeout' }
    $kindHint = @{
        'not-applicable' = 'winget meldet: kein anwendbares Upgrade (andere Quelle/Architektur). Installer meist nur manuell/interaktiv - im Konsolen-Softwarecenter unter "Fehlgeschlagene Updates".'
        'publisher'      = 'winget kann dieses Paket nicht aktualisieren - nur ueber den Publisher/eigenen Paketmanager.'
        'admin'          = 'Installer braucht Admin-Rechte - Button "Admin" versucht elevated (UAC).'
        'timeout'        = 'Update hat das Zeitlimit ueberschritten - evtl. grosse Datei oder Haenger.'
    }
    $script:fuItems = @()
    $script:fuBusy = $false
    $setStatus = { param($t,$col) $fc.StatusText.Text = $t; $fc.StatusText.Foreground = [Windows.Media.BrushConverter]::new().ConvertFrom($col) }

    # --- Live-Protokoll: Queue-Marker + Tail des neuesten
    #     syspilot-proc-*.log (Invoke-SysPilotMonitoredProcess schreibt
    #     den kompletten Paketmanager-Output dorthin) ---
    $fuLog = {
        param([string]$line)
        if (-not $line) { return }
        Write-SysPilotPanelLog $line
        $fc.LogBox.AppendText($line + "`n")
        try { $fc.LogBox.ScrollToEnd() } catch { }
        if ($fc.LogBox.Text.Length -gt 120000) {
            $fc.LogBox.Text = $fc.LogBox.Text.Substring($fc.LogBox.Text.Length - 60000)
            try { $fc.LogBox.ScrollToEnd() } catch { }
        }
    }
    $fuTailProc = {
        # Neueste syspilot-proc-*.log der letzten 20s finden und neue
        # Bytes anhaengen (Offset pro Datei gemerkt).
        try {
            $logs = Get-ChildItem (Join-Path $env:TEMP 'syspilot-proc-*.log') -File -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -gt (Get-Date).AddSeconds(-20) } |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if (-not $logs) { return }
            if ($logs.FullName -ne $script:fuProcPath) { $script:fuProcPath = $logs.FullName; $script:fuProcOffset = 0L }
            $len = $logs.Length
            if ($len -le $script:fuProcOffset) { return }
            $fs = [IO.File]::Open($logs.FullName,'Open','Read','ReadWrite')
            try {
                $fs.Seek($script:fuProcOffset, 'Begin') | Out-Null
                $sr = New-Object IO.StreamReader($fs)
                $chunk = $sr.ReadToEnd()
            } finally { $fs.Close() }
            $script:fuProcOffset = $len
            foreach ($l in ($chunk -split "`r?`n")) { & $fuLog $l }
        } catch { }
    }
    $fuDrain = {
        $line = $null
        while ($script:fuQueue.TryDequeue([ref]$line)) {
            if ($line) { & $fuLog ">> $line" }
            $line = $null
        }
        & $fuTailProc
    }

    $loadFailed = {
        $st = Read-SysPilotUpdateState
        $script:fuItems = @($st.Failed)
        & $filterScript
    }

    $showDetails = {
        $w = $fc.FailList.SelectedItem
        if (-not $w) { $fc.DName.Text=''; $fc.DMeta.Text=''; $fc.DHint.Text=''; $fc.DError.Text=''; return }
        $f = $w.Orig
        $fc.DName.Text = "$($f.Name)  [$($f.Source)]"
        $fc.DMeta.Text = "ID: $($f.Id)`nVersuche: $($f.Count)  Letzter Versuch: $($f.LastTry)"
        $fc.DHint.Text = $(if ($kindHint.ContainsKey([string]$f.Kind)) { $kindHint[[string]$f.Kind] } else { 'Weitere Aktionen (interaktiv/manuell/KI) im Konsolen-Softwarecenter.' })
        $fc.DError.Text = [string]$f.Error
        $fc.BtnSilent.IsEnabled = (-not $script:fuBusy)
        $fc.BtnAdmin.IsEnabled  = (-not $script:fuBusy)
        $fc.BtnSearch.IsEnabled = (-not $script:fuBusy)
        $fc.BtnAutoFix.IsEnabled = (-not $script:fuBusy)
        $fc.BtnManual.IsEnabled = (-not $script:fuBusy)
        $fc.BtnRemove.IsEnabled = (-not $script:fuBusy)
    }

    $filterScript = {
        $q = $fc.FilterBox.Text.Trim()
        $fc.FailList.Items.Clear()
        foreach ($f in $script:fuItems) {
            if ($q -eq '' -or "$($f.Name) $($f.Id) $($f.Error)" -match [regex]::Escape($q)) {
                $kindTxt = $(if ($kindMap.ContainsKey([string]$f.Kind)) { $kindMap[[string]$f.Kind] } else { '' })
                $errShort = $(if ($f.Error) { $f.Error.Substring(0,[Math]::Min(80,$f.Error.Length)) } else { '' })
                [void]$fc.FailList.Items.Add([pscustomobject]@{
                    Name = $f.Name; Source = $f.Source
                    CountText = ("x{0}" -f [int]$f.Count); KindText = $kindTxt
                    LastTry = $f.LastTry; ErrorShort = $errShort; Orig = $f
                })
            }
        }
        if ($fc.FailList.Items.Count -gt 0 -and $fc.FailList.SelectedIndex -lt 0) { $fc.FailList.SelectedIndex = 0 }
        else { & $showDetails }
    }

    # Hintergrund-Retry (silent/admin) - winget/choco kann Minuten dauern
    $fuModDir = Split-Path -Parent $PSCommandPath
    $startRetry = {
        param($mode)
        $w = $fc.FailList.SelectedItem
        if (-not $w -or $script:fuBusy) { return }
        $f = $w.Orig
        $script:fuBusy = $true
        $script:fuJobKind = 'retry'
        $script:fuRetryId = [string]$f.Id
        $script:fuResults = @()
        $script:fuQueue = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
        $script:fuProcPath = ''; $script:fuProcOffset = 0L
        $fc.LogBox.Clear()
        & $showDetails
        & $setStatus "Laeuft: $($f.Name) ($mode) - kann einige Minuten dauern ..." '#FFB0B0C0'
        $script:fuRs = [runspacefactory]::CreateRunspace()
        $script:fuRs.ApartmentState = 'STA'; $script:fuRs.ThreadOptions = 'ReuseThread'
        $script:fuRs.Open()
        $script:fuRs.SessionStateProxy.SetVariable('modDir', $fuModDir)
        $script:fuRs.SessionStateProxy.SetVariable('itemId', [string]$f.Id)
        $script:fuRs.SessionStateProxy.SetVariable('itemSource', [string]$f.Source)
        $script:fuRs.SessionStateProxy.SetVariable('retryMode', $mode)
        $script:fuRs.SessionStateProxy.SetVariable('fuQueue', $script:fuQueue)
        $script:fuPs = [powershell]::Create()
        $script:fuPs.Runspace = $script:fuRs
        [void]$script:fuPs.AddScript({
            Import-Module (Join-Path $modDir 'Common.psm1') -Force -ErrorAction SilentlyContinue
            Import-Module (Join-Path $modDir 'SoftwareUpdateCenter.psm1') -Force
            $q = $fuQueue
            $say = { param($m) if ($q) { $q.Enqueue([string]$m) } }
            & $say "Starte Retry ($retryMode) fuer $itemId ..."
            $err = ''
            try {
                if ($retryMode -eq 'admin') {
                    & $say 'Admin-Pfad: elevation (UAC-Fenster folgt)'
                    $r = Invoke-SysPilotWingetElevated -ArgList @('upgrade','--id',$itemId,'--exact','--accept-package-agreements','--accept-source-agreements')
                    @{ Ok = [bool]$r.Ok; Err = [string]$r.Error }
                } elseif ($itemSource -eq 'chocolatey') {
                    & $say 'Paketmanager: Chocolatey'
                    $cr = Invoke-SysPilotChocoUpgradeAuto -Pkg $itemId -Quiet
                    @{ Ok = [bool]$cr.Ok; Err = [string]$cr.Error }
                } else {
                    & $say 'Paketmanager: winget (silent, mit choco/scoop-Fallback)'
                    $ok = Invoke-SysPilotCatalogWingetSilent -Id $itemId
                    @{ Ok = [bool]$ok; Err = '' }
                }
            } catch { @{ Ok = $false; Err = $_.Exception.Message } }
        })
        $script:fuAsync = $script:fuPs.BeginInvoke()
        $fc.ProgBar.Visibility = 'Visible'; $fc.ProgBar.IsIndeterminate = $true
        $fuPoll.Start()
    }

    # Auto-Fix: Herbert (KI) + SmartDownload analysiert den Fehler und
    # wendet die beste Loesung direkt an - auch fuer 'nicht anwendbar'.
    # -Auto: ohne Rueckfrage (automatischer Start bei Auswahl)
    $startAutoFix = {
        param([switch]$Auto)
        $w = $fc.FailList.SelectedItem
        if (-not $w -or $script:fuBusy) { return }
        $f = $w.Orig
        $mgr = $(if([string]$f.Source -eq 'chocolatey'){'choco'}elseif([string]$f.Source -like 'pm:*'){[string]$f.Source -replace '^pm:',''}else{'winget'})
        if (-not $Auto) {
            $r=[System.Windows.MessageBox]::Show("Herbert + SmartDownload analysieren den Fehler per KI und wenden die beste Loesung DIREKT an`n(alternativer Paketmanager, sicherer Befehl oder Download-Link).`n`n$($f.Name) [$($f.Source)]`n`nFortfahren?",'Auto-Fix','YesNo','Question')
            if($r -ne 'Yes'){return}
        }
        $script:fuBusy = $true
        $script:fuJobKind = 'autofix'
        $script:fuRetryId = [string]$f.Id
        $script:fuResults = @()
        $script:fuQueue = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
        $script:fuProcPath=''; $script:fuProcOffset=0L
        $fc.LogBox.Clear(); & $showDetails
        & $setStatus "Auto-Fix laeuft: $($f.Name) - Herbert analysiert (kann 1-3 Minuten dauern) ..." '#FFB0B0C0'
        $script:fuRs=[runspacefactory]::CreateRunspace();$script:fuRs.ApartmentState='STA';$script:fuRs.ThreadOptions='ReuseThread';$script:fuRs.Open()
        $script:fuRs.SessionStateProxy.SetVariable('modDir',$fuModDir)
        $script:fuRs.SessionStateProxy.SetVariable('fuQueue',$script:fuQueue)
        $script:fuRs.SessionStateProxy.SetVariable('fixName',[string]$f.Name)
        $script:fuRs.SessionStateProxy.SetVariable('fixId',[string]$f.Id)
        $script:fuRs.SessionStateProxy.SetVariable('fixMgr',$mgr)
        $script:fuRs.SessionStateProxy.SetVariable('fixErr',[string]$f.Error)
        $script:fuPs=[powershell]::Create();$script:fuPs.Runspace=$script:fuRs
        [void]$script:fuPs.AddScript({
            Import-Module (Join-Path $modDir 'Common.psm1') -Force -ErrorAction SilentlyContinue
            Import-Module (Join-Path $modDir 'SmartDownload.psm1') -Force -ErrorAction SilentlyContinue
            $q=$fuQueue
            $say={param($m) if($q){$q.Enqueue([string]$m)}}
            try {
                if(-not (Get-Command Invoke-SysPilotAutoInstallFix -ErrorAction SilentlyContinue)){ @{Ok=$false;Err='SmartDownload nicht verfuegbar';Fix=$null} }
                else {
                    $fix = Invoke-SysPilotAutoInstallFix -AppName $fixName -AppId $fixId -FailedManager $fixMgr -ErrorText $fixErr -OnProgress $say
                    @{Ok=[bool]$fix.Ok; Fix=$fix}
                }
            } catch { @{Ok=$false;Err=$_.Exception.Message;Fix=$null} }
        })
        $script:fuAsync=$script:fuPs.BeginInvoke()
        $fc.ProgBar.Visibility='Visible';$fc.ProgBar.IsIndeterminate=$true
        $fuPoll.Start()
    }

    $fuPoll = New-Object System.Windows.Threading.DispatcherTimer
    $fuPoll.Interval = [TimeSpan]::FromSeconds(1)
    $fuPoll.Add_Tick({
        if (-not $script:fuAsync) { $fuPoll.Stop(); return }
        & $fuDrain
        if (-not $script:fuAsync.IsCompleted) { return }
        $fuPoll.Stop()
        & $fuDrain
        $kind = [string]$script:fuJobKind
        $res = $null
        try { $res = $script:fuPs.EndInvoke($script:fuAsync) | Select-Object -Last 1 } catch { $res = @{ Ok=$false; Err=$_.Exception.Message } }
        try { $script:fuPs.Dispose(); $script:fuRs.Close(); $script:fuRs.Dispose() } catch { }
        $script:fuPs = $null; $script:fuRs = $null; $script:fuAsync = $null
        $script:fuBusy = $false
        $fc.ProgBar.Visibility = 'Collapsed'; $fc.ProgBar.IsIndeterminate = $false; $fc.ProgBar.Value = 0
        if ($kind -eq 'search') {
            & $showSearchResults $res
            & $setStatus "Suche abgeschlossen - $(@($script:fuResults).Count) Ergebnis(se)." '#FF81C784'
            & $showDetails
            return
        }
        if ($kind -eq 'sync') {
            $removed = $(if ($res) { [int]$res.Removed } else { 0 })
            $names = $(if ($res -and $res.Names) { @($res.Names) -join ', ' } else { '' })
            if ($removed -gt 0) {
                & $setStatus "Auto-Check: $removed erledigte(s) Update(s) entfernt: $names" '#FF81C784'
            } else {
                & $setStatus 'Auto-Check: alle Eintraege stehen noch als Update aus.' '#FF81C784'
            }
            & $loadFailed
            & $showDetails
            return
        }
        if ($kind -eq 'autofix') {
            $selId = [string]$script:fuRetryId; $script:fuRetryId=''
            $fix = $(if($res -and $res.Fix){$res.Fix}else{$null})
            $fc.ProgBar.IsIndeterminate=$false;$fc.ProgBar.Minimum=0;$fc.ProgBar.Maximum=100;$fc.ProgBar.Value=100
            if ($res -and $res.Ok) {
                Remove-SysPilotFailedUpdate -Id $selId
                & $setStatus "Auto-Fix erfolgreich: $($fix.Detail) - Eintrag entfernt." '#FF81C784'
            } else {
                $det = $(if($fix){[string]$fix.Detail}else{[string]$res.Err})
                & $setStatus "Auto-Fix ohne Erfolg: $det" '#FFFFB74D'
                # Herbert-Links als klickbare Ergebnisse anzeigen
                $script:fuResults=@()
                foreach($lk in @($fix.Links)){ $script:fuResults += [pscustomobject]@{Label="[$($lk.Kind)] $($lk.Name)";Url=[string]$lk.Url} }
                $fc.ResultList.Items.Clear()
                foreach($i in $script:fuResults){[void]$fc.ResultList.Items.Add($i)}
                if($script:fuResults.Count){$fc.ResultList.Visibility='Visible';$fc.BtnOpenLink.Visibility='Visible'}
            }
            & $loadFailed; & $showDetails
            return
        }
        $selId = [string]$script:fuRetryId
        $script:fuRetryId = ''
        if ($res -and $res.Ok) {
            Remove-SysPilotFailedUpdate -Id $selId
            & $setStatus 'Update erfolgreich - Eintrag entfernt.' '#FF81C784'
        } else {
            $errTxt = $(if ($res) { [string]$res.Err } else { 'unbekannt' })
            if ($errTxt.Length -gt 120) { $errTxt = $errTxt.Substring(0,120) + '...' }
            & $setStatus "Erneut fehlgeschlagen: $errTxt" '#FFEF5350'
        }
        & $loadFailed
    })

    # --- Suche: alle Paketmanager + Web-Kataloge + Herbert-KI ---
    $showSearchResults = {
        param($res)
        $items = @()
        if ($res -and $res.Pm)   { foreach ($p in @($res.Pm))   { $items += [pscustomobject]@{ Label = "[pm]  $($p.Kind): $($p.Text)"; Url = $p.Url } } }
        if ($res -and $res.Web)  { foreach ($w in @($res.Web))  { $disp = $(if ($w.Version) { $w.Version } elseif ($w.Title) { $w.Title } else { '' }); $items += [pscustomobject]@{ Label = "[web] $($w.Source): $disp - $($w.Note)"; Url = $w.Url } } }
        if ($res -and $res.AiUrl){ foreach ($u in @($res.AiUrl)) { $items += [pscustomobject]@{ Label = "[ki]  Herbert-Fundstelle"; Url = $u } } }
        # Kostenlose Web-KI als Sofort-Ergebnis (immer verfuegbar, auch ohne Provider-Key)
        $sq = [string]$script:fuSearchQuery
        if ($sq) {
            $sqe = [Uri]::EscapeDataString($sq)
            $items += [pscustomobject]@{ Label = '[ki-frei] Perplexity (Websuche, aktuellste Quellen)'; Url = "https://www.perplexity.ai/?q=$sqe" }
            $items += [pscustomobject]@{ Label = '[ki-frei] Duck.ai (kostenlos, kein Login)';            Url = "https://duckduckgo.com/?q=$sqe&ia=chat" }
            $items += [pscustomobject]@{ Label = '[ki-frei] Gemini (Google)';                           Url = "https://gemini.google.com/app?q=$sqe" }
            $items += [pscustomobject]@{ Label = '[ki-frei] Copilot (Microsoft)';                       Url = "https://copilot.microsoft.com/?q=$sqe" }
        }
        $script:fuResults = $items
        $fc.ResultList.Items.Clear()
        foreach ($i in $items) { [void]$fc.ResultList.Items.Add($i) }
        if ($items.Count -gt 0) {
            $fc.ResultList.Visibility = 'Visible'
            $fc.BtnOpenLink.Visibility = 'Visible'
            $fc.ResultList.SelectedIndex = 0
        } else {
            $fc.ResultList.Visibility = 'Collapsed'
            $fc.BtnOpenLink.Visibility = 'Collapsed'
        }
        if ($res -and $res.AiText) {
            Set-SysPilotRichText -RichBox $fc.HerbBox -Text ([string]$res.AiText)
            $fc.HerbBox.Visibility = 'Visible'
        }
        # HerbBox/ResultList wurden nach dem Oeffnen sichtbar -> Fenster nachwachsen lassen
        Set-SysPilotWindowAutoSize -Win $fwin -MinWidth 980 -MinHeight 620
    }

    $startSearch = {
        $w = $fc.FailList.SelectedItem
        if (-not $w -or $script:fuBusy) { return }
        $f = $w.Orig
        $script:fuBusy = $true
        $script:fuJobKind = 'search'
        $script:fuResults = @()
        $script:fuSearchQuery = "$($f.Name) $($f.Id)"
        $script:fuQueue = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
        $script:fuProcPath = ''; $script:fuProcOffset = 0L
        $fc.HerbBox.Document.Blocks.Clear(); $fc.HerbBox.Visibility = 'Collapsed'
        $fc.LogBox.Clear()
        $fc.ResultList.Visibility = 'Collapsed'; $fc.BtnOpenLink.Visibility = 'Collapsed'
        & $showDetails
        & $setStatus "Suche laeuft: $($f.Name) - Paketmanager, Web-Kataloge, Herbert ..." '#FFB0B0C0'
        $script:fuRs = [runspacefactory]::CreateRunspace()
        $script:fuRs.ApartmentState = 'STA'; $script:fuRs.ThreadOptions = 'ReuseThread'
        $script:fuRs.Open()
        $script:fuRs.SessionStateProxy.SetVariable('modDir', $fuModDir)
        $script:fuRs.SessionStateProxy.SetVariable('itemName', [string]$f.Name)
        $script:fuRs.SessionStateProxy.SetVariable('itemId', [string]$f.Id)
        $script:fuRs.SessionStateProxy.SetVariable('itemError', [string]$f.Error)
        $script:fuRs.SessionStateProxy.SetVariable('fuQueue', $script:fuQueue)
        $script:fuPs = [powershell]::Create()
        $script:fuPs.Runspace = $script:fuRs
        [void]$script:fuPs.AddScript({
            Import-Module (Join-Path $modDir 'Common.psm1') -Force -ErrorAction SilentlyContinue
            Import-Module (Join-Path $modDir 'SoftwareUpdateCenter.psm1') -Force
            Import-Module (Join-Path $modDir 'PackageManagers.psm1') -Force -ErrorAction SilentlyContinue
            Import-Module (Join-Path $modDir 'AiAssist.psm1') -Force -ErrorAction SilentlyContinue
            $q = $fuQueue
            $say = { param($m) if ($q) { $q.Enqueue([string]$m) } }
            $query = "$itemName $itemId"
            $errShort = $itemError
            if ($errShort.Length -gt 200) { $errShort = $errShort.Substring(0,200) }

            # Kind-Runspaces parallel starten (PM + Web gleichzeitig)
            $spawn = {
                param([string]$name, [string]$code, [hashtable]$extra)
                $crs = [runspacefactory]::CreateRunspace()
                $crs.ApartmentState = 'STA'; $crs.ThreadOptions = 'ReuseThread'; $crs.Open()
                $vars = @{ modDir=$modDir; fuQueue=$q; query=$query; itemName=$itemName; itemId=$itemId; itemError=$errShort }
                if ($extra) { foreach ($kv in $extra.GetEnumerator()) { $vars[$kv.Key] = $kv.Value } }
                foreach ($kv in $vars.GetEnumerator()) { $crs.SessionStateProxy.SetVariable($kv.Key, $kv.Value) }
                $cps = [powershell]::Create(); $cps.Runspace = $crs
                [void]$cps.AddScript($code)
                @{ Name=$name; Rs=$crs; Ps=$cps; H=$cps.BeginInvoke() }
            }
            $waitAll = {
                param($children)
                foreach ($c in $children) {
                    while (-not $c.H.IsCompleted) { Start-Sleep -Milliseconds 250 }
                    try { $c.Out = @($c.Ps.EndInvoke($c.H)) }
                    catch { $c.Out = @(); if ($q) { $q.Enqueue("[$($c.Name)] Fehler: $($_.Exception.Message)") } }
                    try { $c.Ps.Dispose() } catch {}
                    try { $c.Rs.Close(); $c.Rs.Dispose() } catch {}
                }
            }

            # Phase 1: Paketmanager + Web-Kataloge parallel
            $pmCode = @'
$pm = @()
try {
    Import-Module (Join-Path $modDir 'Common.psm1') -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $modDir 'PackageManagers.psm1') -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $modDir 'SoftwareUpdateCenter.psm1') -Force -ErrorAction SilentlyContinue
    $q = $fuQueue
    $say = { param($m) if ($q) { $q.Enqueue([string]$m) } }
    & $say "Paketmanager: choco/scoop suchen nach '$query' ..."
    $choco = Get-SysPilotChocoExe; $scoop = Get-SysPilotScoopExeLocal
    if ($choco) {
        foreach ($c in @(Find-SysPilotChocoRemoteCandidates -Query $query | Select-Object -First 3)) {
            $pm += [pscustomobject]@{ Kind='choco'; Text="Kandidat '$c' (choco search)"; Url='' }
        }
    } else { & $say 'choco nicht installiert - uebersprungen' }
    if ($scoop) {
        foreach ($c in @(Find-SysPilotScoopRemoteCandidates -Query $query | Select-Object -First 3)) {
            $pm += [pscustomobject]@{ Kind='scoop'; Text="Kandidat '$c' (scoop search)"; Url='' }
        }
    } else { & $say 'scoop nicht installiert - uebersprungen' }
} catch { if ($q) { $q.Enqueue("PM-Suche Fehler: $($_.Exception.Message)") } }
$pm
'@
            $webCode = @'
$web = @()
try {
    Import-Module (Join-Path $modDir 'Common.psm1') -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $modDir 'SoftwareUpdateCenter.psm1') -Force
    Import-Module (Join-Path $modDir 'PackageManagers.psm1') -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $modDir 'SmartDownload.psm1') -Force -ErrorAction SilentlyContinue
    $q = $fuQueue
    $say = { param($m) if ($q) { $q.Enqueue([string]$m) } }
    & $say 'Web-Kataloge: Versionen + Katalog-Suche (Uptodown, FileHorse, Ninite ...) ...'
    $web += @(Get-SysPilotWebSourceVersions -Query $query | Select-Object -First 6)
    $web += @(Find-SysPilotCatalogSearch -Query $query | Select-Object -First 8)
    # Dedupe nach Url
    $seenU = @{}; $webOut = @()
    foreach ($w in $web) {
        $wu = [string]$w.Url
        if ($wu -and -not $seenU.ContainsKey($wu)) { $seenU[$wu] = $true; $webOut += $w }
        elseif (-not $wu) { $webOut += $w }
    }
    # Suchmaschinen (DDG + Bing) mit Score-Vorbewertung
    try {
        & $say 'Suchmaschinen: DDG + Bing (offiziell, Kataloge, neueste Version) ...'
        $queries = @(
            "$query official download",
            "$query latest version windows download",
            "`"$query`" site:majorgeeks.com OR site:uptodown.com OR site:filehorse.com OR site:softpedia.com"
        )
        $hits = @()
        foreach ($qs in $queries) { $hits += @(Find-SysPilotWebResults -Query $qs -MaxPerEngine 5) }
        $scored = @()
        foreach ($h in $hits) {
            $hu = ([string]$h.Url).TrimEnd('/')
            if ($seenU.ContainsKey($hu)) { continue }
            $seenU[$hu] = $true
            $h.Score = Get-SysPilotSmartDlScore -Hit $h -AppName $itemName
            if ($h.Score -ge 0) { $scored += $h }
        }
        foreach ($h in ($scored | Sort-Object Score -Descending | Select-Object -First 8)) {
            $webOut += [pscustomobject]@{ Source="web:$($h.Engine)"; Version=''; Title=$h.Title; Url=$h.Url; Note="Score $($h.Score)"; Best=($h.Score -ge 5) }
        }
    } catch { & $say "Suchmaschinen-Fehler: $($_.Exception.Message)" }
    $webOut | Select-Object -First 18
} catch { if ($q) { $q.Enqueue("Web-Suche Fehler: $($_.Exception.Message)") }; @() }
'@
            & $say "Parallel-Start: Paketmanager + Web-Kataloge fuer '$query' ..."
            $children = @(
                & $spawn 'pm'  $pmCode  $null
                & $spawn 'web' $webCode $null
            )
            & $waitAll $children

            $pm = @(); $web = @()
            foreach ($c in $children) {
                if ($c.Name -eq 'pm')  { $pm  = @($c.Out | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['Kind'] }) }
                if ($c.Name -eq 'web') { $web = @($c.Out | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['Url'] }) }
            }
            if ($pm.Count -eq 0)  { & $say 'Paketmanager: keine Kandidaten gefunden.' }
            else { & $say "Paketmanager: $($pm.Count) Kandidat(en) gefunden." }
            if ($web.Count -eq 0) { & $say 'Web-Kataloge: keine Treffer.' }
            else { & $say "Web-Kataloge: $($web.Count) Treffer." }

            # Phase 2: Herbert-KI bekommt die Funde und bewertet sie
            $aiUrls = @(); $aiText = ''
            $findings = ''
            foreach ($p in $pm)  { $findings += "- [$($p.Kind)] $($p.Text)`n" }
            foreach ($w in $web) { $disp = $(if ($w.Version) { $w.Version } elseif ($w.Title) { $w.Title } else { $w.Source }); $findings += "- [$($w.Source)] $disp -> $($w.Url) ($($w.Note))`n" }
            if (-not $findings) { $findings = '- (keine automatischen Funde)' }
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
    & $say 'Herbert-KI bewertet die Funde und sucht fehlende Links (kann 30-90s dauern) ...'
    $prompt = @"
Du bist Herbert, der Update-Manager-Assistent von SysPilot. Ein Windows-Update ist fehlgeschlagen.
App: $itemName | ID: $itemId
Fehler: $itemError

Automatisch gefundene Kandidaten:
$findings

Aufgabe: Waehle den besten Download-Link (offizielle Quelle bevorzugen),
sonst nenne die beste manuelle Update-Moeglichkeit. Antworte KURZ auf Deutsch:
1. Eine Zeile 'URL: <bester link>' (nur wenn ein echter Download-Link existiert)
2. Optional 1-2 weitere 'URL:'-Zeilen fuer Alternativen
3. Dann 2-3 Saetze Zusammenfassung/A walkthrough auf Deutsch.
"@
    $ai = Invoke-SysPilotAiChat -Prompt $prompt -TimeoutSec 90
    if ($ai.Ok) {
        $aiText = [string]$ai.Text
        foreach ($m in [regex]::Matches($aiText, 'https?://[^\s)"''<>\]]+')) {
            $u = $m.Value.TrimEnd('.',',',';')
            if ($u -notmatch 'perplexity|duckduckgo|gemini|copilot') { $aiUrls += $u }
        }
    } else { & $say "Herbert nicht erreichbar: $($ai.Error)" }
} catch { if ($q) { $q.Enqueue("KI-Suche Fehler: $($_.Exception.Message)") } }
@{ AiUrl=$aiUrls; AiText=$aiText }
'@
            & $say 'Phase 2: Herbert-KI analysiert ...'
            $aiChild = & $spawn 'ki' $aiCode @{ findings=$findings }
            & $waitAll @($aiChild)
            $aiRes = $aiChild.Out | Where-Object { $_ -is [hashtable] -or $_.PSObject.Properties['AiText'] } | Select-Object -First 1
            if ($aiRes) {
                $aiUrls = @($aiRes.AiUrl)
                $aiText = [string]$aiRes.AiText
            }

            & $say 'Suche abgeschlossen.'
            @{ Ok=$true; Pm=$pm; Web=$web; AiUrl=$aiUrls; AiText=$aiText }
        })
        $script:fuAsync = $script:fuPs.BeginInvoke()
        $fc.ProgBar.Visibility = 'Visible'; $fc.ProgBar.IsIndeterminate = $true
        $fuPoll.Start()
    }

    # --- Auto-Check: Eintraege entfernen, deren Update nicht mehr
    #     ansteht (z.B. App manuell aktualisiert) ---
    $startSync = {
        if ($script:fuBusy) { return }
        $script:fuBusy = $true
        $script:fuJobKind = 'sync'
        $script:fuResults = @()
        $script:fuQueue = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
        $script:fuProcPath = ''; $script:fuProcOffset = 0L
        $fc.LogBox.Clear()
        & $setStatus 'Auto-Check: Package-Manager-Listen werden abgefragt ...' '#FFB0B0C0'
        $script:fuRs = [runspacefactory]::CreateRunspace()
        $script:fuRs.ApartmentState = 'STA'; $script:fuRs.ThreadOptions = 'ReuseThread'
        $script:fuRs.Open()
        $script:fuRs.SessionStateProxy.SetVariable('modDir', $fuModDir)
        $script:fuPs = [powershell]::Create()
        $script:fuPs.Runspace = $script:fuRs
        [void]$script:fuPs.AddScript({
            param($modDir)
            Import-Module (Join-Path $modDir 'Common.psm1') -Force -ErrorAction SilentlyContinue
            Import-Module (Join-Path $modDir 'PackageManagers.psm1') -Force -ErrorAction SilentlyContinue
            Import-Module (Join-Path $modDir 'SoftwareUpdateCenter.psm1') -Force
            Sync-SysPilotFailedUpdates
        }).AddArgument($fuModDir)
        $script:fuAsync = $script:fuPs.BeginInvoke()
        $fc.ProgBar.Visibility = 'Visible'; $fc.ProgBar.IsIndeterminate = $true
        $fuPoll.Start()
    }

    # Auto-Start: bei Auswahl eines noch nicht behandelten Eintrags
    # startet der Auto-Fix automatisch (einmalig pro ID/Session)
    $script:fuAutoTried = @{}
    $maybeAutoFix = {
        $w = $fc.FailList.SelectedItem
        if (-not $w -or $script:fuBusy) { return }
        $id = [string]$w.Orig.Id
        if ($script:fuAutoTried.ContainsKey($id)) { return }
        $script:fuAutoTried[$id] = $true
        & $startAutoFix -Auto
    }

    $fc.FilterBox.Add_TextChanged({ & $filterScript })
    $fc.FailList.Add_SelectionChanged({ & $showDetails; & $maybeAutoFix })
    $fc.BtnRefresh.Add_Click({ & $startSync })
    $fc.BtnClose.Add_Click({ $fwin.Close() })
    $fc.BtnSilent.Add_Click({ & $startRetry 'silent' })
    $fc.BtnAdmin.Add_Click({ & $startRetry 'admin' })
    $fc.BtnManual.Add_Click({
        $w = $fc.FailList.SelectedItem
        if (-not $w) { return }
        $f = $w.Orig
        Open-SysPilotManualUpdateTerminal -Rows @($f)
    })
    $fc.BtnSearch.Add_Click({ & $startSearch })
    $fc.BtnAutoFix.Add_Click({ & $startAutoFix })
    $fc.BtnOpenLink.Add_Click({
        $i = $fc.ResultList.SelectedIndex
        if ($i -lt 0 -or $i -ge $script:fuResults.Count) { return }
        $u = [string]$script:fuResults[$i].Url
        if ($u) { Start-Process $u } else { & $setStatus 'Dieses Ergebnis hat keinen Direktlink - siehe Protokoll.' '#FFFFB74D' }
    })
    $fc.ResultList.Add_MouseDoubleClick({
        $i = $fc.ResultList.SelectedIndex
        if ($i -lt 0 -or $i -ge $script:fuResults.Count) { return }
        $u = [string]$script:fuResults[$i].Url
        if ($u) { Start-Process $u }
    })
    $fc.BtnRemove.Add_Click({
        $w = $fc.FailList.SelectedItem
        if (-not $w) { return }
        $f = $w.Orig
        $r = [System.Windows.MessageBox]::Show("Eintrag '$($f.Name)' entfernen?`n(Wird nicht mehr in der Liste angezeigt)", 'Fehlgeschlagene Updates', 'YesNo', 'Question')
        if ($r -ne 'Yes') { return }
        Remove-SysPilotFailedUpdate -Id ([string]$f.Id)
        & $loadFailed
    })
    $fc.BtnNaRemove.Add_Click({
        $st = Read-SysPilotUpdateState
        $hopeless = @($st.Failed | Where-Object { $_.Kind -in @('not-applicable','publisher') })
        if ($hopeless.Count -eq 0) { & $setStatus 'Keine nicht-anwendbaren Eintraege vorhanden.' '#FFB0B0C0'; return }
        $r = [System.Windows.MessageBox]::Show("$($hopeless.Count) Eintraege entfernen?`n(winget kann diese Apps prinzipiell nicht aktualisieren - nur manuell/installierbar)", 'Fehlgeschlagene Updates', 'YesNo', 'Question')
        if ($r -ne 'Yes') { return }
        $st.Failed = @($st.Failed | Where-Object { $_.Kind -notin @('not-applicable','publisher') })
        Write-SysPilotUpdateState $st
        & $setStatus "$($hopeless.Count) Eintraege entfernt." '#FF81C784'
        & $loadFailed
    })
    $fwin.Add_Closing({
        $fuPoll.Stop()
        if ($script:fuAsync) {
            try { $script:fuPs.Stop(); $script:fuPs.Dispose(); $script:fuRs.Close(); $script:fuRs.Dispose() } catch { }
            $script:fuPs = $null; $script:fuRs = $null; $script:fuAsync = $null
        }
    })
    & $loadFailed
    Set-SysPilotWindowAutoSize -Win $fwin -MinWidth 980 -MinHeight 620
    # Auto-Check im Hintergrund: entfernt Eintraege, deren Update
    # inzwischen erledigt ist (z.B. App manuell aktualisiert)
    & $startSync
    Add-SysPilotAssistantToWindow -Win $fwin -Context 'Show-SysPilotFailedUpdatesWindow'
    [void]$fwin.ShowDialog()
}

function Show-SysPilotUpdateCenterWindow {
    <# WPF-Update-Center: Scan (winget+choco+scoop+pm), Multi-Select-
       Updates silent, Katalog-Tab (winget/GitHub/KI-Suche/Seite),
       SmartDownload-Suche, Auto-Update-Schalter, Live-Log.
       Laengere Aktionen laufen in Hintergrund-Runspaces mit
       Queue-Log + Proc-Log-Tail. Fallback: Konsolen-Menue. #>
    try {
        Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase -ErrorAction Stop
        if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'kein STA' }
    } catch {
        Show-SysPilotUpdateCenter
        return
    }
    # Single-Instance: der State ($fc.ucRows, ucObjQ, ucBusy, ...) ist
    # modul-global. Ein zweites Fenster wuerde ihn zuruecksetzen, waehrend
    # das erste noch laeuft (z.B. "ALLE: 1 Update" statt aller Zeilen).
    if ($script:ucWindow -and $script:ucWindow.IsLoaded) {
        try { $script:ucWindow.Activate() } catch {}
        return
    }
    $pxaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="SysPilot - Softwarecenter" Width="1060" Height="720"
        WindowStartupLocation="CenterScreen" ResizeMode="CanResizeWithGrip"
        Background="#FF1E1E2E" Foreground="#FFE0E0E0">
  <Window.Resources>
    <Style TargetType="Button"><Setter Property="Background" Value="#FF2D2D44"/><Setter Property="Foreground" Value="#FFE0E0E0"/><Setter Property="BorderBrush" Value="#FF4A4A6A"/><Setter Property="Padding" Value="10,4"/><Setter Property="Margin" Value="3"/><Setter Property="Cursor" Value="Hand"/></Style>
    <Style TargetType="ListViewItem"><Setter Property="Padding" Value="7,4"/><Setter Property="Foreground" Value="#FFEAEAF2"/><Setter Property="FontSize" Value="12"/><Setter Property="HorizontalContentAlignment" Value="Stretch"/><Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#FF34344E"/></Trigger><Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#CCE4EAF2"/><Setter Property="Foreground" Value="#FF1E1E2E"/></Trigger></Style.Triggers></Style>
    <Style TargetType="GridViewColumnHeader"><Setter Property="Background" Value="#FF2D2D44"/><Setter Property="Foreground" Value="#FF4FC3F7"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Padding" Value="8,5"/><Setter Property="BorderBrush" Value="#FF4A4A6A"/><Setter Property="BorderThickness" Value="0,0,1,1"/></Style>
    <Style TargetType="ListBoxItem"><Setter Property="Padding" Value="5,3"/><Setter Property="Foreground" Value="#FFD8E8D8"/><Setter Property="FontSize" Value="11"/><Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#FF2A3A2A"/></Trigger><Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#CCE4EAF2"/><Setter Property="Foreground" Value="#FF1B1B28"/></Trigger></Style.Triggers></Style>
    <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#FFE0E0E0"/></Style>
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
      <TextBox x:Name="FilterBox" Width="230" ToolTip="Suchen: Name, ID oder Quelle (filtert Updates + Store)"/>
      <Button x:Name="BtnScan" Content="Scan" ToolTip="winget + Chocolatey + scoop parallel nach Updates suchen"/>
      <Button x:Name="BtnAutoAll" Content="Alle aktualisieren" ToolTip="Alle gefundenen Updates silent installieren"/>
      <Button x:Name="BtnAutoTask" Content="Auto-Update" ToolTip="Taegliche geplante Aufgabe an/aus"/>
      <Button x:Name="BtnFailed" Content="Fehlgeschlagene" ToolTip="Fenster mit fehlgeschlagenen Updates"/>
      <Button x:Name="BtnMore" Content="Mehr &#9662;" ToolTip="DL-Manager, volle App-Suche, App Store, Konsolen-Menue"/>
      <Button x:Name="BtnClose" Content="Schliessen" HorizontalAlignment="Right"/>
    </StackPanel>
    <Border DockPanel.Dock="Bottom" Background="#FF16161F" BorderBrush="#FF4A4A6A" BorderThickness="0,1,0,0" Padding="8,6">
      <StackPanel>
        <ProgressBar x:Name="ProgBar" Height="7" IsIndeterminate="False" Minimum="0" Maximum="100" Value="0" Visibility="Collapsed" Margin="0,0,0,6" Foreground="#FF4FC3F7" Background="#FF2A2A3A"/>
        <Grid Margin="0,0,0,4">
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <ListBox x:Name="ResultList" Grid.Column="0" Height="56" Visibility="Collapsed" Background="#FF101018" BorderThickness="0" DisplayMemberPath="Label" ToolTip="KI-Suchergebnisse - Doppelklick oder Button oeffnet den Link"/>
          <Button x:Name="BtnOpenLink" Grid.Column="1" Content="Link&#10;oeffnen" Visibility="Collapsed" Margin="5,0,0,0" VerticalAlignment="Stretch" ToolTip="Oeffnet die URL des markierten Treffers"/>
        </Grid>
        <RichTextBox x:Name="HerbBox" Height="100" IsReadOnly="True" Visibility="Collapsed"
                     Background="#FF101018" Foreground="#FFEAEAF2" BorderBrush="#FF2E4A2E"
                     FontFamily="Segoe UI" FontSize="12" Padding="8,6" Margin="0,6,0,0"
                     VerticalScrollBarVisibility="Auto" ToolTip="Herbert-Antwort - URLs sind klickbar"/>
        <TextBox x:Name="LogBox" Height="100" IsReadOnly="True" TextWrapping="NoWrap" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="11" Background="#FF0C0C14" Foreground="#FF9FE89F" BorderThickness="0" ToolTip="Live-Protokoll - Rechtsklick = kopieren"/>
        <TextBlock x:Name="StatusText" FontSize="11" Foreground="#FF9E9E9E" Margin="0,5,0,0" TextWrapping="Wrap"/>
      </StackPanel>
    </Border>
    <TabControl Background="Transparent" BorderThickness="0">
      <TabItem Header="Verfuegbare Updates">
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="3*"/><ColumnDefinition Width="*" MinWidth="300"/></Grid.ColumnDefinitions>
          <ListView x:Name="UpdList" SelectionMode="Extended" Background="#FF252538" BorderThickness="0">
            <ListView.View><GridView>
              <GridViewColumn Header="" Width="30">
                <GridViewColumn.CellTemplate>
                  <DataTemplate>
                    <CheckBox IsChecked="{Binding Checked, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" VerticalAlignment="Center" ToolTip="Für Updates vormerken"/>
                  </DataTemplate>
                </GridViewColumn.CellTemplate>
              </GridViewColumn>
              <GridViewColumn Header="Programm" Width="200" DisplayMemberBinding="{Binding Name}"/>
              <GridViewColumn Header="Installiert" Width="90" DisplayMemberBinding="{Binding Installed}"/>
              <GridViewColumn Header="Verfuegbar" Width="90" DisplayMemberBinding="{Binding Available}"/>
              <GridViewColumn Header="Quelle" Width="80" DisplayMemberBinding="{Binding Source}"/>
              <GridViewColumn Header="Status" Width="120" DisplayMemberBinding="{Binding StatusText}"/>
            </GridView></ListView.View>
          </ListView>
          <Border Grid.Column="1" Background="#FF252538" CornerRadius="6" Padding="12" Margin="10,0,0,0">
            <DockPanel>
              <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,10,0,0">
                <Button x:Name="BtnUpdSel" Content="Auswahl aktualisieren" ToolTip="Ausgewaehlte Updates installieren (Ctrl/Shift = Mehrfachauswahl)"/>
                <Button x:Name="BtnUpdSearch" Content="SmartDownload-Suche" ToolTip="KI-Pseudo-Paketmanager: Download-Links + Herbert fuer die Auswahl"/>
                <Button x:Name="BtnPrefs" Content="Prefs" ToolTip="Update-Modus/Admin pro App oder global einstellen"/>
              </StackPanel>
              <StackPanel>
                <TextBlock Text="Modus:" FontSize="11" Foreground="#FF9E9E9E"/>
                <ComboBox x:Name="ModusBox" Margin="0,2,0,8" SelectedIndex="0" ToolTip="silent = ohne Rueckfrage, interaktiv = Installer zeigt UI">
                  <ComboBoxItem Content="silent (empfohlen)" Tag="silent" IsSelected="True"/>
                  <ComboBoxItem Content="interaktiv (UI sichtbar)" Tag="interaktiv"/>
                </ComboBox>
                <TextBlock Text="Ausgewaehlt:" FontSize="11" Foreground="#FF9E9E9E"/>
                <TextBlock x:Name="DCount" FontSize="13" FontWeight="Bold" Foreground="#FF4FC3F7" Margin="0,2,0,8"/>
                <TextBlock Text="Hinweis:" FontSize="11" Foreground="#FF9E9E9E"/>
                <TextBlock x:Name="DHint" FontSize="11" Foreground="#FFFFB74D" TextWrapping="Wrap" Margin="0,2,0,0"/>
              </StackPanel>
            </DockPanel>
          </Border>
        </Grid>
      </TabItem>
      <TabItem Header="Store &amp; Downloads (Megastore)">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
            <TextBox x:Name="StoreQuery" Width="260" ToolTip="Programm/App suchen - winget remote + Katalog + SmartDownload/Web"/>
            <Button x:Name="BtnStoreSearch" Content="Suchen" ToolTip="Sucht parallel in winget, lokalem Katalog und SmartDownload/Web-Quellen"/>
            <Button x:Name="BtnStoreInstall" Content="Installieren" ToolTip="Abgehakte Treffer installieren (Mehrfachauswahl per Haeckchen); ohne Haken: markierte Zeile"/>
            <Button x:Name="BtnStoreDl" Content="SmartDL" ToolTip="SmartDownload-Suche + Herbert-Empfehlung fuer den Treffer"/>
            <Button x:Name="BtnStorePage" Content="Seite" ToolTip="Offizielle Seite im Browser oeffnen"/>
            <Button x:Name="BtnStoreAll" Content="Alle haken" ToolTip="Alle sichtbaren Treffer per Haeckchen vormerken"/>
            <Button x:Name="BtnStoreNone" Content="Haken leeren" ToolTip="Alle Haekchen entfernen"/>
            <Button x:Name="BtnStoreMega" Content="Megastore" ToolTip="App Store (Megastore): lokaler Index aus PMs, Katalogen, GitHub/GitLab und Web-Portalen - kategorisiert, OS-Filter, installierbar" FontWeight="Bold"/>
          </StackPanel>
          <ListView x:Name="StoreList" Grid.Row="1" SelectionMode="Extended" Background="#FF252538" BorderThickness="0">
            <ListView.View><GridView>
              <GridViewColumn Header="" Width="30">
                <GridViewColumn.CellTemplate>
                  <DataTemplate>
                    <CheckBox IsChecked="{Binding Checked, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" VerticalAlignment="Center" ToolTip="Für Installation vormerken"/>
                  </DataTemplate>
                </GridViewColumn.CellTemplate>
              </GridViewColumn>
              <GridViewColumn Header="Name" Width="230" DisplayMemberBinding="{Binding Name}"/>
              <GridViewColumn Header="Typ" Width="90" DisplayMemberBinding="{Binding Typ}"/>
              <GridViewColumn Header="Installiert" Width="110" DisplayMemberBinding="{Binding InstText}"/>
              <GridViewColumn Header="Quellen" Width="140" DisplayMemberBinding="{Binding SrcText}"/>
              <GridViewColumn Header="Detail" Width="330" DisplayMemberBinding="{Binding Detail}"/>
            </GridView></ListView.View>
          </ListView>
        </Grid>
      </TabItem>
      <TabItem Header="Web-Quellen">
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="3*"/><ColumnDefinition Width="*" MinWidth="300"/></Grid.ColumnDefinitions>
          <ListView x:Name="WebList" SelectionMode="Single" Background="#FF252538" BorderThickness="0">
            <ListView.View><GridView>
              <GridViewColumn Header="Portal" Width="180" DisplayMemberBinding="{Binding Name}"/>
              <GridViewColumn Header="Art" Width="110" DisplayMemberBinding="{Binding ArtText}"/>
              <GridViewColumn Header="Beschreibung" Width="330" DisplayMemberBinding="{Binding DescText}"/>
            </GridView></ListView.View>
          </ListView>
          <Border Grid.Column="1" Background="#FF252538" CornerRadius="6" Padding="12" Margin="10,0,0,0">
            <DockPanel>
              <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,10,0,0">
                <Button x:Name="BtnWebOpen" Content="Oeffnen" ToolTip="Portal im Browser oeffnen"/>
                <Button x:Name="BtnWebVer" Content="Versionen suchen" ToolTip="Versionen in automatisierten Quellen (Ninite/MajorGeeks/Uptodown/FOSSHub)"/>
                <Button x:Name="BtnWebVerAll" Content="Alle Quellen" ToolTip="Versions-Check inkl. manueller Portale (Links)"/>
                <Button x:Name="BtnWebRss" Content="RSS-Center" ToolTip="RSS-Feed-Center: Interessengebiete waehlen, 1400+ Feeds sortiert, OPML-Export, Miniflux-API-Import"/>
              </StackPanel>
              <StackPanel>
                <TextBlock Text="Portal:" FontSize="11" Foreground="#FF9E9E9E"/>
                <TextBlock x:Name="WName" FontSize="13" FontWeight="Bold" Foreground="#FF4FC3F7" Margin="0,2,0,8" TextWrapping="Wrap"/>
                <TextBlock x:Name="WInfo" FontSize="11" Foreground="#FF9E9E9E" TextWrapping="Wrap"/>
              </StackPanel>
            </DockPanel>
          </Border>
        </Grid>
      </TabItem>
    </TabControl>
  </DockPanel>
</Window>
"@
    $ucw = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$pxaml)))
    $script:ucWindow = $ucw
    $fc = @{}
    foreach ($n in 'UpdList','StoreList','WebList','FilterBox','BtnScan','BtnAutoAll','BtnAutoTask','BtnFailed','BtnClose','BtnUpdSel','BtnUpdSearch','BtnPrefs','ModusBox','BtnWebOpen','BtnWebVer','BtnWebVerAll','BtnWebRss','BtnMore','StoreQuery','BtnStoreSearch','BtnStoreInstall','BtnStoreDl','BtnStorePage','BtnStoreAll','BtnStoreNone','BtnStoreMega','DCount','DHint','WName','WInfo','StatusText','ProgBar','LogBox','ResultList','BtnOpenLink','HerbBox') {
        $fc[$n] = $ucw.FindName($n)
    }
    $fc.ucRows = @(); $fc.ucStoreRows = @(); $fc.ucStoreRemote = @(); $fc.ucBusy = $false
    $fc.ucQueue = New-Object 'System.Collections.Generic.Queue[object]'
    $fc.ucProgGoal = 0; $fc.ucProgFloor = 0; $fc.ucJobT0 = $null; $fc.ucCurLabel = $null
    $fc.ucLogQ = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    $fc.ucObjQ  = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $fc.ucProcPath = ''; $fc.ucProcOffset = 0L
    $setStatus = { param($t,$col) $fc.StatusText.Text = $t; $fc.StatusText.Foreground = [Windows.Media.BrushConverter]::new().ConvertFrom($col) }
    $ucModDir = Split-Path -Parent $PSCommandPath

    $ucLog = {
        param([string]$line)
        if (-not $line) { return }
        $fc.LogBox.AppendText($line + "`n")
        try { $fc.LogBox.ScrollToEnd() } catch { }
        if ($fc.LogBox.Text.Length -gt 120000) { $fc.LogBox.Text = $fc.LogBox.Text.Substring($fc.LogBox.Text.Length - 60000) }
        # Live-Fortschritt direkt aus Job-Markerzeilen ableiten:
        # "=== [i/n] name ===" = Programm i von n gestartet.
        # Robust gegen ucObjQ-Probleme - die Queue ist deryne
        # Primaerpfad, dies hier ist die sicher sichtbare Anzeige.
        if ($line -match '=== \[(\d+)/(\d+)\]\s*(.+?)\s*===') {
            try {
                $pi = [int]$Matches[1]; $pt = [int]$Matches[2]; $pn = $Matches[3]
                if ($pt -gt 0) {
                    $fc.ProgBar.Visibility = 'Visible'
                    $fc.ProgBar.IsIndeterminate = $false
                    $fc.ProgBar.Minimum = 0; $fc.ProgBar.Maximum = $pt
                    $fc.ProgBar.Value = [Math]::Max(0, $pi - 1)
                    $fc.ucProgGoal = $pi
                    $fc.ucCurLabel = "Update $pi/$pt`: $pn"
                    & $setStatus $fc.ucCurLabel '#FFB0B0C0'
                }
            } catch { }
        }
    }
    $ucTailProc = {
        try {
            $logs = Get-ChildItem (Join-Path $env:TEMP 'syspilot-proc-*.log') -File -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -gt (Get-Date).AddSeconds(-30) } |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if (-not $logs) { return }
            if ($logs.FullName -ne $fc.ucProcPath) { $fc.ucProcPath = $logs.FullName; $fc.ucProcOffset = 0L }
            $len = $logs.Length
            if ($len -le $fc.ucProcOffset) { return }
            $fs = [IO.File]::Open($logs.FullName,'Open','Read','ReadWrite')
            try { $fs.Seek($fc.ucProcOffset,'Begin')|Out-Null; $sr=New-Object IO.StreamReader($fs); $chunk=$sr.ReadToEnd() } finally { $fs.Close() }
            $fc.ucProcOffset = $len
            foreach ($l in ($chunk -split "`r?`n")) { & $ucLog $l }
        } catch { }
    }
    $ucDrain = {
        $line = $null
        while ($fc.ucLogQ.TryDequeue([ref]$line)) { if ($line) { & $ucLog ">> $line" }; $line=$null }
        $obj = $null
        # Ein einzelnes defektes Objekt darf die Queue nicht blockieren
        while ($fc.ucObjQ.TryDequeue([ref]$obj)) { if ($obj) { try { & $ucApplyObj $obj } catch {} }; $obj=$null }
        & $ucTailProc
        # Haekchen-Zustand live im Detail-Panel anzeigen
        try { if ($updSelInfo) { & $updSelInfo } } catch {}
        # Sanftes Auffuellen des Balkens bis knapp unter das naechste Ziel
        # + Live-Prozentanzeige in der Statuszeile (jede Drain-Runde)
        try {
            if ($fc.ucBusy -and -not $fc.ProgBar.IsIndeterminate -and $fc.ProgBar.Visibility -eq 'Visible') {
                $goal = [double]$(if($null -ne $fc.ucProgGoal){$fc.ucProgGoal}else{0})
                $cur  = [double]$fc.ProgBar.Value
                $cap  = $goal - 0.15
                if ($cap -gt $cur) { $fc.ProgBar.Value = [Math]::Min($cap, $cur + ($cap - $cur) * 0.04 + 0.02) }
                if ($fc.ucCurLabel) {
                    $pct = [int][Math]::Round($fc.ProgBar.Value / [Math]::Max(1.0,[double]$fc.ProgBar.Maximum) * 100)
                    $el  = ''
                    if ($fc.ucJobT0) { try { $el = ' - ' + ((Get-Date) - $fc.ucJobT0).ToString('mm\:ss') } catch {} }
                    $fc.StatusText.Text = "$($fc.ucCurLabel)  [$pct%]$el"
                }
            }
        } catch {}
    }

    # --- Hintergrund-Job-Start (Runspace + Queue) ---
    $fc.ucRs = $null; $fc.ucPs = $null; $fc.ucAsync = $null; $fc.ucJobKind=''
    $startJob = {
        param([string]$code, [hashtable]$vars)
        $fc.ucJobKind = ''
        try {
        $fc.ucLogQ = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
        $fc.ucObjQ  = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $fc.ucProcPath=''; $fc.ucProcOffset=0L
        $fc.ucRs = [runspacefactory]::CreateRunspace()
        # UseNewThread: ReuseThread kann die Pipeline auf einem von anderen
        # Runspaces (Index-Rebuild, SmartDL) blockierten STA-Pool-Thread queuen
        # - dann läuft der Job nie, obwohl BeginInvoke ok meldet.
        $fc.ucRs.ApartmentState='STA'; $fc.ucRs.ThreadOptions='UseNewThread'; $fc.ucRs.Open()
        $fc.ucRs.SessionStateProxy.SetVariable('modDir', $ucModDir)
        $fc.ucRs.SessionStateProxy.SetVariable('ucLogQ', $fc.ucLogQ)
        $fc.ucRs.SessionStateProxy.SetVariable('ucObjQ',  $fc.ucObjQ)
        foreach ($kv in $vars.GetEnumerator()) { $fc.ucRs.SessionStateProxy.SetVariable($kv.Key, $kv.Value) }
        $fc.ucPs = [powershell]::Create(); $fc.ucPs.Runspace=$fc.ucRs
        [void]$fc.ucPs.AddScript($code)
        $fc.ucAsync = $fc.ucPs.BeginInvoke()
        } catch {
            & $ucLog "Job-Start fehlgeschlagen: $($_.Exception.Message)"
            $fc.ucBusy = $false
            try { if ($fc.ucPs) { $fc.ucPs.Dispose() }; if ($fc.ucRs) { $fc.ucRs.Close(); $fc.ucRs.Dispose() } } catch {}
            $fc.ucPs=$null; $fc.ucRs=$null; $fc.ucAsync=$null
            $fc.ProgBar.Visibility='Collapsed'; $fc.ProgBar.IsIndeterminate=$false
            return
        }
        $fc.ucJobT0 = Get-Date
        $fc.ucProgGoal = 0; $fc.ucProgFloor = 0; $fc.ucCurLabel = $null
        $fc.ProgBar.Value=0; $fc.ProgBar.Visibility='Visible'; $fc.ProgBar.IsIndeterminate=$true
    }
    $finishJob = {
        $fc.ucBusy = $false
        # Balken endet bei 100% und bleibt sichtbar bis zum naechsten Job
        $fc.ucCurLabel=$null
        $fc.ProgBar.IsIndeterminate=$false; $fc.ProgBar.Minimum=0; $fc.ProgBar.Maximum=100; $fc.ProgBar.Value=100
        try {
            if ($fc.ucAsync) {
                $res = @($fc.ucPs.EndInvoke($fc.ucAsync))
                foreach ($o in $res) { if ($o) { & $ucApplyObj $o } }
            }
        } catch { & $ucLog "Job-Fehler: $($_.Exception.Message)" }
        try { $fc.ucPs.Dispose() } catch {}
        try { $fc.ucRs.Close(); $fc.ucRs.Dispose() } catch {}
        $fc.ucPs=$null; $fc.ucRs=$null; $fc.ucAsync=$null
    }

    # ===== Job-Warteschlange =====
    # Klicks waehrend eines laufenden Jobs werden mit Label+Code+Vars
    # eingereiht (Parameter werden beim Klick aufgeloest - kein Closed-over-
    # State). Der Poll-Timer startet bei freiem ucBusy den naechsten Eintrag.
    $ucEnqueue = {
        param([string]$label, [string]$code, [hashtable]$vars, [string]$status)
        foreach ($it in $fc.ucQueue) { if ($it.Label -eq $label) { & $setStatus "Bereits in Warteschlange: $label" '#FFFFB74D'; return } }
        $item = [pscustomobject]@{ Label=$label; Code=$code; Vars=$vars; Status=$status }
        if ($fc.ucBusy) {
            $fc.ucQueue.Enqueue($item)
            & $ucLog ">> Warteschlange ($($fc.ucQueue.Count)): $label"
            & $setStatus "Warteschlange: $($fc.ucQueue.Count) Aktion(en) - '$label' wartet." '#FFFFB74D'
            return
        }
        & $ucPumpItem $item
    }
    $ucPumpItem = {
        param($item)
        & $ucLog "--- $($item.Label) ---"
        $fc.ucBusy = $true
        try { & $startJob $item.Code $item.Vars }
        catch {
            & $ucLog "Job-Start fehlgeschlagen: $($_.Exception.Message)"
            $fc.ucBusy = $false
            $fc.ProgBar.Visibility='Collapsed'; $fc.ProgBar.IsIndeterminate=$false
        }
        if ($item.Status) {
            $fc.StatusText.Text = [string]$item.Status
            $fc.StatusText.Foreground = [Windows.Media.BrushConverter]::new().ConvertFrom('#FFB0B0C0')
        }
    }
    $ucPumpNext = {
        if ($fc.ucBusy -or $fc.ucQueue.Count -eq 0) { return }
        & $ucPumpItem $fc.ucQueue.Dequeue()
    }

    # Scan-Job: parallele Einzel-Jobs pro Paketmanager-Quelle (eigenstaendige
    # Prozesse -> winget/choco/scoop laufen gleichzeitig, nicht mehr seriell)
    $scanCode = @'
Import-Module (Join-Path $modDir 'Common.psm1') -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $modDir 'SoftwareUpdateCenter.psm1') -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $modDir 'PackageManagers.psm1') -Force -ErrorAction SilentlyContinue
$q=$ucLogQ; $oq=$ucObjQ
$say={param($m) if($q){$q.Enqueue([string]$m)}}
& $say 'Starte parallele Scans: winget + chocolatey + scoop/pm ...'

$mkWinget = { param($md)
    Import-Module (Join-Path $md 'Common.psm1') -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $md 'SoftwareUpdateCenter.psm1') -Force -ErrorAction SilentlyContinue
    try { return @(Get-SysPilotWingetUpgrades) } catch { return @() }
}
$mkChoco = { param($md)
    Import-Module (Join-Path $md 'Common.psm1') -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $md 'SoftwareUpdateCenter.psm1') -Force -ErrorAction SilentlyContinue
    try { return @(Get-SysPilotChocoOutdated) } catch { return @() }
}
$mkPm = { param($md)
    Import-Module (Join-Path $md 'Common.psm1') -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $md 'SoftwareUpdateCenter.psm1') -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $md 'PackageManagers.psm1') -Force -ErrorAction SilentlyContinue
    if (Get-Command Get-SysPilotPmOutdated -ErrorAction SilentlyContinue) {
        try {
            $pmRows = @(Get-SysPilotPmOutdated)
            # Abdeckungs-Info als markierte Zeile mitschicken (wird im
            # Scan-Loop als Logzeile angezeigt, nicht als Update-Zeile)
            if (Get-Command Get-SysPilotPmCoverage -ErrorAction SilentlyContinue) {
                Write-Output ("COVERAGE|" + (Get-SysPilotPmCoverage))
            }
            return $pmRows
        } catch { return @() }
    }
    return @()
}

$jobs = @()
$jobs += Start-Job -Name 'winget'  -ScriptBlock $mkWinget -ArgumentList $modDir
$jobs += Start-Job -Name 'choco'   -ScriptBlock $mkChoco  -ArgumentList $modDir
$jobs += Start-Job -Name 'scoop-pm'-ScriptBlock $mkPm     -ArgumentList $modDir
& $say 'Laeuft: winget (source-update + upgrade-Liste), chocolatey, scoop/pm - parallel.'

$rows=@(); $deadline=(Get-Date).AddSeconds(480)
$doneN=0; $totN=3
$seen=@{}
while ($jobs.Count -gt 0 -and (Get-Date) -lt $deadline) {
    $done = @($jobs | Where-Object { $_.State -in @('Completed','Failed','Stopped') })
    foreach ($d in $done) {
        $jobs = @($jobs | Where-Object { $_.Id -ne $d.Id })
        $got = @(Receive-Job $d -ErrorAction SilentlyContinue)
        # Markierte Sonderzeilen (z.B. PM-Abdeckung) loggen, nicht als Rows behandeln
        foreach ($gl in @($got | Where-Object { $_ -is [string] -and $_ -like 'COVERAGE|*' })) {
            & $say ("[pm] " + ($gl -replace '^COVERAGE\|',''))
        }
        $newRows = @($got | Where-Object { -not ($_ -is [string] -and $_ -like 'COVERAGE|*') })
        $rows += $newRows
        # Progressive Anzeige: jede neue unique Row sofort an die UI
        foreach ($r in $newRows) {
            $k = [string]$r.Id
            if (-not $seen.ContainsKey($k)) { $seen[$k]=1; $oq.Enqueue([pscustomobject]@{Type='row';Row=$r}) }
        }
        $doneN++
        $oq.Enqueue([pscustomobject]@{Type='prog';Idx=$doneN;Total=$totN;Name=[string]$d.Name;Kind='Scan'})
        & $say ("[{0}] {1} Update(s) gefunden" -f $d.Name, @($got).Count)
        Remove-Job $d -Force -ErrorAction SilentlyContinue
    }
    if ($jobs.Count -gt 0) { Start-Sleep -Milliseconds 400 }
}
foreach ($j in $jobs) {
    $doneN++
    $oq.Enqueue([pscustomobject]@{Type='prog';Idx=$doneN;Total=$totN;Name=[string]$j.Name;Kind='Scan'})
    & $say ("[{0}] Timeout nach 480s - uebersprungen" -f $j.Name)
    Stop-Job $j -ErrorAction SilentlyContinue; Remove-Job $j -Force -ErrorAction SilentlyContinue
}
$uniq=@($seen.Keys | ForEach-Object { $rows | Where-Object { [string]$_.Id -eq $_ } | Select-Object -First 1 })
& $say "Scan fertig: $($uniq.Count) Updates insgesamt."
'@
    $fc.ucScanCode = $scanCode

    # Update-Job (Auswahl silent)
    $updCode = @'
$q=$ucLogQ; $oq=$ucObjQ
$say={param($m) $t=[string]$m; if($q){$q.Enqueue($t)}; try{Add-Content -LiteralPath "$env:TEMP\syspilot-updjob.log" -Value $t -Encoding UTF8}catch{}}
try{Remove-Item "$env:TEMP\syspilot-updjob.log" -Force -ErrorAction SilentlyContinue}catch{}
# Heartbeat SOFORT - beweist, dass der Runspace lebt, bevor Imports laufen
& $say "Update-Job gestartet - initialisiere ..."
try {
Import-Module (Join-Path $modDir 'Common.psm1') -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $modDir 'SoftwareUpdateCenter.psm1') -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $modDir 'PackageManagers.psm1') -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $modDir 'SmartDownload.psm1') -Force -ErrorAction SilentlyContinue
& $say "Module geladen - beginne Update-Lauf ..."
} catch { & $say "Import-Fehler: $($_.Exception.Message)" }
$sel=@($selRows)
$mode=[string]$updMode
if (-not $mode) { $mode='silent' }
$okN=0;$failN=0;$idx=0;$tot=@($sel).Count
& $say "Verarbeite $tot Programm(e) im Modus [$mode]"
foreach($row in $sel){
    $idx++
    $nm=[string]$row.Name; $id=[string]$row.Id; $src=[string]$row.Source
    $oq.Enqueue([pscustomobject]@{Type='prog';Idx=$idx;Total=$tot;Name=$nm;Kind='Update'})
    & $say "=== [$idx/$tot] $nm ($id) [$src] ==="
    $ok=$false;$err=''
    try {
        if ($mode -eq 'interaktiv' -and $src -ne 'chocolatey' -and $src -notlike 'pm:*') {
            # Interaktiv: winget sichtbar in eigenem Fenster, Exit-Code pruefen
            $wexe = Get-SysPilotWingetExe
            if ($wexe) {
                & $say "starte sichtbares winget upgrade $id ..."
                $p = Start-Process -FilePath $wexe -ArgumentList @('upgrade','--id',$id,'--exact','--accept-package-agreements','--accept-source-agreements') -Wait -PassThru
                $ok = ($p.ExitCode -eq 0); if(-not $ok){$err="ExitCode $($p.ExitCode)"}
            } else { $err='winget nicht gefunden' }
        }
        else {
            if ($src -eq 'chocolatey') { $cr=Invoke-SysPilotChocoUpgradeAuto -Pkg $id -Quiet; $ok=[bool]$cr.Ok;$err=[string]$cr.Error }
            elseif ($src -like 'pm:*') { $pr=Invoke-SysPilotPmUpgrade -Row $row; $ok=[bool]$pr.Ok;$err=[string]$pr.Error }
            else { $r=Invoke-SysPilotWingetUpdateAuto -Row $row -Silent -TimeoutSec 900 -AllowElevated -Quiet; $ok=[bool]$r.Ok;$err=[string]$r.Error }
        }
    } catch { $err=$_.Exception.Message }
    if($ok){$okN++;& $say "[OK] $nm";$oq.Enqueue([pscustomobject]@{Type='upd';Id=$id;Ok=$true})}
    else{
        $failN++;& $say "[FAIL] $nm : $err";$oq.Enqueue([pscustomobject]@{Type='upd';Id=$id;Ok=$false;Err=$err})
        # „Nicht anwendbar" (falsche Architektur/Sprache/Edition) ist kein
        # echter Fehler - Herbert kann das nicht fixen, also nur markieren.
        $notApp = ($err -match '(?i)anwendbares Upgrade|nicht auf Ihr System|No applicable upgrade|0x8a15002b|different (architecture|language|edition)')
        try{ Add-SysPilotFailedUpdate -Row $row -Error $err -Kind $(if($notApp){'not-applicable'}else{''}) }catch{}
        if($notApp){ & $say "[INFO] $nm : winget-Update nicht anwendbar - Herbert sucht Alternativen (anderer PM/Quelle) ..." }
        # Herbert Auto-Fix: bei Fehlschlag automatisch recherchieren
        # (KI) und den besten Fix-Versuch direkt ausfuehren - auch bei
        # 'nicht anwendbar' (anderer Paketmanager/faengt Alternativen ab)
        try {
            if (Get-Command Invoke-SysPilotAutoInstallFix -ErrorAction SilentlyContinue) {
                $mgr = $(if($src -eq 'chocolatey'){'choco'}elseif($src -like 'pm:*'){[string]$src -replace '^pm:',''}else{'winget'})
                & $say "Herbert Auto-Fix: analysiere Fehler fuer $nm ($mgr) ..."
                $fix = Invoke-SysPilotAutoInstallFix -AppName $nm -AppId $id -FailedManager $mgr -ErrorText $err -OnProgress $say
                if($fix -and $fix.Ok){
                    $failN--; $okN++
                    & $say "[OK] $nm - Auto-Fix erfolgreich: $($fix.Detail)"
                    $oq.Enqueue([pscustomobject]@{Type='upd';Id=$id;Ok=$true})
                } else {
                    & $say "[MANUELL] $nm - $($fix.Detail)"
                    foreach($lk in @($fix.Links)){ & $say "  Link: $($lk.Url)" }
                }
            }
        } catch { & $say "Auto-Fix Fehler: $($_.Exception.Message)" }
    }
    # Fortschritt: Programm abgeschlossen -> Balken auf Idx/Total
    $oq.Enqueue([pscustomobject]@{Type='prog';Idx=$idx;Total=$tot;Name='';Kind='Update'})
    if($ok){ try{ Remove-SysPilotFailedUpdate -Id $id }catch{} }
}
& $say "Fertig: $okN ok, $failN Fehler."
$oq.Enqueue([pscustomobject]@{Type='done'})
'@
    $fc.ucUpdCode = $updCode

    # KI-Suche-Job
    $kiCode = @'
Import-Module (Join-Path $modDir 'Common.psm1') -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $modDir 'SoftwareUpdateCenter.psm1') -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $modDir 'SmartDownload.psm1') -Force -ErrorAction SilentlyContinue
$q=$ucLogQ; $oq=$ucObjQ
$say={param($m) if($q){$q.Enqueue([string]$m)}}
& $say "SmartDownload-Suche: '$kiName' ..."
$r = Find-SysPilotDownload -Name $kiName -Id $kiId -Category $kiCat -OnProgress $say
$oq.Enqueue([pscustomobject]@{Type='search';Res=$r})
'@
    $fc.ucKiCode = $kiCode

    # Objekt-Queue-Verarbeitung (Scan-Zeilen, Update-Ergebnisse, Suche)
    $fc.ucResults = @()
    $ucApplyObj = {
        param($o)
        if (-not $o -or -not $o.Type) { return }
        switch ($o.Type) {
            'row' {
                $r = $o.Row
                $srcTxt = [string]$r.Source
                $stTxt = ''
                $fc.ucRows += [pscustomobject]@{ Name=[string]$r.Name; Installed=[string]$r.Installed; Available=[string]$r.Available; Source=$srcTxt; StatusText=$stTxt; Checked=$true; Orig=$r }
                & $refreshUpdList
            }
            'upd' {
                foreach($w in $fc.ucRows){ if([string]$w.Orig.Id -eq [string]$o.Id){ $w.StatusText = $(if($o.Ok){'OK'}else{'fehlgeschlagen'}) } }
                & $refreshUpdList
            }
            'search' {
                $r = $o.Res
                $fc.ucResults = @()
                $items=@()
                foreach($u in @($r.AiUrls)){ $items += [pscustomobject]@{Tag='[ki]';Label='Herbert-Fundstelle';Url=$u} }
                foreach($h in @($r.Web | Sort-Object Score -Descending | Select-Object -First 8)){ $items += [pscustomobject]@{Tag="[$($h.Engine)]";Label="$($h.Title) (Score $($h.Score))";Url=$h.Url} }
                foreach($w in @($r.Catalog | Select-Object -First 6)){ $disp=$(if($w.Title){$w.Title}else{$w.Source}); $items += [pscustomobject]@{Tag="[$($w.Source)]";Label=$disp;Url=$w.Url} }
                $fc.ucResults = $items
                $fc.ResultList.Items.Clear()
                foreach($it in $items){ [void]$fc.ResultList.Items.Add($it) }
                $fc.ResultList.Visibility = $(if($items.Count){'Visible'}else{'Collapsed'})
                $fc.BtnOpenLink.Visibility = $fc.ResultList.Visibility
                if ($r.AiText) { Set-SysPilotRichText -RichBox $fc.HerbBox -Text $r.AiText; $fc.HerbBox.Visibility='Visible' } else { $fc.HerbBox.Visibility='Collapsed' }
                & $setStatus "Suche fertig: $($r.Stats.Pm) PM, $($r.Stats.Catalog) Katalog, $($r.Stats.Web) Web-Treffer." '#FF81C784'
            }
            'store' {
                # Remote-Treffer (winget) mit lokalem Katalog mergen
                foreach ($s in @($o.Rows)) { $fc.ucStoreRemote += $s }
                & $refreshStoreList
                & $setStatus "Store: $(@($o.Rows).Count) Remote-Treffer ($($o.Summary))." '#FF81C784'
            }
            'prog' {
                # Bestimmter Fortschritt: Balken + Statuszeile + Laufzeit.
                # Update-Start (Name gesetzt): Balken zeigt erst die
                # ABGESCHLOSSENEN Programme (Idx-1) und fuellt waehrend
                # das aktuelle laeuft sanft auf; das zugehoerige
                # Abschluss-prog (Name leer) setzt den echten Stand.
                $fc.ProgBar.Visibility='Visible'
                $fc.ProgBar.IsIndeterminate=$false
                $fc.ProgBar.Minimum=0; $fc.ProgBar.Maximum=[double]$o.Total
                $isStart = ($o.Kind -ne 'Scan' -and [string]$o.Name)
                $floor = $(if($isStart){[Math]::Max(0,[double]$o.Idx-1)}else{[double]$o.Idx})
                $fc.ProgBar.Value = $floor
                $fc.ucProgFloor = $floor
                $fc.ucProgGoal  = [double]$o.Idx
                # Aktuelles Label fuer die Live-%-Anzeige in der Statuszeile
                if ($o.Name) { $fc.ucCurLabel = ("{0} {1}/{2}: {3}" -f [string]$o.Kind, $o.Idx, $o.Total, [string]$o.Name) }
                else         { $fc.ucCurLabel = ("{0} {1}/{2}" -f [string]$o.Kind, $o.Idx, $o.Total) }
                if ($o.Name) {
                    & $setStatus $fc.ucCurLabel '#FFB0B0C0'
                }
            }
            'done' { $fc.ucCurLabel=$null; & $setStatus 'Aufgabe abgeschlossen.' '#FF81C784' }
            'webver' {
                $wv = $o.Row
                $lbl = "[$($wv.Source)] $(if($wv.Version){$wv.Version}else{'-'})"
                if ($wv.Note) { $lbl += " - $($wv.Note)" }
                $fc.ucResults += [pscustomobject]@{Tag="[$($wv.Source)]";Label=$lbl;Url=[string]$wv.Url}
                $fc.ResultList.Items.Clear()
                foreach($it in $fc.ucResults){ [void]$fc.ResultList.Items.Add($it) }
                $fc.ResultList.Visibility = $(if($fc.ucResults.Count){'Visible'}else{'Collapsed'})
                $fc.BtnOpenLink.Visibility = $fc.ResultList.Visibility
            }
        }
    }
    $refreshUpdList = {
        $q = $fc.FilterBox.Text.Trim()
        $fc.UpdList.Items.Clear()
        foreach ($w in $fc.ucRows) {
            if ($q -eq '' -or "$($w.Name) $($w.Orig.Id) $($w.Source)" -match [regex]::Escape($q)) {
                [void]$fc.UpdList.Items.Add($w)
            }
        }
        & $refreshStoreList
    }
    $refreshStoreList = {
        $sq = $fc.StoreQuery.Text.Trim()
        $fc.StoreList.Items.Clear()
        $seen=@{}
        foreach ($s in @($fc.ucStoreRemote) + @($fc.ucStoreRows)) {
            $k = [string]$s.Name
            if ($sq -ne '' -and "$k $($s.Detail) $($s.SrcText)" -notmatch [regex]::Escape($sq)) { continue }
            if ($seen.ContainsKey($k.ToLower())) { continue }
            $seen[$k.ToLower()] = 1
            [void]$fc.StoreList.Items.Add($s)
        }
    }
    $updSelInfo = {
        # Checkbox-Menge ist die Auswahl (Wie im Konsolen-Multi-Select).
        # Liest die Listen-Items direkt - fensterlokal, unabhaengig vom
        # geteilten Modul-State ($fc.ucRows kann bei Parallel-Fenstern
        # zurueckgesetzt werden).
        $items = @($fc.UpdList.Items)
        $checked = @($items | Where-Object { $_.Checked -ne $false })
        $n = $checked.Count
        $fc.DCount.Text = "$n Programm(e) vorgemerkt"
        $fc.DHint.Text = $(if ($n -gt 0) { 'Häkchen = für Update vormerken. "Alle aktualisieren" nimmt die vorgemerkten, "Auswahl" die markierten Zeilen.' } else { 'Scan starten, dann per Häkchen vormerken.' })
    }
    # Store-Daten: lokaler Katalog (sofort suchbar) + Installationsstatus
    $fc.ucStoreRows = @()
    $catAll = @(Get-SysPilotUpdateCatalog)
    $instMap = @{}
    try { foreach($kv in (Get-SysPilotInstalledAppMap).GetEnumerator()){ $instMap[$kv.Key]=$kv.Value } } catch {}
    foreach ($a in $catAll) {
        $inst = Find-SysPilotCatalogInstalled -App $a
        $instTxt = $(if ($inst -and $inst.Version -and $inst.Version -notmatch 'unbekannt') { "$($inst.Version)" } else { '-' })
        $srcs=@(); if($a.WingetId){$srcs+='winget'}; if($a.Gh){$srcs+='gh'}; if($a.Mg){$srcs+='mg'}; if($a.Page){$srcs+='web'}
        $fc.ucStoreRows += [pscustomobject]@{
            Name=[string]$a.Name; Typ='Katalog'; InstText=$instTxt; SrcText=($srcs -join '/');
            Detail="[$($a.Cat)]"; Orig=$a; Kind='catalog'; Checked=$false
        }
    }
    $fc.ucStoreRows = @($fc.ucStoreRows | Sort-Object Name)
    & $refreshStoreList

    # Web-Quellen: Download-Portale (PortableTools) + Ninite zuerst
    $fc.ucPortals = @()
    try {
        if (-not (Get-Command Get-SysPilotDownloadPortals -ErrorAction SilentlyContinue)) {
            Import-SysPilotModule -Name 'PortableTools' -ErrorAction SilentlyContinue
        }
        if (Get-Command Get-SysPilotDownloadPortals -ErrorAction SilentlyContinue) {
            $fc.ucPortals = @(Get-SysPilotDownloadPortals)
        }
    } catch { }
    if ($fc.ucPortals.Count -eq 0) {
        $fc.ucPortals = @(
            @{ Id='ninite'; Name='Ninite'; Url='https://ninite.com/'; Auto=$true; Desc='Still-Installation (~160 Apps)' },
            @{ Id='majorgeeks'; Name='MajorGeeks'; Url='https://www.majorgeeks.com/'; Auto=$true; Desc='Kuratierte Downloads' },
            @{ Id='filehippo'; Name='FileHippo'; Url='https://filehippo.com/'; Auto=$false; Desc='Versionsarchiv (Bot-Schutz)' }
        )
    }
    $fc.ucPortals = @($fc.ucPortals | Where-Object { $_.Id -eq 'ninite' }) + @($fc.ucPortals | Where-Object { $_.Id -ne 'ninite' })
    $fc.ucPortalRows = @()
    foreach ($p in $fc.ucPortals) {
        $fc.ucPortalRows += [pscustomobject]@{
            Name=[string]$p.Name
            ArtText = $(if ($p.Auto) { 'automatisierbar' } else { 'manuell' })
            DescText = [string]$p.Desc; Url=[string]$p.Url; Orig=$p
        }
    }
    foreach ($w in $fc.ucPortalRows) { [void]$fc.WebList.Items.Add($w) }
    $webSelInfo = {
        $w = $fc.WebList.SelectedItem
        if (-not $w) { $fc.WName.Text=''; $fc.WInfo.Text=''; return }
        $fc.WName.Text = "$($w.Name)  [$($w.ArtText)]"
        $fc.WInfo.Text = "$($w.DescText)`n$($w.Url)"
    }

    # Button-Verdrahtung
    $fc.FilterBox.Add_TextChanged({ & $refreshUpdList })
    $fc.StoreQuery.Add_TextChanged({ & $refreshUpdList })
    $fc.UpdList.Add_SelectionChanged({ & $updSelInfo })

    $fc.BtnScan.Add_Click({
        & $ucEnqueue 'Scan gestartet' $fc.ucScanCode @{} 'Scan laeuft ...'
    }.GetNewClosure())

    $fc.BtnUpdSel.Add_Click({
        # Bevorzugt die Haekchen-Menge (aus der Liste), sonst markierte Zeilen
        $sel = @($fc.UpdList.Items | Where-Object { $_.Checked -ne $false } | ForEach-Object { $_.Orig })
        $scope = 'Vorgemerkt'
        if ($sel.Count -eq 0) {
            $sel = @($fc.UpdList.SelectedItems | ForEach-Object { $_.Orig })
            $scope = 'Auswahl'
        }
        if ($sel.Count -eq 0) { & $setStatus 'Bitte per Haekchen vormerken oder Zeilen markieren.' '#FFFFB74D'; return }
        $mode = 'silent'
        $mi = $fc.ModusBox.SelectedItem
        if ($mi -and $mi.Tag -eq 'interaktiv') { $mode='interaktiv' }
        if ($mode -eq 'interaktiv') {
            $r0=[System.Windows.MessageBox]::Show("Interaktiver Modus: winget-Installer zeigen ihre eigene UI`n(fuer $($sel.Count) Programm(e), nacheinander). Fortfahren?",'Softwarecenter','YesNo','Question')
            if($r0 -ne 'Yes'){return}
        }
        $sel = @($sel | ForEach-Object { $h=@{}; foreach($p in $_.psobject.Properties){$h[$p.Name]=$p.Value}; [pscustomobject]$h })
        & $ucEnqueue "Update-Lauf: $($sel.Count) Programm(e) [$mode]" $fc.ucUpdCode @{ selRows=$sel; updMode=$mode } "Update laeuft fuer $($sel.Count) Programm(e) [$mode] ..."
    }.GetNewClosure())

    # Prefs: pro App (Auswahl) oder global - portiert aus dem Konsolen-Menue
    $fc.BtnPrefs.Add_Click({
        $selItem = $fc.UpdList.SelectedItem
        $appId = ''
        if ($selItem -and $selItem.Orig.Id) { $appId = [string]$selItem.Orig.Id }
        $items = @(
            @{ Label="App-Einstellung: $(if($appId){$appId}else{'(kein Update ausgewaehlt)'})"; Color='Cyan'; Tag='app' }
            @{ Label='Globale Update-Einstellungen (Standard-Modus/Admin)'; Color='Yellow'; Tag='global' }
        )
        $m = Show-SysPilotArrowMenu -Items $items -Title 'Update-Einstellungen' -Footer 'Enter = waehlen, Esc = schliessen'
        if (-not $m) { return }
        if ($m -eq 'global') {
            $st = Read-SysPilotUpdateState
            $mode = if ($st.Defaults.Mode) { [string]$st.Defaults.Mode } else { 'silent' }
            $adm  = [bool]$st.Defaults.Admin
            $g = Show-SysPilotArrowMenu -Items @(
                @{ Label="Standard-Modus: silent (aktuell: $mode)";      Color='Green';  Tag='silent' },
                @{ Label="Standard-Modus: interaktiv (aktuell: $mode)"; Color='Yellow'; Tag='interactive' },
                @{ Label="Standard-Modus: fragen (aktuell: $mode)";     Color='White';  Tag='ask' },
                @{ Label="Admin-Standard: $(if($adm){'AN'}else{'aus'}) - umschalten"; Color='Magenta'; Tag='admin' }
            ) -Title 'Globale Update-Einstellungen' -Footer 'Enter = waehlen, Esc = schliessen'
            if ($g -in @('silent','interactive','ask')) { Set-SysPilotUpdatePrefs -Global -Mode $g; & $ucLog "Globaler Modus = $g" }
            elseif ($g -eq 'admin') { Set-SysPilotUpdatePrefs -Global -Admin (-not $adm); & $ucLog "Globaler Admin-Standard umgeschaltet." }
        } else {
            if (-not $appId) { & $setStatus 'Bitte zuerst ein Update in der Liste auswaehlen.' '#FFFFB74D'; return }
            $pref = Get-SysPilotUpdatePrefs -Id $appId
            $p = Show-SysPilotArrowMenu -Items @(
                @{ Label="Modus: silent (aktuell: $($pref.Mode))";                 Color='Green';  Tag='silent' },
                @{ Label="Modus: interaktiv (aktuell: $($pref.Mode))";            Color='Yellow'; Tag='interactive' },
                @{ Label="Modus: manuell - nie auto (aktuell: $($pref.Mode))";    Color='Cyan';   Tag='manual' },
                @{ Label="Modus: fragen (aktuell: $($pref.Mode))";                Color='White';  Tag='ask' },
                @{ Label="Admin: $(if($pref.Admin){'AN'}else{'aus'}) - umschalten"; Color='Magenta'; Tag='admin' },
                @{ Label='App-Einstellung loeschen (auf Defaults)';                Color='DarkGray'; Tag='clear' }
            ) -Title "App-Einstellung: $appId" -Footer 'Enter = waehlen, Esc = schliessen'
            switch ($p) {
                'silent'      { Set-SysPilotUpdatePrefs -Id $appId -Mode 'silent';      & $ucLog "Modus=$appId : silent" }
                'interactive' { Set-SysPilotUpdatePrefs -Id $appId -Mode 'interactive'; & $ucLog "Modus=$appId : interaktiv" }
                'manual'      { Set-SysPilotUpdatePrefs -Id $appId -Mode 'manual';      & $ucLog "Modus=$appId : manuell (Auto-Update ueberspringt)" }
                'ask'         { Set-SysPilotUpdatePrefs -Id $appId -Mode 'ask';         & $ucLog "Modus=$appId : fragen" }
                'admin'       { Set-SysPilotUpdatePrefs -Id $appId -Admin (-not $pref.Admin); & $ucLog "Admin fuer $appId umgeschaltet." }
                'clear'       { Set-SysPilotUpdatePrefs -Id $appId -Clear;              & $ucLog "App-Einstellung $appId geloescht." }
            }
        }
    }.GetNewClosure())

    $fc.ucKiName=''; $fc.ucKiId=''; $fc.ucKiCat=''
    $startKiSearch = {
        param($name,$id,$cat='')
        $fc.ucKiName=$name; $fc.ucKiId=$id; $fc.ucKiCat=$cat
        $fc.HerbBox.Visibility='Collapsed'; $fc.ResultList.Items.Clear(); $fc.ResultList.Visibility='Collapsed'; $fc.BtnOpenLink.Visibility='Collapsed'
        & $ucEnqueue "SmartDownload-Suche: $name" $fc.ucKiCode @{ kiName=$name; kiId=$id; kiCat=$cat } "SmartDownload-Suche laeuft: $name ..."
    }
    $fc.BtnUpdSearch.Add_Click({
        $sel = @($fc.UpdList.SelectedItems)
        if ($sel.Count -eq 0) { & $setStatus 'Bitte zuerst ein Update auswaehlen.' '#FFFFB74D'; return }
        & $startKiSearch ([string]$sel[0].Name) ([string]$sel[0].Orig.Id)
    }.GetNewClosure())

    # ===== Store-Tab: Suche + Install =====
    $fc.ucStoreCode = @'
Import-Module (Join-Path $modDir 'Common.psm1') -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $modDir 'SoftwareUpdateCenter.psm1') -Force -ErrorAction SilentlyContinue
$q=$ucLogQ; $oq=$ucObjQ
$say = { param($m) if ($q) { $q.Enqueue([string]$m) } }
& $say "Store-Suche: '$stQuery' ..."
$rows=@()
# 1) winget remote search
try {
    & $say 'winget search ...'
    $wr = Find-SysPilotWingetSearch -Query $stQuery -Limit 15
    foreach($w in @($wr)){ $rows += [pscustomobject]@{Name=[string]$w.Name;Typ='winget';InstText='-';SrcText='winget';Detail=[string]$w.Id;Orig=$w;Kind='winget';Checked=$false} }
    & $say "winget: $(@($wr).Count) Treffer"
} catch { & $say "winget-Fehler: $($_.Exception.Message)" }
# 2) Lokaler Katalog (Namens-Match)
try {
    $cat = @(Get-SysPilotUpdateCatalog)
    $inst = @{}
    try { foreach($kv in (Get-SysPilotInstalledAppMap).GetEnumerator()){ $inst[$kv.Key]=$kv.Value } } catch {}
    $qLower = $stQuery.ToLower()
    $hits = @($cat | Where-Object { "$($_.Name) $($_.Cat)".ToLower() -match [regex]::Escape($qLower) } | Select-Object -First 15)
    foreach($a in $hits){
        $iv = Find-SysPilotCatalogInstalled -App $a
        $it = $(if($iv -and $iv.Version -and $iv.Version -notmatch 'unbekannt'){$iv.Version}else{'-'})
        $srcs=@(); if($a.WingetId){$srcs+='winget'}; if($a.Gh){$srcs+='gh'}; if($a.Mg){$srcs+='mg'}; if($a.Page){$srcs+='web'}
        $rows += [pscustomobject]@{Name=[string]$a.Name;Typ='Katalog';InstText=$it;SrcText=($srcs -join '/');Detail="[$($a.Cat)]";Orig=$a;Kind='catalog';Checked=$false}
    }
    & $say "Katalog: $($hits.Count) Treffer"
} catch { & $say "Katalog-Fehler: $($_.Exception.Message)" }
# 3) SmartDownload/Web-Quellen (Uptodown, FileHorse, offizielle Seiten)
try {
    Import-Module (Join-Path $modDir 'SmartDownload.psm1') -Force -ErrorAction SilentlyContinue
    if (Get-Command Find-SysPilotDownload -ErrorAction SilentlyContinue) {
        & $say 'SmartDownload/Web-Quellen ...'
        $sd = Find-SysPilotDownload -Name $stQuery -MaxWebResults 10 -OnProgress $say
        $wn=0
        foreach($h in @($sd.Web | Sort-Object Score -Descending | Select-Object -First 10)){
            $wn++
            $rows += [pscustomobject]@{Name=[string]$h.Title;Typ='Web';InstText='-';SrcText=[string]$h.Engine;Detail="Score $($h.Score) - $($h.Url)";Orig=[pscustomobject]@{Url=[string]$h.Url;Title=[string]$h.Title};Kind='web';Checked=$false}
        }
        foreach($c in @($sd.Catalog | Select-Object -First 5)){
            $disp = $(if($c.Title){[string]$c.Title}else{[string]$c.Source})
            $rows += [pscustomobject]@{Name=$disp;Typ='DL-Katalog';InstText='-';SrcText=[string]$c.Source;Detail=[string]$c.Url;Orig=[pscustomobject]@{Url=[string]$c.Url;Title=$disp};Kind='web';Checked=$false}
        }
        & $say "SmartDL: $wn Web-Treffer"
    }
} catch { & $say "SmartDL-Fehler: $($_.Exception.Message)" }
# Dedupe nach Name (winget hat Vorrang)
$seen=@{}; $uniq=@()
foreach($r in $rows){ $k=$r.Name.ToLower(); if(-not $seen.ContainsKey($k)){$seen[$k]=1;$uniq+=$r} }
$oq.Enqueue([pscustomobject]@{Type='store';Rows=$uniq;Summary="winget+katalog"})
$oq.Enqueue([pscustomobject]@{Type='done'})
'@

    $fc.BtnStoreSearch.Add_Click({
        $q = $fc.StoreQuery.Text.Trim()
        if (-not $q) { & $setStatus 'Bitte einen Suchbegriff eingeben.' '#FFFFB74D'; return }
        $fc.StoreList.Items.Clear()
        & $ucEnqueue "Store-Suche: $q" $fc.ucStoreCode @{ stQuery=$q } "Store-Suche laeuft: $q ..."
    }.GetNewClosure())
    $fc.StoreQuery.Add_KeyDown({ param($s,$e) if($e.Key -eq 'Return'){ $fc.BtnStoreSearch.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) } })

    $fc.BtnStoreMega.Add_Click({
        try {
            if(-not (Get-Command Show-SysPilotAppStoreWindow -ErrorAction SilentlyContinue)){ Import-SysPilotModule -Name 'AppStore' -ErrorAction SilentlyContinue }
            if(Get-Command Show-SysPilotAppStoreWindow -ErrorAction SilentlyContinue){
                Show-SysPilotAppStoreWindow -Owner $ucw -Title 'SysPilot - Megastore'
            } else { & $setStatus 'Megastore-Modul nicht verfuegbar.' '#FFFFB74D' }
        } catch { & $setStatus "Megastore: $($_.Exception.Message)" '#FFFF5252' }
    }.GetNewClosure())

    # Batch-Install-Job: alle abgehakten Eintraege mit PM-Pfad nacheinander
    # (winget bevorzugt, sonst npm/pip aus dem Katalog)
    $fc.ucStoreBatchCode = @'
Import-Module (Join-Path $modDir 'Common.psm1') -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $modDir 'PackageManagers.psm1') -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $modDir 'SoftwareUpdateCenter.psm1') -Force -ErrorAction SilentlyContinue
$q=$ucLogQ;$oq=$ucObjQ;$say={param($m) if($q){$q.Enqueue([string]$m)}}
$tot=@($instList).Count;$i=0
foreach($it in $instList){
  $i++
  $oq.Enqueue([pscustomobject]@{Type='prog';Idx=$i;Total=$tot;Name=[string]$it.Name;Kind='Install'})
  & $say "$($it.Mgr) install $($it.Id) ($($it.Name)) ..."
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
$oq.Enqueue([pscustomobject]@{Type='prog';Idx=$tot;Total=$tot;Name='';Kind='Install'})
'@

    $fc.BtnStoreInstall.Add_Click({
        # Abgehakte Zeilen (Haeckchen) haben Vorrang - Mehrfachauswahl.
        # Ohne Haken: markierte Zeile, altes Single-Select-Verhalten.
        $checked = @($fc.StoreList.Items | Where-Object { $_.Checked -eq $true })
        if ($checked.Count -gt 0) {
            $instList = @(); $skip = @()
            foreach ($c in $checked) {
                $mgr=''; $pkgId=''
                if ($c.Kind -eq 'winget') { $mgr='winget'; $pkgId=[string]$c.Orig.Id }
                elseif ($c.Kind -eq 'catalog') {
                    if ($c.Orig.WingetId) { $mgr='winget'; $pkgId=[string]$c.Orig.WingetId }
                    elseif ($c.Orig.NpmPkg)  { $mgr='npm';   $pkgId=[string]$c.Orig.NpmPkg }
                    elseif ($c.Orig.PipPkg)  { $mgr='pip';   $pkgId=[string]$c.Orig.PipPkg }
                }
                if ($pkgId) { $instList += [pscustomobject]@{Name=[string]$c.Name; Mgr=$mgr; Id=$pkgId} }
                else { $skip += [string]$c.Name }
            }
            if ($skip.Count -gt 0) { & $ucLog "Uebersprungen (kein Installationspfad): $($skip -join ', ')" }
            if ($instList.Count -eq 0) { & $setStatus 'Keine abgehakten Eintraege mit Installationspfad (winget/npm/pip).' '#FFFFB74D'; return }
            $names = ($instList | ForEach-Object { "$($_.Name)[$($_.Mgr)]" }) -join ', '
            if ($names.Length -gt 300) { $names = $names.Substring(0,300) + ' ...' }
            $r0=[System.Windows.MessageBox]::Show("$($instList.Count) Programm(e) installieren?`n`n$names`n`n(silent, nacheinander - Log unten)",'Softwarecenter','YesNo','Question')
            if($r0 -ne 'Yes'){return}
            & $ucEnqueue "Batch-Install: $($instList.Count) Programm(e)" $fc.ucStoreBatchCode @{ instList=$instList } "Installiere $($instList.Count) Programm(e) ..."
            return
        }
        $sel = @($fc.StoreList.SelectedItems)
        if ($sel.Count -eq 0) { & $setStatus 'Bitte zuerst einen Store-Treffer auswaehlen oder per Haeckchen vormerken.' '#FFFFB74D'; return }
        $w = $sel[0]; $kind = [string]$w.Kind; $a = $w.Orig
        if ($kind -eq 'web') {
            $u = [string]$a.Url
            if ($u) { Start-Process $u; & $ucLog "Web-Treffer geoeffnet: $u" } else { & $setStatus 'Kein Link vorhanden.' '#FFFFB74D' }
            return
        }
        if ($kind -eq 'winget') {
            $wid = [string]$a.Id
            $r=[System.Windows.MessageBox]::Show("$($w.Name) ueber winget installieren?`nID: $wid`n(silent, kann Minuten dauern - Log unten)",'Softwarecenter','YesNo','Question')
            if($r -ne 'Yes'){return}
            $code=@'
Import-Module (Join-Path $modDir 'Common.psm1') -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $modDir 'SoftwareUpdateCenter.psm1') -Force -ErrorAction SilentlyContinue
$q=$ucLogQ;$oq=$ucObjQ;$say={param($m) if($q){$q.Enqueue([string]$m)}}
$oq.Enqueue([pscustomobject]@{Type='prog';Idx=1;Total=1;Name=$wname;Kind='Install'})
& $say "winget install $wid ..."
$ok = Invoke-SysPilotCatalogWingetSilent -Id $wid
& $say $(if($ok){"[OK] $wname"}else{"[FAIL] $wname"})
$oq.Enqueue([pscustomobject]@{Type='prog';Idx=1;Total=1;Name='';Kind='Install'})
'@
            & $ucEnqueue "winget install: $($w.Name) ($wid)" $code @{ wid=$wid; wname=[string]$w.Name } "Installiere $($w.Name) ..."
        } else {
            # Katalog-Eintrag: winget bevorzugen, sonst GitHub-Asset
            $wid = [string]$a.WingetId
            if ($wid) {
                $r=[System.Windows.MessageBox]::Show("$($w.Name) ueber winget installieren/aktualisieren?`nID: $wid`n(silent)",'Softwarecenter','YesNo','Question')
                if($r -ne 'Yes'){return}
                $code=@'
Import-Module (Join-Path $modDir 'Common.psm1') -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $modDir 'SoftwareUpdateCenter.psm1') -Force -ErrorAction SilentlyContinue
$q=$ucLogQ;$oq=$ucObjQ;$say={param($m) if($q){$q.Enqueue([string]$m)}}
$oq.Enqueue([pscustomobject]@{Type='prog';Idx=1;Total=1;Name=$wname;Kind='Install'})
& $say "winget install/upgrade $wid ..."
$ok = Invoke-SysPilotCatalogWingetSilent -Id $wid
& $say $(if($ok){"[OK] $wname"}else{"[FAIL] $wname"})
$oq.Enqueue([pscustomobject]@{Type='prog';Idx=1;Total=1;Name='';Kind='Install'})
'@
                & $ucEnqueue "winget: $($w.Name) ($wid)" $code @{ wid=$wid; wname=[string]$w.Name } "Installiere $($w.Name) ..."
            } elseif ($a.Gh) {
                $fc.BtnStoreDl.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
            } else { & $setStatus "Kein Direkt-Installationspfad fuer $($w.Name) - Seite/SmartDL nutzen." '#FFFFB74D' }
        }
    }.GetNewClosure())

    $fc.BtnStoreAll.Add_Click({
        foreach($it in @($fc.StoreList.Items)){ $it.Checked=$true }
        & $setStatus "Alle $(@($fc.StoreList.Items).Count) sichtbaren Treffer vorgemerkt." '#FF81C784'
    }.GetNewClosure())
    $fc.BtnStoreNone.Add_Click({
        foreach($it in @($fc.StoreList.Items)){ $it.Checked=$false }
        & $setStatus 'Alle Haekchen entfernt.' '#FF9E9E9E'
    }.GetNewClosure())

    $fc.BtnStoreDl.Add_Click({
        $w = $fc.StoreList.SelectedItem; if(-not $w){return}
        if ($w.Kind -eq 'web') {
            $u=[string]$w.Orig.Url; if($u){Start-Process $u}else{& $setStatus 'Kein Link vorhanden.' '#FFFFB74D'}
            return
        }
        & $startKiSearch ([string]$w.Name) ([string]$(if($w.Kind -eq 'winget'){$w.Orig.Id}else{$w.Orig.WingetId})) ''
    }.GetNewClosure())

    $fc.BtnStorePage.Add_Click({
        $w = $fc.StoreList.SelectedItem; if(-not $w){return}
        $u=''
        if ($w.Kind -eq 'catalog') { $u=[string]$w.Orig.Page }
        elseif ($w.Orig.PSObject.Properties['Url']) { $u=[string]$w.Orig.Url }
        if(-not $u){ $u="https://www.bing.com/search?q=" + [uri]::EscapeDataString($w.Name) }
        Start-Process $u
    }.GetNewClosure())

    # ===== "Mehr"-Menue: alle Sekundaer-Funktionen gebuendelt =====
    $fc.BtnMore.Add_Click({
        $mItems = @(
            @{ Label='DL-Manager (SmartDownload-Vollfenster)'; Color='Cyan'; Tag='dlmgr' }
            @{ Label='Volle App-Suche (alle Paketmanager + Herbert)'; Color='Cyan'; Tag='appsearch' }
            @{ Label='App Store / Megastore (eigenes Fenster)'; Color='Green'; Tag='store' }
            @{ Label='Paketmanager (winget/choco/scoop/npm/pip/dotnet/PSGallery/WSL)'; Color='Cyan'; Tag='pkgs' }
            @{ Label='Ninite-Installer (portable Apps, still)'; Color='Green'; Tag='ninite' }
            @{ Label='Manuelle Katalog-Suche (site:-Operatoren, Portale)'; Color='Yellow'; Tag='ksearch' }
            @{ Label='Quellen-Status (was ist verfuegbar?)'; Color='White'; Tag='status' }
            @{ Label='Konsolen-Menue (Expertenmodus)'; Color='DarkGray'; Tag='console' }
        )
        $m = Show-SysPilotArrowMenu -Items $mItems -Title 'Weitere Funktionen' -Footer 'Enter = oeffnen, Esc = schliessen'
        switch ($m) {
            'dlmgr' {
                $nm=''; $id=''
                $u = $fc.UpdList.SelectedItem
                if ($u) { $nm=[string]$u.Name; $id=[string]$u.Orig.Id }
                else { $s = $fc.StoreList.SelectedItem; if ($s) { $nm=[string]$s.Name; $id=[string]$(if($s.Kind -eq 'winget'){$s.Orig.Id}else{$s.Orig.WingetId}) } }
                try {
                    if (-not (Get-Command Show-SysPilotDownloadFinder -ErrorAction SilentlyContinue)) { Import-SysPilotModule -Name 'SmartDownload' -ErrorAction SilentlyContinue }
                    if (Get-Command Show-SysPilotDownloadFinder -ErrorAction SilentlyContinue) { Show-SysPilotDownloadFinder -AppName $nm -AppId $id -Owner $ucw -Title 'SysPilot - Download-Suche' }
                } catch { & $setStatus "DL-Manager: $($_.Exception.Message)" '#FFFF5252' }
            }
            'appsearch' {
                try {
                    if (-not (Get-Command Show-SysPilotAppSearchWindow -ErrorAction SilentlyContinue)) { Import-SysPilotModule -Name 'SmartDownload' -ErrorAction SilentlyContinue }
                    if (Get-Command Show-SysPilotAppSearchWindow -ErrorAction SilentlyContinue) { Show-SysPilotAppSearchWindow -Owner $ucw -Title 'SysPilot - Programm-Suche' }
                } catch { & $setStatus "App-Suche: $($_.Exception.Message)" '#FFFF5252' }
            }
            'store' {
                try {
                    if (-not (Get-Command Show-SysPilotAppStoreWindow -ErrorAction SilentlyContinue)) { Import-SysPilotModule -Name 'AppStore' -ErrorAction SilentlyContinue }
                    if (Get-Command Show-SysPilotAppStoreWindow -ErrorAction SilentlyContinue) { Show-SysPilotAppStoreWindow -Owner $ucw -Title 'SysPilot - App Store (Megastore)' }
                } catch { & $setStatus "Store: $($_.Exception.Message)" '#FFFF5252' }
            }
            'console' {
                $r=[System.Windows.MessageBox]::Show('Konsolen-Menue oeffnet sich in einem eigenen Fenster (SysPilot.ps1 -Tool updates). Fortfahren?','Softwarecenter','YesNo','Question')
                if($r -eq 'Yes'){
                    $root = Split-Path -Parent $PSCommandPath
                    Start-Process powershell.exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $root 'SysPilot.ps1'),'-Tool','updatesc'
                }
            }
            { $_ -in @('pkgs','ninite','ksearch','status') } {
                # Konsolen-Funktionen in eigenem Fenster (kein -Tool-Key,
                # also direkter Modul-Aufruf in neuer PowerShell-Konsole)
                $fn = switch ($m) {
                    'pkgs'    { 'Show-SysPilotPackageManagerMenu' }
                    'ninite'  { 'Show-SysPilotNinitePicker' }
                    'ksearch' { 'Show-SysPilotWebCatalogSearch' }
                    'status'  { 'Show-SysPilotUpdateSourcesStatus' }
                }
                $mods = @('Common.psm1','SoftwareUpdateCenter.psm1','PackageManagers.psm1','PortableTools.psm1','SmartDownload.psm1') |
                    ForEach-Object { "Import-Module '$ucModDir\$_' -Force -ErrorAction SilentlyContinue" }
                $cmd = ($mods -join '; ') + "; if (Get-Command $fn -ErrorAction SilentlyContinue) { $fn } else { Write-Host 'Funktion $fn nicht verfuegbar' -ForegroundColor Red; Read-Host 'Enter' }"
                Start-Process powershell.exe -ArgumentList '-NoExit','-NoProfile','-ExecutionPolicy','Bypass','-Command',$cmd
            }
        }
    }.GetNewClosure())

    # Web-Quellen-Handler
    $fc.WebList.Add_SelectionChanged({ & $webSelInfo }.GetNewClosure())
    $fc.BtnWebOpen.Add_Click({
        $w = $fc.WebList.SelectedItem
        if ($w -and $w.Url) { Start-Process ([string]$w.Url) }
    })
    # Versions-Job (Get-SysPilotWebSourceVersions im Hintergrund)
    $fc.ucWvCode = @'
Import-Module (Join-Path $modDir 'Common.psm1') -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $modDir 'SoftwareUpdateCenter.psm1') -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $modDir 'PortableTools.psm1') -Force -ErrorAction SilentlyContinue
$q=$ucLogQ; $oq=$ucObjQ
$say={param($m) if($q){$q.Enqueue([string]$m)}}
& $say "Versions-Suche '$wvQuery' in automatisierten Quellen (Ninite/MajorGeeks/Uptodown/FOSSHub) ..."
$res = @(Get-SysPilotWebSourceVersions -Query $wvQuery)
foreach($r in $res){ $oq.Enqueue([pscustomobject]@{Type='webver';Row=$r}) }
& $say "Fertig: $($res.Count) Treffer (mit Version: $(@($res|?{$_.Version}).Count))."
$oq.Enqueue([pscustomobject]@{Type='done'})
'@
    $startWebVer = {
        param([string]$q)
        $fc.ucResults=@()
        $fc.ResultList.Items.Clear(); $fc.ResultList.Visibility='Collapsed'; $fc.BtnOpenLink.Visibility='Collapsed'
        & $ucEnqueue "Versions-Suche: $q" $fc.ucWvCode @{ wvQuery=$q } "Versions-Suche laeuft: $q ..."
    }
    $fc.BtnWebVer.Add_Click({
        $w = $fc.WebList.SelectedItem
        if (-not $w) { & $setStatus 'Bitte zuerst ein Portal auswaehlen.' '#FFFFB74D'; return }
        $q = Show-SysPilotWpfInput -Prompt "Suchbegriff fuer Versions-Check (z.B. 7-Zip, VLC):" -Default $w.Name -Title 'SysPilot - Versions-Suche'
        if ($q) { & $startWebVer $q.Trim() }
    }.GetNewClosure())
    $fc.BtnWebVerAll.Add_Click({
        $q = Show-SysPilotWpfInput -Prompt 'Suchbegriff fuer Versions-Check in ALLE Quellen (auch manuelle Portale als Links):' -Default '' -Title 'SysPilot - Versions-Suche'
        if ($q) { & $startWebVer $q.Trim() }
    }.GetNewClosure())
    $fc.BtnWebRss.Add_Click({
        if (Get-Command Show-SysPilotRssCenter -ErrorAction SilentlyContinue) {
            try { Show-SysPilotRssCenter -Owner $ucw | Out-Null } catch {}
        } else { & $setStatus 'RSS-Center nicht verfuegbar (AiAssist-Modul fehlt).' '#FFFFB74D' }
    }.GetNewClosure())

    $fc.BtnAutoAll.Add_Click({
        # Häkchen-Menge = Auswahl; Quelle ist die Listen-Ansicht selbst
        # (fensterlokal - sicher gegen State-Kollisionen zweiter Fenster).
        $sel = @($fc.UpdList.Items | Where-Object { $_.Checked -ne $false } | ForEach-Object { $_.Orig })
        $scope = 'Vorgemerkt'
        # Dedupe nach Quelle+ID (gleiche App kann aus winget UND pm kommen)
        $seen=@{}; $dedup=@()
        foreach($r in $sel){ $k=("$([string]$r.Source)|$([string]$r.Id)").ToLower(); if($k -and -not $seen.ContainsKey($k)){$seen[$k]=1;$dedup+=$r} }
        $sel=$dedup
        if ($sel.Count -eq 0) { & $setStatus 'Keine Updates vorgemerkt - per Haekchen markieren oder scannen.' '#FFFFB74D'; return }
        & $ucLog "Auswahl-Check: Liste=$($fc.UpdList.Items.Count) Zeilen, markiert=$($sel.Count)"
        $r=[System.Windows.MessageBox]::Show("$scope : $($sel.Count) Update(s) jetzt still installieren?",'Softwarecenter','YesNo','Question')
        if($r -ne 'Yes'){return}
        $mode = 'silent'
        $mi = $fc.ModusBox.SelectedItem
        if ($mi -and $mi.Tag -eq 'interaktiv') { $mode='interaktiv' }
        # Orig-Objekte stammen aus dem Scan-Runspace - als frische
        # UI-eigene PSCustomObjects uebergeben (Session-State-sicher).
        $sel = @($sel | ForEach-Object { $h=@{}; foreach($p in $_.psobject.Properties){$h[$p.Name]=$p.Value}; [pscustomobject]$h })
        & $ucEnqueue "Auto-Lauf ($scope): $($sel.Count) Programm(e) [$mode]" $fc.ucUpdCode @{ selRows=$sel; updMode=$mode } "Update laeuft fuer $($sel.Count) Programm(e) [$mode] ..."
    }.GetNewClosure())

    $fc.BtnAutoTask.Add_Click({
        $t = Get-SysPilotUpdateTask
        if($t){
            $r=[System.Windows.MessageBox]::Show('Taegliche Auto-Update-Aufgabe entfernen?','Softwarecenter','YesNo','Question')
            if($r -eq 'Yes'){ Remove-SysPilotUpdateTask; & $ucLog 'Auto-Update-Aufgabe entfernt.' }
        } else {
            $r=[System.Windows.MessageBox]::Show("Taegliche Auto-Update-Aufgabe einrichten?`n(silent, 12:00 taeglich, Admin-Rechte)`n`nAchtung: laeuft auch ohne SysPilot im Hintergrund.",'Softwarecenter','YesNo','Question')
            if($r -eq 'Yes'){ Install-SysPilotUpdateTask; & $ucLog 'Auto-Update-Aufgabe installiert (taeglich 12:00).' }
        }
    }.GetNewClosure())

    $fc.BtnFailed.Add_Click({ try { Show-SysPilotFailedUpdatesWindow -Owner $ucw } catch {} }.GetNewClosure())
    $fc.BtnClose.Add_Click({ $ucw.Close() })
    $fc.BtnOpenLink.Add_Click({
        $it = $fc.ResultList.SelectedItem
        if($it -and $it.Url){ Start-Process ([string]$it.Url) }
    })
    $fc.ResultList.Add_MouseDoubleClick({
        $it = $fc.ResultList.SelectedItem
        if($it -and $it.Url){ Start-Process ([string]$it.Url) }
    })

    # Poll-Timer: Queue + Proc-Tail + Job-State
    $poll = New-Object System.Windows.Threading.DispatcherTimer
    $poll.Interval = [timespan]::FromMilliseconds(200)
    $poll.Add_Tick({
        & $ucDrain
        if ($fc.ucAsync -and $fc.ucAsync.IsCompleted -and $fc.ucBusy) { & $finishJob }
        & $ucPumpNext
    }.GetNewClosure())
    $ucw.Add_Closing({
        $poll.Stop()
        if ($script:ucWindow -eq $ucw) { $script:ucWindow = $null }
        if ($fc.ucAsync) { try { $fc.ucPs.Stop(); $fc.ucPs.Dispose(); $fc.ucRs.Close(); $fc.ucRs.Dispose() } catch {} }
    })
    $poll.Start()
    & $refreshUpdList
    & $updSelInfo
    # Quellen-Status sofort sichtbar machen (winget/choco vorhanden?)
    $wOk = [bool](Get-SysPilotWingetExe); $cOk = [bool](Get-SysPilotChocoExe)
    & $setStatus ("Scan startet automatisch ... (winget={0}, choco={1})" -f $(if($wOk){'OK'}else{'FEHLT'}), $(if($cOk){'OK'}else{'FEHLT'})) '#FF9E9E9E'
    Set-SysPilotWindowAutoSize -Win $ucw -MinWidth 1000 -MinHeight 660
    Add-SysPilotAssistantToWindow -Win $ucw -Context 'Show-SysPilotUpdateCenterWindow'
    # Auto-Scan DIREKT starten (vor ShowDialog): der Job laeuft im
    # Hintergrund, Log/Listen aktualisieren sobald das Fenster sichtbar ist.
    # Loaded-Event war unzuverlaessig - kein sichtbares Ergebnis.
    if (-not $fc.ucBusy) {
        $fc.ucBusy=$true; & $ucLog '--- Auto-Scan beim Oeffnen ---'
        & $startJob $fc.ucScanCode @{}
        $fc.StatusText.Text='Scan laeuft ...'; $fc.StatusText.Foreground=[Windows.Media.BrushConverter]::new().ConvertFrom('#FFB0B0C0')
    }
    [void]$ucw.ShowDialog()
}

function Show-SysPilotFailedUpdates {
    <# Liste fehlgeschlagener Updates: Retry (silent/interaktiv/admin),
       manuell per Terminal, KI-Suche, prefs merken. #>
    # Auto-Check: erledigte Eintraege (z.B. manuell aktualisiert) entfernen
    $pre = @((Read-SysPilotUpdateState).Failed)
    if ($pre.Count -gt 0) {
        Write-Host "  Pruefe automatisiert erledigte Eintraege ..." -ForegroundColor DarkGray
        try {
            $rc = Sync-SysPilotFailedUpdates
            if ($rc.Removed -gt 0) {
                Write-Host ("  [OK] {0} erledigte(s) Update(s) entfernt: {1}" -f $rc.Removed, ($rc.Names -join ', ')) -ForegroundColor Green
            }
        } catch { }
    }
    $st = Read-SysPilotUpdateState
    $failed = @($st.Failed)
    if ($failed.Count -eq 0) {
        Write-Host "  [OK] Keine fehlgeschlagenen Updates." -ForegroundColor Green
        Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
        return
    }
    while ($true) {
        $items = foreach ($f in $failed) {
            $pref = Get-SysPilotUpdatePrefs -Id $f.Id
            $prefTxt = ''
            if ($pref.Mode -ne 'silent' -or $pref.Admin) { $prefTxt = "  [${($pref.Mode)},$(if($pref.Admin){'admin'}else{'user'})]" }
            $kindTxt = switch ($f.Kind) { 'not-applicable' { ' [winget: nicht anwendbar]' } 'publisher' { ' [winget: Publisher-Methode]' } 'admin' { ' [Admin noetig]' } 'timeout' { ' [Timeout]' } default { '' } }
            @{ Label = ("{0}  [{1}]  Fehler x{2}  {3}{4}{5}" -f $f.Name, $f.Source, $f.Count, $prefTxt, $kindTxt, $(if ($f.Error) { "  -- $($f.Error.Substring(0,[Math]::Min(50,$f.Error.Length)))" } else { '' })); Color = 'Yellow'; Tag = $f }
        }
        $items += @{ Label = 'Einstellungen (globale Defaults)'; Color = 'Cyan'; Tag = '__settings' }
        $hopeless = @($failed | Where-Object { $_.Kind -in @('not-applicable','publisher') })
        if ($hopeless.Count -gt 0) {
            $items += @{ Label = "Nicht-anwendbare als erledigt markieren ($($hopeless.Count))"; Color = 'DarkYellow'; Tag = '__done_na' }
        }
        $items += @{ Label = 'Liste leeren (vergessen)'; Color = 'DarkGray'; Tag = '__clear' }
        $items += @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = '__back' }

        $sel = Show-SysPilotArrowMenu -Items $items -Title "Fehlgeschlagene Updates ($($failed.Count))" -Footer 'Pfeiltasten, Enter = waehlen, Esc = zurueck'
        if ($null -eq $sel -or $sel -eq '__back') { return }
        if ($sel -eq '__clear') {
            if (Confirm-SysPilot "Alle $($failed.Count) Eintraege vergessen?") {
                $st.Failed = @(); Write-SysPilotUpdateState $st; return
            }
            continue
        }
        if ($sel -eq '__settings') { Show-SysPilotUpdatePrefsMenu; $failed = @((Read-SysPilotUpdateState).Failed); continue }
        if ($sel -eq '__done_na') {
            $hopeless = @($failed | Where-Object { $_.Kind -in @('not-applicable','publisher') })
            if (Confirm-SysPilot "$($hopeless.Count) Eintraege entfernen? (winget kann diese Apps nicht aktualisieren - nur manuell/installierbar)") {
                $st2 = Read-SysPilotUpdateState
                $st2.Failed = @($st2.Failed | Where-Object { $_.Kind -notin @('not-applicable','publisher') })
                Write-SysPilotUpdateState $st2
                Write-Host "  [OK] $($hopeless.Count) Eintraege entfernt." -ForegroundColor Green
                return
            }
            continue
        }

        # Einzel-Item: Detail-Aktionen
        Show-SysPilotFailedItemActions -Item $sel
        $failed = @((Read-SysPilotUpdateState).Failed)
    }
}

function Show-SysPilotFailedItemActions {
    param([Parameter(Mandatory)]$Item)
    $pref = Get-SysPilotUpdatePrefs -Id $Item.Id
    Write-Host ""
    Write-Host "  --------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  $($Item.Name)  [$($Item.Source)]  ID: $($Item.Id)" -ForegroundColor Cyan
    Write-Host "  Fehler: $($Item.Error)  (Versuche: $($Item.Count))" -ForegroundColor DarkGray
    Write-Host "  Einstellung: Modus=$($pref.Mode) Admin=$($pref.Admin)" -ForegroundColor DarkGray
    if ($Item.Kind -eq 'not-applicable') {
        Write-Host "  ! winget meldet: kein anwendbares Upgrade (andere Quelle/Architektur)." -ForegroundColor Yellow
        Write-Host "    -> Installer meist nur manuell/interaktiv moeglich (Button 'Interaktiv' oder 'Manuell')." -ForegroundColor DarkGray
    } elseif ($Item.Kind -eq 'admin') {
        Write-Host "  ! Installer braucht Admin-Rechte -> 'Silent erneut' oder 'Admin' versucht elevated." -ForegroundColor Yellow
    } elseif ($Item.Kind -eq 'timeout') {
        Write-Host "  ! Update hat das Zeitlimit ueberschritten - evtl. grosse Datei oder Haenger." -ForegroundColor Yellow
    }
    Write-Host "  --------------------------------------------------------" -ForegroundColor DarkGray
    $acts = @(
        @{ Label = 'Silent erneut versuchen';            Color = 'Green';   Tag = 'silent' },
        @{ Label = 'Interaktiv installieren';            Color = 'Yellow';  Tag = 'interactive' },
        @{ Label = 'Als Administrator installieren';     Color = 'Magenta'; Tag = 'admin' },
        @{ Label = 'Manuell (Terminal mit Befehl)';       Color = 'Cyan';    Tag = 'manual' },
        @{ Label = 'KI-Suche / Installations-Hilfe';      Color = 'White';   Tag = 'search' },
        @{ Label = 'KI fragen: Fehler analysieren';       Color = 'Green';   Tag = 'kiask' },
        @{ Label = 'Anderer Paketmanager (choco/scoop) suchen'; Color = 'Green';  Tag = 'altpm' },
        @{ Label = 'Web-Quellen/Versionen suchen (automatisiert)'; Color = 'Cyan'; Tag = 'websrc' },
        @{ Label = 'Einstellung aendern (dauerhaft fuer App)'; Color = 'DarkGray'; Tag = 'prefs' },
        @{ Label = 'Als erledigt markieren (entfernen)';  Color = 'DarkGray'; Tag = 'done' },
        @{ Label = 'Zurueck';                             Color = 'DarkGray'; Tag = 'back' }
    )
    $a = Show-SysPilotArrowMenu -Items $acts -Title $Item.Name -Footer 'Enter = Aktion, Esc = zurueck'
    if (-not $a -or $a -eq 'back') { return }
    switch ($a) {
        'silent' {
            $ok = $false
            if ($Item.Source -eq 'chocolatey') {
                $cr = Invoke-SysPilotChocoUpgradeAuto -Pkg $Item.Id
                $ok = $cr.Ok
                if (-not $ok -and $cr.Error) { Write-Host "     $($cr.Error)" -ForegroundColor DarkGray }
            } else { $ok = Invoke-SysPilotCatalogWingetSilent -Id $Item.Id }
            if ($ok) { Remove-SysPilotFailedUpdate -Id $Item.Id; Write-Host "  [OK] Aktualisiert." -ForegroundColor Green }
            else { Write-Host "  [!] Erneut fehlgeschlagen." -ForegroundColor Red }
        }
        'interactive' {
            Write-Host "  Starte interaktiven Installer ..." -ForegroundColor Cyan
            if ($Item.Source -eq 'chocolatey') { $choco = Get-SysPilotChocoExe; if ($choco) { & $choco upgrade $Item.Id } }
            else { $w = Get-SysPilotWingetExe; if ($w) { & $w upgrade --id $Item.Id --exact --accept-package-agreements --accept-source-agreements } }
            if (Confirm-SysPilot "Hat die Installation geklappt? (Eintrag entfernen)") { Remove-SysPilotFailedUpdate -Id $Item.Id }
        }
        'admin' {
            Write-Host "  elevations-start (UAC) ..." -ForegroundColor Cyan
            $args = @('upgrade','--id',$Item.Id,'--exact','--accept-package-agreements','--accept-source-agreements')
            $r = Invoke-SysPilotWingetElevated -ArgList $args
            if ($r.Ok) { Remove-SysPilotFailedUpdate -Id $Item.Id; Write-Host "  [OK]" -ForegroundColor Green }
            else { Write-Host "  [!] $($r.Error)" -ForegroundColor Red }
        }
        'altpm' {
            # Anderer Paketmanager: Paket in choco/scoop suchen und installieren.
            # Bei not-applicable/apps die schon installiert sind -> -Adopt
            # (Warnung: choco-Installation ersetzt die vorhandene).
            $q = "$($Item.Name) $($Item.Id)"
            if (Show-SysPilotAltManagerInstallMenu -Query $q -Title "Alt-Manager: $($Item.Name)" -Adopt) {
                Remove-SysPilotFailedUpdate -Id $Item.Id
                Write-Host "  [OK] Eintrag entfernt - App wird jetzt vom anderen Manager verwaltet." -ForegroundColor Green
            }
        }
        'websrc' {
            # Letzte Stufe: Web-Kataloge mit automatisierten Versionen
            $q = "$($Item.Name) $($Item.Id)"
            Show-SysPilotWebSourceVersionsMenu -Query $q
        }
        'manual' { Open-SysPilotManualUpdateTerminal -Rows @($Item) }
        'search' {
            $q = "$($Item.Name) windows installieren winget $($Item.Id)"
            Start-SysPilotAiSearch -Query $q
        }
        'kiask' {
            # KI-Assistenz: Fehler analysieren lassen (nutzt alle
            # konfigurierten Provider, lokal + kostenlos)
            if (Get-Command Show-SysPilotAiQuickAsk -ErrorAction SilentlyContinue) {
                $ctx = "App: $($Item.Name) (ID: $($Item.Id), Quelle: $($Item.Source))`n" +
                       "Installiert: $($Item.Installed)`n" +
                       "Fehler: $($Item.Error)`n" +
                       "Art: $($Item.Kind)"
                $sys = 'Du bist ein Windows-Update-Experte. Analysiere den Fehler kurz und konkret: probable Ursache + loesende Schritte. Deutsch, knapp.'
                Show-SysPilotAiQuickAsk -Prompt "Warum schlaegt dieses Update fehl und was kann ich tun?`n$ctx" -System $sys -Title "KI-Analyse: $($Item.Name)" | Out-Null
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            } else { Write-Host '  KI-Assistenz-Modul nicht geladen.' -ForegroundColor Red }
        }
        'prefs'   { Show-SysPilotItemPrefsMenu -Id $Item.Id }
        'done'    { Remove-SysPilotFailedUpdate -Id $Item.Id; Write-Host "  Entfernt." -ForegroundColor DarkGray }
    }
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
}

function Invoke-SysPilotCatalogWingetSilent {
    param([Parameter(Mandatory)][string]$Id)
    $winget = Get-SysPilotWingetExe
    if (-not $winget) { return $false }
    $row = [pscustomobject]@{ Id=$Id; Name=$Id; Source='winget' }
    $r = Invoke-SysPilotWingetUpdateAuto -Row $row -Silent -TimeoutSec 900 -AllowElevated -Quiet
    return $r.Ok
}

function Show-SysPilotItemPrefsMenu {
    param([Parameter(Mandatory)][string]$Id)
    $pref = Get-SysPilotUpdatePrefs -Id $Id
    $m = Show-SysPilotArrowMenu -Items @(
        @{ Label = "Modus: silent (aktuell: $($pref.Mode))";        Color = 'Green';  Tag = 'silent' },
        @{ Label = "Modus: interaktiv (aktuell: $($pref.Mode))";   Color = 'Yellow'; Tag = 'interactive' },
        @{ Label = "Modus: manuell - nie auto (aktuell: $($pref.Mode))"; Color = 'Cyan'; Tag = 'manual' },
        @{ Label = "Modus: fragen (aktuell: $($pref.Mode))";       Color = 'White';  Tag = 'ask' },
        @{ Label = "Admin: $(if($pref.Admin){'AN'}else{'aus'}) - umschalten"; Color = 'Magenta'; Tag = 'admin' },
        @{ Label = 'App-Einstellung loeschen (auf Defaults)';       Color = 'DarkGray'; Tag = 'clear' },
        @{ Label = 'Zurueck';                                       Color = 'DarkGray'; Tag = 'back' }
    ) -Title "Einstellung: $Id" -Footer 'Enter = waehlen, Esc = zurueck'
    if (-not $m -or $m -eq 'back') { return }
    switch ($m) {
        'silent'       { Set-SysPilotUpdatePrefs -Id $Id -Mode 'silent';       Write-Host "  Modus=silent gespeichert." -ForegroundColor Green }
        'interactive'  { Set-SysPilotUpdatePrefs -Id $Id -Mode 'interactive';  Write-Host "  Modus=interaktiv gespeichert." -ForegroundColor Green }
        'manual'       { Set-SysPilotUpdatePrefs -Id $Id -Mode 'manual';       Write-Host "  Modus=manuell gespeichert (Auto-Update ueberspringt)." -ForegroundColor Green }
        'ask'          { Set-SysPilotUpdatePrefs -Id $Id -Mode 'ask';          Write-Host "  Modus=fragen gespeichert." -ForegroundColor Green }
        'admin'        { Set-SysPilotUpdatePrefs -Id $Id -Admin (-not $pref.Admin); Write-Host "  Admin=$(if(-not $pref.Admin){'AN'}else{'aus'}) gespeichert." -ForegroundColor Green }
        'clear'        { Set-SysPilotUpdatePrefs -Id $Id -Clear;              Write-Host "  App-Einstellung geloescht." -ForegroundColor DarkGray }
    }
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
}

function Show-SysPilotUpdatePrefsMenu {
    <# Globale Defaults fuer den Auto-Update. #>
    $st = Read-SysPilotUpdateState
    $mode = if ($st.Defaults.Mode) { $st.Defaults.Mode } else { 'silent' }
    $adm  = [bool]$st.Defaults.Admin
    Write-Host ""
    Write-Host "  GLOBALE UPDATE-EINSTELLUNGEN" -ForegroundColor Cyan
    Write-Host "  ----------------------------------------" -ForegroundColor DarkGray
    Write-Host "  Modus: $mode | Admin: $(if($adm){'AN'}else{'aus'})" -ForegroundColor Green
    Write-Host "  (App-spezifische Einstellungen ueberschreiben diese.)" -ForegroundColor DarkGray
    $sel = Show-SysPilotArrowMenu -Items @(
        @{ Label = "Standard-Modus: silent (aktuell: $mode)";       Color = 'Green';  Tag = 'silent' },
        @{ Label = "Standard-Modus: interaktiv (aktuell: $mode)";  Color = 'Yellow'; Tag = 'interactive' },
        @{ Label = "Standard-Modus: fragen (aktuell: $mode)";      Color = 'White';  Tag = 'ask' },
        @{ Label = "Admin-Standard: $(if($adm){'AN'}else{'aus'}) - umschalten"; Color = 'Magenta'; Tag = 'admin' },
        @{ Label = 'Zurueck';                                       Color = 'DarkGray'; Tag = 'back' }
    ) -Title 'Update-Einstellungen' -Footer 'Enter = waehlen, Esc = zurueck'
    if (-not $sel -or $sel -eq 'back') { return }
    switch ($sel) {
        'silent'       { Set-SysPilotUpdatePrefs -Global -Mode 'silent';       Write-Host "  Standard=silent." -ForegroundColor Green }
        'interactive'  { Set-SysPilotUpdatePrefs -Global -Mode 'interactive';  Write-Host "  Standard=interaktiv." -ForegroundColor Green }
        'ask'          { Set-SysPilotUpdatePrefs -Global -Mode 'ask';          Write-Host "  Standard=fragen." -ForegroundColor Green }
        'admin'        { Set-SysPilotUpdatePrefs -Global -Admin (-not $adm);   Write-Host "  Admin-Standard umgeschaltet." -ForegroundColor Green }
    }
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
}

function Show-SysPilotAutoUpdateMenu {
    $task = Get-SysPilotUpdateTask
    $state = if ($task) { "AKTIV (taeglich 12:00, silent)" } else { 'aus' }
    Write-Host ""
    Write-Host "  AUTOMATISCHE UPDATES" -ForegroundColor Cyan
    Write-Host "  ----------------------------------------" -ForegroundColor DarkGray
    Write-Host "  Status: $state" -ForegroundColor $(if ($task) {'Green'} else {'DarkGray'})
    Write-Host "  Die Aufgabe aktualisiert taeglich alle winget-/choco-Updates" -ForegroundColor DarkGray
    Write-Host "  silent (Admin-Rechte der Aufgabe). Ergebnisse im SysPilot-Log." -ForegroundColor DarkGray
    Write-Host ""
    $items = @()
    if ($task) { $items += @{ Label = 'Automatische Updates DEAKTIVIEREN'; Color = 'Red'; Tag = 'off' } }
    else       { $items += @{ Label = 'Automatische Updates AKTIVIEREN (taeglich 12:00)'; Color = 'Green'; Tag = 'on' } }
    $items += @{ Label = 'Jetzt einmalig alle Updates still installieren'; Color = 'Yellow'; Tag = 'now' }
    $items += @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = 'back' }
    $sel = Show-SysPilotArrowMenu -Items $items -Title 'Auto-Update' -Footer 'Enter = waehlen, Esc = zurueck'
    if (-not $sel -or $sel -eq 'back') { return }
    switch ($sel) {
        'on'  {
            if (-not (Test-SysPilotAdmin)) { Write-Host "  [!] Admin noetig fuer geplante Aufgabe." -ForegroundColor Yellow; Read-SysPilotChoice 'Weiter' | Out-Null; return }
            Install-SysPilotUpdateTask
            Write-Host "  [OK] Taeglich 12:00, silent, Administrator." -ForegroundColor Green
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
        }
        'off' { Remove-SysPilotUpdateTask; Write-Host "  Deaktiviert." -ForegroundColor Green; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
        'now' {
            if (-not (Confirm-SysPilot "Alle gefundenen Updates JETZT still installieren?`n(Das kann laenger dauern und Installer ohne Silent-Support schlagen fehl)") ) { return }
            $r = Invoke-SysPilotAutoUpdate
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
        }
    }
}

Export-ModuleMember -Function Show-SysPilotUpdateCenter, Show-SysPilotUpdateCenterWindow, Get-SysPilotUpdateCatalog,
    Get-SysPilotUpdateCatalogCategories, Get-SysPilotWingetUpgrades, Find-SysPilotWingetSearch, Get-SysPilotChocoOutdated,
    Get-SysPilotGithubLatest, Select-SysPilotGithubAsset, Find-SysPilotCatalogInstalled,
    Invoke-SysPilotAutoUpdate, Get-SysPilotUpdateTask, Install-SysPilotUpdateTask,
    Remove-SysPilotUpdateTask, Show-SysPilotAutoUpdateMenu,
    Show-SysPilotFailedUpdates, Show-SysPilotFailedUpdatesWindow, Show-SysPilotUpdatePrefsMenu, Get-SysPilotUpdatePrefs,
    Set-SysPilotUpdatePrefs, Invoke-SysPilotWingetElevated, Open-SysPilotManualUpdateTerminal,
    Read-SysPilotUpdateState, Write-SysPilotUpdateState, Add-SysPilotFailedUpdate,
    Remove-SysPilotFailedUpdate, Sync-SysPilotFailedUpdates, Invoke-SysPilotWingetRaw, Invoke-SysPilotWingetUpdate,
    Get-SysPilotUpdateFailKind, Get-SysPilotChocoExe,
    Invoke-SysPilotWingetUpdateAuto, Invoke-SysPilotAltManagerUpgrade,
    Invoke-SysPilotChocoUpgradeAuto, Invoke-SysPilotScoopUpdateAuto,
    Get-SysPilotScoopExeLocal, Get-SysPilotChocoInstalledNames,
    Get-SysPilotScoopInstalledNames, Get-SysPilotAltManagerCandidates,
    Get-SysPilotSearchTerms, Find-SysPilotChocoRemoteCandidates,
    Find-SysPilotScoopRemoteCandidates, Invoke-SysPilotChocoInstallPkg,
    Get-SysPilotWingetExe,
    Show-SysPilotAltManagerInstallMenu,
    Get-SysPilotWebSourceVersions, Show-SysPilotWebSourceVersionsMenu,
    Get-SysPilotAiPortalHint, Show-SysPilotWebCatalogSearch,
    Test-SysPilotUrlReachable, Get-SysPilotAiAlternatives, Show-SysPilotAiAlternativesMenu,
    Start-SysPilotAiSearch, Find-SysPilotCatalogSearch
