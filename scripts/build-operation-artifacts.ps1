<#
.SYNOPSIS
    Builds the database bootstrap OCI archive without pushing images or deploying resources.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param([Parameter(Mandatory)] [ValidatePattern('^[0-9a-f]{40}$')] [string] $Commit,
    [string] $OutputDirectory = 'artifacts/operations', [string] $Repository = $env:GITHUB_REPOSITORY)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$product = Get-Content -Raw -LiteralPath (Join-Path $root '.config/product.json') | ConvertFrom-Json
if (@($product.PSObject.Properties.Name).Count -ne 1 -or $product.product -cnotmatch '^hexagon-[a-z][a-z0-9-]*$') { throw 'Invalid DevOps product identity.' }
$headCommit = & git -C $root rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $headCommit -cne $Commit) { throw 'Commit must identify the current checkout.' }
$changes = & git -C $root status --porcelain --untracked-files=no
if ($LASTEXITCODE -ne 0 -or $changes) { throw 'Commit tracked changes before creating operational artifacts.' }
$untracked = & git -C $root ls-files --others --exclude-standard
if ($LASTEXITCODE -ne 0 -or @($untracked | Where-Object { $_ -like 'operations/*' -or $_ -like '.config/*' -or $_ -match '[.](props|targets)$' }).Count -gt 0) { throw 'Commit operational build inputs first.' }
if (-not $Repository) {
    $origin = & git -C $root remote get-url origin
    if ($LASTEXITCODE -ne 0 -or $origin -cnotmatch '^(?:https://github[.]com/|git@github[.]com:)([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:[.]git)?$') { throw 'Provide a GitHub repository identity.' }
    $Repository = $Matches[1]
}
if ($Repository -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'Invalid repository identity.' }
$output = [IO.Path]::GetFullPath($OutputDirectory, $root)
if (-not $PSCmdlet.ShouldProcess($output, 'Build and verify the operational OCI artifact')) { return }
[IO.Directory]::CreateDirectory($output) | Out-Null
$archive = Join-Path $output 'database-bootstrap.oci.tar'
& dotnet publish (Join-Path $root 'operations/Hexagon.Database.Bootstrap') -c Release --os linux --arch x64 -t:PublishContainer '-p:ContainerImageFormat=OCI' '-p:ContainerUser=app' '-p:ContainerRepository=hexagon-database-bootstrap' "-p:ContainerImageTag=$Commit" "-p:ContainerArchiveOutputPath=$archive" --nologo
if ($LASTEXITCODE -ne 0) { throw 'Operational container build failed.' }
$image = & (Join-Path $PSScriptRoot 'Get-OciArchiveMetadata.ps1') -Archive $archive
# The operational tool has no application hosting manifest. Product identity comes from its own ledger.
$record = [ordered] @{ apiVersion = 'hexagon.ec/component-build/v1'; kind = 'ComponentBuild'; product = $product.product; component = 'devops'; repository = $Repository; commit = $Commit; manifests = @(); dependencies = @(); artifacts = @([ordered] @{ id = 'database-bootstrap'; kind = 'oci-image'; file = [IO.Path]::GetFileName($archive); sha256 = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant(); imageDigest = $image.imageDigest; platform = $image.platform }) }
[IO.File]::WriteAllText((Join-Path $output 'build.json'), (($record | ConvertTo-Json -Depth 15) + "`n"), [Text.UTF8Encoding]::new($false))
& (Join-Path $PSScriptRoot 'Test-ComponentBuild.ps1') -Directory $output -ExpectedRepository $Repository -ExpectedCommit $Commit -ExpectedProduct $record.product -ExpectedComponent devops -SourceDirectory $root
