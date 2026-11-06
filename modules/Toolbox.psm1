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
        Explanation = 'Der Vollautomatik-Smann tut das Auto-Optimieren für dich: Erstellt zuerst ein Backup, deaktiviert geprüfte Dienste, entfernt unnötige Windows-Features, wendet Tweaks an (Game Mode an, Werbung aus, Optik bleibt hübsch) und setzt Prozess-Prioritäten.'
        Tip = 'Starte nur, wenn du alles sichern willst. Tippe zuerst „Energiepläne einrichten", um die Basis-Pläne zu aktivieren.'
        HowTo = 'Alle unter dem Menüpunkt „Optimiert“ zusammen ausführen, danach Imagen-Restore optional vorbereiten.'
        AISearchQuery = 'Windows 11 Auto-Optimierung: Dienste deaktivieren, Features deinstallieren, Prozesspriorität'
        NeedsAdmin = $true; HasGUI = $true; Action = { Invoke-SysPilotAutoOptimize; Read-SysPilotChoice 'Weiter' | Out-Null } }
    $tools += @{ Category = 'System optimieren'; Key = 'plans'; Name = 'Energieplaene einrichten'
        Desc = 'Installiert die SysPilot-Plaene "Kuehl & Leise" und "Leistung" - die Basis fuer alles andere.'
        Explanation = 'Energiepläne bestimmen, wie aggressiv Windows Ressourcen nutzt. „Kühl & Leise" senkt die Taktung bei Last, „Leistung" maximiert sie. Beide Pläne sind anpassbar und fangen schnell wieder um (z. B. bei Thermalisierung).'
        Tip = 'Nimm zuerst „Kühl & Leise" für lärmarme Operation, schalte bei Gaming-/Arbeitsphasen auf „Leistung".'
        HowTo = 'Konsole: Import-Module SysPilot.psm1 -> Install-SysPilotPlans -> Wahl „Kühl & Leise" fürs Alltags, „Leistung" für Gaming/Arbeit.'
        AISearchQuery = 'Windows 11 Energiepläne einrichten: Leistung und Lärmschutz konfigurieren'
        NeedsAdmin = $true; HasGUI = $true; Action = { Install-SysPilotPlans; Read-SysPilotChoice 'Weiter' | Out-Null } }
    $tools += @{ Category = 'System optimieren'; Key = 'autopilot'; Name = 'Autopilot starten'
        Desc = 'Live-Umschaltung der Energieplaene + Prozess-Prioritaeten, erkennt Spiele/Entwicklung/Browser, Hitzeschutz.'
        Explanation = 'Der Autopilot erkennt, welche Anwendung aktiv ist (Spiel, Entwicklung, Browser) und passt automatisch die Energiepläne und Prozess-Prioritäten an. Er beinhaltet Hitzeschutz (Notaus bei 95°C).'
        Tip = 'Autopilot ist ideal für Gamer und Entwickler. Der Hitzeschutz schützt vor Überhitzung.'
        HowTo = 'Autopilot starten: Menü -> "Autopilot starten" oder GUI-Button "Autopilot".'
        AISearchQuery = 'Windows 11 Autopilot Energieplan Prozesspriorität Spiel erkennen'
        NeedsAdmin = $false; HasGUI = $true; Action = { Start-SysPilotAutopilot } }
    $tools += @{ Category = 'System optimieren'; Key = 'autopilottask'; Name = 'Autopilot bei Anmeldung'
        Desc = 'Startet den Autopilot automatisch bei jeder Windows-Anmeldung (oder entfernt den Autostart wieder).'
        Explanation = 'Der Autopilot startet mit Windows und optimiert Energiepläne + Prozess-Prioritäten im Hintergrund. Du kannst ihn jederzeit wieder entfernen.'
        Tip = 'Nützlich, wenn du SysPilot dauerhaft laufen lassen willst. Nicht notwendig, wenn du nur gelegentlich optimierst.'
        HowTo = 'Toolbox öffnen -> „Autopilot bei Anmeldung" aktivieren/deaktivieren.'
        AISearchQuery = 'Windows 11 Autostart geplanten Task erstellen entfernen Autopilot'
        NeedsAdmin = $true; HasGUI = $true; Action = {
            $t = Get-ScheduledTask -TaskName 'SysPilot Autopilot' -ErrorAction SilentlyContinue
            if ($t) { Remove-SysPilotAutopilotTask } else { Install-SysPilotAutopilotTask }
            Read-SysPilotChoice 'Weiter' | Out-Null
        } }
    $tools += @{ Category = 'System optimieren'; Key = 'smartboost'; Name = 'Smart Boost an/aus'
        Desc = 'Der Autopilot gibt RAM automatisch frei, sobald er knapp wird (ueber 85% belegt). Einmal einschalten, nie wieder dran denken.'
        Explanation = 'Smart Boost überwacht den verfügbaren RAM. Wenn er unter 85% fällt, gibt der Autopilot aktiv Working Sets und den Standby-Cache zurück, denn sofort mehr freier RAM. Er ist deaktivierbar und läuft im Hintergrund.'
        Tip = 'Nutze Smart Boost nur, wenn du oft viele Apps gleichzeitig geöffnet hast. Nicht aktiv, wenn du PCs mit wenig RAM hast und zu viele Programme gemeinsam nutzen möchtest.'
        HowTo = 'Systemsteuerung > Leistung > Smart Boost ein > Einstellungen speichern > Neustart'
        AISearchQuery = 'Windows 11 RAM freigeben automatisch Smart Boost Konfiguration'
        NeedsAdmin = $false; HasGUI = $true; Action = {
            $cur = [bool](Get-SysPilotConfig).Autopilot.AutoFreeRam
            Set-SysPilotConfigValue -Section 'Autopilot' -Key 'AutoFreeRam' -Value (-not $cur)
            Write-Host ('  Smart Boost: ' + $(if (-not $cur) { 'AN' } else { 'AUS' })) -ForegroundColor $(if (-not $cur) { 'Green' } else { 'Yellow' })
            Read-SysPilotChoice 'Weiter' | Out-Null
        } }
    $tools += @{ Category = 'System optimieren'; Key = 'checkupschedule'; Name = 'Checkup-Zeitplan'
        Desc = 'Checkup automatisch laufen lassen: taeglich oder an einem Wochentag, zu einer Uhrzeit, mit automatischem Beheben.'
        Explanation = 'Der Checkup-Scan prüft 15 Bereiche deines Systems und kann Probleme automatisch beheben. Mit dem Zeitplan läuft er täglich oder wöchentlich zu einer festen Uhrzeit.'
        Tip = 'Nachts (z. B. 03:00) mit „automatisch beheben" einsetzen, damit der PC morgens bereit ist.'
        HowTo = 'Toolbox -> „Checkup-Zeitplan" -> Häufigkeit, Uhrzeit, AutoFix einstellen.'
        AISearchQuery = 'Windows 11 geplanten Task erstellen täglich Skript ausführen'
        NeedsAdmin = $true; HasGUI = $true; Action = { Show-SysPilotCheckupScheduleMenu } }
    $tools += @{ Category = 'System optimieren'; Key = 'guardian'; Name = 'SysPilot Guardian'
        Desc = 'Wacht ueber SysPilot: startet es automatisch neu, falls es nicht laeuft. Waehlbar: GUI offen oder nur im Tray.'
        Explanation = 'Der Guardian überwacht, ob SysPilot läuft. Wenn nicht, startet er es automatisch neu – als sichtbares Fenster oder unsichtbar im Tray.'
        Tip = 'Wähle „Nur im Tray", wenn SysPilot im Hintergrund laufen soll ohne Fenster.'
        HowTo = 'Toolbox -> „SysPilot Guardian" -> Start-Modus wählen.'
        AISearchQuery = 'Windows 11 geplanter Task Programm automatisch neu starten wenn nicht läuft'
        NeedsAdmin = $true; HasGUI = $true; Action = { Show-SysPilotGuardianMenu } }
    $tools += @{ Category = 'System optimieren'; Key = 'startup'; Name = 'Autostart-Manager'
        Desc = 'Zeigt alle Autostart-Eintraege, deaktiviert ohne zu loeschen (rueckgaengig moeglich).'
        Explanation = 'Der Autostart-Manager listet alle Programme, die mit Windows starten. Du kannst sie deaktivieren (nicht löschen) und später wieder aktivieren.'
        Tip = 'Deaktiviere alles, was du nicht täglich brauchst. Jeder Eintrag ist rückgängig machbar.'
        HowTo = 'Toolbox -> „Autostart-Manager" -> Eintrag auswählen -> deaktivieren.'
        AISearchQuery = 'Windows 11 Autostart Programme deaktivieren Task Manager'
        NeedsAdmin = $false; HasGUI = $true; Action = { Show-SysPilotStartupManager } }
    $tools += @{ Category = 'System optimieren'; Key = 'services'; Name = 'Dienste-Tuner'
        Desc = 'Deaktiviert gepruefte, unnoetige Windows-Dienste. Nur Empfehlungen, die Ressourcen sparen.'
        Explanation = 'Der Dienste-Tuner deaktiviert Windows-Dienste, die du wahrscheinlich nicht brauchst (z. B. Fax, Drucker, veraltete Dienste). Das spart RAM und CPU.'
        Tip = 'Nur Dienste deaktivieren, deren Funktion du kennst. Unwissend deaktivieren kann Systemstabilität beeinträchtigen.'
        HowTo = 'Toolbox -> „Dienste-Tuner" -> Dienst auswählen -> deaktivieren.'
        AISearchQuery = 'Windows 11 Dienste deaktivieren sicher welche nicht brauchen'
        NeedsAdmin = $true; HasGUI = $true; Action = { Show-SysPilotServiceTuner; Read-SysPilotChoice 'Weiter' | Out-Null } }
    $tools += @{ Category = 'System optimieren'; Key = 'freemem'; Name = 'RAM freigeben'
        Desc = 'Leert Working Sets und Standby-Cache. Sofort mehr freier RAM, ehrlich gemessen.'
        Explanation = 'Smart Boost legt Working Sets und den Standby-Cache frei. Das gibt sofort mehr verfügbaren RAM, ohne Programme zu beenden.'
        Tip = 'Warte nicht bis der RAM voll ist – nutze das Tool vorbeugend vor schwerer Arbeit.'
        HowTo = 'Toolbox -> „RAM freigeben" -> Sofortige Freigabe starten.'
        AISearchQuery = 'Windows 11 RAM freigeben Working Set Standby Cache leeren'
        NeedsAdmin = $false; HasGUI = $true; Action = { Invoke-SysPilotFreeRam; Read-SysPilotChoice 'Weiter' | Out-Null } }
    $tools += @{ Category = 'System optimieren'; Key = 'priorities'; Name = 'Prozess-Prioritaeten'
        Desc = 'Wichtige Programme hoeher, Ballast niedriger priorisieren. Wirkt sofort.'
        Explanation = 'Prozess-Prioritäten bestimmen, wie viel CPU-Zeit ein Programm bekommt. Wichtige Apps (z. B. Spiele) bekommen mehr, Ballast (z. B. Hintergrund-Updates) weniger.'
        Tip = 'Nutze dies vor dem Gaming oder bei arbeitsintensiven Programmen.'
        HowTo = 'Toolbox -> „Prozess-Prioritäten" -> Prioritäten anwenden.'
        AISearchQuery = 'Windows 11 Prozesspriorität ändern Task Manager hoch niedrig'
        NeedsAdmin = $false; HasGUI = $true; Action = { Set-SysPilotPriorities; Read-SysPilotChoice 'Weiter' | Out-Null } }
    $tools += @{ Category = 'System optimieren'; Key = 'features'; Name = 'Windows-Funktionen & Gaming-Tweaks'
        Desc = 'Game Mode, HAGS, Werbung an/aus, visuelle Effekte huebsch oder schlank.'
        Explanation = 'Windows-Funktionen und Gaming-Tweaks passen das Windows-Erlebnis an: Game Mode für Spiele, HAGS für Grafik, Werbung aus, visuelle Effekte für bessere Optik oder mehr Geschwindigkeit.'
        Tip = 'Game Mode und HAGS können die FPS in Spielen verbessern. Visuelle Effekte schlank macht den PC flotter.'
        HowTo = 'Toolbox -> „Windows-Funktionen & Gaming-Tweaks" -> gewünschte Tweaks auswählen.'
        AISearchQuery = 'Windows 11 Game Mode HAGS Tweaks optimieren Gaming Leistung'
        NeedsAdmin = $true; HasGUI = $true; Action = { Show-SysPilotFeaturesMenu } }
    $tools += @{ Category = 'System optimieren'; Key = 'scripts'; Name = 'Skripte (Gaming/Arbeit/Kuehl/Nacht)'
        Desc = 'Fertige Modus-Pakete - ein Klick stellt alles auf Gaming, Arbeit, kuehlen Betrieb oder Nacht.'
        Explanation = 'Skripte sind fertige Modus-Pakete: Gaming, Arbeit, Kühlen oder Nacht. Ein Klick stellt Energieplan, Prioritäten und Tweaks für den gewählten Modus um.'
        Tip = 'Wähle den Modus, der zu deiner aktuellen Tätigkeit passt.'
        HowTo = 'Toolbox -> „Skripte" -> Modus auswählen -> anwenden.'
        AISearchQuery = 'Windows 11 Skript Gaming Arbeit Modus Energieplan umstellen'
        NeedsAdmin = $false; HasGUI = $true; Action = { Show-SysPilotScriptsMenu } }

    # --- Sicherheit & Reparatur ---
    $tools += @{ Category = 'Sicherheit & Reparatur'; Key = 'security'; Name = 'Sicherheits-Check'
        Desc = 'Prueft Virenschutz, Firewall, UAC, veraltete Protokolle - mit Erklaerungen.'
        Explanation = 'Der Sicherheits-Check prüft Virenschutz (Defender oder Drittanbieter), Firewall, UAC und veraltete Protokolle wie SMBv1 und PowerShell v2.'
        Tip = 'SMBv1 und PowerShell v2 sollten aus sein – sie sind alte, unsichere Protokolle.'
        HowTo = 'Toolbox -> „Sicherheits-Check" -> Ergebnisse ansehen, Empfehlungen befolgen.'
        AISearchQuery = 'Windows 11 Sicherheit überprüfen Defender Firewall UAC SMBv1'
        NeedsAdmin = $false; HasGUI = $true; Action = { Show-SysPilotSecurityCheck; Read-SysPilotChoice 'Weiter' | Out-Null } }
    $tools += @{ Category = 'Sicherheit & Reparatur'; Key = 'netrepair'; Name = 'Netzwerk / Internet reparieren'
        Desc = '14 bewaehrte Reparaturen: Winsock, DNS, IP-Reset, Proxy-Reset u.v.m. (wie Complete Internet Repair).'
        Explanation = 'Netzwerk-Reparatur führt 14 bewährte Reparaturen durch: Winsock-Reset, DNS-Cache leeren, IP-Reset, Proxy-Reset und mehr. Löst die meisten Internet-Probleme.'
        Tip = 'Führe Reparaturen einzeln aus und teste danach, ob das Internet wieder funktioniert.'
        HowTo = 'Toolbox -> „Netzwerk / Internet reparieren" -> Reparatur auswählen -> ausführen.'
        AISearchQuery = 'Windows 11 Netzwerk reparieren Winsock DNS IP Reset Internet nicht erreichbar'
        NeedsAdmin = $true; HasGUI = $true; Action = { Show-SysPilotNetworkRepair } }
    $tools += @{ Category = 'Sicherheit & Reparatur'; Key = 'adapters'; Name = 'Netzwerkadapter identifizieren'
        Desc = 'Was ist vgate0, TAP-Windows & Co.? Findet das zugehoerige Programm, bietet Deinstallation an.'
        Explanation = 'Netzwerkadapter-Identifikation zeigt alle Netzwerkkarten (phyisch, VPN, virtuell) mit Hersteller, Treiber und zugehörigem Programm an.'
        Tip = 'VPN-Adapter (TAP-Windows, vgate0) sollten nicht ohne Grund deinstalliert werden.'
        HowTo = 'Toolbox -> „Netzwerkadapter identifizieren" -> Adapter auswählen -> Details ansehen.'
        AISearchQuery = 'Windows 11 Netzwerkadapter identifizieren vgate0 TAP-Windows virtuell'
        NeedsAdmin = $false; HasGUI = $true; Action = { Show-SysPilotNetworkAdapters } }
    $tools += @{ Category = 'Sicherheit & Reparatur'; Key = 'winupdate'; Name = 'Windows Update suchen'
        Desc = 'Startet die Update-Suche und oeffnet die Update-Einstellungen.'
        Explanation = 'Windows Update sucht nach neuen Systemaktualisierungen und öffnet die Update-Einstellungen. Ein aktuelles Windows ist sicherer und stabiler.'
        Tip = 'Regelmäßig nach Updates suchen, besonders nach größeren Änderungen am System.'
        HowTo = 'Toolbox -> „Windows Update suchen" -> Suche starten.'
        AISearchQuery = 'Windows 11 Update suchen Einstellungen öffnen'
        NeedsAdmin = $false; HasGUI = $true; Action = { Update-SysPilotWindows; Read-SysPilotChoice 'Weiter' | Out-Null } }
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
        Explanation = 'Datenträger-Bereinigung entfernt temporäre Dateien, Update-Cache, Miniaturbilder, Shader-Cache und den Papierkorb. Gibt Speicherplatz frei.'
        Tip = 'Vor dem Löschen die Analyse ansehen, um zu prüfen, was entfernt wird.'
        HowTo = 'Toolbox -> „Datenträger bereinigen" -> Analyse starten -> Dateien auswählen -> löschen.'
        AISearchQuery = 'Windows 11 Datenträger bereinigen temporäre Dateien löschen Speicherplatz freigeben'
        NeedsAdmin = $false; HasGUI = $true; Action = { Show-SysPilotCleanupMenu; Read-SysPilotChoice 'Weiter' | Out-Null } }
    $tools += @{ Category = 'System bereinigen'; Key = 'bloat'; Name = 'Bloatware-Finder'
        Desc = 'Findet bekannte Werbe-Apps und Ressourcenfresser, deinstalliert und entfernt Datei-Reste.'
        Explanation = 'Der Bloatware-Finder sucht nach vorinstallierten Werbe-Apps und unnützen Programmen, die Ressourcen verbrauchen. Sie können deinstalliert werden.'
        Tip = 'Nur Apps deinstallieren, deren Zweck du kennst. Einige System-Apps sollten nicht entfernt werden.'
        HowTo = 'Toolbox -> „Bloatware-Finder" -> App auswählen -> deinstallieren.'
        AISearchQuery = 'Windows 11 Bloatware entfernen vorinstallierte Apps deinstallieren'
        NeedsAdmin = $false; HasGUI = $true; Action = { Show-SysPilotBloatManager } }
    $tools += @{ Category = 'System bereinigen'; Key = 'uwp'; Name = 'UWP-Apps ausmisten'
        Desc = 'Vorinstallierte Windows-Apps (Facebook, TikTok, Spiele-Werbung) entfernen.'
        Explanation = 'UWP-Apps (Universal Windows Platform) sind vorinstallierte Apps wie Facebook, TikTok oder Spiele-Werbung. Sie können entfernt werden, um Speicher und Ressourcen zu sparen.'
        Tip = 'Entferne nur Apps, die du wirklich nicht nutzt. Einige sind Teil von Windows.'
        HowTo = 'Toolbox -> „UWP-Apps ausmisten" -> App auswählen -> entfernen.'
        AISearchQuery = 'Windows 11 UWP Apps entfernen vorinstallierte Apps deinstallieren PowerShell'
        NeedsAdmin = $false; HasGUI = $true; Action = { Show-SysPilotUwpManager } }
    $tools += @{ Category = 'System bereinigen'; Key = 'shortcuts'; Name = 'Shortcut-Fixer'
        Desc = 'Findet tote Verknuepfungen auf Desktop/Startmenue (Ziel existiert nicht mehr) und loescht sie.'
        Explanation = 'Der Shortcut-Fixer sucht nach Verknüpfungen, deren Ziel nicht mehr existiert (z. B. deinstallierte Programme). Diese können sicher gelöscht werden.'
        Tip = 'Tote Verknüpfungen stören nicht, machen den Desktop aber unübersichtlich.'
        HowTo = 'Toolbox -> „Shortcut-Fixer" -> tote Verknüpfungen anzeigen -> löschen.'
        AISearchQuery = 'Windows 11 tote Verknüpfungen finden löschen Desktop Startmenü'
        NeedsAdmin = $false; HasGUI = $true; Action = { Show-SysPilotShortcutFixer; Read-SysPilotChoice 'Weiter' | Out-Null } }
    $tools += @{ Category = 'System bereinigen'; Key = 'largefiles'; Name = 'Grosse Dateien finden'
        Desc = 'Zeigt die groessten Dateien in Downloads/Dokumente/Videos - Platzfresser selbst loeschen.'
        Explanation = 'Große Dateien finden listet die größten Dateien in Downloads, Dokumenten, Videos und Bildern auf. Du entscheidest selbst, was gelöscht wird.'
        Tip = 'Besonders große Dateien (>500 MB) sind oft alte Installer oder Videos.'
        HowTo = 'Toolbox -> „Grosse Dateien finden" -> Datei auswählen -> im Explorer öffnen -> löschen.'
        AISearchQuery = 'Windows 11 große Dateien finden Speicherplatz analysieren Platzfresser'
        NeedsAdmin = $false; HasGUI = $true; Action = { Show-SysPilotLargeFiles; Read-SysPilotChoice 'Weiter' | Out-Null } }
    $tools += @{ Category = 'System bereinigen'; Key = 'emptyfolders'; Name = 'Leere Ordner finden'
        Desc = 'Findet leere Ordner im Benutzerprofil - Ueberreste deinstallierter Programme.'
        Explanation = 'Leere Ordner finden sucht nach Ordnern ohne Inhalt, die oft von deinstallierten Programmen zurückbleiben. Sie können sicher gelöscht werden.'
        Tip = 'Leere Ordner nehmen keinen Platz weg, machen die Struktur aber aufgeräumter.'
        HowTo = 'Toolbox -> „Leere Ordner finden" -> Ordner anzeigen -> löschen.'
        AISearchQuery = 'Windows 11 leere Ordner finden löschen Benutzerprofil'
        NeedsAdmin = $false; HasGUI = $true; Action = { Show-SysPilotEmptyFolders; Read-SysPilotChoice 'Weiter' | Out-Null } }
    $tools += @{ Category = 'System bereinigen'; Key = 'extensions'; Name = 'Browser-Erweiterungen pruefen'
        Desc = 'Findet doppelte KI-/Coupon-/Cleaner-Erweiterungen in Chrome, Edge, Brave, Opera, Firefox.'
        Explanation = 'Browser-Erweiterungen-Prüfer sucht nach doppelten oder verdächtigen Erweiterungen (KI-, Coupon-, Cleaner-Tools) in Chrome, Edge, Brave, Opera und Firefox.'
        Tip = 'Entferne Erweiterungen, die du nicht aktiv nutzt. Sie verbrauchen RAM und können Daten sammeln.'
        HowTo = 'Toolbox -> „Browser-Erweiterungen prüfen" -> Erweiterung auswählen -> deaktivieren/entfernen.'
        AISearchQuery = 'Windows 11 Browser Erweiterungen entfernen Chrome Edge Firefox doppelt'
        NeedsAdmin = $false; HasGUI = $true; Action = { Show-SysPilotExtensionManager } }

    # --- Analyse & Info ---
    $tools += @{ Category = 'Analyse & Info'; Key = 'report'; Name = 'System-Analyse'
        Desc = 'Was bremst meinen PC? Top RAM-Verbraucher, Warnungen, Empfehlungen.'
        Explanation = 'Die System-Analyse erkennt die größten RAM-Verbraucher, warnt vor Problemen und gibt konkrete Empfehlungen zur Optimierung.'
        Tip = 'Führe die Analyse regelmäßig durch, um Leistungseinbußen früh zu erkennen.'
        HowTo = 'Toolbox -> „System-Analyse" -> Scan starten -> Empfehlungen umsetzen.'
        AISearchQuery = 'Windows 11 Systemanalyse RAM Verbraucher Performance Probleme erkennen'
        NeedsAdmin = $false; HasGUI = $true; Action = { Show-SysPilotReport; Read-SysPilotChoice 'Weiter' | Out-Null } }
    $tools += @{ Category = 'Analyse & Info'; Key = 'hogs'; Name = 'Ressourcen-Fresser & Massnahmen'
        Desc = 'Die groessten Verbraucher mit konkreten Massnahmen, Howto-Links und Direkt-Aktionen.'
        Explanation = 'Ressourcen-Fresser zeigt die Programme, die am meisten CPU, RAM und Disk verbrauchen. Mit direkten Aktionen (deaktivieren, deinstallieren, Priorität ändern) und HowTo-Links.'
        Tip = 'Besonders Programme mit hoher CPU-Last über lange Zeit sind Kandidaten für Optimierung.'
        HowTo = 'Toolbox -> „Ressourcen-Fresser" -> Programm auswählen -> Aktion wählen.'
        AISearchQuery = 'Windows 11 Ressourcenfresser finden CPU RAM hoher Verbrauch Task Manager'
        NeedsAdmin = $false; HasGUI = $true; Action = { Show-SysPilotHogs; Read-SysPilotChoice 'Weiter' | Out-Null } }
    $tools += @{ Category = 'Analyse & Info'; Key = 'stats'; Name = 'Statistiken (Verlauf)'
        Desc = 'CPU/RAM/Temperatur-Verlauf aus den Autopilot-Messungen.'
        Explanation = 'Statistiken zeigen den Verlauf von CPU-, RAM- und Temperatur-Messungen aus den Autopilot-Läufen. So siehst du Trends und Engpässe.'
        Tip = 'Achte auf steigende Temperaturen über Tage – das kann auf Staub oder defekte Lüfter hindeuten.'
        HowTo = 'Toolbox -> „Statistiken (Verlauf)" -> Diagramm ansehen.'
        AISearchQuery = 'Windows 11 CPU RAM Temperatur Verlauf messen loggen überwachen'
        NeedsAdmin = $false; HasGUI = $true; Action = { Show-SysPilotStats; Read-SysPilotChoice 'Weiter' | Out-Null } }
    $tools += @{ Category = 'Analyse & Info'; Key = 'sysinfo'; Name = 'System-Info'
        Desc = 'CPU, RAM, GPU, Platten, Windows-Version, Laufzeit - kompakt auf einen Blick.'
        Explanation = 'System-Info zeigt alle wichtigen Hardware- und Systemdaten auf einen Blick: CPU, RAM, GPU, Festplatten, Windows-Version und Laufzeit.'
        Tip = 'Nützlich, wenn du Support benötigst oder Hardware aufrüsten möchtest.'
        HowTo = 'Toolbox -> „System-Info" -> Details ansehen.'
        AISearchQuery = 'Windows 11 Systeminformationen CPU RAM GPU Festplatte anzeigen'
        NeedsAdmin = $false; HasGUI = $true; Action = { Show-SysPilotSystemInfo; Read-SysPilotChoice 'Weiter' | Out-Null } }

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
