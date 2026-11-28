# SysPilot - CleanSweep: Deinstallations-Center (Programme, Windows-Apps,
# Browser-Erweiterungen, Reste & verwaiste Programme) - unabhaengige
# SysPilot-Implementierung nach Funktionsanalyse von IObit Uninstaller.
#Requires -Version 5.1

# =======================================================================
# Inventar: Desktop-Programme (alle 4 Registry-Sichten)
# =======================================================================
function Get-SysPilotUninstallRegistryViews {
    return @(
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*';   View = 'HKLM64' },
        @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'; View = 'HKLM32' },
        @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*';   View = 'HKCU64' },
        @{ Path = 'HKCU:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'; View = 'HKCU32' }
    )
}

function Get-SysPilotProgramInventory {
    <# Liefert alle Desktop-Programme aus den Uninstall-Registry-Sichten.
       Erweiterte Felder gegenueber Get-SysPilotInstalled (Bloatware.psm1):
       InstallLocation, UninstallKey, RegistryView, QuietUninstallString,
       WindowsInstaller, ParentKeyName. #>
    $apps = @()
    foreach ($v in (Get-SysPilotUninstallRegistryViews)) {
        $items = Get-ItemProperty $v.Path -ErrorAction SilentlyContinue
        foreach ($i in $items) {
            if (-not $i.DisplayName) { continue }
            if ($i.SystemComponent) { continue }
            if ($i.ParentKeyName) { continue }
            # Registry-Pfad in HKLM:/HKCU:-Schreibweise fuer Remove-Item/Test-Path
            $base = $v.Path -replace '\\\*$', ''
            $regPath = "$base\$($i.PSChildName)"
            $apps += [PSCustomObject]@{
                Name               = $i.DisplayName
                Version            = $i.DisplayVersion
                Publisher          = $i.Publisher
                InstallDate        = $i.InstallDate
                SizeMB             = $(if ($i.EstimatedSize) { [math]::Round($i.EstimatedSize / 1024) } else { 0 })
                UninstallString    = $i.UninstallString
                QuietUninstallString = $i.QuietUninstallString
                InstallLocation    = $i.InstallLocation
                UninstallKey       = $regPath
                RegistryView       = $v.View
                WindowsInstaller   = [bool]$i.WindowsInstaller
                HelpLink           = $i.HelpLink
                URLInfoAbout       = $i.URLInfoAbout
            }
        }
    }
    # Dedupe: gleiche DisplayName+Version aus mehreren Sichten nur 1x.
    # Bevorzugt Eintraege MIT UninstallString (funktionsfaehig).
    $seen = @{}
    $out = @()
    $sorted = $apps | Sort-Object Name, @{ e = { [bool]($_.UninstallString -or $_.QuietUninstallString) }; Descending = $true }, @{ e = { $_.UninstallKey }; Descending = $false }
    foreach ($a in $sorted) {
        $k = ($a.Name + '|' + $a.Version).ToLower()
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true
        $out += $a
    }
    return $out
}

# =======================================================================
# Windows-Apps (AppX / MSIX)
# =======================================================================
function Get-SysPilotAppxInventory {
    <# Alle AppX/MSIX-Pakete. Mit -AllUsers werden Pakete aller Nutzer
       gelistet (braucht Admin, sonst stiller Fallback auf aktuellen Nutzer). #>
    param([switch]$AllUsers)
    $isAdmin = Test-SysPilotAdmin
    $pkgs = @()
    try {
        if ($AllUsers -and $isAdmin) {
            $pkgs = @(Get-AppxPackage -AllUsers -ErrorAction Stop)
        } else {
            $pkgs = @(Get-AppxPackage -ErrorAction Stop)
        }
    } catch {
        try { $pkgs = @(Get-AppxPackage -ErrorAction Stop) } catch { return @() }
    }
    $out = @()
    foreach ($p in $pkgs) {
        $out += [PSCustomObject]@{
            Name              = $p.Name
            FamilyName        = $p.PackageFamilyName
            Version           = $p.Version
            Publisher         = $p.Publisher
            PackageFullName   = $p.PackageFullName
            SignatureKind     = [string]$p.SignatureKind
            IsFramework       = [bool]$p.IsFramework
            IsResourcePackage = [bool]$p.IsResourcePackage
            NonRemovable      = [bool]$p.NonRemovable
            IsPartiallyStaged = [bool]$p.IsPartiallyStaged
            InstallLocation   = $p.InstallLocation
            AllUsersScope     = ($AllUsers -and $isAdmin)
        }
    }
    return $out
}

function Get-SysPilotAppxDisplayName {
    param($Pkg)
    # AppxPackage hat kein DisplayName-Feld; Name ist z.B. Microsoft.WindowsCalculator.
    # InstallLocation enthaelt AppxManifest.xml mit echtem DisplayName - einmalig cachen.
    if (-not $script:_appxNameCache) { $script:_appxNameCache = @{} }
    $key = $Pkg.PackageFullName
    if ($script:_appxNameCache.ContainsKey($key)) { return $script:_appxNameCache[$key] }
    $display = $Pkg.Name
    try {
        if ($Pkg.InstallLocation -and (Test-Path $Pkg.InstallLocation)) {
            $mf = Join-Path $Pkg.InstallLocation 'AppxManifest.xml'
            if (Test-Path $mf) {
                [xml]$x = Get-Content $mf -Raw -Encoding UTF8
                $ns = New-Object Xml.XmlNamespaceManager($x.NameTable)
                $ns.AddNamespace('uap', 'http://schemas.microsoft.com/appx/manifest/uap/windows10')
                $ns.AddNamespace('mp', 'http://schemas.microsoft.com/appx/2014/manifest')
                $pr = $x.SelectSingleNode('//mp:Properties/mp:DisplayName', $ns)
                if ($pr -and $pr.InnerText) { $display = $pr.InnerText }
            }
        }
    } catch { }
    $script:_appxNameCache[$key] = $display
    return $display
}

function Remove-SysPilotAppxPackage {
    param(
        [Parameter(Mandatory)]$Pkg,
        [switch]$AllUsers
    )
    $name = Get-SysPilotAppxDisplayName -Pkg $Pkg
    Write-SysPilotLog "AppX-Entfernung gestartet: $name ($($Pkg.PackageFullName))"
    try {
        if ($AllUsers -and (Test-SysPilotAdmin)) {
            Remove-AppxPackage -Package $Pkg.PackageFullName -AllUsers -ErrorAction Stop
        } else {
            Remove-AppxPackage -Package $Pkg.PackageFullName -ErrorAction Stop
        }
        Write-Host "  [OK] Entfernt: $name" -ForegroundColor Green
        Write-SysPilotLog "AppX entfernt: $($Pkg.PackageFullName)"
        return $true
    } catch {
        Write-Host "  [!] AppX-Entfernung fehlgeschlagen: $name ($($_.Exception.Message))" -ForegroundColor Yellow
        Write-SysPilotLog "AppX-Entfernung fehlgeschlagen: $($Pkg.PackageFullName): $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Get-SysPilotProvisionedApps {
    <# Fuer neue Nutzer vorinstallierte AppX-Pakete (braucht Admin). #>
    if (-not (Test-SysPilotAdmin)) { return @() }
    try {
        $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop)
        $out = @()
        foreach ($p in $prov) {
            $out += [PSCustomObject]@{
                Name            = $p.DisplayName
                PackageName     = $p.PackageName
                Version         = $p.Version
            }
        }
        return $out
    } catch { return @() }
}

function Remove-SysPilotProvisionedApp {
    param([Parameter(Mandatory)]$Prov)
    if (-not (Test-SysPilotAdmin)) {
        Write-Host "  [!] Braucht Administrator-Rechte." -ForegroundColor Yellow
        return $false
    }
    try {
        Remove-AppxProvisionedPackage -Online -PackageName $Prov.PackageName -ErrorAction Stop | Out-Null
        Write-Host "  [OK] Provisioniertes Paket entfernt: $($Prov.Name)" -ForegroundColor Green
        Write-SysPilotLog "Provisioniertes AppX entfernt: $($Prov.PackageName)"
        return $true
    } catch {
        Write-Host "  [!] Fehlgeschlagen: $($Prov.Name) ($($_.Exception.Message))" -ForegroundColor Yellow
        return $false
    }
}

# =======================================================================
# Deinstallations-String aufloesen (exe + Argumente, silent-Variante)
# =======================================================================
function Split-SysPilotUninstallString {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$UninstallString)
    if (-not $UninstallString) { return $null }
    $u = $UninstallString.Trim()
    # msiexec /I {GUID} oder msiexec.exe /x {GUID}
    if ($u -match '(?i)msiexec.*?(/i|/x)\s+"?([{}\w\-]+)"?') {
        return [PSCustomObject]@{ Kind = 'msi'; Exe = 'msiexec.exe'; Guid = $matches[2]; Raw = $u }
    }
    if ($u -match '^"([^"]+)"\s*(.*)$') {
        return [PSCustomObject]@{ Kind = 'exe'; Exe = $matches[1]; Args = $matches[2]; Raw = $u }
    }
    # Unquotierter Pfad mit Leerzeichen: alles bis zum ersten .exe/.bat/.cmd
    # gehoert zum ausfuehrbaren Teil (z.B. C:\Program Files\X\unins.exe /S)
    if ($u -match '(?i)^(.+?\.(exe|bat|cmd|com|msi|ps1))\s*(.*)$') {
        $exe = $matches[1].Trim()
        return [PSCustomObject]@{ Kind = 'exe'; Exe = $exe; Args = $matches[3]; Raw = $u }
    }
    if ($u -match '^(\S+)\s*(.*)$') {
        return [PSCustomObject]@{ Kind = 'exe'; Exe = $matches[1]; Args = $matches[2]; Raw = $u }
    }
    return $null
}

function Get-SysPilotSilentArgs {
    <# Erraet silent-taugliche Schalter anhand des Installers (Heuristik).
       Liefert $null, wenn kein zuverlaessiger Silent-Modus bekannt ist -
       dann laeuft der Installer normal (interaktiv). #>
    param([Parameter(Mandatory)][string]$Exe, [string]$Args = '')
    $a = "$Exe $Args".ToLower()
    $file = (Split-Path $Exe -Leaf).ToLower()
    # Inno Setup (unins000.exe, *setup*.exe mit /VERYSILENT)
    if ($a -match 'inno|unins0|uninsfs|uninsde|_is1') { return '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-' }
    if ($a -match 'installshield|setup\.ins|_is1\.msi') { return '/s /v"/qn /norestart"' }
    # NSIS (ns*.exe, Au_.exe, Un_A.exe, unins000-ish)
    if ($file -match '^(ns|au_|un_a|uninstall|unins).*\.exe$') { return '/S' }
    # Schnellzugriff-Schalter, die das Programm evtl. schon nutzt
    foreach ($pat in @('/verysilent', '--silent', '/quiet', '--uninstall --silent', '-uninstall -silent')) {
        if ($a -match [regex]::Escape($pat)) { return $pat }
    }
    return $null
}

function Test-SysPilotExeExists {
    param([Parameter(Mandatory)][string]$Exe)
    $e = $Exe.Trim('"')
    if ($e -match '%') { $e = [Environment]::ExpandEnvironmentVariables($e) }
    if (Test-Path $e) { return $true }
    # PATH-Suche
    try { $null = Get-Command $e -ErrorAction Stop; return $true } catch { return $false }
}

