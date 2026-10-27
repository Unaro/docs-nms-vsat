import { useEffect, useState } from "react";
import { useTask } from "~/lib/hooks/use-task";
import { useFetcher } from "react-router";
import { Button } from "~/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "~/components/ui/dialog";
import { Input } from "~/components/ui/input";
import { Label } from "~/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "~/components/ui/select";
import { Badge } from "~/components/ui/badge";

export interface NodeFormData {
  id?: string;
  name: string;
  ip_address: string;
  credential_id?: string | null;
  template_id?: string | null;
  custom_port?: number;
}

interface NodeFormDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  initialData?: NodeFormData | null;
  credentials: Array<{ id: string; name: string; protocol: string }>;
  templates: Array<{ id: string; name: string; vendor: string | null }>;
}

export function NodeFormDialog({
  open,
  onOpenChange,
  initialData,
  credentials,
  templates,
}: NodeFormDialogProps) {
  const isEdit = Boolean(initialData?.id);
  const formFetcher = useFetcher<{ error?: string; success?: boolean }>();
  const probeFetcher = useFetcher<{ taskId?: string; error?: string }>();
  const probeTask = useTask(probeFetcher.data?.taskId);

  const [ip, setIp] = useState("");
  const [port, setPort] = useState("161");
  const [credId, setCredId] = useState("");

  useEffect(() => {
    if (initialData) {
      setIp(initialData.ip_address || "");
      setPort(String(initialData.custom_port || 161));
      setCredId(initialData.credential_id || "");
    } else {
      setIp("");
      setPort("161");
      setCredId("");
    }
  }, [initialData, open]);

  useEffect(() => {
    if (formFetcher.data?.success) {
      onOpenChange(false);
    }
  }, [formFetcher.data, onOpenChange]);

  const handleDryRun = () => {
    if (!ip) return;
    const formData = new FormData();
    formData.append("intent", "test_connection");
    formData.append("ip_address", ip);
    formData.append("custom_port", port);
    formData.append("credential_id", credId);
    probeFetcher.submit(formData, { method: "post" });
  };

  const isSaving = formFetcher.state !== "idle";
  const isTesting = probeFetcher.state !== "idle" || Boolean(probeFetcher.data?.taskId && !['completed', 'failed', 'timeout', 'cancelled'].includes(probeTask?.status ?? 'pending'));
  const probeData = probeTask?.result as { icmp?: any; snmp?: any } | undefined;

  return (
  <Dialog open={open} onOpenChange={onOpenChange}>
    <DialogContent className="sm:max-w-[520px] max-h-[88vh] flex flex-col p-0 overflow-hidden">
      {/* 1. Зафиксированная шапка */}
      <DialogHeader className="p-6 pb-4 border-b">
        <DialogTitle>{isEdit ? "Редактирование устройства" : "Добавление устройства"}</DialogTitle>
        <DialogDescription>
          {isEdit
            ? "Измените параметры узла. Задачи опроса будут пересчитаны автоматически."
            : "Укажите сетевые параметры и протестируйте связь до сохранения."}
        </DialogDescription>
      </DialogHeader>

      {/* 2. Прокручиваемое тело */}
      {(probeFetcher.data?.error || probeTask?.error_message) && <p role="alert" className="px-6 text-destructive">{probeFetcher.data?.error || probeTask?.error_message}</p>}
      <formFetcher.Form id="node-form" method="post" className="flex-1 overflow-y-auto p-6 space-y-4">
        <input type="hidden" name="intent" value={isEdit ? "update_node" : "create_node"} />
        {isEdit && <input type="hidden" name="id" value={initialData?.id} />}

        {formFetcher.data?.error && (
          <div className="rounded-md bg-destructive/15 p-3 text-sm text-destructive">
            {formFetcher.data.error}
          </div>
        )}

        <div className="space-y-2">
          <Label htmlFor="node_name">Название устройства</Label>
          <Input
            id="node_name"
            name="name"
            defaultValue={initialData?.name}
            placeholder="Core Switch SW-01"
            required
          />
        </div>

        <div className="grid grid-cols-3 gap-3">
          <div className="col-span-2 space-y-2">
            <Label htmlFor="node_ip">IP-адрес</Label>
            <Input
              id="node_ip"
              name="ip_address"
              value={ip}
              onChange={(e) => setIp(e.target.value)}
              placeholder="192.168.122.150"
              pattern="^([0-9]{1,3}\.){3}[0-9]{1,3}$"
              required
            />
          </div>
          <div className="space-y-2">
            <Label htmlFor="node_port">Порт SNMP</Label>
            <Input
              id="node_port"
              name="custom_port"
              value={port}
              onChange={(e) => setPort(e.target.value)}
              type="number"
            />
          </div>
        </div>

        <div className="space-y-2">
          <Label>Профиль авторизации</Label>
          <Select 
            name="credential_id" 
            value={credId} 
            onValueChange={(val) => setCredId(val ?? "")}
          >
            <SelectTrigger>
              <SelectValue placeholder="Выберите профиль (SNMP community / v3)" />
            </SelectTrigger>
            <SelectContent>
              {credentials.map((c) => (
                <SelectItem key={c.id} value={c.id}>
                  {c.name} ({c.protocol})
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>

        <div className="space-y-2">
          <Label>Шаблон метрик</Label>
          <Select name="template_id" defaultValue={initialData?.template_id || ""}>
            <SelectTrigger>
              <SelectValue placeholder="Выберите шаблон опроса" />
            </SelectTrigger>
            <SelectContent>
              {templates.map((t) => (
                <SelectItem key={t.id} value={t.id}>
                  {t.name} {t.vendor ? `(${t.vendor})` : ""}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>

        {/* Dry Run Probe Section */}
        <div className="rounded-lg border bg-muted/40 p-3 space-y-2">
          <div className="flex items-center justify-between">
            <span className="text-xs font-semibold text-muted-foreground uppercase">
              Диагностика подключения
            </span>
            <Button
              type="button"
              variant="secondary"
              size="sm"
              onClick={handleDryRun}
              disabled={!ip || isTesting}
            >
              {isTesting ? "Тестирование..." : "Проверить связь"}
            </Button>
          </div>

          {probeData && (
            <div className="text-xs space-y-1.5 pt-1">
              <div className="flex items-center gap-2">
                <span>ICMP:</span>
                {probeData.icmp?.ok ? (
                  <Badge variant="outline" className="text-emerald-500 border-emerald-500/30">
                    Доступен ({probeData.icmp.rtt_ms} ms)
                  </Badge>
                ) : (
                  <Badge variant="destructive">Недоступен</Badge>
                )}
              </div>
              <div className="flex items-center gap-2">
                <span>SNMP:</span>
                {probeData.snmp?.ok ? (
                  <Badge variant="outline" className="text-emerald-500 border-emerald-500/30">
                    Отвечает ({probeData.snmp.data?.sys_name || "OK"})
                  </Badge>
                ) : (
                  <Badge variant="outline" className="text-amber-500 border-amber-500/30">
                    {probeData.snmp?.error || "Нет ответа"}
                  </Badge>
                )}
              </div>
              {probeData.snmp?.data?.sys_descr && (
                <p className="text-[11px] font-mono text-muted-foreground truncate">
                  {probeData.snmp.data.sys_descr}
                </p>
              )}
            </div>
          )}
        </div>
      </formFetcher.Form>

      {/* 3. Зафиксированный подвал */}
      <DialogFooter className="p-4 border-t bg-muted/10">
        <Button type="button" variant="outline" onClick={() => onOpenChange(false)}>
          Отмена
        </Button>
        <Button type="submit" form="node-form" disabled={isSaving}>
          {isSaving ? "Сохранение..." : isEdit ? "Сохранить изменения" : "Создать узел"}
        </Button>
      </DialogFooter>
    </DialogContent>
  </Dialog>
);
}