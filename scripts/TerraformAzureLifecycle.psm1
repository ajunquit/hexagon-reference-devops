Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'EnvironmentLifecycle.psm1')
Import-Module (Join-Path $PSScriptRoot 'EnvironmentSnapshot.psm1')
Import-Module (Join-Path $PSScriptRoot 'AzureEnvironmentStore.psm1')
Import-Module (Join-Path $PSScriptRoot 'LifecycleNative.psm1')
Import-Module (Join-Path $PSScriptRoot 'PlatformBootstrap.psm1')

function Get-AzureLifecycleCollection([hashtable] $Context, [string] $Uri) {
    $items = [Collections.Generic.List[object]]::new(); $visited = [Collections.Generic.HashSet[string]]::new()
    $path = ([uri] $Uri).AbsolutePath
    do {
        if (-not $visited.Add($Uri) -or $visited.Count -gt 100 -or ([uri] $Uri).AbsolutePath -ine $path) { throw 'lifecycle.azure.paginationInvalid' }
        $response = Invoke-AzureLifecycleHttp $Context GET $Uri
        if ($response.status -ne 200) { throw 'lifecycle.azure.collectionUnavailable' }
        $value = [Text.Encoding]::UTF8.GetString($response.bytes) | ConvertFrom-Json -AsHashtable -Depth 64
        if (-not $value.ContainsKey('value') -or $value.value -isnot [Collections.IList]) { throw 'lifecycle.azure.collectionIncomplete' }
        foreach ($item in $value.value) { $items.Add($item) }
        $Uri = $(if ($value.ContainsKey('nextLink')) { [string] $value.nextLink } else { '' })
    } while ($Uri)
    return $items.ToArray()
}

function Get-AzureLifecycleScope([hashtable] $Context, [hashtable] $Root) {
    $id = "/subscriptions/$($Context.inventory.target.subscriptionId)/resourceGroups/$($Root.resourceGroup)"
    $group = Invoke-AzureLifecycleHttp $Context GET "https://management.azure.com/$($id.TrimStart('/'))?api-version=2024-03-01"
    if ($group.status -ne 200) { throw 'lifecycle.azure.scopeUnavailable' }
    $metadata = [Text.Encoding]::UTF8.GetString($group.bytes) | ConvertFrom-Json -AsHashtable
    if ($metadata.id -ine $id -or $metadata.tags.product -cne $Context.inventory.product -or $metadata.tags.environment -cne $Context.inventory.environment -or
        $metadata.tags.'managed-by' -cne 'terraform' -or ($Context.inventory.instance.kind -ceq 'Ephemeral' -and $metadata.tags.instance -cne $Context.inventory.instance.id)) { throw 'lifecycle.azure.groupOwnershipMismatch' }
    $resources = @(Get-AzureLifecycleCollection $Context "https://management.azure.com$id/resources?api-version=2021-04-01")
    $assignments = @(Get-AzureLifecycleCollection $Context "https://management.azure.com$id/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01")
    $roles = @(
        foreach ($role in $assignments) {
            $scope = $role.properties.scope
            if ($scope -ieq $id -or $scope.StartsWith("$id/", [StringComparison]::OrdinalIgnoreCase)) { $role; continue }
            # Azure includes inherited platform assignments. They are not workload-owned resources.
            if ($scope -ine "/subscriptions/$($Context.inventory.target.subscriptionId)" -and $scope -cne '/' -and
                $scope -inotmatch '^/providers/Microsoft[.]Management/managementGroups/[A-Za-z0-9_.()-]+$') { throw 'lifecycle.azure.scopeResponseMismatch' }
            if ($role.properties.principalId -ieq $Context.actorId) { throw 'lifecycle.azure.inheritedActorRole' }
        }
    )
    $retained = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $expected = @('b24988ac-6180-42a0-ab88-20f7382dd24c', 'f58310d9-a9f6-439a-9e8d-f62e7b41a168')
    $delegated = '7f951dda-4ed3-4680-a7ca-43fe172d538d, 4633458b-17de-408a-b874-0445c86b69e6, 69a216fc-b8fb-44d8-bc22-1f3c2cd27a39, 4f6d3b9b-027b-4f4c-9142-0e7da12a66a2'
    $condition = @('delete', 'write' | ForEach-Object {
        $attribute = $(if ($_ -ceq 'delete') { 'Resource' } else { 'Request' })
        "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/$_'})) OR (@$attribute[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$delegated} AND @$attribute[Microsoft.Authorization/roleAssignments:PrincipalType] ForAnyOfAnyValues:StringEqualsIgnoreCase {'ServicePrincipal'}))"
    }) -join ' AND '
    foreach ($role in $roles) {
        $properties = $role.properties
        if ($properties.principalId -ieq $Context.actorId -and ($properties.scope -ine $id -or ($properties.roleDefinitionId -split '/')[-1] -notin $expected)) { throw 'lifecycle.azure.unexpectedActorRole' }
        if ($properties.scope -ieq $id -and $properties.principalId -ieq $Context.actorId -and ($properties.roleDefinitionId -split '/')[-1] -in $expected) {
            if ($properties.principalType -cne 'ServicePrincipal') { throw 'lifecycle.azure.bootstrapRolesUnverified' }
            if (($properties.roleDefinitionId -split '/')[-1] -ceq $expected[0] -and $properties.ContainsKey('condition') -and $properties.condition) { throw 'lifecycle.azure.bootstrapRolesUnverified' }
            if (($properties.roleDefinitionId -split '/')[-1] -ceq $expected[1] -and ($properties.conditionVersion -cne '2.0' -or ($properties.condition -replace '\s', '') -cne ($condition -replace '\s', ''))) { throw 'lifecycle.azure.delegationConditionMismatch' }
            # These two assignments are owned by bootstrap, not by workload Terraform states.
            [void] $retained.Add($role.id)
        }
    }
    if ($retained.Count -ne 2) { throw 'lifecycle.azure.bootstrapRolesUnverified' }
    $all = @{}
    foreach ($resource in @($resources) + @($roles)) {
        if (-not $resource.id.StartsWith("$id/providers/", [StringComparison]::OrdinalIgnoreCase)) { throw 'lifecycle.azure.scopeResponseMismatch' }
        if (-not $retained.Contains($resource.id)) { $all[$resource.id.ToLowerInvariant()] = $resource.id }
    }
    return @{ id = $id; resources = $resources; remaining = @($all.Values); retained = $retained }
}

