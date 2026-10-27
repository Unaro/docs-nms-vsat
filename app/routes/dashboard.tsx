import { useCallback, useState } from "react";
import { data, Link, useFetcher, useRevalidator, type ActionFunctionArgs, type LoaderFunctionArgs } from "react-router";
import type { Route } from "./+types/dashboard";
import { db } from "~/lib/db.server";
import {
  createMonitoredNode,
  updateMonitoredNode,
  deleteMonitoredNode,
  runDryRunProbe,
  spawnSubnetDiscovery,
  approveDiscoveredNode,
} from "~/lib/monitoring/nodes.server";
import { useTelemetryStream, type NodeTelemetryItem } from "~/lib/hooks/use-telemetry-stream";
import { NodeFormDialog, type NodeFormData } from "~/components/sections/node-form-dialog";
import { StatusDot } from "~/components/elements/status-dot";
import { Badge } from "~/components/ui/badge";
import { Button } from "~/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "~/components/ui/card";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "~/components/ui/table";

export async function loader({}: LoaderFunctionArgs) {
  const [nodes, credentials, templates] = await Promise.all([
    db`
      SELECT 
        n.id,
        n.name,
        host(n.ip_address) AS ip_address,
        n.credential_id,
        n.template_id,
        (n.overrides->>'port')::int AS custom_port,
        COALESCE(s.status, 'unknown') AS status,
        s.latency_ms,
        COALESCE(s.metrics, '{}'::jsonb) AS metrics,
        s.last_polled_by,
        s.updated_at
      FROM monitored_nodes n
      LEFT JOIN node_current_state s ON n.id = s.node_id
      WHERE n.is_enabled = true
      ORDER BY n.name ASC
    ` as unknown as (NodeTelemetryItem & { credential_id?: string; template_id?: string; custom_port?: number })[],

    db`SELECT id, name, protocol FROM credential_profiles ORDER BY name ASC` as unknown as Array<{
      id: string;
      name: string;
      protocol: string;
    }>,

    db`SELECT id, name, vendor FROM metric_templates ORDER BY name ASC` as unknown as Array<{
      id: string;
      name: string;
      vendor: string | null;
    }>,
  ]);

  return {
    initialNodes: nodes,
    credentials,
    templates,
  };
}

