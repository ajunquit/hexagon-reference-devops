Set-StrictMode -Version Latest

function Invoke-GitHubApiJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Endpoint,

        [string[]] $Arguments = @()
    )

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw 'GitHub CLI (gh) is required to resolve private application contracts.'
    }

    $output = & gh api $Endpoint @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        $message = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
        throw "GitHub API request failed for '$Endpoint': $message"
    }

    $json = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    return $json | ConvertFrom-Json
}

function Resolve-GitHubCommit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Repository,

        [Parameter(Mandatory = $true)]
        [string] $Reference
    )

    $encodedReference = [Uri]::EscapeDataString($Reference)
    $response = Invoke-GitHubApiJson -Endpoint "repos/$Repository/commits/$encodedReference"
    $commit = [string] $response.sha
    if ($commit -cnotmatch '^[0-9a-f]{40}$') {
        throw "GitHub returned an invalid commit for '$Repository@$Reference'."
    }

    return $commit
}

function Get-GitHubFileBytes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Repository,

        [Parameter(Mandatory = $true)]
        [string] $Commit,

        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    $encodedPath = (($Path -split '/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
    $encodedCommit = [Uri]::EscapeDataString($Commit)
    $response = Invoke-GitHubApiJson `
        -Endpoint "repos/$Repository/contents/$encodedPath`?ref=$encodedCommit"

    if ([string] $response.type -cne 'file' -or [string] $response.encoding -cne 'base64') {
        throw "'${Repository}:$Path@$Commit' is not a base64 GitHub file response."
    }

    $base64 = ([string] $response.content) -replace '\s', ''
    try {
        return [Convert]::FromBase64String($base64)
    }
    catch {
        throw "GitHub returned invalid base64 content for '${Repository}:$Path@$Commit'."
    }
}

function Get-Sha256Hex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [byte[]] $Bytes
    )

    return [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($Bytes)
    ).ToLowerInvariant()
}

function Resolve-ManifestSchemaPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ManifestPath,

        [Parameter(Mandatory = $true)]
        [string] $SchemaReference
    )

    $normalizedReference = $SchemaReference -replace '^\./', ''
    if ($normalizedReference -notmatch '^(?!/)(?!.*(?:^|/)\.\.(?:/|$))[A-Za-z0-9._/-]+$') {
        throw "Manifest schema reference '$SchemaReference' must be a safe relative path."
    }

    $lastSlash = $ManifestPath.LastIndexOf('/')
    $manifestDirectory = if ($lastSlash -ge 0) {
        $ManifestPath.Substring(0, $lastSlash)
    }
    else {
        ''
    }

    if ($manifestDirectory) {
        return "$manifestDirectory/$normalizedReference"
    }

    return $normalizedReference
}

function Get-ValidatedApplicationManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Repository,

        [Parameter(Mandatory = $true)]
        [string] $Commit,

        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [string] $ExpectedProduct,

        [Parameter(Mandatory = $true)]
        [string] $ExpectedComponent
    )

    $bytes = Get-GitHubFileBytes -Repository $Repository -Commit $Commit -Path $Path
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    try {
        $json = $utf8.GetString($bytes)
        $manifest = $json | ConvertFrom-Json
    }
    catch {
        throw "'${Repository}:$Path@$Commit' is not valid UTF-8 JSON: $($_.Exception.Message)"
    }

    $schemaReference = [string] $manifest.'$schema'
    if (-not $schemaReference) {
        throw "'${Repository}:$Path@$Commit' does not declare a relative `$schema."
    }

    $schemaPath = Resolve-ManifestSchemaPath `
        -ManifestPath $Path `
        -SchemaReference $schemaReference
    $schemaBytes = Get-GitHubFileBytes `
        -Repository $Repository `
        -Commit $Commit `
        -Path $schemaPath
    $schemaJson = $utf8.GetString($schemaBytes)

    $isValid = $json | Test-Json -Schema $schemaJson -ErrorAction SilentlyContinue
    if (-not $isValid) {
        throw "'${Repository}:$Path@$Commit' does not satisfy '$schemaPath'."
    }

    if ([string] $manifest.product -cne $ExpectedProduct) {
        throw "'${Repository}:$Path@$Commit' declares product '$($manifest.product)', " +
            "expected '$ExpectedProduct'."
    }
    if ([string] $manifest.component -cne $ExpectedComponent) {
        throw "'${Repository}:$Path@$Commit' declares component '$($manifest.component)', " +
            "expected '$ExpectedComponent'."
    }

    return [pscustomobject] @{
        Manifest = $manifest
        Sha256   = Get-Sha256Hex -Bytes $bytes
    }
}

Export-ModuleMember -Function @(
    'Get-ValidatedApplicationManifest',
    'Resolve-GitHubCommit'
)
