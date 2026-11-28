#requires -Version 5.1
<#
    CareCenter.psm1 - eigene Systempflege-Werkzeuge (konzeptionell
    angelehnt an klassische Cleaner-Suiten, komplett eigenimplementiert):
      - Registry-Cleaner (Scan + Backup + selektives Loeschen)
      - File-Shredder (Ueberschreiben + Loeschen, Ordner-Modus)
      - Privacy-Erase (Browser-/Windows-Spuren, Checkboxen)
      - Disk-Optimize (Analyze/Optimize je Medium)
      - Aktivitaets-Timeline (Recent Files, Power-Events, USB-Historie)
      - Passwort-Generator (WPF-Dialog)
      - Boot-Analyse (Diagnostics-Performance Events)
    ASCII-sicher, PS 5.1, keine Fremd-Assets.
#>

# =====================================================================
# 1) REGISTRY-CLEANER
# =====================================================================

function Get-SysPilotRegistryJunkItems {
    <# Findet Registry-Leichen - konservativ, nur Nachweise:
       a) Uninstall-Eintraege, deren InstallLocation/DisplayIcon nicht
          mehr existiert
       b) MUICache-Eintraege, deren Ziel-exe nicht mehr existiert
       c) MRU-Listen (RunMRU, WordWheelQuery, TypedPaths, ComDlg32-MRUs,
          RecentDocs, Search RecentApps) - immer "vohanden" (Privacy)
       Gibt @{Category;KeyPath;ValueName;Data;Reason;Kind} zurueck. #>
    $items = New-Object System.Collections.ArrayList
    function Add-Item($cat,$key,$vn,$data,$reason,$kind) {
        [void]$items.Add([pscustomobject]@{ Category=$cat; KeyPath=$key; ValueName=$vn; Data=$data; Reason=$reason; Kind=$kind })
    }

    # --- a) Tote Uninstall-Eintraege ---
    $uninstallRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($pat in $uninstallRoots) {
        foreach ($u in @(Get-ItemProperty $pat -ErrorAction SilentlyContinue)) {
            $loc = $u.InstallLocation; $di = $u.DisplayIcon
            $dead = $false; $why = ''
            if ($loc -and (Test-Path $loc)) { $dead = $false }
            elseif ($loc -and -not (Test-Path $loc)) { $dead = $true; $why = "InstallLocation fehlt: $loc" }
            elseif ($di) {
                $d = ($di -split ',')[0].Trim('"')
                if ($d -match '^[A-Za-z]:\\' -and -not (Test-Path $d)) { $dead = $true; $why = "DisplayIcon fehlt: $d" }
            }
            if ($dead -and $u.DisplayName) {
                Add-Item 'Uninstall-Leichen' $u.PSPath.Replace('Microsoft.PowerShell.Core\Registry::','') ($u.PSChildName) $u.DisplayName $why 'uninstall'
            }
        }
    }

    # --- b) MUICache mit totem Ziel ---
    $muiRoots = @(
        'HKCU:\SOFTWARE\Classes\Local Settings\Software\Microsoft\Windows\Shell\MuiCache',
        'HKCU:\SOFTWARE\Classes\WOW6432Node\Local Settings\Software\Microsoft\Windows\Shell\MuiCache'
    )
    foreach ($mr in $muiRoots) {
        $mk = Get-Item $mr -ErrorAction SilentlyContinue
        if (-not $mk) { continue }
        foreach ($vn in @($mk.GetValueNames())) {
            if ($vn -match '\.exe$' -and $vn -match '^[A-Za-z]:\\') {
                if (-not (Test-Path $vn)) {
                    Add-Item 'MUICache-Leichen' $mr $vn '' "Ziel fehlt: $vn" 'value'
                }
            }
        }
    }

    # --- c) MRU-/Verlaufs-Listen (Privacy-Kategorie, immer loeschbar) ---
    $mruDefs = @(
        @{ Cat='MRU: Run-Dialog';        Key='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU';                              Pat='MRUListEx|.*' },
        @{ Cat='MRU: WordWheelQuery';    Key='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\WordWheelQuery';                     Pat='MRUListEx|.*' },
        @{ Cat='MRU: TypedPaths';        Key='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\TypedPaths';                         Pat='url\d+' },
        @{ Cat='MRU: Open/Save-Dialog';  Key='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\ComDlg32\OpenSavePidlMRU';           Pat='.*' },
        @{ Cat='MRU: CIDSize';           Key='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\ComDlg32\CIDSizeMRU';                Pat='.*' },
        @{ Cat='MRU: Letzte Dokumente';  Key='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\RecentDocs';                        Pat='.*' },
        @{ Cat='MRU: Explorer-Verlauf';  Key='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\ComDlg32\LastVisitedPidlMRU';       Pat='.*' },
        @{ Cat='MRU: Start-Suche';       Key='HKCU:\Software\Microsoft\Windows\CurrentVersion\Search\RecentApps';                           Pat='.*' },
        @{ Cat='MRU: Internet Explorer'; Key='HKCU:\Software\Microsoft\Internet Explorer\TypedURLs';                                         Pat='url\d+' }
    )
    foreach ($d in $mruDefs) {
        $k = Get-Item $d.Key -ErrorAction SilentlyContinue
        if (-not $k) { continue }
        $names = @($k.GetValueNames() | Where-Object { $_ -match $d.Pat -and $_ -notmatch '^(MRUListEx|PSPath|PSParentPath|PSChildName|PSDrive|PSProvider)$' })
        if ($names.Count -gt 0) {
            Add-Item $d.Cat $d.Key '*' '' "$($names.Count) Eintrag/Eintraege" 'mru'
        }
    }

    # --- d) FeatureUsage-Telemetrie (App-Nutzung) ---
    $fu = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FeatureUsage'
    foreach ($sub in 'AppSwitched','AppLaunch','ShowJumpView') {
        $fk = "$fu\$sub"
        if (Test-Path $fk) {
            $k = Get-Item $fk -ErrorAction SilentlyContinue
            $cnt = @($k.GetValueNames()).Count
            if ($cnt -gt 0) { Add-Item 'Telemetrie: FeatureUsage' $fk '*' '' "$cnt App-Nutzungs-Eintraege" 'telemetry' }
        }
    }

    return $items
}

