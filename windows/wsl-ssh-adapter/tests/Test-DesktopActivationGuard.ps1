#requires -Version 7.0
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$launcher=Join-Path $root 'Start-DesktopWithAdapter.ps1'
$guard=& $launcher -DefinitionsOnly
if ($guard -isnot [scriptblock]) { throw 'Expected pure activation guard.' }
$package='OpenAI.Codex_1.2.3.4_x64__2p2nqsd0c76g0'
$exe='C:\Program Files\WindowsApps\'+$package+'\app\ChatGPT.exe'
$installation=[pscustomobject]@{packageFullName=$package;desktopExecutable=$exe;packageVersion='1.2.3.4'}
$requested=[DateTimeOffset]::Parse('2030-01-01T00:00:10Z')
$now=$requested.AddSeconds(10)
$activation=@{HResult=0;ProcessId=1234;Executable=$exe;PackageFullName=$package;PackageQueryError=0;ProcessStartUtc='2030-01-01T00:00:11Z'}
$script:count=0
function Check([string]$Name,[hashtable]$Changes,[string]$Expected) {
    $observed=$activation.Clone()
    foreach ($key in $Changes.Keys) { $observed[$key]=$Changes[$key] }
    $result=& $guard ([pscustomobject]$observed) $installation $requested $now
    if ($result -cne $Expected) { throw "Activation case failed: $Name ($result)" }
    $script:count++
}
Check 'new exact package' @{} MATCHED_NEW_DESKTOP
Check 'Windows path casing' @{Executable=$exe.ToUpperInvariant()} MATCHED_NEW_DESKTOP
Check 'failed HRESULT' @{HResult=-1} ACTIVATION_FAILED
Check 'no process' @{ProcessId=0} ACTIVATION_FAILED
Check 'negative process' @{ProcessId=-1} ACTIVATION_FAILED
Check 'missing process' @{ProcessId=$null} ACTIVATION_FAILED
Check 'out of range process' @{ProcessId=2147483648} ACTIVATION_FAILED
Check 'missing HRESULT' @{HResult=$null} ACTIVATION_FAILED
Check 'query error despite matching text' @{PackageQueryError=5} PACKAGE_IDENTITY_UNAVAILABLE
Check 'missing package' @{PackageFullName=$null} PACKAGE_IDENTITY_UNAVAILABLE
Check 'missing package query status' @{PackageQueryError=$null} PACKAGE_IDENTITY_UNAVAILABLE
Check 'new Store package during launch' @{PackageFullName=$package.Replace('1.2.3.4','1.2.3.5');Executable=$exe.Replace('1.2.3.4','1.2.3.5')} PACKAGE_IDENTITY_MISMATCH
Check 'unrelated package' @{PackageFullName='Other.Package_1.2.3.4_x64__other'} PACKAGE_IDENTITY_MISMATCH
Check 'package identity is case sensitive' @{PackageFullName=$package.ToUpperInvariant()} PACKAGE_IDENTITY_MISMATCH
Check 'wrong executable with correct package' @{Executable='C:\Other\ChatGPT.exe'} EXECUTABLE_MISMATCH
Check 'stale existing process' @{ProcessStartUtc='2030-01-01T00:00:08Z'} PROCESS_NOT_NEW
Check 'one second boundary' @{ProcessStartUtc='2030-01-01T00:00:09Z'} MATCHED_NEW_DESKTOP
Check 'missing start' @{ProcessStartUtc=$null} PROCESS_START_UNAVAILABLE
Check 'malformed start' @{ProcessStartUtc='invalid'} PROCESS_START_UNAVAILABLE
Check 'non UTC start' @{ProcessStartUtc='2030-01-01T01:00:11+01:00'} PROCESS_START_UNAVAILABLE
Check 'future process' @{ProcessStartUtc='2030-01-01T00:00:22Z'} PROCESS_OUTSIDE_LAUNCH_WINDOW
if ((& $guard ([pscustomobject]$activation) $installation $requested $requested.AddSeconds(60)) -cne 'PROCESS_OUTSIDE_LAUNCH_WINDOW') { throw 'Expired activation was not refused.' }
$count++
if ((& $guard ([pscustomobject]$activation) $installation $requested $requested.AddSeconds(-2)) -cne 'PROCESS_OUTSIDE_LAUNCH_WINDOW') { throw 'Backwards clock was not refused.' }
$count++
if ((& $guard ([pscustomobject]$activation) ([pscustomobject]@{packageFullName='Other.Package';desktopExecutable=$exe}) $requested $now) -cne 'INVALID_REGISTRATION') { throw 'Unrelated registration was not refused.' }
$count++
if ((& $guard $null $installation $requested $now) -cne 'ACTIVATION_FAILED') { throw 'Null activation was not refused.' }
$count++
$refused=$false
try { & $launcher -DefinitionsOnly -CheckOnly } catch { $refused=$true }
if (-not $refused) { throw 'Conflicting modes were not refused.' }
$count++

