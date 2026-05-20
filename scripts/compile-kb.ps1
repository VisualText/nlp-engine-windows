#requires -Version 5.1
<#
.SYNOPSIS
  Compile only an analyzer's KB (knowledge base) to a native .dll.
  Use when the analyzer rules have not changed but the KB has.

.PARAMETER AnalyzerDir
  Path to the analyzer directory (e.g. data\rfb).

.PARAMETER InputFile
  Path to an input text file the engine will run over to drive the compile.

.EXAMPLE
  scripts\compile-kb.ps1 data\rfb data\rfb\input\text.txt

.NOTES
  Output: <AnalyzerDir>\<analyzer-name>_kb.dll
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
$KbLibName = "${AnalyzerName}_kb"

$NlpExe = Join-Path $RepoRoot 'nlp.exe'
$CompileLibs = Join-Path $RepoRoot 'compile-libs'

if (-not (Test-Path $NlpExe)) {
    throw "nlp.exe not found at $NlpExe"
}
if (-not (Test-Path (Join-Path $CompileLibs 'include')) -or -not (Test-Path (Join-Path $CompileLibs 'lib'))) {
    throw "compile-libs not found at $CompileLibs (expected include\ and lib\)."
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

Write-Host "==> [1/4] Locate Visual Studio (VsDevCmd.bat)"
$VsDevCmd = Find-VsDevCmd
Write-Host "    Using: $VsDevCmd"

Write-Host "==> [2/4] nlp.exe -COMPILEKB  (emits kb\*.cpp under $AnalyzerDir)"
$compileCmd = "`"$NlpExe`" -COMPILEKB -ANA `"$AnalyzerDir`" -WORK `"$RepoRoot`" `"$InputFile`""
Invoke-WithVsDev -VsDevCmd $VsDevCmd -Command $compileCmd

$BuildRoot = Join-Path $AnalyzerDir '.nlp-compile-kb'
$SrcDir    = Join-Path $BuildRoot 'src'
$BuildDir  = Join-Path $BuildRoot 'build'
if (Test-Path $BuildRoot) { Remove-Item -Recurse -Force $BuildRoot }
New-Item -ItemType Directory -Path $SrcDir | Out-Null

[System.IO.File]::WriteAllText(
    (Join-Path $SrcDir 'StdAfx.h'),
    "#pragma once`n#include `"my_tchar.h`"`n",
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host "==> [3/4] Generate CMakeLists.txt"
$cmakeAnalyzer = $AnalyzerDir       -replace '\\', '/'
$cmakeSrcDir   = $SrcDir            -replace '\\', '/'
$cmakeInclApi  = (Join-Path $CompileLibs 'include\Api')  -replace '\\', '/'
$cmakeInclCs   = (Join-Path $CompileLibs 'include\cs')   -replace '\\', '/'
$cmakeLibDir   = (Join-Path $CompileLibs 'lib')          -replace '\\', '/'

$cmakeText = @"
cmake_minimum_required(VERSION 3.16)
project(nlp_generated_kb_library LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "$cmakeAnalyzer")
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "$cmakeAnalyzer")
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY "$cmakeAnalyzer")
foreach(CFG IN ITEMS DEBUG RELEASE RELWITHDEBINFO MINSIZEREL)
    set(CMAKE_RUNTIME_OUTPUT_DIRECTORY_\${CFG} "$cmakeAnalyzer")
    set(CMAKE_LIBRARY_OUTPUT_DIRECTORY_\${CFG} "$cmakeAnalyzer")
    set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY_\${CFG} "$cmakeAnalyzer")
endforeach()

file(GLOB GENERATED_CPP "$cmakeAnalyzer/kb/*.cpp")
if(NOT GENERATED_CPP)
    message(FATAL_ERROR "No generated .cpp files found under $cmakeAnalyzer/kb/ -- did -COMPILEKB succeed?")
endif()

add_library(nlp_kb_generated SHARED \${GENERATED_CPP})
set_target_properties(nlp_kb_generated PROPERTIES OUTPUT_NAME "$KbLibName")

target_include_directories(nlp_kb_generated PRIVATE
    "$cmakeSrcDir"
    "$cmakeAnalyzer"
    "$cmakeAnalyzer/kb"
    "$cmakeInclApi"
    "$cmakeInclCs"
)

target_link_directories(nlp_kb_generated PRIVATE "$cmakeLibDir")
target_link_libraries(nlp_kb_generated PRIVATE
    prim kbm consh words lite
    icuin78 icuuc78 icudt78
)

target_compile_definitions(nlp_kb_generated PRIVATE _CRT_SECURE_NO_WARNINGS)
if(MSVC)
    target_compile_options(nlp_kb_generated PRIVATE /wd4005 /FI"StdAfx.h")
endif()
"@

[System.IO.File]::WriteAllText(
    (Join-Path $SrcDir 'CMakeLists.txt'),
    $cmakeText,
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host "==> [4/4] cmake configure + build"
Invoke-WithVsDev -VsDevCmd $VsDevCmd -Command "cmake -S `"$SrcDir`" -B `"$BuildDir`""
Invoke-WithVsDev -VsDevCmd $VsDevCmd -Command "cmake --build `"$BuildDir`" --config Release"

$outDll = Join-Path $AnalyzerDir "$KbLibName.dll"
if (Test-Path $outDll) {
    Write-Host ""
    Write-Host "Built: $outDll"
} else {
    throw "Expected output $outDll was not produced"
}
