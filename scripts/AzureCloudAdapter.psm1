Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
foreach ($name in @('LifecycleNative', 'AzureEnvironmentStore', 'AzureApplicationDelivery')) { Import-Module (Join-Path $PSScriptRoot "$name.psm1") }

# The Azure adapter of the lifecycle and the delivery (ADR 0016): a Blob container keeps the journal and
# the lease, and the identity comes from the federated credential of the workflow.
# Functions of the cloud adapter contract (docs/separacion-por-nube.md). CloudAdapters.psm1 calls them
# inside this module; the module exports nothing.

function Test-CloudTarget([hashtable] $Target) { return $Target.ContainsKey('subscriptionId') -and -not $Target.ContainsKey('accountId') }

function Get-CloudName { return 'azure' }

function Get-CloudTargetDetails([hashtable] $Inventory, [string] $GithubEnvironment) {
    return @{ provider = 'azure'; clientId = $Inventory.target.clientId; tenantId = $Inventory.target.tenantId; subscriptionId = $Inventory.target.subscriptionId; githubEnvironment = $GithubEnvironment }
}

function Get-CloudEnvironmentEntry { return 'Invoke-AzureEnvironment.ps1' }

function Get-CloudEnvironmentResultVersion { return 'hexagon.ec/azure-environment-result/v1' }

function Get-CloudStoreDescription { return 'the instance Blob container' }

# The database credentials are managed identities: there is no DatabaseCredentials stage (ADR 0024).
function Test-CloudDeliveryStage([string] $Stage) { return $Stage -cne 'DatabaseCredentials' }

function Enter-CloudLifecycle([hashtable] $Inventory, [bool] $AssertCli) {
    $context = New-AzureLifecycleContext $Inventory
    Enter-AzureLifecycleLease $context -Confirm:$false
    return $context
}

function Get-CloudLifecycleJournal([hashtable] $Context) { return Get-AzureLifecycleJournal $Context }

function Exit-CloudLifecycle([hashtable] $Context) { Exit-AzureLifecycleLease $Context -Confirm:$false }

function Invoke-CloudApplicationStage([hashtable] $Context, [hashtable] $Delivery, [hashtable] $Release, [string] $DeliverySha256, [string] $Stage,
    [string] $Repository, [string] $TrustedCommit, [string] $Workspace, [string] $ReviewSha256, [string] $Confirmation) {
    return Invoke-AzureApplicationStage $Context $Delivery $Release $DeliverySha256 $Stage $Repository $TrustedCommit $Workspace $ReviewSha256 $Confirmation -Confirm:$false
}

Export-ModuleMember -Function @()
