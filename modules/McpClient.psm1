# =====================================================================
# McpClient.psm1 - MCP-Client fuer SysPilot
# Spricht MCP (Model Context Protocol) mit stdio- und
# streamableHttp-Servern. Server-Definitionen werden aus den
# vorhandenen MCP-Configs importiert
# (%USERPROFILE%\.codeium\windsurf\mcp_config.json,
#  %USERPROFILE%\.cline\data\settings\cline_mcp_settings.json)
# - Secrets (Tokens) bleiben in den Quelldateien und werden
# zur Laufzeit durchgereicht, nicht kopiert.
# Standard-Server: desktop-commander, powershell, github, browseros-neo.
# =====================================================================

$script:McpConfigPath = Join-Path $env:LOCALAPPDATA 'SysPilot\mcp.json'
$script:McpToolsCache = @{}
$script:McpToolsCacheTime = [datetime]::MinValue
$script:McpDefaultServers = @('desktop-commander','powershell','github','browseros-neo')

function script:Write-SysPilotMcpLog([string]$Msg) {
    if (Get-Command Write-SysPilotLog -ErrorAction SilentlyContinue) { Write-SysPilotLog $Msg }
}

function Read-SysPilotMcpConfig {
    if (Test-Path $script:McpConfigPath) {
        try { return (Get-Content $script:McpConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {}
    }
    return [pscustomobject]@{ Disabled = @() }
}

function Write-SysPilotMcpConfig {
    param($Config)
    $dir = Split-Path $script:McpConfigPath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $Config | ConvertTo-Json -Depth 10 | Set-Content $script:McpConfigPath -Encoding UTF8
}

function ConvertFrom-SysPilotMcpTransport {
    <# Normalisiert die zwei bekannten Config-Formate:
       windsurf:  { command, args, env } | { serverUrl, headers }
       cline:     { transport: { type: stdio|streamableHttp, command, args, url, headers } } #>
    param($Raw)
    $t = $Raw
    if ($Raw.transport) { $t = $Raw.transport }
    $type = $t.type
    if (-not $type) { $type = if ($t.url -or $t.serverUrl) { 'http' } else { 'stdio' } }
    $cmd = $t.command
    $args = @($t.args)
    $env = @{}
    if ($t.env) { foreach ($k in $t.env.PSObject.Properties) { $env[$k.Name] = [string]$k.Value } }
    $url = $t.url; if (-not $url) { $url = $t.serverUrl }
    $headers = @{}
    if ($t.headers) { foreach ($k in $t.headers.PSObject.Properties) { $headers[$k.Name] = [string]$k.Value } }
    return [pscustomobject]@{
        Type = $type; Command = $cmd; Args = $args; Env = $env
        Url = $url; Headers = $headers
    }
}

function Get-SysPilotMcpServers {
    <# Liefert die entdeckten MCP-Server (aus windsurf + cline Configs)
       als normalisierte Objekte. 'Enabled' = in den 4 Standard-Servern
       und nicht in mcp.json deaktiviert. #>
    $found = [ordered]@{}
    $sources = @(
        (Join-Path $env:USERPROFILE '.codeium\windsurf\mcp_config.json'),
        (Join-Path $env:USERPROFILE '.cline\data\settings\cline_mcp_settings.json')
    )
    foreach ($src in $sources) {
        if (-not (Test-Path $src)) { continue }
        try {
            $cfg = Get-Content $src -Raw -Encoding UTF8 | ConvertFrom-Json
            $servers = $cfg.mcpServers
            if (-not $servers) { $servers = $cfg }
            foreach ($prop in $servers.PSObject.Properties) {
                $name = $prop.Name
                if ($found.Contains($name)) { continue }   # windsurf hat Vorrang
                $raw = $prop.Value
                if ($raw.disabled -eq $true) { continue }
                $tr = ConvertFrom-SysPilotMcpTransport $raw
                if (-not $tr.Command -and -not $tr.Url) { continue }
                $found[$name] = [pscustomobject]@{
                    Name = $name; Type = $tr.Type
                    Command = $tr.Command; Args = $tr.Args; Env = $tr.Env
                    Url = $tr.Url; Headers = $tr.Headers; Source = (Split-Path $src -Leaf)
                }
            }
        } catch { Write-SysPilotMcpLog "MCP-Config $src nicht lesbar: $($_.Exception.Message)" }
    }
    # SysPilot-eigene Server (ueber den Install-Katalog installiert,
    # in %LOCALAPPDATA%\SysPilot\mcp.json unter "Servers")
    try {
        $mc0 = Read-SysPilotMcpConfig
        if ($mc0.Servers) {
            foreach ($prop in $mc0.Servers.PSObject.Properties) {
                $name = $prop.Name
                if ($found.Contains($name)) { continue }
                $tr = ConvertFrom-SysPilotMcpTransport $prop.Value
                if (-not $tr.Command -and -not $tr.Url) { continue }
                $found[$name] = [pscustomobject]@{
                    Name = $name; Type = $tr.Type
                    Command = $tr.Command; Args = $tr.Args; Env = $tr.Env
                    Url = $tr.Url; Headers = $tr.Headers; Source = 'syspilot'
                }
            }
        }
    } catch {}
    # Fuer stdio-Commands, die noetigerweise eine Shell brauchen (npx.cmd etc.)
    foreach ($s in $found.Values) {
        if ($s.Type -eq 'stdio' -and $s.Command) {
            $c = $s.Command
            $needsShell = ($c -match '\.(cmd|bat)$') -or ($c -in @('npx','npm','pnpx','yarn'))
            if ($needsShell) {
                $resolved = $c
                if ($c -in @('npx','npm','pnpx','yarn')) {
                    $cmdPath = Get-Command "$c.cmd" -ErrorAction SilentlyContinue
                    if ($cmdPath) { $resolved = $cmdPath.Source } else { $resolved = $c }
                }
                $s.Command = 'cmd.exe'
                $s.Args = @('/d','/c', $resolved) + @($s.Args)
            }
        }
    }
    # Enabled-Status
    $mc = Read-SysPilotMcpConfig
    $disabled = @($mc.Disabled)
    foreach ($s in $found.Values) {
        $isDefault = ($script:McpDefaultServers -contains $s.Name)
        $s | Add-Member -NotePropertyName IsDefault -NotePropertyValue $isDefault -Force
        # Standard-Server + SysPilot-installierte sind aktiv, solange
        # nicht deaktiviert; Fremd-Server (windsurf/cline) nur als STD.
        $s | Add-Member -NotePropertyName Enabled -NotePropertyValue (($isDefault -or $s.Source -eq 'syspilot') -and $disabled -notcontains $s.Name) -Force
    }
    return @($found.Values)
}

function ConvertTo-SysPilotMcpStdioSpawn {
    <# ProcessStartInfo fuer stdio-Server. #>
    param($Server)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Server.Command
    # ArgumentList gibt es in .NET Framework (PS 5.1) nicht -> Arguments-String
    $psi.Arguments = (@($Server.Args) | ForEach-Object {
        $a = [string]$_
        if ($a -match '\s' -or $a -match '"') {
            '"' + ($a -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
        } else { $a }
    }) -join ' '
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    if ($Server.Env) { foreach ($k in $Server.Env.Keys) { try { $psi.EnvironmentVariables[$k] = $Server.Env[$k] } catch {} } }
    return $psi
}

function Invoke-SysPilotMcpStdioRpc {
    <# Ein MCP-Handshake + Request ueber stdio (newline-delimited JSON-RPC).
       Spawned den Server pro Aufruf (zustandslos, robust). #>
    param(
        [Parameter(Mandatory)]$Server,
        [Parameter(Mandatory)][string]$Method,
        $Params = @{},
        [int]$TimeoutSec = 45
    )
    $psi = ConvertTo-SysPilotMcpStdioSpawn $Server
    $p = $null
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
    } catch {
        return @{ Ok=$false; Error="Server-Start fehlgeschlagen: $($_.Exception.Message)" }
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $errBuf = New-Object System.Text.StringBuilder
    # stderr async lesen (verhindert Pipe-Blockade)
    $errTask = $p.StandardError.ReadToEndAsync()
    try {
        $init = @{ jsonrpc='2.0'; id=1; method='initialize'; params=@{
            protocolVersion='2025-06-18'; capabilities=@{}
            clientInfo=@{ name='SysPilot'; version='0.9.5' } } } | ConvertTo-Json -Depth 15 -Compress
        $p.StandardInput.WriteLine($init)
        $p.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}')
        $req = @{ jsonrpc='2.0'; id=2; method=$Method; params=$Params } | ConvertTo-Json -Depth 20 -Compress
        $p.StandardInput.WriteLine($req)
        $p.StandardInput.Flush()
        # Antworten lesen bis id=2 (oder Timeout/Prozess-Ende)
        while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
            if ($p.HasExited) { break }
            $readTask = $p.StandardOutput.ReadLineAsync()
            $remaining = [int](($TimeoutSec - $sw.Elapsed.TotalSeconds) * 1000)
            if ($remaining -le 0) { break }
            if (-not $readTask.Wait($remaining)) { break }
            $line = $readTask.Result
            if (-not $line) { continue }
            try { $msg = $line | ConvertFrom-Json } catch { continue }
            if ($msg.id -ne 2) { continue }   # initialize-Antwort/Notifications ueberspringen
            if ($msg.error) { return @{ Ok=$false; Error="MCP-Fehler: $($msg.error.message)" } }
            return @{ Ok=$true; Result=$msg.result }
        }
        $errTxt = ''
        try { if ($errTask.Wait(1500)) { $errTxt = [string]$errTask.Result } } catch {}
        if (-not $errTxt) { $errTxt = '' }
        return @{ Ok=$false; Error="Timeout (${TimeoutSec}s) oder kein Response. stderr: $($errTxt.Substring(0,[Math]::Min(300,$errTxt.Length)))" }
    } catch {
        return @{ Ok=$false; Error="MCP-Aufruf fehlgeschlagen: $($_.Exception.Message)" }
    } finally {
        try { if ($p -and -not $p.HasExited) { $p.Kill() } } catch {}
        try { if ($p) { $p.Dispose() } } catch {}
    }
}

function ConvertFrom-SysPilotMcpHttpBody {
    <# Parst MCP-HTTP-Response: application/json oder text/event-stream. #>
    param($Response)
    $ct = ''
    try { $ct = [string]$Response.Headers['Content-Type'] } catch {}
    $body = [string]$Response.Content
    if ($ct -match 'text/event-stream' -or $body -match '(?m)^data:') {
        $msgs = @()
        foreach ($ln in ($body -split "`n")) {
            $ln = $ln.Trim()
            if ($ln.StartsWith('data:')) {
                $payload = $ln.Substring(5).Trim()
                if ($payload -and $payload -ne '[DONE]') {
                    try { $msgs += ($payload | ConvertFrom-Json) } catch {}
                }
            }
        }
        return $msgs
    }
    try { return @($body | ConvertFrom-Json) } catch { return @() }
}

function Invoke-SysPilotMcpHttpRpc {
    <# MCP-Request ueber streamableHttp. Macht initialize (Session-ID),
       notifications/initialized, dann den eigentlichen Request. #>
    param(
        [Parameter(Mandatory)]$Server,
        [Parameter(Mandatory)][string]$Method,
        $Params = @{},
        [int]$TimeoutSec = 45
    )
    $headers = @{
        'Accept' = 'application/json, text/event-stream'
        'Content-Type' = 'application/json'
    }
    foreach ($k in $Server.Headers.Keys) { $headers[$k] = $Server.Headers[$k] }
    $sessionId = $null
    try {
        # 1) initialize
        $initBody = @{ jsonrpc='2.0'; id=1; method='initialize'; params=@{
            protocolVersion='2025-06-18'; capabilities=@{}
            clientInfo=@{ name='SysPilot'; version='0.9.5' } } } | ConvertTo-Json -Depth 15 -Compress
        $r1 = Invoke-WebRequest -Uri $Server.Url -Method Post -Headers $headers -Body $initBody -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop
        $sid = $null
        try { $sid = $r1.Headers['Mcp-Session-Id']; if (-not $sid) { $sid = $r1.Headers['mcp-session-id'] } } catch {}
        if ($sid) { $sessionId = [string]$sid; $headers['Mcp-Session-Id'] = $sessionId }
        # 2) initialized-Notification
        try {
            $noteBody = '{"jsonrpc":"2.0","method":"notifications/initialized"}'
            Invoke-WebRequest -Uri $Server.Url -Method Post -Headers $headers -Body $noteBody -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction SilentlyContinue | Out-Null
        } catch {}
        # 3) eigentlicher Request
        $reqBody = @{ jsonrpc='2.0'; id=2; method=$Method; params=$Params } | ConvertTo-Json -Depth 20 -Compress
        $r2 = Invoke-WebRequest -Uri $Server.Url -Method Post -Headers $headers -Body $reqBody -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop
        $msgs = @(ConvertFrom-SysPilotMcpHttpBody $r2)
        foreach ($m in $msgs) {
            if ($m.id -eq 2) {
                if ($m.error) { return @{ Ok=$false; Error="MCP-Fehler: $($m.error.message)" } }
                return @{ Ok=$true; Result=$m.result }
            }
        }
        return @{ Ok=$false; Error='HTTP-Response ohne passendes Resultat' }
    } catch {
        return @{ Ok=$false; Error="HTTP-MCP fehlgeschlagen: $($_.Exception.Message)" }
    }
}

function Invoke-SysPilotMcpRpc {
    <# Dispatcher: stdio oder http. #>
    param(
        [Parameter(Mandatory)]$Server,
        [Parameter(Mandatory)][string]$Method,
        $Params = @{},
        [int]$TimeoutSec = 45
    )
    if ($Server.Type -eq 'stdio') { return Invoke-SysPilotMcpStdioRpc -Server $Server -Method $Method -Params $Params -TimeoutSec $TimeoutSec }
    return Invoke-SysPilotMcpHttpRpc -Server $Server -Method $Method -Params $Params -TimeoutSec $TimeoutSec
}

function Get-SysPilotMcpTools {
    <# tools/list aller enabled Server (10-Min-Cache, Datei-gestuetzt,
       damit auch separate Runspaces den Cache teilen). #>
    param([switch]$Refresh)
    $cacheFile = Join-Path $env:TEMP 'syspilot-mcp-tools.json'
    if (-not $Refresh) {
        if ($script:McpToolsCache.Count -gt 0 -and ((Get-Date) - $script:McpToolsCacheTime).TotalMinutes -lt 10) {
            return $script:McpToolsCache
        }
        if (Test-Path $cacheFile) {
            try {
                $disk = Get-Content $cacheFile -Raw -Encoding UTF8 | ConvertFrom-Json
                $age = ((Get-Date) - [datetime]$disk.Time).TotalMinutes
                if ($age -lt 10 -and $disk.Tools) {
                    $script:McpToolsCache = @($disk.Tools | ForEach-Object {
                        [pscustomobject]@{ Server=$_.Server; Name=$_.Name; Description=[string]$_.Description; Parameters=$_.Parameters }
                    })
                    $script:McpToolsCacheTime = Get-Date
                    return $script:McpToolsCache
                }
            } catch {}
        }
    }
    $tools = @()
    $servers = @(Get-SysPilotMcpServers | Where-Object { $_.Enabled })
    if ($servers.Count -le 1) {
        foreach ($s in $servers) {
            $r = Invoke-SysPilotMcpRpc -Server $s -Method 'tools/list' -Params @{} -TimeoutSec 20
            if ($r.Ok -and $r.Result.tools) {
                foreach ($t in $r.Result.tools) {
                    $tools += [pscustomobject]@{ Server=$s.Name; Name=$t.name; Description=[string]$t.description; Parameters=$t.inputSchema }
                }
            } else {
                Write-SysPilotMcpLog "MCP $($s.Name): tools/list fehlgeschlagen - $($r.Error)"
            }
        }
    } else {
        # Parallel: jeder Server bekommt einen eigenen Runspace -
        # seriell waren es bis zu 25s x Server (messbar ~26s).
        $modPath = $PSCommandPath
        $pool = [runspacefactory]::CreateRunspacePool(1, [Math]::Min(8, $servers.Count))
        try {
            $pool.Open()
            $handles = @()
            foreach ($s in $servers) {
                $ps = [powershell]::Create()
                $ps.RunspacePool = $pool
                [void]$ps.AddScript({
                    param($mod, $srv)
                    Import-Module $mod -Force -ErrorAction SilentlyContinue
                    $r = Invoke-SysPilotMcpRpc -Server $srv -Method 'tools/list' -Params @{} -TimeoutSec 20
                    if ($r.Ok -and $r.Result.tools) {
                        foreach ($t in @($r.Result.tools)) {
                            [pscustomobject]@{ Server=$srv.Name; Name=$t.name; Description=[string]$t.description; Parameters=$t.inputSchema }
                        }
                    }
                }).AddArgument($modPath).AddArgument($s)
                $handles += @{ Ps=$ps; Srv=$s; H=$ps.BeginInvoke() }
            }
            foreach ($h in $handles) {
                try {
                    $tl = @($h.Ps.EndInvoke($h.H))
                    foreach ($t in $tl) { $tools += $t }
                } catch { Write-SysPilotMcpLog "MCP $($h.Srv.Name): paralleler tools/list-Fehler - $($_.Exception.Message)" }
                try { $h.Ps.Dispose() } catch {}
            }
        } finally {
            try { $pool.Close(); $pool.Dispose() } catch {}
        }
    }
    $script:McpToolsCache = $tools
    $script:McpToolsCacheTime = Get-Date
    try {
        @{ Time=(Get-Date).ToString('o'); Tools=$tools } | ConvertTo-Json -Depth 15 -Compress |
            Set-Content $cacheFile -Encoding UTF8
    } catch {}
    return $tools
}

