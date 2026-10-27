import type { Route } from "./+types/api.telemetry.stream";
import { db } from "~/lib/db.server";
import { requireUser } from "~/lib/auth.server";
export async function loader({ request }: Route.LoaderArgs) {
  await requireUser(request);
  let closed = false;
  let timer: ReturnType<typeof setInterval> | undefined;
  const subscriptions: Array<() => Promise<void>> = [];
  let controller: ReadableStreamDefaultController<Uint8Array>;
  const cleanup = async () => {
    if (closed) return;
    closed = true;
    clearInterval(timer);
    request.signal.removeEventListener('abort', abort);
    await Promise.allSettled(subscriptions.map(unlisten => unlisten()));
    try { controller.close(); } catch { /* Stream was cancelled. */ }
  };
  const abort = () => { void cleanup(); };
  const encoder = new TextEncoder();
  const stream = new ReadableStream<Uint8Array>({
    async start(output) {
      controller = output;
      request.signal.addEventListener('abort', abort, { once: true });
      if (request.signal.aborted) { await cleanup(); return; }
      const send = (event: string, value: unknown) => {
        if (closed) return;
        try { output.enqueue(encoder.encode(`event: ${event}\ndata: ${JSON.stringify(value)}\n\n`)); }
        catch { void cleanup(); }
      };
      try {
        for (const [channel, event] of [['node_telemetry_update', 'node_update'], ['discovery_update', 'discovery_update']] as const) {
          const subscription = await db.listen(channel, raw => {
            try { send(event, JSON.parse(raw)); } catch { console.error('Invalid monitoring notification'); }
          });
          if (closed) { await subscription.unlisten(); return; }
          subscriptions.push(subscription.unlisten);
        }
        send('connected', { time: new Date().toISOString() });
        timer = setInterval(() => { if (!closed) { try { output.enqueue(encoder.encode(': ping\n\n')); } catch { void cleanup(); } } }, 15000);
      } catch { await cleanup(); }
    },
    cancel: cleanup,
  });
  return new Response(stream, { headers: { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache, no-transform', 'X-Accel-Buffering': 'no' } });
}
