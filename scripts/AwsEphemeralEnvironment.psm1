Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# AWS side of the ephemeral reservation (ADR 0025): pure checks over the definition, the reservation plan,
# the state bucket and the isolation diagnostic. Native calls stay in the scripts that use them.

function Get-AwsEphemeralNamePrefix([hashtable] $Definition) {
    $inventory = $Definition.inventory
    $bytes = [Text.Encoding]::UTF8.GetBytes("$($inventory.product)/$($inventory.environment)/$($inventory.instance.id)")
    return "$($Definition.namePrefixBase)-" + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant().Substring(0, 6)
}

function Get-AwsEphemeralRoleName([hashtable] $Definition) {
    $inventory = $Definition.inventory
    return "$($inventory.product)-$($inventory.environment)-$($inventory.instance.id)-deploy"
}

function Assert-AwsEphemeralDefinition([hashtable] $Definition) {
    $inventory = $Definition.inventory
    $target = $inventory.target
    $account = $target.accountId
    $prefix = Get-AwsEphemeralNamePrefix $Definition
    $role = Get-AwsEphemeralRoleName $Definition
    if ($inventory.instance.kind -cne 'Ephemeral' -or $inventory.environment -cnotin @('dev', 'staging') -or $inventory.dataPolicy -cne 'DeleteEphemeral' -or
        $role.Length -gt 64 -or $target.roleArn -cne "arn:aws:iam::$($account):role/$role" -or
        ($Definition.oidcPrefix -replace '^repo:', '' -replace '@[0-9]+', '') -cne $inventory.iac.repository -or
        @($inventory.roots | Where-Object { $_.namePrefix -cne $prefix }).Count -gt 0) { throw 'lifecycle.ephemeral.boundaryInvalid' }
    foreach ($arn in @($Definition.githubOidcProviderArn, $Definition.workloadBoundaryArn, $Definition.stateKmsKeyArn)) {
        if (($arn -split ':')[4] -cne $account) { throw 'lifecycle.ephemeral.boundaryInvalid' }
    }
    if (($Definition.stateKmsKeyArn -split ':')[3] -cne $target.region -or $Definition.stateKmsKeyArn -cne $target.stateKmsKeyArn) { throw 'lifecycle.ephemeral.boundaryInvalid' }
    # The diagnostic proves denial on real neighbours, such as the persistent prefixes; never on this
    # instance. Permissions use "<prefix>-*", so a persistent base like tpl-dev stays outside tpl-dev-e1c8fa.
    if (@($Definition.protectedNamePrefixes | Where-Object { $_ -ceq $prefix -or $_.StartsWith("$prefix-", [StringComparison]::Ordinal) }).Count -gt 0) { throw 'lifecycle.ephemeral.protectedScopeInvalid' }
}

function Get-AwsEphemeralGithubBindings([hashtable] $Definition) {
    $target = $Definition.inventory.target
    return [ordered] @{ AWS_ROLE_ARN = $target.roleArn; AWS_REGION = $target.region; AWS_ACCOUNT_ID = $target.accountId }
}

function Assert-AwsEphemeralReservationPlan([hashtable] $Plan) {
    if ($Plan.format_version -cnotmatch '^1[.]' -or $Plan.complete -isnot [bool] -or $Plan.complete -ne $true -or $Plan.errored -isnot [bool] -or $Plan.errored -ne $false) { throw 'lifecycle.ephemeral.reservationChangeForbidden' }
    foreach ($key in @('deferred_changes', 'deferred_action_invocations', 'action_invocations')) { if ($Plan.ContainsKey($key) -and @($Plan[$key]).Count -gt 0) { throw 'lifecycle.ephemeral.reservationChangeForbidden' } }
    $changes = @()
    if ($Plan.ContainsKey('resource_changes')) {
        if ($Plan.resource_changes -isnot [Collections.IList]) { throw 'lifecycle.ephemeral.reservationChangeForbidden' }
        $changes = $Plan.resource_changes
    }
    foreach ($change in $changes) {
        if ($change.mode -ceq 'data') { continue }
        if ($change.mode -cne 'managed' -or $change.change.actions -isnot [Collections.IList] -or $change.change.actions.Count -eq 0 -or
            $change.type -cnotin @('aws_iam_role', 'aws_iam_policy', 'aws_iam_role_policy_attachment') -or
            @($change.change.actions | Where-Object { $_ -cnotin @('create', 'no-op') }).Count -gt 0 -or
            ($change.change.ContainsKey('importing') -and $null -ne $change.change.importing)) { throw 'lifecycle.ephemeral.reservationChangeForbidden' }
    }
}

