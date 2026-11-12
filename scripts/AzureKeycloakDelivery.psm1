Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AzureMaintenanceDelivery.psm1')
Import-Module (Join-Path $PSScriptRoot 'EnvironmentSnapshot.psm1')

function Test-IntegratedKeycloak([hashtable] $Inputs) {
    return $Inputs.ContainsKey('keycloak') -and $null -ne $Inputs.keycloak
}

function Get-AzureHostingAuthority([hashtable] $Inputs, [hashtable] $Outputs) {
    if (-not (Test-IntegratedKeycloak $Inputs)) { return $Inputs.auth.authority }
    if (-not $Outputs.ContainsKey('keycloak') -or $null -eq $Outputs.keycloak -or
        $Outputs.keycloak.origin -cnotmatch "^https://$([regex]::Escape($Inputs.name_prefix))-auth[.][a-z0-9.-]+[.]azurecontainerapps[.]io$" -or
        $Outputs.keycloak.role -cne "$($Inputs.name_prefix)-keycloak" -or
        $Outputs.keycloak.authority -cne "$($Outputs.keycloak.origin)/realms/$($Inputs.keycloak.realm)" -or
        $Outputs.frontend_authentication.authority -cne $Outputs.keycloak.authority) { throw 'lifecycle.identity.bindingChanged' }
    return $Outputs.keycloak.authority
}

function Assert-AzureKeycloakDiscovery([string] $Authority) {
    $handler = [Net.Http.HttpClientHandler]::new(); $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler); $client.Timeout = [TimeSpan]::FromSeconds(30)
    try {
        try { $response = $client.GetAsync("$Authority/.well-known/openid-configuration").GetAwaiter().GetResult() }
        catch { throw 'lifecycle.identity.discoveryUnavailable' }
        try {
            if ([int] $response.StatusCode -ne 200) { throw 'lifecycle.identity.discoveryUnavailable' }
            $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
            if ($bytes.Length -gt 1MB) { throw 'lifecycle.identity.discoveryInvalid' }
            try { $document = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -AsHashtable -Depth 16 }
            catch { throw 'lifecycle.identity.discoveryInvalid' }
            Assert-AzureKeycloakDocument $Authority $document
        }
        finally { $response.Dispose() }
    }
    finally { $client.Dispose(); $handler.Dispose() }
}

function Assert-AzureKeycloakDocument([string] $Authority, [hashtable] $Document) {
    foreach ($key in @('issuer', 'authorization_endpoint', 'token_endpoint', 'jwks_uri', 'code_challenge_methods_supported')) {
        if (-not $Document.ContainsKey($key)) { throw 'lifecycle.identity.discoveryInvalid' }
    }
    if ($Document.issuer -cne $Authority -or
        $Document.authorization_endpoint -cne "$Authority/protocol/openid-connect/auth" -or
        $Document.token_endpoint -cne "$Authority/protocol/openid-connect/token" -or
        $Document.jwks_uri -cne "$Authority/protocol/openid-connect/certs" -or
        $Document.code_challenge_methods_supported -cnotcontains 'S256') { throw 'lifecycle.identity.discoveryInvalid' }
}

