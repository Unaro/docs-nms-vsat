import { isIP } from "node:net";
import { data } from "react-router";

export class MonitoringError extends Error {
  constructor(message: string, public status = 400) { super(message); }
}
export function text(value: unknown, label: string, max = 128): string {
  if (typeof value !== "string" || !value.trim() || value.trim().length > max) throw new MonitoringError(`${label}: требуется строка длиной до ${max} символов`);
  return value.trim();
}
export function identifier(value: unknown) {
  const id = text(value, "Идентификатор", 64);
  if (!/^[a-zA-Z0-9_-]+$/.test(id)) throw new MonitoringError("Идентификатор: допустимы латинские буквы, цифры, _ и -");
  return id;
}
export function ipAddress(value: unknown) {
  const ip = text(value, "IP-адрес", 45);
  if (!isIP(ip)) throw new MonitoringError("Некорректный IP-адрес");
  return ip;
}
export function integer(value: unknown, label: string, min: number, max: number) {
  const number = typeof value === "string" && value.trim() ? Number(value) : value;
  if (typeof number !== "number" || !Number.isInteger(number) || number < min || number > max) throw new MonitoringError(`${label}: допустимо целое число от ${min} до ${max}`);
  return number;
}
export function subnet(value: unknown) {
  const cidr = text(value, "Подсеть", 32);
  const [ip, prefix, extra] = cidr.split("/");
  if (extra !== undefined || isIP(ip) !== 4 || !/^\d+$/.test(prefix ?? "")) throw new MonitoringError("Укажите IPv4 CIDR-подсеть");
  integer(prefix, "Префикс подсети", 24, 32);
  return cidr;
}
export function mutationError(error: unknown) {
  if (error instanceof Response) throw error;
  if (error instanceof MonitoringError) return data({ error: error.message }, { status: error.status });
  const code = (error as { code?: string })?.code;
  if (code === "23505") return data({ error: "Запись с такими данными уже существует" }, { status: 409 });
  if (code === "23503") return data({ error: "Связанный объект отсутствует или используется" }, { status: 409 });
  if (["23514", "22P02", "22001"].includes(code ?? "")) return data({ error: "Данные не соответствуют ограничениям базы" }, { status: 400 });
  console.error("Monitoring operation failed", error instanceof Error ? error.name : "Unknown error");
  return data({ error: "Не удалось выполнить операцию" }, { status: 500 });
}