# =======================================================================
# Programm-Deinstallation (single + batch)
# =======================================================================
function Invoke-SysPilotProgramUninstall {
    <# Deinstalliert EIN Programm. Modi: 'auto' (silent wenn moeglich,
       sonst interaktiv), 'silent', 'normal'. Gibt Status-Objekt zurueck. #>
    param(
        [Parameter(Mandatory)]$App,
        [ValidateSet('auto','silent','normal')][string]$Mode = 'auto',
        [switch]$NoLeftoverScan
    )
    $name = $App.Name
    $cmdline = $null
    $proc = $null

    # Bevorzugt QuietUninstallString, dann UninstallString
    $raw = if ($App.QuietUninstallString) { $App.QuietUninstallString } else { $App.UninstallString }
    if (-not $raw) {
        Write-Host "  [!] Kein Deinstallationsbefehl fuer '$name' - evtl. unter 'Defekte Eintraege' pruefen." -ForegroundColor Yellow
        return [PSCustomObject]@{ Name = $name; Success = $false; Reason = 'Kein UninstallString' }
    }

    $parsed = Split-SysPilotUninstallString -UninstallString $raw
    if (-not $parsed) {
        Write-Host "  [!] UninstallString nicht verarbeitbar: $raw" -ForegroundColor Yellow
        return [PSCustomObject]@{ Name = $name; Success = $false; Reason = 'Unparsbar' }
    }

    Write-SysPilotLog "Deinstallation gestartet: $name | $raw"
    Write-Host "  Deinstalliere: $name" -ForegroundColor Cyan

    try {
        if ($parsed.Kind -eq 'msi') {
            $argList = "/x `"$($parsed.Guid)`""
            if ($Mode -ne 'normal') { $argList += ' /qn /norestart' }
            $proc = Start-Process 'msiexec.exe' -ArgumentList $argList -PassThru -Wait:$false
            $cmdline = "msiexec.exe $argList"
        } else {
            $exe = $parsed.Exe
            $argStr = $parsed.Args
            $silentArgs = Get-SysPilotSilentArgs -Exe $exe -Args $argStr
            $useSilent = ($Mode -eq 'silent') -or ($Mode -eq 'auto' -and $silentArgs)
            if ($Mode -eq 'silent' -and -not $silentArgs) {
                Write-Host "  [i] Kein bekannter Silent-Schalter - starte normalen Installer." -ForegroundColor DarkGray
                $useSilent = $false
            }
            if ($useSilent -and $silentArgs) {
                $argStr = "$argStr $silentArgs".Trim()
                Write-Host "  (silent: $silentArgs)" -ForegroundColor DarkGray
            }
            if (-not (Test-SysPilotExeExists -Exe $exe)) {
                Write-Host "  [!] Programm nicht gefunden: $exe - Eintrag ist evtl. veraltet." -ForegroundColor Yellow
                Write-SysPilotLog "Uninstall-Exe fehlt: $name -> $exe" 'WARN'
                return [PSCustomObject]@{ Name = $name; Success = $false; Reason = 'Exe fehlt' }
            }
            # Argumente sicher quoten: bereits quotierte Teile behalten
            $argLine = $argStr
            $proc = Start-Process -FilePath $exe -ArgumentList $argLine -PassThru
            $cmdline = "$exe $argLine"
        }

        # Warten mit Abbruch-Moeglichkeit (Taste = weiter warten beenden?) - einfach Wait
        $proc.WaitForExit()
        $exit = $proc.ExitCode
        $reboot = ($exit -in 3010, 1641)
        $ok = ($exit -eq 0 -or $reboot)
        $status = if ($ok) { 'OK' } else { "Exit $exit" }
        Write-Host "  [$status] $name $(if ($reboot) { '(Neustart noetig)' })" -ForegroundColor $(if ($ok) { 'Green' } else { 'Yellow' })
        Write-SysPilotLog "Deinstallation beendet: $name | exit=$exit | $cmdline"

        # Nach-Scan anbieten (IObit-Style: links nach uninstall)
        if (-not $NoLeftoverScan -and $ok) {
            Show-SysPilotLeftoverFlow -App $App
        }
        return [PSCustomObject]@{ Name = $name; Success = $ok; RebootRequired = $reboot; Reason = $status }
    } catch {
        Write-Host "  [!] Fehler bei '$name': $($_.Exception.Message)" -ForegroundColor Red
        Write-SysPilotLog "Deinstallation-Fehler: $name : $($_.Exception.Message)" 'ERROR'
        return [PSCustomObject]@{ Name = $name; Success = $false; Reason = $_.Exception.Message }
    }
}

# =======================================================================
# Leftover-Scanner (Dateien, Registry, Tasks, Services, Shortcuts)
# =======================================================================
function Get-SysPilotNameTokens {
    <# Zerlegt DisplayName/Publisher in Such-Tokens (>=3 Zeichen,
       generische Woerter entfernt). #>
    param([string[]]$Names)
    $generic = @('the','and','for','with','pro','free','version','edition','setup','update','software','inc','ltd','gmbh','llc','corp','corporation','windows','microsoft','64','bit','x64','x86','von','der','die','das','und','fuer','mit','neu','plus')
    $tokens = New-Object System.Collections.Generic.List[string]
    foreach ($n in $Names) {
        if (-not $n) { continue }
        foreach ($w in ($n -split '[\s\-_\.\(\)\[\]\{\}:/\\]+' | Where-Object { $_.Length -ge 3 })) {
            $wl = $w.ToLower()
            if ($generic -contains $wl) { continue }
            if ($tokens -notcontains $w) { $tokens.Add($w) }
        }
    }
    return $tokens
}

function Find-SysPilotProgramLeftovers {
    <# Scannt nach Deinstallations-Resten fuer EIN Programm.
       Gibt bewertete Kandidaten zurueck (Score 0-100, nur >=30). #>
    param(
        [Parameter(Mandatory)]$App,
        [int]$MinScore = 30
    )
    $found = @()
    $name = $App.Name
    $tokens = @(Get-SysPilotNameTokens -Names @($name, $App.Publisher))
    if ($tokens.Count -eq 0) { return @() }
    $nameLower = $name.ToLower()
    $pubLower = ([string]$App.Publisher).ToLower()

    # --- 1. Datei-/Ordner-Reste -------------------------------------
    $fileCandidates = New-Object System.Collections.Generic.List[string]
    # InstallLocation selbst
    if ($App.InstallLocation) {
        $il = $App.InstallLocation.Trim('"')
        if ($il -and (Test-Path $il)) { $fileCandidates.Add($il) }
        # Elternordner, wenn er app-spezifisch aussieht (z.B. C:\Program Files\Vendor)
        $parent = Split-Path $il -Parent
        if ($parent -and $parent -notin @('C:\Program Files','C:\Program Files (x86)',"$env:LOCALAPPDATA","$env:APPDATA",'C:\ProgramData')) {
            $leaf = Split-Path $parent -Leaf
            if ($leaf.Length -ge 3 -and ($tokens -contains $leaf -or $pubLower -and $leaf.ToLower() -eq $pubLower)) {
                if (Test-Path $parent) { $fileCandidates.Add($parent) }
            }
        }
    }
    # Uebliche Reste-Orte: Ordner die exakt einem Token oder Publisher entsprechen
    $bases = @(
        'C:\Program Files', 'C:\Program Files (x86)',
        "$env:LOCALAPPDATA", "$env:APPDATA", 'C:\ProgramData',
        "$env:LOCALAPPDATA\Programs"
    ) | Select-Object -Unique
    foreach ($base in $bases) {
        if (-not (Test-Path $base)) { continue }
        try {
            Get-ChildItem $base -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $leaf = $_.Name
                $leafL = $leaf.ToLower()
                $hit = $false; $score = 0
                if ($pubLower -and $leafL -eq $pubLower) { $hit = $true; $score = 55 }
                elseif ($nameLower -and ($leafL -eq $nameLower -or $leafL -eq ($nameLower -replace '[^\w]',''))) { $hit = $true; $score = 70 }
                else {
                    $matchCount = 0
                    foreach ($t in $tokens) { if ($leafL -like "*$($t.ToLower())*") { $matchCount++ } }
                    if ($matchCount -ge 2 -or ($matchCount -eq 1 -and $tokens.Count -le 2)) { $hit = $true; $score = 40 + ($matchCount * 10) }
                }
                if ($hit -and -not $fileCandidates.Contains($_.FullName)) {
                    $fileCandidates.Add($_.FullName) | Out-Null
                }
            }
        } catch { }
    }
    foreach ($p in $fileCandidates) {
        $score = 60
        if ($nameLower -and ($p.ToLower() -like "*$($nameLower -replace '[^\w]','')*" -or $p.ToLower() -like "*$nameLower*")) { $score = 75 }
        $found += [PSCustomObject]@{ Kind = 'Datei/Ordner'; Path = $p; Score = $score; Reason = 'Ordner/Datei passt zum Programmnamen' }
    }

    # --- 2. Registry-Reste ------------------------------------------
    $regRoots = @(
        @{ Path = 'HKCU:\SOFTWARE';  Tag = 'HKCU' },
        @{ Path = 'HKLM:\SOFTWARE';  Tag = 'HKLM' },
        @{ Path = 'HKLM:\SOFTWARE\WOW6432Node'; Tag = 'HKLM32' },
        @{ Path = 'HKCU:\SOFTWARE\WOW6432Node'; Tag = 'HKCU32' }
    )
    foreach ($t in $tokens) {
        foreach ($r in $regRoots) {
            $kp = Join-Path $r.Path $t
            if (Test-Path $kp) {
                $score = 65
                if ($pubLower -and $t.ToLower() -eq $pubLower) { $score = 60 }
                $found += [PSCustomObject]@{ Kind = 'Registry'; Path = $kp; Score = $score; Reason = "Schluessel 'Software\$t'" }
            }
        }
    }
    # Run/RunOnce-Eintraege
    $runKeys = @(
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce'
    )
    foreach ($rk in $runKeys) {
        if (-not (Test-Path $rk)) { continue }
        try {
            $vals = Get-ItemProperty $rk -ErrorAction SilentlyContinue
            foreach ($pn in $vals.PSObject.Properties) {
                if ($pn.Name -like 'PS*') { continue }
                $val = [string]$pn.Value
                foreach ($t in $tokens) {
                    if ($pn.Name -like "*$t*" -or $val -like "*$t*") {
                        $found += [PSCustomObject]@{ Kind = 'Autostart'; Path = "$rk -> $($pn.Name)"; Score = 70; Reason = 'Run/RunOnce-Eintrag' }
                        break
                    }
                }
            }
        } catch { }
    }
    # App Paths
    foreach ($t in $tokens) {
        $ap = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$t.exe"
        if (Test-Path $ap) {
            $found += [PSCustomObject]@{ Kind = 'Registry'; Path = $ap; Score = 55; Reason = 'App Paths-Eintrag' }
        }
    }
    # MUICache (freundliche Namen -> exe)
    $mui = 'HKCU:\SOFTWARE\Classes\Local Settings\Software\Microsoft\Windows\Shell\MuiCache'
    if (Test-Path $mui) {
        try {
            $mv = Get-ItemProperty $mui -ErrorAction SilentlyContinue
            foreach ($pn in $mv.PSObject.Properties) {
                if ($pn.Name -like 'PS*') { continue }
                $val = [string]$pn.Value
                foreach ($t in $tokens) {
                    if ($val -like "*$t*" -or $pn.Name -like "*$t*") {
                        $found += [PSCustomObject]@{ Kind = 'Registry'; Path = "$mui -> $($pn.Name)"; Score = 35; Reason = 'MUICache-Eintrag' }
                        break
                    }
                }
            }
        } catch { }
    }
    # Dienste
    foreach ($t in $tokens) {
        $svc = "HKLM:\SYSTEM\CurrentControlSet\Services\$t"
        if (Test-Path $svc) {
            $found += [PSCustomObject]@{ Kind = 'Dienst'; Path = $svc; Score = 55; Reason = "Dienst '$t'" }
        }
    }
    # Geplante Aufgaben
    try {
        Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
            $tn = $_.TaskName.ToLower()
            foreach ($t in $tokens) { if ($tn -like "*$($t.ToLower())*") { return $true } }
            return $false
        } | ForEach-Object {
            $found += [PSCustomObject]@{ Kind = 'Aufgabe'; Path = "$($_.TaskPath)$($_.TaskName)"; TaskName = $_.TaskName; TaskPath = $_.TaskPath; Score = 55; Reason = 'Geplante Aufgabe' }
        }
    } catch { }
    # Startmenue-/Desktop-Verknuepfungen
    $lnkDirs = @(
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs",
        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs",
        [Environment]::GetFolderPath('Desktop'),
        "$env:PUBLIC\Desktop"
    ) | Select-Object -Unique
    foreach ($d in $lnkDirs) {
        if (-not (Test-Path $d)) { continue }
        try {
            Get-ChildItem $d -Recurse -Filter '*.lnk' -ErrorAction SilentlyContinue | ForEach-Object {
                $ln = $_.BaseName.ToLower()
                foreach ($t in $tokens) {
                    if ($ln -like "*$($t.ToLower())*") {
                        $found += [PSCustomObject]@{ Kind = 'Verknuepfung'; Path = $_.FullName; Score = 45; Reason = 'Startmenue/Desktop-Shortcut' }
                        break
                    }
                }
            }
        } catch { }
    }
    # Der Uninstall-Registry-Eintrag selbst (falls Deinstallation unvollstaendig)
    if ($App.UninstallKey) {
        $found += [PSCustomObject]@{ Kind = 'Registry'; Path = $App.UninstallKey; Score = 50; Reason = 'Uninstall-Registry-Eintrag' }
    }

    # Dedupe + Score-Filter + Sortierung
    $out = @{}
    foreach ($f in $found) {
        $k = "$($f.Kind)|$($f.Path)"
        if (-not $out.ContainsKey($k) -or $out[$k].Score -lt $f.Score) { $out[$k] = $f }
    }
    return @($out.Values | Where-Object { $_.Score -ge $MinScore } | Sort-Object Score -Descending)
}

function Remove-SysPilotLeftoverItem {
    <# Entfernt EIN Leftover-Element sicher:
       - Ordner/Dateien -> Papierkorb (Microsoft.VisualBasic.FileIO)
       - Registry     -> .reg-Backup nach backup\leftovers, dann loeschen
       - Dienst/Aufgabe/Autostart -> loeschen (Admin noetig)
       - Shortcut     -> Papierkorb
    #>
    param([Parameter(Mandatory)]$Item)
    $path = $Item.Path
    $kind = $Item.Kind

    # Registry-Wert-Eintraege haben Form "ROOT -> name"
    if ($path -match '^(HKCU|HKLM):\\(.+) -> (.+)$') {
        $root = $matches[1] + ':\' + $matches[2]
        $valName = $matches[3]
        $bak = Join-Path (Get-SysPilotBackupDir) 'leftovers'
        if (-not (Test-Path $bak)) { New-Item -ItemType Directory -Force -Path $bak | Out-Null }
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        try {
            $safe = ($path -replace '[\\/:*?"<>|]','_')
            $regRoot = $root -replace '^HKCU:\\','HKEY_CURRENT_USER\' -replace '^HKLM:\\','HKEY_LOCAL_MACHINE\'
            & reg.exe export "$regRoot" "$bak\$stamp-$safe.reg" /y 2>$null | Out-Null
        } catch { }
        try {
            Remove-ItemProperty -Path $root -Name $valName -Force -ErrorAction Stop
            Write-Host "    [OK] Registry-Wert entfernt: $valName" -ForegroundColor Green
            Write-SysPilotLog "Leftover entfernt (Registry-Wert): $path" 'INFO'
            return $true
        } catch {
            Write-Host "    [!] Registry-Wert fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Yellow
            return $false
        }
    }

    # Registry-Schluessel (ganzer Key)
    if ($kind -eq 'Registry' -or $path -match '^(HKCU|HKLM):\\') {
        if (Test-Path $path) {
            $bak = Join-Path (Get-SysPilotBackupDir) 'leftovers'
            if (-not (Test-Path $bak)) { New-Item -ItemType Directory -Force -Path $bak | Out-Null }
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $safe = ($path -replace '[\\/:*?"<>|]','_')
            try {
                & reg.exe export ($path -replace '^HKCU:\\','HKEY_CURRENT_USER\' -replace '^HKLM:\\','HKEY_LOCAL_MACHINE\') "$bak\$stamp-$safe.reg" /y 2>$null | Out-Null
            } catch { }
            try {
                Remove-Item -Path $path -Recurse -Force -ErrorAction Stop
                Write-Host "    [OK] Registry-Schluessel entfernt: $path" -ForegroundColor Green
                Write-SysPilotLog "Leftover entfernt (Registry): $path" 'INFO'
                return $true
            } catch {
                Write-Host "    [!] Registry-Schluessel fehlgeschlagen (Admin noetig?): $($_.Exception.Message)" -ForegroundColor Yellow
                return $false
            }
        }
        return $false
    }

    # Dienst
    if ($kind -eq 'Dienst') {
        $svcName = Split-Path $path -Leaf
        try {
            & sc.exe delete $svcName | Out-Null
            Write-Host "    [OK] Dienst geloescht: $svcName" -ForegroundColor Green
            Write-SysPilotLog "Leftover entfernt (Dienst): $svcName" 'INFO'
            return $true
        } catch {
            Write-Host "    [!] Dienst-Loeschung fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Yellow
            return $false
        }
    }

    # Geplante Aufgabe
    if ($kind -eq 'Aufgabe') {
        $tn = if ($Item.TaskName) { $Item.TaskName } else { Split-Path $path -Leaf }
        $tp = if ($Item.TaskPath) { $Item.TaskPath } else { (Split-Path $path -Parent) + '\' }
        try {
            Unregister-ScheduledTask -TaskName $tn -TaskPath $tp -Confirm:$false -ErrorAction Stop
            Write-Host "    [OK] Aufgabe entfernt: $path" -ForegroundColor Green
            Write-SysPilotLog "Leftover entfernt (Aufgabe): $path" 'INFO'
            return $true
        } catch {
            Write-Host "    [!] Aufgabe-Loeschung fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Yellow
            return $false
        }
    }

    # Autostart (Run-Wert) - oben bereits behandelt via ' -> '
    if ($kind -eq 'Autostart') {
        return Remove-SysPilotLeftoverItem -Item ([PSCustomObject]@{ Kind='Registry'; Path=$path })
    }

    # Datei/Ordner/Shortcut -> Papierkorb
    if (Test-Path $path) {
        try {
            Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
            $ui = [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs
            $rp = [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
            if ((Get-Item $path -Force) -is [System.IO.DirectoryInfo]) {
                [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($path, $ui, $rp)
            } else {
                [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($path, $ui, $rp)
            }
            Write-Host "    [OK] In Papierkorb: $path" -ForegroundColor Green
            Write-SysPilotLog "Leftover in Papierkorb: $path" 'INFO'
            return $true
        } catch {
            # Fallback: direkt loeschen wenn Papierkorb fehlschlaegt
            try {
                Remove-Item $path -Recurse -Force -ErrorAction Stop
                Write-Host "    [OK] Geloescht: $path" -ForegroundColor Green
                Write-SysPilotLog "Leftover geloescht: $path" 'INFO'
                return $true
            } catch {
                Write-Host "    [!] Loeschen fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Yellow
                return $false
            }
        }
    }
    return $false
}

function Show-SysPilotLeftoverFlow {
    <# Wird nach erfolgreicher Deinstallation aufgerufen:
       scannt Reste, zeigt Liste, Multi-Select-Entfernung.
       Standard: ALLE Reste vorab abgehakt (abwaehlbar), Buttons
       "Markierte entfernen"/"Abbrechen". Optional per config.json
       CleanSweep.AutoLeftoverClean=$true: alle Reste automatisch
       entfernen (reversibel: Dateien->Papierkorb, Registry->Backup). #>
    param([Parameter(Mandatory)]$App, [switch]$ForceShow)
    $leftovers = @(Find-SysPilotProgramLeftovers -App $App)
    if ($leftovers.Count -eq 0) {
        if ($ForceShow) { Write-Host "  Keine Reste gefunden - sauber!" -ForegroundColor Green }
        return
    }
    $autoClean = ((Get-SysPilotConfig).CleanSweep.AutoLeftoverClean -eq $true)
    if ($autoClean) {
        Write-Host "  Auto-Clean: $($leftovers.Count) Reste fuer '$($App.Name)' werden entfernt ..." -ForegroundColor Cyan
        $autoRemoved = 0
        foreach ($l in $leftovers) { if (Remove-SysPilotLeftoverItem -Item $l) { $autoRemoved++ } }
        Write-Host "  [$autoRemoved/$($leftovers.Count)] Reste-Elemente automatisch entfernt." -ForegroundColor Green
        Write-SysPilotLog "Leftover-AutoClean: $($App.Name) - $autoRemoved von $($leftovers.Count)"
        return
    }
    Write-Host ""
    Write-Host "  Reste gefunden ($($leftovers.Count)) fuer '$($App.Name)' - alle vorab markiert:" -ForegroundColor Yellow
    $shown = @($leftovers | Select-Object -First 50)
    $menuItems = @()
    $i = 0
    foreach ($l in $shown) {
        $i++
        $p = "$($l.Path)"
        if ($p.Length -gt 80) { $p = $p.Substring(0, 77) + '...' }
        $col = switch ($l.Score) { {$_ -ge 60} {'Green'} {$_ -ge 45} {'Yellow'} default {'DarkGray'} }
        $menuItems += @{ Label = ("{0}. {1,-14} {2}  (Score {3})" -f $i, $l.Kind, $p, $l.Score); Color = $col; Tag = $l; Checked = $true }
    }
    if ($leftovers.Count -gt 50) { Write-Host "    ... und $($leftovers.Count - 50) weitere (A = alle, sonst Filter im Reste-Scanner)" -ForegroundColor DarkGray }

    $msActions = @(
        @{ Label = 'Markierte entfernen'; Tag = 'remove'; Color = 'Green' }
        @{ Label = 'Abbrechen';         Tag = 'back';   Color = 'DarkGray' }
    )
    $res = Show-SysPilotMultiSelectMenu -Items $menuItems -Title "Reste bereinigen fuer '$($App.Name)'" -Actions $msActions -Footer 'Klick = Haken an/aus, 1 = entfernen, Enter = entfernen, Esc = ueberspringen'
    if ($null -eq $res -or $res.Action -eq 'back') { return }
    $items = @($res.Selected)
    if ($items.Count -eq 0) { return }
    $removed = 0
    foreach ($it in $items) {
        if (Remove-SysPilotLeftoverItem -Item $it) { $removed++ }
    }
    Write-Host "  [$removed/$($items.Count)] Reste-Elemente entfernt." -ForegroundColor Green
    Write-SysPilotLog "Leftover-Cleanup: $($App.Name) - $removed von $($items.Count)"
}

# =======================================================================
# Browser-Erweiterungen: Inventar + Entfernen
# =======================================================================
function Get-SysPilotBrowserExtensionInventory {
    <# Erweiterte Version von Get-SysPilotExtensions (Extensions.psm1):
       liefert zusaetzlich Pfad-Infos fuer die Entfernung. #>
    $profiles = @(Get-SysPilotBrowserProfiles)
    $exts = @()
    foreach ($p in $profiles) {
        if ($p.Browser -in @('Firefox', 'Tor')) {
            $json = Join-Path $p.Pfad 'extensions.json'
            if (Test-Path $json) {
                try {
                    $data = Read-SysPilotFileRaw -Path $json | ConvertFrom-Json
                    foreach ($a in $data.addons) {
                        if ($a.type -ne 'extension') { continue }
                        $exts += [PSCustomObject]@{
                            Browser = $p.Browser; Profil = $p.Profil; ProfilPfad = $p.Pfad
                            Name = $(if ($a.defaultLocale.name) { $a.defaultLocale.name } else { $a.id })
                            Id = $a.id; Version = $a.version; Aktiv = (-not $a.userDisabled)
                            Source = 'extensions.json'; ManifestPath = $null
                            Engine = 'firefox'; Settings = $p.Settings
                        }
                    }
                } catch { }
            }
        } else {
            $prefFile = Join-Path $p.Pfad 'Secure Preferences'
            if (-not (Test-Path $prefFile)) { $prefFile = Join-Path $p.Pfad 'Preferences' }
            if (-not (Test-Path $prefFile)) { continue }
            # Lenient-Parser: funktioniert auch bei doppelten JSON-Schluesseln
            # (z.B. Edge Secure Preferences -> sonst 0 Extensions)
            $settings = Get-SysPilotChromiumExtensionSettings -PrefPath $prefFile
            if (-not $settings) { continue }
            try {
                foreach ($prop in $settings.PSObject.Properties) {
                    $entry = $prop.Value
                    if ($null -eq $entry.manifest) { continue }
                    if ($entry.manifest.type -eq 'theme') { continue }
                    $exts += [PSCustomObject]@{
                        Browser = $p.Browser; Profil = $p.Profil; ProfilPfad = $p.Pfad
                        Name = $(if ($entry.manifest.name) { $entry.manifest.name } else { $prop.Name })
                        Id = $prop.Name; Version = $entry.manifest.version
                        Aktiv = ($entry.state -ne 0)
                        Source = (Split-Path $prefFile -Leaf)
                        ManifestPath = $prefFile
                        Engine = 'chromium'; Settings = $p.Settings
                    }
                }
            } catch { }
        }
    }
    return $exts
}

function Backup-SysPilotFile {
    param([Parameter(Mandatory)][string]$Path)
    $bak = Join-Path (Get-SysPilotBackupDir) 'extensions'
    if (-not (Test-Path $bak)) { New-Item -ItemType Directory -Force -Path $bak | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    # WICHTIG: Klammern um den concat-Ausdruck - sonst parsed PowerShell
    # das '+' als eigenes Positionsargument fuer Join-Path -> Fehler.
    $destName = "$stamp-" + ($Path -replace '[\\/:*?"<>|]','_')
    $dest = Join-Path $bak $destName
    Copy-Item $Path $dest -Force -ErrorAction SilentlyContinue
    return $dest
}

function Remove-SysPilotBrowserExtension {
    <# Entfernt eine Browser-Erweiterung:
       Chromium: Secure/Preferences-Backup -> extensions.settings.<id> entfernen
                 -> Extensions\<id>-Ordner + Local Extension Settings loeschen
       Firefox:  extensions.json-Backup -> addon-Eintrag entfernen -> Datei loeschen
       Gibt $true/$false zurueck. #>
    param([Parameter(Mandatory)]$Ext)
    Write-SysPilotLog "Extension-Entfernung: $($Ext.Browser)/$($Ext.Name) ($($Ext.Id))"

    if ($Ext.Engine -eq 'chromium') {
        $prof = $Ext.ProfilPfad
        $browserProcs = @(Get-SysPilotBrowserProcesses -Browser $Ext.Browser)
        $procRunning = ($browserProcs.Count -gt 0)
        Write-SysPilotDebug "Entfernung $($Ext.Id): browser=$($Ext.Browser) running=$procRunning prof=$prof"
        if ($procRunning) {
            Write-Host "    [!] $($Ext.Browser) laeuft - Extension wird erst nach Browser-Neustart vollstaendig entfernt." -ForegroundColor Yellow
        }
        $removed = $false
        # 1. Settings-Eintrag aus Secure Preferences + Preferences entfernen
        #    (roh-Text-Edit: funktioniert auch bei doppelten JSON-Schluesseln,
        #    z.B. Edge; vorher wird die Datei nach backup\extensions kopiert)
        foreach ($pf in @('Secure Preferences','Preferences')) {
            $f = Join-Path $prof $pf
            if (-not (Test-Path $f)) { Write-SysPilotDebug "  ${pf}: nicht vorhanden"; continue }
            try {
                Backup-SysPilotFile -Path $f | Out-Null
                $ok = Remove-SysPilotPrefExtensionEntry -FilePath $f -ExtId $Ext.Id
                Write-SysPilotDebug "  ${pf}: Remove-SysPilotPrefExtensionEntry -> $ok"
                if ($ok) { $removed = $true }
            } catch {
                Write-SysPilotDebug "  ${pf}: FEHLER $($_.Exception.GetType().Name): $($_.Exception.Message)"
                Write-Host "    [!] $pf konnte nicht aktualisiert werden: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
        # 2. Extensions-Ordner + lokale Daten loeschen (Papierkorb)
        $extDir = Join-Path $prof "Extensions\$($Ext.Id)"
        $localDir = Join-Path $prof "Local Extension Settings\$($Ext.Id)"
        $syncDir = Join-Path $prof "Sync Extension Settings\$($Ext.Id)"
        foreach ($d in @($extDir, $localDir, $syncDir)) {
            if (Test-Path $d) {
                try {
                    Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
                    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($d,
                        [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                        [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
                    Write-SysPilotDebug "  Ordner geloescht (Papierkorb): $d"
                    $removed = $true
                } catch {
                    try { Remove-Item $d -Recurse -Force -ErrorAction Stop; $removed = $true; Write-SysPilotDebug "  Ordner geloescht (force): $d" }
                    catch {
                        Write-SysPilotDebug "  Ordner NICHT loeschbar: $d - $($_.Exception.Message)"
                        Write-Host "    [!] Ordner nicht loeschbar: $d" -ForegroundColor Yellow
                    }
                }
            }
        }
        if ($removed) {
            Write-Host "    [OK] Entfernt: $($Ext.Name) ($($Ext.Browser))" -ForegroundColor Green
            Write-SysPilotLog "Extension entfernt: $($Ext.Browser)/$($Ext.Id)"
            return $true
        }
        Write-Host "    [!] Nichts zu entfernen gefunden fuer $($Ext.Id)" -ForegroundColor Yellow
        return $false
    }

    if ($Ext.Engine -eq 'firefox') {
        $json = Join-Path $Ext.ProfilPfad 'extensions.json'
        if (-not (Test-Path $json)) { return $false }
        try {
            Backup-SysPilotFile -Path $json | Out-Null
            $rawJson = Read-SysPilotFileRaw -Path $json
            $data = $rawJson | ConvertFrom-Json
            $before = @($data.addons).Count
            $data.addons = @($data.addons | Where-Object { $_.id -ne $Ext.Id })
            if (@($data.addons).Count -eq $before) {
                Write-Host "    [!] Extension nicht in extensions.json gefunden." -ForegroundColor Yellow
                return $false
            }
            # ohne BOM schreiben (sonst evtl. ungueltiges JSON fuer Firefox)
            Write-SysPilotFileRaw -Path $json -Content ($data | ConvertTo-Json -Depth 100 -Compress) | Out-Null
            # Referenzierte Erweiterungs-Datei best effort loeschen:
            # Profil-extensions\<id>* und Firefox-Install\browser\extensions\<id>*
            $idPat = '*'+$Ext.Id+'*'
            $candidates = @(
                (Join-Path $Ext.ProfilPfad 'extensions'),
                "$env:ProgramFiles\Mozilla Firefox\browser\extensions",
                "${env:ProgramFiles(x86)}\Mozilla Firefox\browser\extensions"
            )
            $deleted = $false
            foreach ($dir in $candidates) {
                if (-not (Test-Path $dir)) { continue }
                Get-ChildItem $dir -Filter $idPat -ErrorAction SilentlyContinue | ForEach-Object {
                    try {
                        if ((Get-Item $_.FullName -Force) -is [System.IO.DirectoryInfo]) {
                            Remove-Item $_.FullName -Recurse -Force -ErrorAction Stop
                        } else {
                            Remove-Item $_.FullName -Force -ErrorAction Stop
                        }
                        $deleted = $true
                    } catch { }
                }
            }
            Write-Host "    [OK] Aus extensions.json entfernt: $($Ext.Name) - Firefox neu starten!" -ForegroundColor Green
            if ($deleted) { Write-Host "    [OK] Erweiterungs-Datei(en) geloescht." -ForegroundColor Green }
            Write-SysPilotLog "Firefox-Extension entfernt: $($Ext.Id)"
            return $true
        } catch {
            Write-Host "    [!] extensions.json-Update fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Red
            Write-SysPilotLog "Firefox-Extension-Fehler: $($Ext.Id): $($_.Exception.Message)" 'ERROR'
            return $false
        }
    }
    return $false
}

# =======================================================================
# Sync-Schutz: ExtensionSettings-Policy blockiert Re-Installation durch Sync
# =======================================================================
function Test-SysPilotAiBrowser {
    <# KI-Browser (Perplexity Comet, BrowserOS): in der Extension-
       Entfernung nur EINZELN waehlbar - nie in "Alle Browser" oder
       Cross-Browser-Matching einbezogen. #>
    param([Parameter(Mandatory)][string]$Name)
    return ($Name -in @('Perplexity Comet', 'BrowserOS'))
}

function Get-SysPilotBrowserProcesses {
    <# Laufende Prozesse eines Browsers. Pfad-gestuetzt, weil BrowserOS
       als chrome.exe laeuft und Firefox/Tor beide firefox.exe nutzen -
       eine reine Namenspruefung wuerde falsche Browser treffen. #>
    param([Parameter(Mandatory)][string]$Browser)
    $map = @{
        'Chrome'           = @{ Proc = 'chrome';   Path = '*Google\Chrome*' }
        'Edge'             = @{ Proc = 'msedge';   Path = '*Microsoft\Edge*' }
        'Brave'            = @{ Proc = 'brave';    Path = '*BraveSoftware*' }
        'Opera'            = @{ Proc = 'opera';    Path = '*Opera*' }
        'Vivaldi'          = @{ Proc = 'vivaldi';  Path = '*Vivaldi*' }
        'Chromium'         = @{ Proc = 'chromium'; Path = '*Chromium*' }
        'Perplexity Comet' = @{ Proc = 'comet';    Path = '*Perplexity\Comet*' }
        'BrowserOS'        = @{ Proc = 'chrome';   Path = '*BrowserClaw*' }
        'Firefox'          = @{ Proc = 'firefox';  Path = '*Mozilla Firefox*' }
        'Tor'              = @{ Proc = 'firefox';  Path = '*Tor Browser*' }
    }
    $m = $map[$Browser]
    if (-not $m) {
        return @(Get-Process -Name $Browser.ToLower() -ErrorAction SilentlyContinue)
    }
    return @(Get-Process -Name $m.Proc -ErrorAction SilentlyContinue | Where-Object {
        $null -eq $_.Path -or $_.Path -like $m.Path
    })
}

function Get-SysPilotBrowserExePath {
    <# Sucht die ausfuehrbare Datei eines Browsers: erst der Pfad eines
       laufenden Prozesses (zuverlaessigster Treffer), dann App Paths
       in der Registry, dann uebliche Installationsverzeichnisse.
       Liefert $null wenn nichts gefunden wird. #>
    param([Parameter(Mandatory)][string]$Browser)
    $proc = @(Get-SysPilotBrowserProcesses -Browser $Browser) | Where-Object { $_.Path } | Select-Object -First 1
    if ($proc) { return $proc.Path }
    $exeName = switch ($Browser) {
        'Chrome'           { 'chrome.exe' }
        'Edge'             { 'msedge.exe' }
        'Brave'            { 'brave.exe' }
        'Opera'            { 'opera.exe' }
        'Vivaldi'          { 'vivaldi.exe' }
        'Chromium'         { 'chrome.exe' }
        'Perplexity Comet' { 'Comet.exe' }
        'BrowserOS'        { 'BrowserOS.exe' }
        'Firefox'          { 'firefox.exe' }
        'Tor'              { 'firefox.exe' }
        default            { "$Browser.exe" }
    }
    foreach ($root in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths')) {
        $ap = Join-Path $root $exeName
        if (Test-Path $ap) {
            try {
                $p = (Get-Item $ap).GetValue('')
                if ($p -and (Test-Path $p)) { return $p }
            } catch { }
        }
    }
    $candidates = switch ($Browser) {
        'Chrome'    { @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe", "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe") }
        'Edge'      { @("$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe", "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe") }
        'Brave'     { @("$env:ProgramFiles\BraveSoftware\Brave-Browser\Application\brave.exe", "${env:ProgramFiles(x86)}\BraveSoftware\Brave-Browser\Application\brave.exe", "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\Application\brave.exe") }
        'Opera'     { @("$env:LOCALAPPDATA\Programs\Opera\opera.exe", "$env:ProgramFiles\Opera\opera.exe", "${env:ProgramFiles(x86)}\Opera\opera.exe") }
        'Vivaldi'   { @("$env:LOCALAPPDATA\Vivaldi\Application\vivaldi.exe", "$env:ProgramFiles\Vivaldi\Application\vivaldi.exe", "${env:ProgramFiles(x86)}\Vivaldi\Application\vivaldi.exe") }
        'Firefox'   { @("$env:ProgramFiles\Mozilla Firefox\firefox.exe", "${env:ProgramFiles(x86)}\Mozilla Firefox\firefox.exe") }
        'Perplexity Comet' { @("$env:LOCALAPPDATA\Perplexity\Comet\Application\Comet.exe", "$env:LOCALAPPDATA\Programs\Comet\Comet.exe") }
        'BrowserOS' { @("$env:LOCALAPPDATA\BrowserClaw\Application\BrowserOS.exe", "$env:LOCALAPPDATA\Programs\BrowserOS\BrowserOS.exe") }
        default     { @() }
    }
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}

function Open-SysPilotExtensionPages {
    <# Oeffnet fuer jede Extension die Detailseite im Browser
       (<scheme>://extensions/?id=<id>). Der User klickt dort auf
       'Entfernen' - der Browser selbst entfernt die Extension und
       propagiert die Loeschung ueber den Account-Sync. Das ist der
       sync-sichere Weg: kein Datei-Edit noetig, kein Policy-Block,
       Browser bleibt nicht 'verwaltet'. #>
    param([Parameter(Mandatory)][array]$Exts)
    $opened = @{}
    $manual = @()
    # Pro Browser ein Start mit allen Extension-URLs - Chrome oeffnet sie
    # als Tabs in EINEM neuen Fenster (kein Fenster pro Extension).
    $byBrowser = @{}
    foreach ($e in $Exts) {
        $base = "$($e.Settings)"
        if (-not $base) { $base = 'chrome://extensions/' }
        if ($e.Engine -eq 'chromium') { $url = "$($base.TrimEnd('/'))/?id=$($e.Id)" }
        else { $url = $base }   # Firefox: about:addons (kein Deep-Link pro Extension)
        if (-not $byBrowser.ContainsKey($e.Browser)) { $byBrowser[$e.Browser] = @() }
        $byBrowser[$e.Browser] += $url
    }
    foreach ($b in @($byBrowser.Keys | Sort-Object)) {
        $exe = Get-SysPilotBrowserExePath -Browser $b
        $urls = @($byBrowser[$b] | Select-Object -Unique)
        if ($exe) {
            try {
                # --new-window: eigener Fenster-Fokus, sonst landet der Tab
                # unsichtbar im Hintergrund (User sah nur TabMark-NTP)
                Start-Process -FilePath $exe -ArgumentList (@('--new-window') + $urls) -ErrorAction Stop
                $opened[$b] = $true
            } catch {
                $urls | ForEach-Object { $manual += "  $b : $_" }
            }
        } else {
            $urls | ForEach-Object { $manual += "  $b : $_" }
        }
    }
    Write-Host ""
    if ($opened.Count -gt 0) {
        Write-Host "  Extension-Seiten geoeffnet: $(($opened.Keys | Sort-Object) -join ', ')" -ForegroundColor Green
        Write-Host "  In JEDEM Tab Scrollen bis unten -> 'Entfernen' klicken." -ForegroundColor Green
        Write-Host "  Der Browser entfernt die Extension dann auch aus den Sync-Daten -" -ForegroundColor DarkGray
        Write-Host "  keine Policy noetig, der Browser bleibt NICHT 'verwaltet'." -ForegroundColor DarkGray
    }
    if ($manual.Count -gt 0) {
        Write-Host "  Fuer diese Browser keine Exe gefunden - bitte manuell oeffnen:" -ForegroundColor Yellow
        $manual | ForEach-Object { Write-Host "$_" -ForegroundColor Yellow }
    }
    Write-Host ""
    Write-SysPilotLog "Extension-Seiten geoeffnet: $($Exts.Count) Extension(en) in $($opened.Count) Browser(n)"
}

function Get-SysPilotBrowserPolicyPath {
    <# HKCU-Policy-Registry-Pfad fuer Chromium-basierte Browser
       (ExtensionSettings wird von Chrome/Edge/Brave/Vivaldie/Chromium
       ausgewertet; HKCU = pro Benutzer, kein Admin noetig). #>
    param([Parameter(Mandatory)][string]$Browser)
    switch ($Browser) {
        'Chrome'    { 'HKCU:\SOFTWARE\Policies\Google\Chrome' }
        'Edge'      { 'HKCU:\SOFTWARE\Policies\Microsoft\Edge' }
        'Brave'     { 'HKCU:\SOFTWARE\Policies\BraveSoftware\Brave' }
        'Vivaldi'   { 'HKCU:\SOFTWARE\Policies\Vivaldi' }
        'Chromium'  { 'HKCU:\SOFTWARE\Policies\Chromium' }
        default     { $null }
    }
}

function Test-SysPilotBrowserProfileSignedIn {
    <# $true wenn das Profil bei einem Konto angemeldet ist - nur dann
       kann Sync entfernte Erweiterungen erneut installieren.
       Quellen (live geprueft): Local State -> profile.info_cache.<name>
       (gaia_id / edge_account_cid / user_name, edge_sync_enabled),
       Fallback: profile Preferences -> account_info[].email. #>
    param([Parameter(Mandatory)][string]$ProfilePath)
    $leaf = Split-Path $ProfilePath -Leaf
    $userData = Split-Path $ProfilePath -Parent
    $ls = Join-Path $userData 'Local State'
    if (Test-Path $ls) {
        try {
            $raw = Read-SysPilotFileRaw -Path $ls
            $ic = Find-SysPilotJsonSection -Json $raw -Key 'info_cache'
            if ($ic) {
                $profSec = Find-SysPilotJsonSection -Json $ic.Text -Key $leaf
                if ($profSec) {
                    $t = $profSec.Text
                    # Edge: explizites Flag hat Vorrang
                    if ($t -match '"edge_sync_enabled"\s*:\s*false') { return $false }
                    if ($t -match '"edge_sync_enabled"\s*:\s*true')  { return $true }
                    if ($t -match '"gaia_id"\s*:\s*"[^"]+"' -and $t -notmatch '"gaia_id"\s*:\s*""') { return $true }
                    if ($t -match '"edge_account_cid"\s*:\s*"[^"]+"') { return $true }
                    if ($t -match '"user_name"\s*:\s*"[^"]+@') { return $true }
                }
            }
        } catch { }
    }
    # Fallback: account_info im Profil-Preferences
    $pf = Join-Path $ProfilePath 'Preferences'
    if (Test-Path $pf) {
        try {
            $raw2 = Read-SysPilotFileRaw -Path $pf
            $ai = Find-SysPilotJsonSection -Json $raw2 -Key 'account_info'
            if ($ai -and $ai.Text -match '"email"\s*:\s*"[^"]+@') { return $true }
        } catch { }
    }
    return $false
}

function Get-SysPilotExtensionBlockFile {
    return (Join-Path (Get-SysPilotBackupDir) 'extension-policy-blocks.json')
}

function Set-SysPilotExtensionPolicyBlock {
    <# Schreibt "installation_mode":"blocked" fuer die gegebenen
       Extension-IDs in die ExtensionSettings-Richtlinie des Browsers
       (HKCU, REG_SZ mit JSON). MERGE-basiert: vorhandene Policy-
       Eintraege (andere Modi, andere IDs) bleiben unveraendert.
       Wirkt ab naechstem Browserstart. Protolliert die IDs in
       extension-policy-blocks.json (Backup-Ordner) fuer spaeteres
       Aufheben via Remove-SysPilotExtensionPolicyBlock. #>
    param([Parameter(Mandatory)][string]$Browser,
          [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ExtIds)
    $key = Get-SysPilotBrowserPolicyPath $Browser
    if (-not $key) { return 0 }
    $ids = @($ExtIds | Where-Object { $_ } | Select-Object -Unique)
    if ($ids.Count -eq 0) { return 0 }

    # vorhandene Policy parsen (Objekt: id -> Einstellungen)
    $policy = [ordered]@{}
    try {
        $cur = (Get-ItemProperty -Path $key -Name 'ExtensionSettings' -ErrorAction Stop).ExtensionSettings
        if ($cur) {
            $parsed = $cur | ConvertFrom-Json -ErrorAction Stop
            foreach ($p in $parsed.PSObject.Properties) { $policy[$p.Name] = $p.Value }
        }
    } catch { }
    foreach ($id in $ids) {
        $policy[$id] = [pscustomobject]@{ installation_mode = 'blocked' }
    }
    $json = ($policy | ConvertTo-Json -Depth 6 -Compress)
    try {
        if (-not (Test-Path $key)) { New-Item -Path $key -Force -ErrorAction Stop | Out-Null }
        Set-ItemProperty -Path $key -Name 'ExtensionSettings' -Value $json -Type String -ErrorAction Stop
    } catch {
        Write-Host "    [!] Policy-Schreiben fehlgeschlagen (Admin-Rechte noetig?): $($_.Exception.Message)" -ForegroundColor Yellow
        Write-SysPilotLog "ExtensionSettings-Policy $Browser fehlgeschlagen: $($_.Exception.Message)" 'WARN'
        return 0
    }

    # Protokoll fuehr was SysPilot blockiert hat (reversibel)
    try {
        $recFile = Get-SysPilotExtensionBlockFile
        $rec = [pscustomobject]@{}
        if (Test-Path $recFile) {
            $old = Get-Content $recFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($old) { foreach ($p in $old.PSObject.Properties) { $rec | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force } }
        }
        $cur2 = @()
        if ($rec.PSObject.Properties[$Browser]) { $cur2 = @($rec.$Browser) }
        $merged = @($cur2 + $ids | Select-Object -Unique)
        if ($rec.PSObject.Properties[$Browser]) { $rec.$Browser = $merged }
        else { $rec | Add-Member -NotePropertyName $Browser -NotePropertyValue $merged }
        $rec | ConvertTo-Json -Depth 6 | Set-Content $recFile -Encoding UTF8
    } catch { Write-SysPilotLog "Extension-Block-Protokoll fehlgeschlagen: $($_.Exception.Message)" 'WARN' }

    Write-SysPilotLog "ExtensionSettings-Policy ${Browser}: $($ids.Count) ID(s) blockiert"
    return $ids.Count
}

function Remove-SysPilotExtensionPolicyBlock {
    <# Hebt von SysPilot gesetzte ExtensionSettings-Blocks wieder auf:
       entfernt die IDs aus der Policy (andere Eintraege bleiben).
       Loescht den ExtensionSettings-Wert, wenn keine Eintraege
       uebrig bleiben. #>
    param([Parameter(Mandatory)][string]$Browser,
          [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ExtIds)
    $key = Get-SysPilotBrowserPolicyPath $Browser
    if (-not $key) { return 0 }
    if (-not (Test-Path $key)) { return 0 }
    $cur = (Get-ItemProperty -Path $key -Name 'ExtensionSettings' -ErrorAction SilentlyContinue).ExtensionSettings
    if (-not $cur) { return 0 }
    try { $parsed = $cur | ConvertFrom-Json -ErrorAction Stop } catch { return 0 }
    $ids = @($ExtIds | Where-Object { $_ } | Select-Object -Unique)
    $removed = 0
    foreach ($id in $ids) {
        if ($parsed.PSObject.Properties[$id]) {
            $parsed.PSObject.Properties.Remove($id)
            $removed++
        }
    }
    if ($removed -eq 0) { return 0 }
    if (@($parsed.PSObject.Properties).Count -eq 0) {
        Remove-ItemProperty -Path $key -Name 'ExtensionSettings' -ErrorAction SilentlyContinue
    } else {
        $json = ($parsed | ConvertTo-Json -Depth 6 -Compress)
        try { Set-ItemProperty -Path $key -Name 'ExtensionSettings' -Value $json -Type String -ErrorAction Stop }
        catch { Write-Host "    [!] Policy-Schreiben fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Yellow; return 0 }
    }
    # Protokoll nachziehen
    try {
        $recFile = Get-SysPilotExtensionBlockFile
        if (Test-Path $recFile) {
            $rec = Get-Content $recFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($rec -and $rec.PSObject.Properties[$Browser]) {
                $rest = @($rec.$Browser | Where-Object { $ids -notcontains $_ })
                if ($rest.Count -eq 0) { $rec.PSObject.Properties.Remove($Browser) }
                else { $rec.$Browser = $rest }
                if (@($rec.PSObject.Properties).Count -eq 0) { Remove-Item $recFile -Force -ErrorAction SilentlyContinue }
                else { $rec | ConvertTo-Json -Depth 6 | Set-Content $recFile -Encoding UTF8 }
            }
        }
    } catch { }
    Write-SysPilotLog "ExtensionSettings-Policy ${Browser}: $removed Block(s) aufgehoben"
    return $removed
}

function Get-SysPilotBrowserExtensionPolicy {
    <# Liest den ExtensionSettings-Wert der HKCU-Policy eines
       Chromium-Browsers. Liefert $null wenn keine Policy existiert.
       Unterscheidet SysPilot-Blocks (aus extension-policy-blocks.json)
       von fremden Policy-Eintraegen. #>
    param([Parameter(Mandatory)][string]$Browser)
    $key = Get-SysPilotBrowserPolicyPath $Browser
    if (-not $key -or -not (Test-Path $key)) { return $null }
    $cur = (Get-ItemProperty -Path $key -Name 'ExtensionSettings' -ErrorAction SilentlyContinue).ExtensionSettings
    if (-not $cur) { return $null }
    $ids = @()
    try {
        $parsed = $cur | ConvertFrom-Json -ErrorAction Stop
        $ids = @($parsed.PSObject.Properties | ForEach-Object { $_.Name })
    } catch { }
    $spIds = @()
    $recFile = Get-SysPilotExtensionBlockFile
    if (Test-Path $recFile) {
        try {
            $rec = Get-Content $recFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            if ($rec -and $rec.PSObject.Properties[$Browser]) { $spIds = @($rec.$Browser) }
        } catch { }
    }
    return [pscustomobject]@{
        Browser     = $Browser
        Key         = $key
        Ids         = $ids
        SysPilotIds = @($ids | Where-Object { $spIds -contains $_ })
        ForeignIds  = @($ids | Where-Object { $spIds -notcontains $_ })
        Raw         = $cur
    }
}

function Show-SysPilotExtensionPolicyManager {
    <# Verwaltet ExtensionSettings-Policy-Bloecke (Sync-Schutz).
       WICHTIG: JEDE Policy unter ...\Policies macht den Browser als
       'von der Organisation verwaltet' -> Einstellungen (DNS,
       Cookies, Tracking-Schutz) werden gesperrt. Hier kann der User
       Bloecke aufheben, ohne die Registry von Hand zu editieren. #>
    $browsers = @('Chrome', 'Edge', 'Brave', 'Vivaldi', 'Chromium')
    while ($true) {
        Write-SysPilotHeader "Extension-Policy-Bloecke (Sync-Schutz)"
        Write-Host "  ExtensionSettings-Policies blockieren Extensions dauerhaft," -ForegroundColor DarkGray
        Write-Host "  machen den Browser aber als 'organisationsverwaltet' -" -ForegroundColor DarkGray
        Write-Host "  dann sind dessen Einstellungen (DNS, Cookies, Schutz) gesperrt." -ForegroundColor DarkGray
        Write-Host ""
        if (-not (Test-SysPilotAdmin)) {
            Write-Host "  [i] Policy-Keys koennen Admin-Rechte brauchen -" -ForegroundColor DarkYellow
            Write-Host "      bei Schreibfehlern SysPilot elevated neu starten." -ForegroundColor DarkYellow
        }
        $pols = @()
        foreach ($b in $browsers) {
            $p = Get-SysPilotBrowserExtensionPolicy -Browser $b
            if ($p) { $pols += $p }
        }
        if ($pols.Count -eq 0) {
            Write-Host "  Keine aktiven ExtensionSettings-Policies gefunden." -ForegroundColor Green
            Write-Host "  (Kein Browser ist 'organisationsverwaltet'.)" -ForegroundColor DarkGray
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            return
        }
        $items = @()
        foreach ($p in ($pols | Sort-Object Browser)) {
            $tag = "$($p.Browser): $($p.Ids.Count) blockiert"
            if ($p.ForeignIds.Count -gt 0) { $tag += " ($($p.ForeignIds.Count) nicht von SysPilot)" }
            $items += @{ Label = $tag; Color = 'Yellow'; Tag = $p.Browser }
        }
        $items += @{ Label = 'Zurueck'; Color = 'DarkGray'; Tag = 'back' }
        $sel = Show-SysPilotArrowMenu -Items $items -Title 'Policy-Bloecke - Browser auswaehlen' -Footer 'Pfeiltasten, Enter = auswaehlen, Esc = zurueck'
        if ($null -eq $sel -or $sel -eq 'back') { return }
        $p = @($pols | Where-Object Browser -eq $sel) | Select-Object -First 1
        if (-not $p) { continue }

        while ($true) {
            Write-Host ""
            Write-SysPilotHeader "$($p.Browser) - ExtensionSettings-Policy"
            Write-Host "  Key: $($p.Key)" -ForegroundColor DarkGray
            Write-Host "  Blockiert: $($p.Ids.Count) Extension-ID(s)" -ForegroundColor White
            Write-Host "    davon SysPilot: $($p.SysPilotIds.Count) | fremde Eintraege: $($p.ForeignIds.Count)" -ForegroundColor DarkGray
            Write-Host ""
            $sub = @(
                @{ Label = "Nur SysPilot-Blocks aufheben ($($p.SysPilotIds.Count))"; Color = 'Cyan';  Tag = 'sp' }
                @{ Label = "GESAMTE Policy entfernen ($($p.Ids.Count) Eintraege)"; Color = 'Red';   Tag = 'all' }
                @{ Label = 'Blockierte IDs auflisten';                                        Color = 'DarkGray'; Tag = 'ids' }
                @{ Label = 'Zurueck';                                                          Color = 'DarkGray'; Tag = 'back' }
            )
            $s2 = Show-SysPilotArrowMenu -Items $sub -Title "$($p.Browser) - Aktion" -Footer 'Pfeiltasten, Enter = auswaehlen, Esc = zurueck'
            if ($null -eq $s2 -or $s2 -eq 'back') { break }
            switch ($s2) {
                'ids' {
                    Write-Host ""
                    foreach ($id in $p.Ids) {
                        $mark = if ($p.SysPilotIds -contains $id) { '[SysPilot]' } else { '[fremd]  ' }
                        Write-Host "  $mark $id" -ForegroundColor DarkGray
                    }
                    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
                }
                'sp' {
                    if ($p.SysPilotIds.Count -eq 0) {
                        Write-Host "  Keine SysPilot-Blocks in dieser Policy." -ForegroundColor DarkYellow
                        Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
                        break
                    }
                    $msg = "$($p.Browser): $($p.SysPilotIds.Count) SysPilot-Block(s) aufheben?`n`nACHTUNG: Angemeldeter Sync kann entfernte Extensions erneut installieren.`nDer Browser bleibt 'verwaltet', solange fremde Eintraege existieren."
                    if (Confirm-SysPilot $msg) {
                        $n = Remove-SysPilotExtensionPolicyBlock -Browser $p.Browser -ExtIds $p.SysPilotIds
                        Write-Host "  $n Block(s) aufgehoben." -ForegroundColor Green
                        Write-Host "  Browser neu starten, damit die Policy neu gelesen wird." -ForegroundColor DarkGray
                        Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
                    }
                }
                'all' {
                    $msg = "$($p.Browser): GESAMTE ExtensionSettings-Policy entfernen?`n`n$($p.Ids.Count) Eintraege gehen verloren (auch fremde).`nDanach ist der Browser nicht mehr 'organisationsverwaltet' - alle Einstellungen wieder frei.`n`nACHTUNG: blockierte Extensions koennen sich per Sync erneut installieren."
                    if (Confirm-SysPilot $msg) {
                        try {
                            Remove-ItemProperty -Path $p.Key -Name 'ExtensionSettings' -ErrorAction Stop
                            $recFile = Get-SysPilotExtensionBlockFile
                            if (Test-Path $recFile) {
                                $rec = Get-Content $recFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction SilentlyContinue
                                if ($rec -and $rec.PSObject.Properties[$p.Browser]) {
                                    $rec.PSObject.Properties.Remove($p.Browser)
                                    if (@($rec.PSObject.Properties).Count -eq 0) { Remove-Item $recFile -Force -ErrorAction SilentlyContinue }
                                    else { $rec | ConvertTo-Json -Depth 6 | Set-Content $recFile -Encoding UTF8 }
                                }
                            }
                            Write-Host "  Policy entfernt - $($p.Browser) ist nicht mehr 'verwaltet'." -ForegroundColor Green
                        } catch {
                            Write-Host "  [!] Schreibfehler: $($_.Exception.Message)" -ForegroundColor Red
                            Write-Host "      Policy-Keys koennen Admin-Rechte brauchen - SysPilot elevated neu starten." -ForegroundColor Yellow
                        }
                        Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
                    }
                }
            }
            $p2 = Get-SysPilotBrowserExtensionPolicy -Browser $p.Browser
            if (-not $p2) { break }
            $p = $p2
        }
    }
}

