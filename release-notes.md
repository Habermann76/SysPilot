# SysPilot 0.9.4.9 beta

- **CleanSweep — Deinstallations-Center (NEU)**: `modules/UninstallManager.psm1`
  ist eine eigenständige SysPilot-Implementierung der IObit-Uninstaller-
  Kernfunktionen (Funktionsanalyse per REA an `IObitUninstaler.exe` —
  Delphi/VCL-Binary, Ghidra-Timeout wie bei SDI → PE-Resources +
  String-Extraktion; kein Code kopiert, eigener Name „CleanSweep"):
  - **Programme deinstallieren**: Inventar aus allen 4 Uninstall-
    Registry-Sichten (HKLM 64/32 + HKCU 64/32), Bevorzugung von
    QuietUninstallString, MSI-Erkennung (`msiexec /x {GUID} /qn`),
    Silent-Args-Heuristik (Inno `/VERYSILENT`, NSIS `/S`,
    InstallShield `/s /v"/qn"`), Silent/Normal-Wahl, Nummern-Mehrfach-
    auswahl mit Suchfilter, Batch-Modus, Exit-Code 3010/1641 =
    „Neustart nötig", optionaler Wiederherstellungspunkt vor Batch.
    Unquotierte UninstallStrings mit Leerzeichen werden korrekt geparst
    (bis zum ersten `.exe`-Token).
  - **Windows-Apps**: `Get-AppxPackage` (Optional `-AllUsers` bei Admin),
    Frameworks/Ressourcen-Pakete ausgeblendet, `NonRemovable` markiert
    und mit Warnung, `Remove-AppxPackage`, plus provisionierte Pakete
    (`Get-AppxProvisionedPackage`/`Remove-AppxProvisionedPackage`, Admin).
  - **Browser-Erweiterungen**: Inventar + Entfernen für Chromium
    (Chrome/Edge/Brave/Opera via `Secure Preferences`/`Preferences`
    JSON — `extensions.settings.<id>` + `extensions.alerts.<id>` werden
    entfernt, `Extensions\<id>`-Ordner + `Local/Sync Extension Settings`
    in den Papierkorb; Datei-Backups unter `backup\extensions`) und
    Firefox (`extensions.json`-Eintrag + XPI-Dateien in Profil und
    Browser-Installationsordner). Läuft-Browser-Warnung.
  - **Reste-Scanner**: nach Programmname ( oder automatisch nach jeder
    Deinstallation) scannt Dateien/Ordner (InstallLocation, Publisher-
    Ordner in Program Files/AppData/ProgramData), Registry
    (`Software\<token>` in 4 Sichten, Run/RunOnce-Werte, App Paths,
    MUICache), Dienste, geplante Aufgaben, Startmenü-/Desktop-Shortcuts
    und den Uninstall-Key selbst — jeder Fund mit Sicherheits-Score
    (0-100), Auswahl per Nummern oder „A"; Dateien→Papierkorb,
    Registry→`.reg`-Export nach `backup\leftovers`, Dienste/Aufgaben
    gelöscht, alles geloggt.
  - **Verwaiste Programme**: Ordner in `Program Files`, `Program Files
    (x86)`, `%LOCALAPPDATA%\Programs`, `ProgramData` ohne passenden
    Uninstall-Eintrag (normalisierter Namensabgleich gegen Inventar,
    Windows-Inbox-/Systemordner ausgeblendet) → Force-Uninstall.
  - **Defekte Einträge**: Uninstall-Keys ohne UninstallString oder mit
    nicht mehr vorhandenem Programm — Registry-Entfernung mit
    `.reg`-Backup oder Force-Uninstall des Install-Ordners.
  - **Force-Uninstall**: beliebiger Pfad → löscht Ziel + alle per
    Scanner gefundenen Reste (Papierkorb/Registry-Backup).
  - **Windows-Updates**: KB-Liste via `Win32_QuickFixEngineering`,
    `wusa.exe /uninstall /kb:<n> /quiet /norestart` (Admin).
  - **Wiederherstellungspunkt**: `Checkpoint-Computer` auf Wunsch vor
    Batch-Deinstallationen (Admin).
- **Tests**: Parse + Modul-Import OK; Inventar live: 222 Programme,
  280 AppX-Pakete, 425 Browser-Erweiterungen (Chrome 168, Brave 257),
  9 „defekte" Kandidaten (alles Fehlalarme durch unquotierte
  UninstallStrings — Parser gefixt → 0), ~50 verwaiste Kandidaten,
  7 Windows-Updates; Leftover-Scan an SysPilot selbst: 9 Funde
  (Ordner, 2 geplante Aufgaben, Uninstall-Key, 5 Shortcuts).
  `-Tool uninstall` zeigt das CleanSweep-Menü korrekt.
