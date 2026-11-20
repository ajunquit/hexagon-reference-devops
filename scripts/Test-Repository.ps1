<#
.SYNOPSIS
    Runs the repository guardrails through phase 9B without provisioning infrastructure.
#>
[CmdletBinding()]
param([switch] $VerifySources, [string] $WorkspaceRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
# The guardrails of each cloud (docs/separacion-por-nube.md): <Cloud>Repository.psd1 lists its required
# paths, tests and Terraform roots. The core checks below run in every repository.
$cloudChecks = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*Repository.psd1' -File | Sort-Object Name |
    ForEach-Object { Import-PowerShellDataFile -LiteralPath $_.FullName })

$resourceHelper = Join-Path $PSScriptRoot 'workspace_resources.py'
$resourceCommand = Get-Command python -ErrorAction SilentlyContinue
if (-not $resourceCommand) { $resourceCommand = Get-Command python3 -ErrorAction Stop }
$resourcePython = $resourceCommand.Source
& $resourcePython -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)'
if ($LASTEXITCODE -ne 0) { throw 'Python 3.10 or newer is required for local resource guardrails.' }
if (-not $WorkspaceRoot) {
    $WorkspaceRoot = $env:HEXAGON_WORKSPACE_ROOT
    if (-not $WorkspaceRoot) {
        $resourceCursor = Get-Item -LiteralPath $repositoryRoot
        while ($resourceCursor) {
            if ((Test-Path -LiteralPath (Join-Path $resourceCursor.FullName '.tools/workspace-resources.json')) -or
                (Test-Path -LiteralPath (Join-Path $resourceCursor.FullName '.worktrees'))) {
                $WorkspaceRoot = $resourceCursor.FullName
                break
            }
            $resourceCursor = $resourceCursor.Parent
        }
        if (-not $WorkspaceRoot) { $WorkspaceRoot = $repositoryRoot }
    }
}
& $resourcePython $resourceHelper check --workspace-root $WorkspaceRoot
if ($LASTEXITCODE -ne 0) { throw 'Resource budget exceeded or unverifiable. Review cleanup; do not raise limits automatically.' }
& $resourcePython -m unittest discover -s (Join-Path $repositoryRoot 'tests/python') -v
if ($LASTEXITCODE -ne 0) { throw 'Local resource guardrail tests failed.' }


$requiredPaths = @(
    'contracts/schemas/environment-inventory-v1.schema.json',
    'scripts/EnvironmentLifecycle.psm1',
    'scripts/New-EnvironmentInventory.ps1',
    'scripts/Test-EnvironmentInventory.ps1',
    'docs/pruebas-locales-floci.md',
    'tests/FlociSupport.ps1',
    'docs/adr/0026-floci-como-plataforma-local.md',
    'docs/motor-ciclo-ambiente.md',
    'scripts/EnvironmentSnapshot.psm1',
    'contracts/schemas/environment-snapshot-v1.schema.json',
    'contracts/schemas/ephemeral-environment-v1.schema.json',
    'contracts/schemas/ephemeral-bootstrap-result-v1.schema.json',
    'contracts/schemas/environment-workflow-result-v1.schema.json',
    'scripts/EphemeralEnvironment.psm1',
    'scripts/EnvironmentWorkflow.psm1',
    'scripts/Invoke-ApplicationDelivery.ps1',
    'scripts/ApplicationArtifacts.psm1',
    'scripts/StaticWebPublication.psm1',
    'contracts/schemas/application-delivery-v1.schema.json',
    'contracts/schemas/application-delivery-journal-v1.schema.json',
    'contracts/schemas/application-delivery-result-v1.schema.json',
    'tests/Test-KeycloakAuthorization.ps1',
    'tests/Invoke-KeycloakAuthorizationAcceptance.ps1',
    'tests/Invoke-AuthLocalIntegration.ps1',
    'examples/keycloak-authorization.json',
    'scripts/KeycloakAuthorization.psm1',
    'scripts/AuthorizationDelivery.psm1',
    'scripts/Invoke-KeycloakAuthorization.ps1',
    'contracts/schemas/keycloak-authorization-v1.schema.json',
    '.github/workflows/delivery.yml',
    'scripts/Invoke-EphemeralBootstrap.ps1',
    'scripts/Invoke-EnvironmentWorkflow.ps1',
    'scripts/Test-EphemeralFederation.ps1',
    'tests/Test-CloudAdapters.ps1',
    'scripts/CloudAdapters.psm1',
    '.github/workflows/genesis.yml',
    '.github/workflows/apocalypse.yml',
    '.github/actions/cloud-session/action.yml',
    'contracts/schemas/platform-bootstrap-result-v1.schema.json',
    'scripts/CanonicalJson.psm1',
    'scripts/ContractSchemas.psm1',
    'scripts/Update-CoreDevops.ps1',
    'contracts/schemas/platform-bootstrap-review-v1.schema.json',
    'contracts/schemas/platform-bootstrap-execution-v1.schema.json',
    'AGENTS.md',
    '.github/workflows/ci.yml',
    '.config/product.json',
    'contracts/schemas/component-build-v1.schema.json',
    'scripts/Test-ComponentBuild.ps1',
    'tests/Test-ComponentBuild.ps1',
    'contracts/schemas/application-release-v1.schema.json',
    'CHANGELOG.md',
    'contracts/schemas/product-environment-v1.schema.json',
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
    'docs/politica-rabbitmq.md',
    'terraform/bootstrap/README.md',
    'terraform/environments/dev/README.md',
    'terraform/environments/staging/README.md',
    'terraform/environments/prod/README.md',
    'terraform/modules/messaging/rabbitmq/README.md',
    'scripts/New-LocalMessaging.ps1',
    'scripts/Start-LocalMessaging.ps1',
    'scripts/Stop-LocalMessaging.ps1',
    'tests/Test-Contracts.ps1',
    'scripts/Get-CiScope.ps1',
    'scripts/CiScope.psm1',
    'tests/Test-CiScope.ps1',
    'tests/Test-RabbitMqContracts.ps1',
    'tests/Test-LocalMessaging.ps1',
    'tests/Test-LocalMessagingRuntime.ps1',
    'tests/fixtures/backend/.hexagon/messaging-requirements.json',
    'tests/fixtures/backend/.hexagon/schemas/messaging-requirements-v1.schema.json',
    'scripts/LocalMessagingSupport.psm1',
    'scripts/RabbitMqOperationsPolicy.psm1',
    'scripts/RabbitMqLocalMessaging.psm1'
) + @($cloudChecks | ForEach-Object { $_.RequiredPaths })

