#requires -Version 5.1
<#
    Cloudflare.psm1 - Cloudflare-Integration fuer SysPilot:
      A) CF-geschuetzte Downloads: Challenge-Erkennung + Browser-Impersion
         via Python curl_cffi (TLS-Fingerprint wie Chrome)
      B) Cloudflare WARP (1.1.1.1): Install, Status, Connect/Disconnect, Modi
      D) cloudflared-Tunnel: Uebersicht, Quick-Tunnel, Named-Tunnel, Loeschen
    Alles idempotent, ASCII-sicher, PS 5.1-kompatibel.
#>

function Get-SysPilotCloudflaredExe {
    <# cloudflared.exe finden (PATH, WinGet-Links, Standardpfade). #>
    $c = (Get-Command cloudflared -ErrorAction SilentlyContinue).Source
    if ($c -and (Test-Path $c)) { return $c }
    foreach ($p in "$env:ProgramFiles (x86)\cloudflared\cloudflared.exe",
                    "$env:ProgramFiles\cloudflared\cloudflared.exe",
                    "$env:LOCALAPPDATA\Microsoft\WinGet\Links\cloudflared.exe") {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Install-SysPilotCloudflared {
    <# cloudflared ueber winget installieren. #>
    $res = @{ Ok=$false; Via=''; Error='' }
    $w = $null
    try { $w = Get-SysPilotWingetExe } catch {}
    if (-not $w) { try { $w = (Get-Command winget.exe -ErrorAction Stop).Source } catch { $w = $null } }
    if (-not $w) { $res.Error = 'winget nicht gefunden'; return $res }
    $log = Join-Path $env:TEMP 'syspilot-cloudflared-install.log'
    try {
        & $w install --id 'Cloudflare.cloudflared' --exact --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 | Out-File $log -Encoding utf8
        Start-Sleep -Seconds 2
        $cf = Get-SysPilotCloudflaredExe
        if ($cf) { $res.Ok = $true; $res.Via = 'winget' }
        else { $res.Error = "installiert, aber cloudflared nicht gefunden (Log: $log)" }
    } catch { $res.Error = $_.Exception.Message }
    return $res
}

# =====================================================================
# A) Cloudflare-geschuetzte Downloads
# =====================================================================

function Test-SysPilotCfChallenge {
    <# Probe-GET (liest nur den Anfang der Antwort): erkennt
       Cloudflare-Challenge-Seiten (403/503 + challenge-Markierungen).
       Rueckgabe: @{IsChallenge;Status;Reason} oder $null bei Netzfehler. #>
    param(
        [Parameter(Mandatory)][string]$Uri,
        [int]$ProbeBytes = 65536
    )
    try {
        $req = [Net.HttpWebRequest]::Create($Uri)
        $req.Method = 'GET'
        $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
        $req.AllowAutoRedirect = $true
        $req.Timeout = 20000
        $req.ReadWriteTimeout = 15000
        $req.AutomaticDecompression = [Net.DecompressionMethods]::GZip -bor [Net.DecompressionMethods]::Deflate
        $resp = $req.GetResponse()
        try {
            $status = [int]$resp.StatusCode
            $hdrs = @{}
            foreach ($k in @($resp.Headers.AllKeys)) { $hdrs[[string]$k.ToLower()] = ([string]$resp.Headers[$k]) }
            $ms = New-Object IO.MemoryStream
            $rs = $resp.GetResponseStream()
            $buf = New-Object byte[] 8192
            $total = 0
            while ($total -lt $ProbeBytes) {
                $want = [Math]::Min(8192, $ProbeBytes - $total)
                $n = $rs.Read($buf, 0, $want)
                if ($n -le 0) { break }
                $ms.Write($buf, 0, $n); $total += $n
            }
            try { $rs.Close() } catch {}
            $ms.Position = 0
            $body = [Text.Encoding]::UTF8.GetString($ms.ToArray())
            $head = $body.Substring(0, [Math]::Min(8192, $body.Length))
            $isCfEdge = ($hdrs['server'] -match 'cloudflare') -or $hdrs.ContainsKey('cf-ray') -or $hdrs.ContainsKey('cf-mitigated')
            $markers = 'challenge-platform|cdn-cgi/challenge|Just a moment|cf-chl-|Attention Required|_cf_chl_opt'
            $challenge = ($hdrs['cf-mitigated'] -eq 'challenge') -or ($head -match $markers)
            $isHtml = ($hdrs['content-type'] -match 'text/html')
            if ($challenge -and ($isHtml -or $status -in @(401,403,503))) {
                return @{ IsChallenge=$true; Status=$status; Reason='Cloudflare-Challenge' }
            }
            if ($isCfEdge -and $status -in @(403,503) -and -not $challenge) {
                return @{ IsChallenge=$false; Status=$status; Reason='CF-Edge-Fehler (kein Challenge)' }
            }
            return @{ IsChallenge=$false; Status=$status }
        } finally { try { $resp.Close() } catch {} }
    } catch {
        return @{ IsChallenge=$false; Status=0; Reason="Probe-Fehler: $($_.Exception.Message)" }
    }
}

function Install-SysPilotCurlCffi {
    <# Installiert curl_cffi (Python, Chrome-TLS-Impersion) via pip. #>
    $res = @{ Ok=$false; Via=''; Error='' }
    $py = $null
    try { if (Get-Command Get-SysPilotPythonExeForPip -ErrorAction SilentlyContinue) { $py = Get-SysPilotPythonExeForPip } } catch {}
    if (-not $py) { $py = (Get-Command python.exe -ErrorAction SilentlyContinue).Source }
    if (-not $py) { $res.Error = 'python.exe nicht gefunden (pip/Python noetig)'; return $res }
    # Bereits vorhanden?
    try {
        & $py -c "import curl_cffi" 2>$null
        if ($LASTEXITCODE -eq 0) { $res.Ok = $true; $res.Via = 'vorhanden'; return $res }
    } catch {}
    Write-Host "  Installiere curl_cffi via pip ..." -ForegroundColor Cyan
    try {
        & $py -m pip install --quiet --disable-pip-version-check curl_cffi 2>&1 | Out-Null
        & $py -c "import curl_cffi" 2>$null
        if ($LASTEXITCODE -eq 0) { $res.Ok = $true; $res.Via = 'pip' }
        else { $res.Error = 'pip-Install lief, aber Import-Test schlug fehl' }
    } catch { $res.Error = $_.Exception.Message }
    return $res
}

function Invoke-SysPilotCfDownload {
    <# Download ueber curl_cffi (Chrome-Impersion) - schlaegt Cloudflare-
       Challenges oft fehl, die aria2/segments nicht loesen koennen.
       Progress ueber Datei-Wachstum. Rueckgabe @{Ok;Path;Error}. #>
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile,
        [string]$Label = 'Download',
        [int]$TimeoutSec = 900,
        [object]$ProgressQueue = $null
    )
    $res = @{ Ok=$false; Path=$null; Error='' }
    $py = $null
    try { if (Get-Command Get-SysPilotPythonExeForPip -ErrorAction SilentlyContinue) { $py = Get-SysPilotPythonExeForPip } } catch {}
    if (-not $py) { $py = (Get-Command python.exe -ErrorAction SilentlyContinue).Source }
    if (-not $py) { $res.Error = 'python.exe nicht gefunden'; return $res }
    try { & $py -c "import curl_cffi" 2>$null; if ($LASTEXITCODE -ne 0) { $res.Error = 'curl_cffi fehlt'; return $res } } catch {}

    $outDir = Split-Path $OutFile -Parent
    if (-not $outDir) { $outDir = '.' }
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
    if (Test-Path $OutFile) { Remove-Item $OutFile -Force -ErrorAction SilentlyContinue }

    $pyFile = Join-Path $env:TEMP ("syspilot-cf-dl-{0}.py" -f [Guid]::NewGuid().ToString('N'))
    $resFile = "$pyFile.json"
    $script = @'
import sys, json
url, out, resf = sys.argv[1], sys.argv[2], sys.argv[3]
def done(**kw):
    with open(resf, "w", encoding="utf-8") as f:
        json.dump(kw, f)
    sys.exit(kw.get("code", 0))
try:
    from curl_cffi import requests
except Exception as e:
    done(ok=False, err="curl_cffi import: %s" % e, code=2)
try:
    r = requests.get(url, impersonate="chrome", stream=True,
                     timeout=(20, 120), allow_redirects=True)
    code = r.status_code
    hdrs = {k.lower(): v for k, v in r.headers.items()}
    first = next(r.iter_content(65536), b"")
    head = first[:8192].lower()
    challenge = (hdrs.get("cf-mitigated", "") == "challenge") or \
        (b"challenge-platform" in head) or (b"cdn-cgi/challenge" in head) or \
        (b"just a moment" in head) or (b"cf-chl" in head) or (b"_cf_chl_opt" in head)
    ctype = hdrs.get("content-type", "")
    if challenge and (("html" in ctype) or code in (401, 403, 503)):
        done(ok=False, err="cf_challenge", status=code, code=3)
    if code >= 400:
        done(ok=False, err="http_%d" % code, status=code, code=4)
    n = 0
    with open(out, "wb") as f:
        if first:
            f.write(first); n += len(first)
        for chunk in r.iter_content(1 << 16):
            if chunk:
                f.write(chunk); n += len(chunk)
    done(ok=True, size=n, status=code, url=str(r.url), code=0)
except Exception as e:
    done(ok=False, err=str(e)[:300], code=5)
'@
    try { [IO.File]::WriteAllText($pyFile, $script, (New-Object Text.UTF8Encoding $false)) } catch { $res.Error = "Skript schreiben: $($_.Exception.Message)"; return $res }

    Write-Host "  curl_cffi: $Label (Chrome-Impersion) ..." -ForegroundColor Magenta
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $py
    $psi.Arguments = "`"$pyFile`" `"$Uri`" `"$OutFile`" `"$resFile`""
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $proc = New-Object Diagnostics.Process
    $proc.StartInfo = $psi
    try { [void]$proc.Start() } catch { $res.Error = "Start: $($_.Exception.Message)"; Remove-Item $pyFile,$resFile -Force -ErrorAction SilentlyContinue; return $res }

    $sw = [Diagnostics.Stopwatch]::StartNew(); $lastUi = [datetime]::MinValue; $lastGrow = Get-Date
    try {
        while (-not $proc.HasExited) {
            Start-Sleep -Milliseconds 500
            if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) { try { $proc.Kill() } catch {}; throw "curl_cffi-Timeout nach ${TimeoutSec}s" }
            $sz = 0L
            if (Test-Path $OutFile) { try { $sz = (Get-Item $OutFile).Length } catch {} }
            if ($sz -gt 0) { $lastGrow = Get-Date }
            if (((Get-Date) - $lastUi).TotalMilliseconds -gt 500) {
                $lastUi = Get-Date
                $mb = [math]::Round($sz/1MB,1)
                Write-Host ("`r  $Label : $mb MB (curl_cffi)   ") -NoNewline
                if ($ProgressQueue -and $mb -gt 0) {
                    $ProgressQueue.Enqueue(@{ Pct=-1; Recv=$sz; Total=0; MBR=$mb; MBT=0; MBS=0; Label=$Label; Note='curl_cffi Chrome-Impersion' })
                }
            }
        }
        $proc.WaitForExit(5000) | Out-Null
    } catch {
        $res.Error = $_.Exception.Message
        try { $proc.Kill() } catch {}
        Remove-Item $pyFile,$resFile -Force -ErrorAction SilentlyContinue
        return $res
    }
    Remove-Item $pyFile -Force -ErrorAction SilentlyContinue
    $out = ''
    if (Test-Path $resFile) { try { $out = (Get-Content $resFile -Raw -ErrorAction Stop) } catch {}; Remove-Item $resFile -Force -ErrorAction SilentlyContinue }
    try {
        $j = $out | ConvertFrom-Json
        if ($j.ok -and (Test-Path $OutFile) -and ((Get-Item $OutFile).Length -gt 0)) {
            $res.Ok = $true; $res.Path = $OutFile
            Write-Host "`r  $Label : OK ($([math]::Round((Get-Item $OutFile).Length/1MB,1)) MB)                    " -ForegroundColor Green
            if ($ProgressQueue) { $ProgressQueue.Enqueue(@{ Pct=100; Recv=(Get-Item $OutFile).Length; Total=(Get-Item $OutFile).Length; MBR=0; MBT=0; MBS=0; Label=$Label; Note='fertig' }) }
        } else {
            $res.Error = "curl_cffi: $($j.err)$(if($j.status){" (HTTP $($j.status))"})"
            if ($j.err -eq 'cf_challenge') { $res.Error = 'Cloudflare-Challenge auch per Impersion nicht geloest (evtl. interaktive Pruefung noetig)' }
            Write-Host "`r  [!] $($res.Error)" -ForegroundColor Red
        }
    } catch { $res.Error = "Kein Ergebnis: $out" }
    return $res
}

