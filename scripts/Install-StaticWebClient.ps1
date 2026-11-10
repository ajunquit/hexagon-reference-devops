<#
.SYNOPSIS
    Installs the pinned Microsoft content deployment client without Azure credentials.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'StaticWebClient.psm1')
Install-StaticWebClient -WhatIf:$WhatIfPreference -Confirm:$false
