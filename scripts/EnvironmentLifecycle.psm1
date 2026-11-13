Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PlatformBootstrap.psm1')
$script:lifecycleSchema = Join-Path (Split-Path -Parent $PSScriptRoot) 'contracts/schemas/environment-inventory-v1.schema.json'
# Never managed by an environment: federation, static credentials and the bootstrap boundaries (ADR 0012, ADR 0025).
$script:awsForbiddenTypes = @('aws_iam_openid_connect_provider', 'aws_iam_user', 'aws_iam_access_key', 'aws_iam_user_policy', 'aws_iam_user_policy_attachment')

function Resolve-LifecycleFilePath([string] $Path) {
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Get-LifecycleFileHash([string] $Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-LifecycleValueHash([object] $Value) {
    $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-PlatformBootstrapJson $Value))
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Get-LifecycleProvider([hashtable] $Inventory) {
    return $(if ($Inventory.target.ContainsKey('accountId')) { 'aws' } else { 'azure' })
}

# The short AWS prefix of an instance (ADR 0025): the base alone when persistent, plus six hex characters
# of SHA-256(product/environment/instance) when ephemeral, so that it fits the 19 characters of name_prefix.
function Get-LifecycleAwsPrefixSuffix([hashtable] $Inventory) {
    $bytes = [Text.Encoding]::UTF8.GetBytes("$($Inventory.product)/$($Inventory.environment)/$($Inventory.instance.id)")
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant().Substring(0, 6)
}

# Terraform IDs of AWS resources are not scoped (vpc-..., names, URLs): the inventory qualifies them.
function ConvertTo-LifecycleResourceId([hashtable] $Inventory, [string] $Type, [string] $Id) {
    if ((Get-LifecycleProvider $Inventory) -ceq 'aws') { return "aws:$($Inventory.target.accountId):$($Inventory.target.region):$($Type):$Id" }
    return $Id
}

function Get-EnvironmentRootOrder {
    param([hashtable] $Inventory, [ValidateSet('Create', 'Destroy')][string] $Operation)
    $remaining = [Collections.Generic.List[object]]::new()
    foreach ($root in $Inventory.roots) { $remaining.Add($root) }
    $ordered = [Collections.Generic.List[string]]::new()
    while ($remaining.Count -gt 0) {
        $next = @($remaining | Where-Object { @($_.dependsOn | Where-Object { -not $ordered.Contains($_) }).Count -eq 0 } | Sort-Object id)
        if ($next.Count -eq 0) { throw 'lifecycle.dependencyCycle' }
        foreach ($root in $next) { $ordered.Add($root.id); [void] $remaining.Remove($root) }
    }
    $result = $ordered.ToArray()
    if ($Operation -ceq 'Destroy') { [array]::Reverse($result) }
    return $result
}

function Get-LifecycleBindingHash([hashtable] $Inventory) {
    return Get-LifecycleValueHash @{
        product = $Inventory.product; environment = $Inventory.environment; instance = $Inventory.instance
        target = $Inventory.target; iac = $Inventory.iac; descriptorSha256 = $Inventory.descriptorSha256
        releaseSha256 = $Inventory.releaseSha256; components = $Inventory.components; dataPolicy = $Inventory.dataPolicy
        roots = @($Inventory.roots | Sort-Object id | ForEach-Object {
            $binding = @{ id = $_.id; adapter = $_.adapter; dependsOn = $_.dependsOn
                stateKey = $_.stateKey; configurationSha256 = $_.configurationSha256; inputsSha256 = $_.inputsSha256 }
            if ($_.ContainsKey('namePrefix')) { $binding.namePrefix = $_.namePrefix } else { $binding.resourceGroup = $_.resourceGroup }
            $binding
        })
        observedStates = @($Inventory.roots | Sort-Object id | ForEach-Object {
            @{ id = $_.id; lineage = $_.stateLineage; serial = $_.stateSerial; resources = $_.resources; lastOperation = $_.lastOperation }
        })
    }
}

function Assert-LifecycleResource {
    param([hashtable] $Inventory, [hashtable] $Root, [string] $Id, [string] $Type)
    if ((Get-LifecycleProvider $Inventory) -ceq 'aws') {
        $scope = "aws:$($Inventory.target.accountId):$($Inventory.target.region):$($Type):"
        if ($Type -cnotmatch '^aws_[a-z0-9_]+$' -or $Type -cin $script:awsForbiddenTypes -or -not $Id.StartsWith($scope, [StringComparison]::Ordinal) -or
            $Id.Length -eq $scope.Length -or $Id -match '\s') { throw 'lifecycle.resourceOutsideScope' }
        $raw = $Id.Substring($scope.Length)
        if (($Type -ceq 'aws_s3_bucket' -and $raw -ceq $Inventory.target.stateBucket) -or
            ($Type -ceq 'aws_iam_role' -and $raw -ceq ($Inventory.target.roleArn -split '/')[-1])) { throw 'lifecycle.bootstrapProtected' }
        return
    }
    $prefix = "/subscriptions/$($Inventory.target.subscriptionId)/resourceGroups/$($Root.resourceGroup)/providers/"
    if (-not $Id.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
        $Id -match '[?#%\\\s]|/(?:[.][.]?|)(?:/|$)' -or
        $Type -in @('azurerm_resource_group', 'azurerm_federated_identity_credential', 'azurerm_management_lock')) { throw 'lifecycle.resourceOutsideScope' }
}

function Assert-EnvironmentInventory {
    param([hashtable] $Inventory)
    $json = ConvertTo-PlatformBootstrapJson $Inventory
    if (-not ($json | Test-Json -SchemaFile $script:lifecycleSchema -ErrorAction SilentlyContinue)) { throw 'lifecycle.inventoryInvalid' }
    $aws = (Get-LifecycleProvider $Inventory) -ceq 'aws'
    if ($aws) {
        $key = $Inventory.target.stateKmsKeyArn -split ':'
        if (($Inventory.target.roleArn -split ':')[4] -cne $Inventory.target.accountId -or $key[4] -cne $Inventory.target.accountId -or $key[3] -cne $Inventory.target.region) { throw 'lifecycle.targetInvalid' }
    }
    else {
        foreach ($field in @('tenantId', 'subscriptionId', 'clientId')) {
            if ([guid] $Inventory.target[$field] -eq [guid]::Empty) { throw 'lifecycle.targetInvalid' }
        }
    }
    $ephemeral = $Inventory.instance.kind -ceq 'Ephemeral'
    if (($ephemeral -and $Inventory.instance.id -ceq 'persistent') -or (-not $ephemeral -and $Inventory.instance.id -cne 'persistent')) { throw 'lifecycle.instanceInvalid' }
    if ($Inventory.dataPolicy -ceq 'DeleteEphemeral' -and (-not $ephemeral -or $Inventory.environment -ceq 'prod')) { throw 'lifecycle.dataPolicyInvalid' }
    if (-not $aws -and (-not $Inventory.target.container.EndsWith("-$($Inventory.environment)", [StringComparison]::Ordinal) -or $Inventory.target.container -match '--')) { throw 'lifecycle.containerBoundary' }
    if (($Inventory.iac.repository -split '/')[1] -cne "$($Inventory.product)-devops") { throw 'lifecycle.repositoryBoundary' }
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $groups = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $prefixes = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($root in $Inventory.roots) {
        if (-not $ids.Add($root.id)) { throw 'lifecycle.rootDuplicate' }
        $kind = $(if ($aws) { if ($root.id -ceq 'hosting') { 'AwsHosting' } else { 'AwsSnsSqs' } } elseif ($root.id -ceq 'hosting') { 'AzureHosting' } else { 'AzureServiceBus' })
        if ($root.adapter -cne $kind -or $root.stateKey -cne "$($Inventory.product)/$($Inventory.environment)/$($Inventory.instance.id)/$($root.id).tfstate") { throw 'lifecycle.rootBoundary' }
        if ($aws) {
            # Every root of an AWS instance shares its short prefix; the tags keep the full names.
            $expected = $(if ($ephemeral) { "^[a-z][a-z0-9-]{1,10}[a-z0-9]-$(Get-LifecycleAwsPrefixSuffix $Inventory)$" } else { '^[a-z][a-z0-9-]{1,10}[a-z0-9]$' })
            if ($root.namePrefix -cnotmatch $expected -or $root.namePrefix -match '--') { throw 'lifecycle.prefixBoundary' }
            [void] $prefixes.Add($root.namePrefix)
        }
        else {
            if (-not $groups.Add($root.resourceGroup)) { throw 'lifecycle.rootDuplicate' }
            if ($root.resourceGroup -ieq $Inventory.target.stateResourceGroup) { throw 'lifecycle.bootstrapProtected' }
            $groupPrefix = "rg-$($Inventory.product)-$($Inventory.environment)"
            if ($ephemeral) { $groupPrefix += "-$($Inventory.instance.id)" }
            if ($root.resourceGroup -cne "$groupPrefix-$($root.id)") { throw 'lifecycle.groupBoundary' }
        }
        if ($root.status -cin @('Applying', 'Destroying') -and $null -eq $root.lastOperation) { throw 'lifecycle.transitionInvalid' }
        if ($null -ne $root.plan -and $root.plan.rootId -cne $root.id) { throw 'lifecycle.planRootMismatch' }
        if (($null -eq $root.stateLineage -and $root.stateSerial -ne 0) -or
            ($null -ne $root.plan -and $root.status -cnotin @('Planned', 'Applying', 'Destroying')) -or
            ($root.status -ceq 'Planned' -and $null -eq $root.plan) -or
            ($root.status -ceq 'Verified' -and $root.lastOperation -cne 'Create') -or
            ($root.status -ceq 'Destroyed' -and $root.lastOperation -cne 'Destroy')) { throw 'lifecycle.transitionInvalid' }
        if ($root.status -ceq 'Verified' -and (@($root.resources | Where-Object current -EQ $true).Count -eq 0 -or
            @($root.resources | Where-Object { ($_.current -and $_.presence -cne 'Present') -or (-not $_.current -and $_.presence -cne 'Missing') }).Count -gt 0)) { throw 'lifecycle.verificationInvalid' }
        if ($root.status -ceq 'Destroyed' -and @($root.resources | Where-Object { $_.presence -cne 'Missing' -or $_.current }).Count -gt 0) { throw 'lifecycle.verificationInvalid' }
        $resources = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($resource in $root.resources) {
            Assert-LifecycleResource $Inventory $root $resource.id $resource.type
            if (-not $resources.Add($resource.id)) { throw 'lifecycle.resourceDuplicate' }
        }
    }
    if ($prefixes.Count -gt 1) { throw 'lifecycle.prefixBoundary' }
    if (-not $ids.Contains('hosting') -or ($ids.Contains('messaging') -and $Inventory.components -cnotcontains 'backend')) { throw 'lifecycle.componentUncovered' }
    foreach ($root in $Inventory.roots) {
        foreach ($dependency in $root.dependsOn) { if (-not $ids.Contains($dependency) -or $dependency -ceq $root.id) { throw 'lifecycle.dependencyInvalid' } }
        if ($root.id -ceq 'messaging' -and $ids.Contains('hosting') -and $root.dependsOn -cnotcontains 'hosting') { throw 'lifecycle.dependencyInvalid' }
    }
    Get-EnvironmentRootOrder $Inventory Create | Out-Null
}

function Read-EnvironmentInventory {
    param([Parameter(Mandatory)][string] $Path)
    $Path = Resolve-LifecycleFilePath $Path
    try {
        if ((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'lifecycle.inventoryLink' }
        if ((Get-Item -LiteralPath $Path).Length -gt 4194304) { throw 'lifecycle.inventoryInvalid' }
        $json = Get-Content -Raw -LiteralPath $Path
        if (-not ($json | Test-Json -SchemaFile $script:lifecycleSchema -ErrorAction SilentlyContinue)) { throw 'lifecycle.inventoryInvalid' }
        $inventory = $json | ConvertFrom-Json -AsHashtable -Depth 32
        Assert-EnvironmentInventory $inventory
        return $inventory
    }
    catch {
        if ($_.Exception.Message -cmatch '^lifecycle[.][A-Za-z0-9.]+$') { throw }
        throw 'lifecycle.inventoryInvalid'
    }
}

function Enter-LifecycleLock([string] $Path) {
    $absolute = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetDirectoryName($absolute)
    while ($parent) {
        if ((Get-Item -LiteralPath $parent -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'lifecycle.inventoryLink' }
        $parent = [IO.Path]::GetDirectoryName($parent)
    }
    if ((Test-Path -LiteralPath "$absolute.lock") -and ((Get-Item -LiteralPath "$absolute.lock" -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'lifecycle.inventoryLink' }
    try { return [IO.File]::Open("$absolute.lock", [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch { throw 'lifecycle.inventoryLocked' }
}

function Write-LifecycleInventory {
    param([hashtable] $Inventory, [string] $Path, [switch] $New)
    Assert-EnvironmentInventory $Inventory
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-PlatformBootstrapJson $Inventory) + "`n")
    if ($bytes.Length -gt 4194304) { throw 'lifecycle.inventoryTooLarge' }
    if ($New) {
        $file = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $file.Write($bytes); $file.Flush($true) } finally { $file.Dispose() }
    }
    else {
        $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
        $file = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $file.Write($bytes); $file.Flush($true) } finally { $file.Dispose() }
        try { [IO.File]::Move($temporary, $Path, $true) }
        finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
    }
}

function Assert-EnvironmentInitialInventory {
    param([hashtable] $Inventory)
    Assert-EnvironmentInventory $Inventory
    if ($Inventory.revision -ne 0 -or @($Inventory.roots | Where-Object { $_.status -cne 'Pending' -or $_.resources.Count -ne 0 -or $null -ne $_.plan -or $null -ne $_.lastOperation -or $null -ne $_.stateLineage -or $_.stateSerial -ne 0 -or $null -ne $_.errorCode }).Count -gt 0) { throw 'lifecycle.initialStateInvalid' }
}

function New-EnvironmentInventory {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([hashtable] $Inventory, [string] $Path)
    $Path = Resolve-LifecycleFilePath $Path
    Assert-EnvironmentInitialInventory $Inventory
    if (-not $PSCmdlet.ShouldProcess($Path, 'Create lifecycle inventory')) { return }
    $lock = Enter-LifecycleLock $Path
    try { Write-LifecycleInventory $Inventory $Path -New }
    finally { $lock.Dispose() }
    return Get-LifecycleFileHash $Path
}

function Assert-LifecycleDependencies {
    param([hashtable] $Inventory, [hashtable] $Root, [string] $Operation)
    if ($Root.status -cin @('Applying', 'Destroying')) { throw 'lifecycle.reconciliationRequired' }
    if ($Operation -ceq 'Create') {
        foreach ($id in $Root.dependsOn) { if (@($Inventory.roots | Where-Object { $_.id -ceq $id -and $_.status -ceq 'Verified' }).Count -ne 1) { throw 'lifecycle.dependencyNotReady' } }
    }
    else {
        foreach ($other in $Inventory.roots) { if ($other.dependsOn -ccontains $Root.id -and $other.status -cne 'Destroyed') { throw 'lifecycle.dependentNotDestroyed' } }
    }
}

function Assert-EnvironmentTerraformPlan {
    param([hashtable] $Inventory, [hashtable] $Root, [ValidateSet('Create', 'Destroy')][string] $Operation, [hashtable] $Plan)
    if ($Plan.format_version -cnotmatch '^1[.]' -or $Plan.errored -isnot [bool] -or $Plan.errored -ne $false -or $Plan.complete -isnot [bool] -or $Plan.complete -ne $true -or
        ($Plan.ContainsKey('deferred_changes') -and @($Plan.deferred_changes).Count -gt 0) -or
        ($Plan.ContainsKey('deferred_action_invocations') -and @($Plan.deferred_action_invocations).Count -gt 0) -or
        ($Plan.ContainsKey('action_invocations') -and @($Plan.action_invocations).Count -gt 0)) { throw 'lifecycle.planIncomplete' }
    $aws = (Get-LifecycleProvider $Inventory) -ceq 'aws'
    $known = @{}; foreach ($resource in $Root.resources) { $known[$resource.id.ToLowerInvariant()] = $resource.address }
    $changes = @()
    if ($Plan.ContainsKey('resource_changes')) {
        if ($Plan.resource_changes -isnot [Collections.IList]) { throw 'lifecycle.planIncomplete' }
        $changes = $Plan.resource_changes
    }
    foreach ($change in $changes) {
        if ($change.mode -ceq 'data') { continue }
        $forbidden = $(if ($aws) { $change.type -cnotmatch '^aws_' -or $change.type -cin $script:awsForbiddenTypes }
            else { $change.type -cnotmatch '^azurerm_' -or $change.type -cin @('azurerm_resource_group', 'azurerm_federated_identity_credential', 'azurerm_management_lock') })
        if ($change.mode -cne 'managed' -or $forbidden) { throw 'lifecycle.planResourceForbidden' }
        if ($change.change.ContainsKey('importing') -and $null -ne $change.change.importing) { throw 'lifecycle.planImportForbidden' }
        foreach ($action in $change.change.actions) {
            if (($Operation -ceq 'Create' -and $action -cnotin @('no-op', 'create', 'update')) -or ($Operation -ceq 'Destroy' -and $action -cnotin @('no-op', 'delete'))) { throw 'lifecycle.planOperationMismatch' }
        }
        $before = $null; if ($change.change.ContainsKey('before')) { $before = $change.change.before }
        if ($Operation -ceq 'Destroy' -and $change.change.actions -ccontains 'delete' -and ($null -eq $before -or -not $before.ContainsKey('id') -or -not $before.id)) { throw 'lifecycle.planResourceUnrecorded' }
        if ($null -ne $before -and $before.ContainsKey('id') -and $before.id) {
            $beforeId = ConvertTo-LifecycleResourceId $Inventory $change.type $before.id
            Assert-LifecycleResource $Inventory $Root $beforeId $change.type
            if (-not $known.ContainsKey($beforeId.ToLowerInvariant()) -or $known[$beforeId.ToLowerInvariant()] -cne $change.address) { throw 'lifecycle.planResourceUnrecorded' }
        }
        $after = $null; if ($change.change.ContainsKey('after')) { $after = $change.change.after }
        if ($null -ne $after) {
            if ($after.ContainsKey('id') -and $after.id) { Assert-LifecycleResource $Inventory $Root (ConvertTo-LifecycleResourceId $Inventory $change.type $after.id) $change.type }
            if ($aws) { Assert-LifecycleAwsPlanScope $Inventory $after; continue }
            if ($after.ContainsKey('resource_group_name') -and $after.resource_group_name -ine $Root.resourceGroup) { throw 'lifecycle.planScopeMismatch' }
            if ($after.ContainsKey('scope') -and $after.scope) {
                $scope = "/subscriptions/$($Inventory.target.subscriptionId)/resourceGroups/$($Root.resourceGroup)"
                if ($after.scope -ine $scope -and -not $after.scope.StartsWith("$scope/", [StringComparison]::OrdinalIgnoreCase)) { throw 'lifecycle.planScopeMismatch' }
            }
        }
    }
}

function Assert-LifecycleAwsPlanScope {
    param([hashtable] $Inventory, [hashtable] $After)
    # An ARN known at plan time must belong to the account and, when regional, to the region.
    if ($After.ContainsKey('arn') -and $After.arn -is [string] -and $After.arn) {
        $parts = $After.arn -split ':'
        if ($parts.Count -lt 6 -or $parts[0] -cne 'arn' -or $parts[1] -cne 'aws' -or
            ($parts[3] -and $parts[3] -cne $Inventory.target.region) -or ($parts[4] -and $parts[4] -cne $Inventory.target.accountId)) { throw 'lifecycle.planScopeMismatch' }
    }
    # Taggable resources carry the instance tags through the provider default_tags.
    if ($After.ContainsKey('tags_all') -and $After.tags_all -is [Collections.IDictionary]) {
        $tags = $After.tags_all
        if ($tags['hexagon:product'] -cne $Inventory.product -or $tags['hexagon:environment'] -cne $Inventory.environment -or
            $tags['hexagon:instance'] -cne $Inventory.instance.id) { throw 'lifecycle.planScopeMismatch' }
    }
}

function Add-EnvironmentRootPlan {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string] $InventoryPath, [string] $RootId, [ValidateSet('Create', 'Destroy')][string] $Operation,
        [string] $BinaryPath, [string] $JsonPath, [string] $ExpectedInventorySha256)
    $InventoryPath = Resolve-LifecycleFilePath $InventoryPath
    $BinaryPath = Resolve-LifecycleFilePath $BinaryPath; $JsonPath = Resolve-LifecycleFilePath $JsonPath
    if (-not $PSCmdlet.ShouldProcess($InventoryPath, "Register $Operation plan for $RootId")) { return }
    $lock = Enter-LifecycleLock $InventoryPath
    try {
        if ((Get-LifecycleFileHash $InventoryPath) -cne $ExpectedInventorySha256) { throw 'lifecycle.inventoryChanged' }
        $inventory = Read-EnvironmentInventory $InventoryPath
        $roots = @($inventory.roots | Where-Object id -CEQ $RootId)
        if ($roots.Count -ne 1) { throw 'lifecycle.rootUnknown' }; $root = $roots[0]
        Assert-LifecycleDependencies $inventory $root $Operation
        $plan = Get-Content -Raw -LiteralPath $JsonPath | ConvertFrom-Json -AsHashtable -Depth 100
        Assert-EnvironmentTerraformPlan $inventory $root $Operation $plan
        $inventory.revision++
        $review = @{
            rootId = $root.id
            operation = $Operation; binarySha256 = Get-LifecycleFileHash $BinaryPath; jsonSha256 = Get-LifecycleFileHash $JsonPath
            bindingSha256 = Get-LifecycleBindingHash $inventory; revision = $inventory.revision; createdAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        }
        $review.reviewSha256 = Get-LifecycleValueHash $review
        $root.plan = $review; $root.status = 'Planned'; $root.errorCode = $null
        Write-LifecycleInventory $inventory $InventoryPath
        return $review.reviewSha256
    }
    finally { $lock.Dispose() }
}

function Invoke-LifecyclePort {
    param([scriptblock] $Port, [string] $Action, [hashtable] $Inventory, [hashtable] $Root, [hashtable] $Extra = @{})
    $request = @{ action = $Action; product = $Inventory.product; environment = $Inventory.environment; instanceId = $Inventory.instance.id; target = $Inventory.target; root = $Root; revision = $Inventory.revision }
    foreach ($key in $Extra.Keys) { $request[$key] = $Extra[$key] }
    $requestCopy = (ConvertTo-PlatformBootstrapJson $request) | ConvertFrom-Json -AsHashtable -Depth 32
    try { $response = & $Port $requestCopy }
    catch { throw "lifecycle.port.$Action" }
    if ($null -eq $response -or $response -isnot [Collections.IDictionary]) { throw "lifecycle.port.$Action" }
    return $response
}

function Assert-LifecyclePreflight {
    param([hashtable] $Inventory, [hashtable] $Root, [scriptblock] $Port, [hashtable] $Artifacts = @{})
    $result = Invoke-LifecyclePort $Port Preflight $Inventory $Root $Artifacts
    $targetMatches = $(if ((Get-LifecycleProvider $Inventory) -ceq 'aws') {
            $result.accountId -ceq $Inventory.target.accountId -and $result.region -ceq $Inventory.target.region -and
            $result.roleArn -ceq $Inventory.target.roleArn -and $result.stateBucket -ceq $Inventory.target.stateBucket }
        else {
            $result.tenantId -ieq $Inventory.target.tenantId -and $result.subscriptionId -ieq $Inventory.target.subscriptionId -and
            $result.clientId -ieq $Inventory.target.clientId -and $result.container -ceq $Inventory.target.container })
    if ($result.verified -isnot [bool] -or $result.verified -ne $true -or -not $targetMatches -or $result.product -cne $Inventory.product -or $result.environment -cne $Inventory.environment -or $result.instanceId -cne $Inventory.instance.id -or
        $result.configurationSha256 -cne $Root.configurationSha256 -or $result.inputsSha256 -cne $Root.inputsSha256 -or $result.iacSnapshotSha256 -cne $Inventory.iac.snapshotSha256 -or
        $result.stateKey -cne $Root.stateKey) { throw 'lifecycle.preflightMismatch' }
    if ($Artifacts.Count -gt 0 -and ($result.planVerified -isnot [bool] -or $result.planVerified -ne $true -or
        $result.binarySha256 -cne $Root.plan.binarySha256 -or $result.jsonSha256 -cne $Root.plan.jsonSha256)) { throw 'lifecycle.planNotVerified' }
}

function Save-LifecycleCheckpoint {
    param([hashtable] $Inventory, [hashtable] $Root, [string] $Path, [scriptblock] $Port)
    $Inventory.revision++
    Write-LifecycleInventory $Inventory $Path
    $hash = Get-LifecycleFileHash $Path
    $result = Invoke-LifecyclePort $Port Persist $Inventory $Root @{ inventoryPath = $Path; sha256 = $hash }
    $journalKey = "$($Inventory.product)/$($Inventory.environment)/$($Inventory.instance.id)/inventory.json"
    $storeMatches = $(if ((Get-LifecycleProvider $Inventory) -ceq 'aws') { $result.stateBucket -ceq $Inventory.target.stateBucket }
        else { $result.storageAccount -ceq $Inventory.target.storageAccount -and $result.container -ceq $Inventory.target.container })
    if ($result.durable -isnot [bool] -or $result.durable -ne $true -or $result.sha256 -cne $hash -or $result.revision -ne $Inventory.revision -or
        $result.journalKey -cne $journalKey -or -not $storeMatches -or
        $result.snapshotSha256 -cne $Inventory.iac.snapshotSha256) { throw 'lifecycle.checkpointNotDurable' }
}

function Update-LifecycleObservation {
    param([hashtable] $Inventory, [hashtable] $Root, [hashtable] $Observation, [string] $Operation)
    foreach ($field in @('resources', 'probes', 'remainingResourceIds')) {
        if (-not $Observation.ContainsKey($field) -or $Observation[$field] -isnot [Collections.IList]) { throw 'lifecycle.observationIncomplete' }
    }
    if ($Observation.stateStatus -cnotin @('Present', 'Absent') -or $Observation.scopeAccessible -isnot [bool] -or $Observation.scopeAccessible -ne $true -or
        $Observation.scopeComplete -isnot [bool] -or $Observation.scopeComplete -ne $true) { throw 'lifecycle.observationUnavailable' }
    if ($Observation.stateStatus -ceq 'Present') {
        $parsedLineage = [guid]::Empty
        if (-not [guid]::TryParse([string] $Observation.lineage, [ref] $parsedLineage) -or $parsedLineage -eq [guid]::Empty -or $Observation.serial -isnot [long] -and $Observation.serial -isnot [int] -or $Observation.serial -lt $Root.stateSerial -or
            ($null -ne $Root.stateLineage -and $Observation.lineage -cne $Root.stateLineage)) { throw 'lifecycle.stateMismatch' }
    }
    elseif ($null -ne $Root.stateLineage -or $Observation.resources.Count -gt 0 -or $Observation.remainingResourceIds.Count -gt 0) { throw 'lifecycle.stateMissing' }
    $resources = @{}; foreach ($resource in $Root.resources) { $resources[$resource.id.ToLowerInvariant()] = @{} + $resource; $resources[$resource.id.ToLowerInvariant()].current = $false }
    $currentIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $currentAddresses = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($resource in $Observation.resources) {
        Assert-LifecycleResource $Inventory $Root $resource.id $resource.type
        if (-not $currentIds.Add($resource.id) -or -not $currentAddresses.Add($resource.address)) { throw 'lifecycle.stateResourceDuplicate' }
        $resources[$resource.id.ToLowerInvariant()] = @{ id = $resource.id; address = $resource.address; type = $resource.type; presence = 'Unknown'; current = $true }
    }
    $probes = @{}
    foreach ($probe in $Observation.probes) {
        if ($probe.status -cnotin @('Present', 'Missing') -or $probes.ContainsKey($probe.id.ToLowerInvariant())) { throw 'lifecycle.resourceProbeUnavailable' }
        $probes[$probe.id.ToLowerInvariant()] = $probe.status
    }
    foreach ($id in $resources.Keys) {
        if (-not $probes.ContainsKey($id)) { throw 'lifecycle.resourceProbeMissing' }
        $resources[$id].presence = $probes[$id]
    }
    if ($probes.Count -ne $resources.Count) { throw 'lifecycle.resourceProbeUnexpected' }
    $Root.resources = @($resources.Values | Sort-Object id)
    if ($Observation.stateStatus -ceq 'Present') { $Root.stateLineage = $Observation.lineage; $Root.stateSerial = $Observation.serial }
    if ($Operation -ceq 'Create') {
        if ($Observation.configurationConverged -isnot [bool] -or $Observation.configurationConverged -ne $true -or $Observation.resources.Count -eq 0 -or
            @($Root.resources | Where-Object { ($_.current -and $_.presence -cne 'Present') -or (-not $_.current -and $_.presence -cne 'Missing') }).Count -gt 0) { throw 'lifecycle.creationNotVerified' }
        $Root.status = 'Verified'
    }
    else {
        if ($Observation.resources.Count -gt 0 -or $Observation.remainingResourceIds.Count -gt 0 -or @($Root.resources | Where-Object presence -CNE 'Missing').Count -gt 0) { throw 'lifecycle.destructionNotVerified' }
        $Root.status = 'Destroyed'
    }
}

function Invoke-EnvironmentRootOperation {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string] $InventoryPath, [string] $RootId, [string] $BinaryPath, [string] $JsonPath,
        [string] $ReviewSha256, [string] $Confirmation, [Parameter(Mandatory)][scriptblock] $Port)
    $InventoryPath = Resolve-LifecycleFilePath $InventoryPath
    $BinaryPath = Resolve-LifecycleFilePath $BinaryPath; $JsonPath = Resolve-LifecycleFilePath $JsonPath
    if (-not $PSCmdlet.ShouldProcess($InventoryPath, "Execute reviewed operation for $RootId")) { return }
    $lock = Enter-LifecycleLock $InventoryPath
    try {
        $inventory = Read-EnvironmentInventory $InventoryPath
        $roots = @($inventory.roots | Where-Object id -CEQ $RootId)
        if ($roots.Count -ne 1) { throw 'lifecycle.rootUnknown' }; $root = $roots[0]
        if ($null -eq $root.plan) { throw 'lifecycle.reviewRequired' }
        $review = $root.plan; $operation = $review.operation
        $envelope = @{} + $review; $envelope.Remove('reviewSha256')
        $age = [DateTimeOffset]::UtcNow - [DateTimeOffset]::FromUnixTimeSeconds($review.createdAt)
        if ($root.status -cne 'Planned' -or $review.reviewSha256 -cne $ReviewSha256 -or (Get-LifecycleValueHash $envelope) -cne $ReviewSha256 -or
            $review.revision -ne $inventory.revision -or $review.bindingSha256 -cne (Get-LifecycleBindingHash $inventory) -or $age.TotalHours -gt 24 -or $age.TotalSeconds -lt -60 -or
            (Get-LifecycleFileHash $BinaryPath) -cne $review.binarySha256 -or (Get-LifecycleFileHash $JsonPath) -cne $review.jsonSha256) { throw 'lifecycle.reviewStale' }
        if ($Confirmation -cne "$($operation.ToUpperInvariant()) $($inventory.product) $($inventory.environment) $($inventory.instance.id)") { throw 'lifecycle.confirmationMismatch' }
        Assert-LifecycleDependencies $inventory $root $operation
        Assert-LifecyclePreflight $inventory $root $Port @{ binaryPath = [IO.Path]::GetFullPath($BinaryPath); jsonPath = [IO.Path]::GetFullPath($JsonPath) }
        if ($operation -ceq 'Destroy') {
            $safety = Invoke-LifecyclePort $Port DestructionSafety $inventory $root
            if ($safety.quiesced -isnot [bool] -or $safety.quiesced -ne $true -or $safety.evidenceSha256 -cnotmatch '^[0-9a-f]{64}$' -or
                $safety.product -cne $inventory.product -or $safety.environment -cne $inventory.environment -or $safety.instanceId -cne $inventory.instance.id -or $safety.rootId -cne $root.id -or
                ($inventory.dataPolicy -ceq 'BackupRequired' -and ($safety.backupVerified -isnot [bool] -or $safety.backupVerified -ne $true))) { throw 'lifecycle.destructionSafetyMissing' }
        }
        $root.lastOperation = $operation; $root.status = $(if ($operation -ceq 'Create') { 'Applying' } else { 'Destroying' })
        try {
            Save-LifecycleCheckpoint $inventory $root $InventoryPath $Port
            if ((Get-LifecycleFileHash $BinaryPath) -cne $review.binarySha256 -or (Get-LifecycleFileHash $JsonPath) -cne $review.jsonSha256) { throw 'lifecycle.reviewStale' }
            $result = Invoke-LifecyclePort $Port Apply $inventory $root @{ binaryPath = [IO.Path]::GetFullPath($BinaryPath); binarySha256 = $review.binarySha256; operation = $operation }
            if (($result.exitCode -isnot [int] -and $result.exitCode -isnot [long]) -or $result.exitCode -ne 0) { throw 'lifecycle.applyFailed' }
            $observation = Invoke-LifecyclePort $Port Observe $inventory $root @{ operation = $operation }
            Update-LifecycleObservation $inventory $root $observation $operation
            $root.plan = $null; $root.errorCode = $null
            Save-LifecycleCheckpoint $inventory $root $InventoryPath $Port
        }
        catch {
            $root.status = 'Failed'; $root.plan = $null
            $root.errorCode = $(if ($_.Exception.Message -cmatch '^lifecycle[.][A-Za-z0-9.]+$') { $_.Exception.Message } else { 'lifecycle.operationFailed' })
            try { Save-LifecycleCheckpoint $inventory $root $InventoryPath $Port } catch { throw 'lifecycle.recoveryCheckpointFailed' }
            throw $root.errorCode
        }
        return @{ status = $root.status; applicationVerified = $false; revision = $inventory.revision }
    }
    finally { $lock.Dispose() }
}

