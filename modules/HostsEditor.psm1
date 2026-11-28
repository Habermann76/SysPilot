# SysPilot - HostsEditor: HOSTS-Datei anzeigen, bearbeiten, sperren
# (Nachbau der nuetzlichen Optimizer-Funktionen: Hosts-Editor,
#  Eintraege hinzufuegen/entfernen, alle loeschen, Datei sperren,
#  DNS-Cache danach leeren). Alles mit Backup vor Aenderungen.
#Requires -Version 5.1

$script:HostsPath = "$env:WINDIR\System32\drivers\etc\hosts"

function Get-SysPilotHostsEntries {
    <# Liest die HOSTS-Datei und liefert aktive Eintraege
       (IP + Hostname), ohne Kommentare und Leerzeilen. #>
    $entries = @()
    if (-not (Test-Path $script:HostsPath)) { return $entries }
    foreach ($line in (Get-Content $script:HostsPath -ErrorAction SilentlyContinue)) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        $parts = $t -split '\s+'
        if ($parts.Count -ge 2) {
            $entries += [PSCustomObject]@{
                IP      = $parts[0]
                Host    = ($parts[1..($parts.Count-1)] -join ' ')
                Line    = $t
            }
        }
    }
    $entries
}

function Backup-SysPilotHostsFile {
    <# Kopiert die HOSTS-Datei nach SysPilot-Backups. #>
    if (-not (Test-Path $script:HostsPath)) { return $null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dest = Join-Path (Get-SysPilotBackupDir) "hosts_$stamp.bak"
    try {
        Copy-Item $script:HostsPath $dest -Force
        return $dest
    } catch { return $null }
}

function Set-SysPilotHostsEntry {
    <# Fuegt einen HOSTS-Eintrag hinzu oder entfernt Zeilen.
       -Action Add:    -IP + -Host erforderlich
       -Action Remove: -Match (Hostname-Substring) entfernt passende Zeilen
       -Action Clear:  entfernt ALLE aktiven Eintraege (Kommentare bleiben)
       Erstellt vorher ein Backup. Benoetigt Admin. #>
    param(
        [Parameter(Mandatory)][ValidateSet('Add','Remove','Clear')][string]$Action,
        [string]$IP,
        [string]$Host,
        [string]$Match
    )
    if (-not (Assert-SysPilotAdmin)) { return }

    $bak = Backup-SysPilotHostsFile
    if ($bak) { Write-Host "  Backup: $bak" -ForegroundColor DarkGray }

    $lines = @(Get-Content $script:HostsPath -ErrorAction SilentlyContinue)
    $out = New-Object System.Collections.Generic.List[string]

    switch ($Action) {
        'Add' {
            if (-not $IP -or -not $Host) { Write-Host '  [!] IP und Hostname erforderlich.' -ForegroundColor Red; return }
            if ($IP -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { Write-Host "  [!] Ungueltige IP: $IP" -ForegroundColor Red; return }
            # Doppelte Zeile vermeiden
            $exists = $lines | Where-Object { $_ -match "^\s*$([regex]::Escape($IP))\s+.*\b$([regex]::Escape($Host))\b" }
            if ($exists) { Write-Host "  Eintrag existiert bereits." -ForegroundColor Yellow; return }
            $out.AddRange([string[]]$lines)
            $out.Add("$IP`t$Host")
        }
        'Remove' {
            if (-not $Match) { Write-Host '  [!] Suchbegriff erforderlich.' -ForegroundColor Red; return }
            $removed = 0
            foreach ($l in $lines) {
                $t = $l.Trim()
                if ($t -and -not $t.StartsWith('#') -and $t -match [regex]::Escape($Match)) { $removed++; continue }
                $out.Add($l)
            }
            if ($removed -eq 0) { Write-Host "  Kein Eintrag passt auf '$Match'." -ForegroundColor Yellow; return }
            Write-Host "  $removed Eintrag/Eintraege entfernt." -ForegroundColor Green
        }
        'Clear' {
            foreach ($l in $lines) {
                $t = $l.Trim()
                if (-not $t -or $t.StartsWith('#')) { $out.Add($l) }
            }
            Write-Host '  Alle aktiven HOSTS-Eintraege entfernt (Kommentare bleiben). Backup wurde erstellt.' -ForegroundColor Green
        }
    }

    try {
        # Unicode-sicher schreiben, CRLF
        $content = ($out -join "`r`n") + "`r`n"
        [IO.File]::WriteAllText($script:HostsPath, $content, [Text.Encoding]::ASCII)
        Write-SysPilotLog "HOSTS geaendert ($Action)"
    } catch {
        Write-Host "  [!] Schreiben fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Set-SysPilotHostsLock {
    <# Sperrt (schreibgeschuetzt) oder entsperrt die HOSTS-Datei.
       + Gesperrt = -ReadOnly. #>
    param([Parameter(Mandatory)][bool]$Lock)
    if (-not (Assert-SysPilotAdmin)) { return }
    $bak = Backup-SysPilotHostsFile
    try {
        $item = Get-Item $script:HostsPath -Force
        if ($Lock) {
            $item.Attributes = $item.Attributes -bor [IO.FileAttributes]::ReadOnly
            Write-Host '  [OK] HOSTS-Datei gesperrt (schreibgeschuetzt).' -ForegroundColor Green
            Write-Host '      Entsperren: Menuepunkt erneut waehlen oder attrib -r' -ForegroundColor DarkGray
        } else {
            $item.Attributes = $item.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly)
            Write-Host '  [OK] HOSTS-Datei entsperrt.' -ForegroundColor Green
        }
        Write-SysPilotLog "HOSTS-Lock $(if ($Lock) {'an'} else {'aus'})"
    } catch {
        Write-Host "  [!] Fehler: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Show-SysPilotHostsEditor {
    <# Pfeiltasten-Menue zum Bearbeiten der HOSTS-Datei. #>
    while ($true) {
        $entries = @(Get-SysPilotHostsEntries)
        $locked = (Get-Item $script:HostsPath -Force -ErrorAction SilentlyContinue).IsReadOnly
        $state = if ($locked) { 'GESPERRT' } else { 'schreibbar' }
        Write-Host ''
        Write-Host "  HOSTS-Datei ($state): $script:HostsPath" -ForegroundColor Cyan
        if ($entries.Count -eq 0) {
            Write-Host '  Keine aktiven Eintraege.' -ForegroundColor DarkGray
        } else {
            foreach ($e in $entries) {
                Write-Host ("    {0,-16} {1}" -f $e.IP, $e.Host) -ForegroundColor White
            }
        }
        Write-Host ''

        $items = @(
            @{ Label = 'Eintrag hinzufuegen (IP + Hostname)'; Color = 'White';    Tag = 'add' }
            @{ Label = 'Eintrag entfernen (nach Hostnamen)';  Color = 'White';    Tag = 'remove' }
            @{ Label = 'ALLE Eintraege entfernen';             Color = 'Yellow';   Tag = 'clear' }
            @{ Label = "HOSTS-Datei $(if ($locked) {'entsperren'} else {'sperren'})"; Color = 'White'; Tag = 'lock' }
            @{ Label = 'Inhalt komplett anzeigen (mit Kommentaren)'; Color = 'DarkGray'; Tag = 'show' }
            @{ Label = 'DNS-Cache leeren (flushdns)';          Color = 'DarkGray'; Tag = 'flush' }
            @{ Label = 'Zurueck';                              Color = 'DarkGray'; Tag = $null }
        )
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'Hosts-Editor' -Footer 'Pfeiltasten, Enter = ausfuehren, Esc = zurueck'
        if ($null -eq $sel) { return }

        switch ($sel) {
            'add' {
                $ip = Read-SysPilotInput 'IP-Adresse (z.B. 127.0.0.1), leer = abbrechen'
                if (-not $ip) { continue }
                $hn = Read-SysPilotInput 'Hostname/Domaene (z.B. example.com)'
                if (-not $hn) { continue }
                if (Confirm-SysPilot "Eintrag hinzufuegen?`n  $ip`t$hn") {
                    Set-SysPilotHostsEntry -Action Add -IP $ip -Host $hn
                    Clear-DnsClientCache -ErrorAction SilentlyContinue
                }
            }
            'remove' {
                $m = Read-SysPilotInput 'Hostname-Teilstring zum Entfernen (z.B. tracker), leer = abbrechen'
                if (-not $m) { continue }
                if (Confirm-SysPilot "Alle Eintraege mit '$m' entfernen?") {
                    Set-SysPilotHostsEntry -Action Remove -Match $m
                    Clear-DnsClientCache -ErrorAction SilentlyContinue
                }
            }
            'clear' {
                if (Confirm-SysPilot 'Wirklich ALLE aktiven HOSTS-Eintraege entfernen? Backup wird erstellt.') {
                    Set-SysPilotHostsEntry -Action Clear
                    Clear-DnsClientCache -ErrorAction SilentlyContinue
                }
            }
            'lock' {
                if ($locked) { Set-SysPilotHostsLock -Lock $false } else { Set-SysPilotHostsLock -Lock $true }
            }
            'show' {
                Write-Host ''
                Get-Content $script:HostsPath -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'flush' {
                try { Clear-DnsClientCache; Write-Host '  [OK] DNS-Cache geleert.' -ForegroundColor Green }
                catch { Write-Host "  [!] Flush fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Red }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
        }
    }
}

Export-ModuleMember -Function Get-SysPilotHostsEntries, Backup-SysPilotHostsFile, Set-SysPilotHostsEntry, Set-SysPilotHostsLock, Show-SysPilotHostsEditor
