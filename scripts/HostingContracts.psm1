Set-StrictMode -Version Latest

function Read-HostingContract {
    param([string] $Path, [string] $Schema)
    $json = Get-Content -Raw -LiteralPath $Path
    $schemaFile = Join-Path $PSScriptRoot "../contracts/schemas/$Schema.schema.json"
    if (-not ($json | Test-Json -SchemaFile $schemaFile -ErrorAction SilentlyContinue)) {
        throw "Invalid $Schema contract."
    }
    return $json | ConvertFrom-Json -AsHashtable
}

function Assert-ReleaseSources {
    param($Descriptor, $Release)
    if ($Descriptor.product -cne $Release.product -or $Descriptor.components.Count -ne $Release.sources.Count) {
        throw 'Release sources do not match the product descriptor.'
    }
    if (@($Release.sources.name | Sort-Object -Unique).Count -ne $Release.sources.Count) { throw 'Duplicate release source.' }
    foreach ($component in $Descriptor.components) {
        $source = @($Release.sources | Where-Object { $_.name -ceq $component.name })
        if ($source.Count -ne 1 -or $source[0].repository -cne $component.repository -or $source[0].commit -cne $component.commit -or $source[0].manifests.Count -ne $component.manifests.Count) {
            throw 'Release sources do not match the product descriptor.'
        }
        foreach ($manifest in $component.manifests) {
            if (@($source[0].manifests | Where-Object { $_.path -ceq $manifest.path -and $_.sha256 -ceq $manifest.sha256 }).Count -ne 1) {
                throw 'Release manifest checksums do not match the product descriptor.'
            }
        }
    }
    $names = @($Descriptor.components.name)
    if (@($names | Where-Object { $_ -cnotin @('backend', 'web') }).Count -gt 0) { throw 'Unsupported release component.' }
    if ($names -contains 'backend') {
        if (-not $Release.artifacts.Contains('backend') -or -not $Release.artifacts.Contains('databaseBootstrap')) { throw 'Missing backend artifacts.' }
    } elseif ($Release.artifacts.Contains('backend') -or $Release.artifacts.Contains('databaseBootstrap')) { throw 'Unexpected backend artifacts.' }
    if (($names -contains 'web') -ne $Release.artifacts.Contains('web')) { throw 'Missing or unexpected web artifact.' }
}

function ConvertTo-AzureHostingInput {
    param($Descriptor, $Release, $Policy, $Backend, $Frontend)
    $registry = $Policy.infrastructure.registry_name
    return ConvertTo-HostingInput $Descriptor $Release $Policy $Backend $Frontend { param($image) ConvertTo-EnvironmentImageReference $image $registry }
}

function ConvertTo-AwsHostingInput {
    param($Descriptor, $Release, $Policy, $Backend, $Frontend)
    $infra = $Policy.infrastructure
    $repository = "$($infra.account_id).dkr.ecr.$($infra.region).amazonaws.com/$($infra.name_prefix)"
    return ConvertTo-HostingInput $Descriptor $Release $Policy $Backend $Frontend { param($image) ConvertTo-AwsImageReference $image $repository }
}

