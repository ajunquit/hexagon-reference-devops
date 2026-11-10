Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'EnvironmentLifecycle.psm1')
Import-Module (Join-Path $PSScriptRoot 'PlatformBootstrap.psm1')
Import-Module (Join-Path $PSScriptRoot 'LifecycleNative.psm1')

function Get-LifecycleBytesHash([byte[]] $Bytes) {
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Get-LifecycleAzureToken([hashtable] $Context, [string] $Resource) {
    if ($Context.tokens.ContainsKey($Resource) -and $Context.tokens[$Resource].expires -gt [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 60) { return $Context.tokens[$Resource].value }
    $result = Invoke-LifecycleCommand az @('account', 'get-access-token', '--resource', $Resource, '--subscription', $Context.inventory.target.subscriptionId, '--output', 'json', '--only-show-errors') -TimeoutSeconds 45
    if ($result.exitCode -ne 0) { throw 'lifecycle.azure.tokenUnavailable' }
    try { $token = $result.text | ConvertFrom-Json -AsHashtable; $expires = [long] $token.expires_on }
    catch { throw 'lifecycle.azure.tokenInvalid' }
    if (-not $token.accessToken -or $expires -lt [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 60) { throw 'lifecycle.azure.tokenInvalid' }
    if ($Resource -ceq 'https://management.azure.com/') {
        try {
            $payload = ($token.accessToken -split '[.]')[1].Replace('-', '+').Replace('_', '/')
            $payload = $payload.PadRight($payload.Length + ((4 - $payload.Length % 4) % 4), '=')
            $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json -AsHashtable
            $client = $(if ($claims.ContainsKey('appid')) { $claims.appid } else { $claims.azp })
            if ($client -ine $Context.inventory.target.clientId -or $claims.tid -ine $Context.inventory.target.tenantId -or [guid] $claims.oid -eq [guid]::Empty) { throw 'Invalid token context.' }
            $Context.actorId = $claims.oid
        }
        catch { throw 'lifecycle.azure.tokenContextMismatch' }
    }
    $Context.tokens[$Resource] = @{ value = $token.accessToken; expires = $expires }
    return $token.accessToken
}

function New-AzureLifecycleHttpClient {
    $handler = [Net.Http.HttpClientHandler]::new(); $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler); $client.Timeout = [TimeSpan]::FromSeconds(30)
    return $client
}

function Invoke-AzureLifecycleHttp {
    param([hashtable] $Context, [ValidateSet('GET', 'HEAD', 'PUT')][string] $Method, [string] $Uri, [hashtable] $Headers = @{}, [byte[]] $Bytes = @())
    $address = [uri] $Uri
    $storageHost = "$($Context.inventory.target.storageAccount).blob.core.windows.net"
    $storage = $address.Host -ceq $storageHost
    if ($address.Scheme -cne 'https' -or $address.Port -ne 443 -or $address.UserInfo -or
        (-not $storage -and $address.Host -cne 'management.azure.com')) { throw 'lifecycle.azure.endpointInvalid' }
    if ($storage) {
        if (-not $address.AbsolutePath.StartsWith("/$($Context.inventory.target.container)", [StringComparison]::Ordinal) -or
            ($address.AbsolutePath -cne "/$($Context.inventory.target.container)" -and -not $address.AbsolutePath.StartsWith("/$($Context.inventory.target.container)/", [StringComparison]::Ordinal))) { throw 'lifecycle.azure.endpointInvalid' }
        if ($address.AbsolutePath -cne "/$($Context.inventory.target.container)" -and -not $address.AbsolutePath.StartsWith("/$($Context.inventory.target.container)/$($Context.prefix)/", [StringComparison]::Ordinal)) { throw 'lifecycle.azure.endpointInvalid' }
    }
    else {
        $allowed = @($Context.inventory.roots | Where-Object {
            $prefix = "/subscriptions/$($Context.inventory.target.subscriptionId)/resourceGroups/$($_.resourceGroup)"
            $address.AbsolutePath -ieq $prefix -or $address.AbsolutePath.StartsWith("$prefix/", [StringComparison]::OrdinalIgnoreCase)
        })
        if ($Method -cne 'GET' -or $allowed.Count -ne 1) { throw 'lifecycle.azure.endpointInvalid' }
    }
    $resource = $(if ($storage) { 'https://storage.azure.com/' } else { 'https://management.azure.com/' })
    $token = Get-LifecycleAzureToken $Context $resource
    $client = New-AzureLifecycleHttpClient
    $cancellation = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(30))
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), $address)
    $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token)
    if ($storage) { [void] $request.Headers.TryAddWithoutValidation('x-ms-version', '2023-11-03'); [void] $request.Headers.TryAddWithoutValidation('x-ms-date', [DateTime]::UtcNow.ToString('R')) }
    foreach ($key in $Headers.Keys) { [void] $request.Headers.TryAddWithoutValidation($key, [string] $Headers[$key]) }
    if ($Method -ceq 'PUT') { $request.Content = [Net.Http.ByteArrayContent]::new($Bytes); $request.Content.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::new('application/octet-stream') }
    $response = $null; $stream = $null; $memory = [IO.MemoryStream]::new()
    try {
        $response = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cancellation.Token).GetAwaiter().GetResult()
        $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $buffer = [byte[]]::new(65536)
        while (($count = $stream.ReadAsync($buffer, 0, $buffer.Length, $cancellation.Token).GetAwaiter().GetResult()) -gt 0) {
            $memory.Write($buffer, 0, $count)
            if ($memory.Length -gt 33554432) { throw 'lifecycle.azure.responseTooLarge' }
        }
        $headersOut = @{}; foreach ($header in $response.Headers) { $headersOut[$header.Key] = @($header.Value)[0] }
        return @{ status = [int] $response.StatusCode; headers = $headersOut; bytes = $memory.ToArray() }
    }
    catch {
        if ($_.Exception.Message -cmatch '^lifecycle[.][A-Za-z0-9.]+$') { throw }
        throw 'lifecycle.azure.transportFailed'
    }
    finally { if ($stream) { $stream.Dispose() }; if ($response) { $response.Dispose() }; $memory.Dispose(); $request.Dispose(); $client.Dispose(); $cancellation.Dispose() }
}

