Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'HostingContracts.psm1')

# Hosting inputs of Azure: the shared composition of HostingContracts with images promoted into the ACR.
function ConvertTo-AzureHostingInput {
    param($Descriptor, $Release, $Policy, $Backend, $Frontend)
    $registry = $Policy.infrastructure.registry_name
    return ConvertTo-HostingInput $Descriptor $Release $Policy $Backend $Frontend { param($image) ConvertTo-EnvironmentImageReference $image $registry }
}

function ConvertTo-EnvironmentImageReference([string] $Image, [string] $Registry) {
    # Promotion copies the same manifest/layers into the target ACR; it never rebuilds the image.
    return "$Registry.azurecr.io/" + $Image.Substring($Image.IndexOf('/') + 1)
}

Export-ModuleMember -Function ConvertTo-AzureHostingInput
