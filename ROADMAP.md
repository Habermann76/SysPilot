# SysPilot — Roadmap

## Version 0.9.5.0 (NEU)

- ✅ **Download-Portale & Web-Kataloge**: 17 Portale (DE+EN) als
  `[Portal]`-Apps + Update-Center-Liste; Ninite vollautomatisierbar
  (160 Apps, stiller Installer); `Get-SysPilotWebSourceVersions` mit
  automatisierten Versionen (Ninite/MajorGeeks/Uptodown/FOSSHub) +
  13 manuellen Portalen, letzte Update-Ketten-Stufe
- ✅ **KI-Suche & KI-Version**: `Start-SysPilotAiSearch` Engine-Menü
  (Perplexity/Duck.ai/Gemini/Copilot), `Get-SysPilotAiPortalHint`
  headless pollinations.ai (kostenlos, kein Key) — „KI-Angabe"-Label
- ✅ **KI-Apps-Kategorie**: 57 Tools im Katalog (lokale LLMs,
  Desktop-Clients, Agenten/CLI, Exoten: PocketAI Hub, Layla,
  FreeLLMAPI, OmniRoute, freelm, MCP); `DetectPaths`/`DetectCmds`-
  Erkennung + `NpmPkg`/`PipPkg`-Install-Aktionen
- ✅ `version.txt` = 0.9.5.0

## Version 0.9.4.9

- ✅ **CleanSweep / UninstallManager.psm1**: Deinstallations-Center nach
  REA-Funktionsanalyse von IObit Uninstaller (Delphi/VCL — unabhängig
  nachgebaut, kein Code/UI kopiert)
- ✅ **Programme**: 4 Registry-Sichten (HKLM64/32, HKCU64/32),
  UninstallString/QuietUninstallString, MSI `/x /qn`, Silent-Heuristik
  (Inno/NSIS/InstallShield), Batch mit Nummern+Filter, Reboot-Erkennung
  (3010/1641), optionaler Wiederherstellungspunkt
- ✅ **Windows-Apps**: AppX/MSIX-Inventar (NonRemovable/IsFramework/
  IsResourcePackage gefiltert), Remove-AppxPackage, provisionierte
  Pakete für neue Nutzer
- ✅ **Browser-Erweiterungen**: Chromium (Secure/Preferences-JSON +
  Extensions-Ordner + Local/Sync Settings, Backup vor Edit) und
  Firefox (extensions.json + XPI-Dateien) — echter Entfernen-Flow
- ✅ **Reste-Scanner**: Dateien, Registry (Software/Run/AppPaths/
  MUICache), Dienste, geplante Aufgaben, Autostarts, Shortcuts —
  Sicherheits-Score 0-100, Papierkorb für Dateien, .reg-Export-Backup
- ✅ **Verwaiste Programme**: Ordner ohne Uninstall-Eintrag in
  Program Files/LocalAppData\Programs/ProgramData (normalisierter
  Namensabgleich, Windows-Inbox ausgeblendet)
- ✅ **Defekte Einträge**: Uninstall-Keys mit fehlendem Exe oder ohne
  UninstallString — Registry-Entfernung mit Backup oder Force-Uninstall
- ✅ **Force-Uninstall**: manueller Pfad → Ziel + alle passenden Reste
- ✅ **Windows-Updates**: KB-Liste (Win32_QuickFixEngineering),
  wusa /uninstall /kb: mit Bestätigung
- ✅ **Update / Download Center** (`SoftwareUpdateCenter.psm1`,
  Key `updates`): winget+Chocolatey-Scan, 147-App-Katalog in 7
  Kategorien, GitHub-Releases, MajorGeeks-Resolver, Web-Kataloge
  (site:-Suche via Ecosia/Brave/Google), Auto-Update + Fehlerspeicher
  mit Retry-Modi, Paketmanager-Integration (`PackageManagers.psm1`:
  14 Manager, WSL-PMs, Unified-Search, Manager-Install inkl.
  WSL-Distros), GUI & Erweiterungen (UniGetUI portabel, Chocolatey
  GUI, OuiGui, AppStore-Ext), WSL-Verwaltung (Distro-Picker,
  WSL Manager, .wslconfig-GUI-Apps), Cross-Manager-Fallbacks +
  Alt-Manager-Installation, Auto-Fix-Framework für Warnungen
- ✅ Integration: Vollmenü (`uninstall`, `updates`), `-Tool uninstall`/`updates`,
  Toolbox-Einträge „CleanSweep" + „Update / Download Center";
  `version.txt` = 0.9.4.9

## Version 0.9.4.8 (NEU)

- ✅ **Maussteuerung im Textmenü**: Console-API (P/Invoke) — Klick, Mausrad,
  Hover in allen Arrow-/Multiselect-Menüs + Ja/Nein-Dialoge + „Weiter"-Pausen;
  Event-Queue gegen verlorene Tastendrücke; QuickEdit-Falle behoben
- ✅ **PortableTools.psm1**: 10 Apps (UniGetUI, Komi Store, Uptodown Desktop,
  WinUtil, WinToys, iTop, Ferdium, Flipboard, UWT5, PC Manager) mit
  Download-Fortschritt, SHA256-Check, App-Typen zip/script/winget/web/
  installer/majorgeeks/storeapp, Vollpaket-Checkbox-Auswahl
