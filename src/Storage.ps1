# Local recoverable deletion. Compatible with Windows PowerShell 5.1 and PowerShell 7.
# Commands are stored as text only; this file never executes them.

function Get-SDAbsolutePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ($Path.StartsWith('\\?\') -or $Path.StartsWith('\\.\')) { throw "DENY: Windows device namespace: $Path" }
    if (-not [IO.Path]::IsPathRooted($Path) -or
        ($env:OS -eq 'Windows_NT' -and $Path -notmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\]+\\[^\\]+)')) {
        throw "DENY: an absolute filesystem path is required: $Path"
    }
    $full = [IO.Path]::GetFullPath($Path)
    $volume = [IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $volume.Length) { $full = $full.TrimEnd([char[]]@('\', '/')) }
    # Get-Item expands existing Windows 8.3 names (for example PROGRA~1).
    # Canonicalize the closest existing parent as well when restoring a missing file.
    $cursor = $full
    $missing = New-Object 'System.Collections.Generic.Stack[string]'
    while ($cursor) {
        try {
            $existing = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            $full = $existing.FullName
            while ($missing.Count -gt 0) { $full = Join-Path $full $missing.Pop() }
            break
        } catch [System.Management.Automation.ItemNotFoundException] {
            $missing.Push([IO.Path]::GetFileName($cursor))
            $parent = [IO.Directory]::GetParent($cursor)
            if ($null -eq $parent) { break }
            $cursor = $parent.FullName
        }
    }
    return $full
}

function Test-SDWithin {
    param([string]$Path, [string]$Parent)
    return $Path.StartsWith($Parent.TrimEnd([char[]]@('\', '/')) + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)
}

function Get-SDItem {
    param([string]$Path)
    # Get-Item also detects dangling links, unlike File.Exists / Directory.Exists.
    return Get-Item -LiteralPath $Path -Force -ErrorAction Stop
}

function Test-SDExists {
    param([string]$Path)
    try { $null = Get-SDItem $Path; return $true }
    catch [System.Management.Automation.ItemNotFoundException] { return $false }
}

function Assert-SDNoReparse {
    param([string]$Path)
    $cursor = $Path
    while ($cursor) {
        if (Test-SDExists $cursor) {
            $item = Get-SDItem $cursor
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "DENY: a path or its parent is a reparse point: $cursor"
            }
        }
        $parent = [IO.Directory]::GetParent($cursor)
        if ($null -eq $parent) { break }
        $cursor = $parent.FullName
    }
}

function Assert-SDProtectedPath {
    param([string]$Path)
    if ($Path -eq [IO.Path]::GetPathRoot($Path)) { throw "DENY: drive root: $Path" }
    foreach ($segment in ($Path -split '[\\/]')) {
        # Windows normalizes trailing dots/spaces; never let that bypass protection.
        if ($segment.TrimEnd([char[]]@('.', ' ')) -in @('.git', '.env', '.ssh', '.codex', '.codex-safedelete')) {
            throw "DENY: protected name in path: $Path"
        }
    }
    if ($env:USERPROFILE -and $Path -eq (Get-SDAbsolutePath $env:USERPROFILE)) {
        throw "DENY: user home directory: $Path"
    }
    if ($Path -eq 'C:\Users' -or ($env:SystemDrive -and $Path -eq ($env:SystemDrive + '\Users'))) {
        throw "DENY: users directory: $Path"
    }
    # Alternate data streams and Windows device names are not ordinary payloads.
    if ($env:OS -eq 'Windows_NT') {
        $tail = $Path.Substring([IO.Path]::GetPathRoot($Path).Length)
        if ($tail.Contains(':') -or $tail -match '(^|[\\/])(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|[\\/]|$)') {
            throw "DENY: special Windows path: $Path"
        }
    }
}

function Get-SDProjectRoot {
    param([string]$ProjectRoot)
    $root = Get-SDAbsolutePath $ProjectRoot
    Assert-SDProtectedPath $root
    Assert-SDNoReparse $root
    if (-not (Get-SDItem $root).PSIsContainer) { throw "DENY: project root must be a directory: $root" }
    return $root
}

function Assert-SDTarget {
    param([string]$Path, [string]$ProjectRoot)
    if (-not (Test-SDWithin $Path $ProjectRoot)) {
        throw "DENY: project root, its parents, and paths outside the project cannot be deleted: $Path"
    }
    Assert-SDProtectedPath $Path
    Assert-SDNoReparse $Path
}

function Get-SafeDeleteRoot {
    param([Parameter(Mandatory = $true)][string]$WorkingDirectory)
    $working = Get-SDAbsolutePath $WorkingDirectory
    $cursor = $working
    while ($cursor) {
        if ((Test-SDExists (Join-Path $cursor '.codex-safedelete')) -or
            (Test-SDExists (Join-Path $cursor '.git'))) { return $cursor }
        $parent = [IO.Directory]::GetParent($cursor)
        if ($null -eq $parent) { break }
        $cursor = $parent.FullName
    }
    return $working
}

function Initialize-SafeDeleteStore {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)
    $root = Get-SDProjectRoot $ProjectRoot
    $store = Join-Path $root '.codex-safedelete'
    $trash = Join-Path $store 'trash'
    Assert-SDNoReparse $store
    Assert-SDNoReparse $trash
    $null = [IO.Directory]::CreateDirectory($trash)
    return $store
}

function Enter-SDLock {
    param([string]$Store)
    $path = Join-Path $Store 'store.lock'
    Assert-SDNoReparse $path
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        try { return [IO.File]::Open($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch [IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) { throw 'SafeDelete store is busy; retry shortly.' }
            Start-Sleep -Milliseconds 100
        }
    } while ($true)
}

function Read-SDHistory {
    param([string]$Store)
    $path = Join-Path $Store 'history.json'
    Assert-SDNoReparse $path
    if (-not (Test-SDExists $path)) { return }
    $json = [IO.File]::ReadAllText($path)
    if (-not $json.TrimStart().StartsWith('[')) { throw 'SafeDelete history is invalid; expected a JSON array.' }
    # 5.1 emits a JSON array as one pipeline object; 7 enumerates it. Assignment
    # followed by foreach handles both without creating a nested array.
    try { $records = ConvertFrom-Json -InputObject $json -ErrorAction Stop }
    catch { throw "SafeDelete history is invalid: $($_.Exception.Message)" }
    $ids = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($record in $records) {
        if ($null -eq $record -or $record.id -notmatch '^[a-f0-9]{32}$' -or
            $record.status -notin @('pending', 'active', 'restoring', 'restored', 'cancelled') -or
            $null -eq $record.items -or @($record.items).Count -eq 0 -or @($record.items).Count -gt 1000) {
            throw 'SafeDelete history contains an invalid record.'
        }
        if (-not $ids.Add($record.id)) { throw 'SafeDelete history contains duplicate record IDs.' }
        $record
    }
}

function Write-SDHistory {
    param([string]$Store, [object[]]$History)
    $path = Join-Path $Store 'history.json'
    Assert-SDNoReparse $path
    $temp = Join-Path $Store ('history.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $json = ConvertTo-Json -InputObject @($History) -Depth 8
    $stream = [IO.File]::Open($temp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($json)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally { $stream.Dispose() }
    if (Test-SDExists $path) { [IO.File]::Replace($temp, $path, [NullString]::Value) }
    else { [IO.File]::Move($temp, $path) }
}

function Get-SafeDeleteHistory {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)
    $store = Initialize-SafeDeleteStore $ProjectRoot
    $lock = Enter-SDLock $store
    try { Read-SDHistory $store } finally { $lock.Dispose() }
}

function Assert-SDNoOverlap {
    param([string[]]$Paths)
    for ($i = 0; $i -lt $Paths.Count; $i++) {
        for ($j = $i + 1; $j -lt $Paths.Count; $j++) {
            if ($Paths[$i] -eq $Paths[$j] -or (Test-SDWithin $Paths[$i] $Paths[$j]) -or (Test-SDWithin $Paths[$j] $Paths[$i])) {
                throw "DENY: duplicate or overlapping targets: $($Paths[$i]), $($Paths[$j])"
            }
        }
    }
}

function Assert-SDPayloads {
    param([string[]]$Paths, [string]$ProjectRoot)
    if ($Paths.Count -gt 1000) { throw 'DENY: deletion contains more than 1000 files/directories.' }
    $nodes = 0
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    foreach ($path in $Paths) { $stack.Push($path) }
    while ($stack.Count -gt 0) {
        $path = $stack.Pop()
        Assert-SDTarget $path $ProjectRoot
        $item = Get-SDItem $path
        $nodes++
        if ($nodes -gt 1000) { throw 'DENY: deletion contains more than 1000 files/directories.' }
        if ($item.PSIsContainer) {
            # Enumerate one directory at a time; no recursive API follows links.
            foreach ($child in [IO.Directory]::EnumerateFileSystemEntries($path)) {
                $stack.Push($child)
                if ($nodes + $stack.Count -gt 1000) { throw 'DENY: deletion contains more than 1000 files/directories.' }
            }
        }
    }
}

function Move-SDItem {
    param([string]$Source, [string]$Destination, [string]$Type)
    # Same-volume moves preserve the payload without copying or deleting it.
    if ([IO.Path]::GetPathRoot($Source) -ne [IO.Path]::GetPathRoot($Destination)) { throw 'DENY: cross-volume move.' }
    if ($Type -eq 'directory') { [IO.Directory]::Move($Source, $Destination) }
    else { [IO.File]::Move($Source, $Destination) }
}

function Get-SDPayloadFingerprint {
    param([string]$Path, [string]$OriginalPath, [string]$Type, [ref]$Nodes)
    $payload = Get-SDItem $Path
    if (($payload.PSIsContainer -and $Type -ne 'directory') -or
        (-not $payload.PSIsContainer -and $Type -ne 'file')) { throw 'DENY: payload type does not match history.' }
    $entries = New-Object 'System.Collections.Generic.List[string]'
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $part = $stack.Pop()
        Assert-SDNoReparse $part
        $relative = ''
        if ($part -ne $Path) {
            $relative = $part.Substring($Path.Length + 1)
            Assert-SDProtectedPath (Join-Path $OriginalPath $relative)
        }
        $childItem = Get-SDItem $part
        $Nodes.Value++
        if ($Nodes.Value -gt 1000) { throw 'DENY: payload contains more than 1000 nodes.' }
        # Length-prefix names and sort ordinally so empty directories, node types,
        # and every file's full contents contribute to a stable tree fingerprint.
        $key = $relative.Length.ToString() + ':' + $relative
        if ($childItem.PSIsContainer) {
            $entries.Add('D:' + $key)
            foreach ($child in [IO.Directory]::EnumerateFileSystemEntries($part)) {
                $stack.Push($child)
                if ($Nodes.Value + $stack.Count -gt 1000) { throw 'DENY: payload contains more than 1000 nodes.' }
            }
        } else {
            # .cmd invokes Windows PowerShell even from PowerShell 7, whose inherited
            # PSModulePath can prevent Get-FileHash from loading. Use .NET directly.
            $stream = [IO.File]::OpenRead($part)
            $fileSha = [Security.Cryptography.SHA256]::Create()
            try { $hash = ([BitConverter]::ToString($fileSha.ComputeHash($stream))).Replace('-', '') }
            finally { $fileSha.Dispose(); $stream.Dispose() }
            $entries.Add('F:' + $key + ':' + $childItem.Length.ToString() + ':' + $hash)
        }
    }
    $ordered = $entries.ToArray()
    [Array]::Sort($ordered, [StringComparer]::Ordinal)
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes(($ordered -join "`n"))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function Move-SafeDeleteItems {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string[]]$Paths,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Command
    )
    $root = Get-SDProjectRoot $ProjectRoot
    if ($Paths.Count -eq 0) { throw 'DENY: no deletion targets.' }
    $targets = @($Paths | ForEach-Object { Get-SDAbsolutePath $_ })
    Assert-SDNoOverlap $targets
    # Complete preflight before creating a record or moving any payload.
    Assert-SDPayloads $targets $root
    $store = Initialize-SafeDeleteStore $root
    $lock = Enter-SDLock $store
    try {
        $history = @(Read-SDHistory $store)
        # Recheck after taking the lock, in case another SafeDelete operation moved a target.
        Assert-SDPayloads $targets $root
        $id = [Guid]::NewGuid().ToString('N')
        $batch = Join-Path (Join-Path $store 'trash') $id
        Assert-SDNoReparse $batch
        $null = [IO.Directory]::CreateDirectory($batch)
        $items = @()
        $fingerprintNodes = 0
        for ($i = 0; $i -lt $targets.Count; $i++) {
            $item = Get-SDItem $targets[$i]
            $type = $(if ($item.PSIsContainer) { 'directory' } else { 'file' })
            $items += [pscustomobject]@{
                original_path = $targets[$i]
                name = $item.Name
                trash_path = Join-Path $batch ($i.ToString() + '-' + $item.Name)
                type = $type
                source_fingerprint = Get-SDPayloadFingerprint $targets[$i] $targets[$i] $type ([ref]$fingerprintNodes)
            }
        }
        $record = [pscustomobject]@{
            id = $id; deleted_at = [DateTime]::UtcNow.ToString('o'); command = $Command
            status = 'pending'; items = $items
        }
        $history += $record
        Write-SDHistory $store $history
        try {
            foreach ($item in $items) { Move-SDItem $item.original_path $item.trash_path $item.type }
            $record.status = 'active'
            Write-SDHistory $store $history
        } catch {
            throw "SafeDelete move interrupted; recover record $id with restore or undo. $($_.Exception.Message)"
        }
        return $record
    } finally { $lock.Dispose() }
}

function Restore-SafeDeleteRecord {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot, [string]$Id)
    $root = Get-SDProjectRoot $ProjectRoot
    $store = Initialize-SafeDeleteStore $root
    $lock = Enter-SDLock $store
    try {
        $history = @(Read-SDHistory $store)
        if ($Id) {
            $matches = @($history | Where-Object { $_.id -eq $Id })
            if ($matches.Count -ne 1) { throw "SafeDelete record not found or duplicated: $Id" }
            $available = $matches
        } else {
            $available = @($history | Where-Object { $_.status -in @('pending', 'active', 'restoring') })
            if ($available.Count -eq 0) { throw 'No deletion to undo.' }
        }
        for ($candidate = $available.Count - 1; $candidate -ge 0; $candidate--) {
            $record = $available[$candidate]
            if ($record.status -eq 'restored') { throw "Record already restored: $($record.id)" }
            if ($record.status -eq 'cancelled') { throw "Record cancelled; no files were restored: $($record.id)" }
            $restore = @()
            $originals = @()
            $fingerprints = @()
            $verifiedOriginals = $true
            $batch = Join-Path (Join-Path $store 'trash') $record.id
            $index = 0
            $payloadNodes = 0
            foreach ($item in @($record.items)) {
                if ($null -eq $item -or $item.type -notin @('file', 'directory') -or
                    -not ($item.original_path -is [string]) -or -not ($item.trash_path -is [string])) {
                    throw 'DENY: invalid item in history.'
                }
                $original = Get-SDAbsolutePath $item.original_path
                Assert-SDTarget $original $root
                $name = [IO.Path]::GetFileName($original)
                $expected = Join-Path $batch ($index.ToString() + '-' + $name)
                $trash = Get-SDAbsolutePath $item.trash_path
                if ($trash -ne $expected -or $item.name -ne $name) { throw 'DENY: history contains an invalid trash path or name.' }
                Assert-SDNoReparse $trash
                foreach ($field in @('source_fingerprint', 'restore_fingerprint')) {
                    $proof = $item.PSObject.Properties[$field]
                    if ($null -ne $proof -and (-not ($proof.Value -is [string]) -or $proof.Value -notmatch '^[A-Fa-f0-9]{64}$')) {
                        throw 'DENY: history contains an invalid payload fingerprint.'
                    }
                }
                $originals += $original
                if (Test-SDExists $trash) {
                    if (Test-SDExists $original) { throw "Restore conflict; original path already exists: $original" }
                    # Validate the entire payload again: trash might have changed since deletion.
                    $fingerprints += Get-SDPayloadFingerprint $trash $original $item.type ([ref]$payloadNodes)
                    $restore += $item
                } else {
                    if ($record.status -eq 'active' -or -not (Test-SDExists $original)) {
                        throw "Missing recoverable payload: $trash"
                    }
                    $fingerprint = Get-SDPayloadFingerprint $original $original $item.type ([ref]$payloadNodes)
                    $fingerprints += $fingerprint
                    $field = $(if ($record.status -eq 'restoring') { 'restore_fingerprint' } else { 'source_fingerprint' })
                    $proof = $item.PSObject.Properties[$field]
                    if ($null -eq $proof) { $verifiedOriginals = $false }
                    elseif ($fingerprint -ne $proof.Value) { throw "Restore conflict; original payload does not match recovery evidence: $original" }
                }
                $index++
            }
            Assert-SDNoOverlap $originals
            if ($restore.Count -eq 0) {
                if ($verifiedOriginals -and $record.status -eq 'restoring') {
                    # All moves finished; only the durable terminal journal write failed.
                    $record.status = 'restored'
                    Write-SDHistory $store $history
                    return $record
                }
                if ($verifiedOriginals -and $record.status -eq 'pending') {
                    $record.status = 'cancelled'
                    Write-SDHistory $store $history
                    if ($Id) { throw "Record cancelled; no files were restored: $($record.id)" }
                } elseif ($Id) {
                    throw "No recoverable payload exists; original payload cannot be verified for record: $($record.id)"
                }
                # Legacy empty records have no proof of completed moves. Preserve their
                # status, make no restoration claim, and let undo reach an older record.
                continue
            }
            if ($record.status -eq 'restoring' -and -not $verifiedOriginals) {
                throw "Cannot verify previously restored payload; historical content evidence is missing for record $($record.id). Remaining trash is preserved; verify the original paths before recovering it manually."
            }
            for ($i = 0; $i -lt @($record.items).Count; $i++) {
                $record.items[$i] | Add-Member -NotePropertyName restore_fingerprint -NotePropertyValue $fingerprints[$i] -Force
            }
            $record.status = 'restoring'
            Write-SDHistory $store $history
            foreach ($item in $restore) {
                $parent = [IO.Path]::GetDirectoryName($item.original_path)
                Assert-SDNoReparse $parent
                $null = [IO.Directory]::CreateDirectory($parent)
                if (Test-SDExists $item.original_path) { throw "Restore conflict; original path already exists: $($item.original_path)" }
                Move-SDItem $item.trash_path $item.original_path $item.type
            }
            $record.status = 'restored'
            Write-SDHistory $store $history
            return $record
        }
        throw 'No deletion to undo. Empty interrupted records have no verified recoverable payload.'
    } finally { $lock.Dispose() }
}
