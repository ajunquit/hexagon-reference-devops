Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$backendRoot = Join-Path $PSScriptRoot 'fixtures/backend'

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

$temporaryParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot = Join-Path $temporaryParent ("hexagon-local-messaging-" + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    foreach ($provider in @('azure-service-bus', 'aws-sns-sqs', 'rabbitmq')) {
        $probeBackend = Join-Path $testRoot "backend-$provider"
        New-Item -ItemType Directory -Path (Join-Path $probeBackend '.hexagon/schemas') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $backendRoot '.hexagon/schemas/messaging-requirements-v1.schema.json') `
            -Destination (Join-Path $probeBackend '.hexagon/schemas/messaging-requirements-v1.schema.json')
        $manifest = Get-Content -Raw -LiteralPath `
            (Join-Path $backendRoot '.hexagon/messaging-requirements.json') | ConvertFrom-Json
        $manifest.provider = $provider
        [IO.File]::WriteAllText(
            (Join-Path $probeBackend '.hexagon/messaging-requirements.json'),
            (($manifest | ConvertTo-Json -Depth 20) + "`n"),
            [Text.UTF8Encoding]::new($false)
        )

        $output = Join-Path $testRoot "generated-$provider"
        $bindings = Join-Path $testRoot "bindings-$provider.json"
        & (Join-Path $repositoryRoot 'scripts/New-LocalMessaging.ps1') `
            -BackendPath $probeBackend `
            -OutputDirectory $output `
            -BindingsOutput $bindings
        Assert-True (Test-Path -LiteralPath (Join-Path $output 'compose.yaml')) `
            "Compose file is missing for $provider."
        $bindingJson = Get-Content -Raw -LiteralPath $bindings
        Assert-True ($bindingJson | Test-Json -SchemaFile `
                (Join-Path $repositoryRoot 'contracts/schemas/local-messaging-bindings-v1.schema.json')) `
            "Bindings are invalid for $provider."
        $bindingModel = $bindingJson | ConvertFrom-Json
        Assert-True ([string] $bindingModel.provider -ceq $provider) `
            "Bindings selected the wrong provider for $provider."
        Assert-True (@($bindingModel.workloads.PSObject.Properties).Count -eq 3) `
            "Bindings do not cover every workload for $provider."

        switch ($provider) {
            'azure-service-bus' {
                $config = Get-Content -Raw -LiteralPath `
                    (Join-Path $output 'servicebus-config.json') | ConvertFrom-Json
                $subscriptions = @($config.UserConfig.Namespaces[0].Topics[0].Subscriptions)
                Assert-True ($subscriptions.Count -eq 2) 'Azure did not create one subscription per consumer.'
                Assert-True (@($subscriptions | Where-Object Name -eq 'sales-worker')[0].Rules[0].Properties.CorrelationFilter.Label -ceq 'CustomerCreatedIntegrationEvent') `
                    'Azure did not materialize the include routing filter.'
            }
            'aws-sns-sqs' {
                $init = Get-Content -Raw -LiteralPath (Join-Path $output 'floci-init.sh')
                Assert-True ($init.Contains('"EventType"')) 'AWS filter must use the EventType message attribute.'
                Assert-True (-not $init.Contains('"eventType"')) 'AWS filter used the wrong message attribute casing.'
                if (-not $IsWindows) {
                    $mode = [IO.File]::GetUnixFileMode((Join-Path $output 'floci-init.sh'))
                    Assert-True (($mode -band [IO.UnixFileMode]::UserExecute) -ne 0) 'The Floci initialization hook must be executable on Unix.'
                }
            }
            'rabbitmq' {
                $definitions = Get-Content -Raw -LiteralPath `
                    (Join-Path $output 'rabbitmq-definitions.json') | ConvertFrom-Json
                Assert-True (@($definitions.queues).Count -eq 2) `
                    'RabbitMQ default local policy should not add optional DLQs.'
                Assert-True (@($definitions.bindings | Where-Object routing_key -eq 'CustomerCreatedIntegrationEvent').Count -eq 1) `
                    'RabbitMQ did not materialize the include routing key.'
            }
        }

        $exampleName = switch ($provider) {
            'azure-service-bus' { 'azure-service-bus-policy.json' }
            'aws-sns-sqs' { 'aws-sns-sqs-policy.json' }
            'rabbitmq' { 'rabbitmq-policy.json' }
        }
        $policyPath = Join-Path $testRoot "policy-$provider.json"
        $policyText = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot "examples/$exampleName")
        [IO.File]::WriteAllText($policyPath, $policyText, [Text.UTF8Encoding]::new($false))
        $policyOutput = Join-Path $testRoot "generated-policy-$provider"
        if ($provider -ceq 'azure-service-bus') {
            $localPolicy = $policyText | ConvertFrom-Json
            foreach ($collection in @('destinations', 'consumers')) {
                $rejected = $false
                try {
                    & (Join-Path $repositoryRoot 'scripts/New-LocalMessaging.ps1') -BackendPath $probeBackend -Policy $policyPath -OutputDirectory $policyOutput -BindingsOutput (Join-Path $testRoot 'must-not-exist.json')
                } catch {
                    if ($_.Exception.Message -notlike '*TTL cannot exceed PT1H*') { throw }
                    $rejected = $true
                }
                Assert-True $rejected 'The Azure emulator must reject cloud TTL values before writing files.'
                Assert-True (-not (Test-Path -LiteralPath $policyOutput)) 'An invalid emulator policy wrote topology files.'
                foreach ($entity in $localPolicy.$collection) { $entity.defaultMessageTtl = 'PT1H' }
                [IO.File]::WriteAllText($policyPath, ($localPolicy | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
            }
            $rejected = $false
            try {
                & (Join-Path $repositoryRoot 'scripts/New-LocalMessaging.ps1') -BackendPath $probeBackend -Policy $policyPath -OutputDirectory $policyOutput -BindingsOutput (Join-Path $testRoot 'must-not-exist.json')
            } catch {
                if ($_.Exception.Message -notlike '*duplicate detection window cannot exceed PT5M*') { throw }
                $rejected = $true
            }
            Assert-True $rejected 'The Azure emulator must reject an unsupported cloud duplicate detection window.'
            foreach ($destination in $localPolicy.destinations) { $destination.duplicateDetectionHistory = 'PT5M' }
            [IO.File]::WriteAllText($policyPath, ($localPolicy | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
        }
        & (Join-Path $repositoryRoot 'scripts/New-LocalMessaging.ps1') `
            -BackendPath $probeBackend `
            -Policy $policyPath `
            -OutputDirectory $policyOutput `
            -BindingsOutput (Join-Path $testRoot "bindings-policy-$provider.json")

        switch ($provider) {
            'azure-service-bus' {
                $config = Get-Content -Raw -LiteralPath `
                    (Join-Path $policyOutput 'servicebus-config.json') | ConvertFrom-Json
                Assert-True ($config.UserConfig.Namespaces[0].Topics[0].Subscriptions[0].Properties.MaxDeliveryCount -eq 10) `
                    'Azure local topology did not apply the DevOps delivery policy.'
                Assert-True ($config.UserConfig.Namespaces[0].Topics[0].Properties.DefaultMessageTimeToLive -ceq 'PT1H') `
                    'Azure local topology did not preserve the explicit emulator TTL.'
            }
            'aws-sns-sqs' {
                $init = Get-Content -Raw -LiteralPath (Join-Path $policyOutput 'floci-init.sh')
                Assert-True ($init.Contains('hexagon-example-dev-sales-worker-dlq')) `
                    'AWS local topology did not create the enabled DLQ.'
                Assert-True (-not $init.Contains('hexagon-example-dev-worker-dlq')) `
                    'AWS local topology created a DLQ disabled by policy.'
            }
            'rabbitmq' {
                $definitions = Get-Content -Raw -LiteralPath `
                    (Join-Path $policyOutput 'rabbitmq-definitions.json') | ConvertFrom-Json
                Assert-True (@($definitions.queues).Count -eq 3) `
                    'RabbitMQ local topology did not apply DLQ selection per queue.'
                Assert-True (@($definitions.queues | Where-Object name -eq 'hexagon-example.dev.sales-worker.dlq').Count -eq 1) `
                    'RabbitMQ local topology did not create the enabled DLQ.'
            }
        }
    }
}
finally {
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    $expectedPrefix = Join-Path $temporaryParent 'hexagon-local-messaging-'
    if ($resolvedTestRoot.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolvedTestRoot)) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}

Write-Host 'Local messaging generation checks passed for all providers.'
