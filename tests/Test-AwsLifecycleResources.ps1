<#
.SYNOPSIS
    Checks how the AWS lifecycle adapter proves presence and absence (ADR 0025), with no cloud calls.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repository 'scripts/AwsLifecycleResources.psm1') -Force
$script:assertions = 0
function Assert-True([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message }; $script:assertions++ }
function Assert-Rejected([scriptblock] $Action, [string] $Code) {
    try { & $Action | Out-Null }
    catch { Assert-True ($_.Exception.Message -like "*$Code*") "Unexpected rejection: $($_.Exception.Message)"; return }
    throw "Expected rejection: $Code"
}
$inventory = Get-Content -Raw -LiteralPath (Join-Path $repository 'examples/environment-inventory-aws.json') | ConvertFrom-Json -AsHashtable -Depth 32
$account = '123456789012'; $region = 'us-east-1'
function Id([string] $Type, [string] $Value) { return ConvertTo-AwsLifecycleResourceId $inventory $Type $Value }

# Every type of the AWS modules has a probe: a new type must extend the catalogue, never be assumed absent.
$used = @(Get-ChildItem -Path (Join-Path $repository 'terraform/modules/hosting/aws'), (Join-Path $repository 'terraform/modules/messaging/aws-sns-sqs') -Filter '*.tf' |
    ForEach-Object { [regex]::Matches((Get-Content -Raw -LiteralPath $_.FullName), '(?m)^resource "([a-z0-9_]+)"') | ForEach-Object { $_.Groups[1].Value } } | Sort-Object -Unique)
$supported = @(Get-AwsLifecycleSupportedTypes)
$missing = @($used | Where-Object { $_ -cnotin $supported })
Assert-True ($missing.Count -eq 0) "AWS types without a lifecycle probe: $($missing -join ', ')"
Assert-Rejected { Get-AwsLifecycleProbe $inventory 'aws_instance' 'i-1' } 'lifecycle.aws.resourceTypeUnsupported'

# Cloud Control identifiers derived from Terraform IDs.
$cases = @(
    @{ Type = 'aws_ecs_cluster'; Id = "arn:aws:ecs:$($region):$($account):cluster/tpl-dev-e1c8fa"; TypeName = 'AWS::ECS::Cluster'; Identifier = 'tpl-dev-e1c8fa' },
    @{ Type = 'aws_iam_role_policy'; Id = 'tpl-dev-e1c8fa-api:read-own-secrets'; TypeName = 'AWS::IAM::RolePolicy'; Identifier = 'read-own-secrets|tpl-dev-e1c8fa-api' },
    @{ Type = 'aws_cloudfront_function'; Id = 'tpl-dev-e1c8fa-spa'; TypeName = 'AWS::CloudFront::Function'; Identifier = "arn:aws:cloudfront::$($account):function/tpl-dev-e1c8fa-spa" },
    @{ Type = 'aws_appautoscaling_target'; Id = 'service/tpl-dev-e1c8fa/api'; TypeName = 'AWS::ApplicationAutoScaling::ScalableTarget'; Identifier = 'service/tpl-dev-e1c8fa/api|ecs:service:DesiredCount|ecs' },
    @{ Type = 'aws_vpc'; Id = 'vpc-0123'; TypeName = 'AWS::EC2::VPC'; Identifier = 'vpc-0123' }
)
foreach ($case in $cases) {
    $probe = Get-AwsLifecycleProbe $inventory $case.Type $case.Id
    Assert-True ($probe.mode -ceq 'CloudControl' -and $probe.typeName -ceq $case.TypeName -and $probe.identifier -ceq $case.Identifier) "Wrong Cloud Control probe for $($case.Type)."
}
Assert-Rejected { Get-AwsLifecycleProbe $inventory 'aws_iam_role_policy' 'no-separator' } 'lifecycle.aws.resourceIdInvalid'

# Configuration types follow their parent.
foreach ($case in @(
    @{ Type = 'aws_s3_bucket_public_access_block'; Id = 'tpl-dev-e1c8fa-web-123456789012,123456789012'; Parent = 'tpl-dev-e1c8fa-web-123456789012' },
    @{ Type = 'aws_iam_role_policy_attachment'; Id = 'tpl-dev-e1c8fa-run-1/arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy'; Parent = 'tpl-dev-e1c8fa-run-1' },
    @{ Type = 'aws_iam_role_policy_attachment'; Id = 'tpl-dev-e1c8fa-run-1-20261112120000000000000001'; Parent = 'tpl-dev-e1c8fa-run-1' }
)) {
    $probe = Get-AwsLifecycleProbe $inventory $case.Type $case.Id
    Assert-True ($probe.mode -ceq 'Parent' -and $probe.parent.identifier -ceq $case.Parent) "Wrong parent probe for $($case.Type)."
}
Assert-Rejected { Get-AwsLifecycleProbe $inventory 'aws_iam_role_policy_attachment' 'unknown-format' } 'lifecycle.aws.resourceIdInvalid'
$service = Get-AwsLifecycleProbeArguments (Get-AwsLifecycleProbe $inventory 'aws_ecs_service' "arn:aws:ecs:$($region):$($account):service/tpl-dev-e1c8fa/api")
Assert-True (($service -join ' ') -ceq "ecs describe-services --cluster arn:aws:ecs:$($region):$($account):cluster/tpl-dev-e1c8fa --services arn:aws:ecs:$($region):$($account):service/tpl-dev-e1c8fa/api") 'An ECS service is probed in its own cluster.'

