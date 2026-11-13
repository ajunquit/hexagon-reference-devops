<#
.SYNOPSIS
    Exercises the AWS web delivery and acceptance (ADR 0025): the CloudFront site target, backend and
    identity health, SPA publication with invalidation, serving verification, the acceptance seed task,
    the cleanup consent with AWS roots and the evidence in the S3 custody. Doubles only.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repository 'scripts/AwsApplicationDelivery.psm1') -Force
foreach ($name in @('AwsWebDelivery', 'AwsAcceptance', 'AwsEnvironmentStore', 'AwsLifecycleResources', 'StaticWebPublication', 'AcceptanceCleanup', 'AzureAcceptance', 'EnvironmentLifecycle', 'PlatformBootstrap', 'EnvironmentSnapshot')) {
    Import-Module (Join-Path $repository "scripts/$name.psm1")
}
if (-not ('Hexagon.DeliveryTests.DeliveryHttpHandler' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'DeliveryHttpHandler.cs') }
$script:assertions = 0
function Assert-True([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message }; $script:assertions++ }
function Assert-Rejected([scriptblock] $Action, [string] $Code) {
    try { & $Action | Out-Null }
    catch { Assert-True ($_.Exception.Message -like "*$Code*") "Unexpected rejection: $($_.Exception.Message) $($_.ScriptStackTrace)"; return }
    throw "Expected rejection: $Code"
}
function Copy-Value([object] $Value) { return (ConvertTo-PlatformBootstrapJson $Value) | ConvertFrom-Json -AsHashtable -Depth 64 }
function Bytes([string] $Value) { return , [Text.Encoding]::UTF8.GetBytes($Value) }
function Write-Bundle([string] $Path, [hashtable] $Files) {
    $file = [IO.File]::Create($Path); $gzip = [IO.Compression.GZipStream]::new($file, [IO.Compression.CompressionLevel]::Fastest); $tar = [System.Formats.Tar.TarWriter]::new($gzip)
    try {
        foreach ($name in $Files.Keys) {
            $entry = [System.Formats.Tar.PaxTarEntry]::new([System.Formats.Tar.TarEntryType]::RegularFile, $name); $entry.DataStream = [IO.MemoryStream]::new([byte[]] $Files[$name])
            try { $tar.WriteEntry($entry) } finally { $entry.DataStream.Dispose() }
        }
    }
    finally { $tar.Dispose(); $gzip.Dispose(); $file.Dispose() }
}
$temporary = Join-Path ([IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)) "hexagon-aws-web-tests-$([guid]::NewGuid().ToString('N'))"
[IO.Directory]::CreateDirectory($temporary) | Out-Null

# A verified AWS instance: both roots with their recorded resources.
$inventory = Get-Content -Raw -LiteralPath (Join-Path $repository 'examples/environment-inventory-aws.json') | ConvertFrom-Json -AsHashtable -Depth 32
$prefix = $inventory.roots[0].namePrefix; $account = $inventory.target.accountId
$bucket = "$prefix-web-$account"; $distribution = 'E2ABCDEFGHIJKL'; $origin = 'https://d111111abcdef8.cloudfront.net'
$topic = "arn:aws:sns:us-east-1:${account}:$prefix-events"
foreach ($root in $inventory.roots) {
    $root.status = 'Verified'; $root.lastOperation = 'Create'; $root.stateLineage = '44444444-4444-4444-4444-444444444444'; $root.stateSerial = 3
    $records = @(if ($root.id -ceq 'hosting') { @{ type = 'aws_s3_bucket'; name = 'web'; id = $bucket }; @{ type = 'aws_cloudfront_distribution'; name = 'web'; id = $distribution } } else { @{ type = 'aws_sns_topic'; name = 'events'; id = $topic } })
    $root.resources = @($records | ForEach-Object { @{ address = "module.$($root.id).$($_.type).$($_.name)"; id = (ConvertTo-AwsLifecycleResourceId $inventory $_.type $_.id); type = $_.type; current = $true; presence = 'Present' } })
}

