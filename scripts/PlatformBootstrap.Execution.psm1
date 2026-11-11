Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PlatformBootstrap.psm1')
$script:bootstrapRoot = Split-Path -Parent $PSScriptRoot

function Get-ExecutionHash([string] $Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Invoke-BootstrapNative {
    param([ValidateSet('az', 'gh', 'terraform')][string] $Tool, [string[]] $Arguments, [string] $InputText, [int[]] $ExitCodes = @(0))
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        if ($InputText) { $output = $InputText | & $Tool @Arguments 2>&1 }
        else { $output = & $Tool @Arguments 2>&1 }
        if ($LASTEXITCODE -notin $ExitCodes) { throw 'Native command failed.' }
        return ($output | ForEach-Object ToString) -join "`n"
    }
    catch { throw "bootstrap.command.$Tool" }
}

function Invoke-BootstrapApi {
    param([ValidateSet('GET', 'PUT', 'POST', 'PATCH')][string] $Method, [string] $Path, [object] $Body)
    $arguments = @('api', '--method', $Method, $Path, '-H', 'X-GitHub-Api-Version: 2026-03-10')
    $inputText = ''
    if ($null -ne $Body) { $arguments += @('--input', '-'); $inputText = ConvertTo-PlatformBootstrapJson $Body }
    $text = Invoke-BootstrapNative -Tool gh -Arguments $arguments -InputText $inputText
    if ($text.Trim()) { return $text | ConvertFrom-Json -AsHashtable -Depth 64 }
}

function Invoke-BootstrapAzure {
    param([string[]] $Arguments, [hashtable] $Definition)
    $text = Invoke-BootstrapNative -Tool az -Arguments ($Arguments + @('--subscription', $Definition.azure.subscriptionId, '--only-show-errors', '--output', 'json'))
    return $text | ConvertFrom-Json -AsHashtable -Depth 64
}

