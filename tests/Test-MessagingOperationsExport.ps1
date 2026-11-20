<#
.SYNOPSIS
    Exercises the complete operations exporter with pinned GitHub protocol fixtures and Terraform outputs.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$temporaryParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$temporary = Join-Path $temporaryParent ('hexagon-operations-export-' + [guid]::NewGuid().ToString('N'))
function Save-Json($Value, [string] $Path) { [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false)) }
function Assert-True([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
$previousGh = Get-Item Function:global:gh -ErrorAction SilentlyContinue
try {
    New-Item -ItemType Directory -Path $temporary | Out-Null
    $global:HexagonOperationsTestSchema = [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'fixtures/backend/.hexagon/schemas/messaging-requirements-v1.schema.json'))
    function global:gh {
        param([string] $Command, [string] $Endpoint)
        if ($Command -cne 'api' -or $Endpoint -cnotmatch '^repos/ajunquit/hexagon-example-dotnet-ml/contents/(.+)\?ref=2222222222222222222222222222222222222222$') {
            throw 'Unexpected GitHub request in operations export test.'
        }
        $bytes = switch ($Matches[1]) {
            '.hexagon/messaging-requirements.json' { $global:HexagonOperationsTestManifest }
            '.hexagon/schemas/messaging-requirements-v1.schema.json' { $global:HexagonOperationsTestSchema }
            default { throw 'Unexpected GitHub fixture file.' }
        }
        $global:LASTEXITCODE = 0
        @{ type = 'file'; encoding = 'base64'; content = [Convert]::ToBase64String([byte[]] $bytes) } | ConvertTo-Json -Compress
    }
    # One fixture per provider of the repository: each template brings those of its cloud.
    $fixtures = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'fixtures/operations') -Filter '*.ps1' -File | Sort-Object Name)
    if ($fixtures.Count -eq 0) { throw 'No messaging operations export fixture.' }
    foreach ($fixture in $fixtures) {
        $provider = $fixture.BaseName
        $manifest = Get-Content -Raw (Join-Path $PSScriptRoot 'fixtures/backend/.hexagon/messaging-requirements.json') | ConvertFrom-Json
        $manifest.provider = $provider
        $global:HexagonOperationsTestManifest = [Text.Encoding]::UTF8.GetBytes(($manifest | ConvertTo-Json -Depth 30))
        $descriptor = Get-Content -Raw (Join-Path $root 'examples/product-environment.json') | ConvertFrom-Json
        $descriptor.components = @($descriptor.components | Where-Object name -CEQ backend)
        $descriptor.components[0].manifests[0].sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($global:HexagonOperationsTestManifest)).ToLowerInvariant()
        $topology = Get-Content -Raw (Join-Path $root "examples/$provider-policy.json") | ConvertFrom-Json
        $policy = Get-Content -Raw (Join-Path $root 'examples/messaging-operations-policy.json') | ConvertFrom-Json
        $policy.provider = $provider
        $mapping = @{ consumers = @{} }
        $outputs = & (& $fixture.FullName) $policy $topology $mapping
        $arguments = @{
            Descriptor = Join-Path $temporary 'descriptor.json'
            TopologyPolicy = Join-Path $temporary 'topology.json'
            Policy = Join-Path $temporary 'operations.json'
            TerraformOutputs = Join-Path $temporary 'outputs.json'
            OutputDirectory = Join-Path $temporary $provider
        }
        Save-Json $descriptor $arguments.Descriptor
        Save-Json $topology $arguments.TopologyPolicy
        Save-Json $policy $arguments.Policy
        Save-Json $outputs $arguments.TerraformOutputs
        & (Join-Path $root 'scripts/Export-MessagingOperations.ps1') @arguments
        $targetPath = Join-Path $arguments.OutputDirectory 'sales-worker.target.json'
        $target = Get-Content -Raw $targetPath | ConvertFrom-Json
        Assert-True ($target.provider -ceq $provider -and $target.replayEnabled -and $target.hasDeadLetter) 'Exporter lost provider or DLQ policy.'
        Assert-True ($target.eventTypes.Count -eq 1) 'Exporter lost allowed event types.'
        & (Join-Path $root 'scripts/Invoke-MessagingOperation.ps1') -Action Plan -Target $targetPath -Product hexagon-example -Environment dev -Consumer sales-worker
        $before = Get-Content -Raw $targetPath
        & (Join-Path $root 'scripts/Export-MessagingOperations.ps1') @arguments
        Assert-True ((Get-Content -Raw $targetPath) -ceq $before) 'Operation targets must be deterministic.'
        # A changed physical mapping must fail before writing any new artifact.
        $mapping.consumers['sales-worker'].name = 'unexpected-queue'
        Save-Json $outputs $arguments.TerraformOutputs
        $arguments.OutputDirectory = Join-Path $temporary "$provider-rejected"
        $rejected = $false
        try { & (Join-Path $root 'scripts/Export-MessagingOperations.ps1') @arguments }
        catch { $rejected = $_.Exception.Message -like '*Terraform consumer differs*' }
        Assert-True $rejected 'Unexpected physical mapping was accepted.'
        Assert-True (-not (Test-Path -LiteralPath $arguments.OutputDirectory)) 'Rejected mapping wrote partial artifacts.'
        $descriptor.components[0].manifests[0].sha256 = 'a' * 64
        Save-Json $descriptor $arguments.Descriptor
        $rejected = $false
        try { & (Join-Path $root 'scripts/Export-MessagingOperations.ps1') @arguments }
        catch { $rejected = $_.Exception.Message -like '*SHA-256 mismatch*' }
        Assert-True $rejected 'Manifest tampering was accepted.'
    }
}
finally {
    Remove-Item Function:global:gh -ErrorAction SilentlyContinue
    if ($previousGh) { Set-Item Function:global:gh $previousGh.ScriptBlock }
    Remove-Variable HexagonOperationsTestManifest, HexagonOperationsTestSchema -Scope Global -ErrorAction SilentlyContinue
    $resolved = [IO.Path]::GetFullPath($temporary)
    if ($resolved.StartsWith((Join-Path $temporaryParent 'hexagon-operations-export-'), [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
Write-Host 'Messaging operations export checks passed for all providers.'
