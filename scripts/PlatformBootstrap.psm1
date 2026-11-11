Set-StrictMode -Version Latest
$script:parserBuilt = $false

function Get-BootstrapHash([string] $Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function ConvertTo-PlatformBootstrapJson {
    param([Parameter(Mandatory)][object] $Value)
    function ConvertTo-CanonicalValue($Item) {
        if ($Item -is [Collections.IDictionary]) {
            $map = [ordered] @{}
            foreach ($key in @($Item.Keys | Sort-Object -CaseSensitive)) { $map[$key] = ConvertTo-CanonicalValue $Item[$key] }
            return $map
        }
        if ($Item -is [Collections.IEnumerable] -and $Item -isnot [string]) {
            return ,@($Item | ForEach-Object { ConvertTo-CanonicalValue $_ })
        }
        return $Item
    }
    return (ConvertTo-CanonicalValue $Value) | ConvertTo-Json -Depth 32
}

function Get-BootstrapEnvironments([hashtable] $Definition) {
    return @(@('dev', 'staging', 'prod') | Where-Object { $Definition.environments.ContainsKey($_) })
}

function Read-PlatformBootstrapDocument {
    param([Parameter(Mandatory)][string] $Path)
    $root = Split-Path -Parent $PSScriptRoot
    $project = Join-Path $root 'operations/Hexagon.Platform.Definition/Hexagon.Platform.Definition.csproj'
    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { throw 'bootstrap.tool.dotnet' }
    if (-not $script:parserBuilt) {
        Push-Location $root
        try {
            $buildOutput = & dotnet build $project -c Release --nologo --verbosity quiet 2>&1
            if ($LASTEXITCODE -ne 0) { throw 'bootstrap.parserUnavailable' }
            $script:parserBuilt = $true
        }
        finally { Pop-Location }
    }
    $reader = Join-Path $root 'operations/Hexagon.Platform.Definition/bin/Release/net10.0/Hexagon.Platform.Definition.dll'
    $output = & dotnet $reader $Path 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'bootstrap.definitionInvalid' }
    try { $parsed = ($output -join "`n") | ConvertFrom-Json -AsHashtable -Depth 32 }
    catch { throw 'bootstrap.definitionInvalid' }
    $schema = Join-Path $root 'contracts/schemas/platform-bootstrap-v1.schema.json'
    if (-not (($parsed.definition | ConvertTo-Json -Depth 32) | Test-Json -SchemaFile $schema -ErrorAction SilentlyContinue)) {
        throw 'bootstrap.definitionInvalid'
    }
    $definition = $parsed.definition
    $product = $definition.product
    if (($definition.automation.repository -split '/')[1] -cne "$product-devops") {
        throw 'bootstrap.productMismatch'
    }
    foreach ($key in @('tenantId', 'subscriptionId')) {
        if ([guid] $definition.azure[$key] -eq [guid]::Empty) { throw 'bootstrap.targetInvalid' }
    }
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $groups = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [void] $groups.Add($definition.state.resourceGroup)
    foreach ($environment in @(Get-BootstrapEnvironments $definition)) {
        $settings = $definition.environments[$environment]
        if (-not $names.Add($settings.identityName)) { throw 'bootstrap.identityShared' }
        $reviewers = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($reviewer in $settings.reviewers) {
            if (-not $reviewers.Add($reviewer)) { throw 'bootstrap.reviewerDuplicate' }
        }
        foreach ($group in $settings.resourceGroups) {
            if (-not $groups.Add($group) -or $group -cnotmatch "^rg-$([regex]::Escape($product))-$environment(?:-[a-z0-9-]+)?$") {
                throw 'bootstrap.resourceGroupShared'
            }
        }
    }
    if ($definition.state.container -match '--' -or $definition.state.container.Length -gt 55) { throw 'bootstrap.definitionInvalid' }
    return $parsed
}

function Read-PlatformBootstrapDefinition {
    param([Parameter(Mandatory)][string] $Path)
    $parsed = Read-PlatformBootstrapDocument $Path
    $root = Split-Path -Parent $PSScriptRoot
    $product = (Get-Content -Raw -LiteralPath (Join-Path $root '.config/product.json') | ConvertFrom-Json).product
    if ($parsed.definition.product -cne $product) { throw 'bootstrap.productMismatch' }
    return $parsed
}