function Get-BootstrapSourceHash {
    $paths = @('scripts/PlatformBootstrap.psm1', 'scripts/PlatformBootstrap.Execution.psm1', 'scripts/Invoke-PlatformBootstrap.ps1',
        'scripts/Invoke-PlatformBootstrapStage.ps1', 'scripts/Test-PlatformFederation.ps1', '.github/workflows/platform-diagnostic.yml',
        'contracts/schemas/platform-bootstrap-v1.schema.json', 'contracts/schemas/platform-bootstrap-review-v1.schema.json')
    $paths += @(Get-ChildItem -LiteralPath (Join-Path $script:bootstrapRoot 'terraform/bootstrap/azure'), (Join-Path $script:bootstrapRoot 'terraform/bootstrap/azure-access') -File -Force |
        Where-Object { $_.Extension -eq '.tf' -or $_.Name -eq '.terraform.lock.hcl' } |
        ForEach-Object { [IO.Path]::GetRelativePath($script:bootstrapRoot, $_.FullName).Replace('\', '/') })
    $manifest = @($paths | Sort-Object | ForEach-Object { "$_`:$(Get-ExecutionHash (Join-Path $script:bootstrapRoot $_))" }) -join "`n"
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($manifest))).ToLowerInvariant()
}

function Get-BootstrapContainers([hashtable] $Definition) {
    $containers = @{}
    foreach ($environment in @(Get-BootstrapEnvironments $Definition)) {
        $name = "$($Definition.state.container)-$environment"
        if ($name.Length -gt 63) { throw 'bootstrap.containerTooLong' }
        $containers[$environment] = $name
    }
    return $containers
}

function Get-BootstrapBackend([hashtable] $Definition, [string] $Stage) {
    return @{
        resource_group_name = $Definition.state.resourceGroup
        storage_account_name = $Definition.state.storageAccount
        container_name = $Definition.state.container
        key = "$($Definition.product)/bootstrap/$($Stage.ToLowerInvariant()).tfstate"
        tenant_id = $Definition.azure.tenantId
        subscription_id = $Definition.azure.subscriptionId
        use_azuread_auth = $true
        use_cli = $true
    }
}

function Write-BootstrapFile([string] $Path, [object] $Value) {
    [IO.File]::WriteAllText($Path, (ConvertTo-PlatformBootstrapJson $Value) + "`n", [Text.UTF8Encoding]::new($false))
}

function Get-BootstrapTerraformVariables([hashtable] $Definition, [hashtable] $Observation, [string] $Stage) {
    $containers = Get-BootstrapContainers $Definition
    if ($Stage -ceq 'State') {
        $groups = @{}
        foreach ($environment in @(Get-BootstrapEnvironments $Definition)) {
            foreach ($group in $Definition.environments[$environment].resourceGroups) { $groups[$group] = $environment }
        }
        return @{
            product = $Definition.product
            subscription_id = $Definition.azure.subscriptionId; tenant_id = $Definition.azure.tenantId
            resource_group_name = $Definition.state.resourceGroup; location = $Definition.azure.location
            storage_account_name = $Definition.state.storageAccount; container_name = $Definition.state.container
            tags = @{ product = $Definition.product; 'managed-by' = 'terraform' }
            environment_groups = $groups; environment_containers = $containers
        }
    }
    $environments = @{}
    foreach ($environment in @(Get-BootstrapEnvironments $Definition)) {
        $environments[$environment] = @{
            identity_name = $Definition.environments[$environment].identityName
            resource_groups = @($Definition.environments[$environment].resourceGroups)
            state_container = $containers[$environment]
        }
    }
    return @{
        subscription_id = $Definition.azure.subscriptionId; tenant_id = $Definition.azure.tenantId
        product = $Definition.product; location = $Definition.azure.location
        resource_group_name = $Definition.state.resourceGroup; storage_account_name = $Definition.state.storageAccount
        oidc_prefix = $Observation.oidcPrefix; environments = $environments
    }
}

function Initialize-BootstrapTerraform {
    param([string] $Directory, [hashtable] $Definition, [string] $Stage, [switch] $Local)
    $arguments = @("-chdir=$Directory", 'init', '-input=false', '-lockfile=readonly', '-no-color')
    if (-not $Local) {
        $backend = Get-BootstrapBackend $Definition $Stage
        Write-BootstrapFile (Join-Path $Directory 'backend.json') $backend
        $arguments += @('-reconfigure', '-backend-config=backend.json')
    }
    Invoke-BootstrapNative terraform $arguments | Out-Null
}

function Get-BootstrapGithubDesired {
    param([hashtable] $Definition, [hashtable] $Bindings)
    $desired = @{}
    foreach ($environment in @(Get-BootstrapEnvironments $Definition)) {
        $reviewers = @(
            foreach ($login in $Definition.environments[$environment].reviewers) {
                $user = Invoke-BootstrapApi GET "users/$login"
                if ($user.type -cne 'User' -or $user.login -ine $login -or $user.id -isnot [long] -and $user.id -isnot [int]) { throw 'bootstrap.reviewerInvalid' }
                $permission = Invoke-BootstrapApi GET "repos/$($Definition.automation.repository)/collaborators/$login/permission"
                if ($permission.permission -cnotin @('read', 'write', 'admin', 'maintain', 'triage')) { throw 'bootstrap.reviewerAccess' }
                @{ type = 'User'; id = $user.id }
            }
        )
        $desired[$environment] = @{
            environment = @{
                wait_timer = 0; prevent_self_review = ($reviewers.Count -gt 0); reviewers = $reviewers
                can_admins_bypass = $false
                deployment_branch_policy = @{ protected_branches = $false; custom_branch_policies = $true }
            }
            variables = @{
                AZURE_CLIENT_ID = $Bindings[$environment].client_id
                AZURE_TENANT_ID = $Definition.azure.tenantId
                AZURE_SUBSCRIPTION_ID = $Definition.azure.subscriptionId
            }
        }
    }
    return $desired
}

function Get-BootstrapGithubSnapshot {
    param([hashtable] $Definition, [hashtable] $Observation)
    $snapshot = @{ actions = $Observation.actions; permissions = $Observation.workflowPermissions; environments = @{} }
    foreach ($environment in @(Get-BootstrapEnvironments $Definition)) {
        $matches = @($Observation.environments | Where-Object name -CEQ $environment)
        if ($matches.Count -eq 0) { $snapshot.environments[$environment] = $null; continue }
        $base = "repos/$($Definition.automation.repository)/environments/$environment"
        $settings = Invoke-BootstrapApi GET $base
        $policies = Invoke-BootstrapApi GET "$base/deployment-branch-policies?per_page=100"
        $variables = Invoke-BootstrapApi GET "$base/variables?per_page=100"
        if ($policies.total_count -ne @($policies.branch_policies).Count -or $variables.total_count -ne @($variables.variables).Count) { throw 'bootstrap.githubIncomplete' }
        if (@($policies.branch_policies | Where-Object { $_.name -cne 'main' -or $_.type -cne 'branch' }).Count -gt 0) { throw 'bootstrap.branchPolicyConflict' }
        if (@($settings.protection_rules | Where-Object { $_.type -cnotin @('required_reviewers', 'branch_policy', 'wait_timer') }).Count -gt 0) { throw 'bootstrap.protectionConflict' }
        # Ignore API timestamps and IDs that change without changing the reviewed settings.
        $snapshot.environments[$environment] = @{
            settings = @{
                protection_rules = @($settings.protection_rules | ForEach-Object {
                    if ($_.type -ceq 'required_reviewers') { @{ type = $_.type; prevent_self_review = $_.prevent_self_review; reviewers = @($_.reviewers | ForEach-Object { @{ type = $_.type; id = $_.reviewer.id } } | Sort-Object id) } }
                    elseif ($_.type -ceq 'wait_timer') { @{ type = $_.type; wait_timer = $_.wait_timer } }
                    else { @{ type = $_.type } }
                } | Sort-Object type)
                deployment_branch_policy = $settings.deployment_branch_policy
                can_admins_bypass = $settings.can_admins_bypass
            }
            branches = @($policies.branch_policies | ForEach-Object { @{ name = $_.name; type = $_.type } })
            variables = @($variables.variables | Where-Object name -CIn @('AZURE_CLIENT_ID', 'AZURE_TENANT_ID', 'AZURE_SUBSCRIPTION_ID') | ForEach-Object { @{ name = $_.name; value = $_.value } } | Sort-Object name)
        }
    }
    return $snapshot
}

function Set-BootstrapGithub {
    param([hashtable] $Definition, [hashtable] $Desired, [hashtable] $Before)
    $repo = "repos/$($Definition.automation.repository)"
    if (-not $Before.actions.enabled) { Invoke-BootstrapApi PUT "$repo/actions/permissions" @{ enabled = $true } | Out-Null }
    if ($Before.permissions.default_workflow_permissions -cne 'read' -or $Before.permissions.can_approve_pull_request_reviews) {
        Invoke-BootstrapApi PUT "$repo/actions/permissions/workflow" @{ default_workflow_permissions = 'read'; can_approve_pull_request_reviews = $false } | Out-Null
    }
    # Configure production protections before handing out deployment variables for any environment.
    foreach ($environment in @(@('prod', 'staging', 'dev') | Where-Object { $Desired.ContainsKey($_) })) {
        $base = "$repo/environments/$environment"
        Invoke-BootstrapApi PUT $base $Desired[$environment].environment | Out-Null
        $previous = $Before.environments[$environment]
        if ($null -eq $previous -or $previous.branches.Count -eq 0) {
            Invoke-BootstrapApi POST "$base/deployment-branch-policies" @{ name = 'main'; type = 'branch' } | Out-Null
        }
        foreach ($name in @('AZURE_CLIENT_ID', 'AZURE_TENANT_ID', 'AZURE_SUBSCRIPTION_ID')) {
            $existing = @(); if ($null -ne $previous) { $existing = @($previous.variables | Where-Object name -CEQ $name) }
            if ($existing.Count -eq 1 -and $existing[0].value -ceq $Desired[$environment].variables[$name]) { continue }
            $body = @{ name = $name; value = $Desired[$environment].variables[$name] }
            if ($existing.Count -eq 1) { Invoke-BootstrapApi PATCH "$base/variables/$name" $body | Out-Null }
            else { Invoke-BootstrapApi POST "$base/variables" $body | Out-Null }
        }
    }
}

function Assert-BootstrapGithub {
    param([hashtable] $Snapshot, [hashtable] $Desired)
    if (-not $Snapshot.actions.enabled -or $Snapshot.permissions.default_workflow_permissions -cne 'read' -or $Snapshot.permissions.can_approve_pull_request_reviews) { throw 'bootstrap.githubActionsDrift' }
    foreach ($environment in @(@('dev', 'staging', 'prod') | Where-Object { $Desired.ContainsKey($_) })) {
        $actual = $Snapshot.environments[$environment]
        if ($null -eq $actual -or $actual.settings.can_admins_bypass -ne $false -or
            $actual.settings.deployment_branch_policy.protected_branches -ne $false -or
            $actual.settings.deployment_branch_policy.custom_branch_policies -ne $true -or
            $actual.branches.Count -ne 1 -or $actual.branches[0].name -cne 'main' -or $actual.branches[0].type -cne 'branch') { throw 'bootstrap.githubProtectionDrift' }
        $rules = @($actual.settings.protection_rules | Where-Object type -CEQ 'required_reviewers')
        $reviewers = $Desired[$environment].environment.reviewers
        if ($reviewers.Count -gt 0) {
            if ($rules.Count -ne 1 -or $rules[0].prevent_self_review -ne $true -or
                (ConvertTo-PlatformBootstrapJson @($rules[0].reviewers | Sort-Object id)) -cne (ConvertTo-PlatformBootstrapJson @($reviewers | Sort-Object id))) { throw 'bootstrap.githubReviewerDrift' }
        }
        elseif ($rules.Count -gt 0) { throw 'bootstrap.githubReviewerDrift' }
        if (@($actual.settings.protection_rules | Where-Object { $_.type -ceq 'wait_timer' -and $_.wait_timer -ne 0 }).Count -gt 0) { throw 'bootstrap.githubProtectionDrift' }
        foreach ($name in $Desired[$environment].variables.Keys) {
            $values = @($actual.variables | Where-Object name -CEQ $name)
            if ($values.Count -ne 1 -or $values[0].value -cne $Desired[$environment].variables[$name]) { throw 'bootstrap.githubVariableDrift' }
        }
    }
}

function Get-BootstrapBindings([hashtable] $Definition, [string] $Directory) {
    if (-not (Test-Path -LiteralPath (Join-Path $Directory 'remote.json'))) { throw 'bootstrap.stateNotRemote' }
    Initialize-BootstrapTerraform -Directory $Directory -Definition $Definition -Stage Access
    $outputs = (Invoke-BootstrapNative terraform @("-chdir=$Directory", 'output', '-json')) | ConvertFrom-Json -AsHashtable
    return $outputs.environments.value
}

function New-BootstrapReview {
    param([hashtable] $Parsed, [hashtable] $Observation, [ValidateSet('State', 'Access', 'GitHub')][string] $Stage, [string] $Workspace)
    $definition = $Parsed.definition
    $directory = Join-Path $Workspace $Stage.ToLowerInvariant()
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $files = @{}
    if ($Stage -ceq 'GitHub') {
        $bindings = Get-BootstrapBindings $definition (Join-Path $Workspace 'access')
        $desired = Get-BootstrapGithubDesired $definition $bindings
        $before = Get-BootstrapGithubSnapshot $definition $Observation
        Write-BootstrapFile (Join-Path $directory 'github.json') @{ desired = $desired; before = $before }
        $files['github.json'] = Get-ExecutionHash (Join-Path $directory 'github.json')
    }
    else {
        $source = Join-Path $script:bootstrapRoot $(if ($Stage -ceq 'State') { 'terraform/bootstrap/azure' } else { 'terraform/bootstrap/azure-access' })
        foreach ($file in Get-ChildItem -LiteralPath $source -File -Force | Where-Object { $_.Extension -eq '.tf' -or $_.Name -eq '.terraform.lock.hcl' }) {
            Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $directory $file.Name) -Force
        }
        $local = $Stage -ceq 'State' -and -not (Test-Path -LiteralPath (Join-Path $directory 'remote.json'))
        if ($local) {
            $versions = Join-Path $directory 'versions.tf'
            $text = Get-Content -Raw -LiteralPath $versions
            [IO.File]::WriteAllText($versions, ($text -replace '(?s)backend "azurerm"\s*\{[^}]*\}', 'backend "local" {}'))
        }
        elseif ($Stage -ceq 'Access' -and -not (Test-Path -LiteralPath (Join-Path $Workspace 'state/remote.json'))) { throw 'bootstrap.stateNotRemote' }
        Write-BootstrapFile (Join-Path $directory 'inputs.tfvars.json') (Get-BootstrapTerraformVariables $definition $Observation $Stage)
        Initialize-BootstrapTerraform -Directory $directory -Definition $definition -Stage $Stage -Local:$local
        Invoke-BootstrapNative terraform @("-chdir=$directory", 'plan', '-input=false', '-lock-timeout=60s', '-no-color', '-var-file=inputs.tfvars.json', '-out=review.tfplan') | Out-Null
        $plan = Invoke-BootstrapNative terraform @("-chdir=$directory", 'show', '-json', 'review.tfplan')
        $model = $plan | ConvertFrom-Json -AsHashtable -Depth 100
        if ($model.ContainsKey('resource_changes') -and @($model.resource_changes | Where-Object { $_.change.actions -contains 'delete' }).Count -gt 0) { throw 'bootstrap.destructivePlan' }
        [IO.File]::WriteAllText((Join-Path $directory 'review.plan.json'), $plan)
        foreach ($file in Get-ChildItem -LiteralPath $directory -File -Force | Where-Object { $_.Extension -eq '.tf' -or $_.Name -in @('.terraform.lock.hcl', 'inputs.tfvars.json', 'review.tfplan', 'review.plan.json', 'backend.json') }) {
            $files[$file.Name] = Get-ExecutionHash $file.FullName
        }
    }
    $review = @{
        apiVersion = 'hexagon.ec/platform-bootstrap-review/v1'; stage = $Stage
        definitionSha256 = $Parsed.sha256; sourceSha256 = Get-BootstrapSourceHash
        oidcPrefix = $Observation.oidcPrefix; repositoryId = $Observation.repository.id
        createdAt = [DateTimeOffset]::UtcNow.ToString('o'); files = $files
    }
    Write-BootstrapFile (Join-Path $directory 'review.json') $review
    return @{ reviewPath = Join-Path $directory 'review.json'; reviewSha256 = Get-ExecutionHash (Join-Path $directory 'review.json') }
}

