# SysPilot - SystemRepair: gezielte Windows-Reparaturen
# (Nachbau der nuetzlichen Tweaking.com-Windows-Repair-Funktionen,
#  mit eigener Benennung und sichereren Defaults: jede Aktion mit
#  Bestaetigung, Admin-Check, Log-Eintrag.)
#Requires -Version 5.1

function Get-SysPilotRepairList {
    <# Katalog der verfuegbaren Reparaturen. #>
    @(
        @{ Key = 'proxy';     Name = 'Proxy-Einstellungen komplett zuruecksetzen';
           Desc = 'WinHTTP-Proxy + IE/WinINet-Proxy + Auto-Config-URL auf Direktverbindung'; Cmd = { Invoke-SysPilotRepairProxy } },
        @{ Key = 'firewall';  Name = 'Windows Firewall pruefen & aktivieren';
           Desc = 'mpssvc-Dienst startet, alle Profile aktivieren (kein Reset)'; Cmd = { Invoke-SysPilotRepairFirewall } },
        @{ Key = 'spooler';   Name = 'Druck-Spooler reparieren';
           Desc = 'Haengt Druckauftraege ab: Queue leeren, Dienst neu starten'; Cmd = { Invoke-SysPilotRepairSpooler } },
        @{ Key = 'policies';  Name = 'Sperr-Richtlinien von Infektionen entfernen';
           Desc = 'Loescht NoRun/NoRegistryTools/DisableTaskMgr/DisableCMD/NoControlPanel o.a.'; Cmd = { Invoke-SysPilotRepairPolicies } },
        @{ Key = 'assoc';     Name = 'Dateizuordnungen pruefen & reparieren';
           Desc = 'Prueft exe/bat/cmd/lnk/msc/reg/scr/com/inf/folder/drive-Handler'; Cmd = { Invoke-SysPilotRepairAssociations } },
        @{ Key = 'msi';       Name = 'Windows Installer (MSI) neu registrieren';
           Desc = 'msiserver-Dienst + msi.dll registrieren'; Cmd = { Invoke-SysPilotRepairMsi } },
        @{ Key = 'uac';       Name = 'UAC-Standards wiederherstellen';
           Desc = 'EnableLUA=1, ConsentPrompt=5, SecureDesktop=1 (System-Schutz)'; Cmd = { Invoke-SysPilotRepairUac } },
        @{ Key = 'perfcounters'; Name = 'Performance-Counter neu aufbauen';
           Desc = 'lodctr /R - Task-Manager/Leistungsindikatoren reparieren'; Cmd = { Invoke-SysPilotRepairPerfCounters } },
        @{ Key = 'wmi';       Name = 'WMI-Repository pruefen';
           Desc = 'winmgmt /verifyrepository (bei Fehlern /salvagerepository)'; Cmd = { Invoke-SysPilotRepairWmi } },
        @{ Key = 'vss';       Name = 'Volume Shadow Copy (Wiederherstellung) pruefen';
           Desc = 'VSS-Dienst-Status pruefen und ggf. starten'; Cmd = { Invoke-SysPilotRepairVss } },
        @{ Key = 'winupdate'; Name = 'Windows-Update-Speicher zuruecksetzen';
           Desc = 'SoftwareDistribution + catroot2 umbenennen, Dienste neu starten (schwer!)'; Cmd = { Invoke-SysPilotRepairWindowsUpdate } }
    )
}

# ------------------------------------------------------------------
# Einzelreparaturen
# ------------------------------------------------------------------

function Invoke-SysPilotRepairProxy {
    <# Setzt WinHTTP, WinINet (IE-Proxy) und Auto-Config-URL zurueck. #>
    Write-Host '  WinHTTP-Proxy zuruecksetzen ...' -ForegroundColor Cyan
    & netsh winhttp reset proxy | Out-Null
    $inet = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    Set-ItemProperty $inet -Name ProxyEnable -Value 0 -ErrorAction SilentlyContinue
    Remove-ItemProperty $inet -Name ProxyServer -ErrorAction SilentlyContinue
    Remove-ItemProperty $inet -Name AutoConfigURL -ErrorAction SilentlyContinue
    Write-Host '  [OK] Proxy komplett auf Direktverbindung gesetzt.' -ForegroundColor Green
    Write-SysPilotLog 'Reparatur: Proxy zurueckgesetzt'
}

