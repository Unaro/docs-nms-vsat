import type postgres from "postgres";
import { integer, MonitoringError, text } from "./validation.server";

export type DbExecutor = postgres.Sql | postgres.TransactionSql;
export interface OidDefinition { key: string; oid: string }
export interface JobDefinition {
  job_name: string;
  collector: "icmp" | "snmp";
  interval: number;
  is_vital?: boolean;
  port?: number;
  payload?: { packets?: number; timeout_ms?: number; oids?: OidDefinition[]; [key: string]: unknown };
}
export function validateJobs(input: unknown): JobDefinition[] {
  if (!Array.isArray(input) || input.length < 1 || input.length > 50) throw new MonitoringError("Шаблон должен содержать от 1 до 50 задач");
  const names = new Set<string>();
  const jobs = input.map((raw): JobDefinition => {
    if (!raw || typeof raw !== "object") throw new MonitoringError("Некорректная задача");
    const job_name = text(raw.job_name, "Имя задачи", 64);
    if (names.has(job_name)) throw new MonitoringError("Имена задач должны быть уникальны");
    names.add(job_name);
    if (raw.collector !== "icmp" && raw.collector !== "snmp") throw new MonitoringError("Демон поддерживает только ICMP и SNMPv2c");
    if (raw.is_vital !== undefined && typeof raw.is_vital !== "boolean") throw new MonitoringError("Некорректный признак обязательной проверки");
    const payload = raw.payload ?? {};
    if (typeof payload !== "object" || Array.isArray(payload)) throw new MonitoringError("Некорректные параметры задачи");
    const timeout_ms = integer(payload.timeout_ms ?? 2000, "Таймаут", 100, 10000);
    const normalized: JobDefinition = { job_name, collector: raw.collector, interval: integer(raw.interval, "Интервал", 1, 86400), is_vital: raw.is_vital ?? false, payload: { timeout_ms } };
    if (raw.collector === "icmp") normalized.payload!.packets = integer(payload.packets ?? 2, "Пакеты", 1, 5);
    else {
      normalized.port = integer(raw.port ?? 161, "Порт", 1, 65535);
      if (!Array.isArray(payload.oids) || !payload.oids.length || payload.oids.length > 100) throw new MonitoringError("Укажите от 1 до 100 OID");
      const keys = new Set<string>();
      normalized.payload!.oids = payload.oids.map((oid: OidDefinition) => {
        const key = text(oid?.key, "Ключ метрики", 64);
        const value = text(oid?.oid, "OID", 255);
        if (!/^\.?[0-2](?:\.\d+)+$/.test(value) || keys.has(key)) throw new MonitoringError("Некорректный OID или повторяющийся ключ");
        keys.add(key);
        return { key, oid: value };
      });
    }
    return normalized;
  });
  if (!jobs.some(job => job.is_vital)) throw new MonitoringError("Шаблон должен содержать обязательную проверку доступности");
  return jobs;
}
export interface NodeJobParams { id: string; ipAddress: string; credentialId?: string | null; templateId?: string | null; customSnmpPort?: number }
export async function syncNodeJobs(tx: DbExecutor, params: NodeJobParams) {
  let jobs: JobDefinition[] = [{ job_name: "vital_ping", collector: "icmp", interval: 3, is_vital: true, payload: { packets: 2, timeout_ms: 1000 } }];
  if (params.templateId) {
    const [template] = await tx`SELECT jobs_definition FROM metric_templates WHERE id = ${params.templateId} FOR SHARE`;
    if (!template) throw new MonitoringError("Шаблон не найден", 404);
    jobs = validateJobs(template.jobs_definition);
  }
  if (params.credentialId) {
    const [credential] = await tx`SELECT protocol FROM credential_profiles WHERE id = ${params.credentialId} FOR SHARE`;
    if (!credential) throw new MonitoringError("Профиль не найден", 404);
    if (credential.protocol !== "snmp_v2c") throw new MonitoringError("Профиль не поддерживается демоном");
  }
  const existing = await tx`SELECT * FROM poll_jobs WHERE node_id = ${params.id} FOR UPDATE`;
  for (const old of existing) {
    const job = jobs.find(item => item.job_name === old.job_name);
    const port = job?.collector === "icmp" ? 0 : params.customSnmpPort ?? job?.port ?? 161;
    const credential = job?.collector === "icmp" ? null : params.credentialId || null;
    const unchanged = job && old.collector === job.collector && old.is_vital === (job.is_vital ?? false) && old.host === params.ipAddress && old.port === port && old.credential_id === credential && old.poll_interval_sec === job.interval && JSON.stringify(old.job_payload) === JSON.stringify(job.payload ?? {});
    if (!unchanged) await tx`DELETE FROM poll_jobs WHERE id = ${old.id}`;
  }
  for (const job of jobs) {
    const [retained] = await tx`SELECT id FROM poll_jobs WHERE node_id = ${params.id} AND job_name = ${job.job_name}`;
    if (retained) continue;
    await tx`
      INSERT INTO poll_jobs (node_id, job_name, collector, is_vital, host, port, credential_id, job_payload, poll_interval_sec, next_poll_at)
      VALUES (${params.id}, ${job.job_name}, ${job.collector}, ${job.is_vital ?? false}, ${params.ipAddress}, ${job.collector === "icmp" ? 0 : params.customSnmpPort ?? job.port ?? 161}, ${job.collector === "icmp" ? null : params.credentialId || null}, ${JSON.stringify(job.payload ?? {})}::jsonb, ${job.interval}, now())
    `;
  }
}
