# SysPilot GUI - schlanke WPF-Oberflaeche (kein Electron, ~40-60 MB RAM)
#Requires -Version 5.1
param([switch]$AsAdmin, [switch]$StartHidden)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
# DPI-aware: scharfe Darstellung und korrektes Layout bei 125%/150% Bildschirmskalierung
Add-Type '[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();' -Name DpiAware -Namespace SysPilotGui
[SysPilotGui.DpiAware]::SetProcessDPIAware() | Out-Null
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Eigenes Konsolen-Fenster verstecken (kein zusaetzliches PowerShell-Fenster neben der GUI)
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class SysPilotWin {
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern int GetClassName(IntPtr hWnd, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    public static IntPtr FindGuiWindow() {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            if (!IsWindowVisible(h)) return true;
            var t = new StringBuilder(256); GetWindowText(h, t, 256);
            if (t.ToString() != "SysPilot") return true;
            var c = new StringBuilder(256); GetClassName(h, c, 256);
            if (c.ToString().StartsWith("HwndWrapper")) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
'@
$con = [SysPilotWin]::GetConsoleWindow()
if ($con -ne [IntPtr]::Zero) { [SysPilotWin]::ShowWindow($con, 0) | Out-Null }  # SW_HIDE

# Nur EINE GUI-Instanz: laeuft sie schon, vorhandenes Fenster nach vorne holen und beenden
$script:guiMutex = New-Object System.Threading.Mutex($true, 'Local\SysPilotGUI-SingleInstance')
if (-not $script:guiMutex.WaitOne(0)) {
    # Laeuft schon (evtl. nur im Tray): die laufende Instanz bitten, ihr Fenster zu zeigen.
    # (Nicht bei -StartHidden, z.B. Autostart/Guardian - dann soll nichts aufpoppen.)
    # SPIELE-SCHUTZ: Auch wenn ein Spiel laeuft, Fenster niemals in den Vordergrund draengen!
    $isGamingNow = $false
    try {
        $rootCheck = Split-Path -Parent $MyInvocation.MyCommand.Path
        if (-not $rootCheck) { $rootCheck = $PSScriptRoot }
        $cmod = Join-Path $rootCheck 'modules\Common.psm1'
        if (Test-Path $cmod) { Import-Module $cmod -Force -WarningAction SilentlyContinue }
        if (Get-Command Test-SysPilotGamingActive -ErrorAction SilentlyContinue) { $isGamingNow = Test-SysPilotGamingActive }
    } catch { }

    if (-not $StartHidden -and -not $isGamingNow) {
        try { $evt = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', 'Local\SysPilotGUI-Show'); $evt.Set() | Out-Null } catch { }
        $existing = [SysPilotWin]::FindGuiWindow()
        if ($existing -ne [IntPtr]::Zero) {
            [SysPilotWin]::ShowWindow($existing, 9) | Out-Null   # SW_RESTORE
            [SysPilotWin]::SetForegroundWindow($existing) | Out-Null
        }
    }
    exit
}

try { $script:showEvt = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', 'Local\SysPilotGUI-Show') } catch { $script:showEvt = $null }

$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $script:Root) { $script:Root = $PSScriptRoot }
if (-not $script:Root) { $script:Root = Split-Path -Parent $PSCommandPath }
if (-not $script:Root) { $script:Root = (Get-Location).Path }
Get-ChildItem (Join-Path $script:Root 'modules') -Filter '*.psm1' | ForEach-Object {
    Import-Module $_.FullName -Force -Global -WarningAction SilentlyContinue
}

# Option "Immer als Administrator": ohne Rueckfrage erhoeht neu starten
$startCfg = (Get-SysPilotConfig).Start
if (-not (Test-SysPilotAdmin) -and $startCfg -and $startCfg.AlwaysAdmin) {
    Restart-SysPilotElevated
}

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="SysPilot" Width="760" Height="640" MinWidth="700" MinHeight="600"
        Background="#FF1E1E2E" Foreground="#FFE0E0E0"
        WindowStartupLocation="CenterScreen" ResizeMode="CanResizeWithGrip">
  <Window.Resources>
    <Style TargetType="TextBlock"><Setter Property="FontFamily" Value="Segoe UI"/><Setter Property="FontSize" Value="13"/></Style>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#FF2D2D44"/><Setter Property="Foreground" Value="#FFE0E0E0"/>
      <Setter Property="BorderBrush" Value="#FF4A4A6A"/><Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="10,6"/><Setter Property="Margin" Value="3"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Template">
        <Setter.Value><ControlTemplate TargetType="Button">
          <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="6" Padding="{TemplateBinding Padding}">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#FF3D3D5C"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate></Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ProgressBar">
      <Setter Property="Height" Value="18"/><Setter Property="Minimum" Value="0"/><Setter Property="Maximum" Value="100"/>
      <Setter Property="Background" Value="#FF2D2D44"/><Setter Property="Foreground" Value="#FF4FC3F7"/>
      <Setter Property="BorderThickness" Value="0"/>
    </Style>
  </Window.Resources>

  <Grid Margin="14">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- Kopf -->
    <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,10">
      <TextBlock Text="SysPilot" FontSize="24" FontWeight="Bold" Foreground="#FF4FC3F7" VerticalAlignment="Center"/>
      <TextBlock x:Name="VersionBadge" Text="" FontSize="11" Foreground="#FF9E9E9E" VerticalAlignment="Bottom" Margin="6,0,0,5"/>
      <TextBlock x:Name="AdminBadge" Text="" FontSize="11" Foreground="#FF81C784" VerticalAlignment="Center" Margin="12,0,0,0"/>
      <TextBlock x:Name="PlanBadge" Text="" FontSize="11" Foreground="#FFFFB74D" VerticalAlignment="Center" Margin="12,0,0,0"/>
      <TextBlock x:Name="WatchBadge" Text="  PC wird ueberwacht" FontSize="11" Foreground="#FF81C784" VerticalAlignment="Center" Margin="12,0,0,0"/>
      <Button x:Name="BtnUpdate" Content="Updates" FontSize="11" Padding="8,2" Margin="12,0,0,0" VerticalAlignment="Center"
              ToolTip="Nach einer neuen SysPilot-Version suchen"/>
      <Button x:Name="BtnAdmin" Content="Als Admin starten" FontSize="11" Padding="8,2" Margin="12,0,0,0" VerticalAlignment="Center"
              ToolTip="Startet die GUI mit Administrator-Rechten neu (noetig fuer Plaene, Dienste, einige Fixes)"/>
    </StackPanel>

    <!-- Temperatur gross -->
    <Border Grid.Row="1" Background="#FF252538" CornerRadius="8" Padding="14" Margin="0,0,0,10">
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
        <TextBlock Text="CPU" FontSize="16" Foreground="#FF9E9E9E" VerticalAlignment="Center" Margin="0,0,14,0"/>
        <TextBlock x:Name="TempBig" Text="--" FontSize="44" FontWeight="Bold" Foreground="#FF81C784" VerticalAlignment="Center"/>
        <TextBlock x:Name="TempUnitLabel" Text="°C" FontSize="22" Foreground="#FF9E9E9E" VerticalAlignment="Center" Margin="4,0,14,0"/>
        <TextBlock x:Name="TempStatus" Text="" FontSize="14" FontWeight="Bold" Foreground="#FF81C784" VerticalAlignment="Center"/>
        <TextBlock x:Name="TempSource" Text="" FontSize="10" Foreground="#FF666677" VerticalAlignment="Bottom" Margin="10,0,0,2"/>
      </StackPanel>
    </Border>

    <!-- Live-Metriken -->
    <Border Grid.Row="2" Background="#FF252538" CornerRadius="8" Padding="12" Margin="0,0,0,10">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0" Margin="0,0,10,0">
          <StackPanel Orientation="Horizontal"><TextBlock Text="CPU " FontWeight="Bold"/><TextBlock x:Name="CpuText" Text="0%"/><TextBlock x:Name="CpuSpeed" Text="" Foreground="#FF9E9E9E" Margin="8,0,0,0"/></StackPanel>
          <ProgressBar x:Name="CpuBar" Value="0" Margin="0,4,0,8"/>
          <StackPanel Orientation="Horizontal"><TextBlock Text="RAM " FontWeight="Bold"/><TextBlock x:Name="RamText" Text="0%"/><TextBlock x:Name="RamDetail" Text="" Foreground="#FF9E9E9E" Margin="8,0,0,0"/></StackPanel>
          <ProgressBar x:Name="RamBar" Value="0" Foreground="#FFBA68C8" Margin="0,4,0,8"/>
          <StackPanel Orientation="Horizontal"><TextBlock Text="Disk C: " FontWeight="Bold"/><TextBlock x:Name="DiskText" Text="0%"/><TextBlock x:Name="DiskDetail" Text="" Foreground="#FF9E9E9E" Margin="8,0,0,0"/></StackPanel>
          <ProgressBar x:Name="DiskBar" Value="0" Foreground="#FF81C784" Margin="0,4,0,0"/>
        </StackPanel>
        <StackPanel Grid.Column="1" Margin="10,0,0,0">
          <TextBlock Text="System" FontWeight="Bold" Margin="0,0,0,6"/>
          <TextBlock x:Name="SysCpu" Text="CPU: ..." Foreground="#FFB0B0C0" Margin="0,2"/>
          <TextBlock x:Name="SysProcs" Text="Prozesse: ..." Foreground="#FFB0B0C0" Margin="0,2"/>
          <TextBlock x:Name="SysBattery" Text="" Foreground="#FFB0B0C0" Margin="0,2"/>
          <TextBlock x:Name="SysUptime" Text="" Foreground="#FFB0B0C0" Margin="0,2"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- Top-Fresser -->
    <Border Grid.Row="3" Background="#FF252538" CornerRadius="8" Padding="12">
      <Grid>
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="Top Ressourcen-Fresser" FontWeight="Bold" Margin="0,0,0,6"/>
        <ListView x:Name="HogList" Grid.Row="1" Background="Transparent" BorderThickness="0" Foreground="#FFE0E0E0">
          <ListView.View>
            <GridView>
              <GridViewColumn Header="Programm" Width="200"><GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Programm}" Foreground="#FFE0E0E0"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
              <GridViewColumn Header="RAM MB" Width="90"><GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding RAM_MB}" Foreground="#FFBA68C8"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
              <GridViewColumn Header="CPU s" Width="80"><GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding CPU_s}" Foreground="#FF4FC3F7"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
              <GridViewColumn Header="x" Width="40"><GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Instanzen}" Foreground="#FF9E9E9E"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
              <GridViewColumn Header="Massnahme" Width="280"><GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Massnahme}" Foreground="#FF81C784" TextWrapping="Wrap" ToolTip="{Binding HowTo}"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
            </GridView>
          </ListView.View>
        </ListView>
      </Grid>
    </Border>

    <!-- Aktionen -->
    <Border Grid.Row="4" Background="#FF252538" CornerRadius="8" Padding="8" Margin="0,10,0,0">
      <WrapPanel HorizontalAlignment="Center">
        <Button x:Name="BtnCheckup" Content="CHECKUP" FontWeight="Bold" ToolTip="Automatic Checkup: Komplett-Scan mit Erklaerungen und Reparatur"/>
        <Button x:Name="BtnToolbox" Content="Toolbox" ToolTip="Alle Werkzeuge nach Kategorien"/>
        <Button x:Name="BtnDns" Content="DNS" ToolTip="DNS je Adapter pruefen, testen, sichern und sicher aendern"/>
        <Button x:Name="BtnHealth" Content="Health" ToolTip="Smart Health Monitor: CPU, RAM, Disk, Temperatur"/>
        <Button x:Name="BtnAISearch" Content="KI-Suche" ToolTip="HowTo und Tipps im Browser suchen"/>
        <Button x:Name="BtnAuto" Content="Vollautomatik" FontWeight="Bold" ToolTip="Auto-Optimierung: Backup, Dienste, Features, Tweaks, Prioritaeten - alles in einem Rutsch (Admin)"/>
        <Button x:Name="BtnCool" Content="Kuehl"/>
        <Button x:Name="BtnPerf" Content="Leistung"/>
        <Button x:Name="BtnFreeRam" Content="RAM freigeben"/>
        <Button x:Name="BtnPriorities" Content="Prioritaeten"/>
        <Button x:Name="BtnGaming" Content="Gaming"/>
        <Button x:Name="BtnWork" Content="Arbeit"/>
        <Button x:Name="BtnNight" Content="Nacht"/>
        <Button x:Name="BtnLHM" Content="Temp-Sensor" ToolTip="LibreHardwareMonitor installieren (echte CPU-Temperatur)"/>
        <Button x:Name="BtnMenu" Content="Vollmenue"/>
      </WrapPanel>
    </Border>
  </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$win = [Windows.Markup.XamlReader]::Load($reader)

