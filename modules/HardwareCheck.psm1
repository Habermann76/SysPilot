# SysPilot - Hardware-Check (PC-Analyse / Hardware-Diagnose)
#Requires -Version 5.1
# Eigenstaendige Bezeichnung: "SysPilot PC-Analyse" - KEIN Speccy-Klon.
# Alle Werte ehrlich: was nicht messbar ist, wird als "nicht verfuegbar" angezeigt.

function Get-SysPilotHardwareCpu {
    <# CPU-Infos: Name, Kerne, Threads, Takt, Last. #>
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    if (-not $cpu) { return $null }
    [PSCustomObject]@{
        Name      = $cpu.Name.Trim()
        Cores     = $cpu.NumberOfCores
        Logical   = $cpu.NumberOfLogicalProcessors
        MaxMhz    = [math]::Round($cpu.MaxClockSpeed / 1000)
        LoadPct   = $cpu.LoadPercentage
    }
}

function Get-SysPilotHardwareRam {
    <# RAM-Infos: Gesamt, Belegung. #>
    $os = Get-CimInstance Win32_OperatingSystem
    $totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB)
    $freeGB  = [math]::Round($os.FreePhysicalMemory / 1MB)
    $usedPct = [math]::Round(100 * ($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize)
    [PSCustomObject]@{
        TotalGB     = $totalGB
        FreeGB      = $freeGB
        UsedPct     = $usedPct
    }
}

function Get-SysPilotHardwareGpu {
    <# GPU-Infos: Name, VRAM, Treiber. #>
    $gpuList = Get-CimInstance Win32_VideoController
    $gpus = @()
    foreach ($g in $gpuList) {
        $gpus += [PSCustomObject]@{
            Name         = $g.Name
            VRAMGB       = if ($g.AdapterRAM) { [math]::Round($g.AdapterRAM / 1GB) } else { 0 }
            DriverVersion = $g.DriverVersion
        }
    }
    if ($gpus.Count -eq 0) { $gpus = @([PSCustomObject]@{ Name = 'Keine GPU erkannt'; VRAMGB = 0; DriverVersion = '' }) }
    $gpus
}

function Get-SysPilotHardwareMainboard {
    <# Mainboard/BIOS-Infos: Hersteller, Modell, BIOS-Version. #>
    $mainboard = $null
    $bios = $null
    try { $mainboard = Get-CimInstance Win32_BaseBoard -ErrorAction Stop } catch { }
    try { $bios = Get-CimInstance Win32_BIOS -ErrorAction Stop } catch { }
    [PSCustomObject]@{
        MainboardManufacturer = if ($mainboard) { $mainboard.Manufacturer } else { 'Nicht ermittelt' }
        MainboardProduct      = if ($mainboard) { $mainboard.Product } else { 'Nicht ermittelt' }
        BiosVendor            = if ($bios) { $bios.Manufacturer } else { 'Nicht ermittelt' }
        BiosVersion           = if ($bios) { $bios.SMBIOSBIOSVersion } else { 'Nicht ermittelt' }
    }
}

function Get-SysPilotHardwareDrives {
    <# Laufwerk-Infos: Groesse, Freiraum, Health (falls verfuegbar). #>
    $drives = @()
    $disks = @()
    try { $disks = @(Get-PhysicalDisk -ErrorAction Stop) } catch { }
    try {
        $logical = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop
    } catch {
        $logical = Get-PSDrive -PSProvider FileSystem | ForEach-Object {
            [PSCustomObject]@{ DeviceID = "$($_.Name):"; Size = $_.Size; FreeSpace = $_.Free }
        }
    }
    foreach ($d in @($logical | Sort-Object DeviceID)) {
        $sizeGB  = if ($d.Size)      { [math]::Round($d.Size / 1GB, 1) }      else { 0 }
        $freeGB  = if ($d.FreeSpace) { [math]::Round($d.FreeSpace / 1GB, 1) } else { 0 }
        $usedPct = if ($d.Size -gt 0) { [math]::Round(100 * ($d.Size - $d.FreeSpace) / $d.Size) } else { 0 }
        $drives += [PSCustomObject]@{
            Name    = $d.DeviceID.TrimEnd(':')
            SizeGB  = $sizeGB
            FreeGB  = $freeGB
            UsedPct = $usedPct
            Health  = $(if ($disks.Count -gt 0) { ($disks | ForEach-Object { $_.HealthStatus } | Select-Object -Unique) -join '/' } else { 'n/a' })
        }
    }
    $drives
}