- ✅ **Runtimes.psm1**: Laufzeiten-Manager winget-first (VC++/.NET/.NET FX)
- ✅ **PrivacyFix.psm1**: PrivacyGuard — 32 reversible Tweaks
- ✅ **RootCertificates.psm1**: portable Zertifikats-Verwaltung
- ✅ **Win11-Kontextmenü-Reparatur** (`win11ctxrestore`)
- ✅ **Restart-SysPilot.ps1** + Desktop-Verknüpfung „SysPilot Neustart"
- ✅ **Treiber**: SDI-Download/Versionserkennung, WU + Update-Catalog-Quellen
- ✅ Build: Inno-Setup-Installer + portables ZIP aus version.txt

## Version 0.9.4.7 (NEU)

- ✅ **WizTree-Integration**: Neues Modul `WizTree.psm1` – Festplattenplatz-Analyse via WizTree, stille Installation von `diskanalyzer.com`
- ✅ **SysPilot PC-Analyse**: Neues Modul `HardwareCheck.psm1` – Hardware-Check für CPU, RAM, GPU, Mainboard/BIOS, Laufwerke mit S.M.A.R.T., Netzwerk, Temperatur
- ✅ **Treiber-Werkstatt**: Neues Modul `Drivers.psm1` – Problemgeräte finden, Treiber-Inventar, Rollback, fehlende Komponenten-Check
- ✅ **Vollmenue-Integration**: Alle drei neuen Module in Vollmenue, `-Tool`-Switch und Toolbox (Keys: `wiztree`, `hardware`, `drivers`)
- ✅ **Build‑Verbesserungen**: `build.ps1` erstellt Installer und Portable ZIP automatisch aus `version.txt`
- ✅ **Version‑Quelle**: `version.txt` ist die einzige Versionsquelle

---

## Version 0.9.4.6 beta (aktuell)

- ✅ PowerShell-Kern (Text-Menü mit Pfeiltasten)
- ✅ WPF-GUI (schlank, ~80 MB RAM, Tray, dunkel)
- ✅ Autopilot (App-Erkennung: Gaming/Entwicklung/Browser, Hitze-Notbremse)
- ✅ Prozess-Prioritäten (wichtige Apps bevorzugen, Ballast drosseln)
- ✅ RAM freigeben (manuell + automatisch)
- ✅ Bloatware-Finder (Crapfixer-artig, recherchierte Liste, Reste-Entfernung)
- ✅ Autostart-Manager, Dienste-Tuning, Windows-Features, Cleanup
- ✅ Browser-Extension-Analyzer (Duplikate finden)
- ✅ Werbe-Schalter (Microsoft-Eigenwerbung + personalisierte Werbung)
- ✅ Sprachen (Deutsch/English), Einheiten (°C/°F)
- ✅ Statistiken, Ressourcen-Fresser, Skripte (anpassbar)
- ✅ Hitzeschutz (Notaus bei 95 °C, Ruhezustand)
- ✅ Installer (x64 EXE) + portable ZIP
- ✅ Automatic Checkup (15 Bereiche, ehrlich erklärt, Fixes abwählbar) — Konsole + GUI
- ✅ Toolbox (27 Werkzeuge in 4 Kategorien, mit Erklärungen) — Konsole + GUI
- ✅ Netzwerk-Reparatur (NETREPAIR, 14 Reparaturen) + Adapter-Identifikation
- ✅ Vollautomatik (Auto-Optimierung) in Menü, Toolbox und GUI
- ✅ Smart Boost (RAM automatisch freigeben), Autopilot-Autostart per Installer-Häkchen
- ✅ GUI: Single-Instance, versteckte Konsole, "Als Admin starten"-Button, DPI-scharf
- ✅ "Beenden" = weiter im Hintergrund (Tray), abschaltbar in den Einstellungen
- ✅ Option "Immer als Administrator starten" (Config + Verknüpfungs-Flag)

## Geplant (nach Beta)

### Version 1.0

- ⬜ **Electron-Version** (komplett grafisch, mehr RAM ~150-200 MB, aber
  hübscher + plattformübergreifend) — *vorgemerkt auf Nutzerwunsch*
- ⬜ **Windows-Dienst** (SysPilot dauerhaft im Hintergrund, auch ohne Anmeldung) —
  *vorgemerkt auf Nutzerwunsch, verschoben: Aufwand aktuell zu hoch*
- ⬜ Installer für **ARM64** und **x86 (32-bit)**
- ⬜ **MSI-Installer** (für Unternehmen/Gruppenrichtlinien)
- ⬜ **Auto-Update** (SysPilot aktualisiert sich selbst)
- ⬜ **Mehr Sprachen** (Französisch, Spanisch, …)
- ⬜ **GPU-Temperatur** + Lüftersteuerung (mit LibreHardwareMonitor)
- ⬜ **Profile** (Gaming, Arbeit, Nacht als speicherbare Presets)
- ⬜ **Zeitpläne** (z. B. nachts automatisch Nacht-Modus)
- ⬜ **Netzwerk-Monitor** (welche App saugt Bandbreite?)
- ⬜ **Signierte Installer** (Code-Signing-Zertifikat)

### Ideen (noch nicht geplant)

- Browser-Extension-**Verwaltung** direkt aus SysPilot (deaktivieren ohne Browser zu öffnen)
- **Benchmark** (vorher/nachher Vergleich)
- **Cloud-Backup** der Konfiguration
- **Multi-PC** (mehrere Rechner zentral verwalten)

## Mitmachen

Fehler gefunden? Idee? → [Issues](https://github.com/Habermann76/SysPilot/issues)