# Fenster automatisch in den Vordergrund, wenn eine Aktion laeuft
function Show-SysPilotWindow {
    if ($win.WindowState -eq 'Minimized' -or -not $win.IsVisible) {
        $win.Show(); $win.WindowState = 'Normal'
    }
    $win.Activate() | Out-Null
    $win.Focus() | Out-Null
}

# Controls
$ctrl = @{}
foreach ($n in 'CpuText','CpuSpeed','CpuBar','RamText','RamDetail','RamBar','DiskText','DiskDetail','DiskBar',
                 'SysCpu','SysProcs','SysBattery','SysUptime','HogList','AdminBadge','PlanBadge','WatchBadge','VersionBadge',
                 'TempBig','TempStatus','TempSource','TempUnitLabel',
                 'BtnCheckup','BtnToolbox','BtnDns','BtnHealth','BtnAISearch','BtnAuto','BtnCool','BtnPerf','BtnFreeRam','BtnPriorities','BtnGaming','BtnWork','BtnNight','BtnLHM','BtnMenu','BtnAdmin','BtnUpdate') {
    $ctrl[$n] = $win.FindName($n)
}

# Admin-Badge
$isAdmin = Test-SysPilotAdmin
$ctrl.AdminBadge.Text = if ($isAdmin) { "ADMIN" } else { "eingeschraenkt" }
$ctrl.BtnAdmin.Visibility = if ($isAdmin) { 'Collapsed' } else { 'Visible' }
$script:tick = 0

# System-Info (einmalig)
$cpuInfo = Get-CimInstance Win32_Processor
$ctrl.SysCpu.Text = "{0} ({1}C/{2}T)" -f $cpuInfo.Name.Trim().Replace('AMD ','').Replace(' with Radeon Graphics',''), $cpuInfo.NumberOfCores, $cpuInfo.NumberOfLogicalProcessors

# Schnelle Perf-Counter (kein WMI-Overhead pro Tick)
$script:ctrCpu  = New-Object System.Diagnostics.PerformanceCounter('Processor','% Processor Time','_Total')
$script:ctrRam  = New-Object System.Diagnostics.PerformanceCounter('Memory','% Committed Bytes In Use')
$script:ctrFreq = New-Object System.Diagnostics.PerformanceCounter('Processor Information','% Processor Performance','_Total')
[void]$script:ctrCpu.NextValue(); [void]$script:ctrRam.NextValue(); [void]$script:ctrFreq.NextValue()

