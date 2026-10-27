/**
 * Точка подключения API для SPA.
 *
 * По умолчанию используется mock-сервер. Как только появится реальный backend,
 * достаточно задать `VITE_API_MODE=http` и `VITE_API_BASE_URL=...` -
 * код приложения не меняется.
 */
import { MockNmsApi } from "./adapters/mock/mockServer";
import { HttpNmsApi } from "./adapters/http/httpApi";

export type ApiMode = "mock" | "http";

function resolveMode(): ApiMode {
    const mode = import.meta.env?.VITE_API_MODE;
    return mode === "http" ? "http" : "mock";
}

function createApi() {
    if (resolveMode() === "http") {
        const baseUrl = import.meta.env?.VITE_API_BASE_URL ?? "";
        
        if (baseUrl) return new HttpNmsApi({ baseUrl });
        
        console.warn("[api] VITE_API_MODE=http, но VITE_API_BASE_URL не задан - используется mock");
        return new MockNmsApi();
    }
    return new MockNmsApi();
}

export const nmsApi = createApi();

export { ApiError, toApiError } from "./contract/errors";
export type { AuthApiPort, EventHandlers } from "./contract/ports";