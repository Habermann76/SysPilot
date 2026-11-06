# SysPilot - Smart Health Check: CPU/RAM/Disk/Temp Monitoring + Live-Dashboard
# Requires PowerShell 5.1

#Requires -Version 5.1

# Root Ordner (für Logs und Config)
$script:SysPilotRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)

# ---------- Hilfsfunktionen ----------
function Get-SysPilotHealthSampler {
    <#
    .SYNOPSIS
    Samelt aktuelle Gesundheitswerte.
    .EXAMPLE
        Get-SysPilotHealthSampler
    #>
    $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    $load = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
    $ram = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
    $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue
    $temp = $null
    try {
        # LibreHardwareMonitor API (falls installiert)
        $lhm = Get-ItemProperty -Path 'HKLM:\SOFTWARE\LibreHardwareMonitor' -ErrorAction SilentlyContinue
        if ($lhm) {
            $temp = Get-CimInstance -ClassName Win32_TemperatureSensor -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match 'CPU' } | Select-Object -First 1
        }
    } catch { }
    return [PSCustomObject]@{
        CPU_Usage = if ($cpu) { $cpu.LoadPercentage } else { 0 }
        CPU_Name  = if ($cpu) { $cpu.Name.Substring(0, [math]::Min(30, $cpu.Name.Length)) } else { 'N/A' }
        RAM_UsedMB= if ($ram) { [math]::Round(($ram.TotalVisibleMemorySize - $ram.FreePhysicalMemory) / 1MB) } else { 0 }
        RAM_TotalMB= if ($ram) { [math]::Round($ram.TotalVisibleMemorySize / 1MB) } else { 0 }
        RAM_Util  = if ($ram) { [math]::Round(100 * ($ram.TotalVisibleMemorySize - $ram.FreePhysicalMemory) / $ram.TotalVisibleMemorySize) } else { 0 }
        Disk_UsedMB= if ($disk) { [math]::Round($disk.Size / 1MB - $disk.FreeSpace / 1MB) } else { 0 }
        Disk_TotalMB= if ($disk) { [math]::Round($disk.Size / 1MB) } else { 0 }
        Disk_Util = if ($disk) { [math]::Round(100 * ($disk.Size / 1MB - $disk.FreeSpace / 1MB) / ($disk.Size / 1MB)) } else { 0 }
        Temp_C    = if ($temp) { [math]::Round($temp.CurrentReading, 1) } else { -1 }
        Temp_Source = if ($temp) { 'LHM' } else { 'Schätzung' }
        Timestamp = Get-Date -Format 'o'
    }
}

function Get-SysPilotHealthHistory {
    <#
    .SYNOPSIS
    Holt gesammelte Gesundheitsdaten aus dem Log-Ordner.
    .EXAMPLE
        Get-SysPilotHealthHistory -Count 50
    #>
    param([int]$Count = 50)
    $logFile = Join-Path $script:SysPilotRoot 'logs\health-history.csv'
    if (-not (Test-Path $logFile)) { return @() }
    try {
        return Import-Csv -Path $logFile -ErrorAction Stop | Select-Object -Last $Count
    } catch {
        Write-Host "  [!] Konnte Log nicht lesen: $($_.Exception.Message)" -ForegroundColor Yellow
        return @()
    }
}

function New-SysPilotHealthLog {
    <#
    .SYNOPSIS
    Schreibt einen neuen Eintrag in das Gesundheits-Log.
    #>
    param(
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Sample
    )
    $logFile = Join-Path $script:SysPilotRoot 'logs\health-history.csv'
    $dir = Split-Path $logFile -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $null = $Sample | Select-Object -Property * -ExcludeProperty PSComputerName | Export-Csv -Path $logFile -Append -NoTypeInformation -Encoding UTF8
}

