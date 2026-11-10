Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'EnvironmentLifecycle.psm1')
Import-Module (Join-Path $PSScriptRoot 'EnvironmentSnapshot.psm1')
Import-Module (Join-Path $PSScriptRoot 'PlatformBootstrap.Execution.psm1')
Import-Module (Join-Path $PSScriptRoot 'LifecycleNative.psm1')

function Read-EphemeralEnvironment([string] $Path) {
    $root = Split-Path -Parent $PSScriptRoot
    if ((Get-Item -LiteralPath $Path).Length -gt 4194304 -or (Get-Item -LiteralPath $Path).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'lifecycle.ephemeral.definitionInvalid' }
    $json = Get-Content -Raw -LiteralPath $Path
    if (-not ($json | Test-Json -SchemaFile (Join-Path $root 'contracts/schemas/ephemeral-environment-v1.schema.json') -ErrorAction SilentlyContinue)) { throw 'lifecycle.ephemeral.definitionInvalid' }
    $value = $json | ConvertFrom-Json -AsHashtable -Depth 32
    Assert-EnvironmentInitialInventory $value.inventory
    $inventory = $value.inventory
    if ($inventory.components.Count -ne 2 -or $inventory.components -cnotcontains 'web' -or $inventory.components -cnotcontains 'backend') { throw 'lifecycle.ephemeral.referenceComponentsUnsupported' }
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
    return $value
}

function Assert-EphemeralSelection([hashtable] $Definition, [string] $Environment, [string] $InstanceId, [string] $Operation) {
    $inventory = $Definition.inventory
    if ($inventory.environment -cne $Environment -or $inventory.instance.id -cne $InstanceId) { throw 'lifecycle.selectionMismatch' }
    if ($Operation -ceq 'Create' -and $Definition.expiresAt -le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) { throw 'lifecycle.ephemeral.expired' }
    if ($Operation -ceq 'Create' -and $Definition.expiresAt -gt [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 604800) { throw 'lifecycle.ephemeral.expiryTooLong' }
}

function Resolve-EphemeralWorkspacePath([string] $Path) {
    $root = Split-Path -Parent $PSScriptRoot
    $prefix = [IO.Path]::GetFullPath((Join-Path $root 'artifacts')) + [IO.Path]::DirectorySeparatorChar
    $pathValue = [IO.Path]::GetFullPath($Path, (Get-Location).ProviderPath)
    $comparison = $(if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal })
    if (-not $pathValue.StartsWith($prefix, $comparison)) { throw 'lifecycle.ephemeral.workspaceOutsideArtifacts' }
    $ancestor = $pathValue
    while ($ancestor.Length -ge $prefix.Length - 1) {
        if ((Test-Path -LiteralPath $ancestor) -and (Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'lifecycle.ephemeral.workspaceLink' }
        $ancestor = [IO.Path]::GetDirectoryName($ancestor)
    }
    return $pathValue
}

function New-EphemeralWorkspace {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string] $Path)
    $pathValue = Resolve-EphemeralWorkspacePath $Path
    if (Test-Path -LiteralPath $pathValue) { throw 'lifecycle.ephemeral.workspaceExists' }
    if (-not $PSCmdlet.ShouldProcess($pathValue, 'Create private ephemeral workspace')) { return }
    [IO.Directory]::CreateDirectory($pathValue) | Out-Null
    if ($IsWindows) {
        $acl = Get-Acl -LiteralPath $pathValue; $acl.SetAccessRuleProtection($true, $false)
        $user = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($user, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
        Set-Acl -LiteralPath $pathValue -AclObject $acl
    }
    else { [IO.File]::SetUnixFileMode($pathValue, [IO.UnixFileMode] 'UserRead,UserWrite,UserExecute') }
    return $pathValue
}

function Invoke-EphemeralGithub([string] $Method, [string] $Path, [object] $Body) {
    $module = Get-Module PlatformBootstrap.Execution
    return & $module { param($m, $p, $b) Invoke-BootstrapApi $m $p $b } $Method $Path $Body
}

