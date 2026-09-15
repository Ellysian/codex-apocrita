#requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$guard=& (Join-Path $root 'Desktop-ShellEnvironment.ps1') -DefinitionsOnly
if ($guard -isnot [scriptblock]) { throw 'Expected pure lease guard.' }
$sid='S-1-5-21-111111111-222222222-333333333-1001'
$bin='C:\AdapterFixture\bin'
$package='OpenAI.Codex_1.2.3.4_x64__2p2nqsd0c76g0'
$exe='C:\Program Files\WindowsApps\'+$package+'\app\ChatGPT.exe'
$now=[DateTimeOffset]::Parse('2030-01-01T00:00:20Z')
$lease=@{version=2;ownerSid=$sid;launchId=('a'*32);state='REGISTERED';requestedUtc='2030-01-01T00:00:10Z';expiresUtc='2030-01-01T00:01:10Z';expectedDesktopExecutable=$exe;expectedPackageFullName=$package;registeredProcessId=1234;registeredProcessStartUtc='2030-01-01T00:00:11Z';adapterBin=$bin;adapterSha256=('A'*64);configSha256=('C'*64)}
$observed=@{CurrentUserSid=$sid;ParentUserSid=$sid;LeaseOwnerSid=$sid;HookOwnerSid=$sid;FilesTrusted=$true;ParentProcessId=1234;ShellProcessId=5678;ParentStartUtc='2030-01-01T00:00:11Z';ParentExecutable=$exe;ParentPackageFullName=$package;AdapterSha256=('A'*64);ConfigSha256=('C'*64)}
$script:count=0
function Check([string]$Name,[hashtable]$LeaseChanges,[hashtable]$ObservedChanges,[string]$Decision,[string]$Status) {
    $a=$lease.Clone();$b=$observed.Clone()
    foreach ($key in $LeaseChanges.Keys) { $a[$key]=$LeaseChanges[$key] }
    foreach ($key in $ObservedChanges.Keys) { $b[$key]=$ObservedChanges[$key] }
    $path=$env:PATH;$marker=$env:APOCRITA_ADAPTER_LAUNCH_ID
    $result=& $guard ([pscustomobject]$a) ([pscustomobject]$b) $now $bin $sid
    if ($result.Decision -cne $Decision -or $result.Status -cne $Status -or $path -cne $env:PATH -or $marker -cne $env:APOCRITA_ADAPTER_LAUNCH_ID) { throw "Lease guard case failed: $Name" }
    $script:count++
}
Check 'registered direct parent' @{} @{} APPLY MATCHED_REGISTERED_DESKTOP
Check 'pending' @{state='PENDING';registeredProcessId=0;registeredProcessStartUtc=$null} @{} WAIT WAITING_FOR_REGISTRATION
Check 'pending pre-registration' @{state='PENDING'} @{} IGNORE PENDING_WITH_REGISTRATION
Check 'wrong pid' @{registeredProcessId=1235} @{} IGNORE REGISTERED_PID_MISMATCH
Check 'PID reuse' @{registeredProcessStartUtc='2030-01-01T00:00:12Z'} @{} IGNORE REGISTERED_START_MISMATCH
Check 'disabled' @{state='DISABLED'} @{} IGNORE INVALID_LEASE
Check 'invalid launch id' @{launchId='../other'} @{} IGNORE INVALID_LEASE
Check 'wrong version' @{version=1} @{} IGNORE INVALID_LEASE
Check 'wrong current user' @{} @{CurrentUserSid='S-1-5-18'} IGNORE WRONG_USER
Check 'wrong parent user' @{} @{ParentUserSid='S-1-5-18'} IGNORE WRONG_USER
Check 'wrong lease owner' @{} @{LeaseOwnerSid='S-1-5-18'} IGNORE UNTRUSTED_FILES
Check 'wrong hook owner' @{} @{HookOwnerSid='S-1-5-18'} IGNORE UNTRUSTED_FILES
Check 'untrusted/reparse files' @{} @{FilesTrusted=$false} IGNORE UNTRUSTED_FILES
Check 'expired' @{expiresUtc='2030-01-01T00:00:19Z'} @{} IGNORE EXPIRED_OR_INVALID_WINDOW
Check 'at expiry' @{expiresUtc='2030-01-01T00:00:20Z'} @{} IGNORE EXPIRED_OR_INVALID_WINDOW
Check 'overlong lease' @{expiresUtc='2030-01-01T00:01:11Z'} @{} IGNORE EXPIRED_OR_INVALID_WINDOW
Check 'future request' @{requestedUtc='2030-01-01T00:00:22Z'} @{} IGNORE EXPIRED_OR_INVALID_WINDOW
Check 'non UTC' @{requestedUtc='2030-01-01T01:00:10+01:00'} @{} IGNORE INVALID_METADATA
Check 'old parent' @{} @{ParentStartUtc='2030-01-01T00:00:08Z'} IGNORE PARENT_START_OUTSIDE_WINDOW
Check 'future parent' @{} @{ParentStartUtc='2030-01-01T00:00:22Z'} IGNORE PARENT_START_OUTSIDE_WINDOW
Check 'zero pid' @{} @{ParentProcessId=0} IGNORE INVALID_PROCESS_ID
Check 'self parent' @{} @{ParentProcessId=5678} IGNORE INVALID_PROCESS_ID
Check 'ordinary terminal ancestor irrelevant' @{} @{ParentExecutable='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'} IGNORE WRONG_DIRECT_PARENT_EXE
Check 'wrong package' @{} @{ParentPackageFullName='Other.Package_1.0.0.0_x64__other'} IGNORE WRONG_DESKTOP_PACKAGE
Check 'relative exe' @{expectedDesktopExecutable='ChatGPT.exe'} @{} IGNORE INVALID_METADATA
Check 'case-insensitive path' @{} @{ParentExecutable=$exe.ToUpperInvariant()} APPLY MATCHED_REGISTERED_DESKTOP
Check 'wrong bin' @{adapterBin='C:\OtherAdapter\bin'} @{} IGNORE WRONG_ADAPTER_PATH
Check 'relative bin' @{adapterBin='bin'} @{} IGNORE INVALID_METADATA
Check 'different binary' @{} @{AdapterSha256=('B'*64)} IGNORE ADAPTER_HASH_MISMATCH
Check 'short hash' @{adapterSha256='AAAA'} @{} IGNORE ADAPTER_HASH_MISMATCH
Check 'case-insensitive hash' @{} @{AdapterSha256=('a'*64)} APPLY MATCHED_REGISTERED_DESKTOP
Check 'different config' @{} @{ConfigSha256=('D'*64)} IGNORE CONFIG_HASH_MISMATCH
$updatedPackage=$package.Replace('1.2.3.4','1.2.3.5'); $updatedExe=$exe.Replace('1.2.3.4','1.2.3.5')
$pending=@{state='PENDING';registeredProcessId=0;registeredProcessStartUtc=$null}
$updatedParent=@{ParentPackageFullName=$updatedPackage;ParentExecutable=$updatedExe}
Check 'update waits before registration' $pending $updatedParent WAIT WAITING_FOR_REGISTRATION
Check 'updated identity registered together' @{expectedPackageFullName=$updatedPackage;expectedDesktopExecutable=$updatedExe} $updatedParent APPLY MATCHED_REGISTERED_DESKTOP
Check 'stale registration after update' @{} $updatedParent IGNORE WRONG_DESKTOP_PACKAGE
Check 'only package updated' @{expectedPackageFullName=$updatedPackage} $updatedParent IGNORE WRONG_DESKTOP_PACKAGE
Check 'only path updated' @{expectedDesktopExecutable=$updatedExe} $updatedParent IGNORE WRONG_DESKTOP_PACKAGE
Check 'updated PID mismatch' @{expectedPackageFullName=$updatedPackage;expectedDesktopExecutable=$updatedExe;registeredProcessId=1235} $updatedParent IGNORE REGISTERED_PID_MISMATCH
Check 'pending wrong user remains refused' $pending @{CurrentUserSid='S-1-5-18'} IGNORE WRONG_USER
Check 'pending untrusted files remain refused' $pending @{FilesTrusted=$false} IGNORE UNTRUSTED_FILES
Check 'pending altered adapter remains refused' $pending @{AdapterSha256=('B'*64)} IGNORE ADAPTER_HASH_MISMATCH
Check 'pending altered config remains refused' $pending @{ConfigSha256=('D'*64)} IGNORE CONFIG_HASH_MISMATCH
$expiredPending=$pending.Clone(); $expiredPending.expiresUtc='2030-01-01T00:00:20Z'
Check 'pending expiration remains refused' $expiredPending $updatedParent IGNORE EXPIRED_OR_INVALID_WINDOW
# Execute the actual bounded wait loop with in-memory leases and clock doubles.
# It cannot reach the hook's process-environment mutation or inspect a process.
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Desktop-ShellEnvironment.ps1'),[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'Profile hook parse failed.' }
$loopAst=$ast.Find({param($node)
    $node -is [Management.Automation.Language.DoWhileStatementAst] -and
    $node.Body.Statements[0].Extent.Text -clike '$decision=Test-DesktopProfileLease *'
},$true)
if ($null -eq $loopAst) { throw 'Profile wait loop was not found.' }
$waitLoop=[scriptblock]::Create($loopAst.Extent.Text)
foreach ($command in $waitLoop.Ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst]},$true)) {
    if ($command.GetCommandName() -cnotin @('Test-DesktopProfileLease','Read-Lease','Start-Sleep')) { throw 'Unexpected command in pure wait-loop fixture.' }
}
function CheckWait([string]$Name,[int]$WaitElapsed,[int]$TotalElapsed,[bool]$ReplaceLaunch,[bool]$ExpectedReturn,[int]$ExpectedReads) {
    $pathBefore=$env:PATH; $markerBefore=$env:APOCRITA_ADAPTER_LAUNCH_ID
    $fresh=[DateTimeOffset]::UtcNow.AddMilliseconds(-100)
    $pendingLease=$lease.Clone(); $pendingLease.state='PENDING'; $pendingLease.registeredProcessId=0; $pendingLease.registeredProcessStartUtc=$null
    $pendingLease.requestedUtc=$fresh.ToString('o'); $pendingLease.expiresUtc=$fresh.AddSeconds(60).ToString('o')
    $parent=$observed.Clone(); $parent.ParentExecutable=$updatedExe; $parent.ParentPackageFullName=$updatedPackage; $parent.ParentStartUtc=$fresh.AddMilliseconds(1).ToString('o')
    $registeredLease=$pendingLease.Clone(); $registeredLease.state='REGISTERED'
    $registeredLease.expectedDesktopExecutable=$updatedExe; $registeredLease.expectedPackageFullName=$updatedPackage
    $registeredLease.registeredProcessId=$parent.ParentProcessId; $registeredLease.registeredProcessStartUtc=$parent.ParentStartUtc
    if ($ReplaceLaunch) { $registeredLease.launchId='b'*32 }
    $result=@{returned=$false;reads=0;sleeps=0;decision=$null}
    & {
        $lease=[pscustomobject]$pendingLease; $observed=[pscustomobject]$parent; $launchId=$lease.launchId
        $wait=[pscustomobject]@{ElapsedMilliseconds=$WaitElapsed}; $timer=[pscustomobject]@{ElapsedMilliseconds=$TotalElapsed}
        Set-Item Function:Test-DesktopProfileLease $guard
        function Start-Sleep { param([int]$Milliseconds) if ($Milliseconds -ne 50) { throw 'Wait interval changed.' }; $result.sleeps++ }
        function Read-Lease { $result.reads++; [pscustomobject]$registeredLease }
        # Run the extracted loop directly in this disposable scope so a timeout
        # returns before the sentinel, just as it does in the production hook.
        $runner=[scriptblock]::Create($waitLoop.ToString()+"`n"+'$result.returned=$true; $result.decision=$decision.Decision')
        . $runner
    }
    if ($result.returned -ne $ExpectedReturn -or $result.reads -ne $ExpectedReads -or $result.sleeps -ne $ExpectedReads -or
        ($ExpectedReturn -and $result.decision -cne 'APPLY') -or $env:PATH -cne $pathBefore -or $env:APOCRITA_ADAPTER_LAUNCH_ID -cne $markerBefore) { throw "Wait-loop case failed: $Name" }
    $script:count++
}
CheckWait 'updated registration reaches APPLY' 0 0 $false $true 1
CheckWait 'pending wait deadline returns without APPLY' 2500 0 $false $false 0
CheckWait 'total hook deadline returns without APPLY' 0 4450 $false $false 0
CheckWait 'replacement launch returns without APPLY' 0 0 $true $false 1
. (Join-Path $root 'Desktop-LocalFiles.ps1')
$parsed=ConvertFrom-DesktopJson ($lease|ConvertTo-Json)
if ($parsed.requestedUtc -isnot [string] -or (& $guard $parsed ([pscustomobject]$observed) $now $bin $sid).Decision -cne 'APPLY') { throw 'JSON timestamp round-trip failed.' }
# These compile only; no Windows activation or process API is called.
Add-Type -Path (Join-Path $root 'src\DesktopShellLaunch.cs')
Add-Type -Path (Join-Path $root 'src\DesktopPackageActivation.cs')
[pscustomobject]@{pass=$true;cases=($count+1);powershellVersion=$PSVersionTable.PSVersion.ToString();scope='Pure lease guard, mocked bounded wait loop and native declarations compilation only'}
