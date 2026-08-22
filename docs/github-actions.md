# GitHub Actions → Azure authentication

**Read this once**, when you are ready to hand deploys to CI. After it, a push
to `main` builds, verifies, rolls out and smoke-tests on its own.

Not to be confused with **[Authentication](authentication.md)**, which is about
how *people* log into the site.

This repository authenticates to Azure with **OpenID Connect federated
credentials**. There is no service principal password, no `AZURE_CREDENTIALS`
JSON blob, and nothing to rotate.

The three values stored as repository secrets — `AZURE_CLIENT_ID`,
`AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` — are *identifiers*, not credentials.
They are useless without a federated credential that trusts your specific
repository and ref.

## How it works

1. The workflow requests a short-lived OIDC token from GitHub's identity
   provider. This needs `permissions: id-token: write`; without it the token
   request fails and `azure/login` reports a missing-token error rather than an
   authentication error.
2. `azure/login@v2` exchanges that token with Entra ID.
3. Entra ID validates that the token's `subject` claim matches a federated
   credential registered on the app — which pins it to a repository, and within
   that repository to a branch, tag, environment or pull-request context.
4. The resulting access token lives for that job only.

---

## One-time setup

### 1. App registration and service principal

```bash
# Deliberately not APP_NAME: everywhere else in these docs that means the web app
# or container app. This is the Entra ID app registration, a different thing.
APP_REG_NAME="github-drupal-deploy"

az ad app create --display-name "$APP_REG_NAME"
APP_ID=$(az ad app list --display-name "$APP_REG_NAME" --query "[0].appId" -o tsv)
az ad sp create --id "$APP_ID"
```

### 2. Federated credential

```bash
GITHUB_ORG="your-org"
GITHUB_REPO="drupal-azure"

az ad app federated-credential create --id "$APP_ID" --parameters "{
  \"name\": \"github-main\",
  \"issuer\": \"https://token.actions.githubusercontent.com\",
  \"subject\": \"repo:${GITHUB_ORG}/${GITHUB_REPO}:ref:refs/heads/main\",
  \"audiences\": [\"api://AzureADTokenExchange\"],
  \"description\": \"Deploy from main\"
}"
```

The `subject` is the entire security boundary. One credential per context, and
each context must be added deliberately:

| Subject | Grants |
|---|---|
| `repo:org/repo:ref:refs/heads/main` | Pushes to main |
| `repo:org/repo:environment:production` | Jobs declaring `environment: production` — **the one to prefer** |
| `repo:org/repo:pull_request` | Any pull request, **including from a fork**. Do not add this for a credential with write access |

`deploy.yml`'s `rollout` job declares `environment: production`, so scoping the
credential to the environment rather than the branch lets you add required
reviewers on that environment and gate every production deploy behind a human.
The `subject` claim is checked by Entra ID, so this is not merely a GitHub-side
convention.

### 3. Role assignments

```bash
SUB_ID=$(az account show --query id -o tsv)
RG="rg-drupal-prod"                    # your resource group
ACR_NAME=$(az acr list -g "$RG" --query '[0].name' -o tsv)

# Deploy a new image, read outputs, shift traffic.
az role assignment create \
  --assignee "$APP_ID" --role "Contributor" \
  --scope "/subscriptions/${SUB_ID}/resourceGroups/${RG}"

# Push images.
ACR_ID=$(az acr show --name "$ACR_NAME" --query id -o tsv)
az role assignment create --assignee "$APP_ID" --role "AcrPush" --scope "$ACR_ID"
```

Contributor on the resource group is broader than the workflows need but is what
`az containerapp update` and the traffic commands actually require. Note what is
**not** granted: no Key Vault data-plane role. CI never reads a secret — the
container app resolves those itself with its own managed identity — so a
compromised workflow cannot exfiltrate the database password or the hash salt.

### 4. Repository configuration

**Settings → Secrets and variables → Actions**

