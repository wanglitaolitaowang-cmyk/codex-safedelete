# Codex sends the PreToolUse event as UTF-8 JSON on stdin. The lightweight
# parent owns the deadline; filesystem checks run only in the isolated worker.
[CmdletBinding()]
param([switch]$Worker)
$ErrorActionPreference = 'Stop'
$watchdogMilliseconds = 20000
$watchdogClock = [Diagnostics.Stopwatch]::StartNew()

function Write-SafeDeleteWatchdogDeny {
    param([string]$Failure)
    [Console]::Error.WriteLine('Codex SafeDelete: Hook verification failed (' + $Failure + '); original command denied.')
    # Explicit denial survives Windows shell wrappers that normalize exit codes.
    [Console]::Out.WriteLine('{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Codex SafeDelete: Hook verification failed or exceeded its safety budget. Original command denied. Run safedelete status."}}')
}

# BEGIN SAFEDELETE WORKER
if ($Worker) {
    try {
        [Console]::InputEncoding = New-Object Text.UTF8Encoding($false)
        [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
        . (Join-Path $PSScriptRoot '..\src\Protection.ps1')
        $enabled = Read-SafeDeleteProtectionEnabled -InstallDir (Split-Path -Parent $PSScriptRoot)
        if (-not $enabled) {
            # The parent bounds this input. Drain it before reporting paused
            # protection so a quick exit cannot race delivery/EOF on Windows.
            $null = [Console]::In.ReadToEnd()
            [Console]::Out.WriteLine('{}'); exit 0
        }
        # This action only plans/replaces a command. It never moves a payload.
        & (Join-Path $PSScriptRoot '..\src\safedelete.ps1') -Action hook
        if ($LASTEXITCODE -ne 0) { Write-SafeDeleteWatchdogDeny 'worker-runtime'; exit 0 }
        exit 0
    } catch {
        Write-SafeDeleteWatchdogDeny 'worker-state-or-runtime'
        exit 0
    }
}
# END SAFEDELETE WORKER

function Get-SafeDeleteWatchdogRemaining {
    # A wall-clock adjustment must not extend the budget beyond Codex's timeout.
    $remaining = $watchdogMilliseconds - $watchdogClock.ElapsedMilliseconds
    if ($remaining -le 0) { throw 'watchdog-timeout' }
    return [int]$remaining
}

function Wait-SafeDeleteWatchdogTask {
    param($Task)
    if (-not $Task.Wait((Get-SafeDeleteWatchdogRemaining))) { throw 'watchdog-timeout' }
}

function Restore-SafeDeleteStandardHandleInheritance {
    param([object[]]$Handles)
    foreach ($entry in $Handles) {
        if (-not [Codex.SafeDelete.WatchdogNative]::SetHandleInformation($entry.handle, [uint32]1, [uint32]($entry.flags -band 1))) {
            throw 'standard-handle-restore-failed'
        }
    }
}

function Initialize-SafeDeleteWatchdogNative {
    # Process.Start on Windows inherits every inheritable handle, including the
    # SDK's outer stdout/stderr. A grandchild holding those handles can prevent
    # EOF after this parent exits. Emit public P/Invoke metadata in memory; do
    # not invoke Add-Type/a compiler in this lightweight, timed parent.
    if (-not ('Codex.SafeDelete.WatchdogNative' -as [type])) {
        $name = New-Object Reflection.AssemblyName('CodexSafeDeleteWatchdogInterop')
        if ([Reflection.Emit.AssemblyBuilder].GetMethod('DefineDynamicAssembly', [type[]]@([Reflection.AssemblyName],[Reflection.Emit.AssemblyBuilderAccess]))) {
            $assembly = [Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly($name, [Reflection.Emit.AssemblyBuilderAccess]::Run)
        } else {
            $assembly = [AppDomain]::CurrentDomain.DefineDynamicAssembly($name, [Reflection.Emit.AssemblyBuilderAccess]::Run)
        }
        $module = $assembly.DefineDynamicModule('Native')
        $type = $module.DefineType('Codex.SafeDelete.WatchdogNative', [Reflection.TypeAttributes]::Public -bor [Reflection.TypeAttributes]::Abstract -bor [Reflection.TypeAttributes]::Sealed)
        $signatures = @(
            @{name='GetStdHandle';result=[IntPtr];parameters=[type[]]@([int])},
            @{name='GetHandleInformation';result=[bool];parameters=[type[]]@([IntPtr],[uint32].MakeByRefType())},
            @{name='SetHandleInformation';result=[bool];parameters=[type[]]@([IntPtr],[uint32],[uint32])},
            @{name='CreatePipe';result=[bool];parameters=[type[]]@([IntPtr].MakeByRefType(),[IntPtr].MakeByRefType(),[IntPtr],[uint32])},
            @{name='CloseHandle';result=[bool];parameters=[type[]]@([IntPtr])},
            @{name='TerminateProcess';result=[bool];parameters=[type[]]@([IntPtr],[uint32])},
            @{name='InitializeProcThreadAttributeList';result=[bool];parameters=[type[]]@([IntPtr],[uint32],[uint32],[UIntPtr].MakeByRefType())},
            @{name='UpdateProcThreadAttribute';result=[bool];parameters=[type[]]@([IntPtr],[uint32],[UIntPtr],[IntPtr],[UIntPtr],[IntPtr],[IntPtr])},
            @{name='DeleteProcThreadAttributeList';result=[void];parameters=[type[]]@([IntPtr])},
            @{name='CreateProcessW';result=[bool];parameters=[type[]]@([IntPtr],[IntPtr],[IntPtr],[IntPtr],[bool],[uint32],[IntPtr],[IntPtr],[IntPtr],[IntPtr])}
        )
        foreach ($signature in $signatures) {
            $method = $type.DefinePInvokeMethod($signature.name, 'kernel32.dll',
                [Reflection.MethodAttributes]::Public -bor [Reflection.MethodAttributes]::Static -bor [Reflection.MethodAttributes]::PinvokeImpl,
                [Reflection.CallingConventions]::Standard, $signature.result, $signature.parameters,
                [Runtime.InteropServices.CallingConvention]::Winapi, [Runtime.InteropServices.CharSet]::None)
            $method.SetImplementationFlags($method.GetMethodImplementationFlags() -bor [Reflection.MethodImplAttributes]::PreserveSig)
        }
        $null = $type.CreateType()
    }
}

function Disable-SafeDeleteStandardHandleInheritance {
    Initialize-SafeDeleteWatchdogNative
    $saved = New-Object 'System.Collections.Generic.List[object]'
    $seen = New-Object 'System.Collections.Generic.HashSet[long]'
    try {
        foreach ($id in @(-10,-11,-12)) {
            $handle = [Codex.SafeDelete.WatchdogNative]::GetStdHandle($id)
            if ($handle -eq [IntPtr]::Zero -or $handle.ToInt64() -eq -1) { throw 'invalid-standard-handle' }
            if (-not $seen.Add($handle.ToInt64())) { continue }
            $flags = [uint32]0
            if (-not [Codex.SafeDelete.WatchdogNative]::GetHandleInformation($handle, [ref]$flags)) { throw 'standard-handle-query-failed' }
            $saved.Add([pscustomobject]@{handle=$handle;flags=$flags})
            if (-not [Codex.SafeDelete.WatchdogNative]::SetHandleInformation($handle, [uint32]1, [uint32]0)) { throw 'standard-handle-isolation-failed' }
        }
    } catch {
        try { Restore-SafeDeleteStandardHandleInheritance $saved.ToArray() } catch { }
        throw
    }
    return $saved.ToArray()
}

function Start-SafeDeleteWorkerWithHandleList {
    param([string]$FileName, [string]$Arguments)
    # Windows PowerShell's host may duplicate SDK stdout into additional
    # inheritable handles. Restrict inheritance at CreateProcess itself rather
    # than assuming the three GetStdHandle values are the only pipe copies.
    Initialize-SafeDeleteWatchdogNative
    $pointerSize = [IntPtr]::Size
    $securitySize = if ($pointerSize -eq 8) { 24 } else { 12 }
    $startupSize = if ($pointerSize -eq 8) { 104 } else { 68 }
    $startupExtendedSize = $startupSize + $pointerSize
    $processInfoSize = 2 * $pointerSize + 8
    $standardOffset = if ($pointerSize -eq 8) { 80 } else { 56 }
    $flagsOffset = if ($pointerSize -eq 8) { 60 } else { 44 }
    $security = [IntPtr]::Zero; $startup = [IntPtr]::Zero; $processInfo = [IntPtr]::Zero
    $attributeList = [IntPtr]::Zero; $handleArray = [IntPtr]::Zero; $commandLine = [IntPtr]::Zero; $applicationName = [IntPtr]::Zero
    $attributeInitialized = $false; $childCreated = $false
    $processHandle = [IntPtr]::Zero; $threadHandle = [IntPtr]::Zero
    $owned = New-Object 'System.Collections.Generic.List[System.IntPtr]'
    $pipeStreams = New-Object 'System.Collections.Generic.List[object]'
    $createdProcess = $null; $complete = $false
    try {
        $security = [Runtime.InteropServices.Marshal]::AllocHGlobal($securitySize)
        [Runtime.InteropServices.Marshal]::Copy((New-Object byte[] $securitySize), 0, $security, $securitySize)
        [Runtime.InteropServices.Marshal]::WriteInt32($security, 0, $securitySize)
        [Runtime.InteropServices.Marshal]::WriteInt32($security, (2 * $pointerSize), 1)
        $parentHandles = New-Object 'System.Collections.Generic.List[System.IntPtr]'
        $childHandles = New-Object 'System.Collections.Generic.List[System.IntPtr]'
        foreach ($inputPipe in @($true,$false,$false)) {
            $readHandle = [IntPtr]::Zero; $writeHandle = [IntPtr]::Zero
            if (-not [Codex.SafeDelete.WatchdogNative]::CreatePipe([ref]$readHandle, [ref]$writeHandle, $security, [uint32]0)) { throw 'worker-pipe-create-failed' }
            $owned.Add($readHandle); $owned.Add($writeHandle)
            $parentHandle = if ($inputPipe) { $writeHandle } else { $readHandle }
            $childHandle = if ($inputPipe) { $readHandle } else { $writeHandle }
            if (-not [Codex.SafeDelete.WatchdogNative]::SetHandleInformation($parentHandle, [uint32]1, [uint32]0)) { throw 'worker-pipe-isolation-failed' }
            $parentHandles.Add($parentHandle); $childHandles.Add($childHandle)
        }
        $attributeSize = [UIntPtr]::Zero
        $null = [Codex.SafeDelete.WatchdogNative]::InitializeProcThreadAttributeList([IntPtr]::Zero, [uint32]1, [uint32]0, [ref]$attributeSize)
        if ($attributeSize.ToUInt64() -eq 0 -or $attributeSize.ToUInt64() -gt 65536) { throw 'worker-attribute-size-invalid' }
        $attributeList = [Runtime.InteropServices.Marshal]::AllocHGlobal([int]$attributeSize.ToUInt64())
        if (-not [Codex.SafeDelete.WatchdogNative]::InitializeProcThreadAttributeList($attributeList, [uint32]1, [uint32]0, [ref]$attributeSize)) { throw 'worker-attribute-initialize-failed' }
        $attributeInitialized = $true
        $handleArray = [Runtime.InteropServices.Marshal]::AllocHGlobal(3 * $pointerSize)
        for ($index = 0; $index -lt 3; $index++) { [Runtime.InteropServices.Marshal]::WriteIntPtr($handleArray, ($index * $pointerSize), $childHandles[$index]) }
        $handleListAttribute = [UIntPtr]::new([uint64]0x00020002)
        $handleListSize = [UIntPtr]::new([uint64](3 * $pointerSize))
        if (-not [Codex.SafeDelete.WatchdogNative]::UpdateProcThreadAttribute($attributeList, [uint32]0, $handleListAttribute, $handleArray, $handleListSize, [IntPtr]::Zero, [IntPtr]::Zero)) { throw 'worker-handle-list-failed' }
        $startup = [Runtime.InteropServices.Marshal]::AllocHGlobal($startupExtendedSize)
        [Runtime.InteropServices.Marshal]::Copy((New-Object byte[] $startupExtendedSize), 0, $startup, $startupExtendedSize)
        [Runtime.InteropServices.Marshal]::WriteInt32($startup, 0, $startupExtendedSize)
        [Runtime.InteropServices.Marshal]::WriteInt32($startup, $flagsOffset, 0x100)
        for ($index = 0; $index -lt 3; $index++) { [Runtime.InteropServices.Marshal]::WriteIntPtr($startup, ($standardOffset + $index * $pointerSize), $childHandles[$index]) }
        [Runtime.InteropServices.Marshal]::WriteIntPtr($startup, $startupSize, $attributeList)
        $processInfo = [Runtime.InteropServices.Marshal]::AllocHGlobal($processInfoSize)
        [Runtime.InteropServices.Marshal]::Copy((New-Object byte[] $processInfoSize), 0, $processInfo, $processInfoSize)
        $commandLine = [Runtime.InteropServices.Marshal]::StringToHGlobalUni('"' + $FileName + '" ' + $Arguments)
        $applicationName = [Runtime.InteropServices.Marshal]::StringToHGlobalUni($FileName)
        $null = Get-SafeDeleteWatchdogRemaining
        # Explicit Unicode API and caller's current directory/environment. The
        # only inherited handles are the three child pipe ends above.
        if (-not [Codex.SafeDelete.WatchdogNative]::CreateProcessW($applicationName, $commandLine, [IntPtr]::Zero, [IntPtr]::Zero, $true, [uint32]0x08080000, [IntPtr]::Zero, [IntPtr]::Zero, $startup, $processInfo)) { throw 'worker-native-start-failed' }
        $childCreated = $true
        $processHandle = [Runtime.InteropServices.Marshal]::ReadIntPtr($processInfo, 0)
        $threadHandle = [Runtime.InteropServices.Marshal]::ReadIntPtr($processInfo, $pointerSize)
        $workerPid = [Runtime.InteropServices.Marshal]::ReadInt32($processInfo, (2 * $pointerSize))
        $createdProcess = [Diagnostics.Process]::GetProcessById($workerPid)
        # Open the Process handle while the original creation handle keeps the
        # process object alive, so a quick exit remains observable.
        $null = $createdProcess.Handle
        foreach ($childHandle in $childHandles) { $null = [Codex.SafeDelete.WatchdogNative]::CloseHandle($childHandle); $null = $owned.Remove($childHandle) }
        for ($index = 0; $index -lt 3; $index++) {
            $safeHandle = New-Object Microsoft.Win32.SafeHandles.SafeFileHandle($parentHandles[$index], $true)
            $access = if ($index -eq 0) { [IO.FileAccess]::Write } else { [IO.FileAccess]::Read }
            # Anonymous pipes are synchronous. ReadToEndAsync/WriteAsync use
            # background tasks; a one-byte buffer avoids pending text writes.
            $stream = New-Object IO.FileStream($safeHandle, $access, 1, $false)
            $null = $owned.Remove($parentHandles[$index])
            $pipeStreams.Add($stream)
        }
        $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
        $stdout = New-Object IO.StreamReader($pipeStreams[1], $strictUtf8, $false, 1024)
        $stderr = New-Object IO.StreamReader($pipeStreams[2], (New-Object Text.UTF8Encoding($false)), $false, 1024)
        $complete = $true
        return [pscustomobject]@{process=$createdProcess;input=$pipeStreams[0];output=$stdout;error=$stderr}
    } finally {
        if (-not $complete) {
            if ($childCreated -and $processHandle -ne [IntPtr]::Zero) { $null = [Codex.SafeDelete.WatchdogNative]::TerminateProcess($processHandle, [uint32]1) }
            foreach ($stream in $pipeStreams) { try { $stream.Dispose() } catch { } }
            if ($null -ne $createdProcess) { $createdProcess.Dispose() }
        }
        foreach ($handle in $owned) { $null = [Codex.SafeDelete.WatchdogNative]::CloseHandle($handle) }
        if ($threadHandle -ne [IntPtr]::Zero) { $null = [Codex.SafeDelete.WatchdogNative]::CloseHandle($threadHandle) }
        if ($processHandle -ne [IntPtr]::Zero) { $null = [Codex.SafeDelete.WatchdogNative]::CloseHandle($processHandle) }
        if ($attributeInitialized) { [Codex.SafeDelete.WatchdogNative]::DeleteProcThreadAttributeList($attributeList) }
        foreach ($allocation in @($security,$startup,$processInfo,$attributeList,$handleArray,$commandLine,$applicationName)) {
            if ($allocation -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeHGlobal($allocation) }
        }
    }
}

function Test-SafeDeleteWorkerOutput {
    param([string]$Output)
    if ([string]::IsNullOrWhiteSpace($Output) -or $Output.Length -gt 8388608) { return $false }
    $text = $Output.Trim()
    if (-not $text.StartsWith('{') -or -not $text.EndsWith('}')) { return $false }
    # Require exactly one JSON object even on runtimes whose JSON reader accepts
    # another value after it. JSON parsing below validates the actual syntax.
    $depth = 0; $inString = $false; $escaped = $false
    for ($i=0; $i -lt $text.Length; $i++) {
        if (($i -band 1023) -eq 0) { $null = Get-SafeDeleteWatchdogRemaining }
        $character = $text[$i]
        if ($inString) {
            if ($escaped) { $escaped = $false }
            elseif ($character -eq [char]92) { $escaped = $true }
            elseif ($character -eq [char]34) { $inString = $false }
            continue
        }
        if ($character -eq [char]34) { $inString = $true; continue }
        if ($character -eq [char]123 -or $character -eq [char]91) { $depth++ }
        elseif ($character -eq [char]125 -or $character -eq [char]93) {
            $depth--
            if ($depth -lt 0 -or ($depth -eq 0 -and $i -ne ($text.Length - 1))) { return $false }
        }
    }
    if ($inString -or $depth -ne 0) { return $false }
    try { $result = ConvertFrom-Json -InputObject $text -ErrorAction Stop } catch { return $false }
    $null = Get-SafeDeleteWatchdogRemaining
    if ($null -eq $result -or $result -isnot [System.Management.Automation.PSCustomObject]) { return $false }
    if (@($result.PSObject.Properties).Count -eq 0) { return $true }
    foreach ($property in $result.PSObject.Properties) {
        if ($property.Name -cnotin @('hookSpecificOutput','systemMessage')) { return $false }
    }
    $systemMessage = $result.PSObject.Properties['systemMessage']
    if ($null -ne $systemMessage -and $systemMessage.Value -isnot [string]) { return $false }
    $specificProperty = $result.PSObject.Properties['hookSpecificOutput']
    if ($null -eq $specificProperty -or $specificProperty.Value -isnot [System.Management.Automation.PSCustomObject]) { return $false }
    $specific = $specificProperty.Value
    foreach ($property in $specific.PSObject.Properties) {
        if ($property.Name -cnotin @('hookEventName','permissionDecision','permissionDecisionReason','updatedInput')) { return $false }
    }
    $eventName = $specific.PSObject.Properties['hookEventName']
    $decision = $specific.PSObject.Properties['permissionDecision']
    $reason = $specific.PSObject.Properties['permissionDecisionReason']
    if ($null -eq $eventName -or $eventName.Value -isnot [string] -or $eventName.Value -cne 'PreToolUse' -or
        $null -eq $decision -or $decision.Value -isnot [string] -or $decision.Value -cnotin @('allow','deny')) { return $false }
    if ($null -ne $reason -and $reason.Value -isnot [string]) { return $false }
    $updated = $specific.PSObject.Properties['updatedInput']
    if ($decision.Value -ceq 'deny') {
        return ($null -eq $updated -and $null -ne $reason -and -not [string]::IsNullOrWhiteSpace($reason.Value))
    }
    if ($null -eq $updated -or $updated.Value -isnot [System.Management.Automation.PSCustomObject]) { return $false }
    $command = $updated.Value.PSObject.Properties['command']
    return (@($updated.Value.PSObject.Properties).Count -eq 1 -and $null -ne $command -and $command.Name -ceq 'command' -and
        $command.Value -is [string] -and -not [string]::IsNullOrWhiteSpace($command.Value))
}

$process = $null
$inputStream = $null
$started = $false
$inputWriteFailed = $false
$nativePipes = $null
$write = $null; $output = $null; $errors = $null
$failure = 'parent-runtime'
try {
    [Console]::InputEncoding = New-Object Text.UTF8Encoding($false)
    [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
    $buffer = New-Object byte[] 1048577
    $length = 0
    $inputStream = [Console]::OpenStandardInput()
    while ($length -lt $buffer.Length) {
        $failure = 'input-read-or-timeout'
        $read = $inputStream.ReadAsync($buffer, $length, $buffer.Length - $length)
        Wait-SafeDeleteWatchdogTask $read
        if ($read.Result -eq 0) { break }
        $length += $read.Result
    }
    if ($length -gt 1048576) { $failure = 'input-over-1-MiB'; throw 'invalid-input' }
    $failure = 'invalid-input-utf8'
    $utf8 = New-Object Text.UTF8Encoding($false, $true)
    $null = $utf8.GetString($buffer, 0, $length)
    $null = Get-SafeDeleteWatchdogRemaining
    $failure = 'worker-start'
    $start = New-Object Diagnostics.ProcessStartInfo
    $runtime = [Diagnostics.Process]::GetCurrentProcess()
    try { $start.FileName = $runtime.MainModule.FileName } finally { $runtime.Dispose() }
    # ProcessStartInfo passes native argv directly. Apostrophes and $ in a path
    # are literal; no shell evaluates them. Windows paths cannot contain ".
    $start.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Worker'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = New-Object Text.UTF8Encoding($false, $true)
    $start.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $failure = 'worker-handle-isolation-or-start'
    if ($PSVersionTable.PSVersion.Major -le 5) {
        $nativePipes = Start-SafeDeleteWorkerWithHandleList $start.FileName $start.Arguments
        $process = $nativePipes.process
        $started = $true
        $workerInput = $nativePipes.input
        $workerInputOwner = $nativePipes.input
        $output = $nativePipes.output.ReadToEndAsync()
        $errors = $nativePipes.error.ReadToEndAsync()
    } else {
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $start
        $handleFlags = @(Disable-SafeDeleteStandardHandleInheritance)
        try {
            $null = Get-SafeDeleteWatchdogRemaining
            if (-not $process.Start()) { throw 'worker-start-failed' }
            $started = $true
        } finally { Restore-SafeDeleteStandardHandleInheritance $handleFlags }
        $workerInput = $process.StandardInput.BaseStream
        $workerInputOwner = $process.StandardInput
        $output = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
    }
    $failure = 'worker-input-or-timeout'
    try {
        $write = $workerInput.WriteAsync($buffer, 0, $length)
        Wait-SafeDeleteWatchdogTask $write
    } catch {
        if ($_.Exception.GetBaseException() -isnot [IO.IOException]) { throw }
        $inputWriteFailed = $true
    }
    # Raw pipe writes have no StreamWriter text to flush. FlushAsync requests an
    # OS pipe flush and can fault after a quick, successful worker exit. Closing
    # supplies EOF; retain a completed worker's stdout if its pipe already closed.
    try { $workerInputOwner.Close() }
    catch { if ($_.Exception.GetBaseException() -isnot [IO.IOException]) { throw } }
    $failure = 'worker-timeout'
    if (-not $process.WaitForExit((Get-SafeDeleteWatchdogRemaining))) { throw 'watchdog-timeout' }
    $failure = 'worker-output-or-timeout'
    Wait-SafeDeleteWatchdogTask $output
    Wait-SafeDeleteWatchdogTask $errors
    if ($process.ExitCode -ne 0) { $failure = 'worker-nonzero-exit'; throw 'worker-failed' }
    $failure = 'invalid-worker-output'
    if (-not (Test-SafeDeleteWorkerOutput $output.Result)) { throw 'worker-output-invalid' }
    # PowerShell's JSON reader also accepts comments, single quotes and trailing
    # commas. Re-serialize the validated shape so Codex always receives strict
    # JSON; string values, including the replacement command, stay unchanged.
    $validated = ConvertFrom-Json -InputObject $output.Result -ErrorAction Stop
    if ($inputWriteFailed) {
        $specific = $validated.PSObject.Properties['hookSpecificOutput']
        if ($null -eq $specific -or $specific.Value.permissionDecision -cne 'deny') {
            $failure = 'input-not-delivered'; throw 'worker-did-not-check-input'
        }
    }
    $normalized = ConvertTo-Json -InputObject $validated -Depth 8 -Compress
    $null = Get-SafeDeleteWatchdogRemaining
    [Console]::Out.WriteLine($normalized)
} catch {
    Write-SafeDeleteWatchdogDeny $failure
} finally {
    if ($null -ne $process) {
        if ($started) {
            try { if (-not $process.HasExited) { $process.Kill() } } catch { }
        }
        try { $process.Dispose() } catch { }
    }
    if ($null -ne $inputStream) { try { $inputStream.Dispose() } catch { } }
    if ($null -ne $nativePipes) {
        # Disposing a synchronous pipe during an outstanding background read
        # can wait for a descendant. The OS closes these handles at parent exit;
        # none can refer to the SDK pipe because creation used an allowlist.
        if ($null -eq $write -or $write.IsCompleted) { try { $nativePipes.input.Dispose() } catch { } }
        if ($null -eq $output -or $output.IsCompleted) { try { $nativePipes.output.Dispose() } catch { } }
        if ($null -eq $errors -or $errors.IsCompleted) { try { $nativePipes.error.Dispose() } catch { } }
    }
    $watchdogClock.Stop()
}
exit 0
