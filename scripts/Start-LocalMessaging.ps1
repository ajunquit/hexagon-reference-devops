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

if ($provider -ceq 'azure-service-bus' -and -not $AcceptLicense) {
    throw 'Azure Service Bus emulator requires -AcceptLicense to accept its and SQL Server license terms.'
}
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw 'Docker is required to start local messaging.'
}
docker version --format '{{.Server.Version}}' | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'Docker is not running.'
}

$projectName = "$($generated.Product)-local-$($generated.Provider)"
if (-not $PSCmdlet.ShouldProcess($projectName, "Start $provider local messaging topology")) { return }

$previousAcceptEula = [Environment]::GetEnvironmentVariable('ACCEPT_EULA', 'Process')
$previousSqlPassword = [Environment]::GetEnvironmentVariable('MSSQL_SA_PASSWORD', 'Process')
try {
    if ($provider -ceq 'azure-service-bus') {
        [Environment]::SetEnvironmentVariable('ACCEPT_EULA', 'Y', 'Process')
        $randomSuffix = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(12))
        [Environment]::SetEnvironmentVariable('MSSQL_SA_PASSWORD', "Hexagon!$randomSuffix", 'Process')
    }
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
            switch ($provider) {
                'azure-service-bus' {
                    $response = Invoke-WebRequest -Uri 'http://localhost:5300/health' -TimeoutSec 5
                    $ready = $response.StatusCode -eq 200
                }
                'aws-sns-sqs' {
                    $bindings = Get-Content -Raw -LiteralPath $generated.BindingsFile | ConvertFrom-Json
                    $expectedTopics = @(
                        foreach ($workload in $bindings.workloads.PSObject.Properties) {
                            foreach ($setting in $workload.Value.PSObject.Properties) {
                                if ($setting.Name -like '*__TopicArn') {
                                    [string] $setting.Value
                                }
                            }
                        }
                    ) | Sort-Object -Unique
                    $expectedConsumerCount = @(
                        foreach ($workload in $bindings.workloads.PSObject.Properties) {
                            foreach ($setting in $workload.Value.PSObject.Properties) {
                                if ($setting.Name -like '*__QueueUrl') {
                                    [string] $setting.Value
                                }
                            }
                        }
                    ).Count
                    $initScript = Get-Content -Raw -LiteralPath `
                        (Join-Path $generated.OutputDirectory 'floci-init.sh')
                    $expectedQueues = @(
                        [regex]::Matches($initScript, "--queue-name '([^']+)'") |
                            ForEach-Object { $_.Groups[1].Value } |
                            Sort-Object -Unique
                    )
                    $actualTopics = & docker compose --project-name $projectName --file $generated.ComposeFile `
                        exec -T floci aws sns list-topics --output json 2>$null
                    if ($LASTEXITCODE -eq 0) {
                        $actualQueues = & docker compose --project-name $projectName --file $generated.ComposeFile `
                            exec -T floci aws sqs list-queues --output json 2>$null
                        if ($LASTEXITCODE -eq 0) {
                            $actualSubscriptions = & docker compose --project-name $projectName --file $generated.ComposeFile `
                                exec -T floci aws sns list-subscriptions --output json 2>$null
                            $topicText = ($actualTopics | ForEach-Object ToString) -join "`n"
                            $queueText = ($actualQueues | ForEach-Object ToString) -join "`n"
                            $subscriptionModel = (($actualSubscriptions | ForEach-Object ToString) -join "`n") |
                                ConvertFrom-Json
                            $ready =
                                @($expectedTopics | Where-Object { -not $topicText.Contains($_) }).Count -eq 0 -and
                                @($expectedQueues | Where-Object { -not $queueText.Contains($_) }).Count -eq 0 -and
                                @($subscriptionModel.Subscriptions).Count -eq $expectedConsumerCount
                        }
                    }
                }
                'rabbitmq' {
                    $definitions = Get-Content -Raw -LiteralPath `
                        (Join-Path $generated.OutputDirectory 'rabbitmq-definitions.json') | ConvertFrom-Json
                    $virtualHost = [string] $definitions.vhosts[0].name
                    $expectedQueues = @($definitions.queues | ForEach-Object { [string] $_.name })
                    $actual = & docker compose --project-name $projectName --file $generated.ComposeFile `
                        exec -T rabbitmq rabbitmqctl list_queues -p $virtualHost name --formatter json 2>$null
                    if ($LASTEXITCODE -eq 0) {
                        $actualText = ($actual | ForEach-Object ToString) -join "`n"
                        $ready = @($expectedQueues | Where-Object { -not $actualText.Contains($_) }).Count -eq 0
                    }
                }
            }
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
    [Environment]::SetEnvironmentVariable('ACCEPT_EULA', $previousAcceptEula, 'Process')
    [Environment]::SetEnvironmentVariable('MSSQL_SA_PASSWORD', $previousSqlPassword, 'Process')
}

Write-Host "Local messaging is ready for $($generated.Product) with $provider."
Write-Host "Run the backend AppHost; it will read $($generated.BindingsFile)."
