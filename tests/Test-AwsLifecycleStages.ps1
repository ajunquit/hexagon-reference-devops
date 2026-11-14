<#
.SYNOPSIS
    Exercises the AWS stages behind Genesis and Apocalypse (ADR 0025): snapshot roots, quiesce, messaging
    bindings and the stage adapter entry point. No cloud calls: in-memory S3 and an AWS CLI double.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repository 'scripts/TerraformAwsLifecycle.psm1') -Force
Import-Module (Join-Path $repository 'scripts/AwsEnvironmentStore.psm1')
Import-Module (Join-Path $repository 'scripts/EnvironmentSnapshot.psm1')
Import-Module (Join-Path $repository 'scripts/PlatformBootstrap.psm1')
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

# The snapshot packs the AWS roots and their modules; Azure keeps its own.
Assert-True ((@(Get-SnapshotRootPaths hosting dev AwsHosting) -join ',') -ceq 'terraform/environments/dev/hosting-aws,terraform/modules/hosting/aws') 'AWS hosting root paths.'
Assert-True ((@(Get-SnapshotRootPaths messaging staging AwsSnsSqs) -join ',') -ceq 'terraform/environments/staging/aws,terraform/modules/messaging/aws-sns-sqs') 'AWS messaging root paths.'
Assert-True ((@(Get-SnapshotRootPaths hosting dev) -join ',') -ceq 'terraform/environments/dev/hosting-azure,terraform/modules/hosting/azure') 'Azure stays the default.'
Assert-Rejected { Get-SnapshotRootPaths messaging dev AwsHosting } 'lifecycle.snapshotRootUnknown'
$snapshot = Get-Module EnvironmentSnapshot
$inputs = [Text.Encoding]::UTF8.GetBytes((ConvertTo-PlatformBootstrapJson @{ product = 'hexagon-template'; environment = 'dev'; name_prefix = $prefix }))
& $snapshot { param($i, $r, $b) Assert-LifecycleInputs $i $r $b } $inventory $inventory.roots[0] $inputs; $script:assertions++
$foreign = [Text.Encoding]::UTF8.GetBytes((ConvertTo-PlatformBootstrapJson @{ product = 'hexagon-template'; environment = 'dev'; name_prefix = 'other-prefix' }))
Assert-Rejected { & $snapshot { param($i, $r, $b) Assert-LifecycleInputs $i $r $b } $inventory $inventory.roots[0] $foreign } 'lifecycle.snapshotInputsInvalid'

# A context with an in-memory S3 and a scripted AWS CLI.
$script:objects = @{}
$s3 = {
    param($operation, $key, $bytes, $ifNoneMatch, $ifMatch)
    if ($operation -ceq 'Get') { if (-not $script:objects.ContainsKey($key)) { return @{ status = 404 } }; return @{ status = 200; bytes = $script:objects[$key].bytes; etag = $script:objects[$key].etag } }
    $exists = $script:objects.ContainsKey($key)
    if (($ifNoneMatch -and $exists) -or ($ifMatch -and (-not $exists -or $script:objects[$key].etag -cne $ifMatch))) { return @{ status = 412 } }
    $etag = '"' + [guid]::NewGuid().ToString('N') + '"'; $script:objects[$key] = @{ bytes = $bytes; etag = $etag }; return @{ status = 200; etag = $etag }
}
$ok = { param($value) @{ exitCode = 0; text = (ConvertTo-PlatformBootstrapJson $value); errorText = '' } }
$service = "arn:aws:ecs:us-east-1:123456789012:service/$prefix/api"
$script:desired = 1; $script:running = @("arn:aws:ecs:us-east-1:123456789012:task/$prefix/migrations"); $script:calls = [Collections.Generic.List[string]]::new()
$cli = {
    param($arguments)
    $line = $arguments -join ' '; $script:calls.Add($line)
    switch -Wildcard ($line) {
        'ecs list-services *' { return & $ok @{ serviceArns = @($service) } }
        'ecs update-service *' { $script:desired = 0; return & $ok @{} }
        'ecs stop-task *' { $script:running = @(); return & $ok @{} }
        'ecs list-tasks *' { return & $ok @{ taskArns = @($script:running) } }
        'ecs describe-services *' { return & $ok @{ services = @(@{ serviceArn = $service; status = 'ACTIVE'; desiredCount = $script:desired; runningCount = $script:desired }) } }
    }
    throw "Unexpected AWS call: $line"
}
$context = New-AwsLifecycleContext (Copy-Value $inventory) 'arn:aws:sts::123456789012:assumed-role/hexagon-template-dev-run-12345-1-deploy/GitHubActions' '123456789012' $s3
Enter-AwsLifecycleLease $context -Confirm:$false
$context.awsCli = $cli

