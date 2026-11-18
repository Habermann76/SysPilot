@echo off
setlocal
set "ROOT=C:\Users\haber\SysPilot"
set "OUT=%ROOT%\installer-output\SysPilot-0.9.4.5-portable.zip"
set "STAGE=%TEMP%\SysPilot-portable-0.9.4.5"

if exist "%STAGE%" rmdir /s /q "%STAGE%"
mkdir "%STAGE%"
mkdir "%STAGE%\modules"
mkdir "%STAGE%\scripts"

copy /y "%ROOT%\SysPilot.ps1" "%STAGE%\" >nul
copy /y "%ROOT%\SysPilot-GUI.ps1" "%STAGE%\" >nul
copy /y "%ROOT%\version.txt" "%STAGE%\" >nul
copy /y "%ROOT%\config.json" "%STAGE%\" >nul
copy /y "%ROOT%\README.md" "%STAGE%\" >nul
copy /y "%ROOT%\INSTALL.md" "%STAGE%\" >nul
copy /y "%ROOT%\DEBUG.md" "%STAGE%\" >nul
copy /y "%ROOT%\ROADMAP.md" "%STAGE%\" >nul
copy /y "%ROOT%\LICENSE" "%STAGE%\" >nul
copy /y "%ROOT%\modules\*.psm1" "%STAGE%\modules\" >nul
copy /y "%ROOT%\scripts\*.ps1" "%STAGE%\scripts\" >nul

if exist "%OUT%" del /f /q "%OUT%"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Compress-Archive -Path '%STAGE%\*' -DestinationPath '%OUT%' -Force"
if errorlevel 1 exit /b 1
echo Fertig: Portable ZIP erstellt
endlocal