function Update-SysPilotGui {
    # CPU (Perf-Counter, schnell)
    $load = [math]::Round($script:ctrCpu.NextValue())
    $ctrl.CpuText.Text = "$load%"
    $ctrl.CpuBar.Value = $load
    $ctrl.CpuBar.Foreground = if ($load -gt 80) { '#FFEF5350' } elseif ($load -gt 55) { '#FFFFB74D' } else { '#FF4FC3F7' }

    # Takt: % der Basis-Leistung * Max-Takt
    $freqPct = $script:ctrFreq.NextValue()
    $ghz = [math]::Round(($freqPct/100) * ($cpuInfo.MaxClockSpeed/1000), 2)
    $ctrl.CpuSpeed.Text = "$ghz GHz"

    # RAM
    $os = Get-CimInstance Win32_OperatingSystem
    $totalGB = $os.TotalVisibleMemorySize/1MB; $freeGB = $os.FreePhysicalMemory/1MB
    $ramPct = [math]::Round(100*($totalGB-$freeGB)/$totalGB)
    $ctrl.RamText.Text = "$ramPct%"
    $ctrl.RamBar.Value = $ramPct
    $ctrl.RamDetail.Text = ("{0:N1}/{1:N1} GB frei" -f $freeGB, $totalGB)
    $ctrl.RamBar.Foreground = if ($ramPct -gt 85) { '#FFEF5350' } elseif ($ramPct -gt 70) { '#FFFFB74D' } else { '#FFBA68C8' }

    # Disk
    $d = Get-PSDrive C
    $diskPct = [math]::Round(100*$d.Used/($d.Used+$d.Free))
    $ctrl.DiskText.Text = "$diskPct%"
    $ctrl.DiskBar.Value = $diskPct
    $ctrl.DiskDetail.Text = ("{0:N0} GB frei" -f ($d.Free/1GB))

    # Prozesse / Akku / Uptime / Plan
    $ctrl.SysProcs.Text = "Prozesse: " + (Get-Process).Count
    $b = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
    $ctrl.SysBattery.Text = if ($b) { "Akku: $($b.EstimatedChargeRemaining)%$(if($b.BatteryStatus -eq 1){' (entlaedt)'}else{' (Netz)'})" } else { "Netzbetrieb" }
    $up = (Get-Date) - $os.LastBootUpTime
    $ctrl.SysUptime.Text = ("Laufzeit: {0}d {1}h {2}m" -f $up.Days, $up.Hours, $up.Minutes)
    $mode = Get-SysPilotActiveMode
    $ctrl.PlanBadge.Text = switch ($mode) {
        'Cool'        { 'Plan: KUEHL' }
        'Performance' { 'Plan: LEISTUNG' }
        default       { $n = Get-SysPilotActivePlanName; if ($n) { "Plan: $n" } else { 'Plan: unbekannt' } }
    }

    # Temperatur (gross, in gewaehlter Einheit)
    if (Get-Command Get-SysPilotCpuTemperature -ErrorAction SilentlyContinue) {
        $t = Get-SysPilotCpuTemperature
        $st = Get-SysPilotTempStatus -Celsius $t.Celsius
        $conv = ConvertTo-SysPilotTemp -Celsius $t.Celsius
        $ctrl.TempBig.Text = $conv.Value
        $ctrl.TempBig.Foreground = $st.Color
        $ctrl.TempUnitLabel.Text = $conv.Unit
        $ctrl.TempStatus.Text = $st.Text
        $ctrl.TempStatus.Foreground = $st.Color
        $ctrl.TempSource.Text = if ($t.Geschaetzt) { "geschaetzt (fuer echte Werte: Temp-Sensor-Button)" } else { $t.Quelle }
    }

    # Top-Fresser (gruppiert) - nur alle 5. Ticks neu (Liste flackert sonst)
    $script:tick++
    if (($script:tick % 5) -eq 0 -or $null -eq $ctrl.HogList.ItemsSource) {
        $hogs = Get-Process | Group-Object ProcessName | ForEach-Object {
            [PSCustomObject]@{
                Programm = $_.Name
                RAM_MB = [math]::Round(($_.Group | Measure-Object WorkingSet64 -Sum).Sum/1MB)
                CPU_s = [math]::Round(($_.Group | Measure-Object CPU -Sum).Sum)
                Instanzen = $_.Count
                Massnahme = ''
            }
        } | Sort-Object RAM_MB -Descending | Select-Object -First 12

        $known = (Get-SysPilotConfig).Hogs.KnownHogs
        foreach ($h in $hogs) {
            foreach ($k in $known) {
                if ($h.Programm -like "*$($k.Name)*" -or $k.Name -like "*$($h.Programm)*") {
                    $h.Massnahme = $k.Fix
                    $h | Add-Member -NotePropertyName HowTo -NotePropertyValue $k.HowTo -Force
                    $h | Add-Member -NotePropertyName Link -NotePropertyValue $k.Link -Force
                    $h | Add-Member -NotePropertyName Action -NotePropertyValue $k.Action -Force
                    break
                }
            }
        }
        $ctrl.HogList.ItemsSource = $hogs
    }

    # Tray-Icon Tooltip mit Live-Daten aktualisieren (Windows-Limit: max 63 Zeichen)
    if ($script:notifyIcon -and $script:notifyIcon.Visible) {
        try {
            $tVal = if ($ctrl.TempBig.Text -and $ctrl.TempBig.Text -ne '--') { "$($ctrl.TempBig.Text)$($ctrl.TempUnitLabel.Text)" } else { '' }
            $trayTxt = "SysPilot | CPU: $load% | RAM: $ramPct%"
            if ($tVal) { $trayTxt += " | $tVal" }
            if ($trayTxt.Length -gt 63) { $trayTxt = $trayTxt.Substring(0, 63) }
            Set-SysPilotTrayTooltip $trayTxt
        } catch { }
    }
}

# Hilfsfunktion: Plan-Wechsel mit Feedback + Admin-Angebot
function Set-PlanWithFeedback {
    param([string]$Mode, [string]$Label)
    Show-SysPilotWindow
    $name = if ($Mode -eq 'Cool') { 'SysPilot Kuehl & Leise' } else { 'SysPilot Leistung' }
    $guid = Get-SysPilotPlanGuid -Name $name
    if (-not $guid) {
        $ans = [System.Windows.MessageBox]::Show("Der Plan '$name' existiert noch nicht.`nJetzt einrichten? (braucht Admin)", "Plan fehlt", 'YesNo', 'Question')
        if ($ans -eq 'Yes') {
            if (Test-SysPilotAdmin) { Install-SysPilotPlans } else { Restart-SysPilotElevated }
        }
        return
    }
    if (-not (Test-SysPilotAdmin)) {
        $ans = [System.Windows.MessageBox]::Show("Plan-Wechsel braucht Administrator-Rechte.`nSysPilot jetzt als Admin neu starten?", "Admin noetig", 'YesNo', 'Question')
        if ($ans -eq 'Yes') { Restart-SysPilotElevated }
        return
    }
    & powercfg /setactive $guid 2>$null | Out-Null
    Start-Sleep -Milliseconds 400
    $now = Get-SysPilotActiveMode
    if ($now -eq $Mode) {
        $ctrl.PlanBadge.Text = "Plan: $Label"
    } else {
        [System.Windows.MessageBox]::Show("Wechsel auf '$Label' hat nicht geklappt.", "SysPilot", 'OK', 'Warning') | Out-Null
    }
}

