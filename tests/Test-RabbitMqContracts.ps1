<#
.SYNOPSIS
    Exercises RabbitMQ policy validation and Terraform input materialization.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$policyPath = Join-Path $repositoryRoot 'examples/rabbitmq-policy.json'

Import-Module (Join-Path $repositoryRoot 'scripts/RabbitMqContracts.psm1') -Force

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]
        $Actual,

        [Parameter(Mandatory = $true)]
        $Expected,

        [Parameter(Mandatory = $true)]
        [string] $Message
    )

    if ($Actual -cne $Expected) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock] $Action,

        [Parameter(Mandatory = $true)]
        [string] $ExpectedMessage
    )

    $failedAsExpected = $false
    try {
        & $Action
    }
    catch {
        if ($_.Exception.Message -notlike "*$ExpectedMessage*") {
            throw "Expected an error containing '$ExpectedMessage', got: $($_.Exception.Message)"
        }
        $failedAsExpected = $true
    }

    if (-not $failedAsExpected) {
        throw "Expected an error containing '$ExpectedMessage', but the action succeeded."
    }
}

function Copy-JsonModel {
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Value
    )

    return $Value | ConvertTo-Json -Depth 16 | ConvertFrom-Json
}

$descriptor = [pscustomobject] @{
    product     = 'hexagon-example'
    environment = 'dev'
}
$manifest = @'
{
  "apiVersion": "hexagon.ec/messaging-requirements/v1",
  "kind": "BackendMessagingRequirements",
  "product": "hexagon-example",
  "component": "backend",
  "provider": "rabbitmq",
  "destinations": [
    {
      "id": "integration-events",
      "publisherWorkloads": [
        "hexagon-example-api",
        "hexagon-example-worker",
        "hexagon-example-sales-worker"
      ],
      "eventTypes": [
        "CustomerCreatedIntegrationEvent"
      ]
    }
  ],
  "consumers": [
    {
      "id": "worker",
      "workload": "hexagon-example-worker",
      "destination": "integration-events",
      "routing": {
        "mode": "all"
      }
    },
    {
      "id": "sales-worker",
      "workload": "hexagon-example-sales-worker",
      "destination": "integration-events",
      "routing": {
        "mode": "include",
        "eventTypes": [
          "CustomerCreatedIntegrationEvent"
        ]
      }
    }
  ]
}
'@ | ConvertFrom-Json
$policy = Get-Content -Raw -LiteralPath $policyPath | ConvertFrom-Json

& (Join-Path $repositoryRoot 'scripts/Test-RabbitMqPolicy.ps1') -Policy $policyPath
$inputModel = ConvertTo-RabbitMqTerraformInput `
    -Descriptor $descriptor `
    -Policy $policy `
    -Manifest $manifest

Assert-Equal `
    -Actual $inputModel.virtual_host `
    -Expected 'hexagon-example-dev' `
    -Message 'The RabbitMQ virtual host was not materialized.'
Assert-Equal `
    -Actual $inputModel.destinations.'integration-events'.name `
    -Expected 'hexagon-example.dev.integration-events' `
    -Message 'The logical destination was not mapped to the RabbitMQ exchange.'
Assert-Equal `
    -Actual $inputModel.consumers.'sales-worker'.routing_mode `
    -Expected 'include' `
    -Message 'The include routing mode was not preserved.'
Assert-Equal `
    -Actual $inputModel.consumers.worker.dead_letter.enabled `
    -Expected $false `
    -Message 'The worker queue must keep dead-lettering disabled.'
Assert-Equal `
    -Actual $inputModel.consumers.'sales-worker'.dead_letter.queue_name `
    -Expected 'hexagon-example.dev.sales-worker.dlq' `
    -Message 'The optional dead-letter queue was not materialized.'
Assert-Equal `
    -Actual $inputModel.consumers.'sales-worker'.user_name `
    -Expected 'hexagon-example-dev-sales-worker' `
    -Message 'The consumer RabbitMQ user was not resolved.'

$missingUser = Copy-JsonModel -Value $policy
$missingUser.workloadUserNames.PSObject.Properties.Remove('hexagon-example-api')
Assert-Throws `
    -Action {
        ConvertTo-RabbitMqTerraformInput `
            -Descriptor $descriptor `
            -Policy $missingUser `
            -Manifest $manifest
    } `
    -ExpectedMessage 'workload user names do not match'

$sharedUser = Copy-JsonModel -Value $policy
$sharedUser.workloadUserNames.'hexagon-example-api' =
    $sharedUser.workloadUserNames.'hexagon-example-worker'
Assert-Throws `
    -Action { Test-RabbitMqPolicyModel -Policy $sharedUser } `
    -ExpectedMessage 'distinct RabbitMQ user'

$unknownDestination = Copy-JsonModel -Value $manifest
$unknownDestination.consumers[0].destination = 'missing-events'
Assert-Throws `
    -Action {
        ConvertTo-RabbitMqTerraformInput `
            -Descriptor $descriptor `
            -Policy $policy `
            -Manifest $unknownDestination
    } `
    -ExpectedMessage "references unknown destination 'missing-events'"

$unknownEvent = Copy-JsonModel -Value $manifest
$unknownEvent.consumers[1].routing.eventTypes = @('OrderCreatedIntegrationEvent')
Assert-Throws `
    -Action {
        ConvertTo-RabbitMqTerraformInput `
            -Descriptor $descriptor `
            -Policy $policy `
            -Manifest $unknownEvent
    } `
    -ExpectedMessage 'routes event types not published'

$duplicateQueue = Copy-JsonModel -Value $policy
$duplicateQueue.consumers[1].deadLetter.queueName = $duplicateQueue.consumers[0].queueName
Assert-Throws `
    -Action { Test-RabbitMqPolicyModel -Policy $duplicateQueue } `
    -ExpectedMessage 'Duplicate source or dead-letter queue names'

$duplicateExchange = Copy-JsonModel -Value $policy
$duplicateExchange.consumers[1].deadLetter.exchangeName =
    $duplicateExchange.destinations[0].exchangeName
Assert-Throws `
    -Action { Test-RabbitMqPolicyModel -Policy $duplicateExchange } `
    -ExpectedMessage 'Duplicate destination or dead-letter exchange names'

Write-Host 'RabbitMQ contract tests passed.'
