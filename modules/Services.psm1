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
    $plan = Get-SysPilotServicePlan
    $changes = $plan | Where-Object { $_.Aenderung }

    if ($changes.Count -eq 0) {
        Write-Host "  Alle empfohlenen Dienste sind bereits optimal eingestellt." -ForegroundColor Green
        return
    }

    Write-Host "  Folgende $($changes.Count) Aenderungen werden empfohlen:" -ForegroundColor Cyan
    Write-Host ""
    $i = 0
    foreach ($r in $changes) {
        $i++
        Write-Host ("  [{0,2}] {1,-38} {2,-10} -> {3,-10}" -f $i, $r.Name, $r.Ist, $r.Soll) -ForegroundColor White
        Write-Host ("       $($r.Grund)") -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host "  Befehle: A = alle anwenden | <Nr> = einzeln anwenden | 0 = zurueck" -ForegroundColor Yellow
    $c = Read-SysPilotChoice "Auswahl"
    if ($c -eq '0' -or $c -eq '') { return }
    if (-not (Assert-SysPilotAdmin)) { return }

    $backup = New-SysPilotBackup -Label "services"
    Write-Host "  Backup: $backup" -ForegroundColor DarkGray

    if ($c -match '^(a|A)$') {
        $ok = 0
        foreach ($r in $changes) { if (Set-SysPilotService -Row $r) { $ok++ } }
        Write-Host "  [OK] $ok von $($changes.Count) Diensten optimiert." -ForegroundColor Green
    } else {
        $n = 0
        if ([int]::TryParse($c, [ref]$n) -and $n -ge 1 -and $n -le $changes.Count) {
            if (Set-SysPilotService -Row $changes[$n - 1]) {
                Write-Host "  [OK] $($changes[$n - 1].Name) -> $($changes[$n - 1].Soll)" -ForegroundColor Green
            }
        }
    }
}

Export-ModuleMember -Function Get-SysPilotServicePlan, Set-SysPilotService, Show-SysPilotServiceTuner
