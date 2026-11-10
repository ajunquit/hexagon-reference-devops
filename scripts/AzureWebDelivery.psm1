Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
foreach ($name in @('AzureEnvironmentStore', 'LifecycleNative', 'EnvironmentSnapshot', 'PlatformBootstrap', 'StaticWebPublication', 'StaticWebClient', 'ApplicationArtifacts', 'ApplicationContracts')) { Import-Module (Join-Path $PSScriptRoot "$name.psm1") }

function Get-WebDeliveryAzureObject([hashtable] $Context, [string] $Id, [string] $Version = '2024-03-01') {
    if ($Id -match '[?#%\\\s]|/[.][.]?(?:/|$)') { throw 'lifecycle.web.resourceIdInvalid' }
    $response = Invoke-AzureLifecycleHttp $Context GET "https://management.azure.com${Id}?api-version=$Version"
    if ($response.status -ne 200) { throw 'lifecycle.web.resourceUnavailable' }
    return [Text.Encoding]::UTF8.GetString($response.bytes) | ConvertFrom-Json -AsHashtable -Depth 50
}

function Get-WebDeliveryAzureCollection([hashtable] $Context, [string] $Id) {
    $uri = "https://management.azure.com${Id}?api-version=2024-03-01"; $seen = [Collections.Generic.HashSet[string]]::new(); $items = [Collections.Generic.List[object]]::new()
    while ($uri) {
        $address = [uri] $uri
        if ($address.Scheme -cne 'https' -or $address.Host -cne 'management.azure.com' -or $address.Port -ne 443 -or $address.UserInfo -or $address.Fragment -or
            $address.AbsolutePath -ine $Id -or -not $seen.Add($uri) -or $seen.Count -gt 20) { throw 'lifecycle.web.collectionPageInvalid' }
        $response = Invoke-AzureLifecycleHttp $Context GET $uri
        if ($response.status -ne 200) { throw 'lifecycle.web.collectionUnavailable' }
        $page = [Text.Encoding]::UTF8.GetString($response.bytes) | ConvertFrom-Json -AsHashtable -Depth 40
        if (-not $page.ContainsKey('value') -or $page.value -isnot [Collections.IList]) { throw 'lifecycle.web.collectionIncomplete' }
        foreach ($item in $page.value) { $items.Add($item); if ($items.Count -gt 1000) { throw 'lifecycle.web.collectionTooLarge' } }
        $uri = $(if ($page.ContainsKey('nextLink')) { [string] $page.nextLink } else { '' })
    }
    return $items.ToArray()
}

function Get-AzureWebTarget([hashtable] $Context, [hashtable] $Hosting) {
    $web = $Hosting.state.outputs.web
    if (@($Hosting.state.resources | Where-Object { $_.type -ceq 'azurerm_static_web_app' -and $_.id -ieq $web.id }).Count -ne 1 -or
        -not $web.id.StartsWith("$($Hosting.state.scopeId)/providers/Microsoft.Web/staticSites/", [StringComparison]::OrdinalIgnoreCase)) { throw 'lifecycle.web.siteUnrecorded' }
    $actual = Get-WebDeliveryAzureObject $Context $web.id '2023-12-01'
    if ($actual.id -ine $web.id -or $actual.properties.defaultHostname -cnotmatch '^[a-z0-9-]+[.](?:[a-z0-9-]+[.])?azurestaticapps[.]net$' -or
        $web.url -cne "https://$($actual.properties.defaultHostname)") { throw 'lifecycle.web.siteEndpointChanged' }
    return @{ id = $web.id; origin = $web.url }
}

