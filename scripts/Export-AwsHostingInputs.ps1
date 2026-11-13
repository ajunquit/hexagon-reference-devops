<#
.SYNOPSIS
    Resolves pinned hosting contracts and immutable artifact references into AWS Terraform inputs.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param([Parameter(Mandatory)] [string] $Descriptor, [Parameter(Mandatory)] [string] $Release,
    [Parameter(Mandatory)] [string] $Policy, [Parameter(Mandatory)] [string] $Output)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$outputPath = [IO.Path]::GetFullPath($Output)
if (-not $outputPath.EndsWith('.auto.tfvars.json', [StringComparison]::Ordinal)) { throw 'Output must end with .auto.tfvars.json.' }
if (-not $PSCmdlet.ShouldProcess($outputPath, 'Verify pinned sources and export hosting inputs')) { return }
Import-Module (Join-Path $PSScriptRoot 'HostingContracts.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ApplicationContracts.psm1') -Force
& (Join-Path $PSScriptRoot 'Test-ApplicationRelease.ps1') -Descriptor $Descriptor -Release $Release -VerifySources
$descriptorModel = Get-Content -Raw -LiteralPath $Descriptor | ConvertFrom-Json -AsHashtable
$releaseModel = Read-HostingContract -Path $Release -Schema 'application-release-v1'
$policyModel = Read-HostingContract -Path $Policy -Schema 'aws-hosting-policy-v1'
$manifests = @{}
foreach ($pair in @(@('backend', '.hexagon/backend-hosting-requirements.json'), @('web', '.hexagon/frontend-hosting-requirements.json'))) {
    $source = @($descriptorModel.components | Where-Object { $_.name -ceq $pair[0] })
    if ($source.Count -ne 1 -or @($source[0].manifests | Where-Object { $_.path -ceq $pair[1] }).Count -ne 1) { throw 'The AWS reference requires pinned backend and web hosting manifests.' }
    $verified = Get-ValidatedApplicationManifest -Repository $source[0].repository -Commit $source[0].commit -Path $pair[1] -ExpectedProduct $descriptorModel.product -ExpectedComponent $pair[0]
    $manifests[$pair[0]] = $verified.Manifest | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
}
$inputs = ConvertTo-AwsHostingInput -Descriptor $descriptorModel -Release $releaseModel -Policy $policyModel -Backend $manifests.backend -Frontend $manifests.web
$json = ($inputs | ConvertTo-Json -Depth 30) + "`n"
$temporary = "$outputPath.$([guid]::NewGuid().ToString('N')).tmp"
try {
    [IO.File]::WriteAllText($temporary, $json, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $outputPath -Force
} finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
}
Write-Host "Generated hosting inputs with rollout disabled: $outputPath"
