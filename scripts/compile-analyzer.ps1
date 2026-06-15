#requires -Version 5.1
<#
.SYNOPSIS
  Compile an NLP++ analyzer into the native shared libraries that the
  -COMPILED engine LoadLibrary's at runtime.

.PARAMETER AnalyzerDir
  Path to the analyzer directory (e.g. data\rfb).

.PARAMETER InputFile
  Path to an input text file the engine will run over to drive the compile.

.PARAMETER KbOnly
  If set, build only the KB (legacy behaviour) — produces just bin\kb.dll
  and bin\kbu.dll. Without it (default), the full analyzer is compiled
  and bin\run.dll / bin\runu.dll are produced too.

.PARAMETER AnalyzerOnly
  If set, build only the analyzer rules (-COMPILEANA) — produces just
  bin\run.dll and bin\runu.dll, leaving any existing bin\kb.dll in place.
  Use when only the rules changed and the KB is already compiled. Mutually
  exclusive with -KbOnly.

.EXAMPLE
  scripts\compile-analyzer.ps1 data\rfb data\rfb\input\text.txt
  scripts\compile-analyzer.ps1 -KbOnly data\rfb data\rfb\input\text.txt
  scripts\compile-analyzer.ps1 -AnalyzerOnly data\rfb data\rfb\input\text.txt

.NOTES
  Requires Visual Studio 2022 (or Build Tools) with the "Desktop development
  with C++" workload, and CMake >= 3.16. The first invocation generates ICU
  import libraries (icudt78.lib, icuin78.lib, icuuc78.lib) from the bundled
  DLLs using dumpbin + lib.exe; subsequent runs reuse them.

  Output (default, full-analyzer mode):
    <AnalyzerDir>\bin\run.dll
    <AnalyzerDir>\bin\runu.dll
    <AnalyzerDir>\bin\kb.dll
    <AnalyzerDir>\bin\kbu.dll

  Output (-KbOnly):
    <AnalyzerDir>\bin\kb.dll
    <AnalyzerDir>\bin\kbu.dll

  Output (-AnalyzerOnly):
    <AnalyzerDir>\bin\run.dll
    <AnalyzerDir>\bin\runu.dll
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)] [string] $AnalyzerDir,
    [Parameter(Mandatory = $true, Position = 1)] [string] $InputFile,
    [switch] $KbOnly,
    [switch] $AnalyzerOnly
)

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$AnalyzerDir = (Resolve-Path $AnalyzerDir).Path

$NlpExe = Join-Path $RepoRoot 'nlp.exe'
$CompileLibs = Join-Path $RepoRoot 'compile-libs'

if (-not (Test-Path $NlpExe)) {
    throw "nlp.exe not found at $NlpExe"
}
if (-not (Test-Path (Join-Path $CompileLibs 'include')) -or -not (Test-Path (Join-Path $CompileLibs 'lib'))) {
    throw "compile-libs not found at $CompileLibs (expected include\ and lib\). Re-run the GitHub workflow once upstream attaches nlpengine-compile-libs.zip to the release."
}
if (-not (Test-Path $InputFile)) {
    throw "Input file not found: $InputFile"
}
$InputFile = (Resolve-Path $InputFile).Path

if ($KbOnly -and $AnalyzerOnly) {
    throw "Specify at most one of -KbOnly or -AnalyzerOnly."
}
if ($KbOnly) {
    $CompileFlag = '-COMPILEKB'
    $TargetName  = 'nlp_kb'
    $SrcGlobDesc = 'kb'
} elseif ($AnalyzerOnly) {
    $CompileFlag = '-COMPILEANA'
    $TargetName  = 'nlp_run'
    $SrcGlobDesc = 'run'
} else {
    $CompileFlag = '-COMPILE'
    $TargetName  = 'nlp_analyzer'
    $SrcGlobDesc = 'run + kb'
}

