Set-StrictMode -Version Latest

# Tools that every repository may run. A cloud adds its own tools (and the ambient variables that
# must not reach them) in a module named *LifecycleTools.psm1 next to this one.
$script:genericTools = @('git', 'terraform', 'pwsh', 'acceptance-browser')
$script:toolModules = $null

function Get-LifecycleToolModules {
    if ($null -eq $script:toolModules) {
        $script:toolModules = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*LifecycleTools.psm1' -File | Sort-Object Name |
            ForEach-Object { Import-Module $_.FullName -PassThru -DisableNameChecking })
    }
    return $script:toolModules
}

function Get-LifecycleToolModule([string] $Tool) {
    $module = @(Get-LifecycleToolModules | Where-Object { $Tool -cin (& $_ { Get-LifecycleToolNames }) })
    if ($module.Count -ne 1) { throw 'lifecycle.toolUnavailable' }
    return $module[0]
}

function Invoke-LifecycleCommand {
    param([ValidatePattern('^[a-z][a-z-]*$')][string] $Tool, [string[]] $Arguments,
        [string] $Directory, [hashtable] $Environment = @{}, [int] $TimeoutSeconds = 1200, [scriptblock] $Heartbeat)
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    if ($Tool -cne 'acceptance-browser') {
        $info.Environment.Remove('HEXAGON_E2E_USERNAME') | Out-Null
        $info.Environment.Remove('HEXAGON_E2E_PASSWORD') | Out-Null
    }
    if ($Directory) { $info.WorkingDirectory = $Directory }
    if ($Tool -ceq 'acceptance-browser') {
        if ($Arguments.Count -ne 1 -or -not [IO.Path]::IsPathFullyQualified($Arguments[0]) -or -not (Test-Path -LiteralPath $Arguments[0] -PathType Leaf)) { throw 'lifecycle.acceptance.argumentsInvalid' }
        $info.FileName = (Get-Command node -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        $info.ArgumentList.Add((Join-Path $PSScriptRoot '../acceptance/run.mjs')); $info.ArgumentList.Add($Arguments[0])
        foreach ($key in @($info.Environment.Keys)) {
            if ($key -cnotin @('PATH', 'Path', 'SystemRoot', 'WINDIR', 'TEMP', 'TMP', 'TMPDIR', 'HOME', 'USERPROFILE', 'LANG', 'LC_ALL')) { $info.Environment.Remove($key) | Out-Null }
        }
        foreach ($key in $Environment.Keys) { if ($key -cnotin @('HEXAGON_E2E_USERNAME', 'HEXAGON_E2E_PASSWORD')) { throw 'lifecycle.acceptance.environmentForbidden' } }
    }
    elseif ($Tool -cnotin $script:genericTools) {
        # A cloud tool: launched only through the module of its cloud.
        & (Get-LifecycleToolModule $Tool) { param($t, $i, $a, $e) Set-LifecycleToolStart $t $i $a $e } $Tool $info $Arguments $Environment
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
        # errorText lets callers classify a failure (for example a failed storage precondition); it is never logged.
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
    $modules = @(Get-LifecycleToolModules)
    if (@(Get-ChildItem Env: | Where-Object {
        $variable = $_
        $variable.Name -like 'TF_CLI_ARGS*' -or $variable.Name -in @('TF_DATA_DIR', 'TF_CLI_CONFIG_FILE') -or
        ($variable.Name -eq 'TF_WORKSPACE' -and $variable.Value -cne 'default') -or
        @($modules | Where-Object { & $_ { param($n) Test-LifecycleAmbientVariable $n } $variable.Name }).Count -gt 0 }).Count -gt 0) { throw 'lifecycle.ambientConfiguration' }
}

Export-ModuleMember -Function Invoke-LifecycleCommand, Assert-LifecycleCliEnvironment
