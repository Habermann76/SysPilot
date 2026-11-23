# SysPilot 0.9.4.8 — Installationsanleitung

## Schnellstart (empfohlen)

1. **Installer herunterladen**: `SysPilot-Setup-0.9.4.8-x64.exe` von den
   [Releases](https://github.com/Habermann76/SysPilot/releases)
2. **Doppelklick** → installiert nach `C:\Program Files\SysPilot`
3. **Startmenü** → "SysPilot" öffnen

Fertig. SysPilot fragt beim ersten Start, ob es als Administrator laufen soll
(empfohlen für Energiepläne, Dienste, Deinstallationen).

## Portable Version (keine Installation)

1. `SysPilot-0.9.4.8-beta-portable.zip` herunterladen
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

### Neue Features in 0.9.4.8

- **Maussteuerung im Textmenü**: Menüs, Ja/Nein-Dialoge und „Weiter"-Pausen per Klick/Mausrad bedienbar
- **Portable Apps & Store-Clients**: UniGetUI, Komi Store, Uptodown Desktop, WinUtil, WinToys, iTop, Ferdium, Flipboard, Ultimate Windows Tweaker 5, Microsoft PC Manager + Vollpaket-Auswahl
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