function Find-VsDevCmd {
    $programFilesX86 = ${env:ProgramFiles(x86)}
    if (-not $programFilesX86) { $programFilesX86 = 'C:\Program Files (x86)' }
    $vswhere = Join-Path $programFilesX86 'Microsoft Visual Studio\Installer\vswhere.exe'

    if (Test-Path $vswhere) {
        $installPath = & $vswhere -latest -prerelease -products '*' -requires 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64' -property installationPath 2>$null
        if ($installPath) {
            $candidate = Join-Path $installPath.Trim() 'Common7\Tools\VsDevCmd.bat'
            if (Test-Path $candidate) { return $candidate }
        }
    }

    $editions  = @('BuildTools', 'Community', 'Professional', 'Enterprise')
    $versions  = @('18', '2022', '2019')
    $baseRoots = @(
        (Join-Path $env:ProgramFiles 'Microsoft Visual Studio'),
        (Join-Path $programFilesX86 'Microsoft Visual Studio')
    )
    foreach ($root in $baseRoots) {
        foreach ($v in $versions) {
            foreach ($ed in $editions) {
                $candidate = Join-Path $root "$v\$ed\Common7\Tools\VsDevCmd.bat"
                if (Test-Path $candidate) { return $candidate }
            }
        }
    }
    throw "Could not find VsDevCmd.bat. Install Visual Studio Build Tools with the 'Desktop development with C++' workload."
}

function Invoke-WithVsDev {
    param(
        [Parameter(Mandatory = $true)] [string] $VsDevCmd,
        [Parameter(Mandatory = $true)] [string] $Command,
        [string] $WorkingDirectory = $RepoRoot
    )
    $full = "call `"$VsDevCmd`" -arch=x64 -host_arch=x64 >nul && $Command"
    Push-Location $WorkingDirectory
    try {
        & cmd.exe /c $full
        if ($LASTEXITCODE -ne 0) {
            throw "Command failed (exit $LASTEXITCODE): $Command"
        }
    } finally {
        Pop-Location
    }
}

function Get-DumpbinExports {
    param(
        [Parameter(Mandatory = $true)] [string] $VsDevCmd,
        [Parameter(Mandatory = $true)] [string] $Dll
    )
    $full = "call `"$VsDevCmd`" -arch=x64 -host_arch=x64 >nul && dumpbin /exports `"$Dll`""
    $output = & cmd.exe /c $full 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "dumpbin failed for $Dll"
    }
    $names = New-Object System.Collections.Generic.List[string]
    $inExports = $false
    foreach ($raw in $output) {
        $line = ($raw -as [string])
        if ($null -eq $line) { continue }
        $trimmed = $line.TrimEnd()
        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            if ($inExports -and $names.Count -gt 0) { break }
            continue
        }
        if (-not $inExports) {
            if ($trimmed -match '^\s+ordinal\b' -and $trimmed -match '\bname\b') {
                $inExports = $true
            }
            continue
        }
        if ($trimmed -match '^\s*\d+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]+\s+(\S+)') {
            $names.Add($matches[1])
        } else {
            break
        }
    }
    return ,$names
}

function Ensure-IcuImportLibs {
    param([Parameter(Mandatory = $true)] [string] $VsDevCmd)

    $libDir = Join-Path $CompileLibs 'lib'
    $targets = @('icudt78', 'icuin78', 'icuuc78')

    foreach ($name in $targets) {
        $outLib = Join-Path $libDir "$name.lib"
        if (Test-Path $outLib) { continue }

        $dll = Join-Path $RepoRoot "$name.dll"
        if (-not (Test-Path $dll)) {
            Write-Warning "$name.dll not found at repo root; skipping import-lib generation for $name."
            continue
        }

        Write-Host "==> Generating $name.lib from $name.dll (one-time)"
        $exports = Get-DumpbinExports -VsDevCmd $VsDevCmd -Dll $dll
        if ($exports.Count -eq 0) {
            throw "Failed to enumerate exports of $name.dll via dumpbin"
        }

        $defFile = Join-Path $libDir "$name.def"
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine("LIBRARY $name")
        [void]$sb.AppendLine('EXPORTS')
        foreach ($e in $exports) { [void]$sb.AppendLine("    $e") }
        [System.IO.File]::WriteAllText($defFile, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))

        Invoke-WithVsDev -VsDevCmd $VsDevCmd -Command "lib /def:`"$defFile`" /machine:X64 /out:`"$outLib`""
    }
}