function Assert-AzureWorkloadTemplate([hashtable] $Template, [hashtable] $Configuration, [hashtable] $Workload, [hashtable] $Identity, [hashtable] $Outputs, [hashtable] $Inputs) {
    if ($Template.containers.Count -ne 1 -or ($Template.ContainsKey('initContainers') -and $null -ne $Template.initContainers -and @($Template.initContainers).Count -gt 0)) { throw 'lifecycle.web.workloadTemplateChanged' }
    $container = $Template.containers[0]
    if ($container.name -cne 'application' -or $container.image -cne $Workload.image -or
        ($container.ContainsKey('command') -and $null -ne $container.command -and @($container.command).Count -gt 0) -or ($container.ContainsKey('args') -and $null -ne $container.args -and @($container.args).Count -gt 0)) { throw 'lifecycle.web.workloadImageChanged' }
    $expected = @{} + $Workload.environment
    $expected.ASPNETCORE_ENVIRONMENT = 'Production'; $expected.HTTP_PORTS = $Workload.http_ports -join ';'; $expected.AZURE_CLIENT_ID = $Identity.client_id
    $expected["ConnectionStrings__$($Inputs.database_connection_name)"] = "Host=$($Outputs.database_bootstrap.host);Database=$($Outputs.database_bootstrap.database);Username=$($Identity.database_role);SSL Mode=VerifyFull"
    if ($Workload.kind -ceq 'api') {
        $expected.Auth__Authority = $Inputs.auth.authority; $expected.Auth__Audience = $Inputs.auth.audience; $expected.Auth__ApiScope = $Inputs.auth.api_scope; $expected.AllowedOrigins = $Outputs.web.url
    }
    $actual = @{}; $references = @{}
    foreach ($item in $container.env) {
        if ($actual.ContainsKey($item.name) -or $references.ContainsKey($item.name)) { throw 'lifecycle.web.workloadBindingsChanged' }
        if ($item.ContainsKey('secretRef') -and $item.secretRef) { $references[$item.name] = $item.secretRef }
        else { $actual[$item.name] = [string] $item.value }
    }
    if ((Get-SnapshotHash $actual) -cne (Get-SnapshotHash $expected) -or $references.Count -ne $Workload.secret_references.Count) { throw 'lifecycle.web.workloadBindingsChanged' }
    foreach ($key in $Workload.secret_references.Keys) {
        $suffix = [Convert]::ToHexString([Security.Cryptography.SHA1]::HashData([Text.Encoding]::UTF8.GetBytes($key))).ToLowerInvariant().Substring(0, 12)
        $name = "secret-$suffix"; $secret = @($Configuration.secrets | Where-Object name -CEQ $name)
        if (-not $references.ContainsKey($key) -or $references[$key] -cne $name -or $secret.Count -ne 1 -or
            $secret[0].keyVaultUrl -cne $Workload.secret_references[$key].secret_uri -or $secret[0].identity -ine $Identity.id -or
            ($secret[0].ContainsKey('value') -and $secret[0].value)) { throw 'lifecycle.web.secretReferenceChanged' }
    }
    foreach ($pair in @(@('Startup', '/health/ready'), @('Readiness', '/health/ready'), @('Liveness', '/health/alive'))) {
        $probe = @($container.probes | Where-Object type -CEQ $pair[0])
        if ($probe.Count -ne 1 -or $probe[0].httpGet.port -ne 8081 -or $probe[0].httpGet.path -cne $pair[1] -or
            ($probe[0].httpGet.ContainsKey('scheme') -and $probe[0].httpGet.scheme -cne 'HTTP')) { throw 'lifecycle.web.healthProbeChanged' }
    }
}

