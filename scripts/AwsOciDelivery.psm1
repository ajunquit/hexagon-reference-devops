Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'TerraformAwsLifecycle.psm1')

# Copies verified OCI archives into the ECR repositories of the instance, by digest (ADR 0025), with
# the OCI distribution protocol that the Azure delivery uses against ACR. Only authentication differs:
# ECR takes Basic credentials from ecr get-login-password. $Context.registryHttp may be a test double
# with the contract (method, server, path, authorization, bytes, file, contentType) -> { status; headers }.

function Invoke-AwsRegistryHttp {
    param([hashtable] $Context, [string] $Server, [string] $Method, [string] $Path, [string] $Authorization,
        [byte[]] $Body = $null, [string] $File = '', [string] $ContentType = 'application/octet-stream')
    if ($Server -cnotmatch '^[0-9]{12}[.]dkr[.]ecr[.][a-z0-9-]+[.]amazonaws[.]com$' -or $Path -cnotmatch '^/v2/[a-z0-9:._/-]+(?:[?][A-Za-z0-9%_.~=&:+/-]+)?$') { throw 'lifecycle.delivery.registryRequestInvalid' }
    if ($Context.ContainsKey('registryHttp') -and $null -ne $Context.registryHttp) { return & $Context.registryHttp $Method $Server $Path $Authorization $Body $File $ContentType }
    $handler = [Net.Http.HttpClientHandler]::new(); $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler); $client.Timeout = [TimeSpan]::FromMinutes(15)
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), "https://$Server$Path")
    $request.Headers.TryAddWithoutValidation('Authorization', $Authorization) | Out-Null
    $request.Headers.Accept.ParseAdd('application/vnd.oci.image.manifest.v1+json')
    $stream = $null
    try {
        if ($File) { $stream = [IO.File]::OpenRead($File); $request.Content = [Net.Http.StreamContent]::new($stream) }
        elseif ($null -ne $Body) { $request.Content = [Net.Http.ByteArrayContent]::new($Body) }
        if ($null -ne $request.Content) { $request.Content.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::Parse($ContentType) }
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $headers = @{}
        foreach ($header in @($response.Headers) + @($response.Content.Headers)) { $headers[$header.Key] = ($header.Value -join ',') }
        return @{ status = [int] $response.StatusCode; headers = $headers }
    }
    catch { throw 'lifecycle.delivery.registryUnavailable' }
    finally { if ($null -ne $stream) { $stream.Dispose() }; $request.Dispose(); $client.Dispose() }
}

function Get-AwsRegistryAuthorization([hashtable] $Context) {
    $login = Invoke-AwsLifecycleCli $Context @('ecr', 'get-login-password')
    $password = ([string] $login.text).Trim().Trim('"')
    if ($login.exitCode -ne 0 -or -not $password) { throw 'lifecycle.delivery.registryCredentialInvalid' }
    return 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("AWS:$password"))
}

# The registry of the instance: <account>.dkr.ecr.<region>.amazonaws.com, from the inventory target.
function Get-AwsRegistryServer([hashtable] $Context) {
    return "$($Context.inventory.target.accountId).dkr.ecr.$($Context.inventory.target.region).amazonaws.com"
}

function Publish-AwsOciArchive {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([hashtable] $Context, [hashtable] $Image, [string] $Server)
    if (-not $PSCmdlet.ShouldProcess($Image.target.image, 'Copy verified OCI bytes to the instance registry')) { return }
    $prefix = $Context.inventory.roots[0].namePrefix
    if ($Server -cne (Get-AwsRegistryServer $Context) -or $Image.target.image -cne "$Server/$($Image.target.repository)@$($Image.target.digest)" -or
        -not $Image.target.repository.StartsWith("$prefix/", [StringComparison]::Ordinal) -or
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
    $manifestBytes = [IO.File]::ReadAllBytes((Join-Path $directory $digest.Substring(7)))
    $manifest = [Text.Encoding]::UTF8.GetString($manifestBytes) | ConvertFrom-Json -AsHashtable
    $authorization = Get-AwsRegistryAuthorization $Context
    foreach ($descriptor in @($manifest.config) + @($manifest.layers)) {
        $head = Invoke-AwsRegistryHttp $Context $Server HEAD "/v2/$repository/blobs/$($descriptor.digest)" $authorization
        if ($head.status -eq 200) {
            if ($head.headers['Docker-Content-Digest'] -cne $descriptor.digest) { throw 'lifecycle.delivery.registryDigestMismatch' }
            continue
        }
        if ($head.status -ne 404) { throw 'lifecycle.delivery.registryBlobUnavailable' }
        $start = Invoke-AwsRegistryHttp $Context $Server POST "/v2/$repository/blobs/uploads/" $authorization
        if ($start.status -ne 202 -or -not $start.headers.ContainsKey('Location')) { throw 'lifecycle.delivery.registryUploadUnavailable' }
        $address = [uri]::new([uri] "https://$Server/", [string] $start.headers.Location)
        if ($address.Scheme -cne 'https' -or $address.Host -cne $Server -or $address.Port -ne 443 -or $address.UserInfo -or $address.Fragment -or
            -not $address.AbsolutePath.StartsWith("/v2/$repository/blobs/uploads/", [StringComparison]::Ordinal)) { throw 'lifecycle.delivery.registryUploadEndpointInvalid' }
        $path = $address.PathAndQuery + $(if ($address.Query) { '&' } else { '?' }) + 'digest=' + [uri]::EscapeDataString($descriptor.digest)
        $blob = Join-Path $directory $descriptor.digest.Substring(7)
        if ((Get-FileHash -LiteralPath $blob -Algorithm SHA256).Hash.ToLowerInvariant() -cne $descriptor.digest.Substring(7)) { throw 'lifecycle.delivery.imageChanged' }
        $write = Invoke-AwsRegistryHttp $Context $Server PUT $path $authorization -File $blob
        if ($write.status -ne 201 -or $write.headers['Docker-Content-Digest'] -cne $descriptor.digest) { throw 'lifecycle.delivery.registryBlobNotDurable' }
    }
    $write = Invoke-AwsRegistryHttp $Context $Server PUT "/v2/$repository/manifests/$digest" $authorization $manifestBytes -ContentType 'application/vnd.oci.image.manifest.v1+json'
    if ($write.status -ne 201 -or $write.headers['Docker-Content-Digest'] -cne $digest) { throw 'lifecycle.delivery.registryManifestNotDurable' }
    $head = Invoke-AwsRegistryHttp $Context $Server HEAD "/v2/$repository/manifests/$digest" $authorization
    if ($head.status -ne 200 -or $head.headers['Docker-Content-Digest'] -cne $digest) { throw 'lifecycle.delivery.registryDigestMismatch' }
    return @{ image = $Image.target.image; digest = $digest; archiveSha256 = $Image.sha256 }
}

function Assert-AwsOciImages([hashtable] $Context, [hashtable] $References, [string] $Server) {
    $authorization = Get-AwsRegistryAuthorization $Context
    foreach ($reference in $References.Values) {
        $head = Invoke-AwsRegistryHttp $Context $Server HEAD "/v2/$($reference.repository)/manifests/$($reference.digest)" $authorization
        if ($head.status -ne 200 -or $head.headers['Docker-Content-Digest'] -cne $reference.digest) { throw 'lifecycle.delivery.imagesRequired' }
    }
}

Export-ModuleMember -Function Get-AwsRegistryServer, Get-AwsRegistryAuthorization, Publish-AwsOciArchive, Assert-AwsOciImages
