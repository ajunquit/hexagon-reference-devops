<#
.SYNOPSIS
    Verifies build evidence, checksums and portable artifacts against an expected immutable source.
#>
[CmdletBinding()]
param([Parameter(Mandatory)] [string] $Directory,
    [Parameter(Mandatory)] [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')] [string] $ExpectedRepository,
    [Parameter(Mandatory)] [ValidatePattern('^[0-9a-f]{40}$')] [string] $ExpectedCommit,
    [Parameter(Mandatory)] [string] $ExpectedProduct,
    [Parameter(Mandatory)] [ValidateSet('backend', 'web', 'devops')] [string] $ExpectedComponent,
    [string] $SourceDirectory)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$directoryPath = (Resolve-Path -LiteralPath $Directory).Path
$json = Get-Content -Raw -LiteralPath (Join-Path $directoryPath 'build.json')
if (-not ($json | Test-Json -SchemaFile (Join-Path $root 'contracts/schemas/component-build-v1.schema.json') -ErrorAction SilentlyContinue)) { throw 'Invalid ComponentBuild v1 evidence.' }
$build = $json | ConvertFrom-Json
if ($build.repository -cne $ExpectedRepository -or $build.commit -cne $ExpectedCommit -or $build.product -cne $ExpectedProduct -or $build.component -cne $ExpectedComponent) { throw 'Unexpected artifact source or component.' }
if (@($build.artifacts.id | Sort-Object -Unique).Count -ne $build.artifacts.Count -or @($build.artifacts.file | Sort-Object -Unique).Count -ne $build.artifacts.Count) { throw 'Duplicate artifact identity or filename.' }
$manifestPaths = @($build.manifests | ForEach-Object path)
if (@($manifestPaths | Sort-Object -Unique).Count -ne $build.manifests.Count) { throw 'Duplicate manifest path.' }
$expectedPaths = switch ($ExpectedComponent) {
    'web' { @('.hexagon/frontend-hosting-requirements.json') }
    'backend' { @('.hexagon/backend-hosting-requirements.json', '.hexagon/messaging-requirements.json') }
    'devops' { @() }
}
if ($ExpectedComponent -cne 'devops' -and $manifestPaths -ccontains '.hexagon/acceptance-requirements.json') { $expectedPaths += '.hexagon/acceptance-requirements.json' }
if ((@($manifestPaths | Sort-Object) -join ',') -cne (@($expectedPaths | Sort-Object) -join ',')) { throw 'Missing or unexpected source manifests.' }
if ($ExpectedComponent -ceq 'backend' -and $build.dependencies.Count -ne 1) { throw 'Backend builds must identify the pinned local core.' }
if ($ExpectedComponent -ceq 'web' -and ($build.artifacts.Count -ne 1 -or $build.artifacts[0].kind -cne 'static-bundle' -or $build.dependencies.Count -ne 0)) { throw 'Unexpected SPA artifact shape.' }
if ($ExpectedComponent -cne 'web' -and @($build.artifacts | Where-Object kind -CNE 'oci-image').Count -gt 0) { throw 'Backend and operational artifacts must be OCI images.' }
foreach ($artifact in $build.artifacts) {
    $path = Join-Path $directoryPath $artifact.file
    $item = Get-Item -LiteralPath $path
    if ($item.LinkType -or $item.PSIsContainer -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $artifact.sha256) { throw 'Artifact checksum mismatch or unsafe artifact file.' }
    if ($artifact.kind -ceq 'oci-image') {
        $image = & (Join-Path $PSScriptRoot 'Get-OciArchiveMetadata.ps1') -Archive $path
        if ($image.imageDigest -cne $artifact.imageDigest -or $image.platform -cne $artifact.platform) { throw 'OCI image identity mismatch.' }
    } else {
        & (Join-Path $PSScriptRoot 'Test-StaticBundle.ps1') -Archive $path
    }
}
if ($SourceDirectory) {
    $source = (Resolve-Path -LiteralPath $SourceDirectory).Path
    $headCommit = & git -C $source rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $headCommit -cne $ExpectedCommit) { throw 'Source checkout does not match the expected commit.' }
    foreach ($manifest in $build.manifests) {
        $path = Join-Path $source $manifest.path
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $manifest.sha256) { throw 'Source manifest checksum mismatch.' }
    }
    if ($ExpectedComponent -ceq 'backend') {
        $hosting = Get-Content -Raw -LiteralPath (Join-Path $source '.hexagon/backend-hosting-requirements.json') | ConvertFrom-Json
        if ((@($hosting.workloads.id | Sort-Object) -join ',') -cne (@($build.artifacts.id | Sort-Object) -join ',')) { throw 'Backend artifacts do not match declared workloads.' }
        $pin = Get-Content -Raw -LiteralPath (Join-Path $source '.config/hexagon-core-source.json') | ConvertFrom-Json
        if ($build.dependencies.Count -ne 1 -or $build.dependencies[0].repository -cne $pin.repository -or $build.dependencies[0].commit -cne $pin.commit) { throw 'Build does not identify the pinned local core.' }
    }
}
Write-Host "Verified $ExpectedComponent artifacts and immutable source identity."