function Get-AzureBackendHealth([hashtable] $Context, [hashtable] $Hosting) {
    $facts = @(); $outputs = $Hosting.state.outputs; $inputs = $Hosting.inputs
    $ownedApps = @($Hosting.state.resources | Where-Object type -CEQ 'azurerm_container_app')
    if ($ownedApps.Count -ne $inputs.workloads.Count) { throw 'lifecycle.web.workloadsUnrecorded' }
    foreach ($id in @($inputs.workloads.Keys | Sort-Object)) {
        Assert-AzureLifecycleLease $Context
        $workload = $inputs.workloads[$id]; $appId = "$($Hosting.state.scopeId)/providers/Microsoft.App/containerApps/$($workload.name)"
        if (@($ownedApps | Where-Object id -IEQ $appId).Count -ne 1) { throw 'lifecycle.web.workloadUnrecorded' }
        $app = Get-WebDeliveryAzureObject $Context $appId
        $properties = $app.properties; $revision = [string] $properties.latestRevisionName
        if ($app.id -ine $appId -or $properties.provisioningState -cne 'Succeeded' -or $properties.configuration.activeRevisionsMode -cne 'Single' -or
            $revision -cnotmatch '^[a-z0-9-]+$' -or $properties.latestReadyRevisionName -cne $revision -or
            $app.identity.type -cne 'UserAssigned' -or $app.identity.userAssignedIdentities.Count -ne 1 -or -not $app.identity.userAssignedIdentities.ContainsKey($outputs.workload_identities[$id].id)) { throw 'lifecycle.web.workloadNotReady' }
        Assert-AzureWorkloadTemplate $properties.template $properties.configuration $workload $outputs.workload_identities[$id] $outputs $inputs
        $ingress = $(if ($properties.configuration.ContainsKey('ingress')) { $properties.configuration.ingress } else { $null })
        if ($workload.kind -ceq 'api') {
            if ($null -eq $ingress -or $ingress.external -ne $true -or $ingress.allowInsecure -ne $false -or $ingress.targetPort -ne 8080 -or $ingress.traffic.Count -ne 1 -or
                $ingress.traffic[0].weight -ne 100 -or -not (($ingress.traffic[0].ContainsKey('latestRevision') -and $ingress.traffic[0].latestRevision -eq $true) -or ($ingress.traffic[0].ContainsKey('revisionName') -and $ingress.traffic[0].revisionName -ceq $revision)) -or
                $ingress.fqdn -cnotmatch '^[a-z0-9.-]+[.]azurecontainerapps[.]io$' -or $outputs.api_url -cne "https://$($ingress.fqdn)/api/v1") { throw 'lifecycle.web.apiIngressChanged' }
        }
        elseif ($null -ne $ingress) { throw 'lifecycle.web.workerIngressExposed' }
        $revisionId = "$appId/revisions/$revision"; $observed = Get-WebDeliveryAzureObject $Context $revisionId
        if ($observed.id -ine $revisionId -or $observed.properties.active -ne $true -or $observed.properties.healthState -cne 'Healthy' -or
            $observed.properties.provisioningState -cne 'Provisioned' -or $observed.properties.runningState -cne 'Running') { throw 'lifecycle.web.revisionNotHealthy' }
        Assert-AzureWorkloadTemplate $observed.properties.template $properties.configuration $workload $outputs.workload_identities[$id] $outputs $inputs
        $replicas = @(Get-WebDeliveryAzureCollection $Context "$revisionId/replicas")
        $ready = @($replicas | Where-Object {
            $_.properties.runningState -ceq 'Running' -and @($_.properties.containers | Where-Object { $_.name -ceq 'application' -and $_.ready -eq $true -and $_.started -eq $true -and $_.runningState -ceq 'Running' }).Count -eq 1
        })
        if ($workload.min_replicas -lt 1 -or $ready.Count -lt $workload.min_replicas) { throw 'lifecycle.web.replicasNotReady' }
        $facts += @{ workloadId = $id; appId = $appId; revisionId = $revisionId; image = $workload.image; readyReplicas = $ready.Count }
    }
    return ,$facts
}

function New-AzureWebPayload([hashtable] $Context, [hashtable] $Delivery, [hashtable] $Release, [hashtable] $Hosting, [string] $DeliverySha256) {
    $renew = (Get-Command Assert-AzureLifecycleLease).ScriptBlock; $heartbeat = { & $renew $Context }.GetNewClosure()
    $candidates = Receive-ApplicationCandidates $Delivery $Release $Hosting.registry.login_server (Join-Path $Context.runtime "web-candidate-$([guid]::NewGuid().ToString('N'))") $heartbeat -ComponentNames web -Confirm:$false
    $source = @($Release.sources | Where-Object name -CEQ 'web')[0]
    $previousToken = $env:GH_TOKEN
    try {
        if ($env:HEXAGON_APPLICATIONS_READ_TOKEN) { $env:GH_TOKEN = $env:HEXAGON_APPLICATIONS_READ_TOKEN }
        $manifest = Get-ValidatedApplicationManifest -Repository $source.repository -Commit $source.commit -Path '.hexagon/frontend-hosting-requirements.json' -ExpectedProduct $Release.product -ExpectedComponent web
    }
    catch { throw 'lifecycle.web.sourceManifestUnavailable' }
    finally { $env:GH_TOKEN = $previousToken }
    if (@($source.manifests | Where-Object { $_.path -ceq '.hexagon/frontend-hosting-requirements.json' -and $_.sha256 -ceq $manifest.Sha256 }).Count -ne 1) { throw 'lifecycle.web.manifestMismatch' }
    $outputs = @{ api_url = @{ value = $Hosting.state.outputs.api_url }; frontend_authentication = @{ value = $Hosting.state.outputs.frontend_authentication } }
    $artifact = $candidates.web.build.artifacts[0]
    return New-StaticWebPayload (Join-Path $candidates.web.directory $artifact.file) $Release.artifacts.web.sha256 $manifest.Manifest $outputs $Context.inventory.releaseSha256 $DeliverySha256 (Join-Path $Context.runtime "spa-$([guid]::NewGuid().ToString('N'))") -Confirm:$false
}

