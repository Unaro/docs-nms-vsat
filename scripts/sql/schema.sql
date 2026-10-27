BEGIN;

-- ============================================================================
-- 0. РАСШИРЕНИЯ И ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE OR REPLACE FUNCTION trigger_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- ============================================================================
-- 1. СПРАВОЧНИКИ: ПРОФИЛИ ДОСТУПА И ШАБЛОНЫ МЕТРИК
-- ============================================================================

CREATE TABLE IF NOT EXISTS credential_profiles (
    id VARCHAR(64) PRIMARY KEY,
    name VARCHAR(128) NOT NULL,
    protocol VARCHAR(32) NOT NULL,
    params JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT chk_cred_protocol CHECK (protocol IN ('snmp_v2c', 'snmp_v3', 'http', 'custom'))
);

CREATE TRIGGER trg_cred_profiles_updated_at
    BEFORE UPDATE ON credential_profiles
    FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

CREATE TABLE IF NOT EXISTS metric_templates (
    id VARCHAR(64) PRIMARY KEY,
    name VARCHAR(128) NOT NULL,
    vendor VARCHAR(64),
    sys_object_id_pattern VARCHAR(128),
    jobs_definition JSONB NOT NULL DEFAULT '[]'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_metric_templates_updated_at
    BEFORE UPDATE ON metric_templates
    FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();


-- ============================================================================
-- 2. ОПРАШИВАЕМЫЕ УЗЛЫ (TARGET NODES)
-- ============================================================================

CREATE TABLE IF NOT EXISTS monitored_nodes (
    id VARCHAR(64) PRIMARY KEY,
    name VARCHAR(128) NOT NULL,
    ip_address INET NOT NULL,
    credential_id VARCHAR(64) REFERENCES credential_profiles(id) ON DELETE SET NULL,
    template_id VARCHAR(64) REFERENCES metric_templates(id) ON DELETE SET NULL,
    status VARCHAR(16) NOT NULL DEFAULT 'offline',
    is_enabled BOOLEAN NOT NULL DEFAULT true,
    capabilities JSONB NOT NULL DEFAULT '{"snmp_bulk": true, "max_varbinds": 20}'::jsonb,
    overrides JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT chk_node_status CHECK (status IN ('online', 'suspect', 'offline'))
);

CREATE INDEX IF NOT EXISTS idx_monitored_nodes_status ON monitored_nodes (status) WHERE is_enabled = true;
CREATE INDEX IF NOT EXISTS idx_monitored_nodes_ip ON monitored_nodes (ip_address);

CREATE TRIGGER trg_monitored_nodes_updated_at
    BEFORE UPDATE ON monitored_nodes
    FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();


-- ============================================================================
-- 3. ОЧЕРЕДЬ ЗАДАЧ ОПРОСА (POLL JOBS QUEUE)
-- ============================================================================

CREATE TABLE IF NOT EXISTS poll_jobs (
    id BIGSERIAL PRIMARY KEY,
    node_id VARCHAR(64) NOT NULL REFERENCES monitored_nodes(id) ON DELETE CASCADE,
    job_name VARCHAR(64) NOT NULL,
    collector VARCHAR(32) NOT NULL,
    is_vital BOOLEAN NOT NULL DEFAULT false,
    host VARCHAR(255) NOT NULL,
    port INT NOT NULL DEFAULT 161,
    credential_id VARCHAR(64) REFERENCES credential_profiles(id) ON DELETE SET NULL,
    job_payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    poll_interval_sec INT NOT NULL DEFAULT 60,
    next_poll_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    locked_by VARCHAR(64) DEFAULT NULL,
    locked_until TIMESTAMPTZ DEFAULT NULL,
    CONSTRAINT chk_collector_type CHECK (collector IN ('icmp', 'snmp', 'snmp_bulk', 'http'))
);

CREATE INDEX IF NOT EXISTS idx_poll_jobs_node_id ON poll_jobs (node_id);

-- Составной B-Tree индекс для выборки воркерами (исправлено)
CREATE INDEX IF NOT EXISTS idx_poll_jobs_queue 
ON poll_jobs (is_vital DESC, next_poll_at ASC, locked_until);


-- ============================================================================
-- 4. ОПЕРАТИВНЫЙ СРЕЗ (HOT PATH: 1 СТРОКА НА УЗЕЛ)
-- ============================================================================

CREATE TABLE IF NOT EXISTS node_current_state (
    node_id VARCHAR(64) PRIMARY KEY REFERENCES monitored_nodes(id) ON DELETE CASCADE,
    status VARCHAR(16) NOT NULL DEFAULT 'unknown',
    latency_ms INT,
    metrics JSONB NOT NULL DEFAULT '{}'::jsonb,
    error_message TEXT,
    last_polled_by VARCHAR(64) NOT NULL DEFAULT 'system',
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT chk_state_status CHECK (status IN ('healthy', 'degraded', 'down', 'unknown'))
);

CREATE OR REPLACE FUNCTION notify_node_state_change()
RETURNS TRIGGER AS $$
DECLARE
    payload JSONB;
BEGIN
    payload = jsonb_build_object(
        'node_id', NEW.node_id,
        'status', NEW.status,
        'latency_ms', NEW.latency_ms,
        'last_polled_by', NEW.last_polled_by,
        'updated_at', NEW.updated_at
    );
    PERFORM pg_notify('node_telemetry_update', payload::text);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_node_current_state_notify
    AFTER INSERT OR UPDATE ON node_current_state
    FOR EACH ROW EXECUTE FUNCTION notify_node_state_change();


-- ============================================================================
-- 5. ИСТОРИЯ МЕТРИК (COLD PATH: ПАРТИЦИОНИРОВАНИЕ)
-- ============================================================================

CREATE TABLE IF NOT EXISTS node_metrics_history (
    id BIGINT GENERATED ALWAYS AS IDENTITY,
    node_id VARCHAR(64) NOT NULL,
    metric_name VARCHAR(64) NOT NULL,
    metric_value DOUBLE PRECISION NOT NULL,
    unit VARCHAR(16),
    collected_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (id, collected_at)
) PARTITION BY RANGE (collected_at);

CREATE INDEX IF NOT EXISTS idx_metrics_hist_lookup 
ON node_metrics_history (node_id, metric_name, collected_at DESC);

-- Дефолтная партиция (принимает любые даты без явных партиций)
CREATE TABLE IF NOT EXISTS node_metrics_history_default 
    PARTITION OF node_metrics_history DEFAULT;


-- ============================================================================
-- 6. ПЕСОЧНИЦА ОБНАРУЖЕНИЯ (DISCOVERY SANDBOX)
-- ============================================================================

CREATE TABLE IF NOT EXISTS discovered_nodes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    ip_address INET NOT NULL UNIQUE,
    mac_address MACADDR,
    hostname VARCHAR(255),
    vendor VARCHAR(128),
    model VARCHAR(128),
    snmp_sys_object_id VARCHAR(128),
    suggested_template_id VARCHAR(64) REFERENCES metric_templates(id) ON DELETE SET NULL,
    matched_credential_id VARCHAR(64) REFERENCES credential_profiles(id) ON DELETE SET NULL,
    status VARCHAR(16) NOT NULL DEFAULT 'new',
    discovered_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT chk_discovery_status CHECK (status IN ('new', 'ignored', 'approved'))
);

CREATE INDEX IF NOT EXISTS idx_discovered_nodes_status ON discovered_nodes (status);

COMMIT;