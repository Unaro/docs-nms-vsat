import asyncio
import re
import time
from typing import Any, Dict

class IcmpCollector:
    @staticmethod
    async def ping(host: str, packets: int = 2, timeout_ms: int = 1000) -> Dict[str, Any]:
        timeout_sec = str(max(1, int(timeout_ms / 1000)))
        cmd = ["ping", "-c", str(packets), "-W", timeout_sec, "-q", host]
        t0 = time.perf_counter()
        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
            )
            stdout, _ = await proc.communicate()
            elapsed_ms = int((time.perf_counter() - t0) * 1000)
            if proc.returncode == 0:
                match = re.search(r"=\s*[\d\.]+/([\d\.]+)/", stdout.decode())
                avg_rtt = float(match.group(1)) if match else float(elapsed_ms)
                return {"ok": True, "rtt_ms": int(avg_rtt), "error": None}
            return {"ok": False, "rtt_ms": None, "error": "Host unreachable"}
        except Exception as exc:
            return {"ok": False, "rtt_ms": None, "error": f"ICMP error: {str(exc)}"}