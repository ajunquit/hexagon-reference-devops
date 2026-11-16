Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-KeycloakAuthorization([string] $Path) {
    $json = [IO.File]::ReadAllText([IO.Path]::GetFullPath($Path))
    if (-not ($json | Test-Json -SchemaFile (Join-Path $PSScriptRoot '../contracts/schemas/keycloak-authorization-v1.schema.json') -ErrorAction SilentlyContinue)) { throw 'auth.preparation.configurationInvalid' }
    $model = $json | ConvertFrom-Json -AsHashtable
    $authority = [Uri] $model.authority
    if ($authority.Segments[-1] -ceq 'master' -or $authority.UserInfo -or $authority.Query -or $authority.Fragment -or
        ($model.environment -ceq 'local') -ne $authority.IsLoopback) { throw 'auth.preparation.destinationInvalid' }
    if (@($model.resourceServer.clientId, $model.authorizationClientId, $model.frontend.clientId | Sort-Object -Unique).Count -ne 3 -or
        $model.resourceServer.id -eq [Guid]::Empty.ToString() -or
        ($model.environment -cne 'local' -and -not $model.authorizationClientId.EndsWith("-$($model.environment)-authorization", [StringComparison]::Ordinal))) { throw 'auth.preparation.clientsInvalid' }
    foreach ($origin in $model.frontend.origins) {
        $uri = [Uri] $origin
        if ($uri.Scheme -cne 'https' -and -not ($model.environment -ceq 'local' -and $uri.IsLoopback)) { throw 'auth.preparation.originInvalid' }
        if ($uri.IsLoopback -and $model.environment -cne 'local') { throw 'auth.preparation.originInvalid' }
    }
    return $model
}

function Get-KeycloakAuthorizationBindings([hashtable] $Model) {
    # Only public bindings. A client credential is always obtained separately from its secret store.
    return @{
        authority = $Model.authority
        environment = @{
            Auth__Authority = $Model.authority; Auth__Audience = $Model.resourceServer.clientId; Auth__ApiScope = $Model.resourceServer.apiScope
            Auth__Authorization__Product = $Model.product; Auth__Authorization__ResourceServerId = $Model.resourceServer.id
            Auth__Authorization__ClientId = $Model.authorizationClientId
        }
        secretEnvironment = 'Auth__Authorization__ClientSecret'
        frontend = @{ authority = $Model.authority; clientId = $Model.frontend.clientId; scope = "openid profile email $($Model.resourceServer.apiScope)" }
        maintenanceArguments = @('--migrate-only', '--reconcile-auth-authorization', '--provision-auth-authorization')
    }
}

function New-KeycloakAuthorizationContext([hashtable] $Model) {
    $token = $env:HEXAGON_KEYCLOAK_BOOTSTRAP_TOKEN
    if ([string]::IsNullOrWhiteSpace($token)) { throw 'auth.preparation.operatorTokenRequired' }
    $handler = [Net.Http.HttpClientHandler]::new(); $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler); $client.Timeout = [TimeSpan]::FromSeconds(15); $client.MaxResponseContentBufferSize = 2MB
    return @{ model = $Model; token = $token; client = $client; handler = $handler }
}

function Invoke-KeycloakPreparationHttp([hashtable] $Context, [string] $Method, [string] $Path, $Body = $null) {
    # Tests inject the protocol transport, never shell commands from the configuration.
    if ($Context.ContainsKey('http')) { return & $Context.http $Method $Path $Body }
    $origin = ([Uri] $Context.model.authority).GetLeftPart('Authority')
    $adminRoot = Get-KeycloakPreparationAdminRoot $Context
    if (-not ($Path -ceq "$adminRoot/serverinfo" -or $Path -ceq "$adminRoot/realms" -or $Path.StartsWith("$adminRoot/realms/", [StringComparison]::Ordinal))) { throw 'auth.preparation.pathInvalid' }
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), "$origin$Path")
    $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Context.token)
    if ($null -ne $Body) { $request.Content = [Net.Http.StringContent]::new(($Body | ConvertTo-Json -Depth 30 -Compress), [Text.Encoding]::UTF8, 'application/json') }
    try {
        try { $response = $Context.client.Send($request) } catch { throw 'auth.preparation.transportUnavailable' }
        try {
            $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
            if ($bytes.Length -gt 2MB) { throw 'auth.preparation.responseTooLarge' }
            $value = $null
            if ([int] $response.StatusCode -ge 200 -and [int] $response.StatusCode -lt 300 -and $bytes.Length -gt 0) {
                try { $value = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -AsHashtable -NoEnumerate -Depth 40 } catch { throw 'auth.preparation.responseInvalid' }
            }
            return @{ status = [int] $response.StatusCode; value = $value }
        } finally { $response.Dispose() }
    } finally { $request.Dispose() }
}

