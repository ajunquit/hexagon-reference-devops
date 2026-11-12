Set-StrictMode -Version Latest

# Broker integration tests per messaging provider.
$script:ProviderTests = [ordered] @{
    'azure-service-bus' = 'AzureRuntimeTests'
    'aws-sns-sqs'       = 'AwsRuntimeTests'
    'rabbitmq'          = 'RabbitMqRuntimeTests'
}

function Get-CiMessagingProviders {
    <#
    .SYNOPSIS
        The messaging providers whose integration tests this repository needs.

    .DESCRIPTION
        The template, without product descriptors, tests every provider. A product instance tests only
        the providers its backend declares: each environment descriptor pins the backend commit and the
        SHA-256 of `.hexagon/messaging-requirements.json`, whose `provider` field is read and verified.
        A backend without that manifest (API-only) needs no broker tests.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Root,

        # Reads and validates an application manifest: (repository, commit, path, product) -> { Manifest, Sha256 }.
        [Parameter(Mandatory = $true)]
        [scriptblock] $ReadManifest
    )

    $productsPath = Join-Path $Root 'products'
    $descriptors = @(
        if (Test-Path -LiteralPath $productsPath) {
            Get-ChildItem -LiteralPath $productsPath -Recurse -File -Filter 'descriptor.json'
        }
    )
    if ($descriptors.Count -eq 0) {
        return [string[]] @($script:ProviderTests.Keys)
    }

    $providers = [Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    foreach ($descriptor in $descriptors) {
        $document = [IO.File]::ReadAllText($descriptor.FullName) | ConvertFrom-Json
        foreach ($component in @($document.components | Where-Object name -CEQ 'backend')) {
            $manifest = @($component.manifests | Where-Object path -CEQ '.hexagon/messaging-requirements.json')
            if ($manifest.Count -eq 0) { continue }
            $validated = & $ReadManifest ([string] $component.repository) ([string] $component.commit) '.hexagon/messaging-requirements.json' ([string] $document.product)
            if ([string] $validated.Sha256 -cne [string] $manifest[0].sha256) {
                throw "The messaging manifest of '$($component.repository)@$($component.commit)' does not match '$($descriptor.FullName)'."
            }
            $provider = [string] $validated.Manifest.provider
            if (-not $script:ProviderTests.Contains($provider)) {
                throw "Unknown messaging provider '$provider' in '$($component.repository)@$($component.commit)'."
            }
            [void] $providers.Add($provider)
        }
    }
    return [string[]] @($providers)
}

function ConvertTo-CiMessagingMatrix {
    [CmdletBinding()]
    param([AllowEmptyCollection()] [string[]] $Providers)

    $include = @(foreach ($provider in $Providers) { [ordered] @{ provider = $provider; 'test-class' = $script:ProviderTests[$provider] } })
    return ConvertTo-Json -InputObject $include -Compress -Depth 3
}

Export-ModuleMember -Function Get-CiMessagingProviders, ConvertTo-CiMessagingMatrix
