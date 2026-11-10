Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
foreach ($name in @('AzureAcceptance', 'AcceptanceCleanup', 'AzureEnvironmentStore', 'EnvironmentSnapshot')) { Import-Module (Join-Path $PSScriptRoot "$name.psm1") }

function Invoke-AcceptanceRun {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([hashtable] $Context, [hashtable] $Journal, [hashtable] $Consent, [string] $ConsentSha256,
        [hashtable] $Configuration, [string] $Workspace, [Parameter(Mandatory)][scriptblock] $Seed,
        [Parameter(Mandatory)][scriptblock] $PersistJournal,
        [scriptblock] $Browser = { param($context, $configuration) Invoke-AzureBrowserAcceptance $context $configuration -Confirm:$false },
        [scriptblock] $Cleanup = { param($context, $consent, $workspace) Invoke-AcceptanceCleanup $context $consent $workspace -Confirm:$false },
        [scriptblock] $PersistEvidence = { param($context, $evidence) Save-AcceptanceEvidence $context $evidence -Confirm:$false })
    if (-not $PSCmdlet.ShouldProcess($Context.prefix, 'Run acceptance and retire the consented ephemeral instance')) { return }
    if ($Journal.ContainsKey('acceptance')) { throw 'lifecycle.acceptance.alreadyStarted' }
    $Journal.acceptance = @{ consentSha256 = $ConsentSha256; status = 'Testing'; journeySucceeded = $false; cleanupStatus = 'Pending'; evidenceSha256 = $null }
    & $PersistJournal
    $failure = $null
    $evidence = @{ apiVersion = 'hexagon.ec/acceptance-evidence/v1'; product = $Context.inventory.product; environment = $Context.inventory.environment; instanceId = $Context.inventory.instance.id
        releaseSha256 = $Context.inventory.releaseSha256; deliverySha256 = $Journal.deliverySha256; consentSha256 = $ConsentSha256
        observedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); journeySucceeded = $false; cleanupStatus = 'Pending'; code = $null }
    try {
        & $Seed
        $browserResult = & $Browser $Context $Configuration
        if ($null -eq $browserResult -or $browserResult.status -cne 'Succeeded' -or $browserResult.pkce -ne $true -or $browserResult.authenticatedCreate -ne $true -or $browserResult.workerReaction -ne $true -or $browserResult.tenantIsolation -ne $true) { throw 'lifecycle.acceptance.browserFailed' }
        $evidence.journeySucceeded = $true
    }
    catch { $failure = $(if ($_.Exception.Message -cmatch '^lifecycle[.][A-Za-z0-9.]+$') { $_.Exception.Message } else { 'lifecycle.acceptance.journeyFailed' }); $evidence.code = $failure }
    finally {
        # Persist the result before retiring data, including failed test attempts. No deletion without durable evidence.
        $Journal.acceptance.evidenceSha256 = & $PersistEvidence $Context $evidence
        $Journal.acceptance.journeySucceeded = $evidence.journeySucceeded; $Journal.acceptance.status = 'Cleaning'
        & $PersistJournal
        try {
            & $Cleanup $Context $Consent $Workspace
            $evidence.cleanupStatus = 'Destroyed'
        }
        catch { $evidence.cleanupStatus = 'Failed'; $failure = 'lifecycle.acceptance.cleanupFailed'; $evidence.code = $failure }
        $evidence.observedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $hash = & $PersistEvidence $Context $evidence
        $Journal.acceptance.evidenceSha256 = $hash; $Journal.acceptance.cleanupStatus = $evidence.cleanupStatus
        $Journal.acceptance.status = $(if ($failure) { 'Failed' } else { 'Completed' })
        & $PersistJournal
    }
    if ($failure) { throw $failure }
    return @{ evidenceSha256 = $hash; journeySucceeded = $true; cleanupStatus = 'Destroyed' }
}

Export-ModuleMember -Function Invoke-AcceptanceRun
