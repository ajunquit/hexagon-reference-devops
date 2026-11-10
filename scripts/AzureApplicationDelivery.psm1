Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
foreach ($name in @('PlatformBootstrap', 'EnvironmentLifecycle', 'EnvironmentSnapshot', 'AzureEnvironmentStore', 'TerraformAzureLifecycle', 'AzureLifecycleInputs', 'ApplicationArtifacts', 'AzureOciDelivery', 'AzureMaintenanceDelivery', 'AzureWebDelivery', 'StaticWebPublication', 'AzureAcceptance', 'AcceptanceCleanup', 'AcceptanceRun')) {
    Import-Module (Join-Path $PSScriptRoot "$name.psm1")
}

function Assert-AzureDeliveryJournal([hashtable] $Context, [hashtable] $Journal, [string] $DeliverySha256) {
    $json = ConvertTo-Json -InputObject $Journal -Depth 24
    $inventory = $Context.inventory
    if (-not ($json | Test-Json -SchemaFile (Join-Path $PSScriptRoot '../contracts/schemas/application-delivery-journal-v1.schema.json') -ErrorAction SilentlyContinue) -or
        $Journal.product -cne $inventory.product -or $Journal.environment -cne $inventory.environment -or $Journal.instanceId -cne $inventory.instance.id -or
        $Journal.releaseSha256 -cne $inventory.releaseSha256 -or $Journal.deliverySha256 -cne $DeliverySha256 -or $Journal.iacCommit -cne $inventory.iac.commit -or
        $Journal.targetSha256 -cne (Get-SnapshotHash $inventory.target)) { throw 'lifecycle.delivery.journalInvalid' }
    foreach ($record in $Journal.jobs.Values) {
        if ($record.status -cne 'Starting' -and -not $record.executionId) { throw 'lifecycle.delivery.journalInvalid' }
    }
    if ($Journal.ContainsKey('web') -and (($Journal.web.status -ceq 'Verified') -ne ($null -ne $Journal.web.evidenceSha256))) { throw 'lifecycle.delivery.journalInvalid' }
    if ($Journal.ContainsKey('acceptance') -and $Journal.acceptance.status -ceq 'Completed' -and
        (-not $Journal.acceptance.journeySucceeded -or $Journal.acceptance.cleanupStatus -cne 'Destroyed' -or $null -eq $Journal.acceptance.evidenceSha256)) { throw 'lifecycle.acceptance.journalInvalid' }
}

function Read-AzureDeliveryJournal([hashtable] $Context, [string] $DeliverySha256) {
    Assert-AzureLifecycleLease $Context
    $uri = "https://$($Context.inventory.target.storageAccount).blob.core.windows.net/$($Context.inventory.target.container)/$($Context.prefix)/delivery.json"
    $response = Invoke-AzureLifecycleHttp $Context GET $uri
    $Context.deliveryEtag = $null; $Context.deliveryRevision = -1L
    if ($response.status -eq 404) {
        return @{ apiVersion = 'hexagon.ec/application-delivery-journal/v1'; product = $Context.inventory.product; environment = $Context.inventory.environment; instanceId = $Context.inventory.instance.id
            releaseSha256 = $Context.inventory.releaseSha256; deliverySha256 = $DeliverySha256; targetSha256 = Get-SnapshotHash $Context.inventory.target; iacCommit = $Context.inventory.iac.commit
            revision = -1L; images = @{}; jobs = @{}; maintenanceSha256 = $null; plan = $null; activated = $false }
    }
    if ($response.status -ne 200 -or $response.bytes.Length -gt 1MB -or -not $response.headers.ContainsKey('ETag')) { throw 'lifecycle.delivery.journalUnavailable' }
    $journal = [Text.Encoding]::UTF8.GetString($response.bytes) | ConvertFrom-Json -AsHashtable -Depth 24
    Assert-AzureDeliveryJournal $Context $journal $DeliverySha256
    $Context.deliveryEtag = $response.headers.ETag; $Context.deliveryRevision = $journal.revision
    return $journal
}

