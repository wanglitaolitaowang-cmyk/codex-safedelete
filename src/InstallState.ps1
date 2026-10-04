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

function Find-SafeDeleteCodex {
    if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
        $desktopBin = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
        if ((Test-Path -LiteralPath $desktopBin -PathType Container) -and
            -not ((Get-Item -LiteralPath $desktopBin).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            Assert-SafeDeleteInstallPath $desktopBin
            $desktopCodex = Get-ChildItem -LiteralPath $desktopBin -Directory |
                Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
                ForEach-Object { Get-Item -LiteralPath (Join-Path $_.FullName 'codex.exe') -ErrorAction SilentlyContinue } |
                Where-Object { -not $_.PSIsContainer -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
                Where-Object { try { Assert-SafeDeleteInstallPath $_.FullName; $true } catch { $false } } |
                Sort-Object -Property @{Expression='LastWriteTimeUtc';Descending=$true},FullName | Select-Object -First 1
            if ($desktopCodex) { $env:Path = $desktopCodex.DirectoryName + ';' + $env:Path }
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
    }
    $allowed = @(Get-SafeDeleteInstallManifest)
    if (@($State.files | Where-Object { $_ -notin $allowed }).Count -gt 0) { throw 'Invalid installation file manifest.' }
}

function Test-SafeDeleteDesktopPipeChange {
    param($Snapshot, [string]$InstallDir)
    if ($Snapshot.name -cne 'config.toml' -or -not $Snapshot.existed -or
        $Snapshot.installed_hash -notmatch '^[0-9A-Fa-f]{64}$') { return $false }
    $backup = Join-Path $InstallDir 'backup\config.toml'
    Assert-SafeDeleteInstallPath $backup
    if ((Get-SafeDeleteFileHash $backup) -ne $Snapshot.original_hash) { throw 'Backup checksum mismatch: config.toml' }
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
    param($State, [string]$InstallDir)
    Assert-SafeDeleteInstallState $State $InstallDir
    # Verify every backup before restoring the first file.
    foreach ($entry in @($State.snapshots | Where-Object existed)) {
        $backup = Join-Path $InstallDir ('backup\' + $entry.name)
        Assert-SafeDeleteInstallPath $backup
        if ((Get-SafeDeleteFileHash $backup) -ne $entry.original_hash) { throw ('Backup checksum mismatch: ' + $entry.name) }
    }
    foreach ($entry in @($State.snapshots)) {
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
