param(
  [Parameter(Mandatory)][string]$SubscriptionId,
  [decimal]$MonthlyBudget = 0,
  [string]$WebhookUrl = $env:AZURE_GUARD_WEBHOOK
)
$ErrorActionPreference='Stop'
az account set --subscription $SubscriptionId | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Cannot select subscription' }
$body = @{ type='ActualCost'; timeframe='MonthToDate'; dataset=@{granularity='None';aggregation=@{totalCost=@{name='Cost';function='Sum'}}} } | ConvertTo-Json -Depth 8 -Compress
$url="https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.CostManagement/query?api-version=2023-03-01"
try {
  $raw=az rest --method post --url $url --headers 'Content-Type=application/json' --body $body --output json 2>&1
  if ($LASTEXITCODE -ne 0) { throw ($raw | Out-String) }
  $result=($raw | Out-String | ConvertFrom-Json)
  $columns=@($result.properties.columns | ForEach-Object name)
  $costIndex=[array]::IndexOf($columns,'Cost'); if ($costIndex -lt 0) { throw 'Cost column missing' }
  $currencyIndex=[array]::IndexOf($columns,'Currency')
  $spent=0.0; $currencies=@()
  foreach ($r in $result.properties.rows) { $spent += [double]$r[$costIndex]; if ($currencyIndex -ge 0) { $currencies+= [string]$r[$currencyIndex] } }
  $currency=(@($currencies | Select-Object -Unique) -join ','); if (!$currency) { $currency='Unknown' }
  $remaining='Not available (credits require billing-specific access)'
  $budgetLine=if($MonthlyBudget -gt 0) {"Configured monthly budget: $MonthlyBudget (compare only if same currency); budget less cost: $([math]::Round(([double]$MonthlyBudget-$spent),2))"}else {'No monthly budget configured'}
  $message="Azure daily cost report`nSubscription: $SubscriptionId`nMonth-to-date actual cost: $([math]::Round($spent,2)) $currency`n$budgetLine`nSponsorship credit balance: $remaining`nGenerated UTC: $([datetime]::UtcNow.ToString('u'))`nNote: Cost Management data may lag actual consumption."
  Write-Output $message
  if ($WebhookUrl) { Invoke-RestMethod -Uri $WebhookUrl -Method Post -ContentType 'application/json' -Body (@{text=$message}|ConvertTo-Json -Depth 4) | Out-Null }
} catch { Write-Error "Cost query failed; no zero-cost assumption made: $_"; exit 1 }
