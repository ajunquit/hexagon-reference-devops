<#
.SYNOPSIS
    Prepares reviewed bootstrap changes, applies one stage, migrates state or verifies the platform.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)][string] $Definition,
    [Parameter(Mandatory)][ValidateSet('Prepare', 'Apply', 'Migrate', 'Verify')][string] $Mode,
    [ValidateSet('State', 'Access', 'GitHub')][string] $Stage = 'State',
    [Parameter(Mandatory)][string] $Workspace,
    [string] $ReviewSha256,
    [long] $DiagnosticRunId = 0
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$lock = $null
$status = 'Blocked'
$details = @{}
$checks = @()
try {
    Import-Module (Join-Path $PSScriptRoot 'PlatformBootstrap.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'PlatformBootstrap.Execution.psm1') -Force
    $parsed = Read-PlatformBootstrapDefinition $Definition
    # The reviewed CLI session is the only Terraform authentication source in bootstrap.
    if (@(Get-ChildItem Env: | Where-Object { $_.Name -like 'TF_CLI_ARGS*' -or $_.Name -eq 'TF_DATA_DIR' -or
        ($_.Name -like 'ARM_*' -and $_.Name -notin @('ARM_SUBSCRIPTION_ID', 'ARM_TENANT_ID')) -or
        ($_.Name -eq 'TF_WORKSPACE' -and $_.Value -cne 'default') }).Count -gt 0) { throw 'bootstrap.ambientConfiguration' }
    # No execution workspace or platform write precedes the shared target/repository preflight.
    $observation = Get-PlatformBootstrapObservation $parsed.definition
    $workspacePath = [IO.Path]::GetFullPath($Workspace)
    $root = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
    $allowedParent = Join-Path $root 'artifacts'
    $comparison = $(if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal })
    if (-not $workspacePath.StartsWith($allowedParent + [IO.Path]::DirectorySeparatorChar, $comparison)) { throw 'bootstrap.workspaceOutsideArtifacts' }
    $ancestor = $workspacePath
    while ($ancestor.Length -ge $allowedParent.Length) {
        if ((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'bootstrap.workspaceLink' }
        $ancestor = [IO.Path]::GetDirectoryName($ancestor)
    }
    if (Test-Path -LiteralPath $workspacePath) {
        $links = @(Get-ChildItem -LiteralPath $workspacePath -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
        foreach ($link in $links) {
            $relative = [IO.Path]::GetRelativePath($workspacePath, $link.FullName).Replace('\', '/')
            # Terraform may link its checksummed provider from TF_PLUGIN_CACHE_DIR. Config/state links remain forbidden.
            if ($relative -cnotmatch '^(state|access|state-remote)/[.]terraform/providers/registry[.]terraform[.]io/hashicorp/azurerm/[0-9]+[.][0-9]+[.][0-9]+/(linux|windows|darwin)_(amd64|arm64)$') { throw 'bootstrap.workspaceLink' }
        }
    }
    # WhatIf performs reads only; no directory, plan, lock file or remote mutation is created.
    if ($WhatIfPreference) {
        $status = 'Unverified'; $checks += @{ code = 'bootstrap.executionSkipped'; status = 'Pending' }
    }
    elseif ($PSCmdlet.ShouldProcess("$($parsed.definition.automation.repository):$Stage", "$Mode bootstrap stage")) {
        [IO.Directory]::CreateDirectory($workspacePath) | Out-Null
        if (-not $IsWindows) { [IO.File]::SetUnixFileMode($workspacePath, [IO.UnixFileMode] 'UserRead,UserWrite,UserExecute') }
        $lock = [IO.File]::Open((Join-Path $workspacePath '.execution.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $binding = ConvertTo-PlatformBootstrapJson @{
            product = $parsed.definition.product; repository = $parsed.definition.automation.repository
            tenant = $parsed.definition.azure.tenantId; subscription = $parsed.definition.azure.subscriptionId
            state = $parsed.definition.state
        }
        $bindingPath = Join-Path $workspacePath 'workspace.json'
        if (Test-Path -LiteralPath $bindingPath) {
            if ((Get-Content -Raw -LiteralPath $bindingPath).Trim() -cne $binding.Trim()) { throw 'bootstrap.workspaceTargetChanged' }
        }
        else { [IO.File]::WriteAllText($bindingPath, $binding, [Text.UTF8Encoding]::new($false)) }
        switch ($Mode) {
            'Prepare' {
                $details = New-BootstrapReview -Parsed $parsed -Observation $observation -Stage $Stage -Workspace $workspacePath
                $status = 'Prepared'
            }
            'Apply' {
                if (-not $ReviewSha256) { throw 'bootstrap.reviewRequired' }
                Invoke-BootstrapApply -Parsed $parsed -Observation $observation -Stage $Stage -Workspace $workspacePath -ReviewSha256 $ReviewSha256
                $status = 'Applied'
            }
            'Migrate' {
                if ($Stage -cne 'State') { throw 'bootstrap.migrationStage' }
                Move-BootstrapState -Parsed $parsed -Workspace $workspacePath
                $status = 'Migrated'
            }
            'Verify' {
                $checks = Test-BootstrapPlatform -Parsed $parsed -Observation $observation -Workspace $workspacePath -DiagnosticRunId $DiagnosticRunId
                $status = $(if (@($checks | Where-Object status -CEQ 'Pending').Count -gt 0) { 'Unverified' } else { 'Verified' })
            }
        }
    }
}
catch {
    $code = $_.Exception.Message
    if ($code -cnotmatch '^bootstrap[.][A-Za-z0-9.]+$') { $code = 'bootstrap.executionFailed' }
    $checks += @{ code = $code; status = 'Blocked' }; $status = 'Blocked'
}
finally { if ($null -ne $lock) { $lock.Dispose() } }
$result = @{
    apiVersion = 'hexagon.ec/platform-bootstrap-execution/v1'; mode = $Mode; stage = $Stage
    status = $status; readyToApply = ($status -ceq 'Prepared'); applyImplemented = $true
    platformVerified = ($status -ceq 'Verified'); checks = @($checks); details = $details
}
$json = ConvertTo-PlatformBootstrapJson $result
if (-not ($json | Test-Json -SchemaFile (Join-Path (Split-Path -Parent $PSScriptRoot) 'contracts/schemas/platform-bootstrap-execution-v1.schema.json') -ErrorAction SilentlyContinue)) { throw 'Invalid bootstrap execution result.' }
$json
if ($status -ceq 'Blocked') { exit 1 }
if ($status -ceq 'Unverified') { exit 2 }
exit 0
