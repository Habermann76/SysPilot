# SysPilot - Package Managers (0.9.4.9)
# Einheitliche Schicht ueber ALLE Paketmanager: WinGet, Chocolatey, Scoop,
# Homebrew, APT, DNF, Pacman, Flatpak, Snap, pip, npm, Bun, .NET Tool,
# PowerShell Gallery. Idee nach UniGetUI (github.com/Devolutions/UniGetUI).
# Auf Windows sind APT/DNF/Pacman/Flatpak/Snap/Homebrew nur ueber WSL
# erreichbar - das Modul erkennt das automatisch.
#Requires -Version 5.1

$script:SysPilotRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)

# =====================================================================
# MANAGER-REGISTRY
# =====================================================================

function Get-SysPilotPackageManagerDefs {
    <# Statische Registry aller unterstuetzten Paketmanager.
       Detect/Upgrade werden pro Manager als Scriptblock geliefert. #>
    return @(
        @{ Id='winget';      Name='WinGet';               Kind='native'; Exe='winget';      UpgradeHint='winget upgrade --id <id> --exact' }
        @{ Id='chocolatey';  Name='Chocolatey';           Kind='native'; Exe='choco';       UpgradeHint='choco upgrade <id> -y' }
        @{ Id='scoop';       Name='Scoop';                Kind='native'; Exe='scoop';       UpgradeHint='scoop update <app>' }
        @{ Id='pip';         Name='pip (Python)';         Kind='native'; Exe='pip';         UpgradeHint='pip install --upgrade <pkg>' }
        @{ Id='npm';         Name='npm (Node.js)';        Kind='native'; Exe='npm';         UpgradeHint='npm install -g <pkg>@latest' }
        @{ Id='bun';         Name='Bun';                  Kind='native'; Exe='bun';         UpgradeHint='bun upgrade' }
        @{ Id='dotnet';      Name='.NET Tool';            Kind='native'; Exe='dotnet';      UpgradeHint='dotnet tool update -g <id>' }
        @{ Id='psgallery';   Name='PowerShell Gallery';   Kind='builtin'; Exe='';            UpgradeHint='Update-Module <name> -Force' }
        @{ Id='brew';        Name='Homebrew';             Kind='posix';  Exe='brew';        UpgradeHint='brew upgrade <name>' }
        @{ Id='apt';         Name='APT (Debian/Ubuntu)';   Kind='wsl';    Exe='apt';         UpgradeHint='apt upgrade <pkg>' }
        @{ Id='dnf';         Name='DNF (Fedora/RHEL)';     Kind='wsl';    Exe='dnf';         UpgradeHint='dnf upgrade <pkg>' }
        @{ Id='pacman';      Name='Pacman (Arch)';         Kind='wsl';    Exe='pacman';      UpgradeHint='pacman -Syu <pkg>' }
        @{ Id='flatpak';     Name='Flatpak';               Kind='wsl';    Exe='flatpak';     UpgradeHint='flatpak update <app>' }
        @{ Id='snap';        Name='Snap';                  Kind='wsl';    Exe='snap';        UpgradeHint='snap refresh <name>' }
    )
}

function Get-SysPilotWslDistros {
    <# Echte WSL-Distributionen (ohne docker-desktop o.ae.). #>
    try {
        $raw = (& wsl.exe -l -q 2>$null) -join "`n"
        $names = @()
        foreach ($line in ($raw -split "`r?`n")) {
            $n = ($line -replace "`0", '').Trim()
            if ($n -and $n -notmatch 'docker-desktop|docker-desktop-data') { $names += $n }
        }
        return $names
    } catch { return @() }
}

function Get-SysPilotPackageManagers {
    <# Erkent/installierten Status aller Manager.
       Gibt @{Id;Name;Kind;Status;Path;Detail} zurueck. #>
    $out = @()
    $defs = Get-SysPilotPackageManagerDefs
    $distros = @(Get-SysPilotWslDistros)
    foreach ($d in $defs) {
        $st = @{ Id=$d.Id; Name=$d.Name; Kind=$d.Kind; Status='missing'; Path=''; Detail='' }
        if ($d.Kind -eq 'wsl') {
            if ($distros.Count -gt 0) {
                # Pruefe im Default-Distro ob das PM existiert
                $found = $false
                foreach ($distro in $distros) {
                    $chk = (& wsl.exe -d $distro -- sh -c "command -v $($d.Exe)" 2>$null)
                    if ($chk) { $found = $true; $st.Path = "wsl:$distro"; break }
                }
                if ($found) { $st.Status='installed'; $st.Detail='via WSL' }
            } else {
                $st.Status='wsl-needed'; $st.Detail='WSL-Distribution noetig'
            }
        } elseif ($d.Kind -eq 'builtin') {
            $st.Status='installed'; $st.Path='PowerShell'; $st.Detail='eingebaut'
        } else {
            $cmd = Get-Command $d.Exe -ErrorAction SilentlyContinue
            if ($cmd) { $st.Status='installed'; $st.Path=$cmd.Source }
            elseif ($d.Id -eq 'winget') {
                $w = "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe"
                if (Test-Path $w) { $st.Status='installed'; $st.Path=$w }
            }
        }
        $out += [pscustomobject]$st
    }
    return $out
}

# =====================================================================
# OUTDATED-SCAN pro Manager
# =====================================================================

function Repair-SysPilotScoopBuckets {
    <# Repariert Bucket-Git-Repos, die 'scoop update' blockieren:
       - korrupte remote-refs ('bad object refs/remotes/origin/...')
       - lokale Aenderungen, die den Merge verhindern (-> stash,
         bleibt recoverbar)
       Danach 'git pull --ff-only' auf den aktuellen Stand. #>
    $bucketsDir = Join-Path $env:USERPROFILE 'scoop\buckets'
    if (-not (Test-Path $bucketsDir)) { return }
    foreach ($b in (Get-ChildItem $bucketsDir -Directory -ErrorAction SilentlyContinue)) {
        $gitDir = Join-Path $b.FullName '.git'
        if (-not (Test-Path $gitDir)) { continue }
        # Stehende Lock-Datei eines abgebrochenen Git-Laufs entfernen
        Remove-Item (Join-Path $gitDir 'index.lock') -Force -ErrorAction SilentlyContinue
        # 1) Fetch testen; bei korrupten refs die defekten origin-refs
        #    explizit loeschen (for-each-ref LISTET broken refs nicht ->
        #    packed-refs-Eintrag bleibt sonst erhalten), dann remote
        #    neu eintragen + retry
        & git -C $b.FullName fetch origin --quiet 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  -> Bucket '$($b.Name)': korrupture remote-refs - repariere ..." -ForegroundColor DarkGray
            foreach ($r in @('refs/remotes/origin/master','refs/remotes/origin/main','refs/remotes/origin/HEAD')) {
                & git -C $b.FullName update-ref -d $r 2>$null
            }
            # Loose ref-Dateien unter refs/remotes/origin/ enthalten die
            # defekte SHA ebenfalls -> komplett entfernen (fetch legt sie
            # neu an); tmp_*-Packdateien sind Fetch-Leichen -> aufraeumen
            $looseRefs = Join-Path $b.FullName '.git\refs\remotes\origin'
            if (Test-Path $looseRefs) {
                Remove-Item (Join-Path $looseRefs '*') -Force -Recurse -ErrorAction SilentlyContinue
            }
            $packDir = Join-Path $b.FullName '.git\objects\pack'
            Get-ChildItem $packDir -Filter 'tmp_*' -File -ErrorAction SilentlyContinue |
                Remove-Item -Force -ErrorAction SilentlyContinue
            # Broken refs koennen update-ref -d nicht loesen ('reference
            # broken') -> Zeilen mit refs/remotes/origin/ direkt aus
            # packed-refs entfernen (inkl. '^'-peeled-Folgezeilen)
            $pr = Join-Path $b.FullName '.git\packed-refs'
            if (Test-Path $pr) {
                $kept = New-Object System.Collections.Generic.List[string]
                $skipPeel = $false
                foreach ($ln in (Get-Content $pr)) {
                    if ($ln -match 'refs/remotes/origin/') { $skipPeel = $true; continue }
                    if ($skipPeel -and $ln.StartsWith('^')) { continue }
                    $skipPeel = $false
                    $kept.Add($ln)
                }
                Set-Content -Path $pr -Value $kept -Encoding ASCII
            }
            $url = (& git -C $b.FullName remote get-url origin 2>$null | Out-String).Trim()
            if ($url) {
                & git -C $b.FullName remote remove origin 2>$null
                & git -C $b.FullName remote add origin $url 2>$null
            }
            & git -C $b.FullName fetch origin --quiet 2>$null
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  -> Bucket '$($b.Name)': Fetch weiterhin unmoeglich - uebersprungen." -ForegroundColor Yellow
                continue
            }
        }
        # 1b) Fehlendes Upstream-Tracking reparieren: 'git pull' ohne
        #     Tracking-Info bricht mit 'There is no tracking information
        #     for the current branch' ab und blockiert 'scoop update'
        #     komplett (Bucket bleibt ewig 'out of date').
        $sb = (& git -C $b.FullName status -sb 2>$null | Select-Object -First 1)
        if ($sb -match '^##\s+\S+\s*$') {
            Write-Host "  -> Bucket '$($b.Name)': Upstream-Tracking fehlt - wird gesetzt ..." -ForegroundColor DarkGray
            $def = (& git -C $b.FullName symbolic-ref --short refs/remotes/origin/HEAD 2>$null | ForEach-Object { $_ -replace '^origin/','' })
            if (-not $def) { $def = 'master' }
            $cur = (& git -C $b.FullName rev-parse --abbrev-ref HEAD 2>$null | Out-String).Trim()
            if ($cur) {
                & git -C $b.FullName branch --set-upstream-to="origin/$def" $cur 2>$null
                if ($LASTEXITCODE -ne 0) {
                    & git -C $b.FullName branch --set-upstream-to="origin/master" $cur 2>$null
                }
            }
        }
        # 2) Lokale Aenderungen stashen (recoverbar), dann ff-only pull
        $dirty = & git -C $b.FullName status --porcelain 2>$null
        if ($dirty) {
            Write-Host "  -> Bucket '$($b.Name)': lokale Aenderungen stashen ..." -ForegroundColor DarkGray
            & git -C $b.FullName stash push -u -m 'syspilot-autofix' --quiet 2>$null
        }
        & git -C $b.FullName pull --ff-only --quiet 2>$null
        if ($LASTEXITCODE -ne 0) {
            # ff-only unmoeglich -> auf origin-Stand zuruecksetzen (Bucket-Manifeste
            # sind upstream-verwaltet; stash enthaelt evtl. eigene Aenderungen)
            & git -C $b.FullName reset --hard '@{u}' --quiet 2>$null
            if ($LASTEXITCODE -ne 0) { & git -C $b.FullName reset --hard origin/master --quiet 2>$null }
            if ($LASTEXITCODE -ne 0) { & git -C $b.FullName reset --hard origin/main --quiet 2>$null }
        }
    }
}

function Update-SysPilotScoopBuckets {
    <# Aktualisiert Scoop-Buckets automatisch, wenn der 'bucket(s) out of
       date'-WARN auftritt. Drossel: hoechstens 1x pro 24h (Stamp-Datei
       in %LOCALAPPDATA%\SysPilot\autofix). Bei anhaltendem WARN werden
       die Bucket-Git-Repos repariert und erneut versucht. #>
    if (-not (Test-SysPilotAutoFixDue -Name 'scoop-buckets' -Hours 24)) { return $false }
    # KEIN Stamp vor dem Versuch: nur bei nachweislich behobenem WARN
    # stempeln - sonst bleibt ein hartnaeckiger WARN 24h sichtbar.
    Write-Host '  -> Scoop-Buckets veraltet - aktualisiere automatisch (scoop update) ...' -ForegroundColor DarkGray
    Write-Host '     Das kann eine Minute dauern (Buckets werden per Git gezogen).' -ForegroundColor DarkGray
    $out = (& scoop update 2>&1 | Out-String)
    # Nur relevante Zeilen zeigen - Git-Fetch-Laerm (refs, %, 'Already up to date')
    # sah bisher aus wie eine Flut aus Fehlern/Warnungen.
    $keep = @($out -split "`r?`n" | Where-Object {
        $_.Trim() -ne '' -and $_ -match '(?i)warn|error|fail|abort|out of date|updated|already up.to.date|scoop update|github\.com'
    })
    if ($keep.Count -eq 0) { $keep = @($out -split "`r?`n" | Select-Object -Last 6) }
    foreach ($l in ($keep | Select-Object -First 30)) { Write-Host "     $($l.Trim())" -ForegroundColor DarkGray }
    # Pruefen ob WARN noch besteht -> Bucket-Repos reparieren + retry
    # (scoop-WARNs sind nur via cmd /c auffangbar, siehe Invoke-SysPilotScoopRaw)
    $st = (cmd /c 'scoop status 2>&1' | Out-String)
    $fixed = ($st -notmatch 'out of date')
    if (-not $fixed) {
        Write-Host '  -> WARN besteht weiter - repariere Bucket-Repositories ...' -ForegroundColor DarkGray
        Repair-SysPilotScoopBuckets
        $out2 = (& scoop update 2>&1 | Out-String)
        $keep2 = @($out2 -split "`r?`n" | Where-Object {
            $_.Trim() -ne '' -and $_ -match '(?i)warn|error|fail|abort|updated|already up.to.date|scoop update'
        })
        if ($keep2.Count -eq 0) { $keep2 = @($out2 -split "`r?`n" | Select-Object -Last 6) }
        foreach ($l in ($keep2 | Select-Object -First 30)) { Write-Host "     $($l.Trim())" -ForegroundColor DarkGray }
        Write-SysPilotLog "Scoop-Buckets Retry nach Repo-Reparatur (Exit $LASTEXITCODE)"
        $st2 = (cmd /c 'scoop status 2>&1' | Out-String)
        $fixed = ($st2 -notmatch 'out of date')
    }
    if ($fixed) {
        Save-SysPilotAutoFixStamp -Name 'scoop-buckets'
        Write-SysPilotLog 'Scoop-Buckets automatisch aktualisiert: WARN behoben'
    } else {
        Write-SysPilotLog 'Scoop-Buckets Auto-Fix: WARN besteht weiterhin (kein Stamp - naechster Scan retryt)'
    }
    return $true
}