function Get-SysPilotMcpChatToolDefs {
    <# OpenAI-kompatible Tool-Definitionen fuer Invoke-SysPilotAiChat.
       Namen werden zu mcp_<server>_<tool> sanitisiert; die Rueckgabe
       enthaelt die Original-Mapping-Daten. Max. 24 Tools (Prompt-Groesse). #>
    # Lokale SysPilot-Werkzeuge (UIA etc.) haben Vorrang - sie belegen
    # zuerst Slots, externe MCP-Tools fuellen den Rest bis max. 24.
    $localDefs = @()
    if (Get-Command Get-SysPilotLocalMcpToolDefs -ErrorAction SilentlyContinue) {
        try { $localDefs = @(Get-SysPilotLocalMcpToolDefs) } catch { $localDefs = @() }
    }
    $tools = @(Get-SysPilotMcpTools | Select-Object -First ([Math]::Max(0, 24 - $localDefs.Count)))
    $defs = @($localDefs)
    foreach ($t in $tools) {
        $safe = ("mcp_{0}_{1}" -f $t.Server, $t.Name) -replace '[^a-zA-Z0-9_-]','_'
        if ($safe.Length -gt 64) { $safe = $safe.Substring(0,64) }
        $defs += [pscustomobject]@{
            OpenAiName  = $safe
            Server      = $t.Server
            Tool        = $t.Name
            Description = "[$($t.Server)] $($t.Description)"
            Parameters  = $t.Parameters
        }
    }
    return $defs
}

