$ErrorActionPreference = 'Stop'

function Assert-SafeDeleteSupportedInstallRuntime {
    param(
        [version]$PowerShellVersion = $PSVersionTable.PSVersion,
        [PlatformID]$Platform = [Environment]::OSVersion.Platform,
        [version]$WindowsVersion = [Environment]::OSVersion.Version
    )
    if ($Platform -ne [PlatformID]::Win32NT) {
        throw 'This installer supports Windows only. Linux and macOS installation is not implemented.'
    }
    if ($PowerShellVersion -lt [version]'5.1') {
        throw 'Windows PowerShell 5.1 or PowerShell 7 is required. No configuration was changed.'
    }
    if ($WindowsVersion.Build -lt 17763) {
        throw 'Codex integration requires Windows 10 version 1809 or newer. Windows 7 and 8 are not supported. No configuration was changed.'
    }
}

function Get-SafeDeleteFileHash {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $stream = [IO.File]::OpenRead($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '') }
    finally { $sha.Dispose(); $stream.Dispose() }
}

function Get-SafeDeleteBytesHash {
    param([byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-', '') }
    finally { $sha.Dispose() }
}

function Get-SafeDeleteInstallationMutexNames {
    param([string]$InstallDir, [string]$CodexHome)
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { $sid = $identity.User.Value } finally { $identity.Dispose() }
    $names = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($path in @($InstallDir, $CodexHome)) {
        Assert-SafeDeleteInstallPath $path
        $absolute = [IO.Path]::GetFullPath($path)
        $cursor = $absolute
        $missing = New-Object 'System.Collections.Generic.Stack[string]'
        while (-not (Test-Path -LiteralPath $cursor)) {
            $missing.Push([IO.Path]::GetFileName($cursor))
            $parent = [IO.Directory]::GetParent($cursor)
            if ($null -eq $parent) { throw 'Installation lock path cannot be resolved.' }
            $cursor = $parent.FullName
        }
        $absolute = (Get-Item -LiteralPath $cursor -Force -ErrorAction Stop).FullName
        while ($missing.Count -gt 0) { $absolute = Join-Path $absolute $missing.Pop() }
        $normalized = $absolute.TrimEnd([char[]]@('\', '/')).ToLowerInvariant()
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = [BitConverter]::ToString($sha.ComputeHash((New-Object Text.UTF8Encoding($false)).GetBytes($sid + "`n" + $normalized))).Replace('-', '') }
        finally { $sha.Dispose() }
        # Global named mutexes work across sessions. Unlike global file mappings,
        # creating a mutex does not require SeCreateGlobalPrivilege.
        $null = $names.Add('Global\CodexSafeDelete-' + $hash)
    }
    $ordered = @($names)
    [Array]::Sort($ordered, [StringComparer]::Ordinal)
    return $ordered
}

function Exit-SafeDeleteInstallationLocks {
    param([object[]]$Locks)
    for ($i = $Locks.Count - 1; $i -ge 0; $i--) {
        try { $Locks[$i].ReleaseMutex() } finally { $Locks[$i].Dispose() }
    }
}

function Enter-SafeDeleteInstallationLocks {
    param([string]$InstallDir, [string]$CodexHome)
    $owned = New-Object 'System.Collections.Generic.List[object]'
    $pending = $null
    try {
        foreach ($name in @(Get-SafeDeleteInstallationMutexNames $InstallDir $CodexHome)) {
            $pending = [Threading.Mutex]::new($false, $name)
            $acquired = $false
            try { $acquired = $pending.WaitOne(0) }
            catch [Threading.AbandonedMutexException] { $acquired = $true }
            if (-not $acquired) { throw 'Another SafeDelete installation or uninstall is using this installation or Codex configuration. Wait for it to finish and retry. No changes were made.' }
            $owned.Add($pending)
            $pending = $null
        }
        return $owned.ToArray()
    } catch {
        if ($null -ne $pending) { $pending.Dispose() }
        Exit-SafeDeleteInstallationLocks $owned.ToArray()
        throw
    }
}

function Write-SafeDeleteBytes {
    param([string]$Path, [byte[]]$Bytes)
    $temporary = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    [IO.File]::WriteAllBytes($temporary, $Bytes)
    if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
    else { [IO.File]::Move($temporary, $Path) }
}

function Write-SafeDeleteJson {
    param([string]$Path, $Value)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    Write-SafeDeleteBytes $Path ($encoding.GetBytes(($Value | ConvertTo-Json -Depth 30)))
}

function Assert-SafeDeleteInstallPath {
    param([string]$Path)
    $absolute = [IO.Path]::GetFullPath($Path).TrimEnd([char[]]'\/')
    $usersRoot = Join-Path $env:SystemDrive 'Users'
    if ($absolute -eq [IO.Path]::GetPathRoot($absolute).TrimEnd([char[]]'\/') -or
        $absolute -eq $env:USERPROFILE -or $absolute -eq $usersRoot -or
        $absolute -match '(?i)(?:^|[\\/])(\.git|\.env|\.ssh)(?:[\\/]|$)') { throw 'Unsafe installation path.' }
    $cursor = $absolute
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Installation/configuration paths must not use links or junctions.' }
        }
        $parent = [IO.Directory]::GetParent($cursor)
        if (-not $parent) { break }; $cursor = $parent.FullName
    }
}

function Get-SafeDeleteInstallManifest {
    @('src\Storage.ps1','src\Commands.ps1','src\safedelete.ps1','src\InstallState.ps1','src\Protection.ps1',
      'hooks\pre-tool-use.ps1','hooks\Trust.ps1','SKILL.md','README.md','LICENSE','uninstall.ps1','safedelete.cmd')
}

function Get-SafeDeleteDefaultInstallDir {
    param([string]$UserProfile = $env:USERPROFILE)
    # AppData writes from Store/MSIX Codex can be redirected to its private cache.
    # A directory under the profile is shared with Explorer and ordinary terminals.
    if ([string]::IsNullOrWhiteSpace($UserProfile)) { throw 'USERPROFILE is required to resolve the default installation directory.' }
    return [IO.Path]::GetFullPath((Join-Path $UserProfile '.codex-safedelete-app')).TrimEnd([char[]]'\/')
}

function Get-SafeDeleteLegacyInstallCandidates {
    param([string]$UserProfile = $env:USERPROFILE, [string]$LocalAppData = $env:LOCALAPPDATA)
    if ([string]::IsNullOrWhiteSpace($LocalAppData)) { return }
    $local = [IO.Path]::GetFullPath($LocalAppData).TrimEnd([char[]]'\/')
    $logical = Join-Path $local 'CodexSafeDelete'
    if (Test-Path -LiteralPath $logical) { $logical }
    $packages = Join-Path $local 'Packages'
    if (-not (Test-Path -LiteralPath $packages -PathType Container)) { return }
    Assert-SafeDeleteInstallPath $packages
    foreach ($package in @(Get-ChildItem -LiteralPath $packages -Directory -Force | Where-Object { $_.Name -clike 'OpenAI.Codex_*' })) {
        Assert-SafeDeleteInstallPath $package.FullName
        $candidate = Join-Path $package.FullName 'LocalCache\Local\CodexSafeDelete'
        if (Test-Path -LiteralPath $candidate) { $candidate }
    }
}

function Get-SafeDeleteInstallFileIdentity {
    param([string]$Path)
    if (-not ('SafeDeleteInstallFileIdentity128' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class SafeDeleteInstallFileIdentity128 {
    [StructLayout(LayoutKind.Sequential)]
    struct Info {
        public ulong Volume, IndexLow, IndexHigh;
    }
    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool GetFileInformationByHandleEx(SafeFileHandle handle, int informationClass, out Info info, uint size);
    public static string Read(string path) {
        using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
            Info value;
            if (!GetFileInformationByHandleEx(stream.SafeFileHandle, 18, out value, 24))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            if (value.IndexLow == 0 && value.IndexHigh == 0)
                throw new IOException("The filesystem did not provide a stable 128-bit file identity.");
            return value.Volume.ToString("X16") + ":" + value.IndexHigh.ToString("X16") + value.IndexLow.ToString("X16");
        }
    }
}
'@
    }
    return [SafeDeleteInstallFileIdentity128]::Read($Path)
}

function Get-SafeDeleteLegacyInstallation {
    param([string]$CodexHome)
    $directories = @(Get-SafeDeleteLegacyInstallCandidates)
    if ($directories.Count -eq 0) { return }
    # Prefer the physical package directory when the file identity proves that
    # the logical AppData path and LocalCache path are views of the same files.
    $logicalDefault = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'CodexSafeDelete')).TrimEnd([char[]]'\/')
    $directories = @($directories | Sort-Object @{Expression={ if ($_ -eq $logicalDefault) { 1 } else { 0 } }}, @{Expression={$_}})
    $identified = @()
    $identities = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($directory in $directories) {
        Assert-SafeDeleteInstallPath $directory
        $statePath = Join-Path $directory 'install-state.json'
        Assert-SafeDeleteInstallPath $statePath
        if (-not [IO.File]::Exists($statePath)) { throw ('Legacy SafeDelete directory has no installation state: ' + $directory + '. No changes were made.') }
        if ((Get-Item -LiteralPath $statePath -Force).Length -gt 1048576) { throw 'Legacy SafeDelete installation state exceeds the size limit.' }
        $stateBytes = [IO.File]::ReadAllBytes($statePath)
        $stateHash = Get-SafeDeleteBytesHash $stateBytes
        $json = (New-Object Text.UTF8Encoding($false,$true)).GetString($stateBytes).TrimStart([char]0xfeff)
        if (-not $json.TrimStart().StartsWith('{', [StringComparison]::Ordinal)) { throw 'Invalid legacy installation state.' }
        $state = $json | ConvertFrom-Json
        if ($state -isnot [pscustomobject]) { throw 'Invalid legacy installation state.' }
        $logical = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'CodexSafeDelete')).TrimEnd([char[]]'\/')
        Assert-SafeDeleteInstallState $state $logical
        if ($state.phase -eq 'migrated') { continue }
        if ($state.phase -ne 'complete' -or $state.codex_home -ne $CodexHome) { throw ('Legacy installation is incomplete or belongs to a different Codex configuration: ' + $directory + '. No changes were made.') }
        $identity = if ($directories.Count -gt 1) { Get-SafeDeleteInstallFileIdentity $statePath } else { $statePath }
        if (-not $identities.Add($identity)) { continue }
        if ((Get-SafeDeleteFileHash $statePath) -cne $stateHash) { throw 'Legacy installation state changed while it was read. No changes were made.' }
        $identified += [pscustomobject]@{ Directory=$directory; State=$state; StateBytes=$stateBytes; StateHash=$stateHash }
    }
    if ($identified.Count -gt 1) { throw 'Multiple different legacy SafeDelete installations were found. No changes were made; inspect their installation states before continuing.' }
    if ($identified.Count -eq 1) { return $identified[0] }
}