function Get-SysPilotScoopExePath {
    <# Direkter Pfad zur scoop.cmd (Shim) - bevorzugt gegenueber
       scoop.ps1, damit Invoke-SysPilotMonitoredProcess cmd /c nutzt. #>
    $shim = Join-Path $env:USERPROFILE 'scoop\shims\scoop.cmd'
    if (Test-Path $shim) { return $shim }
    $c = Get-Command scoop -ErrorAction SilentlyContinue
    if ($c) {
        if ($c.Source -match '\.ps1$') {
            $cmd = [IO.Path]::ChangeExtension($c.Source, '.cmd')
            if (Test-Path $cmd) { return $cmd }
        }
        return $c.Source
    }
    return $null
}

function Invoke-SysPilotScoopRaw {
    <# Fuehrt einen scoop-Befehl aus; bei 'bucket(s) out of date'-WARN
       werden die Buckets automatisch aktualisiert und der Befehl
       einmal wiederholt. Gibt die Output-Zeilen zurueck.
       WICHTIG: scoop.cmd schreibt WARNs an die Konsole und umgeht
       PowerShell-Redirection -> muss ueber 'cmd /c' gekapselt werden.
       LAEUFT ueber Invoke-SysPilotMonitoredProcess (cmd /c-Wrapper,
       Timeout + Prozessbaum-Abbruch) - vorher blockierte ein haengender
       scoop-Befehl den kompletten Update-Lauf fuer immer. #>
    param([Parameter(Mandatory)][string[]]$ScoopArgs, [int]$TimeoutSec = 300, [switch]$Quiet)
    $exe = Get-SysPilotScoopExePath
    if (-not $exe) { $exe = 'scoop' }
    $argStr = ($ScoopArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    $run = {
        param($e,$a)
        $r = Invoke-SysPilotMonitoredProcess -FilePath $e -ArgList $a -Label "scoop $($a -join ' ')" -TimeoutSec $TimeoutSec -Quiet:$Quiet.IsPresent
        return @{ Out=[string]$r.Output; Code=$r.ExitCode }
    }
    $rr = & $run $exe @($ScoopArgs)
    $out = [string]$rr.Out
    $script:ScoopLastExitCode = $rr.Code
    if ($out -match 'bucket\(s\) out of date') {
        if (Update-SysPilotScoopBuckets) {
            $rr = & $run $exe @($ScoopArgs); $out = [string]$rr.Out; $script:ScoopLastExitCode = $rr.Code
            # WARN haette an? -> Bucket-Repos reparieren + letzter Retry
            # (eigener 24h-Stempel, damit haengende Git-Repos nicht
            # bei jedem scoop-Aufruf neu repariert werden)
            if ($out -match 'bucket\(s\) out of date' -and
                (Test-SysPilotAutoFixDue -Name 'scoop-bucket-repair' -Hours 24)) {
                Save-SysPilotAutoFixStamp -Name 'scoop-bucket-repair'
                Write-SysPilotLog 'Scoop WARN nach Update weiterhin - repariere Bucket-Repos'
                Repair-SysPilotScoopBuckets
                $rr = & $run $exe @($ScoopArgs); $out = [string]$rr.Out; $script:ScoopLastExitCode = $rr.Code
            }
        }
    } elseif ($out -match 'bad object|did not send all necessary objects' -and
              (Test-SysPilotAutoFixDue -Name 'scoop-bucket-repair' -Hours 24)) {
        # Korruptes Bucket-Repo (z.B. games): WARN ist evtl. schon weg,
        # aber jeder scoop-Befehl zeigt Git-Fehler -> trotzdem reparieren
        Save-SysPilotAutoFixStamp -Name 'scoop-bucket-repair'
        Write-Host '  -> Scoop-Bucket-Repo korrupt - repariere automatisch ...' -ForegroundColor DarkGray
        Repair-SysPilotScoopBuckets
        $rr = & $run $exe @($ScoopArgs); $out = [string]$rr.Out; $script:ScoopLastExitCode = $rr.Code
    }
    return $out
}

function Get-SysPilotScoopOutdated {
    <# scoop status listet Apps mit Verfuegbarkeit-Info; die 'Info'-Spalte
       enthaelt bei Updates die verfuegbare Version. #>
    $exe = (Get-Command scoop -ErrorAction SilentlyContinue).Source
    if (-not $exe) { return @() }
    try {
        $out = Invoke-SysPilotScoopRaw -ScoopArgs @('status')
    } catch { return @() }
    $rows = @()
    foreach ($line in ($out -split "`r?`n")) {
        # Format: Name Version Source Updated Info (Info = 'Update available: x.y' o.ae.)
        if ($line -match 'WARN|bucket|scoop\.sh|^\s*$') { continue }
        $t = $line -split '\s{2,}' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        if ($t.Count -lt 4) { continue }
        $info = ($t -join ' ')
        if ($info -match '(?i)(update|upgrade|new version|verfuegbar|available)') {
            $rows += [pscustomobject]@{ Name=$t[0]; Id=$t[0]; Installed=$t[1]; Available='?'; Source='scoop'; Raw=$info }
        }
    }
    return $rows
}

function Update-SysPilotNpmSelf {
    <# npm-Selbst-Update, wenn eine neuere Version verfuegbar ist.
       Drossel: 1x pro 7 Tagen. #>
    if (-not (Test-SysPilotAutoFixDue -Name 'npm-self' -Hours 168)) { return }
    $exe = (Get-Command npm -ErrorAction SilentlyContinue).Source
    if (-not $exe) { return }
    try {
        $cur = (& npm -v 2>$null | Out-String).Trim()
        $latest = (& npm view npm version 2>$null | Out-String).Trim()
        if (-not $cur -or -not $latest) { return }
        if ([version]$latest -gt [version]$cur) {
            Save-SysPilotAutoFixStamp -Name 'npm-self'
            Write-Host "  -> npm $cur -> $latest (Selbst-Update) ..." -ForegroundColor DarkGray
            & npm install -g "npm@$latest" 2>&1 | Out-Null
            Write-SysPilotLog "npm self-update $cur -> $latest (Exit $LASTEXITCODE)"
        }
    } catch { }
}

function Get-SysPilotNpmOutdated {
    $exe = (Get-Command npm -ErrorAction SilentlyContinue).Source
    if (-not $exe) { return @() }
    Update-SysPilotNpmSelf
    try {
        $out = & npm outdated -g --json 2>$null | Out-String
        $json = $out | ConvertFrom-Json -ErrorAction Stop
    } catch { return @() }
    $rows = @()
    foreach ($p in $json.PSObject.Properties) {
        $v = $p.Value
        $rows += [pscustomobject]@{ Name=$p.Name; Id=$p.Name; Installed=[string]$v.current; Available=[string]$v.latest; Source='npm' }
    }
    return $rows
}

function Update-SysPilotPipSelf {
    <# pip-Selbst-Update, wenn PyPI eine neuere Version meldet.
       Drossel: 1x pro 7 Tagen. #>
    if (-not (Test-SysPilotAutoFixDue -Name 'pip-self' -Hours 168)) { return }
    $exe = (Get-Command pip -ErrorAction SilentlyContinue).Source
    if (-not $exe) { return }
    try {
        $cur = ((& pip --version 2>$null | Out-String) -replace '.*?(\d+\.\d+\.\d+).*','$1').Trim()
        $j = Invoke-RestMethod 'https://pypi.org/pypi/pip/json' -TimeoutSec 15 -ErrorAction Stop
        $latest = [string]$j.info.version
        if (-not $cur -or -not $latest) { return }
        if ([version]$latest -gt [version]$cur) {
            Save-SysPilotAutoFixStamp -Name 'pip-self'
            Write-Host "  -> pip $cur -> $latest (Selbst-Update) ..." -ForegroundColor DarkGray
            & pip install --upgrade "pip==$latest" 2>&1 | Out-Null
            Write-SysPilotLog "pip self-update $cur -> $latest (Exit $LASTEXITCODE)"
        }
    } catch { }
}

function Get-SysPilotPipOutdated {
    $exe = (Get-Command pip -ErrorAction SilentlyContinue).Source
    if (-not $exe) { return @() }
    Update-SysPilotPipSelf
    try {
        $out = & pip list --outdated --format=json --disable-pip-version-check 2>$null | Out-String
        $json = $out | ConvertFrom-Json -ErrorAction Stop
    } catch { return @() }
    $rows = @()
    foreach ($p in $json) {
        $rows += [pscustomobject]@{ Name=$p.name; Id=$p.name; Installed=[string]$p.version; Available=[string]$p.latest_version; Source='pip' }
    }
    return $rows
}

function Get-SysPilotDotnetTools {
    <# Globale .NET-Tools auflisten (kein out-of-date-Check: nuget.org-Suche
       pro Tool zu teuer). #>
    $exe = (Get-Command dotnet -ErrorAction SilentlyContinue).Source
    if (-not $exe) { return @() }
    try {
        $out = & dotnet tool list --global 2>$null | Out-String
    } catch { return @() }
    $rows = @()
    foreach ($line in ($out -split "`r?`n")) {
        $f = $line -split '\s+' | Where-Object { $_ -ne '' }
        if ($f.Count -ge 3 -and $f[0] -match '^[A-Za-z]' -and $f[1] -match '^\d') {
            $rows += [pscustomobject]@{ Name=$f[0]; Id=$f[0]; Installed=$f[1]; Available=''; Source='dotnet' }
        }
    }
    return $rows
}

function Get-SysPilotDotnetOutdated {
    <# Outdated-Check fuer globale .NET-Tools ueber die NuGet-Flatcontainer-
       API: EIN HTTP-Call pro Tool (index.json = alle Versionen), also
       verguenstig genug fuer den Scan. #>
    $exe = (Get-Command dotnet -ErrorAction SilentlyContinue).Source
    if (-not $exe) { return @() }
    $tools = @(Get-SysPilotDotnetTools | Select-Object -First 15)
    $rows = @()
    foreach ($t in $tools) {
        if (-not $t.Installed) { continue }
        try {
            $idx = Invoke-RestMethod -Uri "https://api.nuget.org/v3-flatcontainer/$($t.Id.ToLower())/index.json" -TimeoutSec 8 -ErrorAction Stop
            $vers = @($idx.versions)
            $latest = [string]$vers[-1]
            if ($latest -and [version]$latest -gt [version]$t.Installed) {
                $rows += [pscustomobject]@{ Name=$t.Name; Id=$t.Id; Installed=[string]$t.Installed; Available=$latest; Source='dotnet' }
            }
        } catch { }
    }
    return $rows
}

function Get-SysPilotBunOutdated {
    <# Outdated-Check fuer globale Bun-Pakete. 'bun outdated' kennt nur
       Projekt-Kontext -> globale Pakete werden via 'bun pm ls -g'
       aufgelistet und gegen die npm-Registry (latest-Tag) geprueft. #>
    $exe = (Get-Command bun -ErrorAction SilentlyContinue).Source
    if (-not $exe) { return @() }
    try { $out = (& bun pm ls -g --all 2>$null | Out-String) } catch { return @() }
    if (-not $out) { return @() }
    $rows = @()
    foreach ($line in ($out -split "`r?`n")) {
        # 'pkg@1.2.3' oder 'pkg 1.2.3' - nur Zeilen mit Version
        if ($line -match '^\s*[^\w\s]*\s*([A-Za-z0-9][A-Za-z0-9@._/-]*?)\s*[@ ]\s*(\d+\.\d+\.\d+[^\s]*)') {
            $id = $Matches[1]; $cur = $Matches[2]
            if ($id -match '^(bun|node_modules|dependencies|-+$)') { continue }
            try {
                $meta = Invoke-RestMethod -Uri "https://registry.npmjs.org/$($id -replace '/','%2f')/latest" -TimeoutSec 8 -ErrorAction Stop
                $latest = [string]$meta.version
                if ($latest -and [version]$latest -gt [version]$cur) {
                    $rows += [pscustomobject]@{ Name=$id; Id=$id; Installed=$cur; Available=$latest; Source='bun' }
                }
            } catch { }
        }
        if ($rows.Count -ge 25) { break }
    }
    return $rows
}