export async function action({ request }: ActionFunctionArgs) {
  const formData = await request.formData();
  const intent = formData.get("intent");

  // 1. Dry Run диагностика
  if (intent === "test_connection") {
    const ip = String(formData.get("ip_address") || "");
    const port = Number(formData.get("custom_port") || 161);
    const credId = String(formData.get("credential_id") || "");

    let community = "public";
    if (credId) {
      const [cred] = await db`SELECT params FROM credential_profiles WHERE id = ${credId}`;
      if (cred?.params?.community) community = cred.params.community;
    }

    // Вызов через очередь PostgreSQL
    const probeResult = await runDryRunProbe(db, ip, port, community);
    return data(probeResult);
  }

  // 5. Запуск Discovery
  if (intent === "run_discovery") {
    const cidr = String(formData.get("cidr") || "192.168.122.0/24");
    // Вызов через очередь PostgreSQL
    await spawnSubnetDiscovery(db, cidr);
    return data({ success: true, message: "Сканирование поставлено в очередь" });
  }

  // 2. Создание узла
  if (intent === "create_node") {
    const name = String(formData.get("name") || "").trim();
    const ipAddress = String(formData.get("ip_address") || "").trim();
    const credentialId = String(formData.get("credential_id") || "") || null;
    const templateId = String(formData.get("template_id") || "") || null;
    const portRaw = formData.get("custom_port");
    const customSnmpPort = portRaw ? Number(portRaw) : undefined;

    if (!name || !ipAddress) {
      return data({ error: "Имя и IP-адрес обязательны" }, { status: 400 });
    }

    const generatedId = `${name.toLowerCase().replace(/[^a-z0-9_-]/g, "-")}-${ipAddress.replace(/\./g, "-")}`;
    try {
      await createMonitoredNode(db, {
        id: generatedId,
        name,
        ipAddress,
        credentialId,
        templateId,
        customSnmpPort,
      });
      return data({ success: true });
    } catch (err: any) {
      return data({ error: err.message || "Ошибка при сохранении" }, { status: 500 });
    }
  }

  // 3. Изменение узла
  if (intent === "update_node") {
    const id = String(formData.get("id") || "");
    const name = String(formData.get("name") || "").trim();
    const ipAddress = String(formData.get("ip_address") || "").trim();
    const credentialId = String(formData.get("credential_id") || "") || null;
    const templateId = String(formData.get("template_id") || "") || null;
    const portRaw = formData.get("custom_port");
    const customSnmpPort = portRaw ? Number(portRaw) : undefined;

    try {
      await updateMonitoredNode(db, {
        id,
        name,
        ipAddress,
        credentialId,
        templateId,
        customSnmpPort,
      });
      return data({ success: true });
    } catch (err: any) {
      return data({ error: err.message || "Ошибка обновления" }, { status: 500 });
    }
  }

  // 4. Удаление узла
  if (intent === "delete_node") {
    const id = String(formData.get("id") || "");
    try {
      await deleteMonitoredNode(db, id);
      return data({ success: true });
    } catch (err: any) {
      return data({ error: err.message || "Ошибка при удалении" }, { status: 500 });
    }
  }

  // 6. Утверждение из песочницы
  if (intent === "approve_discovered_node") {
    const discoveredId = String(formData.get("discovered_id") || "");
    const name = String(formData.get("name") || "");
    const templateId = String(formData.get("template_id") || "") || null;
    const credentialId = String(formData.get("credential_id") || "") || null;

    try {
      await approveDiscoveredNode(db, discoveredId, { name, templateId, credentialId });
      return data({ success: true });
    } catch (err: any) {
      return data({ error: err.message || "Ошибка утверждения узла" }, { status: 500 });
    }
  }

  return data({ error: "Неизвестное действие" }, { status: 400 });
}

