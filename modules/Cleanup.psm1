# SysPilot - Cleanup: Datentraeger bereinigen (sicher, mit Analyse vorher)
#Requires -Version 5.1

function Get-SysPilotCleanupTargets {
    $cfg = (Get-SysPilotConfig).Cleanup
    $targets = @()

    if ($cfg.UserTemp) {
        $targets += @{ Name = 'Benutzer-Temp'; Path = $env:TEMP; Admin = $false }
    }
    if ($cfg.WindowsTemp) {
        $targets += @{ Name = 'Windows-Temp'; Path = 'C:\Windows\Temp'; Admin = $true }
    }
    if ($cfg.WindowsUpdateCache) {
        $targets += @{ Name = 'Windows-Update-Cache'; Path = 'C:\Windows\SoftwareDistribution\Download'; Admin = $true; StopService = 'wuauserv' }
    }
    if ($cfg.DeliveryOptimizationCache) {
        $targets += @{ Name = 'Delivery-Optimization-Cache'; Path = 'C:\Windows\SoftwareDistribution\DeliveryOptimization'; Admin = $true }
    }
    if ($cfg.ThumbnailCache) {
        $targets += @{ Name = 'Miniaturbilder-Cache'; Path = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer"; Filter = 'thumbcache_*.db'; Admin = $false }
    }
    if ($cfg.ShaderCache) {
        $targets += @{ Name = 'DirectX-Shader-Cache (AMD)'; Path = "$env:LOCALAPPDATA\AMD\DxCache"; Admin = $false }
        $targets += @{ Name = 'DirectX-Shader-Cache (D3DSC)'; Path = "$env:LOCALAPPDATA\D3DSCache"; Admin = $false }
    }
    if ($cfg.ErrorReports) {
        $targets += @{ Name = 'Windows-Fehlerberichte'; Path = 'C:\ProgramData\Microsoft\Windows\WER'; Admin = $true }
        $targets += @{ Name = 'Benutzer-Fehlerberichte'; Path = "$env:LOCALAPPDATA\Microsoft\Windows\WER"; Admin = $false }
    }
    if ($cfg.BrowserCaches) {
        $targets += @{ Name = 'Chrome-Cache'; Path = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache"; Admin = $false; ProcessCheck = 'chrome' }
        $targets += @{ Name = 'Edge-Cache'; Path = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache"; Admin = $false; ProcessCheck = 'msedge' }
    }
    if ($cfg.OldLogsDays -gt 0) {
        $targets += @{ Name = "Alte Windows-Logs (>$($cfg.OldLogsDays) Tage)"; Path = 'C:\Windows\Logs'; Admin = $true; OlderThanDays = $cfg.OldLogsDays }
    }
    return $targets
}

function Get-FolderSizeMB {
    param([string]$Path, [string]$Filter, [int]$OlderThanDays = 0)
    if (-not (Test-Path $Path)) { return 0 }
    $files = Get-ChildItem $Path -Recurse -Force -File -ErrorAction SilentlyContinue
    if ($Filter) { $files = $files | Where-Object { $_.Name -like $Filter } }
    if ($OlderThanDays -gt 0) {
        $cutoff = (Get-Date).AddDays(-$OlderThanDays)
        $files = $files | Where-Object { $_.LastWriteTime -lt $cutoff }
    }
    $sum = ($files | Measure-Object Length -Sum).Sum
    if (-not $sum) { return 0 }
    return [math]::Round($sum / 1MB)
}

function Show-SysPilotCleanupAnalysis {
    Write-SysPilotHeader "Bereinigungs-Analyse"
    $targets = Get-SysPilotCleanupTargets
    $total = 0
    $rows = @()
    foreach ($t in $targets) {
        $size = Get-FolderSizeMB -Path $t.Path -Filter $t.Filter -OlderThanDays ([int]$t.OlderThanDays)
        $total += $size
        $rows += [PSCustomObject]@{ Bereich = $t.Name; GroesseMB = $size; Pfad = $t.Path }
    }
    $rows | Sort-Object GroesseMB -Descending | Format-Table -AutoSize
    Write-Host "  Gesamt freigebbar: ca. $total MB" -ForegroundColor Cyan
    return $total
}

function Invoke-SysPilotCleanup {
    $cfg = (Get-SysPilotConfig).Cleanup
    $targets = Get-SysPilotCleanupTargets
    $isAdmin = Test-SysPilotAdmin
    $freedTotal = 0

    $ti = 0
    foreach ($t in $targets) {
        $ti++
        Write-SysPilotProgress -Activity 'Datentraeger bereinigen' -Current $ti -Total $targets.Count -Status $t.Name
        if ($t.Admin -and -not $isAdmin) {
            Write-Host "  [uebersprungen] $($t.Name) (braucht Admin)" -ForegroundColor DarkYellow
            continue
        }
        if ($t.ProcessCheck -and (Get-Process -Name $t.ProcessCheck -ErrorAction SilentlyContinue)) {
            Write-Host "  [uebersprungen] $($t.Name) ($($t.ProcessCheck) laeuft gerade)" -ForegroundColor DarkYellow
            continue
        }
        if (-not (Test-Path $t.Path)) { continue }

        $before = Get-FolderSizeMB -Path $t.Path -Filter $t.Filter -OlderThanDays ([int]$t.OlderThanDays)
        if ($before -eq 0) { continue }

        if ($t.StopService) {
            Stop-Service -Name $t.StopService -Force -ErrorAction SilentlyContinue
        }

        $files = Get-ChildItem $t.Path -Recurse -Force -ErrorAction SilentlyContinue
        if ($t.Filter) { $files = $files | Where-Object { $_.Name -like $t.Filter } }
        if ($t.OlderThanDays -gt 0) {
            $cutoff = (Get-Date).AddDays(-$t.OlderThanDays)
            $files = $files | Where-Object { $_.LastWriteTime -lt $cutoff -and -not $_.PSIsContainer }
        }
        foreach ($f in $files) {
            Remove-Item $f.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }

        if ($t.StopService) {
            Start-Service -Name $t.StopService -ErrorAction SilentlyContinue
        }

        $after = Get-FolderSizeMB -Path $t.Path -Filter $t.Filter -OlderThanDays ([int]$t.OlderThanDays)
        $freed = $before - $after
        $freedTotal += $freed
        Write-Host ("  [OK] {0,-40} {1,6} MB frei" -f $t.Name, $freed) -ForegroundColor Green
    }

    if ($cfg.RecycleBin) {
        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
        Write-Host "  [OK] Papierkorb geleert" -ForegroundColor Green
    }

    Complete-SysPilotProgress
    Write-Host ""
    Write-Host "  Gesamt freigegeben: ca. $freedTotal MB" -ForegroundColor Cyan
    Write-SysPilotLog "Bereinigung: $freedTotal MB freigegeben"
}

function Show-SysPilotCleanupMenu {
    Write-SysPilotHeader "Datentraeger bereinigen"
    $total = Show-SysPilotCleanupAnalysis
    if ($total -eq 0) { Write-Host "  Nichts zu bereinigen." -ForegroundColor Green; return }
    Write-Host ""
    if (Confirm-SysPilot "Jetzt bereinigen?") {
        Invoke-SysPilotCleanup
    }
}

Export-ModuleMember -Function Show-SysPilotCleanupAnalysis, Invoke-SysPilotCleanup, Show-SysPilotCleanupMenu
