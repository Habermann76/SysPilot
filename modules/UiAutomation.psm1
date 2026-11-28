# =====================================================================
# UiAutomation.psm1 - WPF-Fenster fernsteuern (UI Automation)
# Fuer Herbert und Diagnose: Fenster nach Titel finden, Controls
# auflisten, Buttons klicken, Text setzen/lesen, Haeckchen toggeln.
# Laedt UIAutomationClient/UIAutomationTypes nach Bedarf.
# =====================================================================

$script:UiaLoaded = $false
function Initialize-SysPilotUia {
    if ($script:UiaLoaded) { return }
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes -ErrorAction Stop
    $script:UiaLoaded = $true
}

function Find-SysPilotUiWindow {
    <# Sucht ein Top-Level-Fenster per Titel (teilstring, case-insens.).
       Gibt AutomationElement oder $null zurueck. #>
    param([Parameter(Mandatory)][string]$TitleLike)
    Initialize-SysPilotUia
    $AE = [System.Windows.Automation.AutomationElement]
    $root = $AE::RootElement
    $wins = $root.FindAll([System.Windows.Automation.TreeScope]::Children,
        [System.Windows.Automation.Condition]::TrueCondition)
    $exact = @(); $prefix = @(); $contains = @()
    foreach ($w in $wins) {
        try {
            $n = [string]$w.Current.Name
            if (-not $n) { continue }
            if ($n -ieq $TitleLike) { $exact += $w }
            elseif ($n -ilike "$TitleLike*") { $prefix += $w }
            elseif ($n -ilike "*$TitleLike*") { $contains += $w }
        } catch {}
    }
    # Exakter Treffer > Prefix > Enthalten; bei Gleichstand kuerzester Titel
    foreach ($set in @($exact, $prefix, $contains)) {
        if ($set.Count -eq 0) { continue }
        $best = $set | Sort-Object { ([string]$_.Current.Name).Length } | Select-Object -First 1
        return $best
    }
    return $null
}

function Get-SysPilotUiElements {
    <# Listet Controls eines Fensters (oder Elemements) auf.
       -ControlType z.B. 'Button','Edit','CheckBox','Text','TabItem','ListItem'
       -NameLike filtert zusaetzlich auf Namen. #>
    param(
        [Parameter(Mandatory)]$Root,
        [string]$ControlType = '',
        [string]$NameLike = '',
        [int]$Max = 200
    )
    Initialize-SysPilotUia
    $AE = [System.Windows.Automation.AutomationElement]
    $conds = @()
    if ($ControlType) {
        $ct = [System.Windows.Automation.ControlType]::$ControlType
        if (-not $ct) { throw "Unbekannter ControlType '$ControlType'" }
        $conds += (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $ct))
    }
    if ($NameLike) {
        $conds += (New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, $NameLike, [System.Windows.Automation.PropertyConditionFlags]::IgnoreCase))
    }
    $cond = $(if ($conds.Count -eq 0) { [System.Windows.Automation.Condition]::TrueCondition }
              elseif ($conds.Count -eq 1) { $conds[0] }
              else { New-Object System.Windows.Automation.AndCondition(, $conds) })
    $found = @($Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond))
    $out = @()
    foreach ($e in ($found | Select-Object -First $Max)) {
        try {
            $out += [pscustomobject]@{
                Type   = [string]$e.Current.ControlType.ProgrammaticName -replace 'ControlType\.',''
                Name   = [string]$e.Current.Name
                AutoId = [string]$e.Current.AutomationId
                Offscreen = [bool]$e.Current.IsOffscreen
                Element = $e
            }
        } catch {}
    }
    return $out
}

