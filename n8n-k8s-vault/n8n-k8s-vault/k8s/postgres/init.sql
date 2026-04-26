-- =============================================================================
-- n8n Article Topic Queue Schema
-- Applied once at first startup via a Kubernetes Job (see postgres-init-job.yaml)
-- =============================================================================

-- ── Topic queue table ──────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS article_topics (
    id            SERIAL PRIMARY KEY,
    topic         TEXT        NOT NULL,
    notes         TEXT,                        -- optional extra context
    status        VARCHAR(20) NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending', 'processing', 'done', 'error')),
    priority      SMALLINT    NOT NULL DEFAULT 5, -- 1 (high) – 10 (low)
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    scheduled_at  TIMESTAMPTZ,                 -- optional: target publish date
    processed_at  TIMESTAMPTZ,
    error_msg     TEXT,
    article_title TEXT,                        -- filled in after generation
    article_url   TEXT,                        -- filled in if published to Medium
    email_sent    BOOLEAN     NOT NULL DEFAULT FALSE,
    retry_count   SMALLINT    NOT NULL DEFAULT 0
);

-- Index for the scheduled workflow to efficiently fetch the next pending topic
CREATE INDEX IF NOT EXISTS idx_topics_status_priority
    ON article_topics (status, priority, created_at);

-- ── Workflow run log (optional audit trail) ────────────────────────────────
CREATE TABLE IF NOT EXISTS workflow_runs (
    id            SERIAL PRIMARY KEY,
    topic_id      INTEGER     REFERENCES article_topics(id),
    run_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    status        VARCHAR(20) NOT NULL DEFAULT 'started'
                  CHECK (status IN ('started', 'success', 'error')),
    duration_ms   INTEGER,
    error_msg     TEXT,
    n8n_exec_id   TEXT        -- n8n execution ID for traceability
);

-- ── Seed a few example topics (remove or modify as needed) ────────────────
INSERT INTO article_topics (topic, notes, priority) VALUES
    ('How to deploy n8n on Kubernetes with Vault integration',
     'Cover architecture, secrets management, and queue mode',
     1),
    ('ROSA HCP vs Classic: a practical comparison',
     'Focus on upgrade paths, networking, and SRE experience',
     2),
    ('Terraform best practices on AKS',
     'Remote state, workspaces, and OIDC auth',
     3)
ON CONFLICT DO NOTHING;

-- Print confirmation
DO $$ BEGIN
  RAISE NOTICE 'n8n topic queue schema initialized successfully.';
END $$;
