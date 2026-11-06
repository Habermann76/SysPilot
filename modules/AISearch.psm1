# SysPilot - AISearch Helper: Open browser with AI/Websuche
# Kein API-Provider benötigt - nutzt den Browser des Users.

#Requires -Version 5.1

function Get-SysPilotAISearchBase {
    <#
    .SYNOPSIS
    Liefert Such-Basis-URLs fuer KI-basierte Suchanfragen.
    .EXAMPLE
        $base = Get-SysPilotAISearchBase
    #>
    return @(
        @{ Name='DuckDuckGo'; Url='https://duckduckgo.com/?q=' };
        @{ Name='SearxNG'; Url='https://searx.run/?q=' };
        @{ Name='Bing'; Url='https://www.bing.com/search?q=' };
        @{ Name='Google'; Url='https://www.google.com/search?q=' }
    )
}

function Get-SysPilotAISearchBaseUrl {
    param([string]$ProviderName='DuckDuckGo')
    $bases = Get-SysPilotAISearchBase
    $found = @($bases | Where-Object { $_.Name -eq $ProviderName })
    if ($found.Count -gt 0) {
        return $found[0].Url
    }
    return 'https://duckduckgo.com/?q='
}

function Invoke-SysPilotAISearch {
    <#
    .SYNOPSIS
    Öffnet den Browser mit einer KI/Websuche für ein HowTo oder Thema.
    .DESCRIPTION
    Öffnet den Standard-Browser des Users mit einer Suchanfrage.
    Unterstützt: DuckDuckGo, SearxNG, Bing, Google.
    .EXAMPLE
        Invoke-SysPilotAISearch -Query 'Windows PowerShell DNS Server setzen'
        Invoke-SysPilotAISearch -Query 'SysPilot Toolbox Erklärung' -Provider Goog
    .EXAMPLE
        # Wie bearbeite ich einen doppelten Shortcut in Windows 10?
        Invoke-SysPilotAISearch -Query 'doppelte Shortcut-Verknüpfung in Windows 10 auflösen'
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$Query,
        [string]$Provider='DuckDuckGo'
    )
    if ([string]::IsNullOrWhiteSpace($Query)) {
        Write-Host '[!] Query ist leer' -ForegroundColor Yellow
        return
    }
    # Query säubern: Leerzeichen durch + ersetzen
    $safeQuery = ($Query.Trim() -replace '\s+','+')
    $url = Get-SysPilotAISearchBaseUrl -ProviderName $Provider
    $fullUrl = $url + [System.Web.HttpUtility]::UrlEncode($Query)
    Write-Host "  [i] Öffne Browser: $fullUrl" -ForegroundColor DarkGray
    try {
        Start-Process -FilePath $fullUrl -ErrorAction Stop
    } catch {
        Write-Host "  [!] Konnte Browser nicht öffnen: $_" -ForegroundColor Red
        Write-Host "      URL: $fullUrl" -ForegroundColor DarkGray
    }
}

function Get-SysPilotHowToLinks {
    <#
    .SYNOPSIS
    Liefert Standard-HowTo-Links für häufige SysPilot-Handwerksaufgaben.
    .EXAMPLE
        $links = Get-SysPilotHowToLinks -Topic 'Dns'
        $links | ForEach-Object { Write-Host $_.Title ": " $_.Url }
    #>
    param(
        [Parameter(Mandatory=$false)]
        [string]$Topic='all'
    )

    $links = @(
        # DNS & Netzwerk
        @{
            Topic='dns'; Title='Windows DNS Server manuell setzen (Netzwerkadapter)'
            Url='https://learn.microsoft.com/en-us/windows-server/networking/technologies/dns/dns-top'
            Desc='Schritt-für-Schritt: DNS auf Netzwerkadapter setzen'
        },
        @{
            Topic='dns'; Title='DNS Cache leeren (ipconfig /flushdns)'
            Url='https://learn.microsoft.com/en-us/windows-server/administration/windows-server-core/using-dns-flushdns'
            Desc='Der Windows-DNS-Cache sofort leeren'
        },
        @{
            Topic='dns'; Title='DNS-Anbieter wechseln (Cloudflare, Google, Quad9)'
            Url='https://www.cloudflare.com/de-de/learning/dns/dns-over-https/overview/'
            Desc='Anbieter wechseln: Cloudflare, Google, Quad9, AdGuard, Mullvad'
        },
        @{
            Topic='dns'; Title='VPN x DNS: Wie schütze ich vor Datenleakage?'
            Url='https://support.apple.com/de-de/guide/mac-help/mchleaba2d38/14.0/mac/14.0'
            Desc='VPN nutzt DNS-Leckage vermeiden'
        },
        # Shortcut / Datei-Probleme
        @{
            Topic='shortcut'; Title='Doppelte Verknüpfung auflösen (Windows)'
            Url='https://support.microsoft.com/de-de/windows/was-sind-verknuepfungen-3798534e-056a-4816-8643-8d3cc8d4a0ef'
            Desc='Doppelte oder defekte Shortcuts finden und entfernen'
        },
        @{
            Topic='shortcut'; Title='Windows-Shortcut auf anderes Ziel ändern'
            Url='https://support.microsoft.com/de-at/windows/was-sind-verknuepfungen-3798534e-056a-4816-8643-8d3cc8d4a0ef'
            Desc='Shortcut-Ziel ändern oder deaktivieren'
        },
        # System-Optimierung
        @{
            Topic='optimize'; Title='Windows 10/11 Performance optimieren (ohne Registry-Wirrnis)'
            Url='https://learn.microsoft.com/en-us/windows/client-management/manage/optimize'
            Desc='Sichere Optimierung von Windows (Energieplan, Start, Dienste)'
        },
        @{
            Topic='optimize'; Title='RAM-Management unter Windows (Smart Boost)'
            Url='https://learn.microsoft.com/en-us/windows/clients/manage/optimize-memory'
            Desc='Windows-RAM-Optimierung und Prozeß-Prioritäten'
        },
        # Sicherheit
        @{
            Topic='security'; Title='Windows Defender Firewall konfigurieren'
            Url='https://learn.microsoft.com/en-us/windows/security/operating-system-security/firewalls/manage-firewall-rules'
            Desc='Windows Firewall Regeln erstellen und testen'
        },
        @{
            Topic='security'; Title='Windows Defender SmartScreen deaktivieren/enable'
            Url='https://support.microsoft.com/de-de/windows/windows-defender-smartscreen-so-beheben-sie-probleme-2c9f5b3a-4e56-4a32-9b8e-7a2a5b5b5b5b'
            Desc='SmartScreen für Downloads und Apps verwalten'
        },
        # Netzwerk-Reparatur
        @{
            Topic='netrepair'; Title='Windows Netzwerk reparieren (NETREPAIR)'
            Url='https://learn.microsoft.com/en-us/troubleshoot/windows-client/networking/network-repair-commands'
            Desc='TCP/IP, Winsock, DNS-Cache, Proxy Reparaturen'
        },
        @{
            Topic='netrepair'; Title='Netzwerkadapter identifizieren (Hersteller, Treiber)'
            Url='https://learn.microsoft.com/en-us/windows-hardware/drivers/download-the-drivers'
            Desc='Netzwerkkarte erkennen und Treiber installieren'
        }
    )

    if ($Topic -eq 'all') {
        return $links
    }
    return @($links | Where-Object { $_.Topic -eq $Topic })
}