function ConvertTo-SysPilotMcpOpenAiTools {
    param([object[]]$Defs)
    return @($Defs | ForEach-Object {
        $desc = [string]$_.Description
        if ($desc.Length -gt 1024) { $desc = $desc.Substring(0,1024) }
        $schema = $_.Parameters
        if (-not $schema) { $schema = @{ type='object'; properties=@{} } }
        @{
            type = 'function'
            function = @{
                name = $_.OpenAiName
                description = $desc
                parameters = $schema
            }
        }
    })
}

function Find-SysPilotMcpToolDef {
    param([Parameter(Mandatory)][string]$OpenAiName)
    return @(Get-SysPilotMcpChatToolDefs) | Where-Object { $_.OpenAiName -eq $OpenAiName } | Select-Object -First 1
}

function Invoke-SysPilotMcpTool {
    <# Fuehrt ein MCP-Tool aus. -Server/-Tool per Originalnamen,
       -Arguments als Hashtable oder JSON-String. #>
    param(
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][string]$Tool,
        $Arguments = @{},
        [int]$TimeoutSec = 60
    )
    # Lokaler Pseudo-Server 'syspilot-local' (UIA-Werkzeuge aus
    # UiAutomation.psm1) - kein externer MCP-Server noetig.
    if ($Server -eq 'syspilot-local') {
        if (-not (Get-Command Invoke-SysPilotLocalMcpTool -ErrorAction SilentlyContinue)) {
            return @{ Ok=$false; Server=$Server; Tool=$Tool; Text=''; Error='UiAutomation-Modul nicht geladen' }
        }
        $lah = @{}
        if ($Arguments -is [string]) { try { $Arguments | ConvertFrom-Json | ForEach-Object { $_.PSObject.Properties } | ForEach-Object { $lah[$_.Name] = $_.Value } } catch {} }
        elseif ($Arguments) { foreach ($lk in $Arguments.Keys) { $lah[$lk] = $Arguments[$lk] } }
        $lr = Invoke-SysPilotLocalMcpTool -Tool $Tool -Arguments $lah
        return @{ Ok=[bool]$lr.Ok; Server=$Server; Tool=$Tool; Text=[string]$lr.Text; Error=[string]$lr.Error }
    }
    $srv = @(Get-SysPilotMcpServers) | Where-Object { $_.Name -eq $Server } | Select-Object -First 1
    if (-not $srv) { return @{ Ok=$false; Server=$Server; Tool=$Tool; Text=''; Error="Server nicht gefunden: $Server" } }
    $argHash = @{}
    if ($Arguments -is [string]) { try { $Arguments | ConvertFrom-Json | ForEach-Object { $_.PSObject.Properties } | ForEach-Object { $argHash[$_.Name] = $_.Value } } catch {} }
    elseif ($Arguments) { foreach ($k in $Arguments.Keys) { $argHash[$k] = $Arguments[$k] } }
    $r = Invoke-SysPilotMcpRpc -Server $srv -Method 'tools/call' -Params @{ name=$Tool; arguments=$argHash } -TimeoutSec $TimeoutSec
    if (-not $r.Ok) { return @{ Ok=$false; Server=$Server; Tool=$Tool; Text=''; Error=$r.Error } }
    # content[] -> Text extrahieren
    $txt = ''
    if ($r.Result.content) {
        $parts = @()
        foreach ($c in $r.Result.content) {
            if ($c.text) { $parts += [string]$c.text }
            elseif ($c.type -eq 'text') { $parts += [string]$c.text }
        }
        $txt = ($parts -join "`n")
    }
    if (-not $txt -and $r.Result) { $txt = ($r.Result | ConvertTo-Json -Depth 10 -Compress) }
    return @{ Ok=$true; Server=$Server; Tool=$Tool; Text=$txt; Error='' }
}

