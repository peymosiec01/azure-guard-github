param(
  [Parameter(Mandatory)][string]$SubscriptionId,
  [int]$Hours=72,
  [switch]$Delete,
  [string]$WebhookUrl=$env:AZURE_GUARD_WEBHOOK
)
$ErrorActionPreference='Stop'
if ($Hours -lt 24) { throw 'Minimum Hours is 24' }
az account set --subscription $SubscriptionId | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Cannot select subscription' }
$now=[datetime]::UtcNow
$cutoff=$now.AddHours(-$Hours)
$groups=az group list --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Cannot list resource groups' }
foreach($rg in $groups) {
  try {
    $tags=$rg.tags
    if (!$tags -or $tags.AutoCleanup -ne 'true' -or $tags.Protect -eq 'true') { continue }
    if ($rg.name -notmatch '^rg-(ephemeral|sandbox|temp)-') { Write-Output "SKIP $($rg.name): name is not in disposable allowlist"; continue }
    if (!$tags.CreatedUtc) { Write-Warning "SKIP $($rg.name): missing CreatedUtc tag"; continue }
    $created=[datetime]::Parse($tags.CreatedUtc).ToUniversalTime()
    if ($created -gt $cutoff) { continue }
    # A 72-hour activity query checks group-scoped management-plane writes, including child resources.
    # If activity history is unavailable, fail closed rather than guessing.
    $start=$cutoff.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $end=$now.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $eventsRaw=az monitor activity-log list --resource-group $rg.name --start-time $start --end-time $end --max-events 1000 --output json 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Warning "SKIP $($rg.name): activity query failed: $eventsRaw"; continue }
    $events=@(($eventsRaw | Out-String | ConvertFrom-Json))
    # Conservative: any event (including reads/errors) blocks deletion.
    if ($events.Count -gt 0) { Write-Output "SKIP $($rg.name): $($events.Count) activity events within $Hours hours"; continue }
    $locksRaw=az lock list --resource-group $rg.name --output json 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Warning "SKIP $($rg.name): lock check failed"; continue }
    if (@(($locksRaw | Out-String | ConvertFrom-Json)).Count -gt 0) { Write-Output "SKIP $($rg.name): locked"; continue }
    $resourcesRaw=az resource list --resource-group $rg.name --output json 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Warning "SKIP $($rg.name): resource enumeration failed"; continue }
    $resources=@(($resourcesRaw | Out-String | ConvertFrom-Json))
    # Restrict to ephemeral test resources; no resource can be explicitly protected.
    if (@($resources | Where-Object { $_.tags.Protect -eq 'true' }).Count -gt 0) { Write-Output "SKIP $($rg.name): protected resource"; continue }
    $action=if($Delete) {'DELETE'}else {'PREVIEW'}
    $message="$action group=$($rg.name) resources=$($resources.Count) CreatedUtc=$($tags.CreatedUtc) idleWindowHours=$Hours"
    Write-Output $message
    if ($WebhookUrl) { Invoke-RestMethod -Uri $WebhookUrl -Method Post -ContentType 'application/json' -Body (@{text=$message}|ConvertTo-Json) | Out-Null }
    if ($Delete) {
      az group delete --name $rg.name --yes --no-wait --output none
      if ($LASTEXITCODE -ne 0) { throw "Deletion submission failed for $($rg.name)" }
      Write-Output "Deletion REQUESTED (not yet confirmed): $($rg.name)"
    }
  } catch { Write-Warning "SKIP $($rg.name): $_" }
}
