Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
foreach ($name in @('PlatformBootstrap', 'EnvironmentLifecycle', 'EnvironmentSnapshot', 'AwsEnvironmentStore', 'TerraformAwsLifecycle', 'AwsLifecycleInputs', 'ApplicationArtifacts', 'AwsOciDelivery', 'AwsMaintenanceDelivery', 'AwsWebDelivery', 'StaticWebPublication', 'AzureAcceptance', 'AcceptanceCleanup', 'AcceptanceRun', 'AwsAcceptance')) {
    Import-Module (Join-Path $PSScriptRoot "$name.psm1")
}

# Application delivery on AWS (ADR 0025): images to ECR by digest, the maintenance plan, the database
# tasks in the order of ADR 0024 (database-credentials, migrations, database-access and, with integrated
# identity, keycloak-database), the identity and application rollouts, the SPA behind CloudFront, the
# serving evidence and the authenticated acceptance with its cleanup. The journal lives in the S3
# custody of the instance.

$script:taskCommands = @{ 'database-credentials' = @('--prepare-credentials'); migrations = @('--migrate-only'); 'database-access' = @(); 'keycloak-database' = @('--prepare-keycloak'); 'acceptance-seed' = @('--seed-acceptance-only') }
$script:applicationTasks = @('migrations', 'acceptance-seed')

function Assert-AwsDeliveryJournal([hashtable] $Context, [hashtable] $Journal, [string] $DeliverySha256) {
    $json = ConvertTo-Json -InputObject $Journal -Depth 24
    $inventory = $Context.inventory
    if (-not ($json | Test-Json -SchemaFile (Join-Path $PSScriptRoot '../contracts/schemas/application-delivery-journal-v1.schema.json') -ErrorAction SilentlyContinue) -or
        $Journal.product -cne $inventory.product -or $Journal.environment -cne $inventory.environment -or $Journal.instanceId -cne $inventory.instance.id -or
        $Journal.releaseSha256 -cne $inventory.releaseSha256 -or $Journal.deliverySha256 -cne $DeliverySha256 -or $Journal.iacCommit -cne $inventory.iac.commit -or
        $Journal.targetSha256 -cne (Get-SnapshotHash $inventory.target)) { throw 'lifecycle.delivery.journalInvalid' }
    foreach ($record in $Journal.jobs.Values) {
        if ($record.status -cnotin @('Starting', 'Running') -and -not $record.executionId) { throw 'lifecycle.delivery.journalInvalid' }
    }
    if ($Journal.ContainsKey('web') -and (($Journal.web.status -ceq 'Verified') -ne ($null -ne $Journal.web.evidenceSha256))) { throw 'lifecycle.delivery.journalInvalid' }
    if ($Journal.ContainsKey('acceptance') -and $Journal.acceptance.status -ceq 'Completed' -and
        (-not $Journal.acceptance.journeySucceeded -or $Journal.acceptance.cleanupStatus -cne 'Destroyed' -or $null -eq $Journal.acceptance.evidenceSha256)) { throw 'lifecycle.acceptance.journalInvalid' }
}

function Read-AwsDeliveryJournal([hashtable] $Context, [string] $DeliverySha256) {
    Assert-AwsLifecycleLease $Context -Confirm:$false
    $response = Get-AwsLifecycleStoredObject $Context 'delivery.json'
    $Context.deliveryEtag = $null; $Context.deliveryRevision = -1L
    if ($response.status -eq 404) {
        return @{ apiVersion = 'hexagon.ec/application-delivery-journal/v1'; product = $Context.inventory.product; environment = $Context.inventory.environment; instanceId = $Context.inventory.instance.id
            releaseSha256 = $Context.inventory.releaseSha256; deliverySha256 = $DeliverySha256; targetSha256 = Get-SnapshotHash $Context.inventory.target; iacCommit = $Context.inventory.iac.commit
            revision = -1L; images = @{}; jobs = @{}; maintenanceSha256 = $null; plan = $null; activated = $false }
    }
    if ($response.status -ne 200 -or $response.bytes.Length -gt 1MB -or -not $response.etag) { throw 'lifecycle.delivery.journalUnavailable' }
    $journal = [Text.Encoding]::UTF8.GetString($response.bytes) | ConvertFrom-Json -AsHashtable -Depth 24
    Assert-AwsDeliveryJournal $Context $journal $DeliverySha256
    $Context.deliveryEtag = $response.etag; $Context.deliveryRevision = $journal.revision
    return $journal
}

function Save-AwsDeliveryJournal {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([hashtable] $Context, [hashtable] $Journal)
    if (-not $PSCmdlet.ShouldProcess($Context.prefix, 'Persist application delivery checkpoint')) { return }
    if ($Journal.revision -ne $Context.deliveryRevision) { throw 'lifecycle.delivery.journalRevisionMismatch' }
    $Journal.revision++
    Assert-AwsDeliveryJournal $Context $Journal $Journal.deliverySha256
    $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-PlatformBootstrapJson $Journal) + "`n")
    $write = Write-AwsLifecycleStoredObject $Context 'delivery.json' $bytes $Context.deliveryEtag
    if ($write.status -ne 200) { throw 'lifecycle.delivery.journalConflict' }
    $read = Read-AwsDeliveryJournal $Context $Journal.deliverySha256
    $observed = [Text.Encoding]::UTF8.GetBytes((ConvertTo-PlatformBootstrapJson $read) + "`n")
    if ((Get-AwsLifecycleBytesHash $observed) -cne (Get-AwsLifecycleBytesHash $bytes)) { throw 'lifecycle.delivery.journalNotDurable' }
}

