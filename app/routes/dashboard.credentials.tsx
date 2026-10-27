import { useState } from "react";
import { data, Link, useFetcher, type ActionFunctionArgs, type LoaderFunctionArgs } from "react-router";
import type { Route } from "./+types/dashboard.credentials";
import { db } from "~/lib/db.server";
import { requireUser } from "~/lib/auth.server";
import { mutationError } from "~/lib/monitoring/validation.server";
import {
  createCredentialProfile,
  updateCredentialProfile,
  deleteCredentialProfile,
  type CredentialProfileData,
} from "~/lib/monitoring/config.server";
import { Badge } from "~/components/ui/badge";
import { Button } from "~/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "~/components/ui/card";
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
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "~/components/ui/table";

export async function loader({ request }: LoaderFunctionArgs) {
  await requireUser(request, ['admin']);
  const credentials = (await db`
    SELECT 
      c.id,
      c.name,
      c.protocol,
      '{}'::jsonb AS params,
      c.created_at,
      COUNT(n.id)::int AS nodes_count
    FROM credential_profiles c
    LEFT JOIN monitored_nodes n ON c.id = n.credential_id
    GROUP BY c.id
    ORDER BY c.name ASC
  `) as unknown as Array<{
    id: string;
    name: string;
    protocol: "snmp_v2c" | "snmp_v3" | "http";
    params: Record<string, any>;
    nodes_count: number;
  }>;

  return { credentials };
}

export async function action({ request }: ActionFunctionArgs) {
  await requireUser(request, ['admin']);
  const formData = await request.formData();
  const intent = formData.get("intent");

  if (intent === "create_credential" || intent === "update_credential") {
    const id = String(formData.get("id") || "").trim();
    const name = String(formData.get("name") || "").trim();
    const protocol = formData.get("protocol") as "snmp_v2c" | "snmp_v3" | "http";

    if (!id || !name || !protocol) {
      return data({ error: "Заполните обязательные поля" }, { status: 400 });
    }

    let params: Record<string, any> = {};
    if (protocol === "snmp_v2c") {
      params = {
        community: String(formData.get("v2c_community") || "").trim(),
      };
    } else if (protocol === "snmp_v3") {
      params = {
        username: String(formData.get("v3_username") || "").trim(),
        auth_protocol: String(formData.get("v3_auth_protocol") || "SHA"),
        auth_key: String(formData.get("v3_auth_key") || ""),
        priv_protocol: String(formData.get("v3_priv_protocol") || "AES"),
        priv_key: String(formData.get("v3_priv_key") || ""),
      };
    }

    try {
      if (intent === "create_credential") {
        await createCredentialProfile(db, { id, name, protocol, params });
      } else {
        await updateCredentialProfile(db, { id, name, protocol, params });
      }
      return data({ success: true });
    } catch (err: any) {
      return mutationError(err);
    }
  }

  if (intent === "delete_credential") {
    const id = String(formData.get("id") || "");
    try {
      await deleteCredentialProfile(db, id);
      return data({ success: true });
    } catch (err: any) {
      return mutationError(err);
    }
  }

  return data({ error: "Неизвестное действие" }, { status: 400 });
}

