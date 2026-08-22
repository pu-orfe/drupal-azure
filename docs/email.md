# Outbound email

**Read this before your site needs to send anything** — a password reset, a
notification, a cron report.

**The short version:** the infrastructure is created for you by
`scripts/azure-up.sh`. One step is manual and cannot be otherwise. Run:

```bash
./scripts/setup-email.sh          # wires it up, then prints where to click
./scripts/setup-email.sh --status # is it authorised?
./scripts/setup-email.sh --test you@example.edu
```

---

## Why it is built this way

A Drupal container has no mail transport agent. Left alone, Drupal's default mail
system **accepts every message and delivers none** — no error, no bounce, nothing
in a log. That silence is the reason this is worth setting up deliberately rather
than discovering when a user cannot reset their password.

The options, and why this one:

| Approach | Why not |
|---|---|
| SMTP credentials | Modern tenants disable basic auth for SMTP. Where it still works it means a long-lived password, with send-as rights, sitting in the app's configuration and rotated by nobody |
| SendGrid / Mailgun | Another vendor, another credential, and mail arrives from outside the institution's domain — which is what DMARC exists to reject |
| Graph API directly | Correct, but needs an app registration with `Mail.Send` **application** permission: tenant-wide consent to send as *any* mailbox. Hard to get approved, and rightly so |
| **A Logic App + Office 365 connector** | Sends as **one** mailbox, consented once by a human who controls it. The app holds no credential at all |

The last row is the point. The site authenticates to the Logic App with its
**managed identity** — a token fetched per send, nothing stored, nothing to
rotate — and the Logic App holds the mailbox authorisation.

## The shape of it

```
Drupal  ──managed-identity token──▶  Logic App  ──O365 connector──▶  the mailbox
        (azure_logic_app_mailer)      (HTTP trigger)                (consented once)
```

| Piece | Where it comes from |
|---|---|
| Logic App + O365 connection | `infra/modules/email.bicep`, deployed by `azure-up.sh` |
| The endpoint URL on the app | `setup-email.sh` (it only exists after the workflow does) |
| The mailbox authorisation | **A human, in the portal.** Once |
| The Drupal side | `azure_logic_app_mailer` (submodule) + `mailsystem`, wired in the settings overlay |

## The manual step, and why it stays manual

The Office 365 connection is created **unauthorised**. Someone has to open it in
the portal and sign in as the sending account.

That is not a gap in the automation. Signing in is how a human proves they
control the mailbox — and it is *precisely* what buys you a deployment with no
mailbox password and no tenant-wide `Mail.Send` grant. A service principal cannot
assert it on their behalf, by design.

`setup-email.sh` prints the exact URL to open. Two things worth deciding before
you click:

- **Use a shared or service mailbox**, not a person's. Every message the site
  sends will come from it, and a personal mailbox leaves with the person.
- **The consent belongs to whoever signs in.** If they lose access to that
  mailbox, mail stops and the connection has to be re-authorised.

## Two controls on who can trigger it

An HTTP-triggered Logic App is a URL that sends mail as your institution, so it
gets two independent controls:

**An AAD policy on the trigger.** The caller must present a token from this
tenant, minted for ARM. Where the template can determine the app's identity it
also pins the `sub` claim, which narrows it from *any principal in the tenant* to
*this app*. That distinction matters more than it sounds: the usual recipe checks
only issuer and audience, which on a shared tenant admits a large set of
principals you have never heard of.

**An IP allow-list**, populated from the app's own egress addresses. This template
wires it in the same deployment that creates the app; the version this is modelled
on had to discover the addresses with a follow-up script, so the workflow spent
its first minutes callable from anywhere.

And one thing deliberately *not* used: `setup-email.sh` **strips the SAS signature**
from the callback URL before storing it, and refuses to store one that still
carries a signature. A SAS is a bearer credential in a query string — keeping it
would make the AAD policy decorative, because a leaked app setting would be enough
to send mail as the institution.

`./scripts/setup-email.sh --status` reports both controls, and warns when the
`sub` claim is absent.

## The identity subtlety

This is the part most likely to be "tidied" into a broken state, so it is worth
knowing why the app has **two** managed identities.

| Identity | Why it exists |
|---|---|
| **User-assigned** | So its AcrPull and Key Vault grants can be made *before* the app is created. A system-assigned identity does not exist until then, which would make the first deployment fail |
| **System-assigned** | Because the mail plugin requests a managed-identity token **without a `client_id`**, and with only user-assigned identities attached that request has no unambiguous answer |

And the `sub` claim on the Logic App trigger is pinned to the **system-assigned**
principal, not the user-assigned one — because that is the identity the plugin's
token is actually issued to.

Pinning the user-assigned principal instead *looks* right and rejects every send
with a 401. Dropping `SystemAssigned` from the identity block does the same. Both
fail at send time, which means the first symptom is a password reset that never
arrives rather than a deployment error.

`tests/shell/run.sh` asserts all three facts, so a change that breaks this fails
CI rather than the mail.

### If sends are 401ing

Compare what the trigger requires against what the app actually has:

```bash
# what the Logic App expects
az resource show -g "$RG" --resource-type Microsoft.Logic/workflows --name "$LOGIC_APP" \
  --query "properties.accessControl.triggers.openAuthenticationPolicies.policies.aad_policy.claims" -o table

# what the app's system-assigned identity actually is
az webapp show -n "$APP" -g "$RG" --query identity.principalId -o tsv
```

If the `sub` value and the principal ID differ, the app's identity was recreated
after the Logic App was deployed. Re-run `./scripts/azure-up.sh` to bring the
claim back into line.

## Verifying

```bash
./scripts/setup-email.sh --test you@example.edu
```

This goes through **Drupal's mail system**, not by calling the Logic App
directly. Calling the workflow from your laptop proves the workflow works and says
nothing about whether Drupal can reach it — which is the half that actually
breaks, because the app's identity and its egress address are both involved.

If nothing arrives, the Logic App's run history shows whether the request even
landed:

```bash
az rest --method get --uri "/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Logic/workflows/$LOGIC_APP/runs?api-version=2016-06-01&\$top=5"
```

| Symptom | Likely cause |
|---|---|
| No runs at all | Drupal never called it — check `AZURE_LOGIC_APP_MAIL_URL` is set, and that the app's egress is in the IP allow-list |
| Runs failing at the connector | The connection is not authorised, or the consent has lapsed |
| Runs succeeding, no mail | Delivery-side: check the sending mailbox's own rules, and the recipient's spam handling |
| 401 on the trigger | The identity is not permitted — if `sub` is pinned, confirm it matches the app's current managed identity |

## Skipping it

```bash
DEPLOY_EMAIL=false ./scripts/azure-up.sh
```

Reasonable for a review environment. Be aware that Drupal will then fall back to
its default mail system, which on this container accepts and discards — so do not
use a mail-less environment to test anything that depends on mail arriving.

## See also

- **[Configuration](configuration.md)** — `AZURE_LOGIC_APP_MAIL_URL` and the rest.
- **[Authentication](authentication.md)** — the same submodule pattern, for the
  Entra ID pieces.
- **[Secrets](secrets.md)** — why this needs no credential, and what to do with
  the ones that remain.
