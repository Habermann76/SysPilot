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
- `version.txt`, README, ROADMAP, INSTALL, release-notes.md und `.clinerules` synchron halten. Installer und Portable werden von `build.ps1` automatisch mit der Version aus `version.txt` benannt.

## Neue Module und Tools integrieren (verbindliche Vorgehensweise)

Jedes neue Modul / Werkzeug muss **gleichzeitig** in allen drei Oberflächen
erreichtbar sein. Die folgende Reihenfolge ist verbindlich:

### 1. Modul-Datei erstellen
- Datei unter `modules/<Name>.psm1` anlegen
- Alle Funktionen mit `Export-ModuleMember` exportieren
- Modul testen (Syntax-Check, Funktionsaufruf)

### 2. Vollmenü (`SysPilot.ps1`)
- **`Invoke-SysPilotTool`-Switch**: Case für den Key hinzufügen (z.B. `'storage' { Show-SysPilotStorageMenu; return }`)
- **`Show-SysPilotMenu`**: Eintrag im `$items`-Array ergänzen: `@{ Label='...'; Color='White'; Tag='<key>' }`
  - **Key-Konsistenz prüfen**: Jeder `Tag` im Menü braucht einen Case in `Invoke-SysPilotTool` (und umgekehrt nur die im Menü verwendeten).
- **Auswahl per Pfeiltasten**: Menüs nutzen `Show-SysPilotArrowMenu` (Common.psm1) – keine Nummerneingabe. `Read-SysPilotChoice` nur noch für Text-/Parameter-Eingaben und "Weiter mit Enter"-Pausen.

### 3. GUI (`SysPilot-GUI.ps1`)
- **Button** erstellen: `$ctrl.Btn<Name>.Add_Click({ Show-SysPilot<Name>Window })`
- **Tastaturnavigation**: Button in das `$buttons = @(...)`-Array aufnehmen
- **Wrapper-Funktion** `Show-SysPilot<Name>Window` hinzufügen, die aufruft:
  ```
  & (Join-Path $script:GuiRoot 'SysPilot.ps1') -Tool '<key>'
  ```
  **Wichtig:** `Join-Path` verwenden, nicht `Join-Pfad`!
- **XAML-Button** im WPF-Layout definieren (`<Button x:Name="Btn<Name>" ...>`)

### 4. Toolbox (`modules/Toolbox.psm1`)
In `Get-SysPilotToolbox` einen Eintrag hinzufügen:
```
$tools += @{ Category = '<Kategorie>'; Key = '<key>'; Name = '<Anzeigename>'
    Desc = '<Beschreibung>'; NeedsAdmin = $true/$false; Action = { Show-SysPilot<Name>Window; Read-SysPilotChoice 'Weiter' | Out-Null } }
```

### 5. Validierung
- **Syntax-Check** aller betroffenen Dateien:
  ```
  [void][scriptblock]::Create((Get-Content $f -Raw -Encoding UTF8))
  ```
- **Konsistenzprüfung**: Key in `$Tool`-Switch, Menüpunkt, GUI-Button und Toolbox-Eintrag müssen übereinstimmen
- **Funktionsprüfung**: Tool über `-Tool '<key>'` aufrufen und prüfen, ob die richtige Funktion startet

### 6. Installierte Version aktualisieren
Geänderte Dateien nach `C:\Program Files\SysPilot` kopieren:
```
Copy-Item -Path 'C:\Users\haber\SysPilot\<Datei>' -Destination 'C:\Program Files\SysPilot\<Datei>' -Force
```