function Backup-SysPilotRegistryJunk {
    <# Exportiert die betroffenen Schluesse als .reg-Backup. #>
    param([object[]]$Items, [string]$OutDir)
    if (-not $OutDir) { $OutDir = Join-Path $env:LOCALAPPDATA 'SysPilot\regbackups' }
    if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $files = @()
    $keys = @($Items | ForEach-Object { $_.KeyPath } | Sort-Object -Unique)
    foreach ($kp in $keys) {
        $ps = $kp -replace '^HKCU:\\','HKCU:' -replace '^HKLM:\\','HKLM:'
        $safe = ($kp -replace '[:\\]','_')
        $regPath = "Registry::$kp"
        $out = Join-Path $OutDir "$stamp-$safe.reg"
        try {
            & reg.exe export "$ps" "$out" /y 2>$null | Out-Null
            if (Test-Path $out) { $files += $out }
        } catch {}
    }
    return $files
}

function Invoke-SysPilotRegistryClean {
    <# Fuehrt das Loeschen der selektierten Junk-Items aus.
       - 'uninstall': ganzer Uninstall-Key wird entfernt
       - 'value': einzelner Wert wird entfernt
       - 'mru'/'telemetry': alle Werte des Keys werden geleert
       Rueckgabe: @{Ok;Removed;Failed;Backup}. #>
    param([object[]]$Items)
    $res = @{ Ok=$true; Removed=0; Failed=@(); Backup=@() }
    $res.Backup = @(Backup-SysPilotRegistryJunk -Items $Items)
    foreach ($it in $Items) {
        try {
            switch ($it.Kind) {
                'uninstall' {
                    $kp = $it.KeyPath
                    if (Test-Path "Registry::$kp") { Remove-Item "Registry::$kp" -Recurse -Force -ErrorAction Stop; $res.Removed++ }
                }
                'value' {
                    $k = Get-Item "Registry::$($it.KeyPath)" -ErrorAction Stop
                    if ($k.GetValue($it.ValueName, $null) -ne $null) { Remove-ItemProperty -Path "Registry::$($it.KeyPath)" -Name $it.ValueName -Force -ErrorAction Stop; $res.Removed++ }
                }
                { $_ -in @('mru','telemetry') } {
                    $k = Get-Item "Registry::$($it.KeyPath)" -ErrorAction Stop
                    foreach ($vn in @($k.GetValueNames())) {
                        if ($vn -notmatch '^(PSPath|PSParentPath|PSChildName|PSDrive|PSProvider)$') {
                            Remove-ItemProperty -Path "Registry::$($it.KeyPath)" -Name $vn -Force -ErrorAction SilentlyContinue
                            $res.Removed++
                        }
                    }
                }
            }
        } catch { $res.Failed += "$($it.Category)/$($it.ValueName): $($_.Exception.Message)" }
    }
    if ($res.Failed.Count -gt 0) { $res.Ok = $false }
    return $res
}

function Show-SysPilotRegistryCleaner {
    <# Registry-Cleaner: Scan -> Liste -> Auswahl -> Backup -> Loeschen. #>
    Write-Host ''
    Write-Host '  === REGISTRY-CLEANER ===' -ForegroundColor Cyan
    Write-Host '  Scanne Registry (Uninstall-Leichen, MUICache, MRU/Verlauf, Telemetrie) ...' -ForegroundColor DarkGray
    $items = @(Get-SysPilotRegistryJunkItems)
    if ($items.Count -eq 0) { Write-Host '  [OK] Keine Registry-Leichen gefunden.' -ForegroundColor Green; Read-SysPilotChoice 'Weiter' | Out-Null; return }

    $byCat = $items | Group-Object Category | Sort-Object Count -Descending
    Write-Host ''
    Write-Host ("  {0} Fund(e) in {1} Kategorie(n):" -f $items.Count, $byCat.Count) -ForegroundColor Yellow
    $idx = 0
    $map = @()
    foreach ($g in $byCat) {
        Write-Host ("    [{0,3}] {1} ({2})" -f $idx, $g.Name, $g.Count) -ForegroundColor White
        foreach ($it in $g.Group) { $map += @{ Idx=$idx; Item=$it } }
        $idx++
    }
    Write-Host ''
    Write-Host '  Auswahl: Nummer, "all", "none", "mru" (nur Verlauf/Privacy), Enter = alle' -ForegroundColor DarkGray
    $sel = Read-SysPilotInput 'Auswahl' 'all'
    $selItems = @()
    if ($sel -eq 'all' -or $sel -eq '') { $selItems = $items }
    elseif ($sel -eq 'mru') { $selItems = @($items | Where-Object { $_.Kind -in @('mru','telemetry') }) }
    elseif ($sel -eq 'none') { Read-SysPilotChoice 'Weiter' | Out-Null; return }
    else {
        $nums = @($sel -split '[,\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
        $selItems = @($map | Where-Object { $nums -contains $_.Idx } | ForEach-Object { $_.Item })
        if ($selItems.Count -eq 0) { Write-Host '  Ungueltige Auswahl.' -ForegroundColor Red; Read-SysPilotChoice 'Weiter' | Out-Null; return }
    }

    Write-Host ''
    Write-Host ("  {0} Eintraege werden entfernt. Vorher wird ein .reg-Backup erstellt." -f $selItems.Count) -ForegroundColor Yellow
    foreach ($s in ($selItems | Select-Object -First 10)) {
        $d = if ($s.Data) { " - $($s.Data)" } else { '' }
        Write-Host "    - $($s.Category): $($s.Reason)$d" -ForegroundColor DarkGray
    }
    if ($selItems.Count -gt 10) { Write-Host "    ... und $($selItems.Count-10) weitere" -ForegroundColor DarkGray }
    if (-not (Confirm-SysPilot "Registry-Clean mit $($selItems.Count) Eintrag/Eintraegen ausfuehren?")) { Write-Host '  Abgebrochen.' -ForegroundColor DarkGray; Read-SysPilotChoice 'Weiter' | Out-Null; return }

    $r = Invoke-SysPilotRegistryClean -Items $selItems
    if ($r.Backup.Count -gt 0) { Write-Host "  Backup: $($r.Backup -join ', ')" -ForegroundColor DarkCyan }
    Write-Host ("  [OK] {0} Eintraege entfernt." -f $r.Removed) -ForegroundColor Green
    foreach ($f in $r.Failed) { Write-Host "  [!] $f" -ForegroundColor Red }
    Read-SysPilotChoice 'Weiter' | Out-Null
}

# =====================================================================
# 2) FILE-SHREDDER
# =====================================================================

function Invoke-SysPilotFileShred {
    <# Ueberschreibt eine Datei mit Zufallsdaten (N-Pass) und loescht sie.
       Standard: 3 Passen (2x Zufall, 1x Nullen). Fortschritt pro Pass.
       Rueckgabe @{Ok;Error}. #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$Passes = 3,
        [object]$ProgressQueue = $null,
        [string]$Label = 'Shred'
    )
    $res = @{ Ok=$false; Error='' }
    if (-not (Test-Path $Path)) { $res.Error = 'Datei nicht gefunden'; return $res }
    $fi = Get-Item $Path -Force
    if ($fi.PSIsContainer) { $res.Error = 'Ist ein Ordner - Ordner-Modus nutzen'; return $res }
    if ($fi.IsReadOnly) { try { $fi.IsReadOnly = $false } catch {} }
    $len = $fi.Length
    if ($len -eq 0) { Remove-Item $Path -Force; $res.Ok=$true; return $res }
    $fs = $null
    try {
        for ($p = 1; $p -le $Passes; $p++) {
            $pattern = if ($p -eq $Passes) { ([byte]0) } else { $null }
            $fs = [IO.File]::Open($Path, 'Open', 'Write', 'None')
            $chunk = New-Object byte[] (4MB)
            $remaining = $len; $pos = 0L
            $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
            while ($remaining -gt 0) {
                $n = [Math]::Min($chunk.Length, $remaining)
                if ($pattern -eq $null) { $rng.GetBytes($chunk, 0, $n) } else { for($i=0;$i -lt $n;$i++){$chunk[$i]=$pattern} }
                $fs.Write($chunk, 0, $n)
                $remaining -= $n; $pos += $n
                if ($ProgressQueue) {
                    $pct = [math]::Round(100 * $p / $Passes * ($pos / $len), 1)
                    $ProgressQueue.Enqueue(@{ Pct=$pct; Recv=$pos; Total=$len; MBR=[math]::Round($pos/1MB,1); MBT=[math]::Round($len/1MB,1); MBS=0; Label="$Label Pass $p/$Passes"; Note='Shred' })
                }
            }
            $fs.Flush($true); $fs.Close(); $fs = $null
            Write-Host ("`r  Shred '$($fi.Name)' Pass $p/$Passes " -replace '\r','') -NoNewline
        }
        Write-Host ''
        Remove-Item $Path -Force -ErrorAction Stop
        $res.Ok = $true
    } catch {
        $res.Error = $_.Exception.Message
        if ($fs) { try { $fs.Close() } catch {} }
    }
    return $res
}

