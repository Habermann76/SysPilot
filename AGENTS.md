# SysPilot – verbindliche Arbeitsregeln für alle KI-Modelle

Diese Datei ist vor Änderungen am Projekt zu lesen.

## Arbeitsweise
- **Analyse → Plan → Umsetzung → Korrektur:** Bei jeder Aufgabe zuerst analysieren (Code, Logs, echte Zustände prüfen — nicht raten), dann einen Plan formulieren, umsetzen und bei Fehlschlag gezielt korrigieren; wenn der Ansatz nicht funktioniert, betroffene Teile gezielt umschreiben statt weiter anzupassen. Immer den echten Fehler finden (z.B. HTTP-Body, Statuscodes, Logs), nicht nur Symptome.
- **OneDrive-Documents**: `Documents` ist OneDrive-umgeleitet → immer `[Environment]::GetFolderPath('MyDocuments')`, nie `$env:USERPROFILE\Documents` (verwaister Ordner). Betrifft `SysPilot\Models`, `api keys`, Exporte.
- **GGUF-Modelle**: Verteilung per Hardlink in Ollama/LM Studio/PocketAI/LlamaApp-Ordner + Registrierung (PocketAI `installed-models.json`, LlamaApp `ModelFolders`); llama.cpp-Server via `Start-SysPilotLlamaServer` (Vulkan/CUDA/ROCm Auto-Backend, Port 8390).
- **PATH**: `Repair-SysPilotPath` (Common.psm1) ergänzt fehlende Tool-Pfade im User-PATH automatisch beim Modul-Import; manuell via Provider-Menü `[PATH]`.
- **Kaggle**: `Get-SysPilotKaggleStatus`/`Invoke-SysPilotKaggleKernelPush`/`Show-SysPilotKaggleMenu` (AiAssist) — CLI-Kernels pushen umgeht „Notebook failed"; kernel-metadata.json ohne BOM.
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
- **0.9.5.2** ist der aktuelle Stand (Fix-Release: **Herbert-
  Ersteinrichtung** = echtes Live-Installations-Log — schwarze
  Konsole, `PgbInstall`-Progressbar, Schritt-Status + Heartbeat
  „laeuft seit Xs" in `Show-SysPilotHerbertOnboarding`; **Megastore**
  Checkbox-Dock-Fix (`DockPanel.Dock` ist attached property →
  `SetValue(DockPanel::DockProperty,...)` in AppStore.psm1);
  README-Screenshots + Camomile-Tabelle aktualisiert).
