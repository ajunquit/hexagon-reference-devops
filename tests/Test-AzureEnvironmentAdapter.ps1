<#
.SYNOPSIS
    Tests Git snapshots, native Terraform plans and Azure HTTP protocol recovery without cloud changes.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repository 'scripts/TerraformAzureLifecycle.psm1') -Force
Import-Module (Join-Path $repository 'scripts/EnvironmentLifecycle.psm1')
Import-Module (Join-Path $repository 'scripts/EnvironmentSnapshot.psm1')
Import-Module (Join-Path $repository 'scripts/AzureEnvironmentStore.psm1')
Import-Module (Join-Path $repository 'scripts/LifecycleNative.psm1')
Import-Module (Join-Path $repository 'scripts/PlatformBootstrap.psm1')
if (-not ('Hexagon.LifecycleTests.LifecycleHttpHandler' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'LifecycleHttpHandler.cs') }
$parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
$temporary = Join-Path $parent "hexagon-azure-lifecycle-tests-$([guid]::NewGuid().ToString('N'))"
[IO.Directory]::CreateDirectory($temporary) | Out-Null
$script:assertions = 0
function Assert-True([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message }; $script:assertions++ }
function Assert-Rejected([scriptblock] $Action, [string] $Code) {
    try { & $Action | Out-Null }
    catch { Assert-True ($_.Exception.Message -like "*$Code*") "Unexpected rejection: $($_.Exception.Message)"; return }
    throw "Expected rejection: $Code"
}
function Copy-Value([object] $Value) { return (ConvertTo-PlatformBootstrapJson $Value) | ConvertFrom-Json -AsHashtable -Depth 64 }
function Write-Json([string] $Path, [object] $Value) { [IO.File]::WriteAllText($Path, (ConvertTo-PlatformBootstrapJson $Value) + "`n") }
function Invoke-Git([string[]] $Arguments) {
    $result = Invoke-LifecycleCommand git $Arguments $source -TimeoutSeconds 30
    if ($result.exitCode -ne 0) { throw 'Fixture Git command failed.' }
    return $result
}
function Set-ArmRoute([string] $Uri, [object] $Value, [int] $Status = 200) { $handler.Route('GET', $Uri, $Status, (ConvertTo-PlatformBootstrapJson $Value)) }
function Write-Zip([string] $Path, [hashtable] $Files) {
    $zip = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
    try { foreach ($name in $Files.Keys) { $stream = $zip.CreateEntry($name).Open(); try { $stream.Write($Files[$name]) } finally { $stream.Dispose() } } }
    finally { $zip.Dispose() }
}
$changedEnvironment = @('GITHUB_ACTIONS', 'GITHUB_EVENT_NAME', 'GITHUB_REF', 'GITHUB_REPOSITORY', 'GITHUB_WORKFLOW_REF', 'TF_CLI_ARGS')
$savedEnvironment = @{}; foreach ($name in $changedEnvironment) { $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name) }
$storeModule = Get-Module AzureEnvironmentStore
$adapterModule = Get-Module TerraformAzureLifecycle
try {
    # A real local Git history proves snapshot trust independently of the storage double.
    $source = Join-Path $temporary 'source'; [IO.Directory]::CreateDirectory($source) | Out-Null
    $inventory = Get-Content -Raw -LiteralPath (Join-Path $repository 'examples/environment-inventory.json') | ConvertFrom-Json -AsHashtable
    foreach ($prefix in @($inventory.roots | ForEach-Object { Get-SnapshotRootPaths $_.id dev } | Sort-Object -Unique)) {
        $destination = Join-Path $source $prefix; [IO.Directory]::CreateDirectory($destination) | Out-Null
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $repository $prefix) -File -Force | Where-Object { $_.Name -match '[.]tf$|^[.]terraform[.]lock[.]hcl$' }) { Copy-Item -LiteralPath $file.FullName -Destination $destination }
    }
    Invoke-Git @('init', '-b', 'main') | Out-Null
    Invoke-Git @('config', 'user.email', 'fixture@example.invalid') | Out-Null
    Invoke-Git @('config', 'user.name', 'Lifecycle fixture') | Out-Null
    Invoke-Git @('remote', 'add', 'origin', 'https://github.com/example-owner/hexagon-template-devops.git') | Out-Null
    Invoke-Git @('add', '.') | Out-Null; Invoke-Git @('commit', '-m', 'Fixture source') | Out-Null
    $commit = (Invoke-Git @('rev-parse', 'HEAD')).text.Trim(); $inventory.iac.commit = $commit
    $inputs = Join-Path $temporary 'inputs'; [IO.Directory]::CreateDirectory($inputs) | Out-Null
    foreach ($root in $inventory.roots) { Write-Json (Join-Path $inputs "$($root.id).tfvars.json") @{ product = $inventory.product; environment = 'dev'; resource_group_name = $root.resourceGroup } }
    $archive = Join-Path $temporary 'snapshot.zip'
    $inventory = New-LifecycleSnapshot $inventory $source $commit $inputs $archive -Confirm:$false
    $snapshot = Read-LifecycleSnapshot $inventory $archive $source $commit
    Assert-True ($snapshot.manifest.commit -ceq $commit -and $snapshot.manifest.files.Count -gt 15) 'Snapshot did not contain the pinned Terraform roots.'
    $secondArchive = Join-Path $temporary 'snapshot-second.zip'
    $second = New-LifecycleSnapshot $inventory $source $commit $inputs $secondArchive -Confirm:$false
    Assert-True ($second.iac.snapshotSha256 -ceq $inventory.iac.snapshotSha256) 'Snapshot creation was not deterministic.'
    $directory = Join-Path $temporary 'extracted'; Expand-LifecycleSnapshot $snapshot $directory -Confirm:$false
    Assert-True ((Get-LifecycleFileHash (Join-Path $directory 'terraform/environments/dev/hosting-azure/main.tf')) -ceq $snapshot.manifest.files['terraform/environments/dev/hosting-azure/main.tf']) 'Extraction changed trusted Git bytes.'
    $bad = Copy-Value $inventory; $bad.iac.snapshotSha256 = 'f' * 64
    Assert-Rejected { Read-LifecycleSnapshot $bad $archive $source $commit } 'snapshotHashMismatch'
    $bad = Copy-Value $inventory; $bad.iac.repository = 'foreign/hexagon-template-devops'
    Assert-Rejected { Read-LifecycleSnapshot $bad $archive $source $commit } 'snapshotRepositoryMismatch'
    $malicious = Join-Path $temporary 'traversal.zip'; Write-Zip $malicious @{ '../outside.tf' = [Text.Encoding]::UTF8.GetBytes('blocked') }
    $bad = Copy-Value $inventory; $bad.iac.snapshotSha256 = Get-LifecycleFileHash $malicious
    Assert-Rejected { Read-LifecycleSnapshot $bad $malicious $source $commit } 'snapshotEntryInvalid'
    $forgedFiles = @{}; foreach ($key in $snapshot.files.Keys) { $forgedFiles[$key] = $snapshot.files[$key] }
    $forgedManifest = Copy-Value $snapshot.manifest
    $forgedFiles['terraform/environments/dev/hosting-azure/main.tf'] = [Text.Encoding]::UTF8.GetBytes('# modified outside trusted Git')
    $forgedManifest.files['terraform/environments/dev/hosting-azure/main.tf'] = Get-LifecycleBytesHash $forgedFiles['terraform/environments/dev/hosting-azure/main.tf']
    $forgedFiles['manifest.json'] = [Text.Encoding]::UTF8.GetBytes((ConvertTo-PlatformBootstrapJson $forgedManifest))
    $forged = Join-Path $temporary 'forged.zip'; Write-Zip $forged $forgedFiles
    $bad = Copy-Value $inventory; $bad.iac.snapshotSha256 = Get-LifecycleFileHash $forged
    Assert-Rejected { Read-LifecycleSnapshot $bad $forged $source $commit } 'snapshotSourceChanged'
    $whatIfArchive = Join-Path $temporary 'whatif.zip'
    New-LifecycleSnapshot $inventory $source $commit $inputs $whatIfArchive -WhatIf | Out-Null
    Assert-True (-not (Test-Path -LiteralPath $whatIfArchive)) 'Snapshot WhatIf wrote an archive.'

    # A real Terraform saved plan and show exercise binary/JSON transport without any apply.
    $nativeRoot = Join-Path $temporary 'native-plan'; [IO.Directory]::CreateDirectory($nativeRoot) | Out-Null
    [IO.File]::WriteAllText((Join-Path $nativeRoot 'main.tf'), 'resource "terraform_data" "fixture" { input = "public-test-value" }')
    foreach ($arguments in @(@('init', '-input=false', '-no-color'), @('plan', '-input=false', '-no-color', '-out=fixture.tfplan'))) {
        $result = Invoke-LifecycleCommand terraform $arguments $nativeRoot -TimeoutSeconds 45
        Assert-True ($result.exitCode -eq 0) 'Native Terraform plan preparation failed.'
    }
    $shown = Invoke-LifecycleCommand terraform @('show', '-json', 'fixture.tfplan') $nativeRoot -TimeoutSeconds 30
    Assert-True ($shown.exitCode -eq 0 -and ($shown.text | ConvertFrom-Json).complete) 'Native Terraform plan JSON was incomplete.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $nativeRoot 'terraform.tfstate'))) 'The native plan smoke test created state.'

    $inventory.roots = @($inventory.roots[0])
    $archive = Join-Path $temporary 'hosting-only.zip'
    $inventory = New-LifecycleSnapshot $inventory $source $commit $inputs $archive -Confirm:$false
    $snapshot = Read-LifecycleSnapshot $inventory $archive $source $commit
    $directory = Join-Path $temporary 'hosting-only'; Expand-LifecycleSnapshot $snapshot $directory -Confirm:$false

    # Only Azure CLI acquisition and HttpClient construction are substituted. Production token context,
    # request, lease, conditional write, response parsing and endpoint fencing code execute unchanged.
    $handler = [Hexagon.LifecycleTests.LifecycleHttpHandler]::new()
    & $storeModule {
        param($Fixture, $Inventory)
        $script:httpFixture = $Fixture; $script:accountFixture = $Inventory; $script:wrongTokenTenant = $false
        function script:New-AzureLifecycleHttpClient { return [Net.Http.HttpClient]::new($script:httpFixture, $false) }
        function script:Invoke-LifecycleCommand {
            param($Tool, $Arguments, $Directory, $Environment, $TimeoutSeconds)
            $target = $script:accountFixture.target
            if ($Arguments -contains 'get-access-token') {
                $claims = @{ appid = $target.clientId; tid = $(if ($script:wrongTokenTenant) { '99999999-9999-9999-9999-999999999999' } else { $target.tenantId }); oid = '44444444-4444-4444-4444-444444444444' } | ConvertTo-Json -Compress
                $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($claims)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
                return @{ exitCode = 0; text = (@{ accessToken = "fixture.$payload.signature"; expires_on = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 300 } | ConvertTo-Json) }
            }
            return @{ exitCode = 0; text = (@{ id = $target.subscriptionId; tenantId = $target.tenantId; environmentName = 'AzureCloud'; state = 'Enabled'; user = @{ type = 'servicePrincipal'; name = $target.clientId } } | ConvertTo-Json) }
        }
    } $handler $inventory
    $context = New-AzureLifecycleContext $inventory
    Enter-AzureLifecycleLease $context -WhatIf
    Assert-True ($handler.Requests.Count -eq 0) 'Lease WhatIf performed HTTP requests.'
    Enter-AzureLifecycleLease $context -Confirm:$false
    Assert-True ($context.leaseId -ceq $handler.LeaseId) 'Blob lease ownership was not recorded.'
    $contender = New-AzureLifecycleContext $inventory
    Assert-Rejected { Enter-AzureLifecycleLease $contender -Confirm:$false } 'inventoryLocked'
    $requestCount = $handler.Requests.Count
    foreach ($uri in @('https://evil.example/steal', 'https://sthexagontemplatestate.blob.core.windows.net/tfstate-prod/foreign', "https://sthexagontemplatestate.blob.core.windows.net/tfstate-dev/hexagon-template/dev/persistent/inventory.json", "https://management.azure.com/subscriptions/$($inventory.target.subscriptionId)/resourceGroups/foreign?api-version=2024-03-01")) {
        Assert-Rejected { Invoke-AzureLifecycleHttp $context GET $uri } 'endpointInvalid'
    }
    Assert-True ($requestCount -eq $handler.Requests.Count) 'Invalid endpoints received authorization headers.'
    & $storeModule { $script:wrongTokenTenant = $true }
    Assert-Rejected { Invoke-AzureLifecycleHttp $context GET "https://management.azure.com/subscriptions/$($inventory.target.subscriptionId)/resourceGroups/$($inventory.roots[0].resourceGroup)?api-version=2024-03-01" } 'tokenContextMismatch'
    & $storeModule { $script:wrongTokenTenant = $false }
    Assert-True ($null -eq (Get-AzureLifecycleJournal $context)) 'An absent journal was fabricated.'
    $snapshotKey = "$($context.prefix)/snapshots/$($inventory.iac.snapshotSha256).zip"
    Publish-AzureLifecycleObject $context $snapshotKey ([IO.File]::ReadAllBytes($archive)) $inventory.iac.snapshotSha256 -Confirm:$false
    Publish-AzureLifecycleObject $context $snapshotKey ([IO.File]::ReadAllBytes($archive)) $inventory.iac.snapshotSha256 -Confirm:$false
    $inventoryPath = Join-Path $temporary 'inventory.json'; New-EnvironmentInventory $inventory $inventoryPath -Confirm:$false | Out-Null
    $saved = Save-AzureLifecycleJournal $context $inventoryPath -Confirm:$false
    Assert-True ($saved.durable -and $context.remoteRevision -eq 0) 'Initial inventory was not read back after persistence.'
    Assert-Rejected { Save-AzureLifecycleJournal $context $inventoryPath -Confirm:$false } 'journalRevisionMismatch'
    $wrong = [Text.Encoding]::UTF8.GetBytes('changed')
    Assert-Rejected { Publish-AzureLifecycleObject $context $snapshotKey $wrong (Get-LifecycleBytesHash $wrong) -Confirm:$false } 'objectNotDurable'
    $journalKey = "/$($inventory.target.container)/$($context.prefix)/inventory.json"
    $currentEtag = $handler.Etags[$journalKey]
    $next = Copy-Value $inventory; $next.revision++; Write-Json $inventoryPath $next
    $handler.Etags[$journalKey] = '"foreign-writer"'
    Assert-Rejected { Save-AzureLifecycleJournal $context $inventoryPath -Confirm:$false } 'journalConflict'
    $handler.Etags[$journalKey] = $currentEtag
    $handler.WriteFailure = 403
    Assert-Rejected { Save-AzureLifecycleJournal $context $inventoryPath -Confirm:$false } 'journalConflict'
    $handler.WriteFailure = 0
    Write-Json $inventoryPath $inventory
    Get-AzureLifecycleJournal $context | Out-Null
    $owner = $handler.LeaseId; $handler.LeaseId = [guid]::NewGuid().ToString()
    Assert-Rejected { Assert-AzureLifecycleLease $context -Confirm:$false } 'leaseLost'
    $handler.LeaseId = $owner

    # Trusted bootstrap roles are retained while workload resources are observed independently.
    $root = $inventory.roots[0]; $scopeId = "/subscriptions/$($inventory.target.subscriptionId)/resourceGroups/$($root.resourceGroup)"
    $scopeUri = "https://management.azure.com$scopeId"
    Set-ArmRoute "$scopeUri`?api-version=2024-03-01" @{ id = $scopeId; tags = @{ product = $inventory.product; environment = 'dev'; 'managed-by' = 'terraform'; instance = $inventory.instance.id } }
    $delegated = '7f951dda-4ed3-4680-a7ca-43fe172d538d, 4633458b-17de-408a-b874-0445c86b69e6, 69a216fc-b8fb-44d8-bc22-1f3c2cd27a39, 4f6d3b9b-027b-4f4c-9142-0e7da12a66a2'
    $condition = @('delete', 'write' | ForEach-Object { $attribute = $(if ($_ -ceq 'delete') { 'Resource' } else { 'Request' }); "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/$_'})) OR (@$attribute[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$delegated} AND @$attribute[Microsoft.Authorization/roleAssignments:PrincipalType] ForAnyOfAnyValues:StringEqualsIgnoreCase {'ServicePrincipal'}))" }) -join ' AND '
    $roles = @(); foreach ($definition in @('b24988ac-6180-42a0-ab88-20f7382dd24c', 'f58310d9-a9f6-439a-9e8d-f62e7b41a168')) {
        $roles += @{ id = "$scopeId/providers/Microsoft.Authorization/roleAssignments/$definition"; properties = @{ scope = $scopeId; principalId = '44444444-4444-4444-4444-444444444444'; principalType = 'ServicePrincipal'; roleDefinitionId = "/subscriptions/$($inventory.target.subscriptionId)/providers/Microsoft.Authorization/roleDefinitions/$definition"; conditionVersion = '2.0'; condition = $(if ($definition -like 'f583*') { $condition } else { $null }) } }
    }
    Set-ArmRoute "$scopeUri/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" @{ value = $roles }
    Set-ArmRoute "$scopeUri/resources?api-version=2021-04-01" @{ value = @() }
    $scope = Get-AzureLifecycleScope $context $root
    Assert-True ($scope.retained.Count -eq 2 -and $scope.remaining.Count -eq 0) 'Bootstrap assignments were counted as workload resources.'
    $inherited = Copy-Value $roles[0]
    $inherited.properties.scope = "/subscriptions/$($inventory.target.subscriptionId)"
    $inherited.id = "$($inherited.properties.scope)/providers/Microsoft.Authorization/roleAssignments/66666666-6666-6666-6666-666666666666"
    $inherited.properties.principalId = '77777777-7777-7777-7777-777777777777'
    Set-ArmRoute "$scopeUri/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" @{ value = @($roles) + @($inherited) }
    $scope = Get-AzureLifecycleScope $context $root
    Assert-True ($scope.remaining.Count -eq 0 -and $scope.retained.Count -eq 2) 'Inherited platform permissions were treated as workload resources.'
    $inherited.properties.principalId = $context.actorId
    Set-ArmRoute "$scopeUri/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" @{ value = @($roles) + @($inherited) }
    Assert-Rejected { Get-AzureLifecycleScope $context $root } 'inheritedActorRole'
    $unexpectedActorRole = Copy-Value $roles[0]
    $unexpectedActorRole.id = "$scopeId/providers/Microsoft.Authorization/roleAssignments/88888888-8888-8888-8888-888888888888"
    $unexpectedActorRole.properties.roleDefinitionId = '/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635'
    Set-ArmRoute "$scopeUri/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" @{ value = @($roles) + @($unexpectedActorRole) }
    Assert-Rejected { Get-AzureLifecycleScope $context $root } 'unexpectedActorRole'
    $badRoles = Copy-Value $roles; $badRoles[1].properties.condition = ''
    Set-ArmRoute "$scopeUri/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" @{ value = $badRoles }
    Assert-Rejected { Get-AzureLifecycleScope $context $root } 'delegationConditionMismatch'
    Set-ArmRoute "$scopeUri/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01" @{ value = $roles }
    Set-ArmRoute "$scopeUri/resources?api-version=2021-04-01" @{ value = @(); nextLink = 'https://evil.example/page2' }
    Assert-Rejected { Get-AzureLifecycleScope $context $root } 'paginationInvalid'
    Set-ArmRoute "$scopeUri/resources?api-version=2021-04-01" @{} 403
    Assert-Rejected { Get-AzureLifecycleScope $context $root } 'collectionUnavailable'
    Set-ArmRoute "$scopeUri/resources?api-version=2021-04-01" @{ value = @() }

    # Engine + native adapter + real HTTP parsing; only Terraform's cloud execution is simulated.
    $single = Copy-Value $inventory; $single.roots = @($single.roots[0])
    $context.inventory = $single; $context.snapshot = $snapshot; $context.directory = $directory; $context.runtime = Join-Path $temporary 'runtime'
    [IO.Directory]::CreateDirectory($context.runtime) | Out-Null
    Write-Json $inventoryPath $single
    $handler.Blobs[$journalKey] = [IO.File]::ReadAllBytes($inventoryPath); Get-AzureLifecycleJournal $context | Out-Null
    $resourceId = "$scopeId/providers/Microsoft.Network/virtualNetworks/fixture"
    $stateKey = "/$($single.target.container)/$($root.stateKey)"
    $cloudFixture = @{ handler = $handler; context = $context; terraformVersion = $snapshot.manifest.terraformVersion; resourceId = $resourceId; stateKey = $stateKey; journalKey = $journalKey; scopeUri = $scopeUri; planJson = $null; operation = 'Create'; serial = 0; commands = [Collections.Generic.List[object]]::new(); failApply = $false }
    & $adapterModule {
        param($Fixture)
        $script:cloudFixture = $Fixture
        function script:Invoke-LifecycleCommand {
            param($Tool, $Arguments, $Directory, $Environment, $TimeoutSeconds, $Heartbeat)
            $fixture = $script:cloudFixture; $fixture.commands.Add(@{ arguments = $Arguments; environment = $Environment })
            if ($Tool -ceq 'az') {
                if ($Arguments -contains 'deactivate') {
                    $fixture.handler.Route('GET', "https://management.azure.com$($fixture.activeApp)/revisions?api-version=2024-03-01", 200, '{"value":[{"name":"fixture--one","properties":{"active":false}}]}')
                }
                elseif ($Arguments -contains 'servicebus') {
                    $fixture.handler.Route('GET', "https://management.azure.com$($fixture.namespace)/topics?api-version=2024-01-01", 200, (@{ value = @(@{ id = $fixture.topic; properties = @{ status = 'Disabled' } }) } | ConvertTo-Json -Depth 8))
                    $fixture.handler.Route('GET', "https://management.azure.com$($fixture.topic)/subscriptions?api-version=2024-01-01", 200, '{"value":[]}')
                }
                else { throw 'Unexpected quiescence command.' }
                $text = ''
            }
            elseif ($Arguments -contains 'version') { $text = @{ terraform_version = $fixture.terraformVersion } | ConvertTo-Json -Compress }
            elseif ($Arguments -contains 'show') { $text = $fixture.planJson }
            elseif ($Arguments -contains 'plan') {
                foreach ($argument in $Arguments) { if ($argument.StartsWith('-out=')) { [IO.File]::WriteAllText($argument.Substring(5), "fixture-binary-$($fixture.operation)") } }
                $text = ''
            }
            elseif ($Arguments -contains 'apply') {
                $durable = [Text.Encoding]::UTF8.GetString($fixture.handler.Blobs[$fixture.journalKey]) | ConvertFrom-Json -AsHashtable
                if ($durable.roots[0].status -cnotin @('Applying', 'Destroying')) { throw 'Missing durable intent before Terraform apply.' }
                $resources = @(); $armResources = @(); $presence = 404
                if ($fixture.operation -ceq 'Create') {
                    $resources = @(@{ mode = 'managed'; type = 'azurerm_virtual_network'; name = 'fixture'; instances = @(@{ attributes = @{ id = $fixture.resourceId } }) })
                    $armResources = @(@{ id = $fixture.resourceId; type = 'Microsoft.Network/virtualNetworks' }); $presence = 200
                }
                $fixture.serial++
                $state = @{ version = 4; lineage = '55555555-5555-5555-5555-555555555555'; serial = $fixture.serial; resources = $resources }
                $fixture.handler.Blobs[$fixture.stateKey] = [Text.Encoding]::UTF8.GetBytes(($state | ConvertTo-Json -Depth 32))
                $fixture.handler.Etags[$fixture.stateKey] = '"state-' + $state.serial + '"'
                $fixture.handler.Route('GET', "$($fixture.scopeUri)/resources?api-version=2021-04-01", 200, (@{ value = $armResources } | ConvertTo-Json -Depth 12))
                $fixture.handler.Route('GET', "https://management.azure.com$($fixture.resourceId)?api-version=2024-05-01", $presence, '{}')
                if ($fixture.failApply) { return @{ exitCode = 1; text = ''; bytes = [byte[]]::new(0) } }
                $text = ''
            }
            else { $text = '' }
            return @{ exitCode = 0; text = $text; bytes = [Text.Encoding]::UTF8.GetBytes($text) }
        }
    } $cloudFixture
    $env:GITHUB_ACTIONS = 'true'; $env:GITHUB_EVENT_NAME = 'workflow_dispatch'; $env:GITHUB_REF = 'refs/heads/main'
    $env:GITHUB_REPOSITORY = $single.iac.repository; $env:GITHUB_WORKFLOW_REF = "$($single.iac.repository)/.github/workflows/genesis.yml@refs/heads/main"
    $env:TF_CLI_ARGS = $null
    Assert-AzureLifecycleRuntime $context
    $env:GITHUB_REF = 'refs/heads/feature'
    Assert-Rejected { Assert-AzureLifecycleRuntime $context } 'trustedWorkflowRequired'
    $env:GITHUB_REF = 'refs/heads/main'
    $cloudFixture.planJson = ConvertTo-PlatformBootstrapJson @{ format_version = '1.2'; complete = $true; errored = $false; resource_changes = @(@{ mode = 'managed'; address = 'azurerm_virtual_network.fixture'; type = 'azurerm_virtual_network'; change = @{ actions = @('create'); before = $null; after = @{ resource_group_name = $root.resourceGroup } } }) }
    $plan = New-AzureLifecyclePlan $context $single.roots[0] Create -Confirm:$false
    $review = Add-EnvironmentRootPlan $inventoryPath hosting Create $plan.binaryPath $plan.jsonPath (Get-LifecycleFileHash $inventoryPath) -Confirm:$false
    Save-AzureLifecycleJournal $context $inventoryPath -Confirm:$false | Out-Null
    $port = New-AzureLifecyclePort $context
    $result = Invoke-EnvironmentRootOperation $inventoryPath hosting $plan.binaryPath $plan.jsonPath $review 'CREATE hexagon-template dev run-12345-1' $port -Confirm:$false
    Assert-True ($result.status -ceq 'Verified' -and $context.remoteRevision -eq 3 -and -not $result.applicationVerified) 'Adapter creation did not persist observed resources.'
    $observed = Read-EnvironmentInventory $inventoryPath
    Assert-True ($observed.roots[0].resources[0].id -ceq $resourceId -and $observed.roots[0].stateSerial -eq 1) 'Observed state identity was not recorded.'
    $originalState = $handler.Blobs[$stateKey]
    $context.inventory = $observed
    $deployment = Get-AzureLifecycleDeploymentState $context hosting
    Assert-True ($deployment.serial -eq 1 -and $deployment.resources[0].id -ceq $resourceId) 'Deployment state was not tied to the verified inventory.'
    $context.inventory.roots[0].stateSerial = 999
    Assert-Rejected { Get-AzureLifecycleDeploymentState $context hosting } 'stateChanged'
    $context.inventory.roots[0].stateSerial = 1
    $env:GITHUB_WORKFLOW_REF = "$($single.iac.repository)/.github/workflows/delivery.yml@refs/heads/main"
    Assert-AzureLifecycleRuntime $context
    $env:GITHUB_WORKFLOW_REF = "foreign/repository/.github/workflows/delivery.yml@refs/heads/main"
    Assert-Rejected { Assert-AzureLifecycleRuntime $context } 'trustedWorkflowRequired'
    $env:GITHUB_WORKFLOW_REF = "$($single.iac.repository)/.github/workflows/genesis.yml@refs/heads/main"
    $state = [Text.Encoding]::UTF8.GetString($originalState) | ConvertFrom-Json -AsHashtable -Depth 32
    $identityId = "$scopeId/providers/Microsoft.ManagedIdentity/userAssignedIdentities/api"
    $state.resources += @{ mode = 'managed'; type = 'azurerm_user_assigned_identity'; name = 'api'; instances = @(@{ attributes = @{ id = $identityId } }) }
    $state.outputs = @{ workload_identities = @{ value = @{ api = @{ id = $identityId; principal_id = '66666666-6666-6666-6666-666666666666' } } } }
    $handler.Blobs[$stateKey] = [Text.Encoding]::UTF8.GetBytes(($state | ConvertTo-Json -Depth 32))
    $context.inventory = $observed
    Set-ArmRoute "https://management.azure.com$identityId`?api-version=2023-01-31" @{ id = $identityId; properties = @{ principalId = '66666666-6666-6666-6666-666666666666' } }
    $principals = Get-AzureLifecycleWorkloadPrincipals $context
    Assert-True ($principals.api -ceq '66666666-6666-6666-6666-666666666666') 'Raw v4 outputs without an optional sensitive flag were not resolved.'
    $state.outputs.workload_identities.sensitive = $true
    $handler.Blobs[$stateKey] = [Text.Encoding]::UTF8.GetBytes(($state | ConvertTo-Json -Depth 32))
    Assert-Rejected { Get-AzureLifecycleWorkloadPrincipals $context } 'workloadIdentitiesUnavailable'
    $state.outputs.workload_identities.sensitive = $false; $state.outputs.workload_identities.value.api.id = "$scopeId/providers/Microsoft.ManagedIdentity/userAssignedIdentities/foreign"
    $handler.Blobs[$stateKey] = [Text.Encoding]::UTF8.GetBytes(($state | ConvertTo-Json -Depth 32))
    Assert-Rejected { Get-AzureLifecycleWorkloadPrincipals $context } 'workloadIdentityInvalid'
    $handler.Blobs[$stateKey] = $originalState; $context.inventory = $single
    Assert-True (@($cloudFixture.commands | Where-Object { $_.arguments -contains 'apply' -and $_.arguments -notcontains '-auto-approve' }).Count -eq 1) 'Saved-plan apply arguments changed.'
    Assert-True (@($cloudFixture.commands | Where-Object { $null -ne $_.environment -and $_.environment.ARM_USE_CLI -ceq 'true' }).Count -gt 3) 'Terraform did not receive explicit CLI target configuration.'
    $trustedMain = Join-Path $directory 'terraform/environments/dev/hosting-azure/main.tf'
    $originalBytes = [IO.File]::ReadAllBytes($trustedMain)
    [IO.File]::AppendAllText($trustedMain, '# tampered')
    Assert-Rejected { New-AzureLifecyclePlan $context $observed.roots[0] Create -Confirm:$false } 'workspaceChanged'
    [IO.File]::WriteAllBytes($trustedMain, $originalBytes)
    $plan = New-AzureLifecyclePlan $context $observed.roots[0] Create -Confirm:$false
    $review = Add-EnvironmentRootPlan $inventoryPath hosting Create $plan.binaryPath $plan.jsonPath (Get-LifecycleFileHash $inventoryPath) -Confirm:$false
    Save-AzureLifecycleJournal $context $inventoryPath -Confirm:$false | Out-Null
    $cloudFixture.failApply = $true
    Assert-Rejected { Invoke-EnvironmentRootOperation $inventoryPath hosting $plan.binaryPath $plan.jsonPath $review 'CREATE hexagon-template dev run-12345-1' $port -Confirm:$false } 'applyFailed'
    $failed = Get-AzureLifecycleJournal $context
    Assert-True ($failed.inventory.roots[0].status -ceq 'Failed' -and $failed.inventory.revision -eq 6) 'Partial Terraform failure was not preserved remotely.'
    $cloudFixture.failApply = $false
    $synced = Sync-EnvironmentRoot $inventoryPath hosting $port -Confirm:$false
    Assert-True ($synced.status -ceq 'Verified' -and $context.remoteRevision -eq 7) 'Sync did not reconcile a partial apply using provider observations.'
    $observed = Read-EnvironmentInventory $inventoryPath
    $badContext = Copy-Value $context.inventory; $badContext.dataPolicy = 'BackupRequired'
    $context.inventory = $badContext
    Assert-Rejected { Get-AzureLifecycleDestructionSafety $context @{ root = $observed.roots[0] } } 'backupVerifierRequired'
    $context.inventory = $single
    $activeApp = "$scopeId/providers/Microsoft.App/containerApps/fixture"
    Set-ArmRoute "$scopeUri/resources?api-version=2021-04-01" @{ value = @(@{ id = $activeApp; type = 'Microsoft.App/containerApps' }) }
    Set-ArmRoute "https://management.azure.com$activeApp/revisions?api-version=2024-03-01" @{ value = @(@{ properties = @{ active = $true } }) }
    Assert-Rejected { Get-AzureLifecycleDestructionSafety $context @{ root = $observed.roots[0] } } 'applicationNotQuiesced'
    Assert-Rejected { Invoke-AzureLifecycleQuiesce $context -Confirm:$false } 'quiesceResourceUnrecorded'
    $quiesceInventory = Copy-Value $observed
    $quiesceInventory.roots[0].resources += @{ id = $activeApp; type = 'azurerm_container_app'; address = 'azurerm_container_app.fixture'; current = $true; presence = 'Present' }
    $context.inventory = $quiesceInventory; $cloudFixture.activeApp = $activeApp
    Set-ArmRoute "https://management.azure.com$activeApp/revisions?api-version=2024-03-01" @{ value = @(@{ name = 'fixture--one'; properties = @{ active = $true } }) }
    $beforeCommands = $cloudFixture.commands.Count
    Invoke-AzureLifecycleQuiesce $context -WhatIf | Out-Null
    Assert-True ($cloudFixture.commands.Count -eq $beforeCommands) 'Quiesce WhatIf executed an Azure mutation.'
    $evidence = Invoke-AzureLifecycleQuiesce $context -Confirm:$false
    Assert-True ($evidence.quiesced -and $cloudFixture.commands[$cloudFixture.commands.Count - 1].arguments -contains 'deactivate') 'Quiescence did not deactivate and re-observe the recorded revision.'
    $namespace = "$scopeId/providers/Microsoft.ServiceBus/namespaces/fixture"
    $topic = "$namespace/topics/events"
    $cloudFixture.namespace = $namespace; $cloudFixture.topic = $topic
    $quiesceInventory.roots[0].resources += @(@{ id = $namespace; type = 'azurerm_servicebus_namespace'; address = 'azurerm_servicebus_namespace.fixture'; current = $true; presence = 'Present' }, @{ id = $topic; type = 'azurerm_servicebus_topic'; address = 'azurerm_servicebus_topic.fixture'; current = $true; presence = 'Present' })
    Set-ArmRoute "$scopeUri/resources?api-version=2021-04-01" @{ value = @(@{ id = $namespace; type = 'Microsoft.ServiceBus/namespaces' }) }
    Set-ArmRoute "https://management.azure.com$namespace/topics?api-version=2024-01-01" @{ value = @(@{ id = $topic; properties = @{ status = 'Active' } }) }
    Set-ArmRoute "https://management.azure.com$topic/subscriptions?api-version=2024-01-01" @{ value = @() }
    $evidence = Invoke-AzureLifecycleQuiesce $context -Confirm:$false
    Assert-True ($evidence.quiesced -and $cloudFixture.commands[$cloudFixture.commands.Count - 1].arguments -contains 'Disabled') 'Quiescence did not disable and re-observe the recorded topic.'
    $context.inventory = $single
    Set-ArmRoute "$scopeUri/resources?api-version=2021-04-01" @{ value = @(@{ id = $resourceId; type = 'Microsoft.Network/virtualNetworks' }) }
    Set-ArmRoute "https://management.azure.com$resourceId`?api-version=2024-05-01" @{} 403
    Assert-Rejected { Get-AzureLifecycleObservation $context $observed.roots[0] Destroy } 'resourceProbeUnavailable'
    Set-ArmRoute "https://management.azure.com$resourceId`?api-version=2024-05-01" @{ id = $resourceId }
    $env:TF_CLI_ARGS = '-target=foreign'
    Assert-Rejected { New-AzureLifecyclePlan $context $observed.roots[0] Destroy -Confirm:$false } 'ambientConfiguration'
    $env:TF_CLI_ARGS = $null
    $cloudFixture.operation = 'Destroy'
    $cloudFixture.planJson = ConvertTo-PlatformBootstrapJson @{ format_version = '1.2'; complete = $true; errored = $false; resource_changes = @(@{ mode = 'managed'; address = 'azurerm_virtual_network.fixture'; type = 'azurerm_virtual_network'; change = @{ actions = @('delete'); before = @{ id = $resourceId }; after = $null } }) }
    $plan = New-AzureLifecyclePlan $context $observed.roots[0] Destroy -Confirm:$false
    $review = Add-EnvironmentRootPlan $inventoryPath hosting Destroy $plan.binaryPath $plan.jsonPath (Get-LifecycleFileHash $inventoryPath) -Confirm:$false
    Save-AzureLifecycleJournal $context $inventoryPath -Confirm:$false | Out-Null
    $result = Invoke-EnvironmentRootOperation $inventoryPath hosting $plan.binaryPath $plan.jsonPath $review 'DESTROY hexagon-template dev run-12345-1' $port -Confirm:$false
    Assert-True ($result.status -ceq 'Destroyed' -and $context.remoteRevision -eq 10) 'Destruction was not verified and persisted.'
    $destroyed = Read-EnvironmentInventory $inventoryPath
    Assert-True ($destroyed.roots[0].resources[0].presence -ceq 'Missing' -and -not $destroyed.roots[0].resources[0].current) 'Destruction discarded the resource history.'
    Exit-AzureLifecycleLease $context -Confirm:$false
    Assert-True ($null -eq $handler.LeaseId) 'Lifecycle lease was not released.'

    # A new runner recovers durable bytes with neither application artifacts nor the old workspace.
    $restoredContext = New-AzureLifecycleContext $inventory
    Enter-AzureLifecycleLease $restoredContext -Confirm:$false
    $restored = Get-AzureLifecycleJournal $restoredContext
    $restoredArchive = Join-Path $temporary 'restored.zip'
    [IO.File]::WriteAllBytes($restoredArchive, (Read-AzureLifecycleObject $restoredContext $snapshotKey $restored.inventory.iac.snapshotSha256))
    $restoredSnapshot = Read-LifecycleSnapshot $restored.inventory $restoredArchive $source $commit
    Assert-True ($restored.inventory.revision -eq 10 -and $restoredSnapshot.manifest.commit -ceq $commit) 'Remote recovery lost its verified snapshot or revision.'
    Exit-AzureLifecycleLease $restoredContext -Confirm:$false

    # Changing stage inputs preserves observed IDs, invalidates approval and is optimistic/WhatIf safe.
    $beforeHash = Get-LifecycleFileHash $inventoryPath
    Set-EnvironmentRootInputs $inventoryPath hosting ('c' * 64) ('d' * 64) $beforeHash -WhatIf
    Assert-True ((Get-LifecycleFileHash $inventoryPath) -ceq $beforeHash) 'Input update WhatIf changed inventory.'
    Set-EnvironmentRootInputs $inventoryPath hosting ('c' * 64) ('d' * 64) $beforeHash -Confirm:$false
    $updated = Read-EnvironmentInventory $inventoryPath
    Assert-True ($updated.revision -eq 11 -and $updated.roots[0].status -ceq 'Failed' -and $null -eq $updated.roots[0].plan -and $updated.roots[0].resources[0].id -ceq $resourceId -and $updated.roots[0].stateSerial -eq 3) 'Input update erased state/history or retained an approval.'
    Assert-Rejected { Set-EnvironmentRootInputs $inventoryPath hosting ('e' * 64) ('f' * 64) $beforeHash -Confirm:$false } 'inventoryChanged'
    $clearPath = Join-Path $temporary 'clear-plans.json'
    Write-Json $clearPath $observed
    $clearJson = Join-Path $temporary 'clear-plan.json'
    Write-Json $clearJson @{ format_version = '1.2'; complete = $true; errored = $false; resource_changes = @() }
    Add-EnvironmentRootPlan $clearPath hosting Create $plan.binaryPath $clearJson (Get-LifecycleFileHash $clearPath) -Confirm:$false | Out-Null
    $beforeClear = Get-LifecycleFileHash $clearPath
    Clear-EnvironmentPlans $clearPath $beforeClear -WhatIf
    Assert-True ((Get-LifecycleFileHash $clearPath) -ceq $beforeClear) 'Discarding plans in WhatIf wrote inventory.'
    Clear-EnvironmentPlans $clearPath $beforeClear -Confirm:$false
    $cleared = Read-EnvironmentInventory $clearPath
    Assert-True ($null -eq $cleared.roots[0].plan -and $cleared.roots[0].status -ceq 'Failed' -and $cleared.roots[0].resources[0].id -ceq $resourceId) 'Quiescence plan invalidation discarded resource history.'
    Assert-Rejected { New-AzureLifecyclePlan $context $single.roots[0] Create -Confirm:$false } 'leaseRequired'

    $entry = Join-Path $repository 'scripts/Invoke-AzureEnvironment.ps1'
    $unusedWorkspace = Join-Path $repository "artifacts/azure-whatif-$([guid]::NewGuid().ToString('N'))"
    $output = & pwsh -NoProfile -File $entry -Mode Initialize -Inventory (Join-Path $repository 'examples/environment-inventory.json') -Environment dev -InstanceId run-12345-1 -Workspace $unusedWorkspace -WhatIf
    Assert-True ($LASTEXITCODE -eq 2 -and ($output -join "`n" | ConvertFrom-Json).status -ceq 'Unverified' -and -not (Test-Path -LiteralPath $unusedWorkspace)) 'CLI WhatIf made changes or claimed success.'
    $buildDefinition = Copy-Value $inventory
    Invoke-Git @('update-ref', 'refs/remotes/origin/main', $commit) | Out-Null
    foreach ($path in @('scripts', 'contracts/schemas', '.config')) {
        $destination = Join-Path $source $path; [IO.Directory]::CreateDirectory($destination) | Out-Null
        Get-ChildItem -LiteralPath (Join-Path $repository $path) -File -Force | Copy-Item -Destination $destination
    }
    $buildWorkspace = Join-Path $source 'artifacts/build-cli'
    $entry = Join-Path $source 'scripts/Invoke-AzureEnvironment.ps1'
    $definitionPath = Join-Path $temporary 'build-definition.json'; Write-Json $definitionPath $buildDefinition
    $output = & pwsh -NoProfile -File $entry -Mode Build -Inventory $definitionPath -Environment dev -InstanceId run-12345-1 -Workspace $buildWorkspace -InputDirectory $inputs
    Assert-True ($LASTEXITCODE -eq 0) "CLI Build failed: $($output -join '')"
    $built = $output -join "`n" | ConvertFrom-Json
    Assert-True ($built.status -ceq 'Built' -and (Test-Path -LiteralPath (Join-Path $buildWorkspace "snapshots/$($built.details.snapshotSha256)/manifest.json"))) 'Build did not install its content-addressed snapshot.'
    if (-not $IsWindows) { Assert-True ([IO.File]::GetUnixFileMode($buildWorkspace) -eq [IO.UnixFileMode] 'UserRead,UserWrite,UserExecute') 'Build workspace was not private.' }
}
finally {
    foreach ($name in $changedEnvironment) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name]) }
    Remove-Module TerraformAzureLifecycle, AzureEnvironmentStore, EnvironmentSnapshot, LifecycleNative -Force -ErrorAction SilentlyContinue
    $resolved = [IO.Path]::GetFullPath($temporary)
    if ([IO.Path]::GetDirectoryName($resolved) -cne $parent -or -not [IO.Path]::GetFileName($resolved).StartsWith('hexagon-azure-lifecycle-tests-')) { throw 'Unsafe Azure lifecycle test cleanup.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Host "Azure lifecycle adapter tests passed: $script:assertions assertions; real Git and local Terraform plan, simulated Azure HTTP/cloud execution, no cloud changes."