function Get-SysPilotHardwareNetwork {
    <# Netzwerkadapter + IPs. #>
    $adapters = @()
    # Bevorzugt Get-NetAdapter (Status 'Up'), Fallback Win32_NetworkAdapter
    try {
        $netAdapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notlike '*Loopback*' })
        foreach ($na in $netAdapters) {
            $ips = @()
            try {
                $ips = @(Get-NetIPAddress -InterfaceIndex $na.ifIndex -AddressFamily IPv4 -ErrorAction Stop | ForEach-Object { $_.IPAddress })
            } catch { }
            $adapters += [PSCustomObject]@{
                Name        = "$($na.Name) ($($na.InterfaceDescription))"
                IPAddresses = ($ips -join ', ')
            }
        }
        if ($adapters.Count -gt 0) { return $adapters }
    } catch { }
    $nicList = @(Get-CimInstance Win32_NetworkAdapter -ErrorAction SilentlyContinue |
        Where-Object { $_.NetConnectionStatus -eq 2 -and $_.PhysicalAdapter -eq $true })
    foreach ($nic in $nicList) {
        $ipConfig = Get-CimInstance Win32_NetworkAdapterConfiguration -ErrorAction SilentlyContinue |
            Where-Object { $_.Index -eq $nic.DeviceID } | Select-Object -First 1
        $ipAddrs = @()
        if ($ipConfig) { $ipAddrs = @($ipConfig.IPAddress) | Where-Object { "$_" -match '^\d+\.' } }
        $adapters += [PSCustomObject]@{
            Name        = $nic.Name
            IPAddresses = ($ipAddrs -join ', ')
        }
    }
    $adapters
}

function Get-SysPilotHardwareWindows {
    <# Windows-Version/Build/Laufzeit. #>
    $os = Get-CimInstance Win32_OperatingSystem
    $boot = $os.LastBootUpTime
    if ($boot -is [string]) { $boot = [Management.ManagementDateTimeConverter]::ToDateTime($boot) }
    $upt = (Get-Date) - $boot
    [PSCustomObject]@{
        Caption      = $os.Caption
        Version      = $os.Version
        BuildNumber  = $os.BuildNumber
        Architecture = $os.OSArchitecture
        ProcessCount = @(Get-Process).Count
        UpTime       = ("{0}T {1}Std {2}Min" -f $upt.Days, $upt.Hours, $upt.Minutes)
        BootTime     = $boot.ToString('dd.MM.yyyy HH:mm')
    }
}

function Get-SysPilotHardwareTemperature {
    <# CPU-Temperatur (echt via LibreHardwareMonitor oder geschaetzt). #>
    if (Get-Command Get-SysPilotCpuTemperature -ErrorAction SilentlyContinue) {
        $t = Get-SysPilotCpuTemperature
        return [PSCustomObject]@{
            Celsius    = $t.Celsius
            Quelle     = $t.Quelle
            Geschaetzt = [bool]$t.Geschaetzt
        }
    }
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $load = if ($cpu) { [double]$cpu.LoadPercentage } else { 0 }
    $est = 40 + ($load * 0.35)
    [PSCustomObject]@{
        Celsius    = [math]::Round($est)
        Quelle     = 'geschaetzt (Last)'
        Geschaetzt = $true
    }
}