export default function DashboardRoute({ loaderData }: Route.ComponentProps) {
  const revalidator = useRevalidator();


  const handleDiscoveryUpdate = useCallback(() => {
    revalidator.revalidate();
  }, [revalidator]);


  const { nodes, isConnected } = useTelemetryStream(
    loaderData.initialNodes,
    handleDiscoveryUpdate
  );
  const deleteFetcher = useFetcher();

  // Состояние диалога формы (создание / редактирование)
  const [formDialogOpen, setFormDialogOpen] = useState(false);
  const [editingNode, setEditingNode] = useState<NodeFormData | null>(null);

  const handleOpenCreate = () => {
    setEditingNode(null);
    setFormDialogOpen(true);
  };

  const handleOpenEdit = (node: any) => {
    setEditingNode({
      id: node.id,
      name: node.name,
      ip_address: node.ip_address,
      credential_id: node.credential_id,
      template_id: node.template_id,
      custom_port: node.custom_port,
    });
    setFormDialogOpen(true);
  };

  const handleDelete = (id: string, name: string) => {
    if (confirm(`Удалить узел "${name}" и все связанные задачи опроса?`)) {
      const fd = new FormData();
      fd.append("intent", "delete_node");
      fd.append("id", id);
      deleteFetcher.submit(fd, { method: "post" });
    }
  };

  const totalNodes = nodes.length;
  const healthyNodes = nodes.filter((n) => n.status === "healthy").length;
  const downNodes = nodes.filter((n) => n.status === "down" || n.status === "offline").length;
  const avgLatency =
    nodes.reduce((acc, curr) => acc + (curr.latency_ms ?? 0), 0) /
    (nodes.filter((n) => n.latency_ms !== null).length || 1);

  return (
    <div className="container mx-auto p-6 space-y-6">
      {/* 1. Header Section */}
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4 border-b pb-4">
        <div>
          <h1 className="text-2xl font-bold tracking-tight">Инфраструктура и сеть</h1>
          <p className="text-sm text-muted-foreground">
            Оперативный мониторинг узлов кластера в реальном времени
          </p>
        </div>

        <div className="flex items-center gap-2">
          <Badge variant={isConnected ? "outline" : "destructive"} className="gap-1.5 py-1">
            <span
              className={`h-2 w-2 rounded-full ${
                isConnected ? "bg-emerald-500 animate-pulse" : "bg-rose-500"
              }`}
            />
            {isConnected ? "Live telemetry" : "Connecting..."}
          </Badge>

          <Link to="/dashboard/templates">
            <Button variant="outline">Шаблоны</Button>
          </Link>

          <Link to="/dashboard/credentials">
            <Button variant="outline">Авторизация</Button>
          </Link>

          <Button onClick={handleOpenCreate}>+ Добавить устройство</Button>
        </div>
      </div>

      {/* 2. Overview Cards */}
      <div className="grid gap-4 md:grid-cols-4">
        <Card>
          <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
            <CardTitle className="text-sm font-medium">Всего устройств</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold">{totalNodes}</div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
            <CardTitle className="text-sm font-medium">В сети (Healthy)</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold text-emerald-600 dark:text-emerald-400">
              {healthyNodes}
            </div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
            <CardTitle className="text-sm font-medium">Сбои / Down</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold text-rose-600 dark:text-rose-400">
              {downNodes}
            </div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
            <CardTitle className="text-sm font-medium">Средний RTT</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold">{avgLatency.toFixed(1)} ms</div>
          </CardContent>
        </Card>
      </div>

      {/* 3. Nodes List Table with Actions */}
      <Card>
        <CardHeader>
          <CardTitle>Список узлов</CardTitle>
        </CardHeader>
        <CardContent>
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead className="w-[80px]">Статус</TableHead>
                <TableHead>Имя узла</TableHead>
                <TableHead>IP-адрес</TableHead>
                <TableHead>Задержка (RTT)</TableHead>
                <TableHead>Последний опрос</TableHead>
                <TableHead className="text-right">Управление</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {nodes.map((node) => (
                <TableRow key={node.id}>
                  <TableCell>
                    <div className="flex items-center gap-2">
                      <StatusDot status={node.status} />
                      <span className="capitalize text-xs font-medium">{node.status}</span>
                    </div>
                  </TableCell>
                  <TableCell className="font-medium">
                    <Link
                      to={`/dashboard/nodes/${node.id}`}
                      className="hover:underline text-primary font-semibold"
                    >
                      {node.name}
                    </Link>
                  </TableCell>                  
                  <TableCell className="font-mono text-sm">{node.ip_address}</TableCell>
                  <TableCell>
                    {node.latency_ms !== null ? (
                      <span className="font-mono text-sm">{node.latency_ms} ms</span>
                    ) : (
                      <span className="text-muted-foreground text-xs">—</span>
                    )}
                  </TableCell>
                  <TableCell className="text-xs text-muted-foreground">
                    {node.updated_at ? new Date(node.updated_at).toLocaleTimeString() : "—"}
                  </TableCell>
                  <TableCell className="text-right space-x-2">
                    <Button
                      variant="ghost"
                      size="sm"
                      onClick={() => handleOpenEdit(node)}
                    >
                      Изменить
                    </Button>
                    <Button
                      variant="ghost"
                      size="sm"
                      className="text-destructive hover:text-destructive"
                      onClick={() => handleDelete(node.id, node.name)}
                    >
                      Удалить
                    </Button>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </CardContent>
      </Card>

      {/* Unified Add / Edit Dialog with Dry Run */}
      <NodeFormDialog
        open={formDialogOpen}
        onOpenChange={setFormDialogOpen}
        initialData={editingNode}
        credentials={loaderData.credentials}
        templates={loaderData.templates}
      />
    </div>
  );
}