function New-PlatformBootstrapResult {
    param([string] $Mode, [string] $Status, [object] $Parsed, [object[]] $Checks = @(), [object[]] $Operations = @())
    $schema = Join-Path (Split-Path -Parent $PSScriptRoot) 'contracts/schemas/platform-bootstrap-v1.schema.json'
    return [ordered] @{
        apiVersion = 'hexagon.ec/platform-bootstrap-result/v1'
        kind = 'PlatformBootstrapResult'
        mode = $Mode
        status = $Status
        readyToApply = $false
        applyImplemented = $false
        definitionSha256 = $(if ($null -ne $Parsed) { $Parsed.sha256 } else { $null })
        schemaSha256 = Get-BootstrapHash $schema
        product = $(if ($null -ne $Parsed) { $Parsed.definition.product } else { $null })
        repository = $(if ($null -ne $Parsed) { $Parsed.definition.automation.repository } else { $null })
        checks = @($Checks)
        operations = @($Operations)
    }
}

function Invoke-PlatformReadCommand {
    param(
        [ValidateSet('AzureAccount', 'TerraformVersion', 'Repository', 'Environments', 'Actions', 'WorkflowPermissions', 'Oidc', 'GroupExists', 'Group', 'Storage', 'Identities')]
        [string] $Request,
        [hashtable] $Definition,
        [string] $Target = ''
    )
    $repository = $Definition.automation.repository
    $subscription = $Definition.azure.subscriptionId
    $group = $Definition.state.resourceGroup
    $command = 'gh'
    $arguments = switch ($Request) {
        'AzureAccount' { $command = 'az'; @('account', 'show', '--output', 'json', '--only-show-errors') }
        'TerraformVersion' { $command = 'terraform'; @('version', '-json') }
        'Repository' { @('api', '--method', 'GET', "repos/$repository") }
        'Environments' { @('api', '--method', 'GET', "repos/$repository/environments?per_page=100") }
        'Actions' { @('api', '--method', 'GET', "repos/$repository/actions/permissions") }
        'WorkflowPermissions' { @('api', '--method', 'GET', "repos/$repository/actions/permissions/workflow") }
        'Oidc' { @('api', '--method', 'GET', "repos/$repository/actions/oidc/customization/sub") }
        'GroupExists' { $command = 'az'; @('group', 'exists', '--name', $Target, '--subscription', $subscription, '--output', 'json', '--only-show-errors') }
        'Group' { $command = 'az'; @('group', 'show', '--name', $group, '--subscription', $subscription, '--output', 'json', '--only-show-errors') }
        'Storage' { $command = 'az'; @('storage', 'account', 'list', '--resource-group', $group, '--subscription', $subscription, '--output', 'json', '--only-show-errors') }
        'Identities' { $command = 'az'; @('identity', 'list', '--resource-group', $group, '--subscription', $subscription, '--output', 'json', '--only-show-errors') }
    }
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "bootstrap.tool.$command" }
    $PSNativeCommandUseErrorActionPreference = $false
    try { $output = & $command @arguments 2>&1 }
    catch { throw "bootstrap.read.$Request" }
    if ($LASTEXITCODE -ne 0) { throw "bootstrap.read.$Request" }
    try { return ($output -join "`n") | ConvertFrom-Json -AsHashtable -Depth 32 }
    catch { throw "bootstrap.read.$Request" }
}