function Update-SysPilotNuGetProvider {
    <# Stellt sicher, dass der NuGet-PackageProvider aktuell ist
       (Find-Module/Install-Module warnen sonst). Drossel: 1x pro 30 Tagen. #>
    if (-not (Test-SysPilotAutoFixDue -Name 'nuget-provider' -Hours 720)) { return }
    try {
        $prov = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
        $min = [version]'2.8.5.208'
        if (-not $prov -or [version]$prov.Version -lt $min) {
            Save-SysPilotAutoFixStamp -Name 'nuget-provider'
            Write-Host "  -> NuGet-Provider aktualisieren ..." -ForegroundColor DarkGray
            Install-PackageProvider -Name NuGet -MinimumVersion $min -Force -Scope CurrentUser -ErrorAction Stop | Out-Null
            Write-SysPilotLog "NuGet-Provider aktualisiert ($($prov.Version) -> $min+)"
        }
    } catch { }
}

function Get-SysPilotPsGalleryOutdated {
    <# Installierte PSGallery-Module vs. Katalog (nur User-Scope, max 25). #>
    Update-SysPilotNuGetProvider
    $modsPath = Join-Path $env:USERPROFILE 'Documents\PowerShell\Modules'
    if (-not (Test-Path $modsPath)) { return @() }
    $rows = @()
    $installed = Get-ChildItem $modsPath -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName ($_.Name + '.psd1')) } |
        Select-Object -First 25
    foreach ($m in $installed) {
        try {
            $latest = Find-Module -Name $m.Name -Repository PSGallery -ErrorAction Stop |
                      Sort-Object Version -Descending | Select-Object -First 1
            $cur = (Get-Module -ListAvailable -Name $m.Name -ErrorAction SilentlyContinue |
                    Sort-Object Version -Descending | Select-Object -First 1).Version
            if ($latest -and $cur -and ([version]$latest.Version -gt [version]$cur)) {
                $rows += [pscustomobject]@{ Name=$m.Name; Id=$m.Name; Installed=[string]$cur; Available=[string]$latest.Version; Source='psgallery' }
            }
        } catch { }
    }
    return $rows
}

function Get-SysPilotPmOutdated {
    <# Alle Outdated-Zeilen aus allen verfuegbaren nativen Managern.
       Gibt Zeilen im Update-Center-Format zurueck (Source='pm:<id>'). #>
    $rows = @()
    $status = @{}
    foreach ($m in (Get-SysPilotPackageManagers)) { $status[$m.Id] = $m }

    if ($status['scoop'].Status -eq 'installed')   { $rows += Get-SysPilotScoopOutdated }
    if ($status['npm'].Status -eq 'installed')     { $rows += Get-SysPilotNpmOutdated }
    if ($status['pip'].Status -eq 'installed')     { $rows += Get-SysPilotPipOutdated }
    if ($status['bun'].Status -eq 'installed')     { $rows += Get-SysPilotBunOutdated }
    if ($status['dotnet'].Status -eq 'installed')  { $rows += Get-SysPilotDotnetOutdated }
    if ($status['psgallery'].Status -eq 'installed') { $rows += Get-SysPilotPsGalleryOutdated }
    # WSL-PM (apt/dnf/pacman/flatpak/snap) und brew: Updates laufen bewusst
    # NICHT automatisch - distro-uebergreifende Upgrades sind zu invasiv
    # fuer einen stillen Hintergrund-Scan. Sie bleiben suchbar/installierbar.

    # Quelle umbenennen fuer Update-Center-Dispatch
    foreach ($r in $rows) { $r.Source = "pm:$($r.Source)" }

    # Abdeckungs-Info fuer die Anzeige: welche Manager wurden tatsaechlich
    # abgefragt, welche sind installsiert aber bewusst ausgenommen
    # (brew/WSL - zu invasiv fuer stillen Scan), welche fehlen komplett.
    $autoIds = @('scoop','npm','pip','bun','dotnet','psgallery')
    $q = @(); $skipInst = @(); $notInst = @()
    foreach ($m in (Get-SysPilotPackageManagers)) {
        if ($m.Id -in @('winget','chocolatey')) { continue }  # eigener Scan
        if ($m.Status -ne 'installed') { $notInst += $m.Name; continue }
        if ($autoIds -contains $m.Id) { $q += $m.Name } else { $skipInst += $m.Name }
    }
    $cov = "Abgefragt: " + $(if ($q.Count) { $q -join ', ' } else { 'keiner' })
    if ($skipInst.Count) { $cov += " | Installiert, nicht auto: $($skipInst -join ', ')" }
    if ($notInst.Count) { $cov += " | Nicht installiert: $($notInst -join ', ')" }
    $script:SysPilotPmCoverage = $cov
    return $rows
}

function Get-SysPilotPmCoverage {
    <# Letzte Abdeckungs-Zusammenfassung aus Get-SysPilotPmOutdated
       (welche PMs wurden abgefragt bzw. bewusst uebersprungen). #>
    if (-not $script:SysPilotPmCoverage) { return 'Pm-Scan noch nicht gelaufen.' }
    return $script:SysPilotPmCoverage
}

# =====================================================================
# UPGRADE pro Manager
# =====================================================================

function Get-SysPilotPythonExeForPip {
    <# Findet python.exe fuer 'python -m pip': bevorzugt das Geschwister-
       python.exe neben Scripts\pip.exe, sonst python aus dem PATH. #>
    $pipExe = Get-Command pip.exe -ErrorAction SilentlyContinue
    if ($pipExe -and $pipExe.Source -match '\\Scripts\\pip\.exe$') {
        $cand = Join-Path (Split-Path (Split-Path $pipExe.Source -Parent) -Parent) 'python.exe'
        if (Test-Path $cand) { return $cand }
    }
    $py = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($py) { return $py.Source }
    return $null
}

function Invoke-SysPilotPmUpgrade {
    <# Upgrade eines Packages ueber seinen Manager.
       $Row braucht: Id, Source ('pm:<mgr>'), Name.
       Gibt @{Ok;Error} zurueck. #>
    param([Parameter(Mandatory)]$Row, [switch]$Silent)
    $mgr = ([string]$Row.Source) -replace '^pm:', ''
    $id  = [string]$Row.Id
    $sw  = [Diagnostics.Stopwatch]::StartNew()

    # Alle externen Aufrufe laufen ueber Invoke-SysPilotMonitoredProcess:
    # echter Timeout + taskkill /T (Prozessbaum) bei Haengern. Vorher
    # blockierten npm/pip/dotnet/brew/scoop OHNE Timeout den kompletten
    # Update-Lauf ("Auto-Lauf" schien zu haengen).
    $run = {
        param($exe, $argv, $lbl)
        $r = Invoke-SysPilotMonitoredProcess -FilePath $exe -ArgList $argv -Label $lbl -TimeoutSec 300 -Quiet
        return @{ Out=[string]$r.Output; Code=$r.ExitCode; Timeout=[bool]$r.Timeout }
    }
    switch ($mgr) {
        'scoop' {
            $out = Invoke-SysPilotScoopRaw -ScoopArgs @('update', $id) -TimeoutSec 600 -Quiet
            $ok = ($script:ScoopLastExitCode -eq 0)
            $err = $(if($ok){''}else{$out.Substring([Math]::Max(0,$out.Length-300))})
            return @{ Ok=$ok; Error=$err; Ms=$sw.ElapsedMilliseconds }
        }
        'npm' {
            $r = & $run 'npm' @('install','-g',"$id@latest") 'npm install'
            $ok = ($r.Code -eq 0 -and -not $r.Timeout)
            $err = $(if($r.Timeout){'npm: Timeout nach 300s'}elseif(-not $ok){$r.Out.Substring([Math]::Max(0,$r.Out.Length-300))}else{''})
            return @{ Ok=$ok; Error=$err; Ms=$sw.ElapsedMilliseconds }
        }
        'pip' {
            # pip.exe kann sich nicht selbst updaten ("To modify pip, please
            # run: python -m pip ...") -> bevorzugt python -m pip nutzen.
            $py = Get-SysPilotPythonExeForPip
            if ($py) { $r = & $run $py @('-m','pip','install','--upgrade',$id) 'pip upgrade' }
            else     { $r = & $run 'pip' @('install','--upgrade',$id) 'pip upgrade' }
            $ok = ($r.Code -eq 0 -and -not $r.Timeout)
            # Fallback: python -m pip scheiterte -> classic pip nochmal
            if (-not $ok -and -not $r.Timeout -and $py) { $r = & $run 'pip' @('install','--upgrade',$id) 'pip upgrade'; $ok = ($r.Code -eq 0 -and -not $r.Timeout) }
            $err = $(if($r.Timeout){'pip: Timeout nach 300s'}elseif(-not $ok){$r.Out.Substring([Math]::Max(0,$r.Out.Length-300))}else{''})
            return @{ Ok=$ok; Error=$err; Ms=$sw.ElapsedMilliseconds }
        }
        'bun' {
            $r = & $run 'bun' @('install','-g',"$id@latest") 'bun install'
            $ok = ($r.Code -eq 0 -and -not $r.Timeout)
            $err = $(if($r.Timeout){'bun: Timeout nach 300s'}elseif(-not $ok){$r.Out.Substring([Math]::Max(0,$r.Out.Length-300))}else{''})
            return @{ Ok=$ok; Error=$err; Ms=$sw.ElapsedMilliseconds }
        }
        'dotnet' {
            $r = & $run 'dotnet' @('tool','update','--global',$id) 'dotnet tool update'
            $ok = ($r.Code -eq 0 -and -not $r.Timeout)
            $err = $(if($r.Timeout){'dotnet: Timeout nach 300s'}elseif(-not $ok){$r.Out.Substring([Math]::Max(0,$r.Out.Length-300))}else{''})
            return @{ Ok=$ok; Error=$err; Ms=$sw.ElapsedMilliseconds }
        }
        'psgallery' {
            try { Update-Module -Name $id -Force -Confirm:$false -ErrorAction Stop; return @{ Ok=$true; Error=''; Ms=$sw.ElapsedMilliseconds } }
            catch { return @{ Ok=$false; Error=$_.Exception.Message; Ms=$sw.ElapsedMilliseconds } }
        }
        'brew' {
            $r = & $run 'brew' @('upgrade',$id) 'brew upgrade'
            $ok = ($r.Code -eq 0 -and -not $r.Timeout)
            $err = $(if($r.Timeout){'brew: Timeout nach 300s'}elseif(-not $ok){$r.Out.Substring([Math]::Max(0,$r.Out.Length-300))}else{''})
            return @{ Ok=$ok; Error=$err; Ms=$sw.ElapsedMilliseconds }
        }
        default {
            return @{ Ok=$false; Error="Manager '$mgr' hat keinen Upgrade-Pfad"; Ms=$sw.ElapsedMilliseconds }
        }
    }
}

