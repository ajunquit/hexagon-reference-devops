Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# What the AWS lifecycle adapter knows about each Terraform type (ADR 0025): how to prove presence or
# absence. Most types use Cloud Control (GetResource). Types that linger after deletion, or whose
# Terraform ID is not the Cloud Control identifier, use a dedicated probe. Configuration types without
# a resource of their own follow their parent. A type not listed here blocks the lifecycle: it is never
# assumed absent.

$script:cloudControl = @{
    aws_appautoscaling_target           = @{ typeName = 'AWS::ApplicationAutoScaling::ScalableTarget'; identifier = { param($id, $ctx) "$id|ecs:service:DesiredCount|ecs" } }
    aws_cloudfront_distribution         = @{ typeName = 'AWS::CloudFront::Distribution'; identifier = { param($id, $ctx) $id } }
    aws_cloudfront_function             = @{ typeName = 'AWS::CloudFront::Function'; identifier = { param($id, $ctx) "arn:aws:cloudfront::$($ctx.accountId):function/$id" } }
    aws_cloudfront_origin_access_control = @{ typeName = 'AWS::CloudFront::OriginAccessControl'; identifier = { param($id, $ctx) $id } }
    aws_cloudfront_response_headers_policy = @{ typeName = 'AWS::CloudFront::ResponseHeadersPolicy'; identifier = { param($id, $ctx) $id } }
    aws_cloudfront_vpc_origin           = @{ typeName = 'AWS::CloudFront::VpcOrigin'; identifier = { param($id, $ctx) $id } }
    aws_cloudwatch_log_group            = @{ typeName = 'AWS::Logs::LogGroup'; identifier = { param($id, $ctx) $id } }
    aws_cloudwatch_metric_alarm         = @{ typeName = 'AWS::CloudWatch::Alarm'; identifier = { param($id, $ctx) $id } }
    aws_db_subnet_group                 = @{ typeName = 'AWS::RDS::DBSubnetGroup'; identifier = { param($id, $ctx) $id } }
    aws_ecr_repository                  = @{ typeName = 'AWS::ECR::Repository'; identifier = { param($id, $ctx) $id } }
    aws_ecs_cluster                     = @{ typeName = 'AWS::ECS::Cluster'; identifier = { param($id, $ctx) ($id -split '/')[-1] } }
    aws_iam_role                        = @{ typeName = 'AWS::IAM::Role'; identifier = { param($id, $ctx) $id } }
    aws_iam_role_policy                 = @{ typeName = 'AWS::IAM::RolePolicy'; identifier = { param($id, $ctx) $parts = $id -split ':', 2; if ($parts.Count -ne 2) { throw 'lifecycle.aws.resourceIdInvalid' }; "$($parts[1])|$($parts[0])" } }
    aws_internet_gateway                = @{ typeName = 'AWS::EC2::InternetGateway'; identifier = { param($id, $ctx) $id } }
    aws_kms_alias                       = @{ typeName = 'AWS::KMS::Alias'; identifier = { param($id, $ctx) $id } }
    aws_lb                              = @{ typeName = 'AWS::ElasticLoadBalancingV2::LoadBalancer'; identifier = { param($id, $ctx) $id } }
    aws_lb_listener                     = @{ typeName = 'AWS::ElasticLoadBalancingV2::Listener'; identifier = { param($id, $ctx) $id } }
    aws_lb_listener_rule                = @{ typeName = 'AWS::ElasticLoadBalancingV2::ListenerRule'; identifier = { param($id, $ctx) $id } }
    aws_lb_target_group                 = @{ typeName = 'AWS::ElasticLoadBalancingV2::TargetGroup'; identifier = { param($id, $ctx) $id } }
    aws_route_table                     = @{ typeName = 'AWS::EC2::RouteTable'; identifier = { param($id, $ctx) $id } }
    aws_route_table_association         = @{ typeName = 'AWS::EC2::SubnetRouteTableAssociation'; identifier = { param($id, $ctx) $id } }
    aws_s3_bucket                       = @{ typeName = 'AWS::S3::Bucket'; identifier = { param($id, $ctx) $id } }
    aws_secretsmanager_secret           = @{ typeName = 'AWS::SecretsManager::Secret'; identifier = { param($id, $ctx) $id } }
    aws_security_group                  = @{ typeName = 'AWS::EC2::SecurityGroup'; identifier = { param($id, $ctx) $id } }
    aws_sns_topic                       = @{ typeName = 'AWS::SNS::Topic'; identifier = { param($id, $ctx) $id } }
    aws_sns_topic_subscription          = @{ typeName = 'AWS::SNS::Subscription'; identifier = { param($id, $ctx) $id } }
    aws_sqs_queue                       = @{ typeName = 'AWS::SQS::Queue'; identifier = { param($id, $ctx) $id } }
    aws_subnet                          = @{ typeName = 'AWS::EC2::Subnet'; identifier = { param($id, $ctx) $id } }
    aws_vpc                             = @{ typeName = 'AWS::EC2::VPC'; identifier = { param($id, $ctx) $id } }
    aws_vpc_security_group_egress_rule  = @{ typeName = 'AWS::EC2::SecurityGroupEgress'; identifier = { param($id, $ctx) $id } }
    aws_vpc_security_group_ingress_rule = @{ typeName = 'AWS::EC2::SecurityGroupIngress'; identifier = { param($id, $ctx) $id } }
}