function Assert-EphemeralRepository([hashtable] $Definition) {
    $repository = $Definition.inventory.iac.repository
    $metadata = Invoke-EphemeralGithub GET "repos/$repository" $null
    $oidc = Invoke-EphemeralGithub GET "repos/$repository/actions/oidc/customization/sub" $null
    $prefixes = @("repo:$repository", "repo:$($metadata.owner.login)@$($metadata.owner.id)/$($metadata.name)@$($metadata.id)")
    if ($metadata.full_name -ine $repository -or $metadata.default_branch -cne 'main' -or $metadata.archived -ne $false -or $metadata.disabled -ne $false -or
        $oidc.use_default -ne $true -or $oidc.sub_claim_prefix -cnotin $prefixes -or $oidc.sub_claim_prefix -cne $Definition.oidcPrefix) { throw 'lifecycle.ephemeral.repositoryMismatch' }
}

function Get-EphemeralGithubProtection {
    param([hashtable] $Definition, [switch] $SkipBindings)
    $inventory = $Definition.inventory
    $name = "$($inventory.environment)-$($inventory.instance.id)"
    $base = "repos/$($inventory.iac.repository)/environments/$name"
    $settings = Invoke-EphemeralGithub GET $base $null
    $policies = Invoke-EphemeralGithub GET "$base/deployment-branch-policies?per_page=100" $null
    if ($policies.total_count -ne @($policies.branch_policies).Count) { throw 'lifecycle.ephemeral.githubIncomplete' }
    if ($settings.can_admins_bypass -ne $false -or $settings.deployment_branch_policy.protected_branches -ne $false -or $settings.deployment_branch_policy.custom_branch_policies -ne $true -or
        @($policies.branch_policies).Count -ne 1 -or $policies.branch_policies[0].name -cne 'main' -or $policies.branch_policies[0].type -cne 'branch') { throw 'lifecycle.ephemeral.githubProtectionDrift' }
    $reviewers = @($settings.protection_rules | Where-Object type -CEQ 'required_reviewers')
    if ($Definition.reviewerIds.Count -gt 0) {
        if ($reviewers.Count -ne 1 -or $reviewers[0].prevent_self_review -ne $true -or
            (@($reviewers[0].reviewers | ForEach-Object { if ($_.type -cne 'User') { throw 'lifecycle.ephemeral.githubReviewerDrift' }; $_.reviewer.id } | Sort-Object) -join ',') -cne (@($Definition.reviewerIds | Sort-Object) -join ',')) { throw 'lifecycle.ephemeral.githubReviewerDrift' }
    }
    elseif ($reviewers.Count -ne 0) { throw 'lifecycle.ephemeral.githubReviewerDrift' }
    if (@($settings.protection_rules | Where-Object { $_.type -cnotin @('required_reviewers', 'branch_policy', 'wait_timer') -or ($_.type -ceq 'wait_timer' -and $_.wait_timer -ne 0) }).Count -gt 0) { throw 'lifecycle.ephemeral.githubProtectionDrift' }
    if (-not $SkipBindings) {
        $variables = Invoke-EphemeralGithub GET "$base/variables?per_page=100" $null
        if ($variables.total_count -ne @($variables.variables).Count) { throw 'lifecycle.ephemeral.githubIncomplete' }
        foreach ($pair in @{ AZURE_CLIENT_ID = $inventory.target.clientId; AZURE_TENANT_ID = $inventory.target.tenantId; AZURE_SUBSCRIPTION_ID = $inventory.target.subscriptionId }.GetEnumerator()) {
            $matches = @($variables.variables | Where-Object name -CEQ $pair.Key)
            if ($matches.Count -ne 1 -or $matches[0].value -cne $pair.Value) { throw 'lifecycle.ephemeral.githubVariableDrift' }
        }
    }
    return $name
}

