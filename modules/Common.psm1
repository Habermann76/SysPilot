# SysPilot - Common: Admin-Check, Logging, Config, Backup/Restore
#Requires -Version 5.1

$script:SysPilotRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$script:Config = $null

function Test-SysPilotAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class SysPilotGameCheck {
    [DllImport("shell32.dll")]
    public static extern int SHQueryUserNotificationState(out int pquns);
}
"@ -ErrorAction SilentlyContinue

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class SysPilotConsoleInput {
    [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
    [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool ReadConsoleInput(IntPtr hConsoleInput, [Out] INPUT_RECORD[] lpBuffer, uint nLength, out uint lpNumberOfEventsRead);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetConsoleScreenBufferInfo(IntPtr hConsoleOutput, out CONSOLE_SCREEN_BUFFER_INFO lpConsoleScreenBufferInfo);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetConsoleCursorPosition(IntPtr hConsoleOutput, COORD dwCursorPosition);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetConsoleCursorPosition(IntPtr hConsoleOutput, out COORD lpCursorPosition);

    [StructLayout(LayoutKind.Sequential)] public struct COORD { public short X; public short Y; }
    [StructLayout(LayoutKind.Sequential)] public struct SMALL_RECT { public short Left; public short Top; public short Right; public short Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct CONSOLE_SCREEN_BUFFER_INFO {
        public COORD dwSize; public COORD dwCursorPosition; public short wAttributes;
        public SMALL_RECT srWindow; public COORD dwMaximumWindowSize;
    }
    [StructLayout(LayoutKind.Sequential)] public struct KEY_EVENT_RECORD {
        public int bKeyDown; public short wRepeatCount; public short wVirtualKeyCode;
        public short wVirtualScanCode; public char UnicodeChar; public int dwControlKeyState;
    }
    [StructLayout(LayoutKind.Sequential)] public struct MOUSE_EVENT_RECORD {
        public COORD dwMousePosition; public uint dwButtonState; public uint dwControlKeyState; public uint dwEventFlags;
    }
    [StructLayout(LayoutKind.Explicit, Size=20)] public struct INPUT_RECORD {
        [FieldOffset(0)] public ushort EventType;
        [FieldOffset(4)] public KEY_EVENT_RECORD KeyEvent;
        [FieldOffset(4)] public MOUSE_EVENT_RECORD MouseEvent;
    }
}
"@ -ErrorAction SilentlyContinue

function Test-SysPilotGamingActive {
    <# Gibt $true zurueck, wenn ein Spiel laeuft oder eine Vollbild-/Direct3D-Anwendung aktiv ist.
       Schuetzt Spiele vor stoerenden Fenstern, Popups und Fokus-Verlust. #>
    try {
        $state = 0
        if ([SysPilotGameCheck]::SHQueryUserNotificationState([ref]$state) -eq 0) {
            # 2 = QUNS_BUSY (Vollbild / D3D Exklusiv)
            # 3 = QUNS_RUNNING_D3D_FULL_SCREEN (Direct3D Vollbild, typisch fuer Spiele)
            # 4 = QUNS_PRESENTATION_MODE
            # 7 = QUNS_APP (Vollbild Store-App)
            if ($state -in 2, 3, 4, 7) { return $true }
        }
    } catch { }

    try {
        $cfg = Get-SysPilotConfig
        if ($cfg -and $cfg.GameProcesses -and $cfg.GameProcesses.Count -gt 0) {
            $running = Get-Process -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ProcessName
            foreach ($g in $cfg.GameProcesses) {
                $base = $g -replace '\.exe$',''
                if ($running -contains $base) { return $true }
            }
        }
    } catch { }

    return $false
}

function Assert-SysPilotAdmin {
    if (-not (Test-SysPilotAdmin)) {
        Write-Host ""
        Write-Host "  [!] Diese Aktion braucht Administrator-Rechte." -ForegroundColor Yellow
        Write-Host "      Bitte SysPilot ueber den Menuepunkt 'Als Administrator neu starten' oeffnen." -ForegroundColor Yellow
        Write-Host ""
        return $false
    }
    return $true
}

function Restart-SysPilotElevated {
    <# Startet das aktuelle Skript (GUI oder Konsole) mit Admin-Rechten neu.
       -NoExit: das aufrufende Skript beendet sich selbst (kein hartes exit,
       damit die GUI sauber aufraeumen kann). #>
    param([switch]$NoExit)
    if (Test-SysPilotAdmin) { return }
    $exe = "powershell.exe"
    if ($PSVersionTable.PSEdition -eq 'Core') { $exe = "pwsh.exe" }
    # Aufrufendes Skript ermitteln ($PSCommandPath zeigt innerhalb eines Moduls auf die .psm1, nicht auf das Skript)
    $caller = Get-PSCallStack | Where-Object { $_.ScriptName -and $_.ScriptName -like '*.ps1' } | Select-Object -First 1
    $current = if ($caller) { $caller.ScriptName } else { $null }
    if (-not $current) { $current = Join-Path $script:SysPilotRoot "SysPilot.ps1" }
    $argList = if ((Split-Path $current -Leaf) -ieq 'SysPilot-GUI.ps1') { "-STA -NoProfile -ExecutionPolicy Bypass" } else { "-NoProfile -ExecutionPolicy Bypass" }
    # Nur die GUI laeuft ohne Konsolenfenster (sie versteckt es selbst). Das Text-Menue (SysPilot.ps1)
    # braucht sein Fenster - versteckt waere es unsichtbar und die App wirkt "nicht gestartet".
    if ((Split-Path $current -Leaf) -ieq 'SysPilot-GUI.ps1') { $argList += " -WindowStyle Hidden" }
    $argList += " -File `"$current`""
    Start-Process $exe -Verb RunAs -ArgumentList $argList
    if (-not $NoExit) { exit }
}

function ConvertTo-SysPilotArgString {
    <# Baut aus einer Argumentliste eine korrekt gequotete Kommandozeile.
       Start-Process -ArgumentList @(...) setzt Pfade mit Leerzeichen NICHT in Anfuehrungszeichen
       (z.B. "C:\Program Files\SysPilot\SysPilot.ps1") - dann startet das Werkzeug nicht. #>
    param([string[]]$ArgList)
    $parts = foreach ($a in $ArgList) {
        if ($null -eq $a -or $a -eq '') { '""' }
        elseif ($a -match '[\s"]') { '"' + ($a -replace '"', '\"') + '"' }
        else { $a }
    }
    return ($parts -join ' ')
}

function Start-SysPilotGuiTool {
    <# Einheitlicher, sicherer Starter für Toolbox-Aktionen aus der GUI. #>
    param(
        [Parameter(Mandatory)][string]$ToolKey,
        [bool]$NeedsAdmin = $false,
        [string]$WorkingDirectory = $script:SysPilotRoot
    )
    $scriptPath = Join-Path $script:SysPilotRoot 'SysPilot.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "SysPilot-Hauptskript nicht gefunden: $scriptPath"
    }
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$scriptPath,'-Tool',$ToolKey)
    $argString = ConvertTo-SysPilotArgString $args
    $params = @{ FilePath = $(if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }); ArgumentList = $argString; WorkingDirectory = $WorkingDirectory; WindowStyle = 'Normal' }
    if ($NeedsAdmin -and -not (Test-SysPilotAdmin)) { $params.Verb = 'RunAs' }
    try {
        $process = Start-Process @params -PassThru -ErrorAction Stop
        Write-SysPilotLog "GUI-Tool gestartet: $ToolKey (Admin=$NeedsAdmin, PID=$($process.Id))"
        return $process
    } catch {
        Write-SysPilotLog "GUI-Tool konnte nicht starten: $ToolKey - $($_.Exception.Message)" 'ERROR'
        throw
    }
}

function Search-SysPilotGuiTopic {
    param([Parameter(Mandatory)][string]$Query)
    $encoded = [Uri]::EscapeDataString("SysPilot $Query")
    Start-Process "https://www.bing.com/search?q=$encoded"
}

$script:_logSessionHeaderWritten = $false

function Write-SysPilotLog {
    <# Zentrales Log. Schreibt nach <root>\logs\syspilot-<datum>.log;
       falls das nicht beschreibbar ist (z.B. Program Files ohne Admin),
       Fallback auf %LOCALAPPDATA%\SysPilot\logs. Erste Zeile jeder
       Session = Header mit Version/PID/User/Admin. #>
    param([string]$Message, [string]$Level = "INFO")
    try {
        $candidates = @(
            (Join-Path $script:SysPilotRoot "logs"),
            (Join-Path $env:LOCALAPPDATA "SysPilot\logs")
        ) | Select-Object -Unique
        $line = "{0} [{1}] {2}" -f (Get-Date -Format "HH:mm:ss.fff"), $Level, $Message
        foreach ($d in $candidates) {
            try {
                if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d -ErrorAction Stop | Out-Null }
                $file = Join-Path $d ("syspilot-" + (Get-Date -Format "yyyy-MM-dd") + ".log")
                if (-not $script:_logSessionHeaderWritten) {
                    $script:_logSessionHeaderWritten = $true
                    $ver = ''
                    try { $ver = (Get-Content (Join-Path $script:SysPilotRoot 'version.txt') -Raw -ErrorAction Stop).Trim() } catch { }
                    $hdr = "=== SysPilot $ver | PID $PID | User $env:USERNAME | Admin $(Test-SysPilotAdmin) | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
                    Add-Content -Path $file -Value $hdr -Encoding UTF8 -ErrorAction Stop
                }
                Add-Content -Path $file -Value $line -Encoding UTF8 -ErrorAction Stop
                return
            } catch { }
        }
    } catch { }
}

function Write-SysPilotDebug {
    <# DETAIL-Log fuer Fehlersuche (Extension-Entfernung, Policy-Ops,
       Menue-Entscheidungen). Landet im selben Log mit Level DEBUG. #>
    param([Parameter(Mandatory)][string]$Message)
    Write-SysPilotLog -Message $Message -Level 'DEBUG'
}

function Get-SysPilotLogFiles {
    <# Alle vorhandenen Log-Dateien (beide moeglichen Orte). #>
    $dirs = @(
        (Join-Path $script:SysPilotRoot "logs"),
        (Join-Path $env:LOCALAPPDATA "SysPilot\logs")
    ) | Select-Object -Unique
    $files = @()
    foreach ($d in $dirs) {
        if (Test-Path $d) { $files += Get-ChildItem $d -Filter 'syspilot-*.log' -File -ErrorAction SilentlyContinue }
    }
    return $files | Sort-Object LastWriteTime -Descending
}

function Get-SysPilotConfig {
    if ($null -eq $script:Config) {
        $path = Join-Path $script:SysPilotRoot "config.json"
        $script:Config = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    return $script:Config
}

function Reset-SysPilotConfig { $script:Config = $null }

function Test-NameMatch {
    # Wildcard-Match (* am Ende oder Anfang erlaubt), case-insensitive
    param([string]$Name, [string[]]$Patterns)
    foreach ($pat in $Patterns) {
        if ($Name -like $pat) { return $true }
        if ($Name -like "$pat*") { return $true }
    }
    return $false
}

function Get-SysPilotProcessByName {
    param([string]$Name)
    $base = $Name -replace '\.exe$',''
    Get-Process -Name $base -ErrorAction SilentlyContinue
}

function New-SysPilotBackup {
    param([string]$Label = "manual")
    $dir = Join-Path $script:SysPilotRoot "backup"
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $target = Join-Path $dir "$stamp-$Label"
    New-Item -ItemType Directory -Force -Path $target | Out-Null

    # Dienste
    Get-CimInstance Win32_Service | Select-Object Name, StartMode, State |
        Export-Csv -Path (Join-Path $target "services.csv") -NoTypeInformation -Encoding UTF8

    # Autostart (Registry Run-Schluessel)
    $runKeys = @(
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32"
    )
    $regOut = Join-Path $target "registry"
    New-Item -ItemType Directory -Force -Path $regOut | Out-Null
    $i = 0
    foreach ($k in $runKeys) {
        $i++
        $regPath = $k -replace '^HKCU:\\','HKEY_CURRENT_USER\' -replace '^HKLM:\\','HKEY_LOCAL_MACHINE\'
        & reg.exe export $regPath (Join-Path $regOut "run-$i.reg") /y 2>$null | Out-Null
    }

    # Energieplaene exportieren
    $plans = & powercfg /list
    foreach ($line in $plans) {
        if ($line -match '([0-9a-fA-F-]{36})') {
            $guid = $matches[1]
            & powercfg /export (Join-Path $target "plan-$guid.pow") $guid 2>$null | Out-Null
        }
    }

    Write-SysPilotLog "Backup erstellt: $target"
    return $target
}

function Get-SysPilotBackupDir {
    $dir = Join-Path $script:SysPilotRoot "backup"
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    return $dir
}

function Import-SysPilotModule {
    <# Importiert ein Geschwister-Modul aus modules\ idempotent.
       Nutzt $script:SysPilotRoot aus Common.psm1. #>
    param([Parameter(Mandatory)][string]$Name)
    if (Get-Module $Name -ErrorAction SilentlyContinue) { return }
    $p = Join-Path $script:SysPilotRoot "modules\$Name.psm1"
    # -Global: ohne es landet das Modul nur in der Session-State des
    # aufrufenden Moduls und seine Funktionen sind global unsichtbar.
    if (Test-Path $p) { Import-Module $p -Force -Global -ErrorAction SilentlyContinue }
}

function Set-SysPilotWpfDarkTheme {
    <# Zieht ein komplettes SysPilot-Dark-Theme auf ein
       code-gebautes WPF-Fenster: Background/Foreground/FontFamily
       plus Styles fuer Button, TextBox, ComboBox (inkl. dunklem
       Dropdown), ListBox, CheckBox, RadioButton, ProgressBar,
       ToolTip. Idempotent - kann mehrfach aufgerufen werden.
       Basiert auf Get-SysPilotWpfPalette. #>
    param(
        [Parameter(Mandatory)]$Win,
        [switch]$NoBackground
    )
    if (-not ('System.Windows.Markup.XamlReader' -as [type])) {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction SilentlyContinue
    }
    $P = Get-SysPilotWpfPalette
    if (-not $NoBackground) {
        $Win.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom($P.Bg)
        $Win.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom($P.Fg)
    }
    $Win.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe UI')

    $xaml = @"
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Style TargetType="Button">
    <Setter Property="Background" Value="$($P.Panel)"/>
    <Setter Property="Foreground" Value="$($P.Fg)"/>
    <Setter Property="BorderBrush" Value="$($P.Border)"/>
    <Setter Property="Padding" Value="12,5"/>
    <Setter Property="Margin" Value="3"/>
    <Setter Property="Cursor" Value="Hand"/>
  </Style>
  <Style TargetType="TextBox">
    <Setter Property="Background" Value="$($P.Input)"/>
    <Setter Property="Foreground" Value="$($P.Fg)"/>
    <Setter Property="BorderBrush" Value="$($P.Border)"/>
    <Setter Property="CaretBrush" Value="$($P.Accent)"/>
    <Setter Property="Padding" Value="5,3"/>
    <Setter Property="VerticalContentAlignment" Value="Center"/>
  </Style>
  <ControlTemplate x:Key="ComboBoxToggleTemplate" TargetType="ToggleButton">
    <Border x:Name="Bg" Background="$($P.Input)" BorderBrush="$($P.Border)" BorderThickness="1" CornerRadius="2"/>
    <ControlTemplate.Triggers>
      <Trigger Property="IsMouseOver" Value="True"><Setter Property="BorderBrush" Value="$($P.Accent)"/></Trigger>
      <Trigger Property="IsChecked" Value="True"><Setter Property="BorderBrush" Value="$($P.Accent)"/></Trigger>
    </ControlTemplate.Triggers>
  </ControlTemplate>
  <Style TargetType="ComboBox">
    <Setter Property="Background" Value="$($P.Input)"/>
    <Setter Property="Foreground" Value="$($P.Fg)"/>
    <Setter Property="BorderBrush" Value="$($P.Border)"/>
    <Setter Property="Padding" Value="5,3"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ComboBox">
          <Grid>
            <ToggleButton x:Name="ToggleButton" Template="{StaticResource ComboBoxToggleTemplate}"
                          Grid.ColumnSpan="2" IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"
                          Focusable="False"/>
            <ContentPresenter x:Name="ContentSite" IsHitTestVisible="False"
                              Content="{TemplateBinding SelectionBoxItem}"
                              ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                              ContentTemplateSelector="{TemplateBinding ItemTemplateSelector}"
                              Margin="8,0,24,0" VerticalAlignment="Center" HorizontalAlignment="Left"/>
            <Popup x:Name="Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}"
                   AllowsTransparency="True" Focusable="False" PopupAnimation="Slide">
              <Border x:Name="DropDownBorder" Background="$($P.Panel)" BorderBrush="$($P.Border)" BorderThickness="1"
                      MinWidth="{TemplateBinding ActualWidth}" MaxHeight="300">
                <ScrollViewer SnapsToDevicePixels="True">
                  <ItemsPresenter/>
                </ScrollViewer>
              </Border>
            </Popup>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property="IsEnabled" Value="False">
              <Setter Property="Opacity" Value="0.55"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style TargetType="ComboBoxItem">
    <Setter Property="Foreground" Value="$($P.Fg)"/>
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="Padding" Value="8,4"/>
    <Style.Triggers>
      <Trigger Property="IsHighlighted" Value="True"><Setter Property="Background" Value="$($P.Border)"/></Trigger>
    </Style.Triggers>
  </Style>
  <Style TargetType="ListBox">
    <Setter Property="Background" Value="$($P.Panel)"/>
    <Setter Property="Foreground" Value="$($P.Fg)"/>
    <Setter Property="BorderBrush" Value="$($P.Border)"/>
  </Style>
  <Style TargetType="ListBoxItem">
    <Setter Property="Foreground" Value="$($P.Fg)"/>
    <Setter Property="Padding" Value="6,4"/>
    <Style.Triggers>
      <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="$($P.Border)"/></Trigger>
      <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="$($P.Input)"/></Trigger>
    </Style.Triggers>
  </Style>
  <Style TargetType="CheckBox"><Setter Property="Foreground" Value="$($P.Fg)"/></Style>
  <Style TargetType="RadioButton"><Setter Property="Foreground" Value="$($P.Fg)"/></Style>
  <Style TargetType="ProgressBar">
    <Setter Property="Background" Value="$($P.Input)"/>
    <Setter Property="Foreground" Value="$($P.Accent)"/>
    <Setter Property="Height" Value="6"/>
  </Style>
  <Style TargetType="ToolTip">
    <Setter Property="Background" Value="$($P.Panel)"/>
    <Setter Property="Foreground" Value="$($P.Fg)"/>
    <Setter Property="BorderBrush" Value="$($P.Border)"/>
  </Style>
</ResourceDictionary>
"@
    try {
        $rd = [System.Windows.Markup.XamlReader]::Parse($xaml)
        $Win.Resources.MergedDictionaries.Add($rd)
    } catch {
        # Fallback: nur Grundfarben (Styles scheitern nie still ignorieren? doch - UI soll laufen)
        Write-Host "  [i] WPF-Dark-Theme nur teilweise anwendbar: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

function Show-SysPilotDownloadDialog {
    <# Modaler WPF-Fortschrittsdialog fuer Downloads: Balken,
       MB/MBS/ETA live, Abbrechen, danach Ordner oeffnen.
       Der eigentliche Download laeuft in einem Kind-Runspace
       (Save-SysPilotUrlToFile mit -ProgressQueue), die UI wird
       per DispatcherTimer aktualisiert.
       Rueckgabe: @{Ok;Path;Error;Cancelled}.
       Ohne STA (MTA-Konsole) -> klassischer Konsolen-Download. #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$OutFile,
        [string]$Label = 'Download',
        [int]$TimeoutSec = 600,
        [string]$Title = 'SysPilot - Download'
    )
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
        $ok = Save-SysPilotUrlToFile -Uri $Url -OutFile $OutFile -TimeoutSec $TimeoutSec -Label $Label -AllowAbort
        return @{ Ok=$ok; Path=$(if($ok){$OutFile}else{$null}); Error=$(if($ok){''}else{'Download fehlgeschlagen'}); Cancelled=$false }
    }
    if (-not ('System.Windows.Markup.XamlReader' -as [type])) {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction SilentlyContinue
    }
    $modDir = Join-Path $script:SysPilotRoot 'modules'
    $P = Get-SysPilotWpfPalette
    $bc = { param($h) [System.Windows.Media.BrushConverter]::new().ConvertFrom($h) }

    # --- Runspace mit dem echten Downloader ---
    $q = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $dlCode = @'
param($modDir,$u,$o,$l,$t,$pq)
Import-Module (Join-Path $modDir 'Common.psm1') -Force -ErrorAction SilentlyContinue
try {
    $ok = Invoke-SysPilotSmartFileDownload -Uri $u -OutFile $o -Label $l -TimeoutSec $t -ProgressQueue $pq
    @{ Ok=[bool]$ok; Err='' }
} catch { @{ Ok=$false; Err=$_.Exception.Message } }
'@
    $crs = [runspacefactory]::CreateRunspace(); $crs.ApartmentState='STA'; $crs.Open()
    $ps = [powershell]::Create(); $ps.Runspace=$crs
    [void]$ps.AddScript($dlCode)
    [void]$ps.AddArgument($modDir); [void]$ps.AddArgument($Url); [void]$ps.AddArgument($OutFile)
    [void]$ps.AddArgument($Label); [void]$ps.AddArgument($TimeoutSec); [void]$ps.AddArgument($q)
    $handle = $ps.BeginInvoke()

    # --- Fenster ---
    $win = New-Object System.Windows.Window
    $win.Title = $Title; $win.Width = 520; $win.Height = 210
    $win.ResizeMode = 'NoResize'; $win.WindowStartupLocation = 'CenterScreen'
    $win.Background = & $bc $P.Bg; $win.Foreground = & $bc $P.Fg
    $win.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe UI')

    $grid = New-Object System.Windows.Controls.Grid; $grid.Margin='18,14,18,12'
    $win.Content = $grid
    foreach ($h in 'Auto','Auto','*','Auto','Auto') {
        $rd = New-Object System.Windows.Controls.RowDefinition; $rd.Height=$h
        $grid.RowDefinitions.Add($rd) | Out-Null
    }
    # Zeile 0: Dateiname + Groesse
    $fn = New-Object System.Windows.Controls.TextBlock
    $fn.Text = "$Label"; $fn.FontWeight='SemiBold'; $fn.FontSize=14
    $fn.Foreground = & $bc $P.Fg; $fn.TextTrimming='CharacterEllipsis'
    $fn.ToolTip = $OutFile
    [System.Windows.Controls.Grid]::SetRow($fn,0); $grid.Children.Add($fn) | Out-Null
    $size = New-Object System.Windows.Controls.TextBlock
    $size.Text = [IO.Path]::GetFileName($OutFile); $size.FontSize=11
    $size.Foreground = & $bc $P.Muted; $size.HorizontalAlignment='Right'
    [System.Windows.Controls.Grid]::SetRow($size,0); $grid.Children.Add($size) | Out-Null
    # Zeile 1: Status
    $stat = New-Object System.Windows.Controls.TextBlock
    $stat.Text = 'Verbinde ...'; $stat.FontSize=12
    $stat.Foreground = & $bc $P.Muted
    [System.Windows.Controls.Grid]::SetRow($stat,1); $grid.Children.Add($stat) | Out-Null
    # Zeile 2: Balken
    $bar = New-Object System.Windows.Controls.ProgressBar
    $bar.Minimum=0; $bar.Maximum=100; $bar.Value=0; $bar.Height=10
    $bar.Background = & $bc $P.Input; $bar.Foreground = & $bc $P.Accent
    $bar.Margin='0,6,0,4'
    [System.Windows.Controls.Grid]::SetRow($bar,2); $grid.Children.Add($bar) | Out-Null
    # Zeile 3: Detail (MB/s, ETA)
    $det = New-Object System.Windows.Controls.TextBlock
    $det.Text=''; $det.FontSize=11; $det.Foreground = & $bc $P.Muted
    [System.Windows.Controls.Grid]::SetRow($det,3); $grid.Children.Add($det) | Out-Null
    # Zeile 4: Buttons
    $btns = New-Object System.Windows.Controls.StackPanel
    $btns.Orientation='Horizontal'; $btns.HorizontalAlignment='Right'
    [System.Windows.Controls.Grid]::SetRow($btns,4); $grid.Children.Add($btns) | Out-Null
    $mkB = { param($l,$bg,$fg) $b=New-Object System.Windows.Controls.Button; $b.Content=$l; $b.Padding='16,5'; $b.Margin='4,0,0,0'; $b.Background=& $bc $bg; $b.Foreground=& $bc $fg; $b.BorderThickness='0'; $b.Cursor='Hand'; return $b }
    $btnCancel = & $mkB 'Abbrechen' '#FFEF5350' '#FF0B0B12'
    $btnFolder = & $mkB 'Ordner oeffnen' '#FF455A64' '#FFEAF2FF'
    $btnClose  = & $mkB 'Schliessen'   '#FF2D2D44' '#FFE0E0E0'
    $btnFolder.Visibility='Collapsed'; $btnClose.Visibility='Collapsed'
    foreach ($b in @($btnCancel,$btnFolder,$btnClose)) { $btns.Children.Add($b) | Out-Null }

    $state = @{ Done=$false; Result=$null; Cancelled=$false }
    $baseDet = ''
    $sw = [Diagnostics.Stopwatch]::StartNew()

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [timespan]::FromMilliseconds(150)
    $timer.Add_Tick({
        param($s,$e)
        # Queue leeren
        $m = $null
        while ($q.TryDequeue([ref]$m)) {
            if ($m.Pct -ge 0) {
                $bar.Value = [math]::Min(100,[double]$m.Pct)
                $segTxt = if ($m.Segs) { " [$($m.Segs)]" } else { '' }
                $noteTxt = if ($m.Note) { " - $($m.Note)" } else { '' }
                $stat.Text = "$($m.Label): $($m.Pct)%$segTxt$noteTxt"
                $baseDet = "$($m.MBR) / $($m.MBT) MB  -  $($m.MBS) MB/s"
            } elseif ($m.Pct -eq -2) {
                $bar.IsIndeterminate = $true
                $stat.Text = "$($m.Label): $($m.Note)"
                $stat.Foreground = & $bc $P.Warn
            } else {
                $bar.IsIndeterminate = $true
                $stat.Text = "$($m.Label): $($m.MBR) MB geladen ..."
                $baseDet = 'Gesamtgroesse unbekannt (chunked)'
            }
        }
        if (-not $state.Done) {
            $el = [int]$sw.Elapsed.TotalSeconds
            $det.Text = $(if ($baseDet) { "$baseDet   |   $el s" } else { "Verbinde ...   |   $el s" })
        }
        # Job fertig?
        if ($handle.IsCompleted -and -not $state.Done) {
            $state.Done = $true
            try { $state.Result = @($ps.EndInvoke($handle) | Select-Object -First 1)[0] } catch { $state.Result = @{Ok=$false;Err=$_.Exception.Message} }
            try { $ps.Dispose() } catch {}
            try { $crs.Close(); $crs.Dispose() } catch {}
            $timer.Stop()
            $ok = $state.Result -and $state.Result.Ok
            if ($ok -and (Test-Path $OutFile)) {
                $bar.Value = 100; $bar.IsIndeterminate=$false
                $len = [math]::Round((Get-Item $OutFile).Length/1MB,1)
                $stat.Text = "[OK] $len MB gespeichert"; $stat.Foreground = & $bc $P.Ok
                $det.Text = $OutFile
                $btnCancel.Visibility='Collapsed'; $btnFolder.Visibility='Visible'; $btnClose.Visibility='Visible'
                $win.Title = "$Title - fertig"
            } else {
                $err = $(if ($state.Result -and $state.Result.Err) { $state.Result.Err } else { 'Download fehlgeschlagen oder abgebrochen' })
                $stat.Text = "[!] $err"; $stat.Foreground = & $bc $P.Danger
                $btnCancel.Visibility='Collapsed'; $btnClose.Visibility='Visible'
            }
        }
    }.GetNewClosure())

    $btnCancel.Add_Click({
        $state.Cancelled = $true
        try { $ps.Stop() } catch {}
        try { $crs.Close(); $crs.Dispose() } catch {}
        try { $ps.Dispose() } catch {}
        if (Test-Path $OutFile) { Remove-Item $OutFile -Force -ErrorAction SilentlyContinue }
        $win.Close()
    }.GetNewClosure())
    $btnFolder.Add_Click({ Start-Process explorer.exe -ArgumentList "/select,`"$OutFile`"" }.GetNewClosure())
    $btnClose.Add_Click({ $win.Close() }.GetNewClosure())
    $win.Add_Closed({
        if (-not $state.Done) {
            try { $ps.Stop() } catch {}
            try { $crs.Close(); $crs.Dispose() } catch {}
            try { $ps.Dispose() } catch {}
            if ($state.Cancelled -and (Test-Path $OutFile)) { Remove-Item $OutFile -Force -ErrorAction SilentlyContinue }
        }
    }.GetNewClosure())

    $timer.Start()
    try { Set-SysPilotWindowForeground -Win $win } catch {}
    $win.ShowDialog() | Out-Null

    $okFinal = ($state.Done -and $state.Result -and $state.Result.Ok -and (Test-Path $OutFile))
    return @{ Ok=[bool]$okFinal; Path=$(if($okFinal){$OutFile}else{$null})
              Error=$(if($okFinal){''}else{ $(if($state.Result -and $state.Result.Err){$state.Result.Err}else{'abgebrochen/fehlgeschlagen'}) })
              Cancelled=[bool]$state.Cancelled }
}

function Test-SysPilotInternet {
    <# Schneller Online-Check fuer instabile Verbindungen (Hotspot/
       Mobilfunk): DNS + TCP 1.1.1.1:443, 2s Timeout, 20s Cache.
       Gibt $true/$false zurueck - KEIN HTTP-Call noetig. #>
    if ($script:_netOkCache -and ((Get-Date) - $script:_netOkCache.At).TotalSeconds -lt 20) { return $script:_netOkCache.Ok }
    $ok = $false
    try {
        # 1) DNS loest auf (faengt "kein WLAN"-Faelle)
        [void][Net.Dns]::GetHostAddresses('one.one.one.one')
        # 2) TCP zu Cloudflare anycast - schnell, uaerlich
        $tcp = New-Object Net.Sockets.TcpClient
        $iar = $tcp.BeginConnect('1.1.1.1', 443, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(2000)
        $tcp.Close()
    } catch { $ok = $false }
    $script:_netOkCache = @{ Ok=$ok; At=Get-Date }
    return $ok
}

function Wait-SysPilotInternet {
    <# Wartet bei Verbindungsabbruch (Hotspot-Aussetzer) bis das Netz
       zurueck ist - max $MaxSec, Poll alle $PollSec. Gibt $true
       zurueck wenn online, $false bei Timeout. #>
    param([int]$MaxSec = 90, [int]$PollSec = 5, [string]$Label = 'Download')
    if (Test-SysPilotInternet) { return $true }
    Write-Host "  [!] Keine Internetverbindung - warte auf Wiederkehr (max ${MaxSec}s, z.B. Hotspot-Aussetzer) ..." -ForegroundColor Yellow
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $MaxSec) {
        Start-Sleep -Seconds $PollSec
        # Cache explizit invalidieren (Test cached 20s)
        $script:_netOkCache = $null
        if (Test-SysPilotInternet) {
            Write-Host "  [OK] Verbindung wieder da - fahre fort." -ForegroundColor Green
            return $true
        }
    }
    Write-Host "  [!] Immer noch offline nach ${MaxSec}s - brich ab." -ForegroundColor Red
    return $false
}

function Invoke-SysPilotHttpRequest {
    <# Robuster HTTP-Request-Wrapper fuer instabile Netze:
       bis zu $Retries Versuche mit exponentiellem Backoff
       (2s/4s/8s), laengerer Timeout optional. Wirft die letzte
       Exception wenn alle Versuche scheitern. #>
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string]$Method = 'Get',
        [hashtable]$Headers = @{},
        [object]$Body = $null,
        [string]$ContentType = 'application/json',
        [int]$TimeoutSec = 30,
        [int]$Retries = 3,
        [scriptblock]$OnRetry = $null
    )
    $lastErr = $null
    for ($i = 1; $i -le $Retries; $i++) {
        try {
            $p = @{ Uri=$Uri; Method=$Method; Headers=$Headers; TimeoutSec=$TimeoutSec; ErrorAction='Stop' }
            if ($null -ne $Body) { $p.Body = $Body; $p.ContentType = $ContentType }
            return (Invoke-WebRequest @p)
        } catch {
            $lastErr = $_
            if ($i -lt $Retries) {
                $wait = [math]::Pow(2, $i)
                if ($OnRetry) { & $OnRetry $i $wait $_.Exception.Message } else { Write-Host "  [netz] Versuch $i/$Retries fehlgeschlagen ($($_.Exception.Message)) - Retry in ${wait}s" -ForegroundColor DarkYellow }
                Start-Sleep -Seconds $wait
                # Cache invalidieren: Netz koennte wieder da sein
                $script:_netOkCache = $null
            }
        }
    }
    throw $lastErr
}