function Show-SysPilotExtensionRemoval {
    <# Browser-Erweiterungen entfernen - komplett mausfuehrbar:
       1. Browser-Liste zum Anklicken (alle gefundenen Browser + "Alle")
       2. Multiselect-Liste: Klick = Haken, Buttons "Markierte entfernen"
          und "Abbrechen" direkt unter der Liste (oder Ziffern 1/2)
       3. Frage: gleiche Extension auch in anderen Browsern entfernen?
       Nach jeder Entfernung zurueck zur Browser-Liste (Schleife). #>
    $firstPass = $true
    while ($true) {
        # Inventar-Scan dauert bei vielen Browser-Profilen ~15-20 s -
        # ohne Hinweis wirkt das wie ein Haenger (User-Beschwerde 0.9.5.0).
        if (-not $firstPass) { Write-Host "  [..] Browser-Erweiterungen werden neu gescannt ..." -ForegroundColor DarkGray }
        $firstPass = $false
        $exts = @(Get-SysPilotBrowserExtensionInventory)
        Write-SysPilotDebug "Extension-Flow: Inventar = $($exts.Count) Eintraege"
        if ($exts.Count -eq 0) {
            Write-Host "  Keine Browser-Erweiterungen gefunden." -ForegroundColor Green
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            return
        }
        # 1. Browser-Auswahl (alle installierten Browser mit Erweiterungen)
        $groups = @($exts | Group-Object Browser | Sort-Object Name)
        $navItems = @()
        foreach ($g in $groups) {
            $navItems += @{ Label = ("{0}  ({1} Erweiterungen)" -f $g.Name, $g.Count); Color = 'White'; Tag = $g.Name }
        }
        # "Alle Browser" schliesst KI-Browser aus - sie sind nur einzeln
        # waehlbar (User-Wunsch: keine unbeabsichtigte Massen-Entfernung)
        $nonAiCount = @($exts | Where-Object { -not (Test-SysPilotAiBrowser $_.Browser) }).Count
        $navItems += @{ Label = ("Alle Browser  ({0} Erweiterungen)" -f $nonAiCount); Color = 'Cyan'; Tag = '__all' }
        $navItems += @{ Label = 'Fertig'; Color = 'DarkGray'; Tag = 'back' }
        $browser = Show-SysPilotArrowMenu -Items $navItems -Title "Browser-Erweiterungen - Browser waehlen" -Footer 'Klick/Pfeile+Enter = auswaehlen, Esc = fertig'
        Write-SysPilotDebug "Browser-Auswahl: $browser"
        if ($null -eq $browser -or $browser -eq 'back') { return }

        # 2. Extension-Liste des gewaehlten Browsers (oder alle)
        $list = @($exts | Where-Object {
            if ($browser -eq '__all') { -not (Test-SysPilotAiBrowser $_.Browser) }
            else { $_.Browser -eq $browser }
        } | Sort-Object Name, Profil)
        $menuItems = @()
        $i = 0
        foreach ($e in $list) {
            $i++
            $state = if ($e.Aktiv) { 'AN ' } else { 'aus' }
            $nm = "$($e.Name)"
            if ($nm.Length -gt 42) { $nm = $nm.Substring(0, 39) + '...' }
            if ($browser -eq '__all') {
                $br = "$($e.Browser)"
                if ($br.Length -gt 7) { $br = $br.Substring(0, 7) }
                $menuItems += @{ Label = ("{0}. {1,-4} {2,-44} {3,-8} {4}" -f $i, $state, $nm, $br, $e.Profil); Color = 'White'; Tag = $e; Checked = $false }
            } else {
                $prof = "$($e.Profil)"
                if ($prof.Length -gt 14) { $prof = $prof.Substring(0, 11) + '...' }
                $menuItems += @{ Label = ("{0}. {1,-4} {2,-44} {3}" -f $i, $state, $nm, $prof); Color = 'White'; Tag = $e; Checked = $false }
            }
        }
        $title = if ($browser -eq '__all') { "Alle Browser ($($list.Count))" } else { "$browser - Erweiterungen ($($list.Count))" }
        $msActions = @(
            @{ Label = 'Markierte entfernen'; Tag = 'remove'; Color = 'Green' }
            @{ Label = 'Im Browser oeffnen'; Tag = 'open'; Color = 'Cyan' }
            @{ Label = 'Abbrechen';         Tag = 'back';   Color = 'DarkGray' }
        )
        $res = Show-SysPilotMultiSelectMenu -Items $menuItems -Title $title -Actions $msActions -Footer 'Klick = Haken, Enter = weiter, A = alle, 1/2/3 = Buttons, Esc = Browserwahl'
        Write-SysPilotDebug "Multiselect $title : res=$(if($null -eq $res){'null'}else{"action=$($res.Action) sel=$($res.Selected.Count)"})"
        if ($null -eq $res) { continue }
        if ($res.Action -eq 'back') { continue }
        if ($res.Action -eq 'open') {
            $toOpen = @($res.Selected)
            if ($toOpen.Count -eq 0) {
                Write-Host "  Keine Extensions markiert - zuerst Haken setzen." -ForegroundColor Yellow
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
                continue
            }
            Open-SysPilotExtensionPages -Exts $toOpen
            Read-SysPilotChoice 'Weiter mit Enter (danach wird neu gescannt)' | Out-Null
            continue
        }
        if ($res.Selected.Count -eq 0) { continue }

        $chosen = @($res.Selected)
        # 4. Gleiche Extension in anderen Browsern suchen?
        #    Match: gleiche ID (Chromium-Browser teilen IDs) ODER gleicher
        #    normalisierter Name (fuer Firefox/Tor mit eigenen IDs).
        $normName = { param($n) ($n -replace '[^a-zA-Z0-9]','').ToLower() }
        $chosenKeys = @{}
        foreach ($c in $chosen) { $chosenKeys["$($c.Browser)|$($c.Id)"] = $true }
        $others = @()
        foreach ($c in $chosen) {
            $cName = & $normName "$($c.Name)"
            foreach ($o in $exts) {
                if ($o.Browser -eq $c.Browser) { continue }
                if (Test-SysPilotAiBrowser $o.Browser) { continue }
                $oKey = "$($o.Browser)|$($o.Id)"
                if ($chosenKeys.ContainsKey($oKey)) { continue }
                $sameId = ($o.Id -eq $c.Id)
                $sameName = ((& $normName "$($o.Name)") -eq $cName -and $cName.Length -gt 3)
                if ($sameId -or $sameName) {
                    $others += $o
                    $chosenKeys[$oKey] = $true
                }
            }
        }
        if ($others.Count -gt 0) {
            $oList = ($others | ForEach-Object { "$($_.Name) ($($_.Browser))" }) -join ', '
            if ($oList.Length -gt 300) { $oList = $oList.Substring(0, 297) + '...' }
            $crossOk = Confirm-SysPilot "Gleiche Erweiterung(en) in anderen Browsern mit entfernen?`n  + $($others.Count): $oList"
            Write-SysPilotDebug "Cross-Browser: $($others.Count) Treffer, Bestaetigung=$crossOk"
            if ($crossOk) {
                $chosen += $others
            }
        }

        # 3b. Laufende Browser blockieren: sie halten Secure Preferences/
        #     extensions.json im Speicher und ueberschreiben die Datei-
        #     Aenderung beim Beenden -> Extension kaeme zurueck.
        $running = @{}
        foreach ($c in $chosen) {
            $procs = @(Get-SysPilotBrowserProcesses -Browser $c.Browser)
            if ($procs.Count -gt 0) {
                if (-not $running.ContainsKey($c.Browser)) { $running[$c.Browser] = @() }
                $running[$c.Browser] += $procs
            }
        }
        $runInfo = @($running.Keys | ForEach-Object { "${_}:$(@($running[$_]).Count)" }) -join ', '
        Write-SysPilotDebug "Laufende Browser unter den Zielen: $runInfo"
        $killedBrowsers = @{}
        foreach ($rb in @($running.Keys)) {
            $procs = @($running[$rb] | Select-Object -Unique)
            $cnt = @($chosen | Where-Object { $_.Browser -eq $rb }).Count
            Write-Host "" -ForegroundColor DarkGray
            Write-Host "  [!] $rb laeuft ($cnt Extension(s) betroffen)." -ForegroundColor Yellow
            Write-Host "      Seine Einstellungen sind im Speicher - eine Datei-Aenderung" -ForegroundColor Yellow
            Write-Host "      wuerde beim Beenden ueberschrieben und die Extension bleibt." -ForegroundColor Yellow
            $dec = Show-SysPilotArrowMenu -Items @(
                @{ Label = "$rb beenden und entfernen (offene Tabs koennen verloren gehen!)"; Color = 'Yellow'; Tag = 'kill' }
                @{ Label = 'Trotzdem entfernen (Aenderung wird evtl. zurueckgesetzt)'; Color = 'DarkYellow'; Tag = 'force' }
                @{ Label = "$rb-Eintraege ueberspringen"; Color = 'DarkGray'; Tag = 'skip' }
            ) -Title "$rb laeuft - wie fortfahren?" -Footer 'Klick = waehlen, Esc = ueberspringen'
            Write-SysPilotDebug "$rb Lauf-Frage: Entscheidung=$dec"
            if ($dec -eq 'kill') {
                Write-Host "  Beende $rb ($($procs.Count) Prozess(e)) ..." -ForegroundColor Yellow
                # nur die Prozesse DIESes Browsers beenden (BrowserOS laeuft
                # z.B. als chrome.exe - Stop-Process -Name wuerde Chrome treffen)
                $procs | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
                # Stop-Process kehrt sofort zurueck - Chrome braucht aber
                # sekundenlang zum Sterben und schreibt dabei noch Prefs.
                # Warten bis der Prozessbaum wirklich leer ist, sonst
                # ueberschreibt der sterbende Browser unsere Edits.
                $deadline = (Get-Date).AddSeconds(15)
                while ((Get-Date) -lt $deadline) {
                    if (@(Get-SysPilotBrowserProcesses -Browser $rb).Count -eq 0) { break }
                    Start-Sleep -Milliseconds 500
                }
                $still = @(Get-SysPilotBrowserProcesses -Browser $rb)
                if ($still.Count -gt 0) {
                    Write-Host "  [!] $rb laeuft noch ($($still.Count) Prozess(e)) - Entfernen kann zurueckgesetzt werden." -ForegroundColor Yellow
                } else {
                    Write-Host "  $rb beendet." -ForegroundColor Green
                }
                $killedBrowsers[$rb] = $true
                Write-SysPilotLog "$rb fuer Extension-Entfernung beendet"
            } elseif ($dec -eq 'skip' -or $null -eq $dec) {
                $chosen = @($chosen | Where-Object { $_.Browser -ne $rb })
                Write-SysPilotLog "$rb-Eintraege uebersprungen (Browser lief)"
            }
            # 'force' = unveraendert (Datei-Edit, wird evtl. reverted)
        }
        if ($chosen.Count -eq 0) { Write-SysPilotDebug 'Nach Lauf-Filter: nichts zu tun'; continue }

        Write-Host ""
        Write-Host "  Folgende werden entfernt ($($chosen.Count)):" -ForegroundColor Yellow
        foreach ($c in $chosen) { Write-Host "    - $($c.Name) ($($c.Browser))" -ForegroundColor Yellow }
        Write-Host "  Hinweis: Chromium-Profile werden vorher gesichert (Secure Preferences/Preferences)." -ForegroundColor DarkGray
        Write-Host "  Sync-Hinweis: Bei angemeldeten Browsern kann die Extension vom Server" -ForegroundColor DarkYellow
        Write-Host "  zurueckkommen - danach bietet SysPilot eine Policy-Blockierung an." -ForegroundColor DarkYellow
        $finalOk = Confirm-SysPilot "$($chosen.Count) Erweiterung(en) wirklich entfernen?"
        Write-SysPilotDebug "Endbestaetigung ($($chosen.Count) Extensionen): $finalOk"
        if (-not $finalOk) {
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            continue
        }
        # Zwischen Kill-Frage und Endbestaetigung kann ein Browser neu
        # gestartet worden sein (User oeffnet ihn wieder, Autostart) -
        # ein laufender Browser ueberschreibt unsere Pref-Edits beim
        # Beenden und die Extension kommt zurueck (dann muss der User den
        # ganzen Flow wiederholen). Kill-Consent liegt bereits vor ->
        # einfach erneut beenden.
        foreach ($rb in @($killedBrowsers.Keys)) {
            $again = @(Get-SysPilotBrowserProcesses -Browser $rb)
            if ($again.Count -gt 0) {
                Write-Host "  $rb laeuft wieder - beende erneut, sonst kommt die Extension zurueck ..." -ForegroundColor Yellow
                $again | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
                $deadline = (Get-Date).AddSeconds(15)
                while ((Get-Date) -lt $deadline) {
                    if (@(Get-SysPilotBrowserProcesses -Browser $rb).Count -eq 0) { break }
                    Start-Sleep -Milliseconds 500
                }
                Write-SysPilotLog "$rb vor Entfernung erneut beendet (war zwischendurch neu gestartet)"
            }
        }
        $ok = 0
        $removedOk = @()
        foreach ($c in $chosen) {
            if (Remove-SysPilotBrowserExtension -Ext $c) { $ok++; $removedOk += $c }
        }
        Write-SysPilotDebug "Entfernung abgeschlossen: $ok/$($chosen.Count) erfolgreich"
        Write-Host ""
        Write-Host "  [$ok/$($chosen.Count)] Erweiterungen entfernt. Browser ggf. neu starten." -ForegroundColor Green
        Write-SysPilotLog "Extension-Bereinigung: $ok von $($chosen.Count)"

        # Sync-Schutz: Bei angemeldeten (sync-faehigen) Profilen kann der
        # Server die Extension erneut installieren -> per ExtensionSettings-
        # Policy blockieren (HKCU, merge-basiert, per Remove-SysPilot
        # ExtensionPolicyBlock wieder aufhebbar).
        $syncGroups = @{}
        foreach ($c in $removedOk) {
            if ($c.Engine -ne 'chromium') { continue }
            if (-not (Get-SysPilotBrowserPolicyPath $c.Browser)) { continue }
            if (-not (Test-SysPilotBrowserProfileSignedIn -ProfilePath $c.ProfilPfad)) { continue }
            if (-not $syncGroups.ContainsKey($c.Browser)) { $syncGroups[$c.Browser] = @() }
            $syncGroups[$c.Browser] += $c.Id
        }
        # HKCU-Policy braucht KEIN Admin - die Blockierung wird also
        # immer angeboten, auch wenn der Tool-Prozess nicht elevated ist.
        foreach ($bg in @($syncGroups.Keys | Sort-Object)) {
            $gids = @($syncGroups[$bg] | Select-Object -Unique)
            Write-Host ""
            Write-Host "  [i] $bg ist angemeldet - Sync kann entfernen wieder rueckgaengig" -ForegroundColor Cyan
            Write-Host "      machen. $($gids.Count) ID(s) per Richtlinie blockieren?" -ForegroundColor Cyan
            Write-Host "      (Wirkt ab Browser-Neustart, nur fuer diesen Rechner, jederzeit aufhebbar)" -ForegroundColor DarkGray
            $bgOk = Confirm-SysPilot "${bg}: $($gids.Count) Extension-ID(s) gegen Sync-Wiederherstellung blockieren?"
            Write-SysPilotDebug "Sync-Block $bg ($($gids.Count) IDs): Bestaetigung=$bgOk"
            if ($bgOk) {
                $n = Set-SysPilotExtensionPolicyBlock -Browser $bg -ExtIds $gids
                if ($n -gt 0) {
                    Write-Host "  [OK] $n ID(s) in ${bg} blockiert (HKCU-Policy, ab Neustart aktiv)." -ForegroundColor Green
                    Write-Host "       Aufheben: Remove-SysPilotExtensionPolicyBlock -Browser '$bg'" -ForegroundColor DarkGray
                } else {
                    Write-Host "  [!] Policy konnte nicht geschrieben werden." -ForegroundColor Yellow
                }
            }
        }
        Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
        # Schleife: Inventar wird neu geladen - naechste Browser-/Auswahl moeglich
    }
}

