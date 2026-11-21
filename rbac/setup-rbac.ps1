$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$envFile = Join-Path -Path $repoRoot -ChildPath '.env'

if (-not (Test-Path -Path $envFile)) {
    throw '.env not found. Copy .env.example to .env and configure it first.'
}

foreach ($line in Get-Content -Path $envFile) {
    $text = $line.Trim()
    if ([string]::IsNullOrWhiteSpace($text) -or $text.StartsWith('#')) {
        continue
    }

    $parts = $text -split '=', 2
    if ($parts.Count -eq 2) {
        $name = $parts[0].Trim()
        $value = $parts[1].Trim().Trim('"').Trim("'")
        [Environment]::SetEnvironmentVariable($name, $value, 'Process')
    }
}

$SubscriptionId = $env:AZURE_SUBSCRIPTION_ID
$TenantId = $env:AZURE_TENANT_ID
$MonitorAppId = $env:AZURE_MONITOR_CLIENT_ID
$CleanupAppId = $env:AZURE_CLEANUP_CLIENT_ID

foreach ($required in @{
    AZURE_SUBSCRIPTION_ID = $SubscriptionId
    AZURE_TENANT_ID = $TenantId
    AZURE_MONITOR_CLIENT_ID = $MonitorAppId
    AZURE_CLEANUP_CLIENT_ID = $CleanupAppId
}.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace([string]$required.Value)) {
        throw "Missing required setting: $($required.Key)"
    }
}

function Ensure-RoleDefinition {
    param(
        [Parameter(Mandatory)] [string]$RoleName,
        [Parameter(Mandatory)] [string]$DefinitionFile
    )

    if (-not (Test-Path -Path $DefinitionFile)) {
        throw "Role definition file not found: $DefinitionFile"
    }

    $desiredRole = Get-Content -Path $DefinitionFile -Raw | ConvertFrom-Json

    $existingRoleId = az role definition list `
        --name $RoleName `
        --query '[0].id' `
        --output tsv 2>$null

    if ($LASTEXITCODE -ne 0) {
        throw "Unable to inspect role definition: $RoleName"
    }

    if ([string]::IsNullOrWhiteSpace($existingRoleId)) {
        Write-Output "Creating role definition: $RoleName"

        az role definition create `
            --role-definition $DefinitionFile `
            --output none

        if ($LASTEXITCODE -ne 0) {
            throw "Unable to create role definition: $RoleName"
        }

        Write-Output "Created role definition: $RoleName"
        return
    }

    Write-Output "Updating role definition: $RoleName"

    $existingRoleJson = az role definition list `
        --name $RoleName `
        --query '[0]' `
        --output json

    if ($LASTEXITCODE -ne 0) {
        throw "Unable to retrieve existing role definition: $RoleName"
    }

    $existingRole = $existingRoleJson | Out-String | ConvertFrom-Json

    if ([string]::IsNullOrWhiteSpace($existingRole.id)) {
        throw "Existing role is missing its Azure role-definition ID: $RoleName"
    }

    if ([string]::IsNullOrWhiteSpace($existingRole.name)) {
        throw "Existing role is missing its Azure role-definition name: $RoleName"
    }

    $updateRole = [ordered]@{
        id = $existingRole.id
        name = $existingRole.name
        roleName = $RoleName
        description = $desiredRole.Description
        roleType = 'CustomRole'
        type = 'Microsoft.Authorization/roleDefinitions'
        permissions = @(
            [ordered]@{
                actions = @($desiredRole.Actions)
                notActions = @($desiredRole.NotActions)
                dataActions = @($desiredRole.DataActions)
                notDataActions = @($desiredRole.NotDataActions)
            }
        )
        assignableScopes = @($desiredRole.AssignableScopes)
    }

    $temporaryFile = Join-Path `
        -Path ([System.IO.Path]::GetTempPath()) `
        -ChildPath ('azure-guard-role-' + [guid]::NewGuid().ToString() + '.json')

    try {
        $updateRole |
            ConvertTo-Json -Depth 20 |
            Set-Content -Path $temporaryFile -Encoding UTF8

        az role definition update `
            --role-definition $temporaryFile `
            --output none

        if ($LASTEXITCODE -ne 0) {
            throw "Unable to update role definition: $RoleName"
        }

        Write-Output "Updated role definition: $RoleName"
    }
    finally {
        if (Test-Path -Path $temporaryFile) {
            Remove-Item -Path $temporaryFile -Force
        }
    }
}

function Ensure-RoleAssignment {
    param(
        [Parameter(Mandatory)] [string]$PrincipalId,
        [Parameter(Mandatory)] [string]$RoleName,
        [Parameter(Mandatory)] [string]$Scope
    )

    $existingAssignment = az role assignment list `
        --assignee-object-id $PrincipalId `
        --role $RoleName `
        --scope $Scope `
        --query '[0].id' `
        --output tsv

    if ($LASTEXITCODE -ne 0) {
        throw "Unable to inspect assignment for $RoleName"
    }

    if (-not [string]::IsNullOrWhiteSpace($existingAssignment)) {
        Write-Output "Role already assigned: $RoleName"
        return
    }

    az role assignment create `
        --assignee-object-id $PrincipalId `
        --assignee-principal-type ServicePrincipal `
        --role $RoleName `
        --scope $Scope `
        --output none

    if ($LASTEXITCODE -ne 0) {
        throw "Unable to assign role: $RoleName"
    }

    Write-Output "Assigned role: $RoleName"
}

az account set --subscription $SubscriptionId | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Cannot select subscription $SubscriptionId"
}

$currentTenant = az account show --query tenantId --output tsv
if ($LASTEXITCODE -ne 0 -or $currentTenant -ne $TenantId) {
    throw 'Azure CLI is not authenticated to the expected tenant'
}

$subscriptionScope = '/subscriptions/' + $SubscriptionId

$monitorSpId = az ad sp show --id $MonitorAppId --query id --output tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($monitorSpId)) {
    throw 'Cannot resolve monitor service principal'
}

$cleanupSpId = az ad sp show --id $CleanupAppId --query id --output tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($cleanupSpId)) {
    throw 'Cannot resolve cleanup service principal'
}

Ensure-RoleDefinition `
    -RoleName 'Azure Guard - RG Delete' `
    -DefinitionFile (Join-Path $PSScriptRoot 'azure-guard-rg-delete-role.json')

Ensure-RoleDefinition `
    -RoleName 'Azure Guard - Foundry Purge' `
    -DefinitionFile (Join-Path $PSScriptRoot 'azure-guard-foundry-purge-role.json')

Ensure-RoleAssignment `
    -PrincipalId $monitorSpId `
    -RoleName 'Cost Management Reader' `
    -Scope $subscriptionScope

Ensure-RoleAssignment `
    -PrincipalId $monitorSpId `
    -RoleName 'Reader' `
    -Scope $subscriptionScope

Ensure-RoleAssignment `
    -PrincipalId $cleanupSpId `
    -RoleName 'Reader' `
    -Scope $subscriptionScope

Ensure-RoleAssignment `
    -PrincipalId $cleanupSpId `
    -RoleName 'Azure Guard - Foundry Purge' `
    -Scope $subscriptionScope

Write-Output ''
Write-Output 'Azure Guard base RBAC configured.'
Write-Output "Monitor service principal: $monitorSpId"
Write-Output "Cleanup service principal: $cleanupSpId"
Write-Output ''
Write-Output 'The RG Delete role must still be assigned separately'
Write-Output 'to each approved disposable resource group.'