function Get-AzureLifecycleApiVersion([string] $Type) {
    switch -Regex ($Type) {
        '^azurerm_(virtual_network|subnet)$' { return '2024-05-01' }
        '^azurerm_private_dns_zone(_virtual_network_link)?$' { return '2020-06-01' }
        '^azurerm_user_assigned_identity$' { return '2023-01-31' }
        '^azurerm_postgresql_flexible_server(_database|_active_directory_administrator)?$' { return '2024-08-01' }
        '^azurerm_container_registry$' { return '2023-07-01' }
        '^azurerm_log_analytics_workspace$' { return '2023-09-01' }
        '^azurerm_container_app(_environment|_job)?$' { return '2024-03-01' }
        '^azurerm_static_web_app$' { return '2023-12-01' }
        '^azurerm_servicebus_(namespace|topic|subscription|subscription_rule)$' { return '2024-01-01' }
        '^azurerm_role_assignment$' { return '2022-04-01' }
        '^azurerm_monitor_metric_alert$' { return '2018-03-01' }
        default { throw 'lifecycle.azure.resourceTypeUnsupported' }
    }
}

function Get-AzureLifecycleState([hashtable] $Context, [hashtable] $Root) {
    $uri = "https://$($Context.inventory.target.storageAccount).blob.core.windows.net/$($Context.inventory.target.container)/$($Root.stateKey)"
    $response = Invoke-AzureLifecycleHttp $Context GET $uri
    if ($response.status -eq 404) { return @{ stateStatus = 'Absent'; lineage = $null; serial = 0; resources = @(); etag = $null } }
    if ($response.status -ne 200 -or -not $response.headers.ContainsKey('ETag')) { throw 'lifecycle.azure.stateUnavailable' }
    $state = [Text.Encoding]::UTF8.GetString($response.bytes) | ConvertFrom-Json -AsHashtable -Depth 100
    if ($state.version -ne 4 -or $state.resources -isnot [Collections.IList]) { throw 'lifecycle.azure.stateInvalid' }
    $items = [Collections.Generic.List[object]]::new()
    foreach ($resource in $state.resources) {
        if ($resource.mode -cne 'managed') { continue }
        Get-AzureLifecycleApiVersion $resource.type | Out-Null
        foreach ($instance in $resource.instances) {
            if ($instance.ContainsKey('deposed')) { throw 'lifecycle.azure.deposedStateUnsupported' }
            $address = "$($resource.type).$($resource.name)"
            if ($resource.ContainsKey('module')) { $address = "$($resource.module).$address" }
            if ($instance.ContainsKey('index_key')) { $address += '[' + (ConvertTo-Json -InputObject $instance.index_key -Compress) + ']' }
            $items.Add(@{ id = $instance.attributes.id; address = $address; type = $resource.type })
        }
    }
    return @{ stateStatus = 'Present'; lineage = $state.lineage; serial = $state.serial; resources = @($items.ToArray()); etag = $response.headers.ETag; outputs = $(if ($state.ContainsKey('outputs')) { $state.outputs } else { @{} }) }
}

