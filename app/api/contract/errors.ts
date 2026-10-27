/**
 * Типизированные ошибки API.
 *
 * UI никогда не должен зависеть от конкретного текста ошибки: он работает с кодом
 * (`code`) и статусом (`status`), а человекочитаемый текст - это деталь отображения.
 */
export type ApiErrorCode =
    | "unauthorized"
    | "forbidden"
    | "not_found"
    | "conflict"
    | "validation_failed"
    | "network_error"
    | "unknown_error";

export interface ApiErrorPayload {
    status: number;
    code: ApiErrorCode;
    message: string;
    fieldErrors?: Record<string, string>;
}

export const STATUS_TO_CODE: Record<number, ApiErrorCode> = {
    400: "validation_failed",
    401: "unauthorized",
    403: "forbidden",
    404: "not_found",
    409: "conflict",
    422: "validation_failed",
};

export class ApiError extends Error {
    readonly status: number;
    readonly code: ApiErrorCode;
    readonly fieldErrors?: Record<string, string>;

    constructor(payload: ApiErrorPayload) {
        super(payload.message);
        this.name = "ApiError";
        this.status = payload.status;
        this.code = payload.code;
        this.fieldErrors = payload.fieldErrors;
    }

    static fromStatus(status: number, message: string, fieldErrors?: Record<string, string>) {
        return new ApiError({
            status,
            code: STATUS_TO_CODE[status] ?? "unknown_error",
            message,
            fieldErrors,
        });
    }

    static network(message = "Сервер недоступен") {
        return new ApiError({ status: 0, code: "network_error", message });
    }

    get isUnauthorized() {
        return this.code === "unauthorized";
    }

    get isForbidden() {
        return this.code === "forbidden";
    }

    get isValidation() {
        return this.code === "validation_failed";
    }

    static isApiError(value: unknown): value is ApiError {
        return value instanceof ApiError;
    }
}

export function toApiError(value: unknown): ApiError {
    if (ApiError.isApiError(value)) return value;
    if (value instanceof Error) {
        return new ApiError({ status: 0, code: "unknown_error", message: value.message });
    }
    return new ApiError({ status: 0, code: "unknown_error", message: "Непредвиденная ошибка" });
}