function Show-SysPilotHardwareReport {
    <# Uebersicht der Hardware-Diagnose. #>
    Write-Host ''
    Write-Host '========================================' -ForegroundColor DarkCyan
    Write-Host '  SysPilot PC-Analyse (Hardware-Diagnose)' -ForegroundColor Cyan
    Write-Host '========================================' -ForegroundColor DarkCyan
    Write-Host ''

    $cpu = Get-SysPilotHardwareCpu
    if ($cpu) {
        Write-Host '--- CPU ---' -ForegroundColor Yellow
        Write-Host "Name:         $($cpu.Name)" -ForegroundColor White
        Write-Host "Kerne/Threads: $($cpu.Cores) Kerne / $($cpu.Logical) Threads" -ForegroundColor White
        Write-Host "Max-Takt:     $($cpu.MaxMhz) GHz" -ForegroundColor White
        Write-Host "Last:         $($cpu.LoadPct)%" -ForegroundColor White
    }

    $ram = Get-SysPilotHardwareRam
    Write-Host ''
    Write-Host '--- RAM ---' -ForegroundColor Yellow
    Write-Host "Gesamt:       $($ram.TotalGB) GB" -ForegroundColor White
    Write-Host "Belegt:       $($ram.UsedPct)%" -ForegroundColor White
    Write-Host "Frei:         $($ram.FreeGB) GB" -ForegroundColor White

    $gpus = @(Get-SysPilotHardwareGpu)
    Write-Host ''
    Write-Host '--- GPU ---' -ForegroundColor Yellow
    foreach ($g in $gpus) {
        Write-Host "  $($g.Name)" -ForegroundColor White
        if ($g.VRAMGB) { Write-Host "    VRAM: $($g.VRAMGB) GB" -ForegroundColor White }
        if ($g.DriverVersion) { Write-Host "    Treiber: $($g.DriverVersion)" -ForegroundColor White }
    }

    $mb = Get-SysPilotHardwareMainboard
    Write-Host ''
    Write-Host '--- Mainboard/BIOS ---' -ForegroundColor Yellow
    Write-Host "Hersteller:   $($mb.MainboardManufacturer)" -ForegroundColor White
    Write-Host "Modell:       $($mb.MainboardProduct)" -ForegroundColor White
    Write-Host "BIOS:         $($mb.BiosVersion)" -ForegroundColor White

    $drives = @(Get-SysPilotHardwareDrives)
    Write-Host ''
    Write-Host '--- Laufwerke ---' -ForegroundColor Yellow
    foreach ($dr in $drives) {
        Write-Host ("  {0}: {1} GB gesamt, {2} GB frei ({3}% belegt)  Health: {4}" -f $dr.Name, $dr.SizeGB, $dr.FreeGB, $dr.UsedPct, $dr.Health) -ForegroundColor White
    }

    $net = @(Get-SysPilotHardwareNetwork)
    Write-Host ''
    Write-Host '--- Netzwerk ---' -ForegroundColor Yellow
    if ($net.Count -eq 0) { Write-Host '  Keine aktiven Adapter' -ForegroundColor DarkGray }
    foreach ($ad in $net) {
        Write-Host "  $($ad.Name): $($ad.IPAddresses)" -ForegroundColor White
    }

    $win = Get-SysPilotHardwareWindows
    Write-Host ''
    Write-Host '--- Windows ---' -ForegroundColor Yellow
    Write-Host "  $($win.Caption) (Build $($win.BuildNumber))" -ForegroundColor White
    Write-Host "  Laufzeit seit Start: $($win.UpTime) (Boot $($win.BootTime))" -ForegroundColor White
    Write-Host "  Prozesse: $($win.ProcessCount)" -ForegroundColor White

    $temp = Get-SysPilotHardwareTemperature
    Write-Host ''
    Write-Host '--- Temperatur ---' -ForegroundColor Cyan
    $tempColor = if ($temp.Geschaetzt) { 'Yellow' } elseif ($temp.Celsius -ge 85) { 'Red' } elseif ($temp.Celsius -ge 75) { 'Yellow' } else { 'Green' }
    Write-Host "  CPU-Temperatur: $($temp.Celsius) C ($($temp.Quelle))" -ForegroundColor $tempColor

    Write-Host ''
}

