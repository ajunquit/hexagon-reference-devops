Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../scripts/KeycloakAuthorization.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../scripts/AuthorizationDelivery.psm1') -Force
function Assert-Rejected([scriptblock] $Action, [string] $Code) {
    try { & $Action | Out-Null; throw 'Unsafe authorization configuration was accepted.' }
    catch { if ($_.Exception.Message -cnotlike "*$Code*") { throw } }
}
$path = Join-Path ([IO.Path]::GetTempPath()) "auth-config-$([Guid]::NewGuid().ToString('N')).json"
$fixture = Get-Content (Join-Path $PSScriptRoot '../examples/keycloak-authorization.json') -Raw | ConvertFrom-Json -AsHashtable
try {
    $fixture | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $path
    $model = Read-KeycloakAuthorization $path
    $public = Get-KeycloakAuthorizationBindings $model
    if ($public.environment.Auth__Authorization__Product -cne 'hexagon-example' -or
        ($public.maintenanceArguments -join ',') -cne '--migrate-only,--reconcile-auth-authorization,--provision-auth-authorization') { throw 'Incomplete public authorization bindings.' }
    foreach ($kind in @('master', 'loopback', 'clientCollision', 'insecureOrigin', 'sharedIdentity', 'inlineSecret')) {
        $bad = ($fixture | ConvertTo-Json -Depth 15) | ConvertFrom-Json -AsHashtable
        switch ($kind) {
            master { $bad.authority = 'https://identity.example.invalid/realms/master' }
            loopback { $bad.authority = 'https://localhost:8188/realms/hexagon' }
            clientCollision { $bad.frontend.clientId = $bad.resourceServer.clientId }
            insecureOrigin { $bad.frontend.origins = @('http://web.example.invalid') }
            sharedIdentity { $bad.authorizationClientId = 'hexagon-example-authorization' }
            inlineSecret { $bad.clientSecret = 'forbidden-inline-value' }
        }
        $bad | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $path
        Assert-Rejected { Read-KeycloakAuthorization $path } 'auth.preparation.'
    }
    $fixture | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $path
    # WhatIf is useful on an empty platform and must not need an operator credential or make HTTP calls.
    & (Join-Path $PSScriptRoot '../scripts/Invoke-KeycloakAuthorization.ps1') -Configuration $path -Mode Apply -WhatIf | Out-Null
    $observed = [Collections.Generic.List[string]]::new()
    $context = @{ model=$model; http={ param($method,$requestPath,$body)
        $observed.Add($method + ' ' + $requestPath)
        if ($method -cne 'GET') { throw 'Plan attempted a write.' }
        if ($requestPath -ceq '/admin/serverinfo') { return @{status=200;value=@{systemInfo=@{version='26.6.0'}}} }
        return @{status=404;value=$null}
    }.GetNewClosure() }
    $plan = Get-KeycloakAuthorizationPlan $context
    if ($plan.realmExists -or $observed.Count -ne 2) { throw 'Empty-platform plan is not read-only and bounded.' }
    $model.authority='https://example.cloudfront.net/auth/realms/hexagon-example'
    $observed.Clear()
    $context.http={param($method,$requestPath,$body) $observed.Add($method+' '+$requestPath)
        if($requestPath -ceq '/auth/admin/serverinfo') { return @{status=200;value=@{systemInfo=@{version='26.6.0'}}} }
        if($requestPath -ceq '/auth/admin/realms/hexagon-example') { return @{status=404;value=$null} }
        throw 'Keycloak relative path was lost.'
    }.GetNewClosure()
    $null=Get-KeycloakAuthorizationPlan $context
    if($observed.Count -ne 2) {throw 'Relative-path plan made unexpected calls.'}
    $model.authority=$fixture.authority
    $context.http = { param($method,$requestPath,$body) return @{status=403;value=$null} }
    Assert-Rejected { Get-KeycloakAuthorizationPlan $context } 'readFailed:403'
    $context.http = { param($method,$requestPath,$body) return @{status=200;value=@{systemInfo=@{version='26.3.0'}}} }
    Assert-Rejected { Get-KeycloakAuthorizationPlan $context } 'versionUnsupported'
    $inputs = @{ product=$model.product; migration_workload='api'; workloads=@{ api=@{environment=@{}; secret_references=@{}}; worker=@{environment=@{};secret_references=@{}} } }
    if ($null -ne (Get-HostingAuthorizationBindings $inputs)) { throw 'Legacy input was made to require an authorization job.' }
    $inputs.workloads.api.environment = @{} + $public.environment
    foreach ($key in @('Auth__Authority','Auth__Audience','Auth__ApiScope')) { $inputs.workloads.api.environment.Remove($key) }
    $inputs.workloads.api.secret_references.Auth__Authorization__ClientSecret = @{secret_arn='arn:aws:secretsmanager:us-east-1:000000000001:secret:auth-fixture'}
    if ((Get-HostingAuthorizationBindings $inputs).environment.Count -ne 3) { throw 'Public authorization environment differs.' }
    $journal=@{jobs=@{}}
    Assert-Rejected { Assert-AuthorizationTaskOrder $journal $inputs } 'previousTaskRequired'
    $journal.jobs=@{migrations=@{status='Succeeded'};'database-access'=@{status='Succeeded'}}
    Assert-AuthorizationTaskOrder $journal $inputs
    Assert-Rejected { Assert-AuthorizationReady $journal $inputs } 'preparationRequired'
    $journal.jobs.authorization=@{status='Failed'}
    Assert-Rejected { Assert-AuthorizationReady $journal $inputs } 'preparationRequired'
    $journal.jobs.authorization.status='Succeeded'
    Assert-AuthorizationReady $journal $inputs
    $inputs.workloads.worker.environment.Auth__Authorization__ClientId='forbidden-worker'
    Assert-Rejected { Get-HostingAuthorizationBindings $inputs } 'apiOnly'
    $inputs.workloads.worker.environment.Clear()
    $inputs.workloads.api.environment.Auth__Authorization__Product='hexagon-foreign'
    Assert-Rejected { Get-HostingAuthorizationBindings $inputs } 'bindingsInvalid'
    Write-Host 'Keycloak preparation and authorization delivery guardrails passed.'
} finally { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path } }