function Get-SysPilotMcpInstallCatalog {
    <# Katalog bekannter MCP-Server (npm/npx-basiert), die per
       "Installieren" in die SysPilot-Config geschrieben werden.
       Env-Hinweise markiert, was zusaetzlich noetig ist. #>
    return @(
        @{ Name='filesystem'; Package='@modelcontextprotocol/server-filesystem'; Args='C:\\ D:\\'; Desc='Datei-Zugriff auf lokale Laufwerke (Args = erlaubte Pfade)'; NeedsArgs=$true }
        @{ Name='fetch';      Package='@modelcontextprotocol/server-fetch';      Args=''; Desc='HTTP-Downloads/Webseiten fuer die KI'; NeedsArgs=$false }
        @{ Name='memory';     Package='@modelcontextprotocol/server-memory';     Args=''; Desc='Persistenter Wissensspeicher zwischen Chats'; NeedsArgs=$false }
        @{ Name='time';       Package='@modelcontextprotocol/server-time';       Args=''; Desc='Aktuelle Zeit/Daten fuer die KI'; NeedsArgs=$false }
        @{ Name='sequential-thinking'; Package='@modelcontextprotocol/server-sequential-thinking'; Args=''; Desc='Strukturierte Denk-Kette fuer komplexe Aufgaben'; NeedsArgs=$false }
        @{ Name='github';     Package='@modelcontextprotocol/server-github';     Args=''; Desc='GitHub-Issues/PRs/Repos (braucht GITHUB_PERSONAL_ACCESS_TOKEN)'; NeedsArgs=$false; NeedsToken=$true }
        @{ Name='everything'; Package='@modelcontextprotocol/server-everything'; Args=''; Desc='Demo/Referenz-Server (alle Features)'; NeedsArgs=$false }
        @{ Name='sqlite';     Package='@modelcontextprotocol/server-sqlite';     Args=''; Desc='SQLite-Datenbank-Abfragen (Args = Pfad zur .db)'; NeedsArgs=$true }
        # --- Erweiterung: kostenlose Server ohne API-Key ---
        @{ Name='git';        Package='@modelcontextprotocol/server-git';        Args=''; Desc='Git-Operationen: Status, Diff, Log, Branch (lokales Repo als Args)'; NeedsArgs=$true }
        @{ Name='puppeteer';  Package='@modelcontextprotocol/server-puppeteer';  Args=''; Desc='Browser-Automation: Seiten oeffnen, klicken, scrapen (Headless Chrome)'; NeedsArgs=$false }
        @{ Name='playwright'; Package='@playwright/mcp';                        Args=''; Desc='Microsoft Playwright MCP: Browser-Steuerung, Screenshots, Accessibility-Snapshots'; NeedsArgs=$false }
        @{ Name='context7';   Package='@upstash/context7-mcp';                   Args=''; Desc='Aktuelle Library-Doku (React, Next.js u.v.m.) fuer die KI - kostenlos ohne Key'; NeedsArgs=$false }
        @{ Name='desktop-commander'; Package='@wonderwhy-er/desktop-commander';  Args=''; Desc='Dateien + Terminal + Suche auf diesem PC fuer die KI (wie hier genutzt)'; NeedsArgs=$false }
        @{ Name='brave-search'; Package='@modelcontextprotocol/server-brave-search'; Args=''; Desc='Web-Suche fuer die KI (braucht BRAVE_API_KEY - kostenlos auf brave.com/search/api)'; NeedsArgs=$false; NeedsToken=$true }
        # --- Windows + Browser-Steuerung ---
        @{ Name='windows-mcp'; Runtime='uvx'; Package='windows-mcp'; Args=''; Desc='Windows-MCP (CursorTouch): steuert Windows direkt - Fenster, Klicks, Tippen, PowerShell via UIA. Benotigt uv (winget install astral-sh.uv)'; NeedsArgs=$false }
        @{ Name='playwright-extension'; Package='@playwright/mcp'; Args='--extension'; Desc='Playwright MCP als Browser-Extension: verbindet sich mit laufenden Tabs + Login-Sessions (Playwright Extension noetig)'; NeedsArgs=$false }
        @{ Name='chrome-devtools-mcp'; Package='chrome-devtools-mcp'; Args=''; Desc='Google Chrome DevTools MCP: Browser-Steuerung, Performance-Traces, Netzwerk-Analyse (kostenlos, offiziell)'; NeedsArgs=$false }
    )
}

