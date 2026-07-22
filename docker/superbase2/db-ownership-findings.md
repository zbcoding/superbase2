# sb2 project-database ownership & credential findings

Investigated 2026-07-22 against the live server (`2.56.246.101`). All ownership and
privilege data below was read from the running cluster, not inferred.

## Summary

Projects created through the Studio UI get a database owned by `supabase_admin`,
while projects created through `superbase2.sh` get one owned by `postgres`. The
two provisioning paths have been producing structurally different databases.

Because the connection string sb2 hands out authenticates as `postgres`, on
UI-created projects the connecting role owns nothing — it cannot `CREATE` in
`public`, and cannot `ALTER`/`DROP`/`CREATE INDEX` on any table the Studio table
editor or SQL editor created.

Separately, every project reuses the single cluster-wide `POSTGRES_PASSWORD`.

## The two provisioning paths

| | `superbase2.sh` | Studio UI |
|---|---|---|
| entry point | `_init_project_db`, `superbase2.sh:462` | `createProjectDatabase`, `apps/studio/lib/superbase2/db.ts:92` |
| connects as | `postgres` | `supabase_admin` (`db.ts:44`, `db.ts:104`) |
| resulting DB owner | `postgres` | `supabase_admin` |

`CREATE DATABASE` assigns ownership to the creating role. `public` is owned by
`pg_database_owner`, which resolves to the database owner — so on UI-created
projects `pg_database_owner` is `supabase_admin` and `postgres` has no `CREATE`.

## Verified server state

Database ownership:

```
_supabase         | supabase_admin
postgres          | postgres           <- healthy
project_nraidata  | supabase_admin
project_test2     | supabase_admin
project_vrsite    | supabase_admin
```

All three project databases were created through the UI. `CREATE` on `public`
for role `postgres`:

| database | `public` owner | `postgres` has CREATE |
|---|---|---|
| `postgres` | `pg_database_owner` | yes |
| `project_nraidata` | `pg_database_owner` | yes — **only** because of a manual `GRANT` |
| `project_test2` | `pg_database_owner` | **no** |
| `project_vrsite` | **`supabase_admin`** | **no** |

`project_test2` and `project_vrsite` are untouched and both fail, so the defect
reproduces independently of the project that surfaced it.

`project_vrsite` is a worse case: its `public` schema is owned by `supabase_admin`
directly rather than by `pg_database_owner`. Fixing the *database* owner alone
would not restore `CREATE` there; the schema owner has to be corrected too.

Table ownership in `public`:

| database | tables | owner |
|---|---|---|
| `project_nraidata` | `meta_model_snapshots` | `postgres` (manually reassigned) |
| `project_test2` | `test` | `supabase_admin` |
| `project_vrsite` | 13 tables (`vrchat_worlds`, `user_profiles`, `analytics_events`, …) | `supabase_admin` |

Fourteen tables are owned by a role no client authenticates as.

## What actually breaks

Only for connections made **as `postgres`**, i.e. over the `DATABASE_URL` that
`apps/studio/lib/superbase2/response-helpers.ts:167` builds and the keys panel
displays:

- `CREATE TABLE` / `CREATE SCHEMA` in `public` — denied, no CREATE privilege.
- `CREATE INDEX` / `ALTER TABLE` / `DROP TABLE` on any Studio-created table —
  denied, these require ownership and cannot be granted.

Everything through PostgREST (`anon`, `authenticated`, `service_role`) works
normally, which is why this went unnoticed. It only became reachable when
commit `12cc81d` added the `DATABASE_URL` row to the keys and creation panels —
that commit advertises a connection string that is broken by construction on
every UI-created project.

### Corrections to earlier analysis

Two claims made during investigation were wrong and are retracted:

1. **`postgres` does have table privileges.** It holds `SELECT`/`INSERT` on all
   14 `supabase_admin`-owned tables. `postgres` is a member of `anon`,
   `authenticated`, and `service_role`, and `db.ts:151-153` grants those roles
   `ALL` on new tables, so `postgres` inherits. The earlier claim that
   `postgres` "is not a grantee, therefore has no privileges" was incorrect —
   privileges are inherited via role membership.

   Consequently the `GRANT SELECT/INSERT/UPDATE/DELETE` applied by hand to
   `meta_model_snapshots` was likely unnecessary. The two changes that mattered
   were the `CREATE` grant on `public` and the ownership reassignment.

2. **The initial wrong connection string is not the root cause.** The app first
   connected to the `postgres` database rather than `project_nraidata`, so the
   table was created in the wrong database. That is an application-side
   misconfiguration, independent of the ownership defect — which reproduces on
   `project_test2` and `project_vrsite` with no application involved. No stray
   objects remain: `public` in the `postgres` database has zero tables.

