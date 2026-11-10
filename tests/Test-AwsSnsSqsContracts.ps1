<#
.SYNOPSIS
    Exercises AWS SNS/SQS policy validation and Terraform input materialization.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$policyPath = Join-Path $repositoryRoot 'examples/aws-sns-sqs-policy.json'

Import-Module (Join-Path $repositoryRoot 'scripts/AwsSnsSqsContracts.psm1') -Force

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
  "provider": "aws-sns-sqs",
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

& (Join-Path $repositoryRoot 'scripts/Test-AwsSnsSqsPolicy.ps1') -Policy $policyPath
$inputModel = ConvertTo-AwsSnsSqsTerraformInput `
    -Descriptor $descriptor `
    -Policy $policy `
    -Manifest $manifest

Assert-Equal `
    -Actual $inputModel.destinations.'integration-events'.name `
    -Expected 'hexagon-example-dev-integration-events' `
    -Message 'The logical destination was not mapped to the SNS topic.'
Assert-Equal `
    -Actual $inputModel.kms_alias_name `
    -Expected 'hexagon-example-dev-messaging' `
    -Message 'The SNS encryption key alias was not materialized.'
Assert-Equal `
    -Actual $inputModel.consumers.'sales-worker'.routing_mode `
    -Expected 'include' `
    -Message 'The include routing mode was not preserved.'
Assert-Equal `
    -Actual $inputModel.consumers.worker.redrive.enabled `
    -Expected $false `
    -Message 'The worker queue must keep redrive disabled.'
Assert-Equal `
    -Actual $inputModel.consumers.'sales-worker'.redrive.max_receive_count `
    -Expected 5 `
    -Message 'The optional redrive policy was not materialized.'
Assert-Equal `
    -Actual $inputModel.consumers.'sales-worker'.role_name `
    -Expected 'hexagon-example-dev-sales-worker' `
    -Message 'The receiver IAM role was not resolved.'

$missingRole = Copy-JsonModel -Value $policy
$missingRole.workloadRoleNames.PSObject.Properties.Remove('hexagon-example-api')
Assert-Throws `
    -Action {
        ConvertTo-AwsSnsSqsTerraformInput `
            -Descriptor $descriptor `
            -Policy $missingRole `
            -Manifest $manifest
    } `
    -ExpectedMessage 'workload role names do not match'

$sharedRole = Copy-JsonModel -Value $policy
$sharedRole.workloadRoleNames.'hexagon-example-api' =
    $sharedRole.workloadRoleNames.'hexagon-example-worker'
Assert-Throws `
    -Action {
        ConvertTo-AwsSnsSqsTerraformInput `
            -Descriptor $descriptor `
            -Policy $sharedRole `
            -Manifest $manifest
    } `
    -ExpectedMessage 'distinct IAM role'

$unknownDestination = Copy-JsonModel -Value $manifest
$unknownDestination.consumers[0].destination = 'missing-events'
Assert-Throws `
    -Action {
        ConvertTo-AwsSnsSqsTerraformInput `
            -Descriptor $descriptor `
            -Policy $policy `
            -Manifest $unknownDestination
    } `
    -ExpectedMessage "references unknown destination 'missing-events'"

$unknownEvent = Copy-JsonModel -Value $manifest
$unknownEvent.consumers[1].routing.eventTypes = @('OrderCreatedIntegrationEvent')
Assert-Throws `
    -Action {
        ConvertTo-AwsSnsSqsTerraformInput `
            -Descriptor $descriptor `
            -Policy $policy `
            -Manifest $unknownEvent
    } `
    -ExpectedMessage 'routes event types not published'

$duplicateQueue = Copy-JsonModel -Value $policy
$duplicateQueue.consumers[1].redrive.deadLetterQueueName =
    $duplicateQueue.consumers[0].queueName
Assert-Throws `
    -Action { Test-AwsSnsSqsPolicyModel -Policy $duplicateQueue } `
    -ExpectedMessage 'Duplicate source or dead-letter queue names'

$invalidRetention = Copy-JsonModel -Value $policy
$invalidRetention.consumers[1].redrive.deadLetterMessageRetentionSeconds =
    $invalidRetention.consumers[1].messageRetentionSeconds
Assert-Throws `
    -Action { Test-AwsSnsSqsPolicyModel -Policy $invalidRetention } `
    -ExpectedMessage 'dead-letter retention must be longer'

Write-Host 'AWS SNS/SQS contract tests passed.'
