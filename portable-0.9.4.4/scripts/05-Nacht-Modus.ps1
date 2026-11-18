# Nacht-Modus - alles Unnoetige schliessen, maximal kuehl & leise
Write-Host "Aktiviere Nacht-Modus..." -ForegroundColor DarkBlue

# 1. Kuehl-Plan
Set-SysPilotPlan -Mode Cool | Out-Null
Write-Host "  [OK] Energieplan: KUEHL & LEISE" -ForegroundColor Green

# 2. Alles Unnoetige schliessen (Browser bleiben, Rest weg)
$schliessen = @('Honeygain','earnapp','Bright VPN','brightdata','TeraBox','TeraBoxWeb',
                'teraboxhost','teraboxunite','OneDrive','GoogleDriveFS','MEGAsync',
                'UpdateHub','wumgr','dnschanger','ASCTray','WiseTray','GalaxyClient',
                'EpicGamesLauncher','Fireflies','Discord','Steam','LM Studio','ollama',
                'Ferdium','UniGetUI')
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
Write-Host "Nacht-Modus AKTIV - minimaler Verbrauch, maximale Ruhe." -ForegroundColor DarkBlue
