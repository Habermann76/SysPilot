# SysPilot - Toolbox: Alle Werkzeuge nach Kategorie, mit ehrlichen Erklaerungen.
# Vorbild Advanced SystemCare Toolbox - aber kostenlos, ohne Werbung, ohne Abo.
#Requires -Version 5.1

# ---------- Neue Mini-Werkzeuge ----------

function Get-SysPilotProfileDirs {
    <# Stack-basierte Ordner-Enumeration mit echtem Pruning: ausgeschlossene Ordner
       (.git, node_modules, AppData ...) werden gar nicht erst betreten.
       Get-ChildItem -Recurse wuerde sie trotz Filter erst komplett auflisten.
       MaxDepth begrenzt die Tiefe (OneDrive-Ordner koennen riesig sein). #>
    param([string[]]$Roots, [switch]$FilesToo, [int]$MaxDepth = 4)
    $skipDirs = @('.git', 'node_modules', '.vscode', '.cache', 'AppData', '$Recycle.Bin')
    $stack = New-Object System.Collections.Generic.Stack[PSCustomObject]
    foreach ($r in $Roots) { if (Test-Path $r) { $stack.Push([PSCustomObject]@{ Path = $r; Depth = 0 }) } }
    while ($stack.Count -gt 0) {
        $cur = $stack.Pop()
        if ($cur.Depth -ge $MaxDepth) { continue }
        $items = Get-ChildItem $cur.Path -Force -ErrorAction SilentlyContinue
        foreach ($i in $items) {
            if ($i.PSIsContainer) {
                if ($skipDirs -notcontains $i.Name) {
                    $stack.Push([PSCustomObject]@{ Path = $i.FullName; Depth = $cur.Depth + 1 })
                    $i  # Ordner selbst auch liefern
                }
            } elseif ($FilesToo) {
                $i
            }
        }
    }
}

function Find-SysPilotLargeFiles {
    <# Findet die groessten Dateien im Benutzerprofil (Downloads, Dokumente, Videos, Bilder, Desktop). #>
    param([int]$Top = 20, [int]$MinMB = 100)
    $roots = @(
        "$env:USERPROFILE\Downloads",
        [Environment]::GetFolderPath('MyDocuments'),
        [Environment]::GetFolderPath('MyVideos'),
        [Environment]::GetFolderPath('MyPictures'),
        [Environment]::GetFolderPath('Desktop')
    ) | Select-Object -Unique
    $minBytes = $MinMB * 1MB
    $files = @(Get-SysPilotProfileDirs -Roots $roots -FilesToo -MaxDepth 6 |
        Where-Object { -not $_.PSIsContainer -and $_.Length -ge $minBytes })
    return @($files | Sort-Object Length -Descending | Select-Object -First $Top | ForEach-Object {
        [PSCustomObject]@{
            Name   = $_.Name
            Pfad   = $_.FullName
            SizeMB = [math]::Round($_.Length / 1MB)
            Alter  = [math]::Round(((Get-Date) - $_.LastWriteTime).TotalDays)
        }
    })
}

