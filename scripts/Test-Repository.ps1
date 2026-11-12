<#
.SYNOPSIS
    Runs the repository guardrails through phase 9B without provisioning infrastructure.
#>
[CmdletBinding()]
param([switch] $VerifySources)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

$requiredPaths = @(
    'contracts/schemas/platform-bootstrap-v1.schema.json',
    'contracts/schemas/environment-inventory-v1.schema.json',
    'scripts/EnvironmentLifecycle.psm1',
    'scripts/New-EnvironmentInventory.ps1',
    'scripts/Test-EnvironmentInventory.ps1',
    'tests/Test-EnvironmentLifecycle.ps1',
    'docs/motor-ciclo-ambiente.md',
    'scripts/Invoke-AzureEnvironment.ps1',
    'scripts/AzureEnvironmentStore.psm1',
    'scripts/TerraformAzureLifecycle.psm1',
    'scripts/EnvironmentSnapshot.psm1',
    'contracts/schemas/environment-snapshot-v1.schema.json',
    'contracts/schemas/azure-environment-result-v1.schema.json',
    'tests/Test-AzureEnvironmentAdapter.ps1',
    'tests/LifecycleHttpHandler.cs',
    'docs/adaptador-ciclo-azure.md',
    'docs/ciclo-efimero-azure.md',
    'contracts/schemas/ephemeral-environment-v1.schema.json',
    'contracts/schemas/ephemeral-bootstrap-result-v1.schema.json',
    'contracts/schemas/environment-workflow-result-v1.schema.json',
    'scripts/EphemeralEnvironment.psm1',
    'scripts/EnvironmentWorkflow.psm1',
    'scripts/Invoke-ApplicationDelivery.ps1',
    'scripts/ApplicationArtifacts.psm1',
    'scripts/AzureOciDelivery.psm1',
    'scripts/AzureMaintenanceDelivery.psm1',
    'scripts/AzureApplicationDelivery.psm1',
    'scripts/AzureWebDelivery.psm1',
    'scripts/StaticWebPublication.psm1',
    'scripts/StaticWebClient.psm1',
    'scripts/Install-StaticWebClient.ps1',
    '.config/static-web-client.json',
    'tests/Test-StaticWebPublication.ps1',
    'tests/Test-StaticWebClient.ps1',
    'scripts/AzureLifecycleInputs.psm1',
    'contracts/schemas/application-delivery-v1.schema.json',
    'contracts/schemas/application-delivery-journal-v1.schema.json',
    'contracts/schemas/application-delivery-result-v1.schema.json',
    'tests/Test-ApplicationDelivery.ps1',
    'tests/Test-KeycloakDelivery.ps1',
    'scripts/AzureKeycloakDelivery.psm1',
    '.github/workflows/delivery.yml',
    'docs/entrega-aplicaciones-azure.md',
    'scripts/Invoke-EphemeralBootstrap.ps1',
    'scripts/Invoke-EnvironmentWorkflow.ps1',
    'scripts/Test-EphemeralFederation.ps1',
    'tests/Test-EnvironmentWorkflow.ps1',
    '.github/workflows/genesis.yml',
    '.github/workflows/apocalypse.yml',
    'terraform/bootstrap/azure-ephemeral/main.tf',
    'contracts/schemas/platform-bootstrap-result-v1.schema.json',
    'scripts/Invoke-PlatformBootstrap.ps1',
    'scripts/PlatformBootstrap.psm1',
    'scripts/PlatformBootstrap.Execution.psm1',
    'scripts/Invoke-PlatformBootstrapStage.ps1',
    'scripts/Test-PlatformFederation.ps1',
    '.github/workflows/platform-diagnostic.yml',
    'contracts/schemas/platform-bootstrap-review-v1.schema.json',
    'contracts/schemas/platform-bootstrap-execution-v1.schema.json',
    'tests/Test-PlatformBootstrapExecution.ps1',
    'tests/Test-PlatformBootstrap.ps1',
    'docs/bootstrap-plataformas.md',
    'AGENTS.md',
    '.github/workflows/ci.yml',
    '.config/product.json',
    'contracts/schemas/component-build-v1.schema.json',
    'scripts/Test-ComponentBuild.ps1',
    'tests/Test-ComponentBuild.ps1',
    'contracts/schemas/application-release-v1.schema.json',
    'contracts/schemas/azure-hosting-policy-v1.schema.json',
    'docs/hosting-azure.md',
    'docs/adr/0010-primera-referencia-de-hosting-en-azure.md',
    'terraform/modules/hosting/azure/README.md',
    'CHANGELOG.md',
    'contracts/schemas/product-environment-v1.schema.json',
    'contracts/schemas/azure-service-bus-policy-v1.schema.json',
    'contracts/schemas/aws-sns-sqs-policy-v1.schema.json',
    'contracts/schemas/rabbitmq-policy-v1.schema.json',
    'contracts/schemas/local-messaging-bindings-v1.schema.json',
    'contracts/schemas/messaging-operations-policy-v1.schema.json',
    'docs/operacion-mensajeria.md',
    'docs/adr/0009-operacion-de-mensajeria-por-consumidor.md',
    'operations/Hexagon.Messaging.Operations/Hexagon.Messaging.Operations.csproj',
    'tests/Test-MessagingOperations.ps1',
    'scripts/Export-MessagingOperations.ps1',
    'scripts/Invoke-MessagingOperation.ps1',
    'docs/adr/0001-una-instancia-devops-por-producto.md',
    'docs/adr/0002-terraform-como-herramienta-iac.md',
    'docs/adr/0003-descriptores-inmutables-por-ambiente.md',
    'docs/adr/0004-una-plantilla-devops-con-monolito-modular-inicial.md',
    'docs/adr/0005-topologia-de-azure-service-bus-desde-contratos.md',
    'docs/adr/0006-topologia-de-aws-sns-sqs-con-redrive-por-cola.md',
    'docs/adr/0007-topologia-de-rabbitmq-con-dlx-por-cola.md',
    'docs/adr/0008-topologia-local-fuera-del-apphost.md',
    'docs/politica-azure-service-bus.md',
    'docs/politica-aws-sns-sqs.md',
    'docs/politica-rabbitmq.md',
    'terraform/bootstrap/README.md',
    'terraform/bootstrap/azure/versions.tf',
    'terraform/bootstrap/aws/versions.tf',
    'terraform/environments/dev/README.md',
    'terraform/environments/staging/README.md',
    'terraform/environments/prod/README.md',
    'terraform/modules/messaging/azure-service-bus/README.md',
    'terraform/modules/messaging/aws-sns-sqs/README.md',
    'terraform/modules/messaging/rabbitmq/README.md',
    'scripts/New-LocalMessaging.ps1',
    'scripts/Start-LocalMessaging.ps1',
    'scripts/Stop-LocalMessaging.ps1',
    'tests/Test-Contracts.ps1',
    'tests/Test-AzureServiceBusContracts.ps1',
    'tests/Test-AwsSnsSqsContracts.ps1',
    'tests/Test-RabbitMqContracts.ps1',
    'tests/Test-LocalMessaging.ps1',
    'tests/Test-LocalMessagingRuntime.ps1',
    'tests/fixtures/backend/.hexagon/messaging-requirements.json',
    'tests/fixtures/backend/.hexagon/schemas/messaging-requirements-v1.schema.json'
)

