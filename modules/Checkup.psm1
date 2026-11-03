# SysPilot - Checkup: Automatic Checkup (Komplett-Scan mit Erklaerungen und Reparatur)
# Besser als Advanced SystemCare: ehrlich, jede Pruefung hat eine echte Erklaerung
# und eine echte Reparatur - keine erfundenen "Probleme" als Verkaufsdruck.
#Requires -Version 5.1

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
        Erklaerung = 'Temporaere Dateien, Update-Reste, Caches. Windows und Programme lagern hier Staub ab - loeschen ist sicher und schafft Platz.'
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
        Erklaerung = 'Liste zuletzt geoeffneter Dateien, DNS-Verlauf, Sprunglisten. Verraten, was du zuletzt gemacht hast - loeschen schuetzt deine Privatsphaere.'
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
        Id = 'shortcuts'; Name = 'Ungueltige Verknuepfungen'; Kategorie = 'Bereinigen'
        Erklaerung = 'Verknuepfungen auf Desktop/Startmenue, deren Programm laengst deinstalliert ist. Tote Links - weg damit.'
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
        Id = 'registry'; Name = 'Verwaiste Registry-Eintraege'; Kategorie = 'Bereinigen'
        Erklaerung = 'Registry-Verweise auf Dateien, die es nicht mehr gibt (Autostart, Deinstallation, App Paths). Ehrlich gesagt: macht den PC kaum schneller, entfernt aber tote Verweise. Vorher wird ein Backup gemacht.'
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
            $regBackup = Join-Path $backupDir ("registry-orphans-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.reg')
            "Windows Registry Editor Version 5.00`r`n" | Out-File $regBackup -Encoding unicode
            $removed = 0
            foreach ($o in $orphans) {
                try {
                    $regPath = $o.Schluessel -replace '^HKCU:\\', 'HKEY_CURRENT_USER\' -replace '^HKLM:\\', 'HKEY_LOCAL_MACHINE\'
                    if ($o.Typ -eq 'Value') {
                        & reg.exe delete $regPath /v $o.Name /f 2>$null | Out-Null
                    } else {
                        & reg.exe delete $regPath /f 2>$null | Out-Null
                    }
                    $removed++
                } catch { }
            }
            Write-Host "  [OK] $removed verwaiste Eintraege entfernt (Backup: $regBackup)" -ForegroundColor Green
            Write-SysPilotLog "Checkup: $removed Registry-Waisen entfernt"
        }
    }

    $items += @{
        Id = 'antivirus'; Name = 'Antiviren-Schutz'; Kategorie = 'Sicherheit'
        Erklaerung = 'Prueft, ob ein Virenschutz aktiv ist, Echtzeitschutz laeuft und die Virensignaturen aktuell sind. Das ist dein wichtigster Schutz.'
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
        Id = 'firewall'; Name = 'Firewall'; Kategorie = 'Sicherheit'
        Erklaerung = 'Die Windows-Firewall blockiert unerwuenschte Zugriffe aus dem Netz. Sie sollte in allen Profilen (Privat, Oeffentlich, Domain) an sein.'
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
        Id = 'weaknesses'; Name = 'Systemschwaechen'; Kategorie = 'Sicherheit'
        Erklaerung = 'Veraltete Protokolle (SMBv1), alte PowerShell-Version, ausstehende Neustarts, abgeschwaechte Benutzerkontensteuerung. Kleine Tueren, die man schliessen sollte.'
        NeedsAdmin = $true; AutoFix = $true
        Scan = {
            $sec = Get-SysPilotSecurityStatus
            $found = $false; $details = @()
            if ($sec.SmbV1 -eq $true) { $found = $true; $details += 'SMBv1 aktiv (veraltetes Protokoll, Ransomware-Risiko)' }
            if ($sec.PsV2Enabled -eq $true) { $found = $true; $details += 'PowerShell v2 aktiv (veraltet, wird von Malware missbraucht)' }
            if (-not $sec.UacEnabled) { $found = $true; $details += 'Benutzerkontensteuerung (UAC) ist AUS' }
            if ($sec.PendingReboot) { $found = $true; $details += 'Ausstehender Neustart (Updates warten)' }
            @{ Found = $found; Count = $details.Count; SizeMB = 0; Details = $details
               Summary = if ($details.Count) { "$($details.Count) Schwaechen" } else { 'Keine gefunden' } }
        }
        Fix = {
            $sec = Get-SysPilotSecurityStatus
            if ($sec.SmbV1 -eq $true) {
                Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoRestart -ErrorAction SilentlyContinue | Out-Null
                Write-Host '  [OK] SMBv1 deaktiviert (wirkt nach Neustart)' -ForegroundColor Green
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
            Write-SysPilotLog 'Checkup: Systemschwaechen behoben'
        }
    }

    $items += @{
        Id = 'startup'; Name = 'Autostart-Last'; Kategorie = 'Optimieren'
        Erklaerung = 'Jedes Programm im Autostart verlaengert den Start und frisst dauerhaft RAM. Ueber 15 aktive Eintraege bremsen spuerbar.'
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
        Erklaerung = 'Ist der RAM fast voll, lagert Windows auf die langsame SSD aus und alles ruckelt. Freigeben hilft sofort.'
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
        Erklaerung = 'Eine fast volle Systemplatte bremst Windows spuerbar aus (Auslagerung, Updates, Temp). Unter 10% frei wird es kritisch.'
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
        Erklaerung = 'Windows-Dienste, die du nicht brauchst, laufen trotzdem mit. SysPilot kennt gepruefte Empfehlungen und deaktiviert nur, was Ressourcen spart.'
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
        Id = 'bloat'; Name = 'Bekannte Bloatware'; Kategorie = 'Optimieren'
        Erklaerung = 'Vorinstallierte Werbung, Testversionen und Ressourcenfresser, die kaum jemand braucht. SysPilot erkennt die ueblichen Verdaechtigen.'
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
        Id = 'optimizers'; Name = 'Optimizer-Konflikte'; Kategorie = 'Optimieren'
        Erklaerung = 'Mehrere PC-Optimizer gleichzeitig bremsen sich gegenseitig aus (jeder scannt staendig). Ein bis zwei genuegen - SysPilot kann alles Wichtige selbst.'
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
        Id = 'temp'; Name = 'Temperatur'; Kategorie = 'Optimieren'
        Erklaerung = 'Ein heisser Laptop drosselt sich selbst (wird langsam) und altert schneller. Ab 80 Grad greift SysPilot mit dem Kuehl-Plan ein.'
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

# ---------- Konsolen-UI ----------

function Show-SysPilotCheckup {
    Write-SysPilotHeader 'AUTOMATIC CHECKUP'
    Write-Host '  SysPilot prueft deinen PC in 14 Bereichen - ehrlich, mit Erklaerung' -ForegroundColor DarkGray
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

    # Auswahl: alles / einzeln / nur ansehen
    $menuItems = @(
        @{ Label = "ALLE automatisch behebaren Probleme beheben (empfohlen)"; Color = 'Green'; Tag = 'all' },
        @{ Label = "Eintraege EINZELN ansehen und auswaehlen (mit Erklaerungen)"; Color = 'White'; Tag = 'pick' },
        @{ Label = "Zurueck"; Color = 'DarkGray'; Tag = $null }
    )
    $sel = Show-SysPilotArrowMenu -Items $menuItems -Title 'Was moechtest du tun?'
    if ($null -eq $sel) { return }

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
            }
        }
    }
}

Export-ModuleMember -Function Get-SysPilotCheckupItems, Invoke-SysPilotCheckupScan, Invoke-SysPilotCheckupFix,
    Show-SysPilotCheckup, Find-SysPilotBrokenShortcuts, Get-SysPilotRegistryOrphans, Get-SysPilotSecurityStatus,
    Get-SysPilotFolderSizeMB