## Missing initialization SQL

The upstream init scripts (`docker/volumes/db/*.sql`, mounted at
`docker-compose.standalone.yml:488-495`) run once at cluster initialization
against the `postgres` database only. Project databases are created later from
`template1` and inherit none of it.

Confirmed by default-ACL comparison — the `postgres` database carries default
ACLs for `supabase_functions`, `graphql`, `graphql_public`, `realtime`, and
`extensions`; project databases carry them for `public` only.

Concretely absent from every project database:

- All of `webhooks.sql` — `pg_net`, the `supabase_functions` schema, and
  `http_request()`. Database webhooks are non-functional.
- `pg_graphql` and the `graphql_public` resolver. `superbase2.sh:507` creates the
  `graphql_public` schema empty while `PGRST_DB_SCHEMAS` (`:415`) exposes it, so
  `/graphql/v1` cannot work.

Not applicable per-project, correctly absent: `_supabase.sql`, `logs.sql`,
`pooler.sql`.

Ruled out: roles are cluster-global and do exist; `roles.sql` only sets
passwords. GoTrue, Storage, and Realtime run their own migrations at startup, so
missing objects in `auth`/`storage` indicate a failed service migration rather
than an initialization gap.

## Shared-password problem

Every project authenticates with the one cluster-wide `POSTGRES_PASSWORD`. It is
the same secret for the surfaced `DATABASE_URL`, for every service role, and for
every project. Disclosing one project's connection string discloses the
credential for all of them, and the keys panel's Rotate button does not rotate
it.

**Constraint:** Postgres roles are cluster-global. `supabase_auth_admin`,
`authenticator`, `supabase_storage_admin`, `anon`, `authenticated`, and
`service_role` are shared across all project databases, so they cannot hold
per-project passwords without cloning the entire role set per project and
rewriting every service connection string, grant, and the rotation flow. Those
credentials are server-side only and are never handed to a user.

The credential that is both reused *and* handed out is the one in `DATABASE_URL`.
That is the one worth separating.

## Additional defects found while implementing the fix

Four more, none visible from the ownership analysis alone. All verified against
the live cluster.

1. **`docker exec` without `-i` discards stdin**, so every heredoc-fed `psql`
   block in `superbase2.sh` was a silent no-op — including the whole of
   `_init_project_db`'s schema/grant SQL. It exits 0, which is why it was never
   noticed. CLI-created projects therefore never got their `auth`, `storage`,
   `extensions` or `graphql_public` schemas, nor any service grants. This went
   unseen only because all three live projects came from the UI path.

2. **`ALTER SEQUENCE ... OWNER TO` fails on `SERIAL`/identity sequences**
   (`is linked to table`). A naive reassignment loop aborts on the first one and
   skips everything after it. Owned sequences must be excluded — they follow
   their table's owner automatically. Views must also be reassigned after
   tables, since a view cannot be owned by a role lacking privileges on what it
   reads.

3. **`pg_hba.conf` has `host all all 127.0.0.1/32 trust`.** Any password test run
   over loopback inside the db container passes regardless of the password.
   Credential checks must use the container's network address (`10.x`), which
   matches the `scram-sha-256` rule.

4. **A schema on `search_path` is not usable without `USAGE`.** The project role
   is not a member of `anon`/`authenticated`/`service_role`, so it needs its own
   `GRANT USAGE ON SCHEMA extensions` — without it `uuid_generate_v4()` and
   `gen_salt()` are unresolvable over `DATABASE_URL` even though `extensions` is
   on the path.

## Fix (implemented)

### 1. Per-project owner role

Each project gets a login role named after its database, which owns it:

```sql
CREATE ROLE "project_x" LOGIN INHERIT BYPASSRLS PASSWORD '<24 random bytes, hex>';
ALTER ROLE "project_x" SET search_path TO "$user", public, extensions;
CREATE DATABASE "project_x" OWNER "project_x";
```

The role holds **no cluster-level memberships or capabilities** — the one place
this departs from upstream's `postgres` role, deliberately:

| Upstream `postgres` has | project role | why |
|---|---|---|
| `anon`, `authenticated`, `service_role` | no | those roles hold `CONNECT` on *every* project database, so membership would let one project's credential open all the others |
| `pg_read_all_data` | no | would also grant read of the main `postgres` database |
| `CREATEROLE`, `CREATEDB`, `REPLICATION` | no | roles and databases are cluster-global |
| `BYPASSRLS` | yes | per-connection, and the SQL editor is expected to see through RLS |

What it would otherwise have inherited is replaced by database-scoped grants:

```sql
GRANT USAGE ON SCHEMA extensions, graphql_public TO "project_x";
GRANT USAGE ON SCHEMA auth, storage TO "project_x";
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_auth_admin    IN SCHEMA auth    GRANT SELECT ON TABLES TO "project_x";
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_storage_admin IN SCHEMA storage GRANT SELECT ON TABLES TO "project_x";

-- PostgREST must see tables the project role creates; the pre-existing
-- ALTER DEFAULT PRIVILEGES only covered objects created by supabase_admin.
ALTER DEFAULT PRIVILEGES FOR ROLE "project_x" IN SCHEMA public
  GRANT ALL ON TABLES TO anon, authenticated, service_role;   -- + SEQUENCES, FUNCTIONS

-- Confine the credential to its own database.
REVOKE CONNECT ON DATABASE "project_x" FROM PUBLIC;
```

Applied identically in both provisioning paths, which no longer diverge:
`superbase2.sh:_init_project_db` and `db.ts:createProjectDatabase`.

### 2. The pg-meta ceiling, closed

The earlier plan accepted that pg-meta keeps connecting as `supabase_admin`, so
table-editor tables stay `supabase_admin`-owned and `CREATE INDEX` on them over
`DATABASE_URL` still fails. That ceiling is now removed: **pg-meta connects as
the project role** (`templates/docker-compose.project.yml.tpl`), which is what
upstream `docker/docker-compose.yml:434` already does with `postgres`. sb2's
templates had diverged to `supabase_admin` with no reason recorded.

The edge-functions runtime's `SUPABASE_DB_URL` moved to the project role for the
same reason — it was previously handed the broken `postgres` credential.

### 3. Per-project password, and rolling it

`db_password` is stored in the manifest and as `PROJECT_DB_PASSWORD` in the
project `.env`. `toDbUrlTemplate` emits the real credential
(`postgresql://project_x:<pw>@db:5432/project_x`); projects without a
`db_password` still get the old placeholder, so the change is backward
compatible.

`superbase2.sh rotate-keys` now rolls the database password **together with**
the JWT secret and API keys, so the existing Rotate button in the keys panel
does both in one action — no migration, no data movement. The database URL row
in the UI is now masked, since it carries a real secret.

### 4. Backfill for existing projects

`superbase2.sh migrate-db-owner <name>` — creates the role, transfers the
database, the `public` schema and every `public` object to it, applies the
grants above, and writes the credential into `.env` + manifest. Data is
untouched. Restart the project afterwards so pg-meta picks up the new role.

Reassignment is restricted to `public`; `REASSIGN OWNED BY supabase_admin` is
database-wide and would move `auth`, `storage` and `realtime` objects too,
breaking GoTrue, Storage and Realtime.

## Verification

Verified end-to-end against the live cluster by running the real `cmd_create`
and `rotate-keys` against a throwaway project in an isolated `SB2_STATE_DIR`
(live manifest and Kong config untouched), then connecting over the emitted
`DATABASE_URL` from the Docker network:

| check | result |
|---|---|
| database owner / `public` owner | `project_probetest` / `pg_database_owner` |
| `has_schema_privilege(role,'public','CREATE')` | `t` |
| role memberships / `CREATEROLE` / `CREATEDB` | none / `f` / `f` |
| `CREATE TABLE`, `CREATE INDEX`, `ALTER TABLE`, `CREATE SCHEMA` over `DATABASE_URL` | all succeed |
| `uuid_generate_v4()`, `gen_salt()` over `DATABASE_URL` | resolve |
| `anon`/`authenticated`/`service_role` `SELECT` on a project-role-created table | all three |
| connect to another *migrated* project's database | `permission denied ... does not have CONNECT privilege` |
| read main `postgres` database | connects, `permission denied for schema auth` |
| `rotate-keys`: old password / new password / data | rejected / accepted / intact |

## Known ceilings

- The project role can still *connect* to the main `postgres` database (PUBLIC
  holds `CONNECT` there), though it can read nothing in it. Revoking that would
  mean auditing every main-stack service and was judged not worth the risk.
- Cross-project isolation only holds between migrated databases; an un-migrated
  project still has `CONNECT` for PUBLIC.
- `_init_project_db` still runs without `ON_ERROR_STOP`, so a failed
  `CREATE EXTENSION` on an image lacking `pgjwt` stays non-fatal — matching the
  per-extension error handling on the Studio path.

## Related

`numerai-crypto-tracker` was the project that surfaced this. Two independent
bugs stacked: its `entrypoint.sh` checked only `DATABASE_URL` while the Coolify
deployment sets `SUPABASE_URL`, so the schema-ensure step silently no-op'd
(fixed there in `94b665b`). That masked the sb2 defect — with `schema.sql` never
running, no permission errors were visible. Fixing the entrypoint is what
exposed the ownership failures.
