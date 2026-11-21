param(
    [Parameter(Mandatory)]
    [string]$ResourceGroupName
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$envFile = Join-Path -Path $repoRoot -ChildPath '.env'

if (-not (Test-Path -Path $envFile)) {
    throw '.env not found. Copy .env.example to .env and configure it first.'
}

foreach ($line in Get-Content -Path $envFile) {
    $text = $line.Trim()

    if (
        [string]::IsNullOrWhiteSpace($text) -or
        $text.StartsWith('#')
    ) {
        continue
    }

    $parts = $text -split '=', 2

    if ($parts.Count -eq 2) {
        $name = $parts[0].Trim()
        $value = $parts[1].Trim().Trim('"').Trim("'")

        [Environment]::SetEnvironmentVariable(
            $name,
            $value,
            'Process'
        )
    }
}

$SubscriptionId = $env:AZURE_SUBSCRIPTION_ID
$CleanupAppId = $env:AZURE_CLEANUP_CLIENT_ID

if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
    throw 'AZURE_SUBSCRIPTION_ID is missing from .env'
}

if ([string]::IsNullOrWhiteSpace($CleanupAppId)) {
    throw 'AZURE_CLEANUP_CLIENT_ID is missing from .env'
}

$DisposableResourceGroupPattern = '^rg-.*-(ephemeral|sandbox|temp)(-|$)'

if ($ResourceGroupName -notmatch $DisposableResourceGroupPattern) {
    throw (
        "Resource group '$ResourceGroupName' is not eligible. " +
        "Its name must explicitly contain ephemeral, sandbox or temp."
    )
}

az account set `
    --subscription $SubscriptionId |
    Out-Null

if ($LASTEXITCODE -ne 0) {
    throw "Cannot select subscription $SubscriptionId"
}

$resourceGroupExists = az group exists `
    --name $ResourceGroupName `
    --output tsv

if ($LASTEXITCODE -ne 0 -or $resourceGroupExists -ne 'true') {
    throw "Resource group does not exist: $ResourceGroupName"
}

$autoCleanup = az group show `
    --name $ResourceGroupName `
    --query tags.AutoCleanup `
    --output tsv

if ($LASTEXITCODE -ne 0) {
    throw "Cannot inspect AutoCleanup tag on $ResourceGroupName"
}

if (-not ([string]$autoCleanup).Equals(
    'true',
    [System.StringComparison]::OrdinalIgnoreCase
)) {
    throw "Resource group does not have AutoCleanup=true"
}

$protected = az group show `
    --name $ResourceGroupName `
    --query tags.Protect `
    --output tsv

if (
    -not [string]::IsNullOrWhiteSpace($protected) -and
    ([string]$protected).Equals(
        'true',
        [System.StringComparison]::OrdinalIgnoreCase
    )
) {
    throw "Resource group has Protect=true"
}

$cleanupSpId = az ad sp show `
    --id $CleanupAppId `
    --query id `
    --output tsv

if (
    $LASTEXITCODE -ne 0 -or
    [string]::IsNullOrWhiteSpace($cleanupSpId)
) {
    throw 'Cannot resolve cleanup service principal'
}

$resourceGroupScope = (
    "/subscriptions/$SubscriptionId" +
    "/resourceGroups/$ResourceGroupName"
)

$existingAssignment = az role assignment list `
    --assignee-object-id $cleanupSpId `
    --role 'Azure Guard - RG Delete' `
    --scope $resourceGroupScope `
    --query "[0].id" `
    --output tsv

if ($LASTEXITCODE -ne 0) {
    throw 'Unable to inspect existing RG Delete assignment'
}

if (-not [string]::IsNullOrWhiteSpace($existingAssignment)) {
    Write-Output (
        "Azure Guard - RG Delete is already assigned to " +
        $ResourceGroupName
    )

    exit 0
}

az role assignment create `
    --assignee-object-id $cleanupSpId `
    --assignee-principal-type ServicePrincipal `
    --role 'Azure Guard - RG Delete' `
    --scope $resourceGroupScope `
    --output none

if ($LASTEXITCODE -ne 0) {
    throw "Unable to assign cleanup role to $ResourceGroupName"
}

Write-Output (
    "Assigned Azure Guard - RG Delete to " +
    "$ResourceGroupName for cleanup service principal $cleanupSpId"
)