function Save-AzureDeliveryJournal {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([hashtable] $Context, [hashtable] $Journal)
    if (-not $PSCmdlet.ShouldProcess($Context.prefix, 'Persist application delivery checkpoint')) { return }
    Assert-AzureLifecycleLease $Context
    if ($Journal.revision -ne $Context.deliveryRevision) { throw 'lifecycle.delivery.journalRevisionMismatch' }
    $Journal.revision++
    Assert-AzureDeliveryJournal $Context $Journal $Journal.deliverySha256
    $uri = "https://$($Context.inventory.target.storageAccount).blob.core.windows.net/$($Context.inventory.target.container)/$($Context.prefix)/delivery.json"
    $headers = @{ 'x-ms-blob-type' = 'BlockBlob' }
    if ($Context.deliveryEtag) { $headers['If-Match'] = $Context.deliveryEtag } else { $headers['If-None-Match'] = '*' }
    $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-PlatformBootstrapJson $Journal) + "`n")
    $write = Invoke-AzureLifecycleHttp $Context PUT $uri $headers $bytes
    if ($write.status -ne 201) { throw 'lifecycle.delivery.journalConflict' }
    $read = Read-AzureDeliveryJournal $Context $Journal.deliverySha256
    $observed = [Text.Encoding]::UTF8.GetBytes((ConvertTo-PlatformBootstrapJson $read) + "`n")
    if ((Get-LifecycleBytesHash $observed) -cne (Get-LifecycleBytesHash $bytes)) { throw 'lifecycle.delivery.journalNotDurable' }
}

function Get-AzureDeliveryInputs([hashtable] $Context) {
    return [Text.Encoding]::UTF8.GetString($Context.snapshot.files['inputs/hosting.tfvars.json']) | ConvertFrom-Json -AsHashtable -Depth 40
}

function Get-AzureDeliveryReferences([hashtable] $Release, [string] $Registry) {
    $references = @{}
    foreach ($id in $Release.artifacts.backend.Keys) {
        if ($id -ceq 'database-bootstrap') { throw 'lifecycle.delivery.reservedWorkloadId' }
        $references[$id] = Get-DeliveryImageTarget $Release.artifacts.backend[$id] $Registry
    }
    $references['database-bootstrap'] = Get-DeliveryImageTarget $Release.artifacts.databaseBootstrap.image $Registry
    return $references
}

function Get-AzureDeliveryHosting([hashtable] $Context, [hashtable] $Release, [switch] $AllowPendingPlan) {
    $state = Get-AzureLifecycleDeploymentState $Context hosting -AllowPendingPlan:$AllowPendingPlan
    $inputs = Get-AzureDeliveryInputs $Context
    $registry = $state.outputs.registry
    $actual = @($state.resources | Where-Object { $_.type -ceq 'azurerm_container_registry' -and $_.id -ieq $registry.id })
    if ($actual.Count -ne 1 -or $registry.login_server -cne "$($inputs.registry_name).azurecr.io" -or
        $registry.id -ine "$($state.scopeId)/providers/Microsoft.ContainerRegistry/registries/$($inputs.registry_name)") { throw 'lifecycle.delivery.registryUnrecorded' }
    $response = Invoke-AzureLifecycleHttp $Context GET "https://management.azure.com$($registry.id)?api-version=2023-07-01"
    if ($response.status -ne 200) { throw 'lifecycle.delivery.registryUnavailable' }
    $arm = [Text.Encoding]::UTF8.GetString($response.bytes) | ConvertFrom-Json -AsHashtable
    if ($arm.id -ine $registry.id -or $arm.properties.loginServer -cne $registry.login_server -or $arm.properties.adminUserEnabled -ne $false) { throw 'lifecycle.delivery.registryChanged' }
    $references = Get-AzureDeliveryReferences $Release $registry.login_server
    if ((@($inputs.workloads.Keys | Sort-Object) -join ',') -cne (@($Release.artifacts.backend.Keys | Sort-Object) -join ',')) { throw 'lifecycle.delivery.workloadsMismatch' }
    foreach ($id in $inputs.workloads.Keys) {
        if ($inputs.workloads[$id].image -cne $references[$id].image) { throw 'lifecycle.delivery.hostingImageMismatch' }
    }
    if ($inputs.bootstrap_image -cne $references['database-bootstrap'].image) { throw 'lifecycle.delivery.hostingImageMismatch' }
    return @{ state = $state; inputs = $inputs; registry = $registry; references = $references }
}