function Invoke-KeycloakPreparationRead([hashtable] $Context, [string] $Path, [switch] $AllowMissing) {
    $response = Invoke-KeycloakPreparationHttp $Context GET $Path
    if ($AllowMissing -and $response.status -eq 404) { return $null }
    if ($response.status -ne 200 -or $null -eq $response.value) { throw "auth.preparation.readFailed:$($response.status):$Path" }
    return $response.value
}

function Invoke-KeycloakPreparationWrite([hashtable] $Context, [string] $Method, [string] $Path, $Body) {
    $response = Invoke-KeycloakPreparationHttp $Context $Method $Path $Body
    if ($response.status -notin @(200, 201, 204)) { throw "auth.preparation.writeFailed:$($response.status):${Method}:$Path" }
}

function Get-KeycloakPreparationAdminRoot([hashtable] $Context) {
    $path = ([Uri] $Context.model.authority).AbsolutePath
    return $path.Substring(0, $path.LastIndexOf('/realms/', [StringComparison]::Ordinal)) + '/admin'
}
function Get-KeycloakPreparationBase([hashtable] $Context) { return (Get-KeycloakPreparationAdminRoot $Context) + '/realms/' + ([Uri] $Context.model.authority).Segments[-1] }

function Find-KeycloakPreparationClient([hashtable] $Context, [string] $ClientId) {
    $base = Get-KeycloakPreparationBase $Context
    $matches = @(Invoke-KeycloakPreparationRead $Context "$base/clients?clientId=$([Uri]::EscapeDataString($ClientId))" | Where-Object clientId -CEQ $ClientId)
    if ($matches.Count -gt 1) { throw 'auth.preparation.clientAmbiguous' }
    if ($matches.Count -eq 0) { return $null }
    # Never return a complete client representation: the Admin API may include credentials.
    $client = Invoke-KeycloakPreparationRead $Context "$base/clients/$($matches[0].id)"
    $result = @{}
    foreach ($key in @('id', 'clientId', 'protocol', 'enabled', 'publicClient', 'serviceAccountsEnabled', 'standardFlowEnabled', 'directAccessGrantsEnabled', 'authorizationServicesEnabled', 'webOrigins', 'redirectUris')) {
        if ($client.ContainsKey($key)) { $result[$key] = $client[$key] }
    }
    $result.attributes = @{}
    foreach ($key in @('pkce.code.challenge.method', 'post.logout.redirect.uris')) {
        if ($client.ContainsKey('attributes') -and $client.attributes.ContainsKey($key)) { $result.attributes[$key] = $client.attributes[$key] }
    }
    return $result
}

