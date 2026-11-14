Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'EnvironmentLifecycle.psm1')
Import-Module (Join-Path $PSScriptRoot 'EnvironmentSnapshot.psm1')
Import-Module (Join-Path $PSScriptRoot 'AwsEnvironmentStore.psm1')
Import-Module (Join-Path $PSScriptRoot 'AwsLifecycleResources.psm1')
Import-Module (Join-Path $PSScriptRoot 'LifecycleNative.psm1')
Import-Module (Join-Path $PSScriptRoot 'PlatformBootstrap.psm1')

# The Terraform/AWS adapter of the lifecycle engine (ADR 0025), equivalent to TerraformAzureLifecycle:
# plans and applies the hosting-aws and aws roots of a reservation, proves presence with Cloud Control
# and dedicated probes, and proves a complete destruction with the instance tag. $Context.awsCli may be
# a test double with the contract (arguments) -> { exitCode; text; errorText }.

function Invoke-AwsLifecycleCli([hashtable] $Context, [string[]] $Arguments) {
    $full = $Arguments + @('--region', $Context.inventory.target.region, '--output', 'json')
    if ($Context.ContainsKey('awsCli') -and $null -ne $Context.awsCli) { return & $Context.awsCli $full }
    return Invoke-LifecycleCommand aws $full -TimeoutSeconds 120
}

function Assert-AwsLifecycleRuntime([hashtable] $Context) {
    $repository = $Context.inventory.iac.repository
    if ($env:GITHUB_ACTIONS -cne 'true' -or $env:GITHUB_EVENT_NAME -cne 'workflow_dispatch' -or $env:GITHUB_REF -cne 'refs/heads/main' -or
        $env:GITHUB_REPOSITORY -ine $repository -or
        $env:GITHUB_WORKFLOW_REF -cnotin @('genesis', 'apocalypse', 'delivery' | ForEach-Object { "$repository/.github/workflows/$_.yml@refs/heads/main" })) { throw 'lifecycle.aws.trustedWorkflowRequired' }
}

# Inputs of a root must stay inside the reservation: its account, region, instance and short prefix.
# Physical names come from the product policies, so they are checked here before any plan.
function Assert-AwsLifecycleInputs([hashtable] $Inventory, [hashtable] $Root, [hashtable] $Inputs) {
    $prefix = $Root.namePrefix
    $ephemeral = $Inventory.instance.kind -ceq 'Ephemeral'
    $named = { param($value) $value -is [string] -and $value.StartsWith("$prefix-", [StringComparison]::Ordinal) }
    $instance = $(if ($Inputs.ContainsKey('instance_id')) { $Inputs.instance_id } else { 'persistent' })
    if ($Inputs.product -cne $Inventory.product -or $Inputs.environment -cne $Inventory.environment -or $instance -cne $Inventory.instance.id -or
        $Inputs.region -cne $Inventory.target.region) { throw 'lifecycle.aws.inputsOutsideScope' }
    if ($Root.id -ceq 'hosting') {
        if ($Inputs.name_prefix -cne $prefix -or $Inputs.account_id -cne $Inventory.target.accountId -or
            ($ephemeral -and -not ($Inputs.ContainsKey('workload_boundary_arn') -and $Inputs.workload_boundary_arn)) -or
            @($Inputs.workloads.Values | Where-Object { -not (& $named $_.name) }).Count -gt 0) { throw 'lifecycle.aws.inputsOutsideScope' }
        return
    }
    $names = @($Inputs.kms_alias_name) + @($Inputs.destinations.Values | ForEach-Object { $_.name; @($_.publishers.Values) }) +
        @($Inputs.consumers.Values | ForEach-Object { $_.name; $_.role_name; if ($_.ContainsKey('redrive') -and $null -ne $_.redrive -and $_.redrive.ContainsKey('dead_letter_queue_name') -and $_.redrive.dead_letter_queue_name) { $_.redrive.dead_letter_queue_name } })
    if (($ephemeral -and $Inputs.name_prefix -cne $prefix) -or @($names | Where-Object { -not (& $named $_) }).Count -gt 0) { throw 'lifecycle.aws.inputsOutsideScope' }
}

