# Local messaging fixture of Azure Service Bus for tests/Test-LocalMessaging.ps1: checks the generated topology with
# the default policy and with the example delivery policy, and adapts that example to the emulator.
return @{
    Default = {
        param($output)
        $config = Get-Content -Raw -LiteralPath `
            (Join-Path $output 'servicebus-config.json') | ConvertFrom-Json
        $subscriptions = @($config.UserConfig.Namespaces[0].Topics[0].Subscriptions)
        Assert-True ($subscriptions.Count -eq 2) 'Azure did not create one subscription per consumer.'
        Assert-True (@($subscriptions | Where-Object Name -eq 'sales-worker')[0].Rules[0].Properties.CorrelationFilter.Label -ceq 'CustomerCreatedIntegrationEvent') `
            'Azure did not materialize the include routing filter.'
    }
    PreparePolicy = {
        param($policyPath, $policyText, $probeBackend, $policyOutput, $testRoot)
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
    Policy = {
        param($policyOutput)
        $config = Get-Content -Raw -LiteralPath `
            (Join-Path $policyOutput 'servicebus-config.json') | ConvertFrom-Json
        Assert-True ($config.UserConfig.Namespaces[0].Topics[0].Subscriptions[0].Properties.MaxDeliveryCount -eq 10) `
            'Azure local topology did not apply the DevOps delivery policy.'
        Assert-True ($config.UserConfig.Namespaces[0].Topics[0].Properties.DefaultMessageTimeToLive -ceq 'PT1H') `
            'Azure local topology did not preserve the explicit emulator TTL.'
    }
}
