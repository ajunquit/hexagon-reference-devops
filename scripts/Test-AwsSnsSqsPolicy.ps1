<#
.SYNOPSIS
    Validates an AWS SNS/SQS policy owned by the DevOps repository.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Policy
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$schemaPath = Join-Path $repositoryRoot 'contracts/schemas/aws-sns-sqs-policy-v1.schema.json'
$policyPath = (Resolve-Path -LiteralPath $Policy).Path

Import-Module (Join-Path $PSScriptRoot 'AwsSnsSqsContracts.psm1') -Force

$json = Get-Content -Raw -LiteralPath $policyPath
$isValid = $json | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue
if (-not $isValid) {
    throw "Policy '$policyPath' does not satisfy AwsSnsSqsPolicy v1."
}

$model = $json | ConvertFrom-Json
Test-AwsSnsSqsPolicyModel -Policy $model

$relativePath = [IO.Path]::GetRelativePath($repositoryRoot, $policyPath).Replace('\', '/')
if ($relativePath.StartsWith('products/', [StringComparison]::Ordinal)) {
    $expectedPath = "products/$($model.product)/environments/$($model.environment)/aws-sns-sqs-policy.json"
    if ($relativePath -cne $expectedPath) {
        throw "Policy location '$relativePath' must be '$expectedPath'."
    }
}

Write-Host "Validated AWS SNS/SQS policy: $relativePath"