function Get-AzureLifecycleWorkloadPrincipals([hashtable] $Context) {
    $roots = @($Context.inventory.roots | Where-Object { $_.id -ceq 'hosting' -and $_.status -ceq 'Verified' })
    if ($roots.Count -ne 1) { throw 'lifecycle.dependencyNotReady' }
    $root = $roots[0]; $scope = Get-AzureLifecycleScope $Context $root
    $state = Get-AzureLifecycleState $Context $root
    if ($state.stateStatus -cne 'Present' -or -not $state.outputs.ContainsKey('workload_identities') -or
        ($state.outputs.workload_identities.ContainsKey('sensitive') -and $state.outputs.workload_identities.sensitive -ne $false)) { throw 'lifecycle.azure.workloadIdentitiesUnavailable' }
    $principals = @{}
    foreach ($key in $state.outputs.workload_identities.value.Keys) {
        $identity = $state.outputs.workload_identities.value[$key]
        $current = @($state.resources | Where-Object { $_.type -ceq 'azurerm_user_assigned_identity' -and $_.id -ieq $identity.id })
        if ($key -cnotmatch '^[a-z][a-z0-9-]*$' -or $current.Count -ne 1 -or -not $identity.id.StartsWith("$($scope.id)/providers/Microsoft.ManagedIdentity/userAssignedIdentities/", [StringComparison]::OrdinalIgnoreCase) -or [guid] $identity.principal_id -eq [guid]::Empty) { throw 'lifecycle.azure.workloadIdentityInvalid' }
        $response = Invoke-AzureLifecycleHttp $Context GET "https://management.azure.com$($identity.id)?api-version=2023-01-31"
        if ($response.status -ne 200) { throw 'lifecycle.azure.workloadIdentityInvalid' }
        $actual = [Text.Encoding]::UTF8.GetString($response.bytes) | ConvertFrom-Json -AsHashtable
        if ($actual.id -ine $identity.id -or $actual.properties.principalId -ine $identity.principal_id) { throw 'lifecycle.azure.workloadIdentityInvalid' }
        $principals[$key] = $identity.principal_id
    }
    $after = Get-AzureLifecycleState $Context $root
    if ($after.etag -cne $state.etag -or $state.lineage -cne $root.stateLineage -or $state.serial -ne $root.stateSerial -or $principals.Count -eq 0) { throw 'lifecycle.azure.stateChangedDuringObservation' }
    return $principals
}

function ConvertTo-AzureMessagingPrincipalInput([hashtable] $InputValue, [hashtable] $Principals) {
    if ($InputValue.destinations -isnot [Collections.IDictionary] -or $InputValue.consumers -isnot [Collections.IDictionary]) { throw 'lifecycle.azure.messagingInputInvalid' }
    $value = (ConvertTo-PlatformBootstrapJson $InputValue) | ConvertFrom-Json -AsHashtable -Depth 32
    foreach ($destination in $value.destinations.Values) {
        foreach ($key in @($destination.publishers.Keys)) {
            if (-not $Principals.ContainsKey($key)) { throw 'lifecycle.azure.publisherIdentityMissing' }
            $destination.publishers[$key] = $Principals[$key]
        }
    }
    foreach ($consumer in $value.consumers.Values) {
        if (-not $Principals.ContainsKey($consumer.workload)) { throw 'lifecycle.azure.consumerIdentityMissing' }
        $consumer.principal_id = $Principals[$consumer.workload]
    }
    return $value
}

