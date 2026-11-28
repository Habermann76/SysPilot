# console-debug.ps1 - Live-Debugging fuer SysPilot-Konsolen (ConPTY/Windows Terminal)
# ASCII-only. Aufruf: powershell -STA -File console-debug.ps1 -Action <action> [-TargetPid N] [-Hwnd N] [-Rows "a-b"]
# Actions:
#   buftext   - Screen-Buffer einer fremden Konsole lesen (AttachConsole+CONOUT$)
#   wins      - Alle sichtbaren WT-/Conhost-Fenster auflisten (Titel, RECT, minimiert?)
#   restore   - Fenster aus Minimierung holen + in den Vordergrund
#   shotocr   - PrintWindow-Screenshot -> Windows.Media.Ocr -> Text (was der User sieht)
#   procs     - SysPilot-relevante powershell/pwsh-Prozesse mit Startzeit+Cmdline
# Hinweis: WriteConsoleInput-Injection erreicht ConPTY-Apps NICHT zuverlaessig -
# fuer Input-Tests echte Maus (SetCursorPos erzeugt MOUSE_MOVEs) oder Tastatur.
param(
    [Parameter(Mandatory)][ValidateSet('buftext','wins','restore','shotocr','procs')][string]$Action,
    [int]$TargetPid = 0,
    [int]$Hwnd = 0,
    [string]$Rows = '0-29',
    [string]$Out = "$env:TEMP\console-debug.png"
)
$ErrorActionPreference = 'Continue'

if ($Action -eq 'procs') {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
        Where-Object { $_.CommandLine -match 'SysPilot|YesNo|probe|fix_test' } |
        Select-Object ProcessId, Name, CreationDate,
            @{n='Cmd';e={$_.CommandLine.Substring(0,[Math]::Min(140,$_.CommandLine.Length))}} |
        Format-List
    return
}

if ($Action -eq 'wins') {
    Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class WE {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll", public: true)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    public struct RECT { public int Left, Top, Right, Bottom; }
}
"@
    $cb = [WE+EnumProc]{ param($h,$l)
        $sb = New-Object System.Text.StringBuilder 256
        [void][WE]::GetWindowText($h, $sb, 256)
        $t = $sb.ToString()
        if ($t -and [WE]::IsWindowVisible($h)) {
            $r = New-Object WE+RECT; [void][WE]::GetWindowRect($h,[ref]$r)
            $min = if ([WE]::IsIconic($h)) { 'MIN' } else { '   ' }
            "{0} HWND={1} '{2}' RECT={3},{4} {5}x{6}" -f $min, $h, $t, $r.Left, $r.Top, ($r.Right-$r.Left), ($r.Bottom-$r.Top)
        }
        return $true
    }
    [void][WE]::EnumWindows($cb, [IntPtr]::Zero)
    return
}

if ($Action -eq 'restore') {
    if ($Hwnd -eq 0) { "-Hwnd noetig (siehe -Action wins)"; return }
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class RS {
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    public struct RECT { public int Left, Top, Right, Bottom; }
}
"@
    $h = [IntPtr]$Hwnd
    [void][RS]::ShowWindow($h, 9)
    Start-Sleep -Milliseconds 400
    [void][RS]::SetForegroundWindow($h)
    Start-Sleep -Milliseconds 400
    $r = New-Object RS+RECT; [void][RS]::GetWindowRect($h,[ref]$r)
    "restored: RECT=$($r.Left),$($r.Top) $($r.Right-$r.Left)x$($r.Bottom-$r.Top)"
    return
}

if ($Action -eq 'shotocr') {
    if ($Hwnd -eq 0) { "-Hwnd noetig"; return }
    Add-Type -AssemblyName System.Drawing
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class PW {
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
}
"@
    $h = [IntPtr]$Hwnd
    $r = New-Object PW+RECT; [void][PW]::GetWindowRect($h,[ref]$r)
    $w = $r.Right-$r.Left; $hh = $r.Bottom-$r.Top
    if ($w -le 0 -or $hh -le 0) { "Fenster minimiert/ungueltig - erst -Action restore"; return }
    $bmp = New-Object System.Drawing.Bitmap $w, $hh
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc()
    [void][PW]::PrintWindow($h, $hdc, 2)
    $g.ReleaseHdc($hdc); $g.Dispose()
    $bmp.Save($Out)
    "saved ${w}x${hh} -> $Out"
    # OCR (WinRT, -STA noetig)
    [void][Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType=WindowsRuntime]
    [void][Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType=WindowsRuntime]
    [void][Windows.Storage.StorageFile, Windows.Foundation, ContentType=WindowsRuntime]
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
    function Await($op, $type) { $m = $asTaskGeneric.MakeGenericMethod($type); $t = $m.Invoke($null, @($op)); $t.Wait(); $t.Result }
    $file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($Out)) ([Windows.Storage.StorageFile])
    $stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    $dec = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $sbmp = Await ($dec.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
    $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
    $result = Await ($engine.RecognizeAsync($sbmp)) ([Windows.Media.Ocr.OcrResult])
    $result.Text
    return
}

if ($Action -eq 'buftext') {
    if ($TargetPid -eq 0) { "-TargetPid noetig (siehe -Action procs)"; return }
    $rb = $Rows -split '-' ; $rowFrom = [int]$rb[0]; $rowTo = [int]$rb[1]
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class RdBuf {
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr sa, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetConsoleScreenBufferInfo(IntPtr h, out CSBI i);
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool ReadConsoleOutputCharacter(IntPtr h, [Out] char[] buf, uint len, COORD coord, out uint read);
    [StructLayout(LayoutKind.Sequential)] public struct COORD { public short X; public short Y; }
    [StructLayout(LayoutKind.Sequential)] public struct SMALL_RECT { public short Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct CSBI {
        public COORD dwSize; public COORD dwCursorPosition; public short wAttributes;
        public SMALL_RECT srWindow; public COORD dwMaximumWindowSize;
    }
}
"@
    [void][RdBuf]::FreeConsole()
    if (-not [RdBuf]::AttachConsole([uint32]$TargetPid)) { "ATTACH FAIL err=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())"; return }
    Start-Sleep -Milliseconds 300
    $h = [RdBuf]::CreateFile('CONOUT$', ([uint32]3221225472), 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
    $i = New-Object RdBuf+CSBI
    [void][RdBuf]::GetConsoleScreenBufferInfo($h, [ref]$i)
    "bufSize=$($i.dwSize.X)x$($i.dwSize.Y) cursor=$($i.dwCursorPosition.X),$($i.dwCursorPosition.Y) win=$($i.srWindow.Top)-$($i.srWindow.Bottom)"
    for ($row = $rowFrom; $row -le $rowTo; $row++) {
        $chars = New-Object char[] 120
        $coord = New-Object RdBuf+COORD; $coord.X = 0; $coord.Y = [int16]$row
        $nr = 0
        [void][RdBuf]::ReadConsoleOutputCharacter($h, $chars, 120, $coord, [ref]$nr)
        "r{0,2}|{1}|" -f $row, ((-join $chars).TrimEnd())
    }
    [void][RdBuf]::FreeConsole()
}
