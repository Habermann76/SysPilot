# Stoppt die Kaggle-TPU-Sitzung (spart Quota) und den lokalen Proxy.
param([string]$LabDir = (Join-Path $env:USERPROFILE "kaggle-tpu-lab"), [int]$Port = 18787)
$py = (Get-Command python -ErrorAction Stop).Source
Write-Host "Stoppe Kaggle-Kernel ..." -ForegroundColor Yellow
& $py -u (Join-Path $LabDir "launch.py") stop
Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }
$sd = if ($env:HERETIC_STATE_DIR) { $env:HERETIC_STATE_DIR } else { Join-Path $env:LOCALAPPDATA "heretic-claude" }
Remove-Item (Join-Path $sd "state.json") -Force -ErrorAction SilentlyContinue
Write-Host "Gestoppt." -ForegroundColor Green