function Assert-AzureLifecycleRuntime([hashtable] $Context) {
    if ($env:GITHUB_ACTIONS -cne 'true' -or $env:GITHUB_EVENT_NAME -cne 'workflow_dispatch' -or $env:GITHUB_REF -cne 'refs/heads/main' -or
        $env:GITHUB_REPOSITORY -ine $Context.inventory.iac.repository -or
        $env:GITHUB_WORKFLOW_REF -cnotin @("$($Context.inventory.iac.repository)/.github/workflows/genesis.yml@refs/heads/main", "$($Context.inventory.iac.repository)/.github/workflows/apocalypse.yml@refs/heads/main", "$($Context.inventory.iac.repository)/.github/workflows/delivery.yml@refs/heads/main")) { throw 'lifecycle.azure.trustedWorkflowRequired' }
}

function Get-AzureLifecycleDeploymentState {
    param([hashtable] $Context, [ValidateSet('hosting', 'messaging')][string] $RootId, [switch] $AllowPendingPlan)
    Assert-AzureLifecycleLease $Context
    $root = @($Context.inventory.roots | Where-Object id -CEQ $RootId)[0]
    $pending = $AllowPendingPlan -and ($root.status -ceq 'Planned' -or ($root.status -ceq 'Failed' -and $root.errorCode -ceq 'lifecycle.inputsChangedRequiresPlan'))
    if ($root.lastOperation -cne 'Create' -or ($root.status -cne 'Verified' -and -not $pending)) { throw 'lifecycle.delivery.rootNotReady' }
    $scope = Get-AzureLifecycleScope $Context $root
    $state = Get-AzureLifecycleState $Context $root
    if ($state.stateStatus -cne 'Present' -or $state.lineage -cne $root.stateLineage -or $state.serial -ne $root.stateSerial) { throw 'lifecycle.delivery.stateChanged' }
    $allowed = $(if ($RootId -ceq 'hosting') { @('registry', 'maintenance_jobs', 'workload_identities', 'database_bootstrap', 'web', 'api_url', 'frontend_authentication') } else { @('workload_bindings', 'namespace') })
    $outputs = @{}
    foreach ($name in $allowed) {
        if (-not $state.outputs.ContainsKey($name)) { continue }
        $output = $state.outputs[$name]
        if ($output.ContainsKey('sensitive') -and $output.sensitive -ne $false) { throw 'lifecycle.delivery.sensitiveOutputRejected' }
        $outputs[$name] = $output.value
    }
    foreach ($resource in $state.resources) {
        if (-not $resource.id.StartsWith("$($scope.id)/providers/", [StringComparison]::OrdinalIgnoreCase) -or
            @($root.resources | Where-Object { $_.id -ieq $resource.id -and $_.current }).Count -ne 1) { throw 'lifecycle.delivery.resourceUnrecorded' }
    }
    return @{ outputs = $outputs; resources = $state.resources; lineage = $state.lineage; serial = $state.serial; etag = $state.etag; scopeId = $scope.id }
}

