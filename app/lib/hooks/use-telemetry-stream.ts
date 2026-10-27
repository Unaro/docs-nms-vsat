import { useEffect, useState } from "react";

export interface NodeTelemetryItem {
  id: string;
  name: string;
  ip_address: string;
  status: "healthy" | "degraded" | "down" | "unknown" | "offline";
  latency_ms: number | null;
  metrics: Record<string, any>;
  last_polled_by: string | null;
  updated_at: string | null;
}

export function useTelemetryStream(
  initialNodes: NodeTelemetryItem[],
  onDiscoveryUpdate?: () => void
) {
  const [nodes, setNodes] = useState<NodeTelemetryItem[]>(initialNodes);
  const [isConnected, setIsConnected] = useState<boolean>(false);

  useEffect(() => {
    setNodes(prevNodes => initialNodes.map(node => {
      const previous = prevNodes.find(item => item.id === node.id);
      return previous && Date.parse(previous.updated_at ?? '') > Date.parse(node.updated_at ?? '') ? { ...node, status: previous.status, latency_ms: previous.latency_ms, last_polled_by: previous.last_polled_by, updated_at: previous.updated_at } : node;
    }));
  }, [initialNodes]);

  useEffect(() => {
    let eventSource: EventSource | null = null;
    let closed = false;
    let retryTimer: ReturnType<typeof setTimeout> | undefined;
    let retries = 0;
    let announcedDiscovery = false;

    const connect = () => {
      if (closed || retries >= 5) return;
      eventSource = new EventSource("/api/telemetry/stream");

      eventSource.addEventListener("connected", () => {
        retries = 0;
        setIsConnected(true);
        if (!announcedDiscovery) { announcedDiscovery = true; onDiscoveryUpdate?.(); }
      });

      // Живой статус узлов
      eventSource.addEventListener("node_update", (event: MessageEvent) => {
        try {
          const update = JSON.parse(event.data);
          setNodes((prevNodes) =>
            prevNodes.map((node) => {
              if (node.id !== update.node_id || Date.parse(update.updated_at) < Date.parse(node.updated_at ?? '')) return node;
              return {
                ...node,
                status: update.status,
                latency_ms: update.latency_ms,
                last_polled_by: update.last_polled_by,
                updated_at: update.updated_at,
              };
            })
          );
        } catch (err) {
          console.error("Failed to parse node_update:", err);
        }
      });

      // Сигнал обновления песочницы обнаружения
      eventSource.addEventListener("discovery_update", () => {
        onDiscoveryUpdate?.();
      });

      eventSource.onerror = () => {
        setIsConnected(false);
        eventSource?.close();
        eventSource = null;
        if (!closed && ++retries < 5) retryTimer = setTimeout(connect, Math.min(1000 * 2 ** retries, 15000));
      };
    };

    return () => {
      closed = true;
      clearTimeout(retryTimer);
      eventSource?.close();
      setIsConnected(false);
    };
  }, [onDiscoveryUpdate]);

  return { nodes, isConnected };
}