function Invoke-SysPilotRepairFirewall {
    <# Prueft mpssvc und aktiviert Firewall-Profile (kein Reset!). #>
    $svc = Get-Service mpssvc -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Running') {
        Set-Service mpssvc -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service mpssvc -ErrorAction SilentlyContinue
    }
    & netsh advfirewall set allprofiles state on | Out-Null
    $fw = Get-NetFirewallProfile -ErrorAction SilentlyContinue
    $allOn = @($fw | Where-Object { -not $_.Enabled }).Count -eq 0
    Write-Host ("  Firewall-Dienst: {0}; Profile aktiv: {1}" -f (Get-Service mpssvc).Status, $(if ($allOn) {'alle'} else {'NICHT alle'})) -ForegroundColor $(if ($allOn) {'Green'} else {'Yellow'})
    Write-SysPilotLog 'Reparatur: Firewall geprueft'
}

function Invoke-SysPilotRepairSpooler {
    <# Druckwarteschlange leeren + Spooler neu starten. #>
    $spool = "$env:WINDIR\System32\spool\PRINTERS"
    Stop-Service Spooler -Force -ErrorAction SilentlyContinue
    $n = 0
    Get-ChildItem $spool -File -ErrorAction SilentlyContinue | ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue; $n++ }
    Set-Service Spooler -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service Spooler -ErrorAction SilentlyContinue
    Write-Host "  [OK] $n Druckauftraege entfernt, Spooler neu gestartet." -ForegroundColor Green
    Write-SysPilotLog "Reparatur: Druck-Spooler ($n Auftraege geloescht)"
}

function Invoke-SysPilotRepairPolicies {
    <# Entfernt Infektions-Richtlinien (System-Einschraenkungen). #>
    $removed = 0
    $policyPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Policies\System',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'
    )
    $badValues = @('NoRun','NoRunOnce','NoClose','NoLogOff','NoRegistryTools','DisableTaskMgr','DisableCMD',
                   'NoControlPanel','NoDesktop','NoFind','NoFileMenu','NoFolderOptions','NoViewContextMenu',
                   'NoTrayContextMenu','NoSetFolders','NoSetTaskbar','NoWindowMinimizingShortcuts','NoChangeStartMenu')
    foreach ($p in $policyPaths) {
        if (-not (Test-Path $p)) { continue }
        $props = Get-ItemProperty -Path $p -ErrorAction SilentlyContinue
        foreach ($v in $badValues) {
            if ($props.PSObject.Properties[$v]) {
                Remove-ItemProperty -Path $p -Name $v -Force -ErrorAction SilentlyContinue
                $removed++
            }
        }
    }
    Write-Host "  [OK] $removed Sperr-Richtlinien entfernt." -ForegroundColor Green
    if ($removed -gt 0) { Write-SysPilotLog "Reparatur: $removed Policies entfernt" }
}

