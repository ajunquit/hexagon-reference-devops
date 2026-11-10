<#
.SYNOPSIS
    Verifies that a SPA archive contains public files without deployment bindings or unsafe paths.
#>
[CmdletBinding()]
param([Parameter(Mandatory)] [string] $Archive)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$file = [IO.File]::OpenRead((Resolve-Path -LiteralPath $Archive).Path)
$gzip = [IO.Compression.GZipStream]::new($file, [IO.Compression.CompressionMode]::Decompress)
$tar = [System.Formats.Tar.TarReader]::new($gzip)
$total = 0L; $entries = 0; $foundIndex = $false; $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
try {
    while ($null -ne ($entry = $tar.GetNextEntry())) {
        $total += $entry.Length; $entries++
        if ($total -gt 1GB -or $entries -gt 100000) { throw 'Static bundle exceeds delivery limits.' }
        $name = $entry.Name -creplace '^\./', ''
        if ($name -in @('', '.')) {
            if ($entry.EntryType -ne [System.Formats.Tar.TarEntryType]::Directory) { throw 'Unsafe static bundle root entry.' }
            continue
        }
        if ($name.StartsWith('/') -or $name.Contains('\') -or $name -match '(^|/)\.\.?(/|$)|//' -or $name.Contains(':') -or $name -match '[\r\n]') { throw 'Unsafe static bundle path.' }
        if ($entry.EntryType -eq [System.Formats.Tar.TarEntryType]::Directory) { continue }
        if ($entry.EntryType -notin @([System.Formats.Tar.TarEntryType]::RegularFile, [System.Formats.Tar.TarEntryType]::V7RegularFile) -or -not $names.Add($name)) { throw 'Unsafe or duplicate static bundle entry.' }
        if ($name -cin @('runtime-config.json', 'staticwebapp.config.json') -or $name -match '(^|/)\.[^/]+|[.](map|pem|pfx|key|nupkg)$') { throw 'Deployment bindings, secrets or source maps are forbidden in the SPA bundle.' }
        if ($name -ceq 'index.html') { $foundIndex = $true }
    }
} finally { $tar.Dispose(); $gzip.Dispose(); $file.Dispose() }
if (-not $foundIndex) { throw 'The SPA bundle must contain index.html.' }
