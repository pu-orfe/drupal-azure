# GitHub Actions → Azure OIDC Authentication

This project uses **OpenID Connect (OIDC) federated credentials** for GitHub Actions to authenticate with Azure. No long-lived secrets (PATs, service principal passwords, or JSON credential blobs) are stored in GitHub.

## How It Works

1. GitHub Actions requests a short-lived OIDC token from GitHub's identity provider
2. The `azure/login@v2` action exchanges that token with Azure AD for an access token
3. Azure validates that the token came from the correct GitHub repo/branch/environment
4. The access token is used for the remainder of the job (ACR push, container app deploy, etc.)

Tokens are scoped to a single workflow run and expire automatically.

## One-Time Setup

### 1. Create an Azure AD App Registration

```bash
# Create the app registration
az ad app create --display-name "github-drupal-deploy"

# Note the appId from the output — this is your AZURE_CLIENT_ID
APP_ID=$(az ad app list --display-name "github-drupal-deploy" --query "[0].appId" -o tsv)

# Create a service principal for the app
az ad sp create --id "$APP_ID"
```

### 2. Add Federated Credential (ties GitHub repo to Azure identity)

```bash
# Replace with your GitHub org/user and repo name
GITHUB_ORG="your-github-org"
GITHUB_REPO="orfe-drupal-azure"

az ad app federated-credential create --id "$APP_ID" --parameters '{
  "name": "github-main-branch",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:'"${GITHUB_ORG}/${GITHUB_REPO}"':ref:refs/heads/main",
  "audiences": ["api://AzureADTokenExchange"],
  "description": "GitHub Actions deploy from main branch"
}'
```

> **Note:** The `subject` field controls which branches/environments can authenticate.
> For additional branches or pull requests, create additional federated credentials:
> - `repo:org/repo:ref:refs/heads/develop` — develop branch
> - `repo:org/repo:environment:production` — GitHub environment
> - `repo:org/repo:pull_request` — PRs (use cautiously)

### 3. Grant Azure Permissions

```bash
# Get your subscription ID
SUB_ID=$(az account show --query id -o tsv)

# Grant Contributor role on the resource group
az role assignment create \
  --assignee "$APP_ID" \
  --role "Contributor" \
  --scope "/subscriptions/${SUB_ID}/resourceGroups/rg-drupal-prod"

# Grant AcrPush role on the container registry
ACR_ID=$(az acr show --name acrdrupalprod --query id -o tsv)
az role assignment create \
  --assignee "$APP_ID" \
  --role "AcrPush" \
  --scope "$ACR_ID"
```

### 4. Configure GitHub Secrets

In your GitHub repository, go to **Settings → Secrets and variables → Actions** and add these **secrets**:

| Secret                   | Value                                          |
|--------------------------|-------------------------------------------------|
| `AZURE_CLIENT_ID`       | The `appId` from step 1                         |
| `AZURE_TENANT_ID`       | Your Azure AD tenant ID (`az account show --query tenantId -o tsv`) |
| `AZURE_SUBSCRIPTION_ID` | Your subscription ID (`az account show --query id -o tsv`)          |

These three values replace the old `AZURE_CREDENTIALS` JSON blob.

### 5. Verify (optional)

After setup, trigger a manual workflow run and check that the "Azure Login (OIDC)" step succeeds.

## Migrating from AZURE_CREDENTIALS

If you previously used `AZURE_CREDENTIALS` (a JSON service principal secret):

1. Complete steps 1-4 above
2. Remove the `AZURE_CREDENTIALS` secret from GitHub
3. Delete the old service principal if it's no longer needed:
   ```bash
   az ad sp delete --id <old-service-principal-appId>
   ```

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| `AADSTS70021: No matching federated identity record found` | Subject claim mismatch | Verify the federated credential `subject` matches your branch/environment |
| `AADSTS700016: Application not found` | Wrong client ID | Check `AZURE_CLIENT_ID` matches the app registration |
| `AuthorizationFailed` | Missing role assignment | Ensure the service principal has Contributor + AcrPush roles |
| `id-token: write permission missing` | Workflow permissions | Ensure `permissions: id-token: write` is set in the workflow |