# Configuration types: present while their parent exists (Terraform removes them before the parent).
$script:parents = @{
    aws_s3_bucket_ownership_controls                   = @{ type = 'aws_s3_bucket'; id = { param($id) ($id -split ',')[0] } }
    aws_s3_bucket_policy                               = @{ type = 'aws_s3_bucket'; id = { param($id) $id } }
    aws_s3_bucket_public_access_block                  = @{ type = 'aws_s3_bucket'; id = { param($id) ($id -split ',')[0] } }
    aws_s3_bucket_server_side_encryption_configuration = @{ type = 'aws_s3_bucket'; id = { param($id) ($id -split ',')[0] } }
    aws_sqs_queue_policy                               = @{ type = 'aws_sqs_queue'; id = { param($id) $id } }
    aws_sqs_queue_redrive_allow_policy                 = @{ type = 'aws_sqs_queue'; id = { param($id) $id } }
    aws_sqs_queue_redrive_policy                       = @{ type = 'aws_sqs_queue'; id = { param($id) $id } }
    aws_iam_role_policy_attachment                     = @{ type = 'aws_iam_role'; id = {
            param($id)
            if ($id -match '^(.+?)/arn:aws:iam::') { return $Matches[1] }
            if ($id -match '^(.+)-[0-9]{26}$') { return $Matches[1] }
            throw 'lifecycle.aws.resourceIdInvalid'
        }
    }
}

# Types that linger after deletion (pending key deletion, inactive revisions or services) or whose
# Terraform ID is not the Cloud Control identifier (DbiResourceId, scaling policy name).
$script:dedicated = @('aws_db_instance', 'aws_kms_key', 'aws_ecs_task_definition', 'aws_ecs_service', 'aws_appautoscaling_policy')

function Get-AwsLifecycleSupportedTypes { return @($script:cloudControl.Keys) + @($script:parents.Keys) + $script:dedicated | Sort-Object }

function ConvertTo-AwsLifecycleResourceId([hashtable] $Inventory, [string] $Type, [string] $Id) {
    return "aws:$($Inventory.target.accountId):$($Inventory.target.region):$($Type):$Id"
}

function Split-AwsLifecycleResourceId([hashtable] $Inventory, [string] $ResourceId) {
    $prefix = "aws:$($Inventory.target.accountId):$($Inventory.target.region):"
    if (-not $ResourceId.StartsWith($prefix, [StringComparison]::Ordinal)) { throw 'lifecycle.aws.resourceScopeMismatch' }
    $rest = $ResourceId.Substring($prefix.Length)
    $separator = $rest.IndexOf(':')
    if ($separator -lt 1) { throw 'lifecycle.aws.resourceIdInvalid' }
    return @{ type = $rest.Substring(0, $separator); id = $rest.Substring($separator + 1) }
}

# How to probe one resource: Cloud Control, a dedicated probe, or its parent.
function Get-AwsLifecycleProbe([hashtable] $Inventory, [string] $Type, [string] $Id) {
    $context = @{ accountId = $Inventory.target.accountId; region = $Inventory.target.region }
    if ($script:cloudControl.ContainsKey($Type)) {
        $spec = $script:cloudControl[$Type]
        return @{ mode = 'CloudControl'; typeName = $spec.typeName; identifier = [string] (& $spec.identifier $Id $context) }
    }
    if ($script:parents.ContainsKey($Type)) {
        $parent = $script:parents[$Type]
        $parentId = [string] (& $parent.id $Id)
        return @{ mode = 'Parent'; parent = Get-AwsLifecycleProbe $Inventory $parent.type $parentId }
    }
    if ($script:dedicated -ccontains $Type) { return @{ mode = 'Dedicated'; type = $Type; identifier = $Id } }
    throw 'lifecycle.aws.resourceTypeUnsupported'
}