function Assert-BootstrapReview {
    param([hashtable] $Parsed, [hashtable] $Observation, [string] $Stage, [string] $Workspace, [string] $ReviewSha256)
    $directory = Join-Path $Workspace $Stage.ToLowerInvariant()
    $path = Join-Path $directory 'review.json'
    if ($ReviewSha256 -cnotmatch '^[0-9a-f]{64}$' -or (Get-ExecutionHash $path) -cne $ReviewSha256) { throw 'bootstrap.reviewHash' }
    $json = Get-Content -Raw -LiteralPath $path
    if (-not ($json | Test-Json -SchemaFile (Join-Path $script:bootstrapRoot 'contracts/schemas/platform-bootstrap-review-v1.schema.json') -ErrorAction SilentlyContinue)) { throw 'bootstrap.reviewInvalid' }
    $review = $json | ConvertFrom-Json -AsHashtable
    $age = [DateTimeOffset]::UtcNow - [DateTimeOffset] $review.createdAt
    if ($age.TotalHours -gt 24 -or $age.TotalSeconds -lt -60) { throw 'bootstrap.reviewExpired' }
    if ($review.stage -cne $Stage -or $review.definitionSha256 -cne $Parsed.sha256 -or
        $review.sourceSha256 -cne (Get-BootstrapSourceHash) -or $review.oidcPrefix -cne $Observation.oidcPrefix -or $review.repositoryId -ne $Observation.repository.id) { throw 'bootstrap.reviewStale' }
    foreach ($name in $review.files.Keys) {
        if ((Get-ExecutionHash (Join-Path $directory $name)) -cne $review.files[$name]) { throw 'bootstrap.reviewFileChanged' }
    }
    $required = $(if ($Stage -ceq 'GitHub') { @('github.json') } else { @('review.tfplan', 'review.plan.json', 'inputs.tfvars.json', 'versions.tf', 'main.tf', 'providers.tf', 'variables.tf', 'outputs.tf', '.terraform.lock.hcl') })
    foreach ($name in $required) { if (-not $review.files.ContainsKey($name)) { throw 'bootstrap.reviewIncomplete' } }
    # Extra override/configuration files must not affect a reviewed binary plan or backend setup.
    foreach ($file in Get-ChildItem -LiteralPath $directory -File -Force | Where-Object { $_.Name -match '\.tf(?:\.json)?$|\.tfvars(?:\.json)?$' }) {
        if (-not $review.files.ContainsKey($file.Name)) { throw 'bootstrap.reviewExtraConfiguration' }
    }
    return $review
}

