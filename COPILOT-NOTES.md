# Hinweis an Copilot (Stand 2026-11-03)

Betrifft Commit `74cc166` ("GUI-Start ohne leeres PowerShell-Fenster") und die Korrektur dazu.

## Was schiefging
`Restart-SysPilotElevated` (modules/Common.psm1) wird von der GUI **und** vom Text-Menue (`SysPilot.ps1`)
benutzt. In 74cc166 bekam der Neustart pauschal `-WindowStyle Hidden`. Das Text-Menue ist aber eine
reine Konsolen-App: versteckt war sie unsichtbar (wartet auf Eingabe), die App wirkte "nicht gestartet".
Ausserdem zeigt `$PSCommandPath` innerhalb eines Moduls auf die `.psm1`, nicht auf das aufrufende Skript.

## Was geaendert wurde
- `Restart-SysPilotElevated`: ermittelt das aufrufende `.ps1` ueber `Get-PSCallStack`.
  `-WindowStyle Hidden` nur noch, wenn das Ziel `SysPilot-GUI.ps1` ist (die GUI versteckt ihre
  Konsole zusaetzlich selbst per `GetConsoleWindow`/`ShowWindow`). Das Text-Menue startet sichtbar.
- Unveraendert und korrekt: Menuepunkt 20 und `Close-SysPilotToTray` (starten nur die GUI hidden),
  Verknuepfungen/Installer in `installer.iss`.

## Regeln fuer kuenftige Aenderungen
1. `-WindowStyle Hidden` nur fuer `SysPilot-GUI.ps1`, nie fuer `SysPilot.ps1` (Konsole).
2. Nach jeder Aenderung am Start-Pfad testen: Verknuepfung, Menue 20, "Als Admin neu starten"
   (GUI und Text-Menue), `AlwaysAdmin = true`.
3. Ein kurzes Konsolen-Aufblitzen beim Start der GUI laesst sich mit PowerShell allein nicht ganz
   vermeiden. Sauber geht es nur mit einem kleinen Launcher (z.B. VBScript `wscript` mit
   `Run cmd, 0` oder eine .exe ohne Konsole) als Ziel der Verknuepfung.

---

# Nachtrag 2026-11-03 (Toolbox, Checkup-Fehler, Tray-Start)

## 1) Toolbox-Werkzeuge starteten nicht (v.a. installiert unter "C:\Program Files\SysPilot")
`Start-Process powershell.exe -ArgumentList @('-File', $pfad, ...)` setzt Pfade mit Leerzeichen **nicht**
in Anfuehrungszeichen -> PowerShell bekommt `-File C:\Program` und beendet sich sofort.
Neu: `ConvertTo-SysPilotArgString` (modules/Common.psm1). **Alle** Start-Process-Aufrufe mit Skriptpfaden
muessen `-ArgumentList (ConvertTo-SysPilotArgString @(...))` nutzen (GUI-Toolbox, Checkup-Werkzeug,
Vollautomatik, Vollmenue, LHM-Installer, Guardian, Menuepunkt 20, Tray-Start).

## 2) Checkup "Tote Registry-Verweise": "Argument kann nicht an Parameter Path gebunden werden"
Jedes Modul hat einen **eigenen** `$script:`-Bereich. `$script:SysPilotRoot` wird nur in Common.psm1
gesetzt, war in Checkup.psm1 und Guardian.psm1 daher `$null` (betraf auch Checkup-Zeitplan und Guardian).
Neu: beide Module setzen `$script:SysPilotRoot` selbst. Regel: nie `$script:`-Variablen anderer Module nutzen.
Ausserdem im Registry-Fix: (a) das "Backup" war nur eine leere .reg-Datei -> jetzt echter `reg export`
der betroffenen Schluessel nach backup\registry-orphans-<Zeit>\; (b) Schluessel vom Typ "Key" hatten den
PSPath-Praefix und wurden gar nicht geloescht, aber als "entfernt" gezaehlt -> Praefix wird entfernt,
Erfolg wird ueber `$LASTEXITCODE` gezaehlt.

## 3) Neu: GUI beim Start nur im Tray
Config `Start.StartInTray` (true/false, Standard false). Umschalten: Text-Menue -> Einstellungen oder
Rechtsklick aufs Tray-Symbol -> "Beim Start nur im Tray (ohne Fenster)". Ist die GUI schon im Tray und
wird die Verknuepfung nochmal gestartet, zeigt sie ihr Fenster (benanntes Event `Local\SysPilotGUI-Show`);
`-StartHidden` (Autostart/Guardian) loest das bewusst nicht aus.
Hinweis: Ob das Symbol sichtbar oder unter "^" (ausgeblendete Symbole) liegt, entscheidet Windows
(Einstellungen -> Personalisierung -> Taskleiste -> Andere Symbole der Taskleiste).
