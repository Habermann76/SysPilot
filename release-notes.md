# SysPilot 0.9.4 beta

- **Guardian**: erkennt eine laufende SysPilot-GUI jetzt zuverlaessig ueber ihre Sperre (Mutex), auch wenn sie mit hoeheren Rechten laeuft als die pruefende Stelle.

---

# SysPilot 0.9.3 beta (Vorgaenger)

- **Updates**: Neuer Button "Updates" im SysPilot-Fenster (zeigt die installierte Version, z. B. v0.9.3). SysPilot sucht ausserdem beim Start im Hintergrund auf GitHub nach einer neueren Version und meldet sie per Tray-Hinweis. Ein Klick laedt den Installer und aktualisiert; eigene Einstellungen bleiben erhalten. Abschaltbar: Tray-Menue "Beim Start nach Updates suchen".
- **Guardian (neu mit Installer-Haekchen, standardmaessig an)**: SysPilot startet mit Windows unsichtbar im Infobereich ("Ausgeblendete Symbole") und wird alle 30 Sekunden geprueft; laeuft es nicht, startet der Guardian es neu. Bewusstes "Beenden" im Tray-Menue wird respektiert (bis zur naechsten Anmeldung). Keine Fenster, die alle 2 Minuten aufblitzen.
- **Nach der Installation/dem Update startet SysPilot jetzt automatisch** (Installer-Haekchen "SysPilot jetzt starten" bzw. unsichtbar im Tray bei stillem Update).
- **Einstellungen bleiben beim Update erhalten** (Start, Guardian, Autopilot, Sprache/Einheit, Update).

---

# SysPilot 0.9.2 beta (Vorgaenger)

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
