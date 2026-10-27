import type postgres from "postgres";

export type DbExecutor = postgres.Sql | postgres.TransactionSql;

export interface OidDefinition {
  key: string;
  oid: string;
}

export interface JobDefinition {
  job_name: string;
  collector: "icmp" | "snmp" | "snmp_bulk" | "http";
  interval: number;
  is_vital?: boolean;
  port?: number;
  payload?: {
    packets?: number;
    timeout_ms?: number;
    oids?: OidDefinition[];
    [key: string]: unknown;
  };
}

export interface MetricTemplateData {
  id: string;
  name: string;
  vendor: string | null;
  sys_object_id_pattern: string | null;
  jobs_definition: JobDefinition[];
}

export interface CredentialProfileData {
  id: string;
  name: string;
  protocol: "snmp_v2c" | "snmp_v3" | "http";
  params: Record<string, unknown>;
}

// ============================================================================
// METRIC TEMPLATES
// ============================================================================

export async function getMetricTemplate(sql: postgres.Sql, id: string) {
  const [template] = await sql<MetricTemplateData[]>`
    SELECT id, name, vendor, sys_object_id_pattern, jobs_definition
    FROM metric_templates
    WHERE id = ${id}
  `;
  return template || null;
}

export async function createMetricTemplate(sql: postgres.Sql, data: MetricTemplateData) {
  const jobsJson = JSON.stringify(data.jobs_definition);

  return await sql`
    INSERT INTO metric_templates (id, name, vendor, sys_object_id_pattern, jobs_definition)
    VALUES (
      ${data.id}, 
      ${data.name}, 
      ${data.vendor || null}, 
      ${data.sys_object_id_pattern || null}, 
      ${jobsJson}::jsonb
    )
    RETURNING id, name
  `;
}

export async function updateMetricTemplate(sql: postgres.Sql, data: MetricTemplateData) {
  return await sql.begin(async (tx) => {
    const jobsJson = JSON.stringify(data.jobs_definition);

    const [template] = await tx`
      UPDATE metric_templates
      SET 
        name = ${data.name},
        vendor = ${data.vendor || null},
        sys_object_id_pattern = ${data.sys_object_id_pattern || null},
        jobs_definition = ${jobsJson}::jsonb,
        updated_at = now()
      WHERE id = ${data.id}
      RETURNING id, name
    `;

    if (!template) throw new Error("Шаблон не найден");

    // Выбираем узлы, использующие этот шаблон
    const nodes = await tx<Array<{
      id: string;
      ip_address: string;
      credential_id: string | null;
      custom_port: number | null;
    }>>`
      SELECT 
        id, 
        host(ip_address) as ip_address, 
        credential_id,
        (overrides->>'port')::int as custom_port
      FROM monitored_nodes
      WHERE template_id = ${data.id} AND is_enabled = true
    `;

    // Каскадная перегенерация poll_jobs для всех затронутых узлов
    for (const node of nodes) {
      await tx`DELETE FROM poll_jobs WHERE node_id = ${node.id}`;

      for (const job of data.jobs_definition) {
        const port = job.collector === "icmp" ? 0 : node.custom_port || job.port || 161;
        const payloadJson = JSON.stringify(job.payload ?? {});

        await tx`
          INSERT INTO poll_jobs (
            node_id, job_name, collector, is_vital, host, port,
            credential_id, job_payload, poll_interval_sec, next_poll_at
          )
          VALUES (
            ${node.id}, 
            ${job.job_name}, 
            ${job.collector}, 
            ${job.is_vital ?? false},
            ${node.ip_address}, 
            ${port}, 
            ${node.credential_id},
            ${payloadJson}::jsonb, 
            ${job.interval || 60}, 
            now()
          )
        `;
      }
    }

    return template;
  });
}

export async function deleteMetricTemplate(sql: postgres.Sql, id: string) {
  return await sql.begin(async (tx) => {
    const [usage] = await tx`
      SELECT COUNT(id)::int as count FROM monitored_nodes WHERE template_id = ${id}
    `;
    if (usage && usage.count > 0) {
      throw new Error(`Нельзя удалить шаблон: он привязан к ${usage.count} устройствам`);
    }

    const [deleted] = await tx`DELETE FROM metric_templates WHERE id = ${id} RETURNING id`;
    return deleted;
  });
}

// ============================================================================
// CREDENTIAL PROFILES
// ============================================================================

export async function createCredentialProfile(sql: postgres.Sql, data: CredentialProfileData) {
  const paramsJson = JSON.stringify(data.params);
  return await sql`
    INSERT INTO credential_profiles (id, name, protocol, params)
    VALUES (${data.id}, ${data.name}, ${data.protocol}, ${paramsJson}::jsonb)
    RETURNING id, name, protocol
  `;
}

export async function updateCredentialProfile(sql: postgres.Sql, data: CredentialProfileData) {
  const paramsJson = JSON.stringify(data.params);
  return await sql`
    UPDATE credential_profiles
    SET 
      name = ${data.name},
      protocol = ${data.protocol},
      params = ${paramsJson}::jsonb,
      updated_at = now()
    WHERE id = ${data.id}
    RETURNING id, name, protocol
  `;
}

export async function deleteCredentialProfile(sql: postgres.Sql, id: string) {
  return await sql.begin(async (tx) => {
    const [usage] = await tx`
      SELECT COUNT(id)::int as count FROM monitored_nodes WHERE credential_id = ${id}
    `;
    if (usage && usage.count > 0) {
      throw new Error(`Нельзя удалить профиль: он используется на ${usage.count} устройствах`);
    }

    await tx`UPDATE poll_jobs SET credential_id = NULL WHERE credential_id = ${id}`;
    const [deleted] = await tx`DELETE FROM credential_profiles WHERE id = ${id} RETURNING id`;
    return deleted;
  });
}