function Find-SysPilotEmptyFolders {
    <# Findet leere Ordner im Benutzerprofil (Ueberreste deinstallierter Programme). #>
    param([int]$Max = 50)
    $roots = @(
        [Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('MyDocuments'),
        [Environment]::GetFolderPath('MyVideos'),
        [Environment]::GetFolderPath('MyPictures'),
        [Environment]::GetFolderPath('MyMusic'),
        "$env:USERPROFILE\Downloads"
    ) | Select-Object -Unique
    $empty = @()
    foreach ($d in (Get-SysPilotProfileDirs -Roots $roots -MaxDepth 3)) {
        if ($empty.Count -ge $Max) { break }
        $content = Get-ChildItem $d.FullName -Force -ErrorAction SilentlyContinue
        if (-not $content) { $empty += $d.FullName }
    }
    return $empty
}

function Show-SysPilotSecurityCheck {
    <# Sicherheits-Check: Defender, Firewall, UAC, SMBv1, PSv2, Neustart - mit Erklaerungen. #>
    Write-SysPilotHeader 'Sicherheits-Check'
    $sec = Get-SysPilotSecurityStatus

    Write-Host '  VIRENSCHUTZ' -ForegroundColor Cyan
    if ($sec.OtherAv.Count -gt 0) {
        Write-Host "    [OK] Aktiv: $($sec.OtherAv -join ', ')" -ForegroundColor Green
    } elseif ($sec.AvService -eq $true) {
        Write-Host '    [OK] Windows Defender ist aktiv' -ForegroundColor Green
        if ($sec.AvRealTime) {
            Write-Host '    [OK] Echtzeitschutz laeuft' -ForegroundColor Green
        } else {
            Write-Host '    [!] Echtzeitschutz ist AUS - das ist gefaehrlich!' -ForegroundColor Red
        }
        $sigColor = if ($sec.AvSignatureAgeDays -le 3) { 'Green' } else { 'Yellow' }
        Write-Host "    [i] Signaturen: $($sec.AvSignatureAgeDays) Tage alt" -ForegroundColor $sigColor
    } else {
        Write-Host '    [!] KEIN aktiver Virenschutz gefunden!' -ForegroundColor Red
    }

    Write-Host ''
    Write-Host '  FIREWALL' -ForegroundColor Cyan
    if ($sec.FirewallOff.Count -eq 0) {
        Write-Host '    [OK] Alle Profile aktiv (Privat, Oeffentlich, Domain)' -ForegroundColor Green
    } else {
        Write-Host "    [!] AUS in: $($sec.FirewallOff -join ', ')" -ForegroundColor Red
    }

    Write-Host ''
    Write-Host '  SYSTEM' -ForegroundColor Cyan
    if ($sec.UacEnabled) {
        Write-Host '    [OK] Benutzerkontensteuerung (UAC) aktiv' -ForegroundColor Green
    } else {
        Write-Host '    [!] UAC ist AUS - Programme bekommen Admin-Rechte ohne Rueckfrage!' -ForegroundColor Red
    }
    if ($sec.SmbV1 -eq $true) {
        Write-Host '    [!] SMBv1 aktiv (veraltet, Ransomware-Einfallstor)' -ForegroundColor Yellow
    } else {
        Write-Host '    [OK] SMBv1 aus' -ForegroundColor Green
    }
    if ($sec.PsV2Enabled -eq $true) {
        Write-Host '    [!] PowerShell v2 aktiv (veraltet, wird von Malware missbraucht)' -ForegroundColor Yellow
    } else {
        Write-Host '    [OK] PowerShell v2 aus' -ForegroundColor Green
    }
    if ($sec.PendingReboot) {
        Write-Host '    [i] Ausstehender Neustart - Updates warten auf Fertigstellung' -ForegroundColor Yellow
    } else {
        Write-Host '    [OK] Kein Neustart ausstehend' -ForegroundColor Green
    }

    Write-Host ''
    Write-Host '  Reparaturen laufen ueber den Automatic Checkup (Menue 24).' -ForegroundColor DarkGray
}

function Update-SysPilotWindows {
    <# Startet die Windows-Update-Suche und oeffnet die Update-Einstellungen. #>
    Write-SysPilotHeader 'Windows Update'
    Write-Host '  Starte Update-Suche im Hintergrund ...' -ForegroundColor Cyan
    try {
        Start-Process 'UsoClient.exe' -ArgumentList 'StartInteractiveScan' -ErrorAction SilentlyContinue
    } catch { }
    Start-Process 'ms-settings:windowsupdate'
    Write-Host '  [OK] Update-Suche gestartet, Einstellungen geoeffnet.' -ForegroundColor Green
    Write-Host '  Die Suche dauert ein paar Minuten - Ergebnisse siehst du im Einstellungen-Fenster.' -ForegroundColor DarkGray
}

function Show-SysPilotShortcutFixer {
    <# Findet tote Verknuepfungen (Ziel existiert nicht mehr) und loescht sie auf Wunsch. #>
    Write-SysPilotHeader 'Shortcut-Fixer'
    $broken = @(Find-SysPilotBrokenShortcuts)
    if ($broken.Count -eq 0) { Write-Host '  [OK] Keine toten Verknuepfungen gefunden.' -ForegroundColor Green }
    else {
        $broken | Format-Table -AutoSize
        if (Confirm-SysPilot "$($broken.Count) tote Verknuepfungen loeschen?") {
            foreach ($b in $broken) { Remove-Item $b.Link -Force -ErrorAction SilentlyContinue }
            Write-Host '  [OK] Geloescht.' -ForegroundColor Green
            Write-SysPilotLog "Shortcut-Fixer: $($broken.Count) tote Verknuepfungen geloescht"
        }
    }
}

function Show-SysPilotLargeFiles {
    <# Zeigt die groessten Dateien im Benutzerprofil - Platzfresser selbst loeschen. #>
    Write-SysPilotHeader 'Grosse Dateien (Top 20, ab 100 MB)'
    $big = @(Find-SysPilotLargeFiles)
    if ($big.Count -eq 0) { Write-Host '  [OK] Keine grossen Dateien gefunden.' -ForegroundColor Green }
    else {
        $big | Format-Table -AutoSize
        Write-Host '  Tipp: Pfad kopieren, im Explorer oeffnen, selbst entscheiden.' -ForegroundColor DarkGray
    }
}

function Show-SysPilotEmptyFolders {
    <# Findet leere Ordner im Benutzerprofil (Ueberreste) und loescht sie auf Wunsch. #>
    Write-SysPilotHeader 'Leere Ordner'
    $empty = @(Find-SysPilotEmptyFolders)
    if ($empty.Count -eq 0) { Write-Host '  [OK] Keine leeren Ordner gefunden.' -ForegroundColor Green }
    else {
        $empty | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        if (Confirm-SysPilot "$($empty.Count) leere Ordner loeschen?") {
            foreach ($e in $empty) { Remove-Item $e -Force -Recurse -ErrorAction SilentlyContinue }
            Write-Host '  [OK] Geloescht.' -ForegroundColor Green
            Write-SysPilotLog "Leere Ordner: $($empty.Count) geloescht"
        }
    }
}

function Show-SysPilotSystemInfo {
    <# Kompakte System-Info: CPU, RAM, GPU, Platten, Windows. #>
    Write-SysPilotHeader 'System-Info'
    $os = Get-CimInstance Win32_OperatingSystem
    $cpu = Get-CimInstance Win32_Processor
    $gpu = Get-CimInstance Win32_VideoController
    $bios = Get-CimInstance Win32_BIOS
    Write-Host "  Computer:  $env:COMPUTERNAME"
    Write-Host "  Windows:   $($os.Caption) (Build $($os.BuildNumber))"
    Write-Host "  CPU:       $($cpu.Name.Trim())"
    Write-Host "             $($cpu.NumberOfCores) Kerne / $($cpu.NumberOfLogicalProcessors) Threads, max $($cpu.MaxClockSpeed) MHz"
    Write-Host "  RAM:       $([math]::Round($os.TotalVisibleMemorySize / 1MB, 1)) GB"
    foreach ($g in $gpu) {
        Write-Host "  GPU:       $($g.Name) ($([math]::Round($g.AdapterRAM / 1GB, 1)) GB)"
    }
    Write-Host "  BIOS:      $($bios.SMBIOSBIOSVersion)"
    Write-Host ''
    Write-Host '  Datentraeger:' -ForegroundColor Cyan
    Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
        $totalGB = [math]::Round($_.Size / 1GB, 1)
        $freeGB = [math]::Round($_.FreeSpace / 1GB, 1)
        $pct = if ($_.Size -gt 0) { [math]::Round(100 * $_.FreeSpace / $_.Size) } else { 0 }
        Write-Host ("    {0}  {1} GB frei von {2} GB ({3}% frei)" -f $_.DeviceID, $freeGB, $totalGB, $pct)
    }
    $up = (Get-Date) - $os.LastBootUpTime
    Write-Host ''
    Write-Host ("  Laufzeit seit Start: {0} Tage {1} Std {2} Min" -f $up.Days, $up.Hours, $up.Minutes)
}

