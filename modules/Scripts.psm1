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
        Write-SysPilotHeader "Skripte (vorgefertigt & anpassbar)"
        $scripts = @(Get-SysPilotScripts)
        if ($scripts.Count -eq 0) {
            Write-Host "  Keine Skripte gefunden." -ForegroundColor DarkGray
        } else {
            $i = 0
            foreach ($s in $scripts) {
                $i++
                Write-Host ("  [{0,2}] {1,-28} {2}" -f $i, $s.Name, $s.Beschreibung) -ForegroundColor White
            }
        }
        Write-Host ""
        Write-Host "  Befehle: <Nr> = ausfuehren | E<Nr> = bearbeiten | N = neu | 0 = zurueck" -ForegroundColor Yellow
        $c = Read-SysPilotChoice "Auswahl"
        if ($c -eq '0' -or $c -eq '') { return }
        if ($c -match '^(n|N)$') { New-SysPilotScriptTemplate; continue }
        if ($c -match '^[eE](\d+)$') {
            $n = [int]$matches[1]
            if ($n -ge 1 -and $n -le $scripts.Count) { Start-Process notepad.exe $scripts[$n - 1].Pfad }
            continue
        }
        $n = 0
        if ([int]::TryParse($c, [ref]$n) -and $n -ge 1 -and $n -le $scripts.Count) {
            Invoke-SysPilotScript -Path $scripts[$n - 1].Pfad
            Read-SysPilotChoice "Weiter mit Enter" | Out-Null
        }
    }
}

Export-ModuleMember -Function Get-SysPilotScripts, Invoke-SysPilotScript, New-SysPilotScriptTemplate, Show-SysPilotScriptsMenu
