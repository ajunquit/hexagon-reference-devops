Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'EnvironmentLifecycle.psm1')
Import-Module (Join-Path $PSScriptRoot 'PlatformBootstrap.psm1')
Import-Module (Join-Path $PSScriptRoot 'LifecycleNative.psm1')

function Get-SnapshotHash([object] $Value) {
    $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-PlatformBootstrapJson $Value))
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Get-SnapshotRootPaths([string] $Id, [string] $Environment, [string] $Adapter = '') {
    # AWS roots (ADR 0025); Azure stays the default for the adapters that existed before.
    if ($Adapter -ceq 'AwsHosting' -and $Id -ceq 'hosting') { return @("terraform/environments/$Environment/hosting-aws", 'terraform/modules/hosting/aws') }
    if ($Adapter -ceq 'AwsSnsSqs' -and $Id -ceq 'messaging') { return @("terraform/environments/$Environment/aws", 'terraform/modules/messaging/aws-sns-sqs') }
    if ($Adapter -like 'Aws*') { throw 'lifecycle.snapshotRootUnknown' }
    if ($Id -ceq 'hosting') { return @("terraform/environments/$Environment/hosting-azure", 'terraform/modules/hosting/azure') }
    if ($Id -ceq 'messaging') { return @("terraform/environments/$Environment/azure", 'terraform/modules/messaging/azure-service-bus') }
    throw 'lifecycle.snapshotRootUnknown'
}

function Read-LifecycleGitFile([string] $Repository, [string] $Commit, [string] $Path) {
    $result = Invoke-LifecycleCommand git @('show', "$Commit`:$Path") $Repository -TimeoutSeconds 30
    if ($result.exitCode -ne 0) { throw 'lifecycle.snapshotSourceUnavailable' }
    return ,$result.bytes
}

function Assert-LifecycleGitSource([hashtable] $Inventory, [string] $Repository, [string] $TrustedCommit) {
    $origin = Invoke-LifecycleCommand git @('remote', 'get-url', 'origin') $Repository -TimeoutSeconds 30
    $name = $origin.text.Trim() -replace '^https://github[.]com/', '' -replace '^git@github[.]com:', '' -replace '[.]git$', ''
    if ($origin.exitCode -ne 0 -or $name -ine $Inventory.iac.repository -or $TrustedCommit -cnotmatch '^[0-9a-f]{40}$') { throw 'lifecycle.snapshotRepositoryMismatch' }
    $ancestor = Invoke-LifecycleCommand git @('merge-base', '--is-ancestor', $Inventory.iac.commit, $TrustedCommit) $Repository -TimeoutSeconds 30
    if ($ancestor.exitCode -ne 0) { throw 'lifecycle.snapshotCommitUntrusted' }
}

function Get-LifecycleConfigurationFiles([hashtable] $Inventory, [string] $Repository) {
    $prefixes = @($Inventory.roots | ForEach-Object { Get-SnapshotRootPaths $_.id $Inventory.environment $_.adapter } | Sort-Object -Unique)
    $result = Invoke-LifecycleCommand git (@('ls-tree', '-r', '--name-only', $Inventory.iac.commit, '--') + $prefixes) $Repository -TimeoutSeconds 30
    if ($result.exitCode -ne 0) { throw 'lifecycle.snapshotSourceUnavailable' }
    return @($result.text -split "`n" | Where-Object { $_ -match '[.]tf$|/[.]terraform[.]lock[.]hcl$' } | Sort-Object)
}

function Assert-LifecycleInputs([hashtable] $Inventory, [hashtable] $Root, [byte[]] $Bytes) {
    if ($Bytes.Length -gt 1048576) { throw 'lifecycle.snapshotInputsInvalid' }
    try { $text = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes); $value = $text | ConvertFrom-Json -AsHashtable -Depth 32 }
    catch { throw 'lifecycle.snapshotInputsInvalid' }
    # Azure inputs name their resource group; AWS inputs, the short prefix of the reservation (ADR 0025).
    $scoped = $(if ($Root.ContainsKey('namePrefix')) { $Root.id -ceq 'messaging' -and $Inventory.instance.kind -cne 'Ephemeral' -and -not $value.ContainsKey('name_prefix') -or $value.name_prefix -ceq $Root.namePrefix }
        else { $value.resource_group_name -ceq $Root.resourceGroup })
    if ($value.product -cne $Inventory.product -or $value.environment -cne $Inventory.environment -or -not $scoped -or
        $text -match '(?i)SharedAccessKey=|Password=|-----BEGIN [A-Z ]*PRIVATE KEY-----|"(?:client_secret|clientSecret|password|accessToken)"\s*:\s*"') { throw 'lifecycle.snapshotInputsInvalid' }
}

