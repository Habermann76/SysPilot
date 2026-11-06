# SysPilot - Advanced DNS Manager
# Analyse, DNS-Test, Anbieterwahl, Backup und Wiederherstellung pro Netzwerkadapter.
# Requires PowerShell 5.1

#Requires -Version 5.1

# Root Ordner
$script:SysPilotRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)

# ---------- Hilfsfunktionen ----------
function Get-SysPilotDnsCatalog {
    @(
        [PSCustomObject]@{ Key='cloudflare'; Name='Cloudflare'; Description='Schnell und datensparsam.'; IPv4=@('1.1.1.1','1.0.0.1'); IPv6=@('2606:4700:4700::1111','2606:4700:4700::1001') }
        [PSCustomObject]@{ Key='google'; Name='Google Public DNS'; Description='Sehr verbreitet und stabil.'; IPv4=@('8.8.8.8','8.8.4.4'); IPv6=@('2001:4860:4860::8888','2001:4860:4860::8844') }
        [PSCustomObject]@{ Key='quad9'; Name='Quad9'; Description='Sicherheitsorientiert, blockiert viele Schad-Domains.'; IPv4=@('9.9.9.9','149.112.112.112'); IPv6=@('2620:fe::fe','2620:fe::9') }
        [PSCustomObject]@{ Key='adguard'; Name='AdGuard DNS'; Description='Blockiert Werbung und viele Tracker.'; IPv4=@('94.140.14.14','94.140.15.15'); IPv6=@('2a10:50c0::ad1:ff','2a10:50c0::ad2:ff') }
        [PSCustomObject]@{ Key='mullvad'; Name='Mullvad DNS'; Description='Datenschutzorientiert, optionale Filterung.'; IPv4=@('194.242.2.2','194.242.2.3'); IPv6=@('2a07:e340::2','2a07:e340::3') }
    )
}

function Test-SysPilotVpnAdapter {
    param([string]$Name, [string]$Description)
    return (($Name + ' ' + $Description) -match '(?i)vpn|wireguard|openvpn|tap-|tunnel|fortinet|cisco anyconnect|tailscale|zerotier|hamachi|wintun|proton|mullvad|expressvpn')
}

function Get-SysPilotDnsInventory {
    param([switch]$ActiveOnly)
    $rows = @()
    $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'Disabled' -and (-not $ActiveOnly -or $_.Status -eq 'Up') })
    foreach ($adapter in $adapters) {
        $v4 = @((Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)
        $v6 = @((Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue).ServerAddresses)
        $dhcp = $false
        try { $dhcp = ((Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop).Dhcp -eq 'Enabled') } catch { }
        $rows += [PSCustomObject]@{
            Name = $adapter.Name; InterfaceIndex = $adapter.ifIndex
            Description = $adapter.InterfaceDescription; Status = $adapter.Status
            IPv4 = $v4; IPv6 = $v6; Dns = @($v4 + $v6)
            Dhcp = [bool]$dhcp; VPN = (Test-SysPilotVpnAdapter $adapter.Name $adapter.InterfaceDescription)
        }
    }
    return $rows
}

