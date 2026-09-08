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
. (Join-Path $root 'Desktop-LocalFiles.ps1')
$parsed=ConvertFrom-DesktopJson ($lease|ConvertTo-Json)
if ($parsed.requestedUtc -isnot [string] -or (& $guard $parsed ([pscustomobject]$observed) $now $bin $sid).Decision -cne 'APPLY') { throw 'JSON timestamp round-trip failed.' }
# These compile only; no Windows activation or process API is called.
Add-Type -Path (Join-Path $root 'src\DesktopShellLaunch.cs')
Add-Type -Path (Join-Path $root 'src\DesktopPackageActivation.cs')
[pscustomobject]@{pass=$true;cases=($count+1);powershellVersion=$PSVersionTable.PSVersion.ToString();scope='Pure mock lease guard and native declarations compilation only'}
