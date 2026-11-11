<#
.SYNOPSIS
    Tests restricted YAML, bootstrap boundaries and read-only plans without platform credentials.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'scripts/PlatformBootstrap.psm1') -Force
$module = Get-Module PlatformBootstrap
$example = Join-Path $root 'examples/platform-bootstrap.yaml'
$original = Get-Content -Raw -LiteralPath $example
$temporaryParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
$temporaryRoot = Join-Path $temporaryParent "hexagon-platform-tests-$([guid]::NewGuid().ToString('N'))"
[IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null
$script:assertions = 0

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
    $script:assertions++
}
function Assert-Rejected([scriptblock] $Action, [string] $Code) {
    try { & $Action | Out-Null }
    catch {
        Assert-True ($_.Exception.Message -like "*$Code*") "Unexpected failure: $($_.Exception.Message)"
        return
    }
    throw "Expected rejection: $Code"
}
function Write-Yaml([string] $Text) {
    $path = Join-Path $temporaryRoot "$([guid]::NewGuid().ToString('N')).yaml"
    [IO.File]::WriteAllText($path, $Text, [Text.UTF8Encoding]::new($false))
    return $path
}
function Reset-Responses {
    $script:requests = [Collections.Generic.List[string]]::new()
    $script:responses = @{
        AzureAccount = @{ tenantId = '11111111-1111-1111-1111-111111111111'; id = '22222222-2222-2222-2222-222222222222' }
        TerraformVersion = @{ terraform_version = '1.17.1' }
        Repository = @{ full_name = 'example-owner/hexagon-template-devops'; default_branch = 'main'; archived = $false; disabled = $false; permissions = @{ admin = $true }; private = $false; owner = @{ id = 123 }; id = 456 }
        Environments = @{ total_count = 0; environments = @() }
        Actions = @{ enabled = $true }
        WorkflowPermissions = @{ default_workflow_permissions = 'read'; can_approve_pull_request_reviews = $false }
        Oidc = @{ use_default = $true; sub_claim_prefix = 'repo:example-owner@123/hexagon-template-devops@456' }
        GroupExists = $false
        Group = @{ name = 'rg-hexagon-template-state'; tags = @{ product = 'hexagon-template'; 'managed-by' = 'terraform' } }
        Storage = @(); Identities = @()
    }
}
$read = {
    param($request, $definition, $target)
    $script:requests.Add($request)
    if (-not $script:responses.ContainsKey($request)) { throw 'Unexpected read request.' }
    return $script:responses[$request]
}

