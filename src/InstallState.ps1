$ErrorActionPreference = 'Stop'

function Get-SafeDeleteFileHash {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $stream = [IO.File]::OpenRead($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '') }
    finally { $sha.Dispose(); $stream.Dispose() }
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
    @('src\Storage.ps1','src\Commands.ps1','src\safedelete.ps1','src\InstallState.ps1',
      'hooks\pre-tool-use.ps1','hooks\Trust.ps1','SKILL.md','README.md','LICENSE','uninstall.ps1','safedelete.cmd')
}

function Test-SafeDeleteHookCommand {
    param([string]$HookCommand, [string]$ProjectRoot)
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    # Execute the exact configured hook command, without involving a model or files.
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($HookCommand))
    $start.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + $encoded
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
        $response = $output.Result | ConvertFrom-Json
        if ($response.hookSpecificOutput.permissionDecision -ne 'deny') { throw 'Hook runtime verification did not deny project-root deletion.' }
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
