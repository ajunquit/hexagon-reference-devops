Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
foreach ($name in @('PlatformBootstrap', 'TerraformAwsLifecycle', 'AwsEnvironmentStore', 'AwsLifecycleResources', 'ApplicationArtifacts', 'ApplicationContracts', 'StaticWebPublication')) {
    Import-Module (Join-Path $PSScriptRoot "$name.psm1")
}

# The SPA and the serving checks of an AWS instance (ADR 0025): the verified bundle goes to the private
# bucket behind CloudFront with explicit types and cache policies, CloudFront is invalidated, and the
# backend counts as serving only when every ECS service completed its rollout with the expected image
# and the API targets are healthy. $Context.httpGet may be a test double for the identity discovery.

$script:noStore = @('index.html', 'runtime-config.json', 'hexagon-deployment.json')

function Get-AwsWebContentType([string] $Name) {
    switch ([IO.Path]::GetExtension($Name).ToLowerInvariant()) {
        '.html' { return 'text/html; charset=utf-8' }
        { $_ -in @('.js', '.mjs') } { return 'text/javascript; charset=utf-8' }
        '.css' { return 'text/css; charset=utf-8' }
        { $_ -in @('.json', '.map') } { return 'application/json' }
        '.webmanifest' { return 'application/manifest+json' }
        '.svg' { return 'image/svg+xml' }
        '.png' { return 'image/png' }
        { $_ -in @('.jpg', '.jpeg') } { return 'image/jpeg' }
        '.ico' { return 'image/x-icon' }
        '.woff' { return 'font/woff' }
        '.woff2' { return 'font/woff2' }
        '.wasm' { return 'application/wasm' }
        '.txt' { return 'text/plain; charset=utf-8' }
        default { return 'application/octet-stream' }
    }
}

function Get-AwsWebTarget([hashtable] $Context, [hashtable] $Hosting) {
    $web = $Hosting.outputs.web
    $prefix = $Context.inventory.roots[0].namePrefix
    $bucket = "$prefix-web-$($Context.inventory.target.accountId)"
    $resources = @($Context.inventory.roots | Where-Object id -CEQ 'hosting')[0].resources
    $recorded = { param($type, $id) @($resources | Where-Object { $_.current -and $_.type -ceq $type -and $_.id -ceq (ConvertTo-AwsLifecycleResourceId $Context.inventory $type $id) }).Count -eq 1 }
    if ($web.bucket -cne $bucket -or $web.distribution_id -cnotmatch '^[A-Z0-9]{8,20}$' -or $web.url -cnotmatch '^https://[a-z0-9]+[.]cloudfront[.]net$' -or
        -not (& $recorded 'aws_s3_bucket' $bucket) -or -not (& $recorded 'aws_cloudfront_distribution' $web.distribution_id)) { throw 'lifecycle.web.siteUnrecorded' }
    return @{ bucket = $bucket; distributionId = [string] $web.distribution_id; origin = [string] $web.url }
}

function Assert-AwsIdentityDiscovery([hashtable] $Context, [string] $Authority) {
    $address = "$Authority/.well-known/openid-configuration"
    $response = $(if ($Context.ContainsKey('httpGet') -and $null -ne $Context.httpGet) { & $Context.httpGet $address } else {
            try { $reply = Invoke-WebRequest -Uri $address -MaximumRedirection 0 -TimeoutSec 30 -SkipHttpErrorCheck; @{ status = [int] $reply.StatusCode; text = [string] $reply.Content } }
            catch { throw 'lifecycle.identity.discoveryUnavailable' } })
    if ($response.status -ne 200 -or $response.text.Length -gt 1MB) { throw 'lifecycle.identity.discoveryUnavailable' }
    try { $document = $response.text | ConvertFrom-Json -AsHashtable -Depth 16 } catch { throw 'lifecycle.identity.discoveryInvalid' }
    if ($document.issuer -cne $Authority -or $document.authorization_endpoint -cne "$Authority/protocol/openid-connect/auth" -or
        $document.token_endpoint -cne "$Authority/protocol/openid-connect/token" -or $document.jwks_uri -cne "$Authority/protocol/openid-connect/certs" -or
        @($document.code_challenge_methods_supported) -cnotcontains 'S256') { throw 'lifecycle.identity.discoveryInvalid' }
}

function Get-AwsStableService([hashtable] $Context, [string] $Name) {
    $described = Invoke-AwsLifecycleCli $Context @('ecs', 'describe-services', '--cluster', $Context.inventory.roots[0].namePrefix, '--services', $Name)
    if ($described.exitCode -ne 0) { throw 'lifecycle.web.workloadUnavailable' }
    $services = @(($described.text | ConvertFrom-Json -AsHashtable -Depth 16).services)
    if ($services.Count -ne 1 -or $services[0].serviceName -cne $Name) { throw 'lifecycle.web.workloadUnrecorded' }
    $deployments = @($services[0].deployments)
    if ($services[0].status -cne 'ACTIVE' -or $deployments.Count -ne 1 -or $deployments[0].rolloutState -cne 'COMPLETED') { throw 'lifecycle.web.workloadNotReady' }
    return $services[0]
}

