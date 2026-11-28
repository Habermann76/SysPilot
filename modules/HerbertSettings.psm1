# HerbertSettings.psm1 - KI-Einstellungs-Assistent ("Herbert Settings").
#
#idea: Herbert analysiert das System (Fakten: Admin, RAM, Akku,
#      Gaming) und priorisiert die noch inaktiven Tweaks aus
#      SystemTuning + PrivacyFix. Das WPF-Fenster zeigt die
#      Empfehlungen sortiert, jeder Eintrag ist per Klick
#      anwendbar UND rueckgaengig (Toggle). Kein Ratespiel:
#      nur Tweaks, die in den Modulen tatsaechlich existieren.
#
#Kandidaten-Quellen (wiederverwendet, nichts dupliziert):
#  - Get-SysPilotTuningStatus / Set-SysPilotTuningItem  (SystemTuning)
#  - Get-SysPilotPrivacyStatus / Set-SysPilotPrivacyItem (PrivacyFix,
#    -NoConfirm fuer WPF-Bestaetigung)
#Herbert-Rangfolge via Invoke-SysPilotAiChat; bei nicht
#erreichbarem Provider deterministisches Fallback (Kategorie-
#Prioritaet Datenschutz > Werbung > System > Netzwerk > Explorer).

$script:HsCatPriority = @('Datenschutz','Werbung','System','Netzwerk','Explorer')

function Get-SysPilotSystemFacts {
    <# Kurze System-Fakten fuer den Herbert-Prompt (deutsch, kurz). #>
    $facts = @()
    $facts += "Admin-Rechte: $(if (Test-SysPilotAdmin) {'ja'} else {'nein'})"
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $facts += ("RAM: {0:N1} GB gesamt, {1:N1} GB frei" -f ($os.TotalVisibleMemorySize/1MB), ($os.FreePhysicalMemory/1MB))
        $facts += "OS: $($os.Caption) (Build $($os.BuildNumber))"
    } catch { }
    try {
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        if ($cpu) { $facts += "CPU: $($cpu.Name.Trim()) - $($cpu.NumberOfCores) Kerne" }
    } catch { }
    try { Import-SysPilotModule PowerPlans; if (Test-SysPilotOnBattery) { $facts += 'Stromquelle: Akku (mobil)' } else { $facts += 'Stromquelle: Netzteil/Desktop' } } catch { }
    try { Import-SysPilotModule PowerPlans; if (Test-SysPilotGamingActive) { $facts += 'Modus: Gaming/Performance aktiv' } } catch { }
    try {
        $bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($bat) { $facts += ("Akku-Ladung: {0}%" -f $bat.EstimatedChargeRemaining) }
    } catch { }
    return $facts
}

function Get-SysPilotSettingEntry {
    <# Liefert EINEN Tweak (egal welcher Status) alsheitliches
       Objekt: @{Id;Source;Key;Tweak;State;Cat;Name;Desc;Admin}. #>
    param([Parameter(Mandatory)][string]$Id)
    $src = ($Id -split ':',2)[0]; $key = ($Id -split ':',2)[1]
    try {
        Import-SysPilotModule SystemTuning
        foreach ($s in @(Get-SysPilotTuningStatus)) {
            if ($s.Tweak.Key -eq $key) {
                $t = $s.Tweak
                return @{ Id=$Id; Source='systemtuning'; Key=$key; Tweak=$t; State=[string]$s.State
                          Cat=[string]$t.Cat; Name=[string]$t.Name; Desc=[string]$t.Desc; Admin=[bool]$t.Admin }
            }
        }
    } catch { }
    try {
        Import-SysPilotModule PrivacyFix
        foreach ($s in @(Get-SysPilotPrivacyStatus)) {
            if ($s.Tweak.Key -eq $key) {
                $t = $s.Tweak
                return @{ Id=$Id; Source='privacyfix'; Key=$key; Tweak=$t; State=[string]$s.State
                          Cat=[string]$t.Cat; Name=[string]$t.Name; Desc=[string]$t.Desc; Admin=[bool]$t.Admin }
            }
        }
    } catch { }
    return $null
}

