# Migrating an existing site

**Read this if** you have a Drupal site somewhere else — cPanel, a VM, another
cloud — and you want it running on this template.

**If you are starting fresh,** skip it. `scripts/local-dev.sh` and
`scripts/azure-up.sh` give you an empty site with no migration involved.

---

## The order that matters

The single most valuable structural rule, and the one everything below depends on:

> **Audit before you move anything, and keep the destructive step separate from
> the step that makes it live.**

Concretely: find out what the source data actually is, configure the target to
match, move the data while production keeps serving, verify, and only then
repoint. If a check fails, the source has not been touched and there is nothing
to roll back — which also means the whole sequence can be rehearsed as often as
you like against live production data.

```
1. audit the source        ./scripts/migrate.sh --audit      ← always first
2. configure the target    MYSQL_COLLATION=… ./scripts/azure-up.sh
3. move the data           ./scripts/migrate.sh
4. verify                  row manifest + the checks below
5. repoint                 only after 4 passes
```

---

## 1. Audit the source

```bash
./scripts/migrate.sh --audit
```

Reports the source's database default collation, the collation of every table
grouped by count, the storage engines in use, and the server version. It changes
nothing and asks for no credentials it does not need.

Run this first, every time. The failure it prevents does not appear during the
migration at all — it appears months later, on the first module update that adds
a table. See [Collation](database.md#collation-the-one-that-will-bite-you).

Three things to look for in the output:

| If you see | Do this |
|---|---|
| A dominant collation that is not the template default | `export MYSQL_COLLATION='<that value>'` before deploying |
| `utf8` rather than `utf8mb4` | **Convert the source first.** 3-byte `utf8` cannot store emoji or some CJK, and `mysqldump` will replace them with `?` silently. See [database.md](database.md#3-byte-utf8-is-a-data-loss-bug-not-a-collation-choice) |
| `MyISAM` tables | Convert to InnoDB. MyISAM has no transactions, so `--single-transaction` silently excludes those tables from the dump's consistency guarantee |

## 2. Configure the target to match

```bash
export MYSQL_COLLATION='utf8mb4_unicode_ci'   # whatever the audit reported
./scripts/azure-up.sh
```

This is the step people skip, and it is the reason the audit exists.

## 3. Move the data

```bash
./scripts/migrate.sh
```

It exports the database over SSH, sanitises the dump, imports it, then copies the
public and private files to the Azure Files shares.

### What it asks you for, and what it does not

**On the Azure side it asks for the resource group and nothing else.** The
hostname, the admin login, the database name and the storage account are read back
from Azure, and the password comes from Key Vault — so you never see it, never
paste it, and it is unset again as soon as the import finishes.

Earlier guidance for this step was:

```bash
export AZURE_MYSQL_USER=drupaladmin
export AZURE_MYSQL_PASS="$MYSQL_ADMIN_PASSWORD"
```

Both lines are now unnecessary. They were also a bad idea: `export` puts a
credential in your shell history and in every child process for the rest of the
session, and `drupaladmin` is only this template's *default* admin login — reading
it from the server is correct on a deployment that chose otherwise. See
[Secrets](secrets.md#reading-a-secret-you-actually-need).

**On the source side it does ask for the database password**, because that
credential belongs to the system you are leaving and nothing here can know it.
Input is hidden, and it is delivered to the remote host over stdin rather than on
a command line — `mysql -p<password>` would put it in that host's process list,
readable by any other user on the box.

**A note on reachability.** The MySQL server this template provisions has no
public endpoint — it sits on a delegated subnet with public access disabled. So
the import has to run from inside the VNet. Two options:

- run the script from a VM or a job inside the VNet, or
- temporarily allow your address, import, then remove the rule.

The second is quicker and is what most people do. Do not forget the removal.

### What the script does to the dump, and why

| Step | Reason |
|---|---|
| `--no-tablespaces` | Otherwise `mysqldump` needs the `PROCESS` privilege, which a shared-hosting user does not have. Fails as "access denied", which reads like a credentials problem |
| `--default-character-set=utf8mb4` | The client default is 3-byte `utf8` on older versions, which mangles 4-byte characters into `?` with no error |
| Strips `DEFINER=` | Names a user that does not exist on the target — and on Azure *cannot*, because `SUPER` is not granted |
| `SET sql_mode='NO_AUTO_VALUE_ON_ZERO'` on import | Drupal's anonymous user is `uid 0`. Without it MySQL renumbers it to 1, colliding with the admin account, and **anonymous visitors appear to be logged in as the administrator** |
| Reports rather than rewrites a `0900_ai_ci` collation | Rewriting silently changes comparison and sort semantics. The decision is yours to make deliberately |

It then *verifies* the anonymous user survived rather than assuming it did.

## 4. Verify

### The row manifest

The right way to prove a database migration moved everything is a **row-count
manifest**: `SELECT table_name, COUNT(*)` for every table on the source, the same
on the target, and a byte-order diff of the two.

Two details make the difference between a check that works and one that cries
wolf on every run.

#### Compare in byte order, not the server's collation order

Sort the manifest with `LC_ALL=C sort`, not with `ORDER BY table_name`. The two
servers may order identifiers differently — that is the whole reason you are
migrating collations — so a manifest ordered by the server produces a diff full
of reordered-but-identical lines.

#### Scope it to tables that do not churn

Even with the site in maintenance mode, Drupal keeps writing. A manifest taken
across the dump/restore window will legitimately differ on:

```
cache_*            every cache bin
cachetags
key_value_expire
sessions
watchdog
semaphore
flood
queue
```

A real cutover attempt failed its gate on exactly this: `cache_data` 73 → 39,
`cache_discovery` 65 → 52, `key_value` 791 → 790. Nothing was wrong; the
manifest was measuring the wrong thing.

Two ways to handle it, and the second is better:

1. **Exclude the volatile tables** from the manifest by name. Simple, and it
   hard-codes an assumption about which tables are volatile — which is
   site-specific and changes with the module set.
2. **Measure which tables were quiescent.** Take the manifest twice on the source,
   a few seconds apart, with maintenance mode already on. Any table whose count
   moved between the two is volatile *on this site, right now*; compare only the
   rest. Tables that did not move are the ones whose counts genuinely have to
   match.

Take the manifest **after** maintenance mode is on, not before — otherwise the
window between the two is unbounded and includes ordinary traffic.

### Check the things a row count cannot see

A matching row count says nothing about collation or about the anonymous user, so
assert those separately on the target:

```sql
-- Must be zero on both counts, or a later updb will create untraversable tables.
SELECT COUNT(*) FROM information_schema.tables
 WHERE table_schema = DATABASE() AND table_collation = 'utf8mb4_0900_ai_ci';
SELECT COUNT(*) FROM information_schema.columns
 WHERE table_schema = DATABASE() AND collation_name = 'utf8mb4_0900_ai_ci';

-- The ascii and _bin populations must match the SOURCE's counts exactly.
SELECT COUNT(*) FROM information_schema.columns
 WHERE table_schema = DATABASE() AND character_set_name = 'ascii';
SELECT COUNT(*) FROM information_schema.columns
 WHERE table_schema = DATABASE() AND collation_name LIKE '%\_bin';

-- Exactly one, or anonymous visitors are somebody else.
SELECT COUNT(*) FROM users WHERE uid = 0;
```

Then make Drupal itself bootstrap against the target before repointing anything.
A schema that passes every SQL assertion and still cannot boot Drupal is a real
outcome, and the cheapest place to discover it is before the switch.

---

## 5. Repoint

Only once step 4 passes. Until this moment the source is untouched and there is
nothing to roll back.

```bash
# App Service
az webapp config appsettings set -n "$AZURE_APP_NAME" -g "$AZURE_RESOURCE_GROUP" \
  --settings DRUPAL_DB_HOST="<new-server-fqdn>"

# Container Apps
az containerapp update -n "$AZURE_APP_NAME" -g "$AZURE_RESOURCE_GROUP" \
  --set-env-vars DRUPAL_DB_HOST="<new-server-fqdn>"
```

Both create a restart, so the entrypoint runs against the new server: it waits
for an authenticated query to succeed, takes a validated backup, and applies any
pending schema work. Watch it:

```bash
./scripts/azure-logs.sh
./scripts/verify-site.sh "https://<host>"
```

If it does not come up, the old server is still there and still correct —
repoint back.

### Guard the destructive target

If you are scripting the data movement rather than running `migrate.sh` once, this
is the check that matters most.

The obvious safety check after dropping every table is "assert 0 tables remain".
That verifies the drop **succeeded**. It says nothing about **which server** was
dropped — if the target hostname ever resolves to production, that assertion
cheerfully confirms you have wiped it.

So allow-list the target, with checks a single typo cannot satisfy together:

1. the target must be string-equal to the new server's FQDN;
2. it must **not** be string-equal to the old server's FQDN — a separate check, so
   an editing mistake in one constant cannot pass both;
3. `SELECT VERSION()` on the target must report the expected version, which
   catches a DNS record repointed underneath the name.

Hard-code both FQDNs at the guard. Do not read them from a flag, an environment
variable, or a shared config file whose default may still be the old server —
that default is exactly the value that must never reach a `DROP`.

---

## Files as well as the database

`migrate.sh` copies both file directories, and the reason they are separate
shares is worth knowing: the public one grows without bound and the private one
holds whatever was made private for a reason. Both are default-deny and reachable
only from the app subnet.

If you restore a database later, **restore the files from the same point in
time**. A database rolled back to yesterday against current files has broken
every managed-file reference in between — Drupal renders file fields pointing at
files that do not exist, and holds rows for files that were deleted. See
[Operations → Restoring](operations.md#restoring-the-database).

---

## See also

- **[Database settings](database.md)** — what each setting does and why.
- **[Troubleshooting](troubleshooting.md)** — the errors this process produces,
  by symptom.
- **[Production learnings](production-learnings.md)** — the incidents that shaped
  the checks above.
