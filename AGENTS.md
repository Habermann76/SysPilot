# SysPilot – verbindliche Arbeitsregeln für alle KI-Modelle

Diese Datei ist vor Änderungen am Projekt zu lesen.

## Arbeitsweise
- Bestehende installierte und lokale Version prüfen; sinnvolle Änderungen übernehmen, nichts blind überschreiben.
- Elegante, wartbare und möglichst automatische Lösungen bevorzugen.
- Wichtige, potenziell riskante Schritte bleiben als feste Auswahl mit Rückfrage sichtbar.
- GUI zuerst: Funktionen sollen über die WPF-GUI und Toolbox sauber per Klick erreichbar sein.
- Informative Anzeigen, verständliche Tooltips und Status-/Fehlermeldungen ergänzen.
- KI-/Web-Suche nur anbieten, wenn sie für die konkrete Information sinnvoll ist; keine erfundenen Ergebnisse.
- Nach mehreren zusammenhängenden Änderungen selbst testen (PowerShell-Syntax, Pfade, Startargumente, GUI-relevante Funktionen).
- Keine neue Versionsnummer und kein Release automatisch anbieten oder ausführen, bevor der Benutzer ausdrücklich zustimmt.
- Erst nach erfolgreichem Test eine neue Versionsnummer vorschlagen; Release auf GitHub nur nach expliziter Anweisung.

## Installation und Versionen
- Entwicklungsordner: `C:\Users\haber\SysPilot`.
- Installierte Version: `C:\Program Files\SysPilot`.
- Änderungen der installierten Version prüfen und sinnvoll in die Entwicklung übernehmen.
- `version.txt`, Installer, README, Installationshinweise und Release-Notizen synchron halten.

## Stabilität & Versionspolice
- `0.9.4.1` ist die letzte **funktionierende** Version. Neue Features (DNS-Manager, etc.) sind WIP und werden nur nach vollständigem Test auf diese Version eingespielt.
- version.txt, README, ROADMAP und Release-Notizen immer synchron halten.
- Vor jedem neuen Release prüfen: `git log`, `git tag`, `gh release list` → keine Dopplungen.

## Workflow beim Wiederstart auf stabile Version
1. `git reset --hard <Tag>`
2. Untracked Hindernisse löschen: `git clean -fd` (beachte Installer/Assets im installer-output!).
3. Dokumentation + AGENTS.md anpassen
4. Commit + Push

## Experimentelle Features
Die DNS-Manager-/Language-Experimente sind zurückgesetzt; sie sind nicht im Release enthalten.

## GitHub-Fallback
Wenn GitHub MCP nicht funktioniert, nicht abbrechen: `scripts\github-fallback.ps1` für Commit und Push über PowerShell verwenden. Niemals force-pushen oder ohne Benutzerfreigabe releasen.