function Set-EphemeralGithubProtection {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([hashtable] $Definition)
    Assert-EphemeralRepository $Definition
    $inventory = $Definition.inventory
    $repository = $inventory.iac.repository
    $name = "$($inventory.environment)-$($inventory.instance.id)"
    $base = "repos/$repository/environments/$name"
    $environments = Invoke-EphemeralGithub GET "repos/$repository/environments?per_page=100" $null
    if ($environments.total_count -ne @($environments.environments).Count) { throw 'lifecycle.ephemeral.githubIncomplete' }
    if (@($environments.environments | Where-Object name -CEQ $name).Count -gt 0) {
        $policies = Invoke-EphemeralGithub GET "$base/deployment-branch-policies?per_page=100" $null
        if ($policies.total_count -ne @($policies.branch_policies).Count -or @($policies.branch_policies | Where-Object { $_.name -cne 'main' -or $_.type -cne 'branch' }).Count -gt 0) { throw 'lifecycle.ephemeral.githubBranchConflict' }
    }
    else { $policies = @{ branch_policies = @() } }
    foreach ($id in $Definition.reviewerIds) {
        $user = Invoke-EphemeralGithub GET "user/$id" $null
        $permission = Invoke-EphemeralGithub GET "repos/$repository/collaborators/$($user.login)/permission" $null
        if ($user.id -ne $id -or $user.type -cne 'User' -or $permission.permission -cnotin @('read', 'write', 'admin', 'maintain', 'triage')) { throw 'lifecycle.ephemeral.reviewerInvalid' }
    }
    if (-not $PSCmdlet.ShouldProcess($base, 'Configure isolated main-only GitHub environment and bindings')) { return }
    Invoke-EphemeralGithub PUT $base @{ wait_timer = 0; prevent_self_review = ($Definition.reviewerIds.Count -gt 0); reviewers = @($Definition.reviewerIds | ForEach-Object { @{ type = 'User'; id = $_ } }); can_admins_bypass = $false; deployment_branch_policy = @{ protected_branches = $false; custom_branch_policies = $true } } | Out-Null
    if (@($policies.branch_policies).Count -eq 0) { Invoke-EphemeralGithub POST "$base/deployment-branch-policies" @{ name = 'main'; type = 'branch' } | Out-Null }
    $existing = Invoke-EphemeralGithub GET "$base/variables?per_page=100" $null
    if ($existing.total_count -ne @($existing.variables).Count) { throw 'lifecycle.ephemeral.githubIncomplete' }
    foreach ($pair in @{ AZURE_CLIENT_ID = $inventory.target.clientId; AZURE_TENANT_ID = $inventory.target.tenantId; AZURE_SUBSCRIPTION_ID = $inventory.target.subscriptionId }.GetEnumerator()) {
        $matches = @($existing.variables | Where-Object name -CEQ $pair.Key)
        if ($matches.Count -eq 1 -and $matches[0].value -ceq $pair.Value) { continue }
        if ($matches.Count -eq 1) { Invoke-EphemeralGithub PATCH "$base/variables/$($pair.Key)" @{ name = $pair.Key; value = $pair.Value } | Out-Null }
        else { Invoke-EphemeralGithub POST "$base/variables" @{ name = $pair.Key; value = $pair.Value } | Out-Null }
    }
    Get-EphemeralGithubProtection $Definition | Out-Null
}