foreach ($path in $requiredPaths) {
    if (-not (Test-Path -LiteralPath (Join-Path $repositoryRoot $path))) {
        throw "Required phase 3 path is missing: $path"
    }
}

$schemaPath = Join-Path $repositoryRoot 'contracts/schemas/product-environment-v1.schema.json'
Get-Content -Raw -LiteralPath $schemaPath | ConvertFrom-Json | Out-Null
$serviceBusSchemaPath = Join-Path $repositoryRoot 'contracts/schemas/azure-service-bus-policy-v1.schema.json'
Get-Content -Raw -LiteralPath $serviceBusSchemaPath | ConvertFrom-Json | Out-Null
$awsSchemaPath = Join-Path $repositoryRoot 'contracts/schemas/aws-sns-sqs-policy-v1.schema.json'
Get-Content -Raw -LiteralPath $awsSchemaPath | ConvertFrom-Json | Out-Null
$rabbitMqSchemaPath = Join-Path $repositoryRoot 'contracts/schemas/rabbitmq-policy-v1.schema.json'
Get-Content -Raw -LiteralPath $rabbitMqSchemaPath | ConvertFrom-Json | Out-Null
$localBindingsSchemaPath = Join-Path $repositoryRoot 'contracts/schemas/local-messaging-bindings-v1.schema.json'
Get-Content -Raw -LiteralPath $localBindingsSchemaPath | ConvertFrom-Json | Out-Null

