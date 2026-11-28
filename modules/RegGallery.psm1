# ======================================================================
# SysPilot RegGallery.psm1 - "Registry-Galerie": kuratierte .reg-Dateien
# nach Themen, Import/Export, Risiko-Scan, Backup vor dem Anwenden,
# Wiederherstellung und optionale KI-Sicherheitspruefung.
# ======================================================================

function Get-SysPilotRegGalleryDirs {
    $dirs = @()
    $repo = Join-Path (Split-Path $PSScriptRoot) 'reggallery'
    if (Test-Path $repo) { $dirs += $repo }
    $user = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'SysPilot\RegGallery'
    if (-not (Test-Path $user)) { New-Item -ItemType Directory -Path $user -Force | Out-Null }
    $dirs += $user
    return $dirs
}

function Read-SysPilotRegFile {
    <# Liest .reg (UTF-16LE-BOM, UTF-8 oder ANSI) als String-Array. #>
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        return [Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length-2) -split "`r?`n"
    }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return [Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length-3) -split "`r?`n"
    }
    # ANSI-Fallback
    return [Text.Encoding]::Default.GetString($bytes) -split "`r?`n"
}

function Get-SysPilotRegEntries {
    <# Parst eine .reg-Datei in strukturierte Eintraege. #>
    param([Parameter(Mandatory)][string]$Path)
    $lines = Read-SysPilotRegFile -Path $Path
    $entries = @()
    $section = $null
    $multi = $null  # laufende hex(...)-Mehrfachzeile
    foreach ($raw in $lines) {
        $line = $raw.Trim()
        if ($line -eq '' -or $line.StartsWith('Windows Registry Editor') -or $line.StartsWith(';')) { continue }
        if ($line -match '^\[(.+)\]$') {
            $section = $Matches[1].Trim()
            $entries += [pscustomobject]@{ Kind='Section'; Key=$section; Name=''; Value=''; Type='' }
            continue
        }
        if ($null -eq $section) { continue }
        if ($line -match '^-"') {
            # geloeschter Wert
            if ($line -match '^-"([^"]*)"=-') {
                $entries += [pscustomobject]@{ Kind='DeleteValue'; Key=$section; Name=$Matches[1]; Value=''; Type='' }
            } elseif ($line -match '^-\[') {
                $entries += [pscustomobject]@{ Kind='DeleteKey'; Key=$section; Name=''; Value=''; Type='' }
            }
            continue
        }
        if ($line -match '^"([^"]*)"=(.*)$') {
            $name = $Matches[1]; $rhs = $Matches[2].Trim()
            $type = 'Sz'; $value = $rhs
            if ($rhs -match '^(dword|DWORD):(.+)$') { $type='Dword'; $value=$Matches[2] }
            elseif ($rhs -match '^(qword|QWORD):(.+)$') { $type='Qword'; $value=$Matches[2] }
            elseif ($rhs -match '^(hex|HEX)\(([^)]*)\):(.*)$') { $type='Hex'; $value=$Matches[3] }
            elseif ($rhs -match '^(expand|EXPAND_SZ):(.+)$') { $type='ExpandSz'; $value=$Matches[2] }
            elseif ($rhs -match '^(multi|MULTI_SZ):(.+)$') { $type='MultiSz'; $value=$Matches[2] }
            if ($type -eq 'Hex' -and $rhs -notmatch '\),') { $multi = @{Key=$section;Name=$name;Type=$type;Value=$value} ; continue }
            $entries += [pscustomobject]@{ Kind='Set'; Key=$section; Name=$name; Value=$value; Type=$type }
            continue
        }
        if ($line -match '^@=(.*)$') {
            $rhs = $Matches[1].Trim()
            $entries += [pscustomobject]@{ Kind='Set'; Key=$section; Name='(Standard)'; Value=$rhs; Type='Sz' }
            continue
        }
        # hex-Mehrfachzeilen (mit Backslash am Zeilenende)
        if ($line.EndsWith('\') -and $null -ne $multi) {
            $multi.Value += ' ' + $line.TrimEnd('\').Trim()
            continue
        }
        if ($null -ne $multi) {
            $entries += [pscustomobject]@{ Kind='Set'; Key=$multi.Key; Name=$multi.Name; Value=$multi.Value; Type='Hex' }
            $multi = $null
            continue
        }
    }
    if ($null -ne $multi) {
        $entries += [pscustomobject]@{ Kind='Set'; Key=$multi.Key; Name=$multi.Name; Value=$multi.Value; Type='Hex' }
    }
    return $entries
}

function Get-SysPilotRegCategory {
    <# Ordnet einen Registry-Pfad einer Kategorie zu. #>
    param([Parameter(Mandatory)][string]$Key)
    $k = $Key.ToLower()
    if ($k -match 'shell|contextmenu|commandstore|context menu') { return 'Kontextmenue' }
    if ($k -match 'explorer|taskbar|startmenu|search|shell folders|user shell') { return 'Explorer & Taskleiste' }
    if ($k -match 'runonce|run\\|winlogon|services|currentcontrolset.services|image file execution|appinit|print\\monitors|lsa|sam\\') { return 'Autostart & Dienste' }
    if ($k -match 'privac|telemetry|datacollection|advertising|contentdelivery|capabilityaccess|consentstore|diagnostic|feedback|customer experience|allowedtel') { return 'Datenschutz' }
    if ($k -match 'firewall|security|defender|bitlocker|credential|lsass|policies.microsoft.windows.security|uac|enablelua') { return 'Sicherheit' }
    if ($k -match 'network|tcpip|dns|winsock|interfaces|netbt|lanman|dhcp') { return 'Netzwerk' }
    if ($k -match 'performance|prefetch|sysmain|memory management|videoplayer|multimedia|systemprofile|power\\') { return 'Leistung' }
    if ($k -match 'edge|chrome|firefox|browser|internet explorer|internet settings') { return 'Browser' }
    if ($k -match 'uninstall|appx|applications\\|immersive|startapps') { return 'Apps & Deinstallation' }
    if ($k -match 'windows\\currentversion\\themes|desktop|wallpaper|visual|transparen|colors|fonts|icon') { return 'Darstellung' }
    if ($k -match 'windowsupdate|windows update|wuau|usoclient|deliveryoptimization|bits') { return 'Windows Update' }
    if ($k -match 'software\\classes|file associations|mimetype|progid') { return 'Dateizuordnungen' }
    return 'Sonstiges'
}

function Get-SysPilotRegRisk {
    <# Heuristischer Risiko-Scan einer .reg-Datei.
       Gibt @{Score; Level; Reasons[]} zurueck. Score 0-100. #>
    param([Parameter(Mandatory)][string]$Path)
    $entries = @(Get-SysPilotRegEntries -Path $Path)
    $score = 0; $reasons = @()
    $hay = ($entries | ForEach-Object { "$($_.Key)|$($_.Name)|$($_.Value)" }) -join "`n"
    $hl = $hay.ToLower()

    # Kritisch: Autostart-Persistenz, Sicherheitsmechanismen, Systemstart
    $crit = @(
        @{P='currentversion\\run'; R='Autostart-Run-Key'},
        @{P='winlogon'; R='Winlogon (Logon/Shell)'},
        @{P='image file execution options'; R='IFEO (Debug-Hijack)'},
        @{P='appinit_dlls'; R='AppInit_DLLs'},
        @{P='print\\monitors'; R='Print-Monitor'},
        @{P='lsa\\'; R='LSA'},
        @{P='sam\\'; R='SAM'},
        @{P='currentcontrolset\\control\\session manager'; R='Session Manager'},
        @{P='bootexecute'; R='BootExecute'},
        @{P='currentversion\\policies\\system'; R='System-Policy'},
        @{P='enablelua'; R='UAC-Einstellung'},
        @{P='disableantivirus'; R='AV-Deaktivierung'},
        @{P='bitlocker'; R='BitLocker'},
        @{P='credential'; R='Anmeldeinformationen'},
        @{P='security\\policies'; R='Sicherheitsrichtlinien'},
        @{P='hosts'; R='Hosts-Datei'},
        @{P='firewall'; R='Firewall-Regeln'},
        @{P='wininit'; R='Wininit'},
        @{P='currentversion\\winlogonnotify'; R='Winlogon-Notify'}
    )
    foreach ($c in $crit) {
        if ($hl -match [regex]::Escape($c.P)) { $score += 35; $reasons += "KRITISCH: $($c.R)" }
    }
    # Warnung: Dienste, Netzwerk, Update, Deinstall
    $warn = @(
        @{P='currentcontrolset\\services'; R='Dienst-Konfiguration'},
        @{P='tcpip'; R='TCP/IP-Konfiguration'},
        @{P='dns'; R='DNS'},
        @{P='netbt'; R='NetBIOS'},
        @{P='lanman'; R='Lanman/Server'},
        @{P='windowsupdate'; R='Windows-Update'},
        @{P='wuau'; R='WU-Client'},
        @{P='deliveryoptimization'; R='Delivery Optimization'},
        @{P='uninstall'; R='Deinstallations-Eintrag'},
        @{P='appx'; R='Appx-Paket'},
        @{P='shell\\open'; R='Shell-Open'},
        @{P='shell\\runas'; R='Shell-RunAs'},
        @{P='exefile'; R='EXE-Dateizuordnung'},
        @{P='cmdfile'; R='CMD-Dateizuordnung'},
        @{P='batfile'; R='BAT-Dateizuordnung'},
        @{P='scrfile'; R='SCR-Dateizuordnung'},
        @{P='piffile'; R='PIF-Dateizuordnung'},
        @{P='deletekey'; R='Loescht Registry-Keys'}
    )
    foreach ($w in $warn) {
        if ($hl -match [regex]::Escape($w.P)) { $score += 12; $reasons += "ACHTUNG: $($w.R)" }
    }
    # Delete-Operationen generell pruefen
    $delKeys = @($entries | Where-Object { $_.Kind -eq 'DeleteKey' }).Count
    $delVals = @($entries | Where-Object { $_.Kind -eq 'DeleteValue' }).Count
    if ($delKeys -gt 0) { $score += 15 * [math]::Min($delKeys,3); $reasons += "ACHTUNG: $delKeys Key(s) werden geloescht" }
    if ($delVals -gt 10) { $score += 10; $reasons += "ACHTUNG: $delVals Wert(e) werden geloescht" }
    # HKLM/HKCR ist riskanter als HKCU
    if ($hl -match 'hklm|hkey_local_machine|hkcr|hkey_classes_root|hku') { $score += 10; $reasons += 'SYSTEM- oder KLASSEN-Root (Admin, global)' }
    $score = [math]::Min($score, 100)
    $level = if ($score -ge 60) { 'KRITISCH' } elseif ($score -ge 30) { 'VORSICHT' } elseif ($score -ge 10) { 'OK-mit-Hinweisen' } else { 'SICHER' }
    return @{ Score=$score; Level=$level; Reasons=$reasons; Entries=$entries.Count; Categories=@($entries | ForEach-Object { Get-SysPilotRegCategory $_.Key } | Sort-Object -Unique) }
}

function Get-SysPilotRegGalleryFiles {
    $files = @()
    foreach ($dir in (Get-SysPilotRegGalleryDirs)) {
        if (Test-Path $dir) {
            $files += Get-ChildItem -Path $dir -Filter *.reg -File -ErrorAction SilentlyContinue
        }
    }
    return @($files | Sort-Object Name -Unique)
}

function Import-SysPilotRegFile {
    <# Kopiert eine .reg-Datei in die User-Galerie. #>
    param([Parameter(Mandatory)][string]$SourcePath)
    if (-not (Test-Path $SourcePath)) { Write-Host "  Datei nicht gefunden: $SourcePath" -ForegroundColor Red; return $null }
    $userDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'SysPilot\RegGallery'
    New-Item -ItemType Directory -Path $userDir -Force | Out-Null
    $dest = Join-Path $userDir (Split-Path $SourcePath -Leaf)
    Copy-Item -Path $SourcePath -Destination $dest -Force
    Write-Host "  Importiert: $dest" -ForegroundColor Green
    return $dest
}

function Backup-SysPilotRegFile {
    <# Exportiert alle betroffenen Keys einer .reg-Datei als Backup. #>
    param([Parameter(Mandatory)][string]$RegPath)
    $entries = @(Get-SysPilotRegEntries -Path $RegPath)
    $keys = @{}
    foreach ($e in $entries) {
        if ($e.Kind -eq 'Section') {
            $k = $e.Key
            # naechsten existierenden Vorfahren finden
            $cur = $k
            while ($cur -and $cur.Length -gt 4 -and -not (Test-Path $cur)) {
                $cur = Split-Path $cur -Parent
                if ($cur -match 'HKEY_|HKCU:|HKLM:|HKCR:|HKU:') { break }
            }
            if ($cur -and (Test-Path $cur)) { $keys[$cur] = $true }
        }
    }
    if ($keys.Count -eq 0) { return $null }
    $bkDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ("SysPilot\reg-backups\" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $bkDir -Force | Out-Null
    $files = @()
    foreach ($k in $keys.Keys) {
        $safe = ($k -replace '[:\\/]','_')
        $f = Join-Path $bkDir "$safe.reg"
        & reg.exe export "$k" "$f" /y 2>$null | Out-Null
        if (Test-Path $f) { $files += $f }
    }
    return @{ Dir=$bkDir; Files=$files; Count=$keys.Count }
}

function Invoke-SysPilotRegApply {
    <# Wendet eine .reg-Datei an (mit Backup + Bestaetigung). #>
    param([Parameter(Mandatory)][string]$RegPath, [switch]$NoConfirm)
    if (-not (Test-Path $RegPath)) { Write-Host "  Datei nicht gefunden." -ForegroundColor Red; return }
    $risk = Get-SysPilotRegRisk -Path $RegPath
    Write-Host "  Datei: $(Split-Path $RegPath -Leaf)" -ForegroundColor Cyan
    Write-Host "  Eintraege: $($risk.Entries) | Kategorien: $($risk.Categories -join ', ')" -ForegroundColor DarkGray
    Write-Host "  Risiko: $($risk.Level) (Score $($risk.Score))" -ForegroundColor $(if ($risk.Score -ge 30) {'Yellow'} else {'Green'})
    foreach ($r in $risk.Reasons) { Write-Host "   ! $r" -ForegroundColor DarkYellow }
    if ($risk.Score -ge 30 -and -not $NoConfirm) {
        if (-not (Confirm-SysPilot "Risiko '$($risk.Level)' - trotzdem anwenden?`n$(Split-Path $RegPath -Leaf)")) { return }
    } elseif (-not $NoConfirm) {
        if (-not (Confirm-SysPilot "'$($risk.Level)' - .reg-Datei anwenden?`n$(Split-Path $RegPath -Leaf)")) { return }
    }
    # Admin-Check fuer HKLM/HKCR/HKU
    $needsAdmin = (Get-Content $RegPath -Encoding Unicode -ErrorAction SilentlyContinue | Select-String -Pattern 'HKEY_LOCAL_MACHINE|HKEY_CLASSES_ROOT|HKEY_USERS' -Quiet)
    if (-not $needsAdmin) { $needsAdmin = (Select-String -Path $RegPath -Pattern 'HKEY_LOCAL_MACHINE|HKEY_CLASSES_ROOT|HKEY_USERS' -Quiet -ErrorAction SilentlyContinue) }
    if ($needsAdmin -and -not (Test-SysPilotAdmin)) {
        Write-Host '  Hinweis: enthaelt System-Keys - Admin noetig. SysPilot elevated neu starten?' -ForegroundColor Yellow
        if (Confirm-SysPilot 'Als Administrator neu starten?') { Restart-SysPilotElevated }
        return
    }
    $bk = Backup-SysPilotRegFile -RegPath $RegPath
    Write-Host "  Backup: $($bk.Dir) ($($bk.Count) Keys)" -ForegroundColor DarkGray
    & reg.exe import $RegPath 2>&1 | ForEach-Object { Write-Host "  $_" }
    $code = $LASTEXITCODE
    if ($code -eq 0) {
        Write-Host "  [OK] .$($RegPath | Split-Path -Leaf) importiert." -ForegroundColor Green
        Write-SysPilotLog "RegGallery applied $RegPath"
    } else {
        Write-Host "  [!] reg import lieferte Exit-Code $code" -ForegroundColor Red
    }
    return @{ Ok=($code -eq 0); Backup=$bk }
}

function Restore-SysPilotRegBackup {
    <# Stellt ein Backup-Verzeichnis (mit .reg-Exports) wieder her. #>
    param([Parameter(Mandatory)][string]$BackupDir)
    if (-not (Test-Path $BackupDir)) { Write-Host "  Backup-Ordner nicht gefunden." -ForegroundColor Red; return }
    $files = @(Get-ChildItem $BackupDir -Filter *.reg -File)
    if ($files.Count -eq 0) { Write-Host "  Keine .reg-Dateien im Backup." -ForegroundColor Yellow; return }
    Write-Host "  $($files.Count) Backup-Datei(en) in $BackupDir" -ForegroundColor Cyan
    if (-not (Confirm-SysPilot 'Backup wiederherstellen? (ueberschreibt aktuelle Werte)')) { return }
    $ok = 0; $fail = 0
    foreach ($f in $files) {
        & reg.exe import $f.FullName 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $ok++ } else { $fail++ }
    }
    Write-Host "  Wiederhergestellt: $ok OK, $fail Fehler" -ForegroundColor $(if ($fail -eq 0) {'Green'} else {'Yellow'})
}

function Show-SysPilotRegBackups {
    <# Liste aller Backup-Ordner mit Wiederherstellen-Option. #>
    $base = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'SysPilot\reg-backups'
    if (-not (Test-Path $base)) { Write-Host '  Noch keine Backups vorhanden.' -ForegroundColor DarkGray; Read-SysPilotChoice 'Enter' | Out-Null; return }
    $dirs = @(Get-ChildItem $base -Directory | Sort-Object Name -Descending | Select-Object -First 30)
    if ($dirs.Count -eq 0) { Write-Host '  Noch keine Backups vorhanden.' -ForegroundColor DarkGray; Read-SysPilotChoice 'Enter' | Out-Null; return }
    $items = @()
    foreach ($d in $dirs) {
        $n = @(Get-ChildItem $d.FullName -Filter *.reg -File).Count
        $items += @{ Label = "$($d.Name)  ($n Dateien)"; Color = 'White'; Tag = $d.FullName }
    }
    $items += @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = $null }
    $sel = Show-SysPilotArrowMenu -Items $items -Title 'Registry-Backups' -Footer 'Enter = wiederherstellen, Esc = zurueck'
    if ($sel) { Restore-SysPilotRegBackup -BackupDir $sel }
}

function Invoke-SysPilotAiRegReview {
    <# Optionale KI-Sicherheitspruefung einer .reg-Datei. #>
    param([Parameter(Mandatory)][string]$RegPath)
    if (-not (Get-Command Invoke-SysPilotAiChat -ErrorAction SilentlyContinue)) {
        Write-Host '  KI-Chat nicht verfuegbar (AiAssist-Modul fehlt).' -ForegroundColor Yellow
        return
    }
    $entries = @(Get-SysPilotRegEntries -Path $RegPath)
    $preview = ($entries | Select-Object -First 60 | ForEach-Object { "$($_.Kind) $($_.Key) | $($_.Name) = $($_.Value)" }) -join "`n"
    $prompt = @"
Du bist ein Windows-Registry-Sicherheitspruefer. Analysiere diese .reg-Datei und antworte KURZ:
1) Ist sie sicher, Vorsicht oder gefaehrlich?
2) Was genau macht sie (1-2 Saetze)?
3) Gibt es versteckte Risiken (Autostart, Sicherheitsmechanismen, Datenverlust)?
Antworte auf Deutsch, max. 6 Zeilen.