function Get-SysPilotSettingCandidates {
    <# Alle Tweaks, die NOCH NICHT im Zielzustand sind (= Kandidaten
       fuer den Assistenten). Gibt sortierte Objekte zurueck. #>
    $out = @()
    try {
        Import-SysPilotModule SystemTuning
        foreach ($s in @(Get-SysPilotTuningStatus)) {
            if ($s.State -eq 'AN') { continue }
            $t = $s.Tweak
            $out += [pscustomobject]@{ Id=('tune:' + $t.Key); Source='systemtuning'; Key=[string]$t.Key
                Cat=[string]$t.Cat; Name=[string]$t.Name; Desc=[string]$t.Desc
                State=[string]$s.State; Admin=[bool]$t.Admin; Tweak=$t }
        }
    } catch { }
    try {
        Import-SysPilotModule PrivacyFix
        foreach ($s in @(Get-SysPilotPrivacyStatus)) {
            if ($s.State -eq 'AN') { continue }
            $t = $s.Tweak
            $out += [pscustomobject]@{ Id=('priv:' + $t.Key); Source='privacyfix'; Key=[string]$t.Key
                Cat=[string]$t.Cat; Name=[string]$t.Name; Desc=[string]$t.Desc
                State=[string]$s.State; Admin=[bool]$t.Admin; Tweak=$t }
        }
    } catch { }
    return $out
}

function Set-SysPilotSettingItem {
    <# Wendet einen Tweak an (oder macht ihn rueckgaengig - die
       Setter toggeln je nach aktuellem Status).
       Gibt @{Ok;State;Error} zurueck. #>
    param(
        [Parameter(Mandatory)]$Entry,
        [switch]$Silent
    )
    if ($Entry.Admin -and -not (Test-SysPilotAdmin)) {
        return @{ Ok=$false; State=''; Error='Administrator-Rechte noetig' }
    }
    try {
        if ($Entry.Source -eq 'systemtuning') {
            Import-SysPilotModule SystemTuning
            $fresh = Get-SysPilotTuningStatus | Where-Object { $_.Tweak.Key -eq $Entry.Key } | Select-Object -First 1
            if (-not $fresh) { return @{ Ok=$false; State=''; Error='Tweak nicht gefunden' } }
            Set-SysPilotTuningItem -Tweak $fresh | Out-Null
        } else {
            Import-SysPilotModule PrivacyFix
            Set-SysPilotPrivacyItem -Tweak $Entry.Tweak -NoConfirm:$Silent | Out-Null
        }
        Start-Sleep -Milliseconds 300
        $after = Get-SysPilotSettingEntry -Id $Entry.Id
        return @{ Ok=$true; State=($(if ($after -and $after.State -eq 'AN') {'AN'} else {'aus'})); Error='' }
    } catch {
        return @{ Ok=$false; State=''; Error=$_.Exception.Message }
    }
}

