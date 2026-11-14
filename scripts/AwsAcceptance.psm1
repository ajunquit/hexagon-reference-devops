Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
foreach ($name in @('PlatformBootstrap', 'EnvironmentLifecycle', 'EnvironmentSnapshot', 'AwsEnvironmentStore', 'TerraformAwsLifecycle', 'AcceptanceCleanup', 'LifecycleNative')) {
    Import-Module (Join-Path $PSScriptRoot "$name.psm1")
}

# The AWS pieces of the authenticated acceptance (ADR 0025). Invoke-AcceptanceRun stays common: it
# receives the browser, the evidence store and the cleanup of the cloud. Cleanup retires only the
# consented resource set, root by root in destroy order, with plans checked against the consent.

function Invoke-AwsBrowserAcceptance {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([hashtable] $Context, [hashtable] $Configuration)
    if (-not $PSCmdlet.ShouldProcess($Context.prefix, 'Run the authenticated browser acceptance without persisted credentials')) { return }
    if (-not $env:HEXAGON_E2E_USERNAME -or -not $env:HEXAGON_E2E_PASSWORD) { throw 'lifecycle.acceptance.credentialsMissing' }
    $file = Join-Path $Context.runtime "acceptance-$([guid]::NewGuid().ToString('N')).json"
    [IO.File]::WriteAllText($file, (ConvertTo-Json -InputObject $Configuration -Depth 12 -Compress))
    $renew = (Get-Command Assert-AwsLifecycleLease).ScriptBlock; $heartbeat = { & $renew $Context -Confirm:$false }.GetNewClosure()
    $result = Invoke-LifecycleCommand acceptance-browser @($file) -Environment @{ HEXAGON_E2E_USERNAME = $env:HEXAGON_E2E_USERNAME; HEXAGON_E2E_PASSWORD = $env:HEXAGON_E2E_PASSWORD } -TimeoutSeconds 240 -Heartbeat $heartbeat
    if ($result.exitCode -ne 0 -or $result.bytes.Length -gt 2048) { throw 'lifecycle.acceptance.browserFailed' }
    $value = $result.text | ConvertFrom-Json -AsHashtable
    if ($value.apiVersion -cne 'hexagon.ec/browser-acceptance-result/v1' -or $value.status -cne 'Succeeded' -or $value.pkce -ne $true -or
        $value.authenticatedCreate -ne $true -or $value.workerReaction -ne $true -or $value.tenantIsolation -ne $true -or $value.Count -ne 6) { throw 'lifecycle.acceptance.browserFailed' }
    return $value
}

function Save-AwsAcceptanceEvidence {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([hashtable] $Context, [hashtable] $Evidence)
    if (-not $PSCmdlet.ShouldProcess($Context.prefix, 'Persist acceptance evidence outside workload resources')) { return }
    if (-not ((ConvertTo-Json -InputObject $Evidence -Depth 12) | Test-Json -SchemaFile (Join-Path $PSScriptRoot '../contracts/schemas/acceptance-evidence-v1.schema.json') -ErrorAction SilentlyContinue)) { throw 'lifecycle.acceptance.evidenceInvalid' }
    $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Evidence -Depth 12 -Compress)); $hash = Get-AwsLifecycleBytesHash $bytes
    Publish-AwsLifecycleObject $Context "evidence/$hash.json" $bytes $hash -Confirm:$false
    return $hash
}

function Invoke-AwsAcceptanceCleanup {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([hashtable] $Context, [hashtable] $Consent, [string] $Workspace)
    if (-not $PSCmdlet.ShouldProcess($Context.prefix, 'Retire only the pre-reviewed ephemeral resource set')) { return }
    $inventoryPath = Join-Path $Workspace 'inventory.json'
    Invoke-AwsLifecycleQuiesce $Context -Confirm:$false | Out-Null
    foreach ($id in @(Get-EnvironmentRootOrder $Context.inventory Destroy)) {
        $Context.inventory = Read-EnvironmentInventory $inventoryPath
        $root = @($Context.inventory.roots | Where-Object id -CEQ $id)[0]
        $plan = New-AwsLifecyclePlan $Context $root Destroy -Confirm:$false
        $json = Get-Content -Raw -LiteralPath $plan.jsonPath | ConvertFrom-Json -AsHashtable -Depth 100
        Assert-AcceptanceDestroyPlan $Context.inventory $root $Consent $json
        $hash = Add-EnvironmentRootPlan $inventoryPath $id Destroy $plan.binaryPath $plan.jsonPath (Get-LifecycleFileHash $inventoryPath) -Confirm:$false
        Publish-AwsLifecycleObject $Context "plans/$hash/$id.tfplan" ([IO.File]::ReadAllBytes($plan.binaryPath)) (Get-LifecycleFileHash $plan.binaryPath) -Confirm:$false
        Publish-AwsLifecycleObject $Context "plans/$hash/$id.json" ([IO.File]::ReadAllBytes($plan.jsonPath)) (Get-LifecycleFileHash $plan.jsonPath) -Confirm:$false
        Save-AwsLifecycleJournal $Context $inventoryPath -Confirm:$false | Out-Null
        $Context.inventory = Read-EnvironmentInventory $inventoryPath
        $confirmation = "DESTROY $($Context.inventory.product) $($Context.inventory.environment) $($Context.inventory.instance.id)"
        Invoke-EnvironmentRootOperation $inventoryPath $id $plan.binaryPath $plan.jsonPath $hash $confirmation (New-AwsLifecyclePort $Context) -Confirm:$false | Out-Null
    }
    $Context.inventory = Read-EnvironmentInventory $inventoryPath
    if (@($Context.inventory.roots | Where-Object status -CNE 'Destroyed').Count -ne 0) { throw 'lifecycle.acceptance.cleanupIncomplete' }
}

Export-ModuleMember -Function Invoke-AwsBrowserAcceptance, Save-AwsAcceptanceEvidence, Invoke-AwsAcceptanceCleanup
