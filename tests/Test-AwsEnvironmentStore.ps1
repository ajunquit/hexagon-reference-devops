<#
.SYNOPSIS
    Exercises the S3 custody of the AWS lifecycle (ADR 0025) with an in-memory S3 that honours conditional writes.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repository 'scripts/AwsEnvironmentStore.psm1') -Force
Import-Module (Join-Path $repository 'scripts/EnvironmentLifecycle.psm1')
Import-Module (Join-Path $repository 'scripts/PlatformBootstrap.psm1')
$script:assertions = 0
function Assert-True([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message }; $script:assertions++ }
function Assert-Rejected([scriptblock] $Action, [string] $Code) {
    try { & $Action | Out-Null }
    catch { Assert-True ($_.Exception.Message -like "*$Code*") "Unexpected rejection: $($_.Exception.Message)"; return }
    throw "Expected rejection: $Code"
}
$inventory = Get-Content -Raw -LiteralPath (Join-Path $repository 'examples/environment-inventory-aws.json') | ConvertFrom-Json -AsHashtable -Depth 32
$caller = 'arn:aws:sts::123456789012:assumed-role/hexagon-template-dev-run-12345-1-deploy/GitHubActions'
$prefix = 'hexagon-template/dev/run-12345-1'

# An S3 bucket in memory: Put honours If-None-Match: * and If-Match, and each write gets a new ETag.
$script:objects = @{}
$s3 = {
    param($operation, $key, $bytes, $ifNoneMatch, $ifMatch)
    if ($operation -ceq 'Get') {
        if (-not $script:objects.ContainsKey($key)) { return @{ status = 404 } }
        return @{ status = 200; bytes = $script:objects[$key].bytes; etag = $script:objects[$key].etag }
    }
    $exists = $script:objects.ContainsKey($key)
    if (($ifNoneMatch -and $exists) -or ($ifMatch -and (-not $exists -or $script:objects[$key].etag -cne $ifMatch))) { return @{ status = 412 } }
    $etag = '"' + [guid]::NewGuid().ToString('N') + '"'
    $script:objects[$key] = @{ bytes = $bytes; etag = $etag }
    return @{ status = 200; etag = $etag }
}
function New-Context { return New-AwsLifecycleContext $inventory $caller '123456789012' $s3 }
$temporary = Join-Path ([IO.Path]::GetTempPath()) "hexagon-aws-store-$([guid]::NewGuid().ToString('N'))"
[IO.Directory]::CreateDirectory($temporary) | Out-Null