# With integrated identity, the Keycloak service completed its rollout and answers discovery under /auth.
function Assert-AwsIdentityReady([hashtable] $Context, [hashtable] $Hosting) {
    $inputs = $Hosting.inputs
    if (-not $inputs.ContainsKey('keycloak') -or $null -eq $inputs.keycloak) { return }
    $keycloak = $(if ($Hosting.outputs.ContainsKey('keycloak')) { $Hosting.outputs.keycloak } else { $null })
    if ($inputs.keycloak_rollout_enabled -ne $true -or $null -eq $keycloak -or -not $keycloak.service) { throw 'lifecycle.identity.rolloutRequired' }
    Assert-AwsLifecycleLease $Context -Confirm:$false
    $service = Get-AwsStableService $Context ([string] $keycloak.service)
    if ($service.runningCount -lt 1) { throw 'lifecycle.identity.notReady' }
    if ($keycloak.authority -cne $Hosting.outputs.frontend_authentication.authority) { throw 'lifecycle.identity.authorityChanged' }
    Assert-AwsIdentityDiscovery $Context ([string] $keycloak.authority)
}

# Every workload runs its expected image with a completed rollout; the API targets are healthy behind
# the internal load balancer. With integrated identity, Keycloak answers discovery under /auth.
function Get-AwsBackendHealth([hashtable] $Context, [hashtable] $Hosting) {
    $inputs = $Hosting.inputs
    if ($inputs.application_rollout_enabled -ne $true) { throw 'lifecycle.web.activationRequired' }
    $facts = [Collections.Generic.List[hashtable]]::new()
    foreach ($id in @($inputs.workloads.Keys | Sort-Object)) {
        Assert-AwsLifecycleLease $Context -Confirm:$false
        $workload = $inputs.workloads[$id]
        $service = Get-AwsStableService $Context $workload.name
        if ($service.desiredCount -lt $workload.min_replicas -or $service.runningCount -lt $workload.min_replicas) { throw 'lifecycle.web.workloadNotReady' }
        $definition = Invoke-AwsLifecycleCli $Context @('ecs', 'describe-task-definition', '--task-definition', [string] $service.taskDefinition)
        if ($definition.exitCode -ne 0) { throw 'lifecycle.web.workloadUnavailable' }
        $containers = @(($definition.text | ConvertFrom-Json -AsHashtable -Depth 32).taskDefinition.containerDefinitions | Where-Object name -CEQ 'application')
        if ($containers.Count -ne 1 -or $containers[0].image -cne $workload.image) { throw 'lifecycle.web.workloadImageChanged' }
        $balancers = @($service['loadBalancers'] ?? @())
        if ($workload.kind -ceq 'api') {
            if ($balancers.Count -ne 1 -or $balancers[0].containerPort -ne 8080) { throw 'lifecycle.web.apiIngressChanged' }
            $targets = Invoke-AwsLifecycleCli $Context @('elbv2', 'describe-target-health', '--target-group-arn', [string] $balancers[0].targetGroupArn)
            if ($targets.exitCode -ne 0) { throw 'lifecycle.web.workloadUnavailable' }
            $states = @(($targets.text | ConvertFrom-Json -AsHashtable -Depth 16).TargetHealthDescriptions | ForEach-Object { $_.TargetHealth.State })
            $healthy = @($states | Where-Object { $_ -ceq 'healthy' }).Count
            if ($healthy -lt $workload.min_replicas) { throw 'lifecycle.web.targetsNotHealthy' }
        }
        elseif ($balancers.Count -ne 0) { throw 'lifecycle.web.workerIngressExposed' }
        $facts.Add(@{ workloadId = $id; service = [string] $service.serviceArn; taskDefinition = [string] $service.taskDefinition; image = $workload.image; runningTasks = [int] $service.runningCount })
    }
    Assert-AwsIdentityReady $Context $Hosting
    return , $facts.ToArray()
}

