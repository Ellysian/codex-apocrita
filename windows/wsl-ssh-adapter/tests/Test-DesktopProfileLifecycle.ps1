#requires -Version 7.0
# Temporary profiles only. No actual Windows profile installation or app launch.
$ErrorActionPreference='Stop'
Add-Type -Path (Join-Path $PSScriptRoot 'FixtureOwnerContext.cs')
# Scope the default owner change to this disposable fixture, not the process or
# the account. All production ownership, writer and reparse checks remain active.
[ApocritaAdapter.Tests.FixtureOwnerContext]::Run([Func[object]] {
$source=Split-Path $PSScriptRoot -Parent
$temporary=Join-Path $PSScriptRoot ('codex-adapter-profile-test-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temporary)
$stage='fixture setup'
try {
    foreach ($dir in @('src','bin','profiles')) { [void][IO.Directory]::CreateDirectory((Join-Path $temporary $dir)) }
    foreach ($name in @('Desktop-LocalFiles.ps1','Initialize-AdapterConfiguration.ps1','Install-Adapter.ps1','Install-DesktopProfileHook.ps1','Desktop-ShellEnvironment.ps1','src\DesktopShellLaunch.cs','src\DesktopPackageActivation.cs')) { [IO.File]::WriteAllBytes((Join-Path $temporary $name),[IO.File]::ReadAllBytes((Join-Path $source $name))) }
    # The profile installer only checks presence/ACLs. This file is never executed.
    [IO.File]::WriteAllBytes((Join-Path $temporary 'bin\ssh.exe'),[byte[]]::new(0))
    [IO.File]::WriteAllText((Join-Path $temporary 'adapter-config.json'),'{}')
    . (Join-Path $temporary 'Desktop-LocalFiles.ps1')
    Protect-DesktopLocalFile $temporary
    # Scoped command mock lets fixture installation run while real Desktop stays open.
    function Get-Process { param([string]$Name) if ($Name -ne 'ChatGPT') { throw 'Unexpected process query in fixture.' } }
    $profiles=@((Join-Path $temporary 'profiles\utf8.ps1'),(Join-Path $temporary 'profiles\utf16.ps1'))
    $prefixes=@([Text.UTF8Encoding]::new($false).GetBytes("# user profile`r`n"),[byte[]]([Text.Encoding]::Unicode.GetPreamble()+[Text.Encoding]::Unicode.GetBytes("# unicode profile`r`n")))
    for ($index=0;$index -lt 2;$index++) { [IO.File]::WriteAllBytes($profiles[$index],$prefixes[$index]) }
    $acls=@($profiles | ForEach-Object { (Get-Acl -LiteralPath $_).Sddl })
    $installer=Join-Path $temporary 'Install-DesktopProfileHook.ps1'
    $stage='initial preflight'; $before=& $installer -CheckOnly -ProfilePaths $profiles
    if (@($before.profiles|Where-Object installed).Count) { throw 'Unexpected initial hook.' }
    $stage='complete installation preflight'; [void](& $installer -CheckOnly -PreflightInstall -ProfilePaths $profiles)
    if (Test-Path -LiteralPath (Join-Path $temporary 'state')) { throw 'Read-only preflight created installation state.' }
    $stage='refused profile leaves files unchanged'
    $invalidProfile=Join-Path $temporary 'profiles\invalid-encoding.ps1'
    [IO.File]::WriteAllBytes($invalidProfile,[byte[]](255,254,0,0,35,0,0,0))
    $protectedFiles=@('adapter-config.json','Desktop-ShellEnvironment.ps1','Desktop-LocalFiles.ps1','src\DesktopShellLaunch.cs','src\DesktopPackageActivation.cs','bin\ssh.exe') | ForEach-Object { Join-Path $temporary $_ }
    $originalAcls=@($protectedFiles | ForEach-Object { (Get-Acl -LiteralPath $_).Sddl })
    $refused=$false
    try { [void](& $installer -ProfilePaths @($profiles[0],$invalidProfile)) } catch {
        if ($_.Exception.Message -notmatch '^UTF-32 profiles require manual integration') { throw }
        $refused=$true
    }
    if (-not $refused -or (Test-Path -LiteralPath (Join-Path $temporary 'state'))) { throw 'Invalid profile changed installation state.' }
    for ($index=0;$index -lt $protectedFiles.Count;$index++) {
        if ((Get-Acl -LiteralPath $protectedFiles[$index]).Sddl -cne $originalAcls[$index]) { throw 'Refused profile installation changed an adapter ACL.' }
    }
    if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($profiles[0])) -cne [Convert]::ToBase64String($prefixes[0])) { throw 'Refused second profile changed the first profile.' }
    $stage='untrusted destination preflight'
    $untrustedParent=Join-Path $temporary 'untrusted-profiles'; [void][IO.Directory]::CreateDirectory($untrustedParent)
    $untrustedAcl=Get-Acl -LiteralPath $untrustedParent
    [void]$untrustedAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-1-0'),'Write','Allow'))
    Set-Acl -LiteralPath $untrustedParent -AclObject $untrustedAcl
    $refused=$false
    try { [void](& $installer -CheckOnly -PreflightInstall -ProfilePaths @((Join-Path $untrustedParent 'nested\profile.ps1'))) } catch {
        if ($_.Exception.Message -cne 'Profile directory permits untrusted writers.') { throw }
        $refused=$true
    }
    if (-not $refused -or (Test-Path -LiteralPath (Join-Path $untrustedParent 'nested'))) { throw 'Untrusted profile parent was not refused without writes.' }
    $stage='first installation'; $first=& $installer -ProfilePaths $profiles
    $hashes=@($profiles|ForEach-Object{(Get-FileHash -LiteralPath $_).Hash})
    $stage='idempotent installation'; $again=& $installer -ProfilePaths $profiles
    for ($index=0;$index -lt 2;$index++) {
        if ((Get-FileHash -LiteralPath $profiles[$index]).Hash -ne $hashes[$index]) { throw 'Installation is not idempotent.' }
        if ((Get-Acl -LiteralPath $profiles[$index]).Sddl -cne $acls[$index]) { throw 'Existing profile ACL changed.' }
    }
    $pathBefore=$env:PATH; $markerBefore=$env:APOCRITA_ADAPTER_LAUNCH_ID
    . $profiles[0]
    if ($env:PATH -cne $pathBefore -or $env:APOCRITA_ADAPTER_LAUNCH_ID -cne $markerBefore) { throw 'Ordinary profile changed process environment.' }
    $stage='rollback'; $removed=& $installer -Remove -ProfilePaths $profiles
    for ($index=0;$index -lt 2;$index++) {
        if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($profiles[$index])) -cne [Convert]::ToBase64String($prefixes[$index])) { throw 'Rollback did not preserve profile bytes.' }
    }
    $newProfiles=@((Join-Path $temporary 'profiles\created.ps1'))
    # A separate isolated installation record is required for a different profile selection.
    [IO.File]::Delete((Join-Path $temporary 'state\desktop-profile-installation.json'))
    $stage='new profile installation'; [void](& $installer -ProfilePaths $newProfiles)
    [void](& $installer -Remove -ProfilePaths $newProfiles)
    if (Test-Path -LiteralPath $newProfiles[0]) { throw 'New empty managed profile was not removed.' }
    [IO.File]::Delete((Join-Path $temporary 'state\desktop-profile-installation.json'))
    [void](& $installer -ProfilePaths $profiles)
    [IO.File]::AppendAllText($profiles[0],"# later edit`r`n")
    $refused=$false
    try { [void](& $installer -Remove -ProfilePaths $profiles) } catch { $refused=$true }
    if (-not $refused) { throw 'Moved suffix must fail closed.' }
    $stage='reparse guard'
    $junction=Join-Path $temporary 'junction'
    [void](New-Item -ItemType Junction -Path $junction -Target (Join-Path $temporary 'profiles'))
    $refused=$false
    try { Assert-DesktopLocalPath (Join-Path $junction 'utf8.ps1') -MustExist } catch { $refused=$true }
    if (-not $refused) { throw 'Reparse ancestor must be rejected.' }
    # Remove this verified link itself, not its target, before recursive cleanup.
    [IO.Directory]::Delete($junction)
    $stage='writer guard'
    $probe=Join-Path $temporary 'writer-probe.txt'; [IO.File]::WriteAllText($probe,'fixture')
    $acl=Get-Acl -LiteralPath $probe
    [void]$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-1-0'),'Write','Allow'))
    Set-Acl -LiteralPath $probe -AclObject $acl
    if (Test-DesktopTrustedWriters $probe) { throw 'Everyone write access must be rejected.' }
    $stage='configuration validation read lock'
    # This fixture executable is not the adapter. It only attempts local writes
    # and deletion against its explicit test JSON while the initializer validates it.
    $validatorSource=Join-Path $temporary 'ValidationLockFixture.cs'
    [IO.File]::WriteAllText($validatorSource,@'
using System;
using System.IO;
internal static class ValidationLockFixture {
    private static int Main(string[] args) {
        if (args.Length != 2 || args[0] != "--validate-config") return 2;
        if (File.ReadAllText(args[1]) != "{\"fixture\":true}") return 3;
        bool writeBlocked = false;
        bool deleteBlocked = false;
        try { using (File.Open(args[1], FileMode.Open, FileAccess.Write, FileShare.ReadWrite)) {} }
        catch (IOException) { writeBlocked = true; }
        try { File.Delete(args[1]); }
        catch (IOException) { deleteBlocked = true; }
        if (!writeBlocked || !deleteBlocked) return 4;
        Console.WriteLine("ADAPTER_CONFIG_VALID");
        return 0;
    }
}
'@)
    $compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    $compilerOutput = & $compiler /nologo /target:exe /platform:x64 /warnaserror+ ('/out:'+(Join-Path $temporary 'bin\ssh.exe')) $validatorSource 2>&1
    if ($LASTEXITCODE -ne 0) {
        $diagnostic = [regex]::Replace([string]::Join("`n",[string[]]$compilerOutput),[regex]::Escape($temporary),'<fixture>',[Text.RegularExpressions.RegexOptions]::IgnoreCase)
        throw ('Local validation lock fixture compilation failed: '+$diagnostic)
    }
    # A child compiler uses the process token, not this thread's impersonation
    # token. Normalize only this exact newly built fixture artifact, then verify
    # it with the unmodified production guards. Do not repair arbitrary failures.
    $fixtureBinary=[IO.Path]::GetFullPath((Join-Path $temporary 'bin\ssh.exe'))
    $fixtureRoot=[IO.Path]::GetFullPath($temporary).TrimEnd('\')+'\'
    if (-not $fixtureBinary.StartsWith($fixtureRoot,[StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture compiler output escaped its temporary directory.' }
    Assert-DesktopLocalPath $fixtureBinary -MustExist
    $binaryInfo=[IO.FileInfo]::new($fixtureBinary)
    $binaryAcl=[IO.FileSystemAclExtensions]::GetAccessControl($binaryInfo,[Security.AccessControl.AccessControlSections]::Owner)
    $binaryAcl.SetOwner([Security.Principal.SecurityIdentifier]::new((Get-DesktopUserSid)))
    [IO.FileSystemAclExtensions]::SetAccessControl($binaryInfo,$binaryAcl)
    Assert-DesktopLocalPath $fixtureBinary -MustExist -Owned
    if (-not (Test-DesktopTrustedWriters $fixtureBinary)) { throw 'Fixture compiler output permits untrusted writers.' }
    $lockConfig=Join-Path $temporary 'lock-fixture.json'
    [IO.File]::WriteAllText($lockConfig,'{"fixture":true}')
    $validationResult=& (Join-Path $temporary 'Initialize-AdapterConfiguration.ps1') -ConfigPath $lockConfig -CheckOnly
    if (-not $validationResult.valid -or $validationResult.changed -or [IO.File]::ReadAllText($lockConfig) -cne '{"fixture":true}') { throw 'Validation did not preserve locked configuration bytes.' }
    $stage='top-level installer refuses before config replacement'
    # Route only the copied installer's default profile selection into this
    # fixture. Production code and actual Windows profile paths stay untouched.
    [IO.File]::WriteAllBytes((Join-Path $temporary 'ProfileHookImplementation.ps1'),[IO.File]::ReadAllBytes($installer))
    $quotedProfiles=($profiles | ForEach-Object { "'"+$_.Replace("'","''")+"'" }) -join ','
    [IO.File]::WriteAllText($installer,('param([switch]$CheckOnly,[switch]$Remove,[switch]$PreflightInstall)' + "`r`n" + '& (Join-Path $PSScriptRoot ''ProfileHookImplementation.ps1'') @PSBoundParameters -ProfilePaths @(' + $quotedProfiles + ')'))
    $configBefore=[IO.File]::ReadAllBytes((Join-Path $temporary 'adapter-config.json'))
    $stateBefore=[IO.File]::ReadAllBytes((Join-Path $temporary 'state\desktop-profile-installation.json'))
    $profileBefore=@($profiles | ForEach-Object { [Convert]::ToBase64String([IO.File]::ReadAllBytes($_)) })
    $refused=$false
    try { [void](& (Join-Path $temporary 'Install-Adapter.ps1') -ConfigPath $lockConfig) } catch {
        if ($_.Exception.Message -cne 'The managed profile suffix was edited or moved; automatic editing stopped.') { throw }
        $refused=$true
    }
    if (-not $refused) { throw 'Installer accepted an edited profile suffix.' }
    if ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $temporary 'adapter-config.json'))) -cne [Convert]::ToBase64String($configBefore)) { throw 'Refused installer replaced the configuration.' }
    if ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $temporary 'state\desktop-profile-installation.json'))) -cne [Convert]::ToBase64String($stateBefore)) { throw 'Refused installer changed the profile installation record.' }
    if (Test-Path -LiteralPath (Join-Path $temporary 'state\configuration-installation.json')) { throw 'Refused installer created configuration state.' }
    for ($index=0;$index -lt $profiles.Count;$index++) {
        if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($profiles[$index])) -cne $profileBefore[$index]) { throw 'Refused installer changed profile bytes.' }
    }
    [pscustomobject]@{pass=$true;scope='Temporary profiles, local validation fixture and mocked process-list only';checks=@('UTF8 and UTF16 bytes preserved','existing ACL preserved','idempotent installation','ordinary profile environment unchanged','exact rollback','new managed profile removed','edited suffix refused','reparse ancestor rejected','untrusted writer rejected','configuration validation blocks concurrent write and delete','installation preflight creates no state','invalid second profile preserves first profile and adapter ACLs','untrusted missing profile parent refused without writes','top-level refusal preserves configuration, profile bytes and state')}
} catch { throw ('Fixture stage '+$stage+' failed: '+$_.Exception.Message) } finally {
    # Resolve and verify the exact disposable test root before recursive cleanup.
    $resolved=[IO.Path]::GetFullPath($temporary)
    $tempRoot=[IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')+'\'
    if ($resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved) -like 'codex-adapter-profile-test-*') { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
})
