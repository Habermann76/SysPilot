# SysPilot - Services: Windows-Dienste sicher optimieren (mit Backup)
#Requires -Version 5.1

function Get-StartValue {
    # Boot=0 System=1 Automatic=2 Manual=3 Disabled=4 (hoeher = staerker reduziert)
    param([string]$Type)
    switch ($Type) { 'Automatic' { 2 } 'AutomaticDelayedStart' { 2 } 'Manual' { 3 } 'Disabled' { 4 } default { 2 } }
}

function Get-SysPilotServicePlan {
    <# Vergleicht Empfehlungen aus config.json mit dem Ist-Zustand.
       Nur als Aenderung markiert, wenn der Ist-Zustand MEHR Ressourcen verbraucht als empfohlen. #>
    $cfg = Get-SysPilotConfig
    $rows = @()
    foreach ($rec in $cfg.Services) {
        $name = $rec.Name
        $isWildcard = $name.EndsWith('*')
        $base = $name.TrimEnd('*')
        $sollVal = Get-StartValue $rec.StartupType

        $svc = $null
        if ($isWildcard) {
            $svc = Get-Service -Name "$base*" -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $svc) {
                # Per-User-Dienst-Vorlage (noch keine Instanz) -> Registry pruefen
                $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$base"
                if (Test-Path $regPath) {
                    $start = (Get-ItemProperty $regPath -Name Start -ErrorAction SilentlyContinue).Start
                    $rows += [PSCustomObject]@{
                        Name = $base; DisplayName = "(Vorlage, pro Benutzer)"; Ist = $start
                        Soll = $rec.StartupType; Grund = $rec.Reason
                        Aenderung = ($start -lt $sollVal); Vorlage = $true
                    }
                }
                continue
            }
        } else {
            $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        }
        if (-not $svc) { continue }

        $ist = $svc.StartType.ToString()
        $istVal = Get-StartValue $ist
        $rows += [PSCustomObject]@{
            Name = $svc.Name; DisplayName = $svc.DisplayName; Ist = $ist
            Soll = $rec.StartupType; Grund = $rec.Reason
            Aenderung = ($istVal -lt $sollVal); Vorlage = $false
        }
    }
    return $rows
}

function Set-SysPilotService {
    param([Parameter(Mandatory)]$Row)
    $startVal = switch ($Row.Soll) { 'Disabled' { 4 } 'Manual' { 3 } 'Automatic' { 2 } default { 3 } }

    if ($Row.Vorlage) {
        # Per-User-Dienst-Vorlage ueber Registry setzen
        $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$($Row.Name)"
        Set-ItemProperty -Path $regPath -Name Start -Value $startVal -Type DWord
        Write-SysPilotLog "Dienst-Vorlage $($Row.Name) -> $($Row.Soll) (Registry)"
        return $true
    }

    try {
        Set-Service -Name $Row.Name -StartupType $Row.Soll -ErrorAction Stop
        if ($Row.Soll -eq 'Disabled') {
            $svc = Get-Service -Name $Row.Name -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq 'Running') {
                Stop-Service -Name $Row.Name -Force -ErrorAction SilentlyContinue
            }
        }
        Write-SysPilotLog "Dienst $($Row.Name) -> $($Row.Soll)"
        return $true
    } catch {
        Write-Host "  [!] $($Row.Name): $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }
}

function Show-SysPilotServiceTuner {
    Write-SysPilotHeader "Dienste optimieren"
    $plan = @(Get-SysPilotServicePlan)
    $changes = @($plan | Where-Object { $_.Aenderung })

    if ($changes.Count -eq 0) {
        Write-Host "  Alle empfohlenen Dienste sind bereits optimal eingestellt." -ForegroundColor Green
        return
    }

    Write-Host "  Folgende $($changes.Count) Aenderungen werden empfohlen:" -ForegroundColor Cyan
    Write-Host ""
    foreach ($r in $changes) {
        Write-Host ("       {0,-38} {1,-10} -> {2,-10}  ({3})" -f $r.Name, $r.Ist, $r.Soll, $r.Grund) -ForegroundColor DarkGray
    }
    Write-Host ""

    $items = @()
    foreach ($r in $changes) {
        $items += @{ Label = ("{0,-38} {1,-10} -> {2,-10}" -f $r.Name, $r.Ist, $r.Soll); Color = 'White'; Tag = $r }
    }
    $items += @{ Label = 'ALLE Aenderungen anwenden'; Color = 'Green'; Tag = 'all' }
    $items += @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = $null }

    $sel = Show-SysPilotArrowMenu -Items $items -Title 'Dienste-Optimierung' -Footer 'Pfeiltasten, Enter = anwenden, Esc = zurueck'
    if ($null -eq $sel) { return }
    if (-not (Assert-SysPilotAdmin)) { return }

    $backup = New-SysPilotBackup -Label "services"
    Write-Host "  Backup: $backup" -ForegroundColor DarkGray

    if ($sel -eq 'all') {
        $ok = 0
        foreach ($r in $changes) { if (Set-SysPilotService -Row $r) { $ok++ } }
        Write-Host "  [OK] $ok von $($changes.Count) Diensten optimiert." -ForegroundColor Green
    } else {
        if (Set-SysPilotService -Row $sel) {
            Write-Host "  [OK] $($sel.Name) -> $($sel.Soll)" -ForegroundColor Green
        }
    }
    Read-SysPilotChoice "Weiter mit Enter" | Out-Null
}

Export-ModuleMember -Function Get-SysPilotServicePlan, Set-SysPilotService, Show-SysPilotServiceTuner