$examplePath = Join-Path $repositoryRoot 'examples/product-environment.json'
& (Join-Path $PSScriptRoot 'Test-ProductEnvironmentDescriptor.ps1') `
    -Descriptor $examplePath
$serviceBusExamplePath = Join-Path $repositoryRoot 'examples/azure-service-bus-policy.json'
& (Join-Path $PSScriptRoot 'Test-AzureServiceBusPolicy.ps1') `
    -Policy $serviceBusExamplePath
$awsExamplePath = Join-Path $repositoryRoot 'examples/aws-sns-sqs-policy.json'
& (Join-Path $PSScriptRoot 'Test-AwsSnsSqsPolicy.ps1') `
    -Policy $awsExamplePath
$rabbitMqExamplePath = Join-Path $repositoryRoot 'examples/rabbitmq-policy.json'
& (Join-Path $PSScriptRoot 'Test-RabbitMqPolicy.ps1') `
    -Policy $rabbitMqExamplePath
& (Join-Path $PSScriptRoot 'Test-MessagingOperationsPolicy.ps1') `
    -Policy (Join-Path $repositoryRoot 'examples/messaging-operations-policy.json') `
    -TopologyPolicy $awsExamplePath

$productsPath = Join-Path $repositoryRoot 'products'
$descriptors = @(
    Get-ChildItem -LiteralPath $productsPath -Recurse -File -Filter 'descriptor.json' |
        Where-Object FullName -NotLike '*\.git\*'
)
foreach ($descriptor in $descriptors) {
    & (Join-Path $PSScriptRoot 'Test-ProductEnvironmentDescriptor.ps1') `
        -Descriptor $descriptor.FullName -VerifySources:$VerifySources
}

$serviceBusPolicies = @(
    Get-ChildItem -LiteralPath $productsPath -Recurse -File -Filter 'azure-service-bus-policy.json' |
        Where-Object FullName -NotLike '*\.git\*'
)
foreach ($policy in $serviceBusPolicies) {
    & (Join-Path $PSScriptRoot 'Test-AzureServiceBusPolicy.ps1') `
        -Policy $policy.FullName
}

$awsPolicies = @(
    Get-ChildItem -LiteralPath $productsPath -Recurse -File -Filter 'aws-sns-sqs-policy.json' |
        Where-Object FullName -NotLike '*\.git\*'
)
foreach ($policy in $awsPolicies) {
    & (Join-Path $PSScriptRoot 'Test-AwsSnsSqsPolicy.ps1') `
        -Policy $policy.FullName
}

$rabbitMqPolicies = @(
    Get-ChildItem -LiteralPath $productsPath -Recurse -File -Filter 'rabbitmq-policy.json' |
        Where-Object FullName -NotLike '*\.git\*'
)
foreach ($policy in $rabbitMqPolicies) {
    & (Join-Path $PSScriptRoot 'Test-RabbitMqPolicy.ps1') `
        -Policy $policy.FullName
}

$operationsPolicies = @(Get-ChildItem -LiteralPath $productsPath -Recurse -File -Filter 'messaging-operations-policy.json')
foreach ($policy in $operationsPolicies) {
    $model = Get-Content -Raw -LiteralPath $policy.FullName | ConvertFrom-Json
    $topologyPolicy = Join-Path $policy.DirectoryName "$($model.provider)-policy.json"
    & (Join-Path $PSScriptRoot 'Test-MessagingOperationsPolicy.ps1') -Policy $policy.FullName -TopologyPolicy $topologyPolicy
}

# CI is authorized in 9B. Deployment identities and Terraform apply remain in the later delivery phases.
$workflow = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot '.github/workflows/ci.yml')
if ($workflow -match 'pull_request_target|id-token:\s*write|\bterraform\b[^\r\n]*\bapply\b' -or $workflow -match '(?m)^\s*-?\s*uses:\s*[^\s]+@(?![0-9a-f]{40}\b)') { throw 'CI must use pinned actions without privileged deployment operations.' }

