# SysPilot - Features: Windows-Funktionen & Gaming-Tweaks
#Requires -Version 5.1

function Set-RegValue {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type
}

function Enable-SysPilotGameMode {
    Set-RegValue 'HKCU:\SOFTWARE\Microsoft\GameBar' 'AllowAutoGameMode' 1
    Set-RegValue 'HKCU:\SOFTWARE\Microsoft\GameBar' 'AutoGameModeEnabled' 1
    Write-Host "  [OK] Game Mode aktiviert (Windows priorisiert Spiele)." -ForegroundColor Green
    Write-SysPilotLog "Game Mode aktiviert"
}

function Enable-SysPilotHAGS {
    <# Hardware-beschleunigte GPU-Zeitplanung: weniger Latenz, braucht Neustart #>
    if (-not (Assert-SysPilotAdmin)) { return }
    Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2
    Write-Host "  [OK] Hardware-GPU-Zeitplanung aktiviert (wirkt nach Neustart)." -ForegroundColor Green
    Write-SysPilotLog "HAGS aktiviert"
}

function Set-SysPilotMsAds {
    <# Microsoft-Eigenwerbung: automatisch installierte Werbe-Apps, Vorschlaege, Tipps, Startmenue-Ads #>
    param([bool]$Enabled)
    $v = if ($Enabled) { 1 } else { 0 }
    $cdm = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    Set-RegValue $cdm 'SubscribedContent-338389Enabled' $v
    Set-RegValue $cdm 'SubscribedContent-338388Enabled' $v
    Set-RegValue $cdm 'SubscribedContent-353698Enabled' $v
    Set-RegValue $cdm 'SystemPaneSuggestionsEnabled' $v
    Set-RegValue $cdm 'SilentInstalledAppsEnabled' $v
    Set-RegValue $cdm 'SoftLandingEnabled' $v
    Set-RegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowSyncProviderNotifications' $v
    # Policy (braucht Admin)
    if (Test-SysPilotAdmin) {
        Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' ($(if ($Enabled) { 0 } else { 1 }))
    }
    $state = if ($Enabled) { 'aktiviert' } else { 'deaktiviert' }
    Write-Host "  [OK] Microsoft-Eigenwerbung $state." -ForegroundColor Green
    Write-SysPilotLog "Microsoft-Eigenwerbung $state"
}

function Set-SysPilotPersonalizedAds {
    <# Personalisierte Werbung: Werbe-ID fuer Apps (Tracking). Unabhaengig von Eigenwerbung. #>
    param([bool]$Enabled)
    $v = if ($Enabled) { 1 } else { 0 }
    Set-RegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' $v
    $state = if ($Enabled) { 'aktiviert' } else { 'deaktiviert' }
    Write-Host "  [OK] Personalisierte Werbung $state." -ForegroundColor Green
    Write-SysPilotLog "Personalisierte Werbung $state"
}

function Get-SysPilotAdsStatus {
    $cdm = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    $adv = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo'
    $msAds = (Get-ItemProperty $cdm -Name 'SubscribedContent-338389Enabled' -ErrorAction SilentlyContinue).'SubscribedContent-338389Enabled'
    $persAds = (Get-ItemProperty $adv -Name 'Enabled' -ErrorAction SilentlyContinue).Enabled
    [PSCustomObject]@{
        MsAds = ($msAds -eq 1)
        PersonalizedAds = ($persAds -eq 1)
    }
}

function Disable-SysPilotConsumerFeatures {
    <# Kompatibilitaet: beides aus (wird von AutoOptimize genutzt) #>
    Set-SysPilotMsAds -Enabled $false
    Set-SysPilotPersonalizedAds -Enabled $false
}

function Disable-SysPilotPowerThrottling {
    <# Hintergrund-Drosselung von Windows aus - mehr Leistung, etwas mehr Verbrauch #>
    if (-not (Assert-SysPilotAdmin)) { return }
    Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' 1
    Write-Host "  [OK] Windows Power Throttling deaktiviert (wirkt nach Neustart)." -ForegroundColor Green
    Write-SysPilotLog "Power Throttling deaktiviert"
}

