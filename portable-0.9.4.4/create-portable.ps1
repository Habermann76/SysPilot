# Create portable version of SysPilot 0.9.4.4
$folder = 'C:\Users\haber\SysPilot\portable-0.9.4.4'
if (Test-Path $folder) { Remove-Item $folder -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $folder -Force | Out-Null

$files = Get-ChildItem -Recurse -Include *.ps1,*.iss,*.json,*.txt,*.md,*.lng,*.dat,*.bat,*.config | Where-Object {
    $_.FullName -notmatch 'backup|node_modules|\.git|\.cache|dist|installer-output|\.vscode|portable-0\.'
}

foreach ($f in $files) {
    $rel = $f.FullName.Substring('C:\Users\haber\SysPilot'.Length)
    $dst = Join-Path $folder $rel
    $dir = Split-Path $dst
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Copy-Item -Path $f.FullName -Destination $dst -Force
}

Write-Host "Copied" + (Get-ChildItem $folder -Recurse | Measure-Object).Count + " files"