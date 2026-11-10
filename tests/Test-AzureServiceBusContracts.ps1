<#
.SYNOPSIS
    Exercises Azure Service Bus policy validation and Terraform input materialization.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$policyPath = Join-Path $repositoryRoot 'examples/azure-service-bus-policy.json'

Import-Module (Join-Path $repositoryRoot 'scripts/AzureServiceBusContracts.psm1') -Force

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
  "provider": "azure-service-bus",
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

& (Join-Path $repositoryRoot 'scripts/Test-AzureServiceBusPolicy.ps1') -Policy $policyPath
$inputModel = ConvertTo-AzureServiceBusTerraformInput `
    -Descriptor $descriptor `
    -Policy $policy `
    -Manifest $manifest

Assert-Equal `
    -Actual $inputModel.destinations.'integration-events'.name `
    -Expected 'integration-events' `
    -Message 'The logical destination was not mapped to the topic.'
Assert-Equal `
    -Actual $inputModel.consumers.'sales-worker'.routing_mode `
    -Expected 'include' `
    -Message 'The include routing mode was not preserved.'
Assert-Equal `
    -Actual $inputModel.consumers.worker.event_types.Count `
    -Expected 0 `
    -Message 'All routing must not materialize event filters.'
Assert-Equal `
    -Actual $inputModel.consumers.'sales-worker'.principal_id `
    -Expected '00000000-0000-0000-0000-000000000003' `
    -Message 'The receiver identity was not resolved.'

$missingPrincipal = Copy-JsonModel -Value $policy
$missingPrincipal.workloadPrincipalIds.PSObject.Properties.Remove('hexagon-example-api')
Assert-Throws `
    -Action {
        ConvertTo-AzureServiceBusTerraformInput `
            -Descriptor $descriptor `
            -Policy $missingPrincipal `
            -Manifest $manifest
    } `
    -ExpectedMessage 'workload principal ids do not match'

$unknownDestination = Copy-JsonModel -Value $manifest
$unknownDestination.consumers[0].destination = 'missing-events'
Assert-Throws `
    -Action {
        ConvertTo-AzureServiceBusTerraformInput `
            -Descriptor $descriptor `
            -Policy $policy `
            -Manifest $unknownDestination
    } `
    -ExpectedMessage "references unknown destination 'missing-events'"

$unknownEvent = Copy-JsonModel -Value $manifest
$unknownEvent.consumers[1].routing.eventTypes = @('OrderCreatedIntegrationEvent')
Assert-Throws `
    -Action {
        ConvertTo-AzureServiceBusTerraformInput `
            -Descriptor $descriptor `
            -Policy $policy `
            -Manifest $unknownEvent
    } `
    -ExpectedMessage 'routes event types not published'

$duplicateConsumer = Copy-JsonModel -Value $policy
$duplicateConsumer.consumers[1].id = 'worker'
Assert-Throws `
    -Action { Test-AzureServiceBusPolicyModel -Policy $duplicateConsumer } `
    -ExpectedMessage 'Duplicate consumer ids'

$sharedPrincipal = Copy-JsonModel -Value $policy
$sharedPrincipal.workloadPrincipalIds.'hexagon-example-api' =
    $sharedPrincipal.workloadPrincipalIds.'hexagon-example-worker'
Assert-Throws `
    -Action {
        ConvertTo-AzureServiceBusTerraformInput `
            -Descriptor $descriptor `
            -Policy $sharedPrincipal `
            -Manifest $manifest
    } `
    -ExpectedMessage 'distinct principal id'

$invalidLock = Copy-JsonModel -Value $policy
$invalidLock.consumers[0].lockDuration = 'PT10M'
Assert-Throws `
    -Action { Test-AzureServiceBusPolicyModel -Policy $invalidLock } `
    -ExpectedMessage 'between 5 seconds and 5 minutes'

Write-Host 'Azure Service Bus contract tests passed.'
