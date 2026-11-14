<#
.SYNOPSIS
    Generates local broker topology and backend bindings from the backend messaging contract.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [Parameter(Mandatory = $true)]
    [string] $BackendPath,

    [string] $Policy,

    [string] $OutputDirectory,

    [string] $BindingsOutput,

    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Import-Module (Join-Path $PSScriptRoot 'LocalMessaging.psm1') -Force

$manifestContext = Get-LocalMessagingManifest -BackendPath $BackendPath
$manifest = $manifestContext.Manifest
$policyModel = $null
if ($Policy) {
    $policyPath = (Resolve-Path -LiteralPath $Policy).Path
    $validator = switch ([string] $manifest.provider) {
        'azure-service-bus' { 'Test-AzureServiceBusPolicy.ps1' }
        'aws-sns-sqs' { 'Test-AwsSnsSqsPolicy.ps1' }
        'rabbitmq' { 'Test-RabbitMqPolicy.ps1' }
        default { throw "Unsupported messaging provider '$($manifest.provider)'." }
    }
    & (Join-Path $PSScriptRoot $validator) -Policy $policyPath
    $policyModel = Get-Content -Raw -LiteralPath $policyPath | ConvertFrom-Json
}

$plan = New-LocalMessagingPlan -Manifest $manifest -Policy $policyModel
$generatedRoot = if ($OutputDirectory) {
    [IO.Path]::GetFullPath($OutputDirectory, (Get-Location).Path)
}
else {
    Join-Path $repositoryRoot "local/generated/$($manifest.product)/$($manifest.provider)"
}
$bindingsPath = if ($BindingsOutput) {
    [IO.Path]::GetFullPath($BindingsOutput, (Get-Location).Path)
}
else {
    Join-Path $manifestContext.BackendRoot '.hexagon/local-messaging-bindings.json'
}

$bindingsJson = ($plan.Bindings | ConvertTo-Json -Depth 20) + "`n"
$bindingsSchema = Join-Path $repositoryRoot 'contracts/schemas/local-messaging-bindings-v1.schema.json'
if (-not ($bindingsJson | Test-Json -SchemaFile $bindingsSchema -ErrorAction SilentlyContinue)) {
    throw 'Generated local messaging bindings do not satisfy LocalMessagingBindings v1.'
}

function Write-GeneratedText {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,
        [Parameter(Mandatory = $true)]
        [string] $Text
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $temporaryPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporaryPath, $Text.TrimEnd() + "`n", [Text.UTF8Encoding]::new($false))
        if (-not $IsWindows -and $Path.EndsWith('.sh', [StringComparison]::Ordinal)) {
            # Floci only runs executable initialization hooks on Unix hosts.
            $mode = [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute -bor [IO.UnixFileMode]::GroupRead -bor [IO.UnixFileMode]::GroupExecute -bor [IO.UnixFileMode]::OtherRead -bor [IO.UnixFileMode]::OtherExecute
            [IO.File]::SetUnixFileMode($temporaryPath, $mode)
        }
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

if ($PSCmdlet.ShouldProcess($generatedRoot, 'Generate local messaging topology and backend bindings')) {
    foreach ($file in $plan.Files.GetEnumerator()) {
        Write-GeneratedText -Path (Join-Path $generatedRoot ([string] $file.Key)) -Text ([string] $file.Value)
    }
    Write-GeneratedText -Path $bindingsPath -Text $bindingsJson
    Write-Host "Generated local messaging topology: $generatedRoot"
    Write-Host "Generated backend bindings: $bindingsPath"
}

if ($PassThru) {
    [pscustomobject] @{
        Product         = [string] $manifest.product
        Provider        = [string] $manifest.provider
        OutputDirectory = $generatedRoot
        ComposeFile     = Join-Path $generatedRoot 'compose.yaml'
        BindingsFile    = $bindingsPath
    }
}