# =====================================================================
# B) Cloudflare WARP (1.1.1.1)
# =====================================================================

function Get-SysPilotWarpCli {
    <# warp-cli.exe finden. #>
    $c = (Get-Command warp-cli.exe -ErrorAction SilentlyContinue).Source
    if ($c -and (Test-Path $c)) { return $c }
    foreach ($p in "$env:ProgramFiles\Cloudflare\Cloudflare WARP\warp-cli.exe",
                    "${env:ProgramFiles(x86)}\Cloudflare\Cloudflare WARP\warp-cli.exe") {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Invoke-SysPilotWarpCli {
    param([Parameter(Mandatory)][string[]]$Args, [int]$TimeoutSec = 30)
    $cli = Get-SysPilotWarpCli
    if (-not $cli) { return @{ Ok=$false; Out=''; Error='warp-cli nicht gefunden' } }
    try {
        $out = & $cli @Args 2>&1 | Out-String
        return @{ Ok=($LASTEXITCODE -eq 0); Out=$out.Trim(); Error=$(if($LASTEXITCODE -ne 0){$out.Trim()}else{''}) }
    } catch { return @{ Ok=$false; Out=''; Error=$_.Exception.Message } }
}

function Get-SysPilotWarpStatus {
    <# Status-Objekt: Installed/Service/Registered/Connected/Mode. #>
    $cli = Get-SysPilotWarpCli
    $svc = Get-Service -Name 'CloudflareWARP' -ErrorAction SilentlyContinue
    $st = @{ Installed=[bool]$cli; Service=($svc.Status -eq 'Running'); Registered=$false; Connected=$false; Mode=''; Account=''; Error='' }
    if (-not $cli) { return $st }
    $reg = Invoke-SysPilotWarpCli -Args @('registration','show')
    if ($reg.Ok -and $reg.Out -notmatch 'Not Registered|No') { $st.Registered = $true; if ($reg.Out -match 'Account type:\s*(\S+)') { $st.Account = $Matches[1] } }
    $s = Invoke-SysPilotWarpCli -Args @('status')
    if ($s.Ok -and $s.Out -match 'Connected') { $st.Connected = $true }
    $m = Invoke-SysPilotWarpCli -Args @('settings')
    if ($m.Ok -and $m.Out -match '(?im)^\s*mode\s*[:=]\s*(\S+)') { $st.Mode = $Matches[1] }
    return $st
}

function Install-SysPilotWarp {
    <# Cloudflare WARP per winget installieren. #>
    $res = @{ Ok=$false; Via=''; Error='' }
    $w = $null
    try { $w = Get-SysPilotWingetExe } catch {}
    if (-not $w) { $w = (Get-Command winget.exe -ErrorAction SilentlyContinue).Source }
    if (-not $w) { $res.Error = 'winget nicht gefunden'; return $res }
    try {
        & $w install --id 'Cloudflare.Warp' --exact --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 | Out-Null
        Start-Sleep -Seconds 3
        if (Get-SysPilotWarpCli) { $res.Ok = $true; $res.Via = 'winget' }
        else { $res.Error = 'winget-Install lief, aber warp-cli nicht gefunden' }
    } catch { $res.Error = $_.Exception.Message }
    return $res
}

function Show-SysPilotWarpMenu {
    <# WARP-Menue: Status, Install, Connect/Disconnect, Modi. #>
    while ($true) {
        $st = Get-SysPilotWarpStatus
        Write-Host ''
        Write-Host '  === CLOUDFLARE WARP (1.1.1.1) ===' -ForegroundColor Cyan
        if (-not $st.Installed) { Write-Host '  WARP ist nicht installiert.' -ForegroundColor Yellow }
        else {
            Write-Host ("  Installiert: ja | Service: {0} | Registriert: {1} | Verbunden: {2} | Modus: {3} {4}" -f `
                $(if($st.Service){'laeuft'}else{'gestoppt'}), $(if($st.Registered){'ja'}else{'nein'}), `
                $(if($st.Connected){'JA'}else{'nein'}), $(if($st.Mode){$st.Mode}else{'?'}) , $(if($st.Account){"($($st.Account))"}else{''})) -ForegroundColor Green
        }
        $items = @()
        if (-not $st.Installed) {
            $items += @{ Label='WARP installieren (winget Cloudflare.Warp)'; Color='Green'; Tag='install' }
        } else {
            if (-not $st.Registered) { $items += @{ Label='Registrieren (warp-cli registration new)'; Color='Green'; Tag='reg' } }
            $items += @{ Label=$(if($st.Connected){'Trennen (warp-cli disconnect)'}else{'Verbinden (warp-cli connect)'}); Color='Yellow'; Tag=$(if($st.Connected){'disc'}else{'conn'}) }
            $items += @{ Label='Modus: Warp+Doh (Empfehlung)'; Color='White'; Tag='m-warpdoh' }
            $items += @{ Label='Modus: Nur DNS (Dot)'; Color='White'; Tag='m-dot' }
            $items += @{ Label='Modus: Warp (nur VPN, kein DNS)'; Color='White'; Tag='m-warp' }
            $items += @{ Label='Modus: Aus (warp-cli mode dot + disconnect)'; Color='White'; Tag='m-off' }
            $items += @{ Label='Service neustarten'; Color='DarkGray'; Tag='svc' }
        }
        $items += @{ Label='Zurueck'; Color='DarkGray'; Tag='back' }
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'WARP-Menue' -Footer 'Pfeile + Enter, Esc = zurueck'
        if ($null -eq $sel -or $sel -eq 'back') { return }
        switch ($sel) {
            'install' {
                $r = Install-SysPilotWarp
                if ($r.Ok) { Write-Host "  [OK] WARP installiert." -ForegroundColor Green } else { Write-Host "  [FAIL] $($r.Error)" -ForegroundColor Red }
                Read-SysPilotChoice 'Weiter' | Out-Null
            }
            'reg' {
                $r = Invoke-SysPilotWarpCli -Args @('registration','new')
                if ($r.Ok) { Write-Host "  [OK] Registriert." -ForegroundColor Green } else { Write-Host "  [FAIL] $($r.Error)" -ForegroundColor Red }
                Read-SysPilotChoice 'Weiter' | Out-Null
            }
            'conn' {
                $r = Invoke-SysPilotWarpCli -Args @('connect') -TimeoutSec 60
                if ($r.Ok -or $r.Out -match 'Connecting|Success') { Write-Host "  [OK] Verbinde ..." -ForegroundColor Green; Start-Sleep 3; $s2=Invoke-SysPilotWarpCli -Args @('status'); Write-Host "  Status: $($s2.Out)" -ForegroundColor DarkGray }
                else { Write-Host "  [FAIL] $($r.Error)" -ForegroundColor Red }
                Read-SysPilotChoice 'Weiter' | Out-Null
            }
            'disc' {
                $r = Invoke-SysPilotWarpCli -Args @('disconnect')
                Write-Host "  $($r.Out)" -ForegroundColor DarkGray
                Read-SysPilotChoice 'Weiter' | Out-Null
            }
            { $_ -like 'm-*' } {
                $modeMap = @{ 'm-warpdoh'='warp+doh'; 'm-dot'='dot'; 'm-warp'='warp'; 'm-off'='dot' }
                $mode = $modeMap[$sel]
                if ($sel -eq 'm-off') { [void](Invoke-SysPilotWarpCli -Args @('disconnect')); $mode='dot' }
                $r = Invoke-SysPilotWarpCli -Args @('mode', $mode)
                if ($r.Ok) { Write-Host "  [OK] Modus = $mode" -ForegroundColor Green; if ($sel -ne 'm-off') { [void](Invoke-SysPilotWarpCli -Args @('connect')) } }
                else { Write-Host "  [FAIL] $($r.Error)" -ForegroundColor Red }
                Read-SysPilotChoice 'Weiter' | Out-Null
            }
            'svc' {
                if (Test-SysPilotAdmin) { try { Restart-Service CloudflareWARP -Force -ErrorAction Stop; Write-Host '  [OK] Service neu gestartet.' -ForegroundColor Green } catch { Write-Host "  [FAIL] $($_.Exception.Message)" -ForegroundColor Red } }
                else { Write-Host '  Admin noetig fuer Service-Steuerung.' -ForegroundColor Yellow }
                Read-SysPilotChoice 'Weiter' | Out-Null
            }
        }
    }
}

# =====================================================================
# D) cloudflared-Tunnel
# =====================================================================

function Get-SysPilotCfTunnels {
    <# Listet vorhandene named tunnels (cloudflared tunnel list). #>
    $cf = Get-SysPilotCloudflaredExe
    if (-not $cf) { return @() }
    $out = & $cf tunnel list 2>&1 | Out-String
    $tunnels = @()
    foreach ($line in ($out -split "`r?`n")) {
        if ($line -match '^\s*([0-9a-f\-]{36})\s+(\S+)\s+(\d{4}-\d{2}-\d{2})') {
            $tunnels += [pscustomobject]@{ Id=$Matches[1]; Name=$Matches[2]; Created=$Matches[3] }
        }
    }
    return $tunnels
}

function Start-SysPilotCfQuickTunnel {
    <# Quick-Tunnel: oeffentliche trycloudflare-URL auf lokalen Port.
       Startet cloudflared als Hintergrundprozess, wartet auf die URL.
       Rueckgabe: @{Ok;Url;Process} - Prozess laeuft bis SysPilot endet. #>
    param([int]$LocalPort = 8080, [int]$WaitSec = 30)
    $res = @{ Ok=$false; Url=''; Process=$null; Error='' }
    $cf = Get-SysPilotCloudflaredExe
    if (-not $cf) { $res.Error = 'cloudflared nicht gefunden'; return $res }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $cf
    $psi.Arguments = "tunnel --url http://localhost:$LocalPort --no-autoupdate"
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $proc = New-Object Diagnostics.Process
    $proc.StartInfo = $psi
    try { [void]$proc.Start() } catch { $res.Error = "Start: $($_.Exception.Message)"; return $res }
    $sb = New-Object Text.StringBuilder
    $deadline = (Get-Date).AddSeconds($WaitSec)
    try {
        while ((Get-Date) -lt $deadline -and -not $proc.HasExited) {
            # stdout+stderr non-blocking auslesen
            while ($proc.StandardOutput.Peek() -ge 0) { [void]$sb.Append([char]$proc.StandardOutput.Read()) }
            while ($proc.StandardError.Peek() -ge 0) { [void]$sb.Append([char]$proc.StandardError.Read()) }
            $txt = $sb.ToString()
            if ($txt -match '(https://[a-z0-9\-]+\.trycloudflare\.com)') {
                $res.Ok = $true; $res.Url = $Matches[1]; $res.Process = $proc
                return $res
            }
            Start-Sleep -Milliseconds 300
        }
        $res.Error = 'Keine trycloudflare-URL in ' + $WaitSec + 's erhalten'
        try { $proc.Kill() } catch {}
    } catch { $res.Error = $_.Exception.Message; try { $proc.Kill() } catch {} }
    return $res
}

function Show-SysPilotCfTunnelMenu {
    <# Tunnel-Menue: Uebersicht, Quick-Tunnel, Named-Tunnel, Loeschen. #>
    while ($true) {
        $cf = Get-SysPilotCloudflaredExe
        Write-Host ''
        Write-Host '  === CLOUDFLARED TUNNEL ===' -ForegroundColor Cyan
        if (-not $cf) { Write-Host '  cloudflared nicht installiert.' -ForegroundColor Yellow }
        else {
            $t = Get-SysPilotCfTunnels
            Write-Host "  Installiert: ja | Named Tunnels: $($t.Count)" -ForegroundColor Green
            foreach ($x in $t) { Write-Host "    - $($x.Name) ($($x.Id.Substring(0,8))...) erstellt $($x.Created)" -ForegroundColor DarkGray }
            $q = Get-Process cloudflared -ErrorAction SilentlyContinue
            if ($q) { Write-Host "  Quick-Tunnel-Prozess laeuft (PID $($q[0].Id))" -ForegroundColor DarkCyan }
        }
        $items = @()
        if (-not $cf) {
            $items += @{ Label='cloudflared installieren (winget)'; Color='Green'; Tag='install' }
        } else {
            $items += @{ Label='Tunnel-Uebersicht (cloudflared tunnel list)'; Color='White'; Tag='list' }
            $items += @{ Label='Quick-Tunnel starten (lokaler Port -> oeffentliche URL)'; Color='Green'; Tag='quick' }
            if (Get-Command Show-SysPilotCfNamedTunnel -ErrorAction SilentlyContinue) {
                $items += @{ Label='Named Tunnel einrichten (gefuehrtes Setup, fester Hostname)'; Color='Green'; Tag='named' }
            }
            $items += @{ Label='Tunnel loeschen'; Color='Red'; Tag='del' }
        }
        $items += @{ Label='Zurueck'; Color='DarkGray'; Tag='back' }
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'Tunnel-Menue' -Footer 'Pfeile + Enter, Esc = zurueck'
        if ($null -eq $sel -or $sel -eq 'back') { return }
        switch ($sel) {
            'install' {
                $r = Install-SysPilotCloudflared
                if ($r.Ok) { Write-Host '  [OK] cloudflared installiert.' -ForegroundColor Green } else { Write-Host "  [FAIL] $($r.Error)" -ForegroundColor Red }
                Read-SysPilotChoice 'Weiter' | Out-Null
            }
            'list' {
                $cf = Get-SysPilotCloudflaredExe
                Write-Host ''
                & $cf tunnel list 2>&1 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
                Read-SysPilotChoice 'Weiter' | Out-Null
            }
            'quick' {
                $port = Read-SysPilotInput 'Lokaler Port (z.B. 8080)' '8080'
                $pi = 0; if (-not [int]::TryParse($port, [ref]$pi) -or $pi -lt 1 -or $pi -gt 65535) { Write-Host '  Uungueltiger Port.' -ForegroundColor Red; Read-SysPilotChoice 'Weiter' | Out-Null; continue }
                Write-Host "  Starte Quick-Tunnel auf Port $pi ..." -ForegroundColor Cyan
                $r = Start-SysPilotCfQuickTunnel -LocalPort $pi -WaitSec 40
                if ($r.Ok) {
                    Write-Host ''
                    Write-Host "  [OK] Oeffentliche URL: $($r.Url)" -ForegroundColor Green
                    Write-Host "  Leitet auf http://localhost:$pi um. Laeuft bis SysPilot beendet wird." -ForegroundColor DarkGray
                } else { Write-Host "  [FAIL] $($r.Error)" -ForegroundColor Red }
                Read-SysPilotChoice 'Weiter' | Out-Null
            }
            'named' {
                if (Get-Command Show-SysPilotCfNamedTunnel -ErrorAction SilentlyContinue) {
                    try { Show-SysPilotCfNamedTunnel } catch { Write-Host "  [FAIL] $($_.Exception.Message)" -ForegroundColor Red }
                }
            }
            'del' {
                $cf = Get-SysPilotCloudflaredExe
                $t = @(Get-SysPilotCfTunnels)
                if ($t.Count -eq 0) { Write-Host '  Keine Tunnels vorhanden.' -ForegroundColor DarkGray; Read-SysPilotChoice 'Weiter' | Out-Null; continue }
                $names = @($t | ForEach-Object { $_.Name })
                Write-Host '  Verfuegbare Tunnels:' -ForegroundColor Cyan
                for ($i=0; $i -lt $names.Count; $i++) { Write-Host "    $($i+1). $($names[$i])" -ForegroundColor White }
                $pick = Read-SysPilotInput "Nummer waehlen (1-$($names.Count))"
                $pi = 0
                if ([int]::TryParse($pick, [ref]$pi) -and $pi -ge 1 -and $pi -le $names.Count) {
                    $tn = $names[$pi-1]
                    if (Confirm-SysPilot "Tunnel '$tn' wirklich loeschen? (DNS-Eintrag ggf. separat im CF-Dashboard entfernen)") {
                        & $cf tunnel cleanup $tn 2>&1 | Out-Null
                        & $cf tunnel delete -f $tn 2>&1 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
                        Write-Host "  [OK] Tunnel '$tn' geloescht." -ForegroundColor Green
                    }
                }
                Read-SysPilotChoice 'Weiter' | Out-Null
            }
        }
    }
}

# =====================================================================
# Obermenue + CF-Download-Test
# =====================================================================

function Show-SysPilotCfDownloadTest {
    <# Testet eine URL: Probe -> Challenge? -> curl_cffi-Versuch. #>
    $url = Read-SysPilotInput 'URL zum Testen (z.B. CF-geschuetzter Download)'
    if (-not $url) { return }
    Write-Host "  Probe: $url ..." -ForegroundColor Cyan
    $probe = Test-SysPilotCfChallenge -Uri $url
    if ($probe) {
        Write-Host ("  Status: {0} | Challenge: {1} | {2}" -f $probe.Status, $probe.IsChallenge, $probe.Reason) -ForegroundColor DarkGray
        if ($probe.IsChallenge) {
            $inst = Install-SysPilotCurlCffi
            if (-not $inst.Ok) { Write-Host "  [!] curl_cffi nicht installierbar: $($inst.Error)" -ForegroundColor Red; Read-SysPilotChoice 'Weiter' | Out-Null; return }
            if ($inst.Via -ne 'vorhanden') { Write-Host "  [OK] curl_cffi installiert via $($inst.Via)" -ForegroundColor Green }
            $out = Join-Path $env:TEMP ("cf-test-" + [IO.Path]::GetFileName(([Uri]$url).AbsolutePath))
            $r = Invoke-SysPilotCfDownload -Uri $url -OutFile $out -Label 'CF-Test' -TimeoutSec 300
            if ($r.Ok) { Write-Host "  [OK] Download erfolgreich: $($r.Path) ($([math]::Round((Get-Item $r.Path).Length/1MB,2)) MB)" -ForegroundColor Green }
            else { Write-Host "  [FAIL] $($r.Error)" -ForegroundColor Red }
        } else {
            Write-Host '  Keine Challenge - normaler Download (aria2/Segmente) funktioniert vermutlich.' -ForegroundColor Green
        }
    }
    Read-SysPilotChoice 'Weiter' | Out-Null
}

function Show-SysPilotCloudflareMenu {
    <# Obermenue: WARP / Tunnel / CF-Downloads. #>
    while ($true) {
        $warp = Get-SysPilotWarpStatus
        $cf = Get-SysPilotCloudflaredExe
        Write-Host ''
        Write-Host '  === CLOUDFLARE-MANAGER ===' -ForegroundColor Cyan
        Write-Host ("  WARP: {0} | cloudflared: {1}" -f $(if($warp.Installed){"installiert, $(if($warp.Connected){'VERBUNDEN'}else{'getrennt'})"}else{'nicht installiert'}), $(if($cf){'installiert'}else{'nicht installiert'})) -ForegroundColor DarkGray
        $items = @(
            @{ Label='WARP (1.1.1.1): Status, Install, Connect, Modi'; Color='Green'; Tag='warp' }
            @{ Label='Tunnel: Uebersicht, Quick-Tunnel, Named-Tunnel, Loeschen'; Color='Green'; Tag='tunnel' }
            @{ Label='CF-Download-Test (Challenge erkennen + curl_cffi-Bypass)'; Color='Yellow'; Tag='dltest' }
            @{ Label='curl_cffi installieren (Browser-Impersion fuer CF-Downloads)'; Color='White'; Tag='curlcffi' }
            @{ Label='Zurueck'; Color='DarkGray'; Tag='back' }
        )
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'Cloudflare-Manager' -Footer 'Pfeile + Enter, Esc = zurueck'
        if ($null -eq $sel -or $sel -eq 'back') { return }
        switch ($sel) {
            'warp'    { Show-SysPilotWarpMenu }
            'tunnel'  { Show-SysPilotCfTunnelMenu }
            'dltest'  { Show-SysPilotCfDownloadTest }
            'curlcffi' {
                $r = Install-SysPilotCurlCffi
                if ($r.Ok) { Write-Host "  [OK] curl_cffi ($($r.Via))" -ForegroundColor Green } else { Write-Host "  [FAIL] $($r.Error)" -ForegroundColor Red }
                Read-SysPilotChoice 'Weiter' | Out-Null
            }
        }
    }
}

Export-ModuleMember -Function `
    Get-SysPilotCloudflaredExe, Install-SysPilotCloudflared, `
    Test-SysPilotCfChallenge, Install-SysPilotCurlCffi, Invoke-SysPilotCfDownload, `
    Get-SysPilotWarpCli, Invoke-SysPilotWarpCli, Get-SysPilotWarpStatus, Install-SysPilotWarp, `
    Show-SysPilotWarpMenu, Get-SysPilotCfTunnels, Start-SysPilotCfQuickTunnel, `
    Show-SysPilotCfTunnelMenu, Show-SysPilotCfDownloadTest, Show-SysPilotCloudflareMenu
