import { createCookieSessionStorage, href, redirect } from "react-router";
import type { AuthCredentials, User, UserRole } from "~/types/user.types";
import { randomBytes } from "node:crypto";

const production = process.env.NODE_ENV === "production";
const secret = process.env.SESSION_SECRET;
if (production && (!secret || secret.length < 32)) throw new Error("SESSION_SECRET must contain at least 32 characters");
const sessions = createCookieSessionStorage<{ token?: string; user?: User }>({
  cookie: { name: "nms_session", httpOnly: true, sameSite: "lax", secure: production, path: "/", maxAge: 86400, secrets: [secret || randomBytes(32).toString("hex")] },
});
const backend = process.env.AUTH_API_BASE_URL;
export const demoAuthEnabled = !production && process.env.AUTH_MODE === "mock";

export function requireSameOrigin(request: Request) {
  const origin = request.headers.get("Origin");
  if (!origin || origin !== new URL(request.url).origin) throw new Response("Недопустимый источник запроса", { status: 403 });
}

async function authRequest(path: string, init: RequestInit = {}) {
  if (!backend) throw new Response("AUTH_API_BASE_URL не настроен", { status: 503 });
  const response = await fetch(`${backend.replace(/\/$/, "")}/api/auth/${path}`, { ...init, signal: AbortSignal.timeout(10000) });
  if (!response.ok) throw new Response("Ошибка авторизации", { status: response.status === 401 || response.status === 403 ? response.status : 502 });
  return response;
}
function validateUser(value: unknown): User {
  const user = value as User;
  if (!user || typeof user.id !== "number" || typeof user.email !== "string" || !["admin", "operator", "viewer"].includes(user.role) || typeof user.created_at !== "string") throw new Response("Некорректный ответ сервиса авторизации", { status: 502 });
  return user;
}
export async function currentUser(request: Request): Promise<User | null> {
  const session = await sessions.getSession(request.headers.get("Cookie"));
  if (demoAuthEnabled) return session.get("user") ?? null;
  const token = session.get("token");
  if (!token) return null;
  try {
    return validateUser(await (await authRequest("me", { headers: { Authorization: `Bearer ${token}` } })).json());
  } catch (error) {
    if (error instanceof Response && [401, 403].includes(error.status)) return null;
    throw error;
  }
}
export async function requireUser(request: Request, roles?: UserRole[]) {
  if (!["GET", "HEAD"].includes(request.method)) requireSameOrigin(request);
  const user = await currentUser(request);
  if (!user) throw redirect(`${href("/login")}?redirectTo=${encodeURIComponent(new URL(request.url).pathname)}`);
  if (roles && !roles.includes(user.role)) throw new Response("Недостаточно прав", { status: 403 });
  return user;
}
export function safeRedirect(request: Request, fallback = href("/profile")) {
  const target = new URL(request.url).searchParams.get("redirectTo");
  if (!target) return fallback;
  const url = new URL(target, request.url);
  return url.origin === new URL(request.url).origin && url.pathname !== href("/login") ? url.pathname + url.search : fallback;
}
export async function authenticate(request: Request, credentials: AuthCredentials, register = false) {
  requireSameOrigin(request);
  if (!credentials.email || !credentials.password) throw new Error("Введите email и пароль");
  let user: User;
  let token: string | undefined;
  if (demoAuthEnabled) {
    const { MockNmsApi } = await import("~/api/adapters/mock/mockServer");
    const api = new MockNmsApi();
    const result = await (register ? api.register(credentials) : api.login(credentials));
    user = result.user;
  } else {
    const result = await (await authRequest(register ? "register" : "login", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(credentials) })).json();
    user = validateUser(result.user);
    token = result.token;
    if (typeof token !== "string" || !token) throw new Response("Сервис не вернул токен", { status: 502 });
  }
  const session = await sessions.getSession();
  if (demoAuthEnabled) session.set("user", user);
  else session.set("token", token);
  return redirect(safeRedirect(request), { headers: { "Set-Cookie": await sessions.commitSession(session) } });
}
export async function logout(request: Request) {
  requireSameOrigin(request);
  const session = await sessions.getSession(request.headers.get("Cookie"));
  return redirect(href("/login"), { headers: { "Set-Cookie": await sessions.destroySession(session) } });
}