function Set-SysPilotVisualEffectsPretty {
    <# HUEBSCH-Modus: beste Optik inkl. ClearType-Schriftglaettung, Animationen, Transparenz.
       Ehrlich: Auf GPU-beschleunigten Systemen (wie deiner Radeon) kosten Animationen <1% Leistung.
       Abschalten lohnt sich nicht - deshalb ist das hier die Empfehlung. #>
    Set-RegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 1
    Set-RegValue 'HKCU:\Control Panel\Desktop' 'FontSmoothing' '2' 'String'
    Set-RegValue 'HKCU:\Control Panel\Desktop' 'FontSmoothingType' 2
    Set-RegValue 'HKCU:\Control Panel\Desktop' 'DragFullWindows' '1' 'String'
    Set-RegValue 'HKCU:\SOFTWARE\Microsoft\Windows\DWM' 'EnableAeroPeek' 1
    Set-RegValue 'HKCU:\SOFTWARE\Microsoft\Windows\DWM' 'ColorPrevalence' 1
    Set-RegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAnimations' 1
    Set-RegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'IconsOnly' 0
    Set-RegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ListviewAlphaSelect' 1
    Write-Host "  [OK] Optik: HUEBSCH (Schriftglaettung, Animationen, Transparenz bleiben)." -ForegroundColor Green
    Write-Host "       Kostet auf deiner Radeon-GPU unter 1% Leistung - Augenkrebs-frei." -ForegroundColor DarkGray
    Write-SysPilotLog "Visuelle Effekte: Huebsch"
}

function Set-SysPilotVisualEffectsPerformance {
    <# Leistungs-Modus: Animationen aus. Bringt messbar fast nichts (<2%), sieht aber deutlich
       schlechter aus. Schriftglaettung bleibt trotzdem an (Lesbarkeit geht vor). #>
    Set-RegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 2
    Set-RegValue 'HKCU:\Control Panel\Desktop' 'FontSmoothing' '2' 'String'
    Set-RegValue 'HKCU:\Control Panel\Desktop' 'UserPreferencesMask' ([byte[]](0x90,0x12,0x01,0x80,0x10,0x00,0x00,0x00)) 'Binary'
    Write-Host "  [OK] Visuelle Effekte auf Leistung gestellt (nach Ab-/Anmeldung aktiv)." -ForegroundColor Green
    Write-Host "       Ehrlich: bringt <2%, sieht dafuer deutlich schlechter aus." -ForegroundColor DarkGray
    Write-SysPilotLog "Visuelle Effekte: Leistung"
}

function Get-SysPilotOptionalFeatures {
    if (-not (Test-SysPilotAdmin)) {
        Write-Host "  [!] Optionale Features auflisten braucht Admin-Rechte." -ForegroundColor Yellow
        return @()
    }
    Get-WindowsOptionalFeature -Online -ErrorAction SilentlyContinue |
        Where-Object { $_.State -eq 'Enabled' } |
        Select-Object FeatureName
}

function Disable-SysPilotOptionalFeature {
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Assert-SysPilotAdmin)) { return }
    Disable-WindowsOptionalFeature -Online -FeatureName $Name -NoRestart -ErrorAction SilentlyContinue | Out-Null
    Write-Host "  [OK] Feature deaktiviert: $Name" -ForegroundColor Green
    Write-SysPilotLog "Optionales Feature deaktiviert: $Name"
}

function Get-SysPilotVbsStatus {
    try {
        $dg = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace 'root\Microsoft\Windows\DeviceGuard' -ErrorAction Stop
        $status = switch ($dg.VirtualizationBasedSecurityStatus) {
            2 { "LAEUFT (kostet 5-10% Gaming-Leistung)" }
            1 { "aktiviert, aber nicht aktiv" }
            0 { "aus" }
            default { "unbekannt" }
        }
        return $status
    } catch { return "nicht ermittelbar" }
}

