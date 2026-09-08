#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ConfigPath, [switch]$CheckOnly)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Desktop-LocalFiles.ps1')
$source = [IO.Path]::GetFullPath($ConfigPath)
$destination = Join-Path $PSScriptRoot 'adapter-config.json'
$validator = Join-Path $PSScriptRoot 'bin\ssh.exe'
Assert-DesktopLocalPath $source -MustExist -Owned
Assert-DesktopLocalPath $validator -MustExist -Owned
if (-not (Test-DesktopTrustedWriters $source) -or -not (Test-DesktopTrustedWriters $validator)) { throw 'Configuration and validator must have trusted writers.' }
if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or (Get-Item -LiteralPath $source).Length -gt 65536) { throw 'Expected a small local JSON configuration file.' }
# This dedicated core mode only validates local JSON. It never calls WSL or SSH.
# Keep the source read-locked until validation and byte capture finish, so the
# installed bytes are the same bytes validated by the core.
$inputStream=[IO.File]::Open($source,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
try {
    if ($inputStream.Length -gt 65536) { throw 'Expected a small local JSON configuration file.' }
    $memory=[IO.MemoryStream]::new()
    try { $inputStream.CopyTo($memory); $configurationBytes=$memory.ToArray() } finally { $memory.Dispose() }
    $validation = & $validator --validate-config $source 2>&1
    if ($LASTEXITCODE -ne 0 -or [string]$validation -cne 'ADAPTER_CONFIG_VALID') { throw 'Adapter configuration failed static validation; no configuration was installed.' }
} finally { $inputStream.Dispose() }
if ($CheckOnly) { [pscustomobject]@{ valid=$true; changed=$false; remoteAccess=$false }; return }
Assert-DesktopStopped
Assert-DesktopLocalPath $PSScriptRoot -MustExist -Owned
if (-not (Test-DesktopTrustedWriters $PSScriptRoot)) { throw 'Place the adapter in a directory writable only by your Windows account and administrators.' }
$state = Initialize-DesktopStateDirectory $PSScriptRoot
$backup = $null
if (Test-Path -LiteralPath $destination) {
    Assert-DesktopLocalPath $destination -Owned
    $backup = 'config-before-' + [guid]::NewGuid().ToString('N') + '.json'
    Write-DesktopProtectedBytes (Join-Path $state $backup) ([IO.File]::ReadAllBytes($destination))
}
Write-DesktopProtectedBytes $destination $configurationBytes
Protect-DesktopLocalFile $destination
Write-DesktopProtectedJson (Join-Path $state 'configuration-installation.json') ([ordered]@{
    version=1; configuredUtc=[DateTimeOffset]::UtcNow.ToString('o'); previousConfiguration=$backup
    configurationSha256=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
})
[pscustomobject]@{ valid=$true; changed=$true; remoteAccess=$false; configurationPath=$destination }
