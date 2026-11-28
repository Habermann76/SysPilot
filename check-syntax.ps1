# SysPilot Syntax- + Encoding-Check (PS 5.1 kompatibel, selbst ASCII)
# Prueft ALLE .ps1/.psm1 (modules/, root, scripts/):
#  1) Parse unter Windows PowerShell 5.1 (scriptblock::Create, UTF8)
#  2) Encoding-Falle: Nicht-ASCII-Bytes ohne BOM -> PS5.1 liest ANSI
#     -> Mojibake/Parse-Crash (genau der Bug, der HealthMonitor killte)
#  3) Namens-Konsistenz: veraltete ANZEIGENAMEN in UI-Strings
#     (Title/Label/Content/Desc/ToolTip/Prompt/Write-Host/Items) -
#     bei Umbenennung muessen Menue, GUI-Button, Toolbox, Fenster-Titel
#     UND Herbert-Prompts synchron umbenannt werden (siehe AGENTS.md).
$files = @()
$files += Get-ChildItem 'modules' -Filter '*.psm1' -File -ErrorAction SilentlyContinue
$files += Get-ChildItem '.' -Filter '*.ps1' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '_*' }
$files += Get-ChildItem 'scripts' -Filter '*.ps1' -File -ErrorAction SilentlyContinue
$fail = 0
# Veraltete Anzeigenamen -> aktueller Name (nur UI-sichtbare Strings;
# Code-Identifiers wie Show-SysPilotUpdateCenterWindow bleiben erlaubt,
# weil sie keine Leerzeichen/Bindestriche im Namen-Muster enthalten)
$retiredNames = @(
    @{ Old='Update-Center';        New='Softwarecenter' }
    @{ Old='Updatecenter';         New='Softwarecenter' }
    @{ Old='Update Center';        New='Softwarecenter' }
    @{ Old='Update / Download Center'; New='Softwarecenter' }
)
# Zeilen, die wie UI-Text aussehen (nicht nur Code)
$uiLineRe = '(?i)(Title|Content|Label|Desc|ToolTip|Prompt|Text\s*=|Write-Host|Items|Menu|Anzeige|Beschreibung)'
foreach ($f in $files) {
    $p = $f.FullName
    $bytes = [IO.File]::ReadAllBytes($p)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $utf8 = [Text.Encoding]::UTF8.GetString($bytes)
    if ($utf8.Length -gt 0 -and $utf8[0] -eq [char]0xFEFF) { $utf8 = $utf8.Substring(1) }
    $nonAscii = ([regex]::Matches($utf8, '[^\x00-\x7F]')).Count
    $encWarn = ''
    if ($nonAscii -gt 0 -and -not $hasBom) { $encWarn = "  <-- ENCODING-RISIKO: $nonAscii nicht-ASCII ohne BOM"; $fail++ }
    elseif ($nonAscii -gt 0) { $encWarn = "  (BOM: OK)" }
    try {
        [void][scriptblock]::Create($utf8)
        # Namens-Check: veraltete Anzeigenamen in UI-Zeilen?
        $nameHits = @()
        $ln = 0
        foreach ($line in ($utf8 -split "`r?`n")) {
            $ln++
            if ($line -match '^\s*#') { continue }            # Kommentarzeilen ueberspringen
            if ($line -notmatch $uiLineRe) { continue }
            foreach ($rn in $retiredNames) {
                if ($line -match [regex]::Escape($rn.Old)) {
                    $nameHits += "Z$ln '$($rn.Old)' -> '$($rn.New)'"
                    break
                }
            }
        }
        if ($nameHits.Count -gt 0) {
            $fail++
            Write-Host ("NAMEN {0}: veralteter Anzeigename in UI-String ({1})" -f $f.Name, ($nameHits -join '; '))
        } else {
            Write-Host ("OK   {0}{1}" -f $f.Name, $encWarn)
        }
    } catch {
        $fail++
        Write-Host ("FAIL {0}: {1}{2}" -f $f.Name, $_.Exception.Message, $encWarn)
    }
}
Write-Host ""
Write-Host "Geprueft: $($files.Count) Dateien, Probleme: $fail"
if ($fail -gt 0) { exit 1 }
