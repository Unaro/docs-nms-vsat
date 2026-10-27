/** Валидация на стороне mock-сервера: контракт 422 + `fieldErrors`. */
import { ApiError } from "../../contract/errors";

export const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

export class Validator {
    private errors: Record<string, string> = {};

    required(field: string, label: string, value: unknown): this {
        if (value === undefined || value === null || String(value).trim() === "") {
            this.errors[field] = `${label} - обязательное поле`;
        }
        return this;
    }

    email(field: string, label: string, value: string): this {
        if (!EMAIL_RE.test(value.trim())) this.errors[field] = `${label}: неверный формат e-mail`;
        return this;
    }

    minLength(field: string, label: string, value: string, min: number): this {
        if (value.trim().length < min) this.errors[field] = `${label}: минимум ${min} символов`;
        return this;
    }

    add(field: string, message: string): this {
        this.errors[field] = message;
        return this;
    }

    get isEmpty(): boolean {
        return Object.keys(this.errors).length === 0;
    }

    /** Выбрасывает 422, если накоплены ошибки. */
    assert(): void {
        if (!this.isEmpty) {
            throw new ApiError({
                status: 422,
                code: "validation_failed",
                message: "Проверьте правильность заполнения полей",
                fieldErrors: this.errors,
            });
        }
    }

    result(): Record<string, string> {
        return { ...this.errors };
    }
}
