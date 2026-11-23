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