# --- Checkup-Fenster (nativ, Scan laeuft im Hintergrund-Runspace) ---
function Show-SysPilotCheckupWindow {
    $cxaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="SysPilot - Automatic Checkup" Width="740" Height="580" MinWidth="640" MinHeight="480"
        Background="#FF1E1E2E" Foreground="#FFE0E0E0"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResizeWithGrip">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#FF2D2D44"/><Setter Property="Foreground" Value="#FFE0E0E0"/>
      <Setter Property="BorderBrush" Value="#FF4A4A6A"/><Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="10,6"/><Setter Property="Margin" Value="3"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="12"/>
    </Style>
    <Style TargetType="CheckBox"><Setter Property="Foreground" Value="#FFE0E0E0"/></Style>
  </Window.Resources>
  <Grid Margin="14">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <DockPanel Grid.Row="0">
      <TextBlock Text="Automatic Checkup" FontSize="20" FontWeight="Bold" Foreground="#FF4FC3F7"/>
      <TextBlock Text="15 Bereiche, ehrlich erklaert, echt repariert" FontSize="11" Foreground="#FF9E9E9E" HorizontalAlignment="Right" VerticalAlignment="Bottom"/>
    </DockPanel>
    <StackPanel Grid.Row="1" Margin="0,8">
      <ProgressBar x:Name="ScanBar" Height="6" Minimum="0" Maximum="100" Background="#FF2D2D44" Foreground="#FF4FC3F7"/>
      <TextBlock x:Name="StatusText" Text="Bereit. Starte den Scan, um deinen PC zu pruefen." FontSize="11" Foreground="#FF9E9E9E" Margin="0,4,0,0"/>
    </StackPanel>
    <ListView x:Name="ResultList" Grid.Row="2" Background="#FF252538" BorderThickness="0">
      <ListView.ItemTemplate>
        <DataTemplate>
          <StackPanel Orientation="Horizontal" Margin="2">
            <CheckBox IsChecked="{Binding Selected, Mode=TwoWay}" VerticalAlignment="Center"/>
            <TextBlock Text="{Binding Icon}" Width="34" VerticalAlignment="Center" Foreground="{Binding IconColor}" FontWeight="Bold"/>
            <TextBlock Text="{Binding Name}" Width="200" VerticalAlignment="Center" Foreground="#FFE0E0E0"/>
            <TextBlock Text="{Binding Summary}" VerticalAlignment="Center" Foreground="#FF9E9E9E"/>
          </StackPanel>
        </DataTemplate>
      </ListView.ItemTemplate>
    </ListView>
    <Border Grid.Row="3" Background="#FF252538" CornerRadius="6" Padding="8" Margin="0,8">
      <TextBlock x:Name="DetailText" Text="Waehle einen Eintrag, um die Erklaerung zu sehen." TextWrapping="Wrap" FontSize="12" Foreground="#FFB0B0C0"/>
    </Border>
    <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Center">
      <Button x:Name="BtnScan" Content="Scan starten"/>
      <Button x:Name="BtnFixSelected" Content="Ausgewaehlte beheben"/>
      <Button x:Name="BtnFixAll" Content="Alle beheben"/>
      <Button x:Name="BtnTool" Content="Werkzeug oeffnen" ToolTip="Fuer Bereiche, die deine Entscheidung brauchen"/>
      <Button x:Name="BtnClose" Content="Schliessen"/>
    </StackPanel>
  </Grid>
</Window>
"@
    $creader = New-Object System.Xml.XmlNodeReader ([xml]$cxaml)
    $cwin = [Windows.Markup.XamlReader]::Load($creader)
    $cwin.Owner = $win
    $cctrl = @{}
    foreach ($n in 'ScanBar','StatusText','ResultList','DetailText','BtnScan','BtnFixSelected','BtnFixAll','BtnTool','BtnClose') {
        $cctrl[$n] = $cwin.FindName($n)
    }
    $script:checkupItems = @()

    $scanTimer = New-Object System.Windows.Threading.DispatcherTimer
    $scanTimer.Interval = [TimeSpan]::FromMilliseconds(400)

    $startScan = {
        $cctrl.BtnScan.IsEnabled = $false
        $cctrl.ScanBar.IsIndeterminate = $true
        $cctrl.StatusText.Text = 'Scan laeuft ...'
        $cctrl.ResultList.ItemsSource = $null
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('Root', $script:Root)
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript({
            Get-ChildItem (Join-Path $Root 'modules') -Filter '*.psm1' | ForEach-Object { Import-Module $_.FullName -Force -Global -WarningAction SilentlyContinue }
            Invoke-SysPilotCheckupScan -Quiet
        })
        $script:scanPs = $ps; $script:scanRs = $rs
        $script:scanHandle = $ps.BeginInvoke()
        $scanTimer.Start()
    }

    $scanTimer.Add_Tick({
        if (-not $script:scanHandle.IsCompleted) { return }
        $scanTimer.Stop()
        $cctrl.ScanBar.IsIndeterminate = $false
        $cctrl.ScanBar.Value = 100
        $cctrl.BtnScan.IsEnabled = $true
        $out = $script:scanPs.EndInvoke($script:scanHandle)
        $script:scanPs.Dispose(); $script:scanRs.Close(); $script:scanRs.Dispose()

        $script:checkupItems = @($out | ForEach-Object {
            $icon = if ($_.Skipped) { '?' } elseif (-not $_.Found) { 'OK' } elseif ($_.Critical) { '!!' } else { 'i' }
            $color = if ($_.Skipped) { '#FF666677' } elseif (-not $_.Found) { '#FF81C784' } elseif ($_.Critical) { '#FFEF5350' } else { '#FFFFB74D' }
            [PSCustomObject]@{
                Selected   = ($_.Found -and $_.AutoFix)
                Icon       = $icon
                IconColor  = $color
                Name       = $_.Name
                Summary    = $_.Summary
                Erklaerung = $_.Erklaerung
                Id         = $_.Id
                Found      = $_.Found
                AutoFix    = $_.AutoFix
                MenuAction = $_.MenuAction
                Details    = $_.Details
            }
        })
        $cctrl.ResultList.ItemsSource = $script:checkupItems
        $foundCount = @($script:checkupItems | Where-Object { $_.Found }).Count
        $cctrl.StatusText.Text = if ($foundCount -eq 0) { 'Fertig: Alles sauber - dein PC ist in Topform!' } else { "Fertig: $foundCount Bereiche mit Befunden. Haken setzen und beheben." }
    })

    $cctrl.BtnScan.Add_Click($startScan)

    $cctrl.ResultList.Add_SelectionChanged({
        $sel = $cctrl.ResultList.SelectedItem
        if ($null -eq $sel) { return }
        $txt = $sel.Erklaerung
        if ($sel.Details -and $sel.Details.Count -gt 0) { $txt += "`n`nBefund: " + ($sel.Details -join '; ') }
        if ($sel.Found -and -not $sel.AutoFix) { $txt += "`n`nDieser Bereich braucht deine Entscheidung - nutze den Button 'Werkzeug oeffnen'." }
        $cctrl.DetailText.Text = $txt
    })

    $runFix = {
        param($items)
        $toFix = @($items | Where-Object { $_.Found -and $_.AutoFix -and $_.Selected })
        if ($toFix.Count -eq 0) {
            [System.Windows.MessageBox]::Show('Keine automatisch behebbaren Eintraege ausgewaehlt.', 'Checkup', 'OK', 'Information') | Out-Null
            return
        }
        $cctrl.BtnScan.IsEnabled = $false
        $cctrl.ScanBar.IsIndeterminate = $true
        $cctrl.StatusText.Text = "Behebe $($toFix.Count) Bereiche ..."
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('Root', $script:Root)
        $rs.SessionStateProxy.SetVariable('ToFix', $toFix)
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript({
            Get-ChildItem (Join-Path $Root 'modules') -Filter '*.psm1' | ForEach-Object { Import-Module $_.FullName -Force -Global -WarningAction SilentlyContinue }
            Invoke-SysPilotCheckupFix -Results $ToFix
        })
        $handle = $ps.BeginInvoke()
        while (-not $handle.IsCompleted) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 200
        }
        $fixed = $ps.EndInvoke($handle)
        $ps.Dispose(); $rs.Close(); $rs.Dispose()
        $cctrl.ScanBar.IsIndeterminate = $false
        $cctrl.BtnScan.IsEnabled = $true
        [System.Windows.MessageBox]::Show("$fixed Bereiche behoben. Der Scan startet zur Kontrolle erneut.", 'Checkup', 'OK', 'Information') | Out-Null
        & $startScan
    }

    $cctrl.BtnFixSelected.Add_Click({ & $runFix $script:checkupItems })
    $cctrl.BtnFixAll.Add_Click({
        foreach ($i in $script:checkupItems) { if ($i.Found -and $i.AutoFix) { $i.Selected = $true } }
        & $runFix $script:checkupItems
    })
    $cctrl.BtnTool.Add_Click({
        $sel = $cctrl.ResultList.SelectedItem
        if ($null -eq $sel -or -not $sel.MenuAction) {
            [System.Windows.MessageBox]::Show('Waehle links einen Eintrag, der ein Werkzeug hat (z.B. Autostart-Last, Bloatware).', 'Checkup', 'OK', 'Information') | Out-Null
            return
        }
        $root = $script:Root
        if (-not $root) { $root = Split-Path -Parent $PSCommandPath }
        $toolArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File', (Join-Path $root 'SysPilot.ps1'), '-Tool', $sel.MenuAction)
        Start-Process powershell.exe -ArgumentList (ConvertTo-SysPilotArgString $toolArgs)
    })
    $cctrl.BtnClose.Add_Click({ $cwin.Close() })

    $cwin.ShowDialog() | Out-Null
    $scanTimer.Stop()
}

