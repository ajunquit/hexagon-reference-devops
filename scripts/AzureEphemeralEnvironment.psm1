Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
foreach ($name in @('LifecycleNative', 'AzureEnvironmentStore', 'TerraformAzureLifecycle')) { Import-Module (Join-Path $PSScriptRoot "$name.psm1") }

# Azure side of the ephemeral reservation: definition, reservation plan, bootstrap storage and the isolation
# diagnostic. EphemeralEnvironment.psm1 discovers this module and calls the Ephemeral* contract functions
# inside it; the module exports only its own checks.

function Test-EphemeralCloudTarget([hashtable] $Target) { return $Target.ContainsKey('subscriptionId') -and -not $Target.ContainsKey('accountId') }

function Assert-EphemeralCloudDefinition([hashtable] $Definition) {
    $value = $Definition; $inventory = $Definition.inventory
    if ($inventory.instance.kind -cne 'Ephemeral' -or $inventory.environment -ceq 'prod' -or $inventory.dataPolicy -cne 'DeleteEphemeral' -or
        $inventory.target.container -cne "tfstate-$($inventory.instance.id)-$($inventory.environment)" -or $value.bootstrapContainer -ceq $inventory.target.container -or
        ($value.oidcPrefix -replace '^repo:', '' -replace '@[0-9]+', '') -cne $inventory.iac.repository -or
        "id-$($inventory.product)-$($inventory.environment)-$($inventory.instance.id)-deploy".Length -gt 128) { throw 'lifecycle.ephemeral.boundaryInvalid' }
    if ($value.protectedResourceGroups -cnotcontains $inventory.target.stateResourceGroup -or
        @($value.protectedResourceGroups | Where-Object { -not $_.StartsWith("rg-$($inventory.product)-", [StringComparison]::Ordinal) -or $_ -cin $inventory.roots.resourceGroup }).Count -gt 0) { throw 'lifecycle.ephemeral.protectedScopeInvalid' }
    foreach ($environment in @('dev', 'staging', 'prod')) {
        $prefix = "rg-$($inventory.product)-$environment"
        if (@($value.protectedResourceGroups | Where-Object { ($_ -ceq $prefix -or $_.StartsWith("$prefix-", [StringComparison]::Ordinal)) -and -not $_.StartsWith("$prefix-run-", [StringComparison]::Ordinal) }).Count -eq 0) { throw 'lifecycle.ephemeral.protectedScopeInvalid' }
    }
}

function Get-EphemeralCloudGithubBindings([hashtable] $Definition) {
    $target = $Definition.inventory.target
    return [ordered] @{ AZURE_CLIENT_ID = $target.clientId; AZURE_TENANT_ID = $target.tenantId; AZURE_SUBSCRIPTION_ID = $target.subscriptionId }
}

function Get-EphemeralCloudBootstrapRoot { return 'azure-ephemeral' }

function Get-EphemeralCloudProvider { return 'azurerm' }

function Get-EphemeralCloudTerraformEnvironment([hashtable] $Definition) {
    $target = $Definition.inventory.target
    return @{ ARM_USE_CLI = 'true'; ARM_USE_MSI = 'false'; ARM_USE_OIDC = 'false'; ARM_TENANT_ID = $target.tenantId; ARM_SUBSCRIPTION_ID = $target.subscriptionId }
}

# The operator of the subscription bootstrap: the right tenant and subscription.
function Assert-EphemeralCloudAccount([hashtable] $Definition) {
    $model = $Definition; $inventory = $Definition.inventory
    $account = Invoke-LifecycleCommand az @('account', 'show', '--output', 'json', '--only-show-errors') -TimeoutSeconds 45
    if ($account.exitCode -ne 0) { throw 'lifecycle.ephemeral.accountUnavailable' }
    $account = $account.text | ConvertFrom-Json -AsHashtable
    if ($account.tenantId -ine $inventory.target.tenantId -or $account.id -ine $inventory.target.subscriptionId -or $account.environmentName -cne 'AzureCloud' -or $account.state -cne 'Enabled') { throw 'lifecycle.ephemeral.accountMismatch' }
}

# The protected neighbours exist and the state storage keeps every version.
function Assert-EphemeralCloudState([hashtable] $Definition) {
    $model = $Definition; $inventory = $Definition.inventory
    foreach ($group in $model.protectedResourceGroups) {
        $response = Invoke-LifecycleCommand az @('group', 'show', '--name', $group, '--subscription', $inventory.target.subscriptionId, '--output', 'json', '--only-show-errors') -TimeoutSeconds 45
        if ($response.exitCode -ne 0) { throw 'lifecycle.ephemeral.protectedGroupUnavailable' }
        $metadata = $response.text | ConvertFrom-Json -AsHashtable
        if ($metadata.id -ine "/subscriptions/$($inventory.target.subscriptionId)/resourceGroups/$group" -or $metadata.tags.product -cne $inventory.product) { throw 'lifecycle.ephemeral.protectedGroupMismatch' }
    }
    $storage = Invoke-LifecycleCommand az @('storage', 'account', 'show', '--name', $inventory.target.storageAccount, '--resource-group', $inventory.target.stateResourceGroup, '--subscription', $inventory.target.subscriptionId, '--output', 'json', '--only-show-errors') -TimeoutSeconds 45
    $properties = Invoke-LifecycleCommand az @('storage', 'account', 'blob-service-properties', 'show', '--account-name', $inventory.target.storageAccount, '--resource-group', $inventory.target.stateResourceGroup, '--subscription', $inventory.target.subscriptionId, '--output', 'json', '--only-show-errors') -TimeoutSeconds 45
    if ($storage.exitCode -ne 0 -or $properties.exitCode -ne 0) { throw 'lifecycle.ephemeral.storageUnavailable' }
    Assert-AzureEphemeralBootstrapStorage $model ($storage.text | ConvertFrom-Json -AsHashtable) ($properties.text | ConvertFrom-Json -AsHashtable)
}

function Get-EphemeralCloudReservationFiles([hashtable] $Definition) {
    $model = $Definition; $inventory = $Definition.inventory
    $backend = @{ resource_group_name = $inventory.target.stateResourceGroup; storage_account_name = $inventory.target.storageAccount; container_name = $model.bootstrapContainer; key = "bootstrap/ephemeral/$($inventory.product)/$($inventory.environment)/$($inventory.instance.id).tfstate"; subscription_id = $inventory.target.subscriptionId; tenant_id = $inventory.target.tenantId; use_azuread_auth = $true; use_cli = $true; use_oidc = $false }
    $inputs = @{ subscription_id = $inventory.target.subscriptionId; tenant_id = $inventory.target.tenantId; product = $inventory.product; environment = $inventory.environment; instance_id = $inventory.instance.id; location = $model.location; state_resource_group = $inventory.target.stateResourceGroup; storage_account_name = $inventory.target.storageAccount; oidc_prefix = $model.oidcPrefix; expires_at = $model.expiresAt; roots = @($inventory.roots.id) }
    return @{ backend = $backend; inputs = $inputs }
}

function Assert-EphemeralCloudReservationPlan([hashtable] $Plan) { Assert-AzureEphemeralReservationPlan $Plan }

# The identity that Terraform created is the one GitHub will federate; its client ID completes the definition.
function Assert-EphemeralCloudOutputs([hashtable] $Definition, [hashtable] $Outputs) {
    $model = $Definition; $inventory = $Definition.inventory; $outputs = $Outputs
    $client = $outputs.identity.value.client_id
    if ([guid] $client -eq [guid]::Empty -or $outputs.container.value -cne $inventory.target.container -or $outputs.github_environment.value -cne "$($inventory.environment)-$($inventory.instance.id)") { throw 'lifecycle.ephemeral.bindingsMismatch' }
    $model.inventory.target.clientId = $client
    $identity = Invoke-LifecycleCommand az @('identity', 'show', '--name', "id-$($inventory.product)-$($inventory.environment)-$($inventory.instance.id)-deploy", '--resource-group', $inventory.target.stateResourceGroup, '--subscription', $inventory.target.subscriptionId, '--only-show-errors', '--output', 'json') -TimeoutSeconds 45
    if ($identity.exitCode -ne 0) { throw 'lifecycle.ephemeral.identityUnavailable' }
    $identity = $identity.text | ConvertFrom-Json -AsHashtable
    if ($identity.clientId -ine $client -or $identity.tenantId -ine $inventory.target.tenantId -or $identity.principalId -ine $outputs.identity.value.principal_id) { throw 'lifecycle.ephemeral.identityMismatch' }
}

# The identity reads its scopes and is denied the persistent and bootstrap ones, on the real endpoints.
function Test-EphemeralCloudFederation([hashtable] $Definition) {
    $model = $Definition; $inventory = $Definition.inventory
    Assert-AzureLifecycleRuntime @{ inventory = $inventory }
    $context = New-AzureLifecycleContext $inventory
    foreach ($root in $inventory.roots) { Get-AzureLifecycleScope $context $root | Out-Null }
    function Get-IsolationToken([string] $Resource) {
        $result = Invoke-LifecycleCommand az @('account', 'get-access-token', '--resource', $Resource, '--subscription', $inventory.target.subscriptionId, '--output', 'json', '--only-show-errors') -TimeoutSeconds 45
        if ($result.exitCode -ne 0) { throw 'lifecycle.ephemeral.tokenUnavailable' }
        return ($result.text | ConvertFrom-Json).accessToken
    }
    function Read-IsolationResponse([string] $Uri, [bool] $Storage) {
        $Token = $(if ($Storage) { $storageToken } else { $armToken })
        $headers = @{ Authorization = "Bearer $Token" }
        if ($Storage) { $headers['x-ms-version'] = '2023-11-03'; $headers['x-ms-date'] = [DateTime]::UtcNow.ToString('R') }
        try { $response = Invoke-WebRequest -Uri $Uri -Method Get -Headers $headers -SkipHttpErrorCheck -TimeoutSec 30 -MaximumRedirection 0 }
        catch { throw 'lifecycle.ephemeral.isolationTransportFailed' }
        return [int] $response.StatusCode
    }
    $armToken = Get-IsolationToken 'https://management.azure.com/'
    $storageToken = Get-IsolationToken 'https://storage.azure.com/'
    return Test-AzureEphemeralIsolation $model { param($uri, $storage) Read-IsolationResponse $uri $storage }
}

function Assert-AzureEphemeralReservationPlan([hashtable] $Plan) {
    if ($Plan.format_version -cnotmatch '^1[.]' -or $Plan.complete -isnot [bool] -or $Plan.complete -ne $true -or $Plan.errored -isnot [bool] -or $Plan.errored -ne $false) { throw 'lifecycle.ephemeral.reservationChangeForbidden' }
    foreach ($key in @('deferred_changes', 'deferred_action_invocations', 'action_invocations')) { if ($Plan.ContainsKey($key) -and @($Plan[$key]).Count -gt 0) { throw 'lifecycle.ephemeral.reservationChangeForbidden' } }
    $changes = @()
    if ($Plan.ContainsKey('resource_changes')) {
        if ($Plan.resource_changes -isnot [Collections.IList]) { throw 'lifecycle.ephemeral.reservationChangeForbidden' }
        $changes = $Plan.resource_changes
    }
    foreach ($change in $changes) {
        if ($change.mode -ceq 'data') { continue }
        if ($change.mode -cne 'managed' -or $change.change.actions -isnot [Collections.IList] -or $change.change.actions.Count -eq 0 -or $change.type -cnotin @('azurerm_resource_group', 'azurerm_storage_container', 'azurerm_user_assigned_identity', 'azurerm_federated_identity_credential', 'azurerm_role_assignment') -or
            @($change.change.actions | Where-Object { $_ -cnotin @('create', 'no-op') }).Count -gt 0 -or
            ($change.change.ContainsKey('importing') -and $null -ne $change.change.importing)) { throw 'lifecycle.ephemeral.reservationChangeForbidden' }
    }
}

function Assert-AzureEphemeralBootstrapStorage([hashtable] $Definition, [hashtable] $Account, [hashtable] $Properties) {
    $target = $Definition.inventory.target
    $id = "/subscriptions/$($target.subscriptionId)/resourceGroups/$($target.stateResourceGroup)/providers/Microsoft.Storage/storageAccounts/$($target.storageAccount)"
    if ($Account.id -ine $id -or $Account.allowSharedKeyAccess -ne $false -or $Account.allowBlobPublicAccess -ne $false -or $Account.minimumTlsVersion -cne 'TLS1_2' -or
        $Account.encryption.requireInfrastructureEncryption -ne $true -or $Properties.isVersioningEnabled -ne $true -or $Properties.deleteRetentionPolicy.enabled -ne $true -or
        $Properties.deleteRetentionPolicy.days -lt 30 -or $Properties.containerDeleteRetentionPolicy.enabled -ne $true -or $Properties.containerDeleteRetentionPolicy.days -lt 30) { throw 'lifecycle.ephemeral.storageNotProtected' }
}

function Test-AzureEphemeralIsolation([hashtable] $Definition, [scriptblock] $Read) {
    $inventory = $Definition.inventory
    foreach ($group in $Definition.protectedResourceGroups) {
        $status = & $Read "https://management.azure.com/subscriptions/$($inventory.target.subscriptionId)/resourceGroups/$group`?api-version=2024-03-01" $false
        if ($status -ne 403) { throw 'lifecycle.ephemeral.isolationNotVerified' }
    }
    $hostUrl = "https://$($inventory.target.storageAccount).blob.core.windows.net"
    $status = & $Read "$hostUrl/$($inventory.target.container)?restype=container&comp=list&maxresults=1" $true
    if ($status -ne 200) { throw 'lifecycle.ephemeral.isolationNotVerified' }
    foreach ($name in @($Definition.bootstrapContainer) + @('dev', 'staging', 'prod' | ForEach-Object { "$($Definition.bootstrapContainer)-$_" })) {
        $status = & $Read "$hostUrl/$name`?restype=container&comp=list&maxresults=1" $true
        if ($status -ne 403) { throw 'lifecycle.ephemeral.isolationNotVerified' }
    }
    return @{ apiVersion = 'hexagon.ec/ephemeral-isolation-result/v1'; status = 'Verified'; instanceId = $inventory.instance.id; applicationVerified = $false }
}

Export-ModuleMember -Function Assert-AzureEphemeralReservationPlan, Assert-AzureEphemeralBootstrapStorage, Test-AzureEphemeralIsolation
