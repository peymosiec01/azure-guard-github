# Azure Guard - GitHub Actions + Teams

Azure Guard is a lightweight safety and cost-control solution for disposable Azure development environments.

It uses:

- GitHub Actions for scheduled monitoring and cleanup.
- Microsoft Entra ID workload identity federation for secretless Azure authentication.
- Azure RBAC for least-privilege access.
- Azure Cost Management for month-to-date cost reporting.
- Microsoft Teams workflows for notifications.
- Resource-group tags and naming conventions to identify disposable environments.
- Microsoft Foundry-aware cleanup, including model deployment removal and soft-delete purging.

> [!IMPORTANT]
> Azure Guard is intended for disposable development and sandbox resources. It should not be used to automatically delete production resource groups.

## 1. Safety model

Cleanup is deliberately defensive.

A resource group is considered for cleanup only when:

- `AutoCleanup=true`.
- `Protect` is not `true`.
- `CreatedUtc` exists.
- the resource-group name explicitly identifies the environment as disposable.
- the configured age threshold has been reached.
- the activity check permits deletion.
- the resource group has no locks.
- no contained resource has `Protect=true`.
- the cleanup identity has explicitly been granted deletion permission for that resource group.

Cleanup defaults to **preview only**.

Actual deletion requires:

1. a manual GitHub Actions workflow dispatch;
2. `delete=true`;
3. the GitHub Environment `azure-guard-delete`;
4. required reviewer approval.

The cleanup identity must not be given subscription-wide resource-group deletion permissions.

## 2. Repository structure

```text
azure-guard-github/
│
├── .github/
│   └── workflows/
│       ├── cleanup.yml
│       └── daily-cost.yml
│
├── rbac/
│   ├── assign-rbac.ps1
│   ├── azure-guard-foundry-purge-role.json
│   ├── azure-guard-rg-delete-role.json
│   ├── setup-rbac.ps1
│   └── validate-rbac.ps1
│
├── .env.example
├── .gitignore
├── cleanup.ps1
├── monitor.ps1
└── README.md
```

### Main files

| File | Purpose |
|---|---|
| `cleanup.ps1` | Finds eligible disposable resource groups and optionally deletes them. Also handles Microsoft Foundry cleanup. |
| `monitor.ps1` | Queries Azure Cost Management and sends a daily cost report. |
| `rbac/validate-rbac.ps1` | Read-only validation of custom-role JSON, Azure provider operations, service principals and overly broad cleanup assignments. |
| `rbac/setup-rbac.ps1` | Creates/updates base Azure Guard custom roles and subscription-level assignments. |
| `rbac/assign-rbac.ps1` | Explicitly enrols a disposable resource group for deletion. |
| `rbac/azure-guard-rg-delete-role.json` | Custom role for an approved disposable resource group and its model deployments. |
| `rbac/azure-guard-foundry-purge-role.json` | Custom role for purging soft-deleted Foundry/Cognitive Services accounts. |
| `.github/workflows/cleanup.yml` | Scheduled preview and manually approved cleanup workflow. |
| `.github/workflows/daily-cost.yml` | Scheduled cost-monitoring workflow. |

## 3. Local configuration

Copy:

```powershell
Copy-Item .env.example .env
```

Configure `.env`:

```bash
AZURE_SUBSCRIPTION_ID="your-subscription-id"
AZURE_TENANT_ID="your-tenant-id"
AZURE_GUARD_REPO="your-github-owner/azure-guard-github"
AZURE_MONITOR_CLIENT_ID="your-monitor-app-client-id"
AZURE_CLEANUP_CLIENT_ID="your-cleanup-app-client-id"
AZURE_GUARD_WEBHOOK="your-teams-workflow-webhook"
MONTHLY_BUDGET="25"
```

`.env` is local configuration and must not be committed.

```bash
git check-ignore -v .env
```

Never commit Azure client secrets, service-principal passwords, Foundry API keys, Teams webhook URLs, credentials or access tokens.

## 4. GitHub Actions configuration

GitHub Actions does not use local `.env`.

Configure repository Actions secrets:

```text
AZURE_TENANT_ID
AZURE_SUBSCRIPTION_ID
AZURE_MONITOR_CLIENT_ID
AZURE_CLEANUP_CLIENT_ID
TEAMS_WORKFLOW_WEBHOOK
```

