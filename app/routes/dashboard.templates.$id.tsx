import { useState } from "react";
import { data, Link, redirect, useFetcher, type ActionFunctionArgs, type LoaderFunctionArgs } from "react-router";
import type { Route } from "./+types/dashboard.templates.$id";
import { db } from "~/lib/db.server";
import {
  getMetricTemplate,
  createMetricTemplate,
  updateMetricTemplate,
  type JobDefinition,
  type OidDefinition,
} from "~/lib/monitoring/config.server";
import { Badge } from "~/components/ui/badge";
import { Button } from "~/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "~/components/ui/card";
import { Input } from "~/components/ui/input";
import { Label } from "~/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "~/components/ui/select";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "~/components/ui/table";

const DEFAULT_NEW_TEMPLATE = {
  id: "",
  name: "",
  vendor: "",
  sys_object_id_pattern: "",
  jobs_definition: [
    {
      job_name: "vital_ping",
      collector: "icmp" as const,
      interval: 3,
      is_vital: true,
      payload: { packets: 2, timeout_ms: 1000 },
    },
    {
      job_name: "system_info",
      collector: "snmp" as const,
      interval: 30,
      is_vital: false,
      payload: {
        timeout_ms: 2000,
        oids: [
          { key: "sys_descr", oid: "1.3.6.1.2.1.1.1.0" },
          { key: "sys_uptime", oid: "1.3.6.1.2.1.1.3.0" },
          { key: "sys_name", oid: "1.3.6.1.2.1.1.5.0" },
        ],
      },
    },
  ],
};

export async function loader({ params }: LoaderFunctionArgs) {
  const id = params.id;
  if (!id) throw new Response("ID required", { status: 400 });

  if (id === "new") {
    return { isNew: true, template: DEFAULT_NEW_TEMPLATE };
  }

  const template = await getMetricTemplate(db, id);
  if (!template) {
    throw new Response("Шаблон не найден", { status: 404 });
  }

  return { isNew: false, template };
}

export async function action({ request, params }: ActionFunctionArgs) {
  const isNew = params.id === "new";
  const formData = await request.formData();

  const id = String(formData.get("id") || "").trim();
  const name = String(formData.get("name") || "").trim();
  const vendor = String(formData.get("vendor") || "").trim() || null;
  const sys_object_id_pattern = String(formData.get("sys_object_id_pattern") || "").trim() || null;
  const jobsJson = String(formData.get("jobs_definition") || "[]");

  if (!id || !name) {
    return data({ error: "Идентификатор и Название обязательны для заполнения" }, { status: 400 });
  }

  let jobs: JobDefinition[] = [];
  try {
    jobs = JSON.parse(jobsJson);
    if (!Array.isArray(jobs) || jobs.length === 0) {
      return data({ error: "Шаблон должен содержать хотя бы одну задачу опроса" }, { status: 400 });
    }
  } catch (err: unknown) {
    return data({ error: "Ошибка структуры данных задач" }, { status: 400 });
  }

  try {
    if (isNew) {
      await createMetricTemplate(db, {
        id,
        name,
        vendor,
        sys_object_id_pattern,
        jobs_definition: jobs,
      });
    } else {
      await updateMetricTemplate(db, {
        id,
        name,
        vendor,
        sys_object_id_pattern,
        jobs_definition: jobs,
      });
    }
    return redirect("/dashboard/templates");
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : "Ошибка сохранения шаблона";
    return data({ error: message }, { status: 500 });
  }
}

