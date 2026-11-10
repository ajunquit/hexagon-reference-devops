<#
.SYNOPSIS
    Stops the local messaging topology generated for a backend.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true)]
    [string] $BackendPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Import-Module (Join-Path $PSScriptRoot 'LocalMessaging.psm1') -Force
$manifestContext = Get-LocalMessagingManifest -BackendPath $BackendPath
$manifest = $manifestContext.Manifest
$generatedRoot = Join-Path $repositoryRoot "local/generated/$($manifest.product)/$($manifest.provider)"
$composeFile = Join-Path $generatedRoot 'compose.yaml'
if (-not (Test-Path -LiteralPath $composeFile -PathType Leaf)) {
    throw "Generated local messaging topology does not exist: $composeFile"
}
$projectName = "$($manifest.product)-local-$($manifest.provider)"

if ($PSCmdlet.ShouldProcess($projectName, 'Stop and remove local messaging containers')) {
    $previousSqlPassword = [Environment]::GetEnvironmentVariable('MSSQL_SA_PASSWORD', 'Process')
    try {
        if ([string] $manifest.provider -ceq 'azure-service-bus') {
            [Environment]::SetEnvironmentVariable(
                'MSSQL_SA_PASSWORD',
                'Hexagon!LocalCleanup123',
                'Process'
            )
        }
        & docker compose --project-name $projectName --file $composeFile down --remove-orphans
        if ($LASTEXITCODE -ne 0) {
            throw "Docker Compose could not stop '$projectName'."
        }

        $bindingsPath = Join-Path $manifestContext.BackendRoot '.hexagon/local-messaging-bindings.json'
        if (Test-Path -LiteralPath $bindingsPath -PathType Leaf) {
            $bindings = Get-Content -Raw -LiteralPath $bindingsPath | ConvertFrom-Json
            $isGeneratedBinding =
                [string] $bindings.apiVersion -ceq 'hexagon.ec/local-messaging-bindings/v1' -and
                [string] $bindings.kind -ceq 'LocalMessagingBindings' -and
                [string] $bindings.product -ceq [string] $manifest.product -and
                [string] $bindings.provider -ceq [string] $manifest.provider
            if ($isGeneratedBinding) {
                Remove-Item -LiteralPath $bindingsPath -Force
            }
            else {
                Write-Warning "Bindings were not removed because '$bindingsPath' does not match this product."
            }
        }
    }
    finally {
        [Environment]::SetEnvironmentVariable('MSSQL_SA_PASSWORD', $previousSqlPassword, 'Process')
    }
}
