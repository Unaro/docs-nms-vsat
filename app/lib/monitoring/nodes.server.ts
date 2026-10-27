import type postgres from "postgres";
import { randomUUID } from "node:crypto";
import { syncNodeJobs, type DbExecutor } from "./jobs.server";
import { identifier, integer, ipAddress, MonitoringError, subnet, text } from "./validation.server";

export interface NodeMutationParams {
  id: string; name: string; ipAddress: string;
  credentialId?: string | null; templateId?: string | null; customSnmpPort?: number;
}
function validateNode(params: NodeMutationParams) {
  identifier(params.id);
  params.name = text(params.name, "Имя узла");
  params.ipAddress = ipAddress(params.ipAddress);
  if (params.customSnmpPort !== undefined) integer(params.customSnmpPort, "Порт", 1, 65535);
  if (params.credentialId) identifier(params.credentialId);
  if (params.templateId) identifier(params.templateId);
}
async function dispatchAdhocTask(sql: postgres.Sql, type: "probe" | "inspect" | "discovery", host: string, payload: Record<string, unknown>) {
  return sql.begin(async tx => {
    const [task] = await tx<{ id: string }[]>`
      INSERT INTO adhoc_tasks (task_type, target_host, payload, status)
      VALUES (${type}, ${host}, ${JSON.stringify(payload)}::jsonb, 'pending') RETURNING id
    `;
    await tx`SELECT pg_notify('adhoc_task_created', ${task.id})`;
    return { taskId: task.id, status: "pending" as const };
  });
}
export async function runDryRunProbe(sql: postgres.Sql, ip: string, port = 161, credentialId?: string) {
  ipAddress(ip); integer(port, "Порт", 1, 65535);
  if (credentialId) {
    const [credential] = await sql`SELECT protocol FROM credential_profiles WHERE id = ${identifier(credentialId)}`;
    if (!credential) throw new MonitoringError("Профиль не найден", 404);
    if (credential.protocol !== "snmp_v2c") throw new MonitoringError("Поддерживается только SNMPv2c");
  }
  return dispatchAdhocTask(sql, "probe", ip, { port, credential_id: credentialId || null });
}
export async function inspectAndSaveNode(sql: postgres.Sql, nodeId: string) {
  const [node] = await sql`
    SELECT n.id, host(n.ip_address) AS ip_address, (n.overrides->>'port')::int AS custom_port,
      n.credential_id, c.protocol FROM monitored_nodes n
    LEFT JOIN credential_profiles c ON n.credential_id = c.id WHERE n.id = ${identifier(nodeId)} AND n.is_enabled = true
  `;
  if (!node) throw new MonitoringError("Устройство не найдено или отключено", 404);
  if (node.protocol && node.protocol !== "snmp_v2c") throw new MonitoringError("Поддерживается только SNMPv2c");
  return dispatchAdhocTask(sql, "inspect", node.ip_address, { node_id: nodeId, port: node.custom_port || 161, credential_id: node.credential_id });
}
export async function spawnSubnetDiscovery(sql: postgres.Sql, cidr: string) {
  return dispatchAdhocTask(sql, "discovery", subnet(cidr), { cidr });
}
export async function insertMonitoredNodeCore(tx: DbExecutor, params: NodeMutationParams) {
  validateNode(params);
  const [node] = await tx`
    INSERT INTO monitored_nodes (id, name, ip_address, credential_id, template_id, status, is_enabled, overrides)
    VALUES (${params.id}, ${params.name}, ${params.ipAddress}, ${params.credentialId || null}, ${params.templateId || null},
      'offline', true, ${JSON.stringify(params.customSnmpPort ? { port: params.customSnmpPort } : {})}::jsonb)
    RETURNING id, name, host(ip_address) AS ip_address
  `;
  await tx`INSERT INTO node_current_state (node_id, status) VALUES (${params.id}, 'unknown')`;
  await syncNodeJobs(tx, params);
  return node;
}
export async function createMonitoredNode(sql: postgres.Sql, params: NodeMutationParams) {
  return sql.begin(tx => insertMonitoredNodeCore(tx, params));
}
export async function approveDiscoveredNode(sql: postgres.Sql, discoveredId: string, params: { name: string; templateId?: string | null; credentialId?: string | null }) {
  return sql.begin(async tx => {
    const [discovered] = await tx`SELECT host(ip_address) AS ip_address, status FROM discovered_nodes WHERE id = ${discoveredId} FOR UPDATE`;
    if (!discovered) throw new MonitoringError("Запись в песочнице не найдена", 404);
    if (discovered.status !== "new") throw new MonitoringError("Устройство уже обработано", 409);
    const [existing] = await tx`SELECT id FROM monitored_nodes WHERE ip_address = ${discovered.ip_address}::inet`;
    if (existing) throw new MonitoringError("Этот адрес уже находится в мониторинге", 409);
    await insertMonitoredNodeCore(tx, { id: randomUUID(), name: params.name, ipAddress: discovered.ip_address, templateId: params.templateId, credentialId: params.credentialId });
    await tx`UPDATE discovered_nodes SET status = 'approved' WHERE id = ${discoveredId}`;
  });
}
export async function updateMonitoredNode(sql: postgres.Sql, params: NodeMutationParams) {
  validateNode(params);
  return sql.begin(async tx => {
    const [previous] = await tx`SELECT host(ip_address) AS ip_address, credential_id, template_id, overrides FROM monitored_nodes WHERE id = ${params.id} FOR UPDATE`;
    if (!previous) throw new MonitoringError("Узел не найден", 404);
    const [updated] = await tx`
      UPDATE monitored_nodes SET name = ${params.name}, ip_address = ${params.ipAddress},
        credential_id = ${params.credentialId || null}, template_id = ${params.templateId || null},
        overrides = overrides || ${JSON.stringify({ port: params.customSnmpPort ?? null })}::jsonb, updated_at = now()
      WHERE id = ${params.id} RETURNING id, name, host(ip_address) AS ip_address
    `;
    await syncNodeJobs(tx, params);
    if (previous.ip_address !== params.ipAddress || previous.credential_id !== (params.credentialId || null) || previous.template_id !== (params.templateId || null) || (previous.overrides?.port ?? null) !== (params.customSnmpPort ?? null)) {
      await tx`UPDATE node_current_state SET status = 'unknown', latency_ms = NULL, metrics = '{}'::jsonb, error_message = NULL, updated_at = now() WHERE node_id = ${params.id}`;
    }
    return updated;
  });
}
export async function deleteMonitoredNode(sql: postgres.Sql, nodeId: string) {
  const [deleted] = await sql`DELETE FROM monitored_nodes WHERE id = ${identifier(nodeId)} RETURNING id`;
  if (!deleted) throw new MonitoringError("Узел не найден", 404);
  return deleted;
}