function New-AwsWebPayload([hashtable] $Context, [hashtable] $Delivery, [hashtable] $Release, [hashtable] $Hosting, [string] $DeliverySha256) {
    $renew = (Get-Command Assert-AwsLifecycleLease).ScriptBlock; $heartbeat = { & $renew $Context -Confirm:$false }.GetNewClosure()
    $candidates = Receive-ApplicationCandidates $Delivery $Release $Hosting.registry (Join-Path $Context.runtime "web-candidate-$([guid]::NewGuid().ToString('N'))") $heartbeat -ComponentNames web -Confirm:$false
    $source = @($Release.sources | Where-Object name -CEQ 'web')[0]
    $previousToken = $env:GH_TOKEN
    try {
        if ($env:HEXAGON_APPLICATIONS_READ_TOKEN) { $env:GH_TOKEN = $env:HEXAGON_APPLICATIONS_READ_TOKEN }
        $manifest = Get-ValidatedApplicationManifest -Repository $source.repository -Commit $source.commit -Path '.hexagon/frontend-hosting-requirements.json' -ExpectedProduct $Release.product -ExpectedComponent web
    }
    catch { throw 'lifecycle.web.sourceManifestUnavailable' }
    finally { $env:GH_TOKEN = $previousToken }
    if (@($source.manifests | Where-Object { $_.path -ceq '.hexagon/frontend-hosting-requirements.json' -and $_.sha256 -ceq $manifest.Sha256 }).Count -ne 1) { throw 'lifecycle.web.manifestMismatch' }
    $outputs = @{ api_url = @{ value = $Hosting.outputs.api_url }; frontend_authentication = @{ value = $Hosting.outputs.frontend_authentication } }
    $artifact = $candidates.web.build.artifacts[0]
    return New-StaticWebPayload (Join-Path $candidates.web.directory $artifact.file) $Release.artifacts.web.sha256 $manifest.Manifest $outputs $Context.inventory.releaseSha256 $DeliverySha256 (Join-Path $Context.runtime "spa-$([guid]::NewGuid().ToString('N'))") -Confirm:$false
}

# Uploads the payload (assets first, entry points and the deployment marker last), removes objects that
# no longer belong to it, and waits for the CloudFront invalidation. staticwebapp.config.json is an Azure
# host file: on AWS the CloudFront function and the response headers policy play its role.
function Publish-AwsWebPayload {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([hashtable] $Context, [hashtable] $Target, [hashtable] $Payload, [int] $TimeoutSeconds = 900, [int] $PollSeconds = 10)
    if (-not $PSCmdlet.ShouldProcess($Target.bucket, 'Publish the prebuilt SPA behind CloudFront')) { return }
    Assert-StaticWebPayload $Payload
    $names = @($Payload.files.Keys | Where-Object { $_ -cne 'staticwebapp.config.json' })
    $ordered = @($names | Where-Object { $_ -cnotin $script:noStore } | Sort-Object) + @('index.html', 'runtime-config.json', 'hexagon-deployment.json' | Where-Object { $_ -cin $names })
    foreach ($name in $ordered) {
        Assert-AwsLifecycleLease $Context -Confirm:$false
        $cache = $(if ($name -cin $script:noStore) { 'no-store' } else { 'no-cache' })
        $put = Invoke-AwsLifecycleCli $Context @('s3api', 'put-object', '--bucket', $Target.bucket, '--key', $name, '--body', (Join-Path $Payload.directory $name),
            '--content-type', (Get-AwsWebContentType $name), '--cache-control', $cache)
        if ($put.exitCode -ne 0) { throw 'lifecycle.web.publicationUncertain' }
    }
    $token = ''
    do {
        $arguments = @('s3api', 'list-objects-v2', '--bucket', $Target.bucket)
        if ($token) { $arguments += @('--continuation-token', $token) }
        $listed = Invoke-AwsLifecycleCli $Context $arguments
        if ($listed.exitCode -ne 0) { throw 'lifecycle.web.publicationUncertain' }
        $page = $listed.text | ConvertFrom-Json -AsHashtable -Depth 16
        foreach ($object in @($(if ($page.ContainsKey('Contents')) { $page.Contents } else { @() }))) {
            if ($object.Key -cnotin $names) {
                $removed = Invoke-AwsLifecycleCli $Context @('s3api', 'delete-object', '--bucket', $Target.bucket, '--key', [string] $object.Key)
                if ($removed.exitCode -ne 0) { throw 'lifecycle.web.publicationUncertain' }
            }
        }
        $token = $(if ($page.ContainsKey('NextContinuationToken')) { [string] $page.NextContinuationToken } else { '' })
    } while ($token)
    $created = Invoke-AwsLifecycleCli $Context @('cloudfront', 'create-invalidation', '--distribution-id', $Target.distributionId, '--paths', '/*')
    if ($created.exitCode -ne 0) { throw 'lifecycle.web.invalidationUnavailable' }
    $invalidation = [string] ($created.text | ConvertFrom-Json -AsHashtable -Depth 8).Invalidation.Id
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        Assert-AwsLifecycleLease $Context -Confirm:$false
        $status = Invoke-AwsLifecycleCli $Context @('cloudfront', 'get-invalidation', '--distribution-id', $Target.distributionId, '--id', $invalidation)
        if ($status.exitCode -ne 0) { throw 'lifecycle.web.invalidationUnavailable' }
        if (($status.text | ConvertFrom-Json -AsHashtable -Depth 8).Invalidation.Status -ceq 'Completed') { return @{ invalidationId = $invalidation; files = $ordered.Count } }
        if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw 'lifecycle.web.invalidationPending' }
        Start-Sleep -Seconds $PollSeconds
    } while ($true)
}

Export-ModuleMember -Function Get-AwsWebContentType, Get-AwsWebTarget, Assert-AwsIdentityDiscovery, Assert-AwsIdentityReady, Get-AwsBackendHealth, New-AwsWebPayload, Publish-AwsWebPayload