export default function CredentialsRoute({ loaderData }: Route.ComponentProps) {
  const [dialogOpen, setDialogOpen] = useState(false);
  const [editingItem, setEditingItem] = useState<CredentialProfileData | null>(null);
  const [protocol, setProtocol] = useState<"snmp_v2c" | "snmp_v3" | "http">("snmp_v2c");

  const formFetcher = useFetcher<{ error?: string; success?: boolean }>();
  const deleteFetcher = useFetcher<{ error?: string }>();

  const handleOpenCreate = () => {
    setEditingItem(null);
    setProtocol("snmp_v2c");
    setDialogOpen(true);
  };

  const handleOpenEdit = (item: any) => {
    setEditingItem(item);
    setProtocol(item.protocol);
    setDialogOpen(true);
  };

  const handleDelete = (id: string, name: string) => {
    if (confirm(`Удалить профиль "${name}"?`)) {
      const fd = new FormData();
      fd.append("intent", "delete_credential");
      fd.append("id", id);
      deleteFetcher.submit(fd, { method: "post" });
    }
  };

  return (
    <div className="container mx-auto p-6 space-y-6">
      {/* 1. Header */}
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4 border-b pb-4">
        <div>
          <div className="flex items-center gap-2 text-sm text-muted-foreground">
            <Link to="/dashboard" className="hover:underline">Инфраструктура</Link>
            <span>/</span>
            <span className="text-foreground">Безопасность</span>
          </div>
          <h1 className="text-2xl font-bold tracking-tight">Профили авторизации</h1>
          <p className="text-sm text-muted-foreground">
            Профили SNMPv2c для доступа к устройствам
          </p>
        </div>

        <div className="flex items-center gap-2">
          <Link to="/dashboard/templates">
            <Button variant="outline">Шаблоны метрик</Button>
          </Link>
          <Button onClick={handleOpenCreate}>+ Создать профиль</Button>
        </div>
      </div>

      {deleteFetcher.data?.error && (
        <div className="rounded-md bg-destructive/15 p-3 text-sm text-destructive">
          {deleteFetcher.data.error}
        </div>
      )}

      {/* 2. Credentials Table */}
      <Card>
        <CardHeader>
          <CardTitle>Список учетных записей</CardTitle>
          <CardDescription>
            Профили используются задачами опроса и скриптами сетевого обнаружения
          </CardDescription>
        </CardHeader>
        <CardContent>
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Идентификатор</TableHead>
                <TableHead>Название</TableHead>
                <TableHead>Протокол</TableHead>
                <TableHead>Параметры безопасности</TableHead>
                <TableHead>Привязано узлов</TableHead>
                <TableHead className="text-right">Управление</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {loaderData.credentials.map((cred) => (
                <TableRow key={cred.id}>
                  <TableCell className="font-mono text-xs font-semibold">{cred.id}</TableCell>
                  <TableCell className="font-medium">{cred.name}</TableCell>
                  <TableCell>
                    <Badge variant="outline" className="uppercase text-xs font-mono">
                      {cred.protocol}
                    </Badge>
                  </TableCell>
                  <TableCell className="font-mono text-xs text-muted-foreground">
                    {cred.protocol === "snmp_v2c" ? (
                      <span>Секрет сохранен</span>
                    ) : cred.protocol === "snmp_v3" ? (
                      <span>
                        User: <strong className="text-foreground">{cred.params?.username}</strong> | {cred.params?.auth_protocol}+{cred.params?.priv_protocol}
                      </span>
                    ) : (
                      <span>HTTP Params</span>
                    )}
                  </TableCell>
                  <TableCell>
                    <Badge variant="secondary">{cred.nodes_count} узлов</Badge>
                  </TableCell>
                  <TableCell className="text-right space-x-2">
                    <Button variant="ghost" size="sm" onClick={() => handleOpenEdit(cred)}>
                      Изменить
                    </Button>
                    <Button
                      variant="ghost"
                      size="sm"
                      className="text-destructive hover:text-destructive"
                      onClick={() => handleDelete(cred.id, cred.name)}
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

      {/* 3. Modal Dialog */}
      <Dialog open={dialogOpen} onOpenChange={setDialogOpen}>
        <DialogContent className="sm:max-w-[500px]">
          <DialogHeader>
            <DialogTitle>
              {editingItem ? "Редактирование профиля" : "Новый профиль авторизации"}
            </DialogTitle>
            <DialogDescription>
              Настройка реквизитов доступа к сетевым узлам
            </DialogDescription>
          </DialogHeader>

          <formFetcher.Form method="post" className="space-y-4 pt-2">
            <input
              type="hidden"
              name="intent"
              value={editingItem ? "update_credential" : "create_credential"}
            />

            {formFetcher.data?.error && (
              <div className="rounded-md bg-destructive/15 p-3 text-sm text-destructive">
                {formFetcher.data.error}
              </div>
            )}

            <div className="grid grid-cols-2 gap-3">
              <div className="space-y-2">
                <Label htmlFor="cred_id">Идентификатор (ID)</Label>
                <Input
                  id="cred_id"
                  name="id"
                  defaultValue={editingItem?.id}
                  readOnly={Boolean(editingItem)}
                  placeholder="cred-snmp-core"
                  required
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="cred_name">Название</Label>
                <Input
                  id="cred_name"
                  name="name"
                  defaultValue={editingItem?.name}
                  placeholder="Core Routers v2c"
                  required
                />
              </div>
            </div>

            <div className="space-y-2">
              <Label>Протокол</Label>
              <Select
                name="protocol"
                value={protocol}
                onValueChange={(val) => setProtocol((val ?? "snmp_v2c") as any)}
              >
                <SelectTrigger>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="snmp_v2c">SNMPv2c (Community)</SelectItem>

                </SelectContent>
              </Select>
            </div>

            {/* Параметры SNMPv2c */}
            {protocol === "snmp_v2c" && (
              <div className="space-y-2 border-t pt-3">
                <Label htmlFor="v2c_community">SNMP Community String</Label>
                <Input
                  id="v2c_community"
                  name="v2c_community"
                  type="password"
                  defaultValue=""
                  placeholder={editingItem ? 'Оставьте пустым, чтобы сохранить секрет' : 'Community'}
                  required={!editingItem}
                />
              </div>
            )}

            {/* Параметры SNMPv3 */}
            {protocol === "snmp_v3" && (
              <div className="space-y-3 border-t pt-3">
                <div className="space-y-2">
                  <Label htmlFor="v3_username">Security Name / Username</Label>
                  <Input
                    id="v3_username"
                    name="v3_username"
                    defaultValue=""
                    placeholder="snmpadmin"
                    required
                  />
                </div>

                <div className="grid grid-cols-2 gap-3">
                  <div className="space-y-2">
                    <Label>Аутентификация (Auth)</Label>
                    <Select
                      name="v3_auth_protocol"
                      defaultValue={editingItem?.params?.auth_protocol || "SHA"}
                    >
                      <SelectTrigger>
                        <SelectValue />
                      </SelectTrigger>
                      <SelectContent>
                        <SelectItem value="SHA">SHA</SelectItem>
                        <SelectItem value="MD5">MD5</SelectItem>
                      </SelectContent>
                    </Select>
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="v3_auth_key">Ключ Auth</Label>
                    <Input
                      id="v3_auth_key"
                      name="v3_auth_key"
                      type="password"
                      defaultValue=""
                      placeholder="AuthSecretKey"
                    />
                  </div>
                </div>

                <div className="grid grid-cols-2 gap-3">
                  <div className="space-y-2">
                    <Label>Шифрование (Priv)</Label>
                    <Select
                      name="v3_priv_protocol"
                      defaultValue={editingItem?.params?.priv_protocol || "AES"}
                    >
                      <SelectTrigger>
                        <SelectValue />
                      </SelectTrigger>
                      <SelectContent>
                        <SelectItem value="AES">AES-128</SelectItem>
                        <SelectItem value="DES">DES</SelectItem>
                      </SelectContent>
                    </Select>
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="v3_priv_key">Ключ Priv</Label>
                    <Input
                      id="v3_priv_key"
                      name="v3_priv_key"
                      type="password"
                      defaultValue=""
                      placeholder="PrivSecretKey"
                    />
                  </div>
                </div>
              </div>
            )}

            <DialogFooter className="pt-4">
              <Button type="button" variant="outline" onClick={() => setDialogOpen(false)}>
                Отмена
              </Button>
              <Button type="submit">
                {editingItem ? "Сохранить изменения" : "Создать профиль"}
              </Button>
            </DialogFooter>
          </formFetcher.Form>
        </DialogContent>
      </Dialog>
    </div>
  );
}