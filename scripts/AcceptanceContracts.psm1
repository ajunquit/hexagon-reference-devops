Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
foreach ($name in @('ApplicationContracts', 'CanonicalJson')) { Import-Module (Join-Path $PSScriptRoot "$name.psm1") }

# The acceptance inputs shared by every cloud: the ephemeral fixture of the instance and the contracts
# that the backend and the web declare in their acceptance requirements.
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

Export-ModuleMember -Function Get-AcceptanceFixture, Get-AcceptanceContracts
