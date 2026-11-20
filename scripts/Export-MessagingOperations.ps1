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
$provider = Get-OperationsProviderModule $operations.provider
$providerModule = Invoke-OperationsProvider $provider Get-OperationsContracts
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
    $mapping = Invoke-OperationsProvider $provider Get-OperationsTerraformMapping @(, $outputs)
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
        Invoke-OperationsProvider $provider Set-OperationsTarget @($target, $topology, $physical, $actual, $destination, $mapping)
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