function Assert-AwsLifecycleWorkspace([hashtable] $Context) {
    foreach ($link in @(Get-ChildItem -LiteralPath $Context.directory -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })) {
        $relative = [IO.Path]::GetRelativePath($Context.directory, $link.FullName).Replace('\', '/')
        if ($relative -cnotmatch '^terraform/environments/(dev|staging|prod)/(aws|hosting-aws)/[.]terraform/providers/registry[.]terraform[.]io/hashicorp/aws/[0-9.]+/(linux|windows|darwin)_(amd64|arm64)$') { throw 'lifecycle.aws.workspaceLink' }
    }
    foreach ($name in $Context.snapshot.manifest.files.Keys) {
        if ((Get-LifecycleFileHash (Join-Path $Context.directory $name)) -cne $Context.snapshot.manifest.files[$name]) { throw 'lifecycle.aws.workspaceChanged' }
    }
    $candidates = @(Get-ChildItem -LiteralPath (Join-Path $Context.directory 'terraform') -Recurse -File -Force | Where-Object { $_.FullName -notmatch '[/\\][.]terraform[/\\]' -and ($_.Name -match '[.]tf(?:[.]json)?$|[.]tfvars(?:[.]json)?$|[.]terraform[.]lock[.]hcl$') })
    foreach ($file in $candidates) {
        $relative = [IO.Path]::GetRelativePath($Context.directory, $file.FullName).Replace('\', '/')
        if (-not $Context.snapshot.manifest.files.ContainsKey($relative) -or $file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'lifecycle.aws.workspaceChanged' }
    }
    $version = Invoke-LifecycleCommand terraform @('version', '-json') -TimeoutSeconds 30
    if ($version.exitCode -ne 0 -or ($version.text | ConvertFrom-Json).terraform_version -cne $Context.snapshot.manifest.terraformVersion) { throw 'lifecycle.aws.toolchainMismatch' }
}

function Get-AwsLifecycleRootInputs([hashtable] $Context, [hashtable] $Root) {
    $path = Join-Path $Context.directory $Context.snapshot.manifest.roots[$Root.id].inputs
    $inputs = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -AsHashtable -Depth 32
    Assert-AwsLifecycleInputs $Context.inventory $Root $inputs
    return $path
}

function Invoke-AwsLifecycleTerraform {
    param([hashtable] $Context, [hashtable] $Root, [string[]] $Arguments)
    Assert-LifecycleCliEnvironment
    Assert-AwsLifecycleLease $Context -Confirm:$false
    Assert-AwsLifecycleWorkspace $Context
    $directory = Join-Path $Context.directory $Context.snapshot.manifest.roots[$Root.id].directory
    $cliConfig = Join-Path $Context.runtime 'terraform.rc'
    [IO.File]::WriteAllText($cliConfig, "disable_checkpoint = true`nprovider_installation {`n  direct {}`n}`n")
    $child = @{ AWS_REGION = $Context.inventory.target.region; TF_IN_AUTOMATION = 'true'; TF_CLI_CONFIG_FILE = $cliConfig }
    $renew = (Get-Command Assert-AwsLifecycleLease).ScriptBlock
    $heartbeat = { & $renew $Context -Confirm:$false }.GetNewClosure()
    return Invoke-LifecycleCommand terraform (@("-chdir=$directory") + $Arguments) -Environment $child -Heartbeat $heartbeat
}

function Initialize-AwsLifecycleTerraform([hashtable] $Context, [hashtable] $Root) {
    $target = $Context.inventory.target
    # The bootstrap bucket policy only accepts SSE-KMS with its own key.
    $backend = @{ bucket = $target.stateBucket; key = $Root.stateKey; region = $target.region; encrypt = $true; kms_key_id = $target.stateKmsKeyArn; use_lockfile = $true }
    $path = Join-Path $Context.runtime "$($Root.id)-backend.json"
    [IO.File]::WriteAllText($path, (ConvertTo-PlatformBootstrapJson $backend))
    $result = Invoke-AwsLifecycleTerraform $Context $Root @('init', '-input=false', '-reconfigure', '-lockfile=readonly', '-no-color', "-backend-config=$path")
    if ($result.exitCode -ne 0) { throw 'lifecycle.aws.terraformInitFailed' }
}

function New-AwsLifecyclePlan {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([hashtable] $Context, [hashtable] $Root, [ValidateSet('Create', 'Destroy')][string] $Operation)
    if (-not $PSCmdlet.ShouldProcess($Root.id, "Prepare $Operation Terraform plan")) { return }
    $inputs = Get-AwsLifecycleRootInputs $Context $Root
    Initialize-AwsLifecycleTerraform $Context $Root
    $binary = Join-Path $Context.runtime "$($Root.id).tfplan"
    $arguments = @('plan', '-input=false', '-lock-timeout=60s', '-no-color', "-var-file=$inputs", "-out=$binary")
    if ($Operation -ceq 'Destroy') { $arguments += '-destroy' }
    if ((Invoke-AwsLifecycleTerraform $Context $Root $arguments).exitCode -ne 0) { throw 'lifecycle.aws.terraformPlanFailed' }
    $show = Invoke-AwsLifecycleTerraform $Context $Root @('show', '-json', $binary)
    if ($show.exitCode -ne 0) { throw 'lifecycle.aws.terraformShowFailed' }
    [IO.File]::WriteAllBytes("$binary.json", $show.bytes)
    return @{ binaryPath = $binary; jsonPath = "$binary.json" }
}

function Get-AwsLifecycleState([hashtable] $Context, [hashtable] $Root) {
    $name = $Root.stateKey.Substring($Context.prefix.Length + 1)
    $response = Get-AwsLifecycleStoredObject $Context $name
    if ($response.status -eq 404) { return @{ stateStatus = 'Absent'; lineage = $null; serial = 0; resources = @(); etag = $null; outputs = @{} } }
    $state = Read-AwsLifecycleTerraformState $Context.inventory $response.bytes
    return @{ stateStatus = 'Present'; lineage = $state.lineage; serial = $state.serial; resources = $state.resources; etag = $response.etag; outputs = $state.outputs }
}

# Every page of tag:GetResources for the instance tag; pagination is bounded and must end.
function Get-AwsLifecycleTaggedPages([hashtable] $Context) {
    $pages = [Collections.Generic.List[object]]::new(); $token = ''; $seen = [Collections.Generic.HashSet[string]]::new()
    do {
        $arguments = @('resourcegroupstaggingapi', 'get-resources', '--tag-filters', "Key=hexagon:instance,Values=$($Context.inventory.instance.id)")
        if ($token) { $arguments += @('--pagination-token', $token) }
        $response = Invoke-AwsLifecycleCli $Context $arguments
        if ($response.exitCode -ne 0) { throw 'lifecycle.aws.scopeUnavailable' }
        $page = $response.text | ConvertFrom-Json -AsHashtable -Depth 32
        $pages.Add($page)
        $token = $(if ($page.ContainsKey('PaginationToken')) { [string] $page.PaginationToken } else { '' })
        if ($token -and (-not $seen.Add($token) -or $pages.Count -gt 100)) { throw 'lifecycle.aws.paginationInvalid' }
    } while ($token)
    return , $pages.ToArray()
}

function Get-AwsLifecycleObservationOnce([hashtable] $Context, [hashtable] $Root, [string] $Operation) {
    $state = Get-AwsLifecycleState $Context $Root
    $all = @{}; foreach ($resource in @($Root.resources) + @($state.resources)) { $all[$resource.id] = $resource }
    $cli = (Get-Command Invoke-AwsLifecycleCli).ScriptBlock
    $aws = { param($arguments) & $cli $Context $arguments }.GetNewClosure()
    $probes = @(foreach ($id in $all.Keys) { @{ id = $id; status = Test-AwsLifecycleResource $Context.inventory $id $aws } })
    $converged = $false
    if ($Operation -ceq 'Create') {
        $inputs = Get-AwsLifecycleRootInputs $Context $Root
        Initialize-AwsLifecycleTerraform $Context $Root
        $plan = Invoke-AwsLifecycleTerraform $Context $Root @('plan', '-input=false', '-lock-timeout=60s', '-no-color', '-detailed-exitcode', "-var-file=$inputs")
        if ($plan.exitCode -notin @(0, 2)) { throw 'lifecycle.aws.convergenceUnavailable' }
        $converged = $plan.exitCode -eq 0
    }
    # The tag scope covers both roots: messaging is destroyed first and hosting last, so only the last
    # root to be destroyed can prove that nothing of the instance remains.
    $remaining = @()
    if ($Operation -ceq 'Destroy' -and @($Context.inventory.roots | Where-Object { $_.id -cne $Root.id -and $_.status -cne 'Destroyed' }).Count -eq 0) {
        $remaining = @(Get-AwsLifecycleRemaining $Context.inventory (Get-AwsLifecycleTaggedPages $Context))
    }
    $check = Get-AwsLifecycleState $Context $Root
    if ($check.etag -cne $state.etag) { throw 'lifecycle.aws.stateChangedDuringObservation' }
    return @{ stateStatus = $state.stateStatus; lineage = $state.lineage; serial = $state.serial; resources = @($state.resources)
        scopeAccessible = $true; scopeComplete = $true; configurationConverged = $converged; probes = $probes; remainingResourceIds = $remaining }
}

# Deleted AWS resources fade out of Cloud Control and the Tagging API eventually, so a destruction is
# observed for up to five minutes before it may be reported incomplete.
function Get-AwsLifecycleObservation([hashtable] $Context, [hashtable] $Root, [string] $Operation, [int] $TimeoutSeconds = 300, [int] $DelaySeconds = 10) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        $observation = Get-AwsLifecycleObservationOnce $Context $Root $Operation
        if ($Operation -cne 'Destroy' -or $observation.resources.Count -gt 0 -or
            ($observation.remainingResourceIds.Count -eq 0 -and @($observation.probes | Where-Object status -CNE 'Missing').Count -eq 0) -or
            $timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) { return $observation }
        Assert-AwsLifecycleLease $Context -Confirm:$false
        Start-Sleep -Seconds $DelaySeconds
    } while ($true)
}