function Get-AwsDeliveryInputs([hashtable] $Context) {
    return [Text.Encoding]::UTF8.GetString($Context.snapshot.files['inputs/hosting.tfvars.json']) | ConvertFrom-Json -AsHashtable -Depth 40
}

# The verified hosting state of the instance, its inputs and the ECR references of the release.
function Get-AwsDeliveryHosting([hashtable] $Context, [hashtable] $Release, [switch] $AllowPendingPlan) {
    Assert-AwsLifecycleLease $Context -Confirm:$false
    $root = @($Context.inventory.roots | Where-Object id -CEQ 'hosting')[0]
    $pending = $AllowPendingPlan -and ($root.status -ceq 'Planned' -or ($root.status -ceq 'Failed' -and $root.errorCode -ceq 'lifecycle.inputsChangedRequiresPlan'))
    if ($root.lastOperation -cne 'Create' -or ($root.status -cne 'Verified' -and -not $pending)) { throw 'lifecycle.delivery.rootNotReady' }
    $state = Get-AwsLifecycleState $Context $root
    if ($state.stateStatus -cne 'Present' -or $state.lineage -cne $root.stateLineage -or $state.serial -ne $root.stateSerial) { throw 'lifecycle.delivery.stateChanged' }
    $outputs = @{}
    foreach ($name in @('registry', 'maintenance_tasks', 'task_network', 'database_bootstrap', 'workload_roles', 'web', 'api_url', 'frontend_authentication', 'keycloak')) {
        if (-not $state.outputs.ContainsKey($name)) { continue }
        if ($state.outputs[$name].ContainsKey('sensitive') -and $state.outputs[$name].sensitive -ne $false) { throw 'lifecycle.delivery.sensitiveOutputRejected' }
        $outputs[$name] = $state.outputs[$name].value
    }
    $inputs = Get-AwsDeliveryInputs $Context
    $server = Get-AwsRegistryServer $Context
    if ($outputs.registry.url -cne $server) { throw 'lifecycle.delivery.registryUnrecorded' }
    $registry = "$server/$($root.namePrefix)"
    $references = @{}
    foreach ($id in $Release.artifacts.backend.Keys) {
        if ($id -ceq 'database-bootstrap') { throw 'lifecycle.delivery.reservedWorkloadId' }
        $references[$id] = Get-DeliveryImageTarget $Release.artifacts.backend[$id] $registry
    }
    $references['database-bootstrap'] = Get-DeliveryImageTarget $Release.artifacts.databaseBootstrap.image $registry
    if ((@($inputs.workloads.Keys | Sort-Object) -join ',') -cne (@($Release.artifacts.backend.Keys | Sort-Object) -join ',')) { throw 'lifecycle.delivery.workloadsMismatch' }
    foreach ($id in $inputs.workloads.Keys) { if ($inputs.workloads[$id].image -cne $references[$id].image) { throw 'lifecycle.delivery.hostingImageMismatch' } }
    if ($inputs.bootstrap_image -cne $references['database-bootstrap'].image) { throw 'lifecycle.delivery.hostingImageMismatch' }
    return @{ state = $state; outputs = $outputs; inputs = $inputs; server = $server; registry = $registry; references = $references }
}

function Assert-AwsDeliveryImages([hashtable] $Journal, [hashtable] $Hosting) {
    if ((@($Journal.images.Keys | Sort-Object) -join ',') -cne (@($Hosting.references.Keys | Sort-Object) -join ',')) { throw 'lifecycle.delivery.imagesRequired' }
    foreach ($id in $Hosting.references.Keys) {
        if ($Journal.images[$id].image -cne $Hosting.references[$id].image -or $Journal.images[$id].digest -cne $Hosting.references[$id].digest) { throw 'lifecycle.delivery.imagesRequired' }
    }
}

# Everything that defines the maintenance tasks, except the rollout flags.
function Get-AwsDeliveryMaintenanceHash([hashtable] $Context, [hashtable] $Inputs) {
    $value = @{} + $Inputs; $value.Remove('application_rollout_enabled'); $value.Remove('keycloak_rollout_enabled')
    $messaging = @($Context.inventory.roots | Where-Object id -CEQ 'messaging')
    if ($Inputs.ContainsKey('messaging_enabled') -and $Inputs.messaging_enabled -eq $false) {
        if ($messaging.Count -ne 0) { throw 'lifecycle.delivery.messagingUnexpected' }
        return Get-SnapshotHash @{ hosting = $value; iacCommit = $Context.inventory.iac.commit; messaging = $null }
    }
    if ($messaging.Count -ne 1 -or $messaging[0].status -cne 'Verified') { throw 'lifecycle.delivery.messagingNotReady' }
    return Get-SnapshotHash @{ hosting = $value; iacCommit = $Context.inventory.iac.commit; messaging = @{ lineage = $messaging[0].stateLineage; serial = $messaging[0].stateSerial; inputsSha256 = $messaging[0].inputsSha256 } }
}

