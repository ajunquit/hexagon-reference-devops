Set-StrictMode -Version Latest

# Azure tools of the lifecycle: the Azure CLI, run through PowerShell with its arguments in the
# environment, and the pinned Static Web Apps client with an allowlisted environment.
# LifecycleNative.psm1 discovers this module and calls these functions inside its scope; it exports
# nothing, so the modules of different clouds never collide.

function Get-LifecycleToolNames { return @('az', 'static-web-client') }

function Set-LifecycleToolStart([string] $Tool, [Diagnostics.ProcessStartInfo] $info, [string[]] $Arguments, [hashtable] $Environment) {
    if ($Tool -ceq 'static-web-client') {
        if ($null -ne $Arguments -and $Arguments.Count -gt 0) { throw 'lifecycle.web.clientArgumentsForbidden' }
        Import-Module (Join-Path $PSScriptRoot 'StaticWebClient.psm1')
        $info.FileName = Get-StaticWebClientPath
        foreach ($key in @($info.Environment.Keys)) {
            if ($key -cnotin @('PATH', 'Path', 'SystemRoot', 'WINDIR', 'TEMP', 'TMP', 'TMPDIR', 'HOME', 'USERPROFILE', 'LANG', 'LC_ALL', 'LD_LIBRARY_PATH', 'SSL_CERT_FILE', 'SSL_CERT_DIR')) { $info.Environment.Remove($key) | Out-Null }
        }
        foreach ($key in $Environment.Keys) {
            if ($key -cnotin @('DEPLOYMENT_ACTION', 'DEPLOYMENT_PROVIDER', 'REPOSITORY_BASE', 'SKIP_APP_BUILD', 'SKIP_API_BUILD', 'DEPLOYMENT_TOKEN', 'APP_LOCATION', 'API_LOCATION', 'DATA_API_LOCATION', 'CONFIG_FILE_LOCATION', 'VERBOSE')) { throw 'lifecycle.web.clientEnvironmentForbidden' }
        }
    }
    else {
        $info.FileName = (Get-Process -Id $PID).Path
        $code = '$ErrorActionPreference="Stop"; $PSNativeCommandUseErrorActionPreference=$false; $nativeArgs=ConvertFrom-Json $env:HEXAGON_LIFECYCLE_NATIVE_ARGS; & az @nativeArgs; exit $LASTEXITCODE'
        foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code)))) { $info.ArgumentList.Add($argument) }
        $info.Environment['HEXAGON_LIFECYCLE_NATIVE_ARGS'] = ConvertTo-Json -InputObject @($Arguments) -Compress
    }
}

function Test-LifecycleAmbientVariable([string] $Name) {
    return ($Name -like 'ARM_*' -and $Name -notin @('ARM_SUBSCRIPTION_ID', 'ARM_TENANT_ID'))
}

Export-ModuleMember -Function @()