| Secret | From |
|---|---|
| `AZURE_CLIENT_ID` | `$APP_ID` |
| `AZURE_TENANT_ID` | `az account show --query tenantId -o tsv` |
| `AZURE_SUBSCRIPTION_ID` | `az account show --query id -o tsv` |

| Variable | Example |
|---|---|
| `AZURE_RESOURCE_GROUP` | `rg-drupal-prod` |
| `AZURE_ACR_NAME` | from the `azure-up.sh` output |
| `AZURE_APP_NAME` | the web app or container app name |
| `AZURE_PLATFORM` | `appservice` (default) or `containerapps` |
| `AZURE_IMAGE_NAME` | `drupal` (optional; defaults to `drupal`) |

Variables rather than secrets for the names, deliberately: masking a resource
group name in the logs makes every failure harder to read and protects nothing.

---

## Until you have done this, the workflows skip

The Azure-dependent workflows check for their configuration and **skip** rather
than fail when it is absent — so a fresh clone does not produce red runs before
anyone has done anything wrong, and `drupal-cron.yml` in particular does not fail
every fifteen minutes.

| Workflow | Gated on |
|---|---|
| `deploy.yml` | a `preflight` job checking all three variables and `AZURE_CLIENT_ID` |
| `drupal-cron.yml` | `vars.AZURE_APP_NAME` |
| `scheduled-backup.yml` | `vars.AZURE_RESOURCE_GROUP` |
| `pull-request.yml`, `composer-update.yml`, `security-audit.yml` | nothing — they need no Azure access and work immediately |

They start running **by themselves** once the values exist. There is nothing to
uncomment, which is deliberate: the alternative — commenting out the trigger and
telling people to restore it after bootstrapping — reliably ends with nobody
remembering, and the first real deploy being a manual one.

If a deploy skips when you expect it to run, the run summary names the missing
value.

## Verifying

```bash
gh workflow run deploy.yml
gh run watch
```

The "Azure login (OIDC)" step succeeding is the whole test.

---

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `AADSTS70021: No matching federated identity record found` | The `subject` claim does not match any credential. Most often: the credential names a branch but the run is from a tag, a PR, or an environment | Print the claim — add a step running `echo "$ACTIONS_ID_TOKEN_REQUEST_URL"` context, or read the error's `subject` value — and add a credential for it |
| `AADSTS700016: Application not found` | Wrong `AZURE_CLIENT_ID`, or the service principal was never created | `az ad sp create --id "$APP_ID"` |
| `Unable to get ACTIONS_ID_TOKEN_REQUEST_URL` | `permissions: id-token: write` missing from the job or workflow | Add it. Note that setting `permissions` on one job removes the default for others |
| `AuthorizationFailed` on `containerapp update` | Missing Contributor at the right scope | Check the scope is the resource group, not the subscription or the app |
| `denied: requested access to the resource is denied` on push | Missing AcrPush | Assign it on the registry's resource id |
| Login succeeds, `containerapp` commands fail with "not recognized" | The CLI extension is not installed on the runner | `az extension add --name containerapp --upgrade` — `deploy.yml` does this |

---

## Migrating from `AZURE_CREDENTIALS`

If a previous setup used the JSON service-principal blob:

1. Do steps 1–4 above.
2. Delete the `AZURE_CREDENTIALS` secret.
3. Delete the old service principal's password, or the principal itself if nothing
   else uses it:
   ```bash
   az ad app credential delete --id <old-app-id> --key-id <key-id>
   ```

Deleting the secret from GitHub does not invalidate the credential — it is still
live in Entra ID, and still in the repository's audit history. Revoking it at the
Azure end is the step that matters.

---

## See also

- **[Secrets](secrets.md)** — why CI is granted no Key Vault access at all.
- **[Operations](operations.md)** — what to do when a deploy goes wrong.
- **[Getting started](getting-started.md)** — the manual deploy this replaces.
