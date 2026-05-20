#requires -Version 5.1
<#
.SYNOPSIS
  Compile an NLP++ analyzer (and its KB) to a native .dll that nlp.exe can
  load with -COMPILED.

.PARAMETER AnalyzerDir
  Path to the analyzer directory (e.g. data\rfb).

.PARAMETER InputFile
  Path to an input text file the engine will run over to drive the compile.

.EXAMPLE
  scripts\compile-analyzer.ps1 data\rfb data\rfb\input\text.txt

.NOTES
  Requires Visual Studio 2022 (or Build Tools) with the "Desktop development
  with C++" workload, and CMake >= 3.16. The first invocation generates ICU
  import libraries (icudt78.lib, icuin78.lib, icuuc78.lib) from the bundled
  DLLs using dumpbin + lib.exe; subsequent runs reuse them.

  Output: <AnalyzerDir>\<analyzer-name>.dll
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)] [string] $AnalyzerDir,
    [Parameter(Mandatory = $true, Position = 1)] [string] $InputFile
)

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$AnalyzerDir = (Resolve-Path $AnalyzerDir).Path
$AnalyzerName = Split-Path $AnalyzerDir -Leaf

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
        # "       1    0 00071FA0 u_UCharDirection_swap_78"
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

Write-Host "==> [2/5] Ensure ICU import libraries exist"
Ensure-IcuImportLibs -VsDevCmd $VsDevCmd

Write-Host "==> [3/5] nlp.exe -COMPILE  (emits run\*.cpp and kb\*.cpp under $AnalyzerDir)"
$compileCmd = "`"$NlpExe`" -COMPILE -ANA `"$AnalyzerDir`" -WORK `"$RepoRoot`" `"$InputFile`""
Invoke-WithVsDev -VsDevCmd $VsDevCmd -Command $compileCmd

$BuildRoot = Join-Path $AnalyzerDir '.nlp-compile'
$SrcDir    = Join-Path $BuildRoot 'src'
$BuildDir  = Join-Path $BuildRoot 'build'
if (Test-Path $BuildRoot) { Remove-Item -Recurse -Force $BuildRoot }
New-Item -ItemType Directory -Path $SrcDir | Out-Null

[System.IO.File]::WriteAllText(
    (Join-Path $SrcDir 'StdAfx.h'),
    "#pragma once`n#include `"my_tchar.h`"`n",
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host "==> [4/5] Generate CMakeLists.txt"
$cmakeAnalyzer  = $AnalyzerDir       -replace '\\', '/'
$cmakeSrcDir    = $SrcDir            -replace '\\', '/'
$cmakeInclApi   = (Join-Path $CompileLibs 'include\Api')  -replace '\\', '/'
$cmakeInclCs    = (Join-Path $CompileLibs 'include\cs')   -replace '\\', '/'
$cmakeLibDir    = (Join-Path $CompileLibs 'lib')          -replace '\\', '/'

$cmakeText = @"
cmake_minimum_required(VERSION 3.16)
project(nlp_generated_library LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# Drop the .dll directly into the analyzer dir (no Release/ subfolder).
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "$cmakeAnalyzer")
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "$cmakeAnalyzer")
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY "$cmakeAnalyzer")
foreach(CFG IN ITEMS DEBUG RELEASE RELWITHDEBINFO MINSIZEREL)
    set(CMAKE_RUNTIME_OUTPUT_DIRECTORY_\${CFG} "$cmakeAnalyzer")
    set(CMAKE_LIBRARY_OUTPUT_DIRECTORY_\${CFG} "$cmakeAnalyzer")
    set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY_\${CFG} "$cmakeAnalyzer")
endforeach()

file(GLOB GENERATED_CPP
    "$cmakeAnalyzer/run/*.cpp"
    "$cmakeAnalyzer/kb/*.cpp"
)
if(NOT GENERATED_CPP)
    message(FATAL_ERROR "No generated .cpp files found under $cmakeAnalyzer/{run,kb}/ -- did -COMPILE succeed?")
endif()

add_library(nlp_generated SHARED \${GENERATED_CPP})
set_target_properties(nlp_generated PROPERTIES OUTPUT_NAME "$AnalyzerName")

target_include_directories(nlp_generated PRIVATE
    "$cmakeSrcDir"
    "$cmakeAnalyzer"
    "$cmakeAnalyzer/run"
    "$cmakeAnalyzer/kb"
    "$cmakeInclApi"
    "$cmakeInclCs"
)

target_link_directories(nlp_generated PRIVATE "$cmakeLibDir")
target_link_libraries(nlp_generated PRIVATE
    prim kbm consh words lite
    icuin78 icuuc78 icudt78
)

target_compile_definitions(nlp_generated PRIVATE _CRT_SECURE_NO_WARNINGS)
if(MSVC)
    target_compile_options(nlp_generated PRIVATE /wd4005 /FI"StdAfx.h")
endif()
"@

[System.IO.File]::WriteAllText(
    (Join-Path $SrcDir 'CMakeLists.txt'),
    $cmakeText,
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host "==> [5/5] cmake configure + build"
Invoke-WithVsDev -VsDevCmd $VsDevCmd -Command "cmake -S `"$SrcDir`" -B `"$BuildDir`""
Invoke-WithVsDev -VsDevCmd $VsDevCmd -Command "cmake --build `"$BuildDir`" --config Release"

$outDll = Join-Path $AnalyzerDir "$AnalyzerName.dll"
if (Test-Path $outDll) {
    Write-Host ""
    Write-Host "Built: $outDll"
    Write-Host "Run:   $NlpExe -COMPILED -ANA `"$AnalyzerDir`" -WORK `"$RepoRoot`" `"$InputFile`""
} else {
    throw "Expected output $outDll was not produced"
}