function Find-SysPilotMcpRemoteServers {
    <# Kostenlose MCP-Kataloge aus dem Web (keine Bezahl-API noetig):
       1) GitHub-Suche topic:mcp-server (API, keine Auth, ~10 req/min)
       2) awesome-mcp-servers README (kuratiert, npm-Paketnamen -> npx)
       Gibt vereinheitlichte Treffer zurueck: Name, Desc, Package
       (falls als npx installierbar erkennbar), RepoUrl, Source, Stars. #>
    param([string]$Query = '', [int]$Limit = 25)
    $out = @()
    $headers = @{ 'User-Agent' = 'SysPilot-McpCatalog'; 'Accept' = 'application/vnd.github+json' }
    # 1) awesome-mcp-servers: README parsen (Linktext = oft npm-Paket)
    try {
        $md = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/punkpeye/awesome-mcp-servers/main/README.md' -TimeoutSec 20 -Headers $headers -ErrorAction Stop
        $qLower = $Query.ToLower()
        foreach ($line in ($md -split "`r?`n")) {
            if ($line -notmatch '^\s*[-*]\s*\[([^\]]+)\]\((https?://[^)]+)\)\s*-\s*(.+)$') { continue }
            $pkg = $Matches[1].Trim(); $url = $Matches[2].Trim(); $desc = $Matches[3].Trim()
            if ($qLower -and "$pkg $desc".ToLower() -notmatch [regex]::Escape($qLower)) { continue }
            # npm-Paket (@scope/name oder name) vs. GitHub-Shorthand (owner/repo)
            $npmPkg = ''
            if ($pkg -match '^@[\w.-]+/[\w.-]+$') { $npmPkg = $pkg }
            elseif ($pkg -match '^[\w.-]+$') { $npmPkg = $pkg }
            elseif ($pkg -match '^[\w.-]+/[\w.-]+$') { $npmPkg = "github:$pkg" }
            $out += [pscustomobject]@{
                Name = ($pkg -replace '^@.*/','' -replace '^github:',''); Desc = $desc.Substring(0,[Math]::Min(160,$desc.Length))
                Package = $npmPkg; RepoUrl = $url
                Source = 'awesome-mcp'; Stars = 0
            }
            if ($out.Count -ge $Limit) { break }
        }
    } catch { Write-SysPilotMcpLog "awesome-mcp fetch: $($_.Exception.Message)" }
    # 2) GitHub topic-Suche (nur wenn Query oder als Ergaenzung die Top-Treffer)
    try {
        $q = 'topic:mcp-server'
        if ($Query) { $q += ' ' + (($Query -split '\s+') -join ' ') }
        $uri = 'https://api.github.com/search/repositories?q=' + [uri]::EscapeDataString($q) + '&sort=stars&order=desc&per_page=' + [Math]::Min(15,$Limit)
        $gh = Invoke-RestMethod -Uri $uri -TimeoutSec 20 -Headers $headers -ErrorAction Stop
        foreach ($it in @($gh.items)) {
            if (-not $it.full_name) { continue }
            $out += [pscustomobject]@{
                Name = ($it.name -replace '[^\w.-]','-'); Desc = ([string]$it.description)
                Package = ''; RepoUrl = [string]$it.html_url
                Source = 'github'; Stars = [int]$it.stargazers_count
            }
        }
    } catch { Write-SysPilotMcpLog "github mcp search: $($_.Exception.Message)" }
    # Dedupe nach Name,awesome zuerst (hat Package), dann Sortierung
    $seen=@{}; $res=@()
    foreach ($r in $out) { $k=$r.Name.ToLower(); if(-not $seen.ContainsKey($k)){$seen[$k]=1;$res+=$r} }
    return @($res | Sort-Object @{ Expression = { if ($_.Package) { 0 } else { 1 } } }, @{ Expression = { -[double]$_.Stars } } | Select-Object -First $Limit)
}

function Find-SysPilotMcpRegistryServers {
    <# Offizielle MCP-Registry (registry.modelcontextprotocol.io) -
       tausende Server, npm-Pakete + ferngesteuerte streamable-http-URLs.
       environmentVariables liefern isRequired/isSecret -> Env-Hinweise.
       Gibt vereinheitlichte Treffer zurueck (wie Find-SysPilotMcpRemoteServers,
       plus RemoteUrl/EnvVars/Paid). #>
    param([string]$Query = '', [int]$Limit = 40)
    $out = @(); $seen = @{}
    $cursor = ''; $pages = 0
    while ($out.Count -lt ($Limit * 3) -and $pages -lt 4) {
        $pages++
        $uri = 'https://registry.modelcontextprotocol.io/v0/servers?limit=100'
        if ($Query) { $uri += '&search=' + [uri]::EscapeDataString($Query) }
        if ($cursor) { $uri += '&cursor=' + [uri]::EscapeDataString($cursor) }
        try {
            $r = Invoke-RestMethod -Uri $uri -TimeoutSec 25 -Headers @{ 'User-Agent'='SysPilot-McpCatalog'; 'Accept'='application/json' } -ErrorAction Stop
        } catch { break }
        $servers = @($r.servers)
        if ($servers.Count -eq 0) { break }
        foreach ($entry in $servers) {
            $sv = $entry.server
            if (-not $sv -or -not $sv.name) { continue }
            if ($seen.ContainsKey($sv.name)) { continue }
            $seen[$sv.name] = $true
            $pkgs = @($sv.packages)
            $pkg = ''
            if ($pkgs.Count -gt 0) {
                $npm = @($pkgs | Where-Object { $_.registryType -eq 'npm' } | Select-Object -First 1)
                if (-not $npm) { $npm = @($pkgs | Select-Object -First 1) }
                if ($npm -and $npm.identifier) { $pkg = [string]$npm.identifier }
            }
            $remoteUrl = ''
            $http = @(@($sv.remotes) | Where-Object { $_.type -match 'http' } | Select-Object -First 1)
            if ($http.Count -and $http[0].url) { $remoteUrl = [string]$http[0].url }
            $repoUrl = ''
            if ($sv.repository -and $sv.repository.url) { $repoUrl = [string]$sv.repository.url }
            elseif ($sv.websiteUrl) { $repoUrl = [string]$sv.websiteUrl }
            $envNames = @(); $needTok = $false
            foreach ($pv in @($pkgs | ForEach-Object { @($_.environmentVariables) })) {
                foreach ($ev in @($pv)) {
                    if ($ev.name) { $envNames += [string]$ev.name }
                    if ($ev.isRequired -eq $true -or $ev.isSecret -eq $true) { $needTok = $true }
                }
            }
            if ($envNames.Count -gt 0) { $needTok = $true }
            $desc = [string]$sv.description
            $paid = ($desc -match '(?i)\b(paid|subscription|credits|pricing|pay per|enterprise license)\b')
            # Name: lesstes Segment der reverse-DNS-URL
            $nm = (($sv.name -split '/')[-1]) -replace '^[\w.]+/','' -replace '[^\w.-]','-'
            if (-not $nm) { $nm = 'mcp-registry' }
            $note = ''
            if ($paid) { $note += ' [kostenpflichtig]' }
            if ($needTok) { $note += ' [Token/Env noetig]' }
            $d = $desc; if ($d.Length -gt 200) { $d = $d.Substring(0,200)+'...' }
            $out += [pscustomobject]@{
                Name = $nm; Desc = "$d$note"; Package = $pkg; RemoteUrl = $remoteUrl
                RepoUrl = $repoUrl; EnvVars = @($envNames); Source = 'mcp-registry'
                Stars = 0; Paid = $paid; NeedsToken = $needTok
            }
            if ($out.Count -ge ($Limit * 3)) { break }
        }
        $cursor = ''
        if ($r.metadata -and $r.metadata.nextCursor) { $cursor = [string]$r.metadata.nextCursor }
        if (-not $cursor) { break }
    }
    return @($out | Select-Object -First $Limit)
}