function Assert-KeycloakPreparationClient([hashtable] $Context, $Client, [string] $Kind) {
    if ($null -eq $Client) { return }
    if ($Client.protocol -cne 'openid-connect' -or -not $Client.enabled) { throw 'auth.preparation.clientChanged' }
    if ($Kind -ceq 'resource' -and ($Client.id -cne $Context.model.resourceServer.id -or $Client.publicClient)) { throw 'auth.preparation.resourceChanged' }
    if ($Kind -ceq 'frontend' -and -not $Client.publicClient) { throw 'auth.preparation.frontendChanged' }
    if ($Kind -ceq 'authorization') {
        if ($Client.publicClient -or $Client.standardFlowEnabled -or $Client.directAccessGrantsEnabled -or -not $Client.serviceAccountsEnabled) { throw 'auth.preparation.delegationChanged' }
        $base = Get-KeycloakPreparationBase $Context
        if (-not [string]::IsNullOrWhiteSpace($env:HEXAGON_AUTHORIZATION_CLIENT_SECRET)) {
            $actual = Invoke-KeycloakPreparationRead $Context "$base/clients/$($Client.id)/client-secret"
            if (-not $actual.ContainsKey('value') -or $actual.value -cne $env:HEXAGON_AUTHORIZATION_CLIENT_SECRET) { throw 'auth.preparation.credentialMismatch' }
        }
        $account = Invoke-KeycloakPreparationRead $Context "$base/clients/$($Client.id)/service-account-user"
        $groups = @(Invoke-KeycloakPreparationRead $Context "$base/users/$($account.id)/groups")
        if ($groups.Count -ne 0) { throw 'auth.preparation.delegationElevated' }
        $management = Find-KeycloakPreparationClient $Context 'realm-management'
        $roles = @(Invoke-KeycloakPreparationRead $Context "$base/users/$($account.id)/role-mappings/clients/$($management.id)/composite")
        if (@($roles | Where-Object name -CNotIn @('query-clients', 'query-users')).Count -ne 0) { throw 'auth.preparation.delegationElevated' }
        $realmRoles = @(Invoke-KeycloakPreparationRead $Context "$base/users/$($account.id)/role-mappings/realm/composite")
        if (@($realmRoles | Where-Object name -CIn @('admin', 'realm-admin')).Count -ne 0) { throw 'auth.preparation.delegationElevated' }
    }
}

function Get-KeycloakAuthorizationPlan([hashtable] $Context) {
    $model = $Context.model; $base = Get-KeycloakPreparationBase $Context
    $server = Invoke-KeycloakPreparationRead $Context "$(Get-KeycloakPreparationAdminRoot $Context)/serverinfo"
    if (-not $server.ContainsKey('systemInfo') -or -not $server.systemInfo.ContainsKey('version') -or $server.systemInfo.version -cnotmatch '^26[.](?:[6-9]|[1-9][0-9]+)(?:[.]|$)') { throw 'auth.preparation.versionUnsupported' }
    $realm = Invoke-KeycloakPreparationRead $Context $base -AllowMissing
    $clients = @{ resource = $null; frontend = $null; authorization = $null }
    if ($null -ne $realm) {
        if ($realm.realm -cne ([Uri] $model.authority).Segments[-1] -or -not $realm.enabled) { throw 'auth.preparation.realmChanged' }
        $clients.resource = Find-KeycloakPreparationClient $Context $model.resourceServer.clientId
        $clients.frontend = Find-KeycloakPreparationClient $Context $model.frontend.clientId
        $clients.authorization = Find-KeycloakPreparationClient $Context $model.authorizationClientId
        foreach ($kind in $clients.Keys) { Assert-KeycloakPreparationClient $Context $clients[$kind] $kind }
        $scopes = @(Invoke-KeycloakPreparationRead $Context "$base/client-scopes")
        foreach ($name in @('basic', 'acr', 'profile', 'email', 'roles', 'web-origins')) {
            if (@($scopes | Where-Object name -CEQ $name).Count -ne 1) { throw 'auth.preparation.scopeMissing' }
        }
        $byId = Invoke-KeycloakPreparationRead $Context "$base/clients/$($model.resourceServer.id)" -AllowMissing
        if ($null -ne $byId -and $byId.clientId -cne $model.resourceServer.clientId) { throw 'auth.preparation.resourceChanged' }
        if ($realm.adminPermissionsEnabled) { Assert-KeycloakDelegationIdentity $Context $clients.authorization }
    }
    return @{ realmExists = $null -ne $realm; clients = $clients; bindings = Get-KeycloakAuthorizationBindings $model }
}

