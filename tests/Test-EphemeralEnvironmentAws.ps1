<#
.SYNOPSIS
    Checks the AWS ephemeral reservation contract, plan, state bucket and isolation diagnostic offline (ADR 0025).
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repository 'scripts/EphemeralEnvironment.psm1') -Force
Import-Module (Join-Path $repository 'scripts/AwsEphemeralEnvironment.psm1') -Force
Import-Module (Join-Path $repository 'scripts/PlatformBootstrap.psm1')
$script:assertions = 0
function Assert-True([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message }; $script:assertions++ }
function Assert-Rejected([scriptblock] $Action, [string] $Code) {
    try { & $Action | Out-Null }
    catch { Assert-True ($_.Exception.Message -like "*$Code*") "Unexpected rejection: $($_.Exception.Message)"; return }
    throw "Expected rejection: $Code"
}
$examplePath = Join-Path $repository 'examples/ephemeral-environment-aws.json'
function Copy-Value([object] $Value) { return (ConvertTo-PlatformBootstrapJson $Value) | ConvertFrom-Json -AsHashtable -Depth 64 }
$temporary = Join-Path ([IO.Path]::GetTempPath()) "hexagon-ephemeral-aws-$([guid]::NewGuid().ToString('N'))"
[IO.Directory]::CreateDirectory($temporary) | Out-Null
function Read-Mutated([scriptblock] $Mutation) {
    $value = Copy-Value $definition; & $Mutation $value
    $path = Join-Path $temporary "$([guid]::NewGuid().ToString('N')).json"
    [IO.File]::WriteAllText($path, (ConvertTo-PlatformBootstrapJson $value))
    return Read-EphemeralEnvironment $path
}

