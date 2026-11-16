Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-HostingAuthorizationBindings([hashtable] $Inputs) {
    if (-not $Inputs.ContainsKey('workloads')) { return $null }
    $prefix = 'Auth__Authorization__'
    $configured = @($Inputs.workloads.Values | Where-Object {
        ($_.ContainsKey('environment') -and @($_.environment.Keys | Where-Object { $_.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) -or
        ($_.ContainsKey('secret_references') -and @($_.secret_references.Keys | Where-Object { $_.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0)
    })
    if ($configured.Count -eq 0) { return $null }
    if (-not $Inputs.ContainsKey('migration_workload') -or -not $Inputs.workloads.ContainsKey($Inputs.migration_workload)) { throw 'auth.delivery.bindingsInvalid' }
    $api = $Inputs.workloads[$Inputs.migration_workload]
    $keys = @($api.environment.Keys | Where-Object { $_.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
    $secretKeys = @($api.secret_references.Keys | Where-Object { $_.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
    $hasSecret = $api.secret_references.ContainsKey($prefix + 'ClientSecret')
    foreach ($id in $Inputs.workloads.Keys) {
        if ($id -ceq $Inputs.migration_workload) { continue }
        if (@($Inputs.workloads[$id].environment.Keys + $Inputs.workloads[$id].secret_references.Keys | Where-Object { $_.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) }).Count -ne 0) { throw 'auth.delivery.apiOnly' }
    }
    if ($keys.Count -eq 0 -and $secretKeys.Count -eq 0) { return $null }
    $expected = @("${prefix}Product", "${prefix}ResourceServerId", "${prefix}ClientId")
    if ((@($keys | Sort-Object) -join ',') -cne (@($expected | Sort-Object) -join ',') -or $secretKeys.Count -ne 1 -or -not $hasSecret -or
        $api.environment[($prefix + 'Product')] -cne $Inputs.product -or
        $api.environment[($prefix + 'ResourceServerId')] -cnotmatch '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' -or
        $api.environment[($prefix + 'ResourceServerId')] -ceq [Guid]::Empty.ToString() -or
        $api.environment[($prefix + 'ClientId')] -cnotmatch '^[a-z][a-z0-9._-]{2,100}$') { throw 'auth.delivery.bindingsInvalid' }
    $public = @{}; foreach ($key in $expected) { $public[$key] = $api.environment[$key] }
    return @{ environment = $public
        secret = $api.secret_references[($prefix + 'ClientSecret')]
        arguments = @('--migrate-only', '--reconcile-auth-authorization', '--provision-auth-authorization') }
}

function Assert-AuthorizationTaskOrder([hashtable] $Journal, [hashtable] $Inputs) {
    if ($null -eq (Get-HostingAuthorizationBindings $Inputs)) { throw 'auth.delivery.notConfigured' }
    $required = @('migrations', 'database-access')
    foreach ($id in $required) {
        if (-not $Journal.jobs.ContainsKey($id) -or $Journal.jobs[$id].status -cne 'Succeeded') { throw 'auth.delivery.previousTaskRequired' }
    }
}

function Assert-AuthorizationReady([hashtable] $Journal, [hashtable] $Inputs) {
    if ($null -eq (Get-HostingAuthorizationBindings $Inputs)) { return }
    if (-not $Journal.jobs.ContainsKey('authorization') -or $Journal.jobs.authorization.status -cne 'Succeeded') { throw 'auth.delivery.preparationRequired' }
}

Export-ModuleMember -Function Get-HostingAuthorizationBindings, Assert-AuthorizationTaskOrder, Assert-AuthorizationReady