function Assert-AzureDeliveryImages([hashtable] $Journal, [hashtable] $Hosting) {
    if ((@($Journal.images.Keys | Sort-Object) -join ',') -cne (@($Hosting.references.Keys | Sort-Object) -join ',')) { throw 'lifecycle.delivery.imagesRequired' }
    foreach ($id in $Hosting.references.Keys) {
        if ($Journal.images[$id].image -cne $Hosting.references[$id].image -or $Journal.images[$id].digest -cne $Hosting.references[$id].digest) { throw 'lifecycle.delivery.imagesRequired' }
    }
}

function Get-AzureDeliveryBoundInputs([hashtable] $Context, [hashtable] $Inputs) {
    $messaging = Get-AzureLifecycleDeploymentState $Context messaging
    $value = (ConvertTo-PlatformBootstrapJson $Inputs) | ConvertFrom-Json -AsHashtable -Depth 40
    if ($messaging.outputs.workload_bindings -isnot [Collections.IDictionary]) { throw 'lifecycle.delivery.messagingBindingsUnavailable' }
    foreach ($id in $messaging.outputs.workload_bindings.Keys) {
        if (-not $value.workloads.ContainsKey($id)) { throw 'lifecycle.delivery.bindingWorkloadUnknown' }
        foreach ($key in $messaging.outputs.workload_bindings[$id].Keys) {
            $text = [string] $messaging.outputs.workload_bindings[$id][$key]
            if ($key -cnotmatch '^(ConnectionStrings__servicebus|Messaging__AzureServiceBus__(Destinations|Consumers)__[a-z0-9-]+__(Topic|Subscription))$' -or
                $text -cnotmatch '^[A-Za-z0-9._/-]+$' -or $value.workloads[$id].secret_references.ContainsKey($key)) { throw 'lifecycle.delivery.bindingInvalid' }
            if ($value.workloads[$id].environment.ContainsKey($key) -and $value.workloads[$id].environment[$key] -cne $text) { throw 'lifecycle.delivery.bindingConflict' }
            $value.workloads[$id].environment[$key] = $text
        }
    }
    return $value
}

function Get-AzureDeliveryMaintenanceHash([hashtable] $Context, [hashtable] $Inputs) {
    $value = @{} + $Inputs; $value.Remove('application_rollout_enabled')
    $messaging = @($Context.inventory.roots | Where-Object id -CEQ 'messaging')[0]
    if ($messaging.status -cne 'Verified') { throw 'lifecycle.delivery.messagingNotReady' }
    return Get-SnapshotHash @{ hosting = $value; iacCommit = $Context.inventory.iac.commit; messaging = @{ lineage = $messaging.stateLineage; serial = $messaging.stateSerial; inputsSha256 = $messaging.inputsSha256 } }
}

function Assert-AzureDeliveryMaintenance([hashtable] $Context, [hashtable] $Journal, [hashtable] $Hosting, [switch] $RequireJobs) {
    Assert-AzureDeliveryImages $Journal $Hosting
    if ($Hosting.inputs.maintenance_jobs_enabled -ne $true -or $Journal.maintenanceSha256 -cne (Get-AzureDeliveryMaintenanceHash $Context $Hosting.inputs)) { throw 'lifecycle.delivery.maintenanceEvidenceStale' }
    $bound = Get-AzureDeliveryBoundInputs $Context $Hosting.inputs
    if ((Get-SnapshotHash $bound) -cne (Get-SnapshotHash $Hosting.inputs)) { throw 'lifecycle.delivery.messagingNotBound' }
    if ($RequireJobs) {
        foreach ($id in @('migrations', 'database-access')) {
            if (-not $Journal.jobs.ContainsKey($id) -or $Journal.jobs[$id].status -cne 'Succeeded') { throw 'lifecycle.delivery.successfulJobsRequired' }
        }
    }
}

