import type postgres from "postgres";

export type DbExecutor = postgres.Sql | postgres.TransactionSql;

export interface NodeMutationParams {
  id: string;
  name: string;
  ipAddress: string;
  credentialId?: string | null;
  templateId?: string | null;
  customSnmpPort?: number;
}

/**
 * Создание ad-hoc задачи в PostgreSQL с опциональным синхронным ожиданием результата.
 * Никаких системных процессов: Node.js общается только с PostgreSQL.
 */
async function dispatchAdhocTask(
  sql: postgres.Sql,
  taskType: "probe" | "inspect" | "discovery",
  targetHost: string,
  payload: Record<string, unknown> | string,
  waitResult = false,
  timeoutMs = 8000
) {
  // Нормализация: если payload уже строка, парсим в объект, затем чисто сериализуем один раз
  const cleanPayload = typeof payload === "string" ? JSON.parse(payload) : payload;
  const payloadJson = JSON.stringify(cleanPayload);

  // 1. Постановка задачи в очередь
  const [task] = await sql<Array<{ id: string }>>`
    INSERT INTO adhoc_tasks (task_type, target_host, payload, status)
    VALUES (${taskType}, ${targetHost}, ${payloadJson}::jsonb, 'pending')
    RETURNING id
  `;

  // 2. Оповещаем воркер через pg_notify
  await sql`SELECT pg_notify('adhoc_task_created', ${task.id})`;

  if (!waitResult) {
    return { taskId: task.id, status: "pending" };
  }

  // 3. Ожидание завершения задачи
  const startTime = Date.now();
  while (Date.now() - startTime < timeoutMs) {
    await new Promise((resolve) => setTimeout(resolve, 150));

    const [updated] = await sql<Array<{
      status: string;
      result: any;
      error_message: string | null;
    }>>`
      SELECT status, result, error_message
      FROM adhoc_tasks
      WHERE id = ${task.id}
    `;

    if (updated && updated.status !== "pending" && updated.status !== "running") {
      if (updated.status === "failed") {
        throw new Error(updated.error_message || "Выполнение задачи завершилось сбоем");
      }
      // Если драйвер вернул result как строку, безопасно парсим
      return typeof updated.result === "string" ? JSON.parse(updated.result) : updated.result;
    }
  }

  throw new Error("Таймаут ожидания ответа от демона опроса");
}

/**
 * Интерактивный Dry-Run тест через очередь БД
 */
export async function runDryRunProbe(sql: postgres.Sql, ip: string, port = 161, community = "public") {
  try {
    return await dispatchAdhocTask(
      sql,
      "probe",
      ip,
      { port, community },
      true, // ждем завершения
      6000
    );
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : "Сбой зонда";
    return {
      success: false,
      icmp: { ok: false, error: message },
      snmp: { ok: false, error: message },
    };
  }
}

/**
 * Разовая глубокая инспекция параметров через очередь БД
 */
export async function inspectAndSaveNode(sql: postgres.Sql, nodeId: string) {
  const [node] = await sql<Array<{
    id: string;
    ip_address: string;
    custom_port: number | null;
    cred_params: any;
  }>>`
    SELECT 
      n.id, 
      host(n.ip_address) as ip_address,
      (n.overrides->>'port')::int as custom_port,
      c.params as cred_params
    FROM monitored_nodes n
    LEFT JOIN credential_profiles c ON n.credential_id = c.id
    WHERE n.id = ${nodeId}
  `;

  if (!node) throw new Error("Устройство не найдено");

  const port = node.custom_port || 161;
  let community = "public";

  if (node.cred_params) {
    const creds = typeof node.cred_params === "string"
      ? JSON.parse(node.cred_params)
      : node.cred_params;
    if (creds?.community) community = creds.community;
  }

  const result = await dispatchAdhocTask(
    sql,
    "inspect",
    node.ip_address,
    { node_id: nodeId, port, community },
    true,
    10000
  );

  return result.snmp;
}

/**
 * Асинхронный запуск сетевого сканирования
 */
export async function spawnSubnetDiscovery(sql: postgres.Sql, cidr: string) {
  return await dispatchAdhocTask(
    sql,
    "discovery",
    cidr,
    { cidr },
    false // фоновое выполнение без блокировки
  );
}

// ----------------------------------------------------------------------------
// CRUD узлов (Чистый SQL)
// ----------------------------------------------------------------------------

