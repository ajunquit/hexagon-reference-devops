<#
.SYNOPSIS
    Exercises the Terraform/AWS lifecycle adapter (ADR 0025) with an in-memory S3 and an AWS CLI double.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repository 'scripts/TerraformAwsLifecycle.psm1') -Force
Import-Module (Join-Path $repository 'scripts/AwsEnvironmentStore.psm1')
Import-Module (Join-Path $repository 'scripts/AwsLifecycleResources.psm1')
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
$hosting = $inventory.roots[0]; $messaging = $inventory.roots[1]
$prefix = $hosting.namePrefix

# Inputs stay inside the reservation.
$hostingInputs = @{ product = 'hexagon-template'; environment = 'dev'; instance_id = 'run-12345-1'; region = 'us-east-1'; account_id = '123456789012'; name_prefix = $prefix
    workload_boundary_arn = 'arn:aws:iam::123456789012:policy/hexagon-workload-boundary'; workloads = @{ api = @{ name = "$prefix-api" }; worker = @{ name = "$prefix-worker" } } }
Assert-AwsLifecycleInputs $inventory $hosting $hostingInputs; $script:assertions++
foreach ($mutation in @(
    { param($i) $i.workloads.worker.name = 'example-dev-1' },
    { param($i) $i.workload_boundary_arn = $null },
    { param($i) $i.account_id = '210987654321' },
    { param($i) $i.instance_id = 'persistent' },
    { param($i) $i.name_prefix = 'tpl-dev' }
)) { $bad = Copy-Value $hostingInputs; & $mutation $bad; Assert-Rejected { Assert-AwsLifecycleInputs $inventory $hosting $bad } 'lifecycle.aws.inputsOutsideScope' }
$messagingInputs = @{ product = 'hexagon-template'; environment = 'dev'; instance_id = 'run-12345-1'; region = 'us-east-1'; name_prefix = $prefix; kms_alias_name = "$prefix-events"
    destinations = @{ sales = @{ name = "$prefix-sales"; publishers = @{ api = "$prefix-api" } } }
    consumers = @{ worker = @{ name = "$prefix-worker"; role_name = "$prefix-worker"; redrive = @{ dead_letter_queue_name = "$prefix-worker-dlq" } } } }
Assert-AwsLifecycleInputs $inventory $messaging $messagingInputs; $script:assertions++
foreach ($mutation in @(
    { param($i) $i.consumers.worker.redrive.dead_letter_queue_name = 'worker-dlq' },
    { param($i) $i.destinations.sales.publishers.api = 'shared-api-role' },
    { param($i) $i.kms_alias_name = 'hexagon-events' },
    { param($i) $i.region = 'eu-west-1' }
)) { $bad = Copy-Value $messagingInputs; & $mutation $bad; Assert-Rejected { Assert-AwsLifecycleInputs $inventory $messaging $bad } 'lifecycle.aws.inputsOutsideScope' }

# A context with an in-memory S3 and a scripted AWS CLI.
$script:objects = @{}
$s3 = {
    param($operation, $key, $bytes, $ifNoneMatch, $ifMatch)
    if ($operation -ceq 'Get') { if (-not $script:objects.ContainsKey($key)) { return @{ status = 404 } }; return @{ status = 200; bytes = $script:objects[$key].bytes; etag = $script:objects[$key].etag } }
    $exists = $script:objects.ContainsKey($key)
    if (($ifNoneMatch -and $exists) -or ($ifMatch -and (-not $exists -or $script:objects[$key].etag -cne $ifMatch))) { return @{ status = 412 } }
    $etag = '"' + [guid]::NewGuid().ToString('N') + '"'; $script:objects[$key] = @{ bytes = $bytes; etag = $etag }; return @{ status = 200; etag = $etag }
}
$script:responses = @{}
$script:calls = [Collections.Generic.List[string]]::new()
$cli = {
    param($arguments)
    $line = $arguments -join ' '; $script:calls.Add($line)
    foreach ($pattern in $script:responses.Keys) { if ($line -like $pattern) { return $script:responses[$pattern] } }
    throw "Unexpected AWS call: $line"
}
function New-TestContext([hashtable] $Model) {
    $context = New-AwsLifecycleContext $Model 'arn:aws:sts::123456789012:assumed-role/hexagon-template-dev-run-12345-1-deploy/GitHubActions' '123456789012' $s3
    Enter-AwsLifecycleLease $context -Confirm:$false
    $context.awsCli = $cli
    return $context
}
$ok = { param($value) @{ exitCode = 0; text = (ConvertTo-PlatformBootstrapJson $value); errorText = '' } }
$fail = { param($message) @{ exitCode = 254; text = ''; errorText = $message } }

