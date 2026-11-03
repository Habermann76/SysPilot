# SysPilot - NetworkAdapters: Netzwerkadapter identifizieren (was ist vgate0?)
#Requires -Version 5.1

function Get-SysPilotNetworkAdapters {
    <# Findet alle Netzwerkadapter und versucht, das zugehoerige Programm zu identifizieren #>
    $adapters = Get-NetAdapter -ErrorAction SilentlyContinue
    $rows = @()
    foreach ($a in $adapters) {
        $name = $a.Name
        $desc = $a.InterfaceDescription
        $driver = $a.DriverFileName
        $vendor = $a.DriverProvider

        # Bekannte virtuelle Adapter identifizieren
        $known = $null
        $knownList = @(
            @{ Match = 'vgate'; Program = 'OPPO Connect / vgate (Handy-Verbindung)'; Hint = 'OPPO/vgate Treiber - falls du kein OPPO-Handy hast: deinstallieren' },
            @{ Match = 'tap-windows.*openvpn|openvpn'; Program = 'OpenVPN TAP-Adapter'; Hint = 'OpenVPN - falls ungenutzt: deinstallieren' },
            @{ Match = 'tap-windows'; Program = 'TAP-Windows Adapter (VPN)'; Hint = 'Generischer VPN-TAP-Treiber (OpenVPN/andere) - falls ungenutzt: deinstallieren' },
            @{ Match = 'wireguard'; Program = 'WireGuard VPN'; Hint = 'WireGuard VPN - falls ungenutzt: deinstallieren' },
            @{ Match = 'vmware'; Program = 'VMware'; Hint = 'VMware virtuelle Netzwerkkarte' },
            @{ Match = 'virtualbox|vbox'; Program = 'VirtualBox'; Hint = 'VirtualBox virtuelle Netzwerkkarte' },
            @{ Match = 'hyper-v|vEthernet'; Program = 'Hyper-V / WSL2'; Hint = 'Windows Hyper-V / WSL2 / Docker' },
            @{ Match = 'bluetooth'; Program = 'Bluetooth'; Hint = 'Bluetooth-Netzwerk (PAN)' },
            @{ Match = 'tunnel|teredo|isatap|6to4'; Program = 'Windows Tunnel'; Hint = 'Windows IPv6-Tunnel (normal, kein Programm)' }
        )
        foreach ($k in $knownList) {
            if ($name -match $k.Match -or $desc -match $k.Match -or $driver -match $k.Match) {
                $known = $k
                break
            }
        }

        $rows += [PSCustomObject]@{
            Name = $name
            Beschreibung = $desc
            Status = $a.Status
            Typ = $a.MediaType
            Treiber = $driver
            Hersteller = $vendor
            Programm = if ($known) { $known.Program } else { '' }
            Hinweis = if ($known) { $known.Hint } else { '' }
            Unbekannt = ($null -eq $known -and $a.MediaType -ne 'Native 802.11' -and $desc -notmatch 'Realtek|Intel|Killer|MediaTek|Qualcomm')
        }
    }
    return $rows
}

function Show-SysPilotNetworkAdapters {
    while ($true) {
        $adapters = @(Get-SysPilotNetworkAdapters)
        $items = @()
        foreach ($a in $adapters) {
            $color = if ($a.Unbekannt) { 'Yellow' } else { 'White' }
            $prog = if ($a.Program) { "  -> $($a.Program)" } else { '' }
            $items += @{ Label = ("{0,-20} {1,-40} {2}{3}" -f $a.Name, $a.Beschreibung, $a.Status, $prog); Color = $color; Tag = $a }
        }
        $items += @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = $null }

        $sel = Show-SysPilotArrowMenu -Items $items -Title 'Netzwerkadapter identifizieren' -Footer 'Pfeiltasten, Enter = Details, Esc = zurueck'
        if ($null -eq $sel) { return }

        $adapter = $sel
        Write-SysPilotHeader $adapter.Name
        Write-Host "  Beschreibung: $($adapter.Beschreibung)" -ForegroundColor Cyan
        Write-Host "  Status:       $($adapter.Status)" -ForegroundColor Cyan
        Write-Host "  Treiber:      $($adapter.Treiber)" -ForegroundColor Cyan
        Write-Host "  Hersteller:   $($adapter.Hersteller)" -ForegroundColor Cyan
        Write-Host ""
        if ($adapter.Program) {
            Write-Host "  Gehoert zu:   $($adapter.Program)" -ForegroundColor Green
            Write-Host "  Hinweis:      $($adapter.Hinweis)" -ForegroundColor Yellow
            Write-Host ""
            if ($adapter.Hinweis -match 'deinstallieren') {
                if (Confirm-SysPilot "Zugehoeriges Programm deinstallieren?") {
                    $progName = ($adapter.Program -split ' / ')[0]
                    $app = Get-SysPilotInstalled | Where-Object { $_.DisplayName -like "*$progName*" } | Select-Object -First 1
                    if ($app) { Uninstall-SysPilotProgram -App $app }
                    else { Write-Host "  [!] Programm '$progName' nicht gefunden. Manuell: Einstellungen > Apps" -ForegroundColor Yellow }
                }
            }
        } elseif ($adapter.Unbekannt) {
            Write-Host "  [!] Unbekannter Adapter - kein bekanntes Programm zugeordnet." -ForegroundColor Yellow
            Write-Host "  Tipp: Suche nach '$($adapter.Treiber)' oder '$($adapter.Hersteller)' im Internet." -ForegroundColor DarkGray
            if (Confirm-SysPilot "Google-Suche oeffnen?") {
                Start-Process "https://www.google.com/search?q=$($adapter.Treiber)+treiber+was+ist+das"
            }
        } else {
            Write-Host "  Standard-Windows-Adapter (normal)." -ForegroundColor Green
        }
        Write-Host ""
        Read-SysPilotChoice "Weiter mit Enter" | Out-Null
    }
}

Export-ModuleMember -Function Get-SysPilotNetworkAdapters, Show-SysPilotNetworkAdapters
