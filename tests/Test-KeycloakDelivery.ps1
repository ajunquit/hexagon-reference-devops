Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../scripts/AzureKeycloakDelivery.psm1') -Force
$module = Get-Module AzureKeycloakDelivery
$maintenance = Get-Module -All AzureMaintenanceDelivery | Select-Object -First 1

function Copy-Value($Value) { return ($Value | ConvertTo-Json -Depth 40) | ConvertFrom-Json -AsHashtable -Depth 40 }
function Assert-Rejected([scriptblock] $Action, [string] $Code) {
    try { & $Action; throw 'The unsafe identity fixture was accepted.' }
    catch { if ($_.Exception.Message -cnotlike "*$Code*") { throw } }
}

$scope = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-example-dev'
$origin = 'https://example-dev-auth.example.eastus2.azurecontainerapps.io'
$authority = "$origin/realms/hexagon"
$id = "$scope/providers/Microsoft.App/containerApps/example-dev-auth"
$identity = "$scope/providers/Microsoft.ManagedIdentity/userAssignedIdentities/example-dev-keycloak"
$inputs = @{
    name_prefix = 'example-dev'; keycloak_rollout_enabled = $true
    keycloak = @{
        realm = 'hexagon'; image = "quay.io/keycloak/keycloak@sha256:$('a' * 64)"; bootstrap_user = 'bootstrap'
        database_password = @{ secret_uri = "https://examplevault.vault.azure.net/secrets/kc-database/$('1' * 32)" }
        bootstrap_password = @{ secret_uri = "https://examplevault.vault.azure.net/secrets/kc-bootstrap/$('2' * 32)" }
    }
    auth = @{ authority = $null }
}
$outputs = @{
    keycloak = @{ id = $id; origin = $origin; authority = $authority; role = 'example-dev-keycloak'; identity = $identity }
    frontend_authentication = @{ authority = $authority }
    database_bootstrap = @{ host = 'example-dev-postgres.postgres.database.azure.com'; database = 'product' }
}
$hosting = @{ inputs = $inputs; state = @{ scopeId = $scope; outputs = $outputs; resources = @(@{ type = 'azurerm_container_app'; id = $id }) } }
$environment = @{
    KC_DB = 'postgres'; KC_DB_SCHEMA = 'keycloak'; KC_DB_USERNAME = 'example-dev-keycloak'
    KC_DB_URL = 'jdbc:postgresql://example-dev-postgres.postgres.database.azure.com:5432/product?sslmode=verify-full&sslfactory=org.postgresql.ssl.DefaultJavaSSLFactory'
    KC_DB_POOL_INITIAL_SIZE = '1'; KC_DB_POOL_MIN_SIZE = '1'; KC_DB_POOL_MAX_SIZE = '5'
    KC_HOSTNAME = $origin; KC_HOSTNAME_STRICT = 'true'; KC_PROXY_HEADERS = 'xforwarded'
    KC_HTTP_ENABLED = 'true'; KC_HEALTH_ENABLED = 'true'; KC_CACHE = 'local'; KC_BOOTSTRAP_ADMIN_USERNAME = 'bootstrap'
}
$envs = @($environment.Keys | ForEach-Object { @{ name = $_; value = $environment[$_] } }) + @(
    @{ name = 'KC_DB_PASSWORD'; secretRef = 'database' }, @{ name = 'KC_BOOTSTRAP_ADMIN_PASSWORD'; secretRef = 'bootstrap' })
$app = @{
    id = $id; identity = @{ type = 'UserAssigned'; userAssignedIdentities = @{ $identity = @{} } }
    properties = @{
        provisioningState = 'Succeeded'; latestRevisionName = 'revision'; latestReadyRevisionName = 'revision'
        configuration = @{
            activeRevisionsMode = 'Single'
            ingress = @{ external = $true; allowInsecure = $false; targetPort = 8080; fqdn = $origin.Substring(8); traffic = @(@{ weight = 100; latestRevision = $true }) }
            secrets = @(@{ name = 'database'; keyVaultUrl = $inputs.keycloak.database_password.secret_uri; identity = $identity },
                @{ name = 'bootstrap'; keyVaultUrl = $inputs.keycloak.bootstrap_password.secret_uri; identity = $identity })
        }
        template = @{ scale = @{ minReplicas = 1; maxReplicas = 1 }; containers = @(@{
            name = 'keycloak'; image = $inputs.keycloak.image; args = @('start'); resources = @{ cpu = 0.5; memory = '1Gi' }; env = $envs
            probes = @(@{ type = 'Startup'; httpGet = @{ port = 9000; path = '/health/ready' } },
                @{ type = 'Readiness'; httpGet = @{ port = 9000; path = '/health/ready' } },
                @{ type = 'Liveness'; httpGet = @{ port = 9000; path = '/health/live' } })
        }) }
    }
}
$fixture = @{ app = $app; discovery = $null }
& $module { param($fixture) $script:fixture = $fixture
    function script:Get-DeliveryAzureObject { return $script:fixture.app }
    function script:Assert-AzureKeycloakDiscovery { param($authority) $script:fixture.discovery = $authority }
} $fixture
Assert-AzureIntegratedIdentityReady @{} $hosting
if ($fixture.discovery -cne $authority) { throw 'The exact integrated issuer was not checked.' }
$fixture.app = Copy-Value $app
$fixture.app.properties.configuration.ingress.additionalPortMappings = $null
$fixture.app.properties.template.initContainers = $null
$fixture.app.properties.template.containers[0].command = $null
$fixture.app.properties.template.containers[0].volumeMounts = $null
Assert-AzureIntegratedIdentityReady @{} $hosting
$bad = Copy-Value $hosting; $bad.inputs.keycloak_rollout_enabled = $false
Assert-Rejected { Assert-AzureIntegratedIdentityReady @{} $bad } 'rolloutRequired'
$bad = Copy-Value $hosting; $bad.state.outputs.keycloak.role = 'maintenance'
Assert-Rejected { Assert-AzureIntegratedIdentityReady @{} $bad } 'bindingChanged'
$fixture.app = Copy-Value $app; $fixture.app.properties.latestReadyRevisionName = 'old-revision'
Assert-Rejected { Assert-AzureIntegratedIdentityReady @{} $hosting } 'runtimeChanged'
$fixture.app = Copy-Value $app; $fixture.app.properties.configuration.ingress.traffic = @(@{ weight = 100; revisionName = 'old-revision' })
Assert-Rejected { Assert-AzureIntegratedIdentityReady @{} $hosting } 'runtimeChanged'
$fixture.app = Copy-Value $app; $fixture.app.properties.template.containers[0].image = 'mutable:latest'
Assert-Rejected { Assert-AzureIntegratedIdentityReady @{} $hosting } 'runtimeChanged'
$fixture.app = Copy-Value $app; $fixture.app.properties.configuration.ingress.additionalPortMappings = @(@{ exposedPort = 9000 })
Assert-Rejected { Assert-AzureIntegratedIdentityReady @{} $hosting } 'runtimeChanged'
$fixture.app = Copy-Value $app; $fixture.app.properties.configuration.secrets[0].value = 'forbidden'
Assert-Rejected { Assert-AzureIntegratedIdentityReady @{} $hosting } 'secretReferenceChanged'
$fixture.app = Copy-Value $app; $fixture.app.properties.template.containers[0].probes[0].httpGet.port = 8080
Assert-Rejected { Assert-AzureIntegratedIdentityReady @{} $hosting } 'runtimeChanged'
$fixture.app = Copy-Value $app; ($fixture.app.properties.template.containers[0].env | Where-Object name -CEQ 'KC_DB_USERNAME').value = 'maintenance'
Assert-Rejected { Assert-AzureIntegratedIdentityReady @{} $hosting } 'runtimeChanged'

$document = @{ issuer = $authority; authorization_endpoint = "$authority/protocol/openid-connect/auth";
    token_endpoint = "$authority/protocol/openid-connect/token"; jwks_uri = "$authority/protocol/openid-connect/certs"; code_challenge_methods_supported = @('S256') }
& $module { param($authority, $document) Assert-AzureKeycloakDocument $authority $document } $authority $document
$bad = Copy-Value $document; $bad.issuer = 'https://other.example/realms/hexagon'
Assert-Rejected { & $module { param($authority, $document) Assert-AzureKeycloakDocument $authority $document } $authority $bad } 'discoveryInvalid'
$bad = Copy-Value $document; $bad.code_challenge_methods_supported = @('plain')
Assert-Rejected { & $module { param($authority, $document) Assert-AzureKeycloakDocument $authority $document } $authority $bad } 'discoveryInvalid'

$template = @{ containers = @(@{ name = 'maintenance'; image = 'example.azurecr.io/bootstrap@sha256:fixture'; args = @('--prepare-keycloak'); resources = @{ cpu = 0.5; memory = '1Gi' };
    env = @(@{ name = 'PUBLIC'; value = 'settings' }, @{ name = 'PASSWORD'; secretRef = 'versioned-reference' }) }) }
$expected = @{ name = 'maintenance'; image = 'example.azurecr.io/bootstrap@sha256:fixture'; args = @('--prepare-keycloak'); cpu = 0.5; memory = '1Gi';
    environment = @{ PUBLIC = 'settings'; PASSWORD = @{ secretRef = 'versioned-reference' } } }
& $maintenance { param($template, $expected) Assert-DeliveryJobTemplate $template $expected '' } $template $expected
$bad = Copy-Value $template; $bad.containers[0].env[1].secretRef = 'other-reference'
Assert-Rejected { & $maintenance { param($template, $expected) Assert-DeliveryJobTemplate $template $expected '' } $bad $expected } 'jobTemplateChanged'
$bad = Copy-Value $template; $bad.containers[0].env[1].value = 'plaintext'
Assert-Rejected { & $maintenance { param($template, $expected) Assert-DeliveryJobTemplate $template $expected '' } $bad $expected } 'jobEnvironmentInvalid'

# Bind the actual parent job, identity and versioned credential before constructing a start request.
Import-Module (Join-Path $PSScriptRoot '../scripts/AzureApplicationDelivery.psm1')
$deliveryModule = Get-Module AzureApplicationDelivery
$maintenanceId = "$scope/providers/Microsoft.ManagedIdentity/userAssignedIdentities/example-dev-maintenance"
$jobId = "$scope/providers/Microsoft.App/jobs/example-dev-kc-database"
$clientId = '00000000-0000-0000-0000-000000000002'
$outputs.database_bootstrap.administrator = 'example-dev-maintenance'
$outputs.database_bootstrap.clientId = $clientId
$outputs.database_bootstrap.workloads = @{ api = @{ objectId = '00000000-0000-0000-0000-000000000003'; readDirectory = $true } }
$outputs.maintenance_jobs = @{ 'keycloak-database' = @{ id = $jobId } }
$hosting.inputs.bootstrap_image = "example.azurecr.io/database-bootstrap@sha256:$('b' * 64)"
$hosting.state.resources += @(@{ type = 'azurerm_container_app_job'; id = $jobId }, @{ type = 'azurerm_user_assigned_identity'; id = $maintenanceId })
$bootstrap = @{} + $outputs.database_bootstrap; $bootstrap.purpose = 'keycloak'
$parent = @{
    identity = @{ type = 'UserAssigned'; userAssignedIdentities = @{ $maintenanceId = @{} } }
    properties = @{
        configuration = @{ secrets = @(@{ name = 'keycloak-database-password'; keyVaultUrl = $inputs.keycloak.database_password.secret_uri; identity = $maintenanceId }) }
        template = @{ containers = @(@{
            name = 'maintenance'; image = $hosting.inputs.bootstrap_image; args = @('--prepare-keycloak'); resources = @{ cpu = 0.5; memory = '1Gi' }
            env = @(@{ name = 'HEXAGON_DATABASE_BOOTSTRAP'; value = ($bootstrap | ConvertTo-Json -Depth 20 -Compress) },
                @{ name = 'HEXAGON_KEYCLOAK_DATABASE'; value = '{"role":"example-dev-keycloak"}' },
                @{ name = 'HEXAGON_KEYCLOAK_DATABASE_PASSWORD'; secretRef = 'keycloak-database-password' })
        }) }
    }
}
$jobFixture = @{ job = $parent; jobId = $jobId; identityId = $maintenanceId; clientId = $clientId }
& $deliveryModule { param($fixture) $script:identityJobFixture = $fixture
    function script:Invoke-AzureLifecycleHttp {
        param($context, $method, $uri)
        if ($method -cne 'GET') { throw 'Identity specification verification attempted a write.' }
        if ($uri -ceq "https://management.azure.com$($script:identityJobFixture.jobId)?api-version=2024-03-01") { $value = $script:identityJobFixture.job }
        elseif ($uri -ceq "https://management.azure.com$($script:identityJobFixture.identityId)?api-version=2023-01-31") { $value = @{ properties = @{ clientId = $script:identityJobFixture.clientId } } }
        else { throw 'Unexpected identity specification target.' }
        return @{ status = 200; bytes = [Text.Encoding]::UTF8.GetBytes(($value | ConvertTo-Json -Depth 40 -Compress)) }
    }
} $jobFixture
$spec = & $deliveryModule { param($hosting) Get-AzureDeliveryJobSpec @{} $hosting keycloak-database } $hosting
& $maintenance { param($template, $expected) Assert-DeliveryJobTemplate $template $expected '' } $parent.properties.template $spec.expected
if ($spec.expected.environment.HEXAGON_KEYCLOAK_DATABASE_PASSWORD.secretRef -cne 'keycloak-database-password') { throw 'Identity credential reference was lost.' }
$jobFixture.job = Copy-Value $parent; $jobFixture.job.properties.configuration.secrets[0].keyVaultUrl = 'https://other.vault.azure.net/secrets/database'
Assert-Rejected { & $deliveryModule { param($hosting) Get-AzureDeliveryJobSpec @{} $hosting keycloak-database } $hosting } 'secretReferenceChanged'
$jobFixture.job = Copy-Value $parent; $jobFixture.job.properties.template.containers[0].env[1].value = '{"role":"maintenance"}'
Assert-Rejected { & $deliveryModule { param($hosting) Get-AzureDeliveryJobSpec @{} $hosting keycloak-database } $hosting } 'bindingChanged'
Write-Host 'Integrated identity protocol checks passed: bindings, resource/revision ownership, secret references, issuer/PKCE and job templates; no cloud writes.'
