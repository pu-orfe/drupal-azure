# Database settings

**Read this if** you are migrating an existing site, changing a database setting,
or wondering why a query started failing with `ERROR 1267`.

**If you are just deploying a fresh site,** you do not need any of it — the
defaults are correct and `scripts/azure-up.sh` applies them. Come back when
something surprises you.

## The short version

Several settings here look like tuning and are not. Each has a failure mode that
appears long after the mistake, somewhere that does not point back to it.

| Setting | Where | Why it matters |
|---|---|---|
| `collation` | `settings.azure.php`, `mysql.bicep`, `docker-compose.yml` | **The big one.** Get it wrong and a `drush updb` months from now creates tables that cannot be joined to the existing ones |
| `isolation_level` | `settings.azure.php` | `READ COMMITTED` drops InnoDB's gap locks. Drupal recommends it and flags its absence |
| `sql_mode` | `mysql.bicep` | MySQL 8's default includes `ONLY_FULL_GROUP_BY`, which several contrib modules' Views queries violate |
| `require_secure_transport` | `mysql.bicep` | Stays **ON**. The usual "fix" for a TLS error turns encryption off for every client |
| `max_allowed_packet` | `mysql.bicep` | The 4 MB default truncates a real Drupal dump mid-restore, reported as "server has gone away" |
| `version` | `mysql.bicep` | Pinned, so a rebuild cannot land on an untested engine |
| `autoGrow` | `mysql.bicep` | A full disk stops a Drupal site rather than degrading it |

The three that must **agree with each other** are the collation settings. There
is a test that checks they do: `tests/shell/run.sh`.

---

## Collation: the one that will bite you

### The mechanism

Drupal's MySQL schema layer always emits `DEFAULT CHARACTER SET utf8mb4` for a new
table, and appends `COLLATE <value>` **only when a collation is set in
`settings.php`** — `core/modules/mysql/src/Driver/Database/mysql/Schema.php`.

Here is the part that catches people out. A `CREATE TABLE` that names a
**character set** but no collation takes the **character set's** default
collation — not the database's. On MySQL 8 that is `utf8mb4_0900_ai_ci`.

Which means none of the following fixes it:

| Attempted fix | Why it does not work |
|---|---|
| `ALTER DATABASE … COLLATE utf8mb4_unicode_ci` | The charset default in the `CREATE TABLE` wins over the database default |
| `--collation-server=utf8mb4_unicode_ci` | Same: the statement names a charset, so the charset's default applies |
| Setting the session collation | New-table collation does not come from the session at all |

Setting the `collation` key in `settings.php` is the only thing that fixes it,
because it is the only thing that puts `COLLATE` into the statement.

**Measured, not theorised.** Loading a real production dump into `mysql:8.0.46`
reproduced it: three tables whose `CREATE TABLE` declared `CHARSET=utf8mb4` with
no `COLLATE` landed on `utf8mb4_0900_ai_ci` while the other 190 stayed
`utf8mb4_unicode_ci` — with `--collation-server` set to `unicode_ci` throughout.

And joining a `utf8mb4_unicode_ci` column to a `utf8mb4_0900_ai_ci` one fails
outright:

```
ERROR 1267 (HY000): Illegal mix of collations
  (utf8mb4_unicode_ci,IMPLICIT) and (utf8mb4_0900_ai_ci,IMPLICIT) for operation '='
```

### Why this is not obvious

The risk is **not** literal comparisons. `WHERE name = 'x'` works fine: MySQL
coerces the literal to the column's collation.

The risk is that tables created *later* — by a `drush updb` after a module
update, months after the migration — get the database default, and then refuse to
join everything that came before. The site works perfectly until the update that
adds a table, and the error names two collations without any hint of where either
came from.

### What this template does

Three places must agree, and there is a test that asserts they do
(`tests/shell/run.sh`, "consistency"):

