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
- **0.9.4.7** ist der aktuelle Stand (neu: WizTree.psm1, HardwareCheck.psm1, Drivers.psm1, SystemRepair.psm1, SystemTuning.psm1, HostsEditor.psm1; Win11-UI-Reparatur; weiterhin Pfeiltasten-Menü, StorageCleanup, Ruhezustand an/aus)
- Alle GUI-Tools im Vollmenü, in der WPF-GUI und in der Toolbox
- Installierte Version: C:\Program Files\SysPilot\ (auf diesem PC nicht vorhanden – nur Entwicklungsordner)

## Fehlerquellen & Arbeitsweise (Stand 0.9.4.7)

### 0.9.4.7-Falle: KI-generierte Module können komplett unbrauchbar sein
- `HardwareCheck.psm1` und `Drivers.psm1` wurden von Cline mit massiven Syntaxfehlern
  geliefert (unmatched try/catch, `[datetime]::Parse(...) -ErrorAction`, `};` in
  switch-Case, `foreach ($g in $g)`-Shadowing, `$(if...)`-Subexpressions).
  `Import-Module` schlägt fehl → Funktionen fehlen → Menüs zeigen „Unbekanntes
  Werkzeug". **Immer Parser-Check + Modul-Import-Test + Funktions-Smoketest
  durchführen, bevor gebaut wird.**
- `pnputil /enum-drivers` hat kein `/fo csv` und lokalisierte Ausgabe → Inventar
  lieber über `Win32_PnPSignedDriver` (Version/Datum/Hersteller).
- `Win32_PnPSignedDriver`/Inventar braucht **Administratorrechte**, sonst leer.
- `Get-PSDrive`-Size kann ohne Admin 0 liefern → `Win32_LogicalDisk` verwenden.
- `Win32_NetworkAdapter.NetConnectionStatus`: 2 = connected (nicht 1!).
- `LastBootUpTime` ist CIM-Datum → `[Management.ManagementDateTimeConverter]::ToDateTime()`.
- WizTree-Download: offizielle Installer-URL dynamisch von
  `https://diskanalyzer.com/download` auflösen (Pattern `files/wiztree_X_YY_setup.exe`).

### Treiber-Quellen (SDI-Analyse, 0.9.4.7)
- SDI (Snappy Driver Installer, SamLab) wurde per REA/Strings analysiert:
  DriverPacks = proprietäre .7z-Repack-Archive, Download via integrierter
  libtorrent-Instanz + HTTP-Updates von sdi.com.ru-Torrents. **Nicht
  nachgebaut** (Lizenz/Quellen unklar). Ghidra-Vollanalyse (`binary_overview`)
  lief in REA-Timeout – PE-Imports/Strings genügten für die Bewertung.
- Stattdessen legitime Quellen in `modules/Drivers.psm1`:
  `Get-SysPilotWUDriverUpdates`/`Install-SysPilotWUDriverUpdate`
  (Windows-Update-COM-API, `Type='Driver'`),
  `Find-SysPilotCatalogDrivers` (MS Update Catalog per Hardware-ID,
  Katalog listet gleiche Treiber in Sprachvarianten → Dedupe nach
  Titel+Version), `Get-SysPilotDeviceHardwareIds`
  (`Get-PnpDeviceProperty DEVPKEY_Device_HardwareIds`),
  `Get-SysPilotSdiExe` (erkennt SDI-Installation, Desktop liegt oft unter
  `OneDrive\Desktop`, nicht `Desktop` → `[Environment]::GetFolderPath`).
- Katalog-Download selbst läuft bewusst über den Browser (Katalog-Mechanismus
  mit dynamischen Tokens) – keine Fake-Automatik.
- SDI-Installation: `Get-SysPilotSdiLatestRelease` parst `sdi-tool.org/download`
  nach `SDI_R<n>.7z|zip` (Link `DriverOff.net/sdi/SDI_R<n>.7z`, Versionslabel
  `x.y.z (R<n>)`); `Install-SysPilotSdiLatest` lädt, entpackt per 7-Zip
  (`Get-SysPilot7ZipExe`, Fallback tar) nach `%LOCALAPPDATA%\Programs\SDI`
  (alte Installation → `.old-<ts>`). SDI ist portabel → kein Inno-Installer;
  SDI Full nur per Torrent → nicht anbieten. 7z-Inhalt ist das komplette
  Paket (drivers/, indexes/, tools/, SDI*_drv.exe).

### DriversCloud-Analyse (0.9.4.7)
- `DriversCloud.exe` = Tauri/Rust-Client; Treiber-API unter
  `driverscloud.com/api/` (JWT-Auth, `RecevoirConfigurationApiCrypte`,
  DCCrypt.dll, Kernel-Treiber `DriversCloud_amd64.sys`, WebSocket-Kanal).
  Proprietär + verschlüsselt → **nicht nachgebaut** (gleiche Kategorie wie
  Driver-Booster-API). Ghidra-Timeout wie bei SDI → PE-Imports/Strings
  reichten.
