<#
.SYNOPSIS
    Exercises the AWS application delivery, first part (ADR 0025): ECR targets, the delivery journal, the
    maintenance task specification and order, and RunTask execution with reconciliation. Doubles only.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repository 'scripts/AwsApplicationDelivery.psm1') -Force
foreach ($name in @('AwsEnvironmentStore', 'AwsMaintenanceDelivery', 'AwsOciDelivery', 'ApplicationArtifacts', 'PlatformBootstrap', 'EnvironmentSnapshot')) { Import-Module (Join-Path $repository "scripts/$name.psm1") }
$script:assertions = 0
function Assert-True([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message }; $script:assertions++ }
function Assert-Rejected([scriptblock] $Action, [string] $Code) {
    try { & $Action | Out-Null }
    catch { Assert-True ($_.Exception.Message -like "*$Code*") "Unexpected rejection: $($_.Exception.Message)"; return }
    throw "Expected rejection: $Code"
}
function Copy-Value([object] $Value) { return (ConvertTo-PlatformBootstrapJson $Value) | ConvertFrom-Json -AsHashtable -Depth 64 }
$inventory = Get-Content -Raw -LiteralPath (Join-Path $repository 'examples/environment-inventory-aws.json') | ConvertFrom-Json -AsHashtable -Depth 32
$prefix = $inventory.roots[0].namePrefix
$server = '123456789012.dkr.ecr.us-east-1.amazonaws.com'
$digest = 'sha256:' + ('d' * 64)

# ECR targets keep the digest under <server>/<short prefix>/<artifact>; ACR is unchanged.
$target = Get-DeliveryImageTarget "ghcr.io/example/hexagon-example-api@$digest" "$server/$prefix"
Assert-True ($target.image -ceq "$server/$prefix/hexagon-example-api@$digest" -and $target.repository -ceq "$prefix/hexagon-example-api") 'ECR target.'
Assert-True ((Get-DeliveryImageTarget "ghcr.io/example/hexagon-example-api@$digest" 'exampledev0001.azurecr.io').image -ceq "exampledev0001.azurecr.io/example/hexagon-example-api@$digest") 'ACR target unchanged.'
Assert-Rejected { Get-DeliveryImageTarget "ghcr.io/example/api:latest" "$server/$prefix" } 'lifecycle.delivery.imageReferenceInvalid'

# A context with an in-memory S3, an AWS CLI double and a registry double.
$script:objects = @{}
$s3 = {
    param($operation, $key, $bytes, $ifNoneMatch, $ifMatch)
    if ($operation -ceq 'Get') { if (-not $script:objects.ContainsKey($key)) { return @{ status = 404 } }; return @{ status = 200; bytes = $script:objects[$key].bytes; etag = $script:objects[$key].etag } }
    $exists = $script:objects.ContainsKey($key)
    if (($ifNoneMatch -and $exists) -or ($ifMatch -and (-not $exists -or $script:objects[$key].etag -cne $ifMatch))) { return @{ status = 412 } }
    $etag = '"' + [guid]::NewGuid().ToString('N') + '"'; $script:objects[$key] = @{ bytes = $bytes; etag = $etag }; return @{ status = 200; etag = $etag }
}
$ok = { param($value) @{ exitCode = 0; text = (ConvertTo-PlatformBootstrapJson $value); errorText = '' } }
$script:handlers = @{}; $script:calls = [Collections.Generic.List[string]]::new()
$cli = { param($arguments) $line = $arguments -join ' '; $script:calls.Add($line); foreach ($p in $script:handlers.Keys) { if ($line -like $p) { return & $script:handlers[$p] $line } }; throw "Unexpected AWS call: $line" }
$context = New-AwsLifecycleContext (Copy-Value $inventory) 'arn:aws:sts::123456789012:assumed-role/hexagon-template-dev-run-12345-1-deploy/GitHubActions' '123456789012' $s3
Enter-AwsLifecycleLease $context -Confirm:$false
$context.awsCli = $cli
$context.runtime = Join-Path ([IO.Path]::GetTempPath()) "hexagon-aws-delivery-$([guid]::NewGuid().ToString('N'))"

