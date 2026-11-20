Set-StrictMode -Version Latest

# Azure rules of the environment lifecycle: target, roots, resource scope, plan scope and the roots that
# the snapshot packages. EnvironmentLifecycle.psm1 discovers this module and calls these functions inside
# its scope; it exports nothing, so the modules of different clouds never collide.

# Never managed by an environment: the resource groups, the federation and the locks of the bootstrap.
$script:forbiddenTypes = @('azurerm_resource_group', 'azurerm_federated_identity_credential', 'azurerm_management_lock')
$script:rootAdapters = @{ hosting = 'AzureHosting'; messaging = 'AzureServiceBus' }

function Test-EnvironmentRulesTarget([hashtable] $Target) { return $Target.ContainsKey('subscriptionId') -and -not $Target.ContainsKey('accountId') }

function Test-EnvironmentRulesAdapter([string] $Adapter) { return $Adapter -cin @($script:rootAdapters.Values) }

function Assert-EnvironmentRulesTarget([hashtable] $Inventory) {
    foreach ($field in @('tenantId', 'subscriptionId', 'clientId')) {
        if ([guid] $Inventory.target[$field] -eq [guid]::Empty) { throw 'lifecycle.targetInvalid' }
    }
    if (-not $Inventory.target.container.EndsWith("-$($Inventory.environment)", [StringComparison]::Ordinal) -or $Inventory.target.container -match '--') { throw 'lifecycle.containerBoundary' }
}

function Get-EnvironmentRulesRootAdapter([string] $Id) { return $script:rootAdapters[$Id] }

# Every root lives in its own resource group, named after the instance and never the one of the state.
function Assert-EnvironmentRulesRootScope([hashtable] $Inventory, [hashtable] $Root, [hashtable] $Seen) {
    if (-not $Seen.ContainsKey('groups')) { $Seen.groups = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase) }
    if (-not $Seen.groups.Add($Root.resourceGroup)) { throw 'lifecycle.rootDuplicate' }
    if ($Root.resourceGroup -ieq $Inventory.target.stateResourceGroup) { throw 'lifecycle.bootstrapProtected' }
    $groupPrefix = "rg-$($Inventory.product)-$($Inventory.environment)"
    if ($Inventory.instance.kind -ceq 'Ephemeral') { $groupPrefix += "-$($Inventory.instance.id)" }
    if ($Root.resourceGroup -cne "$groupPrefix-$($Root.id)") { throw 'lifecycle.groupBoundary' }
}

function Get-EnvironmentRulesRootBinding([hashtable] $Root) { return @{ resourceGroup = $Root.resourceGroup } }

# Azure resource IDs are already scoped by subscription and resource group.
function ConvertTo-EnvironmentRulesResourceId([hashtable] $Inventory, [string] $Type, [string] $Id) { return $Id }

function Assert-EnvironmentRulesResource([hashtable] $Inventory, [hashtable] $Root, [string] $Id, [string] $Type) {
    $prefix = "/subscriptions/$($Inventory.target.subscriptionId)/resourceGroups/$($Root.resourceGroup)/providers/"
    if (-not $Id.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
        $Id -match '[?#%\\\s]|/(?:[.][.]?|)(?:/|$)' -or
        $Type -in $script:forbiddenTypes) { throw 'lifecycle.resourceOutsideScope' }
}

function Test-EnvironmentRulesPlanTypeForbidden([string] $Type) { return $Type -cnotmatch '^azurerm_' -or $Type -cin $script:forbiddenTypes }

function Assert-EnvironmentRulesPlanScope([hashtable] $Inventory, [hashtable] $Root, [hashtable] $After) {
    if ($After.ContainsKey('resource_group_name') -and $After.resource_group_name -ine $Root.resourceGroup) { throw 'lifecycle.planScopeMismatch' }
    if ($After.ContainsKey('scope') -and $After.scope) {
        $scope = "/subscriptions/$($Inventory.target.subscriptionId)/resourceGroups/$($Root.resourceGroup)"
        if ($After.scope -ine $scope -and -not $After.scope.StartsWith("$scope/", [StringComparison]::OrdinalIgnoreCase)) { throw 'lifecycle.planScopeMismatch' }
    }
}

function Test-EnvironmentRulesPreflightTarget([hashtable] $Inventory, [Collections.IDictionary] $Result) {
    return $Result.tenantId -ieq $Inventory.target.tenantId -and $Result.subscriptionId -ieq $Inventory.target.subscriptionId -and
        $Result.clientId -ieq $Inventory.target.clientId -and $Result.container -ceq $Inventory.target.container
}

function Test-EnvironmentRulesStore([hashtable] $Inventory, [Collections.IDictionary] $Result) {
    return $Result.storageAccount -ceq $Inventory.target.storageAccount -and $Result.container -ceq $Inventory.target.container
}

function Get-EnvironmentRulesRootPaths([string] $Adapter, [string] $Id, [string] $Environment) {
    if ($Adapter -ceq 'AzureHosting' -and $Id -ceq 'hosting') { return @("terraform/environments/$Environment/hosting-azure", 'terraform/modules/hosting/azure') }
    if ($Adapter -ceq 'AzureServiceBus' -and $Id -ceq 'messaging') { return @("terraform/environments/$Environment/azure", 'terraform/modules/messaging/azure-service-bus') }
    throw 'lifecycle.snapshotRootUnknown'
}

# The inputs name the resource group of their root.
function Test-EnvironmentRulesInputsScope([hashtable] $Inventory, [hashtable] $Root, [hashtable] $Inputs) {
    return $Inputs.resource_group_name -ceq $Root.resourceGroup
}

Export-ModuleMember -Function @()
