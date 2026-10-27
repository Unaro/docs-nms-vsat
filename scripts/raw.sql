CREATE TABLE IF NOT EXISTS adhoc_tasks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    task_type VARCHAR(32) NOT NULL, -- 'probe', 'inspect', 'discovery'
    status VARCHAR(16) NOT NULL DEFAULT 'pending', -- 'pending', 'running', 'completed', 'failed'
    target_host VARCHAR(255),
    payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    result JSONB,
    error_message TEXT,
    locked_by VARCHAR(64),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Частичный индекс для мгновенного захвата задач воркерами
CREATE INDEX IF NOT EXISTS idx_adhoc_tasks_pending 
ON adhoc_tasks (created_at ASC) 
WHERE status = 'pending';

-- Индекс для выборок по ID
CREATE INDEX IF NOT EXISTS idx_adhoc_tasks_status 
ON adhoc_tasks (id, status);