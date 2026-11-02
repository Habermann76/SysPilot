# Aufraeumen - Temp leeren, RAM frei, kurze Analyse
Write-Host "Raeume auf..." -ForegroundColor Yellow

# 1. RAM freigeben
$ws = Clear-SysPilotWorkingSets
Write-Host "  [OK] RAM freigegeben: $($ws.FreedMB) MB" -ForegroundColor Green

# 2. Temp-Ordner leeren (nur Benutzer-Temp, ohne Admin)
$temp = $env:TEMP
$before = (Get-ChildItem $temp -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
Get-ChildItem $temp -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
$after = (Get-ChildItem $temp -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
$freedMB = [math]::Round(($before - $after) / 1MB)
Write-Host "  [OK] Temp geleert: $freedMB MB frei" -ForegroundColor Green

# 3. Kurz-Analyse
Write-Host ""
Write-Host "  Aktuelle Top-Verbraucher:" -ForegroundColor Cyan
Get-Process | Group-Object ProcessName | ForEach-Object {
    [PSCustomObject]@{ Programm = $_.Name; RAM_MB = [math]::Round(($_.Group | Measure-Object WorkingSet64 -Sum).Sum / 1MB) }
} | Sort-Object RAM_MB -Descending | Select-Object -First 5 | Format-Table -AutoSize

Write-Host "Aufraeumen fertig." -ForegroundColor Yellow