function Invoke-SysPilotSettingsAdvisor {
    <# Herbert priorisiert die Kandidaten. Rueckgabe:
       @{Ok;Picks=@(Ids in Reihenfolge);Text;Reason;UsedAi}. #>
    param(
        [object[]]$Candidates = @(),
        [int]$TopN = 12
    )
    if ($Candidates.Count -eq 0) { return @{ Ok=$true; Picks=@(); Text=''; Reason='Keine offenen Tweaks - alles bereits optimal.'; UsedAi=$false } }

    # Deterministisches Fallback (auch wenn Herbert fehlt)
    $fallback = @($Candidates | Sort-Object {
        $i = [array]::IndexOf($script:HsCatPriority, $_.Cat)
        if ($i -lt 0) { 99 } else { $i }
    }, Name | Select-Object -First $TopN)
    $fbIds = @($fallback | ForEach-Object { $_.Id })

    try {
        Import-SysPilotModule AiAssist
        $facts = (Get-SysPilotSystemFacts) -join '; '
        $list = ($Candidates | ForEach-Object { "$($_.Id) | $($_.Cat) | $($_.Name) | $($_.Desc)" }) -join "`n"
        $prompt = @"
Du bist Herbert, der Einstellungs-Assistent von SysPilot. Empfehle System-/Datenschutz-Tweaks fuer DIESES System.

System: $facts

Offene Kandidaten (id | kategorie | name | beschreibung):
$list

Waehle die $TopN sinnvollsten aus (Datenschutz+Werbung haben Prioritaet,
aber System-Tweaks sind bei wenig RAM/Gaming besonders wertvoll;
Admin-Tweaks nur wenn sie wirklich Sinn ergeben). Antworte KURZ:
1. Eine Zeile 'ID: <id>' pro Empfehlung, beste zuerst (max. $TopN)
2. 2-3 Saetze Begruendung auf Deutsch.
"@
        $ai = Invoke-SysPilotAiChat -Prompt $prompt -TimeoutSec 60
        if (-not $ai.Ok) { return @{ Ok=$true; Picks=$fbIds; Text=''; Reason="Herbert nicht erreichbar ($($ai.Error)) - deterministische Reihenfolge."; UsedAi=$false } }
        $picks = @()
        foreach ($m in [regex]::Matches([string]$ai.Text, '(?im)^\s*ID:\s*([a-z]+:[a-z0-9\-_]+)')) {
            $id = $m.Groups[1].Value.Trim()
            if ($Candidates | Where-Object { $_.Id -eq $id } | Select-Object -First 1) { $picks += $id }
        }
        # Herbert-Treffer zuerst, Rest deterministisch nachgezogen
        $rest = @($fbIds | Where-Object { $picks -notcontains $_ })
        $all = @($picks + $rest) | Select-Object -First $TopN
        return @{ Ok=$true; Picks=$all; Text=[string]$ai.Text; Reason='Herbert-Bewertung'; UsedAi=$true }
    } catch {
        return @{ Ok=$true; Picks=$fbIds; Text=''; Reason="Herbert-Fehler: $($_.Exception.Message) - deterministische Reihenfolge."; UsedAi=$false }
    }
}

