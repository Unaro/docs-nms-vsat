import type postgres from "postgres";

interface JobDefinition {
  job_name: string;
  collector: "icmp" | "snmp" | "snmp_bulk" | "http";
  interval: number;
  is_vital?: boolean;
  port?: number;
  payload?: Record<string, any>;
}

interface CreateNodeParams {
  id: string;
  name: string;
  ipAddress: string;
  credentialId?: string | null;
  templateId?: string | null;
  customSnmpPort?: number;
}

/**
 * Атомарное создание устройства и синхронизация задач опроса
 */
export async function createMonitoredNode(
  sql: postgres.Sql,
  params: CreateNodeParams
) {
  return await sql.begin(async (tx) => {
    // 1. Создаем узел в monitored_nodes
    const [node] = await tx`
      INSERT INTO monitored_nodes (
        id, name, ip_address, credential_id, template_id, status, is_enabled, overrides
      )
      VALUES (
        ${params.id},
        ${params.name},
        ${params.ipAddress},
        ${params.credentialId || null},
        ${params.templateId || null},
        'offline',
        true,
        ${params.customSnmpPort ? tx.json({ port: params.customSnmpPort }) : tx.json({})}
      )
      RETURNING id, name, host(ip_address) as ip_address
    `;

    // 2. Инициализируем запись в оперативной таблице node_current_state
    await tx`
      INSERT INTO node_current_state (node_id, status, latency_ms, metrics, error_message, last_polled_by)
      VALUES (${params.id}, 'unknown', NULL, '{}'::jsonb, NULL, 'system')
      ON CONFLICT (node_id) DO NOTHING
    `;

    // 3. Если шаблон не выбран, создаем только базовый Vital Ping
    if (!params.templateId) {
      await tx`
        INSERT INTO poll_jobs (
          node_id, job_name, collector, is_vital, host, port, 
          poll_interval_sec, job_payload, next_poll_at
        )
        VALUES (
          ${params.id},
          'vital_ping',
          'icmp',
          true,
          ${params.ipAddress},
          0,
          3,
          '{"packets": 2, "timeout_ms": 1000}'::jsonb,
          now()
        )
      `;
      return node;
    }

    // 4. Вычитываем jobs_definition из шаблона
    const [template] = await tx<{ jobs_definition: JobDefinition[] }[]>`
      SELECT jobs_definition FROM metric_templates WHERE id = ${params.templateId}
    `;

    if (!template || !Array.isArray(template.jobs_definition)) {
      return node;
    }

    // 5. Разворачиваем шаблон в конкретные задачи в poll_jobs
    for (const job of template.jobs_definition) {
      const port =
        job.collector === "icmp"
          ? 0
          : params.customSnmpPort || job.port || 161;

      await tx`
        INSERT INTO poll_jobs (
          node_id, job_name, collector, is_vital, host, port,
          credential_id, job_payload, poll_interval_sec, next_poll_at
        )
        VALUES (
          ${params.id},
          ${job.job_name},
          ${job.collector},
          ${job.is_vital ?? false},
          ${params.ipAddress},
          ${port},
          ${params.credentialId || null},
          ${tx.json(job.payload ?? {})},
          ${job.interval || 60},
          now()
        )
      `;
    }

    return node;
  });
}