# The CLI arguments of a probe. The caller adds region and output format.
function Get-AwsLifecycleProbeArguments([hashtable] $Probe) {
    if ($Probe.mode -ceq 'CloudControl') { return @('cloudcontrol', 'get-resource', '--type-name', $Probe.typeName, '--identifier', $Probe.identifier) }
    switch ($Probe.type) {
        'aws_db_instance' { return @('rds', 'describe-db-instances', '--filters', "Name=dbi-resource-id,Values=$($Probe.identifier)") }
        'aws_kms_key' { return @('kms', 'describe-key', '--key-id', $Probe.identifier) }
        'aws_ecs_task_definition' { return @('ecs', 'describe-task-definition', '--task-definition', $Probe.identifier) }
        'aws_ecs_service' {
            $cluster = $Probe.identifier -replace ':service/([^/]+)/[^/]+$', ':cluster/$1'
            return @('ecs', 'describe-services', '--cluster', $cluster, '--services', $Probe.identifier)
        }
        'aws_appautoscaling_policy' { return @('application-autoscaling', 'describe-scaling-policies', '--service-namespace', 'ecs', '--policy-names', $Probe.identifier) }
    }
    throw 'lifecycle.aws.resourceTypeUnsupported'
}

# Classifies a probe response. Denied, throttled or unexpected answers are Unknown: they never prove absence.
function Resolve-AwsLifecycleProbe([hashtable] $Probe, [hashtable] $Response) {
    if ($Response.exitCode -ne 0) {
        $message = [string] $Response.errorText
        if ($message -match 'AccessDenied|UnauthorizedOperation|Throttl|RequestLimitExceeded') { return 'Unknown' }
        if ($Probe.mode -ceq 'CloudControl' -and $message -match 'ResourceNotFoundException') { return 'Missing' }
        if ($Probe.mode -ceq 'Dedicated') {
            switch ($Probe.type) {
                'aws_kms_key' { if ($message -match 'NotFoundException') { return 'Missing' } }
                'aws_ecs_task_definition' { if ($message -match 'ClientException') { return 'Missing' } }
            }
        }
        return 'Unknown'
    }
    if ($Probe.mode -ceq 'CloudControl') { return 'Present' }
    try { $body = $Response.text | ConvertFrom-Json -AsHashtable -Depth 32 } catch { return 'Unknown' }
    switch ($Probe.type) {
        'aws_db_instance' { return $(if (@($body.DBInstances).Count -gt 0) { 'Present' } else { 'Missing' }) }
        'aws_kms_key' { return $(if ($body.KeyMetadata.KeyState -cin @('PendingDeletion', 'PendingReplicaDeletion')) { 'Missing' } else { 'Present' }) }
        'aws_ecs_task_definition' { return $(if ($body.taskDefinition.status -ceq 'ACTIVE') { 'Present' } else { 'Missing' }) }
        'aws_ecs_service' {
            $services = @($body.services)
            if ($services.Count -eq 0 -and @($body.failures | Where-Object reason -CEQ 'MISSING').Count -gt 0) { return 'Missing' }
            if ($services.Count -ne 1) { return 'Unknown' }
            return $(if ($services[0].status -ceq 'INACTIVE') { 'Missing' } else { 'Present' })
        }
        'aws_appautoscaling_policy' { return $(if (@($body.ScalingPolicies).Count -gt 0) { 'Present' } else { 'Missing' }) }
    }
    return 'Unknown'
}

# Runs the probe of a recorded resource with $Aws(arguments) -> { exitCode; text; errorText }.
function Test-AwsLifecycleResource([hashtable] $Inventory, [string] $ResourceId, [scriptblock] $Aws) {
    $parts = Split-AwsLifecycleResourceId $Inventory $ResourceId
    $probe = Get-AwsLifecycleProbe $Inventory $parts.type $parts.id
    while ($probe.mode -ceq 'Parent') { $probe = $probe.parent }
    return Resolve-AwsLifecycleProbe $probe (& $Aws (Get-AwsLifecycleProbeArguments $probe))
}