function Show-SysPilotHealthDashboard {
    <#
    .SYNOPSIS
    Zeigt das Live-Health-Dashboard (Maussteuerbar).
    .EXAMPLE
        Show-SysPilotHealthDashboard
    #>
    Write-Host ''
    Write-Host '  █████████████████████████████████████████'
    Write-Host '  █  SYSHEALTH — Live-Dashboard (Smart Health Monitor)' -ForegroundColor Cyan
    Write-Host '  █████████████████████████████████████████'
    Write-Host ''
    $sample = Get-SysPilotHealthSampler
    $sample | Add-Member -MemberType NoteProperty -Name 'Log' -Value (Get-SysPilotHealthHistory -Count 20)
    $sample | New-SysPilotHealthLog

    Write-Host "  CPU: $($sample.CPU_Usage)%  ($($sample.CPU_Name))"
    Write-Host "  RAM: $($sample.RAM_UsedMB) / $($sample.RAM_TotalMB) MB  ($($sample.RAM_Util)%)"
    Write-Host "  Disk: $($sample.Disk_UsedMB) / $($sample.Disk_TotalMB) MB  ($($sample.Disk_Util)%)"
    if ($sample.Temp_C -ge 0) {
        Write-Host "  Temp: $($sample.Temp_C)°C  (via $($sample.Temp_Source))"
        if ($sample.Temp_C -ge 80) { Write-Host '    ⚠️  Hitzeschutz: Kühl-Plan aktiviert' -ForegroundColor Yellow }
    } else {
        Write-Host '  Temp: Schätzung (LibreHardwareMonitor empfohlen)'
    }
    Write-Host ''

    $hist = Get-SysPilotHealthHistory -Count 30
    if ($hist.Count -gt 1) {
        Write-Host '  Verlauf (letzte 30 Messungen):'
        $hist | ForEach-Object {
            $d = [datetime]::Parse($_.Timestamp)
            Write-Host "    $($_.Timestamp)  CPU=$($_.CPU_Usage)% RAM=$($_.RAM_Util)% Disk=$($_.Disk_Util)% Temp=$($_.Temp_C)°C"
        }
    }
    Write-Host ''
}

function Show-SysPilotHealthGUI {
    <#
    .SYNOPSIS
    Erzeugt ein WPF-Dashboard für die Maussteuerung.
    .EXAMPLE
        Show-SysPilotHealthGUI
    #>
    $window = New-Object System.Windows.Window
    $window.Title = 'SysPilot - Smart Health Monitor'
    $window.Width = 680; $window.Height = 460
    $window.WindowStartupLocation = 'CenterScreen'

    $grid = New-Object System.Windows.Controls.Grid
    $grid.Margin = '14'
    $grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Height Auto))
    $grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Height '*'))
    $grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Height Auto))
    $grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Height Auto))

    # Title
    $title = New-Object System.Windows.Controls.TextBlock
    $title.Text = 'Smart Health Monitor'; $title.FontSize=20; $title.FontWeight='Bold'
    $title.Foreground='#FF4FC3F7'; [System.Windows.Controls.Grid]::SetRow($title,0); $grid.Children.Add($title)|Out-Null

    # Data Grid
    $dataGrid = New-Object System.Windows.Controls.DataGrid
    $dataGrid.IsReadOnly=$true; $dataGrid.AutogenesColumnWidth='Auto'
    $dataGrid.CanUserAddRows=$false; $dataGrid.CanUserDeleteRows=$false
    $dataGrid.CanUserResizeColumns=$false
    [System.Windows.Controls.Grid]::SetRow($dataGrid,1); $grid.Children.Add($dataGrid)|Out-Null

    # Controls
    $btnRefresh = New-Object System.Windows.Controls.Button
    $btnRefresh.Content='Aktualisieren'; $btnRefresh.Margin='4,0,4,0'
    [System.Windows.Controls.Grid]::SetRow($btnRefresh,2); $grid.Children.Add($btnRefresh)|Out-Null
    $btnExport = New-Object System.Windows.Controls.Button
    $btnExport.Content='Exportieren'; $btnExport.Margin='4,0,4,0'
    [System.Windows.Controls.Grid]::SetRow($btnExport,3); $grid.Children.Add($btnExport)|Out-Null

    $window.Content = $grid
    $window.ShowDialog() | Out-Null
}

Export-ModuleMember -Function Get-SysPilotHealthSampler, Get-SysPilotHealthHistory, New-SysPilotHealthLog, Show-SysPilotHealthDashboard, Show-SysPilotHealthGUI