function Sync-EnvironmentRoot {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string] $InventoryPath, [string] $RootId, [Parameter(Mandatory)][scriptblock] $Port)
    $InventoryPath = Resolve-LifecycleFilePath $InventoryPath
    if (-not $PSCmdlet.ShouldProcess($InventoryPath, "Reconcile $RootId")) { return }
    $lock = Enter-LifecycleLock $InventoryPath
    try {
        $inventory = Read-EnvironmentInventory $InventoryPath
        $roots = @($inventory.roots | Where-Object id -CEQ $RootId)
        if ($roots.Count -ne 1) { throw 'lifecycle.rootUnknown' }; $root = $roots[0]
        if ($null -eq $root.lastOperation) { throw 'lifecycle.noOperationToReconcile' }
        Assert-LifecyclePreflight $inventory $root $Port
        try {
            $observation = Invoke-LifecyclePort $Port Observe $inventory $root @{ operation = $root.lastOperation }
            Update-LifecycleObservation $inventory $root $observation $root.lastOperation
            $root.plan = $null; $root.errorCode = $null
        }
        catch { $root.status = 'Failed'; $root.plan = $null; $root.errorCode = 'lifecycle.reconciliationIncomplete' }
        Save-LifecycleCheckpoint $inventory $root $InventoryPath $Port
        return @{ status = $root.status; applicationVerified = $false; revision = $inventory.revision }
    }
    finally { $lock.Dispose() }
}