function Invoke-SysPilotUiClick {
    <# Klickt ein Control: Button ueber InvokePattern, sonst
       LegacyIAccessible DoDefaultAction, sonst Toggle fuer CheckBox. #>
    param(
        [Parameter(Mandatory)]$Element,
        [string]$Via = 'auto'
    )
    Initialize-SysPilotUia
    if ($Via -eq 'auto' -or $Via -eq 'invoke') {
        try {
            $p = $Element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
            if ($p) { $p.Invoke(); return $true }
        } catch {}
    }
    if ($Via -eq 'auto' -or $Via -eq 'toggle') {
        try {
            $p = $Element.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
            if ($p) { $p.Toggle(); return $true }
        } catch {}
    }
    try {
        $p = $Element.GetCurrentPattern([System.Windows.Automation.LegacyIAccessiblePattern]::Pattern)
        if ($p) { $p.DoDefaultAction(); return $true }
    } catch {}
    return $false
}

function Set-SysPilotUiText {
    <# Setzt den Wert eines Edit-Controls (ValuePattern). #>
    param([Parameter(Mandatory)]$Element, [Parameter(Mandatory)][string]$Value)
    Initialize-SysPilotUia
    $p = $Element.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    if (-not $p) { throw 'Control unterstuetzt kein ValuePattern' }
    $p.SetValue($Value)
    return $true
}

function Read-SysPilotUiText {
    <# Liest Text-Inhalte: ValuePattern (Edit/TextBox) oder Name (TextBlock).
       Optional -Tail N liefert die letzten N Zeilen (LogBox). #>
    param([Parameter(Mandatory)]$Element, [int]$Tail = 0)
    Initialize-SysPilotUia
    $txt = $null
    try {
        $p = $Element.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
        if ($p) { $txt = [string]$p.Current.Value }
    } catch {}
    if ($null -eq $txt) {
        try {
            $tp = $Element.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)
            if ($tp) { $txt = [string]$tp.DocumentRange.GetText(-1) }
        } catch {}
    }
    if ($null -eq $txt) { $txt = [string]$Element.Current.Name }
    if ($Tail -gt 0 -and $txt) {
        $lines = $txt -split "`r?`n" | Where-Object { $_.Trim() -ne '' }
        $txt = ($lines | Select-Object -Last $Tail) -join "`n"
    }
    return $txt
}

function Find-SysPilotUiElement {
    <# Convenience: sucht erstes sichtbares Control in einem Fenster
       per Typ + NameLike (Teilstring-Match, case-insensitiv).
       Bevorzugt exakte Treffer, dann sichtbare, dann erste. #>
    param(
        [Parameter(Mandatory)]$Win,
        [Parameter(Mandatory)][string]$ControlType,
        [string]$NameLike = ''
    )
    $els = @(Get-SysPilotUiElements -Root $Win -ControlType $ControlType -Max 500)
    if ($NameLike) {
        $els = @($els | Where-Object { $_.Name -and $_.Name -like "*$NameLike*" })
    }
    if ($els.Count -eq 0) { return $null }
    $vis = @($els | Where-Object { -not $_.Offscreen })
    $pool = $(if ($vis.Count) { $vis } else { $els })
    # Exakter Treffer zuerst
    if ($NameLike) {
        $exact = @($pool | Where-Object { $_.Name -eq $NameLike })
        if ($exact.Count) { return $exact[0].Element }
    }
    return $pool[0].Element
}

# ===== Lokale MCP-Werkzeuge (Herbert kann SysPilot-Fenster fernsteuern) =====