function Install-SysPilotPmPackage {
    <# Installiert ein Paket ueber den angegebenen Manager.
       param: Manager ('winget','chocolatey','scoop','npm','pip','dotnet','psgallery'), Id.
       Gibt @{Ok;Error} zurueck. #>
    param([Parameter(Mandatory)][string]$Manager, [Parameter(Mandatory)][string]$Id)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $mgr = $Manager.ToLower()
    if ($mgr -eq 'winget') {
        $w = Get-SysPilotWingetExe
        if (-not $w) { return @{ Ok=$false; Error='winget nicht gefunden' } }
        $r = Invoke-SysPilotWingetRaw -ArgList @('install','--id',$Id,'--exact','--accept-package-agreements','--accept-source-agreements','--disable-interactivity') -TimeoutSec 900
        return @{ Ok=[bool]$r.Ok; Error=[string]$r.Error }
    }
    if ($mgr -eq 'chocolatey') {
        $c = Find-SysPilotChocoExeLocal
        if (-not $c) { return @{ Ok=$false; Error='choco nicht gefunden' } }
        if (Test-SysPilotAdmin) {
            $r = Invoke-SysPilotMonitoredProcess -FilePath $c -ArgList @('install',$Id,'-y','--no-progress','--limit-output') -Label "choco install $Id" -TimeoutSec 600
            $out=[string]$r.Output; $code=$r.ExitCode
        } else {
            $p = Start-Process $c -ArgumentList @('install',$Id,'-y','--no-progress','--limit-output') -Verb RunAs -PassThru
            $p.WaitForExit(900000) | Out-Null; $code=$p.ExitCode; $out=''
        }
        $low = "$out".ToLower()
        $ok = ($code -eq 0 -and $low -notmatch 'was not found|could not find|0/\d+ packages')
        return @{ Ok=$ok; Error=$(if($ok){''}else{"choco exit $code"}) }
    }
    if ($mgr -eq 'scoop') {
        $out = Invoke-SysPilotScoopRaw -ScoopArgs @('install', $Id)
        return @{ Ok=($LASTEXITCODE -eq 0); Error=$(if($LASTEXITCODE -eq 0){''}else{$out.Substring([Math]::Max(0,$out.Length-300))}) }
    }
    if ($mgr -eq 'npm') {
        $out = & npm install -g "$Id" 2>&1 | Out-String
        return @{ Ok=($LASTEXITCODE -eq 0); Error=$(if($LASTEXITCODE -eq 0){''}else{$out.Substring([Math]::Max(0,$out.Length-300))}) }
    }
    if ($mgr -eq 'pip') {
        $py = Get-SysPilotPythonExeForPip
        if ($py) { $out = & $py -m pip install $Id 2>&1 | Out-String }
        else     { $out = & pip install $Id 2>&1 | Out-String }
        $ok = ($LASTEXITCODE -eq 0)
        if (-not $ok -and $py) { $out = & pip install $Id 2>&1 | Out-String; $ok = ($LASTEXITCODE -eq 0) }
        return @{ Ok=$ok; Error=$(if($ok){''}else{$out.Substring([Math]::Max(0,$out.Length-300))}) }
    }
    if ($mgr -eq 'dotnet') {
        $out = & dotnet tool install --global $Id 2>&1 | Out-String
        return @{ Ok=($LASTEXITCODE -eq 0); Error=$(if($LASTEXITCODE -eq 0){''}else{$out.Substring([Math]::Max(0,$out.Length-300))}) }
    }
    if ($mgr -eq 'psgallery') {
        try { Install-Module -Name $Id -Force -Scope CurrentUser -AllowClobber -ErrorAction Stop; return @{ Ok=$true; Error='' } }
        catch { return @{ Ok=$false; Error=$_.Exception.Message } }
    }
    return @{ Ok=$false; Error="Manager '$Manager' wird nicht unterstuetzt" }
}

# =====================================================================
# SEARCH ueber alle Manager
# =====================================================================

function Get-SysPilotPmSearchResults {
    <# Sucht in allen installierten Managern. Gibt gruppierte Ergebnisse:
       @{Manager;Id;Name;Detail}
       Optional: -OnProgress Scriptblock fuer Statuszeilen. #>
    param([Parameter(Mandatory)][string]$Query, [scriptblock]$OnProgress = $null)
    $say = { param($m) if ($OnProgress) { $null = & $OnProgress ([string]$m) } }
    $results = @()
    $status = @{}
    foreach ($m in (Get-SysPilotPackageManagers)) { $status[$m.Id] = $m }

    if ($status['winget'].Status -eq 'installed') {
        & $say 'PM-Suche: winget search ...'
        $w = $null
        if (Get-Command Get-SysPilotWingetExe -ErrorAction SilentlyContinue) { $w = Get-SysPilotWingetExe }
        if (-not $w) { $wg = Get-Command winget.exe -ErrorAction SilentlyContinue; if ($wg) { $w = $wg.Source } }
        if ($w) {
            $out = & $w search $Query --accept-source-agreements 2>$null | Out-String
            foreach ($line in ($out -split "`r?`n")) {
                $t = $line -split '\s{2,}' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
                if ($t.Count -ge 3 -and $t[0] -match '^[A-Za-z]') {
                    $results += [pscustomobject]@{ Manager='winget'; Id=($t | Where-Object { $_ -match '\.' } | Select-Object -First 1); Name=($t -join ' | '); Detail=$t[0] }
                }
            }
        }
    }
    if ($status['chocolatey'].Status -eq 'installed') {
        & $say 'PM-Suche: choco search ...'
        $c = Find-SysPilotChocoExeLocal
        if ($c) {
            $out = & $c search $Query --limit-output 2>$null | Out-String
            foreach ($line in ($out -split "`r?`n")) {
                $f = $line -split '\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
                if ($f.Count -ge 2 -and $f[0] -match '^[a-z]') {
                    $results += [pscustomobject]@{ Manager='chocolatey'; Id=$f[0]; Name=$f[0]; Detail=($f -join ' ') }
                }
            }
        }
    }
    if ($status['scoop'].Status -eq 'installed') {
        & $say 'PM-Suche: scoop search ...'
        $out = Invoke-SysPilotScoopRaw -ScoopArgs @('search', $Query)
        foreach ($line in ($out -split "`r?`n")) {
            $t = $line -split '\s+' | Where-Object { $_ -ne '' }
            if ($t.Count -ge 1 -and $t[0] -match '^[a-z0-9]') {
                $results += [pscustomobject]@{ Manager='scoop'; Id=$t[0]; Name=($t -join ' '); Detail='' }
            }
        }
    }
    if ($status['npm'].Status -eq 'installed') {
        & $say 'PM-Suche: npm search ...'
        $out = & npm search $Query --json 2>$null | Out-String
        try {
            $json = $out | ConvertFrom-Json -ErrorAction Stop
            foreach ($p in ($json | Select-Object -First 10)) {
                $results += [pscustomobject]@{ Manager='npm'; Id=$p.name; Name="$($p.name) $($p.version)"; Detail=$p.description }
            }
        } catch { }
    }
    if ($status['pip'].Status -eq 'installed') {
        & $say 'PM-Suche: pip (kein echtes Search - Installations-Hinweis) ...'
        # pip hat keine echte Such-API mehr (pip search entfernt).
        # pip index versions geht nur exakt -> auf PyPI-Projektnamen raten.
        # Wir bieten stattdessen pip direkt als Installer an.
        $results += [pscustomobject]@{ Manager='pip'; Id="pip install $Query"; Name="pip: '$Query' installieren"; Detail='pip install' }
    }
    if ($status['dotnet'].Status -eq 'installed') {
        & $say 'PM-Suche: dotnet tool search ...'
        $out = & dotnet tool search $Query 2>$null | Out-String
        foreach ($line in ($out -split "`r?`n")) {
            $t = $line -split '\s+' | Where-Object { $_ -ne '' }
            if ($t.Count -ge 2 -and $t[0] -match '^[A-Za-z]') {
                $results += [pscustomobject]@{ Manager='dotnet'; Id=$t[0]; Name=($t -join ' '); Detail='' }
            }
        }
    }
    if ($status['psgallery'].Status -eq 'installed') {
        & $say 'PM-Suche: PSGallery Find-Module ...'
        $mods = Find-Module -Name "*$Query*" -Repository PSGallery -ErrorAction SilentlyContinue |
                Select-Object -First 10 Name, Version
        foreach ($m in $mods) {
            $results += [pscustomobject]@{ Manager='psgallery'; Id=$m.Name; Name="$($m.Name) $($m.Version)"; Detail='PSGallery' }
        }
    }
    return $results
}

# =====================================================================
# AUTO-INSTALL fehlender Manager
# =====================================================================

function Install-SysPilotPackageManager {
    <# Installiert einen fehlenden Paketmanager automatisch:
       offizielles Skript oder winget, PATH wird geprueft/ergaenzt. #>
    param([Parameter(Mandatory)][string]$Id)
    $defs = @{}
    foreach ($d in (Get-SysPilotPackageManagerDefs)) { $defs[$d.Id] = $d }
    $def = $defs[$Id]
    if (-not $def) { Write-Host "  Unbekannter Manager: $Id" -ForegroundColor Red; return $false }

    Write-Host "  Installiere $($def.Name) ..." -ForegroundColor Cyan
    Write-Host "  (Download + Installation - bitte warten, Fortschritt folgt)" -ForegroundColor DarkGray

    switch ($Id) {
        'scoop' {
            # Offizielles Installationsskript (User-Scope, kein Admin noetig)
            # Output LIVE anzeigen (kein Capture) damit der User den Fortschritt sieht
            & powershell -NoProfile -Command "irm get.scoop.sh | iex"
            Start-Sleep -Seconds 2
            $scoopExe = "$env:USERPROFILE\scoop\shims\scoop.cmd"
            if ((Get-Command scoop -ErrorAction SilentlyContinue) -or (Test-Path $scoopExe)) {
                # PATH im Current-Scope ergaenzen falls noetig
                $userPath = [Environment]::GetEnvironmentVariable('Path','User')
                if ($userPath -notlike "*$env:USERPROFILE\scoop\shims*") {
                    [Environment]::SetEnvironmentVariable('Path', "$userPath;$env:USERPROFILE\scoop\shims", 'User')
                }
                $env:Path += ";$env:USERPROFILE\scoop\shims"
                Write-Host "  [OK] Scoop installiert." -ForegroundColor Green
                return $true
            }
            Write-Host "  [!] Scoop-Installation fehlgeschlagen." -ForegroundColor Red
            return $false
        }
        'bun' {
            # Offizielles Skript: installiert nach ~/.bun, PATH automatisch
            Write-Host "  -> Lade bun.sh/install.ps1 herunter ..." -ForegroundColor DarkGray
            & powershell -NoProfile -Command "irm bun.sh/install.ps1 | iex"
            $bunDir = "$env:USERPROFILE\.bun\bin"
            if (Test-Path "$bunDir\bun.exe") {
                # PATH pruefen und ergaenzen
                $userPath = [Environment]::GetEnvironmentVariable('Path','User')
                if ($userPath -notlike "*$bunDir*") {
                    [Environment]::SetEnvironmentVariable('Path', "$userPath;$bunDir", 'User')
                    $env:Path += ";$bunDir"
                    Write-Host "  -> PATH ergaenzt ($bunDir)" -ForegroundColor DarkGray
                }
                Write-Host "  [OK] Bun installiert + PATH gesetzt." -ForegroundColor Green
                return $true
            }
            Write-Host "  [!] Bun-Installation fehlgeschlagen." -ForegroundColor Red
            return $false
        }
        'chocolatey' {
            if (-not (Test-SysPilotAdmin)) {
                Write-Host "  [!] Chocolatey braucht Admin-Rechte." -ForegroundColor Yellow
                return $false
            }
            $out = & powershell -NoProfile -Command "irm https://community.chocolatey.org/install.ps1 | iex" 2>&1 | Out-String
            if (Get-Command choco -ErrorAction SilentlyContinue) { Write-Host "  [OK] Chocolatey installiert." -ForegroundColor Green; return $true }
            Write-Host "  [!] Chocolatey-Installation fehlgeschlagen." -ForegroundColor Red
            return $false
        }
        'npm' {
            # Node.js via winget (enthaelt npm)
            $w = Get-SysPilotWingetExe
            if ($w) {
                Write-Host "  -> winget install OpenJS.NodeJS.LTS (Download ~30MB) ..." -ForegroundColor DarkGray
                & $w install OpenJS.NodeJS.LTS --accept-package-agreements --accept-source-agreements --silent
                if (Get-Command npm -ErrorAction SilentlyContinue) { Write-Host "  [OK] Node.js/npm installiert." -ForegroundColor Green; return $true }
            }
            Write-Host "  [!] Node.js-Installation fehlgeschlagen." -ForegroundColor Red
            return $false
        }
        'pip' {
            # Python via winget (enthaelt pip)
            $w = Get-SysPilotWingetExe
            if ($w) {
                Write-Host "  -> winget install Python.Python.3.13 (Download ~25MB) ..." -ForegroundColor DarkGray
                & $w install Python.Python.3.13 --accept-package-agreements --accept-source-agreements --silent
                if (Get-Command pip -ErrorAction SilentlyContinue) { Write-Host "  [OK] Python/pip installiert." -ForegroundColor Green; return $true }
            }
            Write-Host "  [!] Python-Installation fehlgeschlagen." -ForegroundColor Red
            return $false
        }
        'dotnet' {
            $w = Get-SysPilotWingetExe
            if ($w) {
                Write-Host "  -> winget install Microsoft.DotNet.SDK.9 (Download ~200MB) ..." -ForegroundColor DarkGray
                & $w install Microsoft.DotNet.SDK.9 --accept-package-agreements --accept-source-agreements --silent
                if (Get-Command dotnet -ErrorAction SilentlyContinue) { Write-Host "  [OK] .NET SDK installiert." -ForegroundColor Green; return $true }
            }
            Write-Host "  [!] .NET SDK-Installation fehlgeschlagen." -ForegroundColor Red
            return $false
        }
        'apt'     { return Install-SysPilotWslDistro -Distro 'Ubuntu'        -Pm 'apt' }
        'dnf'     { return Install-SysPilotWslDistro -Distro 'FedoraLinux_42' -Pm 'dnf' }
        'pacman'  { return Install-SysPilotWslDistro -Distro 'archlinux'      -Pm 'pacman' }
        'flatpak' { return Install-SysPilotWslDistro -Distro 'Ubuntu'        -Pm 'flatpak' }
        'snap'    { return Install-SysPilotWslDistro -Distro 'Ubuntu'        -Pm 'snap' }
        'brew' {
            Write-Host "  [!] Homebrew ist auf Windows nur ueber WSL/Linuxbrew moeglich." -ForegroundColor Yellow
            Write-Host "      Empfehlung: WSL Ubuntu installieren, dann: /bin/bash -c ""$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""" -ForegroundColor DarkGray
            return $false
        }
        default {
            Write-Host "  [!] Auto-Install fuer $Id nicht implementiert." -ForegroundColor Yellow
            return $false
        }
    }
}