| | |
|---|---|
| `infra/modules/mysql.bicep` | `param collation` — the **database default**, what a bare `CREATE TABLE` inherits |
| `docker/drupal/settings.azure.php` | `'collation' => …` — what Drupal appends to `CREATE TABLE` |
| `docker-compose.yml` | `--collation-server=…` — so local development reproduces production |

The default is `utf8mb4_general_ci`, which is what Drupal uses for a fresh
install.

### If you are migrating an existing site

**Do not assume.** Run the audit:

```bash
./scripts/migrate.sh --audit
```

It reports the source's database default, the collation of every table grouped by
count, and the storage engines in use. Set the target to whatever the *data* is
on:

```bash
export MYSQL_COLLATION='utf8mb4_unicode_ci'   # for example
./scripts/azure-up.sh
```

Common answers and what they mean:

| Source collation | Typical origin |
|---|---|
| `utf8mb4_general_ci` | A site installed by Drupal on MySQL 5.x |
| `utf8mb4_unicode_ci` | An older site, or one migrated with an explicit conversion |
| `utf8mb4_0900_ai_ci` | Installed directly on MySQL 8 with no collation pinned |
| `utf8_general_ci` | **3-byte utf8.** Not utf8mb4. Fix this before migrating — see below |

### 3-byte `utf8` is a data-loss bug, not a collation choice

MySQL's `utf8` is a 3-byte subset that cannot store any character outside the
BMP: emoji, some CJK, some mathematical symbols. Inserting one either truncates
the string or replaces the character, depending on `sql_mode` — and `mysqldump`
with the wrong `--default-character-set` converts them to `?` with no error at
all.

If the audit reports `utf8` rather than `utf8mb4`, convert the source before
dumping:

```sql
ALTER DATABASE <db> CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
ALTER TABLE <each> CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
```

`migrate.sh` passes `--default-character-set=utf8mb4` to `mysqldump` for exactly
this reason.

### Fixing a mismatch after the fact — and the trap in the obvious fix

```sql
-- Inspect first. Three questions, three answers.
SELECT @@collation_database;
SELECT table_collation, COUNT(*) FROM information_schema.tables
 WHERE table_schema = DATABASE() GROUP BY table_collation;
SELECT character_set_name, COUNT(*) FROM information_schema.columns
 WHERE table_schema = DATABASE() GROUP BY character_set_name;
```

**Do not reach for `ALTER TABLE … CONVERT TO CHARACTER SET`.** It is the advice
you will find everywhere and it causes silent damage, for two independent
reasons.

#### It widens columns Drupal declared narrow on purpose

`CONVERT TO CHARACTER SET` rewrites **every** character column in the table,
including ones that are deliberately a different character set. Drupal declares a
lot of columns `ascii` — cache keys, hashes, machine names are ascii by
definition — and widening them to `utf8mb4` quadruples index width and changes
row sizes for no benefit whatsoever.

Measured on a real site: a blanket `CONVERT TO` silently widened 48 `ascii`
columns (the count went 317 → 269 ascii columns remaining). Nothing reported it.

#### It destroys `_bin` collations, which is corruption

Drupal declares certain columns binary on purpose so they compare
case-sensitively — `file_managed.uri`, and the `cid` column of every cache table.
"Normalising" those makes two values differing only in case compare **equal**.
That is not tidying, it is data corruption, and it surfaces as cache collisions
and file-URI collisions long afterwards.

#### What to do instead

Change the table default, then convert only the columns that actually need it:

```sql
-- 1. Table default only. Does not touch column definitions.
ALTER TABLE `drup_flood` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;

-- 2. Generate a per-column MODIFY for exactly the wrong columns, excluding
--    anything that is deliberately ascii or binary.
SELECT CONCAT('ALTER TABLE `', table_name, '` MODIFY `', column_name, '` ',
              column_type, ' CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci',
              IF(is_nullable = 'NO', ' NOT NULL', ''), ';')
  FROM information_schema.columns
 WHERE table_schema = DATABASE()
   AND collation_name IS NOT NULL
   AND collation_name <> 'utf8mb4_general_ci'
   AND character_set_name = 'utf8mb4'          -- leave ascii alone
   AND collation_name NOT LIKE '%\_bin';       -- leave binary alone
```