Write-Host "==> [1/5] Locate Visual Studio (VsDevCmd.bat)"
$VsDevCmd = Find-VsDevCmd
Write-Host "    Using: $VsDevCmd"

# VS 18's VsDevCmd.bat shells out to bare `vswhere.exe` (without an absolute
# path), so the Installer directory must be on PATH for the subshell.
$programFilesX86 = ${env:ProgramFiles(x86)}
if (-not $programFilesX86) { $programFilesX86 = 'C:\Program Files (x86)' }
$VsInstallerDir = Join-Path $programFilesX86 'Microsoft Visual Studio\Installer'
if ((Test-Path (Join-Path $VsInstallerDir 'vswhere.exe')) -and ($env:PATH -notlike "*$VsInstallerDir*")) {
    $env:PATH = "$VsInstallerDir;$env:PATH"
}

Write-Host "==> [2/5] Ensure ICU import libraries exist"
Ensure-IcuImportLibs -VsDevCmd $VsDevCmd

Write-Host "==> [3/5] nlp.exe $CompileFlag  (emits .cpp trees under $AnalyzerDir\{$SrcGlobDesc}\)"
$compileCmd = "`"$NlpExe`" $CompileFlag -ANA `"$AnalyzerDir`" -WORK `"$RepoRoot`" `"$InputFile`""
Invoke-WithVsDev -VsDevCmd $VsDevCmd -Command $compileCmd

$BuildRoot = Join-Path $AnalyzerDir '.nlp-compile'
$SrcDir    = Join-Path $BuildRoot 'src'
$BuildDir  = Join-Path $BuildRoot 'build'
if (Test-Path $BuildRoot) { Remove-Item -Recurse -Force $BuildRoot }
New-Item -ItemType Directory -Path $SrcDir | Out-Null

# Engine-generated .cpp files begin with `#include "StdAfx.h"`. The cmake
# template force-includes this file too via /FI. Provide a minimal stub
# matching what nlp-compile-service ships.
[System.IO.File]::WriteAllText(
    (Join-Path $SrcDir 'StdAfx.h'),
    "#pragma once`n#include <windows.h>`n#include <tchar.h>`n#include `"my_tchar.h`"`n",
    [System.Text.UTF8Encoding]::new($false)
)

# NOTE: the manual kb_setup.cpp shim used to be generated here. Engine
# v3.1.44+ emits a kb_setup wrapper from cc_gen.cpp automatically
# (NLP-ENGINE-495), so the manual shim would now produce a duplicate
# symbol at link time. Dropped.

Write-Host "==> [4/5] Generate CMakeLists.txt"
$cmakeAnalyzer  = $AnalyzerDir       -replace '\\', '/'
$cmakeSrcDir    = $SrcDir            -replace '\\', '/'
$cmakeInclApi   = (Join-Path $CompileLibs 'include\Api')  -replace '\\', '/'
$cmakeInclCs    = (Join-Path $CompileLibs 'include\cs')   -replace '\\', '/'
$cmakeLibDir    = (Join-Path $CompileLibs 'lib')          -replace '\\', '/'

