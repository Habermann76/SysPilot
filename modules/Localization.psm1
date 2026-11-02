# SysPilot - Localization: Sprachen + Einheiten (de/en, C/F)
#Requires -Version 5.1

$script:Strings = @{
    de = @{
        AppName = 'SysPilot'; Admin = 'ADMIN'; Restricted = 'eingeschraenkt'
        MenuHint = 'Pfeiltasten hoch/runter, Enter = ausfuehren, Esc = beenden'
        Back = 'Zurueck'; Cancel = 'Abbrechen'; Yes = 'Ja'; No = 'Nein'
        Temperature = 'Temperatur'; Celsius = 'Celsius'; Fahrenheit = 'Fahrenheit'
        Advertising = 'Werbung'; MsAds = 'Microsoft-Eigenwerbung'; PersonalizedAds = 'Personalisierte Werbung'
        On = 'An'; Off = 'Aus'; Enabled = 'Aktiviert'; Disabled = 'Deaktiviert'
        Settings = 'Einstellungen'; Language = 'Sprache'; TempUnit = 'Temperatureinheit'
        Done = 'Fertig'; Error = 'Fehler'; Warning = 'Warnung'; Info = 'Hinweis'
    }
    en = @{
        AppName = 'SysPilot'; Admin = 'ADMIN'; Restricted = 'restricted'
        MenuHint = 'Arrow keys up/down, Enter = run, Esc = quit'
        Back = 'Back'; Cancel = 'Cancel'; Yes = 'Yes'; No = 'No'
        Temperature = 'Temperature'; Celsius = 'Celsius'; Fahrenheit = 'Fahrenheit'
        Advertising = 'Advertising'; MsAds = 'Microsoft ads'; PersonalizedAds = 'Personalized ads'
        On = 'On'; Off = 'Off'; Enabled = 'Enabled'; Disabled = 'Disabled'
        Settings = 'Settings'; Language = 'Language'; TempUnit = 'Temperature unit'
        Done = 'Done'; Error = 'Error'; Warning = 'Warning'; Info = 'Info'
    }
}

function Get-SysPilotLang {
    $cfg = Get-SysPilotConfig
    $lang = $cfg.UI.Language
    if (-not $lang) { $lang = 'de' }
    return $lang
}

function Get-SysPilotString {
    param([Parameter(Mandatory)][string]$Key)
    $lang = Get-SysPilotLang
    $table = $script:Strings[$lang]
    if (-not $table) { $table = $script:Strings['de'] }
    if ($table.ContainsKey($Key)) { return $table[$Key] }
    if ($script:Strings['de'].ContainsKey($Key)) { return $script:Strings['de'][$Key] }
    return $Key
}

function Set-SysPilotLanguage {
    param([ValidateSet('de','en')][string]$Lang)
    $path = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'config.json'
    $json = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $json.UI) { $json | Add-Member -NotePropertyName UI -NotePropertyValue ([PSCustomObject]@{ Language = 'de'; TempUnit = 'C' }) -Force }
    $json.UI.Language = $Lang
    $json | ConvertTo-Json -Depth 10 | Set-Content $path -Encoding UTF8
    Reset-SysPilotConfig
}

function Get-SysPilotTempUnit {
    $cfg = Get-SysPilotConfig
    $u = $cfg.UI.TempUnit
    if (-not $u) { $u = 'C' }
    return $u
}

function Set-SysPilotTempUnit {
    param([ValidateSet('C','F')][string]$Unit)
    $path = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'config.json'
    $json = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $json.UI) { $json | Add-Member -NotePropertyName UI -NotePropertyValue ([PSCustomObject]@{ Language = 'de'; TempUnit = 'C' }) -Force }
    $json.UI.TempUnit = $Unit
    $json | ConvertTo-Json -Depth 10 | Set-Content $path -Encoding UTF8
    Reset-SysPilotConfig
}

function ConvertTo-SysPilotTemp {
    <# Wandelt Celsius in die gewaehlte Einheit um und gibt "Wert + Einheit" zurueck #>
    param([int]$Celsius)
    $unit = Get-SysPilotTempUnit
    if ($unit -eq 'F') {
        $f = [math]::Round($Celsius * 9 / 5 + 32)
        return @{ Value = $f; Unit = '°F'; Symbol = 'F' }
    }
    return @{ Value = $Celsius; Unit = '°C'; Symbol = 'C' }
}

Export-ModuleMember -Function Get-SysPilotLang, Get-SysPilotString, Set-SysPilotLanguage,
    Get-SysPilotTempUnit, Set-SysPilotTempUnit, ConvertTo-SysPilotTemp
