# Real isolated installation refusals for malformed user hook configurations.
[CmdletBinding()]
param(
    [string]$SourceRoot,
    [string]$ArtifactRoot,
    [string]$ShellPath = ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if (-not $SourceRoot) { $SourceRoot = Split-Path -Parent $PSScriptRoot }
$SourceRoot = [IO.Path]::GetFullPath($SourceRoot)
$workRoot = [IO.Path]::GetFullPath((Join-Path $SourceRoot 'tests\.work'))
if (-not $ArtifactRoot) { $ArtifactRoot = $workRoot }
$ArtifactRoot = [IO.Path]::GetFullPath($ArtifactRoot).TrimEnd('\')
if (-not [string]::Equals($ArtifactRoot,$workRoot,[StringComparison]::OrdinalIgnoreCase) -and
    -not $ArtifactRoot.StartsWith($workRoot + '\',[StringComparison]::OrdinalIgnoreCase)) {
    throw 'Install preflight fixtures must stay inside tests/.work.'
}
$installer = Join-Path $SourceRoot 'install.ps1'
$cli = Join-Path $SourceRoot 'src\safedelete.ps1'
foreach ($required in @($installer,$cli,$ShellPath)) {
    if (-not [IO.File]::Exists($required)) { throw ('Required program is missing: ' + $required) }
}
$run = 'install-preflight-' + $PSVersionTable.PSVersion.Major + '-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8)
$runRoot = Join-Path $ArtifactRoot $run
$childStateRoot = Join-Path $runRoot 'child-state'
$null = [IO.Directory]::CreateDirectory($childStateRoot)
$encoding = New-Object Text.UTF8Encoding($false)
$results = New-Object 'System.Collections.Generic.List[object]'
$script:caseProcesses = New-Object 'System.Collections.Generic.List[object]'

function Assert-True([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Get-Hash([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','') }
    finally { $sha.Dispose(); $stream.Dispose() }
}
function ConvertTo-NativeArgument([string]$Value) {
    if ($Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value,'(\\*)"','$1$1\"')
    $escaped = [regex]::Replace($escaped,'(\\+)$','$1$1')
    return '"' + $escaped + '"'
}
function Invoke-Process([string[]]$Arguments,[string]$WorkingDirectory) {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $ShellPath
    $start.Arguments = (($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $start.WorkingDirectory = $WorkingDirectory
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $start.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    try {
        $null = $process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(60000)) {
            $process.Kill()
            throw 'Isolated installation process timed out after 60 seconds.'
        }
        $result = [pscustomobject]@{ program=$ShellPath; arguments=$Arguments; exitCode=$process.ExitCode; stdout=$stdoutTask.Result; stderr=$stderrTask.Result }
        $script:caseProcesses.Add($result)
        return $result
    } finally { $process.Dispose() }
}
function Get-PlainProcessError([string]$Message) {
    $plain = $Message -replace '\x1B\[[0-?]*[ -/]*[@-~]', ''
    $lines = @($plain -split '\r?\n' | ForEach-Object { $_ -replace '^\s*(?:\d+\s*)?\|\s*', '' })
    return (($lines -join ' ') -replace '\s+', ' ').Trim()
}
function Get-FixtureSnapshot([string]$Root) {
    return @(Get-ChildItem -LiteralPath $Root -Recurse -Force | ForEach-Object {
        [pscustomobject]@{ path=$_.FullName; directory=$_.PSIsContainer; hash=$(if ($_.PSIsContainer) { $null } else { Get-Hash $_.FullName }) }
    })
}
function Assert-FixtureUnchanged([string]$Root,[object[]]$Before) {
    $after = @(Get-FixtureSnapshot $Root)
    Assert-True ($after.Count -eq $Before.Count) 'Refused installation changed the fixture entry count.'
    foreach ($entry in $Before) {
        $matches = @($after | Where-Object { $_.path -ceq $entry.path })
        Assert-True ($matches.Count -eq 1 -and $matches[0].directory -eq $entry.directory -and $matches[0].hash -ceq $entry.hash) ('Refused installation changed ' + $entry.path)
    }
}

# The child invokes the real source installer and records its own process PATH
# in addition to the parent/User PATH checks. Evidence files live outside each
# fixture so writing test evidence cannot mask an installation-side mutation.
$driver = Join-Path $runRoot 'invoke-install.ps1'
$driverText = @'
[CmdletBinding()]
param([string]$InstallScript,[string]$CodexHome,[string]$InstallDir,[string]$EvidencePath)
$ErrorActionPreference = 'Stop'
$processPathBefore = $env:Path
$userPathBefore = [Environment]::GetEnvironmentVariable('Path','User')
$status = 0
$errorCommand = ''
try {
    & $InstallScript -CodexHome $CodexHome -InstallDir $InstallDir -NoPathUpdate
} catch {
    $status = 1
    $errorCommand = $_.InvocationInfo.MyCommand.Name
    Write-Error -ErrorRecord $_ -ErrorAction Continue
} finally {
    $state = [pscustomobject]@{
        runtime=$PSVersionTable.PSVersion.ToString()
        errorCommand=$errorCommand
        processPathUnchanged=[string]::Equals($env:Path,$processPathBefore,[StringComparison]::Ordinal)
        userPathUnchanged=[string]::Equals([Environment]::GetEnvironmentVariable('Path','User'),$userPathBefore,[StringComparison]::Ordinal)
    }
    [IO.File]::WriteAllText($EvidencePath,(ConvertTo-Json -InputObject $state -Compress),(New-Object Text.UTF8Encoding($false)))
}
exit $status
'@
[IO.File]::WriteAllText($driver,$driverText,$encoding)
$cases = @(
    @{ name='invalid JSON'; slug='invalid-json'; hooks='{"hooks":invalid}'; expected='' },
    @{ name='single-element top-level array'; slug='top-array'; hooks='[{"hooks":{}}]'; expected='hooks.json must be a JSON object' },
    @{ name='hooks is not an object'; slug='hooks-scalar'; hooks='{"hooks":"invalid"}'; expected='hooks.json hooks must be an object' },
    @{ name='PreToolUse is not an array'; slug='pretooluse-object'; hooks='{"hooks":{"PreToolUse":{}}}'; expected='hooks.json PreToolUse must be an array' },
    @{ name='command is not a string'; slug='command-number'; hooks='{"hooks":{"PreToolUse":[{"matcher":"^Read$","hooks":[{"type":"command","command":123}]}]}}'; expected='hooks.json PreToolUse command fields must be strings' }
)
$installerHash = Get-Hash $installer
$cliHash = Get-Hash $cli
foreach ($case in $cases) {
    $script:caseProcesses.Clear()
    $evidence = $null
    $errorMessage = $null
    $status = 'PASS'
    try {
        $root = Join-Path $runRoot $case.slug
        $store = Join-Path $root '.codex-safedelete'
        $codexHome = Join-Path $root 'codex-home'
        $installDir = Join-Path $root 'installed'
        $null = [IO.Directory]::CreateDirectory($store)
        $null = [IO.Directory]::CreateDirectory($codexHome)
        $configPath = Join-Path $codexHome 'config.toml'
        $hooksPath = Join-Path $codexHome 'hooks.json'
        [IO.File]::WriteAllText($configPath,"# preserve original configuration`r`nmodel = `"fixture-model`"`r`n",$encoding)
        [IO.File]::WriteAllText($hooksPath,$case.hooks,$encoding)
        $seedPath = Join-Path $root 'previous.bin'
        [IO.File]::WriteAllBytes($seedPath,[byte[]]@(0,1,2,255,0,128,10))
        $seed = Invoke-Process @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$cli,'-Action','delete','-ProjectRoot',$root,'-Paths',$seedPath,'-Command','rm previous.bin') $root
        Assert-True ($seed.exitCode -eq 0 -and -not [IO.File]::Exists($seedPath)) 'Could not create a real recoverable history fixture.'
        $historyPath = Join-Path $store 'history.json'
        Assert-True ([IO.File]::Exists($historyPath)) 'Seed deletion did not create recovery history.'
        $payloadFiles = @(Get-ChildItem -LiteralPath (Join-Path $store 'trash') -Recurse -Force -File)
        Assert-True ($payloadFiles.Count -eq 1) 'Seed deletion did not create exactly one recoverable payload.'
        $configBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath))
        $hooksBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($hooksPath))
        $snapshot = @(Get-FixtureSnapshot $root)
        $userPathBefore = [Environment]::GetEnvironmentVariable('Path','User')
        $processPathBefore = $env:Path
        $childStatePath = Join-Path $childStateRoot ($case.slug + '.json')
        $blocked = Invoke-Process @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$driver,'-InstallScript',$installer,'-CodexHome',$codexHome,'-InstallDir',$installDir,'-EvidencePath',$childStatePath) $root
        Assert-True ($blocked.exitCode -ne 0) 'Malformed hooks configuration was accepted by installation.'
        $message = Get-PlainProcessError $blocked.stderr
        Assert-True (-not [string]::IsNullOrWhiteSpace($message)) 'Refused installation did not explain its preflight failure.'
        if ($case.expected) { Assert-True ($message.Contains($case.expected)) ('Installation did not report the expected configuration preflight failure: ' + $message) }
        Assert-True (-not (Test-Path -LiteralPath $installDir)) 'Installation created InstallDir before refusing malformed hooks.'
        Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath)) -ceq $configBytes) 'Refused installation changed config.toml bytes.'
        Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($hooksPath)) -ceq $hooksBytes) 'Refused installation changed hooks.json bytes.'
        Assert-FixtureUnchanged $root $snapshot
        Assert-True ([string]::Equals([Environment]::GetEnvironmentVariable('Path','User'),$userPathBefore,[StringComparison]::Ordinal)) 'Refused installation changed User PATH.'
        Assert-True ([string]::Equals($env:Path,$processPathBefore,[StringComparison]::Ordinal)) 'Refused installation changed parent process PATH.'
        Assert-True ([IO.File]::Exists($childStatePath)) 'Child process PATH evidence is missing.'
        $childState = [IO.File]::ReadAllText($childStatePath) | ConvertFrom-Json
        Assert-True ($childState.processPathUnchanged -and $childState.userPathUnchanged) 'Refused installation changed child process or User PATH.'
        if ($case.slug -eq 'invalid-json') { Assert-True ($childState.errorCommand -eq 'ConvertFrom-Json') 'Invalid JSON was not refused by the real JSON parser.' }
        $evidence = [pscustomobject]@{
            fixture=$root; installerExitCode=$blocked.exitCode; childRuntime=$childState.runtime; errorCommand=$childState.errorCommand
            installDirCreated=$false; configurationBytesUnchanged=$true; hooksBytesUnchanged=$true
            preservedEntryCount=$snapshot.Count; historyHash=(Get-Hash $historyPath); payloadHash=(Get-Hash $payloadFiles[0].FullName)
            historyAndPayloadUnchanged=$true; userPathUnchanged=$true; parentProcessPathUnchanged=$true; childProcessPathUnchanged=$true
        }
    } catch { $status = 'FAIL'; $errorMessage = $_.Exception.Message }
    $results.Add([pscustomobject]@{ name=$case.name; result=$status; error=$errorMessage; evidence=$evidence; processes=@($script:caseProcesses.ToArray()) })
}
$failed = @($results | Where-Object { $_.result -eq 'FAIL' }).Count
$sourceUnchanged = (Get-Hash $installer) -ceq $installerHash -and (Get-Hash $cli) -ceq $cliHash
if (-not $sourceUnchanged) { $failed++ }
$reportPath = Join-Path $runRoot 'report.json'
$report = [pscustomobject]@{
    result=$(if ($failed -eq 0) { 'PASS' } else { 'FAIL' }); runtime=$PSVersionTable.PSVersion.ToString(); childShell=$ShellPath
    tested_at=[DateTime]::UtcNow.ToString('o'); total=$results.Count; passed=@($results | Where-Object { $_.result -eq 'PASS' }).Count
    failed=$failed; sourceUnchanged=$sourceUnchanged; installer_sha256=$installerHash; cli_sha256=$cliHash; tests=@($results.ToArray()); fixtures=$runRoot
}
[IO.File]::WriteAllText($reportPath,(ConvertTo-Json -InputObject $report -Depth 8),$encoding)
[pscustomobject]@{ result=$report.result; runtime=$report.runtime; total=$report.total; passed=$report.passed; failed=$failed; report=$reportPath } | ConvertTo-Json -Compress
if ($failed -gt 0) { exit 1 }