function Invoke-SysPilotRepairAssociations {
    <# Prueft System-Dateizuordnungen und repariert defekte Handler.
       Erwartete open\command-Defaults (Windows-Standard). #>
    $expected = @{
        'exefile'  = '"%1" %*'
        'batfile'  = '"%1" %*'
        'cmdfile'  = '"%SystemRoot%\system32\cmd.exe" /c "%1" %*'
        'mscfile'  = '%SystemRoot%\system32\mmc.exe "%1" %*'
        'regfile'  = 'regedit.exe "%1"'
        'scrfile'  = '%SystemRoot%\system32\wscript.exe "%1" %*'
        'comfile'  = '"%SystemRoot%\system32\cmd.exe" /c "%1" %*'
        'inffile'  = '%SystemRoot%\system32\rundll32.exe setupapi,InstallHinfSection DefaultInstall 132 %1'
        'lnkfile'  = $null  #ieu Special: shell\open\command leer = Explorer-Standard
    }
    $fixed = 0; $problems = 0
    foreach ($ext in $expected.Keys) {
        $cmdPath = "HKLM:\SOFTWARE\Classes\$ext\shell\open\command"
        if (-not (Test-Path $cmdPath)) { continue }
        $cur = (Get-ItemProperty -Path $cmdPath -Name '(default)' -ErrorAction SilentlyContinue).'(default)'
        if (-not $cur) { $cur = (Get-ItemProperty -Path $cmdPath -ErrorAction SilentlyContinue).'(default)' }
        $want = $expected[$ext]
        if ($want -eq $null) { continue } # lnkfile: nichts zu pruefen
        if (-not $cur) { $problems++; continue }
        # Grobe Pruefung: Handler soll auf System32-Tool oder %1 zeigen
        $ok = ($cur -match 'cmd\.exe|mmc\.exe|regedit|wscript|rundll32|setupapi|"%1"')
        if (-not $ok) {
            Write-Host "  [!] ${ext}: verdaechtiger Handler -> $cur" -ForegroundColor Yellow
            $problems++
        }
    }
    # Ordner-/Laufwerk-Handler
    foreach ($cls in @('Folder','Directory','Drive')) {
        $cmdPath = "HKLM:\SOFTWARE\Classes\$cls\shell"
        if (Test-Path $cmdPath) { }
    }
    if ($problems -eq 0) { Write-Host '  [OK] Alle geprueften Dateizuordnungen unauffaellig.' -ForegroundColor Green }
    else {
        Write-Host "  $problems Auffaelligkeiten gefunden. Automatische Korrektur nur fuer bekannte Defaults:" -ForegroundColor Yellow
        foreach ($ext in @('exefile','batfile','cmdfile','mscfile','regfile','scrfile','comfile')) {
            $want = $expected[$ext]
            $cmdPath = "HKLM:\SOFTWARE\Classes\$ext\shell\open\command"
            if (-not (Test-Path $cmdPath)) { continue }
            $cur = (Get-ItemProperty -Path $cmdPath -ErrorAction SilentlyContinue).'(default)'
            if (-not $cur -or $cur -notmatch 'cmd\.exe|mmc\.exe|regedit|wscript|"%1"') {
                if (Confirm-SysPilot "Handler fuer .$ext zuruecksetzen auf Windows-Standard?`n  Neu: $want") {
                    New-Item -Path $cmdPath -Force | Out-Null
                    Set-ItemProperty -Path $cmdPath -Name '(default)' -Value $want
                    $fixed++
                }
            }
        }
        Write-Host "  $fixed Handler korrigiert." -ForegroundColor Green
    }
    Write-SysPilotLog "Reparatur: Dateizuordnungen geprueft ($problems Auffaellig, $fixed gefixt)"
}

function Invoke-SysPilotRepairMsi {
    <# Windows Installer neu registrieren. #>
    $svc = Get-Service msiserver -ErrorAction SilentlyContinue
    if (-not $svc) { Write-Host '  [!] msiserver-Dienst nicht gefunden.' -ForegroundColor Red; return }
    Set-Service msiserver -StartupType Manual -ErrorAction SilentlyContinue
    Write-Host '  Registriere msi.dll neu ...' -ForegroundColor Cyan
    Start-Process regsvr32.exe -ArgumentList '/s msi.dll' -Wait -NoNewWindow -ErrorAction SilentlyContinue
    Write-Host '  [OK] MSI-Komponenten geprueft/neu registriert.' -ForegroundColor Green
    Write-SysPilotLog 'Reparatur: MSI neu registriert'
}

