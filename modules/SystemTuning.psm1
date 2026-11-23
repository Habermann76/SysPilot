# SysPilot - SystemTuning: Performance-/System-Tweaks
# (Nachbau der nuetzlichen Simple-System-Tweaker-Funktionen, mit eigener
#  Benennung, Statusanzeige und Ruecksetz-Moeglichkeit.)
#Requires -Version 5.1

$script:TuningDefs = @(
    # Key, Kategorie, Anzeigename, Beschreibung, Registry-Pfad, Wertname, Typ, An-Wert, Aus-Wert, Admin
    @{ Key='autotuning';   Cat='Netzwerk'; Name='TCP Auto Tuning';            Desc='netsh autotuninglevel (disabled = manuelle Kontrolle)';
       Path=$null; Value=$null; Type='NetshAutoTuning'; On='disabled'; Off='normal'; Admin=$true },
    @{ Key='tcptimestamps';Cat='Netzwerk'; Name='TCP-Timestamps';             Desc='netsh timestamps (disabled = weniger Overhead)';
       Path=$null; Value=$null; Type='NetshTimestamps'; On='disabled'; Off='enabled'; Admin=$true },
    @{ Key='dnscachettl';  Cat='Netzwerk'; Name='DNS-Cache-TTL 4h statt 24h';  Desc='MaxCacheTtl/MaxNegativeCacheTtl = 14400';
       Path='HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters'; Value=@('MaxCacheTtl','MaxNegativeCacheTtl'); Type='RegDword'; On=14400; Off=86400; Admin=$true },
    @{ Key='pagingexec';   Cat='System';   Name='Kernel im RAM behalten';    Desc='DisablePagingExecutive=1 (mehr RAM noetig!)';
       Path='HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'; Value='DisablePagingExecutive'; Type='RegDword'; On=1; Off=0; Admin=$true },
    @{ Key='largecache';   Cat='System';   Name='Gross-Datei-Cache aus';       Desc='LargeSystemCache=0 (Workstation-Standard)';
       Path='HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'; Value='LargeSystemCache'; Type='RegDword'; On=0; Off=1; Admin=$true },
    @{ Key='menudelay';    Cat='System';   Name='Menues sofort oeffnen';      Desc='MenuShowDelay=0 (schnelleres Gefuehl)';
       Path='HKCU:\Control Panel\Desktop'; Value='MenuShowDelay'; Type='RegString'; On='0'; Off='400'; Admin=$false },
    @{ Key='fasthangup';   Cat='System';   Name='Schneller herunterfahren';   Desc='AutoEndTasks=1, WaitToKill*=2000, HungAppTimeout=1000';
       Path='HKCU:\Control Panel\Desktop'; Value=@('AutoEndTasks','WaitToKillAppTimeout','WaitToKillServiceTimeout','HungAppTimeout'); Type='RegShutdown'; On=$true; Off=$false; Admin=$false },
    @{ Key='shortcuttrack';Cat='Explorer'; Name='Shortcut-Ueberwachung aus';  Desc='IsShortcut=0 (kein Pruefen toter Verknuepfungen)';
       Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer'; Value='IsShortcut'; Type='RegDword'; On=0; Off=1; Admin=$false },
    @{ Key='notepadmenu';  Cat='Explorer'; Name='Mit-Notepad-oeffnen Kontextmenue'; Desc='HKCR\\*\\shell Eintrag fuer Editor';
       Path='HKCR:\*\shell\Edit with Notepad'; Value='MUIVerb'; Type='RegKeyExists'; On=$true; Off=$false; Admin=$false }
)

function Get-SysPilotTuningStatus {
    <# Aktuelle Werte aller Tweaks auslesen. #>
    $status = @()
    foreach ($t in $script:TuningDefs) {
        $state = 'unbekannt'; $cur = $null
        switch ($t.Type) {
            'NetshAutoTuning' {
                # Get-NetTCPSetting ist lokalisierungsunabhaengig (netsh ist lokalisiert!)
                try {
                    $s = Get-NetTCPSetting -SettingName Internet -ErrorAction Stop
                    $cur = $s.AutoTuningLevelLocal
                    if (-not $cur) { $cur = $s.AutoTuningLevelEffective }
                    $map = @{ 'Disabled'='disabled'; 'HighlyRestricted'='highlyrestricted'; 'Normal'='normal'; 'Local'='normal' }
                    if ($map.ContainsKey($cur)) { $cur = $map[$cur] }
                } catch { $cur = '?' }
                $state = $(if ($cur -eq $t.On) { 'AN' } elseif ($cur -eq $t.Off) { 'aus' } else { 'custom' })
            }
            'NetshTimestamps' {
                try {
                    $s = Get-NetTCPSetting -SettingName Internet -ErrorAction Stop
                    $cur = $(if ($s.Timestamps -eq 'Allowed') { 'enabled' } elseif ($s.Timestamps -eq 'Disabled') { 'disabled' } else { 'custom' })
                } catch { $cur = '?' }
                $state = $(if ($cur -eq $t.On) { 'AN' } elseif ($cur -eq $t.Off) { 'aus' } else { 'custom' })
            }
            'RegDword' {
                if (Test-Path $t.Path) {
                    $v = (Get-ItemProperty -Path $t.Path -Name $t.Value[0] -ErrorAction SilentlyContinue).($t.Value[0])
                    $cur = $v
                    if ($null -eq $v) { $state = 'aus' }
                    else { $state = $(if ($v -eq $t.On) { 'AN' } elseif ($v -eq $t.Off) { 'aus' } else { 'custom' }) }
                } else { $state = 'aus' }
            }
            'RegString' {
                if (Test-Path $t.Path) {
                    $cur = (Get-ItemProperty -Path $t.Path -Name $t.Value -ErrorAction SilentlyContinue).($t.Value)
                    if ($null -eq $cur) { $state = 'aus' }
                    else { $state = $(if ($cur -eq $t.On) { 'AN' } elseif ($cur -eq $t.Off) { 'aus' } else { 'custom' }) }
                } else { $state = 'aus' }
            }
            'RegShutdown' {
                $vals = @()
                foreach ($v in @('AutoEndTasks','WaitToKillAppTimeout','WaitToKillServiceTimeout','HungAppTimeout')) {
                    $vals += (Get-ItemProperty -Path $t.Path -Name $v -ErrorAction SilentlyContinue).$v
                }
                $cur = ($vals -join '/')
                $state = $(if ($vals[0] -eq 1 -and $vals[1] -eq 2000 -and $vals[2] -eq 2000 -and $vals[3] -eq 1000) { 'AN' } else { 'aus' })
            }
            'RegKeyExists' {
                $state = $(if (Test-Path $t.Path) { 'AN' } else { 'aus' })
            }
        }
        $status += [PSCustomObject]@{ Tweak = $t; State = $state; Current = $cur }
    }
    $status
}

function Set-SysPilotTuningItem {
    <# Schaltet einen einzelnen Tweak um (On<->Off). #>
    param([Parameter(Mandatory)]$Tweak)
    $t = $Tweak.Tweak
    $st = $Tweak.State
    $target = if ($st -eq 'AN') { 'Off' } else { 'On' }
    $val = if ($target -eq 'On') { $t.On } else { $t.Off }

    if ($t.Admin -and -not (Assert-SysPilotAdmin)) { return }

    switch ($t.Type) {
        'NetshAutoTuning' {
            $lvl = switch ($val) { 'disabled' {'Disabled'} 'highlyrestricted' {'HighlyRestricted'} 'normal' {'Normal'} default {'Normal'} }
            Set-NetTCPSetting -SettingName Internet -AutoTuningLevelLocal $lvl -ErrorAction Stop
        }
        'NetshTimestamps' {
            $ts = if ($val -eq 'disabled') { 'Disabled' } else { 'Allowed' }
            Set-NetTCPSetting -SettingName Internet -Timestamps $ts -ErrorAction Stop
        }
        'RegDword' {
            if (-not (Test-Path $t.Path)) { New-Item -Path $t.Path -Force | Out-Null }
            foreach ($v in @($t.Value)) {
                Set-ItemProperty -Path $t.Path -Name $v -Value $val -Type DWord -Force
            }
        }
        'RegString' {
            if (-not (Test-Path $t.Path)) { New-Item -Path $t.Path -Force | Out-Null }
            Set-ItemProperty -Path $t.Path -Name $t.Value -Value ([string]$val) -Type String -Force
        }
        'RegShutdown' {
            $pairs = @{
                'AutoEndTasks' = 1; 'WaitToKillAppTimeout' = 2000
                'WaitToKillServiceTimeout' = 2000; 'HungAppTimeout' = 1000
            }
            if ($target -eq 'Off') {
                $pairs = @{
                    'AutoEndTasks' = 0; 'WaitToKillAppTimeout' = 5000
                    'WaitToKillServiceTimeout' = 5000; 'HungAppTimeout' = 5000
                }
            }
            foreach ($k in $pairs.Keys) {
                Set-ItemProperty -Path $t.Path -Name $k -Value $pairs[$k] -Type DWord -Force
            }
        }
        'RegKeyExists' {
            if ($target -eq 'On') {
                if (-not (Test-Path $t.Path)) {
                    New-Item -Path $t.Path -Force | Out-Null
                    New-ItemProperty -Path $t.Path -Name 'MUIVerb' -Value '&Edit with Notepad' -PropertyType String -Force | Out-Null
                    New-ItemProperty -Path $t.Path -Name 'Icon' -Value 'notepad.exe,0' -PropertyType String -Force | Out-Null
                    New-Item -Path "$($t.Path)\command" -Force | Out-Null
                    Set-ItemProperty -Path "$($t.Path)\command" -Name '(default)' -Value 'notepad.exe "%1"' -Force
                }
            } else {
                Remove-Item $t.Path -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Write-Host ("  [OK] '{0}' -> {1}" -f $t.Name, $(if ($target -eq 'On') {'AN'} else {'aus'})) -ForegroundColor Green
    Write-SysPilotLog "Tuning '{0}' -> {1}" -f $t.Name, $target
}

# =======================================================================
# Windows-11-UI: Taskbar-Standard, Kontextmenue klassisch/modern,
# Admin-Kontextmenue (Terminal + PowerShell) fuer Ordner/Laufwerke/Skripte.
# =======================================================================

function Reset-SysPilotWin11Taskbar {
    <# Stellt die Windows-11-Taskbar auf Standardwerte zurueck
       (Ausrichtung, Widgets, Chat, Suche, Taskleiste-Leiste etc.)
       und startet den Explorer neu. #>
    if (-not (Confirm-SysPilot 'Windows-11-Taskbar auf Standard zuruecksetzen und Explorer neu starten?')) { return }

    $adv = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $defaults = @{
        'TaskbarAl'            = 0      # Taskbarsymbole links
        'TaskbarDa'            = 0      # Widgets aus
        'TaskbarMn'            = 0      # Chat (Teams) aus
        'SearchboxTaskbarMode' = 1      # Suchsymbol
        'TaskbarSi'            = 0      # Taskleiste kleine Symbole aus
        'TaskbarGlomLevel'     = 0
        'ShowTaskViewButton'   = 0
        'TaskbarSizeMove'      = 0
        'TaskbarSd'            = 0
        'MMTaskbarEnabled'     = 1
        'Start_TrackProgs'     = 1
        'TaskbarStateLastRun'  = 0
    }
    foreach ($k in $defaults.Keys) {
        Set-ItemProperty $adv -Name $k -Value $defaults[$k] -Type DWord -Force -ErrorAction SilentlyContinue
    }
    # News/Feeds-Leiste
    Set-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Feeds' -Name 'ShellFeedsTaskbarViewMode' -Value 2 -Type DWord -Force -ErrorAction SilentlyContinue
    Write-Host '  Taskbar-Defaults geschrieben, starte Explorer neu ...' -ForegroundColor Cyan
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-Process explorer.exe
    Write-Host '  [OK] Taskbar zurueckgesetzt, Explorer neu gestartet.' -ForegroundColor Green
    Write-SysPilotLog 'Win11: Taskbar-Defaults'
}

function Set-SysPilotContextMenuMode {
    <# Umschalten zwischen Windows-11-Kontextmenue (default) und
       dem klassischen, vollstaendigen Menue (Windows-10-Stil).
       -Mode Win11:    CLSID-Override-Key entfernen
       -Mode Classic:  CLSID-Override-Key anlegen (leerer InprocServer32) #>
    param([Parameter(Mandatory)][ValidateSet('Win11','Classic','Toggle')][string]$Mode)
    $clsid = 'HKCU:\SOFTWARE\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-960fe4311b46}'
    if ($Mode -eq 'Toggle') {
        $Mode = if ((Get-SysPilotContextMenuMode) -eq 'Classic') { 'Win11' } else { 'Classic' }
        if (-not (Confirm-SysPilot "Kontextmenue auf '$Mode' umstellen?")) { return }
    }
    if ($Mode -eq 'Classic') {
        New-Item -Path "$clsid\InprocServer32" -Force | Out-Null
        Set-ItemProperty "$clsid\InprocServer32" -Name '(default)' -Value '' -Force
        Write-Host '  [OK] Klassisches Kontextmenue aktiviert (neuer Explorer noetig bzw. automatisch).' -ForegroundColor Green
        Write-Host '      Die Windows-11-Variante ist unter „Weitere anzeigen" erreichbar.' -ForegroundColor DarkGray
    } else {
        Remove-Item $clsid -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host '  [OK] Windows-11-Kontextmenue wiederhergestellt.' -ForegroundColor Green
    }
    Write-SysPilotLog "Kontextmenue-Modus: $Mode"
}

function Get-SysPilotContextMenuMode {
    <# 'Classic' wenn der Override-CLSID-Key existiert, sonst 'Win11'. #>
    $clsid = 'HKCU:\SOFTWARE\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-960fe4311b46}\InprocServer32'
    if (Test-Path $clsid) { return 'Classic' } else { return 'Win11' }
}

function Restore-SysPilotWin11ContextMenu {
    <# Repariert das moderne Windows-11-Kontextmenue (mit Befehlsleiste
       oben) nach Schaeden durch Tweaking-Tools. Prueft und entfernt:
       - CLSID-Override-Keys in HKCU UND HKLM (Tweaker nutzen beides)
       - blockierte Shell-Erweiterungen (Windows.UI.FileExplorer)
       - fehlt die System-DLL selbst, wird auf sfc/DISM verwiesen.
       Startet den Explorer danach neu (Fenster schliessen sich). #>

    $clsidGuid = '{86ca1aa0-34aa-4e8b-a509-960fe4311b46}'
    $found = @()

    # 1) Diagnose: alle bekannten Schaedigungsstellen pruefen
    $paths = @(
        @{ Path = "HKCU:\SOFTWARE\Classes\CLSID\$clsidGuid";                Scope = 'Benutzer (HKCU)' }
        @{ Path = "HKLM:\SOFTWARE\Classes\CLSID\$clsidGuid";                Scope = 'Systemweit (HKLM)' }
        @{ Path = "HKLM:\SOFTWARE\WOW6432Node\Classes\CLSID\$clsidGuid";    Scope = 'Systemweit 32-bit (HKLM)' }
    )
    foreach ($p in $paths) {
        if (Test-Path $p.Path) { $found += [pscustomobject]@{ Art = 'CLSIDs-Override'; Ort = $p.Path; Scope = $p.Scope } }
    }

    # 2) Blockierte Shell-Erweiterungen (z.B. durch 'Shell Extensions\Blocked')
    $blocked = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'
    if (Test-Path $blocked) {
        $bp = Get-ItemProperty $blocked -ErrorAction SilentlyContinue
        if ($bp) {
            foreach ($prop in $bp.PSObject.Properties) {
                if ($prop.Name -notmatch '^PS' -and ($prop.Name -match 'FileExplorer|ContextMenu|86ca1aa0|ShellExperience' -or [string]$prop.Value -match 'FileExplorer|ContextMenu')) {
                    $found += [pscustomobject]@{ Art = 'Blockierte Erweiterung'; Ort = "$blocked -> $($prop.Name)"; Scope = 'Systemweit (HKLM)' }
                }
            }
        }
    }

    # 3) DLLs des modernen Menues vorhanden? (FileExplorerExtensions/
    #    FileExplorerManaged in MicrosoftWindows.Client.FileExp_*)
    $dll = Get-ChildItem 'C:\Windows\SystemApps' -Recurse -Include 'FileExplorerExtensions.dll','FileExplorerManaged.dll' -ErrorAction SilentlyContinue | Select-Object -First 1
    $dllOk = [bool]$dll

    Write-Host ''
    Write-Host '  === Diagnose: Windows-11-Kontextmenue ===' -ForegroundColor Cyan
    if ($found.Count -eq 0 -and $dllOk) {
        Write-Host '  Keine Defekte gefunden - das Registry-Override ist nicht aktiv.' -ForegroundColor Green
        Write-Host '  Falls das Menue trotzdem klassisch aussieht: Explorer neu starten oder' -ForegroundColor DarkGray
        Write-Host '  pruefen, ob ein.andere Software (z.B. Start11, ExplorerPatcher) das Menue ersetzt.' -ForegroundColor DarkGray
        Write-Host ''
        Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
        return
    }
    foreach ($f in $found) {
        Write-Host ("  [!] {0} ({1})" -f $f.Art, $f.Scope) -ForegroundColor Yellow
        Write-Host ("      {0}" -f $f.Ort) -ForegroundColor DarkGray
    }
    if (-not $dllOk) {
        Write-Host '  [!!] FileExplorerExtensions.dll fehlt komplett!' -ForegroundColor Red
        Write-Host '       Das moderne Menue wurde evtl. geloescht - reparieren mit:' -ForegroundColor Yellow
        Write-Host '       sfc /scannow  und  DISM /Online /Cleanup-Image /RestoreHealth' -ForegroundColor Yellow
    }

    if (-not (Confirm-SysPilot "Defekte entfernen und Explorer neu starten?`n`nAchtung: Alle Explorer-Fenster schliessen sich.")) { return }

    # Admin noetig wenn HKLM-Befunde oder DLL-Problem
    $needAdmin = ($found | Where-Object { $_.Scope -like '*HKLM*' }).Count -gt 0 -or -not $dllOk
    if ($needAdmin -and -not (Test-SysPilotAdmin)) {
        if (Confirm-SysPilot 'Systemweite Aenderungen brauchen Administrator-Rechte. SysPilot jetzt als Administrator neu starten?') {
            Restart-SysPilotElevated
        }
        return
    }

    $removed = 0
    foreach ($p in $paths) {
        if (Test-Path $p.Path) {
            try { Remove-Item $p.Path -Recurse -Force -ErrorAction Stop; $removed++; Write-Host "  [OK] Entfernt: $($p.Path)" -ForegroundColor Green }
            catch { Write-Host "  [!] Konnte nicht entfernen: $($p.Path) ($($_.Exception.Message))" -ForegroundColor Red }
        }
    }
    # Blockierte Eintraege entfernen
    if (Test-Path $blocked) {
        $bp = Get-ItemProperty $blocked -ErrorAction SilentlyContinue
        if ($bp) {
            foreach ($prop in @($bp.PSObject.Properties)) {
                if ($prop.Name -notmatch '^PS' -and ($prop.Name -match 'FileExplorer|ContextMenu|86ca1aa0|ShellExperience' -or [string]$prop.Value -match 'FileExplorer|ContextMenu')) {
                    try { Remove-ItemProperty $blocked -Name $prop.Name -Force -ErrorAction Stop; $removed++; Write-Host "  [OK] Blockierung aufgehoben: $($prop.Name)" -ForegroundColor Green }
                    catch { Write-Host "  [!] Blockierung bleibt: $($prop.Name)" -ForegroundColor Yellow }
                }
            }
        }
    }

    Write-Host '  Starte Explorer neu ...' -ForegroundColor Cyan
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-Process explorer.exe

    $mode = Get-SysPilotContextMenuMode
    Write-Host ''
    if ($mode -eq 'Win11') {
        Write-Host '  [OK] Modernes Windows-11-Kontextmenue wiederhergestellt.' -ForegroundColor Green
        Write-Host '      Tipp: Rechtsklick auf eine Datei/Ordner - das neue Menue erscheint sofort.' -ForegroundColor DarkGray
    } else {
        Write-Host '  [!] Registry ist sauber, aber der Modus meldet noch Classic.' -ForegroundColor Yellow
        Write-Host '      Eventuell blockiert eine andere Software das Menue (Start11, ExplorerPatcher).' -ForegroundColor DarkGray
    }
    Write-SysPilotLog "Win11-Kontextmenue-Reparatur: $removed Eintraege entfernt"
    Write-Host ''
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
}

function Add-SysPilotAdminContextMenus {
    <# Fuegt Admin-Kontextmenue-Eintraege hinzu:
       - Ordner-Hintergrund: „Terminal (Admin) oeffnen"
       - Laufwerke:        „Terminal (Admin) oeffnen"
       - Ordner:            „Terminal (Admin) oeffnen"
       - .ps1-Dateien:      „Mit PowerShell (Admin) oeffnen"
       HKCU-Classes = pro Benutzer, kein Admin noetig. #>
    $added = @()

    $terminalCmd = 'wt.exe -d "%V"'
    $locations = @(
        @{ Path = 'HKCU:\SOFTWARE\Classes\Directory\Background\shell\TerminalAdmin'; Label = 'Terminal (Admin) oeffnen'; Icon = 'WindowsTerminal.exe,0'; Cmd = ($terminalCmd -replace '%V','%V') },
        @{ Path = 'HKCU:\SOFTWARE\Classes\Directory\shell\TerminalAdmin';        Label = 'Terminal (Admin) oeffnen'; Icon = 'WindowsTerminal.exe,0'; Cmd = 'wt.exe -d "%1"' },
        @{ Path = 'HKCU:\SOFTWARE\Classes\Drive\shell\TerminalAdmin';             Label = 'Terminal (Admin) oeffnen'; Icon = 'WindowsTerminal.exe,0'; Cmd = 'wt.exe -d "%1"' },
        @{ Path = 'HKCU:\SOFTWARE\Classes\Folder\shell\TerminalAdmin';            Label = 'Terminal (Admin) oeffnen'; Icon = 'WindowsTerminal.exe,0'; Cmd = 'wt.exe -d "%1"' }
    )
    foreach ($loc in $locations) {
        try {
            New-Item -Path $loc.Path -Force | Out-Null
            Set-ItemProperty $loc.Path -Name '(default)' -Value $loc.Label -Force
            Set-ItemProperty $loc.Path -Name 'Icon' -Value $loc.Icon -Force
            New-Item -Path "$($loc.Path)\command" -Force | Out-Null
            Set-ItemProperty "$($loc.Path)\command" -Name '(default)' -Value $loc.Cmd -Force
            $added += $loc.Label
        } catch { Write-Host "  [!] $($loc.Path): $($_.Exception.Message)" -ForegroundColor Yellow }
    }

    # PowerShell-Admin fuer .ps1 (SystemFileAssociations = alle User-Kontexte)
    $psPath = 'HKCU:\SOFTWARE\Classes\SystemFileAssociations\.ps1\shell\PSAdmin'
    try {
        New-Item -Path $psPath -Force | Out-Null
        Set-ItemProperty $psPath -Name '(default)' -Value 'Mit PowerShell (Admin) oeffnen' -Force
        Set-ItemProperty $psPath -Name 'Icon' -Value 'powershell.exe,0' -Force
        New-Item -Path "$psPath\command" -Force | Out-Null
        Set-ItemProperty "$psPath\command" -Name '(default)' -Value 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%1"' -Force
        $added += 'PS-Admin (.ps1)'
    } catch { Write-Host "  [!] PS-Admin: $($_.Exception.Message)" -ForegroundColor Yellow }

    Write-Host ("  [OK] {0} Kontextmenue-Eintraege hinzugefuegt." -f $added.Count) -ForegroundColor Green
    Write-Host '      Hinweis: Im neuen Win11-Menue erscheinen Background-Eintraege direkt,' -ForegroundColor DarkGray
    Write-Host '      Ordner-/Datei-Eintraege ggf. unter „Weitere anzeigen".' -ForegroundColor DarkGray
    Write-SysPilotLog "Admin-Kontextmenues hinzugefuegt ($($added.Count))"
}

function Remove-SysPilotAdminContextMenus {
    <# Entfernt die oben erstellten Eintraege wieder. #>
    $paths = @(
        'HKCU:\SOFTWARE\Classes\Directory\Background\shell\TerminalAdmin',
        'HKCU:\SOFTWARE\Classes\Directory\shell\TerminalAdmin',
        'HKCU:\SOFTWARE\Classes\Drive\shell\TerminalAdmin',
        'HKCU:\SOFTWARE\Classes\Folder\shell\TerminalAdmin',
        'HKCU:\SOFTWARE\Classes\SystemFileAssociations\.ps1\shell\PSAdmin'
    )
    $n = 0
    foreach ($p in $paths) {
        if (Test-Path $p) { Remove-Item $p -Recurse -Force; $n++ }
    }
    Write-Host "  [OK] $n Admin-Kontextmenue-Eintraege entfernt." -ForegroundColor Green
    Write-SysPilotLog "Admin-Kontextmenues entfernt ($n)"
}

function Show-SysPilotAdminContextMenuManager {
    <# Eigenstaendiges Untermenue fuer die Admin-Kontextmenue-Eintraege. #>
    while ($true) {
        $term = Test-Path 'HKCU:\SOFTWARE\Classes\Directory\Background\shell\TerminalAdmin'
        $ps   = Test-Path 'HKCU:\SOFTWARE\Classes\SystemFileAssociations\.ps1\shell\PSAdmin'
        $state = if ($term -and $ps) { 'installiert' } elseif ($term -or $ps) { 'teilweise' } else { 'nicht vorhanden' }
        $items = @(
            @{ Label = "Admin-Kontextmenue-Eintraege: $state";                          Color = 'DarkGray'; Tag = 'info' }
            @{ Label = 'Eintraege hinzufuegen (Terminal-Admin + PS-Admin)';              Color = 'Green';   Tag = 'add' }
            @{ Label = 'Eintraege entfernen';                                            Color = 'Yellow';  Tag = 'rm' }
            @{ Label = 'Zurueck';                                                        Color = 'DarkGray'; Tag = $null }
        )
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'Admin-Kontextmenue-Eintraege' -Footer 'Pfeiltasten, Enter = ausfuehren, Esc = zurueck'
        if ($null -eq $sel) { return }
        switch ($sel) {
            'add' { Add-SysPilotAdminContextMenus }
            'rm'  { if (Confirm-SysPilot 'Admin-Kontextmenue-Eintraege entfernen?') { Remove-SysPilotAdminContextMenus } }
        }
    }
}

function Show-SysPilotWin11UiMenu {
    <# Untermenue: Windows-11-Taskbar & Kontextmenue. #>
    while ($true) {
        $mode = Get-SysPilotContextMenuMode
        $modeTxt = if ($mode -eq 'Classic') { 'KLASSISCH' } else { 'Windows 11' }
        $items = @(
            @{ Label = 'Taskbar-Standard wiederherstellen (Explorer-Neustart)'; Color = 'White';  Tag = 'taskbar' }
            @{ Label = "Kontextmenue-Modus: $modeTxt -> umschalten";                     Color = 'Cyan';   Tag = 'ctxmode' }
            @{ Label = 'Modernes Win11-Kontextmenue reparieren (nach Tweaker-Schaden)'; Color = 'Green';  Tag = 'ctxrestore' }
            @{ Label = 'Admin-Kontextmenue-Eintraege verwalten (Terminal + PS-Admin)'; Color = 'Green';  Tag = 'addctx' }
            @{ Label = 'Admin-Kontextmenue-Eintraege entfernen';                          Color = 'Yellow'; Tag = 'rmctx' }
            @{ Label = 'Zurueck';                                                          Color = 'DarkGray'; Tag = $null }
        )
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'Windows-11-Taskbar & Kontextmenue' -Footer 'Pfeiltasten, Enter = ausfuehren, Esc = zurueck'
        if ($null -eq $sel) { return }
        switch ($sel) {
            'taskbar' { Reset-SysPilotWin11Taskbar }
            'ctxrestore' { Restore-SysPilotWin11ContextMenu }
            'ctxmode' {
                $new = if ($mode -eq 'Classic') { 'Win11' } else { 'Classic' }
                if (Confirm-SysPilot "Kontextmenue auf '$new' umstellen?") { Set-SysPilotContextMenuMode -Mode $new }
                Start-Sleep -Milliseconds 600
            }
            'addctx'  { Show-SysPilotAdminContextMenuManager }
            'rmctx'   { if (Confirm-SysPilot 'Admin-Kontextmenue-Eintraege entfernen?') { Remove-SysPilotAdminContextMenus } }
        }
    }
}

function Show-SysPilotSystemTuning {
    <# Pfeiltasten-Menue: Tweak-Kategorien, Status, umschalten. #>
    while ($true) {
        $cats = @('Netzwerk', 'System', 'Explorer', 'Win11-UI')
        $items = @()
        foreach ($c in $cats) { $items += @{ Label = ">>> $c-Tweaks"; Color = 'Cyan'; Tag = "cat:$c" } }
        $items += @{ Label = '>>> Status aller Tweaks anzeigen'; Color = 'DarkGray'; Tag = 'status' }
        $items += @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = $null }
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'SysPilot System-Tuning' -Footer 'Pfeiltasten, Enter = auswaehlen, Esc = zurueck'
        if ($null -eq $sel) { return }

        if ($sel -eq 'status') {
            $status = @(Get-SysPilotTuningStatus)
            Write-Host ''
            foreach ($s in $status) {
                $col = switch ($s.State) { 'AN' {'Green'} 'aus' {'DarkGray'} default {'Yellow'} }
                Write-Host ("  [{0,-6}] {1,-38} (aktuell: {2})" -f $s.State, $s.Tweak.Name, $s.Current) -ForegroundColor $col
            }
            Write-Host ''
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            continue
        }

        if ($sel -like 'cat:*') {
            $cat = $sel.Substring(4)
            if ($cat -eq 'Win11-UI') { Show-SysPilotWin11UiMenu; continue }
            $status = @(Get-SysPilotTuningStatus | Where-Object { $_.Tweak.Cat -eq $cat })
            $tItems = @()
            foreach ($s in $status) {
                $mark = switch ($s.State) { 'AN' {'[AN ]'} 'aus' {'[aus]'} default {'[???]'} }
                $color = switch ($s.State) { 'AN' {'Green'} 'aus' {'White'} default {'Yellow'} }
                $tItems += @{ Label = ("{0} {1,-40} {2}" -f $mark, $s.Tweak.Name, $s.Tweak.Desc); Color = $color; Tag = $s }
            }
            $tItems += @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = $null }
            $pick = Show-SysPilotArrowMenu -Items $tItems -Title "$cat-Tweaks" -Footer 'Enter = umschalten, Esc = zurueck'
            if ($null -eq $pick) { continue }
            Set-SysPilotTuningItem -Tweak $pick
            Start-Sleep -Milliseconds 600
        }
    }
}

Export-ModuleMember -Function Get-SysPilotTuningStatus, Set-SysPilotTuningItem, Show-SysPilotSystemTuning,
    Reset-SysPilotWin11Taskbar, Set-SysPilotContextMenuMode, Get-SysPilotContextMenuMode,
    Add-SysPilotAdminContextMenus, Remove-SysPilotAdminContextMenus, Show-SysPilotWin11UiMenu,
    Show-SysPilotAdminContextMenuManager, Restore-SysPilotWin11ContextMenu