try {
    $parsed = Read-PlatformBootstrapDocument -Path $example
    $offline = New-PlatformBootstrapPlan -Parsed $parsed
    Assert-True ($offline.status -ceq 'Unverified' -and -not $offline.readyToApply) 'Offline plans must not claim readiness.'
    Assert-True ($offline.operations.Count -eq 12) 'Missing bootstrap stages.'
    $seen = [Collections.Generic.HashSet[string]]::new()
    foreach ($operation in $offline.operations) {
        foreach ($dependency in $operation.dependsOn) { Assert-True ($seen.Contains($dependency)) 'Dependencies must precede their consumer.' }
        Assert-True ($seen.Add($operation.id)) 'Duplicate operation id.'
    }
    $offlineJson = ConvertTo-PlatformBootstrapJson $offline
    Assert-True ($offlineJson | Test-Json -SchemaFile (Join-Path $root 'contracts/schemas/platform-bootstrap-result-v1.schema.json')) 'Result schema rejected an offline plan.'
    Assert-True ($offlineJson -ceq (ConvertTo-PlatformBootstrapJson (New-PlatformBootstrapPlan -Parsed $parsed))) 'Plan serialization is not deterministic.'
    $devOnly = Read-PlatformBootstrapDocument -Path (Write-Yaml ($original -replace '(?ms)^  staging:\r?\n.*\z', ''))
    $devPlan = New-PlatformBootstrapPlan -Parsed $devOnly
    Assert-True ((@(Get-BootstrapEnvironments $devOnly.definition) -join ',') -ceq 'dev') 'A dev-only definition selected other environments.'
    Assert-True (@($devPlan.operations | Where-Object { $_.id -match '(staging|prod)' }).Count -eq 0 -and
        (@($devPlan.operations | Where-Object id -CEQ 'workflow.diagnostic')[0].dependsOn -join ',') -ceq 'github.variables.dev') 'Dev-only plan still requires staging or prod.'

    foreach ($invalid in @(
        $original.Replace('schemaVersion: 1', 'schemaVersion: 1' + "`nclientSecret: never-print-this-value"),
        $original.Replace('location: eastus2', 'location: eastus2' + "`n  clientSecret: never-print-this-value"),
        $original.Replace('schemaVersion: 1', 'schemaVersion: 1' + "`nschemaVersion: 1"),
        ($original + "`n---`nproduct: another"),
        $original.Replace('schemaVersion: 1', 'schemaVersion: &version 1'),
        $original.Replace('schemaVersion: 1', 'schemaVersion: !custom 1'),
        $original.Replace('reviewers: []', 'reviewers: [*missing]'),
        $original.Replace('provider: GitHubActions', 'provider: AzurePipelines'),
        $original.Replace('branch: main', 'branch: feature/unsafe'),
        $original.Replace('release-reviewer', 'release-reviewer, "$(arbitrary-command)"')
    )) {
        $path = Write-Yaml $invalid
        Assert-Rejected { Read-PlatformBootstrapDocument -Path $path } 'bootstrap.definitionInvalid'
    }
    $configuredProduct = (Get-Content -Raw (Join-Path $root '.config/product.json') | ConvertFrom-Json).product
    $foreignProduct = if ($configuredProduct -cne 'hexagon-context-check') { 'hexagon-context-check' } else { 'hexagon-context-other' }
    $path = Write-Yaml ($original.Replace('hexagon-template', $foreignProduct))
    Read-PlatformBootstrapDocument -Path $path | Out-Null
    Assert-Rejected { Read-PlatformBootstrapDefinition -Path $path } 'bootstrap.productMismatch'
    $path = Write-Yaml ($original.Replace('hexagon-template', $configuredProduct))
    Assert-True ((Read-PlatformBootstrapDefinition -Path $path).definition.product -ceq $configuredProduct) 'Runtime must validate the configured product independently from the template fixture.'
    $path = Write-Yaml ($original.Replace('id-hexagon-template-staging-deploy', 'id-hexagon-template-dev-deploy'))
    Assert-Rejected { Read-PlatformBootstrapDocument -Path $path } 'bootstrap.identityShared'
    $path = Write-Yaml ($original.Replace('rg-hexagon-template-staging-messaging', 'rg-hexagon-template-dev-messaging'))
    Assert-Rejected { Read-PlatformBootstrapDocument -Path $path } 'bootstrap.resourceGroupShared'
    $path = Write-Yaml ($original.Replace('11111111-1111-1111-1111-111111111111', '00000000-0000-0000-0000-000000000000'))
    Assert-Rejected { Read-PlatformBootstrapDocument -Path $path } 'bootstrap.targetInvalid'
    $path = Write-Yaml ('a' * 65537)
    Assert-Rejected { Read-PlatformBootstrapDocument -Path $path } 'bootstrap.definitionInvalid'

    Reset-Responses
    $observation = Get-PlatformBootstrapObservation -Definition $parsed.definition -Read $read
    Assert-True ($script:requests -notcontains 'Storage' -and $script:requests -notcontains 'Identities') 'A missing parent must not require existing child resources.'
    $plan = New-PlatformBootstrapPlan -Parsed $parsed -Observation $observation
    Assert-True ($plan.status -ceq 'Planned' -and -not $plan.readyToApply) 'Read-only preparation must not be apply-ready.'
    Assert-True ($plan.operations[0].action -ceq 'Create') 'An empty bootstrap should be represented as missing.'
    $identity = @($plan.operations | Where-Object id -CEQ 'azure.identity.dev')[0]
    Assert-True ($identity.desired.subject -ceq 'repo:example-owner@123/hexagon-template-devops@456:environment:dev') 'Immutable OIDC subject is incorrect.'
    Assert-True ($identity.desired.audience -ceq 'api://AzureADTokenExchange') 'OIDC audience is missing.'

    Reset-Responses
    $script:responses.AzureAccount.id = '33333333-3333-3333-3333-333333333333'
    Assert-Rejected { Get-PlatformBootstrapObservation -Definition $parsed.definition -Read $read } 'bootstrap.targetMismatch'
    Assert-True ($script:requests.Count -eq 1) 'Wrong Azure subscription must block every later lookup.'
    Reset-Responses
    $script:responses.AzureAccount.tenantId = '33333333-3333-3333-3333-333333333333'
    Assert-Rejected { Get-PlatformBootstrapObservation -Definition $parsed.definition -Read $read } 'bootstrap.targetMismatch'
    Reset-Responses
    $script:responses.Repository.permissions.admin = $false
    Assert-Rejected { Get-PlatformBootstrapObservation -Definition $parsed.definition -Read $read } 'bootstrap.repositoryBoundary'
    Reset-Responses
    $script:responses.TerraformVersion.terraform_version = '1.5.3'
    Assert-Rejected { Get-PlatformBootstrapObservation -Definition $parsed.definition -Read $read } 'bootstrap.terraformVersion'
    Reset-Responses
    $script:responses.Environments.total_count = 101
    Assert-Rejected { Get-PlatformBootstrapObservation -Definition $parsed.definition -Read $read } 'bootstrap.environmentsIncomplete'
    Reset-Responses
    $script:responses.Oidc.use_default = $false
    Assert-Rejected { Get-PlatformBootstrapObservation -Definition $parsed.definition -Read $read } 'bootstrap.oidcTemplateUnsupported'
    Reset-Responses
    $script:responses.GroupExists = $true
    $script:responses.Group.tags.product = 'hexagon-another'
    Assert-Rejected { Get-PlatformBootstrapObservation -Definition $parsed.definition -Read $read } 'bootstrap.ownershipUnverified'
    Reset-Responses
    $script:responses.Repository.private = $true
    $plan = New-PlatformBootstrapPlan -Parsed $parsed -Observation (Get-PlatformBootstrapObservation -Definition $parsed.definition -Read $read)
    Assert-True ($plan.status -ceq 'Unverified') 'Private production protection cannot be assumed available.'

    # Exercise the actual native transport and assert its read-only command arguments.
    & $module {
        $script:nativeCalls = [Collections.Generic.List[object]]::new()
        function script:gh {
            $script:nativeCalls.Add(@($args)); $global:LASTEXITCODE = 0
            '{"enabled":true}'
        }
        try {
            foreach ($request in @('Repository', 'Environments', 'Actions', 'WorkflowPermissions', 'Oidc')) {
                Invoke-PlatformReadCommand -Request $request -Definition @{ automation = @{ repository = 'example-owner/hexagon-template-devops' }; azure = @{ subscriptionId = 'subscription' }; state = @{ resourceGroup = 'group' } } | Out-Null
            }
            foreach ($call in $script:nativeCalls) {
                if ($call[0] -cne 'api' -or $call[1] -cne '--method' -or $call[2] -cne 'GET' -or $call.Count -ne 4) { throw 'Transport issued an unexpected GitHub command.' }
            }
        }
        finally { Remove-Item Function:script:gh }
        function script:az {
            $script:nativeCalls.Add(@($args)); $global:LASTEXITCODE = 0
            '{}'
        }
        $script:nativeCalls.Clear()
        try {
            foreach ($request in @('AzureAccount', 'GroupExists', 'Group', 'Storage', 'Identities')) {
                Invoke-PlatformReadCommand -Request $request -Target 'group' -Definition @{ automation = @{ repository = 'example-owner/hexagon-template-devops' }; azure = @{ subscriptionId = 'expected-subscription' }; state = @{ resourceGroup = 'group' } } | Out-Null
            }
            foreach ($call in $script:nativeCalls) {
                $readVerb = $call -contains 'show' -or $call -contains 'exists' -or $call -contains 'list'
                if (-not $readVerb -or $call -contains 'create' -or $call -contains 'update' -or $call -contains 'delete') { throw 'Transport issued an unexpected Azure command.' }
                if ($call[0] -cne 'account' -and $call -notcontains 'expected-subscription') { throw 'Azure lookup is not scoped to the expected subscription.' }
            }
        }
        finally { Remove-Item Function:script:az }
    }
    $script:assertions++

    $entry = Join-Path $root 'scripts/Invoke-PlatformBootstrap.ps1'
    $runtimeExample = Write-Yaml ($original.Replace('hexagon-template', $configuredProduct))
    $json = & pwsh -NoProfile -File $entry -Definition $runtimeExample -Mode Validate
    Assert-True ($LASTEXITCODE -eq 0 -and ($json -join "`n" | ConvertFrom-Json).status -ceq 'Validated') 'Validate CLI failed.'
    $output = Join-Path $temporaryRoot 'plan.json'
    $json = & pwsh -NoProfile -File $entry -Definition $runtimeExample -Mode Plan -Offline -Output $output -WhatIf
    Assert-True ($LASTEXITCODE -eq 2 -and -not (Test-Path -LiteralPath $output)) 'WhatIf must not write the requested output.'
    Assert-True (($json -join "`n" | ConvertFrom-Json).status -ceq 'Unverified') 'WhatIf output must remain machine-readable JSON.'
    $json = & pwsh -NoProfile -File $entry -Definition $runtimeExample -Mode Plan -Offline -Output $output
    Assert-True ($LASTEXITCODE -eq 2 -and (Test-Path -LiteralPath $output)) 'Offline plan export failed.'
    $before = (Get-FileHash -LiteralPath $output).Hash
    $overwriteError = & pwsh -NoProfile -File $entry -Definition $runtimeExample -Mode Plan -Offline -Output $output 2>&1
    Assert-True ($LASTEXITCODE -ne 0 -and (Get-FileHash -LiteralPath $output).Hash -ceq $before) 'Plan export must not overwrite an existing result.'
    $unsupported = & pwsh -NoProfile -File $entry -Definition $runtimeExample -Mode Apply 2>&1
    Assert-True ($LASTEXITCODE -ne 0) 'Apply without a workspace and reviewed plan must fail.'
    $path = Write-Yaml ($original + "`nclientSecret: never-print-this-value")
    $json = & pwsh -NoProfile -File $entry -Definition $path -Mode Validate
    Assert-True ($LASTEXITCODE -eq 1 -and ($json -join "`n") -notmatch 'never-print-this-value') 'Invalid input must fail without disclosing rejected values.'
    Assert-True (($json -join "`n" | ConvertFrom-Json).status -ceq 'Invalid') 'Invalid CLI status is incorrect.'
}
finally {
    $resolved = [IO.Path]::GetFullPath($temporaryRoot)
    if ([IO.Path]::GetDirectoryName($resolved) -cne $temporaryParent -or -not [IO.Path]::GetFileName($resolved).StartsWith('hexagon-platform-tests-')) { throw 'Unsafe test cleanup target.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Host "Platform bootstrap tests passed: $script:assertions assertions; no live platform access."
