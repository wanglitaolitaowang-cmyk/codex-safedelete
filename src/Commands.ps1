# Literal commands only. Never evaluate agent-provided code to discover a path.
Set-StrictMode -Version 2.0

function New-SafeDeletePlan {
    param([string]$Action, [string]$Reason, [string[]]$Paths = @(), [string]$Risk = '', [string[]]$LiteralPaths = @())
    [pscustomobject]@{ action = $Action; reason = $Reason; paths = @($Paths); literal_paths = @($LiteralPaths); risk = $Risk }
}

function Get-SafeDeleteLiteral {
    param($Element)
    if ($Element -is [System.Management.Automation.Language.StringConstantExpressionAst]) { return [string]$Element.Value }
    if ($Element -is [System.Management.Automation.Language.ConstantExpressionAst] -and $Element.Value -is [string]) { return [string]$Element.Value }
    throw 'Dynamic expressions are not safe deletion paths. Use safedelete delete with literal paths.'
}

function Get-SafeDeleteCommandName {
    param($Ast)
    $name = $Ast.GetCommandName()
    if (-not $name) { return '' }
    $name = ($name -split '[\\/]')[-1]
    ($name -replace '\.(exe|cmd|bat)$', '').ToLowerInvariant()
}

function Get-SafeDeleteShellKind {
    param([string]$Shell)
    # Windows Codex's tool name "Bash" is a shell-tool abstraction. Only an
    # explicit shell executable changes the default Windows PowerShell dialect.
    if ([string]::IsNullOrWhiteSpace($Shell)) { return 'powershell' }
    $name = ($Shell.Trim().Trim([char[]]@('"', "'")) -split '[\\/]')[-1]
    $name = ($name -replace '\.exe$', '').ToLowerInvariant()
    if ($name -in @('powershell', 'pwsh')) { return 'powershell' }
    if ($name -in @('bash', 'sh')) { return 'posix' }
    if ($name -in @('cmd', 'wsl')) { return $name }
    return 'unsupported'
}

