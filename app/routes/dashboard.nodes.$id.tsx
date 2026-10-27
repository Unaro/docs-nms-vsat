import { useCallback } from "react";
import { useTask } from "~/lib/hooks/use-task";
import { data, Link, useFetcher, useRevalidator, type ActionFunctionArgs, type LoaderFunctionArgs } from "react-router";
import type { Route } from "./+types/dashboard.nodes.$id";
import { db } from "~/lib/db.server";
import { requireUser } from "~/lib/auth.server";
import { mutationError } from "~/lib/monitoring/validation.server";
import { inspectAndSaveNode } from "~/lib/monitoring/nodes.server";
import { StatusDot, type NodeStatusType } from "~/components/elements/status-dot";
import { Badge } from "~/components/ui/badge";
import { Button } from "~/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "~/components/ui/card";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "~/components/ui/table";

export async function loader({ params, request }: LoaderFunctionArgs) {
  await requireUser(request);
  const nodeId = params.id;
  if (!nodeId) throw new Response("Node ID required", { status: 400 });

  const [node] = await db`
    SELECT 
      n.id,
      n.name,
      host(n.ip_address) AS ip_address,
      (n.overrides->>'port')::int AS custom_port,
      n.template_id,
      t.name AS template_name,
      c.name AS cred_name,
      c.protocol AS cred_protocol,
      COALESCE(s.status, 'unknown') AS status,
      s.latency_ms,
      COALESCE(s.metrics, '{}'::jsonb) AS metrics,
      s.error_message,
      s.last_polled_by,
      s.updated_at
    FROM monitored_nodes n
    LEFT JOIN metric_templates t ON n.template_id = t.id
    LEFT JOIN credential_profiles c ON n.credential_id = c.id
    LEFT JOIN node_current_state s ON n.id = s.node_id
    WHERE n.id = ${nodeId}
  `;

  if (!node) {
    throw new Response("Устройство не найдено", { status: 404 });
  }

  return { node };
}

export async function action({ params, request }: ActionFunctionArgs) {
  await requireUser(request, ['admin', 'operator']);
  const nodeId = params.id;
  if (!nodeId) return data({ error: "Missing node ID" }, { status: 400 });

  const formData = await request.formData();
  const intent = formData.get("intent");

  if (intent === "inspect_now") {
    try {
      return data(await inspectAndSaveNode(db, nodeId), { status: 202 });
    } catch (err: any) {
      return mutationError(err);
    }
  }

  return data({ error: "Unknown intent" }, { status: 400 });
}