function Assert-AzureLifecycleWorkspace([hashtable] $Context) {
    foreach ($link in @(Get-ChildItem -LiteralPath $Context.directory -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })) {
        $relative = [IO.Path]::GetRelativePath($Context.directory, $link.FullName).Replace('\', '/')
        if ($relative -cnotmatch '^terraform/environments/(dev|staging|prod)/(azure|hosting-azure)/[.]terraform/providers/registry[.]terraform[.]io/hashicorp/azurerm/[0-9.]+/(linux|windows|darwin)_(amd64|arm64)$') { throw 'lifecycle.azure.workspaceLink' }
    }
    foreach ($name in $Context.snapshot.manifest.files.Keys) {
        $path = Join-Path $Context.directory $name
        if ((Get-LifecycleFileHash $path) -cne $Context.snapshot.manifest.files[$name]) { throw 'lifecycle.azure.workspaceChanged' }
    }
    $candidates = @(Get-ChildItem -LiteralPath (Join-Path $Context.directory 'terraform') -Recurse -File -Force | Where-Object { $_.FullName -notmatch '[/\\][.]terraform[/\\]' -and ($_.Name -match '[.]tf(?:[.]json)?$|[.]tfvars(?:[.]json)?$|[.]terraform[.]lock[.]hcl$') })
    foreach ($file in $candidates) {
        $relative = [IO.Path]::GetRelativePath($Context.directory, $file.FullName).Replace('\', '/')
        if (-not $Context.snapshot.manifest.files.ContainsKey($relative) -or $file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'lifecycle.azure.workspaceChanged' }
    }
    $version = Invoke-LifecycleCommand terraform @('version', '-json') -TimeoutSeconds 30
    if ($version.exitCode -ne 0 -or ($version.text | ConvertFrom-Json).terraform_version -cne $Context.snapshot.manifest.terraformVersion) { throw 'lifecycle.azure.toolchainMismatch' }
}

function Invoke-AzureLifecycleTerraform {
    param([hashtable] $Context, [hashtable] $Root, [string[]] $Arguments)
    Assert-LifecycleCliEnvironment
    Assert-AzureLifecycleLease $Context
    Assert-AzureLifecycleWorkspace $Context
    $directory = Join-Path $Context.directory $Context.snapshot.manifest.roots[$Root.id].directory
    $child = @{ ARM_SUBSCRIPTION_ID = $Context.inventory.target.subscriptionId; ARM_TENANT_ID = $Context.inventory.target.tenantId; ARM_USE_CLI = 'true'; ARM_USE_MSI = 'false'; ARM_USE_OIDC = 'false'; TF_IN_AUTOMATION = 'true' }
    $cliConfig = Join-Path $Context.runtime 'terraform.rc'
    [IO.File]::WriteAllText($cliConfig, "disable_checkpoint = true`nprovider_installation {`n  direct {}`n}`n")
    $child['TF_CLI_CONFIG_FILE'] = $cliConfig
    $renew = (Get-Command Assert-AzureLifecycleLease).ScriptBlock
    $heartbeat = { & $renew $Context }.GetNewClosure()
    return Invoke-LifecycleCommand terraform (@("-chdir=$directory") + $Arguments) -Environment $child -Heartbeat $heartbeat
}

function Initialize-AzureLifecycleTerraform([hashtable] $Context, [hashtable] $Root) {
    $backend = @{ resource_group_name = $Context.inventory.target.stateResourceGroup; storage_account_name = $Context.inventory.target.storageAccount
        container_name = $Context.inventory.target.container; key = $Root.stateKey; subscription_id = $Context.inventory.target.subscriptionId; tenant_id = $Context.inventory.target.tenantId
        use_azuread_auth = $true; use_cli = $true; use_oidc = $false }
    $path = Join-Path $Context.runtime "$($Root.id)-backend.json"
    [IO.File]::WriteAllText($path, (ConvertTo-PlatformBootstrapJson $backend))
    $result = Invoke-AzureLifecycleTerraform $Context $Root @('init', '-input=false', '-reconfigure', '-lockfile=readonly', '-no-color', "-backend-config=$path")
    if ($result.exitCode -ne 0) { throw 'lifecycle.azure.terraformInitFailed' }
}

function New-AzureLifecyclePlan {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([hashtable] $Context, [hashtable] $Root, [ValidateSet('Create', 'Destroy')][string] $Operation)
    if (-not $PSCmdlet.ShouldProcess($Root.id, "Prepare $Operation Terraform plan")) { return }
    Initialize-AzureLifecycleTerraform $Context $Root
    $binary = Join-Path $Context.runtime "$($Root.id).tfplan"
    $inputs = Join-Path $Context.directory $Context.snapshot.manifest.roots[$Root.id].inputs
    $arguments = @('plan', '-input=false', '-lock-timeout=60s', '-no-color', "-var-file=$inputs", "-out=$binary")
    if ($Operation -ceq 'Destroy') { $arguments += '-destroy' }
    $result = Invoke-AzureLifecycleTerraform $Context $Root $arguments
    if ($result.exitCode -ne 0) { throw 'lifecycle.azure.terraformPlanFailed' }
    $show = Invoke-AzureLifecycleTerraform $Context $Root @('show', '-json', $binary)
    if ($show.exitCode -ne 0) { throw 'lifecycle.azure.terraformShowFailed' }
    [IO.File]::WriteAllBytes("$binary.json", $show.bytes)
    return @{ binaryPath = $binary; jsonPath = "$binary.json" }
}

function Get-AzureLifecycleObservationOnce([hashtable] $Context, [hashtable] $Root, [string] $Operation) {
    $scope = Get-AzureLifecycleScope $Context $Root
    $state = Get-AzureLifecycleState $Context $Root
    $all = @{}; foreach ($resource in @($Root.resources) + @($state.resources)) {
        if (-not $resource.id.StartsWith("$($scope.id)/providers/", [StringComparison]::OrdinalIgnoreCase) -or $resource.id -match '[?#%\\\s]|/(?:[.][.]?|)(?:/|$)' -or $scope.retained.Contains($resource.id)) { throw 'lifecycle.azure.resourceScopeMismatch' }
        $all[$resource.id.ToLowerInvariant()] = $resource
    }
    $probes = @(
        foreach ($resource in $all.Values) {
            $version = Get-AzureLifecycleApiVersion $resource.type
            $response = Invoke-AzureLifecycleHttp $Context GET "https://management.azure.com$($resource.id)?api-version=$version"
            if ($response.status -notin @(200, 404)) { throw 'lifecycle.azure.resourceProbeUnavailable' }
            @{ id = $resource.id; status = $(if ($response.status -eq 200) { 'Present' } else { 'Missing' }) }
        }
    )
    $converged = $false
    if ($Operation -ceq 'Create') {
        Initialize-AzureLifecycleTerraform $Context $Root
        $inputs = Join-Path $Context.directory $Context.snapshot.manifest.roots[$Root.id].inputs
        $plan = Invoke-AzureLifecycleTerraform $Context $Root @('plan', '-input=false', '-lock-timeout=60s', '-no-color', '-detailed-exitcode', "-var-file=$inputs")
        if ($plan.exitCode -notin @(0, 2)) { throw 'lifecycle.azure.convergenceUnavailable' }
        $converged = $plan.exitCode -eq 0
    }
    $check = Get-AzureLifecycleState $Context $Root
    if ($check.etag -cne $state.etag) { throw 'lifecycle.azure.stateChangedDuringObservation' }
    return @{ stateStatus = $state.stateStatus; lineage = $state.lineage; serial = $state.serial; resources = @($state.resources)
        scopeAccessible = $true; scopeComplete = $true; configurationConverged = $converged; probes = $probes; remainingResourceIds = @($scope.remaining) }
}

function Get-AzureLifecycleObservation([hashtable] $Context, [hashtable] $Root, [string] $Operation) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        $observation = Get-AzureLifecycleObservationOnce $Context $Root $Operation
        if ($Operation -cne 'Destroy' -or $observation.resources.Count -gt 0 -or
            ($observation.remainingResourceIds.Count -eq 0 -and @($observation.probes | Where-Object status -CEQ 'Present').Count -eq 0) -or $timer.Elapsed.TotalSeconds -ge 60) { return $observation }
        Assert-AzureLifecycleLease $Context
        Start-Sleep -Seconds 5
    } while ($true)
}