function Test-AwsIntegratedKeycloak([hashtable] $Inputs) { return $Inputs.ContainsKey('keycloak') -and $null -ne $Inputs.keycloak }

# The task the delivery expects, checked against the registered task definition before it runs.
function Get-AwsDeliveryTaskSpec([hashtable] $Context, [hashtable] $Hosting, [string] $TaskId) {
    $outputs = $Hosting.outputs; $inputs = $Hosting.inputs
    if (-not $outputs.maintenance_tasks.ContainsKey($TaskId)) { throw 'lifecycle.delivery.maintenanceJobMissing' }
    $arn = [string] $outputs.maintenance_tasks[$TaskId].arn
    # The hosting module names maintenance families <short prefix>-<task>.
    $family = "$($Context.inventory.roots[0].namePrefix)-$TaskId"
    if ($arn -cnotmatch "^arn:aws:ecs:$($Context.inventory.target.region):$($Context.inventory.target.accountId):task-definition/$([regex]::Escape($family)):[0-9]+$") { throw 'lifecycle.delivery.maintenanceJobUnrecorded' }
    $network = $outputs.task_network
    $expected = [ordered] @{ taskDefinitionArn = $arn; cluster = [string] $network.cluster; subnets = @($network.subnets); securityGroups = @($network.security_groups)
        image = $(if ($TaskId -cin $script:applicationTasks) { $inputs.workloads[$inputs.migration_workload].image } else { $inputs.bootstrap_image }); command = $script:taskCommands[$TaskId] }
    if ($expected.cluster -cne $Context.inventory.roots[0].namePrefix -or $network.assign_public_ip -ne $true) { throw 'lifecycle.delivery.taskNetworkChanged' }
    $described = Invoke-AwsLifecycleCli $Context @('ecs', 'describe-task-definition', '--task-definition', $arn)
    if ($described.exitCode -ne 0) { throw 'lifecycle.delivery.maintenanceJobUnavailable' }
    $definition = ($described.text | ConvertFrom-Json -AsHashtable -Depth 32).taskDefinition
    $containers = @($definition.containerDefinitions | Where-Object name -CEQ 'maintenance')
    $command = $(if ($containers.Count -eq 1 -and $containers[0].ContainsKey('command') -and $null -ne $containers[0].command) { @($containers[0].command) } else { @() })
    if ($definition.taskDefinitionArn -cne $arn -or $definition.status -cne 'ACTIVE' -or $containers.Count -ne 1 -or $containers[0].image -cne $expected.image -or
        ($command -join ' ') -cne ($expected.command -join ' ')) { throw 'lifecycle.delivery.maintenanceJobChanged' }
    if ($TaskId -ceq 'acceptance-seed') {
        $fixture = Get-AcceptanceFixture $Context.inventory $inputs
        $embedded = @($containers[0].environment | Where-Object name -CEQ 'HEXAGON_ACCEPTANCE_SEED')
        if ($embedded.Count -ne 1 -or (Get-SnapshotHash ($embedded[0].value | ConvertFrom-Json -AsHashtable)) -cne (Get-SnapshotHash $fixture)) { throw 'lifecycle.acceptance.fixtureChanged' }
    }
    elseif ($TaskId -cne 'migrations') {
        $bootstrap = @{} + $outputs.database_bootstrap
        if ($TaskId -ceq 'keycloak-database') {
            if (-not (Test-AwsIntegratedKeycloak $inputs)) { throw 'lifecycle.identity.notIntegrated' }
            $bootstrap.purpose = 'keycloak'
            $bootstrap.keycloak = @{ role = $outputs.keycloak.role; passwordSecret = $outputs.keycloak.secrets.database; bootstrapSecret = $outputs.keycloak.secrets.bootstrap }
        }
        $embedded = @($containers[0].environment | Where-Object name -CEQ 'HEXAGON_DATABASE_BOOTSTRAP')
        if ($embedded.Count -ne 1 -or (Get-SnapshotHash ($embedded[0].value | ConvertFrom-Json -AsHashtable -Depth 20)) -cne (Get-SnapshotHash $bootstrap)) { throw 'lifecycle.delivery.databaseBindingsChanged' }
    }
    return $expected
}

function Invoke-AwsDeliveryTask([hashtable] $Context, [hashtable] $Journal, [hashtable] $Hosting, [string] $TaskId) {
    $expected = Get-AwsDeliveryTaskSpec $Context $Hosting $TaskId
    $record = $(if ($Journal.jobs.ContainsKey($TaskId)) { $Journal.jobs[$TaskId] } else { $null })
    $save = (Get-Command Save-AwsDeliveryJournal).ScriptBlock
    $persist = { param($value) $Journal.jobs[$TaskId] = $value; & $save $Context $Journal -Confirm:$false }.GetNewClosure()
    return Invoke-AwsDeliveryMaintenance $Context $TaskId $expected $record $persist -Confirm:$false
}