function Get-LifecycleBlobUri([hashtable] $Context, [string] $Key) {
    if ($Key -match '[?#%\\\s]|(?:^|/)[.][.]?(?:/|$)') { throw 'lifecycle.azure.blobKeyInvalid' }
    return "https://$($Context.inventory.target.storageAccount).blob.core.windows.net/$($Context.inventory.target.container)/$Key"
}

function Assert-AzureLifecycleAccount([hashtable] $Inventory) {
    Assert-LifecycleCliEnvironment
    $result = Invoke-LifecycleCommand az @('account', 'show', '--output', 'json', '--only-show-errors') -TimeoutSeconds 45
    if ($result.exitCode -ne 0) { throw 'lifecycle.azure.accountUnavailable' }
    $account = $result.text | ConvertFrom-Json -AsHashtable
    if ($account.id -ine $Inventory.target.subscriptionId -or $account.tenantId -ine $Inventory.target.tenantId -or
        $account.environmentName -cne 'AzureCloud' -or $account.state -cne 'Enabled' -or $account.user.type -ine 'servicePrincipal' -or $account.user.name -ine $Inventory.target.clientId) { throw 'lifecycle.azure.accountMismatch' }
}

function New-AzureLifecycleContext([hashtable] $Inventory) {
    Assert-EnvironmentInventory $Inventory
    Assert-AzureLifecycleAccount $Inventory
    $prefix = "$($Inventory.product)/$($Inventory.environment)/$($Inventory.instance.id)"
    return @{ inventory = $Inventory; prefix = $prefix; tokens = @{}; actorId = $null; leaseId = $null; remoteEtag = $null; remoteRevision = -1L; remoteHash = $null }
}