export default function NodeDetailRoute({ loaderData }: Route.ComponentProps) {
  const { node } = loaderData;
  const fetcher = useFetcher<{ error?: string; taskId?: string }>();
  const revalidator = useRevalidator();
  const onComplete = useCallback(() => { void revalidator.revalidate(); }, [revalidator]);
  const task = useTask(fetcher.data?.taskId, onComplete);
  const isRefreshing = fetcher.state !== "idle" || Boolean(fetcher.data?.taskId && !['completed', 'failed', 'timeout', 'cancelled'].includes(task?.status ?? 'pending'));

  const metrics = node.metrics || {};
  const sys = metrics.system || {};
  const hw = metrics.hardware || {};
  const interfaces: any[] = metrics.interfaces || [];

  return (
    <div className="container mx-auto p-6 space-y-6">
      {/* 1. Header with Breadcrumb and Actions */}
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4 border-b pb-4">
        <div className="space-y-1">
          <div className="flex items-center gap-2 text-sm text-muted-foreground">
            <Link to="/dashboard" className="hover:underline">
              Инфраструктура
            </Link>
            <span>/</span>
            <span className="font-mono text-foreground">{node.ip_address}</span>
          </div>
          <div className="flex items-center gap-3">
            <StatusDot status={node.status as NodeStatusType} className="h-3.5 w-3.5" />
            <h1 className="text-2xl font-bold tracking-tight">{node.name}</h1>
            <Badge variant="outline" className="font-mono text-xs">
              {node.ip_address}:{node.custom_port || 161}
            </Badge>
          </div>
        </div>

        <div className="flex items-center gap-3">
          <fetcher.Form method="post">
            <input type="hidden" name="intent" value="inspect_now" />
            <Button type="submit" disabled={isRefreshing}>
              {isRefreshing ? "Опрос устройства..." : "Снять параметры сейчас"}
            </Button>
          </fetcher.Form>
        </div>
      </div>

      {fetcher.data?.error && (
        <div className="rounded-md bg-destructive/15 p-3 text-sm text-destructive">
          {fetcher.data.error}
        </div>
      )}

      {task?.error_message && <p role="alert" className="text-destructive">{task.error_message}</p>}
      {task?.status === 'completed' && <p role="status">Опрос завершен</p>}
      {/* 2. Top Summary & Hardware Cards */}
      <div className="grid gap-4 md:grid-cols-3">
        {/* Card: Availability */}
        <Card>
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium">Сетевой отклик</CardTitle>
          </CardHeader>
          <CardContent className="space-y-1">
            <div className="text-2xl font-bold font-mono">
              {node.latency_ms !== null ? `${node.latency_ms} ms` : "—"}
            </div>
            <p className="text-xs text-muted-foreground">
              Статус: <span className="capitalize font-medium text-foreground">{node.status}</span>
            </p>
          </CardContent>
        </Card>

        {/* Card: CPU Load */}
        <Card>
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium">Загрузка CPU</CardTitle>
          </CardHeader>
          <CardContent className="space-y-2">
            <div className="text-2xl font-bold font-mono">
              {hw.cpu_percent !== null && hw.cpu_percent !== undefined ? `${hw.cpu_percent}%` : "—"}
            </div>
            {hw.cpu_percent !== null && hw.cpu_percent !== undefined && (
              <div className="w-full bg-secondary h-2 rounded-full overflow-hidden">
                <div
                  className="bg-primary h-full transition-all"
                  style={{ width: `${Math.min(100, hw.cpu_percent)}%` }}
                />
              </div>
            )}
          </CardContent>
        </Card>

        {/* Card: RAM Usage */}
        <Card>
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium">Оперативная память</CardTitle>
          </CardHeader>
          <CardContent className="space-y-2">
            <div className="text-2xl font-bold font-mono">
              {hw.ram_percent ? `${hw.ram_percent}%` : "—"}
            </div>
            {hw.ram_total_mb && (
              <p className="text-xs text-muted-foreground">
                {hw.ram_used_mb} MB из {hw.ram_total_mb} MB
              </p>
            )}
            {hw.ram_percent && (
              <div className="w-full bg-secondary h-2 rounded-full overflow-hidden">
                <div
                  className="bg-emerald-500 h-full transition-all"
                  style={{ width: `${Math.min(100, hw.ram_percent)}%` }}
                />
              </div>
            )}
          </CardContent>
        </Card>
      </div>

      {/* 3. System Identity Card */}
      <Card>
        <CardHeader>
          <CardTitle>Системные параметры (MIB-II)</CardTitle>
          <CardDescription>Идентификация оборудования и программного обеспечения</CardDescription>
        </CardHeader>
        <CardContent>
          <div className="grid grid-cols-1 md:grid-cols-2 gap-4 text-sm">
            <div>
              <span className="text-muted-foreground block text-xs">Описание системы (sysDescr):</span>
              <p className="font-mono text-xs bg-muted/50 p-2 rounded mt-1 break-all">
                {sys.descr || "Параметры еще не сняты. Нажмите «Снять параметры сейчас»."}
              </p>
            </div>
            <div className="space-y-3">
              <div>
                <span className="text-muted-foreground block text-xs">Имя хоста (sysName):</span>
                <span className="font-medium font-mono">{sys.name || node.name}</span>
              </div>
              <div>
                <span className="text-muted-foreground block text-xs">Время непрерывной работы (Uptime):</span>
                <span className="font-mono font-medium">{sys.uptime_str || "—"}</span>
              </div>
              <div className="grid grid-cols-2 gap-2">
                <div>
                  <span className="text-muted-foreground block text-xs">Локация (sysLocation):</span>
                  <span>{sys.location || "—"}</span>
                </div>
                <div>
                  <span className="text-muted-foreground block text-xs">Контакты (sysContact):</span>
                  <span>{sys.contact || "—"}</span>
                </div>
              </div>
              <div>
                <span className="text-muted-foreground block text-xs">Идентификатор объекта (sysObjectID):</span>
                <span className="font-mono text-xs text-muted-foreground">{sys.object_id || "—"}</span>
              </div>
            </div>
          </div>
        </CardContent>
      </Card>

      {/* 4. Network Interfaces Table */}
      <Card>
        <CardHeader>
          <CardTitle>Сетевые интерфейсы ({interfaces.length})</CardTitle>
          <CardDescription>Таблица портов и сетевых адаптеров устройства (IF-MIB)</CardDescription>
        </CardHeader>
        <CardContent>
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead className="w-[70px]">Линк</TableHead>
                <TableHead>Имя интерфейса</TableHead>
                <TableHead>MAC-адрес</TableHead>
                <TableHead>Скорость</TableHead>
                <TableHead className="text-right">Входящий трафик (Rx)</TableHead>
                <TableHead className="text-right">Исходящий трафик (Tx)</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {interfaces.length === 0 ? (
                <TableRow>
                  <TableCell colSpan={6} className="text-center py-6 text-muted-foreground text-sm">
                    Список интерфейсов пуст. Выполните опрос параметров устройства.
                  </TableCell>
                </TableRow>
              ) : (
                interfaces.map((iface) => (
                  <TableRow key={iface.index}>
                    <TableCell>
                      <div className="flex items-center gap-1.5">
                        <span
                          className={`h-2.5 w-2.5 rounded-full ${
                            iface.oper_status === "up" ? "bg-emerald-500" : "bg-zinc-400"
                          }`}
                        />
                        <span className="text-xs uppercase font-medium">{iface.oper_status}</span>
                      </div>
                    </TableCell>
                    <TableCell className="font-medium font-mono text-sm">{iface.name}</TableCell>
                    <TableCell className="font-mono text-xs text-muted-foreground">
                      {iface.mac || "—"}
                    </TableCell>
                    <TableCell className="text-xs font-mono">
                      {iface.speed_mbps ? `${iface.speed_mbps} Mbps` : "—"}
                    </TableCell>
                    <TableCell className="text-right font-mono text-xs">
                      {iface.in_octets ? `${(iface.in_octets / 1_000_000).toFixed(2)} MB` : "0"}
                    </TableCell>
                    <TableCell className="text-right font-mono text-xs">
                      {iface.out_octets ? `${(iface.out_octets / 1_000_000).toFixed(2)} MB` : "0"}
                    </TableCell>
                  </TableRow>
                ))
              )}
            </TableBody>
          </Table>
        </CardContent>
      </Card>
    </div>
  );
}