function Set-AwsDeliveryInputs([hashtable] $Context, [hashtable] $Value, [string] $Repository, [string] $TrustedCommit, [string] $Workspace) {
    $directory = Join-Path $Context.runtime "inputs-$([guid]::NewGuid().ToString('N'))"
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    foreach ($root in $Context.inventory.roots) {
        $bytes = $(if ($root.id -ceq 'hosting') { [Text.Encoding]::UTF8.GetBytes((ConvertTo-PlatformBootstrapJson $Value) + "`n") } else { $Context.snapshot.files["inputs/$($root.id).tfvars.json"] })
        [IO.File]::WriteAllBytes((Join-Path $directory "$($root.id).tfvars.json"), $bytes)
    }
    Update-AwsLifecycleInputs -Context $Context -RootId hosting -InputDirectory $directory -Repository $Repository -TrustedCommit $TrustedCommit -InventoryPath (Join-Path $Workspace 'inventory.json') -Archive (Join-Path $Workspace 'snapshot.zip') -AllowUnchanged -Confirm:$false
}

function New-AwsDeliveryPlan([hashtable] $Context, [hashtable] $Journal, [string] $Purpose, [string] $Workspace) {
    $path = Join-Path $Workspace 'inventory.json'
    $root = @($Context.inventory.roots | Where-Object id -CEQ 'hosting')[0]
    $plan = New-AwsLifecyclePlan $Context $root Create -Confirm:$false
    $hash = Add-EnvironmentRootPlan -InventoryPath $path -RootId hosting -Operation Create -BinaryPath $plan.binaryPath -JsonPath $plan.jsonPath -ExpectedInventorySha256 (Get-LifecycleFileHash $path) -Confirm:$false
    Publish-AwsLifecycleObject $Context "plans/$hash/hosting.tfplan" ([IO.File]::ReadAllBytes($plan.binaryPath)) (Get-LifecycleFileHash $plan.binaryPath) -Confirm:$false
    Publish-AwsLifecycleObject $Context "plans/$hash/hosting.json" ([IO.File]::ReadAllBytes($plan.jsonPath)) (Get-LifecycleFileHash $plan.jsonPath) -Confirm:$false
    Save-AwsLifecycleJournal $Context $path -Confirm:$false | Out-Null
    $Context.inventory = Read-EnvironmentInventory $path
    $Journal.plan = @{ purpose = $Purpose; reviewSha256 = $hash }
    Save-AwsDeliveryJournal $Context $Journal -Confirm:$false
    return $hash
}

function Invoke-AwsDeliveryPlan([hashtable] $Context, [hashtable] $Journal, [string] $Purpose, [string] $ReviewSha256, [string] $Confirmation, [string] $Workspace) {
    $root = @($Context.inventory.roots | Where-Object id -CEQ 'hosting')[0]
    if ($null -eq $Journal.plan -or $Journal.plan.purpose -cne $Purpose -or $Journal.plan.reviewSha256 -cne $ReviewSha256 -or
        $null -eq $root.plan -or $root.plan.reviewSha256 -cne $ReviewSha256 -or $ReviewSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'lifecycle.delivery.reviewRequired' }
    $binary = Join-Path $Context.runtime 'hosting.tfplan'
    [IO.File]::WriteAllBytes($binary, (Read-AwsLifecycleObject $Context "plans/$ReviewSha256/hosting.tfplan" $root.plan.binarySha256))
    [IO.File]::WriteAllBytes("$binary.json", (Read-AwsLifecycleObject $Context "plans/$ReviewSha256/hosting.json" $root.plan.jsonSha256))
    $path = Join-Path $Workspace 'inventory.json'
    $result = Invoke-EnvironmentRootOperation -InventoryPath $path -RootId hosting -BinaryPath $binary -JsonPath "$binary.json" -ReviewSha256 $ReviewSha256 -Confirmation $Confirmation -Port (New-AwsLifecyclePort $Context) -Confirm:$false
    $Context.inventory = Read-EnvironmentInventory $path
    if ($result.status -cne 'Verified') { throw 'lifecycle.delivery.infrastructureNotConverged' }
    $Journal.plan = $null
    if ($Purpose -ceq 'Activation') { $Journal.activated = $true }
    Save-AwsDeliveryJournal $Context $Journal -Confirm:$false
}

# Order of the database tasks (ADR 0024): each one requires the previous ones to have succeeded.
function Assert-AwsDeliveryTaskOrder([hashtable] $Journal, [hashtable] $Hosting, [string] $TaskId) {
    $required = switch ($TaskId) {
        'database-credentials' { @() }
        'migrations' { @('database-credentials') }
        'database-access' { @('database-credentials', 'migrations') }
        'keycloak-database' { @('database-credentials') }
        'acceptance-seed' { @('database-credentials', 'migrations', 'database-access') + @(if (Test-AwsIntegratedKeycloak $Hosting.inputs) { 'keycloak-database' }) }
    }
    if ($TaskId -ceq 'keycloak-database' -and -not (Test-AwsIntegratedKeycloak $Hosting.inputs)) { throw 'lifecycle.identity.notIntegrated' }
    foreach ($id in $required) {
        if (-not $Journal.jobs.ContainsKey($id) -or $Journal.jobs[$id].status -cne 'Succeeded') { throw 'lifecycle.delivery.previousTaskRequired' }
    }
}

