# Pilot Herbert — Browser-Extension fuer SysPilot

Erkennt auf **GitHub** Repositories, die fuer SysPilot interessant sind
(lokale LLMs, KI-Assistenten, GGUF-Tools, MCP-Server, unzensierte Modelle
wie `abliterated`/`heretic`/`uncensored`), und zeigt einen Herbert-Badge an.

Klick auf den Badge oeffnet `syspilot://repo/<Owner>/<Name>` — registriert
SysPilot das Protokoll (geschieht automatisch beim ersten Aufruf des
gefuehrten Installations-Assistenten), startet sich der **Installations-
Assistent**: Repo-Info, gefundene Install-Skripte, Bestaetigung, Klon,
Skript-Ausfuehrung, Port-Check.

## Installation (einmalig, ~1 Minute)

1. Chrome/Edge/Brave oeffnen → `chrome://extensions` (Edge: `edge://extensions`)
2. **Entwicklermodus** aktivieren (Schalter oben rechts)
3. **„Entpackte Erweiterung laden"** → diesen Ordner
   (`C:\Users\haber\SysPilot\extensions\pilot-herbert`) auswaehlen
4. Fertig — auf GitHub-Repo-Seiten erscheint der Badge automatisch,
   wenn >=2 KI-Signale erkannt werden.

## Voraussetzungen

- SysPilot installiert (Protokoll `syspilot://` wird automatisch
  registriert, sobald einmal der Installations-Assistent lief —
  alternativ: SysPilot → KI-Assistenz → „Herbert-gestuetzte Installation").
- Ohne Protokoll: Der Badge kopiert trotzdem den Repo-Link in die
  Zwischenablage als Fallback.

## Was der Assistent dann tut

1. Repo-Metadaten von der GitHub-API (Beschreibung, Stars, Branch)
2. Sucht Install-Skripte (`install/bootstrap.ps1`, `INSTALL.bat`, `install.sh` …)
3. Klont nach `%LOCALAPPDATA%\Programs\<Name>` und fuehrt das Skript aus
4. Port-Check (8000, 3000, 8080, 11434) → Provider-Registrierung moeglich

Beispiel: [PapaKoftes/Layla](https://github.com/PapaKoftes/Layla) —
lokaler persoenlicher AI-Assistent mit Web-UI auf `localhost:8000/ui`.
