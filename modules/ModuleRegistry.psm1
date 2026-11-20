# SysPilot - Module Registry: Discovery & Contract
#Requires -Version 5.1

# Standard module contract:
# each module exports a static ModuleInfo object and dynamic tool lists.
# Modules live in modules/*.psm1 and register themselves below.

function Get-SysPilotModuleInfo {
    return [PSCustomObject]@{
        Name='ModuleRegistry'; Version='0.9.4.2';
        Description='Module discovery and registration'; HasGUI=$false; IsConsoleOnly=$true
    }
}

function Get-SysPilotModules {
    return @(
        @{ Name='Common'; File='Common.psm1'; Category='Core'; Description='Shared helpers (admin, config, logging, menu)' };
        @{ Name='Checkup'; File='Checkup.psm1'; Category='Diagnose & Reparatur'; Description='Automatic Checkup (15 Bereiche, ehrlich)' };
        @{ Name='Toolbox'; File='Toolbox.psm1'; Category='Tools'; Description='Toolbox (27 Werkzeuge, austauschbar)' };
        @{ Name='SmartHealth'; File='SmartHealthCheck.psm1'; Category='Performance'; Description='CPU/RAM/Disk/Temp monitoring + dashboard' };
        @{ Name='AdvancedDNS'; File='AdvancedDnsManager.psm1'; Category='Netzwerk'; Description='Advanced DNS Manager (GUI + Konsole)' };
        @{ Name='NetworkRepair'; File='NetworkRepair.psm1'; Category='Netzwerk'; Description='NETREPAIR + Repair-Distribution' };
        @{ Name='AutoOptimize'; File='AutoOptimize.psm1'; Category='Optimization'; Description='Auto-Optimierung: Backup, Dienste, Features, Tweaks' };
        @{ Name='Temperature'; File='Temperature.psm1'; Category='Performance'; Description='Temperatur-Sensor + Hitzeschutz' };
        @{ Name='Guardian'; File='Guardian.psm1'; Category='Sonstiges'; Description='SysPilot self-monitoring (Tray-Watcher)' }
    )
}

Export-ModuleMember -Function Get-SysPilotModuleInfo, Get-SysPilotModules
