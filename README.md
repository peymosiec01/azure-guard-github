# Azure Guard — GitHub Actions + Teams

**Safety:** this repository defaults to preview-only cleanup. Deletion requires manual workflow dispatch with `delete=true` and a GitHub Environment named `azure-guard-delete` configured with required reviewers. Use a dedicated disposable **sandbox subscription**, not production. GitHub-hosted scheduled workflows are best effort, not guaranteed to start exactly on time.

## 1. Prepare Azure

Install/login to Azure CLI locally (`az login`). Set:

```powershell
$sub = '<sandbox-subscription-id>'
$tenant = '<tenant-id>'
$repo = '<github-owner>/<github-repository>'
az account set --subscription $sub
```

Create **two** Microsoft Entra app registrations (monitor and cleanup), each with a federated identity credential, rather than storing client secrets. For each app, create a federated credential in Azure Portal > App registrations > (app) > Certificates & secrets > Federated credentials > Add credential > GitHub Actions deploying Azure resources.

Monitor credential: entity **Branch**, `main` (subject `repo:OWNER/REPO:ref:refs/heads/main`).

Cleanup app requires **two** credentials, entity **Environment**, `azure-guard-preview` and `azure-guard-delete` (subjects `repo:OWNER/REPO:environment:azure-guard-preview` and `repo:OWNER/REPO:environment:azure-guard-delete`). Set issuer `https://token.actions.githubusercontent.com`, audience `api://AzureADTokenExchange`. Set organization/repo to your own exact values.

Assign **Cost Management Reader** at subscription scope to monitor app (and Reader if necessary for account selection). Assign **Reader**, **Monitoring Reader** and a tightly scoped custom RG-delete role to cleanup app. The cleanup app must have permission to read group resources/tags/locks and activity logs and delete groups. **Avoid subscription-wide Contributor**. If scoping per-group, grant deletion role only on preapproved disposable groups; subscription-level delete privilege is too broad for a personal mixed-use subscription.

For initial setup, you may instead test cleanup under a separate disposable subscription using a dedicated identity and then narrow permissions. Never grant the monitor identity delete rights.

## 2. Configure GitHub

In GitHub repository Settings > Secrets and variables > Actions, set secrets:
- `AZURE_TENANT_ID`
- `AZURE_SUBSCRIPTION_ID`
- `AZURE_MONITOR_CLIENT_ID`
- `AZURE_CLEANUP_CLIENT_ID`
- `TEAMS_WORKFLOW_WEBHOOK`

Set variable `MONTHLY_BUDGET` (number **in the same currency as Azure Cost Management**, e.g. `25`).

In Settings > Environments, create `azure-guard-preview` and `azure-guard-delete`. For delete environment, add **required reviewers** and optionally restrict deployment branches to `main`. GitHub environment protection availability depends on repo visibility and plan.

## 3. Microsoft Teams workflow

In Teams Workflows / Power Automate, create a workflow with trigger **When a Teams webhook request is received**. Choose who can call it per tenant policy (do not make publicly callable unless necessary). Configure it to accept a JSON body with string property `text`, e.g. `{"text":"Azure report"}`. Add action **Post message in a chat or channel** (Flow bot), choose target Team/channel, and set message content to the trigger's `text` value. Save and copy the trigger's HTTP POST URL to `TEAMS_WORKFLOW_WEBHOOK`. Keep it secret. If the tenant's trigger requires a different schema or authentication, adjust accordingly; Teams Workflows webhook triggers are not identical to legacy incoming connectors. Test with a manual workflow dispatch.

## 4. Resource-group eligibility

Create only throwaway resource groups. Apply:

```powershell
$created = [datetime]::UtcNow.ToString('o')
az group create --name rg-ephemeral-demo --location uksouth --tags AutoCleanup=true CreatedUtc=$created
```

The script skips untagged/protected groups, groups younger than 72h, groups with recent management-plane activity, and groups with detected locks or protected resources. It fails closed on failed Azure queries. **Activity Logs do not track all data-plane operations and cannot guarantee inactivity**. Treat `CreatedUtc` as an expiration starting point, not a trustworthy last-modified timestamp. Use only in sandbox. For high assurance, prefer explicit `ExpiresUtc` with a controlled deployment pipeline and a human review.

## 5. Scheduling / run

- `daily-cost.yml`: daily **08:00 UTC**, year-round; 09:00 UK in BST, 08:00 UK in GMT.
- `cleanup.yml`: hourly at minute 17 UTC, preview only.
- To delete: Actions > Azure Guard - cleanup > Run workflow > `delete=true` > approve environment review. Azure deletion may take time; `--no-wait` confirms only submission.

The monitor reports month-to-date actual cost; **not sponsorship credit balance**. Sponsorship availability is billing-specific. Cost Management data may lag. Failure of the query should not be interpreted as £0 spend.

## 6. Before trusting it

Review the scripts, verify Azure role scope, test Teams webhook with a harmless message, run both workflows manually, ensure preview excludes protected groups, and test deletion on an empty throwaway RG only. For production-grade expiration, add durable audit logging, retention, and confirmation of successful deletion.