export default function TemplateEditorRoute({ loaderData }: Route.ComponentProps) {
  const { isNew, template } = loaderData;
  const fetcher = useFetcher<{ error?: string }>();
  const isSaving = fetcher.state !== "idle";

  const [id, setId] = useState(template.id);
  const [name, setName] = useState(template.name);
  const [vendor, setVendor] = useState(template.vendor || "");
  const [pattern, setPattern] = useState(template.sys_object_id_pattern || "");
  const [jobs, setJobs] = useState<JobDefinition[]>(
    Array.isArray(template.jobs_definition) ? template.jobs_definition : []
  );

  // Мутации списка задач
  const addJob = () => {
    const newJob: JobDefinition = {
      job_name: `snmp_metrics_${jobs.length + 1}`,
      collector: "snmp",
      interval: 15,
      is_vital: false,
      payload: {
        timeout_ms: 2000,
        oids: [{ key: "metric_1", oid: "1.3.6.1.2.1.1.1.0" }],
      },
    };
    setJobs([...jobs, newJob]);
  };

  const removeJob = (index: number) => {
    setJobs(jobs.filter((_, i) => i !== index));
  };

  const updateJob = <K extends keyof JobDefinition>(index: number, field: K, value: JobDefinition[K]) => {
    setJobs(jobs.map((j, i) => (i === index ? { ...j, [field]: value } : j)));
  };

  // Мутации OID внутри конкретной задачи
  const addOidToJob = (jobIndex: number) => {
    setJobs(
      jobs.map((j, i) => {
        if (i !== jobIndex) return j;
        const currentOids = j.payload?.oids || [];
        return {
          ...j,
          payload: {
            ...j.payload,
            oids: [...currentOids, { key: `val_${currentOids.length + 1}`, oid: "" }],
          },
        };
      })
    );
  };

  const updateOidInJob = (jobIndex: number, oidIndex: number, field: keyof OidDefinition, val: string) => {
    setJobs(
      jobs.map((j, i) => {
        if (i !== jobIndex) return j;
        const currentOids = (j.payload?.oids || []).map((o, oi) =>
          oi === oidIndex ? { ...o, [field]: val } : o
        );
        return {
          ...j,
          payload: {
            ...j.payload,
            oids: currentOids,
          },
        };
      })
    );
  };

  const removeOidFromJob = (jobIndex: number, oidIndex: number) => {
    setJobs(
      jobs.map((j, i) => {
        if (i !== jobIndex) return j;
        return {
          ...j,
          payload: {
            ...j.payload,
            oids: (j.payload?.oids || []).filter((_, oi) => oi !== oidIndex),
          },
        };
      })
    );
  };

  return (
    <div className="container mx-auto p-6 max-w-5xl space-y-6">
      {/* 1. Header & Actions Bar */}
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4 border-b pb-4">
        <div>
          <div className="flex items-center gap-2 text-sm text-muted-foreground">
            <Link to="/dashboard" className="hover:underline">Инфраструктура</Link>
            <span>/</span>
            <Link to="/dashboard/templates" className="hover:underline">Шаблоны</Link>
            <span>/</span>
            <span className="text-foreground">{isNew ? "Новый шаблон" : template.name}</span>
          </div>
          <h1 className="text-2xl font-bold tracking-tight">
            {isNew ? "Создание шаблона метрик" : `Редактор: ${template.name}`}
          </h1>
        </div>

        <div className="flex items-center gap-2">
          <Link to="/dashboard/templates">
            <Button variant="outline">Отмена</Button>
          </Link>
          <Button type="submit" form="template-editor-form" disabled={isSaving}>
            {isSaving ? "Сохранение..." : isNew ? "Создать шаблон" : "Сохранить изменения"}
          </Button>
        </div>
      </div>

      {fetcher.data?.error && (
        <div className="rounded-md bg-destructive/15 p-4 text-sm text-destructive font-medium">
          {fetcher.data.error}
        </div>
      )}

      <fetcher.Form id="template-editor-form" method="post" className="space-y-6">
        {/* Скрытый JSON со всеми задачами и OID */}
        <input type="hidden" name="jobs_definition" value={JSON.stringify(jobs)} />

        {/* 2. Общие свойства шаблона */}
        <Card>
          <CardHeader>
            <CardTitle>Основные параметры</CardTitle>
            <CardDescription>
              Идентификация шаблона и привязка к автообнаружению (Discovery)
            </CardDescription>
          </CardHeader>
          <CardContent className="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div className="space-y-2">
              <Label htmlFor="id">Идентификатор (ID шаблона)</Label>
              <Input
                id="id"
                name="id"
                value={id}
                onChange={(e) => setId(e.target.value)}
                readOnly={!isNew}
                placeholder="tpl-cisco-switch"
                className="font-mono text-sm"
                required
              />
              <p className="text-[11px] text-muted-foreground">Уникальный ID в базе данных (не меняется после создания)</p>
            </div>

            <div className="space-y-2">
              <Label htmlFor="name">Название шаблона</Label>
              <Input
                id="name"
                name="name"
                value={name}
                onChange={(e) => setName(e.target.value)}
                placeholder="Cisco Catalyst 2960/3750"
                required
              />
            </div>

            <div className="space-y-2">
              <Label htmlFor="vendor">Вендор / Семейство</Label>
              <Input
                id="vendor"
                name="vendor"
                value={vendor}
                onChange={(e) => setVendor(e.target.value)}
                placeholder="Cisco Systems"
              />
            </div>

            <div className="space-y-2">
              <Label htmlFor="sys_object_id_pattern">Discovery Pattern (sysObjectID)</Label>
              <Input
                id="sys_object_id_pattern"
                name="sys_object_id_pattern"
                value={pattern}
                onChange={(e) => setPattern(e.target.value)}
                placeholder="1.3.6.1.4.1.9.1.*"
                className="font-mono text-sm"
              />
              <p className="text-[11px] text-muted-foreground">Шаблон OID для автоматического выбора этого профиля при сканировании</p>
            </div>
          </CardContent>
        </Card>

        {/* 3. Список задач опроса */}
        <div className="space-y-4">
          <div className="flex items-center justify-between">
            <div>
              <h2 className="text-lg font-bold tracking-tight">Задачи опроса ({jobs.length})</h2>
              <p className="text-sm text-muted-foreground">
                Каждая задача выполняется воркером независимо с заданным интервалом
              </p>
            </div>
            <Button type="button" variant="outline" onClick={addJob}>
              + Добавить задачу
            </Button>
          </div>

          {jobs.map((job, jIdx) => (
            <Card key={jIdx} className="border-l-4 border-l-primary/60">
              <CardHeader className="pb-3">
                <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-3">
                  <div className="flex items-center gap-3">
                    <span className="text-xs font-mono font-bold text-muted-foreground">#{jIdx + 1}</span>
                    <Input
                      value={job.job_name}
                      onChange={(e) => updateJob(jIdx, "job_name", e.target.value)}
                      placeholder="Имя задачи (например, cpu_load)"
                      className="font-mono font-semibold text-sm h-8 w-[220px]"
                    />
                    <Badge variant="outline" className="uppercase text-[10px] font-mono">
                      {job.collector}
                    </Badge>
                  </div>

                  <div className="flex items-center gap-2">
                    <label className="flex items-center gap-2 text-xs font-medium cursor-pointer border rounded px-2.5 py-1 bg-background">
                      <input
                        type="checkbox"
                        checked={Boolean(job.is_vital)}
                        onChange={(e) => updateJob(jIdx, "is_vital", e.target.checked)}
                        className="rounded"
                      />
                      <span>Vital (Gatekeeper)</span>
                    </label>

                    <Button
                      type="button"
                      variant="ghost"
                      size="sm"
                      className="text-destructive hover:text-destructive h-8 px-2"
                      onClick={() => removeJob(jIdx)}
                    >
                      Удалить задачу
                    </Button>
                  </div>
                </div>
              </CardHeader>

              <CardContent className="space-y-4">
                {/* Настройки выполнения */}
                <div className="grid grid-cols-1 sm:grid-cols-3 gap-3 bg-muted/40 p-3 rounded-md">
                  <div className="space-y-1">
                    <Label className="text-xs">Тип коллектора</Label>
                    <Select
                      value={job.collector}
                      onValueChange={(val) => updateJob(jIdx, "collector", val as any)}
                    >
                      <SelectTrigger className="h-8 text-xs bg-background">
                        <SelectValue />
                      </SelectTrigger>
                      <SelectContent>
                        <SelectItem value="icmp">ICMP (Ping / RTT)</SelectItem>
                        <SelectItem value="snmp">SNMP (Скалярные OID)</SelectItem>
                        <SelectItem value="snmp_bulk">SNMP Bulk (Таблицы)</SelectItem>
                      </SelectContent>
                    </Select>
                  </div>

                  <div className="space-y-1">
                    <Label className="text-xs">Интервал опроса (сек)</Label>
                    <Input
                      type="number"
                      min={1}
                      value={job.interval}
                      onChange={(e) => updateJob(jIdx, "interval", Number(e.target.value))}
                      className="h-8 text-xs font-mono bg-background"
                    />
                  </div>

                  <div className="space-y-1">
                    <Label className="text-xs">Таймаут (мс)</Label>
                    <Input
                      type="number"
                      min={100}
                      value={job.payload?.timeout_ms ?? 1000}
                      onChange={(e) =>
                        updateJob(jIdx, "payload", {
                          ...job.payload,
                          timeout_ms: Number(e.target.value),
                        })
                      }
                      className="h-8 text-xs font-mono bg-background"
                    />
                  </div>
                </div>

                {/* Если это ICMP */}
                {job.collector === "icmp" && (
                  <div className="grid grid-cols-2 gap-3 p-3 border rounded bg-background">
                    <div className="space-y-1">
                      <Label className="text-xs">Пакетов в пачке</Label>
                      <Input
                        type="number"
                        min={1}
                        max={10}
                        value={job.payload?.packets ?? 2}
                        onChange={(e) =>
                          updateJob(jIdx, "payload", {
                            ...job.payload,
                            packets: Number(e.target.value),
                          })
                        }
                        className="h-8 text-xs font-mono"
                      />
                    </div>
                  </div>
                )}

                {/* Если это SNMP: Таблица OID */}
                {(job.collector === "snmp" || job.collector === "snmp_bulk") && (
                  <div className="space-y-2 border rounded-md p-3 bg-background">
                    <div className="flex items-center justify-between">
                      <span className="text-xs font-semibold uppercase text-muted-foreground">
                        Опрашиваемые параметры (OID)
                      </span>
                      <Button
                        type="button"
                        variant="secondary"
                        size="sm"
                        className="h-7 text-xs"
                        onClick={() => addOidToJob(jIdx)}
                      >
                        + Добавить OID
                      </Button>
                    </div>

                    <Table>
                      <TableHeader>
                        <TableRow>
                          <TableHead className="w-[200px]">Ключ метрики (Key)</TableHead>
                          <TableHead>SNMP OID (Числовой)</TableHead>
                          <TableHead className="w-[60px]"></TableHead>
                        </TableRow>
                      </TableHeader>
                      <TableBody>
                        {(job.payload?.oids || []).length === 0 ? (
                          <TableRow>
                            <TableCell colSpan={3} className="text-center py-4 text-xs text-muted-foreground">
                              Нет добавленных OID. Нажмите «+ Добавить OID».
                            </TableCell>
                          </TableRow>
                        ) : (
                          (job.payload?.oids || []).map((oidItem, oIdx) => (
                            <TableRow key={oIdx}>
                              <TableCell className="p-2">
                                <Input
                                  value={oidItem.key}
                                  onChange={(e) => updateOidInJob(jIdx, oIdx, "key", e.target.value)}
                                  placeholder="cpu_idle"
                                  className="h-8 text-xs font-mono"
                                />
                              </TableCell>
                              <TableCell className="p-2">
                                <Input
                                  value={oidItem.oid}
                                  onChange={(e) => updateOidInJob(jIdx, oIdx, "oid", e.target.value)}
                                  placeholder="1.3.6.1.4.1.2021.11.11.0"
                                  className="h-8 text-xs font-mono"
                                />
                              </TableCell>
                              <TableCell className="p-2 text-right">
                                <Button
                                  type="button"
                                  variant="ghost"
                                  size="sm"
                                  className="h-8 w-8 p-0 text-muted-foreground hover:text-destructive"
                                  onClick={() => removeOidFromJob(jIdx, oIdx)}
                                >
                                  ✕
                                </Button>
                              </TableCell>
                            </TableRow>
                          ))
                        )}
                      </TableBody>
                    </Table>
                  </div>
                )}
              </CardContent>
            </Card>
          ))}
        </div>
      </fetcher.Form>
    </div>
  );
}