function Invoke-BootstrapApply {
    param([hashtable] $Parsed, [hashtable] $Observation, [string] $Stage, [string] $Workspace, [string] $ReviewSha256)
    Assert-BootstrapReview @PSBoundParameters | Out-Null
    $directory = Join-Path $Workspace $Stage.ToLowerInvariant()
    if ($Stage -ceq 'GitHub') {
        $review = Get-Content -Raw -LiteralPath (Join-Path $directory 'github.json') | ConvertFrom-Json -AsHashtable
        $actual = Get-BootstrapGithubSnapshot $Parsed.definition $Observation
        if ((ConvertTo-PlatformBootstrapJson $actual) -cne (ConvertTo-PlatformBootstrapJson $review.before)) { throw 'bootstrap.githubPlanStale' }
        Set-BootstrapGithub $Parsed.definition $review.desired $actual
        $fresh = Get-PlatformBootstrapObservation $Parsed.definition
        Assert-BootstrapGithub (Get-BootstrapGithubSnapshot $Parsed.definition $fresh) $review.desired
    }
    else {
        Invoke-BootstrapNative terraform @("-chdir=$directory", 'apply', '-input=false', '-lock-timeout=60s', '-no-color', 'review.tfplan') | Out-Null
        if ($Stage -ceq 'Access') { Write-BootstrapFile (Join-Path $directory 'remote.json') @{ definitionSha256 = $Parsed.sha256 } }
    }
    Write-BootstrapFile (Join-Path $directory 'applied.json') @{ reviewSha256 = $ReviewSha256; definitionSha256 = $Parsed.sha256 }
}