function Get-SysPilotDnsBackupPath { Join-Path $script:SysPilotRoot 'backup\dns' }
function Save-SysPilotDnsBackup {
    $dir = Get-SysPilotDnsBackupPath
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $file = Join-Path $dir ("dns-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Get-SysPilotDnsInventory | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $file -Encoding UTF8
    Write-Host "  [OK] DNS-Backup: $file" -ForegroundColor Green
    return $file
}

function Test-SysPilotDnsServer {
    param([Parameter(Mandatory)][string[]]$Servers)
    $results = @()
    foreach ($server in $Servers) {
        $ping = Test-Connection -ComputerName $server -Count 1 -Quiet -ErrorAction SilentlyContinue
        $resolve = $false
        try { Resolve-DnsName -Name 'www.microsoft.com' -Server $server -DnsOnly -ErrorAction Stop | Out-Null; $resolve = $true } catch { }
        $results += [PSCustomObject]@{ Server=$server; Ping=$ping; Resolve=$resolve; Status=if($resolve){'OK'}elseif($ping){'Ping OK, DNS fehlgeschlagen'}else{'nicht erreichbar'} }
    }
    return $results
}

function Set-SysPilotDnsProvider {
    param([Parameter(Mandatory)]$Adapter,[Parameter(Mandatory)]$Provider,[switch]$Confirmed)
    if ($Adapter.VPN -and -not $Confirmed -and -not (Confirm-SysPilot "Adapter '$($Adapter.Name)' ist wahrscheinlich ein VPN. DNS trotzdem ändern?")) { return $false }
    if (-not (Assert-SysPilotAdmin)) { return $false }
    $backup = Save-SysPilotDnsBackup
    try {
        Set-DnsClientServerAddress -InterfaceIndex $Adapter.InterfaceIndex -ServerAddresses $Provider.IPv4 -AddressFamily IPv4 -ErrorAction Stop
        if ($Provider.IPv6.Count) { Set-DnsClientServerAddress -InterfaceIndex $Adapter.InterfaceIndex -ServerAddresses $Provider.IPv6 -AddressFamily IPv6 -ErrorAction Stop }
        Clear-DnsClientCache -ErrorAction SilentlyContinue
        Write-Host "  [OK] DNS: $($Adapter.Name) auf $(@($Provider.IPv4)[0]) gesetzt. Backup: $backup" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "  [!] DNS konnte nicht gesetzt werden: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Restore-SysPilotDnsBackup {
    $files = @(Get-ChildItem (Get-SysPilotDnsBackupPath) -Filter 'dns-*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    if (-not $files) { Write-Host '  Kein DNS-Backup vorhanden.' -ForegroundColor Yellow; return }
    $file = $files | Select-Object -First 1
    if (-not (Confirm-SysPilot "Letztes DNS-Backup $($file.Name) wiederherstellen?")) { return }
    if (-not (Assert-SysPilotAdmin)) { return }
    foreach ($row in @(Get-Content $file.FullName -Raw | ConvertFrom-Json)) {
        try {
            if ($row.Dns -and $row.Dns.Count) {
                Set-DnsClientServerAddress -InterfaceIndex $row.InterfaceIndex -ServerAddresses @($row.Dns) -ErrorAction Stop
            } elseif ($row.Dhcp) {
                Set-DnsClientServerAddress -InterfaceIndex $row.InterfaceIndex -ResetServerAddresses -ErrorAction Stop
            }
        } catch { Write-Host "  [!] $($row.Name): $($_.Exception.Message)" -ForegroundColor Yellow }
    }
    Clear-DnsClientCache -ErrorAction SilentlyContinue
    Write-Host '  [OK] DNS-Backup wiederhergestellt.' -ForegroundColor Green
}

# ---------- Konsolen-UI ----------
function Show-SysPilotDnsManager {
    $rows = @(Get-SysPilotDnsInventory)
    $items = @(
        @{ Label='Status aller Netzwerkadapter anzeigen'; Color='Cyan'; Tag='status' }
        @{ Label='DNS testen (Ping + Namensauflösung)'; Color='White'; Tag='test' }
        @{ Label='DNS-Anbieter für Adapter setzen'; Color='Green'; Tag='set' }
        @{ Label='Custom DNS eintragen'; Color='Yellow'; Tag='custom' }
        @{ Label='Letztes DNS-Backup wiederherstellen'; Color='White'; Tag='restore' }
        @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
    )
    $choice = Show-SysPilotArrowMenu -Items $items -Title 'DNS-MANAGER' -Footer 'Erst testen, dann aendern; VPN-Adapter separat bestätigen'
    if ($null -eq $choice) { return }
    if ($choice -eq 'status') {
        foreach ($row in $rows) {
            $dnsText = if ($row.Dns.Count) { $row.Dns -join ', ' } else { 'Provider/DHCP' }
            Write-Host "  $($row.Name) [$($row.Status)] $($dnsText)" -ForegroundColor $(if($row.VPN){'Yellow'}else{'White'})
            if ($row.VPN) { Write-Host '    [!] VPN/virtueller Adapter - nicht ungefragt ändern.' -ForegroundColor Yellow }
        }
        Read-SysPilotChoice 'Weiter' | Out-Null; return
    }
    if ($choice -eq 'restore') { Restore-SysPilotDnsBackup; Read-SysPilotChoice 'Weiter' | Out-Null; return }
    if ($choice -eq 'test') {
        $input = Read-SysPilotChoice 'DNS-Server IPs (Komma getrennt; leer = Cloudflare)'
        $servers = if ($input) { @($input -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { @('1.1.1.1','1.0.0.1') }
        Test-SysPilotDnsServer -Servers $servers | Format-Table -AutoSize
        Read-SysPilotChoice 'Weiter' | Out-Null; return
    }
    $adapterItems = foreach ($row in @($rows | Where-Object Status -eq 'Up')) {
        @{ Label="$($row.Name) - $($row.Description)"; Color=if($row.VPN){'Yellow'}else{'White'}; Tag=$row }
    }
    $adapterItems += @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
    $adapter = Show-SysPilotArrowMenu -Items $adapterItems -Title 'Adapter auswaehlen'
    if ($null -eq $adapter) { return }
    $provider = $null
    if ($choice -eq 'custom') {
        $v4 = Read-SysPilotChoice 'Custom IPv4 DNS (Komma getrennt)'
        $v6 = Read-SysPilotChoice 'Custom IPv6 DNS (optional)'
        $provider = [PSCustomObject]@{ Name='Custom'; Description='Benutzerdefinierte DNS-Server'; IPv4=@($v4 -split ',' | % Trim | ? { $_ }); IPv6=@($v6 -split ',' | % Trim | ? { $_ }) }
    } else {
        $providerItems = foreach ($entry in @(Get-SysPilotDnsCatalog)) { @{ Label="$($entry.Name): $($entry.Description)"; Color='White'; Tag=$entry } }
        $providerItems += @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
        $provider = Show-SysPilotArrowMenu -Items $providerItems -Title 'DNS-Anbieter auswaehlen'
        if ($null -eq $provider) { return }
    }
    Test-SysPilotDnsServer -Servers @($provider.IPv4) | Format-Table -AutoSize
    if (Confirm-SysPilot "DNS auf '$($adapter.Name)' auf $($provider.Name) setzen?") { Set-SysPilotDnsProvider -Adapter $adapter -Provider $provider -Confirmed | Out-Null }
    Read-SysPilotChoice 'Weiter' | Out-Null
}

# ---------- GUI ----------
function Show-SysPilotDnsWindow {
    $window = New-Object System.Windows.Window
    $window.Title = 'SysPilot - DNS-Manager'; $window.Width = 780; $window.Height = 560
    $window.Owner = $win; $window.WindowStartupLocation = 'CenterOwner'
    $grid = New-Object System.Windows.Controls.Grid; $grid.Margin = '14'
    0..4 | ForEach-Object { $row = New-Object System.Windows.Controls.RowDefinition; $row.Height = if($_ -eq 3){'*'}else{'Auto'}; $grid.RowDefinitions.Add($row) }
    $title = New-Object System.Windows.Controls.TextBlock; $title.Text='DNS-Manager'; $title.FontSize=20; $title.FontWeight='Bold'; $title.Foreground='#FF4FC3F7'; [System.Windows.Controls.Grid]::SetRow($title,0); $grid.Children.Add($title)|Out-Null

    $info = New-Object System.Windows.Controls.TextBlock; $info.Text='Adapter auswählen, DNS-Anbieter testen und erst danach übernehmen. VPN-Adapter werden gewarnt.'; $info.Margin='0,4,0,8'; [System.Windows.Controls.Grid]::SetRow($info,1); $grid.Children.Add($info)|Out-Null

    $panel = New-Object System.Windows.Controls.StackPanel; $panel.Orientation='Horizontal'; [System.Windows.Controls.Grid]::SetRow($panel,2)
    $adapterBox=New-Object System.Windows.Controls.ComboBox; $adapterBox.Width=330; $adapterBox.Margin='0,0,8,0'; $panel.Children.Add($adapterBox)|Out-Null
    $providerBox=New-Object System.Windows.Controls.ComboBox; $providerBox.Width=330; $panel.Children.Add($providerBox)|Out-Null; $grid.Children.Add($panel)|Out-Null

    $status=New-Object System.Windows.Controls.TextBox; $status.IsReadOnly=$true; $status.AcceptsReturn=$true; $status.TextWrapping='Wrap'; $status.VerticalScrollBarVisibility='Auto'; [System.Windows.Controls.Grid]::SetRow($status,3); $grid.Children.Add($status)|Out-Null
    $buttons=New-Object System.Windows.Controls.StackPanel; $buttons.Orientation='Horizontal'; $buttons.HorizontalAlignment='Center'; [System.Windows.Controls.Grid]::SetRow($buttons,4)
    $test=New-Object System.Windows.Controls.Button; $test.Content='Testen'; $test.Margin='4'; $apply=New-Object System.Windows.Controls.Button; $apply.Content='Übernehmen'; $apply.Margin='4'; $refresh=New-Object System.Windows.Controls.Button; $refresh.Content='Aktualisieren'; $refresh.Margin='4'; $close=New-Object System.Windows.Controls.Button; $close.Content='Schließen'; $close.Margin='4'; foreach($b in @($test,$apply,$refresh,$close)){$buttons.Children.Add($b)|Out-Null}; $grid.Children.Add($buttons)|Out-Null

    $load = { $adapterBox.Items.Clear(); foreach($a in @(Get-SysPilotDnsInventory)){ $adapterBox.Items.Add($a)|Out-Null }; if($adapterBox.Items.Count){$adapterBox.SelectedIndex=0}; $providerBox.Items.Clear(); foreach($p in @(Get-SysPilotDnsCatalog)){$providerBox.Items.Add($p)|Out-Null}; if($providerBox.Items.Count){$providerBox.SelectedIndex=0} }
    $refresh.Add_Click({ & $load; $status.Text='Adapter- und Anbieterlisten aktualisiert.' })
    $test.Add_Click({
        if(-not $adapterBox.SelectedItem -or -not $providerBox.SelectedItem){$status.Text='Bitte Adapter und Anbieter auswählen.';return}
        $p=$providerBox.SelectedItem; $results=@(Test-SysPilotDnsServer -Servers $p.IPv4); $status.Text=($p.Name + ': IPv4 ' + ($p.IPv4 -join ', ') + "`n" + ($results|Out-String))
    })
    $apply.Add_Click({
        if(-not $adapterBox.SelectedItem -or -not $providerBox.SelectedItem){$status.Text='Bitte Adapter und Anbieter auswählen.';return}
        $a=$adapterBox.SelectedItem;$p=$providerBox.SelectedItem
        $message="DNS auf '$($a.Name)' auf $($p.Name) setzen?`nIPv4: $($p.IPv4 -join ', ')`nIPv6: $($p.IPv6 -join ', ')"
        if($a.VPN){$message+="`n`nWARNUNG: Das ist wahrscheinlich ein VPN-/Tunneladapter.`n`nDieser Vorgang erfordert Admin-Rechte. Weiter mit Administrator-Rechten?"}
        if([System.Windows.MessageBox]::Show($message,'DNS ändern','YesNo','Warning') -eq 'Yes'){
            if($a.VPN){ Restart-SysPilotElevated }
            $ok=Set-SysPilotDnsProvider -Adapter $a -Provider $p -Confirmed
            $status.Text=if($ok){'DNS erfolgreich übernommen. Backup wurde erstellt.'}else{'DNS konnte nicht übernommen werden.'}
        }
    })
    $close.Add_Click({$window.Close()}); $window.Content=$grid; & $load; $window.ShowDialog()|Out-Null
}

Export-ModuleMember -Function Get-SysPilotDnsCatalog,Get-SysPilotDnsInventory,Save-SysPilotDnsBackup,Test-SysPilotDnsServer,Set-SysPilotDnsProvider,Restore-SysPilotDnsBackup,Show-SysPilotDnsManager,Show-SysPilotDnsWindow