function Find-SysPilotMcpSmitheryServers {
    <# Smithery.ai - inoffizieller MCP-Verzeichnis-Dienst.
       Enthaelt auch kostenpflichtige/gemetete Server - diese werden
       als Option mit [kostenpflichtig]-Markierung geliefert.
       Remote-faehige Server bekommen eine smithery-Remote-URL. #>
    param([string]$Query = '', [int]$Limit = 40)
    $out = @(); $seen = @{}
    $uri = 'https://api.smithery.ai/servers?limit=' + [Math]::Min(100, [Math]::Max(20, $Limit * 2))
    if ($Query) { $uri += '&query=' + [uri]::EscapeDataString($Query) }
    try {
        $r = Invoke-RestMethod -Uri $uri -TimeoutSec 25 -Headers @{ 'User-Agent'='SysPilot-McpCatalog'; 'Accept'='application/json' } -ErrorAction Stop
    } catch { return @() }
    foreach ($s in @($r.servers)) {
        $qn = [string]$s.qualifiedName
        if (-not $qn -or $seen.ContainsKey($qn.ToLower())) { continue }
        if ($s.inactive -eq $true -or $s.unlisted -eq $true) { continue }
        $seen[$qn.ToLower()] = $true
        $desc = [string]$s.description
        $paid = ($desc -match '(?i)\b(paid|subscription|credits|pricing|pay per|per month|per year)\b')
        $remoteUrl = ''
        if ($s.remote -eq $true) { $remoteUrl = "https://server.smithery.ai/@$qn" }
        $nm = ([string]$s.displayName); if (-not $nm) { $nm = $qn }
        $nm = ($nm -replace '[^\w.-]','-')
        $note = ''
        if ($paid) { $note += ' [kostenpflichtig]' }
        if (-not $remoteUrl) { $note += ' [kein Direkt-Connect]' }
        $d = $desc; if ($d.Length -gt 200) { $d = $d.Substring(0,200)+'...' }
        $out += [pscustomobject]@{
            Name = $nm; Desc = "$d$note"; Package = ''; RemoteUrl = $remoteUrl
            RepoUrl = "https://smithery.ai/server/$qn"; EnvVars = @()
            Source = 'smithery'; Stars = [int]$s.useCount; Paid = $paid; NeedsToken = $false
        }
        if ($out.Count -ge $Limit) { break }
    }
    return @($out)
}

function Install-SysPilotMcpRemote {
    <# Registriert einen remote (streamable-http) MCP-Server direkt
       in der SysPilot-Config - kein npx noetig. #>
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Url,
          [hashtable]$Headers = @{})
    $safe = ($Name -replace '[^\w.-]','-')
    $mc = Read-SysPilotMcpConfig
    if (-not $mc.Servers) { $mc | Add-Member -NotePropertyName Servers -NotePropertyValue ([pscustomobject]@{}) -Force }
    $hdrObj = [pscustomobject]@{}
    foreach ($k in $Headers.Keys) { $hdrObj | Add-Member -NotePropertyName $k -NotePropertyValue $Headers[$k] -Force }
    $mc.Servers | Add-Member -NotePropertyName $safe -NotePropertyValue ([pscustomobject]@{
        type = 'streamableHttp'; url = $Url; headers = $hdrObj
    }) -Force
    $mc.Disabled = @($mc.Disabled | Where-Object { $_ -ne $safe })
    Write-SysPilotMcpConfig $mc
    $script:McpToolsCache=@{}; $script:McpToolsCacheTime=[datetime]::MinValue
    return @{ Ok=$true; Message="Remote-Server registriert: $safe ($Url)" }
}

function Install-SysPilotMcpServer {
    <# Installiert einen MCP-Server aus dem Katalog in die
       SysPilot-Config (mcp.json -> Servers) und aktiviert ihn.
       Prueft npm/npx-Verfuegbarkeit. Gibt @{Ok;Message} zurueck. #>
    param([Parameter(Mandatory)][string]$Name, [string]$Args = '', [hashtable]$Env = @{})
    $cat = @(Get-SysPilotMcpInstallCatalog) | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if (-not $cat) { return @{ Ok=$false; Message="Unbekannter Server: $Name" } }
    $mc = Read-SysPilotMcpConfig
    if (-not $mc.Servers) { $mc | Add-Member -NotePropertyName Servers -NotePropertyValue ([pscustomobject]@{}) -Force }
    $runtime = if ($cat.Runtime) { [string]$cat.Runtime } else { 'npx' }
    if ($runtime -eq 'uvx') {
        $uvx = (Get-Command uvx -ErrorAction SilentlyContinue).Source
        if (-not $uvx) { $uvx = (Get-Command uv -ErrorAction SilentlyContinue).Source }
        if (-not $uvx) { return @{ Ok=$false; Message='uv/uvx nicht gefunden - noetig fuer Python-MCPs (winget install astral-sh.uv)' } }
        $argList = @($cat.Package)
        if ($Args) { $argList += ($Args -split '\s+' | Where-Object { $_ }) }
        $mc.Servers | Add-Member -NotePropertyName $Name -NotePropertyValue ([pscustomobject]@{
            command = 'uvx'; args = $argList; env = $Env
        }) -Force
    } else {
        $npx = (Get-Command npx.cmd -ErrorAction SilentlyContinue).Source
        if (-not $npx) { $npx = (Get-Command npx -ErrorAction SilentlyContinue).Source }
        if (-not $npx) { return @{ Ok=$false; Message='npx nicht gefunden - Node.js noetig (winget install OpenJS.NodeJS)' } }
        $argList = @('-y', $cat.Package)
        if ($Args) { $argList += ($Args -split '\s+' | Where-Object { $_ }) }
        $mc.Servers | Add-Member -NotePropertyName $Name -NotePropertyValue ([pscustomobject]@{
            command = 'npx'; args = $argList
            env = $Env
        }) -Force
    }
    Write-SysPilotMcpConfig $mc
    # Aktivieren (Default-Liste oder Disabled entfernen)
    $disabled = @($mc.Disabled | Where-Object { $_ -ne $Name })
    $mc.Disabled = $disabled
    Write-SysPilotMcpConfig $mc
    return @{ Ok=$true; Message="Installiert+aktiviert: $Name ($($cat.Package))" }
}