# Registry: Basic credentials from ECR; manifests must be present by digest.
$script:handlers['ecr get-login-password*'] = { param($line) @{ exitCode = 0; text = "secret-token`n"; errorText = '' } }
Assert-True ((Get-AwsRegistryAuthorization $context) -ceq ('Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes('AWS:secret-token')))) 'ECR Basic credentials.'
$script:present = $true
$context.registryHttp = { param($method, $registryServer, $path, $authorization) if ($script:present) { @{ status = 200; headers = @{ 'Docker-Content-Digest' = $digest } } } else { @{ status = 404; headers = @{} } } }
$references = @{ api = @{ repository = "$prefix/hexagon-example-api"; digest = $digest; image = "$server/$prefix/hexagon-example-api@$digest" } }
Assert-AwsOciImages $context $references $server; $script:assertions++
$script:present = $false
Assert-Rejected { Assert-AwsOciImages $context $references $server } 'lifecycle.delivery.imagesRequired'
$outside = @{ file = 'missing.tar'; sha256 = 'a' * 64; target = @{ repository = 'other-prefix/api'; digest = $digest; image = "$server/other-prefix/api@$digest" } }
Assert-Rejected { Publish-AwsOciArchive $context $outside $server -Confirm:$false } 'lifecycle.delivery.imageChanged'

# The journal: written with If-None-Match, then CAS on its ETag; ECR images and ECS jobs are valid.
$deliverySha = 'e' * 64
$journal = Read-AwsDeliveryJournal $context $deliverySha
$journal.images['hexagon-example-api'] = @{ image = "$server/$prefix/hexagon-example-api@$digest"; digest = $digest; archiveSha256 = 'f' * 64 }
Save-AwsDeliveryJournal $context $journal -Confirm:$false
$journal = Read-AwsDeliveryJournal $context $deliverySha
Assert-True ($journal.revision -eq 0 -and $journal.images.Count -eq 1) 'The journal must be durable in the S3 custody.'
$script:objects["hexagon-template/dev/run-12345-1/delivery.json"].etag = '"concurrent"'
Assert-Rejected { Save-AwsDeliveryJournal $context $journal -Confirm:$false } 'lifecycle.delivery.journalConflict'
$journal = Read-AwsDeliveryJournal $context $deliverySha

# The task order of ADR 0024.
$hosting = @{ inputs = @{ keycloak = $null } }
Assert-Rejected { Assert-AwsDeliveryTaskOrder $journal $hosting 'migrations' } 'lifecycle.delivery.previousTaskRequired'
Assert-Rejected { Assert-AwsDeliveryTaskOrder $journal $hosting 'keycloak-database' } 'lifecycle.identity.notIntegrated'
Assert-AwsDeliveryTaskOrder $journal $hosting 'database-credentials'; $script:assertions++

# The expected task is checked against the registered task definition.
$arn = "arn:aws:ecs:us-east-1:123456789012:task-definition/$prefix-database-credentials:3"
$bootstrap = @{ provider = 'aws'; host = 'db.example.rds.amazonaws.com'; port = 5432; database = 'hexagon_example' }
$bootstrapImage = "$server/$prefix/database-bootstrap@$digest"
$hosting = @{
    inputs = @{ bootstrap_image = $bootstrapImage; migration_workload = 'api'; workloads = @{ api = @{ image = "$server/$prefix/hexagon-example-api@$digest" } }; keycloak = $null }
    outputs = @{ maintenance_tasks = @{ 'database-credentials' = @{ arn = $arn } }; database_bootstrap = $bootstrap
        task_network = @{ cluster = $prefix; subnets = @('subnet-1', 'subnet-2'); security_groups = @('sg-1'); assign_public_ip = $true } }
    state = @{ resources = @() }
}
$script:definition = @{ taskDefinitionArn = $arn; status = 'ACTIVE'; containerDefinitions = @(@{ name = 'maintenance'; image = $bootstrapImage; command = @('--prepare-credentials')
            environment = @(@{ name = 'HEXAGON_DATABASE_BOOTSTRAP'; value = (ConvertTo-Json -InputObject $bootstrap -Compress) }) }) }
$script:handlers['ecs describe-task-definition*'] = { param($line) & $ok @{ taskDefinition = $script:definition } }
$expected = Get-AwsDeliveryTaskSpec $context $hosting 'database-credentials'
Assert-True ($expected.taskDefinitionArn -ceq $arn -and $expected.cluster -ceq $prefix -and ($expected.command -join ' ') -ceq '--prepare-credentials') 'Expected task specification.'
$script:definition.containerDefinitions[0].image = "$server/$prefix/other@$digest"
Assert-Rejected { Get-AwsDeliveryTaskSpec $context $hosting 'database-credentials' } 'lifecycle.delivery.maintenanceJobChanged'
$script:definition.containerDefinitions[0].image = $bootstrapImage
$script:definition.containerDefinitions[0].environment[0].value = '{"provider":"aws","host":"other"}'
Assert-Rejected { Get-AwsDeliveryTaskSpec $context $hosting 'database-credentials' } 'lifecycle.delivery.databaseBindingsChanged'
$hosting.outputs.maintenance_tasks['database-credentials'].arn = "arn:aws:ecs:us-east-1:123456789012:task-definition/other-database-credentials:3"
Assert-Rejected { Get-AwsDeliveryTaskSpec $context $hosting 'database-credentials' } 'lifecycle.delivery.maintenanceJobUnrecorded'

# RunTask: durable intent first, then the task by its attempt; success needs the essential container to exit 0.
$persisted = [Collections.Generic.List[string]]::new()
$persist = { param($record) $persisted.Add($record.status) }
$task = "arn:aws:ecs:us-east-1:123456789012:task/$prefix/" + ('a' * 32)
$script:attempt = $null; $script:polls = 0; $script:exit = 0
$script:handlers['ecs run-task*'] = { param($line) $script:attempt = ($line -split '--started-by ')[1].Split(' ')[0]; & $ok @{ tasks = @(@{ taskArn = $task }); failures = @() } }
$script:handlers['ecs describe-tasks*'] = { param($line) $script:polls++
    $status = $(if ($script:polls -lt 2) { 'RUNNING' } else { 'STOPPED' })
    & $ok @{ tasks = @(@{ taskArn = $task; taskDefinitionArn = $arn; startedBy = $script:attempt; clusterArn = "arn:aws:ecs:us-east-1:123456789012:cluster/$prefix"; lastStatus = $status
                stopCode = 'EssentialContainerExited'; containers = @(@{ name = 'maintenance'; exitCode = $script:exit }) }) } }
$spec = [ordered] @{ taskDefinitionArn = $arn; cluster = $prefix; subnets = @('subnet-1'); securityGroups = @('sg-1'); image = $bootstrapImage; command = @('--prepare-credentials') }
$record = Invoke-AwsDeliveryMaintenance $context 'database-credentials' $spec $null $persist 30 0 -Confirm:$false
Assert-True ($record.status -ceq 'Succeeded' -and $record.executionId -ceq $task -and ($persisted -join ',') -ceq 'Starting,Running,Succeeded') 'A task must be recorded before RunTask and succeed only on exit code 0.'
Assert-True ((Invoke-AwsDeliveryMaintenance $context 'database-credentials' $spec $record $persist -Confirm:$false).status -ceq 'Succeeded' -and @($script:calls | Where-Object { $_ -like 'ecs run-task*' }).Count -eq 1) 'A succeeded task is never run again.'
# A lost RunTask response is reconciled by --started-by, never repeated.
$script:calls.Clear(); $script:polls = 5
$lost = @{ jobId = $arn; attemptId = [guid]::NewGuid().ToString(); templateSha256 = (Get-AwsDeliveryTaskHash $spec); executionId = $null; status = 'Starting' }
$script:attempt = $lost.attemptId
$script:handlers['ecs list-tasks*'] = { param($line) if ($line -like '*RUNNING*') { & $ok @{ taskArns = @() } } else { & $ok @{ taskArns = @($task) } } }
$adopted = Invoke-AwsDeliveryMaintenance $context 'database-credentials' $spec $lost $persist 30 0 -Confirm:$false
Assert-True ($adopted.executionId -ceq $task -and $adopted.status -ceq 'Succeeded' -and @($script:calls | Where-Object { $_ -like 'ecs run-task*' }).Count -eq 0) 'A lost response must be adopted, not repeated.'
$script:handlers['ecs list-tasks*'] = { param($line) & $ok @{ taskArns = @($task) } }
$lost.executionId = $null; $lost.status = 'Starting'
Assert-Rejected { Invoke-AwsDeliveryMaintenance $context 'database-credentials' $spec $lost $persist 30 0 -Confirm:$false } 'lifecycle.delivery.executionAmbiguous'
# Failure stops the delivery; a stale record or another attempt is never trusted.
$script:exit = 1; $script:polls = 5
Assert-Rejected { Invoke-AwsDeliveryMaintenance $context 'database-credentials' $spec $null $persist 30 0 -Confirm:$false } 'lifecycle.delivery.jobFailed'
$failed = @{ jobId = $arn; attemptId = [guid]::NewGuid().ToString(); templateSha256 = (Get-AwsDeliveryTaskHash $spec); executionId = $task; status = 'Failed' }
Assert-Rejected { Invoke-AwsDeliveryMaintenance $context 'database-credentials' $spec $failed $persist 30 0 -Confirm:$false } 'lifecycle.delivery.failedExecutionRequiresInvestigation'
$stale = @{} + $failed; $stale.status = 'Running'; $stale.templateSha256 = '0' * 64
Assert-Rejected { Invoke-AwsDeliveryMaintenance $context 'database-credentials' $spec $stale $persist 30 0 -Confirm:$false } 'lifecycle.delivery.jobEvidenceStale'
$foreign = @{} + $failed; $foreign.status = 'Running'; $script:exit = 0
Assert-Rejected { Invoke-AwsDeliveryMaintenance $context 'database-credentials' $spec $foreign $persist 30 0 -Confirm:$false } 'lifecycle.delivery.executionChanged'

# Messaging bindings: the exact SNS/SQS keys of each workload are merged into a copy of the hosting inputs.
$topic = 'arn:aws:sns:us-east-1:123456789012:hexagon-example-dev-integration-events'
$queue = 'https://sqs.us-east-1.amazonaws.com/123456789012/hexagon-example-dev-worker'
$bindingInputs = @{ workloads = @{ api = @{ environment = @{ Existing = 'kept' }; secret_references = @{} }; worker = @{ environment = @{}; secret_references = @{} } } }
$bindings = @{ api = @{ 'Messaging__Aws__Sns__Destinations__integration-events__TopicArn' = $topic; 'Messaging__Aws__Sns__Destinations__integration-events__Region' = 'us-east-1' }
    worker = @{ 'Messaging__Aws__Sqs__Consumers__worker__QueueUrl' = $queue; 'Messaging__Aws__Sqs__Consumers__worker__RetryVisibilityTimeoutSeconds' = '30' } }
$bound = Add-AwsMessagingBindings $bindingInputs $bindings
Assert-True ($bound.workloads.api.environment['Messaging__Aws__Sns__Destinations__integration-events__TopicArn'] -ceq $topic -and $bound.workloads.api.environment.Existing -ceq 'kept' -and
    $bound.workloads.worker.environment['Messaging__Aws__Sqs__Consumers__worker__QueueUrl'] -ceq $queue -and $bindingInputs.workloads.api.environment.Count -eq 1) 'Bindings are merged into a copy of the inputs.'
Assert-Rejected { Add-AwsMessagingBindings $bindingInputs @{ ghost = @{ 'Messaging__Aws__Sns__Destinations__x__Region' = 'us-east-1' } } } 'lifecycle.delivery.bindingWorkloadUnknown'
Assert-Rejected { Add-AwsMessagingBindings $bindingInputs @{ api = @{ 'Messaging__Aws__Sqs__Consumers__worker__Password' = 'x' } } } 'lifecycle.delivery.bindingInvalid'
Assert-Rejected { Add-AwsMessagingBindings $bindingInputs @{ api = @{ 'Messaging__Aws__Sns__Destinations__x__TopicArn' = 'arn with spaces' } } } 'lifecycle.delivery.bindingInvalid'
$conflict = @{ workloads = @{ api = @{ environment = @{ 'Messaging__Aws__Sns__Destinations__x__Region' = 'eu-west-1' }; secret_references = @{} } } }
Assert-Rejected { Add-AwsMessagingBindings $conflict @{ api = @{ 'Messaging__Aws__Sns__Destinations__x__Region' = 'us-east-1' } } } 'lifecycle.delivery.bindingConflict'
Assert-Rejected { Add-AwsMessagingBindings $bindingInputs $null } 'lifecycle.delivery.messagingBindingsUnavailable'

# Maintenance reads the bindings only from the exact verified messaging snapshot.
$bindingContext = $context.Clone(); $bindingContext.inventory = Copy-Value $context.inventory
$messagingRoot = @($bindingContext.inventory.roots | Where-Object id -CEQ 'messaging')[0]
$messagingRoot.status = 'Verified'; $messagingRoot.stateLineage = [guid]::NewGuid().ToString(); $messagingRoot.stateSerial = 2
$bindingState = @{ version = 4; lineage = $messagingRoot.stateLineage; serial = 2; resources = @(); outputs = @{ aws_sns_sqs = @{ value = @{ workload_bindings = $bindings } } } }
$script:objects[$messagingRoot.stateKey] = @{ bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-PlatformBootstrapJson $bindingState)); etag = '"bindings"' }
$bound = Get-AwsDeliveryBoundInputs $bindingContext $bindingInputs
Assert-True ($bound.workloads.api.environment['Messaging__Aws__Sns__Destinations__integration-events__TopicArn'] -ceq $topic) 'Maintenance receives verified messaging bindings.'
$messagingRoot.stateSerial = 3
Assert-Rejected { Get-AwsDeliveryBoundInputs $bindingContext $bindingInputs } 'lifecycle.delivery.messagingBindingsUnavailable'
$messagingRoot.stateSerial = 2; $messagingRoot.stateLineage = [guid]::NewGuid().ToString()
Assert-Rejected { Get-AwsDeliveryBoundInputs $bindingContext $bindingInputs } 'lifecycle.delivery.messagingBindingsUnavailable'
$messagingRoot.status = 'Pending'
Assert-Rejected { Get-AwsDeliveryBoundInputs $bindingContext $bindingInputs } 'lifecycle.delivery.messagingNotReady'
$disabled = Copy-Value $bindingInputs; $disabled.messaging_enabled = $false
Assert-Rejected { Get-AwsDeliveryBoundInputs $bindingContext $disabled } 'lifecycle.delivery.messagingUnexpected'
$bindingContext.inventory.roots = @($bindingContext.inventory.roots | Where-Object id -CNE 'messaging')
$bound = Get-AwsDeliveryBoundInputs $bindingContext $disabled
Assert-True ($bound.workloads.api.environment.Count -eq 1 -and $bound.messaging_enabled -eq $false) 'Messaging-free maintenance preserves its inputs.'

Exit-AwsLifecycleLease $context -Confirm:$false
Write-Host "AWS application delivery tests passed: $($script:assertions) assertions; in-memory S3, AWS CLI and registry doubles."