function Show-SysPilotHardwareMenu {
    <# Pfeiltasten-Menue: Hardware-Report + Einzelansichten + zurueck. #>
    $items = @(
        @{ Label = 'Hardware-Report generieren';  Color = 'Green';    Tag = 'report' }
        @{ Label = 'CPU-Details';                 Color = 'White';    Tag = 'cpu' }
        @{ Label = 'RAM-Details';                 Color = 'White';    Tag = 'ram' }
        @{ Label = 'GPU-Details';                 Color = 'White';    Tag = 'gpu' }
        @{ Label = 'Mainboard/BIOS';              Color = 'White';    Tag = 'mainboard' }
        @{ Label = 'Laufwerke (Groesse/Health)';  Color = 'White';    Tag = 'drives' }
        @{ Label = 'Netzwerk-Adapter';            Color = 'White';    Tag = 'network' }
        @{ Label = 'Windows-Infos';               Color = 'White';    Tag = 'windows' }
        @{ Label = 'Temperatur';                  Color = 'White';    Tag = 'temp' }
        @{ Label = 'Zurueck';                     Color = 'DarkGray'; Tag = $null }
    )

    while ($true) {
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'SysPilot PC-Analyse' -Footer 'Pfeiltasten, Enter = ausfuehren, Esc = zurueck'
        if ($null -eq $sel) { return }

        switch ($sel) {
            'report' {
                Show-SysPilotHardwareReport
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'cpu' {
                $c = Get-SysPilotHardwareCpu
                if ($c) { Write-Host "CPU: $($c.Name) - $($c.MaxMhz) GHz, $($c.Cores) Kerne, $($c.LoadPct)% Last" -ForegroundColor White }
                else { Write-Host 'CPU: nicht ermittelt' -ForegroundColor DarkGray }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'ram' {
                $r = Get-SysPilotHardwareRam
                Write-Host "RAM: $($r.TotalGB) GB gesamt, $($r.UsedPct)% belegt, $($r.FreeGB) GB frei" -ForegroundColor White
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'gpu' {
                foreach ($g in @(Get-SysPilotHardwareGpu)) {
                    $vram = if ($g.VRAMGB) { "$($g.VRAMGB) GB" } else { 'n/a' }
                    Write-Host "GPU: $($g.Name) - VRAM $vram, Treiber $($g.DriverVersion)" -ForegroundColor White
                }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'mainboard' {
                $m = Get-SysPilotHardwareMainboard
                Write-Host "Mainboard: $($m.MainboardProduct) von $($m.MainboardManufacturer)" -ForegroundColor White
                Write-Host "BIOS: $($m.BiosVersion) ($($m.BiosVendor))" -ForegroundColor White
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'drives' {
                foreach ($dr in @(Get-SysPilotHardwareDrives)) {
                    Write-Host ("Laufwerk {0}: {1} GB, {2} GB frei ({3}%) - Health: {4}" -f $dr.Name, $dr.SizeGB, $dr.FreeGB, $dr.UsedPct, $dr.Health) -ForegroundColor White
                }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'network' {
                $net = @(Get-SysPilotHardwareNetwork)
                if ($net.Count -eq 0) { Write-Host 'Keine aktiven Netzwerkadapter' -ForegroundColor DarkGray }
                foreach ($ad in $net) { Write-Host "Adapter $($ad.Name): $($ad.IPAddresses)" -ForegroundColor White }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'windows' {
                $w = Get-SysPilotHardwareWindows
                Write-Host "Windows: $($w.Caption) Build $($w.BuildNumber)" -ForegroundColor White
                Write-Host "Architektur: $($w.Architecture), Boot: $($w.BootTime), Laufzeit: $($w.UpTime)" -ForegroundColor White
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'temp' {
                $t = Get-SysPilotHardwareTemperature
                Write-Host "Temperatur: $($t.Celsius) C - $($t.Quelle)" -ForegroundColor $(if ($t.Geschaetzt) { 'Yellow' } else { 'White' })
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
        }
    }
}

Export-ModuleMember -Function Get-SysPilotHardwareCpu, Get-SysPilotHardwareRam, Get-SysPilotHardwareGpu, Get-SysPilotHardwareMainboard, Get-SysPilotHardwareDrives, Get-SysPilotHardwareNetwork, Get-SysPilotHardwareWindows, Get-SysPilotHardwareTemperature, Show-SysPilotHardwareReport, Show-SysPilotHardwareMenu
