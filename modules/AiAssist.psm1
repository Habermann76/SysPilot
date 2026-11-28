# =====================================================================
# AiAssist.psm1 - KI-Assistenz fuer SysPilot
# OpenAI-kompatible Provider: lokale Router (Ollama, LM Studio,
# FreeLLMAPI, OmniRoute) + kostenlose Cloud-Tiers mit eigenem API-Key
# (Google AI Studio, Groq, OpenRouter, GitHub Models, Mistral,
# Cerebras). Keys werden DPAPI-verschluesselt in
# %LOCALAPPDATA%\SysPilot\ai-assist.json gespeichert.
# =====================================================================

$script:AiAssistConfigPath = Join-Path $env:LOCALAPPDATA 'SysPilot\ai-assist.json'
# URLs, die KEIN OpenAI-kompatibler Chat-Endpoint sind (TTS, Search,
# Bilder, special-purpose APIs) - werden aus Katalog + Ordner-Import
# herausgefiltert, damit die Providerliste nutzbar bleibt.
$script:AiNonChatUrlRe = '(?i)tts|speech|transcri|search|omdb|embed|image|video|cartesia|elevenlabs|exa\.ai|tavily|serpsearch|firecrawl|linkup|watchmode|perplexity|brave|cloudflare|outcrawl|freetts|typecast|speechify|tripo|bazaarlink|beatapi|blazeapi|gizmoplatforms|jamai|logfare|lucidity|meldport|nabh|onomeo|plugsky|powertokens|rime|sailresearch|sea-lion|septorlabs|silvr|simplellm|dreamprompting|get\.php|password=|username=|m3u|apikey=|anthropic'
# Caches gegen OneDrive-Scanning-Freeze: Key-Dateiliste (10 min TTL)
# und Datei-Parse-Ergebnisse (keyed auf Pfad+Groesse+mtime).
$script:AiKeyCandidatesCache = $null
$script:AiKeyCandidatesCacheTime = [datetime]::MinValue
$script:AiKeyFileParseCache = @{}
# Chat-Fallback: Modell-Aufloesung + Provider-Fehler werden pro Prozess
# gecacht, damit die Kette nicht bei jedem Versand 50+ Provider
# nacheinander mit HTTP-Timeouts abarbeitet (UI wirkte "haengend").
$script:AiModelResolveCache = @{}
$script:AiProviderFailCache = @{}

function Protect-SysPilotSecret {
    param([Parameter(Mandatory)][string]$Plain)
    if ([string]::IsNullOrEmpty($Plain)) { return '' }
    try {
        $sec = ConvertTo-SecureString $Plain -AsPlainText -Force
        return (ConvertFrom-SecureString $sec)
    } catch { return $Plain }   # Fallback: unverschluesselt (alter Stand)
}

function Unprotect-SysPilotSecret {
    param([string]$Cipher)
    if ([string]::IsNullOrEmpty($Cipher)) { return '' }
    try {
        $sec = ConvertTo-SecureString $Cipher
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    } catch { return $Cipher }
}

function Read-SysPilotAiAssistConfig {
    if (Test-Path $script:AiAssistConfigPath) {
        try { return (Get-Content $script:AiAssistConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { }
    }
    return [pscustomobject]@{ Providers = @() }
}

function Write-SysPilotAiAssistConfig {
    param($Config)
    $dir = Split-Path $script:AiAssistConfigPath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $Config | ConvertTo-Json -Depth 6 | Set-Content $script:AiAssistConfigPath -Encoding UTF8
}

function Get-SysPilotAiLastSelection {
    <# Letzte Provider/Modell-Auswahl - wird von GUI-Panel UND
       Herbert-Fenster geteilt (gleiche Config). #>
    $cfg = Read-SysPilotAiAssistConfig
    return @{ Provider=[string]$cfg.LastProvider; Model=[string]$cfg.LastModel }
}

function Set-SysPilotAiLastSelection {
    param([string]$Provider = '', [string]$Model = '')
    $cfg = Read-SysPilotAiAssistConfig
    $cfg | Add-Member -NotePropertyName LastProvider -NotePropertyValue $Provider -Force
    $cfg | Add-Member -NotePropertyName LastModel    -NotePropertyValue $Model    -Force
    Write-SysPilotAiAssistConfig $cfg
}

# =====================================================================
# HERBERT-PERMISSIONS (Cline/Devin-Style)
# Modi: ask = bei medium/high fragen (Standard),
#       auto = medium automatisch, high fragt,
#       bypass = alles automatisch (inkl. MCP-Werkzeuge).
# Pro Aktion/MCP-Werkzeug zusaetzlich Override: allow|deny|ask.
# =====================================================================

function Get-SysPilotHerbertPermissionMode {
    $cfg = Read-SysPilotAiAssistConfig
    $m = [string]$cfg.PermissionMode
    if ($m -notin @('ask','auto','bypass')) { $m = 'ask' }
    return $m
}

function Set-SysPilotHerbertPermissionMode {
    param([Parameter(Mandatory)][ValidateSet('ask','auto','bypass')][string]$Mode)
    $cfg = Read-SysPilotAiAssistConfig
    $cfg | Add-Member -NotePropertyName PermissionMode -NotePropertyValue $Mode -Force
    Write-SysPilotAiAssistConfig $cfg
}

function Get-SysPilotHerbertPermissionOverride {
    <# Liefert 'allow'|'deny'|'ask'|'' fuer Kind 'action'/'mcp' + Id. #>
    param([string]$Kind = 'action', [Parameter(Mandatory)][string]$Id)
    $cfg = Read-SysPilotAiAssistConfig
    $prop = if ($Kind -eq 'mcp') { 'McpPermOverrides' } else { 'ActionPermOverrides' }
    $hit = @($cfg.$prop | Where-Object { $_.Id -eq $Id } | Select-Object -First 1)
    if ($hit.Count) { return [string]$hit[0].Value }
    return ''
}

function Set-SysPilotHerbertPermissionOverride {
    <# Setzt/loescht ein Override. Value='' = loeschen (Standard). #>
    param([string]$Kind = 'action', [Parameter(Mandatory)][string]$Id,
          [ValidateSet('','allow','deny','ask')][string]$Value = '')
    $cfg = Read-SysPilotAiAssistConfig
    $prop = if ($Kind -eq 'mcp') { 'McpPermOverrides' } else { 'ActionPermOverrides' }
    $list = @($cfg.$prop | Where-Object { $_.Id -ne $Id })
    if ($Value -ne '') { $list += [pscustomobject]@{ Id = $Id; Value = $Value } }
    $cfg | Add-Member -NotePropertyName $prop -NotePropertyValue @($list) -Force
    Write-SysPilotAiAssistConfig $cfg
}

function Test-SysPilotKiPermission {
    <# Loest die Effective-Permission auf: 'allow'|'deny'|'ask'.
       Explizites Override schlaegt den globalen Modus. #>
    param([Parameter(Mandatory)][string]$Kind,          # 'action' | 'mcp'
          [Parameter(Mandatory)][string]$Id,
          [string]$Risk = 'high')
    $ov = Get-SysPilotHerbertPermissionOverride -Kind $Kind -Id $Id
    if ($ov -in @('allow','deny','ask')) { return $ov }
    $mode = Get-SysPilotHerbertPermissionMode
    if ($mode -eq 'bypass') { return 'allow' }
    if ($Kind -eq 'mcp') { return 'ask' }   # MCP-Werkzeuge sind immer kritisch - 'auto' deckt sie NICHT ab
    if ($mode -eq 'auto') { if ($Risk -eq 'high') { return 'ask' } else { return 'allow' } }
    if ($Risk -eq 'low') { return 'allow' }
    return 'ask'
}

function Get-SysPilotAiProviderDefaults {
    <# Lokale OpenAI-kompatible Endpunkte (keine Keys noetig).
       Werden per Port-Probe auf Erreichbarkeit geprueft. #>
    return @(
        @{ Name='Ollama (lokal)';        BaseUrl='http://localhost:11434/v1';            Kind='local'; PortProbe=$true },
        @{ Name='LM Studio (lokal)';     BaseUrl='http://localhost:1234/v1';             Kind='local'; PortProbe=$true },
        @{ Name='FreeLLMAPI (lokal)';    BaseUrl='http://localhost:3001/v1';              Kind='local'; PortProbe=$true },
        @{ Name='OmniRoute (lokal)';     BaseUrl='http://localhost:20128/v1';             Kind='local'; PortProbe=$true },
        # Weitere lokale OpenAI-kompatible KI-Apps (werden nur angezeigt,
        # wenn der Port antwortet - PortProbe)
        @{ Name='Jan (lokal)';           BaseUrl='http://localhost:1337/v1';              Kind='local'; PortProbe=$true },
        @{ Name='GPT4All (lokal)';       BaseUrl='http://localhost:4891/v1';              Kind='local'; PortProbe=$true },
        @{ Name='KoboldCpp (lokal)';     BaseUrl='http://localhost:5001/v1';              Kind='local'; PortProbe=$true },
        @{ Name='vLLM (lokal)';         BaseUrl='http://localhost:8000/v1';              Kind='local'; PortProbe=$true },
        @{ Name='llama.cpp/LocalAI';    BaseUrl='http://localhost:8080/v1';              Kind='local'; PortProbe=$true },
        @{ Name='textgen-webui (lokal)'; BaseUrl='http://localhost:5000/v1';              Kind='local'; PortProbe=$true },
        @{ Name='PocketAI (lokal)';      BaseUrl='http://127.0.0.1:39457/v1';            Kind='local'; PortProbe=$true },
        @{ Name='llama.cpp Server';     BaseUrl='http://127.0.0.1:8390/v1';             Kind='local'; PortProbe=$true },
        @{ Name='LlamaApp/HF (lokal)';   BaseUrl='http://127.0.0.1:9931/v1';             Kind='local'; PortProbe=$true },
        @{ Name='Kaggle TPU Proxy';      BaseUrl='http://127.0.0.1:18787/v1';            Kind='local'; PortProbe=$true }
    )
}

function Get-SysPilotAiFreeTierSuggestions {
    <# Anbieter mit brauchbarem KOSTENLOSEM Kontingent (Stand 2026).
       Der User traegt selbst einen Key ein - SysPilot sendet ihn nur
       an den jeweiligen Endpunkt. #>
    return @(
        @{ Name='Google Gemini (AI Studio)'; BaseUrl='https://generativelanguage.googleapis.com/v1beta/openai'; Model='gemini-2.5-flash';      Signup='https://aistudio.google.com/apikey';        Note='Grosszuegiges Freikontingent, Flash-Modelle' },
        @{ Name='Groq';                      BaseUrl='https://api.groq.com/openai/v1';                            Model='llama-3.3-70b-versatile'; Signup='https://console.groq.com/keys';            Note='Sehr schnell, Freikontingent' },
        @{ Name='OpenRouter';                BaseUrl='https://openrouter.ai/api/v1';                               Model='';                            Signup='https://openrouter.ai/keys';              Note='Viele :free-Modelle, ein Key fuer alles' },
        @{ Name='GitHub Models';             BaseUrl='https://models.github.ai/inference';                         Model='gpt-4o-mini';                  Signup='https://github.com/marketplace/models';   Note='GPT-Modelle mit GitHub-Account/PAT' },
        @{ Name='Mistral La Plateforme';     BaseUrl='https://api.mistral.ai/v1';                                   Model='mistral-small-latest';        Signup='https://console.mistral.ai/';              Note='Freikontingent vorhanden' },
        @{ Name='Cerebras';                  BaseUrl='https://api.cerebras.ai/v1';                                  Model='llama-3.3-70b';                Signup='https://cloud.cerebras.ai/';              Note='Extrem schnell, Freikontingent' }
    )
}

function Get-SysPilotAiProviderIntel {
    <# Anbieter-Metadaten: Kostenklasse, Inhaltsfilter (unzensierte/
       abliterated/heretic-Modelle), Hinweise. Kuratiert, Stand 2026 -
       Preise/aendern sich, daher als Orientierung nicht als Garantie.
       Cost:  lokal | kostenlos | freemium | guenstig | mittel | teuer | abo | unbekannt
       Content: unzensiert | abliterated | heretic | gemischt | zensiert | unbekannt #>
    param([string]$Name = '', [string]$BaseUrl = '')
    $table = @(
        # --- Lokal (alles moeglich, inkl. abliterated GGUFs von HF) ---
        @{ Match='Ollama';                 Cost='lokal';      Content='unzensiert'; Note='Beliebige Modelle inkl. abliterated GGUFs (HF)' },
        @{ Match='LM Studio';              Cost='lokal';      Content='unzensiert'; Note='Beliebige GGUFs, inkl. abliterated/heretic' },
        @{ Match='llama.cpp';              Cost='lokal';      Content='unzensiert'; Note='Beliebige GGUFs' },
        @{ Match='Jan';                    Cost='lokal';      Content='unzensiert'; Note='Beliebige GGUFs' },
        @{ Match='GPT4All';                Cost='lokal';      Content='unzensiert'; Note='Beliebige GGUFs' },
        @{ Match='KoboldCpp';              Cost='lokal';      Content='unzensiert'; Note='Beliebige GGUFs' },
        @{ Match='PocketAI';               Cost='lokal';      Content='unzensiert'; Note='Eigene Modelle' },
        @{ Match='LlamaApp';               Cost='lokal';      Content='unzensiert'; Note='Eigene Modelle' },
        @{ Match='vLLM';                   Cost='lokal';      Content='unzensiert'; Note='Beliebige Modelle' },
        @{ Match='textgen';                Cost='lokal';      Content='unzensiert'; Note='Beliebige Modelle' },
        @{ Match='OmniRoute';              Cost='lokal';      Content='gemischt';   Note='Router - abhaengig von Ziel' },
        @{ Match='FreeLLMAPI';             Cost='lokal';      Content='gemischt';   Note='Router - abhaengig von Ziel' },
        @{ Match='Kaggle TPU Proxy';       Cost='lokal';      Content='unzensiert'; Note='Kaggle-Free-Quota (~30h/Woche GPU/TPU) - Setup im Kaggle-Menue' },
        # --- Kostenlos (Free-Tier) ---
        @{ Match='Google Gemini';          Cost='kostenlos';  Content='zensiert';   Note='Grosszuegiges Freikontingent, Flash-Modelle' },
        @{ Match='Groq';                   Cost='kostenlos';  Content='zensiert';   Note='Sehr schnell, Freikontingent' },
        @{ Match='GitHub Models';          Cost='kostenlos';  Content='zensiert';   Note='GPT-Modelle, GitHub-Account' },
        @{ Match='Mistral';                Cost='freemium';   Content='zensiert';   Note='Freikontingent + Paid' },
        @{ Match='Cerebras';               Cost='kostenlos';  Content='zensiert';   Note='Extrem schnell, Freikontingent' },
        @{ Match='SambaNova';              Cost='kostenlos';  Content='zensiert';   Note='Kostenloses Kontingent' },
        @{ Match='NVIDIA NIM';             Cost='kostenlos';  Content='zensiert';   Note='Kostenloses Dev-Kontingent' },
        @{ Match='OpenCode Zen';           Cost='kostenlos';  Content='gemischt';   Note='Kostenlose Zen-Modelle' },
        @{ Match='Pollinations';           Cost='kostenlos';  Content='gemischt';   Note='Free-Endpoint, kein Key noetig' },
        @{ Match='Numes';                  Cost='freemium';   Content='gemischt';   Note='Gateway mit :free-Varianten, Routing steuerbar' },
        @{ Match='Kaggle Models';          Cost='kostenlos';  Content='unzensiert'; Note='Kein Chat-Endpoint - Models-API + 30h/Woche Gratis-Compute (GPU/TPU). Unzensiert via eigene Modelle in Kernels' },
        @{ Match='Kilo Gateway';           Cost='kostenlos';  Content='unzensiert'; Note='KEYLESS - kein Key noetig, OpenAI-kompatibel' },
        @{ Match='OVH AI Endpoints';       Cost='kostenlos';  Content='unzensiert'; Note='KEYLESS - anonym ~2 req/min' },
        @{ Match='LLM7';                   Cost='kostenlos';  Content='gemischt';   Note='Kostenlose Modelle, teils unzensierte' },
        @{ Match='Agnes AI';               Cost='kostenlos';  Content='gemischt';   Note='Kostenlose Chat-Modelle' },
        @{ Match='Aion Labs';              Cost='kostenlos';  Content='gemischt';   Note='Kostenlose Inference-Modelme' },
        # --- Guenstig (Pay-per-Token, guenstig) ---
        @{ Match='DeepSeek';               Cost='guenstig';   Content='zensiert';   Note='Guenig, stark' },
        @{ Match='SiliconFlow';            Cost='guenstig';   Content='gemischt';   Note='Viele Modelle guenstig/frei, teils unzensierte' },
        @{ Match='Z.ai';                   Cost='guenstig';   Content='zensiert';   Note='GLM-Flash guenstig' },
        @{ Match='Novita AI';              Cost='guenstig';   Content='gemischt';   Note='Serverless GPU + LLM-API' },
        @{ Match='Hyperbolic';             Cost='guenstig';   Content='unzensiert'; Note='Open-Modelle, teils unzensierte' },
        @{ Match='Chutes.ai';              Cost='guenstig';   Content='unzensiert'; Note='Dezentrales Bittorrent-Inference - viele unzensierte/abliterated Modelle' },
        @{ Match='Together AI';            Cost='guenstig';   Content='gemischt';   Note='Offene Modellvielfalt, teils unzensierte' },
        @{ Match='Fireworks AI';           Cost='guenstig';   Content='gemischt';   Note='Schnelle Inference' },
        @{ Match='Kimi';                   Cost='guenstig';   Content='zensiert';   Note='Moonshot-Modelle' },
        @{ Match='Requesty';               Cost='guenstig';   Content='gemischt';   Note='Router - kann auf unzensierte Modelle routen' },
        @{ Match='Featherless';            Cost='abo';        Content='unzensiert'; Note='Abo - spezialisiert auf unzensierte/abliterated HF-Modelle' },
        @{ Match='ArliAI';                 Cost='abo';        Content='unzensiert'; Note='Abo - unzensierte Chat-Modelle' },
        @{ Match='Mancer';                 Cost='guenstig';   Content='unzensiert'; Note='Unzensierte Modelle, pay-per-use' },
        @{ Match='NanoGPT';                Cost='guenstig';   Content='gemischt';   Note='Guinige API, Modellvielfalt' },
        @{ Match='Reka';                   Cost='freemium';   Content='zensiert';   Note='Reka-Modelle, Freitier' },
        @{ Match='Routeway';               Cost='guenstig';   Content='gemischt';   Note='Router mit Freimodellen' },
        @{ Match='BazaarLink';             Cost='gemischt';   Content='unzensiert'; Note='Aggregator - teils unzensierte Modelle' },
        @{ Match='AINative';               Cost='freemium';   Content='gemischt';   Note='Freemium-Modelle' },
        @{ Match='NaraRouter';             Cost='kostenlos';  Content='gemischt';   Note='Kostenloser Router' },
        @{ Match='SEA-LION';               Cost='guenstig';   Content='zensiert';   Note='AIs SEA-LION Modelle' },
        @{ Match='OrcaRouter';             Cost='guenstig';   Content='gemischt';   Note='Router, Freimodelle' },
        @{ Match='UnoRouter';              Cost='guenstig';   Content='gemischt';   Note='Router, guenstig' },
        @{ Match='xKiro';                  Cost='freemium';   Content='gemischt';   Note='Freemium-Gateway' },
        @{ Match='LongCat';                Cost='guenstig';   Content='gemischt';   Note='Meituan LongCat Modelle' },
        @{ Match='iFlytek Spark';          Cost='freemium';   Content='zensiert';   Note='Spark-Desk OpenAPI, Freikontingent' },
        @{ Match='Volcengine Ark';         Cost='guenstig';   Content='zensiert';   Note='Doubao/Seed Modelle' },
        @{ Match='cheapllm';               Cost='guenstig';   Content='gemischt';   Note='GuellsterAggregator' },
        @{ Match='AnyAPI';                 Cost='gemischt';   Content='unzensiert'; Note='Multi-Provider-Gateway' },
        @{ Match='PowerTokens';            Cost='guenstig';   Content='gemischt';   Note='Token-basiert, guenstig' },
        @{ Match='AMD Radeon Cloud';       Cost='guenstig';   Content='unzensiert'; Note='AMD-hosted Inference' },
        @{ Match='B.AI';                   Cost='gemischt';   Content='unzensiert'; Note='Aggregator mit Freimodellen' },
        # --- Gemischt (Free + Paid) ---
        @{ Match='OpenRouter';             Cost='gemischt';   Content='unzensiert'; Note='Enthaelt unzensierte Modelle (dolphin/hermes/abliterated) + :free-Modelle' },
        @{ Match='HuggingFace Router';     Cost='gemischt';   Content='abliterated';Note='Serverless-Inference - viele abliterated/heretic-Modelle auf HF, meist Paid' },
        @{ Match='Ollama Cloud';           Cost='freemium';   Content='gemischt';   Note='Gehostete Modelle, teils unzensierte in der Library' },
        @{ Match='Venice.ai';              Cost='abo';        Content='unzensiert'; Note='Privacy-Fokus, eigene unzensierte/abliterated Modelle - API meist Abo (Pro)' },
        @{ Match='Cohere';                 Cost='freemium';   Content='zensiert';   Note='Command-Modelle' },
        # --- Bezahlt: Frontier (teuer) ---
        @{ Match='OpenAI';                 Cost='teuer';      Content='zensiert';   Note='Frontier, zensiert - Budget-Mode meidet' },
        @{ Match='xAI';                    Cost='guenstig';   Content='zensiert';   Note='Grok-Modelle, guenstiger als OpenAI' },
        @{ Match='Anthropic';              Cost='teuer';      Content='zensiert';   Note='Claude-Frontier (Achtung: nativer Endpoint)' },
        @{ Match='Perplexity Sonar';       Cost='guenstig';   Content='zensiert';   Note='Search-API, pro Request/Token' },
        @{ Match='Writer';                 Cost='mittel';     Content='zensiert';   Note='Enterprise-Modelle' },
        @{ Match='Upstage';                Cost='guenstig';   Content='zensiert';   Note='Solar-Modelle' },
        # --- Bezahlt: Guenstige Inference/Serverless ---
        @{ Match='cheaperinference';       Cost='guenstig';   Content='gemischt';   Note='GuellsterAggregator (OmniRoute-Team)' },
        @{ Match='AI/ML API';              Cost='guenstig';   Content='gemischt';   Note='Aggregator, guenstig' },
        @{ Match='DeepInfra';              Cost='guenstig';   Content='gemischt';   Note='Serverless, viele guenstige Modelle' },
        @{ Match='Baseten';                Cost='guenstig';   Content='gemischt';   Note='Dedizierte/trained Modelle' },
        @{ Match='Nebius';                 Cost='guenstig';   Content='gemischt';   Note='EU-Inference' },
        @{ Match='Lambda Chat';            Cost='guenstig';   Content='unzensiert'; Note='Offene Modelle' },
        @{ Match='Cerebrium';              Cost='guenstig';   Content='gemischt';   Note='Serverless' },
        @{ Match='Replicate';              Cost='guenstig';   Content='unzensiert'; Note='Offene Modelle' },
        @{ Match='Scaleway';               Cost='guenstig';   Content='gemischt';   Note='EU-Cloud' },
        @{ Match='Hetzner';                Cost='guenstig';   Content='unzensiert'; Note='EU, sehr guenstig, Qwen/Llama' },
        @{ Match='AI21';                   Cost='guenstig';   Content='zensiert';   Note='Jamba-Modelle' },
        @{ Match='Qwen Cloud';             Cost='guenstig';   Content='zensiert';   Note='Alibaba Qwen' },
        @{ Match='MiniMax';                Cost='guenstig';   Content='gemischt';   Note='MiniMax-Modelle' },
        @{ Match='StepFun';                Cost='guenstig';   Content='zensiert';   Note='Step-Modelle' },
        @{ Match='Synthetic';              Cost='guenstig';   Content='gemischt';   Note='Guinige GPT-Modelle' },
        @{ Match='Morph';                  Cost='guenstig';   Content='unzensiert'; Note='Coding-Modelle' },
        @{ Match='LlamaGate';              Cost='guenstig';   Content='unzensiert'; Note='Offene Modelle' },
        @{ Match='Modal';                  Cost='guenstig';   Content='unzensiert'; Note='Serverless GPU' },
        @{ Match='Nscale';                 Cost='guenstig';   Content='gemischt';   Note='EU-Inference' },
        @{ Match='Nube';                   Cost='guenstig';   Content='gemischt';   Note='OpenAI-kompatibel' },
        @{ Match='OpenAdapter';            Cost='guenstig';   Content='gemischt';   Note='Aggregator' },
        @{ Match='ZenMux';                 Cost='guenstig';   Content='gemischt';   Note='Aggregator' },
        @{ Match='DigitalOcean';           Cost='guenstig';   Content='gemischt';   Note='Managed Inference' },
        @{ Match='BytePlus';               Cost='guenstig';   Content='gemischt';   Note='Doubao/Seed' },
        @{ Match='Baichuan';               Cost='guenstig';   Content='gemischt';   Note='Chinesische Modelle' },
        @{ Match='Yi (';                   Cost='guenstig';   Content='gemischt';   Note='Yi-Modelle' },
        @{ Match='InternLM';               Cost='guenstig';   Content='gemischt';   Note='Chinesische Modelle' },
        @{ Match='SenseNova';              Cost='guenstig';   Content='gemischt';   Note='Chinesische Modelle' },
        @{ Match='Tencent Hunyuan';        Cost='guenstig';   Content='zensiert';   Note='Hunyuan-Modelle' },
        @{ Match='Baidu Qianfan';          Cost='guenstig';   Content='zensiert';   Note='ERNIE-Modelle' },
        @{ Match='GigaChat';               Cost='guenstig';   Content='zensiert';   Note='Russische Modelle' },
        @{ Match='Sarvam';                 Cost='guenstig';   Content='gemischt';   Note='Indische Modelle' },
        @{ Match='W&B';                    Cost='gemischt';   Content='gemischt';   Note='Ueber W&B-Account' },
        @{ Match='Predibase';              Cost='guenstig';   Content='gemischt';   Note='Fine-tuned Serving' },
        @{ Match='ModelScope';             Cost='kostenlos';  Content='gemischt';   Note='Chinesische Modelle, teils gratis' },
        @{ Match='Cline (API)';            Cost='guenstig';   Content='gemischt';   Note='Cline-Provider-API' },
        @{ Match='Factory';                Cost='teuer';      Content='zensiert';   Note='Coding-Enterprise' },
        @{ Match='Codestral';              Cost='guenstig';   Content='gemischt';   Note='Mistral-Coding' },
        @{ Match='NanoGPT';                Cost='guenstig';   Content='gemischt';   Note='Guinige API' },
        @{ Match='CrofAI';                 Cost='guenstig';   Content='unzensiert'; Note='Offene/Unzensierte Modelle' },
        @{ Match='Typhoon';                Cost='kostenlos';  Content='gemischt';   Note='Thailaendische LLMs, teils gratis' },
        @{ Match='BluesMinds';             Cost='guenstig';   Content='unzensiert'; Note='Unzensierte Modelle' },
        @{ Match='Grokified';              Cost='guenstig';   Content='gemischt';   Note='Guinige Grok-Modelle' },
        @{ Match='Charm';                  Cost='guenstig';   Content='unzensiert'; Note='Unzensierte Modelle' },
        @{ Match='FreeModel';              Cost='kostenlos';  Content='gemischt';   Note='Kostenlose Modelle' },
        @{ Match='FreetheAI';              Cost='kostenlos';  Content='gemischt';   Note='Kostenlose Modelle' },
        @{ Match='FriendliAI';             Cost='guenstig';   Content='gemischt';   Note='Serverless' },
        @{ Match='PublicAI';               Cost='guenstig';   Content='unzensiert'; Note='Offene Modelle' },
        @{ Match='DGrid';                  Cost='guenstig';   Content='unzensiert'; Note='Dezentrale Modelle' },
        @{ Match='OpenVecta';              Cost='guenstig';   Content='unzensiert'; Note='Offene Modelle' },
        @{ Match='LLM-Kiwi';               Cost='guenstig';   Content='gemischt';   Note='Guiniger Gateway' },
        @{ Match='LLMGateway';             Cost='guenstig';   Content='gemischt';   Note='Router' },
        @{ Match='LlamaGate';              Cost='guenstig';   Content='unzensiert'; Note='Offene Modelle' },
        @{ Match='Speka';                  Cost='guenstig';   Content='unzensiert'; Note='Unzensierte Modelle' },
        @{ Match='VoidAI';                 Cost='guenstig';   Content='unzensiert'; Note='Unzensierte Modelle' },
        @{ Match='Uncensored';             Cost='guenstig';   Content='unzensiert'; Note='Unzensierte Modelle' },
        @{ Match='Onomeo';                 Cost='guenstig';   Content='unzensiert'; Note='Offene Modelle' },
        @{ Match='Yolo-Auto';              Cost='guenstig';   Content='gemischt';   Note='Router' },
        @{ Match='TokenReply';             Cost='guenstig';   Content='gemischt';   Note='Router' },
        @{ Match='TokenHarbor';            Cost='guenstig';   Content='gemischt';   Note='Router' },
        @{ Match='TokenMarket';            Cost='guenstig';   Content='gemischt';   Note='Router' },
        @{ Match='OfoxAI';                 Cost='guenstig';   Content='gemischt';   Note='Aggregator' },
        @{ Match='ZyloAI';                 Cost='guenstig';   Content='gemischt';   Note='Router' },
        @{ Match='MNN-AI';                 Cost='guenstig';   Content='gemischt';   Note='Russische Modelle' },
        @{ Match='SeekAI';                 Cost='freemium';   Content='gemischt';   Note='Freemium' },
        @{ Match='HelixMind';              Cost='guenstig';   Content='gemischt';   Note='Router' },
        @{ Match='HelyxAI';                Cost='guenstig';   Content='gemischt';   Note='Router' },
        @{ Match='Chenzk';                 Cost='guenstig';   Content='unzensiert'; Note='Unzensierte Modelle' },
        @{ Match='DahL';                   Cost='guenstig';   Content='gemischt';   Note='Serverless' },
        @{ Match='ByteZ';                  Cost='guenstig';   Content='gemischt';   Note='OpenAI-kompatibel' },
        @{ Match='Dit.ai';                 Cost='guenstig';   Content='gemischt';   Note='Router' },
        @{ Match='Unifcially';             Cost='guenstig';   Content='unzensiert'; Note='Offene Modelle' },
        @{ Match='MaxAI';                  Cost='freemium';   Content='gemischt';   Note='Freemium' },
        @{ Match='1min.AI';                Cost='freemium';   Content='gemischt';   Note='All-in-one' },
        @{ Match='Nous Research';          Cost='guenstig';   Content='unzensiert'; Note='Hermes/DisTral' },
        @{ Match='Syntx';                  Cost='guenstig';   Content='gemischt';   Note='Router' },
        @{ Match='TwinMind';               Cost='guenstig';   Content='gemischt';   Note='Router' },
        @{ Match='Regolo';                 Cost='guenstig';   Content='gemischt';   Note='Router' },
        @{ Match='ParalonCloud';           Cost='guenstig';   Content='gemischt';   Note='Router' },
        # --- teuer / Enterprise ---
        @{ Match='Google (paid)';          Cost='teuer';      Content='zensiert';   Note='Frontier, zensiert' }
    )
    foreach ($t in $table) {
        if ($Name -and $Name -match [regex]::Escape($t.Match)) { return $t }
        if ($BaseUrl -and $BaseUrl -match [regex]::Escape($t.Match)) { return $t }
    }
    # Herbert-Kurations-Overlay (ai-intel-extra.json) hat Vorrang vor 'unbekannt'
    foreach ($e in @(Get-SysPilotAiIntelExtra)) {
        $en = [string]$e.Name
        if ($Name -and ($Name -match [regex]::Escape($en) -or $en -match [regex]::Escape($Name))) {
            return @{ Match=$en; Cost=[string]$e.Cost; Content=[string]$e.Content; Note=[string]$e.Note }
        }
        if ($BaseUrl -and $BaseUrl -match [regex]::Escape($en)) {
            return @{ Match=$en; Cost=[string]$e.Cost; Content=[string]$e.Content; Note=[string]$e.Note }
        }
    }
    return @{ Match=''; Cost='unbekannt'; Content='unbekannt'; Note='' }
}

function Show-SysPilotAiProviderOverview {
    <# Sortierter Anbieter-Ueberblick: Kostenklassen x Inhaltsfilter.
       Erstellt Provider auf Wunsch, oeffnet Signup-Links. #>
    $cat = @(Get-SysPilotAiProviderCatalog -NoKeyFiles:$false)
    $rows = @()
    foreach ($c in $cat) {
        $intel = Get-SysPilotAiProviderIntel -Name $c.Name -BaseUrl $c.BaseUrl
        $rows += [pscustomobject]@{
            Name=$c.Name; Cost=$intel.Cost; Content=$intel.Content
            Key = $(if($c.HasKey){'Key:Set'}elseif($c.Configured){'konfig.'}else{'-'})
            Note=$intel.Note; Source=$c.Source
        }
    }
    $order = @('lokal','kostenlos','freemium','guenstig','gemischt','mittel','teuer','abo','unbekannt')
    Write-Host "`n  === ANBIETER-UEBERBLICK (Kosten + Inhaltsfilter) ===" -ForegroundColor Cyan
    Write-Host "  Content: unzensiert/abliterated/heretic = Modell ohne/mit gelockerten Filtern" -ForegroundColor DarkGray
    Write-Host "  lokal = kostenlos + volle Modellwahl (eigene GGUFs). Stand 2026, Preise veraenderlich.`n" -ForegroundColor DarkGray
    $groups = @{}
    foreach ($r in $rows) { $groups[$r.Cost] = @($groups[$r.Cost]) + $r }
    foreach ($cost in $order) {
        $g = @($groups[$cost])
        if ($g.Count -eq 0) { continue }
        $col = switch ($cost) { 'lokal' {'Green'} 'kostenlos' {'Green'} 'freemium' {'DarkGreen'} 'guenstig' {'Cyan'} 'gemischt' {'Yellow'} 'mittel' {'Yellow'} 'teuer' {'Red'} 'abo' {'Magenta'} default {'DarkGray'} }
        Write-Host ("  [{0}]  ({1} Anbieter)" -f $cost.ToUpper(), $g.Count) -ForegroundColor $col
        foreach ($r in ($g | Sort-Object Name)) {
            $cflag = switch ($r.Content) { 'unzensiert' {'[unzensiert]'} 'abliterated' {'[abliterated]'} 'heretic' {'[heretic]'} 'gemischt' {'[gemischt]'} 'zensiert' {'[zensiert]'} default {''} }
            $ccol = if ($r.Content -in @('unzensiert','abliterated','heretic')) {'Green'} elseif ($r.Content -eq 'zensiert') {'DarkGray'} else {'DarkYellow'}
            $key = if ($r.Key -eq 'Key:Set') {' *'} else {''}
            Write-Host ("    {0,-32} {1,-12} {2} {3}" -f $r.Name, $r.Key, $cflag, $r.Note) -ForegroundColor $ccol
        }
        Write-Host ''
    }
    # Interaktive Auswahl: Provider anlegen
    $items = @()
    foreach ($r in ($rows | Sort-Object Cost, Name)) {
        $tag = "add:$($r.Name)"
        $items += @{ Label = ("{0} [{1}] {2}" -f $r.Name, $r.Cost, $r.Content); Color = 'White'; Tag = $tag }
    }
    $items += @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
    $sel = Show-SysPilotArrowMenu -Items $items -Title 'Anbieter waehlen (anlegen)' -Footer 'Enter = Provider + Signup oeffnen, Esc = zurueck'
    if ($null -eq $sel) { return }
    if ($sel -like 'add:*') {
        $name = $sel.Substring(4)
        $src = $cat | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        if ($src -and $src.Signup) { Start-Process $src.Signup }
        if (Confirm-SysPilot "Provider '$name' anlegen? (Key danach in Provider-Details)") {
            $cfg = Read-SysPilotAiAssistConfig
            $exists = @($cfg.Providers | Where-Object { $_.BaseUrl -eq $src.BaseUrl }).Count -gt 0
            if (-not $exists) {
                $cfg.Providers = @($cfg.Providers) + @([pscustomobject]@{ Name=$src.Name; BaseUrl=$src.BaseUrl; Model=$src.Model; Kind='cloud'; Enabled=$true; ApiKeyCipher='' })
                Write-SysPilotAiAssistConfig $cfg
                Write-Host "  $name angelegt." -ForegroundColor Green
            } else { Write-Host "  Bereits konfiguriert." -ForegroundColor DarkGray }
        }
    }
}

# ==================== KI-News & Provider-Intel-Kuration ====================
# Herbert kuratiert die Anbieter-Metadaten (Kosten/Content) regelmaessig
# neu - Basis = kuratierte Tabelle in Get-SysPilotAiProviderIntel,
# Overlay = Herbert-geschriebene Aktualisierungen (JSON, nicht Code).
# Zusaetzlich: News-Digest aus Reddit/HN/HF-Blog/arXiv + YouTube-Suche.

function Get-SysPilotAiIntelOverlayPath {
    $dir = Join-Path $env:LOCALAPPDATA 'SysPilot'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    return (Join-Path $dir 'ai-intel-extra.json')
}

function Get-SysPilotAiIntelExtra {
    <# Herbert-Kurations-Overlay: Array von @{Name;Cost;Content;Note;Checked;Source}. #>
    $p = Get-SysPilotAiIntelOverlayPath
    if (-not (Test-Path $p)) { return @() }
    try { return @(Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return @() }
}

function Save-SysPilotAiIntelExtra {
    param([Parameter(Mandatory)][object[]]$Entries)
    $p = Get-SysPilotAiIntelOverlayPath
    $json = ($Entries | ConvertTo-Json -Depth 5)
    [IO.File]::WriteAllText($p, $json, [Text.Encoding]::UTF8)
}

function Get-SysPilotAiNewsSources {
    <# Kuratierte Nachrichten-Quellen fuer den KI-Digest.
       Type: reddit-json | hn-json | rss | atom #>
    return @(
        @{ Name='r/LocalLLaMA';      Type='arctic';       Sub='LocalLLaMA';  Weight=3 },
        @{ Name='r/singularity';     Type='arctic';       Sub='singularity'; Weight=2 },
        @{ Name='Hacker News (KI)';  Type='hn-json';      Url='https://hn.algolia.com/api/v1/search?query=LLM+OR+AI+model&tags=story&hitsPerPage=20'; Weight=2 },
        @{ Name='HN (Best/Punkte)';  Type='rss';          Url='https://hnrss.org/best?q=LLM+OR+AI+model&points=30'; Weight=2 },
        @{ Name='HuggingFace Blog';  Type='rss';          Url='https://huggingface.co/blog/feed.xml'; Weight=3 },
        @{ Name='arXiv cs.CL';       Type='atom';         Url='https://export.arxiv.org/api/query?search_query=cat:cs.CL&sortBy=submittedDate&sortOrder=descending&max_results=15'; Weight=1 }
    )
}

function Get-SysPilotAiNewsDigest {
    <# Holt den News-Digest (mit Cache). Gibt normalisierte Items:
       @{Title;Url;Source;Score;Published;Weight} #>
    param([int]$MaxItems = 40, [switch]$Force, [int]$CacheHours = 6)
    $cacheFile = Join-Path $env:LOCALAPPDATA 'SysPilot\ai-news-cache.json'
    if (-not $Force -and (Test-Path $cacheFile)) {
        $age = (Get-Date) - (Get-Item $cacheFile).LastWriteTime
        if ($age.TotalHours -lt $CacheHours) {
            try { return @(Get-Content $cacheFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {}
        }
    }
    $items = @()
    $ua = @{ 'User-Agent' = 'SysPilot/0.9.5 (+https://github.com) AI-News-Digest' }
    foreach ($src in (Get-SysPilotAiNewsSources)) {
        try {
            $url = $src.Url
            if ($src.Type -eq 'arctic') {
                # Arctic Shift (Pushshift-Nachfolger): reddit.com blockiert Bot-UAs mit 403.
                # after = Unix-Timestamp vor 7 Tagen -> "top of week"-Aequivalent.
                $weekAgo = [DateTimeOffset]::UtcNow.AddDays(-7).ToUnixTimeSeconds()
                $url = "https://arctic-shift.photon-reddit.com/api/posts/search?subreddit=$($src.Sub)&limit=100&sort=desc&after=$weekAgo"
            }
            $resp = $null
            for ($try = 0; $try -lt 2 -and -not $resp; $try++) {
                try { $resp = Invoke-WebRequest -Uri $url -Headers $ua -TimeoutSec 40 -UseBasicParsing -ErrorAction Stop }
                catch { if ($try -eq 1) { throw }; Start-Sleep -Seconds 2 }
            }
            $body = $resp.Content
            if ($src.Type -eq 'arctic') {
                $j = $body | ConvertFrom-Json
                $posts = if ($j.data) { @($j.data) } elseif ($j.posts) { @($j.posts) } else { @($j) }
                foreach ($p in $posts) {
                    if (-not $p.title) { continue }
                    $perma = [string]$p.permalink
                    $u = if ($perma -and $perma -notmatch '^https?://') { 'https://www.reddit.com' + $perma } elseif ($perma) { $perma } else { [string]$p.url }
                    $pub = $null; try { $pub = [DateTimeOffset]::FromUnixTimeSeconds([int64]$p.created_utc).LocalDateTime } catch {}
                    # Score + Kommentare als Popularitaets-Mix
                    $sc = ([int]$p.score) + ([int]$p.num_comments / 10)
                    $items += [pscustomobject]@{ Title=[string]$p.title; Url=$u; Source=$src.Name; Score=[int][math]::Round($sc); Published=$pub; Weight=$src.Weight }
                }
            } elseif ($src.Type -eq 'reddit-json') {
                $j = $body | ConvertFrom-Json
                foreach ($c in @($j.data.children)) {
                    $d = $c.data
                    $items += [pscustomobject]@{ Title=[string]$d.title; Url=[string]('https://www.reddit.com' + $d.permalink); Source=$src.Name; Score=[int]$d.score; Published=[DateTimeOffset]::FromUnixTimeSeconds([int64]$d.created_utc).LocalDateTime; Weight=$src.Weight }
                }
            } elseif ($src.Type -eq 'hn-json') {
                $j = $body | ConvertFrom-Json
                foreach ($h in @($j.hits)) {
                    if (-not $h.url) { continue }
                    $items += [pscustomobject]@{ Title=[string]$h.title; Url=[string]$h.url; Source=$src.Name; Score=[int]$h.points; Published=([DateTimeOffset]::Parse([string]$h.created_at)).LocalDateTime; Weight=$src.Weight }
                }
            } elseif ($src.Type -eq 'rss') {
                # Nur die ersten ~40 Items parsen (HF-Feed hat ~900 Archiv-Eintraege)
                foreach ($m in ([regex]::Matches($body, '(?s)<item>(.*?)</item>') | Select-Object -First 40)) {
                    $b = $m.Groups[1].Value
                    $t = [regex]::Match($b, '<title>(.*?)</title>').Groups[1].Value
                    $l = [regex]::Match($b, '<link>(.*?)</link>').Groups[1].Value
                    $dt = [regex]::Match($b, '<pubDate>(.*?)</pubDate>').Groups[1].Value
                    if ($t -and $l) {
                        $pub = $null; try { $pub = [DateTime]::Parse($dt) } catch {}
                        if ($pub -and $pub -lt (Get-Date).AddDays(-21)) { continue }
                        $clean = { param($s) ([System.Net.WebUtility]::HtmlDecode(([string]$s -replace '<!\[CDATA\[(.*?)\]\]>', '$1').Trim())) }
                        $items += [pscustomobject]@{ Title=& $clean $t; Url=(& $clean $l); Source=$src.Name; Score=0; Published=$pub; Weight=$src.Weight }
                    }
                }
            } elseif ($src.Type -eq 'atom') {
                foreach ($m in ([regex]::Matches($body, '(?s)<entry>(.*?)</entry>') | Select-Object -First 30)) {
                    $b = $m.Groups[1].Value
                    $t = [regex]::Match($b, '<title[^>]*>(.*?)</title>').Groups[1].Value
                    $l = [regex]::Match($b, '<link[^>]*href="([^"]+)"').Groups[1].Value
                    $dt = [regex]::Match($b, '<published>(.*?)</published>').Groups[1].Value
                    if ($t -and $l) {
                        $pub = $null; try { $pub = [DateTime]::Parse($dt) } catch {}
                        if ($pub -and $pub -lt (Get-Date).AddDays(-30)) { continue }
                        $items += [pscustomobject]@{ Title=($t -replace '\s+',' ').Trim(); Url=$l.Trim(); Source=$src.Name; Score=0; Published=$pub; Weight=$src.Weight }
                    }
                }
            }
        } catch { Write-SysPilotDebug "News-Quelle $($src.Name) fehlgeschlagen: $($_.Exception.Message)" }
    }
    # Dedupe nach URL + Title-Ahnlichkeit, sortieren nach Weight*Score + Aktualitaet
    $seen = @{}
    $uniq = @()
    foreach ($i in ($items | Sort-Object @{e={$_.Weight * [math]::Max($_.Score,1)}}, @{e={$_.Published}} -Descending)) {
        $k = ($i.Url).ToLower().TrimEnd('/')
        if (-not $k) { $k = $i.Title.ToLower() }
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true
        $uniq += $i
    }
    # Round-Robin ueber die Quellen (jede Quelle bereits rank-sortiert):
    # garantiert dass ALLE aktiven Quellen im Digest vertreten sind,
    # Reddit-Scores wuerden RSS/Atom sonst komplett verdrängen.
    $buckets = @{}
    foreach ($i in $uniq) {
        $s = [string]$i.Source
        if (-not $buckets.ContainsKey($s)) { $buckets[$s] = [System.Collections.Generic.List[object]]::new() }
        [void]$buckets[$s].Add($i)
    }
    $uniq = @()
    $guard = 0
    while ($uniq.Count -lt $MaxItems -and $guard -lt 500) {
        $guard++
        $added = $false
        foreach ($k in @($buckets.Keys)) {
            if ($buckets[$k].Count -gt 0) {
                $uniq += $buckets[$k][0]
                $buckets[$k].RemoveAt(0)
                $added = $true
                if ($uniq.Count -ge $MaxItems) { break }
            }
        }
        if (-not $added) { break }
    }
    try { $uniq | ConvertTo-Json -Depth 4 | Set-Content -Path $cacheFile -Encoding UTF8 } catch {}
    Save-SysPilotAutoFixStamp -Name 'ainews'
    return $uniq
}

function Get-SysPilotAiYoutubeSearch {
    <# YouTube-Suche via yt-dlp (flat, kein Download). #>
    param([Parameter(Mandatory)][string]$Query, [int]$Limit = 5)
    $ytdlp = Get-SysPilotYtDlpPath
    if (-not $ytdlp) { return @() }
    try {
        # -J = single-json des flachen Playlists (schnell, kein Video-Metadata-Fetch)
        $raw = & $ytdlp "ytsearch$Limit`:$Query" --flat-playlist -J --no-warnings 2>$null
        $j = $raw | ConvertFrom-Json
        $res = @()
        foreach ($e in @($j.entries)) {
            if (-not $e.title) { continue }
            $u = [string]$e.url
            if (-not $u -and $e.id) { $u = "https://www.youtube.com/watch?v=$($e.id)" }
            $dur = $e.duration
            if ($dur -is [string]) { try { $dur = [int]$dur } catch { $dur = $null } }
            $res += [pscustomobject]@{ Title=[string]$e.title; Url=$u; Duration=$dur }
        }
        return $res
    } catch { return @() }
}

function Show-SysPilotAiNewsItem {
    <# Einzelne NewsAktionen: oeffnen, YouTube, Herbert-Zusammenfassung. #>
    param([Parameter(Mandatory)]$Item)
    Write-Host "`n  --- $($Item.Title) ---" -ForegroundColor Cyan
    Write-Host "  $($Item.Url)" -ForegroundColor DarkGray
    Write-Host "  Quelle: $($Item.Source) | Score: $($Item.Score) | $($Item.Published)" -ForegroundColor DarkGray
    $acts = @(
        @{ Label='Link oeffnen'; Color='Cyan'; Tag='open' },
        @{ Label='YouTube-Suche (gleiche Thematik)'; Color='Red'; Tag='yt' },
        @{ Label='Herbert: Artikel zusammenfassen'; Color='Green'; Tag='sum' },
        @{ Label='Zurueck'; Color='DarkGray'; Tag='back' }
    )
    $a = Show-SysPilotArrowMenu -Items $acts -Title 'News-Aktion' -Footer 'Enter = Aktion'
    if ($null -eq $a -or $a.Tag -eq 'back') { return }
    switch ($a.Tag) {
        'open' { Start-Process $Item.Url }
        'yt' {
            $q = ($Item.Title -replace '[^\w\s]','').Substring(0, [Math]::Min(80, $Item.Title.Length))
            $vids = @(Get-SysPilotAiYoutubeSearch -Query $q -Limit 5)
            if ($vids.Count -eq 0) { Write-Host '  yt-dlp nicht verfuegbar oder keine Treffer.' -ForegroundColor Yellow }
            else {
                $vItems = @($vids | ForEach-Object { @{ Label="$(if($_.Duration){"[$($_.Duration)s] "}else{''})$($_.Title)"; Color='Red'; Tag=$_.Url } })
                $vItems += @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
                $v = Show-SysPilotArrowMenu -Items $vItems -Title "YouTube: $q" -Footer 'Enter = Video oeffnen'
                if ($v) { Start-Process $v }
            }
        }
        'sum' {
            try {
                $page = Invoke-WebRequest -Uri $Item.Url -Headers @{ 'User-Agent'='Mozilla/5.0 SysPilot' } -TimeoutSec 20 -UseBasicParsing -ErrorAction Stop
                $txt = ($page.Content -replace '(?s)<script.*?</script>','' -replace '(?s)<style.*?</style>','' -replace '<[^>]+>',' ' -replace '\s+',' ').Trim()
                $txt = $txt.Substring(0, [Math]::Min(6000, $txt.Length))
                $pr = "Fasse diesen Artikel in 4-6 Stichpunkten zusammen (Deutsch, knapp):`n`n$txt"
                $r = Invoke-SysPilotAiChat -Prompt $pr -System 'Du bist ein Nachrichten-Zusammenfasser. Antworte nur mit den Stichpunkten.' -MaxTokens 500 -TimeoutSec 90
                if ($r.Ok) { Write-Host "`n  [$($r.Provider)/$($r.Model)]`n  $($r.Text)`n" -ForegroundColor White }
                else { Write-Host "  KI nicht verfuegbar: $($r.Error)" -ForegroundColor Yellow }
            } catch { Write-Host "  Seite nicht lesbar: $($_.Exception.Message)" -ForegroundColor Yellow }
            Read-SysPilotChoice 'Enter = weiter' | Out-Null
        }
    }
}

function Show-SysPilotAiNewsDigest {
    <# News-Digest-Menue: Quellen, Top-Meldungen, Aktionen. #>
    while ($true) {
        Write-Host '  Lade News-Quellen ...' -ForegroundColor Cyan
        $items = @(Get-SysPilotAiNewsDigest -MaxItems 50)
        Write-Host "  $($items.Count) Meldungen (Cache 6h, --Force fuer neu)" -ForegroundColor DarkGray
        $menu = @()
        foreach ($i in ($items | Select-Object -First 40)) {
            $age = if ($i.Published) { "{0:dd.MM HH:mm}" -f $i.Published } else { '????' }
            $menu += @{ Label=("{0} [{1}] {2}  ({3})" -f $age, $i.Source, $i.Title.Substring(0,[Math]::Min(70,$i.Title.Length)), $i.Score); Color='White'; Tag=$i }
        }
        $menu += @{ Label='---'; Color='DarkGray'; Tag=$null }
        $menu += @{ Label='[F] Neu laden (Cache ignorieren)'; Color='Cyan'; Tag='force' }
        $menu += @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
        $sel = Show-SysPilotArrowMenu -Items $menu -Title 'KI-News Digest (Reddit/HN/HF-Blog/arXiv)' -Footer 'Enter = Aktion, Esc = zurueck'
        if ($null -eq $sel) { return }
        if ($sel -eq 'force') { [void](Get-SysPilotAiNewsDigest -Force -MaxItems 50); continue }
        if ($sel -is [pscustomobject] -and $sel.Title) { Show-SysPilotAiNewsItem -Item $sel }
    }
}

function Invoke-SysPilotAiIntelCurate {
    <# Herbert-Kuration: aktuelle Intel-Tabelle + News-Headlines an die KI,
       Antwort als JSON-Overlay in ai-intel-extra.json schreiben. #>
    Write-Host '  Baue Kurations-Prompt ...' -ForegroundColor Cyan
    # Aktuelle Tabelle (Basis + Overlay)
    $known = @()
    foreach ($t in @('Ollama','LM Studio','Venice.ai','OpenRouter','Groq','Gemini','Chutes','Featherless','Kaggle','DeepSeek','Mancer','ArliAI','HuggingFace')) {
        $i = Get-SysPilotAiProviderIntel -Name $t
        $known += "- $t : $($i.Cost) / $($i.Content) / $($i.Note)"
    }
    # Top-News als Kontext
    $news = @(Get-SysPilotAiNewsDigest -MaxItems 15) | ForEach-Object { "- [$($_.Source)] $($_.Title)" }
    $prompt = @"
Du kuratierst KI-Anbieter-Metadaten fuer SysPilot. Antworte NUR mit einem JSON-Array (kein Text davor/danach).

Schema pro Eintrag: {"Name":"...","Cost":"lokal|kostenlos|freemium|guenstig|gemischt|mittel|teuer|abo","Content":"unzensiert|abliterated|heretic|gemischt|zensiert","Note":"1 Satz deutsch","Checked":"yyyy-MM-dd"}

Aufgabe: (1) Bekannte Anbieter auf fehlende/wertlose Eintraege pruefen, (2) NEUE relevante Anbieter ergaenzen (besonders: unzensierte/abliterated-Quellen, guenstige Free-Tiers, neue Router). Nur Eintraege mit Name, der zu einem Provider passt. Kosten/Content ehrlich einschaetzen - lieber 'unbekannt' als raten.

Bekannte Basis:
$($known -join "`n")

Aktuelle News (Kontext):
$($news -join "`n")
"@
    $r = Invoke-SysPilotAiChat -Prompt $prompt -System 'Du bist ein Dat curator. Antworte NUR mit validerm JSON-Array.' -MaxTokens 2000 -TimeoutSec 120
    if (-not $r.Ok) { Write-Host "  KI nicht verfuegbar: $($r.Error)" -ForegroundColor Red; return }
    $txt = $r.Text
    $json = $txt
    $m = [regex]::Match($txt, '(?s)(\[.*\])')
    if ($m.Success) { $json = $m.Groups[1].Value }
    try {
        $new = @($json | ConvertFrom-Json)
    } catch { Write-Host "  KI-Antwort kein gueltiges JSON - uebersprungen." -ForegroundColor Yellow; return }
    # Mit bestehendem Overlay mergen (Name-Match gewinnt)
    $overlay = @(Get-SysPilotAiIntelExtra)
    $map = @{}
    foreach ($e in $overlay) { $map[[string]$e.Name] = $e }
    $added = 0; $updated = 0
    foreach ($n in $new) {
        $rec = [pscustomobject]@{
            Name=[string]$n.Name; Cost=[string]$n.Cost; Content=[string]$n.Content
            Note=[string]$n.Note; Checked=[string]$n.Checked; Source='herbert-ki'
        }
        if ($map.ContainsKey($rec.Name)) { $updated++ } else { $added++ }
        $map[$rec.Name] = $rec
    }
    Save-SysPilotAiIntelExtra -Entries @($map.Values)
    Write-Host "  Kuration fertig: $added neu, $updated aktualisiert (Overlay: $(Get-SysPilotAiIntelOverlayPath))" -ForegroundColor Green
    Write-Host "  Quelle: $($r.Provider)/$($r.Model)" -ForegroundColor DarkGray
}

function Show-SysPilotAiNewsIntelMenu {
    <# Untermenue: News-Digest, Intel-Kuration, Overlay-Ansicht. #>
    while ($true) {
        $items = @(
            @{ Label='[N] News-Digest (Reddit, HN, HF-Blog, arXiv)'; Color='Cyan'; Tag='news' },
            @{ Label='[K] Herbert: Anbieter-Intel kuratieren (KI aktualisiert Overlay)'; Color='Green'; Tag='curate' },
            @{ Label='[O] Herbert-Overlay anzeigen (kuratierte Aktualisierungen)'; Color='Yellow'; Tag='overlay' },
            @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
        )
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'KI-News & Intel-Kurare' -Footer 'Enter = Aktion, Esc = zurueck'
        if ($null -eq $sel) { return }
        switch ($sel) {
            'news'    { Show-SysPilotAiNewsDigest }
            'curate'  { Invoke-SysPilotAiIntelCurate; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
            'overlay' {
                $ex = @(Get-SysPilotAiIntelExtra)
                if ($ex.Count -eq 0) { Write-Host '  Overlay ist leer - erst [K] Kuration laufen lassen.' -ForegroundColor DarkGray }
                else {
                    foreach ($e in $ex) { Write-Host ("  {0,-28} {1,-10} {2,-12} {3}  ({4})" -f $e.Name, $e.Cost, $e.Content, $e.Note, $e.Checked) -ForegroundColor White }
                }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
        }
    }
}

function Get-SysPilotAiProviderCatalog {
    <# Der Provider-Katalog: kuratierte Eintraege (bekannte Free-Tiers,
       Router, guenstige Anbieter) + AUTOMATISCH Eintraege aus den
       Key-Textdateien (Dokumente\api keys u.a.) - BaseUrl, Key und
       Signup-Link werden aus den Dateien extrahiert.
       Jeder Eintrag: Name, BaseUrl, Model, Signup, Note, Kind,
       ApiKey (falls in Datei), KeyPath, HasKey, Configured, Source. #>
    param([switch]$NoKeyFiles, [int]$MaxKeyFileEntries = 80)
    $cat = @()
    # --- Kuratiert: bewusste Auswahl (Free-Tiers + guenstige Router) ---
    $curated = @(
        @{ Name='OpenRouter';            BaseUrl='https://openrouter.ai/api/v1';                    Model='';                 Signup='https://openrouter.ai/keys';              Note='Viele Provider, viele :free-Modelle - ein Key fuer alles' },
        @{ Name='Google Gemini (AI Studio)'; BaseUrl='https://generativelanguage.googleapis.com/v1beta/openai'; Model='gemini-2.5-flash'; Signup='https://aistudio.google.com/apikey';      Note='Grosszuegiges Freikontingent' },
        @{ Name='Groq';                  BaseUrl='https://api.groq.com/openai/v1';                   Model='llama-3.3-70b-versatile'; Signup='https://console.groq.com/keys';       Note='Sehr schnell, Freikontingent' },
        @{ Name='GitHub Models';         BaseUrl='https://models.github.ai/inference';               Model='gpt-4o-mini';        Signup='https://github.com/marketplace/models';   Note='GPT-Modelle mit GitHub-Account/PAT' },
        @{ Name='Mistral';               BaseUrl='https://api.mistral.ai/v1';                         Model='mistral-small-latest'; Signup='https://console.mistral.ai/api-keys';     Note='Freikontingent vorhanden' },
        @{ Name='Cerebras';              BaseUrl='https://api.cerebras.ai/v1';                        Model='llama-3.3-70b';      Signup='https://cloud.cerebras.ai/';              Note='Extrem schnell, Freikontingent' },
        @{ Name='DeepSeek';              BaseUrl='https://api.deepseek.com/v1';                      Model='deepseek-chat';      Signup='https://platform.deepseek.com/api_keys';  Note='Guenig, stark' },
        @{ Name='SiliconFlow';           BaseUrl='https://api.siliconflow.com/v1';                   Model='';                   Signup='https://cloud.siliconflow.com/account/ak'; Note='Viele Modelle guenstig/frei' },
        @{ Name='Novita AI';             BaseUrl='https://api.novita.ai/openai';                     Model='';                   Signup='https://novita.ai/settings/key-management'; Note='Serverless GPU + LLM-API' },
        @{ Name='Hyperbolic';            BaseUrl='https://api.hyperbolic.xyz/v1';                    Model='';                   Signup='https://app.hyperbolic.xyz/settings';      Note='Guenstige Inference' },
        @{ Name='Kimi (Moonshot)';       BaseUrl='https://api.moonshot.ai/v1';                        Model='moonshot-v1-8k';     Signup='https://platform.moonshot.ai/console/api-keys'; Note='Chinesische Frontier-Modelle' },
        @{ Name='Z.ai (Zhipu GLM)';      BaseUrl='https://api.z.ai/api/paas/v4';                      Model='glm-4.5-flash';      Signup='https://z.ai/manage-apikey/apikey-list';    Note='GLM-Modelle, guenstiger Flash-Tier' },
        @{ Name='Venice.ai';             BaseUrl='https://api.venice.ai/api/v1';                      Model='';                   Signup='https://venice.ai/settings/api';           Note='Unzensierte/abliterated Modelle, OpenAI-kompatibel' },
        @{ Name='Featherless';           BaseUrl='https://api.featherless.ai/v1';                    Model='';                   Signup='https://featherless.ai/';                    Note='Abo - unzensierte/abliterated HF-Modelle' },
        @{ Name='ArliAI';                BaseUrl='https://api.arliai.com/v1';                        Model='';                   Signup='https://www.arliai.com/';                    Note='Abo - unzensierte Chat-Modelle' },
        @{ Name='Mancer';                BaseUrl='https://api.mancer.tech/v1';                       Model='';                   Signup='https://mancer.tech/';                       Note='Unzensierte Modelle, guenstig' },
        @{ Name='Numes';                BaseUrl='https://api.numes.ai/api/v1';                      Model='';                   Signup='https://numes.ai/';                           Note='OpenAI-kompatibler Gateway, :free-Varianten, Routing-Steuerung' },
        @{ Name='Kaggle Models';         BaseUrl='https://www.kaggle.com/api/v1';                     Model='';                   Signup='https://www.kaggle.com/settings/api';      Note='Kein Chat-Endpunkt - Models-API + 30h/Woche Gratis-GPU fuer eigene Modelle' },
        @{ Name='SambaNova';             BaseUrl='https://api.sambanova.ai/v1';                      Model='';                   Signup='https://cloud.sambanova.ai/apis';          Note='Kostenloses Kontingent' },
        @{ Name='Chutes.ai';             BaseUrl='https://llm.chutes.ai/v1';                          Model='';                   Signup='https://chutes.ai/app/settings';           Note='Dezentral, guenstig' },
        @{ Name='Requesty';              BaseUrl='https://router.requesty.ai/v1';                    Model='';                   Signup='https://app.requesty.ai/';                  Note='Router mit Failover' },
        @{ Name='NVIDIA NIM';            BaseUrl='https://integrate.api.nvidia.com/v1';              Model='';                   Signup='https://build.nvidia.com/';                Note='Kostenloses Dev-Kontingent' },
        @{ Name='HuggingFace Router';    BaseUrl='https://router.huggingface.co/v1';                  Model='';                   Signup='https://huggingface.co/settings/tokens';   Note='Vielfach-Provider-Aggregator' },
        @{ Name='Ollama Cloud';          BaseUrl='https://ollama.com/v1';                             Model='';                   Signup='https://ollama.com/settings/keys';         Note='Gehostete Ollama-Modelle' },
        @{ Name='OpenCode Zen';          BaseUrl='https://opencode.ai/zen/v1';                        Model='';                   Signup='https://opencode.ai/zen';                   Note='Kostenlose Zen-Modelle' },
        @{ Name='Together AI';           BaseUrl='https://api.together.xyz/v1';                       Model='';                   Signup='https://api.together.ai/settings/api-keys'; Note='Offene Modellvielfalt' },
        @{ Name='Fireworks AI';          BaseUrl='https://api.fireworks.ai/inference/v1';             Model='';                   Signup='https://fireworks.ai/account/api-keys';    Note='Schnelle Inference' },
        @{ Name='Cohere (compat)';       BaseUrl='https://api.cohere.ai/compatibility/v1';            Model='command-r-plus';    Signup='https://dashboard.cohere.com/api-keys';     Note='OpenAI-kompatibler Endpoint' },
        # --- Keyless / anonym nutzbar (aus FreeLLMAPI-Analyse portiert) ---
        @{ Name='Kilo Gateway';          BaseUrl='https://api.kilo.ai/api/gateway/v1';               Model='';                   Signup='';                                             Note='KEYLESS - kein Account noetig, OpenAI-kompatibel' },
        @{ Name='OVH AI Endpoints';      BaseUrl='https://oai.endpoints.kepler.ai.cloud.ovh.net/v1'; Model='';                   Signup='';                                             Note='KEYLESS - anonym ~2 req/min, OpenAI-kompatibel' },
        # --- Weitere Free-Tier-Aggregatoren (FreeLLMAPI-Katalog) ---
        @{ Name='LLM7';                  BaseUrl='https://api.llm7.io/v1';                            Model='';                   Signup='https://api.llm7.io/';                        Note='Kostenlose Modelle, Key optional' },
        @{ Name='Agnes AI';              BaseUrl='https://apihub.agnes-ai.com/v1';                   Model='';                   Signup='https://agnes-ai.com/';                       Note='Kostenlose Chat-Modelle' },
        @{ Name='Reka';                  BaseUrl='https://api.reka.ai/v1';                           Model='';                   Signup='https://platform.reka.ai/';                   Note='Reka-Modelle, Freitier' },
        @{ Name='Routeway';              BaseUrl='https://api.routeway.ai/v1';                        Model='';                   Signup='https://routeway.ai/';                        Note='Router mit Freimodellen' },
        @{ Name='BazaarLink';            BaseUrl='https://bazaarlink.ai/api/v1';                     Model='';                   Signup='https://bazaarlink.ai/';                      Note='Aggregator, guenstige Modelle' },
        @{ Name='AINative Studio';       BaseUrl='https://api.ainative.studio/api/v1';                Model='';                   Signup='https://ainative.studio/';                    Note='Freemium-Modelle' },
        @{ Name='Aion Labs';             BaseUrl='https://api.aionlabs.ai/v1';                        Model='';                   Signup='https://www.aionlabs.ai/';                     Note='Kostenlose Inference-Modelle' },
        @{ Name='NaraRouter';            BaseUrl='https://router.bynara.id/v1';                       Model='';                   Signup='https://bynara.id/';                           Note='Kostenloser Router' },
        @{ Name='SEA-LION';              BaseUrl='https://api.sea-lion.ai/v1';                        Model='';                   Signup='https://sea-lion.ai/';                         Note='AIs SEA-LION Modelle' },
        @{ Name='OrcaRouter';            BaseUrl='https://api.orcarouter.ai/v1';                      Model='';                   Signup='https://orcarouter.ai/';                      Note='Router, Freimodelle' },
        @{ Name='UnoRouter';             BaseUrl='https://api.unorouter.com/v1';                      Model='';                   Signup='https://unorouter.com/';                      Note='Router, guenstig' },
        @{ Name='xKiro';                 BaseUrl='https://api.xkiro.com/v1';                           Model='';                   Signup='https://xkiro.com/';                           Note='Freemium-Gateway' },
        @{ Name='LongCat';               BaseUrl='https://api.longcat.chat/openai/v1';                Model='';                   Signup='https://longcat.chat/';                        Note='Meituan LongCat Modelle' },
        @{ Name='iFlytek Spark';         BaseUrl='https://spark-api-open.xf-yun.com/v1';              Model='';                   Signup='https://xinghuo.xfyun.cn/';                   Note='Spark-Desk OpenAPI, Freikontingent' },
        @{ Name='Volcengine Ark';        BaseUrl='https://ark.cn-beijing.volces.com/api/v3';          Model='';                   Signup='https://console.volcengine.com/ark';           Note='Doubao/Seed Modelle, guenstig' },
        @{ Name='cheapllm';              BaseUrl='https://cheapllm.shop/v1';                          Model='';                   Signup='https://cheapllm.shop/';                      Note='GuellsterAggregator' },
        @{ Name='AnyAPI';                BaseUrl='https://api.anyapi.ai/v1';                          Model='';                   Signup='https://anyapi.ai/';                           Note='Multi-Provider-Gateway' },
        @{ Name='PowerTokens';           BaseUrl='https://api.powertokens.ai/v1';                     Model='';                   Signup='https://powertokens.ai/';                     Note='Token-basiert, guenstig' },
        @{ Name='AMD Radeon Cloud';      BaseUrl='https://developer.amd.com.cn/radeon/api/v1';         Model='';                   Signup='https://developer.amd.com.cn/';                Note='AMD-hosted Inference' },
        @{ Name='B.AI';                  BaseUrl='https://api.b.ai/v1';                               Model='';                   Signup='https://b.ai/';                                Note='Aggregator mit Freimodellen' },
        # --- BEZAHLT / Pay-per-Token (OmniRoute-Registry, OpenAI-kompatibel) ---
        @{ Name='OpenAI';                BaseUrl='https://api.openai.com/v1';                         Model='gpt-4o-mini';        Signup='https://platform.openai.com/api-keys';        Note='Frontier-Modelle, teuer' },
        @{ Name='xAI (Grok)';            BaseUrl='https://api.x.ai/v1';                               Model='';                   Signup='https://console.x.ai/';                       Note='Grok-Modelle, guenstig-teuer' },
        @{ Name='Anthropic (compat)';    BaseUrl='https://api.anthropic.com/v1';                      Model='claude-sonnet-4-5';  Signup='https://console.anthropic.com/';              Note='Claude - Achtung: nativer Endpoint, SysPilot nutzt OpenAI-Format (Fallback/Fehler moeglich)' },
        @{ Name='DeepInfra';             BaseUrl='https://api.deepinfra.com/v1/openai';               Model='';                   Signup='https://deepinfra.com/dash/api_keys';         Note='Serverless, viele guenstige Modelle' },
        @{ Name='Baseten';               BaseUrl='https://inference.baseten.co/v1';                   Model='';                   Signup='https://app.baseten.co/settings/api_keys';    Note='Dedizierte/trained Modelle' },
        @{ Name='Nebius Token Factory';  BaseUrl='https://api.tokenfactory.nebius.com/v1';            Model='';                   Signup='https://tokenfactory.nebius.com/';             Note='Guinige Frontier-Inference' },
        @{ Name='Lambda Chat';           BaseUrl='https://api.lambda.ai/v1';                          Model='';                   Signup='https://cloud.lambda.ai/api-keys';             Note='GPU-Cloud + Chat-API' },
        @{ Name='Cerebrium';             BaseUrl='https://api.cerebrium.ai/v4';                        Model='';                   Signup='https://dashboard.cerebrium.ai/';              Note='Serverless Inference' },
        @{ Name='Replicate';             BaseUrl='https://api.replicate.com/v1';                      Model='';                   Signup='https://replicate.com/account/api-tokens';     Note='Offene Modelle, pay-per-second' },
        @{ Name='Scaleway Generative';   BaseUrl='https://api.scaleway.ai/v1';                         Model='';                   Signup='https://console.scaleway.com/iam/api-keys';    Note='EU-Cloud, guenstig' },
        @{ Name='Hetzner Inference';     BaseUrl='https://inference.hetzner.com/api/v1';               Model='';                   Signup='https://console.hetzner.cloud/';               Note='EU, sehr guenstig' },
        @{ Name='AI21 Studio';           BaseUrl='https://api.ai21.com/studio/v1';                     Model='';                   Signup='https://studio.ai21.com/';                     Note='Jamba-Modelle' },
        @{ Name='Upstage Solar';         BaseUrl='https://api.upstage.ai/v1';                          Model='solar-pro';          Signup='https://console.upstage.ai/';                  Note='Koreanische Solar-Modelle' },
        @{ Name='Writer';                BaseUrl='https://api.writer.com/v1';                          Model='';                   Signup='https://dev.writer.com/';                      Note='Palmyra-Enterprise-Modelle' },
        @{ Name='Qwen Cloud (DashScope)';BaseUrl='https://dashscope-intl.aliyuncs.com/compatible-mode/v1'; Model='';            Signup='https://modelstudio.console.alibabacloud.com/';   Note='Alibaba Qwen, guenstig' },
        @{ Name='MiniMax';               BaseUrl='https://api.minimax.io/v1';                          Model='';                   Signup='https://platform.minimax.io/';                 Note='MiniMax-M*-Modelle' },
        @{ Name='StepFun';               BaseUrl='https://api.stepfun.com/v1';                         Model='';                   Signup='https://platform.stepfun.com/';                Note='Step-Modelle' },
        @{ Name='Synthetic.new';         BaseUrl='https://api.synthetic.new/openai/v1';                Model='';                   Signup='https://synthetic.new/';                       Note='Guinige GPT-Modelle' },
        @{ Name='Morph';                 BaseUrl='https://api.morphllm.com/v1';                        Model='';                   Signup='https://morphllm.com/';                        Note='Fast-Apply/Coding-Modelle' },
        @{ Name='Perplexity Sonar';      BaseUrl='https://api.perplexity.ai';                          Model='sonar';              Signup='https://www.perplexity.ai/settings/api';        Note='Search-augmentierte Antworten' },
        @{ Name='LlamaGate';             BaseUrl='https://llamagate.ai/v1';                            Model='';                   Signup='https://llamagate.ai/';                        Note='Offene Modelle, guenstig' },
        @{ Name='Modal';                 BaseUrl='https://api.modal.ai/v1';                             Model='';                   Signup='https://modal.com/';                            Note='Serverless GPU + LLMs' },
        @{ Name='Nscale Inference';      BaseUrl='https://inference.api.nscale.com/v1';                Model='';                   Signup='https://nscale.com/';                          Note='EU-Inference' },
        @{ Name='Nube.sh';               BaseUrl='https://ai.nube.sh/api/v1';                          Model='';                   Signup='https://nube.sh/';                             Note='OpenAI-kompatibler Endpoint' },
        @{ Name='OpenAdapter';           BaseUrl='https://api.openadapter.in/v1';                      Model='';                   Signup='https://openadapter.in/';                      Note='Multi-Provider-Aggregator' },
        @{ Name='ZenMux';                BaseUrl='https://zenmux.ai/api/v1';                           Model='';                   Signup='https://zenmux.ai/';                           Note='Aggregator, guenstig' },
        @{ Name='DigitalOcean GenAI';    BaseUrl='https://inference.do-ai.run/v1';                     Model='';                   Signup='https://cloud.digitalocean.com/';              Note='Managed Inference' },
        @{ Name='BytePlus Ark';          BaseUrl='https://ark.ap-southeast.bytepluses.com/api/v3';     Model='';                   Signup='https://www.byteplus.com/';                    Note='Doubao/Seed, guenstig' },
        @{ Name='Baichuan';              BaseUrl='https://api.baichuan-ai.com/v1';                     Model='';                   Signup='https://platform.baichuan-ai.com/';            Note='Chinesische Modelle' },
        @{ Name='Yi (01.AI LingYi)';     BaseUrl='https://api.lingyiwanwu.com/v1';                     Model='';                   Signup='https://platform.lingyiwanwu.com/';            Note='Yi-Modelle' },
        @{ Name='InternLM';              BaseUrl='https://chat.intern-ai.org.cn/api/v1';               Model='';                   Signup='https://internlm-chat.intern-ai.org.cn/';      Note='InternLM-Modelle' },
        @{ Name='SenseNova (SenseTime)'; BaseUrl='https://token.sensenova.cn/v1';                       Model='';                   Signup='https://platform.sensenova.cn/';               Note='Chinesische Modelle' },
        @{ Name='Tencent Hunyuan';       BaseUrl='https://api.hunyuan.cloud.tencent.com/v1';           Model='';                   Signup='https://console.cloud.tencent.com/hunyuan';    Note='Hunyuan-Modelle' },
        @{ Name='Baidu Qianfan';         BaseUrl='https://qianfan.baidubce.com/v2';                    Model='';                   Signup='https://console.bce.baidu.com/qianfan';         Note='ERNIE-Modelle' },
        @{ Name='GigaChat (Sber)';       BaseUrl='https://gigachat.devices.sberbank.ru/api/v1';        Model='';                   Signup='https://developers.sber.ru/';                  Note='Russische Modelle' },
        @{ Name='Sarvam AI';             BaseUrl='https://api.sarvam.ai/v1';                            Model='sarvam-m';          Signup='https://dashboard.sarvam.ai/';                  Note='Indische Modelle' },
        @{ Name='W&B Inference';         BaseUrl='https://api.inference.wandb.ai/v1';                  Model='';                   Signup='https://wandb.ai/';                            Note='Ueber W&B-Account' },
        @{ Name='Predibase';             BaseUrl='https://serving.app.predibase.com/v1';               Model='';                   Signup='https://predibase.com/';                       Note='Fine-tuned Serving' },
        @{ Name='ModelScope';            BaseUrl='https://api-inference.modelscope.cn/v1';              Model='';                   Signup='https://modelscope.cn/';                       Note='Chinesische Modelle, teils gratis' },
        @{ Name='Cline (API)';           BaseUrl='https://api.cline.bot/api/v1';                       Model='';                   Signup='https://cline.bot/';                           Note='Cline-Provider-API' },
        @{ Name='Factory AI';            BaseUrl='https://api.factory.ai/v1';                          Model='';                   Signup='https://factory.ai/';                          Note='Droid-Coding-Modelle' },
        @{ Name='Codestral (direct)';    BaseUrl='https://codestral.mistral.ai/v1';                     Model='codestral-latest';  Signup='https://console.mistral.ai/';                  Note='Mistral-Coding-Modell, direkter Endpoint' },
        @{ Name='NanoGPT';               BaseUrl='https://nano-gpt.com/api/v1';                         Model='';                   Signup='https://nano-gpt.com/';                        Note='Guinige API, grosse Modellvielfalt' },
        @{ Name='cheaperinference';      BaseUrl='https://api.cheaperinference.com/v1';                Model='';                   Signup='https://cheaperinference.com/';                Note='GuellsterAggregator (OmniRoute/FreeLLMAPI-Team), sehr guenstig' },
        @{ Name='AI/ML API';             BaseUrl='https://api.aimlapi.com/v1';                         Model='';                   Signup='https://aimlapi.com/';                         Note='Vielfach-Provider-Aggregator, guenstig' },
        @{ Name='CrofAI';                BaseUrl='https://crof.ai/v1';                                 Model='';                   Signup='https://crof.ai/';                             Note='Offene/Unzensierte Modelle' },
        @{ Name='Typhoon (SCB10X)';      BaseUrl='https://api.opentyphoon.ai/v1';                      Model='';                   Signup='https://opentyphoon.ai/';                      Note='Thailaendische LLMs, teils gratis' },
        @{ Name='BluesMinds';            BaseUrl='https://api.bluesminds.com/v1';                      Model='';                   Signup='https://bluesminds.com/';                      Note='Unzensierte Modelle' },
        @{ Name='Grokified';             BaseUrl='https://api.grokified.com/v1';                       Model='';                   Signup='https://grokified.com/';                       Note='Guinige Grok-Modelle' },
        @{ Name='Charm Hyper';           BaseUrl='https://hyper.charm.land/v1';                        Model='';                   Signup='https://charm.land/';                          Note='Unzensierte Modelle' },
        @{ Name='FreeModel.dev';         BaseUrl='https://api.freemodel.dev/v1';                       Model='';                   Signup='https://freemodel.dev/';                      Note='Kostenlose Modelle' },
        @{ Name='FreetheAI';             BaseUrl='https://api.freetheai.org/v1';                       Model='';                   Signup='https://freetheai.org/';                       Note='Kostenlose Modelle' },
        @{ Name='FriendliAI';            BaseUrl='https://api.friendli.ai/serverless/v1';              Model='';                   Signup='https://friendli.ai/';                         Note='Serverless, guenstig' },
        @{ Name='PublicAI';              BaseUrl='https://api.publicai.co/v1';                         Model='';                   Signup='https://publicai.co/';                         Note='Offene Modelle' },
        @{ Name='DGrid';                 BaseUrl='https://api.dgrid.ai/v1';                            Model='';                   Signup='https://dgrid.ai/';                            Note='Dezentrale Modelle' },
        @{ Name='OpenVecta';             BaseUrl='https://api.openvecta.com/v1';                       Model='';                   Signup='https://openvecta.com/';                       Note='Offene Modelle' },
        @{ Name='LLM-Kiwi';              BaseUrl='https://api.llm.kiwi/v1';                             Model='';                   Signup='https://llm.kiwi/';                            Note='Guiniger Gateway' },
        @{ Name='LLMGateway.io';         BaseUrl='https://api.llmgateway.io/v1';                       Model='';                   Signup='https://llmgateway.io/';                      Note='Multi-Provider-Router' },
        @{ Name='Speka';                 BaseUrl='https://speka.me/v1';                                Model='';                   Signup='https://speka.me/';                            Note='Unzensierte Modelle' },
        @{ Name='VoidAI';                BaseUrl='https://api.voidai.app/v1';                          Model='';                   Signup='https://voidai.app/';                          Note='Unzensierte Modelle' },
        @{ Name='Uncensored.com';        BaseUrl='https://api.uncensored.com/api/v1';                  Model='';                   Signup='https://uncensored.com/';                      Note='Unzensierte Modelle' },
        @{ Name='Onomeo';                BaseUrl='https://onomeo.com/v1';                             Model='';                   Signup='https://onomeo.com/';                          Note='Offene Modelle' },
        @{ Name='Yolo-Auto';             BaseUrl='https://yolo-auto.com/v1';                           Model='';                   Signup='https://yolo-auto.com/';                       Note='Router, guenstig' },
        @{ Name='TokenReply';            BaseUrl='https://api.tokenreply.com/v1';                      Model='';                   Signup='https://tokenreply.com/';                      Note='Router, guenstig' },
        @{ Name='TokenHarbor';           BaseUrl='https://tokenharbor.ai/v1';                          Model='';                   Signup='https://tokenharbor.ai/';                      Note='Router, guenstig' },
        @{ Name='TokenMarket';           BaseUrl='https://api.tokensmarket.ai/v1';                     Model='';                   Signup='https://tokensmarket.ai/';                     Note='Router, guenstig' },
        @{ Name='OfoxAI';                BaseUrl='https://api.ofox.ai/v1';                             Model='';                   Signup='https://ofox.ai/';                             Note='Aggregator' },
        @{ Name='ZyloAI';                BaseUrl='https://api.zyloai.net/v1';                          Model='';                   Signup='https://zyloai.net/';                          Note='Router' },
        @{ Name='MNN-AI';                BaseUrl='https://api.mnnai.ru/v1';                            Model='';                   Signup='https://mnnai.ru/';                            Note='Russische Modelle' },
        @{ Name='SeekAI';                BaseUrl='https://seekai.cc/v1';                               Model='';                   Signup='https://seekai.cc/';                           Note='Freemium' },
        @{ Name='HelixMind';             BaseUrl='https://helixmind.online/v1';                        Model='';                   Signup='https://helixmind.online/';                    Note='Router' },
        @{ Name='HelyxAI';               BaseUrl='https://helyxai.space/v1';                           Model='';                   Signup='https://helyxai.space/';                       Note='Router' },
        @{ Name='Chenzk';                BaseUrl='https://chenzk.top/v1';                              Model='';                   Signup='https://chenzk.top/';                          Note='Unzensierte Modelle' },
        @{ Name='DahL Inference';        BaseUrl='https://inference.dahl.global/v1';                    Model='';                   Signup='https://dahl.global/';                         Note='Serverless, guenstig' },
        @{ Name='ByteZ';                 BaseUrl='https://api.bytez.com/models/v2/openai/v1';          Model='';                   Signup='https://bytez.com/';                           Note='OpenAI-kompatibel' },
        @{ Name='Dit.ai';                BaseUrl='https://api.dit.ai/v1';                              Model='';                   Signup='https://dit.ai/';                              Note='Router' },
        @{ Name='Unifcially';            BaseUrl='https://api.unifically.com/v1';                      Model='';                   Signup='https://unifically.com/';                      Note='Offene Modelle' },
        @{ Name='MaxAI';                 BaseUrl='https://api.maxai.me';                               Model='';                   Signup='https://maxai.me/';                            Note='Freemium' },
        @{ Name='1min.AI';               BaseUrl='https://api.1min.ai/api';                            Model='';                   Signup='https://1min.ai/';                             Note='All-in-one KI-Suite' },
        @{ Name='Nous Research';         BaseUrl='https://inference-api.nousresearch.com/v1';          Model='hermes-3-llama-3.1-405b'; Signup='https://portal.nousresearch.com/';            Note='Hermes/DisTral-Modelle' },
        @{ Name='Syntx';                 BaseUrl='https://api.syntx.ai/api/v1';                        Model='';                   Signup='https://syntx.ai/';                            Note='Router' },
        @{ Name='TwinMind';              BaseUrl='https://api2.twinmind.com/api/v3';                   Model='';                   Signup='https://twinmind.com/';                        Note='Router' },
        @{ Name='Regolo';                BaseUrl='https://api.regolo.ai/v1';                           Model='';                   Signup='https://regolo.ai/';                           Note='Router' },
        @{ Name='ParalonCloud';          BaseUrl='https://paraloncloud.com/v1';                       Model='';                   Signup='https://paraloncloud.com/';                    Note='Router' }
    )
    foreach ($c in $curated) {
        $cat += [pscustomobject]@{
            Name=$c.Name; BaseUrl=$c.BaseUrl; Model=$c.Model; Signup=$c.Signup; Note=$c.Note
            Kind=$(if ($c.BaseUrl -match 'localhost|127\.0\.0\.1') {'lokal'} else {'cloud'})
            ApiKey=''; KeyPath=''; HasKey=$false; Source='katalog'; Configured=$false
        }
    }
    # --- Automatisch: Key-Dateien (Dokumente\api keys etc.) ---
    # Ueberspringe nicht-Chat-Endpoints (TTS, Search, Bilder, ...)
    $skipRe = $script:AiNonChatUrlRe
    if (-not $NoKeyFiles) {
        $seen = @{}
        foreach ($e in $cat) { $seen[$e.BaseUrl.ToLower().TrimEnd('/')] = $true }
        $n = 0
        foreach ($f in @(Get-SysPilotAiKeyFileCandidates)) {
            if ($n -ge $MaxKeyFileEntries) { break }
            $e = Import-SysPilotAiKeyFile -Path $f
            if (-not $e -or -not $e.BaseUrl) { continue }
            $url = $e.BaseUrl.TrimEnd('/')
            # Normalisieren: Endpoint-Pfad aus Datei bereinigen
            $url = $url -replace '/chat/completions$','' -replace '/messages$','' -replace '\.+$',''
            # Mindestens /v1 anhaengen wenn Host direkt auf API zeigt
            if ($url -notmatch '/v\d|/openai|/compatibility|/inference|/paas|/api$|/zen$') {
                if ($url -match '^https?://[^/]+$') { $url = "$url/v1" }
            }
            if ($url -match $skipRe) { continue }
            $key = ($seen[$url.ToLower()])
            if ($key) { continue }
            $seen[$url.ToLower()] = $true
            # Sauberer Name aus Dateiname
            $nm = [IO.Path]::GetFileNameWithoutExtension($f) -replace '(?i)\s*api\s*key.*$','' -replace '(?i)\s*project.*$','' -replace '[.\-_]+',' ' -replace '\s+',' '
            $nm = ($nm.Trim().Substring(0, [Math]::Min(40, $nm.Trim().Length)))
            if (-not $nm) { $nm = $url }
            $host_ = ''
            try { $host_ = ([uri]$url).Host } catch {}
            $signup = $(if ($host_) { "https://$host_" } else { '' })
            # Ollama-Sonderfall: ollama.com -> /v1
            if ($host_ -eq 'ollama.com' -and $url -notmatch '/v1$') { }
            $cat += [pscustomobject]@{
                Name = "$nm (Datei)"; BaseUrl=$url; Model=$e.Model; Signup=$signup
                Note = "Aus Key-Datei: $([IO.Path]::GetFileName($f))$(if($e.ApiKey){' - Key vorhanden'}else{' - ohne Key'})"
                Kind='cloud'; ApiKey=$e.ApiKey; KeyPath=$f; HasKey=[bool]$e.ApiKey
                Source='keyfile'; Configured=$false
            }
            $n++
        }
    }
    # Configured-Flag gegen vorhandene Provider setzen
    $cfg = Read-SysPilotAiAssistConfig
    $confUrls = @{}
    foreach ($p in @($cfg.Providers)) { if ($p.BaseUrl) { $confUrls[$p.BaseUrl.ToLower().TrimEnd('/')] = $true } }
    foreach ($c in $cat) {
        if ($confUrls.ContainsKey($c.BaseUrl.ToLower().TrimEnd('/'))) { $c.Configured = $true }
        $intel = Get-SysPilotAiProviderIntel -Name $c.Name -BaseUrl $c.BaseUrl
        $c | Add-Member -NotePropertyName Cost -NotePropertyValue $intel.Cost -Force
        $c | Add-Member -NotePropertyName Content -NotePropertyValue $intel.Content -Force
        if ($intel.Note -and -not $c.Note) { $c.Note = $intel.Note }
    }
    return @($cat)
}

function Get-SysPilotAiProviders {
    <# Alle Provider: Pollinations-Free (immer, kein Key), lokale Router
       (erreichbare) + konfigurierte Cloud-Tiers.
       Gibt Liste mit Status (Enabled, Reachable, HasKey) zurueck.
       30s-Cache fuer Port-Probes (Menue-Aufrufe sind haeufig). #>
    $cfg = Read-SysPilotAiAssistConfig
    $out = @()
    # Lokale Defaults: nur wenn Port antwortet ODER User sie konfiguriert hat
    $configuredUrls = @{}
    foreach ($p in @($cfg.Providers)) { if ($p.BaseUrl) { $configuredUrls[$p.BaseUrl.ToLower()] = $true } }
    if (-not $script:_aiProbeCache) { $script:_aiProbeCache = @{} }
    $now = Get-Date
    # Datei-Cache: jedes Tool spawned eine neue powershell.exe - der
    # $script:-Cache starb bisher mit jedem Prozess (11 Probes neu).
    # 10-Min-Cache in %LOCALAPPDATA%\SysPilot\ai-probe-cache.json.
    $probeFile = Join-Path $env:LOCALAPPDATA 'SysPilot\ai-probe-cache.json'
    if (-not $script:_aiProbeFileLoaded) {
        $script:_aiProbeFileLoaded = $true
        if (Test-Path $probeFile) {
            try {
                $pd = Get-Content $probeFile -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($pp in $pd.PSObject.Properties) {
                    try { $at = [datetime]$pp.Value.at; if ($at -gt $now.AddMinutes(-10)) { $script:_aiProbeCache[$pp.Name] = [pscustomobject]@{ Ok=[bool]$pp.Value.ok; At=$at } } } catch {}
                }
            } catch {}
        }
    }
    $dirty = $false
    foreach ($d in (Get-SysPilotAiProviderDefaults)) {
        if ($configuredUrls.ContainsKey($d.BaseUrl.ToLower())) { continue }  # User-Version gewinnt
        $hit = $false
        $c = $script:_aiProbeCache[$d.BaseUrl]
        if ($c -and $c.At -gt $now.AddMinutes(-10)) { $hit = $c.Ok }
        else {
            $hit = Test-SysPilotAiPortReachable -BaseUrl $d.BaseUrl -TimeoutSec 2
            $script:_aiProbeCache[$d.BaseUrl] = [pscustomobject]@{ Ok=$hit; At=$now }
            $dirty = $true
        }
        if ($hit) {
            $out += [pscustomobject]@{ Name=$d.Name; BaseUrl=$d.BaseUrl; Model=''; ApiKey=''; Kind='local'; Enabled=$true; Configured=$false; Reachable=$true }
        }
    }
    foreach ($p in @($cfg.Providers)) {
        $out += [pscustomobject]@{
            Name=$p.Name; BaseUrl=$p.BaseUrl; Model=$p.Model
            ApiKey=(Unprotect-SysPilotSecret $p.ApiKeyCipher)
            Kind=$(if ($p.Kind) { $p.Kind } else { 'cloud' })
            Enabled=($null -eq $p.Enabled -or $p.Enabled -eq $true)
            AllowedModels=@($p.AllowedModels)
            Configured=$true; Reachable=$null
        }
    }
    # Pollinations.ai OpenAI-kompatibel - KOSTENLOS, kein Key noetig.
    # Rate-Limit (~1-3 req) - letzte Fallback-Stufe.
    $out += [pscustomobject]@{ Name='Pollinations (free)'; BaseUrl='https://text.pollinations.ai/openai'; Model='openai'; ApiKey=''; Kind='free'; Enabled=$true; Configured=$false; Reachable=$null }
    # Intel (Kosten-/Inhaltsklasse) fuer jeden Eintrag - treibt die
    # Free-Budget-Sortierung und Budget-Anzeige in den Provider-Listen.
    foreach ($p in $out) {
        $intel = Get-SysPilotAiProviderIntel -Name $p.Name -BaseUrl $p.BaseUrl
        $p | Add-Member -NotePropertyName Cost -NotePropertyValue $intel.Cost -Force
        $p | Add-Member -NotePropertyName Content -NotePropertyValue $intel.Content -Force
    }
    # Reihenfolge: Cloud zuerst (schont CPU/RAM), lokal als Fallback,
    # Pollinations (free, rate-limitiert) als letzte Instanz. Innerhalb
    # einer Kind-Klasse nach Free-Budget: kostenlose/guenstige Provider
    # vor teuren/Abo - spart Kontingent, wenn Auto-Kette laeuft.
    # Explizite Auswahl ueber ProviderName bleibt unberuehrt.
    $costRank = @{ 'kostenlos'=0; 'lokal'=0; 'guenstig'=1; 'freemium'=2; 'gemischt'=3; 'unbekannt'=3; 'mittel'=4; 'abo'=5; 'teuer'=6 }
    $idx = 0
    $out = @($out | ForEach-Object {
        $p = $_
        $r = if ($p.Kind -eq 'local') { 1 } elseif ($p.Kind -eq 'free') { 2 } else { 0 }
        $cr = if ($costRank.ContainsKey([string]$p.Cost)) { $costRank[[string]$p.Cost] } else { 3 }
        [pscustomobject]@{ P=$p; I=$idx++; R=$r; CR=$cr }
    } | Sort-Object R, CR, I | ForEach-Object { $_.P })
    # Geaenderte Probes in die Datei zurueckschreiben
    if ($dirty) {
        try {
            $dir = Split-Path $probeFile -Parent
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            $pdOut = [ordered]@{}
            foreach ($k in $script:_aiProbeCache.Keys) { $pdOut[$k] = @{ ok=$script:_aiProbeCache[$k].Ok; at=$script:_aiProbeCache[$k].At.ToString('o') } }
            [pscustomobject]$pdOut | ConvertTo-Json -Depth 4 | Set-Content $probeFile -Encoding UTF8
        } catch {}
    }
    return $out
}

function Get-SysPilotAiUsableProviders {
    <# Die tatsaechlich nutzbare Provider-Liste: aktiviert +
       Provider-Modus (auto=cloud->lokal->free, local=strict,
       cloud=strict) + Preferred-Provider-Pin an erster Stelle.
       Jeder Eintrag traegt Cost/Content (Free-Budget) und
       CtxTokens (Kontext-Budget, falls /models-Cached; sonst
       $null = unbekannt, Chat-Fallback 8k/32k). #>
    param([int]$TimeoutSec = 6)
    $providers = @(Get-SysPilotAiProviders | Where-Object { $_.Enabled })
    $mode = Get-SysPilotAiProviderMode
    if ($mode -eq 'local') { $providers = @($providers | Where-Object { $_.Kind -eq 'local' }) }
    elseif ($mode -eq 'cloud') { $providers = @($providers | Where-Object { $_.Kind -ne 'local' }) }
    $pin = Get-SysPilotAiPreferredProvider
    if ($pin) {
        $first = @($providers | Where-Object { $_.Name -eq $pin })
        if ($first.Count -gt 0) { $providers = @($first) + @($providers | Where-Object { $_.Name -ne $pin }) }
    }
    # --- Smart Budget: Kosten-Automatik (an-/abschaltbar) ---
    $budgetMode = Get-SysPilotAiBudgetMode
    if ($budgetMode -ne 'aus' -and $budgetMode -ne 'qualitaet') {
        if ($budgetMode -eq 'sparsam') {
            # Sparmodus: teure/Abo/Enterprise-Provider raus -
            # guenstige+kostenlose bleiben, Pin ist ausgenommen
            $providers = @($providers | Where-Object {
                $_.Name -eq $pin -or $_.Cost -notin @('teuer','abo','mittel')
            })
        } else {
            # 'smart': Bezahltes nur solange Monats-Budget reicht.
            # Ueberschritten -> alle nicht-kostenlosen ans Ende (nicht
            # geloescht - Fallback bleibt, falls Free alles nur Fehlschlaege hat).
            $paidTokens = Get-SysPilotAiPaidTokensThisMonth
            $budget = Get-SysPilotAiMonthlyTokenBudget
            $budgetOut = ($budget -gt 0 -and $paidTokens -ge $budget)
            if ($budgetOut) {
                $free = @($providers | Where-Object { $_.Cost -in @('kostenlos','lokal') -or $_.Kind -eq 'free' })
                $paid = @($providers | Where-Object { $_.Cost -notin @('kostenlos','lokal') -and $_.Kind -ne 'free' })
                $providers = @($free) + @($paid)
            }
            # Pro-Provider Monats-Cap (TokenCapMonthly im Config)
            foreach ($p in @($providers)) {
                if (Test-SysPilotAiProviderBudgetExceeded -Provider $p) {
                    $providers = @($providers | Where-Object { $_.Name -ne $p.Name }) + @($p)
                }
            }
        }
    }
    # Kontext-Budget-Anreicherung: NUR aus dem Cache (CacheOnly) -
    # kein zusaetzlicher HTTP-Call pro Listenerzeugung. Der Chat
    # loest echte Context-Laengen ohnehin live beim ersten Request.
    foreach ($p in $providers) {
        $ctx = $null
        $ml = Get-SysPilotAiProviderModels -Provider $p -TimeoutSec $TimeoutSec -CacheOnly
        if ($ml.Ok -and $ml.Models.Count -gt 0) {
            $m = if ($p.Model) { @($ml.Models | Where-Object { $_.Id -eq $p.Model } | Select-Object -First 1) } else { @($ml.Models | Select-Object -First 1) }
            if ($m.Count -gt 0 -and $m[0].Context -gt 0) { $ctx = [int64]$m[0].Context }
        }
        $p | Add-Member -NotePropertyName CtxTokens -NotePropertyValue $ctx -Force
    }
    return $providers
}

function Test-SysPilotAiPortReachable {
    <# Port-Check: ZUERST TCP-Connect (localhost refused = sofort,
       kein Proxy-Umweg), DANACH optional /models. Verhindert den
       3.5s-Proxy-Timeout pro totem Port (11 Presets = 36s Haenger!). #>
    param([Parameter(Mandatory)][string]$BaseUrl, [int]$TimeoutSec = 3)
    $port = 0; $host_ = 'localhost'
    try {
        $u0 = [Uri]$BaseUrl
        $port = $u0.Port; $host_ = $u0.Host
        if (-not $port) { $port = $(if ($u0.Scheme -eq 'https') { 443 } else { 80 }) }
    } catch { return $false }
    # 1) TCP-Connect - localhost: refused ist sofort, kein HTTP-Proxy.
    # Loopback immer als 127.0.0.1 (vermeidet DNS/IPv6-Verzoegerung)
    $tcpHost = $host_
    if ($host_ -match '^(localhost|127\.|::1|\[::1\])') { $tcpHost = '127.0.0.1' }
    $tcpOk = $false
    try {
        $tcp = New-Object Net.Sockets.TcpClient
        $iar = $tcp.BeginConnect($tcpHost, $port, $null, $null)
        $tcpOk = $iar.AsyncWaitHandle.WaitOne(400)
        $tcp.Close()
    } catch { $tcpOk = $false }
    if (-not $tcpOk) { return $false }
    # Loopback: Port offen = erreichbar (echter /models-Test macht
    # Test-SysPilotAiProvider). HTTP-Aufruf wuerde bei HTTP_PROXY-
    # Umgebungen 2-3.5s pro Port kosten - genau der 36s-Haenger.
    if ($host_ -match '^(localhost|127\.|::1|\[::1\])') { return $true }
    # Remote: /models als Qualitaetscheck
    try {
        $u = $BaseUrl.TrimEnd('/') + '/models'
        Invoke-RestMethod $u -TimeoutSec $TimeoutSec -ErrorAction Stop | Out-Null
        return $true
    } catch { return $true }   # Port offen, /models evtl. anders - Melden genuegt
}

function Test-SysPilotAiProvider {
    <# Live-Test: GET /models (Key falls noetig). #>
    param([Parameter(Mandatory)]$Provider, [int]$TimeoutSec = 15)
    $u = $Provider.BaseUrl.TrimEnd('/') + '/models'
    $headers = @{}
    if ($Provider.ApiKey) { $headers['Authorization'] = "Bearer $($Provider.ApiKey)" }
    try {
        $r = Invoke-RestMethod $u -Headers $headers -TimeoutSec $TimeoutSec -ErrorAction Stop
        $n = @($r.data).Count
        return @{ Ok=$true; Models=$n; Error='' }
    } catch {
        return @{ Ok=$false; Models=0; Error=$_.Exception.Message }
    }
}

# --- Modell-Cooldowns (FreeLLMAPI-Prinzip: pro Modell gemerkte
#     Rate-Limit-Sperre, statt Provider komplett zu blockieren) ---
function Get-SysPilotAiModelCooldownFile {
    $f = Join-Path $env:LOCALAPPDATA 'SysPilot\ai-model-cooldowns.json'
    return $f
}
function Get-SysPilotAiModelCooldowns {
    <# Liefert Hashtable "baseUrl|model" -> [datetime] Cooldown-Ende.
       Abgelaufene Eintraege werden beim Lesen entfernt. #>
    $map = @{}
    $f = Get-SysPilotAiModelCooldownFile
    if (Test-Path $f) {
        try {
            $j = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($prop in $j.PSObject.Properties) {
                $until = [datetime]::MinValue
                if ([datetime]::TryParse([string]$prop.Value, [ref]$until) -and $until -gt (Get-Date)) {
                    $map[$prop.Name] = $until
                }
            }
        } catch {}
    }
    return $map
}
function Set-SysPilotAiModelCooldown {
    <# Merkt sich: dieses Modell auf diesem Provider ist quotiert
       (429/Rate-Limit). Default 15 min - geminated mit Retry-After
       wo moeglich. Persistiert in ai-model-cooldowns.json. #>
    param([Parameter(Mandatory)]$Provider, [Parameter(Mandatory)][string]$Model, [int]$Minutes = 15)
    $key = "$($Provider.BaseUrl.ToLower().TrimEnd('/'))|$Model"
    $map = Get-SysPilotAiModelCooldowns
    $map[$key] = (Get-Date).AddMinutes($Minutes)
    $f = Get-SysPilotAiModelCooldownFile
    try {
        $dir = Split-Path $f -Parent; if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $obj = [ordered]@{}; foreach ($k in $map.Keys) { $obj[$k] = $map[$k].ToString('o') }
        ($obj | ConvertTo-Json -Depth 3) | Set-Content $f -Encoding UTF8
    } catch {}
}
function Test-SysPilotAiModelCooledDown {
    param([Parameter(Mandatory)]$Provider, [Parameter(Mandatory)][string]$Model)
    $map = Get-SysPilotAiModelCooldowns
    $key = "$($Provider.BaseUrl.ToLower().TrimEnd('/'))|$Model"
    return $map.ContainsKey($key)
}
function Clear-SysPilotAiModelCooldown {
    param([Parameter(Mandatory)]$Provider, [Parameter(Mandatory)][string]$Model)
    $key = "$($Provider.BaseUrl.ToLower().TrimEnd('/'))|$Model"
    $map = Get-SysPilotAiModelCooldowns
    if ($map.ContainsKey($key)) {
        $map.Remove($key)
        $f = Get-SysPilotAiModelCooldownFile
        try {
            $obj = [ordered]@{}; foreach ($k in $map.Keys) { $obj[$k] = $map[$k].ToString('o') }
            ($obj | ConvertTo-Json -Depth 3) | Set-Content $f -Encoding UTF8
        } catch {}
    }
}

function Get-SysPilotAiUsageFile {
    return (Join-Path $env:LOCALAPPDATA 'SysPilot\ai-usage.json')
}
function Get-SysPilotAiUsage {
    <# Monatliche Nutzungs-Zaehler pro Provider (FreeLLMAPI-Prinzip:
       monthlyRequestCap/Usage). Schluessel "baseUrl|name", Wert
       {month:'yyyy-MM', requests:N, tokens:N, last:'iso'}. #>
    $f = Get-SysPilotAiUsageFile
    if (Test-Path $f) {
        try { return (Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {}
    }
    return $null
}
function Add-SysPilotAiUsageRecord {
    <# Addiert einen erfolgreichen Request (+ optional Token-Verbrauch)
       auf den Monats-Zaehler des Providers. Billig - nur bei Erfolg. #>
    param([Parameter(Mandatory)]$Provider, [string]$Model = '', [int64]$Tokens = 0)
    try {
        $f = Get-SysPilotAiUsageFile
        $j = Get-SysPilotAiUsage
        $month = (Get-Date).ToString('yyyy-MM')
        $key = "$($Provider.BaseUrl.ToLower().TrimEnd('/'))|$($Provider.Name)"
        if (-not $j) { $j = [pscustomobject]@{} }
        $cur = $j.$key
        if (-not $cur -or $cur.month -ne $month) {
            $cur = [pscustomobject]@{ month=$month; requests=0; tokens=[int64]0; last='' }
        }
        $cur.requests = [int64]$cur.requests + 1
        $cur.tokens = [int64]$cur.tokens + $Tokens
        $cur.last = (Get-Date).ToString('o')
        $j | Add-Member -NotePropertyName $key -NotePropertyValue $cur -Force
        $dir = Split-Path $f -Parent; if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        ($j | ConvertTo-Json -Depth 4) | Set-Content $f -Encoding UTF8
    } catch {}
}
function Get-SysPilotAiUsageSummary {
    <# Monatliche Nutzung eines Providers als Textzeile,
       z.B. 'Mai 2026: 42 Requests, 183k Tokens'. #>
    param([Parameter(Mandatory)]$Provider)
    $j = Get-SysPilotAiUsage
    if (-not $j) { return '' }
    $key = "$($Provider.BaseUrl.ToLower().TrimEnd('/'))|$($Provider.Name)"
    $cur = $j.$key
    if (-not $cur) { return '' }
    $month = (Get-Date).ToString('yyyy-MM')
    if ($cur.month -ne $month) {
        $prev = $j.PSObject.Properties | Where-Object { $_.Value.month -ne $month } | Select-Object -First 1
        return "letzter Monat: $($cur.requests) Requests, $([math]::Round([int64]$cur.tokens/1000))k Tokens"
    }
    $tk = [math]::Round([int64]$cur.tokens / 1000)
    return "Monat ${month}: $($cur.requests) Requests, ${tk}k Tokens"
}

function Get-SysPilotAiRankedModels {
    <# Bewertet die /models-Liste eines Providers und liefert die IDs
       sortiert nach Eignung - 'best selection' automatisiert:
       - Kostenklasse des Providers (kostenlos/lokal > freemium >
         guenstig > teuer): bei kostenlosenProvidern werden Free-Varianten
         (:free, -free, free) und kleine/effiziente Modelle bevorzugt,
         bei teuren der groesste verfuegbare Kontext.
       - Demotion: embedding/rerank/whisper/tts/image/moderation-Modelle
         sind keine Chat-Modelle.
       - Lokale Modelle: 3-9b-Klasse bevorzugt (CPU-Tempo), wie bisher.
       Gibt @(@{Id;Score;Context}) sortiert absteigend zurueck. #>
    param([Parameter(Mandatory)]$Provider, [int]$TimeoutSec = 12, [int]$Top = 8)
    $ml = Get-SysPilotAiProviderModels -Provider $Provider -TimeoutSec $TimeoutSec
    if (-not $ml.Ok -or @($ml.Models).Count -eq 0) { return @() }
    # Model-Scope (FreeLLMAPI-Prinzip): AllowedModels im Config limitiert
    # den Pool - leere Liste = alle Modelle erlaubt.
    $allowed = @($Provider.AllowedModels | ForEach-Object { "$_".Trim().ToLower() } | Where-Object { $_ })
    if ($allowed.Count -gt 0) {
        # Exakt oder Prefix-Match ('openai' deckt 'openai-fast' ab)
        $ml.Models = @($ml.Models | Where-Object {
            $id = ([string]$_.Id).Trim().ToLower()
            ($allowed | Where-Object { $id -eq $_ -or $id.StartsWith("$_") }).Count -gt 0
        })
        if (@($ml.Models).Count -eq 0) { return @() }
    }
    $intel = Get-SysPilotAiProviderIntel -Name $Provider.Name -BaseUrl $Provider.BaseUrl
    $cost = [string]$intel.Cost
    $freeish = $cost -in @('lokal','kostenlos','freemium','gemischt','unbekannt')
    # Modell-Cooldowns (Rate-Limit-Merkzettel, FreeLLMAPI-Prinzip):
    # quotierte Modelle ans Ende der Liste, nicht ausschliessen
    $cooldowns = Get-SysPilotAiModelCooldowns
    $ckBase = "$($Provider.BaseUrl.ToLower().TrimEnd('/'))|"
    $ranked = foreach ($m in @($ml.Models)) {
        $id = [string]$m.Id
        if (-not $id) { continue }
        $score = 0
        if ($cooldowns.ContainsKey("$ckBase$id")) { $score -= 500 }
        # --- Nicht-Chat-Modelle stark demoten ---
        if ($id -match '(?i)embed|bge-|e5-|nomic|gte-|rerank|whisper|tts|speech|moderation|guard|content.?filter|stable.?diffusion|flux|sdxl|imagen|dall-e|midjourney|audio|music|upscale|segment|depth|clip$') { $score -= 100 }
        # --- Free-Varianten (OpenRouter :free, *-free, free*) ---
        if ($id -match '(?i)(:free$|-free$|(^|[/_-])free([:/_-]|$))') { $score += 60 }
        elseif ($freeish -and $id -match '(?i)free|flash|mini|lite|small|nano|turbo|instant|haiku') { $score += 25 }
        # --- Frontier/Coding-Staerken als Qualitaets-Signal ---
        if ($id -match '(?i)gpt-5|gpt-4\.1|claude|gemini-2|pro|max|reason|o[134]-|deepseek-v?3|kimi|glm-4\.6|qwen3-(max|235|480)|llama-4|hermes|dolphin|abliterated|uncensored|dolphin|venice') { $score += 20 }
        # --- Groessen-Klasse ---
        $b = 0
        if ($id -match '(\d+(?:\.\d+)?)\s*b') { $b = [double]$Matches[1] }
        elseif ($id -match '(\d{2,3})') { $b = [double]$Matches[1] }  # z.B. llama-3.3-70b -> 70 via b-Regel; Fallback fuer 70b ohne 'b'
        if ($Provider.Kind -eq 'local' -or $cost -eq 'lokal') {
            if ($b -ge 3 -and $b -le 9) { $score += 30 }        # CPU-Sweet-Spot
            elseif ($b -gt 0 -and $b -lt 3) { $score -= 10 }   # zu klein
            elseif ($b -gt 13) { $score -= 15 }               # zu schwer fuer CPU
        } else {
            # Cloud: groessere Modelle = bessere Qualitaet, aber bei
            # Free-Tiers sind 'flash/mini'-Klassen oft das Kontingent
            if ($b -gt 0) { $score += [math]::Min(20, [math]::Round($b / 5)) }
            if ($freeish -and $id -match '(?i)flash|mini|lite|small|nano|turbo|instant|haiku|8b|7b') { $score += 15 }
        }
        # --- Kontext-Budget: groesser = besser (log-Skala) ---
        if ($m.Context -gt 0) { $score += [math]::Min(15, [math]::Round([math]::Log10($m.Context) * 3)) }
        # --- SysPilot-Spezial: lokales 'herbert'-Modell hat Vorrang ---
        if ($id -match '^(?i)herbert([: ]|$)') { $score += 50 }
        [pscustomobject]@{ Id=$id; Score=$score; Context=[int64]$m.Context }
    }
    return @($ranked | Sort-Object Score -Descending | Select-Object -First $Top)
}

function Resolve-SysPilotAiModel {
    <# Waehlt ein Modell: konfiguriertes, sonst bestes aus der
       bewerteten /models-Liste (Get-SysPilotAiRankedModels -
       beruecksichtigt Kostenklasse, Free-Varianten, Groesse,
       Kontext). Nur HTTP-Call ueber Get-SysPilotAiProviderModels
       + Session-Cache. #>
    param([Parameter(Mandatory)]$Provider, [int]$TimeoutSec = 12)
    if ($Provider.Model) { return $Provider.Model }
    $ck = "$($Provider.BaseUrl.ToLower().TrimEnd('/'))|$([string]$Provider.ApiKey)"
    if ($script:AiModelResolveCache.ContainsKey($ck)) { return $script:AiModelResolveCache[$ck] }
    $pick = 'gpt-4o-mini'
    $ranked = @(Get-SysPilotAiRankedModels -Provider $Provider -TimeoutSec $TimeoutSec -Top 1)
    if ($ranked.Count -gt 0 -and $ranked[0].Id) { $pick = $ranked[0].Id }
    $script:AiModelResolveCache[$ck] = $pick
    if ($script:AiModelResolveCache.Count -gt 200) { $script:AiModelResolveCache.Clear() }
    return $pick
}

function Get-SysPilotAiProviderModels {
    <# Holt die Modellliste eines Providers via GET /models.
       Gibt @{Ok;Models;Error} zurueck; Models = @(@{Id;Context;Raw}).
       Context wird aus ueblichen Feldern gelesen (context_length,
       max_context, n_ctx, max_model_len, maxTokens) - manche Server
       (Ollama, LM Studio, vLLM, OmniRoute) liefern sie mit.
       -CacheOnly: nur Cache lesen, kein HTTP (fuer Listen-Generierung). #>
    param([Parameter(Mandatory)]$Provider, [int]$TimeoutSec = 15, [switch]$CacheOnly)
    # Session-Cache: Modelllisten+aendern sich selten; verhindert
    # Doppel-Calls aus Resolve-SysPilotAiModel + Kontext-Budget.
    $mck = ($Provider.BaseUrl.ToLower().TrimEnd('/') + '|' + [string]$Provider.ApiKey)
    if (-not $script:AiModelsCache) { $script:AiModelsCache = @{} }
    if ($script:AiModelsCache.ContainsKey($mck) -and ((Get-Date) - $script:AiModelsCache[$mck].Time).TotalMinutes -lt 10) {
        return $script:AiModelsCache[$mck].Result
    }
    if ($CacheOnly) { return @{ Ok=$false; Models=@(); Error='cache-miss' } }
    $u = $Provider.BaseUrl.TrimEnd('/') + '/models'
    $headers = @{}
    if ($Provider.ApiKey) { $headers['Authorization'] = "Bearer $($Provider.ApiKey)" }
    try {
        $r = Invoke-RestMethod $u -Headers $headers -TimeoutSec $TimeoutSec -ErrorAction Stop
        $list = @()
        foreach ($m in @($r.data)) {
            $id = [string]$(if ($m.id) { $m.id } elseif ($m.name) { $m.name } else { '' })
            if (-not $id) { continue }
            $ctx = 0
            foreach ($prop in @($m.PSObject.Properties.Name)) {
                if ($prop -match '(?i)context|max_tokens|n_ctx|max_len|ctx') {
                    $v = $m.$prop
                    if ($v -is [long] -or $v -is [int] -or $v -is [double]) {
                        if ($v -gt $ctx) { $ctx = [int64]$v }
                    } elseif ($v -is [string] -and $v -match '^\d{3,}$') {
                        if ([int64]$v -gt $ctx) { $ctx = [int64]$v }
                    }
                }
            }
            $list += [pscustomobject]@{ Id=$id; Context=$ctx }
        }
        # Ollama-Nativ-API: /v1/models liefert kein Context-Feld -
        # /api/show pro Modell liefert model_info.*.context_length
        if ($Provider.BaseUrl -match '11434' -and $list.Count -gt 0) {
            $native = $Provider.BaseUrl -replace '/v1$',''
            foreach ($m in $list) {
                if ($m.Context -gt 0) { continue }
                try {
                    $show = Invoke-RestMethod -Uri "$native/api/show" -Method Post -Body (@{ name=$m.Id } | ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 10 -ErrorAction Stop
                    $mi = $show.model_info
                    if ($mi) {
                        foreach ($pn in $mi.PSObject.Properties.Name) {
                            if ($pn -match 'context_length$' -and $mi.$pn -gt $m.Context) { $m.Context = [int64]$mi.$pn }
                        }
                    }
                } catch {}
            }
        }
        $res = @{ Ok=$true; Models=$list; Error='' }
        $script:AiModelsCache[$mck] = @{ Time=Get-Date; Result=$res }
        if ($script:AiModelsCache.Count -gt 100) { $script:AiModelsCache.Clear() }
        return $res
    } catch {
        return @{ Ok=$false; Models=@(); Error=$_.Exception.Message }
    }
}

function Select-SysPilotAiProviderModel {
    <# Interaktive Modellwahl fuer einen Provider. Setzt Model in der
       Config ('auto' = Feld leeren). Gibt gewaehltes Modell oder
       $null (Abbruch) zurueck. #>
    param([Parameter(Mandatory)]$Provider, [string]$Owner)
    $ml = Get-SysPilotAiProviderModels -Provider $Provider
    if (-not $ml.Ok) {
        Write-Host "  [!] Modelle nicht abrufbar: $($ml.Error)" -ForegroundColor Red
        return $null
    }
    $items = @(@{ Label='(auto - kleinstes passendes Modell waehlt Herbert)'; Color='Cyan'; Tag='' })
    foreach ($m in @($ml.Models)) {
        $ctxTxt = if ($m.Context -gt 0) { "  [$([math]::Round($m.Context/1024))k ctx]" } else { '' }
        $cur = if ($Provider.Model -eq $m.Id) { '  <== aktuell' } else { '' }
        $items += @{ Label="$($m.Id)$ctxTxt$cur"; Color='White'; Tag=$m.Id }
    }
    if ($Provider.Model -and @($ml.Models | Where-Object { $_.Id -eq $Provider.Model }).Count -eq 0) {
        $items += @{ Label="$($Provider.Model)  <== aktuell (nicht in /models)"; Color='Yellow'; Tag=$Provider.Model }
    }
    $sel = Show-SysPilotArrowMenu -Items $items -Title "Modell waehlen - $($Provider.Name)" -Footer 'Enter = uebernehmen, Esc = abbruch'
    if ($null -eq $sel) { return $null }
    # Config updaten - auch fuer eingebaute Provider (dann wird ein
    # konfigurierter Eintrag mit demselben Namen angelegt)
    $cfg = Read-SysPilotAiAssistConfig
    $found = $false
    foreach ($cp in @($cfg.Providers)) {
        if ($cp.Name -eq $Provider.Name) {
            $found = $true
            if ($sel) { $cp | Add-Member -NotePropertyName Model -NotePropertyValue $sel -Force }
            else {
                if ($cp.PSObject.Properties['Model']) { $cp.Model = '' } else { $cp | Add-Member -NotePropertyName Model -NotePropertyValue '' -Force }
            }
        }
    }
    if (-not $found) {
        $cfg.Providers = @($cfg.Providers) + @([pscustomobject]@{
            Name=$Provider.Name; BaseUrl=$Provider.BaseUrl; Model=$sel; Kind=$Provider.Kind
            Enabled=$true; ApiKeyCipher=''
        })
    }
    Write-SysPilotAiAssistConfig $cfg
    Write-Host "  Modell gesetzt: $(if($sel){$sel}else{'auto'})" -ForegroundColor Green
    return $sel
}

function Test-SysPilotAiProviderQuality {
    <# Erweiterter Provider-Check: erreichbar + Modelle + Context-Budget
       (falls gemeldet) + optional Mini-Chat-Test. Ergebnis:
       @{Ok;Score;Issues;Models;Error}. Score 0-100. #>
    param([Parameter(Mandatory)]$Provider, [switch]$ChatTest, [int]$MinContext = 4096)
    $issues = @(); $score = 100
    $ml = Get-SysPilotAiProviderModels -Provider $Provider
    if (-not $ml.Ok) { return @{ Ok=$false; Score=0; Issues=@("nicht erreichbar: $($ml.Error)"); Models=@(); Error=$ml.Error } }
    if (@($ml.Models).Count -eq 0) { $issues += 'keine Modelle in /models'; $score -= 40 }
    $bestCtx = ($ml.Models | Measure-Object -Property Context -Maximum).Maximum
    if ($bestCtx -gt 0 -and $bestCtx -lt $MinContext) {
        $issues += "Context-Budget zu klein: $([math]::Round($bestCtx/1024))k < $([math]::Round($MinContext/1024))k"
        $score -= 30
    }
    if ($ChatTest -and @($ml.Models).Count -gt 0) {
        $mid = ($ml.Models | Select-Object -First 1).Id
        $body = @{ model=$mid; messages=@(@{role='user';content='Antworte nur mit: OK'}); max_tokens=5 } | ConvertTo-Json -Depth 6
        $headers = @{ 'Content-Type'='application/json' }
        if ($Provider.ApiKey) { $headers['Authorization']="Bearer $($Provider.ApiKey)" }
        try {
            Invoke-RestMethod -Uri ($Provider.BaseUrl.TrimEnd('/')+'/chat/completions') -Method Post -Headers $headers -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 30 -ErrorAction Stop | Out-Null
        } catch { $issues += "Chat-Test fehlgeschlagen: $($_.Exception.Message)"; $score -= 30 }
    }
    return @{ Ok=($score -ge 50); Score=$score; Issues=$issues; Models=$ml.Models; Error='' }
}

function Invoke-SysPilotAiProviderCleanup {
    <# Prueft alle konfigurierten Provider und deaktiviert die
       unbrauchbaren (nicht erreichbar, keine Modelle, Chat tot).
       Gibt @{Tested;Disabled;Issues} zurueck. #>
    $cfg = Read-SysPilotAiAssistConfig
    $tested = 0; $disabled = @(); $report = @()
    foreach ($cp in @($cfg.Providers)) {
        $tested++
        $p = [pscustomobject]@{ Name=$cp.Name; BaseUrl=$cp.BaseUrl; Model=$cp.Model; ApiKey=(Unprotect-SysPilotSecret $cp.ApiKeyCipher); Kind=$cp.Kind }
        $q = Test-SysPilotAiProviderQuality -Provider $p -ChatTest:$false
        $bad = @()
        if (-not $q.Ok) { $bad += ($q.Issues -join '; ') }
        elseif ($q.Score -lt 70) { $bad += ($q.Issues -join '; ') }
        if ($bad.Count -gt 0) {
            $report += "  [SCHWACH] $($cp.Name): $($bad -join '; ')"
            # Nur deaktivieren wenn komplett tot (nicht erreichbar/keine Modelle)
            $ml2 = Get-SysPilotAiProviderModels -Provider $p
            if (-not $ml2.Ok -or @($ml2.Models).Count -eq 0) {
                $cp | Add-Member -NotePropertyName Enabled -NotePropertyValue $false -Force
                $disabled += $cp.Name
                $report += "    -> deaktiviert"
            }
        } else {
            $report += "  [OK] $($cp.Name): $(@($q.Models).Count) Modelle, Score $($q.Score)"
        }
    }
    Write-SysPilotAiAssistConfig $cfg
    return @{ Tested=$tested; Disabled=$disabled; Report=$report }
}

function Show-SysPilotHerbertSelfCheck {
    <# Herbert-Selbsttest: inventarisiert Provider, MCP-Server, Skills
       und API-Keys - und schlaegt konkrete naechste Erweiterungen vor.
       'Rat und Tat':  L    /Setup. #>
    Write-Host "`n  === HERBERT SELBSTCHECK (Einrichtung + Erweiterung) ===" -ForegroundColor Cyan
    $tip = @()

    # 1) Provider
    $prov = @(Get-SysPilotAiProviders | Where-Object { $_.Enabled })
    $reach = 0
    foreach ($p in ($prov | Select-Object -First 6)) {
        try { if ((Test-SysPilotAiProvider -Provider $p -TimeoutSec 4).Ok) { $reach++ } } catch {}
    }
    Write-Host "  Provider: $($prov.Count) aktiv, $reach erreichbar (Probe)" -ForegroundColor $(if($prov.Count -gt 0){'Green'}else{'Yellow'})
    if ($prov.Count -eq 0) { $tip += 'Keine Provider - ERSTEINRICHTUNG starten (kostenlos: Ollama oder Free-Tier-Key)' }
    elseif ($reach -eq 0) { $tip += 'Provider da, aber keiner antwortet - Provider-Fenster oeffnen und testen' }

    # 2) MCP-Server
    $mcpOn = @()
    try { $mcpOn = @(Get-SysPilotMcpServers | Where-Object { $_.Enabled }) } catch {}
    $mcpCat = @(Get-SysPilotMcpInstallCatalog)
    Write-Host "  MCP-Server: $($mcpOn.Count) aktiv / $($mcpCat.Count) im Katalog" -ForegroundColor $(if($mcpOn.Count -gt 0){'Green'}else{'Yellow'})
    if ($mcpOn.Count -eq 0) { $tip += 'Keine MCP-Server - Katalog hat 14 kostenlose (git, fetch, memory, puppeteer, context7 ...) - MCP-Menue offnen' }

    # 3) Skills
    $sk = @(Get-SysPilotLocalSkills)
    Write-Host "  Skills: $($sk.Count) lokal installiert (skills.sh-Registry durchsuchbar)" -ForegroundColor $(if($sk.Count -gt 0){'Green'}else{'Yellow'})
    if ($sk.Count -lt 3) { $tip += 'Wenig Skills - Herbert-Manager > skills.sh-Katalog durchsuchen (kostenlos)' }

    # 4) API-Keys
    $keys = @(Get-SysPilotAiKeyFileCandidates)
    Write-Host "  API-Key-Dateien: $($keys.Count) gefunden (Dokumente\api keys u.a.)" -ForegroundColor $(if($keys.Count -gt 0){'Green'}else{'DarkGray'})
    if ($keys.Count -eq 0) { $tip += 'Keine Key-Dateien - Provider-Vorschlaege zeigen Free-Tier-Keys (OpenRouter, Gemini, Groq ...)' }

    if ($tip.Count -gt 0) {
        Write-Host "`n  Naechste Schritte (Empfehlung):" -ForegroundColor Cyan
        $i = 1
        foreach ($t in $tip) { Write-Host "  $i. $t" -ForegroundColor White; $i++ }
        Write-Host "`n  Was jetzt oeffnen?" -ForegroundColor DarkYellow
        $fix = Show-SysPilotArrowMenu -Items @(
            @{ Label='Provider-Onboarding (kostenlose Keys)'; Color='Green'; Tag='onboard' },
            @{ Label='Provider-Fenster (verwalten/testen)'; Color='Cyan'; Tag='providers' },
            @{ Label='MCP-Server installieren (14 kostenlose)'; Color='Green'; Tag='mcp' },
            @{ Label='Skills + Konnektoren (Herbert-Manager)'; Color='Green'; Tag='manager' },
            @{ Label='Provider-Vorschlaege (Free-Tier-Katalog)'; Color='Cyan'; Tag='suggest' },
            @{ Label='API-Keys importieren/sichern'; Color='Yellow'; Tag='keys' },
            @{ Label='Nur Bericht, weiter'; Color='DarkGray'; Tag='done' }
        ) -Title 'Herbert erweitern' -Footer 'Enter = oeffnen, Esc = zurück'
        if ($null -eq $fix -or $fix -eq 'done') { return }
        switch ($fix) {
            'onboard'   { Show-SysPilotAiOnboarding }
            'providers' { try { Show-SysPilotAiProvidersWindow } catch { Show-SysPilotAiProviderMenu } }
            'mcp'       { Show-SysPilotMcpMenu }
            'manager'   { Show-SysPilotHerbertManager }
            'suggest'   { try { Show-SysPilotAiSuggestionsWindow } catch { Show-SysPilotAiSuggestions } }
            'keys'      { try { Show-SysPilotAiImportExportMenu } catch { Save-SysPilotAiKeyBackup | Out-Null } }
        }
        return
    }
    Write-Host "`n  [OK] Herbert ist rundum eingerichtet - nichts fehlt." -ForegroundColor Green
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
}

function Install-SysPilotHerbertCapability {
    <# Selbsttaetiger Faehigkeits-Installer: zu einem Bedarf ($Need, z.B.
       'websuche', 'browser', 'sqlite') sucht Herbert lokal (installierte
       MCP/Skills), im installierbaren Katalog und in den Remote-Katalogen
       (awesome-mcp-servers + GitHub + skills.sh). Der beste Kandidat wird
       zum Review angeboten; bei Auswahl wird installiert, konfiguriert,
       aktiviert und getestet. Token/Args/Login fuehren zu User-Prompt +
       oeffnen der noetigen Seite. #>
    param([Parameter(Mandatory)][string]$Need)

    $needL = $Need.ToLower().Trim()
    $kw = @($needL -split '[^\w+.-]+' | Where-Object { $_.Length -ge 3 } | Select-Object -Unique)
    $score = {
        param([string]$Text)
        $t = "$Text".ToLower(); $s = 0
        foreach ($k in $kw) { if ($t.Contains($k)) { $s += 2 } }
        if ($needL.Length -ge 8 -and $t.Contains($needL)) { $s += 5 }
        return $s
    }

    Write-Host "`n  === HERBERT: Faehigkeit besorgen - '$Need' ===" -ForegroundColor Cyan

    # 1) Bereits vorhanden? (aktive MCP-Server + lokale Skills)
    $haveMcp = @()
    try { $haveMcp = @(Get-SysPilotMcpServers | Where-Object { $_.Enabled } | Where-Object { (& $score "$($_.Name) $($_.Command) $($_.Url)") -gt 0 }) } catch {}
    $haveSkill = @()
    try { $haveSkill = @(Get-SysPilotLocalSkills | Where-Object { (& $score "$($_.Name) $($_.Desc)") -gt 0 }) } catch {}
    if ($haveMcp.Count -gt 0 -or $haveSkill.Count -gt 0) {
        Write-Host "  Bereits vorhanden:" -ForegroundColor Green
        foreach ($m in $haveMcp) { Write-Host "    [MCP] $($m.Name) (aktiv)" -ForegroundColor Green }
        foreach ($s in $haveSkill) { Write-Host "    [Skill] $($s.Name)" -ForegroundColor Green }
        $more = Read-SysPilotInput 'Trotzdem weiteren Kandidaten suchen? (leer = nein)' '' 'Herbert'
        if (-not $more) { Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; return }
    }
    # Deaktivierte Treffer -> direkt aktivieren anbieten
    $disMcp = @()
    try { $disMcp = @(Get-SysPilotMcpServers | Where-Object { -not $_.Enabled } | Where-Object { (& $score "$($_.Name) $($_.Command) $($_.Url)") -gt 0 }) } catch {}
    if ($disMcp.Count -gt 0) {
        Write-Host "`n  Deaktiviert, aber passend:" -ForegroundColor Yellow
        foreach ($d in $disMcp) { Write-Host "    [MCP] $($d.Name)" -ForegroundColor Yellow }
        $act = Read-SysPilotInput "Server-Namen zum Aktivieren eingeben (leer = Kandidaten suchen)" '' 'Herbert'
        if ($act) {
            $match = $disMcp | Where-Object { $_.Name -eq $act.Trim() } | Select-Object -First 1
            if (-not $match) { $match = $disMcp | Where-Object { $_.Name -like "*$($act.Trim())*" } | Select-Object -First 1 }
            if ($match) {
                $en = Set-SysPilotMcpServerEnabled -Name $match.Name -Enabled $true
                Write-Host "  $($en.Message)" -ForegroundColor Green
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
                return
            }
            Write-Host "  Kein Treffer - weiter mit Kandidaten-Suche." -ForegroundColor DarkYellow
        }
    }

    # 2) Kandidaten sammeln
    $cands = @()
    foreach ($c in @(Get-SysPilotMcpInstallCatalog)) {
        $sc = & $score "$($c.Name) $($c.Desc) $($c.Package)"
        if ($sc -gt 0) { $cands += [pscustomobject]@{ Kind='mcp'; Sub='katalog'; Name=$c.Name; Desc=$c.Desc; Package=$c.Package; NeedsArgs=$c.NeedsArgs; NeedsToken=$c.NeedsToken; Score=$sc; Url='' } }
    }
    try {
        foreach ($r in @(Find-SysPilotMcpRemoteServers -Query $Need -Limit 15)) {
            $sc = & $score "$($r.Name) $($r.Desc)"
            if ($sc -gt 0) { $cands += [pscustomobject]@{ Kind='mcp'; Sub='remote'; Name=$r.Name; Desc=$r.Desc; Package=$r.Package; NeedsArgs=$false; NeedsToken=$false; Score=$sc; Url=$r.RepoUrl } }
        }
    } catch { Write-SysPilotMcpLog "capability remote-mcp: $($_.Exception.Message)" }
    try {
        foreach ($r in @(Find-SysPilotSkillsRemote -Query $Need)) {
            $sc = & $score "$($r.Name) $($r.Desc) $($r.Ref)"
            if ($sc -gt 0) { $cands += [pscustomobject]@{ Kind='skill'; Sub='skills.sh'; Name=$r.Name; Desc=$("$($r.Desc) [$($r.Installs) installs]"); Package=$r.Ref; NeedsArgs=$false; NeedsToken=$false; Score=$sc; Url=$r.Url } }
        }
    } catch { Write-SysPilotMcpLog "capability skills: $($_.Exception.Message)" }

    # Dedupe nach Name (katalog/remoteSkill bevorzugt vor remote-ohne-Paket)
    $seen = @{}
    $cands = @($cands | Sort-Object @{E={if($_.Package){0}else{1}}}, @{E={- $_.Score}}, @{E={if($_.Sub -eq 'katalog'){0}else{1}}} | Where-Object {
        $k = "$($_.Kind):$($_.Name)".ToLower()
        if ($seen.ContainsKey($k)) { $false } else { $seen[$k]=$true; $true }
    } | Select-Object -First 10)

    if ($cands.Count -eq 0) {
        Write-Host "  Keine passenden Kandidaten in Katalogen gefunden." -ForegroundColor Yellow
        Write-Host "  Tipp: Herbert-Manager oeffnen (skills.sh + MCP-Kataloge durchsuchen) oder Bedarfs-Formulierung pruefen." -ForegroundColor DarkYellow
        Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
        return
    }

    # 3) Auswahl (bestes zuerst markiert)
    $items = @()
    $i = 0
    foreach ($c in $cands) {
        $i++
        $kind = if ($c.Kind -eq 'skill') { 'SKILL' } else { 'MCP' }
        $sub  = if ($c.Sub -eq 'katalog') { 'Katalog' } elseif ($c.Sub -eq 'remote') { 'Remote' } else { 'skills.sh' }
        $warn = ''
        if ($c.NeedsToken) { $warn = ' [TOKEN noetig]' }
        if ($c.NeedsArgs)  { $warn += ' [ARGS noetig]' }
        if (-not $c.Package -and $c.Kind -eq 'mcp') { $warn += ' [kein npx-Paket -> nur Link]' }
        $items += @{ Label="[$kind/$sub] $($c.Name) - $($c.Desc)$warn"; Color=$(if($i -eq 1){'Green'}else{'White'}); Tag=$c }
    }
    $items += @{ Label='Repository/Info-Seite des ersten Treffers oeffnen'; Color='DarkCyan'; Tag='openfirst' }
    $items += @{ Label='Abbrechen'; Color='DarkGray'; Tag=$null }
    $sel = Show-SysPilotArrowMenu -Items $items -Title "Herbert installiert: $Need" -Footer 'Enter = installieren, Esc = abbruch'
    if ($null -eq $sel) { return }
    if ($sel -eq 'openfirst') {
        $u = $cands[0].Url; if ($u) { Start-Process $u; Write-Host "  Geoeffnet: $u" -ForegroundColor Cyan }
        Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; return
    }

    # 4) Installieren
    $ok = $false; $msg = ''
    if ($sel.Kind -eq 'skill') {
        $r = Install-SysPilotSkill -Ref $sel.Package
        $ok = $r.Ok; $msg = $r.Message
        if ($sel.Url) { try { Start-Process $sel.Url } catch {} }
    } else {
        # Token/Args vorher abfragen + Seiten oeffnen
        $envH = @{}; $srvArgs = ''
        if ($sel.NeedsToken) {
            $page = switch ($sel.Name) {
                'github'       { 'https://github.com/settings/tokens' }
                'brave-search' { 'https://brave.com/search/api/' }
                default        { '' }
            }
            if ($page) { try { Start-Process $page; Write-Host "  Token-Seite geoeffnet: $page" -ForegroundColor Cyan } catch {} }
            $tok = Read-SysPilotInput "API-Token fuer $($sel.Name) (leer = spaeter in mcp.json eintragen)" '' 'Herbert'
            if ($tok) {
                $envKey = switch ($sel.Name) { 'github' {'GITHUB_PERSONAL_ACCESS_TOKEN'} 'brave-search' {'BRAVE_API_KEY'} default {'API_KEY'} }
                $envH[$envKey] = $tok.Trim()
            }
        }
        if ($sel.NeedsArgs) {
            $hint = switch ($sel.Name) {
                'filesystem' { 'erlaubte Pfade, z.B. C:\\ D:\\' }
                'git'        { 'Pfad zum lokalen Repo (optional)' }
                'sqlite'     { 'Pfad zur .db-Datei' }
                default      { 'noetige Argumente' }
            }
            $srvArgs = Read-SysPilotInput "Args fuer $($sel.Name) ($hint)" '' 'Herbert'
            if (-not $srvArgs) { $srvArgs = '' }
        }
        if (-not $sel.Package) {
            Write-Host "  $($sel.Name) hat kein direktes npx-Paket - Repo-Link:" -ForegroundColor Yellow
            Write-Host "    $($sel.Url)" -ForegroundColor Cyan
            try { Start-Process $sel.Url } catch {}
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; return
        }
        if ($sel.Sub -eq 'katalog') {
            $r = Install-SysPilotMcpServer -Name $sel.Name -Args $srvArgs -Env $envH
        } else {
            $r = Install-SysPilotMcpPackage -Name $sel.Name -Package $sel.Package -Args $srvArgs
            if ($r.Ok -and $envH.Count -gt 0) {
                # Env nachruesten (remote-Install hat kein Env-Param)
                $mc = Read-SysPilotMcpConfig
                $safe = ($sel.Name -replace '[^\w.-]','-')
                if ($mc.Servers.$safe) {
                    $envObj = [pscustomobject]@{}
                    foreach ($k in $envH.Keys) { $envObj | Add-Member -NotePropertyName $k -NotePropertyValue $envH[$k] -Force }
                    $mc.Servers.$safe.env = $envObj
                    Write-SysPilotMcpConfig $mc
                }
            }
        }
        $ok = $r.Ok; $msg = $r.Message
    }

    Write-Host "`n  $($msg -split "`n" | Select-Object -First 3 | Out-String).Trim()" -ForegroundColor $(if($ok){'Green'}else{'Red'})
    if ($ok -and $sel.Kind -eq 'mcp') {
        # Aktivieren + Test
        try {
            $srv = @(Get-SysPilotMcpServers) | Where-Object { $_.Name -eq ($sel.Name -replace '[^\w.-]','-') -or $_.Name -eq $sel.Name } | Select-Object -First 1
            if ($srv -and -not $srv.Enabled) { Set-SysPilotMcpServerEnabled -Name $srv.Name -Enabled $true | Out-Null }
            $script:McpToolsCache=@{}; $script:McpToolsCacheTime=[datetime]::MinValue
            Write-Host '  Teste tools/list (erster Start laedt npx-Paket, kann ~30s dauern) ...' -ForegroundColor DarkYellow
            $tr = Invoke-SysPilotMcpRpc -Server $srv -Method 'tools/list' -Params @{} -TimeoutSec 60
            if ($tr.Ok) { Write-Host "  [OK] $($tr.Result.tools.Count) MCP-Tools bereit - Herbert kann sie ab jetzt nutzen." -ForegroundColor Green }
            else { Write-Host "  [!] Test: $($tr.Error)" -ForegroundColor DarkYellow }
        } catch { Write-Host "  [!] Test uebersprungen: $($_.Exception.Message)" -ForegroundColor DarkYellow }
    }
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
}

function Test-SysPilotHealth {
    <# Selbsttest: SysPilot (Installation, Config, Log, Module) + Herbert
       (Provider, MCP, Skills, Aktionen). Gibt PASS/WARN/FAIL pro Check
       aus, protokolliert das Ergebnis ins Debug-Log und bietet direkt
       den GitHub-Debug-Report an. #>
    param([switch]$Quiet)
    $spRoot = Split-Path $PSScriptRoot -Parent
    function Add-Res([string]$Area,[string]$Name,[string]$Status,[string]$Detail='') {
        $script:_hr += [pscustomobject]@{ Area=$Area; Name=$Name; Status=$Status; Detail=$Detail }
    }
    $script:_hr = @()

    Write-Host "`n  === SYSPILOT + HERBERT SELBSTTEST ===" -ForegroundColor Cyan
    $ver = ''
    try { $ver = (Get-Content (Join-Path $spRoot 'version.txt') -Raw -ErrorAction Stop).Trim() } catch { }
    Add-Res 'SysPilot' 'Version' $(if($ver){'PASS'}else{'FAIL'}) $ver

    # Config
    $cfgOk = $false
    try { $null = Get-SysPilotConfig; $cfgOk = $true } catch {}
    Add-Res 'SysPilot' 'config.json' $(if($cfgOk){'PASS'}else{'WARN'}) $(if($cfgOk){'lesbar'}else{'fehlerhaft - Defaults werden genutzt'})

    # Module-Funktionen
    $missing = @()
    foreach ($fn in 'Get-SysPilotMcpServers','Invoke-SysPilotAiChat','Show-SysPilotArrowMenu','Write-SysPilotLog','Get-SysPilotToolbox') {
        if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) { $missing += $fn }
    }
    Add-Res 'SysPilot' 'Kern-Funktionen' $(if($missing.Count -eq 0){'PASS'}else{'FAIL'}) $(if($missing.Count -eq 0){'alle vorhanden'}else{"fehlt: $($missing -join ', ')"})

    # Log schreibbar
    try { Write-SysPilotLog 'Selftest gestartet' 'INFO'; $logOk = $true } catch { $logOk = $false }
    Add-Res 'SysPilot' 'Debug-Log' $(if($logOk){'PASS'}else{'FAIL'}) 'logs\syspilot-<datum>.log'

    # Freier Speicher (SysPilot-Laufwerk)
    try {
        $drive = (Split-Path $spRoot -Qualifier).TrimEnd(':')
        if (-not $drive) { $drive = 'C' }
        $freeGB = [math]::Round((Get-PSDrive -Name $drive -ErrorAction Stop).Free / 1GB, 1)
        Add-Res 'SysPilot' 'Freier Speicher' $(if($freeGB -gt 2){'PASS'}elseif($freeGB -gt 0.5){'WARN'}else{'FAIL'}) "${freeGB} GB auf ${drive}:"
    } catch { Add-Res 'SysPilot' 'Freier Speicher' 'WARN' 'nicht pruefbar' }

    # Admin-Hinweis
    Add-Res 'SysPilot' 'Admin-Rechte' $(if(Test-SysPilotAdmin){'PASS'}else{'WARN'}) $(if(Test-SysPilotAdmin){'aktiv'}else{'nicht aktiv - einige Fixes brauchen Admin'})

    # --- Herbert ---
    $prov = @(Get-SysPilotAiProviders | Where-Object { $_.Enabled })
    $reach = 0
    foreach ($p in ($prov | Select-Object -First 4)) {
        try { if ((Test-SysPilotAiProvider -Provider $p -TimeoutSec 4).Ok) { $reach++ } } catch {}
    }
    Add-Res 'Herbert' 'Provider' $(if($prov.Count -eq 0){'FAIL'}elseif($reach -gt 0){'PASS'}else{'WARN'}) "$($prov.Count) aktiv, $reach erreichbar"
    if ($prov.Count -eq 0) { Add-Res 'Herbert' 'Provider-Config' 'FAIL' 'ERSTEINRICHTUNG noetig (kostenlose Keys)' }

    $mcpOn = @()
    try { $mcpOn = @(Get-SysPilotMcpServers | Where-Object { $_.Enabled }) } catch {}
    Add-Res 'Herbert' 'MCP-Server' $(if($mcpOn.Count -gt 0){'PASS'}else{'WARN'}) "$($mcpOn.Count) aktiv"

    $sk = @()
    try { $sk = @(Get-SysPilotLocalSkills) } catch {}
    Add-Res 'Herbert' 'Skills' $(if($sk.Count -ge 3){'PASS'}else{'WARN'}) "$($sk.Count) installiert"

    $act = @()
    try { $act = @(Get-SysPilotKiActions) } catch {}
    Add-Res 'Herbert' 'Aktionen' $(if($act.Count -gt 20){'PASS'}else{'WARN'}) "$($act.Count) registriert"

    $sel = $null
    try { $sel = Get-SysPilotAiLastSelection } catch {}
    Add-Res 'Herbert' 'Letzte Auswahl' 'PASS' $(if($sel -and ($sel.LastProvider -or $sel.LastModel)){"$($sel.LastProvider) / $($sel.LastModel)"}else{'Auto'})

    # Ausgabe
    $fails = @($script:_hr | Where-Object Status -eq 'FAIL')
    $warns = @($script:_hr | Where-Object Status -eq 'WARN')
    foreach ($r in $script:_hr) {
        $col = switch ($r.Status) { 'PASS' {'Green'} 'WARN' {'Yellow'} default {'Red'} }
        $line = "  [{0}] {1,-14} {2}" -f $r.Status, $r.Name, $r.Detail
        if (-not $Quiet) { Write-Host $line -ForegroundColor $col }
    }
    $summary = "Selftest: $($script:_hr.Count) Checks, $($fails.Count) FAIL, $($warns.Count) WARN"
    if (-not $Quiet) {
        Write-Host "`n  $summary" -ForegroundColor $(if($fails.Count){'Red'}elseif($warns.Count){'Yellow'}else{'Green'})
    }
    Write-SysPilotLog $summary 'INFO'
    foreach ($f in $fails) { Write-SysPilotLog "Selftest FAIL: $($f.Area)/$($f.Name) - $($f.Detail)" 'ERROR' }

    return [pscustomobject]@{ Results=$script:_hr; Fails=$fails; Warns=$warns; Summary=$summary }
}

function Send-SysPilotDebugReport {
    <# Wertet die letzten Debug-Logs aus (Fehler-Muster + letzter Auszug),
       laesst Herbert optional Loesungsansaetze formulieren und meldet das
       Ganze als GitHub-Issue (gh CLI oder vorbefuelltes Browser-Formular).
       Repo: Habermann76/SysPilot. #>
    param([int]$Hours = 48, [switch]$NoAiAnalysis)
    $spRoot = Split-Path $PSScriptRoot -Parent

    Write-Host "`n  === DEBUG-REPORT an GitHub ===" -ForegroundColor Cyan

    # 1) Log-Material sammeln (Dateien im Zeitraum + immer die neueste)
    $cutoff = (Get-Date).AddHours(-$Hours)
    $logFiles = @(Get-SysPilotLogFiles)
    $lines = @()
    $i = 0
    foreach ($f in $logFiles) {
        $i++
        if ($i -gt 4) { break }
        if ($f.LastWriteTime -lt $cutoff -and $i -gt 1) { continue }
        try {
            $raw = Get-Content $f.FullName -Encoding UTF8 -ErrorAction Stop
            foreach ($ln in $raw) {
                if ($ln -match '^(\d{2}:\d{2}:\d{2}\.\d{3}) \[(ERROR|WARN)\] (.*)$') {
                    $lines += [pscustomobject]@{ Time=$Matches[1]; Level=$Matches[2]; Msg=$Matches[3] }
                }
            }
        } catch {}
    }
    # Muster: normalisieren (Zahlen/Pfade raus) + haeufigkeit
    $pat = @{}
    foreach ($l in $lines) {
        $norm = $l.Msg -replace '\d+', 'N' -replace '[A-Za-z]:\\[^\s]*', '<pfad>'
        if ($norm.Length -gt 160) { $norm = $norm.Substring(0,160) }
        if (-not $pat.ContainsKey($norm)) { $pat[$norm] = @{ Count=0; Level=$l.Level; First=$l.Time } }
        $pat[$norm].Count++
    }
    $top = @($pat.GetEnumerator() | Sort-Object { $_.Value.Count } -Descending | Select-Object -First 15)

    # Letzter Roh-Auszug (letzte 60 Zeilen aller aktuellen Logs)
    $tail = @()
    foreach ($f in @(Get-SysPilotLogFiles | Select-Object -First 1)) {
        try { $tail = @(Get-Content $f.FullName -Encoding UTF8 -Tail 60 -ErrorAction Stop) } catch {}
    }

    if ($lines.Count -eq 0 -and $tail.Count -eq 0) {
        Write-Host '  Keine Log-Eintraege gefunden - nichts zu melden.' -ForegroundColor Yellow
        Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; return
    }
    Write-Host "  $($lines.Count) ERROR/WARN-Zeilen, $($top.Count) Muster, Log-Auszug: $($tail.Count) Zeilen" -ForegroundColor DarkGray

    # 2) Herbert-Analyse (Loesungsansaetze) - optional per KI
    $aiText = ''
    if (-not $NoAiAnalysis) {
        $reachable = $false
        try {
            $reachable = [bool](@(Get-SysPilotAiProviders | Where-Object { $_.Enabled }) | Select-Object -First 1)
        } catch {}
        if ($reachable) {
            Write-Host '  Herbert analysiert die Muster (Loesungsansaetze) ...' -ForegroundColor DarkYellow
            $prompt = @"
Du bist SysPilot-Debugger. Unten stehen Fehler-/Warn-Muster aus dem SysPilot-Log (Windows-Wartungstool, PowerShell/WPF).
Gib KEINE Code-Aenderungen, sondern pro Muster maximal 3 kurze deutsche Saetze: wahrscheinlichste Ursache + Loesungsansatz/Workaround. Wenn ein Muster nicht genug Info hat, sag das.

MUSTER:
$(( $top | ForEach-Object { "- [x$($_.Value.Count)] $($_.Key)" } ) -join "`n")
"@
            $r = Invoke-SysPilotAiChat -Prompt $prompt -System 'Du bist ein knapper technischer Debugger. Antworte nur mit der Analyse, keine Einleitung.' -TimeoutSec 75
            if ($r.Ok -and $r.Text) { $aiText = $r.Text.Trim() }
            else { Write-Host "  [!] Keine KI-Antwort ($($r.Error)) - Report ohne Analyse." -ForegroundColor DarkYellow }
        } else {
            Write-Host '  Kein Provider erreichbar - Report ohne KI-Analyse.' -ForegroundColor DarkYellow
        }
    }

    # 3) Issue-Body bauen
    $ver = ''
    try { $ver = (Get-Content (Join-Path $spRoot 'version.txt') -Raw -ErrorAction Stop).Trim() } catch { }
    $topMsg = if ($top.Count) { $top[0].Key } else { 'allgemeiner Log-Auszug' }
    $title = "Auto-Debug $ver`: $($topMsg.Substring(0,[Math]::Min(70,$topMsg.Length)))"
    $title = ($title -replace '[\r\n`]+',' ').Trim()

    $body = [System.Text.StringBuilder]::new()
    [void]$body.AppendLine("## Auto-Debug-Report (SysPilot $ver)")
    [void]$body.AppendLine("")
    [void]$body.AppendLine("- **Erstellt:** $((Get-Date).ToString('yyyy-MM-dd HH:mm'))")
    [void]$body.AppendLine("- **Host:** $env:COMPUTERNAME | User: $env:USERNAME | Admin: $(Test-SysPilotAdmin)")
    [void]$body.AppendLine("- **Zeitraum:** letzte $Hours h | **Muster:** $($top.Count) | **ERROR/WARN:** $($lines.Count)")
    [void]$body.AppendLine("")
    if ($top.Count) {
        [void]$body.AppendLine("### Fehler-Muster (Haeufigkeit)")
        foreach ($p in $top) {
            [void]$body.AppendLine("- [x$($p.Value.Count)] $($p.Key)  ``($($p.Value.Level), zuerst $($p.Value.First))``")
        }
        [void]$body.AppendLine("")
    }
    if ($aiText) {
        [void]$body.AppendLine("### Loesungsansaetze (HerbertAnalyse)")
        [void]$body.AppendLine("")
        [void]$body.AppendLine('```')
        [void]$body.AppendLine($aiText)
        [void]$body.AppendLine('```')
        [void]$body.AppendLine("")
    }
    [void]$body.AppendLine("### Log-Auszug (letzte Zeilen)")
    [void]$body.AppendLine('```')
    foreach ($t in $tail) { [void]$body.AppendLine($t) }
    [void]$body.AppendLine('```')
    $bodyText = $body.ToString()

    # VORSCHAU
    Write-Host "`n  --- VORSCHAU Issue ---" -ForegroundColor Cyan
    Write-Host "  Titel: $title" -ForegroundColor White
    Write-Host ($bodyText.Substring(0,[Math]::Min(2500,$bodyText.Length))) -ForegroundColor DarkGray
    if ($bodyText.Length -gt 2500) { Write-Host '  ... (verkuerzt, volle Fassung im Issue)' -ForegroundColor DarkGray }

    if (-not (Confirm-SysPilot "Debug-Report so als GitHub-Issue melden?")) {
        Write-Host '  Abgebrochen.' -ForegroundColor DarkYellow
        return
    }

    # 4) Senden: gh CLI bevorzugt, sonst Browser-Formular
    $sent = $false
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if ($gh) {
        $tmp = Join-Path $env:TEMP ("syspilot-issue-{0}.md" -f [guid]::NewGuid().ToString('N').Substring(0,8))
        Set-Content -Path $tmp -Value $bodyText -Encoding UTF8
        try {
            $out = & gh issue create --repo Habermann76/SysPilot --title $title --body-file $tmp --label bug 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) { $out = & gh issue create --repo Habermann76/SysPilot --title $title --body-file $tmp 2>&1 | Out-String }
            if ($LASTEXITCODE -eq 0) {
                $sent = $true
                $url = ([regex]::Match($out,'https://github\.com/[^\s]+')).Value
                Write-Host "  [OK] Issue erstellt: $url" -ForegroundColor Green
            } else {
                Write-Host "  [!] gh fehlgeschlagen: $($out.Trim().Substring(0,[Math]::Min(200,$out.Trim().Length)))" -ForegroundColor Red
            }
        } catch { Write-Host "  [!] gh-Fehler: $($_.Exception.Message)" -ForegroundColor Red }
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
    if (-not $sent) {
        $encT = [uri]::EscapeDataString($title)
        $encB = [uri]::EscapeDataString($bodyText)
        $url = "https://github.com/Habermann76/SysPilot/issues/new?title=$encT&body=$encB"
        try { Start-Process $url; Write-Host '  Browser-Formular geoeffnet - bitte Absenden klicken.' -ForegroundColor Green }
        catch { Write-Host "  [!] Weder gh noch Browser moeglich.`n$url" -ForegroundColor Red }
    }
    Write-SysPilotLog "Debug-Report versendet (gh=$([bool]$gh), sent=$sent)" 'INFO'
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
}

function Get-SysPilotKiActions {
    <# Registry der per Chat anbiotbaren Aktionen. Run = Scriptblock,
       laeuft im aktuellen Session-State (Modul-Funktionen verfuegbar,
       Ausgaben via Write-Host/Streams werden mitgefangen).
       Risk: low = 1 Klick, medium/high = Bestaetigungs-Dialog.
       NICHT-interaktive Funktionen verwenden (kein Confirm/Read-Host,
       das wuerde im Chat-Runspace haengen). #>
    return @(
        @{ Id='flushdns'; Label='DNS-Cache leeren'; Risk='low'; NeedsAdmin=$false
           Desc='ipconfig /flushdns - loest DNS-Aufloesungs-Probleme.'
           Run={ if (Clear-SysPilotDnsCache) { 'DNS-Cache geleert.' } else { 'DNS-Cache-Leerung uebersprungen (Admin-Rechte noetig).' } } }
        @{ Id='freeram'; Label='RAM freigeben'; Risk='low'; NeedsAdmin=$false
           Desc='Arbeitsseiten aller Prozesse verkleinern + Standby-Cache leeren (Admin-Teil).'
           Run={ Invoke-SysPilotFreeRam *>&1 | Out-String } }
        @{ Id='restart-explorer'; Label='Explorer neu starten'; Risk='low'; NeedsAdmin=$false
           Desc='Startmenue/Taskleiste/Explorer neu starten - bei Haengern.'
           Run={ Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 600; Start-Process explorer.exe; 'Explorer neu gestartet.' } }
        @{ Id='renew-ip'; Label='IP-Adresse erneuern'; Risk='medium'; NeedsAdmin=$true
           Desc='DHCP-Lease erneuern (ipconfig /release + /renew + flushdns) - bei Netzwerkproblemen. Kurzer Internet-Ausfall moeglich.'
           Run={ & ipconfig /release *>&1 | Out-Null; & ipconfig /renew *>&1 | Out-Null; & ipconfig /flushdns *>&1 | Out-Null; 'IP-Adresse erneuert, DNS-Cache geleert.' } }
        @{ Id='cleanup-temp'; Label='Temp/Cache bereinigen'; Risk='medium'; NeedsAdmin=$false
           Desc='SysPilot-Bereinigung: Temp-Dateien, Update-Caches, Miniaturbilder (aeltere Dateien). Dateien werden endgueltig geloescht.'
           Run={ Invoke-SysPilotCleanup *>&1 | Out-String } }
        @{ Id='repair-spooler'; Label='Druck-Spooler reparieren'; Risk='medium'; NeedsAdmin=$true
           Desc='Druckwarteschlange leeren + Spooler-Dienst neu starten.'
           Run={ Invoke-SysPilotRepairSpooler *>&1 | Out-String } }
        @{ Id='repair-proxy'; Label='Proxy zuruecksetzen'; Risk='medium'; NeedsAdmin=$true
           Desc='WinHTTP- und User-Proxy auf Direktverbindung zuruecksetzen.'
           Run={ Invoke-SysPilotRepairProxy *>&1 | Out-String } }
        @{ Id='repair-firewall'; Label='Firewall-Profile zuruecksetzen'; Risk='medium'; NeedsAdmin=$true
           Desc='Alle Firewall-Profile auf Windows-Standard zuruecksetzen - oeffnet ggf. bisher geblockte Ports.'
           Run={ Invoke-SysPilotRepairFirewall *>&1 | Out-String } }
        @{ Id='repair-perfcounters'; Label='Performance-Counter reparieren'; Risk='medium'; NeedsAdmin=$true
           Desc='Defekte Windows-Performance-Counter neu aufbauen (lodctr /R, einige Minuten).'
           Run={ Invoke-SysPilotRepairPerfCounters *>&1 | Out-String } }
        @{ Id='empty-recycle'; Label='Papierkorb leeren'; Risk='high'; NeedsAdmin=$false
           Desc='ALLE Dateien im Papierkorb werden ENDBUETIG geloescht - NICHT wiederherstellbar!'
           Run={ Clear-RecycleBin -Force -ErrorAction SilentlyContinue; 'Papierkorb geleert.' } }
        @{ Id='ki-keys-import'; Label='KI-API-Keys suchen + importieren'; Risk='medium'; NeedsAdmin=$false
           Desc='Sucht .txt-Dateien mit API-Keys/Base-URLs in Dokumente/Desktop/Downloads und importiert sie als KI-Provider (OpenAI-kompatibel).'
           Run={
               $c = @(Get-SysPilotAiKeyFileCandidates)
               if ($c.Count -eq 0) { return 'Keine Key-Dateien gefunden (Dokumente/Desktop/Downloads).' }
               $entries = @()
               foreach ($f in $c) { $e = Import-SysPilotAiKeyFile -Path $f; if ($e) { $entries += $e } }
               if ($entries.Count -eq 0) { return "($($c.Count) Dateien gefunden, aber keine verwertbaren Eintraege.)" }
               $r = Import-SysPilotAiProvidersData -Entries $entries
               "Import: $($r.Added) neue Provider, $($r.Updated) aktualisiert (aus $($c.Count) Key-Dateien)."
           } }
        @{ Id='ki-cleanup'; Label='KI-Provider bereinigen'; Risk='low'; NeedsAdmin=$false
           Desc='Testet alle konfigurierten KI-Provider und deaktiviert unbrauchbare (nicht erreichbar, keine Modelle).'
           Run={
               $r = Invoke-SysPilotAiProviderCleanup
               $dead = @($r.Disabled) -join ', '
               "Bereinigt: $($r.Tested) getestet" + $(if($dead){", deaktiviert: $dead"}else{', alle Provider OK'}) + '.'
           } }
        @{ Id='ki-apps'; Label='KI-Tools installieren'; Risk='low'; NeedsAdmin=$false
           Desc='Oeffnet den Herbert-Katalog lokaler KI-Tools (Ollama, LM Studio, PocketAI, Layla Server, Jan, GPT4All ...) mit winget-Installation.'
           Run={ Show-SysPilotAiAppsInstall; 'KI-Tool-Katalog geoeffnet.' } }
        @{ Id='ki-models'; Label='KI-Modelle suchen/herunterladen'; Risk='medium'; NeedsAdmin=$false
           Desc='HuggingFace-GGUF-Suche (uncensored, abliterated, heretic, q4_k_m, instruct, coder ...) mit Download in den richtigen Modell-Ordner.'
           Run={ Show-SysPilotAiModelFinder; 'Modell-Suche geoeffnet.' } }
        @{ Id='ki-guided-install'; Label='KI-Tool installieren (Herbert gefuehrt)'; Risk='medium'; NeedsAdmin=$false
           Desc='Fragt was noetig ist, schlaegt passende Tools/Repos vor (Layla, Open WebUI, GitHub-Repos) und installiert gefuehrt per Skript.'
           Run={ Show-SysPilotAiGuidedInstall; 'Installations-Assistent geoeffnet.' } }
        @{ Id='ki-manager'; Label='Herbert-Manager (Skills + Konnektoren)'; Risk='low'; NeedsAdmin=$false
           Desc='Verwaltet Skills (skills.sh-Registry, kostenlos) und MCP-Konnektoren (awesome-mcp-servers + GitHub-Kataloge).'
           Run={ Show-SysPilotHerbertManager; 'Herbert-Manager geoeffnet.' } }
        @{ Id='pm-install-missing'; Label='Fehlende Paketmanager installieren'; Risk='medium'; NeedsAdmin=$false
           Desc='Bietet alle nicht installierten Paketmanager an (Bun, Homebrew, WSL-Distros inkl. apt/dnf-PMs) - SysPilot richtet sie ein.'
           Run={ if (Get-Command Show-SysPilotPackageManagerInstallMenu -ErrorAction SilentlyContinue) { Show-SysPilotPackageManagerInstallMenu; 'PM-Install-Menue geoeffnet.' } else { 'PackageManagers-Modul nicht geladen.' } } }
        @{ Id='browser-research'; Label='Web-Recherche mit eigenem Browser'; Risk='low'; NeedsAdmin=$false
           Desc='Nutzt einen konfigurierten Browser-MCP-Server (BrowserOS, Chrome, Firefox) zum Oeffnen/Lesen von Seiten, dann Zusammenfassung per KI.'
           Run={ Invoke-SysPilotBrowserPageTask -Task 'recherche'; 'Browser-Aufgabe gestartet.' } }
        @{ Id='browser-translate'; Label='Seite uebersetzen (Browser-MCP)'; Risk='low'; NeedsAdmin=$false
           Desc='Oeffnet eine URL im eigenen Browser (MCP), liest den Inhalt und uebersetzt ihn per KI.'
           Run={ Invoke-SysPilotBrowserPageTask -Task 'translate'; 'Uebersetzung gestartet.' } }
        @{ Id='ki-setup'; Label='KI-Setup-Assistent (alles)'; Risk='low'; NeedsAdmin=$false
           Desc='Zentrale Anlaufstelle: Provider+Keys, Router (OmniRoute/FreeLLMAPI), KI-Clients (VS Code, Claude, Perplexity, Devin), Server-Tools, Client-Provider-Bruecke, Modelle, News.'
           Run={ Show-SysPilotKiSetupWizard; 'KI-Setup-Assistent geoeffnet.' } }
        @{ Id='ki-clients'; Label='KI-Clients installieren'; Risk='low'; NeedsAdmin=$false
           Desc='Desktop-KI-Apps mit Status: VS Code, Claude Desktop/Code, Devin (Windsurf), Perplexity, Comet, LM Studio, Cherry Studio, Chatbox, PocketAI, Layla.'
           Run={ Show-SysPilotKiClientsMenu; 'KI-Client-Katalog geoeffnet.' } }
        @{ Id='ki-bridge'; Label='Client mit Provider verbinden'; Risk='low'; NeedsAdmin=$false
           Desc='Verdrahtet Claude Code (~/.claude/settings.json) oder zeigt OpenAI-Config-Anleitung fuer lokale Endpunkte (Ollama, LM Studio, OmniRoute, FreeLLMAPI).'
           Run={ Show-SysPilotKiBridgeMenu; 'Provider-Bruecke geoeffnet.' } }
        @{ Id='ki-news'; Label='KI-News-Feed'; Risk='low'; NeedsAdmin=$false
           Desc='Aktuelle KI-News von Reddit (r/LocalLLaMA, r/artificial) + HackerNews - kostenlos, kein Key noetig.'
           Run={ $items = @(Get-SysPilotAiNewsFeed -Max 10); if ($items.Count -eq 0) { return 'Keine News erreichbar.' }; ($items | ForEach-Object { "- [$($_.Source)] $($_.Title)" }) -join "`n" } }
        @{ Id='ki-extensions'; Label='Browser-Extensions empfehlen'; Risk='low'; NeedsAdmin=$false
           Desc='Kuratierte Chrome-Extensions oeffnen: Reddit RSS Fixer (News-Feed), uBlock, Dark Reader, JSON Viewer, Tampermonkey, YouTube-Tools.'
           Run={ Show-SysPilotKiExtensionsMenu; 'Extension-Katalog geoeffnet.' } }
        @{ Id='rss-feeds'; Label='RSS-Feeds vorschlagen'; Risk='low'; NeedsAdmin=$false
           Desc='Kuratierte Feed-Vorschlaege (KI, Tech, Security, deutsch) + RSS-Reader-Empfehlungen (Feeder, Feedbro, FreshRSS).'
           Run={ $f = @(Get-SysPilotRssFeedSuggestions); $r = @(Get-SysPilotRssReaderApps | Select-Object -First 3); $txt = "RSS-Reader: " + (($r | ForEach-Object { $_.Name }) -join ', ') + "`n`nFeeds:`n" + (($f | ForEach-Object { "- $($_.Name): $($_.Url)" }) -join "`n"); return $txt } }
        @{ Id='ki-browsers'; Label='Browser installieren'; Risk='low'; NeedsAdmin=$false
           Desc='Chrome, Brave, Tor Browser, Firefox, Edge - Status + winget-Installation + Tor-Hinweise.'
           Run={ Show-SysPilotKiBrowsersMenu; 'Browser-Menue geoeffnet.' } }
        @{ Id='ki-essentials'; Label='Wichtige Apps prüfen'; Risk='low'; NeedsAdmin=$false
           Desc='Prueft Installationen (LibreOffice, Notepad++, 7-Zip, VLC, SumatraPDF, PDF24, GIMP, KeePassXC, PowerToys ...) und bietet fehlende + kostenlose Alternativen an.'
           Run={ Show-SysPilotKiEssentialsMenu; 'Essential-Apps geprueft.' } }
        @{ Id='miniflux-setup'; Label='Miniflux einrichten (Self-Host RSS)'; Risk='medium'; NeedsAdmin=$false
           Desc='Self-hosted RSS-Reader (unbegrenzt): Docker-Compose-Stack (Miniflux+Postgres), Docker-Install, Cloud-Optionen (Oracle Free Tier), feste URL via Tailscale Funnel/Cloudflare-Tunnel, OPML-Feed-Export.'
           Run={ Show-SysPilotMinifluxSetup; 'Miniflux-Setup geoeffnet.' } }
        @{ Id='seclab'; Label='Security-Lab einrichten (Kali WSL + unzensiertes Modell)'; Risk='medium'; NeedsAdmin=$false
           Desc='Gefuehrtes Security-Lab: Kali Linux in WSL installieren/starten, unzensierte/abliterated/heretic GGUF-Modelle via HuggingFace-Suche laden, kurze Security-Einfuehrung + Rechtshinweise (nur eigene Systeme, autorisierte Tests).'
           Run={ Show-SysPilotSecLabSetup; 'Security-Lab-Setup beendet.' } }
        @{ Id='tv-setup'; Label='TV/Mobil-Setup (Android TV/Fire TV/Smartphone/Tablet: Debloat, Sideload, Apps)'; Risk='medium'; NeedsAdmin=$false
           Desc='ADB-Verbindung (IP/Pairing/Port 5555), CleanYourTV-aehnlicher Debloat via pm disable-user (reversibel + Backup), APK-Sideload, KodiRoll/VYPN/SquiffNet/StreamFlix-Katalog, Launcher, Fire-TV-Downloader-Codes, TroyPoint/F-Droid/Obtainium/Aurora/APKMirror-Quellen. Smartphone/Tablet: Android via ADB identisch; iOS nur ueber AltStore PAL/SideStore moeglich (Apple-Signatur 7 Tage, kein direktes APK).'
           Run={ Show-SysPilotTvSetup; 'TV/Mobil-Setup geoeffnet.' } }
        @{ Id='mobile-sideload'; Label='Smartphone/Tablet-Sideload (Android + iOS)'; Risk='low'; NeedsAdmin=$false
           Desc='Gefuehrter Sideload-Assistent: Android via ADB (USB/Wireless Debugging), iPhone/iPad nur ueber AltStore PAL/SideStore (kein direktes APK moeglich - Apple-Signatur 7 Tage). App-Quellen: F-Droid, Obtainium, Aurora Store, APKMirror, TroyPoint.'
           Run={ Show-SysPilotMobileSideload; 'Mobile-Sideload-Guide beendet.' } }
        @{ Id='extension-policy'; Label='Extension-Policy-Bloecke verwalten (Browser "verwaltet"?)'; Risk='medium'; NeedsAdmin=$false
           Desc='Listet ExtensionSettings-Policies (Sync-Schutz) pro Browser und erklaert den "organisationsverwaltet"-Effekt: gesperrte Browser-Einstellungen (DNS, Cookies, Tracking-Schutz). Erlaubt Aufheben - nur SysPilot-Blocks oder komplette Policy. Sync kann entfernte Extensions erneut installieren.'
           Run={ Show-SysPilotExtensionPolicyManager; 'Policy-Manager beendet.' } }
        @{ Id='ext-manager'; Label='SysPilot Extension-Manager installieren'; Risk='low'; NeedsAdmin=$false
           Desc='Installiert die eigene Browser-Extension (chrome.management): Suche, Enable/Disable, echtes Entfernen, Browser-Detailseite, HTML-Export/Import als Sync zwischen Browsern. Kopiert den Ordnerpfad (AppData\Local) und oeffnet chrome://extensions - im Ordnerdialog oben die Adresszeile anklicken, Strg+V, Enter, Ordner auswaehlen.'
           Run={ if (Get-Command Install-SysPilotExtManagerExtension -ErrorAction SilentlyContinue) { $r = Install-SysPilotExtManagerExtension; if ($r.Ok) { $r.Message } else { "Fehler: $($r.Message)" } } else { 'Extensions-Modul nicht geladen - bitte SysPilot neu starten oder den Ext-Manager-Button im Extension-Manager nutzen.' } } }
        @{ Id='herbert-interests'; Label='Herbert-Interessen einrichten'; Risk='low'; NeedsAdmin=$false
           Desc='Themen-Profil fuer den Assistenten: Gesundheit, Longevity, Psychosen/Schizophrenie, ADHS, Autismus, Politik, Krieg, Games (Steam/GOG/Epic), Linux/Windows, Deskmodder, Reddit, Aliens/UFO, Hobbies u.v.m. - Herbert praesentiert passende Infos/News proaktiv.'
           Run={ Show-SysPilotHerbertInterestsSetup; 'Interessen gespeichert.' } }
        @{ Id='arzt-vorbereitung'; Label='Arztgespraech vorbereiten (KI-Vorabkonsultation)'; Risk='low'; NeedsAdmin=$false
           Desc='Oeffnet Herbert mit strukturierter Vorlage: Symptome, Verlauf, Medikamente, eigene Ueberlegungen - Ergebnis: Frageliste + moegliche Diagnosen-Richtungen + Gespraechsleitfaden fuer den Arzt.'
           Run={ Show-SysPilotAiQuickAsk -Prompt 'Ich moechte ein bevorstehendes Arztgespraech vorbereiten. Hilf mir step-by-step: 1) Frag mich strukturiert nach Symptomen (seit wann, Haeufigkeit, Ausloeser, Verlauf), relevanter Vorgeschichte und bisherigen Behandlungen. 2) Schlage gemeinsam moegliche Erklaerungsrichtungen vor (keine Diagnose - nur Hypothesen zum Durchdenken). 3) Erstelle am Ende eine Gespraechs-Vorlage: was ich erzaehlen will, was ich erfragen will, welche Unterlagen/Tests ich mitbringen sollte. Denk empathisch, ADHS-verstaendlich, kurze Schritte.' -Title 'Arzt-Vorbereitung'; 'Arzt-Vorbereitung gestartet.' } }
        @{ Id='rss-clients'; Label='RSS-Clients einrichten (Android/iOS/Desktop + QR)'; Risk='low'; NeedsAdmin=$false
           Desc='Miniflux-Client-Katalog (Capy/FluxNews/FeedMe/NetNewsWire/Unread/Reeder/Fluent Reader), QR-Code zum Abscannen, ADB-Play-Store-Assist, Fever/Google-Reader-API-Anleitung.'
           Run={ Show-SysPilotRssClientSetup; 'RSS-Client-Setup geoeffnet.' } }
        @{ Id='rss-opml'; Label='RSS-Feeds als OPML exportieren'; Risk='low'; NeedsAdmin=$false
           Desc='Schreibt die kuratierten Feed-Vorschlaege als OPML-Datei (Documents\SysPilot) - importierbar in Miniflux/FreshRSS/Feedly.'
           Run={ $p = Export-SysPilotRssOpml; "OPML exportiert: $p - importierbar in jeden RSS-Reader." } }
        @{ Id='cf-named-tunnel'; Label='Feste Miniflux-URL per Cloudflare named tunnel'; Risk='low'; NeedsAdmin=$false
           Desc='Gefuehrtes Setup: einmaliger Browser-Login, dann erstellt SysPilot Tunnel+DNS+Service selbst. Feste HTTPS-URL statt wechselnder Quick-Tunnel.'
           Run={ Show-SysPilotCfNamedTunnel; 'Named-Tunnel-Setup beendet.' } }
        @{ Id='ts-funnel'; Label='Feste Miniflux-URL per Tailscale Funnel'; Risk='low'; NeedsAdmin=$false
           Desc='Kostenlose feste HTTPS-URL (https://<pc>.<tailnet>.ts.net) auf den lokalen Miniflux - funktioniert hinter NAT/Hotspot, kein Domain noetig. Einmal-Login, dann Service.'
           Run={ Show-SysPilotTailscaleFunnel; 'Tailscale-Funnel-Setup beendet.' } }
        @{ Id='rss-windows-client'; Label='RSS-Client Windows einrichten (Fluent Reader + Miniflux)'; Risk='low'; NeedsAdmin=$false
           Desc='Startet Fluent Reader (MS Store) und zeigt die Miniflux-Fever-/Google-Reader-Credentials aus ZUGANG.txt zum Eintragen.'
           Run={ $z = Join-Path $env:LOCALAPPDATA 'SysPilot\miniflux\ZUGANG.txt'; if (Test-Path $z) { Get-Content $z | Select-String 'Fever|Google|api_key|REST|URL fest' | ForEach-Object { $_.Line } } else { 'ZUGANG.txt nicht gefunden - erst Miniflux-Setup.' }; try { Start-Process 'shell:AppsFolder\25286HaoyuanLiu.FluentReader_5bmsqm5p4m2q6!App' } catch {}; 'Fluent Reader gestartet - Service-Typ Miniflux, Endpoint https://<host>, REST-API-Key siehe oben.' } }
        @{ Id='oracle-miniflux'; Label='Miniflux auf Oracle Always Free einrichten'; Risk='medium'; NeedsAdmin=$false
           Desc='Exportiert cloud-init Script: Oracle ARM-VM startet Docker+Miniflux+Postgres automatisch (dauerhaft kostenlos, keine Jahresgebuehr).'
           Run={ $r = Export-SysPilotOracleCloudInit; "cloud-init exportiert: $($r.Path) - Miniflux-PW: $($r.Password)" } }
        @{ Id='miniflux-doctor'; Label='Miniflux-Doctor (Diagnose & Fixes)'; Risk='low'; NeedsAdmin=$false
           Desc='Prueft Docker/Container/Port/Tunnel/Service und bietet Ein-Klick-Fixes fuer alle Miniflux-Wege.'
           Run={ Show-SysPilotMinifluxDoctor; 'Doctor beendet.' } }
        @{ Id='miniflux-guide'; Label='Oracle-Setup Schritt-fuer-Schritt'; Risk='low'; NeedsAdmin=$false
           Desc='ADHD-taugliche 6-Schritt-Anleitung zu Oracle Always Free mit Direkt-Links - ein Schritt nach dem anderen.'
           Run={ Show-SysPilotOracleGuide; 'Anleitung beendet.' } }
        @{ Id='ki-doctor'; Label='KI-Doctor (Clients, Endpunkte, Fixes)'; Risk='low'; NeedsAdmin=$false
           Desc='Prueft KI-Clients, Provider-Endpunkte, CLI-Tools und Claude-Code-Config; bietet Fixes an.'
           Run={ Show-SysPilotKiDoctor; 'KI-Doctor beendet.' } }
        @{ Id='wsl-guide'; Label='WSL Ersteinrichtung Schritt-fuer-Schritt'; Risk='low'; NeedsAdmin=$false
           Desc='ADHS-Guide zu WSL: Feature-Enable, Ubuntu-Install, User-Anlage, Updates - mit YouTube-Videos pro Schritt.'
           Run={ Show-SysPilotWslFirstRunGuide; 'WSL-Guide beendet.' } }
        @{ Id='herbert-setup'; Label='Herbert Selbstcheck (Provider, MCP, Skills, Keys)'; Risk='low'; NeedsAdmin=$false
           Desc='Inventarisiert die Herbert-Einrichtung und schlaegt fehlende Erweiterungen vor - oeffnet die passenden Manager direkt.'
           Run={ Show-SysPilotHerbertSelfCheck; 'Selbstcheck beendet.' } }
        @{ Id='selftest'; Label='SysPilot+Herbert Selbsttest'; Risk='low'; NeedsAdmin=$false
           Desc='Prueft SysPilot (Version, Config, Log, Speicher) und Herbert (Provider, MCP, Skills, Aktionen) - PASS/WARN/FAIL mit Tipps.'
           Run={ $r = Test-SysPilotHealth -Quiet; $r.Summary + ' - Details im Konsolen-Fenster via Tool selftest.' } }
        @{ Id='debug-report'; Label='Debug-Log auswerten + GitHub-Issue melden'; Risk='medium'; NeedsAdmin=$false
           Desc='Wertet die letzten 48h Logs aus (Fehler-Muster), laesst Herbert Loesungsansaetze formulieren und erstellt ein GitHub-Issue (gh oder Browser).'
           Run={ Send-SysPilotDebugReport; 'Debug-Report beendet.' } }
        @{ Id='model-cleanup'; Label='Modell-Cleanup (ungenuetzte GGUFs loeschen)'; Risk='medium'; NeedsAdmin=$false
           Desc='Listet alle lokalen Modelle (Ollama, LM Studio, Jan, Layla, PocketAI, LlamaApp, HF-Cache) mit Groesse - loescht was nicht gebraucht wird.'
           Run={ Show-SysPilotModelCleanup; 'Cleanup beendet.' } }
        @{ Id='model-fit'; Label='Modell passend zur Hardware suchen'; Risk='low'; NeedsAdmin=$false
           Desc='Zeigt RAM/VRAM-Empfehlung und oeffnet die Modell-Suche mit automatischer Groessenwahl.'
           Run={ $f = Get-SysPilotHardwareModelFit; "Hardware: $($f.RamGB) GB RAM, $($f.VramGB) GB VRAM -> $($f.Label), Quant $($f.Quant)"; Show-SysPilotAiModelFinder; 'Modellsuche beendet.' } }
        @{ Id='llamacpp'; Label='llama.cpp Server (Vulkan/CUDA/ROCm, eigene GGUF)'; Risk='medium'; NeedsAdmin=$false
           Desc='Installiert den passenden llama.cpp-Build (Auto: Vulkan/CUDA/ROCm/SYCL/CPU je nach CPU+GPU), waehlt eine GGUF und startet den OpenAI-kompatiblen Server als lokalen Provider.'
           Run={ Show-SysPilotLlamaCppMenu; 'llama.cpp-Menue geschlossen.' } }
        @{ Id='herbert-capability'; Label='Faehigkeit besorgen (MCP/Skill suchen+installieren)'; Risk='medium'; NeedsAdmin=$false
           Desc='Herbert sucht selbsttaetig MCP-Server/Skills fuer einen Bedarf (z.B. websuche, browser, datenbank), installiert+aktiviert den besten Kandidaten. Token/Args fuehren zu Prompt + oeffnen der noetigen Seite.'
           Run={
               $need = Read-SysPilotInput 'Welche Faehigkeit/Problem? (z.B. websuche, browser, datenbank, pdf)' '' 'Herbert'
               if (-not $need) { return 'Abgebrochen.' }
               Install-SysPilotHerbertCapability -Need $need
               'Faehigkeits-Installation beendet.'
           } }
        @{ Id='herbert-permissions'; Label='Permissions (Modus + Overrides)'; Risk='low'; NeedsAdmin=$false
           Desc='Cline/Devin-Style: Modus Fragen/Auto-allow/Bypass + pro Aktion und MCP-Werkzeug Erlauben/Fragen/Blockieren.'
           Run={ Show-SysPilotHerbertPermissions; 'Permissions-Fenster geschlossen.' } }
        @{ Id='herbert-extensions'; Label='Installierte MCP + Skills (Ueberblick + Katalog)'; Risk='low'; NeedsAdmin=$false
           Desc='Listet installierte MCP-Server (aktivierbar) und Skills, oeffnet den vollen Katalog (Herbert-Manager).'
           Run={ Show-SysPilotHerbertExtensions; 'Ueberblick geschlossen.' } }
        @{ Id='rss-center'; Label='RSS-Center (Interessengebiete + Import)'; Risk='low'; NeedsAdmin=$false
           Desc='Waehlt Interessengebiete aus oeffentlichen Feed-Katalogen (~1200 Feeds), exportiert sortiertes OPML oder importiert per Miniflux-API in Kategorien.'
           Run={ Show-SysPilotRssCenter; 'RSS-Center geschlossen.' } }
        @{ Id='herbert-api'; Label='Herbert-API + MCP (Provider fuer VS Code/Cline)'; Risk='low'; NeedsAdmin=$false
           Desc='Startet den OpenAI-kompatiblen Herbert-Endpunkt (127.0.0.1:8377/v1) als Provider fuer externe KI-Tools und/oder traegt Herbert als MCP-Server in VS Code/Cline/Windsurf ein.'
           Run={ Show-SysPilotHerbertApiMenu; 'Herbert-API-Menue geschlossen.' } }
        @{ Id='browser-ext'; Label='Browser-Extension installieren (Chrome/Firefox)'; Risk='low'; NeedsAdmin=$false
           Desc='Installiert die Herbert-Browser-Extension (Zusammenfassen, Uebersetzen, Transkript, Assistent, Kontextmenue) - nutzt die lokale Herbert-API.'
           Run={ Install-SysPilotBrowserExtension; 'Extension-Installations-Anleitung gezeigt.' } }
        @{ Id='provider-key'; Label='Provider-API-Key-Assistent'; Risk='low'; NeedsAdmin=$false
           Desc='Oeffnet die Signup-Seite eines KI-Providers, Key einfuegen, Provider wird eingetragen + getestet. Captcha bleibt manuell.'
           Run={ Show-SysPilotProviderKeyAssistant; 'Provider-Key-Assistent beendet.' } }
        @{ Id='yt-scout'; Label='YouTube-Key-Scout (Gratis-Provider aus Videos)'; Risk='low'; NeedsAdmin=$false
           Desc='Sucht YouTube-Videos ueber kostenlose LLM-API-Keys, holt Transkripte, extrahiert Provider via Herbert, oeffnet Signup, schreibt Key-Datei + Provider.'
           Run={ Show-SysPilotYoutubeKeyScout; 'YouTube-Key-Scout beendet.' } }
        @{ Id='mcp-install'; Label='Kostenlose MCP-Server installieren'; Risk='low'; NeedsAdmin=$false
           Desc='Katalog mit 14 kostenlosen MCP-Servern (git, fetch, memory, puppeteer, playwright, context7, desktop-commander ...) - npx-basiert, ohne API-Key.'
           Run={ Show-SysPilotMcpMenu; 'MCP-Menue geoeffnet.' } }
        @{ Id='skills-browse'; Label='Skills suchen + installieren (skills.sh)'; Risk='low'; NeedsAdmin=$false
           Desc='Durchsucht die kostenlose skills.sh-Registry und installiert Skills in .agents/.claude etc.'
           Run={ Show-SysPilotHerbertManager; 'Herbert-Manager geoeffnet.' } }
        @{ Id='api-keys'; Label='API-Keys importieren + sichern'; Risk='low'; NeedsAdmin=$false
           Desc='Findet Key-Dateien (Dokumente\api keys u.a.), importiert sie in Provider und sichert sie verschluesselt.'
           Run={ try { Show-SysPilotAiImportExportMenu } catch { Save-SysPilotAiKeyBackup | Out-Null }; 'Keys verwaltet.' } }
        @{ Id='browser-summarize'; Label='Seite zusammenfassen (Browser-MCP)'; Risk='low'; NeedsAdmin=$false
           Desc='Oeffnet eine URL im eigenen Browser (MCP), liest den Inhalt und fasst ihn per KI zusammen.'
           Run={ Invoke-SysPilotBrowserPageTask -Task 'summarize'; 'Zusammenfassung gestartet.' } }
    )
}

function Get-SysPilotKiActionProtocol {
    <# Prompt-Block fuer den Assistenten: Aktion-Syntax + Katalog. #>
    $lines = @(Get-SysPilotKiActions | ForEach-Object { "- $($_.Id): $($_.Label) - $($_.Desc)" })
    return @"

AKTIONEN: Du kannst dem Nutzer ausfuehrbare SysPilot-Aktionen anbieten. Syntax (exakt, eigene Zeile, max. 2 pro Antwort):
<<<AKTION:AKTIONS-ID>>>
Verfuegbare Aktionen:
$($lines -join "`n")
Regeln: Nur Aktionen vorschlagen, die zur Frage/Lage passen, kurz begruenden warum. Nie mehr als 2. Der Nutzer entscheidet per 'Uebernehmen'-Klick selbst - du fuehrst nichts aus.

ANTWORT-MARKER (werden als UI-Elemente gerendert, nicht als Text gezeigt; max. 3 pro Antwort):
<<<DENK:dein Gedanke/Analyse/Begruendung>>>
<<<VORSCHLAG:kurzer Vorschlag>>>
<<<FRAGE:deine Frage|Option1|Option2>>>

ARBEITSWEISE: Zuerst analysieren (DENK), bei groesseren/unsicheren Aufgaben einen Plan vorschlagen und per FRAGE um Zustimmung bitten, erst danach ausfuehren. Kleine gefahrlose Fragen/Infos direkt beantworten. VORSCHLAG fuer Alternativen, die der Nutzer anklicken kann. Bei Install/Download-Entscheidungen: Paketmanager bevorzugen, wenn er das Paket sauber liefert, sonst SmartDownload begruenden.
"@
}

function Invoke-SysPilotKiAction {
    <# Fuehrt eine registrierte Chat-Aktion aus. Gibt @{Ok;Text;Id;Label;Error}.
       Alle Streams werden mitgefangen (Write-Host etc.). #>
    param([Parameter(Mandatory)][string]$Id)
    $act = @(Get-SysPilotKiActions) | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if (-not $act) { return @{ Ok=$false; Text=''; Id=$Id; Label=''; Error="Unbekannte Aktion: $Id" } }
    # Action-Funktionen koennen in anderen Modulen leben - bei
    # CommandNotFound einmalig alle Module nachladen und wiederholen.
    for ($try = 0; $try -lt 2; $try++) {
        try {
            $out = (& $act.Run *>&1 | Out-String).Trim()
            return @{ Ok=$true; Text=$out; Id=$Id; Label=$act.Label; Error='' }
        } catch {
            if ($try -eq 0 -and $_.Exception.Message -match 'wurde nicht als Name|not recognized') {
                $modDir = Split-Path -Parent $PSCommandPath
                if ($modDir) { Get-ChildItem $modDir -Filter '*.psm1' | ForEach-Object { Import-Module $_.FullName -Force -Global -WarningAction SilentlyContinue } }
                continue
            }
            return @{ Ok=$false; Text=''; Id=$Id; Label=$act.Label; Error=$_.Exception.Message }
        }
    }
    return @{ Ok=$false; Text=''; Id=$Id; Label=$act.Label; Error='Aktion fehlgeschlagen' }
}

# =====================================================================
# Herbert-Interessens-Profil: Themen, ueber die der Assistent
# proaktiv informieren soll (Gesundheit, ADHS, Politik, Hobbies ...).
# Gespeichert in ai-assist.json als "Interests" (String-Array).
# =====================================================================

function Get-SysPilotHerbertInterests {
    <# Liefert die gespeicherten Interessen als String-Array. #>
    $cfg = Read-SysPilotAiAssistConfig
    $raw = @($cfg.Interests)
    return @($raw | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() })
}

function Set-SysPilotHerbertInterests {
    <# Setzt das Interessen-Profil (String-Array). #>
    param([string[]]$Interests = @())
    $cfg = Read-SysPilotAiAssistConfig
    $cfg | Add-Member -NotePropertyName Interests -NotePropertyValue @($Interests | ForEach-Object { [string]$_ }) -Force
    Write-SysPilotAiAssistConfig -Config $cfg
}

function Get-SysPilotHerbertInterestTopics {
    <# Vordefinierte Themen-Vorschlaege fuer das Profil (User kann
       zusaetzlich Freitext-Themen eintragen). #>
    return @(
        'Gesundheit & Wohlbefinden',
        'Longevity & Anti-Aging',
        'Nahrungsergaenzung & Mikronaehrstoffe',
        'Psychosen & Schizophrenie',
        'ADHS',
        'Autismus & Neurodiversitaet',
        'Psychologie & mentale Gesundheit',
        'Politik',
        'Kriegsgeschehen & Geopolitik',
        'Technik & KI',
        'Wissenschaft',
        'Finanzen & Wirtschaft',
        'Hobbies & Freizeit',
        'Kochen & Ernaehrung',
        'Sport & Bewegung',
        'Reisen',
        'Musik',
        'Buecher & Lesen',
        'Spiele',
        'Filme & Serien',
        'Windows',
        'Linux',
        'Games (allgemein)',
        'GOG',
        'Steam',
        'Epic Games Store',
        'Deskmodder',
        'Windows Central',
        'Reddit',
        'Aliens, UFO & UAP',
        'Mystery & Unerklaerliches',
        'Buecher',
        'Filme',
        'Serien',
        'Fantasy',
        'Science-Fiction',
        'Horror',
        'Krimi & Thriller'
    )
}

function Show-SysPilotHerbertInterestsSetup {
    <# ADHS-taugliches Interessen-Setup: Multi-Select ueber
       vordefinierte Themen + Freitext-Eingabe. Speichert in
       ai-assist.json; Herbert beruecksichtigt es ab sofort
       im System-Prompt (proaktive Infos zu diesen Themen). #>
    $topics = @(Get-SysPilotHerbertInterestTopics)
    $current = @(Get-SysPilotHerbertInterests)
    while ($true) {
        $pickItems = foreach ($t in $topics) {
            @{ Label=$t; Color='White'; Tag=$t; Checked=($current -contains $t) }
        }
        $chosen = Show-SysPilotMultiSelectMenu -Items $pickItems -Title 'Herbert-Interessen (Leertaste = an/aus, Enter = fertig)'
        if ($null -eq $chosen) { return }
        # Freitext-Themen ergaenzen (z.B. "3D-Druck", "Vogelkunde")
        $free = Read-SysPilotInput 'Weitere Interessen? (Komma-getrennt, Enter = keine)' 'neue interests'
        $final = @($chosen)
        if ($free) { $final += @($free -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        # Bereits vorhandene Custom-Themen (nicht in topics) behalten
        foreach ($c in $current) { if ($c -notin $topics -and $c -notin $final) { $final += $c } }
        Set-SysPilotHerbertInterests -Interests $final
        Write-Host "`n  Gespeichert: $(if($final.Count){$final -join ', '}else{'(keine - Profil leer)'})" -ForegroundColor Green
        Write-Host "  Herbert beruecksichtigt diese Themen jetzt in seinen Antworten" -ForegroundColor DarkGray
        Write-Host "  und kann dir passende News/Feeds/Infos proaktiv praesentieren." -ForegroundColor DarkGray
        Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
        return
    }
}

function Get-SysPilotHerbertKnowledge {
    <# Kuratiertes Herbert-Wissen: Themen, bei denen der Assistent
       proaktiv ADHS-verstaendlich erklaeren soll (kurze Schritte,
       klare Reihenfolge, typische Fallstricke). Als Textbloecke,
       die in den System-Prompt gehaengt werden. #>
    return @(
        @'
TV/MOBIL-SIDELOAD (Android TV, Fire TV, Smartphone, Tablet):
- Quellen: TroyPoint (troypoint.com/best-apps), F-Droid (nur FOSS), Obtainium (GitHub-Apps + Auto-Update), Aurora Store (Play Store ohne Google-Account), APKMirror (signatur-geprueft), TechDoctorUK/DocSquiffy-Downloads.
- ADB funktioniert bei TV UND Android-Phone/Tablet identisch (Port 5555 oder Wireless-Debugging-Pairing). iOS: kein APK moeglich - nur AltStore PAL (App Store, kostenlos) -> SideStore; Signaturen 7 Tage, SideStore erneuert automatisch.
- WICHTIG SmartTube + YouTube ersetzen: REIHENFOLGE einhalten! 1) Original-YouTube-App deinstallieren (Paket-Konflikt sonst), 2) SmartTube APK installieren, 3) Amazon SYTV Bridge (Fire TV) bzw. ATV SYTV Bridge (Android TV) installieren - die Bridge leitet YouTube-Taste/Alexa/Voice-Suche auf SmartTube um und erscheint nicht im Launcher.
- Launcher: Monet (~10 EUR, Netflix-Look, aufgeraeumt), Projectivy (~3 EUR), Wolf (kostenlos), FLauncher (FOSS). Auf Fire OS (Fire TV) ist KEIN Drittanbieter-Home erlaubt - Amazon-Launcher bleibt; Monet & Co. nur auf Android TV/Google TV.
- Downloader-Codes am TV: Apps aus 'unbekannten Quellen' erlauben, dann APK-URL oder Code eingeben.
'@
        @'
GESUNDHEIT / ARZT-VORBEREITUNG (wichtig,-user-relevant):
- Vor einem Arztgespraech ist eine KI-Vorabkonsultation SEHR sinnvoll: Der User kann mit Herbert Symptome, Verlauf, Medikamente und eigene Ueberlegungen durchgehen, Hypothesen ausloten und eine Liste von Fragen + moeglichen Diagnosen/Baustrategien fuer das Gespraech vorbereiten.
- Herbert soll dabei aktiv helfen: strukturierte Symptom-Liste erfragen (seit wann, Haeufigkeit, Ausloeser, Besserung/ Verschlechterung), relevante Vorgeschichte, bisherige Behandlungen, und daraus eine Uebersicht + Gespraechsleitfaden fuer den Arzt erzeugen (Frageliste, was man erzaehlen will, was man wissen will).
- Bei Psychosen/Schizophrenie/ADHS/Autismus besonders: realistische Erwartung an Diagnose-Prozesse (oft lang, Differentialdiagnosen), Inhalte fuer das naechste Gespräch vorbereiten.
- IMMER klarstellen: Herbert ist KEIN Arzt und keine Diagnose - die KI-Vorbereitung ersetzt keine fachliche Abklaerung. Formulierungen wie "moegliche Richtung", "kann zusammenhaengen mit", nie als Diagnose ausgeben. Bei akuten Warnzeichen (z.B. Krisen, Selbstgefährdung) ruhig, direkt und empathisch einen echten Notdienst/Arzt empfehlen.
- Guter Stil: kurze nummerierte Schritte, ein Thema pro Schritt, ermutigend und ohne Herablassung.
- LONGEVITY/Nahrungsergaenzung: skeptisch-wissenschaftlich bleiben - unserioese Versprechen erkennen und benennen, auf evidenzbasierte Quellen verweisen (Studien, Meta-Analysen), Dosierungen nicht erfinden.
'@
        @'
MINIFLUX / RSS:
- Miniflux = self-gehosteter RSS-Reader (unbegrenzt, kostenlos). Docker-Compose-Stack oder Oracle Always Free. Clients: Android Capy/FluxNews/FeedMe, iOS NetNewsWire/Unread/Reeder, Desktop Fluent Reader.
- Clients brauchen API-Credentials (Einstellungen > Integrations > Fever/Google Reader API), NICHT das Login-Passwort.
- Auf Mobile: QR-Code der Miniflux-URL scannen, dann App einrichten.
- FLUXNEWS (Android, empfohlen, FOSS via F-Droid `de.circle_dev.flux_news`): nutzt Miniflux REST-API direkt — braucht API-Key (Settings > API Keys), Auth-Header ist `X-Auth-Token` (NICHT Bearer!). **WICHTIG: URL muss mit `/` am Ende eingegeben werden** (`https://host.ts.net/`) — App validiert das strikt. Per ADB automatisierbar: `adb install`, App-Start via monkey, Login-Button tippen, Felder per `input tap`+`input text` fuellen, Tastatur per keyevent 4 schliessen, dann Speichern. App-Daten nicht per run-as lesbar (nicht debuggable).
- MINIFLUTT (Android, FOSS, F-Droid `be.martinelli.miniflutt`, Flutter): Miniflux-spezifischer Reader, Config = NUR Server-URL + API-Key (kein User/Passwort). URL ohne `/v1`, kein Slash noetig. **ADB-Automation**: Flutter-Semantik-Baum ist spaerlich — TalkBack aktiviert ihn vollstaendig (`settings put secure enabled_accessibility_services com.google.android.marvin.talkback/...TalkBackService` + `accessibility_enabled 1`); Tutorial dabei NICHT ueber „Fertig" beenden (Schleife!) sondern per `keyevent 4` (BACK), Notification-Permission via `pm grant com.google.android.marvin.talkback android.permission.POST_NOTIFICATIONS`, am Ende TalkBack wieder deaktivieren. **realmeUI/ColorOS blockiert WRITE_SECURE_SETTINGS + GRANT_RUNTIME_PERMISSIONS fuer adb-shell** → TalkBack nicht per ADB aktivierbar, ABER content-desc-Semantik ist dort auch ohne TalkBack teilweise da → rein koordinatenbasiert navigierbar (Nav-Drawer > Settings > Add account; Felder: URL / API-Key-maskiert / '500'=Timeout). `input text`Auto-Kapitalisierung macht 'Habermann' im Host — DNS ist case-insensitive, unkritisch. Account erscheint danach als `admin@<host>`.
- PANDA READER (Windows-Desktop, GPUI, yuhangch/panda-reader, Installer `%LOCALAPPDATA%\Programs\Panda Reader`, Daten in `%LOCALAPPDATA%\PandaReader\PandaReader\data\`): Settings > General > Subscription source > Miniflux > Instance-URL + API-Token (X-Auth-Token) > Connect — Kategorien werden als Ordner, Read/Star synct. Config ist NUR per GUI moeglich (GPUI = kein UIA, keine Automation). Installer ist NSIS, Install-Modus-Dialog per UIAutomation-Klick auf 'Install for me only' automatisierbar.
- WINDOWS-CLIENT: Fluent Reader (MS Store, `25286HaoyuanLiu.FluentReader`, kostenlos) — Service-Typ **Miniflux** (nativ, NICHT Fever!): Endpoint `https://<host>`, Auth = API-Key `f37059...` aus ZUGANG.txt (X-Auth-Token), "Import groups" an → Miniflux-Kategorien werden als Reader-Gruppen uebernommen. Alternative Service-Typ **Fever**: Endpoint muss `/fever/` enthalten (`https://<host>/fever/`) + api_key = Fever-Token aus ZUGANG.txt (`?api_key=` POST-Token aus Postgres `integrations`.fever_token, kein Basic-Auth). **Google Reader API**: User `syspilot` + Passwort aus ZUGANG.txt (ClientLogin-Flow). Browser = Miniflux-Web-UI direkt (`https://<host>`), optional als App installieren.
- Feste oeffentliche URL: Tailscale Funnel (EMPFOHLEN, KOSTENLOS) = https://<pc>.<tailnet>.ts.net - funktioniert hinter NAT/Hotspot ohne Port-Forwarding/Domain, HTTPS inklusive, laeuft als Service mit Windows. Alternative: Cloudflare named tunnel (braucht eigene Domain bei Cloudflare) oder quick tunnel (Zufalls-URL, wechselt bei Neustart). no-ip/ddns nur sinnvoll bei festem DSL mit Port-Forwarding - am Hotspot nutzlos. KiAction 'ts-funnel' oeffnet das gefuehrte Setup.
- WICHTIG Port-Falle: Auf manchen PCs belegt eine andere App Port 8080 (z.B. CEF-Debug) - dann Miniflux-Compose auf 8081:8080 aendern und Funnel auf 8081 richten. Docker-Desktop-NAT + wackeliges Netz => Feed-Adds koennen 500er werfen, einfach retry.
- Reddit hat anonyme RSS-Feeds eingestellt (404/429) - SysPilot markiert sie HtmlOnly, OPML-Export filtert sie raus.
'@
        @'
KI-PROVIDER / HERBERT:
- Provider-Modus: auto (Cloud zuerst, lokal als Fallback - Standard), local (nur lokal), cloud (nur Cloud). Pin = bevorzugter Provider zuerst. Kostenklassen: kostenlos < freemium < guenstig < ... ; Freemium-Modelle bevorzugt bei knappen Budgets.
- Router-Sync (OmniRoute, FreeLLMAPI, freelm, 9router): uebernimmt automatisch Modus + Pin + Budget-Reihenfolge der Provider. Zusaetzlich schreibt jeder Sync das Artefakt %LOCALAPPDATA%\SysPilot\usable-providers.json mit geranktem Modell-Plan pro Provider (model = bestes Modell via Kostenklasse/Free-Varianten/Kontext, models = Fallback-Kette fuer Rate-Limit - Freikontingente gelten pro Modell). Custom-Provider in FreeLLMAPI bekommen dasselbe Ranking.
- Kontext-Budget: History wird automatisch auf ~70% des Modell-Contexts gekuerzt - sehr lange Chats sind normal, aelteste Nachrichten fallen ggf. weg.
- Bei instabilem Netz (Hotspot): SysPilot wartet kurz auf Wiederkehr statt sofort zu scheitern; Downloads sind resume-faehig (aria2/Segmente).
- Provider-Details (SysPilot -> KI-Assistenz -> Provider): Key wird MASKIERT angezeigt (...letzte4), [API-Key anzeigen] gibt ihn frei; 'Modell-Scope' beschraenkt per Haken, welche /models-Modelle ein Key nutzen darf (Prefix-Match: 'openai' deckt 'openai-fast'); 'Nutzung' zeigt Monats-Requests+Tokens (ai-usage.json). Katalog enthaelt KEYLESS-Provider (Kilo Gateway, OVH AI Endpoints - kein Account noetig), ~20 weitere Free-Router (LLM7, Agnes, Aion Labs, NaraRouter, OrcaRouter ...) UND ~90 BEZAHLTE OpenAI-kompatible Provider aus der OmniRoute-Registry (OpenAI, xAI, DeepInfra, Baseten, Hetzner, cheaperinference, AI/ML API, Qwen Cloud, MiniMax, Baidu Qianfan, Tencent Hunyuan u.v.m.) - Budget-Mode sortiert 'teuer' nach hinten, 'guenstig' nach vorn. Bei 429/Quota automatisch: 15min Modell-Cooldown + Wechsel zum naechsten Modell, dann Provider. SMART BUDGET (Provider-Menue > [B] Budget-Modus, an-/abschaltbar): 'smart' = Bezahl-Provider nur solange Monats-Token-Budget reicht (dann ans Ende der Kette, nicht geloescht); 'sparsam' = teure/Abo-Provider komplett raus (Pin ausgenommen); 'qualitaet' = Budget-Checks aus, beste Modelle zuerst; 'aus' = alte Sortierung. Globales Monats-Budget + pro-Provider TokenCapMonthly einstellbar, Nutzung kommt aus ai-usage.json (usage.total_tokens pro Request). Pin (bevorzugter Provider) bleibt in jedem Modus erste Wahl.
'@
        @'
BROWSER "VERWALTET" / EXTENSION-POLICY (Chrome, Edge, Brave, Vivaldi, Chromium):
- Zeigt der Browser "wird von Ihrer Organisation verwaltet" und sperrt Einstellungen (DNS, Cookies, Tracking-Schutz)? -> fast immer eine ExtensionSettings-Policy, oft von SysPilot gesetzt (Sync-Schutz nach Extension-Entfernung: verhindert, dass angemeldeter Sync die Extension erneut installiert).
- WICHTIGER TRADE-OFF den User kennen: Je mehr Policy-Eintraege, desto mehr ist gesperrt. Loesung: CleanSweep -> "Extension-Policy-Bloecke verwalten" (oder KiAction extension-policy): zeigt blockierte IDs pro Browser, unterscheidet SysPilot- vs. fremde Eintraege, erlaubt Aufheben (nur SysPilot-Blocks ODER komplette Policy). Danach Browser neu starten.
- RISIKO beim Aufheben: Angemeldeter Browser-Sync kann entfernt geglaubte Extensions erneut installieren - vor dem Aufheben erwaehnen.
- Policy-Registry-Keys (HKCU\...\Policies) koennen schreibgeschuetzt sein -> SysPilot elevated neu starten.
- Bei Zahlungs-/Anmelde-Problemen in Chrome zunaechst pruefen: ist der Browser "verwaltet"? -> Policy-Bloecke pruefen/beheben.
'@
        @'
SYS PILOT EXTENSION MANAGER (extension-manager/ - eigene MV3-Extension):
- Was: eigener Extension-Manager MIT chrome.management - Extension-Liste + Suche, Enable/Disable pro Extension, echtes Entfernen (chrome.management.uninstall), Zahnrad oeffnet die Browser-Detailseite chrome://extensions/?id=<id> (fokussiert, wie Easy Extension Manager), HTML-Export/-Import als Sync zwischen Browsern (Edge/Brave/Comet).
- Installieren: Button 'Ext-Manager' im SysPilot Extension-Manager (Browser-Erweiterungen), CleanSweep > Browser-Erweiterungen > gruener Eintrag, oder KiAction 'ext-manager'. Kopiert den Ordnerpfad in die Zwischenablage + oeffnet chrome://extensions -> 'Entwicklermodus' an -> 'Entpackte Erweiterung laden'.
- ORDNER-DIALOG-FALLE (haeufiger Fehler!): Der Windows-Ordnerdialog oeffnet in OneDrive\Documents - dort gibt es keine manifest.json -> Fehler 'Manifest konnte nicht geladen werden'.RICHTIG: im Dialog OBEN die Adress-/Pfadzeile anklicken, Strg+V (Pfad liegt in der Zwischenablage), Enter, dann 'Ordner auswaehlen'. Pfad ist %LOCALAPPDATA%\SysPilot\extension-manager (NICHT Program Files - der Picker kommt dort oft nicht klar).
- Wann vorschlagen (proaktiv!): User will viele Extensions aufraeumen, Extensions zwischen Browsern synchron halten, vermisst Funktionen eines Extension-Managers (Easy Extension Manager & Co.) oder hasst die Sync-Rueckhol-Falle - dann Ext-Manager + HTML-Export/Import erklaeren statt Policy-Bloecke.
- Grenzen ehrlich nennen: uninstall kann KEINE policy-installierten oder geschuetzten Extensions entfernen (nur Browser-Detailseite hilft dort); HTML-Import installiert NICHT automatisch (Chrome-Schutz) - zeigt nur Store-Links fuer fehlende Extensions; Sync ist dateibasiert (Export -> Import), kein Live-Sync.
- Stil: kurz, ein Absatz + 3-4 Bulletpoints, ein kleiner Scherz erlaubt (z.B. "dein Browser muss nicht mehr managen-undefined werden"), dann konkreter naechster Schritt.
'@
        @'
SKILLS / MCP / HERBERT-ERWEITERUNG:
- SKILLS = kleine Rezepte/Anleitungen fuer den Assistenten (SKILL.md-Dateien), liegen lokal (z.B. .devin/skills, .agents/skills, User-Skills); verwaltbar ueber den Herbert-Manager (skills.sh-Registry, kostenlos durchsuchbar/installierbar).
- MCP-SERVER = externe Werkzeuge fuer den Chat (Dateisystem, Browser, GitHub, PowerShell, Desktop-Commander u.a.), konfigurierbar im MCP-Menue; Katalog bietet 14+ kostenlose Server (git, fetch, memory, puppeteer, context7 ...).
- Herbert-Selbsttest (KiAction 'selftest' bzw. 'L'/Setup) inventarisiert Provider, MCP-Server, Skills und API-Keys und schlaegt konkrete naechste Erweiterungen vor.
- Wenn der User nach 'Skill', 'MCP', 'Connector', 'Herbert erweitern' fragt: auf Herbert-Manager bzw. MCP-Menue verweisen statt zu raten.
'@
        @'
VIBE CODING (Crash-Kurs-Stil):
- Vibe Coding = Programmieren per Beschreibung: User sagt was er will, die KI schreibt den Code. Herbert soll dabei als Pair-Programming-Lehrer auftreten, nicht nur Code-Bloecke ausspucken.
- Crash-Kurs-Struktur: 1) Mini-Projekt waehlen (z.B. 'Skript das Downloads organisiert'), 2) Schritt fuer Schritt: Idee -> Code -> Test -> Iteration, 3) JEDEN Schritt kurz erklaeren (was tun die 3 wichtigsten Zeilen), 4) Typische Fallstricke nennen (Encoding, Pfade mit Leerzeichen, Admin-Rechte, Synapse), 5) Am Ende: was der User selbst anpassen kann.
- ADHS-gerecht: EIN Schritt pro Nachricht, Code begrenzen (keine 500-Zeilen-Waende), Zwischenzusammenfassung nach jedem Schritt, kleine Erfolge erwaehnen.
- Security: generierter Code ist ungeprueft - bei Loeschungen, Registry, Netzwerk oder Credentials immer Review empfehlen.
'@
        @'
SECURITY-LAB (Kali WSL + unzensierte Modelle - NUR autorisiert/defensiv):
- SysPilot bietet 'Security-Lab einrichten' (KiAction seclab): Kali Linux in WSL (`wsl --install kali-linux`, auch im WSL-Distro-Picker) + unzensierte/abliterated/heretic GGUF-Modelle via HuggingFace-Suche (ModelFinder-Presets 'abliterated', 'heretic', 'uncensored', 'dolphin'; Download in Ollama/LM-Studio/PocketAI-Ordner).
- EINSATZ nur fuer: eigene Geraete/Netzwerke, autorisierte Pentests, CTF, Learning. IMMER klaeren, dass nur eigene/erlaubte Ziele getestet werden; bei Angriffen auf fremde Systeme ablehnen und auf legale Uebungsumgebungen verweisen (eigene VM, DVWA, TryHackMe, HackTheBox).
- Unzensierte Modelle haben weniger Inhaltsfilter, aber Sicherheits- und Rechtshinweise bleiben PFLICHT (Backup, isolierte VM, keine realen Ziele). Modellkunde: 'abliterated' = zensierte Basis ohne Refusal-Training (automatisiert); 'heretic' = ABLITERATION-Tool; 'dolphin' = explizit unzensierte Fine-tunes.
- Kali in WSL: `wsl -d kali-linux`, Tools via `sudo apt install <tool>` (nmap, metasploit-framework, wireshark ...); GUI-Tools laufen ueber WSLg.
'@
        @'
ALLGEMEIN (ADHS-gerechte Erklaerart):
- Antworte in kurzen Schritten, nummeriert. Ein Schritt = eine Aktion. Nenne die naechste Aktion immer explizit.
- Bei Unsicherheit: sag es klar, rate nicht. Keine erfundenen Links/Versionen/Preise - Preise als ca.-Wert kennzeichnen.
- Bei riskanten Aktionen (Loeschen, Registry, Dienste): erst erklaeren was passiert, dann Bestaetigung einholen.
'@
    ) -join "`n`n"
}

function Invoke-SysPilotAiChat {
    <# Sendet einen Chat-Request an die.enabled Provider in Reihenfolge
       (Fallback-Kette). OpenAI-kompatibles /chat/completions.
       Gibt @{Ok;Text;Provider;Model;Error} zurueck. #>
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$System = 'Du bist Pilot Herbert, der Bord-Assistent von SysPilot (Flug 667), einem Windows-Wartungs-Tool. Antworte knapp und konkret auf Deutsch, wenn nicht anders gewuenscht.',
        [string]$ProviderName = '',
        [string]$Model = '',
        [int]$TimeoutSec = 90,
        [object[]]$History = @(),
        [object[]]$McpToolDefs = @(),
        [object[]]$Images = @(),
        [int]$MaxTokens = 1500,
        [switch]$NoProtocol
    )
    $providers = @(Get-SysPilotAiProviders | Where-Object { $_.Enabled })
    if ($ProviderName) {
        $providers = @($providers | Where-Object { $_.Name -eq $ProviderName })
    } else {
        # Brauchbare-Liste: Provider-Modus (auto=cloud->lokal->free,
        # local=strict, cloud=strict) + Preferred-Pin an erster Stelle.
        $providers = @(Get-SysPilotAiUsableProviders)
    }
    if ($providers.Count -eq 0) {
        return @{ Ok=$false; Text=''; Provider=''; Model=''; Error='Kein KI-Provider konfiguriert/erreichbar. Siehe SysPilot -> KI-Assistenz.' }
    }
    # Instabile Netze (Hotspot/Mobilfunk): bei Cloud-Providern kurz auf
    # Wiederkehr der Verbindung warten, statt sofort durch die Kette zu
    # fallen. Lokale Provider werden danach trotzdem versucht.
    try {
        if (@($providers | Where-Object { $_.Kind -ne 'local' }).Count -gt 0 -and
            (Get-Command Test-SysPilotInternet -ErrorAction SilentlyContinue) -and
            -not (Test-SysPilotInternet)) {
            [void](Wait-SysPilotInternet -MaxSec 45 -PollSec 5 -Label 'KI-Chat')
        }
    } catch {}
    # Kontext-Budget: Aelteste History-Eintraege kuerzen, bis
    # System+History+Prompt+MaxTokens in ~70% des Modell-Contexts
    # passen (lokal oft 8k, Cloud 32k+). Verhindert Context-Overflow.
    try {
        $bp = $providers[0]
        $bmodel = if ($Model) { $Model } else { Resolve-SysPilotAiModel -Provider $bp -TimeoutSec 8 }
        $bctx = 0
        $ml = Get-SysPilotAiProviderModels -Provider $bp -TimeoutSec 8
        if ($ml.Ok -and $ml.Models) {
            $mm = @($ml.Models | Where-Object { $_.Id -eq $bmodel } | Select-Object -First 1)
            if ($mm.Count -gt 0) { $bctx = [int64]$mm[0].Context }
        }
        if ($bctx -le 0) { $bctx = $(if ($bp.Kind -eq 'local') { 8192 } else { 32768 }) }
        $budgetTok = [int]($bctx * 0.7)
        $tok = { param($s) ([int]("$s".Length / 4)) }
        $used = (& $tok $System) + (& $tok $Prompt) + $MaxTokens
        $histTok = 0; foreach ($h in @($History)) { $histTok += ((& $tok ([string]$h.content)) + 8) }
        while ($History.Count -gt 0 -and (($used + $histTok) -gt $budgetTok)) {
            $histTok -= ((& $tok ([string]$History[0].content)) + 8)
            $History = @($History | Select-Object -Skip 1)
        }
    } catch {}
    $messages = @()
    if ($System) {
        $sysText = $System
        if (-not $NoProtocol) { $sysText += (Get-SysPilotKiActionProtocol) }
        $messages += @{ role='system'; content=$sysText }
    }
    foreach ($h in $History) { $messages += $h }
    $messages += @{ role='user'; content=$Prompt }
    # Vision: Modellnamen-Heuristik - nur Modelle mit Bildfaehigkeit
    # bekommen image_url-Parts; andere Provider erhalten einen Hinweis.
    $visionRe = 'llava|vision|moondream|bakllava|gemma3|gemma-3|qwen.*vl|qwen3-vl|minicpm|pixtral|gpt-4o|gpt-4\.1|gpt-5|o[0-9]-|o1-|o3-|o4-|claude|gemini|llama3\.2-vision|internvl|cogvlm|idefics|phi-3-vision|phi3v|janus|emu3|llama4'
    $hasImages = (@($Images).Count -gt 0)
    # MCP-Tool-Definitionen (optional, OpenAI-Schema)
    $openAiTools = @()
    if ($McpToolDefs.Count -gt 0 -and (Get-Command ConvertTo-SysPilotMcpOpenAiTools -ErrorAction SilentlyContinue)) {
        try { $openAiTools = @(ConvertTo-SysPilotMcpOpenAiTools -Defs $McpToolDefs) } catch { $openAiTools = @() }
    }
    $lastErr = ''
    foreach ($p in $providers) {
        # Auto-Modus: kuerzlich fehlgeschlagene Provider ueberspringen
        # (15 min TTL) - verhindert, dass die Kette bei jedem Versand
        # Dutzende tote Endpunkte mit Timeouts abarbeitet.
        $pk = $p.BaseUrl.ToLower().TrimEnd('/')
        if (-not $ProviderName -and $script:AiProviderFailCache.ContainsKey($pk)) {
            $ft = $script:AiProviderFailCache[$pk]
            if (((Get-Date) - $ft).TotalMinutes -lt 15) { continue }
            $script:AiProviderFailCache.Remove($pk)
        }
        $model = if ($Model) { $Model } else { Resolve-SysPilotAiModel -Provider $p -TimeoutSec 12 }
        # Rate-Limit-Fallback: bei 429/Quota zuerst ALTERNATIVE Modelle
        # desselben Providers probieren (Budget schonend - das
        # Freikontingent ist pro Modell), ERST dann zum naechsten
        # Provider wechseln. Gerankt via Get-SysPilotAiRankedModels.
        $altModels = @()
        if (-not $Model) {
            try {
                $altModels = @((Get-SysPilotAiRankedModels -Provider $p -TimeoutSec 8 -Top 4 |
                    Where-Object { $_.Id -ne $model } | ForEach-Object { $_.Id }))
            } catch { $altModels = @() }
        }
        $providerErr = ''
        # Vision-Parts nur fuer faehige Modelle; sonst Text-Hinweis
        $reqMessages = @($messages)
        if ($hasImages) {
            if ("$model" -match $visionRe) {
                $parts = @(@{ type='text'; text=[string]$Prompt })
                foreach ($im in @($Images)) {
                    if ($im.B64) { $parts += @{ type='image_url'; image_url=@{ url="data:$($im.Mime);base64,$($im.B64)" } } }
                }
                $reqMessages = if ($messages.Count -gt 1) { @($messages[0..($messages.Count-2)]) } else { @() }
                $reqMessages += @{ role='user'; content=$parts }
            } else {
                $note = "`n`n[Bildanhang: $(@($Images).Count) Bild(er) - Modell '$model' hat evtl. keine Bildunterstuetzung, daher nur Text gesendet]"
                $reqMessages = if ($messages.Count -gt 1) { @($messages[0..($messages.Count-2)]) } else { @() }
                $reqMessages += @{ role='user'; content=("$Prompt$note") }
            }
        }
        for ($attempt = 0; $attempt -lt 6; $attempt++) {
            $useTools = ($openAiTools.Count -gt 0 -and $attempt -eq 0)
            $bodyObj = @{
                model = $model
                messages = $reqMessages
                temperature = 0.3
                max_tokens = $MaxTokens
            }
            if ($useTools) { $bodyObj.tools = $openAiTools; $bodyObj.tool_choice = 'auto' }
            $body = $bodyObj | ConvertTo-Json -Depth 12
            $headers = @{ 'Content-Type' = 'application/json' }
            if ($p.ApiKey) { $headers['Authorization'] = "Bearer $($p.ApiKey)" }
            try {
                $resp = Invoke-RestMethod -Uri ($p.BaseUrl.TrimEnd('/') + '/chat/completions') `
                        -Method Post -Headers $headers -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec $TimeoutSec -ErrorAction Stop
                $msg = $resp.choices[0].message
                if ($msg.tool_calls -and @($msg.tool_calls).Count -gt 0) {
                    $calls = @()
                    foreach ($tc in @($msg.tool_calls)) {
                        $calls += [pscustomobject]@{
                            Id = [string]$tc.id
                            Name = [string]$tc.function.name
                            Arguments = [string]$tc.function.arguments
                        }
                    }
                    try { Add-SysPilotAiUsageRecord -Provider $p -Model $model -Tokens ([int64]$(if ($resp.usage.total_tokens) { $resp.usage.total_tokens } else { 0 })) } catch {}
                    return @{ Ok=$true; Text=''; Provider=$p.Name; Model=$model; Error=''; ToolCalls=$calls }
                }
                $txt = $msg.content
                if (-not $txt) { $txt = [string]$resp.choices[0].text }
                if ($txt) {
                    # Erfolg: Cooldown fuer dieses Modell aufheben
                    if (-not $Model) { try { Clear-SysPilotAiModelCooldown -Provider $p -Model $model } catch {} }
                    try { Add-SysPilotAiUsageRecord -Provider $p -Model $model -Tokens ([int64]$(if ($resp.usage.total_tokens) { $resp.usage.total_tokens } else { 0 })) } catch {}
                    return @{ Ok=$true; Text=($txt -join "`n").Trim(); Provider=$p.Name; Model=$model; Error=''; ToolCalls=@() }
                }
                $providerErr = 'leere Antwort'
                break
            } catch {
                if ($useTools) { continue }   # Provider kann kein tools -> ohne Tools erneut
                $errMsg = "$($_.Exception.Message)"
                # Rate-Limit/Quota: naechstes Modell desselben Providers
                # versuchen (Freikontingent ist pro Modell) - spart den
                # Sprung zum naechsten Provider und bleibt budget-schoen.
                if ($altModels.Count -gt 0 -and $errMsg -match '(?i)429|rate.?limit|quota|budget|too many|insufficient|exceeded|capacity|overloaded') {
                    # Cooldown merken (FreeLLMAPI-Prinzip): naechste
                    # Chats sortieren dieses Modell ans Ende
                    try { Set-SysPilotAiModelCooldown -Provider $p -Model $model -Minutes 15 } catch {}
                    $model = [string]$altModels[0]
                    $altModels = @($altModels | Select-Object -Skip 1)
                    Write-SysPilotLog "KI-Chat $($p.Name): Rate-Limit/Quota - Modell '$model' 15min gesperrt, Wechsel zu '$model'"
                    continue
                }
                # Auch das letzte Alternat-Modell cooldownen, wenn's
                # am Kontingent lag (sonst wird's beim naechsten Chat
                # wieder zuerst probiert)
                if ($errMsg -match '(?i)429|rate.?limit|quota|budget|too many|insufficient|exceeded|capacity|overloaded') {
                    try { Set-SysPilotAiModelCooldown -Provider $p -Model $model -Minutes 15 } catch {}
                }
                $providerErr = "$($p.Name): $errMsg"
                $script:AiProviderFailCache[$pk] = Get-Date
                Write-SysPilotLog "KI-Chat $($p.Name) fehlgeschlagen: $errMsg"
                break
            }
        }
        if ($providerErr) { $lastErr = $providerErr }
    }
    return @{ Ok=$false; Text=''; Provider=''; Model=''; Error=$lastErr; ToolCalls=@() }
}

function Show-SysPilotAiProviderMenu {
    <# Provider verwalten: Status, Test, aktivieren, hinzufuegen,
       Vorschlaege fuer kostenlose Cloud-Tiers. #>
    while ($true) {
        $cfg = Read-SysPilotAiAssistConfig
        $providers = @(Get-SysPilotAiProviders)
        Write-Host ""
        Write-Host "  ========================================================" -ForegroundColor Cyan
        Write-Host "           SYSPilot KI-ASSISTENZ" -ForegroundColor Cyan
        Write-Host "           OpenAI-kompatible Provider (lokal + Cloud)" -ForegroundColor Cyan
        Write-Host "  ========================================================" -ForegroundColor Cyan
        Write-Host "  Config: $script:AiAssistConfigPath" -ForegroundColor DarkGray
        Write-Host ""
        $items = @()
        foreach ($p in $providers) {
            $st = if ($p.Kind -eq 'local') { 'lokal' } else { 'cloud' }
            $key = if ($p.ApiKey) { "Key:…$(if($p.ApiKey.Length -gt 4){$p.ApiKey.Substring($p.ApiKey.Length - 4)}else{$p.ApiKey})" } else { 'Key:-' }
            $en  = if ($p.Enabled) { 'an' } else { 'aus' }
            $col = if ($p.Enabled) { 'Green' } else { 'DarkGray' }
            $items += @{ Label = ("{0}  [{1}] {2} {3} {4}" -f $p.Name, $st, $key, $en, $p.BaseUrl); Color=$col; Tag="p:$($p.Name)" }
        }
        if ($items.Count -eq 0) { $items += @{ Label='(keine Provider erreichbar/konfiguriert)'; Color='DarkGray'; Tag=$null } }
        $items += @{ Label='[+] Provider hinzufuegen (eigener Endpoint + Key)'; Color='Cyan'; Tag='add' }
        $items += @{ Label='[?] Kostenlose Anbieter-Vorschlaege'; Color='Yellow'; Tag='suggest' }
        $items += @{ Label='[S] Anbieter-Ueberblick (Kosten + unzensierte Modelle sortiert)'; Color='Green'; Tag='overview' }
        $newsHint = if (Test-SysPilotAutoFixDue -Name 'ainews' -Hours 120) { ' *' } else { '' }
        $items += @{ Label="[N] KI-News & Intel-Kurare (Herbert aktualisiert Anbieter-Daten)$newsHint"; Color='Magenta'; Tag='newsintel' }
        $items += @{ Label='[<>] Import/Export (CSV, JSON, Key-Ordner, Router-Configs)'; Color='Green'; Tag='io' }
        $items += @{ Label='[YT] YouTube-Key-Scout (Gratis-Provider aus Videos)'; Color='Cyan'; Tag='yscout' }
        $items += @{ Label='[llama] llama.cpp Server (Vulkan/CUDA/ROCm, eigene GGUF)'; Color='Green'; Tag='llamacpp' }
        $items += @{ Label='[E] Non-Chat-Endpunkte (Modelle/Embeddings/Bilder/Audio + Pollinations-Bild)'; Color='Cyan'; Tag='endpoints' }
        $items += @{ Label='[PATH] Tool-Pfade pruefen/ergaenzen (Git, Ollama, LM Studio, llama.cpp, ...)'; Color='Yellow'; Tag='path' }
        $items += @{ Label='[K] Kaggle (Gratis-GPU, Kernel per CLI, Notebook-failed-Hilfe)'; Color='Green'; Tag='kaggle' }
        $items += @{ Label='[ok] Provider bereinigen (tote/knappe ausmustern)'; Color='Yellow'; Tag='clean' }
        $bm = Get-SysPilotAiBudgetMode
        $bmLbl = @{ smart='smart (Budget-Automatik)'; sparsam='sparsam (keine teuren)'; qualitaet='qualitaet (Budget aus)'; aus='aus' }[$bm]
        $items += @{ Label="[B] Budget-Modus: $bmLbl"; Color='Green'; Tag='budget' }
        $items += @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'KI-Provider' -Footer 'Enter = Provider-Details, Esc = zurueck'
        if ($null -eq $sel) { return }
        if ($sel -eq 'add') { Add-SysPilotAiProviderInteractive; continue }
        if ($sel -eq 'io') { try { Show-SysPilotAiImportExportMenu } catch { Write-Host "  Import/Export: $($_.Exception.Message)" -ForegroundColor Red }; continue }
        if ($sel -eq 'yscout') { Show-SysPilotYoutubeKeyScout; continue }
        if ($sel -eq 'llamacpp') { Show-SysPilotLlamaCppMenu; continue }
        if ($sel -eq 'endpoints') { Show-SysPilotAiEndpointsMenu; continue }
        if ($sel -eq 'path') { Show-SysPilotPathMenu; continue }
        if ($sel -eq 'kaggle') { Show-SysPilotKaggleMenu; continue }
        if ($sel -eq 'clean') {
            Write-Host '  Teste alle Provider ...' -ForegroundColor Cyan
            $cr = Invoke-SysPilotAiProviderCleanup
            $cr.Report | ForEach-Object { Write-Host $_ -ForegroundColor DarkGray }
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            continue
        }
        if ($sel -eq 'budget') { Show-SysPilotAiBudgetMenu; continue }
        if ($sel -eq 'suggest') {
            try { Show-SysPilotAiSuggestionsWindow } catch { Show-SysPilotAiSuggestions }
            continue
        }
        if ($sel -eq 'overview') { Show-SysPilotAiProviderOverview; continue }
        if ($sel -eq 'newsintel') { Show-SysPilotAiNewsIntelMenu; continue }
        if ($sel -like 'p:*') {
            $name = $sel.Substring(2)
            Show-SysPilotAiProviderDetail -Name $name
        }
    }
}

function Show-SysPilotAiBudgetMenu {
    <# Smart-Budget Konfiguration: Modus + globales Monats-Token-Budget
       + Uebersicht der Bezahler-Nutzung. #>
    $modeNames = @{ smart='smart'; sparsam='sparsam'; qualitaet='qualitaet'; aus='aus' }
    $modeDesc = @{
        smart    = 'Free zuerst; Bezahltes nur solange Monats-Budget reicht, dann ans Ende'
        sparsam  = 'Teure/Abo-Provider komplett aus der Auto-Kette (Pin ausgenommen)'
        qualitaet= 'Budget-Checks aus - beste Modelle zuerst, Kosten egal'
        aus      = 'Urspruenglich: reine Kosten-Sortierung, keine Caps'
    }
    $paid = Get-SysPilotAiPaidTokensThisMonth
    $bud = Get-SysPilotAiMonthlyTokenBudget
    $budTxt = if ($bud -gt 0) { "$([math]::Round($paid/1000))k / $([math]::Round($bud/1000))k Tokens" } else { "$([math]::Round($paid/1000))k Tokens (unbegrenzt)" }
    Write-Host "`n  Smart Budget" -ForegroundColor Cyan
    Write-Host "  Modus:          $(Get-SysPilotAiBudgetMode) - $($modeDesc[(Get-SysPilotAiBudgetMode)])" -ForegroundColor DarkGray
    Write-Host "  Bezahlte Tokens: $budTxt (Monat $(Get-Date -Format 'yyyy-MM'))" -ForegroundColor DarkGray
    $items = @(
        @{ Label='smart - Budget-Automatik (empfohlen)'; Color='Green'; Tag='smart' },
        @{ Label='sparsam - keine teuren/Abo-Provider'; Color='Yellow'; Tag='sparsam' },
        @{ Label='qualitaet - Budget-Checks aus'; Color='Cyan'; Tag='qualitaet' },
        @{ Label='aus - urspruengliche Sortierung'; Color='DarkGray'; Tag='aus' }
    )
    $items += @{ Label="Monats-Token-Budget setzen (aktuell: $(if($bud -gt 0){"$($bud/1000)k"}else{'unbegrenzt'}))"; Color='Yellow'; Tag='cap' }
    $items += @{ Label='Provider-Nutzung diesen Monat'; Color='DarkGray'; Tag='usage' }
    $items += @{ Label='Zurueck'; Color='DarkGray'; Tag='back' }
    $a = Show-SysPilotArrowMenu -Items $items -Title 'Smart Budget' -Footer 'Enter = waehlen, Esc = zurueck'
    if ($null -eq $a -or $a -eq 'back') { return }
    switch ($a) {
        { $_ -in @('smart','sparsam','qualitaet','aus') } {
            Set-SysPilotAiBudgetMode -Mode $a
            Write-Host "  Budget-Modus: $a" -ForegroundColor Green
        }
        'cap' {
            $in = Read-SysPilotInput 'Monats-Token-Budget in Tausend (z.B. 500 = 500k, 0 = unbegrenzt)'
            if ($null -ne $in -and "$in".Trim() -ne '') {
                $v = 0
                if ("$in".Trim() -match '^\d+$') { $v = [int64]$in * 1000 }
                elseif ("$in".Trim() -match '^\d+[.,]?\d*k?$') { $v = [int64]([double]("$in".Trim() -replace 'k$','')) * 1000 }
                Set-SysPilotAiMonthlyTokenBudget -Tokens $v
                Write-Host "  Budget: $(if($v -gt 0){"$($v/1000)k Tokens/Monat"}else{'unbegrenzt'})" -ForegroundColor Green
            }
        }
        'usage' {
            $j = Get-SysPilotAiUsage
            if ($j) {
                $month = (Get-Date).ToString('yyyy-MM')
                Write-Host "`n  Nutzung $month (Top 10):" -ForegroundColor Cyan
                $rows = foreach ($prop in $j.PSObject.Properties) {
                    $v = $prop.Value
                    if ($v.month -eq $month) {
                        $nm = ($prop.Name -split '\|',2)[1]
                        $intel = Get-SysPilotAiProviderIntel -Name $nm
                        [pscustomobject]@{ Name=$nm; Cost=$intel.Cost; Requests=[int64]$v.requests; Tokens=[int64]$v.tokens }
                    }
                }
                foreach ($r in @($rows | Sort-Object Tokens -Descending | Select-Object -First 10)) {
                    Write-Host ("    {0,-28} {1,-10} {2,6} req  {3,8} tok" -f $r.Name, $r.Cost, $r.Requests, $r.Tokens) -ForegroundColor DarkGray
                }
            } else { Write-Host '  Noch keine Nutzung erfasst.' -ForegroundColor DarkGray }
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
        }
    }
    Write-Host ''
}

function Show-SysPilotAiProviderDetail {
    param([Parameter(Mandatory)][string]$Name)
    $providers = @(Get-SysPilotAiProviders)
    $p = $providers | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if (-not $p) { return }
    $reach = $null
    if ($p.Configured) { $reach = Test-SysPilotAiProvider -Provider $p }
    Write-Host ""
    $maskedKey = if ($p.ApiKey) { if ($p.ApiKey.Length -gt 8) { "…$($p.ApiKey.Substring($p.ApiKey.Length - 4))" } else { '…' } } else { '' }
    Write-Host "  --- $($p.Name) ---" -ForegroundColor Cyan
    Write-Host "  Endpoint: $($p.BaseUrl)" -ForegroundColor DarkGray
    Write-Host "  Modell:   $(if($p.Model){$p.Model}else{'auto (erstes aus /models)'})" -ForegroundColor DarkGray
    Write-Host "  Key:      $(if($p.ApiKey){$maskedKey}else{'-'})" -ForegroundColor DarkGray
    $allowedList = @($p.AllowedModels)
    Write-Host "  Scope:    $(if($allowedList.Count -gt 0){"$($allowedList.Count) Modelle erlaubt"}else{'alle Modelle'})" -ForegroundColor DarkGray
    $usage = Get-SysPilotAiUsageSummary -Provider $p
    if ($usage) { Write-Host "  Nutzung:  $usage" -ForegroundColor DarkGray }
    if ($reach) { Write-Host "  Test:     $(if($reach.Ok){"OK ($($reach.Models) Modelle)"}else{"FEHLER: $($reach.Error)"})" -ForegroundColor $(if($reach.Ok){'Green'}else{'Red'}) }
    $acts = @(
        @{ Label = "Testen (/models)"; Color='Cyan'; Tag='test' },
        @{ Label = "Modelle anzeigen + waehlen ($(if($p.Model){'fest: '+$p.Model}else{'auto'}))"; Color='Cyan'; Tag='model' },
        @{ Label = "Modell-Scope ($(if($allowedList.Count -gt 0){"$($allowedList.Count) erlaubt"}else{'alle'}))"; Color='Magenta'; Tag='scope' }
    )
    if ($p.ApiKey) { $acts += @{ Label = 'API-Key anzeigen'; Color='DarkYellow'; Tag='key' } }
    $pCap = 0
    foreach ($cp in @(Read-SysPilotAiAssistConfig).Providers) { if ($cp.Name -eq $Name -and $cp.PSObject.Properties['TokenCapMonthly'] -and $cp.TokenCapMonthly) { $pCap = [int64]$cp.TokenCapMonthly } }
    $acts += @{ Label = "Monats-Token-Cap ($(if($pCap -gt 0){"$($pCap/1000)k"}else{'kein'}))"; Color='DarkYellow'; Tag='moncap' }
    $acts += @{ Label = $(if ($p.Enabled) { 'Deaktivieren' } else { 'Aktivieren' }); Color='Yellow'; Tag='toggle' }
    if ($p.Configured) { $acts += @{ Label = 'Entfernen'; Color='Red'; Tag='del' } }
    $acts += @{ Label = 'Zurueck'; Color='DarkGray'; Tag='back' }
    $a = Show-SysPilotArrowMenu -Items $acts -Title $p.Name -Footer 'Enter = Aktion, Esc = zurueck'
    if ($null -eq $a -or $a -eq 'back') { return }
    $cfg = Read-SysPilotAiAssistConfig
    switch ($a) {
        'model' {
            # Provider-Objekt fuer Modellliste (ApiKey entschluesselt)
            $pp = [pscustomobject]@{ Name=$p.Name; BaseUrl=$p.BaseUrl; Model=$p.Model; ApiKey=$p.ApiKey; Kind=$p.Kind }
            [void](Select-SysPilotAiProviderModel -Provider $pp)
            return
        }
        'key' {
            Write-Host "`n  API-Key ($($p.Name)):`n  $($p.ApiKey)`n" -ForegroundColor Yellow
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
        }
        'scope' {
            # Modell-Scope: welche /models-IDs darf dieser Key nutzen?
            $ml = Get-SysPilotAiProviderModels -Provider $p -TimeoutSec 12
            if (-not $ml.Ok -or @($ml.Models).Count -eq 0) {
                Write-Host "  [!] Keine Modellliste - Provider erst testen." -ForegroundColor Red
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
                return
            }
            $allowedLower = @($p.AllowedModels | ForEach-Object { "$_".ToLower() })
            $items = @($ml.Models | ForEach-Object { @{ Label=[string]$_.Id; Tag=[string]$_.Id; Checked=($allowedLower -contains ([string]$_.Id).ToLower()) } })
            $sel = @(Show-SysPilotMultiSelectMenu -Items $items -Title "Modell-Scope: $($p.Name)" -Footer 'Leertaste=an/aus, Enter=fertig, Esc=abbruch')
            if ($null -ne $sel) {
                $scope = @($sel | ForEach-Object { [string]$_ } | Where-Object { $_ })
                foreach ($cp in @($cfg.Providers)) {
                    if ($cp.Name -eq $Name) {
                        if ($scope.Count -gt 0) { $cp | Add-Member -NotePropertyName AllowedModels -NotePropertyValue $scope -Force }
                        else { $cp.PSObject.Properties.Remove('AllowedModels') }
                    }
                }
                Write-SysPilotAiAssistConfig $cfg
                Write-Host "  Scope gespeichert: $(if($scope.Count -gt 0){"$($scope.Count) Modelle"}else{'alle Modelle'})" -ForegroundColor Green
            }
            return
        }
        'moncap' {
            $in = Read-SysPilotInput "Monats-Token-Cap fuer '$Name' in Tausend (0 = kein Limit)"
            if ($null -ne $in -and "$in".Trim() -ne '') {
                $v = 0
                if ("$in".Trim() -match '^\d+$') { $v = [int64]$in * 1000 }
                elseif ("$in".Trim() -match '^\d+[.,]?\d*k?$') { $v = [int64]([double]("$in".Trim() -replace 'k$','')) * 1000 }
                foreach ($cp in @($cfg.Providers)) {
                    if ($cp.Name -eq $Name) {
                        if ($v -gt 0) { $cp | Add-Member -NotePropertyName TokenCapMonthly -NotePropertyValue $v -Force }
                        else { $cp.PSObject.Properties.Remove('TokenCapMonthly') }
                    }
                }
                Write-SysPilotAiAssistConfig $cfg
                Write-Host "  Cap: $(if($v -gt 0){"$($v/1000)k Tokens/Monat"}else{'entfernt'})" -ForegroundColor Green
            }
            return
        }
        'test' {
            Write-Host " Teste $($p.Name) ..." -ForegroundColor Cyan
            $t = Test-SysPilotAiProvider -Provider $p
            if ($t.Ok) { Write-Host "  [OK] $($t.Models) Modelle verfuegbar" -ForegroundColor Green }
            else { Write-Host "  [!] $($t.Error)" -ForegroundColor Red }
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
        }
        'toggle' {
            foreach ($cp in @($cfg.Providers)) {
                if ($cp.Name -eq $Name) {
                    $cp | Add-Member -NotePropertyName Enabled -NotePropertyValue (-not ($null -eq $cp.Enabled -or $cp.Enabled -eq $true)) -Force
                }
            }
            Write-SysPilotAiAssistConfig $cfg
            Write-Host "  Status geaendert." -ForegroundColor Green
        }
        'del' {
            $cfg.Providers = @($cfg.Providers | Where-Object { $_.Name -ne $Name })
            Write-SysPilotAiAssistConfig $cfg
            Write-Host "  $Name entfernt." -ForegroundColor Green
        }
    }
}

function Add-SysPilotAiProviderInteractive {
    <# WPF-Dialog (Maus, Rechtsklick-Paste); Faellt auf
       Read-SysPilotInput-Felder zurueck wenn WPF nicht verfuegbar. #>
    try {
        $e = Show-SysPilotAiProviderEditDialog
        if ($e) {
            Save-SysPilotAiProviderEntry -Entry $e
            Write-Host "  $($e.Name) hinzugefuegt." -ForegroundColor Green
        }
        return
    } catch { }
    # Fallback: Einzelfelder (selbst mit WPF-Input, sonst Konsole)
    $name = Read-SysPilotInput 'Anzeigename (z.B. "Mein OpenRouter")'
    if (-not $name) { return }
    $url = Read-SysPilotInput 'Base-URL (z.B. https://openrouter.ai/api/v1)'
    if (-not $url) { return }
    $model = Read-SysPilotInput 'Modell (leer = auto)'
    $key = Read-SysPilotInput 'API-Key (leer = keiner)'
    $kind = Read-SysPilotInput 'Art (cloud/lokal, Enter=cloud)'
    Save-SysPilotAiProviderEntry -Entry @{
        Name=$name; BaseUrl=$url; Model=$model
        Kind=$(if($kind -eq 'lokal'){'lokal'}else{'cloud'})
        Enabled=$true; ApiKey=$key; HasKeyInput=($key.Trim().Length -gt 0)
    }
    Write-Host "  $name hinzugefuegt." -ForegroundColor Green
}

function Show-SysPilotAiSuggestions {
    <# Kostenlose Cloud-Tiers mit_signup_-Links; "Uebernehmen" legt den
       Provider an und fragt den Key ab. #>
    $sugg = @(Get-SysPilotAiProviderCatalog)
    $items = foreach ($s in $sugg) {
        @{ Label = "$($s.Name) - $($s.Note)"; Color='Yellow'; Tag=$s }
    }
    $items += @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
    $sel = Show-SysPilotArrowMenu -Items $items -Title 'Kostenlose KI-Anbieter' -Footer 'Enter = Signup oeffnen/Provider anlegen, Esc = zurueck'
    if ($null -eq $sel) { return }
    Write-Host "`n  Signup: $($sel.Signup)" -ForegroundColor Cyan
    Start-Process $sel.Signup
    if (Confirm-SysPilot "Provider '$($sel.Name)' anlegen? (Key danach in Provider-Details hinterlegen)") {
        $cfg = Read-SysPilotAiAssistConfig
        $exists = @($cfg.Providers | Where-Object { $_.BaseUrl -eq $sel.BaseUrl }).Count -gt 0
        if (-not $exists) {
            $cfg.Providers = @($cfg.Providers) + @([pscustomobject]@{
                Name=$sel.Name; BaseUrl=$sel.BaseUrl; Model=$sel.Model; Kind='cloud'
                Enabled=$true; ApiKeyCipher=''
            })
            Write-SysPilotAiAssistConfig $cfg
            Write-Host "  Angelegt - jetzt unter Provider-Details den API-Key eintragen." -ForegroundColor Green
        } else { Write-Host "  Bereits konfiguriert." -ForegroundColor DarkGray }
    }
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
}

function Show-SysPilotAiChat {
    <# Interaktiver Chat mit dem Assistant (Multi-Turn, Provider-Fallback).
       /clear = Verlauf loeschen, /quit = beenden. #>
    param([string]$Context = '')
    $history = @()
    $sysNote = if ($Context) { " Kontext: $Context" } else { '' }
    Write-Host "`n  === PILOT HERBERT - FLUG 667 ===" -ForegroundColor Cyan
    Write-Host "  (Bord-Assistent von SysPilot)" -ForegroundColor DarkGray
    Write-Host "  Provider werden automatisch probiert (Fallback-Kette)." -ForegroundColor DarkGray
    Write-Host "  Befehle: /clear (Verlauf), /quit (Ende)`n" -ForegroundColor DarkGray
    while ($true) {
        $q = Read-SysPilotChoice "Du$sysNote"
        if (-not $q) { continue }
        if ($q -eq '/quit' -or $q -eq '/exit') { return }
        if ($q -eq '/clear') { $history = @(); Write-Host '  Verlauf geloescht.' -ForegroundColor DarkGray; continue }
        Write-Host '  Denke nach ...' -ForegroundColor DarkGray
        $r = Invoke-SysPilotAiChat -Prompt $q -History $history -TimeoutSec 120
        if (-not $r.Ok) {
            Write-Host "  [!] $($r.Error)" -ForegroundColor Red
            Write-Host '  Tipp: SysPilot -> KI-Assistenz -> Provider einrichten' -ForegroundColor DarkYellow
            continue
        }
        Write-Host "`n  [$($r.Provider) / $($r.Model)]`n" -ForegroundColor DarkCyan -NoNewline
        $clean = [regex]::Replace($r.Text, '\s*<<<AKTION:[a-zA-Z0-9_-]+>>>\s*', "`n").Trim()
        $hadAct = ($clean -ne $r.Text.Trim())
        Write-Host $clean -ForegroundColor White
        Write-Host ''
        if ($hadAct) { Write-Host '  (Hinweis: Aktionen sind in der SysPilot-GUI per "Uebernehmen"-Button ausfuehrbar)' -ForegroundColor DarkYellow }
        # Sprachausgabe (VoiceMode 'speak'): Antwort vorlesen -
        # an/ausschaltbar unter Endpunkte > Voice.
        if ((Get-SysPilotAiVoiceMode) -eq 'speak') {
            [void](Invoke-SysPilotAiSpeak -Text $clean)
        }
        $history += @{ role='user'; content=$q }
        $history += @{ role='assistant'; content=$clean }
        if ($history.Count -gt 20) { $history = @($history | Select-Object -Last 20) }
    }
}

function Show-SysPilotAiQuickAsk {
    <# Einmalige KI-Frage mit Kontext - fuer Integrationen in andere
       Module (z.B. Fehlermeldung erklaeren, Einstellungsempfehlung).
       Schreibt Antwort + Provider auf Konsole. Gibt Answer-Objekt. #>
    param([Parameter(Mandatory)][string]$Prompt, [string]$System = '', [string]$Title = 'KI-Assistent')
    Write-Host "`n  === $Title ===" -ForegroundColor Cyan
    Write-Host "  Frage: $($Prompt.Substring(0,[Math]::Min(100,$Prompt.Length)))" -ForegroundColor DarkGray
    $r = Invoke-SysPilotAiChat -Prompt $Prompt -System $System -TimeoutSec 120
    if (-not $r.Ok) {
        Write-Host "  [!] $($r.Error)" -ForegroundColor Red
        return $r
    }
    Write-Host "  [$($r.Provider) / $($r.Model)]`n" -ForegroundColor DarkCyan -NoNewline
    Write-Host $r.Text -ForegroundColor White
    Write-Host ''
    return $r
}

function Get-SysPilotAiOnboardState {
    <# Liest Onboarded-Flag aus der Config (fehlende Config = nicht
       eingerichtet). #>
    $cfg = Read-SysPilotAiAssistConfig
    return ($null -ne $cfg.Onboarded -and $cfg.Onboarded -eq $true)
}

function Set-SysPilotAiOnboarded {
    $cfg = Read-SysPilotAiAssistConfig
    $cfg | Add-Member -NotePropertyName Onboarded -NotePropertyValue $true -Force
    Write-SysPilotAiAssistConfig $cfg
}

function Get-SysPilotAiProcessHintsEnabled {
    <# Pilot Herbert: Hinweise bei neu geoeffneten Programmen.
       Default AN, per Config/GUI stumm schaltbar. #>
    $cfg = Read-SysPilotAiAssistConfig
    if ($cfg.PSObject.Properties['ProcessHints']) { return [bool]$cfg.ProcessHints }
    return $true
}

function Set-SysPilotAiProcessHintsEnabled {
    param([bool]$On)
    $cfg = Read-SysPilotAiAssistConfig
    $cfg | Add-Member -NotePropertyName ProcessHints -NotePropertyValue $On -Force
    Write-SysPilotAiAssistConfig $cfg
}

function Get-SysPilotHerbertAnnouncementsEnabled {
    <# Bord-Ansagen (Flug-Ansagen, Wetteraussprueche etc.) separat
       schaltbar. Default = ProcessHints-Status (wer Hinweise stumm
       schaltete, will auch keine Ansagen). #>
    $cfg = Read-SysPilotAiAssistConfig
    if ($cfg.PSObject.Properties['Announcements']) { return [bool]$cfg.Announcements }
    return (Get-SysPilotAiProcessHintsEnabled)
}

function Set-SysPilotHerbertAnnouncementsEnabled {
    param([bool]$On)
    $cfg = Read-SysPilotAiAssistConfig
    $cfg | Add-Member -NotePropertyName Announcements -NotePropertyValue $On -Force
    Write-SysPilotAiAssistConfig $cfg
}

function Get-SysPilotAiProviderMode {
    <# 'auto' = Cloud zuerst, lokal als Fallback (Standard);
       'local' = strict lokal (kein Cloud); 'cloud' = strict Cloud. #>
    $cfg = Read-SysPilotAiAssistConfig
    if ($cfg.PSObject.Properties['ProviderMode'] -and $cfg.ProviderMode) { return [string]$cfg.ProviderMode }
    return 'auto'
}

function Set-SysPilotAiProviderMode {
    param([Parameter(Mandatory)][ValidateSet('auto','local','cloud')][string]$Mode)
    $cfg = Read-SysPilotAiAssistConfig
    $cfg | Add-Member -NotePropertyName ProviderMode -NotePropertyValue $Mode -Force
    Write-SysPilotAiAssistConfig $cfg
}

function Get-SysPilotAiPreferredProvider {
    <# Gepinnter Provider: wird in der Auto-Kette an erste Stelle
       gesetzt ('' = keine Pin). #>
    $cfg = Read-SysPilotAiAssistConfig
    if ($cfg.PSObject.Properties['PreferredProvider']) { return [string]$cfg.PreferredProvider }
    return ''
}

function Set-SysPilotAiPreferredProvider {
    param([string]$Name = '')
    $cfg = Read-SysPilotAiAssistConfig
    $cfg | Add-Member -NotePropertyName PreferredProvider -NotePropertyValue $Name -Force
    Write-SysPilotAiAssistConfig $cfg
}

# --- Smart Budget (an-/abschaltbare Kosten-Automatik) ---
# Modes: 'smart'    = Free zuerst, Bezahltes nur solange Monats-Budget
#                     (MonthlyTokenBudget) reicht; ueberschritten -> Bezahlte
#                     ans Ende der Kette (Free-Lokales zuerst).
#        'sparsam'  = Bezahlte Provider (teuer/abo/mittel) komplett aus der
#                     Auto-Kette - ausser per Pin ausdruecklich gewaehlt.
#        'qualitaet'= Budget-Checks aus - beste Modelle zuerst, Kosten
#                     werden nicht beruecksichtigt (Abo/Direktzahl dominiert).
#        'aus'      = Urspruengliches Verhalten (reine Kosten-Sortierung,
#                     keine Caps).
function Get-SysPilotAiBudgetMode {
    $cfg = Read-SysPilotAiAssistConfig
    if ($cfg.PSObject.Properties['BudgetMode'] -and $cfg.BudgetMode) { return [string]$cfg.BudgetMode }
    return 'smart'
}
function Set-SysPilotAiBudgetMode {
    param([Parameter(Mandatory)][ValidateSet('smart','sparsam','qualitaet','aus')][string]$Mode)
    $cfg = Read-SysPilotAiAssistConfig
    $cfg | Add-Member -NotePropertyName BudgetMode -NotePropertyValue $Mode -Force
    Write-SysPilotAiAssistConfig $cfg
}
function Get-SysPilotAiMonthlyTokenBudget {
    <# Globales Monats-Token-Budget fuer BEZAHLTE Provider (0 = unbegrenzt).
       Gilt nur in 'smart'-Mode; zaehlt ai-usage.json (Monats-Zaehler). #>
    $cfg = Read-SysPilotAiAssistConfig
    if ($cfg.PSObject.Properties['MonthlyTokenBudget'] -and $null -ne $cfg.MonthlyTokenBudget) { return [int64]$cfg.MonthlyTokenBudget }
    return 0
}
function Set-SysPilotAiMonthlyTokenBudget {
    param([Parameter(Mandatory)][int64]$Tokens)
    $cfg = Read-SysPilotAiAssistConfig
    $cfg | Add-Member -NotePropertyName MonthlyTokenBudget -NotePropertyValue $Tokens -Force
    Write-SysPilotAiAssistConfig $cfg
}
function Get-SysPilotAiPaidTokensThisMonth {
    <# Summe der Monats-Tokens ueber alle Provider mit Cost NICHT in
       (kostenlos,lokal) - also das was wirklich Geld kosten kann. #>
    $month = (Get-Date).ToString('yyyy-MM')
    $sum = [int64]0
    $j = Get-SysPilotAiUsage
    if (-not $j) { return 0 }
    foreach ($prop in $j.PSObject.Properties) {
        $v = $prop.Value
        if ($v.month -eq $month) {
            # Provider-Name aus Schluessel "baseUrl|name" - Cost-Nachschlag
            $nm = ($prop.Name -split '\|',2)[1]
            $intel = Get-SysPilotAiProviderIntel -Name $nm
            if ($intel.Cost -notin @('kostenlos','lokal')) { $sum += [int64]$v.tokens }
        }
    }
    return $sum
}
function Test-SysPilotAiProviderBudgetExceeded {
    <# True wenn dieser Provider sein Monats-Limit (TokenCapMonthly im
       Provider-Config) ueberschritten hat. #>
    param([Parameter(Mandatory)]$Provider)
    $cap = 0
    $cfg = Read-SysPilotAiAssistConfig
    foreach ($cp in @($cfg.Providers)) {
        if ($cp.Name -eq $Provider.Name -and $cp.PSObject.Properties['TokenCapMonthly'] -and $cp.TokenCapMonthly) {
            $cap = [int64]$cp.TokenCapMonthly; break
        }
    }
    if ($cap -le 0) { return $false }
    $j = Get-SysPilotAiUsage
    if (-not $j) { return $false }
    $month = (Get-Date).ToString('yyyy-MM')
    $key = "$($Provider.BaseUrl.ToLower().TrimEnd('/'))|$($Provider.Name)"
    $cur = $j.$key
    return ($cur -and $cur.month -eq $month -and [int64]$cur.tokens -ge $cap)
}

function Get-SysPilotHerbertAnnouncements {
    <# Pilot Herbert: Bord-Durchsagen-Pool. Kategorien:
       welcome | wetter | sicherheit | nacht | song | flieger |
       hotshots | turbulenz | landung.
       Fliegerlied (F.P.1 antwortet nicht, 1932) + Hot-Shots-Zitate
       (1991) als wahre Zeilen; Hot-Shots-Eintraege sind Uebersetzungen
       echter IMDb-verifizierter Zitate. Rest = eigenes Material. #>
    return @(
        # --- welcome ---
        @{ Cat='welcome'; Text='Willkommen an Bord von Flug 667. Pilot Herbert hat das Kommando - SysPilot ist betankt und provisioniert.' }
        @{ Cat='welcome'; Text='Guten Tag, meine Damen und Herren. Hier spricht Pilot Herbert. Der Wetterbericht folgt gleich - vorerst: Anschnallzeichen leuchtet.' }
        @{ Cat='welcome'; Text='Flug 667 startet in Kuerze. Ich fuehre Sie sicher durch die System-Wartung - Ziel: ein gesunder Rechner.' }
        # --- wetter ---
        @{ Cat='wetter'; Text='Wetterbericht: ueber Ihrem Mainboard nur wenige Wolken, Bodenfrost im Cache bei minus ein Grad - packen Sie sich warm an.' }
        @{ Cat='wetter'; Text='Aktuell ziehen einzelne Update-Wolken auf, aber die Sicht auf Ihre Festplatten bleibt klar.' }
        @{ Cat='wetter'; Text='Vorausschau: die naechsten zwei Stunden versprechen ruhigen Flug ohne nennenswerte Turbulenzen.' }
        @{ Cat='wetter'; Text='Der Niederschlag ueber Ihrem System beschraenkt sich auf Arsache - naemlich Altlasten im Temp-Ordner.' }
        # --- sicherheit ---
        @{ Cat='sicherheit'; Text='Bitte stellen Sie das Rauchen ein und schnallen Sie sich an.' }
        @{ Cat='sicherheit'; Text='Im Notfall sinkt automatisch eine Maske aus der Decke - bei SysPilot ist das der Papierkorb. Gehen Sie sorgfaeltig damit um.' }
        @{ Cat='sicherheit'; Text='Bei Turbulenzen: Laptop festhalten, Prozesse nicht auf den Boden werfen.' }
        @{ Cat='sicherheit'; Text='Hinweis zur Sicherheit: SysPilot fliegt nur mit geprueften Updates - unautorisierte Pakete werden nicht mitgefuehrt.' }
        # --- nacht ---
        @{ Cat='nacht'; Text='Wir befinden uns im Nachtflug nach London. Die Kabinenbeleuchtung wird gedimmt - genau wie die Bildschirme um Mitternacht.' }
        @{ Cat='nacht'; Text='Nachtflug 667: Halten Sie Ihren Kaffee griffbereit - und vergessen Sie nicht, dass Herbert auch nachts fuer Sie da ist.' }
        @{ Cat='nacht'; Text='Auf dem Radar sehen wir nur noch eins: Ihren Papierkorb. Wir ziehen darueber hinweg, ohne ihn zu beruehren.' }
        # --- song (Krupps-Vibes, eigenstaendige Zeilen) ---
        @{ Cat='song'; Text='Und die Krupps haben geliefert - synthetische Energie fuer Ihren CPU-Takt. Pervitin? Nein, Power-Plan!' }
        @{ Cat='song'; Text='Gruen wie ein Pfannkuchen und schneller als der Schall - so fliegt Herbert heute Nacht ueber Ihrem Mainboard.' }
        @{ Cat='song'; Text='Tempo, Tempo! Die Ansage vor dem Abheben: Anschnallzeichen beachten, dann geht es ab in den naechsten Update.' }
        @{ Cat='song'; Text='Es ist ein hartes Leben an Bord - aber jemand muss ja die Updater im Zaum halten.' }
        # --- flieger (Fliegerlied, F.P.1 antwortet nicht, 1932) ---
        @{ Cat='flieger'; Text='Flieger, gruess mir die Sonne, gruess mir die Sterne und gruess mir den Mond.' }
        @{ Cat='flieger'; Text='Vom Nordpol zum Suedpol ist nur ein Katzensprung - wir fliegen die Strecke bei jeder Witterung.' }
        @{ Cat='flieger'; Text='Wir warten nicht, wir starten - was immer auch geschieht. Durch Wind und Wetter klingt das Fliegerlied.' }
        @{ Cat='flieger'; Text='Dein Leben, das ist ein Schweben durch die Ferne, die keiner bewohnt.' }
        @{ Cat='flieger'; Text='Schneller und immer schneller rast der Propeller - wie dir''s grad gefaellt.' }
        @{ Cat='flieger'; Text='Piloten ist nichts verboten - drum gib Vollgas und flieg um die Welt.' }
        @{ Cat='flieger'; Text='Hoch oben im Aether, da sind wir meist zu Haus - bei fuenftausend Meter sieht alles anders aus.' }
        @{ Cat='flieger'; Text='Da gibt''s keine Grenzen, da gibt''s keinen Pass - der Flieger fliegt und fragt nicht: Wie und was?' }
        # --- hotshots (Hot Shots!, 1991 - echte Zitate, uebersetzt) ---
        @{ Cat='hotshots'; Text='Hot Shots-Vorschlag: "Ich habe persoenlich ueber 194 Einsaetze geflogen und wurde bei jedem abgeschossen. Jetzt wo ich dran denke - ich habe noch nie ein Flugzeug gelandet." (Admiral Benson)' }
        @{ Cat='hotshots'; Text='"Ich hatte nie Zeit fuer die Liebe - zu schwer, ein Anker der einen Mann ertraenkt. Ich habe den Himmel, den Geruch von Jet-Antrieb, mein Motorrad. Ein Einzelgaenger? Nein. Ich besitze ihn." (Topper Harley)' }
        @{ Cat='hotshots'; Text='"Mein Herz rutscht mir wie eine nasse Hose in die Knie - mein ganzes Leben wollte ich nur fliegen und Zeug bomben." (Topper Harley)' }
        @{ Cat='hotshots'; Text='"Koennen Sie ihn retten?" - "Nicht sicher. Ich bin kein besonders guter Doktor." (SysPilot-Klinik, Hot-Shots-Style)' }
        @{ Cat='hotshots'; Text='"Ich will nicht zurueck." - Hot-Shots-Motto fuer den naechsten Neustart.' }
        @{ Cat='hotshots'; Text='"Es ist nicht viel. 2500." - Topper ueber seinen heroin-Sparplan. SysPilot legt stattdessen Updates auf Eis.' }
        # --- turbulenz (bei Log-Fehlern) ---
        @{ Cat='turbulenz'; Text='Achtung,leichte Turbulenzen voraus - das Log zeigt ein paar Beulen. Anschnallzeichen an, wir finden die Ursache.' }
        @{ Cat='turbulenz'; Text='Turbulenzzone erreicht: SysPilot hatte ein holpriges Manuals. Keine Sorge - das ist reparierbar.' }
        @{ Cat='turbulenz'; Text='Bordansage: Wir haben ein unruhiges Luftloch durchflogen. Die Maske faellt nicht - aber ein Blick ins Log schadet nicht.' }
        # --- landung (nach Aktion/Tool-Erfolg) ---
        @{ Cat='landung'; Text='Ansage: Aktion sicher ausgefuehrt. Wir naehern uns der Landung - SysPilot dankt fuer die flotte Mithilfe.' }
        @{ Cat='landung'; Text='Die Aktion ist durchgefuehrt und das Flugzeug bleibt in der Luft. Willkommen zurueck im Reiseflughafen SysPilot.' }
    )
}

function Get-SysPilotHerbertAnnouncement {
    <# Zufaellige Ansage; optional nach Kategorie(n) filtern. #>
    param([string[]]$Category = @())
    $all = @(Get-SysPilotHerbertAnnouncements)
    if ($Category.Count -gt 0) { $all = @($all | Where-Object { $_.Cat -in $Category }) }
    if ($all.Count -eq 0) { return $null }
    return $all | Get-Random
}

function Get-SysPilotAiKeyDirs {
    <# Findet alle 'api key'-aehnlichen Ordner unter Dokumente
       ('api key', 'api keys', Abweichungen) und sortiert sie nach
       Anzahl enthaltener .txt-Dateien (groesster zuerst).
       Deckt den haeufigen Fall 'api key' vs. 'api keys' ab. #>
    $docs = [Environment]::GetFolderPath('MyDocuments')
    $dirs = @()
    foreach ($d in @(Get-ChildItem $docs -Directory -ErrorAction SilentlyContinue)) {
        if ($d.Name -match '(?i)^api[\s_\-]*keys?$') { $dirs += $d.FullName }
    }
    if ($dirs.Count -eq 0) { $dirs = @((Join-Path $docs 'api keys')) }
    return @($dirs | Sort-Object {
        @(Get-ChildItem $_ -Recurse -Depth 3 -Filter '*.txt' -File -ErrorAction SilentlyContinue).Count
    } -Descending)
}

function Get-SysPilotAiKeyBackupDir {
    <# Backup-Ziel fuer Key-Exports: der 'api key'-Ordner mit den
       meisten .txt-Dateien (meist der bestehende Benutzer-Ordner). #>
    foreach ($d in @(Get-SysPilotAiKeyDirs)) {
        if (Test-Path $d) { return $d }
    }
    return (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'api keys')
}

function Save-SysPilotAiKeyBackup {
    <# Schreibt pro konfiguriertem Provider eine .txt mit Name,
       Base-URL, Modell und API-Key nach
       Dokumente\api keys\ - zur Wiederverwendung in anderen Tools.
       ACHTUNG: Keys liegen dann PLAINTEXT auf der Platte - nur auf
       vertrauenswuerdigen Systemen, ggf. spaeter loeschen. #>
    param([switch]$Quiet)
    $dir = Get-SysPilotAiKeyBackupDir
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $providers = @(Get-SysPilotAiProviders | Where-Object { $_.Configured -and $_.ApiKey })
    if ($providers.Count -eq 0) {
        if (-not $Quiet) { Write-Host '  Keine Provider mit API-Key konfiguriert.' -ForegroundColor Yellow }
        return 0
    }
    $n = 0
    foreach ($p in $providers) {
        $safe = ($p.Name -replace '[^\w\-\. ]', '_')
        $f = Join-Path $dir "$safe.txt"
        @(
            "SysPilot KI-Provider Export",
            "Name:     $($p.Name)",
            "Base URL: $($p.BaseUrl)",
            "Modell:   $(if($p.Model){$p.Model}else{'auto'})",
            "API Key:  $($p.ApiKey)",
            "",
            "OpenAI-kompatibel: POST $($p.BaseUrl.TrimEnd('/'))/chat/completions",
            "Header: Authorization: Bearer <API-Key>",
            "",
            "ACHTUNG: API-Key im Klartext - nur auf vertrauenswuerdigen Systemen.",
            "Exportiert: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
        ) | Set-Content $f -Encoding UTF8
        $n++
    }
    if (-not $Quiet) {
        Write-Host "  $n Key-Datei(en) gespeichert unter:" -ForegroundColor Green
        Write-Host "  $dir" -ForegroundColor Cyan
        Write-Host '  (plaintext - nur vertrauenswuerdig, nicht weitergeben)' -ForegroundColor DarkYellow
    }
    return $n
}

# ---------- Import / Export von Providern ----------

function Get-SysPilotAiProviderEntryFromHashtable {
    <# Normalisiert eine Provider-Quelle (Hashtable/PSObject) in das
       SysPilot-Format. Erkennt uebliche Feldnamen
       (Name/name, BaseUrl/base_url/baseURL/url/endpoint,
       ApiKey/api_key/apiKey/key/token, Model/model,
       Enabled/enabled, Kind/kind/type). #>
    param([Parameter(Mandatory)]$Raw)
    # Hashtables haben keine PSObject-Properties fuer ihre Keys ->
    # erst in pscustomobject wandeln (Import aus CSV/Key-Dateien)
    if ($Raw -is [System.Collections.IDictionary]) { $Raw = [pscustomobject]$Raw }
    $get = {
        param($names)
        foreach ($n in $names) {
            foreach ($pn in $Raw.PSObject.Properties.Name) {
                if ($pn -eq $n) { return $Raw.$pn }
            }
        }
        return $null
    }
    $name = & $get @('Name','name','id','provider','title','label')
    $url  = & $get @('BaseUrl','base_url','baseURL','url','endpoint','api_base','apiBase','host')
    $key  = & $get @('ApiKey','api_key','apiKey','key','token','access_token','api-key')
    $model= & $get @('Model','model','default_model','defaultModel','model_id')
    $en   = & $get @('Enabled','enabled','active')
    $kind = & $get @('Kind','kind','type','provider_type')
    if (-not $name -or -not $url) { return $null }
    $url = "$url".Trim()
    if ($url -notmatch '^https?://') { $url = "https://$url" }
    $kindS = "$kind".ToLower()
    return @{
        Name = "$name".Trim()
        BaseUrl = $url.TrimEnd('/')
        Model = "$model".Trim()
        ApiKey = "$key".Trim()
        Kind = $(if ($kindS -match 'local|lokal|ollama|lmstudio') { 'local' } else { 'cloud' })
        Enabled = $(if ($null -eq $en) { $true } else { [bool]$en })
    }
}

function Export-SysPilotAiProvidersFile {
    <# Exportiert die KONFIGURIERTEN Provider (inkl. API-Keys als
       Klartext!) als CSV oder JSON. Aufruf:
       Export-SysPilotAiProvidersFile -Path x.csv|-Path x.json #>
    param([Parameter(Mandatory)][string]$Path)
    $providers = @(Get-SysPilotAiProviders | Where-Object { $_.Configured })
    if ($providers.Count -eq 0) { return @{ Ok=$false; Message='Keine konfigurierten Provider' } }
    $ext = [IO.Path]::GetExtension($Path).ToLower()
    if ($ext -eq '.json') {
        $out = @($providers | ForEach-Object {
            [pscustomobject]@{ Name=$_.Name; BaseUrl=$_.BaseUrl; Model=$_.Model; Kind=$_.Kind; Enabled=$_.Enabled; ApiKey=$_.ApiKey }
        })
        $out | ConvertTo-Json -Depth 5 | Set-Content $Path -Encoding UTF8
        return @{ Ok=$true; Message="JSON exportiert: $Path ($($out.Count) Provider)" }
    }
    # CSV: Semikolon-getrennt, Headerzeile - mit BOM fuer Excel
    $lines = @('Name;BaseUrl;Model;Kind;Enabled;ApiKey')
    foreach ($p in $providers) {
        $esc = { param($v) ($v -replace ';',',') }
        $lines += (@($p.Name, $p.BaseUrl, $p.Model, $p.Kind, $p.Enabled, $p.ApiKey) | ForEach-Object { & $esc $_ }) -join ';'
    }
    [IO.File]::WriteAllLines($Path, $lines, [Text.UTF8Encoding]::new($true))
    return @{ Ok=$true; Message="CSV exportiert: $Path ($($providers.Count) Provider)" }
}

function Import-SysPilotAiProvidersData {
    <# Importiert Provider aus einem Array von Eintraegen
       (Hashtables/PSObjects). Upsert per Name+BaseUrl.
       Gibt @{Added;Updated;Skipped;Report} zurueck. #>
    param([Parameter(Mandatory)][object[]]$Entries)
    $cfg = Read-SysPilotAiAssistConfig
    $added=0; $updated=0; $skipped=@(); $report=@()
    foreach ($raw in @($Entries)) {
        $e = Get-SysPilotAiProviderEntryFromHashtable -Raw $raw
        if (-not $e) { $skipped += "$raw"; continue }
        if ($e.BaseUrl -notmatch '^https?://') { $skipped += "$($e.Name): ungueltige URL"; continue }
        $existing = $null
        foreach ($cp in @($cfg.Providers)) {
            if ($cp.Name -eq $e.Name -or $cp.BaseUrl -eq $e.BaseUrl) { $existing = $cp }
        }
        $cipher = if ($e.ApiKey) { Protect-SysPilotSecret $e.ApiKey } else { '' }
        if ($existing) {
            if (-not $cipher) { $cipher = [string]$existing.ApiKeyCipher }
            $existing.BaseUrl = $e.BaseUrl
            if ($e.Model) { $existing.Model = $e.Model }
            if ($e.ApiKey) { $existing.ApiKeyCipher = $cipher }
            if ($null -ne $e.Enabled) { $existing | Add-Member -NotePropertyName Enabled -NotePropertyValue $e.Enabled -Force }
            $updated++
            $report += "  aktualisiert: $($e.Name)"
        } else {
            $cfg.Providers = @($cfg.Providers) + @([pscustomobject]@{
                Name=$e.Name; BaseUrl=$e.BaseUrl; Model=$e.Model; Kind=$e.Kind
                Enabled=$e.Enabled; ApiKeyCipher=$cipher
            })
            $added++
            $report += "  hinzugefuegt: $($e.Name) ($($e.BaseUrl))"
        }
    }
    Write-SysPilotAiAssistConfig $cfg
    return @{ Added=$added; Updated=$updated; Skipped=$skipped; Report=$report }
}

function Import-SysPilotAiProvidersFile {
    <# Importiert Provider aus CSV/JSON-Datei (eigener Export,
       OmniRoute- oder generisches Format). #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return @{ Ok=$false; Message="Datei nicht gefunden: $Path" } }
    $ext = [IO.Path]::GetExtension($Path).ToLower()
    $entries = @()
    try {
        if ($ext -eq '.json') {
            $j = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json
            # Formate: Array, @{Providers=@(...)}, @{providers=@(...)}, oder einzelnes Objekt
            if ($j -is [array]) { $entries = @($j) }
            elseif ($j.PSObject.Properties['providers']) { $entries = @($j.providers) }
            elseif ($j.PSObject.Properties['Providers']) { $entries = @($j.Providers) }
            else { $entries = @($j) }
            # VERSCHACHTELT: z.B. OmniRoute {"providers":{"openai":[{...}]}} - flach collecten
            $flat = @()
            foreach ($en in $entries) {
                $flat += $en
                if ($en -and $en.PSObject.Properties.Count -gt 0) {
                    foreach ($pn in $en.PSObject.Properties.Name) {
                        $pv = $en.$pn
                        if ($pv -is [array] -and $pv.Count -gt 0 -and $pv[0] -isnot [string]) { $flat += @($pv) }
                        elseif ($pv -is [pscustomobject] -and ($pv.PSObject.Properties['baseUrl'] -or $pv.PSObject.Properties['base_url'] -or $pv.PSObject.Properties['url'])) { $flat += $pv }
                    }
                }
            }
            $entries = @($flat | Where-Object { $_ -isnot [string] })
        } elseif ($ext -eq '.csv' -or $ext -eq '.txt') {
            $lines = @(Get-Content $Path -Encoding UTF8 | Where-Object { $_.Trim() })
            $sep = ';'
            if ($lines.Count -gt 0 -and $lines[0] -match ',') { $sep = ',' }
            $header = $null
            foreach ($ln in $lines) {
                $cols = $ln -split $sep
                if (-not $header -and $cols[0] -match '(?i)name') { $header = @($cols | ForEach-Object { $_.Trim().ToLower() }); continue }
                if (-not $header) {
                    # Headerlos: Name;URL;Model;Key annehmen
                    $entries += @{ Name=$cols[0].Trim(); BaseUrl=$cols[1].Trim(); Model=$(if($cols.Count -gt 2){$cols[2].Trim()}else{''}); ApiKey=$(if($cols.Count -gt 3){$cols[3].Trim()}else{''}) }
                    continue
                }
                $h = @{}
                for ($i=0; $i -lt [math]::Min($cols.Count,$header.Count); $i++) { $h[$header[$i]] = $cols[$i].Trim() }
                $entries += $h
            }
        } else {
            return @{ Ok=$false; Message="Unbekanntes Format: $ext (csv/json erwartet)" }
        }
    } catch { return @{ Ok=$false; Message="Parse-Fehler: $($_.Exception.Message)" } }
    if ($entries.Count -eq 0) { return @{ Ok=$false; Message='Keine Provider-Eintraege gefunden' } }
    $r = Import-SysPilotAiProvidersData -Entries $entries
    return @{ Ok=$true; Message="Import: $($r.Added) neu, $($r.Updated) aktualisiert, $($r.Skipped.Count) uebersprungen"; Result=$r }
}

function Import-SysPilotAiKeyFile {
    <# Liest eine einzelne Key-Textdatei (unser Backup-Format oder
       generisch: enthaelt URL + Key-Muster).
       Parse-Cache: keyed auf Pfad+Laenge+mtime - OneDrive-Dateien
       werden nur bei Aenderung erneut gelesen (sonst Hydration = Freeze).
       Rueckgabe ist IMMER eine frische Hashtable (Aufrufer mutieren sie). #>
    param([Parameter(Mandatory)][string]$Path)
    $fi = Get-Item $Path -ErrorAction SilentlyContinue
    if (-not $fi) { return $null }
    $ck = "$Path|$($fi.Length)|$($fi.LastWriteTimeUtc.Ticks)"
    if ($script:AiKeyFileParseCache.ContainsKey($ck)) {
        $c = $script:AiKeyFileParseCache[$ck]
        if ($null -eq $c) { return $null }
        return @{ Name=$c.Name; BaseUrl=$c.BaseUrl; Model=$c.Model; ApiKey=$c.ApiKey; Kind='cloud'; Enabled=$true }
    }
    $txt = Get-Content $Path -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if (-not $txt) { return $null }
    # Format 1: unser Backup (Name:/Base URL:/API Key:)
    $name = $null; $url = $null; $model = $null; $key = $null
    foreach ($ln in ($txt -split "`r?`n")) {
        if ($ln -match '^\s*Name:\s*(.+)$') { $name = $Matches[1].Trim() }
        elseif ($ln -match '^\s*Base\s*URL:\s*(\S+)') { $url = $Matches[1].Trim() }
        elseif ($ln -match '^\s*Modell:\s*(.+)$') { $model = $Matches[1].Trim() }
        elseif ($ln -match '^\s*API\s*Key:\s*(\S+)') { $key = $Matches[1].Trim() }
    }
    if (-not $name) { $name = [IO.Path]::GetFileNameWithoutExtension($Path) }
    # Format 2: generisch - erste http(s)-URL + Key-Muster
    if (-not $url) {
        $um = [regex]::Match($txt, 'https?://[^\s"''<>\)]+')
        if ($um.Success) { $url = $um.Value.TrimEnd('/') }
    }
    if (-not $key) {
        $km = [regex]::Match($txt, '(sk-[A-Za-z0-9_\-]{8,}|AIza[0-9A-Za-z_\-]{20,}|gsk_[A-Za-z0-9]{10,}|xox[baprs]-[A-Za-z0-9\-]{10,}|Bearer\s+[A-Za-z0-9_\-\.]{10,}|api[_-]?key["''\s:=]+([A-Za-z0-9_\-\.]{8,}))')
        if ($km.Success) { $key = ($km.Groups[1].Value, $km.Value | Where-Object { $_ } | Select-Object -First 1) }
    }
    if (-not $url) {
        $script:AiKeyFileParseCache[$ck] = $null
        if ($script:AiKeyFileParseCache.Count -gt 500) { $script:AiKeyFileParseCache.Clear() }
        return $null
    }
    $res = @{ Name=$name; BaseUrl=$url; Model=$model; ApiKey=$key }
    $script:AiKeyFileParseCache[$ck] = $res
    if ($script:AiKeyFileParseCache.Count -gt 500) { $script:AiKeyFileParseCache.Clear() }
    return @{ Name=$name; BaseUrl=$url; Model=$model; ApiKey=$key; Kind='cloud'; Enabled=$true }
}

function Get-SysPilotAiKeyFileCandidates {
    <# Findet .txt-Dateien mit API-Keys/Base-URLs in ueblichen
       Ablageorten. WICHTIG (OneDrive-Freeze-Fix):
       - 'api key*'-Ordner unter Dokumente werden rekursiv (3 Ebenen) durchsucht
       - Dokumente/Desktop/Downloads nur die DIREKTEN .txt-Dateien (keine
         Rekursion ueber den ganzen OneDrive-Baum - das fror die UI ein)
       - Ergebnis wird 10 Minuten gecacht ($script:AiKeyCandidatesCache).
       Max. 200 Treffer. #>
    param([switch]$NoCache)
    if (-not $NoCache -and $script:AiKeyCandidatesCache -and
        ((Get-Date) - $script:AiKeyCandidatesCacheTime).TotalMinutes -lt 10) {
        return $script:AiKeyCandidatesCache
    }
    $docs = [Environment]::GetFolderPath('MyDocuments')
    $desk = [Environment]::GetFolderPath('Desktop')
    $dl   = [Environment]::GetFolderPath('MyDocuments') + '\Downloads'
    # Rekursive Roots: nur dedizierte Key-Ordner
    $deepRoots = @(
        (Join-Path $docs 'api keys'), (Join-Path $docs 'api key'),
        (Join-Path $docs 'API Keys'), (Join-Path $docs 'API Key')
    ) | Sort-Object -Unique | Where-Object { Test-Path $_ }
    # Flache Roots: nur *.txt direkt im Ordner
    $flatRoots = @($docs, $desk, $dl) | Sort-Object -Unique | Where-Object { Test-Path $_ }
    $found = @()
    # 1) Tiefe Suche in Key-Ordnern
    foreach ($root in $deepRoots) {
        if ($found.Count -ge 200) { break }
        try {
            $files = Get-ChildItem $root -Recurse -Depth 3 -Filter '*.txt' -File -ErrorAction SilentlyContinue |
                     Where-Object { $_.Length -gt 10 -and $_.Length -lt 200KB }
            foreach ($f in $files) {
                if ($found.Count -ge 200) { break }
                $head = Get-Content $f.FullName -TotalCount 15 -Encoding UTF8 -ErrorAction SilentlyContinue
                $hay = ($head -join "`n")
                if ($hay -match '(?i)api[_\s-]?key|base\s*url|sk-[A-Za-z0-9]|AIza|Bearer|openai|anthropic|groq|openrouter|mistral|gemini|ollama|endpoint') {
                    $found += $f.FullName
                }
            }
        } catch {}
    }
    # 2) Flach: nur *.txt direkt im Ordner (kein OneDrive-Recurse)
    foreach ($root in $flatRoots) {
        if ($found.Count -ge 200) { break }
        try {
            $files = Get-ChildItem $root -Filter '*.txt' -File -ErrorAction SilentlyContinue |
                     Where-Object { $_.Length -gt 10 -and $_.Length -lt 200KB }
            foreach ($f in $files) {
                if ($found.Count -ge 200) { break }
                $head = Get-Content $f.FullName -TotalCount 15 -Encoding UTF8 -ErrorAction SilentlyContinue
                $hay = ($head -join "`n")
                if ($hay -match '(?i)api[_\s-]?key|base\s*url|sk-[A-Za-z0-9]|AIza|Bearer|openai|anthropic|groq|openrouter|mistral|gemini|ollama|endpoint') {
                    $found += $f.FullName
                }
            }
        } catch {}
    }
    $found = @($found | Sort-Object -Unique)
    $script:AiKeyCandidatesCache = $found
    $script:AiKeyCandidatesCacheTime = Get-Date
    return $found
}

function Import-SysPilotAiKeyFolder {
    <# Importiert alle erkannten Key-Dateien aus einem Ordner
       (rekursiv, max. 3 Ebenen). Standard: Dokumente\api keys,
       sonst vom User gewaehlter Pfad. #>
    param([string]$Path = '', [switch]$Interactive)
    # Standard: ALLE 'api key*'-Ordner unter Dokumente (deckt
    # 'api key' UND 'api keys' ab - vorher nur 'api keys' = fast leer)
    $dirs = @()
    if ($Path) { $dirs = @($Path) }
    else { $dirs = @((Get-SysPilotAiKeyDirs) | Where-Object { Test-Path $_ }) }
    if ($dirs.Count -eq 0) {
        if ($Interactive) {
            $pick = Show-SysPilotWpfInput -Title 'Ordner mit API-Key-Dateien' -Prompt 'Ordner mit .txt-Key-Dateien (Ordner waehlen oder Pfad eingeben)' -BrowseFolder
            if ($pick) { $dirs = @($pick.Trim()) } else { return @{ Ok=$false; Message='Abgebrochen' } }
        } else { return @{ Ok=$false; Message='Kein api-key-Ordner unter Dokumente gefunden' } }
    }
    $entries = @(); $noKey = @(); $fileCount = 0
    foreach ($dir in $dirs) {
        foreach ($f in @(Get-ChildItem $dir -Recurse -Depth 3 -Filter '*.txt' -File -ErrorAction SilentlyContinue)) {
            $fileCount++
            $e = Import-SysPilotAiKeyFile -Path $f.FullName
            if (-not $e -or -not $e.BaseUrl) { continue }
            # Keine Nicht-Chat-APIs (TTS/Search/Bilder/...) importieren
            if ($e.BaseUrl -match $script:AiNonChatUrlRe) { continue }
            # URL normalisieren (wie im Katalog): Endpoint-Pfad weg,
            # /v1 an Bare-Hosts, verwaiste Punkte entfernen
            $u = $e.BaseUrl.TrimEnd('/') -replace '/chat/completions$','' -replace '/messages$','' -replace '\.+$',''
            if ($u -notmatch '/v\d|/openai|/compatibility|/inference|/paas|/api$|/zen$|/chat$') {
                if ($u -match '^https?://[^/]+$') { $u = "$u/v1" }
            }
            $e.BaseUrl = $u
            # Anzeigename aufraeumen ('xyz api key' -> 'xyz')
            $e.Name = (($e.Name -replace '(?i)\s*api\s*key.*$','' -replace '(?i)\s*project.*$','' -replace '\s+',' ').Trim())
            if (-not $e.Name) { $e.Name = $u }
            if ($e.ApiKey) { $entries += $e }
            else { $entries += $e; $noKey += $f.Name }
        }
    }
    if ($entries.Count -eq 0) { return @{ Ok=$false; Message="Keine verwertbaren Eintraege in $($dirs -join ', ') ($fileCount Dateien geprueft)" } }
    $r = Import-SysPilotAiProvidersData -Entries $entries
    $msg = "Import aus $($dirs -join ' + '): $($r.Added) neu, $($r.Updated) aktualisiert ($fileCount Dateien)"
    if ($noKey.Count -gt 0) { $msg += ", $($noKey.Count) ohne Key (spaeter nachtragen)" }
    return @{ Ok=$true; Message=$msg; Result=$r; WithoutKey=$noKey; Dirs=$dirs }
}

function Find-SysPilotAiRouterConfigs {
    <# Sucht nach OmniRoute/FreeLLMAPI/freelm-Konfigurationsdateien in
       ueblichen Verzeichnissen und extrahiert Provider-artige Eintraege.
       Heuristisch: JSON-Dateien <2MB mit baseUrl/apiKey-Feldern. #>
    $roots = @(
        "$env:APPDATA", "$env:LOCALAPPDATA",
        "$env:USERPROFILE\.omniroute", "$env:USERPROFILE\.freellm",
        "$env:USERPROFILE\.config", "$env:USERPROFILE\.freelmapi",
        "$env:USERPROFILE\.cache\omniroute"
    ) | Where-Object { $_ -and (Test-Path $_) }
    $entries = @(); $files = @()
    foreach ($root in $roots) {
        try {
            $cands = Get-ChildItem $root -Recurse -Depth 3 -Include '*.json','*.yaml','*.yml' -File -ErrorAction SilentlyContinue |
                     Where-Object { $_.Length -lt 2MB -and $_.Name -match '(?i)omni|freellm|freelm|provider|config|setting|route' }
            foreach ($f in ($cands | Select-Object -First 30)) {
                $files += $f.FullName
                try {
                    $raw = Get-Content $f.FullName -Raw -Encoding UTF8 -ErrorAction Stop
                    if ($raw -notmatch '(?i)base_?url|api_?key|endpoint|providers?') { continue }
                    $j = $raw | ConvertFrom-Json -ErrorAction Stop
                    $stack = [Collections.Generic.Stack[object]]::new()
                    $stack.Push($j)
                    $depth = 0
                    while ($stack.Count -gt 0 -and $depth -lt 500) {
                        $depth++
                        $node = $stack.Pop()
                        if ($null -eq $node) { continue }
                        if ($node -is [array]) { foreach ($x in $node) { $stack.Push($x) }; continue }
                        if ($node -isnot [pscustomobject]) { continue }
                        $props = $node.PSObject.Properties.Name
                        $hasUrl = @('baseUrl','base_url','baseURL','url','endpoint','api_base') | Where-Object { $props -contains $_ }
                        $hasKey = @('apiKey','api_key','apiKey','key','token') | Where-Object { $props -contains $_ }
                        if ($hasUrl -and $hasKey) {
                            $e = Get-SysPilotAiProviderEntryFromHashtable -Raw $node
                            if ($e) { $entries += $e }
                        }
                        foreach ($pn in $props) { $v = $node.$pn; if ($v -is [pscustomobject] -or $v -is [array]) { $stack.Push($v) } }
                    }
                } catch {}
            }
        } catch {}
    }
    return @{ Entries=$entries; Files=$files }
}

function Show-SysPilotAiImportExportMenu {
    <# Untermenue: Import/Export von Providern. #>
    $items = @(
        @{ Label='Export: Provider -> CSV-Datei (mit Keys, plaintext!)'; Color='Cyan'; Tag='expcsv' },
        @{ Label='Export: Provider -> JSON-Datei (mit Keys, plaintext!)'; Color='Cyan'; Tag='expjson' },
        @{ Label='Import: CSV/JSON-Datei (eigener Export, OmniRoute, generisch)'; Color='Green'; Tag='impfile' },
        @{ Label='Import: Ordner mit Key-.txt-Dateien (Dokumente\api keys)'; Color='Green'; Tag='impfolder' },
        @{ Label='Import: Key-Dateien automatisch suchen (Dokumente/Desktop/Downloads)'; Color='Green'; Tag='impfind' },
        @{ Label='Import: OmniRoute/FreeLLMAPI-Configs automatisch erkennen'; Color='Yellow'; Tag='improuter' },
        @{ Label='Bereinigen: alle Provider testen, tote deaktivieren'; Color='Yellow'; Tag='clean' },
        @{ Label='Zurueck'; Color='DarkGray'; Tag='back' }
    )
    $sel = Show-SysPilotArrowMenu -Items $items -Title 'KI-Provider Import/Export' -Footer 'Enter = Aktion, Esc = zurueck'
    if ($null -eq $sel -or $sel -eq 'back') { return }
    switch ($sel) {
        'expcsv' {
            $def = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'syspilot-ki-provider.csv'
            $p = Show-SysPilotWpfInput -Title 'CSV-Export' -Prompt 'Speicherpfad (.csv)' -Default $def
            if ($p) { $r = Export-SysPilotAiProvidersFile -Path $p.Trim(); Write-Host "  $($r.Message)" -ForegroundColor $(if($r.Ok){'Green'}else{'Red'}) }
        }
        'expjson' {
            $def = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'syspilot-ki-provider.json'
            $p = Show-SysPilotWpfInput -Title 'JSON-Export' -Prompt 'Speicherpfad (.json)' -Default $def
            if ($p) { $r = Export-SysPilotAiProvidersFile -Path $p.Trim(); Write-Host "  $($r.Message)" -ForegroundColor $(if($r.Ok){'Green'}else{'Red'}) }
        }
        'impfile' {
            $p = Show-SysPilotWpfInput -Title 'Provider-Datei importieren' -Prompt 'Pfad zur .csv/.json-Datei' -Default "$env:USERPROFILE\Documents" -BrowseFile
            if ($p) {
                $r = Import-SysPilotAiProvidersFile -Path $p
                Write-Host "  $($r.Message)" -ForegroundColor $(if($r.Ok){'Green'}else{'Red'})
                if ($r.Ok -and $r.Result.Report) { $r.Result.Report | ForEach-Object { Write-Host $_ -ForegroundColor DarkGray } }
            }
        }
        'impfolder' {
            $r = Import-SysPilotAiKeyFolder -Interactive
            Write-Host "  $($r.Message)" -ForegroundColor $(if($r.Ok){'Green'}else{'Red'})
        }
        'impfind' {
            Write-Host '  Suche Key-Dateien in Dokumente/Desktop/Downloads ...' -ForegroundColor Cyan
            $cands = @(Get-SysPilotAiKeyFileCandidates)
            if ($cands.Count -eq 0) { Write-Host '  Keine Key-Dateien gefunden.' -ForegroundColor DarkYellow; break }
            Write-Host "  $($cands.Count) Kandidaten gefunden:" -ForegroundColor Green
            $cands | Select-Object -First 15 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
            if ($cands.Count -gt 15) { Write-Host "    ... und $($cands.Count-15) weitere" -ForegroundColor DarkGray }
            if (Confirm-SysPilot "$($cands.Count) Key-Dateien importieren?") {
                $entries = @()
                foreach ($f in $cands) { $e = Import-SysPilotAiKeyFile -Path $f; if ($e) { $entries += $e } }
                $r = Import-SysPilotAiProvidersData -Entries $entries
                Write-Host "  Import: $($r.Added) neu, $($r.Updated) aktualisiert, $($r.Skipped.Count) uebersprungen" -ForegroundColor Green
            }
        }
        'improuter' {
            Write-Host '  Suche OmniRoute/FreeLLMAPI-Konfigurationen ...' -ForegroundColor Cyan
            $r = Find-SysPilotAiRouterConfigs
            if ($r.Files.Count -eq 0) { Write-Host '  Keine Router-Configs gefunden (OmniRoute/FreeLLMAPI nicht installiert oder andere Pfade).' -ForegroundColor DarkYellow; break }
            Write-Host "  $($r.Files.Count) Config-Datei(en) gefunden, $($r.Entries.Count) Provider-Eintraege extrahiert." -ForegroundColor Green
            $r.Files | Select-Object -First 8 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
            if ($r.Entries.Count -gt 0 -and (Confirm-SysPilot "$($r.Entries.Count) Provider aus Router-Configs importieren?")) {
                $imp = Import-SysPilotAiProvidersData -Entries $r.Entries
                Write-Host "  Import: $($imp.Added) neu, $($imp.Updated) aktualisiert" -ForegroundColor Green
            }
        }
        'clean' {
            Write-Host '  Teste alle Provider (erreichbar + Modelle + Context) ...' -ForegroundColor Cyan
            $r = Invoke-SysPilotAiProviderCleanup
            $r.Report | ForEach-Object { Write-Host $_ -ForegroundColor DarkGray }
            Write-Host "  Fertig: $($r.Tested) getestet, $($r.Disabled.Count) deaktiviert" -ForegroundColor $(if($r.Disabled.Count){'Yellow'}else{'Green'})
        }
    }
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
}

# ---------- Herbert-gestuetzte KI-Tool-Installation + Modell-Download ----------

function Get-SysPilotAiAppsCatalog {
    <# Katalog lokaler KI-Tools (OpenAI-kompatible Server + Chat-UIs).
       Install: winget-ID wenn vorhanden, sonst GitHub-Release/Download.
       Port = lokaler OpenAI-Endpunkt (fuer Provider-Erkennung). #>
    return @(
        @{ Name='Ollama';            Winget='Ollama.Ollama';            Url='https://ollama.com';            Port='11434'; Desc='Lokaler Modell-Server + CLI (llama.cpp-Basis), OpenAI-kompatibel' }
        @{ Name='LM Studio';         Winget='LMStudio.LMStudio';        Url='https://lmstudio.ai';           Port='1234';  Desc='GUI fuer lokale GGUF-Modelle, OpenAI-Server eingebaut' }
        @{ Name='Jan';               Winget='Jan.Jan';                  Url='https://github.com/janhq/jan';  Port='1337';  Desc='Open-Source Chat-UI + lokaler Server (llama.cpp)' }
        @{ Name='GPT4All';           Winget='NLPCloud.GPT4All';         Url='https://gpt4all.io';             Port='4891';  Desc='Desktop-KI mit eingebautem lokalem Server' }
        @{ Name='KoboldCpp';         Winget='';                         Url='https://github.com/LostRuins/koboldcpp/releases'; Port='5001'; Desc='Einzel-.exe llama.cpp-Server, portabel' }
        @{ Name='Layla Server';      Winget='';                         Url='https://github.com/l3utterfly/Layla-Server/releases'; Port=''; Desc='WebRTC-Bridge: Handy-Layla-App mit lokaler KI verbinden (Win-Exe im Release)' }
        @{ Name='PocketAI';          Winget='';                         Url='https://pocketaihub.com/download'; Port='39457'; Desc='Private Offline-KI (Store/Windows/Desktop); Models werden automatisch in seinen Ordner geladen + registriert' }
        @{ Name='Cherry Studio';     Winget='CherryHQ.CherryStudio';    Url='https://www.cherry-ai.com';      Port='';     Desc='Allround-Chat-UI, viele Provider' }
        @{ Name='Chatbox';           Winget='Chatbox.Chatbox-Community'; Url='https://chatboxai.app';        Port='';     Desc='Einfacher Desktop-Chat-Client' }
        @{ Name='AnythingLLM';       Winget='MintplexLabs.AnythingLLM'; Url='https://anythingllm.com';        Port='';     Desc='Lokale RAG-Dokumenten-KI' }
        @{ Name='LocalAI';           Winget='';                         Url='https://localai.io';             Port='8080'; Desc='OpenAI-kompatibler All-in-one-Server (pip/docker)' }
        @{ Name='text-generation-webui'; Winget='';                     Url='https://github.com/oobabooga/text-generation-webui'; Port='5000'; Desc='Flexibler lokaler Server (git clone + start)' }
        @{ Name='Layla (PapaKoftes)'; Winget='';                        Url='https://github.com/PapaKoftes/Layla'; Port='8000'; Desc='Lokaler persoenlicher AI-Assistent (Python, Web-UI localhost:8000/ui), Approval-Tools + Retrieval-Memory'; Repo='PapaKoftes/Layla'; InstallScript='install\bootstrap.ps1'; UiUrl='http://127.0.0.1:8000/ui' }
        @{ Name='Open WebUI';        Winget='';                         Url='https://github.com/open-webui/open-webui'; Port='3000'; Desc='ChatGPT-artige Web-UI fuer Ollama & OpenAI-APIs'; Repo='open-webui/open-webui'; InstallScript=''; UiUrl='http://localhost:3000' }
    )
}

function Get-SysPilotAiRepoInfo {
    <# GitHub-Repo-Metadaten + Install-Skripte erkennen (fuer den
       gefuehrten Installer). #>
    param([Parameter(Mandatory)][string]$Repo)   # 'Owner/Name'
    $info = @{ Ok=$false; FullName=''; Description=''; Stars=0; InstallScripts=@(); DefaultBranch='master' }
    try {
        $r = Invoke-RestMethod "https://api.github.com/repos/$Repo" -TimeoutSec 15 -Headers @{ 'User-Agent'='SysPilot' } -ErrorAction Stop
        $info.Ok = $true
        $info.FullName = $r.full_name; $info.Description = [string]$r.description
        $info.Stars = [int]$r.stargazers_count; $info.DefaultBranch = [string]$r.default_branch
    } catch { $info.Error = $_.Exception.Message; return $info }
    # Root-Listing nach Install-Skripten durchsuchen
    try {
        $c = Invoke-RestMethod "https://api.github.com/repos/$Repo/contents?ref=$($info.DefaultBranch)" -TimeoutSec 15 -Headers @{ 'User-Agent'='SysPilot' } -ErrorAction Stop
        $names = @($c | ForEach-Object { $_.name })
        $info.InstallScripts = @($names | Where-Object { $_ -match 'install|bootstrap|setup' -and $_ -match '\.(ps1|bat|cmd|sh)$' })
    } catch {}
    return $info
}

function Install-SysPilotGitRepoTool {
    <# Klont ein GitHub-Repo und fuehrt ein erkennbares Install-Skript aus
       (bootstrap.ps1 > install.ps1 > INSTALL.bat > install.sh).
       Installationsziel: %LOCALAPPDATA%\Programs\<Name> (portable Konvention). #>
    param([Parameter(Mandatory)][string]$Repo, [string]$InstallScript = '', [string]$Name = '')
    $git = (Get-Command git -ErrorAction SilentlyContinue).Source
    if (-not $git) { return @{ Ok=$false; Error='git nicht gefunden - bitte Git installieren oder manuell klonen' } }
    if (-not $Name) { $Name = ($Repo -split '/')[-1] }
    $dest = Join-Path $env:LOCALAPPDATA "Programs\$Name"
    if (Test-Path $dest) {
        if (-not (Confirm-SysPilot "Ziel $dest existiert bereits - loeschen und neu klonen?")) {
            return @{ Ok=$false; Error='Ziel existiert, Abbruch durch Benutzer' }
        }
        Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent) | Out-Null
    Write-Host "  Klone $Repo -> $dest ..." -ForegroundColor Cyan
    $r1 = Invoke-SysPilotMonitoredProcess -FilePath $git -ArgList @('clone','--depth','1',"https://github.com/$Repo.git",$dest) -Label "Clone $Repo" -TimeoutSec 900
    if (-not $r1.Ok) { return @{ Ok=$false; Error="git clone fehlgeschlagen: $($r1.Error)" } }
    # Skript waehlen
    $script_ = $InstallScript
    if (-not $script_) {
        $cands = @('install\bootstrap.ps1','install.ps1','INSTALL.bat','install.bat','install\install.ps1','install.sh','install\bootstrap.sh')
        foreach ($c in $cands) { if (Test-Path (Join-Path $dest $c)) { $script_ = $c; break } }
    }
    if (-not $script_) {
        return @{ Ok=$true; Partial=$true; Path=$dest; Message="Geklont nach $dest - kein Install-Skript erkannt, bitte README pruefen" }
    }
    $sp = Join-Path $dest ($script_ -replace '/','\')
    Write-Host "  Fuehre Install-Skript aus: $script_" -ForegroundColor Cyan
    $ext = [IO.Path]::GetExtension($sp).ToLower()
    if ($ext -eq '.ps1') {
        $r2 = Invoke-SysPilotMonitoredProcess -FilePath 'powershell.exe' -ArgList @('-NoProfile','-ExecutionPolicy','Bypass','-Command',"Set-Location -LiteralPath '$dest'; & '$sp'") -Label "Install $Name" -TimeoutSec 3600
    } elseif ($ext -in '.bat','.cmd') {
        $r2 = Invoke-SysPilotMonitoredProcess -FilePath 'cmd.exe' -ArgList @('/c','cd /d "' + $dest + '" && "' + $sp + '"') -Label "Install $Name" -TimeoutSec 3600
    } else {
        $r2 = Invoke-SysPilotMonitoredProcess -FilePath 'bash' -ArgList @('-c',"cd '$dest' && bash '$sp'") -Label "Install $Name" -TimeoutSec 3600
    }
    if ($r2.Ok) { return @{ Ok=$true; Path=$dest; Script=$script_; Message="$Name installiert ($script_)" } }
    return @{ Ok=$false; Path=$dest; Script=$script_; Error="Install-Skript fehlgeschlagen: $($r2.Error)" }
}

function Show-SysPilotAiGuidedInstall {
    <# Herbert-gestuetzer Installer: FRAGT, SCHLAEGT VOR, installiert.
       -Repo: direkt ein Repo ('Owner/Name') - z.B. aus der Browser-Extension
              oder dem syspilot://-Protokoll.
       Ohne -Repo: Auswahl aus dem KI-Katalog / GitHub-Repo / Freitext. #>
    param([string]$Repo = '')

    # Direktmodus: Repo vorgegeben (Protokoll/Extension)
    if ($Repo -match '^[\w.-]+/[\w.-]+$') {
        $info = Get-SysPilotAiRepoInfo -Repo $Repo
        if (-not $info.Ok) { Write-Host "  Repo $Repo nicht gefunden: $($info.Error)" -ForegroundColor Red; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; return }
        Write-Host "`n  GitHub-Repo: $($info.FullName)" -ForegroundColor Cyan
        Write-Host "  $($info.Description)" -ForegroundColor DarkGray
        Write-Host "  $($info.Stars) Stars | Install-Skripte: $(if($info.InstallScripts){$info.InstallScripts -join ', '}else{'keine erkannt'})" -ForegroundColor DarkGray
        if (-not (Confirm-SysPilot "Repo klonen + Install-Skript ausfuehren? (Code von GitHub - bitte Repo kurz pruefen)")) { return }
        $r = Install-SysPilotGitRepoTool -Repo $Repo -InstallScript '' -Name (($Repo -split '/')[-1])
        if ($r.Ok) {
            Write-Host "  [OK] $($r.Message)" -ForegroundColor Green
            # Health-Check: bekannte Ports + OpenAI-Endpunkt
            foreach ($port in 8000,3000,8080,11434) {
                if (Test-SysPilotAiPortReachable -BaseUrl "http://localhost:$port/v1" -TimeoutSec 1) {
                    Write-Host "  Port $port antwortet - Provider kann unter KI-Provider verwaltet werden." -ForegroundColor Green
                }
            }
        } else { Write-Host "  [!] $($r.Error)" -ForegroundColor Red }
        Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
        return
    }

    # Interaktiver Modus
    $items = @(
        @{ Label='Layla (PapaKoftes) - lokaler persoenlicher AI-Assistent, Web-UI :8000'; Color='Green'; Tag='layla' }
        @{ Label='Open WebUI - ChatGPT-artige UI fuer Ollama/OpenAI, :3000'; Color='Cyan'; Tag='openwebui' }
        @{ Label='Anderes GitHub-Repo einfuegen (Owner/Name)'; Color='White'; Tag='repo' }
        @{ Label='Beschreiben was ich brauche (Herbert schlaegt passend vor)'; Color='Yellow'; Tag='describe' }
        @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
    )
    $sel = Show-SysPilotArrowMenu -Items $items -Title 'Herbert-gestuetzte Installation' -Footer 'Enter = waehlen, Esc = zurueck'
    if ($null -eq $sel) { return }

    if ($sel -eq 'repo') {
        $repo = Read-SysPilotInput 'GitHub-Repo (z.B. PapaKoftes/Layla)'
        if ($repo -match '^[\w.-]+/[\w.-]+$') { Show-SysPilotAiGuidedInstall -Repo $repo }
        return
    }
    if ($sel -eq 'describe') {
        $want = Read-SysPilotInput 'Was moechtest du? (z.B. "lokaler chat Assistent", "3D", "coding")'
        if (-not $want) { return }
        # Keyword-Match gegen Katalog
        $hits = @(Get-SysPilotAiAppsCatalog | Where-Object {
            $hay = "$($_.Name) $($_.Desc) $($_.Repo)".ToLower()
            @($want.ToLower() -split '\s+' | Where-Object { $_.Length -gt 2 }) | Where-Object { $hay -match [regex]::Escape($_) }
        } | Select-Object -First 5)
        if ($hits.Count -eq 0) {
            Write-Host "  Keine direkten Treffer - versuche GitHub-Suche im Browser." -ForegroundColor DarkYellow
            Start-Process "https://github.com/search?q=$([uri]::EscapeDataString($want))&type=repositories"
        } else {
            $hitems = foreach ($h in $hits) { @{ Label="$($h.Name) - $($h.Desc)"; Color='Green'; Tag=$h } }
            $hitems += @{ Label='GitHub-Suche oeffnen'; Color='DarkGray'; Tag='gh' }
            $hitems += @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
            $h = Show-SysPilotArrowMenu -Items $hitems -Title "Vorschlaege fuer '$want'" -Footer 'Enter = Details/Install, Esc = zurueck'
            if ($null -eq $h) { return }
            if ($h -eq 'gh') { Start-Process "https://github.com/search?q=$([uri]::EscapeDataString($want))&type=repositories"; return }
            if ($h.Repo) { Show-SysPilotAiGuidedInstall -Repo $h.Repo } else { Install-SysPilotAiApp -App $h | Out-Null; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
        }
        return
    }

    # Katalog-Preset
    $repo = switch ($sel) { 'layla' { 'PapaKoftes/Layla' } 'openwebui' { 'open-webui/open-webui' } default { '' } }
    if ($repo) {
        # Protokoll registrieren, damit Browser-Extension + syspilot://-Links funktionieren
        try { $pr = Register-SysPilotProtocol -Repo $repo; if ($pr.Ok) { Write-Host '  syspilot://-Protokoll registriert (fuer Browser-Extension).' -ForegroundColor DarkGray } } catch {}
        Show-SysPilotAiGuidedInstall -Repo $repo
    }
}

function Get-SysPilotAiAppStatus {
    <# Prueft pro Katalog-App: installiert (winget/list/Port/Datei)? #>
    param($App)
    $st = @{ Installed='-'; Port=''; Note='' }
    # Port-Check
    if ($App.Port) {
        $hit = Test-SysPilotAiPortReachable -BaseUrl "http://localhost:$($App.Port)/v1" -TimeoutSec 1
        $st.Port = $(if($hit){'LAEUFT'}else{'-'})
    }
    # winget-Check
    if ($App.Winget) {
        try {
            $w = winget list --id $App.Winget --exact --accept-source-agreements 2>$null | Out-String
            if ($w -match [regex]::Escape(($App.Winget -split '\.')[-1])) { $st.Installed = 'winget' }
        } catch {}
    }
    return $st
}

function Install-SysPilotAiApp {
    <# Installiert eine Katalog-App: winget wenn ID vorhanden,
       sonst oeffnet die offizielle Seite. Gibt Status zurueck. #>
    param([Parameter(Mandatory)]$App)
    if ($App.Winget) {
        $w = (Get-Command winget -ErrorAction SilentlyContinue).Source
        if ($w) {
            Write-Host "  winget install $($App.Winget) ..." -ForegroundColor Cyan
            $r = Invoke-SysPilotMonitoredProcess -FilePath $w -ArgList @('install','--id',$App.Winget,'--exact','--accept-package-agreements','--accept-source-agreements','--disable-interactivity') -Label "Installiere $($App.Name)" -TimeoutSec 900
            if ($r.Ok) { return @{ Ok=$true; Message="$($App.Name) installiert (winget)" } }
            Write-Host "  winget fehlgeschlagen: $($r.Error) - oeffne Download-Seite" -ForegroundColor DarkYellow
        }
    }
    Start-Process $App.Url
    return @{ Ok=$true; Message="$($App.Name): Download-Seite geoeffnet - bitte Installer ausfuehren" }
}

function Show-SysPilotAiAppsInstall {
    <# Herbert-gestuetzter Installer fuer lokale KI-Tools.
       Zeigt Katalog mit Installations-Status + Port-Status,
       Install per winget oder Download-Seite. #>
    $apps = @(Get-SysPilotAiAppsCatalog)
    $items = foreach ($a in $apps) {
        $st = Get-SysPilotAiAppStatus -App $a
        $mark = $(if($st.Installed -ne '-' -or $st.Port -eq 'LAEUFT'){'[x] '}else{'[ ] '})
        $port = if ($a.Port) { " :$($a.Port)" } else { '' }
        @{ Label="$mark$($a.Name)$port - $($a.Desc)"; Color=$(if($st.Port -eq 'LAEUFT'){'Green'}elseif($st.Installed -ne '-'){'Cyan'}else{'White'}); Tag=$a }
    }
    $items += @{ Label='[Modelle] HuggingFace-Modell suchen + herunterladen'; Color='Yellow'; Tag='models' }
    $items += @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
    $sel = Show-SysPilotArrowMenu -Items $items -Title 'KI-Tools installieren (Herbert-Katalog)' -Footer 'Enter = Install/Details, Esc = zurueck'
    if ($null -eq $sel) { return }
    if ($sel -eq 'models') { Show-SysPilotAiModelFinder; return }
    $r = Install-SysPilotAiApp -App $sel
    Write-Host "  $($r.Message)" -ForegroundColor $(if($r.Ok){'Green'}else{'Red'})
    if ($sel.Port) {
        Write-Host "  Tipp: nach dem Start erscheint '$($sel.Name)' automatisch in den KI-Providern (Port $($sel.Port) wird erkannt)." -ForegroundColor DarkCyan
    }
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
}

function Get-SysPilotHfModelSearch {
    <# Durchsucht HuggingFace nach GGUF-Modellen.
       Gibt Array von @{Id;Downloads;Likes;Tags} zurueck. #>
    param([Parameter(Mandatory)][string]$Query, [int]$Limit = 20)
    $u = 'https://huggingface.co/api/models?search=' + [uri]::EscapeDataString($Query) + "&filter=gguf&sort=downloads&direction=-1&limit=$Limit"
    try {
        $r = Invoke-RestMethod $u -TimeoutSec 20 -ErrorAction Stop
        return @($r | ForEach-Object {
            [pscustomobject]@{ Id=$_.id; Downloads=$_.downloads; Likes=$_.likes; Tags=@($_.tags) }
        })
    } catch { return @() }
}

function Get-SysPilotHfModelFiles {
    <# Listet die .gguf-Dateien eines HF-Repos mit Groesse.
       Gibt @(@{File;SizeMB;Url}) sortiert (groesse). #>
    param([Parameter(Mandatory)][string]$RepoId)
    $u = "https://huggingface.co/api/models/$RepoId`?blobs=true"
    try {
        $r = Invoke-RestMethod $u -TimeoutSec 20 -ErrorAction Stop
        return @($r.siblings | Where-Object { $_.rfilename -match '\.gguf$' } | ForEach-Object {
            $sz = if ($_.size) { [math]::Round($_.size/1MB) } else { 0 }
            [pscustomobject]@{ File=$_.rfilename; SizeMB=$sz; Url="https://huggingface.co/$RepoId/resolve/main/$($_.rfilename)" }
        } | Sort-Object SizeMB)
    } catch { return @() }
}

function Get-SysPilotPocketAiModelDir {
    <# Sucht den PocketAI-Modell-Ordner.
       MS Store (MSIX): %LOCALAPPDATA%\Packages\<PFN>\LocalCache\Roaming\PocketAI\models
       Desktop-EXE:     %APPDATA%\PocketAI\models  #>
    $pkg = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Packages') -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'PocketAI' } | Select-Object -First 1
    if ($pkg) {
        $d = Join-Path $pkg.FullName 'LocalCache\Roaming\PocketAI\models'
        if (Test-Path (Split-Path $d -Parent)) { return $d }
    }
    foreach ($c in @((Join-Path $env:APPDATA 'PocketAI\models'), (Join-Path $env:USERPROFILE '.pocketai\models'))) {
        if (Test-Path $c) { return $c }
    }
    return $null
}

function Register-SysPilotPocketAiModel {
    <# Registriert eine .gguf-Datei in PocketAIs installed-models.json,
       damit die App das Modell anzeigt (gleiches Schema wie die App).
       Bei MSIX-Pfaden schreibt die App virtualisierte %APPDATA%-Pfade -
       wir uebernehmen das Schema 1:1. #>
    param([Parameter(Mandatory)][string]$ModelPath)
    $dir = Split-Path $ModelPath -Parent
    $file = Split-Path $ModelPath -Leaf
    $root = Split-Path $dir -Parent                      # ...\PocketAI
    $jsonPath = Join-Path $root 'installed-models.json'
    $isMsix = $dir -match '\\Packages\\'
    $virtualPath = if ($isMsix) {
        Join-Path $env:APPDATA ("PocketAI\models\$file")  # App-Sicht (wird von ihr redirectet)
    } else { $ModelPath }
    $size = (Get-Item $ModelPath).Length
    $modelId = [IO.Path]::GetFileNameWithoutExtension($file)
    $list = @()
    if (Test-Path $jsonPath) {
        try {
            $rawList = Get-Content $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $list = @($rawList)   # PS5.1-Falle: ConvertFrom-Json liefert Array als EIN Pipeline-Objekt -> erst zuweisen, dann wrappen
            if ($list.Count -eq 1 -and $list[0] -is [array]) { $list = @($list[0]) }
        } catch { $list = @() }
    }
    $list = @($list | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['modelId'] })
    if (@($list | Where-Object { $_.localPath -eq $virtualPath -or $_.modelId -eq $modelId }).Count -gt 0) {
        return @{ Ok=$true; Message='bereits registriert' }
    }
    $entry = [pscustomobject]@{
        modelId        = $modelId
        status         = 'ready'
        downloadedBytes= $size
        localPath      = $virtualPath
        installedAt    = ([datetime]::UtcNow.ToString('o'))
        lastUsedAt     = $null
        errorMessage   = $null
        category       = 'language'
        format         = 'gguf'
    }
    if (Test-Path $jsonPath) { Copy-Item $jsonPath "$jsonPath.bak" -Force }
    $out = @($list) + $entry
    ConvertTo-Json -InputObject $out -Depth 5 | Set-Content $jsonPath -Encoding UTF8
    # Rueckprobe: muss ein JSON-Array mit >=1 Eintrag sein
    try {
        $rawBack = Get-Content $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $back = @($rawBack)
        if ($back.Count -eq 1 -and $back[0] -is [array]) { $back = @($back[0]) }
        if ($back.Count -lt 1) { throw 'leeres Array' }
    } catch {
        if (Test-Path "$jsonPath.bak") { Copy-Item "$jsonPath.bak" $jsonPath -Force }
        return @{ Ok=$false; Message="Registrierung fehlgeschlagen, Backup wiederhergestellt: $($_.Exception.Message)" }
    }
    return @{ Ok=$true; Message="in installed-models.json registriert ($modelId)" }
}

function Get-SysPilotLlamaAppInfo {
    <# Findet HuggingFace LlamaApp (MSIX) + liest settings.json
       (ServerPort, CacheDirectory, ModelFolders). #>
    $pkg = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Packages') -Directory `
           -Filter 'HuggingFaceInc.LlamaApp_*' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $pkg) { return $null }
    $sp = Join-Path $pkg.FullName 'LocalCache\Local\Llama\settings.json'
    $cfg = $null
    if (Test-Path $sp) { try { $cfg = Get-Content $sp -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
    return [pscustomobject]@{
        Installed    = $true
        PackageDir   = $pkg.FullName
        SettingsPath = $sp
        Port         = $(if($cfg -and $cfg.ServerPort){[int]$cfg.ServerPort}else{9931})
        CacheDir     = $(if($cfg -and $cfg.CacheDirectory){[string]$cfg.CacheDirectory}else{''})
        ModelFolders = @($(if($cfg -and $cfg.ModelFolders){$cfg.ModelFolders}else{@()}))
        Config       = $cfg
    }
}

function Get-SysPilotLlamaAppModelDir {
    <# Standard-Ordner fuer per SysPilot geladene GGUFs + stellt sicher,
       dass er in LlamaApps ModelFolders registriert ist. #>
    $dir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'SysPilot\Models\LlamaApp'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $info = Get-SysPilotLlamaAppInfo
    if ($info -and $info.SettingsPath -and (Test-Path $info.SettingsPath)) {
        try {
            $cfg = Get-Content $info.SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $folders = @($(if($cfg.ModelFolders){$cfg.ModelFolders}else{@()}))
            if ($folders -notcontains $dir) {
                $cfg | Add-Member -NotePropertyName ModelFolders -NotePropertyValue (@($folders) + $dir) -Force
                $cfg | ConvertTo-Json -Depth 10 | Set-Content $info.SettingsPath -Encoding UTF8
            }
        } catch {}
    }
    return $dir
}

function Get-SysPilotHardwareModelFit {
    <# Empfiehlt Modell-Groesse + Quant aus RAM/VRAM.
       VRAM wird aus der Registry gelesen (Win32_VideoController.AdapterRAM
       ist bei >4GB Karten auf 4GB gekappt). #>
    $ramGB = 0
    try { $ramGB = [math]::Round((Get-CimInstance Win32_OperatingSystem).TotalVisibleMemorySize / 1MB) } catch {}
    $vramGB = 0
    try {
        $vramGB = (Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}' -ErrorAction SilentlyContinue |
            ForEach-Object { try { (Get-ItemProperty $_.PSPath -Name 'HardwareInformation.qwMemorySize' -ErrorAction Stop).'HardwareInformation.qwMemorySize' } catch {} } |
            Measure-Object -Maximum).Maximum / 1GB
        $vramGB = [math]::Round($vramGB, 1)
    } catch {}
    if ($vramGB -le 0) {
        try { $vramGB = [math]::Round(((Get-CimInstance Win32_VideoController | Measure-Object AdapterRAM -Maximum).Maximum) / 1GB, 1) } catch {}
    }
    # Effektiv: VRAM direkt, sonst ~60% des freien RAM fuer CPU-Offload
    $eff = [math]::Max($vramGB, [math]::Round($ramGB * 0.6))
    $fit = if ($eff -ge 20 -or $ramGB -ge 48)      { @{ Class='large'; Quant='Q4_K_M'; Label='gross (~20-35B)' } }
           elseif ($eff -ge 10 -or $ramGB -ge 24) { @{ Class='mid';   Quant='Q4_K_M'; Label='mittel (~9-15B)' } }
           elseif ($eff -ge 6  -or $ramGB -ge 16) { @{ Class='small'; Quant='Q4_K_M'; Label='klein (~4-9B)' } }
           else                                    { @{ Class='small'; Quant='IQ4_XS'; Label='sehr klein (<=4B)' } }
    $fit['RamGB'] = $ramGB; $fit['VramGB'] = $vramGB; $fit['EffGB'] = $eff
    return [pscustomobject]$fit
}

function Test-SysPilotGgufFile {
    <# Prueft GGUF-Magic-Bytes + Groesse - schnellster Integritaets-Check. #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return @{ Ok=$false; Message='Datei fehlt' } }
    $len = (Get-Item $Path).Length
    if ($len -lt 1MB) { return @{ Ok=$false; Message="zu klein ($([math]::Round($len/1MB,1)) MB)" } }
    try {
        $fs = [IO.File]::OpenRead($Path)
        $b = New-Object byte[] 4
        [void]$fs.Read($b, 0, 4); $fs.Close()
        if ([Text.Encoding]::ASCII.GetString($b) -ne 'GGUF') { return @{ Ok=$false; Message='kein GGUF-Header' } }
    } catch { return @{ Ok=$false; Message="nicht lesbar: $($_.Exception.Message)" } }
    return @{ Ok=$true; Message="OK ($([math]::Round($len/1MB)) MB, GGUF-Header valide)" }
}

function Get-SysPilotModelFiles {
    <# Inventar aller lokal liegenden Modell-Dateien/-Ordner:
       .gguf in den bekannten Tool-Ordnern + HF-Hub-Cache (models--*).
       Rueckgabe: Pfad, GroesseMB, Tool, Art (file|dir). #>
    $out = @()
    $dirs = @(Get-SysPilotAiModelDirs)
    foreach ($d in $dirs) {
        if (-not (Test-Path $d.Dir)) { continue }
        foreach ($f in (Get-ChildItem $d.Dir -Filter '*.gguf' -File -Recurse -ErrorAction SilentlyContinue)) {
            $out += [pscustomobject]@{ Path=$f.FullName; SizeMB=[math]::Round($f.Length/1MB); Tool=$d.Tool; Art='file' }
        }
    }
    # HuggingFace-Hub-Cache: jedes models--org--name = ein Modell
    $hub = Join-Path $env:USERPROFILE '.cache\huggingface\hub'
    if (Test-Path $hub) {
        foreach ($m in (Get-ChildItem $hub -Directory -Filter 'models--*' -ErrorAction SilentlyContinue)) {
            $sz = (Get-ChildItem $m.FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
            $out += [pscustomobject]@{ Path=$m.FullName; SizeMB=[math]::Round($sz/1MB); Tool='HF-Cache'; Art='dir' }
        }
    }
    return @($out | Sort-Object SizeMB -Descending)
}

function Show-SysPilotModelCleanup {
    <# Modell-Cleanup: listet alle lokalen GGUFs/Modell-Ordner mit Groesse,
       Enter = nach Bestaetigung loeschen. Verhindert Speicherplatz-Verschwendung
       durch ungenutzte Downloads. #>
    $models = @(Get-SysPilotModelFiles)
    if ($models.Count -eq 0) {
        Write-Host "`n  Keine lokalen Modelle gefunden." -ForegroundColor DarkGray
        Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; return
    }
    $totalMB = ($models | Measure-Object SizeMB -Sum).Sum
    Write-Host "`n  === MODELL-CLEANUP ($($models.Count) Eintraege, $([math]::Round($totalMB/1024,1)) GB gesamt) ===" -ForegroundColor Cyan
    $items = foreach ($m in $models) {
        $sizeTxt = if ($m.SizeMB -ge 1024) { "{0:N1} GB" -f ($m.SizeMB/1024) } else { "$($m.SizeMB) MB" }
        @{ Label=("{0,-10} {1,-8} {2}  ({3})" -f $sizeTxt, $m.Art, $m.Tool, (Split-Path $m.Path -Leaf)); Color='White'; Tag=$m }
    }
    $items += @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
    while ($true) {
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'Modelle loeschen (Enter = loeschen)' -Footer 'Enter = loeschen, Esc = zurueck'
        if ($null -eq $sel) { return }
        $gb = if ($sel.SizeMB -ge 1024) { "{0:N1} GB" -f ($sel.SizeMB/1024) } else { "$($sel.SizeMB) MB" }
        $kind = if ($sel.Art -eq 'dir') { 'Kompletten Modell-Ordner' } else { 'Datei' }
        if (Confirm-SysPilot "$kind endgueltig loeschen?`n`n$($sel.Path)`n$gb - NICHT wiederherstellbar!") {
            try {
                if ($sel.Art -eq 'dir') { Remove-Item $sel.Path -Recurse -Force -ErrorAction Stop }
                else { Remove-Item $sel.Path -Force -ErrorAction Stop }
                Write-Host "  [OK] Geloescht: $($sel.Path) ($gb)" -ForegroundColor Green
                Write-SysPilotLog "Modell geloescht: $($sel.Path) ($gb)" 'INFO'
            } catch { Write-Host "  [!] Fehler: $($_.Exception.Message)" -ForegroundColor Red }
        }
        # Liste neu aufbauen ( geloeschte Eintraege verschwinden)
        $models = @(Get-SysPilotModelFiles)
        if ($models.Count -eq 0) { Write-Host "`n  Keine Modelle mehr vorhanden." -ForegroundColor Green; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; return }
        $items = foreach ($m in $models) {
            $sizeTxt = if ($m.SizeMB -ge 1024) { "{0:N1} GB" -f ($m.SizeMB/1024) } else { "$($m.SizeMB) MB" }
            @{ Label=("{0,-10} {1,-8} {2}  ({3})" -f $sizeTxt, $m.Art, $m.Tool, (Split-Path $m.Path -Leaf)); Color='White'; Tag=$m }
        }
        $items += @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
    }
}

function Register-SysPilotOllamaModel {
    <# Erstellt aus einer .gguf-Datei ein Ollama-Modell (Modelfile +
       'ollama create'). Gibt @{Ok;Message;Name} zurueck. #>
    param([Parameter(Mandatory)][string]$ModelPath, [string]$Name = '')
    $ollama = (Get-Command ollama -ErrorAction SilentlyContinue).Source
    if (-not $ollama) { return @{ Ok=$false; Message='ollama CLI nicht gefunden'; Name='' } }
    if (-not (Test-Path $ModelPath)) { return @{ Ok=$false; Message="Datei fehlt: $ModelPath"; Name='' } }
    if (-not $Name) { $Name = [IO.Path]::GetFileNameWithoutExtension($ModelPath) -replace '[^\w.-]','-' }
    $mf = Join-Path $env:TEMP ("Modelfile-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    try {
        "FROM `"$ModelPath`"`nPARAMETER temperature 0.7" | Set-Content $mf -Encoding ASCII
        $out = & $ollama create $Name -f $mf 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) { return @{ Ok=$true; Message="ollama create '$Name' erfolgreich`n$out"; Name=$Name } }
        return @{ Ok=$false; Message="ollama create fehlgeschlagen (Exit $LASTEXITCODE): $($out.Trim())"; Name=$Name }
    } finally { Remove-Item $mf -Force -ErrorAction SilentlyContinue }
}

function Test-SysPilotOllamaModel {
    <# Kurzer Smoke-Test: 'ollama run <name> "sag ok"' mit Timeout.
       Laedt das Modell dabei ggf. in den Speicher. #>
    param([Parameter(Mandatory)][string]$Name, [int]$TimeoutSec = 180)
    $ollama = (Get-Command ollama -ErrorAction SilentlyContinue).Source
    if (-not $ollama) { return @{ Ok=$false; Message='ollama nicht gefunden' } }
    $job = Start-Job -ScriptBlock {
        param($o,$n)
        & $o run $n 'Antworte nur mit: ok' 2>&1 | Out-String
    } -ArgumentList $ollama, $Name
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ($job.State -eq 'Running' -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
    if ($job.State -eq 'Running') { Stop-Job $job; $timedOut = $true } else { $timedOut = $false }
    $out = "$(@(Receive-Job $job -ErrorAction SilentlyContinue) -join ' ')"
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    if ($timedOut) { return @{ Ok=$false; Message="Timeout nach ${TimeoutSec}s - Modell evtl. zu gross/zu langsam" } }
    if ($out -match 'ok|OK') { return @{ Ok=$true; Message="Modell antwortet: $($out.Trim().Substring(0,[Math]::Min(120,$out.Trim().Length)))" } }
    return @{ Ok=$false; Message="Unerwartete Antwort: $($out.Trim().Substring(0,[Math]::Min(160,$out.Trim().Length)))" }
}

function Get-SysPilotAiModelDirs {
    <# Kandidaten-Ordner fuer GGUF-Downloads (nur existierende +
       'Eigener Ordner' das bei Bedarf angelegt wird). #>
    $c = @(
        @{ Tool='Ollama';        Dir=(Join-Path $env:USERPROFILE '.ollama\models'); Note='ollama create/Modelfile noetig - oder ollama pull hf.co/...' }
        @{ Tool='LM Studio';     Dir=(Join-Path $env:USERPROFILE '.lmstudio\models'); Note='LM Studio scannt automatisch' }
        @{ Tool='LM Studio alt'; Dir=(Join-Path $env:USERPROFILE '.cache\lm-studio\models'); Note='aelterer Cache-Pfad' }
        @{ Tool='Jan';           Dir=(Join-Path $env:USERPROFILE '.jan\models'); Note='Jan Models-Ordner' }
        @{ Tool='Layla';         Dir=(Join-Path $env:USERPROFILE '.layla\models'); Note='Layla (PapaKoftes) - models/ ; model_filename in agent/runtime_config.json setzen' }
        @{ Tool='Layla (Repo)';  Dir=(Join-Path $env:LOCALAPPDATA 'Programs\Layla\models'); Note='Layla-Installationsordner' }
    )
    $pai = Get-SysPilotPocketAiModelDir
    if ($pai) {
        $c += @{ Tool='PocketAI'; Dir=$pai; Note='PocketAI (Store/Desktop) - wird in installed-models.json registriert' }
    }
    if (Get-SysPilotLlamaAppInfo) {
        $c += @{ Tool='LlamaApp'; Dir=(Get-SysPilotLlamaAppModelDir); Note='HuggingFace LlamaApp - Ordner wird in ModelFolders registriert; App ggf. neu starten' }
    }
    $c += @{ Tool='Eigener Ordner'; Dir=(Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'SysPilot\Models'); Note='wird bei Bedarf angelegt' }
    return @($c | Where-Object { $_.Tool -eq 'Eigener Ordner' -or (Test-Path $_.Dir) })
}

function Save-SysPilotHfModel {
    <# Laedt eine .gguf-Datei von HuggingFace in den Ziel-Ordner.
       Fortschritt via Job + Datei-Groesse (Write-Host-Balken). #>
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$RepoId,
          [Parameter(Mandatory)][string]$FileName, [Parameter(Mandatory)][string]$DestDir,
          [int]$TimeoutMin = 60)
    if (-not (Test-Path $DestDir)) { New-Item -ItemType Directory -Force -Path $DestDir | Out-Null }
    $dest = Join-Path $DestDir $FileName
    # HEAD fuer Groesse
    $total = 0
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Method = 'HEAD'; $req.Timeout = 15000
        $resp = $req.GetResponse(); $total = [int64]$resp.ContentLength; $resp.Close()
    } catch {}
    Write-Host "  Download: $FileName" -ForegroundColor Cyan
    Write-Host "  Ziel: $dest" -ForegroundColor DarkGray
    $job = Start-Job -ScriptBlock {
        param($u,$d)
        try { Invoke-WebRequest $u -OutFile $d -UseBasicParsing -TimeoutSec 3600; 'OK' } catch { "ERR: $($_.Exception.Message)" }
    } -ArgumentList $Url, $dest
    $lastMb = -1
    while ($job.State -eq 'Running') {
        Start-Sleep -Seconds 2
        if (Test-Path $dest) {
            $mb = [math]::Round((Get-Item $dest).Length/1MB)
            if ($mb -ne $lastMb) {
                $lastMb = $mb
                $pct = if ($total -gt 0) { [math]::Min(100,[math]::Round($mb*1MB/$total*100)) } else { -1 }
                $bar = if ($pct -ge 0) { " [$pct%]" } else { '' }
                Write-Host "    $mb MB$bar" -ForegroundColor DarkGray
            }
        }
        if (((Get-Date) - $job.ChildJobs[0].StartTime).TotalMinutes -gt $TimeoutMin) { Stop-Job $job; break }
    }
    $res = Receive-Job $job -ErrorAction SilentlyContinue
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    if ("$res" -eq 'OK' -and (Test-Path $dest)) {
        $mb = [math]::Round((Get-Item $dest).Length/1MB)
        Write-Host "  [OK] Gespeichert: $dest ($mb MB)" -ForegroundColor Green
        return @{ Ok=$true; Path=$dest; SizeMB=$mb }
    }
    Write-Host "  [!] Download fehlgeschlagen: $res" -ForegroundColor Red
    return @{ Ok=$false; Path=''; SizeMB=0 }
}

function Get-SysPilotHfRepoFilesBatch {
    <# Laedt .gguf-Dateilisten fuer mehrere Repos parallel
       (Runspace-Pool - seriell waeren es N x HTTP-Timeout).
       Rueckgabe: @{ '<repoId>' = @(<fileObjs>) } #>
    param([Parameter(Mandatory)][string[]]$RepoIds, [int]$MaxParallel = 6)
    $modPath = $PSCommandPath
    $result = @{}
    $pool = [runspacefactory]::CreateRunspacePool(1, [Math]::Min($MaxParallel, $RepoIds.Count))
    try {
        $pool.Open()
        $handles = @()
        foreach ($rid in $RepoIds) {
            $ps = [powershell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript({
                param($mod, $id)
                Import-Module $mod -Force -ErrorAction SilentlyContinue
                @(Get-SysPilotHfModelFiles -RepoId $id)
            }).AddArgument($modPath).AddArgument($rid)
            $handles += @{ Ps=$ps; Id=$rid; H=$ps.BeginInvoke() }
        }
        foreach ($h in $handles) {
            try { $result[$h.Id] = @($h.Ps.EndInvoke($h.H)) } catch { $result[$h.Id] = @() }
            try { $h.Ps.Dispose() } catch {}
        }
    } finally { try { $pool.Close(); $pool.Dispose() } catch {} }
    return $result
}

function Get-SysPilotGgufSizeClass {
    <# Schaetzt die Modell-Groesse aus Repo-/Dateinamen.
       Gibt 'small'|'mid'|'large'|'xl'|'moe'|'' zurueck. #>
    param([string]$Text)
    if ($Text -match 'moe|a3b|a12b|mixtral|deepseek-v3|qwen3-next') { return 'moe' }
    if ($Text -match '(\d+(?:\.\d+)?)\s*[bB](?![a-z])') {
        $n = [double]$Matches[1]
        if ($n -le 4)  { return 'small' }
        if ($n -le 9)  { return 'small' }
        if ($n -le 15) { return 'mid' }
        if ($n -le 35) { return 'large' }
        return 'xl'
    }
    return ''
}

function Get-SysPilotBrowserMcpContext {
    <# Findet einen browser-faehigen MCP-Server + seine navigate/read-Tools.
       Gibt @{Server; NavTool; ReadTool; Tools} oder $null zurueck. #>
    if (-not (Get-Command Get-SysPilotMcpTools -ErrorAction SilentlyContinue)) { return $null }
    $tools = @(Get-SysPilotMcpTools)
    if ($tools.Count -eq 0) { return $null }
    # Server priorisieren: Name-Match, sonst Server mit navigate+read-Tools
    $byServer = $tools | Group-Object Server
    $candidates = @($byServer | Where-Object { $_.Name -match 'browser|chrome|firefox|neo|playwright|edge' })
    if ($candidates.Count -eq 0) { $candidates = @($byServer) }
    foreach ($g in $candidates) {
        $names = @($g.Group | ForEach-Object { $_.Name })
        # Bevorzugte Reihenfolge: direkte navigate/open-Tools vor
        # tabs/new_tab (die evtl. eine action-Parameter brauchen);
        # read/extract/page_text vor snapshot (reiner Text reicht).
        $nav = @($names | Where-Object { $_ -match '^(navigate|open|goto|visit|browser_navigate)$' } | Select-Object -First 1)
        if (-not $nav) { $nav = @($names | Where-Object { $_ -match 'navigate|open|goto|visit|browser_navigate|new_tab|tabs' } | Select-Object -First 1) }
        $read = @($names | Where-Object { $_ -match '^(read|extract|page_text|get_text|content|grep)$' } | Select-Object -First 1)
        if (-not $read) { $read = @($names | Where-Object { $_ -match 'read|snapshot|content|extract|page_text|get_text|grep' } | Select-Object -First 1) }
        if ($nav.Count -gt 0 -and $read.Count -gt 0) {
            return @{ Server=$g.Name; NavTool=$nav[0]; ReadTool=$read[0]; Tools=$names }
        }
    }
    return $null
}

function Invoke-SysPilotBrowserMcpCall {
    <# Ruft ein Browser-MCP-Tool mit Argument-Raten (url/Url/u). #>
    param([string]$Server, [string]$Tool, [string]$Url = '')
    $argSets = @(
        @{ url=$Url }, @{ Url=$Url }, @{ u=$Url }, @{ uri=$Url },
        @{ target=$Url }, @{ address=$Url }
    )
    foreach ($a in $argSets) {
        $r = Invoke-SysPilotMcpTool -Server $Server -Tool $Tool -Arguments $a -TimeoutSec 60
        if ($r.Ok) { return $r }
    }
    # Manche Server wollen keinen Argument-Satz (z.B. 'tabs new' oeffnet dann navigate)
    $r = Invoke-SysPilotMcpTool -Server $Server -Tool $Tool -Arguments @{} -TimeoutSec 60
    return $r
}

function Invoke-SysPilotBrowserPageTask {
    <# Browser-MCP-gestuetzte Aufgaben: 'recherche' (Suchanfrage),
       'translate'/'summarize' (URL -> Inhalt per eigenem Browser lesen
       -> per SysPilot-KI verarbeiten). #>
    param([Parameter(Mandatory)][ValidateSet('recherche','translate','summarize')][string]$Task)
    $ctx = Get-SysPilotBrowserMcpContext
    if (-not $ctx) {
        Write-Host "`n  Kein browser-faehiger MCP-Server konfiguriert." -ForegroundColor Yellow
        Write-Host '  Loesung: MCP-Menue -> "[+] MCP-Server installieren" oder mcp.json um einen' -ForegroundColor DarkCyan
        Write-Host '  Browser-Server ergaenzen (z.B. BrowserOS neo, chrome-devtools-mcp, playwright-mcp).' -ForegroundColor DarkCyan
        Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
        return @{ Ok=$false; Error='kein Browser-MCP' }
    }
    Write-Host "`n  Browser-MCP: $($ctx.Server) (nav='$($ctx.NavTool)', read='$($ctx.ReadTool)')" -ForegroundColor DarkCyan

    # URL/Query erfragen
    if ($Task -eq 'recherche') {
        $q = Read-SysPilotInput 'Suchanfrage fuer Web-Recherche'
        if (-not $q) { return @{ Ok=$false; Error='abgebrochen' } }
        $url = 'https://lite.duckduckgo.com/lite/?q=' + [uri]::EscapeDataString($q)
    } else {
        $prompt = if ($Task -eq 'translate') { 'Uebersetze den folgenden Seiteninhalt ins Deutsche. Gib nur die Uebersetzung aus:' } else { 'Fasse den folgenden Seiteninhalt praezise zusammen (deutsch, Stichpunkte):' }
        $url = Read-SysPilotInput "URL der Seite zum $(if($Task -eq 'translate'){'Uebersetzen'}else{'Zusammenfassen'})"
        if (-not $url -or $url -notmatch '^https?://') { Write-Host '  Uungueltige URL.' -ForegroundColor Red; return @{ Ok=$false; Error='ungueltige URL' } }
    }

    Write-Host "  Oeffne im eigenen Browser: $url" -ForegroundColor Cyan
    $nav = Invoke-SysPilotBrowserMcpCall -Server $ctx.Server -Tool $ctx.NavTool -Url $url
    if (-not $nav.Ok) {
        Write-Host "  [!] navigate fehlgeschlagen: $($nav.Error)" -ForegroundColor Red
        Write-Host "  Verfuegbare Tools: $($ctx.Tools -join ', ')" -ForegroundColor DarkGray
        Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
        return @{ Ok=$false; Error=$nav.Error }
    }
    Start-Sleep -Seconds 2
    $rd = Invoke-SysPilotMcpTool -Server $ctx.Server -Tool $ctx.ReadTool -Arguments @{} -TimeoutSec 60
    if (-not $rd.Ok) { $rd = Invoke-SysPilotMcpTool -Server $ctx.Server -Tool $ctx.ReadTool -Arguments @{ format='markdown' } -TimeoutSec 60 }
    $content = [string]$rd.Text
    if (-not $content -or $content.Length -lt 50) {
        Write-Host "  [!] Seite konnte nicht gelesen werden ($($rd.Error))" -ForegroundColor Red
        Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
        return @{ Ok=$false; Error='read fehlgeschlagen' }
    }
    # Inhalt kuerzen (Token-Budget)
    $maxChars = if ($Task -eq 'recherche') { 12000 } else { 20000 }
    if ($content.Length -gt $maxChars) { $content = $content.Substring(0, $maxChars) + "`n...[gekuerzt]" }

    if ($Task -eq 'recherche') {
        $sys = 'Du bist ein Recherche-Assistent. Fasse die Suchergebnisse zusammen: wichtigste Quellen, Kernfakten, Links.'
        $pr = "Suchanfrage: $q`n`nTreffer:`n$content"
    } else {
        $sys = $prompt
        $pr = "URL: $url`n`n$content"
    }
    Write-Host "  Analysiere per KI ($($ctx.Server)-Browser)..." -ForegroundColor Cyan
    $ai = Invoke-SysPilotAiChat -Prompt $pr -System $sys -TimeoutSec 180
    if ($ai.Ok) {
        Write-Host "`n  [$($ai.Provider)/$($ai.Model)]`n" -ForegroundColor DarkCyan -NoNewline
        Write-Host $ai.Text
    } else {
        Write-Host "  [!] KI-Analyse fehlgeschlagen: $($ai.Error)" -ForegroundColor Red
        Write-Host '  Roher Seiteninhalt (erste 2000 Zeichen):' -ForegroundColor DarkGray
        Write-Host $content.Substring(0, [Math]::Min(2000, $content.Length))
    }
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
    return @{ Ok=$true }
}

function Show-SysPilotAiModelFinder {
    <# Herbert-gestuetzte Modell-Suche:
       Quellen: HuggingFace (mit Quant-/Groessenfilter), Ollama-Registry,
       direkte .gguf-URL. Ziel: Ollama, LM Studio, PocketAI, Jan, eigener Ordner. #>
    $srcItems = @(
        @{ Label='HuggingFace (groesste GGUF-Auswahl, mit Filtern)'; Color='Cyan'; Tag='hf' }
        @{ Label='Ollama-Registry (ollama pull, automatisch passende Quant)'; Color='Green'; Tag='ollama' }
        @{ Label='Direkte .gguf-URL (beliebige Quelle)'; Color='White'; Tag='url' }
        @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
    )
    $src = Show-SysPilotArrowMenu -Items $srcItems -Title 'Modell-Quelle' -Footer 'Enter = waehlen, Esc = zurueck'
    if ($null -eq $src) { return }

    if ($src -eq 'ollama') { Show-SysPilotOllamaModelPull; return }
    if ($src -eq 'url')    { Show-SysPilotDirectModelDownload; return }

    # ===== HuggingFace mit Filtern =====
    # 1) Suchbegriff - kuratierte Presets (Topical, Quant kommt per Filter)
    $presets = @(
        # Allround / Basis
        'instruct', 'chat', 'assistant',
        # Code & Agentic
        'coder', 'code instruct', 'deepseek coder', 'qwen coder',
        'agent tool use', 'function calling', 'json output',
        # Vision & Multimodal
        'vision', 'vl image', 'ocr document', 'multimodal',
        # Reasoning & Thinking
        'r1 distill reasoning', 'thinking', 'math', 'logic puzzle',
        # Uncensored / Kreativ
        'abliterated', 'heretic', 'dolphin', 'uncensored',
        'roleplay', 'story writing', 'creative writing',
        # Sprachen & Spezial
        'german', 'multilingual', 'euro languages', 'translation',
        # Efficiency / Groesse
        'moe efficient', 'tiny 1b', 'small 3b', 'long context',
        # Embeddings / Retrieval
        'embedding', 'rerank', 'retrieval',
        'eigenen Suchbegriff eingeben'
    )
    $items = foreach ($q in $presets) { @{ Label=$q; Color='Cyan'; Tag=$q } }
    $items += @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
    $q = Show-SysPilotArrowMenu -Items $items -Title 'HF-Suchbegriff (GGUF)' -Footer 'Enter = weiter, Esc = zurueck'
    if ($null -eq $q) { return }
    if ($q -eq 'eigenen Suchbegriff eingeben') { $q = Read-SysPilotInput 'Suchbegriff (z.B. "qwen3 abliterated")'; if (-not $q) { return } }

    # 2) Filter: Quantisierung + Groessenklasse - VOR der Trefferliste,
    #    damit die Auswahl nicht von hunderten Dateien erschlagen wird.
    $qitems = @(
        @{ Label='Q4_K_M  (empfohlen: gute Qualitaet, ~4.8 bpw, mittlere Groesse)'; Color='Green'; Tag='Q4_K_M' }
        @{ Label='Q4_K_S  (kleiner/knapper als Q4_K_M)'; Color='White'; Tag='Q4_K_S' }
        @{ Label='Q5_K_M  (besser, groesser)'; Color='White'; Tag='Q5_K_M' }
        @{ Label='Q6_K    (hohe Qualitaet, deutlich groesser)'; Color='White'; Tag='Q6_K' }
        @{ Label='Q8_0    (fast verlustfrei, sehr gross)'; Color='DarkYellow'; Tag='Q8_0' }
        @{ Label='IQ4_XS / andere kleine Quants'; Color='DarkYellow'; Tag='IQ' }
        @{ Label='Beliebige Quantisierung'; Color='DarkGray'; Tag='any' }
        @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
    )
    $quant = Show-SysPilotArrowMenu -Items $qitems -Title "Quant-Filter fuer '$q'" -Footer 'Enter = waehlen, Esc = zurueck'
    if ($null -eq $quant) { return }
    $sitems = @(
        @{ Label='Automatisch (passend zur Hardware: RAM/VRAM)' ; Color='Green'; Tag='auto' }
        @{ Label='Beliebige Groesse'; Color='DarkGray'; Tag='any' }
        @{ Label='Klein: bis ~8B Parameter (schnell, wenig VRAM)'; Color='Green'; Tag='small' }
        @{ Label='Mittel: ~9-15B (gute Balance)'; Color='Cyan'; Tag='mid' }
        @{ Label='Gross: ~20-35B (stark, viel VRAM noetig)'; Color='Yellow'; Tag='large' }
        @{ Label='XL: 70B+ (High-End-Hardware)'; Color='Red'; Tag='xl' }
        @{ Label='MoE / mixture-of-experts (efficient gross)'; Color='Magenta'; Tag='moe' }
        @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
    )
    $sizeClass = Show-SysPilotArrowMenu -Items $sitems -Title 'Modellgroesse-Filter' -Footer 'Enter = waehlen, Esc = zurueck'
    if ($null -eq $sizeClass) { return }
    # Hardware-Fit: 'auto' loest Groesse+Quant aus RAM/VRAM
    if ($sizeClass -eq 'auto') {
        $fit = Get-SysPilotHardwareModelFit
        $sizeClass = $fit.Class
        Write-Host "  Hardware: $($fit.RamGB) GB RAM, $($fit.VramGB) GB VRAM -> Empfehlung: $($fit.Label), Quant $($fit.Quant)" -ForegroundColor Cyan
        if ($quant -eq 'any') { $quant = $fit.Quant }
    }

    # 3) Suche + paralleles Dateilisten-Fetch der Top-Treffer
    Write-Host "`n  Suche HuggingFace: '$q' (Quant: $quant, Groesse: $sizeClass) ..." -ForegroundColor Cyan
    $models = @(Get-SysPilotHfModelSearch -Query $q -Limit 25)
    if ($models.Count -eq 0) { Write-Host '  Keine GGUF-Modelle gefunden.' -ForegroundColor Red; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; return }

    $top = @($models | Select-Object -First 15)
    Write-Host "  Pruefe Dateilisten von $($top.Count) Top-Treffern (parallel) ..." -ForegroundColor DarkGray
    $fileMap = Get-SysPilotHfRepoFilesBatch -RepoIds @($top | ForEach-Object { $_.Id })

    # Quant-Regex + Groessenfilter anwenden
    $quantRx = switch ($quant) {
        'Q4_K_M' { 'Q4_K_M' } 'Q4_K_S' { 'Q4_K_S' } 'Q5_K_M' { 'Q5_K_M' }
        'Q6_K'   { 'Q6_K' }   'Q8_0'   { 'Q8_0' }   'IQ' { 'IQ\d|Q3|Q2' }
        default  { '.' }
    }
    $candidates = foreach ($m in $top) {
        $files = @($fileMap[$m.Id])
        if ($files.Count -eq 0) { continue }
        $match = @($files | Where-Object { $_.File -match $quantRx })
        if ($quant -ne 'any' -and $match.Count -eq 0) { continue }
        $showFiles = if ($quant -eq 'any') { $files } else { $match }
        $cls = Get-SysPilotGgufSizeClass ($m.Id + ' ' + ($showFiles[0].File))
        if ($sizeClass -ne 'any' -and $cls -ne '' -and $cls -ne $sizeClass) { continue }
        [pscustomobject]@{ Model=$m; Files=$showFiles; Count=$showFiles.Count; Cls=$cls }
    }
    $candidates = @($candidates)
    if ($candidates.Count -eq 0) {
        Write-Host "  Keine Treffer mit Quant '$quant'$(if($sizeClass -ne 'any'){" + Groesse '$sizeClass'"})." -ForegroundColor Yellow
        Write-Host '  Tipp: Quant auf "Beliebige" oder groesseren Filter lockern.' -ForegroundColor DarkCyan
        Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; return
    }

    # 4) Trefferliste (Repo + passende Dateianzahl + Groessenklasse)
    $items = foreach ($c in $candidates) {
        $m = $c.Model
        $clsTag = switch ($c.Cls) { 'small'{'[klein]'} 'mid'{'[mittel]'} 'large'{'[gross]'} 'xl'{'[XL]'} 'moe'{'[MoE]'} default{''} }
        $tg = (@($m.Tags) | Where-Object { $_ -match 'gguf|instruct|chat|uncensored|abliterated|coder|vision' } | Select-Object -First 3) -join ','
        @{ Label=("{0}  [{1} DL]{2}  ({3} Dateien){4}" -f $m.Id, $m.Downloads, $(if($clsTag){" $clsTag"}else{''}), $c.Count, $(if($tg){"  $tg"}else{''})); Color='White'; Tag=$c }
    }
    $items += @{ Label='Neue Suche'; Color='DarkGray'; Tag='research' }
    $items += @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
    $sel = Show-SysPilotArrowMenu -Items $items -Title "HF-Treffer '$q' (Quant $quant)" -Footer 'Enter = Dateien, Esc = zurueck'
    if ($null -eq $sel) { return }
    if ($sel -eq 'research') { Show-SysPilotAiModelFinder; return }

    # 5) Dateiliste (nur gefilterte Quant-Dateien)
    $fitems = foreach ($f in $sel.Files) {
        $rec = if ($f.File -match $quantRx -and $quant -ne 'any') { ' <== Filter' } else { '' }
        @{ Label=("{0}  ({1} MB)$rec" -f $f.File, $f.SizeMB); Color=$(if($rec){'Green'}else{'White'}); Tag=$f }
    }
    $fitems += @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
    $fs = Show-SysPilotArrowMenu -Items $fitems -Title "Dateien - $($sel.Model.Id)" -Footer 'Enter = herunterladen, Esc = zurueck'
    if ($null -eq $fs) { return }

    # 6) Ziel-Ordner + Download (wie bisher)
    $dirs = @(Get-SysPilotAiModelDirs)
    $ditems = foreach ($d in $dirs) { @{ Label="$($d.Tool): $($d.Dir) - $($d.Note)"; Color='White'; Tag=$d } }
    $ditems += @{ Label='Anderer Ordner ...'; Color='DarkGray'; Tag='custom' }
    $ditems += @{ Label='Abbrechen'; Color='DarkGray'; Tag=$null }
    $ds = Show-SysPilotArrowMenu -Items $ditems -Title 'Ziel-Ordner fuer Modell' -Footer 'Enter = waehlen, Esc = abbruch'
    if ($null -eq $ds) { return }
    if ($ds -eq 'custom') { $p = Read-SysPilotInput 'Ziel-Ordner'; if (-not $p) { return }; $ds = @{ Tool='Eigener Ordner'; Dir=$p.Trim(); Note='' } }

    $r = Save-SysPilotHfModel -Url $fs.Url -RepoId $sel.Model.Id -FileName $fs.File -DestDir $ds.Dir
    if ($r.Ok) {
        Write-Host "`n  Modell liegt in: $($r.Path)" -ForegroundColor Green
        # Integritaets-Check (GGUF-Header)
        $gchk = Test-SysPilotGgufFile -Path $r.Path
        Write-Host "  Pruefung: $($gchk.Message)" -ForegroundColor $(if($gchk.Ok){'Green'}else{'Red'})
        if (-not $gchk.Ok) {
            Write-Host '  Datei ist kein valide GGUF - bitte neu laden oder kleineres Modell waehlen.' -ForegroundColor Yellow
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; return
        }
        if ($ds.Tool -eq 'LlamaApp') {
            Get-SysPilotLlamaAppModelDir | Out-Null   # stellt ModelFolders-Registrierung sicher
            Write-Host '  LlamaApp: Ordner ist in ModelFolders registriert - App ggf. neu starten, dann Modell laden.' -ForegroundColor DarkCyan
        }
        if ($ds.Tool -eq 'PocketAI') {
            $reg = Register-SysPilotPocketAiModel -ModelPath $r.Path
            Write-Host "  PocketAI: $($reg.Message)" -ForegroundColor $(if($reg.Ok){'Green'}else{'DarkYellow'})
            Write-Host '  Hinweis: PocketAI ggf. neu starten, damit das Modell erscheint.' -ForegroundColor DarkCyan
        }
        if ($ds.Tool -eq 'Ollama') {
            $oname = ($sel.Model.Id -replace '/','-')
            $oreg = Register-SysPilotOllamaModel -ModelPath $r.Path -Name $oname
            Write-Host "  Ollama: $($oreg.Message)" -ForegroundColor $(if($oreg.Ok){'Green'}else{'DarkYellow'})
            if ($oreg.Ok) {
                Write-Host "  Teste Modell (laedt ggf. in RAM - kann dauern) ..." -ForegroundColor DarkYellow
                $t = Test-SysPilotOllamaModel -Name $oreg.Name -TimeoutSec 180
                Write-Host "  Test: $($t.Message)" -ForegroundColor $(if($t.Ok){'Green'}else{'DarkYellow'})
                if (-not $t.Ok) { Write-Host '  Tipp: Modell zu gross? Ueber Modellsuche ein kleineres Quantum (Q4_K_S/IQ4) waehlen.' -ForegroundColor DarkCyan }
            }
        }
        if ($ds.Tool -eq 'LM Studio' -or $ds.Tool -eq 'LM Studio alt') {
            Write-Host '  LM Studio: scannt den Ordner automatisch - App ggf. neu starten.' -ForegroundColor DarkCyan
        }
        if ($ds.Tool -eq 'Jan') {
            Write-Host '  Jan: Modell erscheint nach App-Neustart in der Modellliste.' -ForegroundColor DarkCyan
        }
        if ($ds.Tool -eq 'Layla' -or $ds.Tool -eq 'Layla (Repo)') {
            Write-Host '  Layla: model_filename in agent/runtime_config.json ggf. anpassen.' -ForegroundColor DarkCyan
        }
        if ($ds.Tool -eq 'Eigener Ordner' -or $ds.Tool -eq 'custom') {
            Write-Host '  Datei liegt bereit - App deiner Wahl darauf verweisen oder oberes Skript nutzen.' -ForegroundColor DarkCyan
        }
    }
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
}

function Show-SysPilotOllamaModelPull {
    <# Ollama-Registry: Modell per 'ollama pull' holen - Ollama waehlt
       selbst die passende Quantisierung fuer die Hardware. #>
    if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
        Write-Host '  Ollama ist nicht installiert (ollama.exe nicht im PATH).' -ForegroundColor Red
        Write-Host '  Installiere zuerst ueber KI-Assistenz -> "KI-Tools installieren" -> Ollama.' -ForegroundColor DarkCyan
        Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; return
    }
    $popular = @(
        # Allround
        'qwen3:8b','qwen3:14b','qwen3:30b-a3b','gemma3:12b','gemma3:27b',
        'llama3.1:8b','llama3.3:70b','phi4-mini','mistral-nemo:12b',
        # Vision / Multimodal
        'qwen2.5vl:7b','llava:7b','gemma3n:e4b',
        # Code / Agentic
        'qwen2.5-coder:7b','qwen2.5-coder:14b','deepseek-coder:6.7b','starcoder2:7b',
        # Reasoning
        'deepseek-r1:8b','deepseek-r1:14b',
        # Uncensored / Kreativ
        'dolphin3:8b','hermes3:8b','dolphin-mistral:7b',
        # Embeddings (fuer Retrieval/Suchfeatures)
        'nomic-embed-text','mxbai-embed-large'
    )
    $items = foreach ($m in $popular) { @{ Label=$m; Color='Cyan'; Tag=$m } }
    $items += @{ Label='Eigenen Modellnamen eingeben ...'; Color='White'; Tag='custom' }
    $items += @{ Label='Installierte Modelle anzeigen (ollama list)'; Color='DarkGray'; Tag='list' }
    $items += @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
    $sel = Show-SysPilotArrowMenu -Items $items -Title 'Ollama-Modell holen (ollama pull)' -Footer 'Enter = pull starten, Esc = zurueck'
    if ($null -eq $sel) { return }
    if ($sel -eq 'list') {
        Write-Host "`n  ollama list:" -ForegroundColor Cyan
        try { ollama list 2>&1 | ForEach-Object { Write-Host "  $_" } } catch { Write-Host "  $($_.Exception.Message)" -ForegroundColor Red }
        Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; return
    }
    $model = $sel
    if ($sel -eq 'custom') { $model = Read-SysPilotInput 'Ollama-Modellname (z.B. qwen3:8b oder hf.co/user/repo:Q4_K_M)'; if (-not $model) { return } }
    $model = $model.Trim()
    Write-Host "`n  ollama pull $model ..." -ForegroundColor Cyan
    $r = Invoke-SysPilotMonitoredProcess -FilePath 'ollama' -ArgList @('pull', $model) -Label "Ollama pull $model" -TimeoutSec 3600
    if ($r.Ok) { Write-Host "  [OK] $model bereit" -ForegroundColor Green }
    else { Write-Host "  [!] Pull fehlgeschlagen/abgebrochen: $($r.Error)" -ForegroundColor Red }
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
}

function Show-SysPilotDirectModelDownload {
    <# Direkter .gguf-Download von beliebiger URL
       (ModelScope, GitHub Releases, eigene Server, ...). #>
    $url = Read-SysPilotInput 'Direkte .gguf-URL (z.B. ModelScope/GitHub/Server)'
    if (-not $url -or $url -notmatch '\.gguf(\?|$)') { Write-Host '  Keine gueltige .gguf-URL.' -ForegroundColor Red; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; return }
    $fn = Read-SysPilotInput 'Dateiname (leer = aus URL)'
    if (-not $fn) { $fn = [uri]::UnescapeDataString(([uri]$url).AbsolutePath.Split('/')[-1]); if (-not $fn -match '\.gguf$') { $fn += '.gguf' } }
    $dirs = @(Get-SysPilotAiModelDirs)
    $ditems = foreach ($d in $dirs) { @{ Label="$($d.Tool): $($d.Dir) - $($d.Note)"; Color='White'; Tag=$d } }
    $ditems += @{ Label='Anderer Ordner ...'; Color='DarkGray'; Tag='custom' }
    $ditems += @{ Label='Abbrechen'; Color='DarkGray'; Tag=$null }
    $ds = Show-SysPilotArrowMenu -Items $ditems -Title 'Ziel-Ordner' -Footer 'Enter = waehlen, Esc = abbruch'
    if ($null -eq $ds) { return }
    if ($ds -eq 'custom') { $p = Read-SysPilotInput 'Ziel-Ordner'; if (-not $p) { return }; $ds = @{ Tool='Eigener Ordner'; Dir=$p.Trim(); Note='' } }
    $r = Save-SysPilotHfModel -Url $url -RepoId 'direct' -FileName $fn -DestDir $ds.Dir
    if ($r.Ok -and $ds.Tool -eq 'PocketAI') {
        $reg = Register-SysPilotPocketAiModel -ModelPath $r.Path
        Write-Host "  PocketAI: $($reg.Message)" -ForegroundColor Green
    }
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
}

# ==================== llama.cpp Server (Vulkan/CUDA/ROCm/SYCL/CPU) ====================

function Get-SysPilotLlamaCppDir {
    <# Installationsverzeichnis fuer llama.cpp-Server-Builds. #>
    $d = Join-Path $env:LOCALAPPDATA 'SysPilot\llama.cpp'
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    return $d
}

function Get-SysPilotLlamaCppGpuHint {
    <# Erfasst Architektur + GPU-Hersteller fuer die Backend-Wahl. #>
    $arch = $(if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' })
    if ($env:PROCESSOR_ARCHITECTURE -match 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -match 'ARM64') { $arch = 'arm64' }
    $gpu = ''
    try {
        $vc = @(Get-CimInstance Win32_VideoController -ErrorAction Stop | Where-Object { $_.Name } | Select-Object -ExpandProperty Name)
        $gpu = ($vc -join ' | ')
    } catch {}
    return @{ Arch=$arch; Gpu=$gpu }
}

function Get-SysPilotLlamaCppBackendSuggestion {
    <# Schlaegt das beste llama.cpp-Backend vor:
       ARM64 -> nur CPU-Build; x64 -> Vulkan (universell, auch iGPU),
       CUDA nur bei dedizierter NVIDIA, SYCL bei Intel, ROCm bei AMD-dGPU. #>
    param([hashtable]$Hint = (Get-SysPilotLlamaCppGpuHint))
    if ($Hint.Arch -eq 'arm64') { return 'cpu-arm64' }
    $g = $Hint.Gpu.ToLower()
    if ($g -match 'nvidia') { return 'cuda' }
    # ROCm nur bei dedizierter AMD-GPU (RX/Radeon Pro/FirePro) -
    # "AMD Radeon(TM) Graphics"/Vega = iGPU, dort funktioniert ROCm nicht -> Vulkan
    if ($g -match 'amd|radeon') {
        if ($g -match 'rx ?\d|radeon pro|firepro|instinct') { return 'rocm' }
        return 'vulkan'
    }
    # SYCL nur bei Intel Arc/dGPU - UHD/Iris iGPU laeuft zuverlaessiger mit Vulkan
    if ($g -match 'intel') {
        if ($g -match 'arc|data center|max') { return 'sycl' }
        return 'vulkan'
    }
    return 'vulkan'   # Universalfallback: laeuft auf AMD/Intel/NVIDIA-GPU + CPU
}

function Get-SysPilotLlamaCppRelease {
    <# Findet den neuesten llama.cpp-Release mit Windows-Assets
       (ueberspringt den 'latest'-Marker-Release ohne Binaries). #>
    try {
        $rels = Invoke-RestMethod 'https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=8' -TimeoutSec 25 -Headers @{ 'User-Agent'='SysPilot' } -ErrorAction Stop
        foreach ($rel in @($rels)) {
            $win = @($rel.assets | Where-Object { $_.name -match 'bin-win-' -and $_.name -match 'x64|arm64' })
            if ($win.Count -gt 3) { return $rel }
        }
    } catch {}
    return $null
}

function Get-SysPilotLlamaCppAssetName {
    <# Waehlt den passenden Asset-Namen fuer Backend+Arch.
       CUDA braucht zusaetzlich das cudart-Archiv (behandelt in
       Install-SysPilotLlamaCpp). #>
    param([Parameter(Mandatory)][string]$Backend, [Parameter(Mandatory)][string]$Tag, [string]$Arch = 'x64')
    $map = @{
        'vulkan'    = "llama-$Tag-bin-win-vulkan-$Arch.zip"
        'cpu'       = "llama-$Tag-bin-win-cpu-$Arch.zip"
        'cuda'      = "llama-$Tag-bin-win-cuda-13.5-$Arch.zip"
        'cuda124'   = "llama-$Tag-bin-win-cuda-12.4-$Arch.zip"
        'rocm'      = "llama-$Tag-bin-win-rocm-10.0-$Arch.zip"
        'sycl'      = "llama-$Tag-bin-win-sycl-$Arch.zip"
        'openvino'  = "llama-$Tag-bin-win-openvino-2026.4.1-$Arch.zip"
        'cpu-arm64' = "llama-$Tag-bin-win-cpu-arm64.zip"
    }
    if ($map.ContainsKey($Backend)) { return $map[$Backend] }
    return ''
}

function Install-SysPilotLlamaCpp {
    <# Laedt den passenden llama.cpp-Windows-Build (Auto-Backend oder
       -Backend Vulkan/CUDA/ROCm/SYCL/OpenVINO/CPU) und entpackt ihn
       nach %LOCALAPPDATA%\SysPilot\llama.cpp\<backend>-<tag>. #>
    param([string]$Backend = '', [string]$Tag = '')
    if (-not $Tag) {
        $rel = Get-SysPilotLlamaCppRelease
        if (-not $rel) { return @{ Ok=$false; Dir=''; Error='Kein llama.cpp-Release mit Windows-Assets gefunden.' } }
        $Tag = $rel.tag_name
    } else {
        try { $rel = Invoke-RestMethod "https://api.github.com/repos/ggml-org/llama.cpp/releases/tags/$Tag" -TimeoutSec 25 -Headers @{ 'User-Agent'='SysPilot' } -ErrorAction Stop }
        catch { return @{ Ok=$false; Dir=''; Error="Release $Tag nicht gefunden." } }
    }
    $hint = Get-SysPilotLlamaCppGpuHint
    if (-not $Backend) { $Backend = Get-SysPilotLlamaCppBackendSuggestion -Hint $hint }
    $arch = $(if ($Backend -eq 'cpu-arm64') { 'arm64' } else { $hint.Arch })
    $asset = Get-SysPilotLlamaCppAssetName -Backend $Backend -Tag $Tag -Arch $arch
    if (-not $asset) { return @{ Ok=$false; Dir=''; Error="Unbekanntes Backend '$Backend'." } }
    $assetObj = @($rel.assets | Where-Object { $_.name -eq $asset } | Select-Object -First 1)
    if (-not $assetObj) { return @{ Ok=$false; Dir=''; Error="Asset '$asset' nicht im Release $Tag vorhanden." } }
    $dest = Join-Path (Get-SysPilotLlamaCppDir) "$Backend-$Tag"
    $exe = Join-Path $dest 'llama-server.exe'
    if (-not (Test-Path $exe)) {
        $tmp = Join-Path $env:TEMP "llamacpp-$Tag-$Backend.zip"
        Write-Host "  Lade $asset ($([math]::Round($assetObj[0].size/1MB)) MB) ..." -ForegroundColor DarkGray
        try {
            Invoke-WebRequest -Uri $assetObj[0].browser_download_url -OutFile $tmp -TimeoutSec 600 -UseBasicParsing -ErrorAction Stop
        } catch { return @{ Ok=$false; Dir=''; Error="Download fehlgeschlagen: $($_.Exception.Message)" } }
        if (Test-Path $dest) { Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
        try { Expand-Archive -Path $tmp -DestinationPath $dest -Force -ErrorAction Stop }
        catch {
            # Fallback: tar (manchmal robuster bei grossen zips)
            & tar -xf $tmp -C $dest 2>$null
        }
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        # llama-server.exe liegt evtl. in einem Unterordner (bin/ o.ae.)
        if (-not (Test-Path $exe)) {
            $found = Get-ChildItem $dest -Recurse -Filter 'llama-server.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { $exe = $found.FullName }
        }
        # CUDA: zusaetzlich cudart-Archiv noetig (DLLs ins selbe Verzeichnis)
        if ($Backend -match '^cuda' -and (Test-Path $exe)) {
            $crtName = "cudart-llama-bin-win-cuda-$(if($Backend -eq 'cuda124'){'12.4'}else{'13.5'})-$arch.zip"
            $crtObj = @($rel.assets | Where-Object { $_.name -eq $crtName } | Select-Object -First 1)
            if ($crtObj) {
                $crtTmp = Join-Path $env:TEMP "llamacpp-cudart-$Tag.zip"
                try {
                    Invoke-WebRequest -Uri $crtObj[0].browser_download_url -OutFile $crtTmp -TimeoutSec 600 -UseBasicParsing -ErrorAction Stop
                    $crtDir = Join-Path $env:TEMP "llamacpp-cudart-$Tag"
                    if (Test-Path $crtDir) { Remove-Item $crtDir -Recurse -Force }
                    New-Item -ItemType Directory -Force -Path $crtDir | Out-Null
                    Expand-Archive -Path $crtTmp -DestinationPath $crtDir -Force -ErrorAction SilentlyContinue
                    Copy-Item (Join-Path $crtDir '*') (Split-Path $exe) -Recurse -Force -ErrorAction SilentlyContinue
                    Remove-Item $crtTmp,$crtDir -Recurse -Force -ErrorAction SilentlyContinue
                } catch { Write-Host "  Hinweis: cudart-Nachladung fehlgeschlagen - CUDA evtl. unvollstaendig." -ForegroundColor DarkYellow }
            }
        }
    }
    if (-not (Test-Path $exe)) { return @{ Ok=$false; Dir=$dest; Error='llama-server.exe nach Entpacken nicht gefunden.' } }
    return @{ Ok=$true; Dir=$dest; Exe=$exe; Backend=$Backend; Tag=$Tag; Error='' }
}

function Get-SysPilotLlamaServerExe {
    <# Sucht ein installiertes llama-server.exe (neueste Variante). #>
    $root = Get-SysPilotLlamaCppDir
    $c = Get-ChildItem $root -Recurse -Filter 'llama-server.exe' -ErrorAction SilentlyContinue |
         Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($c) { return $c.FullName }
    return ''
}

function Get-SysPilotLlamaServerStatus {
    <# Liest PID/Port/Modell aus der Statusdatei + Port-Check. #>
    $sf = Join-Path $env:LOCALAPPDATA 'SysPilot\llamacpp-server.json'
    $st = @{ Running=$false; Pid=0; Port=8390; Model=''; Exe='' }
    if (Test-Path $sf) {
        try {
            $j = Get-Content $sf -Raw | ConvertFrom-Json
            $st.Pid = [int]$j.pid; $st.Port = [int]$j.port; $st.Model = [string]$j.model; $st.Exe = [string]$j.exe
            if ($st.Pid -gt 0 -and (Get-Process -Id $st.Pid -ErrorAction SilentlyContinue)) {
                try { $h = Invoke-RestMethod "http://127.0.0.1:$($st.Port)/health" -TimeoutSec 4 -ErrorAction Stop; if ($h) { $st.Running = $true } } catch {}
            }
        } catch {}
    }
    return $st
}

function Get-SysPilotLlamaGgufCandidates {
    <# Sammelt .gguf-Dateien aus allen bekannten Modell-Ablagen. #>
    $dirs = @()
    try { $dirs += @(Get-SysPilotAiModelDirs | ForEach-Object { $_.Dir }) } catch {}
    $dirs += @(
        (Join-Path $env:APPDATA 'PocketAI\models'),
        (Join-Path $env:USERPROFILE '.ollama\models'),
        ([Environment]::GetFolderPath('MyDocuments') + '\SysPilot\Models')
    )
    $files = @()
    foreach ($d in ($dirs | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique)) {
        $files += Get-ChildItem $d -Recurse -Filter '*.gguf' -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -gt 100MB }
    }
    return @($files | Sort-Object Length -Descending | Select-Object -First 40)
}

function Start-SysPilotLlamaServer {
    <# Startet llama-server.exe mit waehlbarer GGUF auf Port 8390
       (OpenAI-kompatibel -> erscheint als lokaler Provider). #>
    param([string]$ModelPath = '', [int]$Port = 8390, [int]$NgpuLayers = -1, [int]$CtxSize = 8192)
    $exe = Get-SysPilotLlamaServerExe
    if (-not $exe) {
        Write-Host '  Kein llama.cpp-Build installiert - zuerst installieren.' -ForegroundColor Yellow
        $inst = Install-SysPilotLlamaCpp
        if (-not $inst.Ok) { Write-Host "  Installation fehlgeschlagen: $($inst.Error)" -ForegroundColor Red; return $false }
        $exe = $inst.Exe
        Write-Host "  Installiert: $($inst.Backend) ($($inst.Tag))" -ForegroundColor Green
    }
    if (-not $ModelPath) {
        $cands = @(Get-SysPilotLlamaGgufCandidates)
        if ($cands.Count -eq 0) { Write-Host '  Keine .gguf-Dateien in bekannten Modell-Ordnern gefunden.' -ForegroundColor Yellow; return $false }
        $items = foreach ($f in $cands) {
            $gb = [math]::Round($f.Length/1GB, 2)
            @{ Label = "$($f.Name)  ($gb GB)  -  $($f.DirectoryName)"; Color='Cyan'; Tag=$f.FullName }
        }
        $items += @{ Label='Eigener Pfad ...'; Color='White'; Tag='custom' }
        $items += @{ Label='Abbrechen'; Color='DarkGray'; Tag=$null }
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'GGUF-Modell fuer llama.cpp-Server' -Footer 'Enter = waehlen, Esc = abbruch'
        if ($null -eq $sel) { return $false }
        $ModelPath = $sel
        if ($sel -eq 'custom') { $ModelPath = Read-SysPilotInput 'Pfad zur .gguf-Datei'; if (-not $ModelPath -or -not (Test-Path $ModelPath)) { return $false } }
    }
    if (-not (Test-Path $ModelPath)) { Write-Host "  Datei nicht gefunden: $ModelPath" -ForegroundColor Red; return $false }
    # GPU-Layer: -1 = backend-abhaengig (Vulkan/CUDA/ROCm -> 99, CPU -> 0)
    if ($NgpuLayers -lt 0) {
        $exeDir = Split-Path $exe -Parent   # z.B. ...\llama.cpp\vulkan-b12774
        $isGpu = ($exeDir -match 'vulkan|cuda|rocm|sycl|openvino')
        $NgpuLayers = $(if ($isGpu) { 99 } else { 0 })
    }
    $alias = [IO.Path]::GetFileNameWithoutExtension($ModelPath) -replace '[^\w\-\.]','_'
    $args = @('--model', $ModelPath, '--host','127.0.0.1','--port',"$Port", '-c',"$CtxSize", '-ngl',"$NgpuLayers", '--alias',$alias)
    Write-Host "  Starte llama-server: $alias (Port $Port, -ngl $NgpuLayers, ctx $CtxSize)" -ForegroundColor Cyan
    $p = Start-Process -FilePath $exe -ArgumentList $args -WindowStyle Hidden -PassThru
    # Health-Wait (Modell-Laden kann dauern)
    $ok = $false
    for ($i=0; $i -lt 90; $i++) {
        Start-Sleep -Milliseconds 1000
        try { $h = Invoke-RestMethod "http://127.0.0.1:$Port/health" -TimeoutSec 3 -ErrorAction Stop; if ($h) { $ok=$true; break } } catch {}
        if ($p.HasExited) { break }
    }
    if (-not $ok) {
        Write-Host "  Server wurde nicht rechtzeitig bereit (Modell-Laden dauert evtl. laenger)." -ForegroundColor Yellow
    } else {
        Write-Host "  OK - llama.cpp-Server laeuft (PID $($p.Id))" -ForegroundColor Green
    }
    $sf = Join-Path $env:LOCALAPPDATA 'SysPilot\llamacpp-server.json'
    @{ pid=$p.Id; port=$Port; model=$ModelPath; alias=$alias; exe=$exe; started=(Get-Date).ToString('o') } | ConvertTo-Json | Set-Content $sf -Encoding UTF8
    Write-Host "  Provider 'llama.cpp Server (lokal)' erscheint in der Provider-Liste, sobald Port $Port antwortet." -ForegroundColor DarkGray
    return $true
}

function Stop-SysPilotLlamaServer {
    <# Stoppt den per SysPilot gestarteten llama-server. #>
    $st = Get-SysPilotLlamaServerStatus
    if (-not $st.Pid) { Write-Host '  Kein Server-Status vorhanden.' -ForegroundColor DarkGray; return }
    $proc = Get-Process -Id $st.Pid -ErrorAction SilentlyContinue
    if ($proc) {
        Stop-Process -Id $st.Pid -Force -ErrorAction SilentlyContinue
        Write-Host "  llama-server (PID $($st.Pid)) gestoppt." -ForegroundColor Green
    } else { Write-Host '  Prozess laeuft nicht mehr.' -ForegroundColor DarkGray }
    $sf = Join-Path $env:LOCALAPPDATA 'SysPilot\llamacpp-server.json'
    Remove-Item $sf -Force -ErrorAction SilentlyContinue
}

function Show-SysPilotLlamaCppMenu {
    <# llama.cpp-Server-Verwaltung: Backend installieren
       (Auto: Vulkan/CUDA/ROCm/SYCL/CPU je nach Hardware),
       GGUF-Modell waehlen, Server starten/stoppen. #>
    while ($true) {
        $st = Get-SysPilotLlamaServerStatus
        $hint = Get-SysPilotLlamaCppGpuHint
        $sug = Get-SysPilotLlamaCppBackendSuggestion -Hint $hint
        Write-Host "`n  ========================================================" -ForegroundColor Cyan
        Write-Host "           LLAMA.CPP SERVER ( direkter Modell-Host )" -ForegroundColor Cyan
        Write-Host "  ========================================================" -ForegroundColor Cyan
        $stateCol = if ($st.Running) { 'Green' } else { 'DarkGray' }
        $stateTxt = if ($st.Running) { "LAEUFT - Port $($st.Port), Modell: $(Split-Path $st.Model -Leaf)" } else { 'gestoppt' }
        Write-Host "  Status: $stateTxt" -ForegroundColor $stateCol
        Write-Host "  Hardware: $($hint.Arch), GPU: $($hint.Gpu) -> Empfehlung: $sug" -ForegroundColor DarkGray
        $installed = @(Get-ChildItem (Get-SysPilotLlamaCppDir) -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
        Write-Host "  Installiert: $(if($installed){$installed -join ', '}else{'keine Builds'})" -ForegroundColor DarkGray
        $items = @(
            @{ Label='[I] Backend installieren (Auto: ' + $sug + ')'; Color='Green'; Tag='install' },
            @{ Label='[I] Backend selbst waehlen (Vulkan/CUDA/ROCm/SYCL/OpenVINO/CPU/ARM64)'; Color='Cyan'; Tag='installpick' },
            @{ Label='[S] GGUF-Modell waehlen + Server starten'; Color='Green'; Tag='start' },
            @{ Label='[X] Server stoppen'; Color='Yellow'; Tag='stop' },
            @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
        )
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'llama.cpp Server' -Footer 'Enter = Aktion, Esc = zurueck'
        if ($null -eq $sel) { return }
        if ($sel -eq 'install') {
            $r = Install-SysPilotLlamaCpp
            if ($r.Ok) { Write-Host "  Installiert: $($r.Backend) $($r.Tag) -> $($r.Dir)" -ForegroundColor Green }
            else { Write-Host "  Fehler: $($r.Error)" -ForegroundColor Red }
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; continue
        }
        if ($sel -eq 'installpick') {
            $bitems = @(
                @{ Label='Vulkan (universell: AMD/Intel/NVIDIA, auch iGPU) - EMPFOHLEN'; Color='Green'; Tag='vulkan' },
                @{ Label='CUDA 13.5 (NVIDIA dediziert, braucht zusaetzlich cudart)'; Color='Cyan'; Tag='cuda' },
                @{ Label='CUDA 12.4 (aeltere NVIDIA-Treiber)'; Color='Cyan'; Tag='cuda124' },
                @{ Label='ROCm 10.0 (AMD dedizierte GPU)'; Color='Yellow'; Tag='rocm' },
                @{ Label='SYCL (Intel Arc/iGPU)'; Color='Yellow'; Tag='sycl' },
                @{ Label='OpenVINO 2026.4 (Intel CPU/iGPU optimiert)'; Color='Yellow'; Tag='openvino' },
                @{ Label='CPU x64 (immer kompatibel, kein GPU-Offload)'; Color='DarkGray'; Tag='cpu' },
                @{ Label='CPU ARM64 (Windows-on-ARM)'; Color='DarkGray'; Tag='cpu-arm64' },
                @{ Label='Abbrechen'; Color='DarkGray'; Tag=$null }
            )
            $b = Show-SysPilotArrowMenu -Items $bitems -Title 'llama.cpp Backend' -Footer 'Enter = installieren, Esc = abbruch'
            if ($null -eq $b) { continue }
            $r = Install-SysPilotLlamaCpp -Backend $b
            if ($r.Ok) { Write-Host "  Installiert: $($r.Backend) $($r.Tag) -> $($r.Dir)" -ForegroundColor Green }
            else { Write-Host "  Fehler: $($r.Error)" -ForegroundColor Red }
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; continue
        }
        if ($sel -eq 'start') { [void](Start-SysPilotLlamaServer); Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; continue }
        if ($sel -eq 'stop') { Stop-SysPilotLlamaServer; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; continue }
    }
}

function Invoke-SysPilotAiEndpoint {
    <# Ruft einen beliebigen OpenAI-kompatiblen Endpunkt eines Providers auf
       (nicht nur /chat/completions): models, embeddings,
       images/generations, audio/transcriptions u.ae.
       Gibt die Roh-Antwort zurueck; optional -OutFile fuer b64_json-Bilder. #>
    param(
        [Parameter(Mandatory)]$Provider,
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Body = @{},
        [ValidateSet('Get','Post')][string]$Method = 'Post',
        [int]$TimeoutSec = 60,
        [string]$OutFile = ''
    )
    $url = $Provider.BaseUrl.TrimEnd('/') + '/' + $Path.TrimStart('/')
    $headers = @{ 'Content-Type' = 'application/json' }
    if ($Provider.ApiKey) { $headers['Authorization'] = "Bearer $($Provider.ApiKey)" }
    if ($Method -eq 'Get') {
        $r = Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec $TimeoutSec -ErrorAction Stop
    } else {
        $r = Invoke-RestMethod -Uri $url -Method Post -Headers $headers `
             -Body ([Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 10))) `
             -TimeoutSec $TimeoutSec -ErrorAction Stop
    }
    if ($OutFile -and $r.data -and @($r.data).Count -gt 0 -and $r.data[0].b64_json) {
        $dir = Split-Path $OutFile -Parent
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        [IO.File]::WriteAllBytes($OutFile, [Convert]::FromBase64String([string]$r.data[0].b64_json))
    }
    return $r
}

# --- Voice (Sprache Ein/Aus, wie PocketAI/Fireflies) ---
# VoiceMode: 'off' = keine Sprachausgabe; 'speak' = Chat-Antworten werden
# vorgesprochen (TTS); 'chat' = dedizierter Voice-Chat (Aufnahme->STT->
# Chat->TTS). VoiceTts: 'system' = Windows System.Speech (offline, DE),
# 'provider' = /audio/speech des Providers (OpenAI-kompatibel).
function Get-SysPilotAiVoiceMode {
    $cfg = Read-SysPilotAiAssistConfig
    if ($cfg.PSObject.Properties['VoiceMode'] -and $cfg.VoiceMode) { return [string]$cfg.VoiceMode }
    return 'off'
}
function Set-SysPilotAiVoiceMode {
    param([Parameter(Mandatory)][ValidateSet('off','speak','chat')][string]$Mode)
    $cfg = Read-SysPilotAiAssistConfig
    $cfg | Add-Member -NotePropertyName VoiceMode -NotePropertyValue $Mode -Force
    Write-SysPilotAiAssistConfig $cfg
}
function Get-SysPilotAiVoiceTts {
    $cfg = Read-SysPilotAiAssistConfig
    if ($cfg.PSObject.Properties['VoiceTts'] -and $cfg.VoiceTts) { return [string]$cfg.VoiceTts }
    return 'system'
}
function Set-SysPilotAiVoiceTts {
    param([Parameter(Mandatory)][ValidateSet('system','provider')][string]$Engine)
    $cfg = Read-SysPilotAiAssistConfig
    $cfg | Add-Member -NotePropertyName VoiceTts -NotePropertyValue $Engine -Force
    Write-SysPilotAiAssistConfig $cfg
}

function Get-SysPilotAiFfmpeg {
    <# ffmpeg.exe suchen - Common.psm1 hat Get-SysPilotFfmpegPath,
       aber AiAssist laeuft teils ohne Common-Import -> Fallback. #>
    if (Get-Command Get-SysPilotFfmpegPath -ErrorAction SilentlyContinue) {
        $p = Get-SysPilotFfmpegPath
        if ($p) { return $p }
    }
    $cmd = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($c in @("$env:LOCALAPPDATA\Microsoft\WinGet\Links\ffmpeg.exe", "$env:USERPROFILE\scoop\apps\ffmpeg\current\bin\ffmpeg.exe", "C:\ProgramData\chocolatey\bin\ffmpeg.exe")) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    return $null
}

function Get-SysPilotMicDevice {
    <# Erster Audio-Aufnahme-Mikrofon via ffmpeg dshow. Cache in Datei
       (Prozess-uebergreifend, wie ai-probe-cache). #>
    $cache = Join-Path $env:LOCALAPPDATA 'SysPilot\mic-device.txt'
    if (Test-Path $cache) {
        $d = (Get-Content $cache -Raw -ErrorAction SilentlyContinue).Trim()
        if ($d) { return $d }
    }
    $ff = Get-SysPilotAiFfmpeg
    if (-not $ff) { return $null }
    $out = & $ff -hide_banner -list_devices true -f dshow -i dummy 2>&1 | Out-String
    $dev = $null
    foreach ($ln in ($out -split "`n")) {
        if ($ln -match '"([^"]+)"\s*\(audio\)') { $dev = $Matches[1]; break }
    }
    if (-not $dev) {
        foreach ($ln in ($out -split "`n")) {
            if ($ln -match '\(audio\)') { $dev = ($ln -replace '.*"([^"]+)".*','$1'); break }
        }
    }
    if ($dev) { try { $dev | Set-Content $cache -Encoding UTF8 } catch {} }
    return $dev
}

function Save-SysPilotMicRecording {
    <# Nimmt Sprache per ffmpeg/dshow auf. Stoppt per Enter oder nach
       $Seconds. Gibt WAV-Pfad (16kHz mono) oder $null zurueck. #>
    param([int]$Seconds = 60)
    $ff = Get-SysPilotAiFfmpeg
    if (-not $ff) { Write-Host '  ffmpeg fehlt - Voice nicht moeglich.' -ForegroundColor Red; return $null }
    $dev = Get-SysPilotMicDevice
    if (-not $dev) { Write-Host '  Kein Audio-Mikrofon gefunden (ffmpeg dshow).' -ForegroundColor Red; return $null }
    $outDir = Join-Path $env:TEMP 'SysPilot-Voice'
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    $out = Join-Path $outDir ("rec-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.wav')
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $ff
    $psi.Arguments = "-hide_banner -loglevel error -y -f dshow -i audio=`"$dev`" -ac 1 -ar 16000 -t $Seconds `"$out`""
    $psi.RedirectStandardInput = $true; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $proc = [Diagnostics.Process]::Start($psi)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while (-not $proc.HasExited -and (Get-Date) -lt $deadline) {
        if ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            if ($k.Key -eq 'Enter') { break }
        }
        Start-Sleep -Milliseconds 120
    }
    try { $proc.StandardInput.WriteLine('q'); $proc.StandardInput.Flush() } catch {}
    if (-not $proc.WaitForExit(8000)) { try { $proc.Kill() } catch {} }
    if (Test-Path $out) { return $out }
    return $null
}

function Send-SysPilotAiAudioTranscription {
    <# POST /audio/transcriptions (Whisper-kompatibel) via curl -
       multipart ist in Invoke-RestMethod unhandlich. #>
    param([Parameter(Mandatory)]$Provider, [Parameter(Mandatory)][string]$File, [string]$Language = '')
    $curl = "$env:SystemRoot\System32\curl.exe"
    if (-not (Test-Path $curl)) { return @{ Ok=$false; Text=''; Error='curl.exe fehlt' } }
    $model = if ($Provider.Model -match 'whisper|audio|transcri|stt') { $Provider.Model } else { 'whisper-1' }
    $args = @('-s','-X','POST', ($Provider.BaseUrl.TrimEnd('/') + '/audio/transcriptions'),
              '-H', "Authorization: Bearer $($Provider.ApiKey)",
              '-F', "file=@$File", '-F', "model=$model")
    if ($Language) { $args += @('-F', "language=$Language") }
    $resp = & $curl @args 2>$null | Out-String
    try {
        $jr = $resp | ConvertFrom-Json
        if ($jr.text) { return @{ Ok=$true; Text=[string]$jr.text; Error='' } }
        return @{ Ok=$false; Text=''; Error=("keine Transkription: " + $resp.Substring(0,[Math]::Min(160,$resp.Length))) }
    } catch { return @{ Ok=$false; Text=''; Error=("Antwort: " + $resp.Substring(0,[Math]::Min(160,$resp.Length))) } }
}

function Get-SysPilotAiVoiceSttProvider {
    <# Waehlt einen Provider fuer Sprache-zu-Text: bevorzugt Modelle mit
       whisper/audio im Namen, sonst erster Key-Provider. #>
    $providers = @(Get-SysPilotAiUsableProviders)
    if ($providers.Count -eq 0) { return $null }
    $hit = @($providers | Where-Object { $_.Model -match '(?i)whisper|audio|transcri|stt' -or $_.Name -match '(?i)groq|openai' } | Select-Object -First 1)
    if ($hit.Count -gt 0) { return $hit[0] }
    $withKey = @($providers | Where-Object { $_.ApiKey } | Select-Object -First 1)
    return $(if ($withKey.Count -gt 0) { $withKey[0] } else { $providers[0] })
}

function Send-SysPilotAiSpeech {
    <# Text -> Audio via /audio/speech (OpenAI-kompatibel). #>
    param([Parameter(Mandatory)]$Provider, [Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][string]$OutFile, [string]$Voice = 'alloy')
    $model = if ($Provider.Model -match '(?i)tts|speech|audio|voice') { $Provider.Model } else { 'tts-1' }
    $body = @{ model=$model; voice=$Voice; input=$Text } | ConvertTo-Json
    $headers = @{ 'Content-Type'='application/json' }
    if ($Provider.ApiKey) { $headers['Authorization'] = "Bearer $($Provider.ApiKey)" }
    Invoke-WebRequest -Uri ($Provider.BaseUrl.TrimEnd('/') + '/audio/speech') -Method Post `
        -Headers $headers -Body ([Text.Encoding]::UTF8.GetBytes($body)) `
        -OutFile $OutFile -TimeoutSec 90 -UseBasicParsing -ErrorAction Stop
    return (Test-Path $OutFile)
}

function Send-SysPilotSystemSpeech {
    <# Offline-TTS via Windows System.Speech - immer verfuegbar,
       bevorzugt deutsche Stimme. #>
    param([Parameter(Mandatory)][string]$Text)
    try {
        Add-Type -AssemblyName System.Speech -ErrorAction Stop
        $s = New-Object System.Speech.Synthesis.SpeechSynthesizer
        try {
            $de = $s.GetInstalledVoices() | Where-Object { $_.VoiceInfo.Culture.Name -match '^de' } | Select-Object -First 1
            if ($de) { $s.SelectVoice($de.VoiceInfo.Name) }
        } catch {}
        $s.Speak($Text)
        $s.Dispose()
        return $true
    } catch { return $false }
}

function Invoke-SysPilotAiSpeak {
    <# Spricht Text - Engine je nach VoiceTts-Config; bei Provider-Fehler
       Fallback auf System.Speech. Gibt 'system'|'provider'|'-' zurueck. #>
    param([Parameter(Mandatory)][string]$Text, [int]$MaxChars = 1200)
    if ($Text.Length -gt $MaxChars) { $Text = $Text.Substring(0,$MaxChars) }
    $engine = Get-SysPilotAiVoiceTts
    $spoken = $false
    if ($engine -eq 'provider') {
        try {
            $p = Get-SysPilotAiVoiceSttProvider
            if ($p -and $p.ApiKey) {
                $outDir = Join-Path $env:TEMP 'SysPilot-Voice'
                New-Item -ItemType Directory -Force -Path $outDir | Out-Null
                $out = Join-Path $outDir ("tts-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.mp3')
                if (Send-SysPilotAiSpeech -Provider $p -Text $Text -OutFile $out) {
                    Start-Process $out -WindowStyle Hidden
                    $spoken = $true
                }
            }
        } catch {}
    }
    if (-not $spoken) {
        $spoken = Send-SysPilotSystemSpeech -Text $Text
    }
    return $(if ($spoken) { $(if ($engine -eq 'provider') { 'provider' } else { 'system' }) } else { '-' })
}

function Show-SysPilotAiVoiceChat {
    <# Voice-Chat: Aufnahme (Enter = Stopp) -> Whisper-STT -> Herbert-Chat
       -> TTS-Antwort (vorgesprochen). /quit, /clear wie Text-Chat. #>
    $stt = Get-SysPilotAiVoiceSttProvider
    if (-not $stt -or -not $stt.ApiKey) {
        Write-Host '  Voice-Chat braucht einen Provider mit API-Key (fuer /audio/transcriptions).' -ForegroundColor Yellow
        Write-Host '  Tipp: Groq (kostenlos) hat whisper-large-v3 - unter Provider eintragen.' -ForegroundColor DarkGray
        return
    }
    Write-Host "`n  === VOICE CHAT (Pilot Herbert) ===" -ForegroundColor Cyan
    Write-Host "  STT: $($stt.Name) | TTS: $(Get-SysPilotAiVoiceTts) | Sprache: deutsch" -ForegroundColor DarkGray
    Write-Host "  Aufnahme startet bei Enter; Enter stoppt frueh. /quit = Ende`n" -ForegroundColor DarkGray
    $history = @()
    while ($true) {
        Write-Host '  [MIC] Aufnahme laeuft ... (Enter = Stopp, max 60s)' -ForegroundColor Green
        $rec = Save-SysPilotMicRecording -Seconds 60
        if (-not $rec) { continue }
        Write-Host '  Transkribiere ...' -ForegroundColor DarkGray
        $tr = Send-SysPilotAiAudioTranscription -Provider $stt -File $rec -Language 'de'
        if (-not $tr.Ok -or -not $tr.Text.Trim()) {
            Write-Host "  [!] Transkription: $($tr.Error)" -ForegroundColor Red
            continue
        }
        $q = $tr.Text.Trim()
        Write-Host "  Du: $q" -ForegroundColor Cyan
        if ($q -match '^/(quit|exit)') { return }
        if ($q -match '^/clear') { $history = @(); Write-Host '  Verlauf geloescht.' -ForegroundColor DarkGray; continue }
        $r = Invoke-SysPilotAiChat -Prompt $q -History $history -TimeoutSec 120
        if (-not $r.Ok) { Write-Host "  [!] $($r.Error)" -ForegroundColor Red; continue }
        $history += @{ role='user'; content=$q }
        $history += @{ role='assistant'; content=$r.Text }
        if ($history.Count -gt 12) { $history = @($history | Select-Object -Last 10) }
        Write-Host "  Herbert: $($r.Text)" -ForegroundColor Green
        $eng = Invoke-SysPilotAiSpeak -Text $r.Text
        if ($eng -eq '-') { Write-Host '  (TTS nicht veruegbar - Antwort bleibt Text)' -ForegroundColor DarkYellow }
        Write-Host ''
    }
}

function Show-SysPilotAiEndpointsMenu {
    <# Non-Chat-API-Endpunkte (getrennt von /chat/completions, wie bei
       PocketAI & Co.): /models, /embeddings, /images/generations,
       /audio/transcriptions + kostenloses Pollinations-Bild (kein Key). #>
    while ($true) {
        $providers = @(Get-SysPilotAiProviders | Where-Object { $_.Enabled })
        $vm = Get-SysPilotAiVoiceMode
        $tts = Get-SysPilotAiVoiceTts
        $items = @(
            @{ Label="[V] Voice (Modus: $vm, TTS: $tts) - Aufnahme->Chat->Sprachausgabe"; Color='Green'; Tag='voice' },
            @{ Label='[P] Pollinations-Bild generieren (KOSTENLOS, kein Key noetig)'; Color='Green'; Tag='pollimg' },
            @{ Label='[M] Provider-Endpunkte (Modelle/Embeddings/Bilder/Audio)'; Color='Cyan'; Tag='prov' },
            @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
        )
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'KI-Endpunkte (non-chat)' -Footer 'Enter = Aktion, Esc = zurueck'
        if ($null -eq $sel) { return }
        if ($sel -eq 'voice') {
            while ($true) {
                $vm = Get-SysPilotAiVoiceMode; $tts = Get-SysPilotAiVoiceTts
                $vitems = @(
                    @{ Label="Voice-Chat starten (STT+TTS aktiv, Modus: $vm)"; Color='Green'; Tag='vchat' },
                    @{ Label="Sprachausgabe im Text-Chat: $(if($vm -eq 'speak'){'AN'}else{'aus'})"; Color='Cyan'; Tag='speak' },
                    @{ Label="TTS-Engine: $(if($tts -eq 'provider'){'Provider (/audio/speech)'}else{'System (offline, DE)'})"; Color='Cyan'; Tag='ttseng' },
                    @{ Label='Zurueck'; Color='DarkGray'; Tag='back' }
                )
                $v = Show-SysPilotArrowMenu -Items $vitems -Title 'Voice' -Footer 'Enter = Aktion, Esc = zurueck'
                if ($null -eq $v -or $v -eq 'back') { break }
                if ($v -eq 'vchat') { Show-SysPilotAiVoiceChat; continue }
                if ($v -eq 'speak') {
                    Set-SysPilotAiVoiceMode -Mode $(if ($vm -eq 'speak') { 'off' } else { 'speak' })
                    Write-Host "  Sprachausgabe: $(if($vm -eq 'speak'){'AUS'}else{'AN'})" -ForegroundColor Green
                    continue
                }
                if ($v -eq 'ttseng') {
                    Set-SysPilotAiVoiceTts -Engine $(if ($tts -eq 'provider') { 'system' } else { 'provider' })
                    Write-Host "  TTS-Engine: $(if($tts -eq 'provider'){'system (offline)'}else{'provider'})" -ForegroundColor Green
                    continue
                }
            }
            continue
        }
        if ($sel -eq 'pollimg') {
            $prompt = Read-SysPilotInput 'Bild-Prompt'
            if (-not $prompt) { continue }
            $w = Read-SysPilotInput 'Breite (Enter=1024)'; if (-not $w) { $w = '1024' }
            $h = Read-SysPilotInput 'Hoehe (Enter=1024)'; if (-not $h) { $h = '1024' }
            $enc = [uri]::EscapeDataString($prompt)
            $url = "https://image.pollinations.ai/prompt/$enc`?width=$w&height=$h&nologo=true&model=flux"
            $outDir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'SysPilot\Images'
            New-Item -ItemType Directory -Force -Path $outDir | Out-Null
            $out = Join-Path $outDir ("pollinations-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.png')
            try {
                Invoke-WebRequest -Uri $url -OutFile $out -TimeoutSec 120 -UseBasicParsing -ErrorAction Stop
                Write-Host "  Bild gespeichert: $out" -ForegroundColor Green
                try { Start-Process $out } catch {}
            } catch { Write-Host "  Download fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Red }
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            continue
        }
        if ($sel -eq 'prov') {
            if ($providers.Count -eq 0) { Write-Host '  Keine Provider konfiguriert/erreichbar.' -ForegroundColor Yellow; continue }
            $pitems = foreach ($p in $providers) {
                $key = if ($p.ApiKey) { 'Key:Set' } else { 'Key:-' }
                @{ Label = "$($p.Name)  [$key]  $($p.BaseUrl)"; Color='Cyan'; Tag=$p.Name }
            }
            $pitems += @{ Label='Abbrechen'; Color='DarkGray'; Tag=$null }
            $pn = Show-SysPilotArrowMenu -Items $pitems -Title 'Provider waehlen' -Footer 'Enter = Endpunkte, Esc = zurueck'
            if ($null -eq $pn) { continue }
            $p = $providers | Where-Object { $_.Name -eq $pn } | Select-Object -First 1
            if (-not $p) { continue }
            while ($true) {
                $acts = @(
                    @{ Label='[M] GET /models (Modellliste)'; Color='Cyan'; Tag='models' },
                    @{ Label='[E] POST /embeddings (Text -> Vektor)'; Color='Cyan'; Tag='emb' },
                    @{ Label='[B] POST /images/generations (Text -> PNG)'; Color='Cyan'; Tag='img' },
                    @{ Label='[A] POST /audio/transcriptions (Audio -> Text)'; Color='Yellow'; Tag='aud' },
                    @{ Label='[S] POST /audio/speech (Text -> Audio/MP3)'; Color='Yellow'; Tag='tts' },
                    @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
                )
                $a = Show-SysPilotArrowMenu -Items $acts -Title "$($p.Name) - Endpunkte" -Footer 'Enter = Aktion, Esc = zurueck'
                if ($null -eq $a) { break }
                try {
                    if ($a -eq 'models') {
                        $r = Invoke-SysPilotAiEndpoint -Provider $p -Path 'models' -Method Get -TimeoutSec 30
                        $names = @($r.data | ForEach-Object { $_.id } | Where-Object { $_ })
                        Write-Host "  $($names.Count) Modelle:" -ForegroundColor Cyan
                        $names | Select-Object -First 40 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
                    }
                    elseif ($a -eq 'emb') {
                        $txt = Read-SysPilotInput 'Text fuer Embedding'
                        if (-not $txt) { continue }
                        $em = Read-SysPilotInput "Modell (Enter=auto/erster aus /models)"
                        $body = @{ input=$txt; model=$(if($em){$em}else{'text-embedding-3-small'}) }
                        $r = Invoke-SysPilotAiEndpoint -Provider $p -Path 'embeddings' -Body $body -TimeoutSec 60
                        $vec = @($r.data[0].embedding)
                        Write-Host "  Embedding: $($vec.Count) Dimensionen" -ForegroundColor Green
                        $out = Join-Path $env:USERPROFILE ("Documents\SysPilot\embedding-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
                        [pscustomobject]@{ Provider=$p.Name; Model=$body.model; Input=$txt; Dimensions=$vec.Count; Embedding=$vec } | ConvertTo-Json -Depth 6 | Set-Content $out -Encoding UTF8
                        Write-Host "  Gespeichert: $out" -ForegroundColor DarkGray
                    }
                    elseif ($a -eq 'img') {
                        $prompt = Read-SysPilotInput 'Bild-Prompt'
                        if (-not $prompt) { continue }
                        $sz = Read-SysPilotInput 'Groesse (Enter=1024x1024)'; if (-not $sz) { $sz='1024x1024' }
                        $outDir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'SysPilot\Images'
                        New-Item -ItemType Directory -Force -Path $outDir | Out-Null
                        $out = Join-Path $outDir ("$($p.Name -replace '[^\w]','_')-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.png')
                        $body = @{ model='dall-e-3'; prompt=$prompt; size=$sz; response_format='b64_json'; n=1 }
                        $mm = Read-SysPilotInput "Modell (Enter=dall-e-3)"; if ($mm) { $body.model = $mm }
                        $r = Invoke-SysPilotAiEndpoint -Provider $p -Path 'images/generations' -Body $body -OutFile $out -TimeoutSec 180
                        if ($r.data -and $r.data[0].url -and -not (Test-Path $out)) {
                            Invoke-WebRequest -Uri $r.data[0].url -OutFile $out -TimeoutSec 120 -UseBasicParsing
                        }
                        if (Test-Path $out) { Write-Host "  Bild gespeichert: $out" -ForegroundColor Green; try { Start-Process $out } catch {} }
                        else { Write-Host '  Keine Bilddaten in der Antwort (Provider unterstuetzt endpoint evtl. nicht).' -ForegroundColor Yellow }
                    }
                    elseif ($a -eq 'tts') {
                        $txt = Read-SysPilotInput 'Text fuer Sprachausgabe'
                        if (-not $txt) { continue }
                        $voice = Read-SysPilotInput 'Stimme (Enter=alloy, z.B. nova/onyx/shimmer)'; if (-not $voice) { $voice='alloy' }
                        $outDir = Join-Path $env:TEMP 'SysPilot-Voice'
                        New-Item -ItemType Directory -Force -Path $outDir | Out-Null
                        $out = Join-Path $outDir ("tts-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.mp3')
                        if (Send-SysPilotAiSpeech -Provider $p -Text $txt -OutFile $out -Voice $voice) {
                            Write-Host "  Audio gespeichert: $out" -ForegroundColor Green
                            try { Start-Process $out } catch {}
                        } else { Write-Host '  /audio/speech fehlgeschlagen oder nicht unterstuetzt.' -ForegroundColor Yellow }
                    }
                    elseif ($a -eq 'aud') {
                        $file = Read-SysPilotInput 'Pfad zur Audiodatei (.mp3/.wav/.m4a/.ogg/.flac/.webm)'
                        if (-not $file -or -not (Test-Path $file)) { Write-Host '  Datei nicht gefunden.' -ForegroundColor Red; continue }
                        $curl = "$env:SystemRoot\System32\curl.exe"
                        if (-not (Test-Path $curl)) { Write-Host '  curl.exe nicht gefunden - Audio-Transkription nicht moeglich.' -ForegroundColor Red; continue }
                        $lang = Read-SysPilotInput 'Sprache (Enter=auto, z.B. de)'; if (-not $lang) { $lang='' }
                        $out = Join-Path $env:USERPROFILE ("Documents\SysPilot\transcript-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
                        $curlArgs = @('-s','-X','POST', ($p.BaseUrl.TrimEnd('/') + '/audio/transcriptions'), '-H', 'Authorization: Bearer ' + $p.ApiKey, '-F', "file=@$file")
                        if ($p.Model) { $curlArgs += @('-F', "model=$($p.Model)") } else { $curlArgs += @('-F','model=whisper-1') }
                        if ($lang) { $curlArgs += @('-F', "language=$lang") }
                        $resp = & $curl @curlArgs 2>$null | Out-String
                        try {
                            $jr = $resp | ConvertFrom-Json
                            if ($jr.text) { [IO.File]::WriteAllText($out, [string]$jr.text, [Text.Encoding]::UTF8); Write-Host "  Transkript: $out" -ForegroundColor Green; Write-Host "  $($jr.text.Substring(0,[Math]::Min(300,$jr.text.Length)))" -ForegroundColor DarkGray }
                            else { Write-Host "  Unerwartete Antwort: $($resp.Substring(0,[Math]::Min(200,$resp.Length)))" -ForegroundColor Yellow }
                        } catch { Write-Host "  Fehler: $($resp.Substring(0,[Math]::Min(200,$resp.Length)))" -ForegroundColor Red }
                    }
                } catch { Write-Host "  Endpunkt-Fehler: $($_.Exception.Message)" -ForegroundColor Red }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
        }
    }
}

# ==================== Kaggle (Gratis-GPU, Models-API, CLI-Kernels) ====================

function Get-SysPilotKaggleStatus {
    <# Diagnose: CLI vorhanden, Auth-Methode, API-Erreichbarkeit. #>
    $st = @{ Cli=$false; CliVersion=''; Auth=''; User=''; ApiOk=$false; Error='' }
    try {
        $v = (& kaggle --version 2>&1 | Out-String).Trim()
        if ($v -match 'Kaggle CLI ([\d\.]+)') { $st.CliVersion = $Matches[1]; $st.Cli = $true }
    } catch {}
    if (-not $st.Cli) {
        # pip-Paket direkt pruefen
        try { $pv = (python -c "import kaggle; print(kaggle.__version__)" 2>&1 | Out-String).Trim(); if ($pv) { $st.Cli=$true; $st.CliVersion="py:$pv" } } catch {}
    }
    if ($st.Cli) {
        try {
            $cv = (& kaggle config view 2>&1 | Out-String)
            if ($cv -match 'username:\s*(\S+)') { $st.User = $Matches[1] }
            if ($cv -match 'auth_method:\s*(\S+)') { $st.Auth = $Matches[1] }
        } catch { $st.Error = $_.Exception.Message }
        try {
            $probe = (& kaggle datasets list -s "titanic" --page-size 1 2>&1 | Out-String)
            if ($probe -match 'titanic|ref') { $st.ApiOk = $true }
        } catch { $st.Error = $_.Exception.Message }
    }
    return [pscustomobject]$st
}

function Invoke-SysPilotKaggleKernelPush {
    <# Baut ein Kernel-Verzeichnis (kernel-metadata.json + kernel.py)
       und startet es via 'kaggle kernels push' - umgeht die fehleranfaellige
       Web-Session-Oberflaeche. Gibt @{Ok;Ref;Dir} zurueck. #>
    param(
        [Parameter(Mandatory)][string]$Title,
        [string]$Slug = '',
        [string]$Code = '',
        [switch]$Gpu,
        [switch]$Tpu,
        [switch]$Internet = $true
    )
    if (-not (Get-Command Invoke-SysPilotMonitoredProcess -ErrorAction SilentlyContinue)) {
        $cm = Join-Path $PSScriptRoot 'Common.psm1'
        if (Test-Path $cm) { try { Import-Module $cm -Force -ErrorAction Stop } catch {} }
    }
    $st = Get-SysPilotKaggleStatus
    if (-not $st.Cli) { return @{ Ok=$false; Ref=''; Dir=''; Error='kaggle CLI nicht gefunden (pip install kaggle).' } }
    if (-not $Slug) { $Slug = ($Title.ToLower() -replace '[^a-z0-9]+','-').Trim('-') }
    if (-not $Slug) { $Slug = 'syspilot-kernel' }
    $user = if ($st.User) { $st.User } else { 'ich' }
    $dir = Join-Path $env:TEMP "syspilot-kaggle-$Slug"
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    if (-not $Code) {
        $Code = @"
import sys, subprocess, os
print('Python:', sys.version)
try:
    import torch
    print('torch:', torch.__version__, '| cuda:', torch.cuda.is_available())
    if torch.cuda.is_available():
        print('GPU:', torch.cuda.get_device_name(0))
except Exception as e:
    print('torch fehlgeschlagen:', e)
os.system('nvidia-smi 2>/dev/null | head -20 || echo "kein nvidia-smi"')
print('RAM-frei-Hinweis: Kaggle gibt ~30h GPU/Woche')
"@
    }
    $utf8nb = New-Object Text.UTF8Encoding($false)   # ohne BOM - kaggle parser lehnt BOM ab
    [IO.File]::WriteAllText((Join-Path $dir 'kernel.py'), $Code, $utf8nb)
    $meta = [ordered]@{
        id = "$user/$Slug"; title = $Title; code_file = 'kernel.py'
        language = 'python'; kernel_type = 'script'; is_private = $true
        enable_gpu = [bool]$Gpu; enable_tpu = [bool]$Tpu; enable_internet = [bool]$Internet
        dataset_sources = @(); competition_sources = @(); kernel_sources = @()
        category_ids = @()
    }
    [IO.File]::WriteAllText((Join-Path $dir 'kernel-metadata.json'), ($meta | ConvertTo-Json -Depth 5), $utf8nb)
    Write-Host "  kaggle kernels push ($user/$Slug, GPU=$Gpu TPU=$Tpu) ..." -ForegroundColor Cyan
    $r = Invoke-SysPilotMonitoredProcess -FilePath 'kaggle' -ArgList @('kernels','push','-p',$dir) -Label "Kaggle push $Slug" -TimeoutSec 300
    if ($r.Ok -or "$($r.Output)" -match 'success|https://www\.kaggle\.com/code') {
        $ref = "$user/$Slug"
        return @{ Ok=$true; Ref=$ref; Dir=$dir; Error='' }
    }
    return @{ Ok=$false; Ref=''; Dir=$dir; Error=($r.Error + ' ' + ($r.Output | Out-String)).Trim() }
}

function Show-SysPilotKaggleMenu {
    <# Kaggle-Setup-Helfer: Status, "Notebook failed"-Tipps,
       Kernel per CLI pushen (umgeht Web-Session-Probleme). #>
    while ($true) {
        $st = Get-SysPilotKaggleStatus
        Write-Host "`n  ========================================================" -ForegroundColor Cyan
        Write-Host "           KAGGLE ( Gratis-GPU + Models-API )" -ForegroundColor Cyan
        Write-Host "  ========================================================" -ForegroundColor Cyan
        Write-Host "  CLI: $(if($st.Cli){"$($st.CliVersion)"}else{'FEHLT'})   Auth: $(if($st.Auth){"$($st.Auth) ($(if($st.User){$st.User}else{'?'}))"}else{'-'})   API: $(if($st.ApiOk){'OK'}else{'?'})" -ForegroundColor $(if($st.Cli -and $st.ApiOk){'Green'}else{'Yellow'})
        Write-Host "  Kaggle bietet: ~30h/Woche Gratis-GPU, T4/P100, TPU-VM - eigene Modelle hosten" -ForegroundColor DarkGray
        $items = @(
            @{ Label='[K] Kernel per CLI starten (GPU-Check oder eigener Code)'; Color='Green'; Tag='push' },
            @{ Label='[S] Status / API-Token einrichten'; Color='Cyan'; Tag='status' },
            @{ Label='[!] Notebook failed? - Loesungstipps'; Color='Yellow'; Tag='fix' },
            @{ Label='[T] TPU-Server (heretic-claude / kaggle-tpu-lab)'; Color='Green'; Tag='tpu' },
            @{ Label='[W] kaggle.com/settings (API-Token, Telefon-Verifizierung)'; Color='Cyan'; Tag='web' },
            @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
        )
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'Kaggle' -Footer 'Enter = Aktion, Esc = zurueck'
        if ($null -eq $sel) { return }
        if ($sel -eq 'push') {
            $what = Read-SysPilotInput 'Kernel-Titel (z.B. "GPU-Check")'
            if (-not $what) { continue }
            $code = Read-SysPilotInput 'Python-Code (leer = GPU-/Umgebungs-Check)' -Multiline:$false
            $gpu = Read-SysPilotYesNo 'Mit GPU? (T4/P100 - Telefon-Verifizierung noetig)'
            $r = Invoke-SysPilotKaggleKernelPush -Title $what -Code $code -Gpu:$gpu
            if ($r.Ok) {
                Write-Host "  Gestartet: https://www.kaggle.com/code/$($r.Ref)" -ForegroundColor Green
                Write-Host "  Status pruefen: kaggle kernels status $($r.Ref)" -ForegroundColor DarkGray
            } else { Write-Host "  Fehler: $($r.Error)" -ForegroundColor Red }
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; continue
        }
        if ($sel -eq 'status') {
            Write-Host "`n  kaggle config view:" -ForegroundColor Cyan
            try { & kaggle config view 2>&1 | ForEach-Object { Write-Host "    $_" } } catch { Write-Host "    $($_.Exception.Message)" -ForegroundColor Red }
            Write-Host "`n  API-Token (kaggle.json) liegt in $env:USERPROFILE\.kaggle\" -ForegroundColor DarkGray
            Write-Host "  Aktuell: auth_method=ACCESS_TOKEN (OAuth) - funktioniert ohne kaggle.json" -ForegroundColor DarkGray
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; continue
        }
        if ($sel -eq 'fix') {
            Write-Host "`n  HAEUFIGE URSACHEN fuer 'Notebook failed':" -ForegroundColor Yellow
            Write-Host "   1) Telefon-Verifizierung fehlt -> kaggle.com/settings (noetig fuer GPU+Sessions)" -ForegroundColor DarkGray
            Write-Host "   2) GPU-Kontingent erschopft -> CPU-Session waehlen oder T4 statt P100" -ForegroundColor DarkGray
            Write-Host "   3) VPN/Proxy blockiert Kaggle-Sessions -> deaktivieren, erneut versuchen" -ForegroundColor DarkGray
            Write-Host "   4) Browser-Erweiterungen (Adblock) stoeren -> Inkognito-Fenster testen" -ForegroundColor DarkGray
            Write-Host "   5) Kaggle-Status prüfen: https://status.kaggle.com" -ForegroundColor DarkGray
            Write-Host "   6) WORKAROUND: Kernel per CLI pushen (Menuepunkt [K]) - umgeht die Web-Session komplett" -ForegroundColor Green
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; continue
        }
        if ($sel -eq 'tpu') { Show-SysPilotKaggleTpuMenu; continue }
        if ($sel -eq 'web') {
            Start-Process 'https://www.kaggle.com/settings'
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; continue
        }
    }
}

# ==================== Kaggle TPU (heretic-claude Integration) ====================

function Get-SysPilotKaggleTpuInfo {
    <# Findet die heretic-claude-Installation (ARahim3/kaggle-tpu-lab +
       proxy.py/watchdog.ps1), Pruefstatus von Proxy (18787) und
       state.json. Key wird maskiert. #>
    $cands = @(
        (Join-Path $env:USERPROFILE 'heretic-claude'),
        (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'heretic-claude'),
        'C:\heretic-claude',
        # Mitgelieferte Kopie im SysPilot-Install (jedem User dasselbe Paket)
        (Join-Path (Split-Path $PSScriptRoot -Parent) 'kaggle-tpu')
    )
    # Vom User gespeicherter Pfad (Kaggle-Menue -> Ordner waehlen)
    try {
        $ac = Read-SysPilotAiAssistConfig
        if ($ac.KaggleTpuDir) { $cands = @($ac.KaggleTpuDir) + $cands }
    } catch {}
    $dir = $null
    foreach ($c in $cands) { if (Test-Path (Join-Path $c 'proxy.py')) { $dir = $c; break } }
    $info = [pscustomobject]@{
        Dir=''; ProxyPy=$false; Watchdog=$false; Stop=$false; UseTpu=$false
        ProxyPort=18787; ProxyUp=$false; Upstream=''; Model=''; StateFile=''; StateAge=$null
    }
    if (-not $dir) { return $info }
    $info.Dir = $dir
    $info.ProxyPy   = Test-Path (Join-Path $dir 'proxy.py')
    $info.Watchdog  = Test-Path (Join-Path $dir 'watchdog.ps1')
    $info.Stop      = Test-Path (Join-Path $dir 'stop-tpu.ps1')
    $info.UseTpu    = Test-Path (Join-Path $dir 'use-tpu.ps1')
    $stateDir = Join-Path $env:LOCALAPPDATA 'heretic-claude'
    $info.StateFile = Join-Path $stateDir 'state.json'
    if (Test-Path $info.StateFile) {
        try {
            $j = Get-Content $info.StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $info.Upstream = [string]$j.url; $info.Model = [string]$j.model
            $info.StateAge = (Get-Item $info.StateFile).LastWriteTime
        } catch {}
    }
    try { $h = Invoke-RestMethod "http://127.0.0.1:$($info.ProxyPort)/_health" -TimeoutSec 4 -ErrorAction Stop; if ($h.proxy) { $info.ProxyUp = $true } } catch {}
    return $info
}

function Start-SysPilotKaggleTpuProxy {
    <# Startet proxy.py (stabile 127.0.0.1:18787-Adresse) versteckt. #>
    param([string]$Dir = '')
    if (-not $Dir) { $Dir = (Get-SysPilotKaggleTpuInfo).Dir }
    if (-not $Dir) { Write-Host '  heretic-claude-Ordner nicht gefunden.' -ForegroundColor Red; return $false }
    $proxy = Join-Path $Dir 'proxy.py'
    if (-not (Test-Path $proxy)) { Write-Host "  proxy.py fehlt in $Dir" -ForegroundColor Red; return $false }
    # Bereits laufend?
    $info = Get-SysPilotKaggleTpuInfo
    if ($info.ProxyUp) { Write-Host '  Proxy laeuft bereits.' -ForegroundColor DarkGray; return $true }
    $env:HERETIC_STATE_DIR = Join-Path $env:LOCALAPPDATA 'heretic-claude'
    $p = Start-Process -FilePath 'python' -ArgumentList @($proxy) -WorkingDirectory $Dir -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 2
    $info2 = Get-SysPilotKaggleTpuInfo
    if ($info2.ProxyUp) { Write-Host "  Proxy laeuft (PID $($p.Id)) -> http://127.0.0.1:$($info2.ProxyPort)/v1" -ForegroundColor Green; return $true }
    Write-Host '  Proxy startete nicht rechtzeitig - python/Port pruefen.' -ForegroundColor Yellow
    return $false
}

function Start-SysPilotKaggleTpu {
    <# Startet den TPU-Server ueber das vorhandene watchdog.ps1
       (Session-Start, URL/Key -> state.json, Auto-Restart).
       -Mode 'fast': fast-start + Gewichte per HF-Download
       statt ueber den langsamen Kaggle-Dataset-Mount (GCSFuse);
       Vision bleibt aktiv (ohne --text-only).
       Hintergrund: Dataset-Mount las ~52 GB mit >10 min/Shard ->
       health-timeout nach 90 min; HF-Fallback auf lokaler VM-Disk
       ist deutlich schneller. #>
    param([string]$Dir = '', [ValidateSet('dataset','fast')][string]$Mode = 'dataset')
    if (-not $Dir) { $Dir = (Get-SysPilotKaggleTpuInfo).Dir }
    if (-not $Dir) { Write-Host '  heretic-claude-Ordner nicht gefunden.' -ForegroundColor Red; return $false }
    $wd = Join-Path $Dir 'watchdog.ps1'
    if (-not (Test-Path $wd)) { Write-Host "  watchdog.ps1 fehlt in $Dir" -ForegroundColor Red; return $false }
    # Watchdog-laeuft? (Prozess auf watchdog.ps1)
    $running = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'watchdog\.ps1' })
    if ($running.Count -gt 0) { Write-Host "  Watchdog laeuft bereits (PID $($running[0].ProcessId))." -ForegroundColor DarkGray; return $true }
    if ($Mode -eq 'fast') {
        Write-Host '  Modus SCHNELL: fast-start + Gewichte via HF-Download (Vision an)' -ForegroundColor Cyan
        Write-Host '  (Dataset-Mount war zu langsam: >10 min pro Shard, health-timeout).' -ForegroundColor DarkGray
    } else {
        Write-Host '  Modus DATASET: Original-Setup (Weights als Kaggle-Dataset-Mount).' -ForegroundColor Cyan
    }
    Write-Host '  Starte TPU-Watchdog (Kaggle-Session, 5-25 Min bis BEREIT) ...' -ForegroundColor Cyan
    if ($Mode -eq 'fast') {
        # ExtraArgs als Array uebergeben - bei -File-Kollabierung ein Argument!
        $inner = "& '$wd' -ExtraArgs @('--fast-start','--weights-dataset','rahim3/hf-fallback-offline')"
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-Command',$inner) -WorkingDirectory $Dir -WindowStyle Hidden -PassThru
    } else {
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',"`"$wd`"") -WorkingDirectory $Dir -WindowStyle Hidden -PassThru
    }
    Write-Host "  Watchdog gestartet (PID $($p.Id)) - Fortschritt in dessen Ausgabe/state.json." -ForegroundColor Green
    Write-Host '  Tipp: Log beobachten via %LOCALAPPDATA%\heretic-claude\state.json' -ForegroundColor DarkGray
    return $true
}

function Stop-SysPilotKaggleTpu {
    <# Beendet TPU-Session + Proxy ueber stop-tpu.ps1. #>
    param([string]$Dir = '')
    if (-not $Dir) { $Dir = (Get-SysPilotKaggleTpuInfo).Dir }
    if (-not $Dir) { Write-Host '  heretic-claude-Ordner nicht gefunden.' -ForegroundColor Red; return $false }
    $st = Join-Path $Dir 'stop-tpu.ps1'
    if (Test-Path $st) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $st 2>&1 | ForEach-Object { Write-Host "  $_" }
        return $true
    }
    # Fallback: Watchdog-Prozesse beenden
    $running = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'watchdog\.ps1' })
    foreach ($r in $running) { Stop-Process -Id $r.ProcessId -Force -ErrorAction SilentlyContinue }
    Write-Host "  $($running.Count) Watchdog-Prozess(e) beendet." -ForegroundColor Yellow
    return $true
}

function Get-SysPilotKaggleSetupStatus {
    <# Pro-User-Status fuer Kaggle-TPU: CLI, Auth, kaggle-tpu-lab, Skripte. #>
    $st = [pscustomobject]@{
        KaggleCli=$false; AuthOk=$false; LabDir=''; LabOk=$false
        ScriptsDir=''; ScriptsSource=''; Python=$false
    }
    $st.Python = [bool](Get-Command python -ErrorAction SilentlyContinue)
    $st.KaggleCli = [bool](Get-Command kaggle -ErrorAction SilentlyContinue)
    if (-not $st.KaggleCli -and $st.Python) {
        $st.KaggleCli = [bool](& python -m kaggle --version 2>$null)
    }
    if ($st.KaggleCli) {
        & kaggle kernels list --mine --page-size 1 2>&1 | Out-Null
        $st.AuthOk = ($LASTEXITCODE -eq 0)
    }
    $lab = Join-Path $env:USERPROFILE 'kaggle-tpu-lab'
    if (Test-Path (Join-Path $lab 'launch.py')) { $st.LabDir = $lab; $st.LabOk = $true }
    $tpu = Get-SysPilotKaggleTpuInfo
    if ($tpu.Dir) {
        $st.ScriptsDir = $tpu.Dir
        $st.ScriptsSource = if ($tpu.Dir -like '*kaggle-tpu*' -and $tpu.Dir -notlike '*heretic-claude*') { 'syspilot-bundle' } else { 'user-dir' }
    }
    return $st
}

function Install-SysPilotKaggleTpuSetup {
    <# Gefuehrter pro-User-Setup: kaggle-CLI, Auth-Token, kaggle-tpu-lab,
       TPU-Skripte (heretic-claude oder SysPilot-Bundle). #>
    $st = Get-SysPilotKaggleSetupStatus
    Write-Host "`n  === Kaggle-TPU Einrichtung (dein eigener Zugang) ===" -ForegroundColor Cyan

    # 1) Python + kaggle-CLI
    if (-not $st.Python) {
        Write-Host '  [!] Python fehlt - zuerst installieren (z.B. winget install Python.Python.3.12)' -ForegroundColor Red
        return
    }
    if (-not $st.KaggleCli) {
        Write-Host '  Installiere kaggle-CLI ...' -ForegroundColor Cyan
        & python -m pip install --user kaggle 2>&1 | Select-Object -Last 3 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
        $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
        $st = Get-SysPilotKaggleSetupStatus
    }
    Write-Host ("  kaggle-CLI: " + $(if($st.KaggleCli){'OK'}else{'FEHLT'})) -ForegroundColor $(if($st.KaggleCli){'Green'}else{'Red'})

    # 2) Auth-Token (pro User, ~/.kaggle/access_token)
    if (-not $st.AuthOk) {
        Write-Host '  Kaggle-Token noetig: https://www.kaggle.com/settings -> API -> Create New Token' -ForegroundColor Yellow
        Write-Host '  (TPU-Nutzung erfordert Telefonverifizierung beim Kaggle-Account)' -ForegroundColor DarkGray
        if (Confirm-SysPilot 'Token-Seite im Browser oeffnen?') { Start-Process 'https://www.kaggle.com/settings' }
        $sec = Read-Host '  Token einfuegen (unsichtbar, Enter = ueberspringen)' -AsSecureString
        $tok = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
        if ($tok) {
            $kd = Join-Path $env:USERPROFILE '.kaggle'
            New-Item -ItemType Directory -Force $kd | Out-Null
            [IO.File]::WriteAllText((Join-Path $kd 'access_token'), $tok.Trim(), (New-Object Text.UTF8Encoding($false)))
            Write-Host '  Token gespeichert (~\.kaggle\access_token).' -ForegroundColor Green
        } else { Write-Host '  Token uebersprungen - Auth bleibt offen.' -ForegroundColor Yellow }
    } else { Write-Host '  Kaggle-Auth: OK (dein Account)' -ForegroundColor Green }

    # 3) kaggle-tpu-lab klonen
    if (-not $st.LabOk) {
        $lab = Join-Path $env:USERPROFILE 'kaggle-tpu-lab'
        if (Get-Command git -ErrorAction SilentlyContinue) {
            Write-Host "  Klone kaggle-tpu-lab (MIT, ARahim3) nach $lab ..." -ForegroundColor Cyan
            & git clone --depth 1 https://github.com/ARahim3/kaggle-tpu-lab.git $lab 2>&1 | Select-Object -Last 3 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
        } else { Write-Host '  git fehlt - Repo manuell klonen: github.com/ARahim3/kaggle-tpu-lab' -ForegroundColor Yellow }
    } else { Write-Host "  kaggle-tpu-lab: OK ($($st.LabDir))" -ForegroundColor Green }

    # 4) TPU-Skripte: vorhandenes heretic-claude oder SysPilot-Bundle bereitstellen
    if (-not $st.ScriptsDir) {
        $bundle = Join-Path (Split-Path $PSScriptRoot -Parent) 'kaggle-tpu'
        $target = Join-Path $env:USERPROFILE 'heretic-claude'
        if ((Test-Path (Join-Path $bundle 'watchdog.ps1')) -and (Confirm-SysPilot "TPU-Skripte nach $target kopieren (aus SysPilot-Paket)?")) {
            New-Item -ItemType Directory -Force $target | Out-Null
            Copy-Item (Join-Path $bundle '*') $target -Recurse -Force
            Write-Host "  Skripte installiert: $target" -ForegroundColor Green
        }
    } else { Write-Host "  TPU-Skripte: OK ($($st.ScriptsDir) [$($st.ScriptsSource)])" -ForegroundColor Green }

    # Abschluss-Status
    $st2 = Get-SysPilotKaggleSetupStatus
    Write-Host "`n  Ergebnis:" -ForegroundColor Cyan
    Write-Host ("    kaggle-CLI: {0}   Auth: {1}   Lab: {2}   Skripte: {3}" -f $(if($st2.KaggleCli){'OK'}else{'FEHLT'}), $(if($st2.AuthOk){'OK'}else{'FEHLT'}), $(if($st2.LabOk){'OK'}else{'FEHLT'}), $(if($st2.ScriptsDir){'OK'}else{'FEHLT'})) -ForegroundColor $(if($st2.AuthOk -and $st2.LabOk -and $st2.ScriptsDir){'Green'}else{'Yellow'})
    if (-not $st2.AuthOk) { Write-Host '  Offen: Kaggle-Token unter kaggle.com/settings erstellen und einfuegen.' -ForegroundColor Yellow }
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
}

function Show-SysPilotKaggleTpuMenu {
    <# heretic-claude / kaggle-tpu-lab: TPU-Status, Proxy, Start/Stop,
       Provider-Registrierung (OpenAI-kompatibel via 127.0.0.1:18787/v1). #>
    while ($true) {
        $info = Get-SysPilotKaggleTpuInfo
        Write-Host "`n  ========================================================" -ForegroundColor Cyan
        Write-Host "           KAGGLE TPU ( heretic-claude / kaggle-tpu-lab )" -ForegroundColor Cyan
        Write-Host "  ========================================================" -ForegroundColor Cyan
        if (-not $info.Dir) {
            Write-Host '  Keine heretic-claude-Installation gefunden.' -ForegroundColor Yellow
            Write-Host '  Erwartet: proxy.py + watchdog.ps1 (z.B. C:\Users\<du>\heretic-claude)' -ForegroundColor DarkGray
            Write-Host '  Projekt: github.com/ARahim3/kaggle-tpu-lab (MIT)' -ForegroundColor DarkCyan
            $items = @(@{ Label='Einrichtungs-Assistent (eigener Kaggle-Zugang)'; Color='Green'; Tag='setup' }, @{ Label='Ordner manuell waehlen ...'; Color='Cyan'; Tag='pick' }, @{ Label='GitHub-Seite oeffnen'; Color='DarkGray'; Tag='gh' }, @{ Label='Zurueck'; Color='DarkGray'; Tag=$null })
        } else {
            Write-Host "  Ordner: $($info.Dir)" -ForegroundColor DarkGray
            Write-Host "  Proxy (18787): $(if($info.ProxyUp){'LAEUFT'}else{'aus'})   Upstream: $(if($info.Upstream){$info.Upstream}else{'-'})   Modell: $(if($info.Model){$info.Model}else{'-'})" -ForegroundColor $(if($info.ProxyUp -and $info.Upstream){'Green'}else{'Yellow'})
            if ($info.StateAge) { Write-Host "  state.json: $($info.StateAge.ToString('HH:mm:ss'))" -ForegroundColor DarkGray }
            $items = @(
                @{ Label='[S] Einrichtungs-Assistent (Kaggle-CLI, Token, Repo, Skripte)'; Color='Green'; Tag='setup' },
                @{ Label='[P] Proxy starten (127.0.0.1:18787)'; Color='Green'; Tag='proxy' },
                @{ Label='[T] TPU-Server starten (Dataset-Mount, Original)'; Color='Green'; Tag='tpu' },
                @{ Label='[F] TPU-Server schnell starten (HF-Gewichte + Vision, ~20 Min)'; Color='Green'; Tag='tpufast' },
                @{ Label='[X] TPU stoppen (Session + Proxy)'; Color='Yellow'; Tag='stop' },
                @{ Label='[R] Als Herbert-Provider registrieren (OpenAI-kompatibel)'; Color='Cyan'; Tag='reg' },
                @{ Label='[U] Projekt auf TPU schalten (use-tpu.ps1)'; Color='Cyan'; Tag='use' },
                @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
            )
        }
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'Kaggle TPU' -Footer 'Enter = Aktion, Esc = zurueck'
        if ($null -eq $sel) { return }
        if ($sel -eq 'setup') { Install-SysPilotKaggleTpuSetup; continue }
        if ($sel -eq 'gh') { Start-Process 'https://github.com/ARahim3/kaggle-tpu-lab'; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; continue }
        if ($sel -eq 'pick') {
            $p = Read-SysPilotInput 'Pfad zum heretic-claude-Ordner (mit proxy.py)'
            if ($p -and (Test-Path (Join-Path $p 'proxy.py'))) {
                # Persistenter Pfad in Config als Extra-Dir merken
                $cfg = Read-SysPilotAiAssistConfig
                if ($cfg.PSObject.Properties['KaggleTpuDir']) { $cfg.KaggleTpuDir = $p }
                else { $cfg | Add-Member -NotePropertyName KaggleTpuDir -NotePropertyValue $p -Force }
                Write-SysPilotAiAssistConfig $cfg
                Write-Host "  Gespeichert: $p" -ForegroundColor Green
            } else { Write-Host '  Ungueltig - proxy.py nicht gefunden.' -ForegroundColor Red }
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; continue
        }
        if ($sel -eq 'proxy') { [void](Start-SysPilotKaggleTpuProxy -Dir $info.Dir); Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; continue }
        if ($sel -eq 'tpu') { [void](Start-SysPilotKaggleTpu -Dir $info.Dir -Mode 'dataset'); Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; continue }
        if ($sel -eq 'tpufast') { [void](Start-SysPilotKaggleTpu -Dir $info.Dir -Mode 'fast'); Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; continue }
        if ($sel -eq 'stop') { [void](Stop-SysPilotKaggleTpu -Dir $info.Dir); Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; continue }
        if ($sel -eq 'reg') {
            $exists = $false
            try {
                $cfg = Read-SysPilotAiAssistConfig
                foreach ($ep in @($cfg.Providers)) { if ($ep.BaseUrl -eq 'http://127.0.0.1:18787/v1') { $exists = $true } }
            } catch {}
            if ($exists) { Write-Host '  Provider ist bereits registriert.' -ForegroundColor DarkGray }
            else {
                Save-SysPilotAiProviderEntry -Entry @{ Name='Kaggle TPU (Proxy 18787)'; BaseUrl='http://127.0.0.1:18787/v1'; Model=''; Kind='lokal'; Enabled=$true; ApiKey=''; HasKeyInput=$false }
                Write-Host '  Provider "Kaggle TPU (Proxy 18787)" registriert - erscheint in der Provider-Liste.' -ForegroundColor Green
            }
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; continue
        }
        if ($sel -eq 'use') {
            $proj = Read-SysPilotInput 'Projektordner fuer use-tpu.ps1'
            $ut = Join-Path $info.Dir 'use-tpu.ps1'
            if ($proj -and (Test-Path $ut)) {
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ut -Project $proj 2>&1 | ForEach-Object { Write-Host "  $_" }
            } else { Write-Host '  use-tpu.ps1 oder Ordner fehlt.' -ForegroundColor Red }
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; continue
        }
    }
}

function Show-SysPilotAiOnboarding {
    <# Ersteinrichtung: erkennt was laeuft, bietet Install-Hilfe
       (Ollama via winget, OmniRoute via npm, freelm via pip,
       FreeLLMAPI=Docker-Hinweis) ODER direktes Eintragen eines
       Cloud-API-Keys. Am Ende Onboarded-Flag setzen. #>
    Write-Host "`n  === KI-ASSISTENZ ERSTEINRICHTUNG ===" -ForegroundColor Cyan
    Write-Host '  Pruefe lokale KI-Provider ...' -ForegroundColor DarkGray
    $providers = @(Get-SysPilotAiProviders)
    $local = @($providers | Where-Object { $_.Kind -in @('local','free') -and $_.Enabled })
    if ($local.Count -gt 0) {
        Write-Host "  Bereits nutzbar: $(($local | ForEach-Object { $_.Name }) -join ', ')" -ForegroundColor Green
    } else {
        Write-Host '  Keine lokalen Provider aktiv - Pollinations (free) ist Fallback.' -ForegroundColor DarkYellow
    }
    Write-Host ''
    $acts = @(
        @{ Label = 'Lokalen KI-Server installieren (Ollama - kostenlos, unlimitiert)'; Color='Green'; Tag='ollama' },
        @{ Label = 'Router-Tool installieren (OmniRoute npm / freelm pip / FreeLLMAPI Docker)'; Color='Cyan'; Tag='routers' },
        @{ Label = 'Cloud-API-Key eintragen (Gemini, Groq, OpenRouter u.a.)'; Color='Yellow'; Tag='key' },
        @{ Label = 'Pollinations (free) reicht vorerst - spaeter einrichten'; Color='DarkGray'; Tag='later' },
        @{ Label = 'Abbrechen'; Color='DarkGray'; Tag='back' }
    )
    $sel = Show-SysPilotArrowMenu -Items $acts -Title 'Ersteinrichtung KI-Assistenz' -Footer 'Enter = Aktion, Esc = abbruch'
    if ($null -eq $sel -or $sel -eq 'back') { return }
    switch ($sel) {
        'ollama' {
            if (Get-Command winget -ErrorAction SilentlyContinue) {
                Write-Host "`n  winget install Ollama.Ollama ..." -ForegroundColor Cyan
                $r = Invoke-SysPilotMonitoredProcess -FilePath 'winget.exe' -ArgList @('install','--id','Ollama.Ollama','--exact','--accept-package-agreements','--accept-source-agreements','--disable-interactivity') -Label 'Ollama-Installation' -TimeoutSec 900
                if ($r.Ok) {
                    Write-Host '  [OK] Ollama installiert. Server ggf. noch starten (ollama serve).' -ForegroundColor Green
                } else {
                    Write-Host "  [!] $($r.Error)" -ForegroundColor Red
                    if ($r.Error) { Write-Host "  Tipp: Katalog -> KI-Apps -> Ollama" -ForegroundColor DarkYellow }
                }
            } else { Write-Host '  winget nicht gefunden.' -ForegroundColor Red }
        }
        'routers' {
            Show-SysPilotAiRouterInstallMenu
        }
        'key' {
            Show-SysPilotAiQuickKeySetup
        }
        'later' {
            Write-Host '  OK - Pollinations (free) wird als Fallback genutzt.' -ForegroundColor DarkGray
        }
    }
    if ($sel -ne 'back') { Set-SysPilotAiOnboarded }
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
}

function Show-SysPilotAiRouterInstallMenu {
    <# Install-Hilfe fuer die lokalen Router (OpenAI-kompatibel). #>
    $items = @(
        @{ Label = 'OmniRoute (npm i -g omniroute) - 375 Provider, localhost:20128'; Color='Cyan'; Tag='omniroute' },
        @{ Label = 'freelm (pip install freelm) - Python-CLI/Router'; Color='Cyan'; Tag='freelm' },
        @{ Label = 'FreeLLMAPI (Docker: tashfeenahmed/freellmapi) - 87 Free-Provider, localhost:3001'; Color='Cyan'; Tag='freellmapi' },
        @{ Label = 'Katalog oeffnen (KI-Apps Kategorie)'; Color='White'; Tag='catalog' },
        @{ Label = 'Zurueck'; Color='DarkGray'; Tag='back' }
    )
    $sel = Show-SysPilotArrowMenu -Items $items -Title 'Router-Tool installieren' -Footer 'Enter = Aktion, Esc = zurueck'
    if ($null -eq $sel -or $sel -eq 'back') { return }
    switch ($sel) {
        'omniroute' {
            $npm = (Get-Command npm.cmd -ErrorAction SilentlyContinue).Source
            if (-not $npm) { $npm = (Get-Command npm -ErrorAction SilentlyContinue).Source }
            if (-not $npm) { Write-Host '  [!] npm nicht gefunden (Node.js noetig)' -ForegroundColor Red; break }
            Write-Host "`n  npm install -g omniroute ..." -ForegroundColor Cyan
            $r = Invoke-SysPilotMonitoredProcess -FilePath $npm -ArgList @('install','-g','omniroute') -Label 'OmniRoute' -TimeoutSec 600
            if ($r.Ok) { Write-Host '  [OK] OmniRoute installiert - Start: omniroute (localhost:20128)' -ForegroundColor Green }
            else { Write-Host "  [!] $($r.Error)" -ForegroundColor Red }
        }
        'freelm' {
            $py = $null
            if (Get-Command Get-SysPilotPythonExeForPip -ErrorAction SilentlyContinue) { $py = Get-SysPilotPythonExeForPip }
            if (-not $py) { $py = (Get-Command python.exe -ErrorAction SilentlyContinue).Source }
            if (-not $py) { Write-Host '  [!] python.exe nicht gefunden' -ForegroundColor Red; break }
            Write-Host "`n  $py -m pip install freelm ..." -ForegroundColor Cyan
            $r = Invoke-SysPilotMonitoredProcess -FilePath $py -ArgList @('-m','pip','install','freelm') -Label 'freelm' -TimeoutSec 600
            if ($r.Ok) { Write-Host '  [OK] freelm installiert.' -ForegroundColor Green }
            else { Write-Host "  [!] $($r.Error)" -ForegroundColor Red }
        }
        'freellmapi' {
            Write-Host "`n  FreeLLMAPI braucht Docker. Repo: https://github.com/tashfeenahmed/freellmapi" -ForegroundColor Cyan
            Write-Host '  Schneller: docker run -p 3001:3001 ... (siehe Repo README)' -ForegroundColor DarkGray
            if (Confirm-SysPilot 'GitHub-Repo im Browser oeffnen?') { Start-Process 'https://github.com/tashfeenahmed/freellmapi' }
        }
        'catalog' {
            if (Get-Command Show-SysPilotCatalogBrowser -ErrorAction SilentlyContinue) { Show-SysPilotCatalogBrowser }
        }
    }
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
}

function Show-SysPilotAiQuickKeySetup {
    <# Direktes Eintragen eines Cloud-API-Keys: Anbieter waehlen,
       Key einfuegen, Modell, Test, speichern. Deckt den "5-10 gute
       Provider mit enough Kontingent"-Fall ab. #>
    $sugg = @(Get-SysPilotAiProviderCatalog)
    $items = foreach ($s in $sugg) {
        @{ Label = "$($s.Name) - $($s.Note)"; Color='Yellow'; Tag=$s }
    }
    $items += @{ Label = 'Eigener OpenAI-kompatibler Endpoint'; Color='White'; Tag='custom' }
    $items += @{ Label = 'Zurueck'; Color='DarkGray'; Tag=$null }
    $sel = Show-SysPilotArrowMenu -Items $items -Title 'Cloud-API-Key eintragen' -Footer 'Enter = waehlen, Esc = zurueck'
    if ($null -eq $sel) { return }
    if ($sel -eq 'custom') {
        # Vollstaendiger WPF-Dialog (inkl. Key-Feld)
        try {
            $e = Show-SysPilotAiProviderEditDialog
            if (-not $e) { return }
            Save-SysPilotAiProviderEntry -Entry $e
            Write-SysPilotLog "KI-Provider konfiguriert: $($e.Name)"
            $np = [pscustomobject]@{ Name=$e.Name; BaseUrl=$e.BaseUrl; Model=$e.Model; ApiKey=$(if($e.HasKeyInput){$e.ApiKey}else{''}) }
            Write-Host "`n  Teste Verbindung ..." -ForegroundColor Cyan
            $t = Test-SysPilotAiProvider -Provider $np
            if ($t.Ok) { Write-Host "  [OK] $($t.Models) Modelle verfuegbar" -ForegroundColor Green }
            else { Write-Host "  [!] $($t.Error)" -ForegroundColor Red }
            if (Confirm-SysPilot "API-Key + Base-URL in 'Dokumente\api keys\' sichern (plaintext)?") { Save-SysPilotAiKeyBackup | Out-Null }
            return
        } catch { }
        $name = Read-SysPilotInput 'Anzeigename'
        $url  = Read-SysPilotInput 'Base-URL'
        if (-not $name -or -not $url) { return }
        $model = Read-SysPilotInput 'Modell (leer=auto)'
        $key   = Read-SysPilotInput 'API-Key'
        if (-not $key) { Write-Host '  Abgebrochen (kein Key).' -ForegroundColor Yellow; return }
        $p = [pscustomobject]@{ Name=$name; BaseUrl=$url; Model=$model; Note=''; Signup='' }
    } else { $p = $sel }
    if ($sel -ne 'custom' -and $p.Signup) {
        Write-Host "`n  Key holen unter: $($p.Signup)" -ForegroundColor Cyan
        if (Confirm-SysPilot 'Signup-Seite im Browser oeffnen?') { Start-Process $p.Signup }
    }
    $key = Read-SysPilotInput "API-Key fuer $($p.Name) einfuegen"
    if (-not $key) { Write-Host '  Abgebrochen (kein Key).' -ForegroundColor Yellow; return }
    # Provider anlegen/updaten
    $cfg = Read-SysPilotAiAssistConfig
    $existing = $null
    foreach ($cp in @($cfg.Providers)) { if ($cp.BaseUrl -eq $p.BaseUrl) { $existing = $cp } }
    if ($existing) {
        $existing.ApiKeyCipher = Protect-SysPilotSecret $key
        $existing.Enabled = $true
        if ($p.Model) { $existing.Model = $p.Model }
    } else {
        $cfg.Providers = @($cfg.Providers) + @([pscustomobject]@{
            Name=$p.Name; BaseUrl=$p.BaseUrl; Model=$p.Model; Kind='cloud'
            Enabled=$true; ApiKeyCipher=(Protect-SysPilotSecret $key)
        })
    }
    Write-SysPilotAiAssistConfig $cfg
    Write-SysPilotLog "KI-Provider konfiguriert: $($p.Name)"
    # Sofort-Test
    Write-Host "`n  Teste Verbindung ..." -ForegroundColor Cyan
    $np = [pscustomobject]@{ Name=$p.Name; BaseUrl=$p.BaseUrl; Model=$p.Model; ApiKey=$key }
    $t = Test-SysPilotAiProvider -Provider $np
    if ($t.Ok) { Write-Host "  [OK] $($t.Models) Modelle verfuegbar" -ForegroundColor Green }
    else { Write-Host "  [!] $($t.Error)" -ForegroundColor Red; Write-Host '  (Key evtl. noch nicht aktiv - spaeter unter Provider-Details testen)' -ForegroundColor DarkYellow }
    # Key-Backup anbieten
    if (Confirm-SysPilot "API-Key + Base-URL in 'Dokumente\api keys\' sichern (plaintext)?") {
        Save-SysPilotAiKeyBackup | Out-Null
    }
}

function Show-SysPilotAiAssist {
    <# Hauptmenue der KI-Assistenz. #>
    $onboarded = Get-SysPilotAiOnboardState
    while ($true) {
        $providers = @(Get-SysPilotAiProviders)
        $en = @($providers | Where-Object { $_.Enabled })
        Write-Host ""
        Write-Host "  ========================================================" -ForegroundColor Cyan
        Write-Host "           SYSPilot KI-ASSISTENZ" -ForegroundColor Cyan
        Write-Host "           $($en.Count) aktive Provider" -ForegroundColor Cyan
        Write-Host "  ========================================================" -ForegroundColor Cyan
        $items = @()
        if (-not $onboarded) {
            $items += @{ Label = 'ERSTEINRICHTUNG (empfohlen: Ollama installieren oder Key eintragen)'; Color='Green'; Tag='onboard' }
        }
        $items += @(
            @{ Label = 'Mit dem Assistenten chatten'; Color='Green'; Tag='chat' },
            @{ Label = 'Provider verwalten (lokal + Cloud + Keys)'; Color='Cyan'; Tag='providers' },
            @{ Label = 'MCP-Server (desktop-commander, powershell, github, browseros)'; Color='Cyan'; Tag='mcp' },
            @{ Label = 'Herbert-Manager: Skills + Konnektoren (kostenlose Kataloge)'; Color='Green'; Tag='manager' },
            @{ Label = 'KI-Setup-Assistent (Clients, Router, Bruecke, News)'; Color='Green'; Tag='kisetup' },
            @{ Label = 'KI-Tools installieren (Ollama, LM Studio, PocketAI, Layla, Jan ...)'; Color='Green'; Tag='apps' },
            @{ Label = 'KI-News-Feed (Reddit + HackerNews)'; Color='White'; Tag='kinews' },
            @{ Label = 'Herbert-gestuetzte Installation (fragt + schlaegt vor + Tool)'; Color='Green'; Tag='guided' },
            @{ Label = 'Modelle suchen + herunterladen (HuggingFace GGUF)'; Color='Green'; Tag='models' },
            @{ Label = 'Prozess-Hinweise bei Programmstart (Pilot Herbert)'; Color='DarkCyan'; Tag='prochints' },
            @{ Label = 'Bord-Ansagen stummschalten (Flug-Ansagen, Wetteraussprueche)'; Color='DarkCyan'; Tag='ansagen' },
            @{ Label = 'Provider-Modus: Cloud+Lokal (Standard) / strict lokal / strict Cloud'; Color='Cyan'; Tag='modmode' },
            @{ Label = 'Bevorzugter Provider pinnen (Auto-Kette zuerst)'; Color='Cyan'; Tag='pinprov' },
            @{ Label = 'Herbert-Interessen (Themen-Profil fuer News/Infos)'; Color='Green'; Tag='interests' },
            @{ Label = 'Schnellfrage mit Kontext'; Color='Yellow'; Tag='quick' },
            @{ Label = 'API-Keys sichern (Dokumente\api keys\)'; Color='DarkYellow'; Tag='keybackup' },
            @{ Label = 'Zurueck'; Color='DarkGray'; Tag=$null }
        )
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'KI-Assistenz' -Footer 'Enter = Aktion, Esc = zurueck'
        if ($null -eq $sel) { return }
        switch ($sel) {
            'onboard'   { Show-SysPilotAiOnboarding; $onboarded = Get-SysPilotAiOnboardState }
            'chat'      { Show-SysPilotAiChat }
            'providers' {
                try { Show-SysPilotAiProvidersWindow }
                catch { Show-SysPilotAiProviderMenu }
            }
            'mcp'       { if (Get-Command Show-SysPilotMcpMenu -ErrorAction SilentlyContinue) { Show-SysPilotMcpMenu } }
            'manager'   { Show-SysPilotHerbertManager }
            'apps'      { Show-SysPilotAiAppsInstall }
            'kisetup'   { Show-SysPilotKiSetupWizard }
            'kinews'    { Show-SysPilotAiNews }
            'guided'    { Show-SysPilotAiGuidedInstall }
            'models'    { Show-SysPilotAiModelFinder }
            'prochints' {
                $cur = Get-SysPilotAiProcessHintsEnabled
                $new = -not $cur
                Set-SysPilotAiProcessHintsEnabled -On $new
                Write-Host ("  Prozess-Hinweise: " + $(if($new){'AN - Herbert meldet sich bei Programmstarts'}else{'AUS (stumm)'})) -ForegroundColor $(if($new){'Green'}else{'DarkGray'})
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'ansagen'   {
                $cur = Get-SysPilotHerbertAnnouncementsEnabled
                $new = -not $cur
                Set-SysPilotHerbertAnnouncementsEnabled -On $new
                Write-Host ("  Bord-Ansagen: " + $(if($new){'AN - Flug-Ansagen, Wetteraussprueche'}else{'AUS (stumm)'})) -ForegroundColor $(if($new){'Green'}else{'DarkGray'})
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'modmode'   {
                $cur = Get-SysPilotAiProviderMode
                $next = switch ($cur) { 'auto' { 'local' } 'local' { 'cloud' } default { 'auto' } }
                Set-SysPilotAiProviderMode -Mode $next
                $desc = switch ($next) {
                    'auto'  { 'Cloud zuerst -> lokal als Fallback -> Pollinations (Standard)' }
                    'local' { 'STRICT LOKAL - keine Cloud-Provider, nur Ollama/llama.cpp/etc.' }
                    'cloud' { 'STRICT CLOUD - nur Remote-Provider, kein lokales Modell' }
                }
                Write-Host "  Provider-Modus: $next" -ForegroundColor Cyan
                Write-Host "    $desc" -ForegroundColor DarkGray
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'pinprov'   {
                $prov = @(Get-SysPilotAiProviders | Where-Object { $_.Enabled } | Sort-Object Kind, Name)
                if ($prov.Count -eq 0) { Write-Host '  Keine aktivierten Provider.' -ForegroundColor Red; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; break }
                $items = @(@{ Label = "(kein Pin - Auto-Reihenfolge)"; Color='Gray'; Tag='' })
                foreach ($p in $prov) {
                    $items += @{ Label = ("{0,-22} [{1}] {2}" -f $p.Name, $p.Kind, ($p.BaseUrl -replace 'https?://','')); Color = $(if ($p.Kind -eq 'cloud') {'Cyan'} else {'Green'}); Tag = $p.Name }
                }
                Write-Host '  Bevorzugter Provider (wird in der Auto-Kette zuerst versucht):' -ForegroundColor Yellow
                $pick = Show-SysPilotArrowMenu -Title 'Provider pinnen' -Items $items
                if ($pick) {
                    $tag = [string]$pick.Tag
                    Set-SysPilotAiPreferredProvider -Name $tag
                    if ($tag) { Write-Host "  Pin gesetzt: $tag" -ForegroundColor Green } else { Write-Host '  Pin entfernt - Auto-Reihenfolge aktiv' -ForegroundColor DarkGray }
                }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'interests' {
                $cur = @(Get-SysPilotHerbertInterests)
                Write-Host ("  Aktuell: " + $(if($cur.Count){$cur -join ', '}else{'(kein Profil)'})) -ForegroundColor DarkGray
                Show-SysPilotHerbertInterestsSetup
            }
            'quick'     {
                $q = Read-SysPilotChoice 'Deine Frage an die KI'
                if ($q) { Show-SysPilotAiQuickAsk -Prompt $q -Title 'Schnellfrage' | Out-Null; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
            }
            'keybackup' {
                $n = Save-SysPilotAiKeyBackup
                if ($n -gt 0) { Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
            }
        }
    }
}

# --- KI-Provider-Verwaltung (WPF, Maus-bedienbar) ---
function Show-SysPilotAiProviderEditDialog {
    <# Modal-Dialog zum Anlegen/Bearbeiten eines Providers.
       Katalog-gesteuert: Anbieter aus Get-SysPilotAiProviderCatalog
       waehlen -> Name/BaseUrl/Modell werden vorbelegt, "API-Key holen"
       oeffnet die Signup-Seite, "Key laden" importiert den Key aus
       der gefundenen Key-Datei. Manuelle Felder bleiben editierbar.
       Gibt Hashtabelle zurueck oder $null (Abbruch).
       ApiKey-Feld: leer lassen beim Bearbeiten = Key bleibt. #>
    param($Provider, [string]$OriginalName = '', $Owner)
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase -ErrorAction SilentlyContinue
    $isEdit = ($null -ne $Provider)
    $dxaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="KI-Provider $(if($isEdit){'bearbeiten'}else{'hinzufuegen'})" Width="560" Height="560"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        Background="#FF1E1E2E" Foreground="#FFE0E0E0">
  <Window.Resources>
    <Style TargetType="TextBox"><Setter Property="Background" Value="#FF252538"/><Setter Property="Foreground" Value="#FFE0E0E0"/><Setter Property="BorderBrush" Value="#FF4A4A6A"/><Setter Property="Padding" Value="6,4"/></Style>
    <ControlTemplate x:Key="ComboDarkToggle" TargetType="ToggleButton">
      <Border x:Name="Bg" Background="#FF252538" BorderBrush="#FF4A4A6A" BorderThickness="1" CornerRadius="2"/>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="BorderBrush" Value="#FF4FC3F7"/></Trigger>
        <Trigger Property="IsChecked" Value="True"><Setter Property="BorderBrush" Value="#FF4FC3F7"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate>
    <Style TargetType="ComboBox">
      <Setter Property="Background" Value="#FF252538"/><Setter Property="Foreground" Value="#FFE0E0E0"/>
      <Setter Property="BorderBrush" Value="#FF4A4A6A"/><Setter Property="Padding" Value="5,3"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton x:Name="ToggleButton" Focusable="False" ClickMode="Press"
                Template="{StaticResource ComboDarkToggle}"
                IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"/>
              <ContentPresenter x:Name="ContentSite" IsHitTestVisible="False"
                Content="{TemplateBinding SelectionBoxItem}"
                ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                ContentTemplateSelector="{TemplateBinding ItemTemplateSelector}"
                Margin="8,0,24,0" VerticalAlignment="Center" HorizontalAlignment="Left"/>
              <Path Data="M 0 0 L 4 4 L 8 0 Z" Fill="#FF9E9E9E" Width="8" Height="4"
                    HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,10,0"/>
              <Popup x:Name="Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}"
                     AllowsTransparency="True" Focusable="False" PopupAnimation="Slide">
                <Border Background="#FF1E1E2E" BorderBrush="#FF4A4A6A" BorderThickness="1"
                        MinWidth="{TemplateBinding ActualWidth}" MaxHeight="320">
                  <ScrollViewer><ItemsPresenter/></ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.55"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="#FFE0E0E0"/><Setter Property="Background" Value="Transparent"/>
      <Setter Property="Padding" Value="8,4"/>
      <Style.Triggers>
        <Trigger Property="IsHighlighted" Value="True"><Setter Property="Background" Value="#FF34344E"/><Setter Property="Foreground" Value="#FFEAEAF2"/></Trigger>
        <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#CCE4EAF2"/><Setter Property="Foreground" Value="#FF1E1E2E"/></Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="Button"><Setter Property="Background" Value="#FF2D2D44"/><Setter Property="Foreground" Value="#FFE0E0E0"/><Setter Property="BorderBrush" Value="#FF4A4A6A"/><Setter Property="Padding" Value="14,5"/><Setter Property="Margin" Value="4,0"/><Setter Property="Cursor" Value="Hand"/></Style>
    <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#FF9E9E9E"/><Setter Property="FontSize" Value="11"/></Style>
  </Window.Resources>
  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <StackPanel x:Name="PnlCatalog" Grid.Row="0" Margin="0,0,0,10">
      <TextBlock Text="Anbieter-Katalog (kuratiert + deine Key-Dateien):" Margin="0,0,0,3" FontWeight="SemiBold" Foreground="#FFE0E0E0"/>
      <DockPanel>
        <ComboBox x:Name="CmbCat" Width="330" DisplayMemberPath="Label" VerticalAlignment="Center"/>
        <Button x:Name="BtnGetKey" Content="API-Key holen" ToolTip="Signup-Seite des Anbieters im Browser oeffnen" Margin="8,0,0,0"/>
        <Button x:Name="BtnLoadKey" Content="Key laden" ToolTip="API-Key aus der gefundenen Key-Datei uebernehmen" Margin="4,0,0,0"/>
      </DockPanel>
      <TextBlock x:Name="FCatNote" Margin="0,4,0,0" TextWrapping="Wrap" FontSize="10" Foreground="#FF7FBF7F"/>
    </StackPanel>
    <TextBlock Text="Anzeigename" Grid.Row="1" Margin="0,0,0,3"/>
    <TextBox x:Name="FName" Grid.Row="2" Margin="0,0,0,10" ToolTip="z.B. &quot;Mein OpenRouter&quot; oder &quot;Groq&quot;"/>
    <TextBlock Text="Base-URL (OpenAI-kompatibel)" Grid.Row="3" Margin="0,0,0,3"/>
    <TextBox x:Name="FUrl" Grid.Row="4" Margin="0,0,0,10" ToolTip="z.B. https://openrouter.ai/api/v1"/>
    <Grid Grid.Row="5" Margin="0,0,0,10">
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <StackPanel>
        <TextBlock Text="Modell (leer = auto)" Margin="0,0,0,3"/>
        <TextBox x:Name="FModel" ToolTip="z.B. gpt-4o-mini, llama-3.3-70b-versatile"/>
      </StackPanel>
      <StackPanel Grid.Column="1">
        <TextBlock Text="Art:" Margin="0,0,0,3"/>
        <ComboBox x:Name="FKind" SelectedIndex="0">
          <ComboBoxItem Content="cloud"/><ComboBoxItem Content="lokal"/>
        </ComboBox>
      </StackPanel>
    </Grid>
    <TextBlock Text="API-Key (Rechtsklick = einfuegen; leer lassen = kein Key / beim Bearbeiten: Key bleibt)" Grid.Row="6" Margin="0,0,0,3"/>
    <TextBox x:Name="FKey" Grid.Row="7" Margin="0,0,0,10" ToolTip="Wird DPAPI-verschluesselt gespeichert"/>
    <StackPanel Grid.Row="8" Orientation="Horizontal" Margin="0,0,0,10">
      <CheckBox x:Name="FEnabled" Content="aktiviert" IsChecked="True" VerticalAlignment="Center" Foreground="#FFE0E0E0"/>
      <TextBlock x:Name="FHint" Margin="16,0,0,0" TextWrapping="Wrap" VerticalAlignment="Center"/>
    </StackPanel>
    <StackPanel Grid.Row="9" Orientation="Horizontal" HorizontalAlignment="Right">
      <Button x:Name="BtnOk" Content="Speichern" IsDefault="True"/>
      <Button x:Name="BtnCancel" Content="Abbrechen" IsCancel="True"/>
    </StackPanel>
  </Grid>
</Window>
"@
    $dwin = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$dxaml)))
    if ($Owner) { $dwin.Owner = $Owner } else { $dwin.WindowStartupLocation = 'CenterScreen' }
    $dc = @{}
    foreach ($n in 'FName','FUrl','FModel','FKey','FKind','FEnabled','FHint','CmbCat','BtnGetKey','BtnLoadKey','FCatNote','PnlCatalog') { $dc[$n] = $dwin.FindName($n) }
    $catSel = $null
    $catItems = @()

    if ($isEdit) {
        $dc.PnlCatalog.Visibility = 'Collapsed'
        $dc.FName.Text = [string]$Provider.Name
        $dc.FUrl.Text = [string]$Provider.BaseUrl
        $dc.FModel.Text = [string]$Provider.Model
        $dc.FKey.Text = ''
        $dc.FKind.SelectedIndex = $(if ($Provider.Kind -eq 'lokal') { 1 } else { 0 })
        $dc.FEnabled.IsChecked = [bool]$Provider.Enabled
        $dc.FHint.Text = "Key ist gesetzt - Feld leer lassen, um ihn zu behalten."
        $dc.FHint.Foreground = [Windows.Media.BrushConverter]::new().ConvertFrom('#FF7FBF7F')
    } else {
        # Katalog laden (Key-Dateien inklusive) und Combo fuellen
        try { $catItems = @(Get-SysPilotAiProviderCatalog) } catch { $catItems = @() }
        $items = @()
        foreach ($c in $catItems) {
            $tag = switch ($c.Source) { 'keyfile' { '[Datei] ' } default { '' } }
            $km = if ($c.HasKey) { ' *' } else { '' }
            $conf = if ($c.Configured) { ' (konfiguriert)' } else { '' }
            $items += [pscustomobject]@{ Label = "$tag$($c.Name)$km$conf - $($c.Note)"; Entry = $c }
        }
        $dc.CmbCat.ItemsSource = $items
        if ($items.Count -gt 0) { $dc.CmbCat.SelectedIndex = -1 }
        $dc.FHint.Text = 'Tipp: Anbieter aus dem Katalog waehlen - BaseUrl/Modell werden vorbelegt, "API-Key holen" oeffnet die Signup-Seite.'
    }

    $applyCatalog = {
        param($entry)
        if (-not $entry) { return }
        $catSel = $entry
        $dc.FName.Text = ($entry.Name -replace ' \(Datei\)$','')
        $dc.FUrl.Text = $entry.BaseUrl
        if ($entry.Model) { $dc.FModel.Text = $entry.Model }
        $dc.FKind.SelectedIndex = $(if ($entry.Kind -eq 'lokal') { 1 } else { 0 })
        $dc.FHint.Text = $entry.Note
        $dc.FHint.Foreground = [Windows.Media.BrushConverter]::new().ConvertFrom('#FF9CCC65')
        $dc.BtnLoadKey.IsEnabled = [bool]$entry.KeyPath
        if ($entry.HasKey -and $entry.ApiKey) {
            $dc.FKey.Text = $entry.ApiKey
            $dc.FHint.Text = "$($entry.Note) - Key wurde aus der Datei uebernommen."
        }
    }
    $dc.CmbCat.Add_SelectionChanged({
        $sel = $dc.CmbCat.SelectedItem
        if ($sel) { & $applyCatalog $sel.Entry }
    })
    $dc.BtnGetKey.Add_Click({
        $sel = $dc.CmbCat.SelectedItem
        $url = $(if ($sel) { $sel.Entry.Signup } else { '' })
        if (-not $url) { $url = 'https://www.google.com/search?q=' + [uri]::EscapeDataString("$($dc.FName.Text) API key erstellen") }
        try { Start-Process $url } catch {}
    })
    $dc.BtnLoadKey.Add_Click({
        $sel = $dc.CmbCat.SelectedItem
        if (-not $sel -or -not $sel.Entry.KeyPath) { return }
        $e = Import-SysPilotAiKeyFile -Path $sel.Entry.KeyPath
        if ($e -and $e.ApiKey) {
            $dc.FKey.Text = $e.ApiKey
            $dc.FHint.Text = 'API-Key aus Key-Datei geladen.'
            $dc.FHint.Foreground = [Windows.Media.BrushConverter]::new().ConvertFrom('#FF7FBF7F')
        } else { $dc.FHint.Text = 'Key konnte nicht aus der Datei gelesen werden.' }
    })

    $result = $null
    $dcBtnOk = $dwin.FindName('BtnOk'); $dcBtnCancel = $dwin.FindName('BtnCancel')
    $dcBtnOk.Add_Click({
        $name = $dc.FName.Text.Trim(); $url = $dc.FUrl.Text.Trim()
        if (-not $name -or -not $url) {
            [System.Windows.MessageBox]::Show('Name und Base-URL sind erforderlich.', 'KI-Provider', 'OK', 'Warning') | Out-Null
            return
        }
        $result = @{
            Name=$name; BaseUrl=$url; Model=$dc.FModel.Text.Trim()
            Kind=[string]$dc.FKind.SelectedItem.Content
            Enabled=[bool]$dc.FEnabled.IsChecked
            ApiKey=$dc.FKey.Text
            HasKeyInput=($dc.FKey.Text.Trim().Length -gt 0)
        }
        $dwin.DialogResult = $true
    })
    Set-SysPilotWindowAutoSize -Win $dwin -MinWidth 560 -MinHeight 540
    $dwin.ShowDialog() | Out-Null
    return $result
}

function Save-SysPilotAiProviderEntry {
    <# Upsert eines Provider-Eintrags in ai-assist.json.
       -Entry: Hashtabelle aus dem Edit-Dialog; -OriginalName: beim
       Bearbeiten der bisherige Name (Umbennung moeglich). #>
    param([Parameter(Mandatory)]$Entry, [string]$OriginalName = '')
    $cfg = Read-SysPilotAiAssistConfig
    $cipher = ''
    if ($Entry.HasKeyInput) { $cipher = Protect-SysPilotSecret $Entry.ApiKey }
    elseif ($OriginalName) {
        $old = @($cfg.Providers | Where-Object { $_.Name -eq $OriginalName }) | Select-Object -First 1
        if ($old) { $cipher = [string]$old.ApiKeyCipher }
    }
    # Alt-Eintrag entfernen (Name oder OriginalName), Duplikate vermeiden
    $drop = @($OriginalName, $Entry.Name) | Where-Object { $_ }
    $cfg.Providers = @($cfg.Providers | Where-Object { $drop -notcontains $_.Name })
    $cfg.Providers = @($cfg.Providers) + @([pscustomobject]@{
        Name=$Entry.Name; BaseUrl=$Entry.BaseUrl; Model=$Entry.Model
        Kind=$Entry.Kind; Enabled=$Entry.Enabled; ApiKeyCipher=$cipher
    })
    Write-SysPilotAiAssistConfig $cfg
    Write-SysPilotLog "KI-Provider konfiguriert: $($Entry.Name) ($($Entry.BaseUrl))"
}

function Show-SysPilotAiSuggestionsWindow {
    param($Owner)
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase -ErrorAction SilentlyContinue
    <# WPF-Liste der kostenlosen Cloud-Tiers mit Signup-Links,
       Copy-Buttons und Ein-Klick-Anlegen. #>
    $sugg = @(Get-SysPilotAiProviderCatalog)
    $sxaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="SysPilot - Provider-Katalog" Width="680" Height="520"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResizeWithGrip"
        Background="#FF1E1E2E" Foreground="#FFE0E0E0">
  <Window.Resources>
    <Style TargetType="Button"><Setter Property="Background" Value="#FF2D2D44"/><Setter Property="Foreground" Value="#FFE0E0E0"/><Setter Property="BorderBrush" Value="#FF4A4A6A"/><Setter Property="Padding" Value="10,4"/><Setter Property="Margin" Value="3"/><Setter Property="Cursor" Value="Hand"/></Style>
    <Style TargetType="ListBoxItem"><Setter Property="Padding" Value="6,4"/><Setter Property="Foreground" Value="#FFEAEAF2"/><Setter Property="FontSize" Value="12"/><Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#FF34344E"/></Trigger><Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#CCE4EAF2"/><Setter Property="Foreground" Value="#FF1E1E2E"/></Trigger></Style.Triggers></Style>
  </Window.Resources>
  <DockPanel Margin="12">
    <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,8">
      <Button x:Name="BtnSignup" Content="Signup-Seite oeffnen" ToolTip="API-Key-Seite des Anbieters im Browser oeffnen"/>
      <Button x:Name="BtnCreate" Content="Provider anlegen" ToolTip="Anbieter eintragen - bei Key-Dateien wird der Key gleich mit importiert"/>
      <Button x:Name="BtnCreateKey" Content="Mit Key anlegen" ToolTip="Provider + API-Key aus der Key-Datei in einem Schritt"/>
      <Button x:Name="BtnCopyUrl" Content="URL kopieren"/>
      <Button x:Name="BtnCopyModel" Content="Modell kopieren"/>
      <Button x:Name="BtnClose" Content="Schliessen" HorizontalAlignment="Right"/>
    </StackPanel>
    <ListBox x:Name="SuggList" DockPanel.Dock="Left" Width="250" Margin="0,0,10,0" Background="#FF252538" BorderThickness="0"/>
    <Border Background="#FF252538" CornerRadius="6" Padding="10">
      <ScrollViewer VerticalScrollBarVisibility="Auto">
        <StackPanel>
          <TextBlock x:Name="SName" FontSize="16" FontWeight="Bold" Foreground="#FF4FC3F7" TextWrapping="Wrap"/>
          <TextBlock x:Name="SNote" FontSize="12" Foreground="#FFB0B0C0" Margin="0,4,0,8" TextWrapping="Wrap"/>
          <TextBlock Text="Base-URL:" FontSize="11" Foreground="#FF9E9E9E"/>
          <TextBox x:Name="SUrl" IsReadOnly="True" Margin="0,2,0,8" ToolTip="Rechtsklick = kopieren"/>
          <TextBlock Text="Modell:" FontSize="11" Foreground="#FF9E9E9E"/>
          <TextBox x:Name="SModel" IsReadOnly="True" ToolTip="Rechtsklick = kopieren"/>
          <TextBlock x:Name="SStatus" FontSize="11" Foreground="#FF7FBF7F" Margin="0,8,0,0" TextWrapping="Wrap"/>
        </StackPanel>
      </ScrollViewer>
    </Border>
  </DockPanel>
</Window>
"@
    $swin = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$sxaml)))
    if (Test-SysPilotWindowAlreadyOpen -Key 'syspilot-ai-suggestions' -Win $swin) { return }
    if ($Owner) { $swin.Owner = $Owner } else { $swin.WindowStartupLocation = 'CenterScreen' }
    $sc = @{}
    foreach ($n in 'SuggList','SName','SNote','SUrl','SModel','SStatus','BtnSignup','BtnCreate','BtnCreateKey','BtnCopyUrl','BtnCopyModel','BtnClose') {
        $sc[$n] = $swin.FindName($n)
    }
    foreach ($s in $sugg) {
        $tag = switch ($s.Source) { 'keyfile' { '[Key-Datei] ' } default { '' } }
        $keyMark = if ($s.HasKey) { ' *Key*' } else { '' }
        [void]$sc.SuggList.Items.Add("$tag$($s.Name)$keyMark")
    }
    $script:suggItems = $sugg
    $showSugg = {
        $i = $sc.SuggList.SelectedIndex
        if ($i -lt 0 -or $i -ge $sugg.Count) { return }
        $s = $sugg[$i]
        $sc.SName.Text = $s.Name
        $sc.SNote.Text = $s.Note
        $sc.SUrl.Text = $s.BaseUrl
        $sc.SModel.Text = $(if ($s.Model) { $s.Model } else { '(auto)' })
        $cfg = Read-SysPilotAiAssistConfig
        $exists = @($cfg.Providers | Where-Object { $_.BaseUrl -eq $s.BaseUrl }).Count -gt 0
        $keyTxt = $(if ($s.HasKey) { ' - API-Key vorhanden (aus Key-Datei)' } else { '' })
        $sc.SStatus.Text = $(if ($exists) { 'Bereits konfiguriert.' } else { "Nicht konfiguriert$keyTxt" })
    }
    $sc.SuggList.Add_SelectionChanged({ & $showSugg })
    $sc.BtnSignup.Add_Click({
        $i = $sc.SuggList.SelectedIndex
        if ($i -ge 0 -and $i -lt $sugg.Count) { Start-Process $sugg[$i].Signup }
    })
    $sc.BtnCopyUrl.Add_Click({
        $i = $sc.SuggList.SelectedIndex
        if ($i -ge 0 -and $i -lt $sugg.Count) { [Windows.Clipboard]::SetText($sugg[$i].BaseUrl) }
    })
    $sc.BtnCopyModel.Add_Click({
        $i = $sc.SuggList.SelectedIndex
        if ($i -ge 0 -and $i -lt $sugg.Count -and $sugg[$i].Model) { [Windows.Clipboard]::SetText($sugg[$i].Model) }
    })
    $doCreate = {
        param([bool]$withKey)
        $i = $sc.SuggList.SelectedIndex
        if ($i -lt 0 -or $i -ge $sugg.Count) { return }
        $s = $sugg[$i]
        $cfg = Read-SysPilotAiAssistConfig
        $exists = @($cfg.Providers | Where-Object { $_.BaseUrl -eq $s.BaseUrl }).Count -gt 0
        if ($exists) { $sc.SStatus.Text = 'Bereits konfiguriert.'; return }
        $cipher = ''
        if ($withKey -and $s.HasKey -and $s.ApiKey) { $cipher = Protect-SysPilotSecret $s.ApiKey }
        $cfg.Providers = @($cfg.Providers) + @([pscustomobject]@{
            Name=$s.Name; BaseUrl=$s.BaseUrl; Model=$s.Model; Kind='cloud'
            Enabled=$true; ApiKeyCipher=$cipher
        })
        Write-SysPilotAiAssistConfig $cfg
        Write-SysPilotLog "KI-Provider angelegt: $($s.Name)$(if($cipher){' (mit Key)'})"
        $sc.SStatus.Text = $(if ($cipher) { 'Angelegt - MIT API-Key. Sofort nutzbar!' } else { 'Angelegt - Key jetzt ueber "Provider bearbeiten" eintragen.' })
    }
    $sc.BtnCreate.Add_Click({ & $doCreate $false })
    $sc.BtnCreateKey.Add_Click({
        $i = $sc.SuggList.SelectedIndex
        if ($i -ge 0 -and $i -lt $sugg.Count -and -not $sugg[$i].HasKey) {
            $sc.SStatus.Text = 'Kein Key in der Datei - bitte "Provider anlegen" und Key manuell eintragen.'
            return
        }
        & $doCreate $true
    })
    $sc.BtnClose.Add_Click({ $swin.Close() })
    if ($sugg.Count -gt 0) { $sc.SuggList.SelectedIndex = 0 }
    Set-SysPilotWindowAutoSize -Win $swin -MinWidth 720 -MinHeight 480
    $swin.ShowDialog() | Out-Null
}

function Show-SysPilotAiProvidersWindow {
    param($Owner)
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase -ErrorAction SilentlyContinue
    <# WPF-Provider-Verwaltung: Liste, Details, Test, Bearbeiten,
       An/Aus, Entfernen, Hinzufuegen, Vorschlaege, Key-Backup. #>
    $pxaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="SysPilot - KI-Provider (Pilot Herbert)" Width="700" Height="560"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResizeWithGrip"
        Background="#FF1E1E2E" Foreground="#FFE0E0E0">
  <Window.Resources>
    <Style TargetType="Button"><Setter Property="Background" Value="#FF2D2D44"/><Setter Property="Foreground" Value="#FFE0E0E0"/><Setter Property="BorderBrush" Value="#FF4A4A6A"/><Setter Property="Padding" Value="10,4"/><Setter Property="Margin" Value="3"/><Setter Property="Cursor" Value="Hand"/></Style>
    <Style TargetType="ListBoxItem"><Setter Property="Padding" Value="6,4"/><Setter Property="Foreground" Value="#FFEAEAF2"/><Setter Property="FontSize" Value="12"/><Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#FF34344E"/></Trigger><Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#CCE4EAF2"/><Setter Property="Foreground" Value="#FF1E1E2E"/></Trigger></Style.Triggers></Style>
    <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#FFE0E0E0"/></Style>
  </Window.Resources>
  <DockPanel Margin="12">
    <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,8">
      <Button x:Name="BtnAdd" Content="+ Provider" ToolTip="Eigenen Endpoint + Key anlegen"/>
      <Button x:Name="BtnSuggest" Content="? Provider-Katalog" ToolTip="Katalog aus ca. 25 kuratierten Anbietern + deinen Key-Dateien (Get-API-Key-Links, 1-Klick-Import)"/>
      <Button x:Name="BtnModel" Content="Modelle" ToolTip="Modelle des Providers anzeigen und eines waehlen (z.B. Ollama)"/>
      <Button x:Name="BtnIo" Content="Import/Export" ToolTip="CSV/JSON exportieren, Key-Ordner + Router-Configs (OmniRoute, FreeLLMAPI) importieren"/>
      <Button x:Name="BtnClean" Content="Bereinigen" ToolTip="Alle Provider testen und unbrauchbare deaktivieren"/>
      <Button x:Name="BtnBackup" Content="Keys sichern" ToolTip="API-Keys als .txt nach Dokumente\api keys exportieren"/>
      <Button x:Name="BtnRefresh" Content="Aktualisieren"/>
      <Button x:Name="BtnClose" Content="Schliessen" HorizontalAlignment="Right"/>
    </StackPanel>
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="300"/><ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <ListBox x:Name="ProviderList" Background="#FF252538" BorderThickness="0"/>
      <Border Grid.Column="1" Background="#FF252538" CornerRadius="6" Padding="12" Margin="10,0,0,0">
        <DockPanel>
          <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,10,0,0">
            <Button x:Name="BtnTest" Content="Testen" ToolTip="GET /models - Prueft Endpoint + Key"/>
            <Button x:Name="BtnEdit" Content="Bearbeiten"/>
            <Button x:Name="BtnToggle" Content="An/Aus"/>
            <Button x:Name="BtnDelete" Content="Entfernen" ToolTip="Nur konfigurierte Provider"/>
          </StackPanel>
          <StackPanel>
            <TextBlock x:Name="DName" FontSize="17" FontWeight="Bold" Foreground="#FF4FC3F7" TextWrapping="Wrap"/>
            <TextBlock x:Name="DKind" FontSize="11" Foreground="#FF9E9E9E" Margin="0,2,0,10"/>
            <TextBlock Text="Endpoint:" FontSize="11" Foreground="#FF9E9E9E"/>
            <TextBox x:Name="DUrl" IsReadOnly="True" Margin="0,2,0,8" ToolTip="Rechtsklick = kopieren"/>
            <TextBlock Text="Modell:" FontSize="11" Foreground="#FF9E9E9E"/>
            <TextBox x:Name="DModel" IsReadOnly="True" Margin="0,2,0,8" ToolTip="Rechtsklick = kopieren"/>
            <TextBlock Text="API-Key:" FontSize="11" Foreground="#FF9E9E9E"/>
            <TextBox x:Name="DKey" IsReadOnly="True" Margin="0,2,0,8" ToolTip="Key ist DPAPI-verschluesselt und wird nie angezeigt"/>
            <TextBlock x:Name="DStatus" FontSize="12" Foreground="#FFB0B0C0" TextWrapping="Wrap"/>
          </StackPanel>
        </DockPanel>
      </Border>
    </Grid>
    <TextBlock x:Name="StatusText" DockPanel.Dock="Bottom" FontSize="11" Foreground="#FF9E9E9E" Margin="0,8,0,0" TextWrapping="Wrap"/>
  </DockPanel>
</Window>
"@
    $pwin = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$pxaml)))
    if (Test-SysPilotWindowAlreadyOpen -Key 'syspilot-ai-providers' -Win $pwin) { return }
    if ($Owner) { $pwin.Owner = $Owner } else { $pwin.WindowStartupLocation = 'CenterScreen' }
    $pc = @{}
    foreach ($n in 'ProviderList','DName','DKind','DUrl','DModel','DKey','DStatus','BtnAdd','BtnSuggest','BtnBackup','BtnRefresh','BtnClose','BtnTest','BtnEdit','BtnToggle','BtnDelete','StatusText','BtnModel','BtnIo','BtnClean') {
        $pc[$n] = $pwin.FindName($n)
    }
    $script:aiProvItems = @()
    $setStatus = { param($t, $col) $pc.StatusText.Text = $t; $pc.StatusText.Foreground = [Windows.Media.BrushConverter]::new().ConvertFrom($col) }

    $loadProviders = {
        $items = @(Get-SysPilotAiProviders)
        $script:aiProvItems = $items
        $pc.ProviderList.Items.Clear()
        foreach ($p in $items) {
            $kind = switch ($p.Kind) { 'local' { '[lokal]' } 'free' { '[free]' } default { '[cloud]' } }
            $key = if ($p.ApiKey) { 'Key:Set' } else { 'Key:-' }
            $en = if ($p.Enabled) { '' } else { ' (aus)' }
            [void]$pc.ProviderList.Items.Add("$kind $($p.Name)  $key$en")
        }
        if ($pc.ProviderList.Items.Count -gt 0 -and $pc.ProviderList.SelectedIndex -lt 0) { $pc.ProviderList.SelectedIndex = 0 }
    }

    $showDetails = {
        $i = $pc.ProviderList.SelectedIndex
        if ($i -lt 0 -or $i -ge $script:aiProvItems.Count) {
            $pc.DName.Text=''; $pc.DKind.Text=''; $pc.DUrl.Text=''; $pc.DModel.Text=''; $pc.DKey.Text=''; $pc.DStatus.Text=''
            return
        }
        $p = $script:aiProvItems[$i]
        $pc.DName.Text = $p.Name
        $pc.DKind.Text = "$($p.Kind) - $(if($p.Configured){'konfiguriert'}else{'eingebaut'}$(if($p.Enabled){''}{', deaktiviert'}))"
        $pc.DUrl.Text = $p.BaseUrl
        $pc.DModel.Text = $(if ($p.Model) { $p.Model } else { '(auto)' })
        $pc.DKey.Text = $(if ($p.ApiKey) { 'gesetzt (DPAPI)' } else { '-' })
        $st = @()
        # KEIN synchroner /models-Test hier - 15s Timeout wuerde den
        # UI-Thread pro Auswahl blockieren (gefuhlter Fenster-Haenger).
        # Test laeuft bewusst nur per BtnTest-Klick.
        if ($p.Kind -eq 'local' -or $p.Configured) { $st += 'Test: [Testen]-Button druecken' }
        if ($p.Name -eq 'Pollinations (free)') { $st += 'Kostenloser Fallback - Rate-Limit moeglich.' }
        $pc.DStatus.Text = ($st -join "`n")
        $pc.BtnDelete.IsEnabled = [bool]$p.Configured
        $pc.BtnEdit.IsEnabled = [bool]$p.Configured
    }

    $pc.ProviderList.Add_SelectionChanged({ & $showDetails })
    $pc.BtnRefresh.Add_Click({ & $loadProviders; & $showDetails })
    $pc.BtnClose.Add_Click({ $pwin.Close() })
    $pc.BtnAdd.Add_Click({
        $e = Show-SysPilotAiProviderEditDialog -Owner $Owner
        if ($e) { Save-SysPilotAiProviderEntry -Entry $e; & $loadProviders; & $showDetails }
    })
    $pc.BtnEdit.Add_Click({
        $i = $pc.ProviderList.SelectedIndex
        if ($i -lt 0 -or $i -ge $script:aiProvItems.Count) { return }
        $p = $script:aiProvItems[$i]
        if (-not $p.Configured) { return }
        $e = Show-SysPilotAiProviderEditDialog -Provider $p -OriginalName $p.Name -Owner $Owner
        if ($e) { Save-SysPilotAiProviderEntry -Entry $e -OriginalName $p.Name; & $loadProviders; & $showDetails }
    })
    $pc.BtnToggle.Add_Click({
        $i = $pc.ProviderList.SelectedIndex
        if ($i -lt 0 -or $i -ge $script:aiProvItems.Count) { return }
        $p = $script:aiProvItems[$i]
        if (-not $p.Configured) { & $setStatus 'Eingebaute Provider koennen nicht deaktiviert werden.' '#FFFFB74D'; return }
        $cfg = Read-SysPilotAiAssistConfig
        foreach ($cp in @($cfg.Providers)) {
            if ($cp.Name -eq $p.Name) {
                $cp | Add-Member -NotePropertyName Enabled -NotePropertyValue (-not ($null -eq $cp.Enabled -or $cp.Enabled -eq $true)) -Force
            }
        }
        Write-SysPilotAiAssistConfig $cfg
        & $loadProviders; & $showDetails
    })
    $pc.BtnDelete.Add_Click({
        $i = $pc.ProviderList.SelectedIndex
        if ($i -lt 0 -or $i -ge $script:aiProvItems.Count) { return }
        $p = $script:aiProvItems[$i]
        if (-not $p.Configured) { return }
        $r = [System.Windows.MessageBox]::Show("Provider '$($p.Name)' wirklich entfernen?`n(Der API-Key bleibt in alten Backups moeglicherweise gespeichert.)", 'KI-Provider', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { return }
        $cfg = Read-SysPilotAiAssistConfig
        $cfg.Providers = @($cfg.Providers | Where-Object { $_.Name -ne $p.Name })
        Write-SysPilotAiAssistConfig $cfg
        Write-SysPilotLog "KI-Provider entfernt: $($p.Name)"
        & $loadProviders; & $showDetails
    })
    $pc.BtnTest.Add_Click({
        $i = $pc.ProviderList.SelectedIndex
        if ($i -lt 0 -or $i -ge $script:aiProvItems.Count) { return }
        $p = $script:aiProvItems[$i]
        $pc.StatusText.Text = "Teste $($p.Name) ..."
        $pc.StatusText.Foreground = [Windows.Media.BrushConverter]::new().ConvertFrom('#FF9E9E9E')
        $t = Test-SysPilotAiProvider -Provider $p -TimeoutSec 8
        if ($t.Ok) { & $setStatus "[OK] $($p.Name): $($t.Models) Modelle" '#FF7FBF7F' }
        else { & $setStatus "[!] $($p.Name): $($t.Error)" '#FFFF8A80' }
        & $showDetails
    })
    $pc.BtnSuggest.Add_Click({ Show-SysPilotAiSuggestionsWindow -Owner $Owner; & $loadProviders })
    $pc.BtnModel.Add_Click({
        $i = $pc.ProviderList.SelectedIndex
        if ($i -lt 0 -or $i -ge $script:aiProvItems.Count) { & $setStatus 'Kein Provider markiert.' '#FFFFB74D'; return }
        $p = $script:aiProvItems[$i]
        & $setStatus "Lade Modelle von $($p.Name) ..." '#FF9E9E9E'
        # Gleiche Picker-Mechanik wie im Konsolen-Detailmenue
        # (WPF-Pfeilmenue mit allen Modellen + Context-Anzeige)
        [void](Select-SysPilotAiProviderModel -Provider $p)
        & $loadProviders; & $showDetails
    })
    $pc.BtnIo.Add_Click({
        try { Show-SysPilotAiImportExportMenu } catch { & $setStatus "Import/Export: $($_.Exception.Message)" '#FFFF8A80' }
        & $loadProviders
    })
    $pc.BtnClean.Add_Click({
        & $setStatus 'Teste alle Provider ...' '#FF9E9E9E'
        $r = Invoke-SysPilotAiProviderCleanup
        foreach ($ln in @($r.Report | Select-Object -Last 8)) { & $setStatus $ln '#FFB0B0C0' }
        & $setStatus "Bereinigt: $($r.Tested) getestet, $($r.Disabled.Count) deaktiviert" $(if($r.Disabled.Count){'#FFFFB74D'}else{'#FF7FBF7F'})
        & $loadProviders; & $showDetails
    })
    $pc.BtnBackup.Add_Click({
        $n = Save-SysPilotAiKeyBackup -Quiet
        $dir = Get-SysPilotAiKeyBackupDir
        if ($n -gt 0) { & $setStatus "$n Key-Backup(s) exportiert nach $dir" '#FF7FBF7F' }
        else { & $setStatus 'Keine Provider mit API-Key konfiguriert.' '#FFFFB74D' }
    })

    & $loadProviders
    & $showDetails
    Set-SysPilotWindowAutoSize -Win $pwin -MinWidth 860 -MinHeight 540
    Add-SysPilotAssistantToWindow -Win $pwin -Context 'Show-SysPilotAiProvidersWindow'
    $pwin.ShowDialog() | Out-Null
}

# === Herbert Chat-Verlauf (persistent, JSON pro Chat) ===
function Get-SysPilotHerbertChatDir {
    $d = Join-Path $env:LOCALAPPDATA 'SysPilot\herbert-chats'
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    return $d
}

function Save-SysPilotHerbertChat {
    <# Speichert einen Chat als JSON. $Messages = @{role;content}-Paare. #>
    param([Parameter(Mandatory)][string]$Id, [string]$Title = '',
          [Parameter(Mandatory)][object[]]$Messages, [string]$Created = '')
    if (-not $Created) { $Created = (Get-Date).ToString('o') }
    if (-not $Title) {
        $firstUser = @($Messages | Where-Object { $_.role -eq 'user' } | Select-Object -First 1)
        if ($firstUser.Count) { $Title = [string]$firstUser[0].content; if ($Title.Length -gt 60) { $Title = $Title.Substring(0,60)+'...' } }
        if (-not $Title) { $Title = 'Chat' }
    }
    $obj = [ordered]@{
        Id = $Id; Title = $Title; Created = $Created
        Updated = (Get-Date).ToString('o'); Messages = @($Messages)
    }
    $dir = Get-SysPilotHerbertChatDir
    ($obj | ConvertTo-Json -Depth 8) | Set-Content (Join-Path $dir "$Id.json") -Encoding UTF8
    return Join-Path $dir "$Id.json"
}

function Get-SysPilotHerbertChats {
    <# Liste aller gespeicherten Chats (neueste zuerst). #>
    $dir = Get-SysPilotHerbertChatDir
    $out = @()
    foreach ($f in (Get-ChildItem $dir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        try {
            $j = Get-Content $f.FullName -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
            $out += [pscustomobject]@{
                Id = [string]$j.Id; Title = [string]$j.Title
                Created = [string]$j.Created; Updated = [datetime]$j.Updated
                Count = @($j.Messages).Count
            }
        } catch {}
    }
    return @($out | Sort-Object Updated -Descending)
}

function Read-SysPilotHerbertChat {
    param([Parameter(Mandatory)][string]$Id)
    $f = Join-Path (Get-SysPilotHerbertChatDir) "$Id.json"
    if (-not (Test-Path $f)) { return $null }
    try { return (Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Remove-SysPilotHerbertChat {
    param([Parameter(Mandatory)][string]$Id)
    $f = Join-Path (Get-SysPilotHerbertChatDir) "$Id.json"
    if (Test-Path $f) { Remove-Item $f -Force; return $true }
    return $false
}

function Get-SysPilotHerbertFullscreen {
    <# Konfigurierbarer Vollbild-Modus fuer den Herbert-Assistenten
       (config.json -> Herbert.Fullscreen). #>
    try {
        $cfg = Get-SysPilotConfig
        $sec = $cfg.PSObject.Properties['Herbert']
        if ($sec -and $sec.Value -and $sec.Value.PSObject.Properties['Fullscreen']) {
            return [bool]$sec.Value.Fullscreen
        }
    } catch {}
    return $false
}

function Set-SysPilotHerbertFullscreen {
    <# Setzt den Vollbild-Modus (persistent in config.json). #>
    param([Parameter(Mandatory)][bool]$Enabled)
    try { Set-SysPilotConfigValue -Section 'Herbert' -Key 'Fullscreen' -Value ([bool]$Enabled) } catch {}
    try { Write-SysPilotLog ("Herbert-Vollbildmodus: " + $(if($Enabled){'an'}else{'aus'})) } catch {}
}

function Show-SysPilotHerbertAssistant {
    <# Schwebender Herbert-Assistent (WPF):-Fenster, das sich
       rechts vom aufrufenden Fenster positioniert. Mit Kontext,
       Schnellfragen und <<<AKTION:>>>-Uebernehmen-Buttons.
       Kann aus jedem Tool-Fenster aufgerufen werden:
       Show-SysPilotHerbertAssistant -Owner $win -Context 'SmartDriver Studio' #>
    param(
        [string]$Context = '',
        $Owner = $null,
        [string[]]$Suggestions = @(),
        [string]$Title = 'Pilot Herbert - Bordassistent',
        [switch]$Fullscreen
    )
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
        Write-Warning 'Show-SysPilotHerbertAssistant braucht STA.'
        return $false
    }
    # Persistenter Vollbild-Modus (config.json -> Herbert.Fullscreen)
    # kann den -Fullscreen-Switch ergaenzen, nicht aufheben.
    $fsMode = [bool]$Fullscreen -or (Get-SysPilotHerbertFullscreen)
    try {
        [void][reflection.assembly]::LoadWithPartialName('PresentationFramework')
        [void][reflection.assembly]::LoadWithPartialName('PresentationCore')
        [void][reflection.assembly]::LoadWithPartialName('WindowsBase')
    } catch {}

    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$Title" Width="$(if($fsMode){'1280'}else{'400'})" Height="$(if($fsMode){'800'}else{'620'})" WindowStartupLocation="Manual"
        Background="#FF1E1E2E" Foreground="#FFEAEAF2" FontFamily="Segoe UI"
        Topmost="True" ShowInTaskbar="False" ResizeMode="CanResizeWithGrip">
  <Window.Resources>
    <Style TargetType="Button"><Setter Property="Background" Value="#FF2D2D44"/><Setter Property="Foreground" Value="#FFEAEAF2"/><Setter Property="BorderBrush" Value="#FF4A4A6A"/><Setter Property="Padding" Value="8,3"/><Setter Property="Margin" Value="2"/><Setter Property="Cursor" Value="Hand"/><Setter Property="FontSize" Value="11"/></Style>
    <Style TargetType="TextBox"><Setter Property="Background" Value="#FF252538"/><Setter Property="Foreground" Value="#FFEAEAF2"/><Setter Property="BorderBrush" Value="#FF4A4A6A"/><Setter Property="Padding" Value="6,4"/></Style>
    <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#FFEAEAF2"/></Style>
    <Style TargetType="ListBoxItem">
      <Setter Property="Padding" Value="6,4"/>
      <Setter Property="Foreground" Value="#FFEAEAF2"/>
      <Setter Property="FontSize" Value="10"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#FF34344E"/></Trigger>
        <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#CCE4EAF2"/><Setter Property="Foreground" Value="#FF1E1E2E"/></Trigger>
      </Style.Triggers>
    </Style>
    <ControlTemplate x:Key="ComboDarkToggle" TargetType="ToggleButton">
      <Border x:Name="Bg" Background="#FF252538" BorderBrush="#FF4A4A6A" BorderThickness="1" CornerRadius="2"/>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="BorderBrush" Value="#FF4FC3F7"/></Trigger>
        <Trigger Property="IsChecked" Value="True"><Setter Property="BorderBrush" Value="#FF4FC3F7"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate>
    <Style TargetType="ComboBox">
      <Setter Property="Background" Value="#FF252538"/><Setter Property="Foreground" Value="#FFEAEAF2"/>
      <Setter Property="BorderBrush" Value="#FF4A4A6A"/><Setter Property="Padding" Value="6,3"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton x:Name="ToggleButton" Focusable="False" ClickMode="Press"
                Template="{StaticResource ComboDarkToggle}"
                IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"/>
              <ContentPresenter x:Name="ContentSite" IsHitTestVisible="False"
                Content="{TemplateBinding SelectionBoxItem}"
                ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                ContentTemplateSelector="{TemplateBinding ItemTemplateSelector}"
                Margin="8,0,24,0" VerticalAlignment="Center" HorizontalAlignment="Left"/>
              <Path Data="M 0 0 L 4 4 L 8 0 Z" Fill="#FF9E9E9E" Width="8" Height="4"
                    HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,10,0"/>
              <Popup x:Name="Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}"
                     AllowsTransparency="True" Focusable="False" PopupAnimation="Slide">
                <Border Background="#FF1E1E2E" BorderBrush="#FF4A4A6A" BorderThickness="1"
                        MinWidth="{TemplateBinding ActualWidth}" MaxHeight="320">
                  <ScrollViewer>
                    <ItemsPresenter/>
                  </ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.55"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="#FFEAEAF2"/><Setter Property="Background" Value="Transparent"/>
      <Setter Property="Padding" Value="8,4"/>
      <Style.Triggers>
        <Trigger Property="IsHighlighted" Value="True"><Setter Property="Background" Value="#FF34344E"/><Setter Property="Foreground" Value="#FFEAEAF2"/></Trigger>
        <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#CCE4EAF2"/><Setter Property="Foreground" Value="#FF1E1E2E"/></Trigger>
      </Style.Triggers>
    </Style>
  </Window.Resources>
  <DockPanel Margin="10">
    <StackPanel DockPanel.Dock="Top" Margin="0,0,0,8">
      <TextBlock Text="Pilot Herbert" FontSize="16" FontWeight="Bold" Foreground="#FF4FC3F7"/>
      <TextBlock x:Name="TxtCtx" FontSize="10" Foreground="#FF9CCC65" TextWrapping="Wrap" Margin="0,2,0,0"/>
      <WrapPanel Margin="0,6,0,0">
        <Button x:Name="BtnNewChat" Content="+ Neu" ToolTip="Neuen Chat starten (Verlauf wird gespeichert, nicht geloescht)"/>
        <Button x:Name="BtnManager" Content="Manager" ToolTip="Skills (skills.sh) + MCP-Konnektoren verwalten"/>
        <Button x:Name="BtnPerm" Content="Perm" ToolTip="Permissions: Modus (Fragen/Auto-allow/Bypass) + Overrides pro Aktion/MCP-Werkzeug"/>
        <Button x:Name="BtnExt" Content="MCP/Skills" ToolTip="Installierte MCP-Server + Skills im Ueberblick, Katalog oeffnen"/>
        <Button x:Name="BtnFs" Content="Vollbild" ToolTip="Vollbild-Modus an/aus (wird gespeichert - auch beim naechsten Start)"/>
        <TextBlock Text="Provider:" VerticalAlignment="Center" Foreground="#FF9E9E9E" FontSize="11" Margin="10,0,4,0"/>
        <ComboBox x:Name="CmbProvider" Width="215" VerticalAlignment="Center" ToolTip="KI-Provider waehlen (Auto = Fallback-Kette ueber alle)"/>
        <TextBlock Text="Modell:" VerticalAlignment="Center" Foreground="#FF9E9E9E" FontSize="11" Margin="10,0,4,0"/>
        <ComboBox x:Name="CmbModel" Width="240" VerticalAlignment="Center" IsEditable="True" ToolTip="Modell des Providers (leer = automatisch)"/>
      </WrapPanel>
    </StackPanel>
    <StackPanel DockPanel.Dock="Bottom" Margin="0,8,0,0">
      <TextBox x:Name="TxtInput" ToolTip="Enter = senden, Strg+V = Bild aus Zwischenablage anhaengen (Vision-Modelle)"/>
      <Button x:Name="BtnSend" Content="Senden" Margin="0,6,0,0"/>
      <TextBlock x:Name="TxtStatus" FontSize="10" Foreground="#FF9E9E9E" Margin="0,2,0,0" Text="bereit"/>
    </StackPanel>
    <Border x:Name="SideBar" DockPanel.Dock="Left" Width="190" Margin="0,0,10,0"
            Background="#FF1A1A28" CornerRadius="8" Padding="10" Visibility="Collapsed">
      <DockPanel>
        <StackPanel DockPanel.Dock="Top">
          <TextBlock Text="HERBERT" FontWeight="Bold" Foreground="#FF4FC3F7" FontSize="14" Margin="0,0,0,8"/>
          <Button x:Name="BtnSideProviders" Content="Provider verwalten" FontSize="11" Margin="0,0,0,4"
                  ToolTip="Keys, Endpoints, kostenlose Anbieter"/>
          <Button x:Name="BtnSideSuggest" Content="Provider-Vorschlaege" FontSize="11" Margin="0,0,0,4"
                  ToolTip="Kostenlose KI-Anbieter zum Abklappern"/>
          <Button x:Name="BtnSideManager" Content="Skills + Konnektoren" FontSize="11" Margin="0,0,0,4"
                  ToolTip="Herbert-Manager (skills.sh + MCP)"/>
          <Button x:Name="BtnSidePerm" Content="Permissions" FontSize="11" Margin="0,0,0,4"
                  ToolTip="Modus + Overrides fuer Aktionen und MCP-Werkzeuge"/>
          <Button x:Name="BtnSideExt" Content="Installierte MCP + Skills" FontSize="11" Margin="0,0,0,4"
                  ToolTip="Ueberblick + Katalog oeffnen"/>
          <Button x:Name="BtnSideNew" Content="+ Neuer Chat" FontSize="11" Margin="0,0,0,8"/>
          <TextBlock Text="CHATS" FontWeight="Bold" Foreground="#FF9E9E9E" FontSize="10" Margin="0,0,0,4"/>
        </StackPanel>
        <StackPanel DockPanel.Dock="Bottom" Margin="0,6,0,0">
          <Separator Margin="0,0,0,6" Background="#FF4A4A6A"/>
          <TextBlock Text="STATUS" FontWeight="Bold" Foreground="#FF9E9E9E" FontSize="10" Margin="0,0,0,4"/>
          <TextBlock x:Name="TxtSideStatus" FontSize="10" Foreground="#FFB0B0C0" TextWrapping="Wrap"/>
        </StackPanel>
        <ListBox x:Name="LstChats" Background="#FF14141E" Foreground="#FFEAEAF2"
                 BorderThickness="0" FontSize="10" Margin="0,0,0,0"
                 ToolTip="Klick = alten Chat laden | Entf = Chat loeschen"/>
      </DockPanel>
    </Border>
    <Border Background="#FF14141E" CornerRadius="6" Padding="8">
      <DockPanel>
        <ScrollViewer x:Name="ChatScroll" VerticalScrollBarVisibility="Auto">
          <RichTextBox x:Name="ChatBox" IsReadOnly="True" Background="Transparent" BorderThickness="0"
                       Foreground="#FFEAEAF2" FontFamily="Segoe UI" FontSize="12"
                       VerticalScrollBarVisibility="Disabled" HorizontalScrollBarVisibility="Disabled"/>
        </ScrollViewer>
      </DockPanel>
    </Border>
  </DockPanel>
</Window>
"@
    # KeyDown-Handler kann in XAML nicht mit Scriptblock - daher Tell-gesteuert:
    # TextBox-KeyDown wird unten per Add_KeyDown verdaeckt (XAML-Attribut 'Ignored' ist nur
    # Platzhalter; wir entfernen ihn vor dem Load)
    $xaml = $xaml -replace ' KeyDown="Ignored"', ''
    $win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$xaml)))
    if (Test-SysPilotWindowAlreadyOpen -Key 'syspilot-ai-chat' -Win $win) { return }

    # Rechts vom Owner-Fenster positionieren, ohne Ueberlappung:
    # Reihenfolge rechts -> links -> unterhalb -> Bildschirmmitte.
    # Immer komplett innerhalb der Workarea (falls moeglich).
    $wa = [Windows.SystemParameters]::WorkArea
    $placed = $false
    if ($Owner) {
        try {
            $ow = [Math]::Max(100, [double]$Owner.Width); $oh = [Math]::Max(100, [double]$Owner.Height)
            $cands = @(
                @{ L = $Owner.Left + $ow + 10; T = $Owner.Top },
                @{ L = $Owner.Left - $win.Width - 10; T = $Owner.Top },
                @{ L = $Owner.Left; T = $Owner.Top + $oh + 10 },
                @{ L = $Owner.Left + [Math]::Max(0,($ow - $win.Width)/2); T = $Owner.Top + $oh + 10 }
            )
            foreach ($c in $cands) {
                $L = [Math]::Max($wa.Left + 4, [Math]::Min([double]$c.L, $wa.Right - $win.Width - 4))
                $T = [Math]::Max($wa.Top + 4, [Math]::Min([double]$c.T, $wa.Bottom - $win.Height - 4))
                # Ueberlappung mit Owner pruefen (10px Toleranz)
                $overlap = ($L -lt ($Owner.Left + $ow - 10)) -and (($L + $win.Width) -gt ($Owner.Left + 10)) -and
                           ($T -lt ($Owner.Top + $oh - 10)) -and (($T + $win.Height) -gt ($Owner.Top + 10))
                if (-not $overlap) { $win.Left=$L; $win.Top=$T; $placed=$true; break }
            }
            if (-not $placed) {
                # Alles belegt: rechts buendig an Owner, vertikal zentriert
                $win.Left = [Math]::Max($wa.Left + 4, [Math]::Min($Owner.Left + $ow + 10, $wa.Right - $win.Width - 4))
                $win.Top  = [Math]::Max($wa.Top + 4, [Math]::Min($Owner.Top + ($oh - $win.Height)/2, $wa.Bottom - $win.Height - 4))
            }
            $win.Owner = $Owner
        } catch {}
    }
    if (-not $win.Owner) { $win.WindowStartupLocation='CenterScreen' }
    try { $win.MaxHeight = [Math]::Max(200, $wa.Height - 16); $win.MaxWidth = [Math]::Max(200, $wa.Width - 16) } catch {}
    # Vordergrund holen (eigener Topmost-Puls beim Oeffnen)
    try { Set-SysPilotWindowForeground -Win $win } catch {}

    # Kontext lesbar machen: 'Show-SysPilotDnsWindow' -> 'DNS-Manager'-Style
    $ctxLabel = "$Context".Trim()
    if ($ctxLabel -match '^Show-SysPilot(.+)$') {
        $raw = $Matches[1] -replace 'Window$',''
        $words = [regex]::Matches($raw,'[A-Z]+(?![a-z])|[A-Z][a-z0-9]*|[a-z0-9]+') | ForEach-Object { $_.Value }
        $ctxLabel = ($words -join ' ')
        $ctxLabel = $ctxLabel.Substring(0,1).ToUpper() + $ctxLabel.Substring(1)
    }
    $ctxLabel = $ctxLabel -replace '\bDns\b','DNS' -replace '\bAi\b','KI' -replace '\bGui\b','GUI' -replace '\bWpf\b','WPF' -replace '\bUsb\b','USB' -replace '\bId\b','ID'
    if (-not $ctxLabel) { $ctxLabel = 'SysPilot' }

    $fc = @{}
    foreach ($n in 'TxtCtx','TxtInput','BtnSend','ChatBox','ChatScroll','BtnNewChat','BtnManager','BtnPerm','BtnExt','CmbProvider','CmbModel','TxtStatus','SideBar','BtnSideProviders','BtnSideSuggest','BtnSideManager','BtnSidePerm','BtnSideExt','BtnSideNew','TxtSideStatus','LstChats') { $fc[$n] = $win.FindName($n) }
    $fc.TxtCtx.Text = "Kontext: $ctxLabel"

    # --- Provider-/Modell-Auswahl ---
    # Alle aktiven Provider + lokale Presets auch dann anzeigen, wenn
    # der Port gerade zu ist (marker '(Port zu?)' - Fallback-Kette
    # fingert den Ausfall ab, direkter Aufruf zeigt klare Fehlermeldung).
    $provList = @()
    try {
        $seenNames = @{}
        foreach ($p in @(Get-SysPilotAiProviders | Where-Object { $_.Enabled })) {
            $provList += [pscustomobject]@{ Name=$p.Name; Label=$p.Name; Prov=$p }
            $seenNames[$p.Name.ToLower()] = $true
        }
        foreach ($d in @(Get-SysPilotAiProviderDefaults)) {
            if (-not $seenNames.ContainsKey($d.Name.ToLower())) {
                $provList += [pscustomobject]@{ Name=$d.Name; Label="$($d.Name) (Port zu?)"; Prov=$null }
            }
        }
    } catch { $provList = @() }
    $provList = @([pscustomobject]@{ Name=''; Label='Auto (Fallback-Kette)'; Prov=$null }) + @($provList)
    $fc.CmbProvider.DisplayMemberPath = 'Label'
    $fc.CmbProvider.ItemsSource = $provList
    $fc.CmbProvider.SelectedIndex = 0
    # Geteilte Auswahl (Panel <-> Fenster) wiederherstellen
    try {
        $last = Get-SysPilotAiLastSelection
        if ($last.Provider) {
            $hit = @($fc.CmbProvider.Items | Where-Object { $_.Name -eq $last.Provider } | Select-Object -First 1)
            if ($hit.Count -gt 0) { $fc.CmbProvider.SelectedItem = $hit[0] }
            if ($last.Model) { $script:_herbPendingModel = $last.Model }
        }
    } catch {}

    $script:_herbMdlJob = $null; $script:_herbMdlTimer = $null
    $loadModelsForProvider = {
        param($provObj)
        $fc.CmbModel.ItemsSource = @()
        if (-not $provObj) { return }
        $script:_herbMdlJob = Start-Job -ScriptBlock {
            param($modDir, $p)
            Import-Module (Join-Path $modDir 'Common.psm1') -Force -WarningAction SilentlyContinue
            Import-Module (Join-Path $modDir 'AiAssist.psm1') -Force -WarningAction SilentlyContinue
            $pr = [pscustomobject]@{ Name=$p.Name; BaseUrl=$p.BaseUrl; Model=$p.Model; ApiKey=$p.ApiKey; Kind=$p.Kind }
            $r = Get-SysPilotAiProviderModels -Provider $pr -TimeoutSec 12
            foreach ($m in @($r.Models)) { Write-Output $m.Id }
            if ($r.Models.Count -eq 0 -and $pr.Model) { Write-Output $pr.Model }
        } -ArgumentList $modDir, $provObj.Prov
        $script:_herbMdlTimer = New-Object Windows.Threading.DispatcherTimer
        $script:_herbMdlTimer.Interval = [TimeSpan]::FromMilliseconds(700)
        $script:_herbMdlTimer.Add_Tick({
            if ($script:_herbMdlJob.State -eq 'Running') { return }
            $script:_herbMdlTimer.Stop()
            try {
                $ids = @(Receive-Job $script:_herbMdlJob -ErrorAction Stop)
                $fc.CmbModel.ItemsSource = $ids
                if ($ids.Count -gt 0) {
                    $pref = @($ids | Where-Object { $_ -match '(?i)free|mini|flash|small|8b|7b|instruct' } | Select-Object -First 1)
                    $fc.CmbModel.Text = $(if ($pref) { $pref } else { $ids[0] })
                }
                if ($script:_herbPendingModel) { $fc.CmbModel.Text = $script:_herbPendingModel; $script:_herbPendingModel = $null }
            } catch {}
            Remove-Job $script:_herbMdlJob -Force -ErrorAction SilentlyContinue
        })
        $script:_herbMdlTimer.Start()
    }
    $fc.CmbProvider.Add_SelectionChanged({
        $sel = $fc.CmbProvider.SelectedItem
        & $loadModelsForProvider $(if ($sel) { $sel.Prov } else { $null })
    })
    # Beim Oeffnen Modelle des ersten Providers nicht automatisch laden
    # (Auto = Fallback) - Combo bleibt leer bis Provider gewaehlt wird.

    $fc.BtnNewChat.Add_Click({ & $newChat })
    $fc.BtnManager.Add_Click({ try { Show-SysPilotHerbertManager | Out-Null } catch {} })
    $fc.BtnPerm.Add_Click({ try { Show-SysPilotHerbertPermissions -Owner $win | Out-Null } catch {} })
    $fc.BtnExt.Add_Click({ try { Show-SysPilotHerbertExtensions -Owner $win | Out-Null } catch {} })

    # === Chat-Verlauf (persistent unter %LOCALAPPDATA%\SysPilot\herbert-chats) ===
    $chatId = [guid]::NewGuid().ToString('N')
    $chatCreated = (Get-Date).ToString('o')
    $chatTitle = ''
    $loadingChat = $false
    $history = @(); $pendingImages = @()

    $refreshChatList = {
        try {
            $fc.LstChats.Items.Clear()
            foreach ($c in @(Get-SysPilotHerbertChats | Select-Object -First 50)) {
                $li = New-Object Windows.Controls.ListBoxItem
                $li.Content = "$($c.Title)`n$($c.Updated.ToString('dd.MM. HH:mm')) - $($c.Count) Nachrichten"
                $li.Tag = $c.Id
                if ($c.Id -eq $chatId) {
                    try { $li.Background = [Windows.Media.BrushConverter]::new().ConvertFromString('#FF2D2D44') } catch {}
                }
                $fc.LstChats.Items.Add($li)
            }
        } catch {}
    }

    $saveCurrentChat = {
        if ($history.Count -eq 0) { return }
        try {
            Save-SysPilotHerbertChat -Id $chatId -Title $chatTitle -Messages $history -Created $chatCreated | Out-Null
            & $refreshChatList
        } catch {}
    }

    $loadChat = {
        param([string]$id)
        $j = Read-SysPilotHerbertChat -Id $id
        if (-not $j) { return }
        $loadingChat = $true
        try {
            $history = @($j.Messages | ForEach-Object { @{ role=[string]$_.role; content=[string]$_.content } })
            $pendingImages = @()
            $chatId = [string]$j.Id; $chatCreated = [string]$j.Created; $chatTitle = [string]$j.Title
            try { $fc.ChatBox.Document.Blocks.Clear() } catch {}
            & $addMsg 'System' "Chat geladen: $($j.Title) ($(@($history).Count) Nachrichten) - zum Loeschen im Chat-Menu" '#9CCC65'
            foreach ($m in $history) {
                if ($m.role -eq 'user')      { & $addMsg 'Du'      $m.content '#FFB0B0C0' }
                elseif ($m.role -eq 'assistant') { & $addMsg 'Herbert' $m.content '#FFEAEAF2' }
            }
            & $refreshChatList
        } finally { $loadingChat = $false }
    }

    $newChat = {
        & $saveCurrentChat
        $history = @(); $pendingImages = @()
        $chatId = [guid]::NewGuid().ToString('N'); $chatCreated = (Get-Date).ToString('o'); $chatTitle = ''
        try { $fc.ChatBox.Document.Blocks.Clear() } catch {}
        & $addMsg 'System' 'Neuer Chat gestartet - Verlauf ist leer.' '#9CCC65'
        & $refreshChatList
    }

    # === Vollbild-Modus: Sidebar + Maximized (Claude/PocketAI-Style) ===
    if ($fsMode) {
        try { $win.WindowState = 'Maximized' } catch {}
        try { $fc.SideBar.Visibility = 'Visible' } catch {}
        try {
            $sp = $fc.CmbProvider.SelectedItem
            $pn = if ($sp -and $sp.Name) { $sp.Name } else { 'Auto' }
            $mm = "$($fc.CmbModel.Text)".Trim()
            $fc.TxtSideStatus.Text = "Provider: $pn`nModell: $(if($mm){$mm}else{'auto'})`nKontext: $ctxLabel"
        } catch {}
        $spRoot = Split-Path $modDir -Parent
        $fc.BtnSideProviders.Add_Click({ try { Show-SysPilotAiProvidersWindow -Owner $win } catch {} })
        $fc.BtnSideSuggest.Add_Click({ try { Show-SysPilotAiSuggestionsWindow -Owner $win } catch {} })
        $fc.BtnSideManager.Add_Click({
            try { Show-SysPilotHerbertManager | Out-Null } catch {}
        })
        $fc.BtnSidePerm.Add_Click({
            try { Show-SysPilotHerbertPermissions -Owner $win | Out-Null } catch {}
        })
        $fc.BtnSideExt.Add_Click({
            try { Show-SysPilotHerbertExtensions -Owner $win | Out-Null } catch {}
        })
        $fc.BtnSideNew.Add_Click({ & $newChat })
        # Chat-Liste: Klick laedt, Entf loescht
        $fc.LstChats.Add_SelectionChanged({
            $sel = $fc.LstChats.SelectedItem
            if ($loadingChat -or $busy -or -not $sel) { return }
            $id = [string]$sel.Tag
            if ($id -and $id -ne $chatId) { & $loadChat $id }
        })
        $fc.LstChats.Add_KeyDown({ param($s,$e)
            if ($e.Key -ne 'Delete') { return }
            $sel = $fc.LstChats.SelectedItem
            if (-not $sel) { return }
            $id = [string]$sel.Tag
            $title = [string]$sel.Content
            $wr = [Windows.MessageBox]::Show("Chat loeschen?`n`n$title",'Pilot Herbert','YesNo','Question')
            if ($wr -eq 'Yes') {
                Remove-SysPilotHerbertChat -Id $id | Out-Null
                if ($id -eq $chatId) { & $newChat } else { & $refreshChatList }
            }
            $e.Handled = $true
        })
        & $refreshChatList
    }

    # Vollbild-Toggle: live umschalten + persistent speichern
    $fc.BtnFs.Add_Click({
        $isFs = ($win.WindowState -eq 'Maximized')
        try {
            if ($isFs) {
                $win.WindowState = 'Normal'
                try { $win.Width = 400; $win.Height = 620 } catch {}
                try { $fc.SideBar.Visibility = 'Collapsed' } catch {}
            } else {
                $win.WindowState = 'Maximized'
                try { $fc.SideBar.Visibility = 'Visible' } catch {}
            }
            Set-SysPilotHerbertFullscreen -Enabled (-not $isFs)
            try { $fc.TxtStatus.Text = $(if($isFs){'Vollbild aus'}else{'Vollbild an'}) } catch {}
        } catch {}
    })

    $history = @()
    $pendingImages = @()
    $busy = $false
    $rs=$null; $ps=$null; $async=$null
    $modDir = Split-Path -Parent $PSCommandPath

    $addImageMsg = {
        <# Clipboard-Bild -> PNG (Base64 fuer API) + Thumbnail im Chat. #>
        param($bmp)
        try {
            $ms = New-Object IO.MemoryStream
            $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
            $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
            $enc.Save($ms)
            $bytes = $ms.ToArray()
            $b64 = [Convert]::ToBase64String($bytes)
            $pendingImages += @{ B64=$b64; Mime='image/png' }
            $bi = New-Object Windows.Media.Imaging.BitmapImage
            $bi.BeginInit(); $bi.StreamSource = (New-Object IO.MemoryStream(,$bytes)); $bi.EndInit(); $bi.Freeze()
            $img = New-Object Windows.Controls.Image
            $img.Source=$bi; $img.Width=200; $img.Margin='0,4,0,2'
            $blk = New-Object Windows.Documents.BlockUIContainer($img)
            [void]$fc.ChatBox.Document.Blocks.Add($blk)
            $cap = New-Object Windows.Documents.Paragraph; $cap.Margin='0,0,0,4'
            $r1=[Windows.Documents.Run]::new("[Bild angehaengt: $([int]$bmp.Width)x$([int]$bmp.Height) - wird mitgesendet]")
            $r1.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString('#FF9CCC65')
            $cap.Inlines.Add($r1); [void]$fc.ChatBox.Document.Blocks.Add($cap)
            try{$fc.ChatScroll.ScrollToEnd()}catch{}
        } catch {}
    }

    $addMsg = {
        param([string]$who, [string]$text, [string]$color='#FFEAEAF2')
        $tb = New-Object Windows.Documents.Paragraph
        $tb.Margin = '0,3,0,3'
        $run = [Windows.Documents.Run]::new("$who : ")
        $run.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#FF4FC3F7')
        $tb.Inlines.Add($run)
        $fg = [Windows.Media.BrushConverter]::new().ConvertFromString($color)
        # URLs im Text als klickbare Hyperlinks rendern (oefnen Browser)
        foreach ($part in ([regex]::Split([string]$text, '(https?://[^\s<>"'']+)'))) {
            if ($part -match '^https?://') {
                $hl = New-Object Windows.Documents.Hyperlink($part)
                $hl.NavigateUri = $part
                try { $hl.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#FF64B5F6') } catch {}
                $hl.AddHandler([Windows.Documents.Hyperlink]::RequestNavigateEvent, [System.Windows.RoutedEventHandler]{
                    param($s,$e)
                    try { Start-Process $e.Uri.AbsoluteUri } catch {}
                    $e.Handled = $true
                })
                $tb.Inlines.Add($hl)
            } elseif ($part) {
                $r = [Windows.Documents.Run]::new($part)
                $r.Foreground = $fg
                $tb.Inlines.Add($r)
            }
        }
        [void]$fc.ChatBox.Document.Blocks.Add($tb)
        try { $fc.ChatScroll.ScrollToEnd() } catch {}
    }

    $stopJob = { if($async){try{$ps.Stop();$ps.Dispose()}catch{};try{$rs.Close();$rs.Dispose()}catch{}};$ps=$null;$rs=$null;$async=$null }

    $sysPrompt = {
        $admin = if (Get-Command Test-SysPilotAdmin -ErrorAction SilentlyContinue) { if(Test-SysPilotAdmin){'mit Administratorrechten'}else{'ohne Administratorrechte'} } else { '' }
        $ctx = "`nAktueller Kontext: $ctxLabel"
        $know = ''
        if (Get-Command Get-SysPilotHerbertKnowledge -ErrorAction SilentlyContinue) { try { $know = Get-SysPilotHerbertKnowledge } catch { $know = '' } }
        $interests = ''
        try { $ii = @(Get-SysPilotHerbertInterests); if ($ii.Count -gt 0) { $interests = $ii -join ', ' } } catch {}
        $iLine = if ($interests) { "`nNutzer-Interessen (du weisst, was den User beschaeftigt - erwaehne bei passenden Anlaessen relevante Infos/News aus diesen Bereichen, ohne aufdringlich zu sein): $interests" } else { '' }
        "Du bist Pilot Herbert, der Bord-Assistent von SysPilot (Flug 667), einem Windows-Wartungs-Tool (PowerShell/WPF).$ctx`nSystem: $admin$iLine`nAntworte auf Deutsch, knapp und konkret. Erfinde keine Ergebnisse - bei Unsicherheit sag es. Du kannst per <<<AKTION:ID>>> SysPilot-Aktionen anbieten (siehe Protokoll).`n`nANTWORT-PROTOKOLL (Marker werden als UI-Elemente gerendert, nicht als Text gezeigt):`n- <<<DENK:dein Gedanke/Begruendung>>> - dein Denkprozess, wird als Gedanke angezeigt`n- <<<VORSCHLAG:kurzer Vorschlag>>> - klickbarer Chip, der den Text als Nachricht sendet`n- <<<FRAGE:deine Frage|Option1|Option2>>> - Frage mit Antwort-Buttons`n- <<<AKTION:ID>>> - SysPilot-Aktion mit Uebernehmen-Button`nNutze DENK fuer sichtbares Mitdenken, VORSCHLAG fuer Alternativen die der Nutzer anklicken kann, FRAGE wenn du eine Entscheidung des Nutzers brauchst. Verwende die Marker massvoll (max. 3 pro Antwort).`n`nARBEITSWEISE: Zuerst analysieren (DENK), dann bei groesseren/unsicheren Aufgaben einen Plan vorschlagen und mit FRAGE um Zustimmung bitten, erst danach ausfuehren. Kleine, gefahrlose Fragen/Aktionen (Infos, Status, harmlose Reads) darfst du direkt erledigen. Bei jeder ausfuehrenden Aktion frag erst, was der Nutzer moechte - Permission-Modus ask/auto/bypass gilt zusaetzlich.`n`nDownload/Install-Entscheidungen: Wenn der Nutzer ein Programm installieren oder herunterladen will, entscheide ob ein Paketmanager (winget/choco/scoop/npm/pip) das Paket sauber liefert (bevorzugt) oder SmartDownload (Segment-Download, aria2, Torrent, yt-dlp) noetig ist - begruende es im DENK-Block.`n`nHERBERT-WISSEN (kuratiert - wenn der Nutzer zu einem dieser Themen fragt oder es passt, kurz und ADHS-verstaendlich erklaeren, Schritt-fuer-Schritt):`n$know"
    }

    $poll = New-Object System.Windows.Threading.DispatcherTimer
    $poll.Interval=[timespan]::FromMilliseconds(400)
    $poll.Add_Tick({
        if(-not $async){return}
        if(-not $async.IsCompleted){
            try { $fc.TxtStatus.Text = ("Herbert arbeitet ... {0}s" -f [int]((Get-Date)-$script:_busySince).TotalSeconds) } catch {}
            return
        }
        if($async.IsCompleted){
            $poll.Stop()
            $res=@()
            try{$res=@($ps.EndInvoke($async))}catch{}
            & $stopJob
            $busy=$false;$fc.BtnSend.IsEnabled=$true;$fc.TxtInput.IsEnabled=$true
            try { $fc.TxtStatus.Text = 'bereit' } catch {}
            $r = $res | Where-Object {$_ -is [hashtable]} | Select-Object -First 1
            if($r -and $r.Ok){
                $fullText = [string]$r.Text
                # Alle Marker aus dem Fliesstext entfernen
                $clean = [regex]::Replace($fullText, '\s*<<<(AKTION|DENK|VORSCHLAG|FRAGE):[\s\S]*?>>>\s*', "`n").Trim()
                & $addMsg 'Herbert' $clean '#FFEAEAF2'
                # DENK-Marker -> Gedanke-Anzeige (dunkel, kursiv)
                $denks = @([regex]::Matches($fullText, '<<<DENK:([\s\S]*?)>>>') | ForEach-Object { $_.Groups[1].Value.Trim() })
                if($denks.Count -gt 0){
                    foreach($d in $denks){ & $addMsg 'Herbert denkt' $d '#FF7A7A8C' }
                }
                # MCP-Toolcalls sichtbar machen (Ausfuehrung per Klick im
                # SysPilot-Hauptfenster-Chat - hier nur Info)
                if ($r.ToolCalls -and @($r.ToolCalls).Count -gt 0) {
                    $tn = (@($r.ToolCalls) | ForEach-Object { [string]$_.Name }) -join ', '
                    & $addMsg 'System' "MCP-Werkzeuge angefragt: $tn`n(Ausfuehrung per Klick im Hauptfenster-Chat moeglich)" '#FF9E9E9E'
                }
                # VORSCHLAG-Marker -> klickbare Chips (senden Text als Nachricht)
                $sugg = @([regex]::Matches($fullText, '<<<VORSCHLAG:([^<>|]+)>>>') | ForEach-Object { $_.Groups[1].Value.Trim() } | Select-Object -Unique)
                if($sugg.Count -gt 0){
                    $panel = New-Object Windows.Controls.WrapPanel
                    $panel.Margin='0,2,0,6'
                    foreach($s in $sugg){
                        if(-not $s){continue}
                        $b=New-Object Windows.Controls.Button
                        $b.Content=$s; $b.FontSize=11; $b.Padding='8,3'; $b.Margin='0,0,6,4'
                        $b.ToolTip='Vorschlag von Herbert - Klick sendet diesen Text'
                        $b.Add_Click({ param($bs,$be)
                            $fc.TxtInput.Text=[string]$bs.Content
                            try{$fc.TxtInput.Focus()|Out-Null}catch{}
                        })
                        [void]$panel.Children.Add($b)
                    }
                    $para=New-Object Windows.Documents.Paragraph; $para.Margin='0,0,0,2'
                    [void]$fc.ChatBox.Document.Blocks.Add((New-Object Windows.Documents.BlockUIContainer($panel)))
                    try{$fc.ChatScroll.ScrollToEnd()}catch{}
                }
                # FRAGE-Marker -> Frage + Antwort-Buttons (senden Option als Nachricht)
                $qs = @([regex]::Matches($fullText, '<<<FRAGE:([^<>]+)>>>') | ForEach-Object { $_.Groups[1].Value.Trim() })
                foreach($qraw in $qs){
                    $parts = $qraw -split '\|'
                    $question = $parts[0].Trim()
                    $opts = @($parts | Select-Object -Skip 1 | ForEach-Object { $_.Trim() } | Where-Object {$_})
                    if($question){ & $addMsg 'Herbert fragt' $question '#FFFFB74D' }
                    $panel = New-Object Windows.Controls.WrapPanel
                    $panel.Margin='0,2,0,6'
                    foreach($op in $opts){
                        $b=New-Object Windows.Controls.Button
                        $b.Content=$op; $b.FontSize=11; $b.Padding='10,4'; $b.Margin='0,0,8,4'
                        $b.ToolTip='Antwort an Herbert senden'
                        $b.Add_Click({ param($bs,$be)
                            $fc.TxtInput.Text=[string]$bs.Content
                            try{$fc.TxtInput.Focus()|Out-Null}catch{}
                        })
                        [void]$panel.Children.Add($b)
                    }
                    $para=New-Object Windows.Documents.Paragraph; $para.Margin='0,0,0,2'
                    [void]$fc.ChatBox.Document.Blocks.Add((New-Object Windows.Documents.BlockUIContainer($panel)))
                    try{$fc.ChatScroll.ScrollToEnd()}catch{}
                }
                # Aktions-Marker -> Uebernehmen-Buttons
                $acts = @([regex]::Matches($fullText, '<<<AKTION:([a-zA-Z0-9_-]+)>>>') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
                if($acts.Count -gt 0){ & $renderActions $acts }
                $history += @{ role='user'; content=$script:_lastQ }
                $history += @{ role='assistant'; content=$clean }
                if($history.Count -gt 20){ $history=@($history | Select-Object -Last 20) }
                & $saveCurrentChat
            } else {
                $err = $(if($r){$r.Error}else{'Keine Antwort'})
                & $addMsg 'System' "Fehler: $err`nTipp: SysPilot -> KI-Assistenz -> Provider einrichten." '#FFFF8A80'
            }
        }
    })

    $renderActions = {
        param([string[]]$Ids)
        $known=@{}; foreach($a in (Get-SysPilotKiActions)){ $known[$a.Id]=$a }
        $panel = New-Object Windows.Controls.WrapPanel
        $panel.Margin='0,4,0,4'
        foreach($id in $Ids){
            $a=$known[$id]; if(-not $a){continue}
            $b=New-Object Windows.Controls.Button
            $b.Content="Uebernehmen: $($a.Label)";$b.FontSize=11;$b.Padding='8,3';$b.Margin='0,0,6,4'
            $risk = switch($a.Risk){'high'{'HOCHES RISIKO'}'medium'{'mittleres Risiko'}default{'geringes Risiko'}}
            $b.ToolTip="$($a.Desc)`nRisiko: $risk | Admin: $($a.NeedsAdmin)`n`nKlick = bewusste Entscheidung"
            $b.Tag=$id
            $b.Add_Click({ param($s,$e)
                $actId=[string]$s.Tag
                $act=@(Get-SysPilotKiActions)|?{$_.Id -eq $actId}|select -First 1
                $perm='ask'
                try { $perm = Test-SysPilotKiPermission -Kind 'action' -Id $actId -Risk ([string]$act.Risk) } catch { $perm='ask' }
                if($perm -eq 'deny'){
                    & $addMsg 'System' "Aktion '$($act.Label)' ist in den Permissions blockiert." '#FFFF8A80'
                    return
                }
                if($perm -eq 'ask' -and $act -and $act.Risk -ne 'low'){
                    $wr=[Windows.MessageBox]::Show("AKTION: $($act.Label)`n`n$($act.Desc)`nRisiko: $($act.Risk.ToUpper())`n`nAusfuehren?",'Pilot Herbert','YesNo','Warning')
                    if($wr -ne 'Yes'){return}
                }
                $out = Invoke-SysPilotKiAction -Id $actId
                & $addMsg 'System' $(if($out.Ok){"[$($out.Label)]`n$($out.Text)"}else{"Fehler: $($out.Error)"}) $(if($out.Ok){'#FF9CCC65'}else{'#FFFF8A80'})
            })
            [void]$panel.Children.Add($b)
        }
        # Buttons ans Ende des Dokuments haengen
        $para = New-Object Windows.Documents.Paragraph
        $para.Margin='0,0,0,4'
        $blk = New-Object Windows.Documents.BlockUIContainer($panel)
        [void]$fc.ChatBox.Document.Blocks.Add($blk)
        try{ $fc.ChatScroll.ScrollToEnd() }catch{}
    }

    $send = {
        $q = $fc.TxtInput.Text.Trim()
        if(-not $q -and $pendingImages.Count -eq 0){return}
        if($busy){return}
        if(-not $q){$q='(siehe Bild)'}
        $fc.TxtInput.Text=''
        $imgsToSend = @($pendingImages)
        $pendingImages = @()
        & $addMsg 'Du' $q '#FFB0B0C0'
        if ($imgsToSend.Count -gt 0) { & $addMsg 'System' "$($imgsToSend.Count) Bild(er) werden mitgesendet." '#FF9CCC65' }
        $script:_lastQ = $q
        $busy=$true;$fc.BtnSend.IsEnabled=$false;$fc.TxtInput.IsEnabled=$false
        $script:_busySince = Get-Date
        $provLbl = if($provName){$provName}else{'Auto-Fallback'}
        & $addMsg 'System' "Denke nach ... ($provLbl)" '#FF9E9E9E'
        try { $fc.TxtStatus.Text = "Herbert arbeitet ($provLbl) ..." } catch {}
        try {
            if($rs){try{$ps.Stop();$ps.Dispose()}catch{};try{$rs.Close();$rs.Dispose()}catch{}}
            $rs=[runspacefactory]::CreateRunspace();$rs.ApartmentState='STA';$rs.ThreadOptions='ReuseThread';$rs.Open()
            $rs.SessionStateProxy.SetVariable('modCommon',(Join-Path $modDir 'Common.psm1'))
            $rs.SessionStateProxy.SetVariable('modAi',(Join-Path $modDir 'AiAssist.psm1'))
            $rs.SessionStateProxy.SetVariable('modMcp',(Join-Path $modDir 'McpClient.psm1'))
            $rs.SessionStateProxy.SetVariable('modUia',(Join-Path $modDir 'UiAutomation.psm1'))
            $rs.SessionStateProxy.SetVariable('prompt',$q)
            $rs.SessionStateProxy.SetVariable('sysPrompt',(& $sysPrompt))
            $rs.SessionStateProxy.SetVariable('hist',$history)
            $rs.SessionStateProxy.SetVariable('chatImgs',$imgsToSend)
            $selProv = $fc.CmbProvider.SelectedItem
            $provName = ''
            if ($selProv -and $selProv.Name) { $provName = $selProv.Name }
            $modelSel = ''
            if ($provName) { $modelSel = "$($fc.CmbModel.Text)".Trim() }
            try { Set-SysPilotAiLastSelection -Provider $provName -Model $modelSel } catch {}
            $rs.SessionStateProxy.SetVariable('provName',$provName)
            $rs.SessionStateProxy.SetVariable('modelSel',$modelSel)
            $ps=[powershell]::Create();$ps.Runspace=$rs
            [void]$ps.AddScript({
                param()
                Import-Module $modCommon -Force -Global -WarningAction SilentlyContinue
                Import-Module $modAi -Force -Global -WarningAction SilentlyContinue
                if(Test-Path $modMcp){ Import-Module $modMcp -Force -Global -WarningAction SilentlyContinue }
                if(Test-Path $modUia){ Import-Module $modUia -Force -Global -WarningAction SilentlyContinue }
                $defs=@()
                if(Get-Command Get-SysPilotMcpChatToolDefs -ErrorAction SilentlyContinue){ try{$defs=@(Get-SysPilotMcpChatToolDefs)}catch{$defs=@()} }
                Invoke-SysPilotAiChat -Prompt $prompt -System $sysPrompt -History $hist -McpToolDefs $defs -Images $chatImgs -ProviderName $provName -Model $modelSel -TimeoutSec 100
            })
            $async=$ps.BeginInvoke()
            $poll.Start()
        } catch {
            $busy=$false;$fc.BtnSend.IsEnabled=$true;$fc.TxtInput.IsEnabled=$true
            try { $fc.TxtStatus.Text = 'bereit' } catch {}
            & $addMsg 'System' "Fehler: $($_.Exception.Message)" '#FFFF8A80'
        }
    }

    # Schnellfragen-Buttons
    $sg = @()
    if($Suggestions -and @($Suggestions).Count -gt 0){ $sg = @($Suggestions) }
    else {
        $sg = @("Was kann ich in $ctxLabel tun?","Tipps zu $ctxLabel",'System-Status pruefen','Gute Einstellungen vorschlagen')
        # Kontext-Sensitivity: bei KI-/Provider-Kontexten Installations-Hilfe anbieten
        if ($ctxLabel -match 'KI|Provider|Assistent|AI|Modell|Lays|Layla') {
            $sg = @('Ein lokales KI-Tool installieren (Herbert gefuehrt)','Ein GGUF-Modell suchen + herunterladen','Was kann ich in ' + $ctxLabel + ' tun?','System-Status pruefen') + @($sg | Select-Object -Skip 1)
        }
    }
    $suggPanel = New-Object Windows.Controls.WrapPanel
    $suggPanel.Margin='0,6,0,0'
    foreach($s in $sg){
        $b=New-Object Windows.Controls.Button
        $b.Content=$s;$b.FontSize=10;$b.Padding='6,2';$b.Margin='0,0,4,4'
        $b.Add_Click({ param($s2,$e)
            $fc.TxtInput.Text=[string]$s2.Tag
            & $send
        })
        $b.Tag=$s
        [void]$suggPanel.Children.Add($b)
    }
    # WrapPanel als erstes Kind des unteren StackPanels (ueber dem Eingabefeld)
    $bottom = $fc.BtnSend.Parent
    if ($bottom -is [Windows.Controls.Panel]) { [void]$bottom.Children.Insert(0,$suggPanel) }

    $fc.BtnSend.Add_Click({ & $send })
    $fc.TxtInput.Add_KeyDown({ param($s,$e)
        if($e.Key -eq 'Return'){ & $send; $e.Handled=$true; return }
        # Strg+V: Bild aus der Zwischenablage anhaengen (falls Vision-Modell)
        if($e.Key -eq 'V' -and ($e.KeyboardDevice.Modifiers -band [Windows.Input.ModifierKeys]::Control)){
            try {
                if([Windows.Clipboard]::ContainsImage()){
                    $bmp=[Windows.Clipboard]::GetImage()
                    if($bmp){ & $addImageMsg $bmp; $e.Handled=$true }
                }
            } catch {}
        }
    })
    $win.Add_Closing({ & $stopJob; $poll.Stop(); & $saveCurrentChat })

    & $addMsg 'System' "Hallo, ich bin Pilot Herbert. Kontext: $ctxLabel. Frag mich oder nutze die Schnellfragen. Tipp: Strg+V haengt Bilder an (Vision-Modelle)." '#9CCC65'
    # Nicht-modal nur wenn ein sichtbares Owner-Fenster den Dispatcher
    # weiter pumped; sonst modal, damit der Prozess nicht exited.
    $hasLiveOwner = $false
    if ($null -ne $Owner) {
        try { $hasLiveOwner = [bool]($Owner.IsLoaded -and $Owner.IsVisible) } catch { $hasLiveOwner = $false }
    }
    if ($hasLiveOwner) { $win.Show() } else { [void]$win.ShowDialog() }
    try { $fc.TxtInput.Focus() | Out-Null } catch {}
    return $true
}

function Get-SysPilotOptionalExtras {
    <# Optionale Komponenten, die Herbert beim ersten Start anbietet -
       in sinnvoller Installations-Reihenfolge (klein -> gross).
       Nur sinnvolle Erweiterungen; was SysPilot schon mitbringt
       (Download-Tools, aria2, yt-dlp, ffmpeg, llama.cpp, Kern-PMs)
       ist nicht dabei. #>
    $pwsh = $false; try { $pwsh = [bool](Get-SysPilotPwshInfo) } catch {}
    $git  = [bool](Get-Command git.exe -ErrorAction SilentlyContinue)
    $bun  = [bool](Get-Command bun.exe -ErrorAction SilentlyContinue)
    $dn   = [bool](Get-Command dotnet.exe -ErrorAction SilentlyContinue)
    $wslU = $false; try { $wslU = (@(Get-SysPilotWslDistros) -contains 'Ubuntu') } catch {}
    return @(
        [pscustomobject]@{ Key='pwsh7'; Label='PowerShell 7'; Desc='Moderner Shell-Nachfolger - SysPilot nutzt ihn automatisch, wenn vorhanden (schneller, mehr Features).'; Installed=$pwsh; Order=10 }
        [pscustomobject]@{ Key='git';   Label='Git'; Desc='Versionskontrolle - viele Tools und Download-Quellen (GitHub, scoop-Buckets) brauchen es.'; Installed=$git; Order=20 }
        [pscustomobject]@{ Key='bun';   Label='Bun (JS-Laufzeit)'; Desc='Schnelle JavaScript-Runtime + Paketmanager - Alternative/Ergaenzung zu node/npm.'; Installed=$bun; Order=30 }
        [pscustomobject]@{ Key='dotnet';Label='.NET SDK'; Desc='Ermoeglicht .NET-Global-Tools (dotnet tool) und diverse Installer.'; Installed=$dn; Order=40 }
        [pscustomobject]@{ Key='wsl';   Label='WSL Ubuntu (Linux)'; Desc='Echte Linux-Shell: APT/DNF/Pacman/Flatpak-Paketmanager + Linux-Dev-Tools. Groesster Brocken (~1-2 GB, evtl. Neustart noetig).'; Installed=$wslU; Order=90 }
    ) | Sort-Object Order
}

function Show-SysPilotHerbertOnboarding {
    <# Einmaliges Herbert-Onboarding nach der Installation:
       zeigt optional waehlbare Extras (Checkboxen) + Was-Herbert-kann-
       Ueberblick. Auswahl wird in einem Hintergrund-Job installiert.
       Schreibt Stempel herbert-onboard.done bei jeder Entscheidung. #>
    param($Owner = $null)
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
        Write-Warning 'Show-SysPilotHerbertOnboarding braucht STA.'
        return $false
    }
    try {
        [void][reflection.assembly]::LoadWithPartialName('PresentationFramework')
        [void][reflection.assembly]::LoadWithPartialName('PresentationCore')
        [void][reflection.assembly]::LoadWithPartialName('WindowsBase')
    } catch {}

    $stamp = Join-Path $env:LOCALAPPDATA 'SysPilot\herbert-onboard.done'
    $extras = @(Get-SysPilotOptionalExtras)
    $modDir = Split-Path -Parent $PSCommandPath

    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Pilot Herbert - Ersteinrichtung" Width="620" Height="660" WindowStartupLocation="CenterOwner"
        Topmost="True" ShowInTaskbar="True"
        Background="#FF1E1E2E" Foreground="#FFEAEAF2" FontFamily="Segoe UI" ResizeMode="CanResizeWithGrip">
  <Window.Resources>
    <Style TargetType="Button"><Setter Property="Background" Value="#FF2D2D44"/><Setter Property="Foreground" Value="#FFEAEAF2"/><Setter Property="BorderBrush" Value="#FF4A4A6A"/><Setter Property="Padding" Value="10,4"/><Setter Property="Margin" Value="3"/><Setter Property="Cursor" Value="Hand"/><Setter Property="FontSize" Value="11"/></Style>
    <Style TargetType="CheckBox"><Setter Property="Foreground" Value="#FFEAEAF2"/><Setter Property="FontSize" Value="12"/><Setter Property="Margin" Value="0,3"/></Style>
    <Style TargetType="TextBox"><Setter Property="Background" Value="#FF14141E"/><Setter Property="Foreground" Value="#FFB0B0C0"/><Setter Property="BorderBrush" Value="#FF4A4A6A"/><Setter Property="Padding" Value="6,4"/><Setter Property="FontFamily" Value="Consolas"/><Setter Property="FontSize" Value="10"/></Style>
    <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#FFEAEAF2"/></Style>
  </Window.Resources>
  <DockPanel Margin="14">
    <StackPanel DockPanel.Dock="Top" Margin="0,0,0,8">
      <TextBlock Text="Pilot Herbert" FontSize="18" FontWeight="Bold" Foreground="#FF4FC3F7"/>
      <TextBlock Text="Ersteinrichtung - optionale Erweiterungen" FontSize="11" Foreground="#FF9CCC65" Margin="0,1,0,0"/>
    </StackPanel>
    <StackPanel DockPanel.Dock="Bottom" Margin="0,8,0,0">
      <WrapPanel>
        <Button x:Name="BtnInstall" Content="Auswahl installieren" ToolTip="Gewaehlte Komponenten nacheinander installieren (kann laenger dauern)"/>
        <Button x:Name="BtnSkip" Content="Alles ueberspringen"/>
        <Button x:Name="BtnNever" Content="Nicht mehr fragen" ToolTip="Onboarding nie wieder anzeigen"/>
      </WrapPanel>
      <ProgressBar x:Name="PgbInstall" Height="4" Margin="0,6,0,0" IsIndeterminate="True" Visibility="Collapsed"/>
    </StackPanel>
    <ScrollViewer VerticalScrollBarVisibility="Auto">
      <StackPanel>
        <Border Background="#FF252538" CornerRadius="6" Padding="10" Margin="0,0,0,10">
          <StackPanel>
            <TextBlock Text="Was Herbert kann" FontWeight="Bold" Foreground="#FF4FC3F7" FontSize="12" Margin="0,0,0,4"/>
            <TextBlock TextWrapping="Wrap" FontSize="10.5" Foreground="#FFB0B0C0" Text="Downloads (Segmente, aria2, Torrent, yt-dlp-Video) - Programm-Suche + Installation ueber alle Paketmanager (winget/choco/scoop/npm/pip/dotnet) mit Auto-Fix - Update-Scans + Kataloge - KI-Chat mit Aktions-Buttons, MCP-Werkzeugen und sichtbarem Denkprozess - WPF-Fenster selbst fernsteuern (klicken, lesen, Status) - Log-Analyse, Checkups, System-Wartung - RSS-Center (1400+ Feeds, OPML) + Miniflux Self-Host (Docker/Oracle/Cloudflare) inkl. Android/iOS-Client-Setup per QR/ADB -optionale Zusatz-Tools wie WSL, Git, .NET, PowerShell 7 - TV/Mobil-Sideload (Android TV/Fire TV/Smartphone/Tablet: ADB, Debloat, APK-Quellen, SmartTube+Bridge-Anleitung, iOS via AltStore PAL/SideStore) - erklaert Setup-Schritte ADHS-verstaendlich Schritt fuer Schritt"/>
          </StackPanel>
        </Border>
        <TextBlock Text="OPTIONALE ERWEITERUNGEN (Haeckchen = installieren):" FontWeight="Bold" Foreground="#FF9E9E9E" FontSize="10" Margin="0,0,0,4"/>
        <StackPanel x:Name="PnlExtras"/>
        <TextBlock x:Name="TxtStatus" FontSize="10" Foreground="#FF9CCC65" TextWrapping="Wrap" Margin="0,8,0,0" Text=""/>
        <Border x:Name="LogBorder" Background="#FF0A0A12" BorderBrush="#FF4A4A6A" BorderThickness="1" CornerRadius="4" Margin="0,6,0,0" Padding="4">
          <Grid>
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
            <TextBlock Text="INSTALLATIONS-LOG (Live)" FontSize="9" Foreground="#FF7A7A8C" Margin="2,0,0,2"/>
            <TextBox x:Name="TxtLog" Grid.Row="1" Height="120" Background="#FF000000" BorderThickness="0" IsReadOnly="True" VerticalScrollBarVisibility="Auto"
                     Foreground="#FF9FE89F" FontFamily="Consolas" FontSize="10"
                     Text="(Installations-Log erscheint hier, sobald du 'Auswahl installieren' klickst)"/>
          </Grid>
        </Border>
      </StackPanel>
    </ScrollViewer>
  </DockPanel>
</Window>
"@
    $win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$xaml)))
    if ($Owner) { try { $win.Owner = $Owner } catch {} }
    $fc = @{}
    foreach ($n in 'BtnInstall','BtnSkip','BtnNever','PnlExtras','TxtStatus','TxtLog','PgbInstall') {
        $fc[$n] = $win.FindName($n)
    }

    # Checkboxen fuer Extras (vorab installierte ausgegraut)
    $checks = @{}
    foreach ($ex in $extras) {
        $cb = New-Object Windows.Controls.CheckBox
        $suffix = if ($ex.Installed) { '  [INSTALLIERT]' } else { '' }
        $cb.Content = "$($ex.Label)$suffix  ($($ex.Desc))"
        $cb.IsChecked = (-not $ex.Installed)
        $cb.IsEnabled = (-not $ex.Installed)
        if ($ex.Installed) { $cb.Foreground = '#FF7A7A8C' }
        $cb.Tag = $ex.Key
        [void]$fc.PnlExtras.Children.Add($cb)
        $checks[$ex.Key] = $cb
    }
    $stampIt = { try { Set-Content -Path $stamp -Value (Get-Date -Format o) -Encoding UTF8 } catch {} }
    $busy = $false
    $job = $null; $pollT = $null

    $fc.BtnNever.Add_Click({ & $stampIt; $win.Close() })
    $fc.BtnSkip.Add_Click({ & $stampIt; $win.Close() })
    $win.Add_Closing({ & $stampIt })   # auch beim Schliessen: nicht wieder nerven

    $fc.BtnInstall.Add_Click({
        if ($busy) { return }
        $keys = @($checks.Keys | Where-Object { $checks[$_].IsChecked -eq $true })
        if ($keys.Count -eq 0) { $fc.TxtStatus.Text = 'Nichts ausgewaehlt.'; return }
        $busy = $true
        $fc.BtnInstall.IsEnabled = $false; $fc.BtnSkip.IsEnabled = $false; $fc.BtnNever.IsEnabled = $false
        $fc.PgbInstall.Visibility = 'Visible'
        $fc.TxtStatus.Text = "Installiere $($keys.Count) Komponente(n) - bitte warten ..."
        $fc.TxtLog.Clear()
        $script:_obStart = Get-Date
        $script:_obLastLine = Get-Date
        $labels = @{ pwsh7='PowerShell 7'; git='Git'; bun='Bun (JS-Laufzeit)'; dotnet='.NET SDK'; wsl='WSL Ubuntu' }
        $script:_obTotal = $keys.Count; $script:_obDone = 0
        $job = Start-Job -ScriptBlock {
            param($md, $klist, $lbl)
            Write-Output 'Initialisiere (lade benoetigte Module) ...'
            Get-ChildItem $md -Filter '*.psm1' | ForEach-Object { try { Import-Module $_.FullName -Force -ErrorAction SilentlyContinue } catch {} }
            Write-Output 'Module bereit - starte Installationen.'
            $i = 0; $n = $klist.Count
            foreach ($k in $klist) {
                $i++
                $name = if ($lbl.ContainsKey($k)) { $lbl[$k] } else { $k }
                Write-Output ">>> [$i/$n] Installiere $name ..."
                $out = ''
                try {
                    switch ($k) {
                        'pwsh7' { if (Get-Command Install-SysPilotPwsh -ErrorAction SilentlyContinue) { $out = (Install-SysPilotPwsh 6>&1 | Out-String) } else { $out = 'Install-SysPilotPwsh nicht verfuegbar' } }
                        'git'    { if (Get-Command Install-SysPilotPmPackage -ErrorAction SilentlyContinue) { $out = (Install-SysPilotPmPackage -Manager winget -Id 'Git.Git' 6>&1 | Out-String) } else { $out = 'PM-Modul fehlt' } }
                        'bun'    { if (Get-Command Install-SysPilotPackageManager -ErrorAction SilentlyContinue) { $out = (Install-SysPilotPackageManager -Id 'bun' 6>&1 | Out-String) } else { $out = 'PM-Modul fehlt' } }
                        'dotnet' { if (Get-Command Install-SysPilotPackageManager -ErrorAction SilentlyContinue) { $out = (Install-SysPilotPackageManager -Id 'dotnet' 6>&1 | Out-String) } else { $out = 'PM-Modul fehlt' } }
                        'wsl'    { if (Get-Command Install-SysPilotPackageManager -ErrorAction SilentlyContinue) { $out = (Install-SysPilotPackageManager -Id 'apt' 6>&1 | Out-String) } else { $out = 'PM-Modul fehlt' } }
                    }
                    # Installer-Output: leere/
-Zeilen raus, auf 12 Zeilen kuerzen
                    $lines = @($out -split "`r?`n" | Where-Object { $_.Trim() -ne '' } | Select-Object -First 12)
                    foreach ($ol in $lines) { Write-Output "    $ol" }
                    Write-Output "FERTIG: $k"
                } catch {
                    Write-Output "FEHLER $k : $($_.Exception.Message)"
                }
            }
            Write-Output '=== ALLES ERLEDIGT ==='
        } -ArgumentList $modDir, $keys, $labels
        # Poll-Timer: Job-Output streamen + Statuszeile aktualisieren
        $pollT = New-Object System.Windows.Threading.DispatcherTimer
        $pollT.Interval = [TimeSpan]::FromSeconds(1)
        $pollT.Add_Tick({
            if (-not $job) { return }
            $elapsed = [int]((Get-Date) - $script:_obStart).TotalSeconds
            try {
                $lines = Receive-Job $job -ErrorAction SilentlyContinue
                foreach ($ln in @($lines)) {
                    if (-not $ln) { continue }
                    $script:_obLastLine = Get-Date
                    $fc.TxtLog.AppendText("$ln`r`n"); try { $fc.TxtLog.ScrollToEnd() } catch {}
                    if ($ln -match '^>>> \[(\d+)/(\d+)\] Installiere (.+)') {
                        $fc.TxtStatus.Text = "Installiere $($Matches[3]) [$($Matches[1])/$($Matches[2])] - UAC-Abfragen koennen aufpoppen ..."
                    } elseif ($ln -match '^(FERTIG|FEHLER):?\s*(\S+)') {
                        $script:_obDone++
                        $fc.TxtStatus.Text = "Fortschritt: $($script:_obDone)/$($script:_obTotal) erledigt ..."
                    }
                }
                # Heartbeat: zeigt dass der Job lebt, auch ohne Ausgabe
                $silent = [int]((Get-Date) - $script:_obLastLine).TotalSeconds
                $cur = $fc.TxtStatus.Text
                if ($silent -gt 25) {
                    if ($cur -match '^(Installiere .+ \[\d+/\d+\].*|Fortschritt: \d+/\d+.*)') {
                        $fc.TxtStatus.Text = "$cur  -  keine Ausgabe seit ${silent}s (Installer laufen oft still)"
                    } else {
                        $fc.TxtStatus.Text = "Laeuft seit ${elapsed}s - keine Ausgabe seit ${silent}s, bitte Geduld ..."
                    }
                } elseif ($cur -notmatch 'Installiere .+ \[\d+/\d+\]' -and $cur -notmatch 'Fortschritt: \d+/\d+') {
                    $fc.TxtStatus.Text = "Laeuft seit ${elapsed}s ..."
                }
                if ($job.State -notin @('Running','NotStarted','Blocked')) {
                    $pollT.Stop()
                    $fc.TxtStatus.Text = "Installation abgeschlossen ($($job.State)) nach ${elapsed}s. Fenster kann geschlossen werden."
                    $fc.PgbInstall.Visibility = 'Collapsed'
                    $fc.BtnInstall.IsEnabled = $true; $fc.BtnSkip.IsEnabled = $true; $fc.BtnNever.IsEnabled = $true
                    $busy = $false
                    try { Write-SysPilotLog "Herbert-Onboarding: Extras installiert ($($job.State))" } catch {}
                    Remove-Job $job -Force -ErrorAction SilentlyContinue
                }
            } catch {}
        })
        $pollT.Start()
        $script:_obPoll = $pollT
    })

    $win.ShowDialog() | Out-Null
    try { if ($pollT) { $pollT.Stop() }; if ($job) { Remove-Job $job -Force -ErrorAction SilentlyContinue } } catch {}
    return $true
}

function Get-SysPilotLocalSkills {
    <# Scannt lokale Skill-Verzeichnisse (agents/claude/copilot/devin)
       nach SKILL.md-Dateien. Gibt Name, Desc, Path, Source zurueck. #>
    $dirs = @(
        @{ Dir = (Join-Path $env:USERPROFILE '.agents\skills'); Source='agents' },
        @{ Dir = (Join-Path $env:USERPROFILE '.claude\skills');  Source='claude' },
        @{ Dir = (Join-Path $env:USERPROFILE '.copilot\skills'); Source='copilot' },
        @{ Dir = (Join-Path $env:USERPROFILE '.config\devin\skills'); Source='devin' }
    )
    $out = @()
    foreach ($d in $dirs) {
        if (-not (Test-Path $d.Dir)) { continue }
        foreach ($sm in (Get-ChildItem -Path $d.Dir -Filter 'SKILL.md' -Recurse -File -ErrorAction SilentlyContinue)) {
            $name=''; $desc=''
            foreach ($ln in (Get-Content $sm.FullName -TotalCount 30 -ErrorAction SilentlyContinue)) {
                if (-not $name -and $ln -match '^\s*name:\s*(.+?)\s*$') { $name = $Matches[1].Trim('"'' ') }
                if (-not $desc -and $ln -match '^\s*description:\s*(.+?)\s*$') { $desc = $Matches[1].Trim('"'' ') }
                if ($name -and $desc) { break }
            }
            if (-not $name) { $name = Split-Path -Leaf (Split-Path -Parent $sm.FullName) }
            $out += [pscustomobject]@{ Name=$name; Desc=$desc; Path=$sm.FullName; Source=$d.Source; Installed=$true }
        }
    }
    return @($out | Sort-Object Name -Unique)
}

function Find-SysPilotSkillsRemote {
    <# Durchsucht die kostenlose skills.sh-Registry via `npx skills search`.
       Gibt @{Name;Desc;Ref;Url;Installs} zurueck. Laeuft ~10-30s (npx). #>
    param([Parameter(Mandatory)][string]$Query)
    $npx = (Get-Command npx.cmd -ErrorAction SilentlyContinue).Source
    if (-not $npx) { $npx = (Get-Command npx -ErrorAction SilentlyContinue).Source }
    if (-not $npx) { return @() }
    $out = & $npx -y skills@latest search $Query 2>$null
    $res = @(); $cur = $null
    foreach ($ln in @($out)) {
        $t = "$ln".Trim()
        if ($t -match '^([\w.~-]+/[\w.~-]+@[\w.~-]+)\s+([\d.]+[KMG]?)\s+installs') {
            if ($cur) { $res += $cur }
            $ref = $Matches[1]
            $parts = $ref -split '@'
            $nm = ($parts[-1] -replace '[^\w.-]','-')
            $cur = [pscustomobject]@{ Name=$nm; Desc=''; Ref=$ref; Url="https://skills.sh/$($ref -replace '@','/')"; Installs=$Matches[2]; Raw=$t }
        } elseif ($cur -and $t -match '^\S*\s*(https?://\S+)') {
            $cur.Url = $Matches[1]; $res += $cur; $cur = $null
        } elseif ($cur -and -not $cur.Desc -and $t -and $t -notmatch 'installs|^$') {
            # Beschreibungszeilen sind selten; installs-Zeile reicht als Info
        }
    }
    if ($cur) { $res += $cur }
    return @($res | Select-Object -First 30)
}

function Find-SysPilotSkillsPopular {
    <# Holt die Popular-Skills von der skills.sh-Startseite
       (/owner/repo/skill-Links) - kein Suchbegriff noetig.
       Gibt dieselbe Struktur wie Find-SysPilotSkillsRemote zurueck. #>
    param([int]$Limit = 40)
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $html = (Invoke-WebRequest -Uri 'https://www.skills.sh/' -TimeoutSec 20 -UseBasicParsing `
                 -Headers @{ 'User-Agent'='Mozilla/5.0 (SysPilot)' } -ErrorAction Stop).Content
    } catch { return @() }
    $seen=@{}; $out=@()
    foreach ($m in [regex]::Matches($html,'href="(/[\w.-]+/[\w.-]+/[\w.-]+)"')) {
        $p = $m.Groups[1].Value.Trim('/')
        $seg = $p -split '/'
        if ($seg.Count -ne 3) { continue }
        # Owner = GitHub-Name (kein Punkt), Repo/Skill = Wortzeichen
        if ($seg[0] -notmatch '^[A-Za-z0-9][A-Za-z0-9-]*$') { continue }
        if ($seg[1] -notmatch '^[\w.-]+$' -or $seg[2] -notmatch '^[\w.-]+$') { continue }
        $ref = "$($seg[0])/$($seg[1])@$($seg[2])"
        $key = $ref.ToLower()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key]=$true
        $out += [pscustomobject]@{ Name=$seg[2]; Desc=''; Ref=$ref; Url="https://skills.sh/$p"; Installs=''; Source='skills.sh popular'; Installed=$false; Path='' }
        if ($out.Count -ge $Limit) { break }
    }
    return @($out)
}

function Get-SysPilotSkillDescription {
    <# Holt die Beschreibung eines skills.sh-Eintrags von dessen Seite
       (JSON-LD/meta-Tag). Gibt '' zurueck wenn nicht ladbar. #>
    param([Parameter(Mandatory)][string]$Url)
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
        $html = ''
        foreach ($u in @($Url, $(if($Url -match '^https://(?!www\.)' ){ 'https://www.' + $Url.Substring(8) } else { '' }))) {
            if (-not $u) { continue }
            try {
                $html = (Invoke-WebRequest -Uri $u -TimeoutSec 15 -UseBasicParsing -MaximumRedirection 5 `
                         -Headers @{ 'User-Agent'='Mozilla/5.0 (SysPilot)' } -ErrorAction Stop).Content
                break
            } catch {}
        }
        if (-not $html) { return '' }
        # Laengste "description"-Angabe gewinnt (Site-Desc ist kurz,
        # Skill-Desc aus JSON-LD ist ausfuehrlich)
        $best = ''
        foreach ($m in [regex]::Matches($html, '"description"\s*:\s*"((?:[^"\\]|\\.){40,1200})"')) {
            $d = ($m.Groups[1].Value -replace '\\"','"' -replace '\\n',' ')
            if ($d.Length -gt $best.Length) { $best = $d }
        }
        if (-not $best) {
            $m2 = [regex]::Match($html, 'og:description"\s+content="([^"]{40,600})')
            if ($m2.Success) { $best = $m2.Groups[1].Value }
        }
        if ($best.Length -gt 500) { $best = $best.Substring(0,500)+'...' }
        return $best
    } catch { return '' }
}

function Install-SysPilotSkill {
    <# Installiert einen Skill aus der skills.sh-Registry global
       (npx skills add <ref> --yes --global -> ~/.agents/skills). #>
    param([Parameter(Mandatory)][string]$Ref)
    $npx = (Get-Command npx.cmd -ErrorAction SilentlyContinue).Source
    if (-not $npx) { $npx = (Get-Command npx -ErrorAction SilentlyContinue).Source }
    if (-not $npx) { return @{ Ok=$false; Message='npx nicht gefunden - Node.js noetig' } }
    $out = & $npx -y skills@latest add $Ref --yes --global 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) { return @{ Ok=$true; Message="Skill installiert: $Ref`n$out" } }
    return @{ Ok=$false; Message="Install fehlgeschlagen (Exit $LASTEXITCODE): $out" }
}

function Show-SysPilotHerbertManager {
    <# Herbert-Manager: Verwaltung von Skills (skills.sh) und MCP-Konnektoren
       (kostenlose Web-Kataloge: awesome-mcp-servers + GitHub topic:mcp-server). #>
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Pilot Herbert - Manager (Skills + Konnektoren)" Width="980" Height="620"
        WindowStartupLocation="CenterScreen" Background="#FF1E1E2E" Foreground="#FFE0E0E0">
  <Window.Resources>
    <Style TargetType="TextBox"><Setter Property="Background" Value="#FF252538"/><Setter Property="Foreground" Value="#FFE0E0E0"/><Setter Property="BorderBrush" Value="#FF4A4A6A"/><Setter Property="Padding" Value="6,4"/></Style>
    <Style TargetType="ListBox"><Setter Property="Background" Value="#FF252538"/><Setter Property="Foreground" Value="#FFE0E0E0"/><Setter Property="BorderBrush" Value="#FF4A4A6A"/></Style>
    <Style TargetType="ListBoxItem"><Setter Property="Padding" Value="6,4"/><Setter Property="Margin" Value="0,1"/></Style>
    <Style TargetType="Button"><Setter Property="Background" Value="#FF2D2D44"/><Setter Property="Foreground" Value="#FFE0E0E0"/><Setter Property="BorderBrush" Value="#FF4A4A6A"/><Setter Property="Padding" Value="12,5"/><Setter Property="Margin" Value="4,0"/><Setter Property="Cursor" Value="Hand"/></Style>
    <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#FF9E9E9E"/><Setter Property="FontSize" Value="11"/></Style>
    <Style TargetType="TabItem">
      <Setter Property="Foreground" Value="#FF9E9E9E"/><Setter Property="FontSize" Value="13"/>
      <Setter Property="Padding" Value="14,7"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="Bd" Background="#FF252538" BorderBrush="#FF4A4A6A" BorderThickness="0,0,0,2" Padding="{TemplateBinding Padding}">
              <ContentPresenter ContentSource="Header" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter Property="Background" Value="#FF2D2D44" TargetName="Bd"/>
                <Setter Property="BorderBrush" Value="#FF4FC3F7" TargetName="Bd"/>
                <Setter Property="Foreground" Value="#FF4FC3F7"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True"><Setter Property="Foreground" Value="#FFEAEAF2"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Grid Margin="14">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <TextBlock FontSize="16" FontWeight="Bold" Foreground="#FF9CCC65" Text="Pilot Herbert - Manager"/>
    <TextBlock Grid.Row="1" Margin="0,4,0,8" Text="Kostenlose + optionale Quellen: skills.sh (Skills); MCP: offizielle Registry, Smithery (inoffiziell), awesome-mcp/GitHub. [kostenpflichtig] und [Token/Env noetig] sind markiert - alles bleibt eine Option fuer dich." TextWrapping="Wrap"/>
    <TabControl Grid.Row="2">
      <TabItem Header="Konnektoren (MCP)">
        <Grid Margin="8">
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
          <DockPanel>
            <TextBox x:Name="McpQuery" Width="340" ToolTip="Suchbegriff (z.B. filesystem, browser, github)"/>
            <Button x:Name="McpSearch" Content="Katalog suchen" Margin="8,0,0,0"/>
            <Button x:Name="McpCatalog" Content="Empfehlungen (14 kuratiert)" Margin="8,0,0,0"/>
            <Button x:Name="McpTop" Content="Top 40 Remote" Margin="8,0,0,0"/>
            <Button x:Name="McpRefresh" Content="Installierte laden" Margin="8,0,0,0"/>
            <Button x:Name="McpMenu" Content="MCP-Menue" Margin="8,0,0,0"/>
          </DockPanel>
          <ListBox x:Name="McpList" Grid.Row="1" Margin="0,8">
            <ListBox.ItemTemplate><DataTemplate>
              <StackPanel>
                <TextBlock Foreground="#FFE0E0E0" FontWeight="SemiBold"><Run Text="{Binding Name}"/><Run Text="  " Foreground="#FF666688"/><Run Text="{Binding Source}"/></TextBlock>
                <TextBlock Text="{Binding Desc}" TextWrapping="Wrap" Foreground="#FF9E9E9E"/>
                <TextBlock FontSize="10" Foreground="#FF666688"><Run Text="{Binding Package}"/><Run Text="  {Binding RemoteUrl}"/><Run Text="  {Binding RepoUrl}"/></TextBlock>
              </StackPanel>
            </DataTemplate></ListBox.ItemTemplate>
          </ListBox>
          <StackPanel Grid.Row="2" Orientation="Horizontal">
            <Button x:Name="McpInstall" Content="Installieren"/>
            <Button x:Name="McpOpen" Content="Seite oeffnen"/>
            <Button x:Name="McpRemove" Content="Entfernen"/>
            <TextBlock x:Name="McpStatus" VerticalAlignment="Center" Margin="12,0,0,0"/>
          </StackPanel>
        </Grid>
      </TabItem>
      <TabItem Header="Skills (skills.sh)">
        <Grid Margin="8">
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
          <DockPanel>
            <TextBox x:Name="SkillQuery" Width="340" ToolTip="Suchbegriff (z.B. pdf, github, translate)"/>
            <Button x:Name="SkillSearch" Content="Registry suchen" Margin="8,0,0,0"/>
            <Button x:Name="SkillPopular" Content="Popular laden" Margin="8,0,0,0"/>
            <Button x:Name="SkillRefresh" Content="Lokale laden" Margin="8,0,0,0"/>
          </DockPanel>
          <ListBox x:Name="SkillList" Grid.Row="1" Margin="0,8">
            <ListBox.ItemTemplate><DataTemplate>
              <StackPanel>
                <TextBlock Foreground="#FFE0E0E0" FontWeight="SemiBold"><Run Text="{Binding Name}"/><Run Text="  " Foreground="#FF666688"/><Run Text="{Binding Source}"/></TextBlock>
                <TextBlock Text="{Binding Desc}" TextWrapping="Wrap" Foreground="#FF9E9E9E"/>
                <TextBlock FontSize="10" Foreground="#FF666688"><Run Text="{Binding Installs}"/><Run Text="  {Binding Ref}"/><Run Text="{Binding Url}"/></TextBlock>
              </StackPanel>
            </DataTemplate></ListBox.ItemTemplate>
          </ListBox>
          <StackPanel Grid.Row="2" Orientation="Horizontal">
            <Button x:Name="SkillInstall" Content="Installieren"/>
            <Button x:Name="SkillOpen" Content="Seite oeffnen"/>
            <TextBlock x:Name="SkillStatus" VerticalAlignment="Center" Margin="12,0,0,0"/>
          </StackPanel>
        </Grid>
      </TabItem>
    </TabControl>
    <TextBlock x:Name="Status" Grid.Row="3" Foreground="#FF9CCC65"/>
  </Grid>
</Window>
"@
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
    $win = [Windows.Markup.XamlReader]::Load($reader)
    $fc = @{}
    foreach ($n in 'McpQuery','McpSearch','McpCatalog','McpTop','McpRefresh','McpMenu','McpList','McpInstall','McpOpen','McpRemove','McpStatus','SkillQuery','SkillSearch','SkillPopular','SkillRefresh','SkillList','SkillInstall','SkillOpen','SkillStatus','Status') {
        $fc[$n] = $win.FindName($n)
    }
    $say = { param($t,$c='#FF9CCC65') $fc.Status.Text=$t; $fc.Status.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString($c) }

    function Load-McpInstalled {
        $items = @()
        foreach ($s in @(Get-SysPilotMcpServers)) {
            $items += [pscustomobject]@{ Name=$s.Name; Desc="installiert: $($s.Command) $($s.Args -join ' ')"; Package=''; RepoUrl=''; Source='lokal'; Stars=0 }
        }
        $script:mcpInstalled = @{}
        foreach ($s in @(Get-SysPilotMcpServers)) { $script:mcpInstalled[$s.Name.ToLower()]=$true }
        return $items
    }

    function Load-McpCatalog {
        <# Kuratierter Katalog (Get-SysPilotMcpInstallCatalog) als
           Auswahl-Liste - mit Beschreibung, Install-Markierung. #>
        if (-not $script:mcpInstalled) { $script:mcpInstalled = @{} }
        $items = @()
        foreach ($c in @(Get-SysPilotMcpInstallCatalog)) {
            $inst = $script:mcpInstalled[$c.Name.ToLower()]
            $src = if ($inst) { 'katalog [installiert]' } else { 'katalog' }
            $warn = ''
            if ($c.NeedsToken) { $warn = ' [TOKEN noetig]' }
            if ($c.NeedsArgs)  { $warn = ' [ARGS noetig]' }
            $items += [pscustomobject]@{
                Name = $c.Name; Desc = "$($c.Desc)$warn"
                Package = $c.Package; RepoUrl = ''
                Source = $src; Stars = 0
            }
        }
        return $items
    }

    $fc.McpCatalog.Add_Click({
        try {
            foreach ($s in @(Get-SysPilotMcpServers)) { $script:mcpInstalled[$s.Name.ToLower()] = $true }
        } catch {}
        $fc.McpList.ItemsSource = @(Load-McpCatalog)
        & $say "$($fc.McpList.Items.Count) kuratierte MCP-Server - 'Installieren' traegt ein, 'Installierte laden' zeigt den Ist-Stand"
    })
    # Merge mehrerer Remote-Quellen, Dedupe nach Name (erste Quelle
    # gewinnt), installierte markieren.
    $mergeMcpRemote = {
        param($items)
        $seen = @{}; $merged = @()
        foreach ($r in @($items)) {
            if (-not $r -or -not $r.Name) { continue }
            $k = $r.Name.ToLower()
            if ($seen.ContainsKey($k)) { continue }
            $seen[$k] = 1; $merged += $r
        }
        foreach ($r in $merged) { if ($script:mcpInstalled[$r.Name.ToLower()]) { $r.Source = "$($r.Source) [installiert]" } }
        return @($merged)
    }

    $fc.McpTop.Add_Click({
        & $say 'Lade Remote-Kataloge (Registry + Smithery + awesome/GitHub, kann ~30s dauern) ...'
        $fc.McpList.ItemsSource = @()
        try {
            $all = @()
            $all += @(Find-SysPilotMcpRegistryServers -Query '' -Limit 60)
            $all += @(Find-SysPilotMcpSmitheryServers -Query '' -Limit 40)
            $all += @(Find-SysPilotMcpRemoteServers -Query '' -Limit 40)
            $res = @(& $mergeMcpRemote $all | Select-Object -First 120)
            $fc.McpList.ItemsSource = $res
            & $say "$($res.Count) Remote-Treffer - Registry/Smithery/GitHub; [kostenpflichtig]+[Token] markiert"
        } catch { & $say "Fehler: $($_.Exception.Message)" '#FFF44336' }
    })
    $fc.McpRefresh.Add_Click({
        & $say 'Lade installierte Server...'
        $fc.McpList.ItemsSource = @(Load-McpInstalled)
        & $say "$($fc.McpList.Items.Count) installierte Server"
    })
    $fc.McpSearch.Add_Click({
        $q = $fc.McpQuery.Text.Trim()
        & $say "Durchsuche MCP-Kataloge (Registry + Smithery + awesome/GitHub)..."
        $fc.McpList.ItemsSource = @()
        try {
            $all = @()
            $all += @(Find-SysPilotMcpRegistryServers -Query $q -Limit 30)
            $all += @(Find-SysPilotMcpSmitheryServers -Query $q -Limit 30)
            $all += @(Find-SysPilotMcpRemoteServers -Query $q -Limit 30)
            $res = @(& $mergeMcpRemote $all)
            $fc.McpList.ItemsSource = $res
            & $say "$($res.Count) Treffer in allen Remote-Katalogen"
        } catch { & $say "Fehler: $($_.Exception.Message)" '#FFF44336' }
    })
    $fc.McpInstall.Add_Click({
        $sel = $fc.McpList.SelectedItem
        if (-not $sel) { & $say 'Bitte einen Eintrag waehlen.' '#FFFFB74D'; return }
        if ($sel.Source -match '^lokal') { & $say 'Lokaler Eintrag - nichts zu installieren.' '#FFFFB74D'; return }
        # Remote-Server (streamable-http) direkt registrieren
        if ($sel.RemoteUrl) {
            & $say "Registriere Remote-Server $($sel.Name) ..."
            $r = Install-SysPilotMcpRemote -Name $sel.Name -Url $sel.RemoteUrl
            & $say $r.Message $(if($r.Ok){'#FF9CCC65'}else{'#FFF44336'})
            if ($r.Ok) { $fc.McpRefresh.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
            return
        }
        if (-not $sel.Package) {
            & $say "Kein Direkt-Install moeglich - Seite: $($sel.RepoUrl)" '#FFFFB74D'
            return
        }
        # Env-Vars (Tokens/Keys) vor dem Install abfragen
        $envH = @{}
        if ($sel.EnvVars -and @($sel.EnvVars).Count -gt 0) {
            foreach ($ev in @($sel.EnvVars)) {
                $v = Read-SysPilotInput "Env-Variable '$ev' fuer $($sel.Name) (leer = ueberspringen)"
                if ($v) { $envH[$ev] = $v.Trim() }
            }
        }
        & $say "Installiere $($sel.Name) ($($sel.Package))..."
        $r = Install-SysPilotMcpPackage -Name $sel.Name -Package $sel.Package -Env $envH
        & $say $r.Message $(if($r.Ok){'#FF9CCC65'}else{'#FFF44336'})
        if ($r.Ok) { $fc.McpRefresh.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
    })
    $fc.McpOpen.Add_Click({
        $sel = $fc.McpList.SelectedItem
        if ($sel -and $sel.RepoUrl) { Start-Process $sel.RepoUrl }
    })
    $fc.McpRemove.Add_Click({
        $sel = $fc.McpList.SelectedItem
        if (-not $sel -or $sel.Source -notmatch 'lokal') { & $say 'Nur installierte (lokale) Eintraege koennen entfernt werden.' '#FFFFB74D'; return }
        $mc = Read-SysPilotMcpConfig
        $removed = $false
        if ($mc.Servers) {
            if ($mc.Servers -is [System.Collections.IDictionary]) {
                $removed = [bool]$mc.Servers.Remove($sel.Name)
            } else {
                if ($mc.Servers.PSObject.Properties[$sel.Name]) {
                    $mc.Servers.PSObject.Properties.Remove($sel.Name); $removed = $true
                }
            }
        }
        $mc.Disabled = @($mc.Disabled | Where-Object { $_ -ne $sel.Name })
        Write-SysPilotMcpConfig $mc
        & $say $(if($removed){"Entfernt: $($sel.Name)"}else{"Nicht in SysPilot-Config gefunden: $($sel.Name) (Quelle: $($sel.Source))"})
        $fc.McpRefresh.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    })
    $fc.McpMenu.Add_Click({ try { Show-SysPilotMcpMenu } catch {} })

    function Load-SkillsLocal {
        $items = @(Get-SysPilotLocalSkills)
        $script:skillInstalled = @{}
        foreach ($s in $items) { $script:skillInstalled["$($s.Name)@$($s.Source)"]=$true; $script:skillInstalled[$s.Name.ToLower()]=$true }
        return $items
    }
    # Beschreibungen fuer Skill-Treffer im Hintergrund von den
    # skills.sh-Seiten nachladen (Top 10) - wird von Suche + Popular
    # gemeinsam genutzt.
    $enrichSkillDescs = {
        param($res)
        # Timer-Tick laeuft nach Rueckkehr dieses Blocks - Liste
        # muss script-scoped sein, damit $res dort noch sichtbar ist.
        $script:_skillDescRes = $res
        & $say "$($res.Count) Treffer in skills.sh - lade Beschreibungen..."
        $needDesc = @($res | Where-Object { -not $_.Desc -and $_.Url } | Select-Object -First 10)
        if ($needDesc.Count -eq 0) { & $say "$($res.Count) Treffer in skills.sh"; return }
        $script:descJob = Start-Job -ScriptBlock {
            param($items)
            foreach ($it in $items) {
                try {
                    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                    $html = ''
                    foreach ($u in @($it.Url, $(if($it.Url -match '^https://(?!www\.)' ){ 'https://www.' + $it.Url.Substring(8) } else { '' }))) {
                        if (-not $u) { continue }
                        try {
                            $html = (Invoke-WebRequest -Uri $u -TimeoutSec 15 -UseBasicParsing -MaximumRedirection 5 -Headers @{ 'User-Agent'='Mozilla/5.0' }).Content
                            break
                        } catch {}
                    }
                    if (-not $html) { continue }
                    $best=''
                    foreach ($m in [regex]::Matches($html,'"description"\s*:\s*"((?:[^"\\]|\\.){40,1200})"')) {
                        $d=($m.Groups[1].Value -replace '\\"','"' -replace '\\n',' ')
                        if($d.Length -gt $best.Length){$best=$d}
                    }
                    if(-not $best){ $m2=[regex]::Match($html,'og:description"\s+content="([^"]{40,600})'); if($m2.Success){$best=$m2.Groups[1].Value} }
                    if($best.Length -gt 500){$best=$best.Substring(0,500)+'...'}
                    if($best){ $it.Desc=$best }
                } catch {}
            }
            $items
        } -ArgumentList $needDesc
        $script:descTimer = New-Object Windows.Threading.DispatcherTimer
        $script:descTimer.Interval = [TimeSpan]::FromMilliseconds(900)
        $script:descTimer.Add_Tick({
            if ($script:descJob.State -eq 'Running') { return }
            $script:descTimer.Stop()
            try {
                $upd = @(Receive-Job $script:descJob -ErrorAction Stop)
                $res = @($script:_skillDescRes)
                foreach ($u in $upd) {
                    $hit = @($res | Where-Object { $_.Ref -eq $u.Ref } | Select-Object -First 1)
                    if ($hit.Count -and $u.Desc) { $hit[0].Desc = $u.Desc }
                }
                $selIdx = $fc.SkillList.SelectedIndex
                $fc.SkillList.ItemsSource = @()
                $fc.SkillList.ItemsSource = $res
                if ($selIdx -ge 0 -and $selIdx -lt $res.Count) { $fc.SkillList.SelectedIndex = $selIdx }
                $n = @($upd | Where-Object { $_.Desc }).Count
                & $say "$($res.Count) Treffer, $n Beschreibungen geladen"
            } catch {}
            Remove-Job $script:descJob -Force -ErrorAction SilentlyContinue
        })
        $script:descTimer.Start()
    }

    $fc.SkillRefresh.Add_Click({
        & $say 'Lade lokale Skills...'
        $fc.SkillList.ItemsSource = @(Load-SkillsLocal)
        & $say "$($fc.SkillList.Items.Count) lokale Skills (~/.agents, ~/.claude, ~/.copilot)"
    })
    $fc.SkillPopular.Add_Click({
        & $say 'Lade Popular-Skills von skills.sh ...'
        $fc.SkillList.ItemsSource = @()
        try {
            $res = @(Find-SysPilotSkillsPopular -Limit 40)
            foreach ($r in $res) { if ($script:skillInstalled[$r.Name.ToLower()]) { $r.Source='skills.sh popular [installiert]' } }
            $fc.SkillList.ItemsSource = $res
            & $enrichSkillDescs $res
        } catch { & $say "Fehler: $($_.Exception.Message)" '#FFF44336' }
    })
    $fc.SkillSearch.Add_Click({
        $q = $fc.SkillQuery.Text.Trim()
        if (-not $q) { & $say 'Suchbegriff eingeben.' '#FFFFB74D'; return }
        & $say "Durchsuche skills.sh Registry (npx - kann ~30s dauern)..."
        $fc.SkillList.ItemsSource = @()
        $script:skillJob = Start-Job -ScriptBlock {
            param($query)
            $npx = (Get-Command npx.cmd -ErrorAction SilentlyContinue).Source
            if (-not $npx) { $npx = (Get-Command npx -ErrorAction SilentlyContinue).Source }
            if (-not $npx) { return ,@() }
            $out = & $npx -y skills@latest search $query 2>$null
            $res=@(); $cur=$null
            foreach ($ln in @($out)) {
                $t="$ln".Trim()
                if ($t -match '^([\w.~-]+/[\w.~-]+@[\w.~-]+)\s+([\d.]+[KMG]?)\s+installs') {
                    if ($cur) { $res += ,$cur }
                    $ref=$Matches[1]; $parts=$ref -split '@'; $nm=($parts[-1] -replace '[^\w.-]','-')
                    $cur=[pscustomobject]@{Name=$nm;Desc='';Ref=$ref;Url="https://skills.sh/$($ref -replace '@','/')";Installs=$Matches[2];Source='skills.sh';Installed=$false;Path=''}
                } elseif ($cur -and $t -match '^\S*\s*(https?://\S+)') { $cur.Url=$Matches[1]; $res+=,$cur; $cur=$null }
            }
            if ($cur) { $res+=,$cur }
            $res | Select-Object -First 30
        } -ArgumentList $q
        $script:skillTimer = New-Object Windows.Threading.DispatcherTimer
        $script:skillTimer.Interval = [TimeSpan]::FromMilliseconds(800)
        $script:skillTimer.Add_Tick({
            if ($script:skillJob.State -eq 'Running') { return }
            $script:skillTimer.Stop()
            try {
                $res = @(Receive-Job $script:skillJob -ErrorAction Stop)
                foreach ($r in $res) { if ($script:skillInstalled[$r.Name.ToLower()]) { $r.Source='skills.sh [installiert]' } }
                $fc.SkillList.ItemsSource = $res
                & $enrichSkillDescs $res
            } catch { & $say "Suche fehlgeschlagen: $($_.Exception.Message)" '#FFF44336' }
            Remove-Job $script:skillJob -Force -ErrorAction SilentlyContinue
        })
        $script:skillTimer.Start()
    })
    $fc.SkillInstall.Add_Click({
        $sel = $fc.SkillList.SelectedItem
        if (-not $sel) { & $say 'Bitte einen Eintrag waehlen.' '#FFFFB74D'; return }
        if ($sel.Installed -or $sel.Source -match 'installiert') { & $say 'Bereits installiert.' '#FFFFB74D'; return }
        if (-not $sel.Ref) { & $say 'Kein installierbarer Skill (lokaler Eintrag).' '#FFFFB74D'; return }
        & $say "Installiere Skill $($sel.Ref)..."
        $r = Install-SysPilotSkill -Ref $sel.Ref
        & $say $r.Message $(if($r.Ok){'#FF9CCC65'}else{'#FFF44336'})
        if ($r.Ok) { $fc.SkillRefresh.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
    })
    $fc.SkillOpen.Add_Click({
        $sel = $fc.SkillList.SelectedItem
        if ($sel -and $sel.Url) { Start-Process $sel.Url }
    })

    # Autostart: kuratierter MCP-Katalog + lokale Skills laden
    try { $fc.McpCatalog.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent))) } catch {}
    try { $fc.SkillRefresh.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent))) } catch {}
    try { Set-SysPilotWindowForeground -Win $win } catch {}
    [void]$win.ShowDialog()
    return $true
}


function Show-SysPilotHerbertPermissions {
    <# Permissions-Fenster (Cline/Devin-Style): globaler Modus
       (Fragen / Auto-allow / Bypass) + pro Aktion und pro
       MCP-Werkzeug Overrides (Erlauben/Fragen/Blockieren). #>
    param($Owner = $null)
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase -ErrorAction SilentlyContinue
    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Pilot Herbert - Permissions" Width="860" Height="640"
        WindowStartupLocation="CenterScreen" Background="#FF1E1E2E" Foreground="#FFE0E0E0">
  <Window.Resources>
    <Style TargetType="Button"><Setter Property="Background" Value="#FF2D2D44"/><Setter Property="Foreground" Value="#FFE0E0E0"/><Setter Property="BorderBrush" Value="#FF4A4A6A"/><Setter Property="Padding" Value="10,4"/><Setter Property="Margin" Value="3,0"/><Setter Property="Cursor" Value="Hand"/></Style>
    <Style TargetType="ListBox"><Setter Property="Background" Value="#FF252538"/><Setter Property="Foreground" Value="#FFE0E0E0"/><Setter Property="BorderBrush" Value="#FF4A4A6A"/></Style>
    <Style TargetType="ListBoxItem"><Setter Property="Padding" Value="6,3"/><Setter Property="Margin" Value="0,1"/></Style>
    <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#FF9E9E9E"/><Setter Property="FontSize" Value="11"/></Style>
  </Window.Resources>
  <Grid Margin="14">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <TextBlock FontSize="16" FontWeight="Bold" Foreground="#FF4FC3F7" Text="Permissions"/>
    <StackPanel Grid.Row="1" Margin="0,8,0,8">
      <TextBlock FontWeight="Bold" Foreground="#FFE0E0E0" Text="Modus (gilt fuer alles ohne Override):" Margin="0,0,0,4"/>
      <StackPanel Orientation="Horizontal">
        <Button x:Name="BtnModeAsk" Content="Fragen (Standard)" ToolTip="medium + high + MCP-Werkzeuge fragen jedes Mal"/>
        <Button x:Name="BtnModeAuto" Content="Auto-allow" ToolTip="low+medium automatisch, high + MCP fragen"/>
        <Button x:Name="BtnModeBypass" Content="Bypass" ToolTip="ALLES automatisch - auch MCP-Werkzeuge und high-risk. Nur fuer vertrauenswuerdige Nutzung!"/>
      </StackPanel>
      <TextBlock x:Name="TxtModeHint" Margin="0,4,0,0" TextWrapping="Wrap"/>
    </StackPanel>
    <DockPanel Grid.Row="2">
      <StackPanel DockPanel.Dock="Right" Width="170" Margin="10,0,0,0">
        <TextBlock FontWeight="Bold" Foreground="#FFE0E0E0" Text="Override fuer Auswahl:" Margin="0,0,0,4"/>
        <Button x:Name="BtnOvAllow" Content="Erlauben"/>
        <Button x:Name="BtnOvAsk" Content="Fragen"/>
        <Button x:Name="BtnOvDeny" Content="Blockieren"/>
        <Button x:Name="BtnOvReset" Content="Standard"/>
        <Separator Margin="0,8" Background="#FF4A4A6A"/>
        <TextBlock TextWrapping="Wrap" FontSize="10" Text="Erlauben/Blockieren ueberschreibt den Modus dauerhaft (in ai-assist.json)."/>
      </StackPanel>
      <ListBox x:Name="LstPerm">
        <ListBox.ItemTemplate><DataTemplate>
          <TextBlock Text="{Binding Row}" TextWrapping="Wrap"/>
        </DataTemplate></ListBox.ItemTemplate>
      </ListBox>
    </DockPanel>
    <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
      <TextBlock x:Name="TxtStatus" VerticalAlignment="Center" Foreground="#FF9CCC65"/>
      <Button x:Name="BtnClose" Content="Schliessen"/>
    </StackPanel>
  </Grid>
</Window>
"@
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
    $win = [Windows.Markup.XamlReader]::Load($reader)
    if ($Owner) { try { $win.Owner = $Owner } catch {} }
    $fc = @{}
    foreach ($n in 'BtnModeAsk','BtnModeAuto','BtnModeBypass','TxtModeHint','LstPerm','BtnOvAllow','BtnOvAsk','BtnOvDeny','BtnOvReset','TxtStatus','BtnClose') {
        $fc[$n] = $win.FindName($n)
    }
    $say = { param($t,$c='#FF9CCC65') $fc.TxtStatus.Text=$t; $fc.TxtStatus.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString($c) }

    # Alle permissions-relevanten Eintraege sammeln: Chat-Aktionen + MCP-Werkzeuge
    $items = @()
    foreach ($a in @(Get-SysPilotKiActions)) {
        $items += [pscustomobject]@{ Kind='action'; Id=$a.Id; Label=$a.Label; Risk=$a.Risk; Desc=$a.Desc }
    }
    try {
        foreach ($t in @(Get-SysPilotMcpTools)) {
            $items += [pscustomobject]@{ Kind='mcp'; Id="$($t.Server)/$($t.Name)"; Label="$($t.Server)/$($t.Name)"; Risk='high'; Desc='MCP-Werkzeug' }
        }
    } catch {}
    # Overrides als Lookup
    $ovMap = @{}
    $cfg = Read-SysPilotAiAssistConfig
    foreach ($e in @($cfg.ActionPermOverrides)) { $ovMap["a:$($e.Id)"] = [string]$e.Value }
    foreach ($e in @($cfg.McpPermOverrides))    { $ovMap["m:$($e.Id)"] = [string]$e.Value }
    foreach ($it in $items) {
        $k = $(if($it.Kind -eq 'mcp'){'m'}else{'a'}) + ':' + $it.Id
        $it | Add-Member -NotePropertyName Override -NotePropertyValue $(if($ovMap.ContainsKey($k)){$ovMap[$k]}else{''}) -Force
        $riskTxt = switch($it.Risk){'high'{'HOCH'}'medium'{'MITTEL'}default{'niedrig'}}
        $it | Add-Member -NotePropertyName Row -NotePropertyValue ("[{0}] {1}  ({2})" -f $it.Kind,$it.Label,$riskTxt) -Force
    }
    $items = @($items | Sort-Object Kind, Label)
    $fc.LstPerm.ItemsSource = $items

    $refreshMode = {
        $mode = Get-SysPilotHerbertPermissionMode
        foreach ($m in @(@('ask',$fc.BtnModeAsk),@('auto',$fc.BtnModeAuto),@('bypass',$fc.BtnModeBypass))) {
            $b = $m[1]
            $active = ($m[0] -eq $mode)
            $b.Background = [Windows.Media.BrushConverter]::new().ConvertFromString($(if($active){'#FF4FC3F7'}else{'#FF2D2D44'}))
            $b.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString($(if($active){'#FF1E1E2E'}else{'#FFE0E0E0'}))
        }
        $hint = switch($mode){
            'auto'   { 'Auto-allow: low+medium laufen ohne Rueckfrage, high + MCP-Werkzeuge fragen.' }
            'bypass' { 'BYPASS: Herbert darf alles ohne Rueckfrage - auch MCP-Werkzeuge und riskante Aktionen. Nur verwenden wenn du weisst was du tust!' }
            default  { 'Fragen: medium, high und MCP-Werkzeuge brauchen jedes Mal deine Bestaetigung.' }
        }
        $fc.TxtModeHint.Text = $hint
        $fc.TxtModeHint.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString($(if($mode -eq 'bypass'){'#FFFF7043'}else{'#FF9E9E9E'}))
    }
    $fc.BtnModeAsk.Add_Click({ try{Set-SysPilotHerbertPermissionMode -Mode 'ask'; & $refreshMode} catch{} })
    $fc.BtnModeAuto.Add_Click({ try{Set-SysPilotHerbertPermissionMode -Mode 'auto'; & $refreshMode} catch{} })
    $fc.BtnModeBypass.Add_Click({ try{Set-SysPilotHerbertPermissionMode -Mode 'bypass'; & $refreshMode} catch{} })

    $applyOverride = {
        param([string]$Val)
        $sel = $fc.LstPerm.SelectedItem
        if (-not $sel) { & $say 'Bitte zuerst einen Eintrag waehlen.' '#FFFFB74D'; return }
        $kind = $(if($sel.Kind -eq 'mcp'){'mcp'}else{'action'})
        Set-SysPilotHerbertPermissionOverride -Kind $kind -Id $sel.Id -Value $Val
        $sel.Override = $Val
        $fc.LstPerm.ItemsSource = @()
        $fc.LstPerm.ItemsSource = $items
        $fc.LstPerm.SelectedItem = $sel
        & $say $(if($Val -eq ''){"Standard wiederhergestellt: $($sel.Label)"}else{"$($sel.Label): $Val"})
    }
    $fc.BtnOvAllow.Add_Click({ & $applyOverride 'allow' })
    $fc.BtnOvAsk.Add_Click({ & $applyOverride 'ask' })
    $fc.BtnOvDeny.Add_Click({ & $applyOverride 'deny' })
    $fc.BtnOvReset.Add_Click({ & $applyOverride '' })
    $fc.BtnClose.Add_Click({ $win.Close() })

    $fc.LstPerm.Add_SelectionChanged({
        $sel = $fc.LstPerm.SelectedItem
        if ($sel) {
            $ovTxt = if ($sel.Override) { $sel.Override } else { 'Standard (Modus)' }
            & $say "Ausgewaehlt: $($sel.Row)  |  Override: $ovTxt"
        }
    })

    & $refreshMode
    & $say "$($items.Count) Eintraege - Modus: $(Get-SysPilotHerbertPermissionMode)"
    [void]$win.ShowDialog()
    return $true
}

function Show-SysPilotHerbertExtensions {
    <# Installierte MCP-Server + Skills im Ueberblick,
       mit Direkt-Aktivierung/-Deaktivierung und Knopf
       zum oeffnen des vollen Katalogs (Herbert-Manager). #>
    param($Owner = $null)
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase -ErrorAction SilentlyContinue
    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Pilot Herbert - Installierte MCP + Skills" Width="820" Height="600"
        WindowStartupLocation="CenterScreen" Background="#FF1E1E2E" Foreground="#FFE0E0E0">
  <Window.Resources>
    <Style TargetType="Button"><Setter Property="Background" Value="#FF2D2D44"/><Setter Property="Foreground" Value="#FFE0E0E0"/><Setter Property="BorderBrush" Value="#FF4A4A6A"/><Setter Property="Padding" Value="10,4"/><Setter Property="Margin" Value="3,0"/><Setter Property="Cursor" Value="Hand"/></Style>
    <Style TargetType="ListBox"><Setter Property="Background" Value="#FF252538"/><Setter Property="Foreground" Value="#FFE0E0E0"/><Setter Property="BorderBrush" Value="#FF4A4A6A"/></Style>
    <Style TargetType="ListBoxItem"><Setter Property="Padding" Value="6,3"/><Setter Property="Margin" Value="0,1"/></Style>
    <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#FF9E9E9E"/><Setter Property="FontSize" Value="11"/></Style>
  </Window.Resources>
  <Grid Margin="14">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <DockPanel>
      <TextBlock FontSize="16" FontWeight="Bold" Foreground="#FF4FC3F7" Text="Installierte MCP + Skills" VerticalAlignment="Center"/>
      <Button x:Name="BtnCatalog" Content="Katalog oeffnen (Manager)" DockPanel.Dock="Right"/>
    </DockPanel>
    <TabControl Grid.Row="1" Margin="0,8,0,8">
      <TabItem Header="MCP-Server">
        <Grid Margin="6">
          <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
          <ListBox x:Name="LstMcp">
            <ListBox.ItemTemplate><DataTemplate><TextBlock Text="{Binding Row}"/></DataTemplate></ListBox.ItemTemplate>
          </ListBox>
          <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,8,0,0">
            <Button x:Name="BtnMcpToggle" Content="Aktivieren/Deaktivieren"/>
            <Button x:Name="BtnMcpRemove" Content="Entfernen"/>
            <Button x:Name="BtnMcpRefresh" Content="Neu laden"/>
            <TextBlock x:Name="TxtMcpStatus" VerticalAlignment="Center" Margin="10,0,0,0" Foreground="#FF9CCC65"/>
          </StackPanel>
        </Grid>
      </TabItem>
      <TabItem Header="Skills">
        <Grid Margin="6">
          <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
          <ListBox x:Name="LstSkills">
            <ListBox.ItemTemplate><DataTemplate><TextBlock Text="{Binding Row}" TextWrapping="Wrap"/></DataTemplate></ListBox.ItemTemplate>
          </ListBox>
          <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,8,0,0">
            <Button x:Name="BtnSkillsRefresh" Content="Neu laden"/>
            <TextBlock x:Name="TxtSkillStatus" VerticalAlignment="Center" Margin="10,0,0,0" Foreground="#FF9CCC65"/>
          </StackPanel>
        </Grid>
      </TabItem>
    </TabControl>
    <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right">
      <Button x:Name="BtnClose" Content="Schliessen"/>
    </StackPanel>
  </Grid>
</Window>
"@
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
    $win = [Windows.Markup.XamlReader]::Load($reader)
    if ($Owner) { try { $win.Owner = $Owner } catch {} }
    $fc = @{}
    foreach ($n in 'BtnCatalog','LstMcp','BtnMcpToggle','BtnMcpRemove','BtnMcpRefresh','TxtMcpStatus','LstSkills','BtnSkillsRefresh','TxtSkillStatus','BtnClose') {
        $fc[$n] = $win.FindName($n)
    }
    $sayM = { param($t,$c='#FF9CCC65') $fc.TxtMcpStatus.Text=$t; $fc.TxtMcpStatus.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString($c) }
    $sayS = { param($t,$c='#FF9CCC65') $fc.TxtSkillStatus.Text=$t; $fc.TxtSkillStatus.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString($c) }

    $loadMcp = {
        $rows = @()
        foreach ($s in @(Get-SysPilotMcpServers)) {
            $en = if ($s.Enabled) { 'an ' } else { 'aus' }
            $tr = if ($s.Type -eq 'stdio') { 'stdio' } else { 'http ' }
            $src = if ($s.Source -eq 'syspilot') { 'entfernbar' } else { $s.Source }
            $rows += [pscustomobject]@{ Server=$s; Row=("[{0}] {1} {2} ({3})" -f $en,$tr,$s.Name,$src) }
        }
        $fc.LstMcp.ItemsSource = @($rows | Sort-Object Row)
        & $sayM "$(@($rows).Count) MCP-Server"
    }
    $loadSkills = {
        $rows = @()
        foreach ($s in @(Get-SysPilotLocalSkills)) {
            $d = [string]$s.Desc; if ($d.Length -gt 90) { $d = $d.Substring(0,90)+'...' }
            $rows += [pscustomobject]@{ Skill=$s; Row=("{0}  [{1}]  {2}" -f $s.Name,$s.Source,$d) }
        }
        $fc.LstSkills.ItemsSource = @($rows | Sort-Object Row)
        & $sayS "$(@($rows).Count) lokale Skills"
    }

    $fc.BtnCatalog.Add_Click({ try { Show-SysPilotHerbertManager | Out-Null } catch {} })
    $fc.BtnMcpRefresh.Add_Click({ & $loadMcp })
    $fc.BtnSkillsRefresh.Add_Click({ & $loadSkills })
    $fc.BtnMcpToggle.Add_Click({
        $sel = $fc.LstMcp.SelectedItem
        if (-not $sel) { & $sayM 'Bitte einen Server waehlen.' '#FFFFB74D'; return }
        $r = Set-SysPilotMcpServerEnabled -Name $sel.Server.Name -Enabled (-not $sel.Server.Enabled)
        & $sayM $r.Message $(if($r.Ok){'#FF9CCC65'}else{'#FFF44336'})
        & $loadMcp
    })
    $fc.BtnMcpRemove.Add_Click({
        $sel = $fc.LstMcp.SelectedItem
        if (-not $sel) { & $sayM 'Bitte einen Server waehlen.' '#FFFFB74D'; return }
        if ($sel.Server.Source -ne 'syspilot') { & $sayM 'Nur SysPilot-installierte Server sind entfernbar (Quelle: externe Config).' '#FFFFB74D'; return }
        $wr = [Windows.MessageBox]::Show("MCP-Server '$($sel.Server.Name)' wirklich entfernen?",'Pilot Herbert','YesNo','Question')
        if ($wr -ne 'Yes') { return }
        $r = Remove-SysPilotMcpServer -Name $sel.Server.Name
        & $sayM $r.Message $(if($r.Ok){'#FF9CCC65'}else{'#FFF44336'})
        & $loadMcp
    })
    $fc.BtnClose.Add_Click({ $win.Close() })

    & $loadMcp
    & $loadSkills
    [void]$win.ShowDialog()
    return $true
}

# =====================================================================
# KI-SETUP-ASSISTENT: Clients, Provider-Bruecke, News
# =====================================================================

function Get-SysPilotKiClientApps {
    <# Desktop-KI-Clients (Chat-Apps, Coding-Tools). Winget-IDs verifiziert
       gegen den SoftwareUpdateCenter-Katalog (Cat='KI-Apps'). #>
    return @(
        @{ Name='Visual Studio Code'; Winget='Microsoft.VisualStudioCode'; Page='https://code.visualstudio.com/'; Desc='Editor - mit Continue/Cline erweiterbar' }
        @{ Name='Claude Desktop';      Winget='Anthropic.Claude';          Page='https://claude.com/download'; Desc='Anthropics Desktop-App' }
        @{ Name='Claude Code';         Winget='Anthropic.ClaudeCode';      Page='https://claude.com/product/claude-code'; Desc='CLI-Coding-Agent (Bridge-Ziel)' }
        @{ Name='Devin (Windsurf)';    Winget='Codeium.Windsurf';          Page='https://devin.ai/'; Desc='Autonomer KI-Engineer / Windsurf-Editor' }
        @{ Name='Perplexity';          Winget='9P9XG917PWCJ'; WingetSource='msstore'; Page='https://www.perplexity.ai/'; Desc='KI-Suche (nur MSIX/Store)' }
        @{ Name='Comet Browser';       Winget='Perplexity.Comet';          Page='https://www.perplexity.ai/comet'; Desc='Perplexitys KI-Browser (Win32-Alternative)' }
        @{ Name='LM Studio';           Winget='ElementLabs.LMStudio';      Page='https://lmstudio.ai/'; Port='1234'; Desc='Lokale LLM-GUI + OpenAI-Server' }
        @{ Name='Cherry Studio';       Winget='CherryHQ.CherryStudio';     Page='https://www.cherry-ai.com'; Desc='Allround-Chat-UI, viele Provider' }
        @{ Name='Chatbox';             Winget='Chatbox.Chatbox-Community'; Page='https://chatboxai.app'; Desc='Einfacher Desktop-Chat-Client' }
        @{ Name='PocketAI';            Winget='';                          Page='https://pocketaihub.com/download'; Port='39457'; Desc='Privater Offline-KI-Client' }
        @{ Name='Layla (Desktop)';     Winget='';                          Page='https://github.com/PapaKoftes/Layla'; Repo='PapaKoftes/Layla'; InstallScript='install\bootstrap.ps1'; UiUrl='http://127.0.0.1:8000/ui'; Desc='Lokaler Assistent (Python, Web-UI :8000)' }
    )
}

function Install-SysPilotKiClientApp {
    <# Installiert einen KI-Client: GitHub-Repo (bootstrap) > winget
       (optional --source msstore) > Download-Seite im Browser. #>
    param([Parameter(Mandatory)]$App)
    if ($App.Repo) {
        return (Install-SysPilotGitRepoTool -Repo $App.Repo -InstallScript $App.InstallScript -Name ('Ki' + ($App.Name -replace '[^A-Za-z0-9]','')))
    }
    if ($App.Winget) {
        $w = (Get-Command winget -ErrorAction SilentlyContinue).Source
        if ($w) {
            $argL = @('install','--id',$App.Winget,'--exact','--accept-package-agreements','--accept-source-agreements','--disable-interactivity')
            if ($App.WingetSource) { $argL += @('--source', $App.WingetSource) }
            Write-Host "  winget install $($App.Winget) ..." -ForegroundColor Cyan
            $r = Invoke-SysPilotMonitoredProcess -FilePath $w -ArgList $argL -Label "Installiere $($App.Name)" -TimeoutSec 900
            if ($r.Ok) { return @{ Ok=$true; Message="$($App.Name) installiert (winget)" } }
            Write-Host "  winget fehlgeschlagen: $($r.Error) - oeffne Seite" -ForegroundColor DarkYellow
        }
    }
    if ($App.Page) { Start-Process $App.Page }
    return @{ Ok=$true; Message="$($App.Name): Download-Seite geoeffnet - bitte Installer ausfuehren" }
}

function Get-SysPilotKiExtensions {
    <# Kuratierte Chrome-Extensions fuer den Agenten-Browser (BrowserOS
       nutzt Chrome-Profile - Extensions gelten dort wie in Chrome).
       Url = direkter Store-Link (detail/<id>) oder Store-Suche. #>
    return @(
        @{ Name='Reddit RSS Fixer';   Url='https://chromewebstore.google.com/detail/reddit-rss-fixer/mdmahkfahjcjoclbjmoaliadfgnhboag'; Desc='Umgeht Reddit-RSS-Limit - erzeugt Feed-URLs pro Subreddit (fuers KI-News-Feed nuetzlich)' }
        @{ Name='uBlock Origin';      Url='https://chromewebstore.google.com/detail/ublock-origin/cjpalhdlnbpafiamejdnhcphjbkeiagm'; Desc='Werbeblocker - sauberere Seiten fuer Scraping/KI-Lesen' }
        @{ Name='Dark Reader';        Url='https://chromewebstore.google.com/detail/dark-reader/eimadpbcbfnmbkopoojfekhnkhdbieeh'; Desc='Dark Mode fuer alle Seiten' }
        @{ Name='JSON Viewer';        Url='https://chromewebstore.google.com/detail/json-viewer/gbmdgofindgifklingmhlmhkocbeippbb'; Desc='API-Responses/JSON lesbar formatieren' }
        @{ Name='Tampermonkey';       Url='https://chromewebstore.google.com/detail/tampermonkey/dhdgffkkebhmkfjojejmpbldmpobfkfo'; Desc='Userscripts-Verwalter (Vielfalt an Browser-Anpassungen)' }
        @{ Name='SponsorBlock';       Url='https://chromewebstore.google.com/search/sponsorblock'; Desc='Ueberspringt Sponsor-Segmente in YouTube-Videos' }
        @{ Name='Enhancer for YouTube'; Url='https://chromewebstore.google.com/search/enhancer%20for%20youtube'; Desc='YouTube anpassen: Playback, Filter, Download-Optionen' }
        @{ Name='Return YouTube Dislike'; Url='https://chromewebstore.google.com/search/return%20youtube%20dislike'; Desc='Dislike-Balken in YouTube zurueckbringen' }
        @{ Name='Vimium';             Url='https://chromewebstore.google.com/search/vimium'; Desc='Tastatur-Navigation (h,j,k,l) - schnelles Surfen' }
        @{ Name='OneTab';             Url='https://chromewebstore.google.com/search/onetab'; Desc='Tabs in eine Liste buendeln - Speicher sparen' }
        @{ Name='GetVM';              Url='https://chromewebstore.google.com/search/getvm'; Desc='Kostenlose Linux-VMs + IDEs direkt in der Browser-Seitenleiste (Coding/Lernen)' }
        @{ Name='Linux Journey';      Url='https://chromewebstore.google.com/search/linux%20journey'; Desc='Interaktiver Linux-Kurs - lernt by doing, gratis' }
        @{ Name='ManRepository';      Url='https://chromewebstore.google.com/search/manrepository'; Desc='Linux-Manpages/Kommandos nachschlagen' }
    )
}

function Show-SysPilotKiExtensionsMenu {
    <# Extension-Katalog: Enter = Store-Seite im Browser oeffnen. #>
    $items = foreach ($e in (Get-SysPilotKiExtensions)) {
        @{ Label="$($e.Name) - $($e.Desc)"; Color='Cyan'; Tag=$e }
    }
    $items += @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
    $sel = Show-SysPilotArrowMenu -Items $items -Title 'Browser-Extensions (Chrome Web Store)' -Footer 'Enter = Store oeffnen, Esc = zurueck'
    if ($null -eq $sel) { return }
    if ($sel.Url) { Start-Process $sel.Url }
}

function Show-SysPilotKiDoctor {
    <# Status + Problembehebung fuer KI-Clients, Endpunkte, Tools
       und Claude-Code-Config. Bietet Fixes per Confirm. #>
    Write-Host "`n  === KI-Doctor (Diagnose) ===" -ForegroundColor Cyan
    $miss = 0
    foreach ($a in (Get-SysPilotKiClientApps)) {
        $st = Get-SysPilotAiAppStatus -App $a
        if ($st.Installed -ne '-' -or $st.Port -eq 'LAEUFT') { Write-Host "  [ OK ] $($a.Name)" -ForegroundColor Green }
        else { Write-Host "  [--] $($a.Name) nicht installiert" -ForegroundColor DarkGray }
    }
    foreach ($e in (Get-SysPilotKiEndpointPresets)) {
        if ($e.Reachable) { Write-Host "  [ OK ] Endpoint $($e.Name) ($($e.BaseUrl))" -ForegroundColor Green }
        else { Write-Host "  [--] Endpoint $($e.Name) stoppt ($($e.BaseUrl))" -ForegroundColor DarkYellow; $miss++ }
    }
    foreach ($t in 'node','npm','python','ollama','docker','winget') {
        $c = Get-Command $t -ErrorAction SilentlyContinue
        Write-Host ("  [{0}] {1}" -f $(if($c){' OK '}else{'--  '}), $t) -ForegroundColor $(if($c){'Green'}else{'DarkGray'})
    }
    $cf = Join-Path $env:USERPROFILE '.claude\settings.json'
    if (Test-Path $cf) {
        try {
            $j = Get-Content $cf -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.env.ANTHROPIC_BASE_URL) { Write-Host "  [ OK ] Claude Code -> $($j.env.ANTHROPIC_BASE_URL)" -ForegroundColor Green }
            else { Write-Host "  [--] Claude Code: kein ANTHROPIC_BASE_URL gesetzt" -ForegroundColor DarkYellow; $miss++ }
        } catch {}
    } else { Write-Host "  [--] Claude Code nicht konfiguriert (~/.claude/settings.json fehlt)" -ForegroundColor DarkGray }
    if ($miss -gt 0) {
        Write-Host "`n  $miss Punkt(e) offen. Fixes:" -ForegroundColor Yellow
        if (Confirm-SysPilot 'Installations-Menue fuer Server-Tools/Router oeffnen?') { Show-SysPilotAiAppsInstall }
        elseif (Confirm-SysPilot 'Client-Endpoint-Bruecke oeffnen (Claude Code etc.)?') { Show-SysPilotKiBridgeMenu }
    }
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
}

function Show-SysPilotKiBrowserSetupGuide {
    <# ADHS-Guide nach Browser-Installation: Start, Default,
       Extension-Katalog. #>
    param([string]$BrowserName = 'Browser')
    $steps = @(
        @{ T="Browser '$BrowserName' starten"; Url=$null; Yt="$BrowserName setup tutorial";
           Hint='Einmal oeffnen, damit Profil + Cache angelegt werden. SysPilot hat die Installation gerade durchgefuehrt.' },
        @{ T='Als Standard-Browser festlegen (optional)';
           Url='ms-settings:defaultapps'; Yt='windows 11 set default browser';
           Hint='Windows-Settings > Standard-Apps > Browser. Nur noetig wenn SysPilot/Links ihn nutzen sollen.' },
        @{ T='Passende Extensions installieren';
           Url=$null; Yt='best chrome extensions 2026';
           Hint='Menu: KI-Setup-Assistent > Browser-Extensions - kuratierte Liste (uBlock, Dark Reader, JSON Viewer ...). Klick oeffnet den Store, Installation bleibt dein Klick.' }
    )
    [void](Show-SysPilotStepGuide -Steps $steps -Title "$BrowserName einrichten" -DoneText "$BrowserName bereit.")
}

function Show-SysPilotKiClientsMenu {
    <# KI-Desktop-Clients mit Installations-Status; Enter = installieren. #>
    $apps = @(Get-SysPilotKiClientApps)
    $items = foreach ($a in $apps) {
        $st = Get-SysPilotAiAppStatus -App $a
        $mark = $(if($st.Installed -ne '-' -or $st.Port -eq 'LAEUFT'){'[x] '}else{'[ ] '})
        $port = if ($a.Port) { ":$($a.Port)" } else { '' }
        $col = if($st.Port -eq 'LAEUFT'){'Green'}elseif($st.Installed -ne '-'){'Cyan'}else{'White'}
        @{ Label="$mark$($a.Name)$port - $($a.Desc)"; Color=$col; Tag=$a }
    }
    $items += @{ Label='[Server-Tools] Ollama, LM Studio, PocketAI, Layla, Jan ...'; Color='Yellow'; Tag='servers' }
    $items += @{ Label='Doctor: Status pruefen + Fixes (Endpunkte, Claude-Config)'; Color='Magenta'; Tag='doctor' }
    $items += @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
    $sel = Show-SysPilotArrowMenu -Items $items -Title 'KI-Clients installieren' -Footer 'Enter = Install, Esc = zurueck'
    if ($null -eq $sel) { return }
    if ($sel -eq 'servers') { Show-SysPilotAiAppsInstall; return }
    if ($sel -eq 'doctor') { Show-SysPilotKiDoctor; return }
    $r = Install-SysPilotKiClientApp -App $sel
    Write-Host "  $($r.Message)" -ForegroundColor $(if($r.Ok){'Green'}else{'Red'})
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
}

function Get-SysPilotKiEndpointPresets {
    <# Lokale OpenAI-kompatible Endpunkte (Router + lokale Server).
       'Reachable' wird per Port-Probe gesetzt. #>
    $defs = @(
        @{ Name='Ollama';        BaseUrl='http://localhost:11434/v1'; Desc='Lokaler Modell-Server (installiert)' }
        @{ Name='LM Studio';     BaseUrl='http://localhost:1234/v1';  Desc='Server in LM Studio starten (Einstellungen > Server)' }
        @{ Name='OmniRoute';     BaseUrl='http://localhost:20128/v1'; Desc='Router: 375 Provider buendeln (npm i -g omniroute)' }
        @{ Name='FreeLLMAPI';    BaseUrl='http://localhost:3001/v1';  Desc='Router: 87 Free-Provider (Docker)' }
        @{ Name='freelm';        BaseUrl='http://localhost:8080/v1';  Desc='Python-Router (pip install freelm)' }
        @{ Name='Jan';           BaseUrl='http://localhost:1337/v1';  Desc='Lokaler Server' }
        @{ Name='GPT4All';       BaseUrl='http://localhost:4891/v1';  Desc='Lokaler Server' }
    )
    foreach ($d in $defs) {
        $d['Reachable'] = Test-SysPilotAiPortReachable -BaseUrl $d.BaseUrl -TimeoutSec 1
        $d['Kind'] = $(if ($d.Name -in 'OmniRoute','FreeLLMAPI','freelm') {'router'} else {'lokal'})
    }
    return $defs
}

function Set-SysPilotClaudeCodeEndpoint {
    <# Verdrahtet Claude Code (~/.claude/settings.json, env-Block) mit
       einem lokalen/Router-Endpunkt. Erhaelt bestehende Eintraege.
       HINWEIS: Claude Code spricht Anthropic-API - funktioniert mit
       Endpunkten, die Anthropic-kompatibel sind bzw. uebersetzen
       (z.B. OmniRoute mit entspr. Route). #>
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [string]$Model = '',
        [string]$Token = 'sk-local'
    )
    $dir = Join-Path $env:USERPROFILE '.claude'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $f = Join-Path $dir 'settings.json'
    $cfg = $null
    if (Test-Path $f) {
        try { $cfg = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $cfg = $null }
    }
    if (-not $cfg) { $cfg = [pscustomobject]@{} }
    $envObj = $null
    if ($cfg.PSObject.Properties['env'] -and $cfg.env) { $envObj = $cfg.env }
    if (-not $envObj) {
        $envObj = [pscustomobject]@{}
        $cfg | Add-Member -NotePropertyName env -NotePropertyValue $envObj -Force
    }
    $envObj | Add-Member -NotePropertyName ANTHROPIC_BASE_URL     -NotePropertyValue ([string]$BaseUrl) -Force
    $envObj | Add-Member -NotePropertyName ANTHROPIC_AUTH_TOKEN    -NotePropertyValue $Token -Force
    if ($Model) { $envObj | Add-Member -NotePropertyName ANTHROPIC_MODEL -NotePropertyValue $Model -Force }
    $envObj | Add-Member -NotePropertyName ANTHROPIC_SMALL_FAST_MODEL -NotePropertyValue $(if($Model){$Model}else{'haiku'}) -Force
    ($cfg | ConvertTo-Json -Depth 10) | Set-Content -Path $f -Encoding UTF8
    return @{ Ok=$true; File=$f }
}

function Show-SysPilotKiBridgeMenu {
    <# Provider-Bruecke: Client (z.B. Claude Code) mit lokalem
       Router/Server-Endpunkt verbinden. #>
    while ($true) {
        $eps = @(Get-SysPilotKiEndpointPresets)
        $epItems = foreach ($e in $eps) {
            $mark = $(if($e.Reachable){'[LAEUFT] '}else{'[stoppt] '})
            @{ Label="$mark$($e.Name) - $($e.BaseUrl) ($($e.Desc))"; Color=$(if($e.Reachable){'Green'}else{'DarkGray'}); Tag=$e }
        }
        $epItems += @{ Label='Eigener Endpoint (URL eingeben)'; Color='White'; Tag='custom' }
        $epItems += @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
        $ep = Show-SysPilotArrowMenu -Items $epItems -Title 'Endpunkt waehlen (lokal/Router)' -Footer 'Enter = waehlen, Esc = zurueck'
        if ($null -eq $ep) { return }
        if ($ep -eq 'custom') {
            $u = Read-SysPilotInput 'OpenAI-kompatible Base-URL' 'http://localhost:11434/v1'
            if (-not $u) { continue }
            $ep = @{ Name='custom'; BaseUrl=$u; Desc='manuell' }
        }
        # Ziel-Client waehlen
        $cli = Show-SysPilotArrowMenu -Items @(
            @{ Label='Claude Code - schreibt env in ~/.claude/settings.json'; Color='Cyan'; Tag='claude' },
            @{ Label='Claude Desktop - nutzt Anthropic-Account (kein lokaler Endpoint)'; Color='DarkGray'; Tag='info' },
            @{ Label='OpenAI-kompatible Clients (Continue, Cline, Cherry Studio ...) - Config-Anleitung'; Color='White'; Tag='openai' },
            @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
        ) -Title "Client fuer $($ep.Name) verbinden" -Footer 'Enter = waehlen, Esc = zurueck'
        if ($null -eq $cli) { continue }
        switch ($cli) {
            'claude' {
                $m = Read-SysPilotInput 'Modellname (optional, z.B. llama3.2)' ''
                $r = Set-SysPilotClaudeCodeEndpoint -BaseUrl $ep.BaseUrl -Model $m
                Write-Host "  [OK] Claude Code -> $($ep.BaseUrl)" -ForegroundColor Green
                Write-Host "  Config: $($r.File)" -ForegroundColor DarkGray
                Write-Host "  Hinweis: Claude Code spricht Anthropic-API. Der Endpoint muss" -ForegroundColor DarkYellow
                Write-Host "  Anthropic-kompatibel sein (z.B. OmniRoute-Route) - sonst OpenAI-Clients nutzen." -ForegroundColor DarkYellow
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'openai' {
                Write-Host "  OpenAI-kompatible Clients auf diesen Endpoint zeigen:" -ForegroundColor Cyan
                Write-Host "    Base URL : $($ep.BaseUrl)" -ForegroundColor White
                Write-Host "    API Key  : bel. (lokal) / Key vom Router" -ForegroundColor White
                Write-Host "    Modell   : z.B. llama3.2, qwen3.5 (bei Ollama: ollama list)" -ForegroundColor White
                Write-Host "  Weiter: Cherry Studio > Provider > OpenAI-kompatibel;" -ForegroundColor DarkGray
                Write-Host "  Continue (VS Code): config.json apiBase; Cline: OpenAI-Compatible-Provider." -ForegroundColor DarkGray
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'info' {
                Write-Host "  Claude Desktop laeuft ueber den Anthropic-Account - kein lokaler Endpoint." -ForegroundColor Yellow
                Write-Host "  Lokale Modelle nutzt du stattdessen in: Cherry Studio, Chatbox, Open WebUI, Jan." -ForegroundColor DarkGray
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
        }
    }
}

function Get-SysPilotRedditViaBrowser {
    <# Fallback fuer blockierte Reddit-RSS: oeffnet die Subreddit-Seite im
       eigenen Browser (BrowserOS/Cockpit-MCP umgeht die Bot-Sperre).
       Parsemt Post-Links aus Snapshot bzw. read-Markdown. #>
    param([Parameter(Mandatory)][string]$Sub)
    $ctx = Get-SysPilotBrowserMcpContext
    if (-not $ctx) { return @() }
    $url = "https://www.reddit.com/r/$Sub/"
    # tabs new: oeffnet Seite + liefert Snapshot gleich mit
    $nav = Invoke-SysPilotMcpTool -Server $ctx.Server -Tool 'tabs' -Arguments @{ action='new'; url=$url } -TimeoutSec 90
    if (-not $nav.Ok) {
        $nav = Invoke-SysPilotBrowserMcpCall -Server $ctx.Server -Tool $ctx.NavTool -Url $url
        if (-not $nav.Ok) { return @() }
    }
    $content = [string]$nav.Text
    $items = @()
    # Snapshot-Format: link "Titel" [ref=eN] [url="https://www.reddit.com/r/X/comments/..."]
    foreach ($m in [regex]::Matches($content, 'link "([^"]{10,300})" \[ref=e\d+\] \[url="(https://www\.reddit\.com/r/' + [regex]::Escape($Sub) + '/comments/[^"]+)"\]')) {
        $items += [pscustomobject]@{ Source="r/$Sub"; Title=$m.Groups[1].Value; Url=$m.Groups[2].Value; Date=Get-Date }
    }
    # Zu wenig Treffer? -> read (Markdown): [Titel](url)
    if ($items.Count -lt 3) {
        $pageId = $null
        if ($content -match 'opened page (\d+)') { $pageId = $Matches[1] }
        if ($pageId) {
            $rd = Invoke-SysPilotMcpTool -Server $ctx.Server -Tool 'read' -Arguments @{ page=$pageId } -TimeoutSec 60
            if (-not $rd.Ok) { $rd = Invoke-SysPilotMcpTool -Server $ctx.Server -Tool $ctx.ReadTool -Arguments @{ page=$pageId } -TimeoutSec 60 }
            $md = [string]$rd.Text
            foreach ($m in [regex]::Matches($md, '\[([^\[\]]{10,300})\]\((https://www\.reddit\.com/r/' + [regex]::Escape($Sub) + '/comments/[^)\s]+)\)')) {
                $items += [pscustomobject]@{ Source="r/$Sub"; Title=$m.Groups[1].Value; Url=$m.Groups[2].Value; Date=Get-Date }
            }
        }
    }
    # Dedupe (Sidebar/Nav-Duplikate) + aufraeumen
    $seen = @{}
    return @($items | Where-Object { -not $seen.ContainsKey($_.Url) -and ($seen[$_.Url]=$true) } | Select-Object -First 15)
}

function Get-SysPilotAiNewsFeed {
    <# KI-News ohne API-Key: Reddit-RSS (LocalLLaMA, artificial) +
       HackerNews-Algolia (Query 'AI'). Reddit wird bei Bot-Sperre
       automatisch ueber den Browser-MCP geholt. #>
    param([int]$Max = 15)
    $items = @()
    $ua = 'SysPilot/0.9.5'
    foreach ($f in @(
        @{ Name='r/LocalLLaMA'; Sub='LocalLLaMA' },
        @{ Name='r/artificial';  Sub='artificial' }
    )) {
        $got = @()
        try {
            [xml]$x = Invoke-RestMethod -Uri "https://old.reddit.com/r/$($f.Sub)/.rss" -TimeoutSec 12 -Headers @{ 'User-Agent'=$ua } -ErrorAction Stop
            foreach ($it in @($x.rss.channel.item)) {
                $got += [pscustomobject]@{ Source=$f.Name; Title=[string]$it.title; Url=[string]$it.link; Date=[datetime]$it.pubDate }
            }
        } catch {}
        # Bot-Sperre/Blockseite? -> Browser-MCP-Fallback
        if ($got.Count -eq 0) {
            $got = @(Get-SysPilotRedditViaBrowser -Sub $f.Sub)
        }
        $items += $got
    }
    try {
        $hn = Invoke-RestMethod 'https://hn.algolia.com/api/v1/search?query=AI&tags=story&hitsPerPage=10' -TimeoutSec 12 -Headers @{ 'User-Agent'=$ua } -ErrorAction Stop
        foreach ($h in @($hn.hits)) {
            if ($h.title) {
                $items += [pscustomobject]@{ Source='HN'; Title=[string]$h.title; Url=[string]$h.url; Date=[datetime]::FromFileTimeUtc($h.created_at_i * 10000000 + 116444736000000000) }
            }
        }
    } catch {}
    return @($items | Sort-Object Date -Descending | Select-Object -First $Max)
}

function Show-SysPilotAiNews {
    <# KI-News-Feed (Reddit RSS + HN) - kostenlos, kein Key noetig. #>
    Write-Host "  Lade KI-News (Reddit + HackerNews) ..." -ForegroundColor Cyan
    $items = @(Get-SysPilotAiNewsFeed -Max 15)
    if ($items.Count -eq 0) { Write-Host "  Keine News geladen (Netz/Feed nicht erreichbar)." -ForegroundColor Yellow }
    elseif (@($items | Where-Object { $_.Source -like 'r/*' }).Count -eq 0) {
        Write-Host "  Hinweis: Reddit liesst nur aus dem Browser (Bot-Sperre)." -ForegroundColor DarkYellow
        Write-Host "  Fuer direktes RSS: Chrome-Extension 'Reddit RSS Fixer' (Store-Link im KI-Setup-Assistenten)." -ForegroundColor DarkYellow
    }
    foreach ($i in $items) {
        Write-Host ("  [{0}] {1}" -f $i.Source, $i.Title) -ForegroundColor White
        Write-Host ("      {0}  {1}" -f $i.Date.ToString('dd.MM HH:mm'), $i.Url) -ForegroundColor DarkGray
    }
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
}

function Show-SysPilotKiSetupWizard {
    <# Zentrale Anlaufstelle: Provider > Clients > Bruecke > News.
       Alles was SysPilot/Herbert fuer lokale+Cloud-KI einrichten kann. #>
    while ($true) {
        $sel = Show-SysPilotArrowMenu -Items @(
            @{ Label='Provider waehlen + Keys (30+ Free/Cloud-Endpoints)'; Color='Green';  Tag='providers' },
            @{ Label='Router installieren (OmniRoute, FreeLLMAPI, freelm)'; Color='Cyan'; Tag='routers' },
            @{ Label='KI-Clients installieren (VS Code, Claude, Perplexity, Devin ...)'; Color='Green'; Tag='clients' },
            @{ Label='Server-Tools (Ollama, LM Studio, PocketAI, Layla, Jan ...)'; Color='Green'; Tag='servers' },
            @{ Label='Client mit Provider verbinden (Claude-Code-Bridge, OpenAI-Anleitung)'; Color='Yellow'; Tag='bridge' },
            @{ Label='Browser-Extensions (Reddit RSS Fixer, Werbeblocker, Dark Mode ...)'; Color='Cyan'; Tag='extensions' },
            @{ Label='RSS-Center (1400+ Feeds, Interessengebiete, OPML, Miniflux)'; Color='Green'; Tag='rss' },
            @{ Label='Miniflux Self-Host einrichten (Docker/Cloud, unbegrenzt)'; Color='Green'; Tag='miniflux' },
            @{ Label='TV-Setup (Android TV/Fire TV: ADB, Debloat, Sideload, KodiRoll, VYPN)'; Color='Green'; Tag='tv' },
            @{ Label='Browser installieren (Chrome, Brave, Tor, Firefox ...)'; Color='Cyan'; Tag='browsers' },
            @{ Label='Wichtige Apps prüfen (LibreOffice, Notepad++, PDF, Bildbearbeitung ...)'; Color='Green'; Tag='essentials' },
            @{ Label='Modelle laden (HuggingFace GGUF, Ollama pull)'; Color='Cyan'; Tag='models' },
            @{ Label='KI-News-Feed (Reddit LocalLLaMA + HackerNews)'; Color='White'; Tag='news' },
            @{ Label='Ersteinrichtung / Onboarding'; Color='DarkCyan'; Tag='onboard' },
            @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
        ) -Title 'KI-Setup-Assistent (Herbert)' -Footer 'Enter = Aktion, Esc = zurueck'
        if ($null -eq $sel) { return }
        switch ($sel) {
            'providers' { Show-SysPilotAiProviderMenu }
            'routers'   { Show-SysPilotAiRouterInstallMenu }
            'clients'   { Show-SysPilotKiClientsMenu }
            'servers'   { Show-SysPilotAiAppsInstall }
            'bridge'    { Show-SysPilotKiBridgeMenu }
            'extensions'{ Show-SysPilotKiExtensionsMenu }
            'rss'       { Show-SysPilotRssCenter }
            'miniflux'  { Show-SysPilotMinifluxSetup }
            'tv'        { Show-SysPilotTvSetup }
            'browsers'  { Show-SysPilotKiBrowsersMenu }
            'essentials'{ Show-SysPilotKiEssentialsMenu }
            'models'    { Show-SysPilotAiModelFinder }
            'news'      { Show-SysPilotAiNews }
            'onboard'   { Show-SysPilotAiOnboarding }
        }
    }
}


# =====================================================================
# RSS-READER, FEED-VORSCHLAEGE, BROWSER, ESSENTIAL-APPS
# =====================================================================

function Get-SysPilotRssReaderApps {
    <# RSS-Reader-Extensions: sauber, mit Bildern+Text, gute Sortierung.
       Alle kostenlos; 'FreshRSS'/'Miniflux' als Self-Host-Optionen. #>
    return @(
        @{ Name='Feeder';            Url='https://chromewebstore.google.com/search/feeder%20rss'; Desc='Minimalistisch, sehr clean - Bilder+Text, Abo-Listen' }
        @{ Name='RSS Feed Reader';   Url='https://chromewebstore.google.com/search/rss%20feed%20reader'; Desc='Funktionsreich, Ordner/Tags, wird oft empfohlen' }
        @{ Name='Feedbro';           Url='https://chromewebstore.google.com/search/feedbro'; Desc='Komplett-Lösung: Tabs, Filter, Download, Syncron' }
        @{ Name='Inoreader (Web)';   Url='https://www.inoreader.com/'; Desc='Maechstiger Web-Reader, Free-Tier, Filterregeln' }
        @{ Name='Feedly (Web)';      Url='https://feedly.com/'; Desc='Polierter Web-Reader, Leo-KI-Zusammenfassungen' }
        @{ Name='FreshRSS (Self-Host)'; Url='https://freshrss.org/'; Desc='Open Source, eigener Server - unbegrenzt, privat' }
    )
}

function Get-SysPilotRssFeedSuggestions {
    <# Kuratierte Feed-Vorschlaege (RSS/Atom) MIT Kategorie -
       Export-SysPilotRssOpml gruppiert danach, Get-SysPilotRssFeedSuggestions
       kann per -Interests gefiltert werden. #>
    param([string[]]$Interests = @())
    $all = @(
        # Technik & KI
        @{ Name='OpenAI News';        Url='https://openai.com/news/rss.xml'; Desc='Offizielle Ankuendigungen'; Cat='Technik & KI' }
        @{ Name='Google AI Blog';     Url='https://blog.google/technology/ai/rss/'; Desc='Google-Forschung + Modelle'; Cat='Technik & KI' }
        @{ Name='The Verge - KI';     Url='https://www.theverge.com/rss/ai-artificial-intelligence/index.xml'; Desc='KI-News der Tech-Presse'; Cat='Technik & KI' }
        @{ Name='Ars Technica';       Url='https://arstechnica.com/feed/'; Desc='Tiefgruendige Tech-Analyse'; Cat='Technik & KI' }
        @{ Name='Heise online';       Url='https://www.heise.de/news/rss/'; Desc='Deutsch, IT/Security'; Cat='Technik & KI' }
        @{ Name='Golem.de';           Url='https://rss.golem.de/'; Desc='Deutsch, Hardware/Software'; Cat='Technik & KI' }
        @{ Name='Krebs on Security';  Url='https://krebsonsecurity.com/feed/'; Desc='Security-Recherche'; Cat='Technik & KI' }
        @{ Name='Simon Willison';     Url='https://simonwillison.net/atom/everything/'; Desc='LLM-Tools, Prompting, Releases'; Cat='Technik & KI' }
        @{ Name='Interconnects';      Url='https://www.interconnects.ai/feed'; Desc='Nathan Lambert - Open-Source-LLM-Szene'; Cat='Technik & KI' }
        @{ Name='Latent Space';       Url='https://www.latent.space/feed'; Desc='AI-Engineering-Podcast + Blog'; Cat='Technik & KI' }
        @{ Name='Hugging Face Blog';  Url='https://huggingface.co/blog/feed.xml'; Desc='Modelle, Datasets, Tools'; Cat='Technik & KI' }
        @{ Name='MIT Tech Review AI'; Url='https://www.technologyreview.com/topic/artificial-intelligence/feed'; Desc='AI-Politik + Forschung'; Cat='Technik & KI' }
        @{ Name='VentureBeat AI';      Url='https://venturebeat.com/category/ai/feed/'; Desc='Startup/Industrie-KI'; Cat='Technik & KI' }
        # Windows & Deskmodder
        @{ Name='Deskmodder';          Url='https://www.deskmodder.de/rss/'; Desc='DE: Tools, Windows-Tricks, Docks'; Cat='Windows' }
        @{ Name='Windows Central';     Url='https://www.windowscentral.com/latest/russell-rubio/feed'; Desc='EN: Windows/Surface-News'; Cat='Windows' }
        @{ Name='Windows News';        Url='https://www.windowscentral.com/latest/windows/feed'; Desc='EN: Windows-Updates + Guides'; Cat='Windows' }
        # Games & Stores
        @{ Name='Steam News';          Url='https://store.steampowered.com/feeds/news/app/730'; Desc='Steam-Plattform-News'; Cat='Games' }
        @{ Name='PC Gamer';            Url='https://www.pcgamer.com/rss/'; Desc='PC-Gaming-News'; Cat='Games' }
        @{ Name='Rock Paper Shotgun';  Url='https://www.rockpapershotgun.com/feed'; Desc='PC-Games-Kritiken + News'; Cat='Games' }
        @{ Name='GOG News';            Url='https://www.gog.com/news?format=rss'; Desc='GOG-Deals + Releases'; Cat='Games' }
        @{ Name='Epic Games News';     Url='https://store.epicgames.com/en-US/news?lang=en-US'; Desc='Epic-Store (kein RSS - HTML-Link)' ; Cat='Games'; HtmlOnly=$true }
        # Gesundheit & Neurodiversitaet
        @{ Name='ADHD News (ADDitude)';Url='https://www.additudemag.com/feed/'; Desc='EN: ADHS-Magazin'; Cat='Gesundheit' }
        @{ Name='Psychology Today';    Url='https://www.psychologytoday.com/intl/blog/feed'; Desc='EN: Psychologie-Blogs'; Cat='Gesundheit' }
        @{ Name='NIMH (NIH)';          Url='https://www.nimh.nih.gov/index.xml'; Desc='EN: Schizophrenie/ADHS-Forschung (behördlich, seriös)'; Cat='Gesundheit' }
        @{ Name='Longevity Tech';      Url='https://www.labiotech.eu/feed/'; Desc='EN: Biotech/Longevity-News'; Cat='Gesundheit' }
        # Politik & Weltgeschehen
        @{ Name='Tagesschau';          Url='https://www.tagesschau.de/xml/rss2'; Desc='DE: Nachrichten'; Cat='Politik & Welt' }
        @{ Name='Spiegel Politik';     Url='https://www.spiegel.de/politik/index.rss'; Desc='DE: Politik'; Cat='Politik & Welt' }
        @{ Name='DW News';             Url='https://rss.dw.com/rdf/rss-de-all'; Desc='DE: Auslandsnachrichten'; Cat='Politik & Welt' }
        @{ Name='Al Jazeera';          Url='https://www.aljazeera.com/xml/rss/all.xml'; Desc='EN: Nahost/Geopolitik'; Cat='Politik & Welt' }
        @{ Name='ReliefWeb';           Url='https://reliefweb.int/updates/rss.xml'; Desc='EN: Krisen/Fluechtlinge (UN-OCHA)'; Cat='Politik & Welt' }
        # Reddit (via .rss-Endpoints)
        @{ Name='r/LocalLLaMA';        Url='https://www.reddit.com/r/LocalLLaMA/top/.rss?t=week'; Desc='RE: lokale LLMs'; Cat='Reddit & KI' }
        @{ Name='r/ADHD';              Url='https://www.reddit.com/r/ADHD/top/.rss?t=week'; Desc='RE: ADHS-Community'; Cat='Reddit & Gesundheit' }
        @{ Name='r/Schizophrenia';     Url='https://www.reddit.com/r/Schizophrenia/top/.rss?t=month'; Desc='RE: Psychose-Erfahrungen'; Cat='Reddit & Gesundheit' }
        @{ Name='r/Autism';            Url='https://www.reddit.com/r/Autism/top/.rss?t=week'; Desc='RE: Autismus'; Cat='Reddit & Gesundheit' }
        @{ Name='r/SteamDeck';         Url='https://www.reddit.com/r/SteamDeck/top/.rss?t=week'; Desc='RE: Steam Deck/PC-Gaming'; Cat='Reddit & Games' }
        @{ Name='r/linux';             Url='https://www.reddit.com/r/linux/top/.rss?t=day'; Desc='RE: Linux'; Cat='Reddit & Technik' }
        @{ Name='r/windows';           Url='https://www.reddit.com/r/windows/top/.rss?t=day'; Desc='RE: Windows'; Cat='Reddit & Technik' }
        @{ Name='r/linux_gaming';      Url='https://www.reddit.com/r/linux_gaming/top/.rss?t=week'; Desc='RE: Linux-Gaming'; Cat='Reddit & Games' }
        @{ Name='r/battlestations';    Url='https://www.reddit.com/r/battlestations/top/.rss?t=week'; Desc='RE: PC-Setups'; Cat='Reddit & Technik' }
        @{ Name='r/UFOs';              Url='https://www.reddit.com/r/UFOs/top/.rss?t=week'; Desc='RE: UFO/UAP-Beobachtungen'; Cat='Reddit & Mystery' }
        @{ Name='r/UnresolvedMysteries';Url='https://www.reddit.com/r/UnresolvedMysteries/top/.rss?t=month'; Desc='RE: ungelöste Fälle'; Cat='Reddit & Mystery' }
        @{ Name='r/Paranormal';        Url='https://www.reddit.com/r/Paranormal/top/.rss?t=week'; Desc='RE: paranormale Themen'; Cat='Reddit & Mystery' }
        @{ Name='r/Fantasy';           Url='https://www.reddit.com/r/Fantasy/top/.rss?t=week'; Desc='RE: Fantasy-Buecher/Filme'; Cat='Reddit & Medien' }
        @{ Name='r/scifi';             Url='https://www.reddit.com/r/scifi/top/.rss?t=week'; Desc='RE: Science-Fiction'; Cat='Reddit & Medien' }
        @{ Name='r/horror';            Url='https://www.reddit.com/r/horror/top/.rss?t=week'; Desc='RE: Horror-Filme/Serien'; Cat='Reddit & Medien' }
        @{ Name='r/books';             Url='https://www.reddit.com/r/books/top/.rss?t=day'; Desc='RE: Buecher allg.'; Cat='Reddit & Medien' }
        @{ Name='r/television';        Url='https://www.reddit.com/r/television/top/.rss?t=day'; Desc='RE: Serien/Diskussion'; Cat='Reddit & Medien' }
        @{ Name='r/movies';            Url='https://www.reddit.com/r/movies/top/.rss?t=day'; Desc='RE: Filme'; Cat='Reddit & Medien' }
    )
    # Reddit hat anonyme .rss-Endpoints eingestellt (404/429, Stand 2026);
    # GOGs ?format=rss liefert kein RSS. HtmlOnly => nicht in OPML-Export,
    # bleibt als HTML-Link in Menues erreichbar.
    foreach ($f in $all) {
        if ($f.Url -match 'reddit\.com' -or $f.Url -match 'gog\.com/news') {
            $f['HtmlOnly'] = $true
            if ($f.Desc -notmatch 'HTML') { $f['Desc'] = "$($f.Desc) (HTML-Link, RSS blockiert)" }
        }
    }
    # Auf interests filtern: Category-Keyword-Match (groesstenteils
    # deckungsgleich mit den Themen-Namen); ohne Interests alles.
    if ($Interests.Count -gt 0) {
        $map = @{
            'Technik & KI'='Technik|KI|Linux|Windows|Games|Steam|GOG|Epic|Deskmodder|Windows Central|Reddit|science';
            'Windows'='Windows|Deskmodder|windows';
            'Games'='Games|Game|Steam|GOG|Epic|gaming|PC Gamer|Rock Paper';
            'Gesundheit'='Gesundheit|Longevity|Nahrungsergaenzung|Psychosen|Schizophrenie|ADHS|Autismus|Psychologie|mental';
            'Politik & Welt'='Politik|Krieg|Geopolitik|Welt|Nachrichten|Kriegsgeschehen'
        }
        $kw = @()
        foreach ($i in $Interests) {
            $li = $i.ToLower()
            if ($li -match 'gesundheit|wohlbefinden') { $kw += 'Gesundheit' }
            elseif ($li -match 'longevity|anti.?aging') { $kw += 'Gesundheit' }
            elseif ($li -match 'nahrung|mikronaehrstoff|ernaehrung|kochen') { $kw += 'Gesundheit' }
            elseif ($li -match 'psychose|schizophrenie|psycholog') { $kw += 'Gesundheit' }
            elseif ($li -match 'adhs') { $kw += 'Gesundheit' }
            elseif ($li -match 'autismus|neurodivers') { $kw += 'Gesundheit' }
            elseif ($li -match 'politik') { $kw += 'Politik & Welt' }
            elseif ($li -match 'krieg|geopolitik|weltgeschehen') { $kw += 'Politik & Welt' }
            elseif ($li -match 'windows|deskmodder|windows central') { $kw += 'Windows' }
            elseif ($li -match 'linux') { $kw += 'Technik & KI' }
            elseif ($li -match 'game|steam|gog|epic|spiel') { $kw += 'Games' }
            elseif ($li -match 'technik|ki|informatik|software|hardware') { $kw += 'Technik & KI' }
            elseif ($li -match 'reddit') { $kw += 'Reddit & Technik'; $kw += 'Reddit & Gesundheit'; $kw += 'Reddit & Games'; $kw += 'Reddit & KI'; $kw += 'Reddit & Mystery' }
            elseif ($li -match 'alien|ufo|uap|mystery|paranormal|ungeklaert') { $kw += 'Mystery'; $kw += 'Reddit & Mystery' }
            elseif ($li -match 'fantasy|scifi|science.?fiction|horror|krimi|thriller|buch|film|serie|medien') { $kw += 'Medien'; $kw += 'Reddit & Medien' }
            elseif ($li -match 'hobb|freizeit|musik|reisen|sport|bewegung') { $kw += 'Hobbys'; $kw += 'Freizeit' }
            elseif ($li -match 'wissenschaft|forschung|technik') { $kw += 'Technik & KI'; $kw += 'Wissenschaft' }
            else { $kw += $i }   # unbekanntes Interesse: als Keyword behalten
        }
        # Kategorie-Filter: Feed bleibt, wenn sein Cat/Name/Desc den
        # Keyword enthaelt (case-insensitiv, literal - kein Regex-Risiko).
        $keep = @()
        foreach ($f in $all) {
            $hay = "$($f.Cat) $($f.Name) $($f.Desc)"
            foreach ($k in $kw) {
                if ($hay -like "*$k*") { $keep += $f; break }
            }
        }
        # immer ein paar Basis-Feeds dazu (damit OPML nicht leer wird)
        $have = @{}; foreach ($f in $keep) { $have[$f.Url] = $true }
        foreach ($f in $all) { if (-not $have[$f.Url] -and $f.Cat -eq 'Technik & KI') { $keep += $f; if ($keep.Count -ge 8) { break } } }
        return @($keep | Sort-Object Cat, Name)
    }
    return $all
}

function Show-SysPilotRssFeedsMenu {
    <# Feed-Vorschlaege: Enter = Feed-URL oeffnen (fuer Import in den
       RSS-Reader). Zuerst Reader-Empfehlung zeigen. #>
    Write-Host "`n  RSS-Reader-Empfehlung (kostenlos, Bilder+Text, sortiert):" -ForegroundColor Cyan
    Get-SysPilotRssReaderApps | Select-Object -First 3 | ForEach-Object {
        Write-Host "    - $($_.Name): $($_.Desc)" -ForegroundColor DarkGray
        Write-Host "      $($_.Url)" -ForegroundColor DarkCyan
    }
    $items = foreach ($f in (Get-SysPilotRssFeedSuggestions)) {
        @{ Label="$($f.Name) - $($f.Desc)"; Color='Green'; Tag=$f }
    }
    $items += @{ Label='[Reader] RSS-Reader-Extensions ansehen'; Color='Yellow'; Tag='readers' }
    $items += @{ Label='[Self-Host] Miniflux einrichten (unbegrenzt, Docker/Cloud)'; Color='Green'; Tag='miniflux' }
    $items += @{ Label='[Clients] Miniflux-Clients (Android/iOS/Desktop + QR + ADB)'; Color='Green'; Tag='clients' }
    $items += @{ Label='[Interessen] Herbert-Themenprofil (filtert Feeds + News)'; Color='Cyan'; Tag='interests' }
    $items += @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
    $sel = Show-SysPilotArrowMenu -Items $items -Title 'Feed-Vorschlaege (Herbert-Auswahl)' -Footer 'Enter = Feed-URL oeffnen, Esc = zurueck'
    if ($null -eq $sel) { return }
    if ($sel -eq 'miniflux') { Show-SysPilotMinifluxSetup; return }
    if ($sel -eq 'clients') { Show-SysPilotRssClientSetup; return }
    if ($sel -eq 'interests') { Show-SysPilotHerbertInterestsSetup; return }
    if ($sel -eq 'readers') { Show-SysPilotArrowMenu -Items (@(foreach ($r in (Get-SysPilotRssReaderApps)) { @{ Label="$($r.Name) - $($r.Desc)"; Color='Cyan'; Tag=$r } }) + @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }) -Title 'RSS-Reader waehlen' -Footer 'Enter = Store oeffnen' | ForEach-Object { if ($_) { Start-Process $_.Url } }; return }
    if ($sel.Url) { Set-Clipboard -Value $sel.Url; Start-Process $sel.Url; Write-Host "  Feed-URL kopiert + im Browser geoeffnet: $($sel.Url)" -ForegroundColor Green }
}

function Get-SysPilotKiBrowsers {
    <# Browser-Katalog: Chrome/Brave bevorzugt, Tor für anonymes Surfen,
       Firefox + Edge als Alternativen. #>
    return @(
        @{ Name='Google Chrome';  Winget='Google.Chrome';       Page='https://www.google.com/chrome/'; Desc='Standard-Browser, groesste Extension-Auswahl' }
        @{ Name='Brave';          Winget='Brave.Brave';         Page='https://brave.com/'; Desc='Chromium + eingebauter Werbeblocker/Tracking-Schutz' }
        @{ Name='Tor Browser';    Winget='TorProject.TorBrowser'; Page='https://www.torproject.org/'; Desc='Anonymes Surfen (Tor-Netz) - langsam, fuer_privatsphaere; ggf. Bridges noetig' }
        @{ Name='Firefox';        Winget='Mozilla.Firefox';     Page='https://www.mozilla.org/firefox/'; Desc='Unabhaengiger Browser, strikte Privacy' }
        @{ Name='Microsoft Edge'; Winget='Microsoft.Edge';      Page='https://www.microsoft.com/edge'; Desc='Bei Windows vorinstalliert' }
    )
}

function Show-SysPilotKiBrowsersMenu {
    <# Browser-Status + Installation + Extension-Hinweis. #>
    $items = foreach ($b in (Get-SysPilotKiBrowsers)) {
        $st = Get-SysPilotAiAppStatus -App $b
        $mark = $(if($st.Installed -ne '-'){'[x] '}else{'[ ] '})
        @{ Label="$mark$($b.Name) - $($b.Desc)"; Color=$(if($st.Installed -ne '-'){'Green'}else{'White'}); Tag=$b }
    }
    $items += @{ Label='[Extensions] Passende Extensions fuer Browser ansehen'; Color='Cyan'; Tag='ext' }
    $items += @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
    $sel = Show-SysPilotArrowMenu -Items $items -Title 'Browser installieren (Chrome/Brave/Tor ...)' -Footer 'Enter = Install/Details, Esc = zurueck'
    if ($null -eq $sel) { return }
    if ($sel -eq 'ext') { Show-SysPilotKiExtensionsMenu; return }
    if ($sel.Installed) { Write-Host "  $($sel.Name) ist bereits installiert." -ForegroundColor Green; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; return }
    $r = Install-SysPilotKiClientApp -App $sel
    Write-Host "  $($r.Message)" -ForegroundColor $(if($r.Ok){'Green'}else{'Red'})
    if ($sel.Name -eq 'Tor Browser') {
        Write-Host "  Tor-Hinweis: langsames Routing ist normal; in zensierten Netzen evtl. Bridges noetig" -ForegroundColor DarkYellow
        Write-Host "  (Tor Browser > Connect > 'Use a bridge')." -ForegroundColor DarkYellow
    }
    if ($r.Ok -and (Confirm-SysPilot 'Einrichtungs-Guide starten (Start/Default/Extensions)?')) {
        Show-SysPilotKiBrowserSetupGuide -BrowserName $sel.Name
    }
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
}

function Get-SysPilotKiEssentials {
    <# Wichtige Desktop-Apps + kostenlose Alternativen (Match =
       DisplayName-Regex fuer die Installations-Erkennung). #>
    return @(
        @{ Name='LibreOffice';    Winget='TheDocumentFoundation.LibreOffice'; Page='https://www.libreoffice.org/'; Match='LibreOffice'; Desc='Office-Suite (Word/Excel/PPT-Ersatz)' }
        @{ Name='Notepad++';      Winget='Notepad++.Notepad++';    Page='https://notepad-plus-plus.org/'; Match='Notepad\+\+|Notepad Plus Plus'; Desc='Bester Code-/Text-Editor' }
        @{ Name='7-Zip';          Winget='7zip.7zip';              Page='https://www.7-zip.org/'; Match='7-Zip|7Zip'; Desc='Archiv-Tool' }
        @{ Name='VLC media player'; Winget='VideoLAN.VLC';         Page='https://www.videolan.org/'; Match='VLC media player'; Desc='Alle Video/Audio-Formate' }
        @{ Name='SumatraPDF';     Winget='SumatraPDF.SumatraPDF';  Page='https://www.sumatrapdfreader.org/'; Match='SumatraPDF'; Desc='Schneller kostenloser PDF-Reader (Foxit-Alternative)' }
        @{ Name='PDF24 Creator';  Winget='PDF24.PDF24Creator';     Page='https://tools.pdf24.org/'; Match='PDF24'; Desc='PDF-Werkzeuge: Merge, OCR, Konvertieren (Foxit-Alternative)' }
        @{ Name='GIMP';           Winget='GIMP.GIMP';              Page='https://www.gimp.org/'; Match='GIMP'; Desc='Bildbearbeitung (Photoshop-Alternative)' }
        @{ Name='Krita';          Winget='Krita.Krita';            Page='https://krita.org/'; Match='Krita'; Desc='Digital Art / Mal-Programm' }
        @{ Name='KeePassXC';      Winget='KeePassXCP.KeePassXC';   Page='https://keepassxc.org/'; Match='KeePassXC'; Desc='Passwort-Manager offline' }
        @{ Name='PowerToys';      Winget='Microsoft.PowerToys';    Page='https://learn.microsoft.com/windows/powertoys/'; Match='PowerToys'; Desc='Microsoft-Utilities: FancyZones, Picker u.a.' }
        @{ Name='ShareX';         Winget='ShareX.ShareX';          Page='https://getsharex.com/'; Match='ShareX'; Desc='Screenshots + Screen-Recording + Annotieren' }
        @{ Name='Everything';     Winget='voidtools.Everything';   Page='https://www.voidtools.com/'; Match='Everything'; Desc='Sofortige Dateisuche (Eingabe = global)' }
        @{ Name='OBS Studio';     Winget='OBSProject.OBSStudio';   Page='https://obsproject.com/'; Match='OBS Studio'; Desc='Screen-Recording/Streaming' }
        @{ Name='HandBrake';      Winget='HandBrake.HandBrake';    Page='https://handbrake.fr/'; Match='HandBrake'; Desc='Video-Konvertierung/Kompression' }
        @{ Name='Calibre';        Winget='Calibre-Project.Calibre'; Page='https://calibre-ebook.com/'; Match='Calibre'; Desc='E-Book-Verwaltung + Konvertierung' }
    )
}

function Get-SysPilotInstalledAppNames {
    <# Alle installierten Anzeigenamen (Uninstall-Registry, beider
       WOW6432-Knoepfe + HKCU) + Startmenu-Namen. Einmalig geholt. #>
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                  'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*') {
        Get-ItemProperty $k -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.DisplayName) { $names.Add([string]$_.DisplayName) }
        }
    }
    try { Get-StartApps -ErrorAction SilentlyContinue | ForEach-Object { if ($_.Name) { $names.Add([string]$_.Name) } } } catch {}
    return $names
}

function Export-SysPilotRssOpml {
    <# Exportiert Feed-Vorschlaege als OPML-Datei - importierbar in
       jeden RSS-Reader (Miniflux, FreshRSS, Feedly, Inoreader).
       -Items: optionale Liste @{Name;Url;Desc;Category} - wird nach
       Kategorien in verschachtelte Outlines sortiert (gut lesbar
       im Reader). Ohne -Items: kuratierte Liste, flach. #>
    param([string]$OutPath = '', [object[]]$Items = @())
    if (-not $OutPath) {
        $dir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'SysPilot'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $OutPath = Join-Path $dir 'syspilot-feeds.opml'
    }
    $feeds = @()
    if ($Items.Count -gt 0) { $feeds = @($Items) }
    else {
        # Standard: nach Herbert-Interessen filtern (kategorisiert);
        # ohne Profil die volle kuratierte Liste.
        $ii = @()
        if (Get-Command Get-SysPilotHerbertInterests -ErrorAction SilentlyContinue) { try { $ii = @(Get-SysPilotHerbertInterests) } catch {} }
        $src = @(Get-SysPilotRssFeedSuggestions -Interests $ii | Where-Object { -not $_.HtmlOnly })
        $feeds = @($src | ForEach-Object {
            $c = [string]$_.Cat; if (-not $c) { $c = 'Empfehlungen' }
            $_ | Add-Member -NotePropertyName Category -NotePropertyValue $c -Force; $_
        })
    }
    $esc = { param($s) [System.Security.SecurityElement]::Escape([string]$s) }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
    [void]$sb.AppendLine('<opml version="2.0">')
    [void]$sb.AppendLine('  <head><title>SysPilot Feed-Vorschlaege</title></head>')
    [void]$sb.AppendLine('  <body>')
    # Gruppiert nach Kategorie (sortiert), innerhalb nach Name
    $groups = @{}
    foreach ($f in $feeds) {
        $c = [string]$f.Category; if (-not $c) { $c = 'Sonstige' }
        if (-not $groups.ContainsKey($c)) { $groups[$c] = @() }
        $groups[$c] += $f
    }
    foreach ($cat in ($groups.Keys | Sort-Object)) {
        $catFeeds = @($groups[$cat] | Sort-Object Name)
        if ($catFeeds.Count -eq 1 -and $cat -eq 'Sonstige') {
            $f = $catFeeds[0]
            [void]$sb.AppendLine("    <outline text=`"$(& $esc $f.Name)`" title=`"$(& $esc $f.Name)`" type=`"rss`" xmlUrl=`"$(& $esc $f.Url)`" htmlUrl=`"$(& $esc $f.Url)`" description=`"$(& $esc $f.Desc)`" />")
            continue
        }
        [void]$sb.AppendLine("    <outline text=`"$(& $esc $cat)`" title=`"$(& $esc $cat)`">")
        foreach ($f in $catFeeds) {
            [void]$sb.AppendLine("      <outline text=`"$(& $esc $f.Name)`" title=`"$(& $esc $f.Name)`" type=`"rss`" xmlUrl=`"$(& $esc $f.Url)`" htmlUrl=`"$(& $esc $f.Url)`" description=`"$(& $esc $f.Desc)`" />")
        }
        [void]$sb.AppendLine('    </outline>')
    }
    [void]$sb.AppendLine('  </body>')
    [void]$sb.AppendLine('</opml>')
    [System.IO.File]::WriteAllText($OutPath, $sb.ToString(), [System.Text.Encoding]::UTF8)
    return $OutPath
}

function Get-SysPilotRssFeedDirectory {
    <# Holt kuratierte Feed-Kataloge aus oeffentlichen Quellen (GitHub,
       keine Keys noetig):
         1) jonchretien/dev-lists feeds.opml - Tech-Branchen, kategorisiert
         2) clivoa/awesome-security-feeds feeds.json - ~1146 Security-Feeds
       Ergebnis: @{Name;Url;Desc;Category;Source} - 24h gecacht unter
       %LOCALAPPDATA%\SysPilot\rss-directory-cache.json. #>
    $cacheFile = Join-Path $env:LOCALAPPDATA 'SysPilot\rss-directory-cache.json'
    if (Test-Path $cacheFile) {
        try {
            $ci = Get-Item $cacheFile
            if (((Get-Date) - $ci.LastWriteTime).TotalHours -lt 24) {
                $cached = @(Get-Content $cacheFile -Raw -Encoding UTF8 | ConvertFrom-Json)
                if ($cached.Count -gt 50) { return $cached }
            }
        } catch {}
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
    $feeds = @(); $seen = @{}
    # 1) dev-lists OPML (kategorisierte Outlines)
    try {
        $opmlText = (Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/jonchretien/dev-lists/main/feeds.opml' `
                     -TimeoutSec 25 -UseBasicParsing -Headers @{ 'User-Agent'='SysPilot' } -ErrorAction Stop).Content
        [xml]$x = $opmlText
        $top = @($x.opml.body.outline)
        foreach ($cat in $top) {
            $catName = [string]$cat.title; if (-not $catName) { $catName = [string]$cat.text }
            $children = @($cat.outline)
            if ($children.Count -eq 0 -and $cat.xmlUrl) { $children = @($cat) }
            foreach ($f in $children) {
                $u = [string]$f.xmlUrl
                if (-not $u -or $seen.ContainsKey($u)) { continue }
                $seen[$u] = $true
                $feeds += [pscustomobject]@{ Name=[string]$f.title; Url=$u; Desc=[string]$f.description; Category=$catName; Source='dev-lists' }
            }
        }
    } catch { Write-SysPilotLog "RSS-Directory dev-lists: $($_.Exception.Message)" }
    # 2) awesome-security-feeds JSON (categories als Feld)
    try {
        $j = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/clivoa/awesome-security-feeds/main/data/feeds.min.json' `
             -TimeoutSec 40 -Headers @{ 'User-Agent'='SysPilot' } -ErrorAction Stop
        foreach ($f in @($j.feeds)) {
            $u = [string]$f.url
            if (-not $u -or $seen.ContainsKey($u)) { continue }
            $seen[$u] = $true
            $cat = 'Security'
            if ($f.category) { $cat = "Security: $($f.category)" }
            $feeds += [pscustomobject]@{ Name=[string]$f.title; Url=$u; Desc=[string]$f.description; Category=$cat; Source='sec-feeds' }
        }
    } catch { Write-SysPilotLog "RSS-Directory sec-feeds: $($_.Exception.Message)" }
    $feeds = @($feeds | Sort-Object Category, Name)
    try {
        $dir = Split-Path $cacheFile -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $feeds | ConvertTo-Json -Depth 4 | Set-Content $cacheFile -Encoding UTF8
    } catch {}
    return $feeds
}

# =====================================================================
# MINIFLUX API (Self-Host RSS-Server): Config + Feed-Import mit Kategorien
# =====================================================================

$script:MinifluxConfigPath = Join-Path $env:LOCALAPPDATA 'SysPilot\miniflux.json'

function Get-SysPilotMinifluxConfig {
    if (Test-Path $script:MinifluxConfigPath) {
        try { return (Get-Content $script:MinifluxConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {}
    }
    return [pscustomobject]@{ BaseUrl='http://localhost:8080'; ApiKey='' }
}

function Set-SysPilotMinifluxConfig {
    param([string]$BaseUrl = 'http://localhost:8080', [string]$ApiKey = '')
    $cfg = [pscustomobject]@{ BaseUrl=$BaseUrl.TrimEnd('/'); ApiKey=$ApiKey }
    $dir = Split-Path $script:MinifluxConfigPath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $cfg | ConvertTo-Json | Set-Content $script:MinifluxConfigPath -Encoding UTF8
}

function Invoke-SysPilotMinifluxApi {
    <# Miniflux-REST-Call. Gibt deserialisierte Antwort oder $null. #>
    param([Parameter(Mandatory)][string]$Method, [string]$Path, $Body = $null)
    $cfg = Get-SysPilotMinifluxConfig
    if (-not $cfg.ApiKey) { return $null }
    $headers = @{ 'X-Auth-Token' = $cfg.ApiKey; 'Content-Type' = 'application/json' }
    $uri = $cfg.BaseUrl.TrimEnd('/') + $Path
    try {
        $p = @{ Uri=$uri; Method=$Method; Headers=$headers; TimeoutSec=30 }
        if ($null -ne $Body) { $p.Body = ($Body | ConvertTo-Json -Depth 8 -Compress) }
        return (Invoke-RestMethod @p -ErrorAction Stop)
    } catch { return $null }
}

function Test-SysPilotMinifluxApi {
    <# Prueft API-Key gegen /v1/me. Gibt @{Ok;User;Error}. #>
    param([string]$BaseUrl = '', [string]$ApiKey = '')
    if ($BaseUrl) { Set-SysPilotMinifluxConfig -BaseUrl $BaseUrl -ApiKey $ApiKey }
    $cfg = Get-SysPilotMinifluxConfig
    if (-not $cfg.ApiKey) { return @{ Ok=$false; User=''; Error='Kein API-Key konfiguriert' } }
    $me = Invoke-SysPilotMinifluxApi -Method 'Get' -Path '/v1/me'
    if ($me -and $me.username) { return @{ Ok=$true; User=[string]$me.username; Error='' } }
    return @{ Ok=$false; User=''; Error='API antwortet nicht - Key/URL pruefen (Miniflux > Settings > API Keys)' }
}

function Add-SysPilotMinifluxFeeds {
    <# Importiert Feeds per API, gruppiert nach Kategorie (Miniflux
       legt Kategorien an und sortiert die Feeds darunter).
       Gibt @{Ok;Created;Skipped;Error} zurueck. #>
    param([Parameter(Mandatory)][object[]]$Items)
    $t = Test-SysPilotMinifluxApi
    if (-not $t.Ok) { return @{ Ok=$false; Created=0; Skipped=0; Error=$t.Error } }
    # Vorhandene Kategorien holen
    $cats = Invoke-SysPilotMinifluxApi -Method 'Get' -Path '/v1/categories'
    $catMap = @{}
    foreach ($c in @($cats)) { $catMap[[string]$c.title] = [int]$c.id }
    $created = 0; $skipped = 0; $errors = @()
    # Pro Kategorie buendeln
    $groups = @{}
    foreach ($f in $Items) {
        $u = [string]$f.Url; if (-not $u) { continue }
        $cat = [string]$f.Category; if (-not $cat) { $cat = 'SysPilot' }
        if (-not $groups.ContainsKey($cat)) { $groups[$cat] = @() }
        $groups[$cat] += $u
    }
    foreach ($cat in ($groups.Keys | Sort-Object)) {
        # Kategorie anlegen falls noetig
        $catId = 0
        if ($catMap.ContainsKey($cat)) { $catId = $catMap[$cat] }
        else {
            $nc = Invoke-SysPilotMinifluxApi -Method 'Post' -Path '/v1/categories' -Body @{ title=$cat }
            if ($nc -and $nc.id) { $catId = [int]$nc.id; $catMap[$cat] = $catId }
        }
        # Miniflux nimmt Arrays pro Call - in 50er-Batches
        $urls = @($groups[$cat] | Select-Object -Unique)
        for ($i = 0; $i -lt $urls.Count; $i += 50) {
            $chunk = @($urls[$i..([Math]::Min($i + 49, $urls.Count - 1))])
            $body = @{ feed_urls = $chunk; category_id = $catId }
            $r = Invoke-SysPilotMinifluxApi -Method 'Post' -Path '/v1/feeds' -Body $body
            if ($r) { $created += @($r).Count } else { $errors += "$cat : API-Fehler" }
        }
    }
    $skipped = ($Items.Count - $created)
    if ($errors.Count -gt 0) { return @{ Ok=($created -gt 0); Created=$created; Skipped=$skipped; Error=($errors -join '; ') } }
    return @{ Ok=$true; Created=$created; Skipped=$skipped; Error='' }
}

function Get-SysPilotRssMobileClients {
    <# Kuratierte Reader-Clients fuer Miniflux (offizielle Miniflux-Docs:
       Fever-API + Google-Reader-API-Kompatibilitaet, beides in
       Miniflux > Settings > Integrations aktivierbar). #>
    $ps = 'https://play.google.com/store/search?q={0}&c=apps'
    $ios = 'https://apps.apple.com/us/search?term={0}'
    $fd = 'https://f-droid.org/packages/?q={0}'
    return @(
        [pscustomobject]@{ Platform='Android'; Name='Capy Reader';        Store=($ps -f 'capy%20reader');          Fdroid=''; Api='Google Reader API'; Desc='FOSS, Material You, aktiv entwickelt - Top-Empfehlung' }
        [pscustomobject]@{ Platform='Android'; Name='FluxNews';          Store=($ps -f 'fluxnews');              Fdroid=($fd -f 'fluxnews'); Api='Miniflux API (nativ)'; Desc='FOSS, Podcasts, Offline, OLED-Mode' }
        [pscustomobject]@{ Platform='Android'; Name='Fleuron';           Store=($ps -f 'fleuron%20miniflux');   Fdroid=''; Api='Miniflux API (nativ)'; Desc='FOSS, nur fuer Miniflux gebaut' }
        [pscustomobject]@{ Platform='Android'; Name='FeedMe';            Store=($ps -f 'feedme%20rss');         Fdroid=''; Api='Fever API'; Desc='Poliert, offline-cache, proprietaer' }
        [pscustomobject]@{ Platform='Android'; Name='Read You';          Store=($ps -f 'read%20you%20rss');     Fdroid=''; Api='Google Reader/Fever'; Desc='FOSS, Material You' }
        [pscustomobject]@{ Platform='Android'; Name='Miniflutt';         Store=''; Fdroid=($fd -f 'miniflutt');  Api='Miniflux API'; Desc='FOSS, F-Droid only, schlank' }
        [pscustomobject]@{ Platform='iOS';     Name='NetNewsWire';       Store=($ios -f 'netnewswire');         Fdroid=''; Api='Google Reader API'; Desc='FOSS-Standard, schnelles Sync' }
        [pscustomobject]@{ Platform='iOS';     Name='Unread';            Store=($ios -f 'unread%20rss');        Fdroid=''; Api='Fever API'; Desc='Freemium, sehr polish, Swipe-Aktionen' }
        [pscustomobject]@{ Platform='iOS';     Name='Reeder Classic';    Store=($ios -f 'reeder%20classic');    Fdroid=''; Api='Google Reader API'; Desc='Paid (~5 EUR), Referenz-Client' }
        [pscustomobject]@{ Platform='iOS';     Name='FluxNews';          Store=($ios -f 'fluxnews');            Fdroid=''; Api='Miniflux API (nativ)'; Desc='FOSS, Podcasts + Offline' }
        [pscustomobject]@{ Platform='Desktop'; Name='Fluent Reader';     Store='https://fluentreader.app/'; Fdroid=''; Api='Google Reader API'; Desc='Win/macOS/Linux, FOSS, tab-basiert' }
        [pscustomobject]@{ Platform='Desktop'; Name='RSS Guard';         Store='https://github.com/Lightcord/RSS-Guard'; Fdroid=''; Api='Fever API'; Desc='Linux/Windows, FOSS' }
        [pscustomobject]@{ Platform='Web';     Name='Miniflux Web-UI';   Store=''; Fdroid=''; Api='nativ'; Desc='Der Server selbst - unter deiner URL' }
        [pscustomobject]@{ Platform='Web';     Name='Fluxjs (Alt-Frontend)'; Store='https://github.com/almerey/fluxjs'; Fdroid=''; Api='Miniflux API'; Desc='Optionales modernes Web-Frontend' }
    )
}

function Show-SysPilotQrCode {
    <# Zeigt einen QR-Code (via qrserver.com-API, nur die URL geht raus)
       in einem kleinen WPF-Fenster zum Abscannen. Fallback: URL-Text. #>
    param([Parameter(Mandatory)][string]$Data, [string]$Title = 'QR-Code')
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase -ErrorAction SilentlyContinue
    $enc = [uri]::EscapeDataString($Data)
    $imgUrl = "https://api.qrserver.com/v1/create-qr-code/?size=420x420&margin=2&data=$enc"
    $png = $null
    try { $png = Invoke-WebRequest -Uri $imgUrl -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop } catch {}
    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$Title" Width="520" Height="640" WindowStartupLocation="CenterScreen"
        Background="#FF1E1E2E" Foreground="#FFE0E0E0" Topmost="True">
  <StackPanel Margin="18">
    <TextBlock Text="$Title" FontSize="17" FontWeight="Bold" Foreground="#FF9CCC65" Margin="0,0,0,4"/>
    <TextBlock Text="Zum Abscannen mit dem Handy - oeffnet die App/Seite direkt." FontSize="11" Foreground="#FF9E9E9E" Margin="0,0,0,10" TextWrapping="Wrap"/>
    <Border Background="White" CornerRadius="8" Padding="10" HorizontalAlignment="Center">
      <Image x:Name="QrImg" Width="380" Height="380"/>
    </Border>
    <TextBox x:Name="TxtData" IsReadOnly="True" Text="$Data" Margin="0,12,0,0" Padding="6"
             Background="#FF14141E" Foreground="#FF4FC3F7" BorderBrush="#FF4A4A6A" FontSize="11" TextWrapping="Wrap"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
      <Button x:Name="BtnCopy" Content="Kopieren" Padding="14,4" Margin="0,0,8,0"/>
      <Button x:Name="BtnOpen" Content="Oeffnen" Padding="14,4" Margin="0,0,8,0"/>
      <Button x:Name="BtnClose" Content="Schliessen" Padding="14,4"/>
    </StackPanel>
  </StackPanel>
</Window>
"@
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
    $win = [Windows.Markup.XamlReader]::Load($reader)
    if ($png) {
        try {
            $ms = New-Object IO.MemoryStream (, $png.Content)
            $bmp = New-Object Windows.Media.Imaging.BitmapImage
            $bmp.BeginInit(); $bmp.StreamSource = $ms; $bmp.CacheOption = 'OnLoad'; $bmp.EndInit()
            $win.FindName('QrImg').Source = $bmp
        } catch {}
    }
    $win.FindName('TxtData').Text = $Data
    $win.FindName('BtnCopy').Add_Click({ Set-Clipboard -Value $Data })
    $win.FindName('BtnOpen').Add_Click({ Start-Process $Data })
    $win.FindName('BtnClose').Add_Click({ $win.Close() })
    [void]$win.ShowDialog()
}

function Show-SysPilotRssClientSetup {
    <# Gefuehrte Client-Einrichtung fuer Miniflux: URL/QR, Plattform-
       Clients (Play/App Store), ADB-Assist, Miniflux-seitige API-
       Aktivierung als ADHS-StepGuide. #>
    # 1) Miniflux-URL aufloesen
    $cfg = Get-SysPilotMinifluxConfig
    $base = [string]$cfg.BaseUrl
    if (-not $base -or $base -eq 'http://localhost:8080') {
        Write-Host "`n  Miniflux-URL fehlt oder ist nur lokal (localhost)." -ForegroundColor Yellow
        Write-Host "  Wenn Miniflux auf Oracle/VPS laeuft: die oeffentliche URL eintragen." -ForegroundColor DarkGray
        $u = Read-SysPilotChoice 'Miniflux-URL (z.B. https://miniflux.example.com, Enter = ueberspringen)'
        if ($u) { $base = $u.Trim().TrimEnd('/'); Set-SysPilotMinifluxConfig -BaseUrl $base }
    }
    $clients = Get-SysPilotRssMobileClients
    while ($true) {
        $platLabel = @{ Android='Android (Play Store/F-Droid)'; iOS='iPhone/iPad (App Store)'; Desktop='Desktop (Win/macOS/Linux)'; Web='Web/Browser' }
        $items = @()
        foreach ($p in @('Android','iOS','Desktop','Web')) {
            $n = @($clients | Where-Object { $_.Platform -eq $p }).Count
            $items += @{ Label="[$p] $($platLabel[$p]) - $n Client(s)"; Color='Cyan'; Tag="plat:$p" }
        }
        $items += @{ Label='QR-Code anzeigen (URL auf Handy scannen)'; Color='Green'; Tag='qr' }
        $items += @{ Label='Miniflux-Verbesserungen (Fever/Google-Reader-API, Integrationen)'; Color='Yellow'; Tag='improve' }
        $items += @{ Label='ADB: Android-Geraet per USB/WLAN einrichten'; Color='Magenta'; Tag='adb' }
        $items += @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'RSS-Client Einrichtung (Miniflux)' -Footer 'Enter = Aktion, Esc = zurueck'
        if ($null -eq $sel) { return }
        if ($sel -like 'plat:*') {
            $p = $sel.Substring(5)
            $list = @($clients | Where-Object { $_.Platform -eq $p })
            $mi = @($list | ForEach-Object {
                $store = if ($_.Store) { $_.Store } elseif ($_.Fdroid) { $_.Fdroid } else { $null }
                @{ Label="$($_.Name) [$($_.Api)] - $($_.Desc)"; Color='White'; Tag=@{ Client=$_; Url=$store } }
            }) + @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
            $c = Show-SysPilotArrowMenu -Items $mi -Title "$p - Reader-Clients" -Footer 'Enter = Store-Page oeffnen, Esc = zurueck'
            if ($c -and $c['Url']) {
                if ($c['Url']) { Start-Process $c['Url'] }
                $cli = $c['Client']
                Write-Host "`n  Client: $($cli.Name)" -ForegroundColor Cyan
                Write-Host "  API-Typ: $($cli.Api)" -ForegroundColor DarkGray
                Write-Host "  Und in Miniflux: Settings > Integrations > Fever API oder Google Reader API aktivieren" -ForegroundColor Yellow
                Write-Host "  (Benutzer + Passwort dort selbst vergeben - NICHT das Miniflux-Login)." -ForegroundColor DarkGray
                if ($base -and $base -ne 'http://localhost:8080') {
                    Write-Host "  Server-URL fuer die App: $base" -ForegroundColor Green
                    Set-Clipboard -Value $base
                }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            continue
        }
        switch ($sel) {
            'qr' {
                if (-not $base -or $base -eq 'http://localhost:8080') { Write-Host '  Erst Miniflux-URL eintragen (siehe oben).' -ForegroundColor Yellow; Read-SysPilotChoice 'Weiter' | Out-Null; continue }
                Show-SysPilotQrCode -Data $base -Title "Miniflux: $base"
            }
            'improve' {
                Write-Host "`n  Miniflux-Verbesserungen (alles in der Web-UI unter Settings):" -ForegroundColor Cyan
                Write-Host "  - Integrations > Fever API: fuer FeedMe/Unread/Reeder aktivieren" -ForegroundColor White
                Write-Host "  - Integrations > Google Reader API: fuer Capy/NetNewsWire/Fluent Reader" -ForegroundColor White
                Write-Host "  - Integrations > Wallabag/Instapaper/Pinboard: Artikel-Sammeln" -ForegroundColor White
                Write-Host "  - Settings > API Keys: fuer native Miniflux-Clients (FluxNews, Fleuron)" -ForegroundColor White
                Write-Host "  - Appearance: Theme (Light/Dark/System), kompakte Liste" -ForegroundColor White
                Write-Host "  - Cron: Miniflux pollt Feeds selbst (docker-compose Setting POLL_FREQUENCY)" -ForegroundColor DarkGray
                Write-Host "`n  Alle Client-Apps oben testen die Verbindung mit der Miniflux-URL." -ForegroundColor DarkGray
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'adb' { Show-SysPilotAdbRssAssist }
        }
    }
}

function Show-SysPilotAdbRssAssist {
    <# ADB-Assist: Geraet erkennen, Play-Store-Intent auf dem Handy
       oeffnen (kein Tippen noetig), sonst QR-Fallback erklaert. #>
    $adb = (Get-Command adb -ErrorAction SilentlyContinue).Source
    if (-not $adb) {
        Write-Host "`n  adb nicht gefunden - installation optional (nur Convenience)." -ForegroundColor Yellow
        $w = Get-SysPilotWingetExe
        if ($w -and (Confirm-SysPilot 'Android Platform-Tools (adb) per winget installieren?')) {
            [void](Invoke-SysPilotMonitoredProcess -FilePath $w -ArgList @('install','--id','Google.PlatformTools','--exact','--accept-package-agreements','--accept-source-agreements','--disable-interactivity') -Label 'adb' -TimeoutSec 600)
            $adb = (Get-Command adb -ErrorAction SilentlyContinue).Source
        }
        if (-not $adb) { Write-Host '  uebersprungen - QR-Code-Weg bleibt.' -ForegroundColor DarkGray; Read-SysPilotChoice 'Weiter' | Out-Null; return }
    }
    Write-Host "`n  adb: $adb" -ForegroundColor Cyan
    Write-Host "  Bitte Android-Geraet per USB anschliessen (USB-Debugging an)" -ForegroundColor White
    Write-Host "  oder Wireless Debugging Pairing nutzen." -ForegroundColor DarkGray
    $devs = & $adb devices 2>$null | Select-String "`tdevice$"
    if (-not $devs) {
        Write-Host "  Kein Geraet erkannt - zuerst am Handy 'USB-Debugging erlauben' bestaetigen." -ForegroundColor Yellow
        Read-SysPilotChoice 'Enter zum erneuten Pruefen, oder leer = abbrechen' | Out-Null
        return
    }
    foreach ($d in $devs) { Write-Host "  Geraet: $(($d.Line -split "`t")[0])" -ForegroundColor Green }
    # Play-Store-Suche direkt aufs Geraet feuern (market://search - kein
    # Package-Name noetig, oeffnet die Trefferliste in der Play Store App)
    $apps = @('capy reader','fluxnews miniflux','feedme rss')
    foreach ($q in $apps) {
        Write-Host "`n  Oeffne Play Store-Suche auf dem Handy: $q ..." -ForegroundColor Cyan
        $enc = [uri]::EscapeDataString($q)
        & $adb shell am start -a android.intent.action.VIEW -d "market://search?q=$enc&c=apps" 2>$null | Out-Null
        Start-Sleep -Milliseconds 800
    }
    Write-Host "`n  Fertig - die Play Store-App sollte sich mit den Suchergebnissen geoeffnet haben." -ForegroundColor Green
    Write-Host "  Danach: App oeffnen > Miniflux-Server > URL + API-Credentials eintragen." -ForegroundColor DarkGray
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
}

# =====================================================================
# TV-ASSISTENT (Android TV / Fire TV): ADB, Debloat, Sideload, Apps
# =====================================================================

function Get-SysPilotAdbExe {
    <# adb-Pfad: PATH, Platform-Tools uebliche Orte, WinGet-Links. #>
    $cmd = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $cmd2 = Get-Command adb -ErrorAction SilentlyContinue
    if ($cmd2 -and $cmd2.Source -match '\.exe$') { return $cmd2.Source }
    $cands = @(
        "$env:LOCALAPPDATA\Microsoft\WinGet\Links\adb.exe",
        "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe",
        "C:\Android\platform-tools\adb.exe",
        "C:\platform-tools\adb.exe"
    )
    foreach ($c in $cands) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}

function Invoke-SysPilotAdbShell {
    <# adb shell-Aufruf gegen das erste Geraet (oder -Serial). #>
    param([Parameter(Mandatory)][string]$Command, [string]$Serial = '')
    $adb = Get-SysPilotAdbExe
    if (-not $adb) { return @{ Ok=$false; Out=''; Err='adb nicht installiert' } }
    $argL = @()
    if ($Serial) { $argL += @('-s', $Serial) }
    $argL += @('shell', $Command)
    $out = & $adb @argL 2>&1 | Out-String
    return @{ Ok=($LASTEXITCODE -eq 0); Out=$out.Trim(); Err='' }
}

function Connect-SysPilotTvAdb {
    <# ADB-Verbindung zu Android TV / Fire TV aufbauen.
       Fire TV: ADB Debugging an -> Port 5555.
       Android TV 11+: Wireless Debugging -> Pairing noetig. #>
    $adb = Get-SysPilotAdbExe
    if (-not $adb) {
        Write-Host "  adb fehlt - Platform-Tools installieren?" -ForegroundColor Yellow
        $w = Get-SysPilotWingetExeLocal
        if ($w -and (Confirm-SysPilot 'Android Platform-Tools per winget installieren?')) {
            [void](Invoke-SysPilotMonitoredProcess -FilePath $w -ArgList @('install','--id','Google.PlatformTools','--exact','--accept-package-agreements','--accept-source-agreements','--disable-interactivity') -Label 'adb' -TimeoutSec 600)
            $adb = Get-SysPilotAdbExe
        }
        if (-not $adb) { Write-Host '  uebersprungen.' -ForegroundColor DarkGray; return $null }
    }
    $ip = Read-SysPilotChoice 'TV-IP-Adresse (z.B. 192.168.1.50, Enter = abbruch)'
    if (-not $ip) { return $null }
    $ip = $ip.Trim()
    Write-Host "  Versuche adb connect ${ip}:5555 ..." -ForegroundColor Cyan
    $r = & $adb connect "${ip}:5555" 2>&1 | Out-String
    Write-Host "  $($r.Trim())" -ForegroundColor DarkGray
    if ($r -match 'connected') {
        Start-Sleep -Milliseconds 500
        $devs = & $adb devices 2>$null | Select-String "`tdevice$"
        return @{ Ok=$true; Serial=(($devs | Select-Object -First 1).Line -split "`t")[0]; Note='5555' }
    }
    # Android TV 11+: Wireless-Debugging-Pairing
    Write-Host "  5555 klappt nicht - Wireless-Debugging-Pairing (Android TV 11+)?" -ForegroundColor Yellow
    Write-Host "  Am TV: Einstellungen > System > Entwickleroptionen > Wireless debugging > Pairing" -ForegroundColor DarkGray
    $pp = Read-SysPilotChoice 'Pairing-IP:Port (z.B. 192.168.1.50:37123, Enter = ueberspringen)'
    if ($pp) {
        $code = Read-SysPilotChoice 'Pairing-Code (6-stellig, steht am TV)'
        if ($code) {
            $pr = & $adb pair $pp.Trim() $code.Trim() 2>&1 | Out-String
            Write-Host "  pair: $($pr.Trim())" -ForegroundColor DarkGray
            if ($pr -match 'Successfully') {
                Start-Sleep -Seconds 1
                $r2 = & $adb connect "${ip}:5555" 2>&1 | Out-String
                Write-Host "  connect: $($r2.Trim())" -ForegroundColor DarkGray
                $devs = & $adb devices 2>$null | Select-String "`tdevice$"
                if ($devs) { return @{ Ok=$true; Serial=(($devs | Select-Object -First 1).Line -split "`t")[0]; Note='pairing' } }
            }
        }
    }
    Write-Host "  Nicht verbunden. TV pruefen: ADB/Wireless Debugging aktiviert + gleiche WLAN." -ForegroundColor Yellow
    return $null
}

function Get-SysPilotTvPackages {
    <# Paketliste vom verbundenen TV + Hersteller-Erkennung. #>
    param([string]$Serial = '')
    $mfr = (Invoke-SysPilotAdbShell -Command 'getprop ro.product.manufacturer' -Serial $Serial).Out
    $model = (Invoke-SysPilotAdbShell -Command 'getprop ro.product.model' -Serial $Serial).Out
    $pkgs = (Invoke-SysPilotAdbShell -Command 'pm list packages' -Serial $Serial).Out
    $list = @($pkgs -split "`n" | Where-Object { $_ -match '^package:' } | ForEach-Object { $_ -replace '^package:','' } | Where-Object { $_ })
    return @{ Manufacturer=$mfr; Model=$model; Packages=$list }
}

function Get-SysPilotTvBloatCandidates {
    <# Heuristische Bloat-Kandidaten (deaktivierbar, nichts wird geloescht).
       Konservativ: nur Analytics/Ads/Amazon-Services/User-Apps,
       niemals System-Apps (android.*, com.android.*, launcher, keyboards). #>
    param([string[]]$Packages)
    $sys = '^(android\.|com\.android\.|com\.google\.android\.|com\.amazon\.device\.|com\.amazon\.fireos|com\.amazon\.system|com\.amazon\.kindle|com\.amazon\.alexa\.|com\.amazon\.firelauncher|com\.amazon\.avod|com\.amazon\.vision\.factory|com\.amazon\.ims|com\.amazon\.dcp|com\.amazon\.firetv\.usagereporter|com\.amazon\.neodelegate|com\.amazon\.fireos\.sharedlibrary|com\.amazon\.fireos\.config|com\.amazon\.fireos\.location|com\.amazon\.fireos\.ota|com\.amazon\.fireos\.platform|com\.amazon\.fireos\.pithos|com\.amazon\.tcomm|vendor\.|persist\.)'
    $bloatPat = '(?i)(analytics|metric|crashlytics|ads|advert|sponsor|promo|telemetry|usage|tracker|beacon|impression|recommendation|contentrecommend|spotlight|merch|shopping|appstore.*recommend|kids.*promo|freevee|kindle|audible|photos|music\.amazon|gaming|games|alexa.*(service|comm)|imdb|goodreads|wikipedia|etsy|IMDb)'
    $out = @()
    foreach ($p in $Packages) {
        if ($p -match $sys) { continue }
        if ($p -match $bloatPat) { $out += $p }
    }
    return $out
}

function Invoke-SysPilotTvDebloat {
    <# CleanYourTV-aehnlicher Debloat: pm disable-user (REVERsibel,
       nichts wird deinstalliert). Backup + Restore-Datei. #>
    param([string]$Serial = '')
    $info = Get-SysPilotTvPackages -Serial $Serial
    if ($info.Packages.Count -eq 0) { Write-Host '  Keine Pakete gelesen - Geraet pruefen.' -ForegroundColor Red; return }
    Write-Host "  Geraet: $($info.Manufacturer) $($info.Model) - $($info.Packages.Count) Pakete" -ForegroundColor Cyan
    $cands = @(Get-SysPilotTvBloatCandidates -Packages $info.Packages)
    if ($cands.Count -eq 0) { Write-Host '  Keine Bloat-Kandidaten gefunden (Heuristik konservativ).' -ForegroundColor Green; return }
    Write-Host "  $($cands.Count) Bloat-Kandidaten gefunden:" -ForegroundColor Yellow
    $cands | Select-Object -First 40 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    if ($cands.Count -gt 40) { Write-Host "    ... +$($cands.Count-40) weitere" -ForegroundColor DarkGray }
    # Multi-Select
    $items = @($cands | ForEach-Object { @{ Label=$_; Color='White'; Tag=$_; Checked=$true } })
    $sel = @(Show-SysPilotMultiSelectMenu -Items $items -Title 'Bloatware deaktivieren (pm disable-user, reversibel)' -Footer 'Leertaste=Haken, Enter=deaktivieren, Esc=abbruch')
    if ($sel.Count -eq 0) { Write-Host '  Abgebrochen.' -ForegroundColor DarkGray; return }
    # Backup der Pakete
    $dir = Join-Path $env:LOCALAPPDATA 'SysPilot\tv-debloat'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $devName = ($info.Model -replace '[^\w]','_')
    $backup = Join-Path $dir "$devName-$stamp.json"
    @{ Device="$($info.Manufacturer) $($info.Model)"; Disabled=@(); Packages=$info.Packages } | ConvertTo-Json -Depth 4 | Set-Content $backup -Encoding UTF8
    $ok = 0; $fail = 0
    foreach ($pkg in $sel) {
        $r = Invoke-SysPilotAdbShell -Command "pm disable-user --user 0 $pkg" -Serial $Serial
        if ($r.Ok -and $r.Out -match 'disabled') { $ok++ } else { $fail++ }
        Write-Host "  $(if($r.Out -match 'disabled'){'[OK]'}else{'[--]'}) $pkg" -ForegroundColor $(if($r.Out -match 'disabled'){'Green'}else{'DarkGray'})
    }
    # Backup aktualisieren
    try {
        $b = Get-Content $backup -Raw | ConvertFrom-Json
        $b.Disabled = @($sel)
        $b | ConvertTo-Json -Depth 4 | Set-Content $backup -Encoding UTF8
    } catch {}
    Write-Host "`n  Fertig: $ok deaktiviert, $fail uebersprungen/fehlgeschlagen." -ForegroundColor Green
    Write-Host "  Nichts wurde geloescht - Restore: pm enable <pkg> oder SysPilot > TV > Debloat-Rueckgaengig." -ForegroundColor DarkGray
    Write-Host "  Backup: $backup" -ForegroundColor DarkGray
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
}

function Restore-SysPilotTvDebloat {
    <# Letzte Debloat-Sitzung rueckgaengig machen (pm enable). #>
    param([string]$Serial = '')
    $dir = Join-Path $env:LOCALAPPDATA 'SysPilot\tv-debloat'
    if (-not (Test-Path $dir)) { Write-Host '  Kein Debloat-Backup vorhanden.' -ForegroundColor DarkGray; return }
    $latest = Get-ChildItem $dir -Filter '*.json' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) { return }
    $b = Get-Content $latest.FullName -Raw | ConvertFrom-Json
    if (-not $b.Disabled -or @($b.Disabled).Count -eq 0) { Write-Host '  Backup enthaelt keine deaktivierten Pakete.' -ForegroundColor DarkGray; return }
    Write-Host "  Restore: $($b.Device) - $(@($b.Disabled).Count) Pakete" -ForegroundColor Cyan
    foreach ($pkg in @($b.Disabled)) {
        $r = Invoke-SysPilotAdbShell -Command "pm enable $pkg" -Serial $Serial
        Write-Host "  $(if($r.Out -match 'enabled'){'[OK]'}else{'[--]'}) $pkg" -ForegroundColor $(if($r.Out -match 'enabled'){'Green'}else{'DarkGray'})
    }
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
}

function Install-SysPilotTvApk {
    <# APK auf den TV sideloaden: Download (SmartFile) -> adb install. #>
    param([Parameter(Mandatory)][string]$Url, [string]$Serial = '', [string]$Label = 'APK')
    $adb = Get-SysPilotAdbExe
    if (-not $adb) { Write-Host '  adb fehlt.' -ForegroundColor Red; return }
    $tmp = Join-Path $env:TEMP ('syspilot-tv-' + [IO.Path]::GetFileName($Url))
    Write-Host "  Lade $Label ..." -ForegroundColor Cyan
    $r = Invoke-SysPilotSmartFileDownload -Url $Url -OutFile $tmp
    if (-not $r.Ok -or -not (Test-Path $tmp)) { Write-Host "  Download fehlgeschlagen: $($r.Error)" -ForegroundColor Red; return }
    $sz = [math]::Round((Get-Item $tmp).Length/1MB,1)
    Write-Host "  Installiere $sz MB auf dem TV ..." -ForegroundColor Cyan
    $argL = @(); if ($Serial) { $argL += @('-s',$Serial) }
    $argL += @('install','-r',$tmp)
    $o = & $adb @argL 2>&1 | Out-String
    if ($o -match 'Success') { Write-Host "  [OK] $Label installiert" -ForegroundColor Green }
    else { Write-Host "  [!] adb install: $($o.Trim())" -ForegroundColor Yellow; Write-Host '  Tipp: "Apps aus unbekannten Quellen" am TV erlauben.' -ForegroundColor DarkGray }
}

function Get-SysPilotTvApps {
    <# Kuratierter TV-App-Katalog. Url = direkter APK-/Download-Link
       (wo vorhanden), Page = Informationsseite. #>
    return @(
        [pscustomobject]@{ Name='KodiRoll (APK, Auto-Setup)'; Kind='apk'; Url='https://rolling-playforfun.de/app/kodiroll.apk'; Page='https://rolling-playforfun.de/app/'; Desc='Kodi-Fork: Wizard installiert Kodi + Addons (xstream, PlayForFun, Live-TV) automatisch' }
        [pscustomobject]@{ Name='KodiRoll 22 (neuere APK)';  Kind='apk'; Url='https://rolling-playforfun.de/app/KODiRoll-22.apk'; Page='https://rolling-playforfun.de/app/'; Desc='KodiRoll ab Android 7 - Build 22' }
        [pscustomobject]@{ Name='KodiRoll (Windows: Kodi Build)'; Kind='page'; Url=''; Page='https://tinyurl.com/kodiroll'; Desc='Windows: Kodi installieren > Settings > File Manager > Source https://tinyurl.com/kodiroll > plugin.program.kodiroll.zip > Kodiroll Universal Build' }
        [pscustomobject]@{ Name='VYPN (Browser+VPN+Media-Center)'; Kind='apk'; Url='https://www.vypn.net'; Page='https://www.vypn.net/download'; Desc='Browser mit VPN + Media-Center fuer mhub-Seiten; Windows-Version: vypn.net/download' }
        [pscustomobject]@{ Name='SquiffNet VPN (DocSquiffy, FREE)'; Kind='page'; Url=''; Page='https://play.google.com/store/search?q=squiffnet%20vpn&c=apps'; Desc='Kostenlos, taeglicher PIN, WireGuard - Package com.firesend.vpn' }
        [pscustomobject]@{ Name='StreamFlix (TV-APK)';          Kind='apk'; Url='https://rolling-playforfun.de/app/streamflix-v1.7.231-only-tv.apk'; Page='https://rolling-playforfun.de/app/'; Desc='Streaming-App, TV-Variante' }
        [pscustomobject]@{ Name='OTT TV';                        Kind='apk'; Url='https://rolling-playforfun.de/app/OTT%20TV%20v1.7.2.2%20build%2025012521%20%5BFileCR%5D.apk'; Page='https://rolling-playforfun.de/app/'; Desc='IPTV-Manager/Player' }
        [pscustomobject]@{ Name='Downloader (AFTVnews)';         Kind='page'; Url=''; Page='https://www.aftvnews.com/downloader/'; Desc='Der Standard-Sideload-Client: Downloader-Codes + URLs am TV eingeben' }
        [pscustomobject]@{ Name='Flix Vision';                   Kind='page'; Url=''; Page='https://firestickhacks.com/install-flix-vision-apk-on-firestick/'; Desc='Streaming-App - ACHTUNG: VirusTotal meldete 23/63 Funde; Downloader-Code 8937718. Nutzung auf eigene Gefahr.' }
        [pscustomobject]@{ Name='TechDoctorUK Downloads';        Kind='page'; Url=''; Page='https://techdoctoruk.com/downloads'; Desc='APK-Sammlung (geprueft): Cinema HQ, Stremio, Sportzfy u.v.m.' }
        [pscustomobject]@{ Name='DocSquiffy Downloads';          Kind='page'; Url=''; Page='https://www.docsquiffy.com/downloads'; Desc='Apps + Squiffix-Transfer-Codes (App > Transfer > Code am TV eingeben)' }
        [pscustomobject]@{ Name='XMedia / Adult-Apps';           Kind='page'; Url=''; Page='https://techdoctoruk.com/downloads'; Desc='Adult-Streaming-APKs ueber die TechDoctorUK-Download-Seite (Suche: xmedia)' }
        [pscustomobject]@{ Name='SmartTube (YouTube ohne Ads)';  Kind='apk'; Url='https://github.com/yuliskov/SmartTube/releases/download/latest/smarttube_stable.apk'; Page='https://smarttubeapp.github.io/'; Desc='YouTube-Client fuer TV: keine Ads, keine Google-Account-Pflicht, Sidebar, Sponsored-Channels ausblendbar. Ersetzt die YouTube-App' }
        [pscustomobject]@{ Name='Amazon SYTV Bridge (Fire TV)';   Kind='apk'; Url='https://github.com/yuliskov/SmartTube/releases/download/latest/Amazon_SYTV_Bridge.apk'; Page='https://smarttubeapp.github.io/'; Desc='Fire-TV-Bridge: uebernimmt YouTube-Intents/Alexa/Voice-Search und oeffnet SmartTube. VORHER offizielle YouTube-App deinstallieren (App > Verwalten > YouTube > Deinstallieren)' }
        [pscustomobject]@{ Name='ATV SYTV Bridge (Android TV)';   Kind='apk'; Url='https://github.com/yuliskov/SmartTube/releases/download/latest/ATV_SYTV_Bridge.apk'; Page='https://smarttubeapp.github.io/'; Desc='Android-TV/Google-TV-Bridge: YouTube-Tile, Fernbedienungs-YouTube-Taste und Sprachsuche oeffnen SmartTube statt der Original-App' }
        [pscustomobject]@{ Name='TroyPoint (App-Quelle)';         Kind='page'; Url=''; Page='https://troypoint.com/best-apps/'; Desc='Fire-TV/Android-TV-Standardquelle: kuratierte APKs + Schritt-Anleitungen (Kodi-Forks, IPTV, VPN, Launcher). Am TV: Downloader-App + Link aus Artikel' }
        [pscustomobject]@{ Name='F-Droid (FOSS-Store)';          Kind='apk'; Url='https://f-droid.org/F-Droid.apk'; Page='https://f-droid.org/'; Desc='Der Open-Source-Android-Store: nur FOSS-Apps, signierte Builds, kein Tracking. Einmal installieren, dann alles FOSS aus dem Store' }
        [pscustomobject]@{ Name='Obtainium (FOSS-Installer)';    Kind='apk'; Url='https://github.com/ImranR98/Obtainium/releases/latest/download/Obtainium.apk'; Page='https://obtainium.imranr.dev/'; Desc='Installiert Apps direkt von GitHub/F-Droid/Codeberg - mit Auto-Updates, kein Store noetig. Ideal fuer F-Droid-Alternative + GitHub-Releases' }
        [pscustomobject]@{ Name='Aurora Store (Play-Store-Client)'; Kind='page'; Url=''; Page='https://auroraoss.com/downloads/'; Desc='Open-Source Play-Store-Client: Apps ohne Google-Account, anonym. APK-Download von AuroraOSS GitLab' }
        [pscustomobject]@{ Name='APKMirror';                     Kind='page'; Url=''; Page='https://www.apkmirror.com/'; Desc='Sauberste APK-Quelle: signatur-geprueft, viele Versionen. Am TV: APK auf PC laden, per adb installieren' }
        [pscustomobject]@{ Name='APKPure';                       Kind='page'; Url=''; Page='https://apkpure.com/'; Desc='Grosse APK-Datenbank, direkter Download. Achtung: werbefrei-nutzen, Quellen pruefen' }
        [pscustomobject]@{ Name='Aptoide';                       Kind='page'; Url=''; Page='https://en.aptoide.com/'; Desc='Alternative App-Store (eigene Stores). APK direkt vom Aptoide-Client' }
    )
}

function Get-SysPilotTvLaunchers {
    <# Launcher fuer Android TV / Google TV (Fire OS erlaubt KEIN
       Drittanbieter-Home - dort bleibt Amazon-Launcher, Debloat
       bringt trotzdem Ruhe). Vergleichs-Infos pro Launcher. #>
    return @(
        [pscustomobject]@{ Name='Monet Launcher';        Url='https://play.google.com/store/search?q=monet%20launcher&c=apps'; Desc='PAID (~10 EUR, einmallig):moderner Netflix-aehnlicher Aufbau, Rows/Listen, Apps+Games+Netflix-Inhalte, sehr aufgeraeumtes Look-and-Feel. Testsieger-Optik' }
        [pscustomobject]@{ Name='Projectivy Launcher';   Url='https://play.google.com/store/search?q=projectivy%20launcher&c=apps'; Desc='PAID (~3 EUR): klassischer Android-TV-Launcher, App-Listen, Widget-Support,(opts) Netflix-Zeile. Bewaehrt, schlicht' }
        [pscustomobject]@{ Name='FLauncher';            Url='https://f-droid.org/packages/com.flauncher.tvlauncher/'; Desc='KOSTENLOS/FOSS: schlank, schnell, Android-TV-Optik, Widgets, F-Droid-Install ohne Play Store' }
        [pscustomobject]@{ Name='ATV Launcher';         Url='https://play.google.com/store/search?q=atv%20launcher&c=apps'; Desc='KOSTENLOS: Open-Source-Optik ( Lawnchair-Style ), sehr nahe am Google-TV-Standard' }
        [pscustomobject]@{ Name='Wolf Launcher';        Url='https://play.google.com/store/search?q=wolf%20launcher&c=apps'; Desc='KOSTENLOS: modern, Karten-Design, Widgets, benutzerdefinierbar - beliebte Alternative zu Projectivy' }
        [pscustomobject]@{ Name='App Starter (Pro)';     Url='https://play.google.com/store/search?q=app%20starter%20fire%20tv&c=apps'; Desc='KOSTENLOS + Pro (~5 EUR): klassischstes Fire-TV-Feeling, eigene App-Order, kein Abo' }
        [pscustomobject]@{ Name='Weitere FOSS-Launcher (F-Droid)'; Url='https://f-droid.org/index.php?q=launcher'; Desc='F-Droid-Suche "launcher": zusaetzliche Open-Source-Optionen ohne Play Store' }
    )
}

function Show-SysPilotTvSetup {
    <# TV-Assistent: ADB-Verbindung, Debloat (CleanYourTV-Stil),
       Sideload (APK + Downloader-Codes), App-Katalog, Launcher. #>
    $serial = ''
    while ($true) {
        $adb = Get-SysPilotAdbExe
        $devs = @()
        if ($adb) { $devs = @(& $adb devices 2>$null | Select-String "`tdevice$" | ForEach-Object { ($_.Line -split "`t")[0] }) }
        $items = @(
            @{ Label="ADB: " + $(if($adb){"installiert"}else{"FEHLT (Platform-Tools)"}) + $(if($devs.Count){" | Geraet: $($devs -join ', ')"}else{" | kein Geraet"}); Color=$(if($devs.Count){'Green'}else{'Yellow'}); Tag='status' },
            @{ Label='ADB verbinden (TV-IP, Pairing, Fire-TV-Port 5555)'; Color='Cyan'; Tag='connect' },
            @{ Label='Debloat: Bloatware deaktivieren (CleanYourTV-Stil, reversibel)'; Color='Yellow'; Tag='debloat' },
            @{ Label='Debloat rueckgaengig machen (pm enable, letztes Backup)'; Color='DarkYellow'; Tag='restore' },
            @{ Label='Apps installieren (KodiRoll, VYPN, SquiffNet, StreamFlix, OTT ...)'; Color='Green'; Tag='apps' },
            @{ Label='Launcher waehlen (Projectivy, FLauncher, ATV ...)'; Color='Green'; Tag='launcher' },
            @{ Label='Fire-TV-Sideload: Downloader-Codes erklaert'; Color='Cyan'; Tag='firetv' },
            @{ Label='Smartphone/Tablet (Android + iOS): Sideload-Guide'; Color='Green'; Tag='phone' },
            @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
        )
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'TV-Setup (Android TV / Fire TV / Smartphone)' -Footer 'Enter = Aktion, Esc = zurueck'
        if ($null -eq $sel) { return }
        switch ($sel) {
            'status' { continue }
            'connect' {
                $c = Connect-SysPilotTvAdb
                if ($c -and $c.Ok) { $script:_tvSerial = $c.Serial; Write-Host "  Verbunden: $($c.Serial) ($($c.Note))" -ForegroundColor Green }
                continue
            }
            'debloat' {
                if (-not $adb -or -not $devs.Count) { Write-Host '  Erst ADB verbinden.' -ForegroundColor Yellow; Read-SysPilotChoice 'Weiter' | Out-Null; continue }
                Invoke-SysPilotTvDebloat -Serial $script:_tvSerial
                continue
            }
            'restore' {
                if (-not $adb -or -not $devs.Count) { Write-Host '  Erst ADB verbinden.' -ForegroundColor Yellow; Read-SysPilotChoice 'Weiter' | Out-Null; continue }
                Restore-SysPilotTvDebloat -Serial $script:_tvSerial
                continue
            }
            'apps' {
                $apps = @(Get-SysPilotTvApps)
                $ai = @($apps | ForEach-Object {
                    $u = if ($_.Url) { $_.Url } else { $_.Page }
                    @{ Label="$($_.Name) - $($_.Desc)"; Color='White'; Tag=@{ App=$_; Url=$u } }
                }) + @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
                $a = Show-SysPilotArrowMenu -Items $ai -Title 'TV-Apps (Sideload/Katalog)' -Footer 'Enter = auswaehlen'
                if (-not $a) { continue }
                $ap = $a['App']; $u = $a['Url']
                Write-Host "`n  $($ap.Name)" -ForegroundColor Cyan
                Write-Host "  $($ap.Desc)" -ForegroundColor DarkGray
                $acts = @()
                if ($ap.Kind -eq 'apk' -and $ap.Url) { $acts += @{ Label='APK auf TV installieren (adb)' ; Color='Green'; Tag='adbinstall' } }
                if ($ap.Url -or $ap.Page) { $acts += @{ Label='Link im Browser oeffnen'; Color='Cyan'; Tag='open' } }
                if ($ap.Url -or $ap.Page) { $acts += @{ Label='QR-Code anzeigen (am TV/Handy scannen)'; Color='Magenta'; Tag='qr' } }
                $acts += @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
                $act = Show-SysPilotArrowMenu -Items $acts -Title 'Aktion' -Footer 'Enter = Aktion'
                if (-not $act) { continue }
                switch ($act) {
                    'adbinstall' {
                        if (-not $devs.Count) { Write-Host '  Erst ADB verbinden.' -ForegroundColor Yellow; Read-SysPilotChoice 'Weiter' | Out-Null }
                        else { Install-SysPilotTvApk -Url $ap.Url -Serial $script:_tvSerial -Label $ap.Name }
                    }
                    'open' { Start-Process $(if($ap.Url){$ap.Url}else{$ap.Page}) }
                    'qr'    { Show-SysPilotQrCode -Data $(if($u){$u}else{$ap.Page}) -Title $ap.Name }
                }
                continue
            }
            'launcher' {
                $ll = @(Get-SysPilotTvLaunchers)
                $li = @($ll | ForEach-Object { @{ Label="$($_.Name) - $($_.Desc)"; Color='Green'; Tag=@{ L=$_; Url=$_.Url } } }) + @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
                $l = Show-SysPilotArrowMenu -Items $li -Title 'TV-Launcher (Android TV/Google TV)' -Footer 'Enter = Store oeffnen'
                if ($l) {
                    Start-Process $l['Url']
                    Write-Host "`n  $($l['L'].Name): $($l['L'].Desc)" -ForegroundColor DarkGray
                    Write-Host "  Installieren > als Home-App setzen. Auf Fire TV bleibt Amazon-Launcher (Fire OS erlaubt es nicht)." -ForegroundColor Yellow
                    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
                }
                continue
            }
            'firetv' {
                Write-Host "`n  Fire-TV-Sideload Schritt-fuer-Schritt (ADHS):" -ForegroundColor Cyan
                Write-Host "  1) Am TV: Einstellungen > Mein Fire TV > Entwickleroptionen" -ForegroundColor White
                Write-Host "     > ADB-Debugging AN (Port 5555 oeffnet sich)" -ForegroundColor White
                Write-Host "  2) Hier: 'ADB verbinden' mit der TV-IP" -ForegroundColor White
                Write-Host "  3) Oder ohne ADB: 'Downloader'-App aus dem Amazon Appstore" -ForegroundColor White
                Write-Host "     installieren, dann im Downloader Codes/URLs eingeben:" -ForegroundColor White
                Write-Host "     - Flix Vision: Code 8937718 (Achtung: VirusTotal-Warnung!)" -ForegroundColor Yellow
                Write-Host "     - KodiRoll: URL rolling-playforfun.de/app/kodiroll.apk" -ForegroundColor White
                Write-Host "     - VYPN/SquiffNet/StreamFlix: Links aus dem Apps-Katalog" -ForegroundColor White
                Write-Host "     - Weitere Apps: troypoint.com/best-apps (APK-Links in den Artikeln)" -ForegroundColor White
                Write-Host "     - FOSS-Apps: einmalig F-Droid.apk installieren, dann alles Open-Source" -ForegroundColor Green
                Write-Host "  3b) YouTube ersetzen (SmartTube):" -ForegroundColor Cyan
                Write-Host "     1) Settings > Apps > YouTube > Deinstallieren (Updates loeschen)" -ForegroundColor White
                Write-Host "     2) SmartTube APK installieren (Katalog > 'SmartTube')" -ForegroundColor White
                Write-Host "     3) Amazon SYTV Bridge installieren - YouTube-Taste/Alexa oeffnen SmartTube" -ForegroundColor White
                Write-Host "  4) DocSquiffy-Apps: 'Squiffix'-App > Transfer > Code eingeben" -ForegroundColor White
                Write-Host "`n  Hinweis: Es liegt in deiner Entscheidung, welche Apps du nutzt - " -ForegroundColor DarkGray
                Write-Host "  SysPilot stellt nur die Downloads/Tools bereit, keine Inhaltsbewertung." -ForegroundColor DarkGray
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
                continue
            }
            'phone' {
                Show-SysPilotMobileSideload
                continue
            }
        }
    }
}

function Show-SysPilotSecLabSetup {
    <# Security-Lab-Setup: Kali Linux in WSL + unzensiertes Modell.
       Nur fuer autorisierte/defensive Security-Arbeit (eigene Systeme,
       CTF, Learning) - der Guide fragt das bei Bedarf ab. #>
    while ($true) {
        Write-Host ""
        Write-Host "  ========================================================" -ForegroundColor Cyan
        Write-Host "           SYSPilot SECURITY-LAB" -ForegroundColor Cyan
        Write-Host "  ========================================================" -ForegroundColor Cyan
        $wslOk = $null -ne (Get-Command wsl.exe -ErrorAction SilentlyContinue)
        $kali = $false
        if ($wslOk) { try { $kali = (@(Get-SysPilotWslDistros) -contains 'kali-linux') } catch {} }
        Write-Host ("  WSL: {0} | Kali Linux: {1}" -f $(if($wslOk){'vorhanden'}else{'FEHLT'}), $(if($kali){'installiert'}else{'nicht installiert'})) -ForegroundColor $(if($kali){'Green'}else{'Yellow'})
        Write-Host "  Hinweis: Nur eigene Systeme/Netzwerke, autorisierte Tests, CTF, Learning." -ForegroundColor DarkYellow
        Write-Host ""

        $items = @(
            @{ Label = 'Kali Linux in WSL installieren (~1-2 GB Download)'; Color = 'Green';  Tag = 'kali' }
            @{ Label = 'Kali starten (wsl -d kali-linux)';                     Color = 'Cyan';   Tag = 'kaliopen' }
            @{ Label = 'Unzensiertes Modell suchen + laden (abliterated/heretic/uncensored)'; Color = 'Magenta'; Tag = 'model' }
            @{ Label = 'KurzeSecurity-Einfuehrung + Rechts-Hinweise';          Color = 'Yellow'; Tag = 'guide' }
            @{ Label = 'WSL-Verwaltung (alle Distros/Updates)';                Color = 'DarkGray'; Tag = 'wslmenu' }
            @{ Label = 'Zurueck';                                              Color = 'DarkGray'; Tag = 'back' }
        )
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'Security-Lab' -Footer 'Pfeiltasten, Enter = auswaehlen, Esc = zurueck'
        if (-not $sel -or $sel -eq 'back') { return }
        switch ($sel) {
            'kali' {
                if (-not $wslOk) {
                    Write-Host "  [!] WSL fehlt - zuerst WSL aktivieren (Admin): wsl --install --no-distribution" -ForegroundColor Red
                    if (Confirm-SysPilot 'wsl --install --no-distribution jetzt ausfuehren (Admin noetig, evtl. Neustart)?') {
                        if (Test-SysPilotAdmin) { & wsl.exe --install --no-distribution 2>&1 | Out-Host; Write-Host '  Evtl. Neustart noetig - danach erneut versuchen.' -ForegroundColor Yellow }
                        else { Write-Host '  [!] Admin noetig - SysPilot als Administrator neu starten.' -ForegroundColor Red }
                    }
                } else {
                    [void](Install-SysPilotWslDistroByName -Name 'kali-linux')
                }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'kaliopen' {
                if ($kali) {
                    Write-Host "  -> Starte Kali ..." -ForegroundColor Cyan
                    $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
                    if ($wt) { Start-Process wt.exe -ArgumentList 'wsl','-d','kali-linux' }
                    else     { Start-Process wsl.exe -ArgumentList '-d','kali-linux' }
                    Write-Host "  In Kali: sudo apt update && sudo apt install <tool>  (z.B. nmap, metasploit-framework)" -ForegroundColor DarkGray
                    Write-Host "  GUI-Tools laufen ueber WSLg. Root: `"sudo -i`"." -ForegroundColor DarkGray
                } else { Write-Host "  Erst Kali installieren (Menuepunkt oben)." -ForegroundColor Yellow }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'model' {
                Write-Host "`n  Modell-Suche: Empfohlene Suchbegriffe: 'abliterated', 'heretic', 'uncensored', 'dolphin'." -ForegroundColor Cyan
                Write-Host "  Quant-Tipp: Q4_K_M (gute Qualitaet, handlich). Ziel: Ollama/LM Studio/PocketAI." -ForegroundColor DarkGray
                Write-Host "  Unzensiert = weniger Filter, aber Recht/Sicherheit bleibt Sache des Users." -ForegroundColor DarkYellow
                Show-SysPilotAiModelFinder
            }
            'guide' {
                Write-Host "`n  == Security-Lab in 5 Schritten ==" -ForegroundColor Cyan
                Write-Host "  1) Kali installieren (oben) - enthaelt nmap, metasploit, wireshark, hydra ..." -ForegroundColor White
                Write-Host "  2) ERST UEBEN: eigene VM/Netz, z.B. DVWA (Web), Metasploitable, TryHackMe" -ForegroundColor White
                Write-Host "  3) Unzensiertes Modell laden (oben) - Hermes/abliterated/quants via HF-Suche" -ForegroundColor White
                Write-Host "  4) In Herbert: Frage 'Security-Lab' - Wissen erklärt Setup + Grenzen" -ForegroundColor White
                Write-Host "`n  RECHT/HINWEIS: Scans/Exploits nur auf eigene Geraete oder mit" -ForegroundColor Yellow
                Write-Host "  ausdruecklicher Erlaubnis. Andernfalls strafbar (StGB §202a/b, §303a/b," -ForegroundColor Yellow
                Write-Host "  EU-NIS2). Unzensierte Modelle = kein Freibrief - sysPilot empfiehlt" -ForegroundColor Yellow
                Write-Host "  IMMER isolierte Lab-Umgebungen statt Produktivsysteme." -ForegroundColor Yellow
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'wslmenu' { Show-SysPilotWslMenu }
        }
    }
}

function Show-SysPilotMobileSideload {
    <# Smartphone/Tablet-Sideload-Assistent: Android (adb wie TV),
       iPhone/iPad (ehrlicher Guide: AltStore PAL/SideStore - Apple
       erlaubt kein direktes APK). App-Quellen = gleicher Katalog. #>
    while ($true) {
        $items = @(
            @{ Label='Android (Phone/Tablet): ADB + APK installieren'; Color='Green'; Tag='android' },
            @{ Label='iPhone/iPad: Sideload-Guide (AltStore PAL/SideStore)'; Color='Cyan'; Tag='ios' },
            @{ Label='App-Quellen-Katalog (F-Droid, Obtainium, Aurora, APKMirror ...)'; Color='DarkCyan'; Tag='apps' },
            @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
        )
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'Smartphone/Tablet Sideload' -Footer 'Enter = Aktion, Esc = zurueck'
        if ($null -eq $sel) { return }
        switch ($sel) {
            'android' {
                Write-Host "`n  Android-Sideload Schritt-fuer-Schritt:" -ForegroundColor Cyan
                Write-Host "  1) Am Geraet: Einstellungen > Ueber das Geraet > 7x Build-Nummer tippen" -ForegroundColor White
                Write-Host "     > Entwickleroptionen > USB-Debugging AN" -ForegroundColor White
                Write-Host "  2) Per USB an den PC oder Wireless Debugging (Android 11+)" -ForegroundColor White
                Write-Host "  3) Hier: 'ADB verbinden' aus dem TV-Menue nutzen (funktioniert identisch)" -ForegroundColor White
                Write-Host "  4) APK: 'Apps installieren' waehlen > adb install - oder Downloader-App am Geraet" -ForegroundColor White
                Write-Host "     (F-Droid.apk einmalig installieren = alle FOSS-Apps im Store)" -ForegroundColor Green
                Write-Host "  5) Beim ersten Start: 'Installieren aus dieser Quelle erlauben' bestaetigen" -ForegroundColor Yellow
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
                continue
            }
            'ios' {
                Write-Host "`n  iPhone/iPad-Sideload (ehrlich: Apple ist streng):" -ForegroundColor Cyan
                Write-Host "  1) AltStore PAL gibt es KOSTENLOS im App Store - installieren" -ForegroundColor Green
                Write-Host "  2) Darin Konto einrichten (Apple-ID), dann koennen Signierte-Apps laden" -ForegroundColor White
                Write-Host "  3) SideStore (FOSS-Variante mit Auto-Refresh) via AltStore PAL" -ForegroundColor White
                Write-Host "  4) Oder: Sideloadly/AltServer am PC (kostenlos, Signiert mit eigenem Cert)" -ForegroundColor White
                Write-Host "     Download-Seiten: altstore.io / sideloadly.io" -ForegroundColor DarkGray
                Write-Host "`n  Hinweis: iOS-Signaturen laufen nach 7 Tagen ab (kostenlos) -" -ForegroundColor DarkGray
                Write-Host "  SideStore erneuert automatisch, wenn Geraet ab+an." -ForegroundColor DarkGray
                Start-Process 'https://altstore.io/' -ErrorAction SilentlyContinue
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
                continue
            }
            'apps' {
                $apps = @(Get-SysPilotTvApps)
                $ai = @($apps | ForEach-Object {
                    $u = if ($_.Url) { $_.Url } else { $_.Page }
                    @{ Label="$($_.Name) - $($_.Desc)"; Color='White'; Tag=@{ App=$_; Url=$u } }
                }) + @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
                $a = Show-SysPilotArrowMenu -Items $ai -Title 'App-Quellen (Sideload Mobile/TV)' -Footer 'Enter = auswaehlen'
                if (-not $a) { continue }
                $ap = $a['App']; $u = $a['Url']
                Write-Host "`n  $($ap.Name)" -ForegroundColor Cyan
                Write-Host "  $($ap.Desc)" -ForegroundColor DarkGray
                $acts = @()
                if ($ap.Url -or $ap.Page) { $acts += @{ Label='Link im Browser oeffnen'; Color='Cyan'; Tag='open' } }
                if ($ap.Url -or $ap.Page) { $acts += @{ Label='QR-Code anzeigen (am Geraet scannen)'; Color='Magenta'; Tag='qr' } }
                $acts += @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
                $act = Show-SysPilotArrowMenu -Items $acts -Title 'Aktion' -Footer 'Enter = Aktion'
                if (-not $act) { continue }
                switch ($act) {
                    'open' { Start-Process $(if($ap.Url){$ap.Url}else{$ap.Page}) }
                    'qr'    { Show-SysPilotQrCode -Data $(if($u){$u}else{$ap.Page}) -Title $ap.Name }
                }
                continue
            }
        }
    }
}

function Show-SysPilotRssCenter {
    <# RSS-Center: Interessengebiete (Kategorien) aus oeffentlichen
       Feed-Katalogen waehlen, Auswahl sortiert als OPML exportieren
       oder direkt per Miniflux-API importieren (Kategorien = Ordner). #>
    param($Owner = $null)
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase -ErrorAction SilentlyContinue
    # Katalog laden (gecacht) - kann beim ersten Mal ~20s dauern
    $feeds = @(Get-SysPilotRssFeedDirectory)
    $cats = @($feeds | Group-Object Category | Sort-Object Count -Descending)
    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="SysPilot RSS-Center" Width="900" Height="640"
        WindowStartupLocation="CenterScreen" Background="#FF1E1E2E" Foreground="#FFE0E0E0">
  <Window.Resources>
    <Style TargetType="Button"><Setter Property="Background" Value="#FF2D2D44"/><Setter Property="Foreground" Value="#FFE0E0E0"/><Setter Property="BorderBrush" Value="#FF4A4A6A"/><Setter Property="Padding" Value="10,4"/><Setter Property="Margin" Value="3,0"/><Setter Property="Cursor" Value="Hand"/></Style>
    <Style TargetType="CheckBox"><Setter Property="Foreground" Value="#FFE0E0E0"/><Setter Property="FontSize" Value="11"/><Setter Property="Margin" Value="0,2"/></Style>
    <Style TargetType="ListBox"><Setter Property="Background" Value="#FF252538"/><Setter Property="Foreground" Value="#FFE0E0E0"/><Setter Property="BorderBrush" Value="#FF4A4A6A"/></Style>
    <Style TargetType="ListBoxItem"><Setter Property="Padding" Value="5,2"/></Style>
    <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#FF9E9E9E"/><Setter Property="FontSize" Value="11"/></Style>
  </Window.Resources>
  <Grid Margin="14">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <DockPanel>
      <TextBlock FontSize="16" FontWeight="Bold" Foreground="#FF9CCC65" Text="RSS-Center" VerticalAlignment="Center"/>
      <Button x:Name="BtnMinifluxSetup" Content="Miniflux einrichten" DockPanel.Dock="Right"/>
    </DockPanel>
    <Grid Grid.Row="1" Margin="0,8,0,8">
      <Grid.ColumnDefinitions><ColumnDefinition Width="300"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Border Background="#FF252538" CornerRadius="6" Padding="8">
        <DockPanel>
          <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,6">
            <Button x:Name="BtnAll" Content="Alle" Padding="8,2" FontSize="10"/>
            <Button x:Name="BtnNone" Content="Keine" Padding="8,2" FontSize="10" Margin="4,0,0,0"/>
            <TextBlock x:Name="TxtCatCount" VerticalAlignment="Center" Margin="10,0,0,0"/>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <StackPanel x:Name="CatPanel"/>
          </ScrollViewer>
        </DockPanel>
      </Border>
      <Border Grid.Column="1" Background="#FF14141E" CornerRadius="6" Padding="8" Margin="10,0,0,0">
        <DockPanel>
          <TextBlock DockPanel.Dock="Top" x:Name="TxtPreviewInfo" Margin="0,0,0,6" Text="Vorschau (sortiert nach Kategorie)" FontWeight="Bold" Foreground="#FF4FC3F7"/>
          <ListBox x:Name="LstPreview">
            <ListBox.ItemTemplate><DataTemplate>
              <TextBlock Text="{Binding Row}" TextWrapping="Wrap" FontSize="10"/>
            </DataTemplate></ListBox.ItemTemplate>
          </ListBox>
        </DockPanel>
      </Border>
    </Grid>
    <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right">
      <TextBlock x:Name="TxtStatus" VerticalAlignment="Center" Foreground="#FF9CCC65" Margin="0,0,12,0"/>
      <Button x:Name="BtnOpml" Content="OPML exportieren"/>
      <Button x:Name="BtnMiniflux" Content="Miniflux importieren"/>
      <Button x:Name="BtnReaders" Content="Reader-Apps"/>
      <Button x:Name="BtnClose" Content="Schliessen"/>
    </StackPanel>
  </Grid>
</Window>
"@
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
    $win = [Windows.Markup.XamlReader]::Load($reader)
    if ($Owner) { try { $win.Owner = $Owner } catch {} }
    $fc = @{}
    foreach ($n in 'BtnMinifluxSetup','CatPanel','BtnAll','BtnNone','TxtCatCount','LstPreview','TxtPreviewInfo','TxtStatus','BtnOpml','BtnMiniflux','BtnReaders','BtnClose') {
        $fc[$n] = $win.FindName($n)
    }
    $say = { param($t,$c='#FF9CCC65') $fc.TxtStatus.Text=$t; $fc.TxtStatus.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString($c) }

    # Kategorie-Checkboxen bauen
    $catBoxes = @()
    foreach ($g in $cats) {
        $cb = New-Object Windows.Controls.CheckBox
        $cb.Content = "$($g.Name)  ($($g.Count))"
        $cb.Tag = $g.Name
        $cb.IsChecked = ($g.Name -eq 'Empfehlungen')
        $cb.Margin = '0,1'
        $cb.Add_Checked({ & $refreshPreview })
        $cb.Add_Unchecked({ & $refreshPreview })
        $fc.CatPanel.Children.Add($cb)
        $catBoxes += $cb
    }
    # Kuratierte Empfehlungen als virtuelle Kategorie oben
    $emp = New-Object Windows.Controls.CheckBox
    $emp.Content = 'SysPilot-Empfehlungen (13 kuratiert)'
    $emp.Tag = '__emp__'
    $emp.IsChecked = $true
    $emp.Margin = '0,1,0,4'
    $emp.FontWeight = 'Bold'
    $emp.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#FF9CCC65')
    $emp.Add_Checked({ & $refreshPreview })
    $emp.Add_Unchecked({ & $refreshPreview })
    $fc.CatPanel.Children.Insert(0, $emp)
    $catBoxes = @($emp) + $catBoxes

    $refreshPreview = {
        $sel = @{}
        foreach ($cb in $catBoxes) { if ($cb.IsChecked) { $sel[$cb.Tag] = $true } }
        $list = @()
        if ($sel.ContainsKey('__emp__')) {
            foreach ($f in @(Get-SysPilotRssFeedSuggestions)) {
                $list += [pscustomobject]@{ Name=$f.Name; Url=$f.Url; Desc=$f.Desc; Category='Empfehlungen'; Source='kuratiert'; Row="[Empfehlungen] $($f.Name)" }
            }
        }
        foreach ($f in $feeds) {
            if ($sel.ContainsKey([string]$f.Category)) {
                $d = [string]$f.Desc; if ($d.Length -gt 70) { $d = $d.Substring(0,70)+'...' }
                $list += [pscustomobject]@{ Name=$f.Name; Url=$f.Url; Desc=$d; Category=$f.Category; Source=$f.Source; Row="[$($f.Category)] $($f.Name)" }
            }
        }
        $list = @($list | Sort-Object Category, Name)
        $fc.LstPreview.ItemsSource = @($list | Select-Object -First 400)
        $fc.TxtPreviewInfo.Text = "Vorschau: $($list.Count) Feeds (sortiert nach Kategorie)$(if($list.Count -gt 400){', zeige erste 400'})"
        & $say "$($list.Count) Feeds ausgewaehlt"
        $script:_rssSelected = $list
    }

    $fc.BtnAll.Add_Click({ foreach ($cb in $catBoxes) { $cb.IsChecked = $true } })
    $fc.BtnNone.Add_Click({ foreach ($cb in $catBoxes) { $cb.IsChecked = $false } })
    $fc.BtnMinifluxSetup.Add_Click({ try { Show-SysPilotMinifluxSetup | Out-Null } catch {} })
    $fc.BtnReaders.Add_Click({
        # Kleines Popup-Menue (kein Konsolen-ArrowMenu im GUI-Kontext)
        $cm = New-Object System.Windows.Controls.ContextMenu
        foreach ($r in @(Get-SysPilotRssReaderApps)) {
            $mi = New-Object System.Windows.Controls.MenuItem
            $mi.Header = "$($r.Name) - $($r.Desc)"
            $mi.Tag = $r.Url
            $mi.Add_Click({ param($s,$e) try { Start-Process ([string]$s.Tag) } catch {} })
            [void]$cm.Items.Add($mi)
        }
        $cm.PlacementTarget = $fc.BtnReaders
        $cm.Placement = 'Bottom'
        $cm.IsOpen = $true
    })
    $fc.BtnOpml.Add_Click({
        $list = @($script:_rssSelected)
        if ($list.Count -eq 0) { & $say 'Keine Feeds ausgewaehlt.' '#FFFFB74D'; return }
        $p = Export-SysPilotRssOpml -Items $list
        & $say "OPML exportiert: $p"
        if (Confirm-SysPilot 'OPML-Datei im Explorer oeffnen?') { Start-Process explorer.exe "/select,$p" }
    })
    $fc.BtnMiniflux.Add_Click({
        $list = @($script:_rssSelected)
        if ($list.Count -eq 0) { & $say 'Keine Feeds ausgewaehlt.' '#FFFFB74D'; return }
        # API-Key pruefen, sonst einmalig abfragen
        $t = Test-SysPilotMinifluxApi
        if (-not $t.Ok) {
            Write-Host "`n  Miniflux-API nicht erreichbar: $($t.Error)" -ForegroundColor Yellow
            Write-Host "  API-Key findest du in Miniflux unter Settings > API Keys." -ForegroundColor DarkGray
            $key = Read-SysPilotInput 'Miniflux API-Key (Settings > API Keys; leer = abbrechen)' '' 'Miniflux'
            if (-not $key) { & $say 'Abgebrochen - OPML-Export bleibt die Alternative.' '#FFFFB74D'; return }
            $url = Read-SysPilotInput 'Miniflux-URL' 'http://localhost:8080' 'Miniflux'
            if (-not $url) { $url = 'http://localhost:8080' }
            $t = Test-SysPilotMinifluxApi -BaseUrl $url -ApiKey $key.Trim()
            if (-not $t.Ok) { & $say "API-Test fehlgeschlagen: $($t.Error)" '#FFF44336'; return }
        }
        & $say "Importiere $($list.Count) Feeds in Miniflux (Kategorien)..."
        $r = Add-SysPilotMinifluxFeeds -Items $list
        if ($r.Ok -or $r.Created -gt 0) {
            & $say "Importiert: $($r.Created) Feeds ($($list.Count - $r.Created) uebersprungen/dup) - sortiert in Miniflux-Kategorien" '#FF9CCC65'
            if (Confirm-SysPilot 'Miniflux im Browser oeffnen?') { Start-Process (Get-SysPilotMinifluxConfig).BaseUrl }
        } else {
            & $say "Import fehlgeschlagen: $($r.Error)" '#FFF44336'
        }
    })
    $fc.BtnClose.Add_Click({ $win.Close() })

    & $refreshPreview
    [void]$win.ShowDialog()
    return $true
}

function Get-SysPilotCloudflaredExe {
    $c = (Get-Command cloudflared -ErrorAction SilentlyContinue).Source
    if ($c) { return $c }
    foreach ($p in "$env:ProgramFiles (x86)\cloudflared\cloudflared.exe", "$env:ProgramFiles\cloudflared\cloudflared.exe", "$env:LOCALAPPDATA\Microsoft\WinGet\Links\cloudflared.exe") {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Show-SysPilotCfNamedTunnel {
    <# Gefuehrter Cloudflare-Named-Tunnel: EINMALIG Browser-Login
       (unvermeidbar), danach erstellt SysPilot Tunnel + DNS-Route +
       Config + Service komplett von selbst. Feste URL statt Quick-Tunnel. #>
    $cf = Get-SysPilotCloudflaredExe
    if (-not $cf) {
        $w = (Get-Command winget -ErrorAction SilentlyContinue).Source
        if ($w) {
            Write-Host "  Installiere cloudflared ..." -ForegroundColor Cyan
            [void](Invoke-SysPilotMonitoredProcess -FilePath $w -ArgList @('install','--id','Cloudflare.cloudflared','--exact','--accept-package-agreements','--accept-source-agreements','--disable-interactivity') -Label 'cloudflared' -TimeoutSec 600)
            $cf = Get-SysPilotCloudflaredExe
        }
        if (-not $cf) { Write-Host "  [!] cloudflared nicht verfuegbar." -ForegroundColor Red; return }
    }
    $cfDir = Join-Path $env:USERPROFILE '.cloudflared'
    $cert = Join-Path $cfDir 'cert.pem'
    if (-not (Test-Path $cert)) {
        Write-Host "`n  Einmaliger Schritt: Cloudflare-Login (oeffnet Browser)." -ForegroundColor Cyan
        Write-Host "  -> Kostenloses Cloudflare-Konto noetig (Free Plan reicht)." -ForegroundColor DarkGray
        Write-Host "  -> Im Browser die Domain auswaehlen, die du nutzt." -ForegroundColor DarkGray
        if (-not (Confirm-SysPilot 'cloudflared tunnel login starten?')) { return }
        Start-Process -FilePath $cf -ArgumentList @('tunnel','login')
        Write-Host "  Warte auf Login im Browser (max 3 Min) ..." -ForegroundColor DarkGray
        $w = 0
        while ($w -lt 180 -and -not (Test-Path $cert)) { Start-Sleep -Seconds 3; $w += 3 }
        if (-not (Test-Path $cert)) { Write-Host "  [!] Login nicht abgeschlossen - abgebrochen." -ForegroundColor Yellow; return }
    }
    $tname = 'syspilot-miniflux'
    $list = (& $cf tunnel list 2>&1 | Out-String)
    $exists = $list -match [regex]::Escape($tname)
    if (-not $exists) {
        Write-Host "  Erstelle Tunnel '$tname' ..." -ForegroundColor Cyan
        $cr = (& $cf tunnel create $tname 2>&1 | Out-String)
        Write-Host "  $($cr.Trim())" -ForegroundColor DarkGray
    }
    # Tunnel-ID + Credentials-File finden
    $cred = Get-ChildItem $cfDir -Filter '*.json' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'cert.pem' } | Select-Object -First 1
    $tunnelId = $null
    if ($cred) { $tunnelId = $cred.BaseName }
    if (-not $tunnelId) {
        $m = [regex]::Match((& $cf tunnel list 2>&1 | Out-String), "$tname\s+([0-9a-f-]{36})")
        if ($m.Success) { $tunnelId = $m.Groups[1].Value }
    }
    if (-not $tunnelId) { Write-Host "  [!] Tunnel-ID nicht gefunden." -ForegroundColor Red; return }
    $credFile = Join-Path $cfDir "$tunnelId.json"
    # DNS-Hostname erfragen
    $host_ = Read-SysPilotInput 'Oeffentlicher Hostname (z.B. miniflux.deine-domain.de)'
    if (-not $host_ -or $host_ -notmatch '\.') { Write-Host "  Uegueltiger Hostname - abgebrochen." -ForegroundColor Yellow; return }
    Write-Host "  DNS-Route: $host_ -> Tunnel ..." -ForegroundColor Cyan
    $rt = (& $cf tunnel route dns $tname $host_ 2>&1 | Out-String)
    Write-Host "  $($rt.Trim())" -ForegroundColor DarkGray
    # Config
    $cfg = @"
tunnel: $tunnelId
credentials-file: $credFile
ingress:
  - hostname: $host_
    service: http://localhost:8080
  - service: http_status:404
"@
    $cfgPath = Join-Path $cfDir 'config.yml'
    $cfg | Set-Content -Path $cfgPath -Encoding UTF8
    # Service installieren (Admin noetig) + starten
    Write-Host "  Installiere Cloudflare-Service (laeuft dann automatisch mit Windows) ..." -ForegroundColor Cyan
    $svc = (& $cf service install 2>&1 | Out-String)
    Write-Host "  $($svc.Trim())" -ForegroundColor DarkGray
    if ($svc -match 'access denied|requires admin|Permission') {
        Write-Host "  [!] Service-Install braucht Admin - SysPilot als Administrator neu starten," -ForegroundColor Yellow
        Write-Host "      oder manuell: cloudflared service install (Admin-PowerShell)" -ForegroundColor Yellow
    } else {
        try { Start-Service cloudflared -ErrorAction Stop; Write-Host "  [OK] Service gestartet." -ForegroundColor Green } catch {}
    }
    Write-Host "`n  [OK] Feste oeffentliche URL: https://$host_" -ForegroundColor Green
    Write-Host "  Config: $cfgPath | Credentials: $credFile" -ForegroundColor DarkGray
    Write-Host "  Hinweis: Miniflux muss lokal auf Port 8080 laufen (Docker-Stack)." -ForegroundColor DarkYellow
    if (Confirm-SysPilot 'Miniflux oeffnen?') { Start-Process "https://$host_" }
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
}

function Show-SysPilotTailscaleFunnel {
    <# Tailscale Funnel: Feste HTTPS-URL (https://<rechner>.<tailnet>.ts.net)
       auf den lokalen Miniflux-Port - KOSTENLOS, kein Domain noetig,
       funktioniert hinter NAT/Hotspot (kein Port-Forwarding noetig).
       Einmalige Anmeldung noetig (tailscale up oeffnet Browser).
       Funnel bleibt als tailscaled-Config persistent (ueberlebt Reboot). #>
    $ts = Get-Command tailscale -ErrorAction SilentlyContinue
    $tsExe = $null
    if ($ts) { $tsExe = $ts.Source }
    if (-not $tsExe) {
        foreach ($p in "$env:ProgramFiles\Tailscale\tailscale.exe", "$env:ProgramFiles (x86)\Tailscale\tailscale.exe") {
            if (Test-Path $p) { $tsExe = $p; break }
        }
    }
    if (-not $tsExe) {
        Write-Host "`n  Tailscale nicht installiert - installiere via winget ..." -ForegroundColor Cyan
        $w = (Get-Command winget -ErrorAction SilentlyContinue).Source
        if ($w) {
            [void](Invoke-SysPilotMonitoredProcess -FilePath $w -ArgList @('install','--id','Tailscale.Tailscale','--exact','--accept-package-agreements','--accept-source-agreements','--disable-interactivity') -Label 'tailscale' -TimeoutSec 600)
            foreach ($p in "$env:ProgramFiles\Tailscale\tailscale.exe", "$env:ProgramFiles (x86)\Tailscale\tailscale.exe") {
                if (Test-Path $p) { $tsExe = $p; break }
            }
            $ts = Get-Command tailscale -ErrorAction SilentlyContinue
            if (-not $tsExe -and $ts) { $tsExe = $ts.Source }
        }
        if (-not $tsExe) { Write-Host "  [!] Tailscale nicht verfuegbar." -ForegroundColor Red; return }
    }
    $st = (& $tsExe status 2>&1 | Out-String)
    if ($st -match 'Logged out|NeedsLogin|not logged') {
        Write-Host "`n  Einmalige Anmeldung noetig - Browser oeffnet sich." -ForegroundColor Cyan
        Write-Host "  (Kostenloser Tailscale-Account, Google-Login moeglich)" -ForegroundColor DarkGray
        Start-Process -FilePath $tsExe -ArgumentList @('up')
        Write-Host "  Warte auf Anmeldung (max 3 Min) ..." -ForegroundColor DarkGray
        $w = 0
        while ($w -lt 180) {
            Start-Sleep -Seconds 3; $w += 3
            $st = (& $tsExe status 2>&1 | Out-String)
            if ($st -notmatch 'Logged out|NeedsLogin|not logged' -and $st.Trim()) { break }
        }
    }
    if (-not $st.Trim()) { Write-Host "  [!] Tailscale-Status leer - Anmeldung unvollstaendig?" -ForegroundColor Yellow; return }
    # Funnel muss einmalig im Tailnet aktiviert werden
    $probe = (& $tsExe funnel --bg 8080 2>&1 | Out-String)
    if ($probe -match 'not enabled|funnel\?node=') {
        $m = [regex]::Match($probe, 'https://\S+funnel\?node=\S+')
        Write-Host "`n  Funnel muss einmalig aktiviert werden - Browser-Link:" -ForegroundColor Cyan
        if ($m.Success) { Write-Host "  $($m.Value)" -ForegroundColor Yellow; Start-Process $m.Value }
        Write-Host "  Nach dem Klick hier Enter druecken." -ForegroundColor DarkGray
        Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
    }
    # Port ermitteln: lokal laufender Miniflux-Stack -> compose-File
    $port = 8080
    $compose = Join-Path $env:LOCALAPPDATA 'SysPilot\miniflux\docker-compose.yml'
    if (Test-Path $compose) {
        $m = Select-String -Path $compose -Pattern '"(\d+):8080"' | Select-Object -First 1
        if ($m -and $m.Matches[0].Groups[1].Value) { $port = [int]$m.Matches[0].Groups[1].Value }
    }
    # Alt-Proxy aus? Dann frisch auf den richtigen Port
    $cur = (& $tsExe funnel status 2>&1 | Out-String)
    $needOn = $cur -notmatch "proxy http://127\.0\.0\.1:$port"
    if ($cur -match 'Funnel on' -and -not $needOn) {
        Write-Host "`n  Funnel laeuft bereits auf Port $port." -ForegroundColor Green
    } else {
        if ($cur -match 'Funnel on') { & $tsExe funnel --https=443 off 2>&1 | Out-Null }
        Write-Host "`n  Aktiviere Funnel: localhost:$port -> Internet (HTTPS) ..." -ForegroundColor Cyan
        $on = (& $tsExe funnel --bg $port 2>&1 | Out-String)
        Write-Host ($on.Trim() -split "`n" | Select-Object -First 6) -ForegroundColor DarkGray
    }
    $dns = (& $tsExe status --json 2>$null | ConvertFrom-Json).Self.DNSName
    if (-not $dns) {
        $m = [regex]::Match((& $tsExe status 2>&1 | Out-String), '([a-z0-9-]+\.[a-z0-9-]+\.ts\.net)')
        if ($m.Success) { $dns = $m.Groups[1].Value }
    }
    if ($dns) {
        $url = "https://$($dns.TrimEnd('.'))/"
        Write-Host "`n  [OK] Feste oeffentliche URL: $url" -ForegroundColor Green
        Write-Host "  Laeuft automatisch mit Windows (tailscaled-Service)." -ForegroundColor DarkGray
        Write-Host "  Abschalten: tailscale funnel --https=443 off" -ForegroundColor DarkGray
        Set-Clipboard -Value $url
        if (Confirm-SysPilot 'Miniflux im Browser oeffnen?') { Start-Process $url }
    } else {
        Write-Host "  [!] DNS-Name nicht ermittelbar - 'tailscale status' pruefen." -ForegroundColor Yellow
    }
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
}

function Export-SysPilotOracleCloudInit {
    <# Exportiert ein cloud-init/user-data Script fuer Oracle-Cloud-ARM-
       VMs: installiert Docker + startet Miniflux-Stack automatisch.
       Der User fuellt es beim VM-Create ('Paste OpenSSH keys /
       cloud-init') oder in der Cloud Shell ein.
       Compose-File wird base64-eingebettet (kein YAML-Heredoc-Problem). #>
    $out = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'SysPilot\oracle-miniflux-cloudinit.yaml'
    $dir = Split-Path $out -Parent
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $pw = -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 20 | ForEach-Object {[char]$_})
    $compose = @"
services:
  db:
    image: postgres:17-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: miniflux
      POSTGRES_PASSWORD: $pw
      POSTGRES_DB: miniflux
    volumes:
      - miniflux-db:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U miniflux -d miniflux"]
      interval: 10s
      timeout: 5s
      retries: 12
  miniflux:
    image: miniflux/miniflux:2.3.5
    restart: unless-stopped
    ports:
      - "8080:8080"
    environment:
      DATABASE_URL: postgres://miniflux:$pw@db/miniflux?sslmode=disable
      RUN_MIGRATIONS: "1"
      CREATE_ADMIN: "1"
      ADMIN_USERNAME: admin
      ADMIN_PASSWORD: $pw
      # Aeltere ungelesene Eintraege automatisch aufraeumen (Tage)
      REMOVE_UNREAD_ARTICLES: "180"
      POLLING_FREQUENCY: "300"
      BATCH_OPERATIONS: "100"
    depends_on:
      db:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:8080/healthcheck || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 20
      start_period: 30s
volumes:
  miniflux-db:
"@
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($compose))
    $yaml = @"
#cloud-config
# SysPilot Miniflux auf Oracle-Cloud-ARM-VM (Always Free, DAUERHAFT kostenlos)
# Nutzung: Oracle Console > Compute > Instances > Create >
#   Shape: VM.Standard.A1.Flex (ARM) > "Paste OpenSSH keys" ->
#   dieses File als cloud-init einfuegen. Oder Cloud Shell:
#   bash <(curl -sL <this-file>)  nicht noetig - direkt einfügen.
#
# WICHTIG danach (Oracle Console):
#   VCN > Subnetz > Security List > Add Ingress Rule:
#   Stateless=nein, Source CIDR=0.0.0.0/0, IP Protocol=TCP, Port=8080
#   Sonst ist Miniflux von aussen nicht erreichbar!
package_update: true
packages:
  - docker.io
  - docker-compose-v2
  - curl
  - jq
runcmd:
  - systemctl enable --now docker
  # compose-Plugin-Fallback: falls docker-compose-v2 nicht installierbar
  - |
    if ! docker compose version >/dev/null 2>&1; then
      mkdir -p /usr/libexec/docker/cli-plugins
      curl -fsSL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-aarch64 -o /usr/libexec/docker/cli-plugins/docker-compose
      chmod +x /usr/libexec/docker/cli-plugins/docker-compose
    fi
  - mkdir -p /opt/miniflux
  - echo $b64 | base64 -d > /opt/miniflux/docker-compose.yml
  - cd /opt/miniflux && docker compose up -d
  # Warten bis Miniflux gesund, dann API-Key automatisch anlegen
  - |
    for i in `$(seq 1 60); do
      if curl -fsS http://localhost:8080/healthcheck >/dev/null 2>&1; then break; fi
      sleep 5
    done
    IP=`$(curl -s4 ifconfig.me || hostname -I | awk '{print `$1}')
    TOKEN=`$(curl -fsS -u admin:$pw -X POST http://localhost:8080/v1/api-keys -H 'Content-Type: application/json' -d '{"name":"syspilot"}' | jq -r '.api_key // .token // empty' 2>/dev/null)`
    {
      echo "Miniflux URL: http://`$IP`:8080"
      echo "Login: admin"
      echo "Passwort: $pw"
      echo "API-Key (fuer RSS-Clients): `$TOKEN"
      echo "Fever-API + Google-Reader-API: im Login > Settings > Integrations aktivieren (eigene Credentials!)"
    } > /root/miniflux-url.txt
    echo "Miniflux: http://`$IP`:8080" > /etc/motd
    echo "Fertig. Credentials in /root/miniflux-url.txt"
"@
    $yaml | Set-Content -Path $out -Encoding UTF8
    return @{ Path=$out; Password=$pw }
}

function Show-SysPilotMinifluxDoctor {
    <# Diagnose + Problembehebung fuer alle Miniflux-Wege (Docker lokal,
       Quick Tunnel, Named Tunnel, Oracle-VM). Prueft Zustand, bietet
       Ein-Klick-Fixes. #>
    $mdir = Join-Path $env:LOCALAPPDATA 'SysPilot\miniflux'
    $composeFile = Join-Path $mdir 'docker-compose.yml'
    $cfDir = Join-Path $env:USERPROFILE '.cloudflared'
    Write-Host "`n  === Miniflux-Doctor (Diagnose) ===" -ForegroundColor Cyan
    $issues = 0

    # 1. Docker CLI + Daemon
    $docker = (Get-Command docker -ErrorAction SilentlyContinue).Source
    if (-not $docker) { Write-Host "  [FAIL] docker CLI fehlt" -ForegroundColor Red; $issues++ }
    else {
        $dok = $false; $sv = ''
        try { $sv = (& docker version --format '{{.Server.Version}}' 2>$null); $dok = ($LASTEXITCODE -eq 0 -and $sv) } catch {}
        if ($dok) { Write-Host "  [ OK ] Docker Daemon laeuft (Server $sv)" -ForegroundColor Green }
        else {
            Write-Host "  [WARN] Docker CLI da, Daemon nicht bereit" -ForegroundColor Yellow; $issues++
            if (Confirm-SysPilot 'Docker Desktop starten und 60s warten?') {
                $dd = "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"
                if (Test-Path $dd) { Start-Process $dd; Write-Host "  Warte auf Daemon ..." -ForegroundColor DarkGray
                    $w=0; while($w -lt 90){ Start-Sleep 5; $w+=5; try{ if((& docker version --format '{{.Server.Version}}' 2>$null)){$dok=$true;break} }catch{} }
                    if($dok){Write-Host "  [ OK ] Docker Daemon jetzt bereit" -ForegroundColor Green}else{Write-Host "  [FAIL] Daemon kam nicht hoch - Docker Desktop evtl. EULA/Update noetig" -ForegroundColor Red}
                } else { Write-Host "  [FAIL] Docker Desktop.exe nicht gefunden - Installation noetig" -ForegroundColor Red }
            }
        }
    }

    # 2. Compose-File + Container
    if (Test-Path $composeFile) {
        Write-Host "  [ OK ] Compose-File: $composeFile" -ForegroundColor Green
        if ($docker) {
            $ps = (& docker ps --filter "name=miniflux" --format '{{.Names}} {{.Status}}' 2>$null | Out-String).Trim()
            if ($ps -match 'miniflux') { Write-Host "  [ OK ] Container: $ps" -ForegroundColor Green }
            else {
                Write-Host "  [WARN] Miniflux-Container nicht aktiv" -ForegroundColor Yellow; $issues++
                if (Confirm-SysPilot 'Stack starten (docker compose up -d)?') {
                    Push-Location $mdir
                    & docker compose up -d 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
                    Pop-Location
                    Start-Sleep 8
                    $ps = (& docker ps --filter "name=miniflux" --format '{{.Names}} {{.Status}}' 2>$null | Out-String).Trim()
                    Write-Host "  -> $ps" -ForegroundColor DarkGray
                }
            }
        }
    } else {
        Write-Host "  [INFO] Kein lokaler Compose-Stack ($mdir) - ggf. Oracle/VPS-Pfad" -ForegroundColor DarkCyan
    }

    # 3. Lokaler Port erreichbar (Port aus Compose lesen - kann 8081 sein)
    $docPort = 8080
    if (Test-Path $composeFile) { $pm = Select-String -Path $composeFile -Pattern '"(\d+):8080"' | Select-Object -First 1; if ($pm) { $docPort = [int]$pm.Matches[0].Groups[1].Value } }
    $local = Test-SysPilotAiPortReachable -BaseUrl "http://localhost:$docPort" -TimeoutSec 2
    if ($local) { Write-Host "  [ OK ] Miniflux antwortet auf localhost:$docPort" -ForegroundColor Green }
    elseif (Test-Path $composeFile) { Write-Host "  [WARN] Port $docPort antwortet nicht" -ForegroundColor Yellow; $issues++ }

    # 4. Cloudflare Quick Tunnel (prozessbasiert)
    $tunnelProc = Get-Process cloudflared -ErrorAction SilentlyContinue
    if ($tunnelProc) {
        $qlog = Join-Path $env:TEMP 'syspilot-cf-tunnel.log'
        $qurl = $null
        if (Test-Path $qlog) { $m = Select-String -Path $qlog -Pattern 'https://[a-z0-9-]+\.trycloudflare\.com' -ErrorAction SilentlyContinue | Select-Object -First 1; if($m){$qurl=$m.Matches[0].Value} }
        if ($qurl) { Write-Host "  [ OK ] Quick-Tunnel aktiv: $qurl" -ForegroundColor Green }
        else { Write-Host "  [WARN] cloudflared-Prozess laeuft, aber keine URL gefunden" -ForegroundColor Yellow; $issues++ }
    } else { Write-Host "  [INFO] Kein Quick-Tunnel-Prozess (Menu: Internet-Zugang KOSTENLOS)" -ForegroundColor DarkGray }

    # 5. Named Tunnel (Service + Config)
    $cfExe = Get-SysPilotCloudflaredExe
    $cert = Join-Path $cfDir 'cert.pem'
    $cfg  = Join-Path $cfDir 'config.yml'
    $svc  = Get-Service cloudflared -ErrorAction SilentlyContinue
    if (Test-Path $cert) { Write-Host "  [ OK ] Cloudflare-Login vorhanden (cert.pem)" -ForegroundColor Green }
    else { Write-Host "  [INFO] Kein Cloudflare-Login - named tunnel waere erst nach 'tunnel login' moeglich" -ForegroundColor DarkGray }
    if (Test-Path $cfg) {
        Write-Host "  [ OK ] Named-Tunnel-Config: $cfg" -ForegroundColor Green
        if ($svc -and $svc.Status -eq 'Running') { Write-Host "  [ OK ] cloudflared-Service laeuft" -ForegroundColor Green }
        elseif ($svc) {
            Write-Host "  [WARN] cloudflared-Service installiert aber gestoppt" -ForegroundColor Yellow; $issues++
            if (Confirm-SysPilot 'Service starten (Start-Service cloudflared)?') { try{Start-Service cloudflared;Write-Host "  [ OK ] Service gestartet" -ForegroundColor Green}catch{Write-Host "  [FAIL] $($_.Exception.Message) - Admin noetig?" -ForegroundColor Red} }
        } else { Write-Host "  [INFO] Kein cloudflared-Service - Setup: 'Feste URL named tunnel'" -ForegroundColor DarkGray }
    } else { Write-Host "  [INFO] Kein named-tunnel config.yml" -ForegroundColor DarkGray }

    Write-Host "`n  Ergebnis: $(if($issues -eq 0){'Alles OK'}else{"$issues Punkt(e) pruefen"})" -ForegroundColor $(if($issues -eq 0){'Green'}else{'Yellow'})
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
}

function Show-SysPilotOracleGuide {
    <# Schritt-fuer-Schritt-Anleitung Oracle Always Free, ADHD-tauglich:
       EIN Schritt sichtbar, Enter = erledigt/weiter, Herbert prueft
       zustaendig wo moeglich. Oeffnet die noetigen Seiten direkt. #>
    $steps = @(
        @{ T='Oracle-Account anlegen (Karte nur Verifikation, keine Abbuchung)';
           Url='https://www.oracle.com/cloud/free/';
           Yt='oracle cloud always free signup tutorial';
           Hint='-> Seite wird geoeffnet. Email + Passwort vergeben, Kreditkarte zur Verifikation eingeben (KEINE Abbuchung). Danach E-Mail bestaetigen.' },
        @{ T='Oracle Cloud Shell oeffnen (Browser-Konsole, gratis)';
           Url='https://cloud.oracle.com/?region=eu-frankfurt-1';
           Yt='oracle cloud shell basics';
           Hint='-> Nach Login: oben rechts das Terminal-Symbol (>_) = Cloud Shell. Kein SSH noetig.' },
        @{ T='VM anlegen: Compute > Instances > Create Instance';
           Url='https://cloud.oracle.com/compute/instances?region=eu-frankfurt-1';
           Yt='oracle cloud create arm a1 flex instance';
           Hint='Shape: VM.Standard.A1.Flex (ARM Ampere) - 1-4 OCPU, 6-24 GB. Region Frankfurt oder Amsterdam. Bei "Out of capacity" einfach Retry oder andere AD (Availability Domain).' },
        @{ T='cloud-init Script einfuegen (Miniflux startet automatisch)';
           Url=$null;
           Yt='oracle cloud cloud-init user-data';
           Hint='Bei "Paste OpenSSH keys" den Inhalt von oracle-miniflux-cloudinit.yaml einfuegen (Menu-Punkt "Oracle Always Free: cloud-init Script exportieren"). SSH-Key kann leer bleiben wenn cloud-init genutzt wird.' },
        @{ T='Port 8080 in Oracle freigeben (Security List)';
           Url='https://cloud.oracle.com/networking/vcns?region=eu-frankfurt-1';
           Yt='oracle cloud security list ingress rule port';
           Hint='WICHTIG - ohne das ist Miniflux nicht erreichbar: Networking > Virtual Cloud Networks > dein VCN > Subnetz > Security List > Add Ingress Rule: Stateless=nein, Source CIDR=0.0.0.0/0, IP Protocol=TCP, Port=8080.' },
        @{ T='VM starten + warten (~2-5 Min), dann Miniflux oeffnen';
           Url=$null;
           Yt='oracle cloud vm docker tutorial';
           Hint='Miniflux: http://<server-ip>:8080 - Login admin + Passwort aus dem Export (auch /root/miniflux-url.txt auf der VM, API-Key wird automatisch angelegt). Bei "Out of capacity": andere AD oder Retry.' },
        @{ T='Optional: feste HTTPS-URL per Cloudflare named tunnel';
           Url=$null;
           Yt='cloudflare tunnel named tunnel setup';
           Hint='Auf der VM cloudflared installieren + SysPilot named-tunnel-Config entsprechend (Menu: "Feste URL KOSTENLOS"). Oder Oracle Security List fuer Port 8080 oeffnen (nur HTTP, kein HTTPS).' }
    )
    [void](Show-SysPilotStepGuide -Steps $steps -Title 'Oracle Always Free Setup' `
        -DoneText 'Miniflux laeuft auf Oracle Always Free - 0 EUR dauerhaft. Tipp: Feeds via OPML-Import befuellen.')
}

function Show-SysPilotMinifluxSetup {
    <# Miniflux (Self-Host RSS-Reader, Open Source, unbegrenzt) aufsetzen.
       Miniflux braucht PostgreSQL - deshalb docker-compose mit beiden.
       Ohne Docker: Install-Angebot oder Cloud-Optionen. #>
    $dir = Join-Path $env:LOCALAPPDATA 'SysPilot\miniflux'
    while ($true) {
        $docker = (Get-Command docker -ErrorAction SilentlyContinue).Source
        $compose = (Get-Command docker-compose -ErrorAction SilentlyContinue).Source
        $dok = $false
        if ($docker) {
            try { $v = & docker version --format '{{.Server.Version}}' 2>$null; $dok = ($LASTEXITCODE -eq 0 -and $v) } catch {}
        }
        $items = @(
            @{ Label="Docker-Status: " + $(if($dok){"OK (Server $v)"}elseif($docker){'CLI da, aber Daemon laeuft nicht'}else{'nicht installiert'}); Color=$(if($dok){'Green'}else{'Yellow'}); Tag='status' },
            @{ Label='Docker-Stack einrichten (Miniflux + PostgreSQL, docker-compose)'; Color='Green'; Tag='docker' },
            @{ Label='Docker Desktop installieren (winget) und dann Stack'; Color='Cyan'; Tag='dockerinstall' },
            @{ Label='Cloud-Optionen (Oracle Always Free, GCP e2-micro, ~2-4 EUR VPS ...)'; Color='Yellow'; Tag='cloud' },
            @{ Label='Internet-Zugang KOSTENLOS: Cloudflare-Tunnel auf lokalen Miniflux'; Color='Green'; Tag='tunnel' },
            @{ Label='Feste URL KOSTENLOS: Cloudflare named tunnel (gefuehrtes Setup)'; Color='Green'; Tag='cfnamed' },
            @{ Label='Feste URL KOSTENLOS: Tailscale Funnel (empfohlen, kein Domain noetig)'; Color='Green'; Tag='tsfunnel' },
            @{ Label='Oracle Always Free: cloud-init Script exportieren (VM+Miniflux fertig)'; Color='Cyan'; Tag='oracle' },
            @{ Label='Client einrichten (Android/iOS/Desktop, QR-Code, ADB)'; Color='Green'; Tag='clients' },
            @{ Label='Diagnose & Problembehebung (Miniflux-Doctor)'; Color='Yellow'; Tag='doctor' },
            @{ Label='Oracle Always Free: Schritt-fuer-Schritt-Anleitung'; Color='Cyan'; Tag='guide' },
            @{ Label='OPML-Export meiner Feed-Vorschlaege (fuer jeden Reader)'; Color='Cyan'; Tag='opml' },
            @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
        )
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'Miniflux einrichten (Self-Host RSS)' -Footer 'Enter = Aktion, Esc = zurueck'
        if ($null -eq $sel) { return }
        switch ($sel) {
            'status' { continue }
            'tunnel' {
                # Cloudflare Quick Tunnel: oeffentliche URL auf den lokalen
                # Miniflux - 0 EUR, keine Registrierung. Port aus Compose lesen.
                $localPort = 8080
                $mc = Join-Path $env:LOCALAPPDATA 'SysPilot\miniflux\docker-compose.yml'
                if (Test-Path $mc) { $pm = Select-String -Path $mc -Pattern '"(\d+):8080"' | Select-Object -First 1; if ($pm) { $localPort = [int]$pm.Matches[0].Groups[1].Value } }
                Write-Host "`n  Pruefe: laeuft Miniflux lokal (localhost:$localPort)?" -ForegroundColor Cyan
                $local = Test-SysPilotAiPortReachable -BaseUrl "http://localhost:$localPort" -TimeoutSec 2
                if (-not $local) { Write-Host "  [!] Nichts auf Port $localPort - erst 'Docker-Stack' einrichten." -ForegroundColor Yellow }
                $cf = (Get-Command cloudflared -ErrorAction SilentlyContinue).Source
                if (-not $cf) {
                    $w = (Get-Command winget -ErrorAction SilentlyContinue).Source
                    if ($w) {
                        Write-Host "  Installiere cloudflared (winget Cloudflare.cloudflared) ..." -ForegroundColor Cyan
                        $r = Invoke-SysPilotMonitoredProcess -FilePath $w -ArgList @('install','--id','Cloudflare.cloudflared','--exact','--accept-package-agreements','--accept-source-agreements','--disable-interactivity') -Label 'cloudflared' -TimeoutSec 600
                        $cf = (Get-Command cloudflared -ErrorAction SilentlyContinue).Source
                        if (-not $cf) { $cf = "$env:ProgramFiles (x86)\cloudflared\cloudflared.exe"; if (Test-Path $cf) { $cf = $cf } else { $cf = $null } }
                    }
                }
                if (-not $cf) { Write-Host "  [!] cloudflared nicht verfuegbar - Installation fehlgeschlagen." -ForegroundColor Red; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; continue }
                $log = Join-Path $env:TEMP 'syspilot-cf-tunnel.log'
                Remove-Item $log -Force -ErrorAction SilentlyContinue
                Write-Host "  Starte Tunnel: cloudflared tunnel --url http://localhost:$localPort ..." -ForegroundColor Cyan
                $proc = Start-Process -FilePath $cf -ArgumentList @('tunnel','--url',"http://localhost:$localPort",'--logfile',$log) -PassThru -WindowStyle Hidden
                # Auf trycloudflare-URL in der Logdatei warten (max 45s)
                $url = $null; $waited = 0
                while ($waited -lt 45 -and -not $url) {
                    Start-Sleep -Seconds 3; $waited += 3
                    if (Test-Path $log) {
                        $m = Select-String -Path $log -Pattern 'https://[a-z0-9-]+\.trycloudflare\.com' -ErrorAction SilentlyContinue | Select-Object -First 1
                        if ($m) { $url = $m.Matches[0].Value }
                    }
                }
                if ($url) {
                    Write-Host "`n  [OK] Miniflux oeffentlich erreichbar:" -ForegroundColor Green
                    Write-Host "  $url" -ForegroundColor Cyan
                    Write-Host "  Login: admin + Passwort aus %LOCALAPPDATA%\SysPilot\miniflux\ZUGANG.txt" -ForegroundColor DarkGray
                    Write-Host "  HINWEIS: Quick-Tunnel-URL wechselt bei jedem Neustart." -ForegroundColor Yellow
                    Write-Host "  Fuer feste URL: kostenloses Cloudflare-Konto + named tunnel" -ForegroundColor DarkGray
                    Write-Host "  (cloudflared tunnel login + tunnel create + route dns)." -ForegroundColor DarkGray
                    Set-Clipboard -Value $url
                    Write-Host "  URL wurde in die Zwischenablage kopiert." -ForegroundColor DarkGray
                    if (Confirm-SysPilot 'Miniflux im Browser oeffnen?') { Start-Process $url }
                } else {
                    Write-Host "  [!] Keine Tunnel-URL in 45s - Log: $log" -ForegroundColor Red
                    Write-Host "  (Womöglich Laeuft Miniflux nicht - Port $localPort pruefen.)" -ForegroundColor DarkYellow
                }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'clients' { Show-SysPilotRssClientSetup }
            'doctor' { Show-SysPilotMinifluxDoctor }
            'guide' { Show-SysPilotOracleGuide }
            'cfnamed' {
                Show-SysPilotCfNamedTunnel
            }
            'tsfunnel' {
                Show-SysPilotTailscaleFunnel
            }
            'oracle' {
                $r = Export-SysPilotOracleCloudInit
                Write-Host "`n  cloud-init Script exportiert:" -ForegroundColor Green
                Write-Host "  $($r.Path)" -ForegroundColor Cyan
                Write-Host "  Miniflux-Passwort: $($r.Password)" -ForegroundColor Yellow
                Write-Host "`n  So geht's (5 Min, Oracle Console):" -ForegroundColor Cyan
                Write-Host "  1) https://www.oracle.com/cloud/free/ - Account anlegen" -ForegroundColor White
                Write-Host "     (Karte nur zur Verifikation, wird NICHT belastet -" -ForegroundColor DarkGray
                Write-Host "      Always Free ist DAUERHAFT kostenlos, keine Jahresgebuehr," -ForegroundColor DarkGray
                Write-Host "      keine Renewal noetig, keine Kuendigung noetig)" -ForegroundColor DarkGray
                Write-Host "  2) Compute > Instances > Create Instance" -ForegroundColor White
                Write-Host "     Shape: VM.Standard.A1.Flex (ARM Ampere) - bis 4 OCPU/24GB" -ForegroundColor DarkGray
                Write-Host "  3) Bei 'Paste OpenSSH keys' das YAML-File einfuegen" -ForegroundColor White
                Write-Host "  4) Create -> nach ~2 Min: http://<server-ip>:8080" -ForegroundColor White
                Write-Host "     Login: admin + Passwort oben (auch auf Server:" -ForegroundColor DarkGray
                Write-Host "     /root/miniflux-url.txt)" -ForegroundColor DarkGray
                Write-Host "`n  WICHTIG - Idle-Reclaim: Oracle stoppt Always-Free-VMs, die" -ForegroundColor Yellow
                Write-Host "  ueber 7 Tage praktisch ungenutzt sind (<5% CPU)." -ForegroundColor DarkYellow
                Write-Host "  Miniflux pollt Feeds -> meist genug Aktivitaet. Falls doch:" -ForegroundColor DarkYellow
                Write-Host "  auf der VM: echo '*/15 * * * * curl -s localhost:8080' | crontab -" -ForegroundColor DarkCyan
                Write-Host "`n  Optional danach: 'Feste URL' (Cloudflare named tunnel) zeigt" -ForegroundColor Cyan
                Write-Host "  auf http://<server-ip>:8080 statt auf localhost - gleiche Steps," -ForegroundColor DarkGray
                Write-Host "  nur Port 8080 statt 80, oder Oracle Security List oeffnen." -ForegroundColor DarkGray
                if (Confirm-SysPilot 'File-Ordner oeffnen?') { Start-Process explorer.exe (Split-Path $r.Path) }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'opml' {
                $p = Export-SysPilotRssOpml
                Write-Host "  OPML geschrieben: $p" -ForegroundColor Green
                Write-Host "  Import: Miniflux > Settings > Import OPML (oder FreshRSS/Feedly)." -ForegroundColor DarkGray
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'cloud' {
                Write-Host "`n  ECHT dauerhaft kostenlose Linux-Server (Stand 2026):" -ForegroundColor Cyan
                Write-Host "  - Oracle Cloud Always Free: ARM-VM Ampere A1 - bis 4 OCPU / 24 GB RAM" -ForegroundColor White
                Write-Host "    DAUERHAFT kostenlos (kein Ablaufdatum). Ideal fuer Miniflux+Postgres." -ForegroundColor Green
                Write-Host "    Registration mit Kreditkarte noetig (nur Verifikation, keine Abbuchung)." -ForegroundColor DarkGray
                Write-Host "    https://www.oracle.com/cloud/free/" -ForegroundColor DarkCyan
                Write-Host "  - Google Cloud e2-micro: Always-Free in US-Regionen (1 GB RAM, eng." -ForegroundColor White
                Write-Host "    Rechenzentrumswahl noetig, Routing-only)." -ForegroundColor DarkGray
                Write-Host "    https://cloud.google.com/free" -ForegroundColor DarkCyan
                Write-Host "  - AWS Free Tier: NUR 12 Monate - danach kostenpflichtig!" -ForegroundColor Yellow
                Write-Host "    Nicht fuer 'lifetime free' geeignet." -ForegroundColor DarkGray
                Write-Host "`n  Günstige VPS (~2-4 EUR/Monat, verlässlich):" -ForegroundColor Cyan
                Write-Host "  - netcup VPS 200/500: ab ~2 EUR, deutsche Qualitaet," -ForegroundColor White
                Write-Host "    Doku + Support top. https://www.netcup.de/" -ForegroundColor DarkCyan
                Write-Host "  - Hetzner CX22/CX23: ~3.5-4 EUR, sehr gutes Preis/Leistung." -ForegroundColor White
                Write-Host "    https://www.hetzner.com/cloud" -ForegroundColor DarkCyan
                Write-Host "  - IONOS VPS: ~1-2 EUR Einstieg, Okay fuer Mini-Server." -ForegroundColor White
                Write-Host "    https://www.ionos.de/server/vps" -ForegroundColor DarkCyan
                Write-Host "  Bei ~1 EUR gibt es KEINEN verlässlichen Always-on-VPS -" -ForegroundColor Yellow
                Write-Host "  Oracle/GCP (0 EUR) oder eigener Rechner bleiben die besten Deals." -ForegroundColor Yellow
                Write-Host "`n  Auf dem Server: Ubuntu 22.04/24.04 + Docker, dann das" -ForegroundColor Cyan
                Write-Host "  docker-compose-File aus 'Docker-Stack' hier nutzen" -ForegroundColor DarkCyan
                Write-Host "  (Miniflux laeuft dann unter http://<server-ip>:8080)." -ForegroundColor DarkCyan
                Write-Host "`n  Alternativen ohne Cloud:" -ForegroundColor Cyan
                Write-Host "  - Alter Laptop/PC als Heimserver (Docker Desktop oder natives Linux" -ForegroundColor White
                Write-Host "    per USB). Miniflux+Postgres braucht ~1 GB RAM - auch altes" -ForegroundColor DarkGray
                Write-Host "    Geraet reicht. (Dein OpenWrt wurde warm, weil Postgres" -ForegroundColor DarkYellow
                Write-Host "    dauerhaft rechnet - auf x86-HW unproblematisch.)" -ForegroundColor DarkYellow
                Write-Host "  - Raspberry Pi 4/5 (8 GB) - images existieren." -ForegroundColor White
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'dockerinstall' {
                $w = (Get-Command winget -ErrorAction SilentlyContinue).Source
                if ($w) {
                    Write-Host "  winget install Docker.DockerDesktop ..." -ForegroundColor Cyan
                    $r = Invoke-SysPilotMonitoredProcess -FilePath $w -ArgList @('install','--id','Docker.DockerDesktop','--exact','--accept-package-agreements','--accept-source-agreements','--disable-interactivity') -Label 'Docker Desktop' -TimeoutSec 900
                    Write-Host "  $($r.Output | Select-Object -Last 3)" -ForegroundColor DarkGray
                    Write-Host "  Docker Desktop einmal starten (Taskleistanal) - dann hier erneut waehlen." -ForegroundColor Yellow
                } else { Write-Host "  winget fehlt - Docker Desktop manuell: https://docker.com" -ForegroundColor Yellow }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'docker' {
                if (-not $dok) {
                    # Docker Desktop automatisch starten falls installiert
                    $dd = "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"
                    if (Test-Path $dd) {
                        Write-Host "  Starte Docker Desktop (Daemon wird bereitgestellt) ..." -ForegroundColor Cyan
                        Start-Process $dd
                        Write-Host "  Warte bis der Docker-Daemon bereit ist (30-90s) ..." -ForegroundColor DarkGray
                        $waited = 0
                        while ($waited -lt 120) {
                            Start-Sleep -Seconds 5; $waited += 5
                            try { $v = & docker version --format '{{.Server.Version}}' 2>$null; if ($LASTEXITCODE -eq 0 -and $v) { $dok = $true; break } } catch {}
                        }
                    }
                    if (-not $dok) { Write-Host "  Docker laeuft nicht - erst Docker Desktop starten oder installieren." -ForegroundColor Yellow; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; continue }
                }
                New-Item -ItemType Directory -Force -Path $dir | Out-Null
                $pw = -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 20 | ForEach-Object {[char]$_})
                # Port-Belegung pruefen: Wenn 8080 schon ein Fremd-Service
                # beantwortet (z.B. CEF-Debug, andere Apps), auf 8081 ausweichen.
                $hostPort = 8080
                try {
                    $probe = Invoke-WebRequest 'http://localhost:8080/healthcheck' -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
                    if ($probe.Content -notmatch 'OK') { $hostPort = 8081; Write-Host "  Port 8080 ist belegt (kein Miniflux) -> nutze 8081" -ForegroundColor Yellow }
                } catch {
                    # Port frei oder nichts antwortet -> 8080 passt
                }
                $compose = @"
services:
  db:
    image: postgres:17-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: miniflux
      POSTGRES_PASSWORD: $pw
      POSTGRES_DB: miniflux
    volumes:
      - miniflux-db:/var/lib/postgresql/data
  miniflux:
    image: miniflux/miniflux:2.3.5
    restart: unless-stopped
    ports:
      - "8080:8080"
    environment:
      DATABASE_URL: postgres://miniflux:$pw@db/miniflux?sslmode=disable
      RUN_MIGRATIONS: "1"
      CREATE_ADMIN: "1"
      ADMIN_USERNAME: admin
      ADMIN_PASSWORD: $pw
      REMOVE_UNREAD_ARTICLES: "180"
      POLLING_FREQUENCY: "300"
      BATCH_OPERATIONS: "100"
    depends_on:
      db:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:8080/healthcheck || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 20
      start_period: 30s
volumes:
  miniflux-db:
"@
                $compose = $compose -replace '"8080:8080"', ('"' + $hostPort + ':8080"')
                $cf = Join-Path $dir 'docker-compose.yml'
                $compose | Set-Content -Path $cf -Encoding UTF8
                $credFile = Join-Path $dir 'ZUGANG.txt'
                "Miniflux: http://localhost:$hostPort`nLogin: admin / $pw`nCompose: $cf`n`(Passwort nur lokal in dieser Datei - nicht weitergeben)" | Set-Content -Path $credFile -Encoding UTF8
                Write-Host "  Starte Stack: docker compose up -d ..." -ForegroundColor Cyan
                Push-Location $dir
                try {
                    $r = Invoke-SysPilotMonitoredProcess -FilePath 'docker' -ArgList @('compose','up','-d') -Label 'Miniflux-Stack' -TimeoutSec 600
                    if ($r.Ok) {
                        Write-Host "  [OK] Miniflux laeuft: http://localhost:$hostPort" -ForegroundColor Green
                        Write-Host "  Login: admin / $pw (auch in $credFile)" -ForegroundColor Green
                        Write-Host "  Naechster Schritt: im Browser anmelden > Settings > Import OPML" -ForegroundColor DarkCyan
                        $opml = Export-SysPilotRssOpml
                        Write-Host "  Meine Feed-Vorschlaege als OPML: $opml" -ForegroundColor DarkCyan
                        if (Confirm-SysPilot 'Miniflux jetzt im Browser oeffnen?') { Start-Process "http://localhost:$hostPort" }
                    } else { Write-Host "  [!] Stack-Start fehlgeschlagen: $($r.Error)" -ForegroundColor Red }
                } finally { Pop-Location }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
        }
    }
}

function Show-SysPilotKiEssentialsMenu {
    <# Essential-Apps: zeigt was fehlt, bietet Install oder
       kostenlose Alternativen an (z.B. Foxit -> SumatraPDF/PDF24). #>
    $installed = @(Get-SysPilotInstalledAppNames)
    $items = foreach ($e in (Get-SysPilotKiEssentials)) {
        $hit = @($installed | Where-Object { $_ -match $e.Match } | Select-Object -First 1)
        $has = ($hit.Count -gt 0)
        $col = if($has){'Green'}else{'Yellow'}
        $mark = if($has){'[x] '}else{'[ ] '}
        @{ Label="$mark$($e.Name) - $($e.Desc)"; Color=$col; Tag=$e }
    }
    $missing = @($items | Where-Object { $_.Label -match '^\[ \]' })
    $batchLabel = "[Batch] Alle fehlenden installieren ($($missing.Count) Stueck)"
    $items = @($items) + @{ Label=$batchLabel; Color='Green'; Tag='install-all' }
    $items += @{ Label='[Browser] Browser installieren (Chrome/Brave/Tor ...)'; Color='Cyan'; Tag='browsers' }
    $items += @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
    $sel = Show-SysPilotArrowMenu -Items $items -Title 'Wichtige Apps (fehlende werden angeboten)' -Footer 'Enter = Install/Details, Esc = zurueck'
    if ($null -eq $sel) { return }
    if ($sel -eq 'browsers') { Show-SysPilotKiBrowsersMenu; return }
    if ($sel -eq 'install-all') {
        $todo = @($missing | ForEach-Object { $_.Tag })
        if ($todo.Count -eq 0) { Write-Host "  Alles vorhanden - nichts zu installieren." -ForegroundColor Green; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; return }
        if (-not (Confirm-SysPilot "$($todo.Count) fehlende Apps per winget installieren?")) { return }
        $okN = 0; $failN = 0
        foreach ($e in $todo) {
            Write-Host "`n  -> $($e.Name) ..." -ForegroundColor Cyan
            $r = Install-SysPilotKiClientApp -App $e
            Write-Host "     $($r.Message)" -ForegroundColor $(if($r.Ok){'Green'}else{'Red'})
            if ($r.Ok) { $okN++ } else { $failN++ }
        }
        Write-Host "`n  Fertig: $okN installiert, $failN fehlgeschlagen." -ForegroundColor $(if($failN -eq 0){'Green'}else{'Yellow'})
        Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
        return
    }
    $hit = @($installed | Where-Object { $_ -match $sel.Match } | Select-Object -First 1)
    if ($hit.Count -gt 0) { Write-Host "  $($sel.Name) ist bereits installiert ($($hit[0]))." -ForegroundColor Green; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; return }
    $r = Install-SysPilotKiClientApp -App $sel
    Write-Host "  $($r.Message)" -ForegroundColor $(if($r.Ok){'Green'}else{'Red'})
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
}


# =====================================================================
# HERBERT-API (OpenAI-kompatibel, localhost) + HERBERT-MCP (stdio)
# Erlaubt anderen KI-Tools (VS Code, Cline, Continue, Cursor), Herbert
# als Provider bzw. als MCP-Werkzeug einzubinden.
# =====================================================================

$script:HerbertApiStatePath = Join-Path $env:LOCALAPPDATA 'SysPilot\herbert-api.json'
$script:HerbertApiDefaultPort = 8377

function Get-SysPilotHerbertApiKey {
    <# API-Key fuer den Herbert-Endpunkt (Bearer-Auth). Leer = Auth aus. #>
    $cfg = Read-SysPilotAiAssistConfig
    if ($cfg.ApiKeyCipher) { try { return (Unprotect-SysPilotSecret $cfg.ApiKeyCipher) } catch {} }
    return ''
}

function Set-SysPilotHerbertApiKey {
    <# Setzt (oder bei leerem String loescht) den API-Key. #>
    param([string]$Key = '')
    $cfg = Read-SysPilotAiAssistConfig
    if ($Key) { $cfg | Add-Member -NotePropertyName ApiKeyCipher -NotePropertyValue (Protect-SysPilotSecret $Key.Trim()) -Force }
    else { $cfg | Add-Member -NotePropertyName ApiKeyCipher -NotePropertyValue '' -Force }
    Write-SysPilotAiAssistConfig $cfg
}

function New-SysPilotHerbertApiKey {
    <# Generiert einen zufaelligen API-Key (48 Hex-Zeichen). #>
    $bytes = New-Object byte[] 24
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return (-join ($bytes | ForEach-Object { $_.ToString('x2') }))
}

function Test-SysPilotTcpPort {
    <# Schneller localhost-Port-Check (kein Proxy, kein DNS). #>
    param([int]$Port, [int]$TimeoutMs = 800)
    try {
        $c = New-Object Net.Sockets.TcpClient
        $iar = $c.BeginConnect('127.0.0.1', $Port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne($TimeoutMs)
        if ($ok) { try { $c.EndConnect($iar) } catch { $ok = $false } }
        $c.Close()
        return [bool]$ok
    } catch { return $false }
}

function Get-SysPilotHerbertApiStatus {
    <# Laufstatus des Herbert-API-Servers (State-File + Port-Probe). #>
    $st = [pscustomobject]@{ Running=$false; Port=$script:HerbertApiDefaultPort; Pid=0; Url="http://127.0.0.1:$($script:HerbertApiDefaultPort)/v1"; Started='' }
    if (Test-Path $script:HerbertApiStatePath) {
        try {
            $j = Get-Content $script:HerbertApiStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $st.Port = [int]$j.port; $st.Pid = [int]$j.pid; $st.Started = [string]$j.started
            if ($st.Pid -gt 0 -and (Get-Process -Id $st.Pid -ErrorAction SilentlyContinue)) {
                $st.Running = Test-SysPilotTcpPort -Port $st.Port -TimeoutMs 600
            }
        } catch {}
    }
    $st.Url = "http://127.0.0.1:$($st.Port)/v1"
    return $st
}

function Get-SysPilotHerbertApiScriptPath {
    <# Pfad zu SysPilot.ps1 (modules -> Root). #>
    return (Join-Path (Split-Path $PSScriptRoot) 'SysPilot.ps1')
}

function Start-SysPilotHerbertApi {
    <# Startet den API-Server als versteckten Hintergrundprozess. #>
    param([int]$Port = 0)
    $st = Get-SysPilotHerbertApiStatus
    if ($st.Running) { return @{ Ok=$true; Message="Laeuft bereits: $($st.Url) (PID $($st.Pid))" } }
    $sp = Get-SysPilotHerbertApiScriptPath
    if (-not (Test-Path $sp)) { return @{ Ok=$false; Message="SysPilot.ps1 nicht gefunden: $sp" } }
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-STA','-File',$sp,'-Tool','herbertapi')
    if ($Port -gt 0) { $argList += @('-ApiPort', "$Port") }
    try { Start-Process powershell.exe -ArgumentList $argList | Out-Null } catch {
        return @{ Ok=$false; Message="Start fehlgeschlagen: $($_.Exception.Message)" }
    }
    # Auf State-File/Port warten (max. 20s)
    $ok = $false
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 800
        $st2 = Get-SysPilotHerbertApiStatus
        if ($st2.Running) { $ok = $true; break }
    }
    if ($ok) { return @{ Ok=$true; Message="Gestartet: $($st2.Url) (PID $($st2.Pid))" } }
    return @{ Ok=$false; Message='Server startete nicht rechtzeitig - Port belegt? Siehe Log.' }
}

function Stop-SysPilotHerbertApi {
    <# Stoppt den API-Server ueber die State-File-PID. #>
    $st = Get-SysPilotHerbertApiStatus
    if ($st.Pid -le 0) { return @{ Ok=$false; Message='Kein Herbert-API-Server registriert.' } }
    try {
        Stop-Process -Id $st.Pid -Force -ErrorAction Stop
        Remove-Item $script:HerbertApiStatePath -Force -ErrorAction SilentlyContinue
        return @{ Ok=$true; Message="Gestoppt (PID $($st.Pid))." }
    } catch { return @{ Ok=$false; Message="Stopp fehlgeschlagen: $($_.Exception.Message)" } }
}

function Start-SysPilotHerbertApiServer {
    <# Blocking: OpenAI-kompatibler HTTP-Endpoint auf 127.0.0.1.
       Endpunkte: GET /health, GET /v1/models, POST /v1/chat/completions.
       Aufgerufen via 'SysPilot.ps1 -Tool herbertapi' (versteckter Prozess). #>
    param([int]$Port = 0)
    if ($Port -le 0) { $Port = $script:HerbertApiDefaultPort }
    $listener = $null
    try {
        $listener = New-Object System.Net.HttpListener
        $listener.Prefixes.Add("http://127.0.0.1:$Port/")
        $listener.Start()
    } catch {
        Write-Host "  Herbert-API: Port $Port nicht verfuegbar: $($_.Exception.Message)" -ForegroundColor Red
        return
    }
    try {
        $dir = Split-Path $script:HerbertApiStatePath -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        @{ port=$Port; pid=$PID; started=(Get-Date).ToString('o') } | ConvertTo-Json | Set-Content $script:HerbertApiStatePath -Encoding UTF8
    } catch {}
    Write-Host "  Herbert-API laeuft: http://127.0.0.1:$Port/v1 (OpenAI-kompatibel, nur localhost)" -ForegroundColor Green
    Write-Host "  Stoppen: SysPilot -> KI-Assistenz -> Herbert-API, oder PID $PID beenden." -ForegroundColor DarkGray

    $apiKey = Get-SysPilotHerbertApiKey
    $sendJson = {
        param($ctx, $obj, [int]$code = 200)
        $json = $obj | ConvertTo-Json -Depth 12 -Compress
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        $ctx.Response.StatusCode = $code
        $ctx.Response.ContentType = 'application/json; charset=utf-8'
        $ctx.Response.Headers['Access-Control-Allow-Origin'] = '*'
        $ctx.Response.ContentLength64 = $bytes.Length
        $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    }

    # ---- Gemeinsame Request-Uebersetzung (OpenAI + Anthropic-Format) ----
    # Liefert @{ Prompt; System; History; ProviderName; ModelName; Stream }
    $buildChat = {
        param($reqBody, [bool]$anthropic = $false)
        $sysParts = @(); $hist = @(); $prompt = ''
        if ($anthropic) {
            # Anthropic: system als String oder Array von {type:'text',text}
            $sys = $reqBody.system
            if ($sys -is [string]) { if ($sys) { $sysParts += $sys } }
            elseif ($sys) {
                foreach ($b in @($sys)) { if ($b.type -eq 'text' -and $b.text) { $sysParts += [string]$b.text } }
            }
            $msgs = @($reqBody.messages)
            for ($i = 0; $i -lt $msgs.Count; $i++) {
                $m = $msgs[$i]; $role = [string]$m.role
                $content = $m.content
                $text = ''
                if ($content -is [string]) { $text = $content }
                elseif ($content) {
                    foreach ($b in @($content)) {
                        if ($b.type -eq 'text' -and $b.text) { $text += [string]$b.text }
                        # Bildbloecke haben wir nicht - werden uebersprungen
                    }
                }
                if ($i -eq ($msgs.Count - 1) -and $role -eq 'user') { $prompt = $text; continue }
                if ($role -eq 'user' -or $role -eq 'assistant') { $hist += @{ role=$role; content=$text } }
            }
            if (-not $prompt) { $prompt = [string]$msgs[-1].content }
        } else {
            $msgs = @($reqBody.messages)
            $lastIdx = $msgs.Count - 1
            for ($i = 0; $i -lt $msgs.Count; $i++) {
                $m = $msgs[$i]; $role = [string]$m.role; $content = [string]$m.content
                if ($role -eq 'system') { $sysParts += $content; continue }
                if ($i -eq $lastIdx -and $role -ne 'assistant') { $prompt = $content; continue }
                $hist += @{ role=$role; content=$content }
            }
            if (-not $prompt) { $prompt = [string]$msgs[$lastIdx].content }
        }
        $providerName = ''
        $modelName = [string]$reqBody.model
        if ($modelName -match '^herbert/(.+)$') { $providerName = $Matches[1] }
        elseif ($modelName -and $modelName -ne 'herbert' -and $modelName -ne 'auto' -and $modelName -ne 'default') {
            $providerName = $modelName
        }
        return @{
            Prompt=$prompt; System=($sysParts -join "`n"); History=$hist
            ProviderName=$providerName; ModelName=$modelName
            Stream=[bool]$reqBody.stream
        }
    }

    while ($listener.IsListening) {
        $ctx = $null
        try { $ctx = $listener.GetContext() } catch { break }
        try {
            $path = $ctx.Request.Url.AbsolutePath.TrimEnd('/')
            $method = $ctx.Request.HttpMethod
            # CORS-Preflight (Browser-Extension/andere Web-Clients)
            if ($method -eq 'OPTIONS') {
                $ctx.Response.StatusCode = 204
                $ctx.Response.Headers['Access-Control-Allow-Origin'] = '*'
                $ctx.Response.Headers['Access-Control-Allow-Methods'] = 'GET, POST, OPTIONS'
                $ctx.Response.Headers['Access-Control-Allow-Headers'] = 'Content-Type, Authorization'
                $ctx.Response.ContentLength64 = 0
                continue
            }
            # Bearer-Auth fuer /v1/* wenn ein Key konfiguriert ist
            if ($apiKey -and $path -like '/v1/*') {
                $auth = [string]$ctx.Request.Headers['Authorization']
                if ($auth -ne "Bearer $apiKey") {
                    & $sendJson $ctx @{ error=@{ message='Ungueltiger oder fehlender API-Key (Authorization: Bearer <key>)'; type='authentication_error' } } 401
                    continue
                }
            }
            if ($method -eq 'GET' -and ($path -eq '' -or $path -eq '/health')) {
                & $sendJson $ctx @{ status='ok'; service='syspilot-herbert'; version=(Get-SysPilotVersion) }
            }
            elseif ($method -eq 'GET' -and $path -eq '/v1/models') {
                # Nur BRFAHBARE Provider: localhost-Endpunkte mit tote
                # Port werden ausgefiltert (10-Min-Datei-Cache via
                # Get-SysPilotAiProviders), Remote/Cloud bleibt (Key-
                # Qualitaet wird separat getestet).
                $data = @(@{ id='herbert'; object='model'; created=0; owned_by='syspilot' })
                $usable = Get-SysPilotHerbertUsableProviders
                foreach ($p in @($usable.Usable)) {
                    $data += @{ id="herbert/$($p.Name)"; object='model'; created=0; owned_by='syspilot' }
                }
                & $sendJson $ctx @{ object='list'; data=$data }
            }
            elseif ($method -eq 'POST' -and $path -eq '/v1/chat/completions') {
                $sr = New-Object IO.StreamReader($ctx.Request.InputStream, [Text.Encoding]::UTF8)
                $raw = $sr.ReadToEnd()
                $reqBody = $null
                try { $reqBody = $raw | ConvertFrom-Json } catch {}
                if (-not $reqBody -or -not $reqBody.messages) {
                    & $sendJson $ctx @{ error=@{ message='Ungueltiger Request-Body (messages noetig)'; type='invalid_request_error' } } 400
                    continue
                }
                $chat = & $buildChat $reqBody $false
                $providerName = $chat.ProviderName
                $r = Invoke-SysPilotAiChat -Prompt $chat.Prompt -System $chat.System -ProviderName $providerName -TimeoutSec 180 -History $chat.History
                if ($r.Ok) {
                    & $sendJson $ctx @{
                        id = "chatcmpl-$([guid]::NewGuid().ToString('N').Substring(0,24))"
                        object = 'chat.completion'; created = [int][double]::Parse((Get-Date -UFormat %s))
                        model = $(if ($providerName) { "herbert/$providerName" } else { 'herbert' })
                        choices = @(@{ index=0; message=@{ role='assistant'; content=$r.Text }; finish_reason='stop' })
                        usage = @{ prompt_tokens=0; completion_tokens=0; total_tokens=0 }
                    }
                } else {
                    & $sendJson $ctx @{ error=@{ message="Herbert-Fehler: $($r.Error)"; type='server_error' } } 502
                }
            }
            elseif ($method -eq 'POST' -and $path -eq '/v1/messages') {
                # Anthropic Messages API - fuer Claude Code (ANTHROPIC_BASE_URL).
                # Unterstuetzt stream=true (SSE) und non-stream.
                $sr = New-Object IO.StreamReader($ctx.Request.InputStream, [Text.Encoding]::UTF8)
                $raw = $sr.ReadToEnd()
                $reqBody = $null
                try { $reqBody = $raw | ConvertFrom-Json } catch {}
                if (-not $reqBody -or -not $reqBody.messages) {
                    & $sendJson $ctx @{ type='error'; error=@{ type='invalid_request_error'; message='messages noetig' } } 400
                    continue
                }
                $chat = & $buildChat $reqBody $true
                $providerName = $chat.ProviderName
                $modelOut = $(if ($providerName) { "herbert/$providerName" } else { 'herbert' })
                $msgId = "msg_$([guid]::NewGuid().ToString('N').Substring(0,24))"
                $r = Invoke-SysPilotAiChat -Prompt $chat.Prompt -System $chat.System -ProviderName $providerName -TimeoutSec 300 -History $chat.History
                $text = if ($r.Ok) { [string]$r.Text } else { "Herbert-Fehler: $($r.Error)" }
                if ($chat.Stream) {
                    # SSE-Stream: ganzer Text als ein Delta (Herbert liefert
                    # ohnehin erst am Ende - kein True-Streaming noetig).
                    $ctx.Response.StatusCode = 200
                    $ctx.Response.ContentType = 'text/event-stream; charset=utf-8'
                    $ctx.Response.Headers['Cache-Control'] = 'no-cache'
                    $ctx.Response.Headers['Access-Control-Allow-Origin'] = '*'
                    $w = $ctx.Response.OutputStream
                    $enc = [Text.Encoding]::UTF8
                    $emit = {
                        param($event, $dataObj)
                        $line = "event: $event`ndata: $($dataObj | ConvertTo-Json -Depth 10 -Compress)`n`n"
                        $b = $enc.GetBytes($line); $w.Write($b, 0, $b.Length); $w.Flush()
                    }
                    & $emit 'message_start' @{ type='message_start'; message=@{ id=$msgId; type='message'; role='assistant'; model=$modelOut; content=@(); stop_reason=$null; stop_sequence=$null; usage=@{ input_tokens=0; output_tokens=0 } } }
                    & $emit 'content_block_start' @{ type='content_block_start'; index=0; content_block=@{ type='text'; text='' } }
                    & $emit 'content_block_delta' @{ type='content_block_delta'; index=0; delta=@{ type='text_delta'; text=$text } }
                    & $emit 'content_block_stop' @{ type='content_block_stop'; index=0 }
                    & $emit 'message_delta' @{ type='message_delta'; delta=@{ stop_reason='end_turn'; stop_sequence=$null }; usage=@{ output_tokens=0 } }
                    & $emit 'message_stop' @{ type='message_stop' }
                } else {
                    & $sendJson $ctx @{
                        id=$msgId; type='message'; role='assistant'; model=$modelOut
                        content=@(@{ type='text'; text=$text })
                        stop_reason='end_turn'; stop_sequence=$null
                        usage=@{ input_tokens=0; output_tokens=0 }
                    }
                }
            }
            else {
                & $sendJson $ctx @{ error=@{ message="Unbekannter Endpunkt: $method $path"; type='invalid_request_error' } } 404
            }
        } catch {
            try { & $sendJson $ctx @{ error=@{ message=$_.Exception.Message; type='server_error' } } 500 } catch {}
        } finally {
            try { $ctx.Response.Close() } catch {}
        }
    }
    Remove-Item $script:HerbertApiStatePath -Force -ErrorAction SilentlyContinue
}

function Invoke-SysPilotHerbertMcpStdio {
    <# Minimaler MCP-Server ueber stdio (newline-delimited JSON-RPC 2.0).
       Start: powershell -File SysPilot.ps1 -Tool herbertmcp
       Stellt Herbert als MCP-Werkzeuge fuer externe Clients bereit
       (VS Code, Cline, Claude Desktop, Windsurf, Devin). #>
    $protocolVersion = '2024-11-05'
    $tools = @(
        @{ name='herbert_chat'
           description='Frage an Herbert (SysPilot-KI-Assistent) stellen - nutzt die konfigurierten Provider (lokal + Cloud, mit Fallback-Kette).'
           inputSchema=@{ type='object'; properties=@{
               prompt=@{ type='string'; description='Die Frage oder Aufgabe' }
               system=@{ type='string'; description='Optional: System-Prompt' } }
             required=@('prompt') } }
        @{ name='herbert_status'
           description='Herbert-Status: konfigurierte Provider, MCP-Server, installierte Skills, letzter Fehler.'
           inputSchema=@{ type='object'; properties=@{} } }
    )
    while ($true) {
        $line = $null
        try { $line = [Console]::In.ReadLine() } catch { break }
        if ($null -eq $line) { break }
        if (-not $line.Trim()) { continue }
        $req = $null
        try { $req = $line | ConvertFrom-Json } catch { continue }
        if (-not $req) { continue }
        $hasId = ($req.PSObject.Properties.Name -contains 'id')
        if (-not $hasId) { continue }   # Notification -> keine Antwort
        $id = $req.id
        $method = [string]$req.method
        $result = $null; $rpcError = $null
        try {
            switch ($method) {
                'initialize' {
                    $result = @{ protocolVersion=$protocolVersion; capabilities=@{ tools=@{} }
                                serverInfo=@{ name='syspilot-herbert'; version='1.0.0' } }
                }
                'ping' { $result = @{} }
                'tools/list' { $result = @{ tools=$tools } }
                'tools/call' {
                    $pname = [string]$req.params.name
                    $pargs = $req.params.arguments
                    if (-not $pargs) { $pargs = [pscustomobject]@{} }
                    if ($pname -eq 'herbert_chat') {
                        $prompt = [string]$pargs.prompt
                        $sys = [string]$pargs.system
                        $chatSys = if ($sys) { $sys } else { '' }
                        $r = Invoke-SysPilotAiChat -Prompt $prompt -System $chatSys -TimeoutSec 180
                        $txt = if ($r.Ok) { $r.Text } else { "Herbert-Fehler: $($r.Error)" }
                        $result = @{ content=@(@{ type='text'; text=$txt }); isError=(-not $r.Ok) }
                    }
                    elseif ($pname -eq 'herbert_status') {
                        $provs = @(Get-SysPilotAiProviders | Where-Object { $_.Enabled })
                        $lines = @("Herbert-Status (SysPilot):", "Provider konfiguriert: $($provs.Count)")
                        foreach ($p in ($provs | Select-Object -First 10)) {
                            $lines += "  - $($p.Name) ($($p.Kind)) $($p.BaseUrl)"
                        }
                        $lines += "API-Server: $(if ((Get-SysPilotHerbertApiStatus).Running) { 'laeuft' } else { 'gestoppt' })"
                        $result = @{ content=@(@{ type='text'; text=($lines -join "`n") }); isError=$false }
                    }
                    else { $rpcError = @{ code=-32601; message="Unbekanntes Werkzeug: $pname" } }
                }
                default { $rpcError = @{ code=-32601; message="Unbekannte Methode: $method" } }
            }
        } catch {
            $rpcError = @{ code=-32603; message=$_.Exception.Message }
        }
        $resp = @{ jsonrpc='2.0'; id=$id }
        if ($rpcError) { $resp.error = $rpcError } else { $resp.result = $result }
        try { [Console]::Out.WriteLine(($resp | ConvertTo-Json -Depth 12 -Compress)) } catch {}
    }
}

function Get-SysPilotHerbertApiSnippets {
    <# Konfigurations-Snippets fuer externe KI-Tools. #>
    $st = Get-SysPilotHerbertApiStatus
    $sp = Get-SysPilotHerbertApiScriptPath
    $mcpJson = @{
        mcpServers = @{
            herbert = @{
                command = 'powershell'
                args = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $sp, '-Tool', 'herbertmcp')
            }
        }
    } | ConvertTo-Json -Depth 8
    return @{
        OpenAI  = "Provider-Typ: OpenAI-kompatibel`nBase URL: $($st.Url)`nAPI Key: syspilot (beliebig - nur localhost)`nModel: herbert  (oder herbert/<provider-name>)"
        Mcp     = $mcpJson
        Script  = $sp
    }
}

function Install-SysPilotHerbertMcpConfig {
    <# Traegt den Herbert-MCP-Server in eine externe Client-Config ein.
       -Target: 'vscode' (%APPDATA%\Code\User\mcp.json), 'cline'
       (%USERPROFILE%\.cline\data\settings\cline_mcp_settings.json)
       oder 'windsurf' (%USERPROFILE%\.codeium\windsurf\mcp_config.json). #>
    param([Parameter(Mandatory)][ValidateSet('vscode','cline','windsurf')][string]$Target)
    $snip = Get-SysPilotHerbertApiSnippets
    $herbertEntry = @{
        command = 'powershell'
        args = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $snip.Script, '-Tool', 'herbertmcp')
    }
    switch ($Target) {
        'vscode'  { $path = Join-Path $env:APPDATA 'Code\User\mcp.json';        $rootKey = 'servers' }
        'cline'   { $path = Join-Path $env:USERPROFILE '.cline\data\settings\cline_mcp_settings.json'; $rootKey = 'mcpServers' }
        'windsurf'{ $path = Join-Path $env:USERPROFILE '.codeium\windsurf\mcp_config.json'; $rootKey = 'mcpServers' }
    }
    $cfg = $null
    if (Test-Path $path) {
        try { $cfg = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $cfg = $null }
    }
    if (-not $cfg) { $cfg = [pscustomobject]@{} }
    if (-not ($cfg.PSObject.Properties.Name -contains $rootKey)) {
        $cfg | Add-Member -NotePropertyName $rootKey -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $servers = $cfg.$rootKey
    if (-not ($servers.PSObject.Properties.Name -contains 'herbert')) {
        $servers | Add-Member -NotePropertyName 'herbert' -NotePropertyValue ([pscustomobject]$herbertEntry) -Force
    } else {
        $servers.herbert = [pscustomobject]$herbertEntry
    }
    $dir = Split-Path $path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $cfg | ConvertTo-Json -Depth 10 | Set-Content $path -Encoding UTF8
    return @{ Ok=$true; Message="Herbert-MCP in $Target eingetragen: $path`n(Client ggf. neu starten.)" }
}

function Get-SysPilotBrowserExtensionDir {
    <# Pfad zum mitgelieferten Browser-Extension-Ordner. #>
    $root = Split-Path (Get-SysPilotHerbertApiScriptPath)
    $dir = Join-Path $root 'extension'
    if (Test-Path (Join-Path $dir 'manifest.json')) { return $dir }
    # Fallback: Dev-Ordner
    $dev = Join-Path (Split-Path $PSScriptRoot) 'extension'
    if (Test-Path (Join-Path $dev 'manifest.json')) { return $dev }
    return $null
}

function Install-SysPilotBrowserExtension {
    <# Oeffnet die Browser-Extension-Installations-Anleitung:
       Ordnerpfad kopieren + chrome://extensions / about:debugging oeffnen. #>
    $dir = Get-SysPilotBrowserExtensionDir
    if (-not $dir) { return @{ Ok=$false; Message='Extension-Ordner nicht gefunden.' } }
    try { $dir | Set-Clipboard } catch {}
    Write-Host "`n  Browser-Extension: $dir" -ForegroundColor Cyan
    Write-Host "  (Pfad in die Zwischenablage kopiert)" -ForegroundColor DarkGray
    Write-Host "`n  CHROME / EDGE / CHROMIUM:" -ForegroundColor Green
    Write-Host "    1) chrome://extensions oeffnen" -ForegroundColor White
    Write-Host "    2) 'Entwicklermodus' aktivieren (oben rechts)" -ForegroundColor White
    Write-Host "    3) 'Entpackte Erweiterung laden' -> Pfad einfuegen" -ForegroundColor White
    Write-Host "`n  FIREFOX:" -ForegroundColor Green
    Write-Host "    1) about:debugging#/runtime/this-firefox oeffnen" -ForegroundColor White
    Write-Host "    2) 'Temporeres Add-on laden' -> manifest.json waehlen" -ForegroundColor White
    Write-Host "`n  Funktioniert mit der Herbert-API (muss laufen: SysPilot ->" -ForegroundColor DarkGray
    Write-Host "  KI-Assistenz -> Herbert-API + MCP -> API-Server starten)." -ForegroundColor DarkGray
    $open = Read-SysPilotInput 'Browser oeffnen? [c]hrome [f]irefox [Enter]=nein' '' 'Extension'
    if ($open -eq 'c') { Start-Process 'chrome://extensions' }
    elseif ($open -eq 'f') { Start-Process 'about:debugging#/runtime/this-firefox' }
    return @{ Ok=$true; Message="Extension-Ordner: $dir" }
}

function Show-SysPilotProviderKeyAssistant {
    <# Herbert-unterstuetzte API-Key-Einrichtung: oeffnet die Signup-Seite
       des Providers, User holt den Key (Captcha = manuell), SysPilot
       traegt Provider + Key ein und testet die Verbindung.
       Ehrlich: Account-Erstellung + Captcha kann nicht automatisiert
       werden - die Seite wird geoeffnet, der Rest ist 2 Klicks. #>
    $cat = @(Get-SysPilotAiProviderCatalog | Where-Object { $_.Signup -and $_.BaseUrl })
    $cfg = Read-SysPilotAiAssistConfig
    $configured = @{}
    foreach ($p in @($cfg.Providers)) { $configured[$p.BaseUrl.ToLower().TrimEnd('/')] = $true }
    $items = foreach ($c in $cat) {
        $mark = if ($configured.ContainsKey($c.BaseUrl.ToLower().TrimEnd('/'))) { '[konfiguriert] ' } else { '' }
        @{ Label="$mark$($c.Name) - $($c.Note)"; Color=$(if($mark){'DarkGray'}else{'Cyan'}); Tag=$c }
    }
    $items += @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
    $sel = Show-SysPilotArrowMenu -Items $items -Title 'Provider-API-Key-Assistent' -Footer 'Enter = Signup-Seite oeffnen, Esc = zurueck'
    if ($null -eq $sel) { return }
    Write-Host "`n  Oeffne Signup-Seite: $($sel.Signup)" -ForegroundColor Cyan
    Write-Host "  Hinweis: Account-Erstellung und Captcha musst du selbst" -ForegroundColor DarkYellow
    Write-Host "  erledigen (ohne Login kann SysPilot den Key nicht holen)." -ForegroundColor DarkYellow
    Start-Process $sel.Signup
    $key = Read-SysPilotInput "API-Key von $($sel.Name) einfuegen (leer = nur Provider ohne Key)" '' 'Provider-Key'
    $entry = @{
        Name = $sel.Name; BaseUrl = $sel.BaseUrl; Model = $sel.Model
        Kind = 'cloud'; Enabled = $true; HasKeyInput = [bool]$key; ApiKey = $(if ($key) { $key.Trim() } else { '' })
    }
    Save-SysPilotAiProviderEntry -Entry $entry
    Write-Host "  Provider eingetragen: $($sel.Name)" -ForegroundColor Green
    if ($key) {
        Write-Host "  Teste Verbindung ..." -ForegroundColor DarkGray
        $prov = @(Get-SysPilotAiProviders | Where-Object { $_.Name -eq $sel.Name } | Select-Object -First 1)
        if ($prov.Count -gt 0) {
            $test = Test-SysPilotAiProvider -Provider $prov[0]
            if ($test.Ok) { Write-Host "  OK: $($test.Models) Modelle erreichbar." -ForegroundColor Green }
            else { Write-Host "  Test: $($test.Error)" -ForegroundColor Yellow }
        }
    }
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
}

# =====================================================================
# YOUTUBE-KEY-SCOUT: findet Videos ueber Gratis-API-Keys, holt das
# Transkript, laesst Herbert Provider-Kandidaten extrahieren und
# richtet sie ein (Signup oeffnen, Key eintragen, txt + Provider).
# =====================================================================

function Get-SysPilotJsonObjectAt {
    <# Extrahiert ein balanciertes JSON-Objekt ab Position $StartIdx
       (zeigt auf '{'). Noetig fuer ytInitialPlayerResponse. #>
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][int]$StartIdx)
    $depth = 0; $inStr = $false; $esc = $false
    for ($i = $StartIdx; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        if ($inStr) {
            if ($esc) { $esc = $false }
            elseif ($ch -eq '\') { $esc = $true }
            elseif ($ch -eq '"') { $inStr = $false }
            continue
        }
        if ($ch -eq '"') { $inStr = $true; continue }
        if ($ch -eq '{') { $depth++ }
        elseif ($ch -eq '}') {
            $depth--
            if ($depth -eq 0) { return $Text.Substring($StartIdx, $i - $StartIdx + 1) }
        }
    }
    return $null
}

function Find-SysPilotYoutubeApiKeyVideos {
    <# YouTube-Suche (HTML-Scrape von /results, kein API-Key noetig)
       nach Videos ueber kostenlose LLM-API-Keys. #>
    param([string]$Query = 'free LLM API key free tier 2026', [int]$Limit = 8)
    $headers = @{
        'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'
        'Accept-Language' = 'de-DE,de;q=0.9,en;q=0.8'
        'Cookie' = 'CONSENT=YES+cb.20210328-17-p0.en+FX+111'
    }
    $url = 'https://www.youtube.com/results?search_query=' + [uri]::EscapeDataString($Query) + '&hl=de&gl=DE'
    $html = (Invoke-WebRequest -Uri $url -Headers $headers -TimeoutSec 30 -UseBasicParsing).Content
    $videos = [ordered]@{}
    foreach ($m in [regex]::Matches($html, '"videoRenderer":\{')) {
        $block = $html.Substring($m.Index, [Math]::Min(5000, $html.Length - $m.Index))
        $idm = [regex]::Match($block, '"videoId":"([A-Za-z0-9_-]{11})"')
        if (-not $idm.Success) { continue }
        $id = $idm.Groups[1].Value
        if ($videos.Contains($id)) { continue }
        $tm = [regex]::Match($block, '"title":\{"runs":\[\{"text":"((?:[^"\\]|\\.)*)"')
        $title = if ($tm.Success) { ($tm.Groups[1].Value -replace '\\"','"' -replace '\\\\/','/') } else { '' }
        $cm = [regex]::Match($block, '"ownerText":\{"runs":\[\{"text":"((?:[^"\\]|\\.)*)"')
        $chan = if ($cm.Success) { $cm.Groups[1].Value } else { '' }
        $videos[$id] = [pscustomobject]@{ Id=$id; Title=$title; Channel=$chan; Url="https://youtu.be/$id" }
        if ($videos.Count -ge $Limit) { break }
    }
    return @($videos.Values)
}

function ConvertFrom-SysPilotTimedTextXml {
    <# Wandelt timedtext-XML (format=3) in Klartext um. #>
    param([Parameter(Mandatory)][string]$Xml)
    $parts = @()
    try {
        [xml]$doc = $Xml
        foreach ($s in @($doc.GetElementsByTagName('s'))) {
            if ($s.InnerText) { $parts += $s.InnerText }
        }
        if ($parts.Count -gt 0) { return ($parts -join '') }
    } catch {}
    # Regex-Fallback (zerstoerungsresistent)
    foreach ($m in [regex]::Matches($Xml, '<s[^>]*>([^<]*)</s>')) {
        $t = $m.Groups[1].Value
        if ($t) { $parts += ($t -replace '&amp;', '&' -replace '&lt;', '<' -replace '&gt;', '>' -replace '&#39;', "'" -replace '&quot;', '"') }
    }
    return ($parts -join '')
}

function Get-SysPilotYoutubeTranscript {
    <# Holt das Transkript eines YouTube-Videos. Primaer ueber die
       Innertube-API (ANDROID-Client, keine PO-Token noetig);
       Fallback: Watch-Seite + timedtext, dann Videobeschreibung. #>
    param([Parameter(Mandatory)][string]$VideoId, [int]$MaxChars = 30000)
    $headers = @{
        'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'
        'Accept-Language' = 'de-DE,de;q=0.9,en;q=0.8'
        'Cookie' = 'CONSENT=YES+cb.20210328-17-p0.en+FX+111'
    }
    $desc = ''
    # --- Weg 1: Innertube ANDROID player (zuverlaessigste Caption-Quelle) ---
    try {
        $ua = 'com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip'
        $body = '{"context":{"client":{"clientName":"ANDROID","clientVersion":"20.10.38","androidSdkVersion":30,"hl":"de","gl":"DE","timeZone":"UTC","userAgent":"' + $ua + '"}},"videoId":"' + $VideoId + '","contentCheckOk":true,"racyCheckOk":true}'
        $r = Invoke-WebRequest -Uri 'https://www.youtube.com/youtubei/v1/player?prettyPrint=false' -Method Post `
            -Headers @{ 'User-Agent' = $ua; 'Content-Type' = 'application/json; charset=utf-8' } -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 40 -UseBasicParsing
        $pr = $r.Content | ConvertFrom-Json
        if (-not $desc) { try { $desc = [string]$pr.videoDetails.shortDescription } catch {} }
        $tracks = @()
        try {
            $tracks = @($pr.captions.playerCaptionsTracklistRenderer.captionTracks |
                Where-Object { $_.baseUrl } | Select-Object baseUrl, languageCode)
        } catch {}
        if ($tracks.Count -gt 0) {
            $pick = @($tracks | Where-Object { $_.languageCode -match '^(de|de-DE)' } | Select-Object -First 1) +
                    @($tracks | Where-Object { $_.languageCode -match '^(en|en-US|en-GB)' } | Select-Object -First 1) +
                    @($tracks | Select-Object -First 1)
            $track = $pick[0]
            $turl = [string]$track.baseUrl
            if ($turl -notmatch '[?&]fmt=') { $turl += '&fmt=json3' }
            $raw = (Invoke-WebRequest -Uri $turl -Headers @{ 'User-Agent' = $ua } -TimeoutSec 30 -UseBasicParsing).Content
            $txt = ''
            if ($raw.TrimStart().StartsWith('{')) {
                $tj = $raw | ConvertFrom-Json
                $parts = @()
                foreach ($ev in @($tj.events)) {
                    foreach ($seg in @($ev.segs)) { if ($seg.utf8) { $parts += [string]$seg.utf8 } }
                }
                $txt = ($parts -join '')
            } else {
                $txt = ConvertFrom-SysPilotTimedTextXml -Xml $raw
            }
            $txt = ($txt -replace "`n{3,}", "`n`n").Trim()
            if ($txt.Length -gt 0) {
                if ($txt.Length -gt $MaxChars) { $txt = $txt.Substring(0, $MaxChars) }
                return $txt
            }
        }
    } catch {}
    # --- Weg 2: Watch-Seite scrapen (aelterer Fallback) ---
    try {
        $html = (Invoke-WebRequest -Uri "https://www.youtube.com/watch?v=$VideoId&hl=de" -Headers $headers -TimeoutSec 40 -UseBasicParsing).Content
        $pi = $html.IndexOf('ytInitialPlayerResponse')
        if ($pi -ge 0) {
            $bi = $html.IndexOf('{', $pi)
            $json = Get-SysPilotJsonObjectAt -Text $html -StartIdx $bi
            if ($json) {
                try { $pr2 = $json | ConvertFrom-Json } catch { $pr2 = $null }
                if ($pr2) {
                    if (-not $desc) { try { $desc = [string]$pr2.videoDetails.shortDescription } catch {} }
                    $tracks = @()
                    try {
                        $tracks = @($pr2.captions.playerCaptionsTracklistRenderer.captionTracks |
                            Where-Object { $_.baseUrl } | Select-Object baseUrl, languageCode)
                    } catch {}
                    if ($tracks.Count -gt 0) {
                        $track = $tracks | Select-Object -First 1
                        $turl = [string]$track.baseUrl
                        if ($turl -notmatch '[?&]fmt=') { $turl += '&fmt=json3' }
                        $raw = (Invoke-WebRequest -Uri $turl -Headers $headers -TimeoutSec 30 -UseBasicParsing).Content
                        $txt = ''
                        if ($raw.TrimStart().StartsWith('{')) {
                            $tj = $raw | ConvertFrom-Json
                            $parts = @()
                            foreach ($ev in @($tj.events)) {
                                foreach ($seg in @($ev.segs)) { if ($seg.utf8) { $parts += [string]$seg.utf8 } }
                            }
                            $txt = ($parts -join '')
                        } else {
                            $txt = ConvertFrom-SysPilotTimedTextXml -Xml $raw
                        }
                        $txt = ($txt -replace "`n{3,}", "`n`n").Trim()
                        if ($txt.Length -gt 0) {
                            if ($txt.Length -gt $MaxChars) { $txt = $txt.Substring(0, $MaxChars) }
                            return $txt
                        }
                    }
                }
            }
        }
    } catch {}
    # --- Weg 3: Beschreibung als letzter Fallback ---
    if ($desc) { return "[Transkript nicht verfuegbar - nur Beschreibung]`n$desc" }
    return ''
}

function Invoke-SysPilotScoutLlm {
    <# LLM-Call fuer den YouTube-Scout: erst die normale Herbert-
       Provider-Kette, dann als Fallback der KOSTENLOSE
       Pollinations-Text-Endpunkt (POST, kein Key noetig).
       System wird ueberschreibbar ('' = kein System-Prompt noetig
       fuer kleine lokale Kontexte). #>
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$System = 'Du bist ein praeziser Daten-Extraktor. Antworte nur im geforderten Format.',
        [int]$MaxTokens = 800,
        [int]$TimeoutSec = 150,
        [switch]$NoProtocol
    )
    $r = Invoke-SysPilotAiChat -Prompt $Prompt -System $System -MaxTokens $MaxTokens -TimeoutSec $TimeoutSec -NoProtocol:$NoProtocol
    if ($r.Ok -and $r.Text) { return $r }
    # Fallback: Pollinations Text-API (OpenAI-kompatibler Endpoint
    # braucht inzwischen Key - der einfache POST-Endpunkt nicht)
    try {
        $body = @{
            model = 'openai'
            messages = @(@{ role='system'; content=$System }, @{ role='user'; content=$Prompt })
            max_tokens = $MaxTokens
        } | ConvertTo-Json -Depth 8
        $resp = Invoke-RestMethod -Uri 'https://text.pollinations.ai/' -Method Post `
            -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec $TimeoutSec -ErrorAction Stop
        $txt = ''
        if ($resp -is [string]) { $txt = $resp } else { $txt = [string]$resp.choices[0].message.content }
        if ($txt) { return @{ Ok=$true; Text=$txt.Trim(); Provider='Pollinations (text)'; Model='openai'; Error='' } }
    } catch {}
    return $r
}

function Resolve-SysPilotProviderFromCatalog {
    <# Ordnet einen aus einem Transkript extrahierten Provider-Namen
       dem kuratierten SysPilot-Katalog zu (exakte/enthaltene
       Uebereinstimmung). Verhindert Halluzinierte URLs: die BaseUrl
       kommt ausschliesslich aus dem vertrauenswuerdigen Katalog. #>
    param([Parameter(Mandatory)][string]$Name, [object[]]$Catalog = @())
    if (-not $Catalog -or $Catalog.Count -eq 0) { $Catalog = @(Get-SysPilotAiProviderCatalog) }
    $qn = ($Name.ToLower() -replace '[^a-z0-9]', '')
    if ($qn.Length -lt 2) { return $null }
    $best = $null; $bestScore = 0
    foreach ($c in @($Catalog)) {
        $cn = ((($c.Name -replace '\s*\(.*?\)', '')).ToLower() -replace '[^a-z0-9]', '')
        if ($cn.Length -lt 2) { continue }
        $score = 0
        if ($cn -eq $qn) { $score = 100 }
        elseif ($cn.StartsWith($qn) -or $qn.StartsWith($cn)) { $score = 80 }
        elseif ($cn.Contains($qn) -or $qn.Contains($cn)) { $score = 60 }
        if ($score -gt $bestScore -or ($score -eq $bestScore -and $best -and $cn.Length -lt $best._cnLen)) {
            $best = $c; $bestScore = $score; $best._cnLen = $cn.Length
        }
    }
    if ($bestScore -ge 50) { return $best }
    return $null
}

function Find-SysPilotYoutubeKeyCandidates {
    <# YouTube-Scout: Suchergebnisse -> Transkripte -> Herbert
       extrahiert Provider-Kandidaten (Name|BaseUrl|Signup|Model|Note).
       Gibt vereinheitlichte Liste zurueck. #>
    param([string]$Query = 'free LLM API key free tier 2026', [int]$VideoCount = 4)
    $out = @()
    $videos = @(Find-SysPilotYoutubeApiKeyVideos -Query $Query -Limit $VideoCount)
    if ($videos.Count -eq 0) { Write-Host '  Keine YouTube-Treffer.' -ForegroundColor Yellow; return @() }
    Write-Host "  $($videos.Count) Videos gefunden - hole Transkripte ..." -ForegroundColor DarkGray
    $seen = @{}
    foreach ($v in $videos) {
        Write-Host "  -> $($v.Title)" -ForegroundColor DarkCyan
        $transcript = ''
        try { $transcript = Get-SysPilotYoutubeTranscript -VideoId $v.Id -MaxChars 5000 }
        catch { Write-Host "     Transkript fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor DarkYellow }
        if (-not $transcript) { continue }
        $prompt = @"
Du analysierst ein YouTube-Video ueber KOSTENLOSE LLM-API-Provider (API-Keys, Base-URLs, Free-Tiers).
Nenne ALLE darin erwaehnten Provider, die ein API-Key + Base-URL-System haben (z.B. OpenRouter, Groq, Gemini, DeepSeek, Mistral, Cerebras, SambaNova, SiliconFlow, GitHub Models, NVIDIA NIM, Chutes, Novita, Hyperbolic, Kimi, Z.ai, Venice, Numes, Requesty, Ollama Cloud, OpenCode Zen, Together, Fireworks, Cohere).

Antworte AUSSCHLIESSLICH mit den Provider-NAMEN, einer pro Zeile, max. 15.
KEINE URLs, keine Erklaerungen, kein Markdown, keine Nummern, keine Bestaetigungen.
Nur Namen, die wirklich im Transkript vorkommen - nicht die Beispiele oben, ausser sie werden auch genannt.

Video: $($v.Title)

Transkript/Beschreibung:
$transcript
"@
        $r = Invoke-SysPilotScoutLlm -Prompt $prompt -System 'Du bist ein praeziser Daten-Extraktor. Antworte NUR mit den geforderten Zeilen, sonst nichts.' -MaxTokens 400 -TimeoutSec 280 -NoProtocol
        if (-not $r.Ok) { Write-Host "     Herbert-Auswertung fehlgeschlagen: $($r.Error)" -ForegroundColor DarkYellow; continue }
        # Katalog fuer Name->URL-Mapping (einmalig)
        if (-not $script:_scoutCatalog) {
            try { $script:_scoutCatalog = @(Get-SysPilotAiProviderCatalog) } catch { $script:_scoutCatalog = @() }
        }
        foreach ($ln in ($r.Text -split "`r?`n")) {
            $nm = $ln.Trim().TrimStart('-','*',' ','#').TrimEnd('.',' ',':')
            $nm = $nm -replace '^\d+[.\)]\s*',''
            if ($nm.Length -lt 2 -or $nm.Length -gt 60) { continue }
            if ($nm -match '^(und|sowie|etc\.?|usw\.?|z\.b\.?|example|beispiel)\b') { continue }
            $cat = Resolve-SysPilotProviderFromCatalog -Name $nm -Catalog $script:_scoutCatalog
            if ($cat -and $cat.BaseUrl) {
                $key = $cat.BaseUrl.ToLower().TrimEnd('/')
                if ($seen.ContainsKey($key)) { continue }
                $seen[$key] = $true
                $out += [pscustomobject]@{
                    Name=$cat.Name; BaseUrl=$cat.BaseUrl; SignupUrl=$cat.Signup; Model=$cat.Model
                    ApiKey=$cat.ApiKey; HasKey=[bool]$cat.HasKey
                    Note="$($cat.Note) (Quelle: $($v.Title))"; VideoUrl=$v.Url; VideoTitle=$v.Title
                }
            } else {
                # Nicht im Katalog: trotzdem anzeigen, aber ohne URL
                $key = "name:" + $nm.ToLower()
                if ($seen.ContainsKey($key)) { continue }
                $seen[$key] = $true
                $out += [pscustomobject]@{
                    Name=$nm; BaseUrl=''; SignupUrl=''; Model=''; ApiKey=''; HasKey=$false
                    Note="Nicht im Katalog - BaseUrl/Key manuell ergaenzen (Quelle: $($v.Title))"; VideoUrl=$v.Url; VideoTitle=$v.Title
                }
            }
        }
    }
    return @($out)
}

function Show-SysPilotYoutubeKeyScout {
    <# YouTube-Scout: sucht Videos, extrahiert Provider, User waehlt,
       SysPilot oeffnet Signup, nimmt Key entgegen, schreibt die
       Key-Datei nach Dokumente\api keys\ und traegt den Provider ein. #>
    $q = Read-SysPilotInput 'YouTube-Suchbegriff (z.B. "free LLM API key 2026")' 'free LLM API key free tier 2026' 'YouTube-Scout'
    if (-not $q) { return }
    Write-Host "`n  YouTube-Scout: '$q'" -ForegroundColor Cyan
    Write-Host '  (Videos -> Transkript -> Herbert extrahiert Provider)' -ForegroundColor DarkGray
    $cands = @(Find-SysPilotYoutubeKeyCandidates -Query $q.Trim() -VideoCount 4)
    if ($cands.Count -eq 0) { Write-Host '  Keine Provider-Kandidaten extrahiert.' -ForegroundColor Yellow; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; return }
    # Bereits konfigurierte Provider markieren
    $cfg = Read-SysPilotAiAssistConfig
    $confUrls = @{}
    foreach ($p in @($cfg.Providers)) { if ($p.BaseUrl) { $confUrls[$p.BaseUrl.ToLower().TrimEnd('/')] = $true } }
    $items = foreach ($c in $cands) {
        $mark = if ($c.BaseUrl -and $confUrls.ContainsKey($c.BaseUrl.ToLower().TrimEnd('/'))) { '[vorhanden] ' } else { '' }
        $keyMark = if ($c.HasKey) { ' [Key da]' } else { '' }
        $urlTxt = if ($c.BaseUrl) { $c.BaseUrl } else { 'kein BaseUrl' }
        $signupMark = if ($c.SignupUrl) { '' } else { ' [kein Signup-Link]' }
        @{ Label="$mark$($c.Name) - $urlTxt$keyMark$signupMark"; Color=$(if($mark){'DarkGray'}else{'Green'}); Tag=$c }
    }
    $items += @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
    $sel = Show-SysPilotArrowMenu -Items $items -Title 'Gefundene Provider (aus YouTube-Videos)' -Footer 'Enter = Provider einrichten, Esc = zurueck'
    if ($null -eq $sel) { return }
    Write-Host "`n  === $($sel.Name) ===" -ForegroundColor Cyan
    Write-Host "  Base URL: $($sel.BaseUrl)" -ForegroundColor White
    Write-Host "  Model:    $($sel.Model)" -ForegroundColor White
    Write-Host "  Notiz:    $($sel.Note)" -ForegroundColor DarkGray
    if (-not $sel.BaseUrl) {
        Write-Host "`n  Kein BaseUrl im Katalog bekannt - Provider kann nicht automatisch" -ForegroundColor Yellow
        Write-Host '  eingetragen werden. Bitte manuell im Provider-Menue anlegen.' -ForegroundColor Yellow
        Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
        return
    }
    if ($sel.SignupUrl -match '^https?://') {
        Write-Host "`n  Oeffne Signup-Seite: $($sel.SignupUrl)" -ForegroundColor Cyan
        Write-Host '  WICHTIG: Account-Erstellung und Captcha musst du selbst' -ForegroundColor DarkYellow
        Write-Host '  erledigen - SysPilot kann sich nicht bei FremdProvidern einloggen.' -ForegroundColor DarkYellow
        Start-Process $sel.SignupUrl
    } else {
        Write-Host "`n  Kein Signup-Link extrahiert - bitte manuell die Key-Seite suchen." -ForegroundColor Yellow
    }
    # Key: liegt im Katalog bereits einer vor (Key-Datei), wird
    # dieser genutzt - keine erneute Abfrage noetig.
    if ($sel.HasKey -and $sel.ApiKey) {
        $key = [string]$sel.ApiKey
        Write-Host "  Key liegt bereits in einer Key-Datei vor - wird uebernommen." -ForegroundColor DarkGray
    } else {
        $key = Read-SysPilotInput "API-Key fuer $($sel.Name) einfuegen (leer = nur Provider ohne Key)" '' 'API-Key'
        $key = $(if ($key) { $key.Trim() } else { '' })
    }
    # 1) Key-Datei nach Dokumente\api keys\ (Backup-Format -> wird von
    #    Import-SysPilotAiKeyFile/Folder automatisch erkannt)
    if ($key) {
        $dir = Get-SysPilotAiKeyBackupDir
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $safe = ($sel.Name -replace '[^\w\-\. ]', '_')
        $f = Join-Path $dir "$safe.txt"
        @(
            "Name: $($sel.Name)",
            "Base URL: $($sel.BaseUrl)",
            "Modell: $($sel.Model)",
            "API Key: $key",
            "Quelle: YouTube-Scout - $($sel.VideoTitle) ($($sel.VideoUrl))",
            "Erstellt: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
        ) | Set-Content $f -Encoding UTF8
        Write-Host "  Key-Datei geschrieben: $f" -ForegroundColor Green
        $script:AiKeyCandidatesCache = $null   # Cache invalidieren
        $script:AiKeyCandidatesCacheTime = [datetime]::MinValue
    }
    # 2) Provider direkt eintragen
    $entry = @{
        Name = $sel.Name; BaseUrl = $sel.BaseUrl; Model = $sel.Model
        Kind = 'cloud'; Enabled = $true; HasKeyInput = [bool]$key; ApiKey = $key
    }
    Save-SysPilotAiProviderEntry -Entry $entry
    Write-Host "  Provider eingetragen: $($sel.Name)" -ForegroundColor Green
    if ($key) {
        Write-Host '  Teste Verbindung ...' -ForegroundColor DarkGray
        $prov = @(Get-SysPilotAiProviders | Where-Object { $_.Name -eq $sel.Name } | Select-Object -First 1)
        if ($prov.Count -gt 0) {
            $test = Test-SysPilotAiProvider -Provider $prov[0]
            if ($test.Ok) { Write-Host "  OK: $($test.Models) Modelle erreichbar." -ForegroundColor Green }
            else { Write-Host "  Test: $($test.Error)" -ForegroundColor Yellow }
        }
    }
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
}

function Get-SysPilotHerbertUsableProviders {
    <# Filtert Enabled-Provider auf Brauchbarkeit:
       - Basis: Get-SysPilotAiUsableProviders (Provider-Modus,
         Preferred-Pin, Free-Budget-Sortierung, CtxTokens-Budget)
       - localhost/127.0.0.1: TCP-Port-Probe (schnell, File-Cache via
         Get-SysPilotAiProviders)
       - Remote/Cloud: bleibt drin (Key-Qualitaet separat pruefbar)
       Wird von ALLEN Router-Syncs genutzt (OmniRoute, FreeLLMAPI,
       freelm, 9router) - Budget/Modus gilt damit ueberall.
       Rueckgabe: @{ Usable=@(); Dead=@() } #>
    $res = @{ Usable=@(); Dead=@() }
    foreach ($p in @(Get-SysPilotAiUsableProviders)) {
        $u = [string]$p.BaseUrl
        if ($u -match '^https?://(localhost|127\.0\.0\.1|\[::1\])(:\d+)?') {
            $port = 0
            try { $port = [int]([Uri]$u).Port } catch {}
            if ($port -gt 0 -and (Test-SysPilotTcpPort -Port $port -TimeoutMs 400)) {
                $res.Usable += $p
            } else { $res.Dead += $p }
        } else {
            $res.Usable += $p
        }
    }
    return $res
}

function Set-SysPilotHerbertApiAutoStart {
    <# Auto-Start-Flag in ai-assist.json (ApiAutoStart): Herbert-API
       startet automatisch mit SysPilot (Console + GUI). #>
    param([bool]$On)
    $cfg = Read-SysPilotAiAssistConfig
    if ($cfg.PSObject.Properties['ApiAutoStart']) { $cfg.ApiAutoStart = $On }
    else { $cfg | Add-Member -NotePropertyName ApiAutoStart -NotePropertyValue $On -Force }
    Write-SysPilotAiAssistConfig $cfg
    return @{ Ok=$true; On=$On }
}

function Get-SysPilotClaudeHerbertShortcut {
    <# Erstellt 'Claude via Herbert.cmd' auf dem Desktop:
       setzt ANTHROPIC_BASE_URL/AUTH_TOKEN/MODEL auf die Herbert-API
       (/v1/messages = Anthropic-kompatibel) und startet claude. #>
    $st = Get-SysPilotHerbertApiStatus
    $key = Get-SysPilotHerbertApiKey
    if (-not $key) { $key = 'syspilot' }
    $base = "http://127.0.0.1:$($st.Port)"
    $desk = [Environment]::GetFolderPath('Desktop')
    $cmd = Join-Path $desk 'Claude via Herbert.cmd'
    $model = 'herbert'
    # Sinnvoller Default: erster nutzbarer lokaler Provider, sonst 'herbert'
    $usable = Get-SysPilotHerbertUsableProviders
    $local = @($usable.Usable | Where-Object { $_.Kind -eq 'local' -or $_.BaseUrl -match '127\.0\.0\.1|localhost' } | Select-Object -First 1)
    if ($local) { $model = "herbert/$($local.Name)" }
    $body = @"
@echo off
title Claude Code via Herbert (SysPilot)
set ANTHROPIC_BASE_URL=$base
set ANTHROPIC_AUTH_TOKEN=$key
set ANTHROPIC_MODEL=$model
set ANTHROPIC_SMALL_FAST_MODEL=$model
claude %*
"@
    [IO.File]::WriteAllText($cmd, ($body -replace "`n","`r`n"), (New-Object Text.UTF8Encoding($false)))
    return @{ Ok=$true; Path=$cmd; Model=$model; Message="Shortcut erstellt: $cmd`nClaude Code nutzt jetzt Herbert ($model) ueber $base" }
}

function Install-SysPilotContinueConfig {
    <# Traegt Herbert als OpenAI-kompatiblen Provider in Continue
       (VS Code Extension) ein - merged in ~/.continue/config.json. #>
    $st = Get-SysPilotHerbertApiStatus
    $key = Get-SysPilotHerbertApiKey
    if (-not $key) { $key = 'syspilot' }
    $path = Join-Path $env:USERPROFILE '.continue\config.json'
    $cfg = $null
    if (Test-Path $path) {
        try { $cfg = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $cfg = $null }
    }
    if (-not $cfg) { $cfg = [pscustomobject]@{} }
    if (-not ($cfg.PSObject.Properties.Name -contains 'models')) {
        $cfg | Add-Member -NotePropertyName models -NotePropertyValue @() -Force
    }
    $entry = @{
        title = 'Herbert (SysPilot)'
        provider = 'openai'
        model = 'herbert'
        apiBase = "$($st.Url)"
        apiKey = $key
    }
    $models = @($cfg.models)
    $found = $false
    for ($i = 0; $i -lt $models.Count; $i++) {
        if ($models[$i].apiBase -eq $entry.apiBase -or $models[$i].title -eq 'Herbert (SysPilot)') { $models[$i] = $entry; $found = $true }
    }
    if (-not $found) { $models += $entry }
    $cfg.models = $models
    $dir = Split-Path $path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $cfg | ConvertTo-Json -Depth 10 | Set-Content $path -Encoding UTF8
    return @{ Ok=$true; Path=$path; Message="Continue-Config aktualisiert: $path`nModell 'Herbert (SysPilot)' -> $($st.Url)`n(VS Code ggf. neu laden.)" }
}

function Get-SysPilotProviderModelPlan {
    <# Erstellt den Modell-Plan eines Providers: bestes Modell
       (Resolve-SysPilotAiModel = gerankt) + Alternates fuer
       Rate-Limit-Fallback. Wird von ALLEN Router-Syncs genutzt,
       damit OmniRoute/FreeLLMAPI/freelm/9router dieselbe
       Budget-aware Auswahl sehen wie Herbert. #>
    param([Parameter(Mandatory)]$Provider, [int]$TimeoutSec = 8, [int]$Top = 5)
    $best = if ($Provider.Model) { [string]$Provider.Model } else { Resolve-SysPilotAiModel -Provider $Provider -TimeoutSec $TimeoutSec }
    # Alternates auch bei konfiguriertem Modell liefern - Router
    # koennen sie als Fallback-Kette nutzen (Rate-Limit pro Modell)
    $alts = @()
    try {
        $alts = @((Get-SysPilotAiRankedModels -Provider $Provider -TimeoutSec $TimeoutSec -Top ($Top + 1) |
            Where-Object { $_.Id -ne $best } | ForEach-Object { $_.Id } | Select-Object -First ($Top - 1)))
    } catch { $alts = @() }
    return @{ Model=$best; Models=@($best) + $alts }
}

function Save-SysPilotUsableProvidersArtifact {
    <# Schreibt %LOCALAPPDATA%\SysPilot\usable-providers.json - das
       gemeinsame Artefakt fuer ALLE Router (OmniRoute, FreeLLMAPI,
       freelm, 9router, eigene Skripte). Enthaelt pro Provider jetzt
       zusaetzlich den gerankten Modell-Plan (model + models als
       Rate-Limit-Fallback-Kette). #>
    param([object[]]$Providers)
    $file = Join-Path $env:LOCALAPPDATA 'SysPilot\usable-providers.json'
    try {
        $dir = Split-Path $file -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $list = foreach ($p in @($Providers)) {
            $plan = Get-SysPilotProviderModelPlan -Provider $p -TimeoutSec 6 -Top 4
            @{ name=$p.Name; baseUrl=$p.BaseUrl; model=$plan.Model; models=$plan.Models
               kind=$p.Kind; apiKeyPresent=([bool]$p.ApiKey) }
        }
        @{
            updated = (Get-Date).ToString('o')
            providers = @($list)
        } | ConvertTo-Json -Depth 6 | Set-Content $file -Encoding UTF8
        return $file
    } catch { return $null }
}

function Sync-SysPilotOmniRouteProviders {
    <# Synct die BRAUCHBAREN Herbert-Provider nach OmniRoute:
       - openai-compatible-syspilot-<slug>-Connections anlegen/aktualisieren
       - Syspilot-Connections, deren Provider inzwischen tot ist, loeschen
       - Fremde (User-)Connections bleiben unangetastet
       Auth: oma_live_-Token in ai-assist.json (OmniRouteToken) oder
       Env OMNIROUTE_TOKEN. OmniRoute muss laufen (Default :20128). #>
    param([string]$BaseUrl = 'http://127.0.0.1:20128', [string]$Token = '')
    $log = @()
    if (-not $Token) { $Token = [string]$env:OMNIROUTE_TOKEN }
    if (-not $Token) {
        try { $c = Read-SysPilotAiAssistConfig; $Token = [string]$c.OmniRouteToken } catch {}
    }
    if (-not $Token) { return @{ Ok=$false; Message='Kein OmniRoute-Token (ai-assist.json: OmniRouteToken oder Env OMNIROUTE_TOKEN). Token unter OmniRoute -> Settings -> Access Tokens erzeugen.' } }
    # Erreichbar?
    $port = 0; try { $port = [int]([Uri]$BaseUrl).Port } catch {}
    if ($port -gt 0 -and -not (Test-SysPilotTcpPort -Port $port -TimeoutMs 800)) {
        return @{ Ok=$false; Message="OmniRoute nicht erreichbar unter $BaseUrl - Server starten (omniroute)." }
    }
    $hdr = @{ Authorization = "Bearer $Token" }
    # OmniRoute-Modell: provider-nodes (OpenAI-kompatible Endpunkte) +
    # providers (Credentials). Connection.provider = node-id.
    # 1) Nodes + Connections laden
    $nodes = @(); $conns = @()
    try {
        $rn = Invoke-RestMethod "$BaseUrl/api/provider-nodes" -Headers $hdr -TimeoutSec 15
        $nodes = @($rn.nodes); if (-not $nodes) { $nodes = @($rn) }
    } catch { return @{ Ok=$false; Message="GET /api/provider-nodes fehlgeschlagen: $($_.Exception.Message)" } }
    try {
        $r = Invoke-RestMethod "$BaseUrl/api/providers" -Headers $hdr -TimeoutSec 15
        $conns = @($r.connections)
    } catch { return @{ Ok=$false; Message="GET /api/providers fehlgeschlagen: $($_.Exception.Message)" } }
    # 2) Brauchbare Provider -> gewuenschter Zustand
    $usable = @(Get-SysPilotHerbertUsableProviders).Usable
    $want = @{}
    foreach ($p in $usable) {
        $slug = ('syspilot-' + ($p.Name -replace '[^a-zA-Z0-9]+','-')).Trim('-').ToLower()
        if ($slug.Length -gt 60) { $slug = $slug.Substring(0,60) }
        if ($slug -notmatch '^[a-z0-9]') { $slug = 's' + $slug }
        $want[$slug] = $p
    }
    # Node-Lookup: id = openai-compatible-chat-<suffix>, Erkennung ueber
    # providerIdSuffix im Namen bzw. prefix 'syspilot-*'.
    $nodeBySlug = @{}
    foreach ($n in $nodes) {
        $id = [string]$n.id
        if ($id -match '^openai-compatible-chat-(.+)$') {
            $suf = $Matches[1]
            if ($suf -like 'syspilot-*') { $nodeBySlug[$suf] = $n }
        }
    }
    $ourNodeIds = @{}; foreach ($k in $nodeBySlug.Keys) { $ourNodeIds[[string]$nodeBySlug[$k].id] = $true }
    $mine = @($conns | Where-Object { $ourNodeIds.ContainsKey([string]$_.provider) -or ([string]$_.name) -like 'syspilot/*' })
    # 3) Loeschen: Syspilot-Connections + Nodes ohne passenden Provider mehr
    $deleted = 0
    foreach ($c in $mine) {
        $slug = ([string]$c.provider) -replace '^openai-compatible-chat-',''
        if (-not $want.ContainsKey($slug)) {
            try { Invoke-RestMethod "$BaseUrl/api/providers/$($c.id)" -Method Delete -Headers $hdr -TimeoutSec 15 | Out-Null; $deleted++; $log += "conn-geloescht: $($c.name)" } catch { $log += "loesch-fehler $($c.name): $($_.Exception.Message)" }
        }
    }
    foreach ($slug in @($nodeBySlug.Keys)) {
        if (-not $want.ContainsKey($slug)) {
            $nid = [string]$nodeBySlug[$slug].id
            try { Invoke-RestMethod "$BaseUrl/api/provider-nodes/$nid" -Method Delete -Headers $hdr -TimeoutSec 15 | Out-Null; $log += "node-geloescht: $nid" } catch { $log += "node-loesch-fehler $nid : $($_.Exception.Message)" }
        }
    }
    # 4) Upsert: Node anlegen/aktualisieren, dann Connection
    $upserted = 0; $skipped = 0
    foreach ($slug in $want.Keys) {
        $p = $want[$slug]
        $nodeId = "openai-compatible-chat-$slug"
        $node = $nodeBySlug[$slug]
        # Node fehlt -> anlegen; baseUrl geaendert -> patchen
        if (-not $node) {
            $nbody = @{
                type='openai-compatible'; apiType='chat'; name=$p.Name
                prefix=$slug; baseUrl=[string]$p.BaseUrl; providerIdSuffix=$slug
            } | ConvertTo-Json -Depth 5
            try {
                Invoke-RestMethod "$BaseUrl/api/provider-nodes" -Method Post -Headers $hdr -ContentType 'application/json' -Body $nbody -TimeoutSec 20 | Out-Null
                $nodeBySlug[$slug] = @{ id=$nodeId }
                $log += "node-erstellt: $slug"
            } catch { $skipped++; $log += "node-fehler $($p.Name): $($_.Exception.Message)"; continue }
        } elseif ([string]$node.baseUrl -ne [string]$p.BaseUrl) {
            $nbody = @{ baseUrl=[string]$p.BaseUrl } | ConvertTo-Json
            try { Invoke-RestMethod "$BaseUrl/api/provider-nodes/$nodeId" -Method Patch -Headers $hdr -ContentType 'application/json' -Body $nbody -TimeoutSec 15 | Out-Null } catch { $log += "node-patch-fehler $slug : $($_.Exception.Message)" }
        }
        $existing = @($mine | Where-Object { [string]$_.provider -eq $nodeId }) | Select-Object -First 1
        $cbody = @{ provider=$nodeId; name="syspilot/$($p.Name)"; isActive=$true }
        if ([string]$p.ApiKey) { $cbody.apiKey = [string]$p.ApiKey } else { $cbody.allowNoCredential = $true }
        $cbody = $cbody | ConvertTo-Json -Depth 5
        try {
            if ($existing) {
                Invoke-RestMethod "$BaseUrl/api/providers/$($existing.id)" -Method Patch -Headers $hdr -ContentType 'application/json' -Body $cbody -TimeoutSec 15 | Out-Null
            } else {
                Invoke-RestMethod "$BaseUrl/api/providers" -Method Post -Headers $hdr -ContentType 'application/json' -Body $cbody -TimeoutSec 20 | Out-Null
            }
            $upserted++
        } catch { $skipped++; $log += "upsert-fehler $($p.Name): $($_.Exception.Message)" }
    }
    # 5) Brauchbare-Liste als Artefakt (fuer FreeLLMAPI u.a.) -
    #    mit geranktem Modell-Plan (model + models-Fallback-Kette)
    $usableFile = Save-SysPilotUsableProvidersArtifact -Providers $usable
    $msg = "OmniRoute-Sync: $upserted upserted, $deleted entfernt, $skipped Fehler. Liste: $usableFile"
    return @{ Ok=($skipped -eq 0); Message=$msg; Log=$log }
}

# =====================================================================
# Router-Sync: OmniRoute-Client-Key, FreeLLMAPI, freelm, 9router
# =====================================================================

function Get-SysPilotOmniRouteClientKey {
    <# Client-Key fuer OmniRoute /v1/* (Inference) - separater Keytyp
       neben dem oma_live_-Admin-Token. In ai-assist.json. #>
    $c = Read-SysPilotAiAssistConfig
    return [string]$c.OmniRouteClientKey
}

function New-SysPilotOmniRouteClientKey {
    <# Erzeugt einen OmniRoute-Client-Key (POST /api/keys, Admin-Token)
       und speichert ihn in ai-assist.json. Key wird einmalig gezeigt. #>
    param([string]$BaseUrl = 'http://127.0.0.1:20128', [string]$Name = 'syspilot-herbert')
    $Token = [string](Read-SysPilotAiAssistConfig).OmniRouteToken
    if (-not $Token) { $Token = [string]$env:OMNIROUTE_TOKEN }
    if (-not $Token) { return @{ Ok=$false; Key=''; Message='Kein Admin-Token (OmniRouteToken in ai-assist.json fehlt).' } }
    try {
        $r = Invoke-RestMethod "$BaseUrl/api/keys" -Method Post -Headers @{ Authorization="Bearer $Token" } -ContentType 'application/json' -Body (@{ name=$Name } | ConvertTo-Json) -TimeoutSec 20
    } catch { return @{ Ok=$false; Key=''; Message="POST /api/keys fehlgeschlagen: $($_.Exception.Message)" } }
    $key = [string]($r.key); if (-not $key) { $key = [string]($r.apiKey) }
    if (-not $key) { $key = [string]($r.token) }
    if (-not $key) { return @{ Ok=$false; Key=''; Message='Key-Anlage ok, aber kein Key in der Antwort gefunden.' } }
    $c = Read-SysPilotAiAssistConfig
    $c | Add-Member -NotePropertyName OmniRouteClientKey -NotePropertyValue $key -Force
    Write-SysPilotAiAssistConfig $c
    return @{ Ok=$true; Key=$key; Message="Client-Key erzeugt + gespeichert (ai-assist.json: OmniRouteClientKey)." }
}

function Install-SysPilotOmniRouteKeyConfig {
    <# Traegt den OmniRoute-Client-Key als Provider in externe Tools ein.
       -Target: continue | snippet | claude | all #>
    param([ValidateSet('continue','snippet','claude','all')][string]$Target = 'all',
          [string]$BaseUrl = 'http://127.0.0.1:20128')
    $key = Get-SysPilotOmniRouteClientKey
    if (-not $key) {
        $nr = New-SysPilotOmniRouteClientKey -BaseUrl $BaseUrl
        if (-not $nr.Ok) { return $nr }
        $key = $nr.Key
    }
    $log = @()
    if ($Target -in @('continue','all')) {
        $path = Join-Path $env:USERPROFILE '.continue\config.json'
        $cfg = $null
        if (Test-Path $path) { try { $cfg = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $cfg = $null } }
        if (-not $cfg) { $cfg = [pscustomobject]@{} }
        if (-not ($cfg.PSObject.Properties.Name -contains 'models')) { $cfg | Add-Member -NotePropertyName models -NotePropertyValue @() -Force }
        $entry = @{ title='OmniRoute (SysPilot)'; provider='openai'; model='auto'; apiBase="$BaseUrl/v1"; apiKey=$key }
        $models = @($cfg.models); $found = $false
        for ($i = 0; $i -lt $models.Count; $i++) { if ($models[$i].apiBase -eq $entry.apiBase -or $models[$i].title -eq 'OmniRoute (SysPilot)') { $models[$i] = $entry; $found = $true } }
        if (-not $found) { $models += $entry }
        $cfg.models = $models
        $dir = Split-Path $path -Parent; if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $cfg | ConvertTo-Json -Depth 10 | Set-Content $path -Encoding UTF8
        $log += "Continue: $path"
    }
    if ($Target -in @('snippet','all')) {
        $log += "OpenAI-kompatibel: Base URL $BaseUrl/v1 | Model: auto | API-Key: $($key.Substring(0,[Math]::Min(10,$key.Length)))..."
        $log += "Anthropic (/api/v1/messages): Base URL $BaseUrl/api | Model: auto"
    }
    if ($Target -in @('claude','all')) {
        # Claude-Code-Shortcut mit OmniRoute als Anthropic-Endpoint
        $desk = [Environment]::GetFolderPath('Desktop')
        $lnk = Join-Path $desk 'Claude via OmniRoute.cmd'
        $body = "@echo off`r`nset ANTHROPIC_BASE_URL=$BaseUrl/api`r`nset ANTHROPIC_AUTH_TOKEN=$key`r`nset ANTHROPIC_MODEL=auto`r`nclaude %*`r`n"
        Set-Content -Path $lnk -Value $body -Encoding ASCII
        $log += "Claude-Shortcut: $lnk"
    }
    return @{ Ok=$true; Key=$key; Message=($log -join "`n") }
}

function Sync-SysPilotFreelmProviders {
    <# Synct brauchbare SysPilot-Provider als FREELM_*-Env-Vars (User-Scope)
       fuer `freelm serve`. Entfernt nur Variablen, die SysPilot selbst
       gesetzt hat (State-Datei). #>
    $statePath = Join-Path $env:LOCALAPPDATA 'SysPilot\freelm-env-state.json'
    $state = @{ Managed=@{}; Set=@() }
    if (Test-Path $statePath) { try { $state = Get-Content $statePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
    # SysPilot-Name -> (freelm-Provider, EnvVar)
    $map = @(
        @{ Pat='groq';              Prov='groq';      Env='GROQ_API_KEY' },
        @{ Pat='openrouter';        Prov='openrouter';Env='OPENROUTER_API_KEY' },
        @{ Pat='gemini|google';     Prov='google';    Env='GEMINI_API_KEY' },
        @{ Pat='mistral';           Prov='mistral';   Env='MISTRAL_API_KEY' },
        @{ Pat='cohere';            Prov='cohere';    Env='COHERE_API_KEY' },
        @{ Pat='zai|z\.ai';         Prov='zai';       Env='ZAI_API_KEY' },
        @{ Pat='cerebras';          Prov='cerebras';  Env='CEREBRAS_API_KEY' },
        @{ Pat='nvidia|\bnim\b';    Prov='nim';       Env='NVIDIA_API_KEY' },
        @{ Pat='kilo';              Prov='kilo';      Env='KILO_API_KEY' }
    )
    $usable = @(Get-SysPilotHerbertUsableProviders).Usable
    $log = @(); $set = @(); $managed = @{}
    foreach ($m in $map) {
        $p = $usable | Where-Object { $_.Name -match $m.Pat -and $_.ApiKey } | Select-Object -First 1
        if ($p) {
            $key = [string]$p.ApiKey
            [Environment]::SetEnvironmentVariable($m.Env, $key, 'User')
            Set-Item -Path "env:$($m.Env)" -Value $key -ErrorAction SilentlyContinue
            $set += $m.Env; $managed[$m.Prov] = $m.Env
            $log += "gesetzt: $($m.Env) <- $($p.Name)"
        } else {
            # Entfernen nur, wenn SysPilot die Var frueher gesetzt hat
            $prev = $state.Managed.PSObject.Properties[$m.Prov]
            if ($prev -and $prev.Value -eq $m.Env) {
                $cur = [Environment]::GetEnvironmentVariable($m.Env,'User')
                if ($cur) { [Environment]::SetEnvironmentVariable($m.Env, $null, 'User'); Remove-Item "env:$($m.Env)" -ErrorAction SilentlyContinue; $log += "entfernt: $($m.Env) (Provider nicht mehr brauchbar)" }
            }
        }
    }
    @{ Managed=$managed; Set=$set } | ConvertTo-Json -Depth 4 | Set-Content $statePath -Encoding UTF8
    # Gemeinsames Router-Artefakt mit Modell-Plan auffrischen
    try { [void](Save-SysPilotUsableProvidersArtifact -Providers $usable) } catch {}
    $n = $set.Count
    return @{ Ok=($n -gt 0); Message="freelm-Sync: $n Umgebungsvariablen gesetzt.`n$($log -join "`n")"; Log=$log }
}

function Resolve-SysPilotCustomModel {
    <# Loest ein Modell fuer einen OpenAI-kompatiblen Endpoint auf:
       1) Gerankte /models-Liste (Get-SysPilotAiRankedModels -
          dieselbe Budget-aware Auswahl wie Herbert)
       2) Fallback-Map bekannter Provider #>
    param([string]$BaseUrl, [string]$ApiKey, [string]$Name = '')
    $fallback = @{
        'deepseek'='deepseek-chat'; 'openai'='gpt-4o-mini'; 'kimi'='kimi-k2-0905-preview'
        'moonshot'='kimi-k2-0905-preview'; 'ollama'='llama3.2'; 'llama.cpp'='local'
        'herbert'='herbert'; 'omniroute'='auto'; 'venice'='venice-uncensored'
    }
    # Pseudo-Provider fuer das Ranking (BaseUrl + Key reichen fuer /models)
    $pseudo = [pscustomobject]@{ Name=$Name; BaseUrl=$BaseUrl; ApiKey=$ApiKey; Kind='cloud'; Model='' }
    try {
        $ranked = @(Get-SysPilotAiRankedModels -Provider $pseudo -TimeoutSec 8 -Top 1)
        if ($ranked.Count -gt 0 -and $ranked[0].Id) { return [string]$ranked[0].Id }
    } catch {}
    try {
        $h = @{}; if ($ApiKey) { $h.Authorization = "Bearer $ApiKey" }
        $m = Invoke-RestMethod "$BaseUrl/models" -Headers $h -TimeoutSec 8
        $ids = @($m.data | ForEach-Object { [string]$_.id })
        $ids = @($ids | Where-Object { $_ -notmatch 'realtime|embedding|whisper|tts|audio|image|dall|moderation|search|fetch' })
        if ($ids.Count -gt 0) {
            $pick = $ids | Where-Object { $_ -match 'chat|instruct' } | Select-Object -First 1
            if (-not $pick) { $pick = $ids | Where-Object { $_ -match 'flash|mini|latest' } | Select-Object -First 1 }
            if (-not $pick) { $pick = $ids[0] }
            return $pick
        }
    } catch {}
    $n = $Name.ToLower()
    foreach ($k in $fallback.Keys) { if ($n -match [regex]::Escape($k)) { return $fallback[$k] } }
    return ''
}

function Get-SysPilotFreeLlmApiInfo {
    <# FreeLLMAPI-Desktop (MSIX, Electron) erkennen: Port aus config.json,
       Session-Token aus der FreeLLMAPI.exe-Kommandozeile (--freeapi-token). #>
    $pkg = Get-ChildItem "$env:LOCALAPPDATA\Packages" -Directory -ErrorAction SilentlyContinue |
        Where-Object Name -like 'TashAhmed.FreeLLMAPI_*' | Select-Object -First 1
    if (-not $pkg) { return @{ Installed=$false } }
    $data = Join-Path $pkg.FullName 'LocalCache\Roaming\FreeLLMAPI'
    $cfgPath = Join-Path $data 'config.json'
    $port = 31415
    if (Test-Path $cfgPath) { try { $port = [int]((Get-Content $cfgPath -Raw | ConvertFrom-Json).port) } catch {} }
    $token = ''
    try {
        $proc = Get-CimInstance Win32_Process -Filter "Name='FreeLLMAPI.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match 'freeapi-token=([0-9a-f]+)' } | Select-Object -First 1
        if ($proc -and $proc.CommandLine -match 'freeapi-token=([0-9a-f]+)') { $token = $Matches[1] }
    } catch {}
    $up = Test-SysPilotTcpPort -Port $port -TimeoutMs 600
    return @{ Installed=$true; DataDir=$data; Port=$port; Token=$token; Running=$up }
}

function Sync-SysPilotFreeLlmApiProviders {
    <# Synct brauchbare SysPilot-Provider in die FreeLLMAPI-Desktop-App:
       - GET /api/keys/providers (Katalog), GET /api/keys (Ist-Zustand)
       - Fehlende brauchbare Provider werden per POST /api/keys (Katalog-
         Plattform) oder POST /api/keys/custom (beliebiger baseUrl) angelegt
       - SysPilot-eigene Zeilen (label 'syspilot-sync'), deren Provider
         unbrauchbar wurde, werden deaktiviert
       - App-eigene Keys bleiben unangetastet #>
    $info = Get-SysPilotFreeLlmApiInfo
    if (-not $info.Installed) {
        # Fallback: keys.env fuer spaeteren Import schreiben
        $dir = Join-Path $env:LOCALAPPDATA 'SysPilot\freellmapi'
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $file = Join-Path $dir 'keys.env'
        $map = @(@{ Pat='groq';Env='GROQ_API_KEY' },@{ Pat='mistral';Env='MISTRAL_API_KEY' },@{ Pat='sambanova';Env='SAMBANOVA_API_KEY' },@{ Pat='cohere';Env='COHERE_API_KEY' },@{ Pat='huggingface';Env='HUGGINGFACE_API_KEY' },@{ Pat='siliconflow';Env='SILICONFLOW_API_KEY' },@{ Pat='zai|z\.ai';Env='ZAI_API_KEY' },@{ Pat='gemini|google';Env='GEMINI_API_KEY' },@{ Pat='cerebras';Env='CEREBRAS_API_KEY' },@{ Pat='openrouter';Env='OPENROUTER_API_KEY' })
        $usable = @(Get-SysPilotHerbertUsableProviders).Usable
        $lines = @()
        foreach ($m in $map) { $p = $usable | Where-Object { $_.Name -match $m.Pat -and $_.ApiKey } | Select-Object -First 1; if ($p) { $lines += "$($m.Env)=$($p.ApiKey)" } }
        if ($lines.Count -eq 0) { return @{ Ok=$false; Message='FreeLLMAPI nicht installiert und keine Keys zum Exportieren.' } }
        $lines | Set-Content $file -Encoding ASCII
        return @{ Ok=$true; Message="FreeLLMAPI nicht installiert - keys.env exportiert: $file ($($lines.Count) Keys)." }
    }
    if (-not $info.Running -or -not $info.Token) {
        return @{ Ok=$false; Message="FreeLLMAPI installiert, aber nicht erreichbar (Port $($info.Port), Token: $(if($info.Token){'vorhanden'}else{'fehlt - App laeuft?'})). App starten." }
    }
    $base = "http://127.0.0.1:$($info.Port)"
    $hdr = @{ Authorization = "Bearer $($info.Token)" }
    # Katalog + Ist-Zustand
    try { $cat = Invoke-RestMethod "$base/api/keys/providers" -Headers $hdr -TimeoutSec 15 } catch { return @{ Ok=$false; Message="Katalog-Fehler: $($_.Exception.Message)" } }
    $platforms = @{}
    $catItems = @($cat); if ($cat.providers) { $catItems = @($cat.providers) }
    foreach ($p in $catItems) { $id = [string]$p.id; if (-not $id) { $id = [string]$p.platform }; if (-not $id) { $id = [string]$p.value }; if ($id) { $platforms[$id.ToLower()] = $id } }
    try { $keysRes = Invoke-RestMethod "$base/api/keys" -Headers $hdr -TimeoutSec 15; $existing = @($keysRes) } catch { return @{ Ok=$false; Message="GET /api/keys fehlgeschlagen: $($_.Exception.Message)" } }
    $existingPlatforms = @{}
    foreach ($k in $existing) { $existingPlatforms[[string]$k.platform] = $k }
    # Alias: SysPilot-Name -> FreeLLMAPI-Plattform-ID (sonst custom)
    $alias = @{
        'gemini'='google'; 'google'='google'; 'zai'='zhipu'; 'z.ai'='zhipu'; 'zhipu'='zhipu'
        'nvidia'='nvidia'; 'nim'='nvidia'; 'huggingface'='huggingface'; 'hf'='huggingface'
        'ollama.com'='ollama'; 'ollama (cloud)'='ollama'
    }
    $usable = @(Get-SysPilotHerbertUsableProviders).Usable
    $log = @(); $added = 0; $skipped = 0; $disabled = 0
    foreach ($p in $usable) {
        $slug = ($p.Name -replace '[^a-zA-Z0-9.]+','').ToLower()
        $plat = $null
        if ($alias.ContainsKey($slug)) { $plat = $alias[$slug] }
        elseif ($platforms.ContainsKey($slug)) { $plat = $platforms[$slug] }
        else {
            # Teilstring-Fallback auf Katalog
            foreach ($k in $platforms.Keys) { if ($slug.Contains($k) -or $k.Contains($slug)) { $plat = $platforms[$k]; break } }
        }
        $isCustom = (-not $plat)
        if ($isCustom -and -not $p.BaseUrl) { $skipped++; $log += "uebersprungen (kein Katalog-Match, keine baseUrl): $($p.Name)"; continue }
        # Bereits vorhanden?
        $have = $false
        if (-not $isCustom -and $existingPlatforms.ContainsKey($plat)) { $have = $true }
        if (-not $isCustom -and -not $have) {
            $body = @{ platform=$plat; key=[string]$p.ApiKey; label='syspilot-sync' } | ConvertTo-Json
            try { Invoke-RestMethod "$base/api/keys" -Method Post -Headers $hdr -ContentType 'application/json' -Body $body -TimeoutSec 15 | Out-Null; $added++; $log += "hinzugefuegt: $($p.Name) -> $plat" }
            catch { $skipped++; $log += "fehler $($p.Name): $($_.Exception.Message)" }
        } elseif ($isCustom) {
            # custom: nur anlegen wenn kein custom mit gleicher baseUrl existiert
            $burl = ([string]$p.BaseUrl).TrimEnd('/')
            $dup = @($existing | Where-Object { $_.platform -eq 'custom' -and ([string]$_.baseUrl).TrimEnd('/') -eq $burl })
            if ($dup.Count -eq 0 -and $p.ApiKey) {
                # Modell aufloesen: /models-Discovery, dann Fallback-Map
                $model = Resolve-SysPilotCustomModel -BaseUrl $burl -ApiKey ([string]$p.ApiKey) -Name $p.Name
                if (-not $model) { $skipped++; $log += "custom uebersprungen (kein Modell gefunden): $($p.Name)"; continue }
                $body = @{ baseUrl=$burl; apiKey=[string]$p.ApiKey; label="syspilot-sync: $($p.Name)"; model=$model } | ConvertTo-Json
                try { Invoke-RestMethod "$base/api/keys/custom" -Method Post -Headers $hdr -ContentType 'application/json' -Body $body -TimeoutSec 20 | Out-Null; $added++; $log += "custom hinzugefuegt: $($p.Name) -> $burl ($model)" }
                catch { $skipped++; $log += "custom-fehler $($p.Name): $($_.Exception.Message)" }
            } else { $skipped++; $log += "custom vorhanden: $($p.Name)" }
        } else { $skipped++; $log += "plattform vorhanden: $($p.Name) -> $plat" }
    }
    # Entfernen: nur syspilot-sync-Zeilen, deren Provider unbrauchbar
    foreach ($k in $existing) {
        if ([string]$k.label -like 'syspilot-sync*') {
            $pl = [string]$k.platform
            $stillUsable = $false
            if ($pl -eq 'custom') {
                $kb = ([string]$k.baseUrl).TrimEnd('/')
                foreach ($p in $usable) { if ($kb -and ([string]$p.BaseUrl).TrimEnd('/') -eq $kb) { $stillUsable = $true; break } }
            } else {
                foreach ($p in $usable) {
                    $slug = ($p.Name -replace '[^a-zA-Z0-9.]+','').ToLower()
                    $cand = $alias[$slug]; if (-not $cand) { $cand = $slug }
                    if ($cand -eq $pl -or $slug -eq $pl) { $stillUsable = $true; break }
                }
            }
            if (-not $stillUsable) {
                try { Invoke-RestMethod "$base/api/keys/$($k.id)" -Method Patch -Headers $hdr -ContentType 'application/json' -Body '{"enabled":false}' -TimeoutSec 15 | Out-Null; $disabled++; $log += "deaktiviert: $($k.label) ($pl)" }
                catch { $log += "disable-fehler $($k.id): $($_.Exception.Message)" }
            } elseif (-not $k.enabled) {
                try { Invoke-RestMethod "$base/api/keys/$($k.id)" -Method Patch -Headers $hdr -ContentType 'application/json' -Body '{"enabled":true}' -TimeoutSec 15 | Out-Null; $log += "reaktiviert: $($k.label) ($pl)" }
                catch { $log += "enable-fehler $($k.id): $($_.Exception.Message)" }
            }
        }
    }
    # Gemeinsames Router-Artefakt mit Modell-Plan auffrischen
    try { [void](Save-SysPilotUsableProvidersArtifact -Providers $usable) } catch {}
    $msg = "FreeLLMAPI-Sync: $added hinzugefuegt, $disabled deaktiviert, $skipped uebersprungen/fehler."
    return @{ Ok=($skipped -eq 0); Message=$msg; Log=$log }
}

function Get-SysPilotNineRouterInfo {
    <# 9router (decolua/9router, npm '9router') - eigener AI-Router,
       Default-Port 20128 (Kollision mit OmniRoute -> wir nutzen 20130). #>
    $cmd = Get-Command 9router -ErrorAction SilentlyContinue
    $pkg = Join-Path $env:APPDATA 'npm\node_modules\9router\package.json'
    $ver = ''
    if (Test-Path $pkg) { try { $ver = (Get-Content $pkg -Raw | ConvertFrom-Json).version } catch {} }
    $port = 20130
    $up = Test-SysPilotTcpPort -Port $port -TimeoutMs 600
    $cmdPath = ''; if ($cmd) { $cmdPath = $cmd.Source }
    return @{ Installed=[bool]$cmd; Cmd=$cmdPath; Version=$ver; Port=$port; Running=$up }
}

function Install-SysPilotNineRouter {
    <# npm i -g 9router (CLI-Wrapper, startet den Router). #>
    $npm = Get-Command npm -ErrorAction SilentlyContinue
    if (-not $npm) { return @{ Ok=$false; Message='npm nicht gefunden - Node.js noetig.' } }
    try {
        $out = & npm install -g 9router 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) { return @{ Ok=$true; Message="9router installiert.`n$out" } }
        return @{ Ok=$false; Message="npm install fehlgeschlagen (Exit $LASTEXITCODE):`n$($out.Substring(0,[Math]::Min(500,$out.Length)))" }
    } catch { return @{ Ok=$false; Message="npm-Fehler: $($_.Exception.Message)" } }
}

function Get-SysPilotNineRouterSession {
    <# Login gegen 9router-Dashboard (POST /api/auth/login) ->
       auth_token-Cookie-Session. Passwort-Reihenfolge:
       Parameter > ai-assist.json:NineRouterPassword >
       NINEROUTER_PASSWORD > Default '123456' (9router-Default,
       wird beim ersten Login zur Aenderung aufgefordert). #>
    param([string]$BaseUrl = 'http://127.0.0.1:20130', [string]$Password = '')
    if (-not $Password) { $Password = [string](Read-SysPilotAiAssistConfig).NineRouterPassword }
    if (-not $Password) { $Password = [string]$env:NINEROUTER_PASSWORD }
    $tries = @(); if ($Password) { $tries += $Password.Trim() }; $tries += '123456'
    foreach ($pw in ($tries | Select-Object -Unique)) {
        try {
            $r = Invoke-WebRequest "$BaseUrl/api/auth/login" -Method Post -ContentType 'application/json' `
                -Body (@{ password=$pw } | ConvertTo-Json) -SessionVariable sess -TimeoutSec 10 -ErrorAction Stop
            $j = $null; try { $j = $r.Content | ConvertFrom-Json } catch {}
            if ($j -and $j.success -eq $false) {
                # z.B. "Default password must be changed" -> kein Login
                if ($j.error -match '(?i)default|change') { return @{ Ok=$false; Message="9router verlangt Passwort-Aenderung: $($j.error) - einmalig im Dashboard ($BaseUrl) einloggen." } }
                continue
            }
            return @{ Ok=$true; Session=$sess; Password=$pw }
        } catch { continue }
    }
    return @{ Ok=$false; Message='9router-Login fehlgeschlagen (Passwort falsch oder Auth-Modus nicht password).' }
}

function Sync-SysPilotNineRouterProviders {
    <# Synct die BRAUCHBAREN Herbert-Provider (Get-SysPilotHerbertUsableProviders
       = Modus + Pin + Free-Budget-Reihenfolge) als apikey-Connections
       nach 9router (POST/PUT/DELETE /api/providers, Session-Login).
       SysPilot-eigene Zeilen: name 'syspilot-sync-<slug>'.
       Unbekannte Provider mit eigener baseUrl werden als 'custom'
       gelistet (9router provider-nodes = separater Schritt). #>
    param([string]$BaseUrl = 'http://127.0.0.1:20130', [string]$Password = '')
    $info = Get-SysPilotNineRouterInfo
    if (-not $info.Installed) { return @{ Ok=$false; Message='9router nicht installiert - zuerst installieren.' } }
    if (-not $info.Running) { return @{ Ok=$false; Message="9router laeuft nicht (Port $($info.Port) zu). Start: 9router" } }
    $sess = Get-SysPilotNineRouterSession -BaseUrl $BaseUrl -Password $Password
    if (-not $sess.Ok) { return $sess }
    $s = $sess.Session
    try {
        $ex = Invoke-RestMethod "$BaseUrl/api/providers" -WebSession $s -TimeoutSec 15
    } catch { return @{ Ok=$false; Message="GET /api/providers fehlgeschlagen: $($_.Exception.Message)" } }
    $existing = @(); if ($ex.connections) { $existing = @($ex.connections) } elseif ($ex -is [array]) { $existing = @($ex) }
    # SysPilot-Name -> 9router-Provider-ID (aus AI_PROVIDERS des Routers)
    $alias = @{
        'groq'='groq'; 'openrouter'='openrouter'; 'gemini'='gemini'; 'google'='gemini'
        'mistral'='mistral'; 'deepseek'='deepseek'; 'xai'='xai'; 'grok'='grok'; 'grok (xai)'='xai'
        'cerebras'='cerebras'; 'cohere'='cohere'; 'zai'='zai'; 'z\.ai'='zai'; 'zhipu'='zai'
        'nvidia'='nvidia'; 'nim'='nvidia'; 'huggingface'='huggingface'; 'hf'='huggingface'
        'kilo'='kilo'; 'chutes'='chutes'; 'ollama'='ollama'; 'openai'='openai'; 'anthropic'='anthropic'
    }
    $usable = @(Get-SysPilotHerbertUsableProviders).Usable
    $log = @(); $added = 0; $updated = 0; $skipped = 0; $custom = @(); $removed = 0
    foreach ($p in $usable) {
        $slug = ($p.Name -replace '[^a-zA-Z0-9.]+','').ToLower()
        $cname = "syspilot-sync-$slug"
        $prov = $null
        foreach ($k in $alias.Keys) { if ($slug -match $k) { $prov = $alias[$k]; break } }
        $have = @($existing | Where-Object { [string]$_.name -eq $cname -or [string]$_.provider -eq $prov -and [string]$_.name -like 'syspilot-sync-*' } | Select-Object -First 1)
        if (-not $prov) {
            if ($p.ApiKey) { $custom += $p.Name }
            $skipped++; continue
        }
        if (-not $p.ApiKey -and $prov -ne 'ollama') { $skipped++; $log += "kein Key: $($p.Name)"; continue }
        $body = @{ provider=$prov; authType='apikey'; name=$cname; apiKey=[string]$p.ApiKey; allowOverwrite=$true } | ConvertTo-Json
        try {
            if ($have.Count -gt 0) {
                Invoke-RestMethod "$BaseUrl/api/providers/$($have[0].id)" -Method Put -WebSession $s -ContentType 'application/json' -Body $body -TimeoutSec 15 | Out-Null
                $updated++; $log += "aktualisiert: $($p.Name) -> $prov"
            } else {
                Invoke-RestMethod "$BaseUrl/api/providers" -Method Post -WebSession $s -ContentType 'application/json' -Body $body -TimeoutSec 15 | Out-Null
                $added++; $log += "hinzugefuegt: $($p.Name) -> $prov"
            }
        } catch { $skipped++; $log += "fehler $($p.Name): $($_.Exception.Message)" }
    }
    # Veraltete syspilot-sync-Connections entfernen
    $usableSlugs = @($usable | ForEach-Object { "syspilot-sync-$(($_.Name -replace '[^a-zA-Z0-9.]+','').ToLower())" })
    foreach ($k in $existing) {
        $kn = [string]$k.name
        if ($kn -like 'syspilot-sync-*' -and ($usableSlugs -notcontains $kn)) {
            try { Invoke-RestMethod "$BaseUrl/api/providers/$($k.id)" -Method Delete -WebSession $s -TimeoutSec 10 | Out-Null; $removed++; $log += "entfernt: $kn" }
            catch { $log += "remove-fehler $kn : $($_.Exception.Message)" }
        }
    }
    # Gemeinsames Router-Artefakt mit Modell-Plan auffrischen
    try { [void](Save-SysPilotUsableProvidersArtifact -Providers $usable) } catch {}
    $msg = "9router-Sync: $added hinzugefuegt, $updated aktualisiert, $removed entfernt, $skipped uebersprungen."
    if ($custom.Count -gt 0) { $msg += " Custom-Provider (eigene baseUrl, als provider-node noetig): $($custom -join ', ')" }
    return @{ Ok=($true); Message=$msg; Log=$log }
}

function Show-SysPilotRouterSyncMenu {
    <# Router-Sync: OmniRoute (nodes+connections), Client-Key,
       FreeLLMAPI keys.env, freelm Env-Vars, 9router. #>
    while ($true) {
        Write-Host "`n  ========================================================" -ForegroundColor Cyan
        Write-Host "           ROUTER-SYNC ( brauchbare Provider teilen )" -ForegroundColor Cyan
        Write-Host "  ========================================================" -ForegroundColor Cyan
        $omni = try { (Invoke-RestMethod 'http://127.0.0.1:20128/api/health' -TimeoutSec 3).status } catch { 'aus' }
        $ck = Get-SysPilotOmniRouteClientKey
        $ckTxt = 'fehlt'; if ($ck) { $ckTxt = 'gesetzt' }
        Write-Host "  OmniRoute: $omni | Client-Key: $ckTxt" -ForegroundColor DarkGray
        $nr = Get-SysPilotNineRouterInfo
        Write-Host "  9router: $(if($nr.Installed){"installiert v$($nr.Version)"}else{'nicht installiert'}) | Port $($nr.Port): $(if($nr.Running){'laeuft'}else{'aus'})" -ForegroundColor DarkGray
        $items = @(
            @{ Label='[O] OmniRoute: Provider-Sync (Nodes + Connections)'; Color='Green'; Tag='omni' }
            @{ Label='[K] OmniRoute: Client-Key erzeugen'; Color='Cyan'; Tag='key' }
            @{ Label='[X] OmniRoute-Key eintragen (Continue/Claude/Snippet)'; Color='Cyan'; Tag='keycfg' }
            @{ Label='[F] FreeLLMAPI: keys.env schreiben'; Color='Green'; Tag='freellmapi' }
            @{ Label='[L] freelm: Umgebungsvariablen syncen'; Color='Green'; Tag='freelm' }
            @{ Label='[9] 9router: Status / Install / Sync'; Color='Cyan'; Tag='9r' }
            @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
        )
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'Router-Sync' -Footer 'Enter = Aktion, Esc = zurueck'
        if ($null -eq $sel) { return }
        switch ($sel) {
            'omni' {
                $cfg = Read-SysPilotAiAssistConfig
                if (-not $cfg.OmniRouteToken -and -not $env:OMNIROUTE_TOKEN) {
                    Write-Host '  OmniRoute-Token noetig (Settings -> Access Tokens, oma_live_...):' -ForegroundColor Yellow
                    $tok = Read-SysPilotInput 'Token einfuegen (leer = abbrechen)' '' 'OmniRoute'
                    if ($tok) {
                        $cfg | Add-Member -NotePropertyName OmniRouteToken -NotePropertyValue $tok.Trim() -Force
                        Write-SysPilotAiAssistConfig $cfg
                        Write-Host '  Token gespeichert.' -ForegroundColor Green
                    } else { Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; continue }
                }
                $r = Sync-SysPilotOmniRouteProviders
                Write-Host "`n  $($r.Message)" -ForegroundColor $(if($r.Ok){'Green'}else{'Yellow'})
                if ($r.Log) { $r.Log | Select-Object -First 15 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray } }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'key' {
                $r = New-SysPilotOmniRouteClientKey
                Write-Host "`n  $($r.Message)" -ForegroundColor $(if($r.Ok){'Green'}else{'Red'})
                if ($r.Key) { Write-Host "  Key: $($r.Key)" -ForegroundColor Yellow }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'keycfg' {
                $t = Read-SysPilotInput 'Ziel: continue | snippet | claude | all (Enter=all)' 'all' 'OmniRoute-Key'
                $r = Install-SysPilotOmniRouteKeyConfig -Target $(if($t){$t}else{'all'})
                Write-Host "`n  $($r.Message)" -ForegroundColor $(if($r.Ok){'Green'}else{'Red'})
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'freellmapi' {
                $r = Sync-SysPilotFreeLlmApiProviders
                Write-Host "`n  $($r.Message)" -ForegroundColor $(if($r.Ok){'Green'}else{'Yellow'})
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'freelm' {
                $r = Sync-SysPilotFreelmProviders
                Write-Host "`n  $($r.Message)" -ForegroundColor $(if($r.Ok){'Green'}else{'Yellow'})
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            '9r' {
                $info = Get-SysPilotNineRouterInfo
                Write-Host "`n  9router: $(if($info.Installed){"installiert v$($info.Version) ($($info.Cmd))"}else{'nicht installiert'})" -ForegroundColor Cyan
                Write-Host "  Port $($info.Port): $(if($info.Running){'LAEUFT'}else{'aus'})" -ForegroundColor $(if($info.Running){'Green'}else{'DarkGray'})
                $act = Read-SysPilotInput 'Aktion: [i]nstallieren, [s]tarten, [y]sync, [p]asswort, [Enter]=abbrechen' '' '9router'
                if ($act -eq 'i' -and -not $info.Installed) {
                    $r = Install-SysPilotNineRouter
                    Write-Host "  $($r.Message)" -ForegroundColor $(if($r.Ok){'Green'}else{'Red'})
                } elseif ($act -eq 's') {
                    Start-Process -FilePath '9router' -WindowStyle Hidden -ErrorAction SilentlyContinue
                    Write-Host '  9router-Start angestossen - bitte kurz warten, dann [y]sync.' -ForegroundColor Yellow
                } elseif ($act -eq 'p') {
                    $pw = Read-SysPilotInput '9router-Dashboard-Passwort (leer = loeschen)' '' '9router-Passwort'
                    $cfg9 = Read-SysPilotAiAssistConfig
                    if ($pw) { $cfg9 | Add-Member -NotePropertyName NineRouterPassword -NotePropertyValue $pw.Trim() -Force; Write-Host '  Passwort gespeichert (ai-assist.json).' -ForegroundColor Green }
                    else { if ($cfg9.PSObject.Properties['NineRouterPassword']) { $cfg9.NineRouterPassword = '' }; Write-Host '  Passwort-Eintrag entfernt - Default/Env wird genutzt.' -ForegroundColor DarkGray }
                    Write-SysPilotAiAssistConfig $cfg9
                } elseif ($act -eq 'y') {
                    $r = Sync-SysPilotNineRouterProviders
                    Write-Host "  $($r.Message)" -ForegroundColor $(if($r.Ok){'Green'}else{'Yellow'})
                    if ($r.Log) { $r.Log | Select-Object -First 15 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray } }
                    if (-not $r.Ok -and $r.Message -match '(?i)passwort|login') {
                        Write-Host '  Tipp: [p] Passwor konfigieren oder im Dashboard ($($info.Port)) einmalig anmelden.' -ForegroundColor DarkYellow
                    }
                }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
        }
    }
}

function Show-SysPilotOmniRouteSetup {
    <# Eigener Einrichtungs-Flow fuer OmniRoute (npm i -g omniroute,
       localhost:20128): Status, Admin-Token, Provider-Sync,
       Client-Key, externe Tools (Continue/Claude). #>
    while ($true) {
        $up = Test-SysPilotTcpPort -Port 20128 -TimeoutMs 800
        $cfg = Read-SysPilotAiAssistConfig
        $tok = [string]$cfg.OmniRouteToken; if (-not $tok) { $tok = [string]$env:OMNIROUTE_TOKEN }
        Write-Host "`n  ================= OmniRoute Setup =================" -ForegroundColor Cyan
        Write-Host "  Router: $(if($up){'LAEUFT (localhost:20128)'}else{'aus - Start: omniroute'})" -ForegroundColor $(if($up){'Green'}else{'DarkGray'})
        Write-Host "  Admin-Token: $(if($tok){'gesetzt'}else{'FEHLT (Settings -> Access Tokens, oma_live_...)'})" -ForegroundColor $(if($tok){'Green'}else{'Yellow'})
        $items = @(
            @{ Label='[S] Provider-Sync (brauchbare SysPilot-Provider -> OmniRoute)'; Color='Green'; Tag='sync' }
            @{ Label='[K] Client-Key erzeugen (fuer /v1-Inference)'; Color='Cyan'; Tag='key' }
            @{ Label='[X] Key in externe Tools eintragen (Continue/Claude/Snippet)'; Color='Cyan'; Tag='keycfg' }
            @{ Label='[T] Admin-Token aendern'; Color='Yellow'; Tag='token' }
            @{ Label='[>] OmniRoute starten'; Color='Green'; Tag='start' }
            @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
        )
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'OmniRoute einrichten'
        if ($null -eq $sel) { return }
        switch ($sel) {
            'sync' {
                if (-not $tok) {
                    Write-Host '  Admin-Token noetig (Settings -> Access Tokens, oma_live_...):' -ForegroundColor Yellow
                    $t2 = Read-SysPilotInput 'Token einfuegen (leer = abbrechen)' '' 'OmniRoute'
                    if ($t2) { $cfg | Add-Member -NotePropertyName OmniRouteToken -NotePropertyValue $t2.Trim() -Force; Write-SysPilotAiAssistConfig $cfg; Write-Host '  Token gespeichert.' -ForegroundColor Green }
                    else { Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; continue }
                }
                $r = Sync-SysPilotOmniRouteProviders
                Write-Host "`n  $($r.Message)" -ForegroundColor $(if($r.Ok){'Green'}else{'Yellow'})
                if ($r.Log) { $r.Log | Select-Object -First 15 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray } }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'key'  { $r = New-SysPilotOmniRouteClientKey; Write-Host "`n  $($r.Message)" -ForegroundColor $(if($r.Ok){'Green'}else{'Red'}); if ($r.Key) { Write-Host "  Key: $($r.Key)" -ForegroundColor Yellow }; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
            'keycfg'{ $t = Read-SysPilotInput 'Ziel: continue | snippet | claude | all (Enter=all)' 'all' 'OmniRoute-Key'; $r = Install-SysPilotOmniRouteKeyConfig -Target $(if($t){$t}else{'all'}); Write-Host "`n  $($r.Message)" -ForegroundColor $(if($r.Ok){'Green'}else{'Red'}); Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
            'token'{
                Write-Host '  Admin-Token (oma_live_...) aus OmniRoute Settings -> Access Tokens:' -ForegroundColor Yellow
                $t2 = Read-SysPilotInput 'Token einfuegen (leer = unveraendert)' '' 'OmniRoute'
                if ($t2) { $cfg | Add-Member -NotePropertyName OmniRouteToken -NotePropertyValue $t2.Trim() -Force; Write-SysPilotAiAssistConfig $cfg; Write-Host '  Token gespeichert.' -ForegroundColor Green }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'start' {
                if ($up) { Write-Host '  Laeuft bereits.' -ForegroundColor DarkGray }
                else { Start-Process -FilePath 'omniroute' -WindowStyle Hidden -ErrorAction SilentlyContinue; Write-Host '  Start angestossen - Dashboard: http://localhost:20128' -ForegroundColor Yellow }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
        }
    }
}

function Show-SysPilotFreeLlmApiSetup {
    <# Einrichtungs-Flow fuer FreeLLMAPI (Docker, localhost:31415):
       Erkennung, Docker-Start-Anleitung, Provider-Sync, keys.env. #>
    while ($true) {
        $info = Get-SysPilotFreeLlmApiInfo
        Write-Host "`n  ================= FreeLLMAPI Setup =================" -ForegroundColor Cyan
        if ($info.Installed) {
            Write-Host "  App: installiert (Port $($info.Port))" -ForegroundColor Green
            Write-Host "  Status: $(if($info.Running){'LAEUFT'}else{'aus'}) | Token: $(if($info.Token){'gefunden'}else{'fehlt - App starten'})" -ForegroundColor $(if($info.Running -and $info.Token){'Green'}else{'Yellow'})
        } else {
            Write-Host "  App: NICHT installiert" -ForegroundColor Yellow
            Write-Host "  FreeLLMAPI = Docker-Image tashfeenahmed/freellmapi (87 Free-Provider)" -ForegroundColor DarkGray
            Write-Host "  Install: docker run -d -p 31415:31415 --name freellmapi tashfeenahmed/freellmapi" -ForegroundColor DarkGray
        }
        $items = @(
            @{ Label='[S] Provider-Sync (brauchbare SysPilot-Provider -> FreeLLMAPI)'; Color='Green'; Tag='sync' }
            @{ Label='[E] keys.env exportieren (fuer spaeteren Import)'; Color='Cyan'; Tag='env' }
            @{ Label='[D] Docker-Installations-Anleitung'; Color='Yellow'; Tag='docker' }
            @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
        )
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'FreeLLMAPI einrichten'
        if ($null -eq $sel) { return }
        switch ($sel) {
            'sync' {
                $r = Sync-SysPilotFreeLlmApiProviders
                Write-Host "`n  $($r.Message)" -ForegroundColor $(if($r.Ok){'Green'}else{'Yellow'})
                if ($r.Log) { $r.Log | Select-Object -First 15 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray } }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'env'  {
                # App laeuft -> Live-Sync; sonst keys.env-Export (Fallback im Sync)
                $r = Sync-SysPilotFreeLlmApiProviders
                Write-Host "`n  $($r.Message)" -ForegroundColor $(if($r.Ok){'Green'}else{'Yellow'})
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'docker' {
                Write-Host "`n  --- FreeLLMAPI per Docker ---" -ForegroundColor Cyan
                Write-Host "  1) Docker Desktop/Engine noetig ( winget install Docker.DockerDesktop )" -ForegroundColor White
                Write-Host "  2) docker run -d --name freellmapi -p 31415:31415 tashfeenahmed/freellmapi" -ForegroundColor White
                Write-Host "  3) App/Container starten, dann hier [S] Provider-Sync" -ForegroundColor White
                Write-Host "  API: http://127.0.0.1:31415 - Token aus der App (--freeapi-token)" -ForegroundColor DarkGray
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
        }
    }
}

function Show-SysPilotFreelmSetup {
    <# Einrichtungs-Flow fuer freelm (pip/npm): Status, Env-Vars-Sync,
       Serve-Hinweis. #>
    while ($true) {
        $cmd = Get-Command freelm -ErrorAction SilentlyContinue
        Write-Host "`n  ==================== freelm Setup ====================" -ForegroundColor Cyan
        Write-Host "  CLI: $(if($cmd){"installiert ($($cmd.Source))"}else{'nicht gefunden - pip install freelm'})" -ForegroundColor $(if($cmd){'Green'}else{'Yellow'})
        $items = @(
            @{ Label='[E] Provider-Env-Vars syncen (FREELM_*-Keys aus brauchbaren Providern)'; Color='Green'; Tag='env' }
            @{ Label='[I] freelm installieren (pip install freelm)'; Color='Cyan'; Tag='inst' }
            @{ Label='[S] freelm serve starten (Router-Endpoint)'; Color='Yellow'; Tag='serve' }
            @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
        )
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'freelm einrichten'
        if ($null -eq $sel) { return }
        switch ($sel) {
            'env'   { $r = Sync-SysPilotFreelmProviders; Write-Host "`n  $($r.Message)" -ForegroundColor $(if($r.Ok){'Green'}else{'Yellow'}); if ($r.Log) { $r.Log | Select-Object -First 12 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray } }; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
            'inst'  {
                if ($cmd) { Write-Host '  Bereits installiert.' -ForegroundColor DarkGray }
                else {
                    $py = $null; if (Get-Command Get-SysPilotPythonExeForPip -ErrorAction SilentlyContinue) { $py = Get-SysPilotPythonExeForPip }
                    if (-not $py) { $py = (Get-Command python.exe -ErrorAction SilentlyContinue).Source }
                    if ($py) { $pr = Invoke-SysPilotMonitoredProcess -FilePath $py -ArgList @('-m','pip','install','freelm') -Label 'pip install freelm' -TimeoutSec 300; Write-Host "  Exit: $($pr.ExitCode)" -ForegroundColor $(if($pr.ExitCode -eq 0){'Green'}else{'Red'}) }
                    else { Write-Host '  Kein python.exe gefunden.' -ForegroundColor Red }
                }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'serve' {
                Write-Host "`n  freelm serve startet den Router (OpenAI-kompatibel)." -ForegroundColor Cyan
                Write-Host "  Vorher [E] Env-Vars syncen, dann: freelm serve" -ForegroundColor DarkGray
                if ($cmd) { Start-Process -FilePath 'freelm' -ArgumentList 'serve' -WindowStyle Hidden -ErrorAction SilentlyContinue; Write-Host '  Start angestossen.' -ForegroundColor Yellow }
                else { Write-Host '  Erst installieren ([I]).' -ForegroundColor DarkYellow }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
        }
    }
}

function Show-SysPilotNineRouterSetup {
    <# Eigener Einrichtungs-Flow fuer 9router (npm i -g 9router,
       Port 20130): Status, Start, Passwort, Provider-Sync. #>
    while ($true) {
        $info = Get-SysPilotNineRouterInfo
        $cfg = Read-SysPilotAiAssistConfig
        $hasPw = [bool]([string]$cfg.NineRouterPassword) -or [bool]$env:NINEROUTER_PASSWORD
        Write-Host "`n  ================= 9router Setup =================" -ForegroundColor Cyan
        Write-Host "  Installiert: $(if($info.Installed){"v$($info.Version)"}else{'nein - npm i -g 9router'})" -ForegroundColor $(if($info.Installed){'Green'}else{'Yellow'})
        Write-Host "  Router: $(if($info.Running){'LAEUFT (localhost:' + $info.Port + ')'}else{'aus'}) | Passwort: $(if($hasPw){'gesetzt'}else{'Default/Env'})" -ForegroundColor $(if($info.Running){'Green'}else{'DarkGray'})
        $items = @(
            @{ Label='[S] Provider-Sync (brauchbare SysPilot-Provider -> 9router)'; Color='Green'; Tag='sync' }
            @{ Label='[>] 9router starten'; Color='Green'; Tag='start' }
            @{ Label='[I] 9router installieren (npm i -g 9router)'; Color='Cyan'; Tag='inst' }
            @{ Label='[P] Dashboard-Passwort konfigurieren'; Color='Yellow'; Tag='pw' }
            @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
        )
        $sel = Show-SysPilotArrowMenu -Items $items -Title '9router einrichten'
        if ($null -eq $sel) { return }
        switch ($sel) {
            'sync'  { $r = Sync-SysPilotNineRouterProviders; Write-Host "`n  $($r.Message)" -ForegroundColor $(if($r.Ok){'Green'}else{'Yellow'}); if ($r.Log) { $r.Log | Select-Object -First 15 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray } }; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
            'start' {
                if ($info.Running) { Write-Host '  Laeuft bereits.' -ForegroundColor DarkGray }
                else { Start-Process -FilePath '9router' -WindowStyle Hidden -ErrorAction SilentlyContinue; Write-Host "  Start angestossen - Dashboard: http://localhost:$($info.Port)" -ForegroundColor Yellow }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'inst'  { if ($info.Installed) { Write-Host '  Bereits installiert.' -ForegroundColor DarkGray } else { $r = Install-SysPilotNineRouter; Write-Host "  $($r.Message)" -ForegroundColor $(if($r.Ok){'Green'}else{'Red'}) }; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
            'pw'    {
                Write-Host '  Dashboard-Passwort (9router Settings; Default beim Erststart aendern):' -ForegroundColor Yellow
                $pw = Read-SysPilotInput 'Passwort einfuegen (leer = loeschen)' '' '9router-Passwort'
                if ($pw) { $cfg | Add-Member -NotePropertyName NineRouterPassword -NotePropertyValue $pw.Trim() -Force; Write-SysPilotAiAssistConfig $cfg; Write-Host '  Gespeichert (ai-assist.json).' -ForegroundColor Green }
                else { if ($cfg.PSObject.Properties['NineRouterPassword']) { $cfg.NineRouterPassword = '' }; Write-SysPilotAiAssistConfig $cfg; Write-Host '  Eintrag entfernt - Default/Env wird genutzt.' -ForegroundColor DarkGray }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
        }
    }
}

function Show-SysPilotHerbertApiMenu {
    <# Herbert-API + MCP: Server starten/stoppen, Snippets fuer
       externe KI-Tools (VS Code, Cline, Windsurf, Continue). #>
    while ($true) {
        $st = Get-SysPilotHerbertApiStatus
        Write-Host "`n  ========================================================" -ForegroundColor Cyan
        Write-Host "           HERBERT-API + MCP ( fuer externe KI-Tools )" -ForegroundColor Cyan
        Write-Host "  ========================================================" -ForegroundColor Cyan
        $stateCol = if ($st.Running) { 'Green' } else { 'DarkGray' }
        $stateTxt = if ($st.Running) { "LAEUFT - $($st.Url) (PID $($st.Pid), seit $($st.Started))" } else { 'gestoppt' }
        Write-Host "  Status: $stateTxt" -ForegroundColor $stateCol
        Write-Host "  OpenAI-kompatibel: Base URL + /v1/models + /v1/chat/completions" -ForegroundColor DarkGray
        Write-Host "  MCP (stdio): SysPilot.ps1 -Tool herbertmcp" -ForegroundColor DarkGray
        $items = @(
            @{ Label='[>] API-Server starten (OpenAI-Provider fuer VS Code/Cline/Continue)'; Color='Green'; Tag='start' }
            @{ Label='[x] API-Server stoppen'; Color='Yellow'; Tag='stop' }
            @{ Label='[=] Provider-Snippet anzeigen (Base URL, Key, Model)'; Color='Cyan'; Tag='snippet' }
            @{ Label='[M] MCP-Snippet anzeigen ( fuer VS Code/Cline mcp.json )'; Color='Cyan'; Tag='mcpsnip' }
            @{ Label='[W] Herbert-MCP eintragen: VS Code'; Color='Green'; Tag='w-vscode' }
            @{ Label='[W] Herbert-MCP eintragen: Cline'; Color='Green'; Tag='w-cline' }
            @{ Label='[W] Herbert-MCP eintragen: Windsurf'; Color='Green'; Tag='w-windsurf' }
            @{ Label='[K] API-Key anzeigen / neuen generieren'; Color='Yellow'; Tag='apikey' }
            @{ Label='[T] Provider-Brauchbarkeit anzeigen (lokal tot = raus)'; Color='Cyan'; Tag='usable' }
            @{ Label='[A] Auto-Start mit SysPilot'; Color='Cyan'; Tag='autostart' }
            @{ Label='[C] Claude-Code-Verknuepfung (Desktop, Anthropic-API)'; Color='Green'; Tag='claude' }
            @{ Label='[V] Continue (VS Code) eintragen'; Color='Green'; Tag='continue' }
            @{ Label='[O] Router-Sync (OmniRoute/FreeLLMAPI/freelm/9router)'; Color='Green'; Tag='omni' }
            @{ Label='[E] Browser-Extension installieren (Chrome/Firefox)'; Color='Cyan'; Tag='ext' }
            @{ Label='[P] Provider-API-Key-Assistent (Signup + Key eintragen)'; Color='Green'; Tag='pkey' }
            @{ Label='Zurueck'; Color='DarkGray'; Tag=$null }
        )
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'Herbert-API + MCP' -Footer 'Enter = Aktion, Esc = zurueck'
        if ($null -eq $sel) { return }
        switch ($sel) {
            'start' {
                $portTxt = Read-SysPilotInput 'Port (Enter = 8377)' '' 'Herbert-API'
                $port = 0; if ($portTxt -match '^\d+$') { $port = [int]$portTxt }
                $r = Start-SysPilotHerbertApi -Port $port
                Write-Host "  $($r.Message)" -ForegroundColor $(if($r.Ok){'Green'}else{'Red'})
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'stop' {
                $r = Stop-SysPilotHerbertApi
                Write-Host "  $($r.Message)" -ForegroundColor $(if($r.Ok){'Green'}else{'Yellow'})
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'snippet' {
                $sn = Get-SysPilotHerbertApiSnippets
                Write-Host "`n  --- OpenAI-kompatibler Provider ---" -ForegroundColor Cyan
                Write-Host $sn.OpenAI -ForegroundColor White
                try { $sn.OpenAI | Set-Clipboard; Write-Host '  (in Zwischenablage)' -ForegroundColor DarkGray } catch {}
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'mcpsnip' {
                $sn = Get-SysPilotHerbertApiSnippets
                Write-Host "`n  --- MCP-Config (mcp.json) ---" -ForegroundColor Cyan
                Write-Host $sn.Mcp -ForegroundColor White
                try { $sn.Mcp | Set-Clipboard; Write-Host '  (in Zwischenablage)' -ForegroundColor DarkGray } catch {}
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            { $_ -like 'w-*' } {
                $t = $sel.Substring(2)
                if (Confirm-SysPilot "Herbert-MCP in die $t-Konfiguration eintragen?") {
                    $r = Install-SysPilotHerbertMcpConfig -Target $t
                    Write-Host "  $($r.Message)" -ForegroundColor $(if($r.Ok){'Green'}else{'Red'})
                }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'apikey' {
                $cur = Get-SysPilotHerbertApiKey
                Write-Host "`n  Aktueller API-Key: $(if ($cur) { $cur.Substring(0,[Math]::Min(12,$cur.Length)) + '...' } else { '( keiner - Auth deaktiviert )' })" -ForegroundColor DarkGray
                $act = Read-SysPilotInput 'Aktion: [n]eu generieren, [l]oeschen, [Enter]=abbrechen' '' 'API-Key'
                if ($act -eq 'n') {
                    $k = New-SysPilotHerbertApiKey
                    Set-SysPilotHerbertApiKey -Key $k
                    try { $k | Set-Clipboard } catch {}
                    Write-Host "  Neuer API-Key generiert + kopiert: $k" -ForegroundColor Green
                    Write-Host "  (In den Extension-Einstellungen als Bearer-Key eintragen.)" -ForegroundColor DarkGray
                } elseif ($act -eq 'l') {
                    Set-SysPilotHerbertApiKey -Key ''
                    Write-Host '  API-Key geloescht - Auth deaktiviert (nur localhost).' -ForegroundColor Yellow
                }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'ext' {
                Install-SysPilotBrowserExtension | Out-Null
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'pkey' { Show-SysPilotProviderKeyAssistant }
            'usable' {
                $u = Get-SysPilotHerbertUsableProviders
                Write-Host "`n  --- Brauchbar ($($u.Usable.Count)) ---" -ForegroundColor Green
                foreach ($p in $u.Usable) { Write-Host "    + $($p.Name) ($($p.BaseUrl))" -ForegroundColor White }
                if ($u.Dead.Count -gt 0) {
                    Write-Host "`n  --- Nicht erreichbar ($($u.Dead.Count), in /v1/models gefiltert) ---" -ForegroundColor Yellow
                    foreach ($p in $u.Dead) { Write-Host "    - $($p.Name) ($($p.BaseUrl))" -ForegroundColor DarkGray }
                }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'autostart' {
                $cfg = Read-SysPilotAiAssistConfig
                $cur = [bool]$cfg.ApiAutoStart
                $nw = -not $cur
                Set-SysPilotHerbertApiAutoStart -On $nw | Out-Null
                Write-Host ("  Auto-Start " + $(if($nw){'AKTIVIERT - Herbert-API startet mit SysPilot'}else{'deaktiviert'})) -ForegroundColor $(if($nw){'Green'}else{'Yellow'})
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'claude' {
                $r = Get-SysPilotClaudeHerbertShortcut
                Write-Host "`n  $($r.Message)" -ForegroundColor Green
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'omni' {
                Show-SysPilotRouterSyncMenu
            }
            'continue' {
                if (Confirm-SysPilot 'Herbert in Continue (~\.continue\config.json) eintragen?') {
                    $r = Install-SysPilotContinueConfig
                    Write-Host "`n  $($r.Message)" -ForegroundColor Green
                }
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
        }
    }
}


Export-ModuleMember -Function `
    Get-SysPilotAiProviders, Test-SysPilotAiProvider, Test-SysPilotAiPortReachable, `
    Resolve-SysPilotAiModel, Get-SysPilotAiRankedModels, Invoke-SysPilotAiChat, `
    Get-SysPilotAiModelCooldowns, Set-SysPilotAiModelCooldown,
    Test-SysPilotAiModelCooledDown, Clear-SysPilotAiModelCooldown, `
    Get-SysPilotAiUsage, Add-SysPilotAiUsageRecord, Get-SysPilotAiUsageSummary, `
    Get-SysPilotAiBudgetMode, Set-SysPilotAiBudgetMode, `
    Get-SysPilotAiMonthlyTokenBudget, Set-SysPilotAiMonthlyTokenBudget, `
    Get-SysPilotAiPaidTokensThisMonth, Test-SysPilotAiProviderBudgetExceeded, `
    Show-SysPilotAiBudgetMenu, `
    Get-SysPilotAiVoiceMode, Set-SysPilotAiVoiceMode, `
    Get-SysPilotAiVoiceTts, Set-SysPilotAiVoiceTts, `
    Get-SysPilotMicDevice, Save-SysPilotMicRecording, `
    Send-SysPilotAiAudioTranscription, Send-SysPilotAiSpeech, `
    Send-SysPilotSystemSpeech, Invoke-SysPilotAiSpeak, `
    Get-SysPilotAiVoiceSttProvider, Show-SysPilotAiVoiceChat, Get-SysPilotAiFfmpeg, `
    Get-SysPilotAiLastSelection, Set-SysPilotAiLastSelection, `
    Show-SysPilotAiAssist, Show-SysPilotAiChat, Show-SysPilotAiQuickAsk, `
    Show-SysPilotAiProviderMenu, Add-SysPilotAiProviderInteractive, `
    Show-SysPilotAiSuggestions, Get-SysPilotAiFreeTierSuggestions, Get-SysPilotAiProviderCatalog, `
    Get-SysPilotAiProviderIntel, Show-SysPilotAiProviderOverview, `
    Get-SysPilotAiNewsSources, Get-SysPilotAiNewsDigest, Get-SysPilotAiYoutubeSearch, `
    Show-SysPilotAiNewsItem, Show-SysPilotAiNewsDigest, Invoke-SysPilotAiIntelCurate, `
    Show-SysPilotAiNewsIntelMenu, Get-SysPilotAiIntelExtra, Save-SysPilotAiIntelExtra, `
    Get-SysPilotRssMobileClients, Show-SysPilotQrCode, Show-SysPilotRssClientSetup, `
    Show-SysPilotAdbRssAssist, `
    Get-SysPilotAdbExe, Invoke-SysPilotAdbShell, Connect-SysPilotTvAdb, `
    Get-SysPilotTvPackages, Get-SysPilotTvBloatCandidates, Invoke-SysPilotTvDebloat, `
    Restore-SysPilotTvDebloat, Install-SysPilotTvApk, Get-SysPilotTvApps, `
    Get-SysPilotTvLaunchers, Show-SysPilotTvSetup, Show-SysPilotSecLabSetup, Show-SysPilotMobileSideload, `
    Show-SysPilotAiOnboarding, Show-SysPilotAiRouterInstallMenu, `
    Show-SysPilotAiQuickKeySetup, Save-SysPilotAiKeyBackup, `
    Get-SysPilotAiKeyBackupDir, Get-SysPilotAiOnboardState, `
    Get-SysPilotAiProviderModels, Select-SysPilotAiProviderModel, `
    Test-SysPilotAiProviderQuality, Invoke-SysPilotAiProviderCleanup, `
    Export-SysPilotAiProvidersFile, Import-SysPilotAiProvidersData, `
    Import-SysPilotAiProvidersFile, Import-SysPilotAiKeyFile, `
    Get-SysPilotAiKeyFileCandidates, Import-SysPilotAiKeyFolder, Get-SysPilotAiKeyDirs, `
    Find-SysPilotAiRouterConfigs, Show-SysPilotAiImportExportMenu, `
    Get-SysPilotAiAppsCatalog, Get-SysPilotAiAppStatus, Install-SysPilotAiApp, `
    Show-SysPilotAiAppsInstall, Get-SysPilotHfModelSearch, `
    Get-SysPilotHfModelFiles, Get-SysPilotAiModelDirs, `
    Save-SysPilotHfModel, Show-SysPilotAiModelFinder, `
    Get-SysPilotPocketAiModelDir, Register-SysPilotPocketAiModel, `
    Get-SysPilotHfRepoFilesBatch, Get-SysPilotGgufSizeClass, `
    Show-SysPilotOllamaModelPull, Show-SysPilotDirectModelDownload, `
    Get-SysPilotAiRepoInfo, Install-SysPilotGitRepoTool, `
    Show-SysPilotAiGuidedInstall, Get-SysPilotBrowserMcpContext, `
    Invoke-SysPilotBrowserMcpCall, Invoke-SysPilotBrowserPageTask, `
    Set-SysPilotAiOnboarded, `
    Get-SysPilotAiProcessHintsEnabled, Set-SysPilotAiProcessHintsEnabled, `
    Get-SysPilotHerbertAnnouncementsEnabled, Set-SysPilotHerbertAnnouncementsEnabled, `
    Get-SysPilotAiUsableProviders, Get-SysPilotAiProviderMode, Set-SysPilotAiProviderMode, `
    Get-SysPilotAiPreferredProvider, Set-SysPilotAiPreferredProvider, `
    Show-SysPilotAiProvidersWindow, Show-SysPilotAiProviderEditDialog, Show-SysPilotAiSuggestionsWindow, Save-SysPilotAiProviderEntry, `
    Get-SysPilotHerbertAnnouncements, Get-SysPilotHerbertAnnouncement, `
    Show-SysPilotHerbertAssistant, Show-SysPilotHerbertManager, `
    Get-SysPilotHerbertFullscreen, Set-SysPilotHerbertFullscreen, `
    Get-SysPilotOptionalExtras, Show-SysPilotHerbertOnboarding, `
    Get-SysPilotLocalSkills, Find-SysPilotSkillsRemote, Install-SysPilotSkill, `
    Read-SysPilotAiAssistConfig, Write-SysPilotAiAssistConfig, `
    Protect-SysPilotSecret, Unprotect-SysPilotSecret, `
    Get-SysPilotKiClientApps, Install-SysPilotKiClientApp, Show-SysPilotKiClientsMenu, `
    Show-SysPilotKiDoctor, Show-SysPilotKiBrowserSetupGuide, `
    Get-SysPilotKiEndpointPresets, Set-SysPilotClaudeCodeEndpoint, Show-SysPilotKiBridgeMenu, `
    Get-SysPilotKiExtensions, Show-SysPilotKiExtensionsMenu, `
    Get-SysPilotRssReaderApps, Get-SysPilotRssFeedSuggestions, Show-SysPilotRssFeedsMenu, `
    Get-SysPilotKiBrowsers, Show-SysPilotKiBrowsersMenu, `
    Get-SysPilotKiEssentials, Get-SysPilotInstalledAppNames, Show-SysPilotKiEssentialsMenu, `
    Export-SysPilotRssOpml, Show-SysPilotMinifluxSetup, `
    Export-SysPilotOracleCloudInit, Show-SysPilotCfNamedTunnel, Show-SysPilotTailscaleFunnel, `
    Show-SysPilotMinifluxDoctor, Show-SysPilotOracleGuide, `
    Get-SysPilotAiNewsFeed, Show-SysPilotAiNews, Show-SysPilotKiSetupWizard, `
    Show-SysPilotHerbertSelfCheck, Install-SysPilotHerbertCapability, `
    Test-SysPilotHealth, Send-SysPilotDebugReport, `
    Get-SysPilotHerbertPermissionMode, Set-SysPilotHerbertPermissionMode, `
    Get-SysPilotHerbertPermissionOverride, Set-SysPilotHerbertPermissionOverride, `
    Test-SysPilotKiPermission, Show-SysPilotHerbertPermissions, Show-SysPilotHerbertExtensions, `
    Get-SysPilotHerbertChatDir, Save-SysPilotHerbertChat, Get-SysPilotHerbertChats, `
    Read-SysPilotHerbertChat, Remove-SysPilotHerbertChat, `
    Get-SysPilotSkillDescription, Find-SysPilotSkillsPopular, `
    Get-SysPilotRssFeedDirectory, Show-SysPilotRssCenter, `
    Get-SysPilotMinifluxConfig, Set-SysPilotMinifluxConfig, `
    Test-SysPilotMinifluxApi, Add-SysPilotMinifluxFeeds, `
    Get-SysPilotLlamaAppInfo, Get-SysPilotLlamaAppModelDir, Get-SysPilotHardwareModelFit, `
    Test-SysPilotGgufFile, Get-SysPilotModelFiles, Show-SysPilotModelCleanup, `
    Register-SysPilotOllamaModel, Test-SysPilotOllamaModel, `
    Get-SysPilotKiActions, Get-SysPilotKiActionProtocol, Invoke-SysPilotKiAction, Get-SysPilotHerbertKnowledge,
    Get-SysPilotHerbertInterests, Set-SysPilotHerbertInterests, Get-SysPilotHerbertInterestTopics, Show-SysPilotHerbertInterestsSetup, `
    Get-SysPilotHerbertApiStatus, Start-SysPilotHerbertApi, Stop-SysPilotHerbertApi, `
    Start-SysPilotHerbertApiServer, Invoke-SysPilotHerbertMcpStdio, `
    Get-SysPilotHerbertApiSnippets, Install-SysPilotHerbertMcpConfig, `
    Get-SysPilotHerbertUsableProviders, Set-SysPilotHerbertApiAutoStart, `
    Get-SysPilotClaudeHerbertShortcut, Install-SysPilotContinueConfig, `
    Sync-SysPilotOmniRouteProviders, Get-SysPilotProviderModelPlan, `
    Save-SysPilotUsableProvidersArtifact, `
    Get-SysPilotOmniRouteClientKey, New-SysPilotOmniRouteClientKey, `
    Install-SysPilotOmniRouteKeyConfig, `
    Sync-SysPilotFreelmProviders, Sync-SysPilotFreeLlmApiProviders, Get-SysPilotFreeLlmApiInfo, `
    Get-SysPilotNineRouterInfo, Install-SysPilotNineRouter, Sync-SysPilotNineRouterProviders, Get-SysPilotNineRouterSession, `
    Show-SysPilotRouterSyncMenu, Show-SysPilotOmniRouteSetup, `
    Show-SysPilotFreeLlmApiSetup, Show-SysPilotFreelmSetup, Show-SysPilotNineRouterSetup, `
    Show-SysPilotHerbertApiMenu, Test-SysPilotTcpPort, `
    Get-SysPilotHerbertApiKey, Set-SysPilotHerbertApiKey, New-SysPilotHerbertApiKey, `
    Get-SysPilotBrowserExtensionDir, Install-SysPilotBrowserExtension, `
    Show-SysPilotProviderKeyAssistant, Find-SysPilotYoutubeApiKeyVideos, `
    Get-SysPilotYoutubeTranscript, Find-SysPilotYoutubeKeyCandidates, `
    Invoke-SysPilotScoutLlm, Resolve-SysPilotProviderFromCatalog, Show-SysPilotYoutubeKeyScout, `
    Get-SysPilotLlamaCppDir, Get-SysPilotLlamaCppGpuHint, Get-SysPilotLlamaCppBackendSuggestion, `
    Get-SysPilotLlamaCppRelease, Get-SysPilotLlamaCppAssetName, Install-SysPilotLlamaCpp, `
    Get-SysPilotLlamaServerExe, Get-SysPilotLlamaServerStatus, Get-SysPilotLlamaGgufCandidates, `
    Start-SysPilotLlamaServer, Stop-SysPilotLlamaServer, Show-SysPilotLlamaCppMenu, `
    Invoke-SysPilotAiEndpoint, Show-SysPilotAiEndpointsMenu, `
    Get-SysPilotKaggleStatus, Invoke-SysPilotKaggleKernelPush, Show-SysPilotKaggleMenu, `
    Get-SysPilotKaggleTpuInfo, Start-SysPilotKaggleTpuProxy, Start-SysPilotKaggleTpu, `
    Stop-SysPilotKaggleTpu, Show-SysPilotKaggleTpuMenu, Get-SysPilotKaggleSetupStatus, `
    Install-SysPilotKaggleTpuSetup