# =======================================================================
# Verwaiste Programme (Ordner ohne Uninstall-Eintrag) + defekte Eintraege
# =======================================================================
function Get-SysPilotOrphanPrograms {
    <# Findet Programm-Ordner in ueblichen Installationsorten, die KEINEN
       passenden Uninstall-Registry-Eintrag haben. #>
    $inventory = @(Get-SysPilotProgramInventory)
    $knownPaths = @()
    $knownNames = @()
    foreach ($a in $inventory) {
        if ($a.InstallLocation) { $knownPaths += $a.InstallLocation.Trim('"').ToLower() }
        $knownNames += $a.Name.ToLower()
        if ($a.Publisher) { $knownNames += $a.Publisher.ToLower() }
    }
    $roots = @(
        'C:\Program Files', 'C:\Program Files (x86)',
        "$env:LOCALAPPDATA\Programs", 'C:\ProgramData'
    ) | Select-Object -Unique
    $orphans = @()
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        Get-ChildItem $root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $d = $_.FullName
            $leaf = $_.Name
            # System-Ordner ueberspringen (ProgramData hat zusaetzlich
            # Installer-Caches und System-Ordner ohne Programm-Charakter)
            $skip = @('Windows','Microsoft.NET','Common Files','WindowsApps','ModifiableWindowsApps','Packages','Desktop','Documents and Settings','PerfLogs','Recovery','System Volume Information','$Recycle.Bin','Microsoft','Windows Defender','Reference Assemblies','dotnet','Microsoft Visual Studio',
                      'Package Cache','SoftwareDistribution','USOShared','Application Data','Templates','Crypto','ssh','Microsoft Help','WindowsHolographic',
                      'Hyper-V','IIS Express','Internet Explorer','Application Verifier','MSBuild','Windows Kits','PackageManagement','Windows Performance Toolkit',
                      'USOPrivate','CrossDevice','DeveloperTools','SquirrelMachineInstalls','ProductData','ProductData3','Whesvc','shimgen')
            if ($leaf -in $skip) { return }
            # Windows-Inbox-Komponenten (Windows Mail, Media Player, NT, ...)
            if ($leaf -like 'Windows*' -or $leaf -like 'Microsoft*' -or $leaf -like 'Microsoft.*') { return }
            if ($root -eq 'C:\ProgramData' -and $leaf -match '^(regid|chocolatey|pip|npm|Microsoft\.|Windows)') { return }
            # Match gegen bekannte InstallLocations (Prefix-Vergleich)
            $dl = $d.ToLower()
            $matched = $false
            foreach ($kp in $knownPaths) {
                if ($kp -and ($dl -eq $kp -or $kp.StartsWith($dl) -or $dl.StartsWith($kp))) { $matched = $true; break }
            }
            if (-not $matched) {
                # Normalisierter Vergleich: Leerzeichen/ Sonderzeichen raus,
                # sonst matcht z.B. Ordner 'Python314' nicht auf 'Python 3.14.x'
                $leafNorm = ($leaf.ToLower() -replace '[^a-z0-9]','')
                if ($leafNorm.Length -lt 4) { return }
                foreach ($kn in $knownNames) {
                    $knNorm = ($kn -replace '[^a-z0-9]','')
                    if ($knNorm.Length -lt 4) { continue }
                    if ($leafNorm -like "*$knNorm*" -or $knNorm.StartsWith($leafNorm) -or $leafNorm.StartsWith($knNorm)) { $matched = $true; break }
                }
            }
            if (-not $matched) {
                $orphans += [PSCustomObject]@{ Path = $d; Name = $leaf; Root = $root }
            }
        }
    }
    return $orphans
}

