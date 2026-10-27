import type { Route } from "./+types/api.tasks.$id";
import { requireUser } from "~/lib/auth.server";
import { db } from "~/lib/db.server";
export async function loader({ request, params }: Route.LoaderArgs) {
  await requireUser(request, ['admin', 'operator']);
  if (!/^[0-9a-f-]{36}$/i.test(params.id)) throw new Response('Некорректный ID задачи', { status: 400 });
  const [task] = await db`SELECT id, task_type, status, result, error_message, created_at, updated_at FROM adhoc_tasks WHERE id = ${params.id}`;
  if (!task) throw new Response('Задача не найдена', { status: 404 });
  return Response.json(task, { headers: { 'Cache-Control': 'no-store' } });
}