function Get-SysPilotLocalMcpToolDefs {
    <# OpenAi-Tool-Definitionen fuer den pseudo-lokalen MCP-Server
       'syspilot-local' - gleiche Form wie Get-SysPilotMcpChatToolDefs. #>
    $obj = { param($props,$req) @{ type='object'; properties=$props; required=$req } }
    return @(
        [pscustomobject]@{ OpenAiName='syspilot_uia_find_window'; Server='syspilot-local'; Tool='uia_find_window'
            Description='Findet ein offenes SysPilot-Fenster per Titelausschnitt (z.B. "Softwarecenter", "Megastore", "Driver Studio", "Download", "App-Suche").'
            Parameters=& $obj @{ TitleLike=@{type='string';description='Titelausschnitt des Fenstertitels'} } @('TitleLike') },
        [pscustomobject]@{ OpenAiName='syspilot_uia_list_controls'; Server='syspilot-local'; Tool='uia_list_controls'
            Description='Listet die Controls eines Fensters auf (Buttons, Edit-Felder, Checkboxen, Listen, Text/Log). Mit ControlType und NameLike filterbar.'
            Parameters=& $obj @{ TitleLike=@{type='string'}; ControlType=@{type='string';description='Button|Edit|CheckBox|Text|Document|ListItem|TabItem|ComboBox'}; NameLike=@{type='string';description='Namensfilter (Teilstring)'}; Max=@{type='integer'} } @('TitleLike') },
        [pscustomobject]@{ OpenAiName='syspilot_uia_click'; Server='syspilot-local'; Tool='uia_click'
            Description='Klickt ein Control in einem Fenster: Button (Invoke), CheckBox (Toggle), oder Element mit Default-Action. NameLike ist Teilstring-Match.'
            Parameters=& $obj @{ TitleLike=@{type='string'}; ControlType=@{type='string';description='Meist Button oder CheckBox'}; NameLike=@{type='string'} } @('TitleLike','ControlType') },
        [pscustomobject]@{ OpenAiName='syspilot_uia_set_text'; Server='syspilot-local'; Tool='uia_set_text'
            Description='Setzt den Text eines Edit-Controls (ValuePattern).'
            Parameters=& $obj @{ TitleLike=@{type='string'}; ControlType=@{type='string';description='Meist Edit'}; NameLike=@{type='string'}; Value=@{type='string'} } @('TitleLike','Value') },
        [pscustomobject]@{ OpenAiName='syspilot_uia_read_text'; Server='syspilot-local'; Tool='uia_read_text'
            Description='Liest Text aus einem Control: Edit-Feld, TextBlock, LogBox (Document) oder Konsolenfenster. Tail=N liefert die letzten N Zeilen.'
            Parameters=& $obj @{ TitleLike=@{type='string'}; ControlType=@{type='string';description='Edit|Text|Document'}; NameLike=@{type='string'}; Tail=@{type='integer'} } @('TitleLike') }
    )
}