function Get-SysPilotBrokenUninstallEntries {
    <# Findet Uninstall-Eintraege mit fehlendem kaputtem UninstallString
       oder ohne jeglichen Deinstallationsbefehl. #>
    $broken = @()
    foreach ($v in (Get-SysPilotUninstallRegistryViews)) {
        $items = Get-ItemProperty $v.Path -ErrorAction SilentlyContinue
        foreach ($i in $items) {
            if (-not $i.DisplayName) { continue }
            if ($i.SystemComponent -or $i.ParentKeyName) { continue }
            $raw = if ($i.UninstallString) { $i.UninstallString } else { $i.QuietUninstallString }
            $problem = $null
            if (-not $raw) {
                $problem = 'Kein UninstallString'
            } else {
                $parsed = Split-SysPilotUninstallString -UninstallString $raw
                if ($parsed -and $parsed.Kind -eq 'exe' -and -not (Test-SysPilotExeExists -Exe $parsed.Exe)) {
                    $problem = "Programm fehlt: $($parsed.Exe)"
                } elseif (-not $parsed) {
                    $problem = 'Unparsbar'
                }
            }
            if ($problem) {
                $base = $v.Path -replace '\\\*$', ''
                $broken += [PSCustomObject]@{
                    Name = $i.DisplayName; Version = $i.DisplayVersion
                    Publisher = $i.Publisher; Problem = $problem
                    RegPath = "$base\$($i.PSChildName)"
                    UninstallKey = $i.PSPath; UninstallString = $i.UninstallString
                    InstallLocation = $i.InstallLocation; RegistryView = $v.View
                }
            }
        }
    }
    return $broken
}

