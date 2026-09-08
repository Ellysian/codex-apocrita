#requires -Version 7.0
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
& (Join-Path $root 'Build.ps1')
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$bin = Join-Path $PSScriptRoot 'bin'
New-Item -ItemType Directory -Path $bin -Force | Out-Null
function Compile-Fixture([string]$Name, [string[]]$Sources) {
    $output = Join-Path $bin $Name
    & $compiler /nologo /target:exe /platform:x64 /warnaserror+ "/out:$output" @Sources
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $output -PathType Leaf)) {
        throw 'Local test compilation failed or a fixture is missing; stop without renaming or repeated builds.'
    }
}
Compile-Fixture 'ParserTests.exe' @((Join-Path $root 'src\SshArguments.cs'), (Join-Path $PSScriptRoot 'ParserTests.cs'))
Compile-Fixture 'NativeHarness.exe' @((Join-Path $root 'src\NativeProcess.cs'), (Join-Path $PSScriptRoot 'NativeHarness.cs'))
Compile-Fixture 'StreamFixture.exe' @((Join-Path $PSScriptRoot 'StreamFixture.cs'))
Compile-Fixture 'TransportTests.exe' @((Join-Path $root 'src\NativeProcess.cs'), (Join-Path $PSScriptRoot 'TransportTests.cs'))
& (Join-Path $bin 'ParserTests.exe')
if ($LASTEXITCODE -ne 0) { throw 'Parser tests failed.' }
& (Join-Path $PSScriptRoot 'Test-Configuration.ps1')
$events = Join-Path $bin ('transport-' + [Guid]::NewGuid().ToString('N') + '.txt')
& (Join-Path $bin 'TransportTests.exe') $root $events
if ($LASTEXITCODE -ne 0) { throw 'Local byte transport tests failed.' }
Write-Output 'CORE_TESTS_PASS: local Windows fixtures only. No WSL, SSH, HPC or Desktop process was started.'
