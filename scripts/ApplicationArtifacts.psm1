Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PlatformBootstrap.psm1')

function Assert-ApplicationDelivery([hashtable] $Delivery, [string] $ReleaseSha256) {
    $json = ConvertTo-Json -InputObject $Delivery -Depth 20
    if (-not ($json | Test-Json -SchemaFile (Join-Path $PSScriptRoot '../contracts/schemas/application-delivery-v1.schema.json') -ErrorAction SilentlyContinue) -or
        $Delivery.releaseSha256 -cne $ReleaseSha256) { throw 'lifecycle.delivery.definitionInvalid' }
}

function New-DeliveryHttpClient {
    $handler = [Net.Http.HttpClientHandler]::new(); $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler); $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
    return $client
}

function Receive-DeliveryHttp {
    param([string] $Uri, [hashtable] $Headers = @{}, [string] $Destination, [long] $MaximumBytes = 4194304, [scriptblock] $Heartbeat)
    $client = New-DeliveryHttpClient
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, $Uri)
    foreach ($key in $Headers.Keys) { [void] $request.Headers.TryAddWithoutValidation($key, [string] $Headers[$key]) }
    $response = $null; $stream = $null; $output = $null
    $cancel = [Threading.CancellationTokenSource]::new([TimeSpan]::FromMinutes(15))
    $timer = [Diagnostics.Stopwatch]::StartNew(); $lastBeat = 0.0
    try {
        $response = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cancel.Token).GetAwaiter().GetResult()
        if ($response.Content.Headers.ContentLength -gt $MaximumBytes) { throw 'lifecycle.delivery.responseTooLarge' }
        $output = $(if ($Destination) { [IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write) } else { [IO.MemoryStream]::new() })
        $stream = $response.Content.ReadAsStreamAsync($cancel.Token).GetAwaiter().GetResult()
        $buffer = [byte[]]::new(65536); $total = 0L
        while ($true) {
            $task = $stream.ReadAsync($buffer, 0, $buffer.Length, $cancel.Token)
            while (-not $task.Wait(1000)) {
                if ($Heartbeat -and $timer.Elapsed.TotalSeconds - $lastBeat -ge 10) { & $Heartbeat | Out-Null; $lastBeat = $timer.Elapsed.TotalSeconds }
            }
            $count = $task.GetAwaiter().GetResult()
            if ($count -eq 0) { break }
            $total += $count
            if ($total -gt $MaximumBytes) { throw 'lifecycle.delivery.responseTooLarge' }
            $output.Write($buffer, 0, $count)
            if ($Heartbeat -and $timer.Elapsed.TotalSeconds - $lastBeat -ge 10) { & $Heartbeat | Out-Null; $lastBeat = $timer.Elapsed.TotalSeconds }
        }
        $headersOut = @{}; foreach ($header in $response.Headers) { $headersOut[$header.Key] = @($header.Value)[0] }
        return @{ status = [int] $response.StatusCode; headers = $headersOut; bytes = $(if ($Destination) { @() } else { $output.ToArray() }) }
    }
    catch {
        if ($_.Exception.Message -cmatch '^lifecycle[.][A-Za-z0-9.]+$') { throw }
        throw 'lifecycle.delivery.downloadFailed'
    }
    finally { if ($stream) { $stream.Dispose() }; if ($output) { $output.Dispose() }; if ($response) { $response.Dispose() }; $request.Dispose(); $cancel.Dispose(); $client.Dispose() }
}

function Get-DeliveryGithubJson([string] $Repository, [string] $Path, [string] $Token) {
    if ($Repository -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or $Path -cnotmatch '^actions/(artifacts/[1-9][0-9]*|runs/[1-9][0-9]*/attempts/[1-9][0-9]*)$' -or -not $Token) { throw 'lifecycle.delivery.githubRequestInvalid' }
    $result = Receive-DeliveryHttp "https://api.github.com/repos/$Repository/$Path" @{
        Authorization = "Bearer $Token"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28'; 'User-Agent' = 'hexagon-delivery'
    }
    if ($result.status -ne 200) { throw 'lifecycle.delivery.githubEvidenceUnavailable' }
    try { return [Text.Encoding]::UTF8.GetString($result.bytes) | ConvertFrom-Json -AsHashtable -Depth 32 }
    catch { throw 'lifecycle.delivery.githubEvidenceInvalid' }
}

