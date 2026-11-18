# SysPilot - DnsManager: Advanced DNS Manager (neu entworfen, elegant)
# DNS-Adapter verwalten, Provider testen, DNS setzen, Cache prüfen, Reverse-Lookup
# Inspiriert von DNSHop.App.exe - aber als eigenständige, clevere Neuentwicklung
#Requires -Version 5.1

$script:SysPilotRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$script:DnsCacheFile = Join-Path $script:SysPilotRoot 'logs\dns-history.json'
$script:DnsConfigFile = Join-Path $script:SysPilotRoot 'logs\dns-config.json'

# ---------- DNS Provider Definitionen (statt harter Kopie: erweiterbar, elegant) ----------
$script:DnsProviders = [ordered]@{
    'Google'   = @{ Name = 'Google DNS';         Ips = @('8.8.8.8', '8.8.4.4');   Farbe = '#4285F4'; Beschreibung = 'Schnell, weltweit, zuverlässig' }
    'Cloudflare' = @{ Name = 'Cloudflare DNS';   Ips = @('1.1.1.1', '1.0.0.1');   Farbe = '#F38020'; Beschreibung = 'Datenschutz-freundlich, sehr schnell' }
    'Quad9'    = @{ Name = 'Quad9 DNS';          Ips = @('9.9.9.9', '149.112.112.112'); Farbe = '#1A73E8'; Beschreibung = 'Sicherheit mit Malware-Blocking' }
    'OpenDNS'  = @{ Name = 'OpenDNS';            Ips = @('208.67.222.222', '208.67.220.220'); Farbe = '#FE4A49'; Beschreibung = 'Familienfilter optional' }
    'AdGuard'  = @{ Name = 'AdGuard DNS';        Ips = @('94.140.14.14', '94.140.15.15'); Farbe = '#18A0FB'; Beschreibung = 'Werbeblocking auf DNS-Ebene' }
    'Local'    = @{ Name = 'Lokaler DNS-Server'; Ips = @();                            Farbe = '#666666'; Beschreibung = 'Eigene Server eintragen' }
}

# ---------- History laden/speichern ----------
function Get-SysPilotDnsHistory {
    if (-not (Test-Path $script:DnsCacheFile)) { return @() }
    try {
        $raw = Get-Content $script:DnsCacheFile -Raw -ErrorAction Stop
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $obj) { return @() }
        return @($obj)
    } catch { return @() }
}

function Save-SysPilotDnsHistory {
    param([array]$Entries)
    $dir = Split-Path $script:DnsCacheFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = $Entries | ConvertTo-Json -Depth 4
    Set-Content -Path $script:DnsCacheFile -Value $json -Encoding UTF8 -ErrorAction SilentlyContinue
}

function Add-SysPilotDnsHistoryEntry {
    param([string]$Domain, [string]$RecordType, [string]$Result, [string]$Provider, [double]$LatencyMs)
    $entries = @(Get-SysPilotDnsHistory)
    $entry = [PSCustomObject]@{
        Zeit = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Domain = $Domain
        RecordType = $RecordType
        Result = $Result
        Provider = $Provider
        LatencyMs = [math]::Round($LatencyMs, 1)
    }
    $entries = @($entry) + $entries
    if ($entries.Count -gt 100) { $entries = $entries[0..99] }
    Save-SysPilotDnsHistory -Entries $entries
}

# ---------- DNS-Adapter ermitteln ----------
function Get-SysPilotDnsAdapters {
    <# Gibt alle Netzwerkadapter mit DNS-Einstellungen zurück #>
    $adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -or $_.Status -eq 'Disconnected' }
    $rows = @()
    foreach ($a in $adapters) {
        $ifIndex = $a.ifIndex
        $dns = Get-DnsClientServerAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $dnsServers = @($dns | Where-Object { $_.ServerAddresses -ne $null } | ForEach-Object { $_.ServerAddresses }) -join ', '
        if (-not $dnsServers) { $dnsServers = 'Automatisch (DHCP)' }

        $rows += [PSCustomObject]@{
            Name = $a.Name
            Beschreibung = $a.InterfaceDescription
            Status = $a.Status
            ifIndex = $ifIndex
            Mac = $a.MacAddress
            DnsServers = $dnsServers
            Dhcp = if ($a.NdisMedium -eq 9) { 'Ja' } else { 'Unbekannt' }
        }
    }
    return $rows
}