#### Guard it with counts taken from the SOURCE

Count the `ascii` columns and the `_bin` columns **before** you start, and assert
they are unchanged afterwards. A guard that compares its own before and after
catches damage the guard's own run caused and is blind to damage that was already
there — demonstrated on real data, where a `CONVERT TO` run beforehand had already
widened six columns and the self-consistency check then reported "379 → 379,
passed".

```sql
SELECT COUNT(*) FROM information_schema.columns
 WHERE table_schema = DATABASE() AND character_set_name = 'ascii';
SELECT COUNT(*) FROM information_schema.columns
 WHERE table_schema = DATABASE() AND collation_name LIKE '%\_bin';
```

Take a backup first regardless: these statements rewrite rows and hold a table
lock for the duration.

---

## Transaction isolation: `READ COMMITTED`

MySQL defaults to `REPEATABLE READ`. Drupal recommends `READ COMMITTED` and
flags its absence on the status report.

The reason core recommends it: under `REPEATABLE READ`, InnoDB takes **gap locks**
on range scans, which turns ordinary concurrent writes into lock waits and
deadlocks. `READ COMMITTED` drops the gap locks. The trade is that a row read
twice in one transaction can differ — Drupal's data access is written for that,
which is why it is the recommended level rather than merely a tuning option.

This matters more on Container Apps than on a single host: several replicas write
concurrently *by design*, and autoscaling means the concurrency changes without
anyone deciding it should.

Drupal issues `SET SESSION TRANSACTION ISOLATION LEVEL` per connection, so this
changes only our sessions. The server default is untouched and nothing else
sharing the server is affected.

---

## `sql_mode`: removing exactly one flag

`infra/modules/mysql.bicep` sets:

```
STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION
```

which is MySQL 8's default **minus `ONLY_FULL_GROUP_BY`**. Several long-standing
contrib modules' Views queries violate that flag, and Drupal core's own
requirements check flags it.

Note what this is not: the usual advice is to empty `sql_mode` entirely, which
also discards `STRICT_TRANS_TABLES` — and without that, MySQL silently truncates
over-long values and coerces invalid dates instead of erroring. Removing one flag
keeps every other strict check.

---

## TLS stays on

Azure MySQL Flexible Server ships with `require_secure_transport = ON`, and this
template keeps it on. The connection crosses a VNet, not a loopback.

A great many Azure-plus-Drupal writeups tell you to turn it off to fix a
connection error. That removes transport encryption for every client of the
server, in order to work around a client-side CA configuration problem. The image
already trusts Azure's chain — it roots in DigiCert Global Root CA, which is in
`ca-certificates` — so `DRUPAL_DB_SSL_MODE=verify` (the default) needs no
downloaded PEM.

The previous version of the settings overlay paired a CA file with
`MYSQL_ATTR_SSL_VERIFY_SERVER_CERT => FALSE`, which is self-cancelling: it
encrypts but accepts any certificate, so it stops a passive listener and not an
active one, while looking secure in a code review.

`DRUPAL_DB_SSL_MODE` accepts:

| | |
|---|---|
| `verify` | Encrypt and verify the certificate. The default, and correct for Azure |
| `on` | Encrypt without verifying. For a server presenting a private CA |
| `off` | No TLS. For the local docker-compose MySQL only |

---

## Import-time flags

### `NO_AUTO_VALUE_ON_ZERO` — not optional

Drupal's anonymous user is `uid = 0`. Without this flag, MySQL treats an inserted
`0` in an `AUTO_INCREMENT` column as "assign the next value", so the anonymous
user silently becomes `uid 1` — colliding with the site's first real account.

The symptom is that **anonymous visitors appear to be logged in as the
administrator.** It is a data-integrity failure that the import reports as
complete success.

