/**
 * HTTP-адаптер - рабочая замена mock-сервера на реальный backend.
 *
 * Включается переменной окружения: `VITE_API_MODE=http` и `VITE_API_BASE_URL=https://api.example.com`.
 * Контракт запросов повторяет mock: те же пути, те же коды ошибок (401/403/404/409/422).
 */
import type { AuthCredentials, AuthResponse, User } from "~/types/user.types";
import { ApiError, STATUS_TO_CODE } from "../../contract/errors";
import type { AuthApiPort } from "../../contract/ports";

const SESSION_KEY = "nms.session";

export interface HttpApiOptions {
    baseUrl: string;
    /** Токен хранится в памяти вкладки; позже можно переключить на HttpOnly cookie. */
    storage?: Pick<Storage, "getItem" | "setItem" | "removeItem">;
}

export class HttpNmsApi implements AuthApiPort {
    private baseUrl: string;
    private storage: Pick<Storage, "getItem" | "setItem" | "removeItem">;

    constructor({ baseUrl, storage }: HttpApiOptions) {
        this.baseUrl = baseUrl.replace(/\/$/, "");
        const memory = new Map<string, string>();
        this.storage = storage ?? (typeof window !== "undefined" ? window.localStorage : {
            getItem: (key: string) => memory.get(key) ?? null,
            setItem: (key: string, value: string) => { memory.set(key, value); },
            removeItem: (key: string) => { memory.delete(key); },
        });
    }

    private get token(): string | null {
        return this.storage.getItem(SESSION_KEY);
    }

    private set token(value: string | null) {
        if (value) this.storage.setItem(SESSION_KEY, value);
        else this.storage.removeItem(SESSION_KEY);
    }

    private async request<T>(path: string, init: RequestInit = {}): Promise<T> {
        const headers = new Headers(init.headers);
        headers.set("Accept", "application/json");
        if (init.body) headers.set("Content-Type", "application/json");
        if (this.token) headers.set("Authorization", `Bearer ${this.token}`);

        let response: Response;
        try {
            response = await fetch(`${this.baseUrl}${path}`, { ...init, headers, credentials: "include" });
        } catch (cause) {
            if (cause instanceof DOMException && cause.name === "AbortError") throw cause;
            throw ApiError.network();
        }

        if (response.status === 204) return undefined as T;

        const payload = await response.json().catch(() => null);

        if (!response.ok) {
            if (response.status === 401) this.token = null;
            throw new ApiError({
                status: response.status,
                code: (payload?.code as ApiError["code"]) ?? STATUS_TO_CODE[response.status],
                message: payload?.message ?? response.statusText,
                fieldErrors: payload?.fieldErrors,
            });
        }

        return payload as T;
    }

    /**
     * POST /api/auth/login 
     * 
     * body {
     *     email: string,
     *     password: string,
     * }
     * 
     * @param credentials 
     * @returns 
     *      token: string,
     *      user: {
     *          id: number,
     *          email: string,
     *          role: UserRole,
     *          created_at: string,
     *      }
     * 
     */
    async login(credentials: AuthCredentials): Promise<AuthResponse> {
        const result = await this.request<AuthResponse>("/api/auth/login", {
            method: "POST",
            body: JSON.stringify(credentials),
        });
        this.token = result.token;
        return result;
    }


    /**
     * POST /api/auth/register
     * 
     * body {
     *     email: string,
     *     password: string,
     * }
     * 
     * @param credentials 
     * @returns 
     *      token: string,
     *      user: {
     *          id: number,
     *          email: string,
     *          role: UserRole,
     *          created_at: string,
     *      }
     * 
     */
    async register(credentials: AuthCredentials): Promise<AuthResponse> {
        const result = await this.request<AuthResponse>("/api/auth/register", {
            method: "POST",
            body: JSON.stringify(credentials),
        });
        this.token = result.token;
        return result;
    }

    /**
     * GET /api/auth/me
     *  
     * @returns {
     *      user: {
     *          id: number,
     *          email: string,
     *          role: UserRole,
     *          created_at: string,
     *      }
     * }
     */
    async currentUser(): Promise<User> {
        return this.request<User>("/api/auth/me");
    }

    /**
     * POST /api/auth/logout
     *  
     */
    async logout(): Promise<void> {
        try {
            await this.request<void>("/api/auth/logout", { method: "POST" });
        } finally {
            this.token = null;
        }
    }
}
