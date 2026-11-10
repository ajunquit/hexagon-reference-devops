<#
.SYNOPSIS
    Generates alerts and bounded recovery targets from immutable application and DevOps contracts.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)] [string] $Descriptor,
    [Parameter(Mandatory)] [string] $TopologyPolicy,
    [Parameter(Mandatory)] [string] $Policy,
    [Parameter(Mandatory)] [string] $OutputDirectory,
    [string] $TerraformOutputs
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ApplicationContracts.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'MessagingOperations.psm1') -Force

if (-not $PSCmdlet.ShouldProcess($OutputDirectory, 'Verify immutable sources and generate operations artifacts')) { return }
& (Join-Path $PSScriptRoot 'Test-ProductEnvironmentDescriptor.ps1') -Descriptor $Descriptor -VerifySources
& (Join-Path $PSScriptRoot 'Test-MessagingOperationsPolicy.ps1') -Policy $Policy -TopologyPolicy $TopologyPolicy
$descriptorModel = Get-Content -Raw -LiteralPath $Descriptor | ConvertFrom-Json
$topology = Get-Content -Raw -LiteralPath $TopologyPolicy | ConvertFrom-Json
$operations = Get-Content -Raw -LiteralPath $Policy | ConvertFrom-Json
$backend = @($descriptorModel.components | Where-Object name -CEQ 'backend')
if ($backend.Count -ne 1) { throw 'Exactly one backend component is required.' }
$manifestEntry = @($backend[0].manifests | Where-Object path -CEQ '.hexagon/messaging-requirements.json')
if ($manifestEntry.Count -ne 1) { throw 'Exactly one backend messaging manifest is required.' }
$validated = Get-ValidatedApplicationManifest -Repository $backend[0].repository -Commit $backend[0].commit `
    -Path $manifestEntry[0].path -ExpectedProduct $descriptorModel.product -ExpectedComponent 'backend'
if ($validated.Sha256 -cne $manifestEntry[0].sha256) { throw 'Backend manifest SHA-256 mismatch.' }
$providerModule = switch ($operations.provider) {
    'azure-service-bus' { 'AzureServiceBus' }
    'aws-sns-sqs' { 'AwsSnsSqs' }
    'rabbitmq' { 'RabbitMq' }
}
Import-Module (Join-Path $PSScriptRoot "$($providerModule)Contracts.psm1") -Force
# Reuse the full provider checks, including exact routing, workload and product correspondence.
$inputModel = & "ConvertTo-$($providerModule)TerraformInput" -Descriptor $descriptorModel -Policy $topology -Manifest $validated.Manifest
$artifacts = [ordered] @{}
$artifacts['operations.auto.tfvars.json'] = ConvertTo-OperationsTerraformInput -Operations $operations -Topology $topology
if ($operations.provider -ceq 'rabbitmq') {
    $artifacts['messaging.rules.json'] = ConvertTo-RabbitMqAlertRules -Operations $operations -Topology $topology
}

if ($TerraformOutputs) {
    $outputs = Get-Content -Raw -LiteralPath $TerraformOutputs | ConvertFrom-Json
    $mapping = switch ($operations.provider) {
        'azure-service-bus' { $outputs.azure_service_bus.value }
        'aws-sns-sqs' { $outputs.aws_sns_sqs.value }
        'rabbitmq' { $outputs.messaging_topology.value }
    }
    foreach ($consumer in $operations.consumers) {
        $physical = $inputModel.consumers[$consumer.id]
        $actual = $mapping.consumers.($consumer.id)
        if ([string] $actual.name -cne [string] $physical.name) { throw 'Terraform consumer differs from the validated topology.' }
        $destination = $inputModel.destinations[$physical.destination]
        $logical = @($validated.Manifest.consumers | Where-Object id -CEQ $consumer.id)[0]
        $target = [ordered] @{
            apiVersion = 'hexagon.ec/messaging-operation-target/v1'
            product = $operations.product
            environment = $operations.environment
            provider = $operations.provider
            consumer = $consumer.id
            eventTypes = @(if ($logical.routing.mode -ceq 'include') { $logical.routing.eventTypes } else { $destination.event_types })
            replayEnabled = $consumer.replay.enabled
            maxBatchSize = $consumer.replay.maxBatchSize
            delayMilliseconds = $consumer.replay.delayMilliseconds
        }
        switch ($operations.provider) {
            'azure-service-bus' {
                if ($mapping.namespace.name -cne $topology.namespace.name -or $actual.topic_name -cne $destination.name) {
                    throw 'Terraform namespace or topic differs from the validated topology.'
                }
                $target.namespace = "$($topology.namespace.name).servicebus.windows.net"
                $target.topic = $destination.name
                $target.subscription = $physical.name
                $target.hasDeadLetter = $true
            }
            'aws-sns-sqs' {
                $target.region = $topology.region
                $target.sourceQueue = $actual.url
                $target.hasDeadLetter = $physical.redrive.enabled
                $target.deadLetterQueue = if ($physical.redrive.enabled) { $actual.dead_letter_queue.url } else { '' }
                if ($actual.arn -cnotmatch "^arn:aws[a-z-]*:sqs:$([regex]::Escape($topology.region)):([0-9]{12}):$([regex]::Escape($physical.name))$") {
                    throw 'Terraform source queue ARN differs from the validated topology.'
                }
                $account = $Matches[1]
                if ($physical.redrive.enabled -and ($actual.dead_letter_queue.name -cne $physical.redrive.dead_letter_queue_name -or
                    $actual.dead_letter_queue.arn -cne "arn:$(([string] $actual.arn).Split(':')[1]):sqs:$($topology.region):${account}:$($physical.redrive.dead_letter_queue_name)")) {
                    throw 'Terraform dead-letter queue differs from the validated topology.'
                }
                $queueUrls = @(@{ Url = $target.sourceQueue; Name = $actual.name })
                if ($physical.redrive.enabled) { $queueUrls += @{ Url = $target.deadLetterQueue; Name = $actual.dead_letter_queue.name } }
                foreach ($queue in $queueUrls) {
                    $uri = [uri] $queue.Url
                    if ($uri.Scheme -cne 'https' -or $uri.Host -cne "sqs.$($topology.region).amazonaws.com" -or
                        $uri.AbsolutePath -cne "/$account/$($queue.Name)" -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
                        throw 'Terraform queue URL differs from its validated region, account or name.'
                    }
                }
            }
            'rabbitmq' {
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
        }
        $artifacts["$($consumer.id).target.json"] = $target
    }
}

# All validation happens before the first write.
$outputPath = [IO.Path]::GetFullPath($OutputDirectory, (Get-Location).Path)
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
foreach ($entry in $artifacts.GetEnumerator()) {
    $file = Join-Path $outputPath $entry.Key
    [IO.File]::WriteAllText($file, (($entry.Value | ConvertTo-Json -Depth 30) + "`n"), [Text.UTF8Encoding]::new($false))
}
Write-Host "Generated $($artifacts.Count) messaging operations artifacts."
