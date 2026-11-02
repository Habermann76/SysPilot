# Arbeits-Modus - VS Code, Compiler & Co. bevorzugen
Write-Host "Aktiviere Arbeits-Modus..." -ForegroundColor Cyan

# 1. Ausgewogene Leistung (Kuehl reicht meist, Autopilot schaltet bei Last hoch)
Set-SysPilotPlan -Mode Cool | Out-Null
Write-Host "  [OK] Energieplan: KUEHL (Autopilot schaltet bei Last auf Leistung)" -ForegroundColor Green

# 2. Entwicklungs-Tools bevorzugen
$dev = @('code','devenv','cl','link','msbuild','dotnet','node','python','cargo','rustc','go','ninja','cmake')
foreach ($name in $dev) {
    Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object {
        try { $_.PriorityClass = 'AboveNormal' } catch { }
    }
}
Write-Host "  [OK] Dev-Tools auf AboveNormal" -ForegroundColor Green

# 3. Ablenkung bremsen
$ablenkung = @('Discord','Steam','GalaxyClient','EpicGamesLauncher','Honeygain','earnapp')
foreach ($name in $ablenkung) {
    Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object {
        try { $_.PriorityClass = 'BelowNormal' } catch { }
    }
}
Write-Host "  [OK] Ablenkung gebremst" -ForegroundColor Green

Write-Host ""
Write-Host "Arbeits-Modus AKTIV." -ForegroundColor Cyan