function Assert-EphemeralTrackedDefinition([string] $Path, [string] $Sha256, [string] $Environment, [string] $InstanceId, [string] $Operation) {
    $repository = Split-Path -Parent $PSScriptRoot
    if ($Environment -ceq 'prod') { throw 'lifecycle.ephemeral.productionNotSupported' }
    if ($InstanceId -cnotmatch '^run-[1-9][0-9]*-[1-9][0-9]*$' -or $Environment -cnotin @('dev', 'staging', 'prod') -or $Sha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'lifecycle.ephemeral.selectionInvalid' }
    $expected = Join-Path $repository ".config/environments/$Environment/$InstanceId/definition.json"
    if ([IO.Path]::GetFullPath($Path, (Get-Location).ProviderPath) -cne [IO.Path]::GetFullPath($expected)) { throw 'lifecycle.ephemeral.definitionPathInvalid' }
    $ancestor = [IO.Path]::GetDirectoryName($expected)
    while ($ancestor.Length -ge $repository.Length) {
        if ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'lifecycle.ephemeral.definitionPathInvalid' }
        $ancestor = [IO.Path]::GetDirectoryName($ancestor)
    }
    $relative = [IO.Path]::GetRelativePath($repository, $expected).Replace('\', '/')
    $source = Invoke-LifecycleCommand git @('show', "HEAD:$relative") $repository -TimeoutSeconds 30
    if ($source.exitCode -ne 0 -or (Get-LifecycleFileHash $expected) -cne $Sha256 -or (Get-SnapshotHash ([Text.Encoding]::UTF8.GetString($source.bytes))) -cne (Get-SnapshotHash (Get-Content -Raw -LiteralPath $expected))) { throw 'lifecycle.ephemeral.definitionChanged' }
    $definition = Read-EphemeralEnvironment $expected
    $product = (Get-Content -Raw -LiteralPath (Join-Path $repository '.config/product.json') | ConvertFrom-Json).product
    if ($product -cne $definition.inventory.product) { throw 'lifecycle.selectionMismatch' }
    Assert-EphemeralSelection $definition $Environment $InstanceId $Operation
    return $definition
}

function Assert-EphemeralReservationPlan([hashtable] $Plan) {
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

function Assert-EphemeralBootstrapStorage([hashtable] $Definition, [hashtable] $Account, [hashtable] $Properties) {
    $target = $Definition.inventory.target
    $id = "/subscriptions/$($target.subscriptionId)/resourceGroups/$($target.stateResourceGroup)/providers/Microsoft.Storage/storageAccounts/$($target.storageAccount)"
    if ($Account.id -ine $id -or $Account.allowSharedKeyAccess -ne $false -or $Account.allowBlobPublicAccess -ne $false -or $Account.minimumTlsVersion -cne 'TLS1_2' -or
        $Account.encryption.requireInfrastructureEncryption -ne $true -or $Properties.isVersioningEnabled -ne $true -or $Properties.deleteRetentionPolicy.enabled -ne $true -or
        $Properties.deleteRetentionPolicy.days -lt 30 -or $Properties.containerDeleteRetentionPolicy.enabled -ne $true -or $Properties.containerDeleteRetentionPolicy.days -lt 30) { throw 'lifecycle.ephemeral.storageNotProtected' }
}

function Test-EphemeralIsolation([hashtable] $Definition, [scriptblock] $Read) {
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

function Assert-EphemeralReservationReview([hashtable] $Review, [string] $Sha256, [string] $DefinitionSha256, [string] $SourceSha256, [string] $Directory) {
    $names = @('main.tf', 'providers.tf', 'variables.tf', 'outputs.tf', 'versions.tf', '.terraform.lock.hcl', 'terraform.rc', 'backend.json', 'inputs.tfvars.json', 'reservation.tfplan', 'reservation.json')
    if ($Sha256 -cnotmatch '^[0-9a-f]{64}$' -or (Get-SnapshotHash $Review) -cne $Sha256 -or $Review.definitionSha256 -cne $DefinitionSha256 -or
        $Review.sourceSha256 -cne $SourceSha256 -or [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $Review.createdAt -gt 86400 -or $Review.createdAt -gt [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 60 -or
        (@($Review.files.Keys | Sort-Object) -join ',') -cne (@($names | Sort-Object) -join ',')) { throw 'lifecycle.ephemeral.reviewStale' }
    foreach ($name in $names) { if ((Get-LifecycleFileHash (Join-Path $Directory $name)) -cne $Review.files[$name]) { throw 'lifecycle.ephemeral.reviewChanged' } }
}

Export-ModuleMember -Function Read-EphemeralEnvironment, Assert-EphemeralSelection, New-EphemeralWorkspace, Resolve-EphemeralWorkspacePath, Invoke-EphemeralGithub, Assert-EphemeralRepository, Get-EphemeralGithubProtection, Set-EphemeralGithubProtection, Assert-EphemeralTrackedDefinition, Assert-EphemeralReservationPlan, Assert-EphemeralReservationReview, Assert-EphemeralBootstrapStorage, Test-EphemeralIsolation