# Before a destruction: nothing of the instance runs (services at zero and no running task), so no
# workload writes to the database or consumes messages while Terraform removes them. Quiesce (a later
# increment) brings the services to zero; this check never changes anything.
function Get-AwsLifecycleDestructionSafety([hashtable] $Context, [object] $Request) {
    if ($Context.inventory.dataPolicy -cne 'DeleteEphemeral') { throw 'lifecycle.aws.backupVerifierRequired' }
    $cluster = $Context.inventory.roots[0].namePrefix
    $facts = [Collections.Generic.List[string]]::new()
    $services = Invoke-AwsLifecycleCli $Context @('ecs', 'list-services', '--cluster', $cluster)
    if ($services.exitCode -ne 0) {
        if ($services.errorText -notmatch 'ClusterNotFoundException') { throw 'lifecycle.aws.quiescenceUnavailable' }
    }
    else {
        $arns = @(($services.text | ConvertFrom-Json -AsHashtable).serviceArns)
        if ($arns.Count -gt 0) {
            $described = Invoke-AwsLifecycleCli $Context (@('ecs', 'describe-services', '--cluster', $cluster, '--services') + $arns)
            if ($described.exitCode -ne 0) { throw 'lifecycle.aws.quiescenceUnavailable' }
            foreach ($service in @(($described.text | ConvertFrom-Json -AsHashtable).services)) {
                if ($service.status -ceq 'ACTIVE' -and ($service.desiredCount -ne 0 -or $service.runningCount -ne 0)) { throw 'lifecycle.aws.applicationNotQuiesced' }
                $facts.Add([string] $service.serviceArn)
            }
        }
        $tasks = Invoke-AwsLifecycleCli $Context @('ecs', 'list-tasks', '--cluster', $cluster, '--desired-status', 'RUNNING')
        if ($tasks.exitCode -ne 0) { throw 'lifecycle.aws.quiescenceUnavailable' }
        if (@(($tasks.text | ConvertFrom-Json -AsHashtable).taskArns).Count -gt 0) { throw 'lifecycle.aws.jobNotQuiesced' }
    }
    $evidence = @{ product = $Request.product; environment = $Request.environment; instanceId = $Request.instanceId; rootId = $Request.root.id; observedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); resources = @($facts) }
    $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-PlatformBootstrapJson $evidence)); $hash = Get-AwsLifecycleBytesHash $bytes
    Publish-AwsLifecycleObject $Context "evidence/$hash.json" $bytes $hash -Confirm:$false
    return @{ quiesced = $true; backupVerified = $false; evidenceSha256 = $hash; product = $Request.product; environment = $Request.environment; instanceId = $Request.instanceId; rootId = $Request.root.id }
}

