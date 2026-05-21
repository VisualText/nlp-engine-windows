#requires -Version 5.1
<#
.SYNOPSIS
  Verify that a compiled analyzer produces the same final.tree as the
  interpreted run.

.DESCRIPTION
  1. Runs nlp.exe interpreted on the input file and saves the resulting
     <input>_log\final.tree.
  2. Compiles the analyzer to a native .dll via compile-analyzer.ps1.
  3. Runs nlp.exe -COMPILED on the same input file.
  4. Byte-for-byte compares the two final.tree files.

  Exits 0 on match, 1 on mismatch (or any failure along the way).

.PARAMETER AnalyzerDir
  Path to the analyzer directory.
  Default: analyzer-templates\Date and Times

.PARAMETER InputFile
  Path to the input text file the analyzer should run over.
  Default: <AnalyzerDir>\input\test.txt

.EXAMPLE
  scripts\test-compile-roundtrip.ps1

.EXAMPLE
  scripts\test-compile-roundtrip.ps1 "analyzer-templates\Date and Times"

.EXAMPLE
  scripts\test-compile-roundtrip.ps1 "analyzer-templates\Date and Times" "analyzer-templates\Date and Times\input\test.txt"
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)] [string] $AnalyzerDir,
    [Parameter(Position = 1)] [string] $InputFile
)

$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

if (-not $AnalyzerDir) {
    $AnalyzerDir = Join-Path $RepoRoot 'analyzer-templates\Date and Times'
}
$AnalyzerDir = (Resolve-Path $AnalyzerDir).Path

if (-not $InputFile) {
    $InputFile = Join-Path $AnalyzerDir 'input\test.txt'
}
if (-not (Test-Path $InputFile)) {
    throw "Input file not found: $InputFile"
}
$InputFile = (Resolve-Path $InputFile).Path

$NlpExe = Join-Path $RepoRoot 'nlp.exe'
if (-not (Test-Path $NlpExe)) {
    throw "nlp.exe not found at $NlpExe"
}

$AnalyzerName  = Split-Path $AnalyzerDir -Leaf
$InputLeaf     = Split-Path $InputFile -Leaf
$InputDir      = Split-Path $InputFile -Parent
$LogDir        = Join-Path $InputDir "$InputLeaf`_log"
$FinalTreePath = Join-Path $LogDir 'final.tree'

# Saved interpreted-run tree lives next to test-compile-roundtrip.ps1 outputs
# in the analyzer dir (alongside the .dll), so it isn't clobbered when LogDir
# is cleaned between runs.
$SavedTreePath = Join-Path $AnalyzerDir 'final.interpreted.tree'

function Invoke-Nlp {
    param(
        [Parameter(Mandatory = $true)] [string] $Stage,
        [switch] $Compiled
    )
    if (Test-Path $LogDir) {
        Remove-Item -Recurse -Force $LogDir
    }

    $args = @()
    if ($Compiled) { $args += '-COMPILED' }
    $args += @('-ANA', $AnalyzerDir, '-WORK', $RepoRoot, $InputFile)

    Write-Host "==> [$Stage] $NlpExe $($args -join ' ')"
    & $NlpExe @args
    if ($LASTEXITCODE -ne 0) {
        throw "nlp.exe failed ($Stage, exit $LASTEXITCODE)"
    }
    if (-not (Test-Path $FinalTreePath)) {
        throw "Expected $FinalTreePath was not produced by the $Stage run"
    }
}

Write-Host "Analyzer : $AnalyzerDir"
Write-Host "Input    : $InputFile"
Write-Host "Log dir  : $LogDir"
Write-Host ""

# --- 1. Interpreted run -----------------------------------------------------
Invoke-Nlp -Stage 'interpreted'
Copy-Item -Force $FinalTreePath $SavedTreePath
Write-Host "    Saved interpreted tree -> $SavedTreePath"
Write-Host ""

# --- 2. Compile analyzer ----------------------------------------------------
Write-Host "==> [compile] scripts\compile-analyzer.ps1"
& (Join-Path $PSScriptRoot 'compile-analyzer.ps1') $AnalyzerDir $InputFile
if ($LASTEXITCODE -ne 0) {
    throw "compile-analyzer.ps1 failed (exit $LASTEXITCODE)"
}

$Dll = Join-Path $AnalyzerDir "$AnalyzerName.dll"
if (-not (Test-Path $Dll)) {
    throw "Expected compiled DLL not found: $Dll"
}
Write-Host ""

# --- 3. Compiled run --------------------------------------------------------
Invoke-Nlp -Stage 'compiled' -Compiled
Write-Host ""

# --- 4. Compare -------------------------------------------------------------
Write-Host "==> [diff] $SavedTreePath  <-->  $FinalTreePath"

$hashA = (Get-FileHash -Algorithm SHA256 $SavedTreePath).Hash
$hashB = (Get-FileHash -Algorithm SHA256 $FinalTreePath).Hash

if ($hashA -eq $hashB) {
    Write-Host ""
    Write-Host "PASS: interpreted and compiled final.tree are byte-identical."
    Write-Host "      sha256: $hashA"
    exit 0
}

Write-Host ""
Write-Host "FAIL: interpreted and compiled final.tree differ."
Write-Host "      interpreted sha256: $hashA"
Write-Host "      compiled    sha256: $hashB"
Write-Host ""

$linesA = Get-Content -LiteralPath $SavedTreePath
$linesB = Get-Content -LiteralPath $FinalTreePath
$diff   = Compare-Object -ReferenceObject $linesA -DifferenceObject $linesB

Write-Host "First differing lines (<= interpreted, => compiled):"
$diff | Select-Object -First 40 | ForEach-Object {
    $marker = if ($_.SideIndicator -eq '<=') { '<=' } else { '=>' }
    Write-Host "  $marker $($_.InputObject)"
}
if ($diff.Count -gt 40) {
    Write-Host "  ... ($($diff.Count - 40) more diff lines)"
}

exit 1