function Copy-AwsDeliveryInputs([hashtable] $Inputs) { return (ConvertTo-PlatformBootstrapJson $Inputs) | ConvertFrom-Json -AsHashtable -Depth 40 }

# The SNS topic and SQS queues each workload uses, as the messaging root exposes them, merged into a copy
# of the hosting inputs. Only the exact AWS messaging keys and plain physical values are accepted.
function Add-AwsMessagingBindings([hashtable] $Inputs, [object] $Bindings) {
    $value = Copy-AwsDeliveryInputs $Inputs
    if ($Bindings -isnot [Collections.IDictionary]) { throw 'lifecycle.delivery.messagingBindingsUnavailable' }
    foreach ($id in $Bindings.Keys) {
        if (-not $value.workloads.ContainsKey($id)) { throw 'lifecycle.delivery.bindingWorkloadUnknown' }
        if (-not $value.workloads[$id].ContainsKey('environment') -or $null -eq $value.workloads[$id].environment) { $value.workloads[$id].environment = @{} }
        foreach ($key in $Bindings[$id].Keys) {
            $text = [string] $Bindings[$id][$key]
            if ($key -cnotmatch '^Messaging__Aws__(Sns__Destinations__[a-z0-9-]+__(TopicArn|Region)|Sqs__Consumers__[a-z0-9-]+__(QueueUrl|Region|RetryVisibilityTimeoutSeconds))$' -or
                $text -cnotmatch '^[A-Za-z0-9:._/-]+$' -or ($value.workloads[$id].ContainsKey('secret_references') -and $value.workloads[$id].secret_references.ContainsKey($key))) { throw 'lifecycle.delivery.bindingInvalid' }
            if ($value.workloads[$id].environment.ContainsKey($key) -and $value.workloads[$id].environment[$key] -cne $text) { throw 'lifecycle.delivery.bindingConflict' }
            $value.workloads[$id].environment[$key] = $text
        }
    }
    return $value
}

function Get-AwsDeliveryBoundInputs([hashtable] $Context, [hashtable] $Inputs) {
    $messaging = @($Context.inventory.roots | Where-Object id -CEQ 'messaging')
    if ($Inputs.ContainsKey('messaging_enabled') -and $Inputs.messaging_enabled -eq $false) {
        if ($messaging.Count -ne 0) { throw 'lifecycle.delivery.messagingUnexpected' }
        return Copy-AwsDeliveryInputs $Inputs
    }
    if ($messaging.Count -ne 1 -or $messaging[0].status -cne 'Verified') { throw 'lifecycle.delivery.messagingNotReady' }
    $state = Get-AwsLifecycleState $Context $messaging[0]
    if ($state.stateStatus -cne 'Present' -or $state.lineage -cne $messaging[0].stateLineage -or $state.serial -ne $messaging[0].stateSerial -or
        -not $state.outputs.ContainsKey('aws_sns_sqs')) { throw 'lifecycle.delivery.messagingBindingsUnavailable' }
    return Add-AwsMessagingBindings $Inputs $state.outputs.aws_sns_sqs.value.workload_bindings
}

# The application may roll out only after every database task of ADR 0024 succeeded.
function Assert-AwsDeliveryTasksComplete([hashtable] $Journal, [hashtable] $Hosting) {
    $required = @('database-credentials', 'migrations', 'database-access') + @(if (Test-AwsIntegratedKeycloak $Hosting.inputs) { 'keycloak-database' })
    foreach ($id in $required) {
        if (-not $Journal.jobs.ContainsKey($id) -or $Journal.jobs[$id].status -cne 'Succeeded') { throw 'lifecycle.delivery.previousTaskRequired' }
    }
}