function Invoke-SysPilotFileDownload {
    <# Einheitlicher Download-Einstieg fuer interaktive Pfade:
       WPF-Fortschrittsdialog (STA) oder Konsolen-Fortschritt
       (MKA/unabhaengig). Gibt $true/$false zurueck. #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$OutFile,
        [string]$Label = 'Download',
        [int]$TimeoutSec = 600,
        [string]$Title = ''
    )
    $kind = Test-SysPilotSpecialDownloadUrl -Url $Url
    if ($kind -eq 'torrent') {
        # Torrent/Magnet: kein einzelnes OutFile - Ziel = Verzeichnis
        $outDir = Split-Path $OutFile -Parent
        if (-not $outDir) { $outDir = '.' }
        $r = Invoke-SysPilotTorrentDownload -Source $Url -OutDir $outDir -Label $Label -TimeoutSec 0
        return [bool]$r.Ok
    }
    if ([Threading.Thread]::CurrentThread.ApartmentState -eq 'STA') {
        $d = Show-SysPilotDownloadDialog -Url $Url -OutFile $OutFile -Label $Label -TimeoutSec $TimeoutSec -Title $(if($Title){"SysPilot - $Title"}else{"SysPilot - $Label"})
        return [bool]$d.Ok
    }
    return [bool](Invoke-SysPilotSmartFileDownload -Uri $Url -OutFile $OutFile -Label $Label -TimeoutSec $TimeoutSec)
}

function Get-SysPilotWpfPalette {
    <# Einheitliche Farbpalette fuer alle SysPilot-WPF-Fenster.
       Ein einziges Design: dunkles Panel, petrol-Akzent, warmes Orange
       fuer Highlights. Neue Fenster sollten IMMER diese Palette nutzen
       statt eigene Hex-Farben zu erfinden. #>
    return @{
        Bg        = '#FF1E1E2E'   # Fenstersintergrund (wie Download-Suche/SmartDrivers)
        Panel     = '#FF14141E'   # Listen/Karten
        Input     = '#FF101018'   # Eingabefelder/Log
        Border    = '#FF3A3A55'   # Rahmen
        Fg        = '#FFEAEAF2'   # Haupttext
        Muted     = '#FFB0B0C0'   # Sekundaertext
        Accent    = '#FF4FC3F7'   # primaerer Akzent (hellblau, wie Header)
        Accent2   = '#FF9CCC65'   # HerbBox-Grün / Erfolg
        Warn      = '#FFFFB74D'   # Warnung/Admin-Hinweis
        Ok        = '#FF9CCC65'   # Erfolg/aktiv
        BadgePriv = '#FFCE93D8'   # Kategorie Datenschutz/Werbung
        BadgeSys  = '#FF4FC3F7'   # Kategorie System/Netzwerk/Explorer
        Danger    = '#FFEF5350'   # Fehler
    }
}

# =====================================================================
# Auto-Fix-Hilfen: Warnungen (veraltete Buckets/Quellen/Tools) einmalig
# pro Zeitfenster selbsttaetig beheben. Stamp-Dateien in
# %LOCALAPPDATA%\SysPilot\autofix\.
# =====================================================================

function Get-SysPilotAutoFixStampPath {
    param([Parameter(Mandatory)][string]$Name)
    $dir = Join-Path $env:LOCALAPPDATA 'SysPilot\autofix'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    return (Join-Path $dir ($Name + '.stamp'))
}

function Test-SysPilotAutoFixDue {
    <# $true, wenn der Auto-Fix fuer $Name laenger als $Hours nicht lief. #>
    param([Parameter(Mandatory)][string]$Name, [int]$Hours = 24)
    $stamp = Get-SysPilotAutoFixStampPath -Name $Name
    if (-not (Test-Path $stamp)) { return $true }
    return ((Get-Date) - (Get-Item $stamp).LastWriteTime).TotalHours -ge $Hours
}

function Save-SysPilotAutoFixStamp {
    param([Parameter(Mandatory)][string]$Name)
    Set-Content -Path (Get-SysPilotAutoFixStampPath -Name $Name) -Value (Get-Date -Format 'o') -ErrorAction SilentlyContinue
}

function Get-SysPilotPortableAppsDir {
    <# Loest das PortableApps-Verzeichnis des Benutzers auf.
       Bevorzugt den echten Desktop-Ort (OneDrive-Desktop, falls umgeleitet),
       sonst OneDrive/Desktop als Fallback. Legt den Ordner an. #>
    $candidates = @(
        (Join-Path ([Environment]::GetFolderPath('Desktop')) 'PortableApps'),
        "$env:USERPROFILE\OneDrive\Desktop\PortableApps",
        "$env:USERPROFILE\Desktop\PortableApps"
    ) | Select-Object -Unique
    foreach ($d in $candidates) {
        if (Test-Path (Split-Path $d -Parent)) {
            if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
            return $d
        }
    }
    # Letzte Instanz: ersten Kandidaten trotzdem anlegen
    $d = $candidates[0]
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    return $d
}

function Get-SysPilotLocalSearchDirs {
    <# Ordner, in denen nach lokalen Installern/Downloads gesucht wird:
       Downloads + PortableApps (nur existierende). #>
    $dirs = @("$env:USERPROFILE\Downloads", (Get-SysPilotPortableAppsDir))
    return @($dirs | Select-Object -Unique | Where-Object { Test-Path $_ })
}

function Get-SysPilotBackups {
    $dir = Join-Path $script:SysPilotRoot "backup"
    if (-not (Test-Path $dir)) { return @() }
    Get-ChildItem $dir -Directory | Sort-Object Name -Descending
}

function Restore-SysPilotServices {
    param([string]$BackupPath)
    $csv = Join-Path $BackupPath "services.csv"
    if (-not (Test-Path $csv)) { Write-Host "  Kein Dienste-Backup gefunden." -ForegroundColor Red; return }
    $rows = Import-Csv $csv -Encoding UTF8
    $count = 0
    foreach ($r in $rows) {
        $svc = Get-Service -Name $r.Name -ErrorAction SilentlyContinue
        if ($svc -and $svc.StartType -ne $r.StartMode) {
            try {
                Set-Service -Name $r.Name -StartupType $r.StartMode -ErrorAction Stop
                $count++
            } catch { }
        }
    }
    Write-Host "  $count Dienste wiederhergestellt." -ForegroundColor Green
    Write-SysPilotLog "Dienste aus Backup wiederhergestellt: $BackupPath ($count)"
}

function Write-SysPilotHeader {
    param([string]$Title)
    Write-Host ""
    Write-Host ("=" * 66) -ForegroundColor DarkCyan
    Write-Host ("  " + $Title) -ForegroundColor Cyan
    Write-Host ("=" * 66) -ForegroundColor DarkCyan
}

function Show-SysPilotWpfInput {
    <# WPF-Eingabedialog: Maus-Bedienung, Rechtsklick = Einfuegen (WPF-
       Standard), Enter = OK, Esc = Abbrechen, optionaler Durchsuchen-
       Button fuer Dateien/Ordner. Gibt den Text zurueck oder $null
       bei Abbruch. Wirft eine Ausnahme wenn WPF nicht verfuegbar
       (z.B. MTA-Apartment) - Aufrufer faellt auf die Konsole zurueck. #>
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Default = '',
        [string]$Title = 'SysPilot',
        [int]$Width = 480,
        [switch]$Multiline,
        [switch]$BrowseFile,
        [switch]$BrowseFolder
    )
    Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
    Add-Type -AssemblyName PresentationCore -ErrorAction Stop
    Add-Type -AssemblyName WindowsBase -ErrorAction Stop
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'WPF erfordert STA-Apartment' }
    $ml = if ($Multiline) { 'AcceptsReturn="True" Height="72" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"' } else { 'Height="24"' }
    $browseTip = if ($BrowseFolder) { 'Ordner waehlen' } else { 'Datei waehlen' }
    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$Title" Width="$Width" SizeToContent="Height" MinHeight="170" MaxHeight="420"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize"
        Background="#FF1E1E2E" Foreground="#FFE0E0E0">
  <Window.Resources>
    <Style TargetType="Button"><Setter Property="Background" Value="#FF2D2D44"/><Setter Property="Foreground" Value="#FFE0E0E0"/><Setter Property="BorderBrush" Value="#FF4A4A6A"/><Setter Property="Padding" Value="14,5"/><Setter Property="Margin" Value="4,0"/><Setter Property="Cursor" Value="Hand"/></Style>
    <Style TargetType="TextBox"><Setter Property="Background" Value="#FF252538"/><Setter Property="Foreground" Value="#FFEAEAF2"/><Setter Property="BorderBrush" Value="#FF4A4A6A"/><Setter Property="Padding" Value="6,4"/><Setter Property="CaretBrush" Value="#FF4FC3F7"/><Setter Property="FontSize" Value="13"/></Style>
    <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#FFE0E0E0"/><Setter Property="FontSize" Value="12"/></Style>
  </Window.Resources>
  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <TextBlock x:Name="Lbl" Text="$([System.Security.SecurityElement]::Escape($Prompt))" TextWrapping="Wrap" Margin="0,0,0,10"/>
    <DockPanel Grid.Row="1">
      <Button x:Name="BtnBrowse" DockPanel.Dock="Right" Content="..." Width="34" Margin="4,0,0,0" Visibility="Collapsed" ToolTip="$browseTip"/>
      <TextBox x:Name="Input" $ml Text="$([System.Security.SecurityElement]::Escape($Default))"/>
    </DockPanel>
    <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
      <Button x:Name="BtnOk" Content="OK" IsDefault="True"/>
      <Button x:Name="BtnCancel" Content="Abbrechen" IsCancel="True"/>
    </StackPanel>
  </Grid>
</Window>
"@
    $win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$xaml)))
    $tb = $win.FindName('Input'); $btnBrowse = $win.FindName('BtnBrowse')
    if ($Multiline) { $tb.AcceptsReturn = $true; $tb.Height = 72 }
    if ($Default) { $tb.SelectAll() }
    $tb.Focus() | Out-Null
    if ($BrowseFile -or $BrowseFolder) {
        $btnBrowse.Visibility = 'Visible'
        $btnBrowse.Add_Click({
            if ($BrowseFolder) {
                Add-Type -AssemblyName System.Windows.Forms
                $d = New-Object System.Windows.Forms.FolderBrowserDialog
                if ($d.ShowDialog() -eq 'OK') { $tb.Text = $d.SelectedPath }
            } else {
                $d = New-Object Microsoft.Win32.OpenFileDialog
                if ($d.ShowDialog() -eq $true) { $tb.Text = $d.FileName }
            }
        })
    }
    try { Set-SysPilotWindowForeground -Win $win } catch {}
    $win.ShowDialog() | Out-Null
    if ($win.DialogResult -eq $true) { return $tb.Text }
    return $null
}

# --- Globales Fenster-Chrome (Platzierung + Vordergrund) ---------------
# Einmalig pro Prozess registrierter Window.Loaded-Class-Handler:
# JEDES WPF-Fenster mit SysPilot/Pilot-Titel bekommt automatisch einen
# freien Platz neben den anderen Fenstern (kein Ueberlappen) und wird
# in den Vordergrund geholt. Deckt auch Fenster ab, die
# Set-SysPilotWindowAutoSize/Foreground nicht explizit aufrufen.

function Register-SysPilotWindowChrome {
    <# Registriert den globalen Loaded-Class-Handler (idempotent).
       Wird lazy aus Set-SysPilotWindowForeground aufgerufen - so
       entstehen keine WPF-Kosten in reinen Konsolen-Laeufen. #>
    if ($script:_spChromeReg) { return }
    $script:_spChromeReg = $true
    try {
        Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase -ErrorAction SilentlyContinue
        if (-not ('System.Windows.Window' -as [type])) { return }
        if (-not ('SysPilotWin32' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class SysPilotWin32 {
    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lp);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    public struct RECT { public int Left, Top, Right, Bottom; }
}
'@ -ErrorAction SilentlyContinue
        }
        if (-not ('SysPilotWin32' -as [type])) { return }
        $chrome = {
            param($sender, $e)
            try {
                $w = [Windows.Window]$sender
                if ($null -eq $w) { return }
                $title = [string]$w.Title
                if ($title -notmatch '(?i)syspilot|herbert|pilot') { return }
                $rd = $w.Resources
                if ($null -eq $rd) { $rd = New-Object Windows.ResourceDictionary; $w.Resources = $rd }
                if ($rd.Contains('_spPlaced')) { return }
                $rd['_spPlaced'] = $true
                # Platzierung: freier Slot suchen (auch wenn Fenster
                # bereits sichtbar - SetWindowPos verschiebt sauber)
                try {
                    $hwnd = (New-Object Windows.Interop.WindowInteropHelper($w)).Handle
                    if ($hwnd -ne [IntPtr]::Zero) {
                        $pos = Find-SysPilotFreeWindowPosition -Win $w -Hwnd $hwnd
                        if ($pos) {
                            [SysPilotWin32]::SetWindowPos($hwnd, [IntPtr]::Zero, $pos.X, $pos.Y, 0, 0, 0x0015) | Out-Null  # NOSIZE|NOZORDER|NOACTIVATE
                        }
                    }
                } catch {}
                # Vordergrund direkt (Set-SysPilotWindowForeground haengt
                # an Loaded - das feuert hier schon/gerade)
                try { Invoke-SysPilotWindowForegroundNow -Win $w } catch {}
            } catch {}
        }
        $del = [System.Windows.RoutedEventHandler]$chrome
        [System.Windows.EventManager]::RegisterClassHandler([System.Windows.Window], [System.Windows.FrameworkElement]::LoadedEvent, $del)
    } catch {}
}

function Get-SysPilotOccupiedWindowRects {
    <# Alle sichtbaren Top-Level-Fenster mit Titel (SysPilot + fremde
       Apps) als @{L;T;R;B;Title} - Grundlage fuer die Platzierung. #>
    param([IntPtr]$ExcludeHwnd = [IntPtr]::Zero)
    $rects = New-Object 'System.Collections.Generic.List[object]'
    $cb = [SysPilotWin32+EnumProc]{
        param($h, $l)
        try {
            if ($h -eq $ExcludeHwnd) { return $true }
            if (-not [SysPilotWin32]::IsWindowVisible($h)) { return $true }
            $sb = New-Object System.Text.StringBuilder 256
            [void][SysPilotWin32]::GetWindowText($h, $sb, 256)
            $t = $sb.ToString()
            if (-not $t) { return $true }
            # System-/Shell-Fenster ohne echten Platzbedarf ausnehmen
            # (TextInputHost ist fullscreen-sichtbar, verdeckt alles)
            if ($t -match '(?i)program manager|workerw|eingabeerfahrung|textinput|input experience') { return $true }
            $r = New-Object SysPilotWin32+RECT
            if ([SysPilotWin32]::GetWindowRect($h, [ref]$r)) {
                $rects.Add([pscustomobject]@{ L=$r.Left; T=$r.Top; R=$r.Right; B=$r.Bottom; Title=$t })
            }
        } catch {}
        return $true
    }
    try { [void][SysPilotWin32]::EnumWindows($cb, [IntPtr]::Zero) } catch {}
    return $rects
}

function Find-SysPilotFreeWindowPosition {
    <# Sucht eine freie Position fuer $Win: Kandidaten sind
       WorkArea-Start, Rechts-/Unterkante jedes belegten Fensters und
       zentriert - erster Kandidat ohne Kollision (8px Rand) gewinnt.
       Fenster werden so sauber nebeneinander/untereinander gelegt. #>
    param([Parameter(Mandatory)]$Win, [IntPtr]$Hwnd = [IntPtr]::Zero)
    try {
        $wa = [System.Windows.SystemParameters]::WorkArea
        $w = $Win.Width;  if ($w -isnot [double] -or $w -le 0 -or [double]::IsNaN($w))  { $w = 900 }
        $h = $Win.Height; if ($h -isnot [double] -or $h -le 0 -or [double]::IsNaN($h)) { $h = 600 }
        if ($w -gt $wa.Width  - 16) { $w = $wa.Width  - 16 }
        if ($h -gt $wa.Height - 16) { $h = $wa.Height - 16 }
        # Nur Fenster auf DEMSELBEN Monitor (WorkArea) als Hindernis -
        # GetWindowRect liefert Virtual-Screen-Koordinaten, WorkArea nur
        # den Primaerbildschirm; Fenster auf anderen Monitoren duerfen
        # nicht als Kollision zaehlen.
        $occAll = @(Get-SysPilotOccupiedWindowRects -ExcludeHwnd $Hwnd)
        $occ = @($occAll | Where-Object {
            ($_.R -gt $wa.Left -and $_.L -lt $wa.Right -and $_.B -gt $wa.Top -and $_.T -lt $wa.Bottom)
        })
        $gap = 12
        $cands = New-Object 'System.Collections.Generic.List[object]'
        $cands.Add([pscustomobject]@{ X=[int]($wa.Left + 8); Y=[int]($wa.Top + 8) })
        foreach ($o in $occ) {
            $cands.Add([pscustomobject]@{ X=[int]($o.R + $gap); Y=[int]$o.T })
            $cands.Add([pscustomobject]@{ X=[int]$o.L; Y=[int]($o.B + $gap) })
        }
        $cands.Add([pscustomobject]@{ X=[int](($wa.Left + $wa.Right - $w) / 2); Y=[int](($wa.Top + $wa.Bottom - $h) / 2) })
        # Cascade-Kandidaten: diagonale Staffel - fangt den Fall "Bildschirm
        # voll" ab, indem die Kollision mit der kleinstenOverlap-Flaeche
        # minimiert wird (statt stumpf auf 8,8 zu fallen).
        $maxDX = [Math]::Max(36, [int]($wa.Width  - $w - 16))
        $maxDY = [Math]::Max(48, [int]($wa.Height - $h - 16))
        for ($i = 1; $i -le 14; $i++) {
            $cands.Add([pscustomobject]@{ X=[int]($wa.Left + 8 + (($i * 37) % $maxDX)); Y=[int]($wa.Top + 8 + (($i * 53) % $maxDY)) })
        }
        $clamp = {
            param($x, $y)
            if ($x -lt $wa.Left + 4) { $x = $wa.Left + 4 }
            if ($y -lt $wa.Top + 4)  { $y = $wa.Top + 4 }
            if ($x + $w -gt $wa.Right - 4)  { $x = $wa.Right - $w - 4 }
            if ($y + $h -gt $wa.Bottom - 4) { $y = $wa.Bottom - $h - 4 }
            return [pscustomobject]@{ X=[int]$x; Y=[int]$y }
        }
        $overlap = {
            param($x, $y)
            $area = 0
            foreach ($o in $occ) {
                $ix = [Math]::Max(0, [Math]::Min($x + $w, $o.R) - [Math]::Max($x, $o.L))
                $iy = [Math]::Max(0, [Math]::Min($y + $h, $o.B) - [Math]::Max($y, $o.T))
                $area += ($ix * $iy)
            }
            return $area
        }
        $best = $null; $bestArea = [long]::MaxValue
        foreach ($c in $cands) {
            $p = & $clamp $c.X $c.Y
            $area = & $overlap $p.X $p.Y
            if ($area -eq 0) { return $p }                    # perfekt frei
            if ($area -lt $bestArea) { $bestArea = $area; $best = $p }
        }
        if ($best) { return $best }
        return [pscustomobject]@{ X=[int]($wa.Left + 8); Y=[int]($wa.Top + 8) }
    } catch { return $null }
}

function Invoke-SysPilotWindowForegroundNow {
    <# Direkter Vordergrund-Aufruf (Activate + Win32 SetForegroundWindow
       mit AttachThreadInput-Trick + Topmost-Puls). Vom Class-Handler
       und von Set-SysPilotWindowForeground genutzt. #>
    param([Parameter(Mandatory)]$Win)
    try {
        if (-not ('SysPilotFg32' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class SysPilotFg32 {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
}
'@ -ErrorAction SilentlyContinue
        }
        $src = $Win
        $src.Activate() | Out-Null
        $src.Topmost = $true
        try {
            $hwnd = (New-Object Windows.Interop.WindowInteropHelper($src)).Handle
            if ($hwnd -ne [IntPtr]::Zero -and ('SysPilotFg32' -as [type])) {
                [SysPilotFg32]::ShowWindow($hwnd, 9) | Out-Null
                $fg = [SysPilotFg32]::GetForegroundWindow()
                $procId = [uint32]0
                $fgThread = [SysPilotFg32]::GetWindowThreadProcessId($fg, [ref]$procId)
                $myThread = [SysPilotFg32]::GetCurrentThreadId()
                $procId2 = [uint32]0
                $tgtThread = [SysPilotFg32]::GetWindowThreadProcessId($hwnd, [ref]$procId2)
                if ($fgThread -ne $tgtThread) { [SysPilotFg32]::AttachThreadInput($myThread, $tgtThread, $true) | Out-Null }
                [SysPilotFg32]::BringWindowToTop($hwnd) | Out-Null
                [SysPilotFg32]::SetForegroundWindow($hwnd) | Out-Null
                if ($fgThread -ne $tgtThread) { [SysPilotFg32]::AttachThreadInput($myThread, $tgtThread, $false) | Out-Null }
            }
        } catch {}
        $t = New-Object System.Windows.Threading.DispatcherTimer
        $t.Interval = [timespan]::FromMilliseconds(350)
        $t.Add_Tick({
            param($s,$e)
            $s.Stop()
            try { $src.Topmost = $false } catch {}
            try { $src.Activate() | Out-Null } catch {}
        }.GetNewClosure())
        $t.Start()
    } catch {}
}

function Set-SysPilotWindowForeground {
    <# Bringt ein WPF-Fenster in den Vordergrund und registriert dabei
       den globalen Fenster-Chrome-Class-Handler (Platzierung +
       Vordergrund fuer ALLE SysPilot-Fenster im Prozess). #>
    param([Parameter(Mandatory)]$Win)
    try { Register-SysPilotWindowChrome } catch {}
    try {
        if ($null -eq $Win.Resources) { $Win.Resources = New-Object Windows.ResourceDictionary }
        if ($Win.Resources.Contains('_fgDone')) { return }
        $Win.Resources['_fgDone'] = $true
        $win.Add_Loaded({
            try { Invoke-SysPilotWindowForegroundNow -Win $_ } catch {}
        })
    } catch {}
}

function Set-SysPilotWindowAutoSize {
    <# Passt die Fenstergroesse dynamisch an den Inhalt an: misst den
       gewuenschten Platz und vergroessert Breite/Hoehe bis zu ~92%
       der Bildschirm-Arbeitsflaeche. Fenster werden nur vergrößert,
       nie unter die XAML-Defaults verkleinert. #>
    param(
        [Parameter(Mandatory)]$Win,
        [double]$MaxFactor = 0.92,
        [double]$MinWidth = 0,
        [double]$MinHeight = 0
    )
    try {
        $wa = [System.Windows.SystemParameters]::WorkArea
        $maxW = [Math]::Floor($wa.Width * $MaxFactor)
        $maxH = [Math]::Floor($wa.Height * $MaxFactor)
        $Win.Measure([System.Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
        $wantW = [Math]::Ceiling($Win.DesiredSize.Width) + 30
        $wantH = [Math]::Ceiling($Win.DesiredSize.Height) + 50
        if ($MinWidth  -gt 0 -and $wantW -lt $MinWidth)  { $wantW = $MinWidth }
        if ($MinHeight -gt 0 -and $wantH -lt $MinHeight) { $wantH = $MinHeight }
        if ($wantW -gt $Win.Width  -and $wantW -le $maxW) { $Win.Width  = $wantW }
        if ($wantH -gt $Win.Height -and $wantH -le $maxH) { $Win.Height = $wantH }
        # Fenster nach vorn holen (Aufruf zentral fuer fast alle Tools)
        Set-SysPilotWindowForeground -Win $Win
    } catch { }
}

function Test-SysPilotWindowAlreadyOpen {
    <# Single-Instance-Guard fuer WPF-Fenster mit modul-globalem State
       ($script:*-Variablen). Wird ein Fenster erneut geoeffnet, wuerde
       der State zurueckgesetzt waehrend das alte Fenster noch laeuft.
       Rueckgabe $true = Fenster existiert bereits -> Aufrufer soll
       sofort zurueckkehren (das bestehende Fenster wird aktiviert).
       Schluessel sollte eindeutig pro Fensterfunktion sein. #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)]$Win
    )
    if (-not $script:SysPilotOpenWindows) { $script:SysPilotOpenWindows = @{} }
    $w = $script:SysPilotOpenWindows[$Key]
    if ($w -and $w.IsLoaded) {
        try { $w.Activate() } catch {}
        return $true
    }
    $script:SysPilotOpenWindows[$Key] = $Win
    $k = $Key
    $Win.Add_Closed({ param($s,$e) if ($script:SysPilotOpenWindows) { $script:SysPilotOpenWindows.Remove($k) } }.GetNewClosure())
    return $false
}

function Show-SysPilotRunCommand {
    <# Klickbare Befehlskarte: zeigt PowerShell-Befehl(e) in
       Monospace (markierbar, Rechtsklick-Kopieren), mit Buttons
       'Kopieren', 'Als Administrator ausfuehren' (UAC, via
       -EncodedCommand - kein Quoting-Problem) und 'Schliessen'.
       Gibt $true zurueck wenn der Admin-Lauf gestartet wurde. #>
    param(
        [Parameter(Mandatory)][string[]]$Command,
        [string]$Title = 'Befehl ausfuehren',
        [string]$Reason = '',
        $Owner = $null
    )
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
        foreach ($c in $Command) { Write-Host "  $c" -ForegroundColor Yellow }
        Write-Host '  (WPF nicht verfuegbar - Befehl oben kopieren)' -ForegroundColor DarkGray
        return $false
    }
    try {
        [void][reflection.assembly]::LoadWithPartialName('PresentationFramework')
        [void][reflection.assembly]::LoadWithPartialName('PresentationCore')
        [void][reflection.assembly]::LoadWithPartialName('WindowsBase')
    } catch { }
    $joined = ($Command -join "`n")
    $escReason = [System.Security.SecurityElement]::Escape($Reason)
    $escCmd = [System.Security.SecurityElement]::Escape($joined)
    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$([System.Security.SecurityElement]::Escape($Title))" Width="720" Height="330"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResizeWithGrip"
        Background="#FF1E1E2E" Foreground="#FFEAEAF2" FontFamily="Segoe UI">
  <Window.Resources>
    <Style TargetType="Button"><Setter Property="Padding" Value="12,6"/><Setter Property="Margin" Value="8,0,0,0"/><Setter Property="Background" Value="#FF2D4A6B"/><Setter Property="Foreground" Value="#FFEAF2FF"/><Setter Property="BorderBrush" Value="#FF4A6FA5"/></Style>
    <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#FFE0E0E0"/><Setter Property="FontSize" Value="12"/></Style>
  </Window.Resources>
  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <TextBlock x:Name="LblReason" Text="$escReason" TextWrapping="Wrap" Margin="0,0,0,10"/>
    <TextBox x:Name="CmdBox" Grid.Row="1" IsReadOnly="True" TextWrapping="NoWrap"
             VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
             FontFamily="Consolas" FontSize="13" Background="#FF14141E" Foreground="#FF9CCC65"
             BorderBrush="#FF2E4A2E" Text="$escCmd"/>
    <DockPanel Grid.Row="2" Margin="0,12,0,0">
      <StackPanel Orientation="Horizontal" DockPanel.Dock="Right" HorizontalAlignment="Right">
        <Button x:Name="BtnAdmin" Content="Als Administrator ausfuehren" FontWeight="Bold"/>
        <Button x:Name="BtnCopy" Content="Kopieren"/>
        <Button x:Name="BtnClose" Content="Schliessen"/>
      </StackPanel>
      <TextBlock x:Name="Status" VerticalAlignment="Center" Foreground="#FF9E9E9E"/>
    </DockPanel>
  </Grid>
</Window>
"@
    $cwin = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$xaml)))
    if ($Owner) { try { $cwin.Owner = $Owner } catch {} }
    $cb = $cwin.FindName('CmdBox'); $st = $cwin.FindName('Status')
    $ran = $false
    $cwin.FindName('BtnCopy').Add_Click({
        try { [Windows.Clipboard]::SetText($joined); $st.Text='Kopiert.'; $st.Foreground=[Windows.Media.BrushConverter]::new().ConvertFrom('#FF81C784') } catch {}
    })
    $cwin.FindName('BtnAdmin').Add_Click({
        try {
            $st.Text='Starte elevated ...'
            $full = ($Command -join '; ')
            $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($full))
            $p = Start-Process powershell -Verb RunAs -PassThru -Wait `
                -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$enc
            $st.Text = "Beendet (Exit $($p.ExitCode))."
            $st.Foreground = [Windows.Media.BrushConverter]::new().ConvertFrom('#FF81C784')
            $ran = $true
        } catch { $st.Text = "Abgebrochen: $($_.Exception.Message)"; $st.Foreground=[Windows.Media.BrushConverter]::new().ConvertFrom('#FFEF5350') }
    })
    $cwin.FindName('BtnClose').Add_Click({ $cwin.Close() })
    Set-SysPilotWindowAutoSize -Win $cwin -MinWidth 560 -MinHeight 300
    $cwin.ShowDialog() | Out-Null
    return $ran
}

function Set-SysPilotRichText {
    <# Fuellt eine RichTextBox mit Text, in dem http(s)-URLs als
       klickbare Hyperlinks (oeffnen im Browser) dargestellt werden.
       Jede Textzeile wird ein Paragraph; URLs werden hellblau.
       Maximal 60 Zeilen, dann abgeschnitten. #>
    param(
        [Parameter(Mandatory)]$RichBox,
        [Parameter(Mandatory)][string]$Text
    )
    try {
        $RichBox.Document.Blocks.Clear()
        $lines = @($Text -split "`r?`n")
        if ($lines.Count -gt 60) { $lines = @($lines[0..58]) + '... (gekuerzt - volle Antwort im Log)' }
        foreach ($line in $lines) {
            $para = New-Object System.Windows.Documents.Paragraph
            $parts = [regex]::Split($line, '(https?://[^\s)"''<>\]]+)')
            foreach ($p in $parts) {
                if (-not $p) { continue }
                if ($p -match '^https?://') {
                    $run = New-Object System.Windows.Documents.Run($p)
                    $run.TextDecorations = [Windows.TextDecorations]::Underline
                    $link = New-Object System.Windows.Documents.Hyperlink($run)
                    $link.NavigateUri = $p
                    $link.Foreground = [Windows.Media.Brushes]::DeepSkyBlue
                    $link.Cursor = [Windows.Input.Cursors]::Hand
                    $link.ToolTip = 'Klicken = im Browser oeffnen'
                    $clickHandler = [System.Windows.RoutedEventHandler]{ param($s,$e)
                        try { $u = $null; if ($s -is [System.Windows.Documents.Hyperlink]) { $u = $s.NavigateUri } ; if ($u) { Start-Process ([string]$u.AbsoluteUri) } } catch {} }
                    $link.AddHandler([System.Windows.Documents.Hyperlink]::ClickEvent, $clickHandler)
                    $navHandler = [System.Windows.Navigation.RequestNavigateEventHandler]{ param($s,$e)
                        try { if ($e.Uri) { Start-Process ([string]$e.Uri.AbsoluteUri) } } catch {}; $e.Handled = $true }
                    $link.AddHandler([System.Windows.Documents.Hyperlink]::RequestNavigateEvent, $navHandler)
                    $para.Inlines.Add($link)
                } else {
                    $para.Inlines.Add((New-Object System.Windows.Documents.Run($p)))
                }
            }
            $RichBox.Document.Blocks.Add($para)
        }
        try { $RichBox.ScrollToEnd() } catch { }
    } catch { }
}

function Read-SysPilotInput {
    <# Drop-in-Ersatz fuer freie Read-SysPilotChoice-Eingaben: oeffnet den
       WPF-Dialog (Maus, Rechtsklick-Paste, Durchsuchen-Button).
       Gibt Text zurueck ('' bei leerem OK) oder $null bei Abbruch -
       beides ist fuer 'if (-not $x)'-Pruefungen kompatibel.
       Faellt automatisch auf Read-Host zurueck wenn WPF nicht
       verfuegbar ist (Konsole ohne STA, headless). #>
    param(
        [Parameter(Mandatory, Position=0)][string]$Prompt,
        [Parameter(Position=1)][string]$Default = '',
        [string]$Title = 'SysPilot',
        [switch]$Multiline,
        [switch]$BrowseFile,
        [switch]$BrowseFolder,
        [switch]$NoGui
    )
    if (-not $NoGui) {
        try {
            $r = Show-SysPilotWpfInput -Prompt $Prompt -Default $Default -Title $Title `
                 -Multiline:$Multiline -BrowseFile:$BrowseFile -BrowseFolder:$BrowseFolder -Width 500
            if ($null -ne $r) { return $r.Trim() }
            return $null
        } catch { }
    }
    # Konsolen-Fallback
    if ($Default) {
        Write-Host -NoNewline "  $Prompt (Enter = Standard: $Default) : " -ForegroundColor Yellow
    } else {
        Write-Host -NoNewline "  $Prompt : " -ForegroundColor Yellow
    }
    $v = (Read-Host).Trim()
    if ([string]::IsNullOrWhiteSpace($v) -and $Default) { return $Default }
    return $v
}

