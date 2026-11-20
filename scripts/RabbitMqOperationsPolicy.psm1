Set-StrictMode -Version Latest

# Messaging operations of RabbitMQ. MessagingOperations.psm1 discovers this module and calls these
# functions inside it; it exports nothing.

function Get-OperationsProvider { return 'rabbitmq' }

# <Name>Contracts.psm1, Test-<Name>Policy.ps1 and ConvertTo-<Name>TerraformInput validate its topology.
function Get-OperationsContracts { return 'RabbitMq' }

function Get-OperationsTopologyKind { return 'RabbitMqPolicy' }

# The broker integration tests of Hexagon.Messaging.Operations.Tests that the CI runs for this provider.
function Get-OperationsRuntimeTests { return 'RabbitMqRuntimeTests' }

function Get-OperationsWorkloadIdentities($Topology) { return @($Topology.workloadUserNames.PSObject.Properties.Value) }

function Assert-OperationsIdentities([object[]] $Identities) { }

function Assert-OperationsNotifications($Operations) {
    if ($Operations.notificationTargets.Count -ne 0) {
        throw 'RabbitMQ routes notifications through Alertmanager, not cloud notification targets.'
    }
}

function Test-OperationsDeadLetter($Physical) { return [bool] $Physical.deadLetter.enabled }

function Assert-OperationsConsumer($Consumer, $Physical, [bool] $HasDeadLetter) {
    if ($null -ne $Consumer.oldestMessageAgeSeconds) { throw 'This provider has no supported per-queue oldest-message-age metric.' }
}

function Get-OperationsTerraformMapping($Outputs) { return $Outputs.messaging_topology.value }

function Set-OperationsTarget($Target, $Topology, $Physical, $Actual, $Destination, $Mapping) {
    $target = $Target; $topology = $Topology; $physical = $Physical; $actual = $Actual; $destination = $Destination; $mapping = $Mapping
    if ($mapping.virtual_host -cne $topology.virtualHost) { throw 'Terraform virtual host differs from topology.' }
    $target.virtualHost = $topology.virtualHost
    $target.sourceQueue = $physical.name
    $target.exchange = $destination.name
    $target.hasDeadLetter = $physical.dead_letter.enabled
    $target.deadLetterQueue = if ($physical.dead_letter.enabled) { $actual.dead_letter.queue_name } else { '' }
    if ($physical.dead_letter.enabled -and $target.deadLetterQueue -cne $physical.dead_letter.queue_name) {
        throw 'Terraform dead-letter queue differs from the validated topology.'
    }
}

Export-ModuleMember -Function @()
