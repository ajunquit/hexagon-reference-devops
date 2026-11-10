<#
.SYNOPSIS
    Verifies artifact integrity failures with disposable SPA and OCI fixtures.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$temporaryParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$temporaryRoot = Join-Path $temporaryParent ('hexagon-build-tests-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null
function Bytes([string] $Value) { return [Text.UTF8Encoding]::new($false).GetBytes($Value) }
function Hash([byte[]] $Value) { return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Value)).ToLowerInvariant() }
function Write-Archive([string] $Path, [hashtable] $Files) {
    $stream = [IO.File]::Create($Path)
    $gzip = [IO.Compression.GZipStream]::new($stream, [IO.Compression.CompressionLevel]::Fastest)
    $writer = [System.Formats.Tar.TarWriter]::new($gzip)
    try {
        foreach ($name in $Files.Keys) {
            $entry = [System.Formats.Tar.PaxTarEntry]::new([System.Formats.Tar.TarEntryType]::RegularFile, $name)
            $entry.DataStream = [IO.MemoryStream]::new([byte[]] $Files[$name])
            try { $writer.WriteEntry($entry) } finally { $entry.DataStream.Dispose() }
        }
    } finally { $writer.Dispose(); $gzip.Dispose(); $stream.Dispose() }
}
function Assert-Rejected([scriptblock] $Action, [string] $Message) {
    try { & $Action } catch {
        if ($_.Exception.Message -notlike "*$Message*") { throw }
        return
    }
    throw "Expected rejection: $Message"
}
try {
    $webArchive = Join-Path $temporaryRoot 'web.tar.gz'
    Write-Archive $webArchive @{ 'index.html' = (Bytes '<html></html>'); 'main-ABC.js' = (Bytes 'production') }
    $record = [ordered] @{ apiVersion = 'hexagon.ec/component-build/v1'; kind = 'ComponentBuild'; product = 'hexagon-example'; component = 'web'; repository = 'example/web'; commit = ('a' * 40); manifests = @(@{ path = '.hexagon/frontend-hosting-requirements.json'; sha256 = ('b' * 64) }); dependencies = @(); artifacts = @(@{ id = 'web'; kind = 'static-bundle'; file = 'web.tar.gz'; sha256 = (Get-FileHash $webArchive).Hash.ToLowerInvariant() }) }
    $recordPath = Join-Path $temporaryRoot 'build.json'
    function Save-Record { [IO.File]::WriteAllText($recordPath, ($record | ConvertTo-Json -Depth 15)) }
    function Verify-Record { & (Join-Path $root 'scripts/Test-ComponentBuild.ps1') -Directory $temporaryRoot -ExpectedRepository 'example/web' -ExpectedCommit ('a' * 40) -ExpectedProduct 'hexagon-example' -ExpectedComponent web }
    Save-Record
    Verify-Record
    $record.commit = 'c' * 40; Save-Record
    Assert-Rejected { Verify-Record } 'Unexpected artifact source'
    $record.commit = 'a' * 40
    $record.artifacts[0].sha256 = '0' * 64; Save-Record
    Assert-Rejected { Verify-Record } 'checksum mismatch'
    $record.artifacts[0].file = '../outside.tar.gz'; Save-Record
    Assert-Rejected { Verify-Record } 'Invalid ComponentBuild'
    foreach ($unsafe in @('runtime-config.json', 'staticwebapp.config.json', '../escape', '/absolute', 'assets/.env', 'main.js.map')) {
        Write-Archive $webArchive @{ 'index.html' = (Bytes 'index'); $unsafe = (Bytes 'forbidden') }
        Assert-Rejected { & (Join-Path $root 'scripts/Test-StaticBundle.ps1') -Archive $webArchive } $(if ($unsafe -in @('../escape', '/absolute')) { 'Unsafe static bundle path' } else { 'forbidden' })
    }
    $config = Bytes '{"os":"linux","architecture":"amd64","config":{"User":"app"}}'
    $configHash = Hash $config
    $layer = Bytes 'disposable-layer'; $layerHash = Hash $layer
    $manifest = Bytes ((@{ schemaVersion = 2; config = @{ digest = "sha256:$configHash"; size = $config.Length }; layers = @(@{ digest = "sha256:$layerHash"; size = $layer.Length }) } | ConvertTo-Json -Depth 6 -Compress))
    $manifestHash = Hash $manifest
    $index = Bytes ((@{ schemaVersion = 2; manifests = @(@{ mediaType = 'application/vnd.oci.image.manifest.v1+json'; digest = "sha256:$manifestHash"; size = $manifest.Length }) } | ConvertTo-Json -Depth 6 -Compress))
    $oci = @{ 'oci-layout' = (Bytes '{"imageLayoutVersion":"1.0.0"}'); 'index.json' = $index; "blobs/sha256/$configHash" = $config; "blobs/sha256/$manifestHash" = $manifest; "blobs/sha256/$layerHash" = $layer }
    $imagePath = Join-Path $temporaryRoot 'image.oci.tar.gz'
    Write-Archive $imagePath $oci
    $image = & (Join-Path $root 'scripts/Get-OciArchiveMetadata.ps1') -Archive $imagePath
    if ($image.imageDigest -cne "sha256:$manifestHash" -or $image.platform -cne 'linux/amd64') { throw 'Incorrect OCI image identity.' }
    $oci["blobs/sha256/$layerHash"] = Bytes 'tampered-layer'
    Write-Archive $imagePath $oci
    Assert-Rejected { & (Join-Path $root 'scripts/Get-OciArchiveMetadata.ps1') -Archive $imagePath } 'OCI blob checksum mismatch'
} finally {
    $resolved = [IO.Path]::GetFullPath($temporaryRoot)
    if ([IO.Path]::GetDirectoryName($resolved) -cne $temporaryParent.TrimEnd([IO.Path]::DirectorySeparatorChar) -or -not [IO.Path]::GetFileName($resolved).StartsWith('hexagon-build-tests-')) { throw 'Unsafe test cleanup target.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Host 'Component build identity, tampering, OCI and static-bundle tests passed.'
