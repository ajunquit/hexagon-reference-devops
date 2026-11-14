<#
.SYNOPSIS
    Local check (ADR 0026): applies and destroys the hosting and messaging roots of a cloud against Floci.

.DESCRIPTION
    Not part of Test-Repository or CI. It starts the pinned Floci emulator of the chosen cloud with the
    Docker socket mounted, so the services Floci backs with real containers (ECS, RDS, ECR, PostgreSQL)
    run as such, and runs Terraform from its official Linux image in the emulator's network namespace,
    against a temporary copy of the roots with a local backend. Hosting goes through its initial
    state, then maintenance and rollout; messaging is applied from the example policy and the backend
    fixture contract. Each root ends with a convergence plan and a full destroy.

    Where Floci lacks a service the module uses, the temporary copy replaces it with a stand-in that is
    checked against the module text, so a change of the module stops the check instead of silently
    testing something else. Stand-ins and known gaps are listed in docs/pruebas-locales-floci.md.

    A passing run says Terraform creates, converges and destroys the root on an emulator. It never
    replaces the validation in the real cloud (D-9C and D-9C-AWS).

.PARAMETER Cloud
    Aws (hosting-aws and aws roots, Floci AWS) or Azure (hosting-azure and azure roots, Floci AZ).

.PARAMETER Roots
    All (default), Hosting or Messaging.

.PARAMETER Backend
    AWS only. A backend checkout (template-generated product with AWS SNS/SQS, or none). Instead of the
    infrastructure check, deploys that backend completely on Floci with the delivery's own code: images
    copied by digest to ECR, database tasks with RunTask, messaging bindings, rollout, backend health,
    the API and a published SPA through CloudFront; then destroys everything.

.PARAMETER FlociVersion
    An exact release published at least two weeks ago. Defaults to the version pinned by ADR 0026.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Aws', 'Azure')][string] $Cloud,
    [ValidateSet('All', 'Hosting', 'Messaging')][string] $Roots = 'All',
    [string] $Backend,
    [switch] $Rebuild,
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')][string] $FlociVersion,
    [string] $TerraformImage = 'hashicorp/terraform:1.17.1'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'docker is required.' }

$aws = $Cloud -ceq 'Aws'
if ($Backend) {
    if (-not $aws) { throw 'The full local deployment runs on AWS; Floci AZ lacks Container Apps jobs for the database tasks.' }
    $Backend = [IO.Path]::GetFullPath($Backend)
    if (-not (Test-Path -LiteralPath (Join-Path $Backend '.hexagon/backend-hosting-requirements.json'))) { throw 'The backend has no .hexagon/backend-hosting-requirements.json.' }
}
$pinned = $(if ($aws) { '2.3.0' } else { '0.15.0' })
$version = $(if ($FlociVersion) { $FlociVersion } else { $pinned })
$image = $(if ($aws) { "floci/floci:$version" } else { "floci/floci-az:$version" })
$port = $(if ($aws) { 4566 } else { 4577 })
$container = "hexagon-floci-$($Cloud.ToLowerInvariant())"
# Floci reaches the containers it starts (registry, databases) through this network.
$network = "hexagon-floci-$($Cloud.ToLowerInvariant())"
$work = Join-Path $repository "artifacts/floci-$($Cloud.ToLowerInvariant())-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $work | Out-Null
$results = [ordered] @{}

function Invoke-Step([string] $Name, [scriptblock] $Action) {
    Write-Host "== $Name"
    try { & $Action | Out-Host }
    catch { $results[$Name] = "Failed: $($_.Exception.Message)"; throw }
    $passed = $LASTEXITCODE -eq 0
    $results[$Name] = $(if ($passed) { 'Passed' } else { 'Failed' })
    if (-not $passed) { throw "Step failed: $Name" }
}

# Replaces an exact block of the temporary copy; a module that no longer has it stops the check.
function Set-StandIn([string] $Path, [string] $Original, [string] $Replacement, [string] $Name) {
    $text = [IO.File]::ReadAllText($Path).Replace("`r`n", "`n")
    if (-not $text.Contains($Original)) { throw "The module changed; review the stand-in '$Name' (docs/pruebas-locales-floci.md)." }
    [IO.File]::WriteAllText($Path, $text.Replace($Original, $Replacement))
    $results["stand-in: $Name"] = 'Applied'
}

# Removes a whole resource block of the temporary copy, found by its exact header.
function Remove-ResourceBlock([string] $Path, [string] $Header, [string] $Name) {
    $text = [IO.File]::ReadAllText($Path).Replace("`r`n", "`n")
    $start = $text.IndexOf($Header)
    $end = $(if ($start -ge 0) { $text.IndexOf("`n}`n", $start) } else { -1 })
    if ($start -lt 0 -or $end -lt 0) { throw "The module changed; review the stand-in '$Name' (docs/pruebas-locales-floci.md)." }
    [IO.File]::WriteAllText($Path, $text.Remove($start, $end + 3 - $start))
    $results["stand-in: $Name"] = 'Applied'
}

