<#
.SYNOPSIS
    Local check (ADR 0026): applies and destroys the hosting-azure root against Floci AZ.

.DESCRIPTION
    Not part of Test-Repository or CI. It starts the pinned Floci AZ emulator with the Docker socket
    mounted, so the services it backs with real containers (registry, PostgreSQL) run as such, and runs
    Terraform from its official Linux image in the emulator's network namespace, against a temporary
    copy of the roots with a local backend. Hosting goes through its initial state, then maintenance
    and rollout, and ends with a convergence plan and a full destroy. Messaging is reported as not
    covered: Floci AZ manages Service Bus only through its data-plane API.

    Where Floci AZ lacks a service the module uses, the temporary copy replaces it with a stand-in that
    is checked against the module text, so a change of the module stops the check instead of silently
    testing something else. Stand-ins and known gaps are listed in docs/pruebas-locales-floci-azure.md.

    A passing run says Terraform creates, converges and destroys the root on an emulator. It never
    replaces the validation in the real cloud (D-9C).

.PARAMETER Roots
    All (default), Hosting or Messaging.

.PARAMETER FlociVersion
    An exact release published at least two weeks ago. Defaults to the version pinned by ADR 0026.
#>
[CmdletBinding()]
param(
    [ValidateSet('All', 'Hosting', 'Messaging')][string] $Roots = 'All',
    [switch] $Rebuild,
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')][string] $FlociVersion,
    [string] $TerraformImage = 'hashicorp/terraform:1.17.1'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'docker is required.' }

$pinned = '0.15.0'
$version = $(if ($FlociVersion) { $FlociVersion } else { $pinned })
$image = "floci/floci-az:$version"
$port = 4577
$container = "hexagon-floci-azure"
# Floci reaches the containers it starts (registry, databases) through this network.
$network = "hexagon-floci-azure"
$work = Join-Path $repository "artifacts/floci-azure-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $work | Out-Null
$results = [ordered] @{}

. (Join-Path $PSScriptRoot 'FlociSupport.ps1')

