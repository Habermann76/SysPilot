# SysPilot - Checkup: Automatic Checkup (Komplett-Scan mit Erklaerungen und Reparatur)
# Besser als Advanced SystemCare: ehrlich, jede Pruefung hat eine echte Erklaerung
# und eine echte Reparatur - keine erfundenen "Probleme" als Verkaufsdruck.
#Requires -Version 5.1

# Wurzelordner von SysPilot (modules\..). Jedes Modul hat seinen eigenen $script:-Bereich -
# die Variable aus Common.psm1 ist hier NICHT sichtbar (war die Ursache von "Path ... NULL").
$script:SysPilotRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)

# ---------- Hilfsfunktionen ----------

function Get-SysPilotFolderSizeMB {
    param([string]$Path, [string]$Filter)
    if (-not (Test-Path $Path)) { return 0 }
    $files = Get-ChildItem $Path -Recurse -Force -File -ErrorAction SilentlyContinue
    if ($Filter) { $files = $files | Where-Object { $_.Name -like $Filter } }
    $sum = ($files | Measure-Object Length -Sum).Sum
    if (-not $sum) { return 0 }
    return [math]::Round($sum / 1MB)
}

function Find-SysPilotBrokenShortcuts {
    <# Sucht .lnk-Dateien, deren Ziel nicht mehr existiert.
       Orte: Desktop (User+Public), Startmenue (User+Common), angepinnte Taskleisten-Eintraege. #>
    $dirs = @(
        [Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('CommonDesktopDirectory'),
        [Environment]::GetFolderPath('StartMenu'),
        [Environment]::GetFolderPath('CommonStartMenu'),
        "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned"
    ) | Select-Object -Unique

    $shell = New-Object -ComObject WScript.Shell
    $broken = @()
    foreach ($d in $dirs) {
        if (-not (Test-Path $d)) { continue }
        $links = Get-ChildItem $d -Recurse -Filter '*.lnk' -Force -ErrorAction SilentlyContinue
        foreach ($l in $links) {
            try {
                $sc = $shell.CreateShortcut($l.FullName)
                $target = $sc.TargetPath
                if ([string]::IsNullOrWhiteSpace($target)) { continue }
                if ($target -match '^\w+://') { continue }   # steam:// etc.
                $targetExp = [Environment]::ExpandEnvironmentVariables($target)
                if (-not (Test-Path $targetExp)) {
                    $broken += [PSCustomObject]@{ Link = $l.FullName; Ziel = $target }
                }
            } catch { }
        }
    }
    return $broken
}

function Get-SysPilotRegistryOrphans {
    <# Verwaiste Registry-Verweise: Eintraege, die auf nicht mehr existierende Dateien zeigen.
       Sichere Untermenge (wie ASC, aber ehrlich): Autostart, Deinstallation, App Paths.
       Registry-Bereinigung macht den PC kaum schneller - entfernt aber tote Verweise. #>
    $orphans = @()

    function Get-ExePathFromCommand {
        param([string]$cmd)
        if ([string]::IsNullOrWhiteSpace($cmd)) { return $null }
        $cmd = [Environment]::ExpandEnvironmentVariables($cmd.Trim())
        if ($cmd -match '^"([^"]+)"') { return $matches[1] }
        $first = ($cmd -split '\s+')[0]
        return ($first -replace '^"|"$', '')
    }

    # 1) Autostart-Eintraege (Run/RunOnce)
    $runKeys = @(
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
    )
    foreach ($k in $runKeys) {
        if (-not (Test-Path $k)) { continue }
        $props = Get-ItemProperty $k -ErrorAction SilentlyContinue
        foreach ($p in $props.PSObject.Properties) {
            if ($p.Name -like 'PS*') { continue }
            $exe = Get-ExePathFromCommand ([string]$p.Value)
            if ($exe -and $exe -match '\.(exe|bat|cmd|vbs|ps1|dll)$' -and $exe -notmatch '^\w+://') {
                if (-not (Test-Path $exe -ErrorAction SilentlyContinue)) {
                    $orphans += [PSCustomObject]@{
                        Bereich = 'Autostart'; Schluessel = $k; Name = $p.Name; Ziel = $exe
                        Typ = 'Value'
                    }
                }
            }
        }
    }

    # 2) Deinstallations-Eintraege ohne vorhandenes Programm
    $uninstKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($uk in $uninstKeys) {
        if (-not (Test-Path $uk)) { continue }
        foreach ($sub in (Get-ChildItem $uk -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty $sub.PSPath -ErrorAction SilentlyContinue
            if (-not $p.DisplayName) { continue }
            $loc = $p.InstallLocation
            if ($loc -and -not (Test-Path ([Environment]::ExpandEnvironmentVariables($loc)) -ErrorAction SilentlyContinue)) {
                $orphans += [PSCustomObject]@{
                    Bereich = 'Deinstallation'; Schluessel = $sub.PSPath; Name = $p.DisplayName; Ziel = $loc
                    Typ = 'Key'
                }
            }
        }
    }

    # 3) App Paths (Programm-Registrierung mit fehlender Datei)
    $appPaths = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths'
    if (Test-Path $appPaths) {
        foreach ($sub in (Get-ChildItem $appPaths -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty $sub.PSPath -ErrorAction SilentlyContinue
            $exe = $p.'(default)'
            if (-not $exe) { $exe = $p.'(Standard)' }
            if ($exe) {
                $exeExp = [Environment]::ExpandEnvironmentVariables(([string]$exe -replace '^"|"$', ''))
                if ($exeExp -match '^[A-Za-z]:\\' -and -not (Test-Path $exeExp -ErrorAction SilentlyContinue)) {
                    $orphans += [PSCustomObject]@{
                        Bereich = 'App Paths'; Schluessel = $sub.PSPath; Name = $sub.PSChildName; Ziel = $exeExp
                        Typ = 'Key'
                    }
                }
            }
        }
    }
    return $orphans
}

function Get-SysPilotSecurityStatus {
    <# Sicherheits-Status: Defender, Firewall, UAC, SMBv1, PowerShell v2, Neustart. #>
    $s = [ordered]@{}

    # Defender
    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        $s.AvService = [bool]$mp.AMServiceEnabled
        $s.AvRealTime = [bool]$mp.RealTimeProtectionEnabled
        $s.AvSignatureAgeDays = [int]$mp.AntivirusSignatureAge
        $s.AvName = 'Windows Defender'
    } catch {
        $s.AvService = $null; $s.AvRealTime = $null; $s.AvSignatureAgeDays = $null; $s.AvName = $null
    }
    # Andere Antivirus-Programme
    try {
        $others = Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop |
            Where-Object { $_.displayName -notmatch 'Windows Defender|Microsoft Defender' }
        $s.OtherAv = @($others | ForEach-Object { $_.displayName })
    } catch { $s.OtherAv = @() }

    # Firewall
    try {
        $profiles = Get-NetFirewallProfile -ErrorAction Stop
        $s.FirewallOff = @($profiles | Where-Object { -not $_.Enabled } | ForEach-Object { $_.Name })
    } catch { $s.FirewallOff = @() }

    # UAC
    $uac = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue
    $s.UacEnabled = ($uac.EnableLUA -eq 1)
    $s.UacPromptLevel = $uac.ConsentPromptBehaviorAdmin

    # SMBv1 (veraltet, Sicherheitsrisiko)
    try {
        $smb = Get-SmbServerConfiguration -ErrorAction Stop
        $s.SmbV1 = [bool]$smb.EnableSMB1Protocol
    } catch { $s.SmbV1 = $null }

    # PowerShell v2 (veraltet, Sicherheitsrisiko)
    try {
        $psv2 = Get-WindowsOptionalFeature -Online -FeatureName MicrosoftWindowsPowerShellV2Root -ErrorAction Stop
        $s.PsV2Enabled = ($psv2.State -eq 'Enabled')
    } catch { $s.PsV2Enabled = $null }

    # Ausstehender Neustart
    $s.PendingReboot = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')

    return [PSCustomObject]$s
}

# ---------- Checkup-Definitionen ----------

function Get-SysPilotCheckupItems {
    <# Jeder Eintrag: Id, Name, Kategorie, Erklaerung, Scan (Scriptblock -> Ergebnis),
       Fix (Scriptblock oder $null = manuell), NeedsAdmin, AutoFix (sicher automatisch). #>
    $items = @()

    $items += @{
        Id = 'junk'; Name = 'Datenmuell'; Kategorie = 'Bereinigen'
        Erklaerung = 'Loescht temporaere Dateien, Update-Reste und Caches (Temp-Ordner, Windows-Update-Cache, Miniaturbilder, Shader-Cache, Fehlerberichte). Das ist sicher - Windows und Programme bauen diese Caches bei Bedarf neu. Deine Dokumente, Bilder und Programme bleiben unangetastet.'
        NeedsAdmin = $false; AutoFix = $true
        Scan = {
            $total = 0; $details = @()
            foreach ($t in (Get-SysPilotCleanupTargets)) {
                $sz = Get-SysPilotFolderSizeMB -Path $t.Path -Filter $t.Filter
                if ($sz -gt 0) { $total += $sz; $details += "$($t.Name): $sz MB" }
            }
            @{ Found = ($total -gt 50); Count = $details.Count; SizeMB = $total; Details = $details
               Summary = "$total MB loeschbar" }
        }
        Fix = { Invoke-SysPilotCleanup }
    }

    $items += @{
        Id = 'privacy'; Name = 'Spuren der Privatsphaere'; Kategorie = 'Bereinigen'
        Erklaerung = 'Loescht NUR lokale Verlaufs-Listen: zuletzt geoeffnete Dateien, Sprunglisten (Rechtsklick im Startmenue), DNS-Verlauf. WICHTIG: Das schaltet KEINE personalisierte Werbung, KEINE Standortfreigabe und KEINE Telemetrie ab - das sind separate Schalter (Menue 10), die du bewusst selbst steuerst. Hier geht es nur um lokale "Was habe ich zuletzt gemacht"-Spuren auf diesem PC.'
        NeedsAdmin = $false; AutoFix = $true
        Scan = {
            $recent = @(Get-ChildItem "$env:APPDATA\Microsoft\Windows\Recent" -Force -ErrorAction SilentlyContinue).Count
            $dns = 0
            try { $dns = @(Get-DnsClientCache -ErrorAction Stop).Count } catch { }
            $found = ($recent -gt 20 -or $dns -gt 100)
            @{ Found = $found; Count = ($recent + $dns); SizeMB = 0
               Details = @("Zuletzt verwendete Dateien: $recent Eintraege", "DNS-Verlauf: $dns Eintraege")
               Summary = "$recent Datei-Spuren, $dns DNS-Eintraege" }
        }
        Fix = {
            Remove-Item "$env:APPDATA\Microsoft\Windows\Recent\*" -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item "$env:APPDATA\Microsoft\Windows\Recent\AutomaticDestinations\*" -Force -ErrorAction SilentlyContinue
            Remove-Item "$env:APPDATA\Microsoft\Windows\Recent\CustomDestinations\*" -Force -ErrorAction SilentlyContinue
            try { Clear-DnsClientCache -ErrorAction SilentlyContinue } catch { }
            Write-Host '  [OK] Datei-Spuren, Sprunglisten und DNS-Verlauf geloescht' -ForegroundColor Green
        }
    }

    $items += @{
        Id = 'shortcuts'; Name = 'Tote Verknuepfungen'; Kategorie = 'Bereinigen'
        Erklaerung = 'Findet Verknuepfungen auf Desktop/Startmenue, deren Ziel-Programm laengst deinstalliert ist. Loescht nur diese toten Links - keine funktionierenden Verknuepfungen und keine Programme.'
        NeedsAdmin = $false; AutoFix = $true
        Scan = {
            $broken = @(Find-SysPilotBrokenShortcuts)
            @{ Found = ($broken.Count -gt 0); Count = $broken.Count; SizeMB = 0
               Details = @($broken | Select-Object -First 5 | ForEach-Object { "$($_.Link) -> $($_.Ziel)" })
               Summary = "$($broken.Count) tote Verknuepfungen"; Broken = $broken }
        }
        Fix = {
            $broken = @(Find-SysPilotBrokenShortcuts)
            foreach ($b in $broken) {
                Remove-Item $b.Link -Force -ErrorAction SilentlyContinue
                Write-Host "  [OK] Geloescht: $($b.Link)" -ForegroundColor Green
            }
            Write-SysPilotLog "Checkup: $($broken.Count) tote Verknuepfungen geloescht"
        }
    }

    $items += @{
        Id = 'registry'; Name = 'Tote Registry-Verweise'; Kategorie = 'Bereinigen'
        Erklaerung = 'Findet Registry-Eintraege, die auf laengst geloeschte Dateien zeigen (Autostart, Deinstallations-Reste, App Paths). Ehrlich: macht den PC kaum schneller, entfernt aber tote Verweise. Vorher wird automatisch ein Backup (.reg) erstellt. Aendert NICHTS an Netzwerk, Freigaben oder Programmen, die noch installiert sind.'
        NeedsAdmin = $true; AutoFix = $true
        Scan = {
            $orphans = @(Get-SysPilotRegistryOrphans)
            @{ Found = ($orphans.Count -gt 0); Count = $orphans.Count; SizeMB = 0
               Details = @($orphans | Select-Object -First 5 | ForEach-Object { "[$($_.Bereich)] $($_.Name)" })
               Summary = "$($orphans.Count) verwaiste Eintraege"; Orphans = $orphans }
        }
        Fix = {
            $orphans = @(Get-SysPilotRegistryOrphans)
            if ($orphans.Count -eq 0) { Write-Host '  Nichts zu entfernen.' -ForegroundColor Green; return }
            $backupDir = Join-Path $script:SysPilotRoot 'backup'
            if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Force -Path $backupDir | Out-Null }
            # PSPath ("Microsoft.PowerShell.Core\Registry::HKEY_...") bzw. "HKLM:\..." -> Pfad fuer reg.exe
            $toReg = {
                param([string]$p)
                $p -replace '^Microsoft\.PowerShell\.Core\\Registry::', '' -replace '^HKCU:\\', 'HKEY_CURRENT_USER\' -replace '^HKLM:\\', 'HKEY_LOCAL_MACHINE\'
            }
            # Echtes Backup: betroffene Schluessel als .reg exportieren (bei Werten der uebergeordnete Schluessel)
            $regDir = Join-Path $backupDir ("registry-orphans-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
            New-Item -ItemType Directory -Force -Path $regDir | Out-Null
            $exportKeys = @($orphans | ForEach-Object { & $toReg $_.Schluessel } | Select-Object -Unique)
            $n = 0
            foreach ($k in $exportKeys) {
                $n++
                & reg.exe export $k (Join-Path $regDir ('{0:D3}.reg' -f $n)) /y 2>$null | Out-Null
            }
            $removed = 0; $failed = 0
            foreach ($o in $orphans) {
                $regPath = & $toReg $o.Schluessel
                if ($o.Typ -eq 'Value') {
                    & reg.exe delete $regPath /v $o.Name /f 2>$null | Out-Null
                } else {
                    & reg.exe delete $regPath /f 2>$null | Out-Null
                }
                if ($LASTEXITCODE -eq 0) { $removed++ } else { $failed++ }
            }
            Write-Host "  [OK] $removed verwaiste Eintraege entfernt (Backup: $regDir)" -ForegroundColor Green
            if ($failed -gt 0) { Write-Host "  [i] $failed Eintraege konnten nicht entfernt werden (Rechte? Dann SysPilot als Administrator starten)." -ForegroundColor DarkYellow }
            Write-SysPilotLog "Checkup: $removed Registry-Waisen entfernt, $failed fehlgeschlagen"
        }
    }

    $items += @{
        Id = 'antivirus'; Name = 'Virenschutz-Status'; Kategorie = 'Sicherheit'
        Erklaerung = 'Prueft, ob ein Virenschutz aktiv ist, der Echtzeitschutz laeuft und die Signaturen aktuell sind. Behebt nur: Echtzeitschutz wieder einschalten + Signaturen aktualisieren. Deinstalliert oder veraendert KEIN Antivirus-Programm.'
        NeedsAdmin = $true; AutoFix = $true
        Scan = {
            $sec = Get-SysPilotSecurityStatus
            $found = $false; $details = @(); $crit = $false
            if ($sec.OtherAv.Count -gt 0) {
                $details += "Aktiv: $($sec.OtherAv -join ', ')"
            } elseif ($sec.AvService -eq $true) {
                $details += 'Windows Defender ist aktiv'
                if ($sec.AvRealTime -eq $false) { $found = $true; $crit = $true; $details += 'ABER: Echtzeitschutz ist AUS!' }
                if ($sec.AvSignatureAgeDays -gt 7) { $found = $true; $details += "Signaturen sind $($sec.AvSignatureAgeDays) Tage alt" }
            } else {
                $found = $true; $crit = $true; $details += 'KEIN aktiver Virenschutz gefunden!'
            }
            @{ Found = $found; Count = $details.Count; SizeMB = 0; Details = $details
               Summary = ($details -join '; '); Critical = $crit }
        }
        Fix = {
            try {
                Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop
                Write-Host '  [OK] Echtzeitschutz aktiviert' -ForegroundColor Green
            } catch { Write-Host '  [i] Echtzeitschutz konnte nicht gesetzt werden (anderes AV aktiv?)' -ForegroundColor DarkYellow }
            try {
                Update-MpSignature -ErrorAction Stop
                Write-Host '  [OK] Virensignaturen aktualisiert' -ForegroundColor Green
            } catch { Write-Host '  [i] Signatur-Update fehlgeschlagen (offline?)' -ForegroundColor DarkYellow }
        }
    }

    $items += @{
        Id = 'firewall'; Name = 'Firewall-Status'; Kategorie = 'Sicherheit'
        Erklaerung = 'Prueft, ob die Windows-Firewall in allen Profilen (Privat, Oeffentlich, Domain) aktiv ist. Behebt nur: abgeschaltete Profile wieder einschalten. Aendert KEINE Firewall-Regeln, blockiert keine Programme und schaltet keine Netzwerk-Features ab.'
        NeedsAdmin = $true; AutoFix = $true
        Scan = {
            $sec = Get-SysPilotSecurityStatus
            $found = ($sec.FirewallOff.Count -gt 0)
            @{ Found = $found; Count = $sec.FirewallOff.Count; SizeMB = 0
               Details = @($sec.FirewallOff | ForEach-Object { "Profil $_ ist AUS" })
               Summary = if ($found) { "Aus in: $($sec.FirewallOff -join ', ')" } else { 'Alle Profile aktiv' } }
        }
        Fix = {
            Set-NetFirewallProfile -Profile Domain, Public, Private -Enabled True -ErrorAction SilentlyContinue
            Write-Host '  [OK] Firewall in allen Profilen aktiviert' -ForegroundColor Green
        }
    }

    $items += @{
        Id = 'hardening'; Name = 'System-Haertung'; Kategorie = 'Sicherheit'
        Erklaerung = 'Prueft veraltete Angriffsflaechen: SMBv1 (altes Dateifreigabe-Protokoll), PowerShell v2, Benutzerkontensteuerung (UAC), ausstehende Neustarts. WICHTIG: SMBv1 wird NUR deaktiviert, wenn du es nicht brauchst - alte NAS/Netzwerkgeraete (manche Fritz!Box, alte Drucker, Windows XP/2003) brauchen es noch. Die Netzwerkerkennung und Dateifreigabe (SMBv2/v3) bleiben davon unberuehrt und laufen weiter.'
        NeedsAdmin = $true; AutoFix = $true
        Scan = {
            $sec = Get-SysPilotSecurityStatus
            $found = $false; $details = @()
            if ($sec.SmbV1 -eq $true) { $found = $true; $details += 'SMBv1 aktiv (veraltet, Ransomware-Risiko - aber alte NAS/Geraete brauchen es evtl. noch)' }
            if ($sec.PsV2Enabled -eq $true) { $found = $true; $details += 'PowerShell v2 aktiv (veraltet, wird von Malware missbraucht)' }
            if (-not $sec.UacEnabled) { $found = $true; $details += 'Benutzerkontensteuerung (UAC) ist AUS' }
            if ($sec.PendingReboot) { $found = $true; $details += 'Ausstehender Neustart (Updates warten)' }
            @{ Found = $found; Count = $details.Count; SizeMB = 0; Details = $details
               Summary = if ($details.Count) { "$($details.Count) Haertungs-Punkte" } else { 'Keine gefunden' } }
        }
        Fix = {
            $sec = Get-SysPilotSecurityStatus
            if ($sec.SmbV1 -eq $true) {
                Write-Host '  [!] SMBv1 ist aktiv.' -ForegroundColor Yellow
                Write-Host '      Brauchst du es noch? Nur fuer SEHR alte Geraete (alte NAS, XP, manche Fritz!Box).' -ForegroundColor DarkGray
                Write-Host '      Netzwerkerkennung, Dateifreigabe und moderne Geraete laufen auch ohne SMBv1.' -ForegroundColor DarkGray
                if (Confirm-SysPilot 'SMBv1 jetzt deaktivieren? (nur wenn du keine alten Geraete nutzt)') {
                    Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoRestart -ErrorAction SilentlyContinue | Out-Null
                    Write-Host '  [OK] SMBv1 deaktiviert (wirkt nach Neustart)' -ForegroundColor Green
                } else {
                    Write-Host '  [i] SMBv1 bleibt aktiv (deine Entscheidung).' -ForegroundColor DarkGray
                }
            }
            if ($sec.PsV2Enabled -eq $true) {
                Disable-WindowsOptionalFeature -Online -FeatureName MicrosoftWindowsPowerShellV2Root -NoRestart -ErrorAction SilentlyContinue | Out-Null
                Write-Host '  [OK] PowerShell v2 deaktiviert (wirkt nach Neustart)' -ForegroundColor Green
            }
            if (-not $sec.UacEnabled) {
                Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name EnableLUA -Value 1
                Write-Host '  [OK] UAC aktiviert (wirkt nach Neustart)' -ForegroundColor Green
            }
            if ($sec.PendingReboot) {
                Write-Host '  [i] Bitte einmal neu starten - wartende Updates werden dann fertig installiert.' -ForegroundColor Yellow
            }
            Write-SysPilotLog 'Checkup: System-Haertung ausgefuehrt'
        }
    }

    $items += @{
        Id = 'startup'; Name = 'Autostart-Last'; Kategorie = 'Optimieren'
        Erklaerung = 'Zaehlt nur, wie viele Programme beim Start mitlaufen. Aendert hier NICHTS - zum Ausmisten oeffnest du den Autostart-Manager, der Eintraege deaktiviert (nicht loescht) und rueckgaengig machen kann.'
        NeedsAdmin = $false; AutoFix = $false; MenuAction = 'startup'
        Scan = {
            $active = @(Get-SysPilotStartupItems | Where-Object { $_.Aktiv }).Count
            @{ Found = ($active -gt 15); Count = $active; SizeMB = 0
               Details = @("$active aktive Autostart-Eintraege")
               Summary = "$active aktive Eintraege" }
        }
        Fix = $null
    }

    $items += @{
        Id = 'ram'; Name = 'RAM-Druck'; Kategorie = 'Optimieren'
        Erklaerung = 'Ist der RAM fast voll, lagert Windows auf die langsame SSD aus und alles ruckelt. Behebt: leert Arbeitsseiten und Standby-Cache - laufende Programme und deine Daten bleiben unberuehrt.'
        NeedsAdmin = $false; AutoFix = $true
        Scan = {
            $os = Get-CimInstance Win32_OperatingSystem
            $usedPct = [math]::Round(100 * ($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize)
            @{ Found = ($usedPct -ge 85); Count = $usedPct; SizeMB = 0
               Details = @("$usedPct% belegt")
               Summary = "$usedPct% belegt" }
        }
        Fix = { Invoke-SysPilotFreeRam }
    }

    $items += @{
        Id = 'disk'; Name = 'Festplatten-Fuellstand'; Kategorie = 'Optimieren'
        Erklaerung = 'Eine fast volle Systemplatte bremst Windows spuerbar aus (Auslagerung, Updates, Temp). Behebt: loescht nur temporaere Dateien und Caches (wie "Datenmuell") - deine eigenen Dateien bleiben unangetastet.'
        NeedsAdmin = $false; AutoFix = $true
        Scan = {
            $disk = Get-PSDrive C
            $freePct = [math]::Round(100 * $disk.Free / ($disk.Used + $disk.Free))
            $freeGB = [math]::Round($disk.Free / 1GB, 1)
            @{ Found = ($freePct -lt 15); Count = $freePct; SizeMB = 0
               Details = @("$freeGB GB frei ($freePct%)")
               Summary = "$freeGB GB frei ($freePct%)"; Critical = ($freePct -lt 10) }
        }
        Fix = { Invoke-SysPilotCleanup }
    }

    $items += @{
        Id = 'services'; Name = 'Dienste-Optimierung'; Kategorie = 'Optimieren'
        Erklaerung = 'Stellt gepruefte Windows-Dienste auf "Manuell" (starten nur bei Bedarf) statt "Automatisch". WICHTIG: Die Liste in config.json ist bewusst konservativ - sie enthaelt KEINE Dienste fuer Netzwerkerkennung (FDResPub, SSDPSRV), Dateifreigabe (LanmanServer), Samba/SMB oder Standort. Diese bleiben unangetastet, damit Netzwerkgeraete, Freigaben und Ortungsdienste weiter funktionieren, wenn du sie nutzt.'
        NeedsAdmin = $true; AutoFix = $true
        Scan = {
            $pending = @(Get-SysPilotServicePlan | Where-Object { $_.Aenderung })
            @{ Found = ($pending.Count -gt 0); Count = $pending.Count; SizeMB = 0
               Details = @($pending | Select-Object -First 5 | ForEach-Object { "$($_.Name): $($_.Ist) -> $($_.Soll)" })
               Summary = "$($pending.Count) Dienste optimierbar" }
        }
        Fix = {
            $changes = @(Get-SysPilotServicePlan | Where-Object { $_.Aenderung })
            $ok = 0; $i = 0
            foreach ($r in $changes) {
                $i++
                Write-SysPilotProgress -Activity 'Dienste optimieren' -Current $i -Total $changes.Count -Status $r.Name
                if (Set-SysPilotService -Row $r) { $ok++ }
            }
            Complete-SysPilotProgress
            Write-Host "  [OK] $ok von $($changes.Count) Diensten optimiert" -ForegroundColor Green
        }
    }

    $items += @{
        Id = 'bloat'; Name = 'Bloatware-Radar'; Kategorie = 'Optimieren'
        Erklaerung = 'Findet bekannte Werbe-Apps und Ressourcenfresser. Aendert hier NICHTS - zum Entfernen oeffnest du den Bloatware-Finder, der jede App einzeln zeigt und erst nach deiner Bestaetigung deinstalliert.'
        NeedsAdmin = $false; AutoFix = $false; MenuAction = 'bloat'
        Scan = {
            $flagged = @(Get-SysPilotInstalled | Where-Object { $_.Hinweis -and $_.Hinweis -notmatch 'Optimizer-Duplikate' })
            @{ Found = ($flagged.Count -gt 0); Count = $flagged.Count; SizeMB = 0
               Details = @($flagged | Select-Object -First 5 | ForEach-Object { $_.DisplayName })
               Summary = "$($flagged.Count) bekannte Bloatware gefunden" }
        }
        Fix = $null
    }

    $items += @{
        Id = 'optimizers'; Name = 'Optimizer-Duplikate'; Kategorie = 'Optimieren'
        Erklaerung = 'Mehrere PC-Optimizer gleichzeitig bremsen sich gegenseitig aus (jeder scannt staendig). Aendert hier NICHTS - zum Ausmisten oeffnest du den Optimizer-Manager, der jede App zeigt und erst nach deiner Wahl deinstalliert.'
        NeedsAdmin = $false; AutoFix = $false; MenuAction = 'optimizers'
        Scan = {
            $opts = @(Get-SysPilotInstalled | Where-Object { $_.Hinweis -match 'Optimizer-Duplikate' })
            @{ Found = ($opts.Count -gt 1); Count = $opts.Count; SizeMB = 0
               Details = @($opts | ForEach-Object { $_.DisplayName })
               Summary = "$($opts.Count) Optimizer installiert" }
        }
        Fix = $null
    }

    $items += @{
        Id = 'netrepair'; Name = 'Netzwerk-Check'; Kategorie = 'Sicherheit'
        Erklaerung = 'Prueft nur, ob Internet, DNS und Proxy in Ordnung sind - aendert hier NICHTS. Bei Problemen oeffnet NETREPAIR (Toolbox) eine Auswahl, in der du jede Reparatur einzeln siehst und bestaetigst. WICHTIG: NETREPAIR setzt auf Wunsch TCP/IP, Winsock, DNS oder die Firewall zurueck - es schaltet NICHT die Netzwerkerkennung, Dateifreigabe oder Samba ab. Diese bleiben aktiv, wenn du sie nutzt.'
        NeedsAdmin = $false; AutoFix = $false; MenuAction = 'netrepair'
        Scan = {
            $details = @(); $problems = 0

            # 1) Internet-Erreichbarkeit (ICMP + HTTP)
            $online = Test-Connection -ComputerName '8.8.8.8' -Count 1 -Quiet -ErrorAction SilentlyContinue
            if ($online) { $details += 'Internet: erreichbar (8.8.8.8)' } else { $problems++; $details += 'Internet: NICHT erreichbar' }

            # 2) DNS-Aufloesung
            try {
                $null = [System.Net.Dns]::GetHostAddresses('www.microsoft.com')
                $details += 'DNS: funktioniert'
            } catch { $problems++; $details += 'DNS: FEHLER (Namen werden nicht aufgeloest)' }

            # 3) Unerwarteter Proxy aktiv?
            $proxy = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
            if ($proxy -and $proxy.ProxyEnable -eq 1) {
                $problems++; $details += "Proxy: AKTIV ($($proxy.ProxyServer)) - unerwartet? NETREPAIR kann ihn zuruecksetzen"
            } else { $details += 'Proxy: aus (Standard)' }

            @{ Found = ($problems -gt 0); Count = $problems; SizeMB = 0; Details = $details
               Summary = if ($problems -eq 0) { 'Verbindung, DNS und Proxy in Ordnung' } else { "$problems Problem(e) - NETREPAIR kann helfen" } }
        }
        Fix = $null
    }

    $items += @{
        Id = 'temp'; Name = 'Temperatur'; Kategorie = 'Optimieren'
        Erklaerung = 'Ein heisser Laptop drosselt sich selbst (wird langsam) und altert schneller. Behebt: aktiviert den SysPilot Kuehl-Plan (CPU-Boost aus, passive Kuehlung) - das senkt die Temperatur, kostet aber etwas Spitzenleistung. Jederzeit ueber die GUI wieder auf Leistung schaltbar.'
        NeedsAdmin = $false; AutoFix = $true
        Scan = {
            $t = Get-SysPilotCpuTemperature
            $c = $t.Celsius
            $found = ($c -ge 80)
            @{ Found = $found; Count = [int]$c; SizeMB = 0
               Details = @("$([math]::Round($c)) Grad Celsius$(if ($t.Geschaetzt) { ' (geschaetzt)' })")
               Summary = "$([math]::Round($c)) C$(if ($t.Geschaetzt) { ' (geschaetzt)' })"; Critical = ($c -ge 90) }
        }
        Fix = {
            Set-SysPilotPlan -Mode Cool
            Write-Host '  [OK] Kuehl-Plan aktiviert (Boost aus, passive Kuehlung)' -ForegroundColor Green
        }
    }

    return $items
}

# ---------- Scan-Engine (UI-unabhaengig, auch fuer GUI) ----------

function Invoke-SysPilotCheckupScan {
    <# Fuehrt alle Checks aus. Gibt Ergebnis-Objekte zurueck.
       -Quiet: keine Konsolenausgabe (fuer GUI). #>
    param([switch]$Quiet)
    $items = Get-SysPilotCheckupItems
    $results = @()
    $i = 0
    foreach ($item in $items) {
        $i++
        if (-not $Quiet) {
            Write-SysPilotProgress -Activity 'Automatic Checkup laeuft' -Current $i -Total $items.Count -Status $item.Name
        }
        $r = [PSCustomObject]@{
            Id         = $item.Id
            Name       = $item.Name
            Kategorie  = $item.Kategorie
            Erklaerung = $item.Erklaerung
            NeedsAdmin = $item.NeedsAdmin
            AutoFix    = $item.AutoFix
            MenuAction = $item.MenuAction
            Status     = 'OK'
            Found      = $false
            Count      = 0
            SizeMB     = 0
            Summary    = ''
            Details    = @()
            Critical   = $false
            Skipped    = $false
        }
        if ($item.NeedsAdmin -and -not (Test-SysPilotAdmin)) {
            $r.Skipped = $true
            $r.Summary = 'uebersprungen (braucht Admin)'
        } else {
            try {
                $scan = & $item.Scan
                $r.Found = [bool]$scan.Found
                $r.Count = $scan.Count
                $r.SizeMB = $scan.SizeMB
                $r.Summary = $scan.Summary
                $r.Details = @($scan.Details)
                $r.Critical = [bool]$scan.Critical
                if ($r.Found) { $r.Status = if ($r.Critical) { 'Kritisch' } else { 'Hinweis' } }
            } catch {
                $r.Skipped = $true
                $r.Summary = "Fehler beim Scan: $($_.Exception.Message)"
            }
        }
        $results += $r
    }
    if (-not $Quiet) { Complete-SysPilotProgress }
    return $results
}

function Invoke-SysPilotCheckupFix {
    <# Behebt die uebergebenen Ergebnisse (Objekte aus Invoke-SysPilotCheckupScan). #>
    param([Parameter(Mandatory)][array]$Results)
    $items = Get-SysPilotCheckupItems
    $isAdmin = Test-SysPilotAdmin
    $fixed = 0; $i = 0
    $toFix = @($Results | Where-Object { $_.Found -and $_.AutoFix })
    foreach ($r in $toFix) {
        $i++
        Write-SysPilotProgress -Activity 'Probleme werden behoben' -Current $i -Total $toFix.Count -Status $r.Name
        $item = $items | Where-Object { $_.Id -eq $r.Id } | Select-Object -First 1
        if (-not $item -or -not $item.Fix) { continue }
        if ($item.NeedsAdmin -and -not $isAdmin) {
            Write-Host "  [uebersprungen] $($r.Name) (braucht Admin)" -ForegroundColor DarkYellow
            continue
        }
        Write-Host ""
        Write-Host "  >> $($r.Name)" -ForegroundColor Cyan
        try {
            & $item.Fix
            $fixed++
        } catch {
            Write-Host "  [!] Fehler: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    Complete-SysPilotProgress
    Write-SysPilotLog "Checkup: $fixed Bereiche automatisch behoben"
    return $fixed
}

# ---------- Checkup-Zeitplan (geplante Aufgabe) ----------

function Get-SysPilotCheckupSchedule {
    <# Liest den Zeitplan aus config.json -> Checkup.Schedule. #>
    $cfg = Get-SysPilotConfig
    $s = $cfg.Checkup.Schedule
    if (-not $s) {
        $s = [PSCustomObject]@{ Enabled = $false; Frequency = 'Daily'; Weekday = 'Sunday'; Time = '03:00'; AutoFix = $true }
    }
    return $s
}

function Save-SysPilotCheckupSchedule {
    param([bool]$Enabled, [string]$Frequency, [string]$Weekday, [string]$Time, [bool]$AutoFix)
    $path = Join-Path $script:SysPilotRoot 'config.json'
    $json = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $json.Checkup) { $json | Add-Member -NotePropertyName Checkup -NotePropertyValue ([PSCustomObject]@{}) -Force }
    $sched = [PSCustomObject]@{ Enabled = $Enabled; Frequency = $Frequency; Weekday = $Weekday; Time = $Time; AutoFix = $AutoFix }
    if ($json.Checkup.PSObject.Properties['Schedule']) { $json.Checkup.Schedule = $sched }
    else { $json.Checkup | Add-Member -NotePropertyName Schedule -NotePropertyValue $sched -Force }
    $json | ConvertTo-Json -Depth 10 | Set-Content $path -Encoding UTF8
    Reset-SysPilotConfig
}

function Install-SysPilotCheckupTask {
    <# Registriert die geplante Aufgabe "SysPilot Checkup" nach dem gespeicherten Zeitplan. #>
    if (-not (Assert-SysPilotAdmin)) { return $false }
    $s = Get-SysPilotCheckupSchedule
    $exe = 'powershell.exe'
    if ($PSVersionTable.PSEdition -eq 'Core') { $exe = 'pwsh.exe' }
    $scriptPath = Join-Path $script:SysPilotRoot 'SysPilot.ps1'
    $action = New-ScheduledTaskAction -Execute $exe -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" -CheckupAuto"
    $trigger = $null
    $time = [DateTime]::ParseExact($s.Time, 'HH:mm', $null)
    if ($s.Frequency -eq 'Daily') {
        $trigger = New-ScheduledTaskTrigger -Daily -At $time
    } else {
        $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $s.Weekday -At $time
    }
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    Register-ScheduledTask -TaskName 'SysPilot Checkup' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-SysPilotLog "Checkup-Zeitplan installiert: $($s.Frequency) $($s.Weekday) $($s.Time)"
    return $true
}

function Remove-SysPilotCheckupTask {
    if (-not (Assert-SysPilotAdmin)) { return }
    Unregister-ScheduledTask -TaskName 'SysPilot Checkup' -Confirm:$false -ErrorAction SilentlyContinue
    Write-SysPilotLog 'Checkup-Zeitplan entfernt'
}

function Show-SysPilotCheckupScheduleMenu {
    <# Zeitplan einstellen: taeglich / Wochentag / Uhrzeit / Auto-Fix. #>
    while ($true) {
        $s = Get-SysPilotCheckupSchedule
        $task = Get-ScheduledTask -TaskName 'SysPilot Checkup' -ErrorAction SilentlyContinue
        $statusTxt = if ($task -and $s.Enabled) { "AKTIV: $($s.Frequency) $($s.Weekday) um $($s.Time)" } else { 'AUS' }
        $freqTxt = if ($s.Frequency -eq 'Daily') { 'Taeglich' } else { "Woechtentlich ($($s.Weekday))" }
        $fixTxt = if ($s.AutoFix) { 'AN (behebt automatisch)' } else { 'AUS (nur pruefen)' }

        $items = @(
            @{ Label = "Status: $statusTxt  (Enter = an/aus)"; Color = $(if ($task -and $s.Enabled) { 'Green' } else { 'Yellow' }); Tag = 'toggle' },
            @{ Label = "Wie oft: $freqTxt"; Color = 'White'; Tag = 'freq' },
            @{ Label = "Uhrzeit: $($s.Time)"; Color = 'White'; Tag = 'time' },
            @{ Label = "Automatisch beheben: $fixTxt"; Color = 'White'; Tag = 'autofix' },
            @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = $null }
        )
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'Checkup-Zeitplan' -Footer 'Pfeiltasten, Enter = aendern, Esc = zurueck'
        if ($null -eq $sel) { return }

        switch ($sel) {
            'toggle' {
                if ($task -and $s.Enabled) {
                    Save-SysPilotCheckupSchedule -Enabled $false -Frequency $s.Frequency -Weekday $s.Weekday -Time $s.Time -AutoFix $s.AutoFix
                    Remove-SysPilotCheckupTask
                    Write-Host '  [OK] Zeitplan deaktiviert.' -ForegroundColor Yellow
                } else {
                    Save-SysPilotCheckupSchedule -Enabled $true -Frequency $s.Frequency -Weekday $s.Weekday -Time $s.Time -AutoFix $s.AutoFix
                    if (Install-SysPilotCheckupTask) { Write-Host '  [OK] Zeitplan aktiviert.' -ForegroundColor Green }
                }
                Read-SysPilotChoice 'Weiter' | Out-Null
            }
            'freq' {
                $fItems = @(
                    @{ Label = 'Taeglich'; Color = 'White'; Tag = 'Daily' },
                    @{ Label = 'Woechtentlich - Montag'; Color = 'White'; Tag = 'Monday' },
                    @{ Label = 'Woechtentlich - Dienstag'; Color = 'White'; Tag = 'Tuesday' },
                    @{ Label = 'Woechtentlich - Mittwoch'; Color = 'White'; Tag = 'Wednesday' },
                    @{ Label = 'Woechtentlich - Donnerstag'; Color = 'White'; Tag = 'Thursday' },
                    @{ Label = 'Woechtentlich - Freitag'; Color = 'White'; Tag = 'Friday' },
                    @{ Label = 'Woechtentlich - Samstag'; Color = 'White'; Tag = 'Saturday' },
                    @{ Label = 'Woechtentlich - Sonntag'; Color = 'White'; Tag = 'Sunday' }
                )
                $f = Show-SysPilotArrowMenu -Items $fItems -Title 'Wie oft soll der Checkup laufen?'
                if ($f) {
                    if ($f -eq 'Daily') {
                        Save-SysPilotCheckupSchedule -Enabled $s.Enabled -Frequency 'Daily' -Weekday $s.Weekday -Time $s.Time -AutoFix $s.AutoFix
                    } else {
                        Save-SysPilotCheckupSchedule -Enabled $s.Enabled -Frequency 'Weekly' -Weekday $f -Time $s.Time -AutoFix $s.AutoFix
                    }
                    if ($task -and $s.Enabled) { Install-SysPilotCheckupTask | Out-Null }
                    Write-Host '  [OK] Haeufigkeit gespeichert.' -ForegroundColor Green
                    Read-SysPilotChoice 'Weiter' | Out-Null
                }
            }
            'time' {
                $t = Read-SysPilotChoice 'Uhrzeit (HH:MM, z.B. 03:00 oder 18:30)'
                if ($t -match '^([01]?\d|2[0-3]):[0-5]\d$') {
                    $tNorm = [DateTime]::ParseExact($t, 'H:mm', $null).ToString('HH:mm')
                    Save-SysPilotCheckupSchedule -Enabled $s.Enabled -Frequency $s.Frequency -Weekday $s.Weekday -Time $tNorm -AutoFix $s.AutoFix
                    if ($task -and $s.Enabled) { Install-SysPilotCheckupTask | Out-Null }
                    Write-Host "  [OK] Uhrzeit: $tNorm" -ForegroundColor Green
                } else {
                    Write-Host '  [!] Ungueltiges Format. Bitte HH:MM (z.B. 03:00).' -ForegroundColor Red
                }
                Read-SysPilotChoice 'Weiter' | Out-Null
            }
            'autofix' {
                Save-SysPilotCheckupSchedule -Enabled $s.Enabled -Frequency $s.Frequency -Weekday $s.Weekday -Time $s.Time -AutoFix (-not $s.AutoFix)
                Write-Host ('  [OK] Automatisch beheben: ' + $(if (-not $s.AutoFix) { 'AN' } else { 'AUS' })) -ForegroundColor Green
                Read-SysPilotChoice 'Weiter' | Out-Null
            }
        }
    }
}

# ---------- Konsolen-UI ----------

function Show-SysPilotCheckup {
    Write-SysPilotHeader 'AUTOMATIC CHECKUP'
    Write-Host '  SysPilot prueft deinen PC in 15 Bereichen - ehrlich, mit Erklaerung' -ForegroundColor DarkGray
    Write-Host '  und echter Reparatur. Kein erfundener Verkaufsdruck wie bei Kauf-Optimizern.' -ForegroundColor DarkGray
    Write-Host ''

    $results = Invoke-SysPilotCheckupScan

    # Ergebnis-Uebersicht
    Write-Host ''
    Write-Host '  ERGEBNIS:' -ForegroundColor Cyan
    foreach ($r in $results) {
        $icon = if ($r.Skipped) { '[?]' } elseif (-not $r.Found) { '[OK]' } elseif ($r.Critical) { '[!]' } else { '[i]' }
        $color = if ($r.Skipped) { 'DarkGray' } elseif (-not $r.Found) { 'Green' } elseif ($r.Critical) { 'Red' } else { 'Yellow' }
        $line = '  {0,-4} {1,-28} {2}' -f $icon, $r.Name, $r.Summary
        Write-Host $line -ForegroundColor $color
    }
    $foundCount = @($results | Where-Object { $_.Found }).Count
    $critCount = @($results | Where-Object { $_.Critical -and $_.Found }).Count
    Write-Host ''
    if ($foundCount -eq 0) {
        Write-Host '  Alles sauber - dein PC ist in Topform!' -ForegroundColor Green
        return
    }
    Write-Host "  $foundCount Bereiche mit Befunden, davon $critCount kritisch." -ForegroundColor $(if ($critCount) { 'Red' } else { 'Yellow' })

    # Auswahl: alles / einzeln / Zeitplan
    $menuItems = @(
        @{ Label = "ALLE automatisch behebaren Probleme beheben (empfohlen)"; Color = 'Green'; Tag = 'all' },
        @{ Label = "Eintraege EINZELN ansehen und auswaehlen (mit Erklaerungen)"; Color = 'White'; Tag = 'pick' },
        @{ Label = "ZEITPLAN: Checkup automatisch laufen lassen (taeglich/woechentlich)"; Color = 'Cyan'; Tag = 'schedule' },
        @{ Label = "Zurueck"; Color = 'DarkGray'; Tag = $null }
    )
    $sel = Show-SysPilotArrowMenu -Items $menuItems -Title 'Was moechtest du tun?'
    if ($null -eq $sel) { return }
    if ($sel -eq 'schedule') { Show-SysPilotCheckupScheduleMenu; return }

    if ($sel -eq 'all') {
        $fixable = @($results | Where-Object { $_.Found -and $_.AutoFix })
        if ($fixable.Count -eq 0) {
            Write-Host '  Keine automatisch behebbaren Probleme - sieh dir die Eintraege einzeln an.' -ForegroundColor Yellow
            Read-SysPilotChoice 'Weiter' | Out-Null
            return
        }
        Write-Host ''
        Write-Host "  Folgende $($fixable.Count) Bereiche werden jetzt behoben:" -ForegroundColor Cyan
        $fixable | ForEach-Object { Write-Host "    - $($_.Name)" -ForegroundColor DarkGray }
        if (Confirm-SysPilot 'Starten?') {
            Invoke-SysPilotCheckupFix -Results $fixable | Out-Null
            Write-Host ''
            Write-Host '  FERTIG. Starte den Checkup erneut, um das Ergebnis zu pruefen.' -ForegroundColor Green
        }
        Read-SysPilotChoice 'Weiter' | Out-Null
        return
    }

    # Einzelansicht mit Erklaerung + Fix
    while ($true) {
        $pickItems = @()
        foreach ($r in $results) {
            $icon = if ($r.Skipped) { '[?]' } elseif (-not $r.Found) { '[OK]' } elseif ($r.Critical) { '[!]' } else { '[i]' }
            $color = if ($r.Skipped) { 'DarkGray' } elseif (-not $r.Found) { 'Green' } elseif ($r.Critical) { 'Red' } else { 'Yellow' }
            $pickItems += @{ Label = "$icon $($r.Name) - $($r.Summary)"; Color = $color; Tag = $r.Id }
        }
        $pickItems += @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = $null }
        $pick = Show-SysPilotArrowMenu -Items $pickItems -Title 'Checkup-Details (Enter = Details + Reparatur)'
        if ($null -eq $pick) { return }

        $r = $results | Where-Object { $_.Id -eq $pick } | Select-Object -First 1
        Write-SysPilotHeader $r.Name
        Write-Host "  Kategorie: $($r.Kategorie)" -ForegroundColor DarkGray
        Write-Host ''
        Write-Host "  Was ist das? $($r.Erklaerung)" -ForegroundColor White
        Write-Host ''
        Write-Host "  Befund: $($r.Summary)" -ForegroundColor $(if ($r.Found) { 'Yellow' } else { 'Green' })
        if ($r.Details.Count -gt 0) {
            $r.Details | ForEach-Object { Write-Host "    - $_" -ForegroundColor DarkGray }
        }
        Write-Host ''

        if (-not $r.Found) {
            Read-SysPilotChoice 'Weiter' | Out-Null
            continue
        }
        if ($r.AutoFix) {
            if ($r.NeedsAdmin -and -not (Test-SysPilotAdmin)) {
                Write-Host '  [!] Die Reparatur braucht Admin-Rechte (Menue 16).' -ForegroundColor Yellow
                Read-SysPilotChoice 'Weiter' | Out-Null
                continue
            }
            if (Confirm-SysPilot 'Jetzt automatisch beheben?') {
                Invoke-SysPilotCheckupFix -Results @($r) | Out-Null
                Read-SysPilotChoice 'Weiter' | Out-Null
            }
        } else {
            Write-Host '  Dieser Bereich braucht deine Entscheidung - oeffne das passende Werkzeug:' -ForegroundColor Cyan
            switch ($r.MenuAction) {
                'startup'    { if (Confirm-SysPilot 'Autostart-Manager oeffnen?') { Show-SysPilotStartupManager } }
                'bloat'      { if (Confirm-SysPilot 'Bloatware-Finder oeffnen?') { Show-SysPilotBloatManager } }
                'optimizers' { if (Confirm-SysPilot 'Optimizer-Manager oeffnen?') { Show-SysPilotOptimizerManager; Read-SysPilotChoice 'Weiter' | Out-Null } }
                'netrepair'  { if (Confirm-SysPilot 'NETREPAIR oeffnen? (braucht Admin)') { Show-SysPilotNetworkRepair } }
            }
        }
    }
}

# ---------- GUI-Window ----------
function Show-SysPilotCheckupWindow {
    <# Checkup als WPF-Fenster: Ergebnisse mit Erklaerungen, Tips, HowTo-Links, Checkboxen zum Auswaehlen. #>
    $results = Invoke-SysPilotCheckupScan

    $window = New-Object System.Windows.Window
    $window.Title = 'SysPilot - Automatic Checkup'
    $window.Width = 900; $window.Height = 700
    $window.WindowStartupLocation = 'CenterScreen'

    $grid = New-Object System.Windows.Controls.Grid
    $grid.Margin = '14'
    $grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Height Auto))
    $grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Height '*'))
    $grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Height Auto))

    # Header
    $title = New-Object System.Windows.Controls.TextBlock
    $title.Text = 'Automatic Checkup - 15 Bereiche mit Erklaerungen'
    $title.FontSize = 20; $title.FontWeight = 'Bold'; $title.Foreground = '#FF4FC3F7'
    [System.Windows.Controls.Grid]::SetRow($title,0); $grid.Children.Add($title)|Out-Null

    # Info text
    $info = New-Object System.Windows.Controls.TextBlock
    $info.Text = 'Jeder Bereich hat eine ehrliche Erklaerung. Fixes einzeln abwaehlbar. VPN-Adapter werden nie automatisch veraendert.'
    $info.Margin = '0,4,0,8'; $info.TextWrapping = 'Wrap'
    [System.Windows.Controls.Grid]::SetRow($info,1); $grid.Children.Add($info)|Out-Null

    # Scrollable list
    $scroll = New-Object System.Windows.Controls.ScrollViewer
    $scroll.VerticalScrollBarVisibility = 'Auto'
    $listPanel = New-Object System.Windows.Controls.StackPanel
    $listPanel.Orientation = 'Vertical'

    $script:checkupSelectedFixes = @()

    foreach ($r in $results) {
        $itemPanel = New-Object System.Windows.Controls.StackPanel
        $itemPanel.Orientation = 'Vertical'
        $itemPanel.Margin = '0,8,0,8'
        $itemPanel.Background = if ($r.Found) { '#FF3A3A45' } else { '#FF2A2A30' }

        # Icon + Name + Summary
        $headerRow = New-Object System.Windows.Controls.DockPanel
        $icon = New-Object System.Windows.Controls.TextBlock
        $icon.Text = if ($r.Skipped) { '[?]' } elseif (-not $r.Found) { '[OK]' } elseif ($r.Critical) { '[!]' } else { '[i]' }
        $icon.FontWeight = 'Bold'; $icon.Width = 30
        $icon.Foreground = if ($r.Skipped) { 'DarkGray' } elseif (-not $r.Found) { 'Green' } elseif ($r.Critical) { 'Red' } else { 'Yellow' }
        [System.Windows.Controls.DockPanel]::SetDock($icon,'Left'); $headerRow.Children.Add($icon)|Out-Null

        $nameText = New-Object System.Windows.Controls.TextBlock
        $nameText.Text = $r.Name; $nameText.FontWeight = 'Bold'; $nameText.Margin = '4,0,0,0'
        $headerRow.Children.Add($nameText)|Out-Null

        $summaryText = New-Object System.Windows.Controls.TextBlock
        $summaryText.Text = $r.Summary; $summaryText.Foreground = 'DarkGray'; $summaryText.Margin = '8,0,0,0'
        $headerRow.Children.Add($summaryText)|Out-Null
        $itemPanel.Children.Add($headerRow)|Out-Null

        # Erklaerung
        $explText = New-Object System.Windows.Controls.TextBlock
        $explText.Text = "Was ist das? $($r.Erklaerung)"
        $explText.TextWrapping = 'Wrap'; $explText.Margin = '24,2,0,2'; $explText.FontSize = 11; $explText.Foreground = '#FFCCCCCC'
        $itemPanel.Children.Add($explText)|Out-Null

        # Tip
        if ($r.Tip) {
            $tipText = New-Object System.Windows.Controls.TextBlock
            $tipText.Text = "Tipp: $($r.Tip)"
            $tipText.TextWrapping = 'Wrap'; $tipText.Margin = '24,0,0,4'; $tipText.FontSize = 10; $tipText.Foreground = '#FFAAAAAA'
            $itemPanel.Children.Add($tipText)|Out-Null
        }

        # HowTo link
        if ($r.HowTo) {
            $howtoText = New-Object System.Windows.Controls.TextBlock
            $howtoText.Text = "HowTo: $($r.HowTo)"
            $howtoText.TextWrapping = 'Wrap'; $howtoText.Margin = '24,0,0,6'; $howtoText.FontSize = 10; $howtoText.Foreground = '#FF4FC3F7'; $howtoText.Cursor = [System.Windows.Input.Cursors]::Hand
            $howtoText.Add_MouseLeftButtonDown({ Start-Process $r.HowTo })
            $itemPanel.Children.Add($howtoText)|Out-Null
        }

        # Checkbox for fix
        if ($r.Found -and $r.AutoFix) {
            $chk = New-Object System.Windows.Controls.CheckBox
            $chk.Content = 'Automatisch beheben'
            $chk.IsChecked = $true
            $chk.Margin = '24,2,0,6'
            $chk.Tag = $r.Id
            $chk.Add_Checked({ $script:checkupSelectedFixes += $chk.Tag })
            $chk.Add_Unchecked({ $script:checkupSelectedFixes = @($script:checkupSelectedFixes | Where-Object { $_ -ne $chk.Tag }) })
            $itemPanel.Children.Add($chk)|Out-Null
        }

        $scroll.Content = $listPanel
        $listPanel.Children.Add($itemPanel)|Out-Null
    }

    [System.Windows.Controls.Grid]::SetRow($scroll,2); $grid.Children.Add($scroll)|Out-Null

    # Buttons
    $btnPanel = New-Object System.Windows.Controls.StackPanel
    $btnPanel.Orientation = 'Horizontal'; $btnPanel.HorizontalAlignment = 'Center'
    $btnFix = New-Object System.Windows.Controls.Button
    $btnFix.Content = 'Ausgewählte beheben'; $btnFix.Margin = '4'; $btnFix.Width = 140
    $btnClose = New-Object System.Windows.Controls.Button
    $btnClose.Content = 'Schließen'; $btnClose.Margin = '4'; $btnClose.Width = 100
    $btnPanel.Children.Add($btnFix)|Out-Null; $btnPanel.Children.Add($btnClose)|Out-Null
    [System.Windows.Controls.Grid]::SetRow($btnPanel,3); $grid.Children.Add($btnPanel)|Out-Null

    $btnFix.Add_Click({
        if ($script:checkupSelectedFixes.Count -eq 0) {
            [System.Windows.MessageBox]::Show('Bitte waehle mindestens einen Bereich zum Beheben aus.', 'Checkup', 'OK', 'Information') | Out-Null
            return
        }
        $fixable = @($results | Where-Object { $_.Found -and $_.AutoFix -and $script:checkupSelectedFixes -contains $_.Id })
        if ($fixable.Count -eq 0) {
            [System.Windows.MessageBox]::Show('Keine automatisch behebbaren Bereiche ausgewaehlt.', 'Checkup', 'OK', 'Information') | Out-Null
            return
        }
        $adminNeeded = @($fixable | Where-Object { $_.NeedsAdmin })
        if ($adminNeeded.Count -gt 0 -and -not (Test-SysPilotAdmin)) {
            [System.Windows.MessageBox]::Show("Einige Reparaturen brauchen Admin-Rechte. Bitte als Admin neu starten." + "`n`n" + ($adminNeeded | ForEach-Object { $_.Name } -join ', '), 'Admin noetig', 'OK', 'Warning') | Out-Null
            return
        }
        Invoke-SysPilotCheckupFix -Results $fixable | Out-Null
        [System.Windows.MessageBox]::Show("Fertig. $($fixable.Count) Bereiche bearbeitet. Starte den Checkup erneut zum Pruefen.", 'Checkup', 'OK', 'Information') | Out-Null
        $window.Close()
    })

    $btnClose.Add_Click({ $window.Close() })

    $window.Content = $grid
    $window.ShowDialog() | Out-Null
}

Export-ModuleMember -Function Get-SysPilotCheckupItems, Invoke-SysPilotCheckupScan, Invoke-SysPilotCheckupFix,
    Show-SysPilotCheckup, Show-SysPilotCheckupWindow, Find-SysPilotBrokenShortcuts, Get-SysPilotRegistryOrphans, Get-SysPilotSecurityStatus,
    Get-SysPilotFolderSizeMB, Get-SysPilotCheckupSchedule, Save-SysPilotCheckupSchedule,
    Install-SysPilotCheckupTask, Remove-SysPilotCheckupTask, Show-SysPilotCheckupScheduleMenu