function Set-EnvironmentRootInputs {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string] $InventoryPath, [string] $RootId, [string] $InputsSha256, [string] $SnapshotSha256, [string] $ExpectedInventorySha256)
    $InventoryPath = Resolve-LifecycleFilePath $InventoryPath
    if ($InputsSha256 -cnotmatch '^[0-9a-f]{64}$' -or $SnapshotSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'lifecycle.inputsHashInvalid' }
    if (-not $PSCmdlet.ShouldProcess($InventoryPath, "Update protected inputs for $RootId")) { return }
    $lock = Enter-LifecycleLock $InventoryPath
    try {
        if ((Get-LifecycleFileHash $InventoryPath) -cne $ExpectedInventorySha256) { throw 'lifecycle.inventoryChanged' }
        $inventory = Read-EnvironmentInventory $InventoryPath
        if (@($inventory.roots | Where-Object status -CIn @('Applying', 'Destroying')).Count -gt 0) { throw 'lifecycle.reconciliationRequired' }
        $roots = @($inventory.roots | Where-Object id -CEQ $RootId)
        if ($roots.Count -ne 1) { throw 'lifecycle.rootUnknown' }; $root = $roots[0]
        $root.inputsSha256 = $InputsSha256; $root.plan = $null
        $root.status = $(if ($null -eq $root.lastOperation) { 'Pending' } else { 'Failed' })
        $root.errorCode = $(if ($null -eq $root.lastOperation) { $null } else { 'lifecycle.inputsChangedRequiresPlan' })
        $inventory.iac.snapshotSha256 = $SnapshotSha256; $inventory.revision++
        Write-LifecycleInventory $inventory $InventoryPath
    }
    finally { $lock.Dispose() }
}

