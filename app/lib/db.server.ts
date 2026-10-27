import postgres from "postgres";

declare global {
  var __db: postgres.Sql | undefined;
}

const connectionString =
  process.env.DATABASE_URL ||
  "postgresql://app_user:AppSecretPass!@192.168.122.100:5432/postgres";

export const db =
  global.__db ??
  postgres(connectionString, {
    max: 5,
    idle_timeout: 20,
    connect_timeout: 5,
  });

if (process.env.NODE_ENV !== "production") {
  global.__db = db;
}