$versionedCandidates = & git -C $repositoryRoot ls-files --cached --others --exclude-standard
if ($LASTEXITCODE -ne 0) { throw 'Could not enumerate repository files.' }
$forbiddenFiles = @(
    $versionedCandidates | ForEach-Object { Get-Item -LiteralPath (Join-Path $repositoryRoot $_) -Force } |
        Where-Object {
            $_.Name -match '\.tfstate(?:\..+)?$' -or
            $_.Name -match '\.tfplan$' -or
            $_.Name -match '\.auto\.tfvars(?:\.json)?$' -or
            $_.Name -match '\.(?:pem|pfx|key)$'
        }
)
if ($forbiddenFiles.Count -gt 0) {
    $relativeFiles = $forbiddenFiles | ForEach-Object {
        [IO.Path]::GetRelativePath($repositoryRoot, $_.FullName)
    }
    throw "Forbidden state, plan, variable or secret files: $($relativeFiles -join ', ')"
}

$parserErrors = [Collections.Generic.List[string]]::new()
$scripts = Get-ChildItem -LiteralPath $PSScriptRoot -File |
    Where-Object Extension -in '.ps1', '.psm1'
$scripts += Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'tests') -File |
    Where-Object Extension -eq '.ps1'
foreach ($script in $scripts) {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile(
        $script.FullName,
        [ref] $tokens,
        [ref] $errors
    ) | Out-Null
    foreach ($parseIssue in $errors) {
        $parserErrors.Add("$($script.Name): $($parseIssue.Message)")
    }
}
if ($parserErrors.Count -gt 0) {
    throw "PowerShell parse errors: $($parserErrors -join '; ')"
}

& (Join-Path $repositoryRoot 'tests/Test-Contracts.ps1')
& (Join-Path $repositoryRoot 'tests/Test-AzureServiceBusContracts.ps1')
& (Join-Path $repositoryRoot 'tests/Test-AwsSnsSqsContracts.ps1')
& (Join-Path $repositoryRoot 'tests/Test-RabbitMqContracts.ps1')
& (Join-Path $repositoryRoot 'tests/Test-LocalMessaging.ps1')
& (Join-Path $repositoryRoot 'tests/Test-MessagingOperations.ps1')
& (Join-Path $repositoryRoot 'tests/Test-MessagingOperationsExport.ps1')
& (Join-Path $repositoryRoot 'tests/Test-HostingContracts.ps1')
& (Join-Path $repositoryRoot 'tests/Test-ComponentBuild.ps1')
& (Join-Path $repositoryRoot 'tests/Test-PlatformBootstrap.ps1')
& (Join-Path $repositoryRoot 'tests/Test-PlatformBootstrapExecution.ps1')
& (Join-Path $repositoryRoot 'tests/Test-PlatformFederation.ps1')
& (Join-Path $repositoryRoot 'tests/Test-EnvironmentLifecycle.ps1')
& (Join-Path $repositoryRoot 'tests/Test-AzureEnvironmentAdapter.ps1')
& (Join-Path $repositoryRoot 'tests/Test-EnvironmentWorkflow.ps1')
# Delivery HTTP fixtures must not reuse the lifecycle suites' cached module mocks.
& pwsh -NoLogo -NoProfile -File (Join-Path $repositoryRoot 'tests/Test-ApplicationDelivery.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Application delivery tests failed.' }
& pwsh -NoLogo -NoProfile -File (Join-Path $repositoryRoot 'tests/Test-KeycloakDelivery.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Integrated identity delivery tests failed.' }
& pwsh -NoLogo -NoProfile -File (Join-Path $repositoryRoot 'tests/Test-Acceptance.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Acceptance consent and cleanup protocol tests failed.' }
& node --test (Join-Path $repositoryRoot 'acceptance/browser.test.mjs')
if ($LASTEXITCODE -ne 0) { throw 'Chromium acceptance protocol tests failed. Install acceptance dependencies and Chromium first.' }
# Isolate HTTP fixtures from modules cached by the lifecycle suites in this process.
& pwsh -NoLogo -NoProfile -File (Join-Path $repositoryRoot 'tests/Test-StaticWebPublication.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Static web publication and backend health tests failed.' }
& dotnet format whitespace (Join-Path $repositoryRoot 'operations/Hexagon.Platform.Definition/Hexagon.Platform.Definition.csproj') --verify-no-changes --no-restore --verbosity quiet
if ($LASTEXITCODE -ne 0) { throw 'Platform definition reader whitespace validation failed.' }

