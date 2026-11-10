<#
.SYNOPSIS
    Tests immutable SPA publication, public HTTP evidence, Azure health and deployment-token isolation.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
foreach ($name in @('StaticWebPublication', 'AzureWebDelivery', 'AzureEnvironmentStore', 'EnvironmentLifecycle', 'EnvironmentSnapshot', 'PlatformBootstrap', 'StaticWebClient')) { Import-Module (Join-Path $repository "scripts/$name.psm1") }
if (-not ('Hexagon.DeliveryTests.DeliveryHttpHandler' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'DeliveryHttpHandler.cs') }
if (-not ('Hexagon.LifecycleTests.LifecycleHttpHandler' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'LifecycleHttpHandler.cs') }
$parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
$temporary = Join-Path $parent "hexagon-web-publication-tests-$([guid]::NewGuid().ToString('N'))"; [IO.Directory]::CreateDirectory($temporary) | Out-Null
$script:assertions = 0
function Assert-True([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message }; $script:assertions++ }
function Assert-Rejected([scriptblock] $Action, [string] $Code) {
    try { & $Action | Out-Null } catch { Assert-True ($_.Exception.Message -like "*$Code*") "Unexpected rejection: $($_.Exception.Message) $($_.ScriptStackTrace)"; return }
    throw "Expected rejection: $Code"
}
function Bytes([string] $Value) { return ,[Text.Encoding]::UTF8.GetBytes($Value) }
function Copy-Value([object] $Value) { return (ConvertTo-PlatformBootstrapJson $Value) | ConvertFrom-Json -AsHashtable -Depth 60 }
function Write-Bundle([string] $Path, [hashtable] $Files) {
    $file = [IO.File]::Create($Path); $gzip = [IO.Compression.GZipStream]::new($file, [IO.Compression.CompressionLevel]::Fastest); $tar = [System.Formats.Tar.TarWriter]::new($gzip)
    try {
        foreach ($name in $Files.Keys) {
            $entry = [System.Formats.Tar.PaxTarEntry]::new([System.Formats.Tar.TarEntryType]::RegularFile, $name); $entry.DataStream = [IO.MemoryStream]::new([byte[]] $Files[$name])
            try { $tar.WriteEntry($entry) } finally { $entry.DataStream.Dispose() }
        }
    } finally { $tar.Dispose(); $gzip.Dispose(); $file.Dispose() }
}
function Set-Arm([string] $Id, [object] $Value, [string] $Version = '2024-03-01', [int] $Status = 200) { $armHandler.Route('GET', "https://management.azure.com${Id}?api-version=$Version", $Status, (ConvertTo-PlatformBootstrapJson $Value)) }
$webModule = Get-Module StaticWebPublication; $azureModule = Get-Module AzureWebDelivery; $storeModule = Get-Module AzureEnvironmentStore
try {
    $manifest = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'fixtures/hosting/frontend.json') | ConvertFrom-Json
    $outputs = @{ api_url = @{ value = 'https://fixture.region.azurecontainerapps.io/api/v1' }; frontend_authentication = @{ value = @{ authority = 'https://auth.example.test/realms/fixture'; clientId = 'fixture-web'; scope = 'openid profile email fixture.access' } }
        sensitive = @{ value = 'must-never-be-public' } }
    $archive = Join-Path $temporary 'web.tar.gz'
    Write-Bundle $archive @{ 'index.html' = Bytes '<html>production SPA</html>'; 'main-HASH.js' = Bytes 'production-code'; 'assets/fixture.json' = Bytes '{"public":true}' }
    $originalHash = Get-LifecycleFileHash $archive
    $payload = New-StaticWebPayload $archive $originalHash $manifest $outputs ('a' * 64) ('b' * 64) (Join-Path $temporary 'payload') -Confirm:$false
    $second = New-StaticWebPayload $archive $originalHash $manifest $outputs ('a' * 64) ('b' * 64) (Join-Path $temporary 'payload-second') -Confirm:$false
    Assert-True ($payload.deploymentSha256 -ceq $second.deploymentSha256 -and $payload.files.Count -eq 6) 'Payload identity changed on retry or original assets were lost.'
    Assert-True ((Get-LifecycleFileHash $archive) -ceq $originalHash) 'Public configuration changed the original CI archive.'
    $runtime = Get-Content -Raw -LiteralPath (Join-Path $payload.directory 'runtime-config.json')
    Assert-True (-not $runtime.Contains('must-never-be-public') -and ($runtime | ConvertFrom-Json).apiUrl -ceq $outputs.api_url.value) 'An unrelated Terraform output entered public configuration.'
    Assert-Rejected { New-StaticWebPayload $archive ('0' * 64) $manifest $outputs ('a' * 64) ('b' * 64) (Join-Path $temporary 'wrong-hash') -Confirm:$false } 'bundleChanged'
    $badArchive = Join-Path $temporary 'reserved.tar.gz'; Write-Bundle $badArchive @{ 'index.html' = Bytes 'index'; 'hexagon-deployment.json' = Bytes '{}' }
    Assert-Rejected { New-StaticWebPayload $badArchive (Get-LifecycleFileHash $badArchive) $manifest $outputs ('a' * 64) ('b' * 64) (Join-Path $temporary 'reserved') -Confirm:$false } 'reservedOrDuplicateFile'
    [IO.File]::AppendAllText((Join-Path $second.directory 'main-HASH.js'), 'changed')
    Assert-Rejected { Assert-StaticWebPayload $second } 'payloadChanged'
    $whatIfDirectory = Join-Path $temporary 'what-if'
    New-StaticWebPayload $archive $originalHash $manifest $outputs ('a' * 64) ('b' * 64) $whatIfDirectory -WhatIf | Out-Null
    Assert-True (-not (Test-Path -LiteralPath $whatIfDirectory)) 'SPA WhatIf created files.'

    $http = [Hexagon.DeliveryTests.DeliveryHttpHandler]::new()
    & $webModule { param($handler) $script:webHttp = $handler; function script:New-PublicWebHttpClient { return [Net.Http.HttpClient]::new($script:webHttp, $false) } } $http
    $origin = 'https://fixture.azurestaticapps.net'
    foreach ($name in $payload.files.Keys) {
        $http.Route('GET', "$origin/$name", 200, [IO.File]::ReadAllBytes((Join-Path $payload.directory $name)))
        $http.Header('GET', "$origin/$name", 'Cache-Control', $(if ($name -cin @('runtime-config.json', 'index.html')) { 'no-store' } else { 'no-cache' }))
        $http.Header('GET', "$origin/$name", 'Content-Type', $(if ($name.EndsWith('.json')) { 'application/json; charset=utf-8' } elseif ($name.EndsWith('.js')) { 'application/javascript' } else { 'text/html' }))
        $http.Header('GET', "$origin/$name", 'X-Content-Type-Options', 'nosniff'); $http.Header('GET', "$origin/$name", 'Referrer-Policy', 'no-referrer')
    }
    $fallback = "$origin/__hexagon_probe__/route/$($payload.deploymentSha256.Substring(0, 16))"
    foreach ($url in @("$origin/", $fallback)) {
        $http.Route('GET', $url, 200, [IO.File]::ReadAllBytes((Join-Path $payload.directory 'index.html'))); $http.Header('GET', $url, 'Cache-Control', 'no-cache'); $http.Header('GET', $url, 'Content-Type', 'text/html')
        $http.Header('GET', $url, 'X-Content-Type-Options', 'nosniff'); $http.Header('GET', $url, 'Referrer-Policy', 'no-referrer')
    }
    $probe = @{ beats = 0 }; $heartbeat = { $probe.beats++ }
    $verified = Test-StaticWebServing $payload $origin $heartbeat
    Assert-True ($verified.filesVerified -eq 5 -and $verified.fallbackVerified -and $probe.beats -gt 6) 'Serving verification omitted public files, fallback or lease heartbeats.'
    Assert-True (@($http.Requests | Where-Object { $_ -like '*staticwebapp.config.json' }).Count -eq 0) 'Serving verification assumes the host control file is a public asset.'
    Assert-True (@($http.Requests | Where-Object { $_ -ceq "GET $origin/hexagon-deployment.json" }).Count -eq 2) 'Deployment marker was not observed before and after file verification.'
    Assert-True (@($http.Headers | Where-Object { $_.ContainsKey('Authorization') -or $_.ContainsKey('Cookie') }).Count -eq 0) 'Public probes carried credentials.'
    $http.Route('GET', "$origin/main-HASH.js", 200, (Bytes 'old-code'))
    Assert-Rejected { Test-StaticWebServing $payload $origin $heartbeat } 'servedContentMismatch'
    $http.Route('GET', "$origin/main-HASH.js", 200, [IO.File]::ReadAllBytes((Join-Path $payload.directory 'main-HASH.js')))
    $http.Header('GET', "$origin/runtime-config.json", 'Cache-Control', 'public, max-age=3600')
    Assert-Rejected { Test-StaticWebServing $payload $origin $heartbeat } 'cachePolicyInvalid'
    $http.Header('GET', "$origin/runtime-config.json", 'Cache-Control', 'no-store')
    $http.Header('GET', "$origin/main-HASH.js", 'Content-Type', 'application/octet-stream')
    Assert-Rejected { Test-StaticWebServing $payload $origin $heartbeat } 'publicContentTypeInvalid'
    $http.Header('GET', "$origin/main-HASH.js", 'Content-Type', 'application/javascript')
    $http.Header('GET', "$origin/index.html", 'X-Content-Type-Options', 'invalid')
    Assert-Rejected { Test-StaticWebServing $payload $origin $heartbeat } 'securityHeadersInvalid'
    $http.Header('GET', "$origin/index.html", 'X-Content-Type-Options', 'nosniff')
    $http.Route('GET', $fallback, 404, (Bytes 'missing'))
    Assert-Rejected { Test-StaticWebServing $payload $origin $heartbeat } 'publicResponseUnsuccessful'
    $http.Route('GET', $fallback, 200, (Bytes 'wrong fallback'))
    Assert-Rejected { Test-StaticWebServing $payload $origin $heartbeat } 'spaFallbackInvalid'
    $http.Route('GET', "$origin/hexagon-deployment.json", 302, (Bytes ''))
    $http.Header('GET', "$origin/hexagon-deployment.json", 'Location', 'https://foreign.example.test')
    Assert-Rejected { Test-StaticWebServing $payload $origin $heartbeat } 'publicResponseUnsuccessful'
    Assert-Rejected { Test-StaticWebServing $payload 'https://foreign.example.test' $heartbeat } 'publicEndpointInvalid'

    # Real ARM/Blob protocol adapters run against HTTP fixtures; no Azure account is used.
    $inventory = Get-Content -Raw -LiteralPath (Join-Path $repository 'examples/environment-inventory.json') | ConvertFrom-Json -AsHashtable
    $context = @{ inventory = $inventory; prefix = "$($inventory.product)/dev/$($inventory.instance.id)"; runtime = $temporary; tokens = @{}; leaseId = $null }
    $armHandler = [Hexagon.LifecycleTests.LifecycleHttpHandler]::new()
    & $storeModule { param($handler) $script:staticWebArm = $handler; function script:New-AzureLifecycleHttpClient { return [Net.Http.HttpClient]::new($script:staticWebArm, $false) }; function script:Get-LifecycleAzureToken { return 'fixture-token' } } $armHandler
    Enter-AzureLifecycleLease $context -Confirm:$false
    $scope = "/subscriptions/$($inventory.target.subscriptionId)/resourceGroups/$($inventory.roots[0].resourceGroup)"
    $webId = "$scope/providers/Microsoft.Web/staticSites/fixture-web"
    $nativeOutputs = @{ web = @{ id = $webId; url = $origin }; api_url = $outputs.api_url.value; workload_identities = @{}
        database_bootstrap = @{ host = 'fixture.postgres.database.azure.com'; database = 'fixture' } }
    $inputs = @{ database_connection_name = 'database'; auth = @{ authority = $outputs.frontend_authentication.value.authority; audience = 'fixture-api'; api_scope = 'fixture.access' }; workloads = @{} }
    $hosting = @{ inputs = $inputs; state = @{ scopeId = $scope; outputs = $nativeOutputs; resources = @(@{ id = $webId; type = 'azurerm_static_web_app' }) } }
    $apps = @{}; $revisions = @{}; $replicas = @{}
    foreach ($kind in @('api', 'consumer')) {
        $id = "fixture-$kind"; $appId = "$scope/providers/Microsoft.App/containerApps/$id"; $revisionId = "$appId/revisions/$id--abc"
        $identity = @{ id = "$scope/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$id"; client_id = '33333333-3333-3333-3333-333333333333'; database_role = $id }
        $nativeOutputs.workload_identities[$id] = $identity
        $workload = @{ name = $id; kind = $kind; image = "fixture.azurecr.io/$id@sha256:$('d' * 64)"; http_ports = $(if ($kind -ceq 'api') { @(8080, 8081) } else { @(8081) }); min_replicas = 1; environment = @{}; secret_references = @{} }
        $environment = @{ ASPNETCORE_ENVIRONMENT = 'Production'; HTTP_PORTS = $workload.http_ports -join ';'; AZURE_CLIENT_ID = $identity.client_id
            ConnectionStrings__database = "Host=fixture.postgres.database.azure.com;Database=fixture;Username=$id;SSL Mode=VerifyFull" }
        if ($kind -ceq 'api') { $environment.Auth__Authority = $inputs.auth.authority; $environment.Auth__Audience = $inputs.auth.audience; $environment.Auth__ApiScope = $inputs.auth.api_scope; $environment.AllowedOrigins = $origin }
        $container = @{ name = 'application'; image = $workload.image; env = @($environment.GetEnumerator() | ForEach-Object { @{ name = $_.Key; value = $_.Value } })
            probes = @(@{ type = 'Startup'; httpGet = @{ port = 8081; path = '/health/ready' } }, @{ type = 'Readiness'; httpGet = @{ port = 8081; path = '/health/ready' } }, @{ type = 'Liveness'; httpGet = @{ port = 8081; path = '/health/alive' } }) }
        $configuration = @{ activeRevisionsMode = 'Single' }
        if ($kind -ceq 'api') { $configuration.ingress = @{ external = $true; allowInsecure = $false; targetPort = 8080; fqdn = 'fixture.region.azurecontainerapps.io'; traffic = @(@{ weight = 100; latestRevision = $true }) } }
        $apps[$id] = @{ id = $appId; identity = @{ type = 'UserAssigned'; userAssignedIdentities = @{ $identity.id = @{} } }; properties = @{ provisioningState = 'Succeeded'; latestRevisionName = "$id--abc"; latestReadyRevisionName = "$id--abc"; configuration = $configuration; template = @{ containers = @($container) } } }
        $revisions[$id] = @{ id = $revisionId; properties = @{ active = $true; healthState = 'Healthy'; provisioningState = 'Provisioned'; runningState = 'Running'; template = @{ containers = @($container) } } }
        $replicas[$id] = @{ value = @(@{ properties = @{ runningState = 'Running'; containers = @(@{ name = 'application'; ready = $true; started = $true; runningState = 'Running' }) } }) }
        Set-Arm $appId $apps[$id]; Set-Arm $revisionId $revisions[$id]; Set-Arm "$revisionId/replicas" $replicas[$id]
        $inputs.workloads[$id] = $workload; $hosting.state.resources += @{ id = $appId; type = 'azurerm_container_app' }
    }
    $facts = Get-AzureBackendHealth $context $hosting
    Assert-True ($facts.Count -eq 2 -and $facts[0].readyReplicas -eq 1 -and -not (ConvertTo-PlatformBootstrapJson $facts).Contains('ConnectionStrings')) 'Backend evidence lost a workload or exposed bindings.'
    $apps['fixture-api'].properties.template.initContainers = $null
    $apps['fixture-api'].properties.template.containers[0].command = $null; $apps['fixture-api'].properties.template.containers[0].args = $null
    Set-Arm $apps['fixture-api'].id $apps['fixture-api']
    Assert-True ((Get-AzureBackendHealth $context $hosting).Count -eq 2) 'Nullable ARM defaults were treated as executable overrides.'
    $revisions['fixture-api'].properties.healthState = 'Unhealthy'; Set-Arm $revisions['fixture-api'].id $revisions['fixture-api']
    Assert-Rejected { Get-AzureBackendHealth $context $hosting } 'revisionNotHealthy'
    $revisions['fixture-api'].properties.healthState = 'Healthy'; Set-Arm $revisions['fixture-api'].id $revisions['fixture-api']
    $replicas['fixture-consumer'].value[0].properties.containers[0].ready = $false; Set-Arm "$($revisions['fixture-consumer'].id)/replicas" $replicas['fixture-consumer']
    Assert-Rejected { Get-AzureBackendHealth $context $hosting } 'replicasNotReady'
    $replicas['fixture-consumer'].value[0].properties.containers[0].ready = $true; Set-Arm "$($revisions['fixture-consumer'].id)/replicas" $replicas['fixture-consumer']
    $apps['fixture-consumer'].properties.configuration.ingress = @{ external = $true }; Set-Arm $apps['fixture-consumer'].id $apps['fixture-consumer']
    Assert-Rejected { Get-AzureBackendHealth $context $hosting } 'workerIngressExposed'
    $apps['fixture-consumer'].properties.configuration.Remove('ingress'); Set-Arm $apps['fixture-consumer'].id $apps['fixture-consumer']
    $apps['fixture-api'].properties.template.containers[0].probes[1].httpGet.port = 8080; Set-Arm $apps['fixture-api'].id $apps['fixture-api']
    Assert-Rejected { Get-AzureBackendHealth $context $hosting } 'healthProbeChanged'
    $apps['fixture-api'].properties.template.containers[0].probes[1].httpGet.port = 8081; Set-Arm $apps['fixture-api'].id $apps['fixture-api']
    $apps['fixture-api'].properties.template.containers[0].image = 'wrong'; Set-Arm $apps['fixture-api'].id $apps['fixture-api']
    Assert-Rejected { Get-AzureBackendHealth $context $hosting } 'workloadImageChanged'
    $apps['fixture-api'].properties.template.containers[0].image = $inputs.workloads['fixture-api'].image; Set-Arm $apps['fixture-api'].id $apps['fixture-api']
    Set-Arm $webId @{ id = $webId; properties = @{ defaultHostname = 'fixture.azurestaticapps.net' } } '2023-12-01'
    $target = Get-AzureWebTarget $context $hosting
    Assert-True ($target.origin -ceq $origin) 'Web target was not tied to its recorded ARM resource.'
    Set-Arm $webId @{ id = $webId; properties = @{ defaultHostname = 'other.azurestaticapps.net' } } '2023-12-01'
    Assert-Rejected { Get-AzureWebTarget $context $hosting } 'siteEndpointChanged'
    $context.inventory.roots[0].resources = @(@{ id = $webId; type = 'azurerm_static_web_app'; current = $true; presence = 'Present' })

    $native = @{ calls = @(); acknowledged = $false }
    & $azureModule { param($fixture) $script:publicationNative = $fixture; function script:Get-StaticWebClientPath { return 'fixture-client' }
        function script:Invoke-LifecycleCommand {
            param($Tool, $Arguments, $Directory, $Environment, $TimeoutSeconds, $Heartbeat)
            $script:publicationNative.calls += @{ tool = $Tool; arguments = $Arguments; directory = $Directory; environment = $Environment }
            if ($Tool -ceq 'az') { return @{ exitCode = 0; text = '{"properties":{"apiKey":"fixture-deployment-token"}}' } }
            if ($Tool -cne 'static-web-client') { throw 'Unexpected executable.' }
            & $Heartbeat | Out-Null
            return @{ exitCode = $(if ($script:publicationNative.acknowledged) { 0 } else { 1 }); text = 'must-not-be-persisted' }
        }
    } $native
    Assert-Rejected { Publish-AzureWebPayload $context @{ id = "$scope/providers/Microsoft.Web/staticSites/unrecorded"; origin = $origin } $payload -Confirm:$false } 'siteUnrecorded'
    Assert-True ($native.calls.Count -eq 0) 'Publication fetched a deployment token for an unrecorded site.'
    Assert-Rejected { Publish-AzureWebPayload $context $target $payload -Confirm:$false } 'publicationUncertain'
    $native.acknowledged = $true; Publish-AzureWebPayload $context $target $payload -Confirm:$false
    $call = $native.calls[-1]
    Assert-True ($call.environment.DEPLOYMENT_TOKEN -ceq 'fixture-deployment-token' -and $call.environment.SKIP_APP_BUILD -ceq 'true' -and $call.environment.SKIP_API_BUILD -ceq 'true') 'Deployment token or no-build flags were not passed through the environment.'
    Assert-True (@($call.arguments).Count -eq 0 -and $call.environment.API_LOCATION -ceq '' -and $call.environment.DATA_API_LOCATION -ceq '') 'Publication accepts command arguments or an application API build.'
    Assert-True ($call.environment.REPOSITORY_BASE -ceq $temporary -and $call.environment.APP_LOCATION -ceq $payload.directory -and $call.directory -ceq $temporary) 'Client scratch files overlap the public asset tree or the app escapes its private repository base.'
    Assert-True (@(Get-ChildItem -LiteralPath $temporary -Recurse -File | Select-String -SimpleMatch 'fixture-deployment-token').Count -eq 0) 'A deployment credential was written to disk.'
    $before = $native.calls.Count; Publish-AzureWebPayload $context $target $payload -WhatIf | Out-Null
    Assert-True ($native.calls.Count -eq $before) 'Publication WhatIf requested a token or uploaded content.'
    Exit-AzureLifecycleLease $context -Confirm:$false
    if (($IsWindows -or $IsLinux) -and [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq [Runtime.InteropServices.Architecture]::X64) {
        $spec = Get-StaticWebClientSpec
        Assert-True ($spec.url.Contains('/134664351bac2104cb9ec773226e5b3fc265675d/') -and $spec.sha256.Length -eq 64) 'Content deployment client is not pinned by immutable build and checksum.'
    }
    else { Assert-Rejected { Get-StaticWebClientSpec } 'clientPlatformUnsupported' }
}
finally {
    foreach ($name in @('AzureEnvironmentStore', 'StaticWebPublication', 'AzureWebDelivery')) { Import-Module (Join-Path $repository "scripts/$name.psm1") -Force }
    $resolved = [IO.Path]::GetFullPath($temporary)
    if ([IO.Path]::GetDirectoryName($resolved) -cne $parent -or -not [IO.Path]::GetFileName($resolved).StartsWith('hexagon-web-publication-tests-')) { throw 'Unsafe web test cleanup target.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Host "Static web publication and backend health tests passed ($script:assertions assertions)."