# Destruction safety: nothing may run while Terraform removes the instance.
$context = New-TestContext (Copy-Value $inventory)
$request = @{ product = 'hexagon-template'; environment = 'dev'; instanceId = 'run-12345-1'; root = $messaging }
$service = "arn:aws:ecs:us-east-1:123456789012:service/$prefix/api"
$script:responses = @{ "ecs list-services --cluster $prefix *" = (& $ok @{ serviceArns = @($service) }); "ecs describe-services *" = (& $ok @{ services = @(@{ serviceArn = $service; status = 'ACTIVE'; desiredCount = 1; runningCount = 1 }) }) }
Assert-Rejected { Get-AwsLifecycleDestructionSafety $context $request } 'lifecycle.aws.applicationNotQuiesced'
$script:responses["ecs describe-services *"] = & $ok @{ services = @(@{ serviceArn = $service; status = 'ACTIVE'; desiredCount = 0; runningCount = 0 }) }
$script:responses["ecs list-tasks *"] = & $ok @{ taskArns = @("arn:aws:ecs:us-east-1:123456789012:task/$prefix/migrations") }
Assert-Rejected { Get-AwsLifecycleDestructionSafety $context $request } 'lifecycle.aws.jobNotQuiesced'
$script:responses["ecs list-tasks *"] = & $ok @{ taskArns = @() }
$safety = Get-AwsLifecycleDestructionSafety $context $request
Assert-True ($safety.quiesced -and -not $safety.backupVerified -and $script:objects.ContainsKey("hexagon-template/dev/run-12345-1/evidence/$($safety.evidenceSha256).json")) 'A quiesced instance leaves durable evidence.'
$script:responses = @{ "ecs list-services *" = (& $fail 'An error occurred (ClusterNotFoundException)') }
Assert-True ((Get-AwsLifecycleDestructionSafety $context $request).quiesced) 'A removed cluster runs nothing.'
$script:responses = @{ "ecs list-services *" = (& $fail 'An error occurred (AccessDeniedException)') }
Assert-Rejected { Get-AwsLifecycleDestructionSafety $context $request } 'lifecycle.aws.quiescenceUnavailable'
$persistent = Copy-Value $inventory; $persistent.dataPolicy = 'BackupRequired'
$context.inventory = $persistent
Assert-Rejected { Get-AwsLifecycleDestructionSafety $context $request } 'lifecycle.aws.backupVerifierRequired'

$context.inventory = $inventory
Exit-AwsLifecycleLease $context -Confirm:$false

# Destruction observed: state gone, every recorded resource missing and nothing tagged but the reservation.
$single = Copy-Value $inventory; $single.roots = @($single.roots[0])
$vpc = ConvertTo-AwsLifecycleResourceId $single 'aws_vpc' 'vpc-0123'
$single.roots[0].resources = @(@{ id = $vpc; address = 'module.hosting.aws_vpc.this'; type = 'aws_vpc'; presence = 'Present'; current = $true })
$context = New-TestContext $single
$tags = @(@{ Key = 'hexagon:instance'; Value = 'run-12345-1' })
$script:responses = @{
    'cloudcontrol get-resource --type-name AWS::EC2::VPC --identifier vpc-0123 *' = (& $fail 'An error occurred (ResourceNotFoundException)')
    'resourcegroupstaggingapi get-resources *' = (& $ok @{ ResourceTagMappingList = @(@{ ResourceARN = $single.target.roleArn; Tags = $tags }) })
}
$observation = Get-AwsLifecycleObservation $context $single.roots[0] Destroy 0 0
Assert-True ($observation.stateStatus -ceq 'Absent' -and $observation.remainingResourceIds.Count -eq 0 -and $observation.probes[0].status -ceq 'Missing' -and -not $observation.configurationConverged) 'A complete destruction must be observable.'
$script:responses['resourcegroupstaggingapi get-resources *'] = & $ok @{ ResourceTagMappingList = @(@{ ResourceARN = "arn:aws:sqs:us-east-1:123456789012:$prefix-left"; Tags = $tags }) }
$observation = Get-AwsLifecycleObservation $context $single.roots[0] Destroy 0 0
Assert-True ($observation.remainingResourceIds -ccontains "arn:aws:sqs:us-east-1:123456789012:$prefix-left") 'A resource left behind keeps the destruction incomplete.'
$script:responses['cloudcontrol get-resource --type-name AWS::EC2::VPC --identifier vpc-0123 *'] = & $fail 'An error occurred (AccessDeniedException)'
$observation = Get-AwsLifecycleObservation $context $single.roots[0] Destroy 0 0
Assert-True ($observation.probes[0].status -ceq 'Unknown') 'A denied probe never proves absence.'
Write-Host "AWS lifecycle adapter tests passed: $($script:assertions) assertions; in-memory S3 and AWS CLI double."
