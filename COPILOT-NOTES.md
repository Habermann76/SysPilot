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