`migrate.sh` prepends the flag and then verifies the result rather than assuming
it worked:

```sql
SELECT COUNT(*) FROM users WHERE uid = 0;   -- must be 1
```

If it is 0:

```sql
SET SESSION sql_mode='NO_AUTO_VALUE_ON_ZERO';
UPDATE users SET uid = 0 WHERE uid NOT IN (SELECT uid FROM users_field_data);
```

### `DEFINER` clauses

A dump from another host carries `DEFINER=`user`@`host`` on views, triggers and
routines. The import fails with "The user specified as a definer does not
exist" — and on Azure it *cannot* exist, because `SUPER` is not granted to the
admin account, so you cannot create the definer either. `migrate.sh` strips them.

### `--no-tablespaces`

Without it, `mysqldump` 8 emits a `TABLESPACE` clause and needs the `PROCESS`
privilege, which a shared-hosting database user does not have. The failure is
"Access denied; you need the PROCESS privilege", which reads like a credentials
problem and is not.

### `max_allowed_packet`

Set to 512 MB on the server. Drupal's cache and config tables hold rows well past
the 4 MB default, and a dump or restore of a real site exceeds it easily. The
failure is "MySQL server has gone away" partway through, which reads like a
network problem.

---

## Engine version, pinned

```bicep
param mysqlVersion string = '8.0.21'
```

Without an explicit version Azure provisions whatever its current default is, so
a disaster-recovery rebuild of "the same" infrastructure can land on an engine
nothing here has been tested against. The accepted values are specific strings —
a bare `8.0` is rejected — and the provisioned server will report a patch version
of its own (`8.0.x-azure`); that is expected.

Moving major version is a rehearsed operation, not a parameter change. Restore a
PITR copy onto the new version, run the site against it, and only then repoint —
keeping the destructive work and the switch that makes it live as separate steps.

---

## Storage auto-grow

```bicep
storage: { autoGrow: 'Enabled', autoIoScaling: 'Enabled' }
```

A full MySQL disk does not degrade a Drupal site, it stops it: writes fail, and
because Drupal writes on nearly every request — sessions, cache, watchdog — the
site is down rather than read-only. 32 GB on a Burstable tier fills faster than
expected once `watchdog` and the cache tables grow. Auto-grow costs nothing until
it triggers.

Worth also capping the log volume, since `watchdog` is usually the table that
grows without anyone noticing: set "Database log messages to keep" on
`/admin/config/development/logging` and let cron trim it.

---

## The deploy state table

`docker-entrypoint.sh` creates one table of its own:

```sql
CREATE TABLE azure_deploy_state (
  id               TINYINT UNSIGNED PRIMARY KEY,
  lock_owner       VARCHAR(190) NOT NULL DEFAULT '',
  locked_at        DATETIME NULL,
  deployed_version VARCHAR(190) NOT NULL DEFAULT '',
  deployed_at      DATETIME NULL
);
```

Deliberately outside Drupal's table prefix and unknown to Drupal's schema system,
so `drush updb`, a config import, or a full database restore never touches it.

`deployed_version` is the image whose deploy sequence last completed. It lives in
the database rather than on disk because a replica's filesystem is not shared: a
file marker would make every replica re-run `updb`, and the marker belongs with
the schema it describes.

`lock_owner` is held for the duration of one replica's deploy sequence. Acquisition
is a single conditional `UPDATE` whose `ROW_COUNT()` is read in the same session,
so of N replicas issuing it concurrently exactly one wins — no race, and no
dependence on a connection staying open the way `GET_LOCK()` would require.

---

## See also

- **[Migrating a site](migrating-a-site.md)** — bringing an existing database in,
  and how to verify it arrived intact.
- **[Configuration](configuration.md)** — every database variable and its default.
- **[Troubleshooting](troubleshooting.md)** — `ERROR 1267`, "server has gone away",
  "access denied", and the rest, by symptom.
