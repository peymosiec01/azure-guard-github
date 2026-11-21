param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [ValidateRange(24, 8760)]
    [int]$Hours = 72,

    [switch]$Delete,

    [string]$WebhookUrl = $env:AZURE_GUARD_WEBHOOK,

    [ValidateRange(5, 120)]
    [int]$DeletionTimeoutMinutes = 30
)

$ErrorActionPreference = 'Stop'

$CognitiveServicesApiVersion = '2024-10-01'
$DisposableResourceGroupPattern = '^rg-.*-(ephemeral|sandbox|temp)(-|$)'

function Write-GuardMessage {
    param([Parameter(Mandatory)][string]$Message)
    Write-Output $Message
    if ($WebhookUrl) {
        try {
            $body = @{ text = $Message } | ConvertTo-Json -Depth 4
            Invoke-RestMethod -Uri $WebhookUrl -Method Post -ContentType 'application/json' -Body $body | Out-Null
        }
        catch { Write-Warning "Webhook notification failed: $($_.Exception.Message)" }
    }
}

function Invoke-AzJson {
    param([Parameter(Mandatory)][scriptblock]$Command,[Parameter(Mandatory)][string]$FailureMessage)
    $raw = & $Command 2>&1
    if ($LASTEXITCODE -ne 0) { throw "${FailureMessage}: $($raw | Out-String)" }
    $text = $raw | Out-String
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }
    return $text | ConvertFrom-Json
}

function Test-TrueTag {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $false }
    return ([string]$Value).Equals('true',[System.StringComparison]::OrdinalIgnoreCase)
}

function Remove-ModelDeployments {
    param([Parameter(Mandatory)][string]$ResourceGroupName,[Parameter(Mandatory)][string]$AccountName)
    $deployments = Invoke-AzJson -FailureMessage "Cannot list model deployments for $AccountName" -Command {
        az cognitiveservices account deployment list --resource-group $ResourceGroupName --name $AccountName --output json
    }
    $deployments = @($deployments)
    if ($deployments.Count -eq 0) { Write-Output "No model deployments found for $AccountName"; return }
    foreach ($deployment in $deployments) {
        $deploymentName = [string]$deployment.name
        if ([string]::IsNullOrWhiteSpace($deploymentName)) { throw "A deployment without a name was returned for $AccountName" }
        Write-Output "Deleting model deployment $deploymentName from $AccountName"
        az cognitiveservices account deployment delete --resource-group $ResourceGroupName --name $AccountName --deployment-name $deploymentName --output none
        if ($LASTEXITCODE -ne 0) { throw "Failed to delete deployment $deploymentName from $AccountName" }
    }
}

function Wait-ResourceGroupDeletion {
    param([Parameter(Mandatory)][string]$ResourceGroupName,[Parameter(Mandatory)][int]$TimeoutMinutes)
    $deadline = [datetime]::UtcNow.AddMinutes($TimeoutMinutes)
    while ([datetime]::UtcNow -lt $deadline) {
        $existsRaw = az group exists --name $ResourceGroupName --output tsv 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Unable to check deletion state for $ResourceGroupName" }
        if (([string]$existsRaw).Trim() -eq 'false') { return }
        Write-Output "Waiting for resource group deletion: $ResourceGroupName"
        Start-Sleep -Seconds 20
    }
    throw "Timed out waiting for resource group deletion: $ResourceGroupName"
}

function Get-DeletedCognitiveServicesAccount {
    param([Parameter(Mandatory)][string]$AccountName,[Parameter(Mandatory)][string]$Location,[Parameter(Mandatory)][string]$OriginalResourceGroup)
    $deletedAccounts = Invoke-AzJson -FailureMessage 'Cannot list soft-deleted Cognitive Services accounts' -Command {
        az cognitiveservices account list-deleted --output json
    }
    return @($deletedAccounts | Where-Object {
        $_.name -eq $AccountName -and $_.location -eq $Location -and (-not $_.resourceGroup -or $_.resourceGroup -eq $OriginalResourceGroup)
    }) | Select-Object -First 1
}

