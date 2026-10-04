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

function Get-SafeDeleteCommandPlan {
    param([Parameter(Mandatory)][string]$Command,
          [Parameter(Mandatory)][string]$WorkingDirectory,
          [Parameter(Mandatory)][string]$ProjectRoot,
          [int]$Depth = 0)
    if ($Depth -gt 4) { return New-SafeDeletePlan deny 'Too many nested shells.' }
    $tokens = $null; $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Command, [ref]$tokens, [ref]$parseErrors)
    $commands = @($ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] }, $true))
    $danger = @(); $wrappers = @()
    foreach ($c in $commands) {
        $n = Get-SafeDeleteCommandName $c
        if (-not $n -or $n -in @('invoke-expression', 'iex', 'eval')) {
            return New-SafeDeletePlan deny 'Dynamic command execution cannot be checked. Use literal commands.'
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
        if ($wrapper.Extent.Text -match '(?i)\s-(?:file|f)\s') {
            return New-SafeDeletePlan deny 'Shell script execution cannot be checked safely. Use explicit commands.'
        }
        if ($wrapper.Extent.Text -match '(?i)\s-(?:e|en|enc|enco|encod|encode|encoded|encodedcommand)\b') {
            return New-SafeDeletePlan deny 'Encoded shell commands cannot be checked.'
        }
        $flag = -1
        for ($i = 1; $i -lt $e.Count; $i++) {
            $word = $e[$i].Extent.Text.Trim('"', "'").ToLowerInvariant()
            if (($n -eq 'cmd' -and $word -in @('/c','/k')) -or ($n -in @('powershell','pwsh') -and $word -match '^-(c|co|com|comm|comma|comman|command)$') -or ($n -in @('bash','sh','wsl') -and $word -match '^-(c|lc|cl)$')) { $flag = $i; break }
        }
        if ($flag -ge 0 -and ($flag + 1) -lt $e.Count) {
            try {
                if ($e.Count -eq ($flag + 2)) { $inner = Get-SafeDeleteLiteral $e[$flag + 1] }
                else { $inner = $Command.Substring($e[$flag + 1].Extent.StartOffset, $wrapper.Extent.EndOffset - $e[$flag + 1].Extent.StartOffset) }
                $plan = Get-SafeDeleteCommandPlan -Command $inner -WorkingDirectory $WorkingDirectory -ProjectRoot $ProjectRoot -Depth ($Depth + 1)
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
