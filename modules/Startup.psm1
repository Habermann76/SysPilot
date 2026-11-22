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

function Backup-SysPilotStartup {
    <# Sichert alle Autostart-Quellen (Run-Keys, Autostart-Ordner,
       Logon-Aufgaben) als JSON in das SysPilot-Backup-Verzeichnis. #>
    if (-not (Assert-SysPilotAdmin)) { return $null }
    $data = [ordered]@{
        Created   = (Get-Date).ToString('o')
        RunKeys   = @()
        Folders   = @()
        Tasks     = @()
    }
    foreach ($rk in $script:RunKeys) {
        $reg = Get-ItemProperty -Path $rk.Path -ErrorAction SilentlyContinue
        if (-not $reg) { continue }
        $approved = Get-ItemProperty -Path $rk.Approved -ErrorAction SilentlyContinue
        foreach ($prop in $reg.PSObject.Properties) {
            if ($prop.Name -like 'PS*') { continue }
            $enabled = $true
            if ($approved) {
                $bytes = $approved.PSObject.Properties[$prop.Name]
                if ($bytes -and $bytes.Value -is [byte[]] -and $bytes.Value.Length -gt 0) { $enabled = ($bytes.Value[0] -eq 2) }
            }
            $data.RunKeys += [PSCustomObject]@{
                Hive = $rk.Hive; Key = $rk.Path; Approved = $rk.Approved
                Name = $prop.Name; Value = [string]$prop.Value; Enabled = $enabled
            }
        }
    }
    $folders = @([Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup'))
    foreach ($f in $folders) {
        Get-ChildItem $f -Filter '*.lnk' -ErrorAction SilentlyContinue | ForEach-Object {
            $data.Folders += [PSCustomObject]@{ Folder = $f; File = $_.Name; Enabled = $true }
        }
        $disDir = Join-Path $f '_deaktiviert'
        if (Test-Path $disDir) {
            Get-ChildItem $disDir -Filter '*.lnk' -ErrorAction SilentlyContinue | ForEach-Object {
                $data.Folders += [PSCustomObject]@{ Folder = $f; File = "_deaktiviert\$($_.Name)"; Enabled = $false }
            }
        }
    }
    Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $_.TaskPath -notmatch '^\\Microsoft' -and
        ($_.Triggers | Where-Object { $_.CimClass.CimClassName -match 'LogonTrigger' })
    } | ForEach-Object {
        $data.Tasks += [PSCustomObject]@{ Name = $_.TaskName; Path = $_.TaskPath; Enabled = ($_.State -ne 'Disabled') }
    }

    $dir = Get-SysPilotBackupDir
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dest = Join-Path $dir "startup_$stamp.json"
    try {
        $data | ConvertTo-Json -Depth 5 | Set-Content $dest -Encoding UTF8
        Write-Host "  [OK] Autostart-Backup erstellt: $dest" -ForegroundColor Green
        Write-SysPilotLog "Autostart-Backup: $dest"
        return $dest
    } catch {
        Write-Host "  [!] Backup fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

function Restore-SysPilotStartup {
    <# Stellt einen Autostart-Backup-Stand wieder her.
       Setzt Run-Key-Werte und Aktivierungsstatus; Autostart-Ordner
       werden nur gemeldet (Dateien werden nicht verschoben). #>
    param([Parameter(Mandatory)][string]$BackupPath)
    if (-not (Assert-SysPilotAdmin)) { return }
    if (-not (Test-Path $BackupPath)) { Write-Host "  [!] Backup nicht gefunden: $BackupPath" -ForegroundColor Red; return }
    try {
        $data = Get-Content $BackupPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Host "  [!] Backup ungueltig: $($_.Exception.Message)" -ForegroundColor Red
        return
    }
    if (-not (Confirm-SysPilot "Autostart-Stand vom $($data.Created) wiederherstellen?`n(Aktuelle Aenderungen werden ueberschrieben)")) { return }

    $restored = 0; $missing = 0
    foreach ($rk in $data.RunKeys) {
        try {
            if (-not (Test-Path $rk.Key)) { New-Item -Path $rk.Key -Force | Out-Null }
            Set-ItemProperty -Path $rk.Key -Name $rk.Name -Value $rk.Value -Force
            if ($rk.Enabled -eq $false -and $rk.Approved) {
                if (-not (Test-Path $rk.Approved)) { New-Item -Path $rk.Approved -Force | Out-Null }
                $bytes = New-Object byte[] 12; $bytes[0] = 3
                Set-ItemProperty -Path $rk.Approved -Name $rk.Name -Value $bytes -Type Binary
            }
            $restored++
        } catch { $missing++ }
    }
    foreach ($t in $data.Tasks) {
        try {
            $task = Get-ScheduledTask -TaskName $t.Name -TaskPath $t.Path -ErrorAction Stop
            if ($t.Enabled) { $task | Enable-ScheduledTask | Out-Null } else { $task | Disable-ScheduledTask | Out-Null }
            $restored++
        } catch { $missing++ }
    }
    Write-Host "  [OK] $restored Eintraege wiederhergestellt, $missing fehlten/konnten nicht gesetzt werden." -ForegroundColor Green
    Write-Host '  Hinweis: Autostart-Ordner-Verknuepfungen wurden nicht verschoben - bitte manuell pruefen.' -ForegroundColor DarkGray
    Write-SysPilotLog "Autostart-Restore aus $BackupPath ($restored ok, $missing fehlend)"
}

function Show-SysPilotStartupManager {
    while ($true) {
        $items = Get-SysPilotStartupItems
        $menuItems = @(
            @{ Label = '>>> Autostart-Backup erstellen'; Color = 'Green'; Tag = 'BACKUP' },
            @{ Label = '>>> Autostart-Backup wiederherstellen'; Color = 'Green'; Tag = 'RESTORE' }
        )
        foreach ($it in ($items | Sort-Object @{e='Aktiv'; Descending=$true}, Name)) {
            $state = if ($it.Aktiv) { "[AN ]" } else { "[aus]" }
            $hint = if ($it.Hinweis) { "  <<< $($it.Hinweis)" } else { "" }
            $color = if ($it.Aktiv) { "White" } else { "DarkGray" }
            $menuItems += @{ Label = ("{0} {1,-38} {2}{3}" -f $state, $it.Name, $it.Typ, $hint); Color = $color; Tag = $it }
        }
        $menuItems += @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = $null }

        $sel = Show-SysPilotArrowMenu -Items $menuItems -Title 'Autostart-Manager' -Footer 'Pfeiltasten, Enter = an/aus schalten, Esc = zurueck'
        if ($null -eq $sel) { return }

        $item = $sel
        if ($sel -eq 'BACKUP') { [void](Backup-SysPilotStartup); Start-Sleep -Milliseconds 800; continue }
        if ($sel -eq 'RESTORE') {
            $dir = Get-SysPilotBackupDir
            $latest = Get-ChildItem $dir -Filter 'startup_*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if (-not $latest) { Write-Host '  Kein Autostart-Backup vorhanden.' -ForegroundColor Yellow; Read-SysPilotChoice 'Weiter' | Out-Null; continue }
            Write-Host "  Letztes Backup: $($latest.FullName)" -ForegroundColor Cyan
            Restore-SysPilotStartup -BackupPath $latest.FullName
            Start-Sleep -Milliseconds 800; continue
        }
        if ($item.Aktiv) {
            if ($item.Hinweis) {
                Write-Host "  Hinweis: $($item.Hinweis)" -ForegroundColor Magenta
            }
            Set-SysPilotStartupItem -Name $item.Name -Enable $false
        } else {
            Set-SysPilotStartupItem -Name $item.Name -Enable $true
        }
        Start-Sleep -Milliseconds 800
    }
}

Export-ModuleMember -Function Get-SysPilotStartupItems, Set-SysPilotStartupItem, Backup-SysPilotStartup, Restore-SysPilotStartup, Show-SysPilotStartupManager