function Get-PlatformBootstrapObservation {
    param(
        [Parameter(Mandatory)][hashtable] $Definition,
        [scriptblock] $Read = { param($request, $definition, $target) Invoke-PlatformReadCommand -Request $request -Definition $definition -Target $target }
    )
    # This boundary is checked before any other platform lookup, including a missing bootstrap group.
    $account = & $Read 'AzureAccount' $Definition ''
    if ($account.tenantId -ine $Definition.azure.tenantId -or $account.id -ine $Definition.azure.subscriptionId) {
        throw 'bootstrap.targetMismatch'
    }
    $terraform = & $Read 'TerraformVersion' $Definition ''
    if (-not $terraform.ContainsKey('terraform_version') -or
        [version] $terraform.terraform_version -lt [version] '1.10.0' -or [version] $terraform.terraform_version -ge [version] '2.0.0') {
        throw 'bootstrap.terraformVersion'
    }
    $repository = & $Read 'Repository' $Definition ''
    if ($repository.full_name -ine $Definition.automation.repository -or $repository.default_branch -cne 'main' -or
        $repository.archived -ne $false -or $repository.disabled -ne $false -or -not $repository.permissions.admin) {
        throw 'bootstrap.repositoryBoundary'
    }
    $environments = & $Read 'Environments' $Definition ''
    if (-not $environments.ContainsKey('total_count') -or -not $environments.ContainsKey('environments') -or
        $environments.total_count -ne @($environments.environments).Count) {
        throw 'bootstrap.environmentsIncomplete'
    }
    $actions = & $Read 'Actions' $Definition ''
    $permissions = & $Read 'WorkflowPermissions' $Definition ''
    if ($actions.enabled -isnot [bool] -or $permissions.can_approve_pull_request_reviews -isnot [bool] -or
        $permissions.default_workflow_permissions -cnotin @('read', 'write')) {
        throw 'bootstrap.permissionsIncomplete'
    }
    $oidc = & $Read 'Oidc' $Definition ''
    $prefix = [string] $oidc.sub_claim_prefix
    $parts = $repository.full_name -split '/'
    $legacyPrefix = "repo:$($repository.full_name)"
    $immutablePrefix = "repo:$($parts[0])@$($repository.owner.id)/$($parts[1])@$($repository.id)"
    if ($oidc.use_default -ne $true -or $prefix -cnotin @($legacyPrefix, $immutablePrefix)) {
        throw 'bootstrap.oidcTemplateUnsupported'
    }
    $stateGroupExists = & $Read 'GroupExists' $Definition $Definition.state.resourceGroup
    if ($stateGroupExists -isnot [bool]) { throw 'bootstrap.read.GroupExists' }
    $stateGroup = $null; $storage = @(); $identities = @()
    if ($stateGroupExists) {
        $stateGroup = & $Read 'Group' $Definition ''
        if ($stateGroup.name -ine $Definition.state.resourceGroup -or $null -eq $stateGroup.tags -or
            $stateGroup.tags.product -cne $Definition.product -or $stateGroup.tags.'managed-by' -cne 'terraform') {
            throw 'bootstrap.ownershipUnverified'
        }
        $storage = @(& $Read 'Storage' $Definition '')
        $identities = @(& $Read 'Identities' $Definition '')
    }
    return @{
        repository = $repository; environments = @($environments.environments)
        actions = $actions; workflowPermissions = $permissions; oidcPrefix = $prefix
        stateGroupExists = $stateGroupExists; storage = $storage; identities = $identities
    }
}