try {
    $definition = Read-EphemeralEnvironment $examplePath
    Assert-True ((Get-AwsEphemeralNamePrefix $definition) -ceq 'tpl-dev-e1c8fa') 'The reservation prefix must follow the engine rule.'
    $bindings = Get-EphemeralGithubBindings $definition
    Assert-True ((@($bindings.Keys) -join ',') -ceq 'AWS_ROLE_ARN,AWS_REGION,AWS_ACCOUNT_ID' -and $bindings.AWS_ROLE_ARN -ceq $definition.inventory.target.roleArn) 'GitHub must hold the AWS bindings of the reservation.'
    Assert-EphemeralSelection $definition dev run-12345-1 Destroy; $script:assertions++

    # Boundaries of the definition.
    foreach ($case in @(
        @{ Code = 'boundaryInvalid'; Mutation = { param($d) $d.inventory.target.roleArn = 'arn:aws:iam::123456789012:role/another-role' } },
        @{ Code = 'boundaryInvalid'; Mutation = { param($d) $d.namePrefixBase = 'other' } },
        @{ Code = 'boundaryInvalid'; Mutation = { param($d) $d.workloadBoundaryArn = 'arn:aws:iam::210987654321:policy/hexagon-workload-boundary' } },
        @{ Code = 'boundaryInvalid'; Mutation = { param($d) $d.stateKmsKeyArn = 'arn:aws:kms:eu-west-1:123456789012:key/11111111-2222-3333-4444-555555555555' } },
        @{ Code = 'boundaryInvalid'; Mutation = { param($d) $d.oidcPrefix = 'repo:example-owner/hexagon-other-devops' } },
        @{ Code = 'protectedScopeInvalid'; Mutation = { param($d) $d.protectedNamePrefixes = @('tpl-dev-e1c8fa') } },
        @{ Code = 'definitionInvalid'; Mutation = { param($d) $d.location = 'eastus2' } },
        @{ Code = 'definitionInvalid'; Mutation = { param($d) $d.Remove('workloadBoundaryArn') } }
    )) { Assert-Rejected { Read-Mutated $case.Mutation } $case.Code }

    # The reservation plan may only create the role and its policies.
    $change = { param($type, $actions) @{ address = "$type.x"; type = $type; mode = 'managed'; change = @{ actions = $actions } } }
    $plan = @{ format_version = '1.2'; complete = $true; errored = $false; resource_changes = @((& $change aws_iam_role @('create')), (& $change aws_iam_policy @('create')), (& $change aws_iam_role_policy_attachment @('no-op'))) }
    Assert-AwsEphemeralReservationPlan $plan; $script:assertions++
    foreach ($bad in @((& $change aws_vpc @('create')), (& $change aws_iam_role @('update')), (& $change aws_iam_role @('delete', 'create')))) {
        Assert-Rejected { Assert-AwsEphemeralReservationPlan @{ format_version = '1.2'; complete = $true; errored = $false; resource_changes = @($bad) } } 'reservationChangeForbidden'
    }
    $imported = & $change aws_iam_role @('create'); $imported.change.importing = @{ id = 'existing' }
    Assert-Rejected { Assert-AwsEphemeralReservationPlan @{ format_version = '1.2'; complete = $true; errored = $false; resource_changes = @($imported) } } 'reservationChangeForbidden'

    # The state bucket protects every state before a reservation writes into it.
    $encryption = @{ ServerSideEncryptionConfiguration = @{ Rules = @(@{ ApplyServerSideEncryptionByDefault = @{ SSEAlgorithm = 'aws:kms'; KMSMasterKeyID = $definition.stateKmsKeyArn } }) } }
    $versioning = @{ Status = 'Enabled' }
    $public = @{ PublicAccessBlockConfiguration = @{ BlockPublicAcls = $true; IgnorePublicAcls = $true; BlockPublicPolicy = $true; RestrictPublicBuckets = $true } }
    Assert-AwsEphemeralStateBucket $definition $encryption $versioning $public; $script:assertions++
    Assert-Rejected { Assert-AwsEphemeralStateBucket $definition $encryption @{ Status = 'Suspended' } $public } 'storageNotProtected'
    $otherKey = Copy-Value $encryption; $otherKey.ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.KMSMasterKeyID = 'alias/aws/s3'
    Assert-Rejected { Assert-AwsEphemeralStateBucket $definition $otherKey $versioning $public } 'storageNotProtected'
    $open = Copy-Value $public; $open.PublicAccessBlockConfiguration.RestrictPublicBuckets = $false
    Assert-Rejected { Assert-AwsEphemeralStateBucket $definition $encryption $versioning $open } 'storageNotProtected'

    # Isolation: every expected allow and deny, from the federated role of the reservation only.
    $cases = Get-AwsEphemeralIsolationCases $definition
    Assert-True ($cases.Count -eq 23 -and @($cases | Where-Object expected -CEQ 'allowed').Count -eq 4) 'The diagnostic must cover own scopes and every protected neighbour.'
    Assert-True (@($cases | Where-Object { $_.id -ceq 'role.own.unbounded' -and $_.expected -ceq 'denied' }).Count -eq 1) 'A role without the workload boundary must be denied.'
    $caller = 'arn:aws:sts::123456789012:assumed-role/hexagon-template-dev-run-12345-1-deploy/GitHubActions'
    $faithful = { param($roleArn, $list) $result = @{}; foreach ($case in $list) { $result[$case.id] = $(if ($case.expected -ceq 'allowed') { 'allowed' } else { 'implicitDeny' }) }; return $result }
    $verified = Test-AwsEphemeralIsolation $definition $caller $faithful
    Assert-True ($verified.status -ceq 'Verified' -and $verified.applicationVerified -eq $false) 'A faithful simulation must verify isolation without claiming the application.'
    $leaky = { param($roleArn, $list) $result = & $faithful $roleArn $list; $result['state.bootstrap'] = 'allowed'; return $result }
    Assert-Rejected { Test-AwsEphemeralIsolation $definition $caller $leaky } 'isolationNotVerified'
    $partial = { param($roleArn, $list) $result = & $faithful $roleArn $list; $result.Remove('create.foreign.tag'); return $result }
    Assert-Rejected { Test-AwsEphemeralIsolation $definition $caller $partial } 'isolationNotVerified'
    $unknown = { param($roleArn, $list) $result = & $faithful $roleArn $list; $result['secret.tpl-prd'] = 'unknown'; return $result }
    Assert-Rejected { Test-AwsEphemeralIsolation $definition $caller $unknown } 'isolationNotVerified'
    Assert-Rejected { Test-AwsEphemeralIsolation $definition 'arn:aws:sts::123456789012:assumed-role/operator/session' $faithful } 'identityMismatch'
    Assert-Rejected { Test-AwsEphemeralIsolation $definition 'arn:aws:iam::123456789012:user/operator' $faithful } 'identityMismatch'
}
finally { Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host "AWS ephemeral reservation tests passed: $($script:assertions) assertions; no cloud calls."