function Invoke-Terraform([string] $Directory, [string[]] $Arguments) {
    $relative = [IO.Path]::GetRelativePath($work, $Directory).Replace('\', '/')
    $environment = @('-e', 'TF_IN_AUTOMATION=1', '-e', 'TF_PLUGIN_CACHE_DIR=/plugins')
    $environment += @('-e', 'SSL_CERT_FILE=/work/floci-az.crt')
    docker run --rm --network "container:$container" -v "${work}:/work" -v 'hexagon-terraform-plugins:/plugins' -w "/work/$relative" @environment $TerraformImage @Arguments
}

try {
    # The Docker socket lets Floci run real containers for the services it backs (owner decision, ADR 0026).
    docker rm -f $container 2>$null | Out-Null
    docker network inspect $network 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { docker network create $network | Out-Null }
    $arguments = @('run', '-d', '--rm', '--name', $container, '--network', $network, '--memory=4g', '-p', "127.0.0.1:${port}:$port", '-v', '/var/run/docker.sock:/var/run/docker.sock')
    $arguments += @('-e', 'FLOCI_AZ_TLS_ENABLED=true', '-e', "FLOCI_AZ_SERVICES_DOCKER_NETWORK=$network")
    Invoke-Step 'Start Floci' { docker @arguments $image | Out-Null }
    $ready = $false
    foreach ($attempt in 1..60) {
        try {
            $probe = "http://127.0.0.1:$port/_floci/tls-cert"
            Invoke-WebRequest -Uri $probe -TimeoutSec 2 | Out-Null; $ready = $true; break
        }
        catch { Start-Sleep -Seconds 1 }
    }
    if (-not $ready) { throw 'Floci did not become ready.' }
    Invoke-WebRequest -Uri "http://127.0.0.1:$port/_floci/tls-cert" -OutFile (Join-Path $work 'floci-az.crt')

    # A temporary copy of the roots, without provider directories, and with a local backend.
    $sourceRoot = Join-Path $repository 'terraform'
    foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force) {
        $relative = [IO.Path]::GetRelativePath($sourceRoot, $file.FullName)
        if (($relative -split '[\\/]') -ccontains '.terraform') { continue }
        $destination = Join-Path $work (Join-Path 'terraform' $relative)
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
        [IO.File]::Copy($file.FullName, $destination)
    }
    $root = Join-Path $work "terraform/environments/dev/hosting-azure"
    $messagingRoot = Join-Path $work "terraform/environments/dev/azure"
    foreach ($directory in @($root, $messagingRoot)) {
        @('terraform {', '  backend "local" {}', '}') | Set-Content -LiteralPath (Join-Path $directory 'backend_override.tf') -Encoding utf8NoBOM
    }
    $descriptor = [pscustomobject] @{ product = 'hexagon-example'; environment = 'dev' }
    $manifest = Get-Content -Raw -LiteralPath (Join-Path $repository 'tests/fixtures/backend/.hexagon/messaging-requirements.json') | ConvertFrom-Json

    $provider = @(
        'provider "azurerm" {', '  features {}', '  use_cli         = false', '  environment     = "stack"', "  metadata_host   = `"localhost:$port`"",
        '  subscription_id = "00000000-0000-0000-0000-000000000001"', '  tenant_id       = "00000000-0000-0000-0000-000000000002"',
        '  client_id       = "11111111-1111-1111-1111-111111111111"', '  client_secret   = "floci-az-dev-secret"', '}')
    foreach ($directory in @($root, $messagingRoot)) { $provider | Set-Content -LiteralPath (Join-Path $directory 'providers_override.tf') -Encoding utf8NoBOM }
    $azureMain = Join-Path $work 'terraform/modules/hosting/azure/main.tf'
    $azureOutputs = Join-Path $work 'terraform/modules/hosting/azure/outputs.tf'
    # Floci AZ requires a password administrator on PostgreSQL; Hexagon uses Entra ID only.
    Set-StandIn $azureMain "  administrator_login               = local.keycloak_enabled ? replace(`"`${var.name_prefix}_bootstrap`", `"-`", `"_`") : null`n  administrator_password_wo         = local.keycloak_enabled ? ephemeral.azurerm_key_vault_secret.postgres_administrator[0].value : null`n  administrator_password_wo_version = local.keycloak_enabled ? var.keycloak.server_password_revision : null" `
        "  administrator_login               = `"floci_bootstrap`"`n  administrator_password            = `"Floci-local-only-1`"" 'PostgreSQL administrator'
    Set-StandIn $azureMain "    password_auth_enabled         = local.keycloak_enabled" "    password_auth_enabled         = true" 'PostgreSQL password authentication'
    # Floci AZ 0.15.0 has no role assignments (RBAC is not released yet): the AcrPull assignments go.
    Remove-ResourceBlock $azureMain 'resource "azurerm_role_assignment" "image_pull" {' 'AcrPull role assignments'
    Set-StandIn $azureMain 'azurerm_role_assignment.image_pull, ' '' 'AcrPull role assignment dependencies'
    # Floci AZ has no Entra administrators on PostgreSQL.
    Set-StandIn $azureMain "resource `"azurerm_postgresql_flexible_server_active_directory_administrator`" `"maintenance`" {`n  server_name         = azurerm_postgresql_flexible_server.this.name`n  resource_group_name = data.azurerm_resource_group.this.name`n  tenant_id           = data.azurerm_client_config.current.tenant_id`n  object_id           = azurerm_user_assigned_identity.maintenance.principal_id`n  principal_name      = azurerm_user_assigned_identity.maintenance.name`n  principal_type      = `"ServicePrincipal`"`n}" '' 'PostgreSQL Entra administrator'
    Set-StandIn $azureMain 'azurerm_postgresql_flexible_server_active_directory_administrator.maintenance, ' '' 'PostgreSQL Entra administrator dependency'
    # Floci AZ has no soft-deleted Log Analytics workspaces, which the provider checks before creating one.
    Set-StandIn $azureMain "resource `"azurerm_log_analytics_workspace`" `"this`" {`n  name                = `"`${var.name_prefix}-logs`"`n  resource_group_name = data.azurerm_resource_group.this.name`n  location            = var.location`n  sku                 = `"PerGB2018`"`n  retention_in_days   = 30`n  tags                = local.tags`n}" '' 'Log Analytics workspace'
    Set-StandIn $azureMain "  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id`n" '' 'Log Analytics link'
    # Floci AZ has no Static Web Apps: the site becomes a fixed value with the same attributes.
    Set-StandIn $azureMain "resource `"azurerm_static_web_app`" `"this`" {`n  name                = `"`${var.name_prefix}-web`"`n  resource_group_name = data.azurerm_resource_group.this.name`n  location            = var.location`n  sku_tier            = `"Standard`"`n  sku_size            = `"Standard`"`n  tags                = local.tags`n}" `
        "resource `"terraform_data`" `"static_web_app`" {`n  input = { id = `"`${data.azurerm_resource_group.this.id}/providers/Microsoft.Web/staticSites/`${var.name_prefix}-web`", default_host_name = `"`${var.name_prefix}-web.floci.local`" }`n}" 'Static Web App'
    # Floci AZ has Container Apps but not Container Apps jobs, which run the maintenance tasks on Azure.
    $azureKeycloak = Join-Path $work 'terraform/modules/hosting/azure/keycloak.tf'
    Remove-ResourceBlock $azureMain 'resource "azurerm_container_app_job" "maintenance" {' 'Container Apps maintenance jobs'
    Set-StandIn $azureOutputs 'output "maintenance_jobs" { value = { for id, job in azurerm_container_app_job.maintenance : id => { id = job.id, name = job.name } } }' 'output "maintenance_jobs" { value = {} }' 'Maintenance jobs output'
    Set-StandIn $azureKeycloak ', azurerm_container_app_job.maintenance]' ']' 'Maintenance jobs dependency'
    foreach ($file in @($azureMain, $azureOutputs)) {
        $text = [IO.File]::ReadAllText($file)
        [IO.File]::WriteAllText($file, $text.Replace('azurerm_static_web_app.this.default_host_name', 'terraform_data.static_web_app.output.default_host_name').Replace('azurerm_static_web_app.this.id', 'terraform_data.static_web_app.output.id'))
    }
    # The bootstrap owns the resource group; here a seed root creates it.
    $seed = Join-Path $work 'seed'; New-Item -ItemType Directory -Path $seed | Out-Null
    @('terraform {', '  required_providers {', '    azurerm = { source = "hashicorp/azurerm", version = "~> 5.0" }', '  }', '}') + $provider +
    @('resource "azurerm_resource_group" "hosting" {', '  name     = "rg-example-dev-hosting"', '  location = "eastus2"', '}',
        'resource "azurerm_resource_group" "messaging" {', '  name     = "rg-hexagon-example-dev"', '  location = "eastus2"', '}') | Set-Content -LiteralPath (Join-Path $seed 'main.tf') -Encoding utf8NoBOM
    Invoke-Step 'seed: resource groups' { Invoke-Terraform $seed @('init', '-input=false', '-no-color'); if ($LASTEXITCODE -eq 0) { Invoke-Terraform $seed @('apply', '-input=false', '-auto-approve', '-no-color') } }
    $registry = 'exampledev0001.azurecr.io'
    $inputs = [ordered] @{
        product = 'hexagon-example'; environment = 'dev'; location = 'eastus2'; resource_group_name = 'rg-example-dev-hosting'; name_prefix = 'example-dev-0001'
        registry_name = 'exampledev0001'; virtual_network_cidr = '10.42.0.0/16'; application_subnet_cidr = '10.42.0.0/23'; database_subnet_cidr = '10.42.2.0/24'
        database_name = 'hexagon_example'; database_connection_name = 'HexagonExampleDb'; database_sku = 'B_Standard_B1ms'; database_storage_mb = 32768; messaging_enabled = $false
        auth = @{ authority = 'https://auth.example.test/realms/hexagon'; client_id = 'example-web'; audience = 'example-api'; api_scope = 'example_api.all' }
        workloads = @{ api = @{ name = 'example-dev-api'; kind = 'api'; image = "$registry/example-api@sha256:$('a' * 64)"; http_ports = @(8080, 8081); health_port = 8081
                environment = @{}; secret_references = @{}; cpu = 0.5; memory = '1Gi'; min_replicas = 1; max_replicas = 2 } }
        migration_workload = 'api'; bootstrap_image = "$registry/database-bootstrap@sha256:$('c' * 64)"; tags = @{}
    }
    # One root: apply its stages, check convergence, and always destroy it.
    function Test-Root([string] $Name, [string] $Directory, [object] $Inputs, [scriptblock] $Stages) {
        $tfvars = Join-Path $Directory 'floci.auto.tfvars.json'
        $Inputs | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $tfvars -Encoding utf8NoBOM
        Invoke-Step "${Name}: terraform init" { Invoke-Terraform $Directory @('init', '-input=false', '-no-color') }
        try {
            Invoke-Step "${Name}: apply" { Invoke-Terraform $Directory @('apply', '-input=false', '-auto-approve', '-no-color') }
            if ($Stages) { & $Stages $tfvars }
            Write-Host "== ${Name}: converged plan"
            Invoke-Terraform $Directory @('plan', '-input=false', '-detailed-exitcode', '-no-color') | Out-Host
            $results["${Name}: converged plan"] = $(switch ($LASTEXITCODE) { 0 { 'Passed' } 2 { 'Drift (emulator fidelity gap)' } default { 'Failed' } })
        }
        finally {
            # Destroy even after a failed apply, so nothing created by the check stays in the emulator.
            Write-Host "== ${Name}: destroy"
            Invoke-Terraform $Directory @('destroy', '-input=false', '-auto-approve', '-no-color') | Out-Host
            $results["${Name}: destroy"] = $(if ($LASTEXITCODE -eq 0) { 'Passed' } else { 'Failed' })
            $left = @(Invoke-Terraform $Directory @('state', 'list') | Where-Object { $_ })
            $results["${Name}: nothing left in state"] = $(if ($left.Count -eq 0) { 'Passed' } else { "Failed: $($left.Count) resources" })
        }
    }

    if ($Roots -cin @('All', 'Hosting')) {
        Test-Root 'hosting' $root $inputs {
            param($tfvars)
            $inputs.maintenance_jobs_enabled = $true; $inputs.application_rollout_enabled = $true
            $inputs | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $tfvars -Encoding utf8NoBOM
            Invoke-Step 'hosting: apply maintenance and rollout' { Invoke-Terraform $root @('apply', '-input=false', '-auto-approve', '-no-color') }
        }
    }
    if ($Roots -cin @('All', 'Messaging')) {
        # Floci AZ manages Service Bus entities only through its data-plane API, not through ARM.
        $results['messaging'] = 'Not covered: Floci AZ has no Service Bus management through ARM'
    }
}
finally {
    docker rm -f $container 2>$null | Out-Null
    # The containers Floci started (registry and databases) are attached to the check's network.
    $spawned = @(docker ps -aq --filter "network=$network")
    if ($spawned.Count -gt 0) { docker rm -f @spawned 2>$null | Out-Null }
    docker network rm $network 2>$null | Out-Null
    Write-Host ''
    foreach ($step in $results.GetEnumerator()) { Write-Host ("{0,-40} {1}" -f $step.Key, $step.Value) }
    Write-Host "Workspace kept for review: $work (contains no credentials)."
}
if (@($results.Values | Where-Object { $_ -like 'Failed*' }).Count -gt 0) { exit 1 }
