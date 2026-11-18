foreach ($f in @('SysPilot.ps1','SysPilot-GUI.ps1','modules\HealthMonitor.psm1','modules\Toolbox.psm1')) {
  try { [void][scriptblock]::Create((Get-Content $f -Raw -Encoding UTF8)); Write-Host "$f OK" }
  catch { Write-Host "$f FEHLER: $($_.Exception.Message)" }
}