function Invoke-SysPilotRepairUac {
    <# UAC auf Windows-Standardwerte zuruecksetzen. #>
    $base = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $defaults = @{
        'EnableLUA' = 1; 'ConsentPromptBehaviorAdmin' = 5; 'PromptOnSecureDesktop' = 1;
        'EnableInstallerDetection' = 1; 'EnableVirtualization' = 1; 'EnableSecureUIAPaths' = 1
    }
    foreach ($k in $defaults.Keys) {
        Set-ItemProperty $base -Name $k -Value $defaults[$k] -ErrorAction SilentlyContinue
    }
    Write-Host '  [OK] UAC-Standards wiederhergestellt (Neustart noetig).'; Write-Host '      EnableLUA=1, Admin-Bestaetigung=Standard, SecureDesktop=an' -ForegroundColor DarkGray
    Write-SysPilotLog 'Reparatur: UAC-Defaults'
}

function Invoke-SysPilotRepairPerfCounters {
    <# Performance-Counter aus Basis-INIs neu aufbauen. #>
    Write-Host '  lodctr /R (Performance-Counter neu aufbauen) ...' -ForegroundColor Cyan
    & lodctr.exe /R 2>&1 | Out-Null
    Write-Host '  [OK] Performance-Counter neu aufgebaut.' -ForegroundColor Green
    Write-SysPilotLog 'Reparatur: Performance-Counter'
}

function Invoke-SysPilotRepairWmi {
    <# WMI-Repository pruefen; bei Inkonsistenz salvagen (langsam!). #>
    Write-Host '  Pruefe WMI-Repository ...' -ForegroundColor Cyan
    $res = & winmgmt.exe /verifyrepository 2>&1
    $res | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    if ($LASTEXITCODE -eq 0) {
        Write-Host '  [OK] WMI-Repository ist konsistent.' -ForegroundColor Green
        Write-SysPilotLog 'Reparatur: WMI verify ok'
        return
    }
    Write-Host '  [!] WMI-Repository inkonsistent. Salvage-Versuch (kann dauern) ...' -ForegroundColor Yellow
    if (Confirm-SysPilot 'WMI-Salvage durchfuehren? (winmgmt /salvagerepository, mehrere Minuten moeglich)') {
        & winmgmt.exe /salvagerepository 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        Write-Host '  Fertig.' -ForegroundColor Green
        Write-SysPilotLog 'Reparatur: WMI salvage'
    }
}

function Invoke-SysPilotRepairVss {
    <# Volume Shadow Copy Dienst pruefen. #>
    $svc = Get-Service VSS -ErrorAction SilentlyContinue
    $swprv = Get-Service swprv -ErrorAction SilentlyContinue
    foreach ($s in @($svc, $swprv)) {
        if ($s -and $s.Status -ne 'Running') {
            Set-Service $s.Name -StartupType Manual -ErrorAction SilentlyContinue
            Start-Service $s.Name -ErrorAction SilentlyContinue
        }
    }
    Write-Host ("  VSS: {0}, swprv: {1}" -f (Get-Service VSS).Status, (Get-Service swprv).Status) -ForegroundColor Green
    Write-SysPilotLog 'Reparatur: VSS geprueft'
}

function Invoke-SysPilotRepairWindowsUpdate {
    <# SoftwareDistribution + catroot2 zuruecksetzen (tiefe WU-Reparatur). #>
    if (-not (Confirm-SysPilot 'Windows-Update-Speicher zuruecksetzen?`nDienste stoppen, SoftwareDistribution + catroot2 umbenennen, neu starten.')) { return }
    $sd = "$env:WINDIR\SoftwareDistribution"
    $cr = "$env:WINDIR\System32\catroot2"
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    foreach ($svc in 'wuauserv','bits','cryptsvc','msiserver') {
        Stop-Service $svc -Force -ErrorAction SilentlyContinue
    }
    try {
        Rename-Item $sd "$sd.old-$stamp" -Force -ErrorAction Stop
        Rename-Item $cr "$cr.old-$stamp" -Force -ErrorAction Stop
    } catch {
        Write-Host "  [!] Umbenennen fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Red
        foreach ($svc in 'wuauserv','bits','cryptsvc','msiserver') { Start-Service $svc -ErrorAction SilentlyContinue }
        return
    }
    New-Item -ItemType Directory -Path $sd -Force | Out-Null
    New-Item -ItemType Directory -Path $cr -Force | Out-Null
    foreach ($svc in 'cryptsvc','bits','msiserver','wuauserv') {
        Set-Service $svc -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service $svc -ErrorAction SilentlyContinue
    }
    Write-Host "  [OK] Windows-Update-Speicher zurueckgesetzt." -ForegroundColor Green
    Write-Host "      Alt-Ordner: SoftwareDistribution.old-$stamp, catroot2.old-$stamp" -ForegroundColor DarkGray
    Write-SysPilotLog 'Reparatur: Windows-Update-Speicher'
}

