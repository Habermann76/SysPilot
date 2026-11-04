# SysPilot - Updater: sucht auf GitHub nach neuen Versionen und installiert sie auf Wunsch
#Requires -Version 5.1

$script:SysPilotRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$script:RepoApi     = 'https://api.github.com/repos/Habermann76/SysPilot'
$script:RepoVersion = 'https://raw.githubusercontent.com/Habermann76/SysPilot/master/version.txt'
$script:ReleasesUrl = 'https://github.com/Habermann76/SysPilot/releases/latest'

function Get-SysPilotVersion {
    <# Installierte Version (steht in version.txt neben SysPilot.ps1). #>
    $f = Join-Path $script:SysPilotRoot 'version.txt'
    if (Test-Path $f) {
        $v = (Get-Content $f -Raw -ErrorAction SilentlyContinue)
        if ($v) { $v = $v.Trim(); if ($v) { return $v } }
    }
    return '0.0.0'
}

function ConvertTo-SysPilotVersionObject {
    param([string]$Text)
    $m = [regex]::Match([string]$Text, '\d+(\.\d+){1,3}')
    if (-not $m.Success) { return $null }
    $parts = @($m.Value.Split('.'))
    while ($parts.Count -lt 3) { $parts += '0' }
    try { return [version]($parts -join '.') } catch { return $null }
}

function Get-SysPilotLatestRelease {
    <# Fragt GitHub nach dem neuesten Release. Gibt es noch keins, wird version.txt im master gelesen. #>
    param([int]$TimeoutSec = 6)
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $ProgressPreference = 'SilentlyContinue'
    $headers = @{ 'User-Agent' = 'SysPilot-Updater'; 'Accept' = 'application/vnd.github+json' }
    $res = [pscustomobject]@{ Ok = $false; Version = $null; Url = $script:ReleasesUrl; DownloadUrl = $null; Error = '' }
    try {
        $r = Invoke-RestMethod "$($script:RepoApi)/releases/latest" -Headers $headers -TimeoutSec $TimeoutSec -ErrorAction Stop
        $asset = @($r.assets) | Where-Object { $_.name -like 'SysPilot-Setup-*.exe' } | Select-Object -First 1
        $res.Ok = $true
        $res.Version = [string]$r.tag_name
        if ($r.html_url) { $res.Url = [string]$r.html_url }
        if ($asset) { $res.DownloadUrl = [string]$asset.browser_download_url }
        return $res
    } catch { $res.Error = $_.Exception.Message }
    try {
        $t = Invoke-RestMethod $script:RepoVersion -Headers $headers -TimeoutSec $TimeoutSec -ErrorAction Stop
        $res.Ok = $true
        $res.Version = ([string]$t).Trim()
        $res.Error = ''
    } catch { $res.Error = ($res.Error + ' | ' + $_.Exception.Message).Trim(' |') }
    return $res
}

function Test-SysPilotUpdate {
    <# Vergleicht installierte und neueste Version. #>
    $cur = Get-SysPilotVersion
    $rel = Get-SysPilotLatestRelease
    $o = [pscustomobject]@{ Ok = $rel.Ok; Current = $cur; Latest = $rel.Version; Newer = $false; Url = $rel.Url; DownloadUrl = $rel.DownloadUrl; Error = $rel.Error }
    if ($rel.Ok) {
        $a = ConvertTo-SysPilotVersionObject $cur
        $b = ConvertTo-SysPilotVersionObject $rel.Version
        if ($a -and $b -and $b -gt $a) { $o.Newer = $true }
    }
    return $o
}

function Test-SysPilotUpdateAtStart {
    <# Soll beim Start nach Updates gesucht werden? (Standard: ja) #>
    try {
        $u = (Get-SysPilotConfig).PSObject.Properties['Update']
        if ($u -and $u.Value -and $u.Value.PSObject.Properties['CheckAtStart']) { return [bool]$u.Value.CheckAtStart }
    } catch { }
    return $true
}

function Install-SysPilotUpdate {
    <# Laedt den Installer von GitHub und startet ihn (Windows fragt nach Administrator-Rechten). #>
    param([Parameter(Mandatory)][string]$DownloadUrl, [string]$Version = '')
    if ($DownloadUrl -notmatch '^https://github\.com/Habermann76/SysPilot/') {
        throw "Unerwartete Download-Adresse: $DownloadUrl"
    }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $ProgressPreference = 'SilentlyContinue'
    $ver = ($Version -replace '[^\d\.]', '')
    $file = Join-Path $env:TEMP "SysPilot-Setup-$ver.exe"
    Invoke-WebRequest $DownloadUrl -OutFile $file -UseBasicParsing -Headers @{ 'User-Agent' = 'SysPilot-Updater' } -TimeoutSec 300 -ErrorAction Stop
    if (-not (Test-Path $file) -or (Get-Item $file).Length -lt 100000) { throw 'Download unvollstaendig.' }
    Write-SysPilotLog "Update: Installer $ver heruntergeladen, starte Installation"
    Start-Process $file -ArgumentList '/SILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Verb RunAs
}

Export-ModuleMember -Function Get-SysPilotVersion, Get-SysPilotLatestRelease, Test-SysPilotUpdate,
    Test-SysPilotUpdateAtStart, Install-SysPilotUpdate
