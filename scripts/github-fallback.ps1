# GitHub-Fallback ohne GitHub MCP
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Message,
    [string]$Branch = 'master',
    [switch]$Push
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$status = @(git status --short)
if (-not $status) { Write-Host 'Keine Änderungen zum Committen.'; exit 0 }
Write-Host ($status -join "`n")
git add -A
git commit -m $Message
if ($Push) {
    git push origin $Branch
    Write-Host "Push erfolgreich: origin/$Branch" -ForegroundColor Green
} else {
    Write-Host 'Commit erstellt. Push nur mit -Push ausführen.' -ForegroundColor Yellow
}