function Assert-KeycloakDelegationIdentity([hashtable] $Context, $AuthorizationClient) {
    # FGAP combines overlapping resource permissions with AND. A second identity could revoke the first.
    $base = Get-KeycloakPreparationBase $Context
    $permissions = Find-KeycloakPreparationClient $Context 'admin-permissions'
    if ($null -eq $permissions) { throw 'auth.preparation.fgapUnavailable' }
    $account = if ($null -ne $AuthorizationClient) { Invoke-KeycloakPreparationRead $Context "$base/clients/$($AuthorizationClient.id)/service-account-user" } else { $null }
    $policyBase = "$base/clients/$($permissions.id)/authz/resource-server"
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    for ($first = 0; $first -lt 10000; $first += 100) {
        $policies = @(Invoke-KeycloakPreparationRead $Context "$policyBase/policy?type=scope&first=$first&max=100")
        foreach ($policy in $policies) {
            if (-not $seen.Add($policy.id)) { throw 'auth.preparation.policyAmbiguous' }
            $definition = Invoke-KeycloakPreparationRead $Context "$policyBase/permission/scope/$($policy.id)"
            if ($definition.resourceType -cnotin @('Clients', 'Users')) { continue }
            $resources = @(Invoke-KeycloakPreparationRead $Context "$policyBase/policy/$($policy.id)/resources")
            $relevant = ($definition.resourceType -ceq 'Clients' -and @($resources | Where-Object name -CEQ $Context.model.resourceServer.id).Count -gt 0) -or
                ($definition.resourceType -ceq 'Users' -and @($resources | Where-Object name -CEQ 'Users').Count -gt 0)
            if (-not $relevant) { continue }
            $scopes = @(Invoke-KeycloakPreparationRead $Context "$policyBase/policy/$($policy.id)/scopes")
            if (@($scopes | Where-Object name -CIn @('view', 'manage', 'map-roles')).Count -eq 0) { continue }
            if ($null -eq $account -or $definition.logic -cne 'POSITIVE') { throw 'auth.preparation.delegationIdentityConflict' }
            $associated = @(Invoke-KeycloakPreparationRead $Context "$policyBase/policy/$($policy.id)/associatedPolicies")
            if ($associated.Count -ne 1 -or $associated[0].type -cne 'user') { throw 'auth.preparation.delegationIdentityConflict' }
            $user = Invoke-KeycloakPreparationRead $Context "$policyBase/policy/user/$($associated[0].id)"
            if ($user.logic -cne 'POSITIVE' -or @($user.users).Count -ne 1 -or $user.users[0] -cne $account.id) { throw 'auth.preparation.delegationIdentityConflict' }
        }
        if ($policies.Count -lt 100) { return }
    }
    throw 'auth.preparation.policyInventoryTooLarge'
}

function Set-KeycloakPreparationPolicy([hashtable] $Context, [string] $Base, [string] $Kind, [hashtable] $Body) {
    $found = @(Invoke-KeycloakPreparationRead $Context "$Base/policy?name=$([Uri]::EscapeDataString($Body.name))" | Where-Object name -CEQ $Body.name)
    if ($found.Count -gt 1) { throw 'auth.preparation.policyAmbiguous' }
    if ($found.Count -eq 0) { Invoke-KeycloakPreparationWrite $Context POST "$Base/$Kind" $Body }
    else { Invoke-KeycloakPreparationWrite $Context PUT "$Base/$Kind/$($found[0].id)" $Body }
    $verified = @(Invoke-KeycloakPreparationRead $Context "$Base/policy?name=$([Uri]::EscapeDataString($Body.name))" | Where-Object name -CEQ $Body.name)
    if ($verified.Count -ne 1 -or -not $verified[0].id) { throw 'auth.preparation.policyMissing' }
    return $verified[0].id
}