# Resources of a Terraform state (version 4), with the qualified IDs the lifecycle engine records.
function Read-AwsLifecycleTerraformState([hashtable] $Inventory, [byte[]] $Bytes) {
    try { $state = [Text.Encoding]::UTF8.GetString($Bytes) | ConvertFrom-Json -AsHashtable -Depth 100 } catch { throw 'lifecycle.aws.stateInvalid' }
    if ($state.version -ne 4 -or $state.resources -isnot [Collections.IList]) { throw 'lifecycle.aws.stateInvalid' }
    $items = [Collections.Generic.List[object]]::new()
    foreach ($resource in $state.resources) {
        if ($resource.mode -cne 'managed') { continue }
        if ((Get-AwsLifecycleSupportedTypes) -cnotcontains $resource.type) { throw 'lifecycle.aws.resourceTypeUnsupported' }
        foreach ($instance in $resource.instances) {
            if ($instance.ContainsKey('deposed')) { throw 'lifecycle.aws.deposedStateUnsupported' }
            $address = "$($resource.type).$($resource.name)"
            if ($resource.ContainsKey('module')) { $address = "$($resource.module).$address" }
            if ($instance.ContainsKey('index_key')) { $address += '[' + (ConvertTo-Json -InputObject $instance.index_key -Compress) + ']' }
            $id = [string] $instance.attributes.id
            if (-not $id) { throw 'lifecycle.aws.stateInvalid' }
            $items.Add(@{ id = ConvertTo-AwsLifecycleResourceId $Inventory $resource.type $id; address = $address; type = $resource.type })
        }
    }
    return @{ lineage = $state.lineage; serial = $state.serial; resources = @($items.ToArray()); outputs = $(if ($state.ContainsKey('outputs')) { $state.outputs } else { @{} }) }
}

# Bootstrap-owned resources that carry the instance tags but never belong to a root: the deployment
# role of the reservation and its five policies (aws-ephemeral).
function Get-AwsLifecycleRetainedArns([hashtable] $Inventory) {
    $role = ($Inventory.target.roleArn -split '/')[-1]
    $identity = $role -replace '-deploy$', ''
    return @($Inventory.target.roleArn) + @('state', 'create', 'manage', 'named', 'guardrails' | ForEach-Object { "arn:aws:iam::$($Inventory.target.accountId):policy/$identity-$_" })
}

# ARNs still tagged with the instance, from the pages of tag:GetResources. Bootstrap resources are excluded.
function Get-AwsLifecycleRemaining([hashtable] $Inventory, [object[]] $Pages) {
    $retained = Get-AwsLifecycleRetainedArns $Inventory
    $remaining = [Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    foreach ($page in $Pages) {
        if ($page -isnot [Collections.IDictionary] -or -not $page.ContainsKey('ResourceTagMappingList') -or $page.ResourceTagMappingList -isnot [Collections.IList]) { throw 'lifecycle.aws.scopeIncomplete' }
        foreach ($mapping in $page.ResourceTagMappingList) {
            $arn = [string] $mapping.ResourceARN
            $tag = @($mapping.Tags | Where-Object Key -CEQ 'hexagon:instance')
            if ($tag.Count -ne 1 -or $tag[0].Value -cne $Inventory.instance.id) { throw 'lifecycle.aws.scopeResponseMismatch' }
            $parts = $arn -split ':'
            if ($parts.Count -lt 6 -or $parts[0] -cne 'arn' -or ($parts[4] -and $parts[4] -cne $Inventory.target.accountId)) { throw 'lifecycle.aws.scopeResponseMismatch' }
            if ($retained -cnotcontains $arn) { [void] $remaining.Add($arn) }
        }
    }
    return [string[]] @($remaining)
}

Export-ModuleMember -Function Get-AwsLifecycleSupportedTypes, ConvertTo-AwsLifecycleResourceId, Split-AwsLifecycleResourceId, Get-AwsLifecycleProbe, Get-AwsLifecycleProbeArguments, Resolve-AwsLifecycleProbe, Test-AwsLifecycleResource, Read-AwsLifecycleTerraformState, Get-AwsLifecycleRetainedArns, Get-AwsLifecycleRemaining