function Assert-AzureIntegratedIdentityReady([hashtable] $Context, [hashtable] $Hosting) {
    $inputs = $Hosting.inputs
    if (-not (Test-IntegratedKeycloak $inputs)) { return }
    $outputs = $Hosting.state.outputs
    $authority = Get-AzureHostingAuthority $inputs $outputs
    $id = "$($Hosting.state.scopeId)/providers/Microsoft.App/containerApps/$($inputs.name_prefix)-auth"
    if (-not $inputs.keycloak_rollout_enabled -or $outputs.keycloak.id -ine $id -or
        @($Hosting.state.resources | Where-Object { $_.type -ceq 'azurerm_container_app' -and $_.id -ieq $id }).Count -ne 1) { throw 'lifecycle.identity.rolloutRequired' }
    $app = Get-DeliveryAzureObject $Context $id
    if ($app.id -ine $id -or $app.identity.type -cne 'UserAssigned' -or
        $app.identity.userAssignedIdentities.Count -ne 1 -or -not $app.identity.userAssignedIdentities.ContainsKey($outputs.keycloak.identity) -or
        $app.properties.provisioningState -cne 'Succeeded' -or
        -not $app.properties.latestRevisionName -or $app.properties.latestRevisionName -cne $app.properties.latestReadyRevisionName -or
        $app.properties.configuration.activeRevisionsMode -cne 'Single' -or
        $app.properties.configuration.ingress.external -ne $true -or $app.properties.configuration.ingress.allowInsecure -ne $false -or
        $app.properties.configuration.ingress.targetPort -ne 8080 -or
        $app.properties.configuration.ingress.traffic.Count -ne 1 -or
        $app.properties.configuration.ingress.traffic[0].weight -ne 100 -or
        -not (($app.properties.configuration.ingress.traffic[0].ContainsKey('latestRevision') -and $app.properties.configuration.ingress.traffic[0].latestRevision -eq $true) -or
            ($app.properties.configuration.ingress.traffic[0].ContainsKey('revisionName') -and $app.properties.configuration.ingress.traffic[0].revisionName -ceq $app.properties.latestRevisionName)) -or
        ($app.properties.configuration.ingress.ContainsKey('additionalPortMappings') -and $null -ne $app.properties.configuration.ingress.additionalPortMappings -and @($app.properties.configuration.ingress.additionalPortMappings).Count -gt 0) -or
        "https://$($app.properties.configuration.ingress.fqdn)" -cne $outputs.keycloak.origin -or
        $app.properties.template.containers.Count -ne 1) { throw 'lifecycle.identity.runtimeChanged' }
    $container = $app.properties.template.containers[0]
    if ($container.name -cne 'keycloak' -or $container.image -cne $inputs.keycloak.image -or
        ($container.args -join ',') -cne 'start' -or
        ($container.ContainsKey('command') -and $null -ne $container.command -and @($container.command).Count) -or
        ($container.ContainsKey('volumeMounts') -and $null -ne $container.volumeMounts -and @($container.volumeMounts).Count) -or
        ($app.properties.template.ContainsKey('initContainers') -and $null -ne $app.properties.template.initContainers -and @($app.properties.template.initContainers).Count) -or
        $container.resources.cpu -ne 0.5 -or $container.resources.memory -cne '1Gi' -or
        $app.properties.template.scale.minReplicas -ne 1 -or $app.properties.template.scale.maxReplicas -ne 1) { throw 'lifecycle.identity.runtimeChanged' }
    $expected = @{
        KC_DB = 'postgres'; KC_DB_SCHEMA = 'keycloak'; KC_DB_USERNAME = $outputs.keycloak.role
        KC_DB_URL = "jdbc:postgresql://$($outputs.database_bootstrap.host):5432/$($outputs.database_bootstrap.database)?sslmode=verify-full&sslfactory=org.postgresql.ssl.DefaultJavaSSLFactory"
        KC_DB_POOL_INITIAL_SIZE = '1'; KC_DB_POOL_MIN_SIZE = '1'; KC_DB_POOL_MAX_SIZE = '5'
        KC_HOSTNAME = $outputs.keycloak.origin; KC_HOSTNAME_STRICT = 'true'; KC_PROXY_HEADERS = 'xforwarded'
        KC_HTTP_ENABLED = 'true'; KC_HEALTH_ENABLED = 'true'; KC_CACHE = 'local'; KC_BOOTSTRAP_ADMIN_USERNAME = $inputs.keycloak.bootstrap_user
        KC_DB_PASSWORD = @{ secretRef = 'database' }; KC_BOOTSTRAP_ADMIN_PASSWORD = @{ secretRef = 'bootstrap' }
    }
    $actual = @{}
    foreach ($env in $container.env) {
        if ($actual.ContainsKey($env.name)) { throw 'lifecycle.identity.runtimeChanged' }
        if ($env.ContainsKey('secretRef') -and $env.secretRef -and $env.ContainsKey('value') -and $env.value) { throw 'lifecycle.identity.runtimeChanged' }
        $actual[$env.name] = $(if ($env.ContainsKey('secretRef') -and $env.secretRef) { @{ secretRef = $env.secretRef } } else { $env.value })
    }
    if ((Get-SnapshotHash $actual) -cne (Get-SnapshotHash $expected)) { throw 'lifecycle.identity.runtimeChanged' }
    $secrets = @{ database = $inputs.keycloak.database_password; bootstrap = $inputs.keycloak.bootstrap_password }
    if ($app.properties.configuration.secrets.Count -ne 2) { throw 'lifecycle.identity.secretReferenceChanged' }
    foreach ($key in $secrets.Keys) {
        $entry = @($app.properties.configuration.secrets | Where-Object name -CEQ $key)
        if ($entry.Count -ne 1 -or $entry[0].keyVaultUrl -cne $secrets[$key].secret_uri -or $entry[0].identity -ine $outputs.keycloak.identity -or
            ($entry[0].ContainsKey('value') -and $entry[0].value)) { throw 'lifecycle.identity.secretReferenceChanged' }
    }
    if ($container.probes.Count -ne 3) { throw 'lifecycle.identity.runtimeChanged' }
    foreach ($probe in @{ Startup = '/health/ready'; Readiness = '/health/ready'; Liveness = '/health/live' }.GetEnumerator()) {
        $matching = @($container.probes | Where-Object type -CEQ $probe.Key)
        if ($matching.Count -ne 1 -or $matching[0].httpGet.port -ne 9000 -or $matching[0].httpGet.path -cne $probe.Value -or
            ($matching[0].httpGet.ContainsKey('scheme') -and $matching[0].httpGet.scheme -cne 'HTTP')) { throw 'lifecycle.identity.runtimeChanged' }
    }
    Assert-AzureKeycloakDiscovery $authority
}

Export-ModuleMember -Function Test-IntegratedKeycloak, Get-AzureHostingAuthority, Assert-AzureIntegratedIdentityReady