# ---------- Toolbox-Registry ----------

function Get-SysPilotToolbox {
    <# Alle Werkzeuge: Kategorie, Name, Beschreibung, Action (Scriptblock), NeedsAdmin. #>
    $tools = @()

    # --- System optimieren ---
    $tools += @{ Category = 'System optimieren'; Key = 'autooptimize'; Name = 'VOLLAUTOMATIK (Auto-Optimierung)'
        Desc = 'Alles in einem Rutsch: Backup, Dienste, sicher unnoetige Features aus, Tweaks (Game Mode, Werbung aus), Prioritaeten.'
        NeedsAdmin = $true; Action = { Invoke-SysPilotAutoOptimize; Read-SysPilotChoice 'Weiter' | Out-Null } }
    $tools += @{ Category = 'System optimieren'; Key = 'plans'; Name = 'Energieplaene einrichten'
        Desc = 'Installiert die SysPilot-Plaene "Kuehl & Leise" und "Leistung" - die Basis fuer alles andere.'
        NeedsAdmin = $true; Action = { Install-SysPilotPlans; Read-SysPilotChoice 'Weiter' | Out-Null } }
    $tools += @{ Category = 'System optimieren'; Key = 'autopilot'; Name = 'Autopilot starten'
        Desc = 'Live-Umschaltung der Energieplaene + Prozess-Prioritaeten, erkennt Spiele/Entwicklung/Browser, Hitzeschutz.'
        NeedsAdmin = $false; Action = { Start-SysPilotAutopilot } }
    $tools += @{ Category = 'System optimieren'; Key = 'autopilottask'; Name = 'Autopilot bei Anmeldung'
        Desc = 'Startet den Autopilot automatisch bei jeder Windows-Anmeldung (oder entfernt den Autostart wieder).'
        NeedsAdmin = $true; Action = {
            $t = Get-ScheduledTask -TaskName 'SysPilot Autopilot' -ErrorAction SilentlyContinue
            if ($t) { Remove-SysPilotAutopilotTask } else { Install-SysPilotAutopilotTask }
            Read-SysPilotChoice 'Weiter' | Out-Null
        } }
    $tools += @{ Category = 'System optimieren'; Key = 'smartboost'; Name = 'Smart Boost an/aus'
        Desc = 'Der Autopilot gibt RAM automatisch frei, sobald er knapp wird (ueber 85% belegt). Einmal einschalten, nie wieder dran denken.'
        NeedsAdmin = $false; Action = {
            $cur = [bool](Get-SysPilotConfig).Autopilot.AutoFreeRam
            Set-SysPilotConfigValue -Section 'Autopilot' -Key 'AutoFreeRam' -Value (-not $cur)
            Write-Host ('  Smart Boost: ' + $(if (-not $cur) { 'AN' } else { 'AUS' })) -ForegroundColor $(if (-not $cur) { 'Green' } else { 'Yellow' })
            Read-SysPilotChoice 'Weiter' | Out-Null
        } }
    $tools += @{ Category = 'System optimieren'; Key = 'checkupschedule'; Name = 'Checkup-Zeitplan'
        Desc = 'Checkup automatisch laufen lassen: taeglich oder an einem Wochentag, zu einer Uhrzeit, mit automatischem Beheben.'
        NeedsAdmin = $true; Action = { Show-SysPilotCheckupScheduleMenu } }
    $tools += @{ Category = 'System optimieren'; Key = 'guardian'; Name = 'SysPilot Guardian'
        Desc = 'Wacht ueber SysPilot: startet es automatisch neu, falls es nicht laeuft. Waehlbar: GUI offen oder nur im Tray.'
        NeedsAdmin = $true; Action = { Show-SysPilotGuardianMenu } }
    $tools += @{ Category = 'System optimieren'; Key = 'startup'; Name = 'Autostart-Manager'
        Desc = 'Zeigt alle Autostart-Eintraege, deaktiviert ohne zu loeschen (rueckgaengig moeglich).'
        NeedsAdmin = $false; Action = { Show-SysPilotStartupManager } }
    $tools += @{ Category = 'System optimieren'; Key = 'services'; Name = 'Dienste-Tuner'
        Desc = 'Deaktiviert gepruefte, unnoetige Windows-Dienste. Nur Empfehlungen, die Ressourcen sparen.'
        NeedsAdmin = $true; Action = { Show-SysPilotServiceTuner; Read-SysPilotChoice 'Weiter' | Out-Null } }
    $tools += @{ Category = 'System optimieren'; Key = 'freemem'; Name = 'RAM freigeben'
        Desc = 'Leert Working Sets und Standby-Cache. Sofort mehr freier RAM, ehrlich gemessen.'
        NeedsAdmin = $false; Action = { Invoke-SysPilotFreeRam; Read-SysPilotChoice 'Weiter' | Out-Null } }
    $tools += @{ Category = 'System optimieren'; Key = 'priorities'; Name = 'Prozess-Prioritaeten'
        Desc = 'Wichtige Programme hoeher, Ballast niedriger priorisieren. Wirkt sofort.'
        NeedsAdmin = $false; Action = { Set-SysPilotPriorities; Read-SysPilotChoice 'Weiter' | Out-Null } }
    $tools += @{ Category = 'System optimieren'; Key = 'features'; Name = 'Windows-Funktionen & Gaming-Tweaks'
        Desc = 'Game Mode, HAGS, Werbung an/aus, visuelle Effekte huebsch oder schnell.'
        NeedsAdmin = $false; Action = { Show-SysPilotFeaturesMenu } }
    $tools += @{ Category = 'System optimieren'; Key = 'scripts'; Name = 'Skripte (Gaming/Arbeit/Kuehl/Nacht)'
        Desc = 'Fertige Modus-Pakete - ein Klick stellt alles auf Gaming, Arbeit, kuehlen Betrieb oder Nacht.'
        NeedsAdmin = $false; Action = { Show-SysPilotScriptsMenu } }

    # --- Sicherheit & Reparatur ---
    $tools += @{ Category = 'Sicherheit & Reparatur'; Key = 'security'; Name = 'Sicherheits-Check'
        Desc = 'Prueft Virenschutz, Firewall, UAC, veraltete Protokolle - mit Erklaerungen.'
        NeedsAdmin = $false; Action = { Show-SysPilotSecurityCheck; Read-SysPilotChoice 'Weiter' | Out-Null } }
    $tools += @{ Category = 'Sicherheit & Reparatur'; Key = 'netrepair'; Name = 'Netzwerk / Internet reparieren'
        Desc = '14 bewaehrte Reparaturen: Winsock, DNS, IP-Reset, Proxy-Reset u.v.m. (wie Complete Internet Repair).'
        NeedsAdmin = $true; Action = { Show-SysPilotNetworkRepair } }
    $tools += @{ Category = 'Sicherheit & Reparatur'; Key = 'adapters'; Name = 'Netzwerkadapter identifizieren'
        Desc = 'Was ist vgate0, TAP-Windows & Co.? Findet das zugehoerige Programm, bietet Deinstallation an.'
        NeedsAdmin = $false; Action = { Show-SysPilotNetworkAdapters } }
    $tools += @{ Category = 'Sicherheit & Reparatur'; Key = 'winupdate'; Name = 'Windows Update suchen'
        Desc = 'Startet die Update-Suche und oeffnet die Update-Einstellungen.'
        NeedsAdmin = $false; Action = { Update-SysPilotWindows; Read-SysPilotChoice 'Weiter' | Out-Null } }
    $tools += @{ Category = 'Sicherheit & Reparatur'; Key = 'backup'; Name = 'Backup erstellen / wiederherstellen'
        Desc = 'Sichert Dienste, Autostart und Energieplaene - der Sicherheitsgurt vor jeder Optimierung.'
        NeedsAdmin = $true; Action = {
            $b = New-SysPilotBackup -Label 'toolbox'
            Write-Host "  Backup erstellt: $b" -ForegroundColor Green
            Read-SysPilotChoice 'Weiter' | Out-Null
        } }

    # --- System bereinigen ---
    $tools += @{ Category = 'System bereinigen'; Key = 'cleanup'; Name = 'Datentraeger bereinigen'
        Desc = 'Temp, Update-Cache, Miniaturbilder, Shader-Cache, Papierkorb - mit Analyse vorher.'
        NeedsAdmin = $false; Action = { Show-SysPilotCleanupMenu; Read-SysPilotChoice 'Weiter' | Out-Null } }
    $tools += @{ Category = 'System bereinigen'; Key = 'bloat'; Name = 'Bloatware-Finder'
        Desc = 'Findet bekannte Werbe-Apps und Ressourcenfresser, deinstalliert und entfernt Datei-Reste.'
        NeedsAdmin = $false; Action = { Show-SysPilotBloatManager } }
    $tools += @{ Category = 'System bereinigen'; Key = 'uwp'; Name = 'UWP-Apps ausmisten'
        Desc = 'Vorinstallierte Windows-Apps (Facebook, TikTok, Spiele-Werbung) entfernen.'
        NeedsAdmin = $false; Action = { Show-SysPilotUwpManager } }
    $tools += @{ Category = 'System bereinigen'; Key = 'shortcuts'; Name = 'Shortcut-Fixer'
        Desc = 'Findet tote Verknuepfungen auf Desktop/Startmenue (Ziel existiert nicht mehr) und loescht sie.'
        NeedsAdmin = $false; Action = { Show-SysPilotShortcutFixer; Read-SysPilotChoice 'Weiter' | Out-Null } }
    $tools += @{ Category = 'System bereinigen'; Key = 'largefiles'; Name = 'Grosse Dateien finden'
        Desc = 'Zeigt die groessten Dateien in Downloads/Dokumente/Videos - Platzfresser selbst loeschen.'
        NeedsAdmin = $false; Action = { Show-SysPilotLargeFiles; Read-SysPilotChoice 'Weiter' | Out-Null } }
    $tools += @{ Category = 'System bereinigen'; Key = 'emptyfolders'; Name = 'Leere Ordner finden'
        Desc = 'Findet leere Ordner im Benutzerprofil - Ueberreste deinstallierter Programme.'
        NeedsAdmin = $false; Action = { Show-SysPilotEmptyFolders; Read-SysPilotChoice 'Weiter' | Out-Null } }
    $tools += @{ Category = 'System bereinigen'; Key = 'extensions'; Name = 'Browser-Erweiterungen pruefen'
        Desc = 'Findet doppelte KI-/Coupon-/Cleaner-Erweiterungen in Chrome, Edge, Brave, Opera, Firefox.'
        NeedsAdmin = $false; Action = { Show-SysPilotExtensionManager } }

    # --- Analyse & Info ---
    $tools += @{ Category = 'Analyse & Info'; Key = 'report'; Name = 'System-Analyse'
        Desc = 'Was bremst meinen PC? Top RAM-Verbraucher, Warnungen, Empfehlungen.'
        NeedsAdmin = $false; Action = { Show-SysPilotReport; Read-SysPilotChoice 'Weiter' | Out-Null } }
    $tools += @{ Category = 'Analyse & Info'; Key = 'hogs'; Name = 'Ressourcen-Fresser & Massnahmen'
        Desc = 'Die groessten Verbraucher mit konkreten Massnahmen, Howto-Links und Direkt-Aktionen.'
        NeedsAdmin = $false; Action = { Show-SysPilotHogs; Read-SysPilotChoice 'Weiter' | Out-Null } }
    $tools += @{ Category = 'Analyse & Info'; Key = 'stats'; Name = 'Statistiken (Verlauf)'
        Desc = 'CPU/RAM/Temperatur-Verlauf aus den Autopilot-Messungen.'
        NeedsAdmin = $false; Action = { Show-SysPilotStats; Read-SysPilotChoice 'Weiter' | Out-Null } }
    $tools += @{ Category = 'Analyse & Info'; Key = 'sysinfo'; Name = 'System-Info'
        Desc = 'CPU, RAM, GPU, Platten, Windows-Version, Laufzeit - kompakt auf einen Blick.'
        NeedsAdmin = $false; Action = { Show-SysPilotSystemInfo; Read-SysPilotChoice 'Weiter' | Out-Null } }

    return $tools
}

