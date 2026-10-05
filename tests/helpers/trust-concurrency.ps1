# Deterministic fixture-local faults around the real Codex app-server Trust call.
# Loaded by install-location.ps1; uses its New-SourceFixture/Write-Json helpers.
function Enable-TrustConcurrencyFault($Fixture,[string]$Point,[bool]$FailSelfCheck,[string]$SdkReloadFailure='') {
    if ($Point -notin @('none','before-sdk-write','after-sdk-write','before-trust-return','after-self-check')) {
        throw ('Unknown Trust concurrency fault point: ' + $Point)
    }
    if ($SdkReloadFailure -notin @('','failure','timeout')) { throw 'Unknown SDK reload failure mode.' }
    $evidence = Join-Path $Fixture.root 'trust-concurrency-evidence'
    $null = [IO.Directory]::CreateDirectory($evidence)
    $Fixture | Add-Member NoteProperty testEnvironment @{
        SAFEDELETE_TEST_FIXTURE_ROOT=$Fixture.root
        SAFEDELETE_TEST_CONFIG_PATH=$Fixture.configPath
        SAFEDELETE_TEST_FAULT_EVIDENCE=$evidence
        SAFEDELETE_TEST_CONFIG_FAULT_POINT=$Point
        SAFEDELETE_TEST_FAIL_SELF_CHECK=$(if ($FailSelfCheck) { '1' } else { '0' })
        SAFEDELETE_TEST_SDK_RELOAD_FAILURE=$SdkReloadFailure
    } -Force
    $Fixture | Add-Member NoteProperty trustConcurrencyEvidence $evidence -Force
}

