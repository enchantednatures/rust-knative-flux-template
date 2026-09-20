-- Initial schema for the demo items table used by this template's
-- CRUD endpoints. sqlx::migrate!() embeds this directory at build time;
-- migrations run at app startup (see src/postgres.rs / APP__POSTGRES__RUN_MIGRATIONS).
CREATE TABLE IF NOT EXISTS demo_items (
    id          BIGSERIAL PRIMARY KEY,
    key         TEXT NOT NULL UNIQUE,
    value       TEXT NOT NULL,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS demo_items_key_idx ON demo_items (key);
