# heretic-claude watchdog: startet den Kaggle-TPU-Server, erkennt URL + API-Key, haelt den
# lokalen Proxy aktuell, prueft die Gesundheit und startet bei Ausfall neu. Windows PowerShell 5.1+.
param(
  [string]$Model = "qwen38-27b",
  [int]$Port = 18787,
  [string]$LabDir = (Join-Path $env:USERPROFILE "kaggle-tpu-lab"),
  [string]$LaunchScript = "",
  [string[]]$ExtraArgs = @(),
  [int]$MaxFailures = 5,
  [int]$MaxRestarts = 3,
  [int]$HealthSeconds = 60
)
$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$StateDir = if ($env:HERETIC_STATE_DIR) { $env:HERETIC_STATE_DIR } else { Join-Path $env:LOCALAPPDATA "heretic-claude" }
$StateFile = Join-Path $StateDir "state.json"
New-Item -ItemType Directory -Force $StateDir | Out-Null
$env:HERETIC_STATE_DIR = $StateDir
$env:HERETIC_PORT = "$Port"
$env:PYTHONUNBUFFERED = "1"
$env:PYTHONIOENCODING = "utf-8"
$py = (Get-Command python -ErrorAction Stop).Source
$Script = if ($LaunchScript) { $LaunchScript } else { Join-Path $LabDir "launch.py" }
if (-not (Test-Path $Script)) { Write-Host "FEHLER: $Script nicht gefunden. Erst setup.ps1 ausfuehren." -ForegroundColor Red; exit 1 }
if (-not $LaunchScript) {
  & kaggle kernels list --mine --page-size 1 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Write-Host "FEHLER: Kaggle-Anmeldung fehlt oder ist ungueltig." -ForegroundColor Red
    Write-Host "Token erstellen: https://www.kaggle.com/settings  (API -> Create New Token), dann .\setup.ps1 ausfuehren - es fragt den Token unsichtbar ab." -ForegroundColor Yellow
    exit 1
  }
}

