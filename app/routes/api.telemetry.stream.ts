import type { Route } from "./+types/api.telemetry.stream";
import { db } from "~/lib/db.server";

export async function loader({ request }: Route.LoaderArgs) {
  let isClosed = false;
  let heartbeatTimer: NodeJS.Timeout | null = null;
  let unlistenTelemetry: (() => Promise<void>) | null = null;
  let unlistenDiscovery: (() => Promise<void>) | null = null;

  const cleanup = async () => {
    if (isClosed) return;
    isClosed = true;

    if (heartbeatTimer) {
      clearInterval(heartbeatTimer);
      heartbeatTimer = null;
    }

    if (unlistenTelemetry) await unlistenTelemetry().catch(() => {});
    if (unlistenDiscovery) await unlistenDiscovery().catch(() => {});
  };

  const stream = new ReadableStream({
    async start(controller) {
      const encoder = new TextEncoder();

      const sendEvent = (event: string, data: any) => {
        if (isClosed) return;
        try {
          const payload = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
          controller.enqueue(encoder.encode(payload));
        } catch {
          cleanup();
        }
      };

      sendEvent("connected", { time: new Date().toISOString() });

      try {
        // 1. Канал телеметрии узлов
        const sub1 = await db.listen("node_telemetry_update", (rawPayload) => {
          try {
            sendEvent("node_update", JSON.parse(rawPayload));
          } catch (e) {
            console.error("Failed to parse telemetry notify:", e);
          }
        });
        unlistenTelemetry = sub1.unlisten;

        // 2. Канал событий автообнаружения
        const sub2 = await db.listen("discovery_update", (rawPayload) => {
          try {
            sendEvent("discovery_update", JSON.parse(rawPayload));
          } catch (e) {
            console.error("Failed to parse discovery notify:", e);
          }
        });
        unlistenDiscovery = sub2.unlisten;
      } catch (err) {
        console.error("Failed to register postgres listeners:", err);
        await cleanup();
        return;
      }

      // Heartbeat каждые 15 сек
      heartbeatTimer = setInterval(() => {
        if (isClosed) return;
        try {
          controller.enqueue(encoder.encode(": ping\n\n"));
        } catch {
          cleanup();
        }
      }, 15000);

      request.signal.addEventListener("abort", () => cleanup());
    },

    async cancel() {
      await cleanup();
    },
  });

  return new Response(stream, {
    headers: {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache, no-transform",
      "Connection": "keep-alive",
      "X-Accel-Buffering": "no",
    },
  });
}