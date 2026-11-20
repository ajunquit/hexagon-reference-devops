Set-StrictMode -Version Latest

# The Azure Static Web Apps host: its control file applies the SPA fallback, the cache policy and the
# security headers that the serving checks verify. StaticWebConfiguration.psm1 discovers this module.

function Get-WebHostReservedNames { return @('staticwebapp.config.json') }

function Test-WebHostOrigin([string] $HostName) {
    return $HostName -cmatch '^[a-z0-9-]+[.](?:[a-z0-9-]+[.])?azurestaticapps[.]net$'
}

# The host files of a payload, added by the Azure delivery to the public runtime configuration.
function Get-AzureStaticWebHostFiles {
    return @{
        'staticwebapp.config.json' = @{
            navigationFallback = @{ rewrite = '/index.html'; exclude = @('/runtime-config.json', '/assets/*', '/*.{css,js,map,ico,png,svg,woff,woff2}') }
            globalHeaders = @{ 'Cache-Control' = 'no-cache'; 'X-Content-Type-Options' = 'nosniff'; 'Referrer-Policy' = 'no-referrer' }
            routes = @(@{ route = '/runtime-config.json'; headers = @{ 'Cache-Control' = 'no-store' } }, @{ route = '/index.html'; headers = @{ 'Cache-Control' = 'no-store' } })
        }
    }
}

Export-ModuleMember -Function Get-AzureStaticWebHostFiles