function Install-SysPilotMcpPackage {
    <# Generischer Install fuer Katalog-Treffer mit npm-Paketname
       (z.B. aus Find-SysPilotMcpRemoteServers / awesome-mcp-servers). #>
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Package,
          [string]$Args = '', [hashtable]$Env = @{})
    $npx = (Get-Command npx.cmd -ErrorAction SilentlyContinue).Source
    if (-not $npx) { $npx = (Get-Command npx -ErrorAction SilentlyContinue).Source }
    if (-not $npx) { return @{ Ok=$false; Message='npx nicht gefunden - Node.js noetig (winget install OpenJS.NodeJS)' } }
    $safe = ($Name -replace '[^\w.-]','-')
    $mc = Read-SysPilotMcpConfig
    if (-not $mc.Servers) { $mc | Add-Member -NotePropertyName Servers -NotePropertyValue ([pscustomobject]@{}) -Force }
    $argList = @('-y', $Package)
    if ($Args) { $argList += ($Args -split '\s+' | Where-Object { $_ }) }
    $envObj = [pscustomobject]@{}
    foreach ($k in $Env.Keys) { $envObj | Add-Member -NotePropertyName $k -NotePropertyValue ([string]$Env[$k]) -Force }
    $mc.Servers | Add-Member -NotePropertyName $safe -NotePropertyValue ([pscustomobject]@{
        command = 'npx'; args = $argList; env = $envObj
    }) -Force
    $mc.Disabled = @($mc.Disabled | Where-Object { $_ -ne $safe })
    Write-SysPilotMcpConfig $mc
    return @{ Ok=$true; Message="Installiert+aktiviert: $safe ($Package)" }
}

function Show-SysPilotMcpInstallMenu {
    <# Katalog der installierbaren MCP-Server. #>
    $cat = @(Get-SysPilotMcpInstallCatalog)
    $existing = @{}
    foreach ($s in (Get-SysPilotMcpServers)) { $existing[$s.Name] = $true }
    $items = foreach ($c in $cat) {
        $mark = if ($existing[$c.Name]) { '[installiert] ' } else { '' }
        $argsTxt = if ($c.NeedsArgs) { ' - ACHTUNG: Args noetig (Pfade/Token)' } else { '' }
        @{ Label="$mark$($c.Name) - $($c.Desc)$argsTxt"; Color=$(if($existing[$c.Name]){'DarkGray'}else{'Cyan'}); Tag=$c }
    }
    $items += @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
    $sel = Show-SysPilotArrowMenu -Items $items -Title 'MCP-Server installieren' -Footer 'Enter = installieren, Esc = zurueck'
    if ($null -eq $sel) { return }
    # Args/Token abfragen falls noetig
    $srvArgs = ''
    if ($sel.NeedsArgs) {
        $srvArgs = Read-SysPilotInput "Args fuer $($sel.Name) (z.B. erlaubte Pfade/Datei)"
        if (-not $srvArgs) { $srvArgs = '' }
    }
    $envH = @{}
    if ($sel.NeedsToken) {
        $tok = Read-SysPilotInput 'GITHUB_PERSONAL_ACCESS_TOKEN (leer = speter in mcp.json eintragen)'
        if ($tok) { $envH['GITHUB_PERSONAL_ACCESS_TOKEN'] = $tok.Trim() }
    }
    $r = Install-SysPilotMcpServer -Name $sel.Name -Args $srvArgs -Env $envH
    Write-Host "  $($r.Message)" -ForegroundColor $(if($r.Ok){'Green'}else{'Red'})
    if ($r.Ok) {
        Write-Host '  Hinweis: Server wird beim naechsten Chat-Anruf gestartet (npx laedt Paket beim ersten Start).' -ForegroundColor DarkYellow
        if ($sel.NeedsArgs -and -not $srvArgs) { Write-Host "  ACHTUNG: $($sel.Name) braucht Args - unter MCP-Server-Detail pruefen." -ForegroundColor DarkYellow }
    }
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
}

function Show-SysPilotMcpMenu {
    <# MCP-Server verwalten: Status, Test, aktivieren/deaktivieren. #>
    while ($true) {
        $servers = @(Get-SysPilotMcpServers)
        Write-Host "`n  ========================================================" -ForegroundColor Cyan
        Write-Host "           SYSPilot MCP-SERVER" -ForegroundColor Cyan
        Write-Host "  ========================================================" -ForegroundColor Cyan
        Write-Host "  Config: $script:McpConfigPath" -ForegroundColor DarkGray
        $items = @()
        foreach ($s in $servers) {
            $std = if ($s.IsDefault) { 'STD' } else { '   ' }
            $en = if ($s.Enabled) { 'an ' } else { 'aus' }
            $col = if ($s.Enabled) { 'Green' } else { 'DarkGray' }
            $tr = if ($s.Type -eq 'stdio') { 'stdio' } else { 'http ' }
            $items += @{ Label = ("[{0}] {1} {2} {3} ({4})" -f $std,$en,$tr,$s.Name, $(if($s.Type -eq 'stdio'){$s.Command}else{$s.Url})); Color=$col; Tag="s:$($s.Name)" }
        }
        if ($items.Count -eq 0) { $items += @{ Label='(keine MCP-Server in Windsurf/Cline-Config gefunden)'; Color='DarkGray'; Tag=$null } }
        $items += @{ Label='[+] MCP-Server installieren (Katalog: filesystem, fetch, memory, github ...)'; Color='Green'; Tag='install' }
        $items += @{ Label='[*] Faehigkeit suchen + installieren (Herbert: MCP + Skills, Remote-Kataloge)'; Color='Cyan'; Tag='capability' }
        $items += @{ Label='[R] Tool-Liste neu laden (Cache leeren)'; Color='Cyan'; Tag='refresh' }
        $items += @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'MCP-Server' -Footer 'Enter = Server-Details, Esc = zurueck'
        if ($null -eq $sel) { return }
        if ($sel -eq 'install') { Show-SysPilotMcpInstallMenu; continue }
        if ($sel -eq 'capability') {
            if (Get-Command Install-SysPilotHerbertCapability -ErrorAction SilentlyContinue) {
                $need = Read-SysPilotInput 'Welche Faehigkeit/Problem? (z.B. websuche, browser, datenbank)' '' 'Herbert'
                if ($need) { Install-SysPilotHerbertCapability -Need $need }
            } else { Write-Host '  AiAssist-Modul nicht geladen.' -ForegroundColor Red }
            continue
        }
        if ($sel -eq 'refresh') { $script:McpToolsCache=@{}; $script:McpToolsCacheTime=[datetime]::MinValue; continue }
        if ($sel -like 's:*') {
            $name = $sel.Substring(2)
            Show-SysPilotMcpServerDetail -Name $name
        }
    }
}