# The bootstrap bucket must already protect every state: KMS with its key, versioning and no public access.
function Assert-AwsEphemeralStateBucket([hashtable] $Definition, [hashtable] $Encryption, [hashtable] $Versioning, [hashtable] $PublicAccess) {
    $rules = @($Encryption.ServerSideEncryptionConfiguration.Rules)
    $block = $PublicAccess.PublicAccessBlockConfiguration
    if ($rules.Count -ne 1 -or $rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm -cne 'aws:kms' -or
        $rules[0].ApplyServerSideEncryptionByDefault.KMSMasterKeyID -cne $Definition.stateKmsKeyArn -or $Versioning.Status -cne 'Enabled' -or
        $block.BlockPublicAcls -ne $true -or $block.IgnorePublicAcls -ne $true -or $block.BlockPublicPolicy -ne $true -or $block.RestrictPublicBuckets -ne $true) { throw 'lifecycle.ephemeral.storageNotProtected' }
}

# Cases the federated identity must be allowed or denied. They are evaluated with
# iam:SimulatePrincipalPolicy, so the diagnostic never creates, changes or deletes anything.
function Get-AwsEphemeralIsolationCases([hashtable] $Definition) {
    $inventory = $Definition.inventory
    $target = $inventory.target
    $account = $target.accountId; $region = $target.region
    $prefix = Get-AwsEphemeralNamePrefix $Definition
    $statePath = "$($inventory.product)/$($inventory.environment)/$($inventory.instance.id)"
    $own = @{ 'aws:RequestTag/hexagon:instance' = $inventory.instance.id; 'aws:RequestTag/hexagon:product' = $inventory.product; 'aws:RequestTag/hexagon:name-prefix' = $prefix }
    $foreign = @{ 'aws:RequestTag/hexagon:instance' = 'persistent'; 'aws:RequestTag/hexagon:product' = $inventory.product }
    $cases = [Collections.Generic.List[hashtable]]::new()
    $cases.Add(@{ id = 'state.own.write'; expected = 'allowed'; action = 's3:PutObject'; resource = "arn:aws:s3:::$($target.stateBucket)/$statePath/hosting.tfstate"; context = @{} })
    $cases.Add(@{ id = 'create.own.tagged'; expected = 'allowed'; action = 'ec2:CreateVpc'; resource = '*'; context = $own })
    $cases.Add(@{ id = 'manage.own.tagged'; expected = 'allowed'; action = 'ec2:DeleteVpc'; resource = "arn:aws:ec2:$($region):$($account):vpc/vpc-own"; context = @{ 'aws:ResourceTag/hexagon:instance' = $inventory.instance.id } })
    $cases.Add(@{ id = 'role.own.bounded'; expected = 'allowed'; action = 'iam:CreateRole'; resource = "arn:aws:iam::$($account):role/$prefix-api"; context = @{ 'iam:PermissionsBoundary' = $Definition.workloadBoundaryArn; 'aws:RequestTag/hexagon:instance' = $inventory.instance.id; 'aws:RequestTag/hexagon:name-prefix' = $prefix } })
    foreach ($environment in @('dev', 'staging', 'prod')) {
        $cases.Add(@{ id = "state.$environment.persistent"; expected = 'denied'; action = 's3:GetObject'; resource = "arn:aws:s3:::$($target.stateBucket)/$($inventory.product)/$environment/persistent/hosting.tfstate"; context = @{} })
    }
    $cases.Add(@{ id = 'state.bootstrap'; expected = 'denied'; action = 's3:GetObject'; resource = "arn:aws:s3:::$($target.stateBucket)/bootstrap/aws-access.tfstate"; context = @{} })
    $cases.Add(@{ id = 'create.foreign.tag'; expected = 'denied'; action = 'ec2:CreateVpc'; resource = '*'; context = $foreign })
    $cases.Add(@{ id = 'manage.foreign.tagged'; expected = 'denied'; action = 'ec2:DeleteVpc'; resource = "arn:aws:ec2:$($region):$($account):vpc/vpc-other"; context = @{ 'aws:ResourceTag/hexagon:instance' = 'persistent' } })
    $cases.Add(@{ id = 'retag.own.to.foreign'; expected = 'denied'; action = 'iam:TagRole'; resource = "arn:aws:iam::$($account):role/$prefix-api"; context = @{ 'aws:RequestTag/hexagon:instance' = 'persistent' } })
    $cases.Add(@{ id = 'role.own.unbounded'; expected = 'denied'; action = 'iam:CreateRole'; resource = "arn:aws:iam::$($account):role/$prefix-api"; context = @{ 'aws:RequestTag/hexagon:instance' = $inventory.instance.id; 'aws:RequestTag/hexagon:name-prefix' = $prefix } })
    $cases.Add(@{ id = 'static.credentials'; expected = 'denied'; action = 'iam:CreateUser'; resource = "arn:aws:iam::$($account):user/$prefix-user"; context = @{} })
    $cases.Add(@{ id = 'reservation.self'; expected = 'denied'; action = 'iam:UpdateAssumeRolePolicy'; resource = $target.roleArn; context = @{} })
    foreach ($protected in $Definition.protectedNamePrefixes) {
        $cases.Add(@{ id = "role.$protected"; expected = 'denied'; action = 'iam:DeleteRole'; resource = "arn:aws:iam::$($account):role/$protected-maintenance"; context = @{} })
        $cases.Add(@{ id = "queue.$protected"; expected = 'denied'; action = 'sqs:DeleteQueue'; resource = "arn:aws:sqs:$($region):$($account):$protected-queue"; context = @{} })
        $cases.Add(@{ id = "secret.$protected"; expected = 'denied'; action = 'secretsmanager:GetSecretValue'; resource = "arn:aws:secretsmanager:$($region):$($account):secret:$protected/database/api"; context = @{} })
    }
    return $cases.ToArray()
}

