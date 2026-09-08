#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ConfigPath, [switch]$CheckOnly)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Desktop-LocalFiles.ps1')
if (-not $CheckOnly) { Assert-DesktopStopped }
# Reject incompatible profiles and untrusted destinations before replacing even
# the configuration. Each writer still repeats its checks immediately before use.
$config = & (Join-Path $PSScriptRoot 'Initialize-AdapterConfiguration.ps1') -ConfigPath $ConfigPath -CheckOnly
$profiles = & (Join-Path $PSScriptRoot 'Install-DesktopProfileHook.ps1') -CheckOnly -PreflightInstall
if (-not $CheckOnly) {
    $config = & (Join-Path $PSScriptRoot 'Initialize-AdapterConfiguration.ps1') -ConfigPath $ConfigPath
    $profiles = & (Join-Path $PSScriptRoot 'Install-DesktopProfileHook.ps1')
}
[pscustomobject]@{configuration=$config;profiles=$profiles;systemSshChanged=$false;sshConfigurationChanged=$false;globalPathChanged=$false;desktopStarted=$false}
