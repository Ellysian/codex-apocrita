#requires -Version 5.1
# Silent, scoped standard-profile hook. Ordinary terminals never get adapter PATH.
# DefinitionsOnly returns a pure guard for local tests; it does not inspect a process.
param([switch]$DefinitionsOnly)
& {
    param([bool]$OnlyDefinitions, [string]$HookRoot)
    function Test-DesktopProfileLease {
        param($Lease, $Observed, [DateTimeOffset]$NowUtc, [string]$AllowedAdapterBin, [string]$ExpectedUserSid)
        function Result([string]$Status, [string]$Decision='IGNORE') { [pscustomobject]@{Status=$Status;Decision=$Decision} }
        function Utc($Value) {
            if ([string]$Value -notmatch '(Z|\+00:00)$') { throw 'UTC required' }
            $date=[DateTimeOffset]::Parse([string]$Value,[Globalization.CultureInfo]::InvariantCulture)
            if ($date.Offset -ne [TimeSpan]::Zero) { throw 'UTC required' }; $date
        }
        function FullPath($Value) {
            $text=[string]$Value
            if ($text -notmatch '^[A-Za-z]:[\\/]' -or $text.Substring(2).Contains(':')) { throw 'Local absolute path required' }
            [IO.Path]::GetFullPath($text).TrimEnd('\','/')
        }
        function SameHash($First,$Second) {
            [string]$First -cmatch '^[A-Fa-f0-9]{64}$' -and [string]$Second -cmatch '^[A-Fa-f0-9]{64}$' -and [string]$First -ieq [string]$Second
        }
        try {
            if ($null -eq $Lease -or $null -eq $Observed) { return Result 'MISSING_METADATA' }
            if ($ExpectedUserSid -notmatch '^S-1-' -or $Observed.CurrentUserSid -cne $ExpectedUserSid -or $Observed.ParentUserSid -cne $ExpectedUserSid) { return Result 'WRONG_USER' }
            if ($Lease.ownerSid -cne $ExpectedUserSid -or $Observed.LeaseOwnerSid -cne $ExpectedUserSid -or $Observed.HookOwnerSid -cne $ExpectedUserSid -or $Observed.FilesTrusted -ne $true) { return Result 'UNTRUSTED_FILES' }
            if ($Lease.version -ne 2 -or [string]$Lease.launchId -cnotmatch '^[a-fA-F0-9]{32}$' -or [string]$Lease.state -cnotin @('PENDING','REGISTERED')) { return Result 'INVALID_LEASE' }
            $requested=Utc $Lease.requestedUtc; $expires=Utc $Lease.expiresUtc; $parentStart=Utc $Observed.ParentStartUtc
            if ($expires -le $requested -or ($expires-$requested).TotalSeconds -gt 60 -or $NowUtc -lt $requested.AddSeconds(-1) -or $NowUtc -ge $expires) { return Result 'EXPIRED_OR_INVALID_WINDOW' }
            if ($parentStart -lt $requested.AddSeconds(-1) -or $parentStart -gt $NowUtc.AddSeconds(1) -or ($NowUtc-$parentStart).TotalSeconds -gt 60) { return Result 'PARENT_START_OUTSIDE_WINDOW' }
            if ([int64]$Observed.ParentProcessId -le 0 -or [int64]$Observed.ShellProcessId -le 0 -or $Observed.ParentProcessId -eq $Observed.ShellProcessId) { return Result 'INVALID_PROCESS_ID' }
            $expectedExe=FullPath $Lease.expectedDesktopExecutable; $actualExe=FullPath $Observed.ParentExecutable
            $package=[string]$Lease.expectedPackageFullName
            if ($package -cnotmatch '^OpenAI\.Codex_\d+\.\d+\.\d+\.\d+_x64__2p2nqsd0c76g0$' -or [IO.Path]::GetFileName($expectedExe) -ine 'ChatGPT.exe' -or [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($expectedExe)) -ine 'app' -or [IO.Path]::GetFileName([IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($expectedExe))) -ine $package -or $Observed.ParentPackageFullName -cne $package) { return Result 'WRONG_DESKTOP_PACKAGE' }
            if ($actualExe -ine $expectedExe) { return Result 'WRONG_DIRECT_PARENT_EXE' }
            if ((FullPath $Lease.adapterBin) -ine (FullPath $AllowedAdapterBin)) { return Result 'WRONG_ADAPTER_PATH' }
            if (-not (SameHash $Lease.adapterSha256 $Observed.AdapterSha256)) { return Result 'ADAPTER_HASH_MISMATCH' }
            if (-not (SameHash $Lease.configSha256 $Observed.ConfigSha256)) { return Result 'CONFIG_HASH_MISMATCH' }
            if ($Lease.state -ceq 'PENDING') {
                if ([int64]$Lease.registeredProcessId -ne 0 -or -not [string]::IsNullOrWhiteSpace([string]$Lease.registeredProcessStartUtc)) { return Result 'PENDING_WITH_REGISTRATION' }
                return Result 'WAITING_FOR_REGISTRATION' 'WAIT'
            }
            if ([int64]$Lease.registeredProcessId -ne [int64]$Observed.ParentProcessId) { return Result 'REGISTERED_PID_MISMATCH' }
            if ((Utc $Lease.registeredProcessStartUtc).UtcTicks -ne $parentStart.UtcTicks) { return Result 'REGISTERED_START_MISMATCH' }
            return Result 'MATCHED_REGISTERED_DESKTOP' 'APPLY'
        } catch { return Result 'INVALID_METADATA' }
    }
    if ($OnlyDefinitions) { return ${function:Test-DesktopProfileLease} }
    $ErrorActionPreference='Stop'; $WarningPreference='SilentlyContinue'; $VerbosePreference='SilentlyContinue'
    $DebugPreference='SilentlyContinue'; $InformationPreference='SilentlyContinue'; $ProgressPreference='SilentlyContinue'
    $changed=$false; $originalPath=$null; $originalMarker=$null
    $timer=[Diagnostics.Stopwatch]::StartNew()
    try {
        $root=[IO.Path]::GetFullPath($HookRoot)
        $state=Join-Path $root 'state'; $leasePath=Join-Path $state 'desktop-environment-lease.json'
        if (-not [IO.File]::Exists($leasePath)) { return }
        # No ancestry search: an ordinary shell nested beneath Desktop is excluded.
        $shell=Get-CimInstance Win32_Process -Filter ('ProcessId='+$PID) -Property ParentProcessId
        $parent=Get-CimInstance Win32_Process -Filter ('ProcessId='+[int]$shell.ParentProcessId) -Property ProcessId,Name,ExecutablePath
        if ($null -eq $parent -or $parent.Name -ine 'ChatGPT.exe') { return }
        # Check the helper path before loading its code, without using that helper.
        $helper=Join-Path $root 'Desktop-LocalFiles.ps1'
        $cursor=$helper
        while ($cursor) {
            if ([IO.File]::GetAttributes($cursor) -band [IO.FileAttributes]::ReparsePoint) { return }
            $next=[IO.Path]::GetDirectoryName($cursor); if ($next -eq $cursor) { break }; $cursor=$next
        }
        $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
        try { $currentSid=$identity.User.Value } finally { $identity.Dispose() }
        $trusted=@($currentSid,'S-1-5-18','S-1-5-32-544')
        $writeMask=[int64]([Security.AccessControl.FileSystemRights]::Write -bor [Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership)
        foreach ($file in @($root,$helper)) {
            $acl=Get-Acl -LiteralPath $file
            if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $currentSid) { return }
            $raw=[Security.AccessControl.RawSecurityDescriptor]::new($acl.GetSecurityDescriptorBinaryForm(),0)
            if ($null -eq $raw.DiscretionaryAcl) { return }
            foreach ($ace in $raw.DiscretionaryAcl) {
                if ($ace -isnot [Security.AccessControl.CommonAce] -or $ace.IsCallback) { return }
                if ($ace.AceQualifier -eq [Security.AccessControl.AceQualifier]::AccessAllowed -and ([int64]$ace.AccessMask -band $writeMask) -ne 0 -and $ace.SecurityIdentifier.Value -notin $trusted) { return }
            }
        }
        . $helper
        $sid=Get-DesktopUserSid
        $hook=Join-Path $root 'Desktop-ShellEnvironment.ps1'; $bin=Join-Path $root 'bin'
        $adapter=Join-Path $bin 'ssh.exe'; $config=Join-Path $root 'adapter-config.json'; $native=Join-Path $root 'src\DesktopShellLaunch.cs'
        foreach ($path in @($root,$state,$leasePath,$hook,$adapter,$config,$native,(Join-Path $root 'Desktop-LocalFiles.ps1'))) {
            Assert-DesktopLocalPath $path -MustExist -Owned
            if (-not (Test-DesktopTrustedWriters $path)) { return }
        }
        function Read-Lease {
            Assert-DesktopLocalPath $leasePath -MustExist -Owned
            if (-not (Test-DesktopTrustedWriters $leasePath) -or (Get-Item -LiteralPath $leasePath).Length -gt 16384) { throw 'Invalid lease file' }
            ConvertFrom-DesktopJson ([IO.File]::ReadAllText($leasePath))
        }
        function Parent-Start([int]$ProcessId) {
            $process=[Diagnostics.Process]::GetProcessById($ProcessId)
            try { $process.StartTime.ToUniversalTime() } finally { $process.Dispose() }
        }
        $lease=Read-Lease; $launchId=[string]$lease.launchId
        if ([string]$parent.ExecutablePath -ine [string]$lease.expectedDesktopExecutable) { return }
        $owner=Invoke-CimMethod -InputObject $parent -MethodName GetOwnerSid
        if ($owner.ReturnValue -ne 0 -or $owner.Sid -cne $sid) { return }
        if ($null -eq ('Apocrita.ProfileGuard.PackageIdentity' -as [type])) { Add-Type -Path $native }
        $started=Parent-Start ([int]$parent.ProcessId)
        $observed=[pscustomobject]@{
            CurrentUserSid=$sid; ParentUserSid=$owner.Sid; LeaseOwnerSid=$sid; HookOwnerSid=$sid; FilesTrusted=$true
            ParentProcessId=[int]$parent.ProcessId; ShellProcessId=$PID; ParentStartUtc=$started.ToString('o')
            ParentExecutable=[string]$parent.ExecutablePath; ParentPackageFullName=[Apocrita.ProfileGuard.PackageIdentity]::Read([uint32]$parent.ProcessId)
            AdapterSha256=(Get-FileHash -LiteralPath $adapter -Algorithm SHA256).Hash; ConfigSha256=(Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash
        }
        $wait=[Diagnostics.Stopwatch]::StartNew()
        do {
            $decision=Test-DesktopProfileLease $lease $observed ([DateTimeOffset]::UtcNow) $bin $sid
            if ($decision.Decision -ne 'WAIT') { break }
            if ($wait.ElapsedMilliseconds -ge 2500 -or $timer.ElapsedMilliseconds -ge 4450) { return }
            Start-Sleep -Milliseconds 50
            $lease=Read-Lease
            if ($lease.launchId -cne $launchId) { return }
        } while ($true)
        if ($decision.Decision -ne 'APPLY') { return }
        if ((Parent-Start ([int]$parent.ProcessId)).Ticks -ne $started.Ticks) { return }
        $lease=Read-Lease
        if ($lease.launchId -cne $launchId -or (Test-DesktopProfileLease $lease $observed ([DateTimeOffset]::UtcNow) $bin $sid).Decision -ne 'APPLY') { return }
        # Hash again immediately before altering this process environment.
        if ((Get-FileHash -LiteralPath $adapter -Algorithm SHA256).Hash -ine $lease.adapterSha256 -or (Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash -ine $lease.configSha256) { return }
        if ($timer.ElapsedMilliseconds -ge 4500) { return }
        $originalPath=[Environment]::GetEnvironmentVariable('Path','Process')
        $originalMarker=[Environment]::GetEnvironmentVariable('APOCRITA_ADAPTER_LAUNCH_ID','Process')
        $remaining=@($originalPath -split ';' | Where-Object { $_.TrimEnd('\') -ine $bin })
        $changed=$true
        [Environment]::SetEnvironmentVariable('Path',($bin+';'+[string]::Join(';',[string[]]$remaining)),'Process')
        [Environment]::SetEnvironmentVariable('APOCRITA_ADAPTER_LAUNCH_ID',$launchId,'Process')
        # Private handshake state, not a transport log or a remote success claim.
        Write-DesktopProtectedJson (Join-Path $state ('desktop-shell-env-'+$launchId+'-'+$PID+'.json')) ([ordered]@{
            status='APPLIED'; launchId=$launchId; parentProcessId=[int]$parent.ProcessId; parentStartUtc=$started.ToString('o'); adapterHashMatches=$true
        })
    } catch {
        if ($changed) {
            try {
                [Environment]::SetEnvironmentVariable('Path',$originalPath,'Process')
                [Environment]::SetEnvironmentVariable('APOCRITA_ADAPTER_LAUNCH_ID',$originalMarker,'Process')
            } catch { }
        }
        # Never emit exception text, profile bodies, process arguments, or environment.
    }
} $DefinitionsOnly.IsPresent $PSScriptRoot
