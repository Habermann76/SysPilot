# SysPilot - Startup: Autostart-Manager (Registry, Autostart-Ordner, Aufgaben)
#Requires -Version 5.1

$script:RunKeys = @(
    @{ Hive = 'HKCU'; Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' },
    @{ Hive = 'HKLM'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' },
    @{ Hive = 'HKLM32'; Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32' }
)

function Get-SysPilotStartupItems {
    $cfg = Get-SysPilotConfig
    $items = @()

    foreach ($rk in $script:RunKeys) {
        $reg = Get-ItemProperty -Path $rk.Path -ErrorAction SilentlyContinue
        if (-not $reg) { continue }
        $approved = Get-ItemProperty -Path $rk.Approved -ErrorAction SilentlyContinue
        foreach ($prop in $reg.PSObject.Properties) {
            if ($prop.Name -like 'PS*') { continue }
            $enabled = $true
            if ($approved) {
                $bytes = $approved.PSObject.Properties[$prop.Name]
                if ($bytes -and $bytes.Value -is [byte[]] -and $bytes.Value.Length -gt 0) {
                    $enabled = ($bytes.Value[0] -eq 2)
                }
            }
            $flag = ""
            foreach ($cat in $cfg.KnownBloat.PSObject.Properties) {
                foreach ($b in $cat.Value) {
                    if ($prop.Name -like "*$b*" -or $prop.Value -like "*$b*") { $flag = $cat.Name; break }
                }
                if ($flag) { break }
            }
            $items += [PSCustomObject]@{
                Typ      = "Registry-$($rk.Hive)"
                Name     = $prop.Name
                Befehl   = $prop.Value
                Aktiv    = $enabled
                Hinweis  = $flag
                Quelle   = $rk.Path
            }
        }
    }

    # Autostart-Ordner (Benutzer + Alle)
    $folders = @(
        [Environment]::GetFolderPath('Startup'),
        [Environment]::GetFolderPath('CommonStartup')
    )
    foreach ($f in $folders) {
        Get-ChildItem $f -Filter '*.lnk' -ErrorAction SilentlyContinue | ForEach-Object {
            $items += [PSCustomObject]@{
                Typ     = 'Autostart-Ordner'
                Name    = $_.BaseName
                Befehl  = $_.FullName
                Aktiv   = $true
                Hinweis = ''
                Quelle  = $f
            }
        }
    }

    # Anmelde-Aufgaben (nicht Microsoft)
    Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $_.TaskPath -notmatch '^\\Microsoft' -and
        ($_.Triggers | Where-Object { $_.CimClass.CimClassName -match 'LogonTrigger' })
    } | ForEach-Object {
        $items += [PSCustomObject]@{
            Typ     = 'Aufgabe'
            Name    = $_.TaskName
            Befehl  = ($_.Actions | Select-Object -First 1).Execute
            Aktiv   = ($_.State -ne 'Disabled')
            Hinweis = ''
            Quelle  = $_.TaskPath
        }
    }

    return $items
}

function Set-SysPilotStartupItem {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Enable
    )
    $byte = if ($Enable) { 2 } else { 3 }
    $done = $false

    foreach ($rk in $script:RunKeys) {
        $reg = Get-ItemProperty -Path $rk.Path -ErrorAction SilentlyContinue
        if (-not $reg) { continue }
        if ($reg.PSObject.Properties[$Name]) {
            $approvedPath = $rk.Approved
            if (-not (Test-Path $approvedPath)) { New-Item -Path $approvedPath -Force | Out-Null }
            $current = (Get-ItemProperty -Path $approvedPath -Name $Name -ErrorAction SilentlyContinue).$Name
            $bytes = if ($current -is [byte[]] -and $current.Length -ge 12) { $current } else { New-Object byte[] 12 }
            $bytes[0] = $byte
            Set-ItemProperty -Path $approvedPath -Name $Name -Value $bytes -Type Binary
            $done = $true
        }
    }

    # Autostart-Ordner: verschieben statt loeschen
    $folders = @([Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup'))
    foreach ($f in $folders) {
        $lnk = Join-Path $f "$Name.lnk"
        $disDir = Join-Path $f "_deaktiviert"
        $disLnk = Join-Path $disDir "$Name.lnk"
        if (-not $Enable -and (Test-Path $lnk)) {
            New-Item -ItemType Directory -Force -Path $disDir | Out-Null
            Move-Item $lnk $disLnk -Force
            $done = $true
        }
        elseif ($Enable -and (Test-Path $disLnk)) {
            Move-Item $disLnk $lnk -Force
            $done = $true
        }
    }

    # Aufgaben
    $task = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
    if ($task) {
        if ($Enable) { $task | Enable-ScheduledTask | Out-Null } else { $task | Disable-ScheduledTask | Out-Null }
        $done = $true
    }

    if ($done) {
        $state = if ($Enable) { 'aktiviert' } else { 'deaktiviert' }
        Write-Host "  [OK] '$Name' $state." -ForegroundColor Green
        Write-SysPilotLog "Autostart '$Name' $state"
    } else {
        Write-Host "  [!] '$Name' nicht gefunden." -ForegroundColor Yellow
    }
}

function Show-SysPilotStartupManager {
    while ($true) {
        Write-SysPilotHeader "Autostart-Manager"
        $items = Get-SysPilotStartupItems
        $i = 0
        $list = @()
        foreach ($it in ($items | Sort-Object @{e='Aktiv'; Descending=$true}, Name)) {
            $i++
            $list += $it
            $state = if ($it.Aktiv) { "AN " } else { "aus" }
            $color = if ($it.Aktiv) { "White" } else { "DarkGray" }
            $hint = if ($it.Hinweis) { "  <<< $($it.Hinweis)" } else { "" }
            Write-Host ("  [{0,2}] {1} {2,-38} {3}{4}" -f $i, $state, $it.Name, $it.Typ, $hint) -ForegroundColor $color
        }
        Write-Host ""
        Write-Host "  Befehle: <Nr> = umschalten (an/aus) | 0 = zurueck" -ForegroundColor Yellow
        $c = Read-SysPilotChoice "Nr."
        if ($c -eq '0' -or $c -eq '') { return }
        $n = 0
        if ([int]::TryParse($c, [ref]$n) -and $n -ge 1 -and $n -le $list.Count) {
            $item = $list[$n - 1]
            if ($item.Aktiv) {
                if ($item.Hinweis) {
                    Write-Host "  Hinweis: $($item.Hinweis)" -ForegroundColor Magenta
                }
                Set-SysPilotStartupItem -Name $item.Name -Enable $false
            } else {
                Set-SysPilotStartupItem -Name $item.Name -Enable $true
            }
        }
    }
}

Export-ModuleMember -Function Get-SysPilotStartupItems, Set-SysPilotStartupItem, Show-SysPilotStartupManager
