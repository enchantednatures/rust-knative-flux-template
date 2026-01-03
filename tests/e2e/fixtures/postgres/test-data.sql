-- E2E Test Data for PostgreSQL Backup Testing
-- This script generates approximately 1GB of test data for backup validation

-- Create test tables
CREATE TABLE IF NOT EXISTS test_data (
    id BIGSERIAL PRIMARY KEY,
    data TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
) WITH (fillfactor=70);

CREATE TABLE IF NOT EXISTS test_metadata (
    id BIGSERIAL PRIMARY KEY,
    test_data_id BIGINT REFERENCES test_data(id),
    metadata JSONB,
    created_at TIMESTAMP DEFAULT NOW()
);

-- Create indexes for realistic workload
CREATE INDEX idx_test_data_created ON test_data(created_at);
CREATE INDEX idx_test_data_updated ON test_data(updated_at);
CREATE INDEX idx_test_metadata_created ON test_metadata(created_at);
CREATE INDEX idx_test_metadata_data_id ON test_metadata(test_data_id);

-- Insert 1M rows of test data (~800 bytes each = ~800MB total)
-- Using a loop to insert data in batches
DO $$
DECLARE
    i INTEGER;
    batch_size INTEGER := 1000;
BEGIN
    FOR i IN 1..1000 LOOP
        INSERT INTO test_data (data) 
        SELECT 
            'Test data row with random content: ' || 
            md5(random()::text) || 
            repeat('x', 700)  -- Pad to ~800 bytes per row
        FROM generate_series(1, batch_size);
        
        -- Insert corresponding metadata
        INSERT INTO test_metadata (test_data_id, metadata)
        SELECT 
            id,
            jsonb_build_object(
                'batch', i,
                'index', ROW_NUMBER() OVER (ORDER BY id),
                'checksum', md5(data),
                'size_bytes', length(data)
            )
        FROM test_data 
        WHERE id > (i-1) * batch_size 
        AND id <= i * batch_size;
        
        -- Log progress
        RAISE NOTICE 'Inserted batch % of 1000', i;
    END LOOP;
END $$;

-- Verify data integrity
SELECT 
    COUNT(*) as total_rows,
    ROUND(CAST(pg_total_relation_size('test_data') AS NUMERIC) / 1024 / 1024 / 1024, 2) as table_size_gb,
    ROUND(CAST(pg_total_relation_size('test_metadata') AS NUMERIC) / 1024 / 1024 / 1024, 2) as metadata_size_gb
FROM test_data;

-- Create a backup marker table to verify backup captures this data
CREATE TABLE IF NOT EXISTS backup_marker (
    id SERIAL PRIMARY KEY,
    backup_id VARCHAR(100),
    backup_time TIMESTAMP DEFAULT NOW(),
    data_checksum VARCHAR(32)
);

-- Store checksum of current data for restore verification
INSERT INTO backup_marker (backup_id, data_checksum)
SELECT 
    'test-backup-' || NOW()::DATE,
    md5(STRING_AGG(md5(data)::text, ''))
FROM test_data;
