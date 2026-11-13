Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'EnvironmentLifecycle.psm1')
Import-Module (Join-Path $PSScriptRoot 'PlatformBootstrap.psm1')
Import-Module (Join-Path $PSScriptRoot 'LifecycleNative.psm1')

# Custody of the lifecycle in the S3 state bucket (ADR 0025), with the guarantees of the Azure Blob store:
#   <product>/<environment>/<instance>/control.json      lease, taken and renewed with conditional writes
#   <product>/<environment>/<instance>/inventory.json    journal, written with If-Match on its ETag
#   <product>/<environment>/<instance>/snapshots/<sha>.zip  immutable, written with If-None-Match: *
# S3 has no infinite leases: a lease expires after an hour unless renewed, so a crashed run blocks
# the instance for at most that long. A precondition failure always means someone else holds it.

$script:leaseSeconds = 3600

function Get-AwsLifecycleBytesHash([byte[]] $Bytes) {
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Get-AwsLifecycleKey([hashtable] $Context, [string] $Name) {
    $key = "$($Context.prefix)/$Name"
    if ($Name -match '[?#%\\\s]|(?:^|/)[.][.]?(?:/|$)' -or $key.Length -gt 1024) { throw 'lifecycle.aws.objectKeyInvalid' }
    return $key
}

# The production transport: the AWS CLI with the federated credentials of the workflow. Requests are
# Get(key) -> { status = 200|404; bytes; etag } and Put(key, bytes, ifNoneMatch, ifMatch) -> { status = 200|412; etag }.
# Tests pass their own transport with the same contract.
function Invoke-AwsLifecycleCliObject([hashtable] $Inventory, [string] $Operation, [string] $Key, [byte[]] $Bytes, [bool] $IfNoneMatch, [string] $IfMatch) {
    $bucket = $Inventory.target.stateBucket; $region = $Inventory.target.region
    $directory = Join-Path ([IO.Path]::GetTempPath()) "hexagon-s3-$([guid]::NewGuid().ToString('N'))"
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    try {
        $file = Join-Path $directory 'object'
        if ($Operation -ceq 'Get') {
            $result = Invoke-LifecycleCommand aws @('s3api', 'get-object', '--bucket', $bucket, '--key', $Key, '--region', $region, '--output', 'json', $file) -TimeoutSeconds 120
            if ($result.exitCode -ne 0) {
                if ($result.errorText -match 'NoSuchKey|\(404\)') { return @{ status = 404 } }
                throw 'lifecycle.aws.objectUnavailable'
            }
            return @{ status = 200; bytes = [IO.File]::ReadAllBytes($file); etag = ($result.text | ConvertFrom-Json).ETag }
        }
        [IO.File]::WriteAllBytes($file, $Bytes)
        # The bootstrap bucket policy denies writes without SSE-KMS and its own key.
        $arguments = @('s3api', 'put-object', '--bucket', $bucket, '--key', $Key, '--body', $file, '--server-side-encryption', 'aws:kms', '--ssekms-key-id', $Inventory.target.stateKmsKeyArn, '--region', $region, '--output', 'json')
        if ($IfNoneMatch) { $arguments += @('--if-none-match', '*') } elseif ($IfMatch) { $arguments += @('--if-match', $IfMatch) }
        $result = Invoke-LifecycleCommand aws $arguments -TimeoutSeconds 120
        if ($result.exitCode -ne 0) {
            if ($result.errorText -match 'PreconditionFailed|ConditionalRequestConflict|\(412\)|\(409\)') { return @{ status = 412 } }
            throw 'lifecycle.aws.objectWriteFailed'
        }
        return @{ status = 200; etag = ($result.text | ConvertFrom-Json).ETag }
    }
    finally { Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue }
}

# The federated identity must be the deployment role of the inventory, in its account.
function Assert-AwsLifecycleCaller([hashtable] $Inventory, [string] $CallerArn, [string] $Account) {
    $role = ($Inventory.target.roleArn -split '/')[-1]
    if ($Account -cne $Inventory.target.accountId -or $CallerArn -cnotmatch "^arn:aws:sts::$($Inventory.target.accountId):assumed-role/$([regex]::Escape($role))/[A-Za-z0-9+=,.@_-]+$") { throw 'lifecycle.aws.accountMismatch' }
}

# A null transport uses the AWS CLI; tests pass a double with the same contract.
function New-AwsLifecycleContext([hashtable] $Inventory, [string] $CallerArn, [string] $Account, [scriptblock] $Transport = $null) {
    Assert-EnvironmentInventory $Inventory
    if (-not $Inventory.target.ContainsKey('accountId')) { throw 'lifecycle.aws.targetRequired' }
    Assert-AwsLifecycleCaller $Inventory $CallerArn $Account
    $prefix = "$($Inventory.product)/$($Inventory.environment)/$($Inventory.instance.id)"
    return @{ inventory = $Inventory; prefix = $prefix; transport = $Transport; leaseId = $null; leaseEtag = $null; remoteEtag = $null; remoteRevision = -1L; remoteHash = $null }
}

function Invoke-AwsLifecycleObject([hashtable] $Context, [string] $Operation, [string] $Key, [byte[]] $Bytes = $null, [bool] $IfNoneMatch = $false, [string] $IfMatch = $null) {
    try {
        $response = $(if ($null -eq $Context.transport) { Invoke-AwsLifecycleCliObject $Context.inventory $Operation $Key $Bytes $IfNoneMatch $IfMatch }
            else { & $Context.transport $Operation $Key $Bytes $IfNoneMatch $IfMatch })
    }
    catch { if ($_.Exception.Message -cmatch '^lifecycle[.][A-Za-z0-9.]+$') { throw }; throw 'lifecycle.aws.objectUnavailable' }
    if ($null -eq $response -or $response -isnot [Collections.IDictionary] -or $response.status -notin @(200, 404, 412)) { throw 'lifecycle.aws.objectUnavailable' }
    return $response
}

function New-AwsLeaseBytes([string] $LeaseId, [long] $ExpiresAt) {
    return [Text.Encoding]::UTF8.GetBytes((ConvertTo-PlatformBootstrapJson @{ leaseId = $LeaseId; expiresAt = $ExpiresAt }))
}

function Enter-AwsLifecycleLease {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([hashtable] $Context)
    if (-not $PSCmdlet.ShouldProcess($Context.prefix, 'Acquire lifecycle lease')) { return }
    $key = Get-AwsLifecycleKey $Context 'control.json'
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $id = [guid]::NewGuid().ToString()
    $bytes = New-AwsLeaseBytes $id ($now + $script:leaseSeconds)
    $current = Invoke-AwsLifecycleObject $Context Get $key
    if ($current.status -eq 404) { $write = Invoke-AwsLifecycleObject $Context Put $key $bytes $true }
    else {
        try { $lease = [Text.Encoding]::UTF8.GetString($current.bytes) | ConvertFrom-Json -AsHashtable }
        catch { throw 'lifecycle.aws.controlInvalid' }
        if ($lease.leaseId -and $lease.expiresAt -gt $now) { throw 'lifecycle.aws.inventoryLocked' }
        $write = Invoke-AwsLifecycleObject $Context Put $key $bytes $false $current.etag
    }
    if ($write.status -ne 200 -or -not $write.etag) { throw 'lifecycle.aws.inventoryLocked' }
    $Context.leaseId = $id; $Context.leaseEtag = $write.etag
}

function Assert-AwsLifecycleLease {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([hashtable] $Context)
    if (-not $PSCmdlet.ShouldProcess($Context.prefix, 'Renew lifecycle lease')) { return }
    if (-not $Context.leaseId) { throw 'lifecycle.aws.leaseRequired' }
    $key = Get-AwsLifecycleKey $Context 'control.json'
    $bytes = New-AwsLeaseBytes $Context.leaseId ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + $script:leaseSeconds)
    $write = Invoke-AwsLifecycleObject $Context Put $key $bytes $false $Context.leaseEtag
    if ($write.status -ne 200 -or -not $write.etag) { throw 'lifecycle.aws.leaseLost' }
    $Context.leaseEtag = $write.etag
}

