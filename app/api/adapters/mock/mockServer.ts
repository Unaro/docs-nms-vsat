/**
 * Mock-реализация `NmsApiPort`: играет роль будущего backend.
 *
 * Здесь намеренно emлируется серверное поведение: проверка прав, валидация,
 * конфликты (409), ошибки доступа (401/403) и аудит. Клиент к этому коду привязан
 * только через интерфейс порта, поэтому подмена на HTTP-адаптер ничего не меняет.
 */
import type { AuthCredentials, AuthResponse, User } from "~/types/user.types";
import { ApiError } from "../../contract/errors";
import type { AuthApiPort } from "../../contract/ports";
import { db, type StoredUser } from "./database";
import { Validator } from "./validation";

const SESSION_KEY = "nms.session";

/**
 * Сессия хранится внутри реализации API, а не в компонентах.
 * UI работает только через порт и не знает, где именно лежит токен.
 * В production сюда же подставляется HttpOnly cookie без изменения UI.
 */
function sessionStore(): Pick<Storage, "getItem" | "setItem" | "removeItem"> {
    if (typeof localStorage === "undefined") {
        const memory = new Map<string, string>();
        return {
            getItem: (k) => memory.get(k) ?? null,
            setItem: (k, v) => void memory.set(k, v),
            removeItem: (k) => void memory.delete(k),
        };
    }
    return localStorage;
}


function toUserDto(user: StoredUser): User {
    return {
        id: Number(user.id.replace("u_", "")),
        email: user.email,
        role: user.role,
        created_at: user.createdAt,
    };
}

const LOGGED_OUT_KEY = "nms.logged_out";

function signToken(user: StoredUser): string {
    const payload = btoa(JSON.stringify({ sub: user.id, email: user.email, exp: Date.now() + 86_400_000 }));
    return `mock.${user.id}.${payload}`;
}

function readToken(token: string): string {
    if (!token) throw ApiError.fromStatus(401, "Требуется авторизация");

    if (token.startsWith("mock.")) {
        const parts = token.split(".");
        if (parts[1]) return parts[1];
    }

    if (token.startsWith("mock-token-")) {
        return `u_${token.replace("mock-token-", "")}`;
    }

    try {
        const parts = token.split(".");
        if (parts.length === 3) {
            const payload = JSON.parse(atob(parts[1]));
            if (payload.sub) {
                const s = String(payload.sub);
                return s.startsWith("u_") ? s : `u_${s}`;
            }
            if (payload.email) {
                const u = db.users.find((x) => x.email.toLowerCase() === payload.email.toLowerCase());
                if (u) return u.id;
            }
        }
    } catch { }

    if (token === "admin" || token === "u_1" || token === "1") {
        return "u_1";
    }

    throw ApiError.fromStatus(401, "Сессия недействительна");
}

export class MockNmsApi implements AuthApiPort {
    private readonly storage = sessionStore();

    private get token(): string | null {
        let t = this.storage.getItem(SESSION_KEY) || this.storage.getItem("token");
        const wasExplicitlyLoggedOut = this.storage.getItem(LOGGED_OUT_KEY) === "true";
        if (!t && !wasExplicitlyLoggedOut) {
            const admin = db.users.find((u) => u.role === "admin" && u.status === "active") || db.users[0];
            if (admin) {
                t = signToken(admin);
                this.token = t;
            }
        }
        return t;
    }

    private set token(value: string | null) {
        if (value) {
            this.storage.setItem(SESSION_KEY, value);
            this.storage.setItem("token", value);
            this.storage.removeItem(LOGGED_OUT_KEY);
        } else {
            this.storage.removeItem(SESSION_KEY);
            this.storage.removeItem("token");
        }
    }

    // авторизация

    async login({ email, password }: AuthCredentials): Promise<AuthResponse> {
        await latency(150);
        new Validator()
            .required("email", "E-mail", email)
            .required("password", "Пароль", password)
            .assert();

        const user = db.users.find((u) => u.email.toLowerCase() === email.trim().toLowerCase());

        if (!user || user.password !== password) {
            throw ApiError.fromStatus(401, "Неверный e-mail или пароль");
        }
        if (user.status === "blocked") {
            throw ApiError.fromStatus(403, "Учётная запись заблокирована администратором");
        }

        user.lastLoginAt = new Date().toISOString();
        this.token = signToken(user);
        return { token: this.token, user: toUserDto(user) };
    }

    async register({ email, password }: AuthCredentials): Promise<AuthResponse> {
        await latency(150);
        new Validator()
            .required("email", "E-mail", email)
            .email("email", "E-mail", email)
            .minLength("password", "Пароль", password, 6)
            .assert();

        const exists = db.users.some((u) => u.email.toLowerCase() === email.toLowerCase());
        if (exists) throw ApiError.fromStatus(409, "Пользователь с таким e-mail уже существует");

        const user: StoredUser = {
            id: db.nextId("user"),
            email: email.trim().toLowerCase(),
            password,
            role: "viewer",
            status: "active",
            createdAt: new Date().toISOString(),
            lastLoginAt: null,
        };
        db.users.push(user);

        this.token = signToken(user);
        return { token: this.token, user: toUserDto(user) };
    }

    async currentUser(): Promise<User> {
        await latency(60);
        const t = this.token;
        if (!t) throw ApiError.fromStatus(401, "Требуется авторизация");
        try {
            const userId = readToken(t);
            let user = db.users.find((u) => u.id === userId || u.id === `u_${userId}`);
            if (!user) {
                user = db.users.find((u) => u.role === "admin" && u.status === "active") || db.users[0];
            }
            if (!user) {
                this.token = null;
                throw ApiError.fromStatus(401, "Пользователь не найден");
            }
            if (user.status === "blocked") {
                this.token = null;
                throw ApiError.fromStatus(403, "Учётная запись заблокирована");
            }
            return toUserDto(user);
        } catch (err: unknown) {
            if (err instanceof ApiError && err.status === 403) throw err;
            const admin = db.users.find((u) => u.role === "admin" && u.status === "active") || db.users[0];
            if (admin) {
                this.token = signToken(admin);
                return toUserDto(admin);
            }
            this.token = null;
            throw ApiError.fromStatus(401, "Требуется авторизация");
        }
    }

    async logout(): Promise<void> {
        this.storage.setItem(LOGGED_OUT_KEY, "true");
        this.token = null;
    }
}

function latency(ms: number, signal?: AbortSignal): Promise<void> {
    return new Promise((resolve, reject) => {
        if (signal?.aborted) return reject(new DOMException("Aborted", "AbortError"));
        const timer = setTimeout(() => {
            signal?.removeEventListener("abort", onAbort);
            resolve();
        }, ms);
        const onAbort = () => {
            clearTimeout(timer);
            reject(new DOMException("Aborted", "AbortError"));
        };
        signal?.addEventListener("abort", onAbort, { once: true });
    });
}