# --- Toolbox-Fenster (Kategorien, startet die Konsolen-Werkzeuge) ---
function Show-SysPilotToolboxWindow {
    $twin = New-Object System.Windows.Window
    $twin.Title = 'SysPilot - Toolbox'
    $twin.Width = 640; $twin.Height = 560
    $twin.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#FF1E1E2E')
    $twin.WindowStartupLocation = 'CenterOwner'
    $twin.Owner = $win

    $scroll = New-Object System.Windows.Controls.ScrollViewer
    $scroll.VerticalScrollBarVisibility = 'Auto'
    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Margin = '14'
    $scroll.Content = $panel
    $twin.Content = $scroll

    $head = New-Object System.Windows.Controls.TextBlock
    $head.Text = 'Toolbox - alle Werkzeuge nach Kategorie'
    $head.FontSize = 20; $head.FontWeight = 'Bold'
    $head.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#FF4FC3F7')
    $panel.Children.Add($head) | Out-Null
    $hint = New-Object System.Windows.Controls.TextBlock
    $hint.Text = 'Jedes Werkzeug oeffnet sich in einem eigenen Fenster. Mauszeiger auf einen Eintrag = Erklaerung.'
    $hint.FontSize = 11; $hint.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#FF9E9E9E')
    $hint.Margin = '0,2,0,10'
    $panel.Children.Add($hint) | Out-Null

    $tools = Get-SysPilotToolbox
    foreach ($cat in ($tools | Group-Object Category)) {
        $catHead = New-Object System.Windows.Controls.TextBlock
        $catHead.Text = $cat.Name
        $catHead.FontSize = 15; $catHead.FontWeight = 'Bold'
        $catHead.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#FFFFB74D')
        $catHead.Margin = '0,10,0,4'
        $panel.Children.Add($catHead) | Out-Null

        $wrap = New-Object System.Windows.Controls.WrapPanel
        foreach ($t in $cat.Group) {
            $btn = New-Object System.Windows.Controls.Button
            $btn.Content = $t.Name + $(if ($t.NeedsAdmin) { ' [Admin]' } else { '' })
            $btn.ToolTip = $t.Desc
            $btn.Tag = $t.Key
            $btn.Margin = '3'; $btn.Padding = '10,6'
            $btn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#FF2D2D44')
            $btn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#FFE0E0E0')
            $btn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#FF4A4A6A')
            $btn.Cursor = 'Hand'
            $needsAdmin = [bool]$t.NeedsAdmin
            $btn.Add_Click({
                param($s, $e)
                $key = $s.Tag
                $root = $script:Root
                if (-not $root) { $root = Split-Path -Parent $PSCommandPath }
                if (-not $root) {
                    [System.Windows.MessageBox]::Show('Installationspfad nicht gefunden. Bitte GUI neu starten.', 'SysPilot', 'OK', 'Warning') | Out-Null
                    return
                }
                $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File', (Join-Path $root 'SysPilot.ps1'), '-Tool', $key)
                $cmdLine = ConvertTo-SysPilotArgString $argList
                try {
                    if ($needsAdmin -and -not (Test-SysPilotAdmin)) {
                        Start-Process powershell.exe -Verb RunAs -ArgumentList $cmdLine
                    } else {
                        Start-Process powershell.exe -ArgumentList $cmdLine
                    }
                } catch {
                    [System.Windows.MessageBox]::Show("Das Werkzeug konnte nicht gestartet werden:`n$($_.Exception.Message)", 'SysPilot', 'OK', 'Warning') | Out-Null
                }
            }.GetNewClosure())
            $wrap.Children.Add($btn) | Out-Null
        }
        $panel.Children.Add($wrap) | Out-Null
    }
    $twin.ShowDialog() | Out-Null
}

# --- Updates ---
$ctrl.VersionBadge.Text = 'v' + (Get-SysPilotVersion)
$script:updateInfo = $null
$script:updJob = $null

function Install-SysPilotGuiUpdate {
    param($info)
    $txt = "Neue Version verfuegbar: $($info.Latest)`n(installiert: $($info.Current))`n`nJetzt herunterladen und installieren?`nSysPilot wird dabei kurz neu gestartet, Windows fragt nach Administrator-Rechten."
    $ans = [System.Windows.MessageBox]::Show($txt, 'SysPilot Update', 'YesNo', 'Question')
    if ($ans -ne 'Yes') { return }
    if (-not $info.DownloadUrl) {
        # Noch kein Installer als Datei am Release -> Download-Seite im Browser oeffnen
        Start-Process $info.Url
        return
    }
    try {
        $win.Cursor = [System.Windows.Input.Cursors]::Wait
        $win.Dispatcher.Invoke([action]{}, 'Render')
        Install-SysPilotUpdate -DownloadUrl $info.DownloadUrl -Version $info.Latest
        $script:reallyClose = $true
        $win.Close()
    } catch {
        [System.Windows.MessageBox]::Show("Update fehlgeschlagen:`n$($_.Exception.Message)`n`nDu kannst die neue Version auch hier laden:`n$($info.Url)", 'SysPilot Update', 'OK', 'Warning') | Out-Null
    } finally {
        $win.Cursor = $null
    }
}

function Invoke-SysPilotGuiUpdateClick {
    if ($script:updateInfo -and $script:updateInfo.Newer) { Install-SysPilotGuiUpdate $script:updateInfo; return }
    try {
        $win.Cursor = [System.Windows.Input.Cursors]::Wait
        $win.Dispatcher.Invoke([action]{}, 'Render')
        $info = Test-SysPilotUpdate
    } finally { $win.Cursor = $null }
    if (-not $info.Ok) {
        [System.Windows.MessageBox]::Show("Die Update-Suche hat nicht geklappt (keine Verbindung zu GitHub?).`n`n$($info.Error)", 'SysPilot Update', 'OK', 'Warning') | Out-Null
        return
    }
    if ($info.Newer) {
        $script:updateInfo = $info
        Set-SysPilotGuiUpdateAvailable $info
        Install-SysPilotGuiUpdate $info
    } else {
        [System.Windows.MessageBox]::Show("SysPilot ist aktuell (Version $($info.Current)).", 'SysPilot Update', 'OK', 'Information') | Out-Null
    }
}

function Set-SysPilotGuiUpdateAvailable {
    param($info)
    $ctrl.BtnUpdate.Content = "Update $($info.Latest) verfuegbar!"
    $ctrl.BtnUpdate.FontWeight = 'Bold'
    $ctrl.BtnUpdate.Foreground = [System.Windows.Media.Brushes]::OrangeRed
    $ctrl.BtnUpdate.ToolTip = "SysPilot Update verfuegbar!`nInstalliert: $($info.Current) -> Neueste: $($info.Latest)`nKlicken zum Herunterladen und Installieren."
}

