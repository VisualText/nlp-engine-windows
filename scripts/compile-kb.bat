@echo off
rem Thin shim that delegates to compile-kb.ps1.
rem Usage: scripts\compile-kb.bat <analyzer-dir> <input-file>
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0compile-kb.ps1" %*
exit /b %ERRORLEVEL%
