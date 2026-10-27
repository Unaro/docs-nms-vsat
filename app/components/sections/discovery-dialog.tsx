import { useCallback, useState } from "react";
import { useTask } from "~/lib/hooks/use-task";
import { useFetcher, useRevalidator } from "react-router";
import { Button } from "~/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "~/components/ui/dialog";
import { Input } from "~/components/ui/input";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "~/components/ui/table";
import { Badge } from "~/components/ui/badge";

export interface DiscoveredNodeItem {
  id: string;
  ip_address: string;
  hostname: string | null;
  vendor: string | null;
  suggested_template_id: string | null;
  matched_credential_id: string | null;
  discovered_at: string;
}

interface DiscoveryDialogProps {
  discoveredNodes: DiscoveredNodeItem[];
  templates: Array<{ id: string; name: string }>;
  credentials: Array<{ id: string; name: string }>;
}

export function DiscoveryDialog({ discoveredNodes, templates, credentials }: DiscoveryDialogProps) {
  const [open, setOpen] = useState(false);
  const [cidr, setCidr] = useState("192.168.122.0/24");
  const scanFetcher = useFetcher<{ taskId?: string; error?: string }>();
  const approveFetcher = useFetcher<{ error?: string }>();
  const revalidator = useRevalidator();
  const complete = useCallback(() => { void revalidator.revalidate(); }, [revalidator]);
  const task = useTask(scanFetcher.data?.taskId, complete);
  const isScanning = scanFetcher.state !== 'idle' || Boolean(scanFetcher.data?.taskId && !['completed', 'failed', 'timeout', 'cancelled'].includes(task?.status ?? 'pending'));

  const handleStartScan = () => {
    const fd = new FormData();
    fd.append("intent", "run_discovery");
    fd.append("cidr", cidr);
    scanFetcher.submit(fd, { method: "post" });
  };

  const handleApprove = (node: DiscoveredNodeItem) => {
    const fd = new FormData();
    fd.append("intent", "approve_discovered_node");
    fd.append("discovered_id", node.id);
    fd.append("name", node.hostname || `Node-${node.ip_address}`);
    if (node.suggested_template_id) fd.append("template_id", node.suggested_template_id);
    if (node.matched_credential_id) fd.append("credential_id", node.matched_credential_id);
    approveFetcher.submit(fd, { method: "post" });
  };

  return (
    <>
      <Button variant="outline" onClick={() => setOpen(true)}>
        Сетевое обнаружение ({discoveredNodes.length})
      </Button>

        <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent className="sm:max-w-[750px]">
            <DialogHeader>
            <DialogTitle>Автообнаружение сетевых устройств</DialogTitle>
            <DialogDescription>
                Сканирование CIDR-подсети и утверждение устройств в боевой мониторинг.
            </DialogDescription>
            </DialogHeader>

            {/* Scan Bar */}
            <div className="flex items-center gap-3 pt-2">
            <Input
                value={cidr}
                onChange={(e) => setCidr(e.target.value)}
                placeholder="192.168.122.0/24"
                className="font-mono text-sm"
            />
            <Button onClick={handleStartScan} disabled={isScanning}>
                {isScanning ? "Сканирование..." : "Запустить сканирование"}
            </Button>
            </div>

            {(scanFetcher.data?.error || approveFetcher.data?.error || task?.error_message) && <p role="alert" className="text-destructive">{scanFetcher.data?.error || approveFetcher.data?.error || task?.error_message}</p>}
            {task?.status === 'completed' && <p role="status">Сканирование завершено</p>}
            {/* Sandbox List */}
            <div className="border rounded-md mt-4 max-h-[350px] overflow-auto">
            <Table>
                <TableHeader>
                <TableRow>
                    <TableHead>IP-адрес</TableHead>
                    <TableHead>Имя / Hostname</TableHead>
                    <TableHead>Вендор</TableHead>
                    <TableHead>Шаблон</TableHead>
                    <TableHead className="text-right">Действие</TableHead>
                </TableRow>
                </TableHeader>
                <TableBody>
                {discoveredNodes.length === 0 ? (
                    <TableRow>
                    <TableCell colSpan={5} className="text-center py-6 text-muted-foreground text-sm">
                        Песочница пуста. Запустите сканирование подсети.
                    </TableCell>
                    </TableRow>
                ) : (
                    discoveredNodes.map((item) => (
                    <TableRow key={item.id}>
                        <TableCell className="font-mono text-sm">{item.ip_address}</TableCell>
                        <TableCell className="font-medium text-sm">{item.hostname || "—"}</TableCell>
                        <TableCell>
                        <Badge variant="outline">{item.vendor || "Generic"}</Badge>
                        </TableCell>
                        <TableCell className="text-xs text-muted-foreground">
                        {templates.find((t) => t.id === item.suggested_template_id)?.name || "Базовый пинг"}
                        </TableCell>
                        <TableCell className="text-right">
                        <Button
                            size="sm"
                            onClick={() => handleApprove(item)}
                            disabled={approveFetcher.state !== "idle"}
                        >
                            В мониторинг
                        </Button>
                        <Button variant="ghost" size="sm" disabled={approveFetcher.state !== 'idle'} onClick={() => approveFetcher.submit({ intent: 'ignore_discovered_node', discovered_id: item.id }, { method: 'post' })}>Игнорировать</Button>
                        <Button variant="ghost" size="sm" disabled={approveFetcher.state !== 'idle'} onClick={() => approveFetcher.submit({ intent: 'delete_discovered_node', discovered_id: item.id }, { method: 'post' })}>Удалить</Button>
                        </TableCell>
                    </TableRow>
                    ))
                )}
                </TableBody>
            </Table>
            </div>
        </DialogContent>
        </Dialog>
    </>
  );
}