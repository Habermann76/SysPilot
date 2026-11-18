# SysPilot — Hinweise für Claude (und andere KI-Modelle)

Vor jeder Änderung am Projekt zuerst `AGENTS.md` lesen — dort sind alle verbindlichen Arbeitsregeln definiert.

## Kernaufgabe
SysPilot ist ein reines PowerShell-WPF-Tool. Jedes neue Modul / Werkzeug muss gleichzeitig in drei Oberflächen erreichbar sein:
1. **Vollmenü** (`SysPilot.ps1`) — Menüpunkt + `$Tool`-Switch-Case
2. **GUI** (`SysPilot-GUI.ps1`) — XAML-Button + Click-Handler + Tastaturnavigation
3. **Toolbox** (`modules/Toolbox.psm1`) — Eintrag in `Get-SysPilotToolbox`

## Verbindliche Vorgehensweise
Siehe `AGENTS.md` Abschnitt "Neue Module und Tools integrieren (verbindliche Vorgehensweise)".

## Kritische Fehlerquellen
- **`Join-Pfad` statt `Join-Path`**: Nicht existierendes Cmdlet → GUI-Button funktioniert nicht.
- **Fehlender `$Tool`-Case**: Wenn `Show-SysPilot<Name>Window` `SysPilot.ps1 -Tool '<key>'` aufruft, aber der Switch-Case fehlt → Aufruf bewirkt nichts.
- **Encoding**: PowerShell-Dateien mit UTF-8 speichern; Syntax-Check mit `-Encoding UTF8`.

## Installierte Version
- Entwicklungsordner: `C:\Users\haber\SysPilot`
- Installierte Version: `C:\Program Files\SysPilot`
- Geänderte Dateien immer auch in die installierte Version kopieren (Copy-Item).