function Show-SysPilotFileShredder {
    <# File-Shredder: Dateien/Ordner zur Liste, Loesch-Plaene auswaehlen. #>
    $list = New-Object System.Collections.ArrayList
    Write-Host ''
    Write-Host '  === DATEI-SCHREDDER ===' -ForegroundColor Cyan
    Write-Host '  Ueberschreibt Dateien vor dem Loeschen (Standard: 3 Passes).' -ForegroundColor DarkGray
    while ($true) {
        Write-Host ''
        if ($list.Count -gt 0) {
            Write-Host '  Zur Loeschung vorgemerkt:' -ForegroundColor Yellow
            for ($i=0; $i -lt $list.Count; $i++) { Write-Host ("    {0}. {1}" -f ($i+1), $list[$i]) -ForegroundColor White }
        }
        $items = @(
            @{ Label='Datei(en) hinzufuegen'; Color='Green'; Tag='addf' }
            @{ Label='Ordner hinzufuegen (rekursiv)'; Color='Green'; Tag='addd' }
            @{ Label=$(if($list.Count){"Ausgewaehlte endgueltig loeschen ($($list.Count))"}else{'Nichts zum Loeschen'}); Color='Red'; Tag='del' }
            @{ Label='Liste leeren'; Color='DarkGray'; Tag='clear' }
            @{ Label='Zurueck'; Color='DarkGray'; Tag='back' }
        )
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'File-Shredder' -Footer 'Pfeile + Enter'
        if ($null -eq $sel -or $sel -eq 'back') { return }
        switch ($sel) {
            'addf' {
                $p = Read-SysPilotInput 'Dateipfad(e), getrennt durch ;'
                foreach ($x in ($p -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
                    if (Test-Path $x -PathType Leaf) { [void]$list.Add($x) } else { Write-Host "  Nicht gefunden: $x" -ForegroundColor Red }
                }
            }
            'addd' {
                $p = Read-SysPilotInput 'Ordnerpfad'
                if (Test-Path $p -PathType Container) {
                    Get-ChildItem $p -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object { [void]$list.Add($_.FullName) }
                    Write-Host "  Dateien im Ordner vorgemerkt." -ForegroundColor DarkGray
                } else { Write-Host "  Ordner nicht gefunden: $p" -ForegroundColor Red }
            }
            'del' {
                if ($list.Count -eq 0) { continue }
                $passes = Read-SysPilotInput 'Passes (1-7, Standard 3)' '3'
                $np = 3; try { $np = [Math]::Max(1,[Math]::Min(7,[int]$passes)) } catch {}
                $bytes = 0L; foreach ($f in $list) { try { $bytes += (Get-Item $f -Force).Length } catch {} }
                Write-Host ("  {0} Datei(en), {1:N1} MB, {2} Pass(es). Das kann dauern!" -f $list.Count, ($bytes/1MB), $np) -ForegroundColor Yellow
                if (-not (Confirm-SysPilot 'Endgueltig ueberschreiben und loeschen?')) { continue }
                $ok = 0; $fail = 0
                foreach ($f in $list) {
                    $r = Invoke-SysPilotFileShred -Path $f -Passes $np -Label 'Shred'
                    if ($r.Ok) { $ok++ } else { $fail++; Write-Host "  [!] $f : $($r.Error)" -ForegroundColor Red }
                }
                Write-Host ("  Fertig: {0} geloescht, {1} Fehler." -f $ok, $fail) -ForegroundColor Green
                $list.Clear()
                Read-SysPilotChoice 'Weiter' | Out-Null
            }
            'clear' { $list.Clear() }
        }
    }
}

# =====================================================================
# 3) PRIVACY-ERASE (Spuren)
# =====================================================================

function Get-SysPilotPrivacyEraseTargets {
    <# Gibt loeschbare Spur-Kategorien mit Pfaden zurueck.
       @{Id;Label;Paths;Notes} - Pfade werden nur geloescht wenn sie existieren. #>
    $local = $env:LOCALAPPDATA; $appdata = $env:APPDATA; $user = $env:USERPROFILE
    $targets = @(
        @{ Id='chrome'; Label='Chrome: Verlauf, Cookies, Cache'; Paths=@("$local\Google\Chrome\User Data\Default\History","$local\Google\Chrome\User Data\Default\Cookies","$local\Google\Chrome\User Data\Default\Cache","$local\Google\Chrome\User Data\Default\Code Cache","$local\Google\Chrome\User Data\Default\Service Worker\CacheStorage") ; Notes='Chrome sollte geschlossen sein' }
        @{ Id='edge';   Label='Edge: Verlauf, Cookies, Cache'; Paths=@("$local\Microsoft\Edge\User Data\Default\History","$local\Microsoft\Edge\User Data\Default\Network\Cookies","$local\Microsoft\Edge\User Data\Default\Cache","$local\Microsoft\Edge\User Data\Default\Code Cache") ; Notes='Edge sollte geschlossen sein' }
        @{ Id='firefox';Label='Firefox: Verlauf, Cookies, Cache'; Paths=@("$appdata\Mozilla\Firefox\Profiles") ; Notes='Firefox sollte geschlossen sein - Profile werden nach places.sqlite/cookies.sqlite/gecko Profile gefiltert' }
        @{ Id='brave';  Label='Brave: Verlauf, Cookies, Cache'; Paths=@("$local\BraveSoftware\Brave-Browser\User Data\Default\History","$local\BraveSoftware\Brave-Browser\User Data\Default\Cookies","$local\BraveSoftware\Brave-Browser\User Data\Default\Cache") ; Notes='Brave sollte geschlossen sein' }
        @{ Id='recent'; Label='Windows: Zuletzt verwendet (RecentDocs, JumpLists, Timeline)'; Paths=@("$appdata\Microsoft\Windows\Recent","$local\ConnectedDevicesPlatform") ; Notes='' }
        @{ Id='thumb';  Label='Windows: Thumbnail-/Icon-Cache'; Paths=@("$local\Microsoft\Windows\Explorer") ; Notes='thumbcache_*/iconcache_* Dateien' }
        @{ Id='notif';  Label='Windows: Benachrichtigungs-Verlauf (wpndatabase)'; Paths=@("$local\Microsoft\Windows\Notifications\wpndatabase.db") ; Notes='Benachrichtigungen werden zurueckgesetzt' }
        @{ Id='temp';   Label='Windows: Benutzer-Temp-Dateien'; Paths=@("$env:TEMP") ; Notes='Inhalt von %TEMP%' }
        @{ Id='dns';    Label='DNS-Client-Cache leeren'; Paths=@(); Notes='Clear-DnsClientCache' }
        @{ Id='recycle';Label='Papierkorb leeren'; Paths=@(); Notes='Clear-RecycleBin -force' }
        @{ Id='wer';    Label='Windows Error Reporting-Cache'; Paths=@("$local\Microsoft\Windows\WER","$programdata\Microsoft\Windows\WER") ; Notes='' }
    )
    return $targets
}

function Invoke-SysPilotPrivacyEraseItem {
    <# Fuehrt eine Privacy-Erase-Kategorie aus. #>
    param([Parameter(Mandatory)][hashtable]$Target)
    $res = @{ Ok=$true; FreedMB=0.0; Notes=@(); Errors=@() }
    $freed = 0L
    $sizeOf = { param($p) try { (Get-ChildItem $p -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum } catch { 0 } }

    if ($Target.Id -eq 'dns') {
        try { Clear-DnsClientCache -ErrorAction Stop; $res.Notes += 'DNS-Cache geleert' } catch { $res.Errors += $_.Exception.Message }
        return $res
    }
    if ($Target.Id -eq 'recycle') {
        try { Clear-RecycleBin -Force -ErrorAction Stop; $res.Notes += 'Papierkorb geleert' } catch { $res.Errors += $_.Exception.Message }
        return $res
    }

    foreach ($p in $Target.Paths) {
        if (-not (Test-Path $p)) { continue }
        # Firefox-Sonderfall: nur Trace-Dateien in Profilen loeschen
        if ($Target.Id -eq 'firefox' -and (Test-Path $p -PathType Container)) {
            Get-ChildItem $p -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                foreach ($f in 'places.sqlite','places.sqlite-wal','cookies.sqlite','cookies.sqlite-wal','cache2','startupCache','thumbnails','storage\default\https+++*') {
                    $fp = Join-Path $_.FullName $f
                    if ($f -match '\*') {
                        Get-ChildItem (Join-Path $_.FullName ($f -replace '\*.*','*')) -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                    } elseif (Test-Path $fp) {
                        $freed += (& $sizeOf $fp)
                        Remove-Item $fp -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }
            }
            continue
        }
        # Thumb-Cache: nur thumbcache/iconcache
        if ($Target.Id -eq 'thumb') {
            Get-ChildItem $p -Filter 'thumbcache_*.db' -ErrorAction SilentlyContinue | ForEach-Object { $freed += $_.Length; Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
            Get-ChildItem $p -Filter 'iconcache_*.db' -ErrorAction SilentlyContinue | ForEach-Object { $freed += $_.Length; Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
            continue
        }
        $isDir = Test-Path $p -PathType Container
        if ($isDir -and $Target.Id -eq 'temp') {
            Get-ChildItem $p -Force -ErrorAction SilentlyContinue | ForEach-Object {
                $sz = if ($_.PSIsContainer) { & $sizeOf $_.FullName } else { $_.Length }
                $freed += $sz
                Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
            continue
        }
        $freed += (& $sizeOf $p)
        Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path $p) { $res.Errors += "Konnte nicht loeschen: $p (Datei evtl. in Benutzung - App schliessen)" }
    }
    $res.FreedMB = [math]::Round($freed/1MB,1)
    if ($res.Errors.Count -gt 0) { $res.Ok = $false }
    return $res
}

function Show-SysPilotPrivacyErase {
    <# Privacy-Erase: Checkboxen ueber Spur-Kategorien, dann loeschen. #>
    $targets = @(Get-SysPilotPrivacyEraseTargets)
    Write-Host ''
    Write-Host '  === PRIVACY-ERASE (Spuren loeschen) ===' -ForegroundColor Cyan
    Write-Host '  Waehle Kategorien per Nummer (z.B. "1,3,5"), "all" oder "none".' -ForegroundColor DarkGray
    for ($i=0; $i -lt $targets.Count; $i++) {
        $t = $targets[$i]
        Write-Host ("    [{0}] {1}" -f ($i+1), $t.Label) -ForegroundColor White
        if ($t.Notes) { Write-Host ("        {0}" -f $t.Notes) -ForegroundColor DarkGray }
    }
    $sel = Read-SysPilotInput 'Auswahl' 'none'
    $chosen = @()
    if ($sel -eq 'all') { $chosen = $targets }
    elseif ($sel -ne 'none' -and $sel -ne '') {
        $nums = @($sel -split '[,\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
        $chosen = @($targets | Where-Object { $nums -contains ($targets.IndexOf($_)+1) })
        if ($chosen.Count -eq 0) { Write-Host '  Ungueltige Auswahl.' -ForegroundColor Red; Read-SysPilotChoice 'Weiter' | Out-Null; return }
    }
    if ($chosen.Count -eq 0) { Write-Host '  Nichts ausgewaehlt.' -ForegroundColor DarkGray; Read-SysPilotChoice 'Weiter' | Out-Null; return }
    if (-not (Confirm-SysPilot "$($chosen.Count) Spur-Kategorie(n) loeschen?")) { Write-Host '  Abgebrochen.' -ForegroundColor DarkGray; Read-SysPilotChoice 'Weiter' | Out-Null; return }

    $totalMB = 0.0
    foreach ($t in $chosen) {
        Write-Host "  Loesche: $($t.Label) ..." -ForegroundColor Cyan -NoNewline
        $r = Invoke-SysPilotPrivacyEraseItem -Target $t
        $totalMB += $r.FreedMB
        if ($r.Ok) { Write-Host (" OK ({0} MB)" -f $r.FreedMB) -ForegroundColor Green }
        else { Write-Host " mit Hinweisen" -ForegroundColor Yellow }
        foreach ($n in $r.Notes) { Write-Host "    - $n" -ForegroundColor DarkGray }
        foreach ($e in $r.Errors) { Write-Host "    [!] $e" -ForegroundColor Red }
    }
    Write-Host ("  Gesamt: {0:N1} MB Spuren entfernt." -f $totalMB) -ForegroundColor Green
    Read-SysPilotChoice 'Weiter' | Out-Null
}

# =====================================================================
# 4) DISK-OPTIMIZE (Analyze/Defrag/Trim)
# =====================================================================

function Get-SysPilotVolumeOptimizeInfo {
    <# Laufwerke mit Medium-Typ (SSD/HDD) + Fragmentierung. #>
    $vols = Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.SizeRemaining -gt 0 }
    $out = @()
    foreach ($v in $vols) {
        $dl = $v.DriveLetter
        $media = 'unknown'
        try {
            $part = Get-Partition -DriveLetter $dl -ErrorAction Stop
            $phys = Get-PhysicalDisk -DeviceNumber $part.DiskNumber -ErrorAction Stop
            if ($phys.MediaType) { $media = [string]$phys.MediaType }
            elseif ($phys.BusType -eq 'NVMe') { $media = 'SSD' }
        } catch {}
        $frag = $null
        try {
            $a = defrag "${dl}:" /A /V 2>$null | Out-String
            if ($a -match '(\d+)%\s*(?:fragmented|fragmentation)') { $frag = [int]$Matches[1] }
        } catch {}
        $out += [pscustomobject]@{ Drive="${dl}:"; Label=$v.FileSystemLabel; Media=$media; SizeGB=[math]::Round($v.Size/1GB,1); FreeGB=[math]::Round($v.SizeRemaining/1GB,1); FragPct=$frag }
    }
    return $out
}

function Invoke-SysPilotDiskOptimize {
    <# Optimiert ein Laufwerk: SSD -> /O (Trim), HDD -> /O (Defrag+Analyse).
       /O waehlt automatisch das richtige Verfahren je Medium. #>
    param([Parameter(Mandatory)][string]$Drive, [switch]$AnalyzeOnly, [int]$TimeoutSec = 7200)
    $res = @{ Ok=$false; Output=''; Error='' }
    $args = @("${Drive}:".TrimEnd(':'), '/O')
    if ($AnalyzeOnly) { $args += '/A' }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = 'defrag.exe'
    $psi.Arguments = ($args -join ' ')
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
    $p = New-Object Diagnostics.Process; $p.StartInfo = $psi
    try { [void]$p.Start() } catch { $res.Error = $_.Exception.Message; return $res }
    $out = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()
    $p.WaitForExit($TimeoutSec*1000) | Out-Null
    if (-not $p.HasExited) { try { $p.Kill() } catch {}; $res.Error = "Timeout nach ${TimeoutSec}s"; return $res }
    $res.Output = ($out + "`n" + $err).Trim()
    $res.Ok = ($p.ExitCode -eq 0)
    return $res
}

function Show-SysPilotDiskOptimize {
    <# Disk-Optimize: Laufwerk-Info, Analyse, Optimieren. #>
    Write-Host ''
    Write-Host '  === DISK-OPTIMIEREN ===' -ForegroundColor Cyan
    $vols = @(Get-SysPilotVolumeOptimizeInfo)
    if ($vols.Count -eq 0) { Write-Host '  Keine fixen Laufwerke gefunden.' -ForegroundColor Yellow; Read-SysPilotChoice 'Weiter' | Out-Null; return }
    for ($i=0; $i -lt $vols.Count; $i++) {
        $v = $vols[$i]
        $frag = if ($null -ne $v.FragPct) { "$($v.FragPct)%" } else { '?' }
        Write-Host ("    [{0}] {1} {2} - {3} GB ({4} GB frei), {5}, Fragmentierung: {6}" -f ($i+1), $v.Drive, $v.Label, $v.SizeGB, $v.FreeGB, $v.Media, $frag) -ForegroundColor White
    }
    $pick = Read-SysPilotInput 'Laufwerk waehlen (Nummer)' '1'
    $pi = 0
    if (-not [int]::TryParse($pick,[ref]$pi) -or $pi -lt 1 -or $pi -gt $vols.Count) { Write-Host '  Uungueltig.' -ForegroundColor Red; Read-SysPilotChoice 'Weiter' | Out-Null; return }
    $drive = $vols[$pi-1].Drive
    $mode = Read-SysPilotInput "Aktion: 1=Analyse, 2=Optimieren ($drive), 3=Beides" '3'
    if ($mode -in @('1','3')) {
        Write-Host "  Analyse $drive ..." -ForegroundColor Cyan
        $a = Invoke-SysPilotDiskOptimize -Drive $drive -AnalyzeOnly -TimeoutSec 900
        Write-Host $a.Output -ForegroundColor DarkGray
        if (-not $a.Ok) { Write-Host "  [!] $($a.Error)" -ForegroundColor Red }
    }
    if ($mode -in @('2','3')) {
        Write-Host "  Optimiere $drive (kann bei HDD lange dauern) ..." -ForegroundColor Cyan
        $o = Invoke-SysPilotDiskOptimize -Drive $drive -TimeoutSec 7200
        # Letzte Zeilen zeigen
        $tail = @($o.Output -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 15)
        foreach ($l in $tail) { Write-Host "    $l" -ForegroundColor DarkGray }
        if ($o.Ok) { Write-Host "  [OK] Optimierung abgeschlossen." -ForegroundColor Green } else { Write-Host "  [FAIL] $($o.Error)" -ForegroundColor Red }
    }
    Read-SysPilotChoice 'Weiter' | Out-Null
}

# =====================================================================
# 5) AKTIVITAETS-TIMELINE
# =====================================================================

function Show-SysPilotActivityTimeline {
    <# Aktivitaets-Timeline: Zuletzt geoeffnete Dateien, Power-Events,
       USB-Geraete-Historie - zeitlich sortiert. #>
    Write-Host ''
    Write-Host '  === AKTIVITAETS-TIMELINE ===' -ForegroundColor Cyan
    $events = New-Object System.Collections.ArrayList

    # Recent Files
    $recentDir = "$env:APPDATA\Microsoft\Windows\Recent"
    Get-ChildItem $recentDir -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 25 | ForEach-Object {
        [void]$events.Add([pscustomobject]@{ Zeit=$_.LastWriteTime; Art='Datei'; Was=$($_.Name -replace '\.lnk$',''); Detail='Zuletzt verwendet' })
    }
    # Power-Events (letzte 30 Tage, IDs: 1=Wake, 42=Sleep, 107=Resume, 506/507=Modern Standby)
    try {
        Get-WinEvent -FilterHashtable @{ LogName='System'; StartTime=(Get-Date).AddDays(-30) } -MaxEvents 2000 -ErrorAction SilentlyContinue | Where-Object { $_.ProviderName -match 'Kernel-Power|Power-Troubleshooter' -and $_.Id -in 1,42,107,506,507 } | Select-Object -First 40 | ForEach-Object {
            $art = switch ($_.Id) { 1 {'Wake';break} 42 {'Sleep';break} 107 {'Resume';break} 506 {'ModernStandby';break} 507 {'ExitModernStandby';break} default {'Power'} }
            [void]$events.Add([pscustomobject]@{ Zeit=$_.TimeCreated; Art="Power:$art"; Was=$_.ProviderName; Detail=(($_.Message -split "`n")[0]) })
        }
    } catch {}
    # USB-Historie (Registry Enum\USBSTOR - je Geraet ein Key)
    Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\USBSTOR' -ErrorAction SilentlyContinue | ForEach-Object {
        $dev = $_.PSChildName
        try {
            $props = Get-ItemProperty "$($_.PSPath)\$dev" -ErrorAction SilentlyContinue
            $first = $props.'First Install Date'; $last = $props.'Last Arrival Date'
            if ($last) {
                $dt = try { [Management.ManagementDateTimeConverter]::ToDateTime($last) } catch { $null }
                if ($dt) { [void]$events.Add([pscustomobject]@{ Zeit=$dt; Art='USB'; Was=$dev; Detail='USB-Massenspeicher angeschlossen' }) }
            }
        } catch {}
    }

    if ($events.Count -eq 0) { Write-Host '  Keine Eintraege gefunden.' -ForegroundColor DarkGray; Read-SysPilotChoice 'Weiter' | Out-Null; return }
    $sorted = $events | Sort-Object Zeit -Descending | Select-Object -First 60
    Write-Host ("  {0} Eintraege (neueste zuerst):" -f $sorted.Count) -ForegroundColor Yellow
    foreach ($e in $sorted) {
        Write-Host ("    {0}  {1,-14} {2}  ({3})" -f $e.Zeit.ToString('yyyy-MM-dd HH:mm'), $e.Art, $e.Was, $e.Detail) -ForegroundColor White
    }
    Read-SysPilotChoice 'Weiter' | Out-Null
}

# =====================================================================
# 6) PASSWORT-GENERATOR (WPF)
# =====================================================================

function Show-SysPilotPasswordGenerator {
    <# Kleiner WPF-Dialog: Laenge, Zeichenklassen, Staerke, Kopieren. #>
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
        Write-Warning 'Braucht STA.'; return $false
    }
    try {
        [void][reflection.assembly]::LoadWithPartialName('PresentationFramework')
        [void][reflection.assembly]::LoadWithPartialName('PresentationCore')
        [void][reflection.assembly]::LoadWithPartialName('WindowsBase')
    } catch {}
    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Passwort-Generator" Width="480" Height="380" WindowStartupLocation="CenterScreen"
        Background="#FF1E1E2E" Foreground="#FFEAEAF2" FontFamily="Segoe UI" ResizeMode="NoResize">
  <Window.Resources>
    <Style TargetType="Button"><Setter Property="Background" Value="#FF2D2D44"/><Setter Property="Foreground" Value="#FFEAEAF2"/><Setter Property="BorderBrush" Value="#FF4A4A6A"/><Setter Property="Padding" Value="12,5"/><Setter Property="Margin" Value="4"/><Setter Property="Cursor" Value="Hand"/><Setter Property="FontSize" Value="11"/></Style>
    <Style TargetType="CheckBox"><Setter Property="Foreground" Value="#FFEAEAF2"/><Setter Property="FontSize" Value="12"/><Setter Property="Margin" Value="0,4"/></Style>
    <Style TargetType="TextBox"><Setter Property="Background" Value="#FF14141E"/><Setter Property="Foreground" Value="#FFEAEAF2"/><Setter Property="BorderBrush" Value="#FF4A4A6A"/><Setter Property="Padding" Value="6,4"/><Setter Property="FontFamily" Value="Consolas"/><Setter Property="FontSize" Value="13"/></Style>
  </Window.Resources>
  <StackPanel Margin="16">
    <TextBlock Text="Passwort-Generator" FontSize="18" FontWeight="Bold" Foreground="#FF4FC3F7" Margin="0,0,0,10"/>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <TextBox x:Name="TxtPw" Grid.Column="0" IsReadOnly="True" Text="(noch kein Passwort)" FontSize="14"/>
      <Button x:Name="BtnCopy" Grid.Column="1" Content="Kopieren" Margin="8,0,0,0"/>
    </Grid>
    <TextBlock x:Name="TxtStrength" FontSize="11" Foreground="#FF9CCC65" Margin="0,6,0,0" Text=""/>
    <StackPanel Margin="0,10,0,0">
      <TextBlock Text="Laenge: <b>16</b>" Foreground="#FFB0B0C0" FontSize="11"/>
      <Slider x:Name="SldLen" Minimum="6" Maximum="64" Value="16" TickFrequency="1" IsSnapToTickEnabled="True" Margin="0,2"/>
    </StackPanel>
    <WrapPanel Margin="0,6,0,0">
      <CheckBox x:Name="ChkUpper" Content="Grossbuchstaben (A-Z)" IsChecked="True" Margin="0,0,12,0"/>
      <CheckBox x:Name="ChkLower" Content="Kleinbuchstaben (a-z)" IsChecked="True" Margin="0,0,12,0"/>
      <CheckBox x:Name="ChkDigit" Content="Ziffern (0-9)" IsChecked="True" Margin="0,0,12,0"/>
      <CheckBox x:Name="ChkSpec" Content="Sonderzeichen (!@#...)" IsChecked="False"/>
    </WrapPanel>
    <WrapPanel Margin="0,10,0,0">
      <Button x:Name="BtnGen" Content="Neu generieren"/>
      <Button x:Name="BtnClose" Content="Schliessen"/>
    </WrapPanel>
  </StackPanel>
</Window>
"@
    $win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$xaml)))
    $fc = @{}
    foreach ($n in 'TxtPw','TxtStrength','SldLen','ChkUpper','ChkLower','ChkDigit','ChkSpec','BtnCopy','BtnGen','BtnClose') {
        $fc[$n] = $win.FindName($n)
    }
    $gen = {
        $len = [int]$fc.SldLen.Value
        $sets = @()
        if ($fc.ChkUpper.IsChecked) { $sets += ,([char[]]'ABCDEFGHIJKLMNOPQRSTUVWXYZ') }
        if ($fc.ChkLower.IsChecked) { $sets += ,([char[]]'abcdefghijklmnopqrstuvwxyz') }
        if ($fc.ChkDigit.IsChecked) { $sets += ,([char[]]'0123456789') }
        if ($fc.ChkSpec.IsChecked) { $sets += ,([char[]]'!@#$%^&*()-_=+[]{};:,.<>?/~') }
        if ($sets.Count -eq 0) { $fc.TxtPw.Text='(mindestens eine Zeichenklasse waehlen)'; return }
        $all = ($sets | ForEach-Object { $_ }) -join ''
        $chars = New-Object char[] $len
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
        # Mindestens ein Zeichen pro gewaehlter Klasse
        $idx = 0
        foreach ($s in $sets) { $chars[$idx] = $s[[int]($rng.GetBytes(4)[0] % $s.Count)]; $idx++ }
        for ($i=$idx; $i -lt $len; $i++) {
            $b = $rng.GetBytes(4); $chars[$i] = $all[([BitConverter]::ToUInt32($b,0) % $all.Length)]
        }
        # Mischen (Fisher-Yates)
        for ($i=$len-1; $i -gt 0; $i--) {
            $j = [int]([BitConverter]::ToUInt32($rng.GetBytes(4),0) % ($i+1))
            $t=$chars[$i]; $chars[$i]=$chars[$j]; $chars[$j]=$t
        }
        $pw = -join $chars
        $fc.TxtPw.Text = $pw
        # Staerke: Entropie abschaetzen
        $pool = 0
        if ($fc.ChkUpper.IsChecked){$pool+=26}; if($fc.ChkLower.IsChecked){$pool+=26}
        if($fc.ChkDigit.IsChecked){$pool+=10}; if($fc.ChkSpec.IsChecked){$pool+=32}
        $entropy = [math]::Round($len * [math]::Log($pool,2),1)
        $lvl = if ($entropy -lt 50) { 'SCHWACH' } elseif ($entropy -lt 80) { 'MITTEL' } elseif ($entropy -lt 110) { 'STARK' } else { 'SEHR STARK' }
        $col = if ($entropy -lt 50) { '#FFEF5350' } elseif ($entropy -lt 80) { '#FFFFB74D' } elseif ($entropy -lt 110) { '#FF9CCC65' } else { '#FF4FC3F7' }
        $fc.TxtStrength.Text = "Staerke: $lvl ($entropy bits Entropie)"
        $fc.TxtStrength.Foreground = $col
    }
    $fc.BtnGen.Add_Click({ & $gen })
    $fc.BtnCopy.Add_Click({
        if ($fc.TxtPw.Text -and $fc.TxtPw.Text -notmatch '^\(') {
            try { [Windows.Clipboard]::SetText($fc.TxtPw.Text); $fc.TxtStrength.Text='Kopiert!' } catch {}
        }
    })
    $fc.BtnClose.Add_Click({ $win.Close() })
    foreach ($c in 'ChkUpper','ChkLower','ChkDigit','ChkSpec') { $fc[$c].Add_Checked({ & $gen }); $fc[$c].Add_Unchecked({ & $gen }) }
    $fc.SldLen.Add_ValueChanged({ & $gen })
    $win.Add_ContentRendered({ & $gen })
    $win.ShowDialog() | Out-Null
    return $true
}