function Install-SysPilotWslDistro {
    <# Installiert eine WSL-Distribution UND richtet den gewuenschten
       Paketmanager darin ein (inkl. Abhaengigkeiten). #>
    param([Parameter(Mandatory)][string]$Distro, [Parameter(Mandatory)][string]$Pm)
    if (-not (Test-SysPilotAdmin)) {
        Write-Host "  [!] WSL-Installation braucht Admin-Rechte." -ForegroundColor Yellow
        return $false
    }

    # 1) Distro vorhanden?
    $have = (Get-SysPilotWslDistros) -contains $Distro
    if (-not $have) {
        Write-Host "  -> Installiere WSL-Distribution '$Distro' ..." -ForegroundColor Cyan
        Write-Host "     (kann laenger dauern + ggf. Neustart noetig)" -ForegroundColor DarkGray
        & wsl.exe --install -d $Distro --no-launch
        $code = $LASTEXITCODE
        Start-Sleep -Seconds 3
        $have = (Get-SysPilotWslDistros) -contains $Distro
        if (-not $have) {
            Write-Host "  [!] WSL-Installation unvollstaendig (Exit $code)." -ForegroundColor Red
            Write-Host "      Meist ist ein Neustart noetig - danach erneut versuchen." -ForegroundColor Yellow
            return $false
        }
    } else {
        Write-Host "  -> WSL-Distribution '$Distro' ist bereits vorhanden." -ForegroundColor DarkGray
    }

    # 2) Ersteinrichtung: default user anlegen (Ubuntu fragt interaktiv - wir nutzen root fuer Setup)
    Write-Host "  -> Richte '$Pm' in '$Distro' ein ..." -ForegroundColor Cyan
    $pkgMap = @{
        'apt'     = @{ Debian='apt';        Ubuntu='apt' }
        'dnf'     = @{ Fedora='dnf' }
        'pacman'  = @{ Arch='pacman' }
        'flatpak' = @{ Ubuntu='flatpak'; Debian='flatpak' }
        'snap'    = @{ Ubuntu='snapd';  Debian='snapd' }
    }
    $pmExe = switch ($Pm) {
        'apt'     { 'apt-get' }
        'dnf'     { 'dnf' }
        'pacman'  { 'pacman' }
        'flatpak' { 'flatpak' }
        'snap'    { 'snap' }
        default   { $Pm }
    }
    # Pruefe ob PM in der Distro existiert
    $chk = (& wsl.exe -d $Distro -u root -- sh -c "command -v $pmExe" 2>$null)
    if ($chk) {
        Write-Host "  [OK] $Pm ist in '$Distro' bereits vorhanden." -ForegroundColor Green
        return $true
    }

    # 3) PM installieren (Debian/Ubuntu: apt; Fedora: dnf; Arch: pacman)
    Write-Host "  -> Installiere $Pm in '$Distro' (apt/dnf laeuft) ..." -ForegroundColor DarkGray
    switch ($Pm) {
        'flatpak' {
            & wsl.exe -d $Distro -u root -- bash -c "apt-get update -qq && apt-get install -y flatpak"
        }
        'snap' {
            & wsl.exe -d $Distro -u root -- bash -c "apt-get update -qq && apt-get install -y snapd"
        }
        'apt' {
            # apt ist bei Debian/Ubuntu Standard - nur sicherheitshalber
            & wsl.exe -d $Distro -u root -- bash -c "apt-get update -qq && apt-get install -y apt"
        }
        default {
            # dnf/pacman sind Basisbestandteil der Distro
            Write-Host "  [OK] $Pm ist Basisbestandteil von '$Distro'." -ForegroundColor Green
            return $true
        }
    }
    Start-Sleep -Seconds 2
    $chk2 = (& wsl.exe -d $Distro -u root -- sh -c "command -v $pmExe" 2>$null)
    if ($chk2) {
        Write-Host "  [OK] $Pm in '$Distro' installiert." -ForegroundColor Green
        return $true
    }
    Write-Host "  [!] $Pm-Installation in '$Distro' unvollstaendig." -ForegroundColor Yellow
    Write-Host "      In WSL pruefen: wsl -d $Distro" -ForegroundColor DarkGray
    return $false
}

# =====================================================================
# WSL-MANAGEMENT (Distro-Verwaltung + WSLg/GUI-Apps)
# =====================================================================

function Get-SysPilotWslStatus {
    <# WSL-Status: Version, Kernel, WSLg, Distros. #>
    $status = [ordered]@{ WslVersion=''; Kernel=''; Wslg=''; DefaultDistro=''; Distros=@() }
    try {
        $ver = ((& wsl.exe --version 2>$null) -join "`n") -replace "`0", ''
        if ($ver -match 'WSL\D*Version:\s*([\d.]+)')       { $status.WslVersion = $Matches[1] }
        if ($ver -match 'Kernelversion:\s*([\d.\-a-zA-Z]+)') { $status.Kernel = $Matches[1] }
        if ($ver -match 'WSLg\D*Version:\s*([\d.]+)')      { $status.Wslg = $Matches[1] }
    } catch { }
    try {
        $st = ((& wsl.exe --status 2>$null) -join "`n") -replace "`0", ''
        if ($st -match 'Standarddistribution:\s*(\S+)')   { $status.DefaultDistro = $Matches[1] }
        if ($st -match 'Standardversion:\s*(\d)')          { $status.WslVersion2 = $Matches[1] }
    } catch { }
    $status.Distros = @(Get-SysPilotWslDistros)
    return [pscustomobject]$status
}

function Install-SysPilotWslManager {
    <# Installiert WSL Manager (Bostrot.WSLManager) via winget -
       der beste GUI-Manager: Distro-Install/-Kopie/-Backup/-Loeschen,
       .wslconfig-Editor, Disk-Mount, Remote-WSL, MCP-Server. #>
    $w = Get-SysPilotWingetExe
    if (-not $w) { Write-Host "  [!] winget fehlt." -ForegroundColor Red; return $false }
    Write-Host "  -> winget install Bostrot.WSLManager ..." -ForegroundColor DarkGray
    & $w install Bostrot.WSLManager --accept-package-agreements --accept-source-agreements --silent
    $exe = "$env:LOCALAPPDATA\Programs\WSL Manager\WSLManager.exe"
    if ((Get-Command WSLManager -ErrorAction SilentlyContinue) -or (Test-Path $exe) -or
        (Get-ChildItem "$env:LOCALAPPDATA\Programs" -Recurse -Filter 'WSLManager.exe' -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        Write-Host "  [OK] WSL Manager installiert." -ForegroundColor Green
        return $true
    }
    Write-Host "  [!] WSL Manager-Installation evtl. unvollstaendig - pruefen." -ForegroundColor Yellow
    return $false
}

function Set-SysPilotWslGuiConfig {
    <# Stellt .wslconfig fuer WSLg (GUI-Apps) + sinnvolle Defaults sicher.
       Ueberschreibt Nichts - nur fehlende Keys werden ergaenzt. #>
    $cfg = Join-Path $env:USERPROFILE '.wslconfig'
    $exists = Test-Path $cfg
    $content = if ($exists) { Get-Content $cfg -Raw -ErrorAction SilentlyContinue } else { '' }
    $changed = $false
    $sb = New-Object System.Text.StringBuilder
    if ($content) { [void]$sb.Append($content.TrimEnd()) }

    # [wsl2]-Sektion mit GUI-Apps + localhost forwarding sicherstellen
    $wsl2Block = @'
[wsl2]
guiApplications=true
localhostForwarding=true
'@
    if ($content -notmatch '(?m)^\[wsl2\]') {
        if ($sb.Length -gt 0) { [void]$sb.Append("`r`n") }
        [void]$sb.Append($wsl2Block)
        $changed = $true
    } elseif ($content -notmatch '(?m)^guiApplications\s*=') {
        # guiApplications in bestehender [wsl2]-Sektion einfuegen
        $new = [regex]::Replace($content, '(?m)(^\[wsl2\]\s*$)', "`$1`r`nguiApplications=true", 1)
        if ($new -ne $content) { Set-Content $cfg $new -Encoding UTF8; $changed = $true }
    }
    # Memory-Limit nur setzen wenn gar nichts konfiguriert ist
    if (-not $exists) {
        [void]$sb.Append("`r`n# SysPilot: WSLg GUI-Apps + localhost forwarding`r`n")
        Set-Content $cfg $sb.ToString() -Encoding UTF8
        $changed = $true
    } elseif ($changed) {
        Set-Content $cfg $sb.ToString() -Encoding UTF8
    }
    if ($changed) {
        Write-Host "  [OK] .wslconfig konfiguriert (guiApplications + localhostForwarding)." -ForegroundColor Green
        Write-Host "      GUI-Apps in WSL funktionieren nach 'wsl --shutdown' neu." -ForegroundColor DarkGray
    } else {
        Write-Host "  [OK] .wslconfig bereits korrekt konfiguriert." -ForegroundColor DarkGray
    }
    return $changed
}

function Get-SysPilotWslOnlineDistros {
    <# Live-Liste installierbarer WSL-Distributionen (wsl --list --online).
       Gibt @{Name;Friendly} zurueck. #>
    try {
        $raw = ((& wsl.exe --list --online 2>$null) -join "`n") -replace "`0", ''
    } catch { return @() }
    $out = @()
    $lines = $raw -split "`r?`n"
    # Spalten NAME / FRIENDLY NAME - Datenzeilen haben 2+ Spalten-Trennung
    foreach ($line in $lines) {
        if ($line -match '^\s*(NAME|---|Im Folgenden|Mit )' -or $line.Trim() -eq '') { continue }
        $t = $line -split '\s{2,}' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        if ($t.Count -ge 2 -and $t[0] -match '^[a-zA-Z0-9][a-zA-Z0-9._-]*$') {
            $out += [pscustomobject]@{ Name=$t[0]; Friendly=($t[1..($t.Count-1)] -join ' ') }
        }
    }
    return $out
}

function Install-SysPilotWslDistroByName {
    <# Installiert eine WSL-Distro per Name (z.B. 'Ubuntu-24.04').
       Fortschritt live, dann Verify + optionaler Start (OOBE). #>
    param([Parameter(Mandatory)][string]$Name, [switch]$NoLaunch)
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        Write-Host "  [!] WSL nicht installiert." -ForegroundColor Red; return $false
    }
    $have = (Get-SysPilotWslDistros) -contains $Name
    if ($have) { Write-Host "  '$Name' ist bereits installiert." -ForegroundColor DarkGray; return $true }

    Write-Host "  -> Installiere WSL-Distro '$Name' ..." -ForegroundColor Cyan
    Write-Host "     (Download ~100-600MB - bitte warten, kein Fensterwechsel noetig)" -ForegroundColor DarkGray
    # WSL 3.x: 'wsl --install <Distro>'; aeltere: 'wsl --install -d <Distro>'
    & wsl.exe --install $Name --no-launch 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  -> Retry mit altem Syntax ..." -ForegroundColor DarkGray
        & wsl.exe --install -d $Name --no-launch 2>&1 | Out-Host
    }
    Start-Sleep -Seconds 3
    $have = (Get-SysPilotWslDistros) -contains $Name
    if (-not $have) {
        Write-Host "  [!] '$Name' konnte nicht installiert werden." -ForegroundColor Red
        Write-Host "      Haeufig: Neustart noetig - danach erneut versuchen." -ForegroundColor Yellow
        return $false
    }
    Write-Host "  [OK] '$Name' installiert." -ForegroundColor Green

    # PM in der Distro einrichten falls angefordert
    $pmMap = @{ 'Ubuntu'='apt'; 'Ubuntu-24.04'='apt'; 'Ubuntu-22.04'='apt'; 'Debian'='apt';
                'FedoraLinux-45'='dnf'; 'FedoraLinux-44'='dnf';
                'archlinux'='pacman'; 'kali-linux'='apt'; 'openSUSE-Tumbleweed'='zypper' }
    if ($pmMap.ContainsKey($Name)) {
        Write-Host "  -> Richte Paketmanager in '$Name' ein ..." -ForegroundColor DarkGray
        $pm = $pmMap[$Name]
        if ($pm -eq 'apt') {
            & wsl.exe -d $Name -u root -- bash -c "apt-get update -qq" 2>&1 | Out-Null
        } elseif ($pm -eq 'dnf') {
            & wsl.exe -d $Name -u root -- dnf makecache -q 2>&1 | Out-Null
        }
        Write-Host "  [OK] $pm in '$Name' bereit." -ForegroundColor DarkGray
    }

    if (-not $NoLaunch) {
        if (Confirm-SysPilot "'$Name' jetzt starten? (Terminal fuer Ersteinrichtung)" ) {
            $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
            if ($wt) { Start-Process wt.exe -ArgumentList "wsl","-d",$Name }
            else     { Start-Process wsl.exe -ArgumentList "-d",$Name }
        }
    }
    return $true
}