# A cloud template carries a pinned copy of the base: no copied file may change in place
# (scripts/Update-CoreDevops.ps1 is the only way to update it).
$coreSource = Join-Path $repositoryRoot '.config/hexagon-core-devops-source.json'
if (Test-Path -LiteralPath $coreSource) {
    $copy = Get-Content -Raw -LiteralPath $coreSource | ConvertFrom-Json -AsHashtable
    if ($copy.apiVersion -cne 'hexagon.ec/core-devops-source/v1' -or $copy.commit -cnotmatch '^[0-9a-f]{40}$' -or $copy.files.Count -eq 0) { throw 'Invalid copy of the base.' }
    foreach ($entry in $copy.files.GetEnumerator()) {
        $copied = Join-Path $repositoryRoot $entry.Key
        if (-not (Test-Path -LiteralPath $copied -PathType Leaf) -or (Get-FileHash -LiteralPath $copied -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry.Value) {
            throw "The copy of the base changed in place: $($entry.Key). Change it in hexagon-core-devops and run scripts/Update-CoreDevops.ps1."
        }
    }
}

foreach ($path in $requiredPaths) {
    if (-not (Test-Path -LiteralPath (Join-Path $repositoryRoot $path))) {
        throw "Required phase 3 path is missing: $path"
    }
}

$schemaPath = Join-Path $repositoryRoot 'contracts/schemas/product-environment-v1.schema.json'
Get-Content -Raw -LiteralPath $schemaPath | ConvertFrom-Json | Out-Null
$examplePath = Join-Path $repositoryRoot 'examples/product-environment.json'
& (Join-Path $PSScriptRoot 'Test-ProductEnvironmentDescriptor.ps1') `
    -Descriptor $examplePath
# Every messaging provider of the repository validates its example topology and the operations example
# validates against the RabbitMQ topology of the core.
Import-Module (Join-Path $PSScriptRoot 'MessagingOperations.psm1') -Force
$messagingProviders = @(Get-OperationsProviders)
foreach ($provider in $messagingProviders) {
    $contracts = Invoke-OperationsProvider (Get-OperationsProviderModule $provider) Get-OperationsContracts
    Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot "contracts/schemas/$provider-policy-v1.schema.json") | ConvertFrom-Json | Out-Null
    & (Join-Path $PSScriptRoot "Test-$($contracts)Policy.ps1") -Policy (Join-Path $repositoryRoot "examples/$provider-policy.json")
}
& (Join-Path $PSScriptRoot 'Test-MessagingOperationsPolicy.ps1') `
    -Policy (Join-Path $repositoryRoot 'examples/messaging-operations-policy.json') `
    -TopologyPolicy (Join-Path $repositoryRoot 'examples/rabbitmq-policy.json')

$productsPath = Join-Path $repositoryRoot 'products'
$descriptors = @(
    Get-ChildItem -LiteralPath $productsPath -Recurse -File -Filter 'descriptor.json' |
        Where-Object FullName -NotLike '*\.git\*'
)
foreach ($descriptor in $descriptors) {
    & (Join-Path $PSScriptRoot 'Test-ProductEnvironmentDescriptor.ps1') `
        -Descriptor $descriptor.FullName -VerifySources:$VerifySources
}

