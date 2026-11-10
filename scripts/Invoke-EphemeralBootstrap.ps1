<#
.SYNOPSIS
    Reserves isolated ephemeral infrastructure with a reviewed Terraform plan, then configures GitHub.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)][ValidateSet('Prepare', 'Apply', 'GitHub', 'Verify')][string] $Mode,
    [Parameter(Mandatory)][string] $Definition,
    [Parameter(Mandatory)][string] $Workspace,
    [string] $ReviewSha256
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'EphemeralEnvironment.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'LifecycleNative.psm1')
Import-Module (Join-Path $PSScriptRoot 'EnvironmentSnapshot.psm1')
Import-Module (Join-Path $PSScriptRoot 'PlatformBootstrap.psm1')
$status = 'Blocked'; $code = $null; $details = @{}

function Invoke-ReservationTerraform([string[]] $Arguments) {
    $result = Invoke-LifecycleCommand terraform (@("-chdir=$workspacePath") + $Arguments) -Environment @{ ARM_USE_CLI = 'true'; ARM_USE_MSI = 'false'; ARM_USE_OIDC = 'false'; ARM_TENANT_ID = $model.inventory.target.tenantId; ARM_SUBSCRIPTION_ID = $model.inventory.target.subscriptionId; TF_CLI_CONFIG_FILE = (Join-Path $workspacePath 'terraform.rc'); TF_IN_AUTOMATION = 'true' }
    if ($result.exitCode -ne 0) { throw 'lifecycle.ephemeral.terraformFailed' }
    return $result
}
function Write-ReservationJson([string] $Name, [object] $Value) { [IO.File]::WriteAllText((Join-Path $workspacePath $Name), (ConvertTo-PlatformBootstrapJson $Value) + "`n") }