- **Fixes (0.9.4.9, Iteration 2)**: **Edge lieferte 0 Erweiterungen** —
  Edge-`Secure Preferences` enthalten doppelte JSON-Schlüssel
  (`macroEnabled.12`/`macroenabled.12`) → `ConvertFrom-Json` scheitert
  komplett. Neuer Scanner-Parser in `Common.psm1`
  (`Get-SysPilotJsonChildProperties`, `Get-SysPilotChromiumExtension
  Settings`) + roh-Text-Entfernung (`Remove-SysPilotPrefExtensionEntry`,
  settings+alerts inkl. Komma). Edge jetzt **248** Extensions, Gesamt
  **674** (vorher 425). **Tor Browser** wird erkannt (Firefox-basiert,
  `TorBrowser\Data\Browser\profile*`). **Flacker-Fix**: Multiselect-Menü
  zeigt bei >25 Einträgen nur ein Scroll-Fenster statt jedes Mal alle
  ~400 Zeilen neu zu zeichnen; Taste `A` = alle abhaken. **Bedienung**:
  Extension-Liste ist jetzt eine Endlosschleife — mehrere markieren +
  Enter („remove marked") ODER einzeln nach und nach; Filter bleibt.
  **Iteration 3**: Extension-Bereinigung komplett mausfuehrbar —
  Browser-Auswahlliste zum Anklicken (alle erkannten Browser mit
  Anzahl + „Alle Browser", keine Textfilter noetig), Multiselect mit
  eingebauten klickbaren Buttons „Markierte entfernen"/„Abbrechen"
  (neu: `-Actions`-Parameter in `Show-SysPilotMultiSelectMenu`,
  Ziffern 1-9 als Tastatur-Alternative), und nach der Auswahl die
  Frage ob gleiche Erweiterungen (Match per ID oder normalisiertem
  Namen) auch in anderen Browsern entfernt werden sollen.
  **Iteration 4 (Maus-Koordinaten-Fix)**: `Show-SysPilotMultiSelectMenu`
  zeigte bei langen Listen + niedrigem Fenster zu viele Zeilen → die
  Konsole scrollte beim Zeichnen und die gespeicherten Zeilenpositionen
  (itemStartRow/actionStartRow) drifteten von den Mausklick-Koordinaten
  ab → Highlight sprang auf falsche Zeile, Klicks markierten falsche
  Einträge, Buttons unerreichbar. Sichtbare Listengröße wird jetzt aus
  `[Console]::WindowHeight` berechnet (wie bei `Show-SysPilotArrowMenu`),
  damit nie gescrollt wird; Action-Buttons geben die abgehakten Tags mit
  zurück, Klick auf markierten Eintrag schaltet Haken aus.
  **Iteration 5**: Extension-Entfernung wurde unwirksam, weil **laufende
  Browser** (Chrome/Edge/Brave/Firefox) ihre Preferences im Speicher
  halten und die Datei-Änderung beim Beenden überschreiben — neuer
  Gate vor dem Entfernen: Browser beenden / trotzdem versuchen /
  Einträge überspringen (inkl. Hinweis auf Sync-Restore). Viewport-
  Höhe kommt jetzt aus `GetConsoleScreenBufferInfo` (srWindow) statt
  `[Console]::WindowHeight` — in Windows Terminal kann Letzteres die
  Buffer-Höhe liefern → alle ~248 Einträge wurden gezeichnet und die
  Buttons landeten unterhalb des Fensters. Multiselect hat jetzt
  PageUp/PageDown und einen größeren Mausrad-Schritt.
  **Iteration 6 (Sync-Schutz)**: Aufgeräumte lokale Entfernung nutzte
  nur Datei-Edits — bei angemeldeten Browserninstalliert Sync die
  Extension erneut. Neu: `Test-SysPilotBrowserProfileSignedIn` erkennt
  Login über `Local State → profile.info_cache` (gaia_id /
  edge_account_cid / edge_sync_enabled, Fallback account_info.email);
  `Set-SysPilotExtensionPolicyBlock` schreibt
  `installation_mode=blocked` in die `ExtensionSettings`-Policy
  (HKCU\SOFTWARE\Policies\<Browser>, merge-basiert, bestehende
  Einträge bleiben) → Sync kann die ID nicht erneut installieren.
  `Remove-SysPilotExtensionPolicyBlock` hebt Blocks wieder auf;
  SysPilot protokolliert gesetzte IDs in
  `backup\extension-policy-blocks.json`. Policy-Schreiben braucht
  Admin (HKCU\Policies ist sonst schreibgeschützt) — ohne Admin
  Hinweis statt Angebot. Live getestet: Chrome+Edge angemeldet,
  Brave nicht; kompletter Set/Merge/Remove-Zyklus verifiziert.
  **Iteration 7 (ROOT CAUSE „Extensions bleiben")**: `"extensions"`
  kommt in Chromium-Prefs **mehrfach** vor — `account_values.
  extensions.ui` (winzig, Index ~19), echtes `extensions.settings`,
  `protection.macs.extensions`. `Find-SysPilotJsonSection` griff den
  ERSTEN Treffer → Extension-Entfernung lief ins Leere
  („Secure Preferences konnte nicht aktualisiert werden"). Neu:
  `-MustContain`-Parameter — die Sektion wird nur akzeptiert, wenn
  sie den gesuchten Unter-Key (`settings`/`alerts`) wirklich enthält.
  Zusätzlich: Prefs-Dateien werden jetzt **ohne BOM** geschrieben
  (`Write-SysPilotFileRaw`, FileShare.ReadWrite + Retry) — PS5.1
  `Set-Content -Encoding UTF8` hatte einen BOM ergänzt, den Chromium
  als Dateibeschädigung werten kann. Live verifiziert: Chrome-Kopie
  224 Settings-Einträge, Ziel-ID entfernt, JSON valide.
  **Iteration 8**: `Backup-SysPilotFile` warf bei jedem Aufruf
  `ParameterBindingException` — `Join-Path $bak "$stamp-" + (...)`
  parsed das `+` als eigenes Positionsargument → Exception →
  try/catch hat sie verschluckt → **Extension-Entfernung lief nie**
  (deshalb „konnte nicht aktualisiert werden / kein
  Positionsparameter +"). Fix: Konkat in Variable ausgelagert.
  Live verifiziert: Backup-Datei wird jetzt geschrieben.
  **Iteration 9**: Zentrales Debug-Log — `Write-SysPilotLog` schreibt
  jetzt mit Session-Header (Version/PID/User/Admin, ms-Zeitstempel),
  Fallback `%LOCALAPPDATA%\SysPilot\logs` wenn der Installationsordner
  nicht beschreibbar ist; neue `Write-SysPilotDebug` (Level DEBUG) +
  `Get-SysPilotLogFiles`. Extension-Flow, JSON-Pref-Edit, Lauf-Browser-
  Gate und Sync-Policy sind jetzt vollstaendig im Log nachvollziehbar.
  **Iteration 10**: KI-Browser-Erkennung — Perplexity Comet
  (`%LOCALAPPDATA%\Perplexity\Comet\User Data`) und BrowserOS
  (`%LOCALAPPDATA%\BrowserClaw\User Data`, Chromium-Forks) werden jetzt
  inventarisiert (live: Comet 244, BrowserOS 7 Extensions). Sie sind
  EINZELN waehlbar, aber aus „Alle Browser" und dem Cross-Browser-
  Matching ausgeschlossen (`Test-SysPilotAiBrowser`). Prozess-Erkennung
  jetzt pfadbasiert (`Get-SysPilotBrowserProcesses`): BrowserOS laeuft
  als chrome.exe, Firefox/Tor als firefox.exe — Verwechslungen und
  falsche Prozess-Kills werden vermieden; Kill passiert per Prozess-ID.
  **Iteration 11**: CleanSweep-Flows komplett mausgeführt — Programme:
  Modus (Silent/Normal) jetzt als Buttons in der Auswahlliste statt
  separatem Menü; Windows-Apps + provisionierte Apps: „Entfernen"/
  „Abbrechen"-Buttons statt Enter-Bestätigungen; Reste-Bereinigung:
  alle Einträge standardmässig abgehakt (abwählbar), Buttons statt
  Enter, plus persistenter „Reste Auto-Clean"-Schalter im
  CleanSweep-Menü (config.json → CleanSweep.AutoLeftoverClean): wenn AN,
  werden alle Reste nach der Deinstallation automatisch entfernt
  (reversibel via Papierkorb/Registry-Backup).
  **Iteration 12**: HostsMan 4.8.106 zu den Portable Apps hinzugefuegt
  (MajorGeeks-Download wie UWT): `Get-SysPilotMajorGeeksAsset` ist jetzt
  app-agnostisch (`-VersionPattern`/`-AssetName` statt UWT-Hardcodierung).
  Live verifiziert: Mirror-Download 3,1 MB, ZIP enthaelt `hm.exe`.
  **Iteration 13**: Update/Download-Center (`SoftwareUpdateCenter.psm1`,
  Key `updates`) nach REA-Analyse von IObit Software Updater (proprietaere
  .dbd-Kataloge + Telemetrie → nicht nachgebaut), UpdateHub/Nexova
  (Open-Source Electron, Engine = winget+gsudo → winget-first bestaetigt)
  und Patch My PC Home Updater (SCUP-Katalog-Wrapper → kuratierte
  App→Quelle-Tabelle). Funktionen: winget/Chocolatey-Upgrade-Scan mit
  Batch-Aktualisierung (Silent/Interaktiv), Programm-Katalog 147 Apps in
  7 Kategorien, GitHub-Releases-Check + Asset-Auswahl (.msi>.exe>.zip,
  Debug-Symbole gefiltert), MajorGeeks-Resolver (89 verifizierte Apps),
  Web-Katalog-Links (Heise functional, FileHippo/Uptodown/CHIP
  Bot-geschuetzt → ehrliche Link-outs). winget-Parser robust gegen
  lokalisierte Spalten und collapsing Names. **Auto-Update**:
  `Invoke-SysPilotAutoUpdate` installiert alle winget/choco-Updates
  silent; Menü „Automatische Updates" registriert geplante Aufgabe
  „SysPilot Update" (taeglich 12:00, Admin, `-UpdateAuto`-Parameter);
  Update-Scan bietet zusätzlich „Alle still aktualisieren".
  **Fehlgeschlagene Updates** (`update-center.json`): fehlgeschlagene
  bzw. silent-unmoegliche Updates werden persistent registriert und in
  „Fehlgeschlagene Updates" aufgelistet — pro Eintrag Retry (silent /
  interaktiv / **als Administrator** via UAC), **manuelle Installation
  per Terminal** (generiertes .ps1 mit allen Befehlen, wt.exe-Start),
  **KI-Suche** (DuckDuckGo-Installations-Hilfe) und „als erledigt"
  markieren. **Dauerhafte Einstellungen**: global (Modus
  silent/interaktiv/fragen + Admin-Standard) und pro App
  (Modus silent/interaktiv/manuell/fragen + Admin) in
  `update-center.json`; Auto-Update respektiert sie (manuell markierte
  Apps werden uebersprungen, admin-Prefs starten elevated).
  **Fixes**: choco-Parser las falsche Spalten (`Id|Version|Available|
  Pinned`, nicht Name|Id|...) → Chocolatey-Updates liefen ins Leere;
  interaktiver Update-Modus zeigt jetzt wingets eigenen Fortschritt
  live (vorher unsichtbar, wirkte wie einfrieren), Silent/Auto-Update
  loggt Dauer pro App; Web-Kataloge ehrlich beschriftet (Heise +
  FileHippo = echte Suche, Uptodown/CHIP/MajorGeeks = JS-Suche → Seite
  oeffnen) plus **winget-Suche lokal** im Terminal. Web-Katalog-Suche
  jetzt suchmaschinenbasiert: Provider-Auswahl (MajorGeeks/FileHippo/
  Uptodown/CHIP/Alle) -> site:-Query -> **Ecosia (Baeume pflanzen),
  Brave oder Google** (in AISearch-Basisliste ergaenzt); MajorGeeks
  versucht zuerst die direkte Details-Seite per Slug (verifiziert,
  Soft-404-sicher). **Update-Fehleranalyse (8 Fehlschlaege)**:
  `Invoke-SysPilotWingetRaw` hat jetzt echten Timeout (Process-API,
  vorher ignoriert), ExitCode + Output-Tail als Fehlertext (vorher
  leer), Fehler-Klassifizierung (`not-applicable`/`admin`/`timeout`),
  automatischer elevated-Retry bei Admin-Installer-Fehlern (MSI 1603),
  `update-center.json` liegt jetzt in `%LOCALAPPDATA%\SysPilot` (vorher
  Program Files → stiller Schreibfehler ohne Admin → Fehlerliste
  blieb leer), Auto-Update ueberspringt mehrfaeltig "nicht anwendbare"
  Pakete, Fehlerliste zeigt Kind + Loesungshinweis.
  **Paketmanager-Integration (nach UniGetUI-Konzept)**: neues Modul
  `PackageManagers.psm1` mit Registry ueber 14 Manager (WinGet,
  Chocolatey, Scoop, pip, npm, Bun, .NET Tool, PSGallery, Homebrew,
  APT, DNF, Pacman, Flatpak, Snap). Erkennung automatisch; Linux-PMs
  laufen ueber WSL-Distros (ohne docker-desktop). Outdated-Scan
  merged scoop/npm/pip/PSGallery in den Update-Scan + Auto-Update;
  Upgrade-Dispatch pro Manager (`Invoke-SysPilotPmUpgrade`).
  Suche in ALLEN Managern (`Get-SysPilotPmSearchResults`) auch im
  Web-Katalog-Menu. Fehlende Manager per Knopfdruck installierbar
  (`Install-SysPilotPackageManager`: offizielles Skript oder winget,
  PATH wird geprueft/ergänzt, WSL-Distros via `wsl --install`).
  Update-Center-Menüpunkt „Paketmanager". **Fortschritt + WSL-Setup**:
  Install-Skripte zeigen jetzt Live-Output (vorher unsichtbarer
  Capture → wirkte wie Einfrieren); winget-Installationen (npm/pip/
  dotnet) ebenfalls sichtbar. `Install-SysPilotWslDistro` prueft die
  Distro, installiert sie bei Bedarf (`wsl --install -d <distro>`),
  und richtet den PM **darin** ein: flatpak/snap via `apt-get install`
  in der Distro, apt/dnf/pacman als Basisbestandteil verifiziert.
  **WSL-Verwaltung**: `Show-SysPilotWslMenu` im Paketmanager-Menü —
  Status (WSL-Version/Kernel/WSLg/Distros), WSL Manager
  (Bostrot.WSLManager via winget: Distro-Verwaltung, Backups,
  .wslconfig-Editor, MCP-Server), `wsl --update`, `wsl --shutdown`,
  GUI-Apps-Aktivierung (`.wslconfig`: guiApplications +
  localhostForwarding, nichts wird überschrieben), Linux-Distro +
  PM-Einrichtung. **Distro-Installer**: `Show-SysPilotWslDistroPicker`
  listet die Live-Online-Liste (`wsl --list --online`, 25 Distros:
  Ubuntu 22.04/24.04/26.04, Debian, Fedora 44/45, Arch, Kali,
  openSUSE, Rocky, Alma, Oracle, Azure ...) mit Recommendations und
  „Alle"-Uebersicht; `Install-SysPilotWslDistroByName` installiert per
  `wsl --install <name>` mit Live-Output, Retry-Syntax, Verify und
  PM-Voreinrichtung (apt/dnf makecache), dann optionale
  Terminal-Start (OOBE). **MuMu Player** zu den Portable Apps
  hinzugefuegt (Typ `installer`): offizieller Download-Endpunkt
  `api.mumuplayer.com/api/dl/win?channel=gw-win-download` (302 auf
  signierte Installer-URL, international `_all_`-Build), Installer
  laeuft mit eigener UI; `InstallArgs` darf jetzt auch leer sein
  (interaktive Installer). **Umbenennung**: „Portable Apps &
  Store-Clients" -> „Apps & Store-Clients" (Vollmenue, Toolbox,
  Menue-Titel) - nicht alle Apps sind portabel.
  **Auto-Fix-Framework**: generische Stamp-Drossel in Common.psm1
  (`Test-/Save-SysPilotAutoFixStamp`, `%LOCALAPPDATA%\SysPilot\autofix`)
  + selbsttaetige Behebung von Warnungen: Scoop-Buckets (auto
  `scoop update` bei WARN, Erkennung via `cmd /c`-Kapselung weil
  scoop.cmd WARNs an die Konsole umgeht; `Repair-SysPilotScoopBuckets`
  fixt korrupte packed-refs/loose refs/tmp_*-Fetch-Leichen,
  index.lock, stash't lokale Manifest-Aenderungen, ff-only/reset auf
  origin-Stand), npm/pip-Selbst-Update (7-Tage-Drossel,
  Versionsvergleich), NuGet-Provider >= 2.8.5.208 (30 Tage),
  winget `source update` (24h), Chocolatey-Selbst-Update bei
  veralteter Version (7 Tage). Alle Fixes loggen nach
  `Write-SysPilotLog`.
  **Update-Fixes (Log 20:22-20:50)**: `Get-SysPilotChocoOutdated` filtert
  Phantom-Rows mit identischer Version (`chocolatey.server 0.3.0|0.3.0`
  landete sonst taeglich in der Update-Liste); `choco upgrade` exit 0
  heisst NICHT Erfolg - `Invoke-SysPilotChocoUpgradeAuto` parst jetzt
  `Chocolatey upgraded X/Y` + `was not found with the source(s)`
  (choco meldete „0/1 aktualisiert" als OK); pip-Upgrades laufen ueber
  `python -m pip` (pip.exe kann sich nicht selbst updaten - pip selbst
  verlangt genau das; Python wird aus `Scripts\pip.exe`-Umgebung
  aufgeloest); elevated winget-Retry mit `--force`.
  **Alt-Manager-Installation (wenn winget nicht kann)**: neue Funktion
  `Show-SysPilotAltManagerInstallMenu` sucht das Paket live in den
  Remote-Repos von **Chocolatey UND Scoop** (`choco search`/`scoop
  search`, Suchbegriffe aus Name+winget-Id: Publisher entfernt,
  camelCase gesplittet, Versionen bereinigt; Ergebnisse nach
  Aehnlichkeit gerankt). Aufruf an zwei Stellen: (1)
  `Invoke-SysPilotCatalogWinget` — schlaegt der winget-Download fehl,
  wird die Alt-Manager-Suche automatisch angeboten; (2)
  „Fehlgeschlagene Updates" — neue Aktion „Anderer Paketmanager
  (choco/scoop) suchen" mit `-Adopt`-Warnung (choco-Installation
  ersetzt die vorhandene App und uebernimmt sie unter
  choco-Verwaltung → kuenftige Updates via `choco upgrade`). Live
  verifiziert: FACEIT→`Faceit`, Steam Art Manager→`steam-art-manager`,
  MEGAsync→`megasync`, OnionShare→`onionshare` (alle in Chocolatey
  Community); TeraBox existiert dort nicht → ehrlicher Fehlbericht.
  Scoop nur als optionale Neuinstallation (kein Adopt, da
  userseitig/parallel).
  **Cross-Manager-Update-Fallback (vollautomatisch)**: wenn winget ein
  Paket nicht aktualisieren kann (`not-applicable`, `publisher` =
  „Hersteller-Methode", oder Installer-Fehler), versucht SysPilot
  automatisch **Chocolatey und Scoop** - aber nur wenn der jeweilige
  Manager das Paket tatsaechlich installiert hat (exakter Namensmatch
  gegen `choco list`/`scoop list`, 10-Min-Cache; `openvpn` matcht so
  z.B. NICHT `openvpn-connect`). Neuer Kind `publisher` für
  „kann nicht mit WinGet aktualisiert werden". Elevated-Retry nutzt
  jetzt `--force` (Installer-Shutdown-Checks). `Invoke-SysPilotWinget-
  UpdateAuto` buendelt die Kette: winget -> elevated(--force) ->
  choco/scoop-Fallback; aktiv in AutoUpdate, UpdateScan (silent +
  interaktiv) und im Retry der Fehlgeschlagenen-Liste. Live getestet:
  `Chocolatey.Chocolatey` wird jetzt automatisch via `choco upgrade`
  aktualisiert. Skip-Logik deckt `publisher` nach 2 Fehlversuchen ab.
  **GUI & Erweiterungen der Paketmanager**: `Show-SysPilotPmCompanionsMenu`
  (Update-Center -> Paketmanager -> „GUI & Erweiterungen") mit
  Live-Status-Erkennung und Install/Start-Aktionen: **UniGetUI**
  (portables ZIP, deckt winget/Chocolatey/Scoop/MS-Store ab =
  die „GUI fuer alle"), **Chocolatey GUI** (offizielles Paket
  `chocolateygui`, MSI-Installationen in `Program Files (x86)`
  werden jetzt korrekt erkannt), **OuiGui Chocolatey**
  (Community-GUI, Paket `OuiGuiChocolatey`), **Chocolatey
  AppStore-Extension** (gepflegtes Chrome-Paket
  `chocolatey-appstore-chrome` - Install-Buttons auf Download-
  Seiten), **Legacy `choco-chrome-ext`** (2016, inoffiziell,
  ehrlich gelabelt, nur mit Bestaetigung), **PM-Kataloge**
  (winget.run, chocolatey.org, scoop.sh, npmjs.com, pypi.org,
  powershellgallery.com, nuget.org, MS-Store). Schnelle
  Paket-Erkennung via lib-Ordner-Check (kein langsamer
  `choco list`-Aufruf beim Menu-Redraw).
  Integration: Vollmenue,
  `-Tool updates`, GUI-Button „Update-Center", Toolbox.
- **Integration**: Vollmenü (`uninstall`, `updates`), `-Tool uninstall`/`updates`,
  Toolbox-Einträge „CleanSweep" + „Update / Download Center"; `version.txt` = 0.9.4.9.

# SysPilot 0.9.4.8 beta

- **Fixes**: GUI-Start (XAML-`&`-Fehler, ShowDialog-Konflikt,
  fehlende `Start-SysPilotToolFromGui`), Toolbox-Kategorien
  (Group-Object auf Hashtables), PrivacyGuard (Admin-Restart-Angebot,
  fehlende Policy-Keys, Multi-Value-Schleife), SDI-Installation
  ((Menu-Funktion existierte nicht; EXE-Namen neuer Releases
  `SDI_x64_R2601.exe` werden jetzt erkannt; Versions-Check
  verhindert Doppel-Downloads), **Vollpaket-Auswahl** (Tastenpuffer
  vor Menus wird geleert — veraltete Eingaben inkorporierten sonst
  die erste Auswahl; `Get-StartApps`-Cache beschleunigt das
  Portable-Apps-Menü; Scan-Statusanzeige), **Runtime-Installation**
  (winget-first, falsche `/S`-Argumente für .NET-Framework-Installer
  korrigiert, Exit-Code 1638 = „neuere Version vorhanden" wird als
  Erfolg gewertet, Admin-Neustart wird angeboten), **GUI-Start**
  (veraltete Tray-Instanz blockierte den Single-Instance-Mutex;
  expliziter Zweitstart zeigt das Fenster jetzt auch während des
  Spielens — nur ohne Fokus-Vergiff).
- **„Weiter mit Enter" mausfaehig (NEU)**: `Read-SysPilotChoice`
  erkennt Pause-Aufrufe (`Weiter`, `Weiter mit Enter` — ~160 Stellen)
  und wartet dann auf **Klick oder beliebige Taste** statt Read-Host;
  der Prompt zeigt den Hinweis „(Enter oder Klick)". Rueckgabe `''`
  ist identisch zum bloßen Enter — Aufrufer unveraendert. Getestet:
  Mausklick im Conhost beendete die Pause korrekt.
- **Maus-Kritikfix (QuickEdit)**: `Initialize-SysPilotConsoleInput`
  deaktiviert jetzt zusätzlich `ENABLE_QUICK_EDIT_MODE` (0x40) —
  QuickEdit behandelte die Maus selbst (Textausbildung) und lieferte
  **keine** Mouse-Records an die App; Klicks und Rad waren dadurch
  wirkungslos. Live bewiesen per injizierten Console-Events:
  ohne QuickEdit-Fix 0 Events, danach Move/Click/Wheel alle da.
  Zusätzlich korrigiert: Mausrad-Flag `0x0002`→`0x0004`
  (`MOUSE_WHEELED`, nicht Double-Click). Modus wird nach jedem
  Menü/Dialog wiederhergestellt.
- **Maus-Kritikfix (Event-Queue)**: `ReadConsoleInput` liefert bis zu
  32 Eingaberecords pro Aufruf — bisher wurde nur das erste verarbeitet
  und der Rest still verworfen. Bei gleichzeitigen Mausbewegungen und
  Tastendrücken gingen dadurch Pfeiltasten und Klicks „manchmal"
  verloren (in echten Tests beobachtet). Alle Events werden jetzt in
  `$script:_menuEventQueue` gepuffert und der Reihe nach verarbeitet;
  Move-Events werden bei Überlauf (>100) verworfen. Batch-Test in
  echter Konsole: 4 Events auf einmal injiziert → alle verarbeitet.
- **Flipboard + „Oeffnen mit"-Dialog (Fix)**: `Type='web'`-Apps öffneten
  fälschlich eine lokale Datei — der alte Flipboard-Store-Eintrag in
  der Uninstall-Registry zeigte auf eine `.ico`-Datei
  (`...\Web Applications\...\Flipboard.ico`), `Start-Process` darauf
  löste den Windows-„Öffnen mit"-Dialog mit Store-Suche aus. Fix:
  neuer `Test-SysPilotLaunchablePath`-Filter (nur .exe/.bat/.cmd/.com/
  .ps1/.lnk/.url/.msc/.reg) in allen Registry-Pfad-Auflösungen
  (PortableTools, SDI, WizTree), `web`-Apps suchen nicht mehr lokal,
  und „Starten" startet jetzt die installierte **Brave-PWA**
  (`shell:AppsFolder\Brave._crx_...` — Flipboard ist bei dir als
  Browser-Web-App installiert) oder fällt auf flipboard.com zurück.
- **Maussteuerung in Konsolen-Menüs (NEU)**: alle Pfeiltasten-Menüs
  (`Show-SysPilotArrowMenu`, `Show-SysPilotMultiSelectMenu` — Hauptmenü,
  Tool-Untermenüs, Vollpaket-Auswahl) unterstützen jetzt die Maus:
  **Linksklick auf einen Eintrag = auswählen** (Single-Choice) bzw.
  **Haken umschalten** (Mehrfachauswahl), **Mausrad = blättern**,
  **Hover = Markierung**. Zusätzlich sind alle **Ja/Nein-Abfragen**
  (`Confirm-SysPilot`) mausbedienbar: neuer Inline-Dialog mit klickbaren
  `[ Ja ]`/`[ Nein ]`-Buttons, Mausrad-Umschaltung, j/n-Tasten und
  Pfeilen — der bisherige Kontext bleibt dabei sichtbar (kein
  Clear-Host). Technisch über die Windows Console API
  (`ReadConsoleInput`/`ENABLE_MOUSE_INPUT`, P/Invoke in Common.psm1 —
  kein externes Tool nötig). Hover-Events ohne Zeilenwechsel lösen
  kein Neuzeichnen aus; Menüs erfassen die Eintragsposition live
  (`CursorPosition.Y`), sodass auch umbrochene Titel korrekt bleiben.
  Konsolen-Input-Modus wird nach jedem Menü/Dialog restauriert; ohne
  Console (z.B. Remote/ISE) fällt alles automatisch auf die gewohnte
  Tastaturbedienung zurück. End-to-End getestet: simulierter Mausklick
  auf Menüeintrag, [Ja] und [Nein] sowie Tastatureingaben in echter
  Konsole.
- **Microsoft PC Manager (NEU, App-Typ 'storeapp')**: detection + start
  über `Get-StartApps`/`shell:AppsFolder` (MatchName-Feld für abweichende
  Startmenü-Namen). Installation nicht automatisierbar — die App ist in
  Deutschland regionsbeschränkt (winget/msstore liefern „kein anwendbarer
  Installer", aka.ms-Links sind abgelaufen, Uptodown-Download liegt hinter
  Cloudflare-Turnstile) → „Installieren" öffnet die Uptodown-Downloadseite,
  die nachweislich funktioniert. Live getestet: installierte App erkannt
  und gestartet.
- **Uptodown Desktop (NEU-Typ 'installer')**: statt nur die Website
  zu öffnen werden jetzt offizielle Installer direkt geladen
  (`download.uptodown.app/windows-client` — kein Cloudflare-Problem),
  per SHA256 gegen die offizielle Prüfsumme verifiziert und silent
  installiert. „Starten" findet die installierte App über die
  Uninstall-Registry (quotierte DisplayIcon-Pfade werden jetzt
  korrekt behandelt) und startet sie wirklich — vorher öffnete
  „Starten" nur erneut die Website. Live getestet: App läuft.
- **Ultimate Windows Tweaker 5 (NEU)**: neunte App in Portable Apps &
  Store-Clients — über 200 Windows-11-Tweaks, portabel ohne Installation.
  Neuer `DownloadMode='majorgeeks'`: die offizielle Seite blockiert
  Direktdownloads per Cloudflare (403), daher wird über MajorGeeks
  geladen — Mirror-Seite → Session-Cookie → 302 auf die Datei.
  Version wird live von der Detailseite gelesen (aktuell 5.2),
  EXE-Suche rekursiv (ZIP entpackt in `UWT 5.2\`-Unterordner).
  End-to-End getestet: Download, Extraktion, Startpfad-Erkennung.
- **Win11-Kontextmenue reparieren (NEU)**: `Restore-SysPilotWin11ContextMenu`
  in `SystemTuning.psm1` — stellt das moderne Windows-11-Kontextmenue
  (mit Befehlsleiste oben) nach Schaeden durch Tweaking-Tools wieder
  her. Diagnose zeigt alle Fundstellen: CLSID-Override-Keys in HKCU,
  HKLM und WOW6432Node, blockierte Shell-Erweiterungen
  (`Shell Extensions\Blocked`), fehlende FileExplorer-DLLs (mit
  Hinweis auf sfc/DISM). Nach Bestaetigung werden alle Eintraege
  entfernt und der Explorer neu gestartet. Erreichbar ueber
  Windows-11-UI-Menue, `-Tool win11ctxrestore` und Toolbox-Button.
- **PrivacyGuard – Datenschutz & Werbe-Fix (NEU)**:
  `modules/PrivacyFix.psm1` — 32 Registry-Tweaks in 5 Kategorien
  (Datenschutz, Werbung, Explorer & Taskleiste, System & Gaming, Edge)
  mit Statusanzeige, Einzel-Umschaltung und „FIX: alle
  Datenschutz- + Werbe-Tweaks"-Batch. Enthält: Werbe-ID,
  Tailored Experiences, Telemetrie-Richtlinie, DiagTrack-Stopp,
  Standort-Sperre, Copilot/Recall-Deaktivierung, alle
  ContentDeliveryManager-Werbe-Flags, Suchfeld-Vorschläge,
  MenuShowDelay, Task-Ansicht, Snap-Flyout, Transparenzeffekte,
  NetworkThrottling/SystemResponsiveness, GameDVR, Power-Throttling,
  VisualFX, Shutdown-Beschleunigung, BSOD-Details, Edge-Policy-Tweaks.
  Alles reversibel, Admin-Tweaks markiert, jede Änderung bestätigt +
  geloggt. Eigenständige SysPilot-Eigenentwicklung.
- **Portable Apps & Store-Clients (NEU)**: `modules/PortableTools.psm1` —
  verwaltet portable Programme und Store-Clients mit Statusanzeige
  (installiert/nicht vorhanden), Download, Installation nach
  `PortableApps` und Start. Enthaelt: **UniGetUI** (portables ZIP aus
  GitHub-Releases, Settings bleiben im Programmordner), **Komi Store**
  (ehem. GitHub Store — App-Store für GitHub/Codeberg-Releases,
  portables ZIP) und **Uptodown Desktop** (öffnet die offizielle
  Download-Seite — direkter Download ist wegen Cloudflare-Schutz nicht
  automatisierbar) und **Chris Titus WinUtil** (portables `winutil.ps1`
  aus GitHub-Releases, läuft in eigenem Konsolenfenster) und **WinToys**
  (neuer App-Typ `winget`: Installation über
  `winget install 9NZKPSTSNW4P --source msstore`, Start über
  `shell:AppsFolder`, Fallback auf die Microsoft-Store-Seite) und
  **iTop Easy Desktop** (Desktop-Organisator — winget-Paket
  `iTop.iTopEasyDesktop`, Quelle `winget`; Erkennung jetzt auch über
  Uninstall-Registry und .lnk-Auflösung), **Ferdium** (Messenger-
 aggregator, winget `Ferdium.Ferdium`) und **Flipboard** (Web-Version —
  der offizielle Desktop-Client wurde eingestellt). **Vollpaket:**
  neuer Menüpunkt „Vollpaket: mehrere Apps zum Installieren
  auswählen" — Checkbox-Mehrfachauswahl per Pfeiltasten + Leertaste
  (`Show-SysPilotMultiSelectMenu` in Common.psm1), installiert alle
  markierten Apps nacheinander. Release-Assets
  werden live über die GitHub-API aufgelöst, alte Versionen werden als
  `.old-<Zeitstempel>` gesichert. Toolbox-Eintrag unter „System
  optimieren".
- **Stammzertifikate-Manager (NEU)**: `modules/RootCertificates.psm1` —
  lädt das portable `UpdateRootCertificates`-Tool (asheroto, GitHub,
  GPL-3.0, nur ~4,7 MB) bei Bedarf automatisch in
  `PortableApps\UpdateRootCertificates` herunter (neueste Version via
  GitHub-API, Fallback 5.1.1) und startet es elevated. Aktualisiert die
  vertrauenswürdigen Windows-Root-Zertifikate und entfernt disallowed
  Zertifikate. Statusanzeige zeigt Tool-Version und Anzahl der
  Root-Zertifikate im Speicher. Toolbox-Eintrag unter „Sicherheit &
  Reparatur" (Admin). Das Tool wird nicht mit SysPilot ausgeliefert —
  Download erfolgt zur Laufzeit von der offiziellen Release-URL.
- **Laufzeiten-Manager (NEU)**: `modules/Runtimes.psm1` — prüft installierte
  Visual-C++-Redistributables (Uninstall-Registry), .NET Framework
  (Release-Key → Versionsname) und .NET Desktop/Core-Runtimes
  (Registry + `dotnet --list-runtimes`). **Lokale Installer-Erkennung** in
  `Downloads` und `Downloads\ABDM\Programs` (VC_redist.x64/x86,
  windowsdesktop-runtime-*, NDP48*, aio-runtimes*) — was bereits
  heruntergeladen wurde, wird direkt silent installiert, ohne erneuten
  Download. Andernfalls **winget** (bevorzugt: `Microsoft.VCRedist.2015+.x64/.x86`,
  `Microsoft.DotNet.DesktopRuntime.8/9/10/11`,
  `Microsoft.DotNet.Framework.Runtime` = .NET Framework 4.8.1 —
  erkennt „bereits installiert", saubere Exit-Codes, Silent-Mode)
  und als letzter Fallback Download von offiziellen Microsoft-Quellen:
  VC++ via `aka.ms/vs/17/release/`, .NET Desktop Runtime 11.0.0/10.0.15/
  9.0.23/8.0.34 via `builds.dotnet.microsoft.com` (mit LTS/STS-Hinweis),
  .NET Framework 4.8.1 via `go.microsoft.com/fwlink`. Silent-Install mit
  `/install /quiet /norestart` (VC++/.NET) bzw. `/q /norestart` (.NET
  Framework), jeweils mit Admin-Check, Admin-Neustart-Angebot und
  Bestätigung. **All in One
  Runtimes** wird bewusst interaktiv gestartet (eigene Auswahl-UI,
  countdown-stopbar) oder die Computerbase-Download-Seite geöffnet.
- **PortableApps-Integration (0.9.4.8)**: Neue Shared-Helper in
  `Common.psm1` — `Get-SysPilotPortableAppsDir` löst das PortableApps-
  Verzeichnis des Benutzers auf (bevorzugt den echten Desktop-Ort,
  also OneDrive-Desktop falls umgeleitet, sonst Desktop; nutzer-
  unabhängiger als hartcodierte Pfade) und `Get-SysPilotLocalSearchDirs`
  liefert Downloads + PortableApps für Installer-Suchen. Der
  Laufzeiten-Manager durchsucht jetzt beide Ordner und lädt neue
  Installer nach PortableApps. **SDI** wird nicht mehr nach
  `%LOCALAPPDATA%\Programs` installiert, sondern portabel nach
  `PortableApps\SDI` (alte Installationen bleiben/werden als Hinweis
  angezeigt). **LibreHardwareMonitor** wird nach
  `PortableApps\LibreHardwareMonitor` installiert (vorher fest auf den
  Entwicklungs-Pfad `C:\Users\haber\SysPilot\tools` verdrahtet).
- Integration: Vollmenü-Punkt „LAUFZEITEN", `-Tool runtimes`,
  Toolbox-Button (Kategorie „System optimieren", Admin).
- **SysPilot-Neustart-Verknüpfung (NEU)**: `Restart-SysPilot.ps1` +
  Desktop-Verknüpfung „SysPilot Neustart" — beendet alle laufenden
  SysPilot-Prozesse (inkl. unsichtbarer elevated Instanzen im Tray,
  die per CommandLine nicht erkennbar sind: der Single-Instance-Mutex
  der GUI wird geprüft und bei Bedarf elevated neu gestartet) und
  startet die GUI danach sauber neu. Verhindert den früheren
  „Klick auf Verknüpfung tut nichts"-Effekt durch festhängende
  alte Instanzen. Wird auch als Startmenü-Eintrag „SysPilot
  Neustart" installiert; im Installer und Portable enthalten.

# SysPilot 0.9.4.7 beta

- **WizTree-Integration (NEU)**: `modules/WizTree.psm1` erkennt eine vorhandene
  WizTree-Installation (übliche Pfade + Uninstall-Registry inkl.
  `InstallLocation`/`DisplayIcon`), löst die aktuelle Installer-URL dynamisch
  von `diskanalyzer.com/download` auf (Pattern `files/wiztree_X_YY_setup.exe`,
  höchste Version; Fallback: bekannte Version) und installiert silent
  (`/VERYSILENT /NORESTART /SUPPRESSMSGBOXES`). Download wird auf Größe
  geprüft, Erfolg über die resultierende EXE verifiziert. Menü:
  WizTree starten / installieren / Website öffnen.
- **SysPilot PC-Analyse (NEU)**: `modules/HardwareCheck.psm1` — CPU
  (Name/Kerne/Takt/Last), RAM (Größe/Belegung), GPU(s) inkl. VRAM + Treiber,
  Mainboard/BIOS, Laufwerke (Größe, Freiraum, Health via `Get-PhysicalDisk`),
  Netzwerkadapter inkl. IPv4-Adressen, Windows-Version/Build/Laufzeit und
  CPU-Temperatur (echt via LibreHardwareMonitor, sonst ehrlich als
  „geschaetzt" markiert). Nicht messbare Werte werden als „nicht ermittelt"
  angezeigt.
- **Treiber-Werkstatt (NEU)**: `modules/Drivers.psm1` — Problemgeräte via
  `Win32_PnPEntity` (`ConfigManagerErrorCode <> 0`, mit verständlichen
  Fehlercode-Erklärungen), Treiber-Inventar via `Win32_PnPSignedDriver`
  (Version, Datum, Hersteller), Markierung von Treibern älter als 3 Jahre,
  deterministische Prüfung von DirectX-Registry und Visual-C++-Runtimes
  (Uninstall-Registry). Aktionen: Problemgerät neu starten (`pnputil
  /restart-device`, nur mit Bestätigung + Admin) und eine klare
  Rollback-Anleitung (Gerätemanager → „Vorheriger Treiber", nur wenn ein
  älterer Treiber im Store liegt). Ehrlich dokumentiert: automatische
  Treiber-Downloads aus Herstellernetzwerken sind ohne stabile API nicht
  zuverlässig umsetzbar.
- **Treiber-Quellen (NEU, nach SDI-Analyse)**: Submenü „TREIBER-QUELLEN" in der
  Treiber-Werkstatt. (a) **Windows-Update-API**: listet verfügbare
  Treiber-Updates (COM `Microsoft.Update.Session`, `Type='Driver'`) und
  installiert sie nach Bestätigung (Download → Install, EULA wird
  akzeptiert) — legitime, von Microsoft signierte Quelle. (b)
  **Microsoft Update Catalog**: Hardware-IDs von Problemgeräten
  (`DEVPKEY_Device_HardwareIds`) werden gegen `catalog.update.microsoft.com`
  gesucht; Treffer zeigen Titel, Datum, Version, Größe und Detail-URL, erster
  Treffer kann im Browser geöffnet werden (Download läuft über den Katalog,
  wie bei SDI). (c) **SDI-Erkennung**: findet eine vorhandene
  Snappy-Driver-Installer-Installation (Registry + Desktop/PortableApps/
  Programmverzeichnisse) und kann sie extern starten; Info-Text erklärt,
  warum SDIs DriverPacks (SamLab-Torrents, proprietäre Repack-Archive)
  bewusst nicht nachgebaut werden — SysPilot nutzt stattdessen die
  legitimen Quellen Windows Update + MS-Katalog.
- **SDI-Installation (NEU)**: Menüpunkt „SDI: neueste Version laden +
  installieren" ermittelt die neueste SDI-Lite-Version automatisch von
  `sdi-tool.org/download` (z.B. 1.26.1 / R2601), lädt das ~6-MB-Archiv von
  `DriverOff.net` herunter, entpackt es mit 7-Zip (Fallback: tar) nach
  `%LOCALAPPDATA%\Programs\SDI` — eine vorhandene Installation wird vorher
  gesichert (`.old-<Zeitstempel>`) — und bietet den Start an. SDI ist portabel,
  daher ist kein stiller Installer nötig; „vollautomatisch" = Download +
  Extraktion ohne weitere Eingaben nach einer einzigen Bestätigung. SDI Full
  (50 GB, nur per Torrent) wird bewusst nicht angeboten.
- **DriversCloud-Analyse + Hersteller-Suche (NEU)**: `DriversCloud.exe` wurde
  per REA/Strings analysiert — es ist ein Tauri/Rust-Client; die Treiber-API
  (`driverscloud.com/api/...`) ist JWT-geschützt, verschlüsselt
  (`RecevoirConfigurationApiCrypte`, DCCrypt.dll) und nutzt einen eigenen
  Kernel-Treiber zur Geräteerkennung — **nicht reproduzierbar** und wie die
  Driver-Booster-API proprietär, daher nicht nachgebaut. Stattdessen: neuer
  Menüpunkt „DriversCloud Herstellerseite (Browser)" in TREIBER-QUELLEN —
  `Find-SysPilotDriversCloudManufacturer` liest den öffentlichen
  Hersteller-Index von driverscloud.com, matched per Alias-Tabelle
  (AMD/Intel/NVIDIA/HP/Qualcomm u.a.) + Token-Overlap und öffnet die
  jeweilige Hersteller-Treiberseite im Browser. Problemgeräte mit
  Manufacturer-Angabe werden zur Auswahl angeboten.
- **Hosts-Editor (NEU, nach Optimizer-Analyse)**: `modules/HostsEditor.psm1`
  — HOSTS-Datei anzeigen, Einträge hinzufügen (IP + Hostname, mit
  Validierung + Duplikat-Schutz), nach Hostnamen entfernen, alle aktiven
  Einträge löschen (Kommentare bleiben), Datei sperren/entsperren
  (schreibgeschützt), DNS-Cache leeren. Jedes Backup landet in
  `backup\hosts_<Zeitstempel>.bak`.
- **Autostart-Sicherung (NEU, nach Optimizer-Analyse)**: der
  Autostart-Manager bietet jetzt „Backup erstellen" und „Backup
  wiederherstellen" — Run-Keys (inkl. StartupApproved-Status),
  Autostart-Ordner und Logon-Aufgaben werden als JSON in
  `backup\startup_<Zeitstempel>.json` gesichert und können wieder
  eingespielt werden.
- **SysPilot System-Reparatur (NEU, nach Windows-Repair-Analyse)**:
  `modules/SystemRepair.psm1` — 11 gezielte Reparaturen im
  Pfeiltasten-Menü: Proxy komplett zurücksetzen (WinHTTP + WinINet +
  AutoConfigURL), Firewall-Dienst/Profile prüfen, Druck-Spooler reparieren
  (Queue leeren + Neustart), Infektions-Sperrrichtlinien entfernen
  (NoRun/DisableTaskMgr/NoControlPanel u.a.), Dateizuordnungen prüfen &
  korrigieren (exe/bat/cmd/lnk/msc/reg/scr/com/inf), MSI neu registrieren,
  UAC-Standards wiederherstellen, Performance-Counter neu aufbauen
  (lodctr /R), WMI-Repository verifizieren (verify/salvage), VSS-Dienst
  prüfen, Windows-Update-Speicher zurücksetzen (SoftwareDistribution +
  catroot2 umbenennen). Jede Aktion mit Bestätigung, Admin-Check und Log.
- **SysPilot System-Tuning (NEU, nach Simple-System-Tweaker-Analyse)**:
  `modules/SystemTuning.psm1` — 9 umschaltbare Tweaks in drei Kategorien
  (Netzwerk/System/Explorer): TCP Auto-Tuning & Timestamps (via
  `Get/Set-NetTCPSetting`, lokalisierungsunabhängig), DNS-Cache-TTL 4h,
  Kernel im RAM, LargeSystemCache, MenuShowDelay=0, schnelles
  Herunterfahren (AutoEndTasks + Timeouts), Shortcut-Tracking aus,
  „Mit Notepad öffnen"-Kontextmenü. Statusanzeige aller Werte,
  jede Änderung geloggt.
- **Windows-11-UI-Reparatur (NEU, in System-Tuning → Kategorie
  „Win11-UI")**: Taskbar auf Standard zurücksetzen (Ausrichtung,
  Widgets, Chat, Suche u.a. + Explorer-Neustart), Kontextmenü-Modus
  Windows 11 ↔ klassisch umschalten (CLSID-Override), Admin-
  Kontextmenü-Einträge hinzufügen/entfernen („Terminal (Admin)
  öffnen" für Ordner-Hintergrund/Ordner/Laufwerk, „Mit PowerShell
  (Admin) öffnen" für .ps1-Dateien — alles unter HKCU, kein Admin
  nötig). Zusätzlich als eigene Toolbox-Buttons in der GUI:
  „Win11-UI reparieren", „Win11-Taskbar-Standard",
  „Win11-Kontextmenue-Modus" und „Admin-Kontextmenue-Eintraege".
- **Optimizer-Analyse**: `Optimizer_16.7.exe` (deadmoon, .NET) wurde per
  Strings analysiert — Features (Cleaner, DNS-Wechsel, Hosts-Editor,
  Startup-Manager, Dienst-/Feature-Tweaks) sind in SysPilot bereits
  vorhanden oder wurden oben ergänzt; keine proprietary API gefunden.
- **Integration**: Alle drei Werkzeuge in Vollmenü (Pfeiltasten-Menü),
  `$Tool`-Switch (`-Tool drivers|hardware|wiztree`), GUI-Toolbox und
  `Get-SysPilotToolbox` (Keys: `drivers`, `hardware`, `wiztree`).
- **Build**: `build.ps1` (Entwickler-Werkzeug, kein Produktbestandteil) baut
  `SysPilot-Setup-0.9.4.7-x64.exe` + `SysPilot-0.9.4.7-beta-portable.zip`
  automatisch aus `version.txt`.

---

# SysPilot 0.9.4.6 beta

- **Pfeiltasten-Menü (NEU)**: Das gesamte Vollmenü, das Speicher-Menü, das Skripte-Menü und der Dienste-Tuner werden jetzt per Pfeiltasten (hoch/runter, Bild auf/ab, Pos1/Ende, Enter, Esc) bedient - keine Nummerneingabe mehr. Basis: `Show-SysPilotArrowMenu` in `Common.psm1`.
- **Speicher-Analyse (NEU)**: Neues Modul `StorageCleanup.psm1` - analysiert pagefile.sys, hiberfil.sys, swapfile.sys, Temp-Ordner, Windows-Update-Cache, WinSxS, WER, Dumps u.v.m. mit Groessen und verstaendlichen deutschen Erklaerungen. Integriert in Vollmenue, `$Tool`-Switch (`-Tool storage`) und Toolbox (Kategorie "System bereinigen"). Optionale Aktionen: Ruhezustand an/aus, Pagefile-Anleitung, DISM Component Cleanup - riskante Schritte nur mit Bestaetigung.
- **Ruhezustand-Schalter**: `powercfg /h off` UND `powercfg /h on` - der Ruhezustand lässt sich jetzt in beide Richtungen umschalten.
- **Menu-Reparaturen**: Fehlende Funktionen `Close-SysPilotToTray`, `Show-SysPilotSettingsMenu`, `Edit-SysPilotConfig` wiederhergestellt (waren im numerischen Menüumbau verloren gegangen und verursachten "Benennung nicht erkannt"-Fehler). Energieplan-Kurzwahl `Kuehl`/`Leistung` über `Set-SysPilotPlan` mit Admin-/Plan-Fehlerbehandlung. Doppelte Toolbox-Einträge (DNS, Health) entfernt, doppelter RAM-freigeben-Menüpunkt entfernt, System-Analyse wieder ins Menü aufgenommen.
- **Build**: Neues Skript `build.ps1` baut Installer (EXE) und Portable (ZIP) automatisch aus `version.txt`. Die Versionsnummer steht nicht mehr fest in Installer- und Bat-Dateien.
- **Banner/Module**: Versionsanzeige im Titel kommt aus `version.txt`.

---

# SysPilot 0.9.4.4 beta

- **GUI-Toolbox**: Werkzeuge starten jetzt über einen zentralen, robusten GUI-Launcher mit korrektem Arbeitsordner, Admin-Erhöhung und Fehlermeldungen.
- **Tooltips & Suche**: Toolbox-Buttons zeigen Erklärungen; per Rechtsklick ist eine KI-/Web-Suche zum Werkzeugthema verfügbar.
- **Tray-Tooltip**: Live-Informationen werden gekürzt und zuverlässig aktualisiert, damit Windows die Anzeige beim Mauszeiger korrekt übernimmt.
- **Arbeitsregeln für KI**: `AGENTS.md` legt Test-, Versions-, Installations- und GitHub-Fallback-Regeln verbindlich fest.
- **GitHub-Fallback**: `scripts/github-fallback.ps1` ermöglicht Commit/Push über PowerShell, wenn der GitHub MCP nicht funktioniert.

---

- **Guardian**: erkennt eine laufende SysPilot-GUI jetzt zuverlaessig ueber ihre Sperre (Mutex), auch wenn sie mit hoeheren Rechten laeuft als die pruefende Stelle.

---

# SysPilot 0.9.3.1 beta

- **Updates**: Neuer Button "Updates" im SysPilot-Fenster (zeigt die installierte Version, z. B. v0.9.3.1). SysPilot sucht ausserdem beim Start im Hintergrund auf GitHub nach einer neueren Version und meldet sie per Tray-Hinweis. Ein Klick laedt den Installer und aktualisiert; eigene Einstellungen bleiben erhalten. Abschaltbar: Tray-Menue "Beim Start nach Updates suchen".
- **Guardian**: SysPilot startet mit Windows unsichtbar im Infobereich und wird regelmaessig geprueft; laeuft es nicht, startet der Guardian es neu. Bewusstes "Beenden" im Tray-Menue wird bis zur naechsten Anmeldung respektiert.
- **Automatischer Start**: Nach der Installation oder einem Update startet SysPilot automatisch — auf Wunsch unsichtbar im Tray.
- **Einstellungen bleiben erhalten**: Startverhalten, Guardian, Autopilot, Sprache/Einheit und Update-Suche werden beim Update uebernommen.
- **Bewusst schlank**: SysPilot bleibt eine native PowerShell-/WPF-Anwendung und keine Electron-App. Dadurch wird unnoetiger RAM-Verbrauch vermieden; das Ziel sind viele clevere Funktionen in einem kleinen Tool.

## Ein persoenlicher Hinweis

Rueckblickend haette ich mit `0.0.0.1 alpha` anfangen muessen. Da ich aber schon eine Weile daran gearbeitet hatte, dachte ich, SysPilot sei fast fertig. Deshalb ist die Versionsnummer hoeher gestartet. Weil noch weitere Funktionen geplant sind, kann kuenftig eventuell eine weitere Versionsnummer hinzukommen.

Ich arbeite weiter an SysPilot. Vibe Coding mit KI ist allerdings teurer, als ich anfangs gedacht hatte — durch Zeit, API-/Tool-Kosten und viele Iterationen.

---

# SysPilot 0.9.3 beta (Vorgaenger)

- **Browser-Erweiterungen verwalten**: jetzt komplett mit Pfeiltasten bedienbar (hoch/runter, Bild auf/ab, Pos1/Ende, Enter oeffnet die Erweiterungs-Seite, Esc = zurueck). Lange Listen scrollen automatisch, die Position bleibt nach dem Oeffnen erhalten.
- Alle Pfeiltasten-Menues scrollen jetzt bei kleinen Fenstern und zeigen die Position (z. B. [12/48]).

---

# SysPilot 0.9.1 beta (Vorgaenger)

**Bugfix-Release**

- **Toolbox**: Werkzeuge starten wieder zuverlaessig, auch wenn SysPilot unter `C:\Program Files\SysPilot` installiert ist (Pfade mit Leerzeichen werden korrekt uebergeben; vorher blitzte nur kurz ein PowerShell-Fenster auf).
- **Checkup**: Fehler "Argument ... Parameter Path ... NULL" bei "Tote Registry-Verweise" behoben; echte .reg-Sicherung vor dem Loeschen.
- **Start**: Kein leeres PowerShell-Fenster mehr; Text-Menue bleibt bei "Als Admin neu starten" sichtbar.
- **Neu**: Option "Beim Start nur im Tray (ohne Fenster)" (Einstellungen bzw. Tray-Menue); ein zweiter Start holt das Fenster nach vorn.

---

# SysPilot 0.9 beta (Vorgaenger)

Der ehrliche, kostenlose PC-Optimierer für Windows 10/11 – ohne Abo, ohne Scareware, ohne Übertreibung. Open Source (MIT), Donationware.

**Deutsch** | English below

## Highlights

- **Automatic Checkup** (NEU): Ein Klick prüft 14 Bereiche – Junk, Privatsphäre, defekte Verknüpfungen, Registry-Waisen, Antivirus, Firewall, Sicherheitslücken, Autostart-Last, RAM-Druck, Festplattenfüllstand, Dienste, Bloatware, Optimierer-Konflikte, Temperatur. Jeder Fund mit ehrlicher Erklärung, Fixes einzeln abwählbar oder automatisch. In Konsole und GUI.
- **Toolbox** (NEU): 24 Werkzeuge in 4 Kategorien (System optimieren, Sicherheit & Reparatur, System bereinigen, Analyse & Info) – jedes mit verständlicher Beschreibung. In Konsole und GUI.
- **Netzwerk-Reparatur**: 14 Reparaturen (TCP/IP-Reset, Winsock, DNS-Flush, Firewall-Reset u.v.m.), inspiriert von Complete Internet Repair.
- **Netzwerkadapter-Identifikation**: Erkennt unbekannte Adapter (z. B. vgate0 = OPPO Connect) und bietet Deinstallation an.
- **Ressourcenfresser-Radar**: Findet RAM-/CPU-Hogs mit Erklärung, Direkt-Aktion (Ja/Nein) und 3 Howto-Links (offiziell / Google / KI-Suche).
- **Powerplan-Autopilot**: Wechselt Pläne automatisch nach laufender App (Gaming / Entwicklung / Browser) und Temperatur; Notfall-Ruhezustand bei Überhitzung.
- **Kühlen wie Camomile** – aber gratis: CPU-Boost und Throttling über offizielle Windows-Einstellungen.
- **Bloatware-Finder** mit bekannten Mustern (~70 UWP + Desktop), Reste-Entfernung nach Deinstallation.
- **Browser-Erweiterungen-Analyse** (Chrome/Brave/Edge/Firefox) inkl. KI-Duplikat-Erkennung.
- **WPF-GUI**: Dashboard mit CPU/RAM/Disk/Temperatur, Tray-Betrieb, Checkup- und Toolbox-Fenster.
- **Vollautomatik**: Auto-Optimierung (Backup → Dienste → Features → Tweaks → Prioritäten) in Menü, Toolbox und GUI.
- **Smart Boost**: Der Autopilot gibt RAM automatisch frei, wenn er knapp wird – einmal einschalten, nie wieder dran denken.
- **Installer-Häkchen** (standardmäßig an, abwählbar): Autopilot bei Anmeldung, Smart Boost, Immer als Administrator.
- **Komfort**: Pfeiltasten-Steuerung in allen Menüs, Deutsch/Englisch, °C/°F wählbar, Fortschrittsanzeigen.
- **Sauber**: GUI nur einmal (Single-Instance), kein sichtbares PowerShell-Fenster, "Beenden" = weiter im Tray, "Als Admin starten"-Button.
- **Ehrlich**: Jedes Backup vor jeder Änderung, keine erfundenen "Probleme", keine Panikmache.

## Installation

- **Installer**: `SysPilot-Setup-0.9.4-beta-x64.exe` (Windows 10/11, 64-bit) – installiert nach `Program Files\SysPilot`, Desktop-Verknüpfung inklusive.
- **Portable**: `SysPilot-0.9.4-beta-portable.zip` – entpacken und `SysPilot.ps1` bzw. `SysPilot-GUI.ps1` starten.

Beim ersten Start bitte als Administrator ausführen (für Powerpläne, Dienste und einige Fixes nötig). Details: [INSTALL.md](https://github.com/Habermann76/SysPilot/blob/main/INSTALL.md)

## Feedback & Fehler

Fehler melden und Funktionen vorschlagen: [GitHub Issues](https://github.com/Habermann76/SysPilot/issues) – Debug-Infos sammeln: Menüpunkt "Debug-Bericht" oder siehe [DEBUG.md](https://github.com/Habermann76/SysPilot/blob/main/DEBUG.md).

## Bekannte Einschränkungen (Beta)

- Temperaturanzeige auf Geräten ohne Sensor-Zugang = Schätzung (als solche markiert); echte Sensoren via LibreHardwareMonitor (GUI bietet Installation an).
- Einige Checkup-Fixes (Registry-Waisen, Sicherheitslücken) benötigen Admin-Rechte.
- Electron-Version, ARM64/x86/MSI-Installer und Auto-Update sind geplant: [ROADMAP.md](https://github.com/Habermann76/SysPilot/blob/main/ROADMAP.md)

---

## English

**SysPilot 0.9.1 beta** – the honest, free PC optimizer for Windows 10/11. No subscription, no scareware, no exaggeration. Open source (MIT), donationware.

- **Automatic Checkup** (NEW): one click scans 14 areas (junk, privacy, broken shortcuts, registry orphans, antivirus, firewall, security holes, startup load, RAM pressure, disk fill, services, bloatware, optimizer conflicts, temperature) with honest explanations and selectable fixes – console and GUI.
- **Toolbox** (NEW): 24 explained tools in 4 categories.
- **Network repair** (14 repairs, inspired by Complete Internet Repair) and **network adapter identification**.
- **Resource hog radar** with explanations, direct actions and howto links (official / Google / AI search).
- **Power plan autopilot** by running app and temperature, emergency hibernate on overheating.
- **Camomile-style cooling** for free, bloatware finder with leftovers removal, browser extension analysis, WPF GUI with tray mode, arrow-key menus, German/English, °C/°F.
- **Full automation** (one-click optimize), **Smart Boost** (auto free RAM), installer checkboxes for autopilot-at-logon / Smart Boost / always-run-as-admin.
- **Clean UX**: single-instance GUI, no visible console window, "Exit" keeps running in tray, "Run as admin" button.
- **Honest**: backup before every change, no invented "problems".

Download the x64 installer or the portable ZIP below. Run as administrator on first start. Report bugs and request features via [GitHub Issues](https://github.com/Habermann76/SysPilot/issues).

---

*Hobby-Projekt / hobby project – [Donationware](https://github.com/Habermann76/SysPilot/blob/main/DONATE.md): If you like it, donate what you want.* 💛