function New-LifecycleSnapshot {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([hashtable] $Inventory, [string] $Repository, [string] $TrustedCommit, [string] $InputDirectory, [string] $Archive)
    Assert-EnvironmentInventory $Inventory
    $Inventory = (ConvertTo-PlatformBootstrapJson $Inventory) | ConvertFrom-Json -AsHashtable -Depth 32
    Assert-LifecycleGitSource $Inventory $Repository $TrustedCommit
    $files = @{}; $contents = @{}; $roots = @{}
    foreach ($path in Get-LifecycleConfigurationFiles $Inventory $Repository) {
        $bytes = Read-LifecycleGitFile $Repository $Inventory.iac.commit $path
        $contents[$path] = $bytes; $files[$path] = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    }
    foreach ($root in $Inventory.roots) {
        $paths = Get-SnapshotRootPaths $root.id $Inventory.environment $root.adapter
        foreach ($name in @('main.tf', 'variables.tf', 'providers.tf', 'versions.tf', 'outputs.tf', '.terraform.lock.hcl')) {
            if (-not $files.ContainsKey("$($paths[0])/$name")) { throw 'lifecycle.snapshotConfigurationMissing' }
        }
        $map = @{}; foreach ($path in $files.Keys) { if (@($paths | Where-Object { $path.StartsWith("$_/", [StringComparison]::Ordinal) }).Count -gt 0) { $map[$path] = $files[$path] } }
        $inputPath = "inputs/$($root.id).tfvars.json"
        $bytes = [IO.File]::ReadAllBytes((Join-Path $InputDirectory "$($root.id).tfvars.json"))
        Assert-LifecycleInputs $Inventory $root $bytes
        $contents[$inputPath] = $bytes; $files[$inputPath] = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        $root.configurationSha256 = Get-SnapshotHash $map; $root.inputsSha256 = $files[$inputPath]
        $roots[$root.id] = @{ directory = $paths[0]; inputs = $inputPath; configurationSha256 = $root.configurationSha256; inputsSha256 = $root.inputsSha256 }
    }
    $version = Invoke-LifecycleCommand terraform @('version', '-json') -TimeoutSeconds 30
    if ($version.exitCode -ne 0) { throw 'lifecycle.terraformVersionUnavailable' }
    $terraformVersion = ($version.text | ConvertFrom-Json).terraform_version
    if ([version] $terraformVersion -lt [version] '1.10.0' -or [version] $terraformVersion -ge [version] '2.0.0') { throw 'lifecycle.snapshotToolchainUnsupported' }
    $manifest = @{ apiVersion = 'hexagon.ec/environment-snapshot/v1'; repository = $Inventory.iac.repository; commit = $Inventory.iac.commit
        terraformVersion = $terraformVersion; files = $files; roots = $roots }
    $contents['manifest.json'] = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-PlatformBootstrapJson $manifest))
    if (-not $PSCmdlet.ShouldProcess($Archive, 'Create immutable lifecycle snapshot')) { return }
    $stream = [IO.File]::Open($Archive, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
    try {
        foreach ($name in @($contents.Keys | Sort-Object -CaseSensitive)) {
            $entry = $zip.CreateEntry($name); $entry.LastWriteTime = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
            $output = $entry.Open(); try { $output.Write($contents[$name]) } finally { $output.Dispose() }
        }
    }
    finally { $zip.Dispose(); $stream.Dispose() }
    $Inventory.iac.snapshotSha256 = Get-LifecycleFileHash $Archive
    return $Inventory
}

