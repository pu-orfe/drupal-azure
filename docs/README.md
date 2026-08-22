# Documentation

Start at the repository [README](../README.md) if you have not already.

## In reading order

| | | |
|---|---|---|
| 1 | **[Getting started](getting-started.md)** | Local → deployed, end to end |
| 2 | **[Choosing a platform](choosing-a-platform.md)** | App Service or Container Apps |
| 3 | **[Configuration](configuration.md)** | Every variable, and where it comes from |
| 4 | **[Authentication](authentication.md)** | Entra-only logins |
| 5 | **[Secrets](secrets.md)** | Key Vault and rotation |
| 6 | **[GitHub Actions](github-actions.md)** | OIDC federation for CI |

## When you need them

| | |
|---|---|
| **[Troubleshooting](troubleshooting.md)** | Something is broken. Organised by symptom |
| **[Operations](operations.md)** | The day-two runbook |
| **[Migrating a site](migrating-a-site.md)** | Bringing an existing Drupal site in |

## Background

Not needed to use the template; needed before changing it.

| | |
|---|---|
| **[Design notes](design-notes.md)** | Why the image, entrypoint and probes are shaped this way |
| **[Database settings](database.md)** | Collation, isolation, and the traps |
| **[Production learnings](production-learnings.md)** | The incidents behind the decisions |

## A note on where the reasoning lives

These documents cover *what* and *how*. The *why* for any individual line is in a
comment next to that line — the Dockerfile, `docker-entrypoint.sh`,
`docker/entrypoint-lib.sh`, `docker/drupal/settings.azure.php` and the Bicep
modules are all commented at length, because a reason kept in a separate document
is a reason nobody reads before deleting the code.

[Production learnings](production-learnings.md) is the index tying the two
together: one row per decision, pointing at the file and the test.
