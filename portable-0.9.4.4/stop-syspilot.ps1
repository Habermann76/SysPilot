# SysPilot: laufende SysPilot-Prozesse beenden (wird vom Installer vor Updates/Deinstallation benutzt)
Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'SysPilot(-GUI)?\.ps1' -and $_.CommandLine -notmatch 'stop-syspilot' -and $_.ProcessId -ne $PID } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
