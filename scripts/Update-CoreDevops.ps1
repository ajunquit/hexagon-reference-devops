<#
.SYNOPSIS
    Copies the base (hexagon-core-devops) into a cloud template at an exact commit and pins it.

.DESCRIPTION
    Each cloud template carries a copy of the base, never edited in place (docs/separacion-por-nube.md).
    This script takes a clean checkout of hexagon-core-devops at -Commit, lists the files of the base
    with its classification (common and history, without its changelog), replaces the previous copy
    and writes .config/hexagon-core-devops-source.json with the commit and the SHA-256 of every file.
    Test-Repository.ps1 then checks that no copied file changed.

.EXAMPLE
    pwsh ./scripts/Update-CoreDevops.ps1 -Source ../hexagon-core-devops -Commit <sha>
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)][string] $Source,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string] $Commit,
    [string] $Repository = 'ajunquit/hexagon-core-devops'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$Source = (Resolve-Path -LiteralPath $Source).Path
if ([IO.Path]::GetFullPath($Source) -ieq [IO.Path]::GetFullPath($root)) { throw 'The source must be a checkout of the base, not this template.' }
$head = (& git -C $Source rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $head -cne $Commit) { throw "The source checkout is not at $Commit." }
$dirty = & git -C $Source status --porcelain
if ($LASTEXITCODE -ne 0 -or $dirty) { throw 'The source checkout has local changes.' }
$python = (Get-Command python -ErrorAction SilentlyContinue) ?? (Get-Command python3 -ErrorAction Stop)
$files = @(& $python.Source (Join-Path $Source 'scripts/cloud_classification.py') base --root $Source)
if ($LASTEXITCODE -ne 0 -or $files.Count -eq 0) { throw 'Could not list the files of the base.' }

$manifestPath = Join-Path $root '.config/hexagon-core-devops-source.json'
$previous = @()
if (Test-Path -LiteralPath $manifestPath) { $previous = @((Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json -AsHashtable).files.Keys) }
if (-not $PSCmdlet.ShouldProcess($root, "Copy the base at $Commit")) { return }

foreach ($path in $previous) {
    if ($path -cnotin $files -and (Test-Path -LiteralPath (Join-Path $root $path))) { Remove-Item -LiteralPath (Join-Path $root $path) -Force }
}
$hashes = [ordered] @{}
foreach ($path in $files) {
    $destination = Join-Path $root $path
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
    Copy-Item -LiteralPath (Join-Path $Source $path) -Destination $destination -Force
    $hashes[$path] = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
}
$manifest = [ordered] @{ apiVersion = 'hexagon.ec/core-devops-source/v1'; repository = $Repository; commit = $Commit; files = $hashes }
[IO.File]::WriteAllText($manifestPath, (($manifest | ConvertTo-Json -Depth 4) -replace "`r`n", "`n") + "`n", [Text.UTF8Encoding]::new($false))
Write-Host "Copied $($files.Count) files of the base at $Commit."
