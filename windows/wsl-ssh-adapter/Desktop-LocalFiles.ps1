#requires -Version 5.1
# Local metadata helpers. Never read SSH keys, authentication tokens or profiles for logging.
function ConvertFrom-DesktopJson([string]$Json) {
    if ($PSVersionTable.PSVersion -ge [version]'7.5') { return ConvertFrom-Json -InputObject $Json -DateKind String }
    ConvertFrom-Json -InputObject $Json
}
function Get-DesktopUserSid {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { $identity.User.Value } finally { $identity.Dispose() }
}
function Assert-DesktopLocalPath([string]$Path, [switch]$MustExist, [switch]$Owned) {
    if ($Path -notmatch '^[A-Za-z]:[\\/]' -or $Path.Substring(2).Contains(':')) { throw 'A local absolute Windows path is required.' }
    $full = [IO.Path]::GetFullPath($Path)
    $cursor = $full
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse points are not supported for adapter or profile paths.' }
        }
        $next = [IO.Path]::GetDirectoryName($cursor)
        if ($next -eq $cursor) { break }; $cursor = $next
    }
    if ($MustExist -and -not (Test-Path -LiteralPath $full)) { throw 'Required local path is missing.' }
    if ($Owned -and (Test-Path -LiteralPath $full)) {
        $owner = (Get-Acl -LiteralPath $full).GetOwner([Security.Principal.SecurityIdentifier]).Value
        if ($owner -ne (Get-DesktopUserSid)) { throw 'The local file or directory must belong to the current Windows user.' }
    }
}
function Test-DesktopTrustedWriters([string]$Path) {
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $allowed = @((Get-DesktopUserSid), 'S-1-5-18', 'S-1-5-32-544')
    $mask = [int64]([Security.AccessControl.FileSystemRights]::Write -bor [Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership)
    $raw = [Security.AccessControl.RawSecurityDescriptor]::new($acl.GetSecurityDescriptorBinaryForm(), 0)
    if ($null -eq $raw.DiscretionaryAcl) { return $false }
    foreach ($ace in $raw.DiscretionaryAcl) {
        if ($ace -isnot [Security.AccessControl.CommonAce] -or $ace.IsCallback) { return $false }
        if ($ace.AceQualifier -eq [Security.AccessControl.AceQualifier]::AccessAllowed -and ([int64]$ace.AccessMask -band $mask) -ne 0 -and $ace.SecurityIdentifier.Value -notin $allowed) { return $false }
    }
    return $true
}
function Protect-DesktopLocalFile([string]$Path) {
    Assert-DesktopLocalPath $Path -MustExist -Owned
    $item = Get-Item -LiteralPath $Path -Force
    # Request only access/owner information, never a SACL or SeSecurityPrivilege.
    $sections=[Security.AccessControl.AccessControlSections]::Access -bor [Security.AccessControl.AccessControlSections]::Owner
    if ($PSVersionTable.PSEdition -eq 'Core') {
        if ($item.PSIsContainer) { $acl=[IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]$item,$sections) }
        else { $acl=[IO.FileSystemAclExtensions]::GetAccessControl([IO.FileInfo]$item,$sections) }
    } else { $acl=$item.GetAccessControl($sections) }
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]))) { [void]$acl.RemoveAccessRuleSpecific($rule) }
    foreach ($sid in @((Get-DesktopUserSid), 'S-1-5-18', 'S-1-5-32-544')) {
        $identity = [Security.Principal.SecurityIdentifier]::new($sid)
        if ($item.PSIsContainer) {
            $rule = [Security.AccessControl.FileSystemAccessRule]::new($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        } else { $rule = [Security.AccessControl.FileSystemAccessRule]::new($identity, 'FullControl', 'Allow') }
        [void]$acl.AddAccessRule($rule)
    }
    if ($PSVersionTable.PSEdition -eq 'Core') {
        if ($item.PSIsContainer) { [IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]$item,[Security.AccessControl.DirectorySecurity]$acl) }
        else { [IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]$item,[Security.AccessControl.FileSecurity]$acl) }
    } else { $item.SetAccessControl($acl) }
}
function Initialize-DesktopStateDirectory([string]$Root) {
    Assert-DesktopLocalPath $Root -MustExist -Owned
    $directory = Join-Path $Root 'state'
    Assert-DesktopLocalPath $directory -Owned
    if (-not (Test-Path -LiteralPath $directory)) { [void][IO.Directory]::CreateDirectory($directory) }
    Protect-DesktopLocalFile $directory
    $directory
}
function Write-DesktopProtectedBytes([string]$Path, [byte[]]$Bytes) {
    Assert-DesktopLocalPath $Path -Owned
    $parent = Split-Path $Path -Parent
    Assert-DesktopLocalPath $parent -MustExist -Owned
    if (-not (Test-DesktopTrustedWriters $parent)) { throw 'Destination directory permits untrusted writers.' }
    if (Test-Path -LiteralPath $Path) {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'Expected a regular destination file.' }
        if (-not (Test-DesktopTrustedWriters $Path)) { throw 'Destination file permits untrusted writers.' }
    }
    $temporary = Join-Path $parent ('adapter-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllBytes($temporary, $Bytes)
        Protect-DesktopLocalFile $temporary
        Assert-DesktopLocalPath $Path -Owned
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}
function Write-DesktopProtectedJson([string]$Path, $Value) {
    Write-DesktopProtectedBytes $Path ([Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 8)))
}
function Assert-DesktopStopped {
    if (@(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue).Count -gt 0) {
        throw 'Save work and use the normal desktop Quit action first. This operation never stops a running desktop or remote task.'
    }
}