function New-PlatformBootstrapPlan {
    param([Parameter(Mandatory)][hashtable] $Parsed, [hashtable] $Observation)
    $definition = $Parsed.definition
    $checks = [Collections.Generic.List[object]]::new()
    $checks.Add(@{ code = 'bootstrap.definitionValid'; status = 'Pass' })
    $operations = [Collections.Generic.List[object]]::new()
    $online = $null -ne $Observation
    $checks.Add(@{ code = $(if ($online) { 'bootstrap.readOnlyPreflight' } else { 'bootstrap.offline' }); status = $(if ($online) { 'Pass' } else { 'Pending' }) })
    $state = 'Unknown'; $action = 'Inspect'
    if ($online) {
        $state = $(if ($Observation.stateGroupExists) { 'Present' } else { 'Absent' })
        $action = $(if ($Observation.stateGroupExists) { 'Inspect' } else { 'Create' })
        if ($Observation.stateGroupExists) {
            $accounts = @($Observation.storage | Where-Object { $_.name -ieq $definition.state.storageAccount })
            if ($accounts.Count -gt 1) { throw 'bootstrap.storageAmbiguous' }
            if ($accounts.Count -eq 0) { $state = 'Drift'; $action = 'Reconcile' }
        }
    }
    $operations.Add(@{
        id = 'azure.state'; executor = 'Terraform'; action = $action; state = $state; dependsOn = @()
        target = "terraform/bootstrap/azure:$($definition.state.resourceGroup)"
        desired = @{
            resourceGroup = $definition.state.resourceGroup; storageAccount = $definition.state.storageAccount
            container = $definition.state.container; location = $definition.azure.location
            sharedKeys = $false; versioning = $true; recoveryDays = 30; deleteLock = $true
            bootstrapKey = "$($definition.product)/bootstrap/state.tfstate"
        }
    })
    $operations.Add(@{
        id = 'github.actions'; executor = 'GitHubApi'; action = 'Inspect'; state = 'Unknown'; dependsOn = @()
        target = $definition.automation.repository
        desired = @{ enabled = $true; defaultWorkflowPermissions = 'read'; canApprovePullRequestReviews = $false }
    })
    if ($online) {
        $operation = $operations[1]
        if ($Observation.actions.enabled -eq $true -and $Observation.workflowPermissions.default_workflow_permissions -ceq 'read' -and
            $Observation.workflowPermissions.can_approve_pull_request_reviews -eq $false) {
            $operation.state = 'Present'; $operation.action = 'None'
        }
        else { $operation.state = 'Drift'; $operation.action = 'Reconcile' }
    }
    foreach ($environment in @(Get-BootstrapEnvironments $definition)) {
        $settings = $definition.environments[$environment]
        $identityState = 'Unknown'; $identityAction = 'Inspect'
        $subject = $null
        if ($online) {
            $matches = @($Observation.identities | Where-Object { $_.name -ieq $settings.identityName })
            if ($matches.Count -gt 1) { throw 'bootstrap.identityAmbiguous' }
            $identityState = $(if ($matches.Count -eq 1) { 'Present' } else { 'Absent' })
            # Existing identities still require federation and RBAC inspection in the execution block.
            $identityAction = $(if ($matches.Count -eq 1) { 'Inspect' } else { 'Create' })
            $subject = "$($Observation.oidcPrefix):environment:$environment"
        }
        $operations.Add(@{
            id = "azure.identity.$environment"; executor = 'Terraform'; action = $identityAction; state = $identityState
            dependsOn = @('azure.state'); target = "$($definition.state.resourceGroup)/$($settings.identityName)"
            desired = @{
                environment = $environment; issuer = 'https://token.actions.githubusercontent.com'; subject = $subject
                audience = 'api://AzureADTokenExchange'; resourceGroups = @($settings.resourceGroups)
                stateKeyPrefix = "$($definition.product)/$environment/"
                stateContainer = "$($definition.state.container)-$environment"
            }
        })
        $envState = 'Unknown'; $envAction = 'Inspect'
        if ($online) {
            $matches = @($Observation.environments | Where-Object { $_.name -ieq $environment })
            if ($matches.Count -gt 1) { throw 'bootstrap.environmentAmbiguous' }
            $envState = $(if ($matches.Count -eq 1) { 'Present' } else { 'Absent' })
            $envAction = $(if ($matches.Count -eq 1) { 'Inspect' } else { 'Create' })
            if ($environment -ceq 'prod' -and $Observation.repository.private) {
                $rules = @()
                if ($matches.Count -eq 1) { $rules = @($matches[0].protection_rules | Where-Object { $_.type -ceq 'required_reviewers' }) }
                $checks.Add(@{ code = 'bootstrap.productionProtectionCapability'; status = $(if ($rules.Count -eq 1) { 'Pass' } else { 'Pending' }) })
            }
        }
        $operations.Add(@{
            id = "github.environment.$environment"; executor = 'GitHubApi'; action = $envAction; state = $envState
            dependsOn = @('github.actions'); target = "$($definition.automation.repository):$environment"
            desired = @{ branch = 'main'; reviewers = @($settings.reviewers); preventSelfReview = $true }
        })
        $operations.Add(@{
            id = "github.variables.$environment"; executor = 'GitHubApi'; action = 'Inspect'; state = 'Unknown'
            dependsOn = @("github.environment.$environment", "azure.identity.$environment")
            target = "$($definition.automation.repository):$environment"
            desired = @{ names = @('AZURE_CLIENT_ID', 'AZURE_TENANT_ID', 'AZURE_SUBSCRIPTION_ID'); valuesFrom = 'terraform-outputs' }
        })
    }
    $operations.Add(@{
        id = 'workflow.diagnostic'; executor = 'Workflow'; action = 'Inspect'; state = 'Unknown'
        dependsOn = @(Get-BootstrapEnvironments $definition | ForEach-Object { "github.variables.$_" })
        target = $definition.automation.repository
        desired = @{ implementation = 'pending'; cloudWrites = $false; expectedConclusion = 'success' }
    })
    $status = $(if (@($checks | Where-Object status -CEQ 'Pending').Count -gt 0) { 'Unverified' } else { 'Planned' })
    return New-PlatformBootstrapResult -Mode Plan -Status $status -Parsed $Parsed -Checks @($checks) -Operations @($operations)
}

Export-ModuleMember -Function Read-PlatformBootstrapDefinition, Read-PlatformBootstrapDocument, New-PlatformBootstrapResult, Get-PlatformBootstrapObservation, New-PlatformBootstrapPlan, ConvertTo-PlatformBootstrapJson, Get-BootstrapEnvironments