try {
    $repository = Split-Path -Parent $PSScriptRoot
    $model = Read-EphemeralEnvironment $Definition
    $inventory = $model.inventory
    $workspacePath = [IO.Path]::GetFullPath($Workspace, (Get-Location).ProviderPath)
    if ($WhatIfPreference) { $status = 'Unverified' }
    elseif ($PSCmdlet.ShouldProcess("$($inventory.product)/$($inventory.environment)/$($inventory.instance.id)", "$Mode isolated bootstrap reservation")) {
        Assert-LifecycleCliEnvironment
        $head = Invoke-LifecycleCommand git @('rev-parse', 'HEAD') $repository -TimeoutSeconds 30
        $main = Invoke-LifecycleCommand git @('rev-parse', 'origin/main') $repository -TimeoutSeconds 30
        if ($head.exitCode -ne 0 -or $main.exitCode -ne 0 -or $head.text -cne $main.text) { throw 'lifecycle.ephemeral.trustedMainRequired' }
        $origin = Invoke-LifecycleCommand git @('remote', 'get-url', 'origin') $repository -TimeoutSeconds 30
        $name = $origin.text.Trim() -replace '^https://github[.]com/', '' -replace '^git@github[.]com:', '' -replace '[.]git$', ''
        $product = (Get-Content -Raw -LiteralPath (Join-Path $repository '.config/product.json') | ConvertFrom-Json).product
        if ($origin.exitCode -ne 0 -or $name -ine $inventory.iac.repository -or $product -cne $inventory.product) { throw 'lifecycle.selectionMismatch' }
        $account = Invoke-LifecycleCommand az @('account', 'show', '--output', 'json', '--only-show-errors') -TimeoutSeconds 45
        if ($account.exitCode -ne 0) { throw 'lifecycle.ephemeral.accountUnavailable' }
        $account = $account.text | ConvertFrom-Json -AsHashtable
        if ($account.tenantId -ine $inventory.target.tenantId -or $account.id -ine $inventory.target.subscriptionId -or $account.environmentName -cne 'AzureCloud' -or $account.state -cne 'Enabled') { throw 'lifecycle.ephemeral.accountMismatch' }
        Assert-EphemeralRepository $model
        foreach ($group in $model.protectedResourceGroups) {
            $response = Invoke-LifecycleCommand az @('group', 'show', '--name', $group, '--subscription', $inventory.target.subscriptionId, '--output', 'json', '--only-show-errors') -TimeoutSeconds 45
            if ($response.exitCode -ne 0) { throw 'lifecycle.ephemeral.protectedGroupUnavailable' }
            $metadata = $response.text | ConvertFrom-Json -AsHashtable
            if ($metadata.id -ine "/subscriptions/$($inventory.target.subscriptionId)/resourceGroups/$group" -or $metadata.tags.product -cne $inventory.product) { throw 'lifecycle.ephemeral.protectedGroupMismatch' }
        }
        $storage = Invoke-LifecycleCommand az @('storage', 'account', 'show', '--name', $inventory.target.storageAccount, '--resource-group', $inventory.target.stateResourceGroup, '--subscription', $inventory.target.subscriptionId, '--output', 'json', '--only-show-errors') -TimeoutSeconds 45
        $properties = Invoke-LifecycleCommand az @('storage', 'account', 'blob-service-properties', 'show', '--account-name', $inventory.target.storageAccount, '--resource-group', $inventory.target.stateResourceGroup, '--subscription', $inventory.target.subscriptionId, '--output', 'json', '--only-show-errors') -TimeoutSeconds 45
        if ($storage.exitCode -ne 0 -or $properties.exitCode -ne 0) { throw 'lifecycle.ephemeral.storageUnavailable' }
        Assert-EphemeralBootstrapStorage $model ($storage.text | ConvertFrom-Json -AsHashtable) ($properties.text | ConvertFrom-Json -AsHashtable)
        $root = Join-Path $repository 'terraform/bootstrap/azure-ephemeral'
        $files = @('main.tf', 'providers.tf', 'variables.tf', 'outputs.tf', 'versions.tf', '.terraform.lock.hcl')
        $sourceHashes = @{}
        foreach ($relative in @($files | ForEach-Object { "terraform/bootstrap/azure-ephemeral/$_" }) + @('scripts/Invoke-EphemeralBootstrap.ps1', 'scripts/EphemeralEnvironment.psm1', 'scripts/LifecycleNative.psm1', 'scripts/EnvironmentLifecycle.psm1', 'scripts/EnvironmentSnapshot.psm1', 'scripts/PlatformBootstrap.Execution.psm1', 'scripts/PlatformBootstrap.psm1')) {
            $sourceFile = Invoke-LifecycleCommand git @('show', "HEAD:$relative") $repository -TimeoutSeconds 30
            $hash = Get-LifecycleFileHash (Join-Path $repository $relative)
            if ($sourceFile.exitCode -ne 0 -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($sourceFile.bytes)).ToLowerInvariant() -cne $hash) { throw 'lifecycle.ephemeral.sourceUntrusted' }
            $sourceHashes[$relative] = $hash
        }
        if ($Mode -ceq 'Prepare') {
            Assert-EphemeralSelection $model $inventory.environment $inventory.instance.id Create
            $workspacePath = New-EphemeralWorkspace $workspacePath -Confirm:$false
            foreach ($name in $files) { Copy-Item -LiteralPath (Join-Path $root $name) -Destination $workspacePath }
            [IO.File]::WriteAllText((Join-Path $workspacePath 'terraform.rc'), "disable_checkpoint = true`nprovider_installation {`n  direct {}`n}`n")
            Write-ReservationJson 'backend.json' @{ resource_group_name = $inventory.target.stateResourceGroup; storage_account_name = $inventory.target.storageAccount; container_name = $model.bootstrapContainer; key = "bootstrap/ephemeral/$($inventory.product)/$($inventory.environment)/$($inventory.instance.id).tfstate"; subscription_id = $inventory.target.subscriptionId; tenant_id = $inventory.target.tenantId; use_azuread_auth = $true; use_cli = $true; use_oidc = $false }
            Write-ReservationJson 'inputs.tfvars.json' @{ subscription_id = $inventory.target.subscriptionId; tenant_id = $inventory.target.tenantId; product = $inventory.product; environment = $inventory.environment; instance_id = $inventory.instance.id; location = $model.location; state_resource_group = $inventory.target.stateResourceGroup; storage_account_name = $inventory.target.storageAccount; oidc_prefix = $model.oidcPrefix; expires_at = $model.expiresAt; roots = @($inventory.roots.id) }
        }
        else {
            $workspacePath = Resolve-EphemeralWorkspacePath $workspacePath
            foreach ($item in Get-ChildItem -LiteralPath $workspacePath -Recurse -Force) {
                $relative = [IO.Path]::GetRelativePath($workspacePath, $item.FullName).Replace('\', '/')
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint -and $relative -cnotmatch '^[.]terraform/providers/registry[.]terraform[.]io/hashicorp/azurerm/[0-9.]+/(linux|windows|darwin)_(amd64|arm64)$') { throw 'lifecycle.ephemeral.workspaceLink' }
            }
            foreach ($name in $files) { if ((Get-LifecycleFileHash (Join-Path $root $name)) -cne (Get-LifecycleFileHash (Join-Path $workspacePath $name))) { throw 'lifecycle.ephemeral.sourceChanged' } }
            foreach ($item in Get-ChildItem -LiteralPath $workspacePath -File -Force) {
                if ($item.Name -match '[.]tf(?:[.]json)?$|[.]tfvars(?:[.]json)?$' -and $item.Name -cnotin ($files + @('inputs.tfvars.json'))) { throw 'lifecycle.ephemeral.sourceChanged' }
            }
        }
        if ($Mode -cne 'Prepare') {
            $review = Get-Content -Raw -LiteralPath (Join-Path $workspacePath 'review.json') | ConvertFrom-Json -AsHashtable -Depth 32
            Assert-EphemeralReservationReview $review $ReviewSha256 (Get-LifecycleFileHash $Definition) (Get-SnapshotHash $sourceHashes) $workspacePath
            Assert-EphemeralSelection $model $inventory.environment $inventory.instance.id $(if ($Mode -cin @('GitHub', 'Verify')) { 'Destroy' } else { 'Create' })
        }
        Invoke-ReservationTerraform @('init', '-input=false', '-lockfile=readonly', '-no-color', '-reconfigure', '-backend-config=backend.json') | Out-Null
        if ($Mode -ceq 'Prepare') {
            Invoke-ReservationTerraform @('plan', '-input=false', '-lock-timeout=60s', '-no-color', '-var-file=inputs.tfvars.json', '-out=reservation.tfplan') | Out-Null
            $show = Invoke-ReservationTerraform @('show', '-json', 'reservation.tfplan')
            $plan = $show.text | ConvertFrom-Json -AsHashtable -Depth 64
            Assert-EphemeralReservationPlan $plan
            [IO.File]::WriteAllBytes((Join-Path $workspacePath 'reservation.json'), $show.bytes)
            $hashes = @{}; foreach ($name in ($files + @('terraform.rc', 'backend.json', 'inputs.tfvars.json', 'reservation.tfplan', 'reservation.json'))) { $hashes[$name] = Get-LifecycleFileHash (Join-Path $workspacePath $name) }
            $version = Invoke-ReservationTerraform @('version', '-json')
            $review = @{ definitionSha256 = Get-LifecycleFileHash $Definition; createdAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); files = $hashes; sourceSha256 = Get-SnapshotHash $sourceHashes; terraformVersion = ($version.text | ConvertFrom-Json).terraform_version }
            Write-ReservationJson 'review.json' $review
            $details = @{ reviewSha256 = Get-SnapshotHash $review }; $status = 'Prepared'
        }
        else {
            if ($Mode -ceq 'Apply') {
                $shown = Invoke-ReservationTerraform @('show', '-json', 'reservation.tfplan')
                if ((Get-SnapshotHash $shown.text) -cne (Get-SnapshotHash (Get-Content -Raw -LiteralPath (Join-Path $workspacePath 'reservation.json')))) { throw 'lifecycle.ephemeral.planChanged' }
                $version = Invoke-ReservationTerraform @('version', '-json')
                if (($version.text | ConvertFrom-Json).terraform_version -cne $review.terraformVersion) { throw 'lifecycle.ephemeral.toolchainChanged' }
                Invoke-ReservationTerraform @('apply', '-input=false', '-lock-timeout=60s', '-no-color', 'reservation.tfplan') | Out-Null
            }
            $outputs = (Invoke-ReservationTerraform @('output', '-json')).text | ConvertFrom-Json -AsHashtable -Depth 32
            $client = $outputs.identity.value.client_id
            if ([guid] $client -eq [guid]::Empty -or $outputs.container.value -cne $inventory.target.container -or $outputs.github_environment.value -cne "$($inventory.environment)-$($inventory.instance.id)") { throw 'lifecycle.ephemeral.bindingsMismatch' }
            $model.inventory.target.clientId = $client
            $identity = Invoke-LifecycleCommand az @('identity', 'show', '--name', "id-$($inventory.product)-$($inventory.environment)-$($inventory.instance.id)-deploy", '--resource-group', $inventory.target.stateResourceGroup, '--subscription', $inventory.target.subscriptionId, '--only-show-errors', '--output', 'json') -TimeoutSeconds 45
            if ($identity.exitCode -ne 0) { throw 'lifecycle.ephemeral.identityUnavailable' }
            $identity = $identity.text | ConvertFrom-Json -AsHashtable
            if ($identity.clientId -ine $client -or $identity.tenantId -ine $inventory.target.tenantId -or $identity.principalId -ine $outputs.identity.value.principal_id) { throw 'lifecycle.ephemeral.identityMismatch' }
            Write-ReservationJson 'resolved-definition.json' $model
            if ($Mode -ceq 'GitHub') { Set-EphemeralGithubProtection $model -Confirm:$false; $status = 'Configured' }
            elseif ($Mode -ceq 'Verify') { Get-EphemeralGithubProtection $model | Out-Null; $status = 'PreparedForDiagnostic' }
            else { $status = 'Applied' }
            $details = @{ definitionPath = Join-Path $workspacePath 'resolved-definition.json' }
        }
    }
}
catch { $status = 'Blocked'; $code = $(if ($_.Exception.Message -cmatch '^lifecycle[.][A-Za-z0-9.]+$') { $_.Exception.Message } else { 'lifecycle.ephemeral.bootstrapFailed' }) }
$json = @{ apiVersion = 'hexagon.ec/ephemeral-bootstrap-result/v1'; status = $status; mode = $Mode; applicationVerified = $false; details = $details; code = $code } | ConvertTo-Json -Depth 8
if (-not ($json | Test-Json -SchemaFile (Join-Path $repository 'contracts/schemas/ephemeral-bootstrap-result-v1.schema.json') -ErrorAction SilentlyContinue)) { throw 'lifecycle.ephemeral.resultInvalid' }
$json
if ($status -ceq 'Blocked') { exit 1 }; if ($status -ceq 'Unverified') { exit 2 }; exit 0
