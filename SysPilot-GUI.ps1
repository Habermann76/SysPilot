# SysPilot GUI - schlanke WPF-Oberflaeche (kein Electron, ~40-60 MB RAM)
#Requires -Version 5.1
param([switch]$AsAdmin)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Get-ChildItem (Join-Path $script:Root 'modules') -Filter '*.psm1' | ForEach-Object {
    Import-Module $_.FullName -Force -Global -WarningAction SilentlyContinue
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
      <TextBlock x:Name="AdminBadge" Text="" FontSize="11" Foreground="#FF81C784" VerticalAlignment="Center" Margin="12,0,0,0"/>
      <TextBlock x:Name="PlanBadge" Text="" FontSize="11" Foreground="#FFFFB74D" VerticalAlignment="Center" Margin="12,0,0,0"/>
      <TextBlock x:Name="WatchBadge" Text="  PC wird ueberwacht" FontSize="11" Foreground="#FF81C784" VerticalAlignment="Center" Margin="12,0,0,0"/>
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
              <GridViewColumn Header="Massnahme" Width="280"><GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Massnahme}" Foreground="#FF81C784" TextWrapping="Wrap"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
            </GridView>
          </ListView.View>
        </ListView>
      </Grid>
    </Border>

    <!-- Aktionen -->
    <Border Grid.Row="4" Background="#FF252538" CornerRadius="8" Padding="8" Margin="0,10,0,0">
      <WrapPanel HorizontalAlignment="Center">
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
                 'SysCpu','SysProcs','SysBattery','SysUptime','HogList','AdminBadge','PlanBadge','WatchBadge',
                 'TempBig','TempStatus','TempSource','TempUnitLabel',
                 'BtnCool','BtnPerf','BtnFreeRam','BtnPriorities','BtnGaming','BtnWork','BtnNight','BtnLHM','BtnMenu') {
    $ctrl[$n] = $win.FindName($n)
}

# Admin-Badge
$ctrl.AdminBadge.Text = if (Test-SysPilotAdmin) { "ADMIN" } else { "eingeschraenkt" }
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
    $ctrl.PlanBadge.Text = switch ($mode) { 'Cool' { 'Plan: KUEHL' } 'Performance' { 'Plan: LEISTUNG' } default { 'Plan: fremd' } }

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
                if ($h.Programm -like "*$($k.Name)*" -or $k.Name -like "*$($h.Programm)*") { $h.Massnahme = $k.Fix; break }
            }
        }
        $ctrl.HogList.ItemsSource = $hogs
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

# Buttons
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
            Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"Import-Module '$script:Root\modules\Temperature.psm1' -Force; Import-Module '$script:Root\modules\Common.psm1' -Force; Install-SysPilotLHM; Start-Process powershell.exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','$scriptPath'`""
        }
    }
    Update-SysPilotGui
})
$ctrl.BtnMenu.Add_Click({
    Start-Process powershell.exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $script:Root 'SysPilot.ps1')
})

# --- Tray-Icon (ausgeblendete Symbole) ---
$script:notifyIcon = New-Object System.Windows.Forms.NotifyIcon
# Eigenes Icon: blauer Kreis mit "S"
$bmp = New-Object System.Drawing.Bitmap 32, 32
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = 'AntiAlias'
$g.FillEllipse((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(79,195,247))), 2, 2, 28, 28)
$g.DrawString('S', (New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)), [System.Drawing.Brushes]::White, 4, 2)
$g.Dispose()
$script:notifyIcon.Icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
$script:notifyIcon.Text = "SysPilot - PC wird ueberwacht"
$script:notifyIcon.Visible = $true

# Rechtsklick-Menue
$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$miShow   = $trayMenu.Items.Add('SysPilot anzeigen')
$miCool   = $trayMenu.Items.Add('Kuehl-Modus')
$miPerf   = $trayMenu.Items.Add('Leistung')
$miFree   = $trayMenu.Items.Add('RAM freigeben')
$trayMenu.Items.Add('-') | Out-Null
$miExit   = $trayMenu.Items.Add('Beenden')
$script:notifyIcon.ContextMenuStrip = $trayMenu

$miShow.Add_Click({ $win.Show(); $win.WindowState = 'Normal'; $win.Activate() })
$miCool.Add_Click({ Set-PlanWithFeedback -Mode Cool -Label 'KUEHL' })
$miPerf.Add_Click({ Set-PlanWithFeedback -Mode Performance -Label 'LEISTUNG' })
$miFree.Add_Click({ Clear-SysPilotWorkingSets | Out-Null; if (Test-SysPilotAdmin) { Clear-SysPilotStandbyList | Out-Null } })
$miExit.Add_Click({ $script:reallyClose = $true; $win.Close() })
$script:notifyIcon.Add_DoubleClick({ $win.Show(); $win.WindowState = 'Normal'; $win.Activate() })

# Schliessen -> in Tray minimieren (nicht beenden), es sei denn wirklich beenden
$script:reallyClose = $false
$win.Add_Closing({
    param($s, $e)
    if (-not $script:reallyClose) {
        $e.Cancel = $true
        $win.Hide()
        $script:notifyIcon.ShowBalloonTip(2000, 'SysPilot', 'Laeuft im Hintergrund weiter. Rechtsklick aufs Symbol -> Beenden.', 'Info')
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
        $buttons = @($ctrl.BtnCool, $ctrl.BtnPerf, $ctrl.BtnFreeRam, $ctrl.BtnPriorities, $ctrl.BtnGaming, $ctrl.BtnWork, $ctrl.BtnNight, $ctrl.BtnLHM, $ctrl.BtnMenu)
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

Update-SysPilotGui
$win.ShowDialog() | Out-Null
$timer.Stop()
$script:notifyIcon.Visible = $false
$script:notifyIcon.Dispose()