function Read-SysPilotChoice {
    param([string]$Prompt = "Auswahl")
    Write-Host ""
    # Pause-Aufrufe ('Weiter', 'Weiter mit Enter', ~160 Stellen) bekommen einen
    # mausfaehigen "drueck irgendwas"-Modus: Klick oder Taste = weiter.
    # Rueckgabe ist '' - identisch zum bloßen Enter bei Read-Host.
    $hadApi = $script:ConsoleInputReady
    if ($Prompt -match '^weiter' -and (Initialize-SysPilotConsoleInput)) {
        Write-Host -NoNewline "  $Prompt : " -ForegroundColor Yellow
        Write-Host "(Enter oder Klick)" -ForegroundColor DarkGray
        Clear-SysPilotConsoleInputBuffer
        try {
            while ($true) {
                $ev = Read-SysPilotMenuEvent
                if ($ev.Kind -eq 'Key') { return '' }
                if ($ev.Action -eq 'Click') { return '' }
            }
        } finally {
            if (-not $hadApi) { Restore-SysPilotConsoleInput }
        }
    }
    Write-Host -NoNewline "  $Prompt : " -ForegroundColor Yellow
    return (Read-Host).Trim()
}

function Read-SysPilotYesNo {
    <# Kompakter Ja/Nein-Dialog MIT MausUnterstuetzung: Klick auf [Ja]/[Nein],
       Mausrad = umschalten, j/y = Ja, n = Nein, Pfeile+Enter, Esc = Nein.
       Zeichnet INLINE (kein Clear-Host) - der vorherige Kontext bleibt sichtbar.
       Gibt $true (Ja) oder $false (Nein/Abbruch) zurueck. #>
    param([Parameter(Mandatory)][string]$Question)
    $hadApi = $script:ConsoleInputReady
    if (-not (Initialize-SysPilotConsoleInput)) {
        $a = Read-SysPilotChoice "$Question (j/n)"
        return ($a -match '^(j|ja|y|yes)$')
    }
    Clear-SysPilotConsoleInputBuffer
    $sel = 1   # default: Nein (sicher)
    $optRow = -1; $restRow = -1; $firstDraw = $true
    $drawOpts = {
        Write-Host -NoNewline '   '
        if ($sel -eq 0) { Write-Host -NoNewline '[ Ja ]' -ForegroundColor Black -BackgroundColor Yellow }
        else { Write-Host -NoNewline '[ Ja ]' -ForegroundColor DarkGray }
        Write-Host -NoNewline '   '
        if ($sel -eq 1) { Write-Host -NoNewline '[ Nein ]' -ForegroundColor Black -BackgroundColor Yellow }
        else { Write-Host -NoNewline '[ Nein ]' -ForegroundColor DarkGray }
        Write-Host ""
    }
    try {
    $needDraw = $true
    while ($true) {
        if ($needDraw) {
            if ($firstDraw) {
                Write-Host ""
                Write-Host "  $Question" -ForegroundColor Yellow
                Write-Host ""
                $optRow = $Host.UI.RawUI.CursorPosition.Y
                & $drawOpts
                $restRow = $Host.UI.RawUI.CursorPosition.Y
                Write-Host "  (Klick, j/n, Pfeile+Enter, Esc = Nein)" -ForegroundColor DarkGray
                $firstDraw = $false
            } else {
                # nur die Optionszeile aktualisieren (kein Clear-Host).
                # Cursor-Set MUSS verifiziert werden: Schlaegt es fehl
                # (z.B. ConPTY/Windows Terminal), wuerde drawOpts eine
                # neue Zeile anhängen - endloser Optionszeilen-Spam und
                # Klicks ins Leere. Dann lieber gar nicht neu zeichnen.
                if (Set-SysPilotConsoleCursor -X 0 -Y $optRow) {
                    & $drawOpts
                    [void](Set-SysPilotConsoleCursor -X 0 -Y $restRow)
                } else {
                    $needDraw = $false
                }
            }
        }
        $needDraw = $true
        $ev = Read-SysPilotMenuEvent
        if ($ev.Kind -eq 'Key') {
            switch ([int]$ev.Vk) {
                74 { return $true }    # j
                89 { return $true }    # y
                78 { return $false }   # n
                27 { return $false }   # Esc
                13 { return ($sel -eq 0) }
                37 { $sel = 0 }        # links = Ja
                39 { $sel = 1 }        # rechts = Nein
                38 { $sel = 0 }        # oben = Ja
                40 { $sel = 1 }        # unten = Nein
            }
        } else {
            $zoneJa = ($ev.Row -eq $optRow -and $ev.Col -ge 3 -and $ev.Col -le 10)
            $zoneNein = ($ev.Row -eq $optRow -and $ev.Col -ge 11 -and $ev.Col -le 18)
            switch ($ev.Action) {
                'Move' {
                    $h = if ($zoneJa) { 0 } elseif ($zoneNein) { 1 } else { $sel }
                    if ($h -ne $sel) { $sel = $h } else { $needDraw = $false }
                }
                'Click' {
                    if ($zoneJa) { return $true }
                    if ($zoneNein) { return $false }
                    $needDraw = $false
                }
                'WheelUp'   { $sel = 0 }
                'WheelDown' { $sel = 1 }
            }
        }
    }
    } finally {
        if (-not $hadApi) { Restore-SysPilotConsoleInput }
    }
}

function Confirm-SysPilot {
    param([string]$Question)
    return (Read-SysPilotYesNo $Question)
}

function Set-SysPilotConfigValue {
    <# Setzt einen Config-Wert (z.B. -Section Start -Key AlwaysAdmin -Value $true) und speichert config.json. #>
    param([string]$Section, [Parameter(Mandatory)][string]$Key, $Value)
    $path = Join-Path $script:SysPilotRoot 'config.json'
    $json = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($Section) {
        if (-not $json.$Section) { $json | Add-Member -NotePropertyName $Section -NotePropertyValue ([PSCustomObject]@{}) -Force }
        if ($json.$Section.PSObject.Properties[$Key]) { $json.$Section.$Key = $Value }
        else { $json.$Section | Add-Member -NotePropertyName $Key -NotePropertyValue $Value -Force }
    } else {
        if ($json.PSObject.Properties[$Key]) { $json.$Key = $Value }
        else { $json | Add-Member -NotePropertyName $Key -NotePropertyValue $Value -Force }
    }
    $json | ConvertTo-Json -Depth 10 | Set-Content $path -Encoding UTF8
    Reset-SysPilotConfig
}

function Get-SysPilotShortcutPaths {
    <# Alle SysPilot-Verknuepfungen (Desktop, Startmenue) - User + All Users. #>
    $dirs = @(
        [Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('CommonDesktopDirectory'),
        [Environment]::GetFolderPath('StartMenu'),
        [Environment]::GetFolderPath('CommonStartMenu')
    ) | Select-Object -Unique
    $found = @()
    foreach ($d in $dirs) {
        if (-not (Test-Path $d)) { continue }
        $found += Get-ChildItem $d -Recurse -Filter '*.lnk' -ErrorAction SilentlyContinue |
            Where-Object { $_.BaseName -like 'SysPilot*' } | Select-Object -ExpandProperty FullName
    }
    return $found
}

function Set-SysPilotShortcutRunAs {
    <# Setzt/entfernt "Als Administrator ausfuehren" auf allen SysPilot-Verknuepfungen.
       Trick: Byte 21 im .lnk (LinkFlags) mit 0x20 verodern = RunAsAdministrator. #>
    param([bool]$RunAs)
    $links = Get-SysPilotShortcutPaths
    $changed = 0
    foreach ($l in $links) {
        try {
            $bytes = [System.IO.File]::ReadAllBytes($l)
            if ($bytes.Length -lt 0x16) { continue }
            if ($RunAs) { $bytes[0x15] = $bytes[0x15] -bor 0x20 }
            else { $bytes[0x15] = $bytes[0x15] -band (-bnot 0x20) }
            [System.IO.File]::WriteAllBytes($l, $bytes)
            $changed++
        } catch { }
    }
    Write-SysPilotLog "Verknuepfungen 'Als Administrator ausfuehren' = $RunAs ($changed Links)"
    return $changed
}

function Write-SysPilotProgress {
    <# Fortschrittsanzeige in Prozent (einheitlich) #>
    param(
        [Parameter(Mandatory)][string]$Activity,
        [Parameter(Mandatory)][int]$Current,
        [Parameter(Mandatory)][int]$Total,
        [string]$Status = ''
    )
    $pct = if ($Total -gt 0) { [math]::Round(100 * $Current / $Total) } else { 0 }
    Write-Progress -Activity $Activity -Status "$Status ($Current/$Total)" -PercentComplete $pct
}

function Complete-SysPilotProgress {
    param([string]$Activity = 'Fertig')
    Write-Progress -Activity $Activity -Completed
}

function Clear-SysPilotPendingKeys {
    <# Verwirft Tastendruecke, die waehrend langsamer Vorarbeit im
       Konsolen-Tastenpuffer liegen geblieben sind. Sonst wird z.B. ein
       versehentliches Enter sofort als Menueauswahl verarbeitet. #>
    try {
        while ([Console]::KeyAvailable) {
            [void]$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        }
    } catch { }
}

$script:ConsoleInputReady = $false
$script:ConsoleInputHandle = [IntPtr]::Zero
$script:ConsoleInputOrigMode = 0

function Initialize-SysPilotConsoleInput {
    <# Aktiviert Maus-Events in der Konsole (ENABLE_MOUSE_INPUT) und
       deaktiviert QuickEdit (ENABLE_QUICK_EDIT_MODE = 0x40): Solange
       QuickEdit an ist, behandelt conhost die Maus selbst (Textauswahl)
       und liefert KEINE Mouse-Records an die App - ohne das Ausschalten
       bleiben Klicks/Rad wirkungslos. Der Original-Modus wird gespeichert
       und in Restore-SysPilotConsoleInput wiederhergestellt. #>
    if (-not ('SysPilotConsoleInput' -as [type])) { return $false }
    try {
        $h = [SysPilotConsoleInput]::GetStdHandle(-10)
        if ($h.ToInt64() -eq -1 -or $h -eq [IntPtr]::Zero) { return $false }
        $mode = 0
        if (-not [SysPilotConsoleInput]::GetConsoleMode($h, [ref]$mode)) { return $false }
        # Modus bei JEDEM Aufruf neu anwenden: Falls ein anderes Tool den
        # Console-Mode inzwischen verstellt hat (Maus aus, QuickEdit an),
        # war ConsoleInputReady noch $true, der Modus aber falsch - Klicks
        # bleiben dann dauerhaft wirkungslos. Idempotent, self-healing.
        if (-not $script:ConsoleInputReady) { $script:ConsoleInputOrigMode = $mode }
        $newMode = ($mode -bor 0x0010) -band (-bnot 0x0040)
        [void][SysPilotConsoleInput]::SetConsoleMode($h, $newMode)
        $script:ConsoleInputHandle = $h
        $script:ConsoleInputReady = $true
        return $true
    } catch { return $false }
}

function Restore-SysPilotConsoleInput {
    <# Stellt den urspruenglichen Konsolen-Input-Modus wieder her. #>
    if ($script:ConsoleInputReady -and $script:ConsoleInputHandle -ne [IntPtr]::Zero) {
        try { [void][SysPilotConsoleInput]::SetConsoleMode($script:ConsoleInputHandle, $script:ConsoleInputOrigMode) } catch { }
        $script:ConsoleInputHandle = [IntPtr]::Zero
        $script:ConsoleInputReady = $false
    }
}

function Set-SysPilotConsoleCursor {
    <# Setzt die Konsolen-Cursorposition DIREKT ueber kernel32
       (SetConsoleCursorPosition) und verifiziert per
       GetConsoleScreenBufferInfo, dass die Position wirklich angelaufen ist.
       Hintergrund: Unter Windows
       Terminal/ConPTY kann der RawUI-CursorPosition-Setter "erfolgreich"
       laufen, ohne die Position anzuwenden - die Folge war, dass Inline-
       Redraws (z.B. Ja/Nein-Dialog) jedes Mal eine NEUE Zeile schrieben
       (Optionszeilen-Duplikate, Klicks ins Leere, Tooltip-Spam).
       Rueckgabe: $true nur bei verifizierter Position. #>
    param([Parameter(Mandatory)][int]$X, [Parameter(Mandatory)][int]$Y)
    if (-not ('SysPilotConsoleInput' -as [type])) { return $false }
    try {
        $hOut = [SysPilotConsoleInput]::GetStdHandle(-11)   # STD_OUTPUT_HANDLE
        if ($hOut.ToInt64() -eq -1 -or $hOut -eq [IntPtr]::Zero) { return $false }
        $c = New-Object SysPilotConsoleInput+COORD
        $c.X = [int16]$X; $c.Y = [int16]$Y
        if (-not [SysPilotConsoleInput]::SetConsoleCursorPosition($hOut, $c)) { return $false }
        # Verifizieren ueber GetConsoleScreenBufferInfo: GetConsoleCursorPosition
        # meldet unter ConPTY/Windows Terminal falsch (z.B. 0,0) - CSBI ist korrekt.
        $info = New-Object SysPilotConsoleInput+CONSOLE_SCREEN_BUFFER_INFO
        if (-not [SysPilotConsoleInput]::GetConsoleScreenBufferInfo($hOut, [ref]$info)) { return $false }
        return ($info.dwCursorPosition.X -eq $X -and $info.dwCursorPosition.Y -eq $Y)
    } catch { return $false }
}

function Clear-SysPilotConsoleInputBuffer {
    <# Verwirft alle pending Tastatur-/Maus-Records (blockierungsfrei). #>
    if ($null -ne $script:_menuEventQueue) { $script:_menuEventQueue.Clear() }
    if (-not (Initialize-SysPilotConsoleInput)) { return }
    $buf = [Array]::CreateInstance([type]'SysPilotConsoleInput+INPUT_RECORD', 128)
    while ([SysPilotConsoleInput]::WaitForSingleObject($script:ConsoleInputHandle, 0) -eq 0) {
        $n = 0
        [void][SysPilotConsoleInput]::ReadConsoleInput($script:ConsoleInputHandle, $buf, 128, [ref]$n)
        if ($n -lt 128) { break }
    }
}

$script:_menuEventQueue = $null

function ConvertTo-SysPilotMenuEventRecord {
    <# Wandelt einen INPUT_RECORD in ein Event-Hashtable um oder $null
       (Key-Up, Focus, rechte Maustaste usw. werden uebersprungen). #>
    param($Rec)
    if ($Rec.EventType -eq 1) {
        if ($Rec.KeyEvent.bKeyDown -eq 0) { return $null }
        return @{ Kind = 'Key'; Vk = [int]$Rec.KeyEvent.wVirtualKeyCode }
    }
    if ($Rec.EventType -eq 2) {
        $me = $Rec.MouseEvent
        $flags = [uint32]$me.dwEventFlags
        $btn = [uint32]$me.dwButtonState
        $row = [int]$me.dwMousePosition.Y
        $col = [int]$me.dwMousePosition.X
        if (($flags -band 0x0004) -ne 0) {   # MOUSE_WHEELED (0x04, nicht 0x02=DoubleClick)
            $hi = [int](($btn -shr 16) -band 0xFFFF)
            if ($hi -ge 0x8000) { $hi -= 0x10000 }
            return @{ Kind = 'Mouse'; Action = $(if ($hi -gt 0) { 'WheelUp' } else { 'WheelDown' }); Row = $row; Col = $col }
        }
        if (($flags -band 0x0001) -ne 0) {
            return @{ Kind = 'Mouse'; Action = 'Move'; Row = $row; Col = $col }
        }
        if (($btn -band 0x0001) -ne 0) {
            return @{ Kind = 'Mouse'; Action = 'Click'; Row = $row; Col = $col }
        }
    }
    return $null
}

function Read-SysPilotMenuEvent {
    <# Liest blockierend das naechste Tastatur- oder Maus-Event.
       ReadConsoleInput liefert bis zu 32 Records pro Aufruf - ALLE werden
       in einer Queue zwischengespeichert, sonst gingen Events verloren
       (z.B. Pfeiltaste hinter einer Mausbewegung im selben Paket).
       Rueckgabe: @{Kind='Key'; Vk=<int>} oder
                  @{Kind='Mouse'; Action='Move'|'Click'|'WheelUp'|'WheelDown'; Row=<int>; Col=<int>}
       Ohne Console-API: Fallback auf ReadKey (Tastatur-only). #>
    if (-not (Initialize-SysPilotConsoleInput)) {
        $k = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        return @{ Kind = 'Key'; Vk = [int]$k.VirtualKeyCode }
    }
    if ($null -eq $script:_menuEventQueue) { $script:_menuEventQueue = New-Object System.Collections.Queue }
    $buf = [Array]::CreateInstance([type]'SysPilotConsoleInput+INPUT_RECORD', 32)
    while ($true) {
        if ($script:_menuEventQueue.Count -gt 0) { return $script:_menuEventQueue.Dequeue() }
        $wr = [SysPilotConsoleInput]::WaitForSingleObject($script:ConsoleInputHandle, [uint32]::MaxValue)
        if ($wr -ne 0) {
            # Handle defekt (WAIT_FAILED): ReadConsoleInput wuerde 0 liefern
            # und die Schleife wuerde sich endlos drehen - stattdessen
            # einmalig auf den ReadKey-Fallback ausweichen.
            $k = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
            return @{ Kind = 'Key'; Vk = [int]$k.VirtualKeyCode }
        }
        $n = 0
        [void][SysPilotConsoleInput]::ReadConsoleInput($script:ConsoleInputHandle, $buf, 32, [ref]$n)
        for ($i = 0; $i -lt $n; $i++) {
            $ev = ConvertTo-SysPilotMenuEventRecord $buf[$i]
            if ($null -eq $ev) { continue }
            # Move-Events sind transient: bei voller Queue verwerfen, nie blockieren
            if ($ev.Action -eq 'Move' -and $script:_menuEventQueue.Count -ge 100) { continue }
            $script:_menuEventQueue.Enqueue($ev)
        }
    }
}

function Show-SysPilotArrowMenuConsole {
    <# Konsolen-Variante von Show-SysPilotArrowMenu (Fallback, wenn kein
       WPF/STA verfuegbar). Gibt Tag des gewaehlten Eintrags oder $null.
       Items: Array von @{ Label; Color; Tag }. #>
    param(
        [Parameter(Mandatory)][array]$Items,
        [string]$Title = '',
        [string]$Footer = 'Pfeiltasten hoch/runter, Enter = waehlen, Esc = zurueck',
        [int]$StartIndex = 0
    )
    if ($Items.Count -eq 0) { return $null }
    Clear-SysPilotPendingKeys
    $useApi = Initialize-SysPilotConsoleInput
    if ($useApi) { Clear-SysPilotConsoleInputBuffer }
    $sel = [math]::Max(0, [math]::Min($StartIndex, $Items.Count - 1))
    $top = 0
    $itemStartRow = $(if ($Title) { 3 } else { 0 })
    try {
    $needDraw = $true
    while ($true) {
        $vp = Get-SysPilotConsoleViewport
        $winH = $vp.Rows
        $reserve = 4 + $(if ($Title) { 3 } else { 0 })
        $page = [math]::Max(5, $winH - $reserve)
        if ($Items.Count -lt $page) { $page = $Items.Count }
        if ($sel -lt $top) { $top = $sel }
        if ($sel -ge $top + $page) { $top = $sel - $page + 1 }
        $top = [math]::Max(0, [math]::Min($top, $Items.Count - $page))

        if ($needDraw) {
            Clear-Host
            if ($Title) {
                Write-Host ""
                Write-Host "  $Title" -ForegroundColor Cyan
                Write-Host ""
            }
            $itemStartRow = $Host.UI.RawUI.CursorPosition.Y
            for ($i = $top; $i -lt ($top + $page); $i++) {
                $it = $Items[$i]
                $prefix = if ($i -eq $sel) { ' > ' } else { '   ' }
                $color = if ($i -eq $sel) { 'Black' } else { if ($it.Color) { $it.Color } else { 'White' } }
                $line = "$prefix$($it.Label)"
                if ($i -eq $sel) { Write-Host $line -ForegroundColor $color -BackgroundColor Cyan }
                else { Write-Host $line -ForegroundColor $color }
            }
            Write-Host ""
            $more = if ($Items.Count -gt $page) { "  [{0}/{1}]" -f ($sel + 1), $Items.Count } else { '' }
            Write-Host ("  $Footer" + $more) -ForegroundColor DarkGray
        }
        $needDraw = $true
        $ev = Read-SysPilotMenuEvent
        if ($ev.Kind -eq 'Key') {
            switch ([int]$ev.Vk) {
                38 { $sel = ($sel - 1 + $Items.Count) % $Items.Count }
                40 { $sel = ($sel + 1) % $Items.Count }
                33 { $sel = [math]::Max(0, $sel - $page) }
                34 { $sel = [math]::Min($Items.Count - 1, $sel + $page) }
                36 { $sel = 0 }
                35 { $sel = $Items.Count - 1 }
                27 { return $null }
                13 { return $Items[$sel].Tag }
            }
        } else {
            $idx = [int]$ev.Row - $itemStartRow + $top
            switch ($ev.Action) {
                'Move' {
                    if ($idx -ge $top -and $idx -lt ($top + $page) -and $idx -ne $sel) { $sel = $idx }
                    else { $needDraw = $false }
                }
                'Click' {
                    if ($idx -ge $top -and $idx -lt ($top + $page)) { return $Items[$idx].Tag }
                    else { $needDraw = $false }
                }
                'WheelUp'   { $sel = ($sel - 1 + $Items.Count) % $Items.Count }
                'WheelDown' { $sel = ($sel + 1) % $Items.Count }
            }
        }
    }
    } finally {
        if ($useApi) { Restore-SysPilotConsoleInput }
    }
}

# =====================================================================
# WPF-Menues: Show-SysPilotArrowMenu / Show-SysPilotMultiSelectMenu sind
# Dispatcher - sie oeffnen ein SysPilot-WPF-Fenster (dunkles Design,
# Herbert-Assistent-Leiste, Positionierung neben dem Konsolenfenster),
# wenn WPF+STA verfuegbar sind. Sonst Console-Fallback (unveraendert).
# =====================================================================

function Test-SysPilotWpfMenuAvailable {
    <# $true, wenn Menues als WPF-Fenster laufen koennen:
       interaktive Session, STA-Thread, WPF-Assemblies ladbar. #>
    if (-not [Environment]::UserInteractive) { return $false }
    try { if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { return $false } } catch { return $false }
    try {
        if (-not ('System.Windows.Window' -as [type])) {
            Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop
        }
        return $true
    } catch { return $false }
}

function ConvertTo-SysPilotMenuColor {
    <# Konsolen-Farbname -> Hex-Farbe der SysPilot-Palette. #>
    param([AllowEmptyString()][string]$Color)
    $map = @{
        'White'='#FFEAEAF2'; 'Gray'='#FFB0B0C0'; 'DarkGray'='#FF8A8AA0';
        'Cyan'='#FF4FC3F7'; 'Green'='#FF9CCC65'; 'DarkGreen'='#FF66BB6A';
        'Yellow'='#FFFFB74D'; 'DarkYellow'='#FFFFA726'; 'Red'='#FFEF5350';
        'DarkRed'='#FFB71C1C'; 'Magenta'='#FFCE93D8'; 'Blue'='#FF82B1FF';
        'DarkBlue'='#FF64B5F6'; 'Black'='#FF1E1E2E'
    }
    if ($Color -and $map.ContainsKey($Color)) { return $map[$Color] }
    if ($Color -and $Color -match '^#[0-9A-Fa-f]{6,8}$') { return $Color }
    return '#FFEAEAF2'
}

