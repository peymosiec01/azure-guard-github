$sub = 'bba54ba4-13fe-4f20-8bba-a653c0f83275'
$tenant = '2d1180b6-6e99-416a-be95-c466e484bf95'
$repo = 'peymosiec01/azure-guard-github'

az account set --subscription $sub

$subscriptionId = $sub
$monitorAppId = "d1b57feb-3a61-497f-bab9-5532068127a4"
$scope = "/subscriptions/$subscriptionId"

$monitorSpId = az ad sp show --id $monitorAppId --query id -o tsv

az role assignment create --assignee-object-id $monitorSpId --assignee-principal-type ServicePrincipal --role "Cost Management Reader" --scope $scope

az role assignment create --assignee-object-id $monitorSpId --assignee-principal-type ServicePrincipal --role "Reader" --scope $scope

$cleanupAppId = "f17b5b33-9a88-494c-8ba0-f8887ddcbb4b"

$cleanupSpId = az ad sp show --id $cleanupAppId --query id -o tsv

az role assignment create --assignee-object-id $cleanupSpId --assignee-principal-type ServicePrincipal --role "Reader" --scope $scope

az role definition create --role-definition .\azure-guard-rg-delete-role.json