function Wait-DeletedCognitiveServicesAccount {
    param([Parameter(Mandatory)][string]$AccountName,[Parameter(Mandatory)][string]$Location,[Parameter(Mandatory)][string]$OriginalResourceGroup,[Parameter(Mandatory)][int]$TimeoutMinutes)
    $deadline = [datetime]::UtcNow.AddMinutes($TimeoutMinutes)
    while ([datetime]::UtcNow -lt $deadline) {
        $deletedAccount = Get-DeletedCognitiveServicesAccount -AccountName $AccountName -Location $Location -OriginalResourceGroup $OriginalResourceGroup
        if ($deletedAccount) { return $deletedAccount }
        Write-Output "Waiting for $AccountName to enter soft-delete"
        Start-Sleep -Seconds 20
    }
    throw "Timed out waiting for $AccountName to enter soft-delete"
}

function Remove-DeletedCognitiveServicesAccount {
    param([Parameter(Mandatory)][string]$AccountName,[Parameter(Mandatory)][string]$Location,[Parameter(Mandatory)][string]$OriginalResourceGroup)
    $purgeUrl = ("https://management.azure.com/subscriptions/{0}" + "/providers/Microsoft.CognitiveServices/locations/{1}" + "/resourceGroups/{2}/deletedAccounts/{3}" + "?api-version={4}") -f (
        [uri]::EscapeDataString($SubscriptionId),[uri]::EscapeDataString($Location),[uri]::EscapeDataString($OriginalResourceGroup),[uri]::EscapeDataString($AccountName),$CognitiveServicesApiVersion
    )
    Write-Output "Purging soft-deleted Cognitive Services account: $AccountName"
    $purgeResult = az rest --method DELETE --url $purgeUrl --output none 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Failed to purge ${AccountName}: $($purgeResult | Out-String)" }
}

function Wait-CognitiveServicesPurge {
    param([Parameter(Mandatory)][string]$AccountName,[Parameter(Mandatory)][string]$Location,[Parameter(Mandatory)][string]$OriginalResourceGroup,[Parameter(Mandatory)][int]$TimeoutMinutes)
    $deadline = [datetime]::UtcNow.AddMinutes($TimeoutMinutes)
    while ([datetime]::UtcNow -lt $deadline) {
        $deletedAccount = Get-DeletedCognitiveServicesAccount -AccountName $AccountName -Location $Location -OriginalResourceGroup $OriginalResourceGroup
        if (-not $deletedAccount) { return }
        Write-Output "Waiting for purge to complete: $AccountName"
        Start-Sleep -Seconds 20
    }
    throw "Timed out waiting for purge to complete: $AccountName"
}

az account set --subscription $SubscriptionId | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Cannot select subscription' }

$now = [datetime]::UtcNow
$cutoff = $now.AddHours(-$Hours)
$groups = Invoke-AzJson -FailureMessage 'Cannot list resource groups' -Command { az group list --output json }

