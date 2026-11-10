<#
.SYNOPSIS
    Exercises ephemeral definitions, bootstrap reviews, GitHub protections and staged workflow recovery.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repository 'scripts/EnvironmentWorkflow.psm1') -Force
Import-Module (Join-Path $repository 'scripts/EphemeralEnvironment.psm1')
Import-Module (Join-Path $repository 'scripts/EnvironmentLifecycle.psm1')
Import-Module (Join-Path $repository 'scripts/EnvironmentSnapshot.psm1')
Import-Module (Join-Path $repository 'scripts/PlatformBootstrap.psm1')
Import-Module (Join-Path $repository 'scripts/TerraformAzureLifecycle.psm1')
$parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
$temporary = Join-Path $parent "hexagon-workflow-tests-$([guid]::NewGuid().ToString('N'))"
[IO.Directory]::CreateDirectory($temporary) | Out-Null
$script:assertions = 0
function Assert-True([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message }; $script:assertions++ }
function Assert-Rejected([scriptblock] $Action, [string] $Code) {
    try { & $Action | Out-Null }
    catch { Assert-True ($_.Exception.Message -like "*$Code*") "Unexpected rejection: $($_.Exception.Message)"; return }
    throw "Expected rejection: $Code"
}
function Copy-Value([object] $Value) { return (ConvertTo-PlatformBootstrapJson $Value) | ConvertFrom-Json -AsHashtable -Depth 64 }
function Write-Json([string] $Path, [object] $Value) { [IO.File]::WriteAllText($Path, (ConvertTo-PlatformBootstrapJson $Value) + "`n") }
$definition = Read-EphemeralEnvironment (Join-Path $repository 'examples/ephemeral-environment.json')
$definition.expiresAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 3600
$module = Get-Module EphemeralEnvironment
try {
    Assert-EphemeralSelection $definition dev run-12345-1 Create
    Assert-Rejected { Assert-EphemeralSelection $definition staging run-12345-1 Create } 'selectionMismatch'
    $expired = Copy-Value $definition; $expired.expiresAt = 1
    Assert-Rejected { Assert-EphemeralSelection $expired dev run-12345-1 Create } 'expired'
    Assert-EphemeralSelection $expired dev run-12345-1 Destroy
    Assert-True ($true) 'Expired instances must remain recoverable and removable.'
    $unbounded = Copy-Value $definition; $unbounded.expiresAt += 604800
    Assert-Rejected { Assert-EphemeralSelection $unbounded dev run-12345-1 Create } 'expiryTooLong'
    $path = Join-Path $temporary 'definition.json'
    foreach ($mutation in @(
        { param($d) $d.inventory.target.container = 'tfstate-dev' },
        { param($d) $d.inventory.components = @('backend') },
        { param($d) $d.inventory.environment = 'prod' },
        { param($d) $d.oidcPrefix = 'repo:foreign/hexagon-template-devops' },
        { param($d) $d.protectedResourceGroups = @($d.inventory.roots[0].resourceGroup) },
        { param($d) $d.clientSecret = 'never-store-a-credential' }
    )) {
        $bad = Copy-Value $definition; & $mutation $bad; Write-Json $path $bad
        Assert-Rejected { Read-EphemeralEnvironment $path } 'lifecycle.'
    }
    Assert-Rejected { Assert-EphemeralTrackedDefinition $path ('a' * 64) prod run-12345-1 Create } 'productionNotSupported'
    Assert-Rejected { Assert-EphemeralTrackedDefinition $path ('a' * 64) dev '../foreign' Create } 'selectionInvalid'
    Assert-Rejected { Assert-EphemeralTrackedDefinition $path ('a' * 64) dev run-12345-1 Create } 'definitionPathInvalid'
    Assert-Rejected { Resolve-EphemeralWorkspacePath $temporary } 'workspaceOutsideArtifacts'
    $storage = @{ id = "/subscriptions/$($definition.inventory.target.subscriptionId)/resourceGroups/$($definition.inventory.target.stateResourceGroup)/providers/Microsoft.Storage/storageAccounts/$($definition.inventory.target.storageAccount)"; allowSharedKeyAccess = $false; allowBlobPublicAccess = $false; minimumTlsVersion = 'TLS1_2'; encryption = @{ requireInfrastructureEncryption = $true } }
    $properties = @{ isVersioningEnabled = $true; deleteRetentionPolicy = @{ enabled = $true; days = 30 }; containerDeleteRetentionPolicy = @{ enabled = $true; days = 30 } }
    Assert-EphemeralBootstrapStorage $definition $storage $properties
    $badStorage = Copy-Value $storage; $badStorage.allowSharedKeyAccess = $true
    Assert-Rejected { Assert-EphemeralBootstrapStorage $definition $badStorage $properties } 'storageNotProtected'
    $badProperties = Copy-Value $properties; $badProperties.isVersioningEnabled = $false
    Assert-Rejected { Assert-EphemeralBootstrapStorage $definition $storage $badProperties } 'storageNotProtected'
    $unused = Join-Path $repository "artifacts/workflow-whatif-$([guid]::NewGuid().ToString('N'))"
    New-EphemeralWorkspace $unused -WhatIf | Out-Null
    Assert-True (-not (Test-Path -LiteralPath $unused)) 'Workspace WhatIf created a directory.'

    $plan = @{ format_version = '1.2'; complete = $true; errored = $false; resource_changes = @(@{ mode = 'managed'; type = 'azurerm_user_assigned_identity'; change = @{ actions = @('create') } }) }
    Assert-EphemeralReservationPlan $plan
    Assert-EphemeralReservationPlan @{ format_version = '1.2'; complete = $true; errored = $false }
    Assert-True ($true) 'A converged second reservation must be supported.'
    foreach ($mutation in @(
        { param($p) $p.resource_changes[0].change.actions = @('delete', 'create') },
        { param($p) $p.resource_changes[0].change.actions = @('update') },
        { param($p) $p.complete = $false },
        { param($p) $p.errored = 'false' },
        { param($p) $p.action_invocations = @(@{ action = 'unexpected' }) },
        { param($p) $p.resource_changes[0].change.importing = @{ id = 'foreign' } },
        { param($p) $p.resource_changes[0].type = 'azurerm_virtual_machine' }
    )) {
        $bad = Copy-Value $plan; & $mutation $bad
        Assert-Rejected { Assert-EphemeralReservationPlan $bad } 'reservationChangeForbidden'
    }
    $names = @('main.tf', 'providers.tf', 'variables.tf', 'outputs.tf', 'versions.tf', '.terraform.lock.hcl', 'terraform.rc', 'backend.json', 'inputs.tfvars.json', 'reservation.tfplan', 'reservation.json')
    $hashes = @{}
    foreach ($name in $names) { [IO.File]::WriteAllText((Join-Path $temporary $name), "public-fixture-$name"); $hashes[$name] = Get-LifecycleFileHash (Join-Path $temporary $name) }
    $review = @{ definitionSha256 = 'a' * 64; sourceSha256 = 'b' * 64; createdAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); files = $hashes; terraformVersion = '1.17.1' }
    $reviewHash = Get-SnapshotHash $review
    Assert-EphemeralReservationReview $review $reviewHash ('a' * 64) ('b' * 64) $temporary
    Assert-Rejected { Assert-EphemeralReservationReview $review ('f' * 64) ('a' * 64) ('b' * 64) $temporary } 'reviewStale'
    Assert-Rejected { Assert-EphemeralReservationReview $review $reviewHash ('c' * 64) ('b' * 64) $temporary } 'reviewStale'
    $old = Copy-Value $review; $old.createdAt -= 90000
    Assert-Rejected { Assert-EphemeralReservationReview $old (Get-SnapshotHash $old) ('a' * 64) ('b' * 64) $temporary } 'reviewStale'
    $bad = Copy-Value $review; $bad.files['../outside.tf'] = 'c' * 64
    Assert-Rejected { Assert-EphemeralReservationReview $bad (Get-SnapshotHash $bad) ('a' * 64) ('b' * 64) $temporary } 'reviewStale'
    [IO.File]::AppendAllText((Join-Path $temporary 'backend.json'), 'tampered')
    Assert-Rejected { Assert-EphemeralReservationReview $review $reviewHash ('a' * 64) ('b' * 64) $temporary } 'reviewChanged'

    $messaging = @{ destinations = @{ events = @{ publishers = @{ api = 'placeholder' }; name = 'events' } }; consumers = @{ sales = @{ workload = 'consumer'; principal_id = 'placeholder'; max_delivery_count = 5 } }; product = 'hexagon-template' }
    $principals = @{ api = '11111111-1111-1111-1111-111111111111'; consumer = '22222222-2222-2222-2222-222222222222' }
    $bound = ConvertTo-AzureMessagingPrincipalInput $messaging $principals
    Assert-True ($bound.destinations.events.publishers.api -ceq $principals.api -and $bound.consumers.sales.principal_id -ceq $principals.consumer -and $bound.consumers.sales.max_delivery_count -eq 5 -and $messaging.destinations.events.publishers.api -ceq 'placeholder') 'Principal binding changed topology or mutated source inputs.'
    Assert-Rejected { ConvertTo-AzureMessagingPrincipalInput $messaging @{ consumer = $principals.consumer } } 'publisherIdentityMissing'
    Assert-Rejected { ConvertTo-AzureMessagingPrincipalInput $messaging @{ api = $principals.api } } 'consumerIdentityMissing'

    # The protocol double records the shared stage sequence, never Terraform/cloud commands.
    $fixture = @{ remote = $null; calls = [Collections.Generic.List[string]]::new(); fail = ''; syncStatus = 'Verified' }
    $port = {
        param($action)
        $fixture.calls.Add($action)
        if ($fixture.fail -ceq $action) { throw 'lifecycle.ephemeral.fixtureFailure' }
        if ($action -ceq 'Probe') { return @{ status = 'Probed'; inventory = $fixture.remote } }
        if ($action -ceq 'Sync') { return @{ status = $fixture.syncStatus; applicationVerified = $false } }
        return @{ status = $(if ($action -ceq 'Prepare') { 'Prepared' } elseif ($action -ceq 'Apply') { 'Verified' } else { 'Completed' }); applicationVerified = $false }
    }.GetNewClosure()
    $result = Invoke-EphemeralStage $definition Create Prepare hosting '' '' $port -Confirm:$false
    Assert-True ($result.status -ceq 'Prepared' -and ($fixture.calls -join ',') -ceq 'Probe,ValidateSources,Build,Initialize,Prepare') 'Initial Genesis bypassed source checks or durable initialization.'
    $fixture.calls.Clear()
    Assert-Rejected { Invoke-EphemeralStage $definition Destroy Prepare hosting '' '' $port -Confirm:$false } 'journalMissing'
    Assert-True (($fixture.calls -join ',') -ceq 'Probe') 'Apocalypse fabricated an inventory instead of requiring recovery.'
    $fixture.calls.Clear()
    $result = Invoke-EphemeralStage $definition Create Prepare hosting '' '' $port -WhatIf
    Assert-True ($result.status -ceq 'Unverified' -and $fixture.calls.Count -eq 0) 'Stage WhatIf called the cloud port.'
    Assert-Rejected { Invoke-EphemeralStage $definition Create Apply hosting '' '' $port -Confirm:$false } 'reviewRequired'
    Assert-Rejected { Invoke-EphemeralStage $definition Destroy Apply hosting ('a' * 64) 'DESTROY foreign dev run-12345-1' $port -Confirm:$false } 'confirmationMismatch'
    Assert-Rejected { Invoke-EphemeralStage $definition Create Quiesce hosting '' '' $port -Confirm:$false } 'operationMismatch'
    Assert-True ($fixture.calls.Count -eq 0) 'Invalid approvals contacted the port.'
    $fixture.remote = Copy-Value $definition.inventory
    $fixture.remote.roots[0].lastOperation = 'Create'; $fixture.remote.roots[0].status = 'Verified'
    $result = Invoke-EphemeralStage $definition Create Prepare messaging '' '' $port -Confirm:$false
    Assert-True (($fixture.calls -join ',') -ceq 'Probe,Restore,BindMessaging,Prepare') 'Messaging did not use recovered hosting identities before its new plan.'
    $fixture.calls.Clear()
    $fixture.remote.roots[1].lastOperation = 'Create'; $fixture.remote.roots[1].status = 'Failed'; $fixture.syncStatus = 'Failed'
    Invoke-EphemeralStage $definition Destroy Prepare messaging '' '' $port -Confirm:$false | Out-Null
    Assert-True (($fixture.calls -join ',') -ceq 'Probe,Restore,Sync,Prepare') 'Destruction did not reconcile partial state before planning.'
    $fixture.calls.Clear()
    Invoke-EphemeralStage $expired Destroy Quiesce hosting '' 'QUIESCE hexagon-template dev run-12345-1' $port -Confirm:$false | Out-Null
    Assert-True (($fixture.calls -join ',') -ceq 'Probe,Restore,Quiesce') 'An expired instance could not quiesce without app sources.'
    $fixture.calls.Clear()
    $fixture.remote.roots[1].status = 'Applying'
    Assert-Rejected { Invoke-EphemeralStage $definition Create Prepare messaging '' '' $port -Confirm:$false } 'reconciliationRequired'
    Assert-True (-not $fixture.calls.Contains('Prepare')) 'An interrupted apply reused planning without Sync.'
    $fixture.calls.Clear(); $fixture.remote.roots[1].status = 'Failed'; $fixture.fail = 'Restore'
    Assert-Rejected { Invoke-EphemeralStage $definition Destroy Apply messaging ('a' * 64) 'DESTROY hexagon-template dev run-12345-1' $port -Confirm:$false } 'fixtureFailure'
    Assert-True (-not $fixture.calls.Contains('Apply')) 'Failed recovery still applied a plan.'
    $fixture.fail = ''; $fixture.calls.Clear(); $fixture.remote.releaseSha256 = 'c' * 64
    Assert-Rejected { Invoke-EphemeralStage $definition Create Prepare hosting '' '' $port -Confirm:$false } 'creationContextChanged'
    Invoke-EphemeralStage $definition Destroy Prepare messaging '' '' $port -Confirm:$false | Out-Null
    Assert-True (-not $fixture.calls.Contains('ValidateSources')) 'Cleanup depended on current release/application sources.'

    $isolation = @{ status = 403; calls = [Collections.Generic.List[string]]::new() }
    $reader = { param($uri, $storage) $isolation.calls.Add($uri); if ($storage -and $uri -match '/tfstate-run-12345-1-dev[?]') { return 200 }; return $isolation.status }.GetNewClosure()
    $result = Test-EphemeralIsolation $definition $reader
    Assert-True ($result.status -ceq 'Verified' -and $isolation.calls.Count -eq $definition.protectedResourceGroups.Count + 5) 'Isolation did not probe protected groups and all persistent/bootstrap containers.'
    foreach ($status in @(200, 401, 404, 500)) { $isolation.status = $status; Assert-Rejected { Test-EphemeralIsolation $definition $reader } 'isolationNotVerified' }

    # GitHub API responses are explicit protocol fixtures; mutations must be followed by readback.
    $github = @{ calls = [Collections.Generic.List[string]]::new(); branches = @(); variables = @(); configured = $false; drift = $false }
    & $module {
        param($Fixture)
        $script:githubFixture = $Fixture
        function script:Invoke-EphemeralGithub {
            param($Method, $Path, $Body)
            $f = $script:githubFixture; $f.calls.Add("$Method $Path")
            if ($Path -ceq 'repos/example-owner/hexagon-template-devops') { return @{ full_name = 'example-owner/hexagon-template-devops'; default_branch = 'main'; archived = $false; disabled = $false; owner = @{ login = 'example-owner'; id = 123 }; name = 'hexagon-template-devops'; id = 456 } }
            if ($Path -like '*/actions/oidc/customization/sub') { return @{ use_default = $true; sub_claim_prefix = 'repo:example-owner@123/hexagon-template-devops@456' } }
            if ($Path -like '*/environments?per_page=100') { return @{ total_count = $(if ($f.configured) { 1 } else { 0 }); environments = @($(if ($f.configured) { @{ name = 'dev-run-12345-1' } })) } }
            if ($Path -like '*/deployment-branch-policies*') {
                if ($Method -ceq 'POST') { $f.branches += $Body; return @{} }
                return @{ total_count = $f.branches.Count; branch_policies = $f.branches }
            }
            if ($Path -like '*/variables*') {
                if ($Method -ceq 'POST') { $f.variables += $Body; return @{} }
                return @{ total_count = $f.variables.Count; variables = $f.variables }
            }
            if ($Method -ceq 'PUT') { $f.configured = $true; return @{} }
            return @{ can_admins_bypass = $f.drift; deployment_branch_policy = @{ protected_branches = $false; custom_branch_policies = $true }; protection_rules = @(@{ type = 'branch_policy' }) }
        }
    } $github
    Set-EphemeralGithubProtection $definition -WhatIf
    Assert-True (@($github.calls | Where-Object { $_ -match '^(PUT|POST|PATCH) ' }).Count -eq 0) 'GitHub WhatIf mutated protections.'
    Set-EphemeralGithubProtection $definition -Confirm:$false
    Assert-True ($github.configured -and $github.branches.Count -eq 1 -and $github.variables.Count -eq 3) 'GitHub instance bindings were not reconciled.'
    $github.calls.Clear(); Get-EphemeralGithubProtection $definition -SkipBindings | Out-Null
    Assert-True (@($github.calls | Where-Object { $_ -like '*variables*' }).Count -eq 0) 'Workflow protection validation required administrative variable API access.'
    $github.calls.Clear(); Set-EphemeralGithubProtection $definition -Confirm:$false
    Assert-True (@($github.calls | Where-Object { $_ -match '^(POST|PATCH) ' }).Count -eq 0) 'A second configuration duplicated bindings or policies.'
    $github.drift = $true
    Assert-Rejected { Get-EphemeralGithubProtection $definition } 'githubProtectionDrift'
    $github.drift = $false; $github.branches += @{ name = 'feature'; type = 'branch' }; $github.calls.Clear()
    Assert-Rejected { Set-EphemeralGithubProtection $definition -Confirm:$false } 'githubBranchConflict'
    Assert-True (@($github.calls | Where-Object { $_ -match '^(PUT|POST|PATCH) ' }).Count -eq 0) 'GitHub branch conflict was detected after mutation.'

    # Invoke the real workflow CLI against real tracked Git bytes in an isolated runspace.
    # Only GitHub HTTP and Azure account access are replaced; Validate must never use Azure.
    $source = Join-Path $temporary 'source'; [IO.Directory]::CreateDirectory($source) | Out-Null
    foreach ($relative in @('scripts', 'contracts/schemas', '.config')) {
        $destination = Join-Path $source $relative; [IO.Directory]::CreateDirectory($destination) | Out-Null
        Get-ChildItem -LiteralPath (Join-Path $repository $relative) -File -Force | Copy-Item -Destination $destination
    }
    $profileDirectory = Join-Path $source '.config/environments/dev/run-12345-1'
    [IO.Directory]::CreateDirectory($profileDirectory) | Out-Null
    $profilePath = Join-Path $profileDirectory 'definition.json'; Write-Json $profilePath $definition
    foreach ($arguments in @(@('init', '-b', 'main'), @('config', 'core.autocrlf', 'false'), @('config', 'commit.gpgsign', 'false'), @('config', 'user.email', 'fixture@example.invalid'), @('config', 'user.name', 'Workflow fixture'), @('add', '.'), @('commit', '-m', 'Fixture source'))) {
        & git -C $source @arguments *> $null
        if ($LASTEXITCODE -ne 0) { throw 'Workflow Git fixture preparation failed.' }
    }
    $runspace = [PowerShell]::Create()
    $scriptBody = {
        param($Root, $Hash, $RunMode, $Handler, $Inventory)
        $ErrorActionPreference = 'Stop'
        Import-Module (Join-Path $Root 'scripts/EphemeralEnvironment.psm1')
        Import-Module (Join-Path $Root 'scripts/AzureEnvironmentStore.psm1')
        & (Get-Module AzureEnvironmentStore) { function script:Assert-AzureLifecycleAccount { throw 'Unexpected Azure account access during workflow validation.' } }
        if ($RunMode -ceq 'Prepare') {
            & (Get-Module AzureEnvironmentStore) {
                param($Fixture)
                $script:workflowHandler = $Fixture
                function script:Assert-AzureLifecycleAccount { param($Inventory) }
                function script:New-AzureLifecycleHttpClient { return [Net.Http.HttpClient]::new($script:workflowHandler, $false) }
                function script:Get-LifecycleAzureToken { param($Context, $Resource) return 'fixture-access-token' }
            } $Handler
            Import-Module (Join-Path $Root 'scripts/LifecycleNative.psm1')
            & (Get-Module LifecycleNative) {
                $script:originalCommand = (Get-Command Invoke-LifecycleCommand).ScriptBlock
                function script:Invoke-LifecycleCommand {
                    param($Tool, $Arguments, $Directory, $Environment, $TimeoutSeconds, $Heartbeat)
                    if ($Tool -ceq 'git') { return & $script:originalCommand -Tool git -Arguments $Arguments -Directory $Directory -TimeoutSeconds 30 }
                    if ($Tool -cne 'pwsh') { throw 'Unexpected Azure or Terraform command in the coordinator fixture.' }
                    $index = [Array]::IndexOf($Arguments, '-Mode'); $mode = $Arguments[$index + 1]
                    if ($mode -cnotin @('Restore', 'Prepare')) { throw 'Unexpected native lifecycle stage.' }
                    $path = $Arguments[[Array]::IndexOf($Arguments, '-Inventory') + 1]
                    if ($mode -ceq 'Restore' -and -not (Test-Path -LiteralPath $path)) { throw 'Missing initial inventory locator.' }
                    $json = @{ apiVersion = 'hexagon.ec/azure-environment-result/v1'; status = $(if ($mode -ceq 'Restore') { 'Restored' } else { 'Prepared' }); applicationVerified = $false; details = @{ reviewSha256 = 'a' * 64 } } | ConvertTo-Json -Compress
                    return @{ exitCode = 0; text = $json; bytes = [Text.Encoding]::UTF8.GetBytes($json) }
                }
                Export-ModuleMember -Function Invoke-LifecycleCommand, Assert-LifecycleCliEnvironment
            }
        }
        & (Get-Module EphemeralEnvironment) {
            function script:Invoke-EphemeralGithub {
                param($Method, $Path, $Body)
                if ($Method -cne 'GET') { throw 'Unexpected GitHub mutation.' }
                if ($Path -ceq 'repos/example-owner/hexagon-template-devops') { return @{ full_name = 'example-owner/hexagon-template-devops'; default_branch = 'main'; archived = $false; disabled = $false; owner = @{ login = 'example-owner'; id = 123 }; name = 'hexagon-template-devops'; id = 456 } }
                if ($Path -like '*/actions/oidc/customization/sub') { return @{ use_default = $true; sub_claim_prefix = 'repo:example-owner@123/hexagon-template-devops@456' } }
                if ($Path -like '*/deployment-branch-policies*') { return @{ total_count = 1; branch_policies = @(@{ name = 'main'; type = 'branch' }) } }
                if ($Path -like '*/variables*') { throw 'Workflow validation requested privileged variable API access.' }
                return @{ can_admins_bypass = $false; deployment_branch_policy = @{ protected_branches = $false; custom_branch_policies = $true }; protection_rules = @(@{ type = 'branch_policy' }) }
            }
        }
        $names = @('GITHUB_ACTIONS', 'GITHUB_EVENT_NAME', 'GITHUB_REF', 'GITHUB_REPOSITORY', 'GITHUB_WORKFLOW_REF', 'GITHUB_STEP_SUMMARY', 'AZURE_CLIENT_ID', 'AZURE_TENANT_ID', 'AZURE_SUBSCRIPTION_ID'); $previous = @{}
        foreach ($name in $names) { $previous[$name] = [Environment]::GetEnvironmentVariable($name) }
        try {
            $env:GITHUB_ACTIONS = 'true'; $env:GITHUB_EVENT_NAME = 'workflow_dispatch'; $env:GITHUB_REF = 'refs/heads/main'
            $env:GITHUB_REPOSITORY = 'example-owner/hexagon-template-devops'; $env:GITHUB_WORKFLOW_REF = 'example-owner/hexagon-template-devops/.github/workflows/genesis.yml@refs/heads/main'
            $env:GITHUB_STEP_SUMMARY = $null
            $env:AZURE_CLIENT_ID = $Inventory.target.clientId; $env:AZURE_TENANT_ID = $Inventory.target.tenantId; $env:AZURE_SUBSCRIPTION_ID = $Inventory.target.subscriptionId
            & (Join-Path $Root 'scripts/Invoke-EnvironmentWorkflow.ps1') -Operation Create -Mode $RunMode -Environment dev -InstanceId run-12345-1 -DefinitionSha256 $Hash
        }
        finally { foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) } }
    }
    try {
        [void] $runspace.AddScript($scriptBody.ToString()).AddArgument($source).AddArgument((Get-LifecycleFileHash $profilePath)).AddArgument('Validate').AddArgument($null).AddArgument($definition.inventory)
        $output = $runspace.Invoke()
        if ($runspace.HadErrors) { throw 'Workflow CLI validation failed in its protocol fixture.' }
        $validated = $output -join "`n" | ConvertFrom-Json
        Assert-True ($validated.status -ceq 'Validated' -and $validated.details.githubEnvironment -ceq 'dev-run-12345-1' -and $validated.details.clientId -ceq $definition.inventory.target.clientId) 'CLI validation did not bind real tracked definition bytes to the workflow environment.'
    }
    finally { $runspace.Dispose() }
    if (-not ('Hexagon.LifecycleTests.LifecycleHttpHandler' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'LifecycleHttpHandler.cs') }
    $handler = [Hexagon.LifecycleTests.LifecycleHttpHandler]::new()
    $key = "/$($definition.inventory.target.container)/$($definition.inventory.product)/dev/run-12345-1/inventory.json"
    $handler.Blobs[$key] = [Text.Encoding]::UTF8.GetBytes((ConvertTo-PlatformBootstrapJson $definition.inventory))
    $handler.Etags[$key] = '"workflow-fixture"'
    $runspace = [PowerShell]::Create()
    try {
        [void] $runspace.AddScript($scriptBody.ToString()).AddArgument($source).AddArgument((Get-LifecycleFileHash $profilePath)).AddArgument('Prepare').AddArgument($handler).AddArgument($definition.inventory)
        $output = $runspace.Invoke()
        if ($runspace.HadErrors) {
            $diagnostic = @($runspace.Runspace.SessionStateProxy.GetVariable('Error')) | Select-Object -First 1
            throw "Workflow CLI preparation failed in its protocol fixture: $($output -join '') $($diagnostic.Exception.Message) $($diagnostic.ScriptStackTrace)"
        }
        $prepared = $output -join "`n" | ConvertFrom-Json
        Assert-True ($prepared.status -ceq 'Prepared' -and $prepared.details.reviewSha256 -ceq ('a' * 64) -and $null -eq $handler.LeaseId) "CLI preparation did not restore, delegate or release its inventory lease: $($output -join '')"
    }
    finally { $runspace.Dispose(); $handler.Dispose() }

    $output = & pwsh -NoProfile -File (Join-Path $repository 'scripts/Invoke-EphemeralBootstrap.ps1') -Mode Prepare -Definition (Join-Path $repository 'examples/ephemeral-environment.json') -Workspace $unused -WhatIf
    Assert-True ($LASTEXITCODE -eq 2 -and ($output -join "`n" | ConvertFrom-Json).status -ceq 'Unverified' -and -not (Test-Path -LiteralPath $unused)) 'Bootstrap CLI WhatIf wrote files or claimed success.'
}
finally {
    Remove-Module EphemeralEnvironment, EnvironmentWorkflow -Force -ErrorAction SilentlyContinue
    $resolved = [IO.Path]::GetFullPath($temporary)
    if ([IO.Path]::GetDirectoryName($resolved) -cne $parent -or -not [IO.Path]::GetFileName($resolved).StartsWith('hexagon-workflow-tests-')) { throw 'Unsafe workflow test cleanup.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Host "Ephemeral workflow tests passed: $script:assertions assertions; GitHub/isolation/stage protocol doubles, no cloud changes."
