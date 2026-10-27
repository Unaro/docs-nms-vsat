import { useEffect, useState } from "react";
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

export interface CredentialOption {
  id: string;
  name: string;
  protocol: string;
}

export interface TemplateOption {
  id: string;
  name: string;
  vendor: string | null;
}

interface AddNodeDialogProps {
  credentials: CredentialOption[];
  templates: TemplateOption[];
}

export function AddNodeDialog({ credentials, templates }: AddNodeDialogProps) {
  const [open, setOpen] = useState(false);
  const fetcher = useFetcher<{ error?: string; success?: boolean }>();
  const isSubmitting = fetcher.state !== "idle";

  useEffect(() => {
    if (fetcher.data?.success) {
      setOpen(false);
    }
  }, [fetcher.data]);

  return (
    <>
      {/* Кнопка открытия без обертки DialogTrigger */}
      <Button onClick={() => setOpen(true)}>+ Добавить устройство</Button>

      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent className="sm:max-w-120">
          <DialogHeader>
            <DialogTitle>Добавление узла мониторинга</DialogTitle>
            <DialogDescription>
              Укажите сетевые реквизиты. Задачи опроса будут созданы автоматически.
            </DialogDescription>
          </DialogHeader>

          <fetcher.Form method="post" className="space-y-4 pt-2">
            <input type="hidden" name="intent" value="create_node" />

            {fetcher.data?.error && (
              <div className="rounded-md bg-destructive/15 p-3 text-sm text-destructive">
                {fetcher.data.error}
              </div>
            )}

            <div className="space-y-2">
              <Label htmlFor="name">Название устройства</Label>
              <Input id="name" name="name" placeholder="Core Switch SW-01" required />
            </div>

            <div className="grid grid-cols-3 gap-3">
              <div className="col-span-2 space-y-2">
                <Label htmlFor="ip_address">IP-адрес</Label>
                <Input
                  id="ip_address"
                  name="ip_address"
                  placeholder="192.168.122.150"
                  pattern="^([0-9]{1,3}\.){3}[0-9]{1,3}$"
                  required
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="custom_port">Порт SNMP</Label>
                <Input id="custom_port" name="custom_port" placeholder="161" type="number" />
              </div>
            </div>

            <div className="space-y-2">
              <Label>Профиль авторизации</Label>
              <Select name="credential_id">
                <SelectTrigger>
                  <SelectValue placeholder="Выберите профиль (SNMP/HTTP)" />
                </SelectTrigger>
                <SelectContent>
                  {credentials.map((cred) => (
                    <SelectItem key={cred.id} value={cred.id}>
                      {cred.name} ({cred.protocol})
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>

            <div className="space-y-2">
              <Label>Шаблон метрик</Label>
              <Select name="template_id">
                <SelectTrigger>
                  <SelectValue placeholder="Выберите шаблон опроса" />
                </SelectTrigger>
                <SelectContent>
                  {templates.map((tpl) => (
                    <SelectItem key={tpl.id} value={tpl.id}>
                      {tpl.name} {tpl.vendor ? `(${tpl.vendor})` : ""}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>

            <DialogFooter className="pt-2">
              <Button type="button" variant="outline" onClick={() => setOpen(false)}>
                Отмена
              </Button>
              <Button type="submit" disabled={isSubmitting}>
                {isSubmitting ? "Сохранение..." : "Создать и запустить опрос"}
              </Button>
            </DialogFooter>
          </fetcher.Form>
        </DialogContent>
      </Dialog>
    </>
  );
}