if ($KbOnly) {
    $globExpr = "`"$cmakeAnalyzer/kb/*.cpp`""
} elseif ($AnalyzerOnly) {
    $globExpr = "`"$cmakeAnalyzer/run/*.cpp`""
} else {
    $globExpr = "`"$cmakeAnalyzer/run/*.cpp`" `"$cmakeAnalyzer/kb/*.cpp`""
}

$cmakeText = @"
cmake_minimum_required(VERSION 3.16)
project(${TargetName}_library LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# Drop the .dll into <analyzer-dir>\bin\ — that's what the engine's
# load_compiled() (lite/nlp.cpp:1242) and consh's KB loader
# (cs/libconsh/cg.cpp:168) LoadLibrary at runtime.
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "$cmakeAnalyzer/bin")
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "$cmakeAnalyzer/bin")
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY "$cmakeAnalyzer/bin")
foreach(CFG IN ITEMS DEBUG RELEASE RELWITHDEBINFO MINSIZEREL)
    set(CMAKE_RUNTIME_OUTPUT_DIRECTORY_`${CFG} "$cmakeAnalyzer/bin")
    set(CMAKE_LIBRARY_OUTPUT_DIRECTORY_`${CFG} "$cmakeAnalyzer/bin")
    set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY_`${CFG} "$cmakeAnalyzer/bin")
endforeach()

file(GLOB GENERATED_CPP $globExpr)
if(NOT GENERATED_CPP)
    message(FATAL_ERROR "No generated .cpp files found -- did $CompileFlag succeed?")
endif()

add_library($TargetName SHARED `${GENERATED_CPP})
set_target_properties($TargetName PROPERTIES OUTPUT_NAME "$TargetName")

target_include_directories($TargetName PRIVATE
    "$cmakeSrcDir"
    "$cmakeAnalyzer"
    "$cmakeAnalyzer/run"
    "$cmakeAnalyzer/kb"
    "$cmakeInclApi"
    "$cmakeInclCs"
)

target_link_directories($TargetName PRIVATE "$cmakeLibDir")
target_link_libraries($TargetName PRIVATE
    prim kbm consh words lite
    icuin78 icuuc78 icudt78
)

target_compile_definitions($TargetName PRIVATE _CRT_SECURE_NO_WARNINGS)
if(MSVC)
    target_compile_options($TargetName PRIVATE /wd4005 /FI"StdAfx.h")
endif()
"@

[System.IO.File]::WriteAllText(
    (Join-Path $SrcDir 'CMakeLists.txt'),
    $cmakeText,
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host "==> [5/5] cmake configure + build"
Invoke-WithVsDev -VsDevCmd $VsDevCmd -Command "cmake -S `"$SrcDir`" -B `"$BuildDir`" -A x64"
Invoke-WithVsDev -VsDevCmd $VsDevCmd -Command "cmake --build `"$BuildDir`" --config Release"

# Output landed at <analyzer-dir>\bin\<TargetName>.dll. Stage it under
# every name the engine's load paths look for: run.dll / runu.dll /
# kb.dll / kbu.dll. The "u" variants are the UNICODE build flavour;
# copying lets either engine flavour load without a rebuild.
$builtDll = Join-Path $AnalyzerDir "bin\$TargetName.dll"
if (-not (Test-Path $builtDll)) {
    throw "Expected output $builtDll was not produced"
}

if ($KbOnly) {
    $stagedNames = @('kb.dll', 'kbu.dll')
} elseif ($AnalyzerOnly) {
    $stagedNames = @('run.dll', 'runu.dll')
} else {
    $stagedNames = @('run.dll', 'runu.dll', 'kb.dll', 'kbu.dll')
}

Write-Host ""
Write-Host "==> Staging $(Split-Path $builtDll -Leaf) into $AnalyzerDir\bin\"
foreach ($name in $stagedNames) {
    $dest = Join-Path $AnalyzerDir "bin\$name"
    Copy-Item -Force $builtDll $dest
}

Write-Host ""
Write-Host "Built:  $builtDll"
Write-Host "Staged: $($stagedNames -join ' ')"
Write-Host "Run:    $NlpExe -COMPILED -ANA `"$AnalyzerDir`" -WORK `"$RepoRoot`" `"$InputFile`""