try {
    # Only the federated deployment role of this inventory may hold its custody.
    Assert-Rejected { New-AwsLifecycleContext $inventory 'arn:aws:sts::123456789012:assumed-role/operator/session' '123456789012' $s3 } 'lifecycle.aws.accountMismatch'
    Assert-Rejected { New-AwsLifecycleContext $inventory $caller '210987654321' $s3 } 'lifecycle.aws.accountMismatch'
    $azure = Get-Content -Raw -LiteralPath (Join-Path $repository 'examples/environment-inventory.json') | ConvertFrom-Json -AsHashtable -Depth 32
    Assert-Rejected { New-AwsLifecycleContext $azure $caller '123456789012' $s3 } 'lifecycle.aws.targetRequired'

    # One holder at a time; renewal changes the ETag and a stale holder loses the lease.
    $first = New-Context; $second = New-Context
    Enter-AwsLifecycleLease $first -Confirm:$false
    Assert-Rejected { Enter-AwsLifecycleLease $second -Confirm:$false } 'lifecycle.aws.inventoryLocked'
    $etag = $first.leaseEtag
    Assert-AwsLifecycleLease $first -Confirm:$false
    Assert-True ($first.leaseEtag -cne $etag) 'Renewal must rewrite the lease conditionally.'
    $second.leaseId = 'forged'; $second.leaseEtag = $etag
    Assert-Rejected { Assert-AwsLifecycleLease $second -Confirm:$false } 'lifecycle.aws.leaseLost'
    $second.leaseId = $null; $second.leaseEtag = $null

    # An expired lease may be taken over; its former holder then loses it.
    $control = "$prefix/control.json"
    & $s3 Put $control ([Text.Encoding]::UTF8.GetBytes((ConvertTo-PlatformBootstrapJson @{ leaseId = $first.leaseId; expiresAt = 1 }))) $false $first.leaseEtag | Out-Null
    Enter-AwsLifecycleLease $second -Confirm:$false
    Assert-Rejected { Assert-AwsLifecycleLease $first -Confirm:$false } 'lifecycle.aws.leaseLost'
    Exit-AwsLifecycleLease $second -Confirm:$false
    Assert-True ($null -eq $second.leaseId) 'Release must forget the lease.'
    $first = New-Context
    Enter-AwsLifecycleLease $first -Confirm:$false; $script:assertions++

    # Immutable snapshots: exact bytes only.
    $snapshot = [Text.Encoding]::UTF8.GetBytes('snapshot-bytes')
    $snapshotHash = Get-AwsLifecycleBytesHash $snapshot
    Assert-Rejected { Publish-AwsLifecycleObject $first "snapshots/$snapshotHash.zip" $snapshot ('0' * 64) -Confirm:$false } 'lifecycle.aws.objectHashMismatch'
    Assert-Rejected { Publish-AwsLifecycleObject $first '../escape.zip' $snapshot $snapshotHash -Confirm:$false } 'lifecycle.aws.objectKeyInvalid'
    Publish-AwsLifecycleObject $first "snapshots/$snapshotHash.zip" $snapshot $snapshotHash -Confirm:$false
    Publish-AwsLifecycleObject $first "snapshots/$snapshotHash.zip" $snapshot $snapshotHash -Confirm:$false; $script:assertions++
    $other = [Text.Encoding]::UTF8.GetBytes('other-bytes')
    $script:objects["$prefix/snapshots/conflict.zip"] = @{ bytes = $snapshot; etag = '"x"' }
    Assert-Rejected { Publish-AwsLifecycleObject $first 'snapshots/conflict.zip' $other (Get-AwsLifecycleBytesHash $other) -Confirm:$false } 'lifecycle.aws.objectUnavailable'

    # The journal: absent at first, then written with If-None-Match, then with If-Match on its ETag.
    Assert-True ($null -eq (Get-AwsLifecycleJournal $first)) 'A new instance has no journal.'
    $model = Get-Content -Raw -LiteralPath (Join-Path $repository 'examples/environment-inventory-aws.json') | ConvertFrom-Json -AsHashtable -Depth 32
    $model.iac.snapshotSha256 = $snapshotHash
    $first.inventory = $model
    $path = Join-Path $temporary 'inventory.json'
    [IO.File]::WriteAllText($path, (ConvertTo-PlatformBootstrapJson $model))
    $saved = Save-AwsLifecycleJournal $first $path -Confirm:$false
    Assert-True ($saved.durable -and $saved.revision -eq 0 -and $saved.journalKey -ceq "$prefix/inventory.json" -and $saved.stateBucket -ceq $model.target.stateBucket) 'The first checkpoint must be durable in this bucket.'
    $model.revision = 1; [IO.File]::WriteAllText($path, (ConvertTo-PlatformBootstrapJson $model))
    $script:objects["$prefix/inventory.json"].etag = '"concurrent"'
    Assert-Rejected { Save-AwsLifecycleJournal $first $path -Confirm:$false } 'lifecycle.aws.journalConflict'
    Get-AwsLifecycleJournal $first | Out-Null
    $model.revision = 5; [IO.File]::WriteAllText($path, (ConvertTo-PlatformBootstrapJson $model))
    Assert-Rejected { Save-AwsLifecycleJournal $first $path -Confirm:$false } 'lifecycle.aws.journalRevisionMismatch'
    $foreign = Get-Content -Raw -LiteralPath (Join-Path $repository 'examples/environment-inventory-aws.json') | ConvertFrom-Json -AsHashtable -Depth 32
    $foreign.target.stateBucket = 'another-bucket'
    $script:objects["$prefix/inventory.json"].bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-PlatformBootstrapJson $foreign))
    Assert-Rejected { Get-AwsLifecycleJournal $first } 'lifecycle.aws.journalTargetMismatch'
    Exit-AwsLifecycleLease $first -Confirm:$false
    Assert-Rejected { Get-AwsLifecycleJournal $first } 'lifecycle.aws.leaseRequired'
}
finally { Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host "AWS lifecycle custody tests passed: $($script:assertions) assertions; in-memory S3, no cloud calls."
