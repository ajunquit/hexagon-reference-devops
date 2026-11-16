<#
.SYNOPSIS
    Exercises empty realm, repetition, preservation and scoped privileges on disposable local Keycloak.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string] $Origin)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$uri = [Uri] $Origin
if (-not $uri.IsLoopback -or $uri.Scheme -cne 'https' -or $uri.AbsolutePath -cne '/' -or $uri.Query -or $uri.Fragment -or $uri.UserInfo) { throw 'Use only the HTTPS origin of a disposable local Keycloak server.' }
Import-Module (Join-Path $PSScriptRoot '../scripts/KeycloakAuthorization.psm1') -Force
$module = Get-Module KeycloakAuthorization
$oldSecret = $env:HEXAGON_AUTHORIZATION_CLIENT_SECRET
$env:HEXAGON_AUTHORIZATION_CLIENT_SECRET = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
$realm = 'auth-test-' + [Guid]::NewGuid().ToString('N').Substring(0,12)
$path = Join-Path ([IO.Path]::GetTempPath()) "$realm.json"
$model = @{
    apiVersion = 'hexagon.ec/keycloak-authorization/v1'; kind = 'KeycloakAuthorization'; product = 'hexagon-example'; environment = 'local'
    authority = "$($Origin.TrimEnd('/'))/realms/$realm"; resourceServer = @{ id = [Guid]::NewGuid().ToString(); clientId = 'hexagon-example-api'; apiScope = 'hexagon_example_api.all' }
    frontend = @{ clientId = 'hexagon-example-web'; origins = @('http://localhost:4200') }; authorizationClientId = 'hexagon-example-local-authorization'
}
$context = $null
try {
    [IO.File]::WriteAllText($path, ($model | ConvertTo-Json -Depth 10))
    $model = Read-KeycloakAuthorization $path
    $context = New-KeycloakAuthorizationContext $model
    $plan = Get-KeycloakAuthorizationPlan $context
    if ($plan.realmExists) { throw 'The disposable realm unexpectedly exists.' }
    Invoke-KeycloakAuthorizationPreparation $context -Confirm:$false | Out-Null
    $base = '/admin/realms/' + $realm
    $resourceBase = "$base/clients/$($model.resourceServer.id)/authz/resource-server"
    # Imported realms can assign the API scope as optional by default. Promotion needs an explicit removal first.
    & $module { param($c,$b,$clientId,$scopeName)
        $frontend = Find-KeycloakPreparationClient $c $clientId
        $scope = @(Invoke-KeycloakPreparationRead $c "$b/client-scopes" | Where-Object name -CEQ $scopeName)[0]
        Invoke-KeycloakPreparationWrite $c DELETE "$b/clients/$($frontend.id)/default-client-scopes/$($scope.id)" $null
        Invoke-KeycloakPreparationWrite $c PUT "$b/clients/$($frontend.id)/optional-client-scopes/$($scope.id)" $null
    } $context $base $model.frontend.clientId $model.resourceServer.apiScope
    # These represent later runtime edits; preparation must leave their bytes and IDs intact.
    & $module { param($c,$b) Invoke-KeycloakPreparationWrite $c POST "$b/scope" @{ name = 'GET' } } $context $resourceBase
    & $module { param($c,$b) Invoke-KeycloakPreparationWrite $c POST "$b/resource" @{ name = 'hexagon-example:fixture:Auth.GetMe'; type = 'hexagon.operation'; scopes = @(@{name='GET'}) } } $context $resourceBase
    & $module { param($c,$b) Invoke-KeycloakPreparationWrite $c POST "$b/policy/role" @{name='runtime-owned-policy';type='role';logic='POSITIVE';roles=@();fetchRoles=$true} } $context $resourceBase
    $before = & $module { param($c,$b) @{ resources = @(Invoke-KeycloakPreparationRead $c "$b/resource"); policies = @(Invoke-KeycloakPreparationRead $c "$b/policy") } | ConvertTo-Json -Depth 30 -Compress } $context $resourceBase
    Invoke-KeycloakAuthorizationPreparation $context -Confirm:$false | Out-Null
    Test-KeycloakAuthorizationPreparation $context | Out-Null
    $after = & $module { param($c,$b) @{ resources = @(Invoke-KeycloakPreparationRead $c "$b/resource"); policies = @(Invoke-KeycloakPreparationRead $c "$b/policy") } | ConvertTo-Json -Depth 30 -Compress } $context $resourceBase
    if ($before -cne $after) { throw 'Preparation overwrote runtime resources or policies.' }
    $otherModel = ($model | ConvertTo-Json -Depth 15) | ConvertFrom-Json -AsHashtable
    $otherModel.authorizationClientId = 'hexagon-example-another-authorization'
    $otherContext = @{ model=$otherModel; token=$context.token; client=$context.client }
    try { Get-KeycloakAuthorizationPlan $otherContext | Out-Null; throw 'A competing delegation identity was accepted.' }
    catch { if ($_.Exception.Message -cnotlike '*delegationIdentityConflict*') { throw } }
    $bindings = Get-KeycloakAuthorizationBindings $model | ConvertTo-Json -Depth 20
    if ($bindings.Contains($env:HEXAGON_AUTHORIZATION_CLIENT_SECRET) -or $bindings.Contains($context.token)) { throw 'Public bindings leaked a credential.' }
    $token = Invoke-RestMethod "$($Origin.TrimEnd('/'))/realms/$realm/protocol/openid-connect/token" -Method Post -Body @{
        grant_type = 'client_credentials'; client_id = $model.authorizationClientId; client_secret = $env:HEXAGON_AUTHORIZATION_CLIENT_SECRET
    }
    $serviceContext = @{ model = $model; token = $token.access_token; client = $context.client }
    $own = & $module { param($c,$b) Invoke-KeycloakPreparationHttp $c GET "$b/resource" } $serviceContext $resourceBase
    if ($own.status -ne 200) { throw 'Delegated client cannot read its resource server.' }
    $foreignId = [Guid]::NewGuid().ToString()
    & $module { param($c,$b,$id) Invoke-KeycloakPreparationWrite $c POST "$b/clients" @{ id=$id; clientId='foreign-api'; protocol='openid-connect'; enabled=$true; publicClient=$false } } $context $base $foreignId
    foreach ($operation in @(
        @{method='GET';path="$base/clients/$foreignId";body=$null},
        @{method='PUT';path="$base/clients/$foreignId";body=@{enabled=$false}},
        @{method='DELETE';path=$base;body=$null}
    )) {
        $response = & $module { param($c,$op) Invoke-KeycloakPreparationHttp $c $op.method $op.path $op.body } $serviceContext $operation
        if ($response.status -notin @(403,404)) { throw 'Delegated client has foreign-client or realm administration rights.' }
    }
    # Wrong secret must stop before mutation; it must never rotate the existing client silently.
    $expected = $env:HEXAGON_AUTHORIZATION_CLIENT_SECRET; $env:HEXAGON_AUTHORIZATION_CLIENT_SECRET = 'invalid-' + $expected
    try { Invoke-KeycloakAuthorizationPreparation $context -Confirm:$false | Out-Null; throw 'Wrong credential was accepted.' }
    catch { if ($_.Exception.Message -cnotlike '*credentialMismatch*') { throw } }
    finally { $env:HEXAGON_AUTHORIZATION_CLIENT_SECRET = $expected }
    Write-Host 'Keycloak authorization acceptance passed: empty realm, repeat, preservation, scopes, audience, bounded identity and credential mismatch.'
} finally {
    if ($null -ne $context) {
        # The only deletion target was minted in this invocation on a loopback server.
        if ($realm -cnotmatch '^auth-test-[0-9a-f]{12}$') { throw 'Invalid disposable realm cleanup target.' }
        try { & $module { param($c,$realm) Invoke-KeycloakPreparationWrite $c DELETE "/admin/realms/$realm" $null } $context $realm }
        finally { $context.client.Dispose(); $context.handler.Dispose(); $context.token = $null }
    }
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
    $env:HEXAGON_AUTHORIZATION_CLIENT_SECRET = $oldSecret
}
