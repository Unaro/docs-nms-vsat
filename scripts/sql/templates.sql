INSERT INTO metric_templates (id, name, vendor, sys_object_id_pattern, jobs_definition)
VALUES
-- 1. Linux Host / Server
(
  'tpl-linux-server',
  'Linux Server (Net-SNMP)',
  'Linux / Unix',
  '1.3.6.1.4.1.8072.3.2.*',
  '[
    {"job_name": "vital_ping", "collector": "icmp", "interval": 3, "is_vital": true, "payload": {"packets": 2, "timeout_ms": 1000}},
    {"job_name": "system_info", "collector": "snmp", "interval": 30, "is_vital": false, "payload": {
      "timeout_ms": 2000,
      "oids": [
        {"key": "sys_descr", "oid": "1.3.6.1.2.1.1.1.0"},
        {"key": "sys_uptime", "oid": "1.3.6.1.2.1.1.3.0"},
        {"key": "sys_name", "oid": "1.3.6.1.2.1.1.5.0"}
      ]
    }},
    {"job_name": "cpu_memory", "collector": "snmp", "interval": 15, "is_vital": false, "payload": {
      "timeout_ms": 2000,
      "oids": [
        {"key": "cpu_idle", "oid": "1.3.6.1.4.1.2021.11.11.0"},
        {"key": "mem_total", "oid": "1.3.6.1.4.1.2021.4.5.0"},
        {"key": "mem_avail", "oid": "1.3.6.1.4.1.2021.4.6.0"}
      ]
    }}
  ]'::jsonb
),
-- 2. Cisco Switch / Router
(
  'tpl-cisco-switch',
  'Cisco Catalyst / IOS Device',
  'Cisco Systems',
  '1.3.6.1.4.1.9.1.*',
  '[
    {"job_name": "vital_ping", "collector": "icmp", "interval": 3, "is_vital": true, "payload": {"packets": 2, "timeout_ms": 1000}},
    {"job_name": "system_info", "collector": "snmp", "interval": 30, "is_vital": false, "payload": {
      "timeout_ms": 2000,
      "oids": [
        {"key": "sys_descr", "oid": "1.3.6.1.2.1.1.1.0"},
        {"key": "sys_uptime", "oid": "1.3.6.1.2.1.1.3.0"},
        {"key": "sys_name", "oid": "1.3.6.1.2.1.1.5.0"}
      ]
    }},
    {"job_name": "cisco_cpu", "collector": "snmp", "interval": 15, "is_vital": false, "payload": {
      "timeout_ms": 2000,
      "oids": [
        {"key": "cisco_cpu_5m", "oid": "1.3.6.1.4.1.9.9.109.1.1.1.1.5.1"}
      ]
    }}
  ]'::jsonb
),
-- 3. MikroTik RouterOS
(
  'tpl-mikrotik-router',
  'MikroTik RouterOS',
  'MikroTik',
  '1.3.6.1.4.1.14988.1.*',
  '[
    {"job_name": "vital_ping", "collector": "icmp", "interval": 3, "is_vital": true, "payload": {"packets": 2, "timeout_ms": 1000}},
    {"job_name": "system_info", "collector": "snmp", "interval": 30, "is_vital": false, "payload": {
      "timeout_ms": 2000,
      "oids": [
        {"key": "sys_descr", "oid": "1.3.6.1.2.1.1.1.0"},
        {"key": "sys_uptime", "oid": "1.3.6.1.2.1.1.3.0"},
        {"key": "sys_name", "oid": "1.3.6.1.2.1.1.5.0"}
      ]
    }},
    {"job_name": "mt_cpu", "collector": "snmp", "interval": 15, "is_vital": false, "payload": {
      "timeout_ms": 2000,
      "oids": [
        {"key": "mt_cpu_load", "oid": "1.3.6.1.2.1.25.3.3.1.2.1"}
      ]
    }}
  ]'::jsonb
),
-- 4. Только ICMP (без опроса SNMP)
(
  'tpl-icmp-only',
  'ICMP Ping Only (No SNMP)',
  'Generic',
  NULL,
  '[
    {"job_name": "vital_ping", "collector": "icmp", "interval": 2, "is_vital": true, "payload": {"packets": 2, "timeout_ms": 1000}}
  ]'::jsonb
)
ON CONFLICT (id) DO UPDATE SET
  name = EXCLUDED.name,
  vendor = EXCLUDED.vendor,
  sys_object_id_pattern = EXCLUDED.sys_object_id_pattern,
  jobs_definition = EXCLUDED.jobs_definition;