function Get-AzureDeliveryJobSpec([hashtable] $Context, [hashtable] $Hosting, [string] $Job) {
    $outputs = $Hosting.state.outputs; $inputs = $Hosting.inputs
    if (-not $outputs.maintenance_jobs.ContainsKey($Job)) { throw 'lifecycle.delivery.maintenanceJobMissing' }
    $jobId = $outputs.maintenance_jobs[$Job].id
    if (@($Hosting.state.resources | Where-Object { $_.type -ceq 'azurerm_container_app_job' -and $_.id -ieq $jobId }).Count -ne 1 -or
        $jobId -cnotmatch '^/subscriptions/[0-9a-f-]{36}/resourceGroups/[A-Za-z0-9._-]+/providers/Microsoft[.]App/jobs/[a-z0-9-]+$') { throw 'lifecycle.delivery.maintenanceJobUnrecorded' }
    $response = Invoke-AzureLifecycleHttp $Context GET "https://management.azure.com${jobId}?api-version=2024-03-01"
    if ($response.status -ne 200) { throw 'lifecycle.delivery.maintenanceJobUnavailable' }
    $actual = [Text.Encoding]::UTF8.GetString($response.bytes) | ConvertFrom-Json -AsHashtable -Depth 40
    $identities = @($actual.identity.userAssignedIdentities.Keys)
    if ($actual.identity.type -cne 'UserAssigned' -or $identities.Count -ne 1 -or
        @($Hosting.state.resources | Where-Object { $_.type -ceq 'azurerm_user_assigned_identity' -and $_.id -ieq $identities[0] }).Count -ne 1) { throw 'lifecycle.delivery.maintenanceIdentityInvalid' }
    $identity = Invoke-AzureLifecycleHttp $Context GET "https://management.azure.com$($identities[0])?api-version=2023-01-31"
    if ($identity.status -ne 200 -or ([Text.Encoding]::UTF8.GetString($identity.bytes) | ConvertFrom-Json).properties.clientId -ine $outputs.database_bootstrap.clientId) { throw 'lifecycle.delivery.maintenanceIdentityInvalid' }
    $environment = $(if ($Job -cin @('migrations', 'acceptance-seed')) {
        @{ ASPNETCORE_ENVIRONMENT = 'Production'; AZURE_CLIENT_ID = $outputs.database_bootstrap.clientId
            "ConnectionStrings__$($inputs.database_connection_name)" = "Host=$($outputs.database_bootstrap.host);Database=$($outputs.database_bootstrap.database);Username=$($outputs.database_bootstrap.administrator);SSL Mode=VerifyFull"
            Auth__Authority = $inputs.auth.authority; Auth__Audience = $inputs.auth.audience; Auth__ApiScope = $inputs.auth.api_scope }
    } else { @{ HEXAGON_DATABASE_BOOTSTRAP = ConvertTo-Json -InputObject $outputs.database_bootstrap -Depth 20 -Compress } })
    if ($Job -ceq 'acceptance-seed') {
        $fixture = Get-AcceptanceFixture $Context.inventory $inputs
        $embedded = @($actual.properties.template.containers[0].env | Where-Object name -CEQ 'HEXAGON_ACCEPTANCE_SEED')
        if ($embedded.Count -ne 1 -or (Get-SnapshotHash ($embedded[0].value | ConvertFrom-Json -AsHashtable)) -cne (Get-SnapshotHash $fixture)) { throw 'lifecycle.acceptance.fixtureChanged' }
        $environment.HEXAGON_ACCEPTANCE_SEED = $embedded[0].value
    }
    if ($Job -ceq 'database-access') {
        # Compare the embedded JSON semantically with Terraform jsonencode, then use the exact ARM bytes.
        $embedded = @($actual.properties.template.containers[0].env | Where-Object name -CEQ 'HEXAGON_DATABASE_BOOTSTRAP')
        if ($embedded.Count -ne 1 -or (Get-SnapshotHash ($embedded[0].value | ConvertFrom-Json -AsHashtable -Depth 20)) -cne (Get-SnapshotHash $outputs.database_bootstrap)) { throw 'lifecycle.delivery.databaseBindingsChanged' }
        $environment.HEXAGON_DATABASE_BOOTSTRAP = $embedded[0].value
    }
    $expected = @{ name = 'maintenance'; image = $(if ($Job -cin @('migrations', 'acceptance-seed')) { $inputs.workloads[$inputs.migration_workload].image } else { $inputs.bootstrap_image })
        args = @($(if ($Job -ceq 'migrations') { @('--migrate-only') } elseif ($Job -ceq 'acceptance-seed') { @('--seed-acceptance-only') } else { @() })); environment = $environment; cpu = 0.5; memory = '1Gi' }
    return @{ id = $jobId; expected = $expected }
}

function Invoke-AzureDeliveryJob([hashtable] $Context, [hashtable] $Journal, [hashtable] $Hosting, [string] $Job) {
    $spec = Get-AzureDeliveryJobSpec $Context $Hosting $Job
    $record = $(if ($Journal.jobs.ContainsKey($Job)) { $Journal.jobs[$Job] } else { $null })
    $save = (Get-Command Save-AzureDeliveryJournal).ScriptBlock
    $persist = { param($value) $Journal.jobs[$Job] = $value; & $save $Context $Journal -Confirm:$false }.GetNewClosure()
    return Invoke-AzureDeliveryMaintenance $Context $spec.id $spec.expected $record $persist -Confirm:$false
}