function ConvertTo-HostingInput {
    # Validates the composition shared by every cloud; $ImageReference maps a release image to the environment registry.
    param($Descriptor, $Release, $Policy, $Backend, $Frontend, [scriptblock] $ImageReference)
    Assert-ReleaseSources -Descriptor $Descriptor -Release $Release
    if ($Policy.product -cne $Descriptor.product -or $Policy.environment -cne $Descriptor.environment) { throw 'Hosting policy product or environment mismatch.' }
    if ($Backend.apiVersion -cne 'hexagon.ec/backend-hosting-requirements/v1' -or $Frontend.apiVersion -cne 'hexagon.ec/frontend-hosting-requirements/v2') { throw 'Unsupported hosting contract version.' }
    if ($Backend.product -cne $Descriptor.product -or $Frontend.product -cne $Descriptor.product) { throw 'Hosting manifest product mismatch.' }
    $ids = @($Backend.workloads.id | Sort-Object -Unique)
    if ($ids.Count -ne $Backend.workloads.Count -or ($ids -join ',') -cne ((@($Policy.workloads.Keys) | Sort-Object) -join ',') -or ($ids -join ',') -cne ((@($Release.artifacts.backend.Keys) | Sort-Object) -join ',')) {
        throw 'Workload policies and images must exactly match the backend contract.'
    }
    if (@($Backend.workloads | Where-Object kind -CEQ 'api').Count -ne 1 -or $Backend.database.minimumMajorVersion -gt 17 -or $Backend.database.engine -cne 'postgresql') { throw 'Unsupported backend hosting requirements.' }
    $migration = @($Backend.workloads | Where-Object { $_.id -ceq $Backend.migrations.workload -and $_.kind -ceq 'api' })
    if ($migration.Count -ne 1 -or ($Backend.migrations.arguments -join ',') -cne '--migrate-only') { throw 'Unsupported migration workload.' }
    if ($Frontend.artifact.type -cne 'static-spa' -or $Frontend.routing.fallback -cne '/index.html' -or $Frontend.runtimeConfiguration.path -cne '/runtime-config.json') { throw 'Only the declared static SPA routing contract is supported.' }
    $infra = $Policy.infrastructure
    $result = [ordered] @{ product = $Descriptor.product; environment = $Descriptor.environment }
    foreach ($key in $infra.Keys) { $result[$key] = $infra[$key] }
    $result.auth = @{ authority = $infra.auth.authority; client_id = $infra.auth.client_id; audience = $Backend.identity.audience; api_scope = $Backend.identity.apiScope }
    $result.database_connection_name = $Backend.database.connectionName
    $result.bootstrap_image = & $ImageReference $Release.artifacts.databaseBootstrap.image
    $result.migration_workload = $Backend.migrations.workload
    $result.maintenance_jobs_enabled = $false
    $result.application_rollout_enabled = $false
    $backendSource = @($Descriptor.components | Where-Object name -CEQ 'backend')[0]
    if (@($backendSource.manifests | Where-Object path -CEQ '.hexagon/messaging-requirements.json').Count -eq 0) {
        if (@($Backend.workloads | Where-Object kind -CNE 'api').Count -gt 0) { throw 'Messaging-free hosting requires API-only workloads.' }
        $result.messaging_enabled = $false
    }
    if ($infra.ContainsKey('keycloak')) {
        if ($Descriptor.environment -cne 'dev' -or $null -ne $infra.auth.authority) { throw 'Integrated identity requires dev and a null external authority.' }
        $result.keycloak_rollout_enabled = $false
    }
    $result.workloads = @{}
    foreach ($workload in $Backend.workloads) {
        if ($workload.healthPort -ne 8081 -or ($workload.httpPorts -join ',') -cne $(if ($workload.kind -ceq 'api') { '8080,8081' } else { '8081' })) { throw 'Unsupported workload ports.' }
        $physical = @{} + $Policy.workloads[$workload.id]
        $physical.kind = $workload.kind
        $physical.image = & $ImageReference $Release.artifacts.backend[$workload.id]
        $physical.http_ports = $workload.httpPorts
        $physical.health_port = $workload.healthPort
        $result.workloads[$workload.id] = $physical
    }
    return $result
}

function ConvertTo-EnvironmentImageReference([string] $Image, [string] $Registry) {
    # Promotion copies the same manifest/layers into the target ACR; it never rebuilds the image.
    return "$Registry.azurecr.io/" + $Image.Substring($Image.IndexOf('/') + 1)
}

function ConvertTo-AwsImageReference([string] $Image, [string] $Repository) {
    # Delivery copies the same manifest into <account>.dkr.ecr.<region>.amazonaws.com/<name_prefix>/<artifact>,
    # keeping the digest; the artifact is the last path segment of the release image.
    $parts = $Image.Split('@')
    if ($parts.Count -ne 2 -or $parts[1] -cnotmatch '^sha256:[0-9a-f]{64}$') { throw 'Release images must be pinned by digest.' }
    $artifact = $parts[0].Substring($parts[0].LastIndexOf('/') + 1)
    if ($artifact -cnotmatch '^[a-z0-9][a-z0-9._-]*$') { throw "Invalid artifact name '$artifact'." }
    return "$Repository/$artifact@$($parts[1])"
}

Export-ModuleMember -Function Read-HostingContract, Assert-ReleaseSources, ConvertTo-AzureHostingInput, ConvertTo-AwsHostingInput