function Assert-DeliveryGithubEvidence {
    param([hashtable] $Candidate, [hashtable] $Run, [hashtable] $Artifact, [string] $Repository, [string] $Commit, [string] $Component)
    $prefix = $(if ($Component -ceq 'devops') { 'operations' } else { $Component })
    if ($Run.id -ne $Candidate.runId -or $Run.run_attempt -ne $Candidate.runAttempt -or $Run.status -cne 'completed' -or $Run.conclusion -cne 'success' -or
        $Run.event -cnotin @('push', 'workflow_dispatch') -or $Run.head_branch -cne 'main' -or $Run.head_sha -cne $Commit -or
        $Run.path -cne '.github/workflows/ci.yml' -or $Run.repository.full_name -cne $Repository -or $Run.head_repository.id -ne $Run.repository.id -or
        $Artifact.id -ne $Candidate.artifactId -or $Artifact.expired -isnot [bool] -or $Artifact.expired -or $Artifact.size_in_bytes -le 0 -or $Artifact.size_in_bytes -gt 2GB -or
        $Artifact.name -cne "$prefix-$Commit-$($Candidate.runId)-$($Candidate.runAttempt)" -or $Artifact.digest -cne "sha256:$($Candidate.archiveSha256)" -or
        $Artifact.workflow_run.id -ne $Candidate.runId -or $Artifact.workflow_run.repository_id -ne $Run.repository.id -or
        $Artifact.workflow_run.head_repository_id -ne $Run.repository.id -or $Artifact.workflow_run.head_branch -cne 'main' -or $Artifact.workflow_run.head_sha -cne $Commit) {
        throw 'lifecycle.delivery.candidateUntrusted'
    }
}

function Expand-DeliveryCandidate([string] $Archive, [string] $Directory) {
    if (Test-Path -LiteralPath $Directory) { throw 'lifecycle.delivery.candidateDirectoryExists' }
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $total = 0L
        if ($zip.Entries.Count -gt 256) { throw 'lifecycle.delivery.candidateTooLarge' }
        foreach ($entry in $zip.Entries) {
            $type = ($entry.ExternalAttributes -shr 16) -band 0xf000
            if ($entry.FullName -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,180}$' -or $entry.FullName -in @('.', '..') -or
                $type -notin @(0, 0x8000) -or -not $names.Add($entry.FullName)) { throw 'lifecycle.delivery.candidateEntryInvalid' }
            $total += $entry.Length
            if ($entry.Length -gt 2GB -or $total -gt 4GB) { throw 'lifecycle.delivery.candidateTooLarge' }
        }
        [IO.Directory]::CreateDirectory($Directory) | Out-Null
        foreach ($entry in $zip.Entries) { [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $Directory $entry.FullName), $false) }
    }
    finally { $zip.Dispose() }
}

function Get-DeliveryImageTarget([string] $Reference, [string] $Registry) {
    if ($Registry -cnotmatch '^[a-z0-9]{5,50}[.]azurecr[.]io$' -or
        $Reference -cnotmatch '^[a-z0-9.-]+(?::[0-9]+)?/([a-z0-9]+(?:[._-][a-z0-9]+)*(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)*)@(sha256:[0-9a-f]{64})$') { throw 'lifecycle.delivery.imageReferenceInvalid' }
    return @{ repository = $Matches[1]; digest = $Matches[2]; image = "$Registry/$($Matches[1])@$($Matches[2])" }
}

