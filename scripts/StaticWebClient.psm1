Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-StaticWebClientSpec {
    $lock = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '../.config/static-web-client.json') | ConvertFrom-Json -AsHashtable
    $platform = $(if ($IsWindows) { 'win-x64' } elseif ($IsLinux) { 'linux-x64' } else { throw 'lifecycle.web.clientPlatformUnsupported' })
    if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne [Runtime.InteropServices.Architecture]::X64) { throw 'lifecycle.web.clientPlatformUnsupported' }
    if ($lock.apiVersion -cne 'hexagon.ec/static-web-client/v1' -or $lock.buildId -cnotmatch '^[0-9a-f]{32,64}$') { throw 'lifecycle.web.clientLockInvalid' }
    $file = $lock.files[$platform]; $name = $(if ($IsWindows) { 'StaticSitesClient.exe' } else { 'StaticSitesClient' }); $os = $(if ($IsWindows) { 'windows' } else { 'linux' })
    if ($file.url -cne "https://swalocaldeployv2-bndtgugjgqc3dhdx.b01.azurefd.net/downloads/$($lock.buildId)/$os/$name" -or $file.sha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'lifecycle.web.clientLockInvalid' }
    return @{ buildId = $lock.buildId; url = $file.url; sha256 = $file.sha256; path = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "../artifacts/static-web-client/$($lock.buildId)/$platform/$name")) }
}

function Get-StaticWebClientPath {
    $spec = Get-StaticWebClientSpec
    $item = Get-Item -LiteralPath $spec.path -Force
    $ancestor = $item
    while ($ancestor.FullName.Length -gt (Split-Path -Parent $PSScriptRoot).Length) {
        if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'lifecycle.web.clientLinkRejected' }
        $ancestor = Get-Item -LiteralPath (Split-Path -Parent $ancestor.FullName) -Force
    }
    if ($item.PSIsContainer -or (Get-FileHash -LiteralPath $spec.path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $spec.sha256) { throw 'lifecycle.web.clientChecksumMismatch' }
    return $spec.path
}

function Install-StaticWebClient {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()
    $spec = Get-StaticWebClientSpec
    if (-not $PSCmdlet.ShouldProcess($spec.buildId, 'Install the checksum-pinned Microsoft StaticSitesClient')) { return }
    if (Test-Path -LiteralPath $spec.path) { Get-StaticWebClientPath | Out-Null; return }
    Import-Module (Join-Path $PSScriptRoot 'EphemeralEnvironment.psm1')
    $directory = Split-Path -Parent $spec.path
    New-EphemeralWorkspace $directory -Confirm:$false | Out-Null
    $handler = [Net.Http.HttpClientHandler]::new(); $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler); $client.Timeout = [TimeSpan]::FromMinutes(5)
    $response = $null; $source = $null; $destination = $null
    try {
        $response = $client.GetAsync($spec.url, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if ([int] $response.StatusCode -ne 200 -or $response.Content.Headers.ContentLength -gt 200MB) { throw 'lifecycle.web.clientDownloadFailed' }
        $source = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult(); $destination = [IO.File]::Open($spec.path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
        $buffer = [byte[]]::new(65536); $total = 0L
        while (($count = $source.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $total += $count
            if ($total -gt 200MB) { throw 'lifecycle.web.clientDownloadTooLarge' }
            $destination.Write($buffer, 0, $count)
        }
        $destination.Dispose(); $destination = $null
        Get-StaticWebClientPath | Out-Null
        if (-not $IsWindows) { [IO.File]::SetUnixFileMode($spec.path, [IO.UnixFileMode] 'UserRead,UserWrite,UserExecute') }
    }
    catch { if ($_.Exception.Message -cmatch '^lifecycle[.][A-Za-z0-9.]+$') { throw }; throw 'lifecycle.web.clientDownloadFailed' }
    finally { if ($destination) { $destination.Dispose() }; if ($source) { $source.Dispose() }; if ($response) { $response.Dispose() }; $client.Dispose() }
}

Export-ModuleMember -Function Get-StaticWebClientSpec, Get-StaticWebClientPath, Install-StaticWebClient
