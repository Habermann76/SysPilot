# SysPilot 0.9.5.0 — Installationsanleitung

## Schnellstart (empfohlen)

1. **Installer herunterladen**: `SysPilot-Setup-0.9.5.0-x64.exe` von den
   [Releases](https://github.com/Habermann76/SysPilot/releases)
2. **Doppelklick** → installiert nach `C:\Program Files\SysPilot`
3. **Startmenü** → "SysPilot" öffnen

Fertig. SysPilot fragt beim ersten Start, ob es als Administrator laufen soll
(empfohlen für Energiepläne, Dienste, Deinstallationen).

## Portable Version (keine Installation)

1. `SysPilot-0.9.5.0-beta-portable.zip` herunterladen
2. Entpacken (z. B. nach `C:\SysPilot`)
3. `SysPilot.ps1` → Rechtsklick → "Mit PowerShell ausführen"

## Voraussetzungen

- **Windows 10 oder 11** (64-bit)
- **PowerShell 5.1** (in Windows eingebaut) — kein Download nötig
- **Administrator-Rechte** für volle Funktion (Energiepläne, Dienste,
  Deinstallationen, Standby-RAM). Ohne Admin laufen Analyse, Autostart,
  Prioritäten und Skripte trotzdem.

## Optional: Echte CPU-Temperatur

SysPilot schätzt die Temperatur aus Last + Takt. Für **echte** Sensor-Werte
(auch für den Hitzeschutz):

- Im GUI auf "Temp-Sensor" klicken → SysPilot installiert
  [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor)
  vollautomatisch (kostenlos, Open Source, portable, keine Telemetrie)

## Deinstallation

- **Installer-Version**: Windows → Einstellungen → Apps → SysPilot → Deinstallieren
- **Portable**: Ordner löschen

SysPilot hinterlässt keine Reste (außer `backup\` und `logs\` im
Installationsordner — kann manuell gelöscht werden).

## Probleme?

→ [DEBUG.md](DEBUG.md) — Fehler melden, Vorschläge machen

---

### Neue Features in 0.9.5.0

- **KI-Apps-Kategorie**: 57 kuratierte KI-Tools im Programm-Katalog (lokale LLMs, Desktop-Clients, Agenten/CLI, Exoten wie PocketAI Hub, Layla, FreeLLMAPI, OmniRoute, freelm, MCP) — mit Erkennung auch für portabel/npm-Tools und npm-/pip-Install-Aktionen
- **Download-Portale & Web-Kataloge**: 17 Download-Portale (DE+EN) in „Apps & Store-Clients" + Update-Center; Ninite vollautomatisierbar (still im Hintergrund); automatisierte Versions-Abfrage (Ninite/MajorGeeks/Uptodown/FOSSHub) mit „NEUESTE"-Markierung als letzte Update-Ketten-Stufe
- **KI-Suche & KI-Version**: KI-Suche öffnet Auswahl freier Web-KIs (Perplexity/Duck.ai/Gemini/Copilot); headless pollinations.ai-Abfrage für Version + Download-URL (als „KI-Angabe" gelabelt)

### Neue Features in 0.9.4.9

- **CleanSweep (Deinstallations-Center)**: eigenständige Implementierung — Programme (4 Registry-Sichten, Silent/Normal, Batch), Windows-Apps (AppX + provisioniert), Browser-Erweiterungen entfernen (Chromium/Firefox mit Backups), Resteverwaltung mit Sicherheits-Score (Papierkorb + Registry-Backup), verwaiste Programme, defekte Einträge, Windows-Updates, Wiederherstellungspunkt
- **Update / Download Center**: winget+Chocolatey-Scan, 147-App-Katalog, GitHub-Releases, MajorGeeks-Resolver, Web-Kataloge (Suchmaschinen-Suche via site:-Operatoren), Auto-Update mit Fehlerspeicher + Retry, **Paketmanager-Integration** (14 Manager, WSL-PMs, Suche in ALLEN Managern), **GUI & Erweiterungen** (UniGetUI, Chocolatey GUI, OuiGui, AppStore-Ext), **WSL-Verwaltung** (Distro-Picker, WSL Manager, GUI-Apps), Auto-Fix für Manager-Warnungen (Scoop-Buckets, Self-Updates), Cross-Manager-Fallbacks (winget→choco/scoop)

### Neue Features in 0.9.4.8

- **Maussteuerung im Textmenü**: Menüs, Ja/Nein-Dialoge und „Weiter"-Pausen per Klick/Mausrad bedienbar
- **Apps & Store-Clients**: UniGetUI, Komi Store, Uptodown Desktop, WinUtil, WinToys, iTop, Ferdium, Flipboard, UWT 5, PC Manager, HostsMan, MuMu Player + Vollpaket-Auswahl
- **Laufzeiten-Manager**: VC++/.NET/.NET Framework — winget-first mit Fallbacks
- **PrivacyGuard**: 32 reversible Datenschutz-/Werbe-Tweaks
- **Root-Zertifikate**: portable UpdateRootCertificates-Verwaltung
- **Win11-Kontextmenü reparieren**: moderne Win11-Oberfläche nach Tweaker-Schäden wiederherstellen
- **SysPilot-Neustart**: Desktop-Verknüpfung beendet alle SysPilot-Prozesse und startet neu

### Neue Features in 0.9.4.7

- **WizTree-Integration**: Analyse des Festplattenplatzes via WizTree, optionale stille Installation
- **SysPilot PC-Analyse**: Umfassender Hardware-Check für CPU, RAM, GPU, Mainboard/BIOS, Laufwerke mit S.M.A.R.T., Netzwerkadapter und Temperatur
- **Treiber-Werkstatt**: Problemgeräte finden, Treiber-Inventar, Rollback für ältere Treiber, fehlende System/Spiel-Komponenten prüfen
- **Modul-Erweiterung**: Drei neue Module (`WizTree.psm1`, `HardwareCheck.psm1`, `Drivers.psm1`) stehen im Modulordner bereit