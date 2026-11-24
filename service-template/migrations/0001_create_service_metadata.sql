-- Demo table owned by this service. Replace it with the first real migration.
CREATE TABLE IF NOT EXISTS service_metadata (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