function Show-SysPilotToolbox {
    <# Toolbox-Hauptmenue: Kategorie waehlen -> Werkzeug waehlen -> laeuft. #>
    $tools = Get-SysPilotToolbox
    $categories = @($tools | Group-Object Category | ForEach-Object { $_.Name })

    while ($true) {
        $catItems = @()
        foreach ($c in $categories) {
            $count = @($tools | Where-Object { $_.Category -eq $c }).Count
            $catItems += @{ Label = "$c  ($count Werkzeuge)"; Color = 'White'; Tag = $c }
        }
        $catItems += @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = $null }
        $cat = Show-SysPilotArrowMenu -Items $catItems -Title 'TOOLBOX - Kategorie waehlen'
        if ($null -eq $cat) { return }

        while ($true) {
            $toolItems = @()
            foreach ($t in ($tools | Where-Object { $_.Category -eq $cat })) {
                $adminTag = if ($t.NeedsAdmin -and -not (Test-SysPilotAdmin)) { ' [Admin]' } else { '' }
                $toolItems += @{ Label = "$($t.Name)$adminTag"; Color = 'White'; Tag = $t.Name }
            }
            $toolItems += @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = $null }
            $pick = Show-SysPilotArrowMenu -Items $toolItems -Title "$cat - Werkzeug waehlen"
            if ($null -eq $pick) { break }

            $tool = $tools | Where-Object { $_.Category -eq $cat -and $_.Name -eq $pick } | Select-Object -First 1
            Write-SysPilotHeader $tool.Name
            Write-Host "  $($tool.Desc)" -ForegroundColor DarkGray
            Write-Host ''
            if ($tool.NeedsAdmin -and -not (Test-SysPilotAdmin)) {
                Write-Host '  [!] Dieses Werkzeug braucht Admin-Rechte (Hauptmenue 16).' -ForegroundColor Yellow
                Read-SysPilotChoice 'Weiter' | Out-Null
                continue
            }
            & $tool.Action
        }
    }
}

Export-ModuleMember -Function Get-SysPilotToolbox, Show-SysPilotToolbox,
    Find-SysPilotLargeFiles, Find-SysPilotEmptyFolders, Show-SysPilotSecurityCheck,
    Update-SysPilotWindows, Show-SysPilotSystemInfo,
    Show-SysPilotShortcutFixer, Show-SysPilotLargeFiles, Show-SysPilotEmptyFolders
