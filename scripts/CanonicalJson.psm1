Set-StrictMode -Version Latest

# Canonical JSON and hashes shared by every cloud: keys sorted case-sensitively at every level, so
# the same document always produces the same bytes and the same SHA-256.
function ConvertTo-CanonicalJson {
    param([Parameter(Mandatory)][object] $Value)
    function ConvertTo-CanonicalValue($Item) {
        if ($Item -is [Collections.IDictionary]) {
            $map = [ordered] @{}
            foreach ($key in @($Item.Keys | Sort-Object -CaseSensitive)) { $map[$key] = ConvertTo-CanonicalValue $Item[$key] }
            return $map
        }
        if ($Item -is [Collections.IEnumerable] -and $Item -isnot [string]) {
            return ,@($Item | ForEach-Object { ConvertTo-CanonicalValue $_ })
        }
        return $Item
    }
    return (ConvertTo-CanonicalValue $Value) | ConvertTo-Json -Depth 32
}

function Get-LifecycleBytesHash([byte[]] $Bytes) {
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

Export-ModuleMember -Function ConvertTo-CanonicalJson, Get-LifecycleBytesHash
