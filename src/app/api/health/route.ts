import { NextResponse } from "next/server";

// ═══════════════════════════════════════════════════════════════
// RCC-HIROS — Liveness probe used by Docker HEALTHCHECK, CI/CD
// deploy verification, and monitoring. No auth, no DB access.
// ═══════════════════════════════════════════════════════════════

export const dynamic = "force-dynamic";

export async function GET() {
  return NextResponse.json({
    status: "ok",
    service: "rcc-hiros",
    timestamp: new Date().toISOString(),
  });
}