function Show-SysPilotSettingsAssistant {
    <# WPF-Fenster: Herbert-Empfehlungen als klickbare Liste.
       Jeder Eintrag: Anwenden / Rueckgaengig. #>
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
        Show-SysPilotSettingsAssistantMenu
        return
    }
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction SilentlyContinue
    $P = Get-SysPilotWpfPalette

    $cands = @(Get-SysPilotSettingCandidates)
    $facts = Get-SysPilotSystemFacts
    $adv = Invoke-SysPilotSettingsAdvisor -Candidates $cands -TopN 14

    # Fenster
    $win = New-Object System.Windows.Window
    if (Test-SysPilotWindowAlreadyOpen -Key 'syspilot-herbert-settings' -Win $win) { return }
    $win.Title = 'SysPilot - Herbert Einstellungs-Assistent'
    $win.Width = 980; $win.Height = 640
    $win.MinWidth = 760; $win.MinHeight = 480
    $win.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom($P.Bg)
    $win.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom($P.Fg)
    $win.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe UI')
    $win.WindowStartupLocation = 'CenterScreen'

    $root = New-Object System.Windows.Controls.DockPanel
    $root.LastChildFill = $true
    $win.Content = $root

    # Kopf: Titel + Fakten + Status
    $head = New-Object System.Windows.Controls.StackPanel
    $head.Margin = '16,12,16,8'
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = 'Herbert Einstellungs-Assistent'
    $t.FontSize = 22; $t.FontWeight = 'Bold'
    $t.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom($P.Accent)
    $head.Children.Add($t) | Out-Null
    $f = New-Object System.Windows.Controls.TextBlock
    $f.Text = ($facts -join '  |  ')
    $f.FontSize = 11; $f.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom($P.Muted)
    $f.TextWrapping = 'Wrap'; $f.Margin = '0,2,0,0'
    $head.Children.Add($f) | Out-Null
    $r = New-Object System.Windows.Controls.TextBlock
    $r.Text = $(if ($adv.UsedAi) { "Herbert: $($adv.Reason)" } else { "Hinweis: $($adv.Reason)" })
    $r.FontSize = 11; $r.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#FF80CBC4')
    $r.TextWrapping = 'Wrap'; $r.Margin = '0,2,0,0'
    $head.Children.Add($r) | Out-Null
    $root.Children.Add($head) | Out-Null

    # Fortschrittsbalken (versteckt bis noetig)
    $prog = New-Object System.Windows.Controls.ProgressBar
    $prog.Height = 4; $prog.IsIndeterminate = $true
    $prog.Visibility = 'Collapsed'
    $prog.VerticalAlignment = 'Bottom'
    $root.Children.Add($prog) | Out-Null
    # ProgressBar unten andocken: Order hoch
    $root.Children.Remove($prog) | Out-Null
    $prog.SetValue([System.Windows.Controls.DockPanel]::DockProperty, [System.Windows.Controls.Dock]::Bottom)
    $root.Children.Add($prog) | Out-Null

    # Hauptbereich: links Liste, rechts Herbert-Text
    $grid = New-Object System.Windows.Controls.Grid
    $grid.Margin = '16,0,16,10'
    $col1 = New-Object System.Windows.Controls.ColumnDefinition; $col1.Width = 'New' # liste
    $col2 = New-Object System.Windows.Controls.ColumnDefinition; $col2.Width = '360'
    $grid.ColumnDefinitions.Add($col1) | Out-Null
    $grid.ColumnDefinitions.Add($col2) | Out-Null
    $root.Children.Add($grid) | Out-Null

    # Linke Spalte: Ueberschrift + Scroll-Liste
    $left = New-Object System.Windows.Controls.StackPanel
    $leftGrid = New-Object System.Windows.Controls.Grid
    $leftRowH = New-Object System.Windows.Controls.RowDefinition; $leftRowH.Height = 'Auto'
    $leftRowL = New-Object System.Windows.Controls.RowDefinition; $leftRowL.Height = '*'
    $leftRowB = New-Object System.Windows.Controls.RowDefinition; $leftRowB.Height = 'Auto'
    $leftGrid.RowDefinitions.Add($leftRowH) | Out-Null
    $leftGrid.RowDefinitions.Add($leftRowL) | Out-Null
    $leftGrid.RowDefinitions.Add($leftRowB) | Out-Null

    $lh = New-Object System.Windows.Controls.TextBlock
    $lh.Text = "Empfehlungen ($($cands.Count) offene Tweaks gesamt)"
    $lh.FontSize = 13; $lh.FontWeight = 'Bold'
    $lh.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom($P.Fg)
    $lh.Margin = '0,0,0,6'
    $leftGrid.Children.Add($lh) | Out-Null
    [System.Windows.Controls.Grid]::SetRow($lh, 0) | Out-Null

    # Kandidaten-Map Id -> Objekt
    $candMap = @{}
    foreach ($c in $cands) { $candMap[$c.Id] = $c }
    $applied = @{}   # Id -> $true (in dieser Sitzung angewendet)

    $list = New-Object System.Windows.Controls.ListBox
    $list.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom($P.Panel)
    $list.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom($P.Fg)
    $list.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFrom($P.Border)
    $list.FontSize = 12
    $list.SetValue([System.Windows.Controls.Grid]::RowProperty, 1) | Out-Null
    $leftGrid.Children.Add($list) | Out-Null

    # Buttons unter Liste
    $btns = New-Object System.Windows.Controls.StackPanel
    $btns.Orientation = 'Horizontal'; $btns.Margin = '0,8,0,0'; $btns.HorizontalAlignment = 'Center'
    $btns.SetValue([System.Windows.Controls.Grid]::RowProperty, 2) | Out-Null
    $leftGrid.Children.Add($btns) | Out-Null

    $mkBtn = {
        param($label, $tip, $bg)
        $b = New-Object System.Windows.Controls.Button
        $b.Content = $label; $b.ToolTip = $tip
        $b.Padding = '14,6'; $b.Margin = '0,0,8,0'
        $b.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom($bg)
        $b.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#FF0B0B12')
        $b.BorderThickness = '0'; $b.Cursor = 'Hand'; $b.FontWeight = 'SemiBold'
        return $b
    }
    $btnApply = & $mkBtn 'Anwenden' 'Markierten Tweak aktivieren' $P.Accent
    $btnRevert = & $mkBtn 'Rueckgaengig' 'Markierten Tweak wieder deaktivieren (nur Sitzung)' '#FF78909C'
    $btnReassess = & $mkBtn 'Neu bewerten' 'Herbert analysiert erneut' '#FF455A64'
    foreach ($b in @($btnApply,$btnRevert,$btnReassess)) { $btns.Children.Add($b) | Out-Null }

    # Rechte Spalte: Herbert-Text
    $right = New-Object System.Windows.Controls.StackPanel
    $rh = New-Object System.Windows.Controls.TextBlock
    $rh.Text = 'Herbert sagt:'
    $rh.FontSize = 13; $rh.FontWeight = 'Bold'
    $rh.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom($P.Accent2)
    $rh.Margin = '0,0,0,6'
    $right.Children.Add($rh) | Out-Null
    $herbBox = New-Object System.Windows.Controls.RichTextBox
    $herbBox.IsReadOnly = $true
    $herbBox.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom($P.Panel)
    $herbBox.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom($P.Fg)
    $herbBox.FontSize = 12; $herbBox.Padding = '10'
    $herbBox.VerticalScrollBarVisibility = 'Auto'
    $right.Children.Add($herbBox) | Out-Null
    $grid.Children.Add($leftGrid) | Out-Null
    [System.Windows.Controls.Grid]::SetColumn($leftGrid, 0) | Out-Null
    $grid.Children.Add($right) | Out-Null
    [System.Windows.Controls.Grid]::SetColumn($right, 1) | Out-Null

    # Statuszeile unten
    $status = New-Object System.Windows.Controls.TextBlock
    $status.Text = ''
    $status.FontSize = 11
    $status.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom($P.Muted)
    $status.Margin = '16,0,16,10'
    $status.TextWrapping = 'Wrap'
    $root.Children.Add($status) | Out-Null

    # --- Befuellen ---
    if ($adv.Text) { Set-SysPilotRichText -RichBox $herbBox -Text $adv.Text }
    else {
        $tb = New-Object System.Windows.Documents.Run($adv.Reason)
        $tb.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom($P.Muted)
        $herbBox.Document.Blocks.Add((New-Object System.Windows.Documents.Paragraph($tb))) | Out-Null
    }

    $ordered = @($adv.Picks | ForEach-Object { $candMap[$_] } | Where-Object { $_ })
    # Kandidaten ohne Herbert-Pick ans Ende
    foreach ($c in $cands) { if ($adv.Picks -notcontains $c.Id) { $ordered += $c } }

    foreach ($c in $ordered) {
        $border = New-Object System.Windows.Controls.Border
        $border.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom($P.Panel)
        $border.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFrom($P.Border)
        $border.BorderThickness = '1'; $border.CornerRadius = '4'
        $border.Padding = '10,7'; $border.Margin = '0,0,0,6'
        $sp = New-Object System.Windows.Controls.StackPanel
        $line1 = New-Object System.Windows.Controls.StackPanel
        $line1.Orientation = 'Horizontal'
        $badge = New-Object System.Windows.Controls.Border
        $badge.CornerRadius = '3'; $badge.Padding = '5,1'; $badge.Margin = '0,0,8,0'
        $badge.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom($(if ($c.Cat -eq 'Datenschutz' -or $c.Cat -eq 'Werbung') { $P.BadgePriv } else { $P.BadgeSys }))
        $badgeText = New-Object System.Windows.Controls.TextBlock
        $badgeText.Text = $c.Cat; $badgeText.FontSize = 10; $badgeText.FontWeight = 'Bold'
        $badgeText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#FF0B0B12')
        $badge.Child = $badgeText
        $line1.Children.Add($badge) | Out-Null
        $nm = New-Object System.Windows.Controls.TextBlock
        $nm.Text = $c.Name; $nm.FontWeight = 'SemiBold'; $nm.FontSize = 13
        $nm.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom($P.Fg)
        $line1.Children.Add($nm) | Out-Null
        if ($c.Admin) {
            $adm = New-Object System.Windows.Controls.TextBlock
            $adm.Text = ' [Admin]'; $adm.FontSize = 10
            $adm.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#FFFFB74D')
            $line1.Children.Add($adm) | Out-Null
        }
        $sp.Children.Add($line1) | Out-Null
        $ds = New-Object System.Windows.Controls.TextBlock
        $ds.Text = $c.Desc; $ds.FontSize = 11; $ds.TextWrapping = 'Wrap'
        $ds.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom($P.Muted)
        $ds.Margin = '26,2,0,0'
        $sp.Children.Add($ds) | Out-Null
        $border.Child = $sp
        $border.Tag = $c.Id
        $border.Cursor = 'Hand'
        $list.Items.Add($border) | Out-Null
    }
    if ($ordered.Count -eq 0) {
        $none = New-Object System.Windows.Controls.TextBlock
        $none.Text = 'Keine offenen Tweaks - das System ist bereits optimal eingestellt.'
        $none.FontSize = 13; $none.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom($P.Muted)
        $none.Margin = '10'
        $list.Items.Add($none) | Out-Null
    }

    # Auswahl -> Id merken
    $script:hsSelId = $null
    $list.Add_SelectionChanged({
        param($s,$e)
        $it = $s.SelectedItem
        if ($it -is [System.Windows.Controls.Border]) { $script:hsSelId = [string]$it.Tag }
    })

    $setBusy = {
        param($on)
        $prog.Visibility = $(if ($on) {'Visible'} else {'Collapsed'})
        $btnApply.IsEnabled = -not $on; $btnRevert.IsEnabled = -not $on; $btnReassess.IsEnabled = -not $on
        $win.Cursor = $(if ($on) { [System.Windows.Input.Cursors]::Wait } else { $null })
    }

    $btnApply.Add_Click({
        $id = $script:hsSelId
        if (-not $id) { $status.Text = 'Bitte zuerst eine Empfehlung auswaehlen.'; return }
        $entry = Get-SysPilotSettingEntry -Id $id
        if (-not $entry) { $status.Text = "Unbekannter Eintrag: $id"; return }
        if ($entry.State -eq 'AN') { $status.Text = "'$($entry.Name)' ist bereits aktiv."; return }
        & $setBusy $true
        try {
            $res = Set-SysPilotSettingItem -Entry $entry -Silent
            if ($res.Ok) {
                $applied[$id] = $true
                $status.Text = "[OK] '$($entry.Name)' angewendet ($($res.State))."
                # Markierung im Element
                foreach ($li in $list.Items) {
                    if ($li -is [System.Windows.Controls.Border] -and $li.Tag -eq $id) {
                        $li.Opacity = 0.55
                        $li.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFrom($P.Ok)
                    }
                }
            } else {
                $status.Text = "[!] $($res.Error)"
            }
        } finally { & $setBusy $false }
    }.GetNewClosure())

    $btnRevert.Add_Click({
        $id = $script:hsSelId
        if (-not $id) { $status.Text = 'Bitte zuerst eine Empfehlung auswaehlen.'; return }
        if (-not $applied.ContainsKey($id)) { $status.Text = 'Nur in dieser Sitzung angewendete Tweaks sind rueckgaengig.'; return }
        $entry = Get-SysPilotSettingEntry -Id $id
        if (-not $entry) { $status.Text = "Unbekannter Eintrag: $id"; return }
        if ($entry.State -ne 'AN') { $status.Text = "'$($entry.Name)' ist nicht aktiv."; return }
        & $setBusy $true
        try {
            $res = Set-SysPilotSettingItem -Entry $entry -Silent
            if ($res.Ok) {
                $status.Text = "[OK] '$($entry.Name)' wieder deaktiviert."
                $applied.Remove($id)
                foreach ($li in $list.Items) {
                    if ($li -is [System.Windows.Controls.Border] -and $li.Tag -eq $id) {
                        $li.Opacity = 1.0
                        $li.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFrom($P.Border)
                    }
                }
            } else { $status.Text = "[!] $($res.Error)" }
        } finally { & $setBusy $false }
    }.GetNewClosure())

    $btnReassess.Add_Click({
        & $setBusy $true
        try {
            $c2 = @(Get-SysPilotSettingCandidates)
            $a2 = Invoke-SysPilotSettingsAdvisor -Candidates $c2 -TopN 14
            $status.Text = "Neu bewertet: $($c2.Count) offene Tweaks, Herbert $(if($a2.UsedAi){'aktiv'}else{'nicht erreichbar'})."
        } finally { & $setBusy $false }
    }.GetNewClosure())

    Set-SysPilotWindowAutoSize -Win $win -MinWidth 980 -MinHeight 640
    Add-SysPilotAssistantToWindow -Win $win -Context 'Show-SysPilotSettingsAssistant'
    $win.ShowDialog() | Out-Null
}

