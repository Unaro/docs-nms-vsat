import type postgres from "postgres";
import { syncNodeJobs, validateJobs, type JobDefinition } from "./jobs.server";
import { identifier, MonitoringError, text } from "./validation.server";
export type { JobDefinition, OidDefinition, DbExecutor } from "./jobs.server";
export interface MetricTemplateData { id: string; name: string; vendor: string | null; sys_object_id_pattern: string | null; jobs_definition: JobDefinition[] }
export interface CredentialProfileData { id: string; name: string; protocol: "snmp_v2c" | "snmp_v3" | "http"; params: Record<string, string> }
function validateTemplate(input: MetricTemplateData) {
  identifier(input.id); text(input.name, "Название");
  if (input.vendor) text(input.vendor, "Производитель", 64);
  if (input.sys_object_id_pattern && !/^\.?[0-2](?:\.\d+)+(?:\.\*)?$/.test(input.sys_object_id_pattern)) throw new MonitoringError("Некорректный префикс sysObjectID");
  input.jobs_definition = validateJobs(input.jobs_definition);
}
export async function getMetricTemplate(sql: postgres.Sql, id: string) {
  const [template] = await sql<MetricTemplateData[]>`SELECT id, name, vendor, sys_object_id_pattern, jobs_definition FROM metric_templates WHERE id = ${identifier(id)}`;
  return template ?? null;
}
export async function createMetricTemplate(sql: postgres.Sql, input: MetricTemplateData) {
  validateTemplate(input);
  return sql`INSERT INTO metric_templates (id, name, vendor, sys_object_id_pattern, jobs_definition)
    VALUES (${input.id}, ${input.name}, ${input.vendor}, ${input.sys_object_id_pattern}, ${JSON.stringify(input.jobs_definition)}::jsonb) RETURNING id, name`;
}
export async function updateMetricTemplate(sql: postgres.Sql, input: MetricTemplateData) {
  validateTemplate(input);
  return sql.begin(async tx => {
    const nodes = await tx`SELECT id, host(ip_address) AS ip_address, credential_id, (overrides->>'port')::int AS custom_port FROM monitored_nodes WHERE template_id = ${input.id} ORDER BY id FOR UPDATE`;
    const [template] = await tx`UPDATE metric_templates SET name = ${input.name}, vendor = ${input.vendor}, sys_object_id_pattern = ${input.sys_object_id_pattern}, jobs_definition = ${JSON.stringify(input.jobs_definition)}::jsonb, updated_at = now() WHERE id = ${input.id} RETURNING id, name`;
    if (!template) throw new MonitoringError("Шаблон не найден", 404);
    for (const node of nodes) await syncNodeJobs(tx, { id: node.id, ipAddress: node.ip_address, templateId: input.id, credentialId: node.credential_id, customSnmpPort: node.custom_port ?? undefined });
    return template;
  });
}
export async function deleteMetricTemplate(sql: postgres.Sql, id: string) {
  return sql.begin(async tx => {
    const [template] = await tx`SELECT id FROM metric_templates WHERE id = ${identifier(id)} FOR UPDATE`;
    if (!template) throw new MonitoringError("Шаблон не найден", 404);
    const [usage] = await tx`SELECT count(*)::int AS count FROM monitored_nodes WHERE template_id = ${id}`;
    if (usage.count) throw new MonitoringError(`Шаблон используется на ${usage.count} устройствах`, 409);
    return tx`DELETE FROM metric_templates WHERE id = ${id} RETURNING id`;
  });
}
function validateCredential(input: CredentialProfileData) {
  identifier(input.id); text(input.name, "Название");
  if (input.protocol !== "snmp_v2c") throw new MonitoringError("Демон поддерживает только SNMPv2c");
}
export async function createCredentialProfile(sql: postgres.Sql, input: CredentialProfileData) {
  validateCredential(input);
  const community = text(input.params.community, "Community", 255);
  return sql`INSERT INTO credential_profiles (id, name, protocol, params) VALUES (${input.id}, ${input.name}, ${input.protocol}, ${JSON.stringify({ community })}::jsonb) RETURNING id, name, protocol`;
}
export async function updateCredentialProfile(sql: postgres.Sql, input: CredentialProfileData) {
  validateCredential(input);
  return sql.begin(async tx => {
    const [old] = await tx`SELECT params, protocol FROM credential_profiles WHERE id = ${input.id} FOR UPDATE`;
    if (!old) throw new MonitoringError("Профиль не найден", 404);
    const community = text(input.params.community || (old.protocol === "snmp_v2c" ? old.params.community : ""), "Community", 255);
    return tx`UPDATE credential_profiles SET name = ${input.name}, protocol = ${input.protocol}, params = ${JSON.stringify({ community })}::jsonb, updated_at = now() WHERE id = ${input.id} RETURNING id, name, protocol`;
  });
}
export async function deleteCredentialProfile(sql: postgres.Sql, id: string) {
  return sql.begin(async tx => {
    const [profile] = await tx`SELECT id FROM credential_profiles WHERE id = ${identifier(id)} FOR UPDATE`;
    if (!profile) throw new MonitoringError("Профиль не найден", 404);
    const [usage] = await tx`SELECT count(*)::int AS count FROM monitored_nodes WHERE credential_id = ${id}`;
    if (usage.count) throw new MonitoringError(`Профиль используется на ${usage.count} устройствах`, 409);
    return tx`DELETE FROM credential_profiles WHERE id = ${id} RETURNING id`;
  });
}