function Enter-AzureLifecycleLease {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([hashtable] $Context)
    if (-not $PSCmdlet.ShouldProcess($Context.prefix, 'Acquire lifecycle lease')) { return }
    $container = Invoke-AzureLifecycleHttp $Context HEAD "https://$($Context.inventory.target.storageAccount).blob.core.windows.net/$($Context.inventory.target.container)?restype=container"
    if ($container.status -ne 200) { throw 'lifecycle.azure.containerUnavailable' }
    $uri = Get-LifecycleBlobUri $Context "$($Context.prefix)/control.json"
    $created = Invoke-AzureLifecycleHttp $Context PUT $uri @{ 'If-None-Match' = '*'; 'x-ms-blob-type' = 'BlockBlob' } ([Text.Encoding]::UTF8.GetBytes('{}'))
    if ($created.status -notin @(201, 409, 412)) { throw 'lifecycle.azure.controlUnavailable' }
    $id = [guid]::NewGuid().ToString()
    $lease = Invoke-AzureLifecycleHttp $Context PUT "$uri`?comp=lease" @{ 'x-ms-lease-action' = 'acquire'; 'x-ms-lease-duration' = '-1'; 'x-ms-proposed-lease-id' = $id }
    if ($lease.status -ne 201 -or $lease.headers['x-ms-lease-id'] -cne $id) { throw 'lifecycle.azure.inventoryLocked' }
    $Context.leaseId = $id
}

function Assert-AzureLifecycleLease {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([hashtable] $Context)
    if (-not $PSCmdlet.ShouldProcess($Context.prefix, 'Check lifecycle lease ownership')) { return }
    if (-not $Context.leaseId) { throw 'lifecycle.azure.leaseRequired' }
    $uri = Get-LifecycleBlobUri $Context "$($Context.prefix)/control.json"
    $response = Invoke-AzureLifecycleHttp $Context PUT "$uri`?comp=lease" @{ 'x-ms-lease-action' = 'renew'; 'x-ms-lease-id' = $Context.leaseId }
    if ($response.status -ne 200) { throw 'lifecycle.azure.leaseLost' }
}

function Exit-AzureLifecycleLease {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([hashtable] $Context)
    if (-not $PSCmdlet.ShouldProcess($Context.prefix, 'Release lifecycle lease')) { return }
    try {
        if ($Context.leaseId) {
            $uri = Get-LifecycleBlobUri $Context "$($Context.prefix)/control.json"
            $response = Invoke-AzureLifecycleHttp $Context PUT "$uri`?comp=lease" @{ 'x-ms-lease-action' = 'release'; 'x-ms-lease-id' = $Context.leaseId }
            if ($response.status -ne 200) { throw 'lifecycle.azure.leaseReleaseFailed' }
        }
    }
    finally { $Context.leaseId = $null; $Context.tokens.Clear() }
}

function Get-AzureLifecycleJournal([hashtable] $Context) {
    Assert-AzureLifecycleLease $Context
    $response = Invoke-AzureLifecycleHttp $Context GET (Get-LifecycleBlobUri $Context "$($Context.prefix)/inventory.json")
    if ($response.status -eq 404) { return $null }
    if ($response.status -ne 200 -or -not $response.headers.ContainsKey('ETag')) { throw 'lifecycle.azure.journalUnavailable' }
    if ($response.bytes.Length -gt 4194304) { throw 'lifecycle.azure.journalInvalid' }
    try { $inventory = [Text.Encoding]::UTF8.GetString($response.bytes) | ConvertFrom-Json -AsHashtable -Depth 32; Assert-EnvironmentInventory $inventory }
    catch { throw 'lifecycle.azure.journalInvalid' }
    $expected = $Context.inventory
    if ($inventory.product -cne $expected.product -or $inventory.environment -cne $expected.environment -or
        (ConvertTo-PlatformBootstrapJson $inventory.instance) -cne (ConvertTo-PlatformBootstrapJson $expected.instance) -or
        (ConvertTo-PlatformBootstrapJson $inventory.target) -cne (ConvertTo-PlatformBootstrapJson $expected.target)) { throw 'lifecycle.azure.journalTargetMismatch' }
    $Context.remoteEtag = $response.headers.ETag; $Context.remoteRevision = $inventory.revision; $Context.remoteHash = Get-LifecycleBytesHash $response.bytes
    return @{ inventory = $inventory; bytes = $response.bytes }
}