# Quiesce before Apocalypse: every ECS service of the instance goes to zero and running tasks stop.
# It waits, bounded, until nothing runs; DestructionSafety then proves it before any destroy plan.
function Invoke-AwsLifecycleQuiesce {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([hashtable] $Context, [int] $TimeoutSeconds = 600, [int] $DelaySeconds = 10)
    if (-not $PSCmdlet.ShouldProcess($Context.prefix, 'Quiesce the ECS services and tasks of the instance')) { return }
    Assert-AwsLifecycleLease $Context -Confirm:$false
    $cluster = $Context.inventory.roots[0].namePrefix
    $listed = Invoke-AwsLifecycleCli $Context @('ecs', 'list-services', '--cluster', $cluster)
    if ($listed.exitCode -ne 0) {
        if ($listed.errorText -match 'ClusterNotFoundException') { return @{ quiesced = $true; services = 0 } }
        throw 'lifecycle.aws.quiescenceUnavailable'
    }
    $services = @(($listed.text | ConvertFrom-Json -AsHashtable).serviceArns)
    foreach ($service in $services) {
        $update = Invoke-AwsLifecycleCli $Context @('ecs', 'update-service', '--cluster', $cluster, '--service', $service, '--desired-count', '0')
        if ($update.exitCode -ne 0) { throw 'lifecycle.aws.quiescenceUnavailable' }
    }
    $running = Invoke-AwsLifecycleCli $Context @('ecs', 'list-tasks', '--cluster', $cluster, '--desired-status', 'RUNNING')
    if ($running.exitCode -ne 0) { throw 'lifecycle.aws.quiescenceUnavailable' }
    foreach ($task in @(($running.text | ConvertFrom-Json -AsHashtable).taskArns)) {
        $stop = Invoke-AwsLifecycleCli $Context @('ecs', 'stop-task', '--cluster', $cluster, '--task', $task, '--reason', 'hexagon-quiesce')
        if ($stop.exitCode -ne 0) { throw 'lifecycle.aws.quiescenceUnavailable' }
    }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        try {
            Get-AwsLifecycleDestructionSafety $Context @{ product = $Context.inventory.product; environment = $Context.inventory.environment; instanceId = $Context.inventory.instance.id; root = $Context.inventory.roots[0] } | Out-Null
            return @{ quiesced = $true; services = $services.Count }
        }
        catch {
            if ($_.Exception.Message -cnotin @('lifecycle.aws.applicationNotQuiesced', 'lifecycle.aws.jobNotQuiesced') -or $timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw }
        }
        Assert-AwsLifecycleLease $Context -Confirm:$false
        Start-Sleep -Seconds $DelaySeconds
    } while ($true)
}

