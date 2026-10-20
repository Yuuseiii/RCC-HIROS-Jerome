import { PrismaClient } from "../generated/prisma/client";
import { PrismaMariaDb } from "@prisma/adapter-mariadb";

// ═══════════════════════════════════════════════════════════════
// RCC-HIROS — Prisma client singleton
// DB connection comes from DATABASE_URL (see .env.example).
// Falls back to the local XAMPP/MariaDB defaults for dev.
// ═══════════════════════════════════════════════════════════════

const DEFAULT_DATABASE_URL = "mysql://root:@localhost:3306/rcc_hiros";

const databaseUrl = process.env.DATABASE_URL ?? DEFAULT_DATABASE_URL;

/** Build the MariaDB driver adapter from a MySQL connection URL. */
function buildAdapter(url: string) {
  const u = new URL(url);
  return new PrismaMariaDb({
    host: u.hostname,
    port: u.port ? Number(u.port) : 3306,
    user: decodeURIComponent(u.username || "root"),
    password: decodeURIComponent(u.password || ""),
    database: u.pathname.replace(/^\//, "") || "rcc_hiros",
    connectionLimit: 10,
  });
}

const adapter = buildAdapter(databaseUrl);

const globalForPrisma = globalThis as unknown as {
  prisma: PrismaClient | undefined;
};

export const db =
  globalForPrisma.prisma ??
  new PrismaClient({
    adapter,
    log: process.env.NODE_ENV === "development" ? ["error", "warn"] : ["error"],
  });

if (process.env.NODE_ENV !== "production") globalForPrisma.prisma = db;