DATEI: $(Split-Path $RegPath -Leaf)
$preview
"@
    try {
        $r = Invoke-SysPilotAiChat -Prompt $prompt -System 'Du bist ein Windows-Registry-Sicherheitspruefer. Antworte knapp auf Deutsch.' -MaxTokens 600 -TimeoutSec 90
        if ($r.Ok) {
            Write-Host "`n  --- KI-Bewertung ---" -ForegroundColor Magenta
            Write-Host "  $($r.Text)" -ForegroundColor White
            Write-Host "  ---------------------`n" -ForegroundColor Magenta
        } else {
            Write-Host "  KI-Pruefung fehlgeschlagen: $($r.Error)" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  KI-Pruefung fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Show-SysPilotRegGallery {
    <# Hauptmenue der Registry-Galerie. #>
    while ($true) {
        $files = @(Get-SysPilotRegGalleryFiles)
        $items = @()
        if ($files.Count -eq 0) {
            $items += @{ Label = '(Galerie ist leer - unten Import/URL)'; Color = 'DarkGray'; Tag = $null }
        }
        foreach ($f in $files) {
            $risk = Get-SysPilotRegRisk -Path $f.FullName
            $col = switch ($risk.Level) { 'KRITISCH' {'Red'} 'VORSICHT' {'Yellow'} 'OK-mit-Hinweisen' {'DarkYellow'} default {'Green'} }
            $loc = if ($f.FullName -like '*RegGallery*' -and $f.DirectoryName -match 'Local') { ' [user]' } else { '' }
            $items += @{ Label = ("{0,-16} {1,-30} {2,3} Eintr.  {3}" -f $risk.Level, $f.Name, $risk.Entries, ($risk.Categories -join ',')); Color = $col; Tag = $f.FullName }
        }
        $items += @{ Label = '---'; Color = 'DarkGray'; Tag = $null }
        $items += @{ Label = '>>> DATEI IMPORTIEREN (.reg von lokal)'; Color = 'Cyan'; Tag = 'import' }
        $items += @{ Label = '>>> URL LADEN (.reg aus dem Web)'; Color = 'Cyan'; Tag = 'url' }
        $items += @{ Label = '>>> BACKUPS VERWALTEN / WIEDERHERSTELLEN'; Color = 'Cyan'; Tag = 'backups' }
        $items += @{ Label = '>>> ERSTEINRICHTUNG (Herbert-Assist)'; Color = 'Cyan'; Tag = 'setup' }
        $items += @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = $null }
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'SysPilot Registry-Galerie' -Footer 'Pfeiltasten, Enter = auswaehlen, Esc = zurueck'
        if ($null -eq $sel) { return }
        if ($sel -eq 'import') {
            $src = Read-SysPilotInput 'Pfad zur .reg-Datei (z.B. C:\Users\...\tweak.reg):'
            if ($src -and (Test-Path $src)) {
                $dest = Import-SysPilotRegFile -SourcePath $src
                if ($dest) {
                    $r = Get-SysPilotRegRisk -Path $dest
                    Write-Host "  Risiko: $($r.Level) ($($r.Entries) Eintraege, $($r.Categories -join ', '))" -ForegroundColor $(if ($r.Score -ge 30) {'Yellow'} else {'Green'})
                    foreach ($reason in $r.Reasons) { Write-Host "   ! $reason" -ForegroundColor DarkYellow }
                }
            } else { Write-Host '  Ungueltiger Pfad.' -ForegroundColor Red }
            Read-SysPilotChoice 'Enter = weiter' | Out-Null
            continue
        }
        if ($sel -eq 'url') {
            $u = Read-SysPilotInput 'URL zur .reg-Datei:'
            if ($u) {
                $tmp = Join-Path $env:TEMP ("regdl_" + [Guid]::NewGuid().ToString('N').Substring(0,8) + '.reg')
                try {
                    Invoke-SysPilotSmartFileDownload -Uri $u -OutFile $tmp -Label 'Reg-Datei' | Out-Null
                    if (Test-Path $tmp) { Import-SysPilotRegFile -SourcePath $tmp | Out-Null }
                } catch { Write-Host "  Download fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Red }
            }
            Read-SysPilotChoice 'Enter = weiter' | Out-Null
            continue
        }
        if ($sel -eq 'backups') { Show-SysPilotRegBackups; continue }
        if ($sel -eq 'setup') {
            Show-SysPilotStepGuide -Title 'Registry-Galerie: Ersteinrichtung' -DoneText 'Ersteinrichtung verstanden - Galerie ist bereit.' -Steps @(
                @{ T='Willkommen in der Registry-Galerie'; Hint='Hier werden .reg-Dateien nach Themen kuratiert und sicher angewendet.' },
                @{ T='Woher kommen die Dateien?'; Hint='Zwei Quellen: der mitgelieferte Kuratierungs-Ordner (reggallery) und dein eigener Import-Ordner.' },
                @{ T='Dein Import-Ordner'; Hint='%LOCALAPPDATA%\SysPilot\RegGallery - per "DATEI IMPORTIEREN" oder "URL LADEN" fuellen.' },
                @{ T='Automatische Einordnung'; Hint='Jede Datei wird kategorisiert (Kontextmenue, Explorer, Datenschutz, Sicherheit, Netzwerk, Leistung, Browser, Apps, Update...) und bekommt einen Risiko-Score 0-100.' },
                @{ T='Risiko-Level'; Hint='SICHER = unkritisch, OK-mit-Hinweisen, VORSICHT = Dienste/Netzwerk/Updates, KRITISCH = Autostart/Sicherheit/Boot.' },
                @{ T='Backup ist Pflicht'; Hint='Vor jedem Anwenden werden die betroffenen Registry-Keys automatisch exportiert nach %LOCALAPPDATA%\SysPilot\reg-backups\<zeitstempel>.' },
                @{ T='Wiederherstellen'; Hint='Menue > BACKUPS VERWALTEN > Ordner waehlen > Enter - ueberschreibt die aktuellen Werte mit dem Stand davor.' },
                @{ T='Sicherer Ablauf fuer Web-.reg-Dateien'; Hint='Erst importieren, dann Risiko-Scan + optional KI-Pruefung (Herbert) lesen, ERST dann anwenden.' },
                @{ T='Tipp: Tweak-Studio'; Hint='Fuer haeufige Einzel-Tweaks (Kontextmenue, Taskleiste, Leistung) ist das Tweak-Studio bequemer - gleiche Backup-Mechanik.' }
            )
            continue
        }
        if ($sel -and (Test-Path $sel)) {
            $act = Show-SysPilotArrowMenu -Items @(
                @{ Label = 'Ansehen (Eintraege)'; Color = 'White'; Tag = 'view' },
                @{ Label = 'Risiko-Scan'; Color = 'Yellow'; Tag = 'risk' },
                @{ Label = 'KI-Sicherheitspruefung'; Color = 'Magenta'; Tag = 'ai' },
                @{ Label = 'ANWENDEN (mit Backup)'; Color = 'Green'; Tag = 'apply' },
                @{ Label = 'Datei-Oeffnen (Editor)'; Color = 'DarkGray'; Tag = 'open' },
                @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = $null }
            ) -Title (Split-Path $sel -Leaf) -Footer 'Enter = auswaehlen'
            if ($null -eq $act) { continue }
            switch ($act.Tag) {
                'view'  {
                    $e = @(Get-SysPilotRegEntries -Path $sel)
                    $e | Select-Object -First 200 | ForEach-Object { Write-Host ("  {0,-12} {1} | {2} = {3}" -f $_.Kind, $_.Key, $_.Name, $_.Value) -ForegroundColor DarkGray }
                    if ($e.Count -gt 200) { Write-Host "  ... und $($e.Count-200) weitere" -ForegroundColor DarkGray }
                    Read-SysPilotChoice 'Enter = weiter' | Out-Null
                }
                'risk'  {
                    $r = Get-SysPilotRegRisk -Path $sel
                    Write-Host "`n  Risiko: $($r.Level) (Score $($r.Score))" -ForegroundColor $(if ($r.Score -ge 30) {'Yellow'} else {'Green'})
                    Write-Host "  Eintraege: $($r.Entries) | Kategorien: $($r.Categories -join ', ')" -ForegroundColor Cyan
                    foreach ($reason in $r.Reasons) { Write-Host "   ! $reason" -ForegroundColor DarkYellow }
                    if ($r.Reasons.Count -eq 0) { Write-Host '   Keine Auffaelligkeiten.' -ForegroundColor Green }
                    Read-SysPilotChoice 'Enter = weiter' | Out-Null
                }
                'ai'    { Invoke-SysPilotAiRegReview -RegPath $sel; Read-SysPilotChoice 'Enter = weiter' | Out-Null }
                'apply' { Invoke-SysPilotRegApply -RegPath $sel | Out-Null }
                'open'  { Start-Process notepad.exe -ArgumentList "`"$sel`"" }
            }
        }
    }
}

Export-ModuleMember -Function Get-SysPilotRegGalleryDirs, Get-SysPilotRegEntries,
    Get-SysPilotRegCategory, Get-SysPilotRegRisk, Get-SysPilotRegGalleryFiles,
    Import-SysPilotRegFile, Backup-SysPilotRegFile, Invoke-SysPilotRegApply,
    Restore-SysPilotRegBackup, Show-SysPilotRegBackups, Show-SysPilotRegGallery,
    Invoke-SysPilotAiRegReview, Read-SysPilotRegFile
