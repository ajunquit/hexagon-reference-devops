<#
.SYNOPSIS
    Uses DevOps-prepared Keycloak clients in a restricted local backend and the real built Angular UI.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string] $Backend, [Parameter(Mandatory)][string] $Frontend,
    [Parameter(Mandatory)][string] $Configuration, [string] $Tenant = 'demo')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:HEXAGON_AUTH_LOCAL_DATABASE_EPHEMERAL -cne 'true') { throw 'Use only a disposable local database and set HEXAGON_AUTH_LOCAL_DATABASE_EPHEMERAL=true.' }
Import-Module (Join-Path $PSScriptRoot '../scripts/KeycloakAuthorization.psm1') -Force
$model = Read-KeycloakAuthorization $Configuration
if ($model.environment -cne 'local') { throw 'Only local Keycloak configuration is accepted.' }
$backendPath = (Resolve-Path -LiteralPath $Backend).Path
$frontendPath = (Resolve-Path -LiteralPath $Frontend).Path
$hosting = Get-Content -LiteralPath (Join-Path $backendPath '.hexagon/backend-hosting-requirements.json') -Raw | ConvertFrom-Json -AsHashtable
if ($hosting.apiVersion -cne 'hexagon.ec/backend-hosting-requirements/v1' -or $hosting.product -cne $model.product -or
    $hosting.identity.audience -cne $model.resourceServer.clientId -or $hosting.identity.apiScope -cne $model.resourceServer.apiScope) { throw 'Local authorization does not match the backend contract.' }