function Exit-AwsLifecycleLease {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([hashtable] $Context)
    if (-not $PSCmdlet.ShouldProcess($Context.prefix, 'Release lifecycle lease')) { return }
    try {
        if ($Context.leaseId) {
            $write = Invoke-AwsLifecycleObject $Context Put (Get-AwsLifecycleKey $Context 'control.json') (New-AwsLeaseBytes '' 0) $false $Context.leaseEtag
            if ($write.status -ne 200) { throw 'lifecycle.aws.leaseReleaseFailed' }
        }
    }
    finally { $Context.leaseId = $null; $Context.leaseEtag = $null }
}

function Assert-AwsLifecycleJournalTarget([hashtable] $Context, [hashtable] $Inventory) {
    $expected = $Context.inventory
    if ($Inventory.product -cne $expected.product -or $Inventory.environment -cne $expected.environment -or
        (ConvertTo-PlatformBootstrapJson $Inventory.instance) -cne (ConvertTo-PlatformBootstrapJson $expected.instance) -or
        (ConvertTo-PlatformBootstrapJson $Inventory.target) -cne (ConvertTo-PlatformBootstrapJson $expected.target)) { throw 'lifecycle.aws.journalTargetMismatch' }
}

function Get-AwsLifecycleJournal([hashtable] $Context) {
    Assert-AwsLifecycleLease $Context
    $response = Invoke-AwsLifecycleObject $Context Get (Get-AwsLifecycleKey $Context 'inventory.json')
    if ($response.status -eq 404) { return $null }
    if ($response.status -ne 200 -or -not $response.etag) { throw 'lifecycle.aws.journalUnavailable' }
    if ($response.bytes.Length -gt 4194304) { throw 'lifecycle.aws.journalInvalid' }
    try { $inventory = [Text.Encoding]::UTF8.GetString($response.bytes) | ConvertFrom-Json -AsHashtable -Depth 32; Assert-EnvironmentInventory $inventory }
    catch { throw 'lifecycle.aws.journalInvalid' }
    Assert-AwsLifecycleJournalTarget $Context $inventory
    $Context.remoteEtag = $response.etag; $Context.remoteRevision = $inventory.revision; $Context.remoteHash = Get-AwsLifecycleBytesHash $response.bytes
    return @{ inventory = $inventory; bytes = $response.bytes }
}

