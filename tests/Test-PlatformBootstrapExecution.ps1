<#
.SYNOPSIS
    Exercises review/apply, interrupted migration, federation and GitHub reconciliation with protocol doubles.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'scripts/PlatformBootstrap.psm1') -Force
Import-Module (Join-Path $root 'scripts/PlatformBootstrap.Execution.psm1') -Force
$module = Get-Module PlatformBootstrap.Execution
$parsed = Read-PlatformBootstrapDefinition (Join-Path $root 'examples/platform-bootstrap.yaml')
$observation = @{
    oidcPrefix = 'repo:example-owner@123/hexagon-template-devops@456'
    repository = @{ id = 456 }; environments = @()
    actions = @{ enabled = $true }
    workflowPermissions = @{ default_workflow_permissions = 'read'; can_approve_pull_request_reviews = $false }
}
$temporaryParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
$workspace = Join-Path $temporaryParent "hexagon-bootstrap-execution-$([guid]::NewGuid().ToString('N'))"
[IO.Directory]::CreateDirectory($workspace) | Out-Null
$script:assertions = 0
function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }; $script:assertions++
}
function Assert-Rejected([scriptblock] $Action, [string] $Code) {
    try { & $Action | Out-Null }
    catch { Assert-True ($_.Exception.Message -like "*$Code*") "Unexpected failure: $($_.Exception.Message)"; return }
    throw "Expected rejection: $Code"
}
try {
    $containers = Get-BootstrapContainers $parsed.definition
    Assert-True ($containers.dev -cne $containers.prod -and $containers.dev -ceq 'tfstate-dev') 'State containers are not isolated.'
    $variables = Get-BootstrapTerraformVariables $parsed.definition $observation State
    Assert-True ($variables.environment_groups.Count -eq 6 -and $variables.subscription_id -ceq $parsed.definition.azure.subscriptionId) 'Terraform target or group ownership is missing.'
    $access = Get-BootstrapTerraformVariables $parsed.definition $observation Access
    Assert-True ($access.environments.dev.state_container -ceq 'tfstate-dev' -and $access.oidc_prefix -ceq $observation.oidcPrefix) 'Access inputs lost the observed subject or container boundary.'

    & $module {
        $script:terraformCalls = [Collections.Generic.List[object]]::new()
        $script:remoteState = $null; $script:destructive = $false; $script:failPush = $false
        function script:Invoke-BootstrapNative {
            param($Tool, $Arguments, $InputText, $ExitCodes)
            if ($Tool -cne 'terraform') { throw 'Unexpected native tool.' }
            $script:terraformCalls.Add(@($Arguments))
            $directory = $Arguments[0].Substring(7)
            switch ($Arguments[1]) {
                'init' { return '' }
                'plan' { [IO.File]::WriteAllText((Join-Path $directory 'review.tfplan'), 'saved binary plan'); return '' }
                'show' { return $(if ($script:destructive) { '{"resource_changes":[{"change":{"actions":["delete","create"]}}]}' } else { '{"resource_changes":[{"change":{"actions":["create"]}}]}' }) }
                'apply' {
                    [IO.File]::WriteAllText((Join-Path $directory 'terraform.tfstate'), '{"version":4,"lineage":"initial-lineage","serial":1,"resources":[{"type":"azurerm_resource_group","name":"state"}]}')
                    return ''
                }
                'state' {
                    if ($Arguments[2] -ceq 'push') {
                        if ($script:failPush) { throw 'bootstrap.command.terraform' }
                        $script:remoteState = Get-Content -Raw -LiteralPath $Arguments[-1]
                    }
                    elseif ($Arguments[2] -ceq 'pull') { return $script:remoteState }
                    return ''
                }
                default { throw 'Unexpected Terraform operation.' }
            }
        }
        function script:Invoke-BootstrapAzure { return @{ exists = ($null -ne $script:remoteState) } }
    }
    $review = New-BootstrapReview $parsed $observation State $workspace
    $reviewPath = $review.reviewPath
    $hash = $review.reviewSha256
    Assert-True (Test-Path -LiteralPath $reviewPath) 'A review was not materialized.'
    Assert-BootstrapReview $parsed $observation State $workspace $hash | Out-Null
    $script:assertions++
    Assert-Rejected { Invoke-BootstrapApply $parsed $observation State $workspace ('0' * 64) } 'bootstrap.reviewHash'
    $before = & $module { $script:terraformCalls.Count }
    [IO.File]::AppendAllText((Join-Path $workspace 'state/inputs.tfvars.json'), ' ')
    Assert-Rejected { Invoke-BootstrapApply $parsed $observation State $workspace $hash } 'bootstrap.reviewFileChanged'
    Assert-True ((& $module { $script:terraformCalls.Count }) -eq $before) 'A bad review reached Terraform.'
    $review = New-BootstrapReview $parsed $observation State $workspace
    $alteredObservation = @{} + $observation; $alteredObservation.oidcPrefix = 'repo:wrong/repository'
    Assert-Rejected { Invoke-BootstrapApply $parsed $alteredObservation State $workspace $review.reviewSha256 } 'bootstrap.reviewStale'
    $document = Get-Content -Raw -LiteralPath $reviewPath | ConvertFrom-Json -AsHashtable
    $document.createdAt = [DateTimeOffset]::UtcNow.AddDays(-2).ToString('o')
    [IO.File]::WriteAllText($reviewPath, (ConvertTo-PlatformBootstrapJson $document))
    $oldHash = (Get-FileHash $reviewPath).Hash.ToLowerInvariant()
    Assert-Rejected { Assert-BootstrapReview $parsed $observation State $workspace $oldHash } 'bootstrap.reviewExpired'
    $review = New-BootstrapReview $parsed $observation State $workspace
    $override = Join-Path $workspace 'state/unsafe_override.tf'
    [IO.File]::WriteAllText($override, 'terraform {}')
    Assert-Rejected { Assert-BootstrapReview $parsed $observation State $workspace $review.reviewSha256 } 'bootstrap.reviewExtraConfiguration'
    Remove-Item -LiteralPath $override
    & $module { $script:destructive = $true }
    Assert-Rejected { New-BootstrapReview $parsed $observation State $workspace } 'bootstrap.destructivePlan'
    & $module { $script:destructive = $false }
    $review = New-BootstrapReview $parsed $observation State $workspace
    Invoke-BootstrapApply $parsed $observation State $workspace $review.reviewSha256
    $localState = Join-Path $workspace 'state/terraform.tfstate'
    Assert-True (Test-Path -LiteralPath $localState) 'Initial apply lost the local state.'
    & $module { $script:failPush = $true }
    Assert-Rejected { Move-BootstrapState $parsed $workspace } 'bootstrap.command.terraform'
    Assert-True (Test-Path -LiteralPath $localState) 'Failed migration removed the only local state.'
    & $module { $script:failPush = $false; $script:remoteState = '{"lineage":"foreign-lineage","serial":1,"resources":[]}' }
    Assert-Rejected { Move-BootstrapState $parsed $workspace } 'bootstrap.migrationMismatch'
    Assert-True (Test-Path -LiteralPath $localState) 'Foreign remote lineage destroyed the local backup.'
    & $module { $script:remoteState = $null }
    Move-BootstrapState $parsed $workspace
    Assert-True (-not (Test-Path -LiteralPath $localState) -and (Test-Path -LiteralPath (Join-Path $workspace 'state/remote.json'))) 'Verified migration did not remove its local state.'
    $pushes = & $module { @($script:terraformCalls | Where-Object { $_[1] -ceq 'state' -and $_[2] -ceq 'push' }).Count }
    Move-BootstrapState $parsed $workspace
    Assert-True ((& $module { @($script:terraformCalls | Where-Object { $_[1] -ceq 'state' -and $_[2] -ceq 'push' }).Count }) -eq $pushes) 'A repeated migration pushed state again.'
    $review = New-BootstrapReview $parsed $observation State $workspace
    Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $workspace 'state/versions.tf')) -match 'backend "azurerm"') 'Second execution returned to local state.'

    $credential = @{ issuer = 'https://token.actions.githubusercontent.com'; subject = 'repo:owner/repo:environment:dev'; audiences = @('api://AzureADTokenExchange') }
    Assert-BootstrapFederation @($credential) $credential.subject; $script:assertions++
    foreach ($field in @('issuer', 'subject', 'audiences')) {
        $bad = @{} + $credential; $bad[$field] = $(if ($field -ceq 'audiences') { @('wrong-audience') } else { 'wrong' })
        Assert-Rejected { Assert-BootstrapFederation @($bad) $credential.subject } 'bootstrap.federationDrift'
    }
    Assert-Rejected { Assert-BootstrapFederation @($credential, $credential) $credential.subject } 'bootstrap.federationDrift'
    $subscription = $parsed.definition.azure.subscriptionId
    $roles = @(
        @{ scope = '/container/dev'; roleDefinitionId = '/roles/ba92f5b4-2d11-453d-a403-e96b0029c9fe'; condition = $null },
        @{ scope = "/subscriptions/$subscription/resourceGroups/rg-dev"; roleDefinitionId = '/roles/b24988ac-6180-42a0-ab88-20f7382dd24c'; condition = $null },
        @{ scope = "/subscriptions/$subscription/resourceGroups/rg-dev"; roleDefinitionId = '/roles/f58310d9-a9f6-439a-9e8d-f62e7b41a168'; condition = 'restricted'; conditionVersion = '2.0' }
    )
    Assert-BootstrapRoles $roles @('rg-dev') '/container/dev' $subscription 'restricted'; $script:assertions++
    $roles[0].scope = '/container/prod'
    Assert-Rejected { Assert-BootstrapRoles $roles @('rg-dev') '/container/dev' $subscription 'restricted' } 'bootstrap.roleDrift'
    $roles[0].scope = '/container/dev'; $roles[2].condition = $null
    Assert-Rejected { Assert-BootstrapRoles $roles @('rg-dev') '/container/dev' $subscription 'restricted' } 'bootstrap.roleConditionDrift'
    $roles[2].condition = 'restricted'
    Assert-Rejected { Assert-BootstrapRoles ($roles + @{ scope = "/subscriptions/$subscription"; roleDefinitionId = '/roles/owner' }) @('rg-dev') '/container/dev' $subscription 'restricted' } 'bootstrap.roleDrift'

    & $module {
        $script:apiCalls = [Collections.Generic.List[object]]::new()
        $script:githubEnvironments = @{}; $script:failEnvironment = ''; $script:settings = @{ enabled = $true }
        $script:permissions = @{ default_workflow_permissions = 'read'; can_approve_pull_request_reviews = $false }
        function script:Invoke-BootstrapApi {
            param($Method, $Path, $Body)
            $script:apiCalls.Add(@{ method = $Method; path = $Path; body = $Body })
            if ($Path -like 'users/*') { return @{ login = ($Path -split '/')[-1]; type = 'User'; id = 7 } }
            if ($Path -like '*/permission') { return @{ permission = 'read' } }
            if ($Path -match '/environments/(dev|staging|prod)(.*)$') {
                $environment = $Matches[1]; $suffix = $Matches[2]
                if ($Method -ceq 'PUT' -and $environment -ceq $script:failEnvironment) { throw 'bootstrap.command.gh' }
                if ($suffix -eq '') {
                    if ($Method -ceq 'PUT') {
                        $rules = @(@{ type = 'branch_policy' })
                        if (@($Body.reviewers).Count -gt 0) {
                            $rules += @{ type = 'required_reviewers'; prevent_self_review = $Body.prevent_self_review; reviewers = @($Body.reviewers | ForEach-Object { @{ type = $_.type; reviewer = @{ id = $_.id } } }) }
                        }
                        if (-not $script:githubEnvironments.ContainsKey($environment)) { $script:githubEnvironments[$environment] = @{ branches = @(); variables = @() } }
                        $script:githubEnvironments[$environment].settings = @{ protection_rules = $rules; deployment_branch_policy = $Body.deployment_branch_policy; can_admins_bypass = $Body.can_admins_bypass }
                        return @{}
                    }
                    return $script:githubEnvironments[$environment].settings
                }
                if ($suffix -like '/deployment-branch-policies*') {
                    if ($Method -ceq 'POST') { $script:githubEnvironments[$environment].branches += $Body; return @{} }
                    return @{ total_count = $script:githubEnvironments[$environment].branches.Count; branch_policies = $script:githubEnvironments[$environment].branches }
                }
                if ($Method -cin @('POST', 'PATCH')) {
                    $script:githubEnvironments[$environment].variables = @($script:githubEnvironments[$environment].variables | Where-Object name -CNE $Body.name) + @($Body)
                    return @{}
                }
                return @{ total_count = $script:githubEnvironments[$environment].variables.Count; variables = $script:githubEnvironments[$environment].variables }
            }
            throw 'Unexpected API request.'
        }
    }
    $bindings = @{ dev = @{ client_id = 'dev-client' }; staging = @{ client_id = 'staging-client' }; prod = @{ client_id = 'prod-client' } }
    $desired = Get-BootstrapGithubDesired $parsed.definition $bindings
    $before = Get-BootstrapGithubSnapshot $parsed.definition $observation
    & $module { $script:failEnvironment = 'prod' }
    Assert-Rejected { Set-BootstrapGithub $parsed.definition $desired $before } 'bootstrap.command.gh'
    Assert-True ((& $module { @($script:apiCalls | Where-Object { $_.method -cne 'GET' -and $_.path -like '*/variables*' }).Count }) -eq 0) 'Variables were granted before production protections succeeded.'
    & $module { $script:failEnvironment = 'staging' }
    Assert-Rejected { Set-BootstrapGithub $parsed.definition $desired $before } 'bootstrap.command.gh'
    $partialObservation = @{} + $observation; $partialObservation.environments = @(@{ name = 'prod' })
    $before = Get-BootstrapGithubSnapshot $parsed.definition $partialObservation
    Assert-True ($null -ne $before.environments.prod -and $null -eq $before.environments.dev) 'Partial execution was not discoverable for recovery.'
    & $module { $script:failEnvironment = '' }
    Set-BootstrapGithub $parsed.definition $desired $before
    $fullObservation = @{} + $observation; $fullObservation.environments = @(@{ name = 'dev' }, @{ name = 'staging' }, @{ name = 'prod' })
    $snapshot = Get-BootstrapGithubSnapshot $parsed.definition $fullObservation
    Assert-BootstrapGithub $snapshot $desired; $script:assertions++
    $branchCreates = & $module { @($script:apiCalls | Where-Object { $_.method -ceq 'POST' -and $_.path -like '*/deployment-branch-policies' }).Count }
    $variableWrites = & $module { @($script:apiCalls | Where-Object { $_.method -cne 'GET' -and $_.path -like '*/variables*' }).Count }
    Set-BootstrapGithub $parsed.definition $desired $snapshot
    Assert-True ((& $module { @($script:apiCalls | Where-Object { $_.method -ceq 'POST' -and $_.path -like '*/deployment-branch-policies' }).Count }) -eq $branchCreates) 'Second execution duplicated branch policies.'
    Assert-True ((& $module { @($script:apiCalls | Where-Object { $_.method -cne 'GET' -and $_.path -like '*/variables*' }).Count }) -eq $variableWrites) 'Second execution rewrote unchanged variables.'
    $snapshot.environments.prod.settings.can_admins_bypass = $true
    Assert-Rejected { Assert-BootstrapGithub $snapshot $desired } 'bootstrap.githubProtectionDrift'
    $snapshot.environments.prod.settings.can_admins_bypass = $false
    $snapshot.environments.prod.settings.protection_rules[1].prevent_self_review = $false
    Assert-Rejected { Assert-BootstrapGithub $snapshot $desired } 'bootstrap.githubReviewerDrift'
    $snapshot.environments.prod.settings.protection_rules[1].prevent_self_review = $true
    $snapshot.environments.dev.variables[0].value = 'wrong-client'
    Assert-Rejected { Assert-BootstrapGithub $snapshot $desired } 'bootstrap.githubVariableDrift'
    & $module { $script:githubEnvironments.dev.branches += @{ name = '*'; type = 'tag' } }
    Assert-Rejected { Get-BootstrapGithubSnapshot $parsed.definition $fullObservation } 'bootstrap.branchPolicyConflict'

    $run = @{ status = 'completed'; conclusion = 'success'; event = 'workflow_dispatch'; head_branch = 'main'; head_sha = 'commit'; workflow_id = 99; repository = @{ full_name = $parsed.definition.automation.repository }; display_title = "Platform diagnostic $($parsed.sha256)" }
    $jobs = @{ total_count = 3; jobs = @('dev', 'staging', 'prod' | ForEach-Object { @{ name = "diagnostic-$_"; status = 'completed'; conclusion = 'success'; steps = @('Validate trusted definition', 'Authenticate with environment identity', 'Verify federation and isolation' | ForEach-Object { @{ name = $_; conclusion = 'success' } }) } }) }
    Assert-BootstrapDiagnostic $run $jobs $parsed 'commit' 99; $script:assertions++
    foreach ($conclusion in @('cancelled', 'skipped', 'failure', 'timed_out', 'neutral', 'action_required', '')) {
        $run.conclusion = $conclusion
        Assert-Rejected { Assert-BootstrapDiagnostic $run $jobs $parsed 'commit' 99 } 'bootstrap.diagnosticRunInvalid'
    }
    $run.conclusion = 'success'; $jobs.jobs[0].steps[0].conclusion = 'skipped'
    Assert-Rejected { Assert-BootstrapDiagnostic $run $jobs $parsed 'commit' 99 } 'bootstrap.diagnosticStepFailed'
    $jobs.jobs[0].steps[0].conclusion = 'success'; $jobs.total_count = 4
    Assert-Rejected { Assert-BootstrapDiagnostic $run $jobs $parsed 'commit' 99 } 'bootstrap.diagnosticIncomplete'
    $jobs.total_count = 3
    Assert-Rejected { Assert-BootstrapDiagnostic $run $jobs $parsed 'other-commit' 99 } 'bootstrap.diagnosticRunInvalid'

    # Exercise the public runner with real read-only preflight transports and WhatIf.
    $global:hexagonBootstrapTestWrongTarget = $false
    $global:hexagonBootstrapTestApplyCalls = 0
    function global:az {
        $global:LASTEXITCODE = 0
        if ($args[0] -ceq 'account') {
            @{ tenantId = '11111111-1111-1111-1111-111111111111'; id = $(if ($global:hexagonBootstrapTestWrongTarget) { 'wrong-subscription' } else { '22222222-2222-2222-2222-222222222222' }) } | ConvertTo-Json -Compress
        }
        elseif ($args[0] -ceq 'group' -and $args[1] -ceq 'exists') { 'false' }
        else { throw 'WhatIf attempted an unexpected Azure command.' }
    }
    function global:terraform {
        $global:LASTEXITCODE = 0
        if ($args[0] -ceq 'version') { return '{"terraform_version":"1.17.1"}' }
        $directory = $args[0].Substring(7)
        switch ($args[1]) {
            'init' { return '' }
            'plan' { [IO.File]::WriteAllText((Join-Path $directory 'review.tfplan'), 'CLI saved plan'); return '' }
            'show' { return '{"resource_changes":[]}' }
            'apply' { $global:hexagonBootstrapTestApplyCalls++; return '' }
            default { throw 'Unexpected Terraform CLI command.' }
        }
    }
    function global:gh {
        if ($args[0] -cne 'api' -or $args[1] -cne '--method' -or $args[2] -cne 'GET') { throw 'WhatIf attempted a GitHub mutation.' }
        $global:LASTEXITCODE = 0
        switch -Wildcard ($args[3]) {
            '*/environments*' { '{"total_count":0,"environments":[]}' }
            '*/actions/permissions/workflow' { '{"default_workflow_permissions":"read","can_approve_pull_request_reviews":false}' }
            '*/actions/permissions' { '{"enabled":true}' }
            '*/actions/oidc/customization/sub' { '{"use_default":true,"sub_claim_prefix":"repo:example-owner@123/hexagon-template-devops@456"}' }
            default { '{"full_name":"example-owner/hexagon-template-devops","default_branch":"main","archived":false,"disabled":false,"permissions":{"admin":true},"owner":{"id":123},"id":456}' }
        }
    }
    try {
        $whatIfWorkspace = Join-Path $root "artifacts/bootstrap-whatif-$([guid]::NewGuid().ToString('N'))"
        $result = & (Join-Path $root 'scripts/Invoke-PlatformBootstrapStage.ps1') -Definition (Join-Path $root 'examples/platform-bootstrap.yaml') -Mode Prepare -Stage State -Workspace $whatIfWorkspace -WhatIf
        $model = $result -join "`n" | ConvertFrom-Json
        Assert-True ($model.status -ceq 'Unverified' -and -not $model.readyToApply -and -not (Test-Path -LiteralPath $whatIfWorkspace)) 'WhatIf created execution files or claimed readiness.'
        $global:hexagonBootstrapTestWrongTarget = $true
        $result = & (Join-Path $root 'scripts/Invoke-PlatformBootstrapStage.ps1') -Definition (Join-Path $root 'examples/platform-bootstrap.yaml') -Mode Prepare -Stage State -Workspace $whatIfWorkspace
        $model = $result -join "`n" | ConvertFrom-Json
        Assert-True ($model.status -ceq 'Blocked' -and $model.checks[0].code -ceq 'bootstrap.targetMismatch' -and -not (Test-Path -LiteralPath $whatIfWorkspace)) 'Wrong target was not rejected before the first filesystem write.'
        $global:hexagonBootstrapTestWrongTarget = $false
        $result = & (Join-Path $root 'scripts/Invoke-PlatformBootstrapStage.ps1') -Definition (Join-Path $root 'examples/platform-bootstrap.yaml') -Mode Prepare -Stage State -Workspace $workspace
        Assert-True (($result -join "`n" | ConvertFrom-Json).checks[0].code -ceq 'bootstrap.workspaceOutsideArtifacts') 'An execution workspace outside artifacts was accepted.'
        if (-not $IsWindows) {
            $wrongCase = Join-Path $root "ARTIFACTS/bootstrap-invalid-$([guid]::NewGuid().ToString('N'))"
            $result = & (Join-Path $root 'scripts/Invoke-PlatformBootstrapStage.ps1') -Definition (Join-Path $root 'examples/platform-bootstrap.yaml') -Mode Prepare -Stage State -Workspace $wrongCase
            Assert-True (($result -join "`n" | ConvertFrom-Json).checks[0].code -ceq 'bootstrap.workspaceOutsideArtifacts' -and -not (Test-Path -LiteralPath $wrongCase)) 'Unix accepted a differently cased directory outside the ignored artifacts path.'
        }
        $result = & (Join-Path $root 'scripts/Invoke-PlatformBootstrapStage.ps1') -Definition (Join-Path $root 'examples/platform-bootstrap.yaml') -Mode Prepare -Stage State -Workspace $whatIfWorkspace
        $model = $result -join "`n" | ConvertFrom-Json
        Assert-True ($model.status -ceq 'Prepared' -and $model.readyToApply -and -not $model.platformVerified) 'CLI Prepare did not create a stage-scoped review.'
        $hash = $model.details.reviewSha256
        if (-not $IsWindows) {
            $cacheLink = Join-Path $whatIfWorkspace 'state/.terraform/providers/registry.terraform.io/hashicorp/azurerm/5.13.0/linux_amd64'
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($cacheLink)) | Out-Null
            New-Item -ItemType SymbolicLink -Path $cacheLink -Target $workspace | Out-Null
        }
        $result = & (Join-Path $root 'scripts/Invoke-PlatformBootstrapStage.ps1') -Definition (Join-Path $root 'examples/platform-bootstrap.yaml') -Mode Apply -Stage State -Workspace $whatIfWorkspace -ReviewSha256 ('0' * 64)
        Assert-True (($result -join "`n" | ConvertFrom-Json).status -ceq 'Blocked' -and $global:hexagonBootstrapTestApplyCalls -eq 0) 'An invalid CLI review reached apply.'
        $result = & (Join-Path $root 'scripts/Invoke-PlatformBootstrapStage.ps1') -Definition (Join-Path $root 'examples/platform-bootstrap.yaml') -Mode Apply -Stage State -Workspace $whatIfWorkspace -ReviewSha256 $hash
        $model = $result -join "`n" | ConvertFrom-Json
        Assert-True ($model.status -ceq 'Applied' -and -not $model.platformVerified -and $global:hexagonBootstrapTestApplyCalls -eq 1) 'CLI Apply failed or claimed platform verification.'
        if (-not $IsWindows) {
            $unsafeLink = Join-Path $whatIfWorkspace 'state/linked-configuration'
            New-Item -ItemType SymbolicLink -Path $unsafeLink -Target $workspace | Out-Null
            $result = & (Join-Path $root 'scripts/Invoke-PlatformBootstrapStage.ps1') -Definition (Join-Path $root 'examples/platform-bootstrap.yaml') -Mode Prepare -Stage State -Workspace $whatIfWorkspace
            Assert-True (($result -join "`n" | ConvertFrom-Json).checks[0].code -ceq 'bootstrap.workspaceLink') 'A configuration link escaped the workspace boundary.'
            Remove-Item -LiteralPath $unsafeLink
        }
        $changed = Join-Path $workspace 'changed-storage.yaml'
        [IO.File]::WriteAllText($changed, (Get-Content -Raw -LiteralPath (Join-Path $root 'examples/platform-bootstrap.yaml')).Replace('sthexagontemplatestate', 'stchangedstorage'))
        $result = & (Join-Path $root 'scripts/Invoke-PlatformBootstrapStage.ps1') -Definition $changed -Mode Prepare -Stage State -Workspace $whatIfWorkspace
        Assert-True (($result -join "`n" | ConvertFrom-Json).checks[0].code -ceq 'bootstrap.workspaceTargetChanged') 'A workspace silently changed its storage target.'
    }
    finally {
        Remove-Item Function:az, Function:gh, Function:terraform
        Remove-Variable -Name hexagonBootstrapTestWrongTarget -Scope Global
        Remove-Variable -Name hexagonBootstrapTestApplyCalls -Scope Global
        if (Test-Path -LiteralPath $whatIfWorkspace) {
            $resolvedArtifacts = [IO.Path]::GetFullPath((Join-Path $root 'artifacts'))
            $resolvedProbe = [IO.Path]::GetFullPath($whatIfWorkspace)
            if ([IO.Path]::GetDirectoryName($resolvedProbe) -cne $resolvedArtifacts -or -not [IO.Path]::GetFileName($resolvedProbe).StartsWith('bootstrap-whatif-')) { throw 'Unsafe CLI test cleanup.' }
            Remove-Item -LiteralPath $resolvedProbe -Recurse -Force
        }
    }
}
finally {
    $resolved = [IO.Path]::GetFullPath($workspace)
    if ([IO.Path]::GetDirectoryName($resolved) -cne $temporaryParent -or -not [IO.Path]::GetFileName($resolved).StartsWith('hexagon-bootstrap-execution-')) { throw 'Unsafe test cleanup target.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
    Remove-Module PlatformBootstrap.Execution -ErrorAction SilentlyContinue
}
Write-Host "Bootstrap execution tests passed: $script:assertions assertions; no live platform writes."
