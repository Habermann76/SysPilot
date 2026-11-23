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
    $argStr = ($argList | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    $proc = $null
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.Arguments = $argStr
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
            try { $proc.Kill() } catch { }
            Write-SysPilotLog "winget Timeout nach ${TimeoutSec}s: $argStr"
            return @{ Ok = $false; Text = ''; Error = "Timeout nach $TimeoutSec s"; ExitCode = $null; Timeout = $true }
        }
        $proc.WaitForExit()   # async Reader absichern
        $out = "$($outTask.Result)`n$($errTask.Result)"
        $code = $proc.ExitCode
        $tail = (($out -split "`r?`n") | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 8) -join ' | '
        return @{ Ok = ($code -eq 0); Text = $out; Error = $(if ($code -eq 0) { '' } else { $tail }); ExitCode = $code; Timeout = $false }
    } catch {
        return @{ Ok = $false; Text = ''; Error = $_.Exception.Message; ExitCode = $null; Timeout = $false }
    } finally {
        if ($proc) { $proc.Dispose() }
    }
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
        $out = & $exe @args 2>&1 | Out-String
        $code = $LASTEXITCODE
    } else {
        if (-not $Quiet) { Write-Host "     choco braucht Admin - UAC folgt ..." -ForegroundColor DarkGray }
        $p = Start-Process $exe -ArgumentList $args -Verb RunAs -Wait -PassThru
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
    $out = & $exe update $App 2>&1 | Out-String
    $code = $LASTEXITCODE
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
       gesplittet, Versionen entfernt, Publisher-Präfix weg. #>
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
    foreach ($t in (Get-SysPilotSearchTerms -Query $Query)) {
        $out = & $exe search $t --limit-output 2>&1 | Out-String
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
    foreach ($t in (Get-SysPilotSearchTerms -Query $Query)) {
        $out = & $exe search $t 2>&1 | Out-String
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
    if (Test-SysPilotAdmin) { $out = & $exe @args 2>&1 | Out-String; $code=$LASTEXITCODE }
    else {
        $p = Start-Process $exe -ArgumentList $args -Verb RunAs -Wait -PassThru
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
    $chocoC = @(Find-SysPilotChocoRemoteCandidates -Query $Query)
    $scoopC = @(Find-SysPilotScoopRemoteCandidates -Query $Query)
    if ($chocoC.Count -eq 0 -and $scoopC.Count -eq 0) {
        Write-Host "  Keine Pakete in Chocolatey/Scoop gefunden." -ForegroundColor Yellow
        Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
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
        & $se install $app 2>&1 | Out-Host
        $ok = ($LASTEXITCODE -eq 0)
        if ($ok) { Write-Host "  [OK] $app installiert." -ForegroundColor Green; Write-SysPilotLog "scoop install $app OK (alt-manager)" }
        else { Write-Host "  [!] scoop exit $LASTEXITCODE" -ForegroundColor Red }
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
    $r = Invoke-SysPilotWingetRaw -ArgList @('upgrade') -TimeoutSec 240
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
            Write-Host "  -> Chocolatey selbst aktualisieren ($($Matches[1])) ..." -ForegroundColor DarkGray
            & $exe upgrade chocolatey -y --no-color --limit-output 2>&1 | Out-Null
            Write-SysPilotLog "choco self-update (Exit $LASTEXITCODE)"
        }
    } catch { }
}

function Get-SysPilotChocoOutdated {
    $exe = Get-SysPilotChocoExe
    if (-not $exe) { return @() }
    Update-SysPilotChocoSelf
    try {
        $out = & $exe outdated --no-color --limit-output 2>&1 | Out-String
    } catch { return @() }
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
        @{ Cat='Multimedia'; Name='Audacity';              WingetId='Audacity.Audacity';            Gh='audacity/audacity';                Page='https://www.audacityteam.org/' },
        @{ Cat='Multimedia'; Name='LMMS';                  WingetId='LMMS.LMMS';                    Gh='LMMS/lmms';                        Page='https://lmms.io/' },
        @{ Cat='Multimedia'; Name='MuseScore';             Gh='musescore/MuseScore';                Page='https://musescore.org/' },
        @{ Cat='Multimedia'; Name='iTunes';                WingetId='Apple.iTunes';                 Page='https://www.apple.com/itunes/' },

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
        @{ Cat='Sicherheit'; Name='HitmanPro';              Page='https://www.sophos.com/de-de/products/hitman/' }
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
    return $best
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
        $r = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest" -Headers $script:_ghHeaders -TimeoutSec $TimeoutSec -ErrorAction Stop
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
    <# Download mit Fortschritt nach $env:USERPROFILE\Downloads (bzw. PortableApps
       nicht noetig - Downloads-Ordner ist der Natuerliche Ort). #>
    param([Parameter(Mandatory)][string]$Url,
          [Parameter(Mandatory)][string]$OutFile,
          [string]$Label = 'Download')
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $ProgressPreference = 'Continue'
    try {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 600 -ErrorAction Stop
        $len = (Get-Item $OutFile).Length
        Write-Host ("  {0}: {1:N1} MB -> {2}" -f $Label, ($len/1MB), $OutFile) -ForegroundColor Green
        return @{ Ok = $true; Path = $OutFile; SizeMB = [math]::Round($len/1MB,1); Error = '' }
    } catch {
        if (Test-Path $OutFile) { Remove-Item $OutFile -Force -ErrorAction SilentlyContinue }
        return @{ Ok = $false; Path = $null; SizeMB = 0; Error = $_.Exception.Message }
    }
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
        Write-Host "           SYSPilot UPDATE / DOWNLOAD CENTER" -ForegroundColor Cyan
        Write-Host "           winget + Chocolatey + Katalog + GitHub + MajorGeeks" -ForegroundColor Cyan
        Write-Host "  ========================================================" -ForegroundColor Cyan
        Write-Host ("  Quellen: winget={0}  choco={1}  Katalog-Apps={2}" -f
            $(if ($winget) { 'OK' } else { 'FEHLT' }),
            $(if ($choco)  { 'OK' } else { 'FEHLT' }),
            $catN) -ForegroundColor DarkGray
        Write-Host ""

        $items = @(
            @{ Label = 'Installierte Programme auf Updates pruefen (winget + Chocolatey)'; Color = 'Green'; Tag = 'scan' },
            @{ Label = 'Programm-Katalog (Kategorien: Browser, Multimedia, Dev, Tools, Sicherheit ...)'; Color = 'Cyan'; Tag = 'catalog' },
            @{ Label = 'Fehlgeschlagene Updates (Kontrolle, Retry, manuell, KI-Suche)'; Color = 'Red'; Tag = 'failed' },
            @{ Label = 'Automatische Updates (taeglich silent, geplante Aufgabe)'; Color = 'Yellow'; Tag = 'auto' },
            @{ Label = 'Web-Kataloge oeffnen (Heise, FileHippo, Uptodown, CHIP, MajorGeeks)'; Color = 'Yellow'; Tag = 'webcat' },
            @{ Label = 'Paketmanager (winget/choco/scoop/npm/pip/dotnet/PSGallery + WSL)' ; Color = 'Cyan'; Tag = 'pkgs' },
            @{ Label = 'Quellen-Status (was ist verfuegbar?)'; Color = 'White'; Tag = 'status' },
            @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = $null }
        )
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'SysPilot Update-Center' -Footer 'Pfeiltasten, Enter = auswaehlen, Esc = zurueck'
        if ($null -eq $sel) { return }

        switch ($sel) {
            'scan'    { Show-SysPilotUpdateScan }
            'catalog' { Show-SysPilotCatalogBrowser }
            'auto'    { Show-SysPilotAutoUpdateMenu }
            'failed'  { Show-SysPilotFailedUpdates }
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
    Write-Host "  Web-Kataloge: Heise ( Suche ), FileHippo/Uptodown/CHIP (Links, Bot-Schutz)" -ForegroundColor Yellow
    Write-Host ""
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
}

function Show-SysPilotWebCatalogs {
    <# Web-Katalog-Suche: Provider -> site:-Query -> Suchmaschine
       (Ecosia/Brave/Google). Die Query ist auf die Download-Seiten des
       Providers zugeschnitten (site:-Operator), damit die Ergebnisse
       direkt zur Installationsdatei fuehren. #>
    $q = Read-SysPilotChoice 'Suchbegriff fuer Web-Kataloge' '7-Zip'
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
        if ($a.WingetId) { $src += 'winget' }
        if ($a.Gh)       { $src += 'github' }
        if ($a.Mg)       { $src += 'majorgeeks' }
        if ($a.Page)     { $src += 'web' }
        $instTxt = if ($inst) { "  [installiert: $($inst.Version)]" } else { '' }
        @{ Label = ("{0}  [{1}]{2}" -f $a.Name, ($src -join '+'), $instTxt); Color = 'White'; Tag = $a }
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
        Write-Host "  Kategorie: $($App.Cat)" -ForegroundColor DarkGray
        if ($App.WingetId) { Write-Host "  winget-ID: $($App.WingetId)" -ForegroundColor DarkGray }
        if ($App.Gh)       { Write-Host "  GitHub:    $($App.Gh)" -ForegroundColor DarkGray }
        if ($inst)         { Write-Host "  Installiert: $($inst.Version)" -ForegroundColor Green }
        else               { Write-Host "  Installiert: nein" -ForegroundColor DarkGray }
        Write-Host "  --------------------------------------------------------" -ForegroundColor DarkGray

        $acts = @()
        if ($App.WingetId) { $acts += @{ Label = 'winget: installieren / aktualisieren'; Color = 'Green';  Tag = 'winget' } }
        if ($App.Gh)       { $acts += @{ Label = 'GitHub: neueste Version + Download'; Color = 'Cyan';   Tag = 'github' } }
        if ($App.Mg)       { $acts += @{ Label = 'MajorGeeks: Version + Mirror-Download'; Color = 'Yellow'; Tag = 'mg' } }
        if ($App.Page)     { $acts += @{ Label = 'Offizielle Seite oeffnen'; Color = 'White'; Tag = 'page' } }
        $acts += @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = 'back' }

        $a = Show-SysPilotArrowMenu -Items $acts -Title $App.Name -Footer 'Enter = Aktion, Esc = zurueck'
        if ($null -eq $a -or $a -eq 'back') { return }

        switch ($a) {
            'winget' { Invoke-SysPilotCatalogWinget -App $App }
            'github' { Invoke-SysPilotCatalogGithub -App $App }
            'mg'     { Invoke-SysPilotCatalogMajorGeeks -App $App }
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
    Write-Host ""
    Write-Host "  winget $(if ($isUpgrade) {'upgrade'} else {'install'}) $($App.WingetId) ..." -ForegroundColor Cyan
    $args = @($(if ($isUpgrade) {'upgrade'} else {'install'}), '--id', $App.WingetId, '--exact',
              '--accept-package-agreements','--accept-source-agreements','--disable-interactivity')
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
    if (-not $r.Ok) { Write-Host "  [!] Download fehlgeschlagen: $($r.Error)" -ForegroundColor Red; Read-SysPilotChoice 'Weiter' | Out-Null; return }

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
    if (Get-Command Get-SysPilotPmOutdated -ErrorAction SilentlyContinue) { $rows += @(Get-SysPilotPmOutdated) }
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
        $p = Start-Process -FilePath $exe -ArgumentList $argStr -Verb RunAs -Wait -PassThru -ErrorAction Stop
        return @{ Ok = ($p.ExitCode -eq 0); ExitCode = $p.ExitCode; Error = '' }
    } catch {
        # Fallback: elevated PowerShell
        try {
            $cmd = "& '$exe' $argStr"
            $p2 = Start-Process powershell.exe -ArgumentList "-NoProfile","-Command",$cmd -Verb RunAs -Wait -PassThru -ErrorAction Stop
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
    <# DuckDuckGo-Suche als Installations-Hilfe (wie SysPilot 'aisearch'). #>
    param([Parameter(Mandatory)][string]$Query)
    Start-Process ('https://duckduckgo.com/?q=' + [Uri]::EscapeDataString($Query))
}

function Show-SysPilotFailedUpdates {
    <# Liste fehlgeschlagener Updates: Retry (silent/interaktiv/admin),
       manuell per Terminal, KI-Suche, prefs merken. #>
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
        @{ Label = 'Anderer Paketmanager (choco/scoop) suchen'; Color = 'Green';  Tag = 'altpm' },
        @{ Label = 'Einstellung aendern (dauerhaft für App)'; Color = 'DarkGray'; Tag = 'prefs' },
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
        'manual' { Open-SysPilotManualUpdateTerminal -Rows @($Item) }
        'search' {
            $q = "$($Item.Name) windows installieren winget $($Item.Id)"
            Start-SysPilotAiSearch -Query $q
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

Export-ModuleMember -Function Show-SysPilotUpdateCenter, Get-SysPilotUpdateCatalog,
    Get-SysPilotUpdateCatalogCategories, Get-SysPilotWingetUpgrades, Get-SysPilotChocoOutdated,
    Get-SysPilotGithubLatest, Select-SysPilotGithubAsset, Find-SysPilotCatalogInstalled,
    Invoke-SysPilotAutoUpdate, Get-SysPilotUpdateTask, Install-SysPilotUpdateTask,
    Remove-SysPilotUpdateTask, Show-SysPilotAutoUpdateMenu,
    Show-SysPilotFailedUpdates, Show-SysPilotUpdatePrefsMenu, Get-SysPilotUpdatePrefs,
    Set-SysPilotUpdatePrefs, Invoke-SysPilotWingetElevated, Open-SysPilotManualUpdateTerminal,
    Read-SysPilotUpdateState, Write-SysPilotUpdateState, Add-SysPilotFailedUpdate,
    Remove-SysPilotFailedUpdate, Invoke-SysPilotWingetRaw, Invoke-SysPilotWingetUpdate,
    Get-SysPilotUpdateFailKind, Get-SysPilotChocoExe,
    Invoke-SysPilotWingetUpdateAuto, Invoke-SysPilotAltManagerUpgrade,
    Invoke-SysPilotChocoUpgradeAuto, Invoke-SysPilotScoopUpdateAuto,
    Get-SysPilotScoopExeLocal, Get-SysPilotChocoInstalledNames,
    Get-SysPilotScoopInstalledNames, Get-SysPilotAltManagerCandidates,
    Get-SysPilotSearchTerms, Find-SysPilotChocoRemoteCandidates,
    Find-SysPilotScoopRemoteCandidates, Invoke-SysPilotChocoInstallPkg,
    Show-SysPilotAltManagerInstallMenu
