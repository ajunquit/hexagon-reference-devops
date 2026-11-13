<#
.SYNOPSIS
    Exercises the lifecycle engine with an AWS target (ADR 0025) through a protocol double, never cloud.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$rootDirectory = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $rootDirectory 'scripts/EnvironmentLifecycle.psm1') -Force
$template = Get-Content -Raw -LiteralPath (Join-Path $rootDirectory 'examples/environment-inventory-aws.json')
$parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
$temporary = Join-Path $parent "hexagon-lifecycle-aws-tests-$([guid]::NewGuid().ToString('N'))"
[IO.Directory]::CreateDirectory($temporary) | Out-Null
$script:assertions = 0
function Assert-True([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message }; $script:assertions++ }
function Assert-Rejected([scriptblock] $Action, [string] $Code) {
    try { & $Action | Out-Null }
    catch { Assert-True ($_.Exception.Message -like "*$Code*") "Unexpected rejection: $($_.Exception.Message)"; return }
    throw "Expected rejection: $Code"
}
function Get-Fixture { return $template | ConvertFrom-Json -AsHashtable }
function Get-Plan([object[]] $Changes) { return @{ format_version = '1.2'; errored = $false; complete = $true; resource_changes = $Changes } }
function New-Change([string] $Type, [hashtable] $After, [string] $Action = 'create', [hashtable] $Before = $null) {
    return @{ address = "$Type.test"; type = $Type; mode = 'managed'; change = @{ actions = @($Action); before = $Before; after = $After } }
}
$tags = @{ 'hexagon:product' = 'hexagon-template'; 'hexagon:environment' = 'dev'; 'hexagon:instance' = 'run-12345-1' }
$vpcId = 'aws:123456789012:us-east-1:aws_vpc:vpc-0123456789abcdef0'

