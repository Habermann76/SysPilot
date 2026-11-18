# Kuehl-Modus - leise & kuehl, Ballast schliessen
Write-Host "Aktiviere Kuehl-Modus..." -ForegroundColor Blue

# 1. Kuehl-Plan
Set-SysPilotPlan -Mode Cool | Out-Null
Write-Host "  [OK] Energieplan: KUEHL & LEISE" -ForegroundColor Green

# 2. Unnoetige Hintergrund-Apps SCHLIESSEN (nicht nur bremsen)
$schliessen = @('Honeygain','earnapp','Bright VPN','TeraBox','TeraBoxWeb','teraboxhost',
                'teraboxunite','UpdateHub','wumgr','ASCTray','WiseTray','GalaxyClient',
                'EpicGamesLauncher','Fireflies')
foreach ($name in $schliessen) {
    $p = Get-Process -Name $name -ErrorAction SilentlyContinue
    if ($p) {
        $p | Stop-Process -Force -ErrorAction SilentlyContinue
        Write-Host "  [OK] geschlossen: $name" -ForegroundColor DarkGreen
    }
}

# 3. RAM freigeben
$ws = Clear-SysPilotWorkingSets
Write-Host "  [OK] RAM freigegeben: $($ws.FreedMB) MB" -ForegroundColor Green

Write-Host ""
Write-Host "Kuehl-Modus AKTIV - leise und stromsparend." -ForegroundColor Blue