# Exercise the launcher's actual try/catch/finally with an in-memory activation
# stub. This process never loads the real COM activation implementation.
Add-Type -TypeDefinition @'
namespace Apocrita.PackageActivation {
    public static class Desktop {
        public static object Result;
        public static bool Fail;
        public static int Calls;
        public static object Activate() {
            Calls++;
            if (Fail) throw new System.InvalidOperationException("fixture activation failure");
            return Result;
        }
    }
}
'@
Set-Item -Path Function:Get-DesktopActivationStatus -Value $guard
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($launcher,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'Launcher parse failed.' }
$flowAst=$ast.Find({param($node)
    $node -is [Management.Automation.Language.TryStatementAst] -and
    $node.Body.Statements[0].Extent.Text -ceq 'Assert-DesktopStopped'
},$true)
if ($null -eq $flowAst) { throw 'Launcher lifecycle block was not found.' }
$flow=[scriptblock]::Create($flowAst.Extent.Text)
$script:receipts=[Collections.Generic.List[object]]::new()
$script:diagnosticWriteFails=$false
$script:leaseWriteFails=$false
function Assert-DesktopStopped { }
function Write-DesktopProtectedJson($Path,$Value) {
    if ($script:leaseWriteFails -and $Value['state'] -ceq 'FAILED') { throw 'fixture lease invalidation write failure' }
    if ($script:diagnosticWriteFails -and $Path -like '*desktop-launch-*') { throw 'fixture receipt write failure' }
    $script:receipts.Add(($Value | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable))
}
function Get-ChildItem { throw 'fixture handshake inspection failure' }
$directory='C:\AdapterFixture\state'; $leasePath=Join-Path $directory 'desktop-environment-lease.json'
$launchId='a'*32; $desktopExe=$exe
function CheckFlow([string]$Name,$Result,[bool]$ActivationThrows,[bool]$ReceiptThrows,[string]$ExpectedError,[string]$ExpectedStatus,[bool]$Registered,[bool]$LeaseThrows=$false,$FreshInstallation=$installation,[bool]$ResolverThrows=$false) {
    $requested=[DateTimeOffset]::UtcNow.AddMilliseconds(-200)
    if ($null -ne $Result) { $Result=$Result.PSObject.Copy(); $Result.ProcessStartUtc=$requested.AddMilliseconds(1).ToString('o') }
    $installation=$initialInstallation; $desktopExe=$installation.desktopExecutable
    $packageUpdatedDuringActivation=$false
    $script:resolutionCount=0
    function Resolve-CodexDesktopInstallation {
        $script:resolutionCount++
        if ($ResolverThrows) { throw 'fixture official registration unavailable' }
        $FreshInstallation
    }
    [Apocrita.PackageActivation.Desktop]::Result=$Result
    [Apocrita.PackageActivation.Desktop]::Fail=$ActivationThrows
    [Apocrita.PackageActivation.Desktop]::Calls=0
    $script:diagnosticWriteFails=$ReceiptThrows; $script:receipts.Clear()
    $script:leaseWriteFails=$LeaseThrows
    $lease=[ordered]@{state='PENDING';expiresUtc=$requested.AddSeconds(60).ToString('o');registeredProcessId=0;registeredProcessStartUtc=$null;expectedDesktopExecutable=$desktopExe;expectedPackageFullName=$package}
    $activation=$null; $activationStatus='ACTIVATION_NOT_COMPLETED'; $launchStatus='FAILED'
    $message=$null
    try { . $flow 3>$null } catch { $message=$_.Exception.Message }
    if ($message -notlike $ExpectedError) { throw "Lifecycle error changed: $Name ($message)" }
    if ([Apocrita.PackageActivation.Desktop]::Calls -ne 1 -or $lease.state -cne 'FAILED') { throw "Lifecycle did not fail closed: $Name" }
    if ((@($script:receipts | Where-Object { $_['state'] -ceq 'REGISTERED' }).Count -gt 0) -ne $Registered) { throw "Unexpected registration: $Name" }
    if ($Registered) {
        $published=@($script:receipts | Where-Object { $_['state'] -ceq 'REGISTERED' })
        if ($published.Count -ne 1 -or $published[0].expectedPackageFullName -cne $Result.PackageFullName -or $published[0].expectedDesktopExecutable -ine $Result.Executable -or $published[0].registeredProcessId -ne $Result.ProcessId) { throw "Stale or incomplete registered lease: $Name" }
    }
    if (-not $ReceiptThrows) {
        $record=$script:receipts[$script:receipts.Count-1]
        if ($record.status -cne 'FAILED' -or $record.activationStatus -cne $ExpectedStatus -or $record.expectedPackageFullName -cne $installation.packageFullName -or $record.initialPackageFullName -cne $package -or $record.initialDesktopExecutable -cne $exe -or $record.packageUpdatedDuringActivation -ne $packageUpdatedDuringActivation) { throw "Wrong diagnostic result: $Name" }
        $expectedPackage=if ($null -eq $Result) { $null } else { $Result.PackageFullName }
        if ($record.actualPackageFullName -cne $expectedPackage) { throw "Wrong actual package: $Name" }
    }
    $shouldResolve=$null -ne $Result -and -not $ActivationThrows -and ($Result.PackageFullName -cne $package -or $Result.Executable -ine $exe)
    if ($script:resolutionCount -ne [int]$shouldResolve) { throw "Incorrect resolver count: $Name" }
    $script:count++
}
Set-StrictMode -Version Latest
$WarningPreference='Stop'
$initialInstallation=$installation
$updated=$activation.Clone(); $updated.PackageFullName=$package.Replace('1.2.3.4','1.2.3.5'); $updated.Executable=$exe.Replace('1.2.3.4','1.2.3.5')
$newInstallation=[pscustomobject]@{packageFullName=$updated.PackageFullName;desktopExecutable=$updated.Executable;packageVersion='1.2.3.5'}
CheckFlow 'unregistered changed package' ([pscustomobject]$updated) $false $false '*PACKAGE_IDENTITY_MISMATCH*' PACKAGE_IDENTITY_MISMATCH $false
CheckFlow 'official package changes during activation' ([pscustomobject]$updated) $false $false '*fixture handshake inspection failure*' MATCHED_NEW_DESKTOP $true $false $newInstallation
CheckFlow 'registration unavailable' ([pscustomobject]$updated) $false $false '*fixture official registration unavailable*' PACKAGE_IDENTITY_MISMATCH $false $false $newInstallation $true
$thirdInstallation=[pscustomobject]@{packageFullName=$package.Replace('1.2.3.4','1.2.3.6');desktopExecutable=$exe.Replace('1.2.3.4','1.2.3.6')}
CheckFlow 'second update differs from activated process' ([pscustomobject]$updated) $false $false '*PACKAGE_IDENTITY_MISMATCH*' PACKAGE_IDENTITY_MISMATCH $false $false $thirdInstallation
$mixed=$updated.Clone(); $mixed.Executable=$exe
CheckFlow 'new package with old executable' ([pscustomobject]$mixed) $false $false '*EXECUTABLE_MISMATCH*' EXECUTABLE_MISMATCH $false $false $newInstallation
CheckFlow 'activation throws before result' $null $true $false '*fixture activation failure*' ACTIVATION_NOT_COMPLETED $false
CheckFlow 'receipt failure preserves activation error' $null $true $true '*fixture activation failure*' ACTIVATION_NOT_COMPLETED $false
CheckFlow 'lease and receipt failures preserve activation error' $null $true $true '*fixture activation failure*' ACTIVATION_NOT_COMPLETED $false $true
CheckFlow 'receipt failure preserves mismatch' ([pscustomobject]$updated) $false $true '*PACKAGE_IDENTITY_MISMATCH*' PACKAGE_IDENTITY_MISMATCH $false
CheckFlow 'matched package with later handshake failure' ([pscustomobject]$activation) $false $false '*fixture handshake inspection failure*' MATCHED_NEW_DESKTOP $true
# Drive the same full launcher block through a matching handshake and its final
# process identity check. The input file is this source file; its contents are
# ignored by the JSON mock. No lease, profile, or process is created or changed.
function CheckCompletion([string]$Name,[bool]$ReusePid,[bool]$ChangedPath,[bool]$Exited) {
    $requested=[DateTimeOffset]::UtcNow.AddMilliseconds(-200)
    $installation=$initialInstallation; $desktopExe=$installation.desktopExecutable; $packageUpdatedDuringActivation=$false
    $activated=[pscustomobject]@{HResult=0;ProcessId=1234;Executable=$newInstallation.desktopExecutable;PackageFullName=$newInstallation.packageFullName;PackageQueryError=0;ProcessStartUtc=$requested.AddMilliseconds(1).ToString('o')}
    [Apocrita.PackageActivation.Desktop]::Result=$activated; [Apocrita.PackageActivation.Desktop]::Fail=$false; [Apocrita.PackageActivation.Desktop]::Calls=0
    $script:receipts.Clear(); $script:diagnosticWriteFails=$false; $script:leaseWriteFails=$false; $script:resolutionCount=0
    function Resolve-CodexDesktopInstallation { $script:resolutionCount++; $newInstallation }
    function Get-ChildItem { [pscustomobject]@{FullName=$launcher} }
    function Assert-DesktopLocalPath { }
    function Test-DesktopTrustedWriters { $true }
    function ConvertFrom-DesktopJson {
        [pscustomobject]@{status='APPLIED';launchId=$launchId;parentProcessId=$activated.ProcessId;parentStartUtc=$activated.ProcessStartUtc;adapterHashMatches=$true}
    }
    function Get-Process {
        param([int]$Id)
        if ($Id -ne $activated.ProcessId) { throw 'Unexpected fixture process ID.' }
        $started=[DateTimeOffset]::Parse($activated.ProcessStartUtc).UtcDateTime
        if ($ReusePid) { $started=$started.AddSeconds(1) }
        [pscustomobject]@{Path=$(if ($ChangedPath) {$exe} else {$activated.Executable});HasExited=$Exited;StartTime=$started}
    }
    $lease=[ordered]@{state='PENDING';expiresUtc=$requested.AddSeconds(60).ToString('o');registeredProcessId=0;registeredProcessStartUtc=$null;expectedDesktopExecutable=$desktopExe;expectedPackageFullName=$package}
    $activation=$null; $activationStatus='ACTIVATION_NOT_COMPLETED'; $launchStatus='FAILED'; $message=$null; $output=$null
    try { $output=. $flow } catch { $message=$_.Exception.Message }
    $expectedFailure=$ReusePid -or $ChangedPath -or $Exited
    if ($expectedFailure) {
        if ($message -cne 'Desktop changed or exited before verification completed.' -or $lease.state -cne 'FAILED' -or $launchStatus -cne 'FAILED') { throw "Final process verification did not fail closed: $Name" }
    } elseif ($null -ne $message -or $output.status -cne 'DESKTOP_STARTED_PROFILE_APPLIED' -or $output.remoteTransportVerified -ne $false -or $lease.state -cne 'REGISTERED') { throw "Successful update did not finish: $Name ($message)" }
    $record=$script:receipts[$script:receipts.Count-1]
    if ($script:resolutionCount -ne 1 -or [Apocrita.PackageActivation.Desktop]::Calls -ne 1 -or
        $record.status -cne $launchStatus -or -not $record.packageUpdatedDuringActivation -or
        $record.initialPackageFullName -cne $package -or $record.expectedPackageFullName -cne $activated.PackageFullName -or
        $record.expectedDesktopExecutable -cne $activated.Executable) { throw "Completion diagnostic mismatch: $Name" }
    $script:count++
}
CheckCompletion 'official update completes' $false $false $false
CheckCompletion 'PID reused after handshake' $true $false $false
CheckCompletion 'process path changed after handshake' $false $true $false
CheckCompletion 'process exited after handshake' $false $false $true
[pscustomobject]@{pass=$true;cases=$count;powershellVersion=$PSVersionTable.PSVersion.ToString();scope='Local activation guard and mocked full launcher lifecycle; no Desktop activation, profiles, SSH or HPC access'}
