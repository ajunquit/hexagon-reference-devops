<#
.SYNOPSIS
    Validates immutable application artifacts against the pinned product descriptor.
#>
[CmdletBinding()]
param([Parameter(Mandatory)] [string] $Descriptor, [Parameter(Mandatory)] [string] $Release, [switch] $VerifySources)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'HostingContracts.psm1') -Force
& (Join-Path $PSScriptRoot 'Test-ProductEnvironmentDescriptor.ps1') -Descriptor $Descriptor -VerifySources:$VerifySources
$descriptorModel = Get-Content -Raw -LiteralPath $Descriptor | ConvertFrom-Json -AsHashtable
$releaseModel = Read-HostingContract -Path $Release -Schema 'application-release-v1'
Assert-ReleaseSources -Descriptor $descriptorModel -Release $releaseModel
Write-Host 'Validated immutable release sources and artifact references. Artifact bytes must be verified when downloading or promoting.'
