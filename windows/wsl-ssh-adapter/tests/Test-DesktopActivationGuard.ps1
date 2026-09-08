#requires -Version 7.0
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$launcher=Join-Path $root 'Start-DesktopWithAdapter.ps1'
$guard=& $launcher -DefinitionsOnly
if ($guard -isnot [scriptblock]) { throw 'Expected pure activation guard.' }
$package='OpenAI.Codex_1.2.3.4_x64__2p2nqsd0c76g0'
$exe='C:\Program Files\WindowsApps\'+$package+'\app\ChatGPT.exe'
$installation=[pscustomobject]@{packageFullName=$package;desktopExecutable=$exe}
$requested=[DateTimeOffset]::Parse('2030-01-01T00:00:10Z')
$activation=@{HResult=0;ProcessId=1234;Executable=$exe;PackageFullName=$package;PackageQueryError=0;ProcessStartUtc='2030-01-01T00:00:11Z'}
$script:count=0
function Check([string]$Name,[hashtable]$Changes,[string]$Expected) {
    $observed=$activation.Clone()
    foreach ($key in $Changes.Keys) { $observed[$key]=$Changes[$key] }
    $result=& $guard ([pscustomobject]$observed) $installation $requested
    if ($result -cne $Expected) { throw "Activation case failed: $Name ($result)" }
    $script:count++
}
Check 'new exact package' @{} MATCHED_NEW_DESKTOP
Check 'Windows path casing' @{Executable=$exe.ToUpperInvariant()} MATCHED_NEW_DESKTOP
Check 'failed HRESULT' @{HResult=-1} ACTIVATION_FAILED
Check 'no process' @{ProcessId=0} ACTIVATION_FAILED
Check 'query error despite matching text' @{PackageQueryError=5} PACKAGE_IDENTITY_UNAVAILABLE
Check 'missing package' @{PackageFullName=$null} PACKAGE_IDENTITY_UNAVAILABLE
Check 'new Store package during launch' @{PackageFullName=$package.Replace('1.2.3.4','1.2.3.5');Executable=$exe.Replace('1.2.3.4','1.2.3.5')} PACKAGE_IDENTITY_MISMATCH
Check 'unrelated package' @{PackageFullName='Other.Package_1.2.3.4_x64__other'} PACKAGE_IDENTITY_MISMATCH
Check 'package identity is case sensitive' @{PackageFullName=$package.ToUpperInvariant()} PACKAGE_IDENTITY_MISMATCH
Check 'wrong executable with correct package' @{Executable='C:\Other\ChatGPT.exe'} EXECUTABLE_MISMATCH
Check 'stale existing process' @{ProcessStartUtc='2030-01-01T00:00:08Z'} PROCESS_NOT_NEW
Check 'one second boundary' @{ProcessStartUtc='2030-01-01T00:00:09Z'} MATCHED_NEW_DESKTOP
Check 'missing start' @{ProcessStartUtc=$null} PROCESS_START_UNAVAILABLE
Check 'malformed start' @{ProcessStartUtc='invalid'} PROCESS_START_UNAVAILABLE
if ((& $guard $null $installation $requested) -cne 'ACTIVATION_FAILED') { throw 'Null activation was not refused.' }
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
function CheckFlow([string]$Name,$Result,[bool]$ActivationThrows,[bool]$ReceiptThrows,[string]$ExpectedError,[string]$ExpectedStatus,[bool]$Registered,[bool]$LeaseThrows=$false) {
    [Apocrita.PackageActivation.Desktop]::Result=$Result
    [Apocrita.PackageActivation.Desktop]::Fail=$ActivationThrows
    [Apocrita.PackageActivation.Desktop]::Calls=0
    $script:diagnosticWriteFails=$ReceiptThrows; $script:receipts.Clear()
    $script:leaseWriteFails=$LeaseThrows
    $lease=[ordered]@{state='PENDING';expiresUtc=$requested.AddSeconds(60).ToString('o');registeredProcessId=0;registeredProcessStartUtc=$null}
    $activation=$null; $activationStatus='ACTIVATION_NOT_COMPLETED'; $launchStatus='FAILED'
    $message=$null
    try { . $flow 3>$null } catch { $message=$_.Exception.Message }
    if ($message -notlike $ExpectedError) { throw "Lifecycle error changed: $Name ($message)" }
    if ([Apocrita.PackageActivation.Desktop]::Calls -ne 1 -or $lease.state -cne 'FAILED') { throw "Lifecycle did not fail closed: $Name" }
    if ((@($script:receipts | Where-Object { $_['state'] -ceq 'REGISTERED' }).Count -gt 0) -ne $Registered) { throw "Unexpected registration: $Name" }
    if (-not $ReceiptThrows) {
        $record=$script:receipts[$script:receipts.Count-1]
        if ($record.status -cne 'FAILED' -or $record.activationStatus -cne $ExpectedStatus -or $record.expectedPackageFullName -cne $package) { throw "Wrong diagnostic result: $Name" }
        $expectedPackage=if ($null -eq $Result) { $null } else { $Result.PackageFullName }
        if ($record.actualPackageFullName -cne $expectedPackage) { throw "Wrong actual package: $Name" }
    }
    $script:count++
}
Set-StrictMode -Version Latest
$WarningPreference='Stop'
$updated=$activation.Clone(); $updated.PackageFullName=$package.Replace('1.2.3.4','1.2.3.5'); $updated.Executable=$exe.Replace('1.2.3.4','1.2.3.5')
CheckFlow 'package changes during activation' ([pscustomobject]$updated) $false $false '*different Desktop package*' PACKAGE_IDENTITY_MISMATCH $false
CheckFlow 'activation throws before result' $null $true $false '*fixture activation failure*' ACTIVATION_NOT_COMPLETED $false
CheckFlow 'receipt failure preserves activation error' $null $true $true '*fixture activation failure*' ACTIVATION_NOT_COMPLETED $false
CheckFlow 'lease and receipt failures preserve activation error' $null $true $true '*fixture activation failure*' ACTIVATION_NOT_COMPLETED $false $true
CheckFlow 'receipt failure preserves mismatch' ([pscustomobject]$updated) $false $true '*different Desktop package*' PACKAGE_IDENTITY_MISMATCH $false
CheckFlow 'matched package with later handshake failure' ([pscustomobject]$activation) $false $false '*fixture handshake inspection failure*' MATCHED_NEW_DESKTOP $true
[pscustomobject]@{pass=$true;cases=$count;powershellVersion=$PSVersionTable.PSVersion.ToString();scope='Local activation guard and mocked launcher failure lifecycle; no Desktop activation, profiles, SSH or HPC access'}
