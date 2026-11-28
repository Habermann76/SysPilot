# ======================================================================
# SysPilot PrivacyFix.psm1 - "PrivacyGuard": Datenschutz-, Werbe- und
# UI-Tweaks. Registry-Tweak-Engine mit Statusanzeige, Einzel-Umschaltung
# und Batch-Fix. Alles reversibel.
# ======================================================================

$script:PrivacyDefs = @(
    # --- Datenschutz ---
    @{ Key='adid';        Cat='Datenschutz'; Name='Werbe-ID deaktivieren';
       Desc='AdvertisingID auf 0 - Apps duerfen keine Werbe-Kennung nutzen';
       Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; Value='Enabled'; Type='RegDword'; On=0; Off=1; Admin=$false },
    @{ Key='tailored';    Cat='Datenschutz'; Name='Massgeschneiderte Inhalte';
       Desc='TailoredExperiencesEnabled = 0 - keine personalisierten Vorschlaege';
       Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy'; Value='TailoredExperiencesEnabled'; Type='RegDword'; On=0; Off=1; Admin=$false },
    @{ Key='telemetry';   Cat='Datenschutz'; Name='Telemetrie-Richtlinie (AllowTelemetry=0)';
       Desc='HKLM-Policy: volle Telemetrie aus (werbewirksam, harmlos fuer Updates)';
       Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Value='AllowTelemetry'; Type='RegDword'; On=0; Off=1; Admin=$true },
    @{ Key='activity';    Cat='Datenschutz'; Name='Aktivitaetsverlauf deaktivieren';
       Desc='DiagTrack-Dienst stoppen (verbraucht CPU/RAM, sendet Nutzungsdaten)';
       Path=$null; Value=$null; Type='DiagTrack'; On='disabled'; Off='automatic'; Admin=$true },
    @{ Key='location';    Cat='Datenschutz'; Name='Standort-Ortung deaktivieren';
       Desc='Location Capability auf Deny - Apps sehen keinen Standort';
       Path='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location'; Value='Value'; Type='RegSz'; On='Deny'; Off='Allow'; Admin=$true },
    @{ Key='copilot';     Cat='Datenschutz'; Name='Copilot in Taskleiste aus';
       Desc='WindowsCopilot-Richtlinie: Taskbar-Icon + Copilot deaktiviert';
       Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot'; Value='TurnOffWindowsCopilot'; Type='RegDword'; On=1; Off=0; Admin=$true },
    @{ Key='recall';      Cat='Datenschutz'; Name='Recall (KI-Screenshots) deaktivieren';
       Desc='WindowsAI-Richtlinie: DisableAIDataAnalysis=1';
       Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Value='DisableAIDataAnalysis'; Type='RegDword'; On=1; Off=0; Admin=$true },

    # --- Werbung ---
    @{ Key='cdm';         Cat='Werbung'; Name='Content Delivery Master-Schalter';
       Desc='ContentDeliveryAllowed=0 - sperrt die meisten Consumer-Features';
       Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Value='ContentDeliveryAllowed'; Type='RegDword'; On=0; Off=1; Admin=$false },
    @{ Key='startads';    Cat='Werbung'; Name='Startmenue-Empfehlungen/Werbung';
       Desc='Mehrere SubscribedContent-Flags auf 0 (Vorschlaege, Highlights, Widget-Werbung)';
       Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Value=@('SubscribedContent-338387Enabled','SubscribedContent-338388Enabled','SubscribedContent-338389Enabled','SubscribedContent-338393Enabled','SubscribedContent-353694Enabled','SubscribedContent-353696Enabled','SubscribedContent-353698Enabled'); Type='RegDwordMulti'; On=0; Off=1; Admin=$false },
    @{ Key='softlanding'; Cat='Werbung'; Name='Einstellungs-Vorschlaege (Soft Landing)';
       Desc='SoftLandingEnabled=0 - keine App-Vorschlaege in den Einstellungen';
       Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Value='SoftLandingEnabled'; Type='RegDword'; On=0; Off=1; Admin=$false },
    @{ Key='rotlock';     Cat='Werbung'; Name='Rotierender LockScreen';
       Desc='RotatingLockScreenEnabled=0 - kein Werbe-Hintergrund am Sperrbildschirm';
       Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Value='RotatingLockScreenEnabled'; Type='RegDword'; On=0; Off=1; Admin=$false },
    @{ Key='syncnotify';  Cat='Werbung'; Name='Explorer-Sync-Benachrichtigungen';
       Desc='ShowSyncProviderNotifications=0 - keine OneDrive-Werbe-Hinweise im Explorer';
       Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Value='ShowSyncProviderNotifications'; Type='RegDword'; On=0; Off=1; Admin=$false },
    @{ Key='welcameads';  Cat='Werbung'; Name='Willkommens-/Setup-Werbung';
       Desc='Multiple SubscribedContent-3384xx Flags = 0 (OOBE, Finish-Setup)';
       Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Value=@('SubscribedContent-338341Enabled','SubscribedContent-338342Enabled','SubscribedContent-338343Enabled','SubscribedContent-353710Enabled'); Type='RegDwordMulti'; On=0; Off=1; Admin=$false },

    # --- Explorer & Taskleiste ---
    @{ Key='searchbox';   Cat='Explorer & Taskleiste'; Name='Suchfeld-Vorschlaege aus';
       Desc='DisableSearchBoxSuggestions=1 - keine Bing-Vorschlaege in der Suche';
       Path='HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer'; Value='DisableSearchBoxSuggestions'; Type='RegDword'; On=1; Off=0; Admin=$false },
    @{ Key='menudelay';   Cat='Explorer & Taskleiste'; Name='Menue-Verzoegerung = 0';
       Desc='MenuShowDelay=0 - Kontextmenues oeffnen sofort';
       Path='HKCU:\Control Panel\Desktop'; Value='MenuShowDelay'; Type='RegSz'; On='0'; Off='400'; Admin=$false },
    @{ Key='taskview';    Cat='Explorer & Taskleiste'; Name='Task-Ansicht-Button';
       Desc='ShowTaskViewButton 0/1 - Taskleiste anzeigen/ausblenden';
       Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Value='ShowTaskViewButton'; Type='RegDword'; On=1; Off=0; Admin=$false },
    @{ Key='searchtb';    Cat='Explorer & Taskleiste'; Name='Taskleisten-Suchmodus';
       Desc='SearchboxTaskbarMode: 0=aus, 1=Symbol, 2=Suchfeld';
       Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search'; Value='SearchboxTaskbarMode'; Type='RegDword'; On=2; Off=1; Admin=$false },
    @{ Key='mostused';    Cat='Explorer & Taskleiste'; Name='Start: Meistgenutzte Apps';
       Desc='Start_TrackDocs=0 - keine "Haeufig verwendet"-Liste im Startmenue';
       Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Value='Start_TrackDocs'; Type='RegDword'; On=0; Off=1; Admin=$false },
    @{ Key='snapflyout';  Cat='Explorer & Taskleiste'; Name='Snap-Layouts-Flyout aus';
       Desc='EnableSnapAssistFlyout=0 - kein Flyout beim Hover ueber Fensterrand';
       Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Value='EnableSnapAssistFlyout'; Type='RegDword'; On=0; Off=1; Admin=$false },
    @{ Key='transparency';Cat='Explorer & Taskleiste'; Name='Transparenzeffekte aus';
       Desc='EnableTransparency=0 - auch bei hohem Kontrast/einfache Optik';
       Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Value='EnableTransparency'; Type='RegDword'; On=0; Off=1; Admin=$false },

    # --- System & Gaming ---
    @{ Key='netthrottle'; Cat='System & Gaming'; Name='Netzwerk-Drosselung aus';
       Desc='NetworkThrottlingIndex=0xFFFFFFFF - volle Bandbreite fuer Spiele/Streaming';
       Path='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'; Value='NetworkThrottlingIndex'; Type='RegDword'; On=-1; Off=10; Admin=$true },
    @{ Key='sysresp';     Cat='System & Gaming'; Name='System-Reaktivitaet fuer Spiele';
       Desc='SystemResponsiveness=0 - CPU Prioritaet fuer Games statt Hintergrund';
       Path='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'; Value='SystemResponsiveness'; Type='RegDword'; On=0; Off=20; Admin=$true },
    @{ Key='gamedvr';     Cat='System & Gaming'; Name='Game DVR deaktivieren';
       Desc='AppCaptureEnabled=0 + GameDVR_Enabled=0 - kein Hintergrund-Recording';
       Path=@('HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR','HKCU:\System\GameConfigStore'); Value=@('AppCaptureEnabled','GameDVR_Enabled'); Type='RegDwordPair'; On=0; Off=1; Admin=$false },
    @{ Key='powerthrottle';Cat='System & Gaming'; Name='Power Throttling aus';
       Desc='PowerThrottlingOff=1 - Hintergrundprozesse nicht ausdrosseln';
       Path='HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling'; Value='PowerThrottlingOff'; Type='RegDword'; On=1; Off=0; Admin=$true },
    @{ Key='visualfx';    Cat='System & Gaming'; Name='Visuelle Effekte: Leistung';
       Desc='VisualFXSetting=2 - beste Leistung (weniger Animationen)';
       Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'; Value='VisualFXSetting'; Type='RegDword'; On=2; Off=0; Admin=$false },
    @{ Key='shutdown';    Cat='System & Gaming'; Name='Schnelleres Herunterfahren';
       Desc='AutoEndTasks + WaitToKillAppTimeout=2000 (Apps werden beendet statt zu warten)';
       Path='HKCU:\Control Panel\Desktop'; Value=@('AutoEndTasks','WaitToKillAppTimeout','HungAppTimeout'); Type='RegSzMulti'; On=@('1','2000','1000'); Off=@('0','5000','5000'); Admin=$false },
    @{ Key='bsod';        Cat='System & Gaming'; Name='BSOD-Details anzeigen';
       Desc='DisplayParameters=1 - techn. Info beim Bluescreen (BlueScreenView-tauglich)';
       Path='HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'; Value='DisplayParameters'; Type='RegDword'; On=1; Off=0; Admin=$true },
    @{ Key='verbose';     Cat='System & Gaming'; Name='Ausfuehrliche Statusmeldungen';
       Desc='VerboseStatus=1 - mehr Info bei Start/Herunterfahren';
       Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Value='VerboseStatus'; Type='RegDword'; On=1; Off=0; Admin=$true },

    # --- Edge ---
    @{ Key='edgeads';     Cat='Edge'; Name='Edge: Anmeldung + Werbe-Features';
       Desc='BrowserSignin=0, ImportOnEachLaunch=0, UserFeedback=0 (Edge-Policy HKCU)';
       Path='HKCU:\SOFTWARE\Policies\Microsoft\Edge'; Value=@('BrowserSignin','ImportOnEachLaunch','UserFeedback'); Type='RegDwordMulti'; On=0; Off=1; Admin=$false },
    @{ Key='edgetop';     Cat='Edge'; Name='Edge: Top-Seiten + Sammlungen';
       Desc='ShowMicrosoftRewards=0, NewTabPageContentEnabled=0 (weniger Edge-Werbung)';
       Path='HKCU:\SOFTWARE\Policies\Microsoft\Edge'; Value=@('ShowMicrosoftRewards','NewTabPageContentEnabled'); Type='RegDwordMulti'; On=0; Off=1; Admin=$false },
    @{ Key='edgestart';   Cat='Edge'; Name='Edge: Startup-Boost + Schnellstart';
       Desc='StartupBoostEnabled=0, StartupBoostPolicy=0 - Edge startet nicht mit Windows';
       Path='HKCU:\SOFTWARE\Policies\Microsoft\Edge'; Value=@('StartupBoostEnabled','StartupBoostPolicy'); Type='RegDwordMulti'; On=0; Off=1; Admin=$false },
    @{ Key='edgegamer';   Cat='Edge'; Name='Edge: Gamer Mode';
       Desc='GamingServicesEnabled... nein - Edge Gaming Mode Policy';
       Path='HKCU:\SOFTWARE\Policies\Microsoft\Edge'; Value='EdgeCollectionsEnabled'; Type='RegDword'; On=0; Off=1; Admin=$false }
)

function Get-SysPilotPrivacyStatus {
    <# Aktueller Status aller Privacy-Tweaks. #>
    $out = @()
    foreach ($t in $script:PrivacyDefs) {
        $state = 'custom'; $cur = '-'
        if ($t.Type -eq 'DiagTrack') {
            $svc = Get-Service DiagTrack -ErrorAction SilentlyContinue
            $state = if ($svc -and $svc.StartType -eq 'Disabled') { 'AN' } elseif ($svc) { 'aus' } else { 'custom' }
            $cur = if ($svc) { $svc.StartType.ToString() } else { 'nicht gefunden' }
        } else {
            $paths = @($t.Path); $vals = @($t.Value)
            if ($vals.Count -gt 1 -and $vals[0] -is [array]) { $vals = $vals[0] }
            # Schleife ueber die Values (nicht nur Pfade): Multi-Value-Tweaks
            # haben oft EINEN Pfad, aber MEHRERE Wertnamen.
            $count = [math]::Max($paths.Count, $vals.Count)
            $allMatch = $true; $seen = @()
            for ($i = 0; $i -lt $count; $i++) {
                $p = $paths[[math]::Min($i, $paths.Count-1)]
                $vn = $vals[$i]
                $prop = Get-ItemProperty -Path $p -Name $vn -ErrorAction SilentlyContinue
                if ($null -eq $prop -or $null -eq $prop.$vn) { $allMatch = $false; break }
                $seen += $prop.$vn
            }
            if ($allMatch -and $seen.Count -gt 0) {
                $onVal = @($t.On)[0]; $offVal = @($t.Off)[0]
                if ($seen[0] -eq $onVal) { $state = 'AN' }
                elseif ($seen[0] -eq $offVal) { $state = 'aus' }
                $cur = ($seen -join ', ')
            } else { $cur = 'nicht gesetzt' }
        }
        $out += [pscustomobject]@{ Tweak = $t; State = $state; Current = $cur }
    }
    return $out
}

function Set-SysPilotPrivacyItem {
    <# Schaltet einen Privacy-Tweak um (AN <-> aus).
       -NoConfirm ueberspringt die Rueckfrage (fuer WPF-Assistenten
       mit eigener Bestaetigung). #>
    param([Parameter(Mandatory)]$Tweak, [switch]$NoConfirm)
    $st = Get-SysPilotPrivacyStatus | Where-Object { $_.Tweak.Key -eq $Tweak.Key } | Select-Object -First 1
    $toOn = ($st.State -ne 'AN')
    $target = if ($toOn) { $Tweak.On } else { $Tweak.Off }

    if ($Tweak.Admin -and -not (Test-SysPilotAdmin)) {
        $r = Confirm-SysPilot "'$( $Tweak.Name)' braucht Administrator-Rechte.`nSysPilot jetzt als Administrator neu starten?"
        if ($r) { Restart-SysPilotElevated }
        return
    }
    if (-not $NoConfirm -and -not (Confirm-SysPilot "'$($Tweak.Name)' $(if ($toOn) {'einschalten'} else {'ausschalten'})?`n$($Tweak.Desc)")) { return }

    try {
        if ($Tweak.Type -eq 'DiagTrack') {
            Set-Service DiagTrack -StartupType $target -ErrorAction Stop
            if ($target -eq 'disabled') { Stop-Service DiagTrack -Force -ErrorAction SilentlyContinue }
        } else {
            $paths = @($Tweak.Path); $vals = @($Tweak.Value)
            if ($vals.Count -gt 1 -and $vals[0] -is [array]) { $vals = $vals[0] }
            $targets = @($target); if ($targets.Count -gt 1 -and $targets[0] -is [array]) { $targets = $targets[0] }
            # Multi-Value: On/Off sind Arrays
            if ($Tweak.On -is [array] -and $Tweak.On.Count -gt 1) { $targets = if ($toOn) { $Tweak.On } else { $Tweak.Off } }
            # Schleife ueber die Values: ein Pfad kann mehrere Wertnamen haben
            $count = [math]::Max($paths.Count, $vals.Count)
            for ($i = 0; $i -lt $count; $i++) {
                $p = $paths[[math]::Min($i, $paths.Count-1)]
                $vn = $vals[$i]
                $v = $targets[[math]::Min($i, $targets.Count-1)]
                $type = if ($Tweak.Type -match 'Sz') { 'String' } else { 'DWord' }
                $val = if ($type -eq 'DWord') { [int]$v } else { [string]$v }
                # Policy-Keys existieren oft nicht -> anlegen statt Fehler
                if (-not (Test-Path $p)) { New-Item -Path $p -Force | Out-Null }
                Set-ItemProperty -Path $p -Name $vn -Value $val -Type $type -Force -ErrorAction Stop            }
        }
        Write-Host "  [OK] $($Tweak.Name) -> $(if ($toOn) {'AN'} else {'aus'})" -ForegroundColor Green
        Write-SysPilotLog "PrivacyFix $($Tweak.Key) = $(if ($toOn) {'AN'} else {'aus'})"
    } catch {
        Write-Host "  [!] Fehler: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Set-SysPilotPrivacyBatch {
    <# Wendet alle empfohlenen Datenschutz- und Werbe-Tweaks an. #>
    $cats = @('Datenschutz','Werbung')
    $items = Get-SysPilotPrivacyStatus | Where-Object { $cats -contains $_.Tweak.Cat -and $_.State -ne 'AN' }
    if ($items.Count -eq 0) { Write-Host '  Alles bereits aktiv.' -ForegroundColor Green; return }
    Write-Host "  $($items.Count) Tweaks werden aktiviert:" -ForegroundColor Cyan
    foreach ($i in $items) { Write-Host "   - $($i.Tweak.Name)" -ForegroundColor DarkGray }
    if (-not (Confirm-SysPilot 'Alle Datenschutz- und Werbe-Tweaks anwenden?')) { return }
    foreach ($i in $items) { Set-SysPilotPrivacyItem -Tweak $i.Tweak }
}

function Show-SysPilotPrivacyFix {
    <# Pfeiltasten-Menue: Kategorien, Status, umschalten, Batch-Fix. #>
    while ($true) {
        $cats = @('Datenschutz','Werbung','Explorer & Taskleiste','System & Gaming','Edge')
        $items = @()
        foreach ($c in $cats) { $items += @{ Label = ">>> $c"; Color = 'Cyan'; Tag = "cat:$c" } }
        $items += @{ Label = '>>> FIX: Alle Datenschutz- + Werbe-Tweaks anwenden'; Color = 'Green'; Tag = 'fixall' }
        $items += @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = $null }
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'SysPilot Datenschutz & Werbe-Fix' -Footer 'Pfeiltasten, Enter = auswaehlen, Esc = zurueck'
        if ($null -eq $sel) { return }

        if ($sel -eq 'fixall') { Set-SysPilotPrivacyBatch; continue }
        if ($sel -like 'cat:*') {
            $cat = $sel.Substring(4)
            $status = @(Get-SysPilotPrivacyStatus | Where-Object { $_.Tweak.Cat -eq $cat })
            $tItems = @()
            foreach ($s in $status) {
                $mark = switch ($s.State) { 'AN' {'[AN ]'} 'aus' {'[aus]'} default {'[???]'} }
                $color = switch ($s.State) { 'AN' {'Green'} 'aus' {'White'} default {'Yellow'} }
                $adm = if ($s.Tweak.Admin) { ' [Admin]' } else { '' }
                $tItems += @{ Label = ("{0} {1,-42} {2}{3}" -f $mark, $s.Tweak.Name, $s.Tweak.Desc, $adm); Color = $color; Tag = $s }
            }
            $tItems += @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = $null }
            $pick = Show-SysPilotArrowMenu -Items $tItems -Title "$cat - Tweaks" -Footer 'Enter = umschalten, Esc = zurueck'
            if ($null -eq $pick) { continue }
            Set-SysPilotPrivacyItem -Tweak $pick
            Start-Sleep -Milliseconds 600
        }
    }
}

Export-ModuleMember -Function Get-SysPilotPrivacyStatus, Set-SysPilotPrivacyItem,
    Set-SysPilotPrivacyBatch, Show-SysPilotPrivacyFix
