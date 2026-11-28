# Schaltet Claude Code in einem Projektordner auf den lokalen TPU-Proxy (oder zurueck auf normales Claude).
# Aendert nur <Projekt>\.claude\settings.local.json - dein normales Claude bleibt ueberall sonst unberuehrt.
param(
  [Parameter(Mandatory = $true)][string]$Project,
  [switch]$Off,
  [int]$Port = 18787,
  [string]$Model = "qwen3.8-27b"
)
$dir = Join-Path $Project ".claude"
New-Item -ItemType Directory -Force $dir | Out-Null
$f = Join-Path $dir "settings.local.json"
$top = @{}; $envMap = @{}
if (Test-Path $f) {
  $o = Get-Content $f -Raw | ConvertFrom-Json
  foreach ($p in $o.PSObject.Properties) { if ($p.Name -eq "env") { foreach ($e in $p.Value.PSObject.Properties) { $envMap[$e.Name] = $e.Value } } else { $top[$p.Name] = $p.Value } }
}
$vals = [ordered]@{
  ANTHROPIC_BASE_URL = "http://127.0.0.1:$Port"
  ANTHROPIC_AUTH_TOKEN = "local-proxy"
  ANTHROPIC_MODEL = $Model
  ANTHROPIC_DEFAULT_OPUS_MODEL = $Model
  ANTHROPIC_DEFAULT_SONNET_MODEL = $Model
  ANTHROPIC_DEFAULT_HAIKU_MODEL = $Model
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1"
}
foreach ($k in $vals.Keys) { if ($Off) { $envMap.Remove($k) } else { $envMap[$k] = $vals[$k] } }
if ($envMap.Count -gt 0) { $top["env"] = $envMap }
$json = ($top | ConvertTo-Json -Depth 10)
[IO.File]::WriteAllText($f, $json, (New-Object Text.UTF8Encoding($false)))
if ($Off) { Write-Host "TPU-Modus AUS fuer $Project (normales Claude)." -ForegroundColor Yellow }
else { Write-Host "TPU-Modus AN fuer $Project -> http://127.0.0.1:$Port. Claude Code im Ordner neu starten bzw. VS Code 'Reload Window'." -ForegroundColor Green }