# ---------- Toolbox-GUI (Maussteuerbar) ----------
function Show-SysPilotToolboxWindow {
    $tools = Get-SysPilotToolbox
    $categories = @($tools | Group-Object Category | ForEach-Object { $_.Name })

    $window = New-Object System.Windows.Window
    $window.Title = 'SysPilot - Toolbox (Maussteuerbar)'
    $window.Width = 880; $window.Height = 620
    $window.WindowStartupLocation = 'CenterScreen'

    $grid = New-Object System.Windows.Controls.Grid
    $grid.Margin = '14'
    $grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Height Auto))
    $grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Height '*'))
    $grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Height Auto))

    # Header
    $title = New-Object System.Windows.Controls.TextBlock
    $title.Text = 'Toolbox - Werkzeuge nach Kategorie'
    $title.FontSize = 20; $title.FontWeight = 'Bold'; $title.Foreground = '#FF4FC3F7'
    [System.Windows.Controls.Grid]::SetRow($title,0); $grid.Children.Add($title)|Out-Null

    # Category + Tool list
    $catPanel = New-Object System.Windows.Controls.StackPanel
    $catPanel.Orientation = 'Vertical'
    $toolPanel = New-Object System.Windows.Controls.StackPanel
    $toolPanel.Orientation = 'Vertical'

    $catButtons = @{}
    foreach ($c in $categories) {
        $btn = New-Object System.Windows.Controls.Button
        $btn.Content = "$c"
        $btn.Margin = '2,0,2,0'
        $btn.Tag = $c
        $catButtons[$c] = $btn
        $catPanel.Children.Add($btn)|Out-Null
    }

    $toolList = New-Object System.Windows.Controls.ListBox
    $toolList.DisplayMemberPath = 'Name'
    $toolList.Margin = '4,0,0,0'
    [System.Windows.Controls.Grid]::SetRow($toolList,1); $grid.Children.Add($toolList)|Out-Null

    # Tool detail panel
    $detailPanel = New-Object System.Windows.Controls.StackPanel
    $detailPanel.Orientation = 'Vertical'
    $detailPanel.Margin = '8,8,8,8'
    $detailText = New-Object System.Windows.Controls.TextBlock
    $detailText.TextWrapping = 'Wrap'
    $detailText.FontSize = 12
    $detailPanel.Children.Add($detailText)|Out-Null

    # Buttons
    $btnPanel = New-Object System.Windows.Controls.StackPanel
    $btnPanel.Orientation = 'Horizontal'
    $btnPanel.HorizontalAlignment = 'Center'
    $btnExplain = New-Object System.Windows.Controls.Button
    $btnExplain.Content = 'Erklären'
    $btnExplain.Margin = '4'
    $btnHowTo = New-Object System.Windows.Controls.Button
    $btnHowTo.Content = 'HowTo / KI-Suche'
    $btnHowTo.Margin = '4'
    $btnRun = New-Object System.Windows.Controls.Button
    $btnRun.Content = 'Ausführen'
    $btnRun.Margin = '4'
    $btnClose = New-Object System.Windows.Controls.Button
    $btnClose.Content = 'Schließen'
    $btnClose.Margin = '4'
    foreach ($b in @($btnExplain,$btnHowTo,$btnRun,$btnClose)) { $btnPanel.Children.Add($b)|Out-Null }
    [System.Windows.Controls.Grid]::SetRow($btnPanel,2); $grid.Children.Add($btnPanel)|Out-Null

    # State
    $script:toolboxSelectedTool = $null
    $script:toolboxCurrentCategory = $null

    # Category click handler
    foreach ($c in $categories) {
        $catButtons[$c].Add_Click({
            param($sender, $e)
            $script:toolboxCurrentCategory = $sender.Tag
            $toolList.Items.Clear()
            foreach ($t in ($tools | Where-Object { $_.Category -eq $script:toolboxCurrentCategory })) {
                $toolList.Items.Add($t)|Out-Null
            }
            $detailText.Text = 'Werkzeug auswählen...'
        })
    }

    # Tool selection handler
    $toolList.Add_SelectionChanged({
        $t = $toolList.SelectedItem
        if ($t) {
            $script:toolboxSelectedTool = $t
            $detailText.Text = "$($t.Name)`n`n$($t.Desc)`n`nErklärung: $($t.Explanation)`n`nTipp: $($t.Tip)`n`nHowTo: $($t.HowTo)"
        }
    })

    # Explain button
    $btnExplain.Add_Click({
        $t = $script:toolboxSelectedTool
        if ($t) {
            [System.Windows.MessageBox]::Show("$($t.Name)`n`n$($t.Desc)`n`nErklärung: $($t.Explanation)`n`nTipp: $($t.Tip)", 'Erklärung', 'OK', 'Information') | Out-Null
        }
    })

    # HowTo / AI Search button
    $btnHowTo.Add_Click({
        $t = $script:toolboxSelectedTool
        if ($t) {
            $query = if ($t.AISearchQuery) { $t.AISearchQuery } else { $t.Name + ' Windows' }
            Invoke-SysPilotAISearch -Query $query
        }
    })

    # Run button
    $btnRun.Add_Click({
        $t = $script:toolboxSelectedTool
        if ($t) {
            if ($t.NeedsAdmin -and -not (Test-SysPilotAdmin)) {
                [System.Windows.MessageBox]::Show('Dieses Werkzeug braucht Admin-Rechte. Bitte als Admin neu starten.', 'Admin noetig', 'OK', 'Warning') | Out-Null
                return
            }
            & $t.Action
        }
    })

    # Close button
    $btnClose.Add_Click({ $window.Close() })

    $window.Content = $grid
    $window.ShowDialog() | Out-Null
}

# ---------- Checkup-GUI (implemented in Checkup.psm1 module) ----------
# Button calls Show-SysPilotCheckupWindow directly (imported globally from Checkup.psm1)

# ---------- Buttons ----------

# Buttons
$ctrl.BtnUpdate.Add_Click({ Invoke-SysPilotGuiUpdateClick })
$ctrl.BtnAdmin.Add_Click({
    $ans = [System.Windows.MessageBox]::Show("SysPilot mit Administrator-Rechten neu starten?`n`nDamit funktionieren: Energieplaene, Dienste, alle Checkup-Fixes, Netzwerk-Reparatur.", "Als Admin starten", 'YesNo', 'Question')
    if ($ans -eq 'Yes') {
        $script:reallyClose = $true
        Restart-SysPilotElevated -NoExit
        $win.Close()
    }
})
$ctrl.BtnCheckup.Add_Click({ Show-SysPilotCheckupWindow })
$ctrl.BtnToolbox.Add_Click({ Show-SysPilotToolboxWindow })
$ctrl.BtnDns.Add_Click({ Show-SysPilotWindow; Show-SysPilotDnsWindow })
$ctrl.BtnHealth.Add_Click({ Show-SysPilotWindow; Show-SysPilotHealthDashboard })
$ctrl.BtnAISearch.Add_Click({ Show-SysPilotWindow; Invoke-SysPilotAISearch -Query (Read-SysPilotChoice 'Suchbegriff fuer KI-Websuche') })
$ctrl.BtnAuto.Add_Click({
    $msg = "VOLLAUTOMATIK (Auto-Optimierung)`n`n1. Backup (Dienste, Registry, Energieplaene)`n2. Dienste optimieren (nur gepruefte Empfehlungen)`n3. Sicher unnoetige Windows-Features aus`n4. Tweaks: Game Mode an, Werbung aus, Optik bleibt huebsch`n5. Prozess-Prioritaeten anwenden`n`nBraucht Admin. Jetzt starten?"
    $ans = [System.Windows.MessageBox]::Show($msg, 'Vollautomatik', 'YesNo', 'Question')
    if ($ans -ne 'Yes') { return }
    $root = $script:Root
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File', (Join-Path $root 'SysPilot.ps1'), '-Tool', 'autooptimize')
    $cmdLine = ConvertTo-SysPilotArgString $argList
    if (Test-SysPilotAdmin) {
        Start-Process powershell.exe -ArgumentList $cmdLine
    } else {
        Start-Process powershell.exe -Verb RunAs -ArgumentList $cmdLine
    }
})
$ctrl.BtnCool.Add_Click({ Set-PlanWithFeedback -Mode Cool -Label 'KUEHL'; Update-SysPilotGui })
$ctrl.BtnPerf.Add_Click({ Set-PlanWithFeedback -Mode Performance -Label 'LEISTUNG'; Update-SysPilotGui })
$ctrl.BtnFreeRam.Add_Click({
    Show-SysPilotWindow
    $ws = Clear-SysPilotWorkingSets
    if (Test-SysPilotAdmin) { Clear-SysPilotStandbyList | Out-Null }
    [System.Windows.MessageBox]::Show("$($ws.FreedMB) MB freigegeben ($($ws.Trimmed) Prozesse)", "RAM freigeben", 'OK', 'Information') | Out-Null
    Update-SysPilotGui
})
$ctrl.BtnPriorities.Add_Click({ Show-SysPilotWindow; Set-SysPilotPriorities -Quiet; Update-SysPilotGui })
$ctrl.BtnGaming.Add_Click({
    Show-SysPilotWindow
    if (-not (Test-SysPilotAdmin)) {
        $ans = [System.Windows.MessageBox]::Show("Gaming-Modus (Plan-Wechsel) braucht Admin.`nJetzt als Admin neu starten?", "Admin noetig", 'YesNo', 'Question')
        if ($ans -eq 'Yes') { Restart-SysPilotElevated }
        return
    }
    & (Join-Path $script:Root 'scripts\01-Gaming-Modus.ps1'); Update-SysPilotGui
})
$ctrl.BtnWork.Add_Click({
    Show-SysPilotWindow
    if (-not (Test-SysPilotAdmin)) {
        $ans = [System.Windows.MessageBox]::Show("Arbeits-Modus (Plan-Wechsel) braucht Admin.`nJetzt als Admin neu starten?", "Admin noetig", 'YesNo', 'Question')
        if ($ans -eq 'Yes') { Restart-SysPilotElevated }
        return
    }
    & (Join-Path $script:Root 'scripts\02-Arbeits-Modus.ps1'); Update-SysPilotGui
})
$ctrl.BtnNight.Add_Click({
    Show-SysPilotWindow
    if (-not (Test-SysPilotAdmin)) {
        $ans = [System.Windows.MessageBox]::Show("Nacht-Modus (Plan-Wechsel) braucht Admin.`nJetzt als Admin neu starten?", "Admin noetig", 'YesNo', 'Question')
        if ($ans -eq 'Yes') { Restart-SysPilotElevated }
        return
    }
    & (Join-Path $script:Root 'scripts\05-Nacht-Modus.ps1'); Update-SysPilotGui
})
$ctrl.BtnLHM.Add_Click({
    Show-SysPilotWindow
    $msg = "Echte CPU-Temperatur statt Schaetzung?`n`nDein Laptop gibt den Temperatur-Sensor nicht direkt frei. SysPilot schaetzt die Temperatur aktuell aus Last + Takt.`n`nLibreHardwareMonitor (kostenlos, Open Source, ~5 MB, portable) liest den echten Sensor. SysPilot nutzt ihn dann automatisch - auch fuer den Hitzeschutz (Notaus bei 95°C).`n`nJetzt als Administrator installieren und starten?"
    $ans = [System.Windows.MessageBox]::Show($msg, "Temp-Sensor (LibreHardwareMonitor)", 'YesNo', 'Question')
    if ($ans -eq 'Yes') {
        if (Test-SysPilotAdmin) {
            Install-SysPilotLHM
        } else {
            # Als Admin neu starten und LHM installieren
            $scriptPath = Join-Path $script:Root 'SysPilot-GUI.ps1'
            Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"Import-Module '$script:Root\modules\Temperature.psm1' -Force; Import-Module '$script:Root\modules\Common.psm1' -Force; Install-SysPilotLHM; Start-Process powershell.exe -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \`"$scriptPath\`"'`""
        }
    }
    Update-SysPilotGui
})
$ctrl.BtnMenu.Add_Click({
    Start-Process powershell.exe -ArgumentList (ConvertTo-SysPilotArgString @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $script:Root 'SysPilot.ps1')))
})

