# SysPilot — Fehler melden & Vorschläge

Du hast einen Fehler gefunden oder eine Idee? Super — hier ist wie:

## Fehler melden (Bug Report)

1. Gehe zu [Issues](https://github.com/Habermann76/SysPilot/issues)
2. Klicke **„New Issue"** → **„Bug Report"**
3. Fülle aus:
   - **Was hast du getan?** (z. B. „Menü 8 Auto-Optimierung gestartet")
   - **Was ist passiert?** (Fehlermeldung, falsches Verhalten)
   - **Was hast du erwartet?**
   - **SysPilot-Version** (steht im Titel, z. B. 0.9 beta)
   - **Windows-Version** (z. B. Windows 11 23H2)
   - **Log-Datei** anhängen: `SysPilot\logs\syspilot-YYYY-MM-DD.log`

## Vorschlag machen (Feature Request)

1. [Issues](https://github.com/Habermann76/SysPilot/issues) → **„New Issue"** → **„Feature Request"**
2. Beschreibe:
   - **Was soll SysPilot können?**
   - **Warum wäre das nützlich?**

## Debug-Modus (für Entwickler)

SysPilot loggt alle Aktionen nach `logs\syspilot-YYYY-MM-DD.log`.
Für mehr Details:

```powershell
# Verbose-Modus
$VerbosePreference = 'Continue'
.\SysPilot.ps1
```

## Häufige Fragen

**„Buttons funktionieren nicht"**
→ SysPilot braucht Admin-Rechte. Menü **16** oder GUI als Admin starten.

**„Temperatur wird geschätzt"**
→ Normal ohne Sensor-Tool. GUI → „Temp-Sensor" → LibreHardwareMonitor
installieren (vollautomatisch).

**„Plan wechselt nicht"**
→ Energiepläne fehlen. Menü **2** ausführen (als Admin).

**„Deinstallation hängt"**
→ Manche Deinstallations-Programme warten auf Benutzer-Eingabe.
Fenster suchen und bestätigen.