function Publish-AzureLifecycleObject {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([hashtable] $Context, [string] $Key, [byte[]] $Bytes, [string] $Sha256)
    if (-not $PSCmdlet.ShouldProcess($Key, 'Publish immutable lifecycle object')) { return }
    Assert-AzureLifecycleLease $Context
    if ((Get-LifecycleBytesHash $Bytes) -cne $Sha256) { throw 'lifecycle.azure.objectHashMismatch' }
    $uri = Get-LifecycleBlobUri $Context $Key
    $write = Invoke-AzureLifecycleHttp $Context PUT $uri @{ 'If-None-Match' = '*'; 'x-ms-blob-type' = 'BlockBlob' } $Bytes
    if ($write.status -notin @(201, 409, 412)) { throw 'lifecycle.azure.objectWriteFailed' }
    $read = Invoke-AzureLifecycleHttp $Context GET $uri
    if ($read.status -ne 200 -or (Get-LifecycleBytesHash $read.bytes) -cne $Sha256) { throw 'lifecycle.azure.objectNotDurable' }
}

function Read-AzureLifecycleObject([hashtable] $Context, [string] $Key, [string] $Sha256) {
    $read = Invoke-AzureLifecycleHttp $Context GET (Get-LifecycleBlobUri $Context $Key)
    if ($read.status -ne 200 -or (Get-LifecycleBytesHash $read.bytes) -cne $Sha256) { throw 'lifecycle.azure.objectUnavailable' }
    return ,$read.bytes
}

function Save-AzureLifecycleJournal {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([hashtable] $Context, [string] $Path)
    if (-not $PSCmdlet.ShouldProcess($Context.prefix, 'Persist lifecycle checkpoint')) { return }
    Assert-AzureLifecycleLease $Context
    $inventory = Read-EnvironmentInventory $Path
    if ($inventory.product -cne $Context.inventory.product -or $inventory.environment -cne $Context.inventory.environment -or
        (ConvertTo-PlatformBootstrapJson $inventory.instance) -cne (ConvertTo-PlatformBootstrapJson $Context.inventory.instance) -or
        (ConvertTo-PlatformBootstrapJson $inventory.target) -cne (ConvertTo-PlatformBootstrapJson $Context.inventory.target) -or
        $inventory.iac.snapshotSha256 -cne $Context.inventory.iac.snapshotSha256) { throw 'lifecycle.azure.journalTargetMismatch' }
    if ($inventory.revision -ne $Context.remoteRevision + 1) { throw 'lifecycle.azure.journalRevisionMismatch' }
    $bytes = [IO.File]::ReadAllBytes($Path); $hash = Get-LifecycleBytesHash $bytes
    $snapshotKey = "$($Context.prefix)/snapshots/$($inventory.iac.snapshotSha256).zip"
    Read-AzureLifecycleObject $Context $snapshotKey $inventory.iac.snapshotSha256 | Out-Null
    $headers = @{ 'x-ms-blob-type' = 'BlockBlob' }
    if ($null -eq $Context.remoteEtag) { $headers['If-None-Match'] = '*' } else { $headers['If-Match'] = $Context.remoteEtag }
    $write = Invoke-AzureLifecycleHttp $Context PUT (Get-LifecycleBlobUri $Context "$($Context.prefix)/inventory.json") $headers $bytes
    if ($write.status -ne 201) { throw 'lifecycle.azure.journalConflict' }
    $read = Get-AzureLifecycleJournal $Context
    if ($Context.remoteHash -cne $hash -or $read.inventory.revision -ne $inventory.revision) { throw 'lifecycle.azure.journalNotDurable' }
    return @{ durable = $true; sha256 = $hash; revision = $inventory.revision; journalKey = "$($Context.prefix)/inventory.json"
        storageAccount = $inventory.target.storageAccount; container = $inventory.target.container; snapshotSha256 = $inventory.iac.snapshotSha256 }
}

Export-ModuleMember -Function New-AzureLifecycleContext, Enter-AzureLifecycleLease, Assert-AzureLifecycleLease, Exit-AzureLifecycleLease, Get-AzureLifecycleJournal, Save-AzureLifecycleJournal, Publish-AzureLifecycleObject, Read-AzureLifecycleObject, Invoke-AzureLifecycleHttp, Get-LifecycleBytesHash
