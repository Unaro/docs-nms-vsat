/**
 * `NmsApiPort` - единственный контракт, через который SPA общается с сервером.
 *
 * Сейчас его реализует mock-сервер (`adapters/mock`), позже - реальный backend
 * (`adapters/http`). UI, роуты и хуки зависят только от этого интерфейса.
 */
import type { AuthCredentials, AuthResponse, User } from "~/types/user.types";

export interface AuthApiPort {
    login(credentials: AuthCredentials): Promise<AuthResponse>;
    register(credentials: AuthCredentials): Promise<AuthResponse>;
    currentUser(): Promise<User>;
    logout(): Promise<void>;
}

export interface EventHandlers {
    onOpen?: () => void;
    onError?: (error: unknown) => void;
}