function Get-SysPilotConsoleWindowRect {
    <# Position des Konsolenfensters (conhost/Windows Terminal),
       damit WPF-Menues daneben aufgehen koennen. $null ohne Konsole. #>
    try {
        if (-not ('SysPilotWin32' -as [type])) {
            Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class SysPilotWin32 {
    [DllImport("user32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
}
"@ -ErrorAction Stop
        }
        $h = [SysPilotWin32]::GetConsoleWindow()
        if ($h -eq [IntPtr]::Zero) { return $null }
        $r = New-Object SysPilotWin32+RECT
        if (-not [SysPilotWin32]::GetWindowRect($h, [ref]$r)) { return $null }
        return @{ Left=$r.Left; Top=$r.Top; Right=$r.Right; Bottom=$r.Bottom }
    } catch { return $null }
}

function Set-SysPilotMenuWindowPosition {
    <# Platziert $Win rechts neben dem Konsolenfenster (Fallback:
       darueber bzw. Bildschirmmitte), innerhalb des WorkArea. #>
    param($Win, [int]$Width = 580, [int]$Height = 640)
    try {
        $wa = [System.Windows.SystemParameters]::WorkArea
        $rect = Get-SysPilotConsoleWindowRect
        if ($rect) {
            $left = $rect.Right + 12
            if (($left + $Width) -gt $wa.Right) {
                $left = $rect.Left - $Width - 12
                if ($left -lt $wa.Left) { $left = [math]::Max($wa.Left, $rect.Left) }
            }
            $top = [math]::Max($wa.Top, [math]::Min($rect.Top, $wa.Bottom - $Height))
            $Win.Left = $left; $Win.Top = $top
            return
        }
    } catch {}
    $Win.WindowStartupLocation = 'CenterScreen'
}

function Show-SysPilotWpfMenu {
    <# WPF-Variante von Show-SysPilotArrowMenu. Gibt Tag oder $null (Esc). #>
    param(
        [Parameter(Mandatory)][array]$Items,
        [string]$Title = '',
        [string]$Footer = 'Pfeiltasten hoch/runter, Enter = waehlen, Esc = zurueck',
        [int]$StartIndex = 0
    )
    if ($Items.Count -eq 0) { return $null }
    if (-not ('System.Windows.Markup.XamlReader' -as [type])) {
        try { Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop } catch {}
    }
    $pal = Get-SysPilotWpfPalette
    $bc = { param($h) [Windows.Media.BrushConverter]::new().ConvertFromString($h) }
    # XAML-Attribute escapen (Titel koennen & oder " enthalten)
    $TitleX = "$Title" -replace '&','&amp;' -replace '"','&quot;' -replace '<','&lt;' -replace '>','&gt;'
    $FooterX = "$Footer" -replace '&','&amp;' -replace '"','&quot;' -replace '<','&lt;' -replace '>','&gt;'

    # Item-Wrapper: Original-Tag bleibt unveraendert erhalten
    $wrapped = foreach ($it in $Items) {
        [pscustomobject]@{
            Label = "$($it.Label)"
            ColorHex = (ConvertTo-SysPilotMenuColor $it.Color)
            Tag    = $it.Tag
        }
    }
    $wrapped = @($wrapped)

    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="SysPilot - $TitleX" Width="560" SizeToContent="Height" MaxHeight="620"
        WindowStartupLocation="Manual" ResizeMode="NoResize"
        Background="$($pal.Bg)" Foreground="$($pal.Fg)"
        FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <Style TargetType="ListBoxItem">
      <Setter Property="Padding" Value="12,6"/>
      <Setter Property="Margin" Value="0,1"/>
      <Setter Property="Foreground" Value="$($pal.Fg)"/>
      <Style.Triggers>
        <Trigger Property="IsSelected" Value="True">
          <Setter Property="Background" Value="#CCE4EAF2"/>
          <Setter Property="Foreground" Value="#FF1E1E2E"/>
        </Trigger>
      </Style.Triggers>
    </Style>
  </Window.Resources>
  <DockPanel Margin="12">
    <Border DockPanel.Dock="Top" Padding="0,0,0,8">
      <DockPanel>
        <TextBlock x:Name="TitleText" Text="$TitleX" FontSize="16" FontWeight="Bold"
                   Foreground="$($pal.Accent)" VerticalAlignment="Center"/>
        <TextBlock x:Name="PosText" Text="" FontSize="11" Foreground="$($pal.Muted)"
                   HorizontalAlignment="Right" VerticalAlignment="Center"/>
      </DockPanel>
    </Border>
    <Border DockPanel.Dock="Bottom" Padding="0,8,0,0">
      <TextBlock x:Name="FooterText" Text="$FooterX" FontSize="11" Foreground="$($pal.Muted)"/>
    </Border>
    <ListBox x:Name="Lb" Background="Transparent" BorderThickness="0" MaxHeight="440"
             ScrollViewer.HorizontalScrollBarVisibility="Disabled"
             ScrollViewer.VerticalScrollBarVisibility="Auto">
      <ListBox.ItemTemplate>
        <DataTemplate>
          <TextBlock Text="{Binding Label}" TextTrimming="CharacterEllipsis"/>
        </DataTemplate>
      </ListBox.ItemTemplate>
    </ListBox>
  </DockPanel>
</Window>
"@
    $win = [Windows.Markup.XamlReader]::Parse($xaml)
    if (-not $win) { throw 'WPF-Menue: XAML konnte nicht gelesen werden' }
    Set-SysPilotWpfDarkTheme -Win $win -NoBackground
    Set-SysPilotMenuWindowPosition -Win $win

    $lb = $win.FindName('Lb')
    $pos = $win.FindName('PosText')
    $lb.ItemsSource = $wrapped
    $selIdx = [math]::Max(0, [math]::Min($StartIndex, $wrapped.Count - 1))
    # HashTable-Zelle: Event-Handler laufen in eigenem Scope und koennen
    # Skalar-Variablen der Funktion NICHT zurueckschreiben.
    $cell = @{ V = $null }

    $refreshPos = {
        if ($lb.SelectedIndex -ge 0) { $pos.Text = "$($lb.SelectedIndex + 1)/$($wrapped.Count)" }
        # Selektierte Zeile: dunkler Text auf Akzent-Hintergrund
        try {
            $bcvt = [Windows.Media.BrushConverter]::new()
            for ($i = 0; $i -lt $wrapped.Count; $i++) {
                $cont = $lb.ItemContainerGenerator.ContainerFromIndex($i)
                if ($cont) {
                    $fg = if ($i -eq $lb.SelectedIndex) { '#FF101018' } else { $wrapped[$i].ColorHex }
                    $cont.Foreground = $bcvt.ConvertFromString($fg)
                }
            }
        } catch {}
    }
    $lb.Add_SelectionChanged({ & $refreshPos })

    # Hover = Auswahl bewegen (wie im Konsolen-Menue)
    $lb.Add_PreviewMouseMove({
        try {
            $hit = $lb.InputHitTest([Windows.Input.Mouse]::GetPosition($lb))
            $node = $hit
            while ($node -and -not ($node -is [Windows.Controls.ListBoxItem])) { $node = $node.Parent }
            if ($node -and $node.DataContext) {
                $idx = [array]::IndexOf($wrapped, $node.DataContext)
                if ($idx -ge 0 -and $idx -ne $lb.SelectedIndex) { $lb.SelectedIndex = $idx }
            }
        } catch {}
    })

    $win.Add_PreviewKeyDown({
        param($s, $e)
        # Pfeiltasten auf Fenster-Ebene: funktioniert auch ohne ListBox-Fokus
        switch ($e.Key) {
            'Up'        { if ($lb.SelectedIndex -gt 0) { $lb.SelectedIndex-- }; $e.Handled=$true }
            'Down'      { if ($lb.SelectedIndex -lt $wrapped.Count-1) { $lb.SelectedIndex++ }; $e.Handled=$true }
            'PageUp'    { $lb.SelectedIndex = [math]::Max(0, $lb.SelectedIndex - 10); $e.Handled=$true }
            'PageDown'  { $lb.SelectedIndex = [math]::Min($wrapped.Count-1, $lb.SelectedIndex + 10); $e.Handled=$true }
            'Home'      { $lb.SelectedIndex = 0; $e.Handled=$true }
            'End'       { $lb.SelectedIndex = $wrapped.Count-1; $e.Handled=$true }
        }
    })
    $win.Add_KeyDown({
        param($s, $e)
        if ($e.Key -eq 'Escape') { $win.DialogResult = $false; $win.Close(); return }
        if (($e.Key -eq 'Return' -or $e.Key -eq 'Enter') -and $lb.SelectedItem) {
            $cell.V = $lb.SelectedItem.Tag
            $win.DialogResult = $true; $win.Close(); return
        }
    })
    # Einzelklick = sofort oeffnen (Hover waehlt eh schon aus -
    # Doppelklick war unnoetige Zweistufigkeit). Doppelklick bleibt
    # aus Kompatibilitaet zusaetzlich aktiv.
    $lb.Add_MouseLeftButtonUp({
        if ($lb.SelectedItem) { $cell.V = $lb.SelectedItem.Tag; $win.DialogResult = $true; $win.Close() }
    })
    $lb.Add_MouseDoubleClick({
        if ($lb.SelectedItem) { $cell.V = $lb.SelectedItem.Tag; $win.DialogResult = $true; $win.Close() }
    })
    $lb.Add_Loaded({
        $lb.SelectedIndex = $selIdx
        try { $lb.Focus() } catch {}
        & $refreshPos
    })

    # Herbert-Assistent-Leiste (Kontext = Menue-Titel)
    try { Add-SysPilotAssistantToWindow -Win $win -Context "Menue: $Title" -AutoHerbert:$false | Out-Null } catch {}

    [void]$win.ShowDialog()
    return $cell.V
}

function Show-SysPilotWpfMultiSelect {
    <# WPF-Variante von Show-SysPilotMultiSelectMenu.
       Rueckgabe identisch zur Konsole: $null bei Esc; Array der Tags
       (bzw. @{Selected;Action} wenn -Actions gesetzt). #>
    param(
        [Parameter(Mandatory)][array]$Items,
        [string]$Title = '',
        [string]$Footer = 'Pfeiltasten/Klick, Leertaste = Haken, A = alle, Enter = uebernehmen, Esc = abbrechen',
        [array]$Actions = @()
    )
    if ($Items.Count -eq 0) { return @() }
    if (-not ('System.Windows.Markup.XamlReader' -as [type])) {
        try { Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop } catch {}
    }
    $pal = Get-SysPilotWpfPalette
    $bc = { param($h) [Windows.Media.BrushConverter]::new().ConvertFromString($h) }
    $hasActions = $Actions.Count -gt 0
    $TitleX = "$Title" -replace '&','&amp;' -replace '"','&quot;' -replace '<','&lt;' -replace '>','&gt;'
    $FooterX = "$Footer" -replace '&','&amp;' -replace '"','&quot;' -replace '<','&lt;' -replace '>','&gt;'

    $wrapped = foreach ($it in $Items) {
        [pscustomobject]@{
            Label = "$($it.Label)"
            ColorHex = (ConvertTo-SysPilotMenuColor $it.Color)
            Tag    = $it.Tag
            Checked = [bool]$it.Checked
        }
    }
    $wrapped = @($wrapped)
    $actionList = @($Actions)

    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="SysPilot - $TitleX" Width="580" SizeToContent="Height" MaxHeight="640"
        WindowStartupLocation="Manual" ResizeMode="NoResize"
        Background="$($pal.Bg)" Foreground="$($pal.Fg)"
        FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <Style TargetType="ListBoxItem">
      <Setter Property="Padding" Value="12,4"/>
      <Setter Property="Margin" Value="0,1"/>
      <Setter Property="Foreground" Value="$($pal.Fg)"/>
      <Style.Triggers>
        <Trigger Property="IsSelected" Value="True">
          <Setter Property="Background" Value="#CCE4EAF2"/>
          <Setter Property="Foreground" Value="#FF1E1E2E"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="$($pal.Fg)"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
  </Window.Resources>
  <DockPanel Margin="12">
    <Border DockPanel.Dock="Top" Padding="0,0,0,8">
      <DockPanel>
        <TextBlock Text="$TitleX" FontSize="16" FontWeight="Bold"
                   Foreground="$($pal.Accent)" VerticalAlignment="Center"/>
        <TextBlock x:Name="PosText" Text="" FontSize="11" Foreground="$($pal.Muted)"
                   HorizontalAlignment="Right" VerticalAlignment="Center"/>
      </DockPanel>
    </Border>
    <Border DockPanel.Dock="Bottom" Padding="0,8,0,0">
      <StackPanel>
        <WrapPanel x:Name="ActionPanel" Margin="0,0,0,6"/>
        <TextBlock x:Name="FooterText" Text="$FooterX" FontSize="11" Foreground="$($pal.Muted)"/>
      </StackPanel>
    </Border>
    <ListBox x:Name="Lb" Background="Transparent" BorderThickness="0" MaxHeight="460"
             ScrollViewer.HorizontalScrollBarVisibility="Disabled"
             ScrollViewer.VerticalScrollBarVisibility="Auto">
      <ListBox.ItemTemplate>
        <DataTemplate>
          <CheckBox Content="{Binding Label}" IsChecked="{Binding Checked, Mode=TwoWay}"/>
        </DataTemplate>
      </ListBox.ItemTemplate>
    </ListBox>
  </DockPanel>
</Window>
"@
    $win = [Windows.Markup.XamlReader]::Parse($xaml)
    if (-not $win) { throw 'WPF-Menue: XAML konnte nicht gelesen werden' }
    Set-SysPilotWpfDarkTheme -Win $win -NoBackground
    Set-SysPilotMenuWindowPosition -Win $win

    $lb = $win.FindName('Lb')
    $pos = $win.FindName('PosText')
    $lb.ItemsSource = $wrapped
    $bcvt = [Windows.Media.BrushConverter]::new()
    $script:_msResult = $null

    $collect = {
        $out = @()
        foreach ($w in $wrapped) { if ($w.Checked) { $out += $w.Tag } }
        # NICHT ',$out' + '@(& $collect)' verwenden - das verschachtelt
        # Selected ein Level zu tief (Array im Array) und bricht alle
        # Aufrufer, die Tags direkt weiterverarbeiten (z.B. $c.Browser).
        $out
    }
    $finishAction = {
        param($actTag)
        $selTags = @(& $collect)
        if ($hasActions) { $script:_msResult = [PSCustomObject]@{ Selected = $selTags; Action = $actTag } }
        else { $script:_msResult = $selTags }
        $win.DialogResult = $true; $win.Close()
    }

    # Aktions-Buttons dynamisch anlegen (Tag = Action-Tag)
    $ap = $win.FindName('ActionPanel')
    if ($hasActions) {
        foreach ($a in $actionList) {
            $btn = New-Object Windows.Controls.Button
            $btn.Content = "[ $($a.Label) ]"
            $btn.Tag = $a.Tag
            $btn.Margin = '0,0,8,0'; $btn.Padding = '10,3'
            $fg = ConvertTo-SysPilotMenuColor $a.Color
            $btn.Foreground = $bcvt.ConvertFromString($fg)
            # Tag ueber den Sender lesen - NICHT $a.Tag im Handler:
            # Schleifen-Variablen werden per Referenz geteilt, alle
            # Buttons haetten sonst das letzte Tag ('back').
            $btn.Add_Click({ param($s, $e) & $finishAction $s.Tag })
            [void]$ap.Children.Add($btn)
        }
    } else { $ap.Visibility = 'Collapsed' }

    # Findet die CheckBox im visuellen Baum eines ListBoxItem
    $findCb = {
        param($parent)
        $stack = New-Object 'System.Collections.Generic.Stack[System.Windows.DependencyObject]'
        $stack.Push($parent)
        while ($stack.Count -gt 0) {
            $n = $stack.Pop()
            if ($n -is [Windows.Controls.CheckBox]) { return $n }
            $cnt = 0
            try { $cnt = [Windows.Media.VisualTreeHelper]::GetChildrenCount($n) } catch {}
            for ($i = 0; $i -lt $cnt; $i++) {
                try { $stack.Push([Windows.Media.VisualTreeHelper]::GetChild($n, $i)) } catch {}
            }
        }
        return $null
    }
    # Checkbox-Farbe: Checked = Gruen, selektiert = dunkel, sonst Item-Farbe
    $refreshPos = {
        if ($lb.SelectedIndex -ge 0) { $pos.Text = "$($lb.SelectedIndex + 1)/$($wrapped.Count)" }
        try {
            for ($i = 0; $i -lt $wrapped.Count; $i++) {
                $cont = $lb.ItemContainerGenerator.ContainerFromIndex($i)
                if (-not $cont) { continue }
                $cbx = & $findCb $cont
                if ($cbx) {
                    $hex = if ($i -eq $lb.SelectedIndex) { '#FF101018' }
                           elseif ($wrapped[$i].Checked) { '#FF9CCC65' }
                           else { $wrapped[$i].ColorHex }
                    $cbx.Foreground = $bcvt.ConvertFromString($hex)
                }
            }
        } catch {}
    }
    $lb.Add_SelectionChanged({ & $refreshPos })

    $lb.Add_PreviewMouseMove({
        try {
            $hit = $lb.InputHitTest([Windows.Input.Mouse]::GetPosition($lb))
            $node = $hit
            while ($node -and -not ($node -is [Windows.Controls.ListBoxItem])) { $node = $node.Parent }
            if ($node -and $node.DataContext) {
                $idx = [array]::IndexOf($wrapped, $node.DataContext)
                if ($idx -ge 0 -and $idx -ne $lb.SelectedIndex) { $lb.SelectedIndex = $idx }
            }
        } catch {}
    })

    $lb.Add_PreviewMouseLeftButtonUp({ & $refreshPos })

    $win.Add_PreviewKeyDown({
        param($s, $e)
        # Fokus auf Aktions-Button: Enter/Leertaste normal an den Button lassen
        if ($e.OriginalSource -is [Windows.Controls.Button]) { return }
        switch ($e.Key) {
            'Up'        { if ($lb.SelectedIndex -gt 0) { $lb.SelectedIndex-- }; $e.Handled=$true; return }
            'Down'      { if ($lb.SelectedIndex -lt $wrapped.Count-1) { $lb.SelectedIndex++ }; $e.Handled=$true; return }
            'PageUp'    { $lb.SelectedIndex = [math]::Max(0, $lb.SelectedIndex - 10); $e.Handled=$true; return }
            'PageDown'  { $lb.SelectedIndex = [math]::Min($wrapped.Count-1, $lb.SelectedIndex + 10); $e.Handled=$true; return }
            'Home'      { $lb.SelectedIndex = 0; $e.Handled=$true; return }
            'End'       { $lb.SelectedIndex = $wrapped.Count-1; $e.Handled=$true; return }
        }
        if ($e.Key -eq 'Escape') { $win.DialogResult = $false; $win.Close(); $e.Handled = $true; return }
        if ($e.Key -eq 'Return' -or $e.Key -eq 'Enter') {
            if (@(& $collect).Count -gt 0) { & $finishAction $null }
            $e.Handled = $true; return
        }
        if ($e.Key -eq 'Space' -and $lb.SelectedItem) {
            $lb.SelectedItem.Checked = -not $lb.SelectedItem.Checked
            & $refreshPos
            $e.Handled = $true; return
        }
        if ($e.Key -eq 'A') {
            foreach ($w in $wrapped) { $w.Checked = $true }
            $lb.Items.Refresh(); & $refreshPos; $e.Handled = $true; return
        }
        if ($hasActions -and [int]$e.Key -ge [int][Windows.Input.Key]::D1 -and [int]$e.Key -le [int][Windows.Input.Key]::D9) {
            $ai = [int]$e.Key - [int][Windows.Input.Key]::D1
            if ($ai -lt $actionList.Count) { & $finishAction $actionList[$ai].Tag }
            $e.Handled = $true; return
        }
    })
    $lb.Add_MouseDoubleClick({
        if ($lb.SelectedItem) { $lb.SelectedItem.Checked = -not $lb.SelectedItem.Checked; & $refreshPos }
    })
    $lb.Add_Loaded({
        try { $lb.SelectedIndex = 0; $lb.Focus() } catch {}
        & $refreshPos
    })

    try { Add-SysPilotAssistantToWindow -Win $win -Context "Menue: $Title" -AutoHerbert:$false | Out-Null } catch {}

    [void]$win.ShowDialog()
    if ($win.DialogResult -eq $true) { return $script:_msResult }
    return $null
}

function Show-SysPilotArrowMenu {
    <# Dispatcher: oeffnet das Menu als WPF-Fenster (SysPilot-Design,
       Herbert-Leiste, Position neben der Konsole). Fallback: das
       originale Konsolen-Pfeiltasten-Menue.
       Gibt Tag des gewaehlten Eintrags zurueck oder $null bei Esc. #>
    param(
        [Parameter(Mandatory)][array]$Items,
        [string]$Title = '',
        [string]$Footer = 'Pfeiltasten hoch/runter, Enter = waehlen, Esc = zurueck',
        [int]$StartIndex = 0
    )
    if ($Items.Count -eq 0) { return $null }
    if (Test-SysPilotWpfMenuAvailable) {
        try { return (Show-SysPilotWpfMenu -Items $Items -Title $Title -Footer $Footer -StartIndex $StartIndex) }
        catch { try { Write-SysPilotDebug "WPF-Menue fehlgeschlagen ($Title): $($_.Exception.Message)" } catch {} }
    }
    return (Show-SysPilotArrowMenuConsole -Items $Items -Title $Title -Footer $Footer -StartIndex $StartIndex)
}

function Show-SysPilotMultiSelectMenu {
    <# Dispatcher wie Show-SysPilotArrowMenu, fuer Mehrfachauswahl. #>
    param(
        [Parameter(Mandatory)][array]$Items,
        [string]$Title = '',
        [string]$Footer = 'Pfeiltasten/Klick, Leertaste = Haken, A = alle, Enter = uebernehmen, Esc = abbrechen',
        [array]$Actions = @()
    )
    if ($Items.Count -eq 0) { return @() }
    if (Test-SysPilotWpfMenuAvailable) {
        try { return (Show-SysPilotWpfMultiSelect -Items $Items -Title $Title -Footer $Footer -Actions $Actions) }
        catch { try { Write-SysPilotDebug "WPF-Mehrfachmenue fehlgeschlagen ($Title): $($_.Exception.Message)" } catch {} }
    }
    return (Show-SysPilotMultiSelectMenuConsole -Items $Items -Title $Title -Footer $Footer -Actions $Actions)
}

function Get-SysPilotConsoleViewport {
    <# Liefert die SICHTBARE Konsolen-Groesse (Viewport) in Zeichen.
       srWindow aus GetConsoleScreenBufferInfo ist in conhost UND
       Windows Terminal zuverlaessig; [Console]::WindowHeight kann in
       manchen Hosts die Buffer-Hoehe liefern (dann scrollt die Anzeige
       und Maus-Koordinaten stimmen nicht mehr). Fallback: Console-API. #>
    try {
        $h = [SysPilotConsoleInput]::GetStdHandle(-11)
        if ($h -ne [IntPtr]::Zero -and $h.ToInt64() -ne -1) {
            $info = New-Object SysPilotConsoleInput+CONSOLE_SCREEN_BUFFER_INFO
            if ([SysPilotConsoleInput]::GetConsoleScreenBufferInfo($h, [ref]$info)) {
                $rows = $info.srWindow.Bottom - $info.srWindow.Top + 1
                $cols = $info.srWindow.Right - $info.srWindow.Left + 1
                if ($rows -gt 0 -and $cols -gt 0) { return @{ Rows = [int]$rows; Cols = [int]$cols } }
            }
        }
    } catch { }
    $rows = 30; $cols = 120
    try { $rows = [Console]::WindowHeight } catch { }
    try { $cols = [Console]::WindowWidth } catch { }
    return @{ Rows = $rows; Cols = $cols }
}

function Show-SysPilotMultiSelectMenuConsole {
    <# Konsolen-Variante von Show-SysPilotMultiSelectMenu (Fallback).
       Mehrfachauswahl per Pfeiltasten: hoch/runter, Leertaste = Haken,
       Enter = Auswahl bestaetigen, Esc = abbrechen.
       Maus: Linksklick auf Eintrag = Haken umschalten, Mausrad = blaettern.
       Items: Array von @{ Label; Color; Tag; Checked } - gibt Array der
       Tags der abgehakten Eintraege zurueck oder $null bei Esc.
       Optional -Actions @(@{Label;Tag;Color}): zusaetzliche klickbare
       Buttons unter der Liste. Wenn gesetzt, gibt die Funktion IMMER ein
       Objekt zurueck: @{ Selected = @(Tags); Action = $null|<ActionTag> }.
       Tastatur: Ziffern 1-9 loesen Actions aus, Enter = Selected. #>
    param(
        [Parameter(Mandatory)][array]$Items,
        [string]$Title = '',
        [string]$Footer = 'Pfeiltasten/Klick, Leertaste = Haken, A = alle, Enter = uebernehmen, Esc = abbrechen',
        [array]$Actions = @()
    )
    if ($Items.Count -eq 0) { return @() }
    Clear-SysPilotPendingKeys
    $useApi = Initialize-SysPilotConsoleInput
    if ($useApi) { Clear-SysPilotConsoleInputBuffer }
    $sel = 0
    # Fenster-Darstellung: bei langen Listen nur eine Sichtscheibe zeichnen,
    # sonst flackert die Anzeige bei jedem Hover (Clear-Host + hunderte Zeilen).
    # WICHTIG: Die sichtbare Groesse wird aus der FENSTERHOEHE berechnet -
    # sonst scrollt die Konsole beim Zeichnen und die gespeicherten Zeilen-
    # positionen (itemStartRow/actionStartRow) stimmen nicht mehr mit den
    # Mausklick-Koordinaten ueberein (Highlight versetzt, Klicks falsch).
    $viewTop = 0
    $windowed = $false
    $viewSize = 0
    $actionStartRow = -1
    $actionCols = @()
    $hasActions = $Actions.Count -gt 0
    try {
    $needDraw = $true
    while ($true) {
        if ($needDraw) {
            # Zeilenbudget: Titel(3) + Items + Leer(1) + Buttons(2) + Footer(1)
            # Viewport-Hoehe aus der Console-API (srWindow) - zuverlaessig
            # in conhost UND Windows Terminal, anders als WindowHeight.
            $vp = Get-SysPilotConsoleViewport
            $winH = $vp.Rows
            $overhead = 2 + $(if ($hasActions) { 3 } else { 0 }) + $(if ($Title) { 3 } else { 0 })
            $viewSize = [Math]::Max(3, $winH - $overhead - 1)
            $windowed = $Items.Count -gt $viewSize
            Clear-Host
            if ($Title) {
                Write-Host ""
                Write-Host "  $Title" -ForegroundColor Cyan
                Write-Host ""
            }
            if ($windowed) {
                if ($sel -lt $viewTop) { $viewTop = $sel }
                if ($sel -ge $viewTop + $viewSize) { $viewTop = $sel - $viewSize + 1 }
                $viewTop = [Math]::Max(0, [Math]::Min($viewTop, $Items.Count - $viewSize))
            } else { $viewTop = 0 }
            $itemStartRow = $Host.UI.RawUI.CursorPosition.Y
            $viewEnd = if ($windowed) { [Math]::Min($Items.Count, $viewTop + $viewSize) } else { $Items.Count }
            for ($i = $viewTop; $i -lt $viewEnd; $i++) {
                $it = $Items[$i]
                $mark = if ($it.Checked) { '[x]' } else { '[ ]' }
                $prefix = if ($i -eq $sel) { ' > ' } else { '   ' }
                $line = "$prefix$mark $($it.Label)"
                if ($i -eq $sel) { Write-Host $line -ForegroundColor Black -BackgroundColor Cyan }
                else { Write-Host $line -ForegroundColor $(if ($it.Checked) { 'Green' } else { if ($it.Color) { $it.Color } else { 'White' } }) }
            }
            Write-Host ""
            $cnt = @($Items | Where-Object { $_.Checked }).Count
            $pos = if ($windowed) { "  Eintrag $($sel + 1)/$($Items.Count)  |  " } else { '' }
            if ($Actions.Count -gt 0) {
                # Buttons in EINER Zeile mit Abstand; Spalten werden fuer
                # Klick-Trefferatz gespeichert (actionCols: Start/End/Tag)
                $actionStartRow = $Host.UI.RawUI.CursorPosition.Y
                $actionCols = @()
                $colPos = 2
                Write-Host '  ' -NoNewline
                foreach ($a in $Actions) {
                    $btn = "[ $($a.Label) ]"
                    $actionCols += @{ Start = $colPos; End = $colPos + $btn.Length; Tag = $a.Tag }
                    $acol = if ($a.Color) { $a.Color } else { 'Green' }
                    Write-Host $btn -ForegroundColor $acol -NoNewline
                    Write-Host '   ' -NoNewline
                    $colPos += $btn.Length + 3
                }
                Write-Host ''
                Write-Host ""
            }
            Write-Host ("$pos$Footer  |  ausgewaehlt: $cnt") -ForegroundColor DarkGray
        }
        $needDraw = $true
        $ev = Read-SysPilotMenuEvent
        if ($ev.Kind -eq 'Key') {
            switch ([int]$ev.Vk) {
                38 { $sel = ($sel - 1 + $Items.Count) % $Items.Count }
                40 { $sel = ($sel + 1) % $Items.Count }
                33 { $sel = [Math]::Max(0, $sel - $viewSize) }
                34 { $sel = [Math]::Min($Items.Count - 1, $sel + $viewSize) }
                36 { $sel = 0 }
                35 { $sel = $Items.Count - 1 }
                27 { return $null }
                13 {
                    $out = @()
                    foreach ($it in $Items) { if ($it.Checked) { $out += $it.Tag } }
                    if ($out.Count -eq 0) { continue }
                    if ($hasActions) { return [PSCustomObject]@{ Selected = $out; Action = $null } }
                    return $out
                }
                32 { $Items[$sel].Checked = -not $Items[$sel].Checked }
                65 { foreach ($it in $Items) { $it.Checked = $true } }
                { [int]$ev.Vk -ge 49 -and [int]$ev.Vk -le 57 -and $hasActions } {
                    $ai = [int]$ev.Vk - 49
                    if ($ai -lt $Actions.Count) {
                        $selTags = @(); foreach ($it in $Items) { if ($it.Checked) { $selTags += $it.Tag } }
                        return [PSCustomObject]@{ Selected = $selTags; Action = $Actions[$ai].Tag }
                    }
                }
            }
        } else {
            # Klick auf Aktions-Button? (eine Zeile, Spalten-Test per Col)
            if ($hasActions -and $actionStartRow -ge 0 -and [int]$ev.Row -eq $actionStartRow -and $ev.Action -eq 'Click') {
                foreach ($ac in $actionCols) {
                    if ([int]$ev.Col -ge $ac.Start -and [int]$ev.Col -lt $ac.End) {
                        $selTags = @(); foreach ($it in $Items) { if ($it.Checked) { $selTags += $it.Tag } }
                        return [PSCustomObject]@{ Selected = $selTags; Action = $ac.Tag }
                    }
                }
                $needDraw = $false
            }
            $idx = $viewTop + ([int]$ev.Row - $itemStartRow)
            $inView = ($idx -ge $viewTop -and $idx -lt $viewEnd)
            switch ($ev.Action) {
                'Move' {
                    if ($inView -and $idx -ne $sel) { $sel = $idx }
                    else { $needDraw = $false }
                }
                'Click' {
                    if ($inView) { $Items[$idx].Checked = -not $Items[$idx].Checked }
                    else { $needDraw = $false }
                }
                'WheelUp'   { $step = [Math]::Max(3, [int]($viewSize / 3)); $sel = [Math]::Max(0, $sel - $step) }
                'WheelDown' { $step = [Math]::Max(3, [int]($viewSize / 3)); $sel = [Math]::Min($Items.Count - 1, $sel + $step) }
            }
        }
    }
    } finally {
        if ($useApi) { Restore-SysPilotConsoleInput }
    }
}

