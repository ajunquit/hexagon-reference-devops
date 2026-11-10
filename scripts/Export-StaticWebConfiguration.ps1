<#
.SYNOPSIS
    Generates public runtime bindings and Azure Static Web Apps routing from verified hosting outputs.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param([Parameter(Mandatory)] [string] $Descriptor, [Parameter(Mandatory)] [string] $TerraformOutputs,
    [Parameter(Mandatory)] [string] $OutputDirectory)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $PSCmdlet.ShouldProcess($OutputDirectory, 'Verify contracts and generate public web configuration')) { return }
Import-Module (Join-Path $PSScriptRoot 'ApplicationContracts.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'StaticWebConfiguration.psm1') -Force
& (Join-Path $PSScriptRoot 'Test-ProductEnvironmentDescriptor.ps1') -Descriptor $Descriptor -VerifySources
$model = Get-Content -Raw -LiteralPath $Descriptor | ConvertFrom-Json
$web = @($model.components | Where-Object name -CEQ 'web')
if ($web.Count -ne 1 -or @($web[0].manifests | Where-Object path -CEQ '.hexagon/frontend-hosting-requirements.json').Count -ne 1) { throw 'Missing pinned frontend hosting contract.' }
$manifest = Get-ValidatedApplicationManifest -Repository $web[0].repository -Commit $web[0].commit -Path '.hexagon/frontend-hosting-requirements.json' -ExpectedProduct $model.product -ExpectedComponent 'web'
$outputs = Get-Content -Raw -LiteralPath $TerraformOutputs | ConvertFrom-Json -AsHashtable
$files = ConvertTo-StaticWebConfiguration -Manifest $manifest.Manifest -Outputs $outputs
[IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($OutputDirectory)) | Out-Null
foreach ($name in $files.Keys) {
    [IO.File]::WriteAllText((Join-Path $OutputDirectory $name), (($files[$name] | ConvertTo-Json -Depth 15) + "`n"), [Text.UTF8Encoding]::new($false))
}
Write-Host 'Generated public runtime-config.json and staticwebapp.config.json; no credentials were exported.'
