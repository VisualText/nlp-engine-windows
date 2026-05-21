@echo off
rem Thin shim that delegates to test-compile-roundtrip.ps1.
rem Usage: scripts\test-compile-roundtrip.bat [analyzer-dir] [input-file]
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0test-compile-roundtrip.ps1" %*
exit /b %ERRORLEVEL%