try {
    # Content types: explicit for what a browser executes or renders, generic otherwise.
    Assert-True ((Get-AwsWebContentType 'index.html') -ceq 'text/html; charset=utf-8' -and (Get-AwsWebContentType 'chunk-AB12.js') -ceq 'text/javascript; charset=utf-8' -and
        (Get-AwsWebContentType 'runtime-config.json') -ceq 'application/json' -and (Get-AwsWebContentType 'assets/logo.SVG') -ceq 'image/svg+xml' -and
        (Get-AwsWebContentType 'assets/data.bin') -ceq 'application/octet-stream') 'Content types.'

    # In-memory S3 custody and an AWS CLI double.
    $script:objects = @{}
    $s3 = {
        param($operation, $key, $bytes, $ifNoneMatch, $ifMatch)
        if ($operation -ceq 'Get') { if (-not $script:objects.ContainsKey($key)) { return @{ status = 404 } }; return @{ status = 200; bytes = $script:objects[$key].bytes; etag = $script:objects[$key].etag } }
        $exists = $script:objects.ContainsKey($key)
        if (($ifNoneMatch -and $exists) -or ($ifMatch -and (-not $exists -or $script:objects[$key].etag -cne $ifMatch))) { return @{ status = 412 } }
        $etag = '"' + [guid]::NewGuid().ToString('N') + '"'; $script:objects[$key] = @{ bytes = $bytes; etag = $etag }; return @{ status = 200; etag = $etag }
    }
    $ok = { param($value) @{ exitCode = 0; text = (ConvertTo-PlatformBootstrapJson $value); errorText = '' } }
    $script:handlers = @{}; $script:calls = [Collections.Generic.List[object]]::new()
    $cli = { param($arguments) $line = $arguments -join ' '; $script:calls.Add(@{ line = $line; arguments = @($arguments) })
        foreach ($p in $script:handlers.Keys) { if ($line -like $p) { return & $script:handlers[$p] $line $arguments } }; throw "Unexpected AWS call: $line" }
    $context = New-AwsLifecycleContext (Copy-Value $inventory) "arn:aws:sts::${account}:assumed-role/hexagon-template-dev-run-12345-1-deploy/GitHubActions" $account $s3
    Enter-AwsLifecycleLease $context -Confirm:$false
    $context.awsCli = $cli; $context.runtime = Join-Path $temporary 'runtime'; [IO.Directory]::CreateDirectory($context.runtime) | Out-Null

    # The site target is the bucket and the distribution the hosting root recorded, and nothing else.
    $authority = "$origin/auth/realms/hexagon"
    $digest = 'sha256:' + ('d' * 64); $server = "$account.dkr.ecr.us-east-1.amazonaws.com"
    $images = @{ api = "$server/$prefix/hexagon-example-api@$digest"; worker = "$server/$prefix/hexagon-example-worker@$digest" }
    $hosting = @{
        inputs = @{ application_rollout_enabled = $true; keycloak_rollout_enabled = $true; keycloak = @{ realm = 'hexagon' }; migration_workload = 'api'; bootstrap_image = "$server/$prefix/database-bootstrap@$digest"
            workloads = @{ api = @{ name = "$prefix-api"; kind = 'api'; image = $images.api; min_replicas = 1 }; worker = @{ name = "$prefix-worker"; kind = 'consumer'; image = $images.worker; min_replicas = 1 } } }
        outputs = @{ web = @{ bucket = $bucket; distribution_id = $distribution; url = $origin }; api_url = "$origin/api/v1"
            frontend_authentication = @{ authority = $authority; clientId = 'hexagon-web'; scope = 'openid profile email hexagon.access' }
            keycloak = @{ service = "$prefix-auth"; origin = "$origin/auth"; authority = $authority } }
    }
    $target = Get-AwsWebTarget $context $hosting
    Assert-True ($target.bucket -ceq $bucket -and $target.distributionId -ceq $distribution -and $target.origin -ceq $origin) 'Site target.'
    $foreign = Copy-Value $hosting; $foreign.outputs.web.bucket = 'another-product-web-123456789012'
    Assert-Rejected { Get-AwsWebTarget $context $foreign } 'lifecycle.web.siteUnrecorded'
    $foreign = Copy-Value $hosting; $foreign.outputs.web.distribution_id = 'E9ZZZZZZZZZZZZ'
    Assert-Rejected { Get-AwsWebTarget $context $foreign } 'lifecycle.web.siteUnrecorded'
    $foreign = Copy-Value $hosting; $foreign.outputs.web.url = 'https://example.com'
    Assert-Rejected { Get-AwsWebTarget $context $foreign } 'lifecycle.web.siteUnrecorded'

    # Identity discovery: the exact issuer and endpoints, with PKCE S256.
    $script:discovery = @{ issuer = $authority; authorization_endpoint = "$authority/protocol/openid-connect/auth"; token_endpoint = "$authority/protocol/openid-connect/token"
        jwks_uri = "$authority/protocol/openid-connect/certs"; code_challenge_methods_supported = @('plain', 'S256') }
    $script:discoveryStatus = 200; $script:requested = [Collections.Generic.List[string]]::new()
    $context.httpGet = { param($address) $script:requested.Add($address); @{ status = $script:discoveryStatus; text = (ConvertTo-Json -InputObject $script:discovery -Compress) } }
    Assert-AwsIdentityDiscovery $context $authority
    Assert-True ($script:requested[0] -ceq "$authority/.well-known/openid-configuration") 'Discovery address.'
    $script:discovery.issuer = 'https://attacker.example/realms/hexagon'
    Assert-Rejected { Assert-AwsIdentityDiscovery $context $authority } 'lifecycle.identity.discoveryInvalid'
    $script:discovery.issuer = $authority; $script:discovery.code_challenge_methods_supported = @('plain')
    Assert-Rejected { Assert-AwsIdentityDiscovery $context $authority } 'lifecycle.identity.discoveryInvalid'
    $script:discovery.code_challenge_methods_supported = @('S256'); $script:discoveryStatus = 503
    Assert-Rejected { Assert-AwsIdentityDiscovery $context $authority } 'lifecycle.identity.discoveryUnavailable'
    $script:discoveryStatus = 200

    # Backend health: every service stable with its image; API targets healthy; workers without ingress.
    $targetGroup = "arn:aws:elasticloadbalancing:us-east-1:${account}:targetgroup/$prefix-api/0123456789abcdef"
    $script:services = @{
        "$prefix-api" = @{ serviceName = "$prefix-api"; serviceArn = "arn:aws:ecs:us-east-1:${account}:service/$prefix/$prefix-api"; status = 'ACTIVE'; desiredCount = 1; runningCount = 1
            taskDefinition = "arn:aws:ecs:us-east-1:${account}:task-definition/$prefix-api:4"; deployments = @(@{ rolloutState = 'COMPLETED' }); loadBalancers = @(@{ targetGroupArn = $targetGroup; containerName = 'application'; containerPort = 8080 }) }
        "$prefix-worker" = @{ serviceName = "$prefix-worker"; serviceArn = "arn:aws:ecs:us-east-1:${account}:service/$prefix/$prefix-worker"; status = 'ACTIVE'; desiredCount = 1; runningCount = 1
            taskDefinition = "arn:aws:ecs:us-east-1:${account}:task-definition/$prefix-worker:4"; deployments = @(@{ rolloutState = 'COMPLETED' }); loadBalancers = @() }
        "$prefix-auth" = @{ serviceName = "$prefix-auth"; serviceArn = "arn:aws:ecs:us-east-1:${account}:service/$prefix/$prefix-auth"; status = 'ACTIVE'; desiredCount = 1; runningCount = 1
            taskDefinition = "arn:aws:ecs:us-east-1:${account}:task-definition/$prefix-auth:2"; deployments = @(@{ rolloutState = 'COMPLETED' }); loadBalancers = @() }
    }
    $script:taskImages = @{ "$prefix-api" = $images.api; "$prefix-worker" = $images.worker }
    $script:targetStates = @('healthy')
    $script:handlers['ecs describe-services*'] = { param($line, $arguments) $name = $arguments[[Array]::IndexOf($arguments, '--services') + 1]
        if ($arguments[[Array]::IndexOf($arguments, '--cluster') + 1] -cne $prefix) { throw 'Wrong cluster.' }
        & $ok @{ services = @($(if ($script:services.ContainsKey($name)) { $script:services[$name] })) } }
    $script:handlers['ecs describe-task-definition*'] = { param($line, $arguments) $family = ($arguments[[Array]::IndexOf($arguments, '--task-definition') + 1] -split '/')[-1].Split(':')[0]
        & $ok @{ taskDefinition = @{ containerDefinitions = @(@{ name = 'application'; image = $script:taskImages[$family] }) } } }
    $script:handlers['elbv2 describe-target-health*'] = { param($line, $arguments) & $ok @{ TargetHealthDescriptions = @($script:targetStates | ForEach-Object { @{ TargetHealth = @{ State = $_ } } }) } }
    $facts = Get-AwsBackendHealth $context $hosting
    Assert-True ($facts.Count -eq 2 -and $facts[0].workloadId -ceq 'api' -and $facts[0].image -ceq $images.api -and $facts[1].runningTasks -eq 1) 'Backend health facts.'
    Assert-True (@($script:calls | Where-Object { $_.line -like "ecs describe-services*$prefix-auth*" }).Count -eq 1) 'Integrated identity must be checked with the backend.'
    $script:services["$prefix-api"].deployments = @(@{ rolloutState = 'IN_PROGRESS' }, @{ rolloutState = 'COMPLETED' })
    Assert-Rejected { Get-AwsBackendHealth $context $hosting } 'lifecycle.web.workloadNotReady'
    $script:services["$prefix-api"].deployments = @(@{ rolloutState = 'COMPLETED' }); $script:services["$prefix-api"].runningCount = 0
    Assert-Rejected { Get-AwsBackendHealth $context $hosting } 'lifecycle.web.workloadNotReady'
    $script:services["$prefix-api"].runningCount = 1; $script:taskImages["$prefix-api"] = "$server/$prefix/other@$digest"
    Assert-Rejected { Get-AwsBackendHealth $context $hosting } 'lifecycle.web.workloadImageChanged'
    $script:taskImages["$prefix-api"] = $images.api; $script:targetStates = @('unhealthy', 'draining')
    Assert-Rejected { Get-AwsBackendHealth $context $hosting } 'lifecycle.web.targetsNotHealthy'
    $script:targetStates = @('healthy'); $script:services["$prefix-worker"].loadBalancers = @(@{ targetGroupArn = $targetGroup; containerPort = 8080 })
    Assert-Rejected { Get-AwsBackendHealth $context $hosting } 'lifecycle.web.workerIngressExposed'
    $script:services["$prefix-worker"].loadBalancers = @()
    $missing = $script:services["$prefix-worker"]; $script:services.Remove("$prefix-worker")
    Assert-Rejected { Get-AwsBackendHealth $context $hosting } 'lifecycle.web.workloadUnrecorded'
    $script:services["$prefix-worker"] = $missing
    $inactive = Copy-Value $hosting; $inactive.inputs.application_rollout_enabled = $false
    Assert-Rejected { Get-AwsBackendHealth $context $inactive } 'lifecycle.web.activationRequired'
    # Identity readiness on its own: the rollout input, the stable service and the same authority.
    $pending = Copy-Value $hosting; $pending.inputs.keycloak_rollout_enabled = $false; $pending.outputs.keycloak.service = $null
    Assert-Rejected { Assert-AwsIdentityReady $context $pending } 'lifecycle.identity.rolloutRequired'
    $script:services["$prefix-auth"].runningCount = 0
    Assert-Rejected { Assert-AwsIdentityReady $context $hosting } 'lifecycle.identity.notReady'
    $script:services["$prefix-auth"].runningCount = 1
    $changed = Copy-Value $hosting; $changed.outputs.keycloak.authority = "$origin/auth/realms/other"
    Assert-Rejected { Assert-AwsIdentityReady $context $changed } 'lifecycle.identity.authorityChanged'
    $external = Copy-Value $hosting; $external.inputs.keycloak = $null; $script:calls.Clear()
    Assert-AwsIdentityReady $context $external
    Assert-True ($script:calls.Count -eq 0) 'An external identity provider is not probed as a service of the instance.'

    # Publication: explicit types and cache policies, entry points last, stale objects removed, invalidation awaited.
    $manifest = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'fixtures/hosting/frontend.json') | ConvertFrom-Json
    $outputs = @{ api_url = @{ value = "$origin/api/v1" }; frontend_authentication = @{ value = $hosting.outputs.frontend_authentication } }
    $archive = Join-Path $temporary 'web.tar.gz'
    Write-Bundle $archive @{ 'index.html' = Bytes '<html>production SPA</html>'; 'main-HASH.js' = Bytes 'production-code'; 'assets/fixture.json' = Bytes '{"public":true}' }
    $payload = New-StaticWebPayload $archive (Get-LifecycleFileHash $archive) $manifest $outputs ('a' * 64) ('b' * 64) (Join-Path $context.runtime 'payload') -Confirm:$false
    $script:published = @{}; $script:removed = [Collections.Generic.List[string]]::new(); $script:invalidationPolls = 0; $script:putFailure = $null
    $script:handlers['s3api put-object*'] = { param($line, $arguments)
        $value = { param($flag) $arguments[[Array]::IndexOf($arguments, $flag) + 1] }
        if ((& $value '--bucket') -cne $bucket) { throw 'Wrong bucket.' }
        if ($script:putFailure -ceq (& $value '--key')) { return @{ exitCode = 254; text = ''; errorText = 'AccessDenied' } }
        $script:published[(& $value '--key')] = @{ bytes = [IO.File]::ReadAllBytes((& $value '--body')); contentType = (& $value '--content-type'); cacheControl = (& $value '--cache-control'); order = $script:published.Count }
        & $ok @{ ETag = '"x"' } }
    $script:handlers['s3api list-objects-v2*'] = { param($line, $arguments)
        if ($line -like '*--continuation-token page-2*') { return & $ok @{ Contents = @(@{ Key = 'stale/old-chunk.js' }, @{ Key = 'index.html' }) } }
        & $ok @{ Contents = @(@{ Key = 'main-HASH.js' }, @{ Key = 'old-main.js' }); NextContinuationToken = 'page-2' } }
    $script:handlers['s3api delete-object*'] = { param($line, $arguments) $script:removed.Add($arguments[[Array]::IndexOf($arguments, '--key') + 1]); & $ok @{} }
    $script:handlers['cloudfront create-invalidation*'] = { param($line, $arguments)
        if ($arguments[[Array]::IndexOf($arguments, '--distribution-id') + 1] -cne $distribution -or $arguments[[Array]::IndexOf($arguments, '--paths') + 1] -cne '/*') { throw 'Wrong invalidation.' }
        & $ok @{ Invalidation = @{ Id = 'I2J0I21PCUYOIK'; Status = 'InProgress' } } }
    $script:handlers['cloudfront get-invalidation*'] = { param($line, $arguments) $script:invalidationPolls++
        & $ok @{ Invalidation = @{ Id = 'I2J0I21PCUYOIK'; Status = $(if ($script:invalidationPolls -lt 2) { 'InProgress' } else { 'Completed' }) } } }
    $result = Publish-AwsWebPayload $context $target $payload 30 0 -Confirm:$false
    $expectedNames = @($payload.files.Keys | Where-Object { $_ -cne 'staticwebapp.config.json' })
    Assert-True ($result.invalidationId -ceq 'I2J0I21PCUYOIK' -and $result.files -eq $expectedNames.Count -and $script:invalidationPolls -eq 2) 'Publication must wait for the invalidation.'
    Assert-True ((@($script:published.Keys | Sort-Object) -join ',') -ceq (@($expectedNames | Sort-Object) -join ',') -and -not $script:published.ContainsKey('staticwebapp.config.json')) 'Only the public files of the payload are uploaded.'
    $last = @($script:published.Keys | Sort-Object { $script:published[$_].order } | Select-Object -Last 3)
    Assert-True (($last -join ',') -ceq 'index.html,runtime-config.json,hexagon-deployment.json') 'Entry points and the deployment marker go last.'
    Assert-True ($script:published['index.html'].cacheControl -ceq 'no-store' -and $script:published['runtime-config.json'].cacheControl -ceq 'no-store' -and
        $script:published['main-HASH.js'].cacheControl -ceq 'no-cache' -and $script:published['main-HASH.js'].contentType -ceq 'text/javascript; charset=utf-8') 'Cache policies and types.'
    Assert-True ((@($script:removed | Sort-Object) -join ',') -ceq 'old-main.js,stale/old-chunk.js') 'Objects outside the payload are removed, on every page.'
    $script:putFailure = 'index.html'
    Assert-Rejected { Publish-AwsWebPayload $context $target $payload 30 0 -Confirm:$false } 'lifecycle.web.publicationUncertain'
    $script:putFailure = $null; $script:invalidationPolls = -1000
    Assert-Rejected { Publish-AwsWebPayload $context $target $payload 0 0 -Confirm:$false } 'lifecycle.web.invalidationPending'
    $script:calls.Clear()
    Publish-AwsWebPayload $context $target $payload -WhatIf | Out-Null
    Assert-True ($script:calls.Count -eq 0) 'WhatIf must not publish.'

    # What was published satisfies the common serving verification behind the security headers policy.
    $http = [Hexagon.DeliveryTests.DeliveryHttpHandler]::new()
    & (Get-Module StaticWebPublication) { param($handler) $script:webHttp = $handler; function script:New-PublicWebHttpClient { return [Net.Http.HttpClient]::new($script:webHttp, $false) } } $http
    $serve = { param($url, $name)
        $http.Route('GET', $url, 200, $script:published[$name].bytes); $http.Header('GET', $url, 'Cache-Control', $script:published[$name].cacheControl); $http.Header('GET', $url, 'Content-Type', $script:published[$name].contentType)
        $http.Header('GET', $url, 'X-Content-Type-Options', 'nosniff'); $http.Header('GET', $url, 'Referrer-Policy', 'no-referrer') }
    foreach ($name in $script:published.Keys) { & $serve "$origin/$name" $name }
    foreach ($url in @("$origin/", "$origin/__hexagon_probe__/route/$($payload.deploymentSha256.Substring(0, 16))")) { & $serve $url 'index.html' }
    $serving = Test-StaticWebServing $payload $origin { }
    Assert-True ($serving.filesVerified -eq $expectedNames.Count -and $serving.fallbackVerified) 'The published site must pass the serving verification.'

    # The acceptance seed runs the API image with its own command and the fixture of this instance.
    $journal = @{ jobs = @{ 'database-credentials' = @{ status = 'Succeeded' }; migrations = @{ status = 'Succeeded' } } }
    Assert-Rejected { Assert-AwsDeliveryTasksComplete $journal $external } 'lifecycle.delivery.previousTaskRequired'
    Assert-Rejected { Assert-AwsDeliveryTaskOrder $journal $external 'acceptance-seed' } 'lifecycle.delivery.previousTaskRequired'
    $journal.jobs['database-access'] = @{ status = 'Succeeded' }
    Assert-AwsDeliveryTasksComplete $journal $external; Assert-AwsDeliveryTaskOrder $journal $external 'acceptance-seed'; $script:assertions += 2
    Assert-Rejected { Assert-AwsDeliveryTasksComplete $journal $hosting } 'lifecycle.delivery.previousTaskRequired'
    Assert-Rejected { Assert-AwsDeliveryTaskOrder $journal $hosting 'acceptance-seed' } 'lifecycle.delivery.previousTaskRequired'
    $journal.jobs['keycloak-database'] = @{ status = 'Succeeded' }
    Assert-AwsDeliveryTasksComplete $journal $hosting; $script:assertions++
    $fixture = @{ instanceId = $inventory.instance.id; subjectId = '55555555-5555-4555-8555-555555555555'; tenant = "e2e-$($inventory.instance.id)-a"; otherTenant = "e2e-$($inventory.instance.id)-b" }
    $seedArn = "arn:aws:ecs:us-east-1:${account}:task-definition/$prefix-acceptance-seed:1"
    $seeded = Copy-Value $hosting; $seeded.inputs.acceptance_fixture = $fixture
    $seeded.outputs.maintenance_tasks = @{ 'acceptance-seed' = @{ arn = $seedArn } }
    $seeded.outputs.task_network = @{ cluster = $prefix; subnets = @('subnet-1', 'subnet-2'); security_groups = @('sg-1'); assign_public_ip = $true }
    $script:seedDefinition = @{ taskDefinitionArn = $seedArn; status = 'ACTIVE'; containerDefinitions = @(@{ name = 'maintenance'; image = $images.api; command = @('--seed-acceptance-only')
                environment = @(@{ name = 'ASPNETCORE_ENVIRONMENT'; value = 'Production' }, @{ name = 'HEXAGON_ACCEPTANCE_SEED'; value = (ConvertTo-Json -InputObject $fixture -Compress) }) }) }
    $script:handlers['ecs describe-task-definition*'] = { param($line, $arguments) & $ok @{ taskDefinition = $script:seedDefinition } }
    $spec = Get-AwsDeliveryTaskSpec $context $seeded 'acceptance-seed'
    Assert-True ($spec.image -ceq $images.api -and ($spec.command -join ' ') -ceq '--seed-acceptance-only' -and $spec.taskDefinitionArn -ceq $seedArn) 'Seed task specification.'
    $foreignFixture = @{} + $fixture; $foreignFixture.tenant = 'existing-tenant'
    $script:seedDefinition.containerDefinitions[0].environment[1].value = (ConvertTo-Json -InputObject $foreignFixture -Compress)
    Assert-Rejected { Get-AwsDeliveryTaskSpec $context $seeded 'acceptance-seed' } 'lifecycle.acceptance.fixtureChanged'
    $script:seedDefinition.containerDefinitions[0].environment[1].value = (ConvertTo-Json -InputObject $fixture -Compress); $script:seedDefinition.containerDefinitions[0].command = @('--migrate-only')
    Assert-Rejected { Get-AwsDeliveryTaskSpec $context $seeded 'acceptance-seed' } 'lifecycle.delivery.maintenanceJobChanged'
    $unfixtured = Copy-Value $seeded; $unfixtured.inputs.Remove('acceptance_fixture'); $script:seedDefinition.containerDefinitions[0].command = @('--seed-acceptance-only')
    Assert-Rejected { Get-AwsDeliveryTaskSpec $context $unfixtured 'acceptance-seed' } 'lifecycle.acceptance.fixtureRequired'

    # The cleanup consent names AWS roots by their short prefix and admits only their recorded resources.
    $consent = New-AcceptanceConsent $inventory ('b' * 64) ('c' * 64)
    Assert-True ((ConvertTo-Json -InputObject $consent -Depth 20) | Test-Json -SchemaFile (Join-Path $repository 'contracts/schemas/acceptance-cleanup-consent-v1.schema.json') -ErrorAction SilentlyContinue) 'An AWS consent must satisfy its contract.'
    Assert-True (@($consent.roots | Where-Object { $_.namePrefix -ceq $prefix -and -not $_.ContainsKey('resourceGroup') }).Count -eq 2) 'AWS roots are scoped by their prefix.'
    Assert-AcceptanceConsent $inventory $consent ('b' * 64) ('c' * 64) "TEST AND CLEANUP $($inventory.product) dev $($inventory.instance.id)"; $script:assertions++
    $root = @($inventory.roots | Where-Object id -CEQ 'hosting')[0]
    $changes = @($root.resources | ForEach-Object { @{ mode = 'managed'; address = $_.address; type = $_.type; change = @{ actions = @('delete'); before = @{ id = ($_.id -split ':', 5)[4] }; after = $null } } })
    $plan = @{ format_version = '1.2'; errored = $false; complete = $true; resource_changes = $changes }
    Assert-AcceptanceDestroyPlan $inventory $root $consent $plan; $script:assertions++
    $bad = Copy-Value $plan; $bad.resource_changes[0].change.before.id = 'another-product-web-123456789012'
    Assert-Rejected { Assert-AcceptanceDestroyPlan $inventory $root $consent $bad } 'planResourceUnrecorded'
    $bad = Copy-Value $plan; $bad.resource_changes = @($bad.resource_changes[0])
    Assert-Rejected { Assert-AcceptanceDestroyPlan $inventory $root $consent $bad } 'deleteSetIncomplete'
    $bad = Copy-Value $plan; $bad.resource_changes[0].change.actions = @('delete', 'create')
    Assert-Rejected { Assert-AcceptanceDestroyPlan $inventory $root $consent $bad } 'planOperationMismatch'
    $drifted = Copy-Value $inventory; $drifted.roots[0].stateSerial++
    Assert-Rejected { Assert-AcceptanceDestroyPlan $drifted $drifted.roots[0] $consent $plan } 'lifecycle.acceptance.stateChanged'

    # Evidence goes to the S3 custody by its hash; the browser never starts without its credentials.
    $evidence = @{ apiVersion = 'hexagon.ec/acceptance-evidence/v1'; product = $inventory.product; environment = $inventory.environment; instanceId = $inventory.instance.id
        releaseSha256 = $inventory.releaseSha256; deliverySha256 = 'b' * 64; consentSha256 = 'a' * 64; observedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        journeySucceeded = $true; cleanupStatus = 'Pending'; code = $null }
    $hash = Save-AwsAcceptanceEvidence $context $evidence -Confirm:$false
    $key = "$($inventory.product)/dev/$($inventory.instance.id)/evidence/$hash.json"
    Assert-True ($hash -cmatch '^[0-9a-f]{64}$' -and $script:objects.ContainsKey($key) -and (Get-AwsLifecycleBytesHash $script:objects[$key].bytes) -ceq $hash) 'Evidence must be stored by its hash in the instance prefix.'
    $invalid = @{} + $evidence; $invalid.cleanupStatus = 'Skipped'
    Assert-Rejected { Save-AwsAcceptanceEvidence $context $invalid -Confirm:$false } 'lifecycle.acceptance.evidenceInvalid'
    $previous = @($env:HEXAGON_E2E_USERNAME, $env:HEXAGON_E2E_PASSWORD)
    try {
        $env:HEXAGON_E2E_USERNAME = $null; $env:HEXAGON_E2E_PASSWORD = $null
        Assert-Rejected { Invoke-AwsBrowserAcceptance $context @{} -Confirm:$false } 'lifecycle.acceptance.credentialsMissing'
    }
    finally { $env:HEXAGON_E2E_USERNAME = $previous[0]; $env:HEXAGON_E2E_PASSWORD = $previous[1] }

    # Outside the trusted workflow no stage runs; WhatIf touches nothing.
    $before = $script:objects.Count; $script:calls.Clear()
    $whatIf = Invoke-AwsApplicationStage $context @{} @{} ('b' * 64) PublishWeb $repository ('a' * 40) $temporary -WhatIf
    Assert-True ($whatIf.status -ceq 'Unverified' -and $script:calls.Count -eq 0 -and $script:objects.Count -eq $before) 'Stage WhatIf must not touch AWS.'
    foreach ($stage in @('PrepareIdentity', 'ApplyActivation', 'PublishWeb', 'VerifyServing', 'Acceptance')) {
        Assert-Rejected { Invoke-AwsApplicationStage $context @{} @{} ('b' * 64) $stage $repository ('a' * 40) $temporary -Confirm:$false } 'lifecycle.aws.trustedWorkflowRequired'
    }

    # The real stage dispatch, with only the outer edges replaced: state, registry, artifact download,
    # Terraform plans, tasks, the browser and the cleanup.
    $stageHosting = Copy-Value $seeded
    $stageHosting.inputs.maintenance_jobs_enabled = $true; $stageHosting.inputs.application_rollout_enabled = $false
    $stageHosting.references = @{}; $stageHosting.server = $server; $stageHosting.registry = "$server/$prefix"; $stageHosting.state = @{ lineage = 'hosting-lineage'; serial = 7 }
    $stageFixture = @{ hosting = $stageHosting; payload = $payload; inputs = $null; plans = [Collections.Generic.List[string]]::new(); applied = [Collections.Generic.List[string]]::new()
        tasks = [Collections.Generic.List[string]]::new(); browser = 0; cleanup = 0; state = @{ stateStatus = 'Present'; lineage = 'hosting-lineage'; serial = 7 }; browserResult = $null }
    $stageFixture.browserResult = @{ apiVersion = 'hexagon.ec/browser-acceptance-result/v1'; status = 'Succeeded'; pkce = $true; authenticatedCreate = $true; workerReaction = $true; tenantIsolation = $true }
    & (Get-Module AwsApplicationDelivery) { param($fixture) $script:stageFixture = $fixture
        function script:Assert-ApplicationDelivery { }
        function script:Get-AwsDeliveryHosting { return $script:stageFixture.hosting }
        function script:Assert-AwsOciImages { }
        function script:New-AwsWebPayload { return $script:stageFixture.payload }
        function script:Get-AwsLifecycleState { return $script:stageFixture.state }
        function script:Get-AcceptanceContracts { return @{ backend = @{ fixture = 'backend' }; web = @{ fixture = 'web' } } }
        function script:Set-AwsDeliveryInputs { param($Context, $Value) $script:stageFixture.inputs = $Value }
        function script:New-AwsDeliveryPlan { param($Context, $Journal, $Purpose) $script:stageFixture.plans.Add($Purpose); return 'c' * 64 }
        function script:Invoke-AwsDeliveryPlan { param($Context, $Journal, $Purpose) $script:stageFixture.applied.Add($Purpose); if ($Purpose -ceq 'Activation') { $Journal.activated = $true }; Save-AwsDeliveryJournal $Context $Journal -Confirm:$false }
        function script:Invoke-AwsDeliveryTask { param($Context, $Journal, $Hosting, $TaskId) $script:stageFixture.tasks.Add($TaskId); return @{ executionId = 'task'; status = 'Succeeded' } }
        function script:Invoke-AwsBrowserAcceptance { [CmdletBinding(SupportsShouldProcess = $true)] param($Context, $Configuration) $script:stageFixture.browser++; $script:stageFixture.configuration = $Configuration; return $script:stageFixture.browserResult }
        function script:Invoke-AwsAcceptanceCleanup { [CmdletBinding(SupportsShouldProcess = $true)] param($Context, $Consent, $Workspace) $script:stageFixture.cleanup++; $script:stageFixture.consent = $Consent }
    } $stageFixture
    $script:handlers['ecs describe-task-definition*'] = { param($line, $arguments) $family = ($arguments[[Array]::IndexOf($arguments, '--task-definition') + 1] -split '/')[-1].Split(':')[0]
        & $ok @{ taskDefinition = @{ containerDefinitions = @(@{ name = 'application'; image = $script:taskImages[$family] }) } } }
    $workflow = @{}; foreach ($name in @('GITHUB_ACTIONS', 'GITHUB_REF', 'GITHUB_EVENT_NAME', 'GITHUB_REPOSITORY', 'GITHUB_WORKFLOW_REF')) { $workflow[$name] = [Environment]::GetEnvironmentVariable($name) }
    try {
        $env:GITHUB_ACTIONS = 'true'; $env:GITHUB_REF = 'refs/heads/main'; $env:GITHUB_EVENT_NAME = 'workflow_dispatch'
        $env:GITHUB_REPOSITORY = $inventory.iac.repository; $env:GITHUB_WORKFLOW_REF = "$($inventory.iac.repository)/.github/workflows/delivery.yml@refs/heads/main"
        $deliverySha = 'b' * 64
        $run = { param($stage, $review, $confirmation) Invoke-AwsApplicationStage $context @{} @{} $deliverySha $stage $repository ('a' * 40) $temporary $review $confirmation -Confirm:$false }
        $job = { param($task) @{ jobId = "arn:aws:ecs:us-east-1:${account}:task-definition/$prefix-$($task):1"; attemptId = [guid]::NewGuid().ToString(); templateSha256 = 'e' * 64; executionId = 'task'; status = 'Succeeded' } }
        $stageJournal = Read-AwsDeliveryJournal $context $deliverySha
        $stageJournal.maintenanceSha256 = Get-AwsDeliveryMaintenanceHash $context $stageHosting.inputs
        foreach ($task in @('database-credentials', 'migrations')) { $stageJournal.jobs[$task] = & $job $task }
        Save-AwsDeliveryJournal $context $stageJournal -Confirm:$false

        # Nothing rolls out before every database task and the identity are ready.
        Assert-Rejected { & $run PrepareActivation } 'lifecycle.delivery.previousTaskRequired'
        Assert-Rejected { & $run PrepareIdentity } 'lifecycle.identity.databasePreparationRequired'
        Assert-Rejected { & $run KeycloakDatabase } 'lifecycle.identity.alreadyStarted'
        Assert-Rejected { & $run PublishWeb } 'lifecycle.web.activationRequired'
        $stageJournal = Read-AwsDeliveryJournal $context $deliverySha
        foreach ($task in @('database-access', 'keycloak-database')) { $stageJournal.jobs[$task] = & $job $task }
        Save-AwsDeliveryJournal $context $stageJournal -Confirm:$false
        $stageHosting.inputs.keycloak_rollout_enabled = $false; $stageHosting.outputs.keycloak.service = $null
        Assert-Rejected { & $run ApplyIdentity } 'lifecycle.identity.rolloutInputsRequired'
        Assert-Rejected { & $run PrepareActivation } 'lifecycle.identity.rolloutRequired'
        $prepared = & $run PrepareIdentity
        Assert-True ($prepared.status -ceq 'Prepared' -and $prepared.details.reviewSha256 -ceq ('c' * 64) -and $stageFixture.inputs.keycloak_rollout_enabled -eq $true -and
            $stageHosting.inputs.keycloak_rollout_enabled -eq $false -and ($stageFixture.plans -join ',') -ceq 'Identity') 'Identity is prepared as a reviewed plan over a copy of the inputs.'
        $stageHosting.inputs.keycloak_rollout_enabled = $true; $stageHosting.outputs.keycloak.service = "$prefix-auth"
        Assert-True ((& $run ApplyIdentity ('c' * 64) 'CREATE').status -ceq 'Completed' -and ($stageFixture.applied -join ',') -ceq 'Identity') 'Identity apply.'
        Assert-Rejected { & $run ApplyActivation ('c' * 64) 'CREATE' } 'lifecycle.delivery.activationInputsRequired'
        $prepared = & $run PrepareActivation
        Assert-True ($prepared.status -ceq 'Prepared' -and $stageFixture.inputs.application_rollout_enabled -eq $true -and $stageHosting.inputs.application_rollout_enabled -eq $false) 'Activation is prepared over a copy of the inputs.'
        $stageHosting.inputs.application_rollout_enabled = $true
        & $run ApplyActivation ('c' * 64) 'CREATE' | Out-Null
        Assert-True ((Read-AwsDeliveryJournal $context $deliverySha).activated -and ($stageFixture.applied -join ',') -ceq 'Identity,Activation') 'Activation apply.'
        Assert-Rejected { & $run Migrations } 'lifecycle.delivery.activationOrderInvalid'
        Assert-Rejected { & $run PrepareActivation } 'lifecycle.delivery.alreadyActivated'

        # Publication records its intent before uploading; serving evidence is a separate step.
        Assert-Rejected { & $run VerifyServing } 'lifecycle.web.publicationEvidenceRequired'
        Assert-Rejected { & $run PrepareAcceptance } 'lifecycle.acceptance.servingRequired'
        $script:invalidationPolls = 5; $script:putFailure = 'index.html'
        Assert-Rejected { & $run PublishWeb } 'lifecycle.web.publicationUncertain'
        Assert-True ((Read-AwsDeliveryJournal $context $deliverySha).web.status -ceq 'Publishing') 'The publication intent must be durable before the upload.'
        Assert-Rejected { & $run VerifyServing } 'lifecycle.web.publicationEvidenceRequired'
        $script:putFailure = $null
        $published = & $run PublishWeb
        Assert-True ($published.status -ceq 'Completed' -and $published.details.invalidationId -ceq 'I2J0I21PCUYOIK' -and $published.details.deploymentSha256 -ceq $payload.deploymentSha256 -and
            (Read-AwsDeliveryJournal $context $deliverySha).web.status -ceq 'Published') 'PublishWeb.'
        $verified = & $run VerifyServing
        $web = (Read-AwsDeliveryJournal $context $deliverySha).web
        Assert-True ($verified.details.workloadsHealthy -eq 2 -and $verified.details.filesVerified -eq $expectedNames.Count -and $web.status -ceq 'Verified' -and
            $web.evidenceSha256 -ceq $verified.details.evidenceSha256 -and $script:objects.ContainsKey("$($inventory.product)/dev/$($inventory.instance.id)/evidence/$($web.evidenceSha256).json")) 'Serving evidence must be durable in the custody.'
        $stageFixture.state.serial = 8
        Assert-Rejected { & $run VerifyServing } 'lifecycle.web.stateChangedDuringVerification'
        $web = (Read-AwsDeliveryJournal $context $deliverySha).web
        Assert-True ($web.status -ceq 'Published' -and $null -eq $web.evidenceSha256) 'A failed verification must not keep the previous evidence.'
        Assert-Rejected { & $run PrepareAcceptance } 'lifecycle.acceptance.servingRequired'
        $stageFixture.state.serial = 7
        & $run VerifyServing | Out-Null

        # Acceptance: a stored consent, the seed, the browser, durable evidence and the consented cleanup.
        $review = (& $run PrepareAcceptance).details.reviewSha256
        Assert-True ($script:objects.ContainsKey("$($inventory.product)/dev/$($inventory.instance.id)/consents/$review.json") -and $stageFixture.browser -eq 0 -and $stageFixture.cleanup -eq 0) 'PrepareAcceptance only stores the consent.'
        $confirmation = "TEST AND CLEANUP $($inventory.product) dev $($inventory.instance.id)"
        Assert-Rejected { & $run Acceptance 'not-a-hash' $confirmation } 'lifecycle.acceptance.consentRequired'
        Assert-Rejected { & $run Acceptance $review "DESTROY $($inventory.product) dev $($inventory.instance.id)" } 'lifecycle.acceptance.consentInvalid'
        Assert-True ($stageFixture.browser -eq 0 -and $stageFixture.cleanup -eq 0 -and $stageFixture.tasks.Count -eq 0) 'Nothing runs without the exact consent.'
        $accepted = & $run Acceptance $review $confirmation
        $acceptance = (Read-AwsDeliveryJournal $context $deliverySha).acceptance
        Assert-True ($accepted.status -ceq 'Completed' -and $accepted.details.journeySucceeded -eq $true -and $accepted.details.cleanupStatus -ceq 'Destroyed' -and
            ($stageFixture.tasks -join ',') -ceq 'acceptance-seed' -and $stageFixture.browser -eq 1 -and $stageFixture.cleanup -eq 1) 'Acceptance runs the seed, the browser and the cleanup once.'
        Assert-True ($acceptance.status -ceq 'Completed' -and $acceptance.consentSha256 -ceq $review -and
            $script:objects.ContainsKey("$($inventory.product)/dev/$($inventory.instance.id)/evidence/$($acceptance.evidenceSha256).json")) 'Acceptance evidence must be durable in the custody.'
        Assert-True ($stageFixture.configuration.origin -ceq $origin -and $stageFixture.configuration.apiUrl -ceq "$origin/api/v1" -and $stageFixture.configuration.tenant -ceq $fixture.tenant -and
            $stageFixture.configuration.authentication.authority -ceq $authority -and @($stageFixture.consent.roots | Where-Object namePrefix -CEQ $prefix).Count -eq 2) 'The browser and the cleanup receive this instance and its consent.'
        Assert-Rejected { & $run Acceptance $review $confirmation } 'lifecycle.acceptance.alreadyStarted'
    }
    finally { foreach ($name in $workflow.Keys) { [Environment]::SetEnvironmentVariable($name, $workflow[$name]) } }
    Exit-AwsLifecycleLease $context -Confirm:$false
}
finally { Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host "AWS web delivery and acceptance tests passed: $($script:assertions) assertions; in-memory S3, AWS CLI, HTTP and discovery doubles."
