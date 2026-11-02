# Gaming-Modus - volle Leistung, Hintergrund bremsen, RAM frei
Write-Host "Aktiviere Gaming-Modus..." -ForegroundColor Magenta

# 1. Volle Leistung
Set-SysPilotPlan -Mode Performance | Out-Null
Write-Host "  [OK] Energieplan: LEISTUNG" -ForegroundColor Green

# 2. Hintergrund-Apps bremsen (Updater, Cloud, Launcher)
$bremsen = @('OneDrive','GoogleDriveFS','MEGAsync','TeraBox','teraboxhost','teraboxunite',
             'UpdateHub','wumgr','dnschanger','GalaxyClient','EpicGamesLauncher',
             'Honeygain','earnapp','Bright VPN','brightdata','ASCTray','WiseTray')
foreach ($name in $bremsen) {
    Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object {
        try { $_.PriorityClass = 'Idle' } catch { }
    }
}
Write-Host "  [OK] Hintergrund-Apps auf IDLE gebremst" -ForegroundColor Green

# 3. RAM freigeben
$ws = Clear-SysPilotWorkingSets
Write-Host "  [OK] RAM freigegeben: $($ws.FreedMB) MB" -ForegroundColor Green

# 4. Game Mode sicherstellen
Enable-SysPilotGameMode

Write-Host ""
Write-Host "Gaming-Modus AKTIV. Viel Spass!" -ForegroundColor Magenta
Write-Host "Tipp: Danach Skript '02-Arbeits-Modus' oder '03-Kuehl-Modus' starten." -ForegroundColor DarkGray