function Invoke-KeycloakAuthorizationPreparation {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([hashtable] $Context)
    $model = $Context.model; $base = Get-KeycloakPreparationBase $Context
    if ([string]::IsNullOrWhiteSpace($env:HEXAGON_AUTHORIZATION_CLIENT_SECRET) -or $env:HEXAGON_AUTHORIZATION_CLIENT_SECRET.Length -lt 32) { throw 'auth.preparation.clientCredentialRequired' }
    $plan = Get-KeycloakAuthorizationPlan $Context
    if (-not $PSCmdlet.ShouldProcess($model.authority, 'Prepare realm, OIDC clients and scoped UMA administration')) { return }
    if (-not $plan.realmExists) {
        Invoke-KeycloakPreparationWrite $Context POST "$(Get-KeycloakPreparationAdminRoot $Context)/realms" @{ realm = ([Uri] $model.authority).Segments[-1]; enabled = $true; sslRequired = 'external'; registrationAllowed = $false; bruteForceProtected = $true }
    }
    $realm = Invoke-KeycloakPreparationRead $Context $base
    if (-not $realm.adminPermissionsEnabled) { Invoke-KeycloakPreparationWrite $Context PUT $base @{ adminPermissionsEnabled = $true } }
    if ($null -eq $plan.clients.resource) {
        Invoke-KeycloakPreparationWrite $Context POST "$base/clients" @{
            id = $model.resourceServer.id; clientId = $model.resourceServer.clientId; protocol = 'openid-connect'; enabled = $true
            publicClient = $false; serviceAccountsEnabled = $true; standardFlowEnabled = $false; directAccessGrantsEnabled = $false
            authorizationServicesEnabled = $true; authorizationSettings = @{ policyEnforcementMode = 'ENFORCING'; decisionStrategy = 'UNANIMOUS'; resources = @(); policies = @(); scopes = @() }
        }
    }
    $resource = Find-KeycloakPreparationClient $Context $model.resourceServer.clientId
    if (-not $resource.ContainsKey('authorizationServicesEnabled') -or -not $resource.authorizationServicesEnabled) {
        Invoke-KeycloakPreparationWrite $Context PUT "$base/clients/$($model.resourceServer.id)" @{
            serviceAccountsEnabled = $true; authorizationServicesEnabled = $true
            authorizationSettings = @{ policyEnforcementMode = 'ENFORCING'; decisionStrategy = 'UNANIMOUS'; resources = @(); policies = @(); scopes = @() }
        }
    }
    if ($null -eq $plan.clients.authorization) {
        Invoke-KeycloakPreparationWrite $Context POST "$base/clients" @{
            clientId = $model.authorizationClientId; secret = $env:HEXAGON_AUTHORIZATION_CLIENT_SECRET; protocol = 'openid-connect'; enabled = $true
            publicClient = $false; serviceAccountsEnabled = $true; standardFlowEnabled = $false; directAccessGrantsEnabled = $false
        }
    }
    $authorization = Find-KeycloakPreparationClient $Context $model.authorizationClientId
    $account = Invoke-KeycloakPreparationRead $Context "$base/clients/$($authorization.id)/service-account-user"
    $management = Find-KeycloakPreparationClient $Context 'realm-management'
    $roles = @('query-clients', 'query-users') | ForEach-Object { Invoke-KeycloakPreparationRead $Context "$base/clients/$($management.id)/roles/$_" }
    Invoke-KeycloakPreparationWrite $Context POST "$base/users/$($account.id)/role-mappings/clients/$($management.id)" @($roles)
    $permissions = Find-KeycloakPreparationClient $Context 'admin-permissions'
    if ($null -eq $permissions) { throw 'auth.preparation.fgapUnavailable' }
    $policyBase = "$base/clients/$($permissions.id)/authz/resource-server"
    $prefix = "hexagon-$($model.authorizationClientId)"
    $policy = Set-KeycloakPreparationPolicy $Context $policyBase 'policy/user' @{ name = "$prefix-identity"; type = 'user'; logic = 'POSITIVE'; users = @($account.id) }
    $null = Set-KeycloakPreparationPolicy $Context $policyBase 'permission/scope' @{
        name = "$prefix-client"; type = 'scope'; resourceType = 'Clients'; resources = @($model.resourceServer.id)
        scopes = @('view', 'manage', 'map-roles'); policies = @($policy); decisionStrategy = 'UNANIMOUS'
    }
    $null = Set-KeycloakPreparationPolicy $Context $policyBase 'permission/scope' @{
        name = "$prefix-mappings"; type = 'scope'; resourceType = 'Users'; resources = @()
        scopes = @('view', 'map-roles'); policies = @($policy); decisionStrategy = 'UNANIMOUS'
    }
    $scopeList = @(Invoke-KeycloakPreparationRead $Context "$base/client-scopes")
    $apiScope = @($scopeList | Where-Object name -CEQ $model.resourceServer.apiScope)
    if ($apiScope.Count -gt 1) { throw 'auth.preparation.scopeAmbiguous' }
    if ($apiScope.Count -eq 0) {
        Invoke-KeycloakPreparationWrite $Context POST "$base/client-scopes" @{ name = $model.resourceServer.apiScope; protocol = 'openid-connect'; attributes = @{ 'include.in.token.scope' = 'true' } }
        $scopeList = @(Invoke-KeycloakPreparationRead $Context "$base/client-scopes")
    }
    $spa = @{
        clientId = $model.frontend.clientId; protocol = 'openid-connect'; enabled = $true; publicClient = $true
        standardFlowEnabled = $true; directAccessGrantsEnabled = $false; serviceAccountsEnabled = $false
        redirectUris = @($model.frontend.origins | ForEach-Object { "$_/authentication/callback" }); webOrigins = @($model.frontend.origins)
        attributes = @{ 'pkce.code.challenge.method' = 'S256'; 'post.logout.redirect.uris' = (@($model.frontend.origins | ForEach-Object { "$_/authentication/login" }) -join '##') }
    }
    if ($null -eq $plan.clients.frontend) { Invoke-KeycloakPreparationWrite $Context POST "$base/clients" $spa }
    else { Invoke-KeycloakPreparationWrite $Context PUT "$base/clients/$($plan.clients.frontend.id)" $spa }
    $frontend = Find-KeycloakPreparationClient $Context $model.frontend.clientId
    $optional = @(Invoke-KeycloakPreparationRead $Context "$base/clients/$($frontend.id)/optional-client-scopes")
    foreach ($name in @('basic', 'acr', 'profile', 'email', 'roles', 'web-origins', $model.resourceServer.apiScope)) {
        $scope = @($scopeList | Where-Object name -CEQ $name)
        if ($scope.Count -ne 1) { throw 'auth.preparation.scopeMissing' }
        if (@($optional | Where-Object id -CEQ $scope[0].id).Count -ne 0) {
            Invoke-KeycloakPreparationWrite $Context DELETE "$base/clients/$($frontend.id)/optional-client-scopes/$($scope[0].id)" $null
        }
        Invoke-KeycloakPreparationWrite $Context PUT "$base/clients/$($frontend.id)/default-client-scopes/$($scope[0].id)" $null
    }
    $mappers = @(Invoke-KeycloakPreparationRead $Context "$base/clients/$($frontend.id)/protocol-mappers/models")
    $mapper = @($mappers | Where-Object name -CEQ 'hexagon-api-audience')
    if ($mapper.Count -gt 1) { throw 'auth.preparation.mapperAmbiguous' }
    $body = @{ name = 'hexagon-api-audience'; protocol = 'openid-connect'; protocolMapper = 'oidc-audience-mapper'
        config = @{ 'included.client.audience' = $model.resourceServer.clientId; 'access.token.claim' = 'true'; 'id.token.claim' = 'false' } }
    if ($mapper.Count -eq 0) { Invoke-KeycloakPreparationWrite $Context POST "$base/clients/$($frontend.id)/protocol-mappers/models" $body }
    else { $body.id = $mapper[0].id; Invoke-KeycloakPreparationWrite $Context PUT "$base/clients/$($frontend.id)/protocol-mappers/models/$($mapper[0].id)" $body }
    Test-KeycloakAuthorizationPreparation $Context
}