- Stattdessen `Find-SysPilotDriversCloudManufacturer` (Drivers.psm1):
  parst `driverscloud.com/en/drivers` (manufacturer/<id>/<slug>), Alias-
  Tabelle + Token-Overlap; **Slug-Match exakt bevorzugen** ("intel" darf
  nicht „intellon" treffen). Öffnet Herstellerseite im Browser.
- REA: `search_strings`/`list_strings` brauchen geöffnetes Target
  (`open_binary`); `document` = Pfad. Ghidra-Import timeoutet bei >5 MB
  oft → lokale String-Extraktion per PowerShell genügt für URLs/APIs.

### Hosts-Editor + Autostart-Sicherung (Optimizer-Analyse, 0.9.4.7)
- `Optimizer_16.7.exe` (deadmoon) = .NET-App; Strings zeigen Cleaner,
  DNS, Hosts-Editor, Startup-Manager, Dienst-Tweaks — keine proprietäre
  API. Nützliche Lücken in SysPilot geschlossen:
  `modules/HostsEditor.psm1` (Key `hosts`) + `Backup-SysPilotStartup`/
  `Restore-SysPilotStartup` in Startup.psm1 (Menü-Pseudo-Einträge
  BACKUP/RESTORE; `Show-SysPilotArrowMenu` gibt den **Tag** zurück,
  nicht das Hashtable-Item — Tag-Vergleiche nutzen!).
- `Get-SysPilotBackupDir` liegt in Common.psm1 (jedes Modul braucht
  eigenen `$script:SysPilotRoot` oder die Funktion aus Common).

### Windows Repair + Simple System Tweaker (0.9.4.7)
- `Repair_Windows.exe` (Tweaking.com 4.14): Funktionsliste komplett in
  `repairs_info/*.txt` + `repairs_presets/*.ini` lesbar (kein RE noetig).
  Nachgebaut als `modules/SystemRepair.psm1` (Key `sysrepair`, 11
  Reparaturen). NICHT nachgebaut: COM-Unmarshaller, MDAC/Jet, CD/DVD,
  Safe-Mode-Fix, Permissions-Reset (zu riskant ohne PRuefung).
- `Simple_System_Tweaker.exe` (Tweaking.com 2.2, VB6): Klassische
  Registry-Tweaks → `modules/SystemTuning.psm1` (Key `systune`, 9 Tweaks).
- **netsh-Ausgaben sind lokalisiert** (deutsche Windows: „Autom.
  Abstimmungsgrad..."!) → TCP-Settings IMMER via `Get/Set-NetTCPSetting`
  (`AutoTuningLevelLocal`, `Timestamps`), nie per netsh-Text parsen.
- PowerShell-String-Falle: `"$ext:"` in double-quotes = Variablenverweis
  mit Doppelpunkt → `${ext}:` schreiben.
- Win11-UI-Funktionen in SystemTuning.psm1: `Reset-SysPilotWin11Taskbar`
  (HKCU Taskbar-Keys + Explorer-Neustart), `Set-SysPilotContextMenuMode`
  (klassisch = CLSID `{86ca1aa0-…}` InprocServer32 anlegen, Win11 =
  löschen), `Add/Remove-SysPilotAdminContextMenus` (HKCU\Classes
  Directory\Background|Directory|Drive|Folder\shell\TerminalAdmin +
  SystemFileAssociations\.ps1\shell\PSAdmin — `%V` für Background,
  `%1` sonst; wt.exe für Terminal). Alles HKCU → kein Admin nötig;
  neue Win11-Menü zeigt Background-Verben direkt, Ordner/Datei-Verben
  ggf. unter „Weitere anzeigen".

### Bewährte Methoden (verbindlich für alle neuen Features)
- **GUI-Toolbox-Buttons**: `Get-SysPilotToolbox` (Toolbox.psm1) ist die
  EINZIGE Quelle für GUI-Toolbox-Buttons — `SysPilot-GUI.ps1` generiert
  sie automatisch nach Kategorie. Ein neuer Toolbox-Eintrag mit `Key`
  erzeugt den Button; der Key MUSS einen Case in `Invoke-SysPilotTool`
  haben (GUI startet `SysPilot.ps1 -Tool '<key>'` in einer eigenen
  Konsole). `Action`-Scriptblock = Fallback für die Konsolen-Toolbox.
- **Pfeiltasten-Menüs**: Jedes Auswahlmenü (Hauptmenü, Tool-Untermenüs,
  Kategorie-Wahl) nutzt `Show-SysPilotArrowMenu`. `Tag` ist der Rückgabe-
  wert — Vergleiche auf Tag-Ebene, nicht auf Item-Ebene. `Esc`/`$null` =
  zurück/zur. Kein `Read-Host` für Menüs.
- **Direkt-Tool-Keys**: Für Tools, die per Button DIREKT eine Funktion
  aufrufen sollen (nicht nur ein Untermenü), zusätzlich eigene Keys im
  `Invoke-SysPilotTool`-Switch anlegen (Beispiel 0.9.4.7:
  `win11ui`/`win11taskbar`/`win11ctx`/`win11ctxadmin` → je eigener Case).
  Ein „Alles-in-einem"-Key (`win11ui`) öffnet das Untermenü; die
  Einzel-Keys ermöglichen One-Click-Aktionen aus der Toolbox.
- **Registry-UI-Tweaks (Win11 Taskbar/Kontextmenü)**: Bevorzugt HKCU
  (`HKCU:\SOFTWARE\Classes`, `Explorer\Advanced`) → kein Admin nötig.
  Vor Änderungen Backup via `New-SysPilotBackup` oder Registry-Export;
  Explorer-Neustart immer ankündigen und nur nach Bestätigung.
  Admin-Verben im Kontextmenü: HKCU-Classes-Einträge mit `command`-Key,
  `%V` für Ordner-Hintergrund, `%1` für Ordner/Laufwerk/Datei;
  Windows-Terminal via `wt.exe`, PowerShell via `powershell.exe`.
- **Kontextmenü-Modus Win11↔klassisch**: CLSID-Override
  `{86ca1aa0-34aa-4e8b-a509-960fe4311b46}` unter `HKCU:\SOFTWARE\Classes`;
  `InprocServer32` anlegen = klassisch, löschen = Win11.

### Menü-System (0.9.4.6)

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

## Release-Checkliste (0.9.4.7 & nachfolgend)
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
