# SysPilot – Agenten-Regeln für Cline/Copilot

## Produktzusammenfassung
SysPilot ist ein reiner PowerShell-WPF-Tool zur Systemdiagnose und -automatisierung.

## Aufbau
- **Vollmenü:** SysPilot.ps1 – $Tool-Switch-Case + Show-SysPilot<Name>Window
- **GUI:** SysPilot-GUI.ps1 – WPF-Layout + Start-SysPilotToolFromGui
- **Toolbox:** modules/Toolbox.psm1 – Get-SysPilotToolbox mit Action-Blocks

## Start-SysPilotToolFromGui-Mechanismus (0.9.4.5)
```powershell
function Start-SysPilotToolFromGui {
    param([string]$Tool, [switch]$FromGui)
    # -FromGui gibt an, dass das GUI-Fenster geöffnet werden soll
    # -VisibleConsole bewirkt, dass die Konsole sichtbar bleibt
}
```
- GUI-Buttons müssen -FromGui an Start-SysPilotToolFromGui bergeben
- Read-Host oder Read-SysPilotChoice verblocken das WPF-Fenster
- Nicht-ASCII-Zeichen (→, —, ä, ü, ö) in Attributen des WPF-XAML verursachen Parser-Fehler unter PowerShell 5.1

## clinerules.md für SysPilot-Entwicklung
*Erstellt: 09.11.2026 – basierend auf erfolgreicher 0.9.4.5-Deployment*

- Alle Script-Dateien unter C:\Users\haber\SysPilot\ sind UTF-8 (kein BOM)
- Die installierte Version live unter C:\Program Files\SysPilot\ parallel testen
- Installer: Inno Setup (C:\Users\haber\SysPilot\installer.iss)
- Portable: build-portable.bat -> installer-output\SysPilot-0.9.4.4-beta-portable.zip
- Release-Checkliste: Syntax-Check -> Funktionsprüfung -> ZIP/EXE -> Versionsnummer
- version.txt immer mit dem Release-Tag synchron halten
