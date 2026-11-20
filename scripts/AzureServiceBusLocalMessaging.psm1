Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'LocalMessagingSupport.psm1')

# Local topology of Azure Service Bus (its emulator). LocalMessaging.psm1 discovers this module and calls these functions inside it;
# it exports nothing.

function Get-LocalMessagingProvider { return 'azure-service-bus' }

function Get-LocalMessagingTopologyKind { return 'AzureServiceBusPolicy' }

# <Name>Contracts.psm1 and Test-<Name>Policy.ps1 validate its delivery policy.
function Get-LocalMessagingContracts { return 'AzureServiceBus' }

function ConvertTo-ProviderLocalMessaging($Manifest, $Policy) { return ConvertTo-AzureLocalMessaging -Manifest $Manifest -Policy $Policy }

# Rejects a start that the emulator does not allow, such as unaccepted license terms.
function Assert-LocalMessagingStart([bool] $AcceptLicense) {
    if (-not $AcceptLicense) { throw 'Azure Service Bus emulator requires -AcceptLicense to accept its and SQL Server license terms.' }
}

# Process variables that Docker Compose needs while it starts or stops the emulator.
function Get-LocalMessagingStartEnvironment { return @{ ACCEPT_EULA = 'Y'; MSSQL_SA_PASSWORD = "Hexagon!$([Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(12)))" } }

function Get-LocalMessagingStopEnvironment { return @{ MSSQL_SA_PASSWORD = 'Hexagon!LocalCleanup123' } }

function Test-LocalMessagingReady($Generated, [string] $ProjectName) {
    $generated = $Generated; $projectName = $ProjectName; $ready = $false
    $response = Invoke-WebRequest -Uri 'http://localhost:5300/health' -TimeoutSec 5
    $ready = $response.StatusCode -eq 200
    return $ready
}

