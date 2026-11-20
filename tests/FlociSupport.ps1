# Helpers shared by the Floci checks of every cloud (ADR 0026). Dot-sourced by tests/Invoke-FlociRoots*.ps1,
# which own $results.

function Invoke-Step([string] $Name, [scriptblock] $Action) {
    Write-Host "== $Name"
    try { & $Action | Out-Host }
    catch { $results[$Name] = "Failed: $($_.Exception.Message)"; throw }
    $passed = $LASTEXITCODE -eq 0
    $results[$Name] = $(if ($passed) { 'Passed' } else { 'Failed' })
    if (-not $passed) { throw "Step failed: $Name" }
}

# Replaces an exact block of the temporary copy; a module that no longer has it stops the check.
function Set-StandIn([string] $Path, [string] $Original, [string] $Replacement, [string] $Name) {
    $text = [IO.File]::ReadAllText($Path).Replace("`r`n", "`n")
    if (-not $text.Contains($Original)) { throw "The module changed; review the stand-in '$Name' (docs/pruebas-locales-floci.md)." }
    [IO.File]::WriteAllText($Path, $text.Replace($Original, $Replacement))
    $results["stand-in: $Name"] = 'Applied'
}

# Removes a whole resource block of the temporary copy, found by its exact header.
function Remove-ResourceBlock([string] $Path, [string] $Header, [string] $Name) {
    $text = [IO.File]::ReadAllText($Path).Replace("`r`n", "`n")
    $start = $text.IndexOf($Header)
    $end = $(if ($start -ge 0) { $text.IndexOf("`n}`n", $start) } else { -1 })
    if ($start -lt 0 -or $end -lt 0) { throw "The module changed; review the stand-in '$Name' (docs/pruebas-locales-floci.md)." }
    [IO.File]::WriteAllText($Path, $text.Remove($start, $end + 3 - $start))
    $results["stand-in: $Name"] = 'Applied'
}
