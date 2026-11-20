<#
.SYNOPSIS
    Starts the selected local messaging provider and materializes bindings for the backend AppHost.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [Parameter(Mandatory = $true)]
    [string] $BackendPath,

    [string] $Policy,

    [switch] $AcceptLicense
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'LocalMessaging.psm1') -Force

$manifestContext = Get-LocalMessagingManifest -BackendPath $BackendPath
$provider = [string] $manifestContext.Manifest.provider
$newArguments = @{
    BackendPath = $BackendPath
    PassThru    = $true
}
if ($Policy) { $newArguments.Policy = $Policy }
if ($WhatIfPreference) { $newArguments.WhatIf = $true }
$generated = & (Join-Path $PSScriptRoot 'New-LocalMessaging.ps1') @newArguments
if ($WhatIfPreference) { return }

$providerModule = Get-LocalMessagingProviderModule $provider
Invoke-LocalMessagingProvider $providerModule Assert-LocalMessagingStart @([bool] $AcceptLicense)
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw 'Docker is required to start local messaging.'
}
docker version --format '{{.Server.Version}}' | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'Docker is not running.'
}

$projectName = "$($generated.Product)-local-$($generated.Provider)"
if (-not $PSCmdlet.ShouldProcess($projectName, "Start $provider local messaging topology")) { return }

$environment = Invoke-LocalMessagingProvider $providerModule Get-LocalMessagingStartEnvironment
$previous = @{}
foreach ($name in $environment.Keys) { $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
try {
    foreach ($name in $environment.Keys) { [Environment]::SetEnvironmentVariable($name, $environment[$name], 'Process') }
    & docker compose `
        --project-name $projectName `
        --file $generated.ComposeFile `
        up --detach --wait --wait-timeout 300
    if ($LASTEXITCODE -ne 0) {
        throw "Docker Compose could not start local messaging for '$provider'."
    }

    $deadline = [DateTime]::UtcNow.AddMinutes(3)
    $ready = $false
    do {
        try {
            $ready = [bool] (Invoke-LocalMessagingProvider $providerModule Test-LocalMessagingReady @($generated, $projectName))
        }
        catch {
            $ready = $false
        }
        if (-not $ready) { Start-Sleep -Seconds 2 }
    } while (-not $ready -and [DateTime]::UtcNow -lt $deadline)

    if (-not $ready) {
        throw "Local messaging provider '$provider' did not become ready within three minutes."
    }
}
finally {
    foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process') }
}

Write-Host "Local messaging is ready for $($generated.Product) with $provider."
Write-Host "Run the backend AppHost; it will read $($generated.BindingsFile)."