# Classification: lingering resources count as absent; denied or unexpected answers never do.
$cloud = Get-AwsLifecycleProbe $inventory 'aws_vpc' 'vpc-0123'
$key = Get-AwsLifecycleProbe $inventory 'aws_kms_key' '11111111-2222-3333-4444-555555555555'
$definition = Get-AwsLifecycleProbe $inventory 'aws_ecs_task_definition' 'tpl-dev-e1c8fa-migrations'
$ecs = Get-AwsLifecycleProbe $inventory 'aws_ecs_service' "arn:aws:ecs:$($region):$($account):service/tpl-dev-e1c8fa/api"
$database = Get-AwsLifecycleProbe $inventory 'aws_db_instance' 'db-ABCDEFGHIJKL'
foreach ($case in @(
    @{ Probe = $cloud; Response = @{ exitCode = 0; text = '{}'; errorText = '' }; Expected = 'Present' },
    @{ Probe = $cloud; Response = @{ exitCode = 254; text = ''; errorText = 'An error occurred (ResourceNotFoundException)' }; Expected = 'Missing' },
    @{ Probe = $cloud; Response = @{ exitCode = 254; text = ''; errorText = 'An error occurred (AccessDeniedException)' }; Expected = 'Unknown' },
    @{ Probe = $cloud; Response = @{ exitCode = 254; text = ''; errorText = 'An error occurred (ThrottlingException)' }; Expected = 'Unknown' },
    @{ Probe = $key; Response = @{ exitCode = 0; text = '{"KeyMetadata":{"KeyState":"PendingDeletion"}}'; errorText = '' }; Expected = 'Missing' },
    @{ Probe = $key; Response = @{ exitCode = 0; text = '{"KeyMetadata":{"KeyState":"Enabled"}}'; errorText = '' }; Expected = 'Present' },
    @{ Probe = $definition; Response = @{ exitCode = 0; text = '{"taskDefinition":{"status":"INACTIVE"}}'; errorText = '' }; Expected = 'Missing' },
    @{ Probe = $ecs; Response = @{ exitCode = 0; text = '{"services":[],"failures":[{"reason":"MISSING"}]}'; errorText = '' }; Expected = 'Missing' },
    @{ Probe = $ecs; Response = @{ exitCode = 0; text = '{"services":[{"status":"DRAINING"}],"failures":[]}'; errorText = '' }; Expected = 'Present' },
    @{ Probe = $ecs; Response = @{ exitCode = 0; text = '{"services":[{"status":"INACTIVE"}],"failures":[]}'; errorText = '' }; Expected = 'Missing' },
    @{ Probe = $database; Response = @{ exitCode = 0; text = '{"DBInstances":[]}'; errorText = '' }; Expected = 'Missing' },
    @{ Probe = $database; Response = @{ exitCode = 0; text = 'not json'; errorText = '' }; Expected = 'Unknown' }
)) {
    $status = Resolve-AwsLifecycleProbe $case.Probe $case.Response
    Assert-True ($status -ceq $case.Expected) "Expected $($case.Expected), got $status."
}
$seen = [Collections.Generic.List[string]]::new()
$aws = { param($arguments) $seen.Add($arguments -join ' '); return @{ exitCode = 0; text = '{}'; errorText = '' } }
$status = Test-AwsLifecycleResource $inventory (Id 'aws_s3_bucket_policy' 'tpl-dev-e1c8fa-web-123456789012') $aws
Assert-True ($status -ceq 'Present' -and $seen[0] -ceq 'cloudcontrol get-resource --type-name AWS::S3::Bucket --identifier tpl-dev-e1c8fa-web-123456789012') 'A bucket policy is proven through its bucket.'
Assert-Rejected { Test-AwsLifecycleResource $inventory 'aws:210987654321:us-east-1:aws_vpc:vpc-1' $aws } 'lifecycle.aws.resourceScopeMismatch'

