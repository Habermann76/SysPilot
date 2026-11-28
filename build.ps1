# SysPilot Build: liest die Version aus version.txt und baut Installer (EXE) + Portable (ZIP)
# Aufruf:  powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
param([string]$Version)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $Version) { $Version = (Get-Content (Join-Path $root 'version.txt') -Raw).Trim() }
if ($Version -notmatch '^\d+(\.\d+){2,3}$') { throw "Ungueltige Version: '$Version'" }
$out = Join-Path $root 'installer-output'
New-Item -ItemType Directory -Force $out | Out-Null
Write-Host "== SysPilot $Version bauen ==" -ForegroundColor Cyan

# --- Installer (Inno Setup) ---
$iscc = @(
  "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
  "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
  "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw 'ISCC.exe nicht gefunden - Inno Setup 6 installieren: winget install JRSoftware.InnoSetup' }
& $iscc "/DMyAppVersion=$Version" (Join-Path $root 'installer.iss')
if ($LASTEXITCODE -ne 0) { throw "ISCC fehlgeschlagen (Exit $LASTEXITCODE)" }

# --- Portable (ZIP) ---
$stage = Join-Path $env:TEMP "SysPilot-portable-$Version"
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force "$stage\modules","$stage\scripts" | Out-Null
foreach ($d in 'extension','kaggle-tpu') {
  $sp = Join-Path $root $d
  if (Test-Path $sp) { Copy-Item $sp "$stage\$d" -Recurse }
}
foreach ($f in 'SysPilot.ps1','SysPilot-GUI.ps1','setup-automation.ps1','stop-syspilot.ps1','Restart-SysPilot.ps1','version.txt','config.json','README.md','INSTALL.md','DEBUG.md','ROADMAP.md','LICENSE') {
  $p = Join-Path $root $f; if (Test-Path $p) { Copy-Item $p $stage }
}
Copy-Item (Join-Path $root 'modules\*.psm1') "$stage\modules"
Copy-Item (Join-Path $root 'scripts\*.ps1') "$stage\scripts"
$zip = Join-Path $out "SysPilot-$Version-beta-portable.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path "$stage\*" -DestinationPath $zip -Force

Write-Host "`nFertig:" -ForegroundColor Green
Get-ChildItem $out -Filter "*$Version*" | Where-Object { $_.Extension -in '.exe','.zip' } | Select-Object Name,Length,LastWriteTime | Format-Table -AutoSize
