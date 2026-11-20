Set-StrictMode -Version Latest

# Messaging operations of Azure Service Bus. MessagingOperations.psm1 discovers this module and calls these
# functions inside it; it exports nothing.

function Get-OperationsProvider { return 'azure-service-bus' }

# <Name>Contracts.psm1, Test-<Name>Policy.ps1 and ConvertTo-<Name>TerraformInput validate its topology.
function Get-OperationsContracts { return 'AzureServiceBus' }

function Get-OperationsTopologyKind { return 'AzureServiceBusPolicy' }

# The broker integration tests of Hexagon.Messaging.Operations.Tests that the CI runs for this provider.
function Get-OperationsRuntimeTests { return 'AzureRuntimeTests' }

function Get-OperationsWorkloadIdentities($Topology) { return @($Topology.workloadPrincipalIds.PSObject.Properties.Value) }

function Assert-OperationsIdentities([object[]] $Identities) {
    foreach ($identity in $Identities) {
        $principal = [guid]::Empty
        if (-not [guid]::TryParseExact($identity, 'D', [ref] $principal) -or $principal -eq [guid]::Empty) {
            throw 'Azure operator identities must be principal UUIDs.'
        }
    }
}

function Assert-OperationsNotifications($Operations) {
    if ($Operations.notificationTargets.Count -eq 0) { throw 'Cloud alerts require notification targets.' }
    foreach ($target in $Operations.notificationTargets) {
        if ($target -cnotmatch '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[A-Za-z0-9._()-]+/providers/Microsoft.Insights/actionGroups/[A-Za-z0-9._()-]+$') {
            throw 'Invalid notification target for this provider.'
        }
    }
}

# Every subscription has its dead-letter subqueue.
function Test-OperationsDeadLetter($Physical) { return $true }

function Assert-OperationsConsumer($Consumer, $Physical, [bool] $HasDeadLetter) {
    if ($null -ne $Consumer.oldestMessageAgeSeconds) { throw 'This provider has no supported per-queue oldest-message-age metric.' }
}

function Get-OperationsTerraformMapping($Outputs) { return $Outputs.azure_service_bus.value }

function Set-OperationsTarget($Target, $Topology, $Physical, $Actual, $Destination, $Mapping) {
    $target = $Target; $topology = $Topology; $physical = $Physical; $actual = $Actual; $destination = $Destination; $mapping = $Mapping
    if ($mapping.namespace.name -cne $topology.namespace.name -or $actual.topic_name -cne $destination.name) {
        throw 'Terraform namespace or topic differs from the validated topology.'
    }
    $target.namespace = "$($topology.namespace.name).servicebus.windows.net"
    $target.topic = $destination.name
    $target.subscription = $physical.name
    $target.hasDeadLetter = $true
}

Export-ModuleMember -Function @()