function Say($m, $c = "Gray") { Write-Host ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $m) -ForegroundColor $c }
function Mask($s) { ($s -replace '\x1b\[[0-9;]*m', '') -replace '((?:sk|glm)-)[0-9A-Fa-f]{8,}', '$1********' }
function Clear-State { Remove-Item $StateFile -Force -ErrorAction SilentlyContinue }
function Write-State($url, $key, $model) {
  $json = @{ url = $url; key = $key; model = $model; started = (Get-Date).ToString("s") } | ConvertTo-Json
  $tmp = "$StateFile.tmp"
  [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
  Move-Item $tmp $StateFile -Force
}
function Read-New($path, [ref]$pos) {
  if (-not (Test-Path $path)) { return "" }
  $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
  try {
    if ($fs.Length -le $pos.Value) { return "" }
    $fs.Seek($pos.Value, 'Begin') | Out-Null
    $buf = New-Object byte[] ($fs.Length - $pos.Value)
    $n = $fs.Read($buf, 0, $buf.Length); $pos.Value += $n
    return [Text.Encoding]::UTF8.GetString($buf, 0, $n)
  } finally { $fs.Close() }
}
function Ensure-Proxy {
  try { Invoke-RestMethod "http://127.0.0.1:$Port/_health" -TimeoutSec 2 | Out-Null; return } catch {}
  Start-Process -FilePath $py -ArgumentList "`"$(Join-Path $Root 'proxy.py')`"" -WindowStyle Hidden | Out-Null
  Start-Sleep -Seconds 2
  try { Invoke-RestMethod "http://127.0.0.1:$Port/_health" -TimeoutSec 3 | Out-Null; Say "Lokaler Proxy laeuft auf http://127.0.0.1:$Port" Green }
  catch { Say "WARNUNG: Proxy startet nicht (Port $Port belegt?)" Yellow }
}
function Test-Health($url, $key) {
  try { (Invoke-WebRequest "$url/v1/models" -Headers @{ Authorization = "Bearer $key" } -TimeoutSec 20 -UseBasicParsing).StatusCode -eq 200 } catch { $false }
}

$failures = 0; $restarts = 0; $run = $null
Ensure-Proxy
try {
  while ($true) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $log = Join-Path $StateDir "run-$stamp.log"; $err = "$log.err"
    $argList = @("-u", "`"$Script`"", "serve", "--model", $Model) + $ExtraArgs
    Say "Starte TPU-Server (Modell $Model). Das dauert je nach Warteschlange ca. 5-25 Minuten." Cyan
    $run = Start-Process -FilePath $py -ArgumentList $argList -WorkingDirectory (Split-Path $Script) `
      -RedirectStandardOutput $log -RedirectStandardError $err -WindowStyle Hidden -PassThru
    $pos = [long]0; $epos = [long]0; $all = ""; $url = $null; $key = $null; $mdl = $Model; $ready = $false
    $nextHealth = Get-Date; $bad = 0
    while (-not $run.HasExited) {
      $new = (Read-New $log ([ref]$pos)) + (Read-New $err ([ref]$epos))
      if ($new) {
        foreach ($line in ($new -split "`r?`n")) { if ($line.Trim()) { Write-Host (Mask $line) -ForegroundColor DarkGray } }
        $all += ($new -replace '\x1b\[[0-9;]*m', ''); if ($all.Length -gt 200000) { $all = $all.Substring($all.Length - 100000) }
        if (-not $ready) {
          if ($all -match 'base URL\s*:\s*(https?://\S+)') { $url = ($Matches[1] -replace '/v1/?$', '').TrimEnd('/') }
          if ($all -match 'API key\s*:\s*((?:sk|glm)-[0-9A-Fa-f]+)') { $key = $Matches[1] }
          if ($all -match '(?m)^\s*model\s*:\s*(\S+)') { $mdl = $Matches[1] }
          if ($url -and $key) {
            Write-State $url $key $mdl; $ready = $true; $failures = 0
            Say "BEREIT. Lokale Adresse fuer alle Tools: http://127.0.0.1:$Port  (Modell: $mdl)" Green
            Say "Claude Code im Projekt aktivieren: use-tpu.ps1 -Project <Ordner>" Green
          }
        }
      }
      if ($ready -and (Get-Date) -ge $nextHealth) {
        $nextHealth = (Get-Date).AddSeconds($HealthSeconds)
        if (Test-Health $url $key) { $bad = 0 } else { $bad++; Say "Gesundheitscheck fehlgeschlagen ($bad/3)" Yellow }
        if ($bad -ge 3) { Say "Server antwortet nicht mehr - starte neu." Red; break }
      }
      Start-Sleep -Seconds 3
    }
    Clear-State
    if (-not $run.HasExited) { & $py "-u" $Script "stop" 2>&1 | Out-Null; Stop-Process -Id $run.Id -Force -ErrorAction SilentlyContinue }
    if ($ready) {
      $restarts++
      if ($restarts -gt $MaxRestarts) { Say "Sitzung beendet. Maximale Neustarts ($MaxRestarts) erreicht - Schutz der woechentlichen TPU-Quota. Mit TPU-Start erneut starten." Yellow; break }
      Say "Sitzung beendet (Zeitlimit/Leerlauf/Ausfall). Neustart $restarts/$MaxRestarts in 20 s." Yellow
      Start-Sleep -Seconds 20; continue
    }
    $failures++
    Say "Start fehlgeschlagen ($failures/$MaxFailures). Letzte Ausgabe:" Red
    (Get-Content $log -Tail 12 -ErrorAction SilentlyContinue) + (Get-Content $err -Tail 6 -ErrorAction SilentlyContinue) | ForEach-Object { Write-Host (Mask $_) -ForegroundColor Red }
    if ($failures -ge $MaxFailures) { Say "Zu viele Fehlversuche - Abbruch. Pruefe: kaggle Login, TPU-Quota, Telefonverifizierung." Red; break }
    $wait = [Math]::Min(600, 60 * $failures); Say "Neuer Versuch in $wait s." Yellow; Start-Sleep -Seconds $wait
  }
} finally {
  Clear-State
  if ($run -and -not $run.HasExited) {
    Say "Beende TPU-Sitzung (spart Quota) ..." Yellow
    & $py "-u" $Script "stop" 2>&1 | Out-Null
    Stop-Process -Id $run.Id -Force -ErrorAction SilentlyContinue
  }
}