# Doppelklick auf Fresser -> Details + Aktion/Howto
$ctrl.HogList.Add_MouseDoubleClick({
    $hog = $ctrl.HogList.SelectedItem
    if (-not $hog) { return }
    Show-SysPilotWindow
    $msg = "$($hog.Programm)`n`nRAM: $($hog.RAM_MB) MB  |  CPU: $($hog.CPU_s)s  |  Instanzen: $($hog.Instanzen)`n"
    if ($hog.Massnahme) { $msg += "`nMassnahme: $($hog.Massnahme)" }
    if ($hog.HowTo) { $msg += "`n`nWie geht das?`n$($hog.HowTo)" }
    if ($hog.Link) { $msg += "`n`nAnleitung: $($hog.Link)" }

    if ($hog.Action) {
        $actionText = switch ($hog.Action) {
            'DisableStartup' { 'Autostart deaktivieren' }
            'Uninstall'      { 'Programm deinstallieren' }
            'DisableService' { 'Dienst auf Manuell stellen' }
            'WslShutdown'    { 'WSL/Docker herunterfahren' }
            default { $hog.Action }
        }
        $msg += "`n`nSoll SysPilot das jetzt fuer dich tun? ($actionText)"
        $ans = [System.Windows.MessageBox]::Show($msg, $hog.Programm, 'YesNo', 'Question')
        if ($ans -eq 'Yes') {
            Invoke-SysPilotHogAction -Hog $hog
            Update-SysPilotGui
        }
    } else {
        [System.Windows.MessageBox]::Show($msg, $hog.Programm, 'OK', 'Information') | Out-Null
        if ($hog.Link) {
            $ans = [System.Windows.MessageBox]::Show("Anleitung im Browser oeffnen?", $hog.Programm, 'YesNo', 'Question')
            if ($ans -eq 'Yes') { Start-Process $hog.Link }
        }
    }
})

# --- Tray-Icon (ausgeblendete Symbole) ---
function Set-SysPilotTrayTooltip {
    param([string]$Text)
    if (-not $script:notifyIcon) { return }
    $safeText = ([string]$Text).Trim()
    if ($safeText.Length -gt 63) { $safeText = $safeText.Substring(0, 63) }
    if (-not $safeText) { $safeText = 'SysPilot' }
    if ($script:notifyIcon.Text -ne $safeText) {
        $wasVisible = $script:notifyIcon.Visible
        $script:notifyIcon.Text = $safeText
        # Windows aktualisiert NotifyIcon-Tooltips nicht immer bei laufendem Symbol.
        if ($wasVisible) { $script:notifyIcon.Visible = $false; $script:notifyIcon.Visible = $true }
    }
}

$script:notifyIcon = New-Object System.Windows.Forms.NotifyIcon
# Eigenes Icon: blauer Kreis mit "S"
$bmp = New-Object System.Drawing.Bitmap 32, 32
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = 'AntiAlias'
$g.FillEllipse((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(79,195,247))), 2, 2, 28, 28)
$g.DrawString('S', (New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)), [System.Drawing.Brushes]::White, 4, 2)
$g.Dispose()
$script:notifyIcon.Icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
Set-SysPilotTrayTooltip 'SysPilot - PC wird ueberwacht'
$script:notifyIcon.Visible = $true
$script:notifyIcon.BalloonTipTitle = 'SysPilot'
$script:notifyIcon.BalloonTipText = 'Doppelklick öffnet das Dashboard; Rechtsklick zeigt Aktionen.'

# Rechtsklick-Menue
$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$miShow   = $trayMenu.Items.Add('SysPilot anzeigen')
$miShow.Font = New-Object System.Drawing.Font($trayMenu.Font, [System.Drawing.FontStyle]::Bold)
$miCool   = $trayMenu.Items.Add('Kuehl-Modus (Leise)')
$miPerf   = $trayMenu.Items.Add('Leistungs-Modus')
$miFree   = $trayMenu.Items.Add('RAM jetzt freigeben')
$trayMenu.Items.Add('-') | Out-Null

$miGame = $trayMenu.Items.Add('Gaming-Schutz: Spiele ungestoert')
$miGame.Enabled = $false
$trayMenu.Items.Add('-') | Out-Null

$miTrayStart = New-Object System.Windows.Forms.ToolStripMenuItem 'Beim Start nur im Tray (ohne Fenster)'
$miTrayStart.CheckOnClick = $true
$miTrayStart.Checked = [bool]($startCfg -and $startCfg.PSObject.Properties['StartInTray'] -and $startCfg.StartInTray)
$trayMenu.Items.Add($miTrayStart) | Out-Null

$miGuardian = New-Object System.Windows.Forms.ToolStripMenuItem 'Guardian (Waecher-Schutz aktiv)'
$miGuardian.CheckOnClick = $true
$gCfg = Get-SysPilotGuardianConfig
$miGuardian.Checked = [bool]($gCfg.Enabled)
$trayMenu.Items.Add($miGuardian) | Out-Null

$trayMenu.Items.Add('-') | Out-Null
$miUpdate = $trayMenu.Items.Add('Nach Updates suchen')
$miUpdAtStart = New-Object System.Windows.Forms.ToolStripMenuItem 'Beim Start nach Updates suchen'
$miUpdAtStart.CheckOnClick = $true
$miUpdAtStart.Checked = [bool](Test-SysPilotUpdateAtStart)
$trayMenu.Items.Add($miUpdAtStart) | Out-Null
$trayMenu.Items.Add('-') | Out-Null
$miExit   = $trayMenu.Items.Add('Beenden')
$script:notifyIcon.ContextMenuStrip = $trayMenu

