-- One-shot bootstrap for the roko-indexer-sidecar's Postgres state.
--
-- Run this against the blockscout database (as POSTGRES_USER=blockscout's
-- superuser) before the sidecar container starts for the first time.
--
-- It creates the `roko` schema, a dedicated `roko_indexer` role that owns
-- only that schema, and grants the blockscout role read-only access so the
-- SubstrateController can SELECT from `roko.*` rows.
--
-- Re-running this script is safe — every statement is guarded with
-- `IF NOT EXISTS` or equivalent.
--
-- See: roko_network/sidecar/migrations/  (the sidecar runs its own
-- sqlx migrations on top of this once the schema and role exist).

-- 1. Schema
CREATE SCHEMA IF NOT EXISTS roko;

-- 2. Role for the sidecar. Replace the password before running, or use
--    `ALTER ROLE roko_indexer WITH PASSWORD '...'` after creation.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'roko_indexer') THEN
        EXECUTE 'CREATE ROLE roko_indexer LOGIN PASSWORD ''CHANGEME''';
    END IF;
END $$;

-- 3. Ownership of the `roko` schema → roko_indexer
ALTER SCHEMA roko OWNER TO roko_indexer;

-- 3b. The sidecar's own sqlx migrations run AS roko_indexer and need to:
--       - CREATE SCHEMA roko (idempotent; needs CREATE on the database), and
--       - create tables + _sqlx_migrations INSIDE roko (needs roko on the search_path).
--     Without these the migrations fail with "permission denied for schema public"
--     (Postgres 15+ makes public non-writable to non-owners) then "permission denied
--     for database blockscout". roko_indexer still cannot touch Blockscout's own
--     tables in `public` (step 5 revokes write there); CREATE on the database only
--     lets it make NEW schemas, which for this dedicated role is acceptable.
GRANT CREATE ON DATABASE blockscout TO roko_indexer;
ALTER ROLE roko_indexer SET search_path = roko, public;

-- 4. Read-only access for the existing blockscout role on the roko schema.
GRANT USAGE ON SCHEMA roko TO blockscout;
GRANT SELECT ON ALL TABLES IN SCHEMA roko TO blockscout;
ALTER DEFAULT PRIVILEGES IN SCHEMA roko
    GRANT SELECT ON TABLES TO blockscout;

-- 5. Symmetric: the sidecar must NOT touch the public schema (where
--    Blockscout's own tables live).
REVOKE ALL ON SCHEMA public FROM roko_indexer;
GRANT USAGE ON SCHEMA public TO roko_indexer;
