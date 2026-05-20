@echo off
rem Thin shim that delegates to compile-analyzer.ps1.
rem Usage: scripts\compile-analyzer.bat <analyzer-dir> <input-file>
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0compile-analyzer.ps1" %*
exit /b %ERRORLEVEL%