$script:states = @{}
$script:foreignBucket = $false
$port = {
    param($request)
    $id = $request.root.id
    switch ($request.action) {
        'Preflight' {
            return @{ verified = $true; accountId = $request.target.accountId; region = $request.target.region; roleArn = $request.target.roleArn
                stateBucket = $(if ($script:foreignBucket) { 'other-bucket' } else { $request.target.stateBucket })
                product = $request.product; environment = $request.environment; instanceId = $request.instanceId
                configurationSha256 = $request.root.configurationSha256; inputsSha256 = $request.root.inputsSha256
                iacSnapshotSha256 = 'a' * 64; stateKey = $request.root.stateKey; planVerified = $true
                binarySha256 = $(if ($null -ne $request.root.plan) { $request.root.plan.binarySha256 } else { $null })
                jsonSha256 = $(if ($null -ne $request.root.plan) { $request.root.plan.jsonSha256 } else { $null }) }
        }
        'Persist' {
            return @{ durable = $true; sha256 = $request.sha256; revision = $request.revision; stateBucket = $request.target.stateBucket
                journalKey = "$($request.product)/$($request.environment)/$($request.instanceId)/inventory.json"; snapshotSha256 = 'a' * 64 }
        }
        'DestructionSafety' { return @{ quiesced = $true; evidenceSha256 = 'c' * 64; backupVerified = $true
            product = $request.product; environment = $request.environment; instanceId = $request.instanceId; rootId = $request.root.id } }
        'Apply' {
            if (-not $script:states.ContainsKey($id)) { $script:states[$id] = @{ serial = 0; resources = @() } }
            $state = $script:states[$id]; $state.serial++
            if ($request.operation -ceq 'Create') { $state.resources = @(@{ id = $vpcId; address = 'aws_vpc.test'; type = 'aws_vpc' }) } else { $state.resources = @() }
            return @{ exitCode = 0 }
        }
        'Observe' {
            $state = $script:states[$id]
            $all = @{}; foreach ($resource in @($request.root.resources) + @($state.resources)) { $all[$resource.id] = $resource }
            $probes = @($all.Keys | ForEach-Object { @{ id = $_; status = $(if (@($state.resources | Where-Object id -CEQ $_).Count -gt 0) { 'Present' } else { 'Missing' }) } })
            return @{ stateStatus = 'Present'; scopeAccessible = $true; scopeComplete = $true; lineage = '44444444-4444-4444-4444-444444444444'
                serial = $state.serial; resources = $state.resources; probes = $probes; configurationConverged = $true; remainingResourceIds = @() }
        }
        default { throw 'Unexpected lifecycle port action.' }
    }
}
function Invoke-Operation([string] $Path, [string] $Operation, [object[]] $Changes) {
    $inventory = Read-EnvironmentInventory $Path
    $binary = Join-Path ([IO.Path]::GetDirectoryName($Path)) "hosting-$Operation.tfplan"
    [IO.File]::WriteAllText($binary, "test-binary-$([guid]::NewGuid().ToString('N'))")
    [IO.File]::WriteAllText("$binary.json", ((Get-Plan $Changes) | ConvertTo-Json -Depth 32))
    $review = Add-EnvironmentRootPlan -InventoryPath $Path -RootId hosting -Operation $Operation -BinaryPath $binary -JsonPath "$binary.json" -ExpectedInventorySha256 (Get-LifecycleFileHash $Path)
    Invoke-EnvironmentRootOperation -InventoryPath $Path -RootId hosting -BinaryPath $binary -JsonPath "$binary.json" -ReviewSha256 $review `
        -Confirmation "$($Operation.ToUpperInvariant()) $($inventory.product) $($inventory.environment) $($inventory.instance.id)" -Port $port | Out-Null
    return Read-EnvironmentInventory $Path
}

try {
    $inventory = Get-Fixture
    Assert-EnvironmentInventory $inventory; $script:assertions++
    Assert-True ((@(Get-EnvironmentRootOrder $inventory Destroy) -join ',') -ceq 'messaging,hosting') 'Destroy order was not reversed.'

    # Boundaries of an AWS instance.
    foreach ($case in @(
        @{ Code = 'lifecycle.prefixBoundary'; Mutation = { param($i) $i.roots[0].namePrefix = 'tpl-dev-000000'; $i.roots[1].namePrefix = 'tpl-dev-000000' } },
        @{ Code = 'lifecycle.prefixBoundary'; Mutation = { param($i) $i.roots[1].namePrefix = 'other-e1c8fa' } },
        @{ Code = 'lifecycle.prefixBoundary'; Mutation = { param($i) $i.roots[0].namePrefix = 'tpl-dev'; $i.roots[1].namePrefix = 'tpl-dev' } },
        @{ Code = 'lifecycle.inventoryInvalid'; Mutation = { param($i) $i.roots[1].adapter = 'AzureServiceBus' } },
        @{ Code = 'lifecycle.targetInvalid'; Mutation = { param($i) $i.target.roleArn = 'arn:aws:iam::210987654321:role/foreign' } },
        @{ Code = 'lifecycle.targetInvalid'; Mutation = { param($i) $i.target.stateKmsKeyArn = 'arn:aws:kms:eu-west-1:123456789012:key/11111111-2222-3333-4444-555555555555' } },
        @{ Code = 'lifecycle.inventoryInvalid'; Mutation = { param($i) $i.roots[0].resourceGroup = 'rg-hexagon-template-dev-run-12345-1-hosting' } },
        @{ Code = 'lifecycle.inventoryInvalid'; Mutation = { param($i) $i.target.secretAccessKey = 'never-log-this-secret' } }
    )) {
        $bad = Get-Fixture; & $case.Mutation $bad
        Assert-Rejected { Assert-EnvironmentInventory $bad } $case.Code
    }
    $persistent = Get-Fixture; $persistent.instance = @{ kind = 'Persistent'; id = 'persistent' }; $persistent.dataPolicy = 'BackupRequired'
    foreach ($root in $persistent.roots) { $root.namePrefix = 'tpl-dev'; $root.stateKey = $root.stateKey.Replace('run-12345-1', 'persistent') }
    Assert-EnvironmentInventory $persistent; $script:assertions++

    # Recorded resources must stay in the account and region, outside the bootstrap.
    foreach ($case in @(
        @{ Id = 'aws:210987654321:us-east-1:aws_vpc:vpc-1'; Type = 'aws_vpc'; Code = 'lifecycle.resourceOutsideScope' },
        @{ Id = 'aws:123456789012:eu-west-1:aws_vpc:vpc-1'; Type = 'aws_vpc'; Code = 'lifecycle.resourceOutsideScope' },
        @{ Id = 'aws:123456789012:us-east-1:aws_iam_openid_connect_provider:x'; Type = 'aws_iam_openid_connect_provider'; Code = 'lifecycle.resourceOutsideScope' },
        @{ Id = 'aws:123456789012:us-east-1:aws_s3_bucket:hexagon-template-tfstate-123456789012'; Type = 'aws_s3_bucket'; Code = 'lifecycle.bootstrapProtected' },
        @{ Id = 'aws:123456789012:us-east-1:aws_iam_role:hexagon-template-dev-run-12345-1-deploy'; Type = 'aws_iam_role'; Code = 'lifecycle.bootstrapProtected' }
    )) {
        $bad = Get-Fixture
        $bad.roots[0].status = 'Failed'; $bad.roots[0].lastOperation = 'Create'; $bad.roots[0].stateLineage = '44444444-4444-4444-4444-444444444444'; $bad.roots[0].stateSerial = 1
        $bad.roots[0].resources = @(@{ id = $case.Id; address = "$($case.Type).test"; type = $case.Type; presence = 'Present'; current = $true })
        Assert-Rejected { Assert-EnvironmentInventory $bad } $case.Code
    }

    # Plans: AWS types only, tagged for this instance, with ARNs of this account and region.
    $hosting = $inventory.roots[0]
    Assert-EnvironmentTerraformPlan $inventory $hosting Create (Get-Plan @(New-Change aws_vpc @{ tags_all = $tags })); $script:assertions++
    Assert-EnvironmentTerraformPlan $inventory $hosting Create (Get-Plan @(New-Change aws_cloudfront_function @{ arn = 'arn:aws:cloudfront::123456789012:function/x' })); $script:assertions++
    foreach ($case in @(
        @{ Code = 'lifecycle.planScopeMismatch'; Change = (New-Change aws_vpc @{ tags_all = @{ 'hexagon:product' = 'hexagon-template'; 'hexagon:environment' = 'dev'; 'hexagon:instance' = 'run-99-1' } }) },
        @{ Code = 'lifecycle.planScopeMismatch'; Change = (New-Change aws_vpc @{ tags_all = @{} }) },
        @{ Code = 'lifecycle.planScopeMismatch'; Change = (New-Change aws_sqs_queue @{ arn = 'arn:aws:sqs:us-east-1:210987654321:queue' }) },
        @{ Code = 'lifecycle.planScopeMismatch'; Change = (New-Change aws_sqs_queue @{ arn = 'arn:aws:sqs:eu-west-1:123456789012:queue' }) },
        @{ Code = 'lifecycle.planResourceForbidden'; Change = (New-Change aws_iam_openid_connect_provider @{}) },
        @{ Code = 'lifecycle.planResourceForbidden'; Change = (New-Change azurerm_virtual_network @{}) },
        @{ Code = 'lifecycle.planResourceUnrecorded'; Change = (New-Change aws_vpc $null 'delete' @{ id = 'vpc-unknown' }) }
    )) {
        $operation = $(if ($case.Change.change.actions[0] -ceq 'delete') { 'Destroy' } else { 'Create' })
        Assert-Rejected { Assert-EnvironmentTerraformPlan $inventory $hosting $operation (Get-Plan @($case.Change)) } $case.Code
    }

    # A full Create and Destroy of the hosting root through the AWS port contract.
    $directory = Join-Path $temporary 'cycle'; [IO.Directory]::CreateDirectory($directory) | Out-Null
    $path = Join-Path $directory 'inventory.json'
    $hostingOnly = Get-Fixture; $hostingOnly.roots = @($hostingOnly.roots[0])
    New-EnvironmentInventory $hostingOnly $path | Out-Null
    $created = Invoke-Operation $path Create @(New-Change aws_vpc @{ tags_all = $tags })
    $root = @($created.roots | Where-Object id -CEQ 'hosting')[0]
    Assert-True ($root.status -ceq 'Verified' -and $root.resources[0].id -ceq $vpcId -and $root.resources[0].presence -ceq 'Present') 'AWS Create did not verify the qualified resource.'
    $destroyed = Invoke-Operation $path Destroy @(New-Change aws_vpc $null 'delete' @{ id = 'vpc-0123456789abcdef0' })
    $root = @($destroyed.roots | Where-Object id -CEQ 'hosting')[0]
    Assert-True ($root.status -ceq 'Destroyed' -and $root.resources[0].presence -ceq 'Missing' -and -not $root.resources[0].current) 'AWS Destroy did not prove absence.'

    # The preflight must report this target's state bucket.
    $directory = Join-Path $temporary 'foreign'; [IO.Directory]::CreateDirectory($directory) | Out-Null
    $path = Join-Path $directory 'inventory.json'
    New-EnvironmentInventory (Get-Fixture) $path | Out-Null
    $script:foreignBucket = $true
    Assert-Rejected { Invoke-Operation $path Create @(New-Change aws_vpc @{ tags_all = $tags }) } 'lifecycle.preflightMismatch'
    $script:foreignBucket = $false
}
finally {
    Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "AWS environment lifecycle tests passed: $($script:assertions) assertions; protocol double, no cloud changes."
