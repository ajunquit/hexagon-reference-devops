Set-StrictMode -Version Latest

# Helpers shared by the local topology of every messaging provider.

function Get-PolicyItem {
    param(
        [AllowNull()]
        [pscustomobject] $Policy,
        [Parameter(Mandatory = $true)]
        [string] $Collection,
        [Parameter(Mandatory = $true)]
        [string] $Id
    )

    if ($null -eq $Policy) { return $null }
    return @($Policy.$Collection | Where-Object { [string] $_.id -ceq $Id })[0]
}

function Add-LocalEnvironmentValue {
    param(
        [Parameter(Mandatory = $true)]
        [Collections.Specialized.OrderedDictionary] $Workloads,
        [Parameter(Mandatory = $true)]
        [string] $Workload,
        [Parameter(Mandatory = $true)]
        [string] $Name,
        [Parameter(Mandatory = $true)]
        [string] $Value
    )

    if (-not $Workloads.Contains($Workload)) {
        $Workloads.Add($Workload, [ordered] @{})
    }
    $Workloads[$Workload][$Name] = $Value
}

Export-ModuleMember -Function Get-PolicyItem, Add-LocalEnvironmentValue
