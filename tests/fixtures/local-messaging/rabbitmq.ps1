# Local messaging fixture of RabbitMQ for tests/Test-LocalMessaging.ps1: checks the generated topology with
# the default policy and with the example delivery policy, and adapts that example to the emulator.
return @{
    Default = {
        param($output)
        $definitions = Get-Content -Raw -LiteralPath `
            (Join-Path $output 'rabbitmq-definitions.json') | ConvertFrom-Json
        Assert-True (@($definitions.queues).Count -eq 2) `
            'RabbitMQ default local policy should not add optional DLQs.'
        Assert-True (@($definitions.bindings | Where-Object routing_key -eq 'CustomerCreatedIntegrationEvent').Count -eq 1) `
            'RabbitMQ did not materialize the include routing key.'
    }
    PreparePolicy = {
        param($policyPath, $policyText, $probeBackend, $policyOutput, $testRoot)
    }
    Policy = {
        param($policyOutput)
        $definitions = Get-Content -Raw -LiteralPath `
            (Join-Path $policyOutput 'rabbitmq-definitions.json') | ConvertFrom-Json
        Assert-True (@($definitions.queues).Count -eq 3) `
            'RabbitMQ local topology did not apply DLQ selection per queue.'
        Assert-True (@($definitions.queues | Where-Object name -eq 'hexagon-example.dev.sales-worker.dlq').Count -eq 1) `
            'RabbitMQ local topology did not create the enabled DLQ.'
    }
}
