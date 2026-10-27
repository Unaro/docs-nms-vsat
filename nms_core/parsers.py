from typing import Any

def format_mac(raw_val: Any) -> str:
    if isinstance(raw_val, bytes):
        return ":".join(f"{b:02x}" for b in raw_val)
    return str(raw_val)

def format_uptime(timeticks: int) -> str:
    total_seconds = int(timeticks / 100)
    days, rem = divmod(total_seconds, 86400)
    hours, rem = divmod(rem, 3600)
    minutes, _ = divmod(rem, 60)
    parts = []
    if days > 0: parts.append(f"{days}d")
    if hours > 0: parts.append(f"{hours}h")
    parts.append(f"{minutes}m")
    return " ".join(parts) or "< 1m"

def decode_val(val: Any) -> Any:
    if isinstance(val, bytes):
        try:
            return val.decode("utf-8").strip("\x00")
        except UnicodeDecodeError:
            return val.hex()
    return val