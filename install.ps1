[CmdletBinding()]
param(
    [string]$CodexHome,
    [string]$InstallDir,
    [switch]$NoPathUpdate
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'src\InstallState.ps1')
. (Join-Path $PSScriptRoot 'hooks\Trust.ps1')
. (Join-Path $PSScriptRoot 'src\Storage.ps1')
. (Join-Path $PSScriptRoot 'src\Protection.ps1')

if (-not $CodexHome) { $CodexHome = $env:CODEX_HOME }
if (-not $CodexHome) { $CodexHome = Join-Path $env:USERPROFILE '.codex' }
if (-not $InstallDir) { $InstallDir = Join-Path $env:LOCALAPPDATA 'CodexSafeDelete' }
$CodexHome = [IO.Path]::GetFullPath($CodexHome)
$InstallDir = [IO.Path]::GetFullPath($InstallDir).TrimEnd([char[]]'\/')
$project = Get-SafeDeleteRoot -WorkingDirectory ((Get-Location).Path)
Assert-SafeDeleteInstallPath $InstallDir
Assert-SafeDeleteInstallPath $CodexHome
if ($CodexHome -eq $InstallDir -or $CodexHome.StartsWith($InstallDir + '\', [StringComparison]::OrdinalIgnoreCase) -or $InstallDir.StartsWith($CodexHome + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'InstallDir and CodexHome must be separate directories.' }
$originalProcessPath = $env:Path
Find-SafeDeleteCodex
$statePath = Join-Path $InstallDir 'install-state.json'
if (Test-Path -LiteralPath $statePath) {
    $existing = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json
    Assert-SafeDeleteInstallState $existing $InstallDir
    if ($existing.phase -ne 'complete' -or $existing.codex_home -ne $CodexHome -or $existing.install_dir -ne $InstallDir) { throw 'An incomplete or different installation exists. Inspect install-state.json first.' }
    if (-not (Test-Path -LiteralPath (Join-Path $InstallDir 'src\Protection.ps1'))) { throw 'This older installation does not support pause. Uninstall it with its original uninstaller, then install this version.' }
    $registration = Get-SafeDeleteHookRegistration -CodexHome $CodexHome -WorkingDirectory $project -HookPath (Join-Path $CodexHome 'hooks.json') -ExpectedCommand $existing.hook_command
    if ($registration.TrustStatus -notin @('trusted','managed')) { throw 'Hook trust changed. Check Codex /hooks before continuing.' }
    $expected = if (Read-SafeDeleteProtectionEnabled -InstallDir $InstallDir -RequireState) { 'deny' } else { 'bypass' }
    Test-SafeDeleteHookCommand -HookCommand $existing.hook_command -ProjectRoot $project -ExpectedDecision $expected
    $null = Initialize-SafeDeleteStore -ProjectRoot $project
    Write-Output 'Codex SafeDelete installed. (Already installed and verified.)'
    exit 0
}
if ((Test-Path -LiteralPath $InstallDir) -and @(Get-ChildItem -LiteralPath $InstallDir -Force).Count -gt 0) { throw 'InstallDir must be empty; existing files will not be overwritten.' }
if ($InstallDir -eq $PSScriptRoot -or $PSScriptRoot.StartsWith($InstallDir + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'InstallDir must not contain the source checkout.' }
$null = New-Item -ItemType Directory -Path $InstallDir -Force
$null = New-Item -ItemType Directory -Path (Join-Path $InstallDir 'backup') -Force
$null = New-Item -ItemType Directory -Path $CodexHome -Force
$state = [pscustomobject]@{
    version = 1; phase = 'installing'; install_dir = $InstallDir; codex_home = $CodexHome
    hook_command = ''; snapshots = @(); files = @(); path_updated = $false
    original_user_path = [Environment]::GetEnvironmentVariable('Path','User')
    original_process_path = $originalProcessPath; installed_user_path = $null
}
foreach ($name in @('config.toml','hooks.json')) {
    $path = Join-Path $CodexHome $name
    $exists = [IO.File]::Exists($path)
    if (Test-Path -LiteralPath $path) {
        if (-not $exists) { throw ($name + ' must be a regular file.') }
        Assert-SafeDeleteInstallPath $path
        Copy-Item -LiteralPath $path -Destination (Join-Path $InstallDir ('backup\' + $name))
    }
    $state.snapshots += [pscustomobject]@{ name=$name; path=$path; existed=$exists; original_hash=(Get-SafeDeleteFileHash $path); installed_hash=$null }
}
Write-SafeDeleteJson $statePath $state
try {
    $manifest = @(Get-SafeDeleteInstallManifest)
    $state.files = $manifest
    foreach ($relative in $manifest) {
        if ($relative -eq 'safedelete.cmd') { continue }
        $target = Join-Path $InstallDir $relative
        $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($target)) -Force
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $relative) -Destination $target
    }
    Write-SafeDeleteJson (Join-Path $InstallDir 'protection-state.json') ([pscustomobject]@{ enabled=$true })
    $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $shim = '@echo off' + "`r`n" + '"' + $shell + '" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0src\safedelete.ps1" %*' + "`r`n"
    [IO.File]::WriteAllText((Join-Path $InstallDir 'safedelete.cmd'), $shim, [Text.Encoding]::Default)
    $hookFile = Join-Path $CodexHome 'hooks.json'
    $configuration = [pscustomobject]@{ hooks = [pscustomobject]@{} }
    if ([IO.File]::Exists($hookFile)) {
        if ((Get-Item -LiteralPath $hookFile).Length -gt 1048576) { throw 'hooks.json exceeds the 1 MiB installation limit.' }
        $configuration = [IO.File]::ReadAllText($hookFile) | ConvertFrom-Json
    }
    if (-not $configuration -or $configuration -is [array] -or $configuration -is [string]) { throw 'hooks.json must be a JSON object.' }
    if (-not $configuration.PSObject.Properties['hooks']) { $configuration | Add-Member NoteProperty hooks ([pscustomobject]@{}) }
    if (-not $configuration.hooks -or $configuration.hooks -is [array] -or $configuration.hooks -is [string]) { throw 'hooks.json hooks must be an object.' }
    $prior = @()
    if ($configuration.hooks.PSObject.Properties['PreToolUse']) { $prior = @($configuration.hooks.PreToolUse) }
    $hookScript = Join-Path $InstallDir 'hooks\pre-tool-use.ps1'
    $state.hook_command = "& '" + $shell.Replace("'", "''") + "' -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File '" + $hookScript.Replace("'", "''") + "'"
    $entry = [pscustomobject]@{ matcher='^(Bash|apply_patch)$'; hooks=@([pscustomobject]@{ type='command'; command=$state.hook_command; timeout=30; statusMessage='Codex SafeDelete' }) }
    $configuration.hooks | Add-Member NoteProperty PreToolUse @($prior + $entry) -Force
    Write-SafeDeleteJson $hookFile $configuration
    $registration = Get-SafeDeleteHookRegistration -CodexHome $CodexHome -WorkingDirectory $project -HookPath $hookFile -ExpectedCommand $state.hook_command -Trust
    if ($registration.TrustStatus -notin @('trusted','managed') -or -not $registration.Enabled) { throw 'Codex did not verify the hook as enabled and trusted.' }
    Test-SafeDeleteHookCommand -HookCommand $state.hook_command -ProjectRoot $project
    $null = Initialize-SafeDeleteStore -ProjectRoot $project
    if (-not $NoPathUpdate) {
        $userPath = $state.original_user_path
        if (@($userPath -split ';' | Where-Object { $_.TrimEnd('\') -eq $InstallDir }).Count -eq 0) {
            $state.installed_user_path = (($userPath, $InstallDir) | Where-Object { $_ }) -join ';'
            [Environment]::SetEnvironmentVariable('Path', $state.installed_user_path, 'User')
            $state.path_updated = $true
        } else { $state.installed_user_path = $userPath }
        $env:Path = $InstallDir + ';' + $env:Path
    }
    foreach ($snapshot in $state.snapshots) { $snapshot.installed_hash = Get-SafeDeleteFileHash $snapshot.path }
    $state.phase = 'complete'
    Write-SafeDeleteJson $statePath $state
    Write-Output 'Codex SafeDelete installed.'
    Write-Output "`nProtected:"
    foreach ($name in @('Remove-Item','rm','del','rmdir','git clean','git reset --hard')) { Write-Output (([char]0x2713).ToString() + ' ' + $name) }
    Write-Output "`nUndo:`nsafedelete undo"
    Write-Output "`nRestart Codex and open a new terminal. In Codex /hooks, confirm SafeDelete is enabled and trusted."
} catch {
    $failure = $_
    # Persist the uncertain phase before restoring anything. A failed rollback or
    # final state write must never leave a state that permits normal uninstall.
    $state.phase = 'rolling-back'
    Write-SafeDeleteJson $statePath $state
    Restore-SafeDeleteConfiguration -State $state -InstallDir $InstallDir
    $state.phase = 'rolled-back'
    Write-SafeDeleteJson $statePath $state
    throw $failure
}