Configure variable:

```text
MONTHLY_BUDGET
```

No Azure client secret is required. GitHub Actions authenticates using Microsoft Entra workload identity federation and OIDC.

## 5. Microsoft Entra applications

Create two Microsoft Entra app registrations.

### Monitor identity

Used only for Azure Cost Management and subscription/resource visibility required by monitoring. It must not receive deletion permissions.

### Cleanup identity

Used only for controlled cleanup operations.

This separation prevents the monitoring identity from becoming destructive.

## 6. GitHub OIDC federation

### Monitor credential

```text
Entity: Branch
Branch: main
Subject: repo:OWNER/REPO:ref:refs/heads/main
```

### Cleanup preview credential

```text
Environment: azure-guard-preview
Subject: repo:OWNER/REPO:environment:azure-guard-preview
```

### Cleanup delete credential

```text
Environment: azure-guard-delete
Subject: repo:OWNER/REPO:environment:azure-guard-delete
```

Use:

```text
Issuer: https://token.actions.githubusercontent.com
Audience: api://AzureADTokenExchange
```

## 7. RBAC model

### Monitor identity

Subscription scope:

```text
Reader
Cost Management Reader
```

### Cleanup identity

Subscription scope:

```text
Reader
Azure Guard - Foundry Purge
```

Assigned individually to approved disposable resource groups:

```text
Azure Guard - RG Delete
```

```text
Monitor identity
│
├── Reader
└── Cost Management Reader

Cleanup identity
│
├── Reader
├── Azure Guard - Foundry Purge
└── Azure Guard - RG Delete
      approved sandbox RG only
```

Do not assign subscription-wide `Contributor` or subscription-wide `Azure Guard - RG Delete` merely to simplify cleanup.

## 8. Validate RBAC before configuration

```powershell
./rbac/validate-rbac.ps1
```

The validator is read-only. It checks:

- local configuration;
- Azure tenant/subscription context;
- custom-role JSON and assignable scopes;
- Azure resource-provider RBAC operations;
- Foundry model-deployment read/delete operations;
- Foundry soft-delete read/purge operations;
- monitor and cleanup service principals;
- potentially over-broad cleanup assignments.

Expected:

```text
[SUCCESS] Azure Guard RBAC validation passed.
No Azure roles or assignments were changed.
```

Do not run `setup-rbac.ps1` when validation fails.

## 9. Configure base RBAC

```powershell
./rbac/setup-rbac.ps1
```

The script creates or updates:

```text
Azure Guard - RG Delete
Azure Guard - Foundry Purge
```

and configures the required subscription-level assignments.

## 10. Explicitly enrol a disposable resource group

A matching name and `AutoCleanup=true` tag do not grant deletion permission.

```powershell
./rbac/assign-rbac.ps1 `
    -ResourceGroupName "rg-insurance-foundry-sandbox"
```

Explicit enrolment is an additional safety boundary.

## 11. Required cleanup tags

```text
AutoCleanup=true
CreatedUtc=<UTC ISO-8601 timestamp>
```

Optional protection:

```text
Protect=true
```

Azure Guard fails closed when protection is detected.

## 12. Cleanup eligibility

`cleanup.ps1` skips a group when:

- `AutoCleanup=true` is absent;
- `Protect=true`;
- the name does not identify a disposable environment;
- `CreatedUtc` is missing;
- the age threshold has not been reached;
- recent management-plane activity blocks cleanup;
- a resource lock exists;
- a contained resource has `Protect=true`;
- a required Azure query fails.

The default threshold is 72 hours and the minimum accepted value is 24 hours.

Azure Activity Log does not represent all data-plane activity, so `CreatedUtc` should be treated as an expiration starting point rather than a reliable last-used timestamp. For stronger lifecycle management, consider adding `ExpiresUtc` through a controlled deployment pipeline.

## 13. Microsoft Foundry-aware cleanup

Foundry/Cognitive Services resources require additional cleanup because account deletion enters soft-delete.

```text
Eligible sandbox resource group
        ↓
Discover Foundry/Cognitive Services account
        ↓
Delete model deployments
        ↓
Delete resource group
        ↓
Wait for RG deletion
        ↓
Wait for Foundry soft-delete
        ↓
Purge soft-deleted account
        ↓
