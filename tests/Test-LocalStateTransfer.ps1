<#
.SYNOPSIS
    Checks Terraform state transfer and lineage protection against local files only; no apply or provider.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
$directory = Join-Path $parent "hexagon-state-transfer-$([guid]::NewGuid().ToString('N'))"
try {
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    [IO.File]::WriteAllText((Join-Path $directory 'main.tf'), "terraform {`n  backend `"local`" {}`n}`n")
    $version = ((& terraform version -json) -join "`n" | ConvertFrom-Json).terraform_version
    $state = @{ version = 4; terraform_version = $version; serial = 7; lineage = [guid]::NewGuid().ToString(); resources = @(); outputs = @{ probe = @{ type = 'string'; value = 'local-only' } }; check_results = $null }
    $path = Join-Path $directory 'sample-state.json'
    [IO.File]::WriteAllText($path, ($state | ConvertTo-Json -Depth 10))
    & terraform "-chdir=$directory" init -input=false -no-color | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Local state transfer init failed.' }
    & terraform "-chdir=$directory" state push $path
    if ($LASTEXITCODE -ne 0) { throw 'Local state transfer failed.' }
    $transferred = ((& terraform "-chdir=$directory" state pull) -join "`n") | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $transferred.lineage -cne $state.lineage -or $transferred.serial -ne $state.serial -or $transferred.outputs.probe.value -cne 'local-only') { throw 'State push did not preserve lineage, serial and data.' }
    $state.lineage = [guid]::NewGuid().ToString()
    [IO.File]::WriteAllText($path, ($state | ConvertTo-Json -Depth 10))
    $failure = & terraform "-chdir=$directory" state push $path 2>&1
    if ($LASTEXITCODE -eq 0) { throw 'State push must reject a foreign lineage without force.' }
    $after = ((& terraform "-chdir=$directory" state pull) -join "`n") | ConvertFrom-Json
    if ($after.lineage -cne $transferred.lineage -or $after.serial -ne $transferred.serial) { throw 'A refused state push altered the destination.' }
}
finally {
    $resolved = [IO.Path]::GetFullPath($directory)
    if ([IO.Path]::GetDirectoryName($resolved) -cne $parent -or -not [IO.Path]::GetFileName($resolved).StartsWith('hexagon-state-transfer-')) { throw 'Unsafe local state test cleanup.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Host 'Terraform local state transfer and foreign-lineage protection passed; no cloud access or apply.'