function Invoke-AwsApplicationStage {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([hashtable] $Context, [hashtable] $Delivery, [hashtable] $Release, [string] $DeliverySha256,
        [ValidateSet('Artifacts', 'PrepareMaintenance', 'ApplyMaintenance', 'DatabaseCredentials', 'Migrations', 'DatabaseAccess', 'KeycloakDatabase', 'PrepareIdentity', 'ApplyIdentity',
            'PrepareActivation', 'ApplyActivation', 'PublishWeb', 'VerifyServing', 'PrepareAcceptance', 'Acceptance')][string] $Stage,
        [string] $Repository, [string] $TrustedCommit, [string] $Workspace, [string] $ReviewSha256, [string] $Confirmation)
    if (-not $PSCmdlet.ShouldProcess($Context.prefix, "Run application delivery stage $Stage")) { return @{ status = 'Unverified'; applicationVerified = $false; details = @{} } }
    Assert-AwsLifecycleRuntime $Context
    Assert-ApplicationDelivery $Delivery $Context.inventory.releaseSha256
    $journal = Read-AwsDeliveryJournal $Context $DeliverySha256
    # A new verification always replaces the previous evidence; it never inherits it.
    if ($Stage -ceq 'VerifyServing' -and $journal.ContainsKey('web') -and $journal.web.status -ceq 'Verified') {
        $journal.web.status = 'Published'; $journal.web.evidenceSha256 = $null
        Save-AwsDeliveryJournal $Context $journal -Confirm:$false
    }
    $hosting = Get-AwsDeliveryHosting $Context $Release -AllowPendingPlan:($Stage -cin @('PrepareMaintenance', 'ApplyMaintenance', 'PrepareIdentity', 'ApplyIdentity', 'PrepareActivation', 'ApplyActivation'))
    $details = @{}
    switch ($Stage) {
        'Artifacts' {
            if ($hosting.inputs.application_rollout_enabled -or $journal.activated) { throw 'lifecycle.delivery.alreadyActivated' }
            $renew = (Get-Command Assert-AwsLifecycleLease).ScriptBlock
            $heartbeat = { & $renew $Context -Confirm:$false }.GetNewClosure()
            $candidates = Receive-ApplicationCandidates $Delivery $Release $hosting.registry (Join-Path $Context.runtime 'candidates') $heartbeat -Confirm:$false
            Save-AwsDeliveryJournal $Context $journal -Confirm:$false
            foreach ($component in @('backend', 'devops')) {
                foreach ($id in $candidates[$component].images.Keys) {
                    $journal.images[$id] = Publish-AwsOciArchive $Context $candidates[$component].images[$id] $hosting.server -Confirm:$false
                    Save-AwsDeliveryJournal $Context $journal -Confirm:$false
                }
            }
            Assert-AwsDeliveryImages $journal $hosting
            $details.images = $journal.images.Count; $details.webArchiveSha256 = $Release.artifacts.web.sha256
        }
        'PrepareMaintenance' {
            Assert-AwsDeliveryImages $journal $hosting
            Assert-AwsOciImages $Context $hosting.references $hosting.server
            if ($hosting.inputs.application_rollout_enabled -or $journal.activated -or $journal.jobs.Count -gt 0) { throw 'lifecycle.delivery.maintenanceAlreadyStarted' }
            # The workloads receive their SNS topic and SQS queues from the verified messaging root.
            $inputs = Get-AwsDeliveryBoundInputs $Context $hosting.inputs
            $inputs.maintenance_jobs_enabled = $true; $inputs.application_rollout_enabled = $false
            $journal.maintenanceSha256 = Get-AwsDeliveryMaintenanceHash $Context $inputs
            Save-AwsDeliveryJournal $Context $journal -Confirm:$false
            Set-AwsDeliveryInputs $Context $inputs $Repository $TrustedCommit $Workspace
            $details.reviewSha256 = New-AwsDeliveryPlan $Context $journal Maintenance $Workspace
        }
        default {
            Assert-AwsDeliveryImages $journal $hosting
            if ($hosting.inputs.maintenance_jobs_enabled -ne $true -or $journal.maintenanceSha256 -cne (Get-AwsDeliveryMaintenanceHash $Context $hosting.inputs)) { throw 'lifecycle.delivery.maintenanceEvidenceStale' }
            Assert-AwsOciImages $Context $hosting.references $hosting.server
            if ($Stage -cin @('ApplyMaintenance', 'DatabaseCredentials', 'Migrations', 'DatabaseAccess', 'KeycloakDatabase', 'PrepareIdentity', 'ApplyIdentity') -and
                $hosting.inputs.application_rollout_enabled) { throw 'lifecycle.delivery.activationOrderInvalid' }
            switch ($Stage) {
                'ApplyMaintenance' { Invoke-AwsDeliveryPlan $Context $journal Maintenance $ReviewSha256 $Confirmation $Workspace }
                { $_ -cin @('DatabaseCredentials', 'Migrations', 'DatabaseAccess', 'KeycloakDatabase') } {
                    if ($Stage -ceq 'KeycloakDatabase' -and $hosting.inputs.keycloak_rollout_enabled) { throw 'lifecycle.identity.alreadyStarted' }
                    $task = @{ DatabaseCredentials = 'database-credentials'; Migrations = 'migrations'; DatabaseAccess = 'database-access'; KeycloakDatabase = 'keycloak-database' }[$Stage]
                    Assert-AwsDeliveryTaskOrder $journal $hosting $task
                    $record = Invoke-AwsDeliveryTask $Context $journal $hosting $task
                    $details.executionId = $record.executionId
                }
                { $_ -cin @('PrepareIdentity', 'ApplyIdentity') } {
                    if (-not (Test-AwsIntegratedKeycloak $hosting.inputs)) { throw 'lifecycle.identity.notIntegrated' }
                    if (-not $journal.jobs.ContainsKey('keycloak-database') -or $journal.jobs['keycloak-database'].status -cne 'Succeeded') { throw 'lifecycle.identity.databasePreparationRequired' }
                    if ($Stage -ceq 'PrepareIdentity') {
                        $inputs = Copy-AwsDeliveryInputs $hosting.inputs; $inputs.keycloak_rollout_enabled = $true
                        Set-AwsDeliveryInputs $Context $inputs $Repository $TrustedCommit $Workspace
                        $details.reviewSha256 = New-AwsDeliveryPlan $Context $journal Identity $Workspace
                    }
                    else {
                        if ($hosting.inputs.keycloak_rollout_enabled -ne $true) { throw 'lifecycle.identity.rolloutInputsRequired' }
                        Invoke-AwsDeliveryPlan $Context $journal Identity $ReviewSha256 $Confirmation $Workspace
                    }
                }
                { $_ -cin @('PrepareActivation', 'ApplyActivation') } {
                    Assert-AwsDeliveryTasksComplete $journal $hosting
                    Assert-AwsIdentityReady $Context $hosting
                    if ($Stage -ceq 'PrepareActivation') {
                        if ($journal.activated) { throw 'lifecycle.delivery.alreadyActivated' }
                        $inputs = Copy-AwsDeliveryInputs $hosting.inputs; $inputs.application_rollout_enabled = $true
                        Set-AwsDeliveryInputs $Context $inputs $Repository $TrustedCommit $Workspace
                        $details.reviewSha256 = New-AwsDeliveryPlan $Context $journal Activation $Workspace
                    }
                    else {
                        if ($hosting.inputs.application_rollout_enabled -ne $true) { throw 'lifecycle.delivery.activationInputsRequired' }
                        Invoke-AwsDeliveryPlan $Context $journal Activation $ReviewSha256 $Confirmation $Workspace
                    }
                }
                { $_ -cin @('PublishWeb', 'VerifyServing') } {
                    if (-not $journal.activated -or $hosting.inputs.application_rollout_enabled -ne $true) { throw 'lifecycle.web.activationRequired' }
                    Assert-AwsDeliveryTasksComplete $journal $hosting
                    $target = Get-AwsWebTarget $Context $hosting
                    if ($Stage -ceq 'PublishWeb') { Get-AwsBackendHealth $Context $hosting | Out-Null }
                    $payload = New-AwsWebPayload $Context $Delivery $Release $hosting $DeliverySha256
                    $inputsSha256 = Get-SnapshotHash $hosting.inputs
                    if ($Stage -ceq 'PublishWeb') {
                        $journal.web = @{ status = 'Publishing'; deploymentSha256 = $payload.deploymentSha256; archiveSha256 = $payload.identity.archiveSha256
                            overlaySha256 = $payload.identity.overlaySha256; hostingInputsSha256 = $inputsSha256; evidenceSha256 = $null }
                        Save-AwsDeliveryJournal $Context $journal -Confirm:$false
                        $published = Publish-AwsWebPayload $Context $target $payload -Confirm:$false
                        $journal.web.status = 'Published'
                        Save-AwsDeliveryJournal $Context $journal -Confirm:$false
                        $details.invalidationId = $published.invalidationId; $details.filesPublished = $published.files
                    }
                    else {
                        if (-not $journal.ContainsKey('web') -or $journal.web.status -ceq 'Publishing' -or $journal.web.deploymentSha256 -cne $payload.deploymentSha256 -or
                            $journal.web.hostingInputsSha256 -cne $inputsSha256) { throw 'lifecycle.web.publicationEvidenceRequired' }
                        $renew = (Get-Command Assert-AwsLifecycleLease).ScriptBlock; $heartbeat = { & $renew $Context -Confirm:$false }.GetNewClosure()
                        $serving = Test-StaticWebServing $payload $target.origin $heartbeat
                        $backend = Get-AwsBackendHealth $Context $hosting
                        $current = Get-AwsLifecycleState $Context @($Context.inventory.roots | Where-Object id -CEQ 'hosting')[0]
                        if ($current.stateStatus -cne 'Present' -or $current.lineage -cne $hosting.state.lineage -or $current.serial -ne $hosting.state.serial) { throw 'lifecycle.web.stateChangedDuringVerification' }
                        $evidence = @{ apiVersion = 'hexagon.ec/serving-evidence/v1'; product = $Context.inventory.product; environment = $Context.inventory.environment; instanceId = $Context.inventory.instance.id
                            releaseSha256 = $Context.inventory.releaseSha256; deliverySha256 = $DeliverySha256; observedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); hostingInputsSha256 = $inputsSha256
                            backend = $backend; web = $serving; applicationVerified = $false }
                        $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-PlatformBootstrapJson $evidence)); $hash = Get-AwsLifecycleBytesHash $bytes
                        Publish-AwsLifecycleObject $Context "evidence/$hash.json" $bytes $hash -Confirm:$false
                        $journal.web.status = 'Verified'; $journal.web.evidenceSha256 = $hash
                        Save-AwsDeliveryJournal $Context $journal -Confirm:$false
                        $details.evidenceSha256 = $hash; $details.filesVerified = $serving.filesVerified; $details.workloadsHealthy = $backend.Count
                    }
                    $details.deploymentSha256 = $payload.deploymentSha256
                }
                { $_ -cin @('PrepareAcceptance', 'Acceptance') } {
                    if (-not $journal.activated -or -not $journal.ContainsKey('web') -or $journal.web.status -cne 'Verified' -or
                        $journal.web.hostingInputsSha256 -cne (Get-SnapshotHash $hosting.inputs)) { throw 'lifecycle.acceptance.servingRequired' }
                    $fixture = Get-AcceptanceFixture $Context.inventory $hosting.inputs
                    $contracts = Get-AcceptanceContracts $Release
                    $target = Get-AwsWebTarget $Context $hosting
                    $payload = New-AwsWebPayload $Context $Delivery $Release $hosting $DeliverySha256
                    if ($payload.deploymentSha256 -cne $journal.web.deploymentSha256) { throw 'lifecycle.acceptance.deploymentChanged' }
                    $renew = (Get-Command Assert-AwsLifecycleLease).ScriptBlock; $heartbeat = { & $renew $Context -Confirm:$false }.GetNewClosure()
                    Test-StaticWebServing $payload $target.origin $heartbeat | Out-Null
                    Get-AwsBackendHealth $Context $hosting | Out-Null
                    if ($Stage -ceq 'PrepareAcceptance') {
                        $consent = New-AcceptanceConsent $Context.inventory $DeliverySha256 $payload.deploymentSha256
                        if (-not ((ConvertTo-Json -InputObject $consent -Depth 20) | Test-Json -SchemaFile (Join-Path $PSScriptRoot '../contracts/schemas/acceptance-cleanup-consent-v1.schema.json') -ErrorAction SilentlyContinue)) { throw 'lifecycle.acceptance.consentInvalid' }
                        $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-PlatformBootstrapJson $consent)); $hash = Get-AwsLifecycleBytesHash $bytes
                        Publish-AwsLifecycleObject $Context "consents/$hash.json" $bytes $hash -Confirm:$false
                        $details.reviewSha256 = $hash
                    }
                    else {
                        if ($ReviewSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'lifecycle.acceptance.consentRequired' }
                        $bytes = Read-AwsLifecycleObject $Context "consents/$ReviewSha256.json" $ReviewSha256
                        if ($bytes.Length -gt 4MB) { throw 'lifecycle.acceptance.consentInvalid' }
                        $consent = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -AsHashtable -Depth 20
                        Assert-AcceptanceConsent $Context.inventory $consent $DeliverySha256 $payload.deploymentSha256 $Confirmation
                        $configuration = @{ apiVersion = 'hexagon.ec/browser-acceptance/v1'; instanceId = $fixture.instanceId; subjectId = $fixture.subjectId
                            tenant = $fixture.tenant; otherTenant = $fixture.otherTenant; origin = $target.origin; apiUrl = $hosting.outputs.api_url
                            authentication = $hosting.outputs.frontend_authentication; backend = $contracts.backend; web = $contracts.web }
                        $order = (Get-Command Assert-AwsDeliveryTaskOrder).ScriptBlock; $runTask = (Get-Command Invoke-AwsDeliveryTask).ScriptBlock
                        $seed = { & $order $journal $hosting acceptance-seed; & $runTask $Context $journal $hosting acceptance-seed | Out-Null }.GetNewClosure()
                        $save = (Get-Command Save-AwsDeliveryJournal).ScriptBlock
                        $persist = { & $save $Context $journal -Confirm:$false }.GetNewClosure()
                        $browserCommand = Get-Command Invoke-AwsBrowserAcceptance; $cleanupCommand = Get-Command Invoke-AwsAcceptanceCleanup; $evidenceCommand = Get-Command Save-AwsAcceptanceEvidence
                        $browser = { param($context, $value) & $browserCommand $context $value -Confirm:$false }.GetNewClosure()
                        $cleanup = { param($context, $value, $directory) & $cleanupCommand $context $value $directory -Confirm:$false }.GetNewClosure()
                        $persistEvidence = { param($context, $value) & $evidenceCommand $context $value -Confirm:$false }.GetNewClosure()
                        $details = Invoke-AcceptanceRun $Context $journal $consent $ReviewSha256 $configuration $Workspace $seed $persist -Browser $browser -Cleanup $cleanup -PersistEvidence $persistEvidence -Confirm:$false
                    }
                }
            }
        }
    }
    return @{ status = $(if ($Stage.StartsWith('Prepare', [StringComparison]::Ordinal)) { 'Prepared' } else { 'Completed' }); applicationVerified = $false; details = $details }
}

Export-ModuleMember -Function Read-AwsDeliveryJournal, Save-AwsDeliveryJournal, Assert-AwsDeliveryJournal, Get-AwsDeliveryHosting, Get-AwsDeliveryMaintenanceHash, Get-AwsDeliveryTaskSpec, Assert-AwsDeliveryTaskOrder, Assert-AwsDeliveryTasksComplete, Add-AwsMessagingBindings, Get-AwsDeliveryBoundInputs, Invoke-AwsApplicationStage