function Set-AzureDeliveryInputs([hashtable] $Context, [hashtable] $Value, [string] $Repository, [string] $TrustedCommit, [string] $Workspace) {
    $directory = Join-Path $Context.runtime "inputs-$([guid]::NewGuid().ToString('N'))"
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    foreach ($root in $Context.inventory.roots) {
        $bytes = $(if ($root.id -ceq 'hosting') { [Text.Encoding]::UTF8.GetBytes((ConvertTo-PlatformBootstrapJson $Value) + "`n") } else { $Context.snapshot.files["inputs/$($root.id).tfvars.json"] })
        [IO.File]::WriteAllBytes((Join-Path $directory "$($root.id).tfvars.json"), $bytes)
    }
    Update-AzureLifecycleInputs -Context $Context -RootId hosting -InputDirectory $directory -Repository $Repository -TrustedCommit $TrustedCommit -InventoryPath (Join-Path $Workspace 'inventory.json') -Archive (Join-Path $Workspace 'snapshot.zip') -AllowUnchanged -Confirm:$false
}

function New-AzureDeliveryPlan([hashtable] $Context, [hashtable] $Journal, [string] $Purpose, [string] $Workspace) {
    $path = Join-Path $Workspace 'inventory.json'
    $root = @($Context.inventory.roots | Where-Object id -CEQ 'hosting')[0]
    $plan = New-AzureLifecyclePlan $Context $root Create -Confirm:$false
    $hash = Add-EnvironmentRootPlan -InventoryPath $path -RootId hosting -Operation Create -BinaryPath $plan.binaryPath -JsonPath $plan.jsonPath -ExpectedInventorySha256 (Get-LifecycleFileHash $path) -Confirm:$false
    Publish-AzureLifecycleObject $Context "$($Context.prefix)/plans/$hash/hosting.tfplan" ([IO.File]::ReadAllBytes($plan.binaryPath)) (Get-LifecycleFileHash $plan.binaryPath)
    Publish-AzureLifecycleObject $Context "$($Context.prefix)/plans/$hash/hosting.json" ([IO.File]::ReadAllBytes($plan.jsonPath)) (Get-LifecycleFileHash $plan.jsonPath)
    Save-AzureLifecycleJournal $Context $path | Out-Null
    $Context.inventory = Read-EnvironmentInventory $path
    $Journal.plan = @{ purpose = $Purpose; reviewSha256 = $hash }
    Save-AzureDeliveryJournal $Context $Journal -Confirm:$false
    return $hash
}

function Invoke-AzureDeliveryPlan([hashtable] $Context, [hashtable] $Journal, [string] $Purpose, [string] $ReviewSha256, [string] $Confirmation, [string] $Workspace) {
    $root = @($Context.inventory.roots | Where-Object id -CEQ 'hosting')[0]
    if ($null -eq $Journal.plan -or $Journal.plan.purpose -cne $Purpose -or $Journal.plan.reviewSha256 -cne $ReviewSha256 -or
        $null -eq $root.plan -or $root.plan.reviewSha256 -cne $ReviewSha256 -or $ReviewSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'lifecycle.delivery.reviewRequired' }
    $binary = Join-Path $Context.runtime 'hosting.tfplan'
    [IO.File]::WriteAllBytes($binary, (Read-AzureLifecycleObject $Context "$($Context.prefix)/plans/$ReviewSha256/hosting.tfplan" $root.plan.binarySha256))
    [IO.File]::WriteAllBytes("$binary.json", (Read-AzureLifecycleObject $Context "$($Context.prefix)/plans/$ReviewSha256/hosting.json" $root.plan.jsonSha256))
    $path = Join-Path $Workspace 'inventory.json'
    $result = Invoke-EnvironmentRootOperation -InventoryPath $path -RootId hosting -BinaryPath $binary -JsonPath "$binary.json" -ReviewSha256 $ReviewSha256 -Confirmation $Confirmation -Port (New-AzureLifecyclePort $Context) -Confirm:$false
    $Context.inventory = Read-EnvironmentInventory $path
    if ($result.status -cne 'Verified') { throw 'lifecycle.delivery.infrastructureNotConverged' }
    $Journal.plan = $null
    if ($Purpose -ceq 'Activation') { $Journal.activated = $true }
    Save-AzureDeliveryJournal $Context $Journal -Confirm:$false
}