function Move-BootstrapState {
    param([hashtable] $Parsed, [string] $Workspace)
    $definition = $Parsed.definition
    $directory = Join-Path $Workspace 'state'
    $receipt = Get-Content -Raw -LiteralPath (Join-Path $directory 'applied.json') | ConvertFrom-Json -AsHashtable
    if ($receipt.definitionSha256 -cne $Parsed.sha256) { throw 'bootstrap.migrationDefinition' }
    $localPath = Join-Path $directory 'terraform.tfstate'
    $remoteDirectory = Join-Path $Workspace 'state-remote'
    [IO.Directory]::CreateDirectory($remoteDirectory) | Out-Null
    Copy-Item -LiteralPath (Join-Path $script:bootstrapRoot 'terraform/bootstrap/azure/versions.tf') -Destination (Join-Path $remoteDirectory 'versions.tf') -Force
    Copy-Item -LiteralPath (Join-Path $script:bootstrapRoot 'terraform/bootstrap/azure/.terraform.lock.hcl') -Destination (Join-Path $remoteDirectory '.terraform.lock.hcl') -Force
    Initialize-BootstrapTerraform -Directory $remoteDirectory -Definition $definition -Stage State
    if (-not (Test-Path -LiteralPath $localPath)) {
        if (-not (Test-Path -LiteralPath (Join-Path $directory 'remote.json'))) { throw 'bootstrap.localStateMissing' }
        $marker = Get-Content -Raw -LiteralPath (Join-Path $directory 'remote.json') | ConvertFrom-Json -AsHashtable
        $current = (Invoke-BootstrapNative terraform @("-chdir=$remoteDirectory", 'state', 'pull')) | ConvertFrom-Json -AsHashtable -Depth 100
        if ($marker.definitionSha256 -cne $Parsed.sha256 -or $current.lineage -cne $marker.lineage -or @($current.resources).Count -eq 0) { throw 'bootstrap.migrationMismatch' }
        return
    }
    $localText = Get-Content -Raw -LiteralPath $localPath
    $localState = $localText | ConvertFrom-Json -AsHashtable -Depth 100
    if (@($localState.resources).Count -eq 0) { throw 'bootstrap.localStateEmpty' }
    $backend = Get-BootstrapBackend $definition State
    $exists = Invoke-BootstrapAzure @('storage', 'blob', 'exists', '--auth-mode', 'login', '--account-name', $definition.state.storageAccount, '--container-name', $definition.state.container, '--name', $backend.key) $definition
    if ($exists.exists -isnot [bool]) { throw 'bootstrap.migrationResponseInvalid' }
    $needsPush = -not $exists.exists
    if (-not $needsPush) {
        $existingText = Invoke-BootstrapNative terraform @("-chdir=$remoteDirectory", 'state', 'pull')
        $existing = $existingText | ConvertFrom-Json -AsHashtable -Depth 100
        # Backend init may create an empty state blob with its own lineage. Terraform accepts
        # a normal, locked push into that state; a populated or previously used state is never replaced.
        $needsPush = @($existing.resources).Count -eq 0 -and (-not $existing.outputs -or $existing.outputs.Count -eq 0) -and $existing.serial -le 1
    }
    if ($needsPush) {
        # State push takes the remote lock and refuses mismatching lineage/newer serial; never use -force.
        Invoke-BootstrapNative terraform @("-chdir=$remoteDirectory", 'state', 'push', '-lock-timeout=60s', $localPath) | Out-Null
    }
    $remoteText = Invoke-BootstrapNative terraform @("-chdir=$remoteDirectory", 'state', 'pull')
    $remote = $remoteText | ConvertFrom-Json -AsHashtable -Depth 100
    # Terraform may advance the serial by one while importing the local snapshot.
    if ($remote.lineage -cne $localState.lineage -or $remote.serial -lt $localState.serial -or
        $remote.serial -gt ($localState.serial + 1) -or
        (ConvertTo-PlatformBootstrapJson $remote.resources) -cne (ConvertTo-PlatformBootstrapJson $localState.resources)) { throw 'bootstrap.migrationMismatch' }
    Copy-Item -LiteralPath (Join-Path $script:bootstrapRoot 'terraform/bootstrap/azure/versions.tf') -Destination (Join-Path $directory 'versions.tf') -Force
    Initialize-BootstrapTerraform -Directory $directory -Definition $definition -Stage State
    $confirmation = (Invoke-BootstrapNative terraform @("-chdir=$directory", 'state', 'pull')) | ConvertFrom-Json -AsHashtable -Depth 100
    if ($confirmation.lineage -cne $localState.lineage -or $confirmation.serial -ne $remote.serial) { throw 'bootstrap.migrationMismatch' }
    Write-BootstrapFile (Join-Path $directory 'remote.json') @{ definitionSha256 = $Parsed.sha256; lineage = $remote.lineage }
    # Exact known files inside the validated workspace; backups survive every earlier failure.
    foreach ($name in @('terraform.tfstate', 'terraform.tfstate.backup')) {
        $path = Join-Path $directory $name
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
}

function Assert-BootstrapFederation {
    param([object[]] $Credentials, [string] $Subject)
    if ($Credentials.Count -ne 1 -or $Credentials[0].issuer -cne 'https://token.actions.githubusercontent.com' -or
        $Credentials[0].subject -cne $Subject -or @($Credentials[0].audiences).Count -ne 1 -or
        $Credentials[0].audiences[0] -cne 'api://AzureADTokenExchange') { throw 'bootstrap.federationDrift' }
}

function Assert-BootstrapRoles {
    param([object[]] $Assignments, [string[]] $Groups, [string] $ContainerScope, [string] $SubscriptionId, [string] $Condition)
    $expected = @{}
    $expected["$ContainerScope/ba92f5b4-2d11-453d-a403-e96b0029c9fe".ToLowerInvariant()] = $null
    foreach ($group in $Groups) {
        $scope = "/subscriptions/$SubscriptionId/resourceGroups/$group"
        $expected["$scope/b24988ac-6180-42a0-ab88-20f7382dd24c".ToLowerInvariant()] = $null
        $expected["$scope/f58310d9-a9f6-439a-9e8d-f62e7b41a168".ToLowerInvariant()] = $Condition
    }
    if ($Assignments.Count -ne $expected.Count) { throw 'bootstrap.roleDrift' }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($assignment in $Assignments) {
        $role = ($assignment.roleDefinitionId -split '/')[-1]
        $key = "$($assignment.scope)/$role".ToLowerInvariant()
        if (-not $expected.ContainsKey($key) -or -not $seen.Add($key)) { throw 'bootstrap.roleDrift' }
        if ($null -ne $expected[$key]) {
            if ($assignment.conditionVersion -cne '2.0' -or ($assignment.condition -replace '\s', '') -cne ($expected[$key] -replace '\s', '')) { throw 'bootstrap.roleConditionDrift' }
        }
        elseif ($assignment.ContainsKey('condition') -and $assignment.condition) { throw 'bootstrap.roleConditionDrift' }
    }
}

function Assert-BootstrapDiagnostic {
    param([hashtable] $Run, [hashtable] $Jobs, [hashtable] $Parsed, [string] $Commit, [long] $WorkflowId)
    if ($Run.status -cne 'completed' -or $Run.conclusion -cne 'success' -or $Run.event -cne 'workflow_dispatch' -or
        $Run.head_branch -cne 'main' -or $Run.head_sha -cne $Commit -or $Run.workflow_id -ne $WorkflowId -or
        $Run.repository.full_name -ine $Parsed.definition.automation.repository -or
        $Run.display_title -cne "Platform diagnostic $($Parsed.sha256)") { throw 'bootstrap.diagnosticRunInvalid' }
    $environments = @(Get-BootstrapEnvironments $Parsed.definition)
    if ($Jobs.total_count -ne $environments.Count -or @($Jobs.jobs).Count -ne $environments.Count) { throw 'bootstrap.diagnosticIncomplete' }
    foreach ($environment in $environments) {
        $job = @($Jobs.jobs | Where-Object name -CEQ "diagnostic-$environment")
        if ($job.Count -ne 1 -or $job[0].conclusion -cne 'success' -or $job[0].status -cne 'completed') { throw 'bootstrap.diagnosticJobFailed' }
        foreach ($step in @('Validate trusted definition', 'Authenticate with environment identity', 'Verify federation and isolation')) {
            $steps = @($job[0].steps | Where-Object name -CEQ $step)
            if ($steps.Count -ne 1 -or $steps[0].conclusion -cne 'success') { throw 'bootstrap.diagnosticStepFailed' }
        }
    }
}

function Test-BootstrapPlatform {
    param([hashtable] $Parsed, [hashtable] $Observation, [string] $Workspace, [long] $DiagnosticRunId = 0)
    $definition = $Parsed.definition
    foreach ($stage in @('State', 'Access')) {
        $directory = Join-Path $Workspace $stage.ToLowerInvariant()
        if (-not (Test-Path -LiteralPath (Join-Path $directory 'remote.json'))) { throw 'bootstrap.stateNotRemote' }
        $source = Join-Path $script:bootstrapRoot $(if ($stage -ceq 'State') { 'terraform/bootstrap/azure' } else { 'terraform/bootstrap/azure-access' })
        $trusted = @{}
        foreach ($file in Get-ChildItem -LiteralPath $source -File -Force | Where-Object { $_.Extension -eq '.tf' -or $_.Name -eq '.terraform.lock.hcl' }) {
            $trusted[$file.Name] = $true
            if ((Get-ExecutionHash $file.FullName) -cne (Get-ExecutionHash (Join-Path $directory $file.Name))) { throw 'bootstrap.configurationDrift' }
        }
        foreach ($file in Get-ChildItem -LiteralPath $directory -File -Force | Where-Object { $_.Name -match '\.tf(?:\.json)?$|\.auto\.tfvars(?:\.json)?$' }) {
            if (-not $trusted.ContainsKey($file.Name)) { throw 'bootstrap.configurationDrift' }
        }
        Write-BootstrapFile (Join-Path $directory 'inputs.tfvars.json') (Get-BootstrapTerraformVariables $definition $Observation $stage)
        Initialize-BootstrapTerraform -Directory $directory -Definition $definition -Stage $stage
        # Exit 2 (drift), canceled and failed commands all block verification.
        Invoke-BootstrapNative terraform @("-chdir=$directory", 'plan', '-input=false', '-lock-timeout=60s', '-no-color', '-detailed-exitcode', '-var-file=inputs.tfvars.json') | Out-Null
    }
    $outputs = (Invoke-BootstrapNative terraform @("-chdir=$(Join-Path $Workspace 'access')", 'output', '-json')) | ConvertFrom-Json -AsHashtable
    $bindings = $outputs.environments.value
    $containerScope = "/subscriptions/$($definition.azure.subscriptionId)/resourceGroups/$($definition.state.resourceGroup)/providers/Microsoft.Storage/storageAccounts/$($definition.state.storageAccount)/blobServices/default/containers"
    $containers = Get-BootstrapContainers $definition
    $principals = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($environment in @(Get-BootstrapEnvironments $definition)) {
        $identity = Invoke-BootstrapAzure @('identity', 'show', '--resource-group', $definition.state.resourceGroup, '--name', $definition.environments[$environment].identityName) $definition
        if ($identity.tenantId -ine $definition.azure.tenantId -or $identity.clientId -ine $bindings[$environment].client_id -or
            $identity.principalId -ine $bindings[$environment].principal_id -or -not $principals.Add($identity.principalId)) { throw 'bootstrap.identityDrift' }
        $credentials = @(Invoke-BootstrapAzure @('identity', 'federated-credential', 'list', '--resource-group', $definition.state.resourceGroup, '--identity-name', $identity.name) $definition)
        Assert-BootstrapFederation $credentials "$($Observation.oidcPrefix):environment:$environment"
        $roles = @(Invoke-BootstrapAzure @('role', 'assignment', 'list', '--assignee-object-id', $identity.principalId, '--all', '--include-inherited', '--fill-principal-name', 'false', '--fill-role-definition-name', 'false') $definition)
        Assert-BootstrapRoles $roles $definition.environments[$environment].resourceGroups "$containerScope/$($containers[$environment])" $definition.azure.subscriptionId $outputs.delegation_condition.value
    }
    $desired = Get-BootstrapGithubDesired $definition $bindings
    Assert-BootstrapGithub (Get-BootstrapGithubSnapshot $definition $Observation) $desired
    $checks = @(@{ code = 'bootstrap.configurationAndFederation'; status = 'Pass' })
    if ($DiagnosticRunId -eq 0) { $checks += @{ code = 'bootstrap.liveDiagnosticRequired'; status = 'Pending' }; return $checks }
    $repo = "repos/$($definition.automation.repository)"
    $run = Invoke-BootstrapApi GET "$repo/actions/runs/$DiagnosticRunId"
    $workflow = Invoke-BootstrapApi GET "$repo/actions/workflows/platform-diagnostic.yml"
    $jobs = Invoke-BootstrapApi GET "$repo/actions/runs/$DiagnosticRunId/jobs?per_page=100"
    $commit = & git -C $script:bootstrapRoot rev-parse HEAD
    if ($LASTEXITCODE -ne 0) { throw 'bootstrap.gitUnavailable' }
    & git -C $script:bootstrapRoot diff --quiet HEAD -- scripts terraform/bootstrap .github/workflows/platform-diagnostic.yml contracts/schemas
    if ($LASTEXITCODE -ne 0) { throw 'bootstrap.diagnosticSourceChanged' }
    Assert-BootstrapDiagnostic $run $jobs $Parsed $commit $workflow.id
    $checks += @{ code = 'bootstrap.liveDiagnostic'; status = 'Pass' }
    return $checks
}

Export-ModuleMember -Function New-BootstrapReview, Invoke-BootstrapApply, Move-BootstrapState, Get-BootstrapSourceHash, Get-BootstrapContainers, Get-BootstrapTerraformVariables, Assert-BootstrapReview, Get-BootstrapGithubDesired, Get-BootstrapGithubSnapshot, Assert-BootstrapGithub, Set-BootstrapGithub, Get-BootstrapBindings, Assert-BootstrapFederation, Assert-BootstrapRoles, Assert-BootstrapDiagnostic, Test-BootstrapPlatform