function Find-SysPilotJsonSection {
    <# Findet "Key":<Wert> in JSON-Text per Regex + Klammer-Scanning
       (stringsicher). Gibt @{ Start; End; Text } zurueck, wobei Start/End
       den WERT (ohne "Key":) im Originaltext markieren, oder $null.
       -MustContain <key>: ueberspringt Kandidaten, deren Wert den
       Unter-Schluessel NICHT enthaelt - noetig bei mehrdeutigen Keys
       (z.B. "extensions" kommt in Chromium-Prefs mehrfach vor:
       account_values.extensions.ui, echtes extensions.settings,
       protection.macs.extensions - nur das echte hat "settings"). #>
    param([Parameter(Mandatory)][string]$Json, [Parameter(Mandatory)][string]$Key,
          [string]$MustContain = '')
    $rx = New-Object System.Text.RegularExpressions.Regex('"' + [regex]::Escape($Key) + '"\s*:')
    $searchFrom = 0
    $len = $Json.Length
    while ($searchFrom -lt $len) {
        $m = $rx.Match($Json, $searchFrom)
        if (-not $m.Success) { return $null }
        $i = $m.Index + $m.Length
        while ($i -lt $len -and [char]::IsWhiteSpace($Json[$i])) { $i++ }
        if ($i -ge $len) { return $null }
        $open = $Json[$i]
        if ($open -eq '{' -or $open -eq '[') {
            $close = if ($open -eq '{') { '}' } else { ']' }
            $depth = 0; $inStr = $false; $esc = $false; $endIdx = -1
            for ($j = $i; $j -lt $len; $j++) {
                $c = $Json[$j]
                if ($inStr) {
                    if ($esc) { $esc = $false }
                    elseif ($c -eq '\') { $esc = $true }
                    elseif ($c -eq '"') { $inStr = $false }
                    continue
                }
                if ($c -eq '"') { $inStr = $true }
                elseif ($c -eq $open) { $depth++ }
                elseif ($c -eq $close) {
                    $depth--
                    if ($depth -eq 0) { $endIdx = $j + 1; break }
                }
            }
            if ($endIdx -lt 0) { return $null }
            $txt = $Json.Substring($i, $endIdx - $i)
            if ($MustContain -and $txt -notmatch ('"' + [regex]::Escape($MustContain) + '"\s*:')) {
                $searchFrom = $m.Index + $m.Length
                continue
            }
            return @{ Start = $i; End = $endIdx; Text = $txt }
        }
        $j = $i; $inStr = $false; $esc = $false
        while ($j -lt $len) {
            $c = $Json[$j]
            if ($inStr) {
                if ($esc) { $esc = $false }
                elseif ($c -eq '\') { $esc = $true }
                elseif ($c -eq '"') { $inStr = $false }
                $j++; continue
            }
            if ($c -eq '"') { $inStr = $true; $j++; continue }
            if ($c -eq ',' -or $c -eq '}' -or $c -eq ']') { break }
            $j++
        }
        $txt = $Json.Substring($i, $j - $i).Trim()
        if ($MustContain -and $txt -notmatch ('"' + [regex]::Escape($MustContain) + '"\s*:')) {
            $searchFrom = $m.Index + $m.Length
            continue
        }
        return @{ Start = $i; End = $j; Text = $txt }
    }
    return $null
}

function Get-SysPilotJsonChildProperties {
    <# Listet die DIREKTEN Kind-Elemente eines JSON-Objekt-Texts
       ({"k":v,...}) per Scanner auf - stringsicher, unveraendert den Text.
       Gibt Array von @{ Key; KeyStart; ValueStart; ValueEnd; Value } zurueck
       (Value = Rohtext des Werts). Benoetigt fuer Dateien mit doppelten
       Schluesseln, die ConvertFrom-Json nicht parsen kann. #>
    param([Parameter(Mandatory)][string]$Json)
    $props = @()
    $len = $Json.Length
    $i = 0
    # oeffnende Klammer ueberspringen
    while ($i -lt $len -and [char]::IsWhiteSpace($Json[$i])) { $i++ }
    if ($i -ge $len -or $Json[$i] -ne '{') { return $props }
    $i++
    while ($i -lt $len) {
        while ($i -lt $len -and [char]::IsWhiteSpace($Json[$i])) { $i++ }
        if ($i -ge $len -or $Json[$i] -eq '}') { break }
        if ($Json[$i] -ne '"') { break }
        $keyStart = $i
        $i++
        $key = ''
        $esc = $false
        while ($i -lt $len) {
            $c = $Json[$i]
            if ($esc) {
                switch ($c) { 'n' { $key += "`n" } 't' { $key += "`t" } 'r' { $key += "`r" } default { $key += $c } }
                $esc = $false; $i++; continue
            }
            if ($c -eq '\') { $esc = $true; $i++; continue }
            if ($c -eq '"') { $i++; break }
            $key += $c; $i++
        }
        while ($i -lt $len -and [char]::IsWhiteSpace($Json[$i])) { $i++ }
        if ($i -ge $len -or $Json[$i] -ne ':') { break }
        $i++
        while ($i -lt $len -and [char]::IsWhiteSpace($Json[$i])) { $i++ }
        $vStart = $i
        if ($i -ge $len) { break }
        $c = $Json[$i]
        if ($c -eq '{' -or $c -eq '[') {
            $open = $c; $close = $(if ($open -eq '{') { '}' } else { ']' })
            $depth = 0; $inStr = $false; $esc = $false; $vEnd = -1
            for ($j = $i; $j -lt $len; $j++) {
                $ch = $Json[$j]
                if ($inStr) {
                    if ($esc) { $esc = $false }
                    elseif ($ch -eq '\') { $esc = $true }
                    elseif ($ch -eq '"') { $inStr = $false }
                    continue
                }
                if ($ch -eq '"') { $inStr = $true }
                elseif ($ch -eq $open) { $depth++ }
                elseif ($ch -eq $close) {
                    $depth--
                    if ($depth -eq 0) { $vEnd = $j + 1; break }
                }
            }
            if ($vEnd -lt 0) { break }
            $props += @{ Key = $key; KeyStart = $keyStart; ValueStart = $vStart; ValueEnd = $vEnd; Value = $Json.Substring($vStart, $vEnd - $vStart) }
            $i = $vEnd
        } else {
            $inStr = $false; $esc = $false; $vEnd = $i
            while ($vEnd -lt $len) {
                $ch = $Json[$vEnd]
                if ($inStr) {
                    if ($esc) { $esc = $false }
                    elseif ($ch -eq '\') { $esc = $true }
                    elseif ($ch -eq '"') { $inStr = $false }
                    $vEnd++; continue
                }
                if ($ch -eq '"') { $inStr = $true; $vEnd++; continue }
                if ($ch -eq ',' -or $ch -eq '}' -or $ch -eq ']') { break }
                $vEnd++
            }
            $props += @{ Key = $key; KeyStart = $keyStart; ValueStart = $vStart; ValueEnd = $vEnd; Value = $Json.Substring($vStart, $vEnd - $vStart).Trim() }
            $i = $vEnd
        }
        while ($i -lt $len -and [char]::IsWhiteSpace($Json[$i])) { $i++ }
        if ($i -lt $len -and $Json[$i] -eq ',') { $i++; continue }
        break
    }
    return $props
}

function ConvertFrom-SysPilotJsonScalar {
    <# Wandelt einen JSON-Skalar-Rohtext in einen PS-Wert um. #>
    param([Parameter(Mandatory)][string]$Text)
    $t = $Text.Trim()
    if ($t.Length -ge 2 -and $t[0] -eq '"' -and $t[$t.Length-1] -eq '"') {
        $inner = $t.Substring(1, $t.Length - 2)
        return ($inner -replace '\\"','"' -replace '\\\\','\')
    }
    if ($t -match '^-?\d+$') { return [int64]$t }
    if ($t -match '^-?\d+\.\d+$') { return [double]$t }
    if ($t -eq 'true') { return $true }
    if ($t -eq 'false') { return $false }
    return $t
}

function Get-SysPilotJsonSectionText {
    <# Text des Werts eines JSON-Objekt-Schluessels (siehe Find-...#Section). #>
    param([Parameter(Mandatory)][string]$Json, [Parameter(Mandatory)][string]$Key, [string]$MustContain = '')
    $s = Find-SysPilotJsonSection -Json $Json -Key $Key -MustContain $MustContain
    if ($null -eq $s) { return $null }
    return $s.Text
}

function Get-SysPilotChromiumExtensionSettings {
    <# Liest extensions.settings aus einer Chromium-Prefs-Datei
       (Secure Preferences/Preferences). Schneller Pfad: komplettes
       ConvertFrom-Json. Fallback: Scanner-basierte Extraktion, weil
       z.B. Edge-Dateien doppelte Schluessel enthalten
       (macroEnabled.12/macroenabled.12) und ConvertFrom-Json dann
       komplett scheitert - der Fallback baut pro Extension ein
       minimales Objekt (manifest.name/version/type + state).
       Gibt $null zurueck, wenn nichts da. #>
    param([Parameter(Mandatory)][string]$PrefPath)
    $raw = Read-SysPilotFileRaw -Path $PrefPath
    if (-not $raw) { return $null }
    try {
        $j = $raw | ConvertFrom-Json
        if ($j.extensions -and $j.extensions.settings) { return $j.extensions.settings }
        return $null
    } catch { }
    $ext = Get-SysPilotJsonSectionText -Json $raw -Key 'extensions' -MustContain 'settings'
    if (-not $ext) { return $null }
    $set = Get-SysPilotJsonSectionText -Json $ext -Key 'settings'
    if (-not $set) { return $null }
    # Scanner-Fallback: Kind-Elemente von settings durchgehen
    $result = [PSCustomObject]@{}
    $count = 0
    foreach ($pr in (Get-SysPilotJsonChildProperties -Json $set)) {
        $manifest = $null; $state = $null; $location = $null
        foreach ($ch in (Get-SysPilotJsonChildProperties -Json $pr.Value)) {
            if ($ch.Key -eq 'manifest') {
                $mObj = [PSCustomObject]@{ name = $null; version = $null; type = $null }
                foreach ($mc in (Get-SysPilotJsonChildProperties -Json $ch.Value)) {
                    if ($mc.Key -eq 'name')    { $mObj.name = ConvertFrom-SysPilotJsonScalar -Text $mc.Value }
                    elseif ($mc.Key -eq 'version') { $mObj.version = ConvertFrom-SysPilotJsonScalar -Text $mc.Value }
                    elseif ($mc.Key -eq 'type')   { $mObj.type = ConvertFrom-SysPilotJsonScalar -Text $mc.Value }
                }
                $manifest = $mObj
            } elseif ($ch.Key -eq 'state') {
                $state = ConvertFrom-SysPilotJsonScalar -Text $ch.Value
            } elseif ($ch.Key -eq 'location') {
                $location = ConvertFrom-SysPilotJsonScalar -Text $ch.Value
            }
        }
        $entry = [PSCustomObject]@{ manifest = $manifest; state = $state; location = $location }
        $result | Add-Member -NotePropertyName $pr.Key -NotePropertyValue $entry -Force
        $count++
    }
    if ($count -eq 0) { return $null }
    return $result
}

function Remove-SysPilotJsonPropertyText {
    <# Entfernt "Key":<Wert> inkl. Komma aus JSON-Objekt-Text, ohne den
       Rest des Dokuments anzufassen (roh-Text, stringsicher).
       Gibt den neuen Text zurueck oder $null, wenn Key nicht vorhanden. #>
    param([Parameter(Mandatory)][string]$Json, [Parameter(Mandatory)][string]$Key)
    $m = [regex]::Match($Json, '"' + [regex]::Escape($Key) + '"\s*:')
    if (-not $m.Success) { return $null }
    $keyStart = $m.Index
    $i = $m.Index + $m.Length
    while ($i -lt $Json.Length -and [char]::IsWhiteSpace($Json[$i])) { $i++ }
    if ($i -ge $Json.Length) { return $null }
    $open = $Json[$i]
    $end = $i
    if ($open -eq '{' -or $open -eq '[') {
        $close = if ($open -eq '{') { '}' } else { ']' }
        $depth = 0; $inStr = $false; $esc = $false; $found = $false
        for ($j = $i; $j -lt $Json.Length; $j++) {
            $c = $Json[$j]
            if ($inStr) {
                if ($esc) { $esc = $false }
                elseif ($c -eq '\') { $esc = $true }
                elseif ($c -eq '"') { $inStr = $false }
                continue
            }
            if ($c -eq '"') { $inStr = $true }
            elseif ($c -eq $open) { $depth++ }
            elseif ($c -eq $close) {
                $depth--
                if ($depth -eq 0) { $end = $j + 1; $found = $true; break }
            }
        }
        if (-not $found) { return $null }
    } else {
        $inStr = $false; $esc = $false
        while ($end -lt $Json.Length) {
            $c = $Json[$end]
            if ($inStr) {
                if ($esc) { $esc = $false }
                elseif ($c -eq '\') { $esc = $true }
                elseif ($c -eq '"') { $inStr = $false }
                $end++; continue
            }
            if ($c -eq '"') { $inStr = $true; $end++; continue }
            if ($c -eq ',' -or $c -eq '}' -or $c -eq ']') { break }
            $end++
        }
    }
    # Komma mit entfernen: direkt vor dem Key (",\"id\":{...}") oder dahinter.
    # Vorwaerts-Scan auf das letzte nicht-leere Zeichen vor dem Key -
    # robust gegen Kommas in Strings frueherer Werte.
    $k = $keyStart - 1
    while ($k -ge 0 -and [char]::IsWhiteSpace($Json[$k])) { $k-- }
    if ($k -ge 0 -and $Json[$k] -eq ',') {
        return $Json.Substring(0, $k) + $Json.Substring($end)
    }
    $after = $Json.Substring($end)
    if ($after -match '^\s*,') {
        $skip = $after.IndexOf(',') + 1
        return $Json.Substring(0, $keyStart) + $after.Substring($skip)
    }
    return $Json.Substring(0, $keyStart) + $Json.Substring($end)
}

function Read-SysPilotFileRaw {
    <# Liest eine Textdatei mit FileShare.ReadWrite - funktioniert auch
       wenn ein Browser die Datei gerade schreibt/liest. #>
    param([Parameter(Mandatory)][string]$Path)
    $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
        try { return $sr.ReadToEnd() } finally { $sr.Close() }
    } finally { $fs.Close() }
}

function Write-SysPilotFileRaw {
    <# Schreibt Text OHNE BOM (UTF8-Encoding($false)) mit
       FileShare.ReadWrite und Retry - Chromium-Prefs (Secure
       Preferences/extensions.json) dürfen keinen BOM haben, sonst
       werte der Browser die Datei evtl. als korrupt und stellt
       Einträge wieder her. #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Content)
    $enc = New-Object System.Text.UTF8Encoding($false)
    $lastErr = $null
    for ($try = 0; $try -lt 4; $try++) {
        try {
            $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Create,
                [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
            try {
                $sw = New-Object System.IO.StreamWriter($fs, $enc)
                try { $sw.Write($Content) } finally { $sw.Close() }
            } finally { $fs.Close() }
            return $true
        } catch {
            $lastErr = $_.Exception.Message
            Start-Sleep -Milliseconds 300
        }
    }
    throw "Schreiben fehlgeschlagen: $lastErr"
}

function Remove-SysPilotPrefExtensionEntry {
    <# Entfernt eine Extension-ID aus extensions.settings UND
       extensions.alerts einer Chromium-Prefs-Datei per Rohtext-Edit
       (funktioniert auch bei doppelt verKeys wie in Edge-Dateien,
       wo ConvertFrom/To-Json scheitert). Gibt $true bei Aenderung. #>
    param([Parameter(Mandatory)][string]$FilePath, [Parameter(Mandatory)][string]$ExtId)
    $raw = Read-SysPilotFileRaw -Path $FilePath
    if (-not $raw) { return $false }
    $new = $raw
    foreach ($sub in @('settings', 'alerts')) {
        # "extensions" kommt in Chromium-Prefs mehrfach vor
        # (account_values.extensions.ui, protection.macs.extensions) -
        # nur die Sektion mit dem jeweiligen Unter-Key ist die echte.
        $extSec = Find-SysPilotJsonSection -Json $new -Key 'extensions' -MustContain $sub
        if ($null -eq $extSec) { Write-SysPilotDebug "  PrefEdit $($FilePath | Split-Path -Leaf): extensions-Sektion fuer '$sub' nicht gefunden"; continue }
        $subSec = Find-SysPilotJsonSection -Json $extSec.Text -Key $sub
        if ($null -eq $subSec) { Write-SysPilotDebug "  PrefEdit $($FilePath | Split-Path -Leaf): '$sub'-Sektion nicht gefunden"; continue }
        $subNew = Remove-SysPilotJsonPropertyText -Json $subSec.Text -Key $ExtId
        if ($null -eq $subNew) { Write-SysPilotDebug "  PrefEdit $($FilePath | Split-Path -Leaf): ID $ExtId nicht in $sub"; continue }
        Write-SysPilotDebug "  PrefEdit $($FilePath | Split-Path -Leaf): ID $ExtId aus $sub entfernt"
        $innerNew = $extSec.Text.Substring(0, $subSec.Start) + $subNew + $extSec.Text.Substring($subSec.End)
        $new = $new.Substring(0, $extSec.Start) + $innerNew + $new.Substring($extSec.End)
    }
    if ($new -ne $raw) {
        Write-SysPilotFileRaw -Path $FilePath -Content $new | Out-Null
        return $true
    }
    return $false
}

function Test-SysPilotLaunchablePath {
    <# $true wenn der Pfad eine startbare Datei ist (.exe/.bat/.cmd/.com/
       .ps1/.lnk/.url/.msc/.reg). Verhindert, dass z.B. ein .ico- oder
       .png-DisplayIcon aus der Uninstall-Registry als "Programm" gestartet
       wird (Windows "Oeffnen mit"-Dialog). #>
    param([Parameter(Mandatory)][string]$Path)
    return ($Path -match '\.(exe|bat|cmd|com|ps1|lnk|url|msc|reg)$')
}

function Save-SysPilotUrlToFile {
    <# Lädt eine URL mit sichtbarem Fortschritt (Prozent + MB/s + ETA).
       Haengererkennung: wenn StallWarnSec lang keine Bytes ankommen,
       wird gewarnt und Abbruch (Q) oder Weiterwarten (Enter) angeboten.
       Gibt $true bei Erfolg zurück. #>
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile,
        [int]$TimeoutSec = 600,
        [int]$StallWarnSec = 60,
        [string]$Label = 'Download',
        [switch]$AllowAbort,
        [object]$ProgressQueue = $null
    )
    # HttpWebRequest + Stream-Read: zuverlaessiger als WebClient.
    # DownloadFileAsync hat bei manchen Hosts (z.B. live.sysinternals.com)
    #stillschweigend abgebrochen und eine halbe Datei als "Erfolg" geliefert.
    $req = $null; $resp = $null; $inStream = $null; $outStream = $null
    $total = 0L; $received = 0L
    $script:dlTotal = 0L; $script:dlReceived = 0L
    $canAbort = $AllowAbort -and (-not [Console]::IsInputRedirected)
    $aborted = $false
    try {
        $req = [Net.HttpWebRequest]::Create($Uri)
        $req.UserAgent = 'SysPilot/0.9'
        $req.Timeout = [Math]::Max(15000, $TimeoutSec * 1000)
        $req.ReadWriteTimeout = 60000
        $req.AllowAutoRedirect = $true
        $resp = $req.GetResponse()
        $total = [long]$resp.ContentLength
        if ($total -le 0) { $total = 0 }   # chunked -> unbekannt
        $script:dlTotal = $total
        $inStream = $resp.GetResponseStream()
        $outStream = [IO.File]::Create($OutFile)
        $buf = New-Object byte[] 262144
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $lastRecv = 0L; $lastGrow = Get-Date; $stallWarned = $false
        $lastUi = [datetime]::MinValue
        # Genau eine offene Read-Operation: Sie bleibt ueber die
        # 250ms-Slices hinweg bestehen (parallele Reads auf einem
        # Stream sind nicht erlaubt).
        $readTask = $null
        while ($true) {
            if ($null -eq $readTask) {
                $readTask = $inStream.ReadAsync($buf, 0, $buf.Length)
            }
            [void]$readTask.AsyncWaitHandle.WaitOne(250)
            if ($readTask.IsCompleted) {
                $n = $readTask.Result
                $readTask = $null
                if ($n -le 0) { break }   # EOF
                $outStream.Write($buf, 0, $n)
                $received += $n
                $script:dlReceived = $received
                $lastRecv = $received; $lastGrow = Get-Date; $stallWarned = $false
                Start-Sleep -Milliseconds 10   # kein Busy-Spin bei schnellen Downloads
            }
            # Fortschritt ~4x/s (jeder Schleifendurchlauf max ~250ms)
            if (((Get-Date) - $lastUi).TotalMilliseconds -gt 250) {
                $lastUi = Get-Date
                $r = $received; $t = $total
                $idle = ((Get-Date) - $lastGrow).TotalSeconds
                if ($t -gt 0) {
                    $pct = [math]::Min(100, [math]::Round($r * 100 / $t))
                    $mbR = [math]::Round($r / 1MB, 1); $mbT = [math]::Round($t / 1MB, 1)
                    $el = $sw.Elapsed.TotalSeconds
                    $spd = if ($el -gt 1) { [math]::Round($r / 1MB / $el, 1) } else { 0 }
                    $eta = ''
                    if ($spd -gt 0.05 -and $r -lt $t) { $eta = '  Rest ~' + [math]::Round(($t - $r) / 1MB / $spd) + 's' }
                    Write-Host ("`r  $Label : $pct%  ($mbR/$mbT MB, $spd MB/s)$eta   ") -NoNewline
                    if ($ProgressQueue) {
                        $ProgressQueue.Enqueue(@{ Pct=$pct; Recv=$r; Total=$t; MBR=$mbR; MBT=$mbT; MBS=$spd; Label=$Label })
                    }
                } else {
                    $mbR = [math]::Round($r / 1MB, 1)
                    Write-Host ("`r  $Label : $mbR MB geladen...   ") -NoNewline
                    if ($ProgressQueue) {
                        $ProgressQueue.Enqueue(@{ Pct=-1; Recv=$r; Total=0; MBR=$mbR; MBT=0; MBS=0; Label=$Label })
                    }
                }
                if ($idle -gt $StallWarnSec) {
                    if (-not $stallWarned) {
                        Write-Host "`n  ! Kein Fortschritt seit $([int]$idle)s - Download haengt moeglicherweise." -ForegroundColor Yellow
                        if ($canAbort) { Write-Host '    [Q] Abbrechen  [Enter] weiter warten' -ForegroundColor DarkYellow -NoNewline }
                        $stallWarned = $true
                    }
                    if ($canAbort -and [Console]::KeyAvailable) {
                        $k = [Console]::ReadKey($true).Key
                        if ($k -eq 'Q' -or $k -eq 'Escape') { $aborted = $true; break }
                        if ($k -eq 'Enter') { $lastGrow = Get-Date; $stallWarned = $false; Write-Host '' }
                    }
                }
                if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) { throw "Download-Timeout nach ${TimeoutSec}s" }
            }
        }
        Write-Host ''
        if ($aborted) {
            Write-Host "  [!] Download abgebrochen." -ForegroundColor Yellow
            if (Test-Path $OutFile) { Remove-Item $OutFile -Force -ErrorAction SilentlyContinue }
            return $false
        }
        if ($total -gt 0 -and $received -lt $total) {
            Write-Host "  [!] Download unvollstaendig ($received/$total Bytes)." -ForegroundColor Red
            if (Test-Path $OutFile) { Remove-Item $OutFile -Force -ErrorAction SilentlyContinue }
            return $false
        }
        return $true
    } catch {
        Write-Host ''
        Write-Host "  [!] Download fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Red
        if (Test-Path $OutFile) { Remove-Item $OutFile -Force -ErrorAction SilentlyContinue }
        return $false
    } finally {
        try { if ($inStream) { $inStream.Dispose() } } catch {}
        try { if ($outStream) { $outStream.Dispose() } } catch {}
        try { if ($resp) { $resp.Close() } } catch {}
        try { if ($req) { $req.Abort() } } catch {}
        if (Test-Path $OutFile) {
            $fi = Get-Item $OutFile
            if ($fi.Length -eq 0) { Remove-Item $OutFile -Force -ErrorAction SilentlyContinue }
        }
    }
}

# =====================================================================
# Download-Engine (FDM-inspiriert): Segment-Downloads, Torrent via aria2,
# Video via yt-dlp. Dispatch in Invoke-SysPilotSmartFileDownload.
# =====================================================================

function Get-SysPilotAria2Path {
    <# Sucht aria2c.exe: PATH, WinGet-Links, Programmordner, Scoop, Choco. #>
    $cmd = Get-Command aria2c.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $cands = @(
        "$env:LOCALAPPDATA\Microsoft\WinGet\Links\aria2c.exe",
        "${env:ProgramFiles}\aria2\aria2c.exe",
        "${env:ProgramFiles(x86)}\aria2\aria2c.exe",
        "$env:USERPROFILE\scoop\apps\aria2\current\aria2c.exe",
        "C:\ProgramData\chocolatey\bin\aria2c.exe",
        "C:\ProgramData\chocolatey\lib\aria2\tools\aria2c.exe"
    )
    foreach ($c in $cands) { if ($c -and (Test-Path $c)) { return $c } }
    # choco-Tools-Ordner (versionsnummeriert)
    $chocoLib = 'C:\ProgramData\chocolatey\lib\aria2\tools'
    if (Test-Path $chocoLib) {
        $hit = Get-ChildItem $chocoLib -Recurse -Filter aria2c.exe -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

function Get-SysPilotYtDlpPath {
    <# Sucht yt-dlp: PATH, WinGet-Links, pip-Scripts, Scoop. #>
    $cmd = Get-Command yt-dlp.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $cmd2 = Get-Command yt-dlp -ErrorAction SilentlyContinue
    if ($cmd2 -and $cmd2.Source -match '\.(exe|cmd|bat)$') { return $cmd2.Source }
    $cands = @(
        "$env:LOCALAPPDATA\Microsoft\WinGet\Links\yt-dlp.exe",
        "$env:USERPROFILE\scoop\apps\yt-dlp\current\yt-dlp.exe",
        "$env:APPDATA\Python\Python312\Scripts\yt-dlp.exe",
        "$env:APPDATA\Python\Python311\Scripts\yt-dlp.exe",
        "$env:APPDATA\Python\Python310\Scripts\yt-dlp.exe",
        "C:\ProgramData\chocolatey\bin\yt-dlp.exe"
    )
    foreach ($c in $cands) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}

function Resolve-SysPilotExePath {
    <# Normalisiert Get-Command (CommandInfo->.Source), Get-Item
       (FileInfo->.FullName) oder String zu einem exe-Pfad. #>
    param($Cmd)
    if (-not $Cmd) { return $null }
    if ($Cmd -is [string]) { return $Cmd }
    if ($Cmd -is [System.Management.Automation.CommandInfo]) { return [string]$Cmd.Source }
    if ($Cmd -is [IO.FileInfo]) { return $Cmd.FullName }
    if ($Cmd.PSObject.Properties['Source']) { return [string]$Cmd.Source }
    if ($Cmd.PSObject.Properties['FullName']) { return [string]$Cmd.FullName }
    return [string]$Cmd
}

function Get-SysPilotWingetExeLocal {
    <# winget.exe-Pfad (PATH, WindowsApps-Link, Store-Package). #>
    $w = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $w) {
        foreach ($wp in @("$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe","C:\Program Files\WindowsApps\*\winget.exe")) {
            if ($wp -match '\*') { $hit = Get-Item $wp -ErrorAction SilentlyContinue | Select-Object -First 1; if($hit){$w=$hit;break} }
            elseif (Test-Path $wp) { $w = Get-Item $wp; break }
        }
    }
    $p = Resolve-SysPilotExePath $w
    if ($p -and (Test-Path $p)) { return $p }
    return $null
}

function Install-SysPilotYtDlp {
    <# Installiert yt-dlp bei Bedarf (winget -> pip -> scoop).
       Idempotent - analog Install-SysPilotAria2. #>
    if (Get-SysPilotYtDlpPath) { return @{ Ok=$true; Error=''; Via='vorhanden' } }
    $tried = @()
    $wexe = Get-SysPilotWingetExeLocal
    if ($wexe) {
        $tried += 'winget'
        & $wexe install --id yt-dlp.yt-dlp --exact --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 | Out-Null
        if ((Get-SysPilotYtDlpPath)) { return @{ Ok=$true; Error=''; Via='winget' } }
    }
    $py = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($py) {
        $tried += 'pip'
        & python -m pip install -U yt-dlp 2>&1 | Out-Null
        if ((Get-SysPilotYtDlpPath)) { return @{ Ok=$true; Error=''; Via='pip' } }
    }
    $scoop = Get-Command scoop.cmd -ErrorAction SilentlyContinue
    if (-not $scoop -and (Test-Path "$env:USERPROFILE\scoop\shims\scoop.cmd")) { $scoop = Get-Item "$env:USERPROFILE\scoop\shims\scoop.cmd" }
    $sexe = Resolve-SysPilotExePath $scoop
    if ($sexe -and (Test-Path $sexe)) {
        $tried += 'scoop'
        & $sexe install yt-dlp 2>&1 | Out-Null
        if ((Get-SysPilotYtDlpPath)) { return @{ Ok=$true; Error=''; Via='scoop' } }
    }
    return @{ Ok=$false; Error=("yt-dlp nicht installierbar (versucht: " + ($tried -join ', ') + ").") }
}

function Get-SysPilotFfmpegPath {
    <# Sucht ffmpeg.exe (PATH, WinGet-Links, gyan.dev-Ordner, Scoop, Choco). #>
    $cmd = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $cands = @(
        "$env:LOCALAPPDATA\Microsoft\WinGet\Links\ffmpeg.exe",
        "$env:USERPROFILE\scoop\apps\ffmpeg\current\bin\ffmpeg.exe",
        "C:\ProgramData\chocolatey\bin\ffmpeg.exe"
    )
    foreach ($c in $cands) { if ($c -and (Test-Path $c)) { return $c } }
    # gyan.dev-Style: ffmpeg-*-essentials_build/bin
    $gyan = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages"
    if (Test-Path $gyan) {
        $hit = Get-ChildItem $gyan -Recurse -Filter 'ffmpeg.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

function Install-SysPilotFfmpeg {
    <# Installiert ffmpeg (fuer yt-dlp-Merges, Video-Processing).
       winget 'Gyan.FFmpeg' -> scoop. Idempotent. #>
    if (Get-SysPilotFfmpegPath) { return @{ Ok=$true; Error=''; Via='vorhanden' } }
    $tried = @()
    $wexe = Get-SysPilotWingetExeLocal
    if ($wexe) {
        $tried += 'winget'
        & $wexe install --id Gyan.FFmpeg --exact --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 | Out-Null
        if ((Get-SysPilotFfmpegPath)) { return @{ Ok=$true; Error=''; Via='winget' } }
    }
    $scoop = Get-Command scoop.cmd -ErrorAction SilentlyContinue
    if (-not $scoop -and (Test-Path "$env:USERPROFILE\scoop\shims\scoop.cmd")) { $scoop = Get-Item "$env:USERPROFILE\scoop\shims\scoop.cmd" }
    $sexe = Resolve-SysPilotExePath $scoop
    if ($sexe -and (Test-Path $sexe)) {
        $tried += 'scoop'
        & $sexe install ffmpeg 2>&1 | Out-Null
        if ((Get-SysPilotFfmpegPath)) { return @{ Ok=$true; Error=''; Via='scoop' } }
    }
    return @{ Ok=$false; Error=("ffmpeg nicht installierbar (versucht: " + ($tried -join ', ') + ").") }
}

function Install-SysPilotAria2 {
    <# Installiert aria2 bei Bedarf ueber den ersten verfuegbaren
       Paketmanager (winget -> choco -> scoop). Idempotent. #>
    if (Get-SysPilotAria2Path) { return @{ Ok=$true; Error=''; Via='vorhanden' } }
    $tried = @()
    # CommandInfo (Get-Command -> .Source), FileInfo (Get-Item -> .FullName), string
    $resolve = { param($c)
        if (-not $c) { return $null }
        if ($c -is [string]) { return $c }
        if ($c -is [System.Management.Automation.CommandInfo]) { return [string]$c.Source }
        if ($c -is [IO.FileInfo]) { return $c.FullName }
        if ($c.PSObject.Properties['Source']) { return [string]$c.Source }
        if ($c.PSObject.Properties['FullName']) { return [string]$c.FullName }
        return [string]$c
    }
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) {
        foreach ($wp in @("$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe","C:\Program Files\WindowsApps\*\winget.exe")) {
            if ($wp -match '\*') { $hit = Get-Item $wp -ErrorAction SilentlyContinue | Select-Object -First 1; if($hit){$winget=$hit;break} }
            elseif (Test-Path $wp) { $winget = Get-Item $wp; break }
        }
    }
    $wexe = & $resolve $winget
    if ($wexe -and (Test-Path $wexe)) {
        $tried += 'winget'
        & $wexe install --id aria2.aria2 --exact --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 | Out-Null
        if ((Get-SysPilotAria2Path)) { return @{ Ok=$true; Error=''; Via='winget' } }
    }
    $choco = Get-Command choco.exe -ErrorAction SilentlyContinue
    if (-not $choco -and (Test-Path 'C:\ProgramData\chocolatey\bin\choco.exe')) { $choco = Get-Item 'C:\ProgramData\chocolatey\bin\choco.exe' }
    $cexe = & $resolve $choco
    if ($cexe -and (Test-Path $cexe)) {
        $tried += 'choco'
        if (Test-SysPilotAdmin) {
            & $cexe install aria2 -y --no-progress 2>&1 | Out-Null
        } else {
            $p = Start-Process $cexe -ArgumentList 'install aria2 -y --no-progress' -Verb RunAs -PassThru -Wait
        }
        if ((Get-SysPilotAria2Path)) { return @{ Ok=$true; Error=''; Via='choco' } }
    }
    $scoop = Get-Command scoop.cmd -ErrorAction SilentlyContinue
    if (-not $scoop -and (Test-Path "$env:USERPROFILE\scoop\shims\scoop.cmd")) { $scoop = Get-Item "$env:USERPROFILE\scoop\shims\scoop.cmd" }
    $sexe = & $resolve $scoop
    if ($sexe -and (Test-Path $sexe)) {
        $tried += 'scoop'
        & $sexe install aria2 2>&1 | Out-Null
        if ((Get-SysPilotAria2Path)) { return @{ Ok=$true; Error=''; Via='scoop' } }
    }
    return @{ Ok=$false; Error=("aria2 nicht installierbar (versucht: " + ($tried -join ', ') + "). Bitte manuell installieren.") }
}

function Test-SysPilotRangeSupport {
    <# HEAD-Probe (GET-Fallback): liefert Groesse, Accept-Ranges,
       finale URL und Content-Type. #>
    param([Parameter(Mandatory)][string]$Uri, [int]$TimeoutSec = 30)
    $r = @{ Ok=$false; Size=0L; AcceptRanges=''; FinalUrl=''; ContentType=''; Error='' }
    $req = $null; $resp = $null
    try {
        foreach ($method in @('HEAD','GET')) {
            try {
                $req = [Net.HttpWebRequest]::Create($Uri)
                $req.UserAgent = 'SysPilot/0.9'
                $req.Method = $method
                $req.Timeout = $TimeoutSec * 1000
                $req.ReadWriteTimeout = $TimeoutSec * 1000
                $req.AllowAutoRedirect = $true
                if ($method -eq 'GET') { $req.AddRange(0,0) }
                $resp = $req.GetResponse()
                $r.FinalUrl = $resp.ResponseUri.AbsoluteUri
                $r.ContentType = [string]$resp.ContentType
                $len = $resp.ContentLength
                if ($len -gt 0) { $r.Size = [long]$len }
                $ar = $resp.Headers['Accept-Ranges']
                if ($ar) { $r.AcceptRanges = [string]$ar }
                # GET mit Range 0-0: Laenge ist 1, echte Groesse aus
                # Content-Range parsen
                if ($method -eq 'GET') {
                    $cr = $resp.Headers['Content-Range']
                    if ($cr -match '/(\d+)\s*$') { $r.Size = [long]$Matches[1] }
                    elseif ($len -gt 1) { $r.Size = [long]$len }
                }
                $r.Ok = $true
                break
            } catch {
                $r.Error = $_.Exception.Message
                try { if ($resp) { $resp.Close() } } catch {}
                try { if ($req) { $req.Abort() } } catch {}
                $resp = $null; $req = $null
            }
        }
    } finally {
        try { if ($resp) { $resp.Close() } } catch {}
        try { if ($req) { $req.Abort() } } catch {}
    }
    return $r
}

function Convert-SysPilotSizeStr {
    <# '12.3MiB'/'5KB' -> Bytes (long). #>
    param([Parameter(Mandatory)][string]$S)
    if ($S -match '([\d.]+)\s*([KMGT]i?B)', 'IgnoreCase') {
        $v = [double]$Matches[1]
        switch ($Matches[2].ToUpper()) {
            'B'   { return [long]$v }
            'KB'  { return [long]($v * 1KB) }
            'MB'  { return [long]($v * 1MB) }
            'GB'  { return [long]($v * 1GB) }
            'TB'  { return [long]($v * 1TB) }
            'KIB' { return [long]($v * 1KB) }
            'MIB' { return [long]($v * 1MB) }
            'GIB' { return [long]($v * 1GB) }
            'TIB' { return [long]($v * 1TB) }
        }
    }
    return 0L
}

function Invoke-SysPilotSegmentedDownload {
    <# Paralleler Segment-Download (FDM-Stil): HTTP Range-Requests auf
       N Runspaces, jede schreibt eine .part-Datei; danach Merge.
       Resume-faehig ueber $OutFile.sysparts\meta.json - fertige Segmente
       werden uebersprungen. Fallback: Save-SysPilotUrlToFile (Single).
       Gibt $true/$false zurueck. #>
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile,
        [int]$Segments = 8,
        [int]$TimeoutSec = 900,
        [int]$StallWarnSec = 90,
        [string]$Label = 'Download',
        [object]$ProgressQueue = $null
    )
    # Probe: Range-Unterstuetzung noetig
    $probe = Test-SysPilotRangeSupport -Uri $Uri -TimeoutSec 30
    if (-not $probe.Ok -or $probe.Size -le 0) {
        Write-Host "  Range-Probe fehlgeschlagen ($($probe.Error)) - Single-Stream-Fallback." -ForegroundColor DarkYellow
        return Save-SysPilotUrlToFile -Uri $Uri -OutFile $OutFile -TimeoutSec $TimeoutSec -Label $Label -ProgressQueue $ProgressQueue
    }
    $total = $probe.Size
    $supportsRange = ($probe.AcceptRanges -match 'bytes') -or ($probe.FinalUrl -ne $Uri)
    # Server ohne AcceptRanges explizit: trotzdem Segment-Versuch wenn
    # Content-Range bei Probe kam (methode GET) - sonst Single.
    if ($probe.AcceptRanges -notmatch 'bytes' -and $probe.AcceptRanges -ne '') {
        Write-Host "  Hinweis: Server meldet kein 'Accept-Ranges: bytes' - Single-Stream." -ForegroundColor DarkYellow
        return Save-SysPilotUrlToFile -Uri $Uri -OutFile $OutFile -TimeoutSec $TimeoutSec -Label $Label -ProgressQueue $ProgressQueue
    }
    if ($total -lt 4MB -or $Segments -le 1) {
        return Save-SysPilotUrlToFile -Uri $Uri -OutFile $OutFile -TimeoutSec $TimeoutSec -Label $Label -ProgressQueue $ProgressQueue
    }
    $n = [Math]::Min($Segments, [Math]::Max(2, [int][Math]::Ceiling($total / 16MB)))
    $partDir = "$OutFile.sysparts"
    if (-not (Test-Path $partDir)) { New-Item -ItemType Directory -Force -Path $partDir | Out-Null }
    $metaPath = Join-Path $partDir 'meta.json'
    $meta = @{ Url=$Uri; Size=$total; Parts=@() }
    if (Test-Path $metaPath) {
        try { $old = Get-Content $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json; if ($old.Size -eq $total -and $old.Url -eq $Uri) { $meta.Parts = @($old.Parts) } } catch {}
    }
    # Segment-Grenzen
    $segLen = [Math]::Ceiling($total / $n)
    $segs = @()
    for ($i = 0; $i -lt $n; $i++) {
        $st = $i * $segLen; $en = [Math]::Min($total - 1, ($i + 1) * $segLen - 1)
        if ($st -gt $en) { break }
        $pf = Join-Path $partDir ("seg_{0:d3}.part" -f $i)
        $want = $en - $st + 1
        $have = 0L
        if (Test-Path $pf) {
            $have = (Get-Item $pf).Length
            if ($have -gt $want) {
                # Defekte/ueberlange Part-Datei (z.B. alter Run ohne korrekten
                # Range-Header) - verwerfen statt als fertig zu zaehlen.
                Remove-Item $pf -Force -ErrorAction SilentlyContinue
                $have = 0L
            }
        }
        $segs += @{ I=$i; Start=$st; End=$en; Want=$want; Have=$have; File=$pf; Done=($have -ge $want) }
    }
    $nActive = @($segs | Where-Object { -not $_.Done }).Count
    $doneCount = $n - $nActive
    Write-Host "  Segment-Download: $n Segmente à $([math]::Round($segLen/1MB,1)) MB ($([math]::Round($total/1MB,1)) MB gesamt, $nActive offen, $doneCount fertig)." -ForegroundColor Cyan
    if ($ProgressQueue) { $ProgressQueue.Enqueue(@{ Pct=0; Recv=0; Total=$total; MBR=0; MBT=[math]::Round($total/1MB,1); MBS=0; Label=$Label; Segs="$doneCount/$n"; Note='Segmente werden vorbereitet' }) }

    # Worker-Skript (eigener Runspace, kein Modul noetig)
    $workerCode = @'
param($u,$st,$en,$pf,$pq,$ua,$to,$si)
$req=$null;$resp=$null;$ins=$null;$outs=$null
$attempt = 0
try {
    $want = $en - $st + 1
    while ($true) {
        $have = 0L
        if (Test-Path $pf) {
            $have = (Get-Item $pf).Length
            if ($have -gt $want) { Remove-Item $pf -Force -ErrorAction SilentlyContinue; $have = 0L }
        }
        if ($have -ge $want) { break }
        $attempt++
        if ($attempt -gt 6) { throw "Segment ${si}: 6 Versuche fehlgeschlagen (letzter Stand $have/$want Bytes)" }
        try {
            $req = [Net.HttpWebRequest]::Create($u)
            $req.UserAgent = $ua; $req.Timeout = 20000; $req.ReadWriteTimeout = 90000
            $req.AllowAutoRedirect = $true
            # WICHTIG: [long]-Cast noetig - Double-Argumente binden an die
            # AddRange(string,int,int)-Ueberladung und erzeugen einen
            # ungueltigen Range-Header ('13269152=26538303-'), den Server
            # ignoriert -> voller Download pro Segment.
            $req.AddRange([long]($st + $have), [long]$en)
            $resp = $req.GetResponse()
            $ins = $resp.GetResponseStream()
            $outs = [IO.File]::Open($pf, 'OpenOrCreate', 'Write', 'ReadWrite')
            $outs.Seek(0, 'End') | Out-Null
            $buf = New-Object byte[] 131072
            $recv = $have
            $sw = [Diagnostics.Stopwatch]::StartNew(); $lastUi = [datetime]::MinValue
            $readTask = $null
            while ($true) {
                if ($null -eq $readTask) { $readTask = $ins.ReadAsync($buf, 0, $buf.Length) }
                [void]$readTask.AsyncWaitHandle.WaitOne(400)
                if ($readTask.IsCompleted) {
                    $rd = $readTask.Result
                    $readTask = $null
                    if ($rd -le 0) { break }
                    $outs.Write($buf, 0, $rd)
                    $recv += $rd
                    if (((Get-Date) - $lastUi).TotalMilliseconds -gt 250) {
                        $lastUi = Get-Date
                        if ($pq) { $pq.Enqueue(@{ Seg=$si; Recv=$recv; Total=$want; Done=$false }) }
                    }
                }
                if ($sw.Elapsed.TotalSeconds -gt $to) { throw "Segment-Timeout" }
            }
            $outs.Flush()
            try { $ins.Dispose() } catch {}; $ins=$null
            try { $outs.Dispose() } catch {}; $outs=$null
            try { $resp.Close() } catch {}; $resp=$null
            try { $req.Abort() } catch {}; $req=$null
            # Kompletter Segment-Durchlauf ohne Exception -> naechster Versuch
            # nur noetig wenn die Datei noch nicht vollstaendig ist
            if (((Get-Item $pf).Length) -ge $want) { break }
            Start-Sleep -Seconds 2
        } catch {
            try { if ($ins) { $ins.Dispose() } } catch {}; $ins=$null
            try { if ($outs) { $outs.Flush(); $outs.Dispose() } } catch {}; $outs=$null
            try { if ($resp) { $resp.Close() } } catch {}; $resp=$null
            try { if ($req) { $req.Abort() } } catch {}; $req=$null
            if ($attempt -ge 6) { throw }
            Start-Sleep -Seconds (2 * $attempt)
        }
    }
    if ($pq) { $pq.Enqueue(@{ Seg=$si; Recv=$want; Total=$want; Done=$true }) }
    return @{ Ok=$true; Seg=$si; Recv=$want; Err='' }
} catch {
    if ($pq) { try { $pq.Enqueue(@{ Seg=$si; Recv=0; Total=0; Done=$true; Err=$_.Exception.Message }) } catch {} }
    return @{ Ok=$false; Seg=$si; Recv=0; Err=$_.Exception.Message }
} finally {
    try { if ($ins) { $ins.Dispose() } } catch {}
    try { if ($outs) { $outs.Dispose() } } catch {}
    try { if ($resp) { $resp.Close() } } catch {}
    try { if ($req) { $req.Abort() } } catch {}
}
'@

    $psList = @(); $rsList = @(); $segQ = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $segRecv = @{}; $segDone = @{}; $segErr = @{}
    foreach ($sg in $segs) {
        $segRecv[$sg.I] = $sg.Have; $segDone[$sg.I] = $sg.Done; $segErr[$sg.I] = ''
        if ($sg.Done) { continue }
        $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState='MTA'; $rs.Open()
        $wp = [powershell]::Create(); $wp.Runspace = $rs
        [void]$wp.AddScript($workerCode)
        [void]$wp.AddArgument($Uri); [void]$wp.AddArgument($sg.Start); [void]$wp.AddArgument($sg.End)
        [void]$wp.AddArgument($sg.File); [void]$wp.AddArgument($segQ); [void]$wp.AddArgument('SysPilot/0.9')
        [void]$wp.AddArgument($TimeoutSec); [void]$wp.AddArgument($sg.I)
        $h = $wp.BeginInvoke()
        $psList += @{ PS=$wp; Handle=$h; Seg=$sg.I }
        $rsList += $rs
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $lastGrow = Get-Date; $lastRecvSum = 0L; $stallWarned = $false
    $lastUi = [datetime]::MinValue; $sw = [Diagnostics.Stopwatch]::StartNew()
    $okAll = $true
    try {
        while ($true) {
            # Worker-Meldungen einsammeln
            $m = $null
            while ($segQ.TryDequeue([ref]$m)) {
                if ($null -eq $m) { continue }
                if ($m.Contains('Done') -and $m.Done) {
                    if ($m.Err) { $segErr[$m.Seg] = [string]$m.Err; $okAll = $false }
                    $segDone[$m.Seg] = $true; $segRecv[$m.Seg] = [long]$m.Recv
                } else {
                    $segRecv[$m.Seg] = [long]$m.Recv
                    $lastGrow = Get-Date; $stallWarned = $false
                }
            }
            $doneNow = 0; $recvSum = 0L
            foreach ($sg in $segs) { if ($segDone[$sg.I]) { $doneNow++ }; $recvSum += [long]$segRecv[$sg.I] }
            # abgeschlossen?
            $allDone = $true
            foreach ($sg in $segs) { if (-not $segDone[$sg.I]) { $allDone = $false; break } }
            if ($allDone) { break }
            if ((Get-Date) -gt $deadline) { throw "Segment-Download Timeout nach ${TimeoutSec}s" }
            $idle = ((Get-Date) - $lastGrow).TotalSeconds
            if ($idle -gt $StallWarnSec -and -not $stallWarned) {
                Write-Host "`n  ! Segment-Download: kein Fortschritt seit $([int]$idle)s." -ForegroundColor Yellow
                $stallWarned = $true
            }
            # UI ~4x/s
            if (((Get-Date) - $lastUi).TotalMilliseconds -gt 250) {
                $lastUi = Get-Date
                $pct = if ($total -gt 0) { [math]::Min(100, [math]::Round($recvSum * 100 / $total)) } else { -1 }
                $mbR = [math]::Round($recvSum / 1MB, 1); $mbT = [math]::Round($total / 1MB, 1)
                $el = $sw.Elapsed.TotalSeconds
                $spd = if ($el -gt 1) { [math]::Round(($recvSum - $lastRecvSum) / 1MB / 0.25, 1) } else { 0 }
                $spdAvg = if ($el -gt 1) { [math]::Round($recvSum / 1MB / $el, 1) } else { 0 }
                $lastRecvSum = $recvSum
                $eta = ''
                if ($spdAvg -gt 0.05 -and $recvSum -lt $total) { $eta = '  Rest ~' + [math]::Round(($total - $recvSum) / 1MB / $spdAvg) + 's' }
                Write-Host ("`r  $Label : $pct%  ($mbR/$mbT MB, $spdAvg MB/s, $doneNow/$($segs.Count) Segmente)$eta   ") -NoNewline
                if ($ProgressQueue) {
                    $ProgressQueue.Enqueue(@{ Pct=$pct; Recv=$recvSum; Total=$total; MBR=$mbR; MBT=$mbT; MBS=$spdAvg; Label=$Label; Segs="$doneNow/$($segs.Count)" })
                }
            }
            Start-Sleep -Milliseconds 60
        }
    } catch {
        $okAll = $false
        Write-Host ''
        Write-Host "  [!] $($_.Exception.Message)" -ForegroundColor Red
    } finally {
        foreach ($p in $psList) {
            try { if (-not $p.Handle.IsCompleted) { $p.PS.Stop() } } catch {}
            try { $p.PS.EndInvoke($p.Handle) | Out-Null } catch {}
            try { $p.PS.Dispose() } catch {}
        }
        foreach ($r in $rsList) { try { $r.Close(); $r.Dispose() } catch {} }
    }
    Write-Host ''
    if (-not $okAll) {
        $errs = @($segs | Where-Object { $segErr[$_.I] } | ForEach-Object { "Seg $($_.I): $($segErr[$_.I])" })
        Write-Host ("  [!] Segment-Download fehlgeschlagen: " + ($errs -join ' | ')) -ForegroundColor Red
        Write-Host "  Segment-Daten bleiben in $partDir (Resume beim naechsten Versuch)." -ForegroundColor DarkYellow
        if ($ProgressQueue) { $ProgressQueue.Enqueue(@{ Pct=-2; Recv=0; Total=$total; MBR=0; MBT=[math]::Round($total/1MB,1); MBS=0; Label=$Label; Note='fehlgeschlagen - Resume moeglich' }) }
        return $false
    }
    # Merge
    Write-Host "  Merge: $($segs.Count) Segmente -> $OutFile ..." -ForegroundColor DarkCyan
    try {
        $fsOut = [IO.File]::Create($OutFile)
        $buf = New-Object byte[] 1048576
        foreach ($sg in $segs) {
            $fsIn = [IO.File]::OpenRead($sg.File)
            try {
                while (($n = $fsIn.Read($buf, 0, $buf.Length)) -gt 0) { $fsOut.Write($buf, 0, $n) }
            } finally { $fsIn.Dispose() }
        }
        $fsOut.Flush(); $fsOut.Dispose()
        $fi = Get-Item $OutFile
        if ($fi.Length -ne $total) {
            Write-Host "  [!] Groesse stimmt nicht ($($fi.Length)/$total Bytes)." -ForegroundColor Red
            Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
            return $false
        }
        Remove-Item $partDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  [OK] $Label : $([math]::Round($total/1MB,1)) MB in $([math]::Round($sw.Elapsed.TotalSeconds,1))s" -ForegroundColor Green
        if ($ProgressQueue) { $ProgressQueue.Enqueue(@{ Pct=100; Recv=$total; Total=$total; MBR=[math]::Round($total/1MB,1); MBT=[math]::Round($total/1MB,1); MBS=0; Label=$Label; Segs='fertig' }) }
        return $true
    } catch {
        Write-Host "  [!] Merge fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Red
        try { if ($fsOut) { $fsOut.Dispose() } } catch {}
        return $false
    }
}

function Invoke-SysPilotAria2Download {
    <# HTTP(S)-Download ueber aria2c (Multi-Connection, Resume, Metalink).
       Parse der periodischen Fortschrittszeilen im stdout-Log.
       Rueckgabe: @{Ok;Path;Error} oder $null wenn aria2 fehlt. #>
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile,
        [string]$Label = 'Download',
        [int]$TimeoutSec = 900,
        [object]$ProgressQueue = $null,
        [string[]]$ExtraArgs = @()
    )
    $aria = Get-SysPilotAria2Path
    if (-not $aria) { return $null }
    $outDir = Split-Path $OutFile -Parent
    if (-not $outDir) { $outDir = '.' }
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
    $outName = Split-Path $OutFile -Leaf
    $logFile = Join-Path $env:TEMP ("syspilot-aria2-{0}.log" -f [Guid]::NewGuid().ToString('N'))
    $errFile = "$logFile.err"
    $argList = @(
        '-x','8','-s','8','-k','1M','--file-allocation=none','--continue=true',
        '--auto-file-renaming=false','--allow-overwrite=true','--summary-interval=1',
        '--max-tries=0','--retry-wait=3','--connect-timeout=20','--timeout=60',
        '-d',"`"$outDir`"",'-o',"`"$outName`""
    ) + $ExtraArgs + @("`"$Uri`"")
    Write-Host "  aria2: $outName ($([math]::Round((Get-Item $OutFile -ErrorAction SilentlyContinue).Length/1MB,1)) MB Ziel) ..." -ForegroundColor DarkCyan
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $aria
    $psi.Arguments = ($argList -join ' ')
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $proc = New-Object Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    # stdout async in Datei schreiben (aria2 progress geht auf stdout)
    $outFs = [IO.File]::Create($logFile)
    $copyOut = $proc.StandardOutput.BaseStream.CopyToAsync($outFs)
    $errFs = [IO.File]::Create($errFile)
    $copyErr = $proc.StandardError.BaseStream.CopyToAsync($errFs)
    $sw = [Diagnostics.Stopwatch]::StartNew(); $lastUi=[datetime]::MinValue
    $lastPct = -1; $lastGrow = Get-Date; $stallWarned=$false
    $res = @{ Ok=$false; Path=$null; Error='' }
    try {
        while (-not $proc.HasExited) {
            Start-Sleep -Milliseconds 400
            # Fortschritt aus Log parsen
            if (Test-Path $logFile) {
                $tail = Read-SysPilotFileTailLine -Path $logFile -MaxChars 400
                if ($tail -match '\((\d+)%\)') {
                    $pct = [int]$Matches[1]
                    $lastPct = $pct
                    if (((Get-Date) - $lastUi).TotalMilliseconds -gt 300) {
                        $lastUi = Get-Date
                        $mbT = [math]::Round(((Get-Item $OutFile -ErrorAction SilentlyContinue).Length)/1MB,1)
                        Write-Host ("`r  $Label : $pct%  (aria2, $mbT MB)   ") -NoNewline
                        if ($ProgressQueue) {
                            $ProgressQueue.Enqueue(@{ Pct=$pct; Recv=0; Total=0; MBR=$mbT; MBT=0; MBS=0; Label=$Label; Note='aria2 Multi-Connection' })
                        }
                    }
                }
            }
            if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) { throw "aria2-Timeout nach ${TimeoutSec}s" }
            $fsize = 0L
            foreach ($cand in @($OutFile, "$OutFile.aria2")) {
                if (Test-Path $cand) { $fsize = [Math]::Max($fsize, (Get-Item $cand).Length) }
            }
            if ($fsize -gt 0) { $lastGrow = Get-Date }
        }
        try { $copyOut.Wait(3000) | Out-Null; $copyErr.Wait(3000) | Out-Null } catch {}
        try { $outFs.Flush(); $outFs.Dispose(); $errFs.Flush(); $errFs.Dispose() } catch {}
        $code = $proc.ExitCode
        if ($code -eq 0 -and (Test-Path $OutFile) -and ((Get-Item $OutFile).Length -gt 0)) {
            $res.Ok = $true; $res.Path = $OutFile
            Write-Host ''
            Write-Host "  [OK] $Label : aria2 fertig" -ForegroundColor Green
        } else {
            $tailErr = ''
            if (Test-Path $errFile) { $tailErr = (Read-SysPilotFileTailLine -Path $errFile -MaxChars 200) }
            $res.Error = "aria2 exit $code $tailErr"
            Write-Host ''
            Write-Host "  [!] aria2 fehlgeschlagen (exit $code): $tailErr" -ForegroundColor Red
        }
    } catch {
        try { $proc.Kill() } catch {}
        $res.Error = $_.Exception.Message
        Write-Host ''
        Write-Host "  [!] $($res.Error)" -ForegroundColor Red
    } finally {
        try { $proc.Dispose() } catch {}
        try { if ($outFs) { $outFs.Dispose() } } catch {}
        try { if ($errFs) { $errFs.Dispose() } } catch {}
    }
    return $res
}

function Invoke-SysPilotTorrentDownload {
    <# Torrent/Magnet-Download via aria2 (libtorrent-Engine, DHT,
       Magnet-Resolver). Braucht aria2c - wird bei Bedarf automatisch
       installiert (winget/choco/scoop). Output = Ordner (Torrent kann
       mehrere Dateien liefern). Rueckgabe: @{Ok;Dir;Error;Installed}. #>
    param(
        [Parameter(Mandatory)][string]$Source,   # magnet:... oder .torrent-Pfad/URL
        [Parameter(Mandatory)][string]$OutDir,
        [string]$Label = 'Torrent',
        [int]$TimeoutSec = 0,                      # 0 = unbegrenzt (Seeds brauchen Zeit)
        [object]$ProgressQueue = $null
    )
    $res = @{ Ok=$false; Dir=$OutDir; Error=''; Installed=$false }
    $aria = Get-SysPilotAria2Path
    if (-not $aria) {
        Write-Host "  aria2 fehlt - Installation wird versucht (winget/choco/scoop) ..." -ForegroundColor Yellow
        $inst = Install-SysPilotAria2
        if (-not $inst.Ok) { $res.Error = $inst.Error; return $res }
        $res.Installed = $true
        Write-Host "  [OK] aria2 installiert via $($inst.Via)." -ForegroundColor Green
        $aria = Get-SysPilotAria2Path
    }
    if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
    $logFile = Join-Path $env:TEMP ("syspilot-torrent-{0}.log" -f [Guid]::NewGuid().ToString('N'))
    $errFile = "$logFile.err"
    $argList = @(
        '-x','8','-s','8','--file-allocation=none','--continue=true',
        '--seed-time=0','--summary-interval=2','--max-tries=0','--retry-wait=5',
        '--bt-enable-lpd=true','--enable-dht=true','--enable-peer-exchange=true',
        '-d',"`"$OutDir`""
    ) + @("`"$Source`"")
    Write-Host "  Torrent-Download via aria2 -> $OutDir" -ForegroundColor DarkCyan
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $aria; $psi.Arguments = ($argList -join ' ')
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $proc = New-Object Diagnostics.Process; $proc.StartInfo = $psi
    [void]$proc.Start()
    $outFs = [IO.File]::Create($logFile); $copyOut = $proc.StandardOutput.BaseStream.CopyToAsync($outFs)
    $errFs = [IO.File]::Create($errFile);   $copyErr = $proc.StandardError.BaseStream.CopyToAsync($errFs)
    $sw = [Diagnostics.Stopwatch]::StartNew(); $lastUi=[datetime]::MinValue
    $lastGrow = Get-Date; $stallWarned=$false
    try {
        while (-not $proc.HasExited) {
            Start-Sleep -Milliseconds 700
            if (Test-Path $logFile) {
                $tail = Read-SysPilotFileTailLine -Path $logFile -MaxChars 400
                if ($tail -match '\((\d+)%\)') {
                    $pct = [int]$Matches[1]
                    if (((Get-Date) - $lastUi).TotalMilliseconds -gt 500) {
                        $lastUi = Get-Date
                        $dl = [math]::Round($sw.Elapsed.TotalSeconds)
                        Write-Host ("`r  $Label : $pct%  (aria2 BT, ${dl}s)   ") -NoNewline
                        if ($ProgressQueue) { $ProgressQueue.Enqueue(@{ Pct=$pct; Recv=0; Total=0; MBR=0; MBT=0; MBS=0; Label=$Label; Note="Torrent $pct% (${dl}s)" }) }
                    }
                } elseif ($tail -match 'Download complete|download completed') {
                    if (((Get-Date) - $lastUi).TotalMilliseconds -gt 500) {
                        $lastUi = Get-Date
                        Write-Host ("`r  $Label : Download abgeschlossen ...   ") -NoNewline
                    }
                }
            }
            # Wachstums-Check: Irgendwas im OutDir groesser geworden?
            $sz = 0L
            try { $sz = (Get-ChildItem $OutDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum } catch {}
            if ($sz -gt 0) { $lastGrow = Get-Date; $stallWarned=$false }
            if ($TimeoutSec -gt 0 -and $sw.Elapsed.TotalSeconds -gt $TimeoutSec) { throw "Torrent-Timeout nach ${TimeoutSec}s" }
            $idle = ((Get-Date) - $lastGrow).TotalSeconds
            if ($idle -gt 300 -and -not $stallWarned) {
                Write-Host "`n  ! Torrent: seit $([int]($idle/60)) Min kein Byte-Wachstum (Peers/Seeds?)." -ForegroundColor Yellow
                $stallWarned = $true
            }
        }
        try { $copyOut.Wait(3000)|Out-Null; $copyErr.Wait(3000)|Out-Null } catch {}
        try { $outFs.Flush();$outFs.Dispose();$errFs.Flush();$errFs.Dispose() } catch {}
        if ($proc.ExitCode -eq 0) {
            $res.Ok = $true
            Write-Host ''
            Write-Host "  [OK] $Label : Torrent-Download abgeschlossen -> $OutDir" -ForegroundColor Green
        } else {
            $tailErr=''; if(Test-Path $errFile){$tailErr=Read-SysPilotFileTailLine -Path $errFile -MaxChars 200}
            $res.Error = "aria2 exit $($proc.ExitCode) $tailErr"
            Write-Host ''
            Write-Host "  [!] Torrent fehlgeschlagen: $($res.Error)" -ForegroundColor Red
        }
    } catch {
        try { $proc.Kill() } catch {}
        $res.Error = $_.Exception.Message
        Write-Host ''
        Write-Host "  [!] $($res.Error)" -ForegroundColor Red
    } finally {
        try { $proc.Dispose() } catch {}
        try { if ($outFs) { $outFs.Dispose() } } catch {}
        try { if ($errFs) { $errFs.Dispose() } } catch {}
    }
    return $res
}

function Invoke-SysPilotVideoDownload {
    <# Video-Download via yt-dlp (YouTube & Co., HLS/DASH). Installiert
       yt-dlp bei Bedarf (winget 'yt-dlp.yt-dlp' / pip / scoop).
       Rueckgabe: @{Ok;Path;Error;Installed}. #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$OutDir,
        [string]$Label = 'Video',
        [object]$ProgressQueue = $null
    )
    $res = @{ Ok=$false; Path=$null; Error=''; Installed=$false }
    $ytdlp = Get-SysPilotYtDlpPath
    if (-not $ytdlp) {
        Write-Host "  yt-dlp fehlt - Installation wird versucht ..." -ForegroundColor Yellow
        $inst = Install-SysPilotYtDlp
        if (-not $inst.Ok) { $res.Error = $inst.Error; return $res }
        $res.Installed = ($inst.Via -ne 'vorhanden')
        if ($res.Installed) { Write-Host "  [OK] yt-dlp installiert via $($inst.Via)." -ForegroundColor Green }
        $ytdlp = Get-SysPilotYtDlpPath
        if (-not $ytdlp) { $res.Error = 'yt-dlp installiert, aber nicht im PATH'; return $res }
    }
    if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
    $tpl = Join-Path $OutDir '%(title).80s.%(ext)s'
    Write-Host "  Video-Download via yt-dlp -> $OutDir" -ForegroundColor DarkCyan
    $logFile = Join-Path $env:TEMP ("syspilot-ytdlp-{0}.log" -f [Guid]::NewGuid().ToString('N'))
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $ytdlp
    $psi.Arguments = "--newline --progress --no-playlist -o `"$tpl`" `"$Url`""
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $proc = New-Object Diagnostics.Process; $proc.StartInfo = $psi
    [void]$proc.Start()
    $outFs = [IO.File]::Create($logFile)
    $copyOut = $proc.StandardOutput.BaseStream.CopyToAsync($outFs)
    $errFs = [IO.File]::Create("$logFile.err")
    $copyErr = $proc.StandardError.BaseStream.CopyToAsync($errFs)
    $sw=[Diagnostics.Stopwatch]::StartNew(); $lastUi=[datetime]::MinValue; $lastPct=-1
    $newest = $null; $newestLen = 0L
    try {
        while (-not $proc.HasExited) {
            Start-Sleep -Milliseconds 500
            if (Test-Path $logFile) {
                $tail = Read-SysPilotFileTailLine -Path $logFile -MaxChars 300
                if ($tail -match '\[download\]\s+([\d.]+)%') {
                    $pct = [double]$Matches[1]
                    if ($pct -ne $lastPct -and ((Get-Date) - $lastUi).TotalMilliseconds -gt 400) {
                        $lastPct = $pct; $lastUi = Get-Date
                        $pi = [int]$pct
                        Write-Host ("`r  $Label : $pi%  (yt-dlp)   ") -NoNewline
                        if ($ProgressQueue) { $ProgressQueue.Enqueue(@{ Pct=$pi; Recv=0; Total=0; MBR=0; MBT=0; MBS=0; Label=$Label; Note='yt-dlp Video' }) }
                    }
                }
            }
            # Neue Datei im OutDir finden
            try {
                $cand = Get-ChildItem $OutDir -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if ($cand -and $cand.Length -gt $newestLen) { $newest = $cand; $newestLen = $cand.Length }
            } catch {}
            if ($sw.Elapsed.TotalSeconds -gt 3600) { throw 'Video-Download Timeout (1h)' }
        }
        try { $copyOut.Wait(3000)|Out-Null; $copyErr.Wait(3000)|Out-Null } catch {}
        try { $outFs.Flush();$outFs.Dispose();$errFs.Flush();$errFs.Dispose() } catch {}
        if ($proc.ExitCode -eq 0 -and $newest -and (Test-Path $newest.FullName)) {
            $res.Ok = $true; $res.Path = $newest.FullName
            Write-Host ''
            Write-Host "  [OK] $Label : $($newest.Name)" -ForegroundColor Green
        } else {
            $tailErr=''; if(Test-Path "$logFile.err"){$tailErr=Read-SysPilotFileTailLine -Path "$logFile.err" -MaxChars 200}
            $res.Error = "yt-dlp exit $($proc.ExitCode) $tailErr"
            Write-Host ''
            Write-Host "  [!] Video-Download fehlgeschlagen: $($res.Error)" -ForegroundColor Red
        }
    } catch {
        try { $proc.Kill() } catch {}
        $res.Error = $_.Exception.Message
        Write-Host ''
        Write-Host "  [!] $($res.Error)" -ForegroundColor Red
    } finally {
        try { $proc.Dispose() } catch {}
        try { if ($outFs) { $outFs.Dispose() } } catch {}
        try { if ($errFs) { $errFs.Dispose() } } catch {}
    }
    return $res
}

function Test-SysPilotSpecialDownloadUrl {
    <# Erkennt Torrent/Magnet/Video-Page-URLs. #>
    param([Parameter(Mandatory)][string]$Url)
    $u = $Url.Trim()
    if ($u -match '^magnet:\?' ) { return 'torrent' }
    if ($u -match '\.torrent(\?|$)' ) { return 'torrent' }
    if ($u -match '^(https?://)?(www\.)?(youtube\.com|youtu\.be|vimeo\.com|tiktok\.com|instagram\.com|twitter\.com|x\.com|twitch\.tv|dailymotion\.com|bilibili\.com)' ) { return 'video' }
    return ''
}

function Invoke-SysPilotSmartFileDownload {
    <# Zentrale Download-Engine (FDM-inspiriert):
         torrent/magnet -> aria2 BT (Auto-Install)
         http(s)         -> aria2 (falls vorhanden) -> Segment-Download -> Single
       Gibt $true/$false zurueck (wie Save-SysPilotUrlToFile). #>
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile,
        [string]$Label = 'Download',
        [int]$TimeoutSec = 900,
        [object]$ProgressQueue = $null,
        [string]$Engine = 'auto'   # auto|aria2|segments|single
    )
    # Bei instabilen Netzen (Hotspot/Mobilfunk): erst warten bis wieder
    # online, sonst schlagen alle Engine-Versuche ins Leere.
    if (-not (Wait-SysPilotInternet -MaxSec 90 -PollSec 5 -Label $Label)) { return $false }
    $kind = Test-SysPilotSpecialDownloadUrl -Url $Uri
    if ($kind -eq 'torrent') {
        $outDir = Split-Path $OutFile -Parent
        if (-not $outDir) { $outDir = '.' }
        $r = Invoke-SysPilotTorrentDownload -Source $Uri -OutDir $outDir -Label $Label -TimeoutSec 0 -ProgressQueue $ProgressQueue
        return [bool]$r.Ok
    }
    if ($kind -eq 'video') {
        # yt-dlp installiert sich bei Bedarf selbst (winget/pip)
        $outDir = Split-Path $OutFile -Parent
        if (-not $outDir) { $outDir = '.' }
        $vr = Invoke-SysPilotVideoDownload -Url $Uri -OutDir $outDir -Label $Label -ProgressQueue $ProgressQueue
        return [bool]$vr.Ok
    }
    if ($Engine -ne 'single') {
        $ariaRes = Invoke-SysPilotAria2Download -Uri $Uri -OutFile $OutFile -Label $Label -TimeoutSec $TimeoutSec -ProgressQueue $ProgressQueue
        if ($null -ne $ariaRes -and $ariaRes.Ok) { return $true }
        # aria2 fehlt oder ist fehlgeschlagen -> segmentierter nativer Download
        if ($Engine -eq 'auto' -or $Engine -eq 'segments' -or $null -eq $ariaRes) {
            if (Invoke-SysPilotSegmentedDownload -Uri $Uri -OutFile $OutFile -TimeoutSec $TimeoutSec -Label $Label -ProgressQueue $ProgressQueue) { return $true }
        }
    }
    if (Save-SysPilotUrlToFile -Uri $Uri -OutFile $OutFile -TimeoutSec $TimeoutSec -Label $Label -ProgressQueue $ProgressQueue) { return $true }
    # Letzte Instanz: Cloudflare-Challenge? -> Browser-Impersion (curl_cffi)
    if (Get-Command Invoke-SysPilotCfDownload -ErrorAction SilentlyContinue) {
        $probe = Test-SysPilotCfChallenge -Uri $Uri
        if ($probe -and $probe.IsChallenge) {
            Write-Host "  Cloudflare-Challenge erkannt - Browser-Impersion-Download ..." -ForegroundColor Yellow
            $cf = Invoke-SysPilotCfDownload -Uri $Uri -OutFile $OutFile -Label $Label -TimeoutSec $TimeoutSec -ProgressQueue $ProgressQueue
            if ($cf -and $cf.Ok) { return $true }
        }
    }
    return $false
}