function Get-SafeDeleteNonPowerShellPlan {
    param([string]$Command, [string]$WorkingDirectory, [string]$ProjectRoot, [string]$Shell, [int]$Depth)
    if ($Depth -gt 4) { return New-SafeDeletePlan deny 'Too many nested shells.' }
    $scope = 'Automatic deletion recovery supports Windows PowerShell only. Use PowerShell or safedelete delete with explicit Windows paths.'
    # This deliberately small grammar admits common literal non-deletion work.
    # It does not reinterpret POSIX escapes/paths using a PowerShell AST.
    if ($Command -match '[;&|<>`$()%!^\\\r\n]') {
        return New-SafeDeletePlan deny ('Complex or dynamic non-PowerShell syntax cannot be checked. ' + $scope)
    }
    $words = New-Object 'System.Collections.Generic.List[string]'
    $offset = 0
    while ($offset -lt $Command.Length -and $Command.Substring($offset).Trim().Length -gt 0) {
        $match = [regex]::Match($Command.Substring($offset), '^\s*(?:''(?<single>[^'']*)''|"(?<double>[^"]*)"|(?<bare>[A-Za-z0-9_./:=,@+-]+))(?=\s|$)')
        if (-not $match.Success -or ($words.Count -eq 0 -and -not $match.Groups['bare'].Success)) {
            return New-SafeDeletePlan deny ('Quoted, escaped or opaque command names and unsupported arguments cannot be checked. ' + $scope)
        }
        if ($match.Groups['single'].Success) { $words.Add($match.Groups['single'].Value) }
        elseif ($match.Groups['double'].Success) { $words.Add($match.Groups['double'].Value) }
        else { $words.Add($match.Groups['bare'].Value) }
        $offset += $match.Length
    }
    if ($words.Count -eq 0 -or $words[0] -notmatch '^[A-Za-z][A-Za-z0-9_.-]*$') {
        return New-SafeDeletePlan deny ('An explicit simple command name is required. ' + $scope)
    }
    $name = ($words[0] -replace '\.(exe|cmd|bat)$', '').ToLowerInvariant()
    if ($name -in @('rm', 'del', 'erase', 'rmdir', 'rd', 'remove-item', 'ri')) {
        return New-SafeDeletePlan deny ('Deletion in this shell is blocked. ' + $scope)
    }
    if ($name -eq 'echo' -or
        ($name -eq 'git' -and $words.Count -ge 2 -and $words[1] -eq 'status') -or
        ($name -eq 'npm' -and $words.Count -ge 2 -and $words[1] -eq 'test') -or
        ($name -in @('git', 'npm') -and $words.Count -eq 2 -and $words[1] -eq '--version')) {
        return New-SafeDeletePlan allow 'A simple literal non-deletion command is allowed in this shell.'
    }
    if ($name -in @('bash', 'sh', 'cmd', 'wsl')) {
        $flag = -1
        for ($i = 1; $i -lt $words.Count; $i++) {
            if (($name -eq 'cmd' -and $words[$i] -eq '/c') -or
                ($name -in @('bash', 'sh') -and $words[$i] -match '^-[el]*c[el]*$') -or
                ($name -eq 'wsl' -and $words[$i] -in @('-e', '--exec', '--'))) { $flag = $i; break }
            if (($name -in @('bash', 'sh') -and $words[$i] -in @('-e', '-l', '-f', '--noprofile', '--norc')) -or
                ($name -eq 'cmd' -and $words[$i] -in @('/d', '/s', '/q', '/a', '/u', '/v:on', '/v:off', '/e:on', '/e:off'))) { continue }
            return New-SafeDeletePlan deny ('Unsupported shell startup arguments cannot be checked. ' + $scope)
        }
        if ($flag -ge 0 -and $flag + 1 -lt $words.Count) {
            if ($name -in @('bash', 'sh') -and $words.Count -ne $flag + 2) {
                return New-SafeDeletePlan deny ('Extra shell command arguments cannot be checked. ' + $scope)
            }
            $inner = ($words.ToArray()[($flag + 1)..($words.Count - 1)] -join ' ')
            return Get-SafeDeleteCommandPlan -Command $inner -WorkingDirectory $WorkingDirectory -ProjectRoot $ProjectRoot -Depth ($Depth + 1) -Shell $name
        }
    }
    return New-SafeDeletePlan deny ('Only simple literal git status, npm test and echo commands are supported in this shell. ' + $scope)
}