$miShow.Add_Click({ $win.Show(); $win.WindowState = 'Normal'; $win.Activate() })
$miCool.Add_Click({ Set-PlanWithFeedback -Mode Cool -Label 'KUEHL' })
$miPerf.Add_Click({ Set-PlanWithFeedback -Mode Performance -Label 'LEISTUNG' })
$miFree.Add_Click({ Clear-SysPilotWorkingSets | Out-Null; if (Test-SysPilotAdmin) { Clear-SysPilotStandbyList | Out-Null } })
$miTrayStart.Add_Click({ Set-SysPilotConfigValue -Section 'Start' -Key 'StartInTray' -Value ([bool]$miTrayStart.Checked) })
$miGuardian.Add_Click({
    $enable = [bool]$miGuardian.Checked
    Save-SysPilotGuardianConfig -Enabled $enable -StartMode 'TrayOnly'
    if ($enable) { Install-SysPilotGuardian | Out-Null } else { Remove-SysPilotGuardian }
})
$miUpdate.Add_Click({ Show-SysPilotWindow; Invoke-SysPilotGuiUpdateClick })
$miUpdAtStart.Add_Click({ Set-SysPilotConfigValue -Section 'Update' -Key 'CheckAtStart' -Value ([bool]$miUpdAtStart.Checked) })
# Bewusstes Beenden: der Guardian startet SysPilot dann nicht sofort wieder (bis zur naechsten Anmeldung)
$miExit.Add_Click({
    try { Set-SysPilotGuardianPause } catch { }
    $script:reallyClose = $true
    try { $script:notifyIcon.Visible = $false; $script:notifyIcon.Dispose() } catch { }
    $win.Close()
})
$script:notifyIcon.Add_DoubleClick({ $win.Show(); $win.WindowState = 'Normal'; $win.Activate() })

# Minimieren -> im Tray verstecken statt Taskleiste belasten
$win.Add_StateChanged({
    if ($win.WindowState -eq 'Minimized') {
        $win.Hide()
    }
})

# Schliessen -> in Tray minimieren (nicht beenden), es sei denn wirklich beenden
$script:reallyClose = $false
$win.Add_Closing({
    param($s, $e)
    if (-not $script:reallyClose) {
        $e.Cancel = $true
        $win.Hide()
        # Keine stoerenden Balloontips waehrend des Spielens
        if (-not (Test-SysPilotGamingActive)) {
            $script:notifyIcon.ShowBalloonTip(2000, 'SysPilot', 'Laeuft im Hintergrund weiter. Rechtsklick aufs Symbol -> Beenden.', 'Info')
        }
    } else {
        try {
            $script:notifyIcon.Visible = $false
            $script:notifyIcon.Dispose()
        } catch { }
    }
})

# Nicht in den Vordergrund draengeln: kein automatisches Activate/Topmost
$win.Topmost = $false
$win.ShowInTaskbar = $true

# --- Tastatur-Steuerung: Pfeiltasten durch Buttons, Enter = ausfuehren, Esc = schließen ---
$win.Add_KeyDown({
    param($s, $e)
    if ($e.Key -eq 'Escape') { $win.Close(); return }
    if ($e.Key -eq 'Left' -or $e.Key -eq 'Right' -or $e.Key -eq 'Up' -or $e.Key -eq 'Down') {
        $buttons = @($ctrl.BtnCheckup, $ctrl.BtnToolbox, $ctrl.BtnAuto, $ctrl.BtnCool, $ctrl.BtnPerf, $ctrl.BtnFreeRam, $ctrl.BtnPriorities, $ctrl.BtnGaming, $ctrl.BtnWork, $ctrl.BtnNight, $ctrl.BtnLHM, $ctrl.BtnMenu)
        $buttons = @($ctrl.BtnUpdate) + $buttons
        if ($ctrl.BtnAdmin.Visibility -eq 'Visible') { $buttons = @($ctrl.BtnAdmin) + $buttons }
        $focused = [System.Windows.Input.Keyboard]::FocusedElement
        $idx = [Array]::IndexOf($buttons, $focused)
        if ($idx -lt 0) { $idx = 0 }
        if ($e.Key -eq 'Right' -or $e.Key -eq 'Down') { $idx = ($idx + 1) % $buttons.Count }
        else { $idx = ($idx - 1 + $buttons.Count) % $buttons.Count }
        $buttons[$idx].Focus() | Out-Null
        $e.Handled = $true
    }
})

# Live-Timer (2 Sekunden)
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(2)
$timer.Add_Tick({ Update-SysPilotGui })
$timer.Start()

# Zweiter Start (Verknuepfung) waehrend die GUI im Tray laeuft -> Fenster zeigen (nicht wenn ein Spiel laeuft)
$showTimer = New-Object System.Windows.Threading.DispatcherTimer
$showTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$showTimer.Add_Tick({
    if ($script:showEvt -and $script:showEvt.WaitOne(0)) {
        if (-not (Test-SysPilotGamingActive)) {
            $win.Show(); $win.WindowState = 'Normal'; $win.Activate() | Out-Null
        }
    }
})
$showTimer.Start()

# Beim Start (nach 6 Sek.) im Hintergrund nach Updates suchen (per leichtem Runspace statt schwerem Prozess-Job)
$script:updRs = $null
$script:updPs = $null
$script:updAsync = $null

$updStart = New-Object System.Windows.Threading.DispatcherTimer
$updStart.Interval = [TimeSpan]::FromSeconds(6)
$updPoll = New-Object System.Windows.Threading.DispatcherTimer
$updPoll.Interval = [TimeSpan]::FromSeconds(1)

$updStart.Add_Tick({
    $updStart.Stop()
    if (-not (Test-SysPilotUpdateAtStart)) { return }
    try {
        $modPath = Join-Path $script:Root 'modules\Updater.psm1'
        $script:updRs = [runspacefactory]::CreateRunspace()
        $script:updRs.ApartmentState = 'STA'; $script:updRs.ThreadOptions = 'ReuseThread'
        $script:updRs.Open()
        $script:updRs.SessionStateProxy.SetVariable('modPath', $modPath)
        $script:updPs = [powershell]::Create()
        $script:updPs.Runspace = $script:updRs
        [void]$script:updPs.AddScript({
            Import-Module $modPath -Force -Global -WarningAction SilentlyContinue
            Test-SysPilotUpdate
        })
        $script:updAsync = $script:updPs.BeginInvoke()
        $updPoll.Start()
    } catch { }
})

$updPoll.Add_Tick({
    if (-not $script:updAsync) { $updPoll.Stop(); return }
    if ($script:updAsync.IsCompleted) {
        $updPoll.Stop()
        try {
            $res = $script:updPs.EndInvoke($script:updAsync)
            $info = $res | Select-Object -Last 1
            $script:updPs.Dispose(); $script:updRs.Close(); $script:updRs.Dispose()
            $script:updPs = $null; $script:updRs = $null; $script:updAsync = $null

            if ($info -and $info.Newer) {
                $script:updateInfo = $info
                Set-SysPilotGuiUpdateAvailable $info
                # Spiele-Schutz: Ballon-Tip nur zeigen, wenn gerade KEIN Spiel laeuft!
                if (-not (Test-SysPilotGamingActive)) {
                    $script:notifyIcon.ShowBalloonTip(5000, 'SysPilot Update', "Neue Version $($info.Latest) verfuegbar. Im SysPilot-Fenster auf 'Updates' klicken.", 'Info')
                }
            }
        } catch { }
    }
})
$updStart.Start()

Update-SysPilotGui

$isGameActive = Test-SysPilotGamingActive
$startInTray = [bool]($StartHidden -or $isGameActive -or ($startCfg -and $startCfg.PSObject.Properties['StartInTray'] -and $startCfg.StartInTray))
if ($startInTray) {
    # Direkt in den Tray starten (z.B. Autostart, Guardian oder waehrend ein Spiel laeuft)
    $script:notifyIcon.Visible = $true
    $win.Hide()
    if (-not $isGameActive) {
        $script:notifyIcon.ShowBalloonTip(2500, 'SysPilot', 'Laeuft im Hintergrund weiter. Doppelklick aufs Tray-Symbol oeffnet das Dashboard.', 'Info')
    }
} else {
    $win.Show()
}

$win.ShowDialog() | Out-Null
$timer.Stop()
$showTimer.Stop()
$updStart.Stop(); $updPoll.Stop()
if ($script:updPs) {
    try { $script:updPs.Dispose(); $script:updRs.Close(); $script:updRs.Dispose() } catch { }
}
$script:notifyIcon.Visible = $false
$script:notifyIcon.Dispose()
if ($script:guiMutex) { $script:guiMutex.ReleaseMutex() | Out-Null; $script:guiMutex.Dispose() }
Icon.Visible = $false
$script:notifyIcon.Dispose()
if ($script:guiMutex) { $script:guiMutex.ReleaseMutex() | Out-Null; $script:guiMutex.Dispose() }