function Invoke-SysPilotLocalMcpTool {
    <# Lokaler Werkzeug-Dispatch fuer 'syspilot-local'.
       Gibt das gleiche Format wie Invoke-SysPilotMcpTool zurueck. #>
    param([Parameter(Mandatory)][string]$Tool, $Arguments = @{})
    $a = @{}
    if ($Arguments -is [hashtable]) { $a = $Arguments }
    elseif ($Arguments -is [string]) {
        try { $Arguments | ConvertFrom-Json | ForEach-Object { $_.PSObject.Properties } | ForEach-Object { $a[$_.Name] = $_.Value } } catch {}
    } elseif ($Arguments) { foreach ($k in $Arguments.Keys) { $a[$k] = $Arguments[$k] } }
    try {
        # Fensternamen aufloesen
        $win = $null
        if ($Tool -ne 'uia_find_window') {
            $tl = [string]$a.TitleLike
            if (-not $tl) { return @{Ok=$false;Text='';Error='TitleLike fehlt'} }
            $win = Find-SysPilotUiWindow -TitleLike $tl
            if (-not $win) { return @{Ok=$false;Text='';Error="Fenster nicht gefunden: $tl"} }
        }
        switch ($Tool) {
            'uia_find_window' {
                $tl = [string]$a.TitleLike
                if (-not $tl) { return @{Ok=$false;Text='';Error='TitleLike fehlt'} }
                $w = Find-SysPilotUiWindow -TitleLike $tl
                if (-not $w) { return @{Ok=$false;Text='';Error="Fenster nicht gefunden: $tl"} }
                return @{Ok=$true;Text="Gefunden: $($w.Current.Name)";Error=''}
            }
            'uia_list_controls' {
                $ct = [string]$a.ControlType; $nl = [string]$a.NameLike; $mx = [int]$(if($a.Max){$a.Max}else{80})
                $els = @(Get-SysPilotUiElements -Root $win -ControlType $ct -Max ([Math]::Max($mx,200)))
                if ($nl) { $els = @($els | Where-Object { $_.Name -and $_.Name -like "*$nl*" }) }
                $els = @($els | Select-Object -First $mx)
                $lines = @($els | ForEach-Object { "{0} | {1} | {2}" -f $_.Type, $_.Name, $_.AutoId } | Where-Object { $_.Trim() -ne '||' })
                return @{Ok=$true;Text=($lines -join "`n");Error="$($els.Count) Control(s)"}
            }
            'uia_click' {
                $ct = [string]$a.ControlType; $nl = [string]$a.NameLike
                if (-not $ct) { return @{Ok=$false;Text='';Error='ControlType fehlt (z.B. Button, CheckBox)'} }
                $el = Find-SysPilotUiElement -Win $win -ControlType $ct -NameLike $nl
                if (-not $el) {
                    # Teilstring-Fallback: alle des Typs, Name -like *nl*
                    $cands = @(Get-SysPilotUiElements -Root $win -ControlType $ct -Max 500 | Where-Object { -not $_.Offscreen -and (-not $nl -or $_.Name -like "*$nl*") })
                    if ($cands.Count -eq 0) { return @{Ok=$false;Text='';Error="Kein sichtbares '$ct' mit Name '*$nl*' in '$($win.Current.Name)'"} }
                    $el = $cands[0].Element
                }
                $ok = Invoke-SysPilotUiClick -Element $el
                return @{Ok=$ok;Text=$(if($ok){"Geklickt: $($el.Current.Name)"}else{'Kein Klick-Pattern'});Error=''}
            }
            'uia_set_text' {
                $ct = [string]$a.ControlType; if(-not $ct){$ct='Edit'}
                $nl = [string]$a.NameLike; $val = [string]$a.Value
                $el = Find-SysPilotUiElement -Win $win -ControlType $ct -NameLike $nl
                if (-not $el) { return @{Ok=$false;Text='';Error="Kein '$ct' mit Name '*$nl*' gefunden"} }
                Set-SysPilotUiText -Element $el -Value $val | Out-Null
                return @{Ok=$true;Text="Text gesetzt: $($el.Current.Name)";Error=''}
            }
            'uia_read_text' {
                $ct = [string]$a.ControlType; if(-not $ct){$ct='Document'}
                $nl = [string]$a.NameLike; $tail = [int]$(if($null -ne $a.Tail){$a.Tail}else{0})
                $el = Find-SysPilotUiElement -Win $win -ControlType $ct -NameLike $nl
                if (-not $el) { return @{Ok=$false;Text='';Error="Kein '$ct' mit Name '*$nl*' gefunden"} }
                $txt = Read-SysPilotUiText -Element $el -Tail $tail
                if ($null -eq $txt) { $txt='' }
                if ($txt.Length -gt 8000) { $txt = $txt.Substring(0,8000) + "`n... (gekuerzt)" }
                return @{Ok=$true;Text=$txt;Error=''}
            }
            default { return @{Ok=$false;Text='';Error="Unbekanntes lokales Werkzeug: $Tool"} }
        }
    } catch {
        return @{Ok=$false;Text='';Error=$_.Exception.Message}
    }
}

Export-ModuleMember -Function Find-SysPilotUiWindow, Get-SysPilotUiElements,
    Invoke-SysPilotUiClick, Set-SysPilotUiText, Read-SysPilotUiText,
    Find-SysPilotUiElement, Get-SysPilotLocalMcpToolDefs,
    Invoke-SysPilotLocalMcpTool