$api = @($hosting.workloads | Where-Object { $_.kind -ceq 'api' -and $_.id -ceq $hosting.migrations.workload })
if ($api.Count -ne 1) { throw 'An unambiguous API workload is required.' }
$project = [IO.Path]::GetFullPath((Join-Path $backendPath $api[0].project))
if (-not $project.StartsWith($backendPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
    [IO.Path]::GetExtension($project) -cne '.csproj' -or $api[0].assembly -cnotmatch '^[A-Za-z0-9_.-]+\.dll$') { throw 'The API project and assembly must remain within the backend.' }
$projectDirectory = [IO.Path]::GetDirectoryName($project)
$binary = Join-Path $projectDirectory "bin/Release/net10.0/$($api[0].assembly)"
if (-not (Test-Path -LiteralPath $binary) -or -not (Test-Path -LiteralPath (Join-Path $frontendPath 'scripts/test-auth-browser.mjs'))) { throw 'Build the backend Release and frontend production bundle before acceptance.' }
$connection = $env:HEXAGON_AUTH_LOCAL_DATABASE_CONNECTION
$database = [System.Data.Common.DbConnectionStringBuilder]::new()
try { $database.set_ConnectionString($connection) } catch { throw 'The local database connection is invalid.' }
if (-not $database.ContainsKey('Host') -or ([string] $database['Host']) -cnotin @('localhost','127.0.0.1','::1') -or
    -not $database.ContainsKey('Username') -or ([string] $database['Username']) -cne 'hexagon_runtime' -or -not $database.ContainsKey('Password')) { throw 'Use the loopback database and its restricted hexagon_runtime login.' }
$context = New-KeycloakAuthorizationContext $model
$process = $null; $started = $false; $out = $null; $err = $null; $succeeded = $false
try {
    Invoke-KeycloakAuthorizationPreparation $context -Confirm:$false | Out-Null
    $bindings = Get-KeycloakAuthorizationBindings $model
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start(); $port = $listener.LocalEndpoint.Port; $listener.Stop()
    $start = [Diagnostics.ProcessStartInfo]::new((Get-Command dotnet -ErrorAction Stop).Source)
    $start.ArgumentList.Add($binary); $start.WorkingDirectory = $projectDirectory
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    # Runtime receives no GitHub, cloud, operator or bootstrap credentials from the parent shell.
    $start.Environment.Clear()
    foreach ($name in @('PATH','SystemRoot','WINDIR','TEMP','TMP','USERPROFILE','HOME','LOCALAPPDATA','APPDATA','PROGRAMFILES','DOTNET_ROOT')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value) { $start.Environment[$name] = $value }
    }
    foreach ($key in $bindings.environment.Keys) { $start.Environment[$key] = $bindings.environment[$key] }
    $start.Environment['Auth__Authorization__ClientSecret'] = $env:HEXAGON_AUTHORIZATION_CLIENT_SECRET
    $start.Environment["ConnectionStrings__$($hosting.database.connectionName)"] = $connection
    $start.Environment['DOTNET_ENVIRONMENT'] = 'Production'; $start.Environment['ASPNETCORE_ENVIRONMENT'] = 'Production'
    $start.Environment['ASPNETCORE_URLS'] = "http://127.0.0.1:$port"; $start.Environment['Logging__LogLevel__Default'] = 'Warning'
    $messagingFile = Join-Path $backendPath '.hexagon/local-messaging-bindings.json'
    if (Test-Path -LiteralPath (Join-Path $backendPath '.hexagon/messaging-requirements.json')) {
        $text = [IO.File]::ReadAllText($messagingFile)
        if (-not ($text | Test-Json -SchemaFile (Join-Path $PSScriptRoot '../contracts/schemas/local-messaging-bindings-v1.schema.json') -ErrorAction SilentlyContinue)) { throw 'Start the product local messaging from DevOps before acceptance.' }
        $messaging = $text | ConvertFrom-Json -AsHashtable
        if ($messaging.product -cne $model.product -or -not $messaging.workloads.ContainsKey($api[0].id)) { throw 'Local messaging belongs to a different product.' }
        foreach ($key in $messaging.workloads[$api[0].id].Keys) {
            $value = [string] $messaging.workloads[$api[0].id][$key]
            if ($key -ceq 'ConnectionStrings__servicebus') {
                $bus = [System.Data.Common.DbConnectionStringBuilder]::new(); $bus.set_ConnectionString($value)
                if (-not $bus.ContainsKey('Endpoint') -or ([Uri] $bus['Endpoint']).Host -cnotin @('localhost','127.0.0.1','::1') -or
                    -not $bus.ContainsKey('UseDevelopmentEmulator') -or [string] $bus['UseDevelopmentEmulator'] -ine 'true') { throw 'Acceptance messaging must use the local emulator.' }
            } elseif ($key -match '__(ServiceUrl|QueueUrl|ConnectionString)$') {
                $endpoint = $null
                if (-not [Uri]::TryCreate($value, [UriKind]::Absolute, [ref] $endpoint) -or -not $endpoint.IsLoopback) { throw 'Acceptance messaging endpoints must remain on loopback.' }
            }
            $start.Environment[$key] = $value
        }
    }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $start
    $started = $process.Start(); $out = $process.StandardOutput.ReadToEndAsync(); $err = $process.StandardError.ReadToEndAsync()
    $ready = $false
    foreach ($attempt in 1..60) {
        if ($process.HasExited) { break }
        try {
            $response = Invoke-WebRequest "http://127.0.0.1:$port/api/v1/$Tenant/auth/me" -SkipHttpErrorCheck -TimeoutSec 2
            if ($response.StatusCode -eq 401) { $ready = $true; break }
        } catch { }
        Start-Sleep -Milliseconds 500
    }
    if (-not $ready) { throw 'The restricted local backend did not become ready.' }
    $previous = @{}
    foreach ($key in @('AUTH_BROWSER_EPHEMERAL','AUTH_BROWSER_BINDINGS','AUTH_BROWSER_API','AUTH_BROWSER_TENANT','HEXAGON_PLAYWRIGHT_MODULE')) { $previous[$key] = [Environment]::GetEnvironmentVariable($key) }
    try {
        $env:AUTH_BROWSER_EPHEMERAL = 'true'; $env:AUTH_BROWSER_BINDINGS = (Resolve-Path -LiteralPath $Configuration).Path
        $env:AUTH_BROWSER_API = "http://127.0.0.1:$port"; $env:AUTH_BROWSER_TENANT = $Tenant
        $env:HEXAGON_PLAYWRIGHT_MODULE = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../acceptance/node_modules/playwright/index.mjs')).Path
        & node (Join-Path $frontendPath 'scripts/test-auth-browser.mjs')
        if ($LASTEXITCODE -ne 0) { throw 'Local Auth browser acceptance failed.' }
    } finally { foreach ($key in $previous.Keys) { [Environment]::SetEnvironmentVariable($key, $previous[$key]) } }
    # Runtime edits must survive the same operator preparation after administration.
    Invoke-KeycloakAuthorizationPreparation $context -Confirm:$false | Out-Null
    $succeeded = $true
    Write-Host 'Local Auth integration passed with the DevOps-prepared client and a restricted Production backend.'
} finally {
    try {
    if ($started) {
        if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
        $log = $out.GetAwaiter().GetResult() + $err.GetAwaiter().GetResult()
        $sensitive = @($connection, [string] $database['Password'], $env:HEXAGON_AUTHORIZATION_CLIENT_SECRET, $env:HEXAGON_KEYCLOAK_BOOTSTRAP_TOKEN)
        foreach ($value in $sensitive) { if ($value -and $log.Contains($value, [StringComparison]::Ordinal)) { $log = ''; throw 'A credential appeared in runtime output; the output was discarded.' } }
        if (-not $succeeded) {
            $directory = Join-Path $PSScriptRoot "../artifacts/auth-local-$([Guid]::NewGuid().ToString('N'))"
            $null = [IO.Directory]::CreateDirectory($directory)
            [IO.File]::WriteAllText((Join-Path $directory 'backend.log'), $log)
            Write-Host "Sanitized local backend output: $([IO.Path]::GetFullPath($directory))/backend.log"
        }
    }
    } finally {
    if ($null -ne $process) { $process.Dispose() }
    $context.client.Dispose(); $context.handler.Dispose(); $context.token = $null
    }
}
