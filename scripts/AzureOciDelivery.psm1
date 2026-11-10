Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AzureEnvironmentStore.psm1')
Import-Module (Join-Path $PSScriptRoot 'LifecycleNative.psm1')

function New-AcrDeliveryHttpClient {
    $handler = [Net.Http.HttpClientHandler]::new(); $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler); $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
    return $client
}

function Invoke-AcrDeliveryHttp {
    param([hashtable] $Context, [string] $Server, [string] $Method, [string] $Path, [string] $Token,
        [byte[]] $Bytes = @(), [string] $File, [string] $ContentType = 'application/octet-stream')
    if ($Server -cnotmatch '^[a-z0-9]{5,50}[.]azurecr[.]io$' -or $Method -cnotin @('HEAD', 'POST', 'PUT') -or
        $Path -cnotmatch '^/(oauth2/token|v2/[a-z0-9:._/-]+(?:[?][A-Za-z0-9%_.~=&:+/-]+)?)$' -or
        $Path -match '/[.][.]?(?:/|$)|//' -or $Path -match '%(?![0-9A-Fa-f]{2})') { throw 'lifecycle.delivery.registryEndpointInvalid' }
    Assert-AzureLifecycleLease $Context
    $client = New-AcrDeliveryHttpClient; $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), "https://$Server$Path")
    $response = $null; $stream = $null; $memory = [IO.MemoryStream]::new()
    $cancel = [Threading.CancellationTokenSource]::new([TimeSpan]::FromMinutes(15))
    try {
        if ($Token) { $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Token) }
        if ($Method -cne 'HEAD') {
            $request.Content = $(if ($File) { [Net.Http.StreamContent]::new([IO.File]::OpenRead($File)) } else { [Net.Http.ByteArrayContent]::new($Bytes) })
            $request.Content.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::new($ContentType)
        }
        $task = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cancel.Token)
        while (-not $task.Wait(10000)) { Assert-AzureLifecycleLease $Context }
        $response = $task.GetAwaiter().GetResult()
        $stream = $response.Content.ReadAsStreamAsync($cancel.Token).GetAwaiter().GetResult()
        $buffer = [byte[]]::new(65536)
        while (($count = $stream.ReadAsync($buffer, 0, $buffer.Length, $cancel.Token).GetAwaiter().GetResult()) -gt 0) {
            $memory.Write($buffer, 0, $count)
            if ($memory.Length -gt 1MB) { throw 'lifecycle.delivery.registryResponseTooLarge' }
        }
        $headers = @{}; foreach ($header in $response.Headers) { $headers[$header.Key] = @($header.Value)[0] }
        return @{ status = [int] $response.StatusCode; headers = $headers; bytes = $memory.ToArray() }
    }
    catch {
        if ($_.Exception.Message -cmatch '^lifecycle[.][A-Za-z0-9.]+$') { throw }
        throw 'lifecycle.delivery.registryTransportFailed'
    }
    finally { if ($stream) { $stream.Dispose() }; if ($response) { $response.Dispose() }; $request.Dispose(); $memory.Dispose(); $cancel.Dispose(); $client.Dispose() }
}

function Get-AcrDeliveryToken([hashtable] $Context, [string] $Server, [string] $Repository) {
    $name = $Server.Split('.')[0]
    $native = Invoke-LifecycleCommand az @('acr', 'login', '--name', $name, '--expose-token', '--subscription', $Context.inventory.target.subscriptionId, '--output', 'json', '--only-show-errors') -TimeoutSeconds 60
    if ($native.exitCode -ne 0) { throw 'lifecycle.delivery.registryCredentialUnavailable' }
    $login = $native.text | ConvertFrom-Json -AsHashtable
    if ($login.loginServer -cne $Server -or -not $login.accessToken) { throw 'lifecycle.delivery.registryCredentialInvalid' }
    $form = 'grant_type=refresh_token&service=' + [uri]::EscapeDataString($Server) + '&scope=' + [uri]::EscapeDataString("repository:${Repository}:pull,push") + '&refresh_token=' + [uri]::EscapeDataString($login.accessToken)
    $response = Invoke-AcrDeliveryHttp $Context $Server POST '/oauth2/token' '' ([Text.Encoding]::UTF8.GetBytes($form)) -ContentType 'application/x-www-form-urlencoded'
    if ($response.status -ne 200) { throw 'lifecycle.delivery.registryTokenUnavailable' }
    $access = [Text.Encoding]::UTF8.GetString($response.bytes) | ConvertFrom-Json -AsHashtable
    if (-not $access.access_token) { throw 'lifecycle.delivery.registryTokenInvalid' }
    return $access.access_token
}

