Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'EnvironmentSnapshot.psm1')
Import-Module (Join-Path $PSScriptRoot 'PlatformBootstrap.psm1')
Import-Module (Join-Path $PSScriptRoot 'StaticWebConfiguration.psm1')

function New-StaticWebPayload {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string] $Archive, [string] $ArchiveSha256, $Manifest, [hashtable] $Outputs,
        [string] $ReleaseSha256, [string] $DeliverySha256, [string] $Directory)
    if (-not $PSCmdlet.ShouldProcess($Directory, 'Prepare the verified SPA with public deployment configuration')) { return }
    foreach ($hash in @($ArchiveSha256, $ReleaseSha256, $DeliverySha256)) { if ($hash -cnotmatch '^[0-9a-f]{64}$') { throw 'lifecycle.web.payloadIdentityInvalid' } }
    if ((Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ArchiveSha256 -or (Test-Path -LiteralPath $Directory)) { throw 'lifecycle.web.bundleChanged' }
    & (Join-Path $PSScriptRoot 'Test-StaticBundle.ps1') -Archive $Archive
    $overlay = ConvertTo-StaticWebConfiguration $Manifest $Outputs
    [IO.Directory]::CreateDirectory($Directory) | Out-Null
    $file = [IO.File]::OpenRead($Archive); $gzip = [IO.Compression.GZipStream]::new($file, [IO.Compression.CompressionMode]::Decompress); $tar = [System.Formats.Tar.TarReader]::new($gzip)
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase); $files = @{}
    try {
        while ($null -ne ($entry = $tar.GetNextEntry())) {
            $name = $entry.Name -creplace '^\./', ''
            if ($entry.EntryType -eq [System.Formats.Tar.TarEntryType]::Directory) { continue }
            if ($name -iin @('hexagon-deployment.json', 'runtime-config.json', 'staticwebapp.config.json') -or -not $names.Add($name)) { throw 'lifecycle.web.reservedOrDuplicateFile' }
            $path = [IO.Path]::GetFullPath((Join-Path $Directory $name))
            if (-not $path.StartsWith([IO.Path]::GetFullPath($Directory) + [IO.Path]::DirectorySeparatorChar, [StringComparison]::Ordinal)) { throw 'lifecycle.web.bundlePathInvalid' }
            [IO.Directory]::CreateDirectory((Split-Path -Parent $path)) | Out-Null
            $destination = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
            try { $entry.DataStream.CopyTo($destination) } finally { $destination.Dispose() }
            $files[$name] = @{ sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant(); length = $entry.Length }
        }
    }
    finally { $tar.Dispose(); $gzip.Dispose(); $file.Dispose() }
    foreach ($name in $overlay.Keys) {
        $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-PlatformBootstrapJson $overlay[$name]) + "`n")
        [IO.File]::WriteAllBytes((Join-Path $Directory $name), $bytes)
        $files[$name] = @{ sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant(); length = $bytes.Length }
    }
    $identity = @{ archiveSha256 = $ArchiveSha256; releaseSha256 = $ReleaseSha256; deliverySha256 = $DeliverySha256; overlaySha256 = Get-SnapshotHash $overlay; contentSha256 = Get-SnapshotHash $files }
    $deploymentSha256 = Get-SnapshotHash $identity
    $marker = @{ apiVersion = 'hexagon.ec/public-web-deployment/v1'; deploymentSha256 = $deploymentSha256 } + $identity
    $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-PlatformBootstrapJson $marker) + "`n")
    [IO.File]::WriteAllBytes((Join-Path $Directory 'hexagon-deployment.json'), $bytes)
    $files['hexagon-deployment.json'] = @{ sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant(); length = $bytes.Length }
    return @{ directory = [IO.Path]::GetFullPath($Directory); deploymentSha256 = $deploymentSha256; identity = $identity; files = $files }
}