function New-TrustConcurrencySourceFixture([string]$Name) {
    $source = New-SourceFixture $Name
    $trustWrapper = @'

# Test-only wrappers: the saved production functions still launch the real local
# app-server and perform the actual SDK RPC. All injected writes are fixture-local.
$script:SafeDeleteTestOriginalRpc = ${function:Invoke-SafeDeleteHookRpc}
$script:SafeDeleteTestOriginalRegistration = ${function:Get-SafeDeleteHookRegistration}
function Get-SafeDeleteTestFaultPath([string]$Name) {
    if (-not $env:SAFEDELETE_TEST_FAULT_EVIDENCE) { return $null }
    $root = [IO.Path]::GetFullPath($env:SAFEDELETE_TEST_FIXTURE_ROOT).TrimEnd('\')
    $evidence = [IO.Path]::GetFullPath($env:SAFEDELETE_TEST_FAULT_EVIDENCE).TrimEnd('\')
    if (-not $evidence.StartsWith($root + '\',[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Trust concurrency evidence escaped its fixture.'
    }
    return Join-Path $evidence $Name
}
function Invoke-SafeDeleteTestConfigFault([string]$Point) {
    if ($env:SAFEDELETE_TEST_CONFIG_FAULT_POINT -cne $Point) { return }
    $eventPath = Get-SafeDeleteTestFaultPath 'injection.json'
    if (-not $eventPath -or [IO.File]::Exists($eventPath)) { return }
    $root = [IO.Path]::GetFullPath($env:SAFEDELETE_TEST_FIXTURE_ROOT).TrimEnd('\')
    $config = [IO.Path]::GetFullPath($env:SAFEDELETE_TEST_CONFIG_PATH)
    if (-not $config.StartsWith($root + '\',[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Trust concurrency configuration write escaped its fixture.'
    }
    $before = [IO.File]::ReadAllBytes($config)
    $suffix = "`r`n# concurrent-config-should-survive`r`n[profiles.safedelete_concurrency_regression]`r`nmodel_reasoning_effort = 'high'`r`n"
    [IO.File]::AppendAllText($config,$suffix,(New-Object Text.UTF8Encoding($false)))
    $after = [IO.File]::ReadAllBytes($config)
    [IO.File]::WriteAllBytes((Get-SafeDeleteTestFaultPath 'config-before-injection.toml'),$before)
    [IO.File]::WriteAllBytes((Get-SafeDeleteTestFaultPath 'config-after-injection.toml'),$after)
    $event = [pscustomobject]@{
        point=$Point; configuration=$config; beforeBytes=$before.Length; afterBytes=$after.Length
        beforeSha256=(Get-SafeDeleteBytesHash $before); afterSha256=(Get-SafeDeleteBytesHash $after)
        appendedText=$suffix; actualLocalSdkCalled=$true; rpcMocked=$false
    }
    [IO.File]::WriteAllText($eventPath,($event | ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
}
function Invoke-SafeDeleteHookRpc {
    param($Server,[string]$Method,[hashtable]$Params)
    $isLiveHome = $false
    if ($env:SAFEDELETE_TEST_CONFIG_PATH) {
        $liveHome = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($env:SAFEDELETE_TEST_CONFIG_PATH))
        $serverHome = [string]$Server.Process.StartInfo.EnvironmentVariables['CODEX_HOME']
        $isLiveHome = [string]::Equals($serverHome,$liveHome,[StringComparison]::OrdinalIgnoreCase)
    }
    if ($isLiveHome -and $Method -ceq 'hooks/list' -and $script:SafeDeleteTestFailSdkReload) {
        $script:SafeDeleteTestFailSdkReload = $false
        $mode = $env:SAFEDELETE_TEST_SDK_RELOAD_FAILURE
        [IO.File]::WriteAllText((Get-SafeDeleteTestFaultPath 'sdk-reload-failed.json'),
            ([pscustomobject]@{mode=$mode;boundary='hooks/list after actual config/batchWrite';injected=$true} | ConvertTo-Json -Depth 3),
            (New-Object Text.UTF8Encoding($false)))
        if ($mode -ceq 'timeout') { throw 'Injected SDK reload timeout after actual configuration write.' }
        throw 'Injected SDK reload failure after actual configuration write.'
    }
    if ($isLiveHome -and $Method -ceq 'config/batchWrite') { Invoke-SafeDeleteTestConfigFault 'before-sdk-write' }
    $response = & $script:SafeDeleteTestOriginalRpc @PSBoundParameters
    if ($isLiveHome -and $Method -ceq 'config/batchWrite') {
        $bytes = [IO.File]::ReadAllBytes($env:SAFEDELETE_TEST_CONFIG_PATH)
        [IO.File]::WriteAllBytes((Get-SafeDeleteTestFaultPath 'config-after-sdk-write.toml'),$bytes)
        [IO.File]::WriteAllText((Get-SafeDeleteTestFaultPath 'sdk-write-succeeded.json'),
            ([pscustomobject]@{configSha256=(Get-SafeDeleteBytesHash $bytes);actualLocalSdkCalled=$true;rpcMocked=$false} | ConvertTo-Json -Depth 3),
            (New-Object Text.UTF8Encoding($false)))
        Invoke-SafeDeleteTestConfigFault 'after-sdk-write'
        if ($env:SAFEDELETE_TEST_SDK_RELOAD_FAILURE) { $script:SafeDeleteTestFailSdkReload=$true }
    }
    return $response
}
$script:SafeDeleteTestFailSdkReload = $false
function Get-SafeDeleteHookRegistration {
    param(
        [Parameter(Mandatory=$true)][string]$CodexHome,
        [Parameter(Mandatory=$true)][string]$WorkingDirectory,
        [Parameter(Mandatory=$true)][string]$HookPath,
        [Parameter(Mandatory=$true)][string]$ExpectedCommand,
        [switch]$Trust,
        [AllowNull()][AllowEmptyString()][string]$ExpectedConfigHash,
        [hashtable]$ConfigWriteReceipt
    )
    $registration = $null
    try {
        $registration = & $script:SafeDeleteTestOriginalRegistration @PSBoundParameters
        if ($Trust) {
            $path = Get-SafeDeleteTestFaultPath 'trust-succeeded.json'
            if ($path) {
                [IO.File]::WriteAllText($path,([pscustomobject]@{
                    trustStatus=$registration.TrustStatus; enabled=$registration.Enabled
                    configWriteHash=$registration.ConfigWriteHash
                    actualLocalSdkCalled=$true; rpcMocked=$false
                } | ConvertTo-Json -Depth 3),(New-Object Text.UTF8Encoding($false)))
            }
            Invoke-SafeDeleteTestConfigFault 'before-trust-return'
        }
        return $registration
    } finally {
        if ($Trust) {
            $path = Get-SafeDeleteTestFaultPath 'config-write-receipt.json'
            if ($path) {
                [IO.File]::WriteAllText($path,([pscustomobject]@{
                    expectedConfigHash=$ExpectedConfigHash; publishedHash=$(if ($ConfigWriteReceipt) { $ConfigWriteReceipt.Hash } else { $null })
                    trustReturned=($null -ne $registration); actualLocalSdkCalled=$true; rpcMocked=$false
                } | ConvertTo-Json -Depth 3),(New-Object Text.UTF8Encoding($false)))
            }
        }
    }
}
'@
    $selfCheckWrapper = @'

# Preserve and run the actual configured Hook before injecting any failure.
$script:SafeDeleteTestOriginalSelfCheck = ${function:Test-SafeDeleteHookCommand}
function Test-SafeDeleteHookCommand {
    param([string]$HookCommand,[string]$ProjectRoot,
        [ValidateSet('deny','bypass')][string]$ExpectedDecision='deny')
    & $script:SafeDeleteTestOriginalSelfCheck @PSBoundParameters
    if ($env:SAFEDELETE_TEST_FAULT_EVIDENCE) {
        $root = [IO.Path]::GetFullPath($env:SAFEDELETE_TEST_FIXTURE_ROOT).TrimEnd('\')
        $evidence = [IO.Path]::GetFullPath($env:SAFEDELETE_TEST_FAULT_EVIDENCE).TrimEnd('\')
        if (-not $evidence.StartsWith($root + '\',[StringComparison]::OrdinalIgnoreCase)) {
            throw 'Hook self-check evidence escaped its fixture.'
        }
        [IO.File]::WriteAllText((Join-Path $evidence 'self-check-succeeded.json'),
            ([pscustomobject]@{actualHookExecuted=$true;expectedDecision=$ExpectedDecision} | ConvertTo-Json -Depth 3),
            (New-Object Text.UTF8Encoding($false)))
        Invoke-SafeDeleteTestConfigFault 'after-self-check'
        if ($env:SAFEDELETE_TEST_FAIL_SELF_CHECK -ceq '1') {
            throw 'Injected post-trust self-check failure after actual Hook execution.'
        }
    }
}
'@
    [IO.File]::AppendAllText((Join-Path $source 'hooks\Trust.ps1'),$trustWrapper,$encoding)
    [IO.File]::AppendAllText((Join-Path $source 'src\InstallState.ps1'),$selfCheckWrapper,$encoding)
    return $source
}

function Get-TrustConcurrencyEvidence($Fixture) {
    $result = [ordered]@{ directory=$Fixture.trustConcurrencyEvidence; injection=$null; trustSucceeded=$null; selfCheckSucceeded=$null; sdkWriteSucceeded=$null; sdkReloadFailed=$null; configWriteReceipt=$null }
    foreach ($entry in @(
        @{name='injection';file='injection.json'},
        @{name='trustSucceeded';file='trust-succeeded.json'},
        @{name='selfCheckSucceeded';file='self-check-succeeded.json'},
        @{name='sdkWriteSucceeded';file='sdk-write-succeeded.json'},
        @{name='sdkReloadFailed';file='sdk-reload-failed.json'},
        @{name='configWriteReceipt';file='config-write-receipt.json'}
    )) {
        $path = Join-Path $Fixture.trustConcurrencyEvidence $entry.file
        if ([IO.File]::Exists($path)) { $result[$entry.name]=[IO.File]::ReadAllText($path) | ConvertFrom-Json }
    }
    return [pscustomobject]$result
}
