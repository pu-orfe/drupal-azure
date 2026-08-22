# Authentication

**Read this before letting anyone use the site.** How people log in.

Not to be confused with **[GitHub Actions](github-actions.md)**, which is about
how *CI* authenticates to Azure.

Every deployment from this template is **Entra ID only**. There are no working
local passwords: account 1 exists because Drupal requires it, and every other
account authenticates through Entra.

That is a deliberate constraint, not a default, and it changes three things about
how the site is configured.

---

## The modules

| Module | Source | Role |
|---|---|---|
| `drupal/azure_oauth_sso` | contrib, Composer | The OAuth login route. Redirects to Entra, consumes the callback, maps the returning identity to a Drupal account |
| `drupal/externalauth` | contrib, Composer (dependency) | The account↔external-identity mapping table. What makes "this Entra object is this Drupal user" durable |
| `drupal/genpass` | contrib, Composer | Generates a random password on every account, and hides the field |
| `azure_logic_app_mailer` | **submodule**, `pu-orfe/azure_logic_app_mailer` | Outbound mail via a managed-identity-authenticated Azure Logic App |

All three contrib modules are in `composer.json`. The mailer is a submodule
because it is first-party, has no drupal.org release, and depends on Azure
resources — so it is versioned alongside the sites that use it rather than
vendored into each one:

```bash
git clone --recurse-submodules <this repo>
# or, in an existing checkout:
git submodule update --init --recursive
```

The Docker build needs the submodule present. `actions/checkout` does not fetch
submodules by default — add `with: submodules: true` to any workflow that builds
the image, or the mailer is silently absent from it.

---

## Why `genpass` is not optional

Accounts are NetID-shaped: username is the NetID, email is derived from it, and
the password is a random value that is **never displayed and never used**.

Without `genpass`, three things go wrong, and none of them announces itself:

- **`/admin/people/create` demands a password.** An administrator creating an
  account has to invent one, which means either a weak shared convention or a
  real credential that now exists and is written down somewhere.
- **Programmatic account creation gets an empty password.** A bulk NetID import,
  or any `User::create()` without an explicit password, produces an account whose
  password hash is for the empty string. Drupal will not authenticate it — until
  a module or a future core change makes empty-password login behave differently,
  at which point every imported account is open.
- **`/user/password` becomes a working side channel.** A password reset link
  lets someone set a local password and bypass Entra entirely, which quietly
  undoes the "Entra only" property the deployment is built on.

`genpass` closes the first two by generating a strong random value and hiding the
field. Close the third in site configuration by removing the "reset password"
route from anonymous users, and point `/user/login` at `/oauth/login`.

---

## What the settings overlay contributes

`docker/drupal/settings.azure.php` does not configure SSO — that is site
configuration, exported to `config/sync`. What it does provide is the three
things an OAuth flow needs from the *environment*, all of which are easy to get
wrong behind a TLS-terminating ingress:

**HTTPS normalisation.** The ingress terminates TLS and forwards over HTTP, so
without normalisation Drupal builds `http://` absolute URLs. The redirect URI
Drupal sends to Entra then does not match the one registered on the app
registration, and the failure is Entra's generic
`AADSTS50011: redirect URI mismatch` — which points at the app registration
rather than at the proxy.

**Reverse-proxy trust.** Without it Drupal sees the ingress as the client for
every request, so `X-Forwarded-*` is ignored — which breaks the same absolute
URLs and makes flood control treat all traffic as one IP.

**Trusted hosts.** Drupal builds those absolute URLs from the `Host` header, so
an untrusted or over-permissive host list is how a password-reset link ends up
pointing at somebody else's domain. Built from `DRUPAL_TRUSTED_HOSTS` with proper
escaping; see `tests/php/TrustedHostsTest.php`, where most of the assertions are
about which hosts are *refused*.

---

## Two integration shapes, and which to use

There are two ways to put Entra in front of a Drupal container on Azure, and the
choice is not cosmetic.

### Platform authentication at the gateway ("Easy Auth")

The platform authenticates the request before it reaches the container and
injects `X-MS-CLIENT-PRINCIPAL-*` headers. A small module reads those headers and
opens a Drupal session.

- **For:** nothing unauthenticated ever reaches PHP, which is a genuine
  reduction in attack surface. No OAuth code in the application at all.
- **Against:** the container cannot be developed or tested locally the same way,
  because those headers only exist in production — so the login path is dormant
  in every other environment, which is precisely the path you most want to
  exercise. Any header-trusting module must also be certain the headers cannot be
  spoofed, which depends on the gateway being impossible to bypass.

### In-application OAuth (what this template uses)

Drupal owns the login route and performs the OAuth exchange itself.

- **For:** one code path in every environment. Roles, account mapping and the
  authorisation decision live in Drupal's own configuration, where they can be
  exported and reviewed.
- **Against:** anonymous requests do reach PHP, so the ingress allow-list and
  Drupal's own permissions are both doing real work.

Both live deployments this template draws on converged on the second, after
starting with the first — the deciding factor was that a header-driven login path
which cannot be exercised outside production is a path nobody can safely change.

---

## Patching contrib

`azure_oauth_sso` frequently needs a small change — the login route, or the
controller's account-matching logic. Both live deployments do it by copying
replacement files over the installed module in the Dockerfile:

```dockerfile
COPY docker/patches/azure_oauth_sso.routing.yml \
     web/modules/contrib/azure_oauth_sso/azure_oauth_sso.routing.yml
```

That works and has one sharp edge worth naming: a `COPY` over a contrib path is
**silent** when the module restructures. The file lands somewhere harmless, the
patch has no effect, and SSO breaks at runtime rather than at build time. If you
patch this way, assert the target afterwards — `verify-production-image.sh` is
the place, and it already has the pattern for asserting a file is present and
non-empty in the built image.

The alternative is `cweagans/composer-patches` with a real diff, which fails
loudly at install time when a patch stops applying. Prefer it for anything you
expect to carry across more than one module release.

---

## Setting up the app registration

The redirect URIs must include every hostname the site answers on — the Container
Apps default domain *and* every custom domain — because Drupal builds the
redirect URI from the request's `Host` header:

```bash
APP_ID=$(az ad app create --display-name "drupal-sso" --query appId -o tsv)
az ad sp create --id "$APP_ID"

FQDN=$(az containerapp show -n app-drupal -g rg-drupal-prod \
  --query properties.configuration.ingress.fqdn -o tsv)

az ad app update --id "$APP_ID" --enable-id-token-issuance true \
  --web-redirect-uris \
    "https://$FQDN/oauth/login" \
    "https://drupal.example.edu/oauth/login"
```

A client secret is needed for the OAuth exchange. Put it in the same Key Vault as
the other secrets and reference it from the container app, rather than storing it
as a literal — the reasoning and the rotation procedure are in
[secrets.md](secrets.md), and they apply unchanged.

A custom-domain cutover therefore needs the redirect URI added **before** the
domain goes live, or the first login on the new hostname fails with a redirect-URI
mismatch. Add the domain to `DRUPAL_TRUSTED_HOSTS` at the same time.

---

## See also

- **[Secrets](secrets.md)** — where the client secret goes, and how to rotate it.
- **[Configuration](configuration.md)** — `DRUPAL_TRUSTED_HOSTS` and the session
  variables that an OAuth flow depends on.
- **[Getting started](getting-started.md)** — if you have not deployed yet.
