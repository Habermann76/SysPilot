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

    if (-not $StartHidden) {
        # Expliziter Nutzer-Klick (Verknuepfung) holt das Fenster IMMER zurueck.
        # Nur der Fokus wird beim Spielen geschont (Fenster erscheint ohne
        # Aktivierung im Vordergrund, Ballons/Auto-Popups bleiben weiterhin
        # durch den Gaming-Schutz unterdrueckt).
        try { $evt = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', 'Local\SysPilotGUI-Show'); $evt.Set() | Out-Null } catch { }
        $existing = [SysPilotWin]::FindGuiWindow()
        if ($existing -ne [IntPtr]::Zero) {
            if ($isGamingNow) {
                [SysPilotWin]::ShowWindow($existing, 4) | Out-Null    # SW_SHOWNOACTIVATE
            } else {
                [SysPilotWin]::ShowWindow($existing, 9) | Out-Null    # SW_RESTORE
                [SysPilotWin]::SetForegroundWindow($existing) | Out-Null
            }
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
    try {
        Import-Module $_.FullName -Force -Global -WarningAction SilentlyContinue
        $m = Get-Module $_.BaseName
        if (-not $m -or $m.Path -ne $_.FullName) { throw "Modul nicht geladen" }
    } catch {
        $first = ($_.Exception.Message -split "`r?`n")[0]
        try { Write-SysPilotLog "MODUL-IMPORT FEHLER (GUI): $($_.BaseName) - $($_.Exception.Message)" } catch { }
        try { [System.Windows.MessageBox]::Show("Modul $($_.BaseName) fehlgeschlagen:`n$first", 'SysPilot', 'OK', 'Warning') | Out-Null } catch { }
    }
}

# PowerShell-7-Umschaltung (config.json Start.PwshMode): unter powershell.exe
# gestartet, aber Modus verlangt pwsh -> einmalig weiterreichen (Env-Guard).
if (-not $env:SYSPILOT_PWSH_RELAUNCHED -and $PSVersionTable.PSEdition -eq 'Desktop') {
    try {
        if (Get-Command Get-SysPilotPreferredShell -ErrorAction SilentlyContinue) {
            $sh = Get-SysPilotPreferredShell
            if ($sh.IsPwsh -and $sh.Exe -ne 'powershell.exe') {
                $fwd = @('-STA','-NoProfile','-File',"`"$PSCommandPath`"")
                if ($AsAdmin) { $fwd += '-AsAdmin' }
                if ($StartHidden) { $fwd += '-StartHidden' }
                $env:SYSPILOT_PWSH_RELAUNCHED = '1'
                Start-Process $sh.Exe -ArgumentList $fwd | Out-Null
                exit
            }
        }
    } catch {}
}

# Option "Immer als Administrator": ohne Rueckfrage erhoeht neu starten
$startCfg = (Get-SysPilotConfig).Start
if (-not (Test-SysPilotAdmin) -and $startCfg -and $startCfg.AlwaysAdmin) {
    Restart-SysPilotElevated
}

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="SysPilot" Width="780" Height="780" MinWidth="700" MinHeight="640"
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
    <!-- Milchige Auswahl (wie in allen anderen Fenstern): hell transluzent + dunkle Schrift -->
    <Style TargetType="ListViewItem">
      <Setter Property="Padding" Value="8,5"/>
      <Setter Property="Foreground" Value="#FFEAEAF2"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#FF34344E"/></Trigger>
        <Trigger Property="IsSelected" Value="True">
          <Setter Property="Background" Value="#CCE4EAF2"/>
          <Setter Property="Foreground" Value="#FF1E1E2E"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="ListBoxItem">
      <Setter Property="Padding" Value="6,4"/>
      <Setter Property="Foreground" Value="#FFEAEAF2"/>
      <Setter Property="FontSize" Value="12"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#FF34344E"/></Trigger>
        <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#CCE4EAF2"/><Setter Property="Foreground" Value="#FF1E1E2E"/></Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="#FFE0E0E0"/><Setter Property="Background" Value="Transparent"/>
      <Setter Property="Padding" Value="8,4"/>
      <Style.Triggers>
        <Trigger Property="IsHighlighted" Value="True"><Setter Property="Background" Value="#FF34344E"/><Setter Property="Foreground" Value="#FFEAEAF2"/></Trigger>
        <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#CCE4EAF2"/><Setter Property="Foreground" Value="#FF1E1E2E"/></Trigger>
      </Style.Triggers>
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
        <TextBlock x:Name="TempUnitLabel" Text=" Grad C" FontSize="22" Foreground="#FF9E9E9E" VerticalAlignment="Center" Margin="4,0,14,0"/>
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
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,6">
          <TextBlock Text="Top Ressourcen-Fresser" FontWeight="Bold" VerticalAlignment="Center"/>
          <TextBlock Text="  Sort:" Foreground="#FF9E9E9E" VerticalAlignment="Center" Margin="14,0,4,0"/>
          <TextBlock x:Name="SortRam" Text="RAM" Foreground="#FF81C784" FontWeight="Bold" Cursor="Hand" Margin="4,0" ToolTip="Nach RAM-Verbrauch sortieren (Standard)"/>
          <TextBlock x:Name="SortCpu" Text="CPU %" Foreground="#FF9E9E9E" Cursor="Hand" Margin="4,0" ToolTip="Nach aktueller CPU-Auslastung sortieren"/>
          <TextBlock x:Name="SortName" Text="Name" Foreground="#FF9E9E9E" Cursor="Hand" Margin="4,0" ToolTip="Alphabetisch sortieren"/>
        </StackPanel>
        <ListView x:Name="HogList" Grid.Row="2" Background="Transparent" BorderThickness="0" Foreground="#FFE0E0E0">
          <ListView.View>
            <GridView>
              <GridViewColumn Header="Programm" Width="180"><GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Programm}"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
              <GridViewColumn Header="RAM MB" Width="80"><GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding RAM_MB}"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
              <GridViewColumn Header="RAM %" Width="65"><GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding RAM_Pct}"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
              <GridViewColumn Header="CPU %" Width="65"><GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding CPU_Pct, StringFormat={}{0:0.#}%}"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
              <GridViewColumn Header="CPU s" Width="70"><GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding CPU_s}"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
              <GridViewColumn Header="x" Width="30"><GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Instanzen}"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
              <GridViewColumn Header="Massnahme" Width="250"><GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Massnahme}" TextWrapping="Wrap" ToolTip="{Binding HowTo}"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
            </GridView>
          </ListView.View>
        </ListView>
        <TextBlock x:Name="HogTip" Grid.Row="3" Text="" FontSize="11" Foreground="#FF9E9E9E" TextWrapping="Wrap" Margin="0,6,0,0"/>
      </Grid>
    </Border>

    <!-- Aktionen -->
    <Border Grid.Row="4" Background="#FF252538" CornerRadius="8" Padding="8" Margin="0,10,0,0">
      <ScrollViewer MaxHeight="118" VerticalScrollBarVisibility="Auto">
      <WrapPanel HorizontalAlignment="Center">
        <Button x:Name="BtnCheckup" Content="CHECKUP" FontWeight="Bold" ToolTip="Automatic Checkup: Komplett-Scan mit Erklaerungen und Reparatur"/>
        <Button x:Name="BtnToolbox" Content="Toolbox" ToolTip="Alle Werkzeuge nach Kategorien"/>
        <Button x:Name="BtnDns" Content="DNS" ToolTip="DNS je Adapter pruefen, testen, sichern und sicher aendern"/>
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
        <Button x:Name="BtnHealth" Content="Health" ToolTip="SMART Health Monitor: Festplatten, Temperatur, Batterie, Uptime"/>
        <Button x:Name="BtnUpdates" Content="Softwarecenter" ToolTip="Softwarecenter: Updates (winget+Chocolatey), Programm-Suche/Store, Downloads (Katalog, GitHub, MajorGeeks)"/>
        <Button x:Name="BtnDlFind" Content="DL-Suche" ToolTip="KI-Pseudo-Paketmanager: sucht Download-Links ueber Paketmanager, Web-Kataloge, Suchmaschinen und Herbert-KI"/>
        <Button x:Name="BtnAppSearch" Content="App-Suche" ToolTip="Programm-Suche in ALLEN Paketmanagern (winget/choco/scoop/npm/pip/dotnet/PSGallery) + SmartDownload Web/Katalog/Herbert - Treffer installierbar"/>
        <Button x:Name="BtnDrvStudio" Content="DrvStudio" ToolTip="SmartDriver Studio: Hardware-Analyse, Multi-Select-Treiber, Backup, selbsttaetige Installation"/>
        <Button x:Name="BtnKi" Content="KI" FontWeight="Bold" ToolTip="KI-Assistenz: Chat mit kostenlosen Providern (lokal + Cloud), Fehleranalyse, Einstellungshilfe"/>
        <Button x:Name="BtnProcs" Content="Prozesse" ToolTip="Task-Manager: Prozesse auflisten, beenden, starten, analysieren, Process Explorer"/>
        <Button x:Name="BtnCf" Content="CF" ToolTip="Cloudflare: WARP 1.1.1.1, Tunnel (quick/named), CF-geschuetzte Downloads"/>
        <Button x:Name="BtnCare" Content="Care" ToolTip="Systempflege-Center: Registry-Cleaner, File-Shredder, Privacy-Erase, Disk-Optimize, Timeline, Passwort-Generator, Boot-Analyse"/>
        <Button x:Name="BtnTweaks" Content="Tweak" ToolTip="Tweak-Studio: Registry-/Dienst-Tweaks, Kontextmenue (PowerShell hier/Admin), Explorer, Leistung - mit .reg-Backup und Favoriten"/>
        <Button x:Name="BtnRegGal" Content="RegGal" ToolTip="Registry-Galerie: kuratierte .reg-Dateien nach Themen, Risiko-Scan, KI-Pruefung, Backup/Restore"/>
      </WrapPanel>
      </ScrollViewer>
    </Border>

    <!-- Schwebender KI-Assistent: Button + aufklappbarer Chat (Overlay, oberste Ebene, verschiebbar) -->
    <Canvas x:Name="KiOverlay" Grid.Row="0" Grid.RowSpan="5">
      <Border x:Name="KiChatPanel" Width="560" MaxHeight="500" Visibility="Collapsed"
              Background="#F21B1B2E" BorderBrush="#FF4A4A6A" BorderThickness="1" CornerRadius="10" Padding="10"
              ToolTip="KI-Assistent - Kopfzeile ziehen zum Verschieben">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <Border x:Name="KiChatHeader" Background="#FF2D2D44" CornerRadius="6" Padding="8,5">
            <DockPanel>
              <Button x:Name="BtnKiClose" Content="x" DockPanel.Dock="Right" Padding="7,0" FontSize="11" ToolTip="Chat schliessen"/>
              <Button x:Name="BtnKiMenu" Content="Menue" DockPanel.Dock="Right" Padding="8,1" FontSize="10"
                      Background="#FF2D2D44" Foreground="#FFFFB74D" BorderBrush="#FF4A4A6A" BorderThickness="1" Cursor="Hand"
                      VerticalAlignment="Center" Margin="0,0,8,0" ToolTip="Alle KI-Assistent-Funktionen (Setup, Tools, News, Modelle ...)"/>
              <Button x:Name="BtnKiProviders" Content="Provider" DockPanel.Dock="Right" Padding="8,1" FontSize="10"
                      Background="#FF2D2D44" Foreground="#FF9CCBFF" BorderBrush="#FF4A4A6A" BorderThickness="1" Cursor="Hand"
                      VerticalAlignment="Center" Margin="0,0,8,0" ToolTip="KI-Provider verwalten (Keys, Endpoints, kostenlose Anbieter)"/>
              <Button x:Name="BtnKiPerm" Content="Perm" DockPanel.Dock="Right" Padding="8,1" FontSize="10"
                      Background="#FF2D2D44" Foreground="#FFFFCC80" BorderBrush="#FF4A4A6A" BorderThickness="1" Cursor="Hand"
                      VerticalAlignment="Center" Margin="0,0,8,0" ToolTip="Permissions: Modus (Fragen/Auto-allow/Bypass) + Overrides pro Aktion/MCP-Werkzeug"/>
              <Button x:Name="BtnKiExt" Content="MCP" DockPanel.Dock="Right" Padding="8,1" FontSize="10"
                      Background="#FF2D2D44" Foreground="#FF9CCC65" BorderBrush="#FF4A4A6A" BorderThickness="1" Cursor="Hand"
                      VerticalAlignment="Center" Margin="0,0,8,0" ToolTip="Installierte MCP-Server + Skills, Katalog oeffnen"/>
              <CheckBox x:Name="ChkKiHints" Content="Hinweise" DockPanel.Dock="Right" FontSize="10" Foreground="#FF9E9E9E"
                        VerticalAlignment="Center" Margin="0,0,4,0" ToolTip="Pilot Herbert: Hinweise bei Programmstarts (stumm schaltbar)"/>
              <CheckBox x:Name="ChkKiAnn" Content="Ansagen" DockPanel.Dock="Right" FontSize="10" Foreground="#FF9E9E9E"
                        VerticalAlignment="Center" Margin="0,0,8,0" ToolTip="Pilot Herbert: Bord-Ansagen (Flug-Ansagen, Wetteraussprueche) - separat stumm schaltbar"/>
              <TextBlock Text="PILOT HERBERT - FLUG 667" FontWeight="Bold" Foreground="#FF4FC3F7" VerticalAlignment="Center"/>
              <TextBlock Text="ziehen" Foreground="#FF9E9E9E" FontSize="10" VerticalAlignment="Center" Margin="10,0,0,0"/>
            </DockPanel>
          </Border>
          <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,6,0,0">
            <TextBlock Text="Provider:" VerticalAlignment="Center" Foreground="#FF9E9E9E" FontSize="11"/>
            <ComboBox x:Name="CmbKiProvider" Width="180" Margin="4,0,10,0" VerticalAlignment="Center"
                      Background="#FF252538" Foreground="#FFEAEAF2" ToolTip="KI-Provider (Auto = Fallback-Kette)"/>
            <TextBlock Text="Modell:" VerticalAlignment="Center" Foreground="#FF9E9E9E" FontSize="11"/>
            <ComboBox x:Name="CmbKiModel" Width="230" Margin="4,0,0,0" VerticalAlignment="Center" IsEditable="True"
                      Background="#FF252538" Foreground="#FFEAEAF2" ToolTip="Modell des Providers (leer = automatisch)"/>
            <Button x:Name="BtnKiNew" Content="+ Neu" FontSize="10" Padding="8,2" Margin="10,0,0,0" VerticalAlignment="Center"
                    ToolTip="Neuen Chat starten (Verlauf wird geleert)"/>
          </StackPanel>
          <ScrollViewer x:Name="KiChatScroll" Grid.Row="2" Margin="0,8,0,0" VerticalScrollBarVisibility="Auto">
            <StackPanel x:Name="KiChatLog"/>
          </ScrollViewer>
          <Grid Grid.Row="3" Margin="0,8,0,0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBox x:Name="KiChatInput" Padding="6,4" FontSize="12" TextWrapping="Wrap" AcceptsReturn="False"
                     Background="#FF14141F" Foreground="#FFE0E0E0" BorderBrush="#FF4A4A6A" CaretBrush="#FF4FC3F7"
                     ToolTip="Frage an den KI-Assistenten (Enter = senden, Strg+V = Bild anhaengen)"/>
            <Button x:Name="BtnKiSend" Grid.Column="1" Content="Senden" FontSize="11" Padding="10,4" Margin="6,0,0,0" ToolTip="Nachricht senden"/>
          </Grid>
        </Grid>
      </Border>
      <Button x:Name="BtnKiFloat" Content="KI" Width="46" Height="46" FontSize="17" FontWeight="Bold"
              ToolTip="KI-Assistent - schwebender Chat (ziehen zum Verschieben, Klick = auf/zu)"/>
    </Canvas>
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
                 'SysCpu','SysProcs','SysBattery','SysUptime','HogList','HogTip','AdminBadge','PlanBadge','WatchBadge','VersionBadge',
                 'TempBig','TempStatus','TempSource','TempUnitLabel',
                 'BtnCheckup','BtnToolbox','BtnDns','BtnAuto','BtnCool','BtnPerf','BtnFreeRam','BtnPriorities','BtnGaming','BtnWork','BtnNight','BtnLHM','BtnMenu','BtnHealth','BtnUpdates','BtnDlFind','BtnAppSearch','BtnDrvStudio','BtnAdmin','BtnUpdate','BtnKi','BtnProcs','BtnCf','BtnCare','BtnTweaks','BtnRegGal') {
    $ctrl[$n] = $win.FindName($n)
}

# Admin-Badge
$isAdmin = Test-SysPilotAdmin
$ctrl.AdminBadge.Text = if ($isAdmin) { "ADMIN" } else { "eingeschraenkt" }
$ctrl.BtnAdmin.Visibility = if ($isAdmin) { 'Collapsed' } else { 'Visible' }
$script:tick = 0
$script:hogCpuPrev = @{}
$script:hogSort = 'RAM_MB'
$script:hogTips = $null

# === Schwebender KI-Assistent (Overlay) ===
foreach ($n in 'KiOverlay','KiChatPanel','KiChatHeader','KiChatLog','KiChatScroll','KiChatInput','BtnKiSend','BtnKiClose','BtnKiFloat','ChkKiHints','ChkKiAnn','BtnKiProviders','BtnKiPerm','BtnKiExt','BtnKiMenu','CmbKiProvider','CmbKiModel','BtnKiNew') {
    $ctrl[$n] = $win.FindName($n)
}
$script:kiHistory = @()
$script:kiBusy = $false
$script:kiMode = 'chat'   # 'chat' | 'action' | 'mcp'
$script:kiActionLabel = ''
$script:kiMcpInfo = $null
$script:kiMcpEnabled = $false
$script:herbertKnown = @{}
$script:herbertBaselineDone = $false
$script:herbertLastAlert = [datetime]::MinValue
$script:herbertLastBalloon = [datetime]::MinValue
$script:herbertRecent = @()
$script:herbertSession = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
$script:herbertExclude = @('SysPilot','powershell','pwsh','WindowsTerminal','explorer','TextInputHost','SearchHost','StartMenuExperienceHost','ShellExperienceHost','ApplicationFrameHost','SystemSettings','backgroundTaskHost','MoUsoCoreWorker','PhoneExperienceHost','WidgetBoard','Widgets','MicrosoftEdgeUpdate','YourPhone','SecurityHealthSystray','SecurityHealthService','ctfmon','dllhost','WmiPrvSE','taskhostw','smartscreen','RuntimeBroker','ShellHost','StartMenuExperienceHost')
$script:kiWelcomeDone = $false
$script:kiDragEl = $null
$script:kiDragTarget = $null
$script:kiDragStart = $null
$script:kiDragOrig = $null
$script:kiMoved = $false
$script:kiPanelPlaced = $false
$script:kiLogPos = -1
$script:kiLogFile = $null
$script:kiWatchTick = 0
$script:kiPendingErrors = 0
$script:kiThinkMsg = $null
$script:kiImages = @()
$script:kiMdlJob = $null
$script:kiPendingModel = $null
$script:kiMdlTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:kiMdlTimer.Interval = [TimeSpan]::FromMilliseconds(700)

function Add-SysPilotKiDrag {
    <# Macht ein Overlay-Element (Button oder Panel-Kopf) verschiebbar.
       Der Kopf des Chat-Panels bewegt das Panel, nicht sich selbst. #>
    param($el)
    $el.Add_MouseLeftButtonDown({
        param($s,$e)
        $s.CaptureMouse() | Out-Null
        $script:kiDragEl = $s
        $script:kiDragTarget = if ($s.Name -eq 'KiChatHeader') { $ctrl.KiChatPanel } else { $s }
        $script:kiDragStart = $e.GetPosition($ctrl.KiOverlay)
        $script:kiDragOrig = @([Windows.Controls.Canvas]::GetLeft($script:kiDragTarget), [Windows.Controls.Canvas]::GetTop($script:kiDragTarget))
        $script:kiMoved = $false
        $e.Handled = $true
    })
    $el.Add_MouseMove({
        param($s,$e)
        if ($script:kiDragEl -ne $s -or -not $script:kiDragTarget -or -not $script:kiDragStart) { return }
        $p = $e.GetPosition($ctrl.KiOverlay)
        $dx = $p.X - $script:kiDragStart.X
        $dy = $p.Y - $script:kiDragStart.Y
        if ([math]::Abs($dx) -gt 4 -or [math]::Abs($dy) -gt 4) { $script:kiMoved = $true }
        $maxL = [math]::Max(0, $ctrl.KiOverlay.ActualWidth - $script:kiDragTarget.ActualWidth - 8)
        $maxT = [math]::Max(0, $ctrl.KiOverlay.ActualHeight - $script:kiDragTarget.ActualHeight - 8)
        [Windows.Controls.Canvas]::SetLeft($script:kiDragTarget, [math]::Max(0, [math]::Min($maxL, $script:kiDragOrig[0] + $dx)))
        [Windows.Controls.Canvas]::SetTop($script:kiDragTarget, [math]::Max(0, [math]::Min($maxT, $script:kiDragOrig[1] + $dy)))
    })
    $el.Add_MouseLeftButtonUp({
        param($s,$e)
        $s.ReleaseMouseCapture() | Out-Null
        if ($script:kiDragEl -eq $s) { $script:kiDragEl = $null; $script:kiDragTarget = $null; $script:kiDragStart = $null }
    })
}

function Add-SysPilotKiMsg {
    param([string]$who, [string]$text)
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.TextWrapping = 'Wrap'; $tb.FontSize = 12; $tb.Margin = '0,3'
    if ($who -eq 'user') { $tb.Foreground = '#FF4FC3F7'; $tb.Text = "Du: $text" }
    elseif ($who -eq 'sys') { $tb.Foreground = '#FFFFB74D'; $tb.FontStyle = 'Italic'; $tb.Text = $text }
    else { $tb.Foreground = '#FFE0E0E0'; $tb.Text = "KI: $text" }
    [void]$ctrl.KiChatLog.Children.Add($tb)
    [void]$ctrl.KiChatScroll.ScrollToEnd()
    return $tb
}

function Show-SysPilotHerbertAnnouncement {
    <# Pilot Herbert: Bord-Ansage. Panel offen -> Chat-Nachricht,
       sonst Balloon-Tip (max. 1 / 4 Min). Respektiert ChkKiHints. #>
    param([string[]]$Category = @())
    try {
        if (-not (Get-SysPilotAiProcessHintsEnabled)) { return }
        if (-not (Get-SysPilotHerbertAnnouncementsEnabled)) { return }
    } catch { return }
    $ann = Get-SysPilotHerbertAnnouncement -Category $Category
    if (-not $ann) { return }
    if ($ctrl.KiChatPanel.Visibility -eq 'Visible') {
        [void](Add-SysPilotKiMsg 'sys' "ANSAGE: $($ann.Text)")
    } else {
        if (((Get-Date) - $script:herbertLastBalloon).TotalMinutes -lt 4) { return }
        $script:herbertLastBalloon = Get-Date
        try { $script:notifyIcon.ShowBalloonTip(7000, 'Pilot Herbert - Flug 667', $ann.Text, 'Info') } catch {}
        $ctrl.BtnKiFloat.ToolTip = "Pilot Herbert: $($ann.Text)"
    }
}

function Get-SysPilotKiSystemPrompt {
    $admin = if (Test-SysPilotAdmin) { 'mit Administratorrechten' } else { 'ohne Administratorrechte (eingeschraenkt)' }
    $recent = if ($script:herbertRecent.Count -gt 0) { "`nZuletzt vom Nutzer geoeffnete Programme: " + ($script:herbertRecent -join ', ') } else { '' }
    $logTail = ''
    try {
        $lf = Get-SysPilotLogFiles | Select-Object -First 1
        if ($lf) {
            $lines = Get-Content $lf.FullName -Tail 12 -ErrorAction Stop
            $logTail = "`nLetzte Log-Zeilen:`n" + ($lines -join "`n")
        }
    } catch {}
    return @"
Du bist Pilot Herbert, der Bord-Assistent von SysPilot (Flug 667), einem Windows-Wartungs-Tool (PowerShell/WPF).
Antworte auf Deutsch, knapp und konkret. Der Nutzer arbeitet GERADE in SysPilot.$recent
System-Kontext: $admin$logTail
Du kannst erklaeren, wie SysPilot-Funktionen bedient werden (Checkup, Toolbox, DNS, Auto-Optimierung, Softwarecenter, Programm-Katalog, Media-Center, KI-Apps, KI-Assistenz u.a.) und allgemeine Windows-Wartung beantworten.
Wenn der Nutzer Fehler meldet oder Log-Auszuege zeigt, analysiere Ursache und schlage konkrete Loesungen vor.
Bei riskanten Schritten (Registry, Dienste, Loeschungen) immer auf noetige Bestaetigung hinweisen. Erfinde keine Ergebnisse - bei Unsicherheit sag es.
`nARBEITSWEISE: Bei groesseren oder unsicheren Aufgaben zuerst analysieren (DENK-Marker), dann Plan vorschlagen und per FRAGE um Zustimmung bitten, erst danach ausfuehren. Kleine gefahrlose Fragen/Infos darfst du direkt beantworten. Install/Download: entscheide, ob ein Paketmanager das Paket sauber liefert (bevorzugt) oder SmartDownload noetig ist - begruende es im DENK-Block.
`nANTWORT-PROTOKOLL (Marker werden als UI-Elemente gerendert, nicht als Text): <<<DENK:text>>> Gedanke, <<<VORSCHLAG:text>>> klickbarer Chip, <<<FRAGE:frage|opt1|opt2>>> Frage mit Antwort-Buttons, <<<AKTION:id>>> Aktion (siehe Protokoll). Max. 3 Marker pro Antwort.
"@
}

function Show-SysPilotKiPanel {
    if ($ctrl.KiChatPanel.Visibility -eq 'Visible') { return }
    if (-not $script:kiPanelPlaced) {
        $l = [math]::Max(8, $win.ActualWidth - $ctrl.KiChatPanel.Width - 16)
        [Windows.Controls.Canvas]::SetLeft($ctrl.KiChatPanel, $l)
        [Windows.Controls.Canvas]::SetTop($ctrl.KiChatPanel, 12)
        $script:kiPanelPlaced = $true
    }
    $ctrl.KiChatPanel.Visibility = 'Visible'
    $ctrl.BtnKiFloat.Content = 'KI'
    $ctrl.BtnKiFloat.FontSize = 17
    $ctrl.BtnKiFloat.ToolTip = 'KI-Assistent - schwebender Chat (ziehen zum Verschieben, Klick = auf/zu)'
    if ($script:kiPendingErrors -gt 0) {
        Add-SysPilotKiMsg 'sys' "$($script:kiPendingErrors) Fehler(e) wurden waehrend der Abwesenheit im Log registriert - frag mich gerne danach."
        $script:kiPendingErrors = 0
    }
    if (-not $script:kiWelcomeDone) {
        $script:kiWelcomeDone = $true
        Add-SysPilotKiMsg 'sys' 'Hallo, hier ist Pilot Herbert (Flug 667). Ich sehe Kontext wie Admin-Status, Plan, letzte Log-Eintraege und was du zuletzt geoeffnet hast. Frag mich zu Einstellungen, Fehlern oder Programmen.'
        Show-SysPilotHerbertAnnouncement -Category 'welcome'
    }
    [void]$ctrl.KiChatScroll.ScrollToEnd()
    $ctrl.KiChatInput.Focus() | Out-Null
}

function Send-SysPilotKiMessage {
    $q = $ctrl.KiChatInput.Text.Trim()
    if (-not $q -or $script:kiBusy) { return }
    $ctrl.KiChatInput.Text = ''
    [void](Add-SysPilotKiMsg 'user' $q)
    $script:kiHistory += @{ role='user'; content=$q }
    if ($script:kiHistory.Count -gt 24) { $script:kiHistory = @($script:kiHistory | Select-Object -Last 24) }
    $script:kiBusy = $true
    $script:kiMode = 'chat'
    $ctrl.BtnKiSend.IsEnabled = $false
    $ctrl.KiChatInput.IsEnabled = $false
    $script:kiThinkMsg = Add-SysPilotKiMsg 'sys' 'Denke nach ...'
    # Provider/Modell-Auswahl + angehaengte Bilder
    $selProv = $ctrl.CmbKiProvider.SelectedItem
    $provName = if ($selProv -and $selProv.Name) { [string]$selProv.Name } else { '' }
    $modelSel = if ($provName) { "$($ctrl.CmbKiModel.Text)".Trim() } else { '' }
    try { Set-SysPilotAiLastSelection -Provider $provName -Model $modelSel } catch {}
    $imgsToSend = @($script:kiImages)
    $script:kiImages = @()
    # Letzte User-Nachricht nicht doppelt mitschicken (Invoke-SysPilotAiChat haengt Prompt selbst an)
    $hist = @($script:kiHistory | Select-Object -SkipLast 1)
    $sys = Get-SysPilotKiSystemPrompt
    try {
        if ($script:kiPs) { try { $script:kiPs.Dispose(); $script:kiRs.Close(); $script:kiRs.Dispose() } catch {} }
        $script:kiRs = [runspacefactory]::CreateRunspace()
        $script:kiRs.ApartmentState = 'STA'
        $script:kiRs.Open()
        $script:kiPs = [powershell]::Create()
        $script:kiPs.Runspace = $script:kiRs
        $modCommon = Join-Path $script:Root 'modules\Common.psm1'
        $modAi = Join-Path $script:Root 'modules\AiAssist.psm1'
        $modMcp = Join-Path $script:Root 'modules\McpClient.psm1'
        $useMcp = $false
        try { $useMcp = (@(Get-SysPilotMcpServers | Where-Object { $_.Enabled }).Count -gt 0) } catch {}
        [void]$script:kiPs.AddScript({
            param($mc,$ma,$mm,$prompt,$sys,$hist,$useMcp,$provName,$modelSel,$imgs)
            Import-Module $mc -Force -Global -WarningAction SilentlyContinue
            Import-Module $ma -Force -Global -WarningAction SilentlyContinue
            if ($mm) { Import-Module $mm -Force -Global -WarningAction SilentlyContinue }
            $defs = @()
            if ($useMcp -and (Get-Command Get-SysPilotMcpChatToolDefs -ErrorAction SilentlyContinue)) {
                try { $defs = @(Get-SysPilotMcpChatToolDefs) } catch { $defs = @() }
            }
            Invoke-SysPilotAiChat -Prompt $prompt -System $sys -History $hist -McpToolDefs $defs -TimeoutSec 100 -ProviderName $provName -Model $modelSel -Images $imgs
        }).AddArgument($modCommon).AddArgument($modAi).AddArgument($modMcp).AddArgument($q).AddArgument($sys).AddArgument($hist).AddArgument($useMcp).AddArgument($provName).AddArgument($modelSel).AddArgument($imgsToSend)
        $script:kiAsync = $script:kiPs.BeginInvoke()
        $kiPoll.Start()
    } catch {
        $script:kiBusy = $false
        $ctrl.BtnKiSend.IsEnabled = $true
        $ctrl.KiChatInput.IsEnabled = $true
        if ($script:kiThinkMsg) { try { [void]$ctrl.KiChatLog.Children.Remove($script:kiThinkMsg) } catch {}; $script:kiThinkMsg = $null }
        [void](Add-SysPilotKiMsg 'sys' "Fehler beim Starten der KI-Anfrage: $($_.Exception.Message)")
    }
}

function Show-SysPilotKiActionButtons {
    <# Rendert "Uebernehmen"-Buttons fuer Aktions-Marker in der KI-Antwort. #>
    param([string[]]$Ids)
    $known = @{}
    foreach ($a in (Get-SysPilotKiActions)) { $known[$a.Id] = $a }
    $hdr = New-Object System.Windows.Controls.TextBlock
    $hdr.Text = 'Aktionen (Uebernehmen = selbst entscheiden, NO RISK NO FUN):'
    $hdr.FontSize = 11; $hdr.Foreground = '#FFFFB74D'; $hdr.Margin = '0,4,0,2'
    [void]$ctrl.KiChatLog.Children.Add($hdr)
    $panel = New-Object System.Windows.Controls.WrapPanel
    foreach ($id in ($Ids | Select-Object -Unique)) {
        $a = $known[$id]
        if (-not $a) { continue }
        $b = New-Object System.Windows.Controls.Button
        $b.Content = "Uebernehmen: $($a.Label)"
        $b.FontSize = 11; $b.Padding = '8,3'; $b.Margin = '0,0,6,4'
        $riskTxt = switch ($a.Risk) { 'high' {'HOCHES RISIKO'} 'medium' {'mittleres Risiko'} default {'geringes Risiko'} }
        $b.ToolTip = "$($a.Desc)`nRisiko: $riskTxt | Admin noetig: $($a.NeedsAdmin)`n`nKlick = deine bewusste Entscheidung - SysPilot uebernimmt keine Verantwortung."
        $b.Tag = $id
        $b.Add_Click({ param($s,$e) Start-SysPilotKiAction ([string]$s.Tag) })
        [void]$panel.Children.Add($b)
    }
    [void]$ctrl.KiChatLog.Children.Add($panel)
    [void]$ctrl.KiChatScroll.ScrollToEnd()
}

function Show-SysPilotKiChoiceButtons {
    <# Rendert VORSCHLAG-Chips und FRAGE-Antwortbuttons. Klick fuellt
       das Eingabefeld (User entscheidet selbst, sendet per Enter). #>
    param([string[]]$Suggestions = @(), [string[]]$Questions = @())
    $hdr = New-Object System.Windows.Controls.TextBlock
    $hdr.Text = 'Vorschlaege / Fragen (Klick = in Eingabe uebernehmen):'
    $hdr.FontSize = 11; $hdr.Foreground = '#FF4FC3F7'; $hdr.Margin = '0,4,0,2'
    [void]$ctrl.KiChatLog.Children.Add($hdr)
    $panel = New-Object System.Windows.Controls.WrapPanel
    foreach ($s in ($Suggestions | Select-Object -Unique)) {
        if (-not $s) { continue }
        $b = New-Object System.Windows.Controls.Button
        $b.Content = $s
        $b.FontSize = 11; $b.Padding = '8,3'; $b.Margin = '0,0,6,4'
        $b.ToolTip = 'Herbert-Vorschlag - Klick uebernimmt den Text in der Eingabe'
        $b.Tag = $s
        $b.Add_Click({ param($bs,$e)
            $ctrl.KiChatInput.Text = [string]$bs.Tag
            try { $ctrl.KiChatInput.Focus() | Out-Null } catch {}
        })
        [void]$panel.Children.Add($b)
    }
    foreach ($qraw in $Questions) {
        $parts = $qraw -split '\|'
        $question = [string]$parts[0].Trim()
        if ($question) {
            $qh = New-Object System.Windows.Controls.TextBlock
            $qh.Text = "Herbert fragt: $question"; $qh.FontSize = 11; $qh.Foreground = '#FFFFB74D'; $qh.Margin = '0,4,0,2'
            [void]$ctrl.KiChatLog.Children.Add($qh)
        }
        foreach ($op in @($parts | Select-Object -Skip 1 | ForEach-Object { $_.Trim() } | Where-Object {$_})) {
            $b = New-Object System.Windows.Controls.Button
            $b.Content = $op
            $b.FontSize = 11; $b.Padding = '10,4'; $b.Margin = '0,0,8,4'
            $b.ToolTip = 'Antwort an Herbert senden (Klick = in Eingabe uebernehmen)'
            $b.Tag = $op
            $b.Add_Click({ param($bs,$e)
                $ctrl.KiChatInput.Text = [string]$bs.Tag
                try { $ctrl.KiChatInput.Focus() | Out-Null } catch {}
            })
            [void]$panel.Children.Add($b)
        }
    }
    [void]$ctrl.KiChatLog.Children.Add($panel)
    [void]$ctrl.KiChatScroll.ScrollToEnd()
}

function Start-SysPilotKiAction {
    <# Fuehrt eine registrierte Aktion async aus (eigener Runspace,
       alle Module geladen). Risiko medium/high -> Bestaetigungs-Dialog. #>
    param([Parameter(Mandatory)][string]$Id)
    if ($script:kiBusy) { [void](Add-SysPilotKiMsg 'sys' 'Bitte warte, bis die laufende KI-Anfrage/Aktion fertig ist.'); return }
    $act = @(Get-SysPilotKiActions) | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if (-not $act) { [void](Add-SysPilotKiMsg 'sys' "Unbekannte Aktion: $Id"); return }
    $perm = 'ask'
    try { $perm = Test-SysPilotKiPermission -Kind 'action' -Id $Id -Risk ([string]$act.Risk) } catch { $perm = 'ask' }
    if ($perm -eq 'deny') { [void](Add-SysPilotKiMsg 'sys' "Aktion '$($act.Label)' ist in den Permissions blockiert."); return }
    if ($perm -eq 'ask' -and $act.Risk -ne 'low') {
        $warn = "AKTION AUSFUEHREN: $($act.Label)`n`n$($act.Desc)`n`nRisiko: $($act.Risk.ToUpper()) | Admin noetig: $($act.NeedsAdmin)`n`nNO RISK NO FUN - dein Klick gilt als bewusste Entscheidung. SysPilot fuehrt die Aktion aus, uebernimmt aber keine Verantwortung fuer Datenverlust oder Systemschaeden.`n`nTrotzdem ausfuehren?"
        $res = [System.Windows.MessageBox]::Show($warn, 'KI-Aktion bestaetigen', 'YesNo', 'Warning')
        if ($res -ne 'Yes') { [void](Add-SysPilotKiMsg 'sys' "Aktion '$($act.Label)' abgebrochen."); return }
    }
    $script:kiBusy = $true
    $script:kiMode = 'action'
    $script:kiActionLabel = $act.Label
    $ctrl.BtnKiSend.IsEnabled = $false
    $ctrl.KiChatInput.IsEnabled = $false
    [void](Add-SysPilotKiMsg 'sys' "Fuehre Aktion '$($act.Label)' aus - bitte warten ...")
    try {
        if ($script:kiPs) { try { $script:kiPs.Dispose(); $script:kiRs.Close(); $script:kiRs.Dispose() } catch {} }
        $script:kiRs = [runspacefactory]::CreateRunspace()
        $script:kiRs.ApartmentState = 'STA'
        $script:kiRs.Open()
        $script:kiPs = [powershell]::Create()
        $script:kiPs.Runspace = $script:kiRs
        $modDir = Join-Path $script:Root 'modules'
        [void]$script:kiPs.AddScript({
            param($md,$aid)
            Get-ChildItem $md -Filter '*.psm1' | ForEach-Object { Import-Module $_.FullName -Force -Global -WarningAction SilentlyContinue }
            Invoke-SysPilotKiAction -Id $aid
        }).AddArgument($modDir).AddArgument($Id)
        $script:kiAsync = $script:kiPs.BeginInvoke()
        $kiPoll.Start()
    } catch {
        $script:kiBusy = $false; $script:kiMode = 'chat'
        $ctrl.BtnKiSend.IsEnabled = $true; $ctrl.KiChatInput.IsEnabled = $true
        [void](Add-SysPilotKiMsg 'sys' "Fehler beim Starten der Aktion: $($_.Exception.Message)")
    }
}

function Show-SysPilotKiMcpButtons {
    <# Rendert "MCP: server/tool"-Buttons fuer Tool-Calls der KI. #>
    param($Calls)
    $hdr = New-Object System.Windows.Controls.TextBlock
    $hdr.Text = 'MCP-Werkzeuge (Uebernehmen = selbst entscheiden, NO RISK NO FUN):'
    $hdr.FontSize = 11; $hdr.Foreground = '#FF4FC3F7'; $hdr.Margin = '0,4,0,2'
    [void]$ctrl.KiChatLog.Children.Add($hdr)
    $panel = New-Object System.Windows.Controls.WrapPanel
    foreach ($call in $Calls) {
        $def = $null
        try { $def = Find-SysPilotMcpToolDef -OpenAiName ([string]$call.Name) } catch {}
        $srv = if ($def) { $def.Server } else { '?' }
        $tool = if ($def) { $def.Tool } else { [string]$call.Name }
        $b = New-Object System.Windows.Controls.Button
        $b.Content = "MCP: $srv/$tool"
        $b.FontSize = 11; $b.Padding = '8,3'; $b.Margin = '0,0,6,4'
        $argTxt = [string]$call.Arguments
        if ($argTxt.Length -gt 300) { $argTxt = $argTxt.Substring(0,300) + '...' }
        $b.ToolTip = "Server: $srv`nWerkzeug: $tool`nArgumente: $argTxt`n`nKlick = deine Entscheidung - SysPilot uebernimmt keine Verantwortung."
        $b.Tag = @{ Server=$srv; Tool=$tool; Arguments=[string]$call.Arguments }
        $b.Add_Click({ param($s,$e) Start-SysPilotKiMcpTool $s.Tag })
        [void]$panel.Children.Add($b)
    }
    [void]$ctrl.KiChatLog.Children.Add($panel)
    [void]$ctrl.KiChatScroll.ScrollToEnd()
}

function Start-SysPilotKiMcpTool {
    <# Fuehrt einen MCP-Tool-Call async aus (Runspace, alle Module).
       IMMER mit Bestaetigung - MCP-Werkzeuge koennen alles. #>
    param($Info)
    if ($script:kiBusy) { [void](Add-SysPilotKiMsg 'sys' 'Bitte warte, bis die laufende KI-Anfrage/Aktion fertig ist.'); return }
    if (-not $Info -or -not $Info.Server -or $Info.Server -eq '?') {
        [void](Add-SysPilotKiMsg 'sys' 'MCP-Werkzeug-Mapping nicht gefunden (Tool-Liste evtl. abgelaufen). Nochmal fragen.')
        return
    }
    $perm = 'ask'
    try { $perm = Test-SysPilotKiPermission -Kind 'mcp' -Id "$($Info.Server)/$($Info.Tool)" -Risk 'high' } catch { $perm = 'ask' }
    if ($perm -eq 'deny') { [void](Add-SysPilotKiMsg 'sys' "MCP-Werkzeug '$($Info.Tool)' ist in den Permissions blockiert."); return }
    if ($perm -eq 'ask') {
        $argTxt = [string]$Info.Arguments
        if ($argTxt.Length -gt 400) { $argTxt = $argTxt.Substring(0,400) + '...' }
        $warn = "MCP-WERKZEUG AUSFUEHREN`n`nServer:  $($Info.Server)`nWerkzeug: $($Info.Tool)`nArgumente: $argTxt`n`nMCP-Werkzeuge koennen das System direkt beeinflussen (Dateien, Shell, Browser, GitHub).`nNO RISK NO FUN - dein Klick gilt als bewusste Entscheidung. SysPilot uebernimmt keine Verantwortung fuer Schaeden.`n`nTrotzdem ausfuehren?"
        $res = [System.Windows.MessageBox]::Show($warn, 'MCP-Werkzeug bestaetigen', 'YesNo', 'Warning')
        if ($res -ne 'Yes') { [void](Add-SysPilotKiMsg 'sys' "MCP-Werkzeug '$($Info.Tool)' abgebrochen."); return }
    }
    $script:kiBusy = $true
    $script:kiMode = 'mcp'
    $script:kiMcpInfo = $Info
    $ctrl.BtnKiSend.IsEnabled = $false
    $ctrl.KiChatInput.IsEnabled = $false
    [void](Add-SysPilotKiMsg 'sys' "Fuehre MCP-Werkzeug '$($Info.Server)/$($Info.Tool)' aus - bitte warten ...")
    try {
        if ($script:kiPs) { try { $script:kiPs.Dispose(); $script:kiRs.Close(); $script:kiRs.Dispose() } catch {} }
        $script:kiRs = [runspacefactory]::CreateRunspace()
        $script:kiRs.ApartmentState = 'STA'
        $script:kiRs.Open()
        $script:kiPs = [powershell]::Create()
        $script:kiPs.Runspace = $script:kiRs
        $modDir = Join-Path $script:Root 'modules'
        [void]$script:kiPs.AddScript({
            param($md,$srv,$tool,$argsJson)
            Get-ChildItem $md -Filter '*.psm1' | ForEach-Object { Import-Module $_.FullName -Force -Global -WarningAction SilentlyContinue }
            Invoke-SysPilotMcpTool -Server $srv -Tool $tool -Arguments $argsJson -TimeoutSec 90
        }).AddArgument($modDir).AddArgument($Info.Server).AddArgument($Info.Tool).AddArgument([string]$Info.Arguments)
        $script:kiAsync = $script:kiPs.BeginInvoke()
        $kiPoll.Start()
    } catch {
        $script:kiBusy = $false; $script:kiMode = 'chat'
        $ctrl.BtnKiSend.IsEnabled = $true; $ctrl.KiChatInput.IsEnabled = $true
        [void](Add-SysPilotKiMsg 'sys' "Fehler beim Starten des MCP-Werkzeugs: $($_.Exception.Message)")
    }
}

# Drag&Drop: schwebender Button + Chat-Panel-Kopf
Add-SysPilotKiDrag $ctrl.BtnKiFloat
Add-SysPilotKiDrag $ctrl.KiChatHeader

# Klick auf schwebenden Button = Chat auf/zu (Drag unterdrueckt den Klick)
$ctrl.BtnKiFloat.Add_Click({
    if ($script:kiMoved) { $script:kiMoved = $false; return }
    if ($ctrl.KiChatPanel.Visibility -eq 'Visible') { $ctrl.KiChatPanel.Visibility = 'Collapsed' }
    else { Show-SysPilotKiPanel }
})
$ctrl.BtnKiClose.Add_Click({ $ctrl.KiChatPanel.Visibility = 'Collapsed' })
$ctrl.BtnKiSend.Add_Click({ Send-SysPilotKiMessage })
# Pilot Herbert: Prozess-Hinweise stumm schalten
try {
    $ctrl.ChkKiHints.IsChecked = [bool](Get-SysPilotAiProcessHintsEnabled)
    $ctrl.ChkKiHints.Add_Checked({ Set-SysPilotAiProcessHintsEnabled -On $true })
    $ctrl.ChkKiHints.Add_Unchecked({ Set-SysPilotAiProcessHintsEnabled -On $false })
    $ctrl.ChkKiAnn.IsChecked = [bool](Get-SysPilotHerbertAnnouncementsEnabled)
    $ctrl.ChkKiAnn.Add_Checked({ Set-SysPilotHerbertAnnouncementsEnabled -On $true })
    $ctrl.ChkKiAnn.Add_Unchecked({ Set-SysPilotHerbertAnnouncementsEnabled -On $false })
} catch {}
# Top-Fresser Sortierung (RAM / CPU% / Name)
$script:hogSortPaint = {
    $map = @{ SortRam='RAM_MB'; SortCpu='CPU_Pct'; SortName='Programm' }
    foreach ($n in $map.Keys) { $el = $ctrl.$n; if ($el) { $el.Foreground = [Windows.Media.Brushes]::Gray } }
    $cur = if ($script:hogSort) { $script:hogSort } else { 'RAM_MB' }
    foreach ($n in $map.Keys) { if ($map[$n] -eq $cur -and $ctrl.$n) { $ctrl.$n.Foreground = [Windows.Media.Brushes]::LightGreen } }
}
& $script:hogSortPaint
$ctrl.SortRam.Add_Click({ $script:hogSort='RAM_MB'; & $script:hogSortPaint; $script:hogCpuPrev=@{} })
$ctrl.SortCpu.Add_Click({ $script:hogSort='CPU_Pct'; & $script:hogSortPaint; $script:hogCpuPrev=@{} })
$ctrl.SortName.Add_Click({ $script:hogSort='Programm'; & $script:hogSortPaint; $script:hogCpuPrev=@{} })
$ctrl.BtnKiProviders.Add_Click({ Show-SysPilotAiProvidersWindow -Owner $win })
$ctrl.BtnKiPerm.Add_Click({ try { Show-SysPilotHerbertPermissions -Owner $win | Out-Null } catch {} })
$ctrl.BtnKiExt.Add_Click({ try { Show-SysPilotHerbertExtensions -Owner $win | Out-Null } catch {} })
# Menue-Button im Chat-Panel: alle KI-Assistent-Funktionen als Popup.
# Konsole-Tools starten in eigenem Fenster (Start-SysPilotToolFromGui),
# 'providers' oeffnet direkt das WPF-Provider-Fenster.
$kiMenu = New-Object System.Windows.Controls.ContextMenu
foreach ($e in @(
    @{ L='Provider verwalten (Keys, Endpoints)'; K='providers' },
    @{ L='---' },
    @{ L='Setup-Assistent (Clients, Router, Bruecke, News)'; K='kisetup' },
    @{ L='Herbert-Manager (Skills + Konnektoren)'; K='kimgr' },
    @{ L='KI-Tools installieren (Ollama, LM Studio ...)'; K='kitools' },
    @{ L='KI-News-Feed (Reddit + HackerNews)'; K='kinews' },
    @{ L='Modelle suchen (HuggingFace GGUF)'; K='kimodels' },
    @{ L='Herbert-gestuetzte Installation'; K='kiguide' },
    @{ L='Schnellfrage'; K='kiquick' },
    @{ L='ERSTEINRICHTUNG (Provider/Keys)'; K='kionboard' },
    @{ L='API-Keys sichern'; K='kibackup' },
    @{ L='Prozess-Hinweise umschalten'; K='kiprocs' },
    @{ L='Bordansagen umschalten (Flug-Ansagen stumm)'; K='kiannouncements' },
    @{ L='YouTube-Key-Scout (Gratis-Provider aus Videos)'; K='yscout' },
    @{ L='Herbert-API + MCP (Provider fuer VS Code/Cline)'; K='herbertapimenu' },
    @{ L='Selbsttest (SysPilot + Herbert)'; K='selftest' },
    @{ L='Debug-Report an GitHub melden'; K='debugreport' },
    @{ L='Vollmenue (Konsolen-Variante)'; K='kiassist' },
    @{ L='VOLL BILD-Modus (Claude/PocketAI-Style, Sidebar)'; K='herbertfull' }
)) {
    if ($e.L -eq '---') { [void]$kiMenu.Items.Add((New-Object Windows.Controls.Separator)); continue }
    $mi = New-Object System.Windows.Controls.MenuItem
    $mi.Header = $e.L
    $mi.Tag = $e.K
    $mi.Add_Click({
        param($s,$ev)
        $k = [string]$s.Tag
        if ($k -eq 'providers') { Show-SysPilotAiProvidersWindow -Owner $win }
        elseif ($k -eq 'herbertfull') { Start-SysPilotToolFromGui -Tool $k -FromGui -HiddenConsole }
        elseif ($k -eq 'kimgr') { Start-SysPilotToolFromGui -Tool $k -FromGui -HiddenConsole }
        else { Start-SysPilotToolFromGui -Tool $k -FromGui }
    })
    [void]$kiMenu.Items.Add($mi)
}
$ctrl.BtnKiMenu.ContextMenu = $kiMenu
# Linksklick oeffnet das Menue direkt unter dem Button (ContextMenu
# zeigt sich sonst nur per Rechtsklick - das war der "tut-nix"-Bug)
$ctrl.BtnKiMenu.Add_Click({
    $kiMenu.PlacementTarget = $ctrl.BtnKiMenu
    $kiMenu.Placement = 'Bottom'
    $kiMenu.IsOpen = $true
})

# === Provider-/Modell-Auswahl (wie im Herbert-Fenster) ===
function Update-SysPilotKiProviderList {
    $list = @([pscustomobject]@{ Name=''; Label='Auto (Fallback-Kette)'; Prov=$null })
    try {
        $seen = @{}
        foreach ($p in @(Get-SysPilotAiProviders | Where-Object { $_.Enabled })) {
            $list += [pscustomobject]@{ Name=$p.Name; Label=$p.Name; Prov=$p }
            $seen[$p.Name.ToLower()] = $true
        }
        foreach ($d in @(Get-SysPilotAiProviderDefaults)) {
            if (-not $seen.ContainsKey($d.Name.ToLower())) {
                $list += [pscustomobject]@{ Name=$d.Name; Label="$($d.Name) (Port zu?)"; Prov=$null }
            }
        }
    } catch {}
    $ctrl.CmbKiProvider.ItemsSource = $list
    $ctrl.CmbKiProvider.DisplayMemberPath = 'Label'
    if ($ctrl.CmbKiProvider.SelectedIndex -lt 0 -or $ctrl.CmbKiProvider.SelectedItem -eq $null) {
        $ctrl.CmbKiProvider.SelectedIndex = 0
    }
    # Geteilte Auswahl (Panel <-> Herbert-Fenster) wiederherstellen
    try {
        $last = Get-SysPilotAiLastSelection
        if ($last.Provider) {
            $hit = @($ctrl.CmbKiProvider.Items | Where-Object { $_.Name -eq $last.Provider } | Select-Object -First 1)
            if ($hit.Count -gt 0) { $ctrl.CmbKiProvider.SelectedItem = $hit[0] }
            if ($last.Model) { $script:kiPendingModel = $last.Model }
        }
    } catch {}
}
$script:kiMdlTimer.Add_Tick({
    if (-not $script:kiMdlJob -or $script:kiMdlJob.State -eq 'Running') { return }
    $script:kiMdlTimer.Stop()
    try {
        $ids = @(Receive-Job $script:kiMdlJob -ErrorAction Stop)
        $ctrl.CmbKiModel.ItemsSource = $ids
        if ($ids.Count -gt 0) {
            $pref = @($ids | Where-Object { $_ -match '(?i)free|mini|flash|small|8b|7b|instruct' } | Select-Object -First 1)
            $ctrl.CmbKiModel.Text = $(if ($pref) { $pref } else { $ids[0] })
        }
        if ($script:kiPendingModel) { $ctrl.CmbKiModel.Text = $script:kiPendingModel; $script:kiPendingModel = $null }
    } catch {}
    Remove-Job $script:kiMdlJob -Force -ErrorAction SilentlyContinue
    $script:kiMdlJob = $null
})
$ctrl.CmbKiProvider.Add_SelectionChanged({
    $sel = $ctrl.CmbKiProvider.SelectedItem
    $provObj = if ($sel) { $sel.Prov } else { $null }
    $ctrl.CmbKiModel.ItemsSource = @()
    $ctrl.CmbKiModel.Text = ''
    if (-not $provObj) { return }
    if ($script:kiMdlJob) { try { Remove-Job $script:kiMdlJob -Force } catch {} }
    $script:kiMdlJob = Start-Job -ScriptBlock {
        param($modDir,$p)
        Import-Module (Join-Path $modDir 'AiAssist.psm1') -Force -WarningAction SilentlyContinue
        Import-Module (Join-Path $modDir 'Common.psm1') -Force -WarningAction SilentlyContinue
        $pr = [pscustomobject]@{ Name=$p.Name; BaseUrl=$p.BaseUrl; Model=$p.Model; ApiKey=$p.ApiKey; Kind=$p.Kind }
        $r = Get-SysPilotAiProviderModels -Provider $pr -TimeoutSec 12
        foreach ($m in @($r.Models)) { Write-Output $m.Id }
        if ($r.Models.Count -eq 0 -and $pr.Model) { Write-Output $pr.Model }
    } -ArgumentList $script:Root,$provObj
    $script:kiMdlTimer.Start()
})
Update-SysPilotKiProviderList
$ctrl.BtnKiNew.Add_Click({
    $script:kiHistory = @()
    $script:kiImages = @()
    try { $ctrl.KiChatLog.Children.Clear() } catch {}
    [void](Add-SysPilotKiMsg 'sys' 'Neuer Chat gestartet - Verlauf ist leer.')
})
# Bild aus Zwischenablage anhaengen (Strg+V auf dem Eingabefeld)
$ctrl.KiChatInput.Add_PreviewKeyDown({
    param($s,$e)
    if ($e.Key -eq 'V' -and ($e.KeyboardDevice.Modifiers -band 'Control')) {
        try {
            $img = [Windows.Clipboard]::GetImage()
            if ($img -and $img.Width -gt 0) {
                $ms = New-Object IO.MemoryStream
                $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
                $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($img))
                $enc.Save($ms)
                $script:kiImages += @{ B64=[Convert]::ToBase64String($ms.ToArray()); Mime='image/png' }
                [void](Add-SysPilotKiMsg 'sys' "Bild angehaengt ($([int]$img.Width)x$([int]$img.Height)) - wird mitgesendet.")
                $e.Handled = $true
            }
        } catch {}
    }
})
$ctrl.KiChatInput.Add_KeyDown({
    param($s,$e)
    if ($e.Key -eq 'Return') { Send-SysPilotKiMessage; $e.Handled = $true }
})

# Poll-Timer fuer die asynchrone KI-Antwort
$kiPoll = New-Object System.Windows.Threading.DispatcherTimer
$kiPoll.Interval = [TimeSpan]::FromMilliseconds(400)
$kiPoll.Add_Tick({
    if (-not $script:kiAsync) { $kiPoll.Stop(); return }
    if (-not $script:kiAsync.IsCompleted) { return }
    $kiPoll.Stop()
    $r = $null
    try { $r = $script:kiPs.EndInvoke($script:kiAsync) | Select-Object -Last 1 }
    catch { $r = @{ Ok=$false; Error=$_.Exception.Message } }
    try { $script:kiPs.Dispose(); $script:kiRs.Close(); $script:kiRs.Dispose() } catch {}
    $script:kiPs = $null; $script:kiRs = $null; $script:kiAsync = $null
    $script:kiBusy = $false
    $ctrl.BtnKiSend.IsEnabled = $true
    $ctrl.KiChatInput.IsEnabled = $true
    if ($script:kiThinkMsg) { try { [void]$ctrl.KiChatLog.Children.Remove($script:kiThinkMsg) } catch {}; $script:kiThinkMsg = $null }
    if ($script:kiMode -eq 'action') {
        $script:kiMode = 'chat'
        $lbl = $script:kiActionLabel
        if ($r -and $r.Ok) {
            $txt = if ($r.Text) { $r.Text.Trim() } else { '(kein Output)' }
            if ($txt.Length -gt 1200) { $txt = $txt.Substring(0,1200) + "`n... (gekuerzt)" }
            [void](Add-SysPilotKiMsg 'sys' "[$lbl] erledigt:`n$txt")
            if ((Get-Random -Max 2) -eq 0) { Show-SysPilotHerbertAnnouncement -Category 'landung' }
        } else {
            $err = if ($r) { $r.Error } else { 'unbekannt' }
            [void](Add-SysPilotKiMsg 'sys' "[$lbl] fehlgeschlagen: $err")
        }
        return
    }
    if ($script:kiMode -eq 'mcp') {
        $script:kiMode = 'chat'
        $info = $script:kiMcpInfo
        if ($r -and $r.Ok) {
            $txt = if ($r.Text) { $r.Text.Trim() } else { '(leeres Ergebnis)' }
            if ($txt.Length -gt 1500) { $txt = $txt.Substring(0,1500) + "`n... (gekuerzt)" }
            [void](Add-SysPilotKiMsg 'sys' "[MCP $($info.Server)/$($info.Tool)] Ergebnis:`n$txt")
            # Auto-Followup: Ergebnis an Herbert zur Zusammenfassung zurueckgeben
            $auszug = $txt
            if ($auszug.Length -gt 900) { $auszug = $auszug.Substring(0,900) + '...' }
            $ctrl.KiChatInput.Text = "Das MCP-Werkzeug '$($info.Tool)' (Server $($info.Server)) hat geliefert:`n$auszug`n`nBitte fasse das Ergebnis kurz fuer mich zusammen."
            if ((Get-Random -Max 2) -eq 0) { Show-SysPilotHerbertAnnouncement -Category 'landung' }
            Send-SysPilotKiMessage
        } else {
            $err = if ($r) { $r.Error } else { 'unbekannt' }
            [void](Add-SysPilotKiMsg 'sys' "[MCP $($info.Server)/$($info.Tool)] fehlgeschlagen: $err")
        }
        return
    }
    if ($r -and $r.Ok) {
        # MCP-Tool-Calls haben Prioritaet (content ist dann meist leer)
        $calls = @($r.ToolCalls)
        if ($calls.Count -gt 0) {
            $txt0 = [regex]::Replace([string]$r.Text, '\s*<<<(AKTION|DENK|VORSCHLAG|FRAGE):[\s\S]*?>>>\s*', "`n").Trim()
            if ($txt0) { [void](Add-SysPilotKiMsg 'ai' $txt0) }
            Show-SysPilotKiMcpButtons $calls
            $callNames = (($calls | ForEach-Object { [string]$_.Name }) -join ', ')
            $script:kiHistory += @{ role='assistant'; content=("$txt0`n[MCP-Toolcalls: $callNames]").Trim() }
        } else {
        # Marker <<<AKTION:id>>> <<<DENK:>>> <<<VORSCHLAG:>>> <<<FRAGE:>>> filtern + rendern
        $acts = @([regex]::Matches($r.Text, '<<<AKTION:([a-zA-Z0-9_-]+)>>>') | ForEach-Object { $_.Groups[1].Value })
        $denks = @([regex]::Matches([string]$r.Text, '<<<DENK:([\s\S]*?)>>>') | ForEach-Object { $_.Groups[1].Value.Trim() })
        $suggs = @([regex]::Matches([string]$r.Text, '<<<VORSCHLAG:([^<>|]+)>>>') | ForEach-Object { $_.Groups[1].Value.Trim() } | Select-Object -Unique)
        $qs = @([regex]::Matches([string]$r.Text, '<<<FRAGE:([^<>]+)>>>') | ForEach-Object { $_.Groups[1].Value.Trim() })
        $clean = [regex]::Replace([string]$r.Text, '\s*<<<(AKTION|DENK|VORSCHLAG|FRAGE):[\s\S]*?>>>\s*', "`n").Trim()
        if (-not $clean) { $clean = '(Aktion/Vorschlag - siehe Buttons unten)' }
        [void](Add-SysPilotKiMsg 'ai' $clean)
        foreach ($d in $denks) { if ($d) { [void](Add-SysPilotKiMsg 'sys' "Herbert denkt: $d") } }
        if ($suggs.Count -gt 0 -or $qs.Count -gt 0) { Show-SysPilotKiChoiceButtons -Suggestions $suggs -Questions $qs }
        if ($acts.Count -gt 0) { Show-SysPilotKiActionButtons $acts }
        $script:kiHistory += @{ role='assistant'; content=$clean }
        if ($script:kiHistory.Count -gt 24) { $script:kiHistory = @($script:kiHistory | Select-Object -Last 24) }
        }
    } else {
        $err = if ($r) { $r.Error } else { 'unbekannt' }
        [void](Add-SysPilotKiMsg 'sys' "KI nicht erreichbar: $err")
    }
})

# Watcher: Spiele => Overlay ausblenden; Log => neue Fehler melden
$kiWatch = New-Object System.Windows.Threading.DispatcherTimer
$kiWatch.Interval = [TimeSpan]::FromSeconds(12)
$kiWatch.Add_Tick({
    try {
        $gaming = Test-SysPilotGamingActive
        $vis = if ($gaming) { 'Collapsed' } else { 'Visible' }
        if ($ctrl.KiOverlay.Visibility -ne $vis) { $ctrl.KiOverlay.Visibility = $vis }
    } catch {}
    # Pilot Herbert: neue interaktive Programme erkennen (stumm schaltbar)
    try {
        if (Get-SysPilotAiProcessHintsEnabled) {
            $cur = @{}
            Get-Process -ErrorAction SilentlyContinue | Where-Object {
                $_.SessionId -eq $script:herbertSession -and $_.MainWindowTitle -and
                ($script:herbertExclude -notcontains $_.ProcessName)
            } | ForEach-Object { $cur["$($_.ProcessName)|$($_.Id)"] = $true }
            if ($script:herbertBaselineDone) {
                $newKeys = @($cur.Keys | Where-Object { -not $script:herbertKnown.ContainsKey($_) })
                if ($newKeys.Count -gt 0 -and ((Get-Date) - $script:herbertLastAlert).TotalSeconds -gt 90) {
                    $script:herbertLastAlert = Get-Date
                    $names = @($newKeys | ForEach-Object { ($_ -split '\|')[0] } | Select-Object -Unique)
                    $label = ($names -join ', ')
                    foreach ($n in $names) {
                        $script:herbertRecent = @(@($n) + @($script:herbertRecent | Where-Object { $_ -ne $n }) | Select-Object -First 6)
                    }
                    $tip = "Pilot Herbert: '$label' gestartet - Klick auf KI-Button fuer Kurzcheck/Hilfe"
                    try { $script:notifyIcon.ShowBalloonTip(6000, 'Pilot Herbert', $tip, 'Info') } catch {}
                    if ($ctrl.KiChatPanel.Visibility -eq 'Visible') {
                        [void](Add-SysPilotKiMsg 'sys' "Neues Programm erkannt: $label - soll ich etwas dazu tun? (z.B. Prozess-Info, Programm-Details, Einrichtungs-Hilfe)")
                    } else {
                        $ctrl.BtnKiFloat.ToolTip = "Pilot Herbert: '$label' neu - Klick fuer Assistent"
                    }
                }
            } else { $script:herbertBaselineDone = $true }
            $script:herbertKnown = $cur
        }
    } catch {}
    # Pilot Herbert: vereinzelt eine Bord-Ansage (~alle 5 Min, 25% Chance)
    try {
        if (Get-SysPilotAiProcessHintsEnabled -and $script:kiWatchTick % 25 -eq 24 -and (Get-Random -Max 4) -eq 0) {
            Show-SysPilotHerbertAnnouncement -Category @('wetter','sicherheit','nacht','song','flieger','hotshots')
        }
    } catch {}
    $script:kiWatchTick = [int]$script:kiWatchTick + 1
    if ($script:kiWatchTick % 5 -ne 0) { return }   # Log-Check ~alle 60s
    try {
        $logs = @(Get-SysPilotLogFiles)
        if ($logs.Count -eq 0) { return }
        $lf = $logs[0]
        $len = $lf.Length
        if ($script:kiLogFile -ne $lf.FullName) { $script:kiLogFile = $lf.FullName; $script:kiLogPos = $len; return }
        if ($len -le $script:kiLogPos) { $script:kiLogPos = [Math]::Max($script:kiLogPos, $len); return }
        $fs = [IO.File]::Open($lf.FullName, 'Open', 'Read', 'ReadWrite')
        try {
            [void]$fs.Seek($script:kiLogPos, 'Begin')
            $sr = New-Object IO.StreamReader($fs)
            $chunk = $sr.ReadToEnd(); $sr.Close()
        } finally { $fs.Close() }
        $script:kiLogPos = $len
        $errs = @($chunk -split "`r?`n" | Where-Object { $_ -match 'ERROR|FEHLER|fehlgeschlagen|Exception' } | Select-Object -First 5)
        if ($errs.Count -gt 0) {
            $script:kiPendingErrors += $errs.Count
            Show-SysPilotHerbertAnnouncement -Category 'turbulenz'
            if ($ctrl.KiChatPanel.Visibility -eq 'Visible') {
                [void](Add-SysPilotKiMsg 'sys' ("Fehler im Log erkannt:`n" + ($errs -join "`n")))
            } else {
                $ctrl.BtnKiFloat.Content = '!'
                $ctrl.BtnKiFloat.FontSize = 20
                $ctrl.BtnKiFloat.ToolTip = "$($script:kiPendingErrors) neue(r) Log-Eintrag/Fehler - Klick fuer Assistent"
            }
        }
    } catch {}
})

# Button-Startposition (unten rechts) + Clamp beim Fenster-Resize
[Windows.Controls.Canvas]::SetLeft($ctrl.BtnKiFloat, 676)
[Windows.Controls.Canvas]::SetTop($ctrl.BtnKiFloat, 556)
$win.Add_SizeChanged({
    param($s,$e)
    $el = $ctrl.BtnKiFloat
    $l = [Windows.Controls.Canvas]::GetLeft($el); $t = [Windows.Controls.Canvas]::GetTop($el)
    if ($l -lt 4 -or $l -gt ($s.ActualWidth - $el.ActualWidth - 10) -or $t -lt 4 -or $t -gt ($s.ActualHeight - $el.ActualHeight - 10)) {
        [Windows.Controls.Canvas]::SetLeft($el, [math]::Max(4, $s.ActualWidth - $el.ActualWidth - 12))
        [Windows.Controls.Canvas]::SetTop($el, [math]::Max(4, $s.ActualHeight - $el.ActualHeight - 12))
    }
})

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
        # Gesamt-RAM + Kerne fuer %-Anzeige (gecacht)
        if (-not $script:hogRamTotalMB -or ((Get-Date) - $script:hogRamCacheTime).TotalMinutes -gt 5) {
            try { $script:hogRamTotalMB = [math]::Round(((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory)/1MB) } catch { $script:hogRamTotalMB = 8192 }
            $script:hogRamCacheTime = Get-Date
        }
        if (-not $script:hogCores) { $script:hogCores = [Environment]::ProcessorCount }
        $nowH = Get-Date
        $elapsedH = if ($script:hogCpuTime) { [math]::Max(1, ($nowH - $script:hogCpuTime).TotalSeconds) } else { 0 }
        $groups = Get-Process | Group-Object ProcessName
        $hogs = foreach ($g in $groups) {
            $ramMB = [math]::Round((($g.Group | Measure-Object WorkingSet64 -Sum).Sum)/1MB)
            $cpuS = [math]::Round((($g.Group | Measure-Object CPU -Sum).Sum))
            # CPU% = Delta seit letztem Refresh / (Zeit * Kerne) -> max 100%
            $cpuPct = 0.0
            $prev = $script:hogCpuPrev[$g.Name]
            if ($null -ne $prev -and $elapsedH -gt 0) {
                $d = $cpuS - [double]$prev
                if ($d -lt 0) { $d = 0 }
                $cpuPct = [math]::Round(($d / ($elapsedH * $script:hogCores)) * 100, 1)
                if ($cpuPct -gt 100) { $cpuPct = 100 }
            }
            $script:hogCpuPrev[$g.Name] = $cpuS
            [PSCustomObject]@{
                Programm = $g.Name
                RAM_MB = $ramMB
                RAM_Pct = $(if ($script:hogRamTotalMB -gt 0) { "$([math]::Round($ramMB/$script:hogRamTotalMB*100,1))%" } else { '' })
                CPU_Pct = $cpuPct
                CPU_s = $cpuS
                Instanzen = $g.Count
                Massnahme = ''
            }
        }
        $script:hogCpuTime = $nowH
        $sortKey = if ($script:hogSort) { $script:hogSort } else { 'RAM_MB' }
        $hogs = @($hogs | Sort-Object @{Expression=$sortKey; Descending=($sortKey -ne 'Programm')})
        $hogs = @($hogs | Select-Object -First 15)

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
        # Tipp rotieren (kleiner Kontext-Hinweis unter der Liste)
        if (-not $script:hogTips) {
            $script:hogTips = @(
                'Tipp: Doppelklick auf einen Eintrag zeigt Details + HowTo.',
                'Tipp: "RAM freigeben" leert den Standby-Speicher (sinngemaess).',
                'Tipp: "x" = Anzahl der laufenden Instanzen dieses Programms.',
                'Tipp: Hoher RAM-Anteil bei Browsern ist normal - Tabs buendeln sich.',
                'Tipp: "System"/"Idle" mit CPU-Werten sind Windows-intern, meist unkritisch.',
                'Tipp: Process Explorer (Button Prozesse) zeigt die Baumansicht pro Elternteil.'
            )
        }
        $tipIdx = $script:tick % $script:hogTips.Count
        $ctrl.HogTip.Text = "Tipp: $($script:hogTips[$tipIdx])"
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
    <Style TargetType="ListViewItem">
      <Setter Property="Padding" Value="8,5"/>
      <Setter Property="Foreground" Value="#FFEAEAF2"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#FF34344E"/></Trigger>
        <Trigger Property="IsSelected" Value="True">
          <Setter Property="Background" Value="#CCE4EAF2"/>
          <Setter Property="Foreground" Value="#FF1E1E2E"/>
        </Trigger>
      </Style.Triggers>
    </Style>
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
            <TextBlock Text="{Binding Name}" Width="200" VerticalAlignment="Center"/>
            <TextBlock Text="{Binding Summary}" VerticalAlignment="Center"/>
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
            $color = if ($_.Skipped) { '#FF607D8B' } elseif (-not $_.Found) { '#FF43A047' } elseif ($_.Critical) { '#FFE53935' } else { '#FFFB8C00' }
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

    Set-SysPilotWindowAutoSize -Win $cwin -MinWidth 980 -MinHeight 600
    Add-SysPilotAssistantToWindow -Win $cwin -Context 'Show-SysPilotCheckupWindow'
    $cwin.ShowDialog() | Out-Null
    $scanTimer.Stop()
}

# --- Task-Manager-Fenster (Maus-bedienbar: Liste, Prioritaet, Details) ---
function Show-SysPilotProcessWindow {
    $pxaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="SysPilot - Task-Manager" Width="1080" Height="620" MinWidth="820" MinHeight="440"
        Background="#FF1E1E2E" Foreground="#FFE0E0E0"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResizeWithGrip">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#FF2D2D44"/><Setter Property="Foreground" Value="#FFE0E0E0"/>
      <Setter Property="BorderBrush" Value="#FF4A4A6A"/><Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="10,5"/><Setter Property="Margin" Value="3"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="12"/>
    </Style>
    <ControlTemplate x:Key="ComboDarkToggle" TargetType="ToggleButton">
      <Border x:Name="Bg" Background="#FF2D2D44" BorderBrush="#FF4A4A6A" BorderThickness="1" CornerRadius="2"/>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="BorderBrush" Value="#FF4FC3F7"/></Trigger>
        <Trigger Property="IsChecked" Value="True"><Setter Property="BorderBrush" Value="#FF4FC3F7"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate>
    <Style TargetType="ComboBox">
      <Setter Property="Background" Value="#FF2D2D44"/><Setter Property="Foreground" Value="#FFE0E0E0"/>
      <Setter Property="BorderBrush" Value="#FF4A4A6A"/><Setter Property="Padding" Value="5,3"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton x:Name="ToggleButton" Focusable="False" ClickMode="Press"
                Template="{StaticResource ComboDarkToggle}"
                IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"/>
              <ContentPresenter x:Name="ContentSite" IsHitTestVisible="False"
                Content="{TemplateBinding SelectionBoxItem}"
                ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                ContentTemplateSelector="{TemplateBinding ItemTemplateSelector}"
                Margin="8,0,24,0" VerticalAlignment="Center" HorizontalAlignment="Left"/>
              <Path Data="M 0 0 L 4 4 L 8 0 Z" Fill="#FF9E9E9E" Width="8" Height="4"
                    HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,10,0"/>
              <Popup x:Name="Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}"
                     AllowsTransparency="True" Focusable="False" PopupAnimation="Slide">
                <Border Background="#FF1E1E2E" BorderBrush="#FF4A4A6A" BorderThickness="1"
                        MinWidth="{TemplateBinding ActualWidth}" MaxHeight="320">
                  <ScrollViewer><ItemsPresenter/></ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.55"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="#FFE0E0E0"/><Setter Property="Background" Value="Transparent"/>
      <Setter Property="Padding" Value="8,4"/>
      <Style.Triggers>
        <Trigger Property="IsHighlighted" Value="True"><Setter Property="Background" Value="#FF34344E"/><Setter Property="Foreground" Value="#FFEAEAF2"/></Trigger>
        <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#CCE4EAF2"/><Setter Property="Foreground" Value="#FF1E1E2E"/></Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="TextBox"><Setter Property="Background" Value="#FF252538"/><Setter Property="Foreground" Value="#FFE0E0E0"/><Setter Property="BorderBrush" Value="#FF4A4A6A"/></Style>
    <Style TargetType="ListViewItem">
      <Setter Property="Padding" Value="8,5"/>
      <Setter Property="Foreground" Value="#FFEAEAF2"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#FF34344E"/>
        </Trigger>
        <Trigger Property="IsSelected" Value="True">
          <Setter Property="Background" Value="#CCE4EAF2"/>
          <Setter Property="Foreground" Value="#FF1E1E2E"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="GridViewColumnHeader">
      <Setter Property="Background" Value="#FF2D2D44"/>
      <Setter Property="Foreground" Value="#FF9CCBFF"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="BorderBrush" Value="#FF4A4A6A"/>
      <Setter Property="BorderThickness" Value="0,0,1,1"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
    </Style>
  </Window.Resources>
  <Grid Margin="12">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <DockPanel Grid.Row="0">
      <TextBlock Text="Task-Manager" FontSize="20" FontWeight="Bold" Foreground="#FF4FC3F7"/>
      <TextBlock x:Name="ProcCount" Text="" FontSize="11" Foreground="#FF9E9E9E" HorizontalAlignment="Right" VerticalAlignment="Bottom"/>
    </DockPanel>
    <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,8">
      <TextBox x:Name="FilterBox" Width="220" ToolTip="Filter: Name, PID oder Fenstertitel"/>
      <ComboBox x:Name="SortBox" Width="110" Margin="6,0,0,0" ToolTip="Sortierung">
        <ComboBoxItem Content="RAM" IsSelected="True"/><ComboBoxItem Content="CPU"/><ComboBoxItem Content="Name"/><ComboBoxItem Content="Prioritaet"/>
      </ComboBox>
      <CheckBox x:Name="AutoRefresh" Content="Auto (3s)" IsChecked="True" Margin="10,0,0,0" VerticalAlignment="Center" Foreground="#FFE0E0E0"/>
      <Button x:Name="BtnRefresh" Content="Aktualisieren" Margin="10,0,0,0"/>
    </StackPanel>
    <ListView x:Name="ProcList" Grid.Row="2" Background="#FF252538" BorderThickness="0">
      <ListView.View>
        <GridView>
          <GridViewColumn Header="Name" Width="170" DisplayMemberBinding="{Binding Name}"/>
          <GridViewColumn Header="PID" Width="60" DisplayMemberBinding="{Binding Id}"/>
          <GridViewColumn Header="CPU(s)" Width="70" DisplayMemberBinding="{Binding CPU}"/>
          <GridViewColumn Header="RAM (MB)" Width="80" DisplayMemberBinding="{Binding RamMB}"/>
          <GridViewColumn Header="Prioritaet" Width="100" DisplayMemberBinding="{Binding Priority}"/>
          <GridViewColumn Header="Fenstertitel" Width="200" DisplayMemberBinding="{Binding Title}"/>
          <GridViewColumn Header="Pfad" Width="280" DisplayMemberBinding="{Binding Path}"/>
        </GridView>
      </ListView.View>
    </ListView>
    <Border Grid.Row="3" Background="#FF252538" CornerRadius="6" Padding="8" Margin="0,8">
      <TextBlock x:Name="DetailText" Text="Prozess auswaehlen fuer Details." TextWrapping="Wrap" FontSize="12" Foreground="#FFD8D8E4" MaxHeight="90"/>
    </Border>
    <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Center">
      <ComboBox x:Name="PrioBox" Width="130" Margin="0,0,3,0" ToolTip="Neue Prioritaet">
        <ComboBoxItem Content="Idle"/><ComboBoxItem Content="BelowNormal"/><ComboBoxItem Content="Normal" IsSelected="True"/>
        <ComboBoxItem Content="AboveNormal"/><ComboBoxItem Content="High"/><ComboBoxItem Content="Realtime"/>
      </ComboBox>
      <Button x:Name="BtnSetPrio" Content="Prioritaet setzen" ToolTip="High/Realtime brauchen Adminrechte"/>
      <Button x:Name="BtnKill" Content="Beenden" ToolTip="Prozess + Kindprozesse beenden"/>
      <Button x:Name="BtnExplorer" Content="Process Explorer" ToolTip="Sysinternals procexp64, portabel"/>
      <Button x:Name="BtnStart" Content="Programm starten"/>
      <Button x:Name="BtnClose" Content="Schliessen"/>
    </StackPanel>
  </Grid>
</Window>
"@
    $preader = New-Object System.Xml.XmlNodeReader ([xml]$pxaml)
    $pwin = [Windows.Markup.XamlReader]::Load($preader)
    $pwin.Owner = $win
    $pc = @{}
    foreach ($n in 'ProcCount','FilterBox','SortBox','AutoRefresh','BtnRefresh','ProcList','DetailText','PrioBox','BtnSetPrio','BtnKill','BtnExplorer','BtnStart','BtnClose') {
        $pc[$n] = $pwin.FindName($n)
    }
    $script:procWinItems = @()
    $script:procWinSelPid = 0

    $loadProcs = {
        $selPid = $script:procWinSelPid
        $f = $pc.FilterBox.Text.Trim()
        $top = 500
        $items = @(Get-SysPilotProcesses -Top $top -Filter $f)
        $sortMode = $pc.SortBox.SelectedItem.Content
        $items = switch ($sortMode) {
            'CPU'  { $items | Sort-Object { [double]$_.CPU } -Descending }
            'Name' { $items | Sort-Object Name }
            'Prioritaet' { $items | Sort-Object Priority }
            default { $items | Sort-Object { [double]$_.RamMB } -Descending }
        }
        $script:procWinItems = $items
        $pc.ProcList.ItemsSource = $items
        $pc.ProcCount.Text = "$($items.Count) Prozesse"
        if ($selPid -gt 0) {
            $hit = $items | Where-Object { $_.Id -eq $selPid } | Select-Object -First 1
            if ($hit) { $pc.ProcList.SelectedItem = $hit }
        }
    }

    $showDetails = {
        $sel = $pc.ProcList.SelectedItem
        if ($null -eq $sel) { $pc.DetailText.Text = 'Prozess auswaehlen fuer Details.'; return }
        $script:procWinSelPid = $sel.Id
        $p = Get-Process -Id $sel.Id -ErrorAction SilentlyContinue
        if (-not $p) { $pc.DetailText.Text = "Prozess $($sel.Id) nicht mehr vorhanden."; return }
        $lines = @("$($p.ProcessName) (PID $($p.Id)) - Prioritaet: $($p.PriorityClass)")
        $lines += "Pfad: $($p.Path)"
        $lines += "RAM: $([math]::Round($p.WorkingSet64/1MB)) MB | CPU: $([math]::Round($p.CPU,1))s | Threads: $($p.Threads.Count) | Handles: $($p.HandleCount)"
        $lines += "Start: $(if($p.StartTime){$p.StartTime.ToString('dd.MM.yyyy HH:mm')}else{'?'}) | Antwortet: $($p.Responding) | Fenster: '$($p.MainWindowTitle)'"
        try {
            $w = Get-CimInstance Win32_Process -Filter "ProcessId=$($sel.Id)" -ErrorAction SilentlyContinue
            if ($w) {
                $par = Get-Process -Id $w.ParentProcessId -ErrorAction SilentlyContinue
                $lines += "Parent: $(if($par){"$($par.ProcessName) ($($w.ParentProcessId))"}else{"PID $($w.ParentProcessId) (beendet)"})"
                $kids = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($sel.Id)" -ErrorAction SilentlyContinue)
                if ($kids.Count) { $lines += "Kinder: $(($kids | ForEach-Object { "$($_.Name)($($_.ProcessId))" }) -join ', ')" }
            }
        } catch {}
        $pc.DetailText.Text = ($lines -join "`n")
        # PrioBox auf aktuellen Wert setzen
        try { $pc.PrioBox.SelectedItem = $pc.PrioBox.Items | Where-Object { $_.Content -eq [string]$p.PriorityClass } | Select-Object -First 1 } catch {}
    }

    $autoTimer = New-Object System.Windows.Threading.DispatcherTimer
    $autoTimer.Interval = [TimeSpan]::FromSeconds(3)
    $autoTimer.Add_Tick({ & $loadProcs })

    $pc.BtnRefresh.Add_Click({ & $loadProcs })
    $pc.FilterBox.Add_KeyUp({ param($s,$e) if ($e.Key -eq 'Return') { & $loadProcs } })
    $pc.SortBox.Add_SelectionChanged({ & $loadProcs })
    $pc.AutoRefresh.Add_Checked({ $autoTimer.Start() })
    $pc.AutoRefresh.Add_Unchecked({ $autoTimer.Stop() })
    $pc.ProcList.Add_SelectionChanged({ & $showDetails })

    $pc.BtnKill.Add_Click({
        $sel = $pc.ProcList.SelectedItem
        if ($null -eq $sel) { return }
        $res = [System.Windows.MessageBox]::Show("Prozess '$($sel.Name)' (PID $($sel.Id), $($sel.RamMB) MB) samt Kindprozessen beenden?", 'Task-Manager', 'YesNo', 'Warning')
        if ($res -ne 'Yes') { return }
        Stop-SysPilotProcessTree -Id $sel.Id -Force | Out-Null
        & $loadProcs
    })
    $pc.BtnSetPrio.Add_Click({
        $sel = $pc.ProcList.SelectedItem
        if ($null -eq $sel) { return }
        $prio = [string]$pc.PrioBox.SelectedItem.Content
        if (-not $prio) { return }
        if ($prio -in @('High','Realtime')) {
            $res = [System.Windows.MessageBox]::Show("Prioritaet '$prio' auf '$($sel.Name)' setzen? (braucht Adminrechte, kann System ausbremsen)", 'Task-Manager', 'YesNo', 'Warning')
            if ($res -ne 'Yes') { return }
        }
        $r = Set-SysPilotProcessPriority -Id $sel.Id -Priority $prio
        if ($r.Ok) { & $loadProcs } else {
            [System.Windows.MessageBox]::Show("Prioritaet konnte nicht gesetzt werden:`n$($r.Error)", 'Task-Manager', 'OK', 'Warning') | Out-Null
        }
    })
    $pc.BtnExplorer.Add_Click({
        $sel = $pc.ProcList.SelectedItem
        $pidNum = if ($sel) { $sel.Id } else { 0 }
        $pc.BtnExplorer.IsEnabled = $false
        $pc.BtnExplorer.Content = 'Lade procexp ...'
        $exe = Get-SysPilotProcessExplorer
        if ($exe) {
            $args = '/accepteula'; if ($pidNum -gt 0) { $args += "/e $pidNum" }
            Start-Process $exe -ArgumentList $args
        } else {
            [System.Windows.MessageBox]::Show('Process Explorer konnte nicht geladen werden (Download fehlgeschlagen).', 'Task-Manager', 'OK', 'Warning') | Out-Null
        }
        $pc.BtnExplorer.IsEnabled = $true
        $pc.BtnExplorer.Content = 'Process Explorer'
    })
    $pc.BtnStart.Add_Click({
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Filter = 'Programme (*.exe;*.lnk;*.bat;*.cmd)|*.exe;*.lnk;*.bat;*.cmd|Alle Dateien (*.*)|*.*'
        $dlg.Title = 'Programm starten'
        if ($dlg.ShowDialog() -eq $true) {
            try { Start-Process $dlg.FileName; & $loadProcs } catch {
                [System.Windows.MessageBox]::Show("Start fehlgeschlagen: $($_.Exception.Message)", 'Task-Manager', 'OK', 'Warning') | Out-Null
            }
        }
    })
    $pc.BtnClose.Add_Click({ $pwin.Close() })

    & $loadProcs
    if ($pc.AutoRefresh.IsChecked) { $autoTimer.Start() }
    Set-SysPilotWindowAutoSize -Win $pwin -MinWidth 1000 -MinHeight 600
    Add-SysPilotAssistantToWindow -Win $pwin -Context 'Show-SysPilotProcessWindow'
    $pwin.ShowDialog() | Out-Null
    $autoTimer.Stop()
}

# --- Toolbox-Fenster (Kategorien, startet die Konsolen-Werkzeuge) ---
function Show-SysPilotToolboxWindow {
    $P = Get-SysPilotWpfPalette
    $bc = { param($hex) [System.Windows.Media.BrushConverter]::new().ConvertFrom($hex) }
    $twin = New-Object System.Windows.Window
    $twin.Title = 'SysPilot - Toolbox'
    $twin.Width = 640; $twin.Height = 560
    $twin.Background = & $bc $P.Bg
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
    $head.Foreground = & $bc $P.Accent
    $panel.Children.Add($head) | Out-Null
    $hint = New-Object System.Windows.Controls.TextBlock
    $hint.Text = 'Jedes Werkzeug oeffnet sich in einem eigenen Fenster. Mauszeiger auf einen Eintrag = Erklaerung.'
    $hint.FontSize = 11; $hint.Foreground = & $bc $P.Muted
    $hint.Margin = '0,2,0,10'
    $panel.Children.Add($hint) | Out-Null

    $tools = Get-SysPilotToolbox
    foreach ($cat in ($tools | Group-Object Category)) {
        $catHead = New-Object System.Windows.Controls.TextBlock
        $catHead.Text = $cat.Name
        $catHead.FontSize = 15; $catHead.FontWeight = 'Bold'
        $catHead.Foreground = & $bc $P.Warn
        $catHead.Margin = '0,10,0,4'
        $panel.Children.Add($catHead) | Out-Null

        $wrap = New-Object System.Windows.Controls.WrapPanel
        foreach ($t in $cat.Group) {
            $btn = New-Object System.Windows.Controls.Button
            $btn.Content = $t.Name + $(if ($t.NeedsAdmin) { ' [Admin]' } else { '' })
            $btn.ToolTip = $t.Desc
            $btn.Tag = $t.Key
            $btn.Margin = '3'; $btn.Padding = '10,6'
            $btn.Background = & $bc '#FF2D2D44'
            $btn.Foreground = & $bc '#FFE0E0E0'
            $btn.BorderBrush = & $bc '#FF4A4A6A'
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
    Set-SysPilotWindowAutoSize -Win $twin -MinWidth 860 -MinHeight 540
    Add-SysPilotAssistantToWindow -Win $twin -Context 'Show-SysPilotToolboxWindow'
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

function Start-SysPilotToolFromGui {
    <# Startet ein Konsolen-Werkzeug aus der GUI heraus in einem eigenen
       PowerShell-Fenster. Admin-Pflicht wird ueber die Toolbox-Metadaten
       (Get-SysPilotToolbox -> NeedsAdmin) erkannt und elevated gestartet. #>
    param(
        [Parameter(Mandatory)][string]$Tool,
        [switch]$FromGui,
        [switch]$VisibleConsole,
        [switch]$HiddenConsole
    )
    $root = $script:Root
    if (-not $root) { $root = Split-Path -Parent $PSCommandPath }
    if (-not $root) {
        [System.Windows.MessageBox]::Show('Installationspfad nicht gefunden. Bitte GUI neu starten.', 'SysPilot', 'OK', 'Warning') | Out-Null
        return
    }
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File', (Join-Path $root 'SysPilot.ps1'), '-Tool', $Tool)
    $cmdLine = ConvertTo-SysPilotArgString $argList
    $needsAdmin = $false
    try {
        $tb = @(Get-SysPilotToolbox | Where-Object { $_.Key -eq $Tool }) | Select-Object -First 1
        if ($tb) { $needsAdmin = [bool]$tb.NeedsAdmin }
    } catch { }
    try {
        if ($needsAdmin -and -not (Test-SysPilotAdmin)) {
            Start-Process powershell.exe -Verb RunAs -ArgumentList $cmdLine
        } elseif ($HiddenConsole) {
            # Reine WPF-Tools (z.B. herbertfull, kimgr): kein Konsolenfenster
            Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $cmdLine
        } else {
            Start-Process powershell.exe -ArgumentList $cmdLine
        }
    } catch {
        [System.Windows.MessageBox]::Show("Das Werkzeug konnte nicht gestartet werden:`n$($_.Exception.Message)", 'SysPilot', 'OK', 'Warning') | Out-Null
    }
}

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
$ctrl.BtnDns.Add_Click({ Start-SysPilotToolFromGui -Tool 'dns' -FromGui })
$ctrl.BtnUpdates.Add_Click({ Start-SysPilotToolFromGui -Tool 'updates' -FromGui })
$ctrl.BtnDlFind.Add_Click({ try { Show-SysPilotDownloadFinder -Title 'Download-Suche (KI-Pseudo-Paketmanager)' } catch { Show-SysPilotWindow } })
$ctrl.BtnAppSearch.Add_Click({ try { Show-SysPilotAppSearchWindow -Title 'Programm-Suche (alle Paketmanager + KI)' } catch { Show-SysPilotWindow } })
$ctrl.BtnDrvStudio.Add_Click({ try { Show-SysPilotDriverStudioWindow -Title 'SmartDriver Studio - Treiber-Werkstatt' } catch { Show-SysPilotWindow } })
$ctrl.BtnKi.Add_Click({
    # Grosser KI-Button oeffnet jetzt denselben schwebenden Herbert-Chat
    # wie die Kugel - Menue-Button im Panel fuer alle Assistent-Funktionen.
    if ($ctrl.KiChatPanel.Visibility -eq 'Visible') { $ctrl.KiChatPanel.Visibility = 'Collapsed' }
    else { Show-SysPilotKiPanel }
})
$ctrl.BtnProcs.Add_Click({ Show-SysPilotProcessWindow })
$ctrl.BtnCf.Add_Click({ Start-SysPilotToolFromGui -Tool 'cloudflare' -FromGui })
$ctrl.BtnCare.Add_Click({ Start-SysPilotToolFromGui -Tool 'carecenter' -FromGui })
$ctrl.BtnTweaks.Add_Click({ Start-SysPilotToolFromGui -Tool 'tweakstudio' -FromGui })
$ctrl.BtnRegGal.Add_Click({ Start-SysPilotToolFromGui -Tool 'reggallery' -FromGui })
$ctrl.BtnHealth.Add_Click({ Start-SysPilotToolFromGui -Tool 'health' -FromGui })
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
    $msg = "Echte CPU-Temperatur statt Schaetzung?`n`nDein Laptop gibt den Temperatur-Sensor nicht direkt frei. SysPilot schaetzt die Temperatur aktuell aus Last + Takt.`n`nLibreHardwareMonitor (kostenlos, Open Source, ~5 MB, portable) liest den echten Sensor. SysPilot nutzt ihn dann automatisch - auch fuer den Hitzeschutz (Notaus bei 95 Grad C).`n`nJetzt als Administrator installieren und starten?"
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
$script:notifyIcon.BalloonTipText = 'Doppelklick oeffnet das Dashboard; Rechtsklick zeigt Aktionen.'

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

# --- Tastatur-Steuerung: Pfeiltasten durch Buttons, Enter = ausfuehren, Esc = schliessen ---
$win.Add_KeyDown({
    param($s, $e)
    if ($e.Key -eq 'Escape') { $win.Close(); return }
    if ($e.Key -eq 'Left' -or $e.Key -eq 'Right' -or $e.Key -eq 'Up' -or $e.Key -eq 'Down') {
$buttons = @($ctrl.BtnCheckup,$ctrl.BtnToolbox, $ctrl.BtnDns, $ctrl.BtnHealth, $ctrl.BtnAuto, $ctrl.BtnCool, $ctrl.BtnPerf, $ctrl.BtnFreeRam, $ctrl.BtnPriorities, $ctrl.BtnGaming, $ctrl.BtnWork, $ctrl.BtnNight, $ctrl.BtnLHM, $ctrl.BtnMenu, $ctrl.BtnUpdates, $ctrl.BtnDlFind, $ctrl.BtnAppSearch, $ctrl.BtnDrvStudio, $ctrl.BtnKi, $ctrl.BtnProcs, $ctrl.BtnCf, $ctrl.BtnCare, $ctrl.BtnTweaks, $ctrl.BtnRegGal)
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
        # Expliziter Zweitstart = Nutzer will das Fenster: immer zeigen,
        # beim Spielen nur ohne Fokus-Vergiff aktivieren.
        $gamingNow = Test-SysPilotGamingActive
        $win.Show(); $win.WindowState = 'Normal'
        if (-not $gamingNow) { $win.Activate() | Out-Null }
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
$kiWatch.Start()

# Herbert-API Auto-Start (ai-assist.json: ApiAutoStart) - versteckt,
# laeuft unabhaengig vom GUI-Fenster weiter.
try {
    if (Get-Command Read-SysPilotAiAssistConfig -ErrorAction SilentlyContinue) {
        $ac = Read-SysPilotAiAssistConfig
        if ($ac.ApiAutoStart -and (Get-Command Start-SysPilotHerbertApi -ErrorAction SilentlyContinue)) {
            $hst = Get-SysPilotHerbertApiStatus
            if (-not $hst.Running) { Start-SysPilotHerbertApi | Out-Null }
        }
    }
} catch {}

# Erstausfuehrung (auch portabel/Dev): Download-Tools (aria2, yt-dlp,
# ffmpeg), llama.cpp-Backend und Paketmanager im Hintergrund sicherstellen.
# Einmalig pro Installation - Stempeldatei verhindert Wiederholung.
try {
    $prereqStamp = Join-Path $env:LOCALAPPDATA 'SysPilot\prereqs.done'
    if (-not (Test-Path $prereqStamp) -and (Get-Command Ensure-SysPilotPrereqs -ErrorAction SilentlyContinue)) {
        $prereqDir = Join-Path $env:LOCALAPPDATA 'SysPilot'
        if (-not (Test-Path $prereqDir)) { New-Item -ItemType Directory -Force -Path $prereqDir | Out-Null }
        $script:prereqJob = Start-Job -ScriptBlock {
            param($md, $stamp)
            try {
                Get-ChildItem $md -Filter '*.psm1' | ForEach-Object { try { Import-Module $_.FullName -Force -ErrorAction SilentlyContinue } catch {} }
                $r = Ensure-SysPilotPrereqs -Quiet
                try { Write-SysPilotLog ("Prereqs (Erststart): installiert={0} uebersprungen={1} fehlgeschlagen={2}" -f (@($r.Installed)-join ', '), (@($r.Skipped)-join ', '), (@($r.Failed)-join ', ')) } catch {}
            } catch {}
            try { Set-Content -Path $stamp -Value (Get-Date -Format o) -Encoding UTF8 } catch {}
        } -ArgumentList (Join-Path $script:Root 'modules'), $prereqStamp
    }
} catch {}

# Herbert-Onboarding (einmalig): optionale Extras + Was-kann-er-Ueberblick.
# Wird nach ~25s geoeffnet, solange kein Entsheidungs-Stempel existiert.
try {
    $script:obStampPath = Join-Path $env:LOCALAPPDATA 'SysPilot\herbert-onboard.done'
    if (-not (Test-Path $script:obStampPath) -and (Get-Command Show-SysPilotHerbertOnboarding -ErrorAction SilentlyContinue)) {
        $script:obTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:obTimer.Interval = [TimeSpan]::FromSeconds(25)
        $script:obTimer.Add_Tick({
            $script:obTimer.Stop()
            try {
                if (-not (Test-Path $script:obStampPath)) {
                    Show-SysPilotHerbertOnboarding -Owner $win | Out-Null
                }
            } catch {}
        })
        $script:obTimer.Start()
    }
} catch {}

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
}
# ShowDialog zeigt das Fenster selbst an (bzw. laesst es versteckt bei Tray);
# Show() vorher wirft "ShowDialog kann nur fuer ausgeblendete Fenster".
$win.ShowDialog() | Out-Null
$timer.Stop()
$showTimer.Stop()
$updStart.Stop(); $updPoll.Stop()
$kiWatch.Stop(); $kiPoll.Stop()
if ($script:kiPs) {
    try { $script:kiPs.Dispose(); $script:kiRs.Close(); $script:kiRs.Dispose() } catch {}
}
if ($script:updPs) {
    try { $script:updPs.Dispose(); $script:updRs.Close(); $script:updRs.Dispose() } catch { }
}
$script:notifyIcon.Visible = $false
$script:notifyIcon.Dispose()
if ($script:guiMutex) { try { $script:guiMutex.ReleaseMutex() | Out-Null } catch { }; $script:guiMutex.Dispose() }