foreach ($rg in @($groups)) {
    try {
        $tags = $rg.tags
        if (-not $tags) { continue }
        if (-not (Test-TrueTag -Value $tags.AutoCleanup)) { continue }
        if (Test-TrueTag -Value $tags.Protect) { Write-Output "SKIP $($rg.name): Protect=true"; continue }
        if ($rg.name -notmatch $DisposableResourceGroupPattern) { Write-Output "SKIP $($rg.name): name is not in disposable allowlist $DisposableResourceGroupPattern"; continue }
        if (-not $tags.CreatedUtc) { Write-Warning "SKIP $($rg.name): missing CreatedUtc tag"; continue }

        $created = [datetime]::Parse([string]$tags.CreatedUtc,[System.Globalization.CultureInfo]::InvariantCulture,[System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        if ($created -gt $cutoff) { continue }

        $start = $cutoff.ToString('yyyy-MM-ddTHH:mm:ssZ')
        $end = $now.ToString('yyyy-MM-ddTHH:mm:ssZ')
        $eventsRaw = az monitor activity-log list --resource-group $rg.name --start-time $start --end-time $end --max-events 1000 --output json 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Warning "SKIP $($rg.name): activity query failed"; continue }
        $events = @(($eventsRaw | Out-String | ConvertFrom-Json))
        if ($events.Count -gt 0) { Write-Output "SKIP $($rg.name): $($events.Count) activity events within $Hours hours"; continue }

        $locks = Invoke-AzJson -FailureMessage "Lock check failed for $($rg.name)" -Command { az lock list --resource-group $rg.name --output json }
        if (@($locks).Count -gt 0) { Write-Output "SKIP $($rg.name): locked"; continue }

        $resources = @(Invoke-AzJson -FailureMessage "Resource enumeration failed for $($rg.name)" -Command { az resource list --resource-group $rg.name --output json })
        $protectedResources = @($resources | Where-Object { $_.tags -and (Test-TrueTag -Value $_.tags.Protect) })
        if ($protectedResources.Count -gt 0) { Write-Output "SKIP $($rg.name): protected resource"; continue }

        $cognitiveAccounts = @($resources | Where-Object { $_.type -eq 'Microsoft.CognitiveServices/accounts' } | ForEach-Object {
            [pscustomobject]@{ Name=[string]$_.name; Location=[string]$_.location; ResourceGroup=[string]$rg.name }
        })

        $action = if ($Delete) { 'DELETE' } else { 'PREVIEW' }
        $message = "$action group=$($rg.name) resources=$($resources.Count) cognitiveAccounts=$($cognitiveAccounts.Count) CreatedUtc=$($tags.CreatedUtc) idleWindowHours=$Hours"
        Write-GuardMessage -Message $message

        if (-not $Delete) {
            foreach ($account in $cognitiveAccounts) { Write-Output "PREVIEW purge-after-delete account=$($account.Name) location=$($account.Location)" }
            continue
        }

        foreach ($account in $cognitiveAccounts) { Remove-ModelDeployments -ResourceGroupName $account.ResourceGroup -AccountName $account.Name }
        Write-Output "Deleting resource group: $($rg.name)"
        az group delete --name $rg.name --yes --no-wait --output none
        if ($LASTEXITCODE -ne 0) { throw "Deletion submission failed for $($rg.name)" }
        Write-Output "Deletion requested: $($rg.name)"
        Wait-ResourceGroupDeletion -ResourceGroupName $rg.name -TimeoutMinutes $DeletionTimeoutMinutes
        Write-Output "Resource-group deletion confirmed: $($rg.name)"

        foreach ($account in $cognitiveAccounts) {
            Wait-DeletedCognitiveServicesAccount -AccountName $account.Name -Location $account.Location -OriginalResourceGroup $account.ResourceGroup -TimeoutMinutes $DeletionTimeoutMinutes | Out-Null
            Remove-DeletedCognitiveServicesAccount -AccountName $account.Name -Location $account.Location -OriginalResourceGroup $account.ResourceGroup
            Wait-CognitiveServicesPurge -AccountName $account.Name -Location $account.Location -OriginalResourceGroup $account.ResourceGroup -TimeoutMinutes $DeletionTimeoutMinutes
            Write-GuardMessage -Message "PURGED account=$($account.Name) location=$($account.Location) originalGroup=$($account.ResourceGroup)"
        }

        Write-GuardMessage -Message "DELETE CONFIRMED group=$($rg.name) purgedCognitiveAccounts=$($cognitiveAccounts.Count)"
    }
    catch { Write-Warning "SKIP/FAILED $($rg.name): $($_.Exception.Message)" }
}