# Quiesce brings every service to zero and stops running tasks before Apocalypse.
$quiesced = Invoke-AwsLifecycleQuiesce $context 5 0 -Confirm:$false
Assert-True ($quiesced.quiesced -and $quiesced.services -eq 1) 'Quiesce must leave the instance without running workloads.'
Assert-True (@($script:calls | Where-Object { $_ -like "ecs update-service --cluster $prefix --service $service --desired-count 0*" }).Count -eq 1 -and @($script:calls | Where-Object { $_ -like 'ecs stop-task *' }).Count -eq 1) 'Quiesce must scale services to zero and stop running tasks.'
$script:desired = 1; $script:calls.Clear()
$stuck = { param($arguments) $line = $arguments -join ' '; if ($line -like 'ecs update-service *') { return & $ok @{} }; return & $cli $arguments }
$context.awsCli = $stuck
Assert-Rejected { Invoke-AwsLifecycleQuiesce $context 0 0 -Confirm:$false } 'lifecycle.aws.applicationNotQuiesced'
$context.awsCli = $cli

# Messaging binds to the task roles that the verified hosting state declares.
$model = Copy-Value $inventory
$model.roots[0].status = 'Verified'; $model.roots[0].lastOperation = 'Create'; $model.roots[0].stateLineage = '44444444-4444-4444-4444-444444444444'; $model.roots[0].stateSerial = 3
$context.inventory = $model
$state = @{ version = 4; lineage = '44444444-4444-4444-4444-444444444444'; serial = 3; resources = @()
    outputs = @{ workload_roles = @{ value = @{ api = @{ name = "$prefix-a1"; arn = 'x' }; worker = @{ name = "$prefix-b2"; arn = 'y' } } } } }
$script:objects['hexagon-template/dev/run-12345-1/hosting.tfstate'] = @{ bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-PlatformBootstrapJson $state)); etag = '"s"' }
$messaging = @{ destinations = @{ sales = @{ name = "$prefix-sales"; publishers = @{ api = "$prefix-a1" } } }; consumers = @{ worker = @{ name = "$prefix-worker"; role_name = "$prefix-b2" } } }
Assert-AwsMessagingBindings $context $messaging; $script:assertions++
$messaging.consumers.worker.role_name = "$prefix-unknown"
Assert-Rejected { Assert-AwsMessagingBindings $context $messaging } 'lifecycle.aws.messagingRoleUnbound'
$model.roots[0].stateSerial = 4
Assert-Rejected { Assert-AwsMessagingBindings $context @{ destinations = @{}; consumers = @{} } } 'lifecycle.aws.hostingStateChanged'
Exit-AwsLifecycleLease $context -Confirm:$false

# The stage adapter reads the AWS inventory and stops at WhatIf without any call. It runs from a copy
# that carries the product of the example: a product instance has its own name in .config/product.json,
# and the short prefix of the example derives from that name.
$source = Join-Path ([IO.Path]::GetTempPath()) "hexagon-aws-stage-$([guid]::NewGuid().ToString('N'))"
try {
    foreach ($relative in @('scripts', 'contracts/schemas', '.config')) {
        $destination = Join-Path $source $relative; [IO.Directory]::CreateDirectory($destination) | Out-Null
        Get-ChildItem -LiteralPath (Join-Path $repository $relative) -File -Force | Copy-Item -Destination $destination
    }
    [IO.File]::WriteAllText((Join-Path $source '.config/product.json'), (ConvertTo-PlatformBootstrapJson @{ product = $inventory.product }))
    $output = & pwsh -NoLogo -NoProfile -File (Join-Path $source 'scripts/Invoke-AwsEnvironment.ps1') -Mode Build -Inventory (Join-Path $repository 'examples/environment-inventory-aws.json') `
        -Environment dev -InstanceId run-12345-1 -Workspace (Join-Path $source "artifacts/aws-stage-$([guid]::NewGuid().ToString('N'))") -WhatIf
}
finally { Remove-Item -LiteralPath $source -Recurse -Force -ErrorAction SilentlyContinue }
$result = ($output -join "`n") | ConvertFrom-Json
Assert-True ($LASTEXITCODE -eq 2 -and $result.apiVersion -ceq 'hexagon.ec/aws-environment-result/v1' -and $result.status -ceq 'Unverified' -and $result.applicationVerified -eq $false) 'The AWS stage adapter must answer WhatIf with its own result contract.'
Write-Host "AWS lifecycle stage tests passed: $($script:assertions) assertions; in-memory S3 and AWS CLI double."