function Ensure-SysPilotPrereqs {
    <# Stellt sicher, dass SysPilot alle benoetigten Helper + Paketmanager
       vorhanden hat - idempotent, laeuft bei Installation/Erstausfuehrung
       und auf Wunsch manuell. Fehlende Teile werden installiert, Fehler
       werden geloggt aber nicht geworfen.
         Download-Engine: aria2, yt-dlp, ffmpeg
         KI-Engine:       llama.cpp-Backend (Auto-GPU)
         Paketmanager:    scoop, chocolatey*, npm, pip, bun, dotnet
                          (* chocolatey nur mit Admin; WSL/brew ausgenommen)
       Gibt @{Ok;Installed;Skipped;Failed} zurueck. #>
    param(
        [switch]$Quiet,
        [string[]]$Only = @(),          # z.B. @('aria2','yt-dlp','pm')
        [switch]$SkipLlamaCpp           # llama.cpp-Download ist gross (~200MB)
    )
    $say = { param($m) if (-not $Quiet) { Write-Host "  $m" -ForegroundColor DarkGray }; try { Write-SysPilotLog $m } catch {} }
    $res = @{ Ok=$true; Installed=@(); Skipped=@(); Failed=@() }
    $want = { param($k) ($Only.Count -eq 0 -or $k -in $Only -or ($k -eq 'pm' -and 'pm' -in $Only)) }

    # --- Download-Engine ---
    if (& $want 'aria2') {
        $r = Install-SysPilotAria2
        if ($r.Ok) { if ($r.Via -ne 'vorhanden') { $res.Installed += "aria2 ($($r.Via))"; & $say "aria2 installiert via $($r.Via)" } else { $res.Skipped += 'aria2 (vorhanden)' } }
        else { $res.Failed += "aria2: $($r.Error)"; & $say "[!] aria2: $($r.Error)" }
    }
    if (& $want 'yt-dlp') {
        $r = Install-SysPilotYtDlp
        if ($r.Ok) { if ($r.Via -ne 'vorhanden') { $res.Installed += "yt-dlp ($($r.Via))"; & $say "yt-dlp installiert via $($r.Via)" } else { $res.Skipped += 'yt-dlp (vorhanden)' } }
        else { $res.Failed += "yt-dlp: $($r.Error)"; & $say "[!] yt-dlp: $($r.Error)" }
    }
    if (& $want 'ffmpeg') {
        $r = Install-SysPilotFfmpeg
        if ($r.Ok) { if ($r.Via -ne 'vorhanden') { $res.Installed += "ffmpeg ($($r.Via))"; & $say "ffmpeg installiert via $($r.Via)" } else { $res.Skipped += 'ffmpeg (vorhanden)' } }
        else { $res.Failed += "ffmpeg: $($r.Error)"; & $say "[!] ffmpeg: $($r.Error)" }
    }

    # --- llama.cpp-Backend (KI-Engine) ---
    if (-not $SkipLlamaCpp -and (& $want 'llamacpp')) {
        $haveLlama = $false
        if (Get-Command Get-SysPilotLlamaServerExe -ErrorAction SilentlyContinue) {
            try { $haveLlama = [bool](Get-SysPilotLlamaServerExe) } catch { $haveLlama = $false }
        }
        if ($haveLlama) { $res.Skipped += 'llama.cpp (vorhanden)' }
        elseif (Get-Command Install-SysPilotLlamaCpp -ErrorAction SilentlyContinue) {
            & $say "llama.cpp-Backend wird geladen (Auto-GPU, ~200MB) ..."
            $lr = Install-SysPilotLlamaCpp
            if ($lr.Ok) { $res.Installed += "llama.cpp ($($lr.Dir))"; & $say "llama.cpp installiert: $($lr.Dir)" }
            else { $res.Failed += "llama.cpp: $($lr.Error)"; & $say "[!] llama.cpp: $($lr.Error)" }
        } else { $res.Skipped += 'llama.cpp (Modul nicht geladen)' }
    }

    # --- Paketmanager (native Windows-Manager) ---
    if (& $want 'pm' -and (Get-Command Get-SysPilotPackageManagers -ErrorAction SilentlyContinue) -and (Get-Command Install-SysPilotPackageManager -ErrorAction SilentlyContinue)) {
        $installed = @{}
        foreach ($pm in @(Get-SysPilotPackageManagers)) { $installed[$pm.Id] = ($pm.Status -eq 'installed') }
        foreach ($mid in @('scoop','chocolatey','npm','pip','bun','dotnet')) {
            if ($installed[$mid]) { $res.Skipped += "pm:$mid (vorhanden)"; continue }
            if ($mid -eq 'chocolatey' -and -not (Test-SysPilotAdmin)) { $res.Skipped += 'pm:chocolatey (kein Admin)'; continue }
            & $say "Paketmanager $mid fehlt - Installation ..."
            try {
                $okm = Install-SysPilotPackageManager -Id $mid
                if ($okm) { $res.Installed += "pm:$mid"; & $say "Paketmanager $mid installiert" }
                else { $res.Failed += "pm:$mid"; & $say "[!] Paketmanager $mid nicht installierbar" }
            } catch { $res.Failed += "pm:$mid"; & $say "[!] pm:$mid : $($_.Exception.Message)" }
        }
        # winget ist on Win11 eingebaut - nur melden wenn wirklich weg
        if (-not $installed['winget'] -and -not (Get-SysPilotWingetExeLocal)) { $res.Failed += 'pm:winget (nicht gefunden)' }
    }

    # curl_cffi (CF-Download-Bypass) - braucht pip/python; groessenmaessig klein
    if (& $want 'curlcffi') {
        if (Get-Command Install-SysPilotCurlCffi -ErrorAction SilentlyContinue) {
            $cr = Install-SysPilotCurlCffi
            if ($cr.Ok) { if ($cr.Via -ne 'vorhanden') { $res.Installed += "curl_cffi ($($cr.Via))"; & $say "curl_cffi installiert via $($cr.Via)" } else { $res.Skipped += 'curl_cffi (vorhanden)' } }
            else { $res.Skipped += "curl_cffi ($($cr.Error))" }
        } else { $res.Skipped += 'curl_cffi (Modul nicht geladen)' }
    }

    & $say ("Prereqs fertig: {0} installiert, {1} uebersprungen, {2} fehlgeschlagen" -f $res.Installed.Count, $res.Skipped.Count, $res.Failed.Count)
    return $res
}

