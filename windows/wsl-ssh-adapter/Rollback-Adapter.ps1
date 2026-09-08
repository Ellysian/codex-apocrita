#requires -Version 7.0
[CmdletBinding()]
param([switch]$VerifyOnly)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Desktop-LocalFiles.ps1')
if (-not $VerifyOnly) { Assert-DesktopStopped }
$before = & (Join-Path $PSScriptRoot 'Install-DesktopProfileHook.ps1') -CheckOnly
$after = $before
if (-not $VerifyOnly) {
    # Disable the lease first: a later profile-removal error cannot re-enable it.
    $leasePath = Join-Path $PSScriptRoot 'state\desktop-environment-lease.json'
    if (Test-Path -LiteralPath $leasePath) {
        Assert-DesktopLocalPath $leasePath -MustExist -Owned
        $lease = ConvertFrom-DesktopJson ([IO.File]::ReadAllText($leasePath))
        $lease.state='DISABLED'; $lease.expiresUtc=[DateTimeOffset]::UtcNow.ToString('o')
        Write-DesktopProtectedJson $leasePath $lease
    }
    $after = & (Join-Path $PSScriptRoot 'Install-DesktopProfileHook.ps1') -Remove
}
[pscustomobject]@{verifyOnly=[bool]$VerifyOnly;hooksBefore=@($before.profiles|Where-Object installed).Count;hooksAfter=@($after.profiles|Where-Object installed).Count;systemSshChanged=$false;globalPathChanged=$false;remoteAccess=$false;configurationAndBackupsPreserved=$true}