function Invoke-AzureApplicationStage {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([hashtable] $Context, [hashtable] $Delivery, [hashtable] $Release, [string] $DeliverySha256,
        [ValidateSet('Artifacts', 'PrepareMaintenance', 'ApplyMaintenance', 'Migrations', 'DatabaseAccess', 'PrepareActivation', 'ApplyActivation', 'PublishWeb', 'VerifyServing', 'PrepareAcceptance', 'Acceptance')][string] $Stage,
        [string] $Repository, [string] $TrustedCommit, [string] $Workspace, [string] $ReviewSha256, [string] $Confirmation)
    if (-not $PSCmdlet.ShouldProcess($Context.prefix, "Run application delivery stage $Stage")) { return @{ status = 'Unverified'; applicationVerified = $false; details = @{} } }
    Assert-AzureLifecycleRuntime $Context
    Assert-ApplicationDelivery $Delivery $Context.inventory.releaseSha256
    $journal = Read-AzureDeliveryJournal $Context $DeliverySha256
    if ($Stage -ceq 'VerifyServing' -and $journal.ContainsKey('web') -and $journal.web.status -ceq 'Verified') {
        $journal.web.status = 'Published'; $journal.web.evidenceSha256 = $null
        Save-AzureDeliveryJournal $Context $journal -Confirm:$false
    }
    $hosting = Get-AzureDeliveryHosting $Context $Release -AllowPendingPlan:($Stage -cin @('PrepareMaintenance', 'ApplyMaintenance', 'PrepareActivation', 'ApplyActivation'))
    $details = @{}
    if ($Stage -ceq 'Artifacts') {
        if ($hosting.inputs.application_rollout_enabled -or $journal.activated) { throw 'lifecycle.delivery.alreadyActivated' }
        $renew = (Get-Command Assert-AzureLifecycleLease).ScriptBlock
        $heartbeat = { & $renew $Context }.GetNewClosure()
        $candidates = Receive-ApplicationCandidates $Delivery $Release $hosting.registry.login_server (Join-Path $Context.runtime 'candidates') $heartbeat -Confirm:$false
        Save-AzureDeliveryJournal $Context $journal -Confirm:$false
        foreach ($component in @('backend', 'devops')) {
            foreach ($id in $candidates[$component].images.Keys) {
                $journal.images[$id] = Publish-AzureOciArchive $Context $candidates[$component].images[$id] $hosting.registry.login_server -Confirm:$false
                Save-AzureDeliveryJournal $Context $journal -Confirm:$false
            }
        }
        Assert-AzureDeliveryImages $journal $hosting
        $details.images = $journal.images.Count; $details.webArchiveSha256 = $Release.artifacts.web.sha256
    }
    elseif ($Stage -ceq 'PrepareMaintenance') {
        Assert-AzureDeliveryImages $journal $hosting
        Assert-AzureOciImages $Context $hosting.references $hosting.registry.login_server
        if ($hosting.inputs.application_rollout_enabled -or $journal.activated -or $journal.jobs.Count -gt 0) { throw 'lifecycle.delivery.maintenanceAlreadyStarted' }
        $inputs = Get-AzureDeliveryBoundInputs $Context $hosting.inputs
        $inputs.maintenance_jobs_enabled = $true; $inputs.application_rollout_enabled = $false
        $journal.maintenanceSha256 = Get-AzureDeliveryMaintenanceHash $Context $inputs
        Save-AzureDeliveryJournal $Context $journal -Confirm:$false
        Set-AzureDeliveryInputs $Context $inputs $Repository $TrustedCommit $Workspace
        $details.reviewSha256 = New-AzureDeliveryPlan $Context $journal Maintenance $Workspace
    }
    else {
        Assert-AzureDeliveryMaintenance $Context $journal $hosting -RequireJobs:($Stage -cin @('PrepareActivation', 'ApplyActivation', 'PublishWeb', 'VerifyServing', 'PrepareAcceptance', 'Acceptance'))
        Assert-AzureOciImages $Context $hosting.references $hosting.registry.login_server
        if ($Stage -cin @('Migrations', 'DatabaseAccess', 'ApplyMaintenance') -and $hosting.inputs.application_rollout_enabled) { throw 'lifecycle.delivery.activationOrderInvalid' }
        switch ($Stage) {
            'ApplyMaintenance' { Invoke-AzureDeliveryPlan $Context $journal Maintenance $ReviewSha256 $Confirmation $Workspace }
            'Migrations' { Invoke-AzureDeliveryJob $Context $journal $hosting migrations | Out-Null }
            'DatabaseAccess' {
                if (-not $journal.jobs.ContainsKey('migrations') -or $journal.jobs.migrations.status -cne 'Succeeded') { throw 'lifecycle.delivery.migrationsRequired' }
                Invoke-AzureDeliveryJob $Context $journal $hosting migrations | Out-Null
                Invoke-AzureDeliveryJob $Context $journal $hosting database-access | Out-Null
            }
            { $_ -cin @('PrepareActivation', 'ApplyActivation') } {
                foreach ($job in @('migrations', 'database-access')) { Invoke-AzureDeliveryJob $Context $journal $hosting $job | Out-Null }
                if ($Stage -ceq 'PrepareActivation') {
                    $inputs = @{} + $hosting.inputs; $inputs.application_rollout_enabled = $true
                    Set-AzureDeliveryInputs $Context $inputs $Repository $TrustedCommit $Workspace
                    $details.reviewSha256 = New-AzureDeliveryPlan $Context $journal Activation $Workspace
                }
                else {
                    if ($hosting.inputs.application_rollout_enabled -ne $true) { throw 'lifecycle.delivery.activationInputsRequired' }
                    Invoke-AzureDeliveryPlan $Context $journal Activation $ReviewSha256 $Confirmation $Workspace
                }
            }
            { $_ -cin @('PrepareAcceptance', 'Acceptance') } {
                if (-not $journal.activated -or -not $journal.ContainsKey('web') -or $journal.web.status -cne 'Verified' -or
                    $journal.web.hostingInputsSha256 -cne (Get-SnapshotHash $hosting.inputs)) { throw 'lifecycle.acceptance.servingRequired' }
                $fixture = Get-AcceptanceFixture $Context.inventory $hosting.inputs
                $contracts = Get-AcceptanceContracts $Release
                $target = Get-AzureWebTarget $Context $hosting
                $payload = New-AzureWebPayload $Context $Delivery $Release $hosting $DeliverySha256 -Confirm:$false
                if ($payload.deploymentSha256 -cne $journal.web.deploymentSha256) { throw 'lifecycle.acceptance.deploymentChanged' }
                $renew = (Get-Command Assert-AzureLifecycleLease).ScriptBlock; $heartbeat = { & $renew $Context }.GetNewClosure()
                Test-StaticWebServing $payload $target.origin $heartbeat | Out-Null
                Get-AzureBackendHealth $Context $hosting | Out-Null
                if ($Stage -ceq 'PrepareAcceptance') {
                    $consent = New-AcceptanceConsent $Context.inventory $DeliverySha256 $payload.deploymentSha256
                    if (-not ((ConvertTo-Json -InputObject $consent -Depth 20) | Test-Json -SchemaFile (Join-Path $PSScriptRoot '../contracts/schemas/acceptance-cleanup-consent-v1.schema.json') -ErrorAction SilentlyContinue)) { throw 'lifecycle.acceptance.consentInvalid' }
                    $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-PlatformBootstrapJson $consent)); $hash = Get-LifecycleBytesHash $bytes
                    Publish-AzureLifecycleObject $Context "$($Context.prefix)/consents/$hash.json" $bytes $hash -Confirm:$false
                    $details.reviewSha256 = $hash
                }
                else {
                    if ($ReviewSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'lifecycle.acceptance.consentRequired' }
                    $bytes = Read-AzureLifecycleObject $Context "$($Context.prefix)/consents/$ReviewSha256.json" $ReviewSha256
                    if ($bytes.Length -gt 4MB) { throw 'lifecycle.acceptance.consentInvalid' }
                    $consent = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -AsHashtable -Depth 20
                    Assert-AcceptanceConsent $Context.inventory $consent $DeliverySha256 $payload.deploymentSha256 $Confirmation
                    $configuration = @{ apiVersion = 'hexagon.ec/browser-acceptance/v1'; instanceId = $fixture.instanceId; subjectId = $fixture.subjectId
                        tenant = $fixture.tenant; otherTenant = $fixture.otherTenant; origin = $target.origin; apiUrl = $hosting.state.outputs.api_url
                        authentication = $hosting.state.outputs.frontend_authentication; backend = $contracts.backend; web = $contracts.web }
                    $invokeJob = (Get-Command Invoke-AzureDeliveryJob).ScriptBlock
                    $seed = { & $invokeJob $Context $journal $hosting acceptance-seed | Out-Null }.GetNewClosure()
                    $save = (Get-Command Save-AzureDeliveryJournal).ScriptBlock
                    $persist = { & $save $Context $journal -Confirm:$false }.GetNewClosure()
                    $details = Invoke-AcceptanceRun $Context $journal $consent $ReviewSha256 $configuration $Workspace $seed $persist -Confirm:$false
                }
            }
            { $_ -cin @('PublishWeb', 'VerifyServing') } {
                if (-not $journal.activated -or $hosting.inputs.application_rollout_enabled -ne $true) { throw 'lifecycle.web.activationRequired' }
                $target = Get-AzureWebTarget $Context $hosting
                if ($Stage -ceq 'PublishWeb') { Get-AzureBackendHealth $Context $hosting | Out-Null }
                $payload = New-AzureWebPayload $Context $Delivery $Release $hosting $DeliverySha256
                $inputsSha256 = Get-SnapshotHash $hosting.inputs
                if ($Stage -ceq 'PublishWeb') {
                    $journal.web = @{ status = 'Publishing'; deploymentSha256 = $payload.deploymentSha256; archiveSha256 = $payload.identity.archiveSha256
                        overlaySha256 = $payload.identity.overlaySha256; hostingInputsSha256 = $inputsSha256; evidenceSha256 = $null }
                    Save-AzureDeliveryJournal $Context $journal -Confirm:$false
                    Publish-AzureWebPayload $Context $target $payload -Confirm:$false
                    $journal.web.status = 'Published'
                    Save-AzureDeliveryJournal $Context $journal -Confirm:$false
                }
                else {
                    if (-not $journal.ContainsKey('web') -or $journal.web.deploymentSha256 -cne $payload.deploymentSha256 -or $journal.web.hostingInputsSha256 -cne $inputsSha256) { throw 'lifecycle.web.publicationEvidenceRequired' }
                    $renew = (Get-Command Assert-AzureLifecycleLease).ScriptBlock; $heartbeat = { & $renew $Context }.GetNewClosure()
                    $serving = Test-StaticWebServing $payload $target.origin $heartbeat
                    $backend = Get-AzureBackendHealth $Context $hosting
                    $current = Get-AzureLifecycleDeploymentState $Context hosting
                    if ($current.etag -cne $hosting.state.etag) { throw 'lifecycle.web.stateChangedDuringVerification' }
                    $evidence = @{ apiVersion = 'hexagon.ec/serving-evidence/v1'; product = $Context.inventory.product; environment = $Context.inventory.environment; instanceId = $Context.inventory.instance.id
                        releaseSha256 = $Context.inventory.releaseSha256; deliverySha256 = $DeliverySha256; observedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); hostingInputsSha256 = $inputsSha256
                        backend = $backend; web = $serving; applicationVerified = $false }
                    $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-PlatformBootstrapJson $evidence)); $hash = Get-LifecycleBytesHash $bytes
                    Publish-AzureLifecycleObject $Context "$($Context.prefix)/evidence/$hash.json" $bytes $hash -Confirm:$false
                    $journal.web.status = 'Verified'; $journal.web.evidenceSha256 = $hash
                    Save-AzureDeliveryJournal $Context $journal -Confirm:$false
                    $details.evidenceSha256 = $hash; $details.filesVerified = $serving.filesVerified; $details.workloadsHealthy = $backend.Count
                }
                $details.deploymentSha256 = $payload.deploymentSha256
            }
        }
    }
    return @{ status = $(if ($Stage.StartsWith('Prepare', [StringComparison]::Ordinal)) { 'Prepared' } else { 'Completed' }); applicationVerified = $false; details = $details }
}

Export-ModuleMember -Function Read-AzureDeliveryJournal, Save-AzureDeliveryJournal, Assert-AzureDeliveryJournal, Get-AzureDeliveryMaintenanceHash, Assert-AzureDeliveryMaintenance, Get-AzureDeliveryBoundInputs, Invoke-AzureApplicationStage