function ConvertTo-AzureLocalMessaging {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Manifest,
        [AllowNull()]
        [pscustomobject] $Policy
    )

    $workloads = [ordered] @{}
    if ($null -ne $Policy) {
        foreach ($entity in @($Policy.destinations) + @($Policy.consumers)) {
            if ([Xml.XmlConvert]::ToTimeSpan([string] $entity.defaultMessageTtl) -gt [TimeSpan]::FromHours(1)) {
                throw 'Azure emulator TTL cannot exceed PT1H. Supply an explicit local policy; cloud TTL values are not silently reduced.'
            }
        }
        foreach ($destination in $Policy.destinations) {
            if ([Xml.XmlConvert]::ToTimeSpan([string] $destination.duplicateDetectionHistory) -gt [TimeSpan]::FromMinutes(5)) {
                throw 'Azure emulator duplicate detection window cannot exceed PT5M. Supply an explicit local policy; cloud windows are not silently reduced.'
            }
        }
    }
    $topics = @()
    foreach ($destination in $Manifest.destinations) {
        $policyDestination = Get-PolicyItem -Policy $Policy -Collection destinations -Id ([string] $destination.id)
        $topicName = if ($null -eq $policyDestination) { [string] $destination.id } else { [string] $policyDestination.topicName }
        $topic = [ordered] @{
            Name          = $topicName
            Properties    = [ordered] @{
                DefaultMessageTimeToLive               = if ($null -eq $policyDestination) { 'PT1H' } else { [string] $policyDestination.defaultMessageTtl }
                DuplicateDetectionHistoryTimeWindow    = if ($null -eq $policyDestination) { 'PT20S' } else { [string] $policyDestination.duplicateDetectionHistory }
                RequiresDuplicateDetection             = if ($null -eq $policyDestination) { $false } else { [bool] $policyDestination.duplicateDetectionEnabled }
            }
            Subscriptions = @()
        }

        foreach ($workload in $destination.publisherWorkloads) {
            Add-LocalEnvironmentValue $workloads ([string] $workload) 'ConnectionStrings__servicebus' 'Endpoint=sb://localhost;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=SAS_KEY_VALUE;UseDevelopmentEmulator=true;'
            Add-LocalEnvironmentValue $workloads ([string] $workload) "Messaging__AzureServiceBus__Destinations__$($destination.id)__Topic" $topicName
        }

        foreach ($consumer in @($Manifest.consumers | Where-Object { [string] $_.destination -ceq [string] $destination.id })) {
            $policyConsumer = Get-PolicyItem -Policy $Policy -Collection consumers -Id ([string] $consumer.id)
            $subscriptionName = if ($null -eq $policyConsumer) { [string] $consumer.id } else { [string] $policyConsumer.subscriptionName }
            $subscription = [ordered] @{
                Name       = $subscriptionName
                Properties = [ordered] @{
                    DeadLetteringOnMessageExpiration = if ($null -eq $policyConsumer) { $false } else { [bool] $policyConsumer.deadLetterOnMessageExpiration }
                    DefaultMessageTimeToLive         = if ($null -eq $policyConsumer) { 'PT1H' } else { [string] $policyConsumer.defaultMessageTtl }
                    LockDuration                     = if ($null -eq $policyConsumer) { 'PT1M' } else { [string] $policyConsumer.lockDuration }
                    MaxDeliveryCount                 = if ($null -eq $policyConsumer) { 3 } else { [int] $policyConsumer.maxDeliveryCount }
                    ForwardDeadLetteredMessagesTo    = ''
                    ForwardTo                        = ''
                    RequiresSession                  = $false
                }
            }
            if ([string] $consumer.routing.mode -ceq 'include') {
                $subscription.Rules = @(
                    $consumer.routing.eventTypes | ForEach-Object {
                        [ordered] @{
                            Name       = [string] $_
                            Properties = [ordered] @{
                                FilterType        = 'Correlation'
                                CorrelationFilter = [ordered] @{ Label = [string] $_ }
                            }
                        }
                    }
                )
            }
            $topic.Subscriptions += $subscription

            Add-LocalEnvironmentValue $workloads ([string] $consumer.workload) 'ConnectionStrings__servicebus' 'Endpoint=sb://localhost;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=SAS_KEY_VALUE;UseDevelopmentEmulator=true;'
            Add-LocalEnvironmentValue $workloads ([string] $consumer.workload) "Messaging__AzureServiceBus__Destinations__$($destination.id)__Topic" $topicName
            Add-LocalEnvironmentValue $workloads ([string] $consumer.workload) "Messaging__AzureServiceBus__Consumers__$($consumer.id)__Topic" $topicName
            Add-LocalEnvironmentValue $workloads ([string] $consumer.workload) "Messaging__AzureServiceBus__Consumers__$($consumer.id)__Subscription" $subscriptionName
        }
        $topics += $topic
    }

    $configuration = [ordered] @{
        UserConfig = [ordered] @{
            Namespaces = @([ordered] @{ Name = 'sbemulatorns'; Queues = @(); Topics = $topics })
            Logging    = [ordered] @{ Type = 'File' }
        }
    }
    $compose = @'
services:
  mssql:
    image: mcr.microsoft.com/mssql/server:2022-CU14-ubuntu-22.04
    environment:
      ACCEPT_EULA: "${ACCEPT_EULA:-N}"
      MSSQL_SA_PASSWORD: "${MSSQL_SA_PASSWORD:?MSSQL_SA_PASSWORD is required}"
  servicebus:
    image: mcr.microsoft.com/azure-messaging/servicebus-emulator:2.0.0
    depends_on:
      - mssql
    environment:
      SQL_SERVER: mssql
      MSSQL_SA_PASSWORD: "${MSSQL_SA_PASSWORD:?MSSQL_SA_PASSWORD is required}"
      ACCEPT_EULA: "${ACCEPT_EULA:-N}"
      EMULATOR_HTTP_PORT: "5300"
    ports:
      - "5672:5672"
      - "5300:5300"
    volumes:
      - ./servicebus-config.json:/ServiceBus_Emulator/ConfigFiles/Config.json:ro
'@
    return [pscustomobject] @{
        Workloads = $workloads
        Files     = [ordered] @{
            'compose.yaml'             = $compose
            'servicebus-config.json'   = ($configuration | ConvertTo-Json -Depth 20)
        }
    }
}

Export-ModuleMember -Function @()
