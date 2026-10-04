[CmdletBinding()]
param([string]$CodexHome, [string]$InstallDir, [switch]$NoPathUpdate)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'src\InstallState.ps1')
if (-not $InstallDir) { $InstallDir = Join-Path $env:LOCALAPPDATA 'CodexSafeDelete' }
if (-not $CodexHome) { $CodexHome = $env:CODEX_HOME }
if (-not $CodexHome) { $CodexHome = Join-Path $env:USERPROFILE '.codex' }
$InstallDir = [IO.Path]::GetFullPath($InstallDir).TrimEnd([char[]]'\/')
Assert-SafeDeleteInstallPath $InstallDir
$statePath = Join-Path $InstallDir 'install-state.json'
if (-not (Test-Path -LiteralPath $statePath)) { throw 'No installation state found.' }
$state = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json
Assert-SafeDeleteInstallState $state $InstallDir
if ($state.install_dir -ne $InstallDir -or $state.phase -notin @('complete','rolled-back')) { throw 'Installation identity is invalid or incomplete.' }
if ([IO.Path]::GetFullPath($CodexHome) -ne $state.codex_home) { throw 'CodexHome differs from the recorded installation. Supply the original -CodexHome value.' }
Assert-SafeDeleteInstallPath $state.codex_home
if ($state.phase -eq 'complete') {
    foreach ($snapshot in $state.snapshots) {
        Assert-SafeDeleteInstallPath $snapshot.path
        if ((Get-SafeDeleteFileHash $snapshot.path) -ne $snapshot.installed_hash -and
            -not (Test-SafeDeleteDesktopPipeChange -Snapshot $snapshot -InstallDir $InstallDir)) {
            throw ('Codex configuration changed after installation: ' + $snapshot.path + '. Backups are in ' + (Join-Path $InstallDir 'backup') + '; merge those changes before uninstalling. Nothing was overwritten.')
        }
    }
    if ($state.path_updated -and [Environment]::GetEnvironmentVariable('Path','User') -ne $state.installed_user_path) { throw 'User PATH changed after installation. Nothing was overwritten; inspect install-state.json before uninstalling.' }
}
# Only remove a fully identified installation with no extra user files or links.
$known = @('install-state.json','protection-state.json') + @($state.files) + @($state.snapshots | Where-Object existed | ForEach-Object { 'backup\' + $_.name })
$owned = @(Get-ChildItem -LiteralPath $InstallDir -Recurse -Force)
foreach ($item in $owned) {
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Installation contains a link; uninstall stopped.' }
    if (-not $item.PSIsContainer) {
        $relative = $item.FullName.Substring($InstallDir.Length + 1)
        if ($relative -notin $known) { throw ('Unexpected file in installation: ' + $relative + '. Move it out before uninstalling.') }
    }
}
Restore-SafeDeleteConfiguration -State $state -InstallDir $InstallDir
# InstallDir was resolved, matched to its state, and checked item by item above.
Remove-Item -LiteralPath $InstallDir -Recurse -Force
Write-Output 'Codex SafeDelete uninstalled. Original Codex configuration restored.'
Write-Output 'Recoverable trash and history in projects are preserved.'