# Decisions come from SimulatePrincipalPolicy: allowed, explicitDeny or implicitDeny. Anything else,
# a missing case or a different principal, never counts as isolation.
function Test-AwsEphemeralIsolation([hashtable] $Definition, [string] $CallerArn, [scriptblock] $Simulate) {
    $target = $Definition.inventory.target
    $role = Get-AwsEphemeralRoleName $Definition
    if ($CallerArn -cnotmatch "^arn:aws:sts::$($target.accountId):assumed-role/$([regex]::Escape($role))/[A-Za-z0-9+=,.@_-]+$") { throw 'lifecycle.ephemeral.identityMismatch' }
    $cases = Get-AwsEphemeralIsolationCases $Definition
    $decisions = & $Simulate $target.roleArn $cases
    if ($null -eq $decisions -or $decisions -isnot [Collections.IDictionary]) { throw 'lifecycle.ephemeral.isolationNotVerified' }
    foreach ($case in $cases) {
        if (-not $decisions.Contains($case.id)) { throw 'lifecycle.ephemeral.isolationNotVerified' }
        $decision = [string] $decisions[$case.id]
        $passed = $(if ($case.expected -ceq 'allowed') { $decision -ceq 'allowed' } else { $decision -cin @('explicitDeny', 'implicitDeny') })
        if (-not $passed) { throw "lifecycle.ephemeral.isolationNotVerified" }
    }
    return @{ apiVersion = 'hexagon.ec/ephemeral-isolation-result/v1'; status = 'Verified'; instanceId = $Definition.inventory.instance.id; applicationVerified = $false }
}

Export-ModuleMember -Function Get-AwsEphemeralNamePrefix, Get-AwsEphemeralRoleName, Assert-AwsEphemeralDefinition, Get-AwsEphemeralGithubBindings, Assert-AwsEphemeralReservationPlan, Assert-AwsEphemeralStateBucket, Get-AwsEphemeralIsolationCases, Test-AwsEphemeralIsolation