function Show-SysPilotFeaturesMenu {
    while ($true) {
        $ads = Get-SysPilotAdsStatus
        $msAdsTxt = if ($ads.MsAds) { 'AN' } else { 'aus' }
        $persAdsTxt = if ($ads.PersonalizedAds) { 'AN' } else { 'aus' }

        $items = @(
            @{ Label = "Game Mode aktivieren (empfohlen)"; Color = 'White'; Tag = 'gamemode' },
            @{ Label = "Hardware-GPU-Zeitplanung (HAGS) aktivieren"; Color = 'White'; Tag = 'hags' },
            @{ Label = "Microsoft-Eigenwerbung: $msAdsTxt  (Werbe-Apps, Vorschlaege, Tipps)"; Color = 'White'; Tag = 'msads' },
            @{ Label = "Personalisierte Werbung: $persAdsTxt  (Werbe-ID/Tracking)"; Color = 'White'; Tag = 'persads' },
            @{ Label = "Windows Power Throttling deaktivieren (mehr Leistung)"; Color = 'White'; Tag = 'throttle' },
            @{ Label = "Optik: HUEBSCH behalten (empfohlen - kostet <1%)"; Color = 'Green'; Tag = 'pretty' },
            @{ Label = "Optik: Leistung (Animationen aus - haesslich, bringt fast nichts)"; Color = 'DarkGray'; Tag = 'perf' },
            @{ Label = "Optionale Windows-Features anzeigen/deaktivieren"; Color = 'White'; Tag = 'features' },
            @{ Label = "VBS-Status anzeigen (Virtualisierungsbasierte Sicherheit)"; Color = 'White'; Tag = 'vbs' },
            @{ Label = "Zurueck"; Color = 'DarkGray'; Tag = $null }
        )
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'Windows-Funktionen & Gaming-Tweaks'
        if ($null -eq $sel) { return }
        switch ($sel) {
            'gamemode' { Enable-SysPilotGameMode; Read-SysPilotChoice "Weiter" | Out-Null }
            'hags' { Enable-SysPilotHAGS; Read-SysPilotChoice "Weiter" | Out-Null }
            'msads' { Set-SysPilotMsAds -Enabled (-not $ads.MsAds); Read-SysPilotChoice "Weiter" | Out-Null }
            'persads' { Set-SysPilotPersonalizedAds -Enabled (-not $ads.PersonalizedAds); Read-SysPilotChoice "Weiter" | Out-Null }
            'throttle' { Disable-SysPilotPowerThrottling; Read-SysPilotChoice "Weiter" | Out-Null }
            'pretty' { Set-SysPilotVisualEffectsPretty; Read-SysPilotChoice "Weiter" | Out-Null }
            'perf' { Set-SysPilotVisualEffectsPerformance; Read-SysPilotChoice "Weiter" | Out-Null }
            'features' {
                $feats = Get-SysPilotOptionalFeatures
                $fitems = @()
                foreach ($f in $feats) { $fitems += @{ Label = $f.FeatureName; Color = 'White'; Tag = $f.FeatureName } }
                $fitems += @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = $null }
                $fsel = Show-SysPilotArrowMenu -Items $fitems -Title 'Optionale Windows-Features (Enter = deaktivieren)'
                if ($fsel) { Disable-SysPilotOptionalFeature -Name $fsel; Read-SysPilotChoice "Weiter" | Out-Null }
            }
            'vbs' { Write-Host ("  VBS: " + (Get-SysPilotVbsStatus)) -ForegroundColor Cyan; Read-SysPilotChoice "Weiter" | Out-Null }
        }
    }
}

Export-ModuleMember -Function Enable-SysPilotGameMode, Enable-SysPilotHAGS,
    Set-SysPilotMsAds, Set-SysPilotPersonalizedAds, Get-SysPilotAdsStatus, Disable-SysPilotConsumerFeatures,
    Disable-SysPilotPowerThrottling,
    Set-SysPilotVisualEffectsPretty, Set-SysPilotVisualEffectsPerformance, Get-SysPilotOptionalFeatures,
    Disable-SysPilotOptionalFeature, Get-SysPilotVbsStatus, Show-SysPilotFeaturesMenu