function Test-DeliveryComponent {
    param([string] $Directory, [hashtable] $Release, [string] $Component, [string] $Registry)
    $source = $(if ($Component -ceq 'devops') { $Release.artifacts.databaseBootstrap } else { @($Release.sources | Where-Object name -CEQ $Component)[0] })
    & (Join-Path $PSScriptRoot 'Test-ComponentBuild.ps1') -Directory $Directory -ExpectedRepository $source.repository -ExpectedCommit $source.commit -ExpectedProduct $Release.product -ExpectedComponent $Component | Out-Null
    $build = Get-Content -Raw -LiteralPath (Join-Path $Directory 'build.json') | ConvertFrom-Json -AsHashtable -Depth 32
    if ($Component -cne 'devops') {
        foreach ($manifest in $source.manifests) {
            $matches = @($build.manifests | Where-Object { $_.path -ceq $manifest.path -and $_.sha256 -ceq $manifest.sha256 })
            if ($matches.Count -ne 1) { throw 'lifecycle.delivery.manifestMismatch' }
        }
        if ($build.manifests.Count -ne $source.manifests.Count) { throw 'lifecycle.delivery.manifestMismatch' }
    }
    if ($Component -ceq 'web') {
        if ($build.artifacts[0].sha256 -cne $Release.artifacts.web.sha256) { throw 'lifecycle.delivery.webMismatch' }
        return @{ build = $build; directory = $Directory; images = @{} }
    }
    $references = $(if ($Component -ceq 'backend') { $Release.artifacts.backend } else { @{ 'database-bootstrap' = $Release.artifacts.databaseBootstrap.image } })
    if ((@($references.Keys | Sort-Object) -join ',') -cne (@($build.artifacts.id | Sort-Object) -join ',')) { throw 'lifecycle.delivery.workloadsMismatch' }
    $images = @{}
    foreach ($artifact in $build.artifacts) {
        $target = Get-DeliveryImageTarget $references[$artifact.id] $Registry
        if ($artifact.platform -cne 'linux/amd64' -or $artifact.imageDigest -cne $target.digest) { throw 'lifecycle.delivery.imageMismatch' }
        $images[$artifact.id] = @{ target = $target; file = Join-Path $Directory $artifact.file; sha256 = $artifact.sha256 }
    }
    return @{ build = $build; directory = $Directory; images = $images }
}

function Receive-ApplicationCandidates {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([hashtable] $Delivery, [hashtable] $Release, [string] $Registry, [string] $Directory, [scriptblock] $Heartbeat,
        [ValidateSet('backend', 'web', 'devops')][string[]] $ComponentNames = @('backend', 'web', 'devops'))
    if (-not $PSCmdlet.ShouldProcess($Release.product, 'Retrieve and verify immutable CI candidates')) { return }
    [IO.Directory]::CreateDirectory($Directory) | Out-Null
    $components = @{}
    foreach ($component in $ComponentNames) {
        $source = $(if ($component -ceq 'devops') { $Release.artifacts.databaseBootstrap } else { @($Release.sources | Where-Object name -CEQ $component)[0] })
        $candidate = $Delivery.candidates[$component]
        $token = $(if ($source.repository -ceq $env:GITHUB_REPOSITORY) { $env:GH_TOKEN } else { $env:HEXAGON_ARTIFACTS_READ_TOKEN })
        if (-not $token) { throw 'lifecycle.delivery.artifactsCredentialRequired' }
        $run = Get-DeliveryGithubJson $source.repository "actions/runs/$($candidate.runId)/attempts/$($candidate.runAttempt)" $token
        $artifact = Get-DeliveryGithubJson $source.repository "actions/artifacts/$($candidate.artifactId)" $token
        Assert-DeliveryGithubEvidence $candidate $run $artifact $source.repository $source.commit $component
        $redirect = Receive-DeliveryHttp "https://api.github.com/repos/$($source.repository)/actions/artifacts/$($candidate.artifactId)/zip" @{
            Authorization = "Bearer $token"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28'; 'User-Agent' = 'hexagon-delivery'
        }
        $address = [uri] $redirect.headers['Location']
        if ($redirect.status -ne 302 -or -not $address.IsAbsoluteUri -or $address.Scheme -cne 'https' -or $address.Port -ne 443 -or $address.UserInfo -or
            $address.Host -cnotmatch '^[a-z0-9.-]+[.](blob[.]core[.]windows[.]net|githubusercontent[.]com|actions[.]githubusercontent[.]com)$') { throw 'lifecycle.delivery.archiveRedirectInvalid' }
        $archive = Join-Path $Directory "$component.zip"
        # Signed download URL is never persisted; the GitHub credential is not forwarded.
        $download = Receive-DeliveryHttp $address.AbsoluteUri @{} $archive 2GB $Heartbeat
        if ($download.status -ne 200 -or (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -cne $candidate.archiveSha256) { throw 'lifecycle.delivery.archiveMismatch' }
        $expanded = Join-Path $Directory $component
        Expand-DeliveryCandidate $archive $expanded
        $components[$component] = Test-DeliveryComponent $expanded $Release $component $Registry
        if ($Heartbeat) { & $Heartbeat | Out-Null }
    }
    return $components
}

Export-ModuleMember -Function Assert-ApplicationDelivery, Assert-DeliveryGithubEvidence, Expand-DeliveryCandidate, Get-DeliveryImageTarget, Test-DeliveryComponent, Receive-ApplicationCandidates