# =====================================================================
# 7) BOOT-ANALYSE
# =====================================================================

function Show-SysPilotBootAnalysis {
    <# Boot-Analyse: Diagnostics-Performance-Events (ID 100) der letzten
       Starts - Boot-Dauer + Hauptpfad-Phasen falls vorhanden. #>
    Write-Host ''
    Write-Host '  === BOOT-ANALYSE ===' -ForegroundColor Cyan
    try {
        $evts = Get-WinEvent -FilterHashtable @{ LogName='Microsoft-Windows-Diagnostics-Performance/Operational'; Id=100 } -MaxEvents 10 -ErrorAction Stop
    } catch { Write-Host "  Keine Boot-Performance-Events (Diagnose evtl. deaktiviert)." -ForegroundColor Yellow; Read-SysPilotChoice 'Weiter' | Out-Null; return }
    Write-Host ("  {0} Boot-Events gefunden:" -f $evts.Count) -ForegroundColor Yellow
    foreach ($e in $evts) {
        $xml = [xml]$e.ToXml()
        $data = @{}
        foreach ($d in $xml.Event.EventData.Data) { $data[$d.Name] = $d.'#text' }
        $bootMs = 0; $mainMs = 0; $degrMs = 0
        if ($data['BootTime']) { $bootMs = [int64]$data['BootTime'] }
        if ($data['MainPathBootTime']) { $mainMs = [int64]$data['MainPathBootTime'] }
        if ($data['BootDegradationTime']) { $degrMs = [int64]$data['BootDegradationTime'] }
        $verdict = if ($bootMs -gt 60000) { 'LANGSAM' } elseif ($bootMs -gt 30000) { 'ok' } else { 'schnell' }
        $col = if ($verdict -eq 'LANGSAM') { 'Red' } elseif ($verdict -eq 'ok') { 'Yellow' } else { 'Green' }
        Write-Host ("    {0}  Boot: {1,5} ms  MainPath: {2,5} ms  Degradation: {3,5} ms  [{4}]" -f $e.TimeCreated.ToString('yyyy-MM-dd HH:mm'), $bootMs, $mainMs, $degrMs, $verdict) -ForegroundColor $col
        # Top-5 langsame Boot-Komponenten falls im Event
        $top = $xml.Event.EventData.Data | Where-Object { $_.Name -match 'BootTime' }
    }
    Write-Host ''
    Write-Host '  Tipp: Langsame Starts oft durch Autostart-Programme/Services - siehe Startup-Manager.' -ForegroundColor DarkCyan
    Read-SysPilotChoice 'Weiter' | Out-Null
}

