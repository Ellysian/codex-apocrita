[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
if (-not [Environment]::Is64BitProcess -or [Environment]::OSVersion.Platform -ne 'Win32NT') {
    throw 'Build requires 64-bit Windows PowerShell or PowerShell on Windows.'
}
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) { throw 'The .NET Framework C# compiler is missing.' }
$bin = Join-Path $PSScriptRoot 'bin'
New-Item -ItemType Directory -Path $bin -Force | Out-Null
$sources = @('src\SshArguments.cs','src\NativeProcess.cs','src\Program.cs') | ForEach-Object { Join-Path $PSScriptRoot $_ }
& $compiler /nologo /target:exe /platform:x64 /optimize+ /warnaserror+ /reference:System.Web.Extensions.dll "/out:$bin\ssh.exe" @sources
if ($LASTEXITCODE -ne 0) { throw 'Adapter compilation failed. Do not rename or repeatedly rebuild missing executables to bypass local protection.' }
if (-not (Test-Path -LiteralPath (Join-Path $bin 'ssh.exe') -PathType Leaf)) { throw 'Compiled adapter is missing; stop and inspect local protection history.' }
Write-Output 'Adapter built: bin/ssh.exe. No configuration, SSH session or Desktop process was changed.'
