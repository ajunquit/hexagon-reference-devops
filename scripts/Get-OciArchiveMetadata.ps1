<#
.SYNOPSIS
    Verifies an OCI archive without extracting files and returns its immutable image identity.
#>
[CmdletBinding()]
param([Parameter(Mandatory)] [string] $Archive)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$file = [IO.File]::OpenRead((Resolve-Path -LiteralPath $Archive).Path)
$first = $file.ReadByte(); $second = $file.ReadByte(); $file.Position = 0
# The SDK may write a plain tar even when the requested archive filename ends in .tar.gz.
$stream = if ($first -eq 0x1f -and $second -eq 0x8b) { [IO.Compression.GZipStream]::new($file, [IO.Compression.CompressionMode]::Decompress) } else { $file }
$tar = [System.Formats.Tar.TarReader]::new($stream)
$blobs = @{}; $smallBlobs = @{}; $documents = @{}; $total = 0L; $entries = 0
try {
    while ($null -ne ($entry = $tar.GetNextEntry())) {
        $total += $entry.Length; $entries++
        if ($total -gt 4GB -or $entries -gt 4096) { throw 'OCI archive exceeds delivery limits.' }
        $name = $entry.Name
        if ($entry.EntryType -notin @([System.Formats.Tar.TarEntryType]::RegularFile, [System.Formats.Tar.TarEntryType]::V7RegularFile)) { throw 'OCI archives may contain only regular files.' }
        if ($name -cmatch '^blobs/sha256/([0-9a-f]{64})$') {
            $expected = $Matches[1]
            if ($blobs.ContainsKey($expected)) { throw 'Duplicate OCI blob.' }
            if ($entry.Length -le 1MB) {
                $buffer = [IO.MemoryStream]::new()
                try { $entry.DataStream.CopyTo($buffer); $bytes = $buffer.ToArray() } finally { $buffer.Dispose() }
                $actual = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
                $smallBlobs[$expected] = $bytes
            } else {
                $actual = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($entry.DataStream)).ToLowerInvariant()
            }
            if ($actual -cne $expected) { throw 'OCI blob checksum mismatch.' }
            $blobs[$expected] = $entry.Length
        } elseif ($name -cin @('index.json', 'oci-layout')) {
            if ($documents.ContainsKey($name) -or $entry.Length -gt 1MB) { throw 'Invalid OCI metadata document.' }
            $reader = [IO.StreamReader]::new($entry.DataStream, [Text.UTF8Encoding]::new($false, $true), $false, 1024, $true)
            try { $documents[$name] = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
        } else { throw 'Unexpected OCI archive entry.' }
    }
} finally { $tar.Dispose(); $stream.Dispose(); $file.Dispose() }
if (-not $documents.ContainsKey('index.json') -or -not $documents.ContainsKey('oci-layout') -or $documents['oci-layout'].imageLayoutVersion -cne '1.0.0') { throw 'Missing OCI layout metadata.' }
$index = $documents['index.json']
if ($index.schemaVersion -ne 2 -or $index.manifests.Count -ne 1 -or $index.manifests[0].mediaType -cne 'application/vnd.oci.image.manifest.v1+json') { throw 'Exactly one OCI image manifest is required.' }
function Assert-Blob($Descriptor) {
    if ($Descriptor.digest -cnotmatch '^sha256:([0-9a-f]{64})$') { throw 'Invalid OCI descriptor digest.' }
    $hash = $Matches[1]
    if (-not $blobs.ContainsKey($hash) -or $blobs[$hash] -ne $Descriptor.size) { throw 'Missing OCI blob or incorrect size.' }
    return $hash
}
$manifestHash = Assert-Blob $index.manifests[0]
if (-not $smallBlobs.ContainsKey($manifestHash)) { throw 'Oversized OCI image manifest.' }
$manifest = [Text.Encoding]::UTF8.GetString($smallBlobs[$manifestHash]) | ConvertFrom-Json
if ($manifest.schemaVersion -ne 2) { throw 'Invalid OCI image manifest.' }
$configHash = Assert-Blob $manifest.config
foreach ($layer in $manifest.layers) { $null = Assert-Blob $layer }
if (-not $smallBlobs.ContainsKey($configHash)) { throw 'Oversized OCI configuration.' }
$config = [Text.Encoding]::UTF8.GetString($smallBlobs[$configHash]) | ConvertFrom-Json
if ($config.os -cne 'linux' -or $config.architecture -cnotin @('amd64', 'arm64') -or $config.config.User -cnotin @('app', '1654')) { throw 'Images must use a supported Linux architecture and the non-root app user.' }
return [pscustomobject] @{ imageDigest = $index.manifests[0].digest; platform = "$($config.os)/$($config.architecture)" }
