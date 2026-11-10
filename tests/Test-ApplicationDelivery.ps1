<#
.SYNOPSIS
    Tests CI provenance, byte-preserving OCI delivery, durable job recovery and activation gates.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
foreach ($name in @('AzureApplicationDelivery', 'ApplicationArtifacts', 'AzureOciDelivery', 'AzureMaintenanceDelivery', 'AzureEnvironmentStore', 'PlatformBootstrap', 'EnvironmentSnapshot', 'EnvironmentLifecycle')) {
    Import-Module (Join-Path $repository "scripts/$name.psm1")
}
if (-not ('Hexagon.DeliveryTests.DeliveryHttpHandler' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'DeliveryHttpHandler.cs') }
if (-not ('Hexagon.LifecycleTests.LifecycleHttpHandler' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'LifecycleHttpHandler.cs') }
$parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
$temporary = Join-Path $parent "hexagon-delivery-tests-$([guid]::NewGuid().ToString('N'))"
[IO.Directory]::CreateDirectory($temporary) | Out-Null
$script:assertions = 0
function Assert-True([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message }; $script:assertions++ }
function Assert-Rejected([scriptblock] $Action, [string] $Code) {
    try { & $Action | Out-Null } catch { Assert-True ($_.Exception.Message -like "*$Code*") "Unexpected rejection: $($_.Exception.Message)"; return }
    throw "Expected rejection: $Code"
}
function Bytes([string] $Value) { return ,[Text.Encoding]::UTF8.GetBytes($Value) }
function Copy-Value([object] $Value) { return (ConvertTo-PlatformBootstrapJson $Value) | ConvertFrom-Json -AsHashtable -Depth 50 }
function Write-Json([string] $Path, [object] $Value) { [IO.File]::WriteAllText($Path, (ConvertTo-PlatformBootstrapJson $Value) + "`n") }
function Write-Tar([string] $Path, [hashtable] $Files) {
    $stream = [IO.File]::Create($Path); $writer = [System.Formats.Tar.TarWriter]::new($stream)
    try {
        foreach ($key in $Files.Keys) {
            $entry = [System.Formats.Tar.PaxTarEntry]::new([System.Formats.Tar.TarEntryType]::RegularFile, $key)
            $entry.DataStream = [IO.MemoryStream]::new([byte[]] $Files[$key])
            try { $writer.WriteEntry($entry) } finally { $entry.DataStream.Dispose() }
        }
    } finally { $writer.Dispose(); $stream.Dispose() }
}
function Write-Zip([string] $Path, [hashtable] $Files) {
    $zip = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
    try { foreach ($key in $Files.Keys) { $stream = $zip.CreateEntry($key).Open(); try { $stream.Write($Files[$key]) } finally { $stream.Dispose() } } }
    finally { $zip.Dispose() }
}
function Get-Template([hashtable] $Expected, [string] $Marker = '') {
    $environment = @{} + $Expected.environment
    if ($Marker) { $environment['HEXAGON_DELIVERY_ATTEMPT'] = $Marker }
    return @{ containers = @(@{ name = $Expected.name; image = $Expected.image; args = $Expected.args; resources = @{ cpu = 0.5; memory = '1Gi' }
                env = @($environment.GetEnumerator() | ForEach-Object { @{ name = $_.Key; value = $_.Value } }) }) }
}
$savedEnvironment = @{}
foreach ($key in @('GH_TOKEN', 'HEXAGON_ARTIFACTS_READ_TOKEN', 'GITHUB_REPOSITORY', 'GITHUB_ACTIONS', 'GITHUB_REF', 'GITHUB_EVENT_NAME', 'GITHUB_WORKFLOW_REF')) { $savedEnvironment[$key] = [Environment]::GetEnvironmentVariable($key) }
$artifactsModule = Get-Module ApplicationArtifacts; $registryModule = Get-Module AzureOciDelivery
$maintenanceModule = Get-Module AzureMaintenanceDelivery; $storeModule = Get-Module AzureEnvironmentStore; $deliveryModule = Get-Module AzureApplicationDelivery
try {
    $release = Get-Content -Raw -LiteralPath (Join-Path $repository 'examples/application-release.json') | ConvertFrom-Json -AsHashtable
    $delivery = @{ apiVersion = 'hexagon.ec/application-delivery/v1'; releaseSha256 = 'a' * 64; candidates = @{} }
    foreach ($component in @('backend', 'web', 'devops')) { $delivery.candidates[$component] = @{ runId = 11; runAttempt = 2; artifactId = 21; archiveSha256 = 'b' * 64 } }
    Assert-ApplicationDelivery $delivery ('a' * 64)
    $bad = Copy-Value $delivery; $bad.candidates.web.command = 'forbidden'
    Assert-Rejected { Assert-ApplicationDelivery $bad ('a' * 64) } 'definitionInvalid'
    Assert-Rejected { Assert-ApplicationDelivery $delivery ('c' * 64) } 'definitionInvalid'
    $run = @{ id = 11; run_attempt = 2; status = 'completed'; conclusion = 'success'; event = 'push'; path = '.github/workflows/ci.yml'; head_branch = 'main'; head_sha = 'a' * 40; repository = @{ full_name = 'owner/backend'; id = 1 }; head_repository = @{ id = 1 } }
    $artifact = @{ id = 21; name = "backend-$('a' * 40)-11-2"; expired = $false; size_in_bytes = 100; digest = "sha256:$('b' * 64)"; workflow_run = @{ id = 11; repository_id = 1; head_repository_id = 1; head_branch = 'main'; head_sha = 'a' * 40 } }
    Assert-DeliveryGithubEvidence $delivery.candidates.backend $run $artifact 'owner/backend' ('a' * 40) backend
    foreach ($pair in @(@('conclusion', 'cancelled'), @('status', 'in_progress'), @('event', 'pull_request'), @('head_branch', 'other'), @('run_attempt', 1), @('path', '.github/workflows/untrusted.yml'))) {
        $bad = Copy-Value $run; $bad[$pair[0]] = $pair[1]
        Assert-Rejected { Assert-DeliveryGithubEvidence $delivery.candidates.backend $bad $artifact 'owner/backend' ('a' * 40) backend } 'candidateUntrusted'
    }
    $bad = Copy-Value $artifact; $bad.expired = $true
    Assert-Rejected { Assert-DeliveryGithubEvidence $delivery.candidates.backend $run $bad 'owner/backend' ('a' * 40) backend } 'candidateUntrusted'
    $bad = Copy-Value $artifact; $bad.workflow_run.head_repository_id = 99
    Assert-Rejected { Assert-DeliveryGithubEvidence $delivery.candidates.backend $run $bad 'owner/backend' ('a' * 40) backend } 'candidateUntrusted'
    foreach ($name in @('../outside', '/absolute', 'folder/file')) {
        if ($name -ceq 'build.json') { continue }
        $zip = Join-Path $temporary "$([guid]::NewGuid().ToString('N')).zip"
        $files = @{ 'build.json' = Bytes '{}' }; $files[$name] = Bytes '{}'
        Write-Zip $zip $files
        Assert-Rejected { Expand-DeliveryCandidate $zip (Join-Path $temporary ([guid]::NewGuid().ToString('N'))) } 'candidateEntryInvalid'
    }
    $zip = Join-Path $temporary 'link.zip'
    $writer = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
    $entry = $writer.CreateEntry('build.json'); $entry.ExternalAttributes = -1577058304; $writer.Dispose()
    Assert-Rejected { Expand-DeliveryCandidate $zip (Join-Path $temporary 'linked') } 'candidateEntryInvalid'
    $zip = Join-Path $temporary 'duplicate.zip'
    $writer = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
    [void] $writer.CreateEntry('build.json'); [void] $writer.CreateEntry('BUILD.json'); $writer.Dispose()
    Assert-Rejected { Expand-DeliveryCandidate $zip (Join-Path $temporary 'duplicates') } 'candidateEntryInvalid'

    # Actual disposable archives are validated and copied through the real HTTP adapters.
    $config = Bytes '{"os":"linux","architecture":"amd64","config":{"User":"app"}}'; $configHash = Get-LifecycleBytesHash $config
    $layer = Bytes 'fixture-image-layer'; $layerHash = Get-LifecycleBytesHash $layer
    $manifest = Bytes (ConvertTo-Json @{ schemaVersion = 2; config = @{ digest = "sha256:$configHash"; size = $config.Length }; layers = @(@{ digest = "sha256:$layerHash"; size = $layer.Length }) } -Depth 8 -Compress)
    $manifestHash = Get-LifecycleBytesHash $manifest
    $index = Bytes (ConvertTo-Json @{ schemaVersion = 2; manifests = @(@{ mediaType = 'application/vnd.oci.image.manifest.v1+json'; digest = "sha256:$manifestHash"; size = $manifest.Length }) } -Depth 8 -Compress)
    $ociPath = Join-Path $temporary 'image.oci.tar'
    Write-Tar $ociPath @{ 'oci-layout' = Bytes '{"imageLayoutVersion":"1.0.0"}'; 'index.json' = $index; "blobs/sha256/$configHash" = $config; "blobs/sha256/$layerHash" = $layer; "blobs/sha256/$manifestHash" = $manifest }
    $webPath = Join-Path $temporary 'web.tar.gz'
    $plainWeb = Join-Path $temporary 'web.tar'; Write-Tar $plainWeb @{ 'index.html' = Bytes '<html>fixture</html>' }
    $file = [IO.File]::Create($webPath); $gzip = [IO.Compression.GZipStream]::new($file, [IO.Compression.CompressionLevel]::Fastest)
    try { $gzip.Write([IO.File]::ReadAllBytes($plainWeb)) } finally { $gzip.Dispose(); $file.Dispose() }
    $release.artifacts.backend = @{ 'example-api' = "source.example.test/product/api@sha256:$manifestHash" }
    $release.artifacts.databaseBootstrap.image = "source.example.test/database-bootstrap@sha256:$manifestHash"
    $release.artifacts.web.sha256 = Get-LifecycleFileHash $webPath
    $handler = [Hexagon.DeliveryTests.DeliveryHttpHandler]::new()
    & $artifactsModule { param($h) $script:deliveryHandler = $h; function script:New-DeliveryHttpClient { return [Net.Http.HttpClient]::new($script:deliveryHandler, $false) } } $handler
    $counter = 100
    foreach ($component in @('backend', 'web', 'devops')) {
        $counter++
        $source = $(if ($component -ceq 'devops') { $release.artifacts.databaseBootstrap } else { @($release.sources | Where-Object name -CEQ $component)[0] })
        $build = @{ apiVersion = 'hexagon.ec/component-build/v1'; kind = 'ComponentBuild'; product = $release.product; repository = $source.repository; commit = $source.commit; component = $component
            manifests = @($(if ($component -ceq 'devops') { @() } else { $source.manifests })); dependencies = @(); artifacts = @() }
        if ($component -ceq 'web') {
            $build.artifacts = @(@{ id = 'web'; kind = 'static-bundle'; file = 'web.tar.gz'; sha256 = $release.artifacts.web.sha256 })
            $files = @{ 'web.tar.gz' = [IO.File]::ReadAllBytes($webPath) }
        }
        else {
            $id = $(if ($component -ceq 'backend') { 'example-api' } else { 'database-bootstrap' })
            $build.artifacts = @(@{ id = $id; kind = 'oci-image'; file = 'image.oci.tar'; sha256 = Get-LifecycleFileHash $ociPath; imageDigest = "sha256:$manifestHash"; platform = 'linux/amd64' })
            $files = @{ 'image.oci.tar' = [IO.File]::ReadAllBytes($ociPath) }
            if ($component -ceq 'backend') { $build.dependencies = @(@{ repository = 'owner/hexagon-core-dotnet'; commit = 'c' * 40; version = '1.0.0-dev.1'; packages = @(@{ id = 'Hexagon.Core.Domain'; sha256 = 'd' * 64 }) }); $files['artifacts.json'] = Bytes '{}' }
        }
        $files['build.json'] = Bytes (ConvertTo-PlatformBootstrapJson $build)
        $zip = Join-Path $temporary "$component.zip"; Write-Zip $zip $files
        $candidate = @{ runId = $counter; runAttempt = 1; artifactId = $counter + 100; archiveSha256 = Get-LifecycleFileHash $zip }; $delivery.candidates[$component] = $candidate
        $prefix = $(if ($component -ceq 'devops') { 'operations' } else { $component })
        $run = @{ id = $candidate.runId; run_attempt = 1; status = 'completed'; conclusion = 'success'; event = 'workflow_dispatch'; path = '.github/workflows/ci.yml'; head_branch = 'main'; head_sha = $source.commit; repository = @{ full_name = $source.repository; id = $counter }; head_repository = @{ id = $counter } }
        $artifact = @{ id = $candidate.artifactId; name = "$prefix-$($source.commit)-$counter-1"; expired = $false; size_in_bytes = (Get-Item $zip).Length; digest = "sha256:$($candidate.archiveSha256)"; workflow_run = @{ id = $counter; repository_id = $counter; head_repository_id = $counter; head_branch = 'main'; head_sha = $source.commit } }
        $base = "https://api.github.com/repos/$($source.repository)/actions"
        $handler.Route('GET', "$base/runs/$counter/attempts/1", 200, (Bytes (ConvertTo-PlatformBootstrapJson $run)))
        $handler.Route('GET', "$base/artifacts/$($candidate.artifactId)", 200, (Bytes (ConvertTo-PlatformBootstrapJson $artifact)))
        $handler.Route('GET', "$base/artifacts/$($candidate.artifactId)/zip", 302, (Bytes ''))
        $handler.Header('GET', "$base/artifacts/$($candidate.artifactId)/zip", 'Location', "https://fixture.blob.core.windows.net/download/$component.zip?signature=fixture")
        $handler.Route('GET', "https://fixture.blob.core.windows.net/download/$component.zip?signature=fixture", 200, [IO.File]::ReadAllBytes($zip))
    }
    $env:GH_TOKEN = 'fixture-local-token'; $env:HEXAGON_ARTIFACTS_READ_TOKEN = 'fixture-cross-repository-token'; $env:GITHUB_REPOSITORY = $release.artifacts.databaseBootstrap.repository
    $components = Receive-ApplicationCandidates $delivery $release 'fixture123.azurecr.io' (Join-Path $temporary 'received') -Confirm:$false
    $webOnly = Receive-ApplicationCandidates $delivery $release 'fixture123.azurecr.io' (Join-Path $temporary 'web-only') -ComponentNames web -Confirm:$false
    Assert-True ($webOnly.Count -eq 1 -and $webOnly.ContainsKey('web')) 'Web publication required backend/operations candidates again.'
    Assert-True ($components.Count -eq 3 -and $components.backend.images['example-api'].target.digest -ceq "sha256:$manifestHash") 'Candidate retrieval lost the verified image identity.'
    for ($i = 0; $i -lt $handler.Requests.Count; $i++) {
        if ($handler.Requests[$i] -like '*fixture.blob*') { Assert-True (-not $handler.Headers[$i].ContainsKey('Authorization')) 'GitHub credential followed the signed redirect.' }
    }
    $handler.Route('GET', 'https://fixture.blob.core.windows.net/download/backend.zip?signature=fixture', 200, (Bytes 'tampered-download'))
    Assert-Rejected { Receive-ApplicationCandidates $delivery $release 'fixture123.azurecr.io' (Join-Path $temporary 'tampered-download') -Confirm:$false } 'archiveMismatch'
    $handler.Route('GET', 'https://fixture.blob.core.windows.net/download/backend.zip?signature=fixture', 200, [IO.File]::ReadAllBytes((Join-Path $temporary 'backend.zip')))
    $downloadUri = "https://api.github.com/repos/$($release.sources[1].repository)/actions/artifacts/$($delivery.candidates.backend.artifactId)/zip"
    $handler.Header('GET', $downloadUri, 'Location', 'https://foreign.example.test/archive.zip')
    Assert-Rejected { Receive-ApplicationCandidates $delivery $release 'fixture123.azurecr.io' (Join-Path $temporary 'foreign-download') -Confirm:$false } 'archiveRedirectInvalid'
    Assert-True (@($handler.Requests | Where-Object { $_ -like '*foreign.example.test*' }).Count -eq 0) 'Untrusted archive host was requested.'
    $handler.Header('GET', $downloadUri, 'Location', 'https://fixture.blob.core.windows.net/download/backend.zip?signature=fixture')
    $bad = Copy-Value $release; $bad.sources[0].manifests[0].sha256 = 'f' * 64
    Assert-Rejected { Test-DeliveryComponent $components.web.directory $bad web 'fixture123.azurecr.io' } 'manifestMismatch'
    $bad = Copy-Value $release; $bad.artifacts.backend['example-api'] = "source.example.test/product/api@sha256:$('0' * 64)"
    Assert-Rejected { Test-DeliveryComponent $components.backend.directory $bad backend 'fixture123.azurecr.io' } 'imageMismatch'
    $bad = Copy-Value $release; $bad.artifacts.web.sha256 = '0' * 64
    Assert-Rejected { Test-DeliveryComponent $components.web.directory $bad web 'fixture123.azurecr.io' } 'webMismatch'

    $inventory = Get-Content -Raw -LiteralPath (Join-Path $repository 'examples/environment-inventory.json') | ConvertFrom-Json -AsHashtable
    $context = @{ inventory = $inventory; prefix = "$($inventory.product)/$($inventory.environment)/$($inventory.instance.id)"; runtime = $temporary; tokens = @{}; leaseId = $null }
    $blobHandler = [Hexagon.LifecycleTests.LifecycleHttpHandler]::new()
    & $storeModule { param($h) $script:deliveryBlobHandler = $h; function script:New-AzureLifecycleHttpClient { return [Net.Http.HttpClient]::new($script:deliveryBlobHandler, $false) }; function script:Get-LifecycleAzureToken { return 'fixture-azure-token' } } $blobHandler
    Enter-AzureLifecycleLease $context -Confirm:$false
    & $registryModule { param($h) $script:deliveryRegistryHandler = $h; function script:New-AcrDeliveryHttpClient { return [Net.Http.HttpClient]::new($script:deliveryRegistryHandler, $false) }
        function script:Invoke-LifecycleCommand { return @{ exitCode = 0; text = '{"loginServer":"fixture123.azurecr.io","accessToken":"fixture-refresh"}' } } } $handler
    $copied = Publish-AzureOciArchive $context $components.backend.images['example-api'] 'fixture123.azurecr.io' -Confirm:$false
    Assert-True ($copied.digest -ceq "sha256:$manifestHash" -and (Get-LifecycleBytesHash $handler.RegistryManifests["/v2/product/api/manifests/sha256:$manifestHash"]) -ceq $manifestHash) 'Registry copy changed OCI manifest bytes.'
    Assert-True ((Get-LifecycleBytesHash $handler.RegistryBlobs["/v2/product/api/blobs/sha256:$layerHash"]) -ceq $layerHash) 'Registry copy changed layer bytes.'
    $before = $handler.UploadedBodies.Count
    Publish-AzureOciArchive $context $components.backend.images['example-api'] 'fixture123.azurecr.io' -Confirm:$false | Out-Null
    Assert-True ($handler.UploadedBodies.Count -eq $before + 1) 'Idempotent copy uploaded existing blobs again.'
    $handler.CorruptDigest = $true
    Assert-Rejected { Assert-AzureOciImages $context @{ api = $components.backend.images['example-api'].target } 'fixture123.azurecr.io' } 'registryDigestMismatch'
    $handler.CorruptDigest = $false; $handler.RegistryBlobs.Clear(); $handler.UploadLocation = 'https://other.example.test/receive'
    Assert-Rejected { Publish-AzureOciArchive $context $components.backend.images['example-api'] 'fixture123.azurecr.io' -Confirm:$false } 'registryUploadEndpointInvalid'
    Assert-True (@($handler.Requests | Where-Object { $_ -like '*other.example.test*' }).Count -eq 0) 'Registry token was sent to a foreign upload host.'

    # Durable CAS rejects concurrent or foreign evidence; no success is inferred from a write response.
    $journal = Read-AzureDeliveryJournal $context ('a' * 64)
    Save-AzureDeliveryJournal $context $journal -Confirm:$false
    Assert-True ($journal.revision -eq 0 -and $context.deliveryRevision -eq 0) 'First delivery checkpoint was not read back.'
    $foreign = Copy-Value $journal; $foreign.instanceId = 'run-999-1'
    Assert-Rejected { Assert-AzureDeliveryJournal $context $foreign ('a' * 64) } 'journalInvalid'
    $stale = Copy-Value $context
    $journal.images = @{ 'example-api' = $copied }; Save-AzureDeliveryJournal $context $journal -Confirm:$false
    $staleJournal = Copy-Value $journal; $staleJournal.revision = 0
    Assert-Rejected { Save-AzureDeliveryJournal $stale $staleJournal -Confirm:$false } 'journalConflict'
    Assert-Rejected { Read-AzureDeliveryJournal $context ('f' * 64) } 'journalInvalid'

    $jobId = "/subscriptions/$($inventory.target.subscriptionId)/resourceGroups/$($inventory.roots[0].resourceGroup)/providers/Microsoft.App/jobs/example-migrations"
    $expected = @{ name = 'maintenance'; image = $copied.image; args = @('--migrate-only'); environment = @{ AZURE_CLIENT_ID = 'fixture-public-id' }; cpu = 0.5; memory = '1Gi' }
    $job = @{ id = $jobId; properties = @{ configuration = @{ triggerType = 'Manual'; replicaRetryLimit = 0; replicaTimeout = 1800 }; template = Get-Template $expected } }
    $blobHandler.Route('GET', "https://management.azure.com${jobId}?api-version=2024-03-01", 200, (ConvertTo-PlatformBootstrapJson $job))
    $jobFixture = @{ handler = $blobHandler; id = $jobId; context = $context; expected = $expected; starts = 0; saved = $null; failStart = $false; publishExecution = $true }
    & $maintenanceModule { param($fixture) $script:jobFixture = $fixture
        function script:Invoke-LifecycleCommand {
            param($Tool, $Arguments)
            $script:jobFixture.starts++
            if ($script:jobFixture.ContainsKey('deliveryPath')) {
                $remote = [Text.Encoding]::UTF8.GetString($script:jobFixture.handler.Blobs[$script:jobFixture.deliveryPath]) | ConvertFrom-Json -AsHashtable -Depth 24
                if ($remote.jobs.migrations.status -cne 'Starting') { throw 'Real delivery intent was not durable before start.' }
            }
            elseif ($null -eq $script:jobFixture.saved -or $script:jobFixture.saved.status -cne 'Starting') { throw 'Intent was not durable before start.' }
            $body = $Arguments[[array]::IndexOf($Arguments, '--body') + 1].Substring(1)
            $template = Get-Content -Raw -LiteralPath $body | ConvertFrom-Json -AsHashtable -Depth 32
            if ($script:jobFixture.publishExecution) {
                $execution = @{ id = "$($script:jobFixture.id)/executions/fixture-execution"; name = 'fixture-execution'; properties = @{ status = 'Succeeded'; template = $template } }
                $script:jobFixture.handler.Route('GET', "https://management.azure.com$($script:jobFixture.id)/executions?api-version=2024-03-01", 200, (ConvertTo-PlatformBootstrapJson @{ value = @($execution) }))
                $script:jobFixture.handler.Route('GET', "https://management.azure.com$($execution.id)?api-version=2024-03-01", 200, (ConvertTo-PlatformBootstrapJson $execution))
            }
            return @{ exitCode = $(if ($script:jobFixture.failStart) { 1 } else { 0 }); text = '{}' }
        }
    } $jobFixture
    $persist = { param($record) $jobFixture.saved = Copy-Value $record }
    $result = Invoke-AzureDeliveryMaintenance $context $jobId $expected $null $persist -TimeoutSeconds 0 -PollSeconds 0 -Confirm:$false
    Assert-True ($result.status -ceq 'Succeeded' -and $jobFixture.starts -eq 1 -and $jobFixture.saved.status -ceq 'Succeeded') 'Job did not prove its successful recorded execution.'
    Invoke-AzureDeliveryMaintenance $context $jobId $expected $jobFixture.saved $persist -TimeoutSeconds 0 -PollSeconds 0 -Confirm:$false | Out-Null
    Assert-True ($jobFixture.starts -eq 1) 'A completed job was started again.'
    $jobFixture.saved = $null; $jobFixture.failStart = $true
    Assert-Rejected { Invoke-AzureDeliveryMaintenance $context $jobId $expected $null $persist -TimeoutSeconds 0 -Confirm:$false } 'jobStartUncertain'
    $attempt = $jobFixture.saved.attemptId
    $result = Invoke-AzureDeliveryMaintenance $context $jobId $expected $jobFixture.saved $persist -TimeoutSeconds 0 -Confirm:$false
    Assert-True ($result.attemptId -ceq $attempt -and $jobFixture.starts -eq 2) 'Recovery failed to adopt the exact execution after an ambiguous POST.'
    $jobFixture.saved = $null; $jobFixture.failStart = $false; $jobFixture.publishExecution = $false
    Assert-Rejected { Invoke-AzureDeliveryMaintenance $context $jobId $expected $null $persist -TimeoutSeconds 0 -Confirm:$false } 'executionPending'
    Assert-Rejected { Invoke-AzureDeliveryMaintenance $context $jobId $expected $jobFixture.saved $persist -TimeoutSeconds 0 -Confirm:$false } 'executionPending'
    Assert-True ($jobFixture.starts -eq 3) 'Missing ambiguous execution caused another POST.'
    $failed = Copy-Value $jobFixture.saved; $failed.status = 'Failed'
    Assert-Rejected { Invoke-AzureDeliveryMaintenance $context $jobId $expected $failed $persist -TimeoutSeconds 0 -Confirm:$false } 'failedExecutionRequiresInvestigation'
    $bad = Copy-Value $expected; $bad.image = "fixture123.azurecr.io/product/api@sha256:$('f' * 64)"
    Assert-Rejected { Invoke-AzureDeliveryMaintenance $context $jobId $bad $jobFixture.saved $persist -TimeoutSeconds 0 -Confirm:$false } 'jobTemplateChanged'
    $badTemplate = Get-Template $expected; $badTemplate.containers[0].command = @('/bin/sh')
    Assert-Rejected { Assert-DeliveryJobTemplate $badTemplate $expected '' } 'jobTemplateInvalid'

    # The native job-spec adapter checks the actual recorded identity and expected AAD bindings.
    $identityId = "/subscriptions/$($inventory.target.subscriptionId)/resourceGroups/$($inventory.roots[0].resourceGroup)/providers/Microsoft.ManagedIdentity/userAssignedIdentities/maintenance"
    $bootstrap = @{ clientId = '33333333-3333-3333-3333-333333333333'; host = 'fixture.postgres.database.azure.com'; database = 'fixture'; administrator = 'fixture-maintenance'; workloads = @{} }
    $fullInputs = @{ database_connection_name = 'database'; migration_workload = 'api'; workloads = @{ api = @{ image = $copied.image } }; bootstrap_image = $copied.image
        auth = @{ authority = 'https://auth.example.test'; audience = 'fixture-api'; api_scope = 'fixture.access' } }
    $fullExpected = @{ name = 'maintenance'; image = $copied.image; args = @('--migrate-only'); cpu = 0.5; memory = '1Gi'
        environment = @{ ASPNETCORE_ENVIRONMENT = 'Production'; AZURE_CLIENT_ID = $bootstrap.clientId; ConnectionStrings__database = 'Host=fixture.postgres.database.azure.com;Database=fixture;Username=fixture-maintenance;SSL Mode=VerifyFull'
            Auth__Authority = 'https://auth.example.test'; Auth__Audience = 'fixture-api'; Auth__ApiScope = 'fixture.access' } }
    $job.properties.template = Get-Template $fullExpected
    $job.identity = @{ type = 'UserAssigned'; userAssignedIdentities = @{ $identityId = @{} } }
    $blobHandler.Route('GET', "https://management.azure.com${jobId}?api-version=2024-03-01", 200, (ConvertTo-PlatformBootstrapJson $job))
    $blobHandler.Route('GET', "https://management.azure.com${identityId}?api-version=2023-01-31", 200, (ConvertTo-PlatformBootstrapJson @{ properties = @{ clientId = $bootstrap.clientId } }))
    $fullHosting = @{ inputs = $fullInputs; state = @{ outputs = @{ database_bootstrap = $bootstrap; maintenance_jobs = @{ migrations = @{ id = $jobId } } }
            resources = @(@{ type = 'azurerm_container_app_job'; id = $jobId }, @{ type = 'azurerm_user_assigned_identity'; id = $identityId }) } }
    $spec = & $deliveryModule { param($c, $h) Get-AzureDeliveryJobSpec $c $h migrations } $context $fullHosting
    Assert-True ((Get-SnapshotHash $spec.expected) -ceq (Get-SnapshotHash $fullExpected)) 'Native maintenance specification lost expected connection/auth bindings.'
    $checkpoint = Read-AzureDeliveryJournal $context ('a' * 64); $checkpoint.jobs = @{}
    Save-AzureDeliveryJournal $context $checkpoint -Confirm:$false
    $jobFixture.publishExecution = $true; $jobFixture.saved = $null
    $jobFixture.deliveryPath = "/$($inventory.target.container)/$($context.prefix)/delivery.json"
    $result = & $deliveryModule { param($c, $j, $h) Invoke-AzureDeliveryJob $c $j $h migrations } $context $checkpoint $fullHosting
    $durable = Read-AzureDeliveryJournal $context ('a' * 64)
    Assert-True ($result.status -ceq 'Succeeded' -and $durable.jobs.migrations.status -ceq 'Succeeded') 'Native callback failed to checkpoint a successful maintenance execution.'
    $blobHandler.Route('GET', "https://management.azure.com${identityId}?api-version=2023-01-31", 200, (ConvertTo-PlatformBootstrapJson @{ properties = @{ clientId = '99999999-9999-9999-9999-999999999999' } }))
    Assert-Rejected { & $deliveryModule { param($c, $h) Get-AzureDeliveryJobSpec $c $h migrations } $context $fullHosting } 'maintenanceIdentityInvalid'

    # Maintenance evidence is invalidated by any relevant input, messaging state or IaC change.
    $messaging = @($context.inventory.roots | Where-Object id -CEQ 'messaging')[0]
    $messaging.status = 'Verified'; $messaging.stateLineage = 'fixture-lineage'; $messaging.stateSerial = 1
    $inputs = @{ maintenance_jobs_enabled = $true; application_rollout_enabled = $false; workloads = @{ api = @{ image = $copied.image; environment = @{}; secret_references = @{} } } }
    $hash = Get-AzureDeliveryMaintenanceHash $context $inputs
    $inputs.application_rollout_enabled = $true
    Assert-True ((Get-AzureDeliveryMaintenanceHash $context $inputs) -ceq $hash) 'Activation flag incorrectly invalidates maintenance.'
    $inputs.workloads.api.image = 'different'
    Assert-True ((Get-AzureDeliveryMaintenanceHash $context $inputs) -cne $hash) 'Changed image retained old migration evidence.'
    $inputs.workloads.api.image = $copied.image; $messaging.stateSerial++
    Assert-True ((Get-AzureDeliveryMaintenanceHash $context $inputs) -cne $hash) 'Changed messaging state retained old migration evidence.'
    $messaging.stateSerial = 1
    & $deliveryModule { function script:Get-AzureDeliveryBoundInputs { param($Context, $Inputs) return $Inputs } }
    $hosting = @{ inputs = $inputs; registry = @{ login_server = 'fixture123.azurecr.io' }; references = @{ 'example-api' = $components.backend.images['example-api'].target } }
    $gate = Copy-Value $journal; $gate.maintenanceSha256 = $hash; $gate.images = @{ 'example-api' = $copied }; $gate.jobs = @{}
    Assert-Rejected { Assert-AzureDeliveryMaintenance $context $gate $hosting -RequireJobs } 'successfulJobsRequired'
    $gate.jobs.migrations = @{ status = 'Succeeded' }; $gate.jobs['database-access'] = @{ status = 'Running' }
    Assert-Rejected { Assert-AzureDeliveryMaintenance $context $gate $hosting -RequireJobs } 'successfulJobsRequired'
    $gate.jobs['database-access'].status = 'Succeeded'
    Assert-AzureDeliveryMaintenance $context $gate $hosting -RequireJobs
    $gate.maintenanceSha256 = '0' * 64
    Assert-Rejected { Assert-AzureDeliveryMaintenance $context $gate $hosting -RequireJobs } 'maintenanceEvidenceStale'

    # Exact provider output keys are bound per workload; conflicts and credentials are rejected.
    $bindingsFixture = @{ outputs = @{ workload_bindings = @{ api = @{ ConnectionStrings__servicebus = 'fixture.servicebus.windows.net'; Messaging__AzureServiceBus__Destinations__events__Topic = 'fixture-events' } } } }
    & $deliveryModule { param($fixture) $script:bindingFixture = $fixture; function script:Get-AzureLifecycleDeploymentState { return $script:bindingFixture } } $bindingsFixture
    $bound = Get-AzureDeliveryBoundInputs $context $inputs
    Assert-True ($bound.workloads.api.environment.ConnectionStrings__servicebus -ceq 'fixture.servicebus.windows.net') 'Messaging bindings were not copied to the exact workload.'
    Assert-True ($inputs.workloads.api.environment.Count -eq 0) 'Binding mutated the original protected inputs.'
    $conflict = Copy-Value $inputs; $conflict.workloads.api.environment.ConnectionStrings__servicebus = 'other.servicebus.windows.net'
    Assert-Rejected { Get-AzureDeliveryBoundInputs $context $conflict } 'bindingConflict'
    $bindingsFixture.outputs.workload_bindings.api['Messaging__AzureServiceBus__Token'] = 'forbidden'
    Assert-Rejected { Get-AzureDeliveryBoundInputs $context $inputs } 'bindingInvalid'
    $bindingsFixture.outputs.workload_bindings.api.Remove('Messaging__AzureServiceBus__Token')
    $bindingsFixture.outputs.workload_bindings['unknown-worker'] = @{}
    Assert-Rejected { Get-AzureDeliveryBoundInputs $context $inputs } 'bindingWorkloadUnknown'

    # Exercise the real stage dispatch: missing evidence must stop before any apply or job start.
    $gate = Read-AzureDeliveryJournal $context ('a' * 64); $gate.maintenanceSha256 = $hash; $gate.jobs = @{}
    Save-AzureDeliveryJournal $context $gate -Confirm:$false
    $stageFixture = @{ hosting = $hosting; mutations = 0 }
    & $deliveryModule { param($fixture) $script:stageFixture = $fixture
        function script:Get-AzureDeliveryHosting { return $script:stageFixture.hosting }
        function script:Assert-AzureOciImages { }
        function script:Invoke-AzureDeliveryJob { $script:stageFixture.mutations++; throw 'Unexpected job start without successful predecessor evidence.' }
    } $stageFixture
    $env:GITHUB_ACTIONS = 'true'; $env:GITHUB_REF = 'refs/heads/main'; $env:GITHUB_EVENT_NAME = 'workflow_dispatch'
    $env:GITHUB_REPOSITORY = $inventory.iac.repository; $env:GITHUB_WORKFLOW_REF = "$($inventory.iac.repository)/.github/workflows/delivery.yml@refs/heads/main"
    $delivery.releaseSha256 = $inventory.releaseSha256
    $inputs.application_rollout_enabled = $false
    foreach ($stage in @('PrepareActivation', 'ApplyActivation', 'PublishWeb', 'VerifyServing')) {
        Assert-Rejected { Invoke-AzureApplicationStage $context $delivery $release ('a' * 64) $stage $repository ('a' * 40) $temporary -Confirm:$false } 'successfulJobsRequired'
    }
    Assert-Rejected { Invoke-AzureApplicationStage $context $delivery $release ('a' * 64) DatabaseAccess $repository ('a' * 40) $temporary -Confirm:$false } 'migrationsRequired'
    Assert-True ($stageFixture.mutations -eq 0) 'Missing predecessor evidence allowed a job or activation.'
    $before = $context.deliveryRevision
    $whatIf = Invoke-AzureApplicationStage $context $delivery $release ('a' * 64) Artifacts $repository ('a' * 40) $temporary -WhatIf
    Assert-True ($whatIf.status -ceq 'Unverified' -and $context.deliveryRevision -eq $before) 'Delivery WhatIf persisted a checkpoint.'

    # Publication intent is durable before invoking the client; serving evidence is a separate step.
    $gate = Read-AzureDeliveryJournal $context ('a' * 64)
    $gate.jobs = @{ migrations = Copy-Value $durable.jobs.migrations; 'database-access' = Copy-Value $durable.jobs.migrations }
    $gate.activated = $true; Save-AzureDeliveryJournal $context $gate -Confirm:$false
    $inputs.application_rollout_enabled = $true; $hosting.state = @{ etag = '"fixture-state"' }
    $stageFixture.handler = $blobHandler; $stageFixture.path = "/$($inventory.target.container)/$($context.prefix)/delivery.json"
    $stageFixture.failHealth = $false; $stageFixture.intentObserved = $false
    & $deliveryModule {
        function script:Get-AzureWebTarget { return @{ id = 'fixture'; origin = 'https://fixture.azurestaticapps.net' } }
        function script:Get-AzureBackendHealth {
            if ($script:stageFixture.failHealth) { throw 'lifecycle.web.revisionNotHealthy' }
            return ,@(@{ workloadId = 'fixture-api'; readyReplicas = 1 })
        }
        function script:New-AzureWebPayload { return @{ deploymentSha256 = 'd' * 64; identity = @{ archiveSha256 = 'e' * 64; overlaySha256 = 'f' * 64 } } }
        function script:Publish-AzureWebPayload {
            $stored = [Text.Encoding]::UTF8.GetString($script:stageFixture.handler.Blobs[$script:stageFixture.path]) | ConvertFrom-Json -AsHashtable -Depth 24
            if ($stored.web.status -cne 'Publishing') { throw 'Publication started before durable intent.' }
            $script:stageFixture.intentObserved = $true
        }
        function script:Test-StaticWebServing { return @{ deploymentSha256 = 'd' * 64; filesVerified = 6; fallbackVerified = $true; publicConfigurationVerified = $true } }
        function script:Get-AzureLifecycleDeploymentState { return $script:stageFixture.hosting.state }
    }
    $published = Invoke-AzureApplicationStage $context $delivery $release ('a' * 64) PublishWeb $repository ('a' * 40) $temporary -Confirm:$false
    $checkpoint = Read-AzureDeliveryJournal $context ('a' * 64)
    Assert-True ($stageFixture.intentObserved -and $published.status -ceq 'Completed' -and $checkpoint.web.status -ceq 'Published' -and $null -eq $checkpoint.web.evidenceSha256) 'Client success incorrectly accredited served content.'
    $served = Invoke-AzureApplicationStage $context $delivery $release ('a' * 64) VerifyServing $repository ('a' * 40) $temporary -Confirm:$false
    $checkpoint = Read-AzureDeliveryJournal $context ('a' * 64)
    Assert-True ($checkpoint.web.status -ceq 'Verified' -and $served.details.filesVerified -eq 6 -and $served.applicationVerified -eq $false) 'Serving evidence incorrectly closed the full application verification.'
    $evidence = Read-AzureLifecycleObject $context "$($context.prefix)/evidence/$($checkpoint.web.evidenceSha256).json" $checkpoint.web.evidenceSha256
    Assert-True (([Text.Encoding]::UTF8.GetString($evidence) | ConvertFrom-Json).applicationVerified -eq $false) 'Durable serving evidence was not read back or claims E2E.'
    $stageFixture.failHealth = $true
    Assert-Rejected { Invoke-AzureApplicationStage $context $delivery $release ('a' * 64) VerifyServing $repository ('a' * 40) $temporary -Confirm:$false } 'revisionNotHealthy'
    $checkpoint = Read-AzureDeliveryJournal $context ('a' * 64)
    Assert-True ($checkpoint.web.status -ceq 'Published' -and $null -eq $checkpoint.web.evidenceSha256) 'Failed re-verification retained a current Verified status.'
    Exit-AzureLifecycleLease $context -Confirm:$false

    # The actual CLI validates tracked metadata and protections in an isolated process scope.
    # Only GitHub reads are replaced; Azure account access must not occur in Validate/WhatIf.
    $source = Join-Path $temporary 'source'; [IO.Directory]::CreateDirectory($source) | Out-Null
    foreach ($relative in @('scripts', 'contracts/schemas', '.config')) {
        $destination = Join-Path $source $relative; [IO.Directory]::CreateDirectory($destination) | Out-Null
        Get-ChildItem -LiteralPath (Join-Path $repository $relative) -File -Force | Copy-Item -Destination $destination
    }
    $profile = Join-Path $source '.config/environments/dev/run-12345-1'; [IO.Directory]::CreateDirectory($profile) | Out-Null
    $definition = Get-Content -Raw -LiteralPath (Join-Path $repository 'examples/ephemeral-environment.json') | ConvertFrom-Json -AsHashtable
    $definition.expiresAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 3600
    $definition.reviewerIds = @(); $definition.oidcPrefix = 'repo:example-owner/hexagon-template-devops'
    $release.product = $definition.inventory.product
    $descriptor = Get-Content -Raw -LiteralPath (Join-Path $repository 'examples/product-environment.json') | ConvertFrom-Json -AsHashtable
    $descriptor.product = $release.product; $descriptor.components = $release.sources
    Write-Json (Join-Path $profile 'release.json') $release; Write-Json (Join-Path $profile 'descriptor.json') $descriptor
    $definition.inventory.releaseSha256 = Get-LifecycleFileHash (Join-Path $profile 'release.json')
    $definition.inventory.descriptorSha256 = Get-LifecycleFileHash (Join-Path $profile 'descriptor.json')
    $delivery.releaseSha256 = $definition.inventory.releaseSha256
    Write-Json (Join-Path $profile 'delivery.json') $delivery; Write-Json (Join-Path $profile 'definition.json') $definition
    foreach ($arguments in @(@('init', '-b', 'main'), @('config', 'core.autocrlf', 'false'), @('config', 'commit.gpgsign', 'false'), @('config', 'user.email', 'fixture@example.invalid'), @('config', 'user.name', 'Delivery fixture'), @('add', '.'), @('commit', '-m', 'Fixture source'))) {
        & git -C $source @arguments *> $null
        if ($LASTEXITCODE -ne 0) { throw 'Delivery CLI Git fixture preparation failed.' }
    }
    $runspace = [PowerShell]::Create()
    $scriptBody = {
        param($Root, $DefinitionHash, $DeliveryHash)
        $ErrorActionPreference = 'Stop'
        Import-Module (Join-Path $Root 'scripts/EphemeralEnvironment.psm1')
        Import-Module (Join-Path $Root 'scripts/AzureEnvironmentStore.psm1')
        & (Get-Module AzureEnvironmentStore) { function script:Assert-AzureLifecycleAccount { throw 'Unexpected Azure access in Validate.' } }
        & (Get-Module EphemeralEnvironment) {
            function script:Invoke-EphemeralGithub {
                param($Method, $Path)
                if ($Method -cne 'GET') { throw 'Unexpected GitHub mutation.' }
                if ($Path -ceq 'repos/example-owner/hexagon-template-devops') { return @{ full_name = 'example-owner/hexagon-template-devops'; default_branch = 'main'; archived = $false; disabled = $false; owner = @{ login = 'example-owner'; id = 123 }; name = 'hexagon-template-devops'; id = 456 } }
                if ($Path -like '*/actions/oidc/customization/sub') { return @{ use_default = $true; sub_claim_prefix = 'repo:example-owner/hexagon-template-devops' } }
                if ($Path -like '*/deployment-branch-policies*') { return @{ total_count = 1; branch_policies = @(@{ name = 'main'; type = 'branch' }) } }
                if ($Path -like '*/variables*') { throw 'Unnecessary privileged GitHub API request.' }
                return @{ can_admins_bypass = $false; deployment_branch_policy = @{ protected_branches = $false; custom_branch_policies = $true }; protection_rules = @(@{ type = 'branch_policy' }) }
            }
        }
        $names = @('GITHUB_ACTIONS', 'GITHUB_EVENT_NAME', 'GITHUB_REF', 'GITHUB_REPOSITORY', 'GITHUB_WORKFLOW_REF', 'GITHUB_STEP_SUMMARY'); $saved = @{}
        foreach ($key in $names) { $saved[$key] = [Environment]::GetEnvironmentVariable($key) }
        try {
            $env:GITHUB_ACTIONS = 'true'; $env:GITHUB_EVENT_NAME = 'workflow_dispatch'; $env:GITHUB_REF = 'refs/heads/main'; $env:GITHUB_REPOSITORY = 'example-owner/hexagon-template-devops'
            $env:GITHUB_WORKFLOW_REF = 'example-owner/hexagon-template-devops/.github/workflows/delivery.yml@refs/heads/main'; $env:GITHUB_STEP_SUMMARY = $null
            & (Join-Path $Root 'scripts/Invoke-ApplicationDelivery.ps1') -Environment dev -InstanceId run-12345-1 -DefinitionSha256 $DefinitionHash -DeliverySha256 $DeliveryHash -Stage Validate
        }
        finally { foreach ($key in $names) { [Environment]::SetEnvironmentVariable($key, $saved[$key]) } }
    }
    try {
        [void] $runspace.AddScript($scriptBody.ToString()).AddArgument($source).AddArgument((Get-LifecycleFileHash (Join-Path $profile 'definition.json'))).AddArgument((Get-LifecycleFileHash (Join-Path $profile 'delivery.json')))
        $output = $runspace.Invoke()
        if ($runspace.HadErrors) {
            $diagnostic = @($runspace.Runspace.SessionStateProxy.GetVariable('Error')) | Select-Object -First 1
            throw "Delivery CLI fixture failed: $($output -join '') $($diagnostic.Exception.Message) $($diagnostic.ScriptStackTrace)"
        }
        $validated = $output -join "`n" | ConvertFrom-Json
        Assert-True ($validated.status -ceq 'Validated' -and $validated.details.githubEnvironment -ceq 'dev-run-12345-1') "Delivery CLI did not validate tracked metadata: $($output -join '')"
    }
    finally { $runspace.Dispose() }
}
finally {
    foreach ($key in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($key, $savedEnvironment[$key]) }
    foreach ($name in @('AzureEnvironmentStore', 'ApplicationArtifacts', 'AzureOciDelivery', 'AzureMaintenanceDelivery', 'AzureApplicationDelivery')) { Import-Module (Join-Path $repository "scripts/$name.psm1") -Force }
    $resolved = [IO.Path]::GetFullPath($temporary)
    if ([IO.Path]::GetDirectoryName($resolved) -cne $parent -or -not [IO.Path]::GetFileName($resolved).StartsWith('hexagon-delivery-tests-')) { throw 'Unsafe test cleanup target.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Host "Application delivery tests passed ($script:assertions assertions)."