function Invoke-SysPilotForceUninstall {
    <# Force-Uninstall fuer einen Ordner/eine Datei:
       loescht Ziel (Papierkorb) + raeumt passende Registry-Reste,
       Autostarts, Dienste und Aufgaben anhand der Ordner-Namen. #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) {
        Write-Host "  [!] Pfad existiert nicht: $Path" -ForegroundColor Red
        return
    }
    $leaf = Split-Path $Path -Leaf
    $tokens = @(Get-SysPilotNameTokens -Names @($leaf))
    if ($tokens.Count -eq 0) { $tokens = @($leaf) }
    Write-Host ""
    Write-SysPilotHeader "Force-Uninstall: $leaf"
    Write-Host "  Ziel:    $Path" -ForegroundColor Cyan
    Write-Host "  Tokens:  $($tokens -join ', ')" -ForegroundColor DarkGray

    # 1. Reste scannen (wie After-Uninstall-Flow, aber mit Pfad als Basis)
    # Sammle Kandidaten
    $candidates = New-Object System.Collections.Generic.List[object]
    $candidates.Add([PSCustomObject]@{ Kind='Datei/Ordner'; Path=$Path; Score=90; Reason='Ausgewaehltes Ziel' })
    $fakeApp = [PSCustomObject]@{ Name=$leaf; Publisher=''; InstallLocation=$Path; UninstallKey=$null }
    $targetNorm = $Path.TrimEnd('\').ToLower()
    foreach ($l in (Find-SysPilotProgramLeftovers -App $fakeApp -MinScore 30)) {
        if ($l.Path.TrimEnd('\').ToLower() -ne $targetNorm) { $candidates.Add($l) }
    }

    Write-Host ""
    Write-Host "  Kandidaten ($($candidates.Count)):" -ForegroundColor Cyan
    $i = 0
    foreach ($c in $candidates) {
        $i++
        Write-Host ("  [{0,3}] {1,-12} {2}  (Score {3})" -f $i, $c.Kind, $c.Path, $c.Score) -ForegroundColor DarkGray
    }
    if (-not (Confirm-SysPilot "Force-Uninstall: Ziel + Reste endgueltig entfernen (Papierkorb/Registry-Backup)?")) { return }

    $removed = 0
    foreach ($c in $candidates) {
        if (Remove-SysPilotLeftoverItem -Item $c) { $removed++ }
    }
    Write-Host ""
    Write-Host "  [$removed/$($candidates.Count)] Elemente entfernt." -ForegroundColor Green
    Write-SysPilotLog "Force-Uninstall: $Path - $removed von $($candidates.Count)"
}

# =======================================================================
# Windows Updates (optional, wusa-basiert)
# =======================================================================
function Get-SysPilotWindowsUpdates {
    <# Installierte Windows-Updates via Win32_QuickFixEngineering. #>
    try {
        $qfe = Get-CimInstance Win32_QuickFixEngineering -ErrorAction Stop
        $out = @()
        foreach ($q in $qfe) {
            $out += [PSCustomObject]@{
                HotFixID = $q.HotFixID
                KB = ($q.HotFixID -replace '^KB','')
                Description = $q.Description
                InstalledOn = $q.InstalledOn
                Caption = $q.Caption
            }
        }
        return @($out | Sort-Object InstalledOn -Descending)
    } catch { return @() }
}

function Remove-SysPilotWindowsUpdate {
    <# Deinstalliert ein Update via wusa.exe. Braucht Admin. #>
    param([Parameter(Mandatory)][string]$KB)
    if (-not (Assert-SysPilotAdmin)) { return $false }
    $kbNum = $KB -replace '^KB',''
    Write-Host "  Deinstalliere Update KB$kbNum ..." -ForegroundColor Cyan
    Write-SysPilotLog "Windows-Update-Deinstallation: KB$kbNum"
    try {
        $p = Start-Process 'wusa.exe' -ArgumentList "/uninstall /kb:$kbNum /quiet /norestart" -PassThru -Wait
        if ($p.ExitCode -eq 0) {
            Write-Host "  [OK] KB$kbNum deinstalliert (Neustart evtl. noetig)." -ForegroundColor Green
            Write-SysPilotLog "Windows-Update entfernt: KB$kbNum"
            return $true
        } else {
            Write-Host "  [!] wusa Exit $($p.ExitCode) - Update evtl. nicht entfernbar." -ForegroundColor Yellow
            Write-SysPilotLog "Windows-Update-Fehler: KB$kbNum exit=$($p.ExitCode)" 'WARN'
            return $false
        }
    } catch {
        Write-Host "  [!] Fehler: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# =======================================================================
# Systemwiederherstellungspunkt
# =======================================================================
function New-SysPilotRestorePoint {
    <# Erstellt einen Wiederherstellungspunkt (braucht Admin + aktivierte
       Systemwiederherstellung). #>
    if (-not (Assert-SysPilotAdmin)) { return $false }
    $desc = "SysPilot CleanSweep $((Get-Date).ToString('yyyy-MM-dd HH:mm'))"
    try {
        Write-Host "  Erstelle Wiederherstellungspunkt '$desc' ..." -ForegroundColor Cyan
        Checkpoint-Computer -Description $desc -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-Host "  [OK] Wiederherstellungspunkt erstellt." -ForegroundColor Green
        Write-SysPilotLog "Wiederherstellungspunkt erstellt: $desc"
        return $true
    } catch {
        Write-Host "  [!] Fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "      (Systemwiederherstellung muss auf dem Laufwerk aktiviert sein.)" -ForegroundColor DarkGray
        Write-SysPilotLog "Wiederherstellungspunkt-Fehler: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

# =======================================================================
# Menues (Pfeiltasten + Maus via Show-SysPilotArrowMenu)
# =======================================================================
function Show-SysPilotUninstallProgramsMenu {
    <# Desktop-Programme: Suche, Auswahl, silent/normal, Batch. #>
    $apps = @(Get-SysPilotProgramInventory)
    if ($apps.Count -eq 0) {
        Write-Host "  Keine Programme gefunden." -ForegroundColor Green
        Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
        return
    }
    $filter = ''
    while ($true) {
        $list = @($apps | Where-Object {
            -not $filter -or $_.Name -like "*$filter*" -or $_.Publisher -like "*$filter*"
        } | Sort-Object Name)
        Write-SysPilotHeader "CleanSweep: Programme deinstallieren ($($apps.Count) Eintraege)"
        if ($filter) { Write-Host "  Filter: '$filter'" -ForegroundColor Cyan }
        $nav = @(
            @{ Label = "Programme auswaehlen ($($list.Count) Eintraege)"; Color = 'White';  Tag = 'pick' }
            @{ Label = "Filter aendern (aktuell: $(if ($filter) { $filter } else { 'keiner' }))"; Color = 'Cyan'; Tag = 'filter' }
            @{ Label = 'Abbrechen'; Color = 'DarkGray'; Tag = 'back' }
        )
        $act = Show-SysPilotArrowMenu -Items $nav -Title "CleanSweep - Programme" -Footer 'Pfeiltasten/Klick, Enter = auswaehlen, Esc = zurueck'
        if ($null -eq $act -or $act -eq 'back') { return }
        if ($act -eq 'filter') {
            $filter = Read-SysPilotInput "Suchbegriff (leer = alle)"
            continue
        }
        $menuItems = @()
        $i = 0
        foreach ($a in $list) {
            $i++
            $sz = if ($a.SizeMB -gt 0) { "{0,6} MB" -f $a.SizeMB } else { '     -  ' }
            $broken = if ($a.UninstallString -or $a.QuietUninstallString) { '' } else { ' [KEIN UNINSTALL]' }
            $nm = "$($a.Name)"
            if ($nm.Length -gt 40) { $nm = $nm.Substring(0, 37) + '...' }
            $pub = "$($a.Publisher)"
            if ($pub.Length -gt 22) { $pub = $pub.Substring(0, 19) + '...' }
            $menuItems += @{ Label = ("{0}. {1,-42} {2} {3}{4}" -f $i, $nm, $sz, $pub, $broken); Color = 'White'; Tag = $a; Checked = $false }
        }
        # Modus direkt als Button in der Auswahlliste (wie Extension-Flow)
        $msActions = @(
            @{ Label = 'Silent versuchen'; Tag = 'silent'; Color = 'Green' }
            @{ Label = 'Normal';          Tag = 'normal'; Color = 'Yellow' }
            @{ Label = 'Abbrechen';       Tag = 'back';   Color = 'DarkGray' }
        )
        $res = Show-SysPilotMultiSelectMenu -Items $menuItems -Title "Programme waehlen ($($list.Count))" -Actions $msActions -Footer 'Klick = Haken, 1/2 = Modus, Enter = silent, Esc = zurueck'
        if ($null -eq $res -or $res.Action -eq 'back') { continue }
        $targets = @($res.Selected)
        if ($targets.Count -eq 0) { continue }
        $effMode = if ($res.Action) { $res.Action } else { 'silent' }
        Write-Host ""
        Write-Host "  Ausgewaehlt: $($targets.Count) Programm(e), Modus: $effMode" -ForegroundColor Cyan
        foreach ($t in $targets) { Write-Host "    - $($t.Name)" -ForegroundColor DarkGray }
        # Optional: Restore Point (Ja/Nein ist bereits klickbar)
        $wantRp = Confirm-SysPilot "Vorher Wiederherstellungspunkt erstellen? (empfohlen bei Batch)"
        if ($wantRp) { New-SysPilotRestorePoint | Out-Null }
        $ok = 0; $fail = 0; $reboot = $false
        foreach ($t in $targets) {
            $r = Invoke-SysPilotProgramUninstall -App $t -Mode $effMode
            if ($r.Success) { $ok++ } else { $fail++ }
            if ($r.RebootRequired) { $reboot = $true }
        }
        Write-Host ""
        Write-Host "  Fertig: $ok erfolgreich, $fail fehlgeschlagen." -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Yellow' })
        if ($reboot) { Write-Host "  Neustart erforderlich fuer vollstaendige Deinstallation." -ForegroundColor Yellow }
        Write-SysPilotLog "CleanSweep Batch: $ok ok / $fail fail von $($targets.Count)"
        Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
        return
    }
}

function Show-SysPilotAppxManager {
    <# Windows-Apps (AppX/MSIX) verwalten. #>
    $isAdmin = Test-SysPilotAdmin
    $allScope = $isAdmin -and (Confirm-SysPilot "Apps fuer ALLE Nutzer listen (Admin)? Sonst nur aktueller Nutzer.")
    $apps = @(Get-SysPilotAppxInventory -AllUsers:$allScope)
    # Filter: keine Frameworks/Ressourcen standardmaessig
    $apps = @($apps | Where-Object { -not $_.IsFramework -and -not $_.IsResourcePackage })
    if ($apps.Count -eq 0) {
        Write-Host "  Keine Windows-Apps gefunden." -ForegroundColor Green
        Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
        return
    }
    Write-SysPilotHeader "CleanSweep: Windows-Apps ($($apps.Count) Pakete)"
    Write-Host "  Tip: System-kritische Apps (NonRemovable) sind markiert - Vorsicht!" -ForegroundColor DarkGray
    $filter = ''
    while ($true) {
        $list = @($apps | Where-Object {
            -not $filter -or (Get-SysPilotAppxDisplayName -Pkg $_) -like "*$filter*" -or $_.Name -like "*$filter*"
        } | Sort-Object Name)
        $nav = @(
            @{ Label = "Apps auswaehlen ($($list.Count) Pakete)"; Color = 'White'; Tag = 'pick' }
            @{ Label = "Filter aendern (aktuell: $(if ($filter) { $filter } else { 'keiner' }))"; Color = 'Cyan'; Tag = 'filter' }
            @{ Label = 'Provisionierte Apps (fuer neue Nutzer)'; Color = 'Yellow'; Tag = 'prov' }
            @{ Label = 'Abbrechen'; Color = 'DarkGray'; Tag = 'back' }
        )
        $act = Show-SysPilotArrowMenu -Items $nav -Title "CleanSweep - Windows-Apps" -Footer 'Pfeiltasten/Klick, Enter = auswaehlen, Esc = zurueck'
        if ($null -eq $act -or $act -eq 'back') { return }
        if ($act -eq 'filter') {
            $filter = Read-SysPilotInput "Suchbegriff (leer = alle)"
            continue
        }
        if ($act -eq 'prov') {
            $prov = @(Get-SysPilotProvisionedApps)
            if ($prov.Count -eq 0) { Write-Host "  Keine provisionierten Pakete." -ForegroundColor Green; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null; continue }
            $pm = @()
            $j = 0
            foreach ($pv in $prov) {
                $j++
                $pn = "$($pv.Name)"
                if ($pn.Length -gt 60) { $pn = $pn.Substring(0, 57) + '...' }
                $pm += @{ Label = ("{0}. {1,-62} {2}" -f $j, $pn, $pv.Version); Color = 'White'; Tag = $pv; Checked = $false }
            }
            $pActions = @(
                @{ Label = 'Entfernen'; Tag = 'remove'; Color = 'Green' }
                @{ Label = 'Abbrechen'; Tag = 'back';   Color = 'DarkGray' }
            )
            $pres = Show-SysPilotMultiSelectMenu -Items $pm -Title "Provisionierte Apps ($($prov.Count))" -Actions $pActions -Footer 'Klick = Haken, 1 = entfernen, Enter = entfernen, Esc = zurueck'
            if ($null -eq $pres -or $pres.Action -eq 'back') { continue }
            $ppicked = @($pres.Selected)
            if ($ppicked.Count -eq 0) { continue }
            $pok = 0
            foreach ($pv in $ppicked) { if (Remove-SysPilotProvisionedApp -Prov $pv) { $pok++ } }
            Write-Host "  [$pok/$($ppicked.Count)] provisionierte Pakete entfernt." -ForegroundColor Green
            Write-SysPilotLog "Provisionierte AppX entfernt: $pok von $($ppicked.Count)"
            Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            continue
        }
        $menuItems = @()
        $i = 0
        foreach ($a in $list) {
            $i++
            $disp = Get-SysPilotAppxDisplayName -Pkg $a
            if ($disp.Length -gt 55) { $disp = $disp.Substring(0, 52) + '...' }
            $flag = if ($a.NonRemovable) { ' [SYSTEM]' } elseif ($a.SignatureKind -eq 'Store') { ' [Store]' } else { '' }
            $menuItems += @{ Label = ("{0}. {1,-57} {2}{3}" -f $i, $disp, $a.Version, $flag); Color = $(if ($a.NonRemovable) { 'DarkGray' } else { 'White' }); Tag = $a; Checked = $false }
        }
        $msActions = @(
            @{ Label = 'Ausgewaehlte entfernen'; Tag = 'remove'; Color = 'Green' }
            @{ Label = 'Abbrechen';             Tag = 'back';   Color = 'DarkGray' }
        )
        $res = Show-SysPilotMultiSelectMenu -Items $menuItems -Title "Windows-Apps waehlen ($($list.Count))" -Actions $msActions -Footer 'Klick = Haken, 1 = entfernen, Enter = entfernen, Esc = zurueck'
        if ($null -eq $res -or $res.Action -eq 'back') { continue }
        $chosen = @($res.Selected)
        if ($chosen.Count -eq 0) { continue }
        $sysCount = @($chosen | Where-Object { $_.NonRemovable }).Count
        if ($sysCount -gt 0) {
            Write-Host "  ACHTUNG: $sysCount der ausgewaehlten Apps sind als NonRemovable markiert (System-komponenten)." -ForegroundColor Red
            if (-not (Confirm-SysPilot "Trotzdem fortfahren?")) { continue }
        }
        $ok = 0
        foreach ($c in $chosen) {
            if (Remove-SysPilotAppxPackage -Pkg $c -AllUsers:$allScope) { $ok++ }
        }
        Write-Host "  [$ok/$($chosen.Count)] Windows-Apps entfernt." -ForegroundColor Green
        Write-SysPilotLog "AppX-Bereinigung: $ok von $($chosen.Count)"
        Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
        return
    }
}

function Show-SysPilotLeftoverManager {
    <# Standalone-Leftover-Scan: Programmname eingeben -> Reste suchen. #>
    $apps = @(Get-SysPilotProgramInventory)
    Write-SysPilotHeader "CleanSweep: Reste-Scanner"
    Write-Host "  Scannt nach Dateien, Registry-Eintraegen, Autostarts, Diensten," -ForegroundColor DarkGray
    Write-Host "  Aufgaben und Verknuepfungen - bewertet nach Sicherheit (Score)." -ForegroundColor DarkGray
    $name = Read-SysPilotInput "Name des (bereits deinstallierten) Programms"
    if (-not $name) { return }
    # Versuche passenden Eintrag in Inventory (fuer InstallLocation etc.)
    $app = $apps | Where-Object { $_.Name -like "*$name*" } | Select-Object -First 1
    if (-not $app) {
        $app = [PSCustomObject]@{ Name=$name; Publisher=''; InstallLocation=$null; UninstallKey=$null }
    }
    Write-Host ""
    Write-Host "  Scanne nach '$($app.Name)' ..." -ForegroundColor Cyan
    # Flow uenimmt Scan + Anzeige + Auswahl + Entfernung in einem
    Show-SysPilotLeftoverFlow -App $app -ForceShow
}

function Show-SysPilotOrphanManager {
    <# Findet Programm-Ordner ohne Uninstall-Eintrag -> Force-Uninstall. #>
    Write-Host "  Scanne Installationsordner nach verwaisten Programmen ..." -ForegroundColor Cyan
    $orphans = @(Get-SysPilotOrphanPrograms)
    if ($orphans.Count -eq 0) {
        Write-Host "  Keine verwaisten Programm-Ordner gefunden." -ForegroundColor Green
        Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
        return
    }
    Write-Host ""
    Write-Host "  Verwaiste Programme ($($orphans.Count)) - kein Uninstall-Eintrag:" -ForegroundColor Yellow
    $menuItems = @()
    $i = 0
    $list = @($orphans | Sort-Object Root, Name)
    foreach ($o in $list) {
        $i++
        $p = "$($o.Path)"
        if ($p.Length -gt 80) { $p = $p.Substring(0, 77) + '...' }
        $menuItems += @{ Label = ("{0}. {1,-40} {2}" -f $i, $o.Name, $p); Color = 'White'; Tag = $o; Checked = $false }
    }
    $sel = Show-SysPilotArrowMenu -Items $menuItems -Title "Verwaiste Programme - Force-Uninstall" -Footer 'Klick/Pfeile+Enter = auswaehlen, Esc = zurueck'
    if ($null -eq $sel) { return }
    Invoke-SysPilotForceUninstall -Path $sel.Path
}

function Show-SysPilotBrokenEntriesManager {
    <# Defekte Uninstall-Eintraege: fehlender Exe-Pfad oder kein UninstallString. #>
    Write-Host "  Pruefe Uninstall-Eintraege auf Defekte ..." -ForegroundColor Cyan
    $broken = @(Get-SysPilotBrokenUninstallEntries)
    if ($broken.Count -eq 0) {
        Write-Host "  Alle Uninstall-Eintraege sind in Ordnung." -ForegroundColor Green
        Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
        return
    }
    Write-Host ""
    Write-Host "  Defekte Eintraege ($($broken.Count)):" -ForegroundColor Yellow
    $menuItems = @()
    $i = 0
    foreach ($b in $broken) {
        $i++
        $pr = "$($b.Problem)"
        if ($pr.Length -gt 45) { $pr = $pr.Substring(0, 42) + '...' }
        $nm = "$($b.Name)"
        if ($nm.Length -gt 40) { $nm = $nm.Substring(0, 37) + '...' }
        $menuItems += @{ Label = ("{0}. {1,-42} {2}" -f $i, $nm, $pr); Color = 'White'; Tag = $b; Checked = $false }
    }
    $sel = Show-SysPilotArrowMenu -Items $menuItems -Title "Defekte Deinstallationseintraege" -Footer 'Klick/Pfeile+Enter = auswaehlen, Esc = zurueck'
    if ($null -eq $sel) { return }
    $b = $sel
    Write-Host ""
    Write-Host "  $($b.Name) - Problem: $($b.Problem)" -ForegroundColor Yellow
    $actItems = @(
        @{ Label = 'Registry-Eintrag entfernen (mit .reg-Backup)'; Color = 'Yellow'; Tag = 'reg' }
        @{ Label = 'Force-Uninstall (Install-Ordner + Reste)';    Color = 'Red';    Tag = 'force' }
        @{ Label = 'Abbrechen';                                  Color = 'DarkGray'; Tag = 'back' }
    )
    $act = Show-SysPilotArrowMenu -Items $actItems -Title "Aktion fuer '$($b.Name)'" -Footer 'Klick/Pfeile+Enter = auswaehlen, Esc = abbrechen'
    if ($null -eq $act -or $act -eq 'back') { return }
    if ($act -eq 'reg') {
        if (Confirm-SysPilot "Registry-Eintrag fuer '$($b.Name)' entfernen? (wird vorher exportiert)") {
            $bak = Join-Path (Get-SysPilotBackupDir) 'leftovers'
            if (-not (Test-Path $bak)) { New-Item -ItemType Directory -Force -Path $bak | Out-Null }
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $regName = $b.RegPath -replace '^HKCU:\\','HKEY_CURRENT_USER\\' -replace '^HKLM:\\','HKEY_LOCAL_MACHINE\\'
            $safe = ($b.RegPath -replace '[\\/:*?"<>|]','_')
            try {
                & reg.exe export "$regName" "$bak\$stamp-$safe.reg" /y 2>$null | Out-Null
            } catch { }
            Remove-Item -Path $b.RegPath -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "  [OK] Eintrag entfernt (Backup in backup\leftovers\)." -ForegroundColor Green
            Write-SysPilotLog "Defekter Uninstall-Eintrag entfernt: $($b.Name) ($($b.RegPath))"
        }
    } elseif ($act -eq 'force') {
        if ($b.InstallLocation) {
            Invoke-SysPilotForceUninstall -Path $b.InstallLocation
        } else {
            Write-Host "  Kein InstallLocation bekannt - Pfad manuell unter 'Force-Uninstall' angeben." -ForegroundColor Yellow
        }
    }
}

function Show-SysPilotWindowsUpdateManager {
    <# Windows-Updates auflisten + optional deinstallieren. #>
    Write-Host "  Lade Windows-Updates ..." -ForegroundColor Cyan
    $updates = @(Get-SysPilotWindowsUpdates)
    if ($updates.Count -eq 0) {
        Write-Host "  Keine Updates gefunden." -ForegroundColor Green
        Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
        return
    }
    Write-SysPilotHeader "CleanSweep: Windows-Updates ($($updates.Count))"
    Write-Host "  Hinweis: NurUpdates, die Windows zum Entfernen freigibt, lassen sich deinstallieren." -ForegroundColor DarkGray
    $menuItems = @()
    $i = 0
    foreach ($u in ($updates | Select-Object -First 100)) {
        $i++
        $d = if ($u.InstalledOn -is [datetime]) { $u.InstalledOn.ToString('yyyy-MM-dd') } elseif ($u.InstalledOn) { "$($u.InstalledOn)".Substring(0,10) } else { '????-??-??' }
        $desc = "$($u.Description)"
        if ($desc.Length -gt 45) { $desc = $desc.Substring(0, 42) + '...' }
        $menuItems += @{ Label = ("{0}. {1,-12} {2,-11} {3}" -f $i, $u.HotFixID, $d, $desc); Color = 'White'; Tag = $u; Checked = $false }
    }
    if ($updates.Count -gt 100) { Write-Host "  ... nur die ersten 100 werden angezeigt." -ForegroundColor DarkGray }
    $picked = Show-SysPilotMultiSelectMenu -Items $menuItems -Title "Windows-Updates deinstallieren" -Footer 'Klick/Leertaste = Haken, A = alle, Enter = weiter, Esc = zurueck'
    if ($null -eq $picked -or $picked.Count -eq 0) { return }
    foreach ($u in $picked) {
        if (Confirm-SysPilot "Update $($u.HotFixID) ($($u.Description)) deinstallieren?") {
            Remove-SysPilotWindowsUpdate -KB $u.KB | Out-Null
        }
    }
    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
}

function Show-SysPilotUninstallMenu {
    <# Hauptmenue CleanSweep. #>
    while ($true) {
        Write-SysPilotHeader "CleanSweep - Deinstallations-Center"
        Write-Host "  Unabhaengige SysPilot-Implementierung: Programme, Windows-Apps," -ForegroundColor DarkGray
        Write-Host "  Browser-Erweiterungen, Reste, verwaiste Programme, Updates." -ForegroundColor DarkGray
        Write-Host ""
        $items = @(
            @{ Label = 'Programme deinstallieren (Desktop, silent/normal, Batch)'; Color = 'White';  Tag = 'prog' }
            @{ Label = 'Windows-Apps (Store/UWP/AppX) entfernen';                 Color = 'Cyan';   Tag = 'appx' }
            @{ Label = 'Browser-Erweiterungen entfernen (Chrome/Edge/Brave/Firefox/Opera)'; Color = 'Yellow'; Tag = 'ext' }
            @{ Label = 'Extension-Policy-Bloecke verwalten (Browser "verwaltet"?)'; Color = 'Yellow'; Tag = 'extpol' }
            @{ Label = 'Reste-Scanner (beliebiges Programm nach Ueberresten suchen)'; Color = 'Magenta'; Tag = 'left' }
            @{ Label = "Reste Auto-Clean: $(if ((Get-SysPilotConfig).CleanSweep.AutoLeftoverClean -eq $true) { 'AN' } else { 'aus' }) - nach Deinstallation alle Reste automatisch loeschen"; Color = 'Magenta'; Tag = 'autol' }
            @{ Label = 'Verwaiste Programme finden (Ordner ohne Uninstall-Eintrag)'; Color = 'Yellow'; Tag = 'orph' }
            @{ Label = 'Defekte Deinstallationseintraege reparieren';            Color = 'Red';    Tag = 'broken' }
            @{ Label = 'Force-Uninstall (Pfad/Ordner manuell)';                  Color = 'Red';    Tag = 'force' }
            @{ Label = 'Windows-Updates deinstallieren (KB-Listen)';             Color = 'DarkGray'; Tag = 'wupdate' }
            @{ Label = 'Wiederherstellungspunkt erstellen';                      Color = 'Green';  Tag = 'restore' }
            @{ Label = 'Zurueck';                                                Color = 'DarkGray'; Tag = 'back' }
        )
        $sel = Show-SysPilotArrowMenu -Items $items -Title "CleanSweep - Was moechtest du tun?" -Footer 'Pfeiltasten, Enter = auswaehlen, Esc = zurueck'
        if ($null -eq $sel -or $sel -eq 'back') { return }
        switch ($sel) {
            'prog'    { Show-SysPilotUninstallProgramsMenu }
            'appx'    { Show-SysPilotAppxManager }
            'ext'     { Show-SysPilotExtensionRemoval }
            'extpol'  { Show-SysPilotExtensionPolicyManager }
            'left'    { Show-SysPilotLeftoverManager }
            'autol'   {
                $cur = ((Get-SysPilotConfig).CleanSweep.AutoLeftoverClean -eq $true)
                try {
                    Set-SysPilotConfigValue -Section 'CleanSweep' -Key 'AutoLeftoverClean' -Value (-not $cur)
                } catch {
                    Write-Host "  [!] config.json nicht beschreibbar (Program Files braucht Admin): $($_.Exception.Message)" -ForegroundColor Yellow
                    Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
                    continue
                }
                $new = -not $cur
                Write-Host ""
                Write-Host "  Reste Auto-Clean: $(if ($new) { 'AN - alle Reste werden nach der Deinstallation automatisch entfernt' } else { 'AUS - Reste werden zur Auswahl angezeigt (alle vorab markiert)' })" -ForegroundColor Cyan
                Write-Host "  (Reversibel: Dateien->Papierkorb, Registry->Backup)" -ForegroundColor DarkGray
                Read-SysPilotChoice 'Weiter mit Enter' | Out-Null
            }
            'orph'    { Show-SysPilotOrphanManager }
            'broken'  { Show-SysPilotBrokenEntriesManager }
            'force'   {
                $p = Read-SysPilotInput "Pfad zum Programm/Ordner (z.B. C:\Program Files\X)" -BrowseFolder
                if ($p) { Invoke-SysPilotForceUninstall -Path $p }
            }
            'wupdate' { Show-SysPilotWindowsUpdateManager }
            'restore' { New-SysPilotRestorePoint | Out-Null; Read-SysPilotChoice 'Weiter mit Enter' | Out-Null }
        }
    }
}

Export-ModuleMember -Function `
    Get-SysPilotUninstallRegistryViews, Get-SysPilotProgramInventory, `
    Get-SysPilotAppxInventory, Get-SysPilotAppxDisplayName, Remove-SysPilotAppxPackage, `
    Get-SysPilotProvisionedApps, Remove-SysPilotProvisionedApp, `
    Split-SysPilotUninstallString, Get-SysPilotSilentArgs, Test-SysPilotExeExists, `
    Invoke-SysPilotProgramUninstall, `
    Get-SysPilotNameTokens, Find-SysPilotProgramLeftovers, Remove-SysPilotLeftoverItem, `
    Show-SysPilotLeftoverFlow, `
    Get-SysPilotBrowserExtensionInventory, Backup-SysPilotFile, `
    Remove-SysPilotBrowserExtension, Show-SysPilotExtensionRemoval, `
    Get-SysPilotBrowserPolicyPath, Test-SysPilotBrowserProfileSignedIn, `
    Set-SysPilotExtensionPolicyBlock, Remove-SysPilotExtensionPolicyBlock, `
    Get-SysPilotBrowserExtensionPolicy, Show-SysPilotExtensionPolicyManager, `
    Test-SysPilotAiBrowser, Get-SysPilotBrowserProcesses, `
    Get-SysPilotBrowserExePath, Open-SysPilotExtensionPages, `
    Get-SysPilotOrphanPrograms, Get-SysPilotBrokenUninstallEntries, `
    Invoke-SysPilotForceUninstall, `
    Get-SysPilotWindowsUpdates, Remove-SysPilotWindowsUpdate, `
    New-SysPilotRestorePoint, Show-SysPilotUninstallMenu