function Read-SysPilotFileTailLine {
    <# Letzte nicht-leere Zeile einer (moeglich groszen) Datei, ohne sie
       ganz zu laden - seekt ans Dateiende. #>
    param([Parameter(Mandatory)][string]$Path, [int]$MaxChars = 140)
    try {
        $fs = [IO.File]::Open($Path, 'Open', 'Read', [IO.FileShare]'ReadWrite')
        try {
            $len = [Math]::Min($fs.Length, 16384)
            [void]$fs.Seek(-$len, 'End')
            $buf = New-Object byte[] $len
            [void]$fs.Read($buf, 0, $len)
            try { $txt = [Text.UTF8Encoding]::new($false, $true).GetString($buf) }
            catch { $txt = [Text.Encoding]::Default.GetString($buf) }
        } finally { $fs.Dispose() }
        $lines = @($txt -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
        if ($lines.Count -eq 0) { return '' }
        $l = $lines[-1].Trim()
        if ($l.Length -gt $MaxChars) { $l = '...' + $l.Substring($l.Length - $MaxChars) }
        return $l
    } catch { return '' }
}

function Invoke-SysPilotMonitoredProcess {
    <# Startet einen Prozess MIT sichtbarem Fortschritt: Spinner,
       Laufzeit, letzte Output-Zeile. Output laeuft in eine Temp-Datei
       (cmd /c-Wrapper), dadurch ist "Haengen" erkennbar: wenn waehrend
       StallWarnSec weder Output noch CPU-Zeit wachsen, wird gewarnt
       und Abbruch (Q) oder Weiterwarten (Enter) angeboten.
       Unterstuetzt .exe/.cmd/.bat direkt, .ps1 ueber powershell.exe.
       Rueckgabe: @{Ok;ExitCode;Output;Error;Aborted;Timeout} #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgList = @(),
        [string]$Label = 'Prozess',
        [int]$TimeoutSec = 900,
        [int]$StallWarnSec = 120,
        [switch]$Quiet,
        [switch]$NoAbort
    )
    $exe = $FilePath
    if ($exe -notmatch '[\\/]') {
        $c = Get-Command $exe -ErrorAction SilentlyContinue
        if ($c) { $exe = $c.Source }
    }
    if (-not $exe -or -not (Test-Path $exe)) {
        return @{ Ok=$false; ExitCode=$null; Output=''; Error="Programm nicht gefunden: $FilePath"; Aborted=$false; Timeout=$false }
    }
    $argStr = ($ArgList | ForEach-Object { $s = "$_"; if ($s -match '\s') { '"' + $s + '"' } else { $s } }) -join ' '
    $outFile = Join-Path $env:TEMP ("syspilot-proc-{0}.log" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
    $inner = "`"$exe`" $argStr > `"$outFile`" 2>&1"
    if ($exe -match '\.ps1$') {
        $inner = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$exe`" $argStr > `"$outFile`" 2>&1"
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "$env:SystemRoot\System32\cmd.exe"
    $psi.Arguments = "/d /s /c `"$inner`""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = $null
    try { $proc = [System.Diagnostics.Process]::Start($psi) }
    catch { return @{ Ok=$false; ExitCode=$null; Output=''; Error=$_.Exception.Message; Aborted=$false; Timeout=$false } }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $spin = '|/-\'; $si = 0
    $lastSize = -1L; $lastCpu = 0.0; $lastGrow = Get-Date
    $stallWarned = $false; $aborted = $false; $timedOut = $false
    $canAbort = (-not $NoAbort) -and (-not [Console]::IsInputRedirected)
    $killTree = {
        try { & "$env:SystemRoot\System32\taskkill.exe" /PID $proc.Id /T /F 2>&1 | Out-Null } catch { }
        try { if (-not $proc.HasExited) { $proc.Kill() } } catch { }
    }
    $code = $null
    try {
        while (-not $proc.HasExited) {
            if ($proc.WaitForExit(400)) { break }
            $fi = Get-Item $outFile -ErrorAction SilentlyContinue
            $sz = if ($fi) { $fi.Length } else { 0 }
            $cpu = 0.0
            try { $proc.Refresh(); $cpu = $proc.TotalProcessorTime.TotalSeconds } catch { }
            if ($sz -ne $lastSize -or ($cpu - $lastCpu) -gt 0.3) {
                $lastSize = $sz; $lastCpu = $cpu; $lastGrow = Get-Date; $stallWarned = $false
            }
            $idle = ((Get-Date) - $lastGrow).TotalSeconds
            if (-not $Quiet) {
                $el = [int]$sw.Elapsed.TotalSeconds
                $mm = [math]::Floor($el / 60); $ss = $el % 60
                $tail = Read-SysPilotFileTailLine -Path $outFile
                $tailTxt = if ($tail) { "  |  $tail" } else { '' }
                Write-Host ("`r  {0} {1}  {2}:{3:d2}{4}   " -f $spin[$si % 4], $Label, $mm, $ss, $tailTxt) -NoNewline
                $si++
            }
            if ($idle -gt $StallWarnSec) {
                if (-not $stallWarned) {
                    Write-Host "`n  ! Keine Ausgabe/CPU-Aktivitaet seit $([int]$idle)s - Vorgang haengt moeglicherweise." -ForegroundColor Yellow
                    if ($canAbort) { Write-Host '    [Q] Abbrechen  [Enter] weiter warten' -ForegroundColor DarkYellow -NoNewline }
                    $stallWarned = $true
                }
                if ($canAbort -and [Console]::KeyAvailable) {
                    $k = [Console]::ReadKey($true).Key
                    if ($k -eq 'Q' -or $k -eq 'Escape') { & $killTree; $aborted = $true; break }
                    if ($k -eq 'Enter') { $lastGrow = Get-Date; $stallWarned = $false; Write-Host '' }
                }
            }
            if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) { & $killTree; $timedOut = $true; break }
        }
        if (-not $proc.HasExited) { try { $proc.WaitForExit(3000) | Out-Null } catch { } }
        try { $code = $proc.ExitCode } catch { $code = $null }
    } finally {
        if (-not $Quiet) { Write-Host '' }
        $proc.Dispose()
    }
    $out = ''
    if (Test-Path $outFile) {
        try {
            # Tools sind inkonsistent: winget emittiert UTF-8, aeltere
            # Konsolen-Tools ANSI/OEM. Striktes UTF-8 zuerst, ANSI-Fallback
            # verhindert Mojibake wie 'verfÃ¼gbar'.
            $bytes = [IO.File]::ReadAllBytes($outFile)
            try { $out = [Text.UTF8Encoding]::new($false, $true).GetString($bytes) }
            catch { $out = [Text.Encoding]::Default.GetString($bytes) }
        } catch { $out = '' }
    }
    Remove-Item $outFile -Force -ErrorAction SilentlyContinue
    if ($aborted)   { return @{ Ok=$false; ExitCode=$code; Output=$out; Error='Vom Benutzer abgebrochen'; Aborted=$true;  Timeout=$false } }
    if ($timedOut)  { return @{ Ok=$false; ExitCode=$code; Output=$out; Error="Timeout nach $TimeoutSec s"; Aborted=$false; Timeout=$true } }
    $tail = (($out -split "`r?`n") | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 6) -join ' | '
    return @{ Ok=($code -eq 0); ExitCode=$code; Output=$out; Error=$(if ($code -eq 0) { '' } else { $tail }); Aborted=$false; Timeout=$false }
}

# =====================================================================
# ASSISTENTEN-/AKTIVITAETS-PANEL (flächendeckend fuer alle WPF-Fenster)
# =====================================================================
$script:_spPanels = New-Object System.Collections.ArrayList

function Add-SysPilotAssistantToWindow {
    <# Haengt an einem bestehenden WPF-Fenster eine schmale
       Aktivitaets-Leiste unten an: Herbert-Button (öffnet den
       schwebenden Assistenten rechts), Fortschrittsbalken und
       Konsolen-Log ( klappt bei erster Meldung auf).
       Rückgabe: Info-Objekt; idempotent (Tag '_assistant'). #>
    param(
        [Parameter(Mandatory)]$Win,
        [string]$Context = '',
        [string[]]$Suggestions = @(),
        [bool]$AutoHerbert = $true
    )
    try {
        if ($Win.Tag -is [hashtable] -and $Win.Tag.Contains('_assistant')) { return $Win.Tag['_assistant'] }
        # Fenster-Chrome: Vordergrund + globale Platzierung (Class-
        # Handler deckt zusaetzlich alle anderen Fenster im Prozess)
        try { Set-SysPilotWindowForeground -Win $Win } catch {}
        if (-not ('Windows.Controls.Border' -as [type])) {
            [void][reflection.assembly]::LoadWithPartialName('PresentationFramework')
            [void][reflection.assembly]::LoadWithPartialName('PresentationCore')
            [void][reflection.assembly]::LoadWithPartialName('WindowsBase')
        }
        $pal = Get-SysPilotWpfPalette
        $bc = { param($h) [Windows.Media.BrushConverter]::new().ConvertFromString($h) }

        $border = New-Object Windows.Controls.Border
        $border.Background = & $bc $pal.Panel
        $border.BorderBrush = & $bc $pal.Border
        $border.BorderThickness = '0,1,0,0'
        $border.Padding = '8,4'

        $sp = New-Object Windows.Controls.StackPanel
        # Fortschrittsbalken (dünn, oben)
        $pb = New-Object Windows.Controls.ProgressBar
        $pb.Height = 3; $pb.Minimum=0; $pb.Maximum=100; $pb.Value=0
        $pb.Visibility='Collapsed'; $pb.Margin='0,0,0,4'
        $pb.Foreground = & $bc $pal.Accent; $pb.Background = & $bc '#FF2A2A3A'
        [void]$sp.Children.Add($pb)
        # Kopfzeile: Label + Herbert-Button
        $row = New-Object Windows.Controls.DockPanel
        $lbl = New-Object Windows.Controls.TextBlock
        $lbl.Text = 'Pilot Herbert'; $lbl.FontWeight='Bold'
        $lbl.Foreground = & $bc $pal.Accent2
        $lbl.VerticalAlignment='Center'
        [void]$row.Children.Add($lbl)
        $hbtn = New-Object Windows.Controls.Button
        $hbtn.Content='Assistent'; $hbtn.FontSize=10; $hbtn.Padding='8,2'
        $hbtn.HorizontalAlignment='Right'
        $hbtn.ToolTip='Pilot Herbert: schwebender Assistent mit Kontext, Schnellfragen und SysPilot-Aktionen'
        # HINWEIS: Handler darf KEINE Funktions-Lokalen nutzen - die
        # Funktion kehrt zurueck und die Variablen sind dann weg.
        # Kontext kommt daher aus $Win.Tag['_assistant'] (siehe unten).
        $hbtn.Add_Click({
            param($s, $e)
            try {
                $w = [Windows.Window]::GetWindow($s)
                $inf = $null
                if ($w -and $w.Tag -is [hashtable]) { $inf = $w.Tag['_assistant'] }
                Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'AiAssist.psm1') -Force -ErrorAction SilentlyContinue
                if (Get-Command Show-SysPilotHerbertAssistant -ErrorAction SilentlyContinue) {
                    Show-SysPilotHerbertAssistant -Owner $w -Context $(if ($inf) { $inf.Context } else { '' }) -Suggestions $(if ($inf -and $inf.Suggestions) { $inf.Suggestions } else { @() })
                }
            } catch {}
        })
        $hbtn.SetValue([Windows.Controls.DockPanel]::DockProperty,[Windows.Controls.Dock]::Right)
        [void]$row.Children.Add($hbtn)
        $actLbl = New-Object Windows.Controls.TextBlock
        $actLbl.Text='Aktivitaet'; $actLbl.FontSize=10; $actLbl.Foreground=& $bc $pal.Muted
        $actLbl.VerticalAlignment='Center'; $actLbl.Margin='10,0,0,0'
        [void]$row.Children.Add($actLbl)
        [void]$sp.Children.Add($row)
        # Konsolen-Log (zugeklappt bis erste Meldung)
        $log = New-Object Windows.Controls.TextBox
        $log.IsReadOnly=$true; $log.AcceptsReturn=$true
        $log.TextWrapping='NoWrap'; $log.VerticalScrollBarVisibility='Auto'
        $log.HorizontalScrollBarVisibility='Auto'
        $log.FontFamily='Consolas'; $log.FontSize='10'
        $log.Background=& $bc $pal.Input; $log.Foreground=& $bc '#FF9FE89F'
        $log.BorderThickness='0'; $log.Height=95; $log.Visibility='Collapsed'; $log.Margin='0,4,0,0'
        [void]$sp.Children.Add($log)
        $border.Child = $sp

        # Ins Fenster-Layout einhaengen (DockPanel: vor dem Fuell-Kind unten)
        $content = $Win.Content
        $attached = $false
        if ($content -is [Windows.Controls.DockPanel]) {
            $kids = $content.Children
            $idx = [math]::Max(0, $kids.Count - 1)
            $border.SetValue([Windows.Controls.DockPanel]::DockProperty,[Windows.Controls.Dock]::Bottom)
            $kids.Insert($idx, $border)
            $attached = $true
        } elseif ($content -is [Windows.Controls.Panel] -and -not ($content -is [Windows.Controls.DockPanel])) {
            $wrap = New-Object Windows.Controls.DockPanel
            $content.HorizontalAlignment='Stretch'; $content.VerticalAlignment='Stretch'
            $wrap.Children.Add($content)
            $border.SetValue([Windows.Controls.DockPanel]::DockProperty,[Windows.Controls.Dock]::Bottom)
            # Panel zuerst? nein: content zuletzt = fuellt; border davor mit Dock=Bottom
            $wrap.Children.Insert(0,$border)
            $Win.Content = $wrap
            $attached = $true
        } elseif ($null -ne $content) {
            $wrap = New-Object Windows.Controls.DockPanel
            $holder = New-Object Windows.Controls.ContentPresenter
            $holder.Content = $content
            $wrap.Children.Add($holder)
            $border.SetValue([Windows.Controls.DockPanel]::DockProperty,[Windows.Controls.Dock]::Bottom)
            $wrap.Children.Insert(0,$border)
            $Win.Content = $wrap
            $attached = $true
        }
        if (-not $attached) { return $null }

        $info = [pscustomobject]@{ Win=$Win; Panel=$border; Progress=$pb; Log=$log; Context=$Context; Suggestions=$Suggestions; HerbertOpened=$false }
        [void]$script:_spPanels.Add($info)
        if (-not ($Win.Tag -is [hashtable])) { $Win.Tag = @{} }
        $Win.Tag['_assistant'] = $info
        $Win.Add_Closing({
            try {
                for ($i=$script:_spPanels.Count-1; $i -ge 0; $i--) {
                    if ($script:_spPanels[$i].Win -eq $Win) { $script:_spPanels.RemoveAt($i) }
                }
            } catch {}
        })
        # Herbert automatisch rechts öffnen, sobald das Fenster steht
        # (nicht-modal, Owner = das Fenster). Laeuft nur einmal.
        if ($AutoHerbert) {
            $Win.Add_ContentRendered({
                param($s, $e)
                try {
                    $inf = $null
                    if ($s.Tag -is [hashtable]) { $inf = $s.Tag['_assistant'] }
                    if ($inf -and -not $inf.HerbertOpened) {
                        $inf.HerbertOpened = $true
                        Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'AiAssist.psm1') -Force -ErrorAction SilentlyContinue
                        if (Get-Command Show-SysPilotHerbertAssistant -ErrorAction SilentlyContinue) {
                            Show-SysPilotHerbertAssistant -Owner $s -Context $inf.Context -Suggestions $inf.Suggestions
                        }
                    }
                } catch {}
            })
        }
        return $info
    } catch {
        try { "ASSISTANT-FAIL: $($_.Exception.Message)`n$($_.ScriptStackTrace)" | Out-File "$env:TEMP\syspilot-assistant-err.txt" -Encoding utf8 } catch {}
        return $null
    }
}