function Show-SysPilotSettingsAssistantMenu {
    <# Konsolen-Fallback: Fakten, Top-Empfehlungen, Apply pro Auswahl. #>
    Write-SysPilotHeader 'HERBERT EINSTELLUNGS-ASSISTENT'
    $facts = Get-SysPilotSystemFacts
    foreach ($f in $facts) { Write-Host "  $f" -ForegroundColor DarkGray }
    $cands = @(Get-SysPilotSettingCandidates)
    Write-Host "`n  Offene Tweaks: $($cands.Count)" -ForegroundColor Cyan
    $adv = Invoke-SysPilotSettingsAdvisor -Candidates $cands -TopN 12
    if ($adv.Text) { Write-Host "`n  Herbert: $($adv.Text)" -ForegroundColor DarkCyan }
    elseif ($adv.Reason) { Write-Host "`n  $($adv.Reason)" -ForegroundColor DarkGray }
    if ($adv.Picks.Count -eq 0) { Read-SysPilotChoice 'Weiter' | Out-Null; return }

    $pickObjs = @()
    foreach ($pid in $adv.Picks) {
        $m = $cands | Where-Object { $_.Id -eq $pid } | Select-Object -First 1
        if ($m) { $pickObjs += $m }
    }
    $items = @()
    foreach ($c in $pickObjs) {
        $adm = $(if ($c.Admin) { ' [Admin]' } else { '' })
        $items += @{ Label = "$($c.Cat) | $($c.Name)$adm - $($c.Desc)"; Color = 'White'; Tag = $c.Id }
    }
    $items += @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = 'back' }
    $sel = Show-SysPilotArrowMenu -Items $items -Title 'Empfehlung waehlen (Enter = anwenden)' -Footer 'Esc = zurueck'
    if ($null -eq $sel -or $sel -eq 'back') { return }
    $entry = Get-SysPilotSettingEntry -Id $sel
    if (-not $entry) { Write-Host '  [!] Eintrag nicht gefunden.' -ForegroundColor Red; return }
    if ($entry.State -eq 'AN') { Write-Host "  '$($entry.Name)' ist bereits aktiv." -ForegroundColor Green; Read-SysPilotChoice 'Weiter' | Out-Null; return }
    if (-not (Confirm-SysPilot "'$($entry.Name)' anwenden?`n$($entry.Desc)")) { return }
    $res = Set-SysPilotSettingItem -Entry $entry -Silent
    if ($res.Ok) { Write-Host "  [OK] $($entry.Name) -> $($res.State)" -ForegroundColor Green }
    else { Write-Host "  [!] $($res.Error)" -ForegroundColor Red }
    Read-SysPilotChoice 'Weiter' | Out-Null
}

function Invoke-SysPilotSettingsAssistant {
    <# Einstiegspunkt: WPF wenn STA, sonst Konsolen-Menue. #>
    if ([Threading.Thread]::CurrentThread.ApartmentState -eq 'STA') {
        Show-SysPilotSettingsAssistant
    } else {
        Show-SysPilotSettingsAssistantMenu
    }
}

Export-ModuleMember -Function Get-SysPilotSystemFacts, Get-SysPilotSettingEntry,
    Get-SysPilotSettingCandidates, Set-SysPilotSettingItem,
    Invoke-SysPilotSettingsAdvisor, Show-SysPilotSettingsAssistant,
    Show-SysPilotSettingsAssistantMenu, Invoke-SysPilotSettingsAssistant
