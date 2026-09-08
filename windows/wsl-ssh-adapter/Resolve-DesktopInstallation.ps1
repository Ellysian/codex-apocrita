#requires -Version 7.0
function Resolve-CodexDesktopInstallation {
    [CmdletBinding()]
    param()
    Import-Module Appx -UseWindowsPowerShell -WarningAction SilentlyContinue -ErrorAction Stop
    $packages = @(Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop | Where-Object {
        $_.PackageFamilyName -eq 'OpenAI.Codex_2p2nqsd0c76g0' -and
        $_.Publisher -eq 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B' -and
        [string]$_.SignatureKind -eq 'Store' -and [string]$_.Status -eq 'Ok'
    })
    if ($packages.Count -ne 1) { throw 'Expected one healthy current-user registered official Codex Store package.' }
    $package = $packages[0]
    $root = [IO.Path]::GetFullPath([string]$package.InstallLocation).TrimEnd('\')
    $manifestPath = Join-Path $root 'AppxManifest.xml'
    [xml]$manifest = [IO.File]::ReadAllText($manifestPath)
    if ($manifest.Package.Identity.Name -ne $package.Name -or $manifest.Package.Identity.Publisher -ne $package.Publisher -or [string]$manifest.Package.Identity.Version -ne [string]$package.Version) { throw 'Package registration and manifest do not match.' }
    $apps = @($manifest.Package.Applications.Application | Where-Object { $_.Id -eq 'App' -and $_.EntryPoint -eq 'Windows.FullTrustApplication' })
    if ($apps.Count -ne 1 -or [IO.Path]::IsPathRooted([string]$apps[0].Executable)) { throw 'The desktop application manifest requires review.' }
    $exe = [IO.Path]::GetFullPath((Join-Path $root ([string]$apps[0].Executable)))
    if (-not $exe.StartsWith($root+'\', [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($exe) -ine 'ChatGPT.exe' -or -not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'The desktop executable is unavailable or its manifest identity changed.' }
    [pscustomobject]@{ desktopExecutable=$exe; packageFullName=[string]$package.PackageFullName; packageVersion=[string]$package.Version; manifestPath=$manifestPath }
}