# In AWS the messaging roles are the task roles that hosting created, with deterministic names: there is
# no provisional identity to rewrite, so binding only proves that messaging names roles of this hosting.
function Assert-AwsMessagingBindings([hashtable] $Context, [hashtable] $Inputs) {
    $hosting = @($Context.inventory.roots | Where-Object { $_.id -ceq 'hosting' -and $_.status -ceq 'Verified' })
    if ($hosting.Count -ne 1) { throw 'lifecycle.aws.hostingNotVerified' }
    $state = Get-AwsLifecycleState $Context $hosting[0]
    if ($state.stateStatus -cne 'Present' -or $state.lineage -cne $hosting[0].stateLineage -or $state.serial -ne $hosting[0].stateSerial -or -not $state.outputs.ContainsKey('workload_roles')) { throw 'lifecycle.aws.hostingStateChanged' }
    $roles = @($state.outputs.workload_roles.value.Values | ForEach-Object { $_.name })
    $used = @($Inputs.destinations.Values | ForEach-Object { @($_.publishers.Values) }) + @($Inputs.consumers.Values | ForEach-Object { $_.role_name })
    if (@($used | Where-Object { $_ -cnotin $roles }).Count -gt 0) { throw 'lifecycle.aws.messagingRoleUnbound' }
}