function Publish-AzureOciArchive {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([hashtable] $Context, [hashtable] $Image, [string] $Server)
    if (-not $PSCmdlet.ShouldProcess($Image.target.image, 'Copy verified OCI bytes to the instance registry')) { return }
    if ($Image.target.image -cne "$Server/$($Image.target.repository)@$($Image.target.digest)" -or
        $Image.target.repository -cnotmatch '^[a-z0-9]+(?:[._-][a-z0-9]+)*(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)*$' -or
        $Image.target.digest -cnotmatch '^sha256:[0-9a-f]{64}$' -or (Get-FileHash -LiteralPath $Image.file -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Image.sha256) { throw 'lifecycle.delivery.imageChanged' }
    $metadata = & (Join-Path $PSScriptRoot 'Get-OciArchiveMetadata.ps1') $Image.file
    if ($metadata.imageDigest -cne $Image.target.digest -or $metadata.platform -cne 'linux/amd64') { throw 'lifecycle.delivery.imageChanged' }
    $directory = Join-Path $Context.runtime "oci-$([guid]::NewGuid().ToString('N'))"
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $file = [IO.File]::OpenRead($Image.file)
    $first = $file.ReadByte(); $second = $file.ReadByte(); $file.Position = 0
    $stream = $(if ($first -eq 0x1f -and $second -eq 0x8b) { [IO.Compression.GZipStream]::new($file, [IO.Compression.CompressionMode]::Decompress) } else { $file })
    $tar = [System.Formats.Tar.TarReader]::new($stream)
    try {
        while ($null -ne ($entry = $tar.GetNextEntry())) {
            if ($entry.Name -cmatch '^blobs/sha256/([0-9a-f]{64})$') {
                $destination = [IO.File]::Open((Join-Path $directory $Matches[1]), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
                try { $entry.DataStream.CopyTo($destination) } finally { $destination.Dispose() }
            }
        }
    }
    finally { $tar.Dispose(); $stream.Dispose(); $file.Dispose() }
    $digest = $Image.target.digest; $repository = $Image.target.repository
    $manifestPath = Join-Path $directory $digest.Substring(7)
    $manifestBytes = [IO.File]::ReadAllBytes($manifestPath)
    $manifest = [Text.Encoding]::UTF8.GetString($manifestBytes) | ConvertFrom-Json -AsHashtable
    $token = Get-AcrDeliveryToken $Context $Server $repository
    foreach ($descriptor in @($manifest.config) + @($manifest.layers)) {
        $head = Invoke-AcrDeliveryHttp $Context $Server HEAD "/v2/$repository/blobs/$($descriptor.digest)" $token
        if ($head.status -eq 200) {
            if ($head.headers['Docker-Content-Digest'] -cne $descriptor.digest) { throw 'lifecycle.delivery.registryDigestMismatch' }
            continue
        }
        if ($head.status -ne 404) { throw 'lifecycle.delivery.registryBlobUnavailable' }
        $start = Invoke-AcrDeliveryHttp $Context $Server POST "/v2/$repository/blobs/uploads/" $token
        if ($start.status -ne 202 -or -not $start.headers.ContainsKey('Location')) { throw 'lifecycle.delivery.registryUploadUnavailable' }
        $address = [uri]::new([uri] "https://$Server/", [string] $start.headers.Location)
        if ($address.Scheme -cne 'https' -or $address.Host -cne $Server -or $address.Port -ne 443 -or $address.UserInfo -or $address.Fragment -or
            -not $address.AbsolutePath.StartsWith("/v2/$repository/blobs/uploads/", [StringComparison]::Ordinal)) { throw 'lifecycle.delivery.registryUploadEndpointInvalid' }
        $path = $address.PathAndQuery + $(if ($address.Query) { '&' } else { '?' }) + 'digest=' + [uri]::EscapeDataString($descriptor.digest)
        $blob = Join-Path $directory $descriptor.digest.Substring(7)
        if ((Get-FileHash -LiteralPath $blob -Algorithm SHA256).Hash.ToLowerInvariant() -cne $descriptor.digest.Substring(7)) { throw 'lifecycle.delivery.imageChanged' }
        $write = Invoke-AcrDeliveryHttp $Context $Server PUT $path $token -File $blob
        if ($write.status -ne 201 -or $write.headers['Docker-Content-Digest'] -cne $descriptor.digest) { throw 'lifecycle.delivery.registryBlobNotDurable' }
    }
    $write = Invoke-AcrDeliveryHttp $Context $Server PUT "/v2/$repository/manifests/$digest" $token $manifestBytes -ContentType 'application/vnd.oci.image.manifest.v1+json'
    if ($write.status -ne 201 -or $write.headers['Docker-Content-Digest'] -cne $digest) { throw 'lifecycle.delivery.registryManifestNotDurable' }
    $head = Invoke-AcrDeliveryHttp $Context $Server HEAD "/v2/$repository/manifests/$digest" $token
    if ($head.status -ne 200 -or $head.headers['Docker-Content-Digest'] -cne $digest) { throw 'lifecycle.delivery.registryDigestMismatch' }
    return @{ image = $Image.target.image; digest = $digest; archiveSha256 = $Image.sha256 }
}

function Assert-AzureOciImages([hashtable] $Context, [hashtable] $References, [string] $Server) {
    foreach ($reference in $References.Values) {
        $token = Get-AcrDeliveryToken $Context $Server $reference.repository
        $head = Invoke-AcrDeliveryHttp $Context $Server HEAD "/v2/$($reference.repository)/manifests/$($reference.digest)" $token
        if ($head.status -ne 200 -or $head.headers['Docker-Content-Digest'] -cne $reference.digest) { throw 'lifecycle.delivery.registryDigestMismatch' }
    }
}

Export-ModuleMember -Function Publish-AzureOciArchive, Assert-AzureOciImages