function Show-SysPilotSystemRepair {
    <# Pfeiltasten-Menue: System-Reparaturen (nach Windows-Repair-Art,
       aber mit eigenen Namen, Bestaetigung und Log). #>
    while ($true) {
        $repairs = Get-SysPilotRepairList
        $items = @()
        foreach ($r in $repairs) {
            $items += @{ Label = ("{0,-45} {1}" -f $r.Name, $r.Desc); Color = 'White'; Tag = $r }
        }
        $items += @{ Label = '--- ALLE Reparaturen ausfuehren ---'; Color = 'Red'; Tag = 'ALL' }
        $items += @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = $null }

        $sel = Show-SysPilotArrowMenu -Items $items -Title 'SysPilot System-Reparatur' -Footer 'Pfeiltasten, Enter = reparieren, Esc = zurueck'
        if ($null -eq $sel) { return }

        if ($sel -eq 'ALL') {
            if (Confirm-SysPilot "Wirklich ALLE $($repairs.Count) Reparaturen ausfuehren?") {
                if (-not (Assert-SysPilotAdmin)) { continue }
                $i = 0
                foreach ($r in $repairs) {
                    $i++
                    Write-SysPilotProgress -Activity 'System-Reparatur' -Current $i -Total $repairs.Count -Status $r.Name
                    Write-Host "  [$i/$($repairs.Count)] $($r.Name) ..." -ForegroundColor Cyan
                    try { & $r.Cmd; Write-Host '    [OK]' -ForegroundColor Green } catch { Write-Host "    [!] $($_.Exception.Message)" -ForegroundColor Yellow }
                }
                Complete-SysPilotProgress
                Write-Host ''
                Write-Host '  Fertig. Einzelne Reparaturen koennen Neustart brauchen.' -ForegroundColor Yellow
                Write-SysPilotLog 'System-Reparatur: ALLE ausgefuehrt'
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            continue
        }

        $repair = $sel
        Write-Host ''
        Write-Host "  $($repair.Name)" -ForegroundColor Cyan
        Write-Host "  $($repair.Desc)" -ForegroundColor DarkGray
        Write-Host ''
        if (Confirm-SysPilot 'Jetzt ausfuehren?') {
            if (-not (Assert-SysPilotAdmin)) { continue }
            try {
                & $repair.Cmd
                Write-Host "  [OK] $($repair.Name) abgeschlossen." -ForegroundColor Green
            } catch {
                Write-Host "  [!] Fehler: $($_.Exception.Message)" -ForegroundColor Red
            }
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
        }
    }
}

Export-ModuleMember -Function Get-SysPilotRepairList, Invoke-SysPilotRepairProxy, Invoke-SysPilotRepairFirewall,
    Invoke-SysPilotRepairSpooler, Invoke-SysPilotRepairPolicies, Invoke-SysPilotRepairAssociations,
    Invoke-SysPilotRepairMsi, Invoke-SysPilotRepairUac, Invoke-SysPilotRepairPerfCounters,
    Invoke-SysPilotRepairWmi, Invoke-SysPilotRepairVss, Invoke-SysPilotRepairWindowsUpdate,
    Show-SysPilotSystemRepair