function Show-SysPilotWslDistroPicker {
    <# Distro-Auswahl: Top-Empfehlungen + komplette Online-Liste. #>
    $online = @(Get-SysPilotWslOnlineDistros)
    if ($online.Count -eq 0) {
        Write-Host "  [!] Keine WSL-Distros online verfuegbar (Netz?)." -ForegroundColor Yellow
        Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
        return
    }
    $installed = @(Get-SysPilotWslDistros)
    # Empfohlene Reihenfolge
    $fav = @('Ubuntu-24.04','Ubuntu-22.04','Debian','FedoraLinux-45','archlinux','kali-linux','openSUSE-Tumbleweed')
    $items = @()
    foreach ($f in $fav) {
        $d = @($online | Where-Object { $_.Name -eq $f })[0]
        if ($d) {
            $mark = if ($installed -contains $d.Name) { ' [installiert]' } else { '' }
            $items += @{ Label = "$($d.Friendly) ($($d.Name))$mark"; Color = 'Cyan'; Tag = $d.Name }
        }
    }
    $items += @{ Label = '--- Alle Distributionen (online-Liste) ---'; Color = 'DarkGray'; Tag = '__all' }
    $items += @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = '__back' }

    $sel = Show-SysPilotArrowMenu -Items $items -Title 'WSL-Distro installieren' -Footer 'Pfeiltasten, Enter = auswaehlen, Esc = zurueck'
    if (-not $sel -or $sel -eq '__back') { return }

    if ($sel -eq '__all') {
        $allItems = foreach ($d in $online) {
            $mark = if ($installed -contains $d.Name) { ' [installiert]' } else { '' }
            @{ Label = "$($d.Friendly) ($($d.Name))$mark"; Color = 'White'; Tag = $d.Name }
        }
        $allItems += @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = '__back' }
        $sel = Show-SysPilotArrowMenu -Items $allItems -Title 'Alle WSL-Distros' -Footer 'Pfeiltasten, Enter = auswaehlen, Esc = zurueck'
        if (-not $sel -or $sel -eq '__back') { return }
    }

    if ($installed -contains $sel) {
        Write-Host "  '$sel' ist bereits installiert." -ForegroundColor DarkGray
        Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
        return
    }
    [void](Install-SysPilotWslDistroByName -Name $sel)
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
}

function Show-SysPilotWslFirstRunGuide {
    <# ADHS-Guide fuer WSL-Ersteinrichtung: WAS SysPilot automatisch
       kann (Feature-Enable, wsl --install, Update) vs. was der User
       in der Distro selbst macht (User, apt). #>
    $wslOk = $null -ne (Get-Command wsl.exe -ErrorAction SilentlyContinue)
    $steps = @(
        @{ T='WSL aktivieren (Windows-Feature + Kernel-Update)';
           Url='ms-settings:windowsfeatures'; Yt='install wsl2 windows 11';
           Hint='Admin noetig. SysPilot kann wsl --install --no-distribution ausfuehren (naechster Schritt fragt). Danach evtl. NEUSTART noetig.' },
        @{ T='Ubuntu-Distro installieren';
           Url=$null; Yt='wsl install ubuntu tutorial';
           Hint='SysPilot: Menu-Punkt "Linux-Distro installieren" waehlt Ubuntu und startet wsl --install -d Ubuntu automatisch.' },
        @{ T='Erster Start: Linux-Username + Passwort vergeben';
           Url=$null; Yt='wsl ubuntu first login username';
           Hint='Beim ersten Start fragt Ubuntu nach UNIX-Username + Passwort (NICHT das Windows-Passwort). Danach: Terminal zeigt name@rechner:~$' },
        @{ T='System aktualisieren + Optional: Docker in WSL';
           Url=$null; Yt='docker inside wsl2 ubuntu';
           Hint='In der Distro: sudo apt update && sudo apt upgrade -y. Fuer Docker: Menu "Linux-Distro + Paketmanager einrichten" bietet docker-ce an.' }
    )
    if (-not $wslOk) {
        Write-Host "`n  WSL ist nicht installiert. Schritt 1 ausfuehren?" -ForegroundColor Yellow
        if (Confirm-SysPilot 'wsl --install --no-distribution jetzt ausfuehren (Admin noetig)?') {
            if (Test-SysPilotAdmin) {
                Write-Host "  -> wsl --install --no-distribution ..." -ForegroundColor Cyan
                & wsl.exe --install --no-distribution 2>&1 | Out-Host
                Write-Host "  Falls Neustart noetig: SysPilot danach erneut aufrufen." -ForegroundColor Yellow
            } else {
                Write-Host "  [!] Admin noetig - SysPilot als Administrator neu starten." -ForegroundColor Red
                Write-Host "      Oder manuell (Admin-PowerShell): wsl --install --no-distribution" -ForegroundColor DarkGray
            }
        }
    }
    [void](Show-SysPilotStepGuide -Steps $steps -Title 'WSL Ersteinrichtung' -DoneText 'WSL bereit - Distro ueber "Linux-Distro installieren" holen.')
}

