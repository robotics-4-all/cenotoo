CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE TABLE IF NOT EXISTS organization (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_name TEXT UNIQUE NOT NULL,
    description TEXT,
    tags TEXT[],
    creation_date TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS project (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES organization(id) ON DELETE CASCADE,
    project_name TEXT NOT NULL,
    description TEXT,
    tags TEXT[],
    creation_date TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (project_name, organization_id)
);

CREATE TABLE IF NOT EXISTS collection (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES organization(id) ON DELETE CASCADE,
    project_id UUID NOT NULL REFERENCES project(id) ON DELETE CASCADE,
    collection_name TEXT NOT NULL,
    description TEXT,
    tags TEXT[],
    creation_date TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (collection_name, project_id)
);

CREATE TABLE IF NOT EXISTS api_keys (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id UUID NOT NULL REFERENCES project(id) ON DELETE CASCADE,
    api_key TEXT NOT NULL,
    key_type TEXT NOT NULL CHECK (key_type IN ('read', 'write', 'master')),
    created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_api_keys_hash ON api_keys(api_key);
CREATE INDEX IF NOT EXISTS idx_api_keys_project ON api_keys(project_id);

CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES organization(id) ON DELETE CASCADE,
    username TEXT UNIQUE NOT NULL,
    password TEXT NOT NULL,
    role TEXT DEFAULT 'member',
    creation_date TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS revoked_tokens (
    jti TEXT PRIMARY KEY,
    revoked_at TIMESTAMPTZ DEFAULT NOW(),
    expires_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS flink_jobs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    collection_id UUID,
    project_id UUID,
    session_handle TEXT,
    operation_handle TEXT,
    job_type TEXT,
    config TEXT,
    sink_topic TEXT,
    status TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS device (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id UUID NOT NULL REFERENCES project(id) ON DELETE CASCADE,
    organization_id UUID NOT NULL REFERENCES organization(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    description TEXT,
    tags TEXT[],
    status TEXT DEFAULT 'active',
    last_seen TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS device_shadow (
    device_id UUID PRIMARY KEY REFERENCES device(id) ON DELETE CASCADE,
    reported_state TEXT,
    desired_state TEXT,
    reported_at TIMESTAMPTZ,
    desired_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS rules (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id UUID NOT NULL REFERENCES project(id) ON DELETE CASCADE,
    collection_id UUID NOT NULL REFERENCES collection(id) ON DELETE CASCADE,
    name TEXT,
    description TEXT,
    field TEXT NOT NULL,
    operator TEXT NOT NULL,
    threshold DOUBLE PRECISION,
    webhook_url TEXT NOT NULL,
    cooldown_seconds INT DEFAULT 0,
    last_fired_at TIMESTAMPTZ,
    enabled BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW()
);
