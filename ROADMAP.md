# SysPilot — Roadmap

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