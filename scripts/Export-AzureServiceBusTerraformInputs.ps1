<#
.SYNOPSIS
    Materializes validated Azure Service Bus Terraform inputs from application and DevOps contracts.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [Parameter(Mandatory = $true)]
    [string] $Descriptor,

    [Parameter(Mandatory = $true)]
    [string] $Policy,

    [Parameter(Mandatory = $true)]
    [string] $Output
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$descriptorPath = (Resolve-Path -LiteralPath $Descriptor).Path
$policyPath = (Resolve-Path -LiteralPath $Policy).Path
$outputPath = [IO.Path]::GetFullPath($Output, (Get-Location).Path)

if (-not $outputPath.EndsWith('.auto.tfvars.json', [StringComparison]::Ordinal)) {
    throw "Output '$outputPath' must end with .auto.tfvars.json."
}
$outputDirectory = Split-Path -Parent $outputPath
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    throw "Output directory '$outputDirectory' does not exist."
}

Import-Module (Join-Path $PSScriptRoot 'ApplicationContracts.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AzureServiceBusContracts.psm1') -Force

& (Join-Path $PSScriptRoot 'Test-ProductEnvironmentDescriptor.ps1') `
    -Descriptor $descriptorPath `
    -VerifySources
& (Join-Path $PSScriptRoot 'Test-AzureServiceBusPolicy.ps1') -Policy $policyPath

$descriptorModel = Get-Content -Raw -LiteralPath $descriptorPath | ConvertFrom-Json
$policyModel = Get-Content -Raw -LiteralPath $policyPath | ConvertFrom-Json
$backend = @($descriptorModel.components | Where-Object { [string] $_.name -ceq 'backend' })
if ($backend.Count -ne 1) {
    throw 'The product environment descriptor must contain exactly one backend component.'
}

$messagingManifest = @(
    $backend[0].manifests |
        Where-Object { [string] $_.path -ceq '.hexagon/messaging-requirements.json' }
)
if ($messagingManifest.Count -ne 1) {
    throw "The backend component must contain exactly one '.hexagon/messaging-requirements.json' manifest."
}

$validated = Get-ValidatedApplicationManifest `
    -Repository ([string] $backend[0].repository) `
    -Commit ([string] $backend[0].commit) `
    -Path ([string] $messagingManifest[0].path) `
    -ExpectedProduct ([string] $descriptorModel.product) `
    -ExpectedComponent 'backend'
if ($validated.Sha256 -cne [string] $messagingManifest[0].sha256) {
    throw 'The backend messaging manifest SHA-256 does not match the product environment descriptor.'
}

$terraformInput = ConvertTo-AzureServiceBusTerraformInput `
    -Descriptor $descriptorModel `
    -Policy $policyModel `
    -Manifest $validated.Manifest
$json = ($terraformInput | ConvertTo-Json -Depth 16) + "`n"

if ($PSCmdlet.ShouldProcess($outputPath, 'Write generated Terraform input')) {
    $temporaryPath = "$outputPath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporaryPath, $json, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $outputPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
    Write-Host "Generated Terraform inputs: $outputPath"
}