### Fehlerquellen, die bei früheren Integrationen auftraten
- **`Join-Pfad` statt `Join-Path`**: Nicht existierendes Cmdlet → GUI-Button funktioniert nicht. Immer `Join-Path` verwenden.
- **Fehlender `$Tool`-Case**: Wenn `Show-SysPilot<Name>Window` `SysPilot.ps1 -Tool '<key>'` aufruft, aber der Switch-Case fehlt → Aufruf bewirkt nichts.
- **Encoding-Probleme**: PowerShell-Dateien mit UTF-8 speichern; beim Syntax-Check `-Encoding UTF8` angeben.
- `0.9.4.5` ist die letzte **funktionsreife** Version. Alle Features stehen zur Verfügung.
- version.txt, README, ROADMAP und Release-Notizen immer synchron halten.

## Pfeiler-Fehlerbehandlung (für 0.9.4.5)
| Fehler | Vergangenheits-Ursache | Lokale Lösung |
|--------|----------------------|---------------|
| Nicht-ASCII im String -> Syntax-Fehler | PowerShell unterstützt keine Nicht-ASCII-Module | Alle PS-Dateien ASCII-sicher; Tools/Texte extrahieren |
| $win.Show() vor ShowDialog() -> Crash | Doppeltes Anzeigen | Nur $win.ShowDialog() verwenden |
| $Tool-Case fehlt -> Methode ignoriert | Switch vor Funktion | Case nach Funktionen |
| Read-Host in GUI -> Blockiert UI | Konsole blockiert UI-Thread | InputBox, MessageBox, XAML-Textfelder |
| $args doppelt befüllt -> doppelte Parameter | Doppelter $args += in Start-SysPilotToolFromGui | Einmal befüllen |
| **GUI-Buttons trotz Klick kein Tool starten** | Start-SysPilotToolFromGui hatte kein -FromGui-Switch | -FromGui an alle GUI-Handler weitergeben |
| **Path-Fehler Join-Pfad** | Falsches Cmdlet | Verwende Join-Path (existiert; Join-Pfad ist falsch) |

## Start-SysPilotToolFromGui (0.9.4.5 Fix)
- Neuer [switch]$FromGui Parameter in param-Block
- GUI-Handler: Start-SysPilotToolFromGui -Tool '<key>' -FromGui
- Toolbox-Handler: Start-SysPilotToolFromGui -Tool '<key>' -FromGui -VisibleConsole
- Nicht verwenden: Simultanes $args +=-Füllen

## Aktuelle Version
- **0.9.4.6** ist der aktuelle Stand (Pfeiltasten-Menü, Speicher-Analyse/StorageCleanup, Ruhezustand an/aus, build.ps1)
- Alle GUI-Tools im Vollmenü, in der WPF-GUI und in der Toolbox
- Installierte Version: C:\Program Files\SysPilot\ (auf diesem PC nicht vorhanden – nur Entwicklungsordner)

## Fehlerquellen & Arbeitsweise (Stand 0.9.4.6)

### Menü-System (0.9.4.6)
- **Alle Auswahlmenüs per Pfeiltasten** über `Show-SysPilotArrowMenu -Items @(@{Label;Color;Tag})`:
  Hauptmenü (`Show-SysPilotMenu`), Speicher-Menü, Skripte-Menü, Dienste-Tuner, Einstellungen, Konfiguration.
  `Tag` wird zurückgegeben; `Esc`/`$null` = zurück.
- **Keine Nummerneingabe** mehr für Menüauswahl – nur noch für Parameter (z.B. Prozessname, Uhrzeit, Backup-Name).
- **Menü-Aktionen laufen über `Invoke-SysPilotTool -Name '<key>'`** – neue Menüpunkte brauchen einen Case dort.
- Historischer Fehler (behoben): Menü rief `Start-SysPilotCoolMode`, `Start-SysPilotPerfMode`, `Show-SysPilotSettingsMenu`, `Close-SysPilotToTray` auf, die nicht existierten → "Die Benennung wurde nicht erkannt". Energieplan-Kurzwahl läuft jetzt über `Invoke-SysPilotPlanSwitch` → `Set-SysPilotPlan` (mit Admin-/Plan-Fehlerbehandlung).

