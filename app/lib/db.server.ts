import postgres from "postgres";

declare global {
  var __db: postgres.Sql | undefined;
}

const connectionString = process.env.DATABASE_URL;
if (!connectionString) throw new Error("DATABASE_URL is required");

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