# =====================================================================
# OBERMENUE
# =====================================================================

function Show-SysPilotCareCenter {
    <# CareCenter-Obermenue. #>
    while ($true) {
        Write-Host ''
        Write-Host '  === SYSTEMPFLEGE-CENTER ===' -ForegroundColor Cyan
        Write-Host '  Registry-Cleaner, File-Shredder, Privacy-Erase, Disk-Optimize,' -ForegroundColor DarkGray
        Write-Host '  Aktivitaets-Timeline, Passwort-Generator, Boot-Analyse' -ForegroundColor DarkGray
        $items = @(
            @{ Label='Registry-Cleaner (Leichen, MUICache, MRU, Telemetrie)'; Color='Yellow'; Tag='regclean' }
            @{ Label='File-Shredder (sicheres Ueberschreiben + Loeschen)'; Color='Red'; Tag='shred' }
            @{ Label='Privacy-Erase (Browser-/Windows-Spuren loeschen)'; Color='Magenta'; Tag='privacy' }
            @{ Label='Disk-Optimieren (Analyse/Defrag/Trim je Medium)'; Color='Cyan'; Tag='diskopt' }
            @{ Label='Aktivitaets-Timeline (Dateien, Power, USB)'; Color='White'; Tag='timeline' }
            @{ Label='Passwort-Generator (WPF-Dialog)'; Color='Green'; Tag='pwgen' }
            @{ Label='Boot-Analyse (Startzeiten, Phasen)'; Color='Green'; Tag='boot' }
            @{ Label='Zurueck'; Color='DarkGray'; Tag='back' }
        )
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'Systempflege-Center' -Footer 'Pfeile + Enter, Esc = zurueck'
        if ($null -eq $sel -or $sel -eq 'back') { return }
        switch ($sel) {
            'regclean' { Show-SysPilotRegistryCleaner }
            'shred'    { Show-SysPilotFileShredder }
            'privacy'  { Show-SysPilotPrivacyErase }
            'diskopt'  { Show-SysPilotDiskOptimize }
            'timeline' { Show-SysPilotActivityTimeline }
            'pwgen'    { Show-SysPilotPasswordGenerator | Out-Null }
            'boot'     { Show-SysPilotBootAnalysis }
        }
    }
}

Export-ModuleMember -Function `
    Get-SysPilotRegistryJunkItems, Backup-SysPilotRegistryJunk, Invoke-SysPilotRegistryClean, `
    Show-SysPilotRegistryCleaner, Invoke-SysPilotFileShred, Show-SysPilotFileShredder, `
    Get-SysPilotPrivacyEraseTargets, Invoke-SysPilotPrivacyEraseItem, Show-SysPilotPrivacyErase, `
    Get-SysPilotVolumeOptimizeInfo, Invoke-SysPilotDiskOptimize, Show-SysPilotDiskOptimize, `
    Show-SysPilotActivityTimeline, Show-SysPilotPasswordGenerator, Show-SysPilotBootAnalysis, `
    Show-SysPilotCareCenter