$messagingPolicies = 0
foreach ($provider in $messagingProviders) {
    $contracts = Invoke-OperationsProvider (Get-OperationsProviderModule $provider) Get-OperationsContracts
    foreach ($policy in @(Get-ChildItem -LiteralPath $productsPath -Recurse -File -Filter "$provider-policy.json" | Where-Object FullName -NotLike '*\.git\*')) {
        & (Join-Path $PSScriptRoot "Test-$($contracts)Policy.ps1") -Policy $policy.FullName
        $messagingPolicies++
    }
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

# The environment workflows open the cloud session through the action of the template (docs/separacion-por-nube.md):
# they never authenticate or branch by cloud themselves, and every external action is pinned by commit.
foreach ($name in @('genesis', 'apocalypse', 'delivery')) {
    $environmentWorkflow = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot ".github/workflows/$name.yml")
    if ($environmentWorkflow -notmatch '(?m)^\s*uses:\s*[.]/[.]github/actions/cloud-session\s*$' -or $environmentWorkflow -match 'outputs[.]provider|configure-[a-z]+-credentials|/login@|role-to-assume|client-id:') {
        throw "Workflow $name must open the cloud session only through .github/actions/cloud-session."
    }
}
foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $repositoryRoot '.github') -Recurse -File -Include '*.yml', '*.yaml')) {
    if ((Get-Content -Raw -LiteralPath $file.FullName) -match '(?m)^\s*-?\s*uses:\s*(?![.]/)[^\s]+@(?![0-9a-f]{40}\b)') { throw "$($file.Name) must pin every external action by commit." }
}

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
& (Join-Path $repositoryRoot 'tests/Test-CiScope.ps1')
& (Join-Path $repositoryRoot 'tests/Test-RabbitMqContracts.ps1')
& (Join-Path $repositoryRoot 'tests/Test-LocalMessaging.ps1')
& (Join-Path $repositoryRoot 'tests/Test-MessagingOperations.ps1')
& (Join-Path $repositoryRoot 'tests/Test-MessagingOperationsExport.ps1')
& (Join-Path $repositoryRoot 'tests/Test-KeycloakAuthorization.ps1')
& (Join-Path $repositoryRoot 'tests/Test-ComponentBuild.ps1')
& (Join-Path $repositoryRoot 'tests/Test-CloudAdapters.ps1')
foreach ($checks in $cloudChecks) {
    foreach ($test in $checks.Tests) { & (Join-Path $repositoryRoot $test) }
    # HTTP fixtures run in their own process, away from the modules cached by the lifecycle suites.
    foreach ($test in $checks.IsolatedTests) {
        & pwsh -NoLogo -NoProfile -File (Join-Path $repositoryRoot $test)
        if ($LASTEXITCODE -ne 0) { throw "$test failed." }
    }
}
$nodeTests = @('acceptance/browser.test.mjs') + @($cloudChecks | ForEach-Object { $_.NodeTests })
& node --test @($nodeTests | ForEach-Object { Join-Path $repositoryRoot $_ })
if ($LASTEXITCODE -ne 0) { throw 'Browser acceptance tests failed. Install acceptance dependencies and Chromium first.' }
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

    & $resourcePython $resourceHelper check --workspace-root $WorkspaceRoot
    if ($LASTEXITCODE -ne 0) { throw 'Resource budget exceeded after tests. Stop before initializing providers.' }
    $terraformRoots = @(
        'terraform/modules/messaging/rabbitmq',
        'terraform/environments/dev/rabbitmq',
        'terraform/environments/staging/rabbitmq',
        'terraform/environments/prod/rabbitmq'
    ) + @($cloudChecks | ForEach-Object { $_.TerraformRoots })
    foreach ($terraformRoot in $terraformRoots) {
        & $resourcePython $resourceHelper init --workspace-root $WorkspaceRoot `
            --root (Join-Path $repositoryRoot $terraformRoot) --cache-only -- `
            -backend=false -input=false -lockfile=readonly -no-color
        if ($LASTEXITCODE -ne 0) {
            throw "terraform init failed for '$terraformRoot'."
        }
        & terraform "-chdir=$terraformRoot" validate -no-color
        if ($LASTEXITCODE -ne 0) {
            throw "terraform validate failed for '$terraformRoot'."
        }
    }

    $terraformTestRoots = @(
        'terraform/modules/messaging/rabbitmq'
    ) + @($cloudChecks | ForEach-Object { $_.TerraformTestRoots })
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

Write-Host "Repository checks passed. Validated $($descriptors.Count) product descriptors and $messagingPolicies messaging topology policies for $($messagingProviders -join ', ')."
