Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../scripts/CiScope.psm1') -Force

function New-ScopeRoot([hashtable] $Manifests) {
    $root = Join-Path ([IO.Path]::GetTempPath()) "hexagon-ci-scope-$([guid]::NewGuid().ToString('N'))"
    foreach ($environment in $Manifests.Keys) {
        $directory = Join-Path $root "products/hexagon-example/environments/$environment"
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $entries = @($Manifests[$environment] | ForEach-Object { [ordered] @{ path = $_.path; sha256 = $_.sha256 } })
        $descriptor = [ordered] @{
            product    = 'hexagon-example'
            components = @(
                [ordered] @{ name = 'web'; repository = 'example/web'; commit = ('a' * 40); manifests = @() },
                [ordered] @{ name = 'backend'; repository = 'example/backend'; commit = ('b' * 40); manifests = $entries }
            )
        }
        Set-Content -LiteralPath (Join-Path $directory 'descriptor.json') -Value ($descriptor | ConvertTo-Json -Depth 6) -Encoding utf8NoBOM
    }
    return $root
}

$awsHash = 'e' * 64
$reader = {
    param($repository, $commit, $path, $product)
    if ($product -cne 'hexagon-example' -or $repository -cne 'example/backend') { throw 'The manifest must be read for the descriptor backend.' }
    [pscustomobject] @{ Manifest = [pscustomobject] @{ provider = 'aws-sns-sqs' }; Sha256 = $awsHash }
}
$messaging = @{ path = '.hexagon/messaging-requirements.json'; sha256 = $awsHash }
$hosting = @{ path = '.hexagon/backend-hosting-requirements.json'; sha256 = ('c' * 64) }

# The template, without descriptors, tests every provider.
$template = Join-Path ([IO.Path]::GetTempPath()) "hexagon-ci-scope-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $template | Out-Null
$all = Get-CiMessagingProviders -Root $template -ReadManifest { throw 'The template must not read applications.' }
if (($all -join ',') -cne 'azure-service-bus,aws-sns-sqs,rabbitmq') { throw "The template must test every provider, got '$($all -join ',')'." }

# A product tests only the provider of its backend, once, whatever its number of environments.
$product = New-ScopeRoot @{ dev = @($messaging, $hosting); staging = @($messaging, $hosting) }
$only = Get-CiMessagingProviders -Root $product -ReadManifest $reader
if (($only -join ',') -cne 'aws-sns-sqs') { throw "A product must test only its provider, got '$($only -join ',')'." }
$matrix = ConvertTo-CiMessagingMatrix -Providers $only | ConvertFrom-Json
if ($matrix.Count -ne 1 -or $matrix[0].provider -cne 'aws-sns-sqs' -or $matrix[0].'test-class' -cne 'AwsRuntimeTests') {
    throw 'The matrix must map the provider to its broker tests.'
}

# An API-only backend needs no broker tests.
$apiOnly = New-ScopeRoot @{ dev = @($hosting) }
$none = @(Get-CiMessagingProviders -Root $apiOnly -ReadManifest { throw 'An API-only backend has no messaging manifest to read.' })
if ($none.Count -ne 0 -or (ConvertTo-CiMessagingMatrix -Providers $none) -cne '[]') { throw 'An API-only product must not run broker tests.' }

# A manifest that differs from the pinned SHA-256 is rejected, not trusted.
$tampered = New-ScopeRoot @{ dev = @(@{ path = '.hexagon/messaging-requirements.json'; sha256 = ('d' * 64) }) }
$rejected = $false
try { Get-CiMessagingProviders -Root $tampered -ReadManifest $reader | Out-Null } catch { $rejected = $_.Exception.Message -like '*does not match*' }
if (-not $rejected) { throw 'A manifest that differs from its descriptor must be rejected.' }

# The integrations run when the change can alter them, or when the change is unknown.
if (-not (Test-CiIntegrationChange -ChangedPaths $null)) { throw 'An unknown change must run every integration.' }
foreach ($changed in @(
    'operations/Hexagon.Messaging.Operations/AwsOperations.cs',
    'scripts/LocalMessaging.psm1',
    'scripts/Test-RabbitMqPolicy.ps1',
    'scripts/AzureServiceBusContracts.psm1',
    'products/hexagon-example/environments/dev/descriptor.json',
    'tests/Test-LocalMessagingRuntime.ps1',
    '.github/workflows/ci.yml',
    'global.json')) {
    if (-not (Test-CiIntegrationChange -ChangedPaths @('docs/README.md', $changed))) { throw "A change to '$changed' must run the integrations." }
}
foreach ($changed in @('terraform/modules/hosting/aws/main.tf', 'docs/ci-y-artefactos.md', '.github/workflows/delivery.yml', 'scripts/Invoke-AwsEnvironment.ps1', 'acceptance/package.json')) {
    if (Test-CiIntegrationChange -ChangedPaths @($changed)) { throw "A change to '$changed' must not run the integrations." }
}
if (Test-CiIntegrationChange -ChangedPaths @()) { throw 'An empty change must not run the integrations.' }

foreach ($path in @($template, $product, $apiOnly, $tampered)) { Remove-Item -LiteralPath $path -Recurse -Force }
Write-Host 'CI scope tests passed.'