# Terraform state: managed resources with qualified IDs and addresses; anything unexpected is rejected.
function Get-StateBytes([object[]] $Resources) { return [Text.Encoding]::UTF8.GetBytes((@{ version = 4; lineage = '44444444-4444-4444-4444-444444444444'; serial = 7; resources = $Resources; outputs = @{ web = @{ value = @{ url = 'https://d1.cloudfront.net' } } } } | ConvertTo-Json -Depth 32)) }
$state = Read-AwsLifecycleTerraformState $inventory (Get-StateBytes @(
        @{ mode = 'data'; type = 'aws_caller_identity'; name = 'current'; instances = @(@{ attributes = @{ id = $account } }) },
        @{ module = 'module.hosting'; mode = 'managed'; type = 'aws_vpc'; name = 'this'; instances = @(@{ attributes = @{ id = 'vpc-0123' } }) },
        @{ module = 'module.hosting'; mode = 'managed'; type = 'aws_subnet'; name = 'public'; instances = @(@{ index_key = 0; attributes = @{ id = 'subnet-0' } }, @{ index_key = 1; attributes = @{ id = 'subnet-1' } }) }
    ))
Assert-True ($state.resources.Count -eq 3 -and $state.serial -eq 7 -and $state.resources[0].id -ceq (Id 'aws_vpc' 'vpc-0123') -and $state.resources[2].address -ceq 'module.hosting.aws_subnet.public[1]' -and $state.outputs.web.value.url) 'The state must yield qualified resources, addresses and outputs.'
Assert-Rejected { Read-AwsLifecycleTerraformState $inventory (Get-StateBytes @(@{ mode = 'managed'; type = 'aws_instance'; name = 'x'; instances = @(@{ attributes = @{ id = 'i-1' } }) })) } 'lifecycle.aws.resourceTypeUnsupported'
Assert-Rejected { Read-AwsLifecycleTerraformState $inventory (Get-StateBytes @(@{ mode = 'managed'; type = 'aws_vpc'; name = 'x'; instances = @(@{ deposed = 'abc'; attributes = @{ id = 'vpc-1' } }) })) } 'lifecycle.aws.deposedStateUnsupported'
Assert-Rejected { Read-AwsLifecycleTerraformState $inventory ([Text.Encoding]::UTF8.GetBytes('{"version":3,"resources":[]}')) } 'lifecycle.aws.stateInvalid'

# Remaining resources by instance tag, excluding the reservation that the bootstrap retains.
$tags = @(@{ Key = 'hexagon:instance'; Value = 'run-12345-1' })
$retained = Get-AwsLifecycleRetainedArns $inventory
Assert-True ($retained.Count -eq 6 -and $retained[0] -ceq $inventory.target.roleArn -and $retained -ccontains "arn:aws:iam::$($account):policy/hexagon-template-dev-run-12345-1-guardrails") 'The reservation role and its five policies are retained.'
$pages = @(
    @{ ResourceTagMappingList = @(@{ ResourceARN = $inventory.target.roleArn; Tags = $tags }, @{ ResourceARN = "arn:aws:sqs:$($region):$($account):tpl-dev-e1c8fa-queue"; Tags = $tags }) },
    @{ ResourceTagMappingList = @(@{ ResourceARN = "arn:aws:iam::$($account):policy/hexagon-template-dev-run-12345-1-state"; Tags = $tags }, @{ ResourceARN = 'arn:aws:s3:::tpl-dev-e1c8fa-web-123456789012'; Tags = $tags }) }
)
$remaining = Get-AwsLifecycleRemaining $inventory $pages
Assert-True ($remaining.Count -eq 2 -and $remaining -ccontains 'arn:aws:s3:::tpl-dev-e1c8fa-web-123456789012') 'Only resources of the roots remain to be destroyed.'
Assert-Rejected { Get-AwsLifecycleRemaining $inventory @(@{ ResourceTagMappingList = @(@{ ResourceARN = 'arn:aws:s3:::x'; Tags = @(@{ Key = 'hexagon:instance'; Value = 'persistent' }) }) }) } 'lifecycle.aws.scopeResponseMismatch'
Assert-Rejected { Get-AwsLifecycleRemaining $inventory @(@{ ResourceTagMappingList = @(@{ ResourceARN = "arn:aws:sqs:$($region):210987654321:q"; Tags = $tags }) }) } 'lifecycle.aws.scopeResponseMismatch'
Assert-Rejected { Get-AwsLifecycleRemaining $inventory @(@{ unexpected = $true }) } 'lifecycle.aws.scopeIncomplete'
Write-Host "AWS lifecycle resource tests passed: $($script:assertions) assertions; no cloud calls."