function Test-KeycloakAuthorizationPreparation([hashtable] $Context) {
    if ([string]::IsNullOrWhiteSpace($env:HEXAGON_AUTHORIZATION_CLIENT_SECRET)) { throw 'auth.preparation.clientCredentialRequired' }
    $plan = Get-KeycloakAuthorizationPlan $Context; $model = $Context.model; $base = Get-KeycloakPreparationBase $Context
    if (-not $plan.realmExists -or @($plan.clients.Values | Where-Object { $null -eq $_ }).Count -ne 0) { throw 'auth.preparation.incomplete' }
    $resource = $plan.clients.resource; $frontend = $plan.clients.frontend
    if (-not $resource.authorizationServicesEnabled) { throw 'auth.preparation.resourceNotEnforcing' }
    $server = Invoke-KeycloakPreparationRead $Context "$base/clients/$($resource.id)/authz/resource-server"
    if ($server.policyEnforcementMode -cne 'ENFORCING') { throw 'auth.preparation.resourceNotEnforcing' }
    if (-not $frontend.publicClient -or -not $frontend.standardFlowEnabled -or $frontend.directAccessGrantsEnabled -or $frontend.serviceAccountsEnabled -or
        $frontend.attributes['pkce.code.challenge.method'] -cne 'S256' -or
        (@($frontend.webOrigins | Sort-Object) -join ',') -cne (@($model.frontend.origins | Sort-Object) -join ',') -or
        (@($frontend.redirectUris | Sort-Object) -join ',') -cne (@($model.frontend.origins | ForEach-Object { "$_/authentication/callback" } | Sort-Object) -join ',')) { throw 'auth.preparation.frontendChanged' }
    $scopes = @(Invoke-KeycloakPreparationRead $Context "$base/clients/$($frontend.id)/default-client-scopes")
    foreach ($name in @('basic', 'profile', 'email', $model.resourceServer.apiScope)) {
        if (@($scopes | Where-Object name -CEQ $name).Count -ne 1) { throw 'auth.preparation.scopeMissing' }
    }
    $mappers = @(Invoke-KeycloakPreparationRead $Context "$base/clients/$($frontend.id)/protocol-mappers/models")
    if (@($mappers | Where-Object { $_.name -ceq 'hexagon-api-audience' -and $_.protocolMapper -ceq 'oidc-audience-mapper' -and
        $_.config['included.client.audience'] -ceq $model.resourceServer.clientId -and $_.config['access.token.claim'] -ceq 'true' }).Count -ne 1) { throw 'auth.preparation.audienceChanged' }
    $realm = Invoke-KeycloakPreparationRead $Context $base
    if (-not $realm.adminPermissionsEnabled) { throw 'auth.preparation.fgapUnavailable' }
    $permissions = Find-KeycloakPreparationClient $Context 'admin-permissions'
    if ($null -eq $permissions) { throw 'auth.preparation.fgapUnavailable' }
    $policyBase = "$base/clients/$($permissions.id)/authz/resource-server"
    $prefix = "hexagon-$($model.authorizationClientId)"
    $account = Invoke-KeycloakPreparationRead $Context "$base/clients/$($plan.clients.authorization.id)/service-account-user"
    $identity = @(Invoke-KeycloakPreparationRead $Context "$policyBase/policy?name=$prefix-identity" | Where-Object name -CEQ "$prefix-identity")
    if ($identity.Count -ne 1 -or $identity[0].type -cne 'user') { throw 'auth.preparation.delegationChanged' }
    $userPolicy = Invoke-KeycloakPreparationRead $Context "$policyBase/policy/user/$($identity[0].id)"
    if ($userPolicy.logic -cne 'POSITIVE' -or @($userPolicy.users).Count -ne 1 -or $userPolicy.users[0] -cne $account.id) { throw 'auth.preparation.delegationChanged' }
    foreach ($entry in @(
        @{ suffix = 'client'; type = 'Clients'; resources = $model.resourceServer.id; scopes = 'manage,map-roles,view' },
        @{ suffix = 'mappings'; type = 'Users'; resources = 'Users'; scopes = 'map-roles,view' }
    )) {
        $name = "$prefix-$($entry.suffix)"
        $policy = @(Invoke-KeycloakPreparationRead $Context "$policyBase/policy?name=$name" | Where-Object name -CEQ $name)
        if ($policy.Count -ne 1 -or $policy[0].type -cne 'scope') { throw 'auth.preparation.delegationChanged' }
        $definition = Invoke-KeycloakPreparationRead $Context "$policyBase/permission/scope/$($policy[0].id)"
        $resources = @(Invoke-KeycloakPreparationRead $Context "$policyBase/policy/$($policy[0].id)/resources")
        $scopes = @(Invoke-KeycloakPreparationRead $Context "$policyBase/policy/$($policy[0].id)/scopes")
        $associated = @(Invoke-KeycloakPreparationRead $Context "$policyBase/policy/$($policy[0].id)/associatedPolicies")
        if ($definition.resourceType -cne $entry.type -or $definition.logic -cne 'POSITIVE' -or $definition.decisionStrategy -cne 'UNANIMOUS' -or
            (@($resources.name | Sort-Object) -join ',') -cne $entry.resources -or (@($scopes.name | Sort-Object) -join ',') -cne $entry.scopes -or
            $associated.Count -ne 1 -or $associated[0].id -cne $identity[0].id) { throw 'auth.preparation.delegationChanged' }
    }
    return Get-KeycloakAuthorizationBindings $model
}

Export-ModuleMember -Function Read-KeycloakAuthorization, Get-KeycloakAuthorizationBindings, New-KeycloakAuthorizationContext,
    Get-KeycloakAuthorizationPlan, Invoke-KeycloakAuthorizationPreparation, Test-KeycloakAuthorizationPreparation
