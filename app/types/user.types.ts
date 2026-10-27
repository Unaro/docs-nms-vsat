export type UserRole = 'admin' | 'operator' | 'viewer'

export interface User {
    id: number
    email: string
    role: UserRole
    created_at: string
}

export interface AuthResponse {
    token: string
    user: User
}

export interface AuthCredentials {
    email: string
    password: string
}