# A raw object of the instance prefix, such as a Terraform state: { status = 200|404; bytes; etag }.
function Get-AwsLifecycleStoredObject([hashtable] $Context, [string] $Name) {
    return Invoke-AwsLifecycleObject $Context Get (Get-AwsLifecycleKey $Context $Name)
}

# A mutable object of the instance prefix (such as the delivery journal), written with If-None-Match
# when new or If-Match on its ETag: { status = 200|412; etag }.
function Write-AwsLifecycleStoredObject([hashtable] $Context, [string] $Name, [byte[]] $Bytes, [string] $Etag) {
    Assert-AwsLifecycleLease $Context -Confirm:$false
    if ($Etag) { return Invoke-AwsLifecycleObject $Context Put (Get-AwsLifecycleKey $Context $Name) $Bytes $false $Etag }
    return Invoke-AwsLifecycleObject $Context Put (Get-AwsLifecycleKey $Context $Name) $Bytes $true
}

function Publish-AwsLifecycleObject {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([hashtable] $Context, [string] $Name, [byte[]] $Bytes, [string] $Sha256)
    if (-not $PSCmdlet.ShouldProcess($Name, 'Publish immutable lifecycle object')) { return }
    Assert-AwsLifecycleLease $Context
    if ((Get-AwsLifecycleBytesHash $Bytes) -cne $Sha256) { throw 'lifecycle.aws.objectHashMismatch' }
    $key = Get-AwsLifecycleKey $Context $Name
    Invoke-AwsLifecycleObject $Context Put $key $Bytes $true | Out-Null
    # Written now or by an earlier attempt: either way, the stored bytes must be exactly these.
    Read-AwsLifecycleObject $Context $Name $Sha256 | Out-Null
}

function Read-AwsLifecycleObject([hashtable] $Context, [string] $Name, [string] $Sha256) {
    $read = Invoke-AwsLifecycleObject $Context Get (Get-AwsLifecycleKey $Context $Name)
    if ($read.status -ne 200 -or (Get-AwsLifecycleBytesHash $read.bytes) -cne $Sha256) { throw 'lifecycle.aws.objectUnavailable' }
    return , $read.bytes
}

function Save-AwsLifecycleJournal {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([hashtable] $Context, [string] $Path)
    if (-not $PSCmdlet.ShouldProcess($Context.prefix, 'Persist lifecycle checkpoint')) { return }
    Assert-AwsLifecycleLease $Context
    $inventory = Read-EnvironmentInventory $Path
    Assert-AwsLifecycleJournalTarget $Context $inventory
    if ($inventory.iac.snapshotSha256 -cne $Context.inventory.iac.snapshotSha256) { throw 'lifecycle.aws.journalTargetMismatch' }
    if ($inventory.revision -ne $Context.remoteRevision + 1) { throw 'lifecycle.aws.journalRevisionMismatch' }
    $bytes = [IO.File]::ReadAllBytes($Path); $hash = Get-AwsLifecycleBytesHash $bytes
    Read-AwsLifecycleObject $Context "snapshots/$($inventory.iac.snapshotSha256).zip" $inventory.iac.snapshotSha256 | Out-Null
    $key = Get-AwsLifecycleKey $Context 'inventory.json'
    $write = $(if ($null -eq $Context.remoteEtag) { Invoke-AwsLifecycleObject $Context Put $key $bytes $true } else { Invoke-AwsLifecycleObject $Context Put $key $bytes $false $Context.remoteEtag })
    if ($write.status -ne 200) { throw 'lifecycle.aws.journalConflict' }
    $read = Get-AwsLifecycleJournal $Context
    if ($Context.remoteHash -cne $hash -or $read.inventory.revision -ne $inventory.revision) { throw 'lifecycle.aws.journalNotDurable' }
    return @{ durable = $true; sha256 = $hash; revision = $inventory.revision; journalKey = $key; stateBucket = $inventory.target.stateBucket; snapshotSha256 = $inventory.iac.snapshotSha256 }
}

Export-ModuleMember -Function Get-AwsLifecycleStoredObject, Write-AwsLifecycleStoredObject, New-AwsLifecycleContext, Assert-AwsLifecycleCaller, Enter-AwsLifecycleLease, Assert-AwsLifecycleLease, Exit-AwsLifecycleLease, Get-AwsLifecycleJournal, Save-AwsLifecycleJournal, Publish-AwsLifecycleObject, Read-AwsLifecycleObject, Get-AwsLifecycleBytesHash
