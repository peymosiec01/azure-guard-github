param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [decimal]$MonthlyBudget = 0,

    [string]$WebhookUrl = $env:AZURE_GUARD_WEBHOOK
)

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------
# 1. Select Azure subscription
# ------------------------------------------------------------

az account set --subscription $SubscriptionId | Out-Null

if ($LASTEXITCODE -ne 0) {
    throw "Cannot select Azure subscription: $SubscriptionId"
}

# ------------------------------------------------------------
# 2. Build Cost Management request
# ------------------------------------------------------------

$query = @{
    type = 'ActualCost'
    timeframe = 'MonthToDate'
    dataset = @{
        granularity = 'None'
        aggregation = @{
            totalCost = @{
                name = 'Cost'
                function = 'Sum'
            }
        }
    }
}

$body = $query | ConvertTo-Json -Depth 8 -Compress
$url = 'https://management.azure.com/subscriptions/{0}/providers/Microsoft.CostManagement/query?api-version=2023-03-01' -f $SubscriptionId

# ------------------------------------------------------------
# 3. Query Azure Cost Management
# ------------------------------------------------------------

try {
    $accessToken = az account get-access-token `
        --resource 'https://management.azure.com/' `
        --query accessToken `
        --output tsv

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($accessToken)) {
        throw 'Unable to obtain Azure Resource Manager access token.'
    }

    $headers = @{
        Authorization = "Bearer $accessToken"
    }

    $result = Invoke-RestMethod `
        -Method Post `
        -Uri $url `
        -Headers $headers `
        -ContentType 'application/json' `
        -Body $body
}
catch {
    Write-Error ("Azure Cost Management query failed; no zero-cost assumption made: {0}" -f $_.Exception.Message)
    exit 1
}

# ------------------------------------------------------------
# 4. Parse Cost Management response
# ------------------------------------------------------------

try {
    $columns = @($result.properties.columns | ForEach-Object { $_.name })

    $costIndex = [array]::IndexOf($columns, 'Cost')
    if ($costIndex -lt 0) {
        throw 'Cost column missing from Azure Cost Management response.'
    }

    $currencyIndex = [array]::IndexOf($columns, 'Currency')
    $spent = 0.0
    $currencies = @()

    foreach ($row in $result.properties.rows) {
        $spent += [double]$row[$costIndex]

        if ($currencyIndex -ge 0) {
            $currencies += [string]$row[$currencyIndex]
        }
    }

    $currency = (@($currencies | Select-Object -Unique) -join ',')
    if ([string]::IsNullOrWhiteSpace($currency)) {
        $currency = 'Unknown'
    }
}
catch {
    Write-Error ("Azure Cost Management response parsing failed: {0}" -f $_.Exception.Message)
    exit 1
}

# ------------------------------------------------------------
# 5. Build report
# ------------------------------------------------------------

$roundedSpend = [math]::Round($spent, 2)
$remaining = 'Not available (credits require billing-specific access)'

if ($MonthlyBudget -gt 0) {
    $budgetRemaining = [math]::Round(([double]$MonthlyBudget - $spent), 2)
    $budgetLine = "Configured monthly budget: $MonthlyBudget (compare only if same currency); budget less cost: $budgetRemaining"
}
else {
    $budgetLine = 'No monthly budget configured'
}

$generatedUtc = [datetime]::UtcNow.ToString('u')

$message = @(
    'Azure daily cost report'
    "Subscription: $SubscriptionId"
    "Month-to-date actual cost: $roundedSpend $currency"
    $budgetLine
    "Sponsorship credit balance: $remaining"
    "Generated UTC: $generatedUtc"
    'Note: Cost Management data may lag actual consumption.'
    'Guardrail: Foundry/Cognitive Services model deployments are removed before resource-group deletion, and soft-deleted accounts are purged.'
) -join [Environment]::NewLine

Write-Output $message

# ------------------------------------------------------------
# 6. Optional Teams notification
# ------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($WebhookUrl)) {
    Write-Warning 'Teams webhook is not configured. Report generated without notification.'
    exit 0
}

try {
    $webhookBody = @{ text = $message } | ConvertTo-Json -Depth 4 -Compress

    Invoke-RestMethod `
        -Method Post `
        -Uri $WebhookUrl `
        -ContentType 'application/json' `
        -Body $webhookBody | Out-Null

    Write-Output 'Teams notification sent successfully.'
}
catch {
    Write-Error ("Teams notification failed: {0}" -f $_.Exception.Message)
    exit 1
}