- **0.9.5.1** (neu: **KI-Provider-
  Revolution** — Katalog 134 Einträge via OmniRoute-Registry-
  Analyse (~60 Bezahl-Provider OpenAI-kompatibel + Free-Router +
  Keyless Kilo/OVH); **`Get-SysPilotAiRankedModels`** = automatische
  Best-Model-Selection (Kostenklasse/:free/Kontext) +
  Rate-Limit-Modell-Fallback; **Modell-Cooldowns**
  (`ai-model-cooldowns.json`, 15min, 429/Quota);
  **Smart Budget** `Get/Set-SysPilotAiBudgetMode`
  (smart/sparsam/qualitaet/aus) + `MonthlyTokenBudget` global +
  `TokenCapMonthly` pro Provider, gespeist aus `ai-usage.json`
  (Requests+Tokens/Monat); **Modell-Scope** `AllowedModels`
  (Prefix-Match in RankedModels); **Masked-Key** `Key:…wxyz` +
  Reveal-Aktion; **Voice** an/abschaltbar (`VoiceMode`
  off/speak/chat, `VoiceTts` system/provider — ffmpeg-dshow Aufnahme
  → `/audio/transcriptions` → Chat → `/audio/speech` oder
  `System.Speech` offline-DE; `Get-SysPilotAiFfmpeg` hat eigenen
  Fallback ohne Common-Import); **`/audio/speech`**-Endpoint;
  **SysPilot Extension Manager** `extension-manager/` (MV3,
  `chrome.management` — Liste/Suche/Enable-Disable/Remove,
  HTML-Export/-Import, Pfad `%LOCALAPPDATA%\SysPilot\extension-
  manager` wegen Chrome-Ordnerdialog-Falle OneDrive\Documents);
  **Browser-URL-Protokolle** `Register-SysPilotBrowserUrlSchemes`
  (HKCU, chrome://edge://brave://chromium://); **Router-Sync
  Modell-Plan** `Get-SysPilotProviderModelPlan` +
  `Save-SysPilotUsableProvidersArtifact` → `usable-providers.json`
  mit model+models-Fallback-Kette in allen 4 Syncs;
  **0.9.5.0**: **Task-Manager**
  `ProcessManager.psm1` Key `procs` + Process-Explorer portabel;
  **Pilot Herbert (Flug 667)** = KI-Branding + Programm-Start-
  Watcher (stumm schaltbar via `ChkKiHints`);
  **MCP-Client** `McpClient.psm1` Key `mcp` — Server-Import aus
  windsurf/cline-Configs, stdio+streamableHttp, defaults
  desktop-commander/powershell/github/browseros-neo, MCP-Tool-Calls
  im Chat mit Übernehmen-Buttons; **KI-Apps-Kategorie** –
  57 Tools in `Get-SysPilotUpdateCatalog` (Cat='KI-Apps'): lokale
  LLMs, Desktop-Clients, Agenten/CLI, Exoten (PocketAI Hub,
  Layla=PapaKoftes/Layla, FreeLLMAPI=tashfeenahmed/freellmapi,
  OmniRoute=cheaper-inference/OmniRoute `npm i -g omniroute`,
  freelm=shihabshahrier/freelm pip/npm, MCP Inspector/Desktop/ODR);
  `Find-SysPilotCatalogInstalled` erkennt zusätzlich
  `DetectPaths`/`DetectCmds` (portabel/npm/manuell); Detail-Ansicht
  bietet `NpmPkg`/`PipPkg`-Install-Aktionen (`Invoke-SysPilotCatalog-
  Npm/Pip`, pip via `python -m pip`) und `Note`-Hinweise;
  winget-IDs verifiziert: LMStudio=ElementLabs.LMStudio,
  Gemini=Google.GeminiDesktop, Devin=Codeium.Windsurf(!),
  GPT4All=nomic-ai/gpt4all (kein oeffentliches Repo-Fork);
  Msty/Witsy/Pieces haben KEIN oeffentliches GitHub-Repo → Page-only;
  **`Desc`-Feld**: Kurzbeschreibung aller 59 KI-Apps (Liste + Detail);
  **`WingetSource='msstore'`**: Warnhinweis (nie elevated) +
  Confirm vor Install + `aisearch`-Aktion (Win32/Fork-Suche) —
  Perplexity Desktop existiert NUR als MSIX (Web-Installer nutzt
  auch Store-System), Comet Browser = Win32-Alternative;
  Download-Portale &
  Web-Kataloge in PortableTools.psm1 + SoftwareUpdateCenter.psm1 –
  17 Portale als `[Portal]`-Apps + Update-Center-Liste, Ninite
  vollautomatisierbar (Katalog 160 Apps, `_xsrf`+`apps` POST →
  `/slug/ninite.exe`), `Get-SysPilotWebSourceVersions` mit
  automatisierten Versionen (Ninite/MajorGeeks/Uptodown/FOSSHub)
  + 13 manuellen Portalen, `Get-SysPilotAiPortalHint` = headless
  pollinations.ai-Abfrage (kostenlos, kein Key, kein Web-Zugriff
  → „KI-Angabe"-Label Pflicht), `Start-SysPilotAiSearch` =
  Engine-Auswahl Perplexity/Duck.ai/Gemini/Copilot; Headless-
  Scraping der meisten Portale blockiert: FileHippo/Softonic 412,
  Softpedia/Ghacks/AlternativeTo 403, Deskmodder/PortableApps/
  CHIP/WinFuture JS- oder Timeout → manuell lassen);
  **0.9.5.0-Fixes**: GetNewClosure/$script:-Modul-Falle im Update-
  Center behoben (geteilter State laeuft ueber `$fc`-Hashtable,
  Job-Codes als Closure-Locals), `Invoke-SysPilotMonitoredProcess`
  dekodiert Tool-Output strikte-UTF-8 mit ANSI-Fallback
  (winget-Mojibake `verfÃ¼gbar` weg), Scoop-Bucket-Auto-Fix
  stampft 24h-Drossel nur noch bei nachweislich behobenem WARN +
  hartnaeckiger WARN loest Repo-Reparatur aus, PM-Outdated-Scan
  deckt jetzt zusaetzlich bun + dotnet-Tools ab (NuGet-Flatcontainer),
  SmartDownload-Katalog-Suche durchsucht den lokalen Megastore-Index
  (appindex.json), Megastore-Kategorien: normalisierte Keyword-
  Substring-Heuristik + `Add-SysPilotAiIndexCategories` =
  Herbert-KI-Passage fuer 'Sonstige' mit Cache
  (appindex-aicat.json, inkrementell pro Rebuild);
  **0.9.4.9** (UninstallManager.psm1 –
  „CleanSweep" Deinstallations-Center nach REA-Funktionsanalyse von
  IObit Uninstaller; Key `uninstall`; **SoftwareUpdateCenter.psm1 –
  Update/Download-Center, Key `updates`**: winget+Chocolatey-Scan,
  147-App-Katalog in 7 Kategorien, GitHub-Releases, MajorGeeks-Resolver
  (89 Apps), Web-Kataloge; nach Analyse von IObit Software Updater,
  UpdateHub=Nexova (winget-Engine) und Patch My PC Home Updater;
  **PackageManagers.psm1 – Paketmanager-Integration** (Registry über
  14 Manager: WinGet, Chocolatey, Scoop, pip, npm, Bun, .NET Tool,
  PSGallery, Homebrew, APT/DNF/Pacman/Flatpak/Snap via WSL;
  Auto-Erkennung, Outdated-Scan merged in Update-Scan + Auto-Update,
  Suche in ALLEN Managern, Install fehlender Manager inkl.
  WSL-Distro-Einrichtung, `Show-SysPilotWslMenu` mit Live-Distro-
  Picker (`wsl --list --online`, 25 Distros), WSL-Manager
  (Bostrot.WSLManager), `.wslconfig`-GUI-Apps, `Show-SysPilotPm-
  CompanionsMenu` „GUI & Erweiterungen": UniGetUI portabel,
  Chocolatey GUI offiziell, OuiGui Chocolatey Community,
  Chocolatey AppStore Chrome-Ext (gepflegt), Legacy choco-chrome-ext
  (2016, ehrlich gelabelt), PM-Katalog-Links);
  **Update-Robustheit**: `Invoke-SysPilotWingetUpdateAuto` =
  winget → elevated-`--force`-Retry → Chocolatey/Scoop-Fallback
  (nur wenn der Manager das Paket wirklich installiert hat,
  exakter Match gegen gecachte `choco list`/`scoop list`);
  `Show-SysPilotAltManagerInstallMenu` = Remote-Suche in choco/scoop
  wenn winget-Download unmöglich (Katalog-Install + Failed-Retry,
  `-Adopt` für choco-Übernahme bestehender Apps);
  **Auto-Fix-Framework** (Common.psm1 Stamps): Scoop-Bucket-Git-
  Reparatur (packed-refs/tmp_leichen/locks), Self-Updates von
  npm/pip/choco, NuGet-Provider, winget source update — alles
  gedrosselt 24h–30d);
  0.9.4.8 (neu: Runtimes.psm1 – VC++/.NET/.NET
  Framework/AIO-Manager; RootCertificates.psm1 – portable
  UpdateRootCertificates-Tool-Verwaltung; PortableTools.psm1 –
  UniGetUI/Komi-Store/Uptodown-Desktop/WinUtil portable Apps + WinToys
  (App-Typ 'winget': winget install, Start via shell:AppsFolder
  oder EXE-Pfad aus Uninstall-Registry/.lnk; Source-Feld
  'msstore'|'winget'); iTop Easy Desktop, Ferdium (winget);
  Flipboard (nur Web — offizieller Client eingestellt);
  **Ultimate Windows Tweaker 5** (DownloadMode='majorgeeks':
  `Get-SysPilotMajorGeeksAsset` parst Version+Mirror-URL von der
  Detailseite, `Save-SysPilotMajorGeeksFile` lädt ueber
  WebRequestSession — Cookie von getmirror-Seite, dann
  `index.php?ct=files&action=download` → 302 auf files*.majorgeeks.com;
  thewindowsclub.com selbst blockiert per Cloudflare mit 403);
  **Microsoft PC Manager = Type 'storeapp'** (Erkennung+Start via
  Get-StartApps/shell:AppsFolder, `MatchName` für abweichende
  Startmenü-Namen; Installation regionsbeschränkt → öffnet
  Uptodown-Downloadseite; aka.ms-Links abgelaufen, Turnstile);
  **Uptodown Desktop = Type 'installer'** (`Install-SysPilotInstallerApp`:
  `download.uptodown.app/windows-client` liefert aktuellen Installer
  ohne Cloudflare-Block; SHA256-Feld = offizielle Prüfsumme; Inno
  `/VERYSILENT`; Erkennung+Start ueber Uninstall-Registry —
  DisplayIcon/InstallLocation werden getrimmt, weil sie quotiert sind;
  winget-Paket `Uptodown.UptodownClient` ist VERALTET (0.6.0 vs. 1.1.1));
  EXE-Fallback in Find-SysPilotPortableApp sucht bei Bedarf
  rekursiv (UWT entpackt in Versions-Unterordner `UWT 5.2\`);
  PrivacyFix.psm1 – 32 Datenschutz-/Werbe-Tweaks (Eigenname
  „PrivacyGuard", eigene Registry-Engine); PortableApps-Konvention;
  Runtimes jetzt **winget-first** (`Install-SysPilotRuntimeWinget`:
  Microsoft.VCRedist.2015+.x64/.x86, Microsoft.DotNet.DesktopRuntime.8/9/10/11,
  Microsoft.DotNet.Framework.Runtime = .NET FX 4.8.1), lokale Installer und
  offizielle Downloads als Fallback; Exit-Code 1638 = Erfolg; .NET-Framework-
  Installer brauchen `/q` nicht `/S`; Menüs leeren Tastenpuffer via
  `Clear-SysPilotPendingKeys` (Common.psm1); PortableApps-Scan cached
  `Get-StartApps` 20s (`$script:_startAppsCache` in PortableTools.psm1);
  0.9.4.7: WizTree, HardwareCheck, Drivers, SystemRepair, SystemTuning,
  HostsEditor, Win11-UI)
- **Tweak-Studio + Registry-Galerie (0.9.5.0)**: `TweakStudio.psm1`
  (Key `tweakstudio`) = eigener Tweak-Katalog (35 Tweaks, Ops-Engine
  NewKey/SetDefault/SetValue/DeleteValue/DeleteKey + Service-Art),
  Kontextmenue PowerShell/Terminal/Admin unter
  `HKCU\Software\Classes` (kein Admin), .reg-Backup vor jeder
  Aenderung, Favoriten, Status AN/aus/custom.
  `RegGallery.psm1` (Key `reggallery`) = kuratierte .reg-Galerie:
  Parse, 12 Kategorien, Heuristik-Risiko-Score (0-100), `reg export`-
  Backup vor `reg import`, KI-Sicherheitspruefung via Herbert,
  StepGuide-Ersteinrichtung. **Registry-Pfade mit `*` IMMER
  `-LiteralPath`** (sonst enumeriert Test-Path den ganzen
  Classes-Hive). Seed-Dateien in `reggallery/` (UTF-16LE+BOM).
- **KI-Provider-Intel & News (0.9.5.0)**: `Get-SysPilotAiProviderIntel`
  (AiAssist) = kuratierte `Cost`/`Content`-Metadaten pro Anbieter;
  `Invoke-SysPilotAiIntelCurate` = Herbert-KI-Kuration → Overlay
  `%LOCALAPPDATA%\SysPilot\ai-intel-extra.json` (Vorrang vor 'unbekannt');
  `Get-SysPilotAiNewsDigest` = News-Quellen Reddit/HN/HF-Blog/arXiv mit
  6h-Cache, `Get-SysPilotAiYoutubeSearch` via yt-dlp,
  `Show-SysPilotAiNewsItem` (öffnen/YouTube/KI-Summary),
  `Show-SysPilotAiNewsIntelMenu` = `[N]` im Provider-Menü (>120h `*`-Hinweis).
- **RSS/Miniflux-Clients (0.9.5.0)**: `Get-SysPilotRssMobileClients` =
  14 kuratierte Reader (Capy/FluxNews/Fleuron/FeedMe/ReadYou/Miniflutt,
  NetNewsWire/Unread/Reeder, Fluent Reader/RSS Guard) mit Store-Search-URLs;
  `Show-SysPilotRssClientSetup` = geführtes Setup (URL aus Config,
  Plattformen, API-Hinweise Fever/Google-Reader), `Show-SysPilotQrCode`
  (api.qrserver.com), `Show-SysPilotAdbRssAssist` (adb + market://search-
  Intents). Aufruf: `[C]` im Miniflux-Setup, `[Clients]` im RSS-Feeds-Menü,
  KiAction `rss-clients`.
- **TV-Setup (0.9.5.0)**: `Show-SysPilotTvSetup` (AiAssist) = Android-TV/
  Fire-TV-Assistent: ADB (`Connect-SysPilotTvAdb`: IP→5555, Android-TV-
  Pairing), Debloat via `pm disable-user` (reversibel, Backups in
  `%LOCALAPPDATA%\SysPilot\tv-debloat`), APK-Sideload (`Install-SysPilotTvApk`),
  App-Katalog (KodiRoll, VYPN, SquiffNet, StreamFlix, OTT, Downloader,
  FlixVision+Warnung, TechDoctorUK/DocSquiffy/XMedia), Launcher,
  Fire-TV-Downloader-Codes. KiSetupWizard + KiAction `tv-setup`.
  SoftwareCenter Media-Center: KodiRoll Build + VYPN.
- **Security-Lab (0.9.5.0)**: `Show-SysPilotSecLabSetup` (AiAssist) =
  geführtes Security-Lab: Kali Linux in WSL (`Install-SysPilotWslDistroByName
  'kali-linux'`, Start via `wsl -d kali-linux`/Windows-Terminal), unzensierte
  Modelle via `Show-SysPilotAiModelFinder` (HF-Presets abliterated/heretic/
  uncensored/dolphin), 5-Schritte-Einfuehrung + Rechtshinweise (§202a/b,
  §303a/b, NIS2 — nur eigene Systeme). KiAction `seclab`.
- **Bordansagen stumm schaltbar**: `Get/Set-SysPilotHerbertAnnouncementsEnabled`
  (Default = ProcessHints), GUI `ChkKiAnn`, Konsole `kiannouncements`.
- Alle GUI-Tools im Vollmenü, in der WPF-GUI und in der Toolbox
- **Installierte Version IMMER synchron halten**: nach Änderungen
  `powershell -File _sync_installed.ps1` elevated ausführen
  (`Start-Process powershell -Verb RunAs -ArgumentList ... -Wait`),
  danach `_sync_check.ps1` (Hash-Vergleich). Program Files braucht Admin.

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
- **PortableApps-Konvention (0.9.4.8)**: NIEMALS hartcodierte Pfade wie
  `C:\Users\haber\...` oder `$env:LOCALAPPDATA\Programs` für portable
  Tools verwenden. `Get-SysPilotPortableAppsDir` (Common.psm1) löst das
  Benutzer-PortableApps-Verzeichnis auf (OneDrive-Desktop falls
  umgeleitet), `Get-SysPilotLocalSearchDirs` = Downloads + PortableApps
  für Installer-Suchen. Portable Tools (SDI, LibreHardwareMonitor,
  Runtime-Installer) gehören dorthin; Erkennungs-Pfade müssen den Helper
  nutzen.
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
- **Freie Texteingaben (0.9.5.0, verbindlich)**: NIEMALS `Read-SysPilotChoice`
  für freie Texteingaben (Namen, URLs, IPs, Keys, Pfade, Suchbegriffe) —
  immer `Read-SysPilotInput` (Common.psm1) verwenden: öffnet einen
  WPF-Dialog (Rechtsklick = Einfügen, Enter = OK, Esc = Abbruch,
  `-Default`, `-Multiline`, `-BrowseFile`, `-BrowseFolder`), fällt bei
  nicht-verfügbarem WPF automatisch auf Read-Host zurück. Rückgabe:
  String ('' bei leerem OK) oder `$null` bei Abbruch — für
  `if (-not $x)`-Prüfungen kompatibel. Einfache ja/nein-Fragen und
  Menü-Auswahlen bleiben `Confirm-SysPilot`/`Show-SysPilotArrowMenu`.
  Komplexere Verwaltungs-UI gehört in WPF-Fenster **im Modul**
  (Beispiel: `Show-SysPilotAiProvidersWindow`/`...EditDialog`/
  `...SuggestionsWindow` in AiAssist.psm1, `-Owner`-Parameter optional,
  `Add-Type -AssemblyName PresentationFramework,...` am Funktionsanfang,
  Console-Fallback vorsehen).
- **GetNewClosure + `$script:` in Modulen = FALLE (0.9.5.0, verbindlich):**
  In **Modul-Context** sehen `.GetNewClosure()`-Scriptblöcke (WPF-Click-
  Handler, Timer-Ticks) die Modul-`$script:`-Variablen **nicht** — der
  Closure bekommt einen eigenen, leeren Script-Scope. Geteilter State
  (Job-Code-Strings, Queues, Busy-Flags, Listen) MUSS über ein lokales
  **Hashtable** laufen, das per Referenz in allen Closures geteilt wird
  (Pattern: `$fc = @{ Control=...; ucState=... }`, Zugriff `$fc.ucX`).
  Reine Funktions-/Plain-Scriptblock-Aufrufe (`& $helper` ohne
  GetNewClosure) sehen Modul-`$script:` dagegen korrekt. Der Fehler ist
  tückisch: `BeginInvoke` liefert ok, aber `AddScript('')`/leere Variablen
  produzieren **null** Output ohne jede Exception. Debuggen: suspect
  Scope zuerst prüfen (Mini-Modul-Test), nicht den Runspace.
- **Native-Tool-Output-Encoding (verbindlich für Downloads/Treiber/etc.):**
  `Invoke-SysPilotMonitoredProcess` (Common.psm1) leitet Tool-Output in
  eine Temp-Datei um und dekodiert sie jetzt **strikt-UTF-8 mit
  ANSI-Fallback** (`[Text.UTF8Encoding]::new($false,$true)`, bei
  DecoderFallback auf `[Text.Encoding]::Default`). Grund: winget
  emittiert UTF-8, aeltere Konsolen-Tools (choco/scoop/installer)
  ANSI/OEM — `Get-Content` ohne `-Encoding` las BOM-lose Dateien als
  ANSI → Mojibake (`verfügbar` → `verfÃ¼gbar`). Dieselbe Falle gilt für
  JEDE Stellen, die Native-Output aus Dateien/Streams lesen
  (Treiber-Tools, Download-Checks, `Read-SysPilotFileTailLine`).
- **Guided-Setup-Pattern (verbindlich für Installations-/Einrichtungs-
  Features, 0.9.5.0):** Neue Setup-/Installations-Flows (Server,
  Cloud, Self-Host, externe Dienste) müssen diesem Dreiklang folgen:
  1. **Maximal automatisch:** SysPilot führt alle technisch möglichen
     Schritte selbst aus (Downloads, Configs, Services, Diagnosen) —
     nur dort fragen, wo es wirklich nötig ist (Rechte, Accounts,
     Browser-Logins, kostenpflichtige Aktionen).
  2. **Doctor-Funktion:** ein Diagnose-Menüpunkt, der Zustand prüft
     (Daemon/Container/Port/Service/Config) und **Ein-Klick-Fixes**
     per Confirm anbietet — Muster: `Show-SysPilotMinifluxDoctor`.
  3. **ADHS-Howto für User-Aktionen:** Was der User tun muss, läuft
     über `Show-SysPilotStepGuide` (Common.psm1) — EIN Schritt
     gleichzeitig, `Enter`=weiter, `u`=URL öffnen, `v`=YouTube-Suche
     (`Yt`-Feld pro Schritt), `z`=Abbruch. Nie mehrschichtige
     Anleitungs-Wände oder Nummernlisten ohne Interaktion.
  Referenz-Implementierung: Miniflux-Setup in `AiAssist.psm1`
  (`Show-SysPilotMinifluxSetup` + `...Doctor` + `...OracleGuide` +
  `Show-SysPilotCfNamedTunnel`).
- **Miniflux lokal via Docker (getestet 2026)**: `Show-SysPilotMinifluxSetup`
  Tag `'docker'` legt Stack in `%LOCALAPPDATA%\SysPilot\miniflux`
  an (postgres:17-alpine + miniflux/miniflux:2.3.5, Healthchecks,
  `depends_on: service_healthy`, Access via `http://localhost:<port>`,
  Login admin + Passwort in `ZUGANG.txt`). **Auto-Port-Fallback:**
  Setup probe't localhost:8080 — antwortet dort ein Fremd-Service
  (kein Miniflux-OK), wird `8081:8080` geschrieben; Quick-Tunnel,
  Doctor und Tailscale-Funnel lesen den Port aus der Compose-Date.
  API: Basic-Auth, POST `/v1/feeds` (PUT→405). Docker-Desktop-NAT +
  Hotspot ⇒ Feed-Adds können 500er (Fetcher-Timeouts) werfen —
  Retry hilft, Netzwerk-Sache. **Feste URL:** `Show-SysPilotTailscaleFunnel`
  (KiAction `ts-funnel`, Menü-Tag `tsfunnel`) = Tailscale Funnel
  `https://<pc>.<tailnet>.ts.net` — KOSTENLOS, kein Domain nötig,
  funktioniert hinter NAT/Hotspot, Service überlebt Reboot.
  Cloudflare named tunnel braucht Zone (Domain) — ohne Domain
  nur Quick-Tunnel mit Zufalls-URL. no-ip/ddns braucht Port-Forwarding
  → am Mobilfunk-Hotspot nutzlos. **Reddit hat anonyme `.rss`-
  Endpoints eingestellt (404/429)** — `Get-SysPilotRssFeedSuggestions`
  markiert Reddit- + GOG-Feeds automatisch `HtmlOnly`,
  `Export-SysPilotRssOpml` filtert sie raus (bleiben als HTML-Links
  im Menü).
- **Maussteuerung in Konsolen-Menüs (0.9.4.8)**: `Show-SysPilotArrowMenu`
  und `Show-SysPilotMultiSelectMenu` lesen Eingaben über
  `Read-SysPilotMenuEvent` (Common.psm1) statt `ReadKey` — das puffert
  Tastatur- UND Maus-Events aus `ReadConsoleInput` (P/Invoke
  `SysPilotConsoleInput`, ENABLE_MOUSE_INPUT). **Wichtig:**
  `ReadConsoleInput` liefert bis zu 32 Records pro Call — ALLE müssen
  in `$script:_menuEventQueue` (`System.Collections.Queue`) gepuffert
  werden (`ConvertTo-SysPilotMenuEventRecord`); nur das erste Event
  zurückzugeben verschluckt den Rest (Pfeiltasten/Klicks gingen in
  echten Tests „manchmal" verloren). Move-Events bei voller Queue
  (>100) verwerfen. Queue wird in `Clear-SysPilotConsoleInputBuffer`
  geleert. Linksklick = auswählen
  (Single) / Haken umschalten (Multi), Mausrad = blättern, Hover =
  Markierung (nur bei Zeilenwechsel wird neu gezeichnet, `$needDraw`).
  Eintragsposition wird live via `CursorPosition.Y` als `$itemStartRow`
  erfasst (deckt umbrochene/laengere Titel ab).
  `WaitForSingleObject`-Timeout als `[uint32]::MaxValue` übergeben
  (0xFFFFFFFF wird von PS als -1 geparst → uint32-Konvertierungsfehler).
  **`CursorPosition` ist `Coordinates` mit NUR `.X`/`.Y` — `.Top`
  gibt $null** (Maus-Klicks landen dann auf keiner Zeile).
  Modus wird im `finally` via `Restore-SysPilotConsoleInput` restauriert
  (sonst bleibt QuickEdit-Markierung in conhost deaktiviert). Ohne echte
  Konsole (ISE, Remoting, Pipes) liefert `Initialize-` `$false` →
  Fallback auf `ReadKey` = Tastatur-only. Nie `ReadKey` UND
  `ReadConsoleInput` parallel mischen — die Menüs nutzen ausschließlich
  `Read-SysPilotMenuEvent`.
- **Maus-Ja/Nein-Dialog (0.9.4.8)**: `Confirm-SysPilot` nutzt jetzt
  `Read-SysPilotYesNo` (Common.psm1) — `[ Ja ]`/`[ Nein ]` per Klick
  (Zones: col 3-10 = Ja, 11-18 = Nein auf der Optionszeile `$optRow`),
  Mausrad = umschalten, j/y/n-Tasten, Pfeile+Enter, Esc = Nein.
  Default = Nein (sicher). **Clear-Host + komplettes Neuzeichnen pro
  Redraw** (0.9.5.0-geaendert): frueher wurde die Optionszeile per
  `CursorPosition = Coordinates(0, $optRow)` partiell ueberschrieben -
  unter ConPTY/Windows Terminal schlug das fehl und jede Bewegung haenge
  eine neue `[ Ja ] [ Nein ]`-Zeile an (Klicks ins Leere, "Endlosschleife").
  `$optRow` wird jetzt nach JEDEM Draw frisch via `CursorPosition.Y`
  gelesen (Fragen mit Newlines/Wrap sind abgedeckt). Ohne Console-API
  Fallback auf altes `Read-Host`-j/n.
- **„Weiter mit Enter" pausieren (0.9.4.8)**: `Read-SysPilotChoice`
  erkennt Prompts mit `^weiter` und wartet dann mausfaehig auf
  Klick/beliebige Taste (statt Read-Host); gibt `''` zurueck wie
  bloßes Enter. Echte Texteingabe-Prompts (z.B. `... (j/n)`,
  IP-Adresse, Suchbegriff) bleiben unveraendert auf Read-Host.
  `$hadApi` muss VOR `Initialize-SysPilotConsoleInput` gesichert
  werden, sonst wird der Console-Modus nie restauriert (QuickEdit
  bliebe dauerhaft aus!).
- **QuickEdit-Falle (0.9.4.8, kritisch)**: `ENABLE_QUICK_EDIT_MODE`
  (0x40) muss beim Aktivieren der Maus unbedingt deaktiviert werden —
  conhost behandelt die Maus sonst selbst (Textauswahl) und liefert
  NULL Mouse-Records an die App (Klicks/Rad wirkungslos, ohne
  Fehlermeldung). `Initialize-SysPilotConsoleInput` setzt daher
  `(mode -bor 0x10) -band (-bnot 0x40)`; Original-Modus wird in
  `Restore-SysPilotConsoleInput` zurückgesetzt. MAUSRAD-Flag ist
  `dwEventFlags=0x0004` (MOUSE_WHEELED), NICHT 0x0002 (Double-Click);
  Delta steckt im HIWORD von dwButtonState (vorzeichenbehaftet).
  Live-Test: injizierte Events in Conhost — ohne QuickEdit-Fix 0
  Records, danach Move/Click/Wheel korrekt; `Show-SysPilotArrowMenu`
  per Mausklick → TAG_C.
- **Launchable-Pfad-Filter (0.9.4.8)**: `Test-SysPilotLaunchablePath`
  (Common.psm1, exportiert) erlaubt nur `.exe/.bat/.cmd/.com/.ps1/.lnk/
  .url/.msc/.reg` — wird in `Find-SysPilotStoreApp`,
  `Find-SysPilotPortableApp` (PortableTools), `Get-SysPilotSdiExe`
  (Drivers) und WizTree-Erkennung genutzt. **Ohne Filter** nahm
  `(Get-Item $cand) -is [IO.FileInfo]` jede Datei — z.B. Flipboards
  alter Store-Eintrag zeigte auf `...\Web Applications\...\Flipboard.ico`
  → `Start-Process` auf .ico → Windows-„Oeffnen mit"-Dialog.
  `Type='web'`-Apps (Flipboard): `Find-SysPilotPortableApp` gibt $null
  (kein lokales Install), `Start-SysPilotPortableApp` sucht zuerst per
  `Find-SysPilotStoreApp`/`Get-StartApps` nach Browser-PWA
  (`shell:AppsFolder\<AppId>`, z.B. `Brave._crx_...`), sonst Web-URL.
- **SysPilot-Neustart (0.9.4.8)**: `Restart-SysPilot.ps1` (Repo-Wurzel,
  wird installiert + als „SysPilot Neustart"-Verknüpfung auf dem
  Desktop und im Startmenü bereitgestellt) beendet alle SysPilot-
  Prozesse und startet die GUI neu. **Wichtig**: elevated Instanzen
  (z.B. GUI im Tray) liefern ohne Adminrechte `CommandLine=$null` und
  sind per `Win32_Process`-Match unsichtbar — deshalb prüft das Skript
  zusätzlich den Single-Instance-Mutex `Local\SysPilotGUI-SingleInstance`
  (`Mutex.WaitOne(0)`); ist er belegt oder bleiben sichtbare Prozesse
  übrig, wird das Skript elevated neu gestartet (UAC) und tötet dann
  alles. `stop-syspilot.ps1` (Installer-Helfer) nutzt denselben
  CommandLine-Filter — beide schließen sich per `-notmatch` selbst aus.
- **Direkt-Tool-Keys**: Für Tools, die per Button DIREKT eine Funktion
  aufrufen sollen (nicht nur ein Untermenü), zusätzlich eigene Keys im
  `Invoke-SysPilotTool`-Switch anlegen (Beispiel 0.9.4.7:
  `win11ui`/`win11taskbar`/`win11ctx`/`win11ctxadmin`/`win11ctxrestore`
  → je eigener Case).
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
- **Win11-Kontextmenue-Reparatur (0.9.4.8)**: `Restore-SysPilotWin11ContextMenu`
  (SystemTuning.psm1, Key `win11ctxrestore`) diagnostiziert und entfernt
  Tweaker-Schaeden: CLSID-Override in HKCU **und** HKLM/WOW6432Node,
  blockierte Shell-Erweiterungen (`Shell Extensions\Blocked`), prueft
  FileExplorer-DLLs (`FileExplorerExtensions.dll`/
  `FileExplorerManaged.dll` in `MicrosoftWindows.Client.FileExp_*` —
  NICHT `Windows.UI.FileExplorer.dll`, das existiert nicht), startet
  Explorer neu. HKLM-Befunde loesen Admin-Neustart-Angebot aus.
  Live getestet: Override anlegen → Classic, Funktion → Win11.
- **CleanSweep / UninstallManager.psm1 (0.9.4.9)**: eigenstaendige
  SysPilot-Implementierung nach REA-Funktionsanalyse von
  `IObitUninstaler.exe` (Delphi/VCL, ~10,6 MB, x86; Ghidra-Timeout wie
  bei SDI → PE-Resources + ~116k Strings genuegten; kein Code kopiert).
  Key `uninstall` (Vollmenue, -Tool, Toolbox „System bereinigen").
  WICHTIGE Fallen aus der Implementierung:
  - **Unquotierte UninstallStrings**: viele Eintraege sind
    `C:\PF\App\uninst.exe /x` OHNE Anfuehrungszeichen trotz Leerzeichen
    im Pfad. Parser muss bis zum ersten `.exe`-Token scannen, sonst
    faelschlich „defekter Eintrag" (9 Fehlalarme → Parser gefixt → 0).
  - **4 Registry-Sichten**: HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\
    Uninstall, HKLM\SOFTWARE\WOW6432Node\...\Uninstall, HKCU-Varianten.
  - **Verwaiste Programme**: Ordner-Match per normalisiertem Namen gegen
    das komplette Programm-Inventar; Windows-Inbox-/Systemordner
    (Microsoft.*, Windows*, Intel, NVIDIA, Common Files, Servicing,
    Fonts, Microsoft.NET) IMMER ausblenden — sonst ~30 Fehlalarme.
  - **Leftover-Scanner**: Security-Score 0-100 pro Fund. Dateien→
    Papierkorb, Registry→`.reg`-Export-Backup unter
    `backup\leftovers\<ts>`, nie hart loeschen ohne Bestaetigung.
    Eigener SysPilot-Installationsordner darf nicht pauschal als Rest
    gelten — nur explizit gescannt.
  - **Browser-Extensions**: Chromium via `Secure Preferences`/`Preferences`
    (JSON — `extensions.settings.<id>` + `extensions.alerts.<id>`
    entfernen, `Extensions\<id>`-Ordner + Local/Sync Extension Settings
    in Papierkorb; Backup unter `backup\extensions`). Firefox via
    `extensions.json`. Laufende Browser warnen (Profil-Lock).
  - **Destruktive Aktionen**: IMMER `Confirm-SysPilot` + Log via
    `Write-SysPilotLog`; Restore-Point nur auf expliziten Wunsch
    (Checkpoint-Computer braucht Admin); wusa nur mit Bestaetigung.
  - **Edge/Secure-Preferences-Falle (0.9.4.9)**: Edge-Dateien enthalten
    DUPLIKATE JSON-Schluessel (`macroEnabled.12`/`macroenabled.12`,
    Filetype-MIME-Types in Extension-Eintraegen) → `ConvertFrom-Json`
    wirft komplett → Edge lieferte 0 Extensions. Loesung in Common.psm1:
    `Get-SysPilotJsonChildProperties` (Scanner fuer direkte Kind-Keys),
    `Get-SysPilotChromiumExtensionSettings` (Fallback baut minimal-
    objets manifest.name/version/type+state), `Remove-SysPilotPref-
    ExtensionEntry` (roh-Text-Edit von settings+alerts inkl. Komma —
    NIE ConvertTo-Json-Rewrite, der wuerde die Datei zerstoeren).
    Live: Edge 0 → 248 Extensions, Gesamt 425 → 674.
  - **Tor Browser**: Firefox-basiert, portabel → `Get-SysPilotBrowser-
    Profiles` sucht `TorBrowser\Data\Browser\profile*` auf Desktop
    (OneDrive-sicher via GetFolderPath), LOCALAPPDATA, Program Files;
    Engine='firefox' (extensions.json), Browser-Label 'Tor'.
  - **Multiselect-Fenster (0.9.4.9)**: `Show-SysPilotMultiSelectMenu`
    zeichnet bei >25 Eintraegen nur ein Scroll-Fenster ($viewTop/
    $viewEnd, Maus-Row→Index via $viewTop-Offset, Footer zeigt
    „Eintrag x/y") — vorher flackerte die Anzeige bei jedem Hover
    (Clear-Host + 400+ Zeilen). Key 'A' (65) = alle abhaecken.
  - **Extension-Removal-Loop**: `Show-SysPilotExtensionRemoval` lädt
    nach jeder Entfernung das Inventar neu → erlaubt Batch (mehrere
    markieren + Enter) UND einzeln-nach-und-nach; Filter bleibt aktiv.

### Paketmanager & Update-Center (0.9.4.9, verbindlich)
- **PackageManagers.psm1**: Registry in `Get-SysPilotPackageManagerDefs`
  (Id/Name/Kind/Exe/UpgradeHint); `Get-SysPilotPackageManagers` merged
  Windows- und WSL-PMs (Linux-PMs laufen über `wsl -d <distro> -- <cmd>`,
  `docker-desktop` wird als Infrastruktur-Distro ausgeschlossen).
  Outdated-Quellen: scoop (`Invoke-SysPilotScoopRaw` — scoop.cmd
  umgeht PS-Redirection, WARNs nur via `cmd /c` sichtbar),
  npm (`npm outdated -g --json`), pip (PyPI-JSON pro Paket),
  dotnet (`dotnet tool list -g`), PSGallery (`Find-Module` +
  `Get-InstalledModule`; NuGet-Provider >= 2.8.5.208 nötig).
- **WSL-Falle**: `wsl.exe` gibt UTF-16 mit Null-Bytes aus → IMMER
  `[regex]::Replace($out,"`0",'')` vor dem Parsen (`Get-SysPilotWslStatus`,
  `Get-SysPilotWslOnlineDistros`). Distro-Install: `wsl --install <name>`
  (WSL 3.x), Fallback `-d <name>`; PM-Einrichtung via
  `wsl -u root -d <distro> -- <pm>` + `command -v`-Verify;
  `apt-get update` kann beim ersten Mal >60s brauchen → Timeout 300.
- **choco-Fallen (live verifiziert)**:
  - `choco outdated` listet Pakete mit **identischer Version**
    (chocolatey.server 0.3.0|0.3.0) → Phantom-Updates; IMMER
    Versionsvergleich (`ConvertTo-SysPilotVerObj`) vor dem Row-Bau.
  - `choco upgrade` **exit 0 bei 0/N aktualisiert** + Warning
    „was not found with the source(s)" → NIE auf $LASTEXITCODE
    vertrauen; `Invoke-SysPilotChocoUpgradeAuto` parst
    `Chocolatey upgraded X/Y` + Source-Warnings.
  - `choco list --local-only` ist langsam (~10-20s) → 10-Min-Cache
    ($script:_chocoNamesCache); Package-Erkennung sonst über lib-Ordner
    (`$env:ProgramData\chocolatey\lib\<pkg>` UND
    `$env:LOCALAPPDATA\UniGetUI\Chocolatey\lib\<pkg>` — UniGetUI bringt
    eine EIGENE Chocolatey-Installation mit!).
  - MSI-Pakete (chocolateygui) hinterlassen leere `InstallLocation`/
    `DisplayIcon` im Uninstall-Key → Install-Pfad zusätzlich aus
    `C:\Program Files (x86)\<Name>` + lib-Rekursivscan prüfen.
  - `choco search <begriff> --limit-output` → `id|version`-Zeilen;
    Ergebnisse für Remote-Kandidaten (`Find-SysPilotChocoRemoteCandidates`).
- **pip-Falle**: `pip.exe install --upgrade pip` schlägt IMMER fehl
  (pip verlangt `python -m pip ...`) → `Get-SysPilotPythonExeForPip`
  löst python.exe aus `Scripts\pip.exe`-Umgebung auf, Fallback `python`.
- **winget-Fallen**: `Invoke-SysPilotWingetRaw` nutzt
  `System.Diagnostics.Process` + `ReadToEndAsync` + echten Timeout
  (kein `| Out-String` — puffert ewig). Fehler-Klassen via
  `Get-SysPilotUpdateFailKind`: `not-applicable` (exit 43/andere
  Quelle/Architektur — z.B. aus MS Store oder manuell installiert,
  winget kann prinzipiell nicht), `publisher` („kann nicht mit
  WinGet aktualisiert werden"), `admin` (MSI 1603 → elevated retry
  mit `--force`), `timeout`. `not-applicable`/`publisher` werden nach
  2 Fehlversuchen im Auto-Update übersprungen (Stamp in
  `%LOCALAPPDATA%\SysPilot\update-center.json`, KEIN Program Files —
  ohne Admin nicht beschreibbar!).
- **Fallback-Kette**: `Invoke-SysPilotWingetUpdateAuto` =
  winget → elevated `--force` → `Invoke-SysPilotAltManagerUpgrade`
  (choco/scoop NUR wenn Paket dort installiert — exakter Match,
  `openvpn` ≠ `openvpn-connect`). `Show-SysPilotAltManagerInstallMenu`
  = Remote-Suche für Neuinstallation/Adoption (Katalog-Install-Fail
  + Failed-Retry-Aktion „Anderer Paketmanager"). Live: FACEIT→Faceit,
  SteamArtManager→steam-art-manager, MEGAsync→megasync,
  OnionShare→onionshare in Chocolatey Community; TeraBox nicht.
- **GUI & Erweiterungen ehrlich labeln**: Chocolatey GUI = offiziell
  (`chocolateygui`); OuiGuiChocolatey = Community; Chocolatey
  AppStore (`chocolatey-appstore-chrome`) = gepflegte Chrome-Ext;
  `choco-chrome-ext` = 2016 inoffiziell/unlisted → nur mit
  expliziter Risiko-Bestätigung. Es gibt KEINE offizielle
  Chocolatey-Browser-Extension — nicht erfinden.
- **UniGetUI** ist die „GUI für alle" (winget/choco/scoop/msstore),
  portabel als ZIP in PortableTools; kein eigener GUI-Bau nötig.
- **Download-Portale & Web-Quellen (0.9.4.9)**: 17 Portale in
  `$script:PortablePortalDefs` (PortableTools.psm1, DE+EN inkl.
  portableapps.com) — werden im Apps-Menü als `[Portal]`-Block
  (`$allApps` = PortableAppDefs + Portal-Pseudo-Apps Type='web')
  und in Update-Center → `Show-SysPilotWebCatalogs` (Ninite IMMER
  zuerst, Label „[automatisierbar]") gelistet. **Ninite-Mechanismus
  (live verifiziert)**: GET ninite.com → `_xsrf`-Token +
  `name="apps" value="<slug>"`-Checkboxen (160 Apps, Titel+Version
  im `label-title`), POST `_xsrf`+`apps=slug&...` → Antwort enthält
  `href="/<slug-pfad>/ninite.exe"` → Download+Start; Installer
  läuft still im Hintergrund, überspringt aktuelle Apps.
  **`Get-SysPilotWebSourceVersions`** (SoftwareUpdateCenter):
  Auto-Quellen Ninite/MajorGeeks/Uptodown/FOSSHub via Slug-Raten +
  Verifikation — FÄLLE: (a) Query-Wörter length>=1 behalten
  (`7-Zip` → slug `7-zip`, nicht `zip` → falsche Seite),
  (b) MajorGeeks-Version = `itemprop="softwareVersion" content=`,
  Uptodown = erstes `version">X` (neueste zuerst), FOSSHub =
  `"softwareVersion"` im JSON-LD (Seite hat dutzende SVG-`<title>`
  → NICHT `<title>`-Check, sondern `"name": "...<wort>`),
  (c) Ninite-Titel sind Marketing-Namen („Great Video Player"
  für vlc) → Slug steht in haystack, Needles: Phrase+kompakt+
  erste Wort-Matching mit `\b`-Grenze für 3-Zeichen (`zip` trifft
  sonst peazip), (d) FileHippo = 412 Bot-Schutz → ehrlich „manuell".
  Liste sortiert per `ConvertTo-SysPilotVerObj`, „NEUESTE" markiert.
  Update-Kette-Ende: Alt-Manager-Menü ohne PM-Treffer → automatisch
  WebSourceVersionsMenu; Failed-Item-Aktion „websrc".
- **Fortschritt/Hänger-Erkennung (0.9.5.0, verbindlich)**:
  `Invoke-SysPilotMonitoredProcess` (Common.psm1) ist DER Standard
  für alle externen Prozesse mit potentiellem Langlauf (winget,
  choco, scoop, npm, pip): läuft über `cmd /c ... > tempfile 2>&1`,
  pollt Output-Größe + CPU-Zeit; Stall = keine Output- UND
  CPU-Aktivität > StallWarnSec → Warnung + `[Q] Abbruch /
  `[Enter] weiter` (nur bei Console-Input, sonst silent).
  `Save-SysPilotUrlToFile` (Common) = Standard-Downloader mit
  %/MB-s/ETA + Stall-Abbruch (`-AllowAbort`). `Save-SysPilotDownload`
  (SUC) und Updater/Temperature delegieren dorthin. elevated-Pfade
  (Start-Process -Verb RunAs) können keinen Output liefern →
  nur_elapsed_-Spinner, kein Stall-Check (ehrlich).
- **KI-Suche (0.9.5.0)**: `Get-SysPilotAiPortalHint` (Version+URL,
  mit `Test-SysPilotUrlReachable`-Link-Check → `LinkOk`),
  `Get-SysPilotAiAlternatives`/`Show-SysPilotAiAlternativesMenu`
  (Forks/Alternativen, `NAME | Desc | URL`-Parsing, Kind=github/
  gitlab/fosshub/web). pollinations.ai = kostenlos aber ~3
  Requests/Min Rate-Limit + kein Web-Zugriff → IMMER als
  „KI-Vorschlag" labeln; Browser-Engines (Perplexity etc.) bleiben
  der verlässliche Weg. `aisearch`-Aktion im Katalog für ALLE Apps.
- **KI-Assistenz-Modul (0.9.5.0, `AiAssist.psm1`, Key `kiassist`)**:
  `Invoke-SysPilotAiChat` = OpenAI-kompatibler Client mit
  Fallback-Kette über `Get-SysPilotAiProviders` (lokale Router
  Ollama:11434/LMStudio:1234/FreeLLMAPI:3001/OmniRoute:20128 per
  Port-Probe+30s-Cache, dann konfigurierte Cloud-Provider, dann
  Pollinations `text.pollinations.ai/openai` — KOSTENLOS, kein
  Key, OpenAI-kompatibel, ~1-3 req Rate-Limit). Config in
  `%LOCALAPPDATA%\SysPilot\ai-assist.json`, Keys DPAPI-verschlüsselt
  (Protect/Unprotect-SysPilotSecret). `Show-SysPilotAiQuickAsk
  -Prompt -System` = Einmal-Frage für Modul-Integrationen.
  **Cline-Antwort**: Cline-Free-Modelle sind an die VS-Code-
  Extension gebunden (OAuth/Account) → NICHT headless nutzbar.
  Kostenlose Alternativen: Gemini AI Studio (grosszügig), Groq,
  OpenRouter :free, GitHub Models (PAT), Mistral, Cerebras —
  Liste in `Get-SysPilotAiFreeTierSuggestions`.
  **Ersteinrichtung**: `Show-SysPilotAiOnboarding` (Onboarded-Flag in
  Config; SysPilot.ps1 zeigt prominenten Menü-Eintrag bis gesetzt).
  Install-Hilfe: Ollama=winget `Ollama.Ollama`, OmniRoute=
  `npm i -g omniroute` (:20128), freelm=`pip install freelm`,
  FreeLLMAPI=Docker (:3001). `Show-SysPilotAiQuickKeySetup` =
  Key direkt einfügen + Sofort-Test. `Save-SysPilotAiKeyBackup`
  exportiert Provider+Keys nach `Dokumente\api keys\` (plaintext!).
  **GUI-Overlay (0.9.5.0)**: `SysPilot-GUI.ps1` hat schwebenden
  KI-Button `BtnKiFloat` + `KiChatPanel` (Canvas `KiOverlay`,
  oberste Grid-Ebene). `Add-SysPilotKiDrag` = generischer
  Drag&Drop-Helper (KiChatHeader bewegt Panel). Chat via
  eigenem Runspace (`$script:kiPs`/`kiAsync`/`kiPoll`-Muster wie
  `updPs`), History max 24. `$kiWatch`-Timer (12s):
  `Test-SysPilotGamingActive` => `KiOverlay.Visibility=Collapsed`;
  alle ~60s Log-Tail auf neue Fehler -> Chat-Nachricht oder
  `!`-Badge auf BtnKiFloat. `-History` ist `[object[]]` (nicht
  `[string[]]` - Hashtables sonst zu Strings konvertiert!).
  **Aktionen (0.9.5.0)**: `Get-SysPilotKiActions` (AiAssist.psm1)
  = Registry mit `Id/Label/Risk(low|medium|high)/NeedsAdmin/Desc/
  Run-Scriptblock`. `Get-SysPilotKiActionProtocol` wird automatisch
  an jeden System-Prompt angehaengt; Marker-Syntax
  `<<<AKTION:id>>>` (max 2). GUI parst Marker in kiPoll-Completion,
  `Show-SysPilotKiActionButtons` rendert Buttons,
  `Start-SysPilotKiAction` = Bestaetigung (medium/high, MessageBox
  „NO RISK NO FUN") + async Runspace mit ALLEN Modulen
  ($kiMode='action' im selben kiPoll). `Invoke-SysPilotKiAction`
  faengt Streams via `*>&1|Out-String` und importiert bei
  CommandNotFound automatisch alle Module nach. **Regel**: Run-
  Scriptblocks duerfen KEIN Confirm/Read-Host enthalten (haengt
  im Runspace) - nur nicht-interaktive Funktionen nutzen.
  **Pilot Herbert (0.9.5.0)**: Branding „PILOT HERBERT - FLUG 667"
  (GUI-Header Z.236 + Konsolen-Chat in AiAssist). Prozess-Watcher
  im `$kiWatch`-Tick (SysPilot-GUI.ps1 ~Z.696): neue interaktive
  Programme (MainWindowTitle + gleiche Session, `$script:herbertExclude`
  Ausschlussliste) -> Balloon-Tip/Tooltip oder Chat-Nachricht,
  90s-Dedupe (`herbertLastAlert`), `herbertRecent` (6) geht in den
  System-Prompt. Stumm schaltbar: `ChkKiHints`-Checkbox ->
  `Get/Set-SysPilotAiProcessHintsEnabled` (AiAssist.psm1,
  persistiert in ai-assist.json). Default = AN.
  **Bord-Ansagen**: `Get-SysPilotHerbertAnnouncements` (AiAssist.psm1)
  = 37 Durchsagen in 9 Kategorien (welcome/wetter/sicherheit/nacht/
  song/flieger/hotshots/turbulenz/landung, ASCII-sicher).
  flieger = Fliegerlied F.P.1 (1932), hotshots = Hot-Shots!
  Zitate 1991 (nur IMDb-verifizierte, uebersetzt); Rest eigenes
  Material (Krupps-Vibes, keine geschuetzten Lyrics).
  `Get-SysPilotHerbertAnnouncement -Category <string[]>` = Zufalls-
  pick. GUI `Show-SysPilotHerbertAnnouncement`: Panel offen ->
  Add-SysPilotKiMsg 'sys' („ANSAGE: ..."), sonst Balloon-Tip
  (max 1/4 Min via `herbertLastBalloon`) + BtnKiFloat-Tooltip.
  Trigger: welcome beim ersten Show-SysPilotKiPanel, periodisch
  ~alle 5 Min (kiWatchTick%25==24, 25% Chance, nur
  wetter/sicherheit/nacht/song), turbulenz bei Log-Fehlern,
  landung nach Aktion/MCP-Erfolg (je 50%). Alles respektiert
  ChkKiHints.
  **MCP (0.9.5.0, `McpClient.psm1`, Key `mcp`)**:
  `Get-SysPilotMcpServers` importiert Server aus windsurf
  `mcp_config.json` + cline `cline_mcp_settings.json` (Secrets bleiben
  in Quelldateien), SysPilot-Config `%LOCALAPPDATA%\SysPilot\mcp.json`
  (Disabled-Liste). Defaults: desktop-commander/powershell/github/
  browseros-neo. `Invoke-SysPilotMcpRpc` = Dispatcher stdio
  (`Invoke-SysPilotMcpStdioRpc`, Server pro Aufruf) vs. alles andere
  = streamableHttp (`Invoke-SysPilotMcpHttpRpc`, initialize->session-
  id->Request, JSON+SSE). **PS5.1-Falle**: `ProcessStartInfo.
  ArgumentList` existiert in .NET Framework NICHT -> `Arguments`-
  String mit eigenem Quoting verwenden. `Get-SysPilotMcpTools` =
  tools/list mit 10-Min-Cache (Datei `%TEMP%\syspilot-mcp-tools.json`,
  geteilt zwischen Runspaces). `Get-SysPilotMcpChatToolDefs` liefert
  max 24 OpenAI-Tool-Defs (`mcp_<server>_<tool>`-Namen),
  `Find-SysPilotMcpToolDef` mappt zurueck, `Invoke-SysPilotMcpTool`
  = tools/call. `Write-SysPilotMcpLog` = Guard wenn Common fehlt.
  **MCP im Chat**: `Invoke-SysPilotAiChat -McpToolDefs` sendet
  `tools`+`tool_choice=auto` (Fallback: Retry ohne tools bei Fehler),
  Antwort `tool_calls` -> `Show-SysPilotKiMcpButtons` -> Klick =
  MessageBox-Bestaetigung (NO RISK NO FUN) -> `Start-SysPilotKiMcpTool`
  async (`$kiMode='mcp'`) -> Ergebnis + Auto-Followup-Chat an Herbert.
  **Task-Manager (0.9.5.0, `ProcessManager.psm1`, Key `procs`)**:
  `Get-SysPilotProcesses` (Top/Filter/Sort ram|cpu|name, Objekte mit
  RamMB!), `Show-SysPilotProcessTable`, `Stop-SysPilotProcessTree`
  (Kindprozesse via Win32_Process), `Start-SysPilotProcessPick`,
  `Show-SysPilotProcessDetails` (Signatur/Parent/Kinder/Netzwerk),
  `Get-SysPilotProcessExplorer` (procexp64.exe von live.sysinternals.com
  -> PortableApps\ProcessExplorer, `Save-SysPilotUrlToFile`),
  `Invoke-SysPilotProcessExplorerForPid /e <pid>`,
  `Show-SysPilotProcessMenu` (Show-SysPilotArrowMenu).
  GUI: `BtnProcs` in $buttons-Array + `Show-SysPilotToolFromGui`-
  Wrapper. Toolbox-Eintrag unter „System optimieren".
- **Offene Punkte / Ausblick**: TeraBox u.ä. ohne PM-Pendant bleiben
  manuell (App-eigene Updater nicht automatisierbar); OpenVPN MSI
  1603 trotz `--force` ungelöst (TAP-Treiber/Running-Service —
  ggf. Services stoppen als Smart-Fix nachrüsten); scoop
  „bucket(s) out of date" wird automatisch repariert, weitere
  Manager-Warnungen (npm audit, pip deprecated) noch nicht
  automatisiert; Hash-Pinning für choco/scoop-Installationen fehlt;
  FOSSHub-Slugs nicht immer ableitbar (nur Best-Effort),
  FileHippo-412 = Bot-Schutz (manuell).

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
- Alle `.ps1`/`.psm1` **ASCII-sicher** schreiben (ae/oe/ue/ss statt Umlaute, keine Grad-Symbole) – sonst Mojibake ohne BOM. **Wichtig (0.9.5.0-Fix)**: UTF-8-Dateien **ohne BOM** werden von Windows PowerShell 5.1 als ANSI gelesen → Umlaute/€/° werden zu Mojibake und koennen die Datei komplett unparsebar machen (`Import-Module`-Fehler beim SysPilot-Start). Vor dem Commit: alle Module auf `[^\x00-\x7F]` pruefen.

### KI-Werkzeuge (Cline & Co.)
- **Grosse Dateien nie als ein String schreiben**: Cline hat `SysPilot.ps1` mit `[... truncated, this is a large file ...]` überschrieben → Skript unbrauchbar. Nach jeder KI-Änderung Dateigröße/Inhalt prüfen; bei Verdacht `git diff`/`git show HEAD:<file>` zum Restore nutzen.
- **PowerShell.MCP**: Proxy-Pfad in `C:\Users\haber\.cline\data\settings\cline_mcp_settings.json` muss zur installierten Modulversion passen (`C:\Users\haber\OneDrive\Documents\PowerShell\Modules\PowerShell.MCP\<Version>\bin\win-x64\PowerShell.MCP.Proxy.exe`). Stand 0.9.4.6: 1.17.1.
- **Group-Object auf Hashtables**: `Get-SysPilotToolbox` liefert
  `[pscustomobject]`e — `Group-Object Category` sieht Hashtable-Keys
  in PS 5.1 NICHT als Eigenschaften (alle landeten in einer
  namenlosen Gruppe → Toolbox zeigte keine Kategorien). Nie
  `Group-Object` auf Hashtable-Arrays anwenden; Module geben
  pscustomobject zurück.
- **Inline-PowerShell vermeiden**: komplexe Skripte als `.ps1`-Datei schreiben und per `powershell -NoProfile -ExecutionPolicy Bypass -File <skript>.ps1` ausführen.

## Herbert-, Status- & Verzahnungs-Integration (verbindlich, alle Module)

Jedes Modul / Werkzeug in SysPilot muss die folgenden sechs Punkte
erfüllen — nicht nur bei neuen Modulen, sondern als Maßstab bei jeder
Erweiterung bestehender Module:

### 1. Herbert-Chat pro Modul (Kontext-Assistenz)
- Jedes interaktive Fenster / Menü bietet einen **„Herbert fragen"**-
  Zugang mit modul-spezifischem Kontext (z.B. `Add-SysPilotAssistantToWindow
  -Context 'Show-SysPilot<X>Window'` bei WPF, `-Context`-Parameter beim
  Konsolen-Assistenten). Herbert kennt damit, in welchem Modul der User
  gerade ist.
- Der Kontext enthält: Modulname, aktuelle Auswahl/Ergebnisse (z.B.
  „Registry-Cleaner: 8 Funde in 3 Kategorien"), erlaubte Aktionen —
  nie generische Phrasen.

### 2. Ausführliche Statuskonsole (Pflicht für alle Langläufer)
- Jede Operation, die >2 s dauern kann, zeigt **live**: was gerade
  gemacht wird (Schritt/Phase), Fortschritt in % **und** Balken wo
  sinnvoll, bereits Overhead (`i/n`, ETA falls verfügbar), Status-
  meldungen UND Fehler in Klartext — nicht nur „läuft...".
- Pflicht-Helpers: `Invoke-SysPilotMonitoredProcess` (Externe),
  `-ProgressQueue`-Objekte für eigene Worker (`Pct/Recv/Total/MBR/MBT/
  Label/Note`), `Read-SysPilotFileTailLine` für Log-Tails. Kein stiller
  `Out-Null` bei sichtbaren Prozessen.
- Fehler landen IMMER im Log/Status — nie still schlucken.

### 3. Verzahnung zwischen Modulen (Querverweise)
- Jedes Modul listet seine **verwandten Module** und bietet Übergänge
  an (z.B. Registry-Cleaner → PrivacyFix, Privacy-Erase → Cleanup,
  Disk-Optimize → StorageCleanup, Boot-Analyse → Startup-Manager).
- Implementierung: `Get-SysPilotModuleLinks -Module <key>` (Common) →
  generische „Verwandte Tools"-Sektion in Menüs + `<<<VORSCHLAG>>>`-
  Chips im Herbert-Chat. Neue Module tragen `Related=@('key1','key2')`
  im Modul-Header/Export.

### 4. Herbert-Vorschläge, Anmerkungen, „Senf"
- Herbert darf und soll proaktiv **Vorschläge** aussprechen
  (`<<<VORSCHLAG:...>>>` → klickbarer Chip), **Anmerkungen** machen
  (`<<<DENK:...>>>` → gedimmte Nachricht) und bei Unsicherheit
  **fragen** (`<<<FRAGE:frage|opt1|opt2>>>` → Antwort-Buttons).
- Inhalt muss modulspezifisch sein: was der Scan fand → was Herbert
  empfiehlt → welche Aktion er anbieten kann (`<<<AKTION:id>>>` →
  Übernehmen-Button). Generische Smalltalk-Antworten sind ein Defekt.

### 5. ADHS-HOWTO für User-Aktionen
- Alles, was der **User** selbst tun muss (Browser-Login, UAC,
  Neustart, manuelle Klicks), läuft über `Show-SysPilotStepGuide`
  (Common.psm1): EIN Schritt gleichzeitig, Enter=weiter, u=URL,
  v=YouTube-Suche, z=Abbruch. Nie Anleitungs-Wände oder nummerierte
  Listen ohne Interaktion. Pflicht bei jedem Setup/Onboarding-Flow.

### 6. Anklickbare Herbert-Aktionen (modulspezifisch)
- Jeder Modul-Chat registriert seine Aktionen über
  `Get-SysPilotKiActions`/Action-Protokoll: sinnvolle Next-Steps als
  `<<<AKTION:id>>>`-Marker → UI rendert Übernehmen-Buttons.
- Aktionen müssen **im Kontext des Moduls** passen (z.B. im
  Registry-Cleaner: „Backup erstellen", „Nur MRU/Verlauf löschen",
  „Privacy-Erase öffnen"; im Disk-Optimize: „Analyse nur",
  „Startup-Manager prüfen"). Risk-Einstufung low/medium/high wie
  bestehend; interaktiver Code NIE in Run-Scriptblocks.
- Permission-Modi (ask/auto/bypass) aus `Get-SysPilotHerbertPermissionMode`
  bleiben aktiv — bypass darf keine Bestätigungs-Buttons umgehen,
  die der User explizit angefordert hat.

**Checkliste pro Modul-Änderung:** Kontext-Assistenz verdrahtet?
Statuskonsole live? Modul-Links hinterlegt? Herbert-Vorschläge
modulspezifisch? User-Schritte via StepGuide? Aktionen anklickbar?
Wenn nein → Lücke schließen, bevor als fertig gilt.

## Netzwerk-Robustheit & TV/Mobil-Sideload (0.9.5.0, verbindlich)

### Instabile Netze (Hotspot/Mobilfunk)
- **`Test-SysPilotInternet`** (Common.psm1): Online-Check OHNE HTTP —
  DNS + TCP 443 zu 1.1.1.1, 2s Timeout, 20s Cache (`$script:_netOkCache`).
- **`Wait-SysPilotInternet`**: wartet bis max 90s (Poll 5s) auf
  Wiederkehr — für Hotspot-Aussetzer. Gibt $true/$false zurück.
- **`Invoke-SysPilotHttpRequest`**: HTTP-Wrapper mit 3 Versuchen +
  exponentiellem Backoff (2s/4s/8s); `-OnRetry`-Scriptblock für
  eigene Logzeilen. Für kleine API-Calls (GitHub etc.) — NICHT für
  große Downloads (dafür SmartFileDownload-Kette).
- **Verdrahtet**: `Invoke-SysPilotSmartFileDownload` wartet VOR dem
  Download (`Wait-SysPilotInternet -MaxSec 90`), `Get-SysPilotGithubLatest`
  nutzt den Retry-Wrapper, `Invoke-SysPilotAiChat` wartet 45s wenn
  Cloud-Provider in der Kette und offline. Downloads sind ohnehin
  resume-fähig (aria2 `--continue` + Segmente mit 6 Resume-Retries).

### TV/Mobil-Sideload (`AiAssist.psm1`)
- **`Get-SysPilotTvApps`**: kuratierter Katalog — KodiRoll, VYPN,
  SquiffNet, StreamFlix, OTT, Downloader, FlixVision (mit
  VirusTotal-Warnung), TechDoctorUK/DocSquiffy, **SmartTube**
  (direkter APK `releases/download/latest/smarttube_stable.apk`),
  **Amazon_SYTV_Bridge.apk** (Fire TV) + **ATV_SYTV_Bridge.apk**
  (Android TV) — beide aus demselben `latest`-Tag, URLs dauerhaft
  gültig, **TroyPoint** als page-Quelle.
- **SmartTube-Reihenfolge ist KRITISCH** (in Guide + Herbert-Wissen
  dokumentiert): 1) Original-YouTube-App deinstallieren
  (Paket-Konflikt), 2) SmartTube installieren, 3) Bridge installieren.
  Bridge ist unsichtbar, routet nur YouTube-Intents/Alexa/Voice.
- **`Get-SysPilotTvLaunchers`**: Vergleich mit Preis/Optik — Monet
  (~10 EUR, Netflix-Look), Projectivy (~3 EUR), Wolf (kostenlos),
  App Starter Pro, ATV Launcher, FLauncher (FOSS). **Fire OS erlaubt
  KEIN Drittanbieter-Home** — Monet & Co. nur auf Android TV/Google TV.
- **`Show-SysPilotMobileSideload`**: Smartphone/Tablet-Guide —
  Android via ADB identisch zum TV; iOS ehrlich: nur AltStore PAL
  (App Store, kostenlos) → SideStore, Signaturen 7 Tage, kein direktes
  APK möglich. App-Quellen-Katalog mit QR-Code pro Quelle.
- **ADB-Funktionen sind geräteagnostisch**: `Connect-SysPilotTvAdb`
  (IP:5555, Android-TV-11+-Pairing), `Install-SysPilotTvApk`,
  `Invoke-SysPilotTvDebloat` funktionieren für TV UND Android-Phone/
  Tablet unverändert.
- **Quellen-Katalog**: F-Droid (`f-droid.org/F-Droid.apk`, nur FOSS),
  Obtainium (GitHub-APK + Auto-Updates), Aurora Store (Play Store
  ohne Google-Account), APKMirror (signatur-geprüft), APKPure,
  Aptoide, TroyPoint (`troypoint.com` auch als Portal in
  `PortablePortalDefs`, Auto=$false).

### Herbert-Wissen (`Get-SysPilotHerbertKnowledge`)
- Kuratierte Wissens-Blöcke (TV/Mobil-Sideload, SmartTube-Reihenfolge,
  Launcher-Vergleich, Miniflux/RSS, KI-Provider, ADHS-Erklärstil),
  werden in den Chat-System-Prompt gehängt — Herbert erklärt
  Setup-Schritte proaktiv ADHS-gerecht (nummerierte Schritte, ein
  Schritt = eine Aktion, keine erfundenen Preise/Links).
- KiActions: `tv-setup` (Label/Desc um Smartphone/Tablet + Quellen +
  iOS-Hinweis erweitert), `mobile-sideload` (eigener Guide-Aufruf).
- Onboarding-„Was Herbert kann" um TV/Mobil-Sideload ergänzt.

### Weitere 0.9.5.0-Änderungen
- **WPF-Auswahl-Kontrast (verbindlich)**: markierte Items = milchig
  `#CCE4EAF2` + dunkle Schrift `#FF1E1E2E`. `ListViewItem`/
  `ListBoxItem`-Styles in ALLEN Fenstern; Zellen NIEMALS hardcodierte
  helle Foregrounds (vererben lassen); farbige Icons bei Bedarf
  vertiefen. `WpfMenu`/`WpfMultiSelect` in Common.psm1: Auswahl
  dunkle Schrift `#FF101018` auf Accent.
- **SoftwareCenter-Setup-Feld**: Katalog-Einträge haben `Setup` +
  `SetupLabel` (z.B. `omniroute`/`freellmapi`/`freelm`/`9router` →
  eigene Assistenten `Show-SysPilotOmniRouteSetup` etc.,
  `routersync` = Gesamtmenü-Fallback). Detail-Ansicht mappt Key →
  Assistent; unbekannte Keys = saubere Fehlermeldung.
- **Bordansagen separat**: `Get/Set-SysPilotHerbertAnnouncementsEnabled`
  (Default = ProcessHints-Status), GUI `ChkKiAnn`, Konsole
  `kiannouncements`, KI-Menü `ansagen`. Branding `PILOT HERBERT -
  FLUG 667` bleibt.
- **GUI Top-Ressourcenfresser**: sortierbar (RAM/CPU%/Name-Chips),
  RAM-% + echte CPU-% (Delta ÷ Kerne), rotierende Tipps, Fenster
  780px + Button-Leiste in ScrollViewer (Auto-Zeile fraß vorher
  den Platz), Item-Limit 15.

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

## Extensions-Manager: geloeste Probleme (Stand 0.9.5.0, verbindlich)

- **Chromium-Extension entfernen**: NIEMALS `ConvertTo-Json`-Rewrite auf
  `Secure Preferences`/`Preferences` - Edge-Dateien enthalten doppelte
  JSON-Schluessel (macroEnabled.12/macroenabled.12) und der Rewrite
  zerstoert zusaetzlich die protection.macs. Immer
  `Remove-SysPilotJsonPropertyText` (Common.psm1) fuer ROHE
  Text-Entfernung von `"<id>":<wert>` inkl. protection.macs-Reste,
  in BEIDEN Pref-Dateien. Backup `.syspilot-bak-<ts>` zuerst.
- **Laufender Browser ueberschreibt Removal**: Secure Preferences
  liegen im Browser-Speicher und werden beim Beenden
  zurueckgeschrieben. Vor dem Entfernen Browser-Prozesse schliessen
  (CloseMainWindow + Warten), sonst ist die Aenderung wirkungslos.
- **Store-IDs sind browser-spezifisch**: dieselbe Extension hat in
  Chrome/Edge/Firefox UNTERSCHIEDLICHE IDs (MetaMask: nkbihfbeo... vs
  ejbalbako...). Duplikat-Erkennung IMMER per normalisiertem Namen
  (`$normName` in Extensions.psm1) zusaetzlich zur ID.
- **Account-Sync-Schutz**: `Add-SysPilotExtensionInstallBlock`
  schreibt die ID in `HKCU\SOFTWARE\Policies\<Vendor>\<Browser>\
  ExtensionInstallBlocklist` (Werte 1..n) - verhindert Neuinstallation
  via Sync/Store. HKCU = kein Admin noetig. Firefox braucht eigene
  policies.json (nicht implementiert).
- **Benutzer-Blocklist**: `%LOCALAPPDATA%\SysPilot\ext-user-blocklist.txt`
  (IDs oder Namensfragmente) -> Get-SysPilotExtRisk flagged +80 KRITISCH.
- **WPF-Async-Muster** (verbindlich): Jobs in Runspace + EIN
  DispatcherTimer im FENSTER-Funktionsscope ($poll + $asyncJobs
  ArrayList). NIEMALS Timer/State in einer untergeordneten
  Scriptblock-Funktion ($runAsync) anlegen - dessen Scope stirbt beim
  Return, der Tick sieht $state nicht mehr -> stiller Haenger.
  GetNewClosure nur wenn noetig; $script:-Variablen in Closures
  divergieren (DrvStudio-Bug) -> Shared-State in Hashtable.
- **Add-SysPilotAssistantToWindow**: SetValue fuer DockProperty braucht
  ENUM ([Windows.Controls.Dock]::Bottom), keine Strings - sonst
  wirft die Funktion still $null (Panel erscheint nie!). Handler
  duerfen keine Funktions-Lokalen nutzen (Function returned) ->
  Kontext ueber $Win.Tag['_assistant'] (enthält Context, Suggestions,
  HerbertOpened). -AutoHerbert oeffnet Assistenten rechts automatisch.
- **Window-Lifetime**: WPF-Fenster IMMER mit ShowDialog() oeffnen;
  Show() ohne laufende Owner-Pump-Schleife = Fenster stirbt beim
  Prozess-Ende. Show-SysPilotHerbertAssistant oeffnet modal wenn kein
  sichtbarer Owner.

### Umbenennungen & Anzeigenamen (verbindlich)
- Code-Identifiers (Funktionsnamen, Tool-Keys, Dateinamen) duerfen bei
  Umbenennungen bestehen bleiben - sie sind unsichtbar.
- ANZEIGENAMEN muessen synchron umbenannt werden ueberall dort, wo sie
  nutzersichtig werden: Konsolen-Menue-Labels, WPF `Title=`/`Content=`/
  `ToolTip=`/`Desc=`, Toolbox-Eintraege, Fenster-Titel und die
  System-Prompts von KI-Assistenten (Herbert) - sonst "erzaehlt" der
  Assistent dem Nutzer alte Namen.
- `check-syntax.ps1` prueft automatisch auf veraltete Anzeigenamen in
  UI-Strings (`$retiredNames`-Liste dort pflegen). NAMEN-Befund =
  Check schlaegt fehl wie ein Syntaxfehler.

## Konsolen-UI-Fehlersuche & bekannte Baustellen (Stand 0.9.5.0, verbindlich)

### Windows-Terminal/ConPTY-Fallen (verbindlich)
- **Cursor-Positionierung zum Ueberschreiben ist UNZUVERLAESSIG**: Unter
  Windows Terminal/ConPTY kann der RawUI-Setter "erfolgreich" laufen, ohne
  die Position anzuwenden; selbst kernel32 `SetConsoleCursorPosition` wird
  von der PowerShell ConsoleHost beim naechsten Write-Host ueberschrieben
  (ConsoleHost cached den Cursor intern). Write-Host landet dann am alten
  Ort -> Inline-Redraws haengen Zeilen an (Duplikat-Spam, Klicks ins
  Leere). **Loesung: NIEMALS Cursor-Setzen + Write-Host fuer Redraws** -
  stattdessen `Clear-Host` + komplettes Neuzeichnen (Muster:
  Show-SysPilotArrowMenu/MultiSelect/Read-SysPilotYesNo); `$optRow` wird
  nach jedem Draw frisch gelesen.
- **`WriteConsoleOutput` (CHAR_INFO/Attribute) liefert unter ConPTY
  ERROR_INVALID_PARAMETER (87)** - nicht nutzbar. `WriteConsoleOutput-
  Character` (reiner Text) funktioniert, kann aber keine Attribute setzen.
- **`GetConsoleCursorPosition` (kernel32) liefert unter ConPTY FALSCH**
  (z.B. 0,0) - zur Verifikation nur `GetConsoleScreenBufferInfo`
  (`dwCursorPosition`) benutzen; der ist korrekt (externer Beweis:
  ReadConsoleOutputCharacter auf fremde Konsolen per AttachConsole+CONOUT$).
  Achtung: CSBI kann die GESETZTE Position melden, ohne dass Write-Host
  ihr folgt - als Verify ebenfalls nicht narrensicher.
- **`WriteConsoleInput`-Injection erreicht ConPTY-Apps oft NICHT**:
  synthetische Records werden von Windows Terminal nicht an die App
  durchgereicht. Fuer Live-Tests echte Maus/Tastatur benutzen
  (SetCursorPos erzeugt echte MOUSE_MOVEs), nicht auf Injection vertrauen.
- **Maus-Event-Koordinaten = Buffer-Koordinaten**: `$ev.Row/-Col` in
  Read-SysPilotMenuEvent sind absolute Screen-Buffer-Zellen, identisch zu
  CursorPosition.Y/X - nie Viewport-relative Werte annehmen.
- **Sichtbare Fenster finden**: `EnumWindows`+`GetWindowText` zeigt
  minimierte Fenster als RECT=-25600,-25600; `ShowWindow(hwnd,9)` +
  `SetForegroundWindow` stellt sie wieder her. UIA (`wins3.ps1`-Stil)
  liefert BoundingRectangle nur fuer sichtbare Fenster.

### Konsole live auslesen (Debug-Werkzeuge, Muster in %TEMP%)
- **Buffertext einer fremden Konsole**: `AttachConsole(pid)` +
  `CreateFile('CONOUT$')` + `ReadConsoleOutputCharacter` - liest exakte
  Buffer-Zeilen (Cursor-Position inklusive). Funktioniert auch wenn das
  Fenster minimiert ist.
- **Fensterinhalt visuell**: `PrintWindow(hwnd, hdc, 2)` -> PNG ->
  Windows.Media.Ocr (WinRT, -STA noetig) -> Text. Unabhaengig vom
  Buffer-Zustand, zeigt was der User wirklich sieht.
- **Prozess-Startzeiten pruefen, bevor man Bugs einer Codeversion
  zuordnet**: Module werden beim Prozessstart geladen - ein Langlaeufer
  kann monatelang ALTEN Code im Speicher haben (Fix wirkt erst nach
  Neustart des Tool-Prozesses, nicht nach Deploy).
- **Lange Scans/Inventare brauchen Statuszeilen**: `Get-SysPilotBrowserExtensionInventory`
  dauert ~15-20 s; ohne `[..] wird gescannt ...`-Zeile wirkt der
  Rescan-Loop wie ein Haenger (User-Beschwerde 0.9.5.0). Regel: jeder
  Block >3 s ohne UI-Feedback braucht eine Statusausgabe.
- **`Get-SysPilotBackupDir` (Common.psm1)** prueft Schreibbarkeit und
  faellt bei nicht-elevated Tool-Prozessen auf
  `%LOCALAPPDATA%\SysPilot\backup` zurueck - niemals hardcodiert nach
  `SysPilotRoot\backup` schreiben (Program Files = UnauthorizedAccessException).

### Aehnliche-Fehler-regel (verbindlich)
- Bei jedem Bug in einem Console-/UI-Mechanismus: **repo-weit nach demselben
  Muster suchen** (`git grep` nach CursorPosition, ReadConsoleInput,
  WaitForSingleObject, Write-Host-Redraws, GetNewClosure) und alle
  betroffenen Stellen ANPASSUNGSGERECHT mitfixen - nicht nur die eine
  gemeldete Stelle. Beispiel 0.9.5.0: `$((if`-Klammer-Bug und
  Array-im-Array-Return waren Einzelpunkte; CursorPosition-Falle war
  nur an einer Stelle, wurde aber als Systemic-Risk dokumentiert.
- **Module-Import-Warnung** "nicht genehmigte Verben" ist KOSMETISCH
  (PowerShell-Verbliste) - kein Handlungsbedarf, nicht mit Bugs verwechseln.
- **Deploy nach `C:\Program Files\SysPilot`** braucht Admin:
  `_sync_installed.ps1` oder einzelne `Copy-Item`; bei Devin-Sessions
  ohne Admin Rechte ueber `Start-Process -Verb RunAs` eskalieren
  (UAC-Prompt) - oder Devin selbst elevated starten.