function Read-LifecycleSnapshot {
    param([hashtable] $Inventory, [string] $Archive, [string] $Repository, [string] $TrustedCommit)
    if ((Get-Item -LiteralPath $Archive).Length -gt 33554432 -or (Get-LifecycleFileHash $Archive) -cne $Inventory.iac.snapshotSha256) { throw 'lifecycle.snapshotHashMismatch' }
    Assert-LifecycleGitSource $Inventory $Repository $TrustedCommit
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    $files = @{}; $length = 0L
    try {
        if ($zip.Entries.Count -gt 2000) { throw 'lifecycle.snapshotTooLarge' }
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName
            if ($name -cnotmatch '^(manifest[.]json|inputs/(hosting|messaging)[.]tfvars[.]json|terraform/[A-Za-z0-9_./-]+)$' -or $name -match '(?:^|/)[.][.]?(?:/|$)|\\|:' -or
                $files.ContainsKey($name) -or (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000 -or $entry.Length -gt 8388608) { throw 'lifecycle.snapshotEntryInvalid' }
            $length += $entry.Length; if ($length -gt 67108864) { throw 'lifecycle.snapshotTooLarge' }
            $source = $entry.Open(); $memory = [IO.MemoryStream]::new()
            try {
                $buffer = [byte[]]::new(65536)
                while (($count = $source.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $memory.Write($buffer, 0, $count)
                    if ($memory.Length -gt 8388608 -or $memory.Length -gt $entry.Length) { throw 'lifecycle.snapshotTooLarge' }
                }
                if ($memory.Length -ne $entry.Length) { throw 'lifecycle.snapshotEntryInvalid' }
                $files[$name] = $memory.ToArray()
            } finally { $source.Dispose(); $memory.Dispose() }
        }
    }
    finally { $zip.Dispose() }
    if (-not $files.ContainsKey('manifest.json')) { throw 'lifecycle.snapshotManifestMissing' }
    try { $manifest = [Text.Encoding]::UTF8.GetString($files['manifest.json']) | ConvertFrom-Json -AsHashtable -Depth 32 }
    catch { throw 'lifecycle.snapshotManifestInvalid' }
    $schema = Join-Path (Split-Path -Parent $PSScriptRoot) 'contracts/schemas/environment-snapshot-v1.schema.json'
    if (-not ((ConvertTo-PlatformBootstrapJson $manifest) | Test-Json -SchemaFile $schema -ErrorAction SilentlyContinue) -or
        $manifest.repository -cne $Inventory.iac.repository -or $manifest.commit -cne $Inventory.iac.commit -or $files.Count -ne $manifest.files.Count + 1) { throw 'lifecycle.snapshotManifestInvalid' }
    $expected = @(Get-LifecycleConfigurationFiles $Inventory $Repository)
    foreach ($name in $manifest.files.Keys) {
        if (-not $files.ContainsKey($name) -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($files[$name])).ToLowerInvariant() -cne $manifest.files[$name]) { throw 'lifecycle.snapshotFileChanged' }
        if ($name.StartsWith('terraform/', [StringComparison]::Ordinal)) {
            if ($expected -cnotcontains $name) { throw 'lifecycle.snapshotSourceUnexpected' }
            $trusted = Read-LifecycleGitFile $Repository $Inventory.iac.commit $name
            if ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($trusted)).ToLowerInvariant() -cne $manifest.files[$name]) { throw 'lifecycle.snapshotSourceChanged' }
        }
    }
    foreach ($name in $expected) { if (-not $manifest.files.ContainsKey($name)) { throw 'lifecycle.snapshotConfigurationMissing' } }
    if ($manifest.roots.Count -ne $Inventory.roots.Count) { throw 'lifecycle.snapshotRootMismatch' }
    foreach ($root in $Inventory.roots) {
        $paths = Get-SnapshotRootPaths $root.id $Inventory.environment $root.adapter
        $map = @{}; foreach ($name in $expected) { if (@($paths | Where-Object { $name.StartsWith("$_/", [StringComparison]::Ordinal) }).Count -gt 0) { $map[$name] = $manifest.files[$name] } }
        $entry = $manifest.roots[$root.id]
        if ($entry.directory -cne $paths[0] -or $entry.inputs -cne "inputs/$($root.id).tfvars.json" -or $entry.configurationSha256 -cne $root.configurationSha256 -or
            (Get-SnapshotHash $map) -cne $root.configurationSha256 -or $entry.inputsSha256 -cne $root.inputsSha256 -or $manifest.files[$entry.inputs] -cne $root.inputsSha256) { throw 'lifecycle.snapshotRootMismatch' }
        Assert-LifecycleInputs $Inventory $root $files[$entry.inputs]
    }
    return @{ manifest = $manifest; files = $files }
}

function Expand-LifecycleSnapshot {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([hashtable] $Snapshot, [string] $Destination)
    if (Test-Path -LiteralPath $Destination) { throw 'lifecycle.snapshotDestinationExists' }
    if (-not $PSCmdlet.ShouldProcess($Destination, 'Extract verified lifecycle snapshot')) { return }
    [IO.Directory]::CreateDirectory($Destination) | Out-Null
    foreach ($name in $Snapshot.files.Keys) {
        if ($name -cnotmatch '^(manifest[.]json|inputs/(hosting|messaging)[.]tfvars[.]json|terraform/[A-Za-z0-9_./-]+)$' -or $name -match '(?:^|/)[.][.]?(?:/|$)|\\|:') { throw 'lifecycle.snapshotEntryInvalid' }
        $path = Join-Path $Destination $name
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)) | Out-Null
        [IO.File]::WriteAllBytes($path, $Snapshot.files[$name])
    }
}

Export-ModuleMember -Function New-LifecycleSnapshot, Read-LifecycleSnapshot, Expand-LifecycleSnapshot, Get-SnapshotHash, Get-SnapshotRootPaths