function Get-SafeDeleteCommandPlan {
    param([Parameter(Mandatory)][string]$Command,
          [Parameter(Mandatory)][string]$WorkingDirectory,
          [Parameter(Mandatory)][string]$ProjectRoot,
          [int]$Depth = 0,
          [string]$Shell = '')
    if ($Depth -gt 4) { return New-SafeDeletePlan deny 'Too many nested shells.' }
    $hasShellMetadata = -not [string]::IsNullOrWhiteSpace($Shell)
    $shellKind = Get-SafeDeleteShellKind $Shell
    if ($shellKind -eq 'unsupported') { return New-SafeDeletePlan deny 'Unsupported shell. Use Windows PowerShell for automatic deletion recovery.' }
    if ($shellKind -ne 'powershell') {
        return Get-SafeDeleteNonPowerShellPlan $Command $WorkingDirectory $ProjectRoot $Shell $Depth
    }
    $tokens = $null; $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Command, [ref]$tokens, [ref]$parseErrors)
    if (-not $hasShellMetadata -and $parseErrors.Count -gt 0 -and $Command -match '(?m)(?:^|[;&|])\s*["'']') {
        return New-SafeDeletePlan deny 'A quoted command name cannot be checked without explicit shell metadata. Use an explicit Windows PowerShell shell.'
    }
    $commands = @($ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] }, $true))
    $danger = @(); $wrappers = @()
    foreach ($c in $commands) {
        $rawName = $c.GetCommandName()
        if (-not $hasShellMetadata -and $rawName -and $rawName.Contains('\') -and
            $rawName -notmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\]+\\[^\\]+)' -and
            $c.InvocationOperator -ne [System.Management.Automation.Language.TokenKind]::Ampersand) {
            return New-SafeDeletePlan deny 'An escaped or relative command name cannot be checked without explicit shell metadata. Use an absolute Windows executable or explicit Windows PowerShell shell.'
        }
        $n = Get-SafeDeleteCommandName $c
        if (-not $n -or $n -in @('invoke-expression', 'iex', 'eval')) {
            return New-SafeDeletePlan deny 'Dynamic command execution cannot be checked. Use literal commands.'
        }
        if (-not $hasShellMetadata -and $n -in @('rm', 'del', 'erase', 'rmdir', 'rd')) {
            return New-SafeDeletePlan deny 'The shell for this deletion alias is not specified. Use Remove-Item, an explicit powershell/pwsh wrapper, or explicit PowerShell shell metadata.'
        }
        if ($n -in @('rm', 'del', 'erase', 'rmdir', 'rd', 'remove-item', 'ri')) { $danger += $c }
        if ($n -eq 'git') {
            $gitArguments = @()
            try {
                foreach ($element in @($c.CommandElements | Select-Object -Skip 1)) {
                    if ($element -is [System.Management.Automation.Language.CommandParameterAst]) { $gitArguments += '-' + $element.ParameterName }
                    else { $gitArguments += Get-SafeDeleteLiteral $element }
                }
            } catch { return New-SafeDeletePlan deny 'Dynamic Git arguments cannot be checked.' }
            if (@($gitArguments | Where-Object { $_ -match '(?i)^alias\.[^=]+=' }).Count -gt 0) { return New-SafeDeletePlan deny 'Git alias definitions cannot be checked safely.' }
            if ('clean' -in $gitArguments -or ('reset' -in $gitArguments -and @($gitArguments | Where-Object { $_ -match '^--h(a(r(d)?)?)?$' }).Count -gt 0)) { $danger += $c }
        }
        if ($n -in @('powershell', 'pwsh', 'cmd', 'bash', 'sh', 'wsl')) { $wrappers += $c }
        if ($n -in @('command','env','sudo','nohup','timeout') -and $c.Extent.Text -match '(?i)\b(rm|del|erase|rmdir|rd|remove-item|git\s+clean)\b') {
            return New-SafeDeletePlan deny 'Deletion through an indirect command launcher is blocked.'
        }
        if ($n -match '\.ps1$' -and $n -ne 'safedelete.ps1') { return New-SafeDeletePlan deny 'Shell scripts cannot be checked safely. Use explicit commands.' }
        if ($n -in @('python', 'python3', 'node', 'ruby', 'perl') -and $c.Extent.Text -match '(?i)\b(unlink|rmtree|remove|rmdir|rmSync|rm\s*\(|delete)\b') {
            return New-SafeDeletePlan deny 'Inline permanent deletion APIs are blocked. Use safedelete delete.'
        }
    }
    $memberCalls = @($ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true))
    foreach ($call in $memberCalls) {
        if ($call.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $call.Member.Value -eq 'Delete') {
            return New-SafeDeletePlan deny 'Permanent deletion APIs are blocked. Use safedelete delete.'
        }
        if ($call.Expression -is [System.Management.Automation.Language.TypeExpressionAst] -and
            $call.Expression.TypeName.FullName -match '(?i)^(System\.)?IO\.(File|Directory)$' -and
            $call.Member -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
            return New-SafeDeletePlan deny 'Dynamic filesystem API calls cannot be checked.'
        }
    }
    # Resolve explicit shell command strings, including cmd /c. Encoded shells are opaque.
    foreach ($wrapper in $wrappers) {
        $n = Get-SafeDeleteCommandName $wrapper
        $e = @($wrapper.CommandElements)
        $flag = -1
        $noProfile = $false
        for ($i = 1; $i -lt $e.Count; $i++) {
            $word = $e[$i].Extent.Text.Trim('"', "'").ToLowerInvariant()
            if ($n -in @('powershell', 'pwsh')) {
                if ($e[$i] -is [System.Management.Automation.Language.CommandParameterAst]) {
                    if ($e[$i].Argument) { return New-SafeDeletePlan deny 'Attached or dynamic PowerShell startup arguments cannot be checked.' }
                } else {
                    try { $word = (Get-SafeDeleteLiteral $e[$i]).ToLowerInvariant() }
                    catch { return New-SafeDeletePlan deny 'Dynamic PowerShell startup arguments cannot be checked.' }
                }
                if (-not $word.StartsWith('-') -or $word.Length -lt 2) { return New-SafeDeletePlan deny 'Unsupported PowerShell startup arguments cannot be checked.' }
                $parameter = $word.Substring(1)
                if ('encodedcommand'.StartsWith($parameter) -or 'encodedarguments'.StartsWith($parameter) -or $parameter -eq 'ec') {
                    return New-SafeDeletePlan deny 'Encoded PowerShell commands cannot be checked.'
                }
                if ('file'.StartsWith($parameter)) { return New-SafeDeletePlan deny 'PowerShell script execution cannot be checked safely. Use explicit commands.' }
                if ('workingdirectory'.StartsWith($parameter) -or $parameter -eq 'wd') { return New-SafeDeletePlan deny 'PowerShell startup directory changes cannot be recovered safely. Set the tool workdir instead.' }
                if ($word -match '^-(c|co|com|comm|comma|comman|command)$') { $flag = $i; break }
                if ($word -in @('-noprofile', '-nop')) { $noProfile = $true; continue }
                if ($word -in @('-nologo', '-noninteractive', '-sta', '-mta')) { continue }
                if ($word -eq '-executionpolicy' -and $i + 1 -lt $e.Count) {
                    try { $policy = Get-SafeDeleteLiteral $e[$i + 1] } catch { return New-SafeDeletePlan deny 'Dynamic PowerShell startup arguments cannot be checked.' }
                    if ($policy -notin @('Bypass','RemoteSigned','Unrestricted','Restricted','AllSigned','Default','Undefined')) { return New-SafeDeletePlan deny 'Unsupported PowerShell execution policy.' }
                    $i++; continue
                }
                return New-SafeDeletePlan deny 'Unsupported PowerShell startup arguments cannot be checked. Use -NoProfile -Command with literal commands.'
            }
            if (($n -eq 'cmd' -and $word -eq '/c') -or
                ($n -in @('bash','sh') -and $word -match '^-[el]*c[el]*$') -or
                ($n -eq 'wsl' -and $word -in @('-e', '--exec', '--'))) { $flag = $i; break }
            if (($n -in @('bash', 'sh') -and $word -in @('-e', '-l', '-f', '--noprofile', '--norc')) -or
                ($n -eq 'cmd' -and $word -in @('/d', '/s', '/q', '/a', '/u', '/v:on', '/v:off', '/e:on', '/e:off'))) { continue }
            return New-SafeDeletePlan deny 'Unsupported shell startup arguments cannot be checked.'
        }
        if ($flag -ge 0 -and ($flag + 1) -lt $e.Count) {
            try {
                if ($e.Count -eq ($flag + 2)) { $inner = Get-SafeDeleteLiteral $e[$flag + 1] }
                else { $inner = $Command.Substring($e[$flag + 1].Extent.StartOffset, $wrapper.Extent.EndOffset - $e[$flag + 1].Extent.StartOffset) }
                $plan = Get-SafeDeleteCommandPlan -Command $inner -WorkingDirectory $WorkingDirectory -ProjectRoot $ProjectRoot -Depth ($Depth + 1) -Shell $n
                if ($plan.action -eq 'delete' -and $n -in @('powershell', 'pwsh') -and -not $noProfile) {
                    return New-SafeDeletePlan deny 'PowerShell wrapper deletion requires -NoProfile so startup profiles cannot change the deletion directory.'
                }
                if ($plan.action -ne 'allow') {
                    if ($commands.Count -ne 1) { return New-SafeDeletePlan deny 'Deletion mixed with other commands is blocked. Split the commands.' }
                    return $plan
                }
            } catch { return New-SafeDeletePlan deny $_.Exception.Message }
        } else { return New-SafeDeletePlan deny 'Opaque or interactive shell execution cannot be checked. Use an explicit shell command string.' }
    }
    if ($danger.Count -eq 0) {
        if ($parseErrors.Count -gt 0 -and $Command -match '(?i)(?:^|[;&|\s])(?:rm|del|erase|rd|rmdir|remove-item|git\s+clean)\b') {
            return New-SafeDeletePlan deny 'Deletion syntax could not be parsed safely.'
        }
        return New-SafeDeletePlan allow 'No recognized deletion command.'
    }
    if ($parseErrors.Count -gt 0) { return New-SafeDeletePlan deny 'Deletion syntax could not be parsed safely.' }
    if ($commands.Count -ne 1 -or $danger.Count -ne 1 -or $ast.EndBlock.Statements.Count -ne 1 -or
        $ast.EndBlock.Statements[0] -isnot [System.Management.Automation.Language.PipelineAst] -or
        $ast.EndBlock.Statements[0].PipelineElements.Count -ne 1 -or $danger[0].Redirections.Count -gt 0) {
        return New-SafeDeletePlan deny 'Deletion mixed with other commands is blocked. Split the commands.'
    }
    $c = $danger[0]; $n = Get-SafeDeleteCommandName $c
    if ($n -eq 'git') { return New-SafeDeletePlan deny 'git clean and git reset --hard are blocked; use safedelete delete for explicit files.' }
    $paths = @(); $literals = @(); $recursive = $false; $literalMode = $false
    try {
        foreach ($e in @($c.CommandElements | Select-Object -Skip 1)) {
            if ($e -is [System.Management.Automation.Language.CommandParameterAst]) {
                if ($e.Argument) { throw 'Attached or dynamic parameter values are blocked.' }
                $word = '-' + $e.ParameterName
            } else { $word = Get-SafeDeleteLiteral $e }
            if (-not $literalMode -and $word -eq '--') { $literalMode = $true; continue }
            if (-not $literalMode -and $word.StartsWith('-')) {
                if ($word -match '(?i)^-(recurse|r)$|^--recursive$|^-[rfvd]+$') { if ($word -match '(?i)r') { $recursive = $true }; continue }
                if ($word -match '(?i)^-(force|f|literalpath|path|verbose)$|^--force$') { continue }
                throw ('Unsupported deletion option: ' + $word)
            }
            if (-not $literalMode -and $n -in @('del','erase','rd','rmdir') -and $word -match '^/') {
                if ($word -match '(?i)^/[sqf]$') { if ($word -match '(?i)^/s$') { $recursive = $true }; continue }
                # An absolute Unix path is rejected by the storage boundary on Windows.
                throw ('Unsupported deletion option: ' + $word)
            }
            if ([string]::IsNullOrWhiteSpace($word) -or $word -match '[*?\[\]]') { throw 'Wildcards and empty deletion paths are blocked. Use explicit paths.' }
            if ($word -match '^~|^\w+::|^[a-zA-Z]+:(?![\\/])') { throw 'Home expansion, providers and drive-relative paths are blocked.' }
            if ([IO.Path]::IsPathRooted($word)) { $p = [IO.Path]::GetFullPath($word) }
            else { $p = [IO.Path]::GetFullPath((Join-Path $WorkingDirectory $word)) }
            $cleanRoot = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd([char[]]'\/')
            $cleanPath = $p.TrimEnd([char[]]'\/')
            if ($cleanPath -eq $cleanRoot -or -not $cleanPath.StartsWith($cleanRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'The project root, its parents, and paths outside the project are blocked.'
            }
            if (($cleanPath -split '[\\/]') | Where-Object { $_ -in @('.git','.env','.ssh','.codex-safedelete') }) {
                throw 'Sensitive paths (.git, .env, .ssh, .codex-safedelete) are blocked.'
            }
            $paths += $p
            $literals += $word
        }
        if ($paths.Count -eq 0) { throw 'No explicit deletion path found.' }
        $risk = 'Delete file / directory'
        if ($recursive) { $risk = 'Recursive deletion' }
        return New-SafeDeletePlan delete 'Original deletion blocked; literal targets can be moved to recoverable trash.' $paths $risk $literals
    } catch { return New-SafeDeletePlan deny $_.Exception.Message }
}
