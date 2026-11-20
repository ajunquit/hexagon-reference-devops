Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The cloud adapter of the repository (ADR 0043 of the platform): a module named *CloudAdapter.psm1 next
# to this one implements the same functions for its cloud. The entry points choose it by the target of
# the inventory and call its functions inside the module, so they never branch by cloud. The adapter
# modules export nothing: several can coexist while this template still holds more than one cloud.
$script:adapters = $null

function Get-CloudAdapters {
    if ($null -eq $script:adapters) {
        $script:adapters = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*CloudAdapter.psm1' -File | Sort-Object Name |
            ForEach-Object { Import-Module $_.FullName -PassThru -DisableNameChecking })
    }
    return $script:adapters
}

function Get-CloudAdapter([hashtable] $Inventory) {
    $matching = @(Get-CloudAdapters | Where-Object { & $_ { param($target) Test-CloudTarget $target } $Inventory.target })
    if ($matching.Count -ne 1) { throw 'lifecycle.cloud.targetUnsupported' }
    return $matching[0]
}

function Invoke-CloudAdapter([Management.Automation.PSModuleInfo] $Adapter, [string] $Name, [object[]] $Arguments = @()) {
    return & $Adapter { param($command, $values) & $command @values } $Name $Arguments
}

Export-ModuleMember -Function Get-CloudAdapter, Invoke-CloudAdapter
