# Isolated installation-location and legacy-cache migration checks. Synthetic
# package paths exercise recovery rules; they do not claim a second MSIX host.
[CmdletBinding()]
param(
    [string]$SourceRoot,
    [string]$ArtifactRoot,
    [string]$ShellPath = ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName),
    [string]$CaseFilter = '*'
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
    throw 'Installation-location fixtures must stay inside tests/.work.'
}
foreach ($required in @((Join-Path $SourceRoot 'install.ps1'),(Join-Path $SourceRoot 'src\InstallState.ps1'),$ShellPath)) {
    if (-not [IO.File]::Exists($required)) { throw ('Required program is missing: ' + $required) }
}
. (Join-Path $SourceRoot 'src\InstallState.ps1')
$encoding = New-Object Text.UTF8Encoding($false)
$runId = 'install-location-' + $PSVersionTable.PSVersion.Major + '-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8)
$runRoot = Join-Path $ArtifactRoot $runId
$null = [IO.Directory]::CreateDirectory($runRoot)
$results = New-Object 'System.Collections.Generic.List[object]'
$script:caseProcesses = New-Object 'System.Collections.Generic.List[object]'
$userPathBefore = [Environment]::GetEnvironmentVariable('Path','User')
$processPathBefore = $env:Path

function Assert-True([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Get-Hash([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','') }
    finally { $sha.Dispose(); $stream.Dispose() }
}
function Write-Json([string]$Path,$Value) {
    [IO.File]::WriteAllText($Path,(ConvertTo-Json -InputObject $Value -Depth 12),$encoding)
}
function ConvertTo-NativeArgument([string]$Value) {
    if ($Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value,'(\\*)"','$1$1\"')
    $escaped = [regex]::Replace($escaped,'(\\+)$','$1$1')
    return '"' + $escaped + '"'
}
function Invoke-Process([string[]]$Arguments,$Fixture) {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $ShellPath
    $start.Arguments = (($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $start.WorkingDirectory = $Fixture.project
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = $encoding
    $start.StandardErrorEncoding = $encoding
    $start.EnvironmentVariables['USERPROFILE'] = $Fixture.profile
    $start.EnvironmentVariables['LOCALAPPDATA'] = $Fixture.localAppData
    $start.EnvironmentVariables['CODEX_HOME'] = $Fixture.codexHome
    $start.EnvironmentVariables['TEMP'] = $Fixture.tempRoot
    $start.EnvironmentVariables['TMP'] = $Fixture.tempRoot
    if ($Fixture.PSObject.Properties['testEnvironment']) {
        foreach ($name in $Fixture.testEnvironment.Keys) {
            if (-not $name.StartsWith('SAFEDELETE_TEST_',[StringComparison]::Ordinal)) { throw 'Invalid fixture-only environment name.' }
            $start.EnvironmentVariables[$name] = [string]$Fixture.testEnvironment[$name]
        }
    }
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    try {
        $null = $process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(90000)) { $process.Kill(); throw 'Isolated installation-location process timed out.' }
        $result = [pscustomobject]@{ program=$ShellPath; arguments=$Arguments; exitCode=$process.ExitCode; stdout=$stdoutTask.Result; stderr=$stderrTask.Result }
        $script:caseProcesses.Add($result)
        return $result
    } finally { $process.Dispose() }
}
function Invoke-Install($Fixture,[string]$InstallDir,[string]$Source=$SourceRoot) {
    $arguments = @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $Source 'install.ps1'),'-CodexHome',$Fixture.codexHome,'-NoPathUpdate')
    if ($InstallDir) { $arguments += @('-InstallDir',$InstallDir) }
    return Invoke-Process $arguments $Fixture
}
function Invoke-Uninstall($Fixture,[string]$InstallDir) {
    $arguments = @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $SourceRoot 'uninstall.ps1'),'-CodexHome',$Fixture.codexHome,'-NoPathUpdate')
    if ($InstallDir) { $arguments += @('-InstallDir',$InstallDir) }
    return Invoke-Process $arguments $Fixture
}
function Get-Snapshot([string]$Root) {
    # Starting PS5/PS7 writes these performance caches even with -NoProfile.
    # They are not installer output; all installation/configuration files and
    # other fixture entries remain in the byte-for-byte ownership assertions.
    return @(Get-ChildItem -LiteralPath $Root -Recurse -Force | Where-Object {
        $_.FullName -notmatch '(?i)\\AppData\\Local\\Microsoft\\(?:Windows\\)?PowerShell\\StartupProfileData-NonInteractive$'
    } | ForEach-Object {
        [pscustomobject]@{ path=$_.FullName; directory=$_.PSIsContainer; hash=$(if ($_.PSIsContainer) { $null } else { Get-Hash $_.FullName }) }
    })
}
function Assert-Unchanged([string]$Root,[object[]]$Before) {
    $after = @(Get-Snapshot $Root)
    Assert-True ($after.Count -eq $Before.Count) 'Refused migration changed the fixture entry count.'
    foreach ($entry in $Before) {
        $matches = @($after | Where-Object { $_.path -ceq $entry.path })
        Assert-True ($matches.Count -eq 1 -and $matches[0].directory -eq $entry.directory -and $matches[0].hash -ceq $entry.hash) ('Refused migration changed ' + $entry.path)
    }
}
function New-Fixture([string]$Name) {
    $root = Join-Path $runRoot $Name
    $profile = Join-Path $root 'profile with spaces'
    $localAppData = Join-Path $profile 'AppData\Local'
    $codexHome = Join-Path $root 'custom-codex-home'
    $project = Join-Path $root 'project'
    $tempRoot = Join-Path $root 'temporary-sdk-home'
    foreach ($directory in @($localAppData,$codexHome,$tempRoot,(Join-Path $project '.codex-safedelete'))) { $null = [IO.Directory]::CreateDirectory($directory) }
    $configPath = Join-Path $codexHome 'config.toml'
    $hooksPath = Join-Path $codexHome 'hooks.json'
    [IO.File]::WriteAllText($configPath,"# isolated user settings`r`n",$encoding)
    $baselineHooks = '{"hooks":{"PreToolUse":[{"matcher":"^ForeignBefore$","hooks":[{"type":"command","command":"echo foreign-before","timeout":11,"statusMessage":"foreign before"}]},{"matcher":"^ForeignAfter$","hooks":[{"type":"command","command":"echo foreign-after","timeout":12,"statusMessage":"foreign after"}]}]},"description":"fixture baseline"}'
    [IO.File]::WriteAllText($hooksPath,$baselineHooks,$encoding)
    return [pscustomobject]@{
        root=$root; profile=$profile; localAppData=$localAppData; codexHome=$codexHome; project=$project; tempRoot=$tempRoot
        logicalLegacy=(Join-Path $localAppData 'CodexSafeDelete')
        physicalLegacy=(Join-Path $localAppData 'Packages\OpenAI.Codex_fixturefamily\LocalCache\Local\CodexSafeDelete')
        defaultInstall=(Join-Path $profile '.codex-safedelete-app')
        configPath=$configPath; hooksPath=$hooksPath; configBaseline=(Get-Hash $configPath); hooksBaseline=(Get-Hash $hooksPath)
    }
}
function Copy-Tree([string]$From,[string]$To) {
    $null = [IO.Directory]::CreateDirectory($To)
    foreach ($entry in @(Get-ChildItem -LiteralPath $From -Recurse -Force)) {
        Assert-True (-not ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) 'Fixture unexpectedly contains a reparse point.'
        $relative = $entry.FullName.Substring($From.Length + 1)
        $target = Join-Path $To $relative
        if ($entry.PSIsContainer) { $null = [IO.Directory]::CreateDirectory($target) }
        else { $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)); [IO.File]::Copy($entry.FullName,$target) }
    }
}
function Remove-FixtureDirectory([string]$Path) {
    $absolute = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    Assert-True ($absolute.StartsWith($runRoot + '\',[StringComparison]::OrdinalIgnoreCase)) 'Fixture cleanup escaped its run directory.'
    Remove-Item -LiteralPath $absolute -Recurse -Force
}
function New-LegacyFixture([string]$Name,[bool]$Physical=$true,[bool]$ProtectionEnabled=$true,[string]$ConfigSuffix='',[bool]$KeepInstalledReference=$false) {
    $fixture = New-Fixture $Name
    if ($ConfigSuffix) { [IO.File]::AppendAllText($fixture.configPath,$ConfigSuffix,$encoding); $fixture.configBaseline=Get-Hash $fixture.configPath }
    $installed = Invoke-Install $fixture $fixture.logicalLegacy
    Assert-True ($installed.exitCode -eq 0) 'Could not construct a real isolated legacy installation; see process evidence.'
    $statePath = Join-Path $fixture.logicalLegacy 'install-state.json'
    $state = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json
    $hooks = [IO.File]::ReadAllText($fixture.hooksPath) | ConvertFrom-Json
    Assert-True (@($hooks.hooks.PreToolUse).Count -eq 3) 'Legacy fixture does not have one SafeDelete and two foreign hook groups.'
    $hooks.hooks.PreToolUse = @($hooks.hooks.PreToolUse[0],$hooks.hooks.PreToolUse[2],$hooks.hooks.PreToolUse[1])
    Write-Json $fixture.hooksPath $hooks
    foreach ($snapshot in @($state.snapshots)) { $snapshot.installed_hash = Get-Hash $snapshot.path }
    $referencePath = Join-Path $fixture.logicalLegacy 'backup\installed-config.toml'
    if ($KeepInstalledReference) {
        $configSnapshot = @($state.snapshots | Where-Object { $_.name -ceq 'config.toml' })[0]
        Assert-True ($configSnapshot.installed_reference_hash -ceq $configSnapshot.installed_hash -and (Get-Hash $referencePath) -ceq $configSnapshot.installed_hash) 'Legacy reference fixture does not match the actual installed configuration.'
    } else {
        # The legacy runtime predates the independent installed-config reference.
        # Keep its original baseline backup, and remove only this newer feature.
        foreach ($snapshot in @($state.snapshots)) { if ($snapshot.PSObject.Properties['installed_reference_hash']) { $snapshot.PSObject.Properties.Remove('installed_reference_hash') } }
        $absoluteReference = [IO.Path]::GetFullPath($referencePath)
        Assert-True ($absoluteReference.StartsWith($runRoot + '\',[StringComparison]::OrdinalIgnoreCase)) 'Legacy reference removal escaped its run directory.'
        if ([IO.File]::Exists($absoluteReference)) { Remove-Item -LiteralPath $absoluteReference -Force }
    }
    Write-Json $statePath $state
    Write-Json (Join-Path $fixture.logicalLegacy 'protection-state.json') ([pscustomobject]@{enabled=$ProtectionEnabled})
    if ($Physical) { Copy-Tree $fixture.logicalLegacy $fixture.physicalLegacy; Remove-FixtureDirectory $fixture.logicalLegacy }
    $legacy = if ($Physical) { $fixture.physicalLegacy } else { $fixture.logicalLegacy }
    $fixture | Add-Member NoteProperty legacy $legacy
    $fixture | Add-Member NoteProperty legacyStatePath (Join-Path $legacy 'install-state.json')
    $fixture | Add-Member NoteProperty legacyStateHash (Get-Hash (Join-Path $legacy 'install-state.json'))
    $fixture | Add-Member NoteProperty legacyHookCommand $state.hook_command
    $fixture | Add-Member NoteProperty protectionEnabled $ProtectionEnabled
    return $fixture
}
function Assert-Baseline($Fixture) {
    if ($null -eq $Fixture.configBaseline) { Assert-True (-not (Test-Path -LiteralPath $Fixture.configPath)) 'Uninstall did not restore the originally absent config.toml.' }
    else { Assert-True ((Get-Hash $Fixture.configPath) -ceq $Fixture.configBaseline) 'Uninstall did not restore original config.toml bytes.' }
    Assert-True ((Get-Hash $Fixture.hooksPath) -ceq $Fixture.hooksBaseline) 'Uninstall did not restore original hooks.json bytes.'
    Assert-True ([string]::Equals([Environment]::GetEnvironmentVariable('Path','User'),$userPathBefore,[StringComparison]::Ordinal)) 'Isolated operation changed real User PATH.'
    Assert-True ([string]::Equals($env:Path,$processPathBefore,[StringComparison]::Ordinal)) 'Isolated operation changed parent process PATH.'
}
function Get-DesktopPipeSuffix([string]$Pipe) {
    return "`r`n[mcp_servers.fixture]`r`ncommand = 'cmd.exe'`r`nargs = ['/d', '/c', 'exit 0']`r`nenabled = false`r`n[mcp_servers.fixture.env]`r`nSKY_CUA_NATIVE_PIPE_DIRECTORY = '\\.\pipe\codex-computer-use-" + $Pipe + "'`r`n"
}
function New-SourceFixture([string]$Name) {
    $copy = Join-Path $runRoot $Name
    foreach ($relative in @(@('install.ps1') + @(Get-SafeDeleteInstallManifest))) {
        if ($relative -eq 'safedelete.cmd') { continue }
        $target = Join-Path $copy $relative
        $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
        [IO.File]::Copy((Join-Path $SourceRoot $relative),$target)
    }
    return $copy
}
function Assert-InstalledReference($Fixture,[bool]$OriginalExisted) {
    $state = [IO.File]::ReadAllText((Join-Path $Fixture.defaultInstall 'install-state.json')) | ConvertFrom-Json
    Assert-SafeDeleteInstallState $state $Fixture.defaultInstall
    $configSnapshot = @($state.snapshots | Where-Object { $_.name -ceq 'config.toml' })[0]
    $referencePath = Join-Path $Fixture.defaultInstall 'backup\installed-config.toml'
    Assert-True ($configSnapshot.existed -eq $OriginalExisted) 'Fresh installation recorded the wrong original configuration existence.'
    Assert-True ($configSnapshot.installed_reference_hash -ceq $configSnapshot.installed_hash -and (Get-Hash $referencePath) -ceq $configSnapshot.installed_hash -and (Get-Hash $Fixture.configPath) -ceq $configSnapshot.installed_hash) 'Installed configuration reference was not captured from the real installed configuration.'
    if ($OriginalExisted) { Assert-True ((Get-Hash (Join-Path $Fixture.defaultInstall 'backup\config.toml')) -ceq $Fixture.configBaseline) 'Installed reference replaced the original uninstall backup.' }
    else { Assert-True (-not (Test-Path -LiteralPath (Join-Path $Fixture.defaultInstall 'backup\config.toml'))) 'Fresh installation created an original backup for an absent configuration.' }
    return $referencePath
}
function Assert-Migrated($Fixture) {
    $statePath = Join-Path $Fixture.defaultInstall 'install-state.json'
    Assert-True ([IO.File]::Exists($statePath)) 'Migration did not create shared destination installation state.'
    $state = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json
    Assert-SafeDeleteInstallState $state $Fixture.defaultInstall
    Assert-True ($state.phase -ceq 'complete' -and $state.codex_home -ceq $Fixture.codexHome) 'Migrated installation identity is incomplete or wrong.'
    Assert-True ($state.path_updated -is [bool] -and -not $state.path_updated) 'NoPathUpdate migration recorded ownership of the real User PATH.'
    foreach ($relative in @(Get-SafeDeleteInstallManifest)) { Assert-True ([IO.File]::Exists((Join-Path $Fixture.defaultInstall $relative))) ('Migration omitted ' + $relative) }
    foreach ($snapshot in @($state.snapshots)) {
        Assert-True ((Get-Hash $snapshot.path) -ceq $snapshot.installed_hash) 'Migrated installed configuration hash is incorrect.'
        Assert-True ((Get-Hash (Join-Path $Fixture.defaultInstall ('backup\' + $snapshot.name))) -ceq $snapshot.original_hash) 'Migration lost the original pre-installation backup.'
    }
    $hooks = [IO.File]::ReadAllText($Fixture.hooksPath) | ConvertFrom-Json
    $groups = @($hooks.hooks.PreToolUse)
    Assert-True ($groups.Count -eq 3) 'Migration added or removed hook groups.'
    Assert-True ($groups[0].matcher -ceq '^ForeignBefore$' -and $groups[0].hooks[0].command -ceq 'echo foreign-before' -and $groups[0].hooks[0].timeout -eq 11 -and $groups[0].hooks[0].statusMessage -ceq 'foreign before') 'Migration changed the first foreign hook or its position.'
    Assert-True ($groups[2].matcher -ceq '^ForeignAfter$' -and $groups[2].hooks[0].command -ceq 'echo foreign-after' -and $groups[2].hooks[0].timeout -eq 12 -and $groups[2].hooks[0].statusMessage -ceq 'foreign after') 'Migration changed the last foreign hook or its position.'
    Assert-True ($groups[1].matcher -ceq '^(Bash|apply_patch)$' -and $groups[1].hooks[0].command -ceq $state.hook_command -and $state.hook_command -cne $Fixture.legacyHookCommand) 'Migration did not replace exactly the original SafeDelete command in place.'
    Assert-True ($hooks.description -ceq 'fixture baseline') 'Migration changed unrelated hook metadata.'
    $protection = [IO.File]::ReadAllText((Join-Path $Fixture.defaultInstall 'protection-state.json')) | ConvertFrom-Json
    Assert-True ($protection.enabled -eq $Fixture.protectionEnabled) 'Migration changed the protection switch.'
    $oldState = [IO.File]::ReadAllText($Fixture.legacyStatePath) | ConvertFrom-Json
    Assert-True ($oldState.phase -ceq 'migrated') 'Legacy installation was not marked migrated.'
    return [pscustomobject]@{ fixture=$Fixture.root; legacy=$Fixture.legacy; destination=$Fixture.defaultInstall; hookGroupCount=$groups.Count; foreignHooksAndPositionsPreserved=$true; originalBackupsPreserved=$true; protectionEnabled=$protection.enabled }
}
function Invoke-Case([string]$Name,[scriptblock]$Body) {
    if ($Name -notlike $CaseFilter) { return }
    $script:caseProcesses = New-Object 'System.Collections.Generic.List[object]'
    $status = 'PASS'; $errorMessage = $null; $evidence = $null
    try { $evidence = & $Body } catch { $status = 'FAIL'; $errorMessage = $_.Exception.Message }
    $results.Add([pscustomobject]@{ name=$Name; result=$status; error=$errorMessage; evidence=$evidence; processes=@($script:caseProcesses.ToArray()) })
}
$sourceHashes = @(@('install.ps1','uninstall.ps1','src\InstallState.ps1','src\Storage.ps1','hooks\Trust.ps1','hooks\pre-tool-use.ps1') | ForEach-Object { [pscustomobject]@{ path=$_; hash=(Get-Hash (Join-Path $SourceRoot $_)) } })
. (Join-Path $PSScriptRoot 'helpers\trust-concurrency.ps1')

Invoke-Case 'default uses a profile directory outside AppData and custom CodexHome' {
    $fixture = New-Fixture 'default-helper'
    $chosen = Get-SafeDeleteDefaultInstallDir -UserProfile $fixture.profile
    Assert-True ($chosen -ceq $fixture.defaultInstall) 'Default installation location is not the profile-level shared directory.'
    Assert-True (-not $chosen.StartsWith($fixture.localAppData + '\',[StringComparison]::OrdinalIgnoreCase) -and -not $chosen.StartsWith($fixture.codexHome + '\',[StringComparison]::OrdinalIgnoreCase)) 'Default location depends on AppData or CodexHome.'
    $explicit = Join-Path $fixture.root 'explicit-installation'
    Assert-True ((Resolve-SafeDeleteInstallDirectory -InstallDir $explicit -CodexHome $fixture.codexHome) -ceq $explicit) 'Explicit installation location was overridden.'
    [pscustomobject]@{ selected=$chosen; logicalAppData=$fixture.localAppData; customCodexHome=$fixture.codexHome; appDataIndependent=$true; explicitInstallDirPreserved=$true }
}
Invoke-Case 'legacy candidates include logical AppData and only known Codex package caches' {
    $fixture = New-Fixture 'legacy-candidates'
    $foreign = Join-Path $fixture.localAppData 'Packages\Unrelated.Package_fixturefamily\LocalCache\Local\CodexSafeDelete'
    foreach ($directory in @($fixture.logicalLegacy,$fixture.physicalLegacy,$foreign)) { $null = [IO.Directory]::CreateDirectory($directory) }
    $candidates = @(Get-SafeDeleteLegacyInstallCandidates -UserProfile $fixture.profile -LocalAppData $fixture.localAppData)
    Assert-True ($candidates.Count -eq 2 -and $fixture.logicalLegacy -cin $candidates -and $fixture.physicalLegacy -cin $candidates -and $foreign -cnotin $candidates) 'Candidate enumeration used the wrong package scope or missed a legacy location.'
    [pscustomobject]@{ fixture=$fixture.root; candidateCount=$candidates.Count; candidates=$candidates; unrelatedPackageExcluded=$true }
}
Invoke-Case 'missing LOCALAPPDATA does not block the shared default when there is no legacy installation' {
    $fixture = New-Fixture 'missing-localappdata'
    $localBefore = $env:LOCALAPPDATA
    try {
        $env:LOCALAPPDATA = $null
        $legacy = Get-SafeDeleteLegacyInstallation -CodexHome $fixture.codexHome
        Assert-True ($null -eq $legacy) 'Missing LOCALAPPDATA unexpectedly identified a legacy installation.'
        Assert-True ((Get-SafeDeleteDefaultInstallDir -UserProfile $fixture.profile) -ceq $fixture.defaultInstall) 'Missing LOCALAPPDATA changed the shared default.'
    } finally { $env:LOCALAPPDATA = $localBefore }
    [pscustomobject]@{ sharedDefaultIndependentOfLocalAppData=$true; missingLegacyCandidatesHandled=$true }
}
Invoke-Case 'a PATH npm shim does not hide the native SDK in a Codex package cache' {
    $fixture = New-Fixture 'native-sdk-behind-shim'
    $shimDirectory = Join-Path $fixture.root 'npm-shim'
    $sdkDirectory = Join-Path $fixture.localAppData 'Packages\OpenAI.Codex_sdkfixture\LocalCache\Local\OpenAI\Codex\bin\0.0.1'
    $null = [IO.Directory]::CreateDirectory($shimDirectory)
    $null = [IO.Directory]::CreateDirectory($sdkDirectory)
    [IO.File]::WriteAllText((Join-Path $shimDirectory 'codex.cmd'),"@echo off`r`nexit /b 99`r`n",[Text.Encoding]::ASCII)
    $sdkPath = Join-Path $sdkDirectory 'codex.exe'
    # Discovery reads executable metadata only. Use a harmless OS executable;
    # this fixture never executes the fake SDK or npm shim.
    [IO.File]::Copy((Join-Path $env:SystemRoot 'System32\where.exe'),$sdkPath)
    $localBefore = $env:LOCALAPPDATA
    $pathBefore = $env:Path
    try {
        $env:LOCALAPPDATA = $fixture.localAppData
        $env:Path = $shimDirectory + ';' + (Join-Path $env:SystemRoot 'System32')
        Assert-True ([IO.Path]::GetExtension((Get-Command codex -ErrorAction Stop).Source) -ceq '.cmd') 'The fixture did not resolve to its npm shim.'
        Find-SafeDeleteCodex
        Assert-True ((Get-Command codex -ErrorAction Stop).Source -ceq $sdkPath) 'The npm shim prevented native package SDK discovery.'
    } finally { $env:LOCALAPPDATA = $localBefore; $env:Path = $pathBefore }
    [pscustomobject]@{ nativeSdkSelected=$true; unknownShimNotExecuted=$true; parentEnvironmentRestored=$true }
}
Invoke-Case 'default fresh installation repeats and uninstalls with original configuration' {
    $fixture = New-Fixture 'default-fresh'
    $installed = Invoke-Install $fixture ''
    Assert-True ($installed.exitCode -eq 0 -and [IO.File]::Exists((Join-Path $fixture.defaultInstall 'install-state.json'))) 'Fresh default installation did not use the shared profile directory.'
    Assert-True (-not (Test-Path -LiteralPath $fixture.logicalLegacy)) 'Fresh default installation created the old AppData installation.'
    $before = @(Get-Snapshot $fixture.defaultInstall)
    $configBefore = Get-Hash $fixture.configPath
    $hooksBefore = Get-Hash $fixture.hooksPath
    $repeated = Invoke-Install $fixture ''
    Assert-True ($repeated.exitCode -eq 0 -and $repeated.stdout -match 'Already installed and verified') 'Repeated default installation was not verified.'
    Assert-Unchanged $fixture.defaultInstall $before
    Assert-True ((Get-Hash $fixture.configPath) -ceq $configBefore -and (Get-Hash $fixture.hooksPath) -ceq $hooksBefore) 'Repeated installation changed the current configuration.'
    $uninstalled = Invoke-Uninstall $fixture ''
    Assert-True ($uninstalled.exitCode -eq 0 -and -not (Test-Path -LiteralPath $fixture.defaultInstall)) 'Default uninstallation did not remove the shared installation.'
    Assert-Baseline $fixture
    [pscustomobject]@{ fixture=$fixture.root; installRepeatUninstallSucceeded=$true; repeatedInstallationPreservedProgramAndConfigurationFiles=$true; originalConfigurationAndPathRestored=$true }
}
foreach ($originalExisted in @($true,$false)) {
    $label = if ($originalExisted) { 'existing-config' } else { 'absent-config' }
    $caseName = if ($originalExisted) { 'fresh existing-config installation permits only a Desktop pipe rotation before restoring its baseline' } else { 'fresh absent-config installation refuses Desktop configuration generated after SDK Trust' }
    Invoke-Case $caseName {
        $fixture = New-Fixture ('fresh-pipe-' + $label)
        $pipeOne = '11111111-1111-4111-8111-111111111111'
        $pipeTwo = '22222222-2222-4222-8222-222222222222'
        $suffix = Get-DesktopPipeSuffix $pipeOne
        $source = $SourceRoot
        if ($originalExisted) {
            [IO.File]::AppendAllText($fixture.configPath,$suffix,$encoding)
            $fixture.configBaseline = Get-Hash $fixture.configPath
        } else {
            $absoluteConfig = [IO.Path]::GetFullPath($fixture.configPath)
            Assert-True ($absoluteConfig.StartsWith($runRoot + '\',[StringComparison]::OrdinalIgnoreCase)) 'Absent-config fixture removal escaped the run directory.'
            Remove-Item -LiteralPath $absoluteConfig -Force
            $fixture.configBaseline = $null
            $source = New-SourceFixture 'src-pipe-late'
            # A Desktop setting appended after verified SDK Trust is a concurrent
            # user write. Forward the actual receipt unchanged; installation must
            # preserve the generated configuration and refuse to claim ownership.
            $wrapper = @'
$script:InstallLocationOriginalHookRegistration = ${function:Get-SafeDeleteHookRegistration}
function Get-SafeDeleteHookRegistration {
    param([string]$CodexHome,[string]$WorkingDirectory,[string]$HookPath,[string]$ExpectedCommand,[switch]$Trust,
        [AllowNull()][AllowEmptyString()][string]$ExpectedConfigHash,[hashtable]$ConfigWriteReceipt)
    $result = & $script:InstallLocationOriginalHookRegistration @PSBoundParameters
    if ($Trust) {
        $configPath = Join-Path $CodexHome 'config.toml'
        if (-not [IO.File]::Exists($configPath)) { throw 'Real SDK did not generate the fixture configuration.' }
        [IO.File]::WriteAllText((Join-Path ([IO.Path]::GetDirectoryName($CodexHome)) 'desktop-trust-result.json'),
            ([pscustomobject]@{key=$result.Key;currentHash=$result.CurrentHash;trustStatus=$result.TrustStatus;enabled=$result.Enabled;configWriteHash=$result.ConfigWriteHash;hookFileSha256=(Get-SafeDeleteFileHash $HookPath)} | ConvertTo-Json -Depth 4),
            (New-Object Text.UTF8Encoding($false)))
        $suffix = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('PIPE_SUFFIX_BASE64'))
        [IO.File]::AppendAllText($configPath,$suffix,(New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllBytes((Join-Path ([IO.Path]::GetDirectoryName($CodexHome)) 'desktop-config-after-sdk.toml'),[IO.File]::ReadAllBytes($configPath))
    }
    return $result
}
'@
            $wrapper = $wrapper.Replace('PIPE_SUFFIX_BASE64',[Convert]::ToBase64String($encoding.GetBytes($suffix)))
            [IO.File]::AppendAllText((Join-Path $source 'hooks\Trust.ps1'),"`r`n" + $wrapper,$encoding)
        }
        $installed = Invoke-Install $fixture '' $source
        if (-not $originalExisted) {
            Assert-True ($installed.exitCode -ne 0) 'Fresh installation accepted concurrent Desktop-generated configuration as its own SDK write.'
            $preservedHash = Get-Hash (Join-Path $fixture.root 'desktop-config-after-sdk.toml')
            Assert-True ((Get-Hash $fixture.configPath) -ceq $preservedHash -and [IO.File]::ReadAllText($fixture.configPath).Contains($pipeOne)) 'Fresh rollback removed or changed concurrently generated Desktop configuration.'
            $state = [IO.File]::ReadAllText((Join-Path $fixture.defaultInstall 'install-state.json')) | ConvertFrom-Json
            Assert-True ($state.phase -ceq 'rolling-back') 'Concurrent Desktop configuration did not preserve an unresolved installation phase.'
            # Fresh rollback preflights both files before restoring either one.
            # Its own Hook may remain while configuration ownership is uncertain;
            # every third-party group and all unrelated metadata must be intact.
            $originalHooks=[IO.File]::ReadAllText((Join-Path $fixture.defaultInstall 'backup\hooks.json')) | ConvertFrom-Json
            $currentHooks=[IO.File]::ReadAllText($fixture.hooksPath) | ConvertFrom-Json
            $ownedGroups=@($currentHooks.hooks.PreToolUse | Where-Object { $_.matcher -ceq '^(Bash|apply_patch)$' -and @($_.hooks).Count -eq 1 -and $_.hooks[0].command -ceq $state.hook_command })
            Assert-True ($ownedGroups.Count -eq 1) 'Uncertain fresh installation did not retain exactly its own identifiable Hook.'
            $ownedHandlers=@($currentHooks.hooks.PreToolUse | ForEach-Object {$_.hooks} | Where-Object {$_.command -ceq $state.hook_command})
            Assert-True ($ownedHandlers.Count -eq 1 -and $ownedHandlers[0].type -ceq 'command') 'Uncertain fresh installation retained a malformed or duplicated SafeDelete handler.'
            $trustedBeforeAppend=[IO.File]::ReadAllText((Join-Path $fixture.root 'desktop-trust-result.json')) | ConvertFrom-Json
            Assert-True ((Get-Hash $fixture.hooksPath) -ceq $trustedBeforeAppend.hookFileSha256) 'The complete configured Hook changed after actual SDK Trust.'
            $currentHooks.hooks.PreToolUse=@($currentHooks.hooks.PreToolUse | Where-Object { -not ($_.matcher -ceq '^(Bash|apply_patch)$' -and @($_.hooks).Count -eq 1 -and $_.hooks[0].command -ceq $state.hook_command) })
            Assert-True (($currentHooks | ConvertTo-Json -Depth 12 -Compress) -ceq ($originalHooks | ConvertTo-Json -Depth 12 -Compress)) 'Rejected fresh installation changed third-party Hook groups, their order or unrelated metadata.'
            $retainedHooksHash=Get-Hash $fixture.hooksPath
            $verify=@'
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
. TRUST_LITERAL
Get-SafeDeleteHookRegistration -CodexHome HOME_LITERAL -WorkingDirectory PROJECT_LITERAL -HookPath HOOKS_LITERAL -ExpectedCommand COMMAND_LITERAL | ConvertTo-Json -Depth 5 -Compress
'@
            foreach($replacement in @(
                @{token='TRUST_LITERAL';value=(Join-Path $SourceRoot 'hooks\Trust.ps1')},
                @{token='HOME_LITERAL';value=$fixture.codexHome},
                @{token='PROJECT_LITERAL';value=$fixture.project},
                @{token='HOOKS_LITERAL';value=$fixture.hooksPath},
                @{token='COMMAND_LITERAL';value=$state.hook_command}
            )){$verify=$verify.Replace($replacement.token,"'" + $replacement.value.Replace("'","''") + "'")}
            $verifyPath=Join-Path $fixture.root 'verify-retained-hook.ps1'
            [IO.File]::WriteAllText($verifyPath,$verify,(New-Object Text.UTF8Encoding($true)))
            $verified=Invoke-Process @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$verifyPath) $fixture
            Assert-True ($verified.exitCode -eq 0) 'Actual SDK could not verify the retained SafeDelete Hook after concurrent Desktop generation.'
            $currentRegistration=$verified.stdout | ConvertFrom-Json
            Assert-True ($currentRegistration.Key -ceq $trustedBeforeAppend.key -and $currentRegistration.CurrentHash -ceq $trustedBeforeAppend.currentHash -and $currentRegistration.TrustStatus -ceq 'trusted' -and $currentRegistration.Enabled) 'Retained Hook SDK identity, hash, trust or enablement changed.'
            $destinationBefore = @(Get-Snapshot $fixture.defaultInstall)
            $uninstalled = Invoke-Uninstall $fixture ''
            Assert-True ($uninstalled.exitCode -ne 0) 'Default uninstall accepted the preserved concurrent Desktop-generated configuration.'
            Assert-True ((Get-Hash $fixture.configPath) -ceq $preservedHash -and (Get-Hash $fixture.hooksPath) -ceq $retainedHooksHash) 'Refused uninstall changed generated Desktop configuration or retained Hooks.'
            Assert-Unchanged $fixture.defaultInstall $destinationBefore
            return [pscustomobject]@{fixture=$fixture.root;originalConfigurationExisted=$false;actualSdkTrustUsed=$true;desktopSettingGeneratedAfterTrust=$true;safeInstallationRefusal=$true;generatedConfigurationBytesPreserved=$true;thirdPartyHookStructureAndOrderPreserved=$true;retainedOwnHandlerCompleteAndUnique=$true;actualSdkMetadataUnchanged=$true;defaultUninstallSafelyRefused=$true;preservedConfigSha256=$preservedHash}
        }
        Assert-True ($installed.exitCode -eq 0) 'Fresh pipe fixture installation failed; see process evidence.'
        $reference = Assert-InstalledReference $fixture $originalExisted
        $installedText = [IO.File]::ReadAllText($fixture.configPath)
        Assert-True ($installedText.Contains($pipeOne)) 'Fresh installed configuration does not contain its generated Desktop pipe.'
        $referenceHash = Get-Hash $reference
        [IO.File]::WriteAllText($fixture.configPath,$installedText.Replace($pipeOne,$pipeTwo),$encoding)
        $uninstalled = Invoke-Uninstall $fixture ''
        Assert-True ($uninstalled.exitCode -eq 0) 'Fresh installation refused a verified Desktop pipe rotation.'
        Assert-Baseline $fixture
        [pscustomobject]@{ fixture=$fixture.root; originalConfigurationExisted=$true; installedReferenceHash=$referenceHash; realSdkRegistrationUsed=$true; desktopSettingExistedBeforeInstallation=$true; pipeRotationAccepted=$true; originalExistenceAndBytesRestored=$true }
    }
}
Invoke-Case 'fresh SDK-generated Desktop baseline from empty configuration retains installed-reference pipe rotation support' {
    $fixture = New-Fixture 'fresh-sdk-pipe'
    [IO.File]::WriteAllBytes($fixture.configPath,[byte[]]@())
    $emptyHash = Get-Hash $fixture.configPath
    $pipeOne='11111111-1111-4111-8111-111111111111'
    $pipeTwo='22222222-2222-4222-8222-222222222222'
    $prepare = @'
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
. TRUST_LITERAL
$server=$null
try {
    $server=Start-SafeDeleteHookServer -CodexHome HOME_LITERAL -WorkingDirectory PROJECT_LITERAL
    $null=Invoke-SafeDeleteHookRpc $server 'config/batchWrite' @{
        edits=@(@{keyPath='mcp_servers.fixture';mergeStrategy='upsert';value=@{
            command='cmd.exe';args=@('/d','/c','exit 0');enabled=$false
            env=@{SKY_CUA_NATIVE_PIPE_DIRECTORY='\\.\pipe\codex-computer-use-11111111-1111-4111-8111-111111111111'}
        }})
    }
} finally { Stop-SafeDeleteHookServer $server }
Write-Output 'Desktop fixture baseline generated by actual local SDK before installation.'
'@
    foreach ($replacement in @(
        @{token='TRUST_LITERAL';value=(Join-Path $SourceRoot 'hooks\Trust.ps1')},
        @{token='HOME_LITERAL';value=$fixture.codexHome},
        @{token='PROJECT_LITERAL';value=$fixture.project}
    )) { $prepare=$prepare.Replace($replacement.token,"'" + $replacement.value.Replace("'","''") + "'") }
    $helper=Join-Path $fixture.root 'prepare-desktop-config.ps1'
    [IO.File]::WriteAllText($helper,$prepare,(New-Object Text.UTF8Encoding($true)))
    $prepared=Invoke-Process @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$helper) $fixture
    Assert-True ($prepared.exitCode -eq 0 -and (Get-Hash $fixture.configPath) -cne $emptyHash -and [IO.File]::ReadAllText($fixture.configPath).Contains($pipeOne)) 'Actual SDK did not generate the Desktop baseline before installation.'
    $fixture.configBaseline=Get-Hash $fixture.configPath
    $installed=Invoke-Install $fixture ''
    Assert-True ($installed.exitCode -eq 0) 'Installation rejected its already prepared SDK-generated Desktop baseline.'
    $reference=Assert-InstalledReference $fixture $true
    $referenceHash=Get-Hash $reference
    [IO.File]::WriteAllText($fixture.configPath,[IO.File]::ReadAllText($fixture.configPath).Replace($pipeOne,$pipeTwo),$encoding)
    $uninstalled=Invoke-Uninstall $fixture ''
    Assert-True ($uninstalled.exitCode -eq 0) 'Uninstall refused a verified pipe UUID rotation from an SDK-generated baseline.'
    Assert-Baseline $fixture
    [pscustomobject]@{fixture=$fixture.root;configurationWasEmptyBeforeSdkPreparation=$true;actualSdkGeneratedBaselineBeforeInstallation=$true;installedReferenceHash=$referenceHash;pipeRotationAccepted=$true;generatedBaselineRestoredByteForByte=$true}
}
foreach ($rotatePipe in @($false,$true)) {
    $label = if ($rotatePipe) { 'rotated-pipe' } else { 'unchanged-config' }
    Invoke-Case ('tampered fresh configuration reference refuses uninstall with ' + $label) {
        $fixture = New-Fixture ('fresh-reference-tamper-' + $label)
        $pipeOne = '11111111-1111-4111-8111-111111111111'
        $pipeTwo = '22222222-2222-4222-8222-222222222222'
        [IO.File]::AppendAllText($fixture.configPath,(Get-DesktopPipeSuffix $pipeOne),$encoding)
        $fixture.configBaseline = Get-Hash $fixture.configPath
        $installed = Invoke-Install $fixture ''
        Assert-True ($installed.exitCode -eq 0) 'Fresh reference-tamper fixture installation failed.'
        $reference = Assert-InstalledReference $fixture $true
        if ($rotatePipe) { [IO.File]::WriteAllText($fixture.configPath,[IO.File]::ReadAllText($fixture.configPath).Replace($pipeOne,$pipeTwo),$encoding) }
        [IO.File]::AppendAllText($reference,"# damaged installed comparison reference`r`n",$encoding)
        $programBefore = @(Get-Snapshot $fixture.defaultInstall)
        $configBefore = Get-Hash $fixture.configPath
        $hooksBefore = Get-Hash $fixture.hooksPath
        $blocked = Invoke-Uninstall $fixture ''
        Assert-True ($blocked.exitCode -ne 0) 'Uninstall accepted a changed installed-configuration reference.'
        Assert-Unchanged $fixture.defaultInstall $programBefore
        Assert-True ((Get-Hash $fixture.configPath) -ceq $configBefore -and (Get-Hash $fixture.hooksPath) -ceq $hooksBefore) 'Rejected reference-tamper uninstall overwrote the current configuration.'
        [pscustomobject]@{ fixture=$fixture.root; pipeRotated=$rotatePipe; damagedReferenceRefused=$true; installationAndCurrentConfigurationPreserved=$true }
    }
}
foreach ($physical in @($false,$true)) {
    $label = if ($physical) { 'physical-cache' } else { 'logical-appdata' }
    Invoke-Case ($label + ' legacy installation migrates in place and retains original uninstall baseline') {
        $fixture = New-LegacyFixture ('migrate-' + $label) $physical
        $hookText = [IO.File]::ReadAllText($fixture.hooksPath)
        $oldLiteral = ConvertTo-Json -InputObject $fixture.legacyHookCommand -Compress
        $escapedLiteral = $oldLiteral.Replace("'", '\u0027')
        $hookText = $hookText.Replace($oldLiteral,$escapedLiteral)
        $hookText = $hookText.Replace('fixture baseline','\u0066ixture baseline')
        [IO.File]::WriteAllText($fixture.hooksPath,$hookText,$encoding)
        $oldState = [IO.File]::ReadAllText($fixture.legacyStatePath) | ConvertFrom-Json
        foreach ($snapshot in $oldState.snapshots) { if ($snapshot.name -ceq 'hooks.json') { $snapshot.installed_hash = Get-Hash $fixture.hooksPath } }
        Write-Json $fixture.legacyStatePath $oldState
        $migrated = Invoke-Install $fixture ''
        Assert-True ($migrated.exitCode -eq 0) 'Legacy migration failed; see process evidence.'
        $evidence = Assert-Migrated $fixture
        $newState = [IO.File]::ReadAllText((Join-Path $fixture.defaultInstall 'install-state.json')) | ConvertFrom-Json
        $newLiteral = ConvertTo-Json -InputObject $newState.hook_command -Compress
        $afterHookText = [IO.File]::ReadAllText($fixture.hooksPath)
        Assert-True ($hookText.Replace($escapedLiteral,'<owned-command>') -ceq $afterHookText.Replace($newLiteral,'<owned-command>')) 'Migration changed JSON text beyond the one owned command token.'
        $before = @(Get-Snapshot $fixture.defaultInstall)
        $legacyBefore = @(Get-Snapshot $fixture.legacy)
        $configBefore = Get-Hash $fixture.configPath
        $hooksBefore = Get-Hash $fixture.hooksPath
        $repeated = Invoke-Install $fixture ''
        Assert-True ($repeated.exitCode -eq 0) 'Repeated installation after migration failed.'
        Assert-Unchanged $fixture.defaultInstall $before
        Assert-Unchanged $fixture.legacy $legacyBefore
        Assert-True ((Get-Hash $fixture.configPath) -ceq $configBefore -and (Get-Hash $fixture.hooksPath) -ceq $hooksBefore) 'Repeated migrated installation changed the current configuration.'
        $uninstalled = Invoke-Uninstall $fixture ''
        Assert-True ($uninstalled.exitCode -eq 0 -and -not (Test-Path -LiteralPath $fixture.defaultInstall)) 'Migrated installation could not be uninstalled.'
        Assert-Baseline $fixture
        $evidence | Add-Member NoteProperty originalConfigurationRestored $true
        $evidence | Add-Member NoteProperty repeatedInstallationPreservedProgramAndConfigurationFiles $true
        $evidence | Add-Member NoteProperty unrelatedJsonTextAndEscapesPreserved $true
        $evidence
    }
}
foreach ($physical in @($false,$true)) {
    $label = if ($physical) { 'physical-cache' } else { 'logical-appdata' }
    Invoke-Case ($label + ' legacy default uninstall restores the original configuration') {
        $fixture = New-LegacyFixture ('uninstall-' + $label) $physical
        $uninstalled = Invoke-Uninstall $fixture ''
        Assert-True ($uninstalled.exitCode -eq 0 -and -not (Test-Path -LiteralPath $fixture.legacy)) 'Default uninstallation did not identify and remove the valid legacy installation.'
        Assert-True (-not (Test-Path -LiteralPath $fixture.defaultInstall)) 'Legacy uninstallation created the new installation directory.'
        Assert-Baseline $fixture
        [pscustomobject]@{ fixture=$fixture.root; legacy=$fixture.legacy; legacyDefaultUninstallSucceeded=$true; originalConfigurationRestored=$true; sharedDestinationNotCreated=$true }
    }
}
Invoke-Case 'legacy migration preserves paused protection' {
    $fixture = New-LegacyFixture 'migrate-paused' $true $false
    $migrated = Invoke-Install $fixture ''
    Assert-True ($migrated.exitCode -eq 0) 'Paused legacy installation failed migration.'
    $evidence = Assert-Migrated $fixture
    $uninstalled = Invoke-Uninstall $fixture ''
    Assert-True ($uninstalled.exitCode -eq 0) 'Paused migrated installation could not be uninstalled.'
    Assert-Baseline $fixture
    $evidence
}
Invoke-Case 'NoPathUpdate migration does not inherit old PATH restoration ownership' {
    $fixture = New-LegacyFixture 'migrate-no-path-ownership'
    $oldState = [IO.File]::ReadAllText($fixture.legacyStatePath) | ConvertFrom-Json
    # Record an old PATH owner without making any registry write. The new
    # NoPathUpdate installation must never restore this synthetic old value.
    $oldState.path_updated = $true
    $oldState.original_user_path = 'SAFEDELETE_TEST_SYNTHETIC_OLD_USER_PATH'
    $oldState.installed_user_path = $userPathBefore
    Write-Json $fixture.legacyStatePath $oldState
    $migrated = Invoke-Install $fixture ''
    Assert-True ($migrated.exitCode -eq 0) 'NoPathUpdate migration rejected the old PATH-owner fixture.'
    $evidence = Assert-Migrated $fixture
    Assert-True ([string]::Equals([Environment]::GetEnvironmentVariable('Path','User'),$userPathBefore,[StringComparison]::Ordinal)) 'NoPathUpdate migration wrote the real User PATH.'
    $uninstalled = Invoke-Uninstall $fixture ''
    Assert-True ($uninstalled.exitCode -eq 0) 'NoPathUpdate migrated installation could not be uninstalled.'
    Assert-Baseline $fixture
    $evidence | Add-Member NoteProperty historicalPathOwnershipNotInherited $true
    $evidence
}

Invoke-Case 'migrated protection commands keep a cached legacy Hook in sync' {
    $fixture = New-LegacyFixture 'migrate-cached-switch'
    $migrated = Invoke-Install $fixture ''
    Assert-True ($migrated.exitCode -eq 0) 'Cached-switch fixture failed migration.'
    $evidence = Assert-Migrated $fixture
    $previousAction = ''
    foreach ($action in @('off','status','on','status')) {
        $command = Invoke-Process @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $fixture.defaultInstall 'src\safedelete.ps1'),$action) $fixture
        $expectedEnabled = $action -ceq 'on' -or ($action -ceq 'status' -and $previousAction -ceq 'on')
        $expectedStatus = if ($expectedEnabled) { 'ON' } else { 'OFF' }
        Assert-True ($command.exitCode -eq 0 -and $command.stdout -match ('(?m)^SafeDelete: ' + $expectedStatus + '\s*$')) ('Migrated ' + $action + ' did not verify both runtimes.')
        foreach ($runtime in @($fixture.defaultInstall,$fixture.legacy)) {
            $switch = [IO.File]::ReadAllText((Join-Path $runtime 'protection-state.json')) | ConvertFrom-Json
            Assert-True ($switch.enabled -eq $expectedEnabled) 'New and cached legacy protection states disagree.'
        }
        $previousAction = $action
    }
    $uninstalled = Invoke-Uninstall $fixture ''
    Assert-True ($uninstalled.exitCode -eq 0) 'Cached-switch migrated installation could not be uninstalled.'
    Assert-Baseline $fixture
    $evidence | Add-Member NoteProperty actualOnOffStatusCommandsVerifiedBothRuntimes $true
    $evidence
}
Invoke-Case 'damaged migration marker prevents protection changes to unrelated runtimes' {
    $fixture = New-LegacyFixture 'migrate-invalid-switch-marker'
    $migrated = Invoke-Install $fixture ''
    Assert-True ($migrated.exitCode -eq 0) 'Invalid-switch-marker fixture failed migration.'
    $oldState = [IO.File]::ReadAllText($fixture.legacyStatePath) | ConvertFrom-Json
    $oldState.migrated_to = Join-Path $fixture.root 'unrelated-installation'
    Write-Json $fixture.legacyStatePath $oldState
    $configBefore = Get-Hash $fixture.configPath
    $hooksBefore = Get-Hash $fixture.hooksPath
    $newBefore = @(Get-Snapshot $fixture.defaultInstall)
    $oldBefore = @(Get-Snapshot $fixture.legacy)
    $blocked = Invoke-Process @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $fixture.defaultInstall 'src\safedelete.ps1'),'off') $fixture
    Assert-True ($blocked.exitCode -ne 0 -and $blocked.stdout -match '(?m)^SafeDelete: UNKNOWN\s*$') 'Protection command accepted a mismatched migration marker.'
    Assert-Unchanged $fixture.defaultInstall $newBefore
    Assert-Unchanged $fixture.legacy $oldBefore
    Assert-True ((Get-Hash $fixture.configPath) -ceq $configBefore -and (Get-Hash $fixture.hooksPath) -ceq $hooksBefore) 'Rejected protection change altered user configuration.'
    [pscustomobject]@{ fixture=$fixture.root; unrelatedRuntimeRejected=$true; installationFilesAndConfigurationPreserved=$true }
}

foreach ($keepReference in @($false,$true)) {
    $label = if ($keepReference) { 'with-installed-reference' } else { 'without-installed-reference' }
    Invoke-Case ($label + ' migration retains uninstall support after a Desktop pipe changes twice') {
    $pipeOne = '11111111-1111-1111-1111-111111111111'
    $pipeTwo = '22222222-2222-2222-2222-222222222222'
    $pipeThree = '33333333-3333-3333-3333-333333333333'
    $suffix = Get-DesktopPipeSuffix $pipeOne
    $fixture = New-LegacyFixture ('migration-desktop-pipe-' + $label) $true $true $suffix $keepReference
    $oldState = [IO.File]::ReadAllText($fixture.legacyStatePath) | ConvertFrom-Json
    $oldConfig = @($oldState.snapshots | Where-Object { $_.name -ceq 'config.toml' })[0]
    Assert-True (($null -ne $oldConfig.PSObject.Properties['installed_reference_hash']) -eq $keepReference) 'Legacy pipe fixture has the wrong installed-reference generation.'
    [IO.File]::WriteAllText($fixture.configPath,[IO.File]::ReadAllText($fixture.configPath).Replace($pipeOne,$pipeTwo),$encoding)
    $migrated = Invoke-Install $fixture ''
    Assert-True ($migrated.exitCode -eq 0) 'Migration refused a verified Desktop pipe change.'
    $evidence = Assert-Migrated $fixture
    $state = [IO.File]::ReadAllText((Join-Path $fixture.defaultInstall 'install-state.json')) | ConvertFrom-Json
    $configSnapshot = @($state.snapshots | Where-Object { $_.name -ceq 'config.toml' })[0]
    Assert-True ($configSnapshot.installed_reference_hash -ceq $configSnapshot.installed_hash) 'Migration did not record the current installed configuration reference.'
    [IO.File]::WriteAllText($fixture.configPath,[IO.File]::ReadAllText($fixture.configPath).Replace($pipeTwo,$pipeThree),$encoding)
    $uninstalled = Invoke-Uninstall $fixture ''
    Assert-True ($uninstalled.exitCode -eq 0) 'Migrated uninstall refused a later verified Desktop pipe change.'
    Assert-Baseline $fixture
    $evidence | Add-Member NoteProperty subsequentDesktopPipeChangeAccepted $true
    $evidence | Add-Member NoteProperty originalConfigurationRestored $true
    $evidence | Add-Member NoteProperty legacyInstalledReferencePreserved $keepReference
    $evidence
    }
}
Invoke-Case 'tampered legacy installed-configuration reference refuses migration before any changes' {
    $fixture = New-LegacyFixture 'migration-reference-tamper' $true $true '' $true
    $reference = Join-Path $fixture.legacy 'backup\installed-config.toml'
    [IO.File]::AppendAllText($reference,"# damaged legacy comparison reference`r`n",$encoding)
    $before = @(Get-Snapshot $fixture.root)
    $blocked = Invoke-Install $fixture ''
    Assert-True ($blocked.exitCode -ne 0) 'Migration accepted a changed installed-configuration reference.'
    Assert-Unchanged $fixture.root $before
    [pscustomobject]@{ fixture=$fixture.root; changedInstalledReferenceRefused=$true; allFixtureFilesAndConfigurationPreserved=$true }
}
foreach ($kind in @('multiple','changed-configuration','missing-manifest','changed-backup','nonempty-target')) {
    Invoke-Case ($kind + ' legacy migration refuses before changing any files') {
        $fixture = New-LegacyFixture ('reject-' + $kind)
        switch ($kind) {
            'multiple' {
                $other = Join-Path $fixture.localAppData 'Packages\OpenAI.Codex_secondfamily\LocalCache\Local\CodexSafeDelete'
                Copy-Tree $fixture.legacy $other
            }
            'changed-configuration' { [IO.File]::AppendAllText($fixture.configPath,"# user change after old install`r`n",$encoding) }
            'missing-manifest' {
                $missingPath = [IO.Path]::GetFullPath((Join-Path $fixture.legacy 'LICENSE'))
                Assert-True ($missingPath.StartsWith($runRoot + '\',[StringComparison]::OrdinalIgnoreCase)) 'Fixture removal escaped run directory.'
                Remove-Item -LiteralPath $missingPath -Force
            }
            'changed-backup' { [IO.File]::AppendAllText((Join-Path $fixture.legacy 'backup\hooks.json'),' ', $encoding) }
            'nonempty-target' {
                $null = [IO.Directory]::CreateDirectory($fixture.defaultInstall)
                [IO.File]::WriteAllText((Join-Path $fixture.defaultInstall 'user-file.txt'),'preserve me',$encoding)
            }
        }
        $before = @(Get-Snapshot $fixture.root)
        $blocked = Invoke-Install $fixture ''
        Assert-True ($blocked.exitCode -ne 0) ('Migration accepted the unsafe ' + $kind + ' fixture.')
        Assert-Unchanged $fixture.root $before
        Assert-True ([string]::Equals([Environment]::GetEnvironmentVariable('Path','User'),$userPathBefore,[StringComparison]::Ordinal)) 'Refused migration changed real User PATH.'
        [pscustomobject]@{ fixture=$fixture.root; rejected=$kind; preservedEntries=$before.Count; installationAndConfigurationFilesPreserved=$true; userPathUnchanged=$true }
    }
}
foreach ($unsupported in @('unknown-json-metadata','utf8-bom')) {
    Invoke-Case ($unsupported + ' SDK rejection preserves legacy configuration and backups') {
        $fixture = New-LegacyFixture ('sdk-reject-' + $unsupported)
        $hookText = [IO.File]::ReadAllText($fixture.hooksPath)
        if ($unsupported -ceq 'unknown-json-metadata') {
            $deepJson = '"preserve-depth-40"'
            for ($depth=0; $depth -lt 40; $depth++) { $deepJson = '{"child":' + $deepJson + '}' }
            $hookText = $hookText.Insert($hookText.LastIndexOf('}'), ',"deep_metadata":' + $deepJson + ',"large_integer":9007199254740993,"precise_decimal":0.1000000000000000000000000001')
            [IO.File]::WriteAllText($fixture.hooksPath,$hookText,$encoding)
        } else {
            $bomEncoding = New-Object Text.UTF8Encoding($true)
            [IO.File]::WriteAllBytes($fixture.hooksPath,[byte[]]($bomEncoding.GetPreamble() + $bomEncoding.GetBytes($hookText)))
        }
        $oldState = [IO.File]::ReadAllText($fixture.legacyStatePath) | ConvertFrom-Json
        foreach ($snapshot in $oldState.snapshots) { if ($snapshot.name -ceq 'hooks.json') { $snapshot.installed_hash = Get-Hash $fixture.hooksPath } }
        Write-Json $fixture.legacyStatePath $oldState
        $configBefore = Get-Hash $fixture.configPath
        $hooksBefore = Get-Hash $fixture.hooksPath
        $legacyBefore = @(Get-Snapshot $fixture.legacy)
        $blocked = Invoke-Install $fixture ''
        Assert-True ($blocked.exitCode -ne 0 -and ($blocked.stdout + $blocked.stderr) -match 'failed to parse hooks config') 'The SDK parse rejection did not provide its actual warning.'
        Assert-True ((Get-Hash $fixture.configPath) -ceq $configBefore -and (Get-Hash $fixture.hooksPath) -ceq $hooksBefore) 'SDK rejection changed the preceding configuration bytes.'
        Assert-Unchanged $fixture.legacy $legacyBefore
        $rollbackState = [IO.File]::ReadAllText((Join-Path $fixture.defaultInstall 'install-state.json')) | ConvertFrom-Json
        Assert-True ($rollbackState.phase -ceq 'rolled-back') 'SDK rejection left an uncertain migration rollback.'
        $cleaned = Invoke-Uninstall $fixture ''
        Assert-True ($cleaned.exitCode -eq 0 -and -not (Test-Path -LiteralPath $fixture.defaultInstall)) 'SDK rejection rollback files could not be safely removed.'
        Assert-True ((Get-Hash $fixture.configPath) -ceq $configBefore -and (Get-Hash $fixture.hooksPath) -ceq $hooksBefore) 'Rollback cleanup changed the SDK-rejected configuration.'
        Assert-Unchanged $fixture.legacy $legacyBefore
        [pscustomobject]@{ fixture=$fixture.root; sdkRejected=$unsupported; configurationBytesPreserved=$true; legacyFilesAndBackupsPreserved=$true; rollbackFilesSafelyRemoved=$true }
    }
}
Invoke-Case 'failed migration restores the immediately preceding configuration and legacy state' {
    $fixture = New-LegacyFixture 'migration-rollback'
    $sourceCopy = Join-Path $runRoot 'failure-source'
    $null = [IO.Directory]::CreateDirectory($sourceCopy)
    foreach ($relative in @(@('install.ps1') + @(Get-SafeDeleteInstallManifest))) {
        if ($relative -eq 'safedelete.cmd') { continue }
        $target = Join-Path $sourceCopy $relative
        $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
        [IO.File]::Copy((Join-Path $SourceRoot $relative),$target)
    }
    $failureMarker=Join-Path $fixture.root 'injected-self-check-reached.json'
    $fixture | Add-Member NoteProperty testEnvironment @{SAFEDELETE_TEST_FAILURE_MARKER=$failureMarker} -Force
    $selfCheckFault=@'

function Test-SafeDeleteHookCommand {
    [IO.File]::WriteAllText($env:SAFEDELETE_TEST_FAILURE_MARKER,'{"injectedSelfCheckReached":true}',(New-Object Text.UTF8Encoding($false)))
    throw 'Injected migration self-check failure.'
}
'@
    [IO.File]::AppendAllText((Join-Path $sourceCopy 'src\InstallState.ps1'),$selfCheckFault,$encoding)
    $configBefore = Get-Hash $fixture.configPath
    $hooksBefore = Get-Hash $fixture.hooksPath
    $oldBefore = @(Get-Snapshot $fixture.legacy)
    $failed = Invoke-Install $fixture '' $sourceCopy
    Assert-True ($failed.exitCode -ne 0 -and [IO.File]::Exists($failureMarker)) 'Migration did not reach its injected verification failure.'
    Assert-True ((Get-Hash $fixture.configPath) -ceq $configBefore -and (Get-Hash $fixture.hooksPath) -ceq $hooksBefore) 'Failed migration did not restore the current config and hooks byte for byte.'
    Assert-Unchanged $fixture.legacy $oldBefore
    Assert-True ([string]::Equals([Environment]::GetEnvironmentVariable('Path','User'),$userPathBefore,[StringComparison]::Ordinal)) 'Migration rollback changed real User PATH.'
    $rollbackStatePath = Join-Path $fixture.defaultInstall 'install-state.json'
    Assert-True ([IO.File]::Exists($rollbackStatePath)) 'Failed migration did not preserve inspectable rollback state.'
    $rollbackState = [IO.File]::ReadAllText($rollbackStatePath) | ConvertFrom-Json
    Assert-True ($rollbackState.phase -ceq 'rolled-back') 'Failed migration left an uncertain phase after reporting rollback success.'
    $cleaned = Invoke-Uninstall $fixture ''
    Assert-True ($cleaned.exitCode -eq 0 -and -not (Test-Path -LiteralPath $fixture.defaultInstall)) 'Rolled-back migration files could not be safely removed.'
    Assert-True ((Get-Hash $fixture.configPath) -ceq $configBefore -and (Get-Hash $fixture.hooksPath) -ceq $hooksBefore) 'Rollback cleanup overwrote the restored configuration.'
    Assert-Unchanged $fixture.legacy $oldBefore
    [pscustomobject]@{ fixture=$fixture.root; actualVerificationFailure=$true; configAndHooksRestored=$true; legacyFilesAndStateRestored=$true; userPathUnchanged=$true; rollbackFilesSafelyRemoved=$true }
}

foreach ($point in @('before-sdk-write','after-sdk-write','before-trust-return','after-self-check')) {
    $pointDirectory = @{ 'before-sdk-write'='bsw'; 'after-sdk-write'='asw'; 'before-trust-return'='btr'; 'after-self-check'='asc' }[$point]
    foreach ($failure in @($true,$false)) {
        $branch = if ($failure) { 'later-self-check-failure' } else { 'no-forced-failure' }
        $branchDirectory = if ($failure) { 'f' } else { 's' }
        Invoke-Case ('Trust transaction concurrent configuration ' + $point + ' ' + $branch + ' preserves user bytes') {
            $fixture = New-LegacyFixture ('tc-' + $pointDirectory + '-' + $branchDirectory) $false
            $sourceCopy = New-TrustConcurrencySourceFixture ('src-tc-' + $pointDirectory + '-' + $branchDirectory)
            Enable-TrustConcurrencyFault $fixture $point $failure
            $configBefore = Get-Hash $fixture.configPath
            $hooksBefore = Get-Hash $fixture.hooksPath
            $legacyBefore = @(Get-Snapshot $fixture.legacy)
            $migration = Invoke-Install $fixture '' $sourceCopy
            $fault = Get-TrustConcurrencyEvidence $fixture
            Assert-True ($null -ne $fault.injection -and $fault.injection.point -ceq $point) 'Migration never reached its requested concurrent-edit boundary.'
            Assert-True ($fault.injection.rpcMocked -eq $false -and $fault.injection.actualLocalSdkCalled) 'Concurrency regression used a mocked SDK instead of the real local app-server.'
            Assert-True ($migration.exitCode -ne 0) 'Migration accepted concurrent user configuration as its own write.'
            $state = [IO.File]::ReadAllText((Join-Path $fixture.defaultInstall 'install-state.json')) | ConvertFrom-Json
            Assert-True ($state.phase -ceq 'rolling-back') 'Concurrent configuration did not leave an inspectable unresolved rollback.'
            Assert-True ($null -ne $fault.configWriteReceipt -and $fault.configWriteReceipt.publishedHash -match '^[0-9A-Fa-f]{64}$') 'Expected configuration ownership receipt was never published.'
            $liveHash = Get-Hash $fixture.configPath
            Assert-True ($liveHash -cne $fault.configWriteReceipt.publishedHash) 'The ownership receipt claimed the concurrent user bytes.'
            $liveText = [IO.File]::ReadAllText($fixture.configPath)
            Assert-True ($liveText.Contains('# concurrent-config-should-survive') -and $liveText.Contains('[profiles.safedelete_concurrency_regression]') -and $liveText -match 'model_reasoning_effort\s*=\s*[''\"]high[''\"]') 'Concurrent user profile settings or their comment were lost.'
            $expectedLiveHash = $fault.injection.afterSha256
            if ($point -ceq 'before-sdk-write' -and $null -ne $fault.sdkWriteSucceeded) { $expectedLiveHash=$fault.sdkWriteSucceeded.configSha256 }
            Assert-True ($liveHash -ceq $expectedLiveHash) 'Rollback changed the last fixture bytes written by the user or SDK.'
            if ($point -in @('before-trust-return','after-self-check')) {
                Assert-True ($null -ne $fault.trustSucceeded -and $fault.trustSucceeded.enabled -and $fault.trustSucceeded.trustStatus -ceq 'trusted') 'Edit was not injected after successful actual SDK Trust.'
            }
            if ($point -ceq 'after-self-check') { Assert-True ($null -ne $fault.selfCheckSucceeded -and $fault.selfCheckSucceeded.actualHookExecuted) 'Edit did not occur after the actual Hook self-check.' }
            Assert-True ((Get-Hash $fixture.hooksPath) -ceq $hooksBefore) 'Unresolved configuration rollback did not restore the unchanged legacy Hook file.'
            Assert-Unchanged $fixture.legacy $legacyBefore
            [IO.File]::WriteAllBytes((Join-Path $fault.directory 'config-after-migration.toml'),[IO.File]::ReadAllBytes($fixture.configPath))
            $destinationBefore = @(Get-Snapshot $fixture.defaultInstall)
            $uninstall = Invoke-Uninstall $fixture ''
            Assert-True ($uninstall.exitCode -ne 0) 'Default uninstall accepted ownership of concurrently edited configuration.'
            Assert-True ((Get-Hash $fixture.configPath) -ceq $liveHash -and (Get-Hash $fixture.hooksPath) -ceq $hooksBefore) 'Refused default uninstall changed concurrent configuration or the active legacy Hook.'
            Assert-Unchanged $fixture.defaultInstall $destinationBefore
            Assert-Unchanged $fixture.legacy $legacyBefore
            [pscustomobject]@{
                fixture=$fixture.root; point=$point; requestedLaterSelfCheckFailure=$failure; actualSdkBoundary=$true
                safeMigrationRefusal=$true; unresolvedPhase=$state.phase; concurrentSettingsAndLastWriteBytesPreserved=$true
                configBeforeSha256=$configBefore; retainedConfigSha256=$liveHash; expectedOwnedSha256=$fault.configWriteReceipt.publishedHash
                defaultUninstallSafelyRefused=$true; legacyRuntimeAndHooksPreserved=$true; fault=$fault
            }
        }
    }
}

foreach ($failure in @($true,$false)) {
    $branch = if ($failure) { 'self-check-failure' } else { 'successful-migration' }
    $branchDirectory = if ($failure) { 'f' } else { 's' }
    Invoke-Case ('Trust transaction normal SDK-only write ' + $branch + ' restores the correct baseline') {
        $fixture = New-LegacyFixture ('tn-' + $branchDirectory) $false $true '' $true
        $sourceCopy = New-TrustConcurrencySourceFixture ('src-tn-' + $branchDirectory)
        Enable-TrustConcurrencyFault $fixture 'none' $failure
        $configBefore = Get-Hash $fixture.configPath
        $hooksBefore = Get-Hash $fixture.hooksPath
        $legacyBefore = @(Get-Snapshot $fixture.legacy)
        $migration = Invoke-Install $fixture '' $sourceCopy
        $fault = Get-TrustConcurrencyEvidence $fixture
        Assert-True ($null -eq $fault.injection -and $null -ne $fault.sdkWriteSucceeded -and $null -ne $fault.trustSucceeded) 'Normal control did not execute a real SDK-only Trust write.'
        Assert-True ($null -ne $fault.configWriteReceipt -and $fault.configWriteReceipt.publishedHash -ceq $fault.sdkWriteSucceeded.configSha256 -and $fault.trustSucceeded.configWriteHash -ceq $fault.sdkWriteSucceeded.configSha256) 'Normal SDK bytes do not match the prepublished ownership receipt and Trust return.'
        Assert-True ($null -ne $fault.selfCheckSucceeded -and $fault.selfCheckSucceeded.actualHookExecuted) 'Normal control did not execute the real configured Hook.'
        $state = [IO.File]::ReadAllText((Join-Path $fixture.defaultInstall 'install-state.json')) | ConvertFrom-Json
        if ($failure) {
            Assert-True ($migration.exitCode -ne 0 -and $state.phase -ceq 'rolled-back') 'SDK-only self-check failure did not complete rollback.'
            Assert-True ((Get-Hash $fixture.configPath) -ceq $configBefore -and (Get-Hash $fixture.hooksPath) -ceq $hooksBefore) 'SDK-only rollback failed to restore the immediately preceding configuration bytes.'
            Assert-Unchanged $fixture.legacy $legacyBefore
        } else {
            Assert-True ($migration.exitCode -eq 0) 'Valid SDK-only configuration changes were incorrectly treated as concurrent edits.'
            $null = Assert-Migrated $fixture
        }
        $uninstall = Invoke-Uninstall $fixture ''
        Assert-True ($uninstall.exitCode -eq 0 -and -not (Test-Path -LiteralPath $fixture.defaultInstall)) 'Normal SDK-only transaction could not safely uninstall its destination.'
        if ($failure) {
            Assert-True ((Get-Hash $fixture.configPath) -ceq $configBefore -and (Get-Hash $fixture.hooksPath) -ceq $hooksBefore) 'Rollback cleanup changed the active legacy configuration.'
            Assert-Unchanged $fixture.legacy $legacyBefore
        } else { Assert-Baseline $fixture }
        [pscustomobject]@{fixture=$fixture.root;actualLocalSdkWrite=$true;actualHookExecuted=$true;expectedReceiptVerified=$true;selfCheckFailureInjected=$failure;configurationBaselineRestored=$true;destinationSafelyRemoved=$true;fault=$fault}
    }
}

foreach ($reloadFailure in @('failure','timeout')) {
    $failureDirectory = if ($reloadFailure -ceq 'failure') { 'f' } else { 't' }
    Invoke-Case ('Trust transaction SDK reload ' + $reloadFailure + ' after actual write rolls back from its receipt') {
        $fixture = New-LegacyFixture ('tr-' + $failureDirectory) $false
        $sourceCopy = New-TrustConcurrencySourceFixture ('src-tr-' + $failureDirectory)
        Enable-TrustConcurrencyFault $fixture 'none' $false $reloadFailure
        $configBefore = Get-Hash $fixture.configPath
        $hooksBefore = Get-Hash $fixture.hooksPath
        $legacyBefore = @(Get-Snapshot $fixture.legacy)
        $migration = Invoke-Install $fixture '' $sourceCopy
        $fault = Get-TrustConcurrencyEvidence $fixture
        Assert-True ($null -ne $fault.sdkWriteSucceeded -and $null -ne $fault.sdkReloadFailed -and $fault.sdkReloadFailed.mode -ceq $reloadFailure) 'Fault was not injected at reload after the actual successful SDK write.'
        Assert-True ($null -eq $fault.trustSucceeded -and $null -eq $fault.selfCheckSucceeded -and $null -eq $fault.injection) 'Reload failure unexpectedly returned a trusted Hook or ran later self-checks.'
        Assert-True ($null -ne $fault.configWriteReceipt -and $fault.configWriteReceipt.publishedHash -ceq $fault.sdkWriteSucceeded.configSha256) 'SDK failure discarded the receipt of bytes already written.'
        $state = [IO.File]::ReadAllText((Join-Path $fixture.defaultInstall 'install-state.json')) | ConvertFrom-Json
        Assert-True ($migration.exitCode -ne 0 -and $state.phase -ceq 'rolled-back') 'SDK reload failure could not roll back its owned write.'
        Assert-True ((Get-Hash $fixture.configPath) -ceq $configBefore -and (Get-Hash $fixture.hooksPath) -ceq $hooksBefore) 'Receipt rollback did not restore the pre-migration configuration bytes.'
        Assert-Unchanged $fixture.legacy $legacyBefore
        $uninstall = Invoke-Uninstall $fixture ''
        Assert-True ($uninstall.exitCode -eq 0 -and -not (Test-Path -LiteralPath $fixture.defaultInstall)) 'Receipt rollback destination could not be safely cleaned up.'
        Assert-True ((Get-Hash $fixture.configPath) -ceq $configBefore -and (Get-Hash $fixture.hooksPath) -ceq $hooksBefore) 'Receipt rollback cleanup overwrote the restored configuration.'
        Assert-Unchanged $fixture.legacy $legacyBefore
        [pscustomobject]@{fixture=$fixture.root;reloadFault=$reloadFailure;timeoutExceptionInjected=($reloadFailure -ceq 'timeout');actualSdkWriteBeforeFailure=$true;prepublishedReceiptSurvivedFailure=$true;configurationBytesRestored=$true;legacyRuntimePreserved=$true;destinationSafelyRemoved=$true;fault=$fault}
    }
}

foreach ($configuration in @('absent','empty')) {
    $configurationDirectory = if ($configuration -ceq 'absent') { 'a' } else { 'e' }
    Invoke-Case ('Trust transaction fresh ' + $configuration + ' configuration installs and restores its original existence') {
        $fixture = New-Fixture ('tf-' + $configurationDirectory)
        if ($configuration -ceq 'absent') {
            $absolute = [IO.Path]::GetFullPath($fixture.configPath)
            Assert-True ($absolute.StartsWith($runRoot + '\',[StringComparison]::OrdinalIgnoreCase)) 'Absent configuration fixture escaped its run directory.'
            Remove-Item -LiteralPath $absolute -Force
            $fixture.configBaseline=$null
        } else {
            [IO.File]::WriteAllBytes($fixture.configPath,[byte[]]@())
            $fixture.configBaseline=Get-Hash $fixture.configPath
        }
        $sourceCopy = New-TrustConcurrencySourceFixture ('src-tf-' + $configurationDirectory)
        Enable-TrustConcurrencyFault $fixture 'none' $false
        $installed = Invoke-Install $fixture '' $sourceCopy
        Assert-True ($installed.exitCode -eq 0) 'Fresh installation failed its absent or empty baseline ownership check.'
        $null = Assert-InstalledReference $fixture ($configuration -ceq 'empty')
        $fault = Get-TrustConcurrencyEvidence $fixture
        Assert-True ($null -eq $fault.injection -and $null -ne $fault.sdkWriteSucceeded -and $null -ne $fault.trustSucceeded) 'Fresh control did not execute its actual SDK Trust write.'
        Assert-True ($null -ne $fault.configWriteReceipt -and $fault.configWriteReceipt.publishedHash -ceq $fault.sdkWriteSucceeded.configSha256 -and $fault.trustSucceeded.configWriteHash -ceq $fault.sdkWriteSucceeded.configSha256) 'Fresh SDK bytes do not match their published ownership receipt.'
        $uninstalled = Invoke-Uninstall $fixture ''
        Assert-True ($uninstalled.exitCode -eq 0 -and -not (Test-Path -LiteralPath $fixture.defaultInstall)) 'Fresh absent/empty installation could not safely uninstall.'
        Assert-Baseline $fixture
        [pscustomobject]@{fixture=$fixture.root;originalConfiguration=$configuration;actualLocalSdkCalled=$true;ownershipReceiptVerified=$true;originalConfigurationExistenceAndBytesRestored=$true;fault=$fault}
    }
}

$sourceUnchanged = $true
foreach ($entry in $sourceHashes) { if ((Get-Hash (Join-Path $SourceRoot $entry.path)) -cne $entry.hash) { $sourceUnchanged=$false } }
$pathUnchanged = [string]::Equals([Environment]::GetEnvironmentVariable('Path','User'),$userPathBefore,[StringComparison]::Ordinal) -and [string]::Equals($env:Path,$processPathBefore,[StringComparison]::Ordinal)
$failedCount = @($results | Where-Object { $_.result -eq 'FAIL' }).Count
if (-not $sourceUnchanged -or -not $pathUnchanged) { $failedCount++ }
if ($results.Count -eq 0) { $failedCount++ }
$reportPath = Join-Path $runRoot 'report.json'
$report = [pscustomobject]@{
    result=$(if ($failedCount -eq 0) { 'PASS' } else { 'FAIL' }); runtime=$PSVersionTable.PSVersion.ToString(); childShell=$ShellPath
    tested_at=[DateTime]::UtcNow.ToString('o'); total=$results.Count; passed=@($results | Where-Object { $_.result -eq 'PASS' }).Count; failed=$failedCount; caseFilter=$CaseFilter
    sourceUnchanged=$sourceUnchanged; userAndParentProcessPathUnchanged=$pathUnchanged; sourceHashes=$sourceHashes; tests=@($results.ToArray()); fixtures=$runRoot
    platformEvidence='Synthetic logical AppData and package LocalCache fixtures; no physical MSIX or alternate Windows host claim.'
    snapshotExclusions=@('AppData/Local/Microsoft/Windows/PowerShell/StartupProfileData-NonInteractive','AppData/Local/Microsoft/PowerShell/StartupProfileData-NonInteractive')
}
Write-Json $reportPath $report
[pscustomobject]@{ result=$report.result; runtime=$report.runtime; total=$report.total; passed=$report.passed; failed=$report.failed; report=$reportPath } | ConvertTo-Json -Compress
if ($failedCount -gt 0) { exit 1 }
