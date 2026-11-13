Set-StrictMode -Version Latest

function Invoke-LifecycleCommand {
    param([ValidateSet('git', 'terraform', 'az', 'aws', 'pwsh', 'static-web-client', 'acceptance-browser')][string] $Tool, [string[]] $Arguments,
        [string] $Directory, [hashtable] $Environment = @{}, [int] $TimeoutSeconds = 1200, [scriptblock] $Heartbeat)
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    if ($Tool -cne 'acceptance-browser') {
        $info.Environment.Remove('HEXAGON_E2E_USERNAME') | Out-Null
        $info.Environment.Remove('HEXAGON_E2E_PASSWORD') | Out-Null
    }
    if ($Directory) { $info.WorkingDirectory = $Directory }
    if ($Tool -ceq 'static-web-client') {
        if ($null -ne $Arguments -and $Arguments.Count -gt 0) { throw 'lifecycle.web.clientArgumentsForbidden' }
        Import-Module (Join-Path $PSScriptRoot 'StaticWebClient.psm1')
        $info.FileName = Get-StaticWebClientPath
        foreach ($key in @($info.Environment.Keys)) {
            if ($key -cnotin @('PATH', 'Path', 'SystemRoot', 'WINDIR', 'TEMP', 'TMP', 'TMPDIR', 'HOME', 'USERPROFILE', 'LANG', 'LC_ALL', 'LD_LIBRARY_PATH', 'SSL_CERT_FILE', 'SSL_CERT_DIR')) { $info.Environment.Remove($key) | Out-Null }
        }
        foreach ($key in $Environment.Keys) {
            if ($key -cnotin @('DEPLOYMENT_ACTION', 'DEPLOYMENT_PROVIDER', 'REPOSITORY_BASE', 'SKIP_APP_BUILD', 'SKIP_API_BUILD', 'DEPLOYMENT_TOKEN', 'APP_LOCATION', 'API_LOCATION', 'DATA_API_LOCATION', 'CONFIG_FILE_LOCATION', 'VERBOSE')) { throw 'lifecycle.web.clientEnvironmentForbidden' }
        }
    }
    elseif ($Tool -ceq 'acceptance-browser') {
        if ($Arguments.Count -ne 1 -or -not [IO.Path]::IsPathFullyQualified($Arguments[0]) -or -not (Test-Path -LiteralPath $Arguments[0] -PathType Leaf)) { throw 'lifecycle.acceptance.argumentsInvalid' }
        $info.FileName = (Get-Command node -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        $info.ArgumentList.Add((Join-Path $PSScriptRoot '../acceptance/run.mjs')); $info.ArgumentList.Add($Arguments[0])
        foreach ($key in @($info.Environment.Keys)) {
            if ($key -cnotin @('PATH', 'Path', 'SystemRoot', 'WINDIR', 'TEMP', 'TMP', 'TMPDIR', 'HOME', 'USERPROFILE', 'LANG', 'LC_ALL')) { $info.Environment.Remove($key) | Out-Null }
        }
        foreach ($key in $Environment.Keys) { if ($key -cnotin @('HEXAGON_E2E_USERNAME', 'HEXAGON_E2E_PASSWORD')) { throw 'lifecycle.acceptance.environmentForbidden' } }
    }
    elseif ($Tool -ceq 'az') {
        $info.FileName = (Get-Process -Id $PID).Path
        $code = '$ErrorActionPreference="Stop"; $PSNativeCommandUseErrorActionPreference=$false; $nativeArgs=ConvertFrom-Json $env:HEXAGON_LIFECYCLE_NATIVE_ARGS; & az @nativeArgs; exit $LASTEXITCODE'
        foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code)))) { $info.ArgumentList.Add($argument) }
        $info.Environment['HEXAGON_LIFECYCLE_NATIVE_ARGS'] = ConvertTo-Json -InputObject @($Arguments) -Compress
    }
    else {
        $info.FileName = (Get-Command $Tool -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    }
    foreach ($key in $Environment.Keys) { $info.Environment[$key] = [string] $Environment[$key] }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $info
    $stdout = [IO.MemoryStream]::new(); $stderr = [IO.MemoryStream]::new()
    try {
        [void] $process.Start()
        $outTask = $process.StandardOutput.BaseStream.CopyToAsync($stdout)
        $errTask = $process.StandardError.BaseStream.CopyToAsync($stderr)
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $lastBeat = 0.0
        while (-not $process.WaitForExit(250)) {
            if ($timer.Elapsed.TotalSeconds -gt $TimeoutSeconds) { $process.Kill($true); $process.WaitForExit(); throw 'lifecycle.nativeTimeout' }
            if ($null -ne $Heartbeat -and $timer.Elapsed.TotalSeconds - $lastBeat -ge 10) { & $Heartbeat | Out-Null; $lastBeat = $timer.Elapsed.TotalSeconds }
        }
        $null = $outTask.GetAwaiter().GetResult(); $null = $errTask.GetAwaiter().GetResult()
        if ($stdout.Length -gt 33554432 -or $stderr.Length -gt 33554432) { throw 'lifecycle.nativeOutputTooLarge' }
        # errorText lets callers classify a failure (for example a failed S3 precondition); it is never logged.
        return @{ exitCode = $process.ExitCode; bytes = $stdout.ToArray(); text = [Text.Encoding]::UTF8.GetString($stdout.ToArray()); errorText = [Text.Encoding]::UTF8.GetString($stderr.ToArray()) }
    }
    catch {
        if ($_.Exception.Message -cmatch '^lifecycle[.][A-Za-z0-9.]+$') { throw }
        throw "lifecycle.native.$Tool"
    }
    finally {
        try { if ($process.Id -and -not $process.HasExited) { $process.Kill($true); $process.WaitForExit() } } catch { }
        $process.Dispose(); $stdout.Dispose(); $stderr.Dispose()
    }
}

function Assert-LifecycleCliEnvironment {
    if (@(Get-ChildItem Env: | Where-Object { $_.Name -like 'TF_CLI_ARGS*' -or $_.Name -in @('TF_DATA_DIR', 'TF_CLI_CONFIG_FILE') -or
        ($_.Name -like 'ARM_*' -and $_.Name -notin @('ARM_SUBSCRIPTION_ID', 'ARM_TENANT_ID')) -or $_.Name -like 'AWS_ENDPOINT_URL*' -or
        ($_.Name -eq 'TF_WORKSPACE' -and $_.Value -cne 'default') }).Count -gt 0) { throw 'lifecycle.ambientConfiguration' }
}

Export-ModuleMember -Function Invoke-LifecycleCommand, Assert-LifecycleCliEnvironment