$operationsTestProject = Join-Path $repositoryRoot 'operations/Hexagon.Messaging.Operations.Tests'
& dotnet test $operationsTestProject --nologo --verbosity quiet --filter 'Category!=Broker&Category!=Database'
if ($LASTEXITCODE -ne 0) { throw 'Messaging operations unit tests failed.' }

if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
    throw 'Terraform 1.11 or newer is required to validate the infrastructure modules.'
}
$terraformVersionOutput = & terraform version -json
if ($LASTEXITCODE -ne 0) {
    throw 'Could not read the installed Terraform version.'
}
$terraformVersion = [version] (($terraformVersionOutput | ConvertFrom-Json).terraform_version)
if ($terraformVersion -lt [version] '1.11.0' -or $terraformVersion -ge [version] '2.0.0') {
    throw "Terraform >= 1.11.0 and < 2.0.0 is required; found $terraformVersion."
}

& (Join-Path $repositoryRoot 'tests/Test-LocalStateTransfer.ps1')

Push-Location $repositoryRoot
try {
    & terraform fmt -check -recursive terraform
    if ($LASTEXITCODE -ne 0) {
        throw 'terraform fmt found files that need formatting.'
    }

    $terraformRoots = @(
        'terraform/bootstrap/azure',
        'terraform/bootstrap/azure-access',
        'terraform/bootstrap/azure-ephemeral',
        'terraform/bootstrap/aws',
        'terraform/modules/messaging/azure-service-bus',
        'terraform/modules/messaging/aws-sns-sqs',
        'terraform/modules/messaging/rabbitmq',
        'terraform/modules/hosting/azure',
        'terraform/environments/dev/hosting-azure',
        'terraform/environments/staging/hosting-azure',
        'terraform/environments/prod/hosting-azure',
        'terraform/environments/dev/azure',
        'terraform/environments/dev/aws',
        'terraform/environments/dev/rabbitmq',
        'terraform/environments/staging/azure',
        'terraform/environments/staging/aws',
        'terraform/environments/staging/rabbitmq',
        'terraform/environments/prod/azure',
        'terraform/environments/prod/aws',
        'terraform/environments/prod/rabbitmq'
    )
    foreach ($terraformRoot in $terraformRoots) {
        & terraform "-chdir=$terraformRoot" init `
            -backend=false `
            -input=false `
            -lockfile=readonly `
            -no-color
        if ($LASTEXITCODE -ne 0) {
            throw "terraform init failed for '$terraformRoot'."
        }
        & terraform "-chdir=$terraformRoot" validate -no-color
        if ($LASTEXITCODE -ne 0) {
            throw "terraform validate failed for '$terraformRoot'."
        }
    }

    $terraformTestRoots = @(
        'terraform/bootstrap/azure',
        'terraform/bootstrap/azure-access',
        'terraform/bootstrap/azure-ephemeral',
        'terraform/bootstrap/aws',
        'terraform/modules/messaging/azure-service-bus',
        'terraform/modules/messaging/aws-sns-sqs',
        'terraform/modules/messaging/rabbitmq',
        'terraform/modules/hosting/azure'
    )
    foreach ($terraformTestRoot in $terraformTestRoots) {
        & terraform "-chdir=$terraformTestRoot" test -no-color
        if ($LASTEXITCODE -ne 0) {
            throw "terraform test failed for '$terraformTestRoot'."
        }
    }
}
finally {
    Pop-Location
}

Push-Location $repositoryRoot
try {
    & git diff --check
    if ($LASTEXITCODE -ne 0) {
        throw 'git diff --check found whitespace errors.'
    }
}
finally {
    Pop-Location
}

Write-Host "Repository checks passed. Validated $($descriptors.Count) product descriptors, $($serviceBusPolicies.Count) Azure Service Bus policies, $($awsPolicies.Count) AWS SNS/SQS policies, and $($rabbitMqPolicies.Count) RabbitMQ policies."