function Publish-AzureWebPayload {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([hashtable] $Context, [hashtable] $Target, [hashtable] $Payload)
    if (-not $PSCmdlet.ShouldProcess($Target.id, 'Publish the prebuilt SPA to the isolated site primary slot')) { return }
    $root = @($Context.inventory.roots | Where-Object id -CEQ 'hosting')[0]
    $prefix = "/subscriptions/$($Context.inventory.target.subscriptionId)/resourceGroups/$($root.resourceGroup)/providers/Microsoft.Web/staticSites/"
    if (-not $Target.id.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or $Target.id.Substring($prefix.Length) -cnotmatch '^[a-z0-9-]+$' -or
        @($root.resources | Where-Object { $_.id -ieq $Target.id -and $_.type -ceq 'azurerm_static_web_app' -and $_.current }).Count -ne 1) { throw 'lifecycle.web.siteUnrecorded' }
    Assert-StaticWebPayload $Payload; Get-StaticWebClientPath | Out-Null; Assert-AzureLifecycleLease $Context
    $result = Invoke-LifecycleCommand az @('rest', '--method', 'post', '--url', "https://management.azure.com$($Target.id)/listSecrets?api-version=2023-12-01", '--subscription', $Context.inventory.target.subscriptionId, '--output', 'json', '--only-show-errors') -TimeoutSeconds 45
    if ($result.exitCode -ne 0) { throw 'lifecycle.web.deploymentCredentialUnavailable' }
    $value = $result.text | ConvertFrom-Json -AsHashtable
    if (-not $value.properties.apiKey -or $value.properties.apiKey -match '\s' -or $value.properties.apiKey.Length -gt 4096) { throw 'lifecycle.web.deploymentCredentialInvalid' }
    $directory = [IO.Path]::GetFullPath($Context.runtime)
    if ([IO.Path]::GetDirectoryName($Payload.directory) -cne $directory) { throw 'lifecycle.web.payloadDirectoryInvalid' }
    # Client scratch archives belong to the private repository base, outside the public asset tree.
    $environment = @{ DEPLOYMENT_ACTION = 'upload'; DEPLOYMENT_PROVIDER = 'SwaCli'; REPOSITORY_BASE = $directory; APP_LOCATION = $Payload.directory
        SKIP_APP_BUILD = 'true'; SKIP_API_BUILD = 'true'; API_LOCATION = ''; DATA_API_LOCATION = ''; CONFIG_FILE_LOCATION = $Payload.directory; DEPLOYMENT_TOKEN = $value.properties.apiKey; VERBOSE = 'false' }
    $renew = (Get-Command Assert-AzureLifecycleLease).ScriptBlock; $heartbeat = { & $renew $Context }.GetNewClosure()
    Assert-AzureLifecycleLease $Context
    $result = Invoke-LifecycleCommand static-web-client @() $directory -Environment $environment -TimeoutSeconds 1200 -Heartbeat $heartbeat
    if ($result.exitCode -ne 0) { throw 'lifecycle.web.publicationUncertain' }
    Assert-StaticWebPayload $Payload
}

Export-ModuleMember -Function Get-AzureWebTarget, Get-AzureBackendHealth, Assert-AzureWorkloadTemplate, New-AzureWebPayload, Publish-AzureWebPayload
