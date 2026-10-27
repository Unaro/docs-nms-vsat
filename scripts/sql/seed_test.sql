BEGIN;

-- 1. Тестовый профиль (например, SNMPv2c public)
INSERT INTO credential_profiles (id, name, protocol, params)
VALUES (
    'cred-default-v2c', 
    'Default Public Community', 
    'snmp_v2c', 
    '{"community": "public"}'::jsonb
) ON CONFLICT (id) DO NOTHING;

-- 2. Базовый шаблон (Ping + System Uptime)
INSERT INTO metric_templates (id, name, vendor, jobs_definition)
VALUES (
    'tpl-generic-node',
    'Generic Network Node',
    'Generic',
    '[
        {"job_name": "vital_ping", "collector": "icmp", "interval": 3, "is_vital": true},
        {"job_name": "system_info", "collector": "snmp", "interval": 15, "is_vital": false}
    ]'::jsonb
) ON CONFLICT (id) DO NOTHING;

-- 3. Тестовый узел (целевой хост кластера или шлюз)
INSERT INTO monitored_nodes (id, name, ip_address, credential_id, template_id, status, is_enabled)
VALUES (
    'node-cluster-master',
    'Cluster Gateway / Target Host',
    '192.168.122.100',
    'cred-default-v2c',
    'tpl-generic-node',
    'online',
    true
) ON CONFLICT (id) DO NOTHING;

-- 4. Инициализация очереди задач (poll_jobs)
-- Задача 1: Vital Ping (интервал 3 сек)
INSERT INTO poll_jobs (
    node_id, job_name, collector, is_vital, host, port, 
    job_payload, poll_interval_sec, next_poll_at
)
VALUES (
    'node-cluster-master',
    'vital_ping',
    'icmp',
    true,
    '192.168.122.100',
    0,
    '{"packets": 2, "timeout_ms": 500}'::jsonb,
    3,
    now()
);

-- Задача 2: Скалярные метрики (интервал 15 сек)
INSERT INTO poll_jobs (
    node_id, job_name, collector, is_vital, host, port, 
    credential_id, job_payload, poll_interval_sec, next_poll_at
)
VALUES (
    'node-cluster-master',
    'system_health',
    'snmp',
    false,
    '192.168.122.100',
    161,
    'cred-default-v2c',
    '{"oids": [{"key": "sys_uptime", "oid": "1.3.6.1.2.1.1.3.0"}]}'::jsonb,
    15,
    now()
);

COMMIT;