function Show-SysPilotMcpServerDetail {
    param([Parameter(Mandatory)][string]$Name)
    $s = @(Get-SysPilotMcpServers) | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if (-not $s) { return }
    Write-Host "`n  --- MCP-Server: $($s.Name) ---" -ForegroundColor Cyan
    Write-Host "  Transport: $($s.Type) | Quelle: $($s.Source)" -ForegroundColor DarkGray
    if ($s.Type -eq 'stdio') { Write-Host "  Start: $($s.Command) $($s.Args -join ' ')" } else { Write-Host "  URL: $($s.Url)" }
    Write-Host "  Status: $(if($s.Enabled){'aktiviert'}else{'deaktiviert'}) | Standard: $($s.IsDefault)" -ForegroundColor DarkGray
    Write-Host "`n  Teste tools/list ..." -ForegroundColor DarkGray
    $r = Invoke-SysPilotMcpRpc -Server $s -Method 'tools/list' -Params @{} -TimeoutSec 40
    if ($r.Ok -and $r.Result.tools) {
        Write-Host "  [OK] $($r.Result.tools.Count) Tools verfuegbar:" -ForegroundColor Green
        foreach ($t in ($r.Result.tools | Select-Object -First 20)) {
            $d = [string]$t.description
            if ($d.Length -gt 80) { $d = $d.Substring(0,80)+'...' }
            Write-Host "    - $($t.name): $d" -ForegroundColor White
        }
    } else {
        Write-Host "  [!] $($r.Error)" -ForegroundColor Red
    }
    $items = @(
        @{ Label=($(if($s.Enabled){'Deaktivieren'}else{'Aktivieren'})); Color='Yellow'; Tag='toggle' }
        @{ Label='Tools auflisten (Cache neu)'; Color='White'; Tag='tools' }
        @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
    )
    $sel = Show-SysPilotArrowMenu -Items $items -Title $s.Name -Footer 'Esc = zurueck'
    if ($sel -eq 'toggle') {
        $mc = Read-SysPilotMcpConfig
        $dis = @($mc.Disabled)
        if ($s.Enabled) { $dis += $s.Name } else { $dis = @($dis | Where-Object { $_ -ne $s.Name }) }
        $mc.Disabled = @($dis | Select-Object -Unique)
        Write-SysPilotMcpConfig $mc
        $script:McpToolsCache=@{}; $script:McpToolsCacheTime=[datetime]::MinValue
        Write-Host "  Gespeichert." -ForegroundColor Green
        Read-SysPilotChoice 'Weiter' | Out-Null
    } elseif ($sel -eq 'tools') {
        $script:McpToolsCache=@{}; $script:McpToolsCacheTime=[datetime]::MinValue
        $tl = @(Get-SysPilotMcpTools -Refresh)
        Write-Host "`n  Alle Tools ($($tl.Count)):" -ForegroundColor Cyan
        $tl | ForEach-Object { Write-Host "    [$($_.Server)] $($_.Name)" -ForegroundColor White }
        Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
    }
}

function Set-SysPilotMcpServerEnabled {
    <# Aktiviert/deaktiviert einen Server (mcp.json Disabled-Liste).
       Gibt @{Ok;Message} zurueck. #>
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][bool]$Enabled)
    $mc = Read-SysPilotMcpConfig
    $dis = @($mc.Disabled | Where-Object { $_ -ne $Name })
    if (-not $Enabled) { $dis += $Name }
    $mc.Disabled = @($dis | Select-Object -Unique)
    Write-SysPilotMcpConfig $mc
    $script:McpToolsCache=@{}; $script:McpToolsCacheTime=[datetime]::MinValue
    return @{ Ok=$true; Message="$(if($Enabled){'Aktiviert'}else{'Deaktiviert'}): $Name" }
}

function Remove-SysPilotMcpServer {
    <# Entfernt einen SysPilot-installierten Server komplett aus mcp.json. #>
    param([Parameter(Mandatory)][string]$Name)
    $mc = Read-SysPilotMcpConfig
    $removed = $false
    if ($mc.Servers -and ($mc.Servers.PSObject.Properties.Name -contains $Name)) {
        $mc.Servers.PSObject.Properties.Remove($Name); $removed = $true
    }
    $mc.Disabled = @($mc.Disabled | Where-Object { $_ -ne $Name })
    Write-SysPilotMcpConfig $mc
    $script:McpToolsCache=@{}; $script:McpToolsCacheTime=[datetime]::MinValue
    return @{ Ok=$removed; Message=$(if($removed){"Entfernt: $Name"}else{"Nicht in SysPilot-Config: $Name"}) }
}

Export-ModuleMember -Function `
    Get-SysPilotMcpServers, Get-SysPilotMcpTools, Get-SysPilotMcpChatToolDefs, `
    ConvertTo-SysPilotMcpOpenAiTools, Find-SysPilotMcpToolDef, `
    Invoke-SysPilotMcpTool, Invoke-SysPilotMcpRpc, `
    Get-SysPilotMcpInstallCatalog, Install-SysPilotMcpServer, Find-SysPilotMcpRemoteServers, Install-SysPilotMcpPackage, `
    Find-SysPilotMcpRegistryServers, Find-SysPilotMcpSmitheryServers, Install-SysPilotMcpRemote, `
    Show-SysPilotMcpInstallMenu, Show-SysPilotMcpMenu, Read-SysPilotMcpConfig, Write-SysPilotMcpConfig, `
    Set-SysPilotMcpServerEnabled, Remove-SysPilotMcpServer