function Invoke-AzureLifecycleQuiesce {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([hashtable] $Context)
    if ($Context.inventory.instance.kind -cne 'Ephemeral' -or $Context.inventory.environment -ceq 'prod' -or $Context.inventory.dataPolicy -cne 'DeleteEphemeral') { throw 'lifecycle.azure.backupVerifierRequired' }
    Assert-AzureLifecycleRuntime $Context
    $commands = [Collections.Generic.List[object]]::new()
    foreach ($root in $Context.inventory.roots) {
        $scope = Get-AzureLifecycleScope $Context $root
        foreach ($resource in $scope.resources) {
            if ($resource.type -inotmatch '^Microsoft[.](App/(containerApps|jobs)|ServiceBus/namespaces)$') { continue }
            if (@($root.resources | Where-Object { $_.id -ieq $resource.id -and $_.current }).Count -ne 1) { throw 'lifecycle.azure.quiesceResourceUnrecorded' }
            $name = ($resource.id -split '/')[-1]
            if ($resource.type -ieq 'Microsoft.App/containerApps') {
                foreach ($revision in @(Get-AzureLifecycleCollection $Context "https://management.azure.com$($resource.id)/revisions?api-version=2024-03-01")) {
                    if ($revision.properties.active -isnot [bool] -or $revision.name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,99}$') { throw 'lifecycle.azure.quiesceResponseInvalid' }
                    if ($revision.properties.active) { $commands.Add(@('containerapp', 'revision', 'deactivate', '--name', $name, '--resource-group', $root.resourceGroup, '--revision', $revision.name)) }
                }
            }
            elseif ($resource.type -ieq 'Microsoft.App/jobs') {
                $job = Invoke-AzureLifecycleHttp $Context GET "https://management.azure.com$($resource.id)?api-version=2024-03-01"
                if ($job.status -ne 200 -or ([Text.Encoding]::UTF8.GetString($job.bytes) | ConvertFrom-Json).properties.configuration.triggerType -cne 'Manual') { throw 'lifecycle.azure.quiesceScheduledJobUnsupported' }
                foreach ($execution in @(Get-AzureLifecycleCollection $Context "https://management.azure.com$($resource.id)/executions?api-version=2024-03-01")) {
                    if ($execution.properties.status -cnotin @('Succeeded', 'Failed', 'Stopped', 'Canceled')) {
                        if ($execution.name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,99}$') { throw 'lifecycle.azure.quiesceResponseInvalid' }
                        $commands.Add(@('containerapp', 'job', 'stop', '--name', $name, '--resource-group', $root.resourceGroup, '--job-execution-name', $execution.name))
                    }
                }
            }
            else {
                foreach ($topic in @(Get-AzureLifecycleCollection $Context "https://management.azure.com$($resource.id)/topics?api-version=2024-01-01")) {
                    if (-not $topic.id.StartsWith("$($resource.id)/topics/", [StringComparison]::OrdinalIgnoreCase) -or @($root.resources | Where-Object { $_.id -ieq $topic.id -and $_.current }).Count -ne 1) { throw 'lifecycle.azure.quiesceResourceUnrecorded' }
                    $commands.Add(@('servicebus', 'topic', 'update', '--ids', $topic.id, '--status', 'Disabled'))
                    foreach ($subscription in @(Get-AzureLifecycleCollection $Context "https://management.azure.com$($topic.id)/subscriptions?api-version=2024-01-01")) {
                        if (-not $subscription.id.StartsWith("$($topic.id)/subscriptions/", [StringComparison]::OrdinalIgnoreCase) -or @($root.resources | Where-Object { $_.id -ieq $subscription.id -and $_.current }).Count -ne 1) { throw 'lifecycle.azure.quiesceResourceUnrecorded' }
                        $commands.Add(@('servicebus', 'topic', 'subscription', 'update', '--ids', $subscription.id, '--status', 'Disabled'))
                    }
                }
            }
        }
    }
    if (-not $PSCmdlet.ShouldProcess($Context.prefix, 'Quiesce inventoried ephemeral applications, jobs and messaging')) { return }
    foreach ($arguments in $commands) {
        Assert-AzureLifecycleLease $Context
        $result = Invoke-LifecycleCommand az (@($arguments) + @('--subscription', $Context.inventory.target.subscriptionId, '--only-show-errors', '--output', 'none')) -TimeoutSeconds 90
        if ($result.exitCode -ne 0) { throw 'lifecycle.azure.quiesceFailed' }
    }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        Assert-AzureLifecycleLease $Context
        try { return Get-AzureLifecycleDestructionSafety $Context @{ product = $Context.inventory.product; environment = $Context.inventory.environment; instanceId = $Context.inventory.instance.id; root = $Context.inventory.roots[0] } }
        catch {
            if ($_.Exception.Message -cnotin @('lifecycle.azure.applicationNotQuiesced', 'lifecycle.azure.jobNotQuiesced', 'lifecycle.azure.messagingNotQuiesced') -or $timer.Elapsed.TotalSeconds -ge 90) { throw }
            Start-Sleep -Seconds 5
        }
    } while ($true)
}

