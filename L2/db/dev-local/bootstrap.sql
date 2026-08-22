-- L2/db/dev-local/bootstrap.sql — the external Postgres, for dev-local.
--
-- ─── why this file exists ──────────────────────────────────────────────────
-- Every database this platform uses is EXTERNAL: the cluster runs no Postgres,
-- holds no database PVC, and mints no database credential. That is a deliberate
-- architecture choice (see the note in L1/platform/appset.yaml) and it has one
-- cost — the databases and roles are the only part of dev-local that a cold
-- rebuild does NOT reproduce. `just up` recreates the cluster, the platform and
-- every service; it cannot recreate a database it does not own.
--
-- Before this file, that gap was five CREATE DATABASE lines and four CREATE
-- ROLE lines scattered across the comment headers of four values files, run by
-- hand, on a server whose passwords had to match a fifth file. A missed one
-- does not fail loudly: it surfaces as a schema job retrying behind a green
-- Application.
--
-- ─── the passwords ─────────────────────────────────────────────────────────
-- These match L1/secrets/dev-local/cluster-secret-store.yaml exactly, because
-- the `fake` provider there serves them to every ExternalSecret in L2. Change
-- one and you must change both — they are two halves of the same fact.
--
-- THEY ARE NOT SECRETS. They are obviously-fake development placeholders for a
-- Postgres container on a laptop. A cloud environment has no equivalent of this
-- file: the databases are provisioned by the same OpenTofu that provisions the
-- cluster, and their credentials live in AWS/GCP Secrets Manager, outside all
-- three layers. This is the local stand-in for that, and only that.
--
-- ─── idempotency ───────────────────────────────────────────────────────────
-- Safe to re-run. Postgres has no CREATE ROLE IF NOT EXISTS, so roles go
-- through a DO block; CREATE DATABASE cannot run inside one (it is
-- non-transactional), so databases go through \gexec instead. Re-running never
-- resets a password on an existing role — dropping and recreating a role that
-- owns objects is a worse outcome than a stale password you can see.

\set ON_ERROR_STOP on

-- ─── roles ─────────────────────────────────────────────────────────────────
-- One owner per service, not one shared superuser. It costs nothing here and it
-- is the shape the cloud environments have to have anyway, so dev-local does
-- not teach the wrong habit.
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT * FROM (VALUES
            -- role        password
            ('keycloak',  'dev-placeholder-db-password'),  -- Keycloak's own store
            ('temporal',  'dev-placeholder-db-password'),  -- Temporal: both datastores
            ('maaladmin', 'dev-placeholder-db-password'),  -- client
            ('phadmin',   'dev-placeholder-db-password')   -- paymenthub
        ) AS t(name, password)
    LOOP
        IF EXISTS (SELECT FROM pg_roles WHERE rolname = r.name) THEN
            RAISE NOTICE 'role % already exists — leaving it alone', r.name;
        ELSE
            EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L', r.name, r.password);
            RAISE NOTICE 'created role %', r.name;
        END IF;
    END LOOP;
END
$$;

-- ─── databases ─────────────────────────────────────────────────────────────
-- Owned by the role that uses them, which is what lets Temporal's schema jobs
-- run with `createDatabase: false` and `manageSchema: true` — they need owner
-- rights inside an existing database, and nothing more. A superuser here would
-- work and would also mean every service could drop every other service's data.
SELECT format('CREATE DATABASE %I OWNER %I', d.name, d.owner)
FROM (VALUES
    -- database              owner        consumer
    ('keycloak',            'keycloak'),  -- L2/deps/keycloak/dev-local.yaml      KC_DB_URL_DATABASE
    ('temporal',            'temporal'),  -- L2/deps/temporal/dev-local.yaml      datastores.default
    ('temporal_visibility', 'temporal'),  -- L2/deps/temporal/dev-local.yaml      datastores.visibility
    ('maalbizdb',           'maaladmin'), -- L1/secrets/.../cluster-secret-store  client/db/dsn
    ('phdb',                'phadmin')    -- L1/secrets/.../cluster-secret-store  paymenthub/db/dsn
) AS d(name, owner)
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = d.name)
\gexec

-- ─── what was actually done ────────────────────────────────────────────────
-- Printed rather than assumed: the WHERE NOT EXISTS above is silent about the
-- databases it skipped, and "nothing happened" and "everything was already
-- there" look identical without this.
SELECT d.name AS database,
       d.owner AS owner,
       CASE WHEN EXISTS (SELECT FROM pg_database WHERE datname = d.name)
            THEN 'present' ELSE 'MISSING' END AS status
FROM (VALUES
    ('keycloak', 'keycloak'),
    ('temporal', 'temporal'),
    ('temporal_visibility', 'temporal'),
    ('maalbizdb', 'maaladmin'),
    ('phdb', 'phadmin')
) AS d(name, owner);
