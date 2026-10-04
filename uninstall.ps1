[CmdletBinding()]
param([string]$CodexHome, [string]$InstallDir, [switch]$NoPathUpdate)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'src\InstallState.ps1')
if (-not $CodexHome) { $CodexHome = $env:CODEX_HOME }
if (-not $CodexHome) { $CodexHome = Join-Path $env:USERPROFILE '.codex' }
$CodexHome = [IO.Path]::GetFullPath($CodexHome)
$InstallDir = Resolve-SafeDeleteInstallDirectory -InstallDir $InstallDir -CodexHome $CodexHome -ForUninstall
Assert-SafeDeleteInstallPath $InstallDir
$installationLocks = @(Enter-SafeDeleteInstallationLocks -InstallDir $InstallDir -CodexHome $CodexHome)
try {
    $statePath = Join-Path $InstallDir 'install-state.json'
    if (-not (Test-Path -LiteralPath $statePath)) { throw 'No installation state found.' }
    $state = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json
    if ($state.install_dir -ne $InstallDir) {
        # A legacy MSIX directory may be physically visible only in LocalCache.
        # Verify it is the one identified legacy default before using its backups.
        $legacy = Get-SafeDeleteLegacyInstallation -CodexHome $CodexHome
        if ($null -eq $legacy -or $InstallDir -notin @(Get-SafeDeleteLegacyInstallCandidates) -or
            (Get-SafeDeleteInstallFileIdentity $statePath) -cne (Get-SafeDeleteInstallFileIdentity (Join-Path $legacy.Directory 'install-state.json'))) { throw 'Installation directory differs from its recorded identity.' }
        $state.install_dir = $InstallDir
    }
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
    if ($state.PSObject.Properties['migration_backup_hash']) {
        $migrationBackup = Join-Path $InstallDir 'backup\migration-rollback.json'
        Assert-SafeDeleteInstallPath $migrationBackup
        if (-not [IO.File]::Exists($migrationBackup) -or (Get-SafeDeleteFileHash $migrationBackup) -cne $state.migration_backup_hash) { throw 'Migration recovery backup is missing or changed. Nothing was overwritten.' }
        $known += 'backup\migration-rollback.json'
    }
    $referenceSnapshots = @($state.snapshots | Where-Object { $_.PSObject.Properties['installed_reference_hash'] })
    if ($referenceSnapshots.Count -gt 0) {
        $referencePath = Join-Path $InstallDir 'backup\installed-config.toml'
        Assert-SafeDeleteInstallPath $referencePath
        if ($referenceSnapshots.Count -ne 1 -or -not [IO.File]::Exists($referencePath) -or
            (Get-SafeDeleteFileHash $referencePath) -cne $referenceSnapshots[0].installed_reference_hash) { throw 'Installed-configuration reference is missing or changed. Nothing was overwritten.' }
        $known += 'backup\installed-config.toml'
    }
    $owned = @(Get-ChildItem -LiteralPath $InstallDir -Recurse -Force)
    foreach ($item in $owned) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Installation contains a link; uninstall stopped.' }
        if (-not $item.PSIsContainer) {
            $relative = $item.FullName.Substring($InstallDir.Length + 1)
            if ($relative -notin $known) { throw ('Unexpected file in installation: ' + $relative + '. Move it out before uninstalling.') }
        }
    }
    if ($state.phase -eq 'complete') {
        Restore-SafeDeleteConfiguration -State $state -InstallDir $InstallDir
    }
    # InstallDir was resolved, matched to its state, and checked item by item above.
    Remove-Item -LiteralPath $InstallDir -Recurse -Force
    if ($state.phase -eq 'rolled-back') {
        Write-Output 'Codex SafeDelete rollback files removed. Current Codex configuration and PATH preserved.'
    } else {
        Write-Output 'Codex SafeDelete uninstalled. Original Codex configuration restored.'
        Write-Output 'Restart Codex and your terminal to stop cached hooks before reinstalling.'
    }
    Write-Output 'Recoverable trash and history in projects are preserved.'
} finally {
    Exit-SafeDeleteInstallationLocks $installationLocks
}