function Show-SysPilotWslMenu {
    <# WSL-Verwaltung: Status, Manager installieren, GUI-Config, Distro-Setup. #>
    $wslOk = $null -ne (Get-Command wsl.exe -ErrorAction SilentlyContinue)
    while ($true) {
        Write-Host ""
        Write-Host "  ========================================================" -ForegroundColor Cyan
        Write-Host "           SYSPilot WSL / LINUX-UMGEBUNG" -ForegroundColor Cyan
        Write-Host "  ========================================================" -ForegroundColor Cyan
        if (-not $wslOk) { Write-Host "  [!] WSL nicht installiert." -ForegroundColor Red }
        else {
            $st = Get-SysPilotWslStatus
            Write-Host ("  WSL {0} | Kernel {1} | WSLg {2} | Default: {3}" -f $st.WslVersion, $st.Kernel, $st.Wslg, $st.DefaultDistro) -ForegroundColor DarkGray
            Write-Host ("  Distros: {0}" -f $(if ($st.Distros.Count) { $st.Distros -join ', ' } else { 'keine' })) -ForegroundColor DarkGray
        }
        Write-Host ""

        $items = @(
            @{ Label = 'WSL-Status anzeigen';                              Color = 'Cyan';   Tag = 'status' },
            @{ Label = 'Ersteinrichtung Schritt-fuer-Schritt (ADHS-Guide, Videos)'; Color = 'Green'; Tag = 'firstrun' },
            @{ Label = 'WSL Manager installieren (GUI: Distro-Verwaltung, Backups, .wslconfig)'; Color = 'Green'; Tag = 'install-manager' },
            @{ Label = 'WSL Manager starten';                               Color = 'Green';  Tag = 'start-manager' },
            @{ Label = 'WSL aktualisieren (wsl --update)';                  Color = 'Yellow'; Tag = 'update' },
            @{ Label = 'GUI-Apps aktivieren (.wslconfig: guiApplications)'; Color = 'Magenta'; Tag = 'guiconfig' },
            @{ Label = 'Linux-Distro installieren (Ubuntu/Debian/Fedora/Arch/Kali ...)'; Color = 'Green'; Tag = 'distro-install' },
            @{ Label = 'Linux-Distro + Paketmanager einrichten (Ubuntu/Fedora/Arch)'; Color = 'Yellow'; Tag = 'distro' },
            @{ Label = 'WSL beenden (wsl --shutdown)';                      Color = 'DarkGray'; Tag = 'shutdown' },
            @{ Label = 'Zurueck';                                           Color = 'DarkGray'; Tag = 'back' }
        )
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'WSL-Verwaltung' -Footer 'Pfeiltasten, Enter = auswaehlen, Esc = zurueck'
        if (-not $sel -or $sel -eq 'back') { return }
        switch ($sel) {
            'firstrun' { Show-SysPilotWslFirstRunGuide; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
            'status' {
                $st = Get-SysPilotWslStatus
                Write-Host "`n  WSL-Version:  $($st.WslVersion)" -ForegroundColor White
                Write-Host "  Kernel:        $($st.Kernel)" -ForegroundColor White
                Write-Host "  WSLg (GUI):    $(if($st.Wslg){$st.Wslg + ' - aktiv'}else{'nicht erkannt'})" -ForegroundColor $(if($st.Wslg){'Green'}else{'Yellow'})
                Write-Host "  WSL-Version:   $($st.WslVersion2)" -ForegroundColor White
                Write-Host "  Default-Distro: $($st.DefaultDistro)" -ForegroundColor White
                Write-Host "  Distros:        $(if($st.Distros.Count){$st.Distros -join ', '}else{'keine'})" -ForegroundColor White
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'install-manager' {
                if (Install-SysPilotWslManager) {
                    if (Confirm-SysPilot "WSL Manager jetzt starten?") {
                        $exe = Get-ChildItem "$env:LOCALAPPDATA\Programs" -Recurse -Filter 'WSLManager.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
                        if ($exe) { Start-Process $exe.FullName }
                    }
                }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'start-manager' {
                $exe = Get-ChildItem "$env:LOCALAPPDATA\Programs" -Recurse -Filter 'WSLManager.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($exe) { Start-Process $exe.FullName; Write-Host "  Gestartet." -ForegroundColor Green }
                else { Write-Host "  [!] WSL Manager nicht installiert - zuerst installieren." -ForegroundColor Yellow }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'update' {
                if (-not (Test-SysPilotAdmin)) { Write-Host "  [!] Admin noetig fuer wsl --update." -ForegroundColor Yellow; Read-SysPilotChoice 'Weiter' | Out-Null; continue }
                Write-Host "  -> wsl --update ..." -ForegroundColor Cyan
                & wsl.exe --update 2>&1 | Out-Host
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'guiconfig' { Set-SysPilotWslGuiConfig | Out-Null; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
            'distro-install' { Show-SysPilotWslDistroPicker }
            'distro'    { Show-SysPilotPackageManagerInstallMenu }
            'shutdown'  {
                if (Confirm-SysPilot "Alle WSL-Distributionen beenden? (Offene Sessions werden getrennt)") {
                    & wsl.exe --shutdown
                    Write-Host "  WSL beendet." -ForegroundColor Green
                }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
        }
    }
}

# =====================================================================
# GUI & ERWEITERUNGEN der Paketmanager
# =====================================================================

function Find-SysPilotChocoExeLocal {
    <# choco.exe aufloesen (Fallback falls SoftwareUpdateCenter nicht
       geladen ist). Bevorzugt Get-SysPilotChocoExe aus dem Update-Center. #>
    if (Get-Command Get-SysPilotChocoExe -ErrorAction SilentlyContinue) {
        $e = Get-SysPilotChocoExe
        if ($e) { return $e }
    }
    $c = Get-Command choco.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in @("$env:ProgramData\chocolatey\bin\choco.exe",
                     "$env:LOCALAPPDATA\UniGetUI\Chocolatey\bin\choco.exe")) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Find-SysPilotChocoGui {
    <# Sucht ChocolateyGUI.exe (choco-Paket 'chocolateygui').
       MSI-Installationen landen in Program Files (x86), die
       lib-basierten in chocolatey\lib - beide werden geprueft. #>
    $cands = @(
        'C:\Program Files (x86)\Chocolatey GUI\ChocolateyGui.exe',
        'C:\Program Files (x86)\Chocolatey GUI\ChocolateyGuiCli.exe',
        'C:\Program Files\Chocolatey GUI\ChocolateyGui.exe',
        "$env:ProgramData\chocolatey\lib\chocolateygui\tools\ChocolateyGUI.exe",
        "$env:ProgramData\chocolatey\lib\chocolateygui\tools\chocolatey.gui.exe",
        "$env:LOCALAPPDATA\UniGetUI\Chocolatey\lib\chocolateygui\tools\ChocolateyGUI.exe"
    )
    foreach ($c in $cands) { if (Test-Path $c) { return $c } }
    # Tiefer Scan: chocolateygui-Paketordner in ProgramData UND UniGetUI-Choco
    foreach ($libRoot in @("$env:ProgramData\chocolatey\lib",
                           "$env:LOCALAPPDATA\UniGetUI\Chocolatey\lib")) {
        $pkgDir = Join-Path $libRoot 'chocolateygui'
        if (Test-Path $pkgDir) {
            $exe = Get-ChildItem $pkgDir -Recurse -Filter '*.exe' -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -match 'ChocolateyGUI|chocolatey\.gui' } | Select-Object -First 1
            if ($exe) { return $exe.FullName }
        }
    }
    $uninst = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
              'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
              'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $hit = Get-ItemProperty $uninst -ErrorAction SilentlyContinue |
           Where-Object { $_.DisplayName -match 'Chocolatey GUI' } | Select-Object -First 1
    if ($hit) { return $true }   # installiert, aber kein Pfad gefunden
    return $null
}

function Find-SysPilotOuiGui {
    <# Community-GUI 'OuiGui Chocolatey' (choco-Paket OuiGuiChocolatey).
       Liefert Pfad zur OuiGui.WPF.exe oder $true/'$null'. #>
    $cands = @(
        'C:\Program Files (x86)\OuiGui\OuiGui.WPF.exe',
        'C:\Program Files\OuiGui\OuiGui.WPF.exe',
        "$env:ProgramData\chocolatey\lib\OuiGuiChocolatey\tools\OuiGui.WPF.exe",
        "$env:LOCALAPPDATA\UniGetUI\Chocolatey\lib\OuiGuiChocolatey\tools\OuiGui.WPF.exe"
    )
    foreach ($c in $cands) { if (Test-Path $c) { return $c } }
    $pkgDir = "$env:LOCALAPPDATA\UniGetUI\Chocolatey\lib\OuiGuiChocolatey"
    if (Test-Path $pkgDir) {
        $exe = Get-ChildItem $pkgDir -Recurse -Filter '*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($exe) { return $exe.FullName }
    }
    $uninst = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
              'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
              'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $hit = Get-ItemProperty $uninst -ErrorAction SilentlyContinue |
           Where-Object { $_.DisplayName -match 'OuiGui' } | Select-Object -First 1
    if ($hit) { return $true }
    return $null
}

function Install-SysPilotOuiGui {
    <# Installiert OuiGui Chocolatey (Community-GUI, choco-Paket
       'OuiGuiChocolatey'). #>
    $exe = Find-SysPilotChocoExeLocal
    if (-not $exe) { Write-Host "  [!] Chocolatey nicht installiert." -ForegroundColor Red; return $false }
    $chk = & $exe list OuiGuiChocolatey --local-only --limit-output 2>&1 | Out-String
    if ($chk -match 'OuiGuiChocolatey') { Write-Host "  Bereits installiert." -ForegroundColor Green; return $true }
    Write-Host "  -> choco install OuiGuiChocolatey ..." -ForegroundColor Cyan
    $args = @('install','OuiGuiChocolatey','-y','--no-progress','--limit-output')
    if (Test-SysPilotAdmin) { & $exe @args 2>&1 | Out-Host }
    else {
        Write-Host "  -> Braucht Admin - UAC-Abfrage folgt ..." -ForegroundColor DarkGray
        $p = Start-Process $exe -ArgumentList $args -Verb RunAs -Wait -PassThru
        if ($p.ExitCode -ne 0) { Write-Host "  [!] choco-ExitCode $($p.ExitCode)" -ForegroundColor Yellow }
    }
    Start-Sleep -Seconds 2
    if (Find-SysPilotOuiGui) {
        Write-Host "  [OK] OuiGui Chocolatey installiert." -ForegroundColor Green
        Write-SysPilotLog 'OuiGuiChocolatey installiert'
        return $true
    }
    Write-Host "  [!] Installation unklar - pruefe choco list OuiGuiChocolatey" -ForegroundColor Yellow
    return $false
}

function Test-SysPilotChocoPkgInstalled {
    <# Prueft ob ein choco-Paket lokal installiert ist.
       Zuerst schneller Paketordner-Check (beide lib-Roots),
       dann Fallback auf 'choco list' (langsamer). #>
    param([string]$Package)
    foreach ($libRoot in @("$env:ProgramData\chocolatey\lib",
                           "$env:LOCALAPPDATA\UniGetUI\Chocolatey\lib")) {
        if (Test-Path (Join-Path $libRoot $Package)) { return $true }
    }
    $exe = Find-SysPilotChocoExeLocal
    if (-not $exe) { return $false }
    $chk = & $exe list $Package --local-only --limit-output 2>&1 | Out-String
    return ($chk -match [regex]::Escape($Package))
}

function Install-SysPilotChocoAppStoreExt {
    <# Installiert 'Chocolatey AppStore' Chrome-Extension
       (choco-Paket chocolatey-appstore-chrome). Maintained, ~2.0,
       fuegt 'Install with Chocolatey'-Buttons auf Download-Seiten ein. #>
    $exe = Find-SysPilotChocoExeLocal
    if (-not $exe) { Write-Host "  [!] Chocolatey nicht installiert." -ForegroundColor Red; return $false }
    if (Test-SysPilotChocoPkgInstalled -Package 'chocolatey-appstore-chrome') {
        Write-Host "  Bereits installiert." -ForegroundColor Green; return $true
    }
    Write-Host "  -> choco install chocolatey-appstore-chrome ..." -ForegroundColor Cyan
    $args = @('install','chocolatey-appstore-chrome','-y','--no-progress','--limit-output')
    if (Test-SysPilotAdmin) { & $exe @args 2>&1 | Out-Host }
    else {
        Write-Host "  -> Braucht Admin - UAC-Abfrage folgt ..." -ForegroundColor DarkGray
        $p = Start-Process $exe -ArgumentList $args -Verb RunAs -Wait -PassThru
        if ($p.ExitCode -ne 0) { Write-Host "  [!] choco-ExitCode $($p.ExitCode)" -ForegroundColor Yellow }
    }
    Write-Host "  [OK] Chocolatey AppStore registriert - Chrome fragt beim naechsten Start" -ForegroundColor Green
    Write-Host "        nach, die Erweiterung zu aktivieren (chrome://extensions)." -ForegroundColor DarkGray
    Write-SysPilotLog 'chocolatey-appstore-chrome installiert'
    return $true
}

function Install-SysPilotChocoGui {
    <# Installiert Chocolatey GUI (offizielles choco-Paket). #>
    $exe = Find-SysPilotChocoExeLocal
    if (-not $exe) { Write-Host "  [!] Chocolatey nicht installiert." -ForegroundColor Red; return $false }
    if (Find-SysPilotChocoGui) { Write-Host "  Bereits installiert." -ForegroundColor Green; return $true }
    Write-Host "  -> choco install chocolateygui ..." -ForegroundColor Cyan
    $args = @('install','chocolateygui','-y','--no-progress','--limit-output')
    if (Test-SysPilotAdmin) {
        & $exe @args 2>&1 | Out-Host
    } else {
        Write-Host "  -> Braucht Admin - UAC-Abfrage folgt ..." -ForegroundColor DarkGray
        $p = Start-Process $exe -ArgumentList $args -Verb RunAs -Wait -PassThru
        if ($p.ExitCode -ne 0) { Write-Host "  [!] choco-ExitCode $($p.ExitCode)" -ForegroundColor Yellow }
    }
    Start-Sleep -Seconds 2
    if (Find-SysPilotChocoGui) {
        Write-Host "  [OK] Chocolatey GUI installiert." -ForegroundColor Green
        Write-SysPilotLog 'Chocolatey GUI installiert'
        return $true
    }
    Write-Host "  [!] Installation unklar - pruefe choco list chocolateygui" -ForegroundColor Yellow
    return $false
}

function Install-SysPilotChocoBrowserExt {
    <# Installiert die (einzige existierende, inoffizielle) Chocolatey-
       Browser-Extension via choco-Paket 'choco-chrome-ext'. #>
    $exe = Find-SysPilotChocoExeLocal
    if (-not $exe) { Write-Host "  [!] Chocolatey nicht installiert." -ForegroundColor Red; return $false }
    if (Test-SysPilotChocoPkgInstalled -Package 'choco-chrome-ext') {
        Write-Host "  Bereits installiert." -ForegroundColor Green; return $true
    }
    Write-Host "  -> choco install choco-chrome-ext ..." -ForegroundColor Cyan
    $args = @('install','choco-chrome-ext','-y','--no-progress','--limit-output')
    if (Test-SysPilotAdmin) { & $exe @args 2>&1 | Out-Host }
    else {
        Write-Host "  -> Braucht Admin - UAC-Abfrage folgt ..." -ForegroundColor DarkGray
        $p = Start-Process $exe -ArgumentList $args -Verb RunAs -Wait -PassThru
        if ($p.ExitCode -ne 0) { Write-Host "  [!] choco-ExitCode $($p.ExitCode)" -ForegroundColor Yellow }
    }
    Write-Host "  [OK] Extension-Dateien installiert - in Chrome: chrome://extensions pruefen." -ForegroundColor Green
    Write-SysPilotLog 'choco-chrome-ext installiert'
    return $true
}

function Show-SysPilotUnigetUi {
    <# Unified GUI (UniGetUI) fuer winget/Chocolatey/Scoop/MS-Store:
       portables ZIP aus PortableTools nutzen (Download+Install+Start). #>
    if (-not (Get-Command Find-SysPilotPortableApp -ErrorAction SilentlyContinue)) {
        Import-Module (Join-Path $PSScriptRoot 'PortableTools.psm1') -Force -Global -ErrorAction SilentlyContinue
    }
    if (-not (Get-Command Find-SysPilotPortableApp -ErrorAction SilentlyContinue)) {
        Write-Host "  [!] PortableTools-Modul nicht verfuegbar." -ForegroundColor Red; return
    }
    $app = @{
        Id='unigetui'; Name='UniGetUI';
        Desc='GUI fuer WinGet, Scoop, Chocolatey u.a.';
        Repo='Devolutions/UniGetUI'; AssetPattern='UniGetUI\.x64\.zip$';
        Dir='UniGetUI'; Exe='UniGetUI.exe'; Type='zip';
        Web='https://github.com/Devolutions/UniGetUI/releases/latest'
    }
    $found = Find-SysPilotPortableApp -App $app
    if ($found -and $found.Path) {
        Write-Host "  UniGetUI gefunden: $($found.Path)" -ForegroundColor Green
        if (Confirm-SysPilot 'UniGetUI jetzt starten?') {
            Start-Process $found.Path
        }
        return
    }
    if (Confirm-SysPilot 'UniGetUI herunterladen und installieren? (~150MB portables ZIP)') {
        $path = Install-SysPilotPortableApp -App $app
        if ($path) { Start-Sleep -Seconds 1; Start-Process $path }
    }
}

function Show-SysPilotPmCompanionCatalogs {
    <# Oeffnet die offizielle Web-Katalogseite eines Managers. #>
    $kataloge = @(
        @{ Id='winget';    Name='WinGet / winget.run';      Url='https://www.winget.run/' },
        @{ Id='choco';     Name='Chocolatey Community';     Url='https://community.chocolatey.org/packages' },
        @{ Id='scoop';     Name='Scoop Hauptbucket';        Url='https://scoop.sh/' },
        @{ Id='npm';       Name='npm Registry';             Url='https://www.npmjs.com/' },
        @{ Id='pip';       Name='PyPI';                     Url='https://pypi.org/' },
        @{ Id='psgallery'; Name='PowerShell Gallery';       Url='https://www.powershellgallery.com/' },
        @{ Id='dotnet';    Name='NuGet Gallery';            Url='https://www.nuget.org/' },
        @{ Id='msstore';   Name='Microsoft Store';          Url='https://apps.microsoft.com/' },
        @{ Id='unigetui';  Name='UniGetUI Releases';        Url='https://github.com/Devolutions/UniGetUI/releases' }
    )
    $items = foreach ($k in $kataloge) { @{ Label = $k.Name; Color='Cyan'; Tag = $k.Id } }
    $items += @{ Label='Zurueck'; Color='DarkGray'; Tag='back' }
    $sel = Show-SysPilotArrowMenu -Items $items -Title 'PM-Kataloge / Repositories (Web)' -Footer 'Enter = Seite im Browser oeffnen, Esc = zurueck'
    if (-not $sel -or $sel -eq 'back') { return }
    $k = $kataloge | Where-Object Id -eq $sel | Select-Object -First 1
    if ($k) {
        Write-Host "  Oeffne $($k.Name) ..." -ForegroundColor Cyan
        Start-Process $k.Url
    }
}

function Show-SysPilotPmCompanionsMenu {
    <# GUI & Erweiterungen der Paketmanager. #>
    while ($true) {
        $chocoGui = Find-SysPilotChocoGui
        $guiMark = if ($chocoGui) { '[installiert]' } else { '[nicht vorhanden]' }
        $guiColor = if ($chocoGui) { 'Green' } else { 'White' }
        $ouiGui = Find-SysPilotOuiGui
        $ouiMark = if ($ouiGui) { '[installiert]' } else { '[nicht vorhanden]' }
        $ouiColor = if ($ouiGui) { 'Green' } else { 'White' }
        $appstore = Test-SysPilotChocoPkgInstalled -Package 'chocolatey-appstore-chrome'
        $asMark = if ($appstore) { '[installiert]' } else { '[nicht vorhanden]' }
        $asColor = if ($appstore) { 'Green' } else { 'White' }
        $ug = $null
        if (Get-Command Find-SysPilotPortableApp -ErrorAction SilentlyContinue) {
            try { $ug = Find-SysPilotPortableApp -App @{ Id='unigetui'; Name='UniGetUI'; Dir='UniGetUI'; Exe='UniGetUI.exe'; Type='zip' } } catch { }
        }
        $ugMark = if ($ug -and $ug.Path) { '[installiert]' } else { '[nicht vorhanden]' }
        $ugColor = if ($ug -and $ug.Path) { 'Green' } else { 'White' }
        $items = @(
            @{ Label = "UniGetUI (GUI fuer winget/Choco/Scoop/Store) $ugMark"; Color = $ugColor; Tag = 'unigetui' },
            @{ Label = "Chocolatey GUI (offiziell, WPF) $guiMark";      Color = $guiColor; Tag = 'choco-gui' },
            @{ Label = "OuiGui Chocolatey (Community-GUI) $ouiMark";    Color = $ouiColor; Tag = 'ouigui' },
            @{ Label = "Chocolatey AppStore-Ext (Chrome, gepflegt) $asMark"; Color = $asColor; Tag = 'appstore-ext' },
            @{ Label = 'Legacy-Ext: choco-chrome-ext (2016, inoffiziell)'; Color = 'DarkGray'; Tag = 'choco-ext' },
            @{ Label = 'PM-Kataloge / Repositories (Web)';              Color = 'Cyan';   Tag = 'kataloge' },
            @{ Label = 'GUI-/Extension-Uebersicht';                      Color = 'Cyan';   Tag = 'info' },
            @{ Label = 'Zurueck';                                        Color = 'DarkGray'; Tag = 'back' }
        )
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'Paketmanager - GUI & Erweiterungen' -Footer 'Pfeiltasten, Enter = waehlen, Esc = zurueck'
        if (-not $sel -or $sel -eq 'back') { return }
        switch ($sel) {
            'choco-gui' {
                $found = Find-SysPilotChocoGui
                if ($found -eq $true) {
                    Write-Host "  Installiert, aber Pfad nicht gefunden - Startmenue pruefen." -ForegroundColor Yellow
                } elseif ($found) {
                    Write-Host "  Starte Chocolatey GUI ..." -ForegroundColor Cyan
                    Start-Process $found
                } else {
                    if (Confirm-SysPilot 'Chocolatey GUI installieren? (offizielles Paket, ~50MB)') {
                        [void](Install-SysPilotChocoGui)
                    }
                }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'ouigui' {
                $found = Find-SysPilotOuiGui
                if ($found -eq $true) {
                    Write-Host "  Installiert, aber Pfad nicht gefunden - Startmenue pruefen." -ForegroundColor Yellow
                } elseif ($found) {
                    Write-Host "  Starte OuiGui Chocolatey ..." -ForegroundColor Cyan
                    Start-Process $found
                } else {
                    if (Confirm-SysPilot 'OuiGui Chocolatey installieren? (Community-GUI, choco-Paket)') {
                        [void](Install-SysPilotOuiGui)
                    }
                }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'appstore-ext' {
                Write-Host "`n  === Chocolatey AppStore (Browser-Extension) ===" -ForegroundColor Cyan
                Write-Host "  Gepflegte Extension (choco-Paket 'chocolatey-appstore-chrome'):" -ForegroundColor White
                Write-Host "  fuegt 'Install with Chocolatey'-Buttons auf Software-Download-Seiten ein." -ForegroundColor White
                Write-Host "  Chrome-Store: chrome.google.com/webstore/detail/chocolatey-appstore" -ForegroundColor DarkGray
                if (-not $appstore -and (Confirm-SysPilot 'Chocolatey AppStore-Extension installieren? (choco-Paket)')) {
                    [void](Install-SysPilotChocoAppStoreExt)
                }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'unigetui' { Show-SysPilotUnigetUi; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
            'kataloge' { Show-SysPilotPmCompanionCatalogs; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
            'choco-ext' {
                Write-Host "`n  === Legacy-Extension: choco-chrome-ext ===" -ForegroundColor Cyan
                Write-Host "  INOFFIZIELL, von 2016, unlisted, nicht gewartet." -ForegroundColor Yellow
                Write-Host "  Empfehlung: stattdessen 'Chocolatey AppStore' (Menuepunkt oben)." -ForegroundColor DarkGray
                Write-Host "  Installiert per: choco install choco-chrome-ext" -ForegroundColor DarkGray
                if (Confirm-SysPilot 'Trotzdem installieren? (Legacy, auf eigenes Risiko)') {
                    [void](Install-SysPilotChocoBrowserExt)
                }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'info' {
                Write-Host "`n  === GUI-/Extension-Uebersicht der Paketmanager ===" -ForegroundColor Cyan
                Write-Host "  Chocolatey : Chocolatey GUI (offiziell) + OuiGui (Community)" -ForegroundColor White
                Write-Host "               + Chocolatey AppStore Chrome-Extension (gepflegt)" -ForegroundColor White
                Write-Host "               + Legacy 'choco-chrome-ext' (2016, inoffiziell)" -ForegroundColor DarkGray
                Write-Host "  winget     : UniGetUI (portabel, deckt winget+msstore ab)" -ForegroundColor White
                Write-Host "  Scoop      : UniGetUI (deckt scoop ab); TUI: 'scoop install scoop-search'" -ForegroundColor White
                Write-Host "  npm/pip/dotnet/PSGallery: keine eigenen GUIs - Kataloge unter" -ForegroundColor DarkGray
                Write-Host "               'PM-Kataloge / Repositories' (npmjs.com, pypi.org u.a.)" -ForegroundColor DarkGray
                Write-Host "  WSL        : WSL Manager (Bostrot.WSLManager, siehe WSL-Menue)" -ForegroundColor White
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
        }
    }
}

# =====================================================================
# MENUES
# =====================================================================

function Show-SysPilotPackageManagerStatus {
    <# Uebersicht aller Manager mit Status. #>
    $rows = Get-SysPilotPackageManagers
    Write-Host ""
    Write-Host "  Paketmanager-Status:" -ForegroundColor Cyan
    Write-Host "  ----------------------------------------" -ForegroundColor DarkGray
    foreach ($r in $rows) {
        $color = switch ($r.Status) { 'installed' {'Green'} 'wsl-needed' {'Yellow'} default {'DarkGray'} }
        $mark = switch ($r.Status) { 'installed' {'[OK]'} 'wsl-needed' {'[!]'} default {'[--]'} }
        Write-Host ("  {0} {1,-22} {2,-8} {3}" -f $mark, $r.Name, $r.Kind, $r.Detail) -ForegroundColor $color
    }
    Write-Host ""
    Write-Host "  [gruen] installiert  [gelb] WSL noetig  [grau] fehlend" -ForegroundColor DarkGray
    # Herbert bietet fehlende Manager proaktiv an (bun, brew, WSL-Distros ...)
    $missingNative = @($rows | Where-Object { $_.Status -ne 'installed' -and $_.Status -ne 'wsl-needed' })
    if ($missingNative.Count -gt 0) {
        Write-Host ""
        Write-Host "  Fehlend: $($missingNative.Name -join ', ')" -ForegroundColor Yellow
        if (Confirm-SysPilot "Herbert kann fehlende Paketmanager installieren`n(z.B. Bun, Homebrew, WSL-Distros). Jetzt?") {
            Show-SysPilotPackageManagerInstallMenu
        }
    }
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
}

function Show-SysPilotPackageManagerSearch {
    <# Suche in ALLEM installierten Managern. #>
    param([string]$Query = '')
    $q = if ($Query) { $Query } else { Read-SysPilotInput 'Suchbegriff (alle Paketmanager)' '7zip' }
    if (-not $q) { return }
    Write-Host "  Suche in allen Paketmanagern ..." -ForegroundColor Cyan
    $results = Get-SysPilotPmSearchResults -Query $q
    if ($results.Count -eq 0) {
        Write-Host "  Keine Ergebnisse." -ForegroundColor Yellow
        Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
        return
    }
    # Gruppiert nach Manager anzeigen
    $results | Group-Object Manager | ForEach-Object {
        Write-Host "`n  === $($_.Name) ($($_.Count)) ===" -ForegroundColor Cyan
        $_.Group | Select-Object -First 10 | ForEach-Object {
            Write-Host ("    {0,-30} {1}" -f $_.Name, $_.Detail) -ForegroundColor White
        }
    }
    Write-Host "`n  Installiere mit: winget/choco/scoop/npm/pip/dotnet/Update-Module" -ForegroundColor DarkGray
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
}

function Show-SysPilotPackageManagerMenu {
    <# Hauptmenue fuer Paketmanager-Integration. #>
    while ($true) {
        $status = Get-SysPilotPackageManagers
        $installed = @($status | Where-Object { $_.Status -eq 'installed' }).Count
        $missing = @($status | Where-Object { $_.Status -ne 'installed' }).Count
        $items = @(
            @{ Label="Status anzeigen ($installed installiert, $missing fehlend)"; Color='Cyan';   Tag='status' },
            @{ Label='In ALLEN Managern suchen';                              Color='Green';   Tag='search' },
            @{ Label='Outdated-Scan (scoop/npm/pip/dotnet/PSGallery)';         Color='Yellow';  Tag='outdated' },
            @{ Label='WSL-Verwaltung (Distro, GUI-Apps, WSL Manager)';          Color='Cyan';    Tag='wsl' },
            @{ Label='GUI & Erweiterungen (Chocolatey GUI, UniGetUI, Browser-Ext)'; Color='Green'; Tag='gui' },
            @{ Label='Fehlende Manager installieren';                          Color='Magenta'; Tag='install' },
            @{ Label='Zurueck';                                                Color='DarkGray'; Tag='back' }
        )
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'Paketmanager' -Footer 'Pfeiltasten, Enter = waehlen, Esc = zurueck'
        if (-not $sel -or $sel -eq 'back') { return }
        switch ($sel) {
            'status'   { Show-SysPilotPackageManagerStatus }
            'search'   { Show-SysPilotPackageManagerSearch }
            'outdated' {
                $rows = Get-SysPilotPmOutdated
                if ($rows.Count -eq 0) { Write-Host "  [OK] Keine Outdated-Eintraege in PMs." -ForegroundColor Green }
                else {
                    Write-Host "  Outdated in Paketmanagern:" -ForegroundColor Cyan
                    $rows | Select-Object -First 30 | ForEach-Object {
                        Write-Host ("    {0,-20} {1,-15} {2} -> {3}" -f $_.Name, $_.Source, $_.Installed, $_.Available) -ForegroundColor White
                    }
                }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'wsl'      { Show-SysPilotWslMenu }
            'gui'      { Show-SysPilotPmCompanionsMenu }
            'install'  { Show-SysPilotPackageManagerInstallMenu }
        }
    }
}

function Show-SysPilotPackageManagerInstallMenu {
    <# Fehlende Manager auflisten und Install anbieten. #>
    $status = Get-SysPilotPackageManagers
    $missing = @($status | Where-Object { $_.Status -ne 'installed' })
    if ($missing.Count -eq 0) { Write-Host "  [OK] Alle Manager installiert." -ForegroundColor Green; return }
    $items = foreach ($m in $missing) {
        $canInstall = $m.Status -ne 'wsl-needed' -or $true  # WSL-PMs koennen auch installiert werden (WSL-Distro)
        @{ Label="{0} ({1}) - {2}" -f $m.Name, $m.Kind, $m.Detail; Color='Yellow'; Tag=$m.Id }
    }
    $items += @{ Label='Zurueck'; Color='DarkGray'; Tag='back' }
    $sel = Show-SysPilotArrowMenu -Items $items -Title 'Manager installieren' -Footer 'Enter = installieren, Esc = zurueck'
    if (-not $sel -or $sel -eq 'back') { return }
    if (Install-SysPilotPackageManager -Id $sel) {
        Write-Host "  [OK] $sel installiert." -ForegroundColor Green
    }
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
}

Export-ModuleMember -Function Get-SysPilotPackageManagerDefs, Get-SysPilotPackageManagers,
    Get-SysPilotWslDistros, Get-SysPilotScoopOutdated, Get-SysPilotNpmOutdated,
    Get-SysPilotPipOutdated, Get-SysPilotDotnetTools, Get-SysPilotDotnetOutdated,
    Get-SysPilotBunOutdated, Get-SysPilotPsGalleryOutdated,
    Get-SysPilotPmOutdated, Get-SysPilotPmCoverage, Invoke-SysPilotPmUpgrade, Get-SysPilotPmSearchResults,
    Install-SysPilotPackageManager, Install-SysPilotWslDistro,
    Show-SysPilotPackageManagerStatus, Show-SysPilotPackageManagerSearch,
    Show-SysPilotPackageManagerMenu, Show-SysPilotPackageManagerInstallMenu,
    Get-SysPilotWslStatus, Install-SysPilotWslManager, Set-SysPilotWslGuiConfig,
    Show-SysPilotWslMenu, Get-SysPilotWslOnlineDistros, Install-SysPilotWslDistroByName,
    Show-SysPilotWslFirstRunGuide,
    Show-SysPilotWslDistroPicker, Update-SysPilotScoopBuckets, Invoke-SysPilotScoopRaw,
    Find-SysPilotChocoGui, Find-SysPilotOuiGui, Find-SysPilotChocoExeLocal,
    Install-SysPilotChocoGui, Install-SysPilotOuiGui, Install-SysPilotChocoBrowserExt,
    Install-SysPilotChocoAppStoreExt, Test-SysPilotChocoPkgInstalled,
    Show-SysPilotUnigetUi, Show-SysPilotPmCompanionsMenu, Show-SysPilotPmCompanionCatalogs,
    Get-SysPilotPythonExeForPip, Install-SysPilotPmPackage
