Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Contracts with a variant per cloud (docs/separacion-por-nube.md). The neutral schema lives in
# contracts/schemas/<contract>.schema.json and names each cloud slot as a definition that starts with
# "cloud". Each <cloud>-<contract>.variant.json next to it narrows every slot for its cloud. Test-Json does
# not resolve external references, so this module composes one schema in memory: a slot accepts the
# variant of any cloud of the repository, each one being the neutral definition plus the narrowing of
# that cloud, with no property that neither of them evaluates. Without any variant, a slot accepts nothing.
$script:directory = Join-Path (Split-Path -Parent $PSScriptRoot) 'contracts/schemas'
$script:schemas = @{}

function Read-ContractJson([string] $Path) {
    return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -AsHashtable -Depth 64
}

function Get-ContractSchema {
    param([Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]*-v[1-9][0-9]*$')][string] $Contract)
    if ($script:schemas.ContainsKey($Contract)) { return $script:schemas[$Contract] }
    $schema = Read-ContractJson (Join-Path $script:directory "$Contract.schema.json")
    $definitions = $(if ($schema.ContainsKey('$defs')) { $schema['$defs'] } else { @{} })
    $slots = @($definitions.Keys | Where-Object { $_ -cmatch '^cloud[A-Z][A-Za-z]*$' } | Sort-Object)
    $variants = @{}; foreach ($slot in $slots) { $variants[$slot] = [Collections.Generic.List[object]]::new() }
    foreach ($file in @(Get-ChildItem -LiteralPath $script:directory -Filter "*-$Contract.variant.json" -File | Sort-Object Name)) {
        $variant = Read-ContractJson $file.FullName
        $narrowed = @($variant['$defs'].Keys | Sort-Object)
        if (($narrowed -join ',') -cne ($slots -join ',')) { throw "contract.variantIncomplete: $($file.Name)" }
        foreach ($slot in $slots) {
            $neutral = (ConvertTo-Json -InputObject $definitions[$slot] -Depth 64) | ConvertFrom-Json -AsHashtable -Depth 64
            $variants[$slot].Add(@{ allOf = @($neutral, $variant['$defs'][$slot]); unevaluatedProperties = $false })
        }
    }
    foreach ($slot in $slots) {
        $definitions[$slot] = $(if ($variants[$slot].Count -eq 0) { $false } else { @{ anyOf = $variants[$slot].ToArray() } })
    }
    $script:schemas[$Contract] = ConvertTo-Json -InputObject $schema -Depth 64 -Compress
    return $script:schemas[$Contract]
}

function Test-ContractJson {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Json, [Parameter(Mandatory)][string] $Contract)
    return [bool] ($Json | Test-Json -Schema (Get-ContractSchema $Contract) -ErrorAction SilentlyContinue)
}

Export-ModuleMember -Function Get-ContractSchema, Test-ContractJson