Confirm purge
```

Before deleting the group, Azure Guard captures the account name, Azure location and original resource-group name because those values are needed for purge.

## 14. Custom role: Azure Guard - RG Delete

Defined in:

```text
rbac/azure-guard-rg-delete-role.json
```

It permits the approved sandbox cleanup operations, including resource inspection, lock/activity inspection, Cognitive Services account inspection, model deployment read/delete and RG deletion.

The role is assigned at individual resource-group scope.

## 15. Custom role: Azure Guard - Foundry Purge

Defined in:

```text
rbac/azure-guard-foundry-purge-role.json
```

It permits inspection and purge of soft-deleted Foundry/Cognitive Services accounts. It is assigned at subscription scope because the original RG has disappeared when purge occurs. It does not grant general subscription-wide RG deletion.

## 16. Cleanup preview

```powershell
./cleanup.ps1 `
    -SubscriptionId $env:AZURE_SUBSCRIPTION_ID `
    -Hours 72
```

No resource groups are deleted.

For an eligible Foundry sandbox, preview should identify both the group and the Foundry account that would be purged after deletion.

## 17. Cleanup deletion

```powershell
./cleanup.ps1 `
    -SubscriptionId $env:AZURE_SUBSCRIPTION_ID `
    -Hours 72 `
    -Delete
```

Expected lifecycle:

```text
Delete model deployment
        ↓
Submit RG deletion
        ↓
Confirm RG deletion
        ↓
Detect soft-deleted Foundry account
        ↓
Purge Foundry account
        ↓
Confirm purge
```

## 18. Verify cleanup

```powershell
az group exists --name rg-insurance-foundry-sandbox
```

Expected:

```text
false
```

Then:

```powershell
az cognitiveservices account list-deleted --output table
```

The purged account should not appear. Redeploying the same deterministic Foundry resource name is a useful final proof.

## 19. GitHub environments

Create:

```text
azure-guard-preview
azure-guard-delete
```

The delete environment should have required reviewers. Where supported, restrict deployment branches to `main`.

## 20. Microsoft Teams notifications

Create a Teams / Power Automate workflow using `When a Teams webhook request is received`. Azure Guard sends:

```json
{
  "text": "Azure Guard notification"
}
```

Store the webhook only as `TEAMS_WORKFLOW_WEBHOOK` in GitHub or `AZURE_GUARD_WEBHOOK` locally. Never commit it.

## 21. Cost monitoring

`monitor.ps1` queries month-to-date actual cost. It does not claim sponsorship credit balance because that requires billing-specific access. Azure Cost Management data can lag actual consumption, and query failure must not be treated as zero spend.

## 22. Scheduled workflows

### Daily cost report

```text
.github/workflows/daily-cost.yml
08:00 UTC daily
```

### Cleanup preview

```text
.github/workflows/cleanup.yml
Every six hours at minute 17 UTC
```

Scheduled cleanup is preview only. Actual deletion is manually initiated with `delete=true` and approval through `azure-guard-delete`.

GitHub-hosted schedules are best-effort and may not start exactly on time.

## 23. Relationship with sandbox projects

Application repositories create and tag their own disposable infrastructure:

```text
insurance-foundry-platform
        ↓
rg-insurance-foundry-sandbox
├── AutoCleanup=true
└── CreatedUtc=<timestamp>
```

Azure Guard remains separate:

```text
azure-guard-github
├── identifies eligible groups
├── verifies safety conditions
├── deletes model deployments
├── deletes the approved RG
└── purges soft-deleted Foundry accounts
```

The integration contract is:

```text
Disposable naming
+
AutoCleanup=true
+
CreatedUtc
+
Explicit Azure Guard RG RBAC assignment
```

## 24. Before trusting deletion

1. Validate RBAC.
2. Review both custom roles.
3. Confirm the monitor identity has no deletion rights.
4. Confirm the cleanup identity has no subscription-wide RG delete rights.
5. Confirm RG Delete is assigned only to approved sandboxes.
6. Confirm `azure-guard-delete` requires human approval.
7. Test Teams notifications.
8. Run cleanup preview.
9. Verify protected resources are excluded.
10. Test an empty throwaway RG.
11. Test a disposable Foundry environment.
12. Confirm model deployments are removed.
13. Confirm RG deletion completes.
14. Confirm the Foundry account is purged.
15. Confirm the same Foundry name can be redeployed.
