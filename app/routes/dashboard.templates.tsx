import { data, Link, useFetcher, type ActionFunctionArgs, type LoaderFunctionArgs } from "react-router";
import type { Route } from "./+types/dashboard.templates";
import { db } from "~/lib/db.server";
import { deleteMetricTemplate } from "~/lib/monitoring/config.server";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "~/components/ui/card";
import { Badge } from "~/components/ui/badge";
import { Button } from "~/components/ui/button";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "~/components/ui/table";

export async function loader({}: LoaderFunctionArgs) {
  const templates = (await db`
    SELECT 
      t.id,
      t.name,
      t.vendor,
      t.sys_object_id_pattern,
      t.jobs_definition,
      COUNT(n.id)::int AS nodes_count
    FROM metric_templates t
    LEFT JOIN monitored_nodes n ON t.id = n.template_id
    GROUP BY t.id
    ORDER BY t.name ASC
  `) as unknown as Array<{
    id: string;
    name: string;
    vendor: string | null;
    sys_object_id_pattern: string | null;
    jobs_definition: any[];
    nodes_count: number;
  }>;

  return { templates };
}

export async function action({ request }: ActionFunctionArgs) {
  const formData = await request.formData();
  const intent = formData.get("intent");

  if (intent === "delete_template") {
    const id = String(formData.get("id") || "");
    try {
      await deleteMetricTemplate(db, id);
      return data({ success: true });
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : "Ошибка при удалении шаблона";
      return data({ error: message }, { status: 400 });
    }
  }

  return data({ error: "Неизвестное действие" }, { status: 400 });
}

export default function TemplatesRoute({ loaderData }: Route.ComponentProps) {
  const deleteFetcher = useFetcher<{ error?: string }>();

  const handleDelete = (id: string, name: string) => {
    if (confirm(`Удалить шаблон "${name}"?`)) {
      const fd = new FormData();
      fd.append("intent", "delete_template");
      fd.append("id", id);
      deleteFetcher.submit(fd, { method: "post" });
    }
  };

  return (
    <div className="container mx-auto p-6 space-y-6">
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4 border-b pb-4">
        <div>
          <div className="flex items-center gap-2 text-sm text-muted-foreground">
            <Link to="/dashboard" className="hover:underline">Инфраструктура</Link>
            <span>/</span>
            <span className="text-foreground">Шаблоны</span>
          </div>
          <h1 className="text-2xl font-bold tracking-tight">Шаблоны сбора метрик</h1>
          <p className="text-sm text-muted-foreground">
            Управление интервалами, составом задач и правилами автообнаружения
          </p>
        </div>

        <div className="flex items-center gap-2">
          <Link to="/dashboard/credentials">
            <Button variant="outline">Профили авторизации</Button>
          </Link>
          <Link to="/dashboard/templates/new">
            <Button>+ Создать шаблон</Button>
          </Link>
        </div>
      </div>

      {deleteFetcher.data?.error && (
        <div className="rounded-md bg-destructive/15 p-4 text-sm text-destructive font-medium">
          {deleteFetcher.data.error}
        </div>
      )}

      <div className="grid gap-6">
        {loaderData.templates.map((tpl) => {
          const tplJobs: any[] = Array.isArray(tpl.jobs_definition) ? tpl.jobs_definition : [];
          return (
            <Card key={tpl.id}>
              <CardHeader className="flex flex-row items-center justify-between pb-2">
                <div>
                  <div className="flex items-center gap-2">
                    <CardTitle className="text-lg">{tpl.name}</CardTitle>
                    <Badge variant="outline">{tpl.vendor || "Generic"}</Badge>
                    <Badge variant="secondary">{tpl.nodes_count} устройств привязано</Badge>
                  </div>
                  <CardDescription className="font-mono text-xs mt-1">
                    ID: {tpl.id} {tpl.sys_object_id_pattern && `| Pattern: ${tpl.sys_object_id_pattern}`}
                  </CardDescription>
                </div>

                <div className="flex items-center gap-2">
                  <Link to={`/dashboard/templates/${tpl.id}`}>
                    <Button variant="outline" size="sm">
                      Редактировать
                    </Button>
                  </Link>
                  <Button
                    variant="ghost"
                    size="sm"
                    className="text-destructive hover:text-destructive"
                    onClick={() => handleDelete(tpl.id, tpl.name)}
                  >
                    Удалить
                  </Button>
                </div>
              </CardHeader>
              <CardContent>
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>Имя задачи</TableHead>
                      <TableHead>Коллектор</TableHead>
                      <TableHead>Интервал</TableHead>
                      <TableHead>Тип</TableHead>
                      <TableHead>Опрашиваемые параметры / OID</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {tplJobs.map((job, idx) => (
                      <TableRow key={idx}>
                        <TableCell className="font-mono text-xs font-semibold">{job.job_name}</TableCell>
                        <TableCell>
                          <Badge variant="outline" className="uppercase text-[10px]">
                            {job.collector}
                          </Badge>
                        </TableCell>
                        <TableCell className="font-mono text-xs">{job.interval} сек</TableCell>
                        <TableCell>
                          {job.is_vital ? (
                            <Badge className="bg-rose-500/10 text-rose-600 border-rose-500/20 text-[10px]">
                              Vital (Gatekeeper)
                            </Badge>
                          ) : (
                            <span className="text-xs text-muted-foreground">Метрика</span>
                          )}
                        </TableCell>
                        <TableCell className="text-xs font-mono text-muted-foreground">
                          {job.collector === "icmp" ? (
                            <span>packets: {job.payload?.packets}, timeout: {job.payload?.timeout_ms}ms</span>
                          ) : (
                            <span>
                              {job.payload?.oids?.map((o: any) => o.key).join(", ") || "IF-MIB Bulk"}
                            </span>
                          )}
                        </TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              </CardContent>
            </Card>
          );
        })}
      </div>
    </div>
  );
}