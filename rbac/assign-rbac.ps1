$rgName = "rg-ephemeral-test"
$rgScope = "$scope/resourceGroups/$rgName"

az role assignment create `
  --assignee-object-id $cleanupSpId `
  --assignee-principal-type ServicePrincipal `
  --role "Azure Guard - RG Delete" `
  --scope $rgScope