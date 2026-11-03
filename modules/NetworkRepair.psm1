# SysPilot - NetworkRepair: Internet/Netzwerk reparieren (wie Complete Internet Repair)
#Requires -Version 5.1

function Get-SysPilotNetworkRepairs {
    <# Alle 14 Reparaturen (aus Complete Internet Repair, Open Source) #>
    @(
        @{ Name = 'TCP/IP zuruecksetzen'; Desc = 'Setzt die Internet-Protokolle (IPv4/IPv6) zurueck'; Cmd = { & netsh interface ipv4 reset all; & netsh interface ipv6 reset all }; Reboot = $true },
        @{ Name = 'Winsock reparieren'; Desc = 'Setzt den Winsock-Katalog zurueck (bei Verbindungsproblemen)'; Cmd = { & netsh winsock reset catalog; & netsh winsock reset }; Reboot = $true },
        @{ Name = 'IP-Adresse erneuern'; Desc = 'Gibt die IP frei und fordert eine neue an (DHCP)'; Cmd = { & ipconfig /release; & ipconfig /renew }; Reboot = $false },
        @{ Name = 'DNS-Cache leeren'; Desc = 'Leert den DNS-Resolver-Cache (bei falschen/alten Eintraegen)'; Cmd = { & ipconfig /flushdns; & ipconfig /registerdns }; Reboot = $false },
        @{ Name = 'ARP-Cache leeren'; Desc = 'Leert den ARP-Cache (Address Resolution Protocol)'; Cmd = { & netsh interface ip delete arpcache }; Reboot = $false },
        @{ Name = 'Windows Update Verlauf loeschen'; Desc = 'Loescht den Update-Verlauf (bei Update-Problemen)'; Cmd = { Remove-Item "$env:ALLUSERSPROFILE\Microsoft\Network\Downloader\qmgr*.dat" -Force -ErrorAction SilentlyContinue }; Reboot = $false },
        @{ Name = 'Windows Update reparieren'; Desc = 'Repariert Windows Update (Dienste + DLLs)'; Cmd = { & net stop bits; & net stop wuauserv; & sc config wuauserv start= auto; & sc config bits start= auto; & net start wuauserv; & net start bits; & bitsadmin.exe /reset /allusers }; Reboot = $false },
        @{ Name = 'SSL / HTTPS / Kryptografie reparieren'; Desc = 'Repariert SSL/Zertifikate (bei HTTPS-Fehlern)'; Cmd = { & net stop CryptSvc; & sc config CryptSvc start= auto; & net start CryptSvc }; Reboot = $false },
        @{ Name = 'Proxy-Einstellungen zuruecksetzen'; Desc = 'Setzt den Proxy-Server zurueck (bei Proxy-Fehlern)'; Cmd = { & netsh winhttp reset proxy }; Reboot = $false },
        @{ Name = 'Windows-Firewall zuruecksetzen'; Desc = 'Setzt die Firewall auf Standard zurueck'; Cmd = { & netsh advfirewall reset }; Reboot = $false },
        @{ Name = 'Hosts-Datei wiederherstellen'; Desc = 'Stellt die Standard-hosts-Datei wieder her (Backup wird erstellt)'; Cmd = { $h = "$env:WINDIR\System32\drivers\etc\hosts"; Copy-Item $h "$h.bak" -Force -ErrorAction SilentlyContinue; Set-Content $h "# Copyright (c) 1993-2009 Microsoft Corp.`n#`n# This is a sample HOSTS file used by Microsoft TCP/IP for Windows." -Force }; Reboot = $false },
        @{ Name = 'WINS-Client-Registrierung erneuern'; Desc = 'Erneuert die WINS-Client-Registrierung (NetBIOS)'; Cmd = { & Nbtstat.exe -R; & Nbtstat.exe -RR }; Reboot = $false },
        @{ Name = 'Netzwerk-Computer sichtbar machen'; Desc = 'Startet den Function Discovery Resource Publication Dienst (Netzwerk-PCs im Explorer)'; Cmd = { & net stop FDResPub; & sc config FDResPub start= auto; & net start FDResPub }; Reboot = $false }
    )
}

function Show-SysPilotNetworkRepair {
    while ($true) {
        $repairs = Get-SysPilotNetworkRepairs
        $items = @()
        foreach ($r in $repairs) {
            $reboot = if ($r.Reboot) { '  [Neustart noetig]' } else { '' }
            $items += @{ Label = ("{0,-45} {1}{2}" -f $r.Name, $r.Desc, $reboot); Color = 'White'; Tag = $r }
        }
        $items += @{ Label = '--- ALLE Reparaturen ausfuehren ---'; Color = 'Red'; Tag = 'ALL' }
        $items += @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = $null }

        $sel = Show-SysPilotArrowMenu -Items $items -Title 'Netzwerk / Internet reparieren' -Footer 'Pfeiltasten, Enter = reparieren, Esc = zurueck'
        if ($null -eq $sel) { return }

        if ($sel -eq 'ALL') {
            if (Confirm-SysPilot "Wirklich ALLE $($repairs.Count) Reparaturen ausfuehren?") {
                if (-not (Assert-SysPilotAdmin)) { continue }
                $i = 0
                foreach ($r in $repairs) {
                    $i++
                    Write-SysPilotProgress -Activity 'Netzwerk reparieren' -Current $i -Total $repairs.Count -Status $r.Name
                    Write-Host "  [$i/$($repairs.Count)] $($r.Name) ..." -ForegroundColor Cyan
                    try { & $r.Cmd; Write-Host "    [OK]" -ForegroundColor Green } catch { Write-Host "    [!] $($_.Exception.Message)" -ForegroundColor Yellow }
                }
                Complete-SysPilotProgress
                Write-Host ""
                Write-Host "  Fertig. Einige Reparaturen brauchen einen Neustart." -ForegroundColor Yellow
                Write-SysPilotLog "Netzwerk: ALLE Reparaturen ausgefuehrt"
                Read-SysPilotChoice "Weiter mit Enter" | Out-Null
            }
            continue
        }

        $repair = $sel
        Write-Host ""
        Write-Host "  $($repair.Name)" -ForegroundColor Cyan
        Write-Host "  $($repair.Desc)" -ForegroundColor DarkGray
        if ($repair.Reboot) { Write-Host "  [!] Neustart danach noetig" -ForegroundColor Yellow }
        Write-Host ""
        if (Confirm-SysPilot "Jetzt ausfuehren?") {
            if (-not (Assert-SysPilotAdmin)) { continue }
            try {
                & $repair.Cmd
                Write-Host "  [OK] $($repair.Name) abgeschlossen." -ForegroundColor Green
                Write-SysPilotLog "Netzwerk-Reparatur: $($repair.Name)"
            } catch {
                Write-Host "  [!] Fehler: $($_.Exception.Message)" -ForegroundColor Red
            }
            Read-SysPilotChoice "Weiter mit Enter" | Out-Null
        }
    }
}

Export-ModuleMember -Function Get-SysPilotNetworkRepairs, Show-SysPilotNetworkRepair