function Invoke-Terraform([string] $Directory, [string[]] $Arguments) {
    $relative = [IO.Path]::GetRelativePath($work, $Directory).Replace('\', '/')
    $environment = @('-e', 'TF_IN_AUTOMATION=1', '-e', 'TF_PLUGIN_CACHE_DIR=/plugins')
    if ($aws) {
        # localhost.floci.io and its subdomains resolve to 127.0.0.1: S3 and the account prefix of S3 Control reach Floci.
        $environment += @('-e', "AWS_ENDPOINT_URL=http://localhost.floci.io:$port", '-e', 'AWS_ACCESS_KEY_ID=test', '-e', 'AWS_SECRET_ACCESS_KEY=test',
            '-e', 'AWS_REGION=us-east-1', '-e', 'AWS_DEFAULT_REGION=us-east-1', '-e', 'AWS_EC2_METADATA_DISABLED=true')
    }
    else { $environment += @('-e', 'SSL_CERT_FILE=/work/floci-az.crt') }
    docker run --rm --network "container:$container" -v "${work}:/work" -v 'hexagon-terraform-plugins:/plugins' -w "/work/$relative" @environment $TerraformImage @Arguments
}

try {
    # The Docker socket lets Floci run real containers for the services it backs (owner decision, ADR 0026).
    docker rm -f $container 2>$null | Out-Null
    docker network inspect $network 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { docker network create $network | Out-Null }
    $arguments = @('run', '-d', '--rm', '--name', $container, '--network', $network, '--memory=4g', '-p', "127.0.0.1:${port}:$port", '-v', '/var/run/docker.sock:/var/run/docker.sock')
    # A deployment needs the ECR data plane on localhost and endpoints reachable from task containers.
    if ($Backend) {
        # The bootstrap accepts RDS hosts only. Resolve that name on the isolated Docker network.
        $databaseHost = "$container.rds.amazonaws.com"
        $arguments += @('--network-alias', $databaseHost, '-e', 'FLOCI_SERVICES_ECR_URI_STYLE=path',
            '-e', "FLOCI_HOSTNAME=$container", '-e', "FLOCI_SERVICES_RDS_ENDPOINT_HOST=$databaseHost",
            '-e', "FLOCI_SERVICES_CLOUDFRONT_ALLOWED_PRIVATE_ORIGIN_HOSTS=$container")
    }
    $arguments += $(if ($aws) { @('-e', "FLOCI_SERVICES_DOCKER_NETWORK=$network") } else { @('-e', 'FLOCI_AZ_TLS_ENABLED=true', '-e', "FLOCI_AZ_SERVICES_DOCKER_NETWORK=$network") })
    Invoke-Step 'Start Floci' { docker @arguments $image | Out-Null }
    $ready = $false
    foreach ($attempt in 1..60) {
        try {
            $probe = $(if ($aws) { "http://127.0.0.1:$port/_floci/health" } else { "http://127.0.0.1:$port/_floci/tls-cert" })
            Invoke-WebRequest -Uri $probe -TimeoutSec 2 | Out-Null; $ready = $true; break
        }
        catch { Start-Sleep -Seconds 1 }
    }
    if (-not $ready) { throw 'Floci did not become ready.' }
    if (-not $aws) { Invoke-WebRequest -Uri "http://127.0.0.1:$port/_floci/tls-cert" -OutFile (Join-Path $work 'floci-az.crt') }

    # A temporary copy of the roots, without provider directories, and with a local backend.
    $sourceRoot = Join-Path $repository 'terraform'
    foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force) {
        $relative = [IO.Path]::GetRelativePath($sourceRoot, $file.FullName)
        if (($relative -split '[\\/]') -ccontains '.terraform') { continue }
        $destination = Join-Path $work (Join-Path 'terraform' $relative)
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
        [IO.File]::Copy($file.FullName, $destination)
    }
    $root = Join-Path $work "terraform/environments/dev/$(if ($aws) { 'hosting-aws' } else { 'hosting-azure' })"
    $messagingRoot = Join-Path $work "terraform/environments/dev/$(if ($aws) { 'aws' } else { 'azure' })"
    foreach ($directory in @($root, $messagingRoot)) {
        @('terraform {', '  backend "local" {}', '}') | Set-Content -LiteralPath (Join-Path $directory 'backend_override.tf') -Encoding utf8NoBOM
    }
    $descriptor = [pscustomobject] @{ product = 'hexagon-example'; environment = 'dev' }
    $manifest = Get-Content -Raw -LiteralPath (Join-Path $repository 'tests/fixtures/backend/.hexagon/messaging-requirements.json') | ConvertFrom-Json

    if ($aws) {
        $web = Join-Path $work 'terraform/modules/hosting/aws/web.tf'
        $main = Join-Path $work 'terraform/modules/hosting/aws/main.tf'
        # Floci only has the S3 and DynamoDB AWS-managed prefix lists, and rejects their reserved names.
        Set-StandIn $main "data `"aws_ec2_managed_prefix_list`" `"cloudfront`" {`n  name = `"com.amazonaws.global.cloudfront.origin-facing`"`n}" `
            "resource `"aws_ec2_managed_prefix_list`" `"cloudfront`" {`n  name           = `"floci-cloudfront-origin-facing`"`n  address_family = `"IPv4`"`n  max_entries    = 1`n}" 'CloudFront prefix list'
        Set-StandIn $main 'data.aws_ec2_managed_prefix_list.cloudfront.id' 'aws_ec2_managed_prefix_list.cloudfront.id' 'CloudFront prefix list reference'
        # Floci has no CloudFront VPC origins: the applications origin reaches the load balancer as a custom origin.
        Set-StandIn $web "    vpc_origin_config {`n      vpc_origin_id = aws_cloudfront_vpc_origin.applications.id`n    }" `
            "    custom_origin_config {`n      http_port              = 80`n      https_port             = 443`n      origin_protocol_policy = `"http-only`"`n      origin_ssl_protocols   = [`"TLSv1.2`"]`n    }" 'CloudFront VPC origin'
        if ($Backend) {
            # The one local ALB listener shares Floci's container. Its private host is allowlisted above.
            Set-StandIn $web 'domain_name = aws_lb.this.dns_name' "domain_name = `"$container`"" 'CloudFront local ALB endpoint'
            # Floci stores Functions without executing JavaScript. A separate static distribution
            # exercises its supported fallback API without rewriting errors from the applications origin.
            $fallback = @'
resource "aws_cloudfront_distribution" "floci_spa" {
  enabled             = true
  default_root_object = "index.html"
  origin {
    origin_id                = "web"
    domain_name              = aws_s3_bucket.web.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.web.id
  }
  default_cache_behavior {
    target_origin_id           = "web"
    viewer_protocol_policy     = "allow-all"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    cache_policy_id            = local.cache_optimized
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id
  }
  dynamic "custom_error_response" {
    for_each = toset([403, 404])
    content {
      error_code            = custom_error_response.value
      response_code         = 200
      response_page_path    = "/index.html"
      error_caching_min_ttl = 0
    }
  }
  restrictions {
    geo_restriction { restriction_type = "none" }
  }
  viewer_certificate { cloudfront_default_certificate = true }
}
output "floci_spa_fallback" { value = aws_cloudfront_distribution.floci_spa.id }
resource "aws_s3_bucket_policy" "web" {
'@
            Set-StandIn $web 'resource "aws_s3_bucket_policy" "web" {' $fallback 'CloudFront Function fallback'
            Set-StandIn $web '"AWS:SourceArn" = aws_cloudfront_distribution.web.arn' `
                '"AWS:SourceArn" = [aws_cloudfront_distribution.web.arn, aws_cloudfront_distribution.floci_spa.arn]' 'CloudFront fallback bucket access'
            'output "floci_spa_fallback" { value = module.hosting.floci_spa_fallback }' |
                Set-Content -LiteralPath (Join-Path $root 'floci_spa.tf') -Encoding utf8NoBOM
        }
        # Floci returns the function code base64-encoded, so every plan would rewrite it and its publication fails.
        Set-StandIn $web "  publish = true`n  code    = <<-EOT" "  publish = true`n  lifecycle {`n    ignore_changes = [code]`n  }`n  code    = <<-EOT" 'CloudFront function code read-back'
        Remove-ResourceBlock $web 'resource "aws_cloudfront_vpc_origin" "applications" {' 'CloudFront VPC origin resource'
        Import-Module (Join-Path $repository 'scripts/AwsSnsSqsContracts.psm1') -Force
        $messagingPolicy = Get-Content -Raw -LiteralPath (Join-Path $repository 'examples/aws-sns-sqs-policy.json') | ConvertFrom-Json
        $manifest.provider = 'aws-sns-sqs'
        $messagingInputs = ConvertTo-AwsSnsSqsTerraformInput -Descriptor $descriptor -Policy $messagingPolicy -Manifest $manifest
        # Hosting creates the workload roles in an environment; here a seed root creates the ones the policy names.
        $seed = Join-Path $work 'seed'; New-Item -ItemType Directory -Path $seed | Out-Null
        $roleLines = @('terraform {', '  required_providers {', '    aws = { source = "hashicorp/aws", version = "~> 6.0" }', '  }', '}', 'provider "aws" {}')
        foreach ($role in @($messagingPolicy.workloadRoleNames.PSObject.Properties.Value | Sort-Object -Unique)) {
            $roleLines += @("resource `"aws_iam_role`" `"$($role.Replace('-', '_'))`" {", "  name               = `"$role`"",
                '  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "ecs-tasks.amazonaws.com" } }] })', '}')
        }
        $roleLines | Set-Content -LiteralPath (Join-Path $seed 'main.tf') -Encoding utf8NoBOM
        $registry = '000000000000.dkr.ecr.us-east-1.amazonaws.com/flc-dev'
        $inputs = [ordered] @{
            product = 'hexagon-example'; environment = 'dev'; account_id = '000000000000'; region = 'us-east-1'; name_prefix = 'flc-dev'
            availability_zones = @('us-east-1a', 'us-east-1b'); vpc_cidr = '10.42.0.0/16'; public_subnet_cidrs = @('10.42.0.0/24', '10.42.1.0/24'); database_subnet_cidrs = @('10.42.10.0/24', '10.42.11.0/24')
            database_name = 'hexagon_example'; database_connection_name = 'HexagonExampleDb'; messaging_enabled = $false
            auth = @{ authority = 'https://auth.example.test/realms/hexagon'; client_id = 'example-web'; audience = 'example-api'; api_scope = 'example_api.all' }
            workloads = @{ 'hexagon-example-api' = @{ name = 'flc-dev-api'; kind = 'api'; image = "$registry/hexagon-example-api@sha256:$('d' * 64)"; http_ports = @(8080, 8081); health_port = 8081
                    environment = @{}; secret_references = @{}; cpu = 256; memory = 512; min_replicas = 1; max_replicas = 2 } }
            migration_workload = 'hexagon-example-api'; bootstrap_image = "$registry/database-bootstrap@sha256:$('f' * 64)"; tags = @{}
        }
    }
    else {
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

    # Full local deployment (ADR 0026, L-01 increment 3): the backend's real images go through the
    # delivery's own code paths against Floci, and the result is checked through CloudFront.
    function Invoke-Deployment {
        Import-Module (Join-Path $repository 'scripts/AwsApplicationDelivery.psm1') -Force
        function Copy-Value([object] $Value) { return (ConvertTo-PlatformBootstrapJson $Value) | ConvertFrom-Json -AsHashtable -Depth 40 }
        $script:deployInventory = Get-Content -Raw -LiteralPath (Join-Path $repository 'examples/environment-inventory-aws.json') | ConvertFrom-Json -AsHashtable -Depth 32
        $script:deployInventory.target.accountId = '000000000000'
        $script:deployInventory.target.roleArn = $script:deployInventory.target.roleArn.Replace('123456789012', '000000000000')
        $script:deployInventory.target.stateKmsKeyArn = $script:deployInventory.target.stateKmsKeyArn.Replace('123456789012', '000000000000')
        $script:deployInventory.target.stateBucket = $script:deployInventory.target.stateBucket.Replace('123456789012', '000000000000')
        # The AWS CLI of the delivery talks to Floci, with throwaway credentials and no profile.
        foreach ($pair in @{ AWS_ENDPOINT_URL = "http://127.0.0.1:$port"; AWS_ACCESS_KEY_ID = 'test'; AWS_SECRET_ACCESS_KEY = 'test'; AWS_REGION = 'us-east-1'; AWS_DEFAULT_REGION = 'us-east-1'
                AWS_EC2_METADATA_DISABLED = 'true'; AWS_SHARED_CREDENTIALS_FILE = (Join-Path $work 'none'); AWS_CONFIG_FILE = (Join-Path $work 'none') }.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable($pair.Key, $pair.Value)
        }
        # An empty profile is still a profile for the AWS CLI: remove the variables, do not blank them.
        foreach ($name in @('AWS_PROFILE', 'AWS_SESSION_TOKEN')) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
        foreach ($name in @('AwsEnvironmentStore', 'TerraformAwsLifecycle', 'AwsOciDelivery', 'AwsMaintenanceDelivery', 'AwsWebDelivery', 'StaticWebPublication', 'PlatformBootstrap')) { Import-Module (Join-Path $repository "scripts/$name.psm1") }
        $prefix = $script:deployInventory.roots[0].namePrefix
        $server = '000000000000.dkr.ecr.us-east-1.amazonaws.com'
        $backendManifest = Get-Content -Raw -LiteralPath (Join-Path $Backend '.hexagon/backend-hosting-requirements.json') | ConvertFrom-Json -AsHashtable
        $messagingPath = Join-Path $Backend '.hexagon/messaging-requirements.json'
        $backendMessaging = $(if (Test-Path -LiteralPath $messagingPath) { Get-Content -Raw -LiteralPath $messagingPath | ConvertFrom-Json } else { $null })
        if ($null -ne $backendMessaging -and $backendMessaging.provider -cne 'aws-sns-sqs') { throw 'The backend must declare aws-sns-sqs messaging, or none.' }

        # Images: the operational bootstrap and every workload, as linux/amd64 OCI archives.
        # Images are reused between runs of the same backend and DevOps commits; -Rebuild forces a build.
        $commits = (& git -C $Backend rev-parse HEAD) + '-' + (& git -C $repository rev-parse HEAD)
        $images = Join-Path $repository "artifacts/floci-images/$($commits.Substring(0, 12))-$($commits.Substring(41, 12))"
        if ($Rebuild -and (Test-Path -LiteralPath $images)) { Remove-Item -LiteralPath $images -Recurse -Force }
        New-Item -ItemType Directory -Path $images -Force | Out-Null
        $builds = [ordered] @{ 'database-bootstrap' = (Join-Path $repository 'operations/Hexagon.Database.Bootstrap') }
        foreach ($workload in $backendManifest.workloads) { $builds[$workload.id] = Join-Path $Backend $workload.project }
        $archives = @{}
        foreach ($id in $builds.Keys) {
            $archive = Join-Path $images "$id.oci.tar"
            if (Test-Path -LiteralPath $archive) { $results["build image: $id"] = 'Reused' }
            else { Invoke-Step "build image: $id" {
                dotnet publish $builds[$id] -c Release --os linux --arch x64 -t:PublishContainer "-p:ContainerRepository=$id" '-p:ContainerImageTag=floci' '-p:ContainerUser=app' '-p:ContainerImageFormat=OCI' "-p:ContainerArchiveOutputPath=$archive" --nologo -v q
            } }
            $metadata = & (Join-Path $repository 'scripts/Get-OciArchiveMetadata.ps1') $archive
            $archives[$id] = @{ file = $archive; sha256 = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
                target = @{ repository = "$prefix/$id"; digest = $metadata.imageDigest; image = "$server/$prefix/$id@$($metadata.imageDigest)" } }
        }

        # A local lifecycle context: the AWS CLI and the registry go to Floci; the custody lives in memory.
        $script:objects = @{}
        $memory = {
            param($operation, $key, $bytes, $ifNoneMatch, $ifMatch)
            if ($operation -ceq 'Get') { if (-not $script:objects.ContainsKey($key)) { return @{ status = 404 } }; return @{ status = 200; bytes = $script:objects[$key].bytes; etag = $script:objects[$key].etag } }
            $exists = $script:objects.ContainsKey($key)
            if (($ifNoneMatch -and $exists) -or ($ifMatch -and (-not $exists -or $script:objects[$key].etag -cne $ifMatch))) { return @{ status = 412 } }
            $etag = '"' + [guid]::NewGuid().ToString('N') + '"'; $script:objects[$key] = @{ bytes = $bytes; etag = $etag }; return @{ status = 200; etag = $etag }
        }
        $context = New-AwsLifecycleContext $script:deployInventory "arn:aws:sts::000000000000:assumed-role/$(($script:deployInventory.target.roleArn -split '/')[-1])/floci" '000000000000' $memory
        Enter-AwsLifecycleLease $context -Confirm:$false
        $context.runtime = Join-Path $work 'runtime'; New-Item -ItemType Directory -Path $context.runtime | Out-Null
        $context.awsCli = {
            param($arguments)
            $output = & aws @arguments 2>&1
            $text = ($output | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] }) -join "`n"
            @{ exitCode = $LASTEXITCODE; text = $text; errorText = (($output | Where-Object { $_ -is [Management.Automation.ErrorRecord] }) -join "`n") }
        }
        $account = '000000000000'; $region = 'us-east-1'
        $context.registryHttp = {
            param($Method, $Server, $Path, $Authorization, $Body, $File, $ContentType)
            # Floci serves ECR path-style: /v2/<account>/<region>/<repository>/...
            $handler = [Net.Http.HttpClientHandler]::new(); $handler.AllowAutoRedirect = $false
            $client = [Net.Http.HttpClient]::new($handler); $client.Timeout = [TimeSpan]::FromMinutes(15)
            $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), "http://127.0.0.1:$port$($Path -replace '^/v2/', "/v2/$account/$region/")")
            $request.Headers.Accept.ParseAdd('application/vnd.oci.image.manifest.v1+json')
            $stream = $null
            try {
                if ($File) { $stream = [IO.File]::OpenRead($File); $request.Content = [Net.Http.StreamContent]::new($stream) }
                elseif ($null -ne $Body) { $request.Content = [Net.Http.ByteArrayContent]::new($Body) }
                if ($null -ne $request.Content) { $request.Content.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::Parse($ContentType) }
                $response = $client.SendAsync($request).GetAwaiter().GetResult()
                $headers = @{}
                foreach ($header in @($response.Headers) + @($response.Content.Headers)) { $headers[$header.Key] = ($header.Value -join ',') }
                if ($headers.ContainsKey('Location')) {
                    $location = [uri]::new([uri] "http://127.0.0.1:$port/", $headers.Location)
                    $headers.Location = "https://$Server" + ($location.PathAndQuery -replace "^/v2/$account/$region/", '/v2/')
                }
                return @{ status = [int] $response.StatusCode; headers = $headers }
            }
            finally { if ($null -ne $stream) { $stream.Dispose() }; $request.Dispose(); $client.Dispose() }
        }

        # Hosting inputs from the backend contract, with every image pinned by digest in the instance registry.
        $names = @{}; $index = 0
        foreach ($workload in $backendManifest.workloads) { $names[$workload.id] = "$prefix-w$index"; $index++ }
        $hostingInputs = [ordered] @{
            product = $script:deployInventory.product; environment = 'dev'; account_id = $account; region = $region; name_prefix = $prefix; instance_id = $script:deployInventory.instance.id
            availability_zones = @('us-east-1a', 'us-east-1b'); vpc_cidr = '10.42.0.0/16'; public_subnet_cidrs = @('10.42.0.0/24', '10.42.1.0/24'); database_subnet_cidrs = @('10.42.10.0/24', '10.42.11.0/24')
            database_name = 'hexagon_local'; database_connection_name = $backendManifest.database.connectionName; messaging_enabled = $null -ne $backendMessaging
            auth = @{ authority = 'https://auth.example.test/realms/hexagon'; client_id = 'local-web'; audience = $backendManifest.identity.audience; api_scope = $backendManifest.identity.apiScope }
            workloads = [ordered] @{}; migration_workload = $backendManifest.migrations.workload; bootstrap_image = $archives['database-bootstrap'].target.image; tags = @{}
        }
        foreach ($workload in $backendManifest.workloads) {
            $hostingInputs.workloads[$workload.id] = [ordered] @{ name = $names[$workload.id]; kind = $workload.kind; image = $archives[$workload.id].target.image
                http_ports = @($workload.httpPorts); health_port = $workload.healthPort; environment = @{}; secret_references = @{}; cpu = 256; memory = 512; min_replicas = 1; max_replicas = 1 }
        }
        $hostingTfvars = Join-Path $root 'floci.auto.tfvars.json'
        $writeHosting = { (ConvertTo-PlatformBootstrapJson $script:hostingInputs) | Set-Content -LiteralPath $hostingTfvars -Encoding utf8NoBOM }
        $script:hostingInputs = Copy-Value $hostingInputs; & $writeHosting
        $output = { param($directory, $name) (Invoke-Terraform $directory @('output', '-json', $name)) -join "`n" | ConvertFrom-Json -AsHashtable -Depth 40 }

        Invoke-Step 'deploy: hosting init' { Invoke-Terraform $root @('init', '-input=false', '-no-color') }
        Invoke-Step 'deploy: messaging init' { Invoke-Terraform $messagingRoot @('init', '-input=false', '-no-color') }
        try {
            Invoke-Step 'deploy: infrastructure' { Invoke-Terraform $root @('apply', '-input=false', '-auto-approve', '-no-color') }
            if ($null -ne $backendMessaging) {
                $roles = & $output $root 'workload_roles'
                $policy = [pscustomobject] @{ product = $backendManifest.product; environment = 'dev'; region = $region; kmsAliasName = "$prefix-messaging"; tags = [pscustomobject] @{}
                    destinations = @($backendMessaging.destinations | ForEach-Object { [pscustomobject] @{ id = $_.id; topicName = "$prefix-$($_.id)" } })
                    consumers = @($backendMessaging.consumers | ForEach-Object { [pscustomobject] @{ id = $_.id; queueName = "$prefix-$($_.id)"; visibilityTimeoutSeconds = 60; messageRetentionSeconds = 345600
                                receiveMessageWaitTimeSeconds = 20; retryVisibilityTimeoutSeconds = 30; redrive = [pscustomobject] @{ enabled = $false } } })
                    workloadRoleNames = [pscustomobject] @{} }
                foreach ($id in $roles.Keys) { $policy.workloadRoleNames | Add-Member -NotePropertyName $id -NotePropertyValue $roles[$id].name }
                Import-Module (Join-Path $repository 'scripts/AwsSnsSqsContracts.psm1') -Force
                $messagingInputs = ConvertTo-AwsSnsSqsTerraformInput -Descriptor ([pscustomobject] @{ product = $backendManifest.product; environment = 'dev' }) -Policy $policy -Manifest $backendMessaging
                $messagingInputs | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath (Join-Path $messagingRoot 'floci.auto.tfvars.json') -Encoding utf8NoBOM
                Invoke-Step 'deploy: messaging' { Invoke-Terraform $messagingRoot @('apply', '-input=false', '-auto-approve', '-no-color') }
                # The delivery's own binding of SNS topics and SQS queues into each workload.
                $script:hostingInputs = Add-AwsMessagingBindings $script:hostingInputs (& $output $messagingRoot 'aws_sns_sqs').workload_bindings
                $results['deploy: messaging bindings'] = 'Passed'
            }
            $login = Invoke-AwsLifecycleCli $context @('ecr', 'get-login-password')
            if ($login.exitCode -ne 0 -or -not $login.text) { throw "ECR login failed ($($login.exitCode)): $($login.errorText) $($login.text)" }
            foreach ($id in $archives.Keys) {
                Invoke-Step "deploy: push $id" { Publish-AwsOciArchive $context $archives[$id] $server -Confirm:$false | Out-Null; $global:LASTEXITCODE = 0 }
            }
            $script:hostingInputs.maintenance_jobs_enabled = $true; & $writeHosting
            Invoke-Step 'deploy: maintenance tasks registered' { Invoke-Terraform $root @('apply', '-input=false', '-auto-approve', '-no-color') }
            $hosting = { @{ inputs = $script:hostingInputs; outputs = @{ maintenance_tasks = (& $output $root 'maintenance_tasks'); task_network = (& $output $root 'task_network')
                        database_bootstrap = (& $output $root 'database_bootstrap'); web = (& $output $root 'web'); frontend_authentication = (& $output $root 'frontend_authentication'); keycloak = $null } } }
            $state = & $hosting
            foreach ($task in @('database-credentials', 'migrations', 'database-access')) {
                Invoke-Step "deploy: task $task" {
                    $spec = Get-AwsDeliveryTaskSpec $context $state $task
                    $record = Invoke-AwsDeliveryMaintenance $context $task $spec $null { param($value) } 1800 5 -Confirm:$false
                    if ($record.status -cne 'Succeeded') { throw "Task $task did not succeed." }
                    $global:LASTEXITCODE = 0
                }
            }
            $script:hostingInputs.application_rollout_enabled = $true; & $writeHosting
            Invoke-Step 'deploy: rollout' { Invoke-Terraform $root @('apply', '-input=false', '-auto-approve', '-no-color') }
            $state = & $hosting
            Invoke-Step 'deploy: backend health' {
                $deadline = [DateTime]::UtcNow.AddMinutes(10); $last = $null
                while ($true) {
                    try { Get-AwsBackendHealth $context $state | Out-Null; break }
                    catch { $last = $_.Exception.Message; if ([DateTime]::UtcNow -gt $deadline) { throw "Backend not healthy: $last" }; Start-Sleep -Seconds 10 }
                }
                $global:LASTEXITCODE = 0
            }
            $distribution = $state.outputs.web.distribution_id.ToLowerInvariant()
            $viewer = "http://$distribution.cloudfront.localhost.floci.io:$port"
            Invoke-Step 'deploy: API through CloudFront' {
                $response = Invoke-WebRequest -Uri "$viewer/api/v1/floci-probe" -SkipHttpErrorCheck -TimeoutSec 30
                # The API answers with its own ProblemDetails (a 401 or a 404), never CloudFront's error page.
                if ($response.StatusCode -notin @(401, 404) -or ($response.StatusCode -eq 404 -and $response.Headers['Content-Type'] -notmatch 'application/problem\+json')) { throw "Unexpected API response $($response.StatusCode)." }
                $global:LASTEXITCODE = 0
            }
            Invoke-Step 'deploy: SPA through CloudFront' {
                $bundle = Join-Path $work 'web.tar.gz'
                $file = [IO.File]::Create($bundle); $gzip = [IO.Compression.GZipStream]::new($file, [IO.Compression.CompressionLevel]::Fastest); $tar = [System.Formats.Tar.TarWriter]::new($gzip)
                try {
                    foreach ($entry in @(@('index.html', '<!doctype html><title>Hexagon local</title><div id="app">Hexagon on Floci</div>'), @('main-floci.js', 'console.log("floci");'))) {
                        $item = [System.Formats.Tar.PaxTarEntry]::new([System.Formats.Tar.TarEntryType]::RegularFile, $entry[0]); $item.DataStream = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($entry[1]))
                        try { $tar.WriteEntry($item) } finally { $item.DataStream.Dispose() }
                    }
                }
                finally { $tar.Dispose(); $gzip.Dispose(); $file.Dispose() }
                $frontend = Get-Content -Raw -LiteralPath (Join-Path $repository 'tests/fixtures/hosting/frontend.json') | ConvertFrom-Json
                $publicOutputs = @{ api_url = @{ value = "$($state.outputs.web.url)/api/v1" }; frontend_authentication = @{ value = $state.outputs.frontend_authentication } }
                $payload = New-StaticWebPayload $bundle (Get-FileHash -LiteralPath $bundle -Algorithm SHA256).Hash.ToLowerInvariant() $frontend $publicOutputs ('a' * 64) ('b' * 64) (Join-Path $context.runtime 'spa') -Confirm:$false
                $script:flociPayload = $payload
                $target = @{ bucket = $state.outputs.web.bucket; distributionId = $state.outputs.web.distribution_id; origin = $state.outputs.web.url }
                Publish-AwsWebPayload $context $target $payload 600 2 -Confirm:$false | Out-Null
                foreach ($path in @('/', '/runtime-config.json')) {
                    $response = Invoke-WebRequest -Uri "$viewer$path" -SkipHttpErrorCheck -TimeoutSec 30
                    $expected = $(if ($path -ceq '/runtime-config.json') { 'runtime-config.json' } else { 'index.html' })
                    $sha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($response.RawContentStream.ToArray())).ToLowerInvariant()
                    if ($response.StatusCode -ne 200 -or $sha -cne $payload.files[$expected].sha256) { throw "CloudFront did not serve $path from the published SPA." }
                }
                $global:LASTEXITCODE = 0
            }
            Invoke-Step 'deploy: SPA fallback stand-in' {
                $staticDistribution = (& $output $root 'floci_spa_fallback').ToLowerInvariant()
                $response = Invoke-WebRequest -Uri "http://$staticDistribution.cloudfront.localhost.floci.io:$port/__hexagon_probe__/route/$($script:flociPayload.deploymentSha256.Substring(0, 16))" -SkipHttpErrorCheck -TimeoutSec 30
                $sha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($response.RawContentStream.ToArray())).ToLowerInvariant()
                if ($response.StatusCode -ne 200 -or $sha -cne $script:flociPayload.files['index.html'].sha256) { throw 'CloudFront SPA fallback did not serve the published entry point.' }
                $global:LASTEXITCODE = 0
            }
            Invoke-Step 'deploy: API preserves its 404' {
                $response = Invoke-WebRequest -Uri "$viewer/api/v1/__hexagon_probe__/missing" -SkipHttpErrorCheck -TimeoutSec 30
                if ($response.StatusCode -ne 404 -or ([string] $response.Headers['Content-Type']) -notmatch 'application/problem\+json') { throw 'The API 404 was replaced by the SPA fallback.' }
                $global:LASTEXITCODE = 0
            }
        }
        finally {
            # Evidence before destroying: the output of every container the tasks and services ran.
            $logs = Join-Path $work 'logs'; New-Item -ItemType Directory -Path $logs -Force | Out-Null
            # Floci removes stopped task containers; their output stays in its CloudWatch Logs.
            foreach ($group in @((& aws logs describe-log-groups --query 'logGroups[].logGroupName' --output json 2>$null) -join '' | ConvertFrom-Json)) {
                $file = Join-Path $logs (($group -replace '[^A-Za-z0-9.-]', '_') + '.log')
                $events = (& aws logs filter-log-events --log-group-name $group --query 'events[].[logStreamName,message]' --output text 2>$null)
                [IO.File]::WriteAllLines($file, [string[]] @($events))
                Write-Host "--- $group (last lines)"; @($events) | Select-Object -Last 40 | Out-Host
            }
            Write-Host '== deploy: destroy'
            if ($null -ne $backendMessaging) {
                Invoke-Terraform $messagingRoot @('destroy', '-input=false', '-auto-approve', '-no-color') | Out-Host
                $results['deploy: destroy messaging'] = $(if ($LASTEXITCODE -eq 0) { 'Passed' } else { 'Failed' })
            }
            Invoke-Terraform $root @('destroy', '-input=false', '-auto-approve', '-no-color') | Out-Host
            $results['deploy: destroy hosting'] = $(if ($LASTEXITCODE -eq 0) { 'Passed' } else { 'Failed' })
            $left = @(Invoke-Terraform $root @('state', 'list') | Where-Object { $_ }) + @(Invoke-Terraform $messagingRoot @('state', 'list') | Where-Object { $_ })
            $results['deploy: nothing left in state'] = $(if ($left.Count -eq 0) { 'Passed' } else { "Failed: $($left.Count) resources" })
            Exit-AwsLifecycleLease $context -Confirm:$false
        }
    }

    if ($Backend) { Invoke-Deployment }
    elseif ($Roots -cin @('All', 'Hosting')) {
        Test-Root 'hosting' $root $inputs {
            param($tfvars)
            $inputs.maintenance_jobs_enabled = $true; $inputs.application_rollout_enabled = $true
            $inputs | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $tfvars -Encoding utf8NoBOM
            Invoke-Step 'hosting: apply maintenance and rollout' { Invoke-Terraform $root @('apply', '-input=false', '-auto-approve', '-no-color') }
        }
    }
    if (-not $Backend -and $Roots -cin @('All', 'Messaging')) {
        if ($aws) {
            Invoke-Step 'seed: workload roles' { Invoke-Terraform $seed @('init', '-input=false', '-no-color'); if ($LASTEXITCODE -eq 0) { Invoke-Terraform $seed @('apply', '-input=false', '-auto-approve', '-no-color') } }
        }
        if ($aws) { Test-Root 'messaging' $messagingRoot $messagingInputs $null }
        # Floci AZ manages Service Bus entities only through its data-plane API, not through ARM.
        else { $results['messaging'] = 'Not covered: Floci AZ has no Service Bus management through ARM' }
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
