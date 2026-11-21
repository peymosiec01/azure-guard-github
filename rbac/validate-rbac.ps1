$ErrorActionPreference = 'Stop'

# Ensure Azure CLI provider metadata is handled as UTF-8 on Windows.
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'

[Console]::InputEncoding = [System.Text.UTF8Encoding]::new()
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

# Azure Guard RBAC validator.
# Read-only: this script does not create roles or assignments.

$RepoRoot = Split-Path -Path $PSScriptRoot -Parent
$EnvFile = Join-Path $RepoRoot '.env'
$RgRoleFile = Join-Path $PSScriptRoot 'azure-guard-rg-delete-role.json'
$PurgeRoleFile = Join-Path $PSScriptRoot 'azure-guard-foundry-purge-role.json'
$FailureCount = 0

function Pass([string]$Message) {
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Fail([string]$Message) {
    $script:FailureCount++
    Write-Host "[FAILED] $Message" -ForegroundColor Red
}

function Info([string]$Message) {
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Import-EnvFile([string]$Path) {
    if (-not (Test-Path $Path)) {
        throw ".env not found: $Path"
    }

    foreach ($Line in Get-Content $Path) {
        $Text = $Line.Trim()
        if ([string]::IsNullOrWhiteSpace($Text) -or $Text.StartsWith('#')) {
            continue
        }

        $Parts = $Text -split '=', 2
        if ($Parts.Count -ne 2) {
            Fail "Invalid .env line: $Text"
            continue
        }

        $Name = $Parts[0].Trim()
        $Value = $Parts[1].Trim().Trim('"').Trim("'")
        [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
    }
}

function Get-OperationNames {
    param(
        [Parameter(Mandatory)]
        [string]$Namespace
    )

    $Raw = az provider operation show `
        --namespace $Namespace `
        --query "[operations[].name, resourceTypes[].operations[].name][]" `
        --output tsv 2>$null

    if ($LASTEXITCODE -ne 0) {
        throw "Unable to retrieve operations for $Namespace"
    }

    $Names = @(
        $Raw |
            ForEach-Object {
                [string]$_
            } |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_)
            } |
            ForEach-Object {
                $_.Trim()
            } |
            Sort-Object -Unique
    )

    if ($Names.Count -eq 0) {
        throw "Azure returned no RBAC operations for $Namespace"
    }

    return $Names
}

function Test-Role($Role, [hashtable]$Operations, [string]$ExpectedScope) {
    Write-Host ''
    Write-Host "Role: $($Role.Name)" -ForegroundColor White

    if ($Role.IsCustom -eq $true) {
        Pass 'IsCustom=true'
    }
    else {
        Fail 'IsCustom must be true'
    }

    if (@($Role.AssignableScopes) -contains $ExpectedScope) {
        Pass "AssignableScopes contains $ExpectedScope"
    }
    else {
        Fail "AssignableScopes does not contain $ExpectedScope"
    }

    foreach ($Action in @($Role.Actions)) {
        $Provider = ($Action -split '/')[0]

        if (-not $Operations.ContainsKey($Provider)) {
            Fail "Provider not loaded for action: $Action"
            continue
        }

        if (@($Operations[$Provider]) -contains $Action) {
            Pass $Action
        }
        else {
            Fail "Azure does not expose action: $Action"
        }
    }
}

Write-Host ''
Write-Host '=========================================='
Write-Host ' Azure Guard - RBAC Validation'
Write-Host '=========================================='

Info 'Loading .env'
Import-EnvFile $EnvFile

$RequiredSettings = @(
    'AZURE_SUBSCRIPTION_ID',
    'AZURE_TENANT_ID',
    'AZURE_MONITOR_CLIENT_ID',
    'AZURE_CLEANUP_CLIENT_ID'
)

foreach ($Setting in $RequiredSettings) {
    $Value = [Environment]::GetEnvironmentVariable($Setting, 'Process')
    if ([string]::IsNullOrWhiteSpace($Value)) {
        Fail "Missing setting: $Setting"
    }
    else {
        Pass "$Setting configured"
    }
}

if ($FailureCount -gt 0) {
    throw 'Required configuration is incomplete.'
}

Info 'Checking Azure CLI context'
az account show --output none 2>$null
if ($LASTEXITCODE -ne 0) {
    throw 'Azure CLI is not authenticated. Run az login first.'
}
Pass 'Azure CLI authenticated'

$CurrentTenant = az account show --query tenantId --output tsv
if ($CurrentTenant -ne $env:AZURE_TENANT_ID) {
    throw "Wrong Azure tenant. Current: $CurrentTenant"
}
Pass 'Correct Azure tenant'

az account set --subscription $env:AZURE_SUBSCRIPTION_ID
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to select configured subscription.'
}
Pass 'Configured subscription selected'

$SubscriptionScope = '/subscriptions/' + $env:AZURE_SUBSCRIPTION_ID

Info 'Loading custom-role JSON'
if (-not (Test-Path $RgRoleFile)) { throw "Missing file: $RgRoleFile" }
if (-not (Test-Path $PurgeRoleFile)) { throw "Missing file: $PurgeRoleFile" }

$RgRole = Get-Content $RgRoleFile -Raw | ConvertFrom-Json
$PurgeRole = Get-Content $PurgeRoleFile -Raw | ConvertFrom-Json
Pass 'Custom-role JSON files loaded'

Info 'Loading Azure provider operations'
$ProviderNames = @(
    'Microsoft.Resources',
    'Microsoft.Authorization',
    'Microsoft.Insights',
    'Microsoft.CognitiveServices'
)

$Operations = @{}
foreach ($ProviderName in $ProviderNames) {
    try {
        $Items = @(Get-OperationNames $ProviderName)
        $Operations[$ProviderName] = $Items
        Pass "$ProviderName operations loaded: $($Items.Count)"
    }
    catch {
        Fail $_.Exception.Message
    }
}

if ($FailureCount -gt 0) {
    throw 'Unable to load required provider operations.'
}

Test-Role $RgRole $Operations $SubscriptionScope
Test-Role $PurgeRole $Operations $SubscriptionScope

Info 'Checking critical Foundry cleanup operations'
$CriticalActions = @(
    'Microsoft.CognitiveServices/accounts/read',
    'Microsoft.CognitiveServices/accounts/deployments/read',
    'Microsoft.CognitiveServices/accounts/deployments/delete',
    'Microsoft.CognitiveServices/locations/resourceGroups/deletedAccounts/read',
    'Microsoft.CognitiveServices/locations/resourceGroups/deletedAccounts/delete'
)

foreach ($Action in $CriticalActions) {
    if (@($Operations['Microsoft.CognitiveServices']) -contains $Action) {
        Pass $Action
    }
    else {
        Fail "Missing critical action: $Action"
    }
}

Info 'Resolving service principals'
$MonitorSpId = az ad sp show --id $env:AZURE_MONITOR_CLIENT_ID --query id --output tsv 2>$null
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($MonitorSpId)) {
    Fail 'Monitor service principal could not be resolved'
}
else {
    Pass 'Monitor service principal resolved'
}

$CleanupSpId = az ad sp show --id $env:AZURE_CLEANUP_CLIENT_ID --query id --output tsv 2>$null
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($CleanupSpId)) {
    Fail 'Cleanup service principal could not be resolved'
}
else {
    Pass 'Cleanup service principal resolved'
}

if (-not [string]::IsNullOrWhiteSpace($CleanupSpId)) {
    Info 'Inspecting cleanup identity assignments'
    $RawAssignments = az role assignment list --assignee-object-id $CleanupSpId --all --output json 2>&1

    if ($LASTEXITCODE -ne 0) {
        Fail 'Unable to inspect cleanup identity assignments'
    }
    else {
        $Assignments = @($RawAssignments | Out-String | ConvertFrom-Json)

        if ($Assignments.Count -gt 0) {
            $Assignments |
                Select-Object roleDefinitionName, scope |
                Format-Table -AutoSize
        }
        else {
            Info 'No existing cleanup role assignments found'
        }

        $ForbiddenSubscriptionRoles = @(
            'Owner',
            'Contributor',
            'User Access Administrator',
            'Azure Guard - RG Delete'
        )

        $RiskyAssignments = @(
            $Assignments | Where-Object {
                $_.scope -eq $SubscriptionScope -and
                $_.roleDefinitionName -in $ForbiddenSubscriptionRoles
            }
        )

        if ($RiskyAssignments.Count -eq 0) {
            Pass 'No over-broad cleanup assignment detected at subscription scope'
        }
        else {
            foreach ($Assignment in $RiskyAssignments) {
                Fail "Over-broad subscription assignment: $($Assignment.roleDefinitionName)"
            }
        }
    }
}

Write-Host ''
Write-Host '=========================================='
Write-Host ' RBAC Validation Result'
Write-Host '=========================================='

if ($FailureCount -eq 0) {
    Write-Host '[SUCCESS] Azure Guard RBAC validation passed.' -ForegroundColor Green
    Write-Host 'No Azure roles or assignments were changed.'
    exit 0
}

Write-Host "[FAILED] $FailureCount validation check(s) failed." -ForegroundColor Red
Write-Host 'Do not run setup-rbac.ps1 until the failures are resolved.'
exit 1
