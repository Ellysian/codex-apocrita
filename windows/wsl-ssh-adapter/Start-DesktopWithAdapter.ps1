#requires -Version 7.0
[CmdletBinding()]
param([switch]$CheckOnly,[switch]$DefinitionsOnly)
$ErrorActionPreference='Stop'
if ($CheckOnly -and $DefinitionsOnly) { throw 'Choose either CheckOnly or DefinitionsOnly.' }
function Get-DesktopActivationStatus($Activation,$Installation,[DateTimeOffset]$RequestedUtc) {
    if ($null -eq $Activation -or $Activation.HResult -lt 0 -or $Activation.ProcessId -eq 0) { return 'ACTIVATION_FAILED' }
    if ($Activation.PackageQueryError -ne 0 -or [string]::IsNullOrEmpty($Activation.PackageFullName)) { return 'PACKAGE_IDENTITY_UNAVAILABLE' }
    if ($Activation.PackageFullName -cne $Installation.packageFullName) { return 'PACKAGE_IDENTITY_MISMATCH' }
    if ($Activation.Executable -ine $Installation.desktopExecutable) { return 'EXECUTABLE_MISMATCH' }
    $started=[DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($Activation.ProcessStartUtc,[ref]$started)) { return 'PROCESS_START_UNAVAILABLE' }
    if ($started -lt $RequestedUtc.AddSeconds(-1)) { return 'PROCESS_NOT_NEW' }
    return 'MATCHED_NEW_DESKTOP'
}
# Pure validation entry point: no package discovery, files, processes or activation.
if ($DefinitionsOnly) { return ${function:Get-DesktopActivationStatus} }
. (Join-Path $PSScriptRoot 'Desktop-LocalFiles.ps1')
. (Join-Path $PSScriptRoot 'Resolve-DesktopInstallation.ps1')
$adapter=Join-Path $PSScriptRoot 'bin\ssh.exe'; $config=Join-Path $PSScriptRoot 'adapter-config.json'
$activationSource=Join-Path $PSScriptRoot 'src\DesktopPackageActivation.cs'
foreach ($path in @($PSScriptRoot,$adapter,$config,$activationSource,(Join-Path $PSScriptRoot 'Desktop-ShellEnvironment.ps1'))) {
    Assert-DesktopLocalPath $path -MustExist -Owned
    if (-not (Test-DesktopTrustedWriters $path)) { throw 'Adapter files permit untrusted writers; inspect installation permissions.' }
}
$validation=& $adapter --validate-config $config 2>&1
if ($LASTEXITCODE -ne 0 -or [string]$validation -cne 'ADAPTER_CONFIG_VALID') { throw 'Installed configuration failed local validation.' }
$profiles=& (Join-Path $PSScriptRoot 'Install-DesktopProfileHook.ps1') -CheckOnly
$installed=@($profiles.profiles | Where-Object { -not $_.installed }).Count -eq 0
$running=@(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue).Count -gt 0
if ($CheckOnly) {
    $installation=Resolve-CodexDesktopInstallation
    [pscustomobject]@{configurationValid=$true;profilesInstalled=$installed;desktopAlreadyRunning=$running;packageVersion=$installation.packageVersion;desktopStarted=$false;remoteAccess=$false}; return
}
if (-not $installed) { throw 'Run Install-Adapter.ps1 with an explicit configuration file first.' }
Assert-DesktopStopped
$directory=Initialize-DesktopStateDirectory $PSScriptRoot
$leasePath=Join-Path $directory 'desktop-environment-lease.json'
# Compilation and setup can take time. Resolve the registered Store package only
# after that work so an update is less likely to invalidate the pending lease.
if ($null -eq ('Apocrita.PackageActivation.Desktop' -as [type])) { Add-Type -Path $activationSource }
$adapterHash=(Get-FileHash -LiteralPath $adapter -Algorithm SHA256).Hash
$configHash=(Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash
$installation=Resolve-CodexDesktopInstallation
$desktopExe=$installation.desktopExecutable
$launchId=[guid]::NewGuid().ToString('N'); $requested=[DateTimeOffset]::UtcNow
$lease=[ordered]@{
    version=2; launchId=$launchId; ownerSid=(Get-DesktopUserSid); state='PENDING'
    requestedUtc=$requested.ToString('o'); expiresUtc=$requested.AddSeconds(60).ToString('o')
    expectedDesktopExecutable=$desktopExe; expectedPackageFullName=$installation.packageFullName
    registeredProcessId=0; registeredProcessStartUtc=$null; adapterBin=(Join-Path $PSScriptRoot 'bin')
    adapterSha256=$adapterHash; configSha256=$configHash
}
$activation=$null; $activationStatus='ACTIVATION_NOT_COMPLETED'; $launchStatus='FAILED'
try {
    Assert-DesktopStopped
    Write-DesktopProtectedJson $leasePath $lease
    $activation=[Apocrita.PackageActivation.Desktop]::Activate()
    $activationStatus=Get-DesktopActivationStatus $activation $installation $requested
    if ($activationStatus -ceq 'PACKAGE_IDENTITY_MISMATCH') {
        throw 'Windows activated a different Desktop package. A Store update may have completed during startup. Use the normal Desktop Quit action, then run this launcher again. This window has not been verified for adapter use.'
    }
    if ($activationStatus -cne 'MATCHED_NEW_DESKTOP') { throw "Official activation did not return the expected newly started package process ($activationStatus)." }
    $lease.registeredProcessId=$activation.ProcessId; $lease.registeredProcessStartUtc=$activation.ProcessStartUtc; $lease.state='REGISTERED'
    Write-DesktopProtectedJson $leasePath $lease
    $deadline=[DateTimeOffset]::UtcNow.AddSeconds(20); $matched=$false
    do {
        foreach ($file in Get-ChildItem -LiteralPath $directory -Filter ('desktop-shell-env-'+$launchId+'-*.json') -File) {
            Assert-DesktopLocalPath $file.FullName -MustExist -Owned
            if (-not (Test-DesktopTrustedWriters $file.FullName)) { continue }
            $record=ConvertFrom-DesktopJson ([IO.File]::ReadAllText($file.FullName))
            if ($record.status -ceq 'APPLIED' -and $record.launchId -ceq $launchId -and $record.parentProcessId -eq $activation.ProcessId -and $record.parentStartUtc -ceq $activation.ProcessStartUtc -and $record.adapterHashMatches) { $matched=$true; break }
        }
        if ($matched) { break }; Start-Sleep -Milliseconds 100
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    if (-not $matched) { throw 'Desktop opened but its scoped shell environment was not verified. Inspect setup before retrying; the launcher does not terminate it.' }
    $process=Get-Process -Id $activation.ProcessId -ErrorAction Stop
    if ($process.Path -ine $desktopExe -or $process.HasExited) { throw 'Desktop exited before verification completed.' }
    $launchStatus='DESKTOP_STARTED_PROFILE_APPLIED'
    [pscustomobject]@{status=$launchStatus;packageVersion=$installation.packageVersion;globalPathChanged=$false;remoteTransportVerified=$false}
} catch {
    $lease.state='FAILED'; $lease.expiresUtc=[DateTimeOffset]::UtcNow.ToString('o')
    try { Write-DesktopProtectedJson $leasePath $lease } catch { Write-Warning 'Could not disable the startup lease; its original 60-second expiry remains.' -WarningAction Continue }
    throw
} finally {
    # Diagnostics are independent of lease registration/invalidation. Never log
    # command lines, environment variables, configuration contents or credentials.
    try {
      $record=[ordered]@{
        version=1; launchId=$launchId; requestedUtc=$requested.ToString('o')
        completedUtc=[DateTimeOffset]::UtcNow.ToString('o'); status=$launchStatus
        activationStatus=$activationStatus; expectedPackageFullName=$installation.packageFullName
        expectedDesktopExecutable=$desktopExe
        actualPackageFullName=$null; actualDesktopExecutable=$null
        processId=$null; processStartUtc=$null; hResult=$null; packageQueryError=$null
      }
      if ($null -ne $activation) {
        $record.actualPackageFullName=$activation.PackageFullName; $record.actualDesktopExecutable=$activation.Executable
        $record.processId=$activation.ProcessId; $record.processStartUtc=$activation.ProcessStartUtc
        $record.hResult=$activation.HResult; $record.packageQueryError=$activation.PackageQueryError
      }
      Write-DesktopProtectedJson (Join-Path $directory ('desktop-launch-'+$launchId+'.json')) $record
    }
    catch { Write-Warning 'Could not save launcher diagnostics; the launch result and lease handling are unchanged.' -WarningAction Continue }
}