function Resolve-SafeDeleteInstallDirectory {
    param([string]$InstallDir, [string]$CodexHome, [switch]$ForUninstall)
    if ($InstallDir) { return [IO.Path]::GetFullPath($InstallDir).TrimEnd([char[]]'\/') }
    $default = Get-SafeDeleteDefaultInstallDir
    # Existing new state, including a failed transaction, always takes precedence.
    if (-not $ForUninstall -or (Test-Path -LiteralPath $default)) { return $default }
    $legacy = Get-SafeDeleteLegacyInstallation -CodexHome $CodexHome
    if ($null -ne $legacy) { return $legacy.Directory }
    return $default
}

function Get-SafeDeleteExpectedHookCommand {
    param([string]$InstallDir)
    $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    return "& '" + $shell.Replace("'", "''") + "' -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File '" + (Join-Path $InstallDir 'hooks\pre-tool-use.ps1').Replace("'", "''") + "'"
}

function Find-SafeDeleteCodex {
    $resolved = Get-Command codex -ErrorAction SilentlyContinue
    if (-not $resolved -or [IO.Path]::GetExtension($resolved.Source) -ne '.exe') {
        $desktopBins = @((Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'))
        $packages = Join-Path $env:LOCALAPPDATA 'Packages'
        if (Test-Path -LiteralPath $packages -PathType Container) {
            Assert-SafeDeleteInstallPath $packages
            foreach ($package in @(Get-ChildItem -LiteralPath $packages -Directory -Force | Where-Object { $_.Name -clike 'OpenAI.Codex_*' })) {
                Assert-SafeDeleteInstallPath $package.FullName
                $desktopBins += Join-Path $package.FullName 'LocalCache\Local\OpenAI\Codex\bin'
            }
        }
        foreach ($desktopBin in $desktopBins) {
            if (-not ((Test-Path -LiteralPath $desktopBin -PathType Container) -and
                -not ((Get-Item -LiteralPath $desktopBin).Attributes -band [IO.FileAttributes]::ReparsePoint))) { continue }
            Assert-SafeDeleteInstallPath $desktopBin
            $desktopCodex = Get-ChildItem -LiteralPath $desktopBin -Directory |
                Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
                ForEach-Object { Get-Item -LiteralPath (Join-Path $_.FullName 'codex.exe') -ErrorAction SilentlyContinue } |
                Where-Object { -not $_.PSIsContainer -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
                Where-Object { try { Assert-SafeDeleteInstallPath $_.FullName; $true } catch { $false } } |
                Sort-Object -Property @{Expression='LastWriteTimeUtc';Descending=$true},FullName | Select-Object -First 1
            if ($desktopCodex) { $env:Path = $desktopCodex.DirectoryName + ';' + $env:Path; break }
        }
    }
    $null = Get-Command codex -ErrorAction Stop
}

function Test-SafeDeleteHookCommand {
    param([string]$HookCommand, [string]$ProjectRoot,
        [ValidateSet('deny','bypass')][string]$ExpectedDecision = 'deny')
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    # Execute the exact configured hook command, without involving a model or files.
    # Match Codex's readable -Command invocation instead of encoding the command.
    $start.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "' + $HookCommand.Replace('"','\"') + '"'
    $start.WorkingDirectory = $ProjectRoot
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $start.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'Cannot start hook runtime verification.' }
        $output = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
        $request = @{hook_event_name='PreToolUse';cwd=$ProjectRoot;tool_name='Bash';tool_input=@{command='Remove-Item -Recurse -Force .'}} | ConvertTo-Json -Depth 4 -Compress
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($request)
        $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $process.StandardInput.BaseStream.Flush(); $process.StandardInput.Close()
        if (-not $process.WaitForExit(10000)) { $process.Kill(); throw 'Hook runtime verification timed out.' }
        if ($process.ExitCode -ne 0) { throw ('Hook runtime verification failed. Exit code: ' + $process.ExitCode) }
        if (-not [string]::IsNullOrWhiteSpace($errors.Result)) { throw 'Hook runtime verification returned error output. Protection health was not verified.' }
        if ([string]::IsNullOrWhiteSpace($output.Result)) { throw 'Hook runtime verification returned no output. Check whether security software blocked the Hook.' }
        if (-not $output.Result.TrimStart().StartsWith('{',[StringComparison]::Ordinal)) { throw 'Hook runtime verification must return a JSON object.' }
        $response = $output.Result | ConvertFrom-Json
        if ($response -isnot [pscustomobject]) { throw 'Hook runtime verification must return a JSON object.' }
        if ($ExpectedDecision -eq 'bypass') {
            if ($null -eq $response -or @($response.PSObject.Properties).Count -ne 0) { throw 'Hook runtime verification did not confirm paused protection.' }
        } else {
            $specificProperty = $response.PSObject.Properties['hookSpecificOutput']
            if ($null -eq $specificProperty -or $specificProperty.Name -cne 'hookSpecificOutput' -or $specificProperty.Value -isnot [pscustomobject]) { throw 'Hook runtime verification did not deny project-root deletion. Protection health was not verified.' }
            $specific = $specificProperty.Value
            $eventProperty = $specific.PSObject.Properties['hookEventName']
            $decisionProperty = $specific.PSObject.Properties['permissionDecision']
            $reasonProperty = $specific.PSObject.Properties['permissionDecisionReason']
            if ($null -eq $eventProperty -or $eventProperty.Name -cne 'hookEventName' -or $eventProperty.Value -isnot [string] -or $eventProperty.Value -cne 'PreToolUse' -or
                $null -eq $decisionProperty -or $decisionProperty.Name -cne 'permissionDecision' -or $decisionProperty.Value -isnot [string] -or $decisionProperty.Value -cne 'deny' -or
                $null -eq $reasonProperty -or $reasonProperty.Name -cne 'permissionDecisionReason' -or $reasonProperty.Value -isnot [string] -or
                $null -ne $specific.PSObject.Properties['updatedInput']) { throw 'Hook runtime verification did not deny project-root deletion. Protection health was not verified.' }
            # A watchdog or worker fault also denies commands. Require the normal
            # parser's exact root-deletion diagnostic before reporting healthy ON.
            $reasonLines = @($reasonProperty.Value -split '\r?\n')
            if ($reasonLines -cnotcontains 'DENY: The project root, its parents, and paths outside the project are blocked.' -or
                $reasonLines -cnotcontains 'Command: Remove-Item -Recurse -Force .') { throw 'Hook runtime verification did not confirm the project-root deletion policy. Protection health was not verified.' }
        }
    } finally { $process.Dispose() }
}

function Assert-SafeDeleteInstallState {
    param($State, [string]$InstallDir)
    if ($State.version -ne 1 -or $State.install_dir -ne $InstallDir -or
        [IO.Path]::GetFullPath($State.codex_home) -ne $State.codex_home -or
        $State.codex_home -eq $InstallDir -or $State.codex_home.StartsWith($InstallDir + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid installation identity.' }
    if (@($State.snapshots).Count -ne 2) { throw 'Invalid configuration snapshot count.' }
    foreach ($name in @('config.toml','hooks.json')) {
        $entries = @($State.snapshots | Where-Object { $_.name -ceq $name })
        if ($entries.Count -ne 1) { throw 'Invalid configuration snapshot names.' }
        $entry = $entries[0]
        if ($entry.path -ne (Join-Path $State.codex_home $name) -or $entry.existed -isnot [bool] -or
            ($entry.existed -and $entry.original_hash -notmatch '^[0-9A-Fa-f]{64}$')) { throw 'Invalid configuration snapshot paths or hashes.' }
        if ($entry.PSObject.Properties['installed_reference_hash']) {
            if ($name -cne 'config.toml' -or
                $entry.installed_reference_hash -isnot [string] -or $entry.installed_reference_hash -notmatch '^[0-9A-Fa-f]{64}$' -or
                $entry.installed_reference_hash -cne $entry.installed_hash) { throw 'Invalid installed-configuration reference.' }
        }
    }
    $allowed = @(Get-SafeDeleteInstallManifest)
    if (@($State.files | Where-Object { $_ -notin $allowed }).Count -gt 0) { throw 'Invalid installation file manifest.' }
    if ($State.PSObject.Properties['migration_backup_hash']) {
        if ($State.migration_backup_hash -isnot [string] -or $State.migration_backup_hash -notmatch '^[0-9A-Fa-f]{64}$' -or
            -not $State.PSObject.Properties['migrated_from'] -or $State.migrated_from -isnot [string] -or
            [IO.Path]::GetFullPath($State.migrated_from).TrimEnd([char[]]'\/') -ne $State.migrated_from -or
            $State.migrated_from -eq $InstallDir) { throw 'Invalid installation migration metadata.' }
    }
}

function Test-SafeDeleteDesktopPipeChange {
    param($Snapshot, [string]$InstallDir)
    if ($Snapshot.name -cne 'config.toml' -or (-not $Snapshot.existed -and -not $Snapshot.PSObject.Properties['installed_reference_hash']) -or
        $Snapshot.installed_hash -notmatch '^[0-9A-Fa-f]{64}$') { return $false }
    $referenceHash = $Snapshot.original_hash
    $backup = Join-Path $InstallDir 'backup\config.toml'
    if ($Snapshot.PSObject.Properties['installed_reference_hash']) {
        if ($Snapshot.installed_reference_hash -isnot [string] -or $Snapshot.installed_reference_hash -notmatch '^[0-9A-Fa-f]{64}$' -or
            $Snapshot.installed_reference_hash -cne $Snapshot.installed_hash) { throw 'Invalid installed-configuration reference hash.' }
        $referenceHash = $Snapshot.installed_reference_hash
        $backup = Join-Path $InstallDir 'backup\installed-config.toml'
    }
    Assert-SafeDeleteInstallPath $backup
    if ((Get-SafeDeleteFileHash $backup) -ne $referenceHash) { throw 'Backup checksum mismatch: configuration comparison reference' }
    if (-not [IO.File]::Exists($Snapshot.path) -or
        (Get-Item -LiteralPath $Snapshot.path).Length -gt 1048576 -or
        (Get-Item -LiteralPath $backup).Length -gt 1048576) { return $false }
    try {
        $encoding = New-Object Text.UTF8Encoding($false, $true)
        $texts = @($encoding.GetString([IO.File]::ReadAllBytes($backup)),
                   $encoding.GetString([IO.File]::ReadAllBytes($Snapshot.path)))
        $values = @()
        $sections = @()
        $valueTokens = @()
        foreach ($text in $texts) {
            # This narrow exception is not a TOML parser. Ambiguity stays denied.
            if ($text.Contains('"""') -or $text.Contains("'''")) { return $false }
            if ([regex]::Matches($text, 'SKY_CUA_NATIVE_PIPE_DIRECTORY').Count -ne 1) { return $false }
            $key = [regex]::Matches($text, '(?m)^[ \t]*SKY_CUA_NATIVE_PIPE_DIRECTORY[ \t]*=[ \t]*(?<value>"(?:\\[^\r\n]|[^"\\\r\n])*"|''[^''\r\n]*'')[ \t]*(?:#[^\r\n]*)?\r?$')
            if ($key.Count -ne 1) { return $false }
            $headers = [regex]::Matches($text.Substring(0, $key[0].Index), '(?m)^[ \t]*(?<table>\[[^\r\n]*\])[ \t]*(?:#[^\r\n]*)?\r?$')
            if ($headers.Count -eq 0) { return $false }
            $table = $headers[$headers.Count - 1].Groups['table'].Value
            if ($table -cnotmatch '^\[mcp_servers\.[A-Za-z0-9_-]+\.env\]$') { return $false }
            $token = $key[0].Groups['value']
            $value = if ($token.Value.StartsWith('"')) { $token.Value | ConvertFrom-Json }
                     else { $token.Value.Substring(1, $token.Value.Length - 2) }
            if ($value -isnot [string] -or $value -cnotmatch '^\\\\\.\\pipe\\codex-computer-use-[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { return $false }
            $values += $token.Value
            $sections += $table
            $valueTokens += $token
        }
        if ($sections[0] -cne $sections[1] -or $values[0][0] -cne $values[1][0]) { return $false }
        # Replace only the value in memory. Every other byte must still match.
        $candidate = $texts[1].Remove($valueTokens[1].Index, $valueTokens[1].Length).Insert($valueTokens[1].Index, $values[0])
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = [BitConverter]::ToString($sha.ComputeHash($encoding.GetBytes($candidate))).Replace('-', '') }
        finally { $sha.Dispose() }
        return $hash -eq $Snapshot.installed_hash
    } catch { return $false }
}

function Restore-SafeDeleteConfiguration {
    param($State, [string]$InstallDir, [hashtable]$OwnedHashes)
    Assert-SafeDeleteInstallState $State $InstallDir
    # Verify every backup before restoring the first file.
    foreach ($entry in @($State.snapshots | Where-Object existed)) {
        $backup = Join-Path $InstallDir ('backup\' + $entry.name)
        Assert-SafeDeleteInstallPath $backup
        if ((Get-SafeDeleteFileHash $backup) -ne $entry.original_hash) { throw ('Backup checksum mismatch: ' + $entry.name) }
    }
    foreach ($entry in @($State.snapshots)) {
        if ($null -ne $OwnedHashes) {
            Assert-SafeDeleteInstallPath $entry.path
            $liveHash = Get-SafeDeleteFileHash $entry.path
            if (-not $OwnedHashes.ContainsKey($entry.name) -or
                ($liveHash -cne $entry.original_hash -and $liveHash -cne $OwnedHashes[$entry.name])) {
                throw ('Configuration ownership is uncertain or another process changed ' + $entry.name + '; live contents were preserved for manual recovery.')
            }
        }
        if ($entry.existed) {
            $backup = Join-Path $InstallDir ('backup\' + $entry.name)
            Write-SafeDeleteBytes $entry.path ([IO.File]::ReadAllBytes($backup))
        } elseif ([IO.File]::Exists($entry.path)) {
            [IO.File]::Delete($entry.path)
        }
    }
    if ($State.path_updated) {
        [Environment]::SetEnvironmentVariable('Path', $State.original_user_path, 'User')
        $env:Path = $State.original_process_path
    }
}

function Invoke-SafeDeleteLegacyMigration {
    param([string]$SourceRoot, [string]$InstallDir, [string]$CodexHome, [string]$ProjectRoot, [switch]$NoPathUpdate)
    $legacy = Get-SafeDeleteLegacyInstallation -CodexHome $CodexHome
    if ($null -eq $legacy) { return $false }
    $old = $legacy.State
    $oldDirectory = $legacy.Directory
    $oldStatePath = Join-Path $oldDirectory 'install-state.json'
    $manifest = @(Get-SafeDeleteInstallManifest)
    if (@($old.files).Count -ne $manifest.Count -or @($old.files | Select-Object -Unique).Count -ne $manifest.Count -or
        @($manifest | Where-Object { $_ -notin @($old.files) }).Count -ne 0) { throw 'Legacy installation has an incomplete file manifest. No changes were made.' }
    if ($old.hook_command -cne (Get-SafeDeleteExpectedHookCommand $old.install_dir) -or $old.path_updated -isnot [bool]) { throw 'Legacy installation has an invalid Hook or PATH identity. No changes were made.' }
    Assert-SDNoReparse $oldDirectory
    foreach ($relative in $manifest) {
        $file = Join-Path $oldDirectory $relative
        Assert-SafeDeleteInstallPath $file
        Assert-SDNoReparse $file
        if (-not [IO.File]::Exists($file)) { throw ('Legacy installation file is missing: ' + $relative + '. No changes were made.') }
        $null = Get-SafeDeleteFileHash $file
        if ($relative -cne 'safedelete.cmd' -and -not [IO.File]::Exists((Join-Path $SourceRoot $relative))) { throw ('New installation source is missing: ' + $relative) }
    }
    $known = @('install-state.json','protection-state.json') + $manifest + @($old.snapshots | Where-Object existed | ForEach-Object { 'backup\' + $_.name })
    foreach ($snapshot in @($old.snapshots | Where-Object { $_.PSObject.Properties['installed_reference_hash'] })) {
        $referencePath = Join-Path $oldDirectory 'backup\installed-config.toml'
        Assert-SafeDeleteInstallPath $referencePath
        Assert-SDNoReparse $referencePath
        if (-not [IO.File]::Exists($referencePath) -or (Get-SafeDeleteFileHash $referencePath) -cne $snapshot.installed_reference_hash) { throw 'Legacy installed-configuration reference is missing or changed. No changes were made.' }
        $known += 'backup\installed-config.toml'
    }
    foreach ($item in @(Get-ChildItem -LiteralPath $oldDirectory -Recurse -Force)) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Legacy installation contains a link. No changes were made.' }
        if (-not $item.PSIsContainer -and $item.FullName.Substring($oldDirectory.Length + 1) -notin $known) { throw ('Legacy installation contains an unexpected file: ' + $item.Name + '. No changes were made.') }
    }
    $enabled = Read-SafeDeleteProtectionEnabled -InstallDir $oldDirectory -RequireState
    $rollbackSnapshots = @()
    foreach ($snapshot in $old.snapshots) {
        Assert-SafeDeleteInstallPath $snapshot.path
        Assert-SDNoReparse $snapshot.path
        $backup = Join-Path $oldDirectory ('backup\' + $snapshot.name)
        Assert-SafeDeleteInstallPath $backup
        Assert-SDNoReparse $backup
        if ($snapshot.existed -and (-not [IO.File]::Exists($backup) -or (Get-SafeDeleteFileHash $backup) -cne $snapshot.original_hash)) { throw ('Legacy backup checksum mismatch: ' + $snapshot.name + '. No changes were made.') }
        if (-not $snapshot.existed -and (Test-SDExists $backup)) { throw ('Unexpected legacy backup: ' + $snapshot.name + '. No changes were made.') }
        if ((Test-SDExists $snapshot.path) -and -not [IO.File]::Exists($snapshot.path)) { throw ('Legacy configuration must be a regular file: ' + $snapshot.name) }
        if ($snapshot.installed_hash -notmatch '^[0-9A-Fa-f]{64}$' -or ((Get-SafeDeleteFileHash $snapshot.path) -cne $snapshot.installed_hash -and
            -not (Test-SafeDeleteDesktopPipeChange -Snapshot $snapshot -InstallDir $oldDirectory))) { throw ('Legacy configuration changed after installation: ' + $snapshot.name + '. No changes were made.') }
        $bytes = [IO.File]::ReadAllBytes($snapshot.path)
        $rollbackSnapshots += [pscustomobject]@{ name=$snapshot.name; path=$snapshot.path; bytes=$bytes; owned_hash=(Get-SafeDeleteBytesHash $bytes) }
    }
    $hookFile = Join-Path $CodexHome 'hooks.json'
    if ((Get-Item -LiteralPath $hookFile -Force).Length -gt 1048576) { throw 'hooks.json exceeds the migration size limit.' }
    $hookBytes = @($rollbackSnapshots | Where-Object { $_.name -ceq 'hooks.json' })[0].bytes
    $hookText = (New-Object Text.UTF8Encoding($false,$true)).GetString($hookBytes)
    $json = $hookText.TrimStart([char]0xfeff)
    if (-not $json.TrimStart().StartsWith('{',[StringComparison]::Ordinal)) { throw 'Legacy hooks.json must be a JSON object.' }
    $configuration = $json | ConvertFrom-Json
    if ($configuration -isnot [pscustomobject] -or $configuration.hooks -isnot [pscustomobject] -or $configuration.hooks.PreToolUse -isnot [array]) { throw 'Legacy hooks.json has an invalid PreToolUse configuration.' }
    $handlers = @()
    foreach ($group in @($configuration.hooks.PreToolUse)) {
        if ($group -isnot [pscustomobject] -or $group.hooks -isnot [array]) { throw 'Legacy hooks.json has an invalid Hook group.' }
        foreach ($handler in @($group.hooks)) {
            if ($handler -isnot [pscustomobject]) { throw 'Legacy hooks.json has an invalid Hook handler.' }
            if ($handler.PSObject.Properties['command'] -and $handler.command -ceq $old.hook_command) {
                if ($group.matcher -cne '^(Bash|apply_patch)$' -or $handler.type -cne 'command' -or $handler.timeout -ne 30 -or $handler.statusMessage -cne 'Codex SafeDelete') { throw 'Legacy SafeDelete Hook metadata differs from the recorded installation. No changes were made.' }
                $handlers += $handler
            }
        }
    }
    if ($handlers.Count -ne 1) { throw ('Legacy installation must have exactly one owned Hook; found ' + $handlers.Count + '. No changes were made.') }
    # Locate the exact JSON string token rather than serializing unknown hook
    # metadata. Different valid escapes (including \u0027) decode identically.
    $commandTokens = @()
    foreach ($token in [regex]::Matches($hookText, '"(?:\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4})|[^"\\\x00-\x1f])*"')) {
        if ($token.Length -lt $old.hook_command.Length + 2) { continue }
        if (($token.Value | ConvertFrom-Json) -ceq $old.hook_command) { $commandTokens += $token }
    }
    if ($commandTokens.Count -ne 1) { throw 'The old Hook command JSON token cannot be identified uniquely. No changes were made.' }
    if ((Test-SDExists $InstallDir) -and (-not (Get-SDItem $InstallDir).PSIsContainer -or @(Get-ChildItem -LiteralPath $InstallDir -Force).Count -gt 0)) { throw 'New default installation directory must be empty. No changes were made.' }
    $currentUserPath = [Environment]::GetEnvironmentVariable('Path','User')
    $currentProcessPath = $env:Path
    $oldPath = $old.install_dir.TrimEnd('\')
    $parts = @($currentUserPath -split ';')
    $oldSegments = @($parts | Where-Object { $_.Trim().TrimEnd('\') -eq $oldPath })
    if ($old.path_updated -and -not $NoPathUpdate -and $oldSegments.Count -ne 1) { throw 'The old installation PATH entry cannot be identified uniquely. No changes were made.' }
    $baselineUserPath = $currentUserPath
    if ($old.path_updated) {
        $baselineUserPath = ($parts | Where-Object { $_.Trim().TrimEnd('\') -ne $oldPath }) -join ';'
        if ($currentUserPath -ceq $old.installed_user_path) { $baselineUserPath = $old.original_user_path }
    }
    $newUserPath = $currentUserPath
    if (-not $NoPathUpdate) {
        if ($old.path_updated) { $newUserPath = ($parts | ForEach-Object { if ($_.Trim().TrimEnd('\') -eq $oldPath) { $InstallDir } else { $_ } }) -join ';' }
        elseif (@($parts | Where-Object { $_.Trim().TrimEnd('\') -eq $InstallDir }).Count -eq 0) { $newUserPath = (($currentUserPath, $InstallDir) | Where-Object { $_ }) -join ';' }
    }
    if ($NoPathUpdate) { $baselineUserPath = $currentUserPath }
    $state = [pscustomobject]@{
        version=1; phase='migrating'; install_dir=$InstallDir; codex_home=$CodexHome
        hook_command=(Get-SafeDeleteExpectedHookCommand $InstallDir)
        snapshots=@($old.snapshots | ForEach-Object { [pscustomobject]@{name=$_.name;path=$_.path;existed=$_.existed;original_hash=$_.original_hash;installed_hash=$null} })
        files=$manifest; path_updated=(-not $NoPathUpdate -and ($old.path_updated -or $newUserPath -cne $currentUserPath))
        original_user_path=$baselineUserPath
        original_process_path=$(if ($NoPathUpdate) { $currentProcessPath } else { (($currentProcessPath -split ';' | Where-Object { $_.Trim().TrimEnd('\') -ne $oldPath }) -join ';') })
        installed_user_path=$newUserPath; migrated_from=$oldDirectory; migration_backup_hash=('0' * 64)
    }
    $backupDirectory = Join-Path $InstallDir 'backup'
    $statePath = Join-Path $InstallDir 'install-state.json'
    $transactionBackup = Join-Path $backupDirectory 'migration-rollback.json'
    $configurationChanged = $false
    $pathChanged = $false
    $legacyMarked = $false
    $transactionStarted = $false
    try {
        Find-SafeDeleteCodex
        $transactionStarted = $true
        $null = New-Item -ItemType Directory -Path $backupDirectory -Force
        Write-SafeDeleteJson $transactionBackup ([pscustomobject]@{
            legacy_dir=$oldDirectory; legacy_state=[Convert]::ToBase64String($legacy.StateBytes)
            configurations=@($rollbackSnapshots | ForEach-Object { [pscustomobject]@{name=$_.name;path=$_.path;bytes=[Convert]::ToBase64String($_.bytes)} })
            user_path=$currentUserPath; process_path=$currentProcessPath
        })
        $state.migration_backup_hash = Get-SafeDeleteFileHash $transactionBackup
        Write-SafeDeleteJson $statePath $state
        foreach ($snapshot in @($old.snapshots | Where-Object existed)) {
            $target = Join-Path $backupDirectory $snapshot.name
            Copy-Item -LiteralPath (Join-Path $oldDirectory ('backup\' + $snapshot.name)) -Destination $target
            if ((Get-SafeDeleteFileHash $target) -cne $snapshot.original_hash) { throw ('Migrated configuration backup checksum mismatch: ' + $snapshot.name) }
        }
        foreach ($relative in $manifest) {
            if ($relative -ceq 'safedelete.cmd') { continue }
            $target = Join-Path $InstallDir $relative
            $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($target)) -Force
            Copy-Item -LiteralPath (Join-Path $SourceRoot $relative) -Destination $target
            if ((Get-SafeDeleteFileHash $target) -cne (Get-SafeDeleteFileHash (Join-Path $SourceRoot $relative))) { throw ('Migration copy checksum mismatch: ' + $relative) }
        }
        Write-SafeDeleteJson (Join-Path $InstallDir 'protection-state.json') ([pscustomobject]@{enabled=$enabled})
        $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $shim = '@echo off' + "`r`n" + '"' + $shell + '" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0src\safedelete.ps1" %*' + "`r`n"
        [IO.File]::WriteAllText((Join-Path $InstallDir 'safedelete.cmd'), $shim, [Text.Encoding]::Default)
        # Replace this handler in place. Appending/removing groups would renumber
        # other hook keys and invalidate their independent trust/disabled settings.
        foreach ($snapshot in $rollbackSnapshots) {
            if ((Get-SafeDeleteFileHash $snapshot.path) -cne (Get-SafeDeleteBytesHash $snapshot.bytes)) { throw ('Codex configuration changed during migration preparation: ' + $snapshot.name + '. Existing configuration was preserved.') }
        }
        $newCommandToken = $state.hook_command | ConvertTo-Json -Compress
        $hookToken = $commandTokens[0]
        $newHookText = $hookText.Remove($hookToken.Index, $hookToken.Length).Insert($hookToken.Index, $newCommandToken)
        $hookBytes = (New-Object Text.UTF8Encoding($false)).GetBytes($newHookText)
        $hookRollback = @($rollbackSnapshots | Where-Object { $_.name -ceq 'hooks.json' })[0]
        $hookRollback.owned_hash = Get-SafeDeleteBytesHash $hookBytes
        $configurationChanged = $true
        Write-SafeDeleteBytes $hookFile $hookBytes
        $configRollback = @($rollbackSnapshots | Where-Object { $_.name -ceq 'config.toml' })[0]
        $configReceipt = @{ Hash=$null }
        try {
            $registration = Get-SafeDeleteHookRegistration -CodexHome $CodexHome -WorkingDirectory $ProjectRoot -HookPath $hookFile -ExpectedCommand $state.hook_command -Trust -ExpectedConfigHash $configRollback.owned_hash -ConfigWriteReceipt $configReceipt
        } finally {
            if ($null -ne $configReceipt.Hash) { $configRollback.owned_hash = $configReceipt.Hash }
        }
        if ((Get-SafeDeleteFileHash $hookFile) -cne $hookRollback.owned_hash) { throw 'hooks.json changed during Hook verification. Its newer contents were preserved.' }
        if ($null -eq $configReceipt.Hash -or (Get-SafeDeleteFileHash $configRollback.path) -cne $configReceipt.Hash) { throw 'config.toml changed during Hook verification. Its newer contents were preserved.' }
        if ($registration.TrustStatus -notin @('trusted','managed') -or -not $registration.Enabled) { throw 'Codex did not verify the migrated Hook as enabled and trusted.' }
        $expected = if ($enabled) { 'deny' } else { 'bypass' }
        Test-SafeDeleteHookCommand -HookCommand $state.hook_command -ProjectRoot $ProjectRoot -ExpectedDecision $expected
        $null = Initialize-SafeDeleteStore -ProjectRoot $ProjectRoot
        if ($newUserPath -cne $currentUserPath) {
            if ([Environment]::GetEnvironmentVariable('Path','User') -cne $currentUserPath) { throw 'User PATH changed during migration. No PATH changes were applied.' }
            [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
            $pathChanged = $true
        }
        if (-not $NoPathUpdate) { $env:Path = $InstallDir + ';' + (($env:Path -split ';' | Where-Object { $_.Trim().TrimEnd('\') -ne $oldPath -and $_.Trim().TrimEnd('\') -ne $InstallDir }) -join ';') }
        foreach ($snapshot in $state.snapshots) {
            $ownedSnapshot = @($rollbackSnapshots | Where-Object { $_.name -ceq $snapshot.name })[0]
            $snapshot.installed_hash = Get-SafeDeleteFileHash $snapshot.path
            if ($snapshot.installed_hash -cne $ownedSnapshot.owned_hash) { throw ('Codex configuration changed after Hook verification: ' + $snapshot.name + '. Newer contents were preserved.') }
        }
        $installedConfig = @($state.snapshots | Where-Object { $_.name -ceq 'config.toml' })[0]
        $installedConfigBytes = [IO.File]::ReadAllBytes($installedConfig.path)
        if ((Get-SafeDeleteBytesHash $installedConfigBytes) -cne $installedConfig.installed_hash) { throw 'Codex configuration changed while preparing its comparison reference.' }
        $referencePath = Join-Path $backupDirectory 'installed-config.toml'
        Write-SafeDeleteBytes $referencePath $installedConfigBytes
        if ((Get-SafeDeleteFileHash $referencePath) -cne $installedConfig.installed_hash) { throw 'Installed-configuration reference checksum mismatch.' }
        $installedConfig | Add-Member NoteProperty installed_reference_hash $installedConfig.installed_hash
        if ((Get-SafeDeleteFileHash $oldStatePath) -cne $legacy.StateHash) { throw 'Legacy state changed during migration.' }
        $old.phase = 'migrated'
        $old | Add-Member NoteProperty migrated_to $InstallDir -Force
        $legacyMarked = $true
        Write-SafeDeleteJson $oldStatePath $old
        $state.phase = 'complete'
        Write-SafeDeleteJson $statePath $state
        return $true
    } catch {
        $failure = $_
        $env:Path = $currentProcessPath
        if (-not $transactionStarted) { throw $failure }
        $errors = New-Object 'System.Collections.Generic.List[string]'
        try {
            if (-not [IO.File]::Exists($transactionBackup) -or (Get-SafeDeleteFileHash $transactionBackup) -cne $state.migration_backup_hash) { $errors.Add('The migration recovery backup was not completed; preserve the new directory for inspection.') }
        } catch { $errors.Add($_.Exception.Message) }
        try { if ([IO.Directory]::Exists($InstallDir)) { $state.phase='rolling-back'; Write-SafeDeleteJson $statePath $state } } catch { $errors.Add($_.Exception.Message) }
        if ($configurationChanged) {
            foreach ($snapshot in $rollbackSnapshots) {
                try {
                    $liveHash = Get-SafeDeleteFileHash $snapshot.path
                    $originalHash = Get-SafeDeleteBytesHash $snapshot.bytes
                    if ($liveHash -ceq $originalHash) { continue }
                    if ($liveHash -cne $snapshot.owned_hash) { throw ('Configuration ownership is uncertain or another process changed ' + $snapshot.name + '; live contents were preserved for manual recovery.') }
                    Write-SafeDeleteBytes $snapshot.path $snapshot.bytes
                } catch { $errors.Add($_.Exception.Message) }
            }
        }
        if ($pathChanged) {
            try {
                if ([Environment]::GetEnvironmentVariable('Path','User') -cne $newUserPath) { throw 'User PATH changed after the migration write; it was preserved for manual recovery.' }
                [Environment]::SetEnvironmentVariable('Path', $currentUserPath, 'User')
            } catch { $errors.Add($_.Exception.Message) }
        }
        $env:Path = $currentProcessPath
        if ($legacyMarked) { try { Write-SafeDeleteBytes $oldStatePath $legacy.StateBytes } catch { $errors.Add($_.Exception.Message) } }
        if ($errors.Count -eq 0 -and [IO.Directory]::Exists($InstallDir)) {
            try { $state.phase='rolled-back'; Write-SafeDeleteJson $statePath $state } catch { $errors.Add($_.Exception.Message) }
        }
        if ($errors.Count -gt 0) { throw ('Legacy migration failed and rollback requires inspection. Preserve both installations and backup\migration-rollback.json. ' + ($errors -join ' ') + ' Original error: ' + $failure.Exception.Message) }
        throw ('Legacy migration failed; original configuration, PATH and installation were restored. New rollback files are preserved in ' + $InstallDir + '; uninstall those rollback files before retrying. ' + $failure.Exception.Message)
    }
}
