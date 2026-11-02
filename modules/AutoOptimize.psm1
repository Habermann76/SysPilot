# SysPilot - AutoOptimize: Ein-Klick-Optimierung (mit Backup, rueckgaengig machbar)
#Requires -Version 5.1

function Invoke-SysPilotAutoOptimize {
    Write-SysPilotHeader "Automatische Optimierung (Ein-Klick)"
    if (-not (Assert-SysPilotAdmin)) { return }

    Write-Host "  Was passiert:" -ForegroundColor Cyan
    Write-Host "    1. Backup (Dienste, Registry, Energieplaene)" -ForegroundColor DarkGray
    Write-Host "    2. Dienste optimieren (nur gepruefte Empfehlungen aus config.json)" -ForegroundColor DarkGray
    Write-Host "    3. Sicher unnoetige Windows-Features deaktivieren (Fax, XPS, WorkFolders)" -ForegroundColor DarkGray
    Write-Host "    4. Tweaks: Game Mode an, Werbung/Tipps aus, Optik bleibt HUEBSCH" -ForegroundColor DarkGray
    Write-Host "    5. Prozess-Prioritaeten anwenden" -ForegroundColor DarkGray
    Write-Host ""
    if (-not (Confirm-SysPilot "Jetzt automatisch optimieren?")) { return }

    Write-Host ""
    Write-Host "  [1/5] Backup ..." -ForegroundColor Cyan
    $backup = New-SysPilotBackup -Label "autooptimize"
    Write-Host "        $backup" -ForegroundColor DarkGray

    Write-Host "  [2/5] Dienste optimieren ..." -ForegroundColor Cyan
    $changes = @(Get-SysPilotServicePlan | Where-Object { $_.Aenderung })
    $ok = 0; $i = 0
    foreach ($r in $changes) {
        $i++
        Write-SysPilotProgress -Activity 'Dienste optimieren' -Current $i -Total $changes.Count -Status $r.Name
        if (Set-SysPilotService -Row $r) {
            $ok++
            Write-Host ("        {0,-40} -> {1}" -f $r.Name, $r.Soll) -ForegroundColor DarkGreen
        }
    }
    Complete-SysPilotProgress
    Write-Host "        $ok von $($changes.Count) Diensten optimiert" -ForegroundColor Green

    Write-Host "  [3/5] Optionale Windows-Features (nur sicher unnoetige) ..." -ForegroundColor Cyan
    $safeDisable = @('FaxServicesClientPackage', 'Printing-XPSServices-Features', 'Xps-Foundation-Xps-Viewer', 'WorkFolders-Client')
    $fOk = 0
    foreach ($f in $safeDisable) {
        $feat = Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction SilentlyContinue
        if ($feat -and $feat.State -eq 'Enabled') {
            Disable-WindowsOptionalFeature -Online -FeatureName $f -NoRestart -ErrorAction SilentlyContinue | Out-Null
            Write-Host "        deaktiviert: $f" -ForegroundColor DarkGreen
            $fOk++
        }
    }
    if ($fOk -eq 0) { Write-Host "        nichts zu deaktivieren" -ForegroundColor DarkGray }

    Write-Host "  [4/5] Tweaks (Game Mode, Werbung aus, Optik HUEBSCH) ..." -ForegroundColor Cyan
    Enable-SysPilotGameMode
    Disable-SysPilotConsumerFeatures
    Set-SysPilotVisualEffectsPretty

    Write-Host "  [5/5] Prozess-Prioritaeten ..." -ForegroundColor Cyan
    Set-SysPilotPriorities -Quiet
    Write-Host "        angewendet" -ForegroundColor Green

    Write-Host ""
    Write-Host "  FERTIG. Rueckgaengig: Menue 15 (Backup wiederherstellen)." -ForegroundColor Green
    Write-Host "  Hinweis: Manche Aenderungen wirken erst nach Neustart/Abmeldung." -ForegroundColor DarkGray
    Write-SysPilotLog "Auto-Optimierung: $ok Dienste, $fOk Features, Tweaks angewendet (Backup: $backup)"
}

Export-ModuleMember -Function Invoke-SysPilotAutoOptimize