function Write-SysPilotPanelLog {
    <# Schreibt eine Aktivitaetszeile in das Assistant-Panel
       aller sichtbaren WPF-Fenster (klappt das Log auf).
       Sicher aus Jobs/UI-Thread heraus aufrufbar (nur UI-seitig
       sichtbar, wenn das Fenster auf dem Dispatcher-Thread ist). #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    try {
        # PROGRESS|<n> steuert den Balken statt ins Log zu schreiben
        if ($Text -match '^PROGRESS\|(\d+)$') { Set-SysPilotPanelProgress -Value ([double]$Matches[1]); return }
        if ($Text -match '^PROGRESS\|indeterminate$') { Set-SysPilotPanelProgress -Indeterminate; return }
        $stamp = Get-Date -Format 'HH:mm:ss'
        foreach ($p in @($script:_spPanels)) {
            try {
                if (-not $p.Win.IsVisible) { continue }
                if ($p.Log.Visibility -ne 'Visible') { $p.Log.Visibility='Visible' }
                $p.Log.AppendText("$stamp  $Text`r`n")
                try { $p.Log.ScrollToEnd() } catch {}
            } catch {}
        }
    } catch {}
}

function Set-SysPilotPanelProgress {
    <# Setzt den Fortschrittsbalken im Assistant-Panel sichtbarer
       Fenster. -Value 0-100, oder -Indeterminate. #>
    param([double]$Value = -1, [switch]$Indeterminate, [switch]$Hide)
    try {
        foreach ($p in @($script:_spPanels)) {
            try {
                if (-not $p.Win.IsVisible) { continue }
                if ($Hide) { $p.Progress.Visibility='Collapsed'; continue }
                $p.Progress.Visibility='Visible'
                if ($Indeterminate) { $p.Progress.IsIndeterminate=$true }
                else { $p.Progress.IsIndeterminate=$false; if($Value -ge 0){ $p.Progress.Value=[math]::Min(100,[math]::Max(0,$Value)) } }
            } catch {}
        }
    } catch {}
}

function Register-SysPilotProtocol {
    <# Registriert das syspilot://-URL-Protokoll in HKCU (kein Admin noetig).
       Ermöglicht z.B. der Browser-Extension 'pilot-herbert' den Aufruf
       'syspilot://repo/Owner/Name' -> gefuehrter KI-Installations-Assistent. #>
    param([string]$Repo = '')
    $scriptPath = Join-Path $script:SysPilotRoot 'SysPilot.ps1'
    if (-not $scriptPath) { $scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'SysPilot.ps1' }
    if (-not (Test-Path $scriptPath)) { return @{ Ok=$false; Error="SysPilot.ps1 nicht gefunden: $scriptPath" } }
    $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -ProtocolRepo "{1}"' -f $scriptPath, $Repo
    try {
        $base = 'HKCU:\SOFTWARE\Classes\syspilot'
        New-Item -Path $base -Force | Out-Null
        Set-ItemProperty -Path $base -Name '(Default)' -Value 'URL:SysPilot Protocol' -ErrorAction SilentlyContinue
        New-ItemProperty -Path $base -Name 'URL Protocol' -Value '' -PropertyType String -Force | Out-Null
        $shell = Join-Path $base 'shell\open\command'
        New-Item -Path $shell -Force | Out-Null
        Set-ItemProperty -Path $shell -Name '(Default)' -Value ('"' + $cmd + '" %1')
        return @{ Ok=$true; Command=$cmd }
    } catch { return @{ Ok=$false; Error=$_.Exception.Message } }
}

function Unregister-SysPilotProtocol {
    try { Remove-Item 'HKCU:\SOFTWARE\Classes\syspilot' -Recurse -Force -ErrorAction Stop; return @{ Ok=$true } }
    catch { return @{ Ok=$false; Error=$_.Exception.Message } }
}

function Show-SysPilotStepGuide {
    <# Generischer Schritt-fuer-Schritt-Guide (ADHD-tauglich):
       EIN Schritt sichtbar, Enter = weiter, u = URL oeffnen,
       v = YouTube-Suche (Schritt.Yt oder Fallback), z = Abbruch.
       Steps: @(@{T='Titel'; Hint='Text'; Url='...'; Yt='suchbegriff'}) #>
    param(
        [Parameter(Mandatory=$true)][array]$Steps,
        [string]$Title = 'Anleitung',
        [string]$DoneText = 'Fertig.'
    )
    $i = 0
    while ($i -lt $Steps.Count) {
        $s = $Steps[$i]
        Write-Host "`n  [$($i+1)/$($Steps.Count)] $($s.T)" -ForegroundColor Cyan
        if ($s.Hint) { Write-Host "  $($s.Hint)" -ForegroundColor DarkGray }
        if ($s.Url) { Write-Host "  URL: $($s.Url)" -ForegroundColor DarkCyan }
        $ans = Read-SysPilotChoice '  Enter = weiter / u = URL / v = YouTube / z = zurueck'
        if ($ans -eq 'u' -and $s.Url) { Start-Process $s.Url }
        elseif ($ans -eq 'v') {
            $q = if ($s.Yt) { $s.Yt } else { $Title }
            Start-Process ('https://www.youtube.com/results?search_query=' + [uri]::EscapeDataString($q))
        }
        elseif ($ans -eq 'z') { return $false }
        $i++
    }
    if ($DoneText) { Write-Host "`n  [FERTIG] $DoneText" -ForegroundColor Green }
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
    return $true
}

# ==================== PATH-Verwaltung (fehlende Tool-Pfade) ====================

function Get-SysPilotPathEntries {
    <# Alle PATH-Eintraege (User + Machine), env-variablen-expandiert,
       normalisiert (kein schliessender Backslash), dedupliziert. #>
    param([ValidateSet('User','Machine','Both')][string]$Scope = 'Both')
    $raw = @()
    if ($Scope -in @('User','Both')) { $raw += @([Environment]::GetEnvironmentVariable('Path','User')) }
    if ($Scope -in @('Machine','Both')) { $raw += @([Environment]::GetEnvironmentVariable('Path','Machine')) }
    $seen = @{}
    $out = @()
    foreach ($e in $raw) {
        foreach ($part in ($e -split ';')) {
            $p = $part.Trim()
            if (-not $p) { continue }
            try { $p = [Environment]::ExpandEnvironmentVariables($p) } catch {}
            $p = $p.TrimEnd('\')
            $k = $p.ToLower()
            if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $out += $p }
        }
    }
    return ,$out
}

function Get-SysPilotToolPathCandidates {
    <# Wohlbekannte Tool-Verzeichnisse, die im PATH stehen sollten.
       Nur Verzeichnisse, die es wirklich gibt, werden zurueckgegeben.
       Dynamisch: llama.cpp-Builds, Python-Versionen. #>
    $c = @(
        @{ Name='Git';              Dir='C:\Program Files\Git\cmd' }
        @{ Name='Git (bin)';        Dir='C:\Program Files\Git\bin' }
        @{ Name='GitHub CLI';       Dir='C:\Program Files\GitHub CLI' }
        @{ Name='Node.js';          Dir='C:\Program Files\nodejs' }
        @{ Name='npm global';       Dir=(Join-Path $env:APPDATA 'npm') }
        @{ Name='7-Zip';            Dir='C:\Program Files\7-Zip' }
        @{ Name='Docker';           Dir='C:\Program Files\Docker\Docker\resources\bin' }
        @{ Name='Docker plugins';   Dir='C:\Program Files\Docker\Docker\resources\cli-plugins' }
        @{ Name='VS Code';          Dir='C:\Program Files\Microsoft VS Code\bin' }
        @{ Name='PowerShell 7';     Dir='C:\Program Files\PowerShell\7' }
        @{ Name='Ollama';           Dir=(Join-Path $env:LOCALAPPDATA 'Programs\Ollama') }
        @{ Name='LM Studio (lms)';  Dir=(Join-Path $env:USERPROFILE '.lmstudio\bin') }
        @{ Name='LM Studio (alt)';  Dir='C:\Program Files\LM Studio\resources\app\.webpack' }
        @{ Name='WindowsApps';      Dir=(Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps') }
        @{ Name='bun';              Dir=(Join-Path $env:USERPROFILE '.bun\bin') }
        @{ Name='uv';               Dir=(Join-Path $env:USERPROFILE '.local\bin') }
        @{ Name='cargo';            Dir=(Join-Path $env:USERPROFILE '.cargo\bin') }
        @{ Name='Go';               Dir='C:\Program Files\Go\bin' }
        @{ Name='Rust';             Dir=(Join-Path $env:USERPROFILE '.cargo\bin') }
        @{ Name='Flutter';          Dir=(Join-Path $env:USERPROFILE 'flutter\bin') }
        @{ Name='kubectl';          Dir=(Join-Path $env:USERPROFILE '.kube') }
    )
    # Dynamisch: llama.cpp-Builds mit llama-server.exe
    $llamaRoot = Join-Path $env:LOCALAPPDATA 'SysPilot\llama.cpp'
    if (Test-Path $llamaRoot) {
        Get-ChildItem $llamaRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            if (Test-Path (Join-Path $_.FullName 'llama-server.exe')) {
                $c += @{ Name="llama.cpp ($($_.Name))"; Dir=$_.FullName }
            }
        }
    }
    # Dynamisch: Python-Installationen unter %LOCALAPPDATA%\Programs\Python
    $pyRoot = Join-Path $env:LOCALAPPDATA 'Programs\Python'
    if (Test-Path $pyRoot) {
        Get-ChildItem $pyRoot -Directory -Filter 'Python*' -ErrorAction SilentlyContinue | ForEach-Object {
            if (Test-Path (Join-Path $_.FullName 'python.exe')) { $c += @{ Name="Python $($_.Name)"; Dir=$_.FullName } }
        }
    }
    return @($c | Where-Object { $_.Dir -and (Test-Path $_.Dir) })
}

function Repair-SysPilotPath {
    <# Prueft User+Machine-PATH gegen die Tool-Kandidaten und traegt
       fehlende Verzeichnisse in den USER-PATH ein (kein Admin noetig).
       Machine-PATH-Luecken werden nur gemeldet.
       Rueckgabe: @{ Added=@(); MissingInMachine=@(); Ok } #>
    param([switch]$Quiet)
    $existing = @(Get-SysPilotPathEntries -Scope Both)
    $userPath = @([Environment]::GetEnvironmentVariable('Path','User') -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $machinePath = @([Environment]::GetEnvironmentVariable('Path','Machine') -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $norm = @{}
    foreach ($e in $existing) { $norm[$e.ToLower()] = $true }
    $added = @(); $machineOnly = @()
    foreach ($cand in @(Get-SysPilotToolPathCandidates)) {
        $d = $cand.Dir.TrimEnd('\')
        if ($norm.ContainsKey($d.ToLower())) { continue }
        $inUser = $false
        foreach ($u in $userPath) { try { if ([Environment]::ExpandEnvironmentVariables($u).TrimEnd('\').ToLower() -eq $d.ToLower()) { $inUser = $true; break } } catch {} }
        if ($inUser) { $norm[$d.ToLower()] = $true; continue }
        $inMach = $false
        foreach ($m in $machinePath) { try { if ([Environment]::ExpandEnvironmentVariables($m).TrimEnd('\').ToLower() -eq $d.ToLower()) { $inMach = $true; break } } catch {} }
        if ($inMach) { $norm[$d.ToLower()] = $true; $machineOnly += $cand; continue }
        # In User-PATH eintragen
        try {
            $newPath = (@($userPath) + $d) -join ';'
            [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
            $userPath += $d
            $norm[$d.ToLower()] = $true
            $added += $cand
        } catch {}
    }
    if (-not $Quiet -and $added.Count -gt 0) {
        Write-Host "  PATH ergaenzt ($($added.Count)): $(($added | ForEach-Object Name) -join ', ')" -ForegroundColor Green
    }
    return @{ Added=$added; MissingInMachine=$machineOnly; Ok=($added.Count -gt 0) }
}

function Show-SysPilotPathMenu {
    <# PATH-Audit: zeigt fehlende Tool-Pfade, ergaenzt User-PATH. #>
    while ($true) {
        $existing = @(Get-SysPilotPathEntries -Scope Both)
        $norm = @{}; foreach ($e in $existing) { $norm[$e.ToLower()] = $true }
        $cands = @(Get-SysPilotToolPathCandidates)
        $missing = @($cands | Where-Object { -not $norm.ContainsKey($_.Dir.TrimEnd('\').ToLower()) })
        Write-Host "`n  ========================================================" -ForegroundColor Cyan
        Write-Host "           PATH-VERWALTUNG" -ForegroundColor Cyan
        Write-Host "  ========================================================" -ForegroundColor Cyan
        Write-Host "  PATH-Eintraege (User+Machine): $($existing.Count)" -ForegroundColor DarkGray
        Write-Host "  Tool-Kandidaten gefunden: $($cands.Count), fehlend: $($missing.Count)" -ForegroundColor DarkGray
        foreach ($m in $missing) { Write-Host "    fehlt: $($m.Name) -> $($m.Dir)" -ForegroundColor Yellow }
        $items = @(
            @{ Label="[+] Fehlende Pfade eintragen ($($missing.Count))"; Color='Green'; Tag='add' },
            @{ Label='[L] Alle PATH-Eintraege anzeigen'; Color='Cyan'; Tag='list' },
            @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
        )
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'PATH' -Footer 'Enter = Aktion, Esc = zurueck'
        if ($null -eq $sel) { return }
        if ($sel -eq 'add') {
            $r = Repair-SysPilotPath
            if ($r.Added.Count -eq 0) { Write-Host '  Alles vorhanden.' -ForegroundColor Green }
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; continue
        }
        if ($sel -eq 'list') {
            Write-Host "`n  PATH (User+Machine, dedupliziert):" -ForegroundColor Cyan
            $existing | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; continue
        }
    }
}

# Auto-Check beim Modul-Import: fehlende Standard-Pfade still ergaenzen.
# Billig (Registry-Env-Read + Test-Path), schreibt nur bei Luecken.
try { [void](Repair-SysPilotPath -Quiet) } catch {}

function Get-SysPilotPwshInfo {
    <# Sucht pwsh.exe (PowerShell 7+) an ueblichen Orten. #>
    $cands = @(
        (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source,
        "$env:ProgramFiles\PowerShell\7\pwsh.exe",
        "${env:ProgramFiles(x86)}\PowerShell\7\pwsh.exe",
        "$env:LOCALAPPDATA\Microsoft\WindowsApps\pwsh.exe"
    ) | Where-Object { $_ -and (Test-Path $_) }
    foreach ($c in $cands) {
        try {
            $v = (& $c -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>$null)
            if ($v -match '^\d+\.\d+') {
                return [pscustomobject]@{ Path=$c; Version=$Matches[0] }
            }
        } catch {}
        return [pscustomobject]@{ Path=$c; Version='?' }
    }
    return $null
}

function Get-SysPilotShellMode {
    <# Modus aus config.json -> Start.PwshMode: 'ps51' (default),
       'ps7' (nur pwsh), 'auto' (pwsh wenn vorhanden, sonst 5.1). #>
    $cfg = Get-SysPilotConfig
    $m = 'ps51'
    if ($cfg.Start -and $cfg.Start.PSObject.Properties['PwshMode']) { $m = [string]$cfg.Start.PwshMode }
    return $m
}

function Get-SysPilotPreferredShell {
    <# Liefert @{ Exe; ArgsPrefix; Mode; Pwsh } - was SysPilot nutzen soll.
       pwsh.exe wird gegen powershell.exe getauscht, Args bleiben gleich. #>
    $mode = Get-SysPilotShellMode
    $info = Get-SysPilotPwshInfo
    $usePwsh = ($mode -eq 'ps7') -or ($mode -eq 'auto' -and $info)
    if ($usePwsh -and $info) {
        return @{ Exe=$info.Path; Mode=$mode; Pwsh=$info; IsPwsh=$true }
    }
    return @{ Exe='powershell.exe'; Mode=$mode; Pwsh=$info; IsPwsh=$false }
}

function Install-SysPilotPwsh {
    <# Bietet PS7-Installation via winget an (Microsoft.PowerShell). #>
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host '  Installiere PowerShell 7 via winget ...' -ForegroundColor Cyan
        & winget install -e --id Microsoft.PowerShell --accept-package-agreements --accept-source-agreements --silent 2>&1 | Select-Object -Last 5 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    } else {
        Write-Host '  winget fehlt - PS7 manuell: https://aka.ms/powershell' -ForegroundColor Yellow
        if (Confirm-SysPilot 'Download-Seite oeffnen?') { Start-Process 'https://aka.ms/powershell' }
    }
    Start-Sleep -Seconds 2
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
    return Get-SysPilotPwshInfo
}

function Show-SysPilotPwshMenu {
    <# PowerShell-Laufzeit: Status, PS7 installieren, Modus waehlen. #>
    while ($true) {
        $info = Get-SysPilotPwshInfo
        $mode = Get-SysPilotShellMode
        Write-Host "`n  === PowerShell-Laufzeit ===" -ForegroundColor Cyan
        if ($info) { Write-Host "  PS7 gefunden: $($info.Path) (v$($info.Version))" -ForegroundColor Green }
        else { Write-Host '  PowerShell 7+: nicht installiert (SysPilot laeuft auf Windows PowerShell 5.1)' -ForegroundColor Yellow }
        Write-Host "  Modus: $(switch($mode){'ps7'{'nur PS7'}'auto'{'PS7 wenn da, sonst 5.1'}default{'fest 5.1'}})" -ForegroundColor White
        $items = @(
            @{ Label='[i] PowerShell 7 installieren (winget)'; Color='Green'; Tag='install' },
            @{ Label='[a] Modus: Auto (PS7 wenn vorhanden)'; Color='Cyan'; Tag='auto' },
            @{ Label='[7] Modus: Nur PowerShell 7'; Color='Cyan'; Tag='ps7' },
            @{ Label='[5] Modus: Fest Windows PowerShell 5.1'; Color='Cyan'; Tag='ps51' },
            @{ Label='[t] Testlauf unter PS7 (SysPilot neu starten)'; Color='Yellow'; Tag='test' },
            @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
        )
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'PowerShell-Laufzeit' -Footer 'Enter = Aktion, Esc = zurueck'
        if ($null -eq $sel) { return }
        switch ($sel) {
            'install' {
                $r = Install-SysPilotPwsh
                if ($r) { Write-Host "  installiert: v$($r.Version)" -ForegroundColor Green } else { Write-Host '  Installation unklar - ggf. neu starten noetig.' -ForegroundColor Yellow }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            { $_ -in 'auto','ps7','ps51' } {
                Set-SysPilotConfigValue -Section 'Start' -Key 'PwshMode' -Value $sel
                Write-Host "  Modus gesetzt: $sel" -ForegroundColor Green
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'test' {
                $info = Get-SysPilotPwshInfo
                if (-not $info) { Write-Host '  PS7 nicht gefunden - zuerst installieren.' -ForegroundColor Red; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; continue }
                $gui = Join-Path (Split-Path $PSScriptRoot) 'SysPilot-GUI.ps1'
                Write-Host "  Starte SysPilot-GUI unter PS7: $($info.Path)" -ForegroundColor Cyan
                Start-Process $info.Path -ArgumentList '-STA','-NoProfile','-File',"`"$gui`""
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
        }
    }
}

function Get-SysPilotModuleLinks {
    <# Verwandte Module pro Tool-Key - fuer Querverweise in Menues und
       Herbert-Vorschlaegen (siehe AGENTS.md "Herbert-, Status- &
       Verzahnungs-Integration"). Gibt @{Key;Label;Tag} zurueck. #>
    param([Parameter(Mandatory)][string]$Module)
    $map = @{
        'carecenter'  = @(@{Key='tweakstudio';Label='Tweak-Studio'},@{Key='reggallery';Label='Registry-Galerie'},@{Key='privacyfix';Label='PrivacyFix (Datenschutz-Tweaks)'},@{Key='cleanup';Label='Cleanup'},@{Key='startup';Label='Startup-Manager'},@{Key='updates';Label='Softwarecenter'},@{Key='storage';Label='Speicher-Analyse'})
        'tweakstudio' = @(@{Key='reggallery';Label='Registry-Galerie (.reg-Dateien)'},@{Key='privacyfix';Label='PrivacyFix'},@{Key='carecenter';Label='Systempflege-Center'},@{Key='startup';Label='Startup-Manager'},@{Key='sysinfo';Label='Systeminfo'})
        'reggallery'  = @(@{Key='tweakstudio';Label='Tweak-Studio'},@{Key='carecenter';Label='Systempflege-Center'},@{Key='privacyfix';Label='PrivacyFix'},@{Key='hosts';Label='Hosts-Editor'})
        'cleanup'     = @(@{Key='carecenter';Label='Systempflege-Center'},@{Key='storage';Label='Speicher-Analyse'},@{Key='bloat';Label='Bloatware-Manager'},@{Key='privacyfix';Label='PrivacyFix'})
        'regclean'    = @(@{Key='carecenter';Label='Systempflege-Center'},@{Key='uninstall';Label='Deinstallations-Center'},@{Key='privacyfix';Label='PrivacyFix'})
        'privacyfix'  = @(@{Key='carecenter';Label='Systempflege-Center'},@{Key='hosts';Label='Hosts-Editor'},@{Key='cleanup';Label='Cleanup'})
        'privacy'     = @(@{Key='privacyfix';Label='PrivacyFix'},@{Key='cleanup';Label='Cleanup'},@{Key='carecenter';Label='Systempflege-Center'})
        'startup'     = @(@{Key='carecenter';Label='Systempflege-Center'},@{Key='services';Label='Dienst-Manager'},@{Key='procs';Label='Task-Manager'},@{Key='boot';Label='Boot-Analyse'})
        'smartdrv'    = @(@{Key='drvstudio';Label='DrvStudio'},@{Key='hardware';Label='PC-Analyse'},@{Key='updates';Label='Softwarecenter'})
        'drvstudio'   = @(@{Key='smartdrv';Label='Treiber-Suche'},@{Key='hardware';Label='PC-Analyse'},@{Key='drivers';Label='Treiber-Werkstatt'})
        'updates'     = @(@{Key='appstore';Label='Megastore'},@{Key='appsearch';Label='Programm-Suche'},@{Key='dlfind';Label='Download-Suche'},@{Key='smartdownload';Label='SmartDownload'})
        'appstore'    = @(@{Key='updates';Label='Softwarecenter'},@{Key='appsearch';Label='Programm-Suche'},@{Key='dlfind';Label='Download-Suche'})
        'dlfind'      = @(@{Key='smartdownload';Label='SmartDownload'},@{Key='appsearch';Label='Programm-Suche'},@{Key='updates';Label='Softwarecenter'})
        'smartdownload'= @(@{Key='dlfind';Label='Download-Suche'},@{Key='updates';Label='Softwarecenter'},@{Key='appstore';Label='Megastore'})
        'appsearch'   = @(@{Key='updates';Label='Softwarecenter'},@{Key='appstore';Label='Megastore'},@{Key='dlfind';Label='Download-Suche'})
        'storage'     = @(@{Key='carecenter';Label='Systempflege-Center'},@{Key='cleanup';Label='Cleanup'},@{Key='health';Label='Health-Monitor'})
        'health'      = @(@{Key='hardware';Label='PC-Analyse'},@{Key='storage';Label='Speicher-Analyse'},@{Key='procs';Label='Task-Manager'},@{Key='smarthealth';Label='Smart Health'})
        'hardware'    = @(@{Key='health';Label='Health-Monitor'},@{Key='drvstudio';Label='DrvStudio'},@{Key='smartdrv';Label='Treiber-Suche'})
        'procs'       = @(@{Key='health';Label='Health-Monitor'},@{Key='startup';Label='Startup-Manager'},@{Key='memory';Label='RAM freigeben'})
        'dns'         = @(@{Key='netrepair';Label='Netzwerk-Reparatur'},@{Key='adapters';Label='Netzwerkadapter'},@{Key='hosts';Label='Hosts-Editor'})
        'kiassist'    = @(@{Key='herbert';Label='Pilot Herbert'},@{Key='mcp';Label='MCP-Server'},@{Key='herbertapimenu';Label='Herbert-API'})
        'checkup'     = @(@{Key='carecenter';Label='Systempflege-Center'},@{Key='cleanup';Label='Cleanup'},@{Key='health';Label='Health-Monitor'})
        'uninstall'   = @(@{Key='carecenter';Label='Systempflege-Center'},@{Key='bloat';Label='Bloatware-Manager'},@{Key='cleanup';Label='Cleanup'})
        'cloudflare'  = @(@{Key='dns';Label='DNS-Manager'},@{Key='netrepair';Label='Netzwerk-Reparatur'},@{Key='adapters';Label='Netzwerkadapter'})
        'herbertonboard' = @(@{Key='kiassist';Label='KI-Assistenz'},@{Key='herbert';Label='Pilot Herbert'},@{Key='kimgr';Label='Herbert-Manager'})
    }
    $links = @()
    foreach ($k in @($map[$Module])) { $links += @{ Key=$k.Key; Label=$k.Label; Tag=$k.Key } }
    return $links
}

Export-ModuleMember -Function ConvertTo-SysPilotArgString, Test-SysPilotAdmin, Assert-SysPilotAdmin, Restart-SysPilotElevated,
    Write-SysPilotLog, Write-SysPilotDebug, Get-SysPilotLogFiles, Get-SysPilotConfig, Reset-SysPilotConfig, Set-SysPilotConfigValue, Test-NameMatch,
    Get-SysPilotProcessByName, New-SysPilotBackup, Get-SysPilotBackupDir, Get-SysPilotBackups, Restore-SysPilotServices,
    Write-SysPilotHeader, Read-SysPilotChoice, Read-SysPilotInput, Show-SysPilotWpfInput, Set-SysPilotWindowAutoSize, Set-SysPilotWindowForeground, Register-SysPilotWindowChrome, Find-SysPilotFreeWindowPosition, Get-SysPilotOccupiedWindowRects, Show-SysPilotRunCommand, Set-SysPilotRichText, Confirm-SysPilot, Show-SysPilotArrowMenu, Show-SysPilotMultiSelectMenu,
    Clear-SysPilotPendingKeys,
    Initialize-SysPilotConsoleInput, Restore-SysPilotConsoleInput, Read-SysPilotMenuEvent, Clear-SysPilotConsoleInputBuffer, Read-SysPilotYesNo, Set-SysPilotConsoleCursor,
    Save-SysPilotUrlToFile, Test-SysPilotLaunchablePath, Invoke-SysPilotMonitoredProcess, Read-SysPilotFileTailLine,
    Get-SysPilotModuleLinks,
    Find-SysPilotJsonSection, Get-SysPilotJsonSectionText, Get-SysPilotChromiumExtensionSettings,
    Get-SysPilotJsonChildProperties, ConvertFrom-SysPilotJsonScalar, Get-SysPilotConsoleViewport,
    Read-SysPilotFileRaw, Write-SysPilotFileRaw,
    Remove-SysPilotJsonPropertyText, Remove-SysPilotPrefExtensionEntry,
    Write-SysPilotProgress, Complete-SysPilotProgress, Get-SysPilotShortcutPaths, Set-SysPilotShortcutRunAs,
    Test-SysPilotGamingActive, Get-SysPilotPortableAppsDir, Get-SysPilotLocalSearchDirs,
    Get-SysPilotAutoFixStampPath, Test-SysPilotAutoFixDue, Save-SysPilotAutoFixStamp,
    Import-SysPilotModule, Get-SysPilotWpfPalette, Set-SysPilotWpfDarkTheme,
    Show-SysPilotDownloadDialog, Invoke-SysPilotFileDownload,
    Add-SysPilotAssistantToWindow, Write-SysPilotPanelLog, Set-SysPilotPanelProgress,
    Set-SysPilotMenuWindowPosition, Get-SysPilotConsoleWindowRect, Test-SysPilotWpfMenuAvailable,
    Register-SysPilotProtocol, Unregister-SysPilotProtocol,
    Test-SysPilotWindowAlreadyOpen, Show-SysPilotStepGuide,
    Get-SysPilotPathEntries, Get-SysPilotToolPathCandidates, Repair-SysPilotPath, Show-SysPilotPathMenu,
    Get-SysPilotPwshInfo, Get-SysPilotShellMode, Get-SysPilotPreferredShell, Install-SysPilotPwsh, Show-SysPilotPwshMenu,
    Get-SysPilotAria2Path, Get-SysPilotYtDlpPath, Install-SysPilotAria2,
    Test-SysPilotRangeSupport, Convert-SysPilotSizeStr,
    Invoke-SysPilotSegmentedDownload, Invoke-SysPilotAria2Download,
    Invoke-SysPilotTorrentDownload, Invoke-SysPilotVideoDownload,
    Test-SysPilotSpecialDownloadUrl, Invoke-SysPilotSmartFileDownload,
    Resolve-SysPilotExePath, Get-SysPilotWingetExeLocal,
    Test-SysPilotInternet, Wait-SysPilotInternet, Invoke-SysPilotHttpRequest,
    Install-SysPilotYtDlp, Get-SysPilotFfmpegPath, Install-SysPilotFfmpeg,
    Ensure-SysPilotPrereqs
