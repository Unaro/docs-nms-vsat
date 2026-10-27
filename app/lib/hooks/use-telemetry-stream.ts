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
    setNodes((prevNodes) => {
      const prevMap = new Map(prevNodes.map((n) => [n.id, n]));
      return initialNodes.map((newNode) => {
        const prev = prevMap.get(newNode.id);
        if (!prev) return newNode;
        return {
          ...newNode,
          status: prev.status !== "unknown" ? prev.status : newNode.status,
          latency_ms: prev.latency_ms ?? newNode.latency_ms,
          last_polled_by: prev.last_polled_by ?? newNode.last_polled_by,
          updated_at: prev.updated_at ?? newNode.updated_at,
        };
      });
    });
  }, [initialNodes]);

  useEffect(() => {
    const eventSource = new EventSource("/api/telemetry/stream");

    eventSource.addEventListener("connected", () => {
      setIsConnected(true);
    });

    // Живой статус узлов
    eventSource.addEventListener("node_update", (event: MessageEvent) => {
      try {
        const update = JSON.parse(event.data);
        setNodes((prevNodes) =>
          prevNodes.map((node) => {
            if (node.id !== update.node_id) return node;
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
    };

    return () => {
      eventSource.close();
      setIsConnected(false);
    };
  }, [onDiscoveryUpdate]);

  return { nodes, isConnected };
}