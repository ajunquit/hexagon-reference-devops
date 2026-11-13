<#
.SYNOPSIS
    Optional local check (ADR 0025): applies and destroys the hosting-aws root against AWS Emulator in Docker.

.DESCRIPTION
    Not part of Test-Repository or CI. It builds the emulator image from an exact LTS version, starts it
    on 127.0.0.1 with telemetry off, and runs Terraform with a local backend in a temporary copy of the
    roots: initial state, then maintenance and rollout, a convergence plan and a full destroy.
    The emulator covers mostly the control plane: it does not run real ECS containers or RDS engines and
    does not evaluate IAM, so this never replaces the validation in AWS (D-9C-AWS).

.PARAMETER EmulatorVersion
    An LTS version from https://downloads.aws.com/aws-emulator/packages/aws-emulator/LTS/versions.json,
    such as 1.0.191. Choose one published at least two weeks ago.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^1\.[0-9]+\.[0-9]+$')][string] $EmulatorVersion,
    [ValidateRange(1024, 65535)][int] $Port = 9297
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
foreach ($tool in @('docker', 'terraform')) { if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "$tool is required." } }

$work = Join-Path $repository "artifacts/aws-emulator-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $work | Out-Null
$arch = $(if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') { 'aarch64' } else { 'x86_64' })
$image = "hexagon-aws-emulator:$EmulatorVersion"
$container = "hexagon-aws-emulator-$Port"
$shared = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.aws/emulator'
$saved = @{}
$names = @('AWS_ENDPOINT_URL', 'AWS_SHARED_CREDENTIALS_FILE', 'AWS_CONFIG_FILE', 'AWS_CA_BUNDLE', 'AWS_EC2_METADATA_DISABLED', 'AWS_DISABLE_HOST_PREFIX_INJECTION',
    'AWS_REGION', 'AWS_DEFAULT_REGION', 'AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'AWS_SESSION_TOKEN', 'AWS_PROFILE', 'TF_CLI_ARGS', 'TF_DATA_DIR')
foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
$results = [ordered] @{}
function Invoke-Step([string] $Name, [scriptblock] $Action) {
    Write-Host "== $Name"
    & $Action
    if ($LASTEXITCODE -ne 0) { $results[$Name] = 'Failed'; throw "Step failed: $Name" }
    $results[$Name] = 'Passed'
}

try {
    # The exact package of the chosen version; the image is built locally, never pulled.
    @(
        'FROM public.ecr.aws/amazonlinux/amazonlinux:2023-minimal',
        "ADD https://downloads.aws.com/aws-emulator/packages/aws-emulator/LTS/aws-emulator-$EmulatorVersion-1-$arch.rpm /tmp/aws-emulator.rpm",
        'RUN rpm -i /tmp/aws-emulator.rpm && rm /tmp/aws-emulator.rpm && mkdir -p /home/emulator && chown 1000 /home/emulator',
        'USER 1000', 'ENV HOME=/home/emulator', "EXPOSE $Port", 'ENTRYPOINT ["aws-emulator", "-b", "0.0.0.0"]'
    ) | Set-Content -LiteralPath (Join-Path $work 'Dockerfile') -Encoding utf8NoBOM
    Invoke-Step 'Build emulator image' { docker build --quiet -t $image $work | Out-Null }
    New-Item -ItemType Directory -Force -Path $shared | Out-Null
    Invoke-Step 'Start emulator' { docker run -d --rm --name $container --memory=2g --memory-swap=2g -p "127.0.0.1:${Port}:$Port" -v "${shared}:/home/emulator/.aws/emulator" $image -p $Port --telemetry off | Out-Null }
    $files = Join-Path $shared "$Port"
    $ready = $false
    foreach ($attempt in 1..60) {
        try { if ((Invoke-WebRequest -Uri "https://127.0.0.1:$Port/__admin/health" -SkipCertificateCheck -TimeoutSec 2).Content -match 'ok') { $ready = $true; break } } catch { }
        Start-Sleep -Seconds 1
    }
    if (-not $ready -or -not (Test-Path (Join-Path $files 'ca.pem'))) { throw 'The emulator did not become healthy.' }

    # Only the emulator: no real credentials, profiles or Terraform overrides survive in this process.
    foreach ($name in @('AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'AWS_SESSION_TOKEN', 'AWS_PROFILE', 'TF_CLI_ARGS', 'TF_DATA_DIR')) { [Environment]::SetEnvironmentVariable($name, $null) }
    $env:AWS_ENDPOINT_URL = "https://127.0.0.1:$Port"
    $env:AWS_SHARED_CREDENTIALS_FILE = Join-Path $files 'emulator_credentials'
    $env:AWS_CONFIG_FILE = Join-Path $files 'config'
    $env:AWS_CA_BUNDLE = Join-Path $files 'ca.pem'
    $env:AWS_EC2_METADATA_DISABLED = 'true'; $env:AWS_DISABLE_HOST_PREFIX_INJECTION = 'true'
    $env:AWS_REGION = 'us-east-1'; $env:AWS_DEFAULT_REGION = 'us-east-1'

    # A temporary copy of the roots with a local backend: no real state is ever touched.
    Copy-Item -LiteralPath (Join-Path $repository 'terraform') -Destination (Join-Path $work 'terraform') -Recurse
    $root = Join-Path $work 'terraform/environments/dev/hosting-aws'
    Get-ChildItem -LiteralPath $root -Filter '.terraform' -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
    'terraform { backend "local" {} }' | Set-Content -LiteralPath (Join-Path $root 'backend_override.tf') -Encoding utf8NoBOM
    $registry = '000000000000.dkr.ecr.us-east-1.amazonaws.com/emu-dev'
    $inputs = [ordered] @{
        product = 'hexagon-example'; environment = 'dev'; account_id = '000000000000'; region = 'us-east-1'; name_prefix = 'emu-dev'
        availability_zones = @('us-east-1a', 'us-east-1b'); vpc_cidr = '10.42.0.0/16'; public_subnet_cidrs = @('10.42.0.0/24', '10.42.1.0/24'); database_subnet_cidrs = @('10.42.10.0/24', '10.42.11.0/24')
        database_name = 'hexagon_example'; database_connection_name = 'HexagonExampleDb'; messaging_enabled = $false
        auth = @{ authority = 'https://auth.example.test/realms/hexagon'; client_id = 'example-web'; audience = 'example-api'; api_scope = 'example_api.all' }
        workloads = @{ 'hexagon-example-api' = @{ name = 'emu-dev-api'; kind = 'api'; image = "$registry/hexagon-example-api@sha256:$('d' * 64)"; http_ports = @(8080, 8081); health_port = 8081
                environment = @{}; secret_references = @{}; cpu = 256; memory = 512; min_replicas = 1; max_replicas = 2 } }
        migration_workload = 'hexagon-example-api'; bootstrap_image = "$registry/database-bootstrap@sha256:$('f' * 64)"; tags = @{}
    }
    $tfvars = Join-Path $root 'emulator.auto.tfvars.json'
    $inputs | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tfvars -Encoding utf8NoBOM
    Invoke-Step 'terraform init' { terraform "-chdir=$root" init -input=false -no-color | Out-Null }
    Invoke-Step 'apply: initial state' { terraform "-chdir=$root" apply -input=false -auto-approve -no-color }
    $inputs.maintenance_jobs_enabled = $true; $inputs.application_rollout_enabled = $true
    $inputs | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tfvars -Encoding utf8NoBOM
    Invoke-Step 'apply: maintenance and rollout' { terraform "-chdir=$root" apply -input=false -auto-approve -no-color }
    Write-Host '== converged plan'
    terraform "-chdir=$root" plan -input=false -detailed-exitcode -no-color | Out-Null
    $results['converged plan'] = $(switch ($LASTEXITCODE) { 0 { 'Passed' } 2 { 'Drift (emulator fidelity gap)' } default { 'Failed' } })
    Invoke-Step 'destroy' { terraform "-chdir=$root" destroy -input=false -auto-approve -no-color }
    $left = @(terraform "-chdir=$root" state list)
    $results['nothing left in state'] = $(if ($left.Count -eq 0) { 'Passed' } else { "Failed: $($left.Count) resources" })
}
finally {
    docker rm -f $container 2>$null | Out-Null
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    Write-Host ''
    foreach ($step in $results.GetEnumerator()) { Write-Host ("{0,-32} {1}" -f $step.Key, $step.Value) }
    Write-Host "Workspace kept for review: $work (contains no credentials)."
}
if (@($results.Values | Where-Object { $_ -like 'Failed*' }).Count -gt 0) { exit 1 }