export async function insertMonitoredNodeCore(
  tx: DbExecutor,
  params: NodeMutationParams
) {
  const [node] = await tx`
    INSERT INTO monitored_nodes (
      id, name, ip_address, credential_id, template_id, status, is_enabled, overrides
    )
    VALUES (
      ${params.id}, ${params.name}, ${params.ipAddress},
      ${params.credentialId || null}, ${params.templateId || null},
      'offline', true,
      ${params.customSnmpPort ? tx.json({ port: params.customSnmpPort }) : tx.json({})}
    )
    RETURNING id, name, host(ip_address) as ip_address
  `;

  await tx`
    INSERT INTO node_current_state (node_id, status, latency_ms, metrics, error_message, last_polled_by)
    VALUES (${params.id}, 'unknown', NULL, '{}'::jsonb, NULL, 'system')
    ON CONFLICT (node_id) DO NOTHING
  `;

  await syncNodeJobs(tx, params);
  return node;
}

export async function createMonitoredNode(sql: postgres.Sql, params: NodeMutationParams) {
  return await sql.begin(async (tx) => insertMonitoredNodeCore(tx, params));
}

export async function approveDiscoveredNode(
  sql: postgres.Sql,
  discoveredId: string,
  params: { name: string; templateId?: string | null; credentialId?: string | null }
) {
  return await sql.begin(async (tx) => {
    const [discovered] = await tx`
      SELECT host(ip_address) as ip_address, hostname, vendor
      FROM discovered_nodes WHERE id = ${discoveredId}
    `;
    if (!discovered) throw new Error("Запись в песочнице не найдена");

    const nodeId = `${params.name.toLowerCase().replace(/[^a-z0-9_-]/g, "-")}-${discovered.ip_address.replace(/\./g, "-")}`;

    await insertMonitoredNodeCore(tx, {
      id: nodeId,
      name: params.name,
      ipAddress: discovered.ip_address,
      templateId: params.templateId,
      credentialId: params.credentialId,
    });

    await tx`UPDATE discovered_nodes SET status = 'approved' WHERE id = ${discoveredId}`;
  });
}

export async function updateMonitoredNode(sql: postgres.Sql, params: NodeMutationParams) {
  return await sql.begin(async (tx) => {
    const [updated] = await tx`
      UPDATE monitored_nodes
      SET 
        name = ${params.name},
        ip_address = ${params.ipAddress},
        credential_id = ${params.credentialId || null},
        template_id = ${params.templateId || null},
        overrides = ${params.customSnmpPort ? tx.json({ port: params.customSnmpPort }) : tx.json({})},
        updated_at = now()
      WHERE id = ${params.id}
      RETURNING id, name, host(ip_address) as ip_address
    `;

    if (!updated) throw new Error("Узел не найден");

    await tx`DELETE FROM poll_jobs WHERE node_id = ${params.id}`;
    await syncNodeJobs(tx, params);
    return updated;
  });
}

export async function deleteMonitoredNode(sql: postgres.Sql, nodeId: string) {
  return await sql`DELETE FROM monitored_nodes WHERE id = ${nodeId}`;
}

async function syncNodeJobs(tx: DbExecutor, params: NodeMutationParams) {
  if (!params.templateId) {
    await tx`
      INSERT INTO poll_jobs (node_id, job_name, collector, is_vital, host, port, poll_interval_sec, job_payload, next_poll_at)
      VALUES (${params.id}, 'vital_ping', 'icmp', true, ${params.ipAddress}, 0, 3, '{"packets": 2, "timeout_ms": 1000}'::jsonb, now())
    `;
    return;
  }

  const [template] = await tx<{ jobs_definition: any[] }[]>`
    SELECT jobs_definition FROM metric_templates WHERE id = ${params.templateId}
  `;

  if (!template || !Array.isArray(template.jobs_definition)) return;

  for (const job of template.jobs_definition) {
    const port = job.collector === "icmp" ? 0 : params.customSnmpPort || job.port || 161;
    const payloadJson = JSON.stringify(job.payload ?? {});

    await tx`
      INSERT INTO poll_jobs (
        node_id, job_name, collector, is_vital, host, port,
        credential_id, job_payload, poll_interval_sec, next_poll_at
      )
      VALUES (
        ${params.id}, ${job.job_name}, ${job.collector}, ${job.is_vital ?? false},
        ${params.ipAddress}, ${port}, ${params.credentialId || null},
        ${payloadJson}::jsonb, ${job.interval || 60}, now()
      )
    `;
  }
}