function Assert-StaticWebPayload([hashtable] $Payload) {
    $actual = @(Get-ChildItem -LiteralPath $Payload.directory -Recurse -File -Force)
    if ($actual.Count -ne $Payload.files.Count -or @(Get-ChildItem -LiteralPath $Payload.directory -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count -gt 0) { throw 'lifecycle.web.payloadChanged' }
    foreach ($file in $actual) {
        $name = [IO.Path]::GetRelativePath($Payload.directory, $file.FullName).Replace('\', '/')
        if (-not $Payload.files.ContainsKey($name) -or (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Payload.files[$name].sha256) { throw 'lifecycle.web.payloadChanged' }
    }
}

function New-PublicWebHttpClient {
    $handler = [Net.Http.HttpClientHandler]::new(); $handler.AllowAutoRedirect = $false; $handler.UseCookies = $false
    $handler.AutomaticDecompression = [Net.DecompressionMethods]::All
    $client = [Net.Http.HttpClient]::new($handler); $client.Timeout = [TimeSpan]::FromSeconds(30)
    return $client
}

function Get-PublicWebFile([string] $Origin, [string] $Path, [long] $MaximumBytes) {
    $address = [uri] $Origin
    if ($address.Scheme -cne 'https' -or $address.Port -ne 443 -or $address.UserInfo -or $address.Query -or $address.Fragment -or $address.AbsolutePath -cne '/' -or
        $address.Host -cnotmatch '^[a-z0-9-]+[.](?:[a-z0-9-]+[.])?azurestaticapps[.]net$' -or $Path.StartsWith('/') -or $Path.Contains('\') -or $Path -match '(^|/)[.][.]?(/|$)|[?#]') { throw 'lifecycle.web.publicEndpointInvalid' }
    $escaped = (($Path -split '/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
    $client = New-PublicWebHttpClient; $response = $null; $stream = $null
    $cancel = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(30))
    $hash = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    try {
        $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, "$($address.GetLeftPart([UriPartial]::Authority))/$escaped")
        $request.Headers.CacheControl = [Net.Http.Headers.CacheControlHeaderValue]::new(); $request.Headers.CacheControl.NoCache = $true
        $response = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cancel.Token).GetAwaiter().GetResult()
        if ([int] $response.StatusCode -ne 200) { throw 'lifecycle.web.publicResponseUnsuccessful' }
        $stream = $response.Content.ReadAsStreamAsync($cancel.Token).GetAwaiter().GetResult(); $buffer = [byte[]]::new(65536); $total = 0L
        while (($count = $stream.ReadAsync($buffer, 0, $buffer.Length, $cancel.Token).GetAwaiter().GetResult()) -gt 0) {
            $total += $count
            if ($total -gt $MaximumBytes) { throw 'lifecycle.web.publicFileTooLarge' }
            $hash.AppendData($buffer, 0, $count)
        }
        return @{ sha256 = [Convert]::ToHexString($hash.GetHashAndReset()).ToLowerInvariant(); length = $total
            noStore = $null -ne $response.Headers.CacheControl -and $response.Headers.CacheControl.NoStore
            revalidate = $null -ne $response.Headers.CacheControl -and ($response.Headers.CacheControl.NoCache -or $response.Headers.CacheControl.NoStore)
            noSniff = $response.Headers.Contains('X-Content-Type-Options') -and (@($response.Headers.GetValues('X-Content-Type-Options')) -join ',').Trim() -ieq 'nosniff'
            noReferrer = $response.Headers.Contains('Referrer-Policy') -and (@($response.Headers.GetValues('Referrer-Policy')) -join ',').Trim() -ieq 'no-referrer'
            contentType = [string] $response.Content.Headers.ContentType }
    }
    catch { if ($_.Exception.Message -cmatch '^lifecycle[.][A-Za-z0-9.]+$') { throw }; throw 'lifecycle.web.publicTransportFailed' }
    finally { if ($stream) { $stream.Dispose() }; if ($response) { $response.Dispose() }; if ($request) { $request.Dispose() }; $hash.Dispose(); $cancel.Dispose(); $client.Dispose() }
}

function Test-StaticWebServing {
    param([hashtable] $Payload, [string] $Origin, [Parameter(Mandatory)][scriptblock] $Heartbeat)
    Assert-StaticWebPayload $Payload
    $timer = [Diagnostics.Stopwatch]::StartNew()
    # The host consumes its control file; verify its routing/header effects rather than assuming it is public.
    $publicNames = @($Payload.files.Keys | Where-Object { $_ -cne 'staticwebapp.config.json' })
    foreach ($name in @('hexagon-deployment.json') + @($publicNames | Where-Object { $_ -cne 'hexagon-deployment.json' } | Sort-Object) + @('hexagon-deployment.json')) {
        & $Heartbeat | Out-Null
        if ($timer.Elapsed.TotalSeconds -gt 600) { throw 'lifecycle.web.publicVerificationTimeout' }
        $expected = $Payload.files[$name]; $actual = Get-PublicWebFile $Origin $name $expected.length
        if ($actual.sha256 -cne $expected.sha256 -or $actual.length -ne $expected.length) { throw 'lifecycle.web.servedContentMismatch' }
        if (-not $actual.noSniff -or -not $actual.noReferrer) { throw 'lifecycle.web.securityHeadersInvalid' }
        if ($name -cin @('runtime-config.json', 'index.html') -and -not $actual.noStore) { throw 'lifecycle.web.cachePolicyInvalid' }
        $mediaType = ($actual.contentType -split ';')[0].Trim().ToLowerInvariant()
        $allowed = switch ([IO.Path]::GetExtension($name).ToLowerInvariant()) {
            '.json' { @('application/json') }
            '.html' { @('text/html') }
            { $_ -in @('.js', '.mjs') } { @('application/javascript', 'text/javascript', 'application/x-javascript') }
            '.css' { @('text/css') }
            '.wasm' { @('application/wasm') }
            default { @($mediaType) }
        }
        if ($mediaType -notin $allowed) { throw 'lifecycle.web.publicContentTypeInvalid' }
    }
    foreach ($path in @('', "__hexagon_probe__/route/$($Payload.deploymentSha256.Substring(0, 16))")) {
        & $Heartbeat | Out-Null
        $actual = Get-PublicWebFile $Origin $path $Payload.files['index.html'].length
        if ($actual.sha256 -cne $Payload.files['index.html'].sha256 -or -not $actual.revalidate -or -not $actual.noSniff -or -not $actual.noReferrer -or $actual.contentType -notmatch '^text/html(?:;|$)') { throw 'lifecycle.web.spaFallbackInvalid' }
    }
    return @{ deploymentSha256 = $Payload.deploymentSha256; filesVerified = $publicNames.Count; fallbackVerified = $true; publicConfigurationVerified = $true }
}

Export-ModuleMember -Function New-StaticWebPayload, Assert-StaticWebPayload, Test-StaticWebServing
