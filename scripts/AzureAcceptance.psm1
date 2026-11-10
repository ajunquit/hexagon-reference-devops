Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
foreach ($name in @('ApplicationContracts', 'AcceptanceCleanup', 'AzureEnvironmentStore', 'EnvironmentSnapshot', 'LifecycleNative')) { Import-Module (Join-Path $PSScriptRoot "$name.psm1") }

function Get-AcceptanceFixture([hashtable] $Inventory, [hashtable] $Inputs) {
    if (-not $Inputs.ContainsKey('acceptance_fixture') -or $null -eq $Inputs.acceptance_fixture) { throw 'lifecycle.acceptance.fixtureRequired' }
    $fixture = $Inputs.acceptance_fixture
    if ($Inventory.instance.kind -cne 'Ephemeral' -or $Inventory.environment -cnotin @('dev', 'staging') -or $Inventory.dataPolicy -cne 'DeleteEphemeral' -or
        $fixture.instanceId -cne $Inventory.instance.id -or $fixture.tenant -cne "e2e-$($Inventory.instance.id)-a" -or $fixture.otherTenant -cne "e2e-$($Inventory.instance.id)-b" -or
        $fixture.subjectId -cnotmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$' -or $fixture.Count -ne 4) { throw 'lifecycle.acceptance.fixtureInvalid' }
    return $fixture
}

function Get-AcceptanceContracts([hashtable] $Release) {
    $previous = $env:GH_TOKEN
    if (-not $env:HEXAGON_APPLICATIONS_READ_TOKEN) { throw 'lifecycle.acceptance.sourceCredentialRequired' }
    try {
        $env:GH_TOKEN = $env:HEXAGON_APPLICATIONS_READ_TOKEN
        $contracts = @{}
        foreach ($component in @('backend', 'web')) {
            $source = @($Release.sources | Where-Object name -CEQ $component)
            if ($source.Count -ne 1) { throw 'lifecycle.acceptance.componentRequired' }
            $manifest = @($source[0].manifests | Where-Object path -CEQ '.hexagon/acceptance-requirements.json')
            if ($manifest.Count -ne 1) { throw 'lifecycle.acceptance.manifestRequired' }
            $bytes = Get-GitHubFileBytes $source[0].repository $source[0].commit $manifest[0].path
            if ($bytes.Length -gt 16384 -or (Get-LifecycleBytesHash $bytes) -cne $manifest[0].sha256) { throw 'lifecycle.acceptance.manifestChanged' }
            $json = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
            if (-not ($json | Test-Json -SchemaFile (Join-Path $PSScriptRoot '../contracts/schemas/acceptance-requirements-v1.schema.json') -ErrorAction SilentlyContinue)) { throw 'lifecycle.acceptance.manifestInvalid' }
            $value = $json | ConvertFrom-Json -AsHashtable
            if ($value.product -cne $Release.product -or $value.component -cne $component) { throw 'lifecycle.acceptance.manifestMismatch' }
            $contracts[$component] = $value.contract
        }
        return $contracts
    }
    catch {
        if ($_.Exception.Message -cmatch '^lifecycle[.][A-Za-z0-9.]+$') { throw }
        throw 'lifecycle.acceptance.sourceUnavailable'
    }
    finally { $env:GH_TOKEN = $previous }
}

function Invoke-AzureBrowserAcceptance {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([hashtable] $Context, [hashtable] $Configuration)
    if (-not $PSCmdlet.ShouldProcess($Context.prefix, 'Run the authenticated browser acceptance without persisted credentials')) { return }
    if (-not $env:HEXAGON_E2E_USERNAME -or -not $env:HEXAGON_E2E_PASSWORD) { throw 'lifecycle.acceptance.credentialsMissing' }
    $file = Join-Path $Context.runtime "acceptance-$([guid]::NewGuid().ToString('N')).json"
    [IO.File]::WriteAllText($file, (ConvertTo-Json -InputObject $Configuration -Depth 12 -Compress))
    $renew = (Get-Command Assert-AzureLifecycleLease).ScriptBlock; $heartbeat = { & $renew $Context }.GetNewClosure()
    $result = Invoke-LifecycleCommand acceptance-browser @($file) -Environment @{ HEXAGON_E2E_USERNAME = $env:HEXAGON_E2E_USERNAME; HEXAGON_E2E_PASSWORD = $env:HEXAGON_E2E_PASSWORD } -TimeoutSeconds 240 -Heartbeat $heartbeat
    if ($result.exitCode -ne 0 -or $result.bytes.Length -gt 2048) { throw 'lifecycle.acceptance.browserFailed' }
    $value = $result.text | ConvertFrom-Json -AsHashtable
    if ($value.apiVersion -cne 'hexagon.ec/browser-acceptance-result/v1' -or $value.status -cne 'Succeeded' -or $value.pkce -ne $true -or
        $value.authenticatedCreate -ne $true -or $value.workerReaction -ne $true -or $value.tenantIsolation -ne $true -or $value.Count -ne 6) { throw 'lifecycle.acceptance.browserFailed' }
    return $value
}

function Save-AcceptanceEvidence {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([hashtable] $Context, [hashtable] $Evidence)
    if (-not $PSCmdlet.ShouldProcess($Context.prefix, 'Persist acceptance evidence outside workload resources')) { return }
    if (-not ((ConvertTo-Json -InputObject $Evidence -Depth 12) | Test-Json -SchemaFile (Join-Path $PSScriptRoot '../contracts/schemas/acceptance-evidence-v1.schema.json') -ErrorAction SilentlyContinue)) { throw 'lifecycle.acceptance.evidenceInvalid' }
    $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Evidence -Depth 12 -Compress)); $hash = Get-LifecycleBytesHash $bytes
    Publish-AzureLifecycleObject $Context "$($Context.prefix)/evidence/$hash.json" $bytes $hash -Confirm:$false
    return $hash
}

Export-ModuleMember -Function Get-AcceptanceFixture, Get-AcceptanceContracts, Invoke-AzureBrowserAcceptance, Save-AcceptanceEvidence
