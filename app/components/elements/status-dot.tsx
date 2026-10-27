import { cn } from "~/lib/utils";

export type NodeStatusType = "healthy" | "degraded" | "down" | "unknown" | "offline";

interface StatusDotProps {
  status: NodeStatusType;
  className?: string;
  pingAnimation?: boolean;
}

const statusColorMap: Record<NodeStatusType, { dot: string; ping: string; text: string }> = {
  healthy: {
    dot: "bg-emerald-500",
    ping: "bg-emerald-400",
    text: "Healthy / Online",
  },
  degraded: {
    dot: "bg-amber-500",
    ping: "bg-amber-400",
    text: "Degraded",
  },
  down: {
    dot: "bg-rose-500",
    ping: "bg-rose-400",
    text: "Down / Offline",
  },
  offline: {
    dot: "bg-zinc-500",
    ping: "bg-zinc-400",
    text: "Offline",
  },
  unknown: {
    dot: "bg-zinc-400",
    ping: "bg-zinc-300",
    text: "Unknown",
  },
};

export function StatusDot({ status, className, pingAnimation = true }: StatusDotProps) {
  const config = statusColorMap[status] ?? statusColorMap.unknown;

  return (
    <span className={cn("relative flex h-2.5 w-2.5 items-center justify-center", className)} title={config.text}>
      {pingAnimation && status === "healthy" && (
        <span className={cn("absolute inline-flex h-full w-full animate-ping rounded-full opacity-75", config.ping)} />
      )}
      <span className={cn("relative inline-flex h-2 w-2 rounded-full", config.dot)} />
    </span>
  );
}