# ---------- DNS-Provider testen (Latenz) ----------
function Test-SysPilotDnsProvider {
    param([string]$ProviderName, [string]$TestDomain = 'google.com')
    if (-not $script:DnsProviders.Contains($ProviderName)) {
        return [PSCustomObject]@{ Erfolg = $false; Fehler = 'Unbekannter Provider'; LatenzMs = $null }
    }
    $provider = $script:DnsProviders[$ProviderName]
    $ips = @($provider.Ips)
    if ($ips.Count -eq 0) {
        return [PSCustomObject]@{ Erfolg = $false; Fehler = 'Keine IPs konfiguriert'; LatenzMs = $null }
    }

    $results = @()
    $start = [diagnostics.stopwatch]::StartNew()
    foreach ($ip in $ips) {
        $ipStart = [diagnostics.stopwatch]::StartNew()
        $ok = $false
        try {
            # nslookup mit spezifischem Server, Timeout 3 Sekunden
            $ns = nslookup $TestDomain $ip 2>$null
            if ($LASTEXITCODE -eq 0 -and $ns) { $ok = $true }
        } catch { }
        $ipStart.Stop()
        $results += [PSCustomObject]@{ Ip = $ip; Erfolg = $ok; LatenzMs = [math]::Round($ipStart.Elapsed.TotalMilliseconds, 1) }
    }
    $start.Stop()

    $erfolgreich = @($results | Where-Object { $_.Erfolg })
    $bestLatenz = if ($erfolgreich.Count -gt 0) { ($erfolgreich | Measure-Object LatenzMs -Minimum).Minimum } else { $null }

    return [PSCustomObject]@{
        Erfolg = ($erfolgreich.Count -gt 0)
        Provider = $ProviderName
        LatenzMs = $bestLatenz
        Ergebnisse = $results
        GesamtdauerMs = [math]::Round($start.Elapsed.TotalMilliseconds, 1)
    }
}

# ---------- DNS-Server auf Adapter setzen ----------
function Set-SysPilotDnsServers {
    param([int]$InterfaceIndex, [string[]]$ServerAddresses)
    if (-not (Test-SysPilotAdmin)) {
        Write-Host '  [!] DNS-Änderung benötigt Administrator-Rechte.' -ForegroundColor Yellow
        return $false
    }
    try {
        Set-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -ServerAddresses ($ServerAddresses) -ErrorAction Stop
        Write-SysPilotLog "DNS-Server auf Interface $InterfaceIndex gesetzt: $($ServerAddresses -join ', ')"
        return $true
    } catch {
        Write-Host "  [!] Fehler beim Setzen der DNS-Server: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# ---------- DNS auf DHCP (automatisch) zurücksetzen ----------
function Reset-SysPilotDnsToDhcp {
    param([int]$InterfaceIndex)
    if (-not (Test-SysPilotAdmin)) {
        Write-Host '  [!] DNS-Reset benötigt Administrator-Rechte.' -ForegroundColor Yellow
        return $false
    }
    try {
        Set-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -ResetServerAddresses -ErrorAction Stop
        Write-SysPilotLog "DNS auf Interface $InterfaceIndex auf DHCP zurückgesetzt"
        return $true
    } catch {
        Write-Host "  [!] Fehler beim DNS-Reset: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# ---------- DNS-Cache leeren ----------
function Clear-SysPilotDnsCache {
    <# Leert den Windows DNS-Resolver-Cache #>
    if (-not (Test-SysPilotAdmin)) {
        Write-Host '  [!] DNS-Cache-Leerung benötigt Administrator-Rechte.' -ForegroundColor Yellow
        return $false
    }
    try {
        & ipconfig /flushdns | Out-Null
        Write-SysPilotLog 'DNS-Cache geleert (ipconfig /flushdns)'
        return $true
    } catch {
        Write-Host "  [!] Fehler beim Leeren des DNS-Cache: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# ---------- DNS-Cache anzeigen ----------
function Show-SysPilotDnsCache {
    <# Zeigt den aktuellen DNS-Resolver-Cache #>
    $cache = Get-DnsClientCache -ErrorAction SilentlyContinue
    if (-not $cache) {
        Write-Host '  Keine DNS-Cache-Einträge gefunden.' -ForegroundColor DarkGray
        return
    }
    Write-Host "  DNS-Cache-Einträge: $($cache.Count)" -ForegroundColor Cyan
    Write-Host ''
    $cache | Select-Object -First 30 | ForEach-Object {
        Write-Host "    $($_.Name)  ->  $($_.RecordData)  ($($_.EntryType), TTL: $($_.RemainingTTL)s)" -ForegroundColor DarkGray
    }
    if ($cache.Count -gt 30) {
        Write-Host "    ... und $($cache.Count - 30) weitere" -ForegroundColor DarkGray
    }
}

# ---------- DNS-Lookup (Forward) ----------
function Invoke-SysPilotDnsLookup {
    param([string]$Domain, [string[]]$DnsServers, [string]$RecordType = 'A')
    $serverArg = if ($DnsServers -and $DnsServers.Count -gt 0) { $DnsServers[0] } else { $null }
    $start = [diagnostics.stopwatch]::StartNew()
    $output = & nslookup -type=$RecordType $Domain $serverArg 2>&1
    $start.Stop()
    $latency = [math]::Round($start.Elapsed.TotalMilliseconds, 1)
    $success = $LASTEXITCODE -eq 0

    Add-SysPilotDnsHistoryEntry -Domain $Domain -RecordType $RecordType -Result $(if ($success) { 'OK' } else { 'FEHLER' }) -Provider $(if ($serverArg) { $serverArg } else { 'System' }) -LatencyMs $latency

    return [PSCustomObject]@{
        Erfolg = $success
        Domain = $Domain
        RecordType = $RecordType
        Server = $serverArg
        Output = $output
        LatenzMs = $latency
    }
}

# ---------- Reverse DNS (PTR) ----------
function Invoke-SysPilotReverseDns {
    param([string]$IpAddress, [string[]]$DnsServers)
    $serverArg = if ($DnsServers -and $DnsServers.Count -gt 0) { $DnsServers[0] } else { $null }
    $start = [diagnostics.stopwatch]::StartNew()
    $output = & nslookup $IpAddress $serverArg 2>&1
    $start.Stop()
    $latency = [math]::Round($start.Elapsed.TotalMilliseconds, 1)
    $success = $LASTEXITCODE -eq 0

    return [PSCustomObject]@{
        Erfolg = $success
        IpAddress = $IpAddress
        Server = $serverArg
        Output = $output
        LatenzMs = $latency
    }
}

# ---------- Alle Provider testen ----------
function Test-SysPilotAllDnsProviders {
    param([string]$TestDomain = 'google.com')
    $results = @()
    foreach ($key in $script:DnsProviders.Keys) {
        if ($key -eq 'Local') { continue }
        $r = Test-SysPilotDnsProvider -ProviderName $key -TestDomain $TestDomain
        $results += $r
    }
    return $results | Sort-Object LatenzMs
}

# ---------- Dns Config ----------
function Get-SysPilotDnsConfig {
    if (-not (Test-Path $script:DnsConfigFile)) { return @{ CustomServers = @(); Favorites = @() } }
    try {
        $raw = Get-Content $script:DnsConfigFile -Raw -ErrorAction Stop
        return $raw | ConvertFrom-Json -ErrorAction Stop
    } catch { return @{ CustomServers = @(); Favorites = @() } }
}

function Save-SysPilotDnsConfig {
    param($Config)
    $dir = Split-Path $script:DnsConfigFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = $Config | ConvertTo-Json -Depth 4
    Set-Content -Path $script:DnsConfigFile -Value $json -Encoding UTF8 -ErrorAction SilentlyContinue
}

Export-ModuleMember -Function Get-SysPilotDnsAdapters, Test-SysPilotDnsProvider, Set-SysPilotDnsServers, Reset-SysPilotDnsToDhcp, `
    Clear-SysPilotDnsCache, Show-SysPilotDnsCache, Invoke-SysPilotDnsLookup, Invoke-SysPilotReverseDns, `
    Test-SysPilotAllDnsProviders, Get-SysPilotDnsHistory, Get-SysPilotDnsConfig, Save-SysPilotDnsConfig, `
    Add-SysPilotDnsHistoryEntry