function Get-AzureLifecycleDestructionSafety([hashtable] $Context, [object] $Request) {
    if ($Context.inventory.dataPolicy -cne 'DeleteEphemeral') { throw 'lifecycle.azure.backupVerifierRequired' }
    $facts = @()
    foreach ($root in $Context.inventory.roots) {
        $scope = Get-AzureLifecycleScope $Context $root
        foreach ($resource in $scope.resources) {
            if ($resource.type -ieq 'Microsoft.App/containerApps') {
                $revisions = @(Get-AzureLifecycleCollection $Context "https://management.azure.com$($resource.id)/revisions?api-version=2024-03-01")
                if (@($revisions | Where-Object { $_.properties.active -isnot [bool] -or $_.properties.active }).Count -gt 0) { throw 'lifecycle.azure.applicationNotQuiesced' }
            }
            elseif ($resource.type -ieq 'Microsoft.App/jobs') {
                $executions = @(Get-AzureLifecycleCollection $Context "https://management.azure.com$($resource.id)/executions?api-version=2024-03-01")
                if (@($executions | Where-Object { $_.properties.status -cnotin @('Succeeded', 'Failed', 'Stopped', 'Canceled') }).Count -gt 0) { throw 'lifecycle.azure.jobNotQuiesced' }
            }
            elseif ($resource.type -ieq 'Microsoft.ServiceBus/namespaces') {
                $topics = @(Get-AzureLifecycleCollection $Context "https://management.azure.com$($resource.id)/topics?api-version=2024-01-01")
                foreach ($topic in $topics) {
                    if ($topic.properties.status -cne 'Disabled') { throw 'lifecycle.azure.messagingNotQuiesced' }
                    $subscriptions = @(Get-AzureLifecycleCollection $Context "https://management.azure.com$($topic.id)/subscriptions?api-version=2024-01-01")
                    if (@($subscriptions | Where-Object { $_.properties.status -cne 'Disabled' }).Count -gt 0) { throw 'lifecycle.azure.messagingNotQuiesced' }
                }
            }
            $facts += $resource.id
        }
    }
    $evidence = @{ product = $Request.product; environment = $Request.environment; instanceId = $Request.instanceId; rootId = $Request.root.id; observedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); resources = $facts }
    $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-PlatformBootstrapJson $evidence)); $hash = Get-LifecycleBytesHash $bytes
    Publish-AzureLifecycleObject $Context "$($Context.prefix)/evidence/$hash.json" $bytes $hash
    return @{ quiesced = $true; backupVerified = $false; evidenceSha256 = $hash; product = $Request.product; environment = $Request.environment; instanceId = $Request.instanceId; rootId = $Request.root.id }
}

function Invoke-AzureLifecyclePortAction([hashtable] $Context, [hashtable] $request) {
        $root = $request.root
        switch ($request.action) {
            'Preflight' {
                Assert-AzureLifecycleLease $Context
                Assert-AzureLifecycleWorkspace $Context
                $scope = Get-AzureLifecycleScope $Context $root
                foreach ($resource in $root.resources) { if ($scope.retained.Contains($resource.id)) { throw 'lifecycle.azure.bootstrapProtected' } }
                $valid = $false
                if ($request.ContainsKey('binaryPath')) {
                    Initialize-AzureLifecycleTerraform $Context $root
                    $shown = Invoke-AzureLifecycleTerraform $Context $root @('show', '-json', $request.binaryPath)
                    $valid = $shown.exitCode -eq 0 -and (Get-LifecycleBytesHash $shown.bytes) -ceq $root.plan.jsonSha256 -and (Get-LifecycleFileHash $request.binaryPath) -ceq $root.plan.binarySha256
                }
                return @{ verified = $true; product = $request.product; environment = $request.environment; instanceId = $request.instanceId
                    tenantId = $Context.inventory.target.tenantId; subscriptionId = $Context.inventory.target.subscriptionId; clientId = $Context.inventory.target.clientId
                    configurationSha256 = $Context.snapshot.manifest.roots[$root.id].configurationSha256; inputsSha256 = $Context.snapshot.manifest.roots[$root.id].inputsSha256
                    iacSnapshotSha256 = $Context.inventory.iac.snapshotSha256; stateKey = $root.stateKey; container = $Context.inventory.target.container
                    planVerified = $valid; binarySha256 = $(if ($valid) { Get-LifecycleFileHash $request.binaryPath } else { $null }); jsonSha256 = $(if ($valid) { Get-LifecycleBytesHash $shown.bytes } else { $null }) }
            }
            'Persist' { return Save-AzureLifecycleJournal $Context $request.inventoryPath }
            'DestructionSafety' { return Get-AzureLifecycleDestructionSafety $Context $request }
            'Apply' {
                Assert-AzureLifecycleRuntime $Context
                if ((Get-LifecycleFileHash $request.binaryPath) -cne $request.binarySha256) { throw 'lifecycle.azure.planChanged' }
                $result = Invoke-AzureLifecycleTerraform $Context $root @('apply', '-input=false', '-lock-timeout=60s', '-no-color', $request.binaryPath)
                return @{ exitCode = $result.exitCode }
            }
            'Observe' { return Get-AzureLifecycleObservation $Context $root $request.operation }
            default { throw 'lifecycle.azure.actionUnsupported' }
        }
}

function New-AzureLifecyclePort([hashtable] $Context) {
    $module = $ExecutionContext.SessionState.Module
    $port = { param($request) & $module { param($contextValue, $requestValue) Invoke-AzureLifecyclePortAction $contextValue $requestValue } $Context $request }.GetNewClosure()
    return $port
}

Export-ModuleMember -Function New-AzureLifecyclePort, New-AzureLifecyclePlan, Get-AzureLifecycleObservation, Get-AzureLifecycleDestructionSafety, Get-AzureLifecycleApiVersion, Get-AzureLifecycleScope, Assert-AzureLifecycleRuntime, Get-AzureLifecycleWorkloadPrincipals, Invoke-AzureLifecycleQuiesce, ConvertTo-AzureMessagingPrincipalInput, Get-AzureLifecycleDeploymentState