### PowerShell-Module
- **Nur genehmigte Verben** in exportierten Funktionsnamen (Get/Set/Invoke/Show/Write/Test/Start/Stop/New/Remove/Clear/Install/Update/Save/Restore/Import/Export/Format/Measure/Compare/Convert/Read/Hire/Undo/Watch/Backup/Checkpoint/Resume/Suspend/Debug/Trace/Connect/Disconnect/Enter/Exit/Pop/Push/Redo/StepInto/StepOver).
  Unzulässig z.B. `Toggle-` → Warnung "Namen enthalten nicht genehmigte Verben" bei jedem Start.
- Alle `.ps1`/`.psm1` **ASCII-sicher** schreiben (ae/oe/ue/ss statt Umlaute, keine Grad-Symbole) – sonst Mojibake ohne BOM.

### KI-Werkzeuge (Cline & Co.)
- **Grosse Dateien nie als ein String schreiben**: Cline hat `SysPilot.ps1` mit `[... truncated, this is a large file ...]` überschrieben → Skript unbrauchbar. Nach jeder KI-Änderung Dateigröße/Inhalt prüfen; bei Verdacht `git diff`/`git show HEAD:<file>` zum Restore nutzen.
- **PowerShell.MCP**: Proxy-Pfad in `C:\Users\haber\.cline\data\settings\cline_mcp_settings.json` muss zur installierten Modulversion passen (`C:\Users\haber\OneDrive\Documents\PowerShell\Modules\PowerShell.MCP\<Version>\bin\win-x64\PowerShell.MCP.Proxy.exe`). Stand 0.9.4.6: 1.17.1.
- **Inline-PowerShell vermeiden**: komplexe Skripte als `.ps1`-Datei schreiben und per `powershell -NoProfile -ExecutionPolicy Bypass -File <skript>.ps1` ausführen.

## Release-Checkliste (0.9.4.6 & nachfolgend)
1. **Syntax-Check** aller betroffenen Dateien (`[void][scriptblock]::Create((Get-Content $f -Raw -Encoding UTF8))`)
2. **Konsistenzprüfung**: Menü-Tags ↔ `Invoke-SysPilotTool`-Cases ↔ Toolbox-Keys ↔ GUI-Buttons
3. **Funktionsprüfung**: `SysPilot.ps1 -Tool '<key>'` für geänderte Tools
4. **Build**: `powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1` → `installer-output\SysPilot-Setup-<Version>-x64.exe` + `SysPilot-<Version>-beta-portable.zip` (Version kommt aus `version.txt`)
5. **Artefakte verifizieren**: ZIP-Inhalt (SysPilot.ps1 nicht trivial klein, StorageCleanup.psm1 enthalten), Version korrekt
6. **Docs synchron**: version.txt, README, ROADMAP, INSTALL, release-notes.md, .clinerules, AGENTS.md
7. **Erst dann** (nach ausdrücklicher Freigabe): Commit → Push → `gh release create` mit Artefakten + GitHub-Beschreibung/README aktualisieren
8. Version nicht erhöhen, bevor Tests fehlschlagen

## Workflow beim Wiederstart auf stabile Version
- Vor jedem neuen Release prüfen: `git log`, `git tag`, `gh release list` → keine Dopplungen.

## Workflow beim Wiederstart auf stabile Version
1. `git reset --hard <Tag>`
2. Untracked Hindernisse löschen: `git clean -fd` (beachte Installer/Assets im installer-output!).
3. Dokumentation + AGENTS.md anpassen
4. Commit + Push

## Experimentelle Features
DNS-Manager und Smart Health Monitor sind nun in allen Oberflächen (Vollmenü, GUI, Toolbox) integriert und stehen zur Verfügung.

## GitHub-Fallback
Wenn GitHub MCP nicht funktioniert, nicht abbrechen: `scripts\github-fallback.ps1` für Commit und Push über PowerShell verwenden. Niemals force-pushen oder ohne Benutzerfreigabe releasen.