function Get-SysPilotExamples {
    <#
    .SYNOPSIS
    Bereitgestellte Beispielabfragen für den User (tabelle-ähnlich).
    .EXAMPLE
        Get-SysPilotExamples | Format-Table -AutoSize
    #>
    return @(
        @{ Category='Dns'; Question='Wie setze ich DNS auf meinen Netzwerk-Adapter?'; Url='https://learn.microsoft.com/en-us/windows-server/networking/technologies/dns/dns-top' }
        @{ Category='Dns'; Question='Wie behebe ich einen doppelten Shortcut?'; Url='https://support.microsoft.com/de-at/windows/was-sind-verknuepfungen-3798534e-056a-4816-8643-8d3cc8d4a0ef' }
        @{ Category='Dns'; Question='Wie behebe ich einen defekten DNS-Server?'; Url='https://learn.microsoft.com/en-us/windows-server/networking/technologies/dns/dns-top' }
        @{ Category='Optimize'; Question='Wie befreie ich RAM unter Windows 11?'; Url='https://learn.microsoft.com/en-us/windows/clients/manage/optimize-memory' }
        @{ Category='Optimize'; Question='Wie deaktiviere ich Startprogramme?'; Url='https://support.microsoft.com/de-at/windows/was-sind-autostart-programme-08c02afc-8dfb-4026-9544-4d1d5b2c2c2c' }
        @{ Category='Security'; Question='Wie richte ich Windows Defender Firewall ein?'; Url='https://learn.microsoft.com/en-us/windows/security/operating-system-security/firewalls/manage-firewall-rules' }
        @{ Category='Netrepair'; Question='Wie repariere ich das TCP/IP-Stack?'; Url='https://learn.microsoft.com/en-us/troubleshoot/windows-client/networking/network-repair-commands' }
        @{ Category='Netrepair'; Question='Wie identifiziere ich virtuelle Adapter?'; Url='https://learn.microsoft.com/en-us/windows-hardware/drivers/download-the-drivers' }
        @{ Category='Dns'; Question='Wie teste ich die DNS-Lösung?' ; Url='https://learn.microsoft.com/en-us/windows-server/networking/technologies/dns/dns-top' }
        @{ Category='Dns'; Question='Wie behebe ich DNS-Leakage?'; Url='https://support.apple.com/de-de/guide/mac-help/mchleaba2d38/14.0/mac/14.0' }
        @{ Category='Optimize'; Question='Wie optimiere ich die CPU-Priorität?'; Url='https://learn.microsoft.com/en-us/windows/client-management/manage/optimize' }
        @{ Category='Security'; Question='Wie pflege ich Windows Defender?'; Url='https://learn.microsoft.com/en-us/windows/security/operating-system-security/firewalls/manage-firewall-rules' }
    )
}

Export-ModuleMember -Function Get-SysPilotAISearchBaseUrl, Invoke-SysPilotAISearch, Get-SysPilotHowToLinks, Get-SysPilotExamples