function Invoke-AwsLifecyclePortAction([hashtable] $Context, [hashtable] $Request) {
    $root = $Request.root
    switch ($Request.action) {
        'Preflight' {
            Assert-AwsLifecycleLease $Context -Confirm:$false
            Assert-AwsLifecycleWorkspace $Context
            Get-AwsLifecycleRootInputs $Context $root | Out-Null
            $caller = Invoke-AwsLifecycleCli $Context @('sts', 'get-caller-identity')
            if ($caller.exitCode -ne 0) { throw 'lifecycle.aws.accountUnavailable' }
            $identity = $caller.text | ConvertFrom-Json -AsHashtable
            Assert-AwsLifecycleCaller $Context.inventory $identity.Arn $identity.Account
            $valid = $false
            if ($Request.ContainsKey('binaryPath')) {
                Initialize-AwsLifecycleTerraform $Context $root
                $shown = Invoke-AwsLifecycleTerraform $Context $root @('show', '-json', $Request.binaryPath)
                $valid = $shown.exitCode -eq 0 -and (Get-AwsLifecycleBytesHash $shown.bytes) -ceq $root.plan.jsonSha256 -and (Get-LifecycleFileHash $Request.binaryPath) -ceq $root.plan.binarySha256
            }
            $target = $Context.inventory.target
            return @{ verified = $true; product = $Request.product; environment = $Request.environment; instanceId = $Request.instanceId
                accountId = $target.accountId; region = $target.region; roleArn = $target.roleArn; stateBucket = $target.stateBucket
                configurationSha256 = $Context.snapshot.manifest.roots[$root.id].configurationSha256; inputsSha256 = $Context.snapshot.manifest.roots[$root.id].inputsSha256
                iacSnapshotSha256 = $Context.inventory.iac.snapshotSha256; stateKey = $root.stateKey
                planVerified = $valid; binarySha256 = $(if ($valid) { Get-LifecycleFileHash $Request.binaryPath } else { $null }); jsonSha256 = $(if ($valid) { Get-AwsLifecycleBytesHash $shown.bytes } else { $null }) }
        }
        'Persist' { return Save-AwsLifecycleJournal $Context $Request.inventoryPath -Confirm:$false }
        'DestructionSafety' { return Get-AwsLifecycleDestructionSafety $Context $Request }
        'Apply' {
            Assert-AwsLifecycleRuntime $Context
            if ((Get-LifecycleFileHash $Request.binaryPath) -cne $Request.binarySha256) { throw 'lifecycle.aws.planChanged' }
            $result = Invoke-AwsLifecycleTerraform $Context $root @('apply', '-input=false', '-lock-timeout=60s', '-no-color', $Request.binaryPath)
            return @{ exitCode = $result.exitCode }
        }
        'Observe' { return Get-AwsLifecycleObservation $Context $root $Request.operation }
        default { throw 'lifecycle.aws.actionUnsupported' }
    }
}

function New-AwsLifecyclePort([hashtable] $Context) {
    $module = $ExecutionContext.SessionState.Module
    return { param($request) & $module { param($contextValue, $requestValue) Invoke-AwsLifecyclePortAction $contextValue $requestValue } $Context $request }.GetNewClosure()
}

Export-ModuleMember -Function Invoke-AwsLifecycleCli, Get-AwsLifecycleRootInputs, Invoke-AwsLifecycleQuiesce, Assert-AwsMessagingBindings, New-AwsLifecyclePort, New-AwsLifecyclePlan, Get-AwsLifecycleObservation, Get-AwsLifecycleDestructionSafety, Assert-AwsLifecycleRuntime, Assert-AwsLifecycleInputs, Get-AwsLifecycleState
