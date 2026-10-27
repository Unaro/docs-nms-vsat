/** Изменяемое хранилище mock-сервера: пользователи, устройства, тревоги, аудит, база данных. */
import type { UserRole } from "~/types/user.types";

export interface StoredUser {
    id: string;
    email: string;
    password: string;
    role: UserRole;
    status: "active" | "blocked";
    createdAt: string;
    lastLoginAt: string | null;
}

const daysAgo = (n: number) => new Date(Date.now() - n * 86_400_000).toISOString();

function seedUsers(): StoredUser[] {
    return [
        {
            id: "u_1",
            email: "admin@example.com",
            password: "123456",
            role: "admin",
            status: "active",
            createdAt: daysAgo(240),
            lastLoginAt: daysAgo(0),
        },
        {
            id: "u_2",
            email: "operator@example.com",
            password: "123456",
            role: "operator",
            status: "active",
            createdAt: daysAgo(120),
            lastLoginAt: daysAgo(1),
        },
        {
            id: "u_3",
            email: "viewer@example.com",
            password: "123456",
            role: "viewer",
            status: "active",
            createdAt: daysAgo(45),
            lastLoginAt: daysAgo(3),
        },
        {
            id: "u_4",
            email: "engineer@example.com",
            password: "123456",
            role: "operator",
            status: "blocked",
            createdAt: daysAgo(90),
            lastLoginAt: daysAgo(30),
        },
    ];
}

export class MockDatabase {
    users = seedUsers();
    private seq = { user: 1};

    nextId(kind: keyof typeof this.seq): string {
        const prefix = { user: "u"}[kind];
        return `${prefix}_${this.seq[kind]++}`;
    }

    updateUser(id: string, partial: Partial<Omit<StoredUser, 'id' | 'createdAt'>>): StoredUser | undefined {
        const index = this.users.findIndex((u) => u.id === id);
        if (index === -1) return undefined;
        this.users[index] = { ...this.users[index], ...partial };
        return this.users[index];
    }

    reset(): void {
        this.users = seedUsers();
        this.seq = { user: 1 };
    }
}

export const db = new MockDatabase();
