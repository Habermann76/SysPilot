# SysPilot - Scripts: Vorgefertigte, anpassbare Skripte (ohne KI)
#Requires -Version 5.1

function Get-SysPilotScriptsDir {
    $d = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'scripts'
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    return $d
}

function Get-SysPilotScripts {
    $dir = Get-SysPilotScriptsDir
    Get-ChildItem $dir -Filter '*.ps1' -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
        $desc = ''
        $first = Get-Content $_.FullName -TotalCount 5 -ErrorAction SilentlyContinue
        foreach ($line in $first) { if ($line -match '^#\s*(.+)') { $desc = $matches[1]; break } }
        [PSCustomObject]@{ Name = $_.BaseName; Datei = $_.Name; Beschreibung = $desc; Pfad = $_.FullName }
    }
}

function Invoke-SysPilotScript {
    param([Parameter(Mandatory)][string]$Path)
    Write-Host ""
    Write-Host "  Fuehre aus: $(Split-Path $Path -Leaf)" -ForegroundColor Cyan
    Write-Host ("  " + ("-" * 50)) -ForegroundColor DarkGray
    Write-SysPilotLog "Skript gestartet: $(Split-Path $Path -Leaf)"
    & $Path
    Write-Host ("  " + ("-" * 50)) -ForegroundColor DarkGray
    Write-Host "  [OK] Skript beendet." -ForegroundColor Green
    Write-SysPilotLog "Skript beendet: $(Split-Path $Path -Leaf)"
}

function New-SysPilotScriptTemplate {
    $dir = Get-SysPilotScriptsDir
    $name = Read-SysPilotChoice "Name des neuen Skripts (ohne .ps1)"
    if (-not $name) { return }
    $name = ($name -replace '[^\w\-]', '')
    $path = Join-Path $dir "$name.ps1"
    if (Test-Path $path) { Write-Host "  [!] Existiert bereits." -ForegroundColor Yellow; return }

    $tpl = @"
# $name - Beschreibung hier eintragen (erscheint im Menue)
# SysPilot-Skript: Alle SysPilot-Funktionen stehen zur Verfuegung.
# Beispiele (auskommentiert):

# Energieplan wechseln:
# Set-SysPilotPlan -Mode Performance

# Prioritaeten anwenden:
# Set-SysPilotPriorities

# RAM freigeben:
# Invoke-SysPilotFreeRam

# Eigene Befehle:
# Stop-Process -Name "OneDrive" -Force -ErrorAction SilentlyContinue

Write-Host "Skript '$name' laeuft..." -ForegroundColor Cyan
"@
    Set-Content -Path $path -Value $tpl -Encoding UTF8
    Write-Host "  [OK] Vorlage erstellt: $path" -ForegroundColor Green
    Start-Process notepad.exe $path
}

function Show-SysPilotScriptsMenu {
    while ($true) {
        $scripts = @(Get-SysPilotScripts)
        $items = @()
        foreach ($s in $scripts) {
            $items += @{ Label = ("{0,-30} {1}" -f $s.Name, $s.Beschreibung); Color = 'White'; Tag = "run:$($s.Pfad)" }
        }
        $items += @{ Label = 'Neues Skript aus Vorlage erstellen'; Color = 'Cyan'; Tag = 'new' }
        $items += @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = $null }

        $sel = Show-SysPilotArrowMenu -Items $items -Title 'Skripte (vorgefertigt & anpassbar)' -Footer 'Pfeiltasten, Enter = auswaehlen, Esc = zurueck'
        if ($null -eq $sel) { return }
        if ($sel -eq 'new') {
            New-SysPilotScriptTemplate
            Read-SysPilotChoice "Weiter mit Enter" | Out-Null
            continue
        }
        if ($sel -like 'run:*') {
            $path = $sel.Substring(4)
            $act = Show-SysPilotArrowMenu -Items @(
                @{ Label = 'Skript ausfuehren'; Color = 'Green'; Tag = 'run' },
                @{ Label = 'Im Editor bearbeiten'; Color = 'White'; Tag = 'edit' },
                @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = $null }
            ) -Title 'Aktion waehlen' -Footer 'Enter = auswaehlen, Esc = zurueck'
            if ($act -eq 'run') {
                Invoke-SysPilotScript -Path $path
                Read-SysPilotChoice "Weiter mit Enter" | Out-Null
            } elseif ($act -eq 'edit') {
                Start-Process notepad.exe $path
            }
        }
    }
}

Export-ModuleMember -Function Get-SysPilotScripts, Invoke-SysPilotScript, New-SysPilotScriptTemplate, Show-SysPilotScriptsMenu