function Clear-EnvironmentPlans {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string] $InventoryPath, [string] $ExpectedInventorySha256)
    $InventoryPath = Resolve-LifecycleFilePath $InventoryPath
    if (-not $PSCmdlet.ShouldProcess($InventoryPath, 'Discard reviewed plans before explicit quiescence')) { return }
    $lock = Enter-LifecycleLock $InventoryPath
    try {
        if ((Get-LifecycleFileHash $InventoryPath) -cne $ExpectedInventorySha256) { throw 'lifecycle.inventoryChanged' }
        $inventory = Read-EnvironmentInventory $InventoryPath
        if (@($inventory.roots | Where-Object status -CIn @('Applying', 'Destroying')).Count -gt 0) { throw 'lifecycle.reconciliationRequired' }
        $planned = @($inventory.roots | Where-Object { $null -ne $_.plan })
        if ($planned.Count -eq 0) { return }
        foreach ($root in $planned) {
            $root.plan = $null; $root.status = $(if ($null -eq $root.lastOperation) { 'Pending' } else { 'Failed' })
            $root.errorCode = $(if ($null -eq $root.lastOperation) { $null } else { 'lifecycle.reviewDiscarded' })
        }
        $inventory.revision++
        Write-LifecycleInventory $inventory $InventoryPath
    }
    finally { $lock.Dispose() }
}

Export-ModuleMember -Function Assert-EnvironmentInventory, Assert-EnvironmentInitialInventory, Read-EnvironmentInventory, New-EnvironmentInventory, Get-EnvironmentRootOrder, Get-LifecycleFileHash, Assert-EnvironmentTerraformPlan, Add-EnvironmentRootPlan, Invoke-EnvironmentRootOperation, Sync-EnvironmentRoot, Set-EnvironmentRootInputs, Clear-EnvironmentPlans, ConvertTo-LifecycleResourceId
