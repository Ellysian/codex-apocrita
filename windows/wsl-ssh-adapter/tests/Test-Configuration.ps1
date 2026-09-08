#requires -Version 7.0
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$adapter = Join-Path $root 'bin\ssh.exe'
$example = [IO.File]::ReadAllText((Join-Path $root 'adapter-config.example.json'))
$testDirectory = Join-Path $PSScriptRoot ('bin\config-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testDirectory -Force | Out-Null
$script:configurationTests = 0
function Check-Configuration([string]$Name, [scriptblock]$Change, [int]$Expected) {
    $config = $example | ConvertFrom-Json
    $config.WindowsSsh = Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\OpenSSH\ssh.exe'
    & $Change $config
    $path = Join-Path $testDirectory ($Name + '.json')
    [IO.File]::WriteAllText($path, ($config | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
    $stdoutPath = Join-Path $testDirectory ($Name + '.stdout.txt')
    $stderrPath = Join-Path $testDirectory ($Name + '.stderr.txt')
    # Match the installer's supported native invocation, with streams kept
    # separate for assertions. Expected exit 64 is test data, not a shell error.
    $PSNativeCommandUseErrorActionPreference = $false
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $adapter --validate-config $path 1>$stdoutPath 2>$stderrPath
        $exitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousPreference }
    $stdout = [IO.File]::ReadAllText($stdoutPath)
    $stderr = [IO.File]::ReadAllText($stderrPath)
    if ($exitCode -ne $Expected) { throw "Configuration case failed: $Name" }
    if ($Expected -eq 0 -and ($stdout.Trim() -ne 'ADAPTER_CONFIG_VALID' -or $stderr.Length -ne 0)) { throw 'Unexpected validation success output.' }
    if ($Expected -ne 0 -and ($stdout.Length -ne 0 -or $stderr -notmatch '^APOCRITA_ADAPTER_REFUSED:')) { throw 'Unexpected validation failure output.' }
    if (($stdout + $stderr).Contains('PRIVATE_TEST_MARKER') -or ($stdout + $stderr).Contains($testDirectory)) { throw 'Validation disclosed caller content or configuration path.' }
    $script:configurationTests++
}
Check-Configuration 'example' { param($c) } 0
Check-Configuration 'optional-fields-absent' { param($c) $c.PSObject.Properties.Remove('MetadataLogging'); $c.PSObject.Properties.Remove('WindowsIdentityPath') } 0
Check-Configuration 'independent-identities-and-port' { param($c) $c.TargetUser = 'remote-user'; $c.TargetPort = 2207; $c.Distribution = 'Example Linux' } 0
Check-Configuration 'metadata-opt-in' { param($c) $c.MetadataLogging = $true } 0
Check-Configuration 'missing-host' { param($c) $c.PSObject.Properties.Remove('TargetHost') } 64
Check-Configuration 'unknown-field' { param($c) $c | Add-Member -NotePropertyName 'PRIVATE_TEST_MARKER' -NotePropertyValue 'synthetic-only' } 64
Check-Configuration 'string-port' { param($c) $c.TargetPort = '22' } 64
Check-Configuration 'string-logging' { param($c) $c.MetadataLogging = 'false' } 64
Check-Configuration 'null-user' { param($c) $c.User = $null } 64
Check-Configuration 'unsupported-path-expansion' { param($c) $c.ControlPath = '/home/researcher/.ssh/master-%h' } 64
Check-Configuration 'wrong-home' { param($c) $c.LinuxHome = '/home/different' } 64
Check-Configuration 'recursion' { param($c) $c.WindowsSsh = $adapter } 64
Check-Configuration 'arbitrary-windows-executor' { param($c) $c.WindowsSsh = 'C:\Users\Example\bin\ssh.exe' } 64
Check-Configuration 'arbitrary-linux-executor' { param($c) $c.LinuxSsh = '/tmp/ssh' } 64
Write-Output "PASS: $script:configurationTests static configuration